# MinerU 4.0.6 接入与运维（南宁 110）

> ★★ **当前状态：服务已跑通（含 Web UI），接入 WeKnora 的能力已由官方原生提供**
> —— 官方 `e22a8367`（2026-09-25 第 7 轮同步）让 `mineru` 引擎按 `GET /v1/health` **自动选协议**：
> 4.0+ 走 V1、≤3.x 走 `/file_parse`。**不需要自研引擎，也不需要 110 侧适配器**（详见 §八 的订正）。
> 与此同时 **PP-StructureV3 的容器已删除**（见同目录 `PP-StructureV3-接入与运维（南宁110）.md` §七）
> ⇒ **WeKnora 的 `paddleocr_vl` 引擎目前不可用**（正式库不受影响，它们用 `anydoc`）。
>
> **一句话**：同机新部署的**通用文档解析服务**，`110:36743`。契约是**异步 job 式 `/v1/*`**，
> 与 `paddleocr_vl` 引擎期望的 PPSV3 同步 `/layout-parsing` **不兼容**，
> 但**官方的 `mineru` 引擎已支持它**。
>
> 本文档管 **WeKnora 侧怎么看它、能不能用、要注意什么**。
> 服务本身的实现与运维记录在 **110 上的独立仓库**（见 §七）。

---

## 一、现状

| 项 | 值 |
|---|---|
| 服务地址 | `http://10.168.1.110:36743` |
| 健康检查 | `GET /v1/health` ⇒ `status / version / features` |
| **Web UI** | **`http://10.168.1.110:36744`**（Gradio，**不占显存**，见 §四） |
| 容器 / 镜像 | `mineru-api` / `mineru:4.0.6`（compose project `mineru`） |
| 版本 | `4.0.6` |
| 二开分支 | `wkj-dev`（基点 = upstream master `48a92548`） |
| 能力 | 版面 + 表格（HTML `<table>` 含 `rowspan`）+ 公式（LaTeX）+ OCR，**VLM 驱动** |
| 性能 | **≈1.58 s/页**（38 页扫描件整份 **60 s**） |
| 接口形态 | **异步**：建 upload → 传字节 → 提交 job → 轮询 → 下载产物 |
| 并发 | vLLM 异步调度（与 PPSV3 的串行排队不同） |
| WeKnora 侧配合改动 | **无**（尚未接入） |
| **本机定位** | ⭐ **110 上唯一的 OCR 服务**（2026-09-23 用户决策）。同机 PP-StructureV3、PP-OCRv6（CPU/GPU）、PaddleOCR-VL 的**容器已全部删除、镜像保留**；110 的常驻 AI 组合 = **本服务 + Ollama 的 embedding 模型** |

**实测档 = `tier=standard`**（★ 也是**服务默认档**，即不传 tier 就走这档，见 §六-2；用 PPSV3 同批样本测）

| 样本 | 结果 |
|---|---|
| `p6_table.jpg`（表格页） | HTML `<table>`，`rowspan="12"` 正确 |
| `p1_text.jpg`（文字页） | 段落完整，公式转 `$25.63\%$` |
| `audit_3p.pdf`（3 页） | 正文逐字正确；耗时 7 s（热态） |
| `full.pdf`（38 页） | 107 KB markdown；耗时 60 s |

**显存（12 GB 卡，实测；配置 = `--tier standard` + `util=0.4` + `处理窗口=15`）**

| 场景 | 占用 |
|---|---|
| 114 页文档解析中峰值（MinerU 单侧，无 embedding） | **6644 MiB** |
| MinerU 稳定态（vLLM 冷启涨到位后） | **7358 MiB = 7.19 GB** |
| 容器内存峰值（114 页） | **7.83 GiB** |

拆分明细（稳定态）：`VLLM::EngineCore` **5532 MiB** + API 主进程 `python3` **1826 MiB**。

> ⚠️ **口径**：解析中会采到 `EngineCore` 只有 4660 MiB 的**冷启读数**，稳定态是 **5532 MiB**
> （vLLM 的 CUDA graph 池按实际用到的 batch size 逐个 materialize）。**算预算取稳定态。**

> ⚠️ **`GET /v1/health` 通过 ≠ 可解析** —— VLM 引擎**懒加载**，首次解析才起 vLLM（约 30 s）。
> 验收必须走真实解析，不能只看 health。

### ★ 同机共卡：与 Ollama `qwen3-embedding:4b` 共存（实测 2026-09-23）

用户规划：110 的常驻服务 = **MinerU + Ollama 的 qwen embedding**（Ollama `11434`，
`KEEP_ALIVE=1h`）。两者能否同时用 —— 已实测：

| 场景 | 显存 used 峰值 | 余量 |
|---|---|---|
| MinerU 单独解析 114 页（窗口 15，VLM 档） | 6644 MiB | 5267 MiB |
| embedding 驻留（无解析） | 9587 MiB | 2324 MiB |
| **两者同时**（embedding 驻留 + 114 页解析 + 周期性并发 embedding 请求） | **11821 MiB** | **90 MiB** ⚠️ |

> ⚠️ **此表是「MinerU 含 VLM（即 vLLM 在位）」场景，也是当前实际**。峰值构成：
> `VLLM::EngineCore` 5532 + `python3`（小模型）1826 + Ollama `llama-server` 4300 + 基础 138。
> 旧配置（util 0.5）为 11861 MiB / 余 50 MiB ⇒ **util 从 0.5 收到 0.4 只换回 40 MiB**，
> 因为瓶颈是**双方各自的权重**（且两边预算互相看不见），不是 KV cache。

