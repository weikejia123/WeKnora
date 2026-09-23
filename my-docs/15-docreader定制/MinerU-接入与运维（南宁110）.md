# MinerU 4.0.6 接入与运维（南宁 110）

> ★★ **当前状态：服务已跑通（含 Web UI），但尚未接入 WeKnora**（见 §五）。
> 与此同时 **PP-StructureV3 的容器已删除**（见同目录 `PP-StructureV3-接入与运维（南宁110）.md` §七）
> ⇒ **目前 WeKnora 的 `paddleocr_vl` 引擎实际不可用**（正式库不受影响，它们用 `anydoc`）。
>
> **一句话**：同机新部署的**通用文档解析服务**，`110:36743`。契约是**异步 job 式 `/v1/*`**，
> 与 WeKnora 现有 `paddleocr_vl` 引擎期望的 PPSV3 同步 `/layout-parsing` **不兼容**。
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

**显存（12 GB 卡，实测）**

| 场景 | 占用 |
|---|---|
| 引擎已加载、空闲（常态） | **7020 MiB** |
| 38 页文档解析中峰值 | **8722 MiB** |
| 解析后回落 | 7048 MiB |

拆分明细：`VLLM::EngineCore` 5434 MiB（权重 2.16 GiB + KV cache） + API 主进程 704 MiB。

> ⚠️ **`GET /v1/health` 通过 ≠ 可解析** —— VLM 引擎**懒加载**，首次解析才起 vLLM（约 30 s）。
> 验收必须走真实解析，不能只看 health。

### ★ 同机共卡：与 Ollama `qwen3-embedding:4b` 共存（实测 2026-09-23）

用户规划：110 的常驻服务 = **MinerU + Ollama 的 qwen embedding**（Ollama `11434`，
`KEEP_ALIVE=1h`）。两者能否同时用 —— 已实测：

| 场景 | 显存 used 峰值 | 余量 |
|---|---|---|
| MinerU 单独解析 38 页 | 8722 MiB | 3566 MiB |
| embedding 驻留（无解析） | 10861 MiB | 1050 MiB |
| **两者同时**（embedding 驻留 + 38 页解析） | **11861 MiB** | **50 MiB** ⚠️ |
| 再加 8 个 embedding 请求（**Ollama 侧排队串行**，非真并发） | 未再增长 | 50 MiB |

- embedding 侧：`POST /api/embed`，**2560** 维；占 **4108 MiB**；冷加载 4.6 s、热态 0.15~0.31 s
- 同时运行期间：解析产物 **106995 字符**（与单独跑一致）、embedding **8/8 返回 200**、`dmesg` 无 OOM
- ❌ 已实测排除：调小 embedding `num_ctx` **不省显存**（4096 vs 默认同为 4108 MiB）

⇒ **结论：可以同时使用，但余量很薄（50 MiB）**。若日后要留安全余量，可
① 下调 MinerU `--gpu-memory-utilization`（当前 `0.5`，见 §三）；
② 调短 Ollama `KEEP_ALIVE`（当前 1h）；
③ 换更小的 embedding 模型。

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

源码 `mineru/model/vlm/engine_utils.py:94`：

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
实测 `VLLM::EngineCore` 进程 **6108 MiB**，与 6144 预算吻合。

**并发上限 = `min(KV cache 容量, MinerU 自限 batch_size)`**。`set_default_batch_size()`
（同文件 `:114`）按显存档位取 `≥16 GB → 8`、`≥8 GB → 4` ⇒ 本机为 **4**。
`4 × 单序列长度 ≪ 187,568 tokens` ⇒ **KV cache 不是瓶颈，权重才是**。
这也是「下调 `--gpu-memory-utilization` 主要压 KV cache、**不必然损失并发**」的依据
（真实下限需实测：util 过低会让 vLLM 因 KV cache 不足而在启动期报错）。

⚠️ **共卡陷阱**：`get_vram()` 取的是**整卡总显存**、**不减去**同机 Ollama 已占的 4108 MiB
⇒ 两个进程**各算各的预算**。12 GB 卡上共存余量只剩 50 MiB，根因就在这里。

可用 `--gpu-memory-utilization` 显式覆盖（**要往下压显存就改这里**）。

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

## 五、★ 接入 WeKnora：三条路径（**尚未决策**）

WeKnora 的 `paddleocr_vl` 引擎读的是 **PPSV3 契约**
（`result.layoutParsingResults[].markdown.text`），与 MinerU 的异步 job 契约不兼容
⇒ **不能零改动切换**。

| 方案 | 改动面 | 代价 |
|---|---|---|
| **A. 只部署原生服务**（现状） | 无 | WeKnora 用不上；MinerU 独立可用 |
| **B. 110 上加 PPSV3 契约适配层** | 110 侧新增一个薄服务 | 要把异步 job 流包成同步响应（含轮询 + 超时 + 错误映射） |
| **C. WeKnora 侧新增 `mineru` 引擎** | 改 WeKnora 后端（新增 converter + 引擎注册） | 二开成本最高，但契约最干净 |

**决策所需的两条前提事实**：

1. **`paddleocr_vl` 引擎的探针会假阳性**（见 PPSV3 文档 §三.2）——
   它以「状态码 < 500」判可用，MinerU 只暴露 `/v1/*` ⇒ 若把端点直接指过去，
   探针会拿到 404/405 却判「可用」。**任何走 B/C 之外的「直接改端点」都是错的。**
2. **图片会被静默丢弃**（PPSV3 文档 §三.9）—— MinerU 产物同样是 markdown，
   若采用 B（适配层），需要同样处理 `images` 字段，否则插图丢失。

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

⇒ **对应到接入方案**：只要 PP-OCRv6 管线就传 `tier=basic`（显存上不再与 Ollama embedding
争那 50 MiB）；要 VLM 质量则须显式传 `standard`，并接受共卡紧张。
**选档是 §五 三条路径的前置决策。**

**3. 显存要按峰值算（且峰值不是「KV cache 增长」）**

静态 7020 MiB，38 页文档解析中冲到 **8722 MiB** ⇒ 估余量必须按峰值。
⚠️ 但那个增长**不是** KV cache：vLLM 的 KV cache 在**启动期按 `gpu_memory_utilization`
一次预分配、运行期不增长**（启动日志 `Available KV cache memory: 2.15 GiB` 即最终值），
增长来自激活/中间张量与图像预处理。
另：**仅 `standard` / `advanced` 档才有这笔 vLLM 开销**（见上条）。

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
