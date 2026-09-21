# AGENTS.md —— wkj-dev 分支项目设定

> 本文件随 agent 启动**自动注入上下文**，故只记**推不出来的项目设定**。
>
> 收录判据（两条都要满足才写进来）：
> **① 无法通过逻辑推理得出** —— 能推出来的不写。
> **② 必须读多个项目文件才能知道** —— 读一两个文件就能得到的，不写。
>
> 论证过程、历史沿革、流程细节、状态快照一律外迁（见文末指针）。

## 出发点

**本仓库是 WeKnora（腾讯开源）的二开 fork**，工作分支 `wkj-dev`，上游 `upstream/main`。
采用「**官方层 + 定制层**」物理分离：**官方文件保持原样** ⇒ 上游更新时零冲突、自动继承。

下面所有约束都从这一条派生 —— 凡是想"直接改官方文件图省事"的念头，都违背它。

## 设定

### 1. 官方文件不得修改

`docker-compose.yml`、`frontend/`、`Makefile`、`config/` 等**一律不许改**。

**唯一例外**（此外无第二个）：`docker/Dockerfile.app` 与 `docker/Dockerfile.docreader`
—— 已加**中性**构建 ARG（留空即回落官方行为），用于国内网络换源。

需要改变行为时按序走：**构建参数 → 环境变量 → 叠加层 → 最后才考虑改文件**。
（核对当前改动面的口径：`git diff --name-status upstream/main..HEAD`）

### 2. 前端：`frontend/` 只读，改动只落 `my-frontend/`

`my-frontend/` 是 `frontend/` 的**逐字副本**。判据是
`diff -rq frontend my-frontend` 的**输出内容**必须恒等于"刻意改动量"。

- **不得在 `my-frontend/` 内新增任何说明 / 需求文档** —— 会让上述 diff 失真，且会被
  `COPY . .` 带进构建。
- 在副本内新增 **dotfile 必须 `git add -f`** —— 根 `.gitignore:2` 的 `.*` 规则会**静默**拦下它。

### 3. 编排只改叠加层

`docker-compose.yml`（官方基底）一字不动；全部定制写
`my-docker/docker-compose.overlay.yml` —— 它是**唯一**需要改的编排文件。
合并语义、`!override`、命令写法见该文件的**文件头注释**。

### 4. 端口：服务端口一律取 `41200`–`41299`

**不论对外还是仅回环**，服务端口都从这个号段取 —— 号段与「是否对外」是两件事。
是否对外另由**绑定地址**决定：**能只绑回环（`127.0.0.1`）的就不对外**。

### 5. `.env` 是部署现场状态，不在版本控制内

位于仓库根，含生产密钥，模板为 `.env.example`。

### 6. 文档归档到 `my-docs/NN-中文名/`

编号顺延（现有 `01-项目分析` … `09-二开现状基线`），**不要另起目录体系**。

### 7. 外部关联仓库放 `my-other-git/`，不入版本控制

别人的 git 仓库（如 `Tencent/BrowserSkill`）clone 到 `my-other-git/<仓库名>/`，
用 **`.git/info/exclude` 排除**（**不是** `.gitignore`）—— 它属「本地参考」而非项目依赖；
构建真正需要时由脚本自行拉取（见 `scripts/build_browserskill.sh`）。

⚠️ exclude 是**本地**配置、不入库 ⇒ 别处 clone 后需自行补这条规则，也不会有该目录。

## 指针

| 要看什么 | 去哪 |
|---|---|
| 容器组：服务清单 / 端口表 / 用法 | `my-docker/README.md` |
| 相对官方改了什么（差异清单） | `my-docker/docker-compose.overlay.yml` 文件头 |
| 接入层 TLS / WSS / 证书 | `my-docker/nginx/README.md` |
| 部署 / 构建 / 差异复核命令 | `deploy/deploy-wkj-dev.sh` |
| 分析 / 决策 / 验收记录 | `my-docs/` |
