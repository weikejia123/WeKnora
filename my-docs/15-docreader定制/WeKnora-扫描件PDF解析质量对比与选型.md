# 扫描件 PDF 解析：为什么选 PP-StructureV3

> **结论速览**
>
> | 问题 | 结论 |
> |---|---|
> | 排版为什么不行 | **结构信息在 OCR 阶段就丢了** —— PP-OCRv6 通用产线只给「文本行 + 坐标」，没有区域语义 |
> | 调 OCR 参数能救吗 | **不能，已实测**（提高检测分辨率无改善、耗时翻倍） |
> | 该选什么 | **PP-StructureV3**（★ 该服务**容器已删除**，2026-09-23 起；镜像保留可恢复 —— 见 `PP-StructureV3-接入与运维（南宁110）.md` §七） |
> | 为什么不选别的 | VLM 端到端**慢 16 倍**（14.5 s/页）；MinerU `vlm`/`hybrid` 后端**显存装不下**；`opendataloader` 对扫描件等价于 builtin |
> | 怎么用最稳 | **按库分**：扫描/混合件库走 PP-StructureV3，电子版库走 `anydoc`/`builtin` |

---

## 一、根因：结构信息在 OCR 阶段就丢了

### 1.1 纯 OCR 链路的天花板

```
页面图 → PP-OCRv6（行检测 + 行识别）→ 一堆 (text, bbox) → 几何启发式重组 → markdown
```

PP-OCRv6 的通用 OCR 产线**只做两件事**：检测文本行、识别行内文字。
它**不产出任何区域语义** —— 不知道哪块是标题、哪块是表格、哪块是页眉，也不知道多栏的阅读顺序。

所以只能用 bbox 的**几何特征**去**猜**：

| 目标 | 判据 |
|---|---|
| 段落 | 行距 > 行距中位数 × 1.4；段首缩进 |
| 标题 | 行高比 > 1.15；居中；不以句读结尾 |
| **表格** | **猜不出来**（只有行，没有单元格） |

⇒ **天花板就在这**：密集排版（表格页）会让几何判据失效。
实测：第 6 页 **46 行被切成 39 个段落**（几乎一行一段）。

### 1.2 调 OCR 参数救不了（实测结论）

⚠️ **不要再试这条路** —— 已实测否定。

| 页 | 检测边长 | 行数 | 均分 | 段落块 | 耗时 |
|---|---|---|---|---|---|
| 1（正文） | 960 | 20 | 0.9922 | 5 | 538 ms |
| 1（正文） | 2048 | 20 | 0.9837 | 6 | 1228 ms |
| 6（密集页） | 960 | 46 | 0.9977 | **39** | 780 ms |
| 6（密集页） | 2048 | 46 | 0.9988 | 40 | 956 ms |

⇒ **行数、段落数几乎不变，置信度略降，耗时翻倍。OCR 侧不是瓶颈。**

---

## 二、候选对比与选择

| 路线 | 排版 | 字准 | 速度 | 显存 | 要改什么 |
|---|---|---|---|---|---|
| **★ PP-StructureV3**（已选） | ★★★ | ★★★（内含 PP-OCRv6） | 1.35 s/页 | **≈4.0 GiB** | **零代码** |
| VLM 端到端 | ★★★ | ★★（1b 级会崩） | **14.5 s/页** | ~5 GiB | 纯配置 |
| 纯 OCR + 几何重组 | ★☆ | ★★★ | 0.9 s/页 | 1 GiB | — |
| MinerU（`vlm`/`hybrid` 后端）—— ★ 本行是 **评估时（MinerU v2.x）** 的数据 | ★★★ | ★★★ | — | **9.7~31.6 GB** | 零代码 |
| ★ MinerU **4.0.6**（2026-09-23 实测，见 `MinerU-接入与运维（南宁110）.md`） | ★★★ | ★★★ | 1.58 s/页 | **≈6.9 GiB** | 异步契约，**与现引擎不兼容** |
| `opendataloader` 引擎 | — | — | — | — | 零代码 |

> **附注（2026-09-23）**：MinerU 4.0.6 **自带 Gradio Web UI**（`110:36744`，实测**不占显存**），
> 可上传文件直接肉眼核对解析效果 —— 这给「人工验收」提供了一条不写脚本的路径。
> 见 `MinerU-接入与运维（南宁110）.md` §四。

**被排除的路线及理由**

