# WeKnora 项目分析报告

> 分析对象：`/Users/weikejia/CODE/my-agent-group/projects/rag-tools/WeKnora`
> 版本：**v0.8.0**（`VERSION`）｜协议：MIT｜上游：`github.com/Tencent/WeKnora`
> 分析方式：源码通读 + 官方文档站（`website-docs/` 六大板块）交叉核对，结论均附 `文件:行号`
> 报告日期：2026-09-20

---

## 0. 先建立认知：这个项目是什么

一句话：**WeKnora（维娜拉）是腾讯开源的企业级知识管理框架**，把"文档"变成"可问答、可推理、可沉淀"的知识资产。

它由三个子系统拼成，理解这三个子系统是理解后面所有内容的前提：

| 子系统 | 语言 | 职责 | 关键事实 |
|---|---|---|---|
| **app**（后端主体） | Go 1.26（`go.mod:3`） | HTTP API、业务逻辑、分块、向量化、检索、Agent 编排、权限 | 单二进制，`internal/` 下约 2000 个 Go 文件 |
| **docreader**（解析服务） | Python 3.10 | 只干一件事：**把文件/URL 转成 Markdown + 图片** | 独立 gRPC 服务（`:50051`），**无 HTTP 接口** |
| **frontend** | Vue 3 + TS | Web UI | Nginx 托管，反代 `/api/` 到 app |

它宣称的三大能力模式：
- **RAG 快速问答**——传统检索增强问答
- **ReAct Agent 智能推理**——多步自主编排（检索引擎、MCP 工具、沙箱、网络搜索）
- **Wiki 模式**——Agent 从原始文档**自治生成**互相链接的 Markdown 知识库 + 可视化知识图谱

> ⚠️ **先清一个坑**：网上一篇流传较广的评测（对比 RAGFlow/Dify/FastGPT/WeKnora）结论说"WeKnora **不支持 Excel/PPT**，复杂表格解析有缺陷"。那是针对 **v0.6.2** 的评测，**已经过期**。当前 v0.8.0 明确支持 Excel（`docreader/parser/excel_parser.py`）、PPT（走 MarkItDown 引擎）、XMind、EPUB、MHTML（见 `docreader/parser/registry.py` 与 `website-docs/03-features/03-document-parsing.md`）。引用任何评测前先看它的版本号。

---

## 1. 与其他市面项目的优势

### 1.1 对比对象说明

市面上同类项目分三类，选型时容易混：

| 类型 | 代表 | 本质 |
|---|---|---|
| RAG 专用引擎 | RAGFlow、LightRAG、QAnything | 专注"文档→检索"，深度解析强 |
| 全栈 AI 平台 | Dify、FastGPT、MaxKB | 工作流/Agent 编排为主，知识库是功能之一 |
| 个人/小团队工具 | AnythingLLM、Open WebUI | 轻量、本地优先 |

**WeKnora 的定位是"全栈 AI 平台里偏知识资产化的那一路"**，直接竞品是 Dify / FastGPT / MaxKB / RAGFlow。

### 1.2 它的真实优势（4 条，按含金量排序）

**① 三模式合一，且"自动 Wiki"是独有能力**

| 能力 | WeKnora | RAGFlow | Dify | FastGPT | MaxKB |
|---|---|---|---|---|---|
| RAG 问答 | ✅ | ✅ | ✅ | ✅ | ✅ |
| ReAct Agent | ✅ | 弱 | ✅（强） | 工作流式 | ❌ |
| **自动 Wiki + 知识图谱** | ✅ | ❌ | ❌ | ❌ | ❌ |

Wiki 模式不是"文档摘要"，而是 Agent 把散落文档**重组为互链的页面体系**，带页面版本历史、行级 diff、一键回滚（v0.7.2 起）。这个能力我在这几个竞品里没找到对等实现——这是它最锋利的地方。

**② Go 后端的工程底座（竞品多为 Python）**

Dify / FastGPT / MaxKB / RAGFlow 主体都是 Python。WeKnora 是 Go。实际影响：
- 并发与内存表现更好，单机吞吐高
- 核心服务只需 **4 个容器**（app / docreader / postgres / redis），`docker-compose.yml` 里其余全部是 opt-in profile
- 可编译为单二进制（Lite 形态，见 `docs/LITE.md`）

