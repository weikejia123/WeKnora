# WeKnora 官方 main 更新分析（第 6 轮）

> **区间**：`2e712a97` → `5d00985f`（**13 个提交**）
> **本机结果**：合并提交 `ab705674`（0 冲突）· 副本同步 `5a6e254c`
> **前置轮次**：`WeKnora-官方main第1/2/3/4/5轮更新分析.md`
> **一句话结论**：本轮是**发版轮** —— **v0.8.2 正式发布**（version 0.8.0 → 0.8.2），
> 带 1 个新功能（模型目录控制台）与 **1 个新迁移 `000111`**；零冲突、依赖面未动、`go build` 通过。
> ⚠️ **因有新迁移，部署时 app 重启会改表结构 ⇒ 必须先备份**（与第 5 轮的"无迁移"不同）。

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **13** |
| **发版** | ✅ **v0.8.2**（tag 指向 `3e8b0bfc`；`git describe main` = `v0.8.2-7-g5d00985f`） |
| 版本号变更 | `frontend/package.json` 与根 `VERSION`：**0.8.0 → 0.8.2**（另有 README×4 / helm Chart.yaml） |
| 规模 | **138 文件，+4675 / −623** |
| 依赖面 | `go.mod` / `go.sum` / `docreader/requirements.txt` **未动**；`frontend/package.json` **仅 version 字段**（`package-lock.json` 亦仅随之 4 行） |
| **数据库迁移** | ★ **新增 `000111_model_catalog_config`**（versioned + sqlite 各 2 个文件） |
| 编译验证 | `go build ./...` ⇒ **exit=0**（仅 `ld: warning: ignoring duplicate libraries: '-lc++'`，无害） |
| 冲突预判 | 三点比较**交集 0** + `merge-tree` 预演**干净**（双方法实测） |
| 我方改动面 | 官方 138 / 我方 856 文件，**零重叠** |
| fetch 耗时 | **3.8 秒** |

---

## 二、更新内容（使用视角）

### 2.1 ★ v0.8.2 发版（5 条提交，占本轮近半）

| 提交 | 内容 |
|---|---|
| `5468e7c1` | `chore: bump version to 0.8.2` —— 改 `VERSION`、`frontend/package.json`、README×4、helm Chart.yaml |
| `9f57bbe4` | 标注 v0.8.2 发布日期，并在 README 中描述该版本 |
| `b6b32c24` | 更新文档站集成测试以适配 v0.8.2 的 header 与 release gallery |
| `3e8b0bfc` | Lite 宿主沙箱工作区选择的文档订正（**tag `v0.8.2` 指向此提交**） |
| `5d00985f` | 重构英文与中文 README |

★ **版本口径就此对齐**（对我们有意义）：
上一版是「后端 `v0.8.0`（带 v）× 前端 `0.8.0`」的错位，我们曾修过（`20a9ff8f`：注入值去 `v` + 编译容器内 git shim）。
本轮后 `package.json` = `0.8.2`、根 `VERSION` = `0.8.2` ⇒ **两侧一致**，
系统信息页那个「与应用版本不一致」的提示应彻底消失。

### 2.2 新功能：系统管理员「模型目录控制台」（`967ed097`，#3662）

`feat(models): add system admin model catalog console` —— 新增系统级模型目录管理界面。
前端新增 **5 个文件**（本轮唯一的 `A` 类改动）：

| 文件 | 作用 |
|---|---|
| `frontend/src/api/system/modelCatalog.ts` | API 层 |
| `frontend/src/views/system/ModelCatalog.vue` | 控制台页面 |
| `frontend/src/views/system/ModelCatalogFieldControl.vue` | 字段控件 |
| `frontend/src/views/system/modelCatalogState.ts` + `.test.ts` | 状态层与测试 |

配套后端：`internal/container/container.go` 新增 **2 行** provide
（`repository.NewModelCatalogRepository`、`service.NewModelCatalogService`），
以及**新迁移 `000111_model_catalog_config`**。

### 2.3 修复（6 条）

