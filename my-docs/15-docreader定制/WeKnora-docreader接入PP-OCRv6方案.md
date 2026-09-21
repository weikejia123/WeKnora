# docreader 接入 PP-OCRv6（markitdown 路径）方案

> **目标**：让 docreader 在处理 **扫描件 PDF** 时改用 110 的 PP-OCRv6（`10.168.1.110:36741`），
> 而不是走 Go 侧的 VLM OCR。
> **约束**：不引入 VL 模型；官方文件改动降到最低；不重建 docreader 镜像。
> **状态**：方案已定，**未实施**。引用基线 `@993d6560`（`wkj-dev`）。
> **背景**：为什么不是其他路径，见 `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md`。

---

## 一、两个核实结论（决定了怎么改）

### 1.1 别用「插件机制」，用 `register_converter()`

原设想是「开启 markitdown 的插件 + 写一个插件」。**插件机制在这里是负担**：

- MarkItDown 靠 `importlib.metadata.entry_points(group="markitdown.plugin")` 发现插件
  ⇒ **插件必须是「已安装的 Python 发行版」**（带 entry point 元数据）；
  光把 `.py` 放进目录**不会被发现**
  ⇒ 要装包 ⇒ 改 `pyproject.toml` + **重建 docreader 镜像**。

而 `MarkItDown.register_converter()` 是**公开 API**（插件内部调的就是它）：

```python
md = MarkItDown()
md.register_converter(".pdf", PPOCRConverter(...))   # 直接挂，不走插件发现
```

⇒ **功能等价**，但**免装包、免重建镜像**，配合「docreader 代码外置」可秒级生效。

### 1.2 依赖全现成（零新增）

| 需要的能力 | docreader 现有依赖（`uv.lock`） |
|---|---|
| PDF 拆页渲染 | **`pypdfium2 5.8.0`** |
| 图像处理 | `pillow 12.3.0` |
| HTTP 调 110 | `requests >=2.33.0` |
| 备用 PDF 库 | `pypdf 6.13.3` |

⇒ converter 直接复用，**不需要动依赖、不需要重建镜像**。

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

| 变量 | 建议默认 | 说明 |
|---|---|---|
| `PPOCR_BASE_URL` | `http://10.168.1.110:36741` | 110 的 PP-OCRv6 服务 |
| `PPOCR_TIERS` | `medium` | 档位（`tiny` / `small` / `medium`） |
| `PPOCR_TIMEOUT_SECONDS` | `60` | 单页请求超时 |
| `PPOCR_RENDER_DPI` | `150` | 页图渲染 DPI（见 §五.④） |
| `PPOCR_MAX_EDGE` | `2048` | 页图长边上限（110 限制 ≤4096） |
| `PPOCR_FALLBACK` | `true` | 连不上 110 时回落到内置 PDF 转换器 |

> 走 overlay 的环境变量即可，**不需要**接 WeKnora 的 `parser_engine_overrides`
> （那条链路要改 Go 侧 `tenant.go` + `parser_url_security.go`，与「少改官方文件」相悖）。

---

## 四、converter 设计要点

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

**必须处理的四件事**：

1. **串行 + 429 退避**。110 是串行 ≈1 张/s；`parser_worker_limit("markitdown", …)`
   只管「同时几个文档」，**管不住「一篇文档内的多页」** ⇒ converter 内部自己串行。
2. **页图渲染参数**。DPI / 长边要落在 110 的限制内（最长边 ≤4096px、单图 ≤20MB）。
3. **忽略 `keep_data_uris`**。WeKnora 会分别以 `True` / `False` 调两次（第二次是重试），
   converter 要能安全接受并忽略该 kwarg。
4. **回落**。连不上 110 时（`PPOCR_FALLBACK=true`）退给内置 PDF 转换器，
   避免 110 一挂就整条解析失败。

---

## 五、五个必须注意的点

**① 不选 markitdown，这条路就不会被走到**
扫描件 PDF 默认走 `builtin`（docreader 的 `PDFParser` 拆页 + **Go 侧 VLM OCR**）。
必须在**知识库 → 解析设置**里把 `pdf` 显式改成 `markitdown`。**这是最容易漏的一步。**

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
