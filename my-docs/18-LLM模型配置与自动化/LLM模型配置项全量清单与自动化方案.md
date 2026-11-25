# 南宁 111 · LLM 模型配置项全量清单与自动化配置方案

> 生成于 2026-11-04，数据经**全库反查**验证（用当时存在的 3 个模型 UUID 扫描 WeKnora 库所有
> varchar/text/jsonb 列），不是仅凭代码推断。LiteLLM 条目清单与 graphiti/hindsight 的 env
> 为当日实测值，**易变信息以当场复核为准**。
>
> 用途：手动添加新模型（上游 + LiteLLM + WeKnora 模型管理页）后，由 Agent 按本文档把
> 各处引用自动化地配置/切换过去。

---

## 1. 模型接入链路（手动前置步骤，自动化从这里之后接管）

一个"可用的新模型"需要三层就位，顺序不可颠倒：

| 层 | 位置 | 手动做什么 |
|---|---|---|
| ① 上游 | 121 的 llama.cpp 实例（10081/10083/…） | 载入模型、定槽位数（`-np`） |
| ② 网关 | 111 `/mnt/data/litellm-langfuse/litellm/config.yaml` | 加条目：`model_name` → 上游 `api_base` + `api_key`(env 引用) + `timeout: 600` + `num_retries: 0`（少槽下禁重试放大），然后 `docker restart ll-litellm` |
| ③ WeKnora | 模型管理页（或 API） | provider=generic；**name 必须精确等于 LiteLLM 的 model_name**；base_url=`http://10.168.1.111:23010/v1`；api_key=LiteLLM 调用 key |

⚠️ WeKnora 模型行的 `name` 就是发给网关的模型 ID，拼写错 = 全部调用 404。

LiteLLM 现有条目名（截至 2026-11-04）：`bge-m3` · `bge-reranker-v2-m3` · `deepseek-flash` ·
`deepseek-v4.1-flash-ud-iq3s-gpu3` · `embeddinggemma-2-gpu1` · `glm-4.7-flash-gpu2` ·
`kimi-k3.1-pro-api` · `minicpm-v-4.7-35b-a3b-gpu2` · `qwen3.8-27b-ud-q4xl-gpu2` ·
`qwen3.8-27b-uncensored-q4km` · `qwen3-reranker-4b-gpu1` · `spark-x2.6-4b-gpu2`

---

## 2. WeKnora 配置项全量清单（库：WeKnora 库，容器 WeKnora-postgres）

### 2.1 知识库级 —— `knowledge_bases` 表（10 个配置位）

| # | 配置位 | 用途 | 当日有值行数 | 删除模型校验是否覆盖 |
|---|---|---|---|---|
| 1 | `embedding_model_id` | 向量检索 | 15 | ✓ |
| 2 | `summary_model_id` | 文档摘要 | 12 | ✓ |
| 3 | `vlm_config->>'model_id'` | 图片理解 | 9 | ✓ |
| 4 | `wiki_config->>'synthesis_model_id'` | Wiki 合成 | 9 | ✓ |
| 5 | `auto_tag_config->>'model_id'` | 自动打标 | 9 | ✓ |
| 6 | **`profile_config->>'model_id'`** | KB 画像生成 | 9 | **✗ 校验不查！删模型前必须手动查** |
| 7 | `image_processing_config->>'model_id'` | 图片处理 | 0（空） | ✓ |
| 8 | `asr_config->>'model_id'` | 语音转写 | 0（空） | ✓ |
| 9 | `question_generation_config->>'model_id'` | 问题生成 | 0（空） | ✓ |
| 10 | `extract_config` / `faq_config` | 仅 enabled 开关 / 空 | — | 无模型键 |

> ⚠️ 第 6 项（profile_config）是代码删除校验（`model_usage.go` 的 8 字段口径）之外的
> 漏网配置位——UI 删除模型不拦它，换模型时却必须一起切，否则画像生成静默指向已删模型。

