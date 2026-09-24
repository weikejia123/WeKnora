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
| 备份用增量还是全量？ | **全量**（已定） | 磁盘空间富裕恰恰是"不需要增量"的理由（§3.3） |
| 最终采用什么方案？ | 全量 · **每天 06:00** · 本地专属目录 · **保留 10 份** | §3.5 |
| 落地了吗？ | ✅ **已上线**（2026-09-21 23:29 首次备份成功）；✅ **恢复演练已完成**（2026-09-22，全项一致） | §3.6.1、§4.2 |
| 备份到同盘（`/mnt/data`）够不够？ | **够防误操作，不防硬件故障**（已明确接受） | 源与目标同在一块物理盘（§3.4） |
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
| `searxng_config` 卷 | 同上 | ✅ 能 —— 由 **`my-docker/searxng/settings.yml`**（站点定制，经 `searxng-init` 投递）重建 |
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

### 3.5 已定方案（老魏 2026-09-21 定）

| 项 | 决定 |
|---|---|
| 方式 | **全量**（不用增量，理由见 §3.3） |
| 范围 | 数据库 + `data-files` 卷 + **`.env`** |
| 落点 | **本地机械盘专属目录** `/mnt/data/backups/weknora/` —— **不做异地副本** |
| 频率 | **每天 06:00 一次** |
| 保留 | **最近 10 份** |
| 实现 | `my-scripts/backup-weknora.sh`（随代码经 git 同步到 111） |

**明确接受的边界**（不再讨论）：

- **不做异地副本** ⇒ 本方案只防**误操作**（误删、迁移改坏、schema 被改），
  **不防硬件故障** —— `/mnt/data` 那块盘坏掉时源与备份同失（§3.4）。
- **保留 10 份** ⇒ 可回退窗口是**最近 10 天**。更早的误操作无法回退。
- **`.env` 必须进备份集**（§1.2）——否则库恢复了也解不开密文。

### 3.5.1 文件卷：为何最终用 tar（而非硬链接快照）

**原设计**用 `rsync --link-dest` 硬链接快照（为大卷优化：每份视图完整、占用接近增量）。
**实测后放弃**，两条理由：

| # | 理由 | 实测依据（2026-09-21） |
|---|---|---|
| 1 | **数据量极小** | `data-files` 卷 **568K**、数据库 **32MB**；每天全量 ×10 份也不过数百 MB，而磁盘剩余 **14.6T** ⇒ 硬链接的复杂度换不来收益 |
| 2 | **宿主路径不可读** | `/mnt/data/docker/volumes/` 对 ssh 用户**无权限** ⇒ 必须经容器访问；而 app 容器内**没有 `rsync`**（只有 `tar`）⇒ 宿主侧 rsync 方案直接出局 |

⇒ 最终用 `docker exec WeKnora-app tar czf`：简单、可靠、可校验。

> **附**：硬链接方案的轮转安全性此前已用最小复现验证（未变文件 inode 相同、
> 删最旧一份后其余快照仍可读、3 份/KEEP=2 的轮转正确）。该验证并非白做 ——
> 它正是"可以安全地不用它"的判断依据。留此记录以免后人重走一遍。

### 3.6 实现与安装

| 项 | 值 |
|---|---|
| 脚本 | `my-scripts/backup-weknora.sh` → 111 上为 `/mnt/data/weknora/my-scripts/backup-weknora.sh` |
| 用法 | 无参数=执行一次；`--dry-run`=预演；`--status`=查最近成功备份 |
| 日志 | `/mnt/data/backups/weknora/backup.log` |
| 成功标记 | `/mnt/data/backups/weknora/.last-success` |

脚本内建的保护（都是"避免静默失败"的设计）：

| 保护 | 作用 |
|---|---|
| 前置检查 | 仓库 / `.env` / **容器在跑** / **卷存在** / 空间，任一缺失即中止 ⇒ **不产生半个备份** |
| 空间预检 | 剩余 `< MIN_FREE_GB`（默认 20G）中止 ⇒ 避免写满盘 |
| 并发锁 | `flock`，上次未跑完则跳过 ⇒ 不叠加 |
| **dump 当场校验** | `pg_restore -l` 能读才算成功 ⇒ **未验证的备份不算备份** |
| **tar 当场校验** | `tar tzf` 能列才算成功 |

