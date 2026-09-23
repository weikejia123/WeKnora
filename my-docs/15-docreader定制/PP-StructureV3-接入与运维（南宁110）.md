# PP-StructureV3 接入与运维（南宁 110）

> ★★ **当前状态：容器已停止**（2026-09-23，为 MinerU 让出显存，见 §七）。
> 镜像与模型均保留，一条命令可恢复。
> 本文档其余章节记录的是**恢复后**的可用形态 —— 未恢复前，页面上的
> `PaddleOCR-VL` 引擎**实际不可用**（测试连接会失败，不是假阳性）。
>
> **一句话**：WeKnora 的**扫描件 PDF 解析后端**。服务跑在 `110:36742`，
> 契约复刻 PaddleX 官方 `POST /layout-parsing` ⇒ WeKnora 的 `paddleocr_vl` 引擎**零代码接入**。
>
> 本文档管 **WeKnora 侧怎么用、要注意什么**。
> 服务本身的实现与运维记录在 **110 上的独立仓库**（见 §六）。

---

## 一、现状

| 项 | 值 |
|---|---|
| **当前状态** | ★ **已停止**（2026-09-23）—— 见 §七 |
| 服务地址 | `http://10.168.1.110:36742` |
| 健康检查 | `GET /api/health` ⇒ `status / device / pipeline_loaded / queue_depth / max_queue / settings / gpu_free_mb` |
| 容器 / 镜像 | `pp-structure-v3-api` / `pp-structure-v3:20260922` |
| **OCR 模型** | **`PP-OCRv6_medium_det` + `PP-OCRv6_medium_rec`**（显式指定，见 §三.5） |
| 产线 | PP-StructureV3，**已关**公式 / 印章 / 图表；**已开**方向分类 / UVDoc 矫正 |
| 能力 | 版面检测 + 表格识别（SLANeXt）+ 阅读顺序 + 页码剔除 |
| 性能 | **≈1.35 s/页**（38 页扫描件整份 **51.4 s**） |
| 并发 | **串行执行** + 有界排队（容量 16），队列满返回 429 |
| WeKnora 侧配合改动 | **无**（官方文件一行未动） |

**已验证的边界（实测，非推断）**

| 项 | 结果 |
|---|---|
| **整份 38 页是否被截断** | **否**，返回 38 页 —— 官方 serving 那个「默认只处理前 10 页」的限制**不适用**（本服务直调 Python 产线对象，不走 serving 层） |
| 错误输入（非法 base64 / 缺 `file`） | HTTP **400**，且响应结构保持 `{errorCode, errorMsg, result:null}` ⇒ 不会给下游畸形响应 |
| 响应契约 | `{errorCode:0, errorMsg:"", result:{layoutParsingResults:[{markdown:{text,images}}]}}` |

**显存（12 GB 卡，实测）**

| 场景 | 占用 |
|---|---|
| **跑过大文档后的常驻**（常态） | **≈4.2 GiB** |
| 刚启动、未跑过大文档 | ≈2.1 GiB |
| 推理峰值 | ≈4.0 GiB |

> ⚠️ 常驻**不是固定值**：Paddle 的分配器默认按需增长且**不归还驱动**
> ⇒ 跑过一次大文档后，显存池就按峰值留住了。**余量要按「跑过之后」算。**

**共卡**：与 Ollama（`qwen3-embedding:4b` 等，1 小时无人用自动释放）共用这张卡。
Ollama 释放时 GPU 空闲约 **7.7 GiB**；加载时约 3.6 GiB。
⚠️ 再加载任何**常驻 VLM** 会挤占本服务的空间，需先核对。

---

## 二、怎么接入（三步）

**① 配全局端点**（一次性）

```
设置 → 解析引擎 → PaddleOCR-VL → 服务器地址填 http://10.168.1.110:36742 → 保存
```

- 对应的接口：`PUT /api/v1/tenants/kv/parser-engine-config`，字段 `paddleocr_vl_endpoint`
- 存储在 `tenants.parser_engine_config`（jsonb）

