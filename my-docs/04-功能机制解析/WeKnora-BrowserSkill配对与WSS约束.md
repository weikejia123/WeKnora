# BrowserSkill 配对与 WSS 约束（为什么报 `requires WSS`）

> 记录时间 2026-09-21。场景：在 `http://10.168.1.111:41200` 的「设置 → 浏览器连接」点配对，
> 报 `BrowserSkill public URL requires WSS`。

## 一、结论先说

**这是上游刻意的安全约束，不是配置写错。** 内网部署要能用，**必须补 TLS（wss）** ——
好消息是**不需要公网域名，企业 CA 或自签证书即可**；且**除 TLS 外的链路已经全部就绪**。

## 二、根因（代码级）

判定逻辑在 `internal/browserskill/manager.go` 的 `pairingEndpoint()`：

```go
func pairingEndpoint(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", errors.New("invalid BrowserSkill public URL")
	}
	local := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
	if u.Scheme != "wss" && (!local || u.Scheme != "ws") {
		return "", errors.New("BrowserSkill public URL requires WSS")
	}
	...
}
```

规则一句话：**非 localhost 必须 `wss`；`ws` 只对 `localhost` / `127.0.0.1` / `::1` 开放。**

为什么会命中这条：

1. 前端 `frontend/src/views/settings/BrowserConnectionSettings.vue:171` 发起配对时，
   把**页面 origin** 原样交给后端：
   `POST /api/v1/sessions/:id/local-browser` → `{ action: 'pair', origin: window.location.origin }`
2. 后端在 `BROWSERSKILL_PUBLIC_URL` **为空**时用 origin 推导（`manager.go` 的 `pairingURL()`）：
   `https` → `wss`，`http` → `ws`
3. 以 `http://10.168.1.111:41200` 访问 ⇒ 推导出 `ws://10.168.1.111:41200/api/v1/local-browser/extension`
4. hostname 是 `10.168.1.111`（**不是 localhost**）、scheme 是 `ws` ⇒ **被拒**

## 三、上游立场（原文）

| 位置 | 原文 |
|---|---|
| `.env.example:785` | 「可选覆盖：仅在网关使用独立域名/路径等特殊部署时设置；**远程部署必须使用 WSS（包括内网）**。」 |
| `website-docs/05-clients/09-local-browser.md` | 「**WSS 可以使用企业 CA，无需公网**；**远程明文 WS 不受支持**。」 |

⇒ 上游明确把"内网明文 ws"排除在外，并指出内网可行路径是**企业 CA / 自签证书**。

## 四、链路现状（2026-09-21 实测）

| 环节 | 状态 | 依据 |
|---|---|---|
| 扩展 ws 端点的 nginx **升级转发** | ✅ 已配好 | `frontend/nginx.conf:135-153`：`proxy_set_header Upgrade`、`Connection "upgrade"`、`proxy_read_timeout 3600s`、`proxy_buffering off` |
| 集群内部接口对外**挡掉** | ✅ `return 404` | `frontend/nginx.conf:154` |
| 后端端点是否响应 | ✅ 返回 **403**（缺设备令牌的正常拒绝） | `curl -H 'Upgrade: websocket' ... http://localhost:41200/api/v1/local-browser/extension` → `HTTP/1.1 403` `Server: nginx/1.30.3` |
| **TLS（wss）** | ❌ **缺这一环** | 因此配对链接生成被 `pairingEndpoint` 拒 |

⇒ **只差 TLS 终端**，其余链路不需要改动。

## 五、方案（**已采用 A**，2026-09-21 部署完成）