### 2.2 Agent 级 —— `custom_agents.config`（JSONB，6 个键）

`model_id` · `rerank_model_id` · `vlm_model_id` · `asr_model_id` ·
`query_understand_model_id` · `question_suggestions.follow_ups.model_id`
（当日 2 个 agent 有引用）

### 2.3 租户级 —— `tenants`（2 个 JSONB）

| 配置位 | 键 | 说明 |
|---|---|---|
| `memory_config` | `extract_model_id` | 长期记忆提取（LLM） |
| `memory_config` | `embedding_model_id` | 长期记忆向量化 |
| `chat_history_config` | `embedding_model_id` | 聊天历史召回（当日 1 行） |

### 2.4 其他结构位（存在、当前为空，自动化脚本仍应覆盖）

- `automations.model_id`（当日 0 行有值）
- `sessions.agent_config` / `sessions.summary_model_id` / `rerank_model_id`：
  **会话是 agent 的派生物**（创建时快照），不作为配置源；改 agent 后旧会话仍是旧值，属预期行为。

### 2.5 全局与模型自身参数

| 项 | 位置 | 当日值 |
|---|---|---|
| 后台调用全局并发兜底 | `system_settings` 表 key=`model.max_concurrency` | 2 |
| 模型自身并发上限 | `models.parameters->>'max_concurrency'`（0=回退全局） | qwen3.8=3 |
| 思考模式 | generic 模型**不发送任何思考参数**，由上游模板默认决定（Qwen3 默认开，实测关思考会答错 8.11 vs 8.9） | 不动 |

### 2.6 只读的运行时产物（不要当配置改，但换 embedding 模型时必须知道）

- `knowledges.embedding_model_id`（184 行）：每条知识入库时的向量模型快照。
  **换 embedding 模型 = 新旧向量空间不兼容**，必须重新入库或重嵌，不能只改 KB 的引用。
- `memory_item_embeddings.model_id`：同上，记忆向量。
- `messages.model_id` / `message_suggestion_sets.model_id` / `task_dead_letters` /
  `knowledge_processing_spans`：历史记录与日志，与配置无关。

---

## 3. WeKnora 之外的 LLM 消费者（111 上，都指向 LiteLLM :23010）

| 服务 | 配置方式 | 当日引用的模型 | 改动生效方式 |
|---|---|---|---|
| graphiti-app（知识图谱） | 容器 env：`MODEL_NAME` / `EMBEDDING_MODEL_NAME` / `OPENAI_BASE_URL` | `qwen3.8-27b-uncensored-q4km` + `bge-m3` | 改 env 后**必须 recreate 容器** |
| hindsight-app（记忆） | 容器 env：`HINDSIGHT_API_LLM_MODEL` / `HINDSIGHT_API_VLM_MODEL` / `..._REASONING_EFFORT=none` / `..._LLM_MAX_CONCURRENT=2` | `qwen3.8-27b-nvfp4-ninfer-gpu2`（LLM+VLM 同名） | 同上 |

> 注意两个服务引用的模型名互不相同、也不等于 WeKnora 用的 `ud-q4xl-gpu2`——**LiteLLM 里
> 同一上游可以有多个 model_name 条目**（谁在显存谁应答），上游切模型时这三处要一起想。

---

## 4. 自动化配置方案

### 4.1 认证与执行通道（两条，按场景选）

| 通道 | 适用 | 要点 |
|---|---|---|
| **A. 直连 DB**（默认） | 引用切换、并发参数、复核 | `ssh nanning-111` + `docker exec -i WeKnora-postgres psql -U postgres -d WeKnora`，SQL **本地写文件走 stdin**。⚠️ 含引号/`$` 的 SQL 绝不走 ssh 双引号 heredoc（本地会先做命令替换）；bash 3.2 下变量一律 `${var}` |
| **B. REST API** | 需要 app 即时感知/写审计的操作 | `X-API-Key: <full_access key>` 打 `127.0.0.1:41201`。key 造法：直插 `tenant_api_keys`（token=`sk-…`，`key_hash`=SHA-256 hex，`full_access=true`，`scope_type='tenant'`），**用完即删**，或造一枚长期 key 放 111 的 `/home/wake/.config/weknora-agent.key`（chmod 600，不入 git） |

