# 应用代码外置方案

> 目标（老魏）：**日常改动只需「推代码 → 111 拉取 → 编译 → 替换」**，不必每次重建镜像 / 容器。
> 适用：南宁 111（开发环境 + 正式数据）

---

## 〇、结论速览

| 应用 | 是否外置 | 改完要做什么 | 量级 |
|---|---|---|---|
| **`frontend-wkj`** | ✅ **已上线** | 本地 `npm run build` → 投递 dist | 分钟级，**无需重启** |
| **`docreader`** | ✅ **已上线** | `sync`（更新源码）→ `restart` | **秒级** |
| `app` | ⬜ 未做 | 需先解决"编译只能在容器内" | 见 §5 |

**关键澄清**：111 宿主上**没有 `go`、没有 `npm`** ⇒ "在 111 上直接编译"不可行。
现有 `build` 之所以能编，是因为它在 **Docker 容器内**编。

---

## 一、链路（现在是这个形态）

| 步骤 | 命令 | 状态 |
|---|---|---|
| 1. 推代码 | `git push gitea110 wkj-dev` | ✅ 有 |
| 2. 111 拉取 | `deploy-wkj-dev.sh sync` | ✅ 有 |
| 3. 编译 | 前端：本地 `npm run build`；docreader：免编译 | ✅ 有 |
| 4. 投递 | `deploy-wkj-dev.sh push-ui` / `push-reader` | ✅ **本轮新增** |
| 5. 生效 | 前端**无需重启**；docreader `restart` | ✅ 有 |

**我们用的"映射目录"不是新建的——就是仓库本身**：
111 上本就有完整 git 仓库，`sync` 已把"push → 110 → 111 拉取"铺好，
产物直接落仓库的 **gitignore 目录**即可（`my-frontend/dist` 已被忽略 ⇒ `git reset --hard` 不会动它）。

---

## 二、落地方式

### 2.1 overlay 新增两处挂载

```yaml
  frontend-wkj:
    volumes:
      - ./my-frontend/dist:/usr/share/nginx/html      # ★ 不能加 :ro
  docreader:
    volumes:
      - ./docreader:/app/docreader:ro
```

| 要点 | 原因 |
|---|---|
| 前端**不能加 `:ro`** | `docker-entrypoint.sh` 启动时要往此目录写运行时配置 `config.js`，只读挂载会让容器**直接启动失败** |
| docreader 可以 `:ro` | 依赖在 `/app/.venv`，与源码目录 `/app/docreader` **分开**（`Dockerfile.docreader` 的 `VIRTUAL_ENV`）⇒ 挂源码不遮依赖 |
| 前端挂载后**无需重启** | 内层 nginx 直接读文件 ⇒ 投递即生效 |

### 2.2 投递命令（`deploy/deploy-wkj-dev.sh`）

| 命令 | 做什么 |
|---|---|
| `push-ui` | 本地 `npm run build`（显式注入 `VITE_FRONTEND_COMMIT`）→ `rsync dist` → 立即可见 |
| `push-reader` | `sync_code` + `restart docreader` |
| `up` | **只按当前编排重建容器**（不 pull / 不 build）—— 让编排改动生效 |

**`up` 为什么必需**：改编排后要让它生效，但原有三个子命令都绕不开镜像操作 ——
`update` 检测到本地构建镜像会**自动改走 build**（16 分钟），`build` 更慢，
`sync` 又不重建容器。`up` 模式下 compose 只重建 **config-hash 真正变了**的服务，
所以 app 段没改就**不会被动到 ⇒ 也不会触发数据库迁移**。

---

## 三、实施记录（2026-09-21）

| 步骤 | 结果 |
|---|---|
| 填充宿主目录 | 从现有容器 `docker cp WeKnora-frontend-wkj:/usr/share/nginx/html/.` → `my-frontend/dist/`（19M，8 项，含 `f5a10b7`） |
| 执行 `up` | `frontend-wkj` 与 `docreader` **重建**；**`app` 未被动到**（Up 3 minutes） |
| 健康检查 | 后端 0s、两个前端 200 |

### 3.1 端到端验证（决定性）

| 检查 | 结果 |
|---|---|
| `docker inspect` 挂载 | `frontend-wkj` rw=true / `docreader` rw=false ✅ |
| **宿主写文件 → 容器读 → HTTP 读** | **三者内容完全一致**，清理后立即消失 ✅ |
| `config.js` 落宿主目录 | entrypoint 写得进去 ⇒ `:ro` 会让它失败的判断得到验证 ✅ |
| `docreader` 源码 sha256 | 容器内 = 宿主源码（`171579f9…`）✅ |

---

## 四、收益（诚实说明）

