# WeKnora 二开现状基线

> 盘点时间：2026-09-21 ｜ 盘点时 HEAD：`a00335d4`（wkj-dev）

## 一、一句话结论

二开层与官方层**已同步**（merge-base = `cc82e75c` = upstream/main），但 **`my-frontend/` 已不满足"逐字副本"判据** ——
它落后官方一个版本（66 项差异），且**我们自己在副本里一处未改**。这是开始前端二开前必须先处置的事。

## 二、git 状态

| 项 | 值 |
|---|---|
| 分支 | `wkj-dev` |
| 与上游 | **领先 42 / 落后 0**（已同步） |
| merge-base | `cc82e75c`（= upstream/main） |
| 改动面 | **789 新增 / 2 修改 / 0 删除** |
| 未提交改动 | 无（工作区干净） |
| 唯一的 2 个"修改" | `docker/Dockerfile.app`、`docker/Dockerfile.docreader`（中性 ARG，国内网络换源） |

## 三、二开资产清单

| 资产 | 规模 | 角色 |
|---|---|---|
| `my-frontend/` | 770 文件 | 定制前端源码（官方 `frontend/` 的副本） |
| `my-docker/` | 5 文件 | 容器组定制层（overlay + nginx 接入层 + README） |
| `deploy/` | 2 文件 | 部署脚本（`deploy-wkj-dev.sh`） |
| `my-docs/` | 12 文件 / 8 目录 | 分析、部署、机制、方案记录 |
| `AGENTS.md` | 66 行 | 项目设定（7 条硬约束 + 指针表） |

## 四、★ 前端副本现状（本轮最重要发现）

### 4.1 判据已失效

`AGENTS.md` 的设定是：

> `my-frontend/` 是 `frontend/` 的**逐字副本**。判据是 `diff -rq frontend my-frontend`
> 的**输出内容**必须恒等于"刻意改动量"。

**现状：`diff -rq frontend my-frontend` 输出 66 条**（同步前为 0）。

### 4.2 差异的构成（已严格验证）

把差异集与"官方本轮 frontend 改动集"求差集后逐一比对：

| 构成 | 数量 | 例 |
|---|---|---|
| 官方**新增**的文件（副本缺失） | 19 | `src/stores/modelProviders.ts`、`src/utils/kbPermission.ts`、`src/utils/reasoningEffort.ts`、`src/views/chat/rewindView.ts` |
| 官方**删除**的文件（副本多出） | 1（+1 测试） | `src/utils/thinkingControl.ts`（被 `reasoningEffort.ts` 取代） |
| 官方**修改**的文件（副本是旧版） | 46 | `src/components/Input-field.vue`、`src/api/*/index.ts`、`src/i18n/locales/*.ts` 等 |

**关键：差异 100% 来自官方演进，我们自己的改动为 0。**

### 4.3 为什么必须现在处置

1. **判别力丧失**：`diff -rq` 本是"我们改了什么"的唯一判据。一旦上游演进与我们的改动混在一起，
   这个判据就再也分不清二者 —— 而它是整个"复制独立演进"策略的基石。
2. **成本最低**：现在副本里**零改动**，同步就是"把 66 项官方改动搬过来"，机械且无冲突。
   越晚做，越要与我们的改动逐处比对。
3. **复制点会漂**：`my-docker/README.md` 的「副本复制点」记录的是 `5c5d46d9`，
   同步后需一并更新。

### 4.4 建议

**先同步副本到 `cc82e75c`，再开始改。** 同步后 `diff -rq` 归零，恢复判别力，
复制点更新为 `cc82e75c`。

## 五、文档行号引用失真情况

`my-docs/` 里共 **90 处**（去重后）`文件:行号` 引用，散在 5 个文档。失真分三类：

| 类型 | 严重度 | 实例 |
|---|---|---|
| **文件已不存在** | **高** | `internal/models/provider/provider.go`、`generic.go` —— 官方 `41dde3b0` **删除了整个 `internal/models/provider/` façade 目录**（现 `internal/models/` 下只剩 api/asr/catalog/chat/embedding/limiter/parity/rerank/utils/vendors/vlm） |
| 路径写法不全 | 低 | `vite.config.ts:19`（实际在 `frontend/`）、`knowledge.go:...`（实际在 `internal/handler/`） |
| 行号偏移 | 中 | `Makefile:256-259`→275、`.env.example:779`→785（已在 overlay 侧改为符号引用） |

> 结论：**文档里的 `文件:行号` 是长期维护债**。建议要么改用符号引用（靠段名/函数名定位），
> 要么给引用附上 commit 标注（如 `@cc82e75c`），使"过期"可被发现而非静默错误。

## 六、未决事项

1. **前端副本同步**（本轮新发现，最高优先级）—— 见 4.4。
2. `my-docker/README.md` 的「副本复制点」占位符仍为空（同步后应填同步到的 commit）。
3. **searxng 接入**：端口 `41291` 已定，五处改动方案已出，**尚未动手**。
   （官方新增警告 `68e21b6e` 要求 `SEARXNG_PORT ≠ APP_PORT`，本方案相容。）
4. `41200–41299` 的端口**分配规律**仍未明确（我推 41202 被否，规律待老魏说明）。

## 七、几点有利事实（不必担心）

- 官方本轮对 `docker-compose.yml` / `Makefile` / `.env.example` 的改动是**纯注释或新增 target**，
  对 overlay **零影响**。
- 官方 36 个提交与我们的定制面**零重叠**（550 vs 790 文件，交集为空）—— 物理分离策略有效。
- `go build ./...` → **exit=0**，合并后代码可编译。