- embedding 侧：`POST /api/embed`，**2560** 维；占 **4108 MiB**；冷加载 4.6 s、热态 0.15~0.31 s
- 同时运行期间：解析产物 **106995 字符**（与单独跑一致）、embedding **8/8 返回 200**、`dmesg` 无 OOM
- ❌ 已实测排除：调小 embedding `num_ctx` **不省显存**（4096 vs 默认同为 4108 MiB）

⇒ **结论：可以同时使用，但余量很薄（90 MiB）**，属"可用但无安全边际"。

- ✅ **已实施**：下调 MinerU `--gpu-memory-utilization` 到 **0.4**（见 §三）。⚠️ 只换回 40 MiB。
- ⚠️ **12 GB 卡的天花板**：可用 11911 MiB（`used+free`；卡报 12288 含 377 驱动保留）；
  MinerU(VLM) 最小可行 **7.19 GB** + embedding **4.30 GB** = **11.49 GB ⇒ 理论余量 ≈140 MiB**。
  ⇒ **能放下，但要真余量只能牺牲 VLM**（走 `basic` 档 ⇒ MinerU ≈2.3 GB、余 ≈5 GB）。
- ★★ **验收口径（2026-09-23 定）：`standard` + embedding 驻留「不 OOM 即可」**，不追安全边际。
  已按此口径做边界压测（4 类输入 + 并发）**全部通过**：vLLM OOM 0 / `dmesg` OOM 0 / `Xid` 0。
  边界数据（与 embedding 4300 MiB 驻留同时）：114 页扫描件 **11821 MiB / free 90**；
  38 页 10707 / 1204；满 15 页窗口·表格密集 10187 / 1724；**并发 2×38 页 11223 / 688**。
  ★ 两点反直觉：**「表格密集」≠「贵」**（有原生文字层的密集表格比纯图片扫描件便宜约 1.6 GB）；
  **并发不叠加显存但也不叠加吞吐**（131 s ≈ 2×65 s，实为串行）。
  ⚠️ 接入方若在 110 上跑向量化：**请按"刚好塞得下"来安排**，不要假设有调度余量。
- 仍可用但未实施：① 调短 Ollama `KEEP_ALIVE`（当前 1h，用完即卸可彻底错峰）；
  ② 换更小的 embedding 模型。

> ⚠️ **与 WeKnora 的关系**：当前 **111 侧 WeKnora 的 embedding 不指向本服务** ——
> 其 `OLLAMA_BASE_URL` 为 `http://host.docker.internal:11434`（**111 本机** Ollama），
> `config.yaml` 中亦无 embedding 模型配置。故本共存关系与 WeKnora 现行链路**无耦合**；
> 若将来把 WeKnora 的向量化改指 110，需重新评估并发（那时"解析 → 向量化"会串在同一条链路，
> 并发概率显著高于本次测试的独立调用）。

---

## 二、★ 与 PP-StructureV3 的同口径对比

用 PPSV3 自己那批样本（`pp-structure-v3/samples/`）实测，避免跨样本失真：

| 指标 | PP-StructureV3 `36742` | MinerU `36743` | 差 |
|---|---|---|---|
| 38 页扫描件整份 | **51.4 s**（1.35 s/页） | **60 s**（1.58 s/页） | 慢 **17%** |
| 显存 常态 | **4.2 GiB** | **6.9 GiB** | **多 2.7 GiB** |
| 显存 峰值 | 4.0 GiB | **8.7 GiB** | **多 4.7 GiB** |
| 镜像 **独占**磁盘 | **4.71 GB** | **15.6 GB** | **多 10.9 GB（3.3×）** |
| 接口形态 | 同步 `POST /layout-parsing` | 异步 job `/v1/*` | **不兼容** |
| 页码剔除 | ✅ | 需实测 | — |

> 「镜像独占磁盘」口径 = `docker system df -v` 的 **UNIQUE SIZE**（该镜像独占字节），
> 不是 `docker images` 的显示大小（后者含共享层，MinerU 显示 39.9 GB 但独占 15.6 GB）。

### 结论：「新版显存/磁盘小多了」在同机替换的语境下**不成立**

MinerU 相对 PPSV3 **三项都更大**（慢 17%、显存多 2.7 GiB、磁盘多 3.3 倍）。

**但这条说法在 MinerU 纵向对比下成立** —— 官方 `docs/zh/reference/changelog.md`：

> 增加显存回收逻辑及其他显存优化措施，大幅降低显存使用需求。开启除表格加速外的全部加速功能(layout/公式/OCR)的显存需求**从 16GB 降至 8GB**，开启全部加速功能的显存需求**从 24GB 降至 10GB**
>
> 极致能效，性能 SOTA: 以 **1.2B** 的轻量化规模，实现了超越百亿乃至千亿级模型的 SOTA 性能

⇒ 即：**「小多了」是相对 MinerU 自己的老版本**（曾是 16–24 GB 门槛），
**不是**相对 PPSV3 这个专用轻量服务。

差异的根因：PPSV3 是**专用 Paddle 镜像**（12.3 GB）；
MinerU 建在**通用 vLLM 镜像**上（基底单独 32.9 GB），含完整 CUDA / torch 栈 ——
换来的是通用性（任意 HF 模型、异步调度、多后端切换），代价是体积。

---

## 三、★ 显存由 MinerU 自己接管 —— `0.5` 是「预算比例」，不是「占用比例」

vLLM 默认 `gpu_memory_utilization=0.9`（12 GB 卡会先占 10.8 GB），**MinerU 不用它**。

