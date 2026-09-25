# WeKnora 官方 main 更新分析（第 8 轮）

> 同步日期：2026-09-25 ｜ 范围：`68fe9599`（第 7 轮）→ `8619bdf3`
> 合并提交：`229ae231`（回滚点 `038af272`）

---

## 一、概览

| 项 | 值 |
|---|---|
| 官方新增提交 | **4** |
| 改动规模 | **118 文件 / +11,013 −1,695** |
| 是否发版 | **否**（`v0.8.2-24`；最新 tag 仍是 `v0.8.2`） |
| 依赖面 | ★ **有变**：`frontend/package.json` 新增 **`pdfjs-dist@^6.3.289`**；`docreader/` 的依赖清单（`pyproject.toml` 等）**未动** |
| 新迁移 | ★ **`000114_chunk_source_locators`**（+ sqlite `000033`） |
| `go build ./...` | **exit=0**（38 秒） |
| 官方是否动 `docker/` | **否** ⇒ 我方 2 个例外 Dockerfile 安全 |

> ★ **只有 4 个提交，却有 118 文件 / 1.1 万行** —— 因为其中一条是**跨栈大改**（见 §2.1）。
> 不要按"提交数少"就判断"改动小"。

---

## 二、更新内容（使用视角）

### 2.1 ★★ 引用可跳转到原文位置（`1bf717a5`，#3700）—— 本轮主体

**行为变化**：点击回答里的引用，以前只展示被解析出的 chunk（一段文本）；
现在**打开原文件、跳到被引用的位置并高亮**，且**收窄到支撑该引用的那一句**。

**实现是跨全栈的**：

| 层 | 改动 |
|---|---|
| **数据库** | 迁移 `000114`：`ALTER TABLE chunks ADD COLUMN IF NOT EXISTS source_locators JSONB`（**仅加一列**，无索引重建） |
| **Go** | **新增 `internal/sourceloc/` 包**（`align.go` / `assign.go` / `office.go` / `remap.go` / `text.go` + 测试） |
| **docreader** | **新增 `parser/source_locator.py`**（10.8 KB）与 **`source_wire.py`**；proto 扩展（`docreader.proto` 及 pb2/pb.go 生成物） |
| **前端** | 新增 `src/components/source-preview/`（`PdfSourceViewer.vue` + `pdfjsLoader.ts`）；用 **pdf.js** 渲染 PDF、用 **CSS Custom Highlight API** 高亮 |

**支持定位的类型**（官方 commit body 原文）：PDF 页与段落框（**来自 docreader、MinerU 和 PaddleOCR-VL 的 layout**）、
Word 段落、幻灯片、表格行、EPUB 章节（在 Go 侧对各解析引擎的 Markdown 做对齐）、
Markdown/TXT 的文本偏移、音频的时间段；管线文本重写用 **line-diff remapper** 跟随；
扫描版 PDF 的 OCR 文本在检索时作为 quote，使句子能定位到页。

> ★ **与我们 MinerU 4.0 接入的组合效应**：官方这个功能**原生消费 MinerU 的 layout 输出**来产生
> PDF 页/段落框定位。我们刚接上的 MinerU 4.0（`set the citation to jump`）因此是**受益方** ——
> 用 MinerU 解析的文档也能享受引用跳转，不需要额外适配。

### 2.2 ★ 修复解析卡在 `processing` / `finalizing`（`ab115c09`，#3696）

这正是我们文档里记录过的坑。修复含三组：

| 组 | 内容 |
|---|---|
| **重解析** | 只在覆盖校验与清理通过后才开新 attempt（被拒绝的重解析曾让上一轮子任务误判"已被取代" ⇒ 行**永久停在 finalizing**）；取消上一轮在途的排队任务；摘要任务只写自己的列（全行保存会把 `finalizing` 覆盖到新轮的 `processing` 行上） |
| **错误被 ack 但行还在途** | 失败的后处理入队改为原地重试后再返回；租户/知识库读取与 processing 写入加重试 |
| **孤儿图片** | 末次尝试的孤儿检查失败时仍保留该图 |

