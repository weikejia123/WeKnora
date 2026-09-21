# WeKnora 知识管理 API 深度使用手册

> **定位**：把 WeKnora 的**知识管理**能力完整地用 API 表达出来 —— 建库**之后**的日常操作：
> 添加知识、分目录、改归类、批量处理、查分块、验检索闭环。
>
> **姊妹篇**：`my-docs/05-API与集成/WeKnora-通过API添加知识库指南.md`（上手链路：拿 Key → 建库 → 首次导入）。
> 本文**不重复**那三步的基础写法，只在必要处给指针 —— 两篇合起来才是完整的 API 面。
>
> 基线：`wkj-dev` @ `cce33af5`（2026-09-22）｜ 版本 v0.8.0
> **本文档的源码结论均标注 `文件:行号` 可核对；标注「实测」的条目来自已沉淀的实测记录，本轮未新发起任何 API 调用。**

**短名对照**（正文为简洁用短名，全路径以此为准 —— 维护时按此表更新，避免"路径写法不全"导致引用失效）：

| 短名 | 全路径 |
|---|---|
| `knowledge.go` | `internal/handler/knowledge.go` |
| `tag.go` | `internal/handler/tag.go` |
| `auth.go` | `internal/middleware/auth.go` |
| `routes_knowledge.go` | `internal/router/routes_knowledge.go` |
| `routes_chat.go` | `internal/router/routes_chat.go` |
| `router.go` | `internal/router/router.go` |
| `types/knowledge_folder.go` | `internal/types/knowledge_folder.go` |
| `types/wiki_page.go` | `internal/types/wiki_page.go` |
| `session/qa.go` | `internal/handler/session/qa.go` |
| `session/types.go` | `internal/handler/session/types.go` |

---

## 〇、三条先记住的结论

这三条是通读源码后**最反直觉**的三点，先看它们能省掉大量试错：

| # | 结论 | 为什么会踩 |
|---|---|---|
| **1** | **"目录"有两套完全不同的模型** | 知识文档目录是**派生视图**（靠 `folder_path` 字段聚合），Wiki 页面目录是**实体表**。两套的 API 形状、语义、生命周期都不一样 |
| **2** | **知识文档目录没有"创建"接口** | 所以 `GET/PUT /knowledge-bases/:id/knowledge/folders` 只有两个方法——**没有 POST**。创建目录是"把文档移到该路径"的副作用 |
| **3** | **`PUT /knowledge/:id` 改不了目录** | 它只接受 `title` / `description` / `custom_metadata`（`internal/handler/knowledge.go:1723-1730`）。改归类只能走 `POST /knowledge/folder` |

---

## 一、环境与鉴权

### 1.1 地址

| 用途 | 地址 |
|---|---|
| 后端 API 直连（脚本首选） | `http://10.168.1.111:41201/api/v1` |
| 经 nginx（https） | `https://10.168.1.111:41200/api/v1` |
| 本地开发（本机 compose） | `http://127.0.0.1:<APP_PORT>/api/v1` |

> 前缀 `/api/v1` 在 `internal/router/router.go:227` 定义（`v1 := r.Group("/api/v1")`）。端口语义见 `my-docker/README.md:30-41`。

### 1.2 认证

```
X-API-Key: sk-xxxxxxxx
```

**不是** `Authorization: Bearer`。两者都支持，但走的是两条不同通路：
中间件先试 JWT，失败再回落 `X-API-Key`（`internal/middleware/auth.go:119-161`，取头在 `:161`）。

> **本机 curl 必须加 `--noproxy '*'`**（实测）—— 本机有透明代理，不加会失败或绕路。

### 1.3 能力（capabilities）与本文各接口的对应

| 能力 | 覆盖本文哪些操作 |
|---|---|
| `retrieve` | 所有 **GET**（列知识、查目录树、读分块、`POST /knowledge-search`） |
| `ingest` | 所有**内容写入**（上传/URL/manual、改知识、删知识、移动目录、批量、标签、分块编辑） |
| `manage_kbs` | **知识库**本身的建/改/删/拷贝 |
| `full_access` | 等价于全部；**清空知识库内容仅此能力可用** |

> 清空库是 `kb.With(apiKeyFullAccess())` 门控（`routes_knowledge.go:83`），比其它写操作更严。
> 能力清单与申请方式见姊妹篇 §1.3–1.4。

---

## 二、接口总表（按**任务**分组，不按 HTTP 方法平铺）

全部路径省略前缀 `/api/v1`。

### A. 知识库（KB）本体

