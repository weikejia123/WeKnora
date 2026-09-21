"""PP-OCRv6 扫描件 PDF 转换器 —— docreader 定制件。

设计目标
--------
让 docreader 的 markitdown 引擎在处理 **纯图片 PDF** 时，改用 110 的 PP-OCRv6
（`http://10.168.1.110:36741`）做 OCR，而不是走 Go 侧的 VLM.

接入方式（见 my-docs/15-docreader定制/）
--------------------------------------
在 `docreader/parser/markitdown_parser.py` 里加两行：

    from ppocr_converter import build_converter      # PYTHONPATH 指向本目录
    self.markitdown.register_converter(build_converter(), priority=-1.0)

`priority=-1.0` 用于抢在 markitdown 内置的 PDF 转换器（0.0）之前。

本文件不依赖任何新包：pypdfium2 / pillow / requests 都是 docreader 现有依赖。
"""

from __future__ import annotations

import io
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from statistics import median
from typing import Any, BinaryIO, Optional

import requests
from markitdown import DocumentConverter, DocumentConverterResult, StreamInfo
from markitdown.converters._pdf_converter import PdfConverter

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------
# 配置（全部可用环境变量覆盖，见 overlay）
# --------------------------------------------------------------------------

def _env_str(key: str, default: str) -> str:
    return (os.getenv(key) or default).strip()


def _env_int(key: str, default: int) -> int:
    try:
        return int(_env_str(key, str(default)))
    except ValueError:
        return default


def _env_bool(key: str, default: bool) -> bool:
    raw = _env_str(key, "").lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


BASE_URL = _env_str("PPOCR_BASE_URL", "http://10.168.1.110:36741")
TIERS = _env_str("PPOCR_TIERS", "medium")
HTTP_TIMEOUT = _env_int("PPOCR_TIMEOUT_SECONDS", 60)
RENDER_DPI = _env_int("PPOCR_RENDER_DPI", 200)          # 与 docreader builtin 一致
MAX_EDGE = _env_int("PPOCR_MAX_EDGE", 2000)             # 与 docreader builtin 一致
JPEG_QUALITY = _env_int("PPOCR_JPEG_QUALITY", 85)
FALLBACK = _env_bool("PPOCR_FALLBACK", True)
MAX_RETRIES = _env_int("PPOCR_MAX_RETRIES", 3)
# 0 = 不限制。110 是串行 ≈1 张/s，超大 PDF 会顶穿上游超时，可在此设上限。
MAX_PAGES = _env_int("PPOCR_MAX_PAGES", 0)

# 110 是串行服务（≈1 张/s）。docreader 的 gRPC 有多个 worker，
# 所以串行化必须放在**进程级**，而不是只在单个文档内部串行。
_OCR_LOCK = threading.Lock()

# 页码行：—1— / - 2 - / 12
_PAGE_NUMBER_RE = re.compile(r"^[\s—\-–_·]*\d{1,4}[\s—\-–_·]*$")


# --------------------------------------------------------------------------
# OCR 结果
# --------------------------------------------------------------------------

@dataclass
class OCRResult:
    """单页 OCR 结果。`lines` 保留 bbox，供二维重组使用。"""

    text: str = ""
    confidence: Optional[float] = None
    backend_used: Optional[str] = None
    error: Optional[str] = None
    lines: list[dict] = field(default_factory=list)
    page_size: Optional[tuple[int, int]] = None


# --------------------------------------------------------------------------
# OCR 服务
# --------------------------------------------------------------------------

