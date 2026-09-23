#!/usr/bin/env bash
# ==============================================================================
# WeKnora 生产部署脚本
#
#   部署分支：wkj-dev
#   部署目标：nanning-111 (10.168.1.111)  →  /mnt/data/weknora
#   代码中转：nanning-110 Gitea (10.168.1.110:13000) → wakeagent/WeKnora
#   对外入口：41200 = 官方前端(https) · 41280 = 定制前端(https) · 41201 = 后端 API(http)
#             https 入口由容器组内的 nginx 服务提供（配置在 my-docker/nginx/）；
#             两个前端容器**只绑宿主回环**（41211 / 41212）
#             ⇒ "没有 http 前端端口"是结构上的事实，不是约定。
#
# 用法：
#   ./deploy-wkj-dev.sh deploy      首次部署 / 完整部署（幂等，可重复执行）
#   ./deploy-wkj-dev.sh update      更新：推代码 → 拉取 → 重建容器
#   ./deploy-wkj-dev.sh sync        只同步代码到 111（**不碰容器**。注意：外置的 ./migrations
#                                   会随之更新，但 app 不重启 ⇒ 新迁移要等下次 app 启动才执行）
#   ./deploy-wkj-dev.sh up          只按当前编排重建容器（不 pull / 不 build）—— 改编排后用它生效，
#                                   重建 app 时新迁移随启动自动执行
#   ./deploy-wkj-dev.sh push-ui     构建前端并投递到 111（**无需重启**，立即可见）
#   ./deploy-wkj-dev.sh push-reader 同步代码并重启 docreader（Python 免编译，秒级）
#   ./deploy-wkj-dev.sh push-app    编译 app 并投递到 111（编译镜像；**首次启用会重建容器**）
#                                   一次动作同时更新「二进制 + 迁移」两样外置件
#   ./deploy-wkj-dev.sh build       二开构建：在 111 上构建镜像后重启
#   ./deploy-wkj-dev.sh status      查看容器状态
#   ./deploy-wkj-dev.sh logs [svc]  查看日志（默认 app）
#   ./deploy-wkj-dev.sh restart     重启容器
#   ./deploy-wkj-dev.sh health      健康检查
#   ./deploy-wkj-dev.sh compose-diff 复核站点容器组相对官方的定制面（防叠加层过期）
#   ./deploy-wkj-dev.sh shell       登录 111
#   ./deploy-wkj-dev.sh down        停止容器（保留数据）
#
# ★ 编排形态：**一个容器组** = 官方基底 + 我们的叠加层
#     -f docker-compose.yml（官方，一字不动）        ← 上游更新自动继承其变化
#     -f my-docker/docker-compose.overlay.yml        ← 我们的全部定制（唯一改动点）
#   两份合并后是同一个 project（weknora）、同一个容器组，一次 up -d 起停全部。
#   调用统一带 --project-directory（相对路径以第一个 -f 的目录为基准）。
#
# ★ 关键区分：deploy/update 用的是「官方预构建镜像」，build 才用「你的二开代码」
#   编排文件里每个服务同时写了 image: 与 build:，共用同一个 tag。
#     · pull  → 拉 registry 官方镜像，覆盖该 tag   ⇒ 源码改动**不生效**
#     · build → 在 111 上从源码构建，覆盖该 tag   ⇒ 源码改动生效
#   因此：只改前端/后端源码时，必须用 build；用 update 会把二开镜像换回官方镜像。
#   脚本已内置保护：检测到本地构建镜像时会**拒绝 pull 并自动改用 build**。
#   确实要回到官方镜像：WKJ_ALLOW_PULL_OVERWRITE=1 ./deploy-wkj-dev.sh update
#
# 设计原则：
#   - 幂等：任何命令重复执行结果一致，不破坏已有 .env / 数据卷
#   - 失败即停：set -euo pipefail；任一步失败立刻退出并给出提示
#   - 数据安全：.env 一旦存在就不再覆盖（内含生产密钥）
#   - 凭据不外泄：从本机 ~/.git-credentials 读取，不硬编码在脚本里
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------ 配置区
readonly BRANCH="wkj-dev"                       # ★ 部署分支（脚本名即由此而来）
readonly SSH_HOST="nanning-111"                 # ~/.ssh/config 中的别名
readonly REMOTE_DIR="/mnt/data/weknora"         # 111 上的部署目录（机械盘）
readonly GITEA_HOST="10.168.1.110:13000"        # 110 Gitea
readonly GITEA_REPO="wakeagent/WeKnora"         # 仓库路径
readonly GITEA_CRED_KEY="10.168.1.110%3a13000"  # ~/.git-credentials 中的匹配键
readonly FRONTEND_PORT=41200                    # 前端对外端口
readonly APP_PORT=41201                         # 后端对外端口
readonly HEALTH_TIMEOUT=420                     # 健康检查最长等待（秒），首次启动需建表

# ★ 部署形态：**一个容器组** = 官方基底 + 我们的叠加层。
#   基底是仓库根的官方 docker-compose.yml（一字不动 ⇒ 上游更新自动继承）；
#   叠加层是 my-docker/docker-compose.overlay.yml（我们的全部定制：新增
#   frontend-wkj / nginx 两个服务，并覆盖若干字段）。
#   两份 -f 合并后属于同一个 project（weknora）、同一个容器组。
#
#   --project-directory 指向仓库根是**必需**的：相对路径以**第一个 -f 的目录**
#   为基准；这里第一个就是仓库根的官方文件 ⇒ build.context / bind mount /
#   env_file 全部保持原语义，无需改任何相对路径。顺序也不能反。
readonly COMPOSE_BASE_REL="docker-compose.yml"
readonly COMPOSE_OVERLAY_REL="my-docker/docker-compose.overlay.yml"
# ★ 必须带 --profile searxng 与 --profile neo4j，否则 compose **不会**创建/启动
#   这两个组件 —— 它们在官方基底里分别是 `profiles: [searxng, full]` 与
#   `profiles: [neo4j, full]` 门控的（我们的 overlay 刻意**不声明** profiles，
#   正是为了继承这个门控：编排里写了它，也不等于无条件启动）。
#   加在 $DC 这一处即可覆盖全部子命令（up / build / pull / down / restart / logs …）。
#   注意：`$DC up -d <显式服务名>` 与 `$DC restart <服务>` 不受 profile 影响（显式指定即生效）；
#   受影响的是**不带服务名**的 up / down / ps 之类 —— 它们从此把这两个组件一并纳入。
readonly DC="docker compose --project-directory $REMOTE_DIR --env-file $REMOTE_DIR/.env --profile searxng --profile neo4j -f $REMOTE_DIR/$COMPOSE_BASE_REL -f $REMOTE_DIR/$COMPOSE_OVERLAY_REL"

# 颜色
readonly C_OK=$'\033[0;32m'; readonly C_ERR=$'\033[0;31m'
readonly C_WARN=$'\033[0;33m'; readonly C_INFO=$'\033[0;36m'; readonly C_OFF=$'\033[0m'

