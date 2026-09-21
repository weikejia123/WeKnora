# WeKnora 数据安全与备份方案

> 适用对象：南宁 `nanning-111`（10.168.1.111）单机部署
> 环境定位：**开发环境** + **正式知识库数据**（两个正交维度，见 §1.1）
>
> 本文是「备份与数据安全」话题的**唯一事实来源**。
> `02-本地部署与配置` 与 `03-生产部署与运维` 里的相关段落均**改为指向本文**，不再各自维护一份。

---

## 〇、结论速览

| 问题 | 结论 | 依据 |
|---|---|---|
| 数据库初始化后能运行中加字段/加表吗？ | **能**，且现状本来就是这样 | 109 个 up.sql 中 `ADD COLUMN` 出现在 66 个、`CREATE TABLE` 43 个 |
| 有没有"增量但危险"的操作要防？ | **有**：建索引会锁表 | `CREATE INDEX` **246 处不带 `CONCURRENTLY`**，涉及 `embeddings`/`chunks`/`knowledges` 等大表 |
| 备份用增量还是全量？ | **推荐全量** | 磁盘空间富裕恰恰是"不需要增量"的理由（§3.3） |
| 备份到同盘（`/mnt/data`）够不够？ | **不够**，只能防误操作 | 源与目标同在一块物理盘（§3.4） |
| 只备份数据库够不够？ | **不够** | `.env` 里的 `SYSTEM_AES_KEY` 丢失会让库内加密字段**静默失效**（§1.2） |

---

## 一、这个环境的数据是什么

### 1.1 先区分两个维度

| 维度 | 取值 | 含义 |
|---|---|---|
| **环境性质** | 开发环境 | 容器 / 镜像 / 编排**可以随便折腾**、随时重建 |
| **承载的数据** | 正式知识库数据 | **不能折腾**，且**丢了无法重建** |

这两件事必须分开讲。用"生产环境"一个词概括会同时引入两把互相冲突的尺子：
环境的诉求是**迭代速度**，数据的诉求是**不被开发动作误伤**。

**已核实的"环境可折腾"依据**：`deploy/deploy-wkj-dev.sh:571` 的 `cmd_down` 用 `$DC down`
（**不带 `-v`**），脚本第 23 行注释即写「停止容器（保留数据）」。

### 1.2 数据清单（按「丢了能不能重建」分级）

| 资产 | 实际位置 | 丢了能重建吗 |
|---|---|---|
| `weknora_postgres-data` 卷 | `/mnt/data/docker/volumes/` | ❌ **不能** —— 正式数据 |
| `weknora_data-files` 卷 | 同上 | ❌ **不能** —— 上传的原始文件 |
| **`.env`** | `/mnt/data/weknora/.env`（**gitignore 内**） | ❌ **不能** —— ★ 见下 |
| `weknora_docreader-tmp` 卷 | 同上 | ✅ 能 —— 临时解析产物 |
| `searxng_config` 卷 | 同上 | ✅ 能 —— 由 `docker/searxng/settings.yml` 模板重建 |
| 代码仓库 | `/mnt/data/weknora` | ✅ 能 —— git |
| `config/config.yaml` | 仓库内（受版本控制） | ✅ 能 —— git |
| TLS 证书 | `/mnt/data/weknora-tls` | ⚠️ 能重签，但客户端要重新导入 CA |

**★ 为什么 `.env` 被归为"数据"而不是"配置"**

`.env` 看起来像配置，但它是**解密数据库内容的钥匙**。`.env` 中已设置：

| 变量 | 作用 | 丢失后果 |
|---|---|---|
| `SYSTEM_AES_KEY`（`:546`） | 加密/解密**存库的敏感字段** | ★ 库还在，但**密文字段全部解不开** |
| `JWT_SECRET`（`:539`） | 登录会话签名 | 所有人需重新登录（影响可接受） |
| `SYSTEM_SIGNING_KEY`（`:549`） | 签名用途 | 待核实具体影响 |
| `DB_PASSWORD`（`:136`） | postgres 口令 | 可重置（库内已存凭据） |

