# docreader 接入 PP-OCRv6（markitdown 路径）方案

> **目标**：让 docreader 在处理 **扫描件 PDF** 时改用 110 的 PP-OCRv6（`10.168.1.110:36741`），
> 而不是走 Go 侧的 VLM OCR。
> **约束**：不引入 VL 模型；官方文件改动降到最低；不重建 docreader 镜像。
> **状态**：方案已定，**未实施**。引用基线 `@993d6560`（`wkj-dev`）。
> **背景**：为什么不是其他路径，见 `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md`。

---

## 一、三个核实结论（决定了怎么改）

### 1.1 别用「插件机制」，用 `register_converter()`

原设想是「开启 markitdown 的插件 + 写一个插件」。**插件机制在这里是负担**：

- MarkItDown 靠 `importlib.metadata.entry_points(group="markitdown.plugin")` 发现插件
  ⇒ **插件必须是「已安装的 Python 发行版」**（带 entry point 元数据）；
  光把 `.py` 放进目录**不会被发现**
  ⇒ 要装包 ⇒ 改 `pyproject.toml` + **重建 docreader 镜像**。

而 `MarkItDown.register_converter()` 是**公开 API**（插件内部调的就是它）：

```python
md = MarkItDown()
md.register_converter(PPOCRConverter(...), priority=-1.0)   # 直接挂，不走插件发现
```

> 注意签名（0.1.3 实测）：**只有 converter 一个位置参数 + keyword-only `priority`**，
> 没有「按扩展名注册」那种写法 —— 扩展名匹配由 converter 自己的 `accepts()` 负责。
> `priority=-1.0` 抢在内置 PDF 转换器前面。

⇒ **功能等价**，但**免装包、免重建镜像**，配合「docreader 代码外置」可秒级生效。

### 1.2 依赖全现成（零新增）

| 需要的能力 | docreader 现有依赖（`uv.lock`） |
|---|---|
| PDF 拆页渲染 | **`pypdfium2 5.8.0`** |
| 图像处理 | `pillow 12.3.0` |
| HTTP 调 110 | `requests >=2.33.0` |
| 备用 PDF 库 | `pypdf 6.13.3` |

⇒ converter 直接复用，**不需要动依赖、不需要重建镜像**。

### 1.3 为什么不直接走现成的 `mineru` 引擎（它已内置 PP-OCRv6）

**MinerU 3.4+ 的 OCR 后端已升级到 PP-OCRv6**（官方 release notes：OmniDocBench v1.6
约 +11% 准确率、OCR 处理速度约翻倍），而 WeKnora 的 `mineru` 引擎**可配 endpoint**
⇒ 理论上零代码接入。**但不采用**，两条理由：

| 理由 | 说明 |
|---|---|
| **太重** | 完整文档解析管线：显存平均 **9.7 GB** / 峰值 **31.6 GB**，对比纯 PP-OCRv6 的 **0.6~2 GB**，重一个数量级 |
| **不可控（更本质）** | 它是**黑盒服务** —— 只能配 endpoint，OCR / 版面行为都改不了；而 docreader 的代码是外置的，**改它秒级生效** |

⇒ **docreader 的价值不在解析算法，而在它是「我们已经掌握、可编程的壳」**：
gRPC 契约、图片回传、元数据、并发限流、SSRF/TLS 安全 —— 整套都已打通。
对「用 PP-OCRv6 做扫描件 OCR」这个诉求，**可控性比算法强弱更重要**。

> **公平地说**：MinerU 唯一真正不可替代的是**版面结构 + 公式 LaTeX**
> （例如把表格还原成 markdown 表格）。但那与「省资源 + 只用 PP-OCRv6」直接冲突 ——
> 是个二选一，不是叠加。

---

## 二、改动清单

