# WeKnora 官方 main 更新分析（第 3 轮）

> **区间**：`6afb6ca9` → `a89a5a2c`（6 个提交）
> **本机结果**：合并提交 `cff6cec4`（0 冲突）· 副本同步 `67da04fd`
> **前置轮次**：`WeKnora-官方main第1轮更新分析.md`、`WeKnora-官方main第2轮更新分析.md`
> **一句话结论**：官方内容本身很轻（无发版、无迁移、无依赖变更），但 **BrowserSkill 换了上游基线**
> ⇒ 本次**必须重建 app 镜像**，不能只换后端二进制。

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **6** |
| 有无新发版 | **无**（`git describe --tags main` = `v0.8.0-252-ga89a5a2c`） |
| 依赖面 | `go.mod` / `go.sum` / `docreader/requirements.txt` / `frontend/package.json` / `package-lock.json` **全部未动** |
| 数据库迁移 | `migrations/` **0 改动** ⇒ 不涉及表结构 |
| 编译验证 | `go build ./...` ⇒ **exit=0**（仅 `ld: warning: ignoring duplicate libraries: '-lc++'`，无害） |
| fetch 耗时 | **32 秒**（第 2 轮为 4 分 20 秒 —— 同一条链路，波动很大，故仍应后台跑） |
| 我方改动面 | 官方 170 文件 / 我方 835 文件；**交集 1 个：`docker/Dockerfile.app`** |

---

## 二、更新内容（使用视角）

### 2.1 ★ BrowserSkill 换上游基线（本轮唯一需要重建镜像的改动）

