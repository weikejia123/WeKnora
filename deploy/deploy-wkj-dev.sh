#!/usr/bin/env bash
# ==============================================================================
# WeKnora 生产部署脚本
#
#   部署分支：wkj-dev
#   部署目标：nanning-111 (10.168.1.111)  →  /mnt/data/weknora
#   代码中转：nanning-110 Gitea (10.168.1.110:13000) → wakeagent/WeKnora
#   对外端口：41200 (前端) / 41201 (后端 API)
#
# 用法：
#   ./deploy-wkj-dev.sh deploy      首次部署 / 完整部署（幂等，可重复执行）
#   ./deploy-wkj-dev.sh update      更新：推代码 → 拉取 → 重建容器
#   ./deploy-wkj-dev.sh build       二开构建：在 111 上构建镜像后重启
#   ./deploy-wkj-dev.sh status      查看容器状态
#   ./deploy-wkj-dev.sh logs [svc]  查看日志（默认 app）
#   ./deploy-wkj-dev.sh restart     重启容器
#   ./deploy-wkj-dev.sh health      健康检查
#   ./deploy-wkj-dev.sh compose-diff 对比官方与 my-docker 的 compose 差异（防过期）
#   ./deploy-wkj-dev.sh shell       登录 111
#   ./deploy-wkj-dev.sh down        停止容器（保留数据）
#
# ★ 编排文件：一律使用 my-docker/docker-compose.yml（站点定制版），
#   仓库根的官方 docker-compose.yml 保持原样，同步上游时零冲突。
#   调用时统一带 --project-directory（保持相对路径按仓库根解析，见下方注释）。
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

# ★ 部署一律使用 my-docker/ 下的「站点定制 compose」；仓库根的官方
#   docker-compose.yml 保持原样，以便同步上游时零冲突。
#   --project-directory 是**必需**的：Compose 的相对路径（build.context /
#   bind mount / env_file）默认按 compose 文件所在目录解析，文件放进 my-docker/
#   后 `context: .` 变成 my-docker/、`env_file: .env` 去找 my-docker/.env。
#   加 --project-directory 指向仓库根即恢复原语义 —— 已实测与官方配置的
#   `docker compose config` 输出逐行一致（项目名、数据卷名、路径均不变）。
readonly COMPOSE_FILE_REL="my-docker/docker-compose.yml"
readonly DC="docker compose --project-directory $REMOTE_DIR --env-file $REMOTE_DIR/.env -f $REMOTE_DIR/$COMPOSE_FILE_REL"

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
  [ -f "$f" ] || die "本机缺少 $f，无法获取 110 Gitea 凭据"
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
  [ "$cur" = "$BRANCH" ] || die "当前分支为 $cur，但本脚本部署 $BRANCH；请先 git checkout $BRANCH"
  ok "当前分支：$cur"

  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    warn "本机存在未提交改动，推送的仍是已提交内容（未提交部分不会生效）"
  fi
  ok "本机检查通过"
}

preflight_remote() {
  step "111 远端前置检查"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" 'true' 2>/dev/null \
    || die "无法免密 SSH 到 $SSH_HOST（检查 ~/.ssh/config）"
  ok "SSH 免密连通"

  ssh -o ConnectTimeout=10 "$SSH_HOST" '
    set -e
    command -v docker >/dev/null || { echo "NODOCKER"; exit 1; }
    docker compose version >/dev/null 2>&1 || { echo "NOCOMPOSE"; exit 1; }
    [ -f /mnt/data/.mounted ] || { echo "NOMOUNT"; exit 1; }
    echo "OK"
  ' >/dev/null 2>&1 || die "111 环境检查失败（docker / compose / /mnt/data 挂载）"
  ok "docker + compose 可用，/mnt/data 已挂载"

  # 站点定制 compose 必须在位（部署一律用它）
  ssh "$SSH_HOST" "test -f '$REMOTE_DIR/$COMPOSE_FILE_REL'" 2>/dev/null \
    || die "111 上缺少 $REMOTE_DIR/$COMPOSE_FILE_REL —— 先跑一次 sync_code，或确认 $BRANCH 分支包含 my-docker/"
  ok "站点定制 compose 在位：$COMPOSE_FILE_REL"
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
  cd "$DIR"
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
  step "④ 启动容器（模式：$mode）"
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
# 判据：registry 拉的镜像带 RepoDigests；本地 docker build 出来的没有（长度 0）。
local_built=0
for _img in wechatopenai/weknora-app wechatopenai/weknora-ui; do
  _n=$(docker image inspect "$_img:$TAG" --format '{{len .RepoDigests}}' 2>/dev/null || echo missing)
  if [ "$_n" = "0" ]; then
    local_built=1
    echo "  · 检测到本地构建镜像：$_img:$TAG（无 registry digest，属二开产物）"
  fi
done

if [ "$MODE" = "build" ]; then
  echo "  构建镜像（二开模式，耗时较长，可能 20-40 分钟）..."
  $DC build
elif [ "$local_built" = "1" ] && [ "${ALLOW_OVERWRITE:-0}" != "1" ]; then
  echo ""
  echo "  ⚠ 已阻止 pull —— 111 上存在本地构建的二开镜像。"
  echo "    pull 会把它们静默替换为官方镜像，导致「代码改了但功能没变」。"
  echo "    现自动改用 build 模式。若确实要回到官方镜像，请加："
  echo "        WKJ_ALLOW_PULL_OVERWRITE=1 ./deploy-wkj-dev.sh update"
  echo ""
  $DC build
else
  echo "  拉取镜像（--quiet 模式；首次约 5-10 分钟，请耐心等待）..."
  $DC pull --quiet
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

echo "  启动前端..."
$DC up -d frontend

echo ""
$DC ps --format 'table {{.Name}}\t{{.Status}}'
REMOTE_UP
  ok "容器已启动"
}

