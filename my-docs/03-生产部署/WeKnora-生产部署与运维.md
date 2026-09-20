# WeKnora 生产部署与运维

> **部署分支**：`wkj-dev`
> **部署目标**：nanning-111（`10.168.1.111`）
> **对外端口**：`41200`（网页）/ `41201`（API）
> **部署脚本**：`deploy/deploy-wkj-dev.sh`
> 文档日期：2026-09-20

---

## 〇、一句话上手

在项目根目录执行：

```bash
./deploy/deploy-wkj-dev.sh deploy     # 首次部署 / 完整部署（幂等，可重复跑）
./deploy/deploy-wkj-dev.sh update     # 日常更新（改完代码跑这个）
```

脚本会自己完成：**推代码 → 111 拉取 → 检查环境 → 起容器 → 健康检查**。任一步失败会立刻停下并告诉你原因。

---

## 一、部署架构

### 1.1 代码怎么从本机到 111

```
   ┌─────────────────┐   git push    ┌──────────────────────────┐
   │  本地 Mac        │ ────────────► │ nanning-110 Gitea         │
   │  分支 wkj-dev    │               │ 10.168.1.110:13000        │
   └─────────────────┘               │ wakeagent/WeKnora (私有)  │
                                     └───────────┬──────────────┘
                                                 │ git pull
                                                 ▼
                                     ┌──────────────────────────┐
                                     │ nanning-111 (10.168.1.111)│
                                     │ /mnt/data/weknora         │
                                     │ docker compose ×5 容器    │
                                     └──────────────────────────┘
```

**为什么绕一圈走 Gitea，而不是直接 rsync 到 111？**

- 走 Git：每一次部署都对应一个**明确的 commit**，出问题能精确回滚到某个提交；二开时改动有版本记录。
- 本机 Mac 在 `192.168.55.x` 网段（经 NAT 出去），**无法被 111 反向访问**，直接推文件反而更绕。
- 110 与 111 在同一内网（实测 ping 0.4ms），Gitea 中转这条链路是稳的。

### 1.1.1 编排文件用哪一份：`my-docker/`

仓库里**有两份 compose**，分工明确：

| 文件 | 归属 | 谁在用 |
|---|---|---|
| `docker-compose.yml`（仓库根） | **官方原版，一字不改** | 没人直接用；作为同步上游的基准 |
| `my-docker/docker-compose.yml` | **站点定制版**（官方副本 + 3 处修改） | **部署一律用它** |

这样做的好处：**同步上游时零冲突** —— 上游怎么改官方那份都不影响我们，
只需按 `my-docker/` 头部的差异清单逐条核对是否有需要跟进的变化。

差异清单是**单一事实来源**，写在 `my-docker/docker-compose.yml` 的文件头注释里
（紧贴被改动的代码），`my-docker/README.md` 不重复。

> **调用时必须带 `--project-directory`**：Compose 的相对路径（`build.context` /
> bind mount / `env_file: .env`）默认按 **compose 文件所在目录** 解析，文件挪进 `my-docker/`
> 后会全部错位 —— 轻则报 `my-docker/.env 不存在`，重则项目名退化成 `my-docker`
> 而指向一套**新建的空数据卷**（表现为「数据全没了」）。
> 部署脚本已把这一串参数封装为 `$DC`，并额外加了项目名硬校验兜底。

### 1.2 服务器与路径

| 项 | 值 |
|---|---|
| 主机 | `nanning-111`（SSH 别名，已配免密） |
| 系统 / 架构 | Ubuntu 24.04.5 LTS / **x86_64** |
| 资源 | 32 核 / 128 GB 内存 |
| Docker | 29.8.0（**免 sudo 可用**） |
| 代码目录 | **`/mnt/data/weknora`**（机械盘） |
| Docker 存储 | `/mnt/data/docker` + `/mnt/data/containerd`（已迁至机械盘） |
| 数据卷 | `weknora_postgres-data`、`weknora_data-files`、`weknora_docreader-tmp` |

> **为什么放机械盘**：本服务属"IO 要求不高"类，按《存储分层管理标准》R2 走机械盘（默认层），不需要申请 `/srv/fast` 高速层。

### 1.3 端口规划

| 服务 | 容器内端口 | **宿主机（对外）** |
|---|---|---|
| frontend（网页） | 80 | **41200** |
| app（后端 API） | 8080 | **41201** |
| postgres / redis / docreader | — | **不映射**（仅容器网络内互通） |

访问地址：

- 网页：`http://10.168.1.111:41200`
- API：`http://10.168.1.111:41201/api/v1`
- 健康检查：`http://10.168.1.111:41201/health`

> **`41200-41299` 为本项目预留端口段**，后续如需启用可选组件（MinIO / Neo4j / Langfuse 等）按顺序占用 `41202`、`41203`…，不要跳到区间外。

### 1.4 容器清单

| 容器名 | 作用 |
|---|---|
| `WeKnora-frontend` | 网页界面（Nginx） |
| `WeKnora-app` | 后端主程序 |
| `WeKnora-docreader` | 文档解析服务 |
| `WeKnora-postgres` | 数据库（ParadeDB） |
| `WeKnora-redis` | 队列与缓存 |

> 容器名沿用上游 `WeKnora-` 前缀（compose 里写死）。Docker **项目名**为 `weknora`（体现在网络与数据卷名上）。

