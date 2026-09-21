# AGENTS.md —— wkj-dev 二开分支规约

> 本文件是**我们二开层**的规约（官方仓库不含此文件 ⇒ 不与上游冲突）。
>
> **只放约束。** 判断标准：*这条规则不注入，agent 就会做错事吗？* 不会 → 不进本文件。
> 知识、流程、目录说明一律外迁，此处只留一行指针（见文末「指针」）。

## 仓库形态

WeKnora（腾讯开源）的**二开 fork**：工作分支 `wkj-dev`，上游 `upstream/main`，
发布源 `origin`（GitHub fork）与 `gitea` / `gitea110`（内网）。

结构是「**官方层 + 定制层**」物理分离 —— 官方文件保持原样 ⇒ 上游更新时零冲突、自动继承。

**验证口径**：`git diff --name-status upstream/main..HEAD`
当前改动面：**787 新增 / 2 修改 / 0 删除**。

## 硬约束

### 1. 官方文件：除下表 2 个外，一律不得修改

| 允许修改 | 改动性质 | 为什么必须 |
|---|---|---|
| `docker/Dockerfile.app` | 新增**中性**构建 ARG（留空即回落官方行为） | 国内网络：Go / Rust / npm / GitHub 源不可达 |
| `docker/Dockerfile.docreader` | 同上（APT 源） | 同上 |

`docker-compose.yml`、`frontend/`、`Makefile`、`config/` 等**全部官方文件不得修改**。

要改行为时按优先级走：**构建参数 → 环境变量 → 叠加层 → 最后才改文件**。
确实必须改文件时，**同步登记到上表** —— 否则下一个人无从知道合并时要保住什么。

### 2. 前端：只改 `my-frontend/`

- `my-frontend/` 是官方 `frontend/` 的**逐字副本**。判据：
  `diff -rq frontend my-frontend` 的输出，必须恒等于「我们刻意的改动量」，**不得有噪声差异**。
- **不得在副本内新增说明 / 需求文档** —— 会被 `COPY . .` 带进构建，且让 `diff -rq` 从此不为零。
- 源码改动只落在 `my-frontend/`；**`frontend/` 只读**。

### 3. 编排：只改叠加层

- `docker-compose.yml`（官方基底）**一字不动**；全部定制写
  `my-docker/docker-compose.overlay.yml` —— 它是**唯一**需要改的编排文件。
- 合并语义、`!override` 的用法、两个 `-f` 的顺序、`--project-directory` 的必要性：
  **见该文件头注释**（单一事实来源，此处不重复）。
- ⚠️ 最贵的一个坑：漏 `--project-directory` 或颠倒 `-f` 顺序 ⇒ 项目名退化 ⇒
  指向**新建的空数据卷**（数据丢失级）。部署统一走 `deploy/deploy-wkj-dev.sh`，不要手敲。

### 4. 端口：容器组服务号段 `41200`–`41299`

新服务一律从该段分配。`1xxxx`（如 `14100` / `14102`）是容器**直接绑回环的诊断口**，
不属服务号段。现有分配见 `my-docker/README.md` 端口表。

### 5. `.env` 是部署现场状态，不入库

含生产密钥（DB 密码 / JWT / `SYSTEM_AES_KEY`），已被 `.gitignore` 忽略；
模板是仓库根 `.env.example`。**不得把任何密钥写进受版本控制的文件。**

### 6. 新增 dotfile 必须 `git add -f`

根 `.gitignore:2` 的 `.*` 规则会**静默拦下**所有隐藏文件 —— 已踩过一次：
`my-frontend/.dockerignore` 漏提交，导致 111 上的构建行为与本地不一致。
例外白名单在 `.gitignore:4-5`，要长期放行就在那里加。

### 7. 文档归档

新文档放 `my-docs/NN-中文名/`（编号顺延，现有 `01-项目分析` … `07-前端定制方案`）。
**不要另起目录体系**；同一主题只放一处。

## 指针（细节看这里，本文件不重复）

| 主题 | 单一事实来源 |
|---|---|
| 容器组：服务清单 / 端口表 / 用法 | `my-docker/README.md` |
| 我们相对官方改了什么（差异清单） | `my-docker/docker-compose.overlay.yml` 文件头注释 |
| 接入层（TLS / WSS / 证书） | `my-docker/nginx/README.md` |
| 部署 / 构建 / 差异复核命令 | `deploy/deploy-wkj-dev.sh`（脚本自带用法） |
| 定制前端源码 | `my-frontend/` |
| 分析 / 决策 / 验收记录 | `my-docs/` |
