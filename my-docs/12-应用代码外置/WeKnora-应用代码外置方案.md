# 应用代码外置方案

> 目标（老魏）：**日常改动只需「推代码 → 111 拉取 → 编译 → 替换」**，不必每次重建镜像 / 容器。
> 适用：南宁 111（开发环境 + 正式数据）

---

## 〇、结论速览

| 应用 | 是否外置 | 改完要做什么 | 实测耗时 |
|---|---|---|---|
| **`frontend-wkj`** | ✅ 已上线 | `push-ui`（本地构建 → 投递） | 分钟级，**无需重启** |
| **`docreader`** | ✅ 已上线 | `push-reader`（同步源码 → 重启） | **秒级** |
| **`app`**（后端 Go） | ✅ **已上线**（2026-09-22） | `push-app`（编译镜像编译 → 重启） | **15.7s**（热缓存）／2m02s（首次） |
| **`migrations`**（数据库迁移文件） | ✅ **已上线**（2026-09-22） | 随 `sync` 自动更新；**一次 `push-app` 即生效** | 0（无独立动作） |

**一句话**：四层应用代码都已从镜像里搬出来，**镜像只承担「运行环境」职责**。
⇒ 只有依赖清单（`go.mod` / `requirements.txt` / `package.json`）或基础镜像变化时，才需要重建镜像。

**迁移为什么也算"应用代码"**：它和二进制是同一次代码变更的两个产物（改表结构必须配套改代码）。
之前只有二进制外置，导致**官方新迁移永远不生效**（容器内迁移文件来自镜像），
2026-09-22 实测踩到：容器停在 `000108`、代码已含 `000109`，而新代码的 `Session`
模型直接读该列 ⇒ **所有会话查询会报 `column does not exist`**。外置后两者同步。

**关键澄清**：111 宿主上**不能**用来产出后端二进制 —— 见 §5（这是"用编译镜像"而非"宿主编译"的原因）。

---

## 一、链路（现在是这个形态）

| 步骤 | 命令 | 状态 |
|---|---|---|
| 1. 推代码 | `git push gitea110 wkj-dev` | ✅ 有 |
| 2. 111 拉取 | `deploy-wkj-dev.sh sync` | ✅ 有（**迁移文件也在此步到位**） |
| 3. 编译 | 前端：本地 `npm run build`；后端：111 上的**编译镜像**；docreader / 迁移：免编译 | ✅ 有 |
| 4. 投递 | `push-ui` / `push-app` / `push-reader` | ✅ 有（`push-app` 同时覆盖二进制与迁移） |
| 5. 生效 | 前端**无需重启**；app / docreader `restart`（**新迁移在此刻执行**） | ✅ 有 |

**我们用的"映射目录"不是新建的——就是仓库本身**：
111 上本就有完整 git 仓库，`sync` 已把"push → 110 → 111 拉取"铺好，
产物直接落仓库里的目录即可。两类来源要分清：

| 挂载源 | 性质 | 谁更新它 |
|---|---|---|
| `docreader/`、`migrations/` | **受 git 管理**的仓库内容 | `sync` 的 `git reset --hard` |
| `my-frontend/dist`、`.build/` | **本地产物**（已被 gitignore ⇒ `reset` 不会动它） | `push-ui` / `push-app` 投递 |

---

## 二、落地方式

### 2.1 overlay 四处挂载

```yaml
  frontend-wkj:
    volumes:
      - ./my-frontend/dist:/usr/share/nginx/html      # ★ 不能加 :ro
  docreader:
    volumes:
      - ./docreader:/app/docreader:ro
  app:
    volumes:
      - ./.build/WeKnora:/app/WeKnora:ro              # ★ 单文件挂载
      - ./migrations:/app/migrations:ro               # ★ 与二进制同一次代码变更的产物
```

| 要点 | 原因 |
|---|---|
| 前端**不能加 `:ro`** | `docker-entrypoint.sh` 启动时要往此目录写运行时配置 `config.js`，只读挂载会让容器**直接启动失败** |
| docreader 可以 `:ro` | 依赖在 `/app/.venv`，与源码目录 `/app/docreader` **分开**（`Dockerfile.docreader` 的 `VIRTUAL_ENV`）⇒ 挂源码不遮依赖 |
| 前端挂载后**无需重启** | 内层 nginx 直接读文件 ⇒ 投递即生效 |
| app 是**单文件**挂载 | ★ 宿主文件**必须已存在**，否则 Docker 会创建同名**目录** ⇒ ENTRYPOINT 直接失败（首次启用顺序见 §6.3） |
| 迁移挂载点为什么是 `/app/migrations` | 迁移器读的是**相对路径** `file://migrations/versioned`（`internal/database/migration.go` 的 `RunMigrationsWithOptions`），相对容器 `WORKDIR /app` ⇒ 无需任何配置项 |
| 迁移可以 `:ro` | app 只**读**迁移文件、只**写**数据库 ⇒ 只读足够 |
| 迁移**不需要独立投递动作** | 它是仓库内容 ⇒ 跟着 `sync` 的 `git reset` 一起到位（与二进制不同） |