| 方法 | 路径 | 能力 | 说明 |
|---|---|---|---|
| POST | `/knowledge-bases` | `manage_kbs` | 建库（详见姊妹篇 §二） |
| GET | `/knowledge-bases` | `retrieve` | 列库 |
| GET | `/knowledge-bases/:id` | `retrieve` | 库详情 |
| PUT | `/knowledge-bases/:id` | `manage_kbs` | 改库 |
| DELETE | `/knowledge-bases/:id` | `manage_kbs` | 删库 |
| POST | `/knowledge-bases/copy` | `manage_kbs` | 拷贝（连内容） |
| POST | `/knowledge-bases/:id/duplicate` | `manage_kbs` | 复制设置（不复制内容） |
| GET | `/knowledge-bases/:id/move-targets` | `retrieve` | 可迁移的目标库列表 |
| GET/POST | `/knowledge-bases/:id/hybrid-search` | `retrieve` | 库级混合检索（**POST 为首选**，GET 为兼容保留；`routes_knowledge.go:230-233`） |

### B. 知识的增删改查

| 方法 | 路径 | 能力 | 说明 |
|---|---|---|---|
| **POST** | `/knowledge-bases/:id/knowledge/file` | `ingest` | **上传文件** |
| **POST** | `/knowledge-bases/:id/knowledge/url` | `ingest` | **导入网页** |
| **POST** | `/knowledge-bases/:id/knowledge/manual` | `ingest` | **手工写 Markdown** |
| GET | `/knowledge-bases/:id/knowledge` | `retrieve` | 列知识（支持按目录筛，见 §五） |
| GET | `/knowledge/batch` | `retrieve` | 按 ID 批量取 |
| GET | `/knowledge/:id` | `retrieve` | 单条详情 |
| PUT | `/knowledge/:id` | `ingest` | 改标题/描述（**不能改目录**） |
| PUT | `/knowledge/manual/:id` | `ingest` | 改手工知识正文 |
| DELETE | `/knowledge/:id` | `ingest` | 删单条 |
| POST | `/knowledge/batch-delete` | `ingest` | 批量删 |
| DELETE | `/knowledge-bases/:id/knowledge` | **`full_access`** | **清空整库**（危险） |

### C. 目录（★ 两套，别混）

| 方法 | 路径 | 能力 | 属哪套 |
|---|---|---|---|
| GET | `/knowledge-bases/:id/knowledge/folders` | `retrieve` | 知识文档目录 |
| PUT | `/knowledge-bases/:id/knowledge/folders` | `ingest` | 知识文档目录（重命名/移动） |
| POST | `/knowledge/folder` | `ingest` | 知识文档目录（**归类 = 隐式建目录**） |
| GET | `/knowledgebase/:kb_id/wiki/folders` | `retrieve` | Wiki 目录 |
| POST | `/knowledgebase/:kb_id/wiki/folders` | `ingest` | Wiki 目录（**显式创建**） |
| PUT | `/knowledgebase/:kb_id/wiki/folders/:folder_id` | `ingest` | Wiki 目录（改名/换父） |
| DELETE | `/knowledgebase/:kb_id/wiki/folders/:folder_id` | `ingest` | Wiki 目录（仅空目录） |

### D. 解析、分块、检索、标签

| 方法 | 路径 | 能力 | 说明 |
|---|---|---|---|
| GET | `/knowledge/:id/stages`（或 `/spans`） | `retrieve` | 解析阶段进度 |
| POST | `/knowledge/:id/reparse` | `ingest` | 重新解析 |
| POST | `/knowledge/batch-reparse` | `ingest` | 批量重解析 |
| POST | `/knowledge/:id/cancel-parse` | `ingest` | 取消解析 |
| GET | `/chunks/:knowledge_id` | `retrieve` | **看实际切出的分块** |
| GET | `/chunks/by-id/:id` | `retrieve` | 按分块 ID 取 |
| PUT | `/chunks/:knowledge_id/:id` | `ingest` | 改分块 |
| DELETE | `/chunks/:knowledge_id/:id` | `ingest` | 删分块 |
| DELETE | `/chunks/:knowledge_id` | `ingest` | 删该知识的全部分块 |
| GET | `/knowledge-bases/:id/tags` | `retrieve` | 列标签 |
| POST | `/knowledge-bases/:id/tags` | `ingest` | 建标签 |
| PUT/DELETE | `/knowledge-bases/:id/tags/:tag_id` | `ingest` | 改/删标签 |
| PUT | `/knowledge/tags` | `ingest` | 批量给知识打标签 |
| **POST** | `/knowledge-search` | `retrieve` | **语义检索**（返回 chunk） |
| GET | `/knowledge/search` | `retrieve` | **文件级搜索**（按关键词列条目）⚠️ 与上一条不同 |