被 `SYSTEM_AES_KEY` 保护的字段包括（均**密文存库**）：`web_search_provider.api_key`、
`tenant.api_principal_config.hmac_secret`、tenant 的 `app_secret`、`tenant_api_key.APIKey`。

**最危险的一点是它失败时是静默的**。`internal/types/web_search_provider.go:120-125`：

```go
if plain, ok := utils.DecryptStoredSecretLenient(p.APIKey); ok {
    p.APIKey = plain
} else {
    log.Printf("[crypto] ... treating as unconfigured")
    p.APIKey = ""          // ← 置空，不报错、不阻断
}
```

函数名里的 **`Lenient`** 就是"宽容"：解密失败**不抛错**，只置空 + 打一行日志。
`internal/types/tenant.go:916` 的注释也写明这类字段会被 "**blanked and logged**"。

⇒ **后果**：备份了数据库、却丢了 `.env`，恢复后服务**能正常启动、不报任何错**，
但所有依赖这些密钥的功能静默失效。**这类故障很难被察觉**。

⇒ **要求**：`.env` 必须与数据库**成对备份**。分开备份会造成"恢复了库但解不开密文"。

### 1.3 落盘位置（已核实）

`my-docs/03-生产部署/WeKnora-生产部署与运维.md:526`：

```
| Docker | 29.8.0，免 sudo 可用，`DockerRootDir=/mnt/data/docker` |
```

同文档 `:79` 补充：「Docker 存储 `/mnt/data/docker` + `/mnt/data/containerd`（**已迁至机械盘**）」。

⇒ 所有 named volume（含 postgres 数据、上传文件）与镜像层**都在 `/mnt/data` 这块 15T 机械盘上**。
`/`（857G）只承载系统。

> 该结论与"数据在系统盘"的直觉相反，故在此明确记录。
> 附带影响：机械盘 IO 较慢，是**构建耗时**（实测 15m57s）的次要成因之一（主因是国内网络源，见 `10-部署优化`）。

---

## 二、原则：数据库初始化后只做增量演进

### 2.1 现状与这条原则一致

| 环节 | 事实 |
|---|---|
| **初始化** | `migrations/paradedb/00-init-db.sql` —— 建扩展（`pg_search`/`vector`/`pg_trgm`/`uuid-ossp`）+ 建表 + 建索引 |
| 谁执行它 | **无任何脚本或代码引用**（仅 `internal/application/service/wiki_ingest.go:2307` 注释提到）⇒ **手工一次性执行** |
| 它幂等吗 | ✅ 通篇 `CREATE ... IF NOT EXISTS`，**无 `DROP`/`TRUNCATE`/`DELETE`** |
| 之后 | 109 个 `migrations/versioned/*.up.sql` 组成增量迁移链 |

⇒ **不存在"重复初始化"的自动化路径**。这条原则在当前实现里是成立的，要守住的是别引入它。

### 2.2 ★ 判据：什么算"运行时可做"

「加字段、加表可以在运行时处理」的判断**正确，但不完整**——它漏了一类
**"是增量、但会长时间阻塞"** 的操作。按 109 个 up.sql 实测分类：

| 操作 | 出现范围 | 运行时可做？ | 说明 |
|---|---|---|---|
| `ADD COLUMN`（可空或有默认） | 66 个文件 | ✅ **安全** | 仅改元数据，不重写表 |
| `CREATE TABLE` | 43 个文件 | ✅ **安全** | — |
| **`CREATE INDEX`（无 `CONCURRENTLY`）** | **246 处** | ⚠️ **锁表** | 建索引期间阻塞写（PG 中亦可能阻塞读） |
| `ALTER COLUMN`（改类型） | 10 个文件 | ⚠️ **重写表 + 强锁** | 大表上代价高 |
| `DROP COLUMN` | 4 个文件 | ❌ 破坏性 | 不可逆 |
| `DROP TABLE` | 1 个文件 | ❌ 破坏性 | 不可逆 |

**最需要警惕的是第三行**：246 处不带 `CONCURRENTLY` 的索引创建，且集中在**大表**上：

```
8 次 ON embeddings      （向量表，量最大）
6 次 ON knowledges
6 次 ON chunks
5 次 ON users / kb_shares / data_sources ...
```

