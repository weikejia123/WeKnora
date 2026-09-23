# docreader + PP-OCRv6 备用路径（已搁置）

> **状态：已搁置，代码改动仍在。**
>
> 这条路是「在 docreader 里挂一个 converter，把 `markitdown` 引擎的 PDF 交给 110 的
> PP-OCRv6 单图 OCR 服务做 OCR」。**它依赖的 `pp-ocr-v6-gpu-api`（36741）容器已删除**
> ⇒ 现在走它会**静默降级**（见 §三.2）。
>
> 扫描件 PDF 的**原定路径**是 PP-StructureV3（★ 该服务**容器已删除**，2026-09-23 起；镜像保留可恢复）：
> 见 `PP-StructureV3-接入与运维（南宁110）.md` §七。
>
> **⚠️ 但代码改动还在**（docreader 官方文件 1 处 + 我们自己的目录），
> 所以本文档保留：**现存改动说明 + 恢复方式 + 回滚**。

---

## 一、现存的代码改动（当前实际）

| # | 是什么 | 落在哪 | 是否官方文件 |
|---|---|---|---|
| 1 | `try-import ppocr_converter` + `register_converter(…, priority=-1.0)`（**2 行**） | `docreader/parser/markitdown_parser.py`（带 `★ wkj 定制` 标记） | **是 · 唯一一处** |
| 2 | converter 本体（拆页 → 调 110 → 二维重组 → 拼 markdown） | `my-docreader/`（**我们自己的目录**） | 否 |
| 3 | 挂载 + `PYTHONPATH=/app/docreader_ext` + 4 个环境变量 | `my-docker/docker-compose.overlay.yml` | 否 |

投递方式：自研代码放**自己的目录**，通过挂载 + `PYTHONPATH` 让容器 import 到
⇒ 官方目录里只有 2 行改动。`server/` 与 `my-docreader/` 都是**只读挂载**
⇒ 改代码只需 `./deploy/deploy-wkj-dev.sh push-reader`（秒级），**不必重建镜像**。

---

## 二、配置项（若要恢复需要）

下表是**代码里的默认值**（与 `my-docreader/ppocr_converter.py` 顶部常量一一对应）。
overlay 目前显式注入前三个。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PPOCR_BASE_URL` | `http://10.168.1.110:36741` | 110 的 PP-OCRv6 服务（overlay 已注入） |
| `PPOCR_TIERS` | `medium` | 档位（`tiny`/`small`/`medium`） |
| `PPOCR_FALLBACK` | `true` | 连不上 110 时回落到内置 PDF 转换器 |
| `PPOCR_TIMEOUT_SECONDS` | `60` | 单页请求超时 |
| `PPOCR_RENDER_DPI` | `200` | 页图渲染 DPI —— **与 docreader builtin 同口径，勿调低** |
| `PPOCR_MAX_EDGE` | `2000` | 页图长边上限（110 限制 ≤4096） |
| `PPOCR_JPEG_QUALITY` | `85` | 同上口径 |
| `PPOCR_MAX_RETRIES` | `3` | 429 退避重试次数（按 `Retry-After`） |
| `PPOCR_MAX_PAGES` | `0` | 处理页数上限，`0` = 不限 |
| `PPOCR_SCAN_ONLY` | `true` | 只接管扫描件（判据见 §三.4） |
| `PPOCR_SCAN_MIN_CHARS` | `10` | 「该页无文本层」的字符阈值（同 builtin 口径） |
| `PPOCR_SCAN_PAGE_RATIO` | `0.5` | 无文本层页占比达此值 ⇒ 整份判为扫描件 |

> 走 overlay 的环境变量即可，**不需要**接 WeKnora 的 `parser_engine_overrides`
> （那条链路要改 Go 侧 `tenant.go` + `parser_url_security.go`，与「少改官方文件」相悖）。

---

## 三、必须记住的坑

**1. 不在知识库里选 `markitdown`，这条路根本不会被走到**

扫描件 PDF 默认走 `builtin`（docreader 的 `PDFParser` 拆页 + Go 侧 VLM OCR）。
必须在**知识库 → 解析引擎**里把 `pdf` 显式改成 `markitdown`。**最容易漏的一步。**

