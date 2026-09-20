# WeKnora 生产部署与运维

> **部署分支**：`wkj-dev`
> **部署目标**：nanning-111（`10.168.1.111`）
> **对外端口**：`41200`（网页）/ `41201`（API）
> **部署脚本**：`deploy/deploy-wkj-dev.sh`
> 文档日期：2026-09-20

---

## 〇、一句话上手

在项目根目录执行：

```bash
./deploy/deploy-wkj-dev.sh deploy     # 首次部署 / 完整部署（幂等，可重复跑）
./deploy/deploy-wkj-dev.sh update     # 日常更新（改完代码跑这个）
```

脚本会自己完成：**推代码 → 111 拉取 → 检查环境 → 起容器 → 健康检查**。任一步失败会立刻停下并告诉你原因。

---

## 一、部署架构

### 1.1 代码怎么从本机到 111

```
   ┌─────────────────┐   git push    ┌──────────────────────────┐
   │  本地 Mac        │ ────────────► │ nanning-110 Gitea         │
   │  分支 wkj-dev    │               │ 10.168.1.110:13000        │
   └─────────────────┘               │ wakeagent/WeKnora (私有)  │
                                     └───────────┬──────────────┘
                                                 │ git pull
                                                 ▼
                                     ┌──────────────────────────┐
                                     │ nanning-111 (10.168.1.111)│
                                     │ /mnt/data/weknora         │
                                     │ docker compose ×5 容器    │
                                     └──────────────────────────┘
```

**为什么绕一圈走 Gitea，而不是直接 rsync 到 111？**

- 走 Git：每一次部署都对应一个**明确的 commit**，出问题能精确回滚到某个提交；二开时改动有版本记录。
- 本机 Mac 在 `192.168.55.x` 网段（经 NAT 出去），**无法被 111 反向访问**，直接推文件反而更绕。
- 110 与 111 在同一内网（实测 ping 0.4ms），Gitea 中转这条链路是稳的。

### 1.2 服务器与路径

| 项 | 值 |
|---|---|
| 主机 | `nanning-111`（SSH 别名，已配免密） |
| 系统 / 架构 | Ubuntu 24.04.5 LTS / **x86_64** |
| 资源 | 32 核 / 128 GB 内存 |
| Docker | 29.8.0（**免 sudo 可用**） |
| 代码目录 | **`/mnt/data/weknora`**（机械盘） |
| Docker 存储 | `/mnt/data/docker` + `/mnt/data/containerd`（已迁至机械盘） |
| 数据卷 | `weknora_postgres-data`、`weknora_data-files`、`weknora_docreader-tmp` |

> **为什么放机械盘**：本服务属"IO 要求不高"类，按《存储分层管理标准》R2 走机械盘（默认层），不需要申请 `/srv/fast` 高速层。

### 1.3 端口规划

| 服务 | 容器内端口 | **宿主机（对外）** |
|---|---|---|
| frontend（网页） | 80 | **41200** |
| app（后端 API） | 8080 | **41201** |
| postgres / redis / docreader | — | **不映射**（仅容器网络内互通） |

访问地址：

- 网页：`http://10.168.1.111:41200`
- API：`http://10.168.1.111:41201/api/v1`
- 健康检查：`http://10.168.1.111:41201/health`

> **`41200-41299` 为本项目预留端口段**，后续如需启用可选组件（MinIO / Neo4j / Langfuse 等）按顺序占用 `41202`、`41203`…，不要跳到区间外。

### 1.4 容器清单

| 容器名 | 作用 |
|---|---|
| `WeKnora-frontend` | 网页界面（Nginx） |
| `WeKnora-app` | 后端主程序 |
| `WeKnora-docreader` | 文档解析服务 |
| `WeKnora-postgres` | 数据库（ParadeDB） |
| `WeKnora-redis` | 队列与缓存 |

> 容器名沿用上游 `WeKnora-` 前缀（compose 里写死）。Docker **项目名**为 `weknora`（体现在网络与数据卷名上）。

---

## 二、脚本用法

### 2.1 命令清单

| 命令 | 作用 | 何时用 |
|---|---|---|
| `deploy` | 首次部署 / 完整部署 | 第一次搭环境；或想完整重跑一遍 |
| `update` | 推代码 → 拉取 → 重建容器 | **改完代码日常更新** |
| `build` | 在 111 上构建镜像后重启 | 二开改了 Go / 前端 / docreader 源码 |
| `status` | 查看容器状态 | 想确认在不在跑 |
| `logs [服务]` | 跟踪日志（默认 `app`） | 排查问题 |
| `restart` | 重启容器 | 改了配置想生效 |
| `health` | 健康检查 | 快速确认服务可用 |
| `shell` | 登录 111 并进入部署目录 | 手工排查 |
| `down` | 停止容器（**数据卷保留**） | 临时停服 |

### 2.2 `deploy` 与 `update` 的区别

