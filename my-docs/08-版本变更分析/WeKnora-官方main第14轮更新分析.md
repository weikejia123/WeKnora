# WeKnora 官方 main 第 14 轮更新分析（2026-11-09）

> 同步区间：`02e30e9f`（第 13 轮合并点）→ `e3fb2335`，共 **2 个提交**、**96 文件**（+7088 / -284）。
> 官方版本号仍为 **v0.9.0**（`VERSION` 未变；main 现位于 v0.9.0 之后 129 个提交）。
> 本轮为**小步同步**：一个功能（凭据保险库 + 安全表单）+ 一次依赖升级（BrowserSkill 0.4.1）。

## 1. 概览

| 项 | 值 |
|---|---|
| 提交数 | 2（feat 1 / fix 1） |
| 发版 | 无（`VERSION` 仍 0.9.0，未打新 tag） |
| 官方改动面 | 96 文件 |
| 我方相对官方差异面（合并后） | 1173 文件 |
| 交集 | 仅 2 个例外 Dockerfile（`Dockerfile.app` 的 `BROWSERSKILL_EXTENSION_PATH` 版本号），**零冲突**自动合并 |
| `go build ./...` | **exit=0**（仅既有 sqlite3.h deprecation / `-lc++` 重复库警告） |
| 前端构建 | `my-frontend` `npm run build` **exit=0**（24.4s） |
| 合并提交 | `de55be398`；回滚点 = 合并前 `46afb1e31` |

## 2. 更新内容

### 2.1 `feat(credential): encrypted vault and secure form for sandbox logins`（#5047）

官方新增**沙箱登录凭据链路**，核心目标是"**密码不进模型上下文、不进日志、不进 prompt 行**"：

- **数据层**：新增表 `credential_vault_items`（迁移 **000136**；sqlite 侧 **000052**）。密码只存
  `secret_ciphertext`（AES-256-GCM，用 `SYSTEM_AES_KEY` 派生），唯一键
  `(tenant_id, user_id, site, username) WHERE deleted_at IS NULL`。
- **API**：`/me/credential-vault` 的 GET/POST/PATCH/DELETE（`RegisterMyCredentialVaultRoutes`，
  与 `/me/env-vars` 同款**无角色门禁**——只碰调用者自己的数据，且**任何端点都不回传密码**）。
  另有 `POST /agent/secure-forms/:prompt_id` 专门接收安全表单提交（**不复用** `/prompts`，
  避免值落进 prompt 行）。
- **Agent 工具**：新增 `request_secure_form`（弹卡片、等用户填）与 `browser_fill_secret`
  （拿 handle 填值，**模型只见 handle 不见值**），两者已进入 `SwitchManagedTools()` 受管工具集。
- **沙箱侧**：`internal/sandbox/secret_fill.go` 新增 `SessionSecureBrowser` 能力接口，
  通过容器内 `/usr/local/bin/wk-secret-fill` 助手填充；一次性密钥走 file API、argv 只带密文
  ⇒ **envd 日志看不到密码**。只在**已批准的 HTTPS 页面**上填（`host_mismatch` /
  `insecure_origin` / `page_changed` 等逐字段结果码）。
- **前端**：新增 `CredentialVaultSettings.vue`（设置页「凭据保险库」，能力位
  `settings.sandbox.remote`）、`SecureFormCard.vue`（对话坞卡片）、`api/credentialVault.ts`、
  `utils/secureForm.ts`；改 `Settings.vue` / `PendingPromptDock.vue` / `AgentStreamDisplay.vue` /
  `useChatStreamHandler.ts` / `usePromptDock.ts` + 6 语言 i18n。
- **日志脱敏**：`middleware/logger.go` 抽出 `skipsBodyLogging()`，把
  `/agent/secure-forms/` 与 `/me/credential-vault*` 一并纳入**不读 body**名单。

### 2.2 `fix(browser): upgrade BrowserSkill to v0.4.1`（#5031）

- `scripts/browserskill-release.json`：`0.3.1` → **`0.4.1`**，pinned commit
  `da6bf4ee` → **`b8f2d4f0fa35c8c7c866229e1cf3b3329ae39de5`**（扩展与 bsk daemon 同源）。
- `docker/Dockerfile.app`：`BROWSERSKILL_EXTENSION_PATH` 指向 `browser-skill-weknora-0.4.1.zip`。
- 前端 `BrowserConnectionSettings.vue`：`MIN_EXTENSION_VERSION = '0.4.1'` ⇒ **低于 0.4.1 的扩展
  会被提示升级**。
- `internal/browserskill/manager.go`：人机共享控制模型改写 —— 删掉 `preserveAgentWindow` /
  `releasePlaceholder` 那套"占位标签保窗"逻辑，改为 `checkLastTabClose`（关闭前先同步、不创建
  占位标签，否则会吊销调用方的**共享控制凭据**）；`observe()` 新增受理
  `session.ended`（仅 `reason=user_moved_tab` 且带 `tab_id`），把受控标签被拖出任务窗口视为
  会话结束。
- `docker/Dockerfile.sandbox`：新增 `wk-secret-fill.mjs` / `wk-secret-fill` 的 COPY + chmod，
  并在 Chrome 托管策略注释里补上"关闭密码管理器与自动填充"的理由。

## 3. 二开影响评估