路由来源：`internal/router/routes_knowledge.go`（B/C/D 主体）、`routes_chat.go:148`（`/knowledge-search`）。

---

## 三、添加知识到指定知识库

三条入料通路，选型判据是**内容现在在哪**：

| 内容形态 | 用哪个 | 备注 |
|---|---|---|
| 本地文件（pdf/docx/xlsx/md…） | `/knowledge/file` | 判据顺序 **md > pdf > html**（见 §十三·坑4） |
| 在线网页 | `/knowledge/url` | 只抓这一个 URL，不跟链接 |
| 已在手边的正文 | `/knowledge/manual` | 直写 Markdown，不依赖外部可达性 |

### 3.1 上传文件 —— 附带目录（★ 一步归类的关键）

```bash
API=http://10.168.1.111:41201/api/v1
KB=<知识库ID>

curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  -F "file=@/abs/path/预算法.pdf" \
  -F "fileName=法律法规/预算法.pdf" \
  "$API/knowledge-bases/$KB/knowledge/file"
```

**`fileName` 的语义 = 相对路径**：最后一个 `/` 之前是**目录**，之后是**文件名**。
服务端用 `SplitKnowledgeRelativePath` 切分（`internal/types/knowledge_folder.go:83-92`），
目录**不存在会自动创建** —— 这是最省事的一次性归类方式。

表单字段（`internal/handler/knowledge.go:254-386`）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `file` | **是** | 文件本体（上限 `MAX_FILE_SIZE_MB`，默认 50MB） |
| `fileName` | 否 | 覆盖显示名，**可带目录**（`路径/文件名`） |
| `metadata` | 否 | JSON 字符串 |
| `enable_multimodel` | 否 | 多模态开关 |
| `process_config` | 否 | JSON，覆盖解析/分块配置 |
| `tag_ids` | 否 | 逗号分隔的标签 ID |
| `channel` | 否 | 来源渠道标记 |

> ⚠️ **`fileName` 最后一段才是文件名**：写 `-F "fileName=法律法规/"` 会让文件名为空并回退成原文件名，**目录白设**（实测，见 §十三·坑5）。

### 3.2 导入网页

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"url":"https://www.example.com/policy.html","title":"可选自定义标题"}' \
  "$API/knowledge-bases/$KB/knowledge/url"
```

可用字段：`url`（必填）、`file_name`、`file_type`、`title`、`enable_multimodel`、`tag_ids`、`process_config`。

> 行为与界面一致：**只抓这一个 URL，不跟随页面内链接**。
> **SSRF 白名单同样约束 API 调用**，内网地址会被 `400`。
> ⚠️ 网页存档（html）直传会产生大量导航/页脚噪声块 —— 见 §十三·坑4。

### 3.3 手工写入 Markdown

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"title":"预算法（节选）","content":"# 第一章\n..."}' \
  "$API/knowledge-bases/$KB/knowledge/manual"
```

后续改正文用 `PUT /knowledge/manual/:id`（注意路径段不同：**单条的在 `/knowledge/manual/:id`**，见 `routes_knowledge.go:111`）。

### 3.4 幂等性（重要）

**同一文件重复上传返回 `409`**（按 `file_hash` 去重），**不会产生重复条目**（`handleDuplicateKnowledgeError`，`internal/handler/knowledge.go:365`）。
⇒ 批量脚本可以**安全重试**，不必自己做去重。

---

## 四、创建与管理目录 ★

这一节是本文的核心。

### 4.0 先分清：两套目录模型

| 维度 | **A. 知识文档目录** | **B. Wiki 页面目录** |
|---|---|---|
| 本质 | **派生视图** —— 由 `knowledges.folder_path` 字段**聚合**出来的树 | **实体表** —— 每个目录是一条独立记录，有 `folder_id` |
| 存在形式 | 路径字符串，例 `法律法规/预算类` | ID + 名称 + 父 ID |
| **创建方式** | **没有创建接口** —— 把文档移到该路径即自动创建 | **`POST .../wiki/folders`**，显式创建（可先建空目录） |
| 空目录 | **不可能存在**（没有文档就没有这个目录） | 可以存在（`page_count=0`） |
| 重命名/移动 | `PUT .../knowledge/folders`，body `{from,to}`（**按路径**） | `PUT .../wiki/folders/:folder_id`，body `{name,parent_id,move_parent}`（**按 ID**） |
| 删除 | 无接口（把文档移走，空目录自动消失） | `DELETE .../wiki/folders/:folder_id`（**仅空目录**） |
| 改名对内容的影响 | 只改归类字段，**不重跑解析** | 重算整棵子树的路径 |
| 适用 | 上传的文档/网页/手工知识的归类 | Wiki 模式下 AI 生成页面的组织 |

