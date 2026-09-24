# 自带搜索（SearXNG）接入与引擎选型

> 适用对象：南宁 `nanning-111`（10.168.1.111）
> 本文是「联网搜索 / SearXNG」话题的**唯一事实来源**。
>
> 结论先行：**容器已接入、已测通**；国内网络下**只有 bing 与 360search 两个引擎能稳定出结果**。
> 剩余一步需在 **Web 控制台**完成（加 Provider，见 §5）。

---

## 一、结论速览

| 问题 | 结论 |
|---|---|
| 容器接入了吗 | ✅ `--profile searxng`（`$DC` 单点启用）+ `compose_up` 显式点名启动 |
| 测通了吗 | ✅ 中文查询"政府投资项目" → **15 条**（bing 10 + 360search 5），仅 quark 报 CAPTCHA |
| 引擎怎么选 | **bing（第一优先，weight 2.0）+ 360search（补充，1.0）**；**搜狗、百度、quark 都不用** |
| 实测效果 | 中文查询「政府采购」→ **15 条**（bing 10 + 360search 5），**无未响应引擎** |
| 控制台 Provider | ✅ **已配置**（2026-09-22 00:52）：`SearXNG-Local`（`is_default=true`、`base_url=http://searxng:8080`），UI 点测 **返回 1 条结果** |
| 端口 | 宿主 `127.0.0.1:41291`（仅回环、诊断用）；**容器间走 `http://searxng:8080`** |

---

## 二、为什么需要它

WeKnora 的联网搜索（Web Search Provider）需要一个搜索后端。SearXNG 是**元搜索引擎**：
自建、免 API Key、可自定义引擎，官方 compose 已内置为**可选**组件。

**门控事实**：官方基底里 `searxng` 与 `searxng-init` 都带
`profiles: [searxng, full]` ⇒ **不加 `--profile searxng` 就永远不会被创建**
（这正是它长期"配了却没起"的原因）。

---

## 三、接入方式（改动面 3 处）

| 文件 | 改了什么 |
|---|---|
| `deploy/deploy-wkj-dev.sh` | ① `$DC` 加 `--profile searxng`（**单点覆盖全部子命令**）② `compose_up` 显式 `up -d searxng` ③ `health_check` / `cmd_health` 纳入 searxng ④ settings.yml 的同步与重载判据（见 §4） |
| `my-docker/docker-compose.overlay.yml` | 新增 `searxng-init` 段：用 `volumes: !override` 把模板源指向我们自己的 settings.yml |
| `my-docker/searxng/settings.yml` | **新建**：国内引擎白名单 + 权重（官方 `docker/searxng/settings.yml` 一字未动） |

> **为什么必须显式点名启动**：`compose_up` 里那两条 `up -d` 都是**显式服务名**，
> 不带服务名的 up 不会创建 profile 门控服务 ⇒ 漏掉就会出现"编排里写了、实际没起"。

---

## 四、★ 引擎选型普查（2026-09-22 实测）

### 4.1 判据说明（重要）

**判据不是 HTTP 状态码，而是"能否拿到结果块"** —— 多个引擎返回 200 却是反爬页。
且**必须带 `-L` 跟随重定向**（百度首个响应是 302，不带 `-L` 会得出错误结论）。

```bash
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) ... Chrome/120.0 Safari/537.36'
curl -sL -A "$UA" --max-time 12 "<搜索URL>" -o /tmp/x.html -w '%{http_code} %{size_download}'
grep -ociE '<h2|<h3|class="result|b_algo' /tmp/x.html      # 结果块数
grep -oiE '<title>[^<]*' /tmp/x.html | head -1               # 反爬页会暴露在 title 上
```

### 4.2 实测结果

