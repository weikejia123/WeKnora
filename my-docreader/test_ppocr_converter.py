#!/usr/bin/env python3
"""ppocr_converter 的本地端到端验证脚本。

用法：
    python test_ppocr_converter.py <某个扫描件.pdf> [最多页数]

它做三件事：
1. 用真实的 markitdown（不是 mock）注册 converter，走一遍完整链路；
2. 打印耗时、字符数、标题数、段落数；
3. 打印正文，便于人工核对（视觉你来看，数据我验）。

依赖：markitdown==0.1.3（+[pdf]）、pypdfium2、pillow、requests。
"""

import logging
import os
import sys
import time

DEFAULT_PDF = "/Users/weikejia/Downloads/2025年预算执行等情况审计结果_扫描版.pdf"


def main() -> int:
    pdf_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PDF
    max_pages = sys.argv[2] if len(sys.argv) > 2 else "0"
    os.environ.setdefault("PPOCR_MAX_PAGES", max_pages)

    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)

    logging.basicConfig(level=logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")

    from markitdown import MarkItDown
    from ppocr_converter import build_converter, PPOCRv6Service

    ok, detail = PPOCRv6Service().ping()
    print(f"[服务] {'可用' if ok else '不可用'} —— {detail}")
    if not ok:
        print("（服务不可用时 converter 会回落到内置 PDF 转换器，下面的结果不代表 PP-OCRv6）")

    md = MarkItDown()
    # 关键：priority=-1.0 抢在 markitdown 内置 PDF 转换器（0.0）之前
    md.register_converter(build_converter(), priority=-1.0)

    started = time.time()
    with open(pdf_path, "rb") as fh:
        result = md.convert(fh, file_extension=".pdf")
    elapsed = time.time() - started

    text = result.markdown or ""
    headings = [ln for ln in text.split("\n") if ln.startswith("#")]
    blocks = [p for p in text.split("\n\n") if p.strip()]

    print(f"[文件] {os.path.basename(pdf_path)}")
    print(f"[耗时] {elapsed:.1f}s")
    print(f"[规模] {len(text)} 字符 / {len(blocks)} 段落块 / {len(headings)} 标题行")
    print("=" * 68)
    print(text)


if __name__ == "__main__":
    raise SystemExit(main())