| 路线 | 排除理由 |
|---|---|
| **MinerU 的 `vlm`/`hybrid` 后端** | 显存 **9.7 / 31.6 GB** → 110 是 **RTX 3060 12 GB**，装不下 |
| **`paddleocr_vl` 引擎接 PaddleOCR-VL 服务** | 需 VL 模型，显存需求 ≥ 7~8 GB ⇒ 余量不足 |
| **`opendataloader` 引擎** | `opendataloader_parser.py:353-363`：文本不足时 *"falling back to builtin scanned renderer"* ⇒ 对扫描件**等价于 builtin**，无版面增益 |
| **纯 OCR + 调参** | §1.2 已实测无效 |

> ⚠️ **引用框架资源数字时必须先确认「哪个后端」** —— MinerU 的
> `pipeline` 后端只要 4~6 GB（`vlm`/`hybrid` 要 9.7~31.6 GB），差 5 倍以上，
> 混用会得出完全相反的结论。

---

## 三、为什么 PP-StructureV3 胜出

1. **协议天然匹配 ⇒ 零代码接入**
   WeKnora 的 `paddleocr_vl` 引擎打的就是 `POST /layout-parsing`，
   读的就是 `result.layoutParsingResults[].markdown.{text,images}`。
2. **输出即所需** —— `parsing_res_list` 直接给 `block_label`（`text`/`doc_title`/
   `paragraph_title`/`table`…）+ `block_content` + **`block_order`（阅读顺序）**：
   结构、文字、顺序一次到位，不用自己用几何去猜。
3. **一个容器解决全部** —— 版面 + OCR + 表格 + UVDoc 预处理都自带，不用逐个加模块。
4. **与「只用 PP-OCRv6」的规约一致** —— 它的通用 OCR 子产线可挂 PP-OCRv6
   （**需显式指定，默认是 v5**，见运维文档 §三.5）。
5. **实测资源可控** —— 峰值 ≈4.0 GiB（裁掉公式/印章/图表后），110 装得下。

**它的价值不在模型（用的是同一批 PaddleOCR 模型），而在「编排与融合已经做好」**：
区域↔文本行归属、阅读顺序排序、单元格↔文本行匹配、多模块调度 —— 自研组合这些全要自己写。

---

## 四、对照数据：VLM 路线实测（为什么没选它）

用 WeKnora **实际使用的提示词** `vlmOCRScannedPDFPrompt`（`image_multimodal.go:44-58`，
原文要求 *"extract all text **and layout structure**"* + *"use **Markdown table syntax**"*）
在 110 的 Ollama 上实测：

| | PP-OCRv6 纯 OCR | VLM `minicpm-o4.5:8b` |
|---|---|---|
| 排版 | 46 行 → **39 个碎片段落** | **markdown 表格 + `<br>` 合并单元格内多行** |
| 数字 | 37 个 | 36 个，**0 幻觉**（少的是页码，prompt 明确要求忽略） |
| 速度 | 0.9 s/页 | **14.5 s/页** |

**另一个模型的对照（说明模型规模的重要性）**：`minicpm-v4.6:1b`（752M）
排版也好（甚至识别出 `<td rowspan="10">`），但**字准崩**：

```
工业**化**发展中心   ← 应为「文化」
**链管**单位         ← 应为「通信管理局」
租金**454**.38       ← 应为 254.38
```

⇒ **1b 级模型不能用于审计类文档。** 选 VLM 路线要付「慢 16 倍」，选小模型要付「字准」。

---

## 五、选型知识：版面检测 ≠ 表格结构识别

> 这是本领域**最常见的误解**，也是选型时最容易搞错的地方。

| | 版面检测（Layout Detection） | 表格结构识别（TSR） |
|---|---|---|
| 输入 | **整页图** | **表格区域图**（由版面检测框出） |
| 输出 | **区域框 + 类别** | **单元格行列结构**（HTML / `cell_bbox`） |
| 回答 | 「这块是表格 / 标题 / 正文」 | 「这表几行几列、哪格跨行」 |
| 代表 | PP-DocLayout-L/M/S | SLANet / SLANet_plus / **SLANeXt** |

### 5.1 版面检测能做到什么程度

**能做到**：区域框 + **23 类语义标签**（document title / paragraph title / text /
page number / abstract / toc / references / footnotes / header / footer / formula /
image / figure caption / **table** / table caption / seal …）、**阅读顺序**、
**剔除页眉页脚页码**。

**做不到**：表格内部行列结构 → 需 **TSR**；单元格内容归属 → 需**单元格检测 + IoU 匹配**；
**段落级细分** → 只到「块」，块内段落仍需几何判据；文字内容 → 需 OCR。

**模型规格**（PaddleOCR / PaddleX）：

