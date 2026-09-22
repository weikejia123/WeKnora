# PP-StructureV3 部署记录与验证（南宁 110）

> 日期：2026-09-22 · 目标：在 110 部署 PP-StructureV3 容器，供 WeKnora 解析扫描件 PDF
>
> **状态：已完成部署，并已在 WeKnora 内跑通真实解析（端到端）**（2026-09-22）。
> 服务运行于 `110:36742`，维护仓库在 `110:/opt/docker-deploy/pp-structure-v3/`（独立 git）。
> WeKnora 侧已配置 `paddleocr_vl_endpoint`，实测「上传扫描件 → 落库分块」全链路通（见 §6.5）。
> 本文档保留**决策依据、预检数据与验证结果**；后续实施细节以该仓库 `my-docs/` 为准。
>
> ★ **实施记录已迁至 110 上的独立仓库**：`/opt/docker-deploy/pp-structure-v3/`
> （含 `AGENTS.md` 规约、`my-docs/20-设计/`、`my-docs/30-实施/`）。

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

### 6.4 部署与验证结果（2026-09-22 完成）

| 步骤 | 结果 |
|---|---|
| 镜像 | `pp-structure-v3:20260922` 构建成功（19m24s，主要耗时在 `pip install paddlex[ocr]`） |
| 容器 | `pp-structure-v3-api` **Up (healthy)**，`0.0.0.0:36742->36742` |
| 仓库提交 | `6dd3439` → `22cf4a2` → `64855c7` → `617dd45` → `a71cd50` → **`3bcd18b`** |

**端到端验证（逐字复刻 WeKnora 的 20 字段请求体）**

| 项 | 结果 |
|---|---|
| 契约 | ✅ `{errorCode:0, errorMsg:"", result:{layoutParsingResults:[{markdown:{text,images}}]}}` |
| 3 页样本 | HTTP 200 / 10.9s |
| **整份 38 页** | HTTP 200 / **51.4s（1.35s/页）** / **返回 38 页** |
| 输出质量 | `## 标题` 层级正确、段落完整、页码已剔除 |
| 错误处理 | 非法输入 ⇒ HTTP 400 且响应结构保持 `{errorCode,errorMsg,result:null}` |

> ★ **实测确认无「只处理前 10 页」的截断** —— 该限制属 PaddleX serving 层，
> 本服务直调 Python 产线对象，不受影响。（此前担心的坑已排除，非推断。）

**显存实测（12GB 卡）**

| 状态 | 占用 |
|---|---|
| 产线常驻（空闲） | **1744 MiB** —— 非「用完即释放」 |
| 推理峰值 | **4029 MiB**（38 页）/ 3087 MiB（3 页） |

⇒ 与 `pp-ocr-v6-gpu`(2574) + Ollama-embedding(4300) 全开约 **8618 MiB** 静止、
约 **10900 MiB** 推理 ⇒ **余量约 1.4 GB，再加载 VLM 将 OOM**。

**★ 更新（2026-09-22 15:2x）：`pp-ocr-v6-gpu-api` 容器已删除**（老魏决定；镜像与模型缓存保留）
⇒ 共卡项少一项。**实测当前状态**：

| 占用方 | 实测 |
|---|---|
| PP-StructureV3（常驻） | 2166 MiB |
| Ollama `qwen3-embedding:4b` | 4304 MiB（★ 已按需自动重载，见 §6.1 第 1 条风险） |
| `llama-server` | 138 MiB |
| **合计 / 空闲** | **6628 / 5283 MiB** |

⇒ PP-StructureV3 推理峰值约 +2.3 GB ⇒ 峰值时余量约 **3.4 GB**，比原先宽裕。
恢复 36741 需 `docker compose -f compose.gpu.yaml up -d`（见
`WeKnora-docreader接入PP-OCRv6方案.md` 头部的恢复命令）。

**★ 一处按实测修正的配置（WeKnora 侧需知悉）**

