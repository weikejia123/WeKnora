# MinerU 4.0.6 接入与运维（南宁 110）

> ★★ **当前状态：服务已跑通，但尚未接入 WeKnora**（见 §四）。
> 与此同时 **PP-StructureV3 已停止**（见同目录 `PP-StructureV3-接入与运维（南宁110）.md` §七）
> ⇒ **目前 WeKnora 的 `paddleocr_vl` 引擎实际不可用**（正式库不受影响，它们用 `anydoc`）。
>
> **一句话**：同机新部署的**通用文档解析服务**，`110:36743`。契约是**异步 job 式 `/v1/*`**，
> 与 WeKnora 现有 `paddleocr_vl` 引擎期望的 PPSV3 同步 `/layout-parsing` **不兼容**。
>
> 本文档管 **WeKnora 侧怎么看它、能不能用、要注意什么**。
> 服务本身的实现与运维记录在 **110 上的独立仓库**（见 §六）。

---

## 一、现状

| 项 | 值 |
|---|---|
| 服务地址 | `http://10.168.1.110:36743` |
| 健康检查 | `GET /v1/health` ⇒ `status / version / features` |
| 容器 / 镜像 | `mineru-api` / `mineru:4.0.6`（compose project `mineru`） |
| 版本 | `4.0.6` |
| 二开分支 | `wkj-dev`（基点 = upstream master `48a92548`） |
| 能力 | 版面 + 表格（HTML `<table>` 含 `rowspan`）+ 公式（LaTeX）+ OCR，**VLM 驱动** |
| 性能 | **≈1.58 s/页**（38 页扫描件整份 **60 s**） |
| 接口形态 | **异步**：建 upload → 传字节 → 提交 job → 轮询 → 下载产物 |
| 并发 | vLLM 异步调度（与 PPSV3 的串行排队不同） |
| WeKnora 侧配合改动 | **无**（尚未接入） |

**实测 `tier=standard` 的产物形态**（用 PPSV3 同批样本测）

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

## 三、★ 显存由 MinerU 自己接管，不是 vLLM 默认值

vLLM 默认 `gpu_memory_utilization=0.9`（12 GB 卡会先占 10.8 GB），**MinerU 不用它**。

源码 `mineru/model/vlm/engine_utils.py:94`：

```python
def set_default_gpu_memory_utilization(backend="vllm") -> float:
    gpu_memory = get_vram(device)
    if gpu_memory > 8:
        min_memory = 6                                  # >8GB 统一按 6GB 预算
        return max(round(min_memory / gpu_memory, 2), 0.1)
```

12 GB 卡 ⇒ `6 / 12 = 0.5`。实测 EngineCore 5434 MiB 与该预算吻合。
可用 `--gpu-memory-utilization` 显式覆盖（**要往下压显存就改这里**）。

---

## 四、★ 接入 WeKnora：三条路径（**尚未决策**）

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

## 五、注意事项与坑

**1. 服务形态是异步 job，不是"发一个 POST 就回结果"**

下游若按同步语义调用会拿到 `job_id` 而非解析结果。完整链路 5 步（见 110 侧文档 §2）。

**2. `tier` 是能力分级，不是模型档位**

源码 `mineru/types.py`：`flash(0) < basic(1) < standard(2) < advanced(3)`，
服务端 `standard` 展开为**全部四项能力**。请求参数决定，非容器启动时固定。

**3. 显存要按峰值算**

静态 7020 MiB，但 38 页文档解析中冲到 8722 MiB（KV cache 增长）⇒ 并发时会更高。

**4. 与 PPSV3 无法共存（单卡 12 GB）**

两者常态合计 11.1 GiB、峰值可到 12.9 GiB ⇒ **超卡**。
要同时跑必须先下调 MinerU 的 `--gpu-memory-utilization`。

---

## 六、权威记录在哪

| 要看什么 | 去哪 |
|---|---|
| 服务实现 / 设计 / 运维与坑（**权威**） | `110:/mnt/docker-data/docker-deploy/mineru/` → `my-docs/` |
| 同机另一解析服务 PP-StructureV3（**已停**） | `PP-StructureV3-接入与运维（南宁110）.md`（本目录） |
| 为什么当初选 PPSV3 | `WeKnora-扫描件PDF解析质量对比与选型.md` |
| 解析引擎的通用机制 | `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md` |

> 服务是**独立 git 仓库**（分支 `wkj-dev`，remote `upstream` 带 `gh-proxy.com` 前缀）。
> ⚠️ `/mnt/docker-data/docker-deploy/mineru/` 的父目录属 `root`，新建项目需
> `sudo mkdir` + `sudo chown wkj:wkj`。
