# `my-docker/nginx/` —— WeKnora 接入层（111 站点专属）

## 一、它是什么

**两个前端的 HTTPS + WSS 统一入口。** 官方前端与定制前端各自只绑宿主回环，
对外访问一律经过本层。

| 对外地址（全部 TLS，同一张证书） | 指向 |
|---|---|
| `https://10.168.1.111/` | 官方前端（不带端口的便捷入口） |
| `https://10.168.1.111:41200/` | 官方前端 |
| `https://10.168.1.111:41280/` | 定制前端（源码 `my-frontend/`） |

| 内层地址（只绑 127.0.0.1，不对外） | 说明 |
|---|---|
| `127.0.0.1:41211` | `WeKnora-frontend` 容器（官方前端） |
| `127.0.0.1:41212` | `WeKnora-frontend-wkj` 容器（定制前端） |
| `41201` | `WeKnora-app`（后端 API，**仍是 http**，未纳入本层） |

```
浏览器 --https/wss--> weknora-nginx(:443 / :41200 / :41280)
                        ├── http/ws --> 127.0.0.1:41211  官方前端 --> app:8080
                        └── http/ws --> 127.0.0.1:41212  定制前端 --> app:8080
```

> **前端容器为何只绑回环**：一个端口不能既是 http 又是 https。
> 要让本层占用 `41200` 提供 https，内层前端就必须让出它 —— 因此内层改为只绑
> `127.0.0.1`，对外只剩本层入口。这让"没有 http 端口"成为结构上的事实，而非约定。

## 二、它解决什么问题

BrowserSkill 配对时，后端要求**非 localhost 必须 `wss`**
（`internal/browserskill/manager.go:178-190`）。以 `http://<内网IP>:41200` 访问时，
前端把页面 origin 交给后端推导（`http`→`ws`），因 hostname 不是 localhost 而被拒，
页面报 **`BrowserSkill public URL requires WSS`**。

上游立场（原文）：
- `.env.example:779`：「远程部署必须使用 WSS（**包括内网**）」
- `docs/browser-skill-production.md:88`：「WSS 可以使用**企业 CA，无需公网**；远程明文 WS 不受支持」

本层让页面以 `https://` 打开、配对链接自然推导为 `wss://`。**两个前端都受益**。

## 三、为什么独立成一份编排

`my-docker/docker-compose.yml` 的定位是「官方 compose 的**副本 + 最小定制**」，
要求能与官方**逐行比对**（`compose-diff` 子命令依赖这个性质）。在这里加 service
会破坏它，因此本层单独一份 compose 文件管理。

另外三点设计取舍：

| 决定 | 理由 |
|---|---|
| `network_mode: host`，反代 `127.0.0.1:14100 / 14102` | 不依赖 compose 网络名（`weknora_WeKnora-network` 会随编排变化），与 WeKnora 编排彻底解耦 |
| 保留 `443` 作为官方前端的便捷入口 | 免带端口；与 `41200` 指向同一后端，冗余但无害。不需要时可从 `nginx.conf` 删掉那两行 `listen` |
| **不开 HSTS** | 自签证书下若证书被取消信任，HSTS 会把浏览器锁死在 https，连退回排查都做不到 |
| 上传上限 `512m` | 避免本层先于内层报 413；真实限制仍由内层按 location 决定 |

## 四、部署（在 111 的仓库根 `/mnt/data/weknora`）

```bash
# 1. 生成自签 CA + 服务器证书（幂等；重建用 FORCE=1）
#    ⚠️ 若证书已存在且访问端已信任，**不要**用 FORCE=1 —— 会作废已导入的信任
bash my-docker/nginx/gen-certs.sh
#    → 落在 /mnt/data/weknora-tls/（**目录名保留历史名**，证书不进 git）
#    → SAN 含 IP:10.168.1.111 / IP:127.0.0.1 / DNS:localhost（与端口无关，两个端口共用）

# 2. 起接入层
docker compose -f my-docker/nginx/docker-compose.yml up -d

# 3. 看状态与日志
docker compose -f my-docker/nginx/docker-compose.yml ps
docker compose -f my-docker/nginx/docker-compose.yml logs --tail=20
```

**启动顺序**：本层依赖两个前端容器的回环端口 ⇒ 请在两个前端都起来之后再起本层
（或起完本层后 `docker compose -f my-docker/nginx/docker-compose.yml restart`）。

## 五、访问端（Mac）必须信任这张 CA —— 这步不能省

> ⚠️ **为什么不能像普通自签站点那样"点继续访问"**：
> https 页面可以点「高级 → 继续前往」，但 **WebSocket 握手不会给这个交互机会**
> —— 证书不受信时 `wss` 直接失败，表现为"页面能开、配对仍然失败"。

```bash
# 从 111 取回 CA
scp nanning-111:/mnt/data/weknora-tls/ca.crt ~/Downloads/weknora-ca.crt

# 导入系统钥匙串并设为始终信任（需要输入密码）
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/weknora-ca.crt

# 核对指纹与服务器输出一致
openssl x509 -in ~/Downloads/weknora-ca.crt -noout -fingerprint -sha256
```

GUI 方式：双击 `ca.crt` → 导入「系统」钥匙串 → 找到 `WeKnora Local CA`
→ 右键「显示简介」→ 展开「信任」→ **使用此证书时：始终信任**。

> macOS 上证书信任**按钥匙串**生效，Chrome / Safari 都读系统信任库。
> 若 Chrome 仍报错，重启一次 Chrome。

## 六、验证

