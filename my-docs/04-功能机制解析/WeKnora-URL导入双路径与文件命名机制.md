# WeKnora「导入网页」双路径机制与文件命名规则

> 起因：导入 `http://www.npc.gov.cn/c2/c30834/201905/t20190521_296660.html` 后，
> 知识库里的条目名是 `t20190521_296660.html`，**改不掉**；而之前导入的另一条网页却显示成了正常的网页标题。
>
> 本文基于 **源码 + 生产库记录 + 生产日志** 三方交叉核对，不含推测。
> 代码版本：本地 `wkj-dev` @ `b7e92e2f`；生产运行镜像为官方 `2026-09-03` 构建版（行号有偏差，见第六节）。

---

## 一、结论速览

1. **URL 导入有两条完全不同的代码路径**，由一个**自动路由判据**决定 —— 看你 URL 的**路径扩展名**。
2. 你那条链接以 **`.html` 结尾**，而 `html` 恰好在"可导入扩展名"白名单里 → 被判为**直链文件下载**（`type=file_url`）。
3. **文件名取 URL 最后一段**（`extractFileNameFromURL`）→ 于是叫 `t20190521_296660.html`。
4. 另一条正常显示标题的网页，URL 以 **`.shtml` 结尾**，`.shtml` **不在**白名单 → 走**网页解析路径**（`type=url`）；解析后系统会**用网页 `<title>` 自动更名**。
5. **"自动更名"这一步只写在网页路径里，文件路径完全没有。** 这不是偶发 bug，是两条路径的实现差异。
6. 而且**事后也改不掉** —— 更新接口不暴露 `file_name`，而前端显示优先级是 `file_name || title || source`，`file_name` 一旦非空，`title` 永远被盖住。

---

## 二、路由判据：`isFileURL()`

**位置**：`internal/application/service/knowledge_create.go:292-302`

```go
// isFileURL reports whether the given URL should be treated as a direct file download.
// Priority: URL path has a known file extension first, then fall back to user-provided fileName/fileType hints.
func isFileURL(rawURL, fileName, fileType string) bool {
	u, err := url.Parse(rawURL)
	if err == nil {
		ext := strings.ToLower(strings.TrimPrefix(path.Ext(u.Path), "."))
		if ext != "" && isSupportedImportExtension(ext) {   // ← 命中即走「文件」路径
			return true
		}
	}
	// Fall back to user-provided hints
	return fileName != "" || fileType != ""
}
```

**白名单**：`internal/application/service/knowledge_util.go:30-40`，`html` / `htm` / `mhtml` 都在里面：

```go
var supportedImportFileExtensions = map[string]struct{}{
	"pdf": {}, "txt": {}, "docx": {}, "doc": {}, "epub": {},
	"html": {}, "htm": {}, "mhtml": {}, "md": {}, "markdown": {},   // ← line 32
	"xmind": {},
	"png": {}, "jpg": {}, "jpeg": {}, "gif": {},
	"csv": {}, "xlsx": {}, "xls": {}, "pptx": {}, "ppt": {}, "json": {},
	"mp3": {}, "wav": {}, "m4a": {}, "flac": {}, "ogg": {},
}
```

**你的两条链接代入判据**：

| URL 路径尾段 | `path.Ext` 得到 | 在白名单？ | 路由结果 |
|---|---|---|---|
| `…t20190521_296660.**html**` | `html` | ✅ 是 | **文件路径** `createKnowledgeFromFileURL` |
| `…t20260731_2761692.**shtml**` | `shtml` | ❌ 否 | **网页路径**（正常解析） |

> 顺带点破一个易错点：`path.Ext(u.Path)` 只看 **path**，**不看 query 和 fragment**。
> 所以 `xxx.html?v=1`、`xxx.html#top` 仍然命中文件路径 —— 想靠加参数绕开是没用的。

---

## 三、两条路径的行为对照