> **一句话判据**：**你组织的是"上传的文档"用 A；组织的是"Wiki 页面"用 B。**
> Wiki 是知识库的一种内容模式，与普通文档目录**互不干扰**。

---

### 4.1 A 套：知识文档目录

#### 4.1.1 创建目录（= 把文档移过去）

**没有 `POST /folders`**。创建目录的唯一方式是调用移动接口，目标路径不存在时**自动创建**：

```
POST /api/v1/knowledge/folder
```

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"kb_id":"'$KB'","knowledge_ids":["<kid1>","<kid2>"],"folder_path":"法律法规/预算类"}' \
  "$API/knowledge/folder"
```

请求体（`internal/handler/knowledge.go:1021-1028`）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `kb_id` | **是** | 目标知识库 |
| `knowledge_ids` | **是** | 知识 ID 数组，**单次上限 200**（`:1057-1061`） |
| `folder_path` | 否 | 目标目录；**空串 = 知识库顶层**（故意非必填，以便把文档移出所有目录） |

响应：`{"data":{"moved_count":N,"folder_path":"<规范化后的路径>"}}`

**语义要点**（handler doc 原文，`knowledge.go:1032`）：

> 「批量修改知识条目所属文件夹。文件夹由路径推导而来，因此**目标路径不存在时会自动创建**；空路径表示知识库顶层。**仅调整归类，不会重新解析文档**」

⇒ 三个推论：
1. **建目录不需要先建**，直接移过去即可，父级链也会一并生成。
2. 归类**不重跑解析、不动向量索引**，归类后检索实测仍正常（实测）。
3. 想把文档"挪回根目录"：传 `"folder_path":""`。

#### 4.1.2 查目录树

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  "$API/knowledge-bases/$KB/knowledge/folders"
```

响应结构（`internal/types/knowledge_folder.go:125-149`）：

```json
{
  "success": true,
  "data": {
    "root_document_count": 3,
    "total_document_count": 42,
    "folders": [
      {
        "path": "法律法规",
        "name": "法律法规",
        "document_count": 1,
        "total_count": 12,
        "children": [
          { "path": "法律法规/预算类", "name": "预算类", "document_count": 11, "total_count": 11 }
        ]
      }
    ]
  }
}
```

| 字段 | 含义 |
|---|---|
| `root_document_count` | 在**根目录**（`folder_path=""`）的条目数 |
| `total_document_count` | 全库条目总数 |
| `document_count` | **直接**在本目录的文档数（不含子目录） |
| `total_count` | 本目录 + **所有子孙**目录的文档数 |
| `children` | 直接子目录，按名称排序 |

> **中间层会自动补**：只装子目录、自己没文档的中间目录也会被物化出来，保证层级不断链（`types/knowledge_folder.go:151-153`）。
> ⇒ **不能用 `document_count == 0` 判断目录该不该删** —— 它可能是纯中间层。

#### 4.1.3 重命名 / 移动整个目录

```
PUT /api/v1/knowledge-bases/:id/knowledge/folders
```

```bash
curl -sS --noproxy '*' -X PUT -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"from":"法律法规","to":"法规库"}' \
  "$API/knowledge-bases/$KB/knowledge/folders"
```

请求体（`internal/handler/knowledge.go:1099-1102`）：`from` / `to`，**都是必填**。

行为（handler doc，`knowledge.go:1106`）：
- 整棵子树（含所有子目录）一起改到新路径；
- **目标路径已存在时两个目录合并**；
- **不能移动到自身子目录下**。

#### 4.1.4 路径的规范化与上限（★ 静默截断）

所有路径（`folder_path` / `from` / `to` / 上传的 `fileName` 目录段）都过同一个函数
`NormalizeKnowledgeFolderPath`（`internal/types/knowledge_folder.go:38-77`）：

