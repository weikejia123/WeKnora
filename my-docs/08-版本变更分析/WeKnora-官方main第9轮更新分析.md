# WeKnora 官方 main 更新分析（第 9 轮）

> 同步日期：2026-09-26 ｜ 范围：`8619bdf3`（第 8 轮）→ `4df7ccbb`
> 合并提交：`a089ec5b`（回滚点 `1acbe51a`）｜ **本轮只合并，未部署未推送**（老魏指示）

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **42**（本轮体量最大的一批） |
| 改动规模 | **165 文件 / +9,240 −1,167** |
| 是否发版 | **否**（`v0.8.2-66`；最新 tag 仍是 `v0.8.2`） |
| 依赖面 | **未动**（`go.mod` / `frontend/package.json` / docreader 依赖清单全无改动 ⇒ **无需 npm install**） |
| 新迁移 | **无**（0 条） |
| `go build ./...` | **exit=0**（28 秒） |
| 官方是否动 `docker/` | **否** ⇒ 我方 2 个例外 Dockerfile 安全 |

---

## 二、更新内容（使用视角）

### 2.1 ★★ 插件系统：11 个 PR 合入 main 后**又被整体撤回**（净状态无插件系统）

2026-09-26 当天官方合并了 **11 条插件系统提交**（P2 batch 3–8：插件基础、声明式安装、
代码插件 + Go SDK、Host API、远程运行时、沙箱页面、事件 webhook、动态表单/OAuth/资源限制、
Jira 示例、agent tools 由插件提供），随后 **`6c83d7ab` 把它们全部 revert 回去**——

> 官方原话："Reverts the eleven plugin system PRs merged on 2026-09-26
> **so they can be reviewed before landing**"（落地前先评审）

⇒ **合并后的净代码不含插件系统**。中间提交只在历史里，不影响我们。
等官方评审后重新落地时，届时再评估（那将又是一次大改）。

### 2.2 ★ MinerU / PaddleOCR-VL / 云端解析超时统一可配（`27b0c84b`）—— 与我们直接相关

- 新环境变量 **`WEKNORA_MINERU_TIMEOUT`**（默认仍 **1000 秒**不变）；
  `mineru_v1_client`、`mineru_cloud_converter`、`paddleocr_vl_converter` 三处原本各自硬编码
  的超时改为统一走 `requestTimeoutFromEnv()`（新增 `helpers.go`）。
- **用法**：大文档解析超 1000s 时，在 `.env` 加 `WEKNORA_MINERU_TIMEOUT=1800s` 即可，
  不用改代码。
- ★ 上下文：我们已在 111 接入 MinerU 4.0（官方原生 V1）⇒ 该项是**直接受益方**；
  110 的 VLM 档大文档（如几百页扫描件 + 窗口串行）可能逼近 1000s。

### 2.3 新功能

- `c7601b2d` **跨知识库 Wiki 搜索**：`POST /wiki-search`（#3535）
- `e7c27ccc` **Confluence 目录同步与私有图片资源**（#3319）
- `4364e61a` 语雀数据源：同步文档时**保留 TOC 层级**（#3476）

### 2.4 修复（挑与我们场景相关的）

| 提交 | 内容 |
|---|---|
| `1dd3fe86` | docreader：openpyxl **无法解析的数据验证范围改为丢弃**而不是整表失败（#3608） |
| `a7ac21ce` | docreader：styles.xml 非规范填充**先清洗再加载**（#3638）⇒ 新增 `xlsx_repair.py` |
| `8356742d` | **LLM 截断的流视为损坏**并收紧重试 |
| `ef6f28c1` | agent tool **panic 恢复**，不再拖垮整个服务 |
| `6eb3cce1` | 合并相邻 assistant 消息时**保留 tool_calls**，避免孤儿 tool 消息导致整轮 400（#3574） |
| `8a75bece` | MCP 连接关闭不阻塞退出 |
| `ef938f91` | LLM 调试记录保持在各自目录内 |
| `929dad57` | weaviate：接受另一个 worker 先建好的 class（#3689） |
| `5614c04d` / `605d70fc` / `5c717ca0` | 飞书分页终止 / notion 增量同步中止 / 飞书资源图片 |
| `745a22d0` | 前端：去掉 TTL 资源缓存与重复启动请求（#3562） |

---

## 三、二开影响评估

### 3.1 合并记录

| 项 | 值 |
|---|---|
| 回滚点 | `1acbe51a` |
| 合并提交 | `a089ec5b` |
| 冲突 | **0** |

### 3.2 冲突预判：双方法确认

```bash
# 方法一：三点比较（merge-base = 8619bdf3）
#   官方 165 文件 / 我方 887 文件 → 交集 0
# 方法二：merge-tree 预演
git merge-tree --write-tree --name-only wkj-dev main
#   → 1307156912fccef5f03e3d23e2109a500132f58c（单 tree OID = 干净）
```

### 3.3 二开完整性校验

`comm -23 /tmp/dev9.txt /tmp/after9.txt` → **空（零丢失）**；关键目录全部在位。

### 3.4 前端副本同步（判据成立）

老魏判断「定制前端无修改，直接覆盖」——**实测证实**：归因 `comm -13` **为空**（本轮连目录级假阳性都没有）。