---

## 二、脚本用法

### 2.1 命令清单

| 命令 | 作用 | 何时用 |
|---|---|---|
| `deploy` | 首次部署 / 完整部署 | 第一次搭环境；或想完整重跑一遍 |
| `update` | 推代码 → 拉取 → 重建容器 | **改完代码日常更新** |
| `build` | 在 111 上构建镜像后重启 | 二开改了 Go / 前端 / docreader 源码 |
| `status` | 查看容器状态 | 想确认在不在跑 |
| `logs [服务]` | 跟踪日志（默认 `app`） | 排查问题 |
| `restart` | 重启容器 | 改了配置想生效 |
| `health` | 健康检查 | 快速确认服务可用 |
| `compose-diff` | 对比官方与 `my-docker/` 的 compose 差异 | **上游更新后**核对；或怀疑 my-docker 过期时 |
| `shell` | 登录 111 并进入部署目录 | 手工排查 |
| `down` | 停止容器（**数据卷保留**） | 临时停服 |

### 2.2 `deploy` 与 `update` 的区别

| | `deploy` | `update` |
|---|---|---|
| 本机前置检查 | ✅ | ✅ |
| 111 环境检查（SSH/docker/挂载） | ✅ | ❌（假定已就绪） |
| 推代码 + 拉代码 | ✅ | ✅ |
| `.env` 处理 | 无则生成，有则保留 | 同左 |
| 拉镜像 + 起容器 | ✅ | ✅ |

**两者都是幂等的**，重复执行结果一致。日常更新用 `update` 就够；不确定环境是否完好时用 `deploy`。

### 2.3 `.env` 的处理规则（重要）

- **首次部署**自动在 111 上生成 `.env`，内含随机生成的数据库密码、Redis 密码、JWT 密钥、系统加密主密钥，以及端口配置。
- **之后再执行脚本，绝不覆盖 `.env`**（里面有生产密钥，覆盖会导致已加密的数据永久无法解密）。
- 要改配置（比如加 SSRF 白名单、调端口），**手工编辑 111 上的 `/mnt/data/weknora/.env`**，然后 `./deploy/deploy-wkj-dev.sh restart`。

### 2.4 二开（改代码）的完整流程

> ### ⚠️ 先读这条：`deploy`/`update` **不会**部署你的代码
>
> `docker-compose.yml` 里每个服务**同时**声明了 `image:` 和 `build:`，两者共用同一个 tag：
>
> | 命令 | 实际发生 | 源码改动 |
> |---|---|---|
> | `docker compose pull`（`deploy` / `update` 走这条） | 拉官方预构建镜像，覆盖 tag | ❌ **不生效** |
> | `docker compose build`（`build` 子命令走这条） | 在 111 上从源码构建，覆盖同一 tag | ✅ 生效 |
>
> **实测（2026-09-20，构建前）**：当时 111 上运行的 app 是**官方镜像**：
>
> ```
> wechatopenai/weknora-app:latest
>   Created     = 2026-09-03T07:11:01Z    ← 官方 9 月 3 日构建（判据看这个）
>   RepoDigests = [wechatopenai/weknora-app@sha256:14953fcb…]
> 容器 WeKnora-app 使用镜像 = 同一 ID
> ```
>
> ### ⚠️ 判别技法（**2026-09-20 修正，别再用 RepoDigests**）
>
> 早先我写的判据说"本地构建的镜像 `RepoDigests` 为空"—— **这是错的**。
> 本机 Docker 使用 **containerd 镜像存储**，本地构建的单架构镜像其 `RepoDigests`
> **就等于自己的镜像 ID**（实测 tag 指向 `sha256:f66721c1…`，`RepoDigests` 也是
> `…@sha256:f66721c1…`）⇒ 拿它判"是否本地构建"**恒为假，保护会失效**。
>
> 正确的两条判据：
>
> ```bash
> # 判据 A：镜像构建时间（最直观）
> ssh nanning-111 "docker image inspect wechatopenai/weknora-app:latest --format '{{.Created}}'"
> #   2026-09-03 = 官方预构建镜像；今天的时间 = 本地源码构建
>
> # 判据 B（最强，见 2.4.1）：二进制里注入的 commit
> ssh nanning-111 "docker exec WeKnora-app grep -ac 87bf42e4 /app/WeKnora"
> #   与 111 上 git rev-parse --short=8 HEAD 比对，一致即证明跑的是该提交
> ```
>
> **危险点**：`update` 里的 `pull` 会把本地构建的二开镜像**静默替换**回官方镜像 ——
> 表现为"代码改了、容器也重建了、功能一点没变"，极难排查。
> **脚本的保护机制**：`build` 成功后把各镜像 ID 登记到 `.git/wkj-last-build`
> （放在 `.git` 内 ⇒ 不污染工作区）；后续若 tag 仍指向登记过的 ID，就判定为二开产物，
> **拒绝 pull 并自动改用 `build`**。确实要回到官方镜像：
> `WKJ_ALLOW_PULL_OVERWRITE=1 ./deploy/deploy-wkj-dev.sh update`

