# WeKnora 官方 main 更新分析（第 2 轮）

> 同步区间：`cc82e75c` → `6afb6ca9`（25 个提交）
> 合并结果：wkj-dev 上 `a7929c73`（Merge branch 'main' into wkj-dev）
> 回滚点：`eb347500`（合并前 HEAD）
> 日期：2026-09-22

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **25** |
| 是否发版 | **否** —— `git describe --tags main` = `v0.8.0-246-g6afb6ca9`（仍是 v0.8.0 之后） |
| 改动面 | 官方 212 文件 / 我方 827 文件 |
| **冲突** | **零** —— 三点比较交集为空（第 3 次验证物理分离有效） |
| 依赖变更 | 无 `go.mod` 变更 ⇒ 无需 `go mod download` |
| 编译 | `go build ./...` **exit=0**（34 秒，仅 1 个无害的 `ld: duplicate libraries '-lc++'` 警告） |
| fetch 耗时 | 4 分 38 秒（与上轮 4 分 20 秒相当） |
| 合并规模 | 1039 文件、+281708 / −741 |

新增内容以 **bug 修复为主**：2 个 `feat` + 23 个 `fix`。

## 二、更新内容（使用视角）

### 2.1 新功能（2 个）

**① 知识库「卡住」检测**（`6afb6ca9`，#3557）

以前文档卡在"处理中"和真在跑长得一模一样：转圈、无提示，几小时后只在清理时抛一个笼统失败。现在：

- 批量与 span 端点新增 `last_activity_at`（取 `updated_at` 与最新 span 写入的**较晚者**——
  `updated_at` 只在阶段切换时动，而 span 在长阶段里持续写入）
- **20 分钟无进展** ⇒ 列表与卡片显示「可能已卡住」+ tooltip；时间线显示**停在哪一阶段**
  并给出「停止解析」按钮与"最后进展"统计
- 全部在途任务停滞时，轮询退避到 15 秒
- 清理失败时，错误信息**点名停滞阶段与最后进展时间**，并以 `TASK_STALLED` 关闭该行
  未完成的 span（运行中的标 failed、其余标 cancelled）

> 这条正好补上了我们《知识库数据模型与流程机制》里写的那个判断：
> **`finalizing` 极易被误判为卡住**。上游现在给了显式信号，不再需要凭经验猜。

**② 沙箱：Lite 会话跑在宿主 OS 沙箱**（`22cbcdfa`，#3549）

引入 `WorkspaceLayout`：远程会话保持 `/workspace` 契约，本地会话按 session layout 解析路径；
配套 fail-closed 加固（拒绝 ReadRoots 之外的 inspect、输出树缺失或等于项目根时跳过收集）。
**我们用标准版（容器），不受影响。**

### 2.2 修复中与我们直接相关的（3 条）

**① docreader：中文图注导致整篇文档解析失败**（`ae185dd1`）

根因链条很隐蔽：

```
Markdown: ![x](data:image/png;base64,iVBORw0KGgo= "图片")
                                        └── 正则 ([^\)]+) 把 "图片" 也吃进 payload
base64.b64decode 对非 ASCII str 抛 ValueError（而非 binascii.Error）
  ⇒ encode_image 只 catch 了 binascii.Error ⇒ 逃逸
  ⇒ MarkdownImageBase64.parse_into_text / PipelineParser / BaseParser.parse 均未 catch
  ⇒ ValueError 抵达 gRPC handler ⇒ 整个文档返回
     ReadResponse(error="string argument should contain only ASCII characters")
```

修复位置：`docreader/utils/endecode.py`。

> **对我们的意义**：我们处理的文档全是中文，Markdown 里带中文图注的图片很容易命中这条路径。
> 本轮值得优先跟进。注意它与我们的 docreader 定制（`docreader/parser/markitdown_parser.py`）
> **不在同一文件**，互不冲突。

**② browserskill：连接容量永不释放**（`da049f04`）

`BROWSERSKILL_MAX_CONNECTIONS`（默认 32）统计的是**最近 90 天服务过的所有成员**：

- 已断开的设备不从 device map 移除，直到其授权过期
- 被拒绝的 lease claim、或 pre-pairing 阶段的 select 创建的设备 `expires=0` ⇒ **永不驱逐**
- 后果：**32 个不同成员连过之后，第 33 个即使只有 1 人在线也会被拒**

修复后：容量只统计 **live + handshaking** 成员；其他成员的 idle 设备在下一次获取时驱逐；
握手期间预留设备以免中途被驱逐；daemon 拨号与 WS upgrade **不再在设备锁下执行**
（此前会阻塞其他成员的设备获取）；增加握手超时。

> 这正是我们浏览器技能手册里"'32'是非实测承载量"那句话背后的真实缺陷。

**③ 知识库处理卡死系列**（4 个提交）

