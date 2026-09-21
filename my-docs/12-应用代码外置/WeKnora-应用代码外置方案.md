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

## 五、`app` 为什么暂未做

| 障碍 | 说明 |
|---|---|
| **111 宿主无 `go`** | 编译只能在容器内 ⇒ 无法"换编译后的文件" —— 除非先把产物从容器里导出来 |
| 导出成本 | `docker build --target builder --output type=local` 会导出**整个 builder rootfs**（含 `/go` 缓存，数 GB），不见得比直接 `build` 快 |
| 编译时间是链路大头 | Go 编译 5~12 分钟，**无论产物放哪都省不掉** |

⇒ 结论：**待实测**。若将来要做，可行路径是在 111 上跑
`docker build --target builder --output type=local` 后取产物，再挂载 `/app/WeKnora` + `restart`。

**注意**：`app` 若外置，镜像里那份二进制会被挂载遮住 ⇒ **首次必须先填充**（同前端）。

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