每份快照还带一个 **`meta.txt`**（迁移版本 / 代码提交 / 体积 / 恢复顺序），
使备份**自描述** —— 恢复时不必猜"这是哪一版状态"。迁移版本尤其关键：它决定该配哪一版代码。

**定时任务**（在 111 上 `crontab -e` 追加一行）：

```cron
0 6 * * * /mnt/data/weknora/my-scripts/backup-weknora.sh >/dev/null 2>&1
```

> 脚本自己写 `backup.log`，故 cron 侧的输出丢弃即可。
> ⚠️ 111 上已存在**其他项目的 cron 条目**（北京政策分析），安装时**必须追加而非覆盖**。
> 幂等的追加写法（重复执行不会产生第二条）：
>
> ```bash
> ( crontab -l 2>/dev/null | grep -v "backup-weknora.sh"
>   echo "# WeKnora 数据备份（backup-weknora.sh）：每天 06:00，保留最近 10 份"
>   echo "0 6 * * * /mnt/data/weknora/my-scripts/backup-weknora.sh >/dev/null 2>&1" ) | crontab -
> ```

**健康检查**（确认备份真的在跑，而不是静默停了）：

```bash
ssh nanning-111 '/mnt/data/weknora/my-scripts/backup-weknora.sh --status'
```

### 3.6.1 安装记录（2026-09-21 23:29，已完成）

| 步骤 | 结果 |
|---|---|
| 代码同步到 111 | 用新加的 `deploy-wkj-dev.sh sync`（**不碰容器**，故不触发迁移）→ 111 至 `3ac90e3a` |
| dry-run 前置检查 | ✅ 通过（剩余空间 14651G） |
| **首次真实备份** | ✅ **6 秒完成**，产物 3.3M（`db.dump` 2.8M / `data-files.tar.gz` 436K / `env.backup` 44K / `meta.txt`） |
| cron 安装 | ✅ 追加到 111（原「北京政策分析」条目保留），`cron` 服务 `active`；重复安装幂等已验证 |
| 快照 | `/mnt/data/backups/weknora/20260921-232928/` |

**★ 同时确认了一件重要的事**：`db.dump` 里**包含** ParadeDB / pgvector 的特殊索引定义 ——
`USING bm25`（1 条，`embeddings_search_idx`，含 `key_field` 与中文分词配置）、
`USING hnsw`（3 条，1024/3584/798 维）、以及
`CREATE EXTENSION IF NOT EXISTS pg_search WITH SCHEMA paradedb;`。
⇒ **恢复时这些索引会随 dump 一起重建**，不需手工补建。
（残余风险：恢复端须有**匹配版本**的 `pg_search` 扩展 —— 同镜像内成立，换镜像时需留意。）

**恢复顺序**（缺一不可）：① 恢复 `.env` → ② 起 postgres → ③ `pg_restore` 入库 →
④ 解回 `data-files` → ⑤ 起 app。
**顺序反了会出问题**：`.env` 里的密钥决定库内密文字段能否解开，而 app 启动就会读取它们。

---

## 四、验证状态

### 4.1 已实测（2026-09-21）

| 项 | 实测结果 |
|---|---|
| 数据库体积 | **32 MB** |
| 文件卷 `data-files` 体积 | **568 K** |
| 磁盘剩余 | **14.6 T** ⇒ 全量 ×10 份毫无压力（这正是"不需要增量"的实证） |
| 迁移版本（实测当时） | `106`，`dirty=f`（干净）—— **2026-09-22 已到 `108`**（本地 migrations 最新号也是 108 ⇒ 重跑 app 不会执行迁移） |
| `pg_dump` / `pg_restore` 在 `paradedb/paradedb:v0.22.6-pg17` 中可用 | ✅ dump 2.8M，`pg_restore -l` 可解析 |
| **特殊索引是否在 dump 中** | ✅ 含 `USING bm25` ×1、`USING hnsw` ×3、`CREATE EXTENSION pg_search WITH SCHEMA paradedb` |

