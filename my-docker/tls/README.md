# `my-docker/tls/` —— WeKnora 的 TLS 终端（111 站点专属）

## 一、它解决什么问题

BrowserSkill 配对时，后端要求**非 localhost 必须 `wss`**
（`internal/browserskill/manager.go:178-190`）。以 `http://<内网IP>:41200` 访问时，
前端把页面 origin 交给后端推导（`http`→`ws`），因 hostname 不是 localhost 而被拒，
页面报 **`BrowserSkill public URL requires WSS`**。

上游立场（原文）：
- `.env.example:779`：「远程部署必须使用 WSS（**包括内网**）」
- `docs/browser-skill-production.md:88`：「WSS 可以使用**企业 CA，无需公网**；远程明文 WS 不受支持」

本目录提供一个 **TLS 终端**，让页面以 `https://` 打开、配对链接自然推导为 `wss://`。

```
浏览器 --https/wss--> weknora-tls :443 --http/ws--> 127.0.0.1:41200 (frontend nginx) --> app:8080
```

## 二、为什么独立成一份编排

`my-docker/docker-compose.yml` 的定位是「官方 compose 的**副本 + 最小定制**」，
要求能与官方**逐行比对**（有 `compose-diff` 子命令依赖这个性质）。
在这里加 service 会破坏它，因此 TLS 终端单独一份 compose 文件管理。

另外两点设计取舍：

| 决定 | 理由 |
|---|---|
| `network_mode: host`，反代 `127.0.0.1:41200` | 不依赖 compose 网络名（`weknora_WeKnora-network` 会随编排变化）；与 WeKnora 编排彻底解耦 |
| 监听 `443`，**保留 41200 不变** | 443 让 URL 不带端口；41200 原样保留 ⇒ 随时可退回纯 http 排查 |
| **不开 HSTS** | 自签证书下若证书被取消信任，HSTS 会把浏览器锁死在 https，连退回排查都做不到 |

## 三、部署（在 111 的仓库根 `/mnt/data/weknora`）

```bash
# 1. 生成自签 CA + 服务器证书（幂等；重建用 FORCE=1）
bash my-docker/tls/gen-certs.sh
#    → 落在 /mnt/data/weknora-tls/（证书不进 git）
#    → SAN 含 IP:10.168.1.111 / IP:127.0.0.1 / DNS:localhost

# 2. 起 TLS 终端
docker compose -f my-docker/tls/docker-compose.yml up -d

# 3. 看状态与日志
docker compose -f my-docker/tls/docker-compose.yml ps
docker compose -f my-docker/tls/docker-compose.yml logs --tail=20
```

## 四、访问端（Mac）必须信任这张 CA —— 这步不能省

> ⚠️ **为什么不能像普通自签站点那样"点继续访问"**：
> https 页面可以点「高级 → 继续前往」，但 **WebSocket 握手不会给这个交互机会**
> —— 证书不受信时 `wss` 直接失败，表现为"页面能开、配对仍然失败"。

**方式一（命令行，推荐）**

```bash
# 从 111 取回 CA
scp nanning-111:/mnt/data/weknora-tls/ca.crt ~/Downloads/weknora-ca.crt

# 导入系统钥匙串并设为始终信任（需要输入密码）
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/weknora-ca.crt

# 核对指纹与服务器输出一致
openssl x509 -in ~/Downloads/weknora-ca.crt -noout -fingerprint -sha256
```

**方式二（GUI）**：双击 `ca.crt` → 导入「系统」钥匙串 → 找到 `WeKnora Local CA`
→ 右键「显示简介」→ 展开「信任」→ **使用此证书时：始终信任**。

> macOS 上证书信任是**按用户/系统钥匙串**生效的，Chrome / Safari 都读系统信任库。
> 若 Chrome 仍报错，重启一次 Chrome。

## 五、验证

```bash
# ① 用 CA 验证证书链（不跳过校验）——应输出 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert /mnt/data/weknora-tls/ca.crt \
  https://10.168.1.111/

# ② 域名/IP 匹配是否正确（--resolve 不适用 IP，改用 SAN 校验）
openssl s_client -connect 10.168.1.111:443 -CAfile /mnt/data/weknora-tls/ca.crt \
  -verify_return_error </dev/null 2>&1 | grep -E "Verify return code|subject="

# ③ WebSocket 升级是否能穿过 TLS 层 —— 应返回 403（缺设备令牌的正常拒绝），
#    若返回 400/426 说明 Upgrade 头在中途被丢了
curl -s -i -N --max-time 6 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://10.168.1.111/api/v1/local-browser/extension | head -3
```

## 六、业务侧验证（在 Mac 上）

1. 浏览器打开 **`https://10.168.1.111/`**（注意：不再带 `:41200`）
2. 地址栏应显示锁标（证书受信任）
3. 「设置 → 浏览器连接」→ 下载扩展 → 点配对
4. 此时后端收到的 origin 是 `https://…`，推导出 `wss://…` ⇒ **不再报 requires WSS**
5. 把配对链接粘进 Chrome 扩展完成配对

## 七、回滚 / 停用

```bash
# 停掉 TLS 终端（WeKnora 本体不受影响，41200 仍可直连）
docker compose -f my-docker/tls/docker-compose.yml down

# 彻底清理（含证书）
rm -rf /mnt/data/weknora-tls
```

## 八、排查清单

| 现象 | 原因 |
|---|---|
| 页面能开，但配对仍失败 | 证书未受信任（见第四节）；或 Chrome 未重启 |
| `NET::ERR_CERT_COMMON_NAME_INVALID` | SAN 里没有你访问用的那个 IP/域名 ⇒ `FORCE=1 bash gen-certs.sh` 重建 |
| ws 请求返回 400 / 426 | `Upgrade` 头在某层被丢：检查本目录 `nginx.conf` 的两行 `proxy_set_header`，以及内层 `frontend/nginx.conf:135-153` |
| 443 起不来 | 端口被占：`ss -ltnp \| grep :443`；改 `nginx.conf` 的 `listen` 与访问 URL |
| 证书过期 | 3650 天；用 `openssl x509 -in server.crt -noout -dates` 查，`FORCE=1` 重建后重启容器 |