```bash
# ① 三个入口逐个验（用 CA 校验证书链，不跳过校验）——应全部 200
for u in https://10.168.1.111/ https://10.168.1.111:41200/ https://10.168.1.111:41280/; do
  curl -s -o /dev/null -w "  $u -> %{http_code}\n" --cacert /mnt/data/weknora-tls/ca.crt "$u"
done

# ② 证书链与 SAN
openssl s_client -connect 10.168.1.111:41280 -CAfile /mnt/data/weknora-tls/ca.crt \
  -verify_return_error </dev/null 2>&1 | grep -E "Verify return code|subject="

# ③ 两个前端是否指向不同后端（改过定制前端后，两边内容会不同）
curl -s --cacert /mnt/data/weknora-tls/ca.crt https://10.168.1.111:41200/ | head -c 120
curl -s --cacert /mnt/data/weknora-tls/ca.crt https://10.168.1.111:41280/ | head -c 120

# ④ WebSocket 升级是否能穿过 TLS 层 —— 应返回 403（缺设备令牌的正常拒绝），
#    若返回 400/426 说明 Upgrade 头在中途被丢了
for p in 41200 41280; do
  echo "-- :$p"
  curl -s -i -N --max-time 6 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    --cacert /mnt/data/weknora-tls/ca.crt "https://10.168.1.111:$p/api/v1/local-browser/extension" | head -2
done
```

## 七、业务侧验证（在 Mac 上）

1. 浏览器打开 **`https://10.168.1.111:41200/`**（官方）或 **`https://10.168.1.111:41280/`**（定制）
2. 地址栏应显示锁标（证书受信任）
3. 「设置 → 浏览器连接」→ 下载扩展 → 点配对
4. 此时后端收到的 origin 是 `https://…`，推导出 `wss://…` ⇒ **不再报 requires WSS**
5. 把配对链接粘进 Chrome 扩展完成配对

## 八、回滚 / 停用

```bash
# 停掉接入层
docker compose -f my-docker/nginx/docker-compose.yml down

# 注意：停掉后两个前端都**无法从外部访问**（内层已只绑回环）。
# 若需临时退回直连，把前端编排的 ports 改回对外绑定，例如：
#   my-docker/frontend-wkj/docker-compose.yml → "41280:80"
#   .env 的 FRONTEND_PORT → 41200
# （改完 up -d 重建对应容器）
```

## 九、排查清单

| 现象 | 原因 |
|---|---|
| 页面能开，但配对仍失败 | 证书未受信任（见第五节）；或 Chrome 未重启 |
| `NET::ERR_CERT_COMMON_NAME_INVALID` | SAN 里没有你访问用的那个 IP/域名 ⇒ `FORCE=1 bash gen-certs.sh` 重建（**会作废已导入的信任，需重新导入**） |
| 某个端口 502 | 对应前端容器没起，或没绑在预期的回环端口：`ss -ltn \| grep -E '41211\|41212'` |
| 端口起不来 / nginx 启动失败 | 端口被占：`ss -ltnp \| grep -E ':(443\|41200\|41280)'`。常见原因是前端容器仍绑着 41200 —— 检查 `.env` 的 `FRONTEND_PORT` 是否已改为 `127.0.0.1:41211` |
| ws 请求返回 400 / 426 | `Upgrade` 头在某层被丢：检查本目录 `nginx.conf` 的两行 `proxy_set_header`，以及内层 `frontend/nginx.conf:135-153` |
| 证书过期 | 3650 天；用 `openssl x509 -in server.crt -noout -dates` 查，`FORCE=1` 重建后重启容器 |

## 十、迁移记录

**2026-09-21：前端回环口迁入服务号段（`14100` / `14102` → `41211` / `41212`）**

起因：容器组约定「**服务端口一律取 `41200`–`41299`**，不论对外还是仅回环」
（见仓库根 `AGENTS.md` 第 4 条）。原 `14100` / `14102` 不在号段内，属早期遗留。

职责不变 —— 仍是**只绑 `127.0.0.1`、仅供诊断直连**的前端容器端口，仅号码迁移：

| | 之前 | 现在 |
|---|---|---|
| 官方前端容器 | `127.0.0.1:14100` | **`127.0.0.1:41211`** |
| 定制前端容器 | `127.0.0.1:14102` | **`127.0.0.1:41212`** |

> 使用取向（老魏 2026-09-21）：**日常主用定制前端**（对外 `:41280`、诊断 `:41212`）；
> **官方前端留作功能对照**（对外 `:41200`、诊断 `:41211`）。

**2026-09-21：`tls` → `nginx`（正名 + 扩为双入口）**

| | 之前 | 现在 |
|---|---|---|
| 目录 | `my-docker/tls/` | **`my-docker/nginx/`** |
| 容器 | `weknora-tls` | **`weknora-nginx`** |
| 职责 | 给官方前端 41200 加 TLS | **两个前端的统一 HTTPS/WSS 入口** |
| 覆盖端口 | `443` → 127.0.0.1:41200 | `443` + `41200` → 14100；`41280` → 14102 |
| 前端容器绑定 | 对外 `41200` / `41202` | **只绑回环** `14100` / `14102`（当晚即迁至 `41211` / `41212`，见上一条） |
| 证书目录 | `/mnt/data/weknora-tls` | **不变**（刻意保留，避免作废已导入的 CA 信任） |

正名理由：它的职责已从"给某个服务加 TLS"升级为"站点的统一接入层"——
`tls` 描述的是**手段**，不是**身份**。
