# MinerU 4.x 在 WeKnora 中的支持 —— 结案（改用官方原生方案）

> **状态：已结案（2026-09-25）。原「自研 `mineru_v4` 引擎」方案已作废，无需实施。**
>
> **起因**：2026-09-24 评估「改 WeKnora 代码、新增 `MinerU-4` 引擎」，
> 唯一实质代价是「**官方文件改动面 2 → 10+、上游不再零冲突**」。
> **结局**：官方 `e22a8367`（2026-09-25 同步的第 7 轮）**原生实现了该能力**
> （同一个引擎 + 探测式协议兼容）⇒ 改动面**保持 2 个**，110 侧也**不需要契约适配器**。

---

## 一、现在的结论：配置即用

**升级 MinerU 不需要改 WeKnora 的配置**（官方原话）。同一个 `mineru` 引擎按服务端能力自动选协议：

| `GET {endpoint}/v1/health` | 协议 | 适用 |
|---|---|---|
| `200` + `status=ok` | **V1**，5 步异步（`internal/infrastructure/docparser/mineru_v1_client.go`） | MinerU **≥ 4.0** |
| `404` / `405` | 旧版 `POST /file_parse`，同步 | MinerU **≤ 3.x** |
| `503` 带错误结构 | 直接报错，**不回退**（模型预加载失败等） | — |

### 本项目的填法（110 的 MinerU 4.0.6）

| 设置项 | 值 | 说明 |
|---|---|---|
| 引擎 | `mineru` | **不新增引擎**，UI 上仍是这一个 |
| `mineru_endpoint` | `http://10.168.1.110:36743` | 指向 110 的 `mineru-api` |
| `mineru_server_api_key` | **留空** | 110 的容器未以 `--api-key` 启动 ⇒ 不填；填错会导致探测/解析鉴权失败 |
| `mineru_tier` | `standard`（或留空） | 110 当前以 `--tier standard` 启动；留空则由服务端选默认（优先 `standard`） |
| `mineru_parse_method` | `auto` | V1 下映射为 `ocr_mode` |
| `mineru_model` / `mineru_vlm_server_url` / 公式 / 表格 / 语言 | **忽略** | 4.0 已删除这些参数；VLM 地址改在 MinerU 侧 `config.yaml` 里配置 |

⚠️ **`mineru_server_api_key` 与 `mineru_api_key` 是两个字段**：后者是 `mineru_cloud`
（mineru.net 云服务）的 Key，前者才是自建 4.0+ 服务端的 Key。**别填串**。

### V1 的几个行为（排障须知）

- 上传带 `sha256sum` ⇒ 服务端已有同文件则复用，不重传字节
- **仅「同源」**（scheme / host / 端口都相同）才附带 API Key；跨源地址（如预签名对象存储 URL）
  不带 Key，并照常经过 SSRF 校验
- 轮询从 2s 起指数退避、上限 30s；总时长仍 **1000s**（与旧版一致）
- 超时或调用方取消 ⇒ 发 `DELETE /v1/parse/jobs/{id}` 取消服务端任务
- ★ **MinerU 服务端把上传与任务状态存在进程内存** ⇒ **服务重启后正在轮询的任务会 404**，
  该次解析直接失败（不是 WeKnora 侧问题）
- 「测试连接」在 V1 上会**额外请求一次需要鉴权的** `GET /v1/parse/jobs?limit=1`
  ⇒ 能发现 API Key 缺失/错误（`/v1/health` 本身不校验 Key）

### ★ 服务端契约实测（2026-09-25，110 实测通过）

不依赖 WeKnora，直接走完 V1 五步，确认 110 侧契约与官方实现的假设一致：