# ------------------------------------------------------------------ 健康检查
health_check() {
  step "⑤ 健康检查"
  local i=0
  local url_app="http://10.168.1.111:${APP_PORT}/health"
  local url_fe="http://10.168.1.111:${FRONTEND_PORT}/"

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
    ssh "$SSH_HOST" "$DC up -d frontend" >/dev/null 2>&1 || true
    sleep 3
  fi

  local fe_code
  fe_code=$(ssh "$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://localhost:${FRONTEND_PORT}/" 2>/dev/null || echo "000")
  [ "$fe_code" = "200" ] && ok "前端 HTTP 200" || warn "前端返回 HTTP $fe_code"

  printf '\n'
  printf '%s╭─────────────────────────────────────────────────────────────╮%s\n' "$C_OK" "$C_OFF"
  printf '%s│  部署完成%s                                                    │\n' "$C_OK" "$C_OFF"
  printf '%s╰─────────────────────────────────────────────────────────────╯%s\n' "$C_OK" "$C_OFF"
  printf '   网页界面 : %s%s%s\n' "$C_INFO" "$url_fe" "$C_OFF"
  printf '   后端 API : %s%s%s\n' "$C_INFO" "$url_app" "$C_OFF"
  printf '   部署目录 : 111:%s\n' "$REMOTE_DIR"
  printf '   部署分支 : %s%s%s\n' "$C_INFO" "$BRANCH" "$C_OFF"
  printf '   查看日志 : %s%s logs%s\n' "$C_INFO" "$0" "$C_OFF"
}

# ------------------------------------------------------------------ 子命令
cmd_deploy() { preflight_local; preflight_remote; sync_code; ensure_env; compose_up pull; health_check; }
cmd_update() { preflight_local; sync_code; ensure_env; compose_up pull; health_check; }
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
  printf '前端: '; ssh "$SSH_HOST" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 http://localhost:${FRONTEND_PORT}/"
}

cmd_down() {
  warn "即将停止容器（数据卷保留）"
  ssh "$SSH_HOST" "$DC down"
  ok "已停止"
}

# 对比官方 compose 与站点定制版 —— 防止 my-docker 悄悄过期（上游加了服务/参数而这里没有）
cmd_compose_diff() {
  step "对比官方与 my-docker 的 compose"
  ssh "$SSH_HOST" "DIR='$REMOTE_DIR' DC='$DC' bash -s" <<'REMOTE_DIFF'
set -e
cd "$DIR"

# 用「渲染后的 config」比对，忽略注释与排版差异，只留语义差异
OFF="docker compose --project-directory $DIR --env-file $DIR/.env -f $DIR/docker-compose.yml"
if ! $OFF config > /tmp/_wk_official.yml 2>/dev/null; then
  echo "  ⚠ 官方 compose 渲染失败（可能上游改了必填变量），跳过结构化比对"
else
  $DC config > /tmp/_wk_mydocker.yml 2>/dev/null
  if diff -q /tmp/_wk_official.yml /tmp/_wk_mydocker.yml >/dev/null; then
    echo "  ✔ 两份配置语义完全一致（无差异）"
  else
    echo "  语义差异（< 官方  > my-docker）："
    diff -u /tmp/_wk_official.yml /tmp/_wk_mydocker.yml | sed -n '3,200p' | sed 's/^/  /'
  fi
fi

echo ""
echo "--- 两份编排文件的最后一次提交 ---"
printf '  官方      : '; git log -1 --format='%h %ad %s' --date=short -- docker-compose.yml
printf '  my-docker : '; git log -1 --format='%h %ad %s' --date=short -- my-docker/docker-compose.yml

off_ts=$(git log -1 --format=%ct -- docker-compose.yml 2>/dev/null || echo 0)
my_ts=$(git log -1 --format=%ct -- my-docker/docker-compose.yml 2>/dev/null || echo 0)
echo ""
if [ "$off_ts" -gt "$my_ts" ]; then
  echo "  ⚠ 官方 docker-compose.yml 的最近提交比 my-docker 新 ——"
  echo "    可能有上游变化尚未搬进 my-docker/docker-compose.yml，请逐条核对上面的差异。"
else
  echo "  ✔ my-docker 不比官方旧（无未同步的上游变化迹象）"
fi
REMOTE_DIFF
}

cmd_shell() { ssh -t "$SSH_HOST" "cd $REMOTE_DIR 2>/dev/null; exec bash -l"; }

cmd_help() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ 入口
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

case "${1:-help}" in
  deploy|update|build|status|restart|health|down|shell) "cmd_$1" "${@:2}" ;;
  logs)         cmd_logs "${2:-app}" ;;
  compose-diff) cmd_compose_diff ;;
  help|-h|--help) cmd_help ;;
  *) die "未知命令：$1（用 help 查看用法）" ;;
esac