⇒ 对**正在做知识库入库**的场景有实际收益。

### 2.3 图库重构（`ebbcf96f`）

图库的工具栏、头部标签与图片查看器重做（第 7 轮刚引入图库标签页，这轮是跟进打磨）。

### 2.4 文档（`8619bdf3`）

README 换新的介绍视频。

---

## 三、二开影响评估

### 3.1 合并记录

| 项 | 值 |
|---|---|
| 回滚点 | `038af272` |
| 合并提交 | `229ae231` |
| 冲突 | **0**（`git diff --diff-filter=U` 为空） |

### 3.2 冲突预判：双方法确认

```bash
# 方法一：三点比较（merge-base = 68fe9599）
#   官方 118 文件 / 我方 877 文件 → 交集 0
# 方法二：merge-tree 预演（不碰工作区）
git merge-tree --write-tree --name-only wkj-dev main
#   → df73d6e63c566a523eaae8948118995ee58a854f（单 tree OID = 干净）
```

### 3.3 二开完整性校验

```bash
comm -23 /tmp/dev8.txt /tmp/after8.txt   # → 空（零丢失）
# 关键目录：my-docker / my-frontend / my-docs / deploy / AGENTS.md / my-scripts 全部在位
```

### 3.4 前端副本同步（判据成立）

```bash
# 归因：差异能否全部归因于官方
comm -13 /tmp/fe_up8.txt /tmp/d8all.txt
#   → 1 条：src/components/source-preview（**目录级**条目，官方新增目录，
#      反向 comm 显示其下 PdfSourceViewer.vue / pdfjsLoader.ts 两个文件级条目）
#      ⇒ 又是「目录级假阳性」，与第 7 轮同型
rsync -a --exclude=/dist --exclude=/node_modules frontend/ my-frontend/
diff -rq frontend my-frontend | wc -l    # 32 → 2（仅 dist / node_modules 两项产物）
```

| 项 | 值 |
|---|---|
| 副本差异 | 32 条 = 22 differ + 8「仅官方有」+ 2 产物 |
| `dist/index.html` sha256 | 覆盖前后均 `aaa0b336…` ⇒ 产物未受影响 |
| ★ 新增依赖处理 | 副本带上 `pdfjs-dist` 声明后执行 **`npm install`**（`added 3 packages`） |
| 副本复制点 | `my-docker/README.md`：`68fe9599` → **`8619bdf3`** |

> ★ 本轮多了一步**副本依赖安装**（前 7 轮没有过）——`frontend/package.json` 首次新增依赖。
> 漏了它，`push-ui` 的本地构建会在 `pdfjs-dist` 处失败。

---

## 四、★ 2 个例外 Dockerfile 的必要性判断

**结论：仍然必要；本轮官方未动 `docker/`，我方改动不受影响。**

| 文件 | 我方领先的改动 | 行数 |
|---|---|---|
| `docker/Dockerfile.app` | `APK_MIRROR_ARG` 条件换源（browserskill 阶段；该阶段基镜像 `node:24-bookworm-slim` **不带 CA**，必须先官方源装 CA 再换源）+ 其余 `RUSTUP_*` / `GH_PROXY` / `NPM_REGISTRY_ARG` / `CARGO_REGISTRY_ARG` | +61 |
| `docker/Dockerfile.docreader` | `GH_PROXY`（protoc / grpc_health_probe 的 GitHub 加速前缀）—— **与 OCR 无关，勿误删** | +9 |

⇒ 全部为**中性 ARG**（留空 = 官方行为），无一条冗余；
`--build-arg` 只有 Dockerfile 里 `ARG` 声明过才可用 ⇒ 无法改为纯编排注入。

---

## 五、连带发现