| | `deploy` | `update` |
|---|---|---|
| 本机前置检查 | ✅ | ✅ |
| 111 环境检查（SSH/docker/挂载） | ✅ | ❌（假定已就绪） |
| 推代码 + 拉代码 | ✅ | ✅ |
| `.env` 处理 | 无则生成，有则保留 | 同左 |
| 拉镜像 + 起容器 | ✅ | ✅ |

**两者都是幂等的**，重复执行结果一致。日常更新用 `update` 就够；不确定环境是否完好时用 `deploy`。

### 2.3 `.env` 的处理规则（重要）

- **首次部署**自动在 111 上生成 `.env`，内含随机生成的数据库密码、Redis 密码、JWT 密钥、系统加密主密钥，以及端口配置。
- **之后再执行脚本，绝不覆盖 `.env`**（里面有生产密钥，覆盖会导致已加密的数据永久无法解密）。
- 要改配置（比如加 SSRF 白名单、调端口），**手工编辑 111 上的 `/mnt/data/weknora/.env`**，然后 `./deploy/deploy-wkj-dev.sh restart`。

### 2.4 二开（改代码）的完整流程

```bash
# 1. 本地改代码
cd /Users/weikejia/CODE/my-agent-group/projects/rag-tools/WeKnora
git checkout wkj-dev
vim internal/xxx.go            # 或改 frontend/ 、docreader/

# 2. 提交
git add -A && git commit -m "feat: 我的改动"

# 3. 部署（build 模式会在 111 上构建镜像）
./deploy/deploy-wkj-dev.sh build
```

> **`build` 模式耗时较长**：Go 编译 + 前端 npm 构建 + docreader 镜像，首次可能 20~40 分钟（111 是 32 核，比本机快）。之后有构建缓存会快很多。

### 2.5 改 `.env` 后的生效方式

| 改了什么 | 怎么生效 |
|---|---|
| `.env` 里的环境变量 | `deploy-wkj-dev.sh restart` **不够**，要 `ssh` 上去 `docker compose up -d app` 重建容器 |
| 代码 | `deploy-wkj-dev.sh build` |
| 只是重启进程 | `deploy-wkj-dev.sh restart` |

> 这是 Docker 的固有行为：**环境变量只在容器创建时读取**，`restart` 不会重新读 `.env`。

---

## 三、配置模型（LLM / Embedding / OCR）

这部分与本地部署完全一致，**详见**：

👉 [`../02-本地部署与配置/WeKnora-本地部署与配置指南.md`](../02-本地部署与配置/WeKnora-本地部署与配置指南.md)

本文件不重复。**生产环境需要特别注意的两点**：

### 3.1 SSRF 白名单（脚本已预置）

脚本生成的 `.env` 已包含：

```
SSRF_WHITELIST=host.docker.internal,localhost,127.0.0.1,10.168.1.110,10.168.1.111
```

含义：允许 app 访问 110 和 111 两台机器上的模型服务。

**如果你的模型服务在别的机器**，编辑 111 上的 `.env` 追加该 IP，然后重建 app 容器。

### 3.2 可用的模型来源（111 同网段现有服务）

| 服务 | 地址 | 说明 |
|---|---|---|
| 110 Ollama | `http://10.168.1.110:11434/v1` | 已有模型 |
| 110 Bonsai 27B | `http://10.168.1.110:11435/v1` | llama.cpp，OpenAI 兼容 |
| 110 ai-gateway | `http://10.168.1.110:13490/v1` | 1Panel AI 网关，需 Key |
| 111 本机 Ollama | `http://host.docker.internal:11434/v1` | 111 上的 Ollama |

> 这些服务都是在跑的，但**具体用哪个、Key 是什么由你决定**——脚本只负责把网络通路（SSRF 白名单）打开。
>
> 注意 110 的 Ollama 是 `OLLAMA_NUM_PARALLEL=1`（单并发槽），长请求会互相阻塞，WeKnora 的批量 embedding 可能与之冲突。生产用建议单独规划一个 embedding 服务。

---

## 四、故障排查

### 4.1 常用命令

```bash
cd /Users/weikejia/CODE/my-agent-group/projects/rag-tools/WeKnora

./deploy/deploy-wkj-dev.sh status          # 容器状态
./deploy/deploy-wkj-dev.sh logs app        # 后端日志（最常看）
./deploy/deploy-wkj-dev.sh logs docreader  # 解析日志
./deploy/deploy-wkj-dev.sh health          # 健康检查
./deploy/deploy-wkj-dev.sh shell           # 登录 111
```

### 4.2 常见问题

| 现象 | 原因 | 处置 |
|---|---|---|
| 脚本报「111 环境检查失败」 | docker 服务停了 / 机械盘没挂 | `ssh nanning-111` 检查 `df -h /mnt/data`、`systemctl status docker` |
| 脚本报「推送失败」 | 110 Gitea 不通 / 凭据失效 | 检查 `~/.git-credentials` 中 `10.168.1.110%3a13000` 条目；Gitea 是否在跑 |
| 拉镜像极慢或失败 | 服务器镜像源问题 | 上一句 `docker compose pull` 手工重试；或检查 `/etc/docker/daemon.json` 镜像源 |
| 后端一直不 healthy | 首次建表慢 / 配置错 | `logs app` 看报错；首次启动建 70 张表需要 1~2 分钟 |
| 网页打不开 | 前端容器或端口问题 | `status` 看状态；确认 `41200` 未被占用 |
| 配模型报 SSRF 错误 | 白名单没加 | 见 3.1 |