| 引擎 | HTTP | 体积 | 结果块 | 页面标识 | 结论 |
|---|---|---|---|---|---|
| **bing**（`cn.bing.com`） | 200 | 99 KB | **9**（`b_algo`） | `test - 搜索` | ✅ **采用，权重 2.0** |
| **360search**（`so.com`） | 200 | 513 KB | **8** | `政府采购_360搜索` | ✅ **采用，权重 1.0** |
| sogou | 200 | 996 KB | **66** | `test - 搜狗搜索` | ✅ 可用，但**老魏明确不用** |
| marginalia | 200 | 37 KB | 19 | `test - Marginalia Search` | ⚠️ 英文小众索引，中文无覆盖 |
| 头条搜索 | 200 | 1.4 MB | 2 | `test-头条搜索` | ⚠️ searxng 无对应模块 |
| seznam | 200 | 98 KB | 1 | `政府 – Seznam.cz` | ⚠️ 捷克引擎，中文结果极少 |
| **baidu** | 200 | 1.4 KB | 0 | **`百度安全验证`** | ❌ 反爬拦截（已移除） |
| quark | 200 | 1.3 KB | 0 | （无 title） | ❌ 反爬，searxng 报 `CAPTCHA`（**已移除**） |
| mojeek | 200 | 5.5 KB | 0 | **`Captcha`** | ❌ 验证码 |
| yandex | 200 | 41 KB | 0 | **`Verification`** | ❌ 验证页 |
| presearch / luxxle | 403 | — | 0 | `Just a moment...` | ❌ Cloudflare |
| zapmeta | 403 | 229 B | 0 | `403 Forbidden` | ❌ |
| startpage / qwant / yahoo / wiby | 000 | 0 | 0 | — | ❌ 不可达 |
| shenma | 200 | 1.2 KB | 0 | — | ❌ 空页（需 JS） |
| swisscows | 200 | 87 KB | 0 | `Web pages for test` | ❌ 结果需 JS 渲染 |

> **`ecosia` 特殊**：它的页面 title 是"搜索 - Microsoft 必应" ⇒ 本质是 **Bing 的封装**，
> 与 bing 结果重复，无增量价值。

### 4.3 最终引擎集

```yaml
use_default_settings:
  engines:
    keep_only: [bing, "360search"]
engines:
  - name: bing
    weight: 2.0                    # ★ 第一优先（老魏定）
    base_url: https://cn.bing.com  # ★ 默认 www.bing.com 本网络不可用
    categories: [general]          # ★ 官方默认定义里 bing 没有 categories 键
  - name: "360search"
    weight: 1.0
```

**两个必须补的字段**（否则 bing 根本不出结果，本次实测踩到）：

| 字段 | 为什么必需 |
|---|---|
| `base_url: https://cn.bing.com` | 默认 `www.bing.com` 在本网络不可用。官方 `settings.yml` 的 bing 段注释给的也是同一建议（`# for instances hosted in China`） |
| `categories: [general]` | 官方默认定义里 bing **没有 `categories` 键**，不显式声明不会进入普通搜索 |

---

## 五、✅ 控制台 Provider（2026-09-22 已完成）

searxng 的接入**不是靠 `.env` 配置**，而是在 **Web 控制台里新增一个 Provider**
（`.env.example` 的 H1 段即如此说明）。步骤（供重建环境时参考）：

1. 打开定制前端 `https://10.168.1.111:41280/` → **平台设置 → 网络搜索**
   （直达路径：`/platform/settings?section=websearch`）并登录
2. 新增：**类型选 `SearXNG`**，**Instance URL 填 `http://searxng:8080`**
3. 保存后点「测试」（后端会真的去请求 searxng）

**实测记录（2026-09-22 00:52，老魏在 UI 操作，服务端日志佐证）**：

| 项 | 值 |
|---|---|
| Provider 记录 | `name=SearXNG-Local` · `provider=searxng` · `is_default=true` · `parameters={"base_url":"http://searxng:8080"}` · `tenant_id=10000` |
| UI 点「测试」 | ✅ `{"success":true}`，**返回 1 条结果**（HTTP 200，517ms） |
| 服务端证据（app 日志） | `[WebSearch][SearXNG] query="test" url=http://searxng:8080` → `returned 1 results` → `[WebSearch][Test] succeeded` |
| API Key | **不需要**（`credentials.api_key.configured=false`） |

> ★ **这次「测试」才是真正的端到端判据**：请求由 **app 进程**发起、经**容器网络**打到 searxng、
> 并**真的解析出结果**。相比"容器起来了""接口返回 200"，它才证明整条链路可用。