| 维度 | 网页路径 `type=url` | 文件路径 `type=file_url` |
|---|---|---|
| 代码入口 | `knowledge_create.go:300` 起（函数内继续） | `knowledge_create.go:509` `createKnowledgeFromFileURL` |
| 抓取方式 | docreader 侧渲染抓取（可处理 JS 页面） | Go 侧 HTTP GET 下载字节流 |
| `file_name` 落库值 | **空** | `extractFileNameFromURL()` → URL 最后一段 |
| `title` 落库值 | 初始 = 请求里的 `title`（前端不传 → 空） | 若空则回落为 `displayName`（=`file_name`） |
| **解析后自动更名** | ✅ **有** —— 用网页 `<title>` 覆盖 | ❌ **无** |
| `file_type` | `html` | 由 `file_name` 后缀推断 |

### 3.1 自动更名的确切代码（只有网页路径有）

**位置**：`internal/application/service/knowledge_process.go:3584-3604`

```go
} else if payload.URL != "" {              // ← 3584：网页路径专属分支
		convertResult, err = s.convert(ctx, payload, kb, knowledge, eff, isLastRetry)
		...
		// Update knowledge title from extracted page title if not already set
		if knowledge.Title == "" || knowledge.Title == payload.URL {
			if extractedTitle := convertResult.Metadata["title"]; extractedTitle != "" {
				knowledge.Title = extractedTitle
				... logger.Infof(ctx, "Updated knowledge title to extracted page title: %s", extractedTitle)
			}
		}
```

文件路径分支里**没有对应的更新逻辑** —— 它只做了 `knowledge.Title = displayName`（`knowledge_create.go:632`），
也就是把 `.html` 那个名字**又抄了一遍**。

### 3.2 文件名的三级来源（文件路径）

**位置**：`knowledge_create.go:569-580` 与 `:478-486`

```go
// Resolve fileName: user-provided > extracted from URL path
if fileName == "" {
	fileName = extractFileNameFromURL(fileURL)   // ← 你的情况走到这里
}
...
displayName := fileName
if displayName == "" { displayName = title }
if displayName == "" { displayName = extractFileNameFromURL(fileURL) }
if displayName == "" { displayName = fileURL }
```

```go
// extractFileNameFromURL extracts the filename from a URL path
func extractFileNameFromURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil { return "" }
	base := path.Base(u.Path)
	if base == "." || base == "/" { return "" }
	return base            // ← "t20190521_296660.html"
}
```

---

## 四、为什么"改不掉"——三重锁

**第一重：更新接口不暴露 `file_name`。**
`internal/handler/knowledge.go:1682-1686`

```go
type UpdateKnowledgeRequest struct {
	Title          *string         `json:"title"`
	Description    *string         `json:"description"`
	CustomMetadata json.RawMessage `json:"custom_metadata"`
}
```

只有这三项。**没有 `file_name`**，所以无论界面还是 API，都改不了它。

**第二重：前端连 `title` 都不传。**
前端对 URL 导入只提交 `{ url, enable_multimodel, tag_ids, process_config }`
（`frontend/src/api/knowledge-base/index.ts:280-285`），**没有 `file_name`、也没有 `title`** —— 这正是后端要回落到"URL 末段"的原因。

**第三重（最阴的一重）：显示优先级里 `file_name` 压过 `title`。**
`frontend/src/hooks/useKnowledgeBase.ts:70-78`

```js
const rawName = item.file_name || item.title || item.source || t('knowledgeBase.untitledDocument')
...
original_file_name: item.file_name,
file_name: displayName,
```

而列表**直接渲染 `file_name`，没有二次回退**：
`frontend/src/views/knowledge/components/DocumentListView.vue:272-273`

```html
<button class="row-file-name" :title="item.file_name" ...>{{ item.file_name }}</button>
```

> **含义**：即使你绕过界面、直接用 API 改 `title` 成功，列表上**显示的仍然是 `t20190521_296660.html`**。
> 这个坑比"改不了"更难发现 —— 因为是"改了、也成功了、但看不出来"。

（`original_file_name` 字段保留了原始值，用途是下载时命名，不参与列表显示。）

---

## 五、实测证据（生产环境，非推理）

### 5.1 生产库两条 URL 记录对照

