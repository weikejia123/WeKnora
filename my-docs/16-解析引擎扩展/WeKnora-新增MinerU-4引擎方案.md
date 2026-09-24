# WeKnora 新增 `mineru_v4` 解析引擎 —— 方案与改动面

> **状态**：方案待确认（尚未实施）
> **目标**：让 WeKnora 能调用 **MinerU 4.x** 的 V1 API，与现有 `mineru` 引擎（旧同步契约）**并存**
> **用户决策（2026-09-24）**：MinerU 单独测试解析质量好 ⇒ 确定使用 4.x；倾向**改 WeKnora 代码、新增一个 `MinerU-4` 引擎**
> **本文用途**：钉死改动面与代价，供决策；实施后作为该引擎的维护 SSOT

---

## 0. 一句话结论

技术上可行且方向正确（增量而非改写），但**代价必须提前接受**：
新增引擎会改动 **10+ 个官方文件**（前端含 5 个语言文件），
⇒ **打破「官方文件改动面 = 2 个」这条根基**，上游同步将不再零冲突。

---

## 1. 背景：为什么会断

| 项 | 事实 |
|---|---|
| MinerU 4.0 发布时间 | 2026-09-16（`22f5abb6`） |
| 破坏性变更 | **删除 `/file_parse` 与 `/tasks`，仅保留 V1**（官方 `docs/zh/reference/migration_4.md`） |
| 现有 `mineru` 引擎 | 按经典同步契约 `POST /file_parse`（`mineru_converter.go:236`），响应 `{"results":{stem:{md_content,images}}}` |
| 结果 | 4.x 上**必然 404**；且 `PingMinerU` 只探 `GET /docs`（默认开启）⇒ **界面永久绿灯** |

**V1 的真实形态（5 步异步，源码实测）**：

```
① POST /v1/uploads                    → upload_id
② POST /v1/uploads/{id}/complete      → 完成分片上传
③ POST /v1/parse/jobs                 → job_id（异步任务）
④ GET  /v1/parse/jobs/{id}            → 轮询状态
⑤ GET  /v1/files/{id}/content         → 取回结果
```

> 证据：110 源码 `/mnt/docker-data/docker-deploy/mineru`（`__version__ = "4.0.6"`），
> `mineru/parser/api_server.py:1575` `_router = APIRouter(prefix="/v1")`；
> 公开路径 `:2450`（`/v1/health`、`/v1/models`、`/v1/tiers`）。
> ⚠️ 本机 `projects/open/MinerU` 是 **3.2.3**（无 V1）——查契约必须去 110 那份。

⇒ **适配的本质是把「1 步同步」改写成「5 步异步」**（分片 + 轮询 + 结果聚合），不是转发。

---

## 2. 引擎机制（勘察结论）

| 机制 | 位置 | 说明 |
|---|---|---|
| 引擎接口 | `internal/infrastructure/docparser/engine_registry.go:16-26` | 接口名 **`EngineRegistration`**（不是 `ParserEngine`），5 方法：`Name` / `Description` / `FileTypes` / `CheckAvailable` / `NewReader` |
| 注册 | `engine_registry.go:44-51` | `var localEngines []EngineRegistration` + `RegisterEngine(e)`；**注册顺序即展示顺序** |
| 引擎名常量 | `engines.go:13-30` | 8 个常量集中定义 |
| 注册调用 | `engines.go:32-42` | `init()` 内 8 个 `RegisterEngine(&xxxEngine{})` |
| ★ 前端列表 | `GET /api/v1/system/parser-engines`（`router/routes_auth_tenant.go:256`） | **完全动态**：后端注册即出现卡片，前端无硬编码清单 |
| 配置持久化 | `tenants.parser_engine_config` **JSONB**（`types/tenant.go:108`） | ⇒ **不需要新的数据库迁移** |
| 配置链路 | `ParserEngineConfig`（`tenant.go:306-348`）→ `ToOverridesMap()`（`:392-479`）→ `MergeParserEngineOverrides`（`knowledge_process_config.go:319-328`）→ `ReaderDeps.Overrides` → 引擎构造函数 | 任一环漏改 ⇒ 配置**静默不生效** |

