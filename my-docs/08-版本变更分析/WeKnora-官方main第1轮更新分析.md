# WeKnora 官方 main 更新分析（第 1 轮）

> 同步区间：`5c5d46d9` → `cc82e75c` ｜ 合并提交：`062fc1b4`
> 记录时间：2026-09-21

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **36 个** |
| 版本 | `v0.8.0-221-gcc82e75c` —— **无新发版**（仍是 v0.8.0 之后） |
| 合并方式 | `git merge main --no-edit`（在 `wkj-dev` 上，未切分支） |
| 冲突 | **零冲突** |
| 依赖面 | `go.mod`：删 `github.com/sashabaranov/go-openai`；`golang.org/x/sys` 由 indirect 提为直接 |
| 编译验证 | `go build ./...` → **exit=0**（仅第三方库警告） |

**冲突预判（三点比较，以 merge-base 为基准）**：官方改 550 个文件、我们改/增 790 个，
**交集为空**。这是"官方层 + 定制层物理分离"策略的直接收益 —— 官方改 456 个 `internal/`
文件、66 个 `frontend/` 文件，与我们的定制面**零重叠**。

## 二、更新内容（使用视角）

- **模型厂商目录重建**：`c40a9dd1` / `9030f556` / `d6c7665c` / `9aa63c86` 等系列提交，
  把 embedding / rerank / ASR 的 wire format 拆进 protocol 包，并**修正四处与厂商文档不符的请求体**。
  新增 `make model-catalog-check` / `make model-catalog-diff` 两个校验入口。
- **本地沙箱**：`7d688cb8` 新增 host OS sandbox 核心 + macOS Seatbelt 后端。
- **会话原地回退**：`d4b9fd0c` in-place rewind with workspace checkpoint reset。
- **PDF 解析**：`cc82e75c` PDF 保持走 builtin，不再默认 anydoc。
- **前端**：`7fa6f028` 重做已保存答案的 Markdown 编辑器；`9e0c28fb` 生成文件可删除；
  `a163bab3` 重做解析时间线面板。
- **一处 docs 修正**：`a62a51e6` 不再声称 MySQL 是受支持的 `DB_DRIVER`。

## 三、二开影响评估

### 3.1 完整性校验（合并后必做）

```
git diff --name-only 5c5d46d9..HEAD  ⊇  我们的改动清单   ⇒ 零丢失 ✓
my-docker / my-frontend / my-docs / deploy / AGENTS.md  ⇒ 全部在位 ✓
```

合并后相对官方最新版的改动面：**788 新增 / 2 修改 / 0 删除**。

### 3.2 官方改了我们依赖的文件吗？

官方改了 `docker-compose.yml`、`Makefile`、`.env.example` —— 三者我们**都没有改**（故无 git 冲突），
但我们的 overlay 与文档**引用**它们，因此逐一看过：

| 文件 | 官方改动 | 对 overlay 的影响 |
|---|---|---|
| `docker-compose.yml` | 仅在 `app` 的 volumes 加 **3 行注释**（model catalog overlay 说明） | **无**（纯注释） |
| `Makefile` | 新增两个 `.PHONY` target + help 文本 | **无**（我们只依赖其 COMMIT_ID/LDFLAGS 注入段） |
| `.env.example` | 加 6 行 SEARXNG 警告 + 若干注释修订 | **无实体影响**，但**行号引用失真**（见 4.1） |

## 四、判断：那 2 个 Dockerfile 的修改是否还有必要？

**结论：全部仍必要，无一处冗余。**

### 4.1 我们真正领先的改动

官方最新版仍然**没有**以下能力，因此这些修改必须保留：

| 改动 | 位置 | 作用 |
|---|---|---|
| `APK_MIRROR_ARG` 条件换源 | `Dockerfile.app` 的 **browserskill** 阶段 | 该阶段基镜像是 `node:24-bookworm-slim`，**不带 CA**；国内镜像 http 会 302 跳 https ⇒ 无 CA 时 apt 索引被静默忽略（**假成功**）。故须"先用官方源装 CA、再换源" |
| `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` | browserskill + builder 两阶段 | Rust 工具链下载源（实测官方 36KB/s ⇒ 约 2 小时） |
| `GH_PROXY` | browserskill（git insteadOf）+ `Dockerfile.docreader` 两处 release 下载 | GitHub 反代（实测直连 0~40KB/s 且常中断） |
| `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` | browserskill 阶段 + builder 的 anydoc 编译 | npm / crates 源 |