log()  { printf '%s[%s]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  ⚠%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s  ✘ %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }
step() { printf '\n%s──── %s ────%s\n' "$C_INFO" "$*" "$C_OFF"; }

# ------------------------------------------------------------------ 凭据读取
# 从本机 ~/.git-credentials 读取 110 Gitea 的凭据；不回显密码。
read_local_cred() {
  local f="$HOME/.git-credentials"
  [ -f "$f" ] || die "本机缺少 ${f}，无法获取 110 Gitea 凭据"
  local line
  line=$(grep -- "$GITEA_CRED_KEY" "$f" 2>/dev/null | head -1 || true)
  [ -n "$line" ] || die "在 $f 中找不到 $GITEA_CRED_KEY 的凭据条目"
  # 形如 http://user:pass@host:port  →  user:pass
  printf '%s' "$line" | sed -E 's|^https?://||; s|@.*$||'
}

# ------------------------------------------------------------------ 前置检查
preflight_local() {
  step "本机前置检查"
  command -v git >/dev/null || die "本机未安装 git"
  command -v ssh >/dev/null || die "本机未安装 ssh"

  local cur
  cur=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
  [ "$cur" = "$BRANCH" ] || die "当前分支为 ${cur}，但本脚本部署 ${BRANCH}；请先 git checkout $BRANCH"
  ok "当前分支：$cur"

  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    warn "本机存在未提交改动，推送的仍是已提交内容（未提交部分不会生效）"
  fi
  ok "本机检查通过"
}

preflight_remote() {
  step "111 远端前置检查"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" 'true' 2>/dev/null \
    || die "无法免密 SSH 到 ${SSH_HOST}（检查 ~/.ssh/config）"
  ok "SSH 免密连通"

  ssh -o ConnectTimeout=10 "$SSH_HOST" '
    set -e
    command -v docker >/dev/null || { echo "NODOCKER"; exit 1; }
    docker compose version >/dev/null 2>&1 || { echo "NOCOMPOSE"; exit 1; }
    [ -f /mnt/data/.mounted ] || { echo "NOMOUNT"; exit 1; }
    echo "OK"
  ' >/dev/null 2>&1 || die "111 环境检查失败（docker / compose / /mnt/data 挂载）"
  ok "docker + compose 可用，/mnt/data 已挂载"

  # 叠加层与官方基底都必须在位（一个容器组由这两份文件共同定义）
  ssh "$SSH_HOST" "test -f '$REMOTE_DIR/$COMPOSE_OVERLAY_REL' && test -f '$REMOTE_DIR/$COMPOSE_BASE_REL'" 2>/dev/null \
    || die "111 上缺少 $REMOTE_DIR/${COMPOSE_OVERLAY_REL}（或官方基底）—— 先跑一次 sync_code"
  ok "编排在位：${COMPOSE_BASE_REL}（基底） + ${COMPOSE_OVERLAY_REL}（叠加）"
}

# ------------------------------------------------------------------ 代码同步
# 1) 本地 → 110 Gitea（push）
# 2) 110 Gitea → 111（fetch/reset）
sync_code() {
  step "① 推送本地 $BRANCH → 110 Gitea"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push gitea110 "$BRANCH" 2>&1 | tail -5 \
    || die "推送失败（检查 remote gitea110 与凭据）"
  ok "已推送 $BRANCH"

  step "② 在 111 上拉取代码"
  local cred
  cred="$(read_local_cred)"

  # 确保 111 上有凭据（写进它自己的 credential store，供后续 fetch 复用）
  ssh "$SSH_HOST" "CRED='$cred' bash -s" <<'REMOTE_PREP'
set -e
if ! grep -q '10.168.1.110%3a13000' ~/.git-credentials 2>/dev/null; then
  mkdir -p ~ && umask 077
  echo "http://${CRED}@10.168.1.110%3a13000" >> ~/.git-credentials
  chmod 600 ~/.git-credentials
  echo "  （已在 111 上登记 Gitea 凭据）"
fi
git config --global credential.helper store 2>/dev/null || true
REMOTE_PREP

  ssh "$SSH_HOST" "BRANCH='$BRANCH' DIR='$REMOTE_DIR' REPO='http://$GITEA_HOST/$GITEA_REPO.git' bash -s" <<'REMOTE_SYNC'
set -e
if [ ! -d "$DIR/.git" ]; then
  echo "  首次部署：clone 到 $DIR"
  mkdir -p "$(dirname "$DIR")"
  GIT_TERMINAL_PROMPT=0 git clone --branch "$BRANCH" "$REPO" "$DIR"
else
  echo "  已存在仓库：fetch + 对齐到 origin/$BRANCH"
fi
cd "$DIR"

# ── 本地排除「后台编译产物」（用 .git/info/exclude，不改官方 .gitignore）──
# 为什么必需：push-app 会在**仓库内**生成这些 Rust 产物
#   third_party/anydoc-go/{target,lib,patched-anydoc}
# 而官方 .gitignore 未覆盖它们 ⇒ 工作区从此"看起来脏"
#   ⇒ 触发下方 reset 保护 ⇒ **每次都静默跳过代码同步**
#     （表现为"部署成功，但 111 上跑的还是旧代码"，极难排查）。
# 用 exclude 而非 .gitignore：它是**本地配置、不入库**，不需要改官方文件；
#   代价是别处 clone 后要自行补 —— 由本段幂等补齐，故无手工步骤。
mkdir -p .git/info
for _p in /third_party/anydoc-go/target/ \
          /third_party/anydoc-go/lib/ \
          /third_party/anydoc-go/patched-anydoc/ ; do
  grep -qxF "$_p" .git/info/exclude 2>/dev/null || echo "$_p" >> .git/info/exclude
done

# 保护：工作区有未提交改动时拒绝覆盖，避免静默丢失
if [ -n "$(git status --porcelain)" ]; then
  echo "  ⚠ 检测到服务器工作区有未提交改动："
  git status --short | head -10
  echo "  ⚠ 已跳过 reset（如需强制对齐，请手工处理或加 --force）"
else
  git fetch --prune origin "$BRANCH"
  git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH" "origin/$BRANCH"
  git reset --hard "origin/$BRANCH"
fi
cd "$DIR"
echo "  当前提交: $(git log --oneline -1)"
REMOTE_SYNC
  ok "111 代码已就位"
}

# ------------------------------------------------------------------ 环境文件
# 首次生成 .env（含随机密钥 + 端口）；已存在则绝不覆盖。
ensure_env() {
  step "③ 准备 .env（已存在则保留）"
  ssh "$SSH_HOST" "DIR='$REMOTE_DIR' FP='$FRONTEND_PORT' AP='$APP_PORT' bash -s" <<'REMOTE_ENV'
set -e
cd "$DIR"
if [ -f .env ]; then
  echo "  .env 已存在，保持不变（含生产密钥，不覆盖）"
  echo "  当前端口配置："
  grep -E '^(FRONTEND_PORT|APP_PORT|COMPOSE_PROJECT_NAME)=' .env | sed 's/^/    /' || true
  exit 0
fi
echo "  首次部署：生成 .env"

gen() { openssl rand -hex "$1"; }
DB_PW=$(gen 16); RD_PW=$(gen 16); JWT=$(gen 32); AES=$(gen 16); SIGN=$(gen 32)

# 以 .env.example 为模板（保留注释），替换/追加关键项
if [ -f .env.example ]; then cp .env.example .env; else touch .env; fi

setkv() {
  local k="$1" v="$2"
  if grep -q "^${k}=" .env; then
    # 用 | 作分隔符，避免密码中的特殊字符
    sed -i "s|^${k}=.*|${k}=${v}|" .env
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

setkv COMPOSE_PROJECT_NAME weknora
setkv DB_USER postgres
setkv DB_PASSWORD "$DB_PW"
setkv DB_NAME WeKnora
setkv REDIS_PASSWORD "$RD_PW"
setkv JWT_SECRET "$JWT"
setkv SYSTEM_AES_KEY "$AES"
setkv SYSTEM_SIGNING_KEY "$SIGN"
setkv DISABLE_REGISTRATION false
# 注意：FRONTEND_PORT 已被 my-docker/docker-compose.overlay.yml 用 `!override`
# 覆盖（前端容器只绑回环，对外端口由容器组内的 nginx 提供）。仍写入是为了兼容
# 官方 .env.example 模板；它的值**不影响实际对外端口**。
setkv FRONTEND_PORT "$FP"
setkv APP_PORT "$AP"
setkv STORAGE_TYPE local
setkv RETRIEVE_DRIVER postgres
setkv SSRF_WHITELIST "host.docker.internal,localhost,127.0.0.1,10.168.1.110,10.168.1.111"

chmod 600 .env
echo "  ✔ 已生成 .env（端口 ${FP}/${AP}，密钥随机生成）"
REMOTE_ENV
  ok ".env 就绪"
}

# ------------------------------------------------------------------ 容器编排
compose_up() {
  local mode="${1:-pull}"
  step "④ 启动容器（模式：${mode}）"
  ssh "$SSH_HOST" "DIR='$REMOTE_DIR' MODE='$mode' DC='$DC' ALLOW_OVERWRITE='${WKJ_ALLOW_PULL_OVERWRITE:-0}' bash -s" <<'REMOTE_UP'
set -e
cd "$DIR"

# ── 项目名校验（防「数据全没了」）───────────────────────────────────────
# 项目名决定数据卷名（weknora_postgres-data 等）。若它变成别的值（例如漏了
# --project-directory 时退化成目录名 my-docker），compose 会去创建一套**全新空卷**，
# 表现为「库里的数据全没了」——其实数据还在旧卷里。此处硬校验，不符即停。
PROJ=$(grep -m1 '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | cut -d= -f2- || true)
if [ "$PROJ" != "weknora" ]; then
  echo "  ✘ .env 中 COMPOSE_PROJECT_NAME=[${PROJ:-未设置}]，期望 weknora。"
  echo "    继续执行会指向另一套数据卷。请修正 $DIR/.env 后重试。"
  exit 1
fi

TAG=$(grep -m1 '^WEKNORA_VERSION=' .env 2>/dev/null | cut -d= -f2-); TAG=${TAG:-latest}

# ── 二开镜像保护 ──────────────────────────────────────────────────────
# docker-compose.yml 里每个服务同时写了 image: 和 build:，二者写的是**同一个 tag**：
#   · docker compose build → 本地构建，覆盖该 tag（二开代码生效）
#   · docker compose pull  → 拉 registry 官方镜像，同样覆盖该 tag
# 所以「先 build 二开、后 update(pull)」会把二开镜像**静默替换**回官方镜像，
# 表现为「代码改了、容器也重建了，但功能一点没变」——极难排查。
# 判据（2026-09-20 修正）：**不能用 RepoDigests 是否为空**。
#   本机 Docker 用 containerd 镜像存储：本地构建的单架构镜像，其 RepoDigests
#   就等于自己的镜像 ID（实测 tag 指向 sha256:f66721c1… 而 RepoDigests 也是
#   wechatopenai/weknora-app@sha256:f66721c1…）⇒ 用 RepoDigests 判"是否本地构建"
#   **恒为 false，保护会失效**。
# 改用「构建时登记的镜像 ID」做判据：`$DC build` 成功后把各镜像 ID 写入
#   .git/wkj-last-build（放在 .git 内 ⇒ 不污染工作区）。之后若 tag 仍指向
#   登记过的 ID，说明它还是我们构建的产物 → 拒绝 pull。
local_built=0
_marker="$DIR/.git/wkj-last-build"
for _img in wechatopenai/weknora-app wechatopenai/weknora-ui wechatopenai/weknora-ui-wkj; do
  _cur=$(docker image inspect "$_img:$TAG" --format '{{.Id}}' 2>/dev/null || echo missing)
  _rec=$(awk -v k="$_img:$TAG" '$1==k {print $2; exit}' "$_marker" 2>/dev/null || true)
  if [ -n "$_rec" ] && [ "$_cur" = "$_rec" ]; then
    local_built=1
    echo "  · 检测到本地构建镜像：$_img:${TAG}（ID 与构建登记一致，属二开产物）"
  fi
done

# ── 构建源自检：把「源配置错误」挡在 40 分钟构建之前 ──────────────────────
# 为什么必须有：实测踩过，且都是**构建末期**才暴露，白等 30+ 分钟：
#   ① APT_MIRROR 写成带 /debian 的完整路径，与 debian.sources 里已有的
#      /debian 拼成 /debian/debian → apt 404 → exit 100（本次实际踩到）
#   ② apt 的 404/证书类失败有**假成功**陷阱：`apt-get update -qq` 在索引
#      全被忽略时仍返回 0，install 才失败 —— 所以只看 update 的退出码会误判。
#   ③ 判断「https 源能不能用」必须以**实际使用该源的基镜像**为准：
#      docreader 两个阶段都是 python:3.10.18-bookworm（非 slim，自带 CA），
#      https 可用；而裸 debian:12.12-slim 无 CA，https 必失败。
#      ★ 用错基镜像做探测会得出相反结论（本次先误判为"必须用 http"）。
_check_url_ok() {
  local url="$1" name="$2" expect="${3:-}" final body
  # 必须**跟随重定向**再判：apt / npm / go 客户端都会跟随 302，
  # 只看第一跳会把可用源误判为不可用（我犯过一次）。
  final=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null || echo 000)
  if [ "$final" != "200" ]; then
    echo "    ✘ $name 不可用：跟随重定向后 HTTP $final"
    echo "        $url"
    return 1
  fi
  # 必须**校验内容**：只看状态码会误判 —— 源路径拼错时也可能返回 200 的错误页。
  # 对 apt 的 Release 文件校验发行版代号，才能真正证明「这个 URI 是有效的 apt 源」。
  if [ -n "$expect" ]; then
    body=$(curl -sL --max-time 12 "$url" 2>/dev/null | head -c 4096)
    case "$body" in
      *"$expect"*) ;;
      *) echo "    ✘ $name 内容异常：响应中未出现 '$expect'（源路径可能拼错）"
         echo "        $url"
         return 1 ;;
    esac
  fi
  echo "    ✔ $name 可用（200${expect:+，内容含 $expect}）"
  return 0
}

_preflight_build_sources() {
  local apt apk goproxy npm rc=0
  apt=$($DC config 2>/dev/null | awk '/^ *APT_MIRROR:/{print $2; exit}')
  apk=$($DC config 2>/dev/null | awk '/^ *APK_MIRROR_ARG:/{print $2; exit}')
  goproxy=$($DC config 2>/dev/null | awk '/^ *GOPROXY_ARG:/{print $2; exit}')
  npm=$($DC config 2>/dev/null | awk '/^ *NPM_REGISTRY:/{print $2; exit}')

  echo "  构建源自检（秒级；避免源配置问题拖到构建 30 分钟后才暴露）..."

  # ① 引导源：app 的 browserskill 与 final 阶段都是 **slim 基镜像、不自带 ca-certificates**，
  #    换到 https 源之前必须先装 CA，而那一步只能走官方源 ⇒ 官方源本身必须可达。
  #    （若这条不通，需把引导源也换成「不跳转到 https 的 http 国内源」，见文档 2.4.3 坑 4）
  _check_url_ok "http://deb.debian.org/debian/dists/bookworm/Release" "引导源 deb.debian.org" "Codename: bookworm" || rc=1

  # ② APT_MIRROR：docreader 两个阶段换源后的主源（值是「带 scheme 的 base、不含路径」）
  if [ -z "$apt" ]; then
    echo "    · APT_MIRROR 未设置 → docreader 走官方源（较慢但可靠）"
  else
    _check_url_ok "$apt/debian/dists/bookworm/Release" "APT_MIRROR" "Codename: bookworm" || rc=1
  fi

  # ③ APK_MIRROR_ARG：app 三个 apt 阶段换源后的主源。
  #    ★ 该值只给**主机名**（sed 只替换主机名），故此处补 scheme 才能探测；
  #    若误填成含 /debian 的完整 URL，会与源里已有的 /debian 拼成 /debian/debian
  #    → 404（内容校验会拦住，不会放过）。
  if [ -z "$apk" ]; then
    echo "    · APK_MIRROR_ARG 未设置 → app 三个 apt 阶段走官方源"
  else
    _check_url_ok "http://${apk#*://}/debian/dists/bookworm/Release" "APK_MIRROR_ARG" "Codename: bookworm" || rc=1
  fi

  [ -n "$goproxy" ] && { _check_url_ok "${goproxy%%,*}" "GOPROXY" || rc=1; }
  [ -n "$npm" ]     && { _check_url_ok "$npm" "NPM_REGISTRY" || rc=1; }

  if [ "$rc" != "0" ]; then
    echo ""
    echo "    ✘ 构建源自检未通过，已中止（避免白等 30+ 分钟）。"
    echo "      覆盖方式：编辑 $DIR/.env 里的"
    echo "        APT_MIRROR / APK_MIRROR_ARG / GOPROXY_ARG / NPM_REGISTRY"
    echo "      后重试；参数取值语义见 my-docker/docker-compose.overlay.yml 文件头。"
    exit 1
  fi
}

# ── 预置构建产物：把「本网络下载不稳」的依赖先备好 ────────────────────────
# 为什么需要：111（及本机）能访问 GitHub Releases，但很慢且会中断
#   （实测 ~40KB/s；构建里 curl 无重试 ⇒ 报 exit 18 传输中断）。
# 为什么用预置而不是换镜像源：
#   · Dockerfile.docreader 本来就带离线分支（第 31 行 COPY packages/ → 第 52 行
#     `if [ -f /app/packages/${PROTOC_PACKAGE} ]` 走离线安装）⇒ 预置即用，
#     **官方 Dockerfile 一个字都不用改**，也不引入第三方 GitHub 反代
#     （避免把生产镜像的二进制信任交给不可控的第三方）。
# 完整性：sha256 经**三条独立路径交叉验证**（本机 Mac / 110 / 111 各自下载，
#   哈希完全一致 1699853 字节）。表里的哈希即校验基准。
# 幂等：文件在位且哈希正确就跳过；否则重下。写入 .git/info/exclude 保持工作区
#   干净（sync_code 用 git status 判断能否安全 reset）。
declare -A BUILD_ARTIFACTS=(
  ["packages/protoc-3.19.4-linux-x86_64.zip"]="https://github.com/protocolbuffers/protobuf/releases/download/v3.19.4/protoc-3.19.4-linux-x86_64.zip|058d29255a08f8661c8096c92961f3676218704cbd516d3916ec468e139cbd87"
)

_ensure_build_artifacts() {
  local rel entry url want cur
  echo "  预置构建产物（走离线分支，免受网络抖动影响）..."
  for rel in "${!BUILD_ARTIFACTS[@]}"; do
    entry="${BUILD_ARTIFACTS[$rel]}"
    url="${entry%%|*}"
    want="${entry##*|}"

    mkdir -p "$(dirname "$rel")"
    grep -qxF "/$rel" .git/info/exclude 2>/dev/null || echo "/$rel" >> .git/info/exclude

    if [ -f "$rel" ] && [ "$(sha256sum "$rel" | awk '{print $1}')" = "$want" ]; then
      echo "    ✔ 已就绪且校验通过：$rel"
      continue
    fi

    echo "    ↓ 下载 ${rel}（本网络较慢，可能需 1-2 分钟）"
    curl -fL --retry 6 --retry-all-errors --retry-delay 3 -C - --max-time 900 -o "$rel" "$url" \
      || { echo "    ✘ 下载失败：$url"; exit 1; }

    cur=$(sha256sum "$rel" | awk '{print $1}')
    if [ "$cur" != "$want" ]; then
      echo "    ✘ 哈希校验失败"
      echo "      期望 $want"
      echo "      实得 $cur"
      exit 1
    fi
    echo "    ✔ 已下载并校验通过：$rel"
  done
}

# 构建时注入版本信息，使「跑的是哪一版」可查证。
# 生效链路：compose 的 build.args → Dockerfile.app builder 阶段的 ENV
#   → Makefile:256-259 从环境变量取 → ldflags -X 写进二进制
#   → GET /api/v1/system/info 的 commit_id 可直接读。
# 同时喂给前端的 VITE_FRONTEND_COMMIT（系统信息页会显示）。
_build_with_version() {
  WKJ_BUILD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  # ★ 去掉 tag 的 `v` 前缀（2026-09-22）：前端「UI 版本」取自 package.json 的
  #   `version`（`0.8.0`，官方不带 v），而后端 Version 取自 tag 名（`v0.8.0`）
  #   ⇒ 系统信息页用 `systemInfo.version !== frontendVersion` 判断，必然判为
  #     "与应用版本不一致"（**误报**，与 commit 位数无关）。
  #   统一为无 v 口径即可消除。前端那侧不能动（逐字副本），故从后端侧对齐。
  WKJ_BUILD_VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
  [ -n "$WKJ_BUILD_VERSION" ] || WKJ_BUILD_VERSION="$BRANCH"
  WKJ_BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  export WKJ_BUILD_COMMIT WKJ_BUILD_VERSION WKJ_BUILD_TIME
  export VITE_FRONTEND_COMMIT="$WKJ_BUILD_COMMIT"
  echo "  注入版本信息：version=$WKJ_BUILD_VERSION commit=$WKJ_BUILD_COMMIT"
  _preflight_build_sources
  _ensure_build_artifacts
  $DC build
  # 登记本次构建的镜像 ID，供后续「二开镜像保护」判断 tag 是否已被 pull 覆盖
  # （放在 .git 内 ⇒ 不污染工作区；判据修正原因见 compose_up 里的说明）
  _marker="$DIR/.git/wkj-last-build"
  : > "$_marker"
  for _img in wechatopenai/weknora-app wechatopenai/weknora-ui wechatopenai/weknora-docreader wechatopenai/weknora-ui-wkj; do
    _id=$(docker image inspect "$_img:$TAG" --format '{{.Id}}' 2>/dev/null || true)
    [ -n "$_id" ] && printf '%s:%s %s\n' "$_img" "$TAG" "$_id" >> "$_marker"
  done
  echo "  已登记本次构建的镜像 ID（.git/wkj-last-build）"
}

if [ "$MODE" = "build" ]; then
  echo "  构建镜像（二开模式，耗时较长，可能 20-40 分钟）..."
  _build_with_version
elif [ "$MODE" = "up" ]; then
  # 只按当前编排重建容器：不 pull、不 build。
  # 用于「改了编排 / 投递了产物」后让改动生效 —— compose 只会重建
  # config-hash 真正变了的服务（例如应用代码外置后只需重建 frontend-wkj 与 docreader，
  # app 的编排没变就不会被动到 ⇒ 也不会触发数据库迁移）。
  echo "  up 模式：跳过 pull / build，只按当前编排重建容器"
elif [ "$local_built" = "1" ] && [ "${ALLOW_OVERWRITE:-0}" != "1" ]; then
  echo ""
  echo "  ⚠ 已阻止 pull —— 111 上存在本地构建的二开镜像。"
  echo "    pull 会把它们静默替换为官方镜像，导致「代码改了但功能没变」。"
  echo "    现自动改用 build 模式。若确实要回到官方镜像，请加："
  echo "        WKJ_ALLOW_PULL_OVERWRITE=1 ./deploy-wkj-dev.sh update"
  echo ""
  _build_with_version
else
  echo "  拉取镜像（--quiet 模式；首次约 5-10 分钟，请耐心等待）..."
  $DC pull --quiet
fi

# ── 知识图谱：容器组已含 neo4j，但「容器起来」≠「功能开启」──────────────
# 功能开关是 .env 的 NEO4J_ENABLE（由 app 读取，见官方 compose 的 app.environment
# 与 .env.example 的 J 段说明）。这里确保 .env 里图谱配置齐备。
# ★ **缺键才补，已有键一律不覆盖** —— 与整个 .env 的纪律一致（内含生产密钥），
#   因此本段幂等，且不会抹掉人工改成 false 的开关。
# ★ 必须在**第一条 up 之前**：environment 变更要靠**重建**容器才生效，
#   `docker compose restart` 不会重新加载 .env（已知坑，见 AGENTS.md 的数据安全段）。
# ★ NEO4J_PASSWORD 必须在此刻定稿：官方默认是弱口令 password；且 Neo4j 把账号
#   存在自己的数据卷里 —— 卷初始化之后再改 .env 里的密码**不会**同步过去，
#   表现为 app 连不上（认证失败）。所以首次就写随机值。
if ! grep -q '^NEO4J_ENABLE=' .env; then
  printf 'NEO4J_ENABLE=true\n' >> .env
  echo "  + .env 补上 NEO4J_ENABLE=true（此前未设置；容器组已含 neo4j）"
fi
if ! grep -q '^NEO4J_PASSWORD=' .env; then
  _neo_pw=$(openssl rand -hex 16 2>/dev/null || od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
  printf 'NEO4J_PASSWORD=%s\n' "$_neo_pw" >> .env
  echo "  + .env 补上随机 NEO4J_PASSWORD（不用官方默认的弱口令 password）"
fi

# ── 知识图谱存储（neo4j）：**必须在 app 之前起** ──────────────────────
# 与 searxng 同款：官方基底里是 `profiles: [neo4j, full]` 门控，靠 $DC 上的
# `--profile neo4j` 才纳入本容器组；同样**必须显式点名**启动（不带服务名的 up
# 不会创建 profile 门控服务）。
# ★ **顺序是硬约束，不是偏好**：app 的 initNeo4jClient()
#   （internal/container/container.go，函数体见"重试 30 次 × 2s"那段）
#   在 NEO4J_ENABLE=true 时会 VerifyAuthentication，**重试 30 次 × 2 秒后仍失败
#   即返回 error ⇒ app 启动失败**。所以 neo4j 必须先起来并监听 7687。
# ★ 宿主端口 41292(Browser UI) / 41293(Bolt) **只绑回环**，仅用于宿主侧诊断；
#   app 走容器网络 `bolt://neo4j:7687`，与本步无关（见 overlay 的 neo4j 段）。
# ★ 数据落在命名卷 neo4j-data ⇒ `down`（不带 -v）不会伤数据。
echo "  启动知识图谱存储（neo4j）..."
$DC up -d neo4j

# 等 neo4j 监听 7687。用 bash 内建 /dev/tcp 探测，不依赖镜像里是否有 curl/nc。
# 首次初始化数据库通常 20-40s；app 侧重试窗口为 60s。
_neo_ok=0
for _i in $(seq 1 30); do
  if docker exec WeKnora-neo4j bash -c 'exec 3<>/dev/tcp/127.0.0.1/7687' 2>/dev/null; then
    _neo_ok=1
    break
  fi
  sleep 2
done
if [ "$_neo_ok" = "1" ]; then
  echo "  ✔ neo4j 已监听 7687"
else
  echo "  ⚠ neo4j 在 60s 内未监听 7687 —— app 侧仍会自行重试；若 app 起不来请查："
  echo "      $DC logs --tail=50 neo4j"
fi

# ── 阶段一：基础设施 + 后端（不含 frontend）──────────────────────────
# 为什么分两阶段：frontend 有 depends_on: app(healthy)。app 首次启动要在
# 机械盘上建 70 张表，耗时可能超过 compose healthcheck 的
# start_period(60s) + retries(3)×interval(30s) 窗口 → app 被判 unhealthy
# → frontend 依赖检查失败并**停在 Created 不再重试**（compose 的固有行为）。
# 因此先起后端、等它就绪，再起前端。
echo "  启动基础设施与后端（postgres / redis / docreader / app）..."
$DC up -d postgres redis docreader app

echo "  等待后端就绪（首次需建库表，最长 600s）..."
_w=0
until [ "$(docker inspect WeKnora-app --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; do
  _w=$((_w+5))
  if [ "$_w" -ge 600 ]; then
    echo "  ✘ 后端 600s 内未就绪，最近日志："
    $DC logs --tail=30 app
    exit 1
  fi
  sleep 5
done
echo "  ✔ 后端已就绪（用时 ${_w}s）"

echo "  启动前端与接入层..."
# nginx 依赖两个前端（同一个容器组内 depends_on 才生效）；
# 前端容器只绑回环，对外入口（443 / 41200 / 41280）全部由 nginx 提供。
$DC up -d frontend frontend-wkj nginx

# ── 自带搜索（searxng）────────────────────────────────────────────────
# 官方基底里 searxng / searxng-init 是 `profiles: [searxng, full]` 门控的，
# 靠 $DC 上的 `--profile searxng` 才纳入本容器组。
# ★ 为什么必须**显式点名**启动：不带服务名的 up 不会创建 profile 门控服务，
#   而这里前面两条 up 都是显式点名，漏掉它就会「编排里写了、实际没起」。
# ★ 依赖由 compose 自动满足：searxng 的 depends_on 是
#   searxng-init(completed_successfully) —— 它先把 settings.yml 模板拷进命名卷。
echo "  启动自带搜索（searxng）..."
$DC up -d searxng

# ★ settings.yml 的生效链路有**两个**坑，必须一起防（2026-09-22 实测踩全）：
#   ① searxng-init（oneshot）只在**被重建**时才把模板拷进命名卷；
#      而 compose 的 config-hash **只覆盖挂载路径、不含文件内容**
#      ⇒ 改了内容时 init 可能不重建，卷里仍是旧文件。
#   ② searxng **只在进程启动时**读 /etc/searxng/settings.yml
#      ⇒ 卷更新了但不重启进程，同样白搭（实测：卷与新宿主文件 sha256 完全一致，
#        但 searxng 仍是 6 分钟前启动的进程，跑的是旧引擎集 ⇒ 搜索 0 结果）。
#   所以要**分别**判两件事：卷内容对不对、进程是否已加载它。
SX_HOST_F="$DIR/my-docker/searxng/settings.yml"
if [ -f "$SX_HOST_F" ]; then
  # 一次容器调用同时取：卷内文件的 sha256 与 mtime
  _sx_meta=$(docker run --rm -v weknora_searxng_config:/c busybox:1.36 \
      sh -c 'sha256sum /c/settings.yml; stat -c %Y /c/settings.yml' 2>/dev/null)
  _v=$(printf '%s\n' "$_sx_meta" | awk 'NR==1{print $1}')
  _vt=$(printf '%s\n' "$_sx_meta" | awk 'NR==2{print $1}')
  _h=$(sha256sum "$SX_HOST_F" 2>/dev/null | cut -d' ' -f1)

  # 判据 A：卷内容 vs 宿主内容
  if [ -n "$_h" ] && [ "$_h" != "$_v" ]; then
    echo "  检测到 settings.yml 内容变化 ⇒ 同步进命名卷"
    if ! docker run --rm \
         -v weknora_searxng_config:/c \
         -v "$SX_HOST_F":/src/settings.yml:ro \
         busybox:1.36 sh -c 'cp /src/settings.yml /c/settings.yml && chmod 0644 /c/settings.yml' \
         >/dev/null 2>&1; then
      echo "  ⚠ 同步失败（busybox:1.36 是否存在于 111？）⇒ searxng 配置可能仍是旧的"
    fi
    # 同步后 mtime 变了，用"当下"作为基准
    _vt=$(date +%s)
  fi

  # 判据 B：searxng 进程是否在「卷内文件最后一次修改」之后启动过
  _st=$(date -d "$(docker inspect WeKnora-searxng --format '{{.State.StartedAt}}' 2>/dev/null)" +%s 2>/dev/null || echo 0)
  if [ "${_vt:-0}" -gt "${_st:-0}" ]; then
    echo "  searxng 尚未加载当前 settings.yml（进程启动于文件更新之前）⇒ 重启"
    $DC restart searxng >/dev/null
    echo "  ✔ 已重启 searxng"
  fi
else
  echo "  ⚠ 找不到 $SX_HOST_F ⇒ 跳过 searxng 配置同步（searxng 将使用卷中的旧配置）"
fi

echo ""
$DC ps --format 'table {{.Name}}\t{{.Status}}'
REMOTE_UP
  ok "容器已启动"
}

# ------------------------------------------------------------------ 迁移一致性
# 外置迁移的**全部意义**是「一次 push-app / up = 新二进制 + 新迁移」，所以必须
#   核到实际生效，而不是只看文件拷没拷过去。两道判据：
#     ① 容器内迁移文件名 = 仓库（挂载是否真的指到了更新后的目录）
#     ② 库版本 = 文件最高版本（迁移器是否真的跑了）—— 这是"跑没跑"的唯一证据
#   ★ 为什么必须查：迁移器失败时 AUTO_MIGRATE 只 warn 不退出（container.go），
#     app 照常 healthy ⇒ 「服务正常」完全掩盖「迁移没跑」。2026-09-22 就因为
#     容器内停在 000108 而新代码要读 000109 的列，差点让所有会话查询报错。
check_migrations() {
  local repo_latest ctr_latest db_ver
  repo_latest="$(basename "$(ls "$REPO_ROOT"/migrations/versioned/*.up.sql | sort | tail -1)" | cut -d_ -f1)"
  ctr_latest="$(ssh "$SSH_HOST" "docker exec WeKnora-app sh -c 'ls /app/migrations/versioned/*.up.sql 2>/dev/null | sort | tail -1'" 2>/dev/null \
                | tr -d '\r' | xargs -n1 basename 2>/dev/null | cut -d_ -f1)"
  printf '  仓库最新迁移: %s\n  容器内最新:   %s\n' "${repo_latest:-?}" "${ctr_latest:-取不到}"
  if [ -n "$ctr_latest" ] && [ "$repo_latest" = "$ctr_latest" ]; then
    ok "外置迁移已同步（容器内 = 仓库）"
  else
    warn "外置迁移未同步：仓库 ${repo_latest:-?} / 容器内 ${ctr_latest:-取不到}"
    log  "  查 111 的 $REMOTE_DIR/migrations（sync_code 的 reset 可能被跳过）"
  fi

  db_ver="$(ssh "$SSH_HOST" "cd $REMOTE_DIR && set -a && . ./.env && set +a && docker exec -e PGPASSWORD=\"\$DB_PASSWORD\" WeKnora-postgres psql -U \"\$DB_USER\" -d \"\$DB_NAME\" -Atc \"SELECT version||'/'||dirty FROM schema_migrations\"" 2>/dev/null | tr -d '\r' | tail -1)"
  if [ -z "$db_ver" ]; then
    warn "取不到库迁移版本（postgres 未起或 .env 变量缺失）"
  elif [ -n "$repo_latest" ] && [ "$((10#${db_ver%%/*}))" -eq "$((10#${repo_latest}))" ] 2>/dev/null; then
    ok "库迁移版本 = ${db_ver}（与文件最高版本一致 ⇒ 已执行）"
  else
    warn "库迁移版本 ${db_ver} ≠ 文件最高版本 ${repo_latest} ⇒ 迁移可能未执行"
    log  "  证据：$DC logs app | grep -i 'migration version'"
  fi
}

# ------------------------------------------------------------------ 健康检查
health_check() {
  step "⑤ 健康检查"
  local i=0
  local url_app="http://10.168.1.111:${APP_PORT}/health"
  local url_fe="https://10.168.1.111:${FRONTEND_PORT}/（官方前端）"
  local url_wkj="https://10.168.1.111:41280/（定制前端）"

  log "等待后端就绪（最长 ${HEALTH_TIMEOUT}s，首次启动需建库表）..."
  while [ $i -lt "$HEALTH_TIMEOUT" ]; do
    if ssh "$SSH_HOST" "curl -fsS --max-time 5 http://localhost:${APP_PORT}/health" >/dev/null 2>&1; then
      ok "后端健康检查通过（用时 ${i}s）"
      break
    fi
    i=$((i+5)); sleep 5
    [ $((i % 30)) -eq 0 ] && log "  ...已等待 ${i}s"
  done
  [ $i -lt "$HEALTH_TIMEOUT" ] || {
    warn "后端在 ${HEALTH_TIMEOUT}s 内未通过健康检查，最近日志："
    ssh "$SSH_HOST" "$DC logs --tail=30 app" || true
    die "健康检查失败"
  }

  # 前端兜底：若停在 Created（历史遗留的 depends_on 失败态），主动拉起
  local fe_state
  fe_state=$(ssh "$SSH_HOST" "docker inspect WeKnora-frontend --format '{{.State.Status}}'" 2>/dev/null || echo "missing")
  if [ "$fe_state" != "running" ]; then
    warn "前端容器状态为 ${fe_state}，尝试拉起..."
    ssh "$SSH_HOST" "$DC up -d frontend frontend-wkj nginx" >/dev/null 2>&1 || true
    sleep 3
  fi

  # 接入层：两个前端的**对外 https 入口全靠它**，必须确认在跑
  local ng_state c_off c_wkj
  ng_state=$(ssh "$SSH_HOST" "docker inspect weknora-nginx --format '{{.State.Status}}'" 2>/dev/null || echo "missing")
  if [ "$ng_state" = "running" ]; then
    c_off=$(ssh "$SSH_HOST" "curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://localhost:${FRONTEND_PORT}/" 2>/dev/null || echo "000")
    c_wkj=$(ssh "$SSH_HOST" "curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://localhost:41280/" 2>/dev/null || echo "000")
    [ "$c_off" = "200" ] && ok "官方前端 https://…:${FRONTEND_PORT} → 200" || warn "官方前端返回 HTTP $c_off"
    [ "$c_wkj" = "200" ] && ok "定制前端 https://…:41280 → 200" || warn "定制前端返回 HTTP $c_wkj"
  else
    warn "接入层 weknora-nginx 未运行（状态 ${ng_state}）⇒ 对外 https 入口不可用"
    log  "  启动：ssh $SSH_HOST 'cd $REMOTE_DIR && $DC up -d nginx'"
  fi

  # 自带搜索（searxng）：profile 门控组件，最容易被「编排里写了但没起」蒙过去
  local sx_state sx_code sx_n
  sx_state=$(ssh "$SSH_HOST" "docker inspect WeKnora-searxng --format '{{.State.Status}}'" 2>/dev/null || echo "missing")
  if [ "$sx_state" = "running" ]; then
    # 走宿主回环端口（overlay 默认 41291，只绑 127.0.0.1）。
    # 带 UA：searxng 的 botdetection 对空 UA 可能直接拒绝。
    # ★ 不要写 `|| echo "000"` —— curl 的 -w 失败时**已经输出** 000，
    #   再叠一次会得到 "000000"（本脚本实际踩过）。
    sx_code=$(ssh "$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -A 'Mozilla/5.0' 'http://127.0.0.1:41291/search?q=weknora&format=json'" 2>/dev/null)
    sx_code=${sx_code:-000}
    # ★ 光有 200 不算通：searxng 在引擎全不可达时**仍返回 200，只是 results 为空**
    #   （2026-09-22 实测：默认引擎在国内网络全挂）。判据必须是「有结果」。
    if [ "$sx_code" = "200" ]; then
      sx_n=$(ssh "$SSH_HOST" "docker exec weknora-nginx wget -q -O - --timeout=25 'http://searxng:8080/search?q=weknora&format=json' 2>/dev/null | grep -o '\"url\":' | wc -l" 2>/dev/null)
      sx_n=${sx_n:-0}
      if [ "$sx_n" -gt 0 ]; then
        ok "自带搜索 searxng → 200，命中 ${sx_n} 条结果（容器内 http://searxng:8080）"
      else
        warn "searxng 返回 200 但**结果为空** ⇒ 多为引擎不可达（看：$DC logs searxng）"
      fi
    else
      warn "searxng 在跑，但搜索接口返回 HTTP ${sx_code}（看日志：$DC logs searxng）"
    fi
  else
    warn "searxng 未运行（状态 ${sx_state}）⇒ 网络搜索 Provider 不可用"
    log  "  启动：ssh $SSH_HOST 'cd $REMOTE_DIR && $DC up -d searxng'"
  fi

  # 知识图谱存储（neo4j）：同样是 profile 门控组件；且它是 app 的**前置依赖**
  # （见 compose_up 段：initNeo4jClient 重试 30×2s，全失败即 app 起不来）。
  local neo_state neo_bolt neo_flag
  neo_state=$(ssh "$SSH_HOST" "docker inspect WeKnora-neo4j --format '{{.State.Status}}'" 2>/dev/null || echo "missing")
  if [ "$neo_state" = "running" ]; then
    # 判据取 **Bolt 7687 可连**（app 实际走的就是它），而不是 Browser UI 的 HTTP。
    # 用 nginx 容器内的 busybox `nc` 探（alpine 自带；不必给 neo4j 镜像装工具）。
    if ssh "$SSH_HOST" "docker exec weknora-nginx nc -z -w 5 neo4j 7687" >/dev/null 2>&1; then
      # ★「容器在跑」≠「功能已开」：真正的开关是 .env 的 NEO4J_ENABLE（app 侧读取）。
      neo_flag=$(ssh "$SSH_HOST" "grep -m1 '^NEO4J_ENABLE=' '$REMOTE_DIR/.env' 2>/dev/null | cut -d= -f2-" 2>/dev/null)
      if [ "$neo_flag" = "true" ]; then
        ok "知识图谱 neo4j → Bolt 7687 可连，且 NEO4J_ENABLE=true（功能已开启）"
      else
        warn "neo4j 在跑、7687 可连，但 .env 的 NEO4J_ENABLE=[${neo_flag:-未设置}] ⇒ 图谱功能仍关闭"
      fi
    else
      warn "neo4j 在跑，但 Bolt 7687 从容器网络连不上（看日志：$DC logs neo4j）"
    fi
  else
    warn "neo4j 未运行（状态 ${neo_state}）⇒ 知识图谱不可用"
    log  "  启动：ssh $SSH_HOST 'cd $REMOTE_DIR && $DC up -d neo4j'"
  fi

  # 迁移一致性（外置迁移的必查项 —— 见 check_migrations 的说明）
  check_migrations

  printf '\n'
  printf '%s╭─────────────────────────────────────────────────────────────╮%s\n' "$C_OK" "$C_OFF"
  printf '%s│  部署完成%s                                                    │\n' "$C_OK" "$C_OFF"
  printf '%s╰─────────────────────────────────────────────────────────────╯%s\n' "$C_OK" "$C_OFF"
  printf '   官方前端 : %s%s%s\n' "$C_INFO" "$url_fe" "$C_OFF"
  printf '   定制前端 : %s%s%s\n' "$C_INFO" "$url_wkj" "$C_OFF"
  printf '   后端 API : %s%s%s\n' "$C_INFO" "$url_app" "$C_OFF"
  printf '   自带搜索 : %s%s%s\n' "$C_INFO" "searxng（Provider 填 http://searxng:8080）" "$C_OFF"
  printf '   部署目录 : 111:%s\n' "$REMOTE_DIR"
  printf '   部署分支 : %s%s%s\n' "$C_INFO" "$BRANCH" "$C_OFF"
  printf '   查看日志 : %s%s logs%s\n' "$C_INFO" "$0" "$C_OFF"
}

# ------------------------------------------------------------------ 子命令
cmd_deploy() { preflight_local; preflight_remote; sync_code; ensure_env; compose_up pull; health_check; }
cmd_update() { preflight_local; sync_code; ensure_env; compose_up pull; health_check; }
# 只同步代码，不碰容器。用于「改了脚本 / 文档，但不想让容器重建」的场景 ——
# 重建 app 容器会触发数据库自动迁移（AUTO_MIGRATE 默认开且失败不阻断），
# 详见 my-docs/11-数据安全与备份/WeKnora-数据安全与备份方案.md §2.3。
cmd_sync()   { preflight_local; sync_code; }

# 只按当前编排重建容器（不 pull、不 build）。改了编排 / 投递了产物后用它生效。
# 例：应用代码外置的挂载第一次生效 —— 只需重建 frontend-wkj 与 docreader，
# 而 app 的编排没变 ⇒ 不会重建它 ⇒ **也不会触发数据库迁移**。
cmd_up()     { preflight_local; sync_code; ensure_env; compose_up up; health_check; }

# ── 应用代码外置：投递命令（配合 overlay 里的 volumes 挂载）
# 思路：日常改动不必重建镜像 / 容器 —— 编译产物直接落到 111 的映射目录即可。
# 背景与边界见 my-docs/12-应用代码外置/WeKnora-应用代码外置方案.md
cmd_push_ui() {
  step "① 构建定制前端（本地）"
  local fe="$REPO_ROOT/my-frontend"
  [ -f "$fe/package.json" ] || die "找不到 $fe/package.json"
  if [ ! -d "$fe/node_modules" ]; then
    echo "  首次运行：安装依赖（npm ci，较慢）"
    ( cd "$fe" && npm ci ) || die "npm ci 失败"
  fi
  # 显式注入 commit（vite.config.ts 的 resolveFrontendCommit 也会回落到
  # `git rev-parse --short HEAD`，但显式传更确定，不依赖 cwd/环境）。
  # 产物里会带 `w="<7位>"`，用于验证「111 上跑的到底是哪一版」。
  ( cd "$fe" && VITE_FRONTEND_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD)" npm run build ) \
    || die "前端构建失败（npm run build）"
  [ -d "$fe/dist" ] || die "构建未见产物：$fe/dist"
  ok "已构建（$(du -sh "$fe/dist" | cut -f1)）"

  step "② 投递到 111 的映射目录"
  ssh "$SSH_HOST" "mkdir -p '$REMOTE_DIR/my-frontend/dist'"
  # --delete 保证与本地 dist 严格一致（清掉旧的 hash 资源）；
  #   ★ exclude config.js —— 它由容器 entrypoint 在启动时生成，本地 dist 里没有，
  #     若被删掉则页面加载会 404，而容器不会自动重建它。
  # 不用 -a：本地是 macOS 用户，保留 owner/group 会在 111 上触发无权限 chown。
  rsync -rlpt --delete --exclude=config.js \
    "$fe/dist/" "$SSH_HOST:$REMOTE_DIR/my-frontend/dist/"
  ok "已投递 ⇒ **立即可见，无需重启容器**（内层 nginx 直接读文件）"

  step "③ 自证：容器内看到的文件数"
  ssh "$SSH_HOST" "docker exec WeKnora-frontend-wkj sh -c 'ls /usr/share/nginx/html | wc -l'" \
    | sed 's/^/  容器内条目数：/'
}

cmd_push_reader() {
  # docreader 是 Python（解释型）⇒ 真·"换文件即生效"：源码同步后重启容器即可。
  sync_code
  step "重启 docreader（加载新源码）"
  ssh "$SSH_HOST" "$DC restart docreader"
  ok "已重启 docreader（秒级）"
}

cmd_push_app() {
  # 编译 app 并投递到映射目录，再让 app 加载它。
  #   —— 不重建镜像；**首次启用**会重建一次容器（挂载在容器创建时固定，restart 不生效）。
  # ★ 一次 push-app 同时更新**两样**外置件：
  #     ① 二进制 .build/WeKnora（本函数编译投递）
  #     ② 迁移文件 ./migrations（由 sync_code 的 git reset 提供，无需投递动作）
  #   ⇒ 官方新迁移随本次动作生效，不必重建镜像。详见 overlay 的 app 段注释。
  #
  # ★ 为什么用「编译镜像」而不是 docker build 全流程：
  #   现有 build 要走 browserskill + builder + final + 镜像 commit + 容器重建；
  #   这里只做 builder 那一步的产物，直接落映射目录。
  #   耗时主要两项：① Rust 侧 anydoc 静态库（首次真编译，之后 target/ 增量复用）
  #   ② Go 全量编译。两者都靠挂载出来的缓存目录复用，稳态为分钟级。
  #
  # ★ 为什么不在 111 宿主上编译：
  #   宿主 Ubuntu 24.04 是 glibc 2.39，容器是 debian:12.12-slim（2.36）；
  #   cgo 二进制与 glibc 强绑定 ⇒ 宿主产物在容器里 `GLIBC_2.38 not found`（已实测）。
  #   编译镜像与 final 镜像同为 Debian 12 ⇒ 产物需求 GLIBC_2.34，可用。
  local img="weknora-app-builder:wkj"
  preflight_local
  sync_code

  step "① 在 111 上编译 app（编译镜像，与 final 镜像同 glibc 基线）"
  ssh "$SSH_HOST" \
      "DIR='$REMOTE_DIR' IMG='$img' \
       V='$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')' \
       C='$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD)' \
       T='$(date -u +%Y-%m-%dT%H:%M:%SZ)' \
       G='go1.26.8' bash -s" <<'REMOTE_APP_BUILD'
set -e
cd "$DIR"
mkdir -p .build

# 编译镜像：**每次都 build**（Dockerfile 改了就应重建，而层缓存会让它很快）。
# ★ 早先写成「镜像存在就跳过」，会导致改了 Dockerfile 却不重建、继续用旧镜像 ——
#   典型的静默失效（本次就因为漏了 `sparse+` 前缀而踩到）。
# ★ context 用 my-docker/（而非仓库根）—— 本 Dockerfile 不 COPY 任何文件，
#   没必要把整个仓库发给 BuildKit；cd 进去还能消除 -f 路径的相对基准歧义。
( cd "$DIR/my-docker" && docker build -t "$IMG" -f Dockerfile.app-builder . )

# 依赖缓存用命名卷（不由 compose 管 ⇒ `down -v` 不会误删）
# ★ 三个缓存卷都必需，缺一个就退化成"每次全量重编译"：
#   go-mod          = 依赖源码（否则每次重新下载 modules）
#   go-build-cache  = Go 的编译产物缓存（默认在容器层 `/root/.cache/go-build`，
#                     而本容器是 --rm ⇒ 不挂出来就每次全量重编所有包）
#   cargo-registry  = Rust crates（anydoc 静态库的依赖）
docker run --rm \
  -v "$DIR":/src \
  -v "$DIR/.build":/out \
  -v weknora-go-mod:/go/pkg/mod \
  -v weknora-go-build-cache:/root/.cache/go-build \
  -v weknora-cargo-registry:/usr/local/cargo/registry \
  -w /src \
  -e VERSION="$V" -e COMMIT_ID="$C" -e BUILD_TIME="$T" -e GO_VERSION="$G" \
  "$IMG" \
  bash -c '
    # ── 让 Makefile 的 `git describe --tags --abbrev=0` 失败，以走官方设计的
    #    fallback：Makefile 的写法是
    #        VERSION=$$(git describe --tags --abbrev=0 2>/dev/null || echo "$${VERSION:-unknown}")
    #    ⇒ describe 成功时**环境变量 VERSION 被忽略**，取到的是带 v 的 tag 名。
    #    为什么官方会走 fallback：Dockerfile 构建时 .dockerignore 排除了 .git，
    #    容器内没有仓库 ⇒ describe 必然失败 ⇒ Version 来自官方专为此留的
    #    `VERSION_ARG`。**我们挂载了完整仓库（含 .git）并配了 safe.directory，
    #    反而绕过了官方设计** —— 这里把它恢复成官方的行为。
    #    shim 只拦 describe，其余 git 调用（含 go build 的 VCS stamping）原样转发。
    #    落点 /tmp 且容器是 --rm ⇒ 不留痕、不碰仓库。
    REAL_GIT=$(command -v git)
    mkdir -p /tmp/gitshim
    printf "%s\n" "#!/bin/sh" \
      "case \"\$*\" in *describe*--abbrev=0*) exit 1 ;; esac" \
      "exec $REAL_GIT \"\$@\"" > /tmp/gitshim/git
    chmod +x /tmp/gitshim/git
    export PATH=/tmp/gitshim:$PATH

    git config --global --add safe.directory /src && \
    ./scripts/build-anydoc-lib.sh && \
    make build-prod GO_BUILD_TAGS=anydoc BINARY_NAME=/out/WeKnora'

# ★ 上面的 shim 只为对齐「UI 版本 vs 应用版本」的口径 —— 详见 _build_with_version
#   的注释与 `my-docs/12-应用代码外置/` 的说明（前端 version 无 v、后端 tag 有 v）。

# ★ build-anydoc-lib.sh 不能省（首个版本漏了它 ⇒ 编译走到 link 才报
#   `/usr/bin/ld: cannot find -lanydoc_go`）。它是 anydoc（进程内 office 解析）的
#   Rust 静态库，官方 Dockerfile.app 的 builder 阶段同样先跑它、再 `make ... GO_BUILD_TAGS=anydoc`。
#   产物落 third_party/anydoc-go/lib/<平台>/libanydoc_go.a，正是 cgo LDFLAGS 的 -L 路径。
#   故必须在同一容器内先产出再链接 —— 两步拆开就会丢这个文件。
#   耗时：首次真编译 Rust（数分钟），之后 target/ 落在挂载出来的仓库里 ⇒ 增量复用。

ls -lh "$DIR/.build/WeKnora"
echo "  ★ GLIBC 需求（容器上限 2.36）:"
grep -aoE "GLIBC_[0-9]+\.[0-9]+" "$DIR/.build/WeKnora" | sort -uV | tail -3 | sed 's/^/    /'
REMOTE_APP_BUILD
  ok "已编译并投递到 .build/WeKnora"

  step "② 让 app 加载新二进制"
  # ★ 首次启用必须先**重建容器**：挂载是容器创建时固定的，`restart` 只换进程、
  #   不会应用 overlay 新增的挂载
  #   ⇒ 会出现"编译成功、也重启了、跑的还是镜像内那份旧二进制"。
  #   判据 = 容器挂载列表中是否**同时**含 `/app/WeKnora`（外置二进制）与
  #     `/app/migrations`（外置迁移）。**两者缺一都要重建** —— 只判前者时，
  #     后来新增的迁移挂载会被这个分支静默跳过（2026-09-22 加迁移外置时踩到）。
  local mounted
  mounted="$(ssh "$SSH_HOST" "docker inspect WeKnora-app --format '{{range .Mounts}}{{.Destination}} {{end}}'" 2>/dev/null || true)"
  if [[ "$mounted" == *"/app/WeKnora"* && "$mounted" == *"/app/migrations"* ]]; then
    ssh "$SSH_HOST" "$DC restart app"
    ok "已重启 app（两处外置挂载齐备，容器未重建）"
  else
    warn "容器挂载不完整（缺外置二进制或外置迁移）⇒ 重建容器（restart 不会应用新挂载）"
    ssh "$SSH_HOST" "$DC up -d app"
    ok "已重建 app 容器，外置挂载已生效"
  fi

  step "③ 自证：容器内二进制的 commit"
  printf "  期望 commit: %s\n" "$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD)"
  # 注：`grep -c` 给的是**命中行数**（二进制里该 commit 串出现多处），
  #     不是版本号 —— 判据是「> 0」而非「等于某个数」。
  local hits
  hits="$(ssh "$SSH_HOST" "docker exec WeKnora-app grep -ac '$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD)' /app/WeKnora" 2>/dev/null | tr -d '[:space:]')"
  if [ "${hits:-0}" -gt 0 ] 2>/dev/null; then
    ok "二进制内嵌 commit 命中 ${hits} 处（>0 即一致）"
  else
    warn "二进制内未命中该 commit ⇒ 容器内跑的很可能不是本次产物"
  fi

  step "④ 自证：迁移文件与库版本"
  check_migrations
}
cmd_build()  { preflight_local; sync_code; ensure_env; compose_up build; health_check; }

cmd_status() {
  ssh "$SSH_HOST" "cd $REMOTE_DIR 2>/dev/null && $DC ps || echo '未部署'"
}

cmd_logs() {
  local svc="${1:-app}"
  ssh "$SSH_HOST" "$DC logs --tail=200 -f $svc"
}

cmd_restart() {
  step "重启容器"
  ssh "$SSH_HOST" "$DC restart"
  ok "已重启"
}

cmd_health() {
  printf '后端: '; ssh "$SSH_HOST" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 http://localhost:${APP_PORT}/health"
  printf '官方前端(https): '; ssh "$SSH_HOST" "curl -sk -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 https://localhost:${FRONTEND_PORT}/"
  printf '定制前端(https): '; ssh "$SSH_HOST" "curl -sk -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 https://localhost:41280/"
  # 自带搜索：与 health_check 里同一口径 —— **必须验「有结果」，不能只看 200**
  # （searxng 在引擎全不可达时仍返回 200，只是 results 为空）
  printf '自带搜索(searxng): '
  ssh "$SSH_HOST" "n=\$(docker exec weknora-nginx wget -q -O - --timeout=25 'http://searxng:8080/search?q=weknora&format=json' 2>/dev/null | grep -o '\"url\":' | wc -l); \
    if [ \"\${n:-0}\" -gt 0 ]; then echo \"HTTP 200，命中 \${n} 条结果\"; else echo '结果为空（多为引擎不可达，看 logs searxng）'; fi"
}

cmd_down() {
  warn "即将停止容器（数据卷保留）"
  ssh "$SSH_HOST" "$DC down"
  ok "已停止"
}

# 复核「我们的站点容器组相对官方改了什么」+ 检查叠加层是否过期
cmd_compose_diff() {
  step "对比官方基底与站点容器组（复核我们的定制面）"
  ssh "$SSH_HOST" "DIR='$REMOTE_DIR' DC='$DC' BASE='$COMPOSE_BASE_REL' OVERLAY='$COMPOSE_OVERLAY_REL' bash -s" <<'REMOTE_DIFF'
set -e
cd "$DIR"

# 渲染后的 config 比对：忽略注释与排版，只留语义差异
OFF="docker compose --project-directory $DIR --env-file $DIR/.env -f $DIR/$BASE"
if ! $OFF config > /tmp/_wk_official.yml 2>/dev/null; then
  echo "  ⚠ 官方 compose 渲染失败（可能上游改了必填变量），跳过结构化比对"
else
  $DC config > /tmp/_wk_site.yml 2>/dev/null
  n=$(diff /tmp/_wk_official.yml /tmp/_wk_site.yml | grep -c '^[<>]' || true)
  echo "  站点容器组相对官方共 $n 行差异（**预期非零**：我们主动新增了 frontend-wkj 与 nginx）"
  echo ""
  echo "  差异明细（< 官方    > 我们的站点容器组）："
  diff -u /tmp/_wk_official.yml /tmp/_wk_site.yml | sed -n '3,300p' | sed 's/^/  /'
fi

echo ""
echo "--- 叠加层是否可能过期（与官方编排文件的提交时间对比） ---"
printf '  官方基底   : '; git log -1 --format='%h %ad %s' --date=short -- "$BASE"
printf '  我们的叠加 : '; git log -1 --format='%h %ad %s' --date=short -- "$OVERLAY"
off_ts=$(git log -1 --format=%ct -- "$BASE" 2>/dev/null || echo 0)
my_ts=$(git log -1 --format=%ct -- "$OVERLAY" 2>/dev/null || echo 0)
echo ""
if [ "$off_ts" -gt "$my_ts" ]; then
  echo "  ⚠ 官方 $BASE 的最近提交比叠加层新 —— 上游可能改了某个我们也在改的字段，"
  echo "    请对照上面的差异逐条核对是否需要同步（常见：新增服务、改名变量、改端口）。"
else
  echo "  ✔ 叠加层不比官方新（无未同步的上游变化迹象）"
fi
echo ""
echo "  判读要点：差异**天然非零**是正常的（我们新增了两个服务）。"
echo "            这里要看的是「有没有非预期的差异」，而不是「是否为零」。"
echo "            我们改了什么、为什么 —— 见 $OVERLAY 的文件头清单。"
REMOTE_DIFF
}

cmd_shell() { ssh -t "$SSH_HOST" "cd $REMOTE_DIR 2>/dev/null; exec bash -l"; }

# 用文件头注释作为帮助。刻意不写死行号（如 '2,39p'）—— 那样会在注释增删后
# **静默截断** help 输出（原先就漏掉了末尾 4 条「设计原则」）。
cmd_help() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ 入口
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

case "${1:-help}" in
  deploy|update|build|sync|up|status|restart|health|down|shell) "cmd_$1" "${@:2}" ;;
  push-ui)      cmd_push_ui ;;
  push-reader)  cmd_push_reader ;;
  push-app)     cmd_push_app ;;
  logs)         cmd_logs "${2:-app}" ;;
  compose-diff) cmd_compose_diff ;;
  help|-h|--help) cmd_help ;;
  *) die "未知命令：$1（用 help 查看用法）" ;;
esac