**③ 企业级治理能力是"白送"的，不在商业版里**

这是我认为对**私有化内网**场景最有价值的一条。Dify / MaxKB 的多租户与细粒度权限在商业版，WeKnora 在 MIT 协议下直接给：

| 能力 | 落点 |
|---|---|
| 多空间 RBAC 四级角色 | `internal/types/tenant_member.go:21-32` |
| 每空间审计日志 | `internal/types/audit_log.go` |
| 作用域 API Key（能力级 + 按 KB 限定） | `internal/types/tenant_api_key.go:18-38` |
| 凭据 AES-256-GCM 静态加密 + 平滑轮换 | `SYSTEM_AES_KEY` 机制 |
| 运行时任务队列面板 + Worker 池治理 | 分阶段独立池（core/后处理/enrichment/maintenance） |
| Langfuse 全链路可观测 | 唯一追踪后端 |

**④ 国内生态与 IM 接入成本最低**

企业微信 / 飞书 / Lark / 钉钉 / QQBot / Slack / Telegram / Mattermost / 微信 / 云之家，外加微信小程序、Chrome 插件、网站嵌入 Widget、以及微信对话开放平台（`chatbot.weixin.qq.com` 的技术底座就是它）。做国内 IM 场景，这是最省事的选择。

模型侧也优先接了腾讯系：混元、LKEAP 重排、腾讯云 VectorDB、腾讯云 COS。

### 1.3 它在哪些方面不如别人（必须说清）

| 短板 | 谁更强 | 说明 |
|---|---|---|
| **深度文档版面解析** | RAGFlow（DeepDoc） | 复杂跨页表格、多栏版面、扫描件的行列语义保留度，RAGFlow 仍是第一梯队 |
| 可视化工作流编排 | Dify（最成熟） | WeKnora 无拖拽式 workflow，Agent 靠 ReAct + Prompt 编排 |
| 社区规模 / 生态插件 | Dify（~141k stars） | WeKnora 约 15k 量级，第三方教程与插件少 |
| 多模态视频处理 | RAGFlow | 无视频关键帧/字幕索引能力 |
| 动态插件加载 | — | **全系统无 Go plugin / dlopen 机制**，所有扩展点是编译期注册（详见第 3 节） |

**一句话选型判据**：要"文档精准解析"选 RAGFlow；要"可视化编排工作流"选 Dify；要"文档既问答、又 Agent、还能自动沉淀成 Wiki + 接国内 IM + 私有化合规"——WeKnora 是最贴合的一体化选择。

---

## 2. PDF / DOCX / XLSX 入库：步骤 & 是否需要外部转换

### 2.1 直接回答：**不需要任何外部文件转换功能**

这是最省心的一点。转换能力**全部内置在 docreader 镜像里**，你不需要自己搭 LibreOffice、Tika、Unstructured 或写预处理脚本。

各格式的解析归属（证据见 `docreader/parser/registry.py` 的 `_build_default_registry()`）：

| 格式 | 由谁处理 | 底层依赖 |
|---|---|---|
| **xlsx / xls** | docreader `builtin` → `ExcelParser` | `openpyxl` / `xlrd` / `pandas` |
| **docx** | docreader `builtin` → `Docx2Parser` | `python-docx`；失败自动回落 MarkItDown |
| **doc**（老 Word） | docreader `builtin` → `DocParser` | `antiword` |
| **pdf** | docreader `builtin` → `PDFParser` | `pypdfium2` + `pypdf` |
| **ppt / pptx** | `markitdown` 引擎 | 微软 MarkItDown |
| **csv** | `markitdown` 引擎 | 内置 |
| epub / xmind / html / mhtml | docreader `builtin` 各自 Parser | `ebooklib` 等 |
| **md / txt / csv / json / 图片 / 音频** | **Go 侧 `SimpleFormatReader`，根本不过 docreader** | — |

最后一行很关键：`internal/infrastructure/docparser/builtin_converter.go:15-20` 定义了 `simpleFormats = {md, markdown, txt, text, csv, json}`，图片与音频格式在 `init()` 里并进同一集合（`:31-38`）——这些**轻格式在 Go 进程内直接处理**，只有 PDF/DOCX/XLSX/PPT 这类"重格式"才走 gRPC 到 Python 服务。

