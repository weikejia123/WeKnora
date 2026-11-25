# WeKnora 官方 main 第 15 轮更新分析（2026-11-26）

> 同步区间：`e3fb2335`（第 14 轮合并点）→ `b2c9edcd`（官方 main 最新），共 **440 个提交**、
> **1051 文件**（+116413 / -108171）。
> 官方版本号 **0.9.0 → 0.9.1**（`VERSION` 已变；`v0.9.1` tag = `71c32af92`，2026-11-24）。
> 本轮是**发版轮**：v0.9.1 的 381 个提交里有 252 个落在本区间内，其余 188 个是发版后的修复。

## 1. 概览

| 项 | 值 |
|---|---|
| 提交数 | 440（fix 343 / feat 25 / perf 13 / 其余 docs·test·chore） |
| 发版 | **有** —— `v0.9.0`（10-29）→ `v0.9.1`（11-24），中间 381 提交 |
| 官方改动面 | 1051 文件，+116413 / -108171 |
| 我方相对官方差异面（合并后） | **1284 文件**（第 14 轮为 1173） |
| 交集（真正的冲突面） | **0 文件** —— 零冲突自动合并 |
| `go build ./...` | **exit=0**（仅既有 sqlite3 deprecation / `-lc++` 重复库警告） |
| 前端构建 | `my-frontend` `npm run build` **exit=0**（19.56s） |
| 合并提交 | `dfa3c6e11`；回滚点 = 合并前 `959684c61` |
| 111 部署 | **完成**，库版本 `137/f`，四个容器镜像 ID 全部与 tag 一致（§6.2） |
| 部署耗时 | **约 12 分钟**（放弃 `build`，改走 push-app / push-ui / push-reader —— 理由见 §6.1） |

### 1.1 为什么本轮零冲突（值得记住的判据）

**不要用 `comm -12 <(git diff --name-only upstream/main..HEAD) <(git diff --name-only HEAD...upstream/main)` 判冲突面** ——
这个写法算的是「官方与我方**最终状态的差异**」，它会把我方所有 `my-*` 新增文件都算成"两边都改了"，
输出 1000+ 行纯噪声（本轮实测如此）。

正确的判据是**三方比较**：以 merge-base 为基准，看「双方各自**相对 merge-base** 的改动是否有交集」：

```bash
MB=$(git merge-base HEAD upstream/main)
comm -12 <(git diff --name-only $MB..HEAD | sort) \
         <(git diff --name-only $MB..upstream/main | sort)
```

本轮结果：**空集**。原因很直接 —— 我方相对 merge-base 的官方文件改动只有 6 个
（`AGENTS.md` / `README-WAKE.md` / `deploy/deploy-wkj-dev.sh` 三个新增，`docker/Dockerfile.app` /
`docker/Dockerfile.docreader` 两个例外文件，外加 `my-*` 全部新增），而官方本轮**没碰 `docker/` 任何文件**
（`git diff --name-only e3fb2335b..b2c9edcd5 -- docker/ | wc -l` = 0）。两个例外 Dockerfile 因此完好无损。

## 2. 更新内容

### 2.1 v0.9.1 的四个对外重点（官方公告口径）

| 项 | 说明 | 对本部署的影响 |
|---|---|---|
| **语音输入（按住说话）** | 给智能体开「语音上传」+ 配 ASR 模型，输入框按住录音、松开转文字再编辑 | 需在 111 配 ASR 模型才可用；不配则按钮不出 |
| **沙箱浏览器人机接力** | 同一会话内桌面与智能体共用浏览器，用户登录后智能体接着用同一页面 | ⚠️ 依赖沙箱桌面；111 当前 `WEKNORA_SANDBOX_DOCKER_ENABLED=false` + 远程沙箱关闭 ⇒ **不生效** |
| **个人凭据保险库** | 每空间每人的站点账号，密码 AES 加密存库，默认「仅用一次」 | 表 `credential_vault_items`（迁移 000136）**第 14 轮已建**；本轮补前端交互 |
| **搜索直达原文 / 以图搜图** | 全局搜索点命中跳原文；检索 API 支持传图查相似图 | 需 KB 开图片向量索引；引用来来源知识库标签默认生效 |