上游源码 `mineru/model/vlm/engine_utils.py` 的 `set_default_gpu_memory_utilization()`：

```python
def set_default_gpu_memory_utilization(backend="vllm") -> float:
    gpu_memory = get_vram(device)                       # ← 卡的「总」显存
    if gpu_memory > 8:
        min_memory = 6                                  # >8GB 统一按 6GB 预算
        return max(round(min_memory / gpu_memory, 2), 0.1)
```

**「0.5」是什么**：MinerU 的策略是「不管卡多大，vLLM 只给 **6 GB** 预算」，
`0.5` 只是这条策略在 12 GB 卡上**除出来的比值**（`6 / 12`）。卡越大比值越小
（24 GB ⇒ 0.25），小到 **0.1** 为止。⇒ 它与「卡上还有谁在跑」**无关**，是无条件的 6 GB；
**更不表示「MinerU 只用一半显存」**。

**它管什么**：只决定 vLLM 切多少给 **KV cache**（＝**并发容量**），不决定单次解析的成败。

2026-09-23 vLLM 启动日志（实测，可复现）：

```
--gpu-memory-utilization=0.5000 is equivalent to --gpu-memory-utilization=0.4842
        without CUDA graph memory profiling     ← v0.21 默认开 CUDA graph profiling，名义值要打折
Available KV cache memory: 2.15 GiB             ← 6 GB 预算里分给 KV cache 的只有 2.15 GiB
GPU KV cache size: 187,568 tokens
```

⇒ 预算 6144 MiB 里：**KV cache 2.15 GiB + 权重约 2.16 GiB + 激活/CUDA graph/非 torch≈1.6 GiB**。

### ★ 本机已收窄到 `0.4`（实测 2026-09-23，含下限）

上游该值是**硬编码 6GB 预算**，api-server CLI 与 `VlmConfig` **均无入口**
⇒ 本机给 `engine_utils.py` 加了 **`MINERU_VLLM_GPU_MEMORY_UTILIZATION` 环境变量覆盖口**
（14 行；未设即完全走上游原逻辑）。compose 现设 **`0.4`**。

| util | 预算 | vLLM 自报 `Available KV cache` | `GPU KV cache size` | 8192-token 并发 | 结果 |
|---|---|---|---|---|---|
| **0.3** | 3686 MiB | **−0.18 GiB** | — | — | ⛔ `No available memory for the cache blocks`，**引擎起不来** |
| **0.4**（在用） | 4915 MiB | 0.98 GiB | **85,936 tokens** | **10.49×** | ✅ |
| 0.5（上游默认） | 6144 MiB | 2.15 GiB | 187,568 tokens | 22.90× | — |

- **下限 ≈ 0.32** = 固定开销 ÷ 卡总显存（实测固定开销 ≈ **3.7~3.9 GB**：权重 bf16 2.15 GiB +
  激活/CUDA graph/非 torch ≈1.6 GiB，**与 util 无关**）。
- **失败形式可预期**：util 过低是**启动期**报错，不是解析时 OOM ⇒ 改动是否安全立刻可见。
  但若只是"偏小"，解析会退化为**抢占重算**——**变慢但不报错**，所以改小后要跑一次真实解析复验。
- vLLM 原文：`--gpu-memory-utilization=0.4000 is equivalent to 0.3842 without CUDA graph
  memory profiling` ⇒ v0.21 默认开 CUDA graph profiling，名义值要打折，算下限别漏。
- ★ **85,936 tokens 够用**：util 0.4 与 0.5 的解析耗时**无系统性差异**（±12% 噪声内）
  ⇒ **187,568 tokens 属明显过配**，KV cache 不是瓶颈。

**并发上限 = `min(KV cache 容量, MinerU 自限 batch_size)`**。`set_default_batch_size()`
（同文件）按显存档位取 `≥16 GB → 8`、`≥8 GB → 4` ⇒ 本机为 **4**。

⚠️ **共卡陷阱**：`get_vram()` 取的是**整卡总显存**、**不减去**同机 Ollama 已占的 4300 MiB
⇒ 两个进程**各算各的预算**。共存余量只剩 90 MiB，根因就在这里。

### ★★ 显存峰值不随页数增长：处理窗口（**"500 页 PDF 会不会炸"的答案**）

`MINERU_PROCESSING_WINDOW_SIZE`（`backend/analysis/pdf/window.py`，**官方默认 64 页**；
**本机设为 15**）：PDF 被切成窗口**串行**处理，窗口内跑完就关闭图像、进下一窗。

⇒ 峰值 = **`min(总页数, 窗口)` × 窗口内并发**，**与总页数无关**
⇒ **500 页 PDF = ⌈500/窗口⌉ 个窗口串行，峰值与一份同复杂度的窗口大小文档相同**。

窗口 A/B 实测（同一份 114 页文档、同 util=0.4）：

| | 窗口 64 | 窗口 15（在用） |
|---|---|---|
| 整卡 used 峰值 | 7876 MiB | **6644 MiB**（−15.6%） |
| 容器内存峰值 | 10.62 GiB | **7.83 GiB**（−26%） |
| 耗时 | 212 s | 189 s |
| 产物字节 | 320989 | 320989（**一致**）|

⇒ **对下游的影响**：窗口变小**不影响产物**；吞吐本例反而更快（内存回收更早）。
若将来为提高吞吐而调大窗口，**必须先核显存**。详见 110 服务仓
`my-docs/30-测试报告/05-显存预算上限与窗口机制（7.5G目标验证）.md`。

---