| 模型 | 骨干 | mAP(0.5) | GPU(ms) 常规/高性能 | 大小 |
|---|---|---|---|---|
| PP-DocLayout-L | RT-DETR-L | **90.4** | 33.59 / **10.39** | 123.8 MB |
| PP-DocLayout-M | PicoDet-L | 75.2 | 13.03 / 4.72 | 22.6 MB |
| PP-DocLayout-S | PicoDet-S | 70.9 | 11.54 / **3.86** | **4.8 MB** |
| PP-DocLayout_plus-L | RT-DETR-L | 83.2（20 类） | 17.23 | 126 MB |
| **PicoDet_layout_1x_table** | PicoDet-1x | **97.5** | 8.02 / 3.09 | **7.4 MB** |

### 5.2 「文字 + 表格」场景的完整组合（PP-TableMagic）

| 环节 | 模型 | 大小 | 指标 |
|---|---|---|---|
| 版面检测 | PP-DocLayout-L | 123.8 MB | mAP 90.4 |
| 表格分类 | PP-LCNet_x1_0_table_cls | 6.6 MB | Top1 94.2% |
| **表格结构识别** | **SLANeXt_wired** | 351 MB | 输出 HTML |
| 表格单元格检测 | RT-DETR-L_wired_table_cell_det | 124 MB | mAP 82.7 |
| **文字识别** | **PP-OCRv6** | — | 已有 ✓ |
| 预处理 | PP-LCNet_x1_0_doc_ori / UVDoc | 7 / 30.3 MB | 方向 / 弯曲矫正 |

**★ 关键点**：官方已实现 **`use_ocr_results_with_table_cells`**（默认开），
用 **L1 距离 + IoU** 把 OCR 文本行归属到单元格 —— 这是自研方案里最难的一环，**不必自己造**。

**两点提醒**：
- `use_table_orientation_classify`（默认开）会先校正 90/180/270 度旋转的表格；
- **69.65% 是「结构识别」指标**，不等于最终表格可用率；**有线表明显优于无线表**
  （公文表格多为有线 ⇒ 选 `SLANeXt_wired`）。

---

## 六、成熟框架的先例（2026 年调研）

### 6.1 行业标准是「三层」，本项目走的正是这条路

```
① 嵌入文本层（原生 PDF 的 glyph 位置）
② 版面检测  —— 目标检测器标注 region + 阅读顺序
③ 识别层    —— OCR（扫描页）/ 公式识别 / 表格结构识别
```

### 6.2 2026 年的一个反转：主流在「合并」，模块化解耦成了低资源选项

多数头部工具已把 ②③ 层**合并进单个 VLM**：
Marker 2 → Surya 2（650M）、MinerU → `vlm`/`hybrid`、Docling → `--pipeline vlm`。

> 行业原文：*"layers two and three have collapsed into a single vision-language model in
> most of the leading tools"*；但同文亦指出 *"the modular stack … is now the **CPU fallback**
> rather than the default"*。

⇒ 模块化解耦（本项目的路线）在 2026 年的定位是「**低资源 / 稳定 / 可 CPU**」的
生产选择 —— **精度低于 VLM 端到端（85 vs 95），但资源低一个量级**。

### 6.3 关键差异：成熟方案用「专用版面模型」，不是通用 LLM

| | 专用版面检测模型（YOLO / RT-DETR / rf-detr） | 通用 LLM 判结构 |
|---|---|---|
| 速度 | 单页**几十毫秒** | 估 1~3 s |
| 体积 | **几十 MB** | 数 GB |
| **幻觉** | **结构性不存在**（只输出「类别 + 框」，本就不产出文字） | 需靠契约约束 |

⇒ **判据：能用专用版面模型，就不要用通用 LLM。**

### 6.4 其他可选实现

| 框架 | 结构侧做法 | 备注 |
|---|---|---|
| **Docling**（IBM） | RT-DETR + TableFormer | 许可宽松、**CPU 可行**、输出 typed document |
| **Surya** | **以版面检测为主任务，OCR 为其下游消费者** | 解耦最彻底 |
| **Marker 2（fast）** | rf-detr 版面检测 | **CPU viable** |
| **PaddleOCR 生态** | PP-Structure / TableStructure / UniMERNet | **可单独调用**，与现用 PP-OCRv6 **同源** ← 本项目采用 |

---

## 七、本项目结论

**按文档性质分流，按库分开建**（引擎粒度只到「按文件类型」，见运维文档 §三.8）：

| 文档性质 | 引擎 | 理由 |
|---|---|---|
| 扫描件 / 混合件 | **`paddleocr_vl`（本服务）** | 版面 + 表格结构；文字层页走 OCR 实测**零损失** |
| 纯电子版 | `anydoc` / `builtin` | 抽文本层更快；且本服务**不判扫描件**（会白慢一轮） |

> 「表格密集 vs 纯文字」的分流也适用同一办法。