class PPOCRv6Service:
    """调用 110 的 PP-OCRv6 服务（multipart /api/ocr）。"""

    def __init__(
        self,
        base_url: str = BASE_URL,
        tiers: str = TIERS,
        timeout: int = HTTP_TIMEOUT,
        max_retries: int = MAX_RETRIES,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.tiers = tiers
        self.timeout = timeout
        self.max_retries = max_retries

        # trust_env=False：绕开系统代理，直连内网（与 110 文档一致）
        self._session = requests.Session()
        self._session.trust_env = False

    # -- 对外接口：与 markitdown-ocr 的 LLMVisionOCRService.extract_text 同构 --
    def extract_text(
        self,
        image_stream: BinaryIO,
        prompt: Optional[str] = None,
        stream_info: Optional[StreamInfo] = None,
        page_size: Optional[tuple[int, int]] = None,
        **kwargs: Any,
    ) -> OCRResult:
        """对一张页图做 OCR。`prompt` 参数保留以兼容接口，本后端不使用。"""
        try:
            image_stream.seek(0)
            payload = image_stream.read()
        except Exception as exc:      # pragma: no cover - 极端情况
            return OCRResult(error=f"read image stream: {exc}", backend_used="ppocrv6")

        if not payload:
            return OCRResult(error="empty image", backend_used="ppocrv6")

        # 进程级串行：110 一次只跑一张，并发只会撞 429
        with _OCR_LOCK:
            return self._post(payload, page_size)

    def _post(self, payload: bytes, page_size: Optional[tuple[int, int]]) -> OCRResult:
        url = f"{self.base_url}/api/ocr"
        last_err = ""

        for attempt in range(self.max_retries):
            try:
                resp = self._session.post(
                    url,
                    files={"image": ("page.jpg", payload, "image/jpeg")},
                    data={"tiers": self.tiers, "include_boxes": "true"},
                    timeout=self.timeout,
                )
            except requests.RequestException as exc:
                last_err = f"request failed: {exc}"
                logger.warning("[PPOCRv6] %s (attempt %d)", last_err, attempt + 1)
                time.sleep(min(2 ** attempt, 5))
                continue

            if resp.status_code == 429:
                # 限流是正常保护，按 Retry-After 退避（110 实测返回 retry-after: 1）
                wait = int(resp.headers.get("Retry-After", "5") or 5)
                last_err = f"429 rate limited, wait {wait}s"
                logger.info("[PPOCRv6] %s (attempt %d)", last_err, attempt + 1)
                time.sleep(wait)
                continue

            if resp.status_code != 200:
                last_err = f"HTTP {resp.status_code}: {resp.text[:200]}"
                # 4xx 多为请求本身的问题，重试无益
                if 400 <= resp.status_code < 500:
                    break
                time.sleep(min(2 ** attempt, 5))
                continue

            try:
                body = resp.json()
            except ValueError as exc:
                last_err = f"invalid JSON: {exc}"
                time.sleep(min(2 ** attempt, 5))
                continue

            results = body.get("results") or []
            if not results:
                errors = body.get("errors") or []
                last_err = f"no results; errors={errors}"
                break

            first = results[0]
            if first.get("error"):
                last_err = f"service error: {first['error']}"
                break

            return OCRResult(
                text=first.get("text", "") or "",
                confidence=first.get("avg_score"),
                backend_used="ppocrv6",
                lines=first.get("lines") or [],
                page_size=page_size,
            )

        return OCRResult(error=last_err or "unknown error", backend_used="ppocrv6")

    # -- 可用性探测（供日志/排障，不阻塞主流程）--
    def ping(self) -> tuple[bool, str]:
        try:
            resp = self._session.get(f"{self.base_url}/api/health", timeout=5)
            if resp.status_code == 200:
                info = resp.json()
                return True, f"device={info.get('device')} tiers={info.get('loaded_tiers')}"
            return False, f"HTTP {resp.status_code}"
        except requests.RequestException as exc:
            return False, str(exc)


# --------------------------------------------------------------------------
# 二维重组：把「行 + 坐标」重排成有顺序的 markdown
# --------------------------------------------------------------------------

class LayoutRestructurer:
    """按 bbox 做二维重组。

    为什么必须做：110 返回的 `text` 是**按 y 排序**的行拼接。表格页里长文本单元格
    跨多行，会与相邻列错位 —— 实测「序号」列的值会插进正文句子中间。
    这里按 (y 行带, x) 二维排序把它修正回来。

    结构语义（谁表格头、谁单元格）恢复不了，只保证**阅读顺序正确**。
    """

    def __init__(self, page_size: Optional[tuple[int, int]] = None) -> None:
        self.page_size = page_size

    def to_markdown(self, lines: list[dict]) -> str:
        # 只用「正文流」一条渲染路径：表格判据在实测中不可靠
        # （OCR 会把单元格文本拆成独立行、y 不重叠，列特征与缩进正文难以区分），
        # 且误判代价高（正文段落会被拆散）。行带聚类本身已能把左右两列按 y 合回同一行。
        rows = self._group_rows(lines)
        if not rows:
            return ""
        return self._render_flow(rows)

    # -- 行带聚类 --
    @staticmethod
    def _group_rows(lines: list[dict]) -> list[list[dict]]:
        """按 y 中心把行聚成「行带」；带内按 x1 排序。"""
        items = []
        for ln in lines:
            bbox = ln.get("bbox")
            if not bbox or len(bbox) != 4:
                continue
            x1, y1, x2, y2 = bbox
            if (x2 - x1) <= 0 or (y2 - y1) <= 0:
                continue
            items.append({"text": (ln.get("text") or "").strip(), "x1": x1, "y1": y1,
                          "x2": x2, "y2": y2, "score": ln.get("score"),
                          "yc": (y1 + y2) / 2, "h": y2 - y1})
        items = [i for i in items if i["text"]]
        if not items:
            return []

        h_med = median([i["h"] for i in items])
        tol = h_med * 0.5

        items.sort(key=lambda i: (i["yc"], i["x1"]))
        rows: list[list[dict]] = []
        for it in items:
            if rows and abs(it["yc"] - rows[-1][0]["yc"]) <= tol:
                rows[-1].append(it)
            else:
                rows.append([it])
        for r in rows:
            r.sort(key=lambda i: i["x1"])
        return rows

    # -- 正文流渲染 --
    def _render_flow(self, rows: list[list[dict]]) -> str:
        heights = [r[0]["h"] for r in rows] or [1.0]
        h_med = median(heights)
        min_x1 = min(r[0]["x1"] for r in rows)

        out: list[str] = []
        para: list[str] = []

        def flush() -> None:
            if para:
                out.append("".join(para))
                para.clear()

        for row in rows:
            first = row[0]
            text = " ".join(i["text"] for i in row).strip()
            if not text or _PAGE_NUMBER_RE.match(text):
                continue                      # 页码 / 空行

            # 标题判定 —— 判据偏保守：宁可漏判，不可给正文误加 #
            ratio = first["h"] / h_med if h_med else 1.0
            level = self._heading_level(text, ratio, self._is_centered(first))
            if level:
                if out and out[-1].startswith("#"):
                    # 相邻标题行合并（实测：主标题常被 OCR 切成 2 行）
                    out[-1] += text
                else:
                    flush()
                    out.append(f"{'#' * level} {text}")
                continue

            # 段落边界：段首缩进（中文公文典型缩进 2 字符）
            indented = (first["x1"] - min_x1) > h_med * 1.2
            if indented and para:
                flush()
            para.append(text)

        flush()
        return "\n\n".join(out)

    # 标题几乎不以句读结尾；正文续行/表格单元格被误判的样例全部以 。 或含 ： 结尾
    _SENTENCE_END = "。，、；：！？,;.!?)）】」》…"

    def _heading_level(self, text: str, ratio: float, centered: bool) -> int:
        """返回 1 / 2 表示标题层级，0 表示正文。"""
        if not text or ratio < 1.15 or len(text) > 30:
            return 0
        if text[-1] in self._SENTENCE_END:
            return 0
        # 含句中冒号/分号 ⇒ 判为正文（实测误判样例「提出了审计建议：一是…」）
        if any(ch in text for ch in "：；:;"):
            return 0
        if ratio >= 1.5:
            return 1
        return 2 if (centered or ratio >= 1.3) else 0

    def _is_centered(self, item: dict) -> bool:
        if not self.page_size:
            return False
        width = self.page_size[0]
        center = (item["x1"] + item["x2"]) / 2
        return abs(center - width / 2) < width * 0.08


# --------------------------------------------------------------------------
# 渲染
# --------------------------------------------------------------------------

def render_pdf_pages(pdf_bytes: bytes, dpi: int = RENDER_DPI,
                     max_edge: int = MAX_EDGE, quality: int = JPEG_QUALITY,
                     max_pages: int = MAX_PAGES):
    """PDF → 逐页 JPEG bytes。参数与 docreader builtin 的 PDF 渲染保持一致。"""
    import pypdfium2 as pdfium
    from PIL import Image

    pdf = pdfium.PdfDocument(io.BytesIO(pdf_bytes))
    try:
        total = len(pdf)
        limit = total if max_pages <= 0 else min(total, max_pages)
        for index in range(limit):
            page = pdf[index]
            bitmap = page.render(scale=dpi / 72.0)
            img = bitmap.to_pil()
            if img.mode != "RGB":
                img = img.convert("RGB")
            w, h = img.size
            if max_edge and max(w, h) > max_edge:
                ratio = max_edge / max(w, h)
                img = img.resize((max(1, int(w * ratio)), max(1, int(h * ratio))), Image.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=quality)
            yield index + 1, buf.getvalue(), img.size
    finally:
        pdf.close()


# --------------------------------------------------------------------------
# 转换器
# --------------------------------------------------------------------------

class PdfConverterWithPPOCR(DocumentConverter):
    """接管 .pdf：逐页渲染 → PP-OCRv6 → 二维重组 → markdown。"""

    PRIORITY = -1.0

    def __init__(self, ocr_service: Optional[PPOCRv6Service] = None,
                 enable_fallback: bool = FALLBACK) -> None:
        super().__init__()
        self.ocr_service = ocr_service or PPOCRv6Service()
        self.enable_fallback = enable_fallback
        self._inner = PdfConverter()      # 回落用（内置实现）

    # markitdown 0.1.3：accepts(file_stream, stream_info, **kwargs)
    def accepts(self, file_stream: BinaryIO, stream_info: StreamInfo, **kwargs: Any) -> bool:
        ext = (stream_info.extension or "").lower().lstrip(".")
        return ext == "pdf"

    def convert(self, file_stream: BinaryIO, stream_info: StreamInfo,
                **kwargs: Any) -> DocumentConverterResult:
        file_stream.seek(0)
        pdf_bytes = file_stream.read()

        ok, detail = self.ocr_service.ping()
        if not ok:
            # ★ 显式失败/回落 —— 不静默返回空（markitdown-ocr 的坑）
            logger.error("[PPOCRv6] unavailable (%s); fallback=%s", detail, self.enable_fallback)
            if self.enable_fallback:
                return self._inner.convert(io.BytesIO(pdf_bytes), stream_info, **kwargs)
            raise RuntimeError(f"PP-OCRv6 service unavailable: {detail}")

        pages_md: list[str] = []
        page_no = 0
        try:
            for page_no, jpeg, size in render_pdf_pages(pdf_bytes):
                result = self.ocr_service.extract_text(
                    io.BytesIO(jpeg), page_size=size
                )
                if result.error:
                    logger.warning("[PPOCRv6] page %d failed: %s", page_no, result.error)
                    if not self.enable_fallback:
                        raise RuntimeError(f"page {page_no}: {result.error}")
                    continue
                md = LayoutRestructurer(page_size=size).to_markdown(result.lines) \
                    or result.text
                if md.strip():
                    pages_md.append(md)
        except Exception as exc:
            logger.error("[PPOCRv6] convert failed at page %d: %s", page_no, exc)
            if self.enable_fallback:
                return self._inner.convert(io.BytesIO(pdf_bytes), stream_info, **kwargs)
            raise

        if not pages_md:
            logger.warning("[PPOCRv6] no text extracted from %d page(s)", page_no)
            if self.enable_fallback:
                return self._inner.convert(io.BytesIO(pdf_bytes), stream_info, **kwargs)
            return DocumentConverterResult(markdown="", title=None)

        logger.info("[PPOCRv6] converted %d page(s), %d chars",
                    len(pages_md), sum(len(p) for p in pages_md))
        return DocumentConverterResult(markdown="\n\n".join(pages_md), title=None)


def build_converter() -> PdfConverterWithPPOCR:
    """供 markitdown_parser.py 调用的入口。"""
    service = PPOCRv6Service()
    ok, detail = service.ping()
    if ok:
        logger.info("[PPOCRv6] OCR backend ready (%s)", detail)
    else:
        logger.warning("[PPOCRv6] OCR backend not reachable: %s", detail)
    return PdfConverterWithPPOCR(ocr_service=service)
