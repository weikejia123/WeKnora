# my-docreader —— docreader 定制件

> **状态：已接入，但这条路已搁置**（依赖的 `pp-ocr-v6-gpu-api` 容器已删除
> ⇒ 现在会按 `PPOCR_FALLBACK=true` **静默降级**成「markitdown 内置 PDF 转换」）。
> 现行扫描件路径是 **PP-StructureV3**（走 `paddleocr_vl` 引擎）：
> `my-docs/15-docreader定制/PP-StructureV3-接入与运维（南宁110）.md`。
> **代码保留。** 恢复方式与坑见 `my-docs/15-docreader定制/WeKnora-docreader接入PP-OCRv6方案.md`。

让 docreader 的 markitdown 引擎在处理**扫描件 PDF** 时改用 110 的 PP-OCRv6，
而不是走 Go 侧的 VLM。

方案依据（含实测数据、设计要点、风险与回滚）：
`my-docs/15-docreader定制/WeKnora-docreader接入PP-OCRv6方案.md`

## 内容

| 文件 | 作用 |
|---|---|
| `ppocr_converter.py` | PP-OCRv6 扫描件 PDF 转换器（MarkItDown converter + OCR 客户端 + 二维重组） |
| `test_ppocr_converter.py` | 本地端到端验证脚本 |

## 接入方式 —— 改 docreader 官方文件 2 行（**已实施**）

`docreader/parser/markitdown_parser.py`：

```python
# ① 顶部 import 区加一行
from ppocr_converter import build_converter

# ② StdMarkitdownParser.__init__ 里，在原有一行之后加一行
self.markitdown = MarkItDown()
self.markitdown.register_converter(build_converter(), priority=-1.0)
```

`priority=-1.0` 用于抢在 markitdown 内置 PDF 转换器（priority `0.0`）之前。
（`register_converter(converter, *, priority)` 的签名已对 0.1.3 实测确认。）

## 容器侧要求（改 `my-docker/docker-compose.overlay.yml`，非官方文件）

1. **挂载本目录**：`./my-docreader:/app/docreader_ext:ro`
2. **注入 PYTHONPATH 与配置**：

```yaml
environment:
  PYTHONPATH: /app/docreader_ext
  PPOCR_BASE_URL: http://10.168.1.110:36741
  PPOCR_TIERS: medium
```

3. **不需要重建 docreader 镜像** —— `pypdfium2` / `requests` / `pillow` 都已是 docreader 现有依赖。

## 本地验证

```bash
/Users/weikejia/.workbuddy/binaries/python/envs/default/bin/python3 \
  my-docreader/test_ppocr_converter.py "/path/to/扫描件.pdf"
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PPOCR_BASE_URL` | `http://10.168.1.110:36741` | OCR 服务地址 |
| `PPOCR_TIERS` | `medium` | 档位（tiny / small / medium） |
| `PPOCR_RENDER_DPI` | `200` | 页图渲染 DPI —— **与 docreader builtin 一致，别调低** |
| `PPOCR_MAX_EDGE` | `2000` | 页图长边上限 —— 同上 |
| `PPOCR_JPEG_QUALITY` | `85` | 页图 JPEG 质量 |
| `PPOCR_MAX_PAGES` | `0` | 限页，0 = 不限；用于控制大文件耗时 |
| `PPOCR_FALLBACK` | `true` | 服务不可用 / 单页失败时回落内置 PDF 转换器 |
| `PPOCR_TIMEOUT_SECONDS` | `60` | 单页请求超时 |
| `PPOCR_MAX_RETRIES` | `3` | 重试次数（429 会按 `Retry-After` 退避） |

## 两个实现上的关键决定

1. **进程级串行**：110 一次只跑一张（≈1 张/s），而 docreader 的 gRPC 有多个 worker
   ⇒ 互斥锁放在**模块级**，不是在单个文档内部串行。
2. **不静默失败**：`markitdown-ocr` 未配置 client 时会静默返回空（批量任务里最难查的坑）。
   本实现遇到服务不可用会**记 error 日志并回落**；关掉 `PPOCR_FALLBACK` 则直接抛错。