> 补充：`docreader` 镜像里装了 **LibreOffice**（用于 doc→docx、ppt→pptx、xls→xlsx 的格式转换）、**Playwright webkit**（网页抓取）、**OpenJDK 17**（OpenDataLoader 版面分析需要 Java）。代价是**这个镜像体积很大**，内网搬运时要留意。

### 2.2 完整入库链路（7 步）

```
① 建知识库 → ② 上传 → ③ Go 侧按格式分流 → ④ docreader 解析
   → ⑤ Go 侧图片落盘 + OCR + caption → ⑥ 分块 → ⑦ 向量化 + 建索引
```

**① 创建知识库**——必须同时确定三件东西，且**前两件后期基本不可逆**：
- **Embedding 模型**（决定向量维度，换模型 = 全量重算）
- **向量库**（Postgres/ES/Qdrant/Milvus/Weaviate/Doris/OpenSearch/腾讯云 VectorDB）
- 存储后端（local / MinIO / COS / TOS / S3 / OSS / KS3 / OBS）

**② 上传**——三种途径：
- UI：文件上传、**文件夹树上传**（保留目录结构，v0.7.2 起）、URL 导入、在线录入
- API：`POST /api/v1/knowledge-bases/:id/knowledge/file`（multipart）
- 外部同步：飞书 / Notion / 语雀 / GitLab / 腾讯 IMA / RSS 增量同步

**③ 分流**——Go 侧判断 `IsSimpleFormat()`：简单格式自己处理，复杂格式转 docreader。

**④ docreader 解析**——`ReadStream` 流式 RPC：先回 1 帧 Markdown 正文，之后每帧回 1 张图片（**inline bytes**）。流式设计的目的是避免数百页扫描件 PDF 撞上 gRPC 消息大小上限。

**⑤ Go 侧后处理**——图片持久化到存储后端、把 Markdown 里的图片引用重写为存储 URL；对扫描页调 **VLM** 做 OCR、对插图生成 caption。

**⑥ 分块**——`internal/infrastructure/chunker/`，支持 5 种策略：`auto` / `heading`（标题层级）/ `heuristic` / `recursive` / `legacy`，可配父子分块。**分块结果可在 UI 里人工编辑**，带版本历史与回滚，编辑后自动重建索引。

**⑦ 向量化 + 索引**——批量 embedding（`BATCH_EMBED_SIZE`）、建索引、可检索。

### 2.3 实操建议（避坑）

| 现象 | 处置 |
|---|---|
| Excel 首行是列名却被当数据 | 解析设置里对 `xlsx`/`xls` 开"首行作为表头" |
| PDF 版面还原差、表格错位 | 给 `pdf` 换引擎：MarkItDown / OpenDataLoader / MinerU |
| 扫描件没出文字 | 确认已配 **VLM 模型**，必要时开 `DOCREADER_PDF_FORCE_SCANNED` |
| 分块内容要修正 | 分块列表直接编辑，改完自动重建索引 |
| 想换解析配置重来 | `POST /knowledge/:id/reparse` 或批量 `batch-reparse`（可带批次级 `process_config`） |

默认单文件上限 **50MB**（`MAX_FILE_SIZE_MB`）。

---

## 3. 架构开放性 & 多领域隔离/共享

### 3.1 开放性：9 类扩展点，注册制但**编译期**

系统把可变部分全部抽象成接口，官方文档 `website-docs/06-development/03-extension-points.md` 有完整清单：