⇒ 结论：**dump 内容正确** —— 恢复时 BM25 / HNSW 索引会随 dump 一起重建，不需手工补建。

### 4.2 ✔ 恢复演练（2026-09-22 完成）

**"未演练的备份不算备份"—— 本轮已补上。** 全程在**临时库**上做，绝不碰正式数据。

做法：建 `weknora_restore_drill` → `pg_restore` 导入最新快照的 `db.dump` → 逐项比对 → 删除临时库。

**结果**（快照 `20260922-000326`，即 app 外置完成后的那一份）：

| # | 检查项 | 结果 |
|---|---|---|
| 1 | `pg_restore` 导入 | ✅ **7 秒**；3 个 error 全是 `schema paradedb / tiger / topology already exists`（实例级扩展自带，**良性**） |
| 2 | 表数量 | 源库 **78** = 恢复库 **78** |
| 3 | 关键表行数 | knowledges 5/5 · chunks 136/136 · embeddings 204/204 · tenants 2/2 · users 2/2 · knowledge_bases 3/3 …… **9 张表全部一致** |
| 4 | 迁移版本 | 源库 `108\|false` = 恢复库 `108\|false` |
| 5 | 特殊索引 | **1×bm25 + 3×hnsw 全部随 dump 重建** |
| 6 | 扩展 | 11 个（含 `pg_search` / `vector` / `postgis`）**完全一致** |
| 7 | 内容抽查 | 能读出真实记录（"财政部关于加强中央部门科研和基建项目结转结余资金管理有关事项的通知"） |
| 8 | **BM25 功能可用** | 关掉顺序扫描后走 `Custom Scan (ParadeDB Base Scan)` + `Index: embeddings_search_idx`；中文分词（`chinese_lindera`）搜索"财政"**命中 15 行** |
| 9 | 向量索引 | ⚠️ 走 `Seq Scan` —— 查明**不是恢复问题**，而是缺 2560 维索引（见 `13-检索性能与索引/`） |
| 10 | `.env` | 备份集 `env.backup` 与现场 `.env` **逐字节一致**（sha256 相同）；`SYSTEM_AES_KEY` / `JWT_SECRET` / `SYSTEM_SIGNING_KEY` / `DB_PASSWORD` **四项全同** |
| 11 | 文件卷 | 备份 tar 内 **6 个文件** = 源卷（容器视角）**6 个文件** |
| 12 | 清理与自证 | `DROP DATABASE weknora_restore_drill`；正式库回到基线（78 表 / `108\|false` / 5·136·204），postgres 容器**从未重启** |

**★ 索引可用性的验证方法（可复用）**：仅看"索引是否存在"是不够的 ——
表小的时候优化器会主动选 Seq Scan。正确做法是
`SET enable_seqscan=off` 后看 `EXPLAIN` 是否真的用上索引（本次 BM25 用此法证成、向量用此法证伪）。

**★ 关于 `.env` 的"解密能力"验证口径**：没有另起一套 app 做端到端解密，
而是用**演绎等价的判据** —— `SYSTEM_AES_KEY` 逐字节一致，而解密只依赖
「密钥 + 代码中的算法」两个要素，算法随代码在 git 中
⇒ **key 相同，则对同一密文的解密结果必然相同**。

**仍未做**：用备份集**重建一个在线服务**。这属于灾难恢复 SOP 演练（涉及端口、模型密钥等
部署侧资源），与"备份集内容是否有效"是两个问题 —— 后者本轮已闭合。

**已知约束（恢复端须满足）**：BM25 索引与 HNSW 索引由**扩展提供** ⇒ 恢复端必须先有
**匹配版本**的扩展（`pg_search` 现为 `0.22.6`，与镜像 tag 对应），
否则 `pg_restore` 会在建索引阶段失败。迁移链里已有同类防御逻辑
（`migrations/versioned/000099_pg_search_0226.up.sql`：仅在已装 0.22.2–0.22.5 且镜像提供 0.22.6 时升级，
否则 `RAISE NOTICE` 交人工处理）—— **恢复流程应与之一致：版本不匹配时不自动降级**。

