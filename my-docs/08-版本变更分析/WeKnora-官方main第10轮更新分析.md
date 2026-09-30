# WeKnora 官方 main 第 10 轮更新分析

> 同步日期：2026-10-01 ｜ 区间：`4df7ccbb..bccb4b15`（36 提交，v0.8.2-102）｜ 耗时：fetch 10s / go build exit=0
> 合并提交：`ec47f067`（零冲突）｜ 前端副本同步：`f439f2d1` ｜ 回滚点：`fb80b1ce`

## 1. 概览

- 36 提交 / 252 文件（+11428 / −1279），无新发版（v0.8.2-102）
- 依赖面：**go.mod、frontend/package.json 均未动** → 无依赖迁移
- 迁移：**无新迁移文件** → app 重启不触发 DB 迁移
- 编译：`go build ./...` exit=0（仅 `-lc++` 重复链接警告，官方自身遗留）

## 2. 更新内容（用户视角）

### feat（2）

| 提交 | 内容 |
|---|---|
| `75fc0ad1` | **AnyDoc 升级 0.2.4**：升级 + 资源（图片）单次解析；`third_party/anydoc-go` Rust 源码级升级（含 UPGRADE-0.2.4.md 与全套基准测试） |
| `5225edc0` (#3900) | 注册新增「仅限邀请」档位（tenant 级） |

### fix 按主题

| 主题 | 要点 | 命中我方？ |
|---|---|---|
| **Wiki 排水** | `4ba85e2e` follow-up 触发按剩余批次扇出（原来每周期只排 1 批，模型服务器闲置）；`c819abd9` 限制在途 follow-up 总量 | ★★ 我们 KB 开 wiki，解析积压排水直接提速 |
| **表格摘要** | `d270a844` 拒绝空模型响应；`d528d1fc` 跳过缺失文档；测试夹具合成化 | ★ 与我方 table_metadata 同链路 |
| **引用链路 (#3794)** | `9114e4e4` 原文定位校验（sourceloc 大改 + `internal/sourceloc/` 对齐算法重写）、高亮范围、**DocReader 启动失败恢复**（`docreader_failure.go`）；前端 53 文件大头在此 | ★ 问答引用/原文预览直接受益 |
| 关键词检索 | `e39043f3` LIKE/ILIKE 显式 ESCAPE——SQLite 无默认转义 ⇒ 含 `%`/`_` 关键词**静默 0 结果**；PG 默认反斜杠转义所以正常 | 我方用 PG 不受影响，但属"静默漏结果"类 |
| 数据源 ×7 | GitLab 下载体积上限(#3887)/按提交快照比增量、Notion 清空残留、飞书分页 token(#3770)、钉钉块级渲染丢内容(#3822)+跳过不静默、RSS 增量重试 | 未用连接器，无感 |
| 认证 | `2ec17746` 令牌写失败不再算登录成功、查询失败不再谎称已撤销；邀请制配套 | — |
| 稳定性 | compaction 流取消≠空摘要(`436d02fd`)、LLM 重试遵守 Retry-After(`cf079b8d`)、FAQ payload 清洗(`5bf2ae1c`)、chat 会话恢复清残留 KB scope(`bdad5eea`)、信号退出跑 ResourceCleaner(`ec0ca463`)、embed 400×2 | 常规 |
| **构建/部署** | `176aa0d0` sandbox 出真 arm64 镜像 + arm64 Cube 变体；`docker/Dockerfile.docreader` 尾部改 `ENTRYPOINT container_entrypoint`（ARM 加密指令探针，SIGILL 回落 OpenSSL）+ CMD 弃 uv 改直跑 venv python | 111 为 amd64 不受影响；官方开始正式支持 arm64 |
| 前端 | 模型复制名称改写修复(#3830)、样式 guard 路径、Windows npm 嵌套、host-sandbox secret 卡片文案 | 随副本同步 |

## 3. 二开影响评估

| 项 | 结果 |
|---|---|
| 合并 | 零冲突（`ec47f067`）；`Dockerfile.docreader` 交集命中但我方 diff（GH_PROXY 等 ARG）与官方改的 ENTRYPOINT/CMD 段不重叠，自动合并 |
| 完整性校验 | `comm -23` = 0，my-docker / my-frontend / my-docs / deploy / AGENTS.md 全在 |
| 编译 | exit=0 |
| 前端副本 | rsync 整体覆盖 53 文件；判据复核：diff -rq 仅剩 dist/node_modules 产物 2 条；package.json/lock 与官方逐字一致；跟踪数 866=866（dotfile 经 `git add -f`） |
| 例外 Dockerfile | **两个仍必要**：Dockerfile.app（RUSTUP/GH_PROXY/NPM/CARGO ARG）与 Dockerfile.docreader（GH_PROXY）均为国内构建硬需求；官方新增的 ENTRYPOINT 探针与我们改动无冲突 |
| 行号引用 | 官方本轮未动 Makefile / .env.example / docker-compose.yml 的既有引用区；`Dockerfile.docreader` 尾部行号变化仅影响尾部（我方引用均用符号定位） |

## 4. 部署判定（第 10 轮上线面）

| 改动 | 部署动作 | 依据 |
|---|---|---|
| 后端 Go 大量变更 | `push-app`（含 build-anydoc-lib 重产 Rust 静态库——**AnyDoc 0.2.4 升级必须重产**） | 消费方走宿主挂载 `.build/WeKnora` |
| 前端 53 文件 | `push-ui`（本地构建投递，免重启） | dist 外置 |
| docreader 源码 7 文件 | `push-reader`（同步+重启，秒级） | 依赖清单未变 ⇒ **不 build 镜像**；`container_entrypoint.py` 虽新增但属 ARM 探针，amd64 上旧入口行为等价 |
| 无新迁移 | app 重启不触发迁移；部署前核一次 cron 备份在跑即可 | migrations diff 为空 |

## 5. 连带发现

- `docs/` 三个存活文件（swagger 等）仍有小改；`website-docs/` 常规更新，无重构迁移。
- 官方给 anydoc 建了 `testdata/upstream/` 语料库与基准测试目录——后续我们调 docreader/分块可参考其基准口径。
- sandbox arm64 化：`Dockerfile.sandbox` 大改（72 行），我方未用 sandbox，不建。

## 6. 待办

- [ ] 部署三连：push-ui → push-app → push-reader（本文档提交后执行）
- [ ] 部署后核验：二进制 commit 注入、迁移 up to date、三 https 入口
- [ ] 审计 KB 全库重解析（child=608 + 新 Wiki 提示词）排期——本轮 AnyDoc 0.2.4 与 wiki 排水修复都会改善该次重解析

## 7. 证据

```
merge: ec47f067 ← bccb4b15 (v0.8.2-102, 36 commits, 252 files)
merge-tree 预演: 550ae3fc（单 tree OID = 零冲突）
go build exit=0；comm -23 = 0
前端: diff -rq = 2（仅产物）；package.json/lock 一致；跟踪 866=866
复制点: my-docker/README.md → bccb4b15
```
