# PP-StructureV3 部署预检与决策待定（南宁 110）

> 日期：2026-09-22 · 目标：在 110 部署 PP-StructureV3 容器，供 WeKnora 解析扫描件 PDF
>
> **状态：已决策，部署进行中**。老魏 2026-09-22 决策：**单独部署一个容器** +
> **释放 Ollama 占卡模型与 `pp-ocr-v6-gpu` 的 GPU 占用** + **独立目录 / 独立 git（本地）**。
>
> ★ **实施记录已迁至 110 上的独立仓库**：`/opt/docker-deploy/pp-structure-v3/`
> （含 `AGENTS.md` 规约、`my-docs/20-设计/`、`my-docs/30-实施/`）。
> 本文档保留**决策依据与预检数据**，作为 WeKnora 侧的接入背景。

---

## 一、预检结果（只读）

| 项 | 现状 | 结论 |
|---|---|---|
| GPU | RTX 3060 12288 MiB，**已用 7034 / 空闲 4877 MiB** | ⚠️ 显存不足 |
| 显存占用 | `python` **2574 MiB**（pp-ocr-v6-gpu 服务）+ `ollama/llama-server` **4300 MiB** | 可腾 |
| 驱动 / Docker | 580.173.02 / **CUDA 13.0** / Docker 29.3.1 | ✓ 新，兼容 |
| 磁盘 | `/` 可用 **366 GB** | ✓ 充足 |
| 本地镜像 | 自建 `pp-ocr-v6-gpu:20260922`（12GB）；另有百度官方 `paddleocr-vl`（13.2GB）、`paddleocr-genai-vllm-server`（18.6GB） | ✓ 有基础 |

### 1.1 三个已确认的技术事实

1. ✓ **不必拉新镜像** —— 现有 `pp-ocr-v6-gpu:20260922` 里已含
   `paddleocr 3.7.0` + **`paddlex 3.7.2`** + `fastapi` + `uvicorn` +
   **`paddlex.inference.pipelines`**（pipeline 能力齐备）。
2. ✗ **但缺 `paddlex[ocr]` extra** —— 实测报错原文：

   ```
   DependencyError: `PP-StructureV3` requires additional dependencies.
   To install them, run `pip install "paddlex[ocr]==<PADDLEX_VERSION>"`
   ```

   ⇒ 需**派生一个镜像**（在现有镜像上补一层 pip 安装）。
3. ⚠️ **显存不足** —— 空闲 4.877 GB，而 PP-StructureV3（裁剪后）估计需 4~6 GB。
   ⇒ **必须先腾显存**（见 §三）。

---

## 二、★ 规约冲突（必须由老魏确认，故暂停）

`/opt/docker-deploy/pp-ocr-v6/AGENTS.md` 是该目录的**最高行为规约**，其第 1 节写明：

> - **唯一 OCR 模型族：PP-OCRv6**……
> - **禁止**引入 PP-OCRv5 及更早代际、**其他 OCR 引擎（Tesseract、EasyOCR 等）或任何 VLM 方案作为识别通路**。
> - 项目核心目标：提供一个 Web 站点，实现 OCR 功能，并支持**同一图片用一种或多种体量识别、
>   横向对比结果质量**（独立对比页面）。

而 **PP-StructureV3 是一条「文档解析产线」**（版面检测 + 表格识别 + OCR + 预处理编排），
与该项目「**单图 OCR + 多体量横向对比**」的定位**不是同一类东西**。

同文件开头亦要求：

> 与本规约冲突的临时指令，需在回复中**显式指出冲突并经用户确认后方可执行**。

⇒ **因此暂停在此，等待确认。**

---

## 三、待决策三件事

### 决策 1：部署位置

| 选项 | 说明 | 我的建议 |
|---|---|---|
| **A. 新建独立目录** `/opt/docker-deploy/pp-structure-v3/` | 独立 compose / 镜像 / 模型缓存 / 文档 | **✅ 建议** |
| B. 放进 `/opt/docker-deploy/pp-ocr-v6/` | 复用其部署骨架 | ❌ 会打破该项目定位与规约 |

**建议 A 的理由**：两者**生命周期与使用方都不同** —— pp-ocr-v6 面向「人做 OCR 与体量对比」，
PP-StructureV3 面向「WeKnora 的文档解析后端」。混放会导致 pp-ocr-v6 的定位模糊、
其「串行 + 429 限流」策略被文档解析任务打扰。

### 决策 2：显存怎么腾（现状空闲 4.877 GB）

| 选项 | 腾出 | 代价 |
|---|---|---|
| A. Ollama 改按需加载（`OLLAMA_KEEP_ALIVE=0` 或更短） | +4.3 GB | 首次调用需重载模型（变慢） |
| B. 停 Ollama | +4.3 GB | 影响所有用 Ollama 的功能 |
| C. 停 `pp-ocr-v6-gpu-api`（36741） | +2.6 GB | 单图 OCR 服务下线（扫描件场景将被 PP-StructureV3 覆盖） |
| D. 先以 CPU 模式跑通链路 | 0 | 慢，仅供验证 |