**为什么官方不用 `CONCURRENTLY`**：`CREATE INDEX CONCURRENTLY` **不能在事务中执行**，
而 golang-migrate 默认把每个迁移包在事务里。所以这是一个**受迁移框架约束的妥协**，不是疏忽。

⇒ **它带来的实际风险**：`AUTO_MIGRATE` 默认开启（见 §2.3）时，
一次"重启容器"就可能触发大表建索引，**阻塞服务数十秒到数分钟，且事先没有任何提示**。

### 2.3 与本原则冲突的一处默认行为

`internal/container/container.go:886` —— **app 容器每次启动都跑 pending 迁移**：

| 事实 | 证据 |
|---|---|
| 默认开启 | `:875` `if os.Getenv("AUTO_MIGRATE") != "false"`；`.env.example:74` 写 `AUTO_MIGRATE=true` |
| **每次启动都跑**（不限于部署时） | 位于容器初始化路径，与部署脚本无关 |
| **失败不阻断** | `:887-892` 仅 `logger.Warnf`，随后 "Continuing with application startup" |
| **dirty 时自动回退重试** | `AUTO_RECOVER_DIRTY` 默认开（`:878` `!= "false"`）；`internal/database/migration.go:163-169` |
| 部署脚本不调用迁移 | `scripts/migrate.sh` 存在，但 `deploy-wkj-dev.sh` **从不引用** ⇒ 无显式关卡 |

**与"只做增量演进"的关系**：迁移内容本身是增量的（符合原则），
但**触发时机不可控、失败不阻断、dirty 还会自动重试**——这三点让"增量"变成**静默发生**的事。

尤其 `AUTO_RECOVER_DIRTY`：正常语义下"迁移失败留下 dirty"应停下等人查，
而这里是自动把版本号退回去重试。对非幂等迁移（如无 `IF NOT EXISTS` 的 `CREATE`），
会二次执行——**用"重试"掩盖"失败"，在正式数据上比直接报错更危险**。

**建议（待定，见 §5）**：把本轮要执行的迁移**先看清楚再放行**，
判据是「数据库当前版本号 vs 代码内最大迁移号」——两者不等即说明下次启动会跑迁移。

---

## 三、备份：增量还是全量

### 3.1 先澄清一个概念

**PostgreSQL 的逻辑备份（`pg_dump`）没有"增量"这个概念**——这是设计使然，不是工具能力问题。
所谓"增量备份"在 PG 里只能由**物理层**实现：

| 方式 | 增量粒度 | 前提条件 | 恢复复杂度 |
|---|---|---|---|
| **WAL 归档 + 基础备份**（PITR） | 事务级 | 改 `postgresql.conf`（`wal_level=replica`、`archive_mode=on`、`archive_command`）+ **重启 postgres** + `pg_basebackup` 打底 | **高** —— 按序重放，全链依赖 |
| **pgBackRest / Barman** | 块级差量 | 额外工具或容器 | 中 —— 工具代管 |
| **文件系统快照** | 块级 | `/mnt/data` 必须是 LVM / ZFS / Btrfs | 低，但依赖文件系统 |
| **`rsync --link-dest` 硬链接** | 逻辑全量、物理增量 | **必须先停库**（运行中直接拷 PG 数据文件会得到不一致副本） | 低（恢复即拷回） |

### 3.2 增量方案的隐藏成本

增量省的是**空间与时间**，付出的是**恢复链路的脆弱性**：

- 全量 dump = **一个文件**。坏了就换上一个版本的，恢复一条命令，且能用 `pg_restore -l` **当场验证内容**
- 增量/PITR = **基础备份 + 一串 WAL**。任何一环缺失或损坏，整条链恢复不了；
  且**必须演练过**才能确信它可用——**没演练过的备份等于没有备份**

### 3.3 ★ 反直觉的一点：空间富裕恰恰是"不需要增量"的理由

增量的核心价值是**省空间**。而这里：

- `/mnt/data` **15T**，当前 weknora 相关占用以镜像层为主（docreader 5.69GB + app 2.4GB + …），
  数据库与上传文件的实际量级**待实测**（见 §4）