### 2.2 投递命令（`deploy/deploy-wkj-dev.sh`）

| 命令 | 做什么 |
|---|---|
| `push-ui` | 本地 `npm run build`（显式注入 `VITE_FRONTEND_COMMIT`）→ `rsync dist` → 立即可见 |
| `push-app` | 111 上用**编译镜像**编译（含 anydoc 静态库）→ 落 `.build/WeKnora` → 重启 app。★ 一次动作同时更新**两样外置件**：二进制 + 迁移文件（后者由 `sync_code` 带来） |
| `push-reader` | `sync_code` + `restart docreader` |
| `up` | **只按当前编排重建容器**（不 pull / 不 build）—— 让编排改动生效 |

**`up` 为什么必需**：改编排后要让它生效，但原有三个子命令都绕不开镜像操作 ——
`update` 检测到本地构建镜像会**自动改走 build**（16 分钟），`build` 更慢，
`sync` 又不重建容器。`up` 模式下 compose 只重建 **config-hash 真正变了**的服务。

> ★★ **所有"让改动生效"的前提都是「改动已提交并推送」** —— 因为 `sync_code` 的第一步是
> `git push gitea110`，再把 111 的仓库 `reset` 到该提交。**未提交的改动传不过去**：
> 编排看起来没变 ⇒ compose 判定"无需重建" ⇒ 打印一片 `Running`、部署"成功"，
> 而挂载/配置实际是旧的。这个坑静默且伪装成成功（2026-09-22 实测：改完 overlay 直接
> 跑 `up`，输出全绿但 app 未重建，容器内迁移文件仍是 `000108`）。
> ⇒ **顺序永远是「提交 → 推送 → 部署」**，部署脚本自己会推，但推的是**已提交**的内容。

---

## 三、实施记录

### 3.1 前端 + docreader（2026-09-21）

| 步骤 | 结果 |
|---|---|
| 填充宿主目录 | 从现有容器 `docker cp WeKnora-frontend-wkj:/usr/share/nginx/html/.` → `my-frontend/dist/`（19M，8 项） |
| 执行 `up` | `frontend-wkj` 与 `docreader` **重建**；**`app` 未被动到** |
| 端到端验证 | 宿主写文件 → 容器读 → HTTP 读 **三者内容一致**；`docreader` 源码 sha256 容器 = 宿主 |

### 3.2 app 外置（2026-09-22 完成）

| 检查 | 结果 |
|---|---|
| 编译 | 首次全链路 **2m02s**（Rust anydoc 45.9s + Go 编译），产物 **267M** |
| GLIBC 需求 | 最高 `GLIBC_2.35`（容器上限 2.36）✅ |
| 挂载生效 | `/app/WeKnora` ← `.build/WeKnora`（rw=false）✅ |
| 版本自证 | 容器内二进制 `grep -c <commit>` 命中 **7 次**，等于部署机 HEAD ✅ |
| 文件一致性 | 宿主与容器内 size 完全一致（279941568）✅ |
| 数据库迁移 | 保持 `108 / dirty=f` —— **当时迁移文件仍在镜像内**，故新迁移不会生效（补齐见 §3.4） |
| 三个 https 入口 | `443` / `41200` / `41280` 全部 **200** ✅ |
| 分支逻辑 | 已挂载时走 `restart`：容器 `Created` 未变、仅 `StartedAt` 更新 ⇒ 未重建容器 ✅ |

### 3.3 编译提速（Go build cache）

编译容器是 `--rm` 的，而 Go 的 build cache 默认落**容器层** `/root/.cache/go-build`
⇒ 只挂 `/go/pkg/mod` 只省了"下载依赖"，**省不掉"编译"**。补挂命名卷后：

| 场景 | 耗时 |
|---|---|
| 冷缓存（首次填充卷） | **72.90s** |
| 热缓存（命中卷） | **15.72s** ← 4.6 倍 |
| （对照）首次全链路含 Rust 全编译 | 2m02s |

> 三个缓存卷：`weknora-go-mod`（依赖源码）、`weknora-go-build-cache`（编译产物）、
> `weknora-cargo-registry`（Rust crates）。均为**命名卷**、不由 compose 管 ⇒ `down -v` 不会误删。

### 3.4 迁移外置（2026-09-22 完成）

**起因**：二进制外置后暴露了一个"半外置"问题 —— 代码更新了、**表结构没更新**。
上游这轮的 `000109` 给 `sessions` 加列，而新代码的 `Session` 模型直接读该列 ⇒
列不存在会让**所有会话查询报错**。当时先手工补了 DDL 应急，随后把迁移层也外置。

