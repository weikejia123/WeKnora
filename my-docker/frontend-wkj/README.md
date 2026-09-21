# `my-docker/frontend-wkj/` —— 定制前端（wkj）的独立编排

## 一、这是什么

在官方前端之外**并行运行第二个前端**，端口不同、同一后端：

```
my-frontend/                    官方 frontend/ 的逐字副本（源码在这里改）
my-docker/frontend-wkj/         独立编排（本目录）：容器名/镜像 tag/端口独立
```

| 项 | 官方前端 | 定制前端（本目录） |
|---|---|---|
| 源码 | `frontend/` | **`my-frontend/`**（逐字副本） |
| 镜像 tag | `wechatopenai/weknora-ui` | **`wechatopenai/weknora-ui-wkj`** |
| 容器名 | `WeKnora-frontend` | **`WeKnora-frontend-wkj`** |
| 宿主端口 | `41200` | **`41202`** |
| compose 项目名 | `weknora` | **`weknora-frontend-wkj`** |
| 访问地址 | `http://10.168.1.111:41200/` | `http://10.168.1.111:41202/` |

后端是同一个（`app` 容器）⇒ **两个前端看到的是同一份数据**。

## 二、为什么编排不放进 `my-frontend/`

`my-frontend/` 要一直保持**"能与官方逐字 diff"**的状态：

```bash
diff -r frontend my-frontend        # 应恒为 0 差异（除你刻意的改动）
```

这是**以后按需合并官方更新**的基准 —— 一旦副本里混入编排、README 等非源码文件，
每次 diff 都要靠人脑过滤噪声。所以：

- **源码改动** → 改 `my-frontend/`
- **编排/说明** → 留在这里
- 副本复制于 **2026-09-21**（770 文件，`diff -r` 零差异）

## 三、部署

在 111 的仓库根 `/mnt/data/weknora`：

> ⚠️ **不要传 `--env-file .env`**。主编排的 `.env` 里有 `COMPOSE_PROJECT_NAME=weknora`，
> 而 Compose 的项目名优先级是 `-p` > `COMPOSE_PROJECT_NAME` > compose 的 `name:` > 目录名
> ⇒ 一旦传了它，本编排的 `name: weknora-frontend-wkj` 会被覆盖（实测确认），
> 副本容器会被归入主编排项目。
> 本文件里所有变量都写了与站点一致的默认值（`npmmirror` / 50MB / 41202 / 独立镜像 tag），
> **不需要**主编排的 `.env`。

```bash
# 1. 构建（首次约 5~10 分钟；国内构建走 npmmirror）
docker compose -f my-docker/frontend-wkj/docker-compose.yml build

# 2. 启动（确认 app 已在运行；本编排不负责启停 app）
docker compose -f my-docker/frontend-wkj/docker-compose.yml up -d

# 3. 查看
docker compose -f my-docker/frontend-wkj/docker-compose.yml ps
docker compose -f my-docker/frontend-wkj/docker-compose.yml logs --tail=20

# 4. 改过 my-frontend/ 里的代码后：重新 build 再 up -d
docker compose -f my-docker/frontend-wkj/docker-compose.yml build
docker compose -f my-docker/frontend-wkj/docker-compose.yml up -d

# 停用（不影响官方前端）
docker compose -f my-docker/frontend-wkj/docker-compose.yml down
```

## 四、怎么确认两个前端都在跑（互不干扰）

```bash
# 两个容器应同时存在
docker ps --filter name=WeKnora-frontend --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# 两个地址都通，且都指向同一个后端
curl -s -o /dev/null -w '官方  %{http_code}\n' http://10.168.1.111:41200/
curl -s -o /dev/null -w '定制  %{http_code}\n' http://10.168.1.111:41202/
curl -s -o /dev/null -w '后端  %{http_code}（401=需登录，正常）\n' http://10.168.1.111:41201/api/v1/system/info

# 镜像必须各自独立（若两者 tag 相同，说明被静默覆盖了）
docker image inspect wechatopenai/weknora-ui:latest     --format '官方 {{.Created}}'
docker image inspect wechatopenai/weknora-ui-wkj:latest --format '定制 {{.Created}}'
```

> **登录状态不共享**：token 存在浏览器本地、按 origin 隔离 ⇒ 两个端口各登录一次。
> 这是浏览器同源策略的正常结果，不是缺陷。

## 五、跟官方合并更新的做法（以后按需）

因为副本是**逐字复制**的，合并代价最低：

```bash
# 1) 看官方 frontend/ 相对副本复制点改了什么
git log --oneline <复制点>..HEAD -- frontend/
git diff --stat <复制点>..HEAD -- frontend/

# 2) 逐项判断：官方的改动要不要摘进 my-frontend/
#    · 与你改过的文件冲突 → 手工合并，保留你的定制
#    · 你没动过 → 直接覆盖（cp 或 patch）

# 3) 合并后重建
docker compose -f my-docker/frontend-wkj/docker-compose.yml build && \
docker compose -f my-docker/frontend-wkj/docker-compose.yml up -d

# 4) 复查差异面是否仍只有你的刻意改动
diff -r frontend my-frontend
```

**建议**：把"副本复制点"的 commit 记在这里，下次合并好对照。

> 副本复制点：`____________`（复制时 111 上的 HEAD，2026-09-21）

## 六、几个必须知道的点

| 事项 | 说明 |
|---|---|
| **镜像 tag 绝不能与官方共用** | 共用会被 `pull` / `build` 互相静默覆盖（同类风险已在 `deploy/deploy-wkj-dev.sh` 针对 app/ui 处理过） |
| **项目名独立**（`weknora-frontend-wkj`） | 否则会继承 `.env` 的 `COMPOSE_PROJECT_NAME=weknora`，被归入主编排项目、归属混乱 |
| **依赖主编排的网络** | 反代目标是 `app`（同网络内的服务名）。主编排若改网络名，这里要同步改 `networks.WeKnora-network.name` |
| **本编排不管 app** | 跨编排无法声明 `depends_on`，启动前自行确认 app 在跑 |
| **运行时可配只有 4 项** | `MAX_FILE_SIZE_MB` / `MAX_SKILL_BUNDLE_SIZE_MB` / `DEFAULT_LOCALE`（+ `EMBED_BASE_URL` 在 `public/config.js`），其余改动都要动源码 |
| **`package.json.md5` 是失效文件** | 记录值（`a8c281…`）与当前 `package.json`（`de4d3b71…`）不符；全仓无引用、且被 `.dockerignore` 排除 ⇒ 不影响构建。保留它只为与官方保持一致 |
| **副本的 `.dockerignore` 需要 `git add -f`** | 根 `.gitignore:2` 有 `.*` 规则会忽略点开头的文件；官方 `frontend/.dockerignore` 因**早已被跟踪**而豁免，副本是新文件 ⇒ 会被拦下，导致 111 上**没有 `.dockerignore`**（Docker 只在 context 根找它，不会向上找）。已用 `git add -f` 纳入。<br>★ 以后在副本里新增任何 dotfile（如 `.env.example`），同样要 `-f`；或者你决定允许改官方 `.gitignore` 时，加一条 `!my-frontend/.*` 更省事 |