| | 做法 | 代价 / 前提 | 适用 |
|---|---|---|---|
| **A（推荐）** | 给 41200 加 TLS 终端（Caddy 最省事；或 nginx + openssl；或企业 CA），反代到 `127.0.0.1:41200` | ★ **证书必须被浏览器信任** —— Chrome 对 wss 的证书错误**不会给"继续访问"的机会**（页面能点"高级→继续"，但 WebSocket 握手直接失败）。自签证书的 SAN **要含 IP**（`IP:10.168.1.111`），并导入 Mac 钥匙串 | 长期在 111 上用 |
| **B** | 改 fork 放宽校验：让 `pairingEndpoint` 接受非 localhost 的 `ws` | 逆上游设计（明文传输设备令牌）；上游同步会留冲突；还需另行验证 Chrome 扩展是否接受 `ws://`。**不推荐** | 内网证书实在无法落地时 |
| **C** | 本机另跑一套 WeKnora，用 `http://localhost:41200` 访问（命中 localhost 例外） | 零证书问题；与 111 生产分离、占本机资源 | 只想先试用/体验 |

> 方案 A 落地后，页面 origin 变为 `https://…`，推导即得 `wss://…`；
> 若网关用了独立域名/路径，则显式设 `BROWSERSKILL_PUBLIC_URL=wss://<域名>/api/v1/local-browser/extension`。

> **已采用方案 A 并部署完成（2026-09-21；同日改版为容器组内的 nginx 服务）**。实现落在容器组内的 `nginx` 服务（定义在 `my-docker/docker-compose.overlay.yml`，配置资产在 `my-docker/nginx/`）
> （**不改 WeKnora 任何文件**），运维细节见 `my-docker/nginx/README.md`。

**部署与验证结果（全部实测）**

| 项 | 结果 |
|---|---|
| 接入层 | 容器 `weknora-nginx`（`nginx:1.30.3-alpine`）：对外 `443`/`41200` → 官方前端、`41280` → 定制前端 |
| 证书 | 自签 CA + 服务器证书，落 `/mnt/data/weknora-tls/`（**不进 git**，私钥 600） |
| SAN | `IP:10.168.1.111`、`IP:127.0.0.1`、`DNS:localhost`（有效期 10 年） |
| 证书链 | `openssl s_client -CAfile ca.crt` → **Verify return code: 0 (ok)** |
| 页面 / API | `https://10.168.1.111/` → **200**；`/api/v1/system/info` → **401**（与 http 时一致） |
| WebSocket 透传 | 带 `Upgrade` 头 → **403**（缺设备令牌的正常拒绝），`Server: nginx/1.30.3` |
| 协议推导（**代码级实证**，`go test` 实测） | `https://10.168.1.111` → `wss://10.168.1.111/api/v1/local-browser/extension` ✅<br>`http://10.168.1.111:41200` → 报 `requires WSS`（复现了原报错）✅<br>`http://localhost:41200` → `ws://…`（localhost 例外生效）✅ |
| 原有 41200 | **保留不变**（双通道，随时可退回纯 http 排查） |

> ⚠️ **访问端（Mac）仍需一步**：把 CA 导入钥匙串并设为「始终信任」——
> 否则页面能打开、**wss 握手仍会失败**（Chrome 对 WebSocket 的证书错误**不给**"继续访问"的机会）。
>
> ```bash
> # CA 已放在 ~/Downloads/weknora-ca.crt
> sudo security add-trusted-cert -d -r trustRoot \
>   -k /Library/Keychains/System.keychain ~/Downloads/weknora-ca.crt
> ```
> 导入后**重启一次 Chrome**。CA 的 sha256 指纹应与 `gen-certs.sh` 输出一致。

## 六、相关配置项

| 变量 | 作用 |
|---|---|
| `BROWSERSKILL_BINARY` | bsk 可执行文件路径。Docker 镜像已预设 `/opt/weknora/browserskill/bsk`；**显式设为空即可关闭此功能** |
| `BROWSERSKILL_PUBLIC_URL` | **可选覆盖**。仅在网关使用独立域名/路径时设置；远程必须是 `wss://…`，且不能含凭据/query/fragment |
| `BROWSERSKILL_EXTENSION_PATH` | 供"个人设置"下载的扩展 ZIP 本地路径（Docker 已预设） |
| `BROWSERSKILL_MAX_CONNECTIONS` | 单实例共享 daemon 最多保留的配对记录数（默认 32） |
| `BROWSERSKILL_INTERNAL_URL` / `BROWSERSKILL_CLUSTER_SECRET` | 仅多副本场景：节点直连地址 / 共享密钥 |

