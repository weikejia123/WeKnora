# WeKnora 向量索引的维度覆盖缺口

> 发现于 2026-09-22 的**备份恢复演练**（副产品，与恢复本身无关）：
> 演练中要证"恢复后的索引真能用"，结果发现 —— **当前使用的 embedding 模型维度（2560）
> 根本没有 hnsw 索引**，向量检索一直在走全表扫描。

---

## 一、现象

在恢复库上验证索引可用性时，向量查询走顺序扫描：

```
->  Seq Scan on embeddings  (cost=...)
```

关键是：`SET enable_seqscan=off` **之后仍然是 Seq Scan**。
⇒ 这不是"优化器选了顺序扫描"，而是**没有可用的索引**（否则会被强制使用）。

> 注：BM25 那条对照项在同样条件下走的是
> `Custom Scan (ParadeDB Base Scan)` + `Index: embeddings_search_idx`
> ⇒ 说明验证方法本身有效，只有向量这一路缺索引。

---

## 二、机制：pgvector 要求索引表达式与查询表达式**精确匹配**

| 环节 | 事实 |
|---|---|
| 索引定义 | `USING hnsw ((embedding::halfvec(N)) halfvec_cosine_ops) WHERE (dimension = N)` —— **部分索引 + 表达式索引** |
| 查询写法 | `embedding::halfvec(%[1]d) <=> $1::halfvec(%[1]d)`（维度由参数拼入） |
| 匹配规则 | `ORDER BY` 表达式必须与索引表达式**完全一致**，否则回退顺序扫描 |

依据：`internal/application/repository/retriever/postgres/repository.go:361-372`
—— 该段注释明确写着这个 cast "is NOT redundant — it is the only way to make the HNSW
index get used at all"，并援引 pgvector issues #702 / #835。

⇒ **查询侧是按维度动态拼的**（`%[1]d`）⇒ 只要**存在**对应维度的索引就能自动命中。
缺的不是查询逻辑，是索引本身。

---

## 三、官方覆盖的维度 vs 实际使用的维度

官方预置的 hnsw 索引**只有 3 个维度**：

| 维度 | 定义位置 |
|---|---|
| 3584 | `migrations/paradedb/00-init-db.sql:217`、`migrations/versioned/000002_embeddings.up.sql:60` |
| 798 | `migrations/paradedb/00-init-db.sql:218`、`migrations/versioned/000002_embeddings.up.sql:70` |
| 1024 | `migrations/versioned/000059_embeddings_hnsw_1024.up.sql:35`（**后补的**，该文件注释即写"避免 1024 维时的顺序扫描"） |

**实际使用**：111 上 `embeddings.dimension` 的取值分布 = **`2560` → 204 行**（2026-09-22 实测）。

2560 来自所选模型：`internal/models/vendors/siliconflow/models.json:23`
—— `Qwen/Qwen3-Embedding-4B`，`"dimension": 2560`。

⇒ **上游的维度白名单与我们的模型选择不匹配。**

**已排除"应用会按需建索引"**：全仓 `internal/**/*.go` 无任何 `CREATE INDEX` / `USING hnsw`
（唯一命中是 `internal/database/migration_postgres_test.go:48` 的注释）
⇒ 不存在的索引不会被自动补上。

---

## 四、影响

| 维度 | 影响 |
|---|---|
| **正确性** | **无** —— 顺序扫描的结果是对的，只是慢 |
| **性能** | 随 `embeddings` 行数**线性**劣化（HNSW 是对数级）。当前 204 行，无可感差异 |
| 何时成为问题 | 知识库规模上去之后，向量检索会拖慢整条 RAG 链路 |

---

## 五、修法（与官方 000059 同构）

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS embeddings_embedding_idx_2560
  ON embeddings USING hnsw ((embedding::halfvec(2560)) halfvec_cosine_ops)
  WITH (m = 16, ef_construction = 64)
  WHERE (dimension = 2560);
```

`CONCURRENTLY` 在这里**可用**（手工执行、不在事务内）——
官方迁移里不用它是因为 golang-migrate 会把每个迁移包进事务
（原因见 `11-数据安全与备份/…` §2.2）。

---

## 六、待决：这个变更放哪个载体

⚠️ **不能**往 `migrations/versioned/` 加一个 `000109_*.up.sql` ——
`AGENTS.md` 第 1 条：官方文件不得修改，**新增文件也不要放进官方目录**。

| 方案 | 说明 |
|---|---|
| **A.** `my-scripts/` 放幂等 SQL，由部署脚本按需执行 | 与 `backup-weknora.sh` 同模式；可重复执行、可审计 |
| **B.** 手工一次性执行，并在本文件记录 | 最简；但环境重建后需记得重做 |
| **C.** 暂不处理，仅登记为已知事项 | 当前数据量下无实际影响 |

（待定 —— 涉及"变更放哪"的载体规约，需老魏拍板。）

---

## 七、证据清单

| 结论 | 证据 |
|---|---|
| 向量查询未走索引 | 恢复库上 `SET enable_seqscan=off` 后仍为 `Seq Scan on embeddings` |
| 源库恢复库行为一致（非恢复引入） | 同一条 EXPLAIN 在两库输出的计划结构相同 |
| 索引是表达式 + 部分索引 | `pg_indexes.indexdef`：`((embedding)::halfvec(1024)) halfvec_cosine_ops … WHERE (dimension = 1024)` |
| 官方只建 3 个维度 | 见 §三 表格中的 5 处文件:行号 |
| 实际维度为 2560 | `SELECT dimension, count(*) FROM embeddings GROUP BY 1` ⇒ `2560 → 204` |
| 无动态建索引逻辑 | 全仓 grep `CREATE INDEX` / `USING hnsw`（`internal/**/*.go`）无实现，仅测试注释 |
| 查询按维度动态拼 | `repository.go:377-393` 的 `fmt.Sprintf` 模板用 `%[1]d` |
