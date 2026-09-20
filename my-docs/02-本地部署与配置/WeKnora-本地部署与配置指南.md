# WeKnora 本地部署与配置指南

> 面向：使用本机 Docker 跑起来的 WeKnora，需要自己配置大模型与 OCR 的人
> 部署方式：Docker Compose（本项目根目录）｜容器组名：`weknora`
> 文档日期：2026-09-20

---

## 〇、先看这里：这份文档怎么用

**部署已经做完了**，你现在只需要做两件事：

| 步骤 | 要做的事 | 在哪做 | 花费时间 |
|---|---|---|---|
| 第 1 步 | 注册账号、登录 | 浏览器打开 `http://localhost` | 2 分钟 |
| 第 2 步 | 配 **对话模型 + 向量模型** | 网页「设置 → 模型管理」 | 5 分钟 |
| 第 3 步（按需） | 配 **OCR**（要处理扫描件才需要） | 网页「设置 → 模型管理 / 解析引擎」 | 5 分钟 |

**关键提醒**：第 2 步里的 **向量模型（Embedding）是必须配的**。没有它，上传的文档无法入库、也搜不出结果——很多人会以为"配了对话模型就能用了"，其实不是。

---

## 一、部署结果速览

### 1.1 访问地址

| 用途 | 地址 |
|---|---|
| **网页界面（日常用这个）** | http://localhost |
| 后端 API（程序调用用） | http://localhost:8080/api/v1 |
| 健康检查（排查用） | http://localhost:8080/health |

### 1.2 容器与项目名

所有容器都属于 Docker 项目 **`weknora`**（这就是"组名"）：

```
网络：weknora_WeKnora-network
数据卷：weknora_postgres-data / weknora_data-files / weknora_docreader-tmp
```

**容器名**（实测，注意首字母是大写 `W`）：

| 容器名 | 作用 | 说明 |
|---|---|---|
| `WeKnora-frontend` | 网页界面 | 就是浏览器访问的那个 |
| `WeKnora-app` | 后端主程序 | 业务逻辑、检索、回答都在这里 |
| `WeKnora-docreader` | **文档解析服务** | PDF / Word / Excel 的解析都在这里做 |
| `WeKnora-postgres` | 数据库 | 存文档、分块、向量 |
| `WeKnora-redis` | 队列与缓存 | 后台任务调度 |

> **为什么容器名不是 `weknora-app` 而是 `WeKnora-app`？**
> `docker-compose.yml` 里对每个服务写死了 `container_name: WeKnora-xxx`，这个设置**优先于**项目名前缀。项目名 `weknora` 仍然生效，体现在**网络名和数据卷名**上（见上）。
> 也就是说：**"组"确实叫 `weknora` 了，但容器名沿用了官方的 `WeKnora-` 前缀。**
> 如果你要求容器名也严格改成 `weknora-xxx`，需要编辑 `docker-compose.yml` 里 5 处 `container_name`——代价是以后 `git pull` 更新官方代码时这一处会冲突。**建议保持现状**，识别上没有任何歧义。
>
> 因为统一在 `weknora` 项目下，以后运维只要记住一条：在项目目录里直接执行 `docker compose xxx` 即可，**不用加 `-p`**。

### 1.3 关键配置（已自动生成，一般不用改）

配置文件是项目根目录的 **`.env`**（已被 git 忽略，不会进版本库）。为安全起见，密码与密钥都是随机生成的，**文件里不要外发**。

| 配置项 | 值 | 说明 |
|---|---|---|
| 数据库账号 | `postgres` / 随机密码 | 数据库名 `WeKnora` |
| Redis 密码 | 随机 | — |
| JWT 密钥 | 随机（64 位） | 登录令牌签名 |
| 系统加密主密钥 | 随机（32 位） | **重要**：加密模型 API Key 等敏感信息，丢失后已存的密钥全部无法解密 |
| 文档存储方式 | `local` | 存在 Docker 数据卷里 |
| 检索引擎 | `postgres` | 用 ParadeDB（自带中文分词 + 向量） |
| 开放注册 | 允许 | 方便你注册第一个账号 |
| **SSRF 白名单** | `host.docker.internal,localhost,127.0.0.1` | **见第五节，这个很关键** |

