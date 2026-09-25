# WeKnora 官方 main 更新分析（第 7 轮）

> 同步日期：2026-09-25 ｜ 范围：`5d00985f`（第 6 轮）→ `68fe9599`
> 合并提交：`4e7f5d5c`（回滚点 `a6a1c59a`）｜ 副本同步：`d345b250`

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **13** |
| 改动规模 | **378 文件 / +24,909 −3,413** |
| 是否发版 | **否**（`git describe` = `v0.8.2-20-g68fe9599`；上个 tag 仍是 `v0.8.2`） |
| 依赖面 | **未动**（`go.mod` / `go.sum` / `frontend/package.json` / `package-lock.json` / `docreader/` 全无改动） |
| 新迁移 | **2 个 versioned**：`000112_embeddings_knowledge_chunk_index`、`000113_chunk_images`（另 sqlite `000032_chunk_images`、`paradedb/00-init-db.sql` 调整） |
| `go build ./...` | **exit=0**（33 秒；仅 `-lc++` 重复库告警，macOS 常态） |
| 官方是否动 `docker/` | **否** ⇒ 我方 2 个例外 Dockerfile 安全 |

**体量偏大的原因**：378 文件里含 `docs/images/` 48 张 README 配图与 4 个 README 重写（+1088/−957），
属文档层。真正的代码改动集中在 `internal/application`(115) / `frontend/src`(59) / `internal/agent`(20) /
`internal/types`(24) / `internal/localsandbox`(15)。

---

## 二、更新内容（使用视角）

### 2.1 ★★ 官方原生支持 MinerU 4.0 V1 API（`e22a8367`）—— 本轮最重要

**这条直接改变了我方的一处重大决策**（详见 §五.1）。

- **不是新引擎**：仍是同一个 `mineru` 引擎，靠 `GET {endpoint}/v1/health` **按请求自动探测协议**：

  | 探测结果 | 协议 | 适用版本 |
  |---|---|---|
  | `200` + `status=ok` | **V1**（5 步异步，新增 `mineru_v1_client.go` 594 行 + 测试 433 行） | MinerU **≥ 4.0** |
  | `404` / `405` | 旧版 `POST /file_parse`（同步） | MinerU **≤ 3.x** |
  | `503` 带错误结构 | 直接报错，**不回退**旧协议（常见于模型预加载失败） | — |

- **新增两个配置项**：`mineru_server_api_key`（4.0+ 服务端 `--api-key`，以 `Authorization: Bearer` 发送）、
  `mineru_tier`（`flash`/`basic`/`standard`/`advanced`，留空由服务端选默认，优先 `standard`）。
- **旧参数在 4.0 下被忽略**：`mineru_model` / `mineru_vlm_server_url` / `mineru_enable_formula` /
  `mineru_enable_table` / `mineru_language`（官方原话："4.0 已删除这些参数；VLM 地址改在 MinerU 的
  `config.yaml` 里配置"）。`mineru_parse_method` 在 V1 下映射为 `ocr_mode`。
- **探测盲区已修**：`PingMinerU(endpoint, apiKey)` 现在额外请求一次**需要鉴权**的
  `GET /v1/parse/jobs?limit=1`，用来发现 API Key 缺失/错误（`/v1/health` 本身不校验 Key）。
  ⇒ 我们曾记录在案的坑「**探测通过 ≠ 契约匹配**」被官方正面修掉了。
- **V1 流程细节**（官方文档）：上传带 `sha256sum` 去重；**仅同源**（scheme/host/端口都相同）才附带
  API Key，跨源仍照常过 SSRF 校验；轮询 2s 起指数退避、上限 30s、总时长仍 1000s；
  超时/取消会 `DELETE /v1/parse/jobs/{id}`；**服务端重启后正在轮询的任务会 404**（状态存在进程内存）。
- **前端**：`ParserEngineSettings.vue` 拆成两段 —— 4.0 段（Endpoint / API Key / 档位 / 解析方式）
  + legacy 段（Backend / vLLM 地址 / 识别选项）；5 个语言文件同步。
- **无需数据库迁移**（配置存在 `tenants.parser_engine_config` 的 JSONB）。
- **升级 MinerU 不需要改 WeKnora 的配置**（官方原话）。

### 2.2 检索质量与协议统一

| 提交 | 内容 |
|---|---|
| `04adc132` | **recall 正确性 + 分数尺度 + 成本 + agent 工具**综合修复（#3687） |
| `9fc08c20` | **rerank 在各检索 API 间统一**，并暴露诊断（#3675） |
| `65d8129c` | ES `CopyIndices` 保留向量与 enabled 状态（#3678） |

### 2.3 新功能

- `68fe9599` **图库标签页**（schema 驱动筛选，#3694）
- `e2433b12` **Lite 版可在宿主机安装并运行 skills**（#3661）

### 2.4 修复