```bash
rsync -a --exclude=/dist --exclude=/node_modules frontend/ my-frontend/
diff -rq frontend my-frontend | wc -l    # 43 → 2（仅 dist / node_modules 两项产物）
```

| 项 | 值 |
|---|---|
| 副本差异 | 43 条 = 35 differ + 6「仅官方有」+ 2 产物 |
| `dist/index.html` sha256 | 覆盖前后均 `73b90d99…` ⇒ 产物未受影响 |
| `frontend/package.json` | **未动** ⇒ 本轮**无需 npm install**（与第 8 轮不同） |
| 跟踪文件数 | `my-frontend` 839 → **845**（+6 官方新增文件，提交时纳入）= `frontend` 845 ✅ |
| 副本复制点 | `my-docker/README.md`：`8619bdf3` → **`4df7ccbb`** |

---

## 四、★ 2 个例外 Dockerfile 的必要性判断

**结论：仍然必要；本轮官方未动 `docker/`，我方改动不受影响。**
（`Dockerfile.app` +61 行中性换源 ARG、`.docreader` +9 行 `GH_PROXY`，与第 8 轮判断一致，不赘述。）

---

## 五、连带发现

### 5.1 ★★ 本轮行号漂移是历轮最多的一次 —— 12 处 + 1 处路由失效

三个行号敏感文件**同时**被官方改动：

| 文件 | 官方改动 | 漂移 |
|---|---|---|
| `internal/container/container.go` | +10 净 | 我方引用 **全部 +1**：`:889→890`、`:892→893`、`:900-905→901-906`、`:886-889→888-890` |
| `.env.example` | +5 | WSS 说明 `:785→804`；**`:74`（AUTO_MIGRATE）未漂移** |
| `docker-compose.yml` | +6/−2（净 +4） | searxng `profiles` `:608-610→612-614`、`searxng-init` `:565→569`、顶层 `volumes:` `:1038→1042` |

已订正 **12 处**当前引用（14-联网搜索 ×2、11-数据安全与备份 ×8、03-生产部署 ×1、
04-功能机制解析 ×1），复查无残留。**历史记录目录（08 / 09）按规约不动。**

★ 另一处结构性失效：`wiki_page.go` 本轮被官方 +118 行 ⇒
`my-docs/04-…全流程.html` 里 `routes_knowledge.go:326 /wiki/graph` 的**路由注册位置已失效**
（`routes_knowledge.go` 里已 grep 不到该路径，注册方式被重构）——已改为符号引用 +
「以 `internal/router/` 现查为准」。⇒ **印证 MEMORY 里的文档债判断：行号引用不可靠，符号引用才是正路。**

### 5.2 官方 README 重排后 `docs/images/` 大量变化

本轮 `docs/images/` 有新增（第 8 轮也有 48 张）——这些是 README/官网配图，不影响运行。

---

## 六、部署判断（**本轮未部署**，供下次执行时用）

| 判断项 | 结论 |
|---|---|
| 是否需要 `build` | **不需要**（依赖面未动、未改例外 Dockerfile） |
| 是否需要 `push-app` | **需要**（`internal/` 97 文件，含 docparser 超时重构、searchutil 新文件） |
| ★ 是否需要 `push-reader` | **需要** —— docreader 改了 5 个文件（excel_parser / markitdown_parser / **新增 `xlsx_repair.py`**） |
| 是否需要 `push-ui` | **需要**（`frontend/` 41 文件） |
| 是否需要 `up` | **不需要**（编排未变） |
| ★ 备份 | **非必须**（无新迁移）——但 app 仍会重启，按习惯备份成本极低（1 分钟），建议照做 |

**执行顺序**：备份（可选）→ `push-app` → `push-reader` → `push-ui`。

---

## 七、待办

1. **部署**（等老魏指令）：本轮改动已在本地提交，尚未推送 gitea / gitea110。
2. 部署后可考虑：`.env` 是否需要设 `WEKNORA_MINERU_TIMEOUT`（若 110 的大文档解析超 1000s 才需要）。
3. 插件系统等官方评审后重新落地时再评估。

---

## 八、证据（可复核）

```bash
# 规模与发版
git rev-list --count 8619bdf3..4df7ccbb          # 42
git diff --shortstat 8619bdf3..4df7ccbb          # 165 files changed, +9240 −1167
git describe --tags 4df7ccbb                     # v0.8.2-66-g4df7ccbb

# 插件系统被撤回
git log -1 --format=%B 6c83d7ab                  # "Reverts the eleven plugin system PRs…"

# 依赖面（应为空）
git diff --name-only 8619bdf3..4df7ccbb -- go.mod go.sum frontend/package.json

# 新迁移（应为空）
git diff --name-only 8619bdf3..4df7ccbb -- migrations/    # 0 条

# MinerU 超时配置
grep -n "WEKNORA_MINERU_TIMEOUT" internal/infrastructure/docparser/helpers.go

# 副本判据
diff -rq frontend my-frontend | wc -l            # 2（仅产物）
shasum -a 256 my-frontend/dist/index.html        # 73b90d99…（覆盖前后一致）

# 行号漂移订正后复查（应为空）
grep -rn ":889）\|:892\|:900-905\|:608-610\|起于 :565\|起于 :1038" my-docs/ my-docker/ \
  | grep -v "08-版本变更分析" | grep -v "09-二开现状基线"
```