| # | 扩展点 | 接口位置 | 注册中枢 |
|---|---|---|---|
| 1 | 文档解析器 | `docreader/parser/base_parser.py` | `docreader/parser/registry.py` |
| 2 | 分块策略 | `internal/infrastructure/chunker/strategy.go` | 包级函数变量覆盖（`init()`） |
| 3 | 检索引擎（向量库） | `internal/types/interfaces/retriever.go:11/68/102` | `internal/container/engine_factory.go:66-88` |
| 4 | 模型 Provider | `internal/models/provider/provider.go:165`（`Register`） | 各实现文件 `init()` |
| 5 | 联网搜索引擎 | `internal/types/interfaces/web_search.go` | `container.go` 的 `registerWebSearchProviders` |
| 6 | 数据源连接器 | `internal/datasource/connector.go:11/122/134` | `container.go` 的 `initConnectorRegistry` |
| 7 | IM 平台适配器 | `internal/im/adapter.go:126` | `container.go` 的 `registerIMAdapterFactories` |
| 8 | Agent 工具 | `internal/agent/tools/` | 同上 |
| 9 | 存储后端 | `internal/types/storagebackend.go` | `internal/application/service/file/factory.go` |

**分两类看待——这是评估"开放性"的关键：**

**✅ 改配置即可（真正的开放）**

| 场景 | 怎么做 |
|---|---|
| **接入任意 OpenAI 兼容的模型服务** | UI 选 provider = `generic`（`internal/models/provider/generic.go:20` 显示名"自定义 (OpenAI兼容接口)"），填 BaseURL + Key，**零代码**。这是内网部署的万能逃生舱。 |
| 接入外部高精度解析服务 | MinerU / MinerU Cloud / PaddleOCR-VL：填 endpoint + key（租户级 overrides） |
| 多向量库实例 | UI 里按空间加实例（受引擎类型白名单限制，见下） |
| 裁剪可用存储类型 | `STORAGE_ALLOW_LIST` |

**❌ 必须改 Go 代码重新编译**

新增**向量库驱动**、**非 OpenAI 协议的模型厂商**、**新存储 provider**、**新数据源连接器**、**新搜索引擎**、**新 IM 平台**、**新 Go 内解析引擎**——全都是"新建文件 + 手工加一行注册 + 加 switch 分支 + 加常量/元数据"。

> **结论**：它的开放性属于**"设计上留了接口，但扩展要改代码"**，不是 Dify 那种插件市场式的动态扩展。全系统**没有 Go plugin / dlopen 动态加载**。
>
> 对你而言的实际含义：**只要你的内网提供的是 OpenAI 兼容接口，你几乎不用改代码**。需要改代码的场景是"要塞一个私有的国产向量库/私有协议模型"，那时成本是"写一个 Go 文件 + 重新构建镜像"。

**官方扩展文档**（是真的有，不是摆设）：`website-docs/03-features/05-retrieval-engines.md`、`website-docs/03-features/11-web-search.md`、`website-docs/03-features/10-datasource.md`、`website-docs/03-features/12-im-integration.md`、`internal/datasource/CONNECTOR_IMPLEMENTATION_GUIDE.md`、`website-docs/03-features/06-models.md`。
**缺口**：解析引擎、存储后端、模型厂商这三类**没有**官方扩展文档。

### 3.2 多领域隔离：靠 Tenant（空间）

**模型层级**（三层，但**不支持嵌套**）：

```
User ──TenantMember──► Tenant（工作区/空间） ──OrganizationTenantMember──► Organization（组织）
```

- **一个领域 = 一个 Tenant**。Tenant 定义在 `internal/types/tenant.go:86-129`，含存储配额（默认 10GB）与大量租户级配置（检索配置、解析引擎配置、存储配置、沙箱配置…）
- ⚠️ **`Tenant` 没有 `parent_id` 字段，不支持子空间**。领域之下不能再分层。
- 一个用户可属于多个 Tenant，登录时返回 `Memberships` 列表，可切换。

**隔离的实际落地方式：共享表 + `tenant_id` 行级过滤**（不是物理隔离）

| 证据 | 内容 |
|---|---|
| `migrations/sqlite/000000_init.up.sql:53/77/98/131` | `knowledge_bases`、`knowledges`、`sessions`、`chunks` 均 `tenant_id NOT NULL` 且建索引 |
| 52 个迁移文件 | 含 `tenant_id` |
| `internal/application/repository/*.go` | `tenant_id` 出现约 314 处，仓储层**强制**带租户过滤 |

**领域内的二次细分**：四级角色 + 资源归属

