# 三鼎（Sanding）统一部署

一套 compose 起五个服务（驿传 + 三个 Agent + 一个共享无头浏览器）；其中 cto 与 pm 共用同一个镜像，
只有插件清单不同，
替代原先「各仓库目录里各自 `docker compose up`」的方式。

> **0.2.0 起不再需要自建带 stagehand extension 的浏览器镜像**：`browserless`
> 直接用官方 `ghcr.io/browserless/chromium`，不带 `--load-extension`。
> 浏览器只通过 CDP(WebSocket) / HTTP 被客户端使用。

## 1. 拓扑

| compose 服务 | 容器名 | 镜像 | 宿主端口 | 作用 |
| --- | --- | --- | --- | --- |
| `echuan` | `echuan-v2` | `echuan-v2:local` | `127.0.0.1:8721` → 8720 | 驿传平台：状态唯一真相源 |
| `cto-agent` | `dsh-agent-cto` | `dsh-agent-base:local` | `127.0.0.1:8090` → 3080 | CTO Agent：requirement / design / breakdown |
| `pm-agent` | `dsh-agent-pm` | `dsh-agent-base:local` | `127.0.0.1:8093` → 3080 | 产品经理 Agent：需求 / 方案 / 拆解 |
| `dev-agent` | `dsh-agent-dev` | `dsh-agent-dev:local` | `127.0.0.1:8091` → 3080 | 开发 Agent：dev（含 docker / devcontainer 能力） |
| `browserless` | `browserless` | `ghcr.io/browserless/chromium:latest` | `127.0.0.1:3001` → 3000 | 无头 Chromium：CDP / HTTP 供 agent 调用 |

- compose 项目名：`sanding`；容器名保持旧名，兼容既有脚本与宿主工具。
- 内部网络 `sanding`：容器间可用服务名互访（如 `echuan:8720`）。
- 两个 agent 的 `cordis.patch.yml` 目前仍走宿主地址 `http://host.docker.internal:8721`。
- 启动顺序：两个 agent `depends_on` 等 `echuan` healthy。
- 浏览器访问方式（`TOKEN` 即 `.env` 的 `BROWSERLESS_TOKEN`）：
  - agent 容器内：`ws://host.docker.internal:3001?token=<TOKEN>`（不能写 127.0.0.1）
  - 宿主本机：`ws://127.0.0.1:3001?token=<TOKEN>`
  - HTTP：`http://127.0.0.1:3001/json/version?token=<TOKEN>`、`/pressure`、`/content` 等

## 2. 依赖

宿主机上需要存在（路径写在 `.env`）：

- 源码：`ECHUAN_SRC`（同级仓库）+ `DSH_AGENT_SRC` / `DSH_DEV_SRC`（本仓库 `agents/`）
- **不需要任何宿主插件源码**：两个 agent 的插件都在容器启动时按 `.env` 的
  `DSH_CTO_PLUGIN_SPECS` / `DSH_PM_PLUGIN_SPECS` / `DSH_DEV_PLUGIN_SPECS` 从 npm registry 安装到 profile。

`browserless` 不需要本地源码，也不构建镜像，只需能拉取 `ghcr.io/browserless/chromium`
（首次 `up` 会拉取；网络受限时先配 daemon 镜像加速或宿主代理）。

## 3. 配置

```bash
cp .env.example .env
```

`.env` 关键项：

| 变量 | 说明 |
| --- | --- |
| `HOST_PROJECT_PATH` | agent 共享工作区（挂 `/workspace`） |
| `ECHUAN_DATA_DIR` | 驿传 SQLite / objects / workspaces 宿主目录 |
| `DSH_CTO_HOME_DIR` / `DSH_PM_HOME_DIR` / `DSH_DEV_HOME_DIR` | 三个 agent 的 dsh home（profile、会话、`cordis.patch.yml`） |
| `ECHUAN_PORT` / `DSH_CTO_PORT` / `DSH_PM_PORT` / `DSH_DEV_PORT` | 宿主回环端口（8721 / 8090 / 8093 / 8091） |
| `DOCKER_SOCKET` | dev-agent 指挥宿主 daemon 的 socket |
| `DOCKER_PROXY` | devcontainer 访问 ghcr.io 的代理；空 = 直连 |
| `DSH_CTO_PLUGIN_SPECS` | cto-agent 的插件清单（`<name>@<version>`，空格分隔，顺序即安装顺序） |
| `DSH_PM_PLUGIN_SPECS` | pm-agent 的插件清单（同上） |
| `DSH_DEV_PLUGIN_SPECS` | dev-agent 的插件清单（同上） |
| `GH_TOKEN` | dev-agent 用的 GitHub PAT；留空 = 容器内 gh 未登录 |
| `BROWSERLESS_IMAGE` | 浏览器镜像，默认官方 `ghcr.io/browserless/chromium:latest`；生产建议固定 tag/digest |
| `BROWSERLESS_PORT` | 浏览器宿主回环端口，默认 `3001`（容器内 3000） |
| `BROWSERLESS_TOKEN` | **必填**，访问令牌；`openssl rand -hex 32` 生成，不要用 `test-token` |
| `BROWSERLESS_CONCURRENT` / `QUEUED` / `TIMEOUT` | 并发会话数 / 排队数 / 会话超时（毫秒） |
| `BROWSERLESS_SHM_SIZE` | Chrome 共享内存，默认 `2g`（低于 2g 易崩） |
| `BROWSERLESS_DATA_DIR` | 浏览器用户数据目录，默认 `./data/browserless` |
| `BROWSERLESS_CONTAINER_NAME` | 容器名，默认 `browserless` |

