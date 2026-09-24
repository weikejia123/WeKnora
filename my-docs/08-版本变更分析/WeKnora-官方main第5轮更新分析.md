# WeKnora 官方 main 更新分析（第 5 轮）

> **区间**：`1fa915d7` → `2e712a97`（**6 个提交**）
> **本机结果**：合并提交 `68935d82`（0 冲突）· 副本同步 `367579f3`
> **前置轮次**：`WeKnora-官方main第1/2/3/4轮更新分析.md`
> **一句话结论**：本轮是**小步修复轮**（6 提交 / 145 文件，其中 117 个是官方文档站资源），
> 无新发版、无迁移、**依赖面未动**、`go build` 通过；官方**未动我方 2 个例外文件**，
> 因此**不需要 build，也不需要重新部署**。顺带订正了 3 处历史遗留的行号漂移。

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **6** |
| 发版状态 | 无新 tag（`git describe --tags main` = `v0.8.0-279-g2e712a97`）；但有一条 **v0.8.2 文档同步**（`be46eaba`） |
| 规模 | **145 文件，+4015 / −1076** |
| 改动分布 | `website-docs/` **117** · `internal/` 16 · `frontend/` 8 · `config/` 2 · `docker-compose.yml` 1 · `CHANGELOG.md` 1 |
| 依赖面 | `go.mod` / `go.sum` / `docreader/requirements.txt` / `frontend/package*.json` **全部未动** |
| 数据库迁移 | **无**（`migrations/` 0 改动） |
| 编译验证 | `go build ./...` ⇒ **exit=0**（仅 `ld: warning: ignoring duplicate libraries: '-lc++'`，无害） |
| 冲突预判 | 三点比较**交集 0**；`merge-tree` 预演只输出 tree OID ⇒ **干净** |
| 我方改动面 | 官方 145 / 我方 855 文件，**零重叠** |
| fetch 耗时 | **3 秒**（VPN 有效；对比：VPN 前曾 11 分钟未完成） |

---

## 二、更新内容（使用视角）

### 2.1 MCP 相关修复（2 条）—— 本轮最可能被用户感知

| 提交 | 现象 |
|---|---|
| `2e712a97` | `fix(mcp): return accessible image URLs from existing tools`（#3650）—— 既有 MCP 工具返回的图片 URL 改为**可访问地址**（此前返回的 URL 客户端取不到） |
| `e87607e8` | `fix(mcp): expose wiki output in structured content`（#3590）—— wiki 输出进入**结构化内容**（此前只在正文里） |

> 判据：改动集中在 `internal/mcpserver/`（`resource_urls.go` / `scope.go` / `server.go` / `tools_ask.go` 及配套测试）。

### 2.2 GitLab 数据源修复（2 条）

| 提交 | 现象 |
|---|---|
| `60802717` | `fix(gitlab): 补齐项目资源列表分页` —— 项目列表分页此前不完整（超过一页会漏） |
| `11edd168` | `fix(datasource): fail closed on GitLab compare errors` —— compare 出错时**改为 fail closed**（此前可能放行） |

> 判据：`internal/datasource/connector/gitlab/{client,connector}.go`。

### 2.3 文档站（2 条，占本轮 117 个文件）

| 提交 | 现象 |
|---|---|
| `be46eaba` | v0.8.2 的 `website-docs` / 首页 / CHANGELOG 同步（含新增截图） |
| `4a026fc8` | `fix(docs): update remaining references to migrated documentation` —— 官方自己**收尾** `docs/` → `website-docs/` 迁移后的残留引用 |

★ 与本项目**无冲突**：我方文档引用在第 3 轮已用官方 `website-docs/MIGRATION.md` 做过映射。

### 2.4 官方编排的一处注释订正

`docker-compose.yml` 唯一改动是第 321 行的一行注释：
`# 见 docs/QA.md…` → `# 见 website-docs/01-getting-started/04-configuration.md…`。
**行数不变** ⇒ **本轮未造成任何行号漂移**（这点很关键，见 §五.1）。