### 4.3 端口冲突检查

```bash
ssh nanning-111 'ss -ltn | grep -E "412[0-9][0-9]"'
```

---

## 五、附录：本次部署记录

### 5.1 部署前环境核查（实测）

| 检查项 | 结果 |
|---|---|
| 111 系统 / 架构 | Ubuntu 24.04.5 LTS / x86_64 |
| Docker | 29.8.0，免 sudo 可用，`DockerRootDir=/mnt/data/docker` |
| 端口 41200~41220 | **全部空闲** |
| 磁盘 | `/` 857G 可用；`/mnt/data` 15T 可用 |
| 机械盘哨兵 | `/mnt/data/.mounted` 存在 ✅ |
| 原有 weknora 痕迹 | 无（首次部署） |

### 5.2 代码中转仓库

| 项 | 值 |
|---|---|
| Gitea | `nanning-110`，`http://10.168.1.110:13000`（另一入口 `http://10.168.1.110/`） |
| 仓库 | `wakeagent/WeKnora`（**私有**，本次新建） |
| 推送账号 | `wakeagent`（Gitea 上的 Agent 专用账号） |
| 凭据存放 | 本机 `~/.git-credentials`（键 `10.168.1.110%3a13000`）；111 上已同样登记 |
| 本地 remote 名 | `gitea110` |

### 5.3 部署结果（2026-09-20 实测）

| 检查项 | 结果 |
|---|---|
| 代码就位 | `/mnt/data/weknora`，提交 `3fce01e2`（分支 `wkj-dev`） |
| 容器 | 5 个全部 Up；`app` / `docreader` / `postgres` healthy |
| 网页 | `http://10.168.1.111:41200/` → **HTTP 200**（标题 `WeKnora`） |
| 后端 | `http://10.168.1.111:41201/health` → **HTTP 200** `{"status":"ok"}` |
| 数据库 | 自动建表完成（与本地一致 70 张表） |
| 镜像落盘 | `/mnt/data`（机械盘），符合存储分层要求 |
| 外网访问 | 从本机 Mac 实测可达 ✅ |

镜像体积（供以后评估参考）：

| 镜像 | 大小 |
|---|---|
| `wechatopenai/weknora-docreader:latest` | **5.69 GB** |
| `wechatopenai/weknora-app:latest` | 2.4 GB |
| `wechatopenai/weknora-frontend`(ui):latest | 130 MB |
| `redis:7.0-alpine` | 48.9 MB |
| `paradedb/paradedb:v0.22.6-pg17` | （随 compose 拉取） |

### 5.4 ⚠️ 首次部署踩到的坑（已修复进脚本）

**现象**：首次 `deploy` 时报

```
Container WeKnora-app Error dependency failed to start: container WeKnora-app is unhealthy
```

`postgres` / `redis` / `docreader` 都正常，但 `app` 被判不健康，**连带 `frontend` 启动失败**。

**根因**：

1. `app` 首次启动要在机械盘上**建 70 张表**（外加初始化），耗时超过了 compose healthcheck 的窗口
   ——`start_period: 60s` + `retries: 3 × interval: 30s`，合计约 150s；
2. `frontend` 声明了 `depends_on: app(condition: service_healthy)`；
3. compose 的固有行为：**依赖检查失败后，依赖方会停在 `Created` 状态且不再自动重试**（即使 `app` 随后自行恢复成 healthy）。

结果：`app` 后来自己重启并变成 healthy，但 `frontend` 一直卡在 `Created`，需要手工 `docker compose up -d frontend`。

**修复**（已改进 `compose_up` 函数）：

- **分两阶段启动**：先 `up -d postgres redis docreader app`，脚本轮询等 `app` 变成 healthy（最长 600s），**再** `up -d frontend`。绕开依赖连锁失败。
- **前端兜底**：`health_check` 里若发现前端容器不是 `running`，主动拉起一次。
- **顺带修掉输出噪音**：`docker compose pull` 加 `--quiet`——首次部署时进度条刷了 **57 万字节**日志，把关键信息全淹没了。

**第二次执行 `update` 已验证修复有效**：分阶段启动正常、输出干净、健康检查通过。

---

## 六、待办 / 注意事项

- [ ] **首次部署后建议做的加固**：把 `DISABLE_REGISTRATION` 改为 `true`（注册完管理员账号之后）。
- [ ] **备份策略**：目前数据只在 111 单机机械盘，`/mnt/data` 无备份。数据库（`weknora_postgres-data` 卷）应纳入备份。
- [ ] **`ops/hosts/nanning-111/services.md` 待登记**本服务（端口 41200/41201）。
- [ ] 110 的 Ollama 是单并发槽，若用其做 embedding，需留意与其它调用方的排队冲突。
