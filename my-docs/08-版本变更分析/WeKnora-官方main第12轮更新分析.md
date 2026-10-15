# WeKnora 官方 main 第 12 轮更新分析（2026-10-15）

> 同步区间：`e7aaf8ae`（第 11 轮复制点）→ `450b6ed1`，共 **142 个提交**，官方发版 **v0.8.3**（main 现位于 v0.8.3 后 15 个提交）。
> 本轮为我方主动发起的完整同步：合并 → 校验 → 构建验证 → 副本同步 → 引用订正。

## 1. 概览

| 项 | 值 |
|---|---|
| 提交数 | 142（fix 91 / feat 33 / docs 8 / 其余 10） |
| 发版 | **v0.8.3**（本轮区间内发布） |
| 官方改动面 | 1034 文件 |
| 我方改动面 | 923 文件 |
| 交集 | 仅 2 个例外 Dockerfile（见 §4） |
| fetch 耗时 | 21 秒（链路波动大，本轮偏快） |
| `go build ./...` | **exit=0**（仅 macOS 桌面构建既有 ld 重复库警告） |
| 合并提交 | `6bb2a7272`；回滚点 `144efc6f` |

## 2. 更新内容（用户可感知）

### feat（新功能）
- **内置 WeKnora 助手（本轮最大主题，约 12 个提交）**：内置 assistant + 操作目录（#4302）、可读捆绑文档（#4303）、任意页面带上下文唤起（#4314）、无需自带 rerank 即可搜索（#4315）、开放更多工作区操作（#4318）、批量删除/移动文档（#4319）、管理 FAQ 条目（#4327）、侧边栏 + 访问级别 + 角色感知操作（#4342）、human-in-the-loop 提示持久化（#4250）。
- **MCP OAuth 补全**：无浏览器调用方也能获取 token（#4229）、工具批准后再弹 OAuth（#4248）。
- **模型**：Claude Opus 5.5 / Sonnet 5.5 / Haiku 5.5 进入目录（#4158）；WeMM embedding 预设 + Transformers serving（#4238）；Cohere rerank v2 provider。
- **检索/搜索**：RRF 控制项进 tab 式设置弹层（#4300）；知识库描述 token 预算可配置（#4230）。
- **图库**：按源文档过滤（#4159）、无限瀑布流滚动替换分页（#4156）。
- **系统**：平台用户管理 + 设置页精简（#4153）。
- **wiki**：图谱布局、主题标注、分组聚焦改进（#4147）。
- **聊天**：@ mention 菜单全局搜索（#4249）、completion 事件标注本轮聊天模型（#4252）、rewind 确认与未读回复标记（#4247）。

### fix（修复）——挑与我们相关的
- **安全**：agent 数据库查询收敛到已授权共享知识库（#4136）—— 我们 41280 前端对外暴露，**下轮部署应尽快跟进**。
- OAuth token 过期与进程时区解耦（#4207）；OAuth 后只关授权用户连接（#4138）；MCP 资源列举分页加界（#4007）。
- Claude 模型不再发送其拒绝的 temperature（#4155）。
- 飞书 Wiki 同步共享限速 + 429/99991400 重试（#4039）。
- 手动 Markdown 文档的引用定位（#4278）；EPUB 预览保留内联图片（#4226）；qdrant 并发建集合（#3999，我们不用 qdrant）。
- GitLab 数据源空文件旧正文残留可搜（#4008）。
- 知识库设置提示、侧栏/列表/引用 UI polish（#4193 / #4154）。

### 基建
- compose：新增 `WEKNORA_OUTBOUND_DIAL_TIMEOUT`、`WEKNORA_PADDLEOCR_VL_CLOUD_TIMEOUT`、`WEKNORA_WEKNORACLOUD_TIMEOUT` 透传；docreader 构建新增 `PLAYWRIGHT_DOWNLOAD_HOST` / `PLAYWRIGHT_WEBKIT_DOWNLOAD_HOST` ARG。
- **paradedb 镜像 `v0.22.6-pg17 → v0.25.11-pg17`**（#4120，配套迁移见 §3/§6）。
- helm：rollouts / 共享存储 / Service 名称覆盖修复。
- `docs/` 本轮**无**重构（0 删除），`website-docs/` 新增 29 篇。

## 3. 二开影响评估

