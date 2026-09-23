# 通过 API 添加知识库（不用页面操作）

> **结论：完全可以。** WeKnora 的全部知识库操作都有 REST API，页面只是它的一个客户端。
> 只要拿到一个带 `manage_kbs` + `ingest` 能力的 API Key，就能纯脚本化地把「建库 → 导入网页/文件」全部跑通。
> 文档日期：2026-09-20 ｜ 版本：v0.8.0 ｜ **本文档仅整理接口与用法，未实际发起任何写操作。**

---

## 〇、整体链路（4 步）

```
① 拿 API Key（一次性，需 Owner 权限）
        ↓
② POST /knowledge-bases                     创建知识库        ← 需 manage_kbs
        ↓
③ POST /knowledge-bases/{id}/knowledge/url  导入网页（或 /file 上传文件）  ← 需 ingest
        ↓
④ GET  /knowledge/:id/stages                查解析进度（可选）
```

认证方式二选一：

| 方式 | 请求头 | 适用 |
|---|---|---|
| **API Key（推荐给程序）** | `X-API-Key: sk-xxxxx` | 长期集成、脚本 |
| JWT Token（登录态） | `Authorization: Bearer eyJ...` | 临时调试 |

> 认证逻辑见 `internal/middleware/auth.go:119-161`——先试 JWT，失败再试 `X-API-Key`。

---

## 一、第 ① 步：获取 API Key

### 1.1 背景（一个容易踩的点）

**从 v0.6 起，创建空间不再自动发放 API Key。** 所以你不能指望"建个空间就有 key 用"，必须显式创建。
（`website-docs/04-api/02-api-tenant.md`）

### 1.2 方式 A：界面创建（最省事）

界面入口：**平台 → 集成**（API 集成设置），或 **平台 → 系统管理** 下的 API Key 管理。

对应代码：`frontend/src/views/integrations/ApiIntegrationSettings.vue`、`frontend/src/views/system/PlatformAPIKeys.vue`

### 1.3 方式 B：API 创建

需要用**登录后的 JWT**（且调用者是空间 Owner）调：

```
POST /api/v1/tenants/{tenant_id}/api-keys
Header: Authorization: Bearer <登录拿到的 token>
Body:
{
  "name": "自动化集成",
  "full_access": false,
  "knowledge_base_ids": [],
  "capabilities": ["manage_kbs", "ingest"],
  "expires_at_unix": null
}
```

**响应里会返回明文 token（形如 `sk-...`），且只返回这一次，务必立即保存。**