```sql
SELECT type, file_name, title, source FROM knowledges WHERE source LIKE 'http%';
```

| type | file_name | title | source 尾段 |
|---|---|---|---|
| `url` | **空** | `财政部关于加强中央部门科研和基建项目结转结余资金管理有关事项的通知` | `…_2761692.shtml` |
| `file_url` | **`t20190521_296660.html`** | `t20190521_296660.html`（= file_name） | `…_296660.html` |

**两条记录唯一的差异就是 URL 尾缀** —— 判据成立。

### 5.2 生产日志：两条链路走了不同分支

第一次导入（`…_2761692.shtml`，20:43:09）：

```
knowledge.go:467            Start creating knowledge from URL
knowledge_create.go:300     Start creating knowledge from URL
knowledge_process.go:3414   Updated knowledge title to extracted page title: 财政部关于加强…   ← ★ 更名发生
```

第二次导入（`…_296660.html`，21:12:35）：

```
knowledge.go:467            Start creating knowledge from URL
knowledge_create.go:300     Start creating knowledge from URL
knowledge_create.go:513     createKnowledgeFromFileURL | Start creating knowledge from file URL   ← ★ 走了文件分支
knowledge_create.go:704     Enqueued file URL process task
knowledge_create.go:708     Knowledge from file URL created successfully
                              （★ 没有 "Updated knowledge title" 这一行）
```

日志本身就是判据的最强证明。

---

## 六、附带发现：生产跑的不是你的 `wkj-dev` 代码

核对行号时发现一个必须报告的问题：

| | 生产日志报的行号 | 本地 `wkj-dev` 的行号 |
|---|---|---|
| "Updated knowledge title …" | `knowledge_process.go:3414` | `knowledge_process.go:3601` |

**差 187 行，而本地工作区是干净的** —— 说明 111 上执行的二进制**不是**这份克隆源码。实查证实：

```
wechatopenai/weknora-app:latest
  RepoDigests = [wechatopenai/weknora-app@sha256:14953fcb…]   ← 有 registry digest
  Created     = 2026-09-03T07:11:01Z                          ← 官方 9 月 3 日构建
容器 WeKnora-app 使用的镜像 = 同一个 digest
```

**判据**：`docker build` 出来的镜像 **没有** `RepoDigests`；`docker pull` 来的**一定有**。当前两者都是 `1` → 官方镜像。

原因在 `docker-compose.yml`：每个服务**同时**写了 `image:` 和 `build:`，共用同一个 tag。

| 命令 | 效果 |
|---|---|
| `docker compose pull`（`deploy` / `update` 用） | 拉官方镜像，覆盖 tag → **源码改动不生效** |
| `docker compose build`（`build` 子命令） | 从源码构建，覆盖同一 tag → **源码改动生效** |

> **对你的二开是硬约束**：改源码后必须走 `build`。而且用 `update` 会把本地构建的镜像**静默换回官方镜像** ——
> 表现为"代码改了、容器也重建了、功能一点没变"，极难排查。
> 部署脚本已加保护（检测到本地构建镜像时拒绝 pull 并自动改用 build）。

详细部署含义见 `my-docs/03-生产部署/WeKnora-生产部署与运维.md`。

---

## 七、解法

### 方案 A：重新导入时显式指定文件名（零改动，立刻可用）

后端 **是**接受 `file_name` 的（`internal/handler/knowledge.go:422-431` 的请求体里有 `file_name` 与 `title`），
只是前端没传。所以走 API 即可：

```jsonc
POST /api/v1/knowledge-bases/{kb_id}/knowledge/url
{
  "url": "http://www.npc.gov.cn/c2/c30834/201905/t20190521_296660.html",
  "file_name": "中华人民共和国预算法",     // ← 名字由你定
  "file_type": "html"                      // ★ 必须带，否则报「无法确定文件类型」
}
```

> **`file_type` 必须一起给**：`file_name` 若无扩展名，会走 `getFileType()` 得到 `unknown`，
> 再被 `resolveFileImportProcessConfig` → `validateImportFileType`（`knowledge_util.go:74`）拒掉，
> 报 `无法确定文件类型`（`knowledge_util.go:76-78`）。