- `c029b50e` RSS **拒绝超限响应**，避免正文被静默截断
- `65d8a34e` desktop：把 Lite 浏览器配对到**本地 API 监听地址**（#3677）
- `3cf0be2e` embed：**未配置签名密钥时启动告警**
- `9253b2c1` 前端文档链接改指**公开文档站**（不再指 GitHub）

### 2.5 文档

- `44a1df60` / `e896270c` / `7e82ee33`：4 个 README 重设计（与官网视觉对齐）+ 概览页 + 介绍视频
- `website-docs/` 同步（含 §2.1 的 MinerU 4.0 章节）

---

## 三、二开影响评估

### 3.1 合并记录

| 项 | 值 |
|---|---|
| 回滚点 | `a6a1c59a` |
| 合并提交 | `4e7f5d5c`（parent1=`a6a1c59a`，parent2=`68fe9599`） |
| 冲突 | **0**（`git diff --diff-filter=U` 为空） |

### 3.2 冲突预判：双方法确认

```bash
# 方法一：三点比较（merge-base = 5d00985f）
#   官方 378 文件 / 我方 862 文件 → 交集 0
# 方法二：merge-tree 预演（不碰工作区）
git merge-tree --write-tree --name-only wkj-dev main
#   → ab1585c2ce8770e3acf7805a2b05bfa9dea7747f（单 tree OID = 干净）
```

### 3.3 二开完整性校验

```bash
comm -23 /tmp/dev.txt /tmp/after.txt   # → 空（零丢失）
# 关键目录：my-docker / my-frontend / my-docs / deploy / AGENTS.md / my-scripts 全部在位
```

### 3.4 前端副本同步（判据成立）

老魏判断「定制前端无实际修改，直接覆盖」——**实测证实该判断成立**：

```bash
# 归因分析：差异能否全部归因于官方
comm -13 /tmp/fe_up.txt /tmp/d_all.txt
#   → 仅 2 条「目录级」条目（src/api/image-gallery、src/views/knowledge/gallery），
#     系 diff 的目录粒度差异（官方改动列表是文件级），**非真实改动**
rsync -a --exclude=/dist --exclude=/node_modules frontend/ my-frontend/
diff -rq frontend my-frontend | wc -l    # 59 → 2（仅 dist / node_modules 两项产物）
```

| 项 | 值 |
|---|---|
| 提交 | `d345b250`（60 文件 = 45 改 + 14 新增 + 1 个 README 复制点） |
| 新增文件 | 14 个（`api/image-gallery/`、`views/knowledge/gallery/`、6 组 `utils/*` 含测试） |
| ★ 跟踪清单 | `my-frontend` 816 → **830** = `frontend` **830** ✅（差的 14 正是上述新增未跟踪文件） |
| `dist/index.html` sha256 | 覆盖前后均 `9a3272d8…` ⇒ 构建产物未受影响 |
| 副本复制点 | `my-docker/README.md`：`5d00985f` → **`68fe9599`** |

> ★ 再次命中技能里记过的坑：「**副本计数差异 ≠ 副本失真**」——
> `ls-files` 差 14，先查是不是"新增文件尚未纳入版本控制"，而不是急着判副本失真。

---

## 四、★ 2 个例外 Dockerfile 的必要性判断

**结论：仍然必要；本轮官方未动 `docker/`，我方改动不受影响。**

`git diff upstream/main..HEAD -- docker/` 的 `+` 行仍**只有我方新增项**：

