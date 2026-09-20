# BrowserSkill 配对与 WSS 约束（为什么报 `requires WSS`）

> 记录时间 2026-09-21。场景：在 `http://10.168.1.111:41200` 的「设置 → 浏览器连接」点配对，
> 报 `BrowserSkill public URL requires WSS`。

## 一、结论先说

**这是上游刻意的安全约束，不是配置写错。** 内网部署要能用，**必须补 TLS（wss）** ——
好消息是**不需要公网域名，企业 CA 或自签证书即可**；且**除 TLS 外的链路已经全部就绪**。

## 二、根因（代码级）

判定逻辑在 `internal/browserskill/manager.go:178-190`：

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
2. 后端在 `BROWSERSKILL_PUBLIC_URL` **为空**时用 origin 推导（`manager.go:196-215`）：
   `https` → `wss`，`http` → `ws`
3. 以 `http://10.168.1.111:41200` 访问 ⇒ 推导出 `ws://10.168.1.111:41200/api/v1/local-browser/extension`
4. hostname 是 `10.168.1.111`（**不是 localhost**）、scheme 是 `ws` ⇒ **被拒**

## 三、上游立场（原文）

| 位置 | 原文 |
|---|---|
| `.env.example:779` | 「可选覆盖：仅在网关使用独立域名/路径等特殊部署时设置；**远程部署必须使用 WSS（包括内网）**。」 |
| `docs/browser-skill-production.md:88` | 「**WSS 可以使用企业 CA，无需公网**；**远程明文 WS 不受支持**。」 |

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

> **已采用方案 A 并部署完成（2026-09-21）**。实现落在 `my-docker/tls/`
> （**独立编排**，不改 WeKnora 任何文件），运维细节见 `my-docker/tls/README.md`。

**部署与验证结果（全部实测）**

| 项 | 结果 |
|---|---|
| TLS 终端 | 容器 `weknora-tls`（`nginx:1.30.3-alpine`，`network_mode: host`），监听 **443** |
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

配对链接形态（`docs/browser-skill-production.md:11-23`）：
**WSS 地址 + fragment 携带配对令牌** → 扩展先走 HTTPS `/authorize` 激活 → 之后长连 WSS，
设备令牌放在 `Sec-WebSocket-Protocol` 子协议里。令牌只以 **sha256 哈希**落库
（`internal/browserskill/authorization.go:46`）。

## 七、一个容易误判的日志

```
docker logs WeKnora-app | grep browserskill
  /app/internal/browserskill/store.go:144 record not found     ← 每 5 秒一次
```

这是**前端在轮询配对状态、且当前无设备记录**，属正常现象，**不是错误**。