`.env` 与 `data/`、`secrets/` 都在 `.gitignore` 里，不会进仓。

## 4. 日常命令

```bash
./scripts/up.sh                # 启动并等到 healthy（加 --build 重建镜像）
./scripts/down.sh              # 停止并移除容器（数据保留）
./scripts/status.sh            # 容器状态 + 端口探活 + 已注册 worker
./scripts/smoke-test.sh        # 冒烟：readyz、两个 agent HTTP、browserless、worker 注册

docker compose logs -f --tail=100 cto-agent
docker compose logs -f --tail=100 dev-agent
docker compose logs -f --tail=100 browserless
docker compose build echuan    # 只重建某个镜像
docker compose up -d echuan    # 只更新某个服务
```

## 5. 数据与备份

| 数据 | 位置 | 备份 |
| --- | --- | --- |
| 驿传库 / 资料 / 工作区 | `$ECHUAN_DATA_DIR`（默认 `~/echuan-v2-data`） | `echuan_v2/scripts/backup.sh` |
| CTO Agent 会话与 profile | `deployment/data/dsh-home-cto` | 目录整体打包即可 |
| PM Agent 会话与 profile | `deployment/data/dsh-home-pm` | 目录整体打包即可 |
| 开发 Agent 会话与 profile | `deployment/data/dsh-home-dev` | 目录整体打包即可 |
| 浏览器用户数据 / 下载 | `deployment/data/browserless` | 可删（丢失 Cookie / 缓存）；备份按需 |

**注意**：`echuan_v2/scripts/{backup,restore}.sh` 默认按项目名 `echuan-v2` 找容器。现在部署在 `sanding` 项目下，调用时需显式指定：

```bash
COMPOSE_PROJECT_NAME=sanding docker compose -f ../../echuan_v2/docker-compose.yml ps
# 或直接用本目录：docker compose ps / docker compose exec echuan ...
```

## 6. 与原部署方式的差异

| 项 | 原来 | 现在 |
| --- | --- | --- |
| 启动方式 | 三个目录各自 `docker compose up` | 本目录一条 `docker compose up -d` |
| compose 项目名 | `echuan-v2` / `dsh-agent-base` / `dsh-dev-agent` | 统一 `sanding` |
| 容器名 | `echuan-v2` / `dsh-agent-base` / `dsh-agent-dev` | `echuan-v2` / `dsh-agent-cto` / `dsh-agent-dev` |
| 端口 | 8721 / 8090 / 8091 | 不变 |
| 镜像名 | `*-local` | 不变 |

| dsh home | 各仓库目录下 `dsh-home/` | 复制到 `deployment/data/`，旧目录保留可回滚 |
| 浏览器 | 自建 `browserless-stagehand` 镜像（带 stagehand extension） | 官方 `ghcr.io/browserless/chromium`，无扩展 |

回滚：

```bash
cd ~/project/opc/sanding/deployment && ./scripts/down.sh
cd ~/project/opc/echuan_v2 && docker compose up -d
cd ~/project/opc/sanding/agents/dsh-agent-cto/examples && docker compose up -d
cd ~/project/opc/sanding/agents/dsh-agent-dev/examples && docker compose up -d
```

（旧 `dsh-home` 目录未删，回滚后状态与切换前一致。）

## 7. 排障

- `worker 'base'/'dev' 未注册`：看对应 agent 日志里的 `[dsh-echuan]` 行；多半是 `cordis.patch.yml` 的 `baseUrl` 或 `worker.poll.enable` 不对，或平台没起。
- agent 里访问平台 502：代理变量没排除 `host.docker.internal`。compose 已把大小写 `NO_PROXY` 成对覆盖，若自行加变量要保持成对。
- `dsh: skipping profile bundle ...`：profile 里残留了本容器没挂载的插件，删掉 `dsh-home-*/profiles/web/package.json` 中对应的 `dsh.profile.bundles` 与 `dependencies` 条目后重启。
- 容器 healthy 但 agent 打不开：token 在日志里，`docker compose logs cto-agent | grep token=`。
- `browserless` 返回 401：`BROWSERLESS_TOKEN` 与客户端使用的 token 不一致（所有端点都鉴权，包括 `/json/version`、`/pressure`）。
- `browserless` 日志报 `/data` 无权限：镜像内用户是 `blessuser`（UID 999），
  `chown -R 999:999 deployment/data/browserless` 后重启。
- `browserless` 反复重启 / Chrome 崩溃：确认 `shm_size` 为 `2g`。
- 从 agent 容器连不上 `127.0.0.1:3001`：容器里的 127.0.0.1 是它自己，必须用 `host.docker.internal:3001`。