| 提交 | 修了什么 |
|---|---|
| `d951cb78` | 处理→收尾交接写库失败时**假 ack**，读作"已不再处理"⇒ 行卡住且无重试；<br>且读行失败被误判为"正在删除"⇒ **会清掉活文档的分块与索引**并静默返回；<br>另把 handler panic 转成 error（在死信中间件之下），使最后一次尝试能把行标 failed |
| `af3ac25b` | **Wiki 队列卡死**：housekeeping 会跳过任何仍持有 wiki ingest op 的行且无年龄上限，<br>于是 wiki 被禁用 / 无合成模型 / 模型被删的库，文档**永远停在 finalizing**。<br>现把这些视为终态：清空未被认领的 op 并释放文档 |
| `0b4cd706` | 不再把「从未跑过的阶段」标成 failed（Closes #3452）。<br>`buildSpanTree` 此前按 `parse_status` 推断所有无 span 的阶段状态，<br>无法区分"跑了并失败"与"从未跑过" |
| `0a99a285` | 上述修复的 review 修订 |

### 2.3 其余修复

- **MCP**（3）：多行 SSE 事件先拼装再解析（`273db881`）；端点经前端网关代理（`733fdd69`）；
  按**存储 ID** 而非端点 ID 解析 MCP 会话（`7feac9c5`）
- **上传**（2）：清理 multipart 临时文件（`d1691cbc`）；在解析引擎探测前接受 XMind（`58260d19`）
- **chat**（2）：暴露被截断的快速回答（`78d7d862`）；流结束后恢复共享工作区图片（`33c0333e`）
- **skill/sandbox**（2）：create-time 沙箱环境变量计入必需检查（`e55e3423`）
- **rerank**（1）：为每个厂商固化请求并纠正三处事实（`4640a1ea`）
- **helm/docker**（2）：**MinIO 镜像改到 `quay.io/minio/minio`**（见下）

### 2.4 ⚠️ 须知变更：MinIO 镜像源

`3a8ce97c` + `8783a993`：**MinIO 不再发布到 Docker Hub**，compose 与 helm 均改为
`quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`。

官方 `docker-compose.yml` 本轮**只改了这 2 行**（`minio` 与 `langfuse-minio` 两处），等长替换，
**行号未变**。

> 我们用 `STORAGE_TYPE=local`，不启用 MinIO ⇒ **无影响**。若将来改用 MinIO，注意镜像源已变。

## 三、二开影响评估

### 3.1 完整性校验（合并后必做）

| 检查 | 结果 |
|---|---|
| `comm -23 dev.txt after.txt`（我方改动是否丢失） | **空 ⇒ 零丢失** |
| 关键二开目录存在性 | `my-docker` / `my-frontend` / `my-docs` / `my-scripts` / `my-docreader` / `deploy` / `AGENTS.md` **全部 ✓** |
| 冲突文件（`--diff-filter=U`） | **空** |

### 3.2 官方改了我们依赖的文件吗？

**没有。** 三点比较交集为空，官方 212 个改动文件与我们的 827 个**零重叠**。

单点复核：

| 我方关注的文件 | 官方本轮是否改过 | 结论 |
|---|---|---|
| `docker/Dockerfile.app` | **否** | 我们的改动仍必要、不冲突 |
| `docker/Dockerfile.docreader` | **否** | 同上 |
| `docreader/parser/markitdown_parser.py`（我们的 PP-OCRv6 定制点） | **否** | 不冲突 |
| `docreader/utils/endecode.py` | 是 | 与我们**不在同一文件**，且该修复对我们有利 |

### 3.3 前端副本同步（本项目特有，必做）

**判据执行结果**：

```
官方本轮改动的前端文件数：32
合并前副本与官方的差异数：26      ← 差异全部可归因于官方
comm -13（无法归因于官方的）：空  ← 我方确实零改动
```

⇒ 按老魏的判断**整体覆盖**：

```sh
rsync -a --delete --exclude='node_modules' frontend/ my-frontend/
```

覆盖后 `diff -rq frontend my-frontend` **只剩 1 行**（`Only in my-frontend: node_modules`），
即副本与官方**逐字一致**，"逐字副本"判据完整恢复。

`my-docker/README.md` 的「副本复制点」已更新：`cc82e75c` → **`6afb6ca9`**。

## 四、判断：那 2 个 Dockerfile 的修改是否还有必要？

**仍必要。** 判据：

```sh
git diff -U2 main..HEAD -- docker/Dockerfile.app docker/Dockerfile.docreader
```

- 本轮官方**未改动**这两个文件 ⇒ 不存在"官方已实现、我们冗余"的情况
- 我方改动仍在：`Dockerfile.app` +64/−3、`Dockerfile.docreader` +11/−2

**上轮已确认的结论本轮依然成立**（无需重新论证）：我们**真正领先**的只有
`RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` /
`CARGO_REGISTRY_ARG`，以及 browserskill 阶段的 `APK_MIRROR_ARG` 条件换源。
其余符号（`GOPROXY_ARG` 等）官方一直就有，在 diff 里是**上下文行**，不是我们加的。

