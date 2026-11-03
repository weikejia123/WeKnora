# WeKnora 官方 main 第 13 轮更新分析（2026-11-03）

> 同步区间：`450b6ed1`（第 12 轮复制点）→ `02e30e9f`，共 **428 个提交**，官方发版 **v0.9.0**（main 现位于 v0.9.0 后 127 个提交）。
> 本轮为我方主动发起的完整同步：合并 → 校验 → 副本同步 → 引用订正。

## 1. 概览

| 项 | 值 |
|---|---|
| 提交数 | 428（fix 347 / feat 60 / perf 5 / refactor 3 / test 3 / docs 3 / 其余 2） |
| 发版 | **v0.9.0**（本轮区间内发布，`VERSION` = 0.9.0） |
| 官方改动面 | 2269 文件 |
| 我方相对官方差异面（合并后） | 974 文件 |
| 交集 | 仅 2 个例外 Dockerfile（见 §4），且**本轮零冲突**自动合并 |
| `go build ./...` | **exit=0**（仅 macOS 桌面构建既有 ld 重复库警告 + sqlite3.h deprecation 提示） |
| 合并提交 | `b77857f6a`；回滚点 = 合并前 `0aa646540` |

## 2. 更新内容（用户可感知）

v0.9.0 是**平台化大版本**：主线从"知识库 + 聊天"扩展到 **Assistant 管理台 + Agent 协作 + 自动化 + 沙箱双模式**。

### 主题一：Assistant / Agent 平台化（本轮最大主题，约 15+ 提交）
- **多 Agent 协作**：持久化协作任务 + 实时任务视图（#4438）。
- **统一权限模型**：agent grants + run modes（#4490），配套 `agent_grants` / `mcp_tool_risk` 迁移。
- **管理面扩展**：助手可管理知识库（#4353）、管理 agent 与 skills（#4344）、试验运行 / 会话授权 / MCP·模型·技能管理（#4375）、扩大管理操作 + 交互打磨（#4427）。
- **上下文感知入口**：任意页面带引导动作唤起（#4757/#4758），欢迎问题按当前页面定制（#4762）。
- **技能发现**：助手可联网检索 skills 与 MCP 服务（#4429）。

### 主题二：自动化（定时 Agent）
- 定时 agent 运行 + 应用内通知收件箱（#4492）；模型设置、任务控制完善（#4514）；
  重构为**经 assistant 执行**的定时任务（#4522）。配套 `automations` 系列迁移（000128/000131/000132/000133）。

### 主题三：沙箱双模式
- 双模式沙箱分配基础（门控关闭，#4507）、按分配记录定位（#4509）、**共享机器用户模式闭环**：删除/回收/管理与桌面（#4510）。
- **会话隔离桌面 + agent-browser 登录共享**（#4785）；共享沙箱短会话目录、移除工具层目录限制（#4533）。
- 修复面：Cube 可写层提到 64G（#5046）、Docker Desktop socket 权限（#3088）、桌面与 agent 共用同一浏览器会话（#5035）。

### 主题四：数据源扩展
- **Confluence**：PAT 认证（#4549）、文档附件同步（#4953）、保留页面表格结构（#4795）。
- **Nextcloud WebDAV 连接器**（#4601）。
- **飞书/Lark 深度适配**：文件夹镜像、块解析、嵌入对象（#3497）——本轮 fix 面中 datasource/feishu 占比高即源于此。
- 钉钉数据源保留来源目录结构（开关，默认关，#4422）。

### 主题五：检索 / 搜索 / 性能
- **以图搜知识**：knowledge-search 支持图片查询（#4823），且图片查询不进文本兜底（#4921）。
- 同父命中共用一个 top-k 槽位，避免重复挤占（#4740）。
- **HNSW 索引支持任意 embedding 维度**（#3364）——对我们 13-检索性能 方案有直接关联。
- MCP 文档级知识搜索（#4463）；独立 JSON 图谱搜索 API（#4395）。
- perf：查询扩展正则复用（#4309/#4871）、chunker 消除二次方排序（#4633）、sourceloc 单次扫描对齐（#4544）、wiki 图标签批量更新（#4646）。

