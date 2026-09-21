#!/usr/bin/env bash
#
# WeKnora 数据备份 —— 全量快照，保留最近 N 份
#
# 在 111 上「本机」运行（由 cron 调用），不经 ssh。
#
# ── 为什么这样设计（完整论证见 my-docs/11-数据安全与备份/）──────────────
# · 数据库：pg_dump 全量。PG 的**逻辑备份没有增量能力**，这是设计使然；
#   所谓"增量"只能靠物理层（WAL 归档 / pgBackRest），代价是恢复链变长、
#   且必须演练才能确信可用。本场景数据 GB 量级、磁盘 15T
#   ⇒ 全量 + 多份轮转更简单可靠。
# · 文件卷：rsync --link-dest 快照。**每份快照都是完整的**（可直接恢复，
#   不是"增量 + 累积"），但未变化的文件以硬链接共享 ⇒ 磁盘占用接近增量。
#   避免"每天 tar 一个大卷 × 10 份"既慢又占空间。
# · ★ .env 必须进备份集：它含 SYSTEM_AES_KEY —— 用于解密【存库的】敏感字段
#   （搜索 provider 的 api_key、tenant 凭据等）。解密走 Lenient 模式
#   （失败只 log + 置空，**不报错**）⇒ 少了它，库能恢复、服务也能正常启动，
#   但那些字段**静默失效**，很难被发现。
#
# 用法：
#   ./backup-weknora.sh                执行一次备份
#   ./backup-weknora.sh --dry-run      只打印将做什么，不落盘
#   ./backup-weknora.sh --status       查看最近一次成功备份
#   ./backup-weknora.sh --help
#
# 可用环境变量覆盖（默认值即 111 的现场值）：
#   REPO_DIR BACKUP_ROOT KEEP PG_CONTAINER APP_CONTAINER
#   DATA_FILES_VOL DOCKER_ROOT_DIR MIN_FREE_GB
#
set -euo pipefail

# cron 的环境极简，必须显式给 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

REPO_DIR="${REPO_DIR:-/mnt/data/weknora}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/data/backups/weknora}"
KEEP="${KEEP:-10}"                                  # 保留最近 N 份
PG_CONTAINER="${PG_CONTAINER:-WeKnora-postgres}"
APP_CONTAINER="${APP_CONTAINER:-WeKnora-app}"
DATA_FILES_VOL="${DATA_FILES_VOL:-weknora_data-files}"
DOCKER_ROOT_DIR="${DOCKER_ROOT_DIR:-/mnt/data/docker}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"                    # 空间低于此值则中止，避免写满盘
DATA_FILES_SRC="${DATA_FILES_SRC:-$DOCKER_ROOT_DIR/volumes/$DATA_FILES_VOL/_data}"
LOG_FILE="${LOG_FILE:-$BACKUP_ROOT/backup.log}"

DRY_RUN=0
MODE="backup"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "✘ 失败：$*"; exit 1; }

# 用文件头的注释作为帮助（自动适应注释长度，不写死行号）
usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --status)  MODE="status" ;;
        --help|-h) usage; exit 0 ;;
        *) die "未知参数：$arg（用 --help 查看用法）" ;;
    esac
done

# ── status 模式 ────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
    if [ -f "$BACKUP_ROOT/.last-success" ]; then
        echo "最近一次成功备份：$(cat "$BACKUP_ROOT/.last-success")"
        echo "现有快照（保留上限 $KEEP）："
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null \
            | sort | sed 's|^|  |'
    else
        echo "尚无成功备份记录（$BACKUP_ROOT/.last-success 不存在）"
    fi
    exit 0
fi

mkdir -p "$BACKUP_ROOT"

# 并发保护：上一次还没跑完（大卷可能跑很久），本次直接退出而不是叠加
if command -v flock >/dev/null 2>&1; then
    exec 9>"$BACKUP_ROOT/.lock"
    if ! flock -n 9; then
        log "另一次备份仍在进行，本次跳过（避免叠加）"
        exit 0
    fi
else
    log "⚠ 环境无 flock（非 util-linux），本次不做并发保护"
fi

