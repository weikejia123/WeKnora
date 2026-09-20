# my-docker —— 我们自己的部署配置

本目录存放**站点定制版**的 Compose 配置。部署一律用这里的文件，**不改动仓库根的官方 `docker-compose.yml`**。

## 为什么单独放一个目录

| 诉求 | 这样做的效果 |
|---|---|
| 上游更新时零冲突 | 官方 `docker-compose.yml` 保持原样，`git pull` 不会撞车 |
| 定制集中、可追溯 | 所有站点差异都在 `my-docker/docker-compose.yml`，受版本控制 |
| 不产生漂移产物 | 不用 override 文件、不用 `--build-arg`、不生成临时产物 |

**差异清单不在本文件重复** —— 它是「单一事实来源」放在 `docker-compose.yml` 的**文件头注释**里，
紧贴被改动的代码，同步上游时按编号逐条比对即可。本文件只补充 yml 里放不下的部分。

## 用法

```bash
cd <仓库根>

# 统一命令形态（务必带 --project-directory，原因见 yml 头部说明）
docker compose --project-directory . --env-file .env \
               -f my-docker/docker-compose.yml <子命令>
```

例如：

```bash
C="docker compose --project-directory . --env-file .env -f my-docker/docker-compose.yml"
$C config          # 校验并查看解析结果
$C ps              # 状态
$C logs -f app     # 日志
$C build           # 从源码构建（二开用；默认构建 app/frontend/docreader）
$C up -d           # 启动
```

**不需要改任何相对路径**：加 `--project-directory` 后 `build.context`、bind mount、`env_file: .env`
全部恢复为「相对仓库根」的原语义。已实测与官方配置的 `docker compose config` 输出逐行一致。

> ⚠️ 漏掉 `--project-directory` 会怎样：`env_file: .env` 会去找 `my-docker/.env`（不存在）→
> **报错退出**；极端情况下若那里恰好有 `.env`，项目名会退化成 `my-docker` → 指向一套**新建的空数据卷**。
> 所以部署脚本已加项目名断言（必须为 `weknora`）来兜底。

## `.env` 在哪

**仍在仓库根**（`<仓库根>/.env`），不在本目录。

原因：`.env` 内含生产密钥（数据库密码、JWT 密钥、`SYSTEM_AES_KEY`），已被 `.gitignore` 忽略，**不能进仓库**。
所以 `.env` 是「部署现场的状态」，`my-docker/` 是「受版本控制的配置」——两者职责分开。
模板见仓库根的 `.env.example`。

## 上游同步

官方 `docker-compose.yml` 更新后：

```bash
./deploy/deploy-wkj-dev.sh compose-diff      # 查看官方与 my-docker 的差异
```

看到上游新增/修改的内容后，**逐条判断是否需要搬进 `my-docker/docker-compose.yml`**，
并同步更新头部差异清单的编号。这一步是为了防止本文件**悄悄过期**（上游加了新服务/新参数而这里没有）。

## 部署

`deploy/deploy-wkj-dev.sh` 已经把上面那串参数封装好了，直接用脚本即可：

```bash
./deploy/deploy-wkj-dev.sh deploy     # 首次部署
./deploy/deploy-wkj-dev.sh update     # 日常更新（用官方预构建镜像）
./deploy/deploy-wkj-dev.sh build      # 二开：从源码构建（让你的代码生效）
```