| 检查 | 结果 |
|---|---|
| 触发方式 | 挂载变化 ⇒ `up` **重建** app（`restart` 不应用新挂载） |
| 容器内挂载 | `migrations → /app/migrations`（read_only）✅ |
| 文件一致性 | 容器内与宿主 `000109` 的 md5 一致（`910bec91fc97…`）✅ |
| 迁移执行 | 启动日志 `Database migrated from version 108 to 109` ✅ |
| 库结构 | `schema_migrations = 109/false`；列与**列注释**均已写入 ✅ |
| 服务 | app healthy；`41200` / `41280` / searxng / neo4j Bolt 全部正常 ✅ |

> **为什么"列注释"是有效判据**：应急时手工执行的 DDL 只加了列、**没有注释**；
> 而官方 `000109` 里含 `COMMENT ON COLUMN` ⇒ 注释存在，即证明这是**迁移文件本身**
> 跑通的，不是遗留的手工状态。这同时说明迁移历史已回到正轨。

**两次部署的对照**（第一次失败恰好演示了 §6 第 7 条）：

| 顺序 | 111 的 overlay | compose 判定 | 容器内迁移文件 | 结果 |
|---|---|---|---|---|
| 改完**直接** `up`（未提交） | 旧（无挂载） | 无需重建 ⇒ 全 `Running` | `000108` | ❌ 输出全绿但未生效 |
| **提交后** `up` | 新 | `Recreate` | `000109` | ✅ 生效 |

---

## 四、收益（诚实说明）

| 动作 | 之前 | 现在 | 省掉的 |
|---|---|---|---|
| 改前端 | `build frontend-wkj`（分钟级） | `push-ui` | 镜像层操作 + 容器重建；**且无需重启** |
| 改 docreader | `build docreader`（分钟级） | `push-reader` | **几乎全免** |
| 改后端 Go | `build app`（7~16 分钟） | `push-app` | **镜像 final 阶段 + 容器重建；编译时间靠缓存压到 16s** |
| 官方带来新迁移 | `build app`（重建镜像，7~16 分钟）；★ **若只做二进制外置则根本不生效** | 随 `push-app` / `up` 自动执行 | 镜像操作；**以及"迁移静默不跑"这个隐患** |
| 依赖清单变了 | `build` | `build`（仍走全量） | — （不可避免） |

**附带好处**：
- 前端**回滚只是换目录内容**（比回滚镜像简单）
- 前端投递后**用户无感知**（不重启容器）

---

## 五、为什么后端用「编译镜像」而不是在 111 宿主上编译

**起因**：老魏提议"111 宿主没 go，就装一个，也没什么麻烦的"。**Go 装好了，但这条路实测走不通。**

**宿主编译的产物在容器里跑不起来**（装了 Go 1.26.8 + `libsqlite3-dev` 后实测）：

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

**根因**：cgo 二进制与 glibc **强绑定** —— 宿主 glibc 更新，产物就引用更高版本的符号。

**退路逐条排除**：

| 退路 | 结论 |
|---|---|
| `-static-libstdc++ -static-libgcc` | 只能消掉 `GLIBCXX_*`，**消不掉 `GLIBC_*`**（glibc 本身无法静态链接） |
| 在 Ubuntu 上装 Debian 12 的 `libc6-dev` | ★ **会破坏宿主系统**，不做 |
| 降级宿主 glibc | 已是最新主线，不可行 |

⇒ **解法**：`my-docker/Dockerfile.app-builder` —— 一个与 final 镜像**同为 Debian 12** 的编译镜像
（`golang:1.26-bookworm` + cgo 依赖 + Rust 工具链），产物需求 `GLIBC_2.34` ⇒ 容器内可用。

> **通用判据**：判断"能不能在 A 上编译、拿到 B 上跑"之前，先比 **`ldd --version`**
> 与**产物实际需求的 `GLIBC_*` 符号** —— 不要凭"都是 x86_64"就认为可以。

> **宿主上的 Go 保留**：虽不能产出容器可用的二进制，但可做 `go vet`、依赖预取。

---

## 六、已知约束与坑（都是"静默失效"型）