### 1.4 部署验收记录（实测数据）

以下是部署完成后**实际跑出来的结果**，不是"应该没问题"：

| 检查项 | 实测结果 |
|---|---|
| 容器状态 | 5 个全部 Up；`app` / `docreader` / `postgres` 通过健康检查（healthy） |
| Docker 项目名 | `weknora` ✓ |
| 网络 | `weknora_WeKnora-network` |
| 数据卷 | `weknora_postgres-data`、`weknora_data-files`、`weknora_docreader-tmp` |
| 后端健康检查 | `GET http://localhost:8080/health` → **HTTP 200**，响应 `{"status":"ok"}` |
| 前端页面 | `GET http://localhost/` → **HTTP 200**，页面标题 `WeKnora` |
| 数据库自动迁移 | ✓ 自动完成，共 **70 张表**；`tenants`、`users`、`knowledge_bases`、`knowledges`、`chunks`、`models`、`embeddings` 均存在 |
| SSRF 白名单 | ✓ 已确认写入 **app 与 docreader 两个容器内部** |
| CPU 架构 | Apple Silicon（arm64），五个核心镜像均有原生 arm64 版本，**未使用 Rosetta 模拟** |
| API 鉴权 | 所有业务 API 未登录时返回 **401**，需登录获取 Token 或 API Key 后调用 |

**一个部署时踩到的坑，特别记录（你以后会用到）：**

> 我先创建了容器，之后才往 `.env` 里补 `SSRF_WHITELIST` —— 结果**白名单没生效**，容器内该变量仍是空的。
> 原因是 `docker compose up -d` 在**命令启动的那一刻**就读取了 `.env`，之后修改 `.env` 不会影响已创建的容器。
> 执行 `docker compose up -d app docreader` 重建后才生效。
>
> **规律：只要改了 `.env` 里的任何一项，就必须执行 `docker compose up -d <服务名>` 重建容器**，光重启（`restart`）不够。

---

## 二、第 1 步：注册并登录

1. 浏览器打开 **http://localhost**
2. 首次访问会跳到**注册页**，填邮箱 + 密码注册
3. 注册完自动进入系统

> 提示：本地用建议把密码设简单点，反正只有你自己访问。
> 如果以后不想让人注册，把 `.env` 里的 `DISABLE_REGISTRATION` 改成 `true` 再重启即可。

---

## 三、第 2 步：配置模型（必做）

### 3.1 操作入口

网页左下角进入 **平台 → 设置（Settings）**，在左侧列表里找到：

| 设置项 | 中文名 | 在这里做什么 |
|---|---|---|
| `models` | **模型管理** | 添加 LLM / 向量 / 重排 / 多模态模型 |
| `parser` | **解析引擎** | 配置外部 OCR 服务（第 4 节） |

点进「模型管理」后，点 **「+ 添加模型」**，会弹出一个表单。

### 3.2 表单怎么填（通用）

| 字段 | 填什么 |
|---|---|
| **模型类型** | 见下表，对话选 `KnowledgeQA`，向量选 `Embedding` |
| **来源** | 远程 API 选 `remote`；Ollama 等本机模型选 `local` |
| **服务商** | **不确定就选 `自定义 (OpenAI兼容接口)`** ← 万能选项，见下 |
| **名称** | 模型 ID，例如 `qwen-plus`、`gpt-4o-mini`、`bge-m3` |
| **Base URL** | 服务的接口地址，OpenAI 兼容的一般以 `/v1` 结尾 |
| **API Key** | 你的密钥 |

**关于「服务商」怎么选：**

