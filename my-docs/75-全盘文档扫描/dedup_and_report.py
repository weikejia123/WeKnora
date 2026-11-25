#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""去重(按MD5) + 生成分类 CSV + 汇总报告"""
import os, sys, json, csv
from collections import defaultdict
from datetime import datetime

OUT_DIR = os.path.abspath(sys.argv[1])
WORK = os.path.join(OUT_DIR, ".work")
def human_size(n):
    for u, d in (("B",1),("KB",1024),("MB",1024**2),("GB",1024**3),("TB",1024**4)):
        if n < d*1024 or u == "TB": return f"{n/d:.1f}{u}"

CATS = ["文档","代码文本","图片","视频","音频","电子书","压缩包","收藏"]
HEADER = ["全路径","文件名","扩展名","类别","大小字节","可读大小","MD5","创建时间","修改时间","行数","同MD5副本数"]
stats = {}
for cat in CATS:
    src = os.path.join(WORK, f"{cat}.jsonl")
    if not os.path.exists(src): continue
    groups = defaultdict(list)
    n_raw = n_err = 0
    with open(src, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line); n_raw += 1
            if r["md5"].startswith("ERROR"): n_err += 1; continue
            groups[r["md5"]].append(r)
    rows = []
    for md5, lst in groups.items():
        lst.sort(key=lambda r: (len(r["path"]), r["path"]))  # 最短路径作代表
        keep = lst[0]
        rows.append([keep["path"], keep["name"], keep["ext"], cat, keep["size"],
                     human_size(keep["size"]), md5, keep["birth"], keep["mtime"],
                     keep["lines"], len(lst)-1])
    rows.sort(key=lambda r: r[0])
    csv_path = os.path.join(OUT_DIR, f"扫描记录-{cat}.csv")
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f); w.writerow(HEADER); w.writerows(rows)
    stats[cat] = dict(raw=n_raw, err=n_err, unique=len(rows),
        raw_size=sum(r[4] for r in rows), dup_pairs=sum(r[10] for r in rows),
        csv=csv_path)
    print(f"{cat}: 原始{n_raw} 去重后{len(rows)} 错误{n_err}")

# 汇总报告
rep = [f"# 全盘知识文件扫描报告", "",
 f"- 扫描时间：{datetime.now():%Y-%m-%d %H:%M:%S}",
 f"- 扫描范围：~/CODE · ~/Desktop · ~/Documents · ~/Downloads · ~/Pictures · ~/Movies · ~/Music · ~/Public · ~/Library/Mobile Documents（iCloud Drive）",
 f"- 排除：.git / node_modules / dist / build / venv / Caches / 各工具链缓存目录（~/.bun ~/go ~/.rustup ~/.nvm ~/.workbuddy OrbStack 等整目录不扫）；.map/.pyc/.o 等产物文件；照片库内部由系统管理不展开",
 f"- 去重口径：**MD5 完全相同视为同一文件**，保留最短全路径作代表，`同MD5副本数` 记录其余副本个数",
 f"- 行数：仅文本类（文档/代码文本）且 ≤10MB 的文件统计",
 "", "## 分类统计", "",
 "| 类别 | 扫描文件数 | MD5去重后 | 完全重复副本对 | 去重后总大小 | CSV |",
 "|---|---:|---:|---:|---:|---|"]
tot_u = tot_r = 0
for cat, s in stats.items():
    tot_r += s["raw"]; tot_u += s["unique"]
    rep.append(f"| {cat} | {s['raw']:,} | {s['unique']:,} | {s['dup_pairs']:,} | {human_size(s['raw_size'])} | {os.path.basename(s['csv'])} |")
rep += ["", f"**合计：扫描 {tot_r:,} → 去重后 {tot_u:,}**", ""]
with open(os.path.join(OUT_DIR, "扫描汇总报告.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(rep))
print("report-done")