> ### ⚠️ 先看清楚：`build` 到底会升什么版本
>
> `wkj-dev` 相对上游 `main` **只多了部署产物**（`my-docs/`、`my-docker/`、`deploy/`、
> `README-WAKE.md`），**`internal/` `frontend/` `docreader/` 尚无源码改动**。
> 也就是说：只要还没动源码，`build` 的净效果 = **把线上升级到上游最新版**。
>
> 2026-09-20 首次 build 时的实测差距：
>
> | 项 | 值 |
> |---|---|
> | 线上镜像构建于 | `2026-09-03` |
> | 上游领先提交数 | **185** |
> | 改动文件数（按目录） | `internal` 1704 / `frontend` 1118 / **`migrations` 63** / `config` 38 / `docreader` 6 |
>
> ⇒ 这是一次**跨 185 个提交的版本升级**，启动时会执行 `AUTO_MIGRATE` 跑 63 个迁移文件。
> **数据不会被清**（迁移是增量演进），但表结构会变 —— 因此每次 build 前都应先备份：
>
> ```bash
> ssh nanning-111 "cd /mnt/data/weknora && DBPW=\$(grep -m1 '^DB_PASSWORD=' .env | cut -d= -f2-) && \
>   mkdir -p /mnt/data/backups/weknora && \
>   docker exec -e PGPASSWORD=\$DBPW WeKnora-postgres pg_dump -U postgres -d WeKnora -Fc \
>   > /mnt/data/backups/weknora/pre-build-\$(date +%Y%m%d-%H%M%S).dump"
> ```
>
> `docreader` 那 6 个文件是 **SSRF 代理 + `web_parser.py`**（安全相关，且正是"导入 URL"
> 用到的组件）⇒ **不能跳过构建 docreader**。所幸 **proto 未变**，gRPC 契约兼容。

```bash
# 1. 本地改代码
cd /Users/weikejia/CODE/my-agent-group/projects/rag-tools/WeKnora
git checkout wkj-dev
vim internal/xxx.go            # 或改 frontend/ 、docreader/

# 2. 提交
git add -A && git commit -m "feat: 我的改动"

# 3. 部署（build 模式会在 111 上构建镜像）
./deploy/deploy-wkj-dev.sh build

# 4. 自查：确认跑的确实是本地构建（看构建时间；并核二进制里的 commit）
ssh nanning-111 "docker image inspect wechatopenai/weknora-app:latest --format '{{.Created}}'"
ssh nanning-111 "docker exec WeKnora-app grep -ac $(git rev-parse --short=8 HEAD) /app/WeKnora"
```

> **`build` 模式耗时较长**：Go 编译 + 前端 npm 构建 + docreader 镜像，首次可能 20~40 分钟（111 是 32 核，比本机快）。之后有构建缓存会快很多。

#### 2.4.1 怎么确认线上跑的是哪一版（已支持直接查）

`build` 时会自动注入版本信息，所以**不需要**再去猜。查证方式：

```bash
# 方式一：后端接口（返回 version / commit_id / build_time / go_version）
ssh nanning-111 "curl -s -H 'Authorization: Bearer <token>' \
  http://localhost:41201/api/v1/system/info" | grep -o '"commit_id":"[^"]*"'
```

方式二（不用登录）：看构建时间 + 直接核二进制里的 commit

```bash
# 构建时间：2026-09-03 = 官方预构建；今天的时间 = 本地源码构建
ssh nanning-111 "docker image inspect wechatopenai/weknora-app:latest --format '{{.Created}}'"

# ★ 最强判据：二进制里注入的 commit 应与 111 上的 HEAD 一致
ssh nanning-111 "cd /mnt/data/weknora && C=\$(git rev-parse --short=8 HEAD) && \
  docker exec WeKnora-app grep -ac \$C /app/WeKnora && echo \"期望提交 \$C\""
# 返回 >=1 且与 HEAD 一致 ⇒ 跑的确实是该提交的源码构建
```

方式三（三个镜像各查各的 —— **判据必须适配各工具的实际表示**）

| 镜像 | 该查什么 | 实测（2026-09-21） |
|---|---|---|
| `weknora-app`（Go 二进制） | 二进制内注入的 commit（**8 位**） | `grep -ac b1c6638b /app/WeKnora` → **3 次** |
| `weknora-ui`（前端产物） | **7 位**（`vite.config.ts:19` 有 `.slice(0, 7)`） | `Settings-*.js` 里 `w="b1c6638"` |
| `weknora-docreader`（Python） | **无 commit 注入** ⇒ 只能比**源文件 sha256** | `utils/ssrf_proxy.py` 等与宿主**逐一一致** |

```bash
# 前端（注意是 7 位）
ssh nanning-111 "docker exec WeKnora-frontend sh -c \
  'grep -ro \"w=\\\"[a-f0-9]\\{7\\}\\\"\" /usr/share/nginx/html/assets/Settings-*.js'"

# docreader（无注入，比文件哈希）
ssh nanning-111 "cd /mnt/data/weknora && for f in docreader/utils/ssrf_proxy.py \
  docreader/parser/web_parser.py; do \
    echo \"\$f 宿主=\$(sha256sum \$f | cut -c1-16)\"; done"
ssh nanning-111 "docker exec WeKnora-docreader sh -c \
  'sha256sum /app/docreader/utils/ssrf_proxy.py /app/docreader/parser/web_parser.py'"
```