- 你的模型服务如果提供的是 **OpenAI 兼容接口**（绝大多数自建服务、vLLM、Ollama、one-api、new-api 都是）→ 直接选 **`自定义 (OpenAI兼容接口)`**，只填 Base URL + Key + 模型名就行，不挑服务商。
- 用公有云的官方接口（阿里云百炼、智谱、火山、硅基流动等）→ 选对应厂商名，能获得更好的兼容性。

### 3.3 必配清单

| 顺序 | 模型类型 | 是否必须 | 作用 | 不配会怎样 |
|---|---|---|---|---|
| 1 | **`Embedding`（向量）** | **必须** | 把文字转成向量，用于检索 | 文档传上去也无法入库、搜不出东西 |
| 2 | **`KnowledgeQA`（对话）** | **必须** | 生成回答 | 能检索到内容，但无法生成答案 |
| 3 | `Rerank`（重排） | 建议 | 对检索结果重新排序，提升准确率 | 结果质量下降，但仍能用 |
| 4 | `VLLM`（多模态） | 按需 | 图片 / 扫描件识别（见第 4 节） | 扫描件、图片里的文字读不出来 |
| 5 | `ASR`（语音） | 按需 | 音频转文字 | 音频文件无法处理 |

### 3.4 ⚠️ 向量模型的「维度」必须填对

添加 `Embedding` 模型时，表单里会有一个 **维度（dimension）** 字段。**这个值必须和模型实际输出的维度一致**，填错会导致入库成功但检索结果莫名其妙。

常见模型的维度：

| 模型 | 维度 |
|---|---|
| `bge-m3` | 1024 |
| `bge-large-zh` | 1024 |
| `nomic-embed-text` | 768 |
| `text-embedding-3-small` | 1536 |
| `text-embedding-3-large` | 3072 |
| 通义 `text-embedding-v3` | 1024 |

> 拿不准就先查你所用模型的说明文档。填错的典型症状：文档能入库，但问答怎么都检索不到相关内容。

### 3.5 用命令行配置（可选，适合批量 / 自动化）

**日常还是推荐用界面配**（3.1～3.4 节更直观）。这一节适合需要批量初始化、或把配置写进自动化脚本的场景。

#### 第一步：先拿凭证

所有 API 都需要认证（未登录一律返回 `401`）。最省事的方式是用你注册的账号换一个 token：

```bash
curl -X POST 'http://localhost:8080/api/v1/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"email":"你的邮箱","password":"你的密码"}'
```

返回内容里会有 `token` 字段（形如 `eyJhbGciOi...`）和一个 `tenant.api_key`。后续请求带上：

```
-H "Authorization: Bearer eyJhbGciOi..."
```

> **给程序长期调用的话，建议另外去界面创建一个「作用域 API Key」**——它可以限定"只能访问哪几个知识库、只能用哪些能力"，比直接拿账号 token 去调安全得多。入口在 **平台 → 集成**（API 集成设置）或 **平台 → 系统管理** 下的 API Key 管理。

#### 第二步：配模型

```bash
# 配对话模型
curl -X POST 'http://localhost:8080/api/v1/models' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer 你的token" \
  -d '{
    "name": "qwen-plus",
    "type": "KnowledgeQA",
    "source": "remote",
    "parameters": {
      "base_url": "http://192.168.1.50:8000/v1",
      "api_key": "sk-xxx",
      "provider": "generic"
    }
  }'

# 配向量模型（注意 dimension 要与模型一致）
curl -X POST 'http://localhost:8080/api/v1/models' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer 你的token" \
  -d '{
    "name": "bge-m3",
    "type": "Embedding",
    "source": "remote",
    "parameters": {
      "base_url": "http://192.168.1.50:8000/v1",
      "api_key": "sk-xxx",
      "provider": "generic",
      "embedding_parameters": { "dimension": 1024 }
    }
  }'
```

配完可以在「模型管理」列表里点 **测试** 按钮验证连通性。

---

## 四、图片型 PDF（扫描件）的 OCR 怎么配

### 4.1 先分清两条完全不同的路

这是最容易搞混的地方——WeKnora 处理扫描件有**两种机制**，用途不同：