6 并发时第 6 个请求被 **429** 拒绝（原队列容量 4）。而 **WeKnora 侧只给 1000s
超时、没有任何 429 重试逻辑**（`paddleocr_vl_converter.go:21`）⇒ **拒绝 = 该文档解析失败**。
串行执行下排队不增加显存 ⇒ 队列容量上调至 **16**。复测 6 并发**全部 200**。

**排版质量对照**（同一份文档、同一页）

| | PP-OCRv6 纯 OCR（`my-docreader`） | PP-StructureV3 |
|---|---|---|
| 第 6 页 | 46 行 → **39 个碎片段落** | 1 个 `table` 区块，**HTML 含 rowspan** |
| 标题 | 靠行高/缩进猜（曾误判） | 产线直接给 `paragraph_title` 标签 |
| 页码 | 正则猜 | `number` 标签，**原生剔除** |

**如实记录的两处不足**

1. **表格长文本单元格被按视觉行拆成多行** ⇒ 单元格内句子跨行被切开（见该仓库
   实施记录 §10.1），下游会切成多个 chunk。
2. **不支持 `mergeTables`**（WeKnora 请求为 `true`）—— 本次样本主表跨 **35 页**
   ⇒ 会产生 **35 个独立表格块、每页各自带表头**。是否后处理合并待定。

### 6.5 ★ WeKnora 侧真实接入验证（端到端，2026-09-22）

> 起因：老魏追问「你确定 WeKnora 里的 PP-VL 解析引擎可以配置这个 v3 的 apiURL？」
> —— **此前只验证了服务侧契约（curl 模拟 WeKnora 请求体），那属于「等价简化路径」**。
> 「零代码接入」当时是**推断**，不是实测。本节把它变成实测。

#### ① 配置入口与校验规则（源码核实）

| 项 | 值 |
|---|---|
| 写入接口 | `PUT /api/v1/tenants/kv/parser-engine-config`（Admin） |
| 字段 | **`paddleocr_vl_endpoint`** |
| **保存时校验** | **`validateParserEngineOutboundURLs()`** → `secutils.ValidateURLForSSRF(endpoint)`（`internal/handler/tenant.go:1924-1928`） |
| 存储位置 | `tenants.parser_engine_config`（jsonb） |
| 权限 | 路由要求 `full_access` API key + `ManageTenantSettings` 能力 |

⇒ **关键**：端点要过 **SSRF 校验**。而 `10.168.1.110` **已在 `SSRF_WHITELIST`** 中
（`deploy/deploy-wkj-dev.sh:256`）⇒ 这道关能过。

#### ② 实测：配置成功

```
PUT  {"paddleocr_vl_endpoint":"http://10.168.1.110:36742"}
→    HTTP 200  {"message":"解析引擎配置已更新","success":true}
回读 → paddleocr_vl_endpoint = "http://10.168.1.110:36742"
库内 → tenants.parser_engine_config 已持久化
```

**引擎可用状态的翻转**（`GET /api/v1/system/parser-engines`）：

| | 配置前 | 配置后 |
|---|---|---|
| `paddleocr_vl` | `Available=false`（端点为空的默认态） | **`Available=true`** |
| 支持的文件类型 | — | `pdf, jpg, jpeg, png, bmp, tiff` |

> 可用性判据 = `PingPaddleOCRVL()`（`engines.go:263`）：
> 发 `GET {endpoint}/layout-parsing`，**状态码 < 500 即判可用**（`paddleocr_vl_converter.go:281-292`），
> 注释原文：*"The pipeline only exposes POST /layout-parsing; an empty GET should still
> produce a routed HTTP response (e.g. 404/405) when the service is up."*
>
> ★ **实测确认了此前预测的「假阳性」**：110 侧日志出现
> `GET /layout-parsing → 405 Method Not Allowed`，而 WeKnora 判为可用。
> ⇒ **绿灯只证明「服务在，且不是 5xx」，不证明协议能跑通。** 以真实解析为准。