### 2.2 数据层：只多一个迁移，且是**索引改写**

| 迁移 | PostgreSQL | SQLite | 动作 |
|---|---|---|---|
| IM 会话模式索引 | **000137** | **000053** | DROP + CREATE `idx_channel_lookup`（加 `thread_id = ''` 条件），SQLite 另建 `idx_channel_thread_lookup` |

⚠️ **本轮不新增表、不改列宽**（000135 审计列宽与 000136 凭据表**都已在第 14 轮**执行完毕，111 当前库版本
就是 `136/f`）。000137 只动 `im_channel_sessions` 的两个**部分唯一索引**。

- **up**：把用户模式的唯一性收窄到 `thread_id = ''`，让同一用户能建多个线程映射；**存量映射一行不动**。
- **down**：会把约束还原成旧形态，若已有一人多线程映射，**down 会直接失败**（官方刻意让它 fail 而不是删数据）。
  ⇒ **回滚时不要 `migrate down`**，直接恢复备份。

### 2.3 运行时行为变化（会影响 111 的）

1. **HNSW 按需建索引**（`internal/application/repository/retriever/postgres/hnsw_index.go`）：
   `AUTO_MIGRATE != false` 时，app 会在**首次写入/查询某个向量维度**时，在后台为该维度
   `CREATE INDEX CONCURRENTLY` 建 partial HNSW 索引（迁移 000002/000059 只为 3584/798/1024 建过）。
   ⚠️ **111 实测库里有 2560 维向量 12882 条**（1024 维仅 5 条），而索引清单里**没有 2560 维的**。
   ⇒ 升级后**首次检索 2560 维就会在后台建索引**（132MB 表，机械盘，预计数分钟，不阻塞查询但吃 IO）。
   这是本轮最容易被误判成"升级后卡了"的点。
2. **neo4j 补 healthcheck**（官方 #5801）：`wget --spider http://localhost:7474/`，`start_period 60s`。
   111 的 neo4j 容器**当前没有 healthcheck**（`docker inspect` 显示 `NO_HEALTHCHECK`）⇒ 本次重建后才会有。
3. **新环境变量**（全部**可选**、留空即官方默认，`docker-compose.yml` 已 wire 的叫★）：
   - ★ `WEKNORA_AGENT_MCP_DIRECTORY_MAX_AGE`（默认 1h）—— 保存的 MCP 工具目录过期后后台重拉
   - `WEKNORA_AGENT_PROMPT_SUSPEND` —— 设 false 后工具审批改纯阻塞等待，不再挂起持久化
   - `DUCKDB_SKIP_EXTENSION_LOAD` —— 无外网时跳过 duckdb spatial/excel 扩展安装。**111 不要设**：
     容器内 `/home/appuser/.duckdb/extensions/v1.5.2` 已有这两个扩展，设了反而让 xlsx 入库失败
   - `BUILTIN_MODELS_CONFIG` / `MODELS_CONFIG` —— 模型声明文件路径覆盖
4. **前端 i18n 拆包**（`fb18d8021`）：6 个巨型 locale 文件拆成 `locales/<locale>/{9 个域}.ts`，
   改为 `dynamic import()` 按需加载。**这是本轮前端改动量最大的一项（61 个文件）**，
   也让 `my-frontend` 的 i18n 目录结构整体变了（新增 6 个 locale 子目录）。
   效果：6 个 locale 变成**独立异步 chunk**（本轮实测：`zh-CN` 398kB / `zh-TW` 401kB / `en-US` 417kB /
   `ko-KR` 484kB / `ja-JP` 552kB / `ru-RU` 652kB），主 entry `index-*.js` 845kB。
   官方基准值（提交信息）：拆分前 6 个 locale 被合并进同步入口 chunk = **4435kB minified / 1299kB gzip**。