| | **路线 A：多模态模型** | **路线 B：外部解析引擎** |
|---|---|---|
| 本质 | 项目**自带的扫描件 OCR** 流程 | 把整篇 PDF **外包**给专业解析服务 |
| 怎么工作 | 把扫描页转成图片，交给多模态大模型"看图识字" | 整个文件交给 MinerU / PaddleOCR-VL 解析 |
| 在哪配 | 设置 → **模型管理**（加一个 `VLLM` 类型模型） | 设置 → **解析引擎** |
| 适合 | 印刷体扫描件、发票、普通公文 | 复杂表格、公式、多栏排版、竖排 |
| 额外部署 | 无（只要有个多模态模型 API） | **需要自己另外部署服务** |

> **建议**：先只配路线 A。它不需要额外部署任何东西，能解决大部分扫描件。等遇到"表格错位、公式乱掉"再上路线 B。

### 4.2 路线 A：配多模态模型（推荐先做这个）

**第 1 步 · 加模型**

设置 → 模型管理 → 添加模型：

| 字段 | 填什么 |
|---|---|
| 模型类型 | **`VLLM`（多模态）** |
| 来源 | `remote` |
| 服务商 | `自定义 (OpenAI兼容接口)` |
| 名称 | 你的多模态模型名，例如 `qwen-vl-max`、`gpt-4o`、`internvl2` |
| Base URL | 多模态服务的地址（OpenAI 兼容，以 `/v1` 结尾） |
| API Key | 对应密钥 |

> 这个模型必须**真的支持图片输入**。纯文本模型（如 `deepseek-chat`）填在这里没用，上传扫描件会报错或识别为空。

**第 2 步 · 在知识库里打开多模态**

1. 进入某个知识库 → **解析设置**
2. 确认 **多模态（图像处理）** 是开启状态
3. 为 `pdf` 选择解析引擎为 `builtin`（内置）

**第 3 步 · 上传扫描件试试**

上传一个扫描版 PDF，观察：

- 文档状态应该依次经过 **解析中 → 处理中 → 已完成**
- 点开文档的**分块列表**，应该能看到识别出来的文字（这些文字存在 `image_ocr` 类型的分块里）

**第 4 步（可选）· 识别效果不好时调参数**

在 `.env` 里可以调这几个（改完要重启 app）：

| 参数 | 默认 | 作用 |
|---|---|---|
| `DOCREADER_PDF_RENDER_DPI` | `200` | 扫描页转图片的清晰度。**密集中文或小字建议调到 300** |
| `DOCREADER_PDF_FORCE_SCANNED` | `false` | 明明有文字层但识别不出来时，设为 `true` 强制按扫描件处理 |
| `DOCREADER_PDF_SCAN_IMAGE_RATIO` | 内置默认 | 判定"这页是扫描页"的图片占比阈值 |
| `DOCREADER_PDF_SCAN_MIN_CHARS` | 内置默认 | 判定扫描页的最小字符数（兜底） |

### 4.3 路线 B：接外部解析引擎

设置 → **解析引擎**，页面会列出所有可用引擎。点进某个引擎，右侧弹出配置表单。

**可选的 4 个外部引擎：**

#### ① `mineru` —— 自建 MinerU 服务（推荐内网用）

| 字段 | 说明 |
|---|---|
| 服务地址（Endpoint） | 你自建 MinerU 的地址，例如 `http://192.168.1.60:8000` |
| Backend | 解析后端，可选：`pipeline`（默认，稳）、`vlm-auto-engine`、`vlm-http-client`、`hybrid-auto-engine`、`hybrid-http-client` |
| vLLM 服务地址 | 当 Backend 选 `vlm-http-client` 等时才需要填 |
| 解析方式 | `auto`（自动）/ `ocr`（强制 OCR）/ `txt`（只取文本层） |
| 识别选项 | 勾选「公式识别」「表格识别」 |
| 语言 | 如 `ch`、`en` |

#### ② `mineru_cloud` —— MinerU 云端 API