---

## 3. 改动清单

### 3.1 后端（A 类 = 缺一即失效）

| # | 文件:行 | 改什么 | 漏掉的后果 |
|---|---|---|---|
| 1 | `docparser/engines.go:13-30` | 加常量 `MinerUV4EngineName = "mineru_v4"` | 无法注册 |
| 2 | `docparser/engines.go:32-42` | `init()` 加 `RegisterEngine(&minerUV4Engine{})` | 引擎不出现在列表 |
| 3 | `docparser/engines.go` 末尾 | 新增 `mineruV4Engine`（照抄 `:196-216` 的 `mineruEngine`） | 同上 |
| 4 | **新建** `docparser/mineru_v4_converter.go` | 实现 5 步 V1 客户端（照抄 `mineru_converter.go:33-104` 骨架；`Read()` 内必须 `utils.ValidateURLForSSRF`） | 无实现 |
| 5 | `types/tenant.go:306-348` | `ParserEngineConfig` 加字段（endpoint / api_key / 档位） | UI 存不下配置 |
| 6 | ★ `types/tenant.go:392-479` | `ToOverridesMap()` 加 key 映射 | **配置传不到引擎** |
| 7 | ★ `application/service/parser_url_security.go:10-16` | `parserOutboundURLKeys` 加新 endpoint key | **被 SSRF 校验拦截** |
| 8 | `handler/tenant.go:1905-1930` | 保存前 SSRF 校验加分支 | 保存失败或漏校验 |
| 9 | ★ `types/config_redaction.go:25-40` | `ParserEngineConfigForResponse` 加密钥脱敏 | **GET 接口泄漏明文密钥** |
| 10 | ★ `types/config_redaction.go:160-177` | `MergeParserEngineConfigForUpdate` 加 `PreserveIfRedacted` | **前端回传 `***` 覆盖真实密钥** |

### 3.2 前端（两份都要：`frontend/` + `my-frontend/`）

| # | 文件:行 | 改什么 |
|---|---|---|
| 11 | `api/system/index.ts:115-143` | `ParserEngineConfig` 接口加新字段 |
| 12 | `views/settings/ParserEngineSettings.vue:227-281` 之后 | 新增配置 section（照抄 mineru 那段） |
| 13 | 同文件 `:403` `CONFIGURABLE_ENGINES` | 加 `'mineru_v4'`（决定"测试连接"按钮是否显示） |
| 14 | 同文件 `:416-440` `DEFAULT_PARSER_CONFIG` | 加字段默认值 |
| 15 | 同文件 `:477-487` `ENGINE_ORDER` | 加排序号 |
| 16 | 同文件 `:551-583` / `:592-619` | `loadConfig` 读回显 + `buildConfigPayload` 提交 |
| 17 | 同文件 `:789-804` / `:1113-1132` | per-engine 配色（不加则用默认蓝） |
| 18 | `i18n/locales/{en-US,zh-CN,ja-JP,ko-KR,ru-RU}.ts` | 各加 `kbSettings.parser.engines.mineru_v4.{name,desc}` |
| 19 | ★ `i18n/localeKeyAudit.test.ts:68-78` | `PARSER_ENGINE_NAMES` 加 `'mineru_v4'` | **不加则该测试直接红** |

### 3.3 测试与文档（B/C 类）

- 新建 `mineru_v4_converter_test.go`（httptest 断言 5 步协议）+ `_ssrf_test.go`
- 更新跨包契约测试：`system_parser_check_test.go`、`parser_url_security_test.go`、`tenant_test.go:47`
- `docs/` swagger 三件套**跑 `swag` 重新生成**（不手改）
- `my-docs/04-功能机制解析/WeKnora-解析引擎接入机制.md` 补引擎清单
- `.env.example` 若需默认端点