| # | 做什么 | 落在哪 | 改官方文件？ |
|---|---|---|---|
| 1 | 给 MarkItDown 挂上自研 converter | `docreader/parser/markitdown_parser.py`（约 2 行） | **是 · 唯一一处** |
| 2 | converter 本体（拆页 → 调 110 → 拼 markdown） | `my-docreader/`（新建，我们的目录） | 否 |
| 3 | 让容器能 import 到它 | `my-docker/docker-compose.overlay.yml`：加挂载 + `PYTHONPATH` | 否 |
| 4 | OCR 地址 / 档位等配置 | 同上：加环境变量 | 否 |
| 5 | 知识库把 `pdf` 的引擎改成 markitdown | Web UI | 否 |
| 6 | 存量文档重新解析 | `POST /knowledge/{id}/reparse` | 否 |
| 7 | 文档 | 本文件 | 否 |

**设计要点**：自研代码放**自己的目录**，通过挂载 + `PYTHONPATH` 让容器 import 到 ——
这样官方目录里只有 **2 行**改动（`import` + `register_converter`）。

```
宿主                                    容器
my-docreader/ppocr_converter.py   →    /app/docreader_ext/ppocr_converter.py
                                        PYTHONPATH=/app/docreader_ext
```

---

## 三、配置设计（环境变量）

下表是**代码里的默认值**（与 `my-docreader/ppocr_converter.py` 顶部常量一一对应）。
overlay 目前只显式注入前四个中的三个；其余用默认值，需要时在
`my-docker/docker-compose.overlay.yml` 的 `docreader.environment` 里追加即可。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PPOCR_BASE_URL` | `http://10.168.1.110:36741` | 110 的 PP-OCRv6 服务（overlay 已注入） |
| `PPOCR_TIERS` | `medium` | 档位（`tiny` / `small` / `medium`，overlay 已注入） |
| `PPOCR_FALLBACK` | `true` | 连不上 110 时回落到内置 PDF 转换器（overlay 已注入） |
| `PPOCR_TIMEOUT_SECONDS` | `60` | 单页请求超时 |
| `PPOCR_RENDER_DPI` | `200` | 页图渲染 DPI —— **与 docreader builtin 同口径，勿调低**（见 §五.⑥） |
| `PPOCR_MAX_EDGE` | `2000` | 页图长边上限 —— 同上口径（110 限制 ≤4096） |
| `PPOCR_JPEG_QUALITY` | `85` | 同上口径 |
| `PPOCR_MAX_RETRIES` | `3` | 429 退避重试次数（按 `Retry-After`） |
| `PPOCR_MAX_PAGES` | `0` | 处理页数上限，`0` = 不限（大 PDF 防超时） |
| **`PPOCR_SCAN_ONLY`** | `true` | **只接管扫描件 PDF**（判据见 §五.⑦）；置 `false` 则接管全部 `pdf` |
| **`PPOCR_SCAN_MIN_CHARS`** | `10` | 「该页无文本层」的字符阈值（同 builtin 的 `DOCREADER_PDF_SCAN_MIN_CHARS`） |
| **`PPOCR_SCAN_PAGE_RATIO`** | `0.5` | 无文本层页占比达此值 ⇒ 整份判为扫描件 |

> 走 overlay 的环境变量即可，**不需要**接 WeKnora 的 `parser_engine_overrides`
> （那条链路要改 Go 侧 `tenant.go` + `parser_url_security.go`，与「少改官方文件」相悖）。

---

## 四、converter 设计要点

### 4.0 参考实现：已扒 `markitdown-ocr` 源码（一手证据）

**没有现成的 PP-OCRv6 插件。** `markitdown-ocr` 是 MarkItDown 仓库里唯一的 OCR 插件，
其文档原文点明：*"doesn't bundle a traditional OCR engine like **Tesseract or PaddleOCR**"* ——
它只调 OpenAI 兼容的 vision API。

**但它的结构可以直接借鉴**（实测 `pip download markitdown-ocr` 解包 0.1.0 读出）：

**① 注册方式**（决定 `markitdown_parser.py` 怎么写）

```python
# 来自 markitdown_ocr/_plugin.py
markitdown.register_converter(
    PdfConverterWithOCR(ocr_service=ocr_service), priority=-1.0
)
```

⇒ 签名是 **`register_converter(converter_instance, priority=float)`**，
`priority=-1.0` 用于**抢占**内置转换器（内置为 `0.0`）。
⚠️ 这是**新版 API**；WeKnora 锁的是 **0.1.3** ⇒ **务必按 §五.② 先实测签名**。