### 4.2 曾经以为"官方抄了我们的"——其实不成立

初看官方版也声明了 `GOPROXY_ARG` / `GOSUMDB_ARG` / `APK_MIRROR_ARG` / `VERSION_ARG` /
`COMMIT_ID_ARG` / `BUILD_TIME_ARG` / `APT_MIRROR`，一度怀疑我们这部分已冗余。
但 `git diff main..HEAD` 显示这些行是**上下文行（未改动）**，即**官方一直就有，不是我们加的**。

> 教训：判断"某改动是否冗余"必须看 diff 的 **+/- 归属**，不能只比两边的符号列表 ——
> 两边都有 ≠ 我们加的。

### 4.3 能否不改文件就实现？

**不能。** Docker 的 `--build-arg` 只有在 Dockerfile 里 `ARG` 声明过才可用；
官方不声明这些 ARG，我们就只能改 Dockerfile。

**可选的替代路径**（不改官方文件，但换了代价位置）：
- 在**构建机层面**解决 —— 给 Docker daemon 配 proxy，或改 hosts。缺点：属环境配置而非项目配置，
  换机器就要重做，且影响所有构建。
- **预置 artifacts** 走离线分支（`Dockerfile.docreader` 已有 protoc 的离线分支，
  部署脚本的 `_ensure_build_artifacts` 也在这个方向）。

这三条改动本身是**中性 ARG**（留空即回落官方行为），所以它们对上游合并的干扰极小 ——
这也是为什么本轮 36 个提交能做到零冲突。

## 五、连带发现

### 5.1 ★ 行号引用会静默失真（本轮实测 3/4 处已偏）

官方插入了 15 行（Makefile）与 6 行（.env.example），结果：

| 引用位置 | 文档原写 | 实际 |
|---|---|---|
| overlay 注释 | `Makefile:256-259` / `:262` | **275** / **281** |
| overlay 注释 | `Dockerfile.app:59-61` | builder 段已后移 |
| overlay 注释 | `.env.example:779` | **785** |
| overlay 注释 | `internal/browserskill/manager.go:178-190` | 185-186（区间内）✓ |

**处置**：overlay 里的这几处已**改为符号引用**（靠段名定位，不靠行号），并就地注明理由。

**待办**：`my-docs/03-生产部署/WeKnora-生产部署与运维.md` 与
`my-docs/04-功能机制解析/WeKnora-BrowserSkill配对与WSS约束.md` 也含官方文件行号引用，
需按本次合并后的实际位置核对一遍。

### 5.2 官方新增的 SEARXNG_PORT 警告 —— 与我们的方案相容

`68e21b6e docs(env): warn against SEARXNG_PORT colliding with APP_PORT`（仅改 `.env.example`）
新增警告原文要点：

> 不要把 `SEARXNG_PORT` 设成与 `APP_PORT`（默认 8080）相同。Linux 上若 SearXNG 绑
> `127.0.0.1:8080` 而 app 也发布 `:8080`，`localhost:8080` 会先命中 SearXNG，
> 导致 `POST /api/v1/auth/login` 返回 SearXNG 的 HTML 404。建议保持 8888 或其他空闲端口。

**对我们的意义**：拟为 searxng 分配的 `41291` 与 `APP_PORT=8080` **不冲突**，
正落在官方建议的"另一个空闲端口"上 ⇒ 原方案不受影响。

## 六、待办

1. `my-docs` 两个文件里的官方文件行号引用需核对（见 5.1）。
2. `my-docker/README.md` 的「副本复制点」占位符 `____________` 仍为空（建议 `5c5d46d9`）。
3. searxng 接入的五处改动（端口 `41291`）—— 方案已出、尚未动手。
4. `41200–41299` 的端口分配规律仍待老魏明确。

## 七、证据

- 同步区间与合并：`git log --oneline 5c5d46d9..cc82e75c`（36 条）、`062fc1b4`
- 冲突预判：`git diff --name-only $(git merge-base wkj-dev main)..main` 与 `..wkj-dev` 的
  交集为空（550 / 790 文件）
- 改动面：`git diff --name-status main..HEAD` ⇒ 788 A / 2 M / 0 D
- 编译：`go build ./...` → exit=0
- Dockerfile 差异：`git diff -U2 main..HEAD -- docker/Dockerfile.app docker/Dockerfile.docreader`
- 行号核对：`grep -n` 于 `Makefile` / `.env.example` / `docker/Dockerfile.app`
