# WeKnora 官方 main 第 11 轮更新分析（2026-10-08）

## 1. 概览

| 项 | 值 |
|---|---|
| 同步区间 | `bccb4b15..e7aaf8ae`（上一轮复制点 → 本轮官方 main） |
| 版本 | `v0.8.2-158-ge7aaf8ae` —— **无新发版**（仍挂在 v0.8.2 之后） |
| 官方提交数 | **56**（54 fix + 1 feat + 1 chore） |
| 官方改动文件数 | 1084（三点比较口径：`git diff --name-only $MB..main`） |
| 依赖面 | 根 `go.mod` 仅 1 处：`milvus-io/milvus-proto/go-api/v2 v2.6.15` 由 indirect 转**直接依赖**（版本未动）；`/cli` 内 2 个依赖 bump（不影响主服务）；`frontend/package.json` **无变化** |
| 迁移面 | `migrations/` **零改动** ⇒ 111 部署不会触发新迁移 |
| 编译 | `go build ./...` exit=0（约 1–2 分钟，仅 cgo 常规告警） |
| 合并 | 零冲突（详见 §3），合并提交由 `git merge main` 生成 |

## 2. 更新内容（按用户可感知视角）

本轮几乎全是**可靠性与正确性修复**，无大的新功能（唯一 feat 是 UI 搜索）。

### feat（1 条）
- **UI**：Skills 与 MCP 工具箱列表增加**搜索框**（`SkillSettings.vue` / `McpSettings.vue`）。

### fix 按主题分组（54 条）

| 主题 | 条目要点 | 命中我方已知情况？ |
|---|---|---|
| **检索后端批量失败不再吞错** | sqlite（BatchSave 失败回滚、主行/索引行不再出现"半提交"）、ES `_bulk` per-item 失败上抛、Qdrant/Milvus 关键词检索整批失败返回 error 而非"无匹配"、Milvus CopyIndices 分块读源行消除静默漏向量的 offset 窗口 | ★ 我们的知识图谱走 **Neo4j**（不在本轮修复面），但若未来切 PG/Qdrant 检索后端，这批是行为性变更：**失败会显式报错** |
| **图谱截断可见性** | 图谱查询三处截断必须可见，模型不再把子图当全集（`internal/modelcontext/graph_truncation_test.go`） | ★ 与我们"Wiki 链接图 ≠ 知识图谱"的口径无冲突，属 agent 图谱工具行为 |
| **分页截断防护**（批量加固） | notion / ima / gitlab / feishu 多维表格 / yuque：重复游标防护、跳数上限、截断不再静默确认、截断轮次不下发删除 | 若后续启用 Notion/飞书/语雀接入，注意其游标行为更保守 |
| **MCP 稳定性** | 会话丢失后自动重连、动态注册 client secret 保留、嵌入资源传入工具结果、legacy chat 响应在 HTTP 错误时关闭、共享知识库纳入 endpoint scope | |
| **agent 稳定性** | 工具自起 goroutine 的 panic 兜底（MCP 预热不再带走进程）、断流摘要不再存为记忆检查点、数据分析 SQL 字符串字面量保留 | |
| **docreader / 解析** | EPUB 按 spine 顺序读章节；anydoc 内嵌 EMF/WMF 扩展名与 Rust 侧对齐；**空白内联元素保留空格** | docreader 是我们**多引擎容器**，本轮改动在 `builtin` 官方解析路径内 ⇒ 随代码挂载生效，无需额外动作 |
| **接入存储** | 腾讯 COS 经 S3 驱动改用 virtual-hosted 寻址；Milvus 连接校验与 gRPC resolver 默认值；Qdrant 环境变量口径统一 | 我们对象存储不走 COS ⇒ 无影响 |
| **其他** | access log 不再缓存整个请求体（内存友好）；SSE 事件字段容忍空格；cli/client 一批小修；FAQ 克隆保留正文与索引状态；wiki 重建逐页写失败不再静默回 200 | wiki 那条与我们已知的"Wiki 半成品"坑同源，是官方侧的修复 |

## 3. 二开影响评估