**代价**：需删掉原记录再导（URL 有去重，`knowledge_create.go:346-364`）；且只对这一条有效，下次又得手工带参数。

### 方案 B：小改二开，让"重命名"成为一等能力（推荐）

三处配套改动，缺一不可：

1. **后端** `UpdateKnowledgeRequest`（`handler/knowledge.go:1682`）增加 `FileName *string`，
   handler 里在非 nil 时写回 `knowledge.FileName`；
2. **前端** 编辑弹窗增加"显示名称"输入框，并在 `updateKnowledge` 调用里带上 `file_name`；
3. （可选）`useKnowledgeBase.ts:70` 调整优先级，或允许 `file_name` 显式置空以回退到 `title`。

改完之后：所有导入方式都能改名，且能删掉 `.html` 尾巴。

### 方案 C：治本 —— 调整路由判据

让**网页类扩展名**（`html` / `htm`）优先走网页解析路径。理由：用户"导入网页"时输入 `.html` URL 的意图，
几乎总是"解析这个页面"，而不是"下载这个文件"。

折中做法（保留直链下载能力）：仅当 **URL 是 http(s) 且路径扩展名为 `html`/`htm`，且用户未显式提供 `file_name`/`file_type`** 时，改走网页路径。
显式提供参数 = 用户确实想按文件处理。这与 `isFileURL` 现有注释里的 "Priority" 思路一致。

> 注意：`mhtml` 是离线存档格式，**应保留在文件路径**，不要一起改。

---

## 八、证据索引

| # | 结论 | 位置 |
|---|---|---|
| 1 | 路由判据 `isFileURL`，按 URL 路径扩展名分流 | `internal/application/service/knowledge_create.go:292-302` |
| 2 | `html`/`htm`/`mhtml` 在可导入白名单内 | `internal/application/service/knowledge_util.go:30-40`（`html` 在 line 32） |
| 3 | 文件路径入口 | `internal/application/service/knowledge_create.go:509` |
| 4 | 文件名取自 URL 末段 | `internal/application/service/knowledge_create.go:478-486` |
| 5 | 文件名三级回落 + `Title` 抄 `displayName` | `internal/application/service/knowledge_create.go:569-580, 632` |
| 6 | **自动更名只在网页分支** | `internal/application/service/knowledge_process.go:3584-3604` |
| 7 | 更新接口无 `file_name` | `internal/handler/knowledge.go:1682-1686` |
| 8 | URL 导入请求体**有** `file_name` / `title` | `internal/handler/knowledge.go:422-431` |
| 9 | 前端 URL 导入不传 `file_name`/`title` | `frontend/src/api/knowledge-base/index.ts:280-285` |
| 10 | 显示优先级 `file_name \|\| title \|\| source` | `frontend/src/hooks/useKnowledgeBase.ts:70-78` |
| 11 | 列表直接渲染 `file_name`（无回退） | `frontend/src/views/knowledge/components/DocumentListView.vue:272-273` |
| 12 | 类型校验会拒 `unknown` | `internal/application/service/knowledge_util.go:74-83`（调用点 `knowledge_process_config.go:133`） |
| 13 | 生产库两条记录对照 | 111 `knowledges` 表 `source LIKE 'http%'` |
| 14 | 生产日志两条分支 | 111 `docker compose logs app`（20:43 / 21:12） |
| 15 | 生产跑官方镜像（`RepoDigests` 有值 / Created 2026-09-03） | 111 `docker image inspect wechatopenai/weknora-app:latest` |
| 16 | compose 同时写 `image:` 与 `build:` | `docker-compose.yml:37-40`（app）、`:3-11`（frontend） |

---

## 九、一句话总结

> **不是"html 没有更名"，而是"`html` 后缀把请求导到了文件下载分支，而那个分支压根没有更名这一步"。**
> 判据在 URL 的**路径扩展名**，改不成名的根因在**显示优先级**。