5. **`frontend/docker-entrypoint.sh` 修正**：`MAX_FILE_SIZE` 从 `${FILE_MB}M` 改为 `$((FILE_MB + 1))M`
   —— 因为 `client_max_body_size` 算的是**整个请求体**（含 multipart 边界/文件名），
   而前端按**文件本身**大小校验 ⇒ 恰好 `FILE_MB` 的文件会被 nginx 413 拒掉。属**真实可用性修复**。
6. **构建链修正**（`scripts/build-anydoc-lib.sh`）：新版 rustc 会在 staticlib 里塞 `.llvm*` 段，
   **Go 1.26 拒绝链接**。官方加了 `strip_llvm_lto_sections` 在 cgo 消费前剥掉。
   ⚠️ 我方 `push-app` 走 `build-anydoc-lib.sh` ⇒ **这条修正直接决定 push-app 能不能过**。

### 2.4 其他值得一提的修正（343 个 fix 里的代表）

- `fix(postgres): limit HNSW compatibility retries to setting failures`（#5955）
- `fix(retriever): restore ParadeDB keyword search with question generation off`（#5611）
- `fix(docreader): stop retrying encrypted documents`（#5653）—— 加密文档不再无限重试
- `fix(excel): hand the workbook to pandas as a stream so pandas 3 detects it`（#5865）—— pandas 3 兼容
- `fix(download): parse quoted protected filenames`（#5375）
- `fix(agent): stop reading canceled provider streams`（#5810）
- `fix(wiki): retry incomplete provider response envelopes`（#5840）
- `fix(graph): stabilize Neo4j merge lock order`（#5328，perf）

## 3. 二开影响评估

- **合并**：`git merge upstream/main` **零冲突**（判据见 §1.1）。真正需要人工确认的是
  **两个例外 Dockerfile 的换源 ARG 是否还在位** —— 合并后逐条 grep 确认
  `Dockerfile.app` 24 处 / `Dockerfile.docreader` 12 处，**全部在位**。
- **官方 `docker-compose.yml` 本轮有改动**（新增 1 个环境变量 + neo4j healthcheck）：
  我们是**自动继承**的（基底一字不动）⇒ 合并后 `compose config` 校验通过，且
  neo4j 的 `!override` 端口（41292/41293 回环）**仍然生效**（healthcheck 与 ports 不冲突）。
- **overlay 是否需要改？** 不需要。本轮官方没动任何我们在 overlay 里覆盖的字段
  （ports / build.args / volumes 全部不重叠）。`compose-diff` 会报
  「官方基底比叠加层新」——这是**预期提示**，因为官方改了 neo4j healthcheck 而我们没跟。
- **`.env` 是否需要改？** 不需要。新增变量全部可选；111 的 `.env` 里
  `APK_MIRROR_ARG=mirrors.tencent.com` 是唯一显式构建源，本轮官方没改对应 ARG 语义。
- **`migrations/` 外置挂载**：`sync_code` 的 `git reset --hard` 会把 000137 带到 111 ⇒
  **app 一重建就会自动执行**。按 AGENTS.md 第 8 条先备份（已做）。
- **`my-frontend` 副本**：官方动 `frontend/` **223 文件**（新增 92 / 删除 2）。
  `rsync -a --delete --exclude node_modules --exclude dist` 后 `diff -rq` 只剩
  `dist` / `node_modules` 两项产物差异（= 0 实质差异）。

## 4. 例外 Dockerfile 的必要性判断（合并后重判）

| 文件 | 官方本轮动作 | 我方剩余领先改动 | 结论 |
|---|---|---|---|
| `Dockerfile.app` | **本轮未改**（`docker/` 零改动） | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`（browserskill + builder 两个阶段） | **仍必要** |
| `Dockerfile.docreader` | **本轮未改** | `GH_PROXY`（protoc / grpc_health_probe）、`APT_MIRROR` 默认值 | **仍必要**（原样保留） |

## 5. 本轮做过的校验（可复现）

```bash
# 冲突面（三方比较，见 §1.1）
MB=$(git merge-base HEAD upstream/main)
comm -12 <(git diff --name-only $MB..HEAD | sort) <(git diff --name-only $MB..upstream/main | sort)  # 空