DB 通道的坑已验证过：`api_key` 列存明文、`key_hash` 存哈希；模型实例每次请求从 DB 现建
（`model.go:731`）⇒ 改 `max_concurrency`、模型参数**无需重启 app**。

### 4.2 换引用标准流程（每次"把模型 X 的引用切到 Y"都走这八步）

```text
① pg_dump 备份 knowledge_bases / custom_agents / tenants / automations / models
     → /mnt/data/weknora-backup/pre-swap-<日期>.sql
② UPDATE knowledge_bases 的 10 个配置位（见下方 SQL 模板，只改当前 = X 的，不碰别的取值）
③ UPDATE custom_agents.config 的 6 个键
④ UPDATE tenants 的 memory_config(2 键) + chat_history_config(1 键)
⑤ UPDATE automations SET model_id
⑥ UPDATE models SET parameters = jsonb_set(parameters,'{max_concurrency}','<目标并发>')
     WHERE id='<Y>'     —— 按 4 槽位模型的经验值：3（留 1 槽给交互）
⑦ 事务内复核：删除校验 8 字段口径 + profile_config + automations 全部 count=0 后 COMMIT
⑧ 提醒用户 UI 删除旧模型（profile_config 不在校验里，删前再人工确认一次）
```

SQL 模板（把 `<OLD_ID>` / `<NEW_ID>` 替换即可；JSONB 一律 `jsonb_set` 逐键，**不要**
对 `::text` 做全文替换——会破坏转义与无关键）：

```sql
BEGIN;
-- KB 级（10 项）
UPDATE knowledge_bases SET embedding_model_id='<NEW_ID>'  WHERE embedding_model_id='<OLD_ID>';
UPDATE knowledge_bases SET summary_model_id='<NEW_ID>'    WHERE summary_model_id='<OLD_ID>';
UPDATE knowledge_bases SET vlm_config=jsonb_set(vlm_config,'{model_id}','"<NEW_ID>"')
  WHERE vlm_config->>'model_id'='<OLD_ID>';
UPDATE knowledge_bases SET wiki_config=jsonb_set(wiki_config,'{synthesis_model_id}','"<NEW_ID>"')
  WHERE wiki_config->>'synthesis_model_id'='<OLD_ID>';
UPDATE knowledge_bases SET auto_tag_config=jsonb_set(auto_tag_config,'{model_id}','"<NEW_ID>"')
  WHERE auto_tag_config->>'model_id'='<OLD_ID>';
UPDATE knowledge_bases SET profile_config=jsonb_set(profile_config,'{model_id}','"<NEW_ID>"')
  WHERE profile_config->>'model_id'='<OLD_ID>';        -- 删除校验查不到的那一处
UPDATE knowledge_bases SET image_processing_config=jsonb_set(image_processing_config,'{model_id}','"<NEW_ID>"')
  WHERE image_processing_config->>'model_id'='<OLD_ID>';
UPDATE knowledge_bases SET asr_config=jsonb_set(asr_config,'{model_id}','"<NEW_ID>"')
  WHERE asr_config->>'model_id'='<OLD_ID>';
UPDATE knowledge_bases SET question_generation_config=jsonb_set(question_generation_config,'{model_id}','"<NEW_ID>"')
  WHERE question_generation_config->>'model_id'='<OLD_ID>';
-- Agent 级（6 键）
UPDATE custom_agents SET config=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(config,
  '{model_id}','"<NEW_ID>"'),'{rerank_model_id}','"<NEW_ID>"'),'{vlm_model_id}','"<NEW_ID>"'),
  '{asr_model_id}','"<NEW_ID>"'),'{query_understand_model_id}','"<NEW_ID>"')
  WHERE config->>'model_id'='<OLD_ID>' OR config->>'rerank_model_id'='<OLD_ID>'
     OR config->>'vlm_model_id'='<OLD_ID>' OR config->>'asr_model_id'='<OLD_ID>'
     OR config->>'query_understand_model_id'='<OLD_ID>';
-- 简化写法只在旧引用恰好都该换成同一新模型时使用；逐键 WHERE 版本更稳，宁繁勿错。
UPDATE custom_agents SET config=jsonb_set(config,'{question_suggestions,follow_ups,model_id}','"<NEW_ID>"')
  WHERE config->'question_suggestions'->'follow_ups'->>'model_id'='<OLD_ID>';
-- 租户级
UPDATE tenants SET memory_config=jsonb_set(memory_config,'{extract_model_id}','"<NEW_ID>"')
  WHERE memory_config->>'extract_model_id'='<OLD_ID>';
UPDATE tenants SET memory_config=jsonb_set(memory_config,'{embedding_model_id}','"<NEW_ID>"')
  WHERE memory_config->>'embedding_model_id'='<OLD_ID>';
UPDATE tenants SET chat_history_config=jsonb_set(chat_history_config,'{embedding_model_id}','"<NEW_ID>"')
  WHERE chat_history_config->>'embedding_model_id'='<OLD_ID>';
-- 自动化任务
UPDATE automations SET model_id='<NEW_ID>' WHERE model_id='<OLD_ID>';
COMMIT;
```