---

## 三、二开影响评估

### 3.1 合并记录

| 步骤 | 提交 | 说明 |
|---|---|---|
| 合并上游 | `68935d82` | **0 冲突**（见 §3.2） |
| 副本同步 | `367579f3` | 8 文件 + 修正副本复制点 |

回滚点：`5e14e7b0`（合并前 HEAD）。

### 3.2 冲突预判：两种独立方法都指向零冲突

```sh
# 方法一：三点比较（以 merge-base 1fa915d7 为基准）
git diff --name-only $MB..main    | sort > /tmp/up.txt    # 145 文件
git diff --name-only $MB..wkj-dev | sort > /tmp/dev.txt   # 855 文件
comm -12 /tmp/up.txt /tmp/dev.txt                          # → 空（交集 0）

# 方法二：不碰工作区的预演
git merge-tree --write-tree --name-only wkj-dev main
# → be9606810fb53c82e9520923548ebe7bca5f4d40（单个 tree OID，无文件名 = 干净）
```

★ **「交集为空」不是定理** —— 第 3 轮就出现过交集命中我方例外文件的情况（官方删了我方 diff 里的上下文行）。
⇒ 每轮都要**双方法实测**，不要默认无事。

### 3.3 二开完整性校验（零丢失）

```sh
comm -23 /tmp/dev.txt /tmp/after.txt   # → 空（我方改动无丢失）
```

关键目录逐个实测：`my-docker` ✓ `my-frontend` ✓ `my-docs` ✓ `deploy` ✓ `AGENTS.md` ✓ `my-scripts` ✓

### 3.4 前端副本同步（判据成立）

| 判据 | 结果 |
|---|---|
| 差异归因 | 差异 10 条，**除 `dist`/`node_modules` 两个构建产物外全部可归因于官方** ⇒ 整体同步 |
| 同步后判据 | `diff -rq frontend my-frontend` = **恰好 2 行**（仅两个产物目录） |
| 跟踪文件数 | `frontend` **811** = `my-frontend` **811** |
| 产物未被触碰 | `dist/index.html` 的 sha256 同步前后一致（`6a3b5c24…`） |
| ★ 副本复制点 | `my-docker/README.md` 由 `a89a5a2c` → **`2e712a97`**（见 §五.2） |

---

## 四、★ 2 个例外 Dockerfile 的必要性判断

**结论：仍必要，且本轮官方未动它们。**

| 项 | 结果 |
|---|---|
| 官方是否改动 | **未动**（`git diff --name-only $MB..main -- docker/Dockerfile.app docker/Dockerfile.docreader` → 空） |
| 我方领先项 | `APK_MIRROR_ARG` 条件换源（browserskill 阶段，slim 基镜像无 CA）+ `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` |
| 判定 | **全部仍在** ⇒ 两个例外继续保留 |

★ **判据提醒（沿用第 3 轮的教训）**：只看 diff 的 `+`/`-` **行归属**。
官方版也声明了 `GOPROXY_ARG` / `GOSUMDB_ARG` / `VERSION_ARG` / `APT_MIRROR` 等，
它们在 diff 里是**上下文行** ⇒ 说明官方一直就有，**不是我们加的**。

---

## 五、连带发现

### 5.1 ★ 行号引用核查：本轮零新增漂移，但查出 3 处历史遗留

按同步流程核对我方文档里的「官方文件:行号」引用（共 30 处）。分两类：

**（a）行号敏感文件是否被本轮改动**：

| 文件 | 本轮是否改动 | 结论 |
|---|---|---|
| `Makefile` / `.env.example` / `docker/` | **未动** | 相关引用不受影响 |
| `internal/container/container.go` | **未动**（改的是 gitlab / mcpserver） | 相关引用不受影响 |
| `docker-compose.yml` | **改了，但仅 1 行注释替换（行数不变）** | **不产生漂移** |

**（b）但核对被引用行的「实际内容」时，查出 3 处对不上**（历史遗留，非本轮造成）：