> **理解上的坑**：容易问「我们改的不是 docreader 吗？跟 markitdown 有什么关系？」
> —— docreader 是**多引擎容器**，内置 `builtin` / `markitdown` / `opendataloader`
> 三个**引擎槽位**（`docreader/parser/registry.py:159-206`），每个槽位对同一文件类型挂不同
> parser 类。`pdf` 在 builtin 下是 `PDFParser`（**我们没动**），在 markitdown 下才是
> `MarkitdownParser` → 内部 `StdMarkitdownParser`（**我们改的就是这个**）。
> 引擎由**请求参数**决定（`parser.py:52,66` ← Go 侧 ← KB 解析设置）
> ⇒「改了 docreader 的文件」与「要在 KB 里选 markitdown」不矛盾：改的是那个槽位，不选它就走不到它。

**2. ★ 110 已是硬依赖，且这个依赖已经断过 —— 降级是静默的**

`markitdown` 引擎处理 PDF 必须能连到 110。
**实际发生过**：36741 容器删除后，因为 `PPOCR_FALLBACK=true`，
**没有报错，只是能力静默降级**成「markitdown 内置 PDF 转换」。
⇒ 排查「markitdown 解析结果不对」时，**先确认这个服务在不在**。
⇒ 也正好印证当初选 `FALLBACK=true` 是对的（否则当时会是一批文档解析失败）。

**3. 用的是 `register_converter()`，不是 MarkItDown 的插件机制**

插件机制要求插件是**已安装的 Python 发行版**（靠 `importlib.metadata.entry_points` 发现）
⇒ 要装包 ⇒ **改 `pyproject.toml` + 重建 docreader 镜像**。
而 `register_converter()` 是公开 API，**免装包、免重建镜像**。功能等价。

> 附带：`markitdown-ocr` 官方插件**恰好是必须避开的那条路**（它走 LLM Vision），
> 且未传 `llm_client` 时会**静默返回空** —— 我们的实现**绝不静默失败**。

**4. 只接管扫描件（`accepts()` 判据），不是接管全部 PDF**

原实现只判扩展名 ⇒ KB 一旦选 markitdown，该库**全部** PDF 都会被送进 OCR。
已修正为：文本层有效字符 < `PPOCR_SCAN_MIN_CHARS` 的页，占比 ≥ `PPOCR_SCAN_PAGE_RATIO`
时整份判为扫描件并接管；否则**返回 `False` 交回内置转换器**。判据失效（异常）时同样交回内置。

实测对照（同一份审计报告的电子版 / 扫描版，各 38 页 —— 天然对照组）：

| 样本 | 无文本层页 | `accepts()` | 走哪条 |
|---|---|---|---|
| 电子版 | 0 / 38 | `False` | 内置转换器抽文本层（毫秒级） |
| 扫描版 | 38 / 38 | `True` | 接管 → PP-OCRv6 |

**5. `markitdown` 被锁在 `0.1.3` —— 签名已实测，与最新版一致**

```python
register_converter(self, converter: DocumentConverter, *, priority: float = 0.0) -> None
```

⇒ `priority=-1.0` 可抢在**内置 PDF 转换器**（`0.0`）之前。**这不是未知数。**

---

## 四、恢复方式

需要重新启用时，两步：

```bash
# ① 把后端服务起回来（镜像/编排/模型缓存都在）
ssh nanning-110 'cd /opt/docker-deploy/pp-ocr-v6 && docker compose -f compose.gpu.yaml up -d'
# ② 目标知识库 → 解析引擎 → 把 pdf 选为 markitdown
```

⚠️ 恢复第 ① 步会重新占约 **2.6 GB 显存**，与 PP-StructureV3 抢卡
（详见 `PP-StructureV3-接入与运维（南宁110）.md` §一的共卡说明）。

---

## 五、回滚

| 要做什么 | 怎么做 |
|---|---|
| 关掉 converter | 把 `markitdown_parser.py` 的 `register_converter` 一行注释掉 ⇒ `push-reader` |
| 改回内置引擎 | 知识库 → 解析引擎 → `pdf` 改回 `builtin` / `anydoc` |

两者都**不需要重建镜像、不涉及数据迁移**。
