# my-docker —— 站点定制层（一个容器组的定义）

## 一、部署形态：**一个容器组**

本目录**不是"另一套编排"**，而是官方编排之上的**叠加层**。两份文件合并后属于
**同一个 compose 项目（`weknora`）、同一个容器组**，一次 `up -d` 起停全部。

| 文件 | 角色 | 上游更新时 |
|---|---|---|
| `docker-compose.yml`（仓库根） | **基底** —— 官方的服务定义，**一字不动** | 自动继承上游新增的 service / 变量 |
| `my-docker/docker-compose.overlay.yml` | **叠加** —— 我们的全部定制 | 我们维护；**唯一需要改的编排文件** |

> **为什么用「基底 + 叠加」而不是"复制一份再改"**：合并语义等价，但官方文件保持原样 ⇒
> 上游更新时零冲突且自动继承，我们的定制也不会散落多处。

### 容器组清单（均为 wkj-dev 分支源码构建）

| 服务 | 来源 | 说明 |
|---|---|---|
| `postgres` · `redis` · `docreader` · `app` · `frontend` | 官方基底 | 本层只改各自的定制项（构建源、端口） |
| **`searxng`** · `searxng-init` | 官方基底（**profile 门控**） | 自带网络搜索，经 `$DC` 的 `--profile searxng` 启用。**引擎清单由站点定制**：`my-docker/searxng/settings.yml`（国内网络只有 bing / 360search 可用，见 `my-docs/14-联网搜索/`） |
| **`neo4j`** | 官方基底（**profile 门控**） | 知识图谱存储（实体 / 关系），经 `$DC` 的 `--profile neo4j` 启用。**容器起来 ≠ 功能开启**：真正的开关是 `.env` 的 `NEO4J_ENABLE`（部署脚本会在缺键时补 `true` 并生成随机密码）。数据落在命名卷 `neo4j-data` |
| **`frontend-wkj`** | **本层新增** | 定制前端，源码 `my-frontend/` |
| **`nginx`** | **本层新增** | 接入层：两个前端的 HTTPS/WSS 统一入口 |

### 对外端口

| 端口 | 指向 | 协议 |
|---|---|---|
| `443` | nginx → 官方前端 | **https / wss**（便捷入口，免带端口） |
| `41200` | nginx → 官方前端 | **https / wss** |
| `41280` | nginx → 定制前端 | **https / wss** |
| `41201` | `app`（后端 API） | http（未纳入 TLS） |

> `41201` 由 `deploy/deploy-wkj-dev.sh` 经 `setkv APP_PORT` **写入部署机的 `.env`**；
> 本机开发的 `.env` 默认仍是 `8080`。两者都走官方 compose 的 `${APP_PORT}:8080`。

两个前端容器**只绑宿主回环** `41211` / `41212`（仅供诊断直连，不对外）
⇒ **"没有 http 前端端口"是结构上的事实，不是约定。**

> 使用取向：**日常主用定制前端**（对外 `:41280`、诊断 `:41212`）；
> **官方前端留作功能对照**（对外 `:41200`、诊断 `:41211`）。

### 内部服务端口（不对外，只绑宿主回环）

| 端口 | 指向 | 说明 |
|---|---|---|
| `41291` | `searxng`（自带搜索） | **已启用**（`deploy-wkj-dev.sh` 的 `$DC` 带 `--profile searxng`）。容器之间访问走容器网络 `http://searxng:8080`，与这个宿主端口无关（它只绑回环、仅用于宿主侧诊断） |
| `41292` | `neo4j` Browser UI | **已启用**（`$DC` 带 `--profile neo4j`）。浏览器访问 `http://127.0.0.1:41292` 查看图谱数据（只能用 SSH 隧道，见下） |
| `41293` | `neo4j` Bolt | 同上。供本机工具（cypher-shell / 桌面客户端）连 `bolt://127.0.0.1:41293`；app 走容器网络 `bolt://neo4j:7687`，**不经过端口** |

> 两个 neo4j 端口都**只绑宿主回环**。要远程查看 Browser UI，用 SSH 隧道：
> `ssh -L 41292:127.0.0.1:41292 <部署机> ` 后访问 `http://127.0.0.1:41292`。
> 账号在 `.env` 的 `NEO4J_USERNAME` / `NEO4J_PASSWORD`（密码由部署脚本首次生成随机值）。

## 二、目录结构