**② OCR 后端是解耦的 —— 只需实现一个方法**

```python
# 来自 markitdown_ocr/_ocr_service.py
class LLMVisionOCRService:
    def extract_text(
        self, image_stream: BinaryIO,
        prompt: str | None = None,
        stream_info: StreamInfo | None = None,
        **kwargs: Any,
    ) -> OCRResult:          # OCRResult(text, confidence, backend_used, error)
```

⇒ **这就是要替换的接缝**：写出 `PPOCRV6Service.extract_text()`（内部打 110 的 `/api/ocr`），
**其余骨架不动**。

**③ PDF 骨架（422 行，两段式）**

| 阶段 | 行为 |
|---|---|
| 嵌入图 | 混排页里只裁出图送 OCR，结果按**原始 Y 坐标**回插，保持阅读顺序 |
| 整页兜底 | 文本抽取**完全为空**时（纯扫描件），整页渲染后**逐页**送 OCR |

⚠️ 它的整页渲染依赖 **`PyMuPDF`（`import fitz`）**，而 docreader **没有这个包**
（用的是 `pypdfium2`）⇒ 若照抄骨架，**渲染那段要换成 `pypdfium2`**，
否则就得加依赖 + 重建镜像。

**④ 三条从它身上学到的教训**

| 它的做法 | 我们不要照做 |
|---|---|
| 未传 `llm_client` 时**静默返回空**（原文 *"OCR is silently skipped"*） | **显式失败或回落** —— 静默空结果是批量任务里最难查的坑 |
| 渲染用 **300 dpi** | 可参考（对字准友好），但要守住 110 的长边 ≤4096px 限制 |
| README 里的 CLI 参数 `--llm-client` **是文档 bug，实际不存在** | 只走 Python API（WeKnora 也正好是 Python API 调用） |

### 4.1 我们的 converter 骨架

```python
class PPOCRConverter(DocumentConverter):
    def accepts(self, file_stream, stream_info, **kwargs) -> bool:
        return stream_info.extension == ".pdf"        # 只管 PDF，不碰 docx/pptx/xlsx

    def convert(self, file_stream, stream_info, **kwargs) -> DocumentConverterResult:
        pdf_bytes = file_stream.read()
        pages = render_pages(pdf_bytes)               # pypdfium2，逐页 → PNG/JPEG bytes
        texts = [ocr(page) for page in pages]         # 串行 + 429 退避 → 110 /api/ocr
        return DocumentConverterResult(text_content="\n\n".join(texts))
```

**必须处理的五件事**：

1. **串行 + 429 退避**。110 是串行 ≈1 张/s；`parser_worker_limit("markitdown", …)`
   只管「同时几个文档」，**管不住「一篇文档内的多页」** ⇒ converter 内部自己串行。
2. **★ 页图渲染参数直接沿用 docreader builtin 的值** ——
   **DPI 200 / JPEG 质量 85 / 长边 ≤2000px**（即 `DOCREADER_PDF_RENDER_DPI` /
   `DOCREADER_PDF_JPEG_QUALITY` / `DOCREADER_PDF_RENDER_MAX_EDGE` 的默认值）。
   这是官方调好的平衡点；**自己定低了 OCR 准确率会直接掉**。
   2000px 也远落在 110 的限制内（最长边 ≤4096px）。
3. **忽略 `keep_data_uris`**。WeKnora 会分别以 `True` / `False` 调两次（第二次是重试），
   converter 要能安全接受并忽略该 kwarg。
4. **回落**。连不上 110 时（`PPOCR_FALLBACK=true`）退给内置 PDF 转换器，
   避免 110 一挂就整条解析失败。
5. **★ 结构补偿（质量关键，见 §五.⑥）** —— 纯 OCR 只给文本行，markdown 里没有标题层级，
   会让下游 chunker 的 heading 策略失效、退化为按长度切。
   建议请求 110 时开 **`include_boxes=true`**，用行坐标做轻量重组：
   按 y 聚类成段落、按 x 与行高推断层级。**这是把「结构质量」找回来的主要手段。**
   实测表明这**不是可选项而是必须项** —— 见 §4.6。

### 4.6 实测结论（2026-09-22）