**无需改**：数据库迁移（JSONB）、`client/system.go`（泛型）、Python `docreader/`（本引擎走 Go）

---

## 4. ★ 代价：这条路的真实成本

| 维度 | 现状 | 新增引擎后 |
|---|---|---|
| **官方文件改动面** | **2 个**（`docker/Dockerfile.app` / `.docreader`，均为中性构建 ARG） | **10+ 个**（含 Go 核心文件与前端 i18n） |
| 上游同步 | 0 冲突（实测两轮） | **多处冲突可预期**（Go 文件行号密集、前端单文件组件） |
| 拒绝上游 merge 的成本 | 低 | 高（需逐处人工解冲突） |
| 前端副本判据 | `diff -rq` = 2 行（仅构建产物） | **判据失效** —— 会出现"刻意改动量"（`my-frontend` 内 6+ 文件） |

> **判断**：这不是"要不要做"的问题，而是**要不要接受"二开从此不再与上游零冲突"**。
> AGENTS.md 第 1 条「官方文件不得修改」的前提是"上游更新零冲突"，本方案会实质性改变该前提。

---

## 5. 建议的实施路径（分阶段，先验证方向）

### 阶段 1 —— 后端 MVP（不碰前端）

**目标**：用后端 API 直接配置，**验证 5 步 V1 契约真的能打通**（先证明方向，再投入前端）。

范围：改动清单 **#1–#10**（Go 侧）。验证方式：

```bash
# 绕过前端，直接写配置
curl -X PUT .../api/v1/tenants/kv/parser-engine-config \
  -d '{"mineru_v4_endpoint":"http://10.168.1.110:36743", ...}'
# 然后上传一份扫描件 PDF，看解析是否成功、产物是否含表格/公式
```

**收益**：若契约不通（例如 V1 还需要认证、或返回结构更复杂），损失仅为 Go 侧改动，前端白做。

### 阶段 2 —— 前端 UI

范围 **#11–#19**。此时契约已验证，前端只是"把已验证的字段暴露出来"。

### 阶段 3 —— 文档与收尾

更新 `AGENTS.md`（改动面口径要改！）、引擎清单文档、swagger。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| V1 需要认证/更复杂（如必须分片 multipart） | 阶段 1 先用 `curl` 打通 5 步再写代码 |
| `engines.go` 改动密集 ⇒ 上游冲突 | 尽量**新增文件**承载实现；官方文件只做"加 3~5 行"的最小插入 |
| 上游将来自己适配 4.x | 我们的 `mineru_v4` 与其**命名不同** ⇒ 可平滑切换到上游实现后删除自有引擎 |
| 前端两份同步 | 改 `frontend/` 后用 rsync 同步 `my-frontend/`，并把"刻意改动量"登记进 AGENTS.md |
| 显存/服务端 | 110 侧 MinerU 4.0.6 已在跑（`mineru-api` 36743），无需改动 |

---

## 7. 待确认（决策点）

1. **是否接受「改动面 2 → 10+、上游不再零冲突」**？（这是本方案唯一的实质代价）
2. 是否按「阶段 1 先验证契约、再投前端」推进？
3. 引擎命名用 `mineru_v4`（后端 ID）／`MinerU-4`（显示名）是否合适？

---

## 附：勘察证据索引

- 引擎接口：`internal/infrastructure/docparser/engine_registry.go:16-26`
- 现有 mineru 引擎：`engines.go:196-216`；converter：`mineru_converter.go:33-104`、`:362-383`（Ping）
- 前端引擎列表 API：`handler/system.go:400-421`；响应结构 `types/docparser.go:43-50`
- 配置往返：`handler/tenant.go:1294-1324`（get）、`:1347-1374`（update）
- i18n 审计：`frontend/src/i18n/localeKeyAudit.test.ts:68-78`、`:272-285`
