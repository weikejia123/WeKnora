# WeKnora 小版本更新的部署优化方案

> ⚠️ **状态：本文提出的方案已于 2026-09-22 落地实施，权威载体已转移到
> `12-应用代码外置/WeKnora-应用代码外置方案.md`。**
>
> 本文保留为**决策过程与实测依据**（为什么需要优化、三种方案如何比较）——
> 但**不要再按本文的"待决问题"行事**，那些问题已经有答案了：
>
> - 文末"是否给部署脚本加 `push-ui` 子命令"⇒ **已实现**，且后续又加了
>   `push-app`（后端 Go）/ `push-reader`（docreader）/ `sync` / `up`；
> - 三个方案里被采纳的是**方案一（静态文件映射）**；其边界、坑与实测耗时的完整记录见 12 号文档。

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

**「改变代码来源」是什么意思**：bind mount 是**遮盖**，不是合并 ——

- **现在**：容器内 `/usr/share/nginx/html` 的真身来自**镜像层**
  （构建时 `COPY --from=builder /frontend/dist /usr/share/nginx/html`，`frontend/Dockerfile:61`）
- **挂载后**：同一路径被宿主目录**盖住**，镜像里那份**不再生效**

⇒ 连带三个后果：

1. **镜像不再自包含** —— 光有镜像起不来完整服务，还要求那个目录就位；
2. **「跑的是哪一版」要看目录内容**，不能只看镜像 ID（原有的 `wkj-last-build` 登记机制覆盖不到它）；
3. **目录空 ⇒ 页面 404**（镜像里那份被遮住，兜不住）。

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

## 八、应用整体映射的评估（老魏 2026-09-21 提出）

老魏的想法更进一层："**把应用放在映射目录里，容器不用动，只需要把应用映射目录里的文件换了就行**"。

**结论：对前端与 docreader 成立，对 app 不成立** —— 因为"应用"这个词下面藏着三种完全不同的形态。

| 应用 | 形态 | 能否映射替换 | 代价 |
|---|---|---|---|
| `frontend` / `frontend-wkj` | **静态文件** | ✅ 最理想 | 无（换文件即生效） |
| `docreader` | **Python 源码** | ✅ 适用 | 代码在 `/app/docreader/`（`Dockerfile.docreader:77`），依赖装在镜像内 venv（`:147`）⇒ **只换源码、依赖不变时无需重建**。入口 `CMD ["/app/.venv/bin/python","-m","docreader.main"]`（`:177`） |
| `app` | **编译产物**（Go + cgo） | ⚠️ **不推荐** | 见下三个硬障碍 |

### `app` 的三个硬障碍（实测）

1. **有 cgo 且有动态依赖** ⇒ 无法在 Mac 上直接交叉编译。
   - `go.mod:13` `asg017/sqlite-vec-go-bindings`、`go.mod:241` `mattn/go-sqlite3`（cgo）
   - `ldd /app/WeKnora` 实测依赖 `libm` / `libstdc++` / `libgcc_s` / `libc` —— **不是静态二进制**
   - ⇒ 必须在**兼容的 Linux 环境**里编译（容器内编译或 111 上编译）
2. **架构不同**：本机 arm64，111 是 amd64。本机镜像实测为 `aarch64`（`lib/aarch64-linux-gnu/`），
   ⇒ 本地产物**不能直接用于 111**。
3. **体积与重启**：二进制 **259,970,760 B ≈ 248 MiB**，每次传输这个量级；
   且换完必须 `docker restart`（进程已在内存，不能热替换）。

### 更关键的一点：**编译时间省不掉**

映射替换省掉的是「镜像层导出/导入 + 容器重建」，而 app 的耗时大头是 **Go 编译本身**
（Rust anydoc / browserskill 又是另外两个阶段）。所以在 app 上做映射，
收益远小于前端，却要额外承担交叉编译与架构匹配的复杂度。

**建议**：`app` 保持「按镜像增量构建」（`build app && up -d app`）；
把映射方案的收益集中用在**前端**（老魏二开的主场景）上。

### 附：`app` 容器的启动链（评估时需知）

```dockerfile
# docker/Dockerfile.app
WORKDIR /app
ENTRYPOINT ["./scripts/docker-entrypoint.sh"]   # :214
CMD ["./WeKnora"]                                # :215
```
⇒ 若真要挂载替换，只覆盖 `/app/WeKnora` 一个文件即可，
`/app/scripts`、`/app/config`、`/app/migrations`、`/app/skills` 仍取镜像内版本。

## 九、证据

- 耗时实测：`my-docs/03-生产部署/WeKnora-生产部署与运维.md:246, :425, :599, :605`
- 前端分层：`frontend/Dockerfile:38-49, :61`
- entrypoint 写 config.js：`my-frontend/docker-entrypoint.sh:23`
- 静态根目录：`my-frontend/nginx.conf:44`（`root /usr/share/nginx/html;`）
- 构建目标：`deploy/deploy-wkj-dev.sh`（`build` 模式）