| 规则 | 行为 |
|---|---|
| `\` | 统一转成 `/` |
| 空段 / `.` / `..` | **静默丢弃** |
| 段尾的 `.` 和空格 | 静默去掉（防 `a.` 与 `a` 渲染成两个同类目录） |
| 单段超长 | **静默按 rune 截断**（不是报错） |
| 层级、总长超限 | **静默裁剪尾部段**（不是报错） |

上限（`types/knowledge_folder.go:14-19`）：

| 常量 | 值 | 说明 |
|---|---|---|
| `MaxKnowledgeFolderDepth` | **16** | 最大嵌套层数 |
| `MaxKnowledgeFolderPathLength` | **1024** | 整条路径字节数（对齐 DB 列宽） |
| `MaxKnowledgeFolderSegmentLength` | **128** | 单段字节数 |

> ⚠️ **单段上限是「字节」不是「字符」** —— 中文一个字 3 字节，所以**中文目录名最多 42 字**就会触发截断
> （代码注释原文：*"a folder named in Chinese hits that on the 43rd character"*，`types/knowledge_folder.go:55-56`）。
>
> **这是静默的**：接口返回 `200`，但路径已被裁。**判据是回读**：调用后 `GET .../knowledge/folders`
> 核对 `path` 是否与你的预期逐字一致 —— 不要相信请求回显的 `folder_path`（那是规范化结果，长这样才是正常的）。

---

### 4.2 B 套：Wiki 页面目录树

Wiki 是知识库的一种内容模式，其目录是**真实体**，因此有完整的 CRUD。

#### 创建（可先建空目录）

```
POST /api/v1/knowledgebase/:kb_id/wiki/folders
```

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"parent_id":"","name":"实体页"}' \
  "$API/knowledgebase/$KB/wiki/folders"
```

请求体（`internal/types/wiki_page.go:455-458`）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | **是** | 目录名 |
| `parent_id` | 否 | 父目录 ID；**空串 = 根级** |

成功返回 **`201`** + 一个 `WikiFolder` 对象（含新 `folder_id`）。

#### 查子目录

```
GET /api/v1/knowledgebase/:kb_id/wiki/folders?parent_id=<父ID>&page_types=<逗号分隔>
```

响应（`internal/types/wiki_page.go:441-452`）：

```json
{ "parent_id": "", "folders": [ { "...WikiFolder", "page_count": 5, "has_children": true } ] }
```

> **只返回直接子目录**（不递归）：`parent_id` 空 = 根级；`has_children` 供前端展开箭头用。**逐层拉取**。

#### 改名 / 换父目录

```
PUT /api/v1/knowledgebase/:kb_id/wiki/folders/:folder_id
```

请求体（`internal/types/wiki_page.go:463-467`）：

| 字段 | 说明 |
|---|---|
| `name` | 新名字（可省） |
| `parent_id` | 新父目录（可省） |
| `move_parent` | **布尔开关**：仅当为 `true` 时才应用 `parent_id` |

> ⚠️ `move_parent` 这个设计是为了**防误移**：只改名时不必回传可能为 "" 的父级，
> 避免"想改名却把目录挪到根"的意外。

#### 删除

```
DELETE /api/v1/knowledgebase/:kb_id/wiki/folders/:folder_id   → 204
```

**只能删空目录**（无页面、无子目录）。

#### 移动页面

```
PUT /api/v1/knowledgebase/:kb_id/wiki/move-page
body: { "slug": "<页面slug>", "folder_id": "<目标目录，空=根>" }
```

> `slug` 走 body 而非路径，因为 wiki slug 本身是层级式的（如 `entity/acme`），会与 gin 的 catch-all 冲突
> （`internal/types/wiki_page.go:469-475`）。

---

### 4.3 选哪套？

```
你要组织的对象是……
├─ 上传的文档 / 网页 / 手工 Markdown  → A 套（folder_path 派生）
│    ├─ 想给新文档归类 → 上传时用 fileName="目录/文件名"
│    ├─ 想给已有文档归类 → POST /knowledge/folder（自动建目录）
│    └─ 想整目录改名/挪位置 → PUT /knowledge-bases/:id/knowledge/folders
│
└─ Wiki 模式下的 AI 生成页面       → B 套（实体目录）
     ├─ 建空目录 → POST /knowledgebase/:kb_id/wiki/folders
     ├─ 把页面放进目录 → PUT /knowledgebase/:kb_id/wiki/move-page
     └─ 改名/换父 → PUT /knowledgebase/:kb_id/wiki/folders/:folder_id
```

---

## 五、列出与按目录筛选知识

```
GET /api/v1/knowledge-bases/:id/knowledge
```

**目录维度是"按参数是否存在"启用的**（`internal/handler/knowledge.go:929-938`）—— 这是设计上刻意为之：

| 参数 | 说明 |
|---|---|
| `folder_path` | **传了才按目录过滤**。空串 = 只看**根目录**（不含子目录） |
| `folder_recursive` | `true` 时连**子孙目录**一起返回（内部转为 `FolderScopeSubtree`） |

映射关系（`types/knowledge_folder.go:22-32`）：