- 按知识库场景估计，数据库在 **几百 MB 到数 GB** 量级
- ⇒ 即便每天一份全量、保留 **30 份**，占用也在**百 GB 量级**，相对 15T 完全宽裕

⇒ **没有空间压力，就没有采用增量方案的必要性**。
反过来，全量在这量级下是**分钟级甚至秒级**，也不构成时间痛点。

**结论：用全量。** 把复杂度预算留给真正需要的地方（异地副本、恢复演练）。

### 3.4 ★ 同盘备份的盲区

现有文档建议的备份目标是 `/mnt/data/backups/weknora`（`03-生产部署/…:221`），
而**数据源也在 `/mnt/data`**（§1.3）。

| 要防的风险 | 同盘备份能否覆盖 |
|---|---|
| 误操作（误删卷、迁移改坏数据、误改 schema） | ✅ **能** —— 这是**最常见的恢复场景** |
| 硬件故障（盘坏、文件系统损坏） | ❌ **完全不能** —— 源与备份同时消失 |

⇒ 同盘备份**有价值**（覆盖高频场景），但**不等于备份完成**。
真正的容灾必须把副本放到**另一块物理设备**上。

### 3.5 推荐方案（分两层，各司其职）

| 层 | 目标 | 内容 | 保留策略 |
|---|---|---|---|
| **① 本地快速恢复点** | 防误操作 | `pg_dump -Fc`（数据库）+ `data-files` 卷归档 + **`.env`** | 轮转，保留 N 份（空间宽裕，可留多） |
| **② 异地副本** | 防硬件故障 | ①的产物复制到另一台设备 | 保留较少份数 |

**第 ① 层要点**：

- **`.env` 必须进备份集**（§1.2）——否则库恢复了也解不开密文
- 必须覆盖 **`data-files` 卷**（上传的原始文件），它可能比数据库还大
- dump 用 `-Fc`（自定义格式，内置压缩，且支持选择性恢复）
- **放在动 `app` 之前**（因为重启即触发迁移，见 §2.3）
- 应做成**脚本**而非文档里要手工敲的命令——靠自觉必然漏

**第 ② 层的目标位置待定**（见 §5），取决于哪台设备可用、剩余空间多少。

### 3.6 参考实现（在 111 上执行）

```bash
ssh nanning-111 'bash -s' <<'EOF'
set -e
cd /mnt/data/weknora
TS=$(date +%Y%m%d-%H%M%S); DEST=/mnt/data/backups/weknora/$TS
mkdir -p "$DEST"
DBPW=$(grep -m1 '^DB_PASSWORD=' .env | cut -d= -f2-)

# 1) 数据库：-Fc 自定义格式（内置压缩，且支持选择性恢复）
docker exec -e PGPASSWORD="$DBPW" WeKnora-postgres \
  pg_dump -U postgres -d WeKnora -Fc > "$DEST/db.dump"

# 2) ★ .env：密钥。缺它则库内密文字段静默失效（§1.2）
cp .env "$DEST/env.backup"

# 3) 上传的原始文件。复用运行中的 app 容器，不额外拉镜像
docker exec WeKnora-app tar czf - -C /data/files . > "$DEST/data-files.tar.gz"

echo "备份完成：$DEST"; ls -lh "$DEST"
EOF
```

**不恢复也能验证 dump**（这一步很重要——未验证的备份不算备份）：

```bash
ssh nanning-111 'docker exec -i WeKnora-postgres pg_restore -l' < db.dump | head -30
```

**恢复顺序**（缺一不可）：① 恢复 `.env` → ② 起 postgres → ③ `pg_restore` 入库 →
④ 解回 `data-files` → ⑤ 起 app。
**顺序反了会出问题**：`.env` 里的密钥决定库内密文字段能否解开，而 app 启动就会读取它们。

---

## 四、待验证的前提

以下三项决定方案的具体参数，**尚未实测**（不擅自探测服务器）：