> ⚠️ **两个判据陷阱（都实际踩过）**
> 1. **前端只存 7 位** —— 用 8 位去 grep 会得出「前端没注入」的**错误结论**（实际注入了）。
> 2. **docreader 没有 commit 注入**（Python 不编译）—— 拿后端那套判据去套会永远查不到，
>    只能比源文件哈希。
> ⇒ **"没查到"不等于"没部署"**：查不到时先问「这个载体本来会不会带这个标识」，再换判据。

> **另一个坑：容器绑定的镜像可能 ≠ tag 当前指向的镜像**（containerd 存储 + BuildKit 缓存命中）。
> 实测：`WeKnora-docreader` 容器的 `.Image` 与 tag 的 `.Id` 不同，且该 ID 已不在
> `docker image ls` 中（记录被 GC、容器快照仍存活）。原因是 docreader 镜像本次构建
> **缓存命中未重建**，但 tag 被重新指向了新记录。
> **判定要点**：这类差异**不代表代码不一致** —— 以「容器内文件哈希 vs 宿主源码」为准。
> 想彻底归位：`docker compose ... up -d --force-recreate docreader`（会短暂中断解析服务）。

生效链路（改之前只有这一条路能反推，成本很高）：
`my-docker` 的 build.args → `Dockerfile.app:59-61` builder 阶段的 `ENV`
→ `Makefile:256-259` 从环境变量取 `COMMIT_ID`
→ `Makefile:262` 用 `ldflags -X ...handler.CommitID` 写进二进制
→ `GET /api/v1/system/info` 的 `commit_id`。

> 官方 compose 不传这几个参数 ⇒ 二进制里恒为 `unknown`，只能靠**日志行号**反推
> （如官方镜像报 `knowledge_process.go:3414`、wkj-dev 报 `3601`）。这正是我们加 `[差异 4]` 的原因。
> 另外 `.dockerignore` 排除了 `.git/`，`VERSION` 的 `git describe` 必然失败，只能靠 `VERSION_ARG` 兜底。

#### 2.4.2 111 上构建的前置条件（✅ 已由 `my-docker/` 解决）

111 **无法直连** `registry-1.docker.io` 与 `proxy.golang.org`。构建期必须联网的几处：

| 步骤 | 依赖 | 现状 |
|---|---|---|
| 拉基础镜像（`golang:1.26-bookworm`、`node:24-bookworm-slim`、`debian:12.12-slim`） | Docker registry | ✅ 走 `daemon.json` 的 `registry-mirrors`（docker.1ms.run 等） |
| `apt-get` 装包 | Debian 源 | ✅ `APK_MIRROR_ARG` / `APT_MIRROR` 已配腾讯源 |
| `go install` / `go mod download` | Go module proxy | ✅ 已由 `my-docker/` 传 `GOPROXY_ARG` |
| 前端 `npm install` | npm registry | ✅ 已由 `my-docker/` 传 `NPM_REGISTRY` |
| **anydoc（Rust）工具链**：`curl https://sh.rustup.rs \| sh` + 取 anydoc crate | `sh.rustup.rs`、`rsproxy.cn` | ✅ 实测均可达 200（脚本优先用国内镜像 `rsproxy.cn`） |

> `WITH_ANYDOC=1`（默认）= 在 Go 进程内解析 office 文档，构建时需装 Rust 工具链。
> 想跳过可设 `WITH_ANYDOC=0`（省几分钟和约 1GB 层），但会失去进程内解析能力。

**根因**：官方 `docker-compose.yml` 的 `app.build.args` 只传了 `APK_MIRROR_ARG` 与 `WITH_ANYDOC`，
**没有 wire `GOPROXY_ARG`**（`Dockerfile.app:23` 声明了该 ARG 却没传）；`NPM_REGISTRY` 与 `APT_MIRROR` 同理
（都声明了、默认空 ⇒ 回落国外源）。仓库**无 `vendor/`**，所以 Go 代理是硬需求。

**解法**：不改官方 compose，改为在 `my-docker/docker-compose.yml` 的三处 build.args 里补默认值
（详见该文件头部「与官方的差异清单」）。部署脚本已统一使用该文件，**无需再手工配 `.env`**。

##### 实测验证（2026-09-20，111 上 compose v5.5.1）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 路径语义未错位 | 逐行 diff 官方与 my-docker 的 `docker compose config` | **仅 3 处差异**（= 定制项）；`context` 仍为 `/mnt/data/weknora` |
| 项目名未变 | `config \| grep '^name:'` | `weknora` ✅ |
| 数据卷未变 | 对比 `config` 声明的卷 vs `docker volume ls` | `data-files`/`docreader-tmp`/`postgres-data` ↔ `weknora_*` **一一对应** |
| **不影响运行中的服务** | `config --hash='*'` vs 容器 `com.docker.compose.config-hash` | 5 个服务**全部一致** ⇒ 切换不会触发重建 |
| 端到端 | 执行 `./deploy/deploy-wkj-dev.sh update` | 通过；容器仍显示 `Up 6 hours`（**未被重建**）、前端 200、后端健康 |

> `config-hash` 只覆盖**运行时**字段（镜像/环境变量/挂载/端口），不含 `build.args` ——
> 这正是「站点定制只影响构建、不影响运行」的机制保证。

#### 2.4.3 构建踩过的四个坑（都已在脚本里加了防护）