#### ③ 实测：真实解析跑通（决定性证据）

在**新建的临时知识库**里把 `pdf` 引擎设为 `paddleocr_vl`（不动现有任何库）：

```
chunking_config.parser_engine_rules = [{"file_types":["pdf"],"engine":"paddleocr_vl"}]
```

上传 3 页纯图片扫描件（`审计结果_扫描版_3页.pdf`，1.6MB，文本层 0 字符），**两侧日志**：

**111（WeKnora）：**
```
knowledge_process.go:3921[convert] | [convert] kb=a632117c-… fileType=pdf isURL=false
                                     engine="paddleocr_vl" rules=[{…}]
paddleocr_vl_converter.go:56[Read] | [PaddleOCR-VL] Parsing file=审计结果_扫描版_3页.pdf
                                     size=1666759 via http://10.168.1.110:36742
paddleocr_vl_converter.go:210      | [PaddleOCR-VL] parsed 3 page(s), images=0
paddleocr_vl_converter.go:73[Read] | [PaddleOCR-VL] Parsed successfully, markdown=3635 chars, images=0
```

**110（PP-StructureV3）：**
```
10.168.1.111:56128 - "GET  /layout-parsing HTTP/1.1" 405 Method Not Allowed   ← 可用性探测
INFO ppsv3: parsed 3 page(s) in 2.4s (fileType=0, pdf=True)
10.168.1.111:42920 - "POST /layout-parsing HTTP/1.1" 200 OK
```

> `markdown=3635` 是 **Go 的 `len(string)`＝字节数**；3635 字节 ≈ 1387 个中文字符，
> 与服务侧直测的 1387 字符**一致**（不要误判成「膨胀」）。

#### ④ 实测：落库分块质量（最终效果）

`parse_status=completed`，共 **5 个分块**。抽样：

```
块0  ## 中央部门单位2025年度预算执行等情况审计结果
     2025年9月至2026年1月，审计署重点审计了39个部门及所属 229 家单位…此次共发现各类问题金额 170.01 亿元…

块1  ## 一、 违反财经纪律等行为仍有发生
     （一）依托部门行政资源和影响力谋利。一是7个部门的16 家所属单位…9201.51 万元…

块3  ## 二、 行政事业性国有资产管理不够严格高效
     （一）资产基础性管理薄弱。主要表现为15个部门的资产底数不清、闲置…
```

⇒ **`##` 标题层级正确、段落完整、金额与数字全对**，且**页码已剔除**。
对比同一份文档走 `builtin + 多模态`（老魏实测的碎片化输出），段落完整性明显更好。

#### ⑤ 一个能力分层的观察（未做结论）

WeKnora 的**知识库级**引擎选择只到「**按文件类型**」这一层
（`parser_engine_rules: [{file_types, engine}]`），**没有「按文档性质分流」的表达能力**。
⇒ 若要「表格密集的库走 A、纯文字批量的库走 B」，只能**按库分开建**（本验证即此法）。

#### ⑥ 测试残留已清理

| 项 | 处置 |
|---|---|
| 临时知识库 `wkj-ppsv3-验证` | 已删除（`DELETE /knowledge-bases/:id`） |
| 测试文档 + 8 个分块 | 已软删（`deleted_at` 均已写入） |
| 临时 API Key `wkj-tmp-verify` | 已从 `tenant_api_keys` 删除（该表只剩 `ADMIN`） |
| 临时文件 | 已清理 |
| **`paddleocr_vl_endpoint` 配置** | **保留** —— 它是使用该引擎的前提，且不影响未选用它的知识库 |

现有 4 个业务库**未被触碰**（`pdf` 仍为 `anydoc`）。

### 6.6 下一步

若要正式启用：在目标知识库的「解析设置」里把 `pdf` 引擎选为 **PaddleOCR-VL（自建）**；
存量文档走 `POST /knowledge/:id/reparse`。分块参数（`chunk_size` / 父子分块等）可按库调。