### 主题六：模型 / Provider
- Claude 5.5 系列进 OpenRouter 目录（#4784）；新增 Runcrate（OpenAI 兼容）provider（#4714）。
- 联网搜索新增 **SearchApi**（#4807）、**DeepSeek search + fetch**（#4792）。
- VLM `VLM_MAX_TOKENS` 可配（#4478，默认 5000）；独立问题生成模型选择（#4718）+ token 预算可配（#4690）。

### 主题七：聊天 / Embed / 后台任务
- **按住说话语音输入**，走 agent 的 ASR 模型（#4804）。
- embed 浏览器本地聊天历史（#4631）；标准版允许显式前端目录（#4637）。
- **共享 background-work 运行时**（#4579）+ web/Lite 异步 shell 作业（#4580）。

### 主题八：图片管线 / 图库
- 硬编码图片流程改为**可配置管线**（#3746）；OCR 前可选有界预处理（#4381）。
- 块级编辑图片 OCR 与说明文字（#4942）；相同图片字节复用 handle，不再重复落盘注册（#4419）。

### 主题九：安全 / 认证
- OIDC **PKCE S256** 可选支持（#4818）。
- 过期 token 刷新不再影响新会话（#4957）；retrieve-scoped API key 可发现共享知识库（#4523）。
- NAT64 受限 IP 判定补测试（#4263，fixes #4092）；请求日志 data URI 脱敏（#4910）；飞书 tenant token 片段不再入日志（#4399）。

### 主题十：系统 / 其他
- `DB_MAX_OPEN_CONNS` Postgres 连接池上限（#4349）；工作区默认模型与搜索设置（#4822，迁移 000134）。
- 文档进度 + 有界 Wiki 启动（#4732）；wiki 支持 manual-only 知识库（#4707）；FAQ 列表视图开关（#4566）。
- tenant-admin memory subject 管理（#4954）；docreader 构建信息显示修正（#4769，配套 compose `VERSION_ARG/COMMIT_ID_ARG/BUILD_TIME_ARG`）。
- v0.9.0 发布准备 + assistant onboarding（#4836）；官网社区 adopter 展示（#4902）。

### fix 面（347 条）——与我们相关的重点
- **agent** 是最大修复域（38 条），围绕新权限模型与协作任务的状态一致性。
- docreader/docparser：MinerU 图片抽取预算（#4963）、混合 PDF 保留图片来源（#4972）、fenced base64 示例保留（#4893）。
- mcp：stale OAuth dialog 失效处理（#4531）。
- search/retrieval：RRF/召回稳定性修复若干；gallery 图片证据编辑对齐查看器控件（#5032）。

## 3. 二开影响评估

- **合并**：`git merge upstream/main` **零冲突**自动完成。两个例外 Dockerfile 均被官方本轮改动（app +14/-4、docreader +4），但官方改的是构建缓存挂载 / Go 版本探测 / `qpdf` 依赖 / 构建元数据 ARG，与我方换源 ARG 无交集；合并后逐行核对，我方 `RUSTUP_*_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` / `PLAYWRIGHT_*` 全部在位。
- **完整性校验**：官方改动面 2269 文件 ∩ 我方差异面 974 文件 = **仅 2 个例外 Dockerfile**；`my-docker / my-frontend / my-docs / deploy / scripts / AGENTS.md` 全部在位。
- **迁移**：新增 versioned 迁移 **15 个（000121–000135）**，本轮无 paradedb/postgres 镜像版本变化（仍 `v0.25.11-pg17`）。⚠️ 其中 `000125_remove_empty_image_chunks` 会**软删**存量的"空图 VLM 假成功 caption"块（限定单图派生块 + 空 SHA-256，走正常删除路径）⇒ **动正式数据**。其余为建表/加列/加索引。111 上 `AUTO_MIGRATE` 默认开启 ⇒ **app 容器重建即自动执行**，部署前先备份（见 §5）。
- **前端副本**：官方动 `frontend/` **427 文件**；合并前已验证 `my-frontend` 与旧官方前端逐字一致（diff=0）⇒ 差异全部归因官方，rsync 整体覆盖后 `diff -rq` = **0**；`package.json` 仅版本号 0.8.3→0.9.0、依赖不变；`npm install` 后 `package-lock.json` 与官方**逐字一致**；工作树文件清单（除 node_modules）两侧 diff=**0**。
- **compose 基底**：镜像全部未变。新增透传变量一批（`DB_MAX_OPEN_CONNS`、`VLM_MAX_TOKENS`、`WEKNORA_WEB_FETCH_TIMEOUT`、`WEKNORA_MCP_ASK_TIMEOUT`、`WEKNORA_MINERU_MAX_IMAGE_BYTES`、`VERSION_ARG/COMMIT_ID_ARG/BUILD_TIME_ARG` 等），均有默认值，**overlay/.env 无需改动**。
- **变量改名（向后兼容）**：`LOG_FORMAT` → `WEKNORA_LOG_FORMAT`（未设置时回落旧变量）。我方 `.env` 中 `LOG_FORMAT` 本就注释未启用 ⇒ 无影响。