| 能力 | Owner | Admin | Contributor | Viewer |
|---|---|---|---|---|
| 读空间内资源 | ✅ | ✅ | ✅ | ✅ |
| 建 KB / Agent | ✅ | ✅ | ✅ | ❌ |
| 改**自己建的** KB/Agent | ✅ | ✅ | ✅ | ❌ |
| 改**他人建的**资源 | ✅ | ✅ | ❌ | ❌ |
| 管成员/集成/模型/向量库 | ✅ | ✅ | ❌ | ❌ |
| 删空间、转移所有权、管 API Key | ✅ | ❌ | ❌ | ❌ |

角色数值：Owner=40 / Admin=30 / Contributor=20 / Viewer=10（`internal/types/tenant_member.go:21-41`），高角色继承低角色。
资源归属靠 `creator_id`（迁移 000043 加列），子资源沿 `chunk → knowledge → kb → creator_id` 回溯。

### 3.3 跨领域共享：粒度较粗

共享的唯一载体是 **Organization**，两张关系表：

| 表 | 位置 | 能共享什么 | 粒度 |
|---|---|---|---|
| `kb_shares` | `internal/types/organization.go:196-224` | **整个知识库** | `viewer` / `editor` |
| `agent_shares` | 同文件 `:238-255` | **Agent** | **仅只读** |

跨租户检索在类型层是支持的：`internal/types/search.go:31-33` 的 `SearchTarget.TenantID`，注释写明 *"Required for cross-tenant shared KB queries"*。

### 3.4 用现有机制裁"多领域隔离 + 跨领域共享"，可行吗？

**可行的部分**：每领域一个 Tenant，`tenant_id` 行级隔离贯穿 DB 与仓储层，日常互不干扰，这是开箱即用的。

**必须知道的 6 条限制**：

1. **无子空间**——领域之下不能再分层（比如"财务/2024/预算"只能靠 KB 命名或文件夹树模拟）
2. **不能共享单文档 / 单分块**——只能整库共享。想"只把 3 个文档给另一个领域看"，**不支持**
3. **Agent 共享只读**——不可写
4. **共享必须双方加入同一 Organization**——不能直接点对点授权给另一个 Tenant
5. **跨空间写有前置条件**——源库的 `creator_id` 若为空（"空间共有 KB"），外空间成员永远只能读
6. ⚠️ **最容易被忽略的一条：默认检索引擎的向量库无法做多实例物理隔离**

关于第 6 条，这是我在源码里挖到一个对"多领域"影响最大的细节：

`internal/types/vectorstore.go:87-95` 的 `validEngineTypes` 白名单**只包含**：

```
Elasticsearch / Qdrant / Milvus / Weaviate / Doris / TencentVectorDB / OpenSearch
```

**不含 Postgres、不含 SQLite**。同文件 `:76-86` 的注释解释了原因：`embeddings` 表是**硬编码的单一表名，无 per-store 分区**，所以同一个 Postgres 实例上注册第二个 store 没有任何隔离效果——所有共享该引擎的 KB 最终落在**同一张物理表**里。

**含义**：如果你用默认的 ParadeDB(Postgres) 做检索，**所有领域的数据共用同一张向量表，只能靠 `tenant_id` 做逻辑隔离**。想要"每个领域一个独立向量集合"的物理隔离，**必须换成 Qdrant / Milvus / ES / OpenSearch / Weaviate / Doris / 腾讯云 VectorDB 之一**。

### 3.5 三种落地方案建议

| 方案 | 做法 | 隔离强度 | 适用 |
|---|---|---|---|
| **A（推荐起步）** | 单部署，每领域一个 Tenant，共用 ParadeDB | 逻辑隔离（`tenant_id`） | 领域间无强合规要求 |
| **B（要物理隔离）** | 单部署 + 接入 **Qdrant**，每领域一个 store / collection，按 KB 绑定 | 向量层物理隔离 | 领域间要求数据不混表 |
| **C（强合规）** | 多套独立部署，各自 PG + 向量库 | 完全隔离 | 涉密 / 跨主体合规 |

方案 B 的依据：`internal/types/vectorstore.go:39` 的 `VectorStore` 支持**同 tenant 多条、同 engine 多条**，且 KB 可绑定指定 store（`storage_backend_id` / `vector_store_id` 字段见 `website-docs/06-development/02-database-schema.md:111`）。