| 提交 | 现象 |
|---|---|
| `e6284f4e` | `fix(browser)`：共享空间的 agent 可驱动**调用方本地的**浏览器 |
| `eebc1d86` | `fix(ui)`：恢复表单弹窗的内边距（#3673） |
| `8d401501` | `fix(session)`：自动生成的会话标题保持**纯文本**（不再被解析成标记） |
| `503f1abf` | `fix(confluence)`：列表被截断时，删除前先确认「未列出页面」 |
| `eb888d0d` | `fix(confluence)`：阻止 Server 列表翻页越过最后一页 |
| `a1b0d0cb` | `fix(models)`：qwen3-rerank 改走 **DashScope 原生 rerank 协议** |

### 2.4 文档站（`cee69792`）

`fix(website-docs): serve everything but the homepage from /docs/` —— 除首页外统一走 `/docs/` 路径。

---

## 三、二开影响评估

### 3.1 合并记录

| 步骤 | 提交 | 说明 |
|---|---|---|
| 合并上游 | `ab705674` | **0 冲突**（中文消息，按本轮修好的技能写法） |
| 副本同步 | `5a6e254c` | 24 文件（19 改 + 5 新）+ 副本复制点更新 |

回滚点：`2d747722`（合并前 HEAD）。

### 3.2 冲突预判：双方法确认

```sh
# 方法一：三点比较（merge-base = 2e712a97）
comm -12 /tmp/up.txt /tmp/dev.txt          # → 空（交集 0）

# 方法二：merge-tree（不碰工作区）
git merge-tree --write-tree --name-only wkj-dev main
# → 2493887d6bd7d311f4b8dc57a43f760b95b44a29（单 tree OID = 干净）
```

### 3.3 二开完整性校验

`comm -23 /tmp/dev.txt /tmp/after.txt` → **空（零丢失）**；
`my-docker` / `my-frontend` / `my-docs` / `deploy` / `AGENTS.md` / `my-scripts` 逐个实测存在。

### 3.4 前端副本同步（判据成立 + 一处新发现）

| 判据 | 结果 |
|---|---|
| 差异归因 | 差异 26 条 = 官方 24（19 改 + 5 新）+ 构建产物 2（`dist`/`node_modules`）⇒ **完全吻合** |
| 同步后判据 | `diff -rq frontend my-frontend` = **恰好 2 行** |
| 产物未被触碰 | `dist/index.html` 的 sha256 同步前后一致 |
| 副本 version | `0.8.2` ✅（随官方 bump） |
| 副本复制点 | `my-docker/README.md`：`2e712a97` → **`5d00985f`** |

★ **新发现（值得记）**：`git ls-files frontend`（816）与 `git ls-files my-frontend`（811）**差 5**。
查证：差的正是官方本轮**新增的 5 个文件** —— rsync 已同步到副本（文件系统层面 `diff -rq` 一致），
但它们此前是**未跟踪**状态，故不计入 `git ls-files`。**已在本次提交中显式纳入**。
⇒ 教训：`ls-files` 计数不等 **≠** 副本失真；先查是不是"新增文件尚未纳入版本控制"。

---

## 四、★ 2 个例外 Dockerfile 的必要性判断

**结论：仍必要，官方本轮未动它们。**

| 项 | 结果 |
|---|---|
| 官方是否改动 | **未动**（`git diff --name-only 2e712a97..main -- docker/Dockerfile.*` → 空） |
| 我方领先项 | 实测 **11 处** `+` 行仍在：`APK_MIRROR_ARG` 条件换源 + `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` |
| 判定 | **继续保留** |

---

## 五、连带发现

### 5.1 ★ 第三个「行号敏感文件」被官方改动：`internal/container/container.go`

官方本轮在该文件加了 **2 行**（第 173 / 247 行附近的 `provide` 注册），
⇒ 其后所有行号 **+2**；而该文件在我方文档里正被频繁引用（自动迁移机制）。

**核对结果（发现历史偏移 + 本轮叠加）**：