| # | 坑 | 现象 | 处置 |
|---|---|---|---|
| 1 | **漏跑 `scripts/build-anydoc-lib.sh`** | 编译走到 link 才报 `/usr/bin/ld: cannot find -lanydoc_go` | 该脚本产出 anydoc 的 Rust 静态库到 `third_party/anydoc-go/lib/`，正是 cgo `-L` 路径；官方 Dockerfile 同样"先产库、再 `GO_BUILD_TAGS=anydoc`"，**两步必须在同一容器内** |
| 2 | **编译产物落在仓库内且未被 gitignore** | 工作区"看起来脏" ⇒ 触发 `sync_code` 的"有改动则跳过 reset"保护 ⇒ **每次部署都静默跳过代码同步**（表现为"部署成功但代码是旧的"） | 产物 = `third_party/anydoc-go/{target,lib,patched-anydoc}`；用 **`.git/info/exclude`** 幂等排除（本地配置、不入库，无需改官方 `.gitignore`） |
| 3 | **首次启用时 `restart` 不应用新挂载** | 编译成功、也重启了，跑的还是镜像内那份旧二进制 | 挂载在**容器创建时**固定 ⇒ 首次必须 `up -d app`；脚本已加挂载检测自动分支 |
| 4 | **单文件挂载要求宿主文件已存在** | 否则 Docker 创建同名**目录** ⇒ ENTRYPOINT 失败、容器起不来 | 首次启用顺序：**先** `push-app` 产出 `.build/WeKnora`，**再** `up -d app` |
| 5 | **手工替换产物后必须重启容器** | bind mount 在容器启动时解析；只换文件不重启 ⇒ 容器内仍是旧二进制 | 用 `push-app`（已内置重启）；不要手工 `cp` 完就算 |
| 6 | 本地 `npm ci` 可能被环境拦下 | `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]` | 前端产物优先从 111 现有容器 `docker cp` 取得 |
| 7 | **改了编排却直接部署（改动未提交）** | 输出**全绿**、容器全 `Running`、后端 200，但挂载/配置实际是旧的 | `sync_code` 推的是**已提交**内容 ⇒ 顺序必须「**提交 → 推送 → 部署**」。判据用 `docker inspect … --format '{{range .Mounts}}{{.Destination}}{{end}}'` 看挂载，**别信 compose 的 `Running`**（2026-09-22 实测踩到） |
| 8 | **迁移未同步 / 未执行，但服务照常 healthy** | app 正常、无报错；`AUTO_MIGRATE` 失败只 `warn` 不退出（`container.go` 的 "don't fail startup"）⇒ 「服务正常」**掩盖**「迁移没跑」 | 外置后宿主 `migrations/` 必须**存在且非空**；用 `health` 里的 `check_migrations` 核两道判据：容器内文件名 = 仓库、库版本 = 文件最高版本 |

> **第 5 条的机制澄清（2026-09-22 实测）**：Go 的 `-o` 是**写临时文件再 rename**
> ⇒ 每次编译产物 **inode 都会变**（实测 `1164023 → 1164022`）。
> 之所以容器内仍能读到新版本，是因为 `push-app` 最后**重启了 app**，
> 让 bind mount 重新解析路径（容器内 inode 同步变为 `1164022`）。
> ⇒ 不要用"inode 相同"判断容器内是否最新，**判据要用容器内 `grep -c <commit>`**。
> ⇒ 也不要在 Mac 上验证这条 —— Mac 的 Docker 走 VM 文件共享，语义与原生 Linux bind mount **不同**。

---

## 七、日常操作手册

```bash
# ── 改前端 ────────────────────────────────────────────
./deploy/deploy-wkj-dev.sh push-ui      # 构建（本地）+ 投递 ⇒ 立即可见，无需重启

# ── 改后端 Go ─────────────────────────────────────────
./deploy/deploy-wkj-dev.sh push-app     # 编译 + 投递 + 重启（热缓存 ~16s）

# ── 改 docreader ──────────────────────────────────────
./deploy/deploy-wkj-dev.sh push-reader  # sync + restart（秒级）

# ── 改了编排（overlay）────────────────────────────────
./deploy/deploy-wkj-dev.sh up           # 只重建受影响的容器
# ★ 前提：改动**已提交**（脚本推的是已提交内容，未提交部分不会生效）

# ── 依赖清单 / 基础镜像 / 上游同步 ────────────────────
./deploy/deploy-wkj-dev.sh build        # 全量（7~16 分钟，不可避免）

# ── 只同步代码，不碰容器 ──────────────────────────────
./deploy/deploy-wkj-dev.sh sync         # 会更新 ./migrations 文件，但 app 不重启
                                        # ⇒ 新迁移要等下次 app 启动才执行
```

**验证闭环（改完自证）**：

```bash
./deploy/deploy-wkj-dev.sh health                          # 后端 + 两个前端 200，含迁移一致性校验
ssh nanning-111 'docker exec WeKnora-app grep -ac <8位commit> /app/WeKnora'   # 至少 1 次命中
ssh nanning-111 'docker exec WeKnora-frontend-wkj grep -rl "<7位commit>" /usr/share/nginx/html/'  # ★ 前端只存 7 位
ssh nanning-111 'docker exec WeKnora-app ls /app/migrations/versioned/ | tail -1'  # 应与仓库最新一致
```