| 字段 | 说明 |
|---|---|
| API Key | MinerU 云服务的 Key（**必填**） |
| Model Version | `pipeline` / `vlm` / `MinerU-HTML` |
| 识别选项 | 公式、表格 |
| 语言 | — |

> 注意：云端 API 意味着文档要传到外网，**内网环境不要用这个**。

#### ③ `paddleocr_vl` —— 自建 PaddleOCR-VL 服务

| 字段 | 说明 |
|---|---|
| 服务地址（Endpoint） | 必填。例如 `http://192.168.1.61:8080`（PaddleOCR-VL pipeline 服务的 `/layout-parsing` 接口） |
| 识别选项 | **印章识别**、**图表识别**（PaddleOCR-VL 的特色能力） |

> 这个引擎对**中文文档**和**印章 / 图表**特别有用——扫描的公章、组织架构图能识别出来。

#### ④ `paddleocr_vl_cloud` —— PaddleOCR-VL 云端

| 字段 | 说明 |
|---|---|
| Token | 云服务 Token（**必填**） |
| Model | 例如 `PaddleOCR-VL-1.6` |
| 识别选项 | 印章、图表 |

> 同样需要外网，内网不用。

**配完之后怎么让它生效？**

外部引擎是**按知识库**（或单次上传）指定的，不是全局开关：

- **按知识库指定**：进入知识库 → 解析设置 → 为 `pdf` 选择对应引擎
- **按单次上传指定**：上传时会弹确认框，可在里面指定本次用哪个引擎解析
- **已入库的文档想换引擎重解析**：在文档上点「重新解析」，或批量选中文档后「批量重新解析」

### 4.4 两句话总结

- **只想让扫描件出文字** → 路线 A，配一个多模态模型就行，不用装别的东西。
- **要啃复杂版面（表格 / 公式 / 印章）** → 路线 B，自己部署 MinerU 或 PaddleOCR-VL，然后在知识库里把它指定为 PDF 的解析引擎。

---

## 五、⚠️ 配模型时最容易踩的坑：SSRF 白名单

### 5.1 现象

配好模型点保存或测试，报错，提示类似：

```
400  base_url failed SSRF validation
```

或者地址明明能 ping 通，就是连不上。

### 5.2 原因

WeKnora 有一层安全防护（防 SSRF 攻击），**默认会拦截**所有指向内网、本机的地址：

- `localhost`、`127.0.0.1`
- 局域网段 `192.168.x.x`、`10.x.x.x`、`172.16~31.x.x`
- 容器访问宿主机的 `host.docker.internal`

也就是说：你的模型服务如果跑在**本机或局域网**里，默认是连不上的——必须把它加进白名单。

### 5.3 怎么解决

**第 1 步**：编辑项目根目录的 `.env`，找到 `SSRF_WHITELIST=` 这一行，把你模型服务的地址加进去（逗号分隔，多个用逗号隔开）：

```bash
# 模型在本机（用 Ollama / vLLM 之类的就用这个）
SSRF_WHITELIST=host.docker.internal,localhost,127.0.0.1

# 模型在局域网另一台机器
SSRF_WHITELIST=host.docker.internal,192.168.1.50

# 多个地址
SSRF_WHITELIST=host.docker.internal,192.168.1.50,192.168.1.60
```

> 支持写法：精确域名（`api.internal`）、通配域名（`*.corp.example`）、CIDR 网段（`172.16.0.0/12`）、IP。
>
> **本次部署已经预置**了 `host.docker.internal,localhost,127.0.0.1`。如果你用局域网地址，只需**追加**那个 IP。

**第 2 步**：重启 app 容器让配置生效：

```bash
cd <项目目录>
docker compose up -d app
```

> 只改模型配置**不用**重启；一改 `.env` 就必须重启，因为环境变量只在容器启动时读取。

### 5.4 顺带说明

这层防护是**好东西**，不要在公网环境图省事把整段私网都放行。本地开发放开了无所谓，上生产时收紧成"只放行你自己的模型服务地址"。

