# 百工统一部署

一套 compose 起三个服务，替代原先「各仓库目录里各自 `docker compose up`」的方式。

## 1. 拓扑

| compose 服务 | 容器名 | 镜像 | 宿主端口 | 作用 |
| --- | --- | --- | --- | --- |
| `echuan` | `echuan-v2` | `echuan-v2:local` | `127.0.0.1:8721` → 8720 | 驿传平台：状态唯一真相源 |
| `cto-agent` | `dsh-agent-base` | `dsh-agent-base:local` | `127.0.0.1:8090` → 3080 | CTO Agent：requirement / design / breakdown |
| `dev-agent` | `dsh-agent-dev` | `dsh-agent-dev:local` | `127.0.0.1:8091` → 3080 | 开发 Agent：dev（含 docker / devcontainer 能力） |

- compose 项目名：`baigong`；容器名保持旧名，兼容既有脚本与宿主工具。
- 内部网络 `baigong`：容器间可用服务名互访（如 `echuan:8720`）。
- 两个 agent 的 `cordis.patch.yml` 目前仍走宿主地址 `http://host.docker.internal:8721`。
- 启动顺序：两个 agent `depends_on` 等 `echuan` healthy。

## 2. 依赖

宿主机上需要存在（路径写在 `.env`）：

- 三个源码仓库：`ECHUAN_SRC` / `DSH_BASE_SRC` / `DSH_DEV_SRC`
- 三个插件仓库，且 **已构建**：`DSH_RSI_AGENT_SRC` / `DSH_DOMAIN_SRC` / `DSH_DEV_DOMAIN_SRC` / `ECHUAN_KIT_DIR`
  - `dsh-rsi-agent`、`dsh-domain`、`dsh-dev-domain`：`dist-server/index.js`
  - `echuan kit`：`lib/index.js`

```bash
pnpm -C ~/project/opc/dsh-rsi-agent build
pnpm -C ~/project/opc/dsh-domain build
pnpm -C ~/project/opc/dsh-dev-domain build
pnpm -C ~/project/opc/echuan_v2/kit build
```

插件不在镜像里：compose 只读目录挂载到 `/src/plugins/<name>`，容器启动时由 entrypoint 幂等 link 进 profile。

## 3. 配置

```bash
cp .env.example .env
```

`.env` 关键项：

| 变量 | 说明 |
| --- | --- |
| `HOST_PROJECT_PATH` | agent 共享工作区（挂 `/workspace`） |
| `ECHUAN_DATA_DIR` | 驿传 SQLite / objects / workspaces 宿主目录 |
| `DSH_BASE_HOME_DIR` / `DSH_DEV_HOME_DIR` | 两个 agent 的 dsh home（profile、会话、`cordis.patch.yml`） |
| `ECHUAN_PORT` / `DSH_BASE_PORT` / `DSH_DEV_PORT` | 宿主回环端口（8721 / 8090 / 8091） |
| `DOCKER_SOCKET` | dev-agent 指挥宿主 daemon 的 socket |
| `DOCKER_PROXY` | devcontainer 访问 ghcr.io 的代理；空 = 直连 |
| `GH_TOKEN_FILE` | gh 令牌只读文件（模板默认空文件 = 未登录） |

`.env` 与 `data/`、`secrets/` 都在 `.gitignore` 里，不会进仓。

## 4. 日常命令

```bash
./scripts/up.sh                # 启动并等到 healthy（加 --build 重建镜像）
./scripts/down.sh              # 停止并移除容器（数据保留）
./scripts/status.sh            # 容器状态 + 端口探活 + 已注册 worker
./scripts/smoke-test.sh        # 冒烟：readyz、两个 agent HTTP、worker 注册

docker compose logs -f --tail=100 cto-agent
docker compose logs -f --tail=100 dev-agent
docker compose build echuan    # 只重建某个镜像
docker compose up -d echuan    # 只更新某个服务
```

## 5. 数据与备份

| 数据 | 位置 | 备份 |
| --- | --- | --- |
| 驿传库 / 资料 / 工作区 | `$ECHUAN_DATA_DIR`（默认 `~/echuan-v2-data`） | `echuan_v2/scripts/backup.sh` |
| CTO Agent 会话与 profile | `deployment/data/dsh-home-base` | 目录整体打包即可 |
| 开发 Agent 会话与 profile | `deployment/data/dsh-home-dev` | 目录整体打包即可 |

**注意**：`echuan_v2/scripts/{backup,restore}.sh` 默认按项目名 `echuan-v2` 找容器。现在部署在 `baigong` 项目下，调用时需显式指定：

```bash
COMPOSE_PROJECT_NAME=baigong docker compose -f ../../echuan_v2/docker-compose.yml ps
# 或直接用本目录：docker compose ps / docker compose exec echuan ...
```

## 6. 与原部署方式的差异

| 项 | 原来 | 现在 |
| --- | --- | --- |
| 启动方式 | 三个目录各自 `docker compose up` | 本目录一条 `docker compose up -d` |
| compose 项目名 | `echuan-v2` / `dsh-agent-base` / `dsh-dev-agent` | 统一 `baigong` |
| 容器名 | `echuan-v2` / `dsh-agent-base` / `dsh-agent-dev` | 不变 |
| 端口 | 8721 / 8090 / 8091 | 不变 |
| 镜像名 | `*-local` | 不变 |
| 插件挂载 | 各自 compose 内写死 | 不变（同一套挂载，集中配置） |
| dsh home | 各仓库目录下 `dsh-home/` | 复制到 `deployment/data/`，旧目录保留可回滚 |

回滚：

```bash
cd ~/project/opc/baigong/deployment && ./scripts/down.sh
cd ~/project/opc/echuan_v2 && docker compose up -d
cd ~/project/opc/dsh-agent/dsh-agent-base && docker compose up -d
cd ~/project/opc/dsh-agent/dsh-dev-agent && docker compose up -d
```

（旧 `dsh-home` 目录未删，回滚后状态与切换前一致。）

## 7. 排障

- `worker 'base'/'dev' 未注册`：看对应 agent 日志里的 `[dsh-echuan]` 行；多半是 `cordis.patch.yml` 的 `baseUrl` 或 `worker.poll.enable` 不对，或平台没起。
- agent 里访问平台 502：代理变量没排除 `host.docker.internal`。compose 已把大小写 `NO_PROXY` 成对覆盖，若自行加变量要保持成对。
- `dsh: skipping profile bundle ...`：profile 里残留了本容器没挂载的插件，删掉 `dsh-home-*/profiles/web/package.json` 中对应的 `dsh.profile.bundles` 与 `dependencies` 条目后重启。
- 容器 healthy 但 agent 打不开：token 在日志里，`docker compose logs cto-agent | grep token=`。