```
docker-compose.yml                      # 官方基底（一字不动，随上游更新）
my-docker/
  ├─ docker-compose.overlay.yml         # ★ 叠加层：全部定制（新增服务 + 覆盖项）
  ├─ README.md                          # 本文件
  └─ nginx/                             # 接入层的配置资产
       ├─ nginx.conf                    #   两个 server 块（443/41200 官方，41280 定制）
       ├─ gen-certs.sh                  #   自签 CA + 服务器证书生成（幂等）
       └─ README.md                     #   接入层详解：部署/信任/验证/排查
my-frontend/                            # 定制前端源码（官方 frontend/ 的逐字副本）
```

**差异清单（改了什么、为什么）** 是单一事实来源，放在
`docker-compose.overlay.yml` 的**文件头注释**里，紧贴被改的代码 ——
这里不重复，避免两处维护。

## 三、用法

```bash
cd <仓库根>
C="docker compose --project-directory . --env-file .env \
     -f docker-compose.yml -f my-docker/docker-compose.overlay.yml"

$C config          # 校验并查看合并结果
$C ps              # 状态
$C logs -f app     # 日志
$C build           # 从源码构建（默认 app / frontend / docreader）
$C up -d           # 启动整个容器组
```

两个 `-f` **必须都给、且顺序不能反**（相对路径以第一个文件的目录为基准；
这里第一个是仓库根的官方文件 ⇒ 基准 = 仓库根 ⇒ 无需改任何相对路径）。

> ⚠️ 漏掉 `--project-directory` 或把 overlay 放前面，都会让 `build.context` /
> bind mount 的解析基准错位 —— 极端情况下项目名退化成别的名字，指向一套**新建的空数据卷**。
> 部署脚本已加项目名断言（必须为 `weknora`）兜底。

**日常不用手敲这串** —— `deploy/deploy-wkj-dev.sh` 已封装：

```bash
./deploy/deploy-wkj-dev.sh deploy     # 首次部署
./deploy/deploy-wkj-dev.sh build      # 二开：从源码构建（让代码生效）
./deploy/deploy-wkj-dev.sh status     # 全部容器状态
./deploy/deploy-wkj-dev.sh compose-diff   # 复核我们相对官方改了什么
```

**日常改代码不必重建镜像** —— 应用代码分四层外置在宿主目录（见第八章），
投递命令各管一层：

| 命令 | 更新哪一层 | 生效方式 |
|---|---|---|
| `push-ui` | `my-frontend/dist` → 前端静态文件 | 立即可见，**无需重启** |
| `push-reader` | `docreader/` → 解析器源码 | 重启 docreader，秒级 |
| `push-app` | `.build/WeKnora` → 后端二进制<br>＋ `migrations/` → 迁移文件（随代码同步） | 重启 app；**新迁移在此刻执行** |

## 四、`.env` 在哪

**仍在仓库根**（`<仓库根>/.env`），不在本目录。

理由：`.env` 含生产密钥（数据库密码、JWT、`SYSTEM_AES_KEY`），已被 `.gitignore` 忽略、
**不能进仓库** ⇒ 它是「部署现场的状态」；`my-docker/` 是「受版本控制的配置」。两者职责分开。
模板见仓库根 `.env.example`。

## 五、定制前端（`frontend-wkj`）

| 项 | 官方前端 | 定制前端 |
|---|---|---|
| 源码 | `frontend/` | **`my-frontend/`**（逐字副本） |
| 镜像 tag | `wechatopenai/weknora-ui` | **`wechatopenai/weknora-ui-wkj`** |
| 容器名 | `WeKnora-frontend` | **`WeKnora-frontend-wkj`** |
| 对外地址 | `https://10.168.1.111:41200/` | **`https://10.168.1.111:41280/`** |
| 容器绑定 | `127.0.0.1:41211`（回环） | `127.0.0.1:41212`（回环） |

后端是同一个（`app`）⇒ **两个前端看到同一份数据**；登录状态不共享（token 按 origin 隔离，
两个地址各登录一次，属浏览器同源策略的正常结果）。

### 为什么副本是「逐字复制」

```bash
diff -r frontend my-frontend     # 应恒等于"你刻意的改动量"，没有噪声
```

这是**以后按需合并官方更新**的基准 —— 所以：

- **源码改动** → 只改 `my-frontend/`
- **编排/说明** → 留在本目录，**不放进副本**（`.dockerignore` 没排除它们，放进去会被
  `COPY . .` 带进构建，且 `diff -r` 从此不为零）
- 副本复制点：`a89a5a2c`（2026-09-23 第 3 轮同步至官方 main；**下次与官方合并时按它对照**）