| 步 | 调用 | 实测结果 |
|---|---|---|
| 1 | `POST /v1/uploads`（`filename` / `bytes` / `mime_type` / `sha256sum`） | 200，返回 `upload_id` + `upload_url` + **`upload_method: PUT`** |
| 2 | `PUT {upload_url}`（字节流，`Content-Type` 取自响应里的 `upload_headers`） | 200 |
| 3 | `POST /v1/uploads/{id}/complete` | `status: completed`，返回 `file.id`（`file-…`） |
| 4 | `POST /v1/parse/jobs` | 返回 **`job_id`**（注意字段名不是 `id`） |
| 5 | `GET /v1/parse/jobs/{job_id}` 轮询 | `completed`，`duration_ms: 47784`、`parser_version: 4.0.6`、`output_files.zip.file_id` |
| 6 | `GET /v1/files/{zip_file_id}/content` | 1,395,098 B 的 zip |

产物 zip **23 个条目**：`markdown.md`（29,083 字符，内容与原文一致）+ **19 张图片** +
`middle_json.json` / `structured_content.json` / `model_output.json`。

★ **两个只有实测才会知道的细节**（写代码 / 排障时有用）：

1. **`files` 不是字符串数组**，而是 `JobFileEntry` 对象数组，且 `source` 是**按 `type` 区分的联合类型**：
   `{"files":[{"source":{"type":"file_id","file_id":"file-…"}}]}`。传 `["file-…"]` 会 **400**。
2. **`sha256sum` 命中已有文件时 `upload_url` 为 `null`**（服务端直接复用）⇒ 调用方必须判空，
   不能假定"创建 upload 后一定有 URL 可 PUT"。

★ 其余实测观察：

- `/v1/tiers` 返回的四档（`flash` / `basic` / `standard` / `advanced`）与 WeKnora 的
  `mineru_tier` 选项**逐一对应**，且各带 `current_model`（standard/advanced 都是
  `MinerU2.5-Pro-2605-1.2B`）。
- `tier: standard` 确实**懒加载** vLLM：`/v1/health` 200 时显存几乎为 0，
  **首次解析才加载**（解析后 used 5263 MiB）⇒ 「探测通过」与「能解析」是两件事，别只看前者。

---

## 二、原方案为什么可以不做了（保留决策经过）

| 维度 | 原方案（自研引擎） | 官方方案（`e22a8367`） |
|---|---|---|
| 引擎 | **新增** `mineru_v4`，与旧 `mineru` 并存 | **同一个** `mineru`，探测式自动选协议 |
| 官方文件改动面 | **10+ 个**（Go 核心 + 前端 5 语言文件） | **0**（我方保持 2 个例外 Dockerfile） |
| 上游同步 | 多处冲突可预期 | **0 冲突** |
| 前端副本判据 | **失效**（副本内会出现"刻意改动量"） | **成立**（`diff -rq` 恒 2 条产物） |
| 旧版兼容 | 保留（两个引擎并存） | 保留（`404`/`405` 回落 `POST /file_parse`） |
| 维护方 | 我方 | 官方 |

⇒ **原方案 §3 的 19 项改动清单（后端 10 + 前端 9）全部不需要**。

> ★ 原方案 §6 曾预判这条风险："上游将来自己适配 4.x ⇒ 与其命名不同 ⇒ 可平滑切换到上游实现"。
> **该预判隔一天即发生**，且方向比预期更好：官方改的是**同一个引擎**、走**探测式兼容**，
> 连旧协议都不必放弃（我们原方案是"并存两个引擎"）。

---

## 三、相关文档

| 文档 | 内容 |
|---|---|
| `my-docs/15-docreader定制/MinerU-接入与运维（南宁110）.md` | 110 服务侧的部署 / 显存 / 运维；§8 保留 2026-09-23 的失败定位过程与证据链 |
| `my-docs/08-版本变更分析/WeKnora-官方main第7轮更新分析.md` | 本轮同步分析（§2.1、§5.1 讲这条） |
| 官方文档 | `website-docs/03-features/03-document-parsing.md` →「MinerU 自建引擎（Go 进程直连，不经 docreader）」一节 |