**坑 1：`APT_MIRROR` 的取值语义 —— 只能给「带 scheme 的 base、不含路径」**

`Dockerfile.docreader` 是这么换源的（第 8 行，两个阶段各一次）：

```sh
sed -i "s@http://deb.debian.org@${APT_MIRROR}@g" /etc/apt/sources.list.d/debian.sources
```

而 `debian.sources` 里本身已带 `/debian` 与 `/debian-security`。所以：

| 给的值 | 拼出来的 URI | 结果 |
|---|---|---|
| `https://mirrors.tencent.com` | `https://mirrors.tencent.com/debian` | ✅ 正确 |
| `https://mirrors.tencent.com/debian` | `https://mirrors.tencent.com/debian/debian` | ❌ 404 → `apt` exit 100 |

> 注意 `APK_MIRROR_ARG`（`Dockerfile.app`）的 `sed` 只替换**主机名**，所以要给
> `mirrors.tencent.com`。**两个参数语义不同，别混。**

**坑 2：`apt-get update` 有「假成功」**

索引全部下载失败时，`apt-get update -qq` **仍然返回 0**（只在 stderr 打 warning）。
只看退出码会误判为成功。必须同时查「命中的索引文件数」：

```bash
ls /var/lib/apt/lists/ | grep -c _Packages    # 0 = 实际什么都没拿到
```

**坑 3：判断源能不能用，必须以「实际使用该源的基镜像」为准**

`docreader` 的两个阶段（builder + runner）**都是** `python:3.10.18-bookworm`（非 slim，
基于 `buildpack-deps`，**自带 CA 证书**）⇒ https 源完全可用。
但若拿**裸 `debian:12.12-slim`**（无 CA）去测同样的 https 源，会得出「证书失败、
必须用 http」的**相反结论**。

> 实测对比（同一台 111）：正确基镜像 + 腾讯 https 源 → **17 秒**通过；
> 错误基镜像 + 阿里云 http 源 → 8 分 43 秒（且仍属勉强可用）。
> **用错探测载体，会把一个 17 秒的正解判死。**

为此脚本新增 `_preflight_build_sources()`：构建前**秒级**校验
`APT_MIRROR` / `GOPROXY_ARG` / `NPM_REGISTRY` 是否 `200 且不跳转`，不过则中止 ——
避免把源配置问题拖成 30 分钟后的构建失败。

**坑 4：slim 基镜像没有 CA 证书 —— 换源必须先装 CA，再换源**

`Dockerfile.app` 三个 apt 阶段的**基镜像不同**，有无 CA 因此不同：

| 阶段 | 基镜像 | 自带 CA？ | 换源写法 |
|---|---|---|---|
| browserskill | `node:24-bookworm-slim` | ❌ **无** | 需先装 CA（`:16` ARG → `:21` sed） |
| builder | `golang:1.26-bookworm`（非 slim） | ✅ 有 | 直接换（`:70` → `:84`） |
| final | `debian:12.12-slim` | ❌ **无** | 需先装 CA（`:161` 注释 → `:168` sed） |

国内若干镜像（实测 `mirrors.tencent.com`、`mirrors.cloud.tencent.com`）的 **http 会 302 跳 https**。
而 `sed` 只替换**主机名**、不改 scheme，所以换出来的 URI 仍是 `http://…` —— apt 会跟随 302 去访问 https，
**slim 基镜像没有 CA 证书 ⇒ 握手失败 ⇒ 索引全被忽略**（且 `apt-get update` 仍返回 0，见坑 2）。

上游在 **final 阶段**已经处理对了 —— `Dockerfile.app:161` 的注释就写着
“First, install ca-certificates without mirror to ensure HTTPS works”：**先用官方源装 CA，再换源**。
`browserskill` 阶段原先缺这一步（属上游疏漏），2026-09-21 已按**同一模式**补齐。

> 实测（真实基镜像 `node:24-bookworm-slim`，两步各验索引命中数，非推测）：

| 步骤 | 结果 |
|---|---|
| 1. 官方源 `apt-get update` + 装 `ca-certificates` | 索引命中 **3**、CA 就位、**150s** |
| 2. 换腾讯源后再 `apt-get update` | 索引命中 **3**、**仅 2s**（此时 apt 能跟随 302 走 https） |

> **代价与收益**：必然要跑一遍官方源（约 150s）装 CA；收益是该阶段装 `build-essential` / `cmake` /
> `pkg-config` / `git` 等从「走 deb.debian.org」变为「走腾讯源」——
> 改动前这一阶段实测 **1539s 仍未装完**（当时最长的单项瓶颈）。
>
> **端到端构建已实证（2026-09-21，commit `b1c6638b`）**：
>
> ```
> #39 [app browserskill 3/7] RUN ...            总耗时 223s   ← 改动前 1539s 仍未装完
> #39 2.023  Get:1 http://deb.debian.org/debian         ← 步骤1：官方源 update
> #39 154.3  Setting up ca-certificates                 ← 步骤1：装 CA 完成（与预演 150s 吻合）
> 日志内域名统计：deb.debian.org 18 次 / mirrors.tencent.com 779 次   ← 步骤2 换源生效
> ```
>
> 即两段都按预期执行，该阶段由「装不完」变为 **223s 完成**。本次构建总计 16m47s，
> 结束后核对：二进制内 commit = `b1c6638b`（与 111 上 HEAD 一致）、
> 数据 `knowledges=2 chunks=81 wiki_pages=33 tenants=1 kbs=1`（与基线逐项一致）、
> `schema_migrations version=106 dirty=false`、前端/后端均 HTTP 200。