### 与官方合并的做法（以后按需）

```bash
git log --oneline <复制点>..HEAD -- frontend/    # 官方 frontend 改了什么
git diff --stat <复制点>..HEAD -- frontend/
# 逐项判断：与你的改动冲突 → 手工合并；你没动过 → 直接覆盖
C="docker compose --project-directory . --env-file .env -f docker-compose.yml -f my-docker/docker-compose.overlay.yml"
$C build frontend-wkj && $C up -d frontend-wkj
diff -r frontend my-frontend                     # 复查差异面仍只有你的刻意改动
```

## 六、接入层（`nginx`）

见 **[`nginx/README.md`](nginx/README.md)** —— 端口总表、证书生成与信任、三个入口的验证、
排查清单、以及 2026-09-21 由 `tls` 正名为 `nginx` 的迁移记录。

一句话：BrowserSkill 配对要求非 localhost 必须 `wss`
（`internal/browserskill/manager.go` 的 `pairingEndpoint()`），所以浏览器必须用 `https://` 打开页面 ——
接入层就是为此存在，**两个前端共用同一张自签证书**。

## 七、与上游同步

```bash
./deploy/deploy-wkj-dev.sh compose-diff
```

它会渲染并比对「纯官方」与「官方 + 我们的叠加层」，列出差异。**目的是发现本文件是否过期**：
上游若新增了 service 或改了某个我们也在改的字段，需要逐条判断是否同步。

> 注意：`my-docker/` 已不再是"官方副本"，所以 `compose-diff` 的差异**天然非零** ——
> 它现在的用途是"我们改了什么"的复核，而不再是"应该没有差异"的自检。

## 八、几个必须知道的点

| 事项 | 说明 |
|---|---|
| **两个 `-f` 缺一不可、顺序固定** | 相对路径以第一个 `-f` 的目录为基准；先把官方文件放前面，基准才是仓库根 |
| **`!override` 是替换序列字段的唯一手段** | Compose 对 `ports` / `volumes` 默认**追加**。本层用 `ports: !override` 让官方前端让出 41200。两台实测均支持（本机 v5.1.2 / 111 v5.5.1） |
| **`.env` 的 `FRONTEND_PORT` 已失效** | 被 `!override` 覆盖。对外端口以 `nginx` 为准 |
| **镜像 tag 绝不与官方共用** | `weknora-ui-wkj` 独立；共用会被 `pull` / `build` 互相静默覆盖 |
| **副本里的 dotfile 要 `git add -f`** | 根 `.gitignore:2` 的 `.*` 规则会拦下新文件；官方 `frontend/.dockerignore` 因**早已被跟踪**而豁免，副本是新文件 ⇒ 会被漏掉，导致 111 上**没有 `.dockerignore`**（Docker 只在 context 根找它，不会向上找）。已用 `-f` 纳入。<br>★ 以后在副本里新增任何 dotfile 同样要 `-f`；若允许改官方 `.gitignore`，加一条 `!my-frontend/.*` 更省事 |
| **`package.json.md5` 是失效文件** | 记录值与当前 `package.json` 不符，但全仓无引用、且被 `.dockerignore` 排除 ⇒ 不影响构建。保留它只为与官方一致 |
| **运行时可配只有 4 项** | `MAX_FILE_SIZE_MB` / `MAX_SKILL_BUNDLE_SIZE_MB` / `DEFAULT_LOCALE`（+ `EMBED_BASE_URL` 在 `public/config.js`），其余改动都要动源码 |
| **应用代码分四层外置** | `my-frontend/dist`（前端静态）/ `docreader`（解析器）/ `.build/WeKnora`（二进制）/ `migrations`（迁移文件）。都从宿主目录取 ⇒ **改代码不必重建镜像**，绕开国内构建链。挂载源分两类：**受 git 管理**（`docreader/`、`migrations/`）随 `sync_code` 的 `reset` 更新；**本地产物**（`my-frontend/dist`、`.build/WeKnora`）由 `push-ui` / `push-app` 投递 |
| **迁移外置的两个硬约束** | ① **宿主目录必须存在且非空** —— 迁移器报错会被 `AUTO_MIGRATE` 的 warn 分支吞掉（`container.go` 的 "don't fail startup"）⇒ app 照常 healthy，迁移却**静默不跑**；镜像方式下无此故障面。② **改这四条挂载必须重建容器**（`up -d`，`restart` 不生效）⇒ `push-app` 已内置两处挂载的判据，缺一即自动改走重建 |