**能否不改文件？** 不能。Docker `--build-arg` 只有 Dockerfile 里 `ARG` 声明过才可用。

## 五、连带发现

### 5.1 ★ 官方被改文件实际是 **3 个**，不是 2 个

本轮复核 `git diff --name-status main..HEAD` 后，排除二开目录，官方文件里被我们改过的是：

```
M	docker/Dockerfile.app
M	docker/Dockerfile.docreader
M	docreader/parser/markitdown_parser.py     ← 第 3 个
```

第三条（PP-OCRv6 相关，加 2 处、带 `★ wkj 定制` 标记）**已记录在 overlay 的文件头注释里**，
但 **`AGENTS.md` 第 1 条的例外清单只写了 2 个 Dockerfile**（原文"唯一例外（此外无第二个）"）。

⇒ 口径与实际不一致。**已向老魏提出，等他决定是否修订 AGENTS.md**
（规约类表述按其惯例属用户口径，不擅自改）。

### 5.2 行号引用失真清单（本轮实测）

官方插行会让 `文件:行号` 静默失真。本轮全量核对 18 处引用，**6 处已偏**：

| 引用 | 文档原写 | 实际 | 性质 |
|---|---|---|---|
| `.env.example` WSS 段 | `:779` | **785** | 配置类 ⇒ **本轮已改为符号引用**（`nginx.conf` + `nginx/README.md` 两处） |
| `Makefile` COMMIT_ID | `256-259` / `262` | **275** / **281** | 分析/运维文档，未改 |
| `Dockerfile.app` uv install | `:122` | **180** | 分析文档，未改 |
| `Dockerfile.app` GOPROXY_ARG | `:23` | **68** | 分析文档，未改 |
| `Dockerfile.app` builder 段 | `59-61` | 已分散到 32/42/68 | 分析文档，未改 |
| `Dockerfile.docreader` protoc | `:60` | **56** | 分析文档，未改 |

**正确的引用**（本轮核对无误）：`.env.example:74`（AUTO_MIGRATE）、
`docker-compose.yml:1032`（volumes 段）、`docker-compose.yml:602`（searxng profiles）、
`docs/browser-skill-production.md:88`、`internal/browserskill/manager.go`（WSS 校验现为 **196**，
文档写 178-190 亦已偏）。

**处置原则**：配置类注释一律改用**符号引用**（靠段名/键名定位）；分析类文档保留行号但须知会过期。

### 5.3 新增数据库迁移

本轮带来 `migrations/versioned/000109_session_host_workspace_dir.up.sql`（配套 sqlite 侧 000029）。

⇒ **下次部署到 111 时，app 重建会执行这条迁移**。按既有纪律，动 app 前先备份
（迁移本身是加列，风险低，但流程不变）。

## 六、待办

| # | 事项 | 状态 |
|---|---|---|
| 1 | 合并到 wkj-dev | ✅ 完成（`a7929c73`） |
| 2 | 前端副本整体覆盖同步 | ✅ 完成（差异仅剩 `node_modules`） |
| 3 | 副本复制点更新 | ✅ 完成（`6afb6ca9`） |
| 4 | 配置类行号引用改符号引用 | ✅ 完成（nginx 两处） |
| 5 | **AGENTS.md 例外清单补第 3 个文件** | ⏸ **待老魏定**（涉及口径） |
| 6 | 分析文档里的 5 处行号失真 | ⏸ 未改（性质为历史分析，可保留） |
| 7 | 推送到 gitea / gitea110 | ⏸ 老魏未要求，不主动推 |
| 8 | 部署到 111（会触发 000109 迁移） | ⏸ 待定 |

## 七、证据

```sh
# 同步区间与规模
git rev-parse --short main                    # 6afb6ca9
git rev-list --count wkj-dev..main            # 25
git describe --tags main                      # v0.8.0-246-g6afb6ca9

# 冲突预判（MB=cc82e75c）
comm -12 /tmp/up.txt /tmp/dev.txt             # 空（官方 212 / 我方 827）
git diff --name-only --diff-filter=U          # 空

# 合并
git merge main --no-edit                      # a7929c73
git diff --name-only cc82e75c..HEAD | wc -l   # 1039
git diff --shortstat cc82e75c..HEAD           # 281708 insertions(+), 741 deletions(-)

# 完整性
comm -23 /tmp/dev.txt /tmp/after.txt          # 空（零丢失）

# 编译
go build ./...                                # exit=0（34s）

# 前端副本
diff -rq frontend my-frontend                 # Only in my-frontend: node_modules

# 官方文件改动面（排除二开目录后的 M/D）
git diff --name-status main..HEAD | awk '$1=="M"' | grep -vE "my-|deploy/|AGENTS"
#   M docker/Dockerfile.app
#   M docker/Dockerfile.docreader
#   M docreader/parser/markitdown_parser.py
```