**我建议 A + C**：Ollama 常驻 4.3 GB 属浪费（按需加载即可）；
而 36741 的「扫描件 PDF」职能本来就会被 PP-StructureV3 覆盖（其单图 OCR / 多档对比仍可保留给人工使用）。

### 决策 3：产出归档位置

- 若选**方案 A（独立目录）** ⇒ 建议独立 git 仓库，实施文档放其 `my-docs/30-实施/`；
- WeKnora 侧只需在 `my-docs/15-docreader定制/` 记录「接入端点与配置」。

---

## 四、技术方案（已设计好，等你点头即可执行）

```
/opt/docker-deploy/pp-structure-v3/
├── Dockerfile              # FROM pp-ocr-v6-gpu:20260922 + pip install paddlex[ocr]==3.7.2
├── compose.yaml            # GPU、独立模型缓存、端口 36742
├── server/main.py          # FastAPI：POST /layout-parsing（**复刻官方服务化契约**）
├── my-scripts/start.sh|stop.sh
└── my-docs/
```

**服务契约**（对齐官方，使 WeKnora **零代码接入**）：

- 端点：`POST /layout-parsing`
- 请求：JSON，`file`（base64 或 URL）+ `fileType`（0=PDF, 1=图像）
- 响应：`result.layoutParsingResults[].markdown.{text, images, isStart, isEnd}`
  —— 与 WeKnora `paddleocr_vl` 引擎读取的字段**完全一致**
- 裁剪：`use_formula_recognition=False`、`use_seal_recognition=False`、
  `use_chart_recognition=False`；保留版面 / OCR / 表格 / 方向分类 / UVDoc 矫正
- ★ **必须设 `max_num_input_imgs: null`** —— 否则官方默认**只处理前 10 页**
  （我们的样本 38 页，会被静默截断）

---

## 五、待老魏确认后执行的动作清单

1. 建目录与骨架 → 2. 写 Dockerfile 并构建 → 3. 写服务与脚本 →
4. 按决策 2 腾显存 → 5. 起容器 → 6. 验证（健康检查 + 一页推理 + 峰值显存）→
7. 配 WeKnora（解析引擎填端点）→ 8. 落实施文档

---

## 六、决策结果与执行进展（2026-09-22）

### 6.1 决策

| 决策项 | 老魏决定 |
|---|---|
| 部署位置 | **单独一个容器** + **独立目录** |
| 显存 | **释放** Ollama 占卡模型与 `pp-ocr-v6-gpu` |
| 归档 | **独立 git（本地）** |

⇒ 与 §二 的规约冲突**就此消解**：PP-StructureV3 **不进** `pp-ocr-v6` 项目目录，
故**不需要修改其 `AGENTS.md`**。

### 6.2 已完成

| 步骤 | 结果 |
|---|---|
| 显存释放 | 停 `pp-ocr-v6-gpu-api`（+2.6GB）→ 卸 Ollama 的 `qwen3-embedding:4b`（+4.3GB）⇒ 空闲 **4877 → 11763 MiB** |
| 目录 | `/opt/docker-deploy/pp-structure-v3/`（软链自 `/mnt/docker-data/docker-deploy/`） |
| 仓库 | `git init` 完成，首次提交 `6dd3439` |
| 骨架 | `AGENTS.md`（规约）/ `Dockerfile` / `compose.yaml` / `server/` / `my-scripts/` / `my-docs/{10,20,30,40}` |
| 服务设计 | `my-docs/20-设计/01-服务设计.md`（契约 + 裁剪决策 + 两处参数冲突）→ 提交 `22cf4a2` |
| 服务代码 | `server/main.py` + 代码外置挂载 → 提交 `64855c7` |
| 镜像 | 构建中（`FROM pp-ocr-v6-gpu:20260922` + `paddlex[ocr]==3.7.2`） |

### 6.3 关键设计结论（供 WeKnora 侧知悉）

1. **WeKnora 侧零代码**：本服务契约复刻 PaddleX 官方 `POST /layout-parsing`，
   响应为 `result.layoutParsingResults[].markdown.{text,images}`
   —— 正是 `paddleocr_vl` 引擎读取的字段。
2. **两处参数语义冲突，服务端为准**（已记入该仓库设计文档）：
   - `useSealRecognition`：WeKnora 发 `true`，服务端关（显存约束）
   - `useDocOrientationClassify` / `useDocUnwarping`：WeKnora 发 `false`，服务端开（扫描件需要）
3. **`markdownIgnoreLabels` 的补偿**：服务端改为按产线 `block_label` 剔除
   页眉/页脚/页码 —— 这是版面检测独有的能力（此前只能靠正则猜）。

### 6.4 待完成

镜像构建 → 探针确认产线输出结构 + 记录峰值显存/单页耗时 → 写服务适配层收尾 →
起容器验证 → 配 WeKnora 端点 → 真实入库验证。
