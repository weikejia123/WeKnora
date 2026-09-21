# WeKnora 小版本更新的部署优化方案

> 动机（老魏 2026-09-21）："每次在 111 上重构镜像效率太低，小版本更新应该换 docker 中的应用代码即可。
> 其实还是时间成本的问题 —— 如果每次重建镜像 5 分钟内能全部搞定，问题也不大。"

## 一、先量一量：实测是 16 分钟，不是 5 分钟

`my-docs/03-生产部署/WeKnora-生产部署与运维.md` 里的实测记录：

| 场景 | 实测耗时 | 出处 |
|---|---|---|
| 全量构建（app / frontend / docreader 三个镜像） | **15m57s** | `:605` |
| 二次构建（有缓存） | **16m47s** | `:599` |
| 首次构建（无缓存） | 20~40 分钟 | `:246` |
| 其中 browserskill 阶段（已优化后） | 223s（优化前 1539s 未装完） | `:425` |

⇒ **16 分钟远超"5 分钟"阈值 ⇒ 优化是有意义的**。

## 二、慢在哪：三个镜像的成本完全不同

| 镜像 | 构建内容 | 成本特征 |
|---|---|---|
| **`app`** | Go 编译（2047 个 .go）+ Rust anydoc 工具链 + browserskill（Node+Rust） | **最重**：Rust 工具链下载与编译、Go 全量编译 |
| **`frontend` / `frontend-wkj`** | `npm ci` + `npm run build`（Vue） | **轻得多**，且分层干净 |
| **`docreader`** | Python 依赖 + protoc / grpc_health_probe | 中等 |

**`frontend/Dockerfile` 的分层是关键**：

```
:38  COPY package.json package-lock.json ./     ← 依赖层
:39  RUN  npm ci                                 ← package.json 不变则缓存复用 ✔
:45  COPY . .                                    ← 改任何源码都从这层开始失效
:49  RUN  npm run build                          ← 重跑（通常 30s~2min）
:61  COPY --from=builder /frontend/dist /usr/share/nginx/html
```

⇒ **改前端源码时，`npm ci` 那层能复用**，只重跑 `COPY . .` + `npm run build`。

## 三、三个方案（前端为主）

| # | 方案 | 机制 | 耗时 | 持久性 | 编排改动 |
|---|---|---|---|---|---|
| **A** | **bind mount 静态文件** | 宿主目录挂到 `/usr/share/nginx/html`，本地构建后 rsync 过去 | **本地 build 时间 + 秒级传输**（111 上零操作） | ✔ volume 持久 | overlay 加 `volumes` |
| **B** | `docker cp` 静态文件 | `docker cp dist/. <容器>:/usr/share/nginx/html/` | 本地 build + 秒级 cp | ✘ **容器重建即丢** | 无 |
| **C** | 只重建 frontend 镜像 | `docker compose build frontend-wkj` | **约 1~3 分钟** | ✔ | 无 |

### 方案 A 的细节

```yaml
  frontend-wkj:
    volumes:
      - /mnt/data/weknora-wkj-dist:/usr/share/nginx/html
```

流程：本地 `npm run build` → `rsync dist/ nanning-111:/mnt/data/weknora-wkj-dist/` → **立即生效**（nginx 直接读文件，无需重启）。

## ★ 四、方案 A 有一个必须防的坑

`docker-entrypoint.sh` 启动时会**往该目录写运行时配置**：

```sh
cat > /usr/share/nginx/html/config.js << EOF
window.__RUNTIME_CONFIG__ = { MAX_FILE_SIZE_MB: ..., ... };
EOF
```

⇒ 两个后果：
1. **挂载不能加 `:ro`** —— 否则容器启动即失败（写不进去）。
2. **volume 目录若为空 ⇒ 页面 404**（镜像里的 dist 已被挂载覆盖）。
   ⇒ 首次启用时必须**先推一份 dist 再启容器**，或保证目录非空。

另：rsync 推送时若用 `--delete`，会删掉容器生成的 `config.js` —— 无害（重启会重建），但要知道。

## 五、建议（按改动类型分场景）

| 你改了什么 | 用什么 | 预计耗时 |
|---|---|---|
| **前端源码（日常主要场景）** | **方案 A**：本地 build + rsync | **1~2 分钟，且不占 111** |
| 前端代码 + 依赖（`package.json` 变了） | 方案 C：`build frontend-wkj && up -d frontend-wkj` | 2~4 分钟 |
| **后端代码** | `build app && up -d app`（Go 编译无法避免；也可在 111 上编译后 `cp` 二进制 + `restart`） | 5~12 分钟 |
| docreader | `build docreader && up -d docreader` | 2~5 分钟 |
| 上游同步 / 基础镜像变更 | 全量 `build` | ~16 分钟（不可避免） |

**一句话**：把"每次全量重建"改成"**按镜像增量构建**"，前端的日常改动就能压到分钟级甚至秒级。

## 六、后端为什么不能像前端那样"换代码"

Go 是编译型语言，容器里跑的是**单个二进制**（`/app/WeKnora`）。要"换代码"必须重新编译。
可选路径：
- 在 111 上编译（32 核，估 1~2 分钟）→ `docker cp` 二进制 → `docker restart WeKnora-app`；
  代价：**容器重建即丢**（同方案 B 的性质）。
- 或者维持 `build app`（有构建缓存，比全量快）。

⇒ **前端是主要场景（老魏：二开主要围绕前端），优先优化前端**。

## 七、待确认

1. 方案 A（bind mount）是否采用？—— 它会改变前端的"代码来源"（从镜像内变为宿主目录），
   属于结构性变化，**需老魏拍板**。
2. 是否给部署脚本加一个子命令（如 `push-ui`：本地 build + rsync + 校验）？
3. 后端是否也要做"编译后 cp"的快速通道？

## 八、证据

- 耗时实测：`my-docs/03-生产部署/WeKnora-生产部署与运维.md:246, :425, :599, :605`
- 前端分层：`frontend/Dockerfile:38-49, :61`
- entrypoint 写 config.js：`my-frontend/docker-entrypoint.sh:23`
- 静态根目录：`my-frontend/nginx.conf:44`（`root /usr/share/nginx/html;`）
- 构建目标：`deploy/deploy-wkj-dev.sh`（`build` 模式）