配对链接形态（`website-docs/05-clients/09-local-browser.md`）：
**WSS 地址 + fragment 携带配对令牌** → 扩展先走 HTTPS `/authorize` 激活 → 之后长连 WSS，
设备令牌放在 `Sec-WebSocket-Protocol` 子协议里。令牌只以 **sha256 哈希**落库
（`internal/browserskill/authorization.go:46`）。

## 七、一个容易误判的日志

```
docker logs WeKnora-app | grep browserskill
  /app/internal/browserskill/store.go:144 record not found     ← 每 5 秒一次
```

这是**前端在轮询配对状态、且当前无设备记录**，属正常现象，**不是错误**。

---

## 八、2026-09-22 实战：配对成功 —— 根因是 CA 从未导入访问端钥匙串

**现象**：以 `https://10.168.1.111:41280/platform/settings?section=browserconnection` 点配对，
扩展报「**配对未完成，请检查服务器连接，或获取新的配对链接重试**」；
但扩展设置页里已经能正确显示目标地址
`将连接到：wss://10.168.1.111:41280/api/v1/local-browser/extension`。

### 排查链：每一步排掉一个嫌疑

| 观察 | 排掉的嫌疑 |
|---|---|
| 扩展能显示正确的 `wss://…:41280/…` 目标地址 | 后端 `pairingEndpoint` 的 WSS 校验**已通过**（页面 origin 确实是 https）⇒ 不是"requires WSS"那一类 |
| 配对链接能生成出来 | 后端 `Enabled()` 为真 ⇒ **111 镜像里 bsk 资产是在的**（否则会直接报 `local browser is unavailable`，第五节的方案 A/C 都不必考虑） |
| 带 `Upgrade` 头请求 41280 → **403** + `Server: nginx/1.30.3` | `Upgrade` 头穿过**两层** nginx 到了后端 ⇒ 转发链没问题（第三节的表已覆盖这一点） |
| `security verify-cert` → `CSSMERR_TP_NOT_TRUSTED`，且系统/用户钥匙串里**都没有** `WeKnora Local CA` | **← 根因坐实** |

**关键概念**：配对链接的**生成**与 WSS 的**握手**是两道独立关卡 ——
前者只是 `pairingEndpoint` 的字符串校验，**过了它不等于握手能成**。
页面的 https 可以点「高级 → 继续前往」绕过证书告警，**扩展发起的握手没有这个交互机会**
（第五节开头那段警告说的就是这件事）。

### 修复（无需 sudo，用户钥匙串即可）

```bash
# CA 早已取回在 ~/Downloads/weknora-ca.crt（文件一直在，只是从没导入）
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db ~/Downloads/weknora-ca.crt
# 实测返回 0，未提示密码；随后 Chrome 配对即成功
```

> 验证与判据方法（**含"不要用 curl 判断"这个坑**）见
> [`my-docker/nginx/README.md` 第五节](../../my-docker/nginx/README.md) —— 单一事实来源，此处不重复。

### 两个容易误判的界面细节

- 扩展设置页顶部会显示**当前激活的连接**。配对前它显示的是
  `本机 · ws://127.0.0.1:52800` +「无法连接，请确认 daemon 已启动且端口一致」
  —— 那是**本机 daemon 模式**的常态，与"服务器配对失败"是两件事，别被它带偏。
- 粘贴配对链接后那一行「将连接到：…」**只是回显解析结果**，不代表连接已建立。

---

## 九、"浏览器搜索指令"该怎么配

### 它是什么

**不是给搜索引擎设参数，而是注入到 `local_browser` 工具描述里的一段文本**，
用来告诉模型"需要搜索时用哪个引擎、用什么 URL 模板"
（`internal/agent/tools/browserskill_prompt.go:9-19`）：