---

## 六、常见问题排查

| 现象 | 最可能的原因 | 怎么查 |
|---|---|---|
| 上传文档一直卡在「处理中」 | 向量模型没配 / 配错 | 设置 → 模型管理，看 Embedding 是否有值、能否测试通过 |
| 文档入库成功，但问答检索不到 | ① 向量维度填错 ② 检索阈值过高 | ① 核对维度 ② 知识库检索设置里调低相似度阈值 |
| 答非所问、答案空泛 | 没配重排模型，或分块不合理 | 加 `Rerank` 模型；调整知识库的分块大小 |
| 保存模型时报 SSRF 错误 | 白名单没加 | 见第五节 |
| 扫描件传上去没有任何文字 | 多模态模型没配 | 设置 → 模型管理，确认有 `VLLM` 类型模型；见第 4.2 节 |
| 网页打不开 | 前端容器没起 | `docker compose ps` 看状态；`docker compose logs frontend` 看日志 |
| 接口 502 | 后端还在启动 | 后端首次启动要建表，等 1~2 分钟；`curl http://localhost:8080/health` |

**看日志的通用方法**：

```bash
cd <项目目录>
docker compose logs -f app          # 后端日志（最常看）
docker compose logs -f docreader    # 文档解析日志（上传失败时看）
docker compose logs --tail=100 frontend
```

---

## 七、日常运维命令

在项目根目录执行（项目名已在 `.env` 里固定为 `weknora`，不用加 `-p`）：

```bash
docker compose ps                    # 查看所有容器状态
docker compose logs -f app           # 跟踪后端日志
docker compose restart app           # 重启后端
docker compose up -d app             # 改了 .env 后重建后端
docker compose stop                  # 停止（保留数据）
docker compose start                 # 启动
docker compose down                  # 停止并删除容器（数据卷保留）
docker compose down -v               # ⚠️ 连数据一起删，文档全没，慎用
```

**数据在哪？**

文档、向量、账号都在 Docker 数据卷里，名字以 `weknora_` 开头：

```bash
docker volume ls | grep weknora
```

要备份就备份这几个卷（重点是 `weknora_postgres-data` 和 `weknora_data-files`）。

---

## 八、附录：本次部署做了什么改动

| 文件 | 改动 |
|---|---|
| `.env` | **新建**（从 `.env.example` 复制后填值）。① 生成随机密码与密钥：数据库、Redis、JWT、系统加密主密钥；② 设 `COMPOSE_PROJECT_NAME=weknora`；③ 设 `DISABLE_REGISTRATION=false` 方便首次注册；④ 启用 `SSRF_WHITELIST=host.docker.internal,localhost,127.0.0.1` |
| 其他 | 无。`config/config.yaml`、`docker-compose.yml` 保持原样未改 |

**镜像版本**：使用 `latest` 标签（官方未发布 `0.8.0` 标签的镜像）。

**几个部署时确认过的事实**：

- 本机是 Apple Silicon（arm64），五个核心镜像均有 arm64 版本，**不需要** Rosetta 模拟。
- 本机的 80 / 8080 / 5432 / 6379 端口启动前均空闲，未与其它服务冲突。
- 默认只启动 5 个容器；知识图谱（Neo4j）、对象存储（MinIO）、链路追踪（Langfuse）等属于可选组件，**本次未启动**。需要时用 `docker compose --profile <名字> up -d` 单独拉起。

---

## 九、还没做 / 需要注意的

- **本指南的配置操作（第 3～5 节）我没有替你实际操作**——按你的要求，模型由你自己配。上面写的路径与字段名来自源码与官方文档核对，但**UI 实际渲染效果请以你看到的为准**。
- 若你的模型服务在局域网其它机器，**记得把它的 IP 加进 `SSRF_WHITELIST`**，这是最容易卡住的一步。
- 生产/内网正式部署时，请回来收紧 `SSRF_WHITELIST`、并考虑把 `DISABLE_REGISTRATION` 改成 `true`。