| # | 待验证项 | 为什么重要 | 验证命令（需授权在 111 执行） |
|---|---|---|---|
| 1 | **数据库与上传文件的实际体积** | 决定全量耗时与保留份数 | `docker exec WeKnora-postgres psql -U postgres -d WeKnora -c "SELECT pg_size_pretty(pg_database_size('WeKnora'))"`<br>`du -sh /mnt/data/docker/volumes/weknora_data-files` |
| 2 | **`pg_dump` 在该镜像中的可用性与 ParadeDB 兼容性** | 镜像是 `paradedb/paradedb:v0.22.6-pg17`，非纯官方 PG；BM25/HNSW 等特殊索引的 dump/restore 行为需实测 | `docker exec WeKnora-postgres pg_dump --version`<br>小库上做一次 dump → 空库 restore 验证 |
| 3 | **恢复演练** | 未演练的备份不算备份 | 在临时库上 restore 一次 dump，比对表数量与关键行数 |

**关于第 2 项的已知约束**：ParadeDB 的 BM25 索引与 pgvector 的 HNSW 索引都是**扩展提供的特殊索引**。
恢复端必须**先有匹配版本的扩展**（`pg_search` 当前为 `0.22.6`，与镜像 tag 对应），
否则 `pg_restore` 会在建索引阶段失败。迁移链里已有版本升级的防御逻辑
（`migrations/versioned/000099_pg_search_0226.up.sql`：仅在已装 0.22.2–0.22.5 且镜像提供 0.22.6 时升级，
否则 `RAISE NOTICE` 交人工处理）——**恢复流程应与之一致：版本不匹配时不自动降级**。

---

## 五、待决策

| # | 事项 | 选项 | 备注 |
|---|---|---|---|
| 1 | 异地副本的目标设备 | 待定（110？NAS？本机？） | 决定方案第 ② 层能否成立 |
| 2 | 备份脚本的形态 | A. `scripts/backup-weknora.sh`（独立）<br>B. `deploy-wkj-dev.sh` 加 `backup` 子命令 | B 更容易与"动 app 前自动触发"绑定 |
| 3 | 是否在 `build` / 动 `app` 前**自动**触发备份 | 是 / 否 | 若否，则依赖纪律 |
| 4 | 迁移控制权（§2.3） | A. 保持 `AUTO_MIGRATE=true` + 重启后查日志<br>B. 改 `false` + 显式迁移 ⇒ 重启不再意外改 schema | B 让"重启容器"重新变回安全动作 |
| 5 | `AUTO_RECOVER_DIRTY` | A. 保持默认开（自动重试）<br>B. 设 `false`，让 dirty 成为**显式失败** | 涉及正式数据，建议偏 B |

---

## 六、证据清单

| 结论 | 证据 |
|---|---|
| 环境可随便重建 | `deploy/deploy-wkj-dev.sh:571`（`$DC down`，无 `-v`）、`:23` 注释 |
| 数据在机械盘 | `my-docs/03-生产部署/…:526`（`DockerRootDir=/mnt/data/docker`）、`:79`（"已迁至机械盘"） |
| 三个数据卷 | `docker-compose.yml:1032-1035`；`my-docs/02-…:83` |
| 自动迁移每次启动都跑 | `internal/container/container.go:875`、`:886` |
| 迁移失败不阻断 | `internal/container/container.go:887-892` |
| dirty 自动恢复 | `internal/database/migration.go:163-169`；`container.go:878` |
| 部署脚本不调迁移 | `deploy/deploy-wkj-dev.sh` 无 `migrate` 引用 |
| 初始化脚本一次性且幂等 | `migrations/paradedb/00-init-db.sql`（无 `DROP`/`TRUNCATE`；无脚本引用） |
| 索引锁表风险 | `migrations/versioned/*.up.sql` 中 `CREATE INDEX` 246 处无 `CONCURRENTLY` |
| 密钥静默失效 | `internal/types/web_search_provider.go:120-125`；`internal/types/tenant.go:916` |
| 密钥清单 | `.env:136`（DB_PASSWORD）、`:539`（JWT_SECRET）、`:546`（SYSTEM_AES_KEY）、`:549`（SYSTEM_SIGNING_KEY） |
| `.env` 不在版本控制 | `git check-ignore -v .env` → `.gitignore:2:.*` |