`a89a5a2c` fix(browser): use unmodified BrowserSkill upstream and remove downstream patches (#3563)

| 项 | 变化 |
|---|---|
| 锁定 commit | `fa953dc6…` → **`3da449e9…`**（`scripts/browserskill-release.json`，扩展与 daemon 两端同步） |
| 下游补丁 | **删除 01/02/04/05/06** —— `patches/browserskill/` 整个目录（6 个文件）**消失** |
| 补丁 02/04/06 | 上游已自行合入（PR #291 导航响应宽限、#296 预览/聚焦 UI 通道、#297 弹窗归属）⇒ WeKnora 改为调用**官方** `ui.task_preview` / `ui.task_focus` |
| 补丁 05（末标签页生命周期） | 改为**宿主侧**实现：`tool.tab_close` 前网关先列举 Agent Window 标签，若目标为唯一标签则用 `tool.tab_create` 先建一个自有的 `about:blank` 占位，避免 Chrome 连窗一起关掉并上报「用户中断」 |
| 补丁 01（有界 CDP 读 + 截图栅栏） | 收窄后**保留**，仍是唯一的下游扩展改动；截图部分改由上游 #296 的有界预览 + 附件栅栏承担 |
| 新增错误分类 | 渲染器读超时 ⇒ `data.reason = renderer_read_timeout`，映射为「停止重读该标签」的模型提示（原先只会给通用的 inspect-and-retry 建议） |

> **★ 为什么这条决定了部署方式**：app 镜像里**内置**着 bsk 与配套扩展
> （`/opt/weknora/browserskill/{bsk, browser-skill-weknora-0.3.0.zip}`，`BROWSERSKILL_BINARY` /
> `BROWSERSKILL_EXTENSION_PATH` 由镜像 ENV 预设），而 111 **未关闭该功能**。
> 只 `push-app` 换后端二进制 ⇒ 形成「**新网关协议 × 旧扩展实现**」的错配。
> 111 上旧资产的指纹（构建后用于比对）：
> `zip = 2fb46000a21c94f4…`、`bsk = 8c7880f4c3d358ee…`。

### 2.2 会话体验修复（4 条，纯前端）

| 提交 | 现象 |
|---|---|
| `b57c3626` | 较早的消息时间戳只显示时间，改为显示完整日期 |
| `fbf9f54b` | 阻止超滚回弹把输入框推走 |
| `4afda18e` | 消息区超滚时输入框保持固定 |
| `d69df50b` | 知识引用悬浮卡与大纲卡片的对齐 |

### 2.3 文档体系重构（`63ef76dd`，142 文件 / −22083 行）

- 有效文档迁入 **`website-docs/`**（VitePress 站点，183 个文件），**删除 87 篇**旧 `docs/` 手写文档。
- 提供 **`website-docs/MIGRATION.md`**：逐篇给出「旧文档 → 新入口 → 处理方式」映射表，是最省事的照抄依据。
- 连带影响我方引用 **20 处 / 11 个路径**（见 §5.1）。
- 官方同步把 `.env.example` / `docker-compose.yml` 里的 6 条**注释**里的文档路径指向新站（纯注释，无功能影响）。

---

## 三、二开影响评估

### 3.1 合并记录

```
merge-base = 6afb6ca9
官方改动 170 文件 ｜ 我方改动 835 文件 ｜ 交集 1 个：docker/Dockerfile.app
git merge-tree --write-tree wkj-dev main   → 单一 tree（无冲突文件）
git merge main --no-edit                   → 0 冲突，HEAD = cff6cec4
```

★ **本轮交集不为空**，与第 2 轮「零重叠」不同 —— 原因是官方删了
`docker/Dockerfile.app` 里的一行 `COPY`，而这正是我方两个例外文件之一。
自动合并结果正确（我方 ARG 全在、官方删行生效），**无需人工干预**，但下次不能再想当然「必然零冲突」。

### 3.2 二开完整性校验

| 检查 | 结果 |
|---|---|
| 改动丢失（`comm -23 合并前..合并后`） | **0** |
| 关键目录/文件存在性 | `my-docker` `my-frontend` `my-docs` `my-scripts` `my-docreader` `deploy` `AGENTS.md` 全部 ✓ |
| 官方是否动过 `Dockerfile.docreader` | **未动** ✓ |
| 官方是否动过 `Makefile` | **未动** ✓（版本口径那处 `git describe` 的失效条件未触发） |

### 3.3 前端副本同步（本项目特有，必做）

先按判据**验证**「副本无刻意改动」这一判断，而不是直接照做：

| 检查 | 结果 |
|---|---|
| 官方本轮前端改动 | **22 个文件**（`nginx.conf` + 21 个 `src`） |
| `diff -rq frontend my-frontend` | 22 条「内容不同」+ 2 条「仅副本有」（`dist` / `node_modules`） |
| 归因 `comm -13`（差异集 − 官方集）= 我方刻意改动 | **0** |
| 归因 `comm -23`（官方集 − 差异集） | **0** |
| 跟踪文件清单 | 两侧一致（791 = 791） |
| `dist` / `node_modules` | 已被 `my-frontend/.gitignore` 忽略（构建产物） |

⇒ 双向为空 = 差异**全部**来自官方 ⇒ 整体覆盖，不挑着改。

同步做法：`rsync -a --exclude=/dist --exclude=/node_modules frontend/ my-frontend/`
（整树覆盖 + 显式排除副本构建产物；不加 `--delete`，避免误删产物）。

覆盖后 `diff -rq` 仅剩 2 条「仅副本有」；`dist/index.html` 校验和覆盖前后同为 `69e43f2aa514713312f1`。
副本复制点 `6afb6ca9` → **`a89a5a2c`**（已同步更新 `my-docker/README.md`）。

---

## 四、判断：那 2 个例外 Dockerfile 是否还有必要

### 4.1 `docker/Dockerfile.app` —— **仍必要**，且本轮出现「交叉改动」

官方在本文件上只做了一件事：**删掉一行** `COPY patches/browserskill ./patches/browserskill`
（157 → 156 行，删除位置是**第 11 行**）。

我方真正领先的 ARG（官方版本**没有**，不是"两边都声明"的误判）：

| 阶段 | 我方的 ARG |
|---|---|
| browserskill | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY`（git `insteadOf`）/ `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` + `APK_MIRROR_ARG` **条件换源**（须先装 CA 再换源） |
| builder | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `CARGO_REGISTRY_ARG` |

合并后实测：5 个 ARG 全部在位、被删的 `COPY` 已消失，且官方新版
`scripts/build_browserskill.sh` **已不再引用 `patches/`**（自洽）。

**能否不改这个文件？不能** —— Docker 的 `--build-arg` 只有 Dockerfile 里 `ARG` 声明过才可用；
替代路径只有构建机层面解决（daemon proxy / hosts）或预置 artifacts 走离线分支。

> ⚠️ **副作用（本轮新增的行号债）**：官方删的是第 11 行 ⇒ 该行之后所有 `Dockerfile.app:NN`
> 引用**统一 −1**。已按实测修正（见 §5.2）。

### 4.2 `docker/Dockerfile.docreader` —— **仍必要**（官方本轮未动）

我方领先项（`GH_PROXY`：protoc 与 grpc_health_probe 的下载前缀）未变。

---

## 五、连带发现

### 5.1 ★ 官方文档迁移把我方引用打断（本轮新增 20 处悬空）

`docs/` 下 87 篇被删 ⇒ 我方 11 个路径的引用全部失效。**这属于"文件已不存在"这一类**（最高严重度）。
已按官方 `MIGRATION.md` 全部改指新站：

| 旧路径 | 新落点 | 处数 |
|---|---|---|
| `docs/browser-skill-production.md[:88 / :11-23]` | `website-docs/05-clients/09-local-browser.md` | 4 |
| `docs/browser-skill-integration.md` | 同上 | 2 |
| `docs/api/knowledge-base.md`、`docs/api/knowledge.md[:64]` | `website-docs/04-api/02-api-knowledge.md` | 5 |
| `docs/api/tenant.md[:113 / :18-22]` | `website-docs/04-api/02-api-tenant.md` | 3 |
| `docs/agent-prompt-assembly.md:32-40` | `website-docs/06-development/05-agent-prompts.md` | 1 |
| `docs/BUILTIN_MODELS.md` | `website-docs/03-features/06-models.md` | 1 |
| `docs/使用其他向量数据库.md` | `website-docs/03-features/05-retrieval-engines.md` | 1 |
| `docs/添加新的网络搜索引擎.md` | `website-docs/03-features/11-web-search.md` | 1 |
| `docs/数据源导入开发文档.md` | `website-docs/03-features/10-datasource.md` | 1 |
| `docs/IM集成开发文档.md` | `website-docs/03-features/12-im-integration.md` | 1 |

**仍存活、未改动的**（`docs/` 保留下来的工程资源）：`docs/LITE.md`、`docs/swagger.json`、`docs/swagger.yaml`。
（`my-docs/15-docreader定制/…` 里的 `docs/zh/reference/changelog.md` 是 **MinerU 自己仓库**的文档，不属本项目，未动。）

**带行号的引用一律丢弃后缀** —— 官方是把旧文档**重组**进新站（不是原样搬运），沿用旧行号必然是错的。
宁可少一个精度点，也不留一个错的行号。

### 5.2 逻辑纠错：一次我自己制造的二次污染（方法论，值得记）

修正前的 grep 用了 `\bdocs/`。**`\b` 在 `-` 与 `d` 之间也成立** ⇒
`website-docs/01-getting-started/02-installation.md` 里的 `docs/01-…` 子串**也被命中**。

后果有两层，都已修正：

1. **误诊**：我据此把 5 处「本来就是对的 `website-docs/…`」判成"一直写错"。
   用 `git cat-file -e 6afb6ca9:<path>` 复核后否证 —— 那些文件**从来只在 `website-docs/` 下**。
2. **误改**：首版替换脚本没有词边界 ⇒ 把 `website-docs/X` 改成了 `website-website-docs/X`（**8 处**）。
   已 `git checkout` 回滚重做。

**教训（两条硬判据）**：
- 路径类批量替换必须加负向断言 **`(?<![\w-])`**，不能用 `\b`；
- 批量替换**必须**在替换后查二次污染（本次加了 `website-website` 检查）与语法完整性（反引号成对）。

另一处同源错误：替换文本自带反引号时，若只匹配反引号**内部**的片段，会产出 ``` `` ``` 嵌套。
⇒ 键要**连反引号一起匹配**（`` `internal/browserskill/manager.go:178-190` ``）。

### 5.3 行号引用修正（本轮实测值）

| 引用 | 原写 | 现测 | 说明 |
|---|---|---|---|
| `docker/Dockerfile.app:122` | 122 | **121** | 官方删第 11 行 ⇒ 其后 −1 |
| `Dockerfile.app:161`（final 阶段 CA 注释） | 161 | **160** | 同上 |
| `Dockerfile.app:23`（`ARG GOPROXY_ARG`） | 23 | **22** | 同上 |
| `Dockerfile.app:59-61`（builder 阶段 ENV） | 59-61 | **58-61** | 同上 |
| `.env.example:779`（WSS 说明） | 779 | **785** | 第 1 轮就已知的偏移，本轮一并清 |
| `Makefile:256-259` / `:262` | 256-259 / 262 | **275** / **281** | `COMMIT_ID` 在 275、`LDFLAGS` 在 281 |
| `internal/browserskill/manager.go:178-190` | 178-190 | **改为符号引用** | 该文件本轮 1272 → **1373** 行，行号必漂；改指 `pairingEndpoint()` / `pairingURL()` |

> **处置原则落地**：`my-docker/` 侧（配置类注释）已全部改为**符号引用**（函数名/键名定位）；
> `my-docs/` 分析类文档保留行号但本文给出实测值。**历史分析文档（第 1/2 轮）不动** —— 它们是当时核对的快照。
> `my-docs/09-二开现状基线` 的「行号偏移」一行属**欠债登记**（形式是"旧引用 → 实际值"），
> 不是当前引用，误改会自相矛盾，已复原。

### 5.4 无新迁移、无依赖变更

- `git diff --name-only 6afb6ca9..main -- migrations/` ⇒ **0**
- 依赖清单四个文件均未出现在官方改动清单里
- ⇒ 本次部署**不会引入新的表结构变更**；但 app 容器仍会重启并跑一遍 pending 迁移（无 pending，属空转）

### 5.5 工作区遗留一个未跟踪文件（**非本次产出，未处理**）

`my-docs/91-深度使用说明/知识库配置提示词.md`（16 行）—— 内容是若干条**需求陈述式笔记**
（Wiki 内容生成要求、问题生成数量、描述生成要求等），曾引用的提问原文在末尾被截断。
判断为**某轮对话的 WIP 笔记**而非成品文档，故**未提交、未修改**，留给老魏处置。

> 附带确认：该文件只触发部署脚本 `preflight_local` 的**警告**（第 120 行），
> 不影响推送；而脚本第 199 行的 reset 保护判的是 **111 端**工作区（本次实测为**干净**，reset 正常执行）。

---

## 六、部署记录（nanning-111）

### 6.1 部署方式判定：**三条命令，缺一不可**

| 命令 | 为什么需要 |
|---|---|
| `build`（14m51s） | ★ 镜像里内置 `bsk` + 扩展包，官方换了 BrowserSkill 基线（§2.1）⇒ 不重建则「新网关协议 × 旧扩展实现」 |
| `push-ui`（24.8s） | 官方改了 22 个前端文件，定制前端产物须从新源码重建（本地 `npm run build` 后投递，无需重启） |
| `push-app` | 后端二进制由**宿主挂载** `./.build/WeKnora` 提供，镜像里那份被挂载**遮蔽** ⇒ 只 `build` 的话跑的还是旧代码 |

> 反过来也成立：只 `push-app` 会让新网关配上旧扩展。所以**必须 build + push-app 两条都走**。
> 无新迁移（`migrations/` 0 改动）⇒ build 触发的 app 重建只是迁移空转。

### 6.2 验证（全部实测，非"命令成功"即算）

| 项 | 值 |
|---|---|
| 111 部署后 commit | `e2a85d08`（= 本机 HEAD，含并行会话的 `d5b60730`） |
| 容器 | 9 个全部 Up；app / docreader / frontend-wkj / nginx / postgres **healthy** |
| 三个 https 入口（**用 CA 校验，不跳过**） | `https://10.168.1.111/` → **200**；`:41200/` → **200**；`:41280/` → **200** |
| 数据库迁移 | 容器内 `000109` = 仓库 `000109`；库 `version=109, dirty=f` |
| app 外置挂载 | 含 `/app/WeKnora` **与** `/app/migrations`（两层齐备） |
| 二进制内嵌 commit | `handler.CommitID` 命中 **7 处**，期望 `e2a85d08` |
| 二进制产物 | `268M`，`9月23 11:06`；GLIBC 需求 `2.33/2.34/2.35` ≤ 容器上限 `2.36` |
| ★ browserskill 扩展包 | `2fb46000a21c94f4…` → **`33f6d7f995235c9b…`**（已换代） |
| ★ browserskill daemon | `8c7880f4c3d358ee…` → **`582fffcce8030ff2…`**（已换代） |
| 定制前端产物标记 | `e2a85d0` 命中 `assets/Settings-DPxvdS7N.js` |
| searxng | HTTP 200 且**命中 15 条结果**（只看 200 会漏判引擎不可达） |

### 6.3 过程纠错：一次被实测否证的自我怀疑（方法论）

我一度判断「**build 在提交副本同步之前就启动了** ⇒ 111 上不含副本同步」。
按时间戳复核后**否证**：

| 时刻 | 事件 |
|---|---|
| 10:47:01 | 合并提交 `cff6cec4` |
| 10:49:42 | 副本同步提交 `67da04fd` |
| 10:49:58 | **build 启动**（脚本第一步即 push） |
| 10:59:46 | 并行会话的 `d5b60730`（110 OCR 文档） |

⇒ 提交早于 build 启动 **16 秒**，且 111 实测 commit = `67da04fd` ✓。结论：**没有**漏推。

但由此确立两条纪律：

1. **脚本第一步就 push** ⇒ 所有需要部署的提交**必须在发起命令之前**完成。
   本次侥幸未踩（16 秒的余量），但这是**没有安全边际**的 —— 违反的后果是
   「输出全绿、容器全 Running，而挂载/配置实际是旧的」（见部署技能坑 12）。
2. ★ **前端产物内的 commit 标记 ≠ 前端内容的来源提交**。
   `push-ui` 用**当时的 HEAD** 打标（本次 = `e2a85d0`，属文档提交），
   而真正改 `my-frontend/` 的是 `67da04fd`。
   ⇒ 核验前端版本应**比对产物内容**，不要只认标记。

### 6.4 一处**未做**的事

`my-docker/nginx/nginx.conf` 本轮只改了注释里的文档引用（`docs/…` → `website-docs/…`）。
提交后 111 会同步到新内容，但 nginx 的 `config-hash` **不含文件内容**
⇒ `up` 不会重建 nginx（实测其状态一直是 `Up 41 hours`），**这是预期的**：
注释改动无需生效动作。若真想让它"生效"，只有 `up -d --force-recreate nginx`，**不必要**。

---

## 七、待办

1. **BrowserSkill 换基线后需实测配对闭环** —— 官方换了扩展实现（补丁 05 改宿主侧），
   配对、预览、末标签页关闭三条路径都应复验。
2. **`docs/` 与 `website-docs/` 的双份引用**：本轮只把 87 篇中的引用改指新站；
   若后续再遇官方文档重组，应按同样流程走 `MIGRATION.md`。
3. 工作区那个未跟踪文件（§5.5）待老魏确认。
4. `my-docs/09-二开现状基线` 的「90 处引用」统计已过期（本轮清理后失真面显著缩小），
   下次触及该文档时一并重算。

---

## 八、证据（可复核）

```bash
# 规模与发版
git rev-list --count wkj-dev..main                 # 6
git describe --tags main                           # v0.8.0-252-ga89a5a2c

# 冲突预判（MB=6afb6ca9）
git diff --name-only $MB..main | sort > /tmp/up.txt
git diff --name-only $MB..wkj-dev | sort > /tmp/dev.txt
comm -12 /tmp/up.txt /tmp/dev.txt                  # docker/Dockerfile.app （唯一交集）
git merge-tree --write-tree --name-only wkj-dev main   # 单 tree，无冲突

# 官方对 Dockerfile.app 的唯一改动
git show a89a5a2c -- docker/Dockerfile.app          # 删第 11 行 COPY patches/browserskill

# 完整性
git diff --name-only $MB..HEAD | sort > /tmp/after.txt
comm -23 /tmp/dev.txt /tmp/after.txt                # 空

# 编译
OUT=$(go build ./... 2>&1); echo "exit=$?"

# 前端副本归因
git diff --name-only $MB..main -- frontend/ | sed 's|^frontend/||' | sort > /tmp/fe_up.txt
diff -rq frontend my-frontend | grep "^Files" | sed 's|^Files frontend/||; s| and .*||' | sort > /tmp/d.txt
comm -13 /tmp/fe_up.txt /tmp/d.txt                  # 空（我方刻意改动 0）
comm -23 /tmp/fe_up.txt /tmp/d.txt                  # 空

# 迁移与依赖
git diff --name-only $MB..main -- migrations/        # 空
git diff --name-only $MB..main -- go.mod go.sum docreader/requirements.txt frontend/package.json
```

**关键 hash**

| 项 | 值 |
|---|---|
| 同步前 merge-base | `6afb6ca9` |
| 官方新 HEAD | `a89a5a2c` |
| 合并提交 | `cff6cec4` |
| 副本同步提交 | `67da04fd` |
| 副本复制点（更新后） | `a89a5a2c` |
| 111 部署前 HEAD | `20a9ff8f` |
| 111 迁移基线（部署前） | `version=109, dirty=f` |