其他相关接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/tenants/{id}/api-keys` | 列出已有 Key |
| PUT | `/tenants/{id}/api-keys/{key_id}` | 修改配置 |
| DELETE | `/tenants/{id}/api-keys/{key_id}` | 吊销 |

（路由定义：`internal/router/routes_auth_tenant.go:97-100`）

### 1.4 能力（capabilities）怎么选

完整能力表见 `internal/types/tenant_api_key.go:71-125`。与你相关的：

| 能力 | 作用 | 本流程是否需要 |
|---|---|---|
| **`manage_kbs`** | 创建 / 更新 / 删除知识库 | ✅ 需要（第 ② 步） |
| **`ingest`** | 向知识库写入内容（上传文件 / 导入 URL） | ✅ 需要（第 ③ 步） |
| `retrieve` | 读取、检索 | 建议加（第 ④ 步查进度） |
| `chat` | 跑对话流程 | 不需要 |
| `manage_models` / `manage_agents` / `manage_channels` 等 | 其它域 | 不需要 |

> **想省事**：直接 `"full_access": true`，等价于全部能力。
> **想收紧**：给最小集 `["manage_kbs", "ingest", "retrieve"]`，并用 `knowledge_base_ids` 限定它能碰哪几个库
> （空数组 = 不限制）。

### 1.5 权限模型（谁有权创建 Key）

| 项 | 要求 |
|---|---|
| 调创建 Key 接口的人 | 必须是该空间的 **Owner**（`g.Owner()`，见 `routes_auth_tenant.go:98`） |
| 用 Key 调知识库接口 | Key 的能力 + KB 白名单双重校验 |

---

## 二、第 ② 步：创建知识库

```
POST /api/v1/knowledge-bases
Header: X-API-Key: sk-xxxxx
Header: Content-Type: application/json
Body:
{
  "name": "财政领域",
  "description": "政策文件知识库",
  "type": "document"
}
```

**字段说明**（完整表见 `website-docs/04-api/02-api-knowledge.md`，结构体在 `internal/types/knowledgebase.go:59`）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | **是** | 知识库名称 |
| `description` | 否 | 描述 |
| `type` | 否 | `document`（默认）/ `faq` |
| `embedding_model_id` | 否 | Embedding 模型 ID。**不传则用空间级配置**——但空间里必须先配好 embedding 模型，否则入库会失败 |
| `summary_model_id` | 否 | 摘要模型（Wiki/摘要用） |
| `chunking_config` | 否 | 分块配置 |
| `image_processing_config` | 否 | 图片处理（多模态开关） |
| `vlm_config` / `asr_config` | 否 | 多模态 / 语音模型 |
| `storage_provider_config` | 否 | 存储，如 `{"provider":"local"}` |
| `vector_store_id` | 否 | 绑定向量库实例。**创建后不可修改**；不传则用环境变量默认 |
| `extract_config` | 否 | 图谱抽取配置 |
| `auto_tag_config` | 否 | 自动打标签 |

> ⚠️ **`vector_store_id` 创建后不可改**（`<-:create` 标签，`internal/types/knowledgebase.go:100`）。
> 如果你以后想给不同领域分配不同向量库，**必须在这一步就指定**。

权限：API Key 需 `manage_kbs` 或 `full_access`（`internal/router/routes_knowledge.go:201-204`）。

**响应**里会返回新知识库的 `id`——第 ③ 步要用。

---

## 三、第 ③ 步：导入内容

### 3.1 导入网页（对应界面上的"导入网页"）

```
POST /api/v1/knowledge-bases/{kb_id}/knowledge/url
Header: X-API-Key: sk-xxxxx
Header: Content-Type: application/json
Body:
{
  "url": "https://www.example.com/policy.html"
}
```

**全部可用字段**（`internal/handler/knowledge.go:422-428`）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | **是** | 目标网址 |
| `file_name` / `file_type` | 否 | 覆盖自动识别的文件名 / 类型 |
| `title` | 否 | 自定义标题 |
| `enable_multimodel` | 否 | 是否启用多模态处理 |
| `tag_ids` | 否 | 打标签 |
| `process_config` | 否 | 覆盖解析/分块配置（见 `website-docs/04-api/02-api-knowledge.md`） |

> **这就是你在页面上点的那一步对应的接口**——同一个 handler。
> 注意行为与页面一致：**只抓这一个 URL，不跟随页面内的链接**（`docreader/parser/web_parser.py:193-236`）。

### 3.2 上传文件

```
POST /api/v1/knowledge-bases/{kb_id}/knowledge/file
Header: X-API-Key: sk-xxxxx
Content-Type: multipart/form-data
表单字段: file=<文件>
```

支持 PDF / Word / Excel / PPT / Markdown / 图片 等（详见 `my-docs/02-本地部署与配置/`）。

### 3.3 手工写入 Markdown 知识

```
POST /api/v1/knowledge-bases/{kb_id}/knowledge/manual
Body: { "title": "...", "content": "# Markdown 内容" }
```

> 💡 **对政策知识库的实用技巧**：如果你想把《预算法》《基本建设财务规则》等政策原文补进
> 已知识别的空壳页，用这个接口直接写入 Markdown 最省事——不依赖外部网页是否可达。

### 3.4 权限

以上三个接口都需 API Key 具备 **`ingest`** 或 `full_access`
（`internal/router/routes_knowledge.go:70-75`）。

---

## 四、第 ④ 步（可选）：查进度与状态

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/knowledge-bases/{kb_id}` | 知识库详情 |
| GET | `/knowledge-bases/{kb_id}/knowledge` | 列出该库下所有文档及状态 |
| GET | `/knowledge/{knowledge_id}/stages` | **单篇文档的解析阶段进度**（排查"卡在处理中"用） |
| POST | `/knowledge/{knowledge_id}/reparse` | 重新解析 |
| POST | `/knowledge/{knowledge_id}/cancel-parse` | 取消解析 |