- **合并**：`git merge main` 仅 `docker/Dockerfile.app` 1 处内容冲突（双方都改了 browserskill 阶段的 apt 换源块，逻辑逐字同构，取官方注释版解决）；`Dockerfile.docreader` 自动合并干净。
- **完整性校验**：`comm -23 dev.txt after.txt` 为空 ⇒ **零丢失**；`my-docker / my-frontend / my-docs / deploy / AGENTS.md / docreader` 全部在位。
- **迁移**：新增 versioned 迁移 **6 个（000115–000120）**（sqlite 侧另有 000034–000038，与我方 PG 无关），其中 `000115_pg_search_02511` 配 paradedb 升级。⚠️ 111 是正式数据 + `AUTO_MIGRATE` 默认开启 ⇒ **下次 app 容器重建即自动执行**，部署前先备份（见 §6）。
- **前端副本**：官方动 `frontend/` 230 文件、`package.json`/`package-lock.json` 均变。归因分析：差异全部可归因官方（仅 dist/node_modules 产物 + 1 条官方删除文件的目录级假阳性）⇒ 我方刻意改动 **0**，整体 rsync 覆盖；官方删除的 `chat-citations.test.mjs` 在副本同步删除；`npm install` 补装后 lock 与官方**逐字一致**；跟踪文件数 **918 = 918**；`dist/index.html` sha256 前后一致（产物未动）。
- **compose 基底**：overlay 未钉 paradedb/postgres 镜像 ⇒ 官方 paradedb 升级随合并流入，下次部署生效。

## 4. 两个例外 Dockerfile 的必要性判断（合并后重判）

| 文件 | 官方本轮动作 | 我方剩余领先改动 | 结论 |
|---|---|---|---|
| `Dockerfile.app` | **原生新增** browserskill 阶段 `APK_MIRROR_ARG` 条件换源（先装 CA 再换源，与我方写法逐字同构）⇒ 我方该段足迹**已消除**（冲突按官方版解决） | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`（browserskill + builder 两阶段） | **仍必要**（官方未覆盖 rustup/gh/npm/cargo） |
| `Dockerfile.docreader` | 新增 `PLAYWRIGHT_DOWNLOAD_HOST` ARG（与 `GH_PROXY` 无关） | `GH_PROXY`（protoc 下载 :65、grpc_health_probe :141） | **仍必要** |

我方对官方文件的总足迹从本轮前的两文件 ~60 行降至 **app +43 / docreader +11 行**，纯增量 ARG + 条件包一层，留空即官方行为。

## 5. 连带发现

- 官方 `Dockerfile.docreader` 的 Playwright webkit 安装现在也走条件下载源 —— 若 111 构建慢可顺带在 compose build.args 注入 `PLAYWRIGHT_DOWNLOAD_HOST`，不必改文件。
- `WEKNORA_OUTBOUND_DIAL_TIMEOUT` 默认空 = 5s；111 访问外部模型端点若偏慢可在 `.env` 调大。
- 官方 docreader 入口 CMD 已是 `["/app/.venv/bin/python","-m","docreader.main"]`（非 `uv run`），我方文档已订正。

## 6. 待办

- [ ] **部署前备份 PG**（本轮带 6 个 versioned 迁移（000115–000120）+ paradedb 大版本升级，`AUTO_MIGRATE` 会在 app 启动时自动执行）：按 `my-docs/11-数据安全与备份` 方案执行后再推 gitea111 部署。
- [ ] 部署时关注 `000115_pg_search_02511` 与 paradedb v0.25.11 的先后（迁移设计上应兼容，但 app 迁移跑在旧 paradedb 镜像上的窗口需确认）。
- [ ] `my-docs/07-前端定制方案` 中 `frontend/Dockerfile:30-49` 为存量行号引用（本轮官方未动该文件，暂无漂移），下次顺手改符号引用。
- [ ] 未推 gitea111 / origin（老魏未要求）。

## 7. 证据（可复核）

```sh
# 区间与发版
git rev-list --count wkj-dev@{1}..main   # 142（merge 前视角）
git describe --tags main                 # v0.8.3-15-g450b6ed1b
# 冲突预判
MB=e7aaf8ae; git merge-tree --write-tree --name-only wkj-dev main   # 仅 Dockerfile.app 冲突
# 完整性
comm -23 /tmp/dev.txt /tmp/after.txt     # 空 = 零丢失
# 构建
go build ./...                           # exit=0
# 副本
diff -q frontend/package.json my-frontend/package.json            # 一致
git ls-files frontend | wc -l   # 918
git ls-files my-frontend | wc -l # 918
sha256sum my-frontend/dist/index.html  # b7443ae9… 前后一致
```

合并提交 `6bb2a7272`，回滚点 `144efc6f`。