| 动作 | 之前 | 现在 | 省掉的 |
|---|---|---|---|
| 改前端 | `build frontend-wkj`（分钟级） | 本地 build + rsync | 镜像层操作 + 容器重建；**且无需重启** |
| 改 docreader | `build docreader`（分钟级） | `sync` + `restart` | **几乎全免** |
| 改后端 Go | `build app` | **未变**（见 §5） | — |

**附带好处**：
- 前端**回滚只是换目录内容**（比回滚镜像简单）
- 投递后**用户无感知**（不重启容器）

---

## 五、`app` 为什么不做外置（已实测，结论：不做）

**起因**：老魏提议"111 宿主没 go，就装一个，也没什么麻烦的"。**Go 装好了，但这条路实测走不通。**

### 5.1 宿主编译的产物在容器里跑不起来

装了 Go 1.26.8 + `libsqlite3-dev` 后，宿主编译**成功**（332M 产物），
但把产物拿进**容器的镜像**里跑 `ldd`，动态链接器直接报缺：

```
/wk: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found (required by /wk)
/wk: /lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32' not found (required by /wk)
/wk: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found (required by /wk)
```

| | GLIBC | GLIBCXX |
|---|---|---|
| 宿主 Ubuntu 24.04 | **2.39** | — |
| 容器 `debian:12.12-slim` | **2.36** | 3.4.30 |
| **宿主编出的产物需求** | **2.38** ❌ | **3.4.32** ❌ |
| 容器内现有二进制需求（基准） | 2.35 ✅ | 3.4.30 ✅ |

**根因**：cgo 二进制与 glibc **强绑定** —— 宿主 glibc 更新，产物就引用更高版本的符号，
拿到更老的 glibc 上直接 `not found`。

### 5.2 退路逐条排除

| 退路 | 结论 |
|---|---|
| `-static-libstdc++ -static-libgcc` | 只能消掉 `GLIBCXX_*`，**消不掉 `GLIBC_*`**（glibc 本身无法静态链接） |
| 在 Ubuntu 上装 Debian 12 的 `libc6-dev` | ★ **会破坏宿主系统**，不做 |
| 降级宿主 glibc | 已是最新主线，不可行 |
| 容器化编译（`golang:1.26-bookworm`） | ✅ 可行，但**等于回到容器编译** |

### 5.3 所以 app 的编译只能在容器里（且不值得再折腾）

| 方案 | 编译耗时 | 额外开销 |
|---|---|---|
| 现状 `build`（Dockerfile 全流程） | 含 browserskill 等阶段 | 镜像 commit + 容器重建 |
| `docker build --target builder --output type=local` | 可跳过 browserskill | **导出整个 builder rootfs**（含 `/go` 缓存，数 GB 写盘） |

⇒ 省下的只是"镜像 final 阶段 + 容器重建"（十几秒量级），
而**编译时间省不掉**（5~12 分钟，无论产物放哪）。

**结论：`app` 维持现状**（走镜像构建），不做外置。

**通用判据**：判断"能不能在 A 上编译、拿到 B 上跑"之前，先比 **`ldd --version`**
与**产物实际需求的 `GLIBC_*` 符号** —— 不要凭"都是 x86_64"就认为可以。

> **宿主上的 Go 保留**：虽然不能用于产出容器可用的二进制，但可做
> `go vet` 静态检查、依赖预取（`go mod download`，缓存已 1.8G）。

---

## 六、已知问题

| # | 问题 | 说明 |
|---|---|---|
| 1 | **本地 `npm ci` 被环境拦下** | 报 `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]`（要删 1087 个条目，超阈值 50）⇒ 本地依赖未装全，`npm run build` 报 `vite: command not found`。<br>**当前规避**：前端产物从 111 现有容器 `docker cp` 取得（也更干净——版本与后端一致）。<br>**若要本地构建**：需先解决 `node_modules` 的安装（例如逐目录清理，或换用 `npm install` 增量补齐）。 |
| 2 | `config.js` 属主 | 本轮它由 `docker cp` 创建（属主 `wake`），entrypoint 只覆盖内容不改属主。**若将来 dist 被清空重建**，entrypoint 新建的 `config.js` 属主会是容器内 uid ⇒ 清理时可能需要 sudo。 |

---

## 七、日常操作手册

```bash
# ── 改前端 ────────────────────────────────────────────
./deploy/deploy-wkj-dev.sh push-ui      # 构建（本地）+ 投递 ⇒ 立即可见，无需重启

# ── 改 docreader ──────────────────────────────────────
./deploy/deploy-wkj-dev.sh push-reader  # sync + restart（秒级）

# ── 改了编排（overlay）────────────────────────────────
./deploy/deploy-wkj-dev.sh up           # 只重建受影响的容器

# ── 改后端 Go（尚未外置）──────────────────────────────
./deploy/deploy-wkj-dev.sh build        # 全量；或按需 docker compose build app
```