**素材**：`2025年预算执行等情况审计结果_扫描版.pdf`
（27 MB / **38 页** / 前三页文本层字符数 **0** ⇒ 纯图片 PDF）。

**方法**：`pypdfium2` 按 docreader 参数渲染（**DPI 200、长边钳制 2000px**）
→ `POST /api/ocr`（`tiers=medium&include_boxes=true`）。

| 页型 | 行数 | 行高 | 左边界 | 平均置信度 | 单页推理 |
|---|---|---|---|---|---|
| **正文页**（2 / 3 页） | 20–21 | 35–36 px（标题 40–54） | 191/194（缩进行 274/297） | 0.990–0.995 | 432–466 ms |
| **表格页**（5 / 10 页） | **46** | **27–29 px** | 415/417（另有 217/282） | 0.998 | 735–780 ms |

**模型确认**：`PP-OCRv6_medium_det` + `PP-OCRv6_medium_rec`（与预期一致）。

**三条结论**：

**① 字准没问题** —— 均分 0.99+，标题、金额、专有名词均正确。

**② 每行都返回 `bbox`，结构化重组可行**

```json
{"text":"中央部门单位2025年度预算执行等","score":0.9995,
 "box":[[307,254],[1107,254],[1107,296],[307,296]],
 "bbox":[307.0,254.0,1107.0,296.0]}
```

实测可直接用做判据：**标题行高 42–54 px vs 正文 35–36 px** ⇒ 按行高可分离标题；
**缩进行左边界 274/297 vs 正文 191** ⇒ 按左边界可识别段落起始与层级。

**③ ★ 表格页的 `text` 顺序是错的 —— 二维重组是必须项，不是可选项**

表格页把多列内容**交错**在了一起（实测片段）：

```
至2025年底，主管的《中国科技纵横》杂志社违规将应由自身开展的4
3                      ← 表格「序号」列的值，插进了正文句子中间
科技部                 ← 「部门名称」列
个栏目征稿工作，委托给3家外部企业开展并向其收取管理费224.35
```

⇒ 文字**没有丢失**，但**阅读顺序错了**：长文本单元格跨多行，按 y 排序时与相邻列错位。
**对 RAG 的后果**：同一单元格的内容被切断、灌进不同 chunk。

**⇒ converter 至少要做这四步重组**：

1. 按 y 聚类成「行带」（同一带内 y 中心差 < 行高 × 0.5）；
2. 行带内按 x1 排序 → 恢复「从左到右」；
3. 表格页进一步：对 x1 做一维聚类求**列边界**，再按 (行带, 列) 重排；
4. 标题识别（行高 > 正文中位数 × 1.15，或短行且水平居中）+ 连续同左边界正文行合并成段。

> **表格语义恢复不了** —— 纯 OCR 不做表格结构识别。二维重组只能做到「顺序正确」，
> 做不到「还原成 markdown 表格」。要真表格语义，只能换 PP-StructureV3 / MinerU
> （代价见 §1.3）。

### 4.7 重组效果：本地端到端实测（已实现并跑通）

用**真实** `markitdown==0.1.3` 注册 converter 后跑同一个 PDF 的前 8 页：

| 指标 | 初版 | 收紧后 |
|---|---|---|
| 标题行数 | 18（大量误判） | **6** |
| 8 页耗时 | 6.4 s | 6.5 s |

**修掉的两类误判**：

- 表格单元格文本被当标题（`## 国家发展` / `## 改革委`）
- 正文续行被当标题（`# 额721.18万元，其中2025年104.55万元。`）

**两条新增判据**（由实测误判样例反推，不是凭空设的）：

1. 标题**不以句读结尾**（`。，、；：！？…`）；
2. 标题**不含句中冒号/分号** —— 这条干掉了 `## 提出了审计建议：一是…`。

**另外两处改进**：

- **相邻标题行合并** —— OCR 常把主标题切成 2 行，现已合并为
  `## 中央部门单位2025年度预算执行等情况审计结果`；
- **去掉表格渲染分支** —— 表格判据在实测中不可靠（OCR 把单元格文本拆成独立行、
  y 不重叠，列特征与「带缩进的正文」难以区分），且误判代价高（正文段落会被拆散）。
  行带聚类本身已能把左右两列按 y 合回同一行，够用。

