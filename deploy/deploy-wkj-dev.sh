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
#   ./deploy-wkj-dev.sh deploy     首次部署 / 完整部署（幂等，可重复执行）
#   ./deploy-wkj-dev.sh update     更新：推代码 → 拉取 → 重建容器
#   ./deploy-wkj-dev.sh build      二开构建：在 111 上构建镜像后重启
#   ./deploy-wkj-dev.sh status     查看容器状态
#   ./deploy-wkj-dev.sh logs [svc] 查看日志（默认 app）
#   ./deploy-wkj-dev.sh restart    重启容器
#   ./deploy-wkj-dev.sh health     健康检查
#   ./deploy-wkj-dev.sh shell      登录 111
#   ./deploy-wkj-dev.sh down       停止容器（保留数据）
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
  ssh "$SSH_HOST" "DIR='$REMOTE_DIR' MODE='$mode' bash -s" <<'REMOTE_UP'
set -e
cd "$DIR"

if [ "$MODE" = "build" ]; then
  echo "  构建镜像（二开模式，耗时较长，可能 20-40 分钟）..."
  docker compose build
else
  echo "  拉取镜像（--quiet 模式；首次约 5-10 分钟，请耐心等待）..."
  docker compose pull --quiet
fi

# ── 阶段一：基础设施 + 后端（不含 frontend）──────────────────────────
# 为什么分两阶段：frontend 有 depends_on: app(healthy)。app 首次启动要在
# 机械盘上建 70 张表，耗时可能超过 compose healthcheck 的
# start_period(60s) + retries(3)×interval(30s) 窗口 → app 被判 unhealthy
# → frontend 依赖检查失败并**停在 Created 不再重试**（compose 的固有行为）。
# 因此先起后端、等它就绪，再起前端。
echo "  启动基础设施与后端（postgres / redis / docreader / app）..."
docker compose up -d postgres redis docreader app

echo "  等待后端就绪（首次需建库表，最长 600s）..."
_w=0
until [ "$(docker inspect WeKnora-app --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; do
  _w=$((_w+5))
  if [ "$_w" -ge 600 ]; then
    echo "  ✘ 后端 600s 内未就绪，最近日志："
    docker compose logs --tail=30 app
    exit 1
  fi
  sleep 5
done
echo "  ✔ 后端已就绪（用时 ${_w}s）"

echo "  启动前端..."
docker compose up -d frontend

echo ""
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
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
    ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose logs --tail=30 app" || true
    die "健康检查失败"
  }

  # 前端兜底：若停在 Created（历史遗留的 depends_on 失败态），主动拉起
  local fe_state
  fe_state=$(ssh "$SSH_HOST" "docker inspect WeKnora-frontend --format '{{.State.Status}}'" 2>/dev/null || echo "missing")
  if [ "$fe_state" != "running" ]; then
    warn "前端容器状态为 ${fe_state}，尝试拉起..."
    ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose up -d frontend" >/dev/null 2>&1 || true
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
  ssh "$SSH_HOST" "cd $REMOTE_DIR 2>/dev/null && docker compose ps || echo '未部署'"
}

cmd_logs() {
  local svc="${1:-app}"
  ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose logs --tail=200 -f $svc"
}

cmd_restart() {
  step "重启容器"
  ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose restart"
  ok "已重启"
}

cmd_health() {
  printf '后端: '; ssh "$SSH_HOST" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 http://localhost:${APP_PORT}/health"
  printf '前端: '; ssh "$SSH_HOST" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 6 http://localhost:${FRONTEND_PORT}/"
}

cmd_down() {
  warn "即将停止容器（数据卷保留）"
  ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose down"
  ok "已停止"
}

cmd_shell() { ssh -t "$SSH_HOST" "cd $REMOTE_DIR 2>/dev/null; exec bash -l"; }

cmd_help() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ 入口
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

case "${1:-help}" in
  deploy|update|build|status|restart|health|down|shell) "cmd_$1" "${@:2}" ;;
  logs)    cmd_logs "${2:-app}" ;;
  help|-h|--help) cmd_help ;;
  *) die "未知命令：$1（用 help 查看用法）" ;;
esac