> 文档处理的异步链路：入库入队 → 解析 → 分块 → 向量化 → 后处理（摘要/问题/图谱/Wiki）。
> 所以**上传接口会立刻返回，内容不会马上可检索**，需要轮询状态。

---

## 五、最小可用示例（把四步串起来）

> ⚠️ 以下为**示例写法，本文档未实际执行**。请替换 `<...>` 中的值为你自己的。

```bash
BASE=http://10.168.1.111:41201/api/v1
KEY=sk-你的APIKey

# ② 创建知识库
curl -s -X POST "$BASE/knowledge-bases" \
  -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"name":"财政领域-API测试","description":"由 API 创建","type":"document"}'
# → 从响应里取 data.id 作为 KB_ID

# ③ 导入网页
KB_ID=<上一步返回的 id>
curl -s -X POST "$BASE/knowledge-bases/$KB_ID/knowledge/url" \
  -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"url":"https://www.example.com/xxx.html"}'

# ③ 上传本地文件
curl -s -X POST "$BASE/knowledge-bases/$KB_ID/knowledge/file" \
  -H "X-API-Key: $KEY" \
  -F "file=@/path/to/预算法.pdf"

# ④ 查列表与状态
curl -s "$BASE/knowledge-bases/$KB_ID/knowledge" -H "X-API-Key: $KEY"
```

---

## 六、注意事项（按重要度）

1. **必须先配好 embedding 模型**。创建 KB 时 `embedding_model_id` 可以不传（走空间默认），
   但空间里若没有可用的 embedding 模型，文档能上传、**无法完成入库**。这与页面操作是同一个前提。
2. **API Key 明文只返回一次**。创建时立即保存；丢了只能吊销重建。
3. **`vector_store_id` 创建后不可修改**——多领域隔离场景要提前规划（见 `my-docs/03-生产部署/`）。
4. **`X-API-Key` 是自定义头**，不是标准 `Authorization`。两者都支持，但 API Key 走前者。
5. **SSRF 白名单同样约束 API 调用**：`url` 参数指向内网地址会被拦（`400`），
   与页面操作共用同一套校验。生产环境的白名单配置见 `my-docs/03-生产部署/`。
6. **能力给到最小集**：程序化集成建议 `["manage_kbs","ingest","retrieve"]` + `knowledge_base_ids` 限范围，
   不要图省事全给 `full_access`。

---

## 七、官方资料位置

| 内容 | 位置 |
|---|---|
| 知识库 API 文档 | `website-docs/04-api/02-api-knowledge.md` |
| 知识（文档）API 文档 | `website-docs/04-api/02-api-knowledge.md` |
| 空间与 API Key API | `website-docs/04-api/02-api-tenant.md` |
| Swagger 定义 | `docs/swagger.json`、`docs/swagger.yaml` |
| 路由源码 | `internal/router/routes_knowledge.go`、`routes_auth_tenant.go` |
| API Key 类型与能力 | `internal/types/tenant_api_key.go:18-125` |
| 在线 API 调试台 | 界面「平台 → 集成」内的 API 集成调试台（v0.7.0 起提供） |

---

## 八、可用于自动化的场景（供参考）

拿到 API Key 后，这一整套都可以脚本化，不必开浏览器：

- 批量建库（每领域一个 KB）
- 批量导入 URL 列表（配合循环）
- 批量上传本地政策文件（用 `/manual` 直写 Markdown 或 `/file` 传原件）
- 定时同步外部数据源（另有专门的数据源连接器 API）
- 轮询解析状态、失败自动重试
