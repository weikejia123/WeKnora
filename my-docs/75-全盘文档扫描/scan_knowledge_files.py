#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
全盘知识文件扫描器（只读，不修改任何被扫描文件）
- 扫描根：白名单制（用户内容目录，排除工具链/缓存）
- 输出：按类别 JSONL 中间产物 → MD5 去重 → CSV（utf-8-sig，Excel 友好）
- 字段：全路径/文件名/扩展名/大小/MD5/创建时间/修改时间/行数(文本类)/同MD5副本数
用法：python3 scan_knowledge_files.py <输出目录>
"""
import os, sys, json, hashlib, time, csv, multiprocessing as mp
from datetime import datetime

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "."
HOME = os.path.expanduser("~")
SCAN_ROOTS = [os.path.join(HOME, d) for d in
    ("CODE", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public")]
SCAN_ROOTS.append(os.path.join(HOME, "Library", "Mobile Documents"))
OUT_DIR = os.path.abspath(OUT_DIR)
SCAN_ROOTS = [r for r in SCAN_ROOTS if os.path.exists(r)]
SCAN_ROOTS.append(OUT_DIR)  # 仅用于排除自身

EXCLUDE_DIR_NAMES = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist",
    "build", ".build", "target", ".next", ".nuxt", "vendor", "Pods", "DerivedData",
    "Caches", ".Trash", ".cache", ".npm", ".pnpm-store", "site-packages", ".gradle",
    ".m2", ".cargo", "Photos Library.photoslibrary textiles", "nodomain freesomething"}
EXCLUDE_SUFFIXES = (".map", ".DS_Store", ".pyc", ".class", ".o", ".so", ".dylib", ".a", ".lib")

CATS = {
  "文档": {"pdf","doc","docx","dot","dotx","docm","xls","xlsx","xlsm","xlsb","xlt","xltx",
    "csv","tsv","ppt","pptx","pps","ppsx","pot","pptm","txt","md","markdown","rst","rtf",
    "odt","ods","odp","pages","numbers","key","log","tex","bib","org","xmind","opml","enex",
    "one","ipynb","srt","ass","vtt","eml","msg","mht","mhtml","wps","et","dps","wpd","abw"},
  "代码文本": {"py","go","js","mjs","cjs","ts","tsx","jsx","sh","bash","zsh","sql","c","h",
    "cpp","hpp","cc","java","rs","rb","php","pl","lua","r","swift","kt","scala","m","mm",
    "vue","css","less","scss","html","htm","xml","yaml","yml","json","toml","ini","conf",
    "cfg","properties","bat","ps1","proto","graphql","dockerfile","mk","cmake","gradle",
    "dart","zig","v","ex","erl","hs","clj","fs","jl","tcl","awk","sed","vim","el","lisp"},
  "图片": {"jpg","jpeg","png","gif","bmp","tif","tiff","webp","heic","heif","svg","ico",
    "psd","ai","eps","raw","cr2","cr3","nef","arw","dng","orf","rw2","raf","srw","pef"},
  "视频": {"mp4","mov","avi","mkv","wmv","flv","webm","m4v","mpg","mpeg","3gp","rmvb","rm",
    "vob","asf","mts","m2ts"},
  "音频": {"mp3","wav","flac","aac","m4a","ogg","wma","aiff","aif","opus","amr","mid","midi","ape","tak"},
  "电子书": {"epub","mobi","azw","azw3","djvu","chm","fb2","caj","nh","kdh","pdb","prc"},
  "压缩包": {"zip","rar","7z","tar","gz","tgz","bz2","xz","zst","dmg","iso","cab","jar","war"},
  "收藏": set(),  # 特判：.url/.webloc/书签文件
}
EXT2CAT = {}
for c, exts in CATS.items():
    for e in exts: EXT2CAT[e] = c
TEXT_CATS = {"文档", "代码文本"}

def classify(name):
    low = name.lower()
    if low.endswith((".url", ".webloc")) or low in ("bookmarks", "bookmarks.plist") \
       or "bookmarks" in low and low.endswith(".html"):
        return "收藏"
    e = low.rsplit(".", 1)[-1] if "." in low else ""
    if e in ("url", "webloc"): return "收藏"
    return EXT2CAT.get(e)

def human_size(n):
    for u, d in (("B",1),("KB",1024),("MB",1024**2),("GB",1024**3),("TB",1024**4)):
        if n < d*1024 or u == "TB":
            return f"{n/d:.1f}{u}"

def walk_files():
    """生成 (path, category) 列表"""
    items = []
    exclude_roots = set()
    for r in SCAN_ROOTS:
        if r == OUT_DIR or r.startswith(OUT_DIR + os.sep): continue
        for root, dirs, files in os.walk(r):
            rel = os.path.relpath(root, HOME)
            top = rel.split(os.sep)[0]
            if top == "Library" and not rel.startswith(os.path.join("Library", "Mobile Documents")):
                dirs[:] = []; continue
            dirs[:] = sorted([d for d in dirs if d not in EXCLUDE_DIR_NAMES])
            for f in files:
                if f.endswith(EXCLUDE_SUFFIXES) or f == ".DS_Store": continue
                c = classify(f)
                if c: items.append((os.path.join(root, f), c))
    return items

def process_one(args):
    path, cat = args
    try:
        st = os.stat(path)
        h = hashlib.md5()
        lines = ""
        is_text = cat in TEXT_CATS and st.st_size <= 10*1024*1024
        with open(path, "rb") as fp:
            if is_text:
                nlines = 0
                prev_tail = b""
                while True:
                    blk = fp.read(1024*1024)
                    if not blk: break
                    h.update(blk)
                    nlines += blk.count(b"\n")
                    prev_tail = blk[-1:]
                if prev_tail not in (b"", b"\n"): nlines += 1
                lines = str(nlines)
            else:
                while True:
                    blk = fp.read(1024*1024)
                    if not blk: break
                    h.update(blk)
        return {"path": path, "name": os.path.basename(path),
                "ext": os.path.splitext(path)[1].lower().lstrip("."),
                "cat": cat, "size": st.st_size, "md5": h.hexdigest(),
                "birth": datetime.fromtimestamp(st.st_birthtime).strftime("%Y-%m-%d %H:%M:%S") if hasattr(st,"st_birthtime") else "",
                "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                "lines": lines}
    except (OSError, PermissionError) as e:
        return {"path": path, "name": os.path.basename(path), "ext": "", "cat": cat,
                "size": -1, "md5": f"ERROR:{e.errno}", "birth": "", "mtime": "", "lines": ""}

def main():
    t0 = time.time()
    print(f"[{datetime.now():%H:%M:%S}] 收集文件清单…", flush=True)
    items = walk_files()
    print(f"[{datetime.now():%H:%M:%S}] 候选 {len(items)} 个，开始并行处理(MD5/行数)…", flush=True)
    workdir = os.path.join(OUT_DIR, ".work")
    os.makedirs(workdir, exist_ok=True)
    jsonl = {c: open(os.path.join(workdir, f"{c}.jsonl"), "w", encoding="utf-8") for c in CATS}
    jsonl["收藏"] = open(os.path.join(workdir, "收藏.jsonl"), "w", encoding="utf-8")
    done = err = 0
    with mp.Pool(processes=8) as pool:
        for rec in pool.imap_unordered(process_one, items, chunksize=256):
            done += 1
            if rec["md5"].startswith("ERROR"): err += 1
            else: jsonl[rec["cat"]].write(json.dumps(rec, ensure_ascii=False) + "\n")
            if done % 50000 == 0:
                print(f"[{datetime.now():%H:%M:%S}] 进度 {done}/{len(items)} 错误{err} 用时{time.time()-t0:.0f}s", flush=True)
    for f in jsonl.values(): f.close()
    print(f"[{datetime.now():%H:%M:%S}] 扫描完成：{done} 个（错误 {err}），用时 {time.time()-t0:.0f}s", flush=True)

if __name__ == "__main__":
    main()