**跨页续接（已实现）**：按页独立 OCR 后，页尾与页首可能是同一句
（实测「…三是2家基金会的项目执行」+「方挪用捐赠资金90.21万元。」）。
原先用 `\n\n` 拼接会**人为制造一个段落边界**，下游 chunker 会正好切在那里。
现改为 `join_pages()`：**上一页末尾不是句读就与下一页直接相连**，否则按段落分隔。
实测该句已正确连成一段。

> **需要说清的边界**：跨页断裂本身是**所有 PDF 提取的通用现象** ——
> 有文本层的 PDF 同样如此（页边界就是硬边界，docreader 的 `PDFParser` 也不会做跨页续句）。
> 所以它不是 OCR 路径特有的。这里能改善的只是「**别把断句进一步强化成段落边界**」。
>
> 两条路在这一点的**真实差别**在「段落判定的可靠性」，而非「有没有断裂」：
> 文本层 PDF 能从字符流里算出空白 / 行距 / 缩进，docreader 还做了几何版面重建；
> 而扫描件只能靠 OCR 回来的 `bbox` 推断（本实现用 y 间距聚行带 + 左边界判缩进），
> 判据更薄一些。

**交付件**：`my-docreader/ppocr_converter.py`、
`my-docreader/test_ppocr_converter.py`、`my-docreader/README.md`。

**第二轮迭代（部署后容器内实测暴露的两处段落判定缺陷）**

| # | 现象 | 根因 | 修正 |
|---|---|---|---|
| 1 | 稀疏排版（封面 / 图注）的 3 行独立文字被**连成一段** | 用「上一行底边 → 本行顶边」的**间隙**判分段，而 **OCR 的 bbox 高度常已吃掉行距** ⇒ 间隙算出来接近 0 | 改用**行中心距**（`yc` 之差） |
| 2 | 真实公文段落块 **46 → 90**（段落结构被毁） | 阈值基准用了**行高**，而中文公文的**行距约为字形高的 2 倍**（35 px 字 / 76 px 间距）⇒ 每行都被判成新段 | 基准改为**相邻行距中位数 × 1.4**（相对判据） |

**这一轮判据的已知取舍**：改用相对判据后，**所有间距等距的稀疏排版不会被分段**
（封面、图注）。**可接受** —— 那种情况下文字不会丢，而误分段会毁掉真实文档的段落结构。
**判据宁可漏分段，不可误分段。**

> 两条修正合起来说明一件事：**重组判据必须用真实稿件实测标定**，
> 凭"排版常识"推出来的阈值（"行距≈行高"）在中文字体下是错的。

---

## 五、必须注意的点

**① 不选 markitdown，这条路就不会被走到**
扫描件 PDF 默认走 `builtin`（docreader 的 `PDFParser` 拆页 + **Go 侧 VLM OCR**）。
必须在**知识库 → 解析设置**里把 `pdf` 显式改成 `markitdown`。**这是最容易漏的一步。**

> 容易产生的误解：「我们改的不是 docreader 吗？跟 markitdown 有什么关系？」
> —— docreader 是**多引擎容器**，内置 `builtin` / `markitdown` / `opendataloader` 三个**引擎槽位**
> （`docreader/parser/registry.py:159-206`），每个槽位对同一文件类型挂不同的 parser 类。
> `pdf` 在 builtin 下是 `PDFParser`（**我们没动**），在 markitdown 下才是
> `MarkitdownParser` → 内部 `StdMarkitdownParser`（**我们改的就是这个**）。
> 引擎由**请求参数**决定（`parser.py:52,66` ← Go 侧 ← KB 解析设置）⇒
> 「改了 docreader 的文件」与「要在 KB 里选 markitdown」并不矛盾：
> 改的是那个槽位，不选它就走不到它。

**② markitdown 被锁在 0.1.3，写代码前先实测 API**
`uv.lock` 里实际版本是 **`0.1.3`**，不是最新（0.1.6）。
官方文档那套 `plugin_interface_version` / `register_converters` / priority 是**较新版本**的形态，
**0.1.3 的 `register_converter` 签名要以实测为准**：