---

## 4. 内网（无互联网）部署依赖清单

### 4.1 直接回答：除了内网 LLM API，你还需要 4 类东西

| # | 类别 | 是否必须 | 说明 |
|---|---|---|---|
| 1 | **离线镜像** | ✅ 必须 | 5 个核心镜像，需 `docker save/load` 或私有 registry 搬运 |
| 2 | **Embedding 模型 API** | ✅ **必须（最容易被漏掉）** | 没有它**完全无法入库和检索**，比 LLM 更底层 |
| 3 | **基础中间件** | ✅ 必须 | Postgres(ParadeDB) + Redis——**随镜像自带，不用额外准备** |
| 4 | Rerank / VLM / ASR API | ⭕ 可选 | 分别影响检索质量 / 扫描件识别 / 音频转写 |

**注意第 2 条**：仓库里**没有任何本地模型文件**（我全仓搜索 `*.onnx` / `*.gguf` / `*.pt` / `*.safetensors`，**0 命中**）。所有模型都是**远程 API 调用**。所以内网必须自备 Embedding 服务。

### 4.2 必备镜像清单

| 镜像 | 作用 | 备注 |
|---|---|---|
| `wechatopenai/weknora-app` | Go 后端 | 中等 |
| `wechatopenai/weknora-ui` | 前端 Nginx | 小 |
| `wechatopenai/weknora-docreader` | **文档解析** | ⚠️ **最大**：含 LibreOffice + Playwright webkit + OpenJDK17 + pdfium |
| `paradedb/paradedb:v0.22.6-pg17` | 数据库（PG17 + `pg_search` BM25 + pgvector） | 大 |
| `redis:7.0-alpine` | 队列 / 缓存 / 流 | 小 |

可选 profile 镜像（按需）：`minio`（对象存储）、`neo4j`（知识图谱）、`qdrant`/`milvus`/`weaviate`/`doris`（向量库）、`langfuse` 全套（可观测）、`searxng`（自建搜索）、`mcp`。

搬运方式（内网侧）：

```bash
# 外网机器
docker compose pull
docker save wechatopenai/weknora-app:0.8.0 ... | gzip > weknora-images.tar.gz
# 内网机器
gunzip -c weknora-images.tar.gz | docker load
```

也可以在内网搭一个私有 registry，改 `WEKNORA_VERSION` 指向它。

### 4.3 模型 API 需求矩阵（按优先级）

| 用途 | 必须性 | 影响的失败现象 | 接口形态 |
|---|---|---|---|
| **Embedding** | 🔴 **必须** | 上传成功但无法检索；入库卡在向量化阶段 | OpenAI 兼容 `/v1/embeddings` |
| **LLM (KnowledgeQA)** | 🔴 必须 | 问答 / 摘要 / Agent 全部不可用 | OpenAI 兼容 `/v1/chat/completions` |
| **Rerank** | 🟡 强烈建议 | 检索质量下降（可关闭，不用则不配） | `/v1/rerank` 类 |
| **VLM** | ⭕ 可选 | 扫描件 PDF / 图片无法出文字与描述 | OpenAI 兼容多模态 |
| **ASR** | ⭕ 可选 | 音频文件无法转写 | OpenAI `/v1/audio/transcriptions` |

配置方式二选一：
- **UI 配置**（推荐，存库，UI 可调）
- **声明式 YAML**：`config/builtin_models.yaml`（从 `.example` 复制），支持 `${ENV}` 引用环境变量，**每次启动重新应用**——适合内网做"配置即代码"

### 4.4 运行期会联网的点（逐条：关掉或内网替代）

这是内网部署最容易踩雷的部分——**默认配置里有若干会主动出网的行为**：