> **判断某阶段能不能直接用国内镜像，要先看它的基镜像有没有 CA** —— 这与坑 3 是同一类错误的两个面：
> 坑 3 是「用错载体测源速度」，本坑是「用错载体判断源可用性」。**判据必须落在该阶段真实使用的基镜像上。**

### 2.5 改 `.env` 后的生效方式

| 改了什么 | 怎么生效 |
|---|---|
| `.env` 里的环境变量 | `deploy-wkj-dev.sh restart` **不够**，要 `ssh` 上去 `docker compose up -d app` 重建容器 |
| 代码 | `deploy-wkj-dev.sh build` |
| 只是重启进程 | `deploy-wkj-dev.sh restart` |

> 这是 Docker 的固有行为：**环境变量只在容器创建时读取**，`restart` 不会重新读 `.env`。

---

## 三、配置模型（LLM / Embedding / OCR）

这部分与本地部署完全一致，**详见**：

👉 [`../02-本地部署与配置/WeKnora-本地部署与配置指南.md`](../02-本地部署与配置/WeKnora-本地部署与配置指南.md)

本文件不重复。**生产环境需要特别注意的两点**：

### 3.1 SSRF 白名单（脚本已预置）

脚本生成的 `.env` 已包含：

```
SSRF_WHITELIST=host.docker.internal,localhost,127.0.0.1,10.168.1.110,10.168.1.111
```

含义：允许 app 访问 110 和 111 两台机器上的模型服务。

**如果你的模型服务在别的机器**，编辑 111 上的 `.env` 追加该 IP，然后重建 app 容器。

### 3.2 可用的模型来源（111 同网段现有服务）

| 服务 | 地址 | 说明 |
|---|---|---|
| 110 Ollama | `http://10.168.1.110:11434/v1` | 已有模型 |
| 110 Bonsai 27B | `http://10.168.1.110:11435/v1` | llama.cpp，OpenAI 兼容 |
| 110 ai-gateway | `http://10.168.1.110:13490/v1` | 1Panel AI 网关，需 Key |
| 111 本机 Ollama | `http://host.docker.internal:11434/v1` | 111 上的 Ollama |

> 这些服务都是在跑的，但**具体用哪个、Key 是什么由你决定**——脚本只负责把网络通路（SSRF 白名单）打开。
>
> 注意 110 的 Ollama 是 `OLLAMA_NUM_PARALLEL=1`（单并发槽），长请求会互相阻塞，WeKnora 的批量 embedding 可能与之冲突。生产用建议单独规划一个 embedding 服务。

---

## 四、故障排查

### 4.1 常用命令

```bash
cd /Users/weikejia/CODE/my-agent-group/projects/rag-tools/WeKnora

./deploy/deploy-wkj-dev.sh status          # 容器状态
./deploy/deploy-wkj-dev.sh logs app        # 后端日志（最常看）
./deploy/deploy-wkj-dev.sh logs docreader  # 解析日志
./deploy/deploy-wkj-dev.sh health          # 健康检查
./deploy/deploy-wkj-dev.sh shell           # 登录 111
```

### 4.2 常见问题

| 现象 | 原因 | 处置 |
|---|---|---|
| 脚本报「111 环境检查失败」 | docker 服务停了 / 机械盘没挂 | `ssh nanning-111` 检查 `df -h /mnt/data`、`systemctl status docker` |
| 脚本报「推送失败」 | 110 Gitea 不通 / 凭据失效 | 检查 `~/.git-credentials` 中 `10.168.1.110%3a13000` 条目；Gitea 是否在跑 |
| 拉镜像极慢或失败 | 服务器镜像源问题 | 上一句 `docker compose pull` 手工重试；或检查 `/etc/docker/daemon.json` 镜像源 |
| 后端一直不 healthy | 首次建表慢 / 配置错 | `logs app` 看报错；首次启动建 70 张表需要 1~2 分钟 |
| 网页打不开 | 前端容器或端口问题 | `status` 看状态；确认 `41200` 未被占用 |
| 配模型报 SSRF 错误 | 白名单没加 | 见 3.1 |

### 4.3 端口冲突检查

```bash
ssh nanning-111 'ss -ltn | grep -E "412[0-9][0-9]"'
```

---

## 五、附录：本次部署记录

### 5.1 部署前环境核查（实测）

| 检查项 | 结果 |
|---|---|
| 111 系统 / 架构 | Ubuntu 24.04.5 LTS / x86_64 |
| Docker | 29.8.0，免 sudo 可用，`DockerRootDir=/mnt/data/docker` |
| 端口 41200~41220 | **全部空闲** |
| 磁盘 | `/` 857G 可用；`/mnt/data` 15T 可用 |
| 机械盘哨兵 | `/mnt/data/.mounted` 存在 ✅ |
| 原有 weknora 痕迹 | 无（首次部署） |

### 5.2 代码中转仓库