> 为什么 URL 用 `http://searxng:8080` 而不是宿主 `127.0.0.1:41291`：
> Provider 的请求由 **app 容器**发出，走的是**容器网络**（Docker DNS 解析服务名）；
> `41291` 只是宿主侧回环端口，容器内不存在。
>
> 相关接口（供参考）：`POST /api/v1/web-search-providers`（创建）、
> `POST /api/v1/web-search-providers/test`（用原始凭据测试、**不落库**）—— 均需 Admin 权限。
> 它写入的 `api_key` 等字段是**密文存库**（由 `.env` 的 `SYSTEM_AES_KEY` 解密）。

---

## 六、★ 生效链路的两个坑（都实测踩过）

改 `my-docker/searxng/settings.yml` 之后，**"看起来部署了"和"真的生效"是两件事**：

| # | 坑 | 为什么 | 判据 |
|---|---|---|---|
| 1 | **卷内容可能是旧的** | `searxng-init`（oneshot）只在**被重建**时才把模板拷进命名卷；而 compose 的 `config-hash` **只覆盖挂载路径、不含文件内容** ⇒ 改了内容 init 不一定重建 | 宿主文件 sha256 **vs** 卷内文件 sha256 |
| 2 | **进程可能没加载新配置** | searxng **只在进程启动时**读 `/etc/searxng/settings.yml`。实测出现过：卷内容已与宿主完全一致（sha256 相同），但 searxng 是 6 分钟前启动的进程，跑的还是旧引擎集 ⇒ 搜索 0 结果 | 卷内文件 **mtime** vs searxng 的 **StartedAt** |

⇒ `deploy-wkj-dev.sh` 的 `compose_up` 里已按这两条**分别把关**（同步 + 按需重启）。
另：宿主文件缺失时**显式 warn**，不再静默跳过。

> **通用教训**：判"某个配置生效没有"，要同时问「**载体**里的值对不对」与
> 「**消费它的进程**加载过没有」。只查前者会得到"配置没问题但行为不对"的假象 ——
> 这与本文 §4.1（只看状态码看不出反爬）是同一类错误的两个面。

---

## 七、验证清单

```bash
# 1) 容器在跑 + 端口映射（应仅绑回环）
ssh nanning-111 'docker ps --filter name=searxng --format "{{.Names}} {{.Status}} {{.Ports}}"'

# 2) searxng 自己认为加载了哪些引擎（最权威）
ssh nanning-111 'docker exec -w /usr/local/searxng WeKnora-searxng \
  /usr/local/searxng/.venv/bin/python -c "
from searx.settings_loader import load_settings
s,_=load_settings(); print(sorted(e[\"name\"] for e in s[\"engines\"]))"'
#   期望：['360search', 'bing']

# 3) ★ 真实搜索 —— 判据是「结果非空」，不是状态码
ssh nanning-111 'curl -s --max-time 45 -A "Mozilla/5.0" \
  "http://127.0.0.1:41291/search?q=%E6%94%BF%E5%BA%9C%E6%8A%95%E8%B5%84%E9%A1%B9%E7%9B%AE&format=json" \
  | grep -o "\"engines\": \[[^]]*\]" | sort | uniq -c'
#   期望：bing 若干条 + 360search 若干条

# 4) 一键（部署脚本已内置同一口径）
./deploy/deploy-wkj-dev.sh health
```

---

## 八、证据清单

| 结论 | 证据 |
|---|---|
| searxng 被 profile 门控 | `docker-compose.yml` 的 `searxng` 服务段内 `profiles:`（本版 :608-610，`[searxng, full]`） |
| settings.yml 模板 → 命名卷 | `docker-compose.yml` 的 `searxng-init` 段（本版起于 :565） |
| 引擎白名单机制 | `/usr/local/searxng/searx/settings_loader.py:148-163`（`keep_only` 过滤） |
| 360search 模块存在且默认禁用 | `/usr/local/searxng/searx/settings.yml` 的 `name: 360search` 段（`disabled: true`） |
| 360search 的 URL | `searx/engines/360search.py:35`（`base_url = "https://www.so.com"`） |
| bing 的国内适配建议来自官方 | 官方 `settings.yml` 的 bing 段注释（`# base_url: https://cn.bing.com  # for instances hosted in China`） |
| Provider 走容器网络 | `.env.example` H1 段（"Instance URL 填 http://searxng:8080"） |
| Provider 接口与权限 | `internal/router/routes_infra.go:216-246`（CRUD，Admin+） |
| search 格式含 json | `my-docker/searxng/settings.yml` 的 `search.formats` |