## 四、Web UI（Gradio）—— 唯一能肉眼核对解析效果的入口

服务**自带一套 Gradio 界面**（官方 `docker/compose.yaml` 的 `webui` profile），已启用：

```
http://10.168.1.110:36744
```

| 项 | 值 |
|---|---|
| 容器 | `mineru-webui`（宿主 **36744** → 容器 7860；`0.0.0.0`，局域网可达） |
| 实现 | Gradio **6.28.0**（78 组件 / 51 交互依赖） |
| **显存** | **0** —— 它是 api 服务的**纯 HTTP 客户端**，容器**未挂 GPU 设备** |
| 能做什么 | 上传 PDF / 图片 → 选 `tier` → 看 markdown 与结构化结果、页面预览；产物落 110 的 `mineru/output/webui/` |
| 启停 | 110 的 `mineru/` 仓库下 `./my-scripts/start-ui.sh` / `stop-ui.sh` |

**用途**：这是目前**唯一能肉眼核对解析质量**的入口 —— 拿同一份扫描件分别过 MinerU 与 PPSV3，
在界面上直接看表格有没有散、公式有没有崩，不必写脚本比对 markdown。

### ⚠️ 坑：官方默认配置在这张卡上会 OOM

官方 webui **默认自己起一个 API 后端**（源码 `mineru/kit/gradio/app.py:1068`：
未传 `--api-url` 时执行 `ManagedLocalApiServer(...).start()`）
⇒ 单卡上会**再拉起一份 vLLM 引擎**（≈6 GiB），与 api 的 6.1 GiB 合计 ≈13.8 GiB > 12 GiB。

⇒ 我们的编排显式传了 `--api-url http://mineru-api:8000` 复用已有 api 服务，
并**不给它 GPU 设备**（显存增量实测为 **0**）。改这个参数前务必核对显存。

> 运维手感上的第二个坑：webui 在 `profiles: ["webui"]` 下，
> 而 `docker compose down` **只作用于当前激活 profile 的服务** ⇒ 不带 profile 的 `down`
> 会留下「api 已删、UI 仍在跑」的**半死状态**（页面能开、一提交就报错）。
> 110 的 `my-scripts/stop.sh` 已修（改为带 `--profile webui`）。

> 冷启动：整机重启后首次解析含引擎加载，约 **70 s**；热态 3 页文档 3~7 s。

---

## 五、★ 接入 WeKnora：走官方 `mineru` 引擎（**已解决**，见 §八）

**结论：用官方的 `mineru` 引擎，不要走 `paddleocr_vl`。**

`paddleocr_vl` 引擎读的是 PPSV3 契约（`result.layoutParsingResults[].markdown.text`），
与 MinerU 的异步 job 契约不兼容 ⇒ **不能直接改端点切过去**（探针还会假阳性，见下）。

而官方的 `mineru` 引擎**已原生支持 MinerU 4.0 的 V1 契约**（2026-09-25 第 7 轮同步，`e22a8367`）：

| 方案 | 状态 |
|---|---|
| **官方 `mineru` 引擎**（推荐，即现状） | ✅ **可用** —— 探测式自动选协议，无需改代码、无需适配器。填法见 `my-docs/16-解析引擎扩展/` |
| 110 加契约适配层 | ❌ 不需要（官方已能直连 V1） |
| 自研 `mineru_v4` 引擎 | ❌ 不需要（官方改的就是同一个引擎） |
| 直接改端点走 `paddleocr_vl` | ❌ **错** —— 探针假阳性 + 图片静默丢弃（见下两条） |

**两条仍然有效的前提事实**（只服务于"不要走 `paddleocr_vl`"这个结论）：

1. **`paddleocr_vl` 引擎的探针会假阳性**（见 PPSV3 文档 §三.2）——
   它以「状态码 < 500」判可用，MinerU 只暴露 `/v1/*` ⇒ 若把端点直接指过去，
   探针会拿到 404/405 却判「可用」。
2. **图片会被静默丢弃**（PPSV3 文档 §三.9）—— MinerU 产物同样是 markdown，
   走 `paddleocr_vl` 会丢插图。

---

## 六、注意事项与坑

**1. 服务形态是异步 job，不是"发一个 POST 就回结果"**

下游若按同步语义调用会拿到 `job_id` 而非解析结果。完整链路 5 步（见 110 侧文档 §2）。

**2. ★★ `tier` 既是能力分级、也决定「用不用 VLM（起不起 vLLM）」**

MinerU 4.x 是「一套 **hybrid** 框架 + 四档 effort」。先分清三层：

| 层 | 组件 | 模型（本机） | 运行时 | 占 GPU |
|---|---|---|---|---|
| OCR（文字识别） | **PP-OCRv6** | `ch_PP-OCRv6_tiny_det` + `ch_PP-OCRv6_small_rec`（印章仍 PP-OCRv4） | onnxruntime | ❌ |
| 版面 / 表格 / 公式 | hybrid 小模型 | PP-DocLayoutV2 + PP-LCNet + UNet + 公式识别 | torch | 少量 |
| **高质解析（VLM）** | MinerU2.5 | `MinerU2.5-Pro-2605-1.2B` | **vLLM** | **≈6 GiB** |

依据 `mineru/model/registry.py`（OCR 模型清单）+ `mineru/model/runtime/hybrid.py`
（`HybridLocalModelContext`：layout / ocr / mfr / table）。
⇒ **不论哪一档，OCR 都是 PP-OCRv6**（注册表不分档）。
⚠️ 老版本的 `pipeline` 后端在 4.x 已改名 **hybrid** ⇒ 「用管线」在 4.x 对应 **`basic` 档**。