- **合并**：`git merge upstream/main` **零冲突**。唯一需要人工判断的是 `docker/Dockerfile.app`
  （唯一例外文件之一）—— 官方只改了一行 `BROWSERSKILL_EXTENSION_PATH` 的版本号，与我方
  `RUSTUP_*` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` 换源 ARG 无交集，
  合并后逐条 grep 确认**全部在位**。
- **迁移 000136**：建表 + 索引，**不动存量数据**（无 UPDATE/DELETE）。⚠️ 但 `AUTO_MIGRATE`
  默认开启 ⇒ **下次重建 app 容器即自动执行**，按第 8 条先备份。
- **`SYSTEM_AES_KEY` 变得更要紧**：本轮新增的凭据保险库用它加密存库密码。该 key 在 `.env`
  里（版本控制外）。丢失 ⇒ 凭据**静默失效**（不报错、解不出来）。与 AGENTS.md 第 8 条同源风险。
- **镜像基座**：`Dockerfile.sandbox` 变了（新 COPY 两个脚本）。我方 `sandbox` 走 `full` profile
  且 `.env` 里 `WEKNORA_SANDBOX_DOCKER_ENABLED=false` ⇒ **本轮不受影响**；将来若要开 Docker 沙箱
  或**远程沙箱**，必须重建 sandbox 镜像，否则 `browser_fill_secret` 会返回
  `ErrSecretFillHelperMissing`（该错误文案已明确要求"rebuild or upgrade the desktop image"）。
- **BrowserSkill 扩展必须重装**：服务端 pin 升到 0.4.1 后，**0.3.1 扩展会协议不匹配**。
  已加载 0.3.1 的浏览器需按 `my-scripts/pack_browserskill_ext.sh` 重新取包并重载
  （脚本自动从 `scripts/browserskill-release.json` 读 pinned 版本，无需改脚本）。
- **无新 compose 变量**：官方 `docker-compose.yml` 本轮零改动；overlay 与 `.env` **无需改动**。
  `.env.example` 只有 `BROWSERSKILL_EXTENSION_PATH` 注释的版本号变化。
- **前端**：官方动 `frontend/` **22 文件**（含 7 个新增）。`my-frontend` 为逐字副本 ⇒ 已
  `rsync` 同步后 `diff -rq` 仅剩 `dist` / `node_modules` 两项产物差异（= 0 实质差异）。

## 4. 例外 Dockerfile 的必要性判断（合并后重判）

| 文件 | 官方本轮动作 | 我方剩余领先改动 | 结论 |
|---|---|---|---|
| `Dockerfile.app` | `BROWSERSKILL_EXTENSION_PATH` 版本号 0.3.1→0.4.1 | `RUSTUP_DIST_SERVER_ARG` / `RUSTUP_UPDATE_ROOT_ARG` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG`（browserskill 与 builder 两个阶段） | **仍必要**（官方未触及换源 ARG） |
| `Dockerfile.docreader` | 本轮未改 | `GH_PROXY`（protoc / grpc_health_probe）、`APT_MIRROR` 默认值 | **仍必要**（原样保留） |

## 5. 本轮做过的校验（可复现）

```bash
git log --oneline 02e30e9f..upstream/main            # 2 条
git diff --shortstat 02e30e9f..e3fb2335b             # 96 files, +7088/-284
go build ./...                                        # exit=0
( cd my-frontend && npm run build )                   # exit=0
diff -rq frontend my-frontend                         # 仅 dist / node_modules
docker compose --project-directory . --env-file .env \
  -f docker-compose.yml -f my-docker/docker-compose.overlay.yml config --quiet   # exit=0
grep -c 'RUSTUP_DIST_SERVER_ARG\|GH_PROXY\|NPM_REGISTRY_ARG\|CARGO_REGISTRY_ARG' docker/Dockerfile.app
git diff --name-status upstream/main..HEAD | wc -l    # 1173（我方差异面）
```

## 6. 部署注意事项（下次动 111 时）

1. **备份**：`postgres-data` + `data-files` + `.env`（`.env` 现同时关系 `SYSTEM_AES_KEY` 的凭据解密）。
2. 迁移 **000136** 会随 app 启动自动执行；纯建表，无数据改写。
3. **重建 app 镜像**：`Dockerfile.app` 里 pinned 扩展是 0.4.1，且 `bsk` daemon 需按新 commit
   重编（走 `scripts/build_browserskill.sh`，我方 `GH_PROXY`/`CARGO_REGISTRY_ARG` 生效）。
4. **重装浏览器扩展**：跑 `./my-scripts/pack_browserskill_ext.sh`（新版镜像起来后才有 0.4.1 的 ZIP），
   然后 `chrome://extensions` 重新加载。**不做这步，本机浏览器功能会协议不匹配**。
5. 前端需重新构建（`./deploy/deploy-wkj-dev.sh push-ui`）；凭据保险库设置项只在
   `settings.sandbox.remote` 能力为真时可见 ⇒ 111 当前为**远程沙箱**才有入口，
   纯 Docker 沙箱关闭时该菜单隐藏（属预期）。
6. ⚠️ 老坑复现提醒：**容器组里任何成员重建后，未重建的 nginx 都要重启一遍**（DNS 缓存旧 IP）。

## 7. 本轮顺带处理

- 合并前工作树有一批**已暂存但未提交**的 `my-docs` 目录重整（`91-深度使用说明` → `83-实际使用`），
  阻塞了 merge（`merge` 报 "local changes would be overwritten"，因 rename 的删除侧未落盘）。
  已先行提交为 `46afb1e31`，再执行合并 —— 该提交即本轮**回滚点**。