| 项 | 值 |
|---|---|
| Gitea | `nanning-110`，`http://10.168.1.110:13000`（另一入口 `http://10.168.1.110/`） |
| 仓库 | `wakeagent/WeKnora`（**私有**，本次新建） |
| 推送账号 | `wakeagent`（Gitea 上的 Agent 专用账号） |
| 凭据存放 | 本机 `~/.git-credentials`（键 `10.168.1.110%3a13000`）；111 上已同样登记 |
| 本地 remote 名 | `gitea110` |

### 5.3 部署结果（2026-09-20 实测）

| 检查项 | 结果 |
|---|---|
| 代码就位 | `/mnt/data/weknora`，提交 `3fce01e2`（分支 `wkj-dev`） |
| 容器 | 5 个全部 Up；`app` / `docreader` / `postgres` healthy |
| 网页 | `http://10.168.1.111:41200/` → **HTTP 200**（标题 `WeKnora`） |
| 后端 | `http://10.168.1.111:41201/health` → **HTTP 200** `{"status":"ok"}` |
| 数据库 | 自动建表完成（与本地一致 70 张表） |
| 镜像落盘 | `/mnt/data`（机械盘），符合存储分层要求 |
| 外网访问 | 从本机 Mac 实测可达 ✅ |

镜像体积（供以后评估参考）：

| 镜像 | 大小 |
|---|---|
| `wechatopenai/weknora-docreader:latest` | **5.69 GB** |
| `wechatopenai/weknora-app:latest` | 2.4 GB |
| `wechatopenai/weknora-frontend`(ui):latest | 130 MB |
| `redis:7.0-alpine` | 48.9 MB |
| `paradedb/paradedb:v0.22.6-pg17` | （随 compose 拉取） |

### 5.4 ⚠️ 首次部署踩到的坑（已修复进脚本）

**现象**：首次 `deploy` 时报

```
Container WeKnora-app Error dependency failed to start: container WeKnora-app is unhealthy
```

`postgres` / `redis` / `docreader` 都正常，但 `app` 被判不健康，**连带 `frontend` 启动失败**。

**根因**：

1. `app` 首次启动要在机械盘上**建 70 张表**（外加初始化），耗时超过了 compose healthcheck 的窗口
   ——`start_period: 60s` + `retries: 3 × interval: 30s`，合计约 150s；
2. `frontend` 声明了 `depends_on: app(condition: service_healthy)`；
3. compose 的固有行为：**依赖检查失败后，依赖方会停在 `Created` 状态且不再自动重试**（即使 `app` 随后自行恢复成 healthy）。

结果：`app` 后来自己重启并变成 healthy，但 `frontend` 一直卡在 `Created`，需要手工 `docker compose up -d frontend`。

**修复**（已改进 `compose_up` 函数）：

- **分两阶段启动**：先 `up -d postgres redis docreader app`，脚本轮询等 `app` 变成 healthy（最长 600s），**再** `up -d frontend`。绕开依赖连锁失败。
- **前端兜底**：`health_check` 里若发现前端容器不是 `running`，主动拉起一次。
- **顺带修掉输出噪音**：`docker compose pull` 加 `--quiet`——首次部署时进度条刷了 **57 万字节**日志，把关键信息全淹没了。

**第二次执行 `update` 已验证修复有效**：分阶段启动正常、输出干净、健康检查通过。

---

### 5.5 首次源码构建（2026-09-20 23:57，第 5 次尝试成功）

前 4 次失败全部出在**构建期国际网络依赖**上，逐项定位并解决后第 5 次成功。

> 2026-09-21 又补齐**并验证**了表格中第 2 项（`browserskill` 阶段的 apt 换源，见 2.4.3 坑 4）——
> 该项此前是唯一「未处理、只靠官方源硬扛」的依赖。至此源矩阵 11 项**全部有对策，且全部经实测**。
> 二次构建（commit `b1c6638b`）耗时 16m47s，数据与基线一致、二进制内 commit 与 HEAD 一致。

**结果核对（全部实测）**

| 项 | 结果 |
|---|---|
| 耗时 | **15m57s**（app / frontend / docreader 三个镜像） |
| 镜像构建时间 | `2026-09-20T23:57` ⇒ 本地源码构建（非官方 `2026-09-03`） |
| **二进制内的 commit** | `grep -ac 87bf42e4 /app/WeKnora` **命中**，与 111 上 `git rev-parse --short=8 HEAD` **一致** |
| 数据库迁移 | `90 → 106`，`dirty=false`；表数 `70 → 78` |
| **数据完整性** | `knowledges=2 chunks=81 wiki_pages=33 tenants=1 kbs=1` ⇒ **与构建前基线逐项一致** |
| 服务 | 前端 HTTP 200 / 后端 HTTP 200；app、docreader `healthy` |

**构建期联网依赖与国内源矩阵**（这是能构建成功的关键）