> ⚠️ 本次演练是在**同一个 postgres 容器**（同镜像）里做的 ⇒ 扩展版本天然匹配，
> **这条约束并未被真正考验**。跨镜像 / 跨版本恢复时，它是第一道要检查的门槛。

---

## 五、决策状态

### 5.1 已定（老魏 2026-09-21）

| # | 事项 | 决定 |
|---|---|---|
| 1 | 备份方式 | **全量**（理由见 §3.3） |
| 2 | 落点 | **本地机械盘专属目录** `/mnt/data/backups/weknora/`；**不做异地副本** |
| 3 | 频率 | **每天 06:00** |
| 4 | 保留份数 | **最近 10 份** |
| 5 | 实现形态 | 独立脚本 `my-scripts/backup-weknora.sh`（**不用**官方 `scripts/`） |

### 5.2 仍待决

| # | 事项 | 选项 | 说明 |
|---|---|---|---|
| 6 | 是否在动 `app` 前**自动**触发一次备份 | 是 / 否 | 若否，则依赖"记得"——而重启 app 会触发迁移（§2.3） |
| 7 | 迁移控制权（§2.3） | A. 保持 `AUTO_MIGRATE=true` + 重启后查日志<br>B. 改 `false` + 显式迁移 | B 让"重启容器"重新变回安全动作 |
| 8 | `AUTO_RECOVER_DIRTY`（§2.3） | A. 保持默认开（dirty 时自动重试）<br>B. 设 `false`，让 dirty 成为**显式失败** | 涉及正式数据，建议偏 B |

### 5.3 已完成 / 未完成（在 111 上）

| # | 事项 | 状态 |
|---|---|---|
| 9 | 代码同步到 111（经 `sync` 子命令，不碰容器） | ✅ 已完成（111 至 `3ac90e3a`） |
| 10 | **安装 cron** + 跑一次真实备份 | ✅ 已完成（2026-09-21 23:29，首次备份 6 秒 / 3.3M） |
| 11 | 数据体积、`pg_dump` 兼容性 | ✅ 已实测（§4.1） |
| 12 | **恢复演练** | ✅ **已完成（2026-09-22）** —— 临时库全项一致，正式库未受影响（§4.2） |

---

## 六、证据清单

| 结论 | 证据 |
|---|---|
| 环境可随便重建 | `deploy/deploy-wkj-dev.sh:571`（`$DC down`，无 `-v`）、`:23` 注释 |
| 数据在机械盘 | `my-docs/03-生产部署/…:526`（`DockerRootDir=/mnt/data/docker`）、`:79`（"已迁至机械盘"） |
| 三个数据卷 | `docker-compose.yml` 顶层 `volumes:` 段（本版起于 :1038）；`my-docs/02-…:83` |
| 自动迁移每次启动都跑 | `internal/container/container.go:875`、`:886` |
| 迁移失败不阻断 | `internal/container/container.go:887-892` |
| dirty 自动恢复 | `internal/database/migration.go:163-169`；`container.go:878` |
| 部署脚本不调迁移 | `deploy/deploy-wkj-dev.sh` 无 `migrate` 引用 |
| 初始化脚本一次性且幂等 | `migrations/paradedb/00-init-db.sql`（无 `DROP`/`TRUNCATE`；无脚本引用） |
| 索引锁表风险 | `migrations/versioned/*.up.sql` 中 `CREATE INDEX` 246 处无 `CONCURRENTLY` |
| 密钥静默失效 | `internal/types/web_search_provider.go:120-125`；`internal/types/tenant.go:916` |
| 密钥清单 | `.env:136`（DB_PASSWORD）、`:539`（JWT_SECRET）、`:546`（SYSTEM_AES_KEY）、`:549`（SYSTEM_SIGNING_KEY） |
| `.env` 不在版本控制 | `git check-ignore -v .env` → `.gitignore:2:.*` |