`mineru/parser/tier.py` 的 `_EFFORT_BY_TIER` 注释即「映射为对应的 **Hybrid** effort」；
但 `GET /v1/tiers` 显示**每档绑定的模型不同**：`flash`→`flash`、`basic`→`hybrid-basic`、
`standard` / `advanced`→`MinerU2.5-Pro-2605-1.2B`（VLM）。

★ **只有 standard 档需要 vLLM** —— `required_modules_for_tier()` 里
`if tier == "standard": modules.extend(VLM_REQUIRED_MODULES[...])`；
`flash` / `basic` **不加载 vLLM 引擎**。

⚠️★ **但默认档 = `standard`**（`parser/api_server.py` 的 `_DEFAULT_API_SERVER_TIER`，
Web UI 同为 `standard`）⇒ **不传 tier 就拉起 vLLM，且加载后不自动卸载**
⇒ 这才是 110 上那 ≈6 GiB 占用的**真正来源**，**不是** MinerU 的固有开销。

⇒ **对应到接入方案**：只要 PP-OCRv6 管线就传 `tier=basic`（省 ≈5 GiB）；要 VLM 质量传 `tier=standard`
（**当前 110 四档全开**，见下条）。

### ★★ 当前 110 的实际配置（2026-09-23）—— 接入方必须知道

**四档全部可用**（compose 的 `command` 为 `--tier standard`）：
`flash` / `basic` / `standard` / `advanced` ⇒ **接入方按需传 `tier`**；不传即 `standard`。
显存由另两个旋钮收窄（⭐ 用户目标：**保留高级解析能力且 MinerU ≤ 7.5 GB**）：

| 旋钮 | 值 | 作用 |
|---|---|---|
| `--tier` | **`standard`** | 保留 VLM 档（`basic` 的代价见下） |
| `MINERU_VLLM_GPU_MEMORY_UTILIZATION` | **`0.4`** | vLLM 预算 6GB→4.8GB，下限 ≈0.32（见 §三） |
| `MINERU_PROCESSING_WINDOW_SIZE` | **`15`** | 峰值不随页数增长（见 §三 末） |

小模型用 `torch` ⇒ 版面 / 表格 / 公式 **以及 PP-OCRv6** 都在 GPU 上算
（`model/runtime/hybrid.py` 里 onnx 路线是「强制 CPU」；torch 路线的 OCR 走
`model/ocr/pytorch_paddle.py`，不依赖 onnxruntime）。

实测（114 页）：**整卡峰值 6644 MiB、容器内存 7.83 GiB、189 s**；MinerU 稳定态 **7.19 GB**。
⚠️ 但**与同机 embedding 共存时整卡余量只有 90 MiB**（见 §一 共存表）—— 若同时在 110 上跑
向量化，需知道这条链路是"刚好塞得下"而非"有调度余量"。

⚠️ **若要省显存可退回 `basic` 档**（把 `--tier` 改成 `basic` ⇒ vLLM 永不加载，MinerU ≈2.3 GB）：
代价是**表格序号会漏识别**、**不还原中英数之间的空格**；正文与关键数字一致（仅 1 份样本验证）。

⇒ **若下游需要表格的「结构化语义」**（合并单元格 rowspan、表头与数据关联），
**传 `tier=standard` 即可 —— 当前配置已包含 VLM 档**。
官方四档：`flash` 极速 / `basic` 基础 / `standard` 标准 / `advanced` 高级，
**VLM 只在 `standard`(high) / `advanced`(xhigh) 加载**（`pipeline.py`：
`if effort in {"high","xhigh"}: get_vlm_predictor(...)`）。
能力对照见 110 服务仓 `my-docs/10-现状与运维/01-服务运行现状.md` 的「关掉 vLLM 后放弃了什么」表。

**3. 显存要按峰值算，且口径取「稳定态」**

当前配置（util 0.4 + 窗口 15，VLM 档）：114 页解析峰值 **6644 MiB**；
MinerU 稳定态 **7358 MiB = 7.19 GB**。
⚠️ 解析中会采到 `VLLM::EngineCore` 只有 4660 MiB 的**冷启读数**，稳定态是 **5532 MiB**
（vLLM 的 CUDA graph 池按实际用到的 batch size 逐个 materialize）⇒ **算预算必须取稳定态**。
⚠️ 峰值增量**不是** KV cache：vLLM 的 KV cache 在启动期一次预分配、运行期不增长。

★★ **那增量到底在哪（2026-09-23 按进程实测）**：`VLLM::EngineCore` **有固定上限、
不随页数增长**（KV cache 启动期预分配）；增量**全在 API 主进程 `python3`**
（484 → **1484~2160** MiB）—— 是 `MINERU_MODEL_SMALL_BACKEND=torch` 的
**版面 / 表格 / 公式小模型在 GPU 上跑**的开销。