**② 让知识库的 PDF 走它**

页面上叫 **「解析引擎」**，两个入口：

| 入口 | 位置 | 作用范围 |
|---|---|---|
| 知识库默认 | 知识库「编辑」→ 左侧「解析引擎」→ **「PDF 文档」**行的下拉选 `PaddleOCR-VL` | 该库后续所有上传 |
| 上传时临时指定 | 上传确认弹窗 → 左侧「解析引擎」 | 仅本次 |

**③ 存量文档要重新解析** —— 改配置只影响**后续入库**。

> 在下拉里看不到 `PaddleOCR-VL` ⇒ 端点没配好（见 §三.3）。

**怎么确认真的走了它**（三条判据）

1. WeKnora 日志：`engine="paddleocr_vl"` + `Parsing … via http://10.168.1.110:36742`
2. 110 侧日志：`POST /layout-parsing 200 OK` + `parsed N page(s) in ...`
3. 内容特征：有 `## 一级标题` 层级、段落完整、**页码被剔除**

---

## 三、★ 注意事项与坑

### 配置类

**1. 端点在保存时就过 SSRF 校验**（不是在解析时）

`validateParserEngineOutboundURLs()` → `secutils.ValidateURLForSSRF()`
（`internal/handler/tenant.go:1924-1928`）⇒ **不在 `SSRF_WHITELIST` 会「保存就报错」**。
`10.168.1.110` 已在白名单（`deploy/deploy-wkj-dev.sh:256`）。

**2. 「测试连接」和引擎可用状态会假阳性 —— 不能当验收判据**

`PingPaddleOCRVL` 只发 `GET {endpoint}/layout-parsing`，判据是 **状态码 < 500**
（`paddleocr_vl_converter.go:281-292`，注释原文 *"an empty GET should still produce a
routed HTTP response (e.g. 404/405)"*）。
本服务**只暴露 POST** ⇒ 探针拿到 **405 却判「可用」**（实测：一次页面加载触发 6 次 405）。
⇒ **绿灯只说明「服务在且不是 5xx」。验收必须真上传一份文件看落库分块。**

**3. 引擎「可用」由「端点是否配置」决定，不是连通性**

端点为空的默认态是 `Available=false`，写上端点立刻 `true`。

**4. 服务端为准 —— 抽屉里有些勾选是无效的**

| 参数 | WeKnora 发 | 服务端实际 | 说明 |
|---|---|---|---|
| `useSealRecognition`（印章） | `true` | **false** | 显存约束，服务端固定关 |
| `useChartRecognition`（图表） | 勾了也无效 | **false** | 同上 |
| `useDocOrientationClassify` / `useDocUnwarping` | `false` | **true** | 扫描件正需要矫正 |

**勾选不会改变服务端行为** —— 这是有意的（资源策略由服务端定），不是 bug。

**5. OCR 模型 v6 是**我们显式指定的**，不是产线默认**

产线默认是 `PP-OCRv5_server`。权重缓存目录里 `PP-OCRv5_server_*` 与
`PP-OCRv6_medium_*` **并存** ⇒ **别看到 v5 权重在就以为它在跑**。
核对方法：容器日志里的 `Creating model: ('PP-OCRv6_medium_det'…)`，
或反查日志里 `PP-OCRv5` 是否**零命中**。

> 可核对性缺口：`/api/health` **不回显 OCR 模型名** ⇒ 只能翻日志。

**6. 队列容量要开大 —— 429 会让 WeKnora 直接失败**

WeKnora 侧只给 **1000s 超时、没有任何 429 重试逻辑**（`paddleocr_vl_converter.go:21`）
⇒ **收到 429 = 该文档解析失败**。
而串行执行下**排队不增加显存** ⇒ 服务端队列容量取 **16**（宁可排队不可拒绝）。

### 行为类

**7. 它不区分扫描件 ——「一刀切」**