| 传参 | 内部 scope | 效果 |
|---|---|---|
| 不传 `folder_path` | `FolderScopeAny` | 全库**扁平**列表（忽略目录） |
| `folder_path=X` | `FolderScopeExact` | 只看**直接**位于 X 的文档 |
| `folder_path=X&folder_recursive=true` | `FolderScopeSubtree` | X 及其**所有子孙** |

> ⚠️ `folder_path=` （空串）**不等于**"不过滤" —— 它表示"只列根目录"。
> 要**浏览某个文件夹**必须显式传；要**全库扁平列表**就完全不传。
> 源码注释解释了这个取舍（`knowledge.go:929-931`）：空串本身是有意义的取值，无法用取值区分"根目录"与"不过滤"。

其余可用查询参数（`internal/handler/knowledge.go:906-927`）：
`page` / `page_size`、`tag_ids`（逗号分隔）、`keyword`、`file_type`、`parse_status`、`source`、`start_time`、`end_time`。

```bash
# 只看"法律法规/预算类"下直接存放的文档
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  "$API/knowledge-bases/$KB/knowledge?folder_path=法律法规/预算类"

# 连子目录一起（子树）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  "$API/knowledge-bases/$KB/knowledge?folder_path=法律法规&folder_recursive=true"

# 只列根目录（注意 folder_path= 是空值，不是省略）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  "$API/knowledge-bases/$KB/knowledge?folder_path="
```

---

## 六、修改知识

```
PUT /api/v1/knowledge/:id
body: { "title": "...", "description": "...", "custom_metadata": {...} }
```

请求体（`internal/handler/knowledge.go:1723-1730`）**只有三个字段**：
`title` / `description` / `custom_metadata` —— **`folder_path` 不在其中**。

> ⚠️ **这是最容易踩的坑**：想改文档所在目录，调这个接口**不会报错，只是静默无效**（字段被忽略）。
> 必须走 `POST /knowledge/folder`（§4.1.1）。

另外：**改了分块配置要生效，必须重解析** —— `POST /knowledge/:id/reparse`（或批量 `POST /knowledge/batch-reparse`）。

---

## 七、删除知识

| 范围 | 接口 | 权限 |
|---|---|---|
| 单条 | `DELETE /knowledge/:id` | `ingest` |
| 批量 | `POST /knowledge/batch-delete`，body `{kb_id, ids[]}`（`knowledge.go:1291-1294`） | `ingest` |
| **整库清空** | `DELETE /knowledge-bases/:id/knowledge` | **仅 `full_access`** |

> ⚠️ 清空整库不可撤销。`full_access` 门控就是为它设的（`routes_knowledge.go:81-83`）。
> 在正式数据的库上操作前，先确认备份已跑（见 `my-docs/11-数据安全与备份/`）。

---

## 八、跨知识库迁移

```
POST /api/v1/knowledge/move
body: { "knowledge_ids": [...], "source_kb_id": "...", "target_kb_id": "...", "mode": "reuse_vectors" | "reparse" }
```

请求体（`internal/handler/knowledge.go:2284-2289`）：`mode` 是**枚举且必填**，只能取两个值：

| `mode` | 含义 | 何时用 |
|---|---|---|
| `reuse_vectors` | 复用已有向量 | 目标库 embedding 模型**相同** ⇒ 快 |
| `reparse` | 重新解析 | 目标库模型**不同**或配置不同 ⇒ 慢但正确 |

响应返回 `task_id`（`knowledge.go:2291-2296`），用 `GET /knowledge/move/progress/:task_id` 轮询。

> ⚠️ **选错 `mode` 会静默留下坏向量**：源库与目标库 embedding 模型不同却用 `reuse_vectors`，
> 向量空间不匹配 ⇒ 检索质量劣化且无报错。**换库前先比对两库的 embedding 配置。**
> 可迁移目标列表用 `GET /knowledge-bases/:id/move-targets` 查。

---

## 九、分块管理

上传后想确认"到底切成了什么"，看**分块**而不是状态：

```bash
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" "$API/chunks/<knowledge_id>"
```

> ★ **`total` 在响应顶层，不在 `data` 里**（实测）——
> 响应形状：`{data:[...], page, page_size, success, total}`。
> 写成 `data.total` 会恒为 `None`，误判成"只切了 1 块"。

| 操作 | 接口 |
|---|---|
| 列分块 | `GET /chunks/:knowledge_id` |
| 按 ID 取单块 | `GET /chunks/by-id/:id` |
| 改块 | `PUT /chunks/:knowledge_id/:id` |
| 删块 | `DELETE /chunks/:knowledge_id/:id` |
| 删该知识全部块 | `DELETE /chunks/:knowledge_id` |
| 分块预览（**只读试算，不写库**） | `POST /chunker/preview`，body `text` + `chunking_config` |