| # | 依赖 | 官方默认源 | 本网络实测 | 采用的替代 |
|---|---|---|---|---|
| 1 | apt（docreader 两阶段 / app builder+final） | deb.debian.org | 4.6~9MB/s（但构建内会抖动到很慢） | `https://mirrors.tencent.com`（差异[3]） |
| 2 | apt（app **browserskill** 阶段） | deb.debian.org | 改动前实测 **1539s 未装完** | 同 `APK_MIRROR_ARG`（`mirrors.tencent.com`），**但须先装 CA 再换源** —— 见 2.4.3 坑 4 |
| 3 | Go modules | proxy.golang.org | 不可达 | `goproxy.cn`（差异[1]） |
| 4 | npm（frontend / browserskill pnpm） | registry.npmjs.org | 不可达 | `registry.npmmirror.com`（差异[2][7]） |
| 5 | pip（uv 安装器 + 依赖） | pypi | 1.4MB/s ✅ | 无需处理 |
| 6 | protoc | GitHub Releases | 0~40KB/s 且中断 | **预置到 `packages/`** 走 Dockerfile 离线分支 |
| 7 | grpc_health_probe | GitHub Releases | 同上 | `GH_PROXY`（差异[6]） |
| 8 | Rust 工具链 | static.rust-lang.org | **36KB/s ⇒ 约 2 小时** | `rsproxy.cn`（差异[5]） |
| 9 | `git clone BrowserSkill` | github.com | **HTTP2 framing 报错** | `GH_PROXY` + `git insteadOf`（差异[6]） |
| 10 | cargo crates（anydoc / bsk） | crates.io | 慢 | `sparse+https://rsproxy.cn/index/`（差异[8]） |
| 11 | uv 二进体 | releases.astral.sh | 1.4MB/s ✅ | 无需处理 |

**GitHub 反代实测**（判据 = 内容 sha256 与官方三方交叉验证值一致，非状态码）

| 反代 | 下载 1699853B 耗时 | 速度 | git 协议 | 判定 |
|---|---|---|---|---|
| **`https://gh-proxy.com/`** | 6s | ≈283KB/s | ✅ 同一 HEAD | **采用** |
| `https://ghfast.top/` | 9s | ≈189KB/s | ✅ 同一 HEAD | 备选 |
| `https://ghproxy.net/` | 55s | ≈31KB/s | — | 偏慢 |
| `ghproxy.cn` / `ghproxy.link` / `gh.con.sh` | 只返回短响应体 | — | — | ✗ |
| 直连 github.com | 失败 | 0 | ✗ | ✗ |

**排查方法论（踩过两次同类错）**：判"通道能不能用"必须**两条判据同时成立** ——
① 下载**完整**（`curl` 返回码 0 / 字节数等于已知值 / 能解压）；② **哈希**等于可信基准。
只看状态码会把错误页判成"可用"；只看哈希但下载被超时截断，会把可用通道判成"不可用"。
且**测速必须串行** —— 并行请求会触发反代限流，返回短响应体 + 200，得出错误结论。

### 5.6 111 的 TLS 终端（443，2026-09-21 新增）

**用途**：让浏览器以 `https://` + `wss://` 访问。BrowserSkill 配对**必须** wss
（`internal/browserskill/manager.go:178-190`；上游 `.env.example:779`「远程部署必须使用
WSS（包括内网）」）。机制与排查详见 `my-docs/04-功能机制解析/WeKnora-BrowserSkill配对与WSS约束.md`。

| 项 | 值 |
|---|---|
| 实现 | `my-docker/tls/`（**独立编排** —— 刻意不并入 `my-docker/docker-compose.yml`，以免破坏其"官方副本可逐行比对"的性质） |
| 容器 | `weknora-tls`（`nginx:1.30.3-alpine`，`network_mode: host`） |
| 监听 | **443**，反代 `127.0.0.1:41200`（frontend）；**41200 原样保留** |
| 证书 | `/mnt/data/weknora-tls/`（自签 CA + 服务器证书；**不进 git**）。`bash my-docker/tls/gen-certs.sh` 幂等生成，`FORCE=1` 重建 |
| 启停 | `docker compose -f my-docker/tls/docker-compose.yml up -d` / `down` |
| 文档 | `my-docker/tls/README.md`（Mac 信任证书、验证、排查、回滚） |

> ⚠️ **刻意未开 HSTS**：自签证书场景下，一旦证书被取消信任，HSTS 会把浏览器锁死在 https，
> 连"退回直连 41200 排查"都做不到。
> ⚠️ **访问端必须导入 CA**：`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/weknora-ca.crt`
> —— 否则页面能开但 **wss 握手仍失败**（Chrome 对 WebSocket 的证书错误不给"继续访问"的机会）。

## 六、待办 / 注意事项

- [x] **✅ 生产已在跑二开代码（2026-09-20 23:57 完成）**：`./deploy/deploy-wkj-dev.sh build` 成功，
      耗时 15m57s。二进制内注入的 commit = `87bf42e4` = 111 上 `wkj-dev` 的 HEAD；
      迁移 `90 → 106`（`dirty=false`）；数据与基线逐项一致。详见 §5.5。
- [ ] **首次部署后建议做的加固**：把 `DISABLE_REGISTRATION` 改为 `true`（注册完管理员账号之后）。
- [ ] **备份策略**：目前数据只在 111 单机机械盘，`/mnt/data` 无备份。数据库（`weknora_postgres-data` 卷）应纳入备份。
- [ ] **`ops/hosts/nanning-111/services.md` 待登记**本服务（端口 41200/41201）。
- [ ] 110 的 Ollama 是单并发槽，若用其做 embedding，需留意与其它调用方的排队冲突。
- [ ] 111 上的代码克隆会落后于本机（`sync_code` 只在执行脚本时才对齐）——想知道线上是哪一版，直接
      `ssh nanning-111 "cd /mnt/data/weknora && git log --oneline -1"`。
