# README-WAKE — WeKnora

> V1-20260920

## 定位

`projects/rag-tools/` 是 RAG 工具类项目（向量索引 / 检索 / 文档处理）的分类目录（管理根目录），本仓库为其下的 **WeKnora** fork。

- **WeKnora**：腾讯开源的 LLM 知识框架，面向企业级文档理解、语义检索与自主推理。三大核心能力：**RAG 快速问答**、**ReAct Agent**（自主编排检索 / MCP 工具 / 租户技能目录 / Docker·E2B·Cube 沙箱 / 联网搜索）、**Wiki Mode**（Agent 将原始文档蒸馏为自维护、互链的 Markdown 知识库，含交互式知识图谱、人工编辑、版本历史与一键回滚）。另有跨会话长期记忆、树状目录视图、分块编辑与版本历史、多源同步（飞书 / GitLab / Notion / 语雀 / 钉钉 / RSS 等）、网站嵌入挂件、作用域 API Key、20+ LLM 供应商接入（含 LiteLLM）、Langfuse 可观测、多工作区 RBAC、完全自托管。后端 Go + 前端 TypeScript + Python 解析服务（docreader）的多语言单体仓库。详见上游 `README.md` / `README_CN.md`（本文件不重复叙述实现）。

## Fork 信息

| 项 | 值 |
|----|----|
| 上游 upstream | https://github.com/Tencent/WeKnora |
| 本地 fork origin | https://github.com/weikejia123/WeKnora |
| 本地 Gitea | `http://localhost:3000/dzsoft/WeKnora`（例行推送目标） |
| 本地路径 | `projects/rag-tools/WeKnora/`（**独立 git**，不属于上级目录 repo） |
| 默认分支 | `main`（维持纯净，跟随上游） |
| 开发分支 | `wkj-dev`（所有本地修改 / 文档提交于此） |
| 上游版本 | `0.8.0`（`VERSION`） |
| 接手时 HEAD | `5c5d46d9fb556a7efa19d1a23331f4ce83ac2031 fix(ui): add resource list title icons and highlight shared filter` |
| 上游许可证 | **MIT**（Tencent，2025）；第三方组件另有许可，见 `LICENSE` / `THIRD_PARTY_NOTICES.md` / `licenses/` |
| 上游热度 | ★27391 / forks 3689（2026-09-20 记录） |
| 仓库体积 | 266 MB（克隆后） |
| 主语言 | Go 1.26（`go.mod`） |

## 许可证

上游主仓为 **MIT**（`LICENSE` 首段：Tencent 2025，除列明第三方组件外均为 MIT）。GitHub 侧 license 字段显示 `NOASSERTION`，原因是 `LICENSE` 文件在 MIT 正文之外还附带了第三方组件清单（Apache-2.0 等）与补充声明，并非限制性变更。

- ✅ 自用 / 内部部署 / 修改 / 分发：允许（保留版权与许可声明）
- ⚠️ 第三方组件（`THIRD_PARTY_NOTICES.md`、`licenses/` 目录）须各自遵守其原始许可
- 对外产品化前建议复核 `licenses/` 下逐项声明

## 分支与同步

- 本地修改一律在 `wkj-dev` 上提交；`main` 保持与上游一致。
- 例行推送只推 `gitea`（本地 Gitea），**不推 GitHub**；仅提交 PR 时才推 GitHub fork。
- 同步上游：`git fetch upstream && git merge upstream/main`（在 `wkj-dev` 上合并）。
- 上游贡献政策见 `README.md` §Contributing；本项目 fork 定位自用，暂无提 PR 计划。

## 标签

知识库|RAG|Agent|Wiki|文档理解|语义检索|多源同步|MCP|沙箱|LLM|Go|TypeScript|Python|PostgreSQL|Redis|Docker|自托管

## 技术栈

Go 1.26（主服务 + CLI）|TypeScript / React（`frontend/`）|Python（`docreader/` 文档解析服务）|gRPC（app ↔ docreader）|PostgreSQL + pgvector|Redis|Elasticsearch / OpenSearch|Qdrant / Milvus / Weaviate / Doris / Tencent VectorDB（多向量库后端）|MinIO / S3 / OSS / COS（对象存储）|Docker Compose / Helm|Langfuse（可观测）|MCP（双向：内置 MCP 服务 + 外部 MCP 工具）

## 依赖与运行

- Go **1.26.0**（`go.mod`）、Node.js（`frontend/`）、Python（`docreader/`）
- 依赖服务：PostgreSQL（默认带 pgvector）、Redis；向量库 / 对象存储按需选装
- 常用入口（`Makefile` / `docker-compose.yml`）：
  - `make help` — 查看全部目标
  - `make build` — 构建（含 `build-anydoc` 等解析依赖）
  - `make run` — 构建并启动
  - `make start-all` / `make start-docker` / `make stop-all` — 容器化一键起停
  - `make docker-build-all` — 构建 app / docreader / frontend 三个镜像
  - `make migrate-up` / `make migrate-down` — 数据库迁移