| 联网点 | 默认值 | 处置 |
|---|---|---|
| **Ollama** | `host.docker.internal:11434` | 内网替代，或 `OLLAMA_OPTIONAL=true`（不可用仅告警不阻断） |
| **网络搜索** | DuckDuckGo/Bing/Google/Tavily/Baidu/Exa/Metaso/SearXNG | **不配置即不启用** |
| **数据源同步** | 飞书 / Notion / 语雀 / GitLab / IMA / RSS | **不配置即不启用** |
| **Langfuse** | `https://cloud.langfuse.com` | 关闭，或内网自建（`--profile langfuse`） |
| **对象存储** | COS / TOS / S3 / OSS / OBS / KS3 | 用 `STORAGE_TYPE=local` 或内网 MinIO |
| **外部解析服务** | MinerU / PaddleOCR-VL | 不配置即不启用 |
| **沙箱** | Docker / E2B / Cube | **默认关闭**，不用管 |
| **WeKnora Cloud 托管模型/解析** | — | 不配置即不启用 |
| **前端图标 CDN** | `tdesign.gtimg.com` | ✅ **已内置离线保护**：`installTDesignIconOfflineGuard`，图标已本地化打包 |

> ✅ 前端这一点做得不错：`website-docs/05-clients/01-frontend.md:83` 明确说明注册了离线图标保护，避免运行时请求 CDN。

### 4.5 构建期联网点（**如果内网要源码编译**）

| 位置 | 行为 |
|---|---|
| `docker/Dockerfile.app:171` | `curl -LsSf https://astral.sh/uv/install.sh` |
| `docker/Dockerfile.docreader:65` | 下载 `protoc-3.19.4-linux-*.zip`（**有离线兜底**：若 `packages/` 下有本地包则跳过下载） |
| `docker/Dockerfile.docreader` | `python -m playwright install webkit`（需下载浏览器内核） |
| `scripts/build_browserskill.sh:35` | `git clone https://github.com/Tencent/BrowserSkill.git` |
| `frontend/` | npm 依赖（可用 `NPM_REGISTRY` 指向内网镜像；`xlsx` 需从 SheetJS 官方固定地址安装） |

**强烈建议**：内网**不要源码编译**，直接 `docker pull` 官方镜像后 `save/load` 搬进去。编译路径需要在有网环境预置 `packages/`、npm 缓存、Playwright 内核，成本远高于搬镜像。

（若必须编译，可用 `APK_MIRROR_ARG` / `APT_MIRROR` / `NPM_REGISTRY` 指向内网镜像源，这些开关在 compose 与 Dockerfile 里都留了。）

### 4.6 部署形态选择

| 形态 | 组件 | 文档解析能力 | 内网适配 |
|---|---|---|---|
| **标准版（Compose）** | app + frontend + docreader + ParadeDB + Redis | ✅ 全格式 | ✅ **推荐** |
| Lite 单二进制 | 单进程 + SQLite + 内存队列 | ⚠️ **仅 Simple 格式**（md/txt/csv/json/图片） | 个人/低资源 |
| Helm (K8s) | 同上，chart 内置 PG/Redis | ✅ | K8s ≥ 1.25 |
| 桌面应用 | Wails，SQLite | ⚠️ 同上 | **未正式发布** |

⚠️ **Lite 版的关键限制**（`docs/LITE.md`）：内置**只有 Simple 类型解析引擎**，PDF/DOCX/XLSX 这类复杂格式需要额外接入（`DOCREADER_ADDR` 指向独立 docreader 进程，见 `.env.lite.example`）。

**你的场景（内网 + 多领域管理）建议用标准版**——Lite 的解析能力和多空间协作都不满足。

### 4.7 硬件基线

官方建议 **4 核 / 8GB 起步**（docreader 含 LibreOffice + Playwright，较吃内存）；磁盘按知识库规模预留（Postgres 卷 + `/data/files` 文件卷）。若启用 Milvus / OpenSearch / Langfuse 需相应加内存。

CPU 注意：ParadeDB 默认镜像 x86 基线为 `x86-64-v2`（SSE4.2 + POPCNT），**不强制 AVX2**；ARM 支持不保证全组件可用。

---

## 5. 四问速答（结论汇总）