git diff --name-status upstream/main..HEAD | wc -l    # 1284（我方差异面）
git diff --name-status upstream/main..HEAD \
  -- . ':!my-*' ':!my-docs' ':!deploy' ':!AGENTS.md' ':!README-WAKE.md'
# 只剩 docker/Dockerfile.app 与 docker/Dockerfile.docreader

go build ./...                                        # exit=0
( cd my-frontend && npm run build )                   # exit=0（19.56s）
diff -rq frontend my-frontend                         # 仅 dist / node_modules
docker compose --project-directory . --env-file .env \
  -f docker-compose.yml -f my-docker/docker-compose.overlay.yml config --quiet   # exit=0
grep -c 'RUSTUP_*|GH_PROXY|NPM_REGISTRY_ARG|CARGO_REGISTRY_ARG|GOPROXY_ARG' docker/Dockerfile.app   # 24
grep -c 'GH_PROXY|APT_MIRROR' docker/Dockerfile.docreader                                            # 12
diff -q .env.example <(git show upstream/main:.env.example)   # 一致
diff -q docker-compose.yml <(git show upstream/main:docker-compose.yml)  # 一致
```

## 6. 部署记录（111，2026-11-26）

- [x] **备份**：`./my-scripts/backup-weknora.sh` → 快照 `20261126-031200`
  （db 154M `pg_restore -l` 校验通过 + data-files 124M `tar` 校验通过 + `.env`），早于本次变更。
  上一份为 11-25 06:00 定时快照（迁移 136/f、commit `1692f7fde`）。回滚点 = `1692f7fde`。
- [x] **清场**：111 工作区有 3 个 `.bak.20261112` 未跟踪文件（旧的手工备份），会触发 `sync_code`
  的 reset 保护导致**静默跳过同步**。已移到 `/mnt/data/backups/weknora/local-hacks-20261126/`
  （不删除，留证据）；另把 111 上被改过的 `deploy-wkj-dev.sh`（把 `GITEA_REPO` 改成 `weikejia/WeKnora`）
  `git checkout --` 还原 —— 那两行是**未经评估的现场改动**，且 `weikejia/WeKnora` 在 Gitea 上
  301 到 `DZSOFT/WeKnora`（我们脚本用的是 `wakeagent/WeKnora`，同样 301），三者指向同一仓库，
  故还原无副作用。
- [x] **代码同步**：`deploy-wkj-dev.sh sync` → 111 到 `1a380279d`；`migrations/versioned/000137`、
  `migrations/sqlite/000053` 已就位。
- [x] **合并 commit**：`dfa3c6e11`（merge）+ `1a380279d`（my-frontend 同步）。
- [x] **`build` 失败 → 改用 `push-app` 路径**：见 §6.1（**本轮最重要的教训**）。
- [x] **push-app**（04:44–04:49）：编译镜像重建 → Rust anydoc `libanydoc_go.a`（26s）→ Go 全量编译
  → `.build/WeKnora` 279M（commit `2028a3de` 命中 7 处）→ 重启 app。
- [x] **迁移 000137 一次通过**：`136 → 137`，`dirty=false`，无需人工干预。
- [x] **push-ui**（04:55）：本地构建 26M（216 assets，i18n 已拆成 6 个独立 locale chunk）
  → rsync 到 111，容器内 216 个 assets。
- [x] **前端镜像重建**：`build frontend frontend-wkj`（各 ~19s）+ `up -d --no-deps` 重建容器
  —— **这一步不可省**，见 §6.2 第 1 条。重建后 `docker restart weknora-nginx` 刷新 DNS。
- [x] **push-reader**（05:02）：docreader 重启加载新 parser（含新增 `csv_converter.py`）。
- [x] **neo4j 重建**（05:04）：本轮官方新增 healthcheck，需重建容器才生效 → `healthy`。
- [x] **验收**：见 §6.2，**全部通过**。

### 6.1 ⚠️ 首次 `build` 失败：inode 耗尽（不是磁盘空间）

**现象**：`./deploy-wkj-dev.sh build` 在 Go 编译与 docreader `uv sync` 阶段同时失败，报大量
`no space left on device`，而 `df -h /mnt/data` 显示 **14T 可用 / 9% 已用** —— 极易误判为"磁盘没满，见鬼了"。

**真正原因**：**inode 耗尽**。

```bash
df -i /mnt/data
# Filesystem    Inodes   IUsed  IFree IUse% Mounted on
# /dev/sdb1    3814912 3805667   9245  100% /mnt/data      ← 只剩 9245 个
```

**inode 去哪了**（`du -s --inodes` 实测）：

| 路径 | inode 数 | 说明 |
|---|---|---|
| `/mnt/data/containerd` | **3,055,210** | ⚠️ 绝对主因：Docker 的镜像层与 BuildKit 快照（3 个 snapshotter 目录 + 2310 个 snapshots） |
| `/mnt/data/docker` | 911,717 | docker rootfs / overlay / buildkit |
| `/mnt/data/silo` | 311,496 | 与本项目无关 |
| `/mnt/data/dsh-web` | 103,569 | 与本项目无关 |
| `/mnt/data/litellm-langfuse` | 101,124 | 与本项目无关 |
| `/mnt/data/weknora` | 11,185 | 本项目（含 `.build` / `migrations` / 前端 dist） |

**为什么 build 特别吃 inode**：`docker compose build` 要跑 browserskill（Rust + pnpm）、
app builder（Go 全量 + cgo + Rust anydoc）、docreader（uv sync 装数百个 Python 包）。
三者各解压数万个小文件到 BuildKit 快照层，同时还有 102.6GB 历史构建缓存 ⇒ 一次就撞顶。

**处置**（只动构建缓存，不碰运行中容器与数据）：

```bash
docker builder prune -f --filter until=24h    # 耗时约 20 分钟（机械盘，逐文件 unlink）
# 效果：IUse% 100% → 94%，IFree 9,245 → 231,067（+24.9 万）
docker image prune -f                          # 0B（无悬空镜像）
```

⚠️ **prune 期间 IO 打满、耗时远超预期**（机械盘 + 逐文件删除）。这本身就是
「Docker data-root 在机械盘」的又一次实证（呼应第 14 轮 §8.1）。

**由此得出的更重要结论**：**本轮根本不需要 `build`**。
`build` 的意义是重建**镜像层**，而镜像层里只有两样东西是我们关心的：
① `Dockerfile.app` 里 pinned 的 BrowserSkill 扩展（0.4.1）② `Dockerfile.docreader` 的 Python 依赖。
本轮官方 `git diff --name-only e3fb2335b..b2c9edcd5 -- docker/` = **0**（两个 Dockerfile 一字未动），
BrowserSkill pin 也仍是 `0.4.1`（`scripts/browserskill-release.json` 未变）。
⇒ **镜像基座无需重建**，只需更新「外置的应用代码 + 外置迁移」，而 `push-app` /
`push-ui` / `push-reader` 正是为此设计的。改用这三条路径后，总耗时从「2 小时+」降到
**约 12 分钟**（push-app 5min + push-ui 1min + 前端镜像 40s + reader/neo4j 各 1min）。

**判据（下次直接照做）**：

```bash
# 本轮是否需要 build？只看这两条 —— 都为 0/未变就不必 build
git diff --name-only <上轮合并点>..<本轮> -- docker/ | wc -l     # 0 ⇒ 镜像基座没变
git diff --name-only <上轮合并点>..<本轮> -- scripts/browserskill-release.json  # 空 ⇒ 扩展 pin 没变
```

⚠️ 但**前端镜像仍需重建**：`frontend/` 官方前端没有 bind mount，静态文件全在镜像层
⇒ `push-ui` 只更新定制前端（`my-frontend/dist` 挂载），**41200 那侧必须重建镜像**。
这一条与 inode 无关，是结构决定的。

**根治建议（未实施）**：把 Docker data-root 从 `/mnt/data`（机械盘、381 万 inode）迁到
根盘 NVMe（937G，4% 已用，ext4 inode 更多），或对 `/mnt/data` 重新 `mkfs` 提高 inode 数
（需重挂载，风险高）。前者在第 14 轮 §8.1 就已列为加速项，本轮再次被 inode 撞出来。

### 6.2 验收清单（部署后逐条核对，本轮全部通过）

| # | 判据 | 实测 |
|---|---|---|
| 1 | 四个容器镜像 ID = tag 当前 ID | **全部 ✔ 一致**（app / docreader / frontend / frontend-wkj） |
| 2 | 库版本 `137/f`、`dirty=false` | **137\|f** ✔ |
| 3 | `idx_channel_lookup` 含 `thread_id = ''` | ✔ `WHERE ((deleted_at IS NULL) AND ((thread_id)::text = ''::text))` |
| 4 | neo4j 有 healthcheck 且 healthy | ✔ `health=healthy`（重建前为 `NO_HEALTHCHECK`） |
| 5 | 三个入口 200 | 41200 **200** / 41280 **200** / 41201 health **200** |
| 6 | `/api` 走前端返回 401（非 502 ⇒ 代理链路通） | 41200 **401** / 41280 **401** ✔ |
| 7 | 容器组全绿 | app/docreader/frontend-wkj/neo4j/postgres **healthy**；frontend 无 healthcheck 定义但 Up |
| 8 | searxng 有结果（不只看 200） | **16 条** ✔ |
| 9 | neo4j Bolt 7687 可连 | ✔ `BOLT_OK` |
| 10 | 定制前端 assets 已投递 | 容器内 **216** 个（与官方前端同数） |
| 11 | app 二进制内嵌 commit | 命中 **7 处**（`2028a3de`） |
| 12 | 2560 维 HNSW 索引 | **尚未建立** —— 属预期，见下 |

**第 12 条说明**：111 库里有 2560 维向量 **12882 条**（1024 维仅 5 条），而 pgvector 索引
只有 1024 / 3584 / 798 三个维度。新代码的 `ensureHNSWIndex` 是**惰性**的 ——
只在「首次写入或查询该维度」时于后台 `CREATE INDEX CONCURRENTLY`。
所以升级完**不会**立刻出现 `embeddings_embedding_idx_2560`，要等第一次真实检索之后。
⇒ **下次做一次检索后再查 `pg_indexes`**，若出现该索引即为生效；若没出现，看 app 日志的
`[Postgres] HNSW index for 2560-dim embeddings: ...` 告警（会把失败原因与处置办法一起打出来）。

### 6.3 遗留事项

- **2560 维 HNSW 索引待触发**（见 §6.2 第 12 条）：需一次真实检索验证。
- **Docker data-root 仍在机械盘 + inode 仅剩 23 万**：下一轮若还需 `build`，大概率再次撞顶。
  根治方向见 §6.1 末段。
- **`my-docs/75-全盘文档扫描/` 的 4 个大 CSV 未入库**（280MB，走 `.git/info/exclude`）：
  别处 clone 后看不到，需回 111 或原机取。

## 7. 本轮顺带处理

- 合并前工作树有一批未提交/未跟踪改动（`my-docs/18`、`my-docs/75`、`my-docs/83`、`my-docs/84`、
  `my-scripts/pack_browserskill_ext.sh`、`AGENTS.md` 指针行）。已先提交为 `959684c61` 清场。
  ⚠️ `my-docs/75-全盘文档扫描/` 里 4 个 CSV **共约 280MB**（文档 45M / 代码文本 220M / 图片 14M / 压缩包 1M），
  只把**小文件与脚本**入库，大 CSV 走 `.git/info/exclude`（本地配置、不入库）——
  与 AGENTS.md 第 7 条「本地参考不入版本控制」同源，但**别处 clone 后需自行补 exclude**。
- 第 3 轮分析文档里两处 `my-docs/91-深度使用说明/` 旧路径已订正为 `my-docs/83-实际使用/`。