| 文件 | 我方领先的 `+` 行 |
|---|---|
| `docker/Dockerfile.app` | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`；以及 browserskill 阶段的 `APK_MIRROR_ARG` 条件换源（该阶段基镜像是 `node:24-bookworm-slim`，**不带 CA**，必须先官方源装 CA 再换源，否则 apt 静默假成功） |
| `docker/Dockerfile.docreader` | `GH_PROXY`（protoc / grpc_health_probe 的 GitHub 加速前缀）—— **与 OCR 无关，勿误删** |

⇒ 无一条冗余（`--build-arg` 只有 Dockerfile 里 `ARG` 声明过才可用 ⇒ 无法改为纯编排注入）。

---

## 五、连带发现

### 5.1 ★★ `my-docs/16-解析引擎扩展/` 的方案**已作废**（官方原生解决）

我方 2026-09-24 评估的「新增 `mineru_v4` 引擎」方案，其**唯一实质代价**是
「**官方文件改动面 2 → 10+、上游不再零冲突**」。官方 `e22a8367` **隔一天**原生实现了该能力
（且更完整：含前端 UI 与 5 个语言文件）⇒

- **不需要再改任何官方文件**，改动面**保持 2 个**；
- 110 侧**不需要写契约适配器**（原方案 A）；
- 16 号文档已改写为**结案说明**；15 号文档 §八 的结论已订正。

> 我方在该方案 §6 里预判过这条风险："上游将来自己适配 4.x ⇒ 可平滑切换到上游实现"——
> **它隔一天就发生了**，且方向比预判更好：官方改的是**同一个引擎**、**探测式兼容**，
> 连旧协议都不必放弃（我们原方案是"并存两个引擎"）。

### 5.2 ★ `container.go` 被官方改动，但**净 0 行** ⇒ 行号不漂移

官方在 `:365` 附近把 `service.NewHostSessionResolver(pinner, host.Manager)` 改为
`(pinner, host.Manager, host.Desktop)` —— **1 插入 / 1 删除，且位置在我们引用的 `:889` 之前**
⇒ 我方引用的 `AUTO_MIGRATE`(`:889`) / `AUTO_RECOVER_DIRTY`(`:892`) / `RunMigrationsWithOptions`(`:900`)
**全部仍然有效**（实测 grep 命中一致）。

### 5.3 ★ 改动面口径：实测 **3 个**，其中 1 个是「我方新增」而非「改了官方」

```bash
git diff --name-status upstream/main..HEAD -- ':!my-*' ':!deploy' ':!AGENTS.md'
#   A  README-WAKE.md
#   M  docker/Dockerfile.app
#   M  docker/Dockerfile.docreader
```

`README-WAKE.md` 是我方文件（`3fce01e2`，2026-09-20 引入），**不在官方仓库中**，
性质与那 2 个 Dockerfile **不同**：它不修改官方文件、不产生合并冲突。
但按 AGENTS.md §1「新增文件也不要放进官方目录」，它放在仓库根是有张力的。

⇒ 建议把口径拆成「**改官方文件 2 个**」+「**新增顶层文件 1 个**」两条，
避免"改动面 = 2"的表述与实测长期不一致（**待老魏定夺，见 §七.1**）。

### 5.4 其余行号敏感文件本轮**全部未动**

`Makefile` / `docker-compose.yml` / `.env.example` / 两个 Dockerfile —— 实测均未被官方改动
⇒ 我方文档里引用它们的行号（`Makefile:275/281`、`.env.example:74/785`、
`docker-compose.yml:608-610 / :565 / :1038`、`Dockerfile.app:58-61 / :121 / :160`、
`Dockerfile.docreader:60`）**全部仍然有效**。

### 5.5 本轮修复了一条我们曾记录在案的坑

「探测通过 ≠ 契约匹配」（`my-docs/15-docreader定制/` §8.3）—— 官方 `e22a8367` 把 `PingMinerU`
从"只看 `/docs` 状态码"改为"**额外请求一次需鉴权的 `/v1/parse/jobs?limit=1`**"
⇒ 该盲区已被官方正面关闭。

---

## 六、★ 部署判断：**必须部署**

| 判断项 | 结论 |
|---|---|
| 是否需要 build | **不需要**（依赖面未动、未改例外 Dockerfile） |
| 是否需要 `push-app` | **需要**（本轮 `internal/` 大改，含 MinerU V1 客户端） |
| 是否需要 `push-ui` | **需要**（`frontend/src` 59 文件，含解析引擎设置 UI） |
| 是否需要 `push-reader` | **不需要**（`docreader/` 未动） |
| ★ 是否必须先备份 | **必须** —— 新增迁移 `000112` / `000113`，app 启动会自动跑 |

---

## 七、待办

1. **口径定夺**：`README-WAKE.md` 是移出仓库根（AGENTS.md §1），还是把"改动面"拆成
   「改官方文件 2 个」+「新增顶层文件 1 个」（见 §5.3）。
2. **部署后实测**：在 111 上验证 MinerU 4.0 V1 是否真的打通（配置 + 上传扫描件）。
3. 15 / 16 两份文档的订正已随本轮提交。

---

## 八、证据（可复核）

```bash
# 规模与发版
git rev-list --count 5d00985f..68fe9599          # 13
git diff --shortstat 5d00985f..68fe9599          # 378 files changed, +24909 −3413
git describe --tags 68fe9599                     # v0.8.2-20-g68fe9599

# 依赖面（应为空）
git diff --name-only 5d00985f..68fe9599 -- go.mod go.sum frontend/package.json \
    frontend/package-lock.json docreader/

# 新迁移
git diff --name-status 5d00985f..68fe9599 -- migrations/

# 冲突预判（双方法）
git merge-tree --write-tree --name-only wkj-dev main   # 单 tree OID

# 例外 Dockerfile（官方是否动过）
git diff --name-status 5d00985f..68fe9599 -- docker/   # 空

# 副本判据
diff -rq frontend my-frontend | wc -l            # 2（仅产物）
shasum -a 256 my-frontend/dist/index.html        # 9a3272d8…（覆盖前后一致）

# container.go 行号
grep -n "AUTO_MIGRATE\|RunMigrationsWithOptions" internal/container/container.go   # 889 / 900
```