# 备份全过程留痕。dry-run 时不写日志文件，免得污染
if [ "$DRY_RUN" != "1" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

TS="$(date '+%Y%m%d-%H%M%S')"
DEST="$BACKUP_ROOT/$TS"

log "=== 备份开始（TS=$TS，保留 $KEEP 份）==="
[ "$DRY_RUN" = "1" ] && log "（dry-run：不会真正写盘）"

# ── 1. 前置检查（失败就退出，不要产生半个备份）────────────────────────
[ -d "$REPO_DIR" ]        || die "仓库目录不存在：$REPO_DIR"
[ -f "$REPO_DIR/.env" ]   || die ".env 不存在：$REPO_DIR/.env（它是备份的必需项，见文件头说明）"
[ -d "$DATA_FILES_SRC" ]  || die "文件卷目录不存在：$DATA_FILES_SRC（DockerRootDir 或卷名变了？）"
docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -q true \
    || die "postgres 容器未在运行：$PG_CONTAINER"

free_kb=$(df -Pk "$BACKUP_ROOT" | awk 'NR==2{print $4}')
free_gb=$(( free_kb / 1024 / 1024 ))
[ "$free_gb" -lt "$MIN_FREE_GB" ] \
    && die "剩余空间 ${free_gb}G < 要求 ${MIN_FREE_GB}G，中止（避免写满盘）"
log "前置检查通过（剩余空间 ${free_gb}G）"

# 读 .env 里的 DB 连接参数（含 '=' 的值要截全）
env_get() { grep -m1 "^$1=" "$REPO_DIR/.env" | cut -d= -f2- ; }
DB_USER="$(env_get DB_USER)"; DB_NAME="$(env_get DB_NAME)"; DB_PW="$(env_get DB_PASSWORD)"
[ -n "$DB_USER" ] && [ -n "$DB_NAME" ] && [ -n "$DB_PW" ] \
    || die ".env 中 DB_USER / DB_NAME / DB_PASSWORD 有缺失"

if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] 将创建 $DEST"
    log "[dry-run] pg_dump -U $DB_USER -d $DB_NAME -Fc → $DEST/db.dump"
    log "[dry-run] cp .env → $DEST/env.backup"
    log "[dry-run] rsync -a --delete${LINK_HINT:-} $DATA_FILES_SRC/ → $DEST/files/"
    exit 0
fi

mkdir -p "$DEST"

# ── 2. 数据库（全量，-Fc：内置压缩 + 支持选择性恢复）──────────────────
log "1/4 pg_dump（$DB_NAME）…"
docker exec -e PGPASSWORD="$DB_PW" "$PG_CONTAINER" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DEST/db.dump"
[ -s "$DEST/db.dump" ] || die "db.dump 为空"

# 当场验证 dump 可读 —— 未验证的备份不算备份
docker exec -i "$PG_CONTAINER" pg_restore -l < "$DEST/db.dump" > /dev/null \
    || die "db.dump 无法被 pg_restore 解析"
log "    db.dump $(du -h "$DEST/db.dump" | cut -f1)，已通过 pg_restore -l 校验"

# ── 3. .env（★ 密钥，缺它则库内密文字段静默失效）──────────────────────
log "2/4 .env …"
cp -p "$REPO_DIR/.env" "$DEST/env.backup"

# ── 4. 文件卷（硬链接快照：完整视图 + 接近增量的占用）─────────────────
log "3/4 文件卷快照（$DATA_FILES_SRC）…"
PREV="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' \
        | sort | grep -v "^$DEST$" | tail -1 || true)"
link_args=()
if [ -n "$PREV" ] && [ -d "$PREV/files" ]; then
    link_args=(--link-dest="$PREV/files")   # rsync 要求绝对路径
    log "    基准快照：$(basename "$PREV")（未变化文件将共享块）"
else
    log "    无基准快照（首份，全量传输）"
fi
rsync -a --delete "${link_args[@]+"${link_args[@]}"}" "$DATA_FILES_SRC/" "$DEST/files/"
log "    文件数 $(find "$DEST/files" -type f | wc -l | tr -d ' ')"

# ── 5. 记录成功 + 轮转 ────────────────────────────────────────────────
log "4/4 轮转（保留最近 $KEEP 份）…"
# 刻意不用 mapfile：它是 bash 4+ 才有（macOS 自带 bash 3.2 没有），
# 用了会在老 bash 上静默变成空数组 ⇒ 轮转悄悄不执行。用 POSIX 友好写法。
snap_count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l | tr -d ' ')"
if [ "$snap_count" -gt "$KEEP" ]; then
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort \
        | head -n $(( snap_count - KEEP )) \
        | while IFS= read -r old; do
            log "    删除最旧：$(basename "$old")"
            rm -rf "$old"
          done
else
    log "    现有 ${snap_count} 份，未超过上限"
fi

printf '%s  snapshot=%s  root=%s\n' "$(date '+%F %T')" "$TS" "$BACKUP_ROOT" \
    > "$BACKUP_ROOT/.last-success"
log "=== 备份完成：$DEST ==="