服务端**不看**本页有无文本层（PaddleX 的 PDF reader 只渲染，不抽文本层）
⇒ 该库**所有 PDF**（含带文本层的电子版）都走 OCR。

**8. 引擎选择粒度只到「按文件类型」，不能按文档性质分流**

`ResolveParserEngineRule`（`internal/types/knowledgebase.go:340-353`）只比对扩展名。
⇒ 要「电子版库走 A、扫描件库走 B」只能**按库分开建**。

**9. 图片会被静默丢弃**（若无 `![]()` 引用）

WeKnora 只提取「markdown 正文里有引用」的图片（`paddleocr_vl_converter.go:216-225`，
匹配不到就 `continue`，**不报错**）。
实测：38 页样本 `images=35 → 0`，那 35 张是**表格区域的截图**（键名 `img_in_table_box_*`），
而**同表内容已以 HTML 在正文里** ⇒ 本次不损失信息。
⚠️ 但**真插图（图表/照片）同样会被丢弃**，且下游多模态阶段不会再补 ⇒ 插图彻底消失。

**10. 跨页拼接发生在 WeKnora 侧，改不了**

`paddleocr_vl_converter.go:211` = `strings.Join(texts, "\n\n")`
⇒ `\n\n` 即段落边界，**跨页断句会正好落在下游切分点上**。
该文件是官方文件（AGENTS.md 禁改）⇒ 任何改善只能落在 110 服务侧。

### 不支持的能力（无对应参数，不是 bug）

`mergeTables`（跨页表格合并）、`restructurePages`（跨页重构）、
`relevelTitles`（标题层级重排）—— 这三项是 **PaddleOCR-VL** 的能力，PP-StructureV3 没有。
（WeKnora 请求里它们为 `true`，但服务端会忽略。）

### 显存与共卡

**11. 常驻会涨到峰值附近**（见 §一）—— 排查「显存怎么少了」时先想到这条。

**12. 与服务串行** —— 并发请求会排队（不报错），大文档排队久属正常。

---

## 四、能力边界（含实测结论）

### 4.1 表格长文本单元格会被按「视觉行」拆行

SLANeXt 的 row 边界按视觉行切 ⇒ 单元格内换行的长文本被切成多行，
**一句话跨行被切开**，下游会切成多个 chunk。
（对比：含表格整页的识别本身是好的 —— HTML 表格 + `rowspan` 都正确。）

### 4.2 ★ 跨页表格「每页各自带表头」**对 RAG 反而有利**

| | 对检索的影响 |
|---|---|
| **现状**（不合并：每页一块、各带表头） | ✅ 每块**自解释** —— 命中任意一块都能看懂列含义 |
| 若合并成长表 | ⚠️ 下游按长度切后**只有首块有表头** ⇒ 后面的块看不懂列含义 |

⇒ 在**面向检索**的用途下，现状可能优于合并。
（若目的是生成"人能读的完整文档"，则相反。）

### 4.3 ★ 混合 PDF：不需要「逐页辨别」（实测结论）

**背景**：实际业务 PDF 常混合（如 1/3/5 页文字层 + 2/4/6 页图片）。

**两条路的实测行为**：

| | 文字层页 | 图片层页 | 页码 |
|---|---|---|---|
| `builtin`（WeKnora 原生） | 保留文本层原文（**会留页码**） | 渲染成 JPEG → 交 Go 侧 **VLM** OCR | **保留**（成噪声） |
| **PP-StructureV3** | 渲染 → PP-OCRv6 OCR | 渲染 → PP-OCRv6 OCR | **剔除** |

> `builtin` 的 `PDFParser` **本身就是逐页分流的实现**（文件头原文
> *"Per-page router … Hybrid documents interleave both in reading order"*，
> 判页看「图像面积覆盖率 + 文本长度」）。实测：6 页混合样本的图片槽**正好命中 2/4/6 页**。
> **「辨别能力」在 `builtin` 里，不在 PP-StructureV3。**

