# Build extension and daemon from the same pinned source on the runtime architecture.
FROM --platform=$TARGETPLATFORM node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS browserskill
WORKDIR /build
# apt 换源开关（可选，留空 = 全程官方 deb.debian.org，行为与上游逐字一致）。
#
# ★ 与 builder / final 阶段的写法差别，源于**基镜像不同**：
#   本阶段是 node:24-bookworm-slim，属 **slim 变体，不自带 ca-certificates**；
#   而国内若干镜像（实测 mirrors.tencent.com / mirrors.cloud.tencent.com）的 http
#   会 **302 跳到 https** ⇒ 无 CA 时 apt 会静默忽略全部索引
#   （⚠️ `apt-get update` 仍返回 0，属**假成功**）⇒ 后续 install 失败。
#   因此必须**先用官方源装 ca-certificates，再换源** —— 与下方 final 阶段的处理同构。
#
# 实测（node:24-bookworm-slim，两步各验索引命中数）：
#   步骤1 官方源 update + 装 CA ：索引 3、CA 就位、150s
#   步骤2 换源后再 update       ：索引 3、2s（此时 apt 能跟随 302 走 https）
ARG APK_MIRROR_ARG
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends ca-certificates && \
        rm -rf /var/lib/apt/lists/* && \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends git python3 ca-certificates curl build-essential cmake pkg-config && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
# Rust 工具链下载源（可选，留空 = 官方 static.rust-lang.org）。
# 为什么需要：部分网络下 static.rust-lang.org 极慢（实测 36KB/s，工具链约 300MB ⇒ 2 小时），
# 而国内镜像实测快 2 个数量级（rsproxy.cn / ustc / aliyun 均 >1MB/s）。
# 站点值由 compose 的 build.args 注入（见 my-docker/docker-compose.yml）。
ARG RUSTUP_DIST_SERVER_ARG=""
ARG RUSTUP_UPDATE_ROOT_ARG=""
# 本阶段还会（由 scripts/build_browserskill.sh 发起）做三件依赖国际源的事，
# 部分网络下会失败或极慢，故同样提供可选中继（留空 = 官方行为，全部由 compose 注入）：
#   · git clone https://github.com/Tencent/BrowserSkill.git   → GH_PROXY（git insteadOf 改写）
#   · npx --yes pnpm@… install                                → NPM_REGISTRY_ARG
#   · cargo build --locked -p bsk                             → CARGO_REGISTRY_ARG（sparse 索引）
ARG GH_PROXY=""
ARG NPM_REGISTRY_ARG=""
ARG CARGO_REGISTRY_ARG=""
RUN if [ -n "$RUSTUP_DIST_SERVER_ARG" ]; then \
        export RUSTUP_DIST_SERVER="$RUSTUP_DIST_SERVER_ARG" RUSTUP_UPDATE_ROOT="$RUSTUP_UPDATE_ROOT_ARG"; \
    fi && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
COPY scripts/build_browserskill.sh scripts/browserskill-release.json ./scripts/
COPY patches/browserskill ./patches/browserskill
ARG TARGETOS
ARG TARGETARCH
RUN if [ -n "$GH_PROXY" ]; then \
        git config --global url."${GH_PROXY}https://github.com/".insteadOf "https://github.com/"; \
    fi && \
    if [ -n "$CARGO_REGISTRY_ARG" ]; then \
        mkdir -p "${CARGO_HOME:-/usr/local/cargo}" && \
        printf '[source.crates-io]\nreplace-with = "mirror"\n[source.mirror]\nregistry = "%s"\n' "$CARGO_REGISTRY_ARG" \
            >> "${CARGO_HOME:-/usr/local/cargo}/config.toml"; \
    fi && \
    if [ -n "$NPM_REGISTRY_ARG" ]; then export npm_config_registry="$NPM_REGISTRY_ARG"; fi && \
    bash scripts/build_browserskill.sh /opt/weknora/browserskill "${TARGETOS}/${TARGETARCH}"

# Build stage
FROM golang:1.26-bookworm AS builder

WORKDIR /app

# 通过构建参数接收敏感信息
ARG GOPRIVATE_ARG
ARG GOPROXY_ARG
ARG GOSUMDB_ARG=off
ARG APK_MIRROR_ARG
# Rust 工具链下载源（可选，留空 = 官方 static.rust-lang.org）；见 browserskill 阶段的说明
ARG RUSTUP_DIST_SERVER_ARG=""
ARG RUSTUP_UPDATE_ROOT_ARG=""
# cargo crates 索引镜像（可选，留空 = 官方 crates.io）；本阶段 build-anydoc-lib.sh 会真编译
ARG CARGO_REGISTRY_ARG=""

# 设置Go环境变量
ENV GOPRIVATE=${GOPRIVATE_ARG}
ENV GOPROXY=${GOPROXY_ARG}
ENV GOSUMDB=${GOSUMDB_ARG}

# Install dependencies
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y git build-essential libsqlite3-dev curl

# Install migrate tool
RUN go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

# Copy go mod files. go.mod replace-points anydoc at ./third_party/anydoc-go,
# so that module's go.mod must exist before `go mod download`.
COPY go.mod go.sum ./
COPY third_party/anydoc-go/go.mod third_party/anydoc-go/go.mod
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd/download cmd/download
RUN go run cmd/download/duckdb/duckdb.go
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod bash ./scripts/copy-licenses.sh /license-bundle

# Get version and commit info for build injection
ARG VERSION_ARG
ARG COMMIT_ID_ARG
ARG BUILD_TIME_ARG
ARG GO_VERSION_ARG

# Set build-time variables
ENV VERSION=${VERSION_ARG}
ENV COMMIT_ID=${COMMIT_ID_ARG}
ENV BUILD_TIME=${BUILD_TIME_ARG}
ENV GO_VERSION=${GO_VERSION_ARG}

# Link the anydoc parser engine (office docs converted in-process, no
# Python docreader). Default on so Hub / compose images ship a working
# engine; pass WITH_ANYDOC=0 to skip the Rust toolchain (~few minutes and
# ~1 GB of build-stage layers).
ARG WITH_ANYDOC=1
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    if [ "$WITH_ANYDOC" = "1" ]; then \
        if [ -n "$RUSTUP_DIST_SERVER_ARG" ]; then \
            export RUSTUP_DIST_SERVER="$RUSTUP_DIST_SERVER_ARG" RUSTUP_UPDATE_ROOT="$RUSTUP_UPDATE_ROOT_ARG"; \
        fi && \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain stable && \
        if [ -n "$CARGO_REGISTRY_ARG" ]; then \
            mkdir -p "${CARGO_HOME:-/usr/local/cargo}" && \
            printf '[source.crates-io]\nreplace-with = "mirror"\n[source.mirror]\nregistry = "%s"\n' "$CARGO_REGISTRY_ARG" \
                >> "${CARGO_HOME:-/usr/local/cargo}/config.toml"; \
        fi && \
        ./scripts/build-anydoc-lib.sh; \
    fi

# Build the application with version info
RUN --mount=type=cache,target=/go/pkg/mod \
    if [ "$WITH_ANYDOC" = "1" ]; then \
        make build-prod GO_BUILD_TAGS=anydoc; \
    else \
        make build-prod; \
    fi
RUN --mount=type=cache,target=/go/pkg/mod cp -r /go/pkg/mod/github.com/yanyiwu/ /app/yanyiwu/

# Final stage
FROM debian:12.12-slim

WORKDIR /app

ARG APK_MIRROR_ARG

# Pairing derives the gateway URL from the user's page origin by default.
ENV BROWSERSKILL_BINARY=/opt/weknora/browserskill/bsk \
    BROWSERSKILL_EXTENSION_PATH=/opt/weknora/browserskill/browser-skill-weknora-0.3.0.zip
COPY --from=browserskill /opt/weknora/browserskill /opt/weknora/browserskill

# Create a non-root user first
RUN useradd -m -s /bin/bash appuser

# First, install ca-certificates without mirror to ensure HTTPS works
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Then switch to mirror if specified and install other packages
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential postgresql-client default-mysql-client tzdata sed curl bash vim wget \
        libsqlite3-0 \
        python3 python3-pip python3-dev libffi-dev libssl-dev \
        nodejs npm \
        gosu \
        ffmpeg && \
    python3 -m pip install --break-system-packages --upgrade pip setuptools wheel && \
    mkdir -p /home/appuser/.local/bin && \
    curl -LsSf https://astral.sh/uv/install.sh | CARGO_HOME=/home/appuser/.cargo UV_INSTALL_DIR=/home/appuser/.local/bin sh && \
    chown -R appuser:appuser /home/appuser && \
    ln -sf /home/appuser/.local/bin/uvx /usr/local/bin/uvx && \
    chmod +x /usr/local/bin/uvx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create data directories and set permissions
RUN mkdir -p /data/files && \
    chown -R appuser:appuser /app /data/files

# Copy migrate tool from builder stage
COPY --from=builder /go/bin/migrate /usr/local/bin/
COPY --from=builder /app/yanyiwu/ /go/pkg/mod/github.com/yanyiwu/

# Copy the binary from the builder stage
COPY --from=builder /app/config ./config
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/migrations ./migrations
COPY --from=builder /app/dataset/samples ./dataset/samples
COPY --from=builder /root/.duckdb /home/appuser/.duckdb
COPY --from=builder /app/WeKnora .
COPY --from=builder /license-bundle/ ./

# Copy and make entrypoint script executable
COPY --from=builder /app/scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh

# Make scripts executable
RUN chmod +x ./scripts/*.sh

# Expose ports
EXPOSE 8080


ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
CMD ["./WeKnora"]