| 你的问题 | 结论 |
|---|---|
| **1. 优势** | 三模式合一（尤其独有自动 Wiki）+ Go 工程底座 + MIT 下白送的企业级治理（RBAC/审计/加密）+ 国内 IM 生态。**短板**：深度版面解析不及 RAGFlow，无可视化工作流，生态规模小于 Dify |
| **2. PDF/DOCX/XLSX 入库** | **不需要外部转换**。7 步：建库（定 embedding+向量库，不可逆）→ 上传 → 分流 → docreader 解析 → 图片落盘/OCR → 分块 → 向量化。docreader 内置 LibreOffice/openpyxl/python-docx/pdfium |
| **3. 开放性 & 隔离共享** | 9 类扩展点，**有接口但扩展需改代码**（无动态插件）；OpenAI 兼容协议是零代码逃生舱。隔离 = 每领域一个 Tenant + `tenant_id` 行级过滤（**逻辑隔离，非物理**）；共享只能"整库共享到 Organization"或"Agent 只读共享"，**不能共享单文档**。想要向量层物理隔离**必须弃用默认 Postgres 引擎改 Qdrant/Milvus 等** |
| **4. 内网依赖** | ① 5 个离线镜像（docreader 最大）② **Embedding API（必须，最易漏）** ③ LLM API ④ 可选 Rerank/VLM/ASR。中间件随镜像自带。**建议搬镜像而非源码编译**。默认有 8 处会出网的配置需逐个处理 |

---

## 附录 A：证据索引（可核对）

| 结论 | 证据位置 |
|---|---|
| Go 1.26 | `go.mod:3` |
| 版本 v0.8.0 | `VERSION` |
| 简单格式 Go 内处理 | `internal/infrastructure/docparser/builtin_converter.go:15-20`、`:31-38`、`:47` |
| 解析引擎注册表 | `docreader/parser/registry.py`（`_build_default_registry()`） |
| docreader 依赖（LibreOffice 等） | `docker/Dockerfile.docreader` |
| 解析器基类职责 | `docreader/parser/base_parser.py` |
| 检索引擎接口 | `internal/types/interfaces/retriever.go:11`、`:68`、`:102` |
| 检索引擎工厂 switch | `internal/container/engine_factory.go:66-88` |
| **向量库白名单（不含 PG/SQLite）** | `internal/types/vectorstore.go:87-95`（原因注释 `:76-86`） |
| 模型 Provider 注册 | `internal/models/provider/provider.go:165`；OpenAI 兼容逃生舱 `internal/models/provider/generic.go:20` |
| Chat 工厂 | `internal/models/chat/chat.go:119`、`:174`、`:195` |
| 存储后端白名单 | `internal/storageallowlist/allowlist.go:10` |
| 数据源连接器接口 | `internal/datasource/connector.go:11`、`:122`、`:134` |
| IM 适配器接口 | `internal/im/adapter.go:126` |
| 解析引擎扩展接口 | `internal/infrastructure/docparser/engine_registry.go:16-26` |
| Tenant 模型 | `internal/types/tenant.go:86-129` |
| 四级角色与数值 | `internal/types/tenant_member.go:21-32`、`:39-42` |
| 跨租户开关（双条件） | `internal/config/config.go:209-210`；`internal/middleware/access.go:63`、`:77`、`:90` |
| KB 共享表 | `internal/types/organization.go:196-224`；`migrations/sqlite/000000_init.up.sql:617` |
| 跨租户检索字段 | `internal/types/search.go:31-33` |
| API Key 范围 | `internal/types/tenant_api_key.go:18-38` |
| 离线图标保护 | `website-docs/05-clients/01-frontend.md:83` |
| Lite 限制 | `docs/LITE.md` |
| 官方扩展点文档 | `website-docs/06-development/03-extension-points.md` |
| 文档解析机制 | `website-docs/03-features/03-document-parsing.md` |
| 部署与依赖 | `website-docs/01-getting-started/02-installation.md` |

## 附录 B：需人工复核的项

1. **社区数据**（stars、竞品版本）来自 2026-09 网络检索，会随时间变化，**引用前请复核**。
2. 结论 1.3 中"RAGFlow 深度解析更强"基于第三方评测汇总，**建议用你自己的真实样本做一次对照测试**再定论。
3. `docreader` 镜像的**具体体积**未实测（本报告只依据 Dockerfile 内容推断"较大"）。内网搬运前请实测 `docker images`。
4. 内网部署的**完整可用性**未实测——本报告只做静态依赖分析，未在无网环境真实拉起。建议正式部署前先在内网做一次冒烟。