**关键数据：文字层页走 PP-StructureV3 的损失 = 零**

取电子版前 3 页对比「文本层原文」vs「PP-StructureV3 输出」：
去空白后 **1336 字 vs 1333 字，相似度 99.438%**，
差异 **5 处且全是**「页码被剔除」+「`##` 标题标记被加入」⇒ **正文一字不差**。

**⇒ 结论：不做「逐页辨别」。** 理由：

- 收益只剩**速度**（0.74 s/页 → 毫秒级）
- 代价是**同一文档两种结构来源**（文字页无 `block_label`/无标题层级）+ 文字页**页码变噪声**
- 更干净的划分是**按库分**：电子版库走 `anydoc`/`builtin`，扫描/混合库走本服务

---

## 五、已搁置的路径：docreader + PP-OCRv6（markitdown 路径）

另一条路：在 docreader 里挂一个 converter，把 `markitdown` 引擎的 PDF 交给 110 的
PP-OCRv6 单图 OCR 服务做 OCR。

**现状：已搁置。** 它依赖的 `pp-ocr-v6-gpu-api`（36741）容器**已删除**
⇒ 那条路会按 `PPOCR_FALLBACK=true` **静默降级**成「markitdown 内置 PDF 转换」（不报错）。
⚠️ 而 docreader 里那处**官方文件改动仍在**（`markitdown_parser.py` 注册 converter），
细节与恢复方式见 `WeKnora-docreader接入PP-OCRv6方案.md`。

---

## 六、权威记录在哪

| 要看什么 | 去哪 |
|---|---|
| 服务实现 / 设计 / 运维与坑（**权威**） | `110:/mnt/docker-data/docker-deploy/pp-structure-v3/` → `my-docs/` |
| ★ **同机新服务 MinerU 4.0.6**（`36743`） | `MinerU-接入与运维（南宁110）.md`（本目录） |
| 为什么选它（选型依据） | `WeKnora-扫描件PDF解析质量对比与选型.md` |
| 解析引擎的通用机制（引擎列表从哪来 / 能否配 endpoint） | `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md` |
| 已搁置的 docreader 路径 | `WeKnora-docreader接入PP-OCRv6方案.md` |

> 服务是**独立 git 仓库**，提交用 `git -c user.name=wkj -c user.email=wkj@local commit`。
> ⚠️ 该机器上 `/opt/docker-deploy` 是软链 → `/mnt/docker-data/docker-deploy`；
> 且 **`/mnt` 是文件系统边界**，从别处 `cd` 进不去。

---

## 七、★ 停用与恢复（2026-09-23）

**为什么停**：同机上新部署了 **MinerU 4.0.6**（`36743`，见同目录
`MinerU-接入与运维（南宁110）.md`）。单卡 12 GB 上 MinerU 常态占 6.9 GiB、
峰值 8.7 GiB ⇒ 与本服务（常态 4.2 GiB）**无法共存**，故停本服务让出显存。

**影响面（已核实，非推断）**：111 侧 WeKnora 的**正式库不受影响** ——

| 库 | 解析引擎 |
|---|---|
| 正式库（财政领域 / 预算执行常态化审查等） | `anydoc` |
| 测试库 `wkj-ppsv3-验证`、`测试1` | `paddleocr_vl` ← **仅这两个** |

⇒ 停用只影响那两个测试库；正式库解析链路无变更。

**容器状态**：`Exited (143)`；`restart: unless-stopped`
⇒ **宿主机重启也不会自行拉起**，需显式恢复。

**恢复命令**：

```bash
cd /mnt/docker-data/docker-deploy/pp-structure-v3 && docker compose up -d
```

**恢复后需注意**：显存账本要重算（届时 MinerU 若仍在跑，两者合计 11.1 GiB 常态、
峰值可到 12.9 GiB ⇒ **超卡**）。恢复前应先停 MinerU 或下调其
`--gpu-memory-utilization`。