| 文档原写 | 实际位置 | 偏差 |
|---|---|---|
| `container.go:875`（`AUTO_MIGRATE` 判断） | **889** | +14（历史 +12，本轮 +2） |
| `container.go:878`（`AUTO_RECOVER_DIRTY`） | **892** | +14 |
| `container.go:887-892`（迁移失败不阻断） | **900-905**（`RunMigrationsWithOptions` 的 err 分支） | +13 |

**已订正**（`my-docs/11-数据安全与备份/WeKnora-数据安全与备份方案.md` 两处，共 6 行）：
改为「**符号定位 + 本版行号**」形式（如"`container.go` 内 `if os.Getenv("AUTO_MIGRATE") != "false"`（本版 :889）"）。

> ★ 这印证了技能第 9 步的判据：不止 `Makefile` / `docker-compose.yml` / `.env.example` 这几类，
> **任何被我们引用了行号的官方文件都可能漂移** —— 本轮就是 `container.go`。

### 5.2 其余行号敏感文件本轮未被改动

`Makefile` / `docker-compose.yml` / `docker-compose.dev.yml` / `.env.example` / `docker/` /
`scripts/build_browserskill.sh` / `scripts/browserskill-release.json` —— **均未动** ⇒ 相关引用不受影响。

---

## 六、★ 部署判断（与第 5 轮不同，本轮**必须**部署才生效）

| 项 | 结论 |
|---|---|
| 是否需 `build` | **不需要**（例外文件与依赖面未动，镜像层无变化） |
| **是否需 `push-app`** | ★ **需要** —— 本轮改了 `internal/`（含 `container.go`、modelcatalog 相关）⇒ 后端二进制必须重编 |
| 是否需 `push-ui` | **需要** —— 24 个前端文件（含 5 个新页面），且 `package.json` 版本号已变 0.8.2 |
| 编排 / docreader | 未变 ⇒ 不需要 `up` / `push-reader` |
| **迁移** | ⚠️ **有 `000111`** ⇒ app 重启会执行迁移、**改正式数据的表结构** ⇒ **必须先备份** |

**部署前置（不可省）**：
1. 推送（`gitea` + `gitea110`）—— 部署铁律「提交 → 推送 → 部署」
2. **备份**（技能坑 6：动 app 前必须备份）—— 本轮有迁移，备份是硬要求

---

## 七、待办

| # | 事项 | 说明 |
|---|---|---|
| 1 | **部署**（`push-app` + `push-ui`） | 本轮修复与 v0.8.2 都还没上 111；执行前先备份（有迁移 000111） |
| 2 | MinerU-4 引擎 | 方案在 `my-docs/16-解析引擎扩展/`，待确认是否接受改动面扩大（2 → 10+） |
| 3 | BrowserSkill 0.3.1 | 仍只在源码里（镜像内 0.3.0）；该功能按你口径暂不使用 ⇒ 潜伏项 |

---

## 八、证据（可复核）

```bash
# 规模与发版
git rev-list --count wkj-dev..main                 # → 13
git describe --tags main                           # → v0.8.2-7-g5d00985f
git diff --shortstat wkj-dev...main                # → 138 files, +4675 / -623
git log --oneline -1 v0.8.2                        # → 3e8b0bfc

# 版本口径（合并后应两侧一致）
grep '"version"' frontend/package.json             # → 0.8.2
cat VERSION                                        # → 0.8.2

# 冲突预判（双方法）
comm -12 <(git diff --name-only 2e712a97..main | sort) <(git diff --name-only 2e712a97..wkj-dev | sort)   # → 空
git merge-tree --write-tree --name-only wkj-dev main                                        # → 单 tree OID

# 新迁移
git diff --name-status 2e712a97..main -- migrations/     # → A 000111_model_catalog_config ×4

# 副本判据
diff -rq frontend my-frontend | wc -l              # → 2
git diff --name-status 2e712a97..main -- frontend/ | grep -c "^A"   # → 5（新增）

# container.go 行号核对
sed -n '889p;892p;900,905p' internal/container/container.go
```

**提交链**：`2d747722`（回滚点）→ `ab705674`（合并）→ `5a6e254c`（副本同步）