⇒ **三条可操作结论**：
- **页数维度**：调 `MINERU_PROCESSING_WINDOW_SIZE`（见 §三 末）——**最有效的显存杠杆**
- 调 `--vlm-max-concurrency` 对峰值显存**无效**（KV cache 启动期一次预分配）
- 要把它**挪到内存**：改 **`MINERU_MODEL_SMALL_BACKEND=onnx`** —— 本容器
  `onnxruntime.get_available_providers()` 只有 `[Azure, CPU]`（**无 CUDA**）⇒ 小模型转 CPU
  （代价大：38 页 18 s → 75 s；**只在必须共卡时才划算**，当前不用）。
  ★ **已实测（2026-09-23，详见 110 服务仓 `my-docs/30-测试报告/`）**：
  `python3` 显存**归零**、MinerU 侧峰值 **7592 → 6392 MiB（6.24 GB，达成 ≤7G ✅）**、
  38 页产物 **106995 字节逐字节一致**；代价 **38 页 18 s → 75 s（×4.2）**
  （单页无变化 —— CPU 小模型是**逐页**开销）。
  ⚠️ 前置：onnx 小模型是**独立仓库**（819 MB），镜像未烘焙，需下载 + 挂载；
  **当前 110 服务即运行在 onnx 试验态（待定去留）**。
  ⚠️ PP-OCRv6 本来就走 onnxruntime/CPU，不受此开关影响。

⚠️ **口径（易算错）**：`nvidia-smi` 的 `memory.total` 报 12288 MiB，但 `used + free` 实测只
**11911 MiB**（差 377 为驱动保留）⇒ **算余量要用 `used + free`**，别用 total 减。

**4. 与 PPSV3 无法共存（单卡 12 GB）**

两者常态合计 11.1 GiB、峰值可到 12.9 GiB ⇒ **超卡**。
要同时跑必须先下调 MinerU 的 `--gpu-memory-utilization`。

---

## 七、权威记录在哪

| 要看什么 | 去哪 |
|---|---|
| 服务实现 / 设计 / 运维与坑（**权威**） | `110:/mnt/docker-data/docker-deploy/mineru/` → `my-docs/` |
| 同机另一解析服务 PP-StructureV3（**容器已删**，镜像保留） | `PP-StructureV3-接入与运维（南宁110）.md`（本目录） |
| 为什么当初选 PPSV3 | `WeKnora-扫描件PDF解析质量对比与选型.md` |
| 解析引擎的通用机制 | `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md` |

> 服务是**独立 git 仓库**（分支 `wkj-dev`，remote `upstream` 带 `gh-proxy.com` 前缀）。
> ⚠️ `/mnt/docker-data/docker-deploy/mineru/` 的父目录属 `root`，新建项目需
> `sudo mkdir` + `sudo chown wkj:wkj`。

---

## 八、★ 接入 WeKnora：失败定位（2026-09-23）→ **官方原生解决（2026-09-25）**

> ★★ **订正（2026-09-25）**：本章 §8.4「上游有没有解？**没有**」与 §8.6「可选方案与代价」
> **已被官方推翻**。官方 `e22a8367`（第 7 轮同步）原生实现了 MinerU 4.0 V1 支持
> ⇒ **§8.6 的 A/B/C/D 四个方案全部不再需要**；
> 配置方式见 `my-docs/16-解析引擎扩展/WeKnora-新增MinerU-4引擎方案.md`（已改写为结案说明）。
> **§8.1–§8.3、§8.7–§8.9 作为「问题定位过程与证据链」仍然有效**（它们解释的是**当时**为什么跑不通）。

用户已在 WeKnora 把 PDF 解析引擎设为 `mineru`、`mineru_endpoint=http://10.168.1.110:36743`，
但上传 PDF 后报「**读取文档失败**」。已定位到根因，证据链如下。

### 8.1 证据链（三步闭合）

| # | 证据 | 位置 |
|---|---|---|
| 1 | 引擎确实被选中并调用：`[convert] kb=… fileType=pdf engine="mineru"` | `WeKnora-app` 日志 `knowledge_process.go:3949` |
| 2 | 请求确实打到 110：`[MinerU] Parsing file=2025年…_扫描版.pdf size=27215815 via http://10.168.1.110:36743` | `mineru_converter.go:81` |
| 3 | **110 侧访问日志：`"POST /file_parse HTTP/1.1" 404 Not Found` × 4**（与前端 `attempt=4` 吻合） | `docker logs mineru-api` |

另有一条**时序旁证**：从发起到失败仅 **1.2 s**，而这份 38 页扫描件真实解析需 **≥18 s**
⇒ 是「被立刻拒绝」，不是超时或解析失败。

### 8.2 根因：两套 API 契约不同

**WeKnora 的自托管 MinerU 引擎按「经典同步契约」实现**（`mineru_converter.go:236`）：

```
POST {endpoint}/file_parse          ← 同步、multipart
  字段：files(文件) + return_md=true + return_images=true + parse_method + backend
        + table_enable + formula_enable + start_page_id=0 + end_page_id=99999
        + lang_list + return_content_list=true + response_format_zip=false …
  响应：{"results": {"<上传文件名去扩展名>": {"md_content": "...", "images": {"<路径>": "<base64 或 data-uri>"}}}}
        （键回退顺序：stem → "document" → "files" → 任意非空 entry）
```

**MinerU 4.0.6 只提供 `/v1/*` 异步 job 契约**（upload → PUT → complete → job → poll → download）：

- `mineru/parser/api_server.py` 只有 `APIRouter(prefix="/v1")`
- **全仓 grep `file_parse` = 0 命中** ⇒ 4.0.6 已彻底移除旧同步 API
- `mineru-kit` 子命令只有 `parse / webui / api-server / vlm-server / router / models`
  —— 其中 `router` 也只是「仅暴露 **V1** API」，**没有**旧契约兼容服务

### 8.3 为什么"看起来配置是好的"——探测点与解析点不是同一个

`CheckAvailable` → `PingMinerU()` 只做一件事：**`GET {endpoint}/docs`** 且状态码 < 400。