## 4. 两个例外 Dockerfile 的必要性判断（合并后重判）

| 文件 | 官方本轮动作 | 我方剩余领先改动 | 结论 |
|---|---|---|---|
| `Dockerfile.app` | builder 加 Go build/module cache 挂载、运行时探测 Go 版本；无换源类新增 ARG | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`（browserskill + builder 两阶段） | **仍必要**（官方未覆盖 rustup/gh/npm/cargo） |
| `Dockerfile.docreader` | 新增 `VERSION_ARG/COMMIT_ID_ARG` 构建元数据；apt 加 `qpdf` | `GH_PROXY`（protoc :65、grpc_health_probe :141）、`PLAYWRIGHT_*` 为官方原生 ARG（非我方） | **仍必要**（GH_PROXY 段官方未覆盖） |

## 5. 部署注意事项（下次重建 111 app 前）

1. **备份正式数据**：`postgres-data` + `data-files` + `.env`（含 `SYSTEM_AES_KEY`）。
2. 迁移 000121–000135 将随 app 启动自动执行；000125 会软删少量脏块，属预期清理。
3. 前端镜像需重新构建（官方前端 427 文件变化，assistant/automation/sandbox 新功能全在前端）。
4. 新能力多为**门控默认关**（沙箱双模式、钉钉目录结构、HTML 正文索引等），上线后按需开启。

## 6. 复核命令

```bash
git log --oneline 450b6ed1..upstream/main | wc -l          # 428
git diff --name-status upstream/main..wkj-dev | wc -l      # 974（我方差异面）
diff -rq frontend my-frontend --exclude=node_modules       # 应仅剩 dist/node_modules 级产物
```

## 7. 部署记录（111，2026-11-03）

- [x] **备份**：用当日 cron 快照 `/mnt/data/backups/weknora/20261103-060001`（06:00 完成，早于本次变更）。
- [x] **已部署**（11:10–11:55，`deploy-wkj-dev.sh`）：
  1. `push-app` —— 111 编译镜像重编 app 二进制（anydoc 增量 21s + Go 全量），投递 `.build/WeKnora`（commit `5641eae7` 命中 7 处）；重启 app ⇒ **迁移 120→135 一次通过**，无 dirty。
  2. `push-ui` —— 本地构建 my-frontend v0.9.0（23M），rsync 到 `/mnt/data/weknora/my-frontend/dist`，容器内标记 `w="5641eae"` 命中。
  3. `push-reader` —— docreader 源码同步 + 重启。
  4. `update` —— **pull 官方 v0.9.0 新基镜像**（app 新增 `qpdf`、docreader 新增 `rapidocr/onnxruntime/opencv`，旧镜像均缺 ⇒ 必须换新基）并重建 app/docreader/frontend；searxng-init 顺带重跑。
- **验收**：41200（官方前端）/ 41280（定制前端）均 **200**；app / docreader / frontend-wkj healthy；`schema_migrations` max=**135**、dirty=f；`qpdf` 在位、`import rapidocr/onnxruntime/cv2` OK。
- ⚠️ **踩坑（复发）**：前端容器重建后换了 IP，`weknora-nginx`（2 周未重建）DNS 缓存旧 IP ⇒ 41280 全 502；`docker restart weknora-nginx` 刷新解析即愈。与第 12 轮「app 重建致前端内嵌 nginx DNS 过期」同族 —— **容器组里任何成员重建后，未重建的 nginx/代理都要重启一遍**。
- [x] gitea / gitea111 已推（`5641eae7c`）；未推 origin（GitHub fork）。