| 文档写的 | 实际位置 | 处置 |
|---|---|---|
| `docker-compose.yml:602-604`（searxng profiles） | **608-610** | 已订正为「`searxng` 服务段内 `profiles:`（本版 :608-610）」 |
| `docker-compose.yml:558-572`（`searxng-init` 段） | **565** 起 | 已订正为「`searxng-init` 段（本版起于 :565）」 |
| `docker-compose.yml:1032-1035`（三个数据卷） | **1038** 起 | 已订正为「顶层 `volumes:` 段（本版起于 :1038）」 |

**订正手法**：改为「**段名 + 本版行号**」形式 —— 段名抗漂移（上游怎么挪都认得出），
行号仅供当次定位。这与配置注释「改用符号引用」的原则一致。

波及文件：
- `my-docs/14-联网搜索/WeKnora-自带搜索SearXNG接入与引擎选型.md:188-189`
- `my-docs/11-数据安全与备份/WeKnora-数据安全与备份方案.md:418`

★ **未动**「欠债登记」类引用（如 `my-docs/09-二开现状基线:83` 的 `Makefile:256-259`→275）
—— 那是**记录**旧值到实际值的映射，改左半边会让它自相矛盾（技能 §9.3 的坑）。

### 5.2 ★ 同步流程自身的两个缺陷（已修）

| # | 缺陷 | 处置 |
|---|---|---|
| 1 | **副本复制点字段漏更**：`my-docker/README.md` 还停在 `a89a5a2c`（第 3 轮），而第 4 轮已同步至 `1fa915d7` —— 该字段位于同步流程末尾，**极易漏** | 已更新为 `2e712a97`，并在字段处**标注自查提示** |
| 2 | **同步技能内部不一致**：第 4 步写 `git merge main --no-edit`（生成英文默认消息 `Merge branch 'main' into wkj-dev`），而第 11 步自己要求「中文 Conventional Commits」 | 已把合并提交 amend 为中文；技能同步修正 |

> 第 1 条的根因值得记：**第 4 轮同步时我没有先读本技能**，于是漏了只写在流程末尾的这一步。
> ⇒ 纪律：**执行同步前先通读技能**，而不是凭记忆走流程。

---

## 六、待办

| # | 事项 | 说明 |
|---|---|---|
| 1 | **无需部署** | 本轮未动我方例外文件、无迁移、依赖面未动 ⇒ 111 上的现版本仍是最新可用版本 |
| 2 | MinerU-4 引擎 | 方案已落 `my-docs/16-解析引擎扩展/`，**待用户确认是否接受改动面扩大**（2 → 10+） |
| 3 | 其余行号引用 | 已核对的是「官方文件」类；`my-docs/0x-*` 内部互引未逐个核（价值低，暂缓） |

---

## 七、证据（可复核）

```bash
# 规模与发版
git rev-list --count wkj-dev..main          # → 6
git describe --tags main                    # → v0.8.0-279-g2e712a97
git diff --shortstat wkj-dev...main         # → 145 files, +4015 / -1076
git diff --name-only 1fa915d7..main -- go.mod go.sum frontend/package.json   # → 空

# 冲突预判（双方法）
MB=1fa915d7
comm -12 <(git diff --name-only $MB..main | sort) <(git diff --name-only $MB..wkj-dev | sort)   # → 空
git merge-tree --write-tree --name-only wkj-dev main    # → 单个 tree OID

# 例外文件未被官方触碰
git diff --name-only $MB..main -- docker/Dockerfile.app docker/Dockerfile.docreader   # → 空

# 副本判据
diff -rq frontend my-frontend | wc -l                  # → 2
git ls-files frontend | wc -l; git ls-files my-frontend | wc -l   # → 811 / 811

# 编译
OUT=$(go build ./... 2>&1); RC=$?; echo "exit=$RC"     # → exit=0
```

**提交链**：`5e14e7b0`（回滚点）→ `68935d82`（合并）→ `367579f3`（副本同步）