- 110 的 `enable_docs` 默认 **True**（`api_server.py`：`MINERU_API_ENABLE_FASTAPI_DOCS`，默认 True）
  ⇒ `/docs` 返回 **200** ⇒ UI 显示引擎「可用/已连接」
- 但真正解析走的是 `/file_parse` ⇒ **404**

⇒ **「探测通过」≠「契约匹配」**。这是本轮最容易误判的一点：UI 的绿灯只证明"那台机器上有个 FastAPI"。

### 8.4 上游有没有解？**当时没有（2026-09-23）→ 已于 2026-09-25 原生解决**

- 2026-09-23 实测：本地 `wkj-dev` 与 `upstream/main` 同步（落后 **0** 提交），
  但 `upstream/main` 里 **完全没有** `/v1/uploads`、`parse/jobs` 之类 4.x 契约的实现（grep 命中 0）
  ⇒ 当时「拉上游拿不到 4.x 支持」的判断**成立**
- ★ **该结论已于 2026-09-25 失效**：官方 `e22a8367` 新增 `mineru_v1_client.go`（594 行），
  把 `mineru` 引擎改为**按 `GET /v1/health` 自动选协议** ⇒ **拉上游就能拿到 4.x 支持**

### 8.5 超时不构成障碍

`mineru_converter.go:25` 的 `mineruTimeout = 1000 * time.Second`（≈16.7 分钟）
⇒ 一个**同步阻塞式**的适配器（内部轮询 `/v1` job 直到完成再返回）完全可行。

### 8.6 可选方案与代价（★ **2026-09-25 起全部作废**）

> 官方原生支持后，下表四个方案**均不需要**。保留以记录当时的决策空间。

| 方案 | 做法 | 代价 | 合规 |
|---|---|---|---|
| **A（推荐）110 侧契约适配器** | 在 110 上新增一个小服务：暴露 `POST /file_parse`（+ `GET /docs` 供探测），内部转调 `/v1/*` 五步异步 API，再把结果映射成 `{"results":{stem:{md_content,images}}}` | 约 200 行 Python + 一个容器/端口；多一跳 | ✅ **不动 WeKnora 官方代码**，符合 fork 铁律 §1 |
| B 改 WeKnora Go 代码 | 在 `mineru_converter.go` 加 4.x 分支 | **修改官方文件** ⇒ 上游同步冲突 | ❌ 违反 AGENTS.md §1 |
| C 换回旧版 MinerU 容器 | 跑提供 `/file_parse` 的 1.x/2.x MinerU | 退回旧模型；质量与显存优化全部重来 | ⚠️ 倒退 |
| D 暂用 `paddleocr_vl` 引擎 | 该引擎契约是同步 `POST {endpoint}/layout-parsing`（`paddleocr_vl_converter.go:156`），WeKnora 原生支持 | 立即可用，但 PPSV3 容器已删（镜像保留，`up -d` 即恢复），实测占 ~4.2 GiB，**与 MinerU 不能共存** ⇒ 等于放弃 MinerU | ✅ 可作过渡 |

### 8.7 一处会误导排障的命名（提醒后来者）

失败在知识库任务里被标成 **`DOCREADER_PARSE_FAILED` / `name: "docreader"` / `stage: "docreader"`**，
但实际执行的是 **Go 原生的 `mineru` 引擎**（日志已证），**没走 docreader 服务**
（docreader 容器近 1 小时日志为空）。

⇒ 该错误码是「文档读取阶段」的**通用标签**，别据此去查 docreader 侧。

### 8.8 核实「以前用管道模式调用 MinerU 成功过」（2026-09-23）

用户回忆曾成功过。**核实结论：没记错"看到过成功"，但那个成功是「引擎连通性检查通过」，
不是解析成功；真正跑通过的解析是 PP-StructureV3（`paddleocr_vl` 引擎），不是 MinerU。**

| 核查点 | 证据 | 结论 |
|---|---|---|
| 有没有走通 `mineru` 引擎的解析？ | 库表：唯一用 `mineru` 的是 `财政审计工作报告`（09-23 建），**仅 1 个文档**、状态 `deleting`、错误「用户已取消解析」 | ❌ **从未 completed** |
| 日志里的 MinerU 调用 | `[MinerU] Parsing … via http://10.168.1.110:36743` **4 次**（均为同一文件）；`[MinerU] Using response path` / `Raw response` 计数 **0** —— 这两行**只在 HTTP 200 时才打印** | ❌ 4/4 失败 |
| 110 侧 | `"POST /file_parse HTTP/1.1" 404 Not Found` × 4 | ✅ 与上吻合 |
| 那"成功"到底是什么？ | `POST /system/parser-engines/check` → `ListAllEngines` → 对 `mineru` 调 `PingMinerU()` = **只 `GET /docs`** | ⚠️ **连通性 ≠ 契约匹配** |
| 真正跑通过的是什么？ | 全库 **38 份 `completed`** 全在 `wkj-ppsv3-验证`／`测试1`／`(备份)财政审计工作报告`，规则 = **`paddleocr_vl`**（PPSV3 同步 `/layout-parsing`），时间 **09-22** | ✅ **是 PPSV3** |
| 时间窗 | `min(created_at)` = 2026-09-20，`max` = 2026-09-23 | 无更早历史 |
| 日志覆盖 | `WeKnora-app` 日志窗口 2026-09-23 11:04 → 20:36，其间 `mineru_endpoint` **只出现过 `10.168.1.110:36743` 一个值** | 没有指向过别的服务 |