> **调分块参数前先只读试算**：`POST /chunker/preview` 不写库、不调 embedding，
> 其预测块数与实际上传**逐数一致**（实测，见 `weknora-kb-ingest` skill）。

---

## 十、标签管理

| 操作 | 接口 | body |
|---|---|---|
| 列标签 | `GET /knowledge-bases/:id/tags` | — |
| 建标签 | `POST /knowledge-bases/:id/tags` | `{name, color, sort_order}`（`internal/handler/tag.go:113-117`，`name` 必填） |
| 改标签 | `PUT /knowledge-bases/:id/tags/:tag_id` | `{name, color, sort_order}` 三者皆可选（`tag.go:159-163`） |
| 删标签 | `DELETE /knowledge-bases/:id/tags/:tag_id` | — |
| **批量给知识打标签** | `PUT /knowledge/tags` | 按知识 ID 批量改标签 |

检索时可用 `tag_ids` 做过滤（既可用于 `GET /knowledge-bases/:id/knowledge`，也可用于 `POST /knowledge-search`）。

---

## 十一、检索验证（★ 两个检索接口别搞混）

源码里有两个都叫 `SearchKnowledge` 的方法，**分属不同 handler、行为完全不同**：

| | **语义检索** | **文件级搜索** |
|---|---|---|
| 路径 | **`POST /api/v1/knowledge-search`** | **`GET /api/v1/knowledge/search`** |
| 实现 | `session.Handler.SearchKnowledge`（`internal/handler/session/qa.go:808`） | `KnowledgeHandler.SearchKnowledge`（`internal/handler/knowledge.go:2143`） |
| 入参 | **JSON body** | **query string**（`?keyword=` 或 `?query=`） |
| 返回 | **命中的分块**（chunk 级，带相似度） | **知识条目**（文件级） |
| 用途 | 验证"能不能召回、召回什么内容" | 按关键词列出文件 |

语义检索请求体（`internal/handler/session/types.go:76-83`）：

| 字段 | 说明 |
|---|---|
| `query` | **必填**，查询文本 |
| `knowledge_base_id` | 单库（向后兼容） |
| `knowledge_base_ids` | 多库（数组） |
| `knowledge_ids` | 限定到具体文件 |
| `tag_ids` | 限定到具体标签 |

```bash
# 语义检索：验检索闭环（用该文件独有的措辞做 query）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"<该文件独有的法条措辞>","knowledge_base_id":"'$KB'"}' \
  "$API/knowledge-search"

# 文件级搜索
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" "$API/knowledge/search?keyword=预算法"
```

> **入库后的验收标准是"能召回正确的块"，不是"状态变成 completed"** —— 见 §十三·坑3。

---

## 十二、解析状态与任务进度

| 用途 | 接口 |
|---|---|
| 单篇解析阶段 | `GET /knowledge/:id/stages`（别名 `/spans`） |
| 跨库迁移进度 | `GET /knowledge/move/progress/:task_id` |
| 知识库拷贝进度 | `GET /knowledge-bases/copy/progress/:task_id` |
| FAQ 导入进度 | `GET /faq/import/progress/:task_id` |

`parse_status` 的**四个**状态（源码口径，官方文档只写了三个 —— 实测）：

```
pending → processing → finalizing → completed
```

> ★ **分块与向量在 `finalizing` 之前就已落库**，此时**检索已可用**。
> `finalizing` 阶段是本地模型在跑摘要 + 自动标签，实测 **> 5 分钟**（模型越慢越久）。
> ⇒ **不要死等 `completed`**，会白白空等。判据：看它是否已越过 `processing`。

---

## 十三、实测坑清单

> 标「实测」的条目来自已沉淀的实测记录（`weknora-kb-ingest` skill，2026-09-21 前后），
> 不是本轮新验证；标 `文件:行号` 的来自源码。