复核 SQL（全部应为 0）：

```sql
SELECT 'kb' src, count(*) FROM knowledge_bases WHERE '<OLD_ID>' IN (
  embedding_model_id, summary_model_id, image_processing_config->>'model_id',
  vlm_config->>'model_id', asr_config->>'model_id', wiki_config->>'synthesis_model_id',
  auto_tag_config->>'model_id', question_generation_config->>'model_id',
  profile_config->>'model_id')          -- 注意比删除校验多一项
UNION ALL SELECT 'agent', count(*) FROM custom_agents WHERE config::text LIKE '%<OLD_ID>%'
UNION ALL SELECT 'tenant', count(*) FROM tenants WHERE memory_config::text LIKE '%<OLD_ID>%'
  OR chat_history_config::text LIKE '%<OLD_ID>%'
UNION ALL SELECT 'automation', count(*) FROM automations WHERE model_id='<OLD_ID>';
```

### 4.3 换 embedding 模型的特例（不能走 4.2）

`embedding_model_id` 引用切换只对新入库生效；**已有向量是旧模型产的**（
`knowledges.embedding_model_id` 184 行快照、`memory_item_embeddings` 同理），新旧向量空间
不兼容。正确做法：切换后对该 KB 触发重新解析/重嵌，或直接重建 KB。长期记忆同理（清空重建）。

### 4.4 graphiti / hindsight 的切换（env 类，需 recreate）

1. 找到对应容器在 `my-docker/docker-compose.overlay.yml`（或独立 compose 文件）中的 env 声明；
2. 改 `MODEL_NAME` / `HINDSIGHT_API_LLM_MODEL` / `HINDSIGHT_API_VLM_MODEL` 等为新的
   LiteLLM model_name；
3. `docker compose up -d <service>`（recreate，**不是 restart**——restart 不吃新 env）；
4. 探活：`docker logs --since 2m <容器>` 无模型 404/连接错误。

### 4.5 交接约定（给 Agent）

- 用户说"把 X 的引用切到 Y"= 执行 4.2 全流程（含 profile_config 与 automations）；
- 用户说"加个模型"= 手动三步（§1）完成后，按 4.2 把需要的位置指过去（具体指哪些由用户指定）；
- 每次执行前后把备份路径、改动行数、复核结果写入
  `WeKnora/.workbuddy/memory/YYYY-MM-DD.md`；
- 本文档的"当日有值行数"是 2026-11-04 快照，执行前先重跑 §2 的反查 SQL 核对现状。