**为什么"管道"这个词会挂到 MinerU 上**：`mineru` 引擎抽屉里 `Backend` 字段的**默认值就是 `pipeline`（管道）**，
示例地址也写 `:8000` —— 两者都是**旧版 MinerU 1.x/2.x 的语义**（那时 `POST /file_parse` 存在且可用）。
⇒ 「管道模式 + mineru」在 **1.x/2.x 时代成立**，在 **4.0.6 时代不成立**。

**时间线旁证**：110 上确实有过一台提供 `/file_parse` 的旧版 MinerU（`mineru:latest`，端口 8000/7860），
但它 **2026-08-06 已停用**，而 111 上 WeKnora 的文档记录自 **09-20** 才开始 ⇒ 两者时间不重叠。

**旧 `backend` → 4.x 档位的映射（★ 官方方案已内置，此处仅备查）**：
官方 `e22a8367` 用 `mineru_tier` 取代旧 `backend`。官方迁移口径如下 ——
⚠️ **照官方口径，不要按字面语义推**：

| 旧 `backend` | 4.x 档位 |
|---|---|
| `pipeline` | `tier=basic` |
| `vlm-engine` / `vlm-auto-engine` / `vlm-http-client` | **`tier=advanced`** |
| `hybrid-engine` / `hybrid-auto-engine` | `tier=standard`（或不传） |
| `flash` | `tier=flash` |

> ★ **一处自我订正**：本节初版把 `vlm-*` 写成 `tier=standard`，**这是错的** —— 官方口径是 `advanced`。
> 记下来当反例：**映射关系要以官方迁移/变更文档为准，不能按名字的字面语义推**。

⇒ 在官方方案里，抽屉中的旧 `Backend` / 公式 / 表格 / 语言字段**在 4.0 下被忽略**
（官方把它们归入 legacy 段），改由 `mineru_tier` 直接选档位 —— 比"适配器映射"更直接。
`解析方式` 则保留，映射为 V1 的 `ocr_mode`。

### 8.9 为什么「WeKnora 有 MinerU 配置却跑不通」——版本不对，而且是**刚发生**的（2026-09-23 定案）

**结论**：是版本不对，但更准确的说法是**契约代际不对**。而且**不是我们配错，也不是上游偷懒** ——
是 **MinerU 4.0 在 2026-09-16 做了一次不兼容重构**，本机 09-23 才接上，**中间只隔 7 天**。

**两边时间线对照**（各自仓库 git 实测）

| 时间 | 谁 | 事件 | 契约状态 |
|---|---|---|---|
| 2025-06-25 | MinerU `3f87f83f` | 加 FastAPI 自托管服务与 `/file_parse` | 旧契约诞生 |
| **2026-02-28** | WeKnora `397689d2` | 引入 `mineru` 自托管引擎（Lite edition） | **照旧契约写** |
| **2026-03-04** | WeKnora `fd742fea` | 定型 MinerU 响应处理（`{"results":{stem:{md_content,images}}}`） | 最后定型 |
| 2026-03-19 | MinerU `1d96a77a` | FastAPI 改异步（加 `/tasks`），但**保留** `/file_parse` | 兼容期 |
| 3.x 全程 | MinerU | 官方 changelog：保留 `/file_parse` **"for compatibility with legacy plugins"** | 兼容期 |
| 2026-05~07 | WeKnora | 仍在做 MinerU 参数增强（`mineru_vlm_server_url`、SSRF 加固） | 仍是旧契约参数 |
| **2026-09-16** | MinerU `22f5abb6` | **4.0.0 正式发布：`/file_parse`、`/tasks` 不再提供** | **契约死亡** |
| 2026-09-23 | 本机 | 接入 → `POST /file_parse` **404** | 相隔 7 天 |

⇒ **WeKnora 的集成代码比 MinerU 的 API 重构早了半年**；在 3.x 全程它都是对的，一直到 4.0 把它作废。
⇒ 所以"正常配置就能跑通"这个假设，**在 2026-09-16 之前是成立的**。

**为什么"配置看起来完备"反而是陷阱**（三层，都很具体）

1. **字段是照旧契约设计的**：`Backend` 下拉的五个值 `pipeline` / `vlm-auto-engine` / `vlm-http-client` /
   `hybrid-auto-engine` / `hybrid-http-client` —— **正是 MinerU 4.0 明确移除的 `--backend` 取值**。
   ⇒ 这个下拉框本身就是**旧契约时代的化石**：字段越齐全，越像"配好了"。
2. **检查按钮验的不是契约**：`POST /system/parser-engines/check` → `PingMinerU()` 只做 `GET /docs`，
   而 4.0.6 的 `MINERU_API_ENABLE_FASTAPI_DOCS` **默认 True**（`api_server.py:2383`）⇒ 永久绿灯。
3. **没有任何版本护栏**：WeKnora 官方 `docs/` **从未写明 MinerU 版本要求**（版本号 grep 0 命中），
   MinerU 也**不随 WeKnora 分发容器**（`docker-compose*.yml` 里没有）⇒ 版本责任推给使用者，
   但既无检查也无提示。

**正本在 MinerU 侧**：`my-docs/10-现状与运维/02-注意事项与坑.md` **§18** —— 含官方迁移文档引文、
`/file_parse` 存亡时间线、`backend→tier` 官方映射表、以及探测盲区的端点实测（`/docs` 200 / `/file_parse` 404）。

**由此得一条可迁移的判据**（以后接任何外部解析服务都适用）

> **配置字段齐全 ≠ 契约匹配；探测绿灯 ≠ 能调用。**
> 接第三方服务时第一件事是**核对它对标的 API 代际与发布日**，而不是先调参数。