```go
return browserToolDescription +
    "\n\nSearch preferences (current user request overrides; browser control rules still apply):\n" +
    "<browser_search_preferences>\n" +
    html.EscapeString(prefs.EffectiveBrowserSearchInstructions()) +
    "\n</browser_search_preferences>"
```

它在**工具描述**里，不在系统提示词正文里，也不在用户可编辑的 Agent 模板里
（`website-docs/06-development/05-agent-prompts.md`）。

### 默认值

`internal/types/browser_search.go:10-11`：

```
Default search engine: Bing.
Search URL: https://www.bing.com/search?q={query}
```

### 读写路径

| 动作 | 走向 |
|---|---|
| 读取 | `GET /auth/me` 的 `preference_defaults.browser_search_instructions`（`internal/handler/auth.go:668`） |
| 保存 | `PUT /auth/me/preferences` → 存 `browser_search_instructions` 到**当前用户的 JSON 偏好**（`auth.go:685`，`max=4000`） |
| 恢复继承 | **留空**、或存回默认文本 —— 无需数据库迁移 |
| 生效时机 | **下一次请求**（浏览器已启用的请求才读取；保存不影响在跑的请求） |
| 不适用 | **浏览器关闭时不读取、不注入这一段**；**共享 Agent 不使用创建者的个人偏好** |

### 建议：把 `www.bing.com` 换成 `cn.bing.com`

```
Default search engine: Bing (China).
Search URL: https://cn.bing.com/search?q={query}
```

实测依据（2026-09-22，访问端 Mac，`scutil --proxy` 显示**无系统代理**）：

| URL | 实测结果 |
|---|---|
| `https://www.bing.com/search?q=test` | **302 → `https://cn.bing.com/search?q=test` → 200**（1 跳，0.56s） |
| `https://cn.bing.com/search?q=test` | **200 直达**（0 跳，0.49s） |
| `https://www.so.com/s?q=test` | 200（0.59s，可作备用引擎） |

**为什么值得改**（不只是快 0.07s）：

1. **少一次文档加载**。`navigate` 默认等 `domcontentloaded`；302 会多产生一次加载过程，
   而本项目**专门为"导航响应"打过下游补丁**（`scripts/build_browserskill.sh`：
   “published CLI binaries do not include this downstream patch”）⇒ 这正是一个已知痛点。
2. **避免与工具描述自相矛盾**。同一份 `browserToolDescription` 里写着
   `do not guess paths or repeatedly verify known redirects`（`browserskill_prompt.go:28-30`）
   —— 让 agent 第一次 `navigate` 就直达结果页，比让它对着一次重定向做额外确认更干净。
3. **口径统一**：`my-docs/14-联网搜索/` 已定下"bing 用 `cn.bing.com`"的选型，两边一致。

### ★ 一个必须分清的边界

**浏览器搜索走的是访问端本机的 Chrome**（扩展装在谁的浏览器里，浏览器就在谁那儿），
所以它与 111 上那套 **searxng（服务端通道，容器网络 `http://searxng:8080`）是两条独立通道**，
配置互不影响、也互不替代：

| | 浏览器搜索指令 | 联网搜索（searxng） |
|---|---|---|
| 执行位置 | **访问端本机 Chrome** | 111 的 `searxng` 容器 |
| 依赖什么网络 | **访问端**能否到达该搜索引擎 | **111** 能否到达上游搜索源 |
| 配置处 | 个人设置 → 浏览器连接 | 平台设置 → 网络搜索（Provider） |
| 生效前提 | 浏览器已启用且配对成功 | Provider 已配且 `is_default` |

> 所以：**即使 searxng 全通，浏览器搜索也可能因为访问端网络而失败，反之亦然。**

### 写法约束

- 上限 **4000 字符**（`auth.go:685`）；保持"两行英文"的原生形状最稳。
- 经 `html.EscapeString` ⇒ **写 HTML 没有意义，会被转义成纯文本**（也是防注入设计）。
- `{query}` 是占位符，模型会以 **URL 编码后**的关键词替换它。