- 配置：`config/` 与 `.env`（约 150 个环境变量，官方文档站 `website-docs/` 有清单）

## 关联

- 官方仓库：`https://github.com/Tencent/WeKnora`
- GitHub fork：`https://github.com/weikejia123/WeKnora`
- 本地路径：`projects/rag-tools/WeKnora/`
- 本地 Gitea：`http://localhost:3000/dzsoft/WeKnora`
- 官方站点：`https://weknora.weixin.qq.com`
- 官方文档站：`website-docs/`（VitePress，六大部分约 50 页，含约 360 个 API 与约 150 个环境变量）
- 发布记录：`CHANGELOG.md`
- 本地管理目录：`projects/rag-tools/`（同胞项目：`Recuris/`、`semantica/`、`turbovec/`、`wake-md-rag/`、`outline/`）

## 项目自身结构

| 路径 | 说明 |
|------|------|
| `cmd/` | 入口：`server/`（主服务）、`desktop/`、`download/`、`milvus-migrate/` |
| `internal/` | 核心业务：`agent/` `application/` `handler/` `router/` `middleware/` `models/` `database/` `datasource/` `im/` `mcp/` `mcpserver/` `sandbox/` `container/` `modelcontext/` `tracing/` `storageurl/` `ratelimit/` `event/` `stream/` 等 |
| `frontend/` | TypeScript 前端（Web 控制台 / 聊天 / 知识库管理 / 图谱） |
| `docreader/` | Python 文档解析服务（PDF/Word/图片/Excel/XMind 等，gRPC 对外） |
| `cli/` | `weknora` 命令行工具（agent-first wire contract、NDJSON、`mcp serve`） |
| `mcp-server/` | 官方 MCP Server（PyPI `tencent-weknora-mcp`） |
| `miniprogram/` | 微信小程序端 |
| `client/` `packages/` | 客户端 SDK 与共享包 |
| `migrations/` | 数据库迁移脚本 |
| `config/` | 配置与内置模型声明（YAML） |
| `deploy/` `helm/` `docker/` | 部署编排（Docker Compose / Helm / 镜像构建） |
| `docs/` | 上游设计文档（agent、skills、chunking、IM 集成、RBAC 等，含中文文档） |
| `website-docs/` | 官方产品文档站（VitePress 源） |
| `dataset/` `testdata/` `tests/` `examples/` | 测试数据、样例与脚本 |
| `LICENSE` `THIRD_PARTY_NOTICES.md` `licenses/` | 许可与第三方组件声明 |
| `my-docs/` | **本项目内我方新增文档（上游目录不动）** |

## 深度分析 / Fork 策略

**参考 + 二开（内部自用）** — 定位为「企业级 RAG 知识库平台」的参考实现与潜在内部部署基座，与本目录其他项目互补：`outline/` 负责结构化语料的**生产与组织**，WeKnora 覆盖**入库 → 检索 → 推理 → 问答**全链路，`Recuris/` `semantica/` `turbovec/` 则是其中检索/语义环节的轻量组件。

几点值得关注的设计：

1. **多语言分层** — Go 主服务承载并发与编排，Python `docreader` 专司重型文档解析并通过 gRPC 隔离，前端独立构建；解析器崩溃/资源占用不会拖垮主服务。
2. **可插拔后端** — 向量库（pgvector / Qdrant / Milvus / Weaviate / Doris / Tencent VectorDB）、对象存储（本地 / MinIO / S3 / OSS / COS）、LLM 供应商均以驱动形式接入，`config/` 内有声明式内置模型 YAML，便于私有化替换。
3. **Agent + 沙箱** — ReAct Agent 可编排检索、MCP 工具与租户技能目录；v0.8.0 起技能执行走 Docker / E2B / Cube 沙箱（已移除本地宿主进程后端），是「Agent 能力边界」的工程化样本。
4. **Wiki Mode** — 由 Agent 从原始文档蒸馏出互链 Markdown 知识库并维护知识图谱，与本目录 `wake-md-rag/`（自研 Markdown RAG）在思路上可互为参照。
5. **多源同步与 IM 出口** — 飞书 / GitLab / Notion / 语雀 / 钉钉 / RSS 入，企业微信 / 飞书 / Slack / Telegram / QQ 出，构成完整的企业落地闭环。

默认维持上游纯净，所有改动脉冲落在 `wkj-dev`。

## 备注

- 仓库体积较大（266 MB，含 `dataset/` 与前端资源），克隆/构建耗时长。
- 构建依赖较重：Go 1.26 + Node + Python 三套工具链；`make build` 含 `build-anydoc`（Office 解析库）等步骤。
- 首次运行建议直接走 `docker-compose.yml`（含 postgres / redis / minio 等依赖服务），避免手工拼装环境。
- 上游客群覆盖 SaaS（WeKnora Cloud）与自托管双形态；自托管时注意 `RESOURCE_URL_MODE`、凭证加密（AES-256-GCM）与 SSRF/IDOR 相关安全配置。
- 经验沉淀与二次开发文档放 `my-docs/`，不污染上游目录。