### 合并与冲突
- merge-base = `bccb4b15`（= 上一轮复制点，干净的单轮区间）。
- **三点比较交集为空**；`git merge-tree --write-tree` 预演仅输出 tree OID（`93bb635a`）⇒ 预判零冲突。
- 实际 `git merge main` **零冲突**，与预判一致。
- 二开完整性校验：`comm -23 /tmp/dev.txt /tmp/after.txt` 为空 ⇒ **零丢失**；`my-docker / my-frontend / my-docs / deploy / AGENTS.md` 全部在位。

### 官方是否动了我方依赖的文件
- 2 个例外 Dockerfile（`docker/Dockerfile.app` / `docker/Dockerfile.docreader`）：官方**未触碰**。
- `my-frontend/` 副本：官方本轮改 7 个前端文件，归因后**副本零刻意改动** ⇒ 整体 rsync 同步（见 §5）。

## 4. 2 个例外 Dockerfile 的必要性判断

`git diff -U2 main..HEAD -- docker/Dockerfile.app docker/Dockerfile.docreader` 复核：

- diff 的 `+` 块仍全部是我方**条件换源 ARG**（`APK_MIRROR_ARG` 两步装 CA 写法、`RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`），官方符号（`GOPROXY_ARG` 等）只出现在上下文行。
- **结论：仍然必要，不冗余** —— Docker 的 `--build-arg` 只对 Dockerfile 里声明过的 `ARG` 生效，留空即逐字回落官方行为，删掉就失去国内换源能力。

## 5. 连带处理

| 事项 | 结果 |
|---|---|
| 前端副本整体同步 | `rsync -a --exclude=/dist --exclude=/node_modules frontend/ my-frontend/`；同步后 `diff -rq` 仅剩 `dist` / `node_modules` 2 条产物（预期）；`dist/index.html` sha256 前后一致（`b7443ae9…`）⇒ 产物未被动 |
| 副本新增文件入暂存 | 官方新增 2 个测试文件 `sessionInputState.test.ts` / `SkillSettings.filters.test.ts`，rsync 后为 untracked，已显式 `git add`；跟踪文件数 868 = 868 |
| npm 依赖 | `frontend/package.json` 本轮未变 ⇒ 副本无需补装 |
| `my-docker/README.md` 副本复制点 | 已更新为 `e7aaf8ae`（第 11 轮，v0.8.2-158） |
| `docs/` 重构检查 | 本轮官方**未动** `docs/` ⇒ 无 MIGRATION 映射需求 |
| 行号引用漂移 | 官方在 `Makefile` 的 `docs:` 目标前插入 9 行注释（swag `--exclude ./internal/localsandbox`，修复 swagger 生成）⇒ 其后行号 **+9**。扫描确认"活引用"中无 Makefile 行号引用（08 目录内的行号表是历史登记，按 9.3 不改）⇒ 无需批量修订 |
| Milvus 直接依赖 | `go.mod` 中 milvus-proto 转直接依赖，仅声明面变化，go.sum 无新增 ⇒ `go mod download` 无额外拉取 |

## 6. 待办

- [ ] 部署到 111：本轮无新迁移，`deploy-wkj-dev.sh update` 即可（会重建 app 容器加载新后端）。
- [ ] 下轮若启用 Notion/飞书/语雀等接入源，注意分页防护加固后的游标行为。
- [ ] `my-docs/07-前端定制方案` 中 `frontend/Dockerfile:30-49` 为存量行号引用（本轮官方未动该文件，暂无漂移），下次顺手改符号引用。

## 7. 证据（可复核）

```sh
# 区间与规模
git rev-list --count wkj-dev..main        # 56
git describe --tags main                  # v0.8.2-158-ge7aaf8ae

# 冲突预判（merge-base = bccb4b151bae403508da77fbb174efc79dc47c1a）
git merge-tree --write-tree --name-only wkj-dev main
#   → 93bb635af06a8fb3eda3235d92e61ac8c1e5abed（单 tree = 零冲突）

# 完整性
comm -23 /tmp/dev.txt /tmp/after.txt      # 空 = 二开零丢失

# 编译
OUT=$(go build ./... 2>&1); RC=$?         # exit=0

# 前端副本
diff -rq frontend my-frontend             # 仅 dist / node_modules 2 条
git ls-files frontend | wc -l             # 868（= my-frontend）
sha256sum my-frontend/dist/index.html     # b7443ae93d86… 同步前后一致

# fetch 耗时
time git fetch upstream main:main         # 8.29s（本轮链路通畅）
```