| # | 坑 | 现象 | 处置 |
|---|---|---|---|
| 1 | 认证头 | 用 `Authorization: Bearer` 调 API Key 场景不通 | 用 `X-API-Key`（`auth.go:161`）；本机 curl 加 `--noproxy '*'`（实测） |
| 2 | `chunks` 的 total 位置 | 写 `data.total` 恒为 `None`，误判"只切了 1 块" | `total` 在**响应顶层**（实测） |
| 3 | 死等解析完成 | 卡在 `finalizing` 空等 >5 分钟 | `finalizing` 前检索已可用，**不必等 `completed`**（实测） |
| 4 | html 直传 | 一个政府网页被切成 6 块，**4 块是导航/页脚噪声**，正文块 4367 字符（超 `chunk_size=2000` 一倍）；检索命中文件对、**召回内容垃圾** | **html 先提正文转 Markdown 再上传**。判据顺序 md > pdf > html（实测） |
| 5 | `fileName` 目录白设 | 写 `-F "fileName=法律法规/"` ⇒ 文件名为空、回退原名、目录丢失 | 必须写**完整**「目录/文件名」（实测；`types/knowledge_folder.go:83-92`） |
| 6 | 以为要先建目录 | 找不到"创建文件夹"接口 | A 套**没有创建接口**，移动即创建（`knowledge.go:1032`） |
| 7 | 想改目录却调 `PUT /knowledge/:id` | **静默无效**，不报错 | 走 `POST /knowledge/folder`（`knowledge.go:1723-1730`） |
| 8 | 路径超限静默截断 | 返回 `200` 但路径被裁（中文名 43 字起触发） | 回读 `GET .../knowledge/folders` 核对 `path`（`types/knowledge_folder.go:14-19,52-62`） |
| 9 | `folder_path=` 空串 | 以为等于"不过滤"，实际只列根目录 | 要全库扁平列表就**省略该参数**（`knowledge.go:929-938`） |
| 10 | 重复上传 | 担心产生重复条目 | 返回 `409` 去重，**可安全重试**（`knowledge.go:365`） |
| 11 | 空目录判据 | 用 `document_count==0` 判断目录可删 | 纯中间层目录也是 0 但必须保留（`types/knowledge_folder.go:151-153`） |
| 12 | 跨库迁移 `mode` 选错 | 静默留下不匹配的向量，检索劣化无报错 | embedding 模型相同才用 `reuse_vectors`（`knowledge.go:2284-2289`） |
| 13 | 迁移/拷贝异步 | 以为调用完就完事 | 迁移与拷贝都返回 `task_id`，需轮询进度 |

---

## 十四、最小闭环示例（把本文串起来）

```bash
API=http://10.168.1.111:41201/api/v1
KB=<知识库ID>

# 1) 带目录上传（目录自动创建）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  -F "file=@/abs/预算法.pdf" -F "fileName=法律法规/预算类/预算法.pdf" \
  "$API/knowledge-bases/$KB/knowledge/file"
# → 记下 data.id 作为 KID

# 2) 看目录树（核对目录已建、路径未被截断）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" \
  "$API/knowledge-bases/$KB/knowledge/folders"

# 3) 给已有文档换目录（目标目录不存在会自动建）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"kb_id":"'$KB'","knowledge_ids":["'$KID'"],"folder_path":"法规库/预算"}' \
  "$API/knowledge/folder"

# 4) 整目录改名
curl -sS --noproxy '*' -X PUT -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"from":"法规库","to":"法律法规"}' \
  "$API/knowledge-bases/$KB/knowledge/folders"

# 5) 验分块质量（不看状态看内容）
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" "$API/chunks/$KID"

# 6) 验检索闭环
curl -sS --noproxy '*' -H "X-API-Key: $WK_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"<该文件独有的法条措辞>","knowledge_base_id":"'$KB'"}' \
  "$API/knowledge-search"
```

> ⚠️ 以上为**示例写法**。本文档未实际执行任何调用（不新增对服务器的写操作），
> 执行前请替换 `<...>` 并核对权限。**正式数据上操作前先确认备份已跑。**

---

## 十五、官方资料指针

| 内容 | 位置 |
|---|---|
| 知识 API（含 folder 章节 336–420 行） | `docs/api/knowledge.md` |
| 知识库 API | `docs/api/knowledge-base.md` |
| 空间与 API Key | `docs/api/tenant.md` |
| Swagger | `docs/swagger.json` / `docs/swagger.yaml` |
| 路由定义 | `internal/router/routes_knowledge.go`、`routes_chat.go:148` |
| 目录模型与上限 | `internal/types/knowledge_folder.go` |
| Wiki 目录类型 | `internal/types/wiki_page.go:419-475` |
| 知识 handler | `internal/handler/knowledge.go` |
| 语义检索 handler | `internal/handler/session/qa.go:808`、`session/types.go:76-83` |
| 鉴权中间件 | `internal/middleware/auth.go:119-161` |
| 批量上库实操 skill | `~/.workbuddy/skills/weknora-kb-ingest/SKILL.md` |
| 备份与数据安全 | `my-docs/11-数据安全与备份/WeKnora-数据安全与备份方案.md` |
| 上手链路（拿 Key → 建库 → 首导） | `my-docs/05-API与集成/WeKnora-通过API添加知识库指南.md` |