### 5.1 ★ 官方本轮引入了「依赖面变化」——但**不需要 build**

`frontend/package.json` 新增 `pdfjs-dist`，按"依赖清单变更需 build"的口诀看似要 build，
但我们的前端是**外置层**（`my-frontend/dist` 挂载到容器，镜像里那份被遮蔽）
⇒ **构建发生在本地**，`push-ui` 即可。

⚠️ **一个需要知道的边界**：官方 `frontend` 容器（回环口 **41211**）用的是**镜像内的 dist**，
它**不会**随 `push-ui` 更新 ⇒ 本轮之后 **41211 仍是上一版**。
若要与定制前端做"同版本对照"，需要额外 `build frontend`。**本轮未做**（老魏主用定制前端 41212）。

### 5.2 所有被引用行号的官方文件本轮**全部未被改动**

`Makefile` / `docker-compose.yml` / `.env.example` / 两个 Dockerfile / `internal/container/container.go`
—— 均未变 ⇒ 我方文档里的行号引用**全部仍然有效**，本轮无需订正。

### 5.3 docreader 首次出现「新增源文件」

前 7 轮官方几乎不动 `docreader/`，本轮新增 `source_locator.py` / `source_wire.py` 并改 proto
⇒ **必须 `push-reader`**（外置层同步 + 重启）。
只做 `push-app` 会漏掉 docreader 侧的新文件 ⇒ 引用跳转在 docreader 解析的文档上失效。

---

## 六、★ 部署判断：**必须部署**，且组合与以往不同

| 判断项 | 结论 |
|---|---|
| 是否需要 `build` | **不需要**（依赖变化都落在两层外置层：前端本地构建、docreader 同步源码） |
| 是否需要 `push-app` | **需要**（`internal/` 大改 + 新增 `sourceloc` 包 + proto 生成物） |
| ★ 是否需要 `push-reader` | **需要** —— 本轮**首次**（docreader 新增源文件 + proto 改） |
| 是否需要 `push-ui` | **需要**（`frontend/src` 29 文件 + 新依赖 `pdfjs-dist`） |
| 是否需要 `up` | **不需要**（编排未变） |
| ★ 是否必须先备份 | **必须** —— 新迁移 `000114`，app 启动会自动跑 |

**执行顺序**：备份 → `push-app` → `push-reader` → `push-ui`。

---

## 七、待办

1. 部署后人工测试（老魏）：重点验**引用跳转原文位置**（点击引用应打开原文件并高亮到具体句子）。
2. 若需要官方前端(41211)与定制前端同版本对照 ⇒ 额外 `build frontend`。
3. `internal/sourceloc/` 是本轮新增的 Go 包 —— 后续若我们自己动解析链路，注意它是引用定位的唯一实现处。

---

## 八、证据（可复核）

```bash
# 规模与发版
git rev-list --count 68fe9599..8619bdf3          # 4
git diff --shortstat 68fe9599..8619bdf3          # 118 files changed, +11013 −1695
git describe --tags 8619bdf3                     # v0.8.2-24-g8619bdf3

# 依赖面（★ 本轮非空）
git diff --name-status 68fe9599..8619bdf3 -- frontend/package.json
#   → M  frontend/package.json（+pdfjs-dist）

# 新迁移
git diff --name-status 68fe9599..8619bdf3 -- migrations/
#   → A  migrations/versioned/000114_chunk_source_locators.{up,down}.sql

# 冲突预判（双方法）
git merge-tree --write-tree --name-only wkj-dev main   # 单 tree OID df73d6e6

# 例外 Dockerfile（官方是否动过）
git diff --name-status 68fe9599..8619bdf3 -- docker/   # 空

# 副本判据
diff -rq frontend my-frontend | wc -l            # 2（仅产物）
shasum -a 256 my-frontend/dist/index.html        # aaa0b336…（覆盖前后一致）
grep -c pdfjs-dist my-frontend/package.json      # 1
```