```bash
docker exec <docreader容器> python -c \
  "import markitdown, inspect; print(markitdown.__version__); \
   print(inspect.signature(markitdown.MarkItDown.register_converter))"
```

**③ 超时预算**
一篇 N 页扫描件 = N 次 OCR 调用；按 110 的实测（≈0.14–0.25s 推理 + 排队）粗估
**每页 0.3–1s**，100 页约 **30–100s**。这还没算 docreader 的 gRPC 往返与
Go 侧 `docreader_call_timeout`。**大 PDF 有超时风险**，需按实际文档规模评估并调参。

**④ 输出里不会有图片**
内置 PDF 转换器会把文档内嵌图片内联进 markdown；我们的 converter **只出文字**
⇒ markdown 里没有图片。对「只要文字」的场景没问题，但要知道这个差异。

**⑤ 110 会成为 docreader 的硬依赖**
改完后 `markitdown` 引擎处理 PDF 必须能连到 110。**所以 §三 的 `PPOCR_FALLBACK` 建议保持开启**，
否则 110 一挂，这批文档全部解析失败。

**⑥ 质量要分两个维度看，结构一项已有实测数据**（详见 §4.6）

| 维度 | 变化 | 依据 |
|---|---|---|
| **字级识别** | **↑** | 实测均分 **0.99+**；PP-OCRv6 检测 86.2 / 识别 83.2 |
| **文档结构** | **↓ 实测已确认** | 表格页 `text` 顺序错乱；markdown 无 `#` 层级 |

原因：builtin 路径交给 VLM 的 prompt 明确要求
*"extract all text **and layout structure** … output in pure Markdown format"*
（`image_multimodal.go` 的 `vlmOCRScannedPDFPrompt`）⇒ **VLM 会尝试组织标题与段落**；
而纯 OCR 只给文本行。

**对策**：开 `include_boxes=true` 做二维重组（可执行判据见 §4.6 末）。
若某批文档**结构比字准更重要**，那批仍走 `builtin` —— 引擎规则按库分开建即可。

**⑦ 接管范围：只认扫描件（`accepts()` 判据）**
原实现只判扩展名 ⇒ **KB 一旦选了 markitdown，该库全部 PDF 都会被送进 OCR**。
已修正为：文本层有效字符 < `PPOCR_SCAN_MIN_CHARS` 的页，占比 ≥ `PPOCR_SCAN_PAGE_RATIO`
时整份判为扫描件并接管；否则**返回 `False` 交回内置转换器**。
判据失效（异常）时同样交回内置 —— 本方案定位是**补足扫描件**，不是接管全部 PDF 处理。

实测对照（同一份审计报告的电子版 / 扫描版，各 38 页 —— 天然的对照组）：

| 样本 | 无文本层页 | `accepts()` | 走哪条 |
|---|---|---|---|
| 电子版 | 0 / 38 | `False` | 内置转换器抽文本层（毫秒级） |
| 扫描版 | 38 / 38 | `True` | 我们接管 → PP-OCRv6 |

⇒ 所以「KB 里把 pdf 改成 markitdown」**不会**让带文本层的 PDF 变慢或变糙。

---

## 六、上线前的验证顺序

1. **确认 API 形态**（§五.② 的那条命令）；
2. converter 本地跑通：用 `docreader/scripts/parse_local.py --engine markitdown` 直接调 Parser，
   不经 gRPC，先确认拆页 + OCR + markdown 拼接正确；
3. 容器内跑通：挂载 + `PYTHONPATH` 生效后，`docker exec` 里 import 一次；
4. **小样本端到端**：KB 里挑 1–2 份扫描件 PDF，改 pdf 引擎 → 重新解析 → 比对文本；
5. 再铺开存量（`reparse`），并观察 110 的 `/api/health` 队列深度与 429 比例。

---

## 七、回滚

- **关掉 converter**：把 `markitdown_parser.py` 的 `register_converter` 一行注释即可
  （YAML 层无需动）；
- **改回 builtin**：知识库 → 解析设置 → `pdf` 引擎改回内置；
- 两者都**不需要**重建镜像、不涉及数据迁移。
