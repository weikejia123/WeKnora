import io
import logging

from markitdown import MarkItDown

from docreader.config import CONFIG
from docreader.models.document import Document
from docreader.parser.base_parser import BaseParser
from docreader.parser.chain_parser import PipelineParser
from docreader.parser.concurrency import parser_worker_limit
from docreader.parser.docx_merge import fill_vertical_merged_cells_docx
from docreader.parser.markdown_parser import MarkdownParser
from docreader.parser.ppt_convert import normalize_ppt_bytes
from docreader.parser.pptx_media import (
    attach_pptx_media_to_markdown,
    markdown_needs_pptx_media_attach,
)

logger = logging.getLogger(__name__)

# ★ wkj 定制：PP-OCRv6 扫描件 OCR 转换器（见 my-docs/15-docreader定制/）。
#   该目录由 overlay 挂载到 /app/docreader_ext 并经 PYTHONPATH 注入。
#   取不到时**记 warning 并保持官方行为** —— 不静默改变解析路径。
try:
    from ppocr_converter import build_converter as _build_ppocr_converter
except ImportError:  # pragma: no cover - 未启用定制时
    _build_ppocr_converter = None
    logger.warning(
        "ppocr_converter not importable — PP-OCRv6 PDF path disabled "
        "(check the /app/docreader_ext mount and PYTHONPATH)"
    )


class StdMarkitdownParser(BaseParser):
    """
    Standard MarkItDown Parser Wrapper

    This parser uses the markitdown library to convert various document formats
    (docx, pptx, pdf, etc.) into text/markdown.
    """

    def __init__(self, *args, **kwargs):
        # 这里的 super() 会调用 BaseParser 的初始化，确保 self.file_type 被正确赋值
        super().__init__(*args, **kwargs)
        self.markitdown = MarkItDown()
        # ★ wkj 定制：注册 PP-OCRv6 的 PDF 转换器。
        #   priority=-1.0 抢在 markitdown 内置 PDF 转换器（0.0）之前；
        #   register_converter(converter, *, priority) 的签名已对 0.1.3 实测确认。
        if _build_ppocr_converter is not None:
            self.markitdown.register_converter(
                _build_ppocr_converter(), priority=-1.0
            )

    def parse_into_text(self, content: bytes) -> Document:
        """
        Parses content using MarkItDown.
        Uses self.file_type (inherited from BaseParser) to hint the stream format.
        """
        ext = self.file_type
        ft = (ext or "").lstrip(".").lower()
        pptx_bytes: bytes | None = None
        if ft in ("ppt", "pptx"):
            content, ext = normalize_ppt_bytes(content, ft)
            pptx_bytes = content
            ft = "pptx"
        elif ft == "docx":
            content = fill_vertical_merged_cells_docx(content)
        if ext and not ext.startswith("."):
            ext = "." + ext

        with parser_worker_limit("markitdown", CONFIG.markitdown_max_workers):
            result = self._convert_markitdown(content, ext, keep_data_uris=True)
            if result is None:
                logger.warning(
                    "MarkItDown failed with embedded images for %s; retrying without data URIs",
                    ft or ext,
                )
                result = self._convert_markitdown(content, ext, keep_data_uris=False)

        text = result.text_content
        images: dict[str, str] = {}
        if pptx_bytes is not None and markdown_needs_pptx_media_attach(text):
            text, images = attach_pptx_media_to_markdown(text, pptx_bytes)
        return Document(content=text, images=images)

    def _convert_markitdown(
        self, content: bytes, ext: str | None, *, keep_data_uris: bool
    ):
        try:
            return self.markitdown.convert(
                io.BytesIO(content),
                file_extension=ext,
                keep_data_uris=keep_data_uris,
            )
        except Exception:
            if keep_data_uris:
                return None
            raise


class MarkitdownParser(PipelineParser):
    _parser_cls = (StdMarkitdownParser, MarkdownParser)
