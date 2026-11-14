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
| `dsh-agent` | `dsh-agent` | `dsh-agent-dev:local` | `127.0.0.1:8095` → 3080 | **合并 Host（V3）**：cto + pm + dev 三个角色包同 profile，五个 preset |
| `dsh-portal` | `dsh-portal` | `caddy:2-alpine` | `127.0.0.1:8080` → 80 | 统一入口：三个子域各自反代一台官方 UI + 门户页 |
| `dsh-control-plane` | `dsh-control-plane` | `dsh-control-plane:local` | 无（仅容器内 3080） | Web 控制面（实验，已冻结）：多 Agent 统一 UI |
| `browserless` | `browserless` | `ghcr.io/browserless/chromium:latest` | `127.0.0.1:3001` → 3000 | 无头 Chromium：CDP / HTTP 供 agent 调用 |

- compose 项目名：`sanding`；容器名保持旧名，兼容既有脚本与宿主工具。
- 内部网络 `sanding`：容器间可用服务名互访（如 `echuan:8720`）。
- 两个 agent 的 `cordis.patch.yml` 目前仍走宿主地址 `http://host.docker.internal:8721`。
- 启动顺序：两个 agent `depends_on` 等 `echuan` healthy。
- Web 控制面（`dsh-web-control`）在多 Agent 场景下已改由 `dsh-portal` 承担（见第 6 节），控制面服务保留仅供对比。
- `dsh-agent` 是 V3 的目标形态，与旧三台并存：三个角色包装进同一个 profile，
  技能在各自 preset 层、persona 按 preset id 门控；旧三台保留到收口（任务-10）。
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

可选：Web 控制面源码 `../dsh-web-control`（仅开发态起控制面时需要，不参与 compose）。

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

## 5.1 echuan 配置归属

echuan 的容器配置**归部署侧所有**：`deployment/echuan/echuan.container.toml`，只读挂载到
容器内 `/etc/echuan/echuan.toml`。

- 部署不再引用 `echuan_v2/configs/echuan.container.toml`（那是该仓库**独立部署**时用的，两者无自动同步）
- 需要改监听/租约/worker TTL/飞书等参数，改本目录这一份，然后 `docker compose restart echuan`
- 覆盖优先级未变：环境变量（`ECHUAN_*`）> 本文件 > 内置默认值
- 需要临时换配置：`.env` 里设 `ECHUAN_CONFIG_FILE=<绝对路径或相对本目录的路径>`

仍在跨仓库的只剩构建上下文（`ECHUAN_SRC=../../echuan_v2`，从源码构建镜像），那是「代码从哪来」，
不属于配置耦合；若想彻底解耦，可改为直接用已构建好的镜像（`ECHUAN_IMAGE`）并去掉 `build`。

## 6. 统一入口（`dsh-portal`）

三个 Agent 各自是一个**官方 dsh web**，用 Caddy 按子域反代，UI 零改动：

| 入口 | 反代目标 |
| --- | --- |
| `http://cto.localhost:8080` | `cto-agent:3080` |
| `http://dev.localhost:8080` | `dev-agent:3080` |
| `http://pm.localhost:8080` | `pm-agent:3080` |
| `http://127.0.0.1:8080` | 门户页（三张入口卡片） |

- **不要改成路径前缀**（`/cto/`）：dsh web 的资源与 API 都是绝对路径，前缀会踩坑。
- 每个子域都是根路径，官方 UI 不知道自己在反代后面；上游升级只需重建 agent 镜像。
- `*.localhost` 在 Chrome / Edge / Safari 上由浏览器解析到回环，无需改 hosts；
  系统级解析不到时可直接用 `127.0.0.1:8090` / `:8091` / `:8093`（等价入口）。
- Docker Desktop 会把宿主代理注入容器：`dsh-portal` 必须配 `NO_PROXY` 含三个服务名，
  否则反代会把内部请求交给代理，返回 502。
- 只绑回环；要对外暴露交给隧道 / 反向代理，不要直接把 8080 发布到 0.0.0.0。

改完 `Caddyfile` 或 `portal/` 后：

```bash
docker compose up -d --force-recreate dsh-portal
docker compose logs --tail=20 dsh-portal
```

## 7. Web 控制面（`dsh-control-plane`，实验，已冻结）

> 2026-11-14 起不再迭代：它靠 fork 官方 UI 换来多 Agent 聚合，上游每次改 UI/协议都要跟。
> 多 Agent 的日常入口改用第 6 节的 `dsh-portal`，本服务只作对比与回退保留。

把 cto / pm / dev 三个 Agent 收进同一个 Web UI：侧栏是「实例 → 工作区 → 会话」树，对话区复用官方 dsh UI。
镜像复用官方 dsh CLI + 本仓库构建的 control-plane bundle（CLI 未改动），镜像名 `dsh-control-plane:local`（约 780MB）。

职责红线：控制面只做接入、路由、呈现、审计；任务编排、重试、验收归驿传。

### 6.1 服务定义

- harness 只绑 **loopback**（`DSH_BIND_HOST=loopback`），对外入口是 **dsh-relay 的 3443**（容器内 `0.0.0.0:3443` → 发布 `127.0.0.1:3443`）
- relay **不打进镜像**：镜像构建只产出 monorepo 运行时，插件由 entrypoint 在容器启动时装进 profile
  （`dsh plugin --profile web add ${DSH_RELAY_PLUGIN:-dsh-relay@0.4.0}`，幂等，装在 `DSH_HOME` 卷里，重建容器不丢）。
  背景：dsh 从 profile 的 `node_modules` 解析插件，镜像内装在 monorepo 根下 profile 看不见，
  启动会报 `Cannot find package 'dsh-relay'`。
- relay 实例由包自带的 bundle 层 `insert`（id=`relay`），部署配置在 `control-plane/cordis.patch.yml` 里**按 id 覆盖**；
  该层会整体替换 config，需要的字段必须重述。
- 安装源：`NPM_REGISTRY`（默认 `${DSH_CONTROL_PLANE_NPM_REGISTRY:-https://registry.npmmirror.com}`）
- 版本：`DSH_RELAY_PLUGIN`（默认 `dsh-relay@0.4.0`）。entrypoint 比对 profile 里已装版本，不一致才重装——**升级只改这个变量 + `docker compose up -d`，不用重建镜像**。
- 实例表通过只读挂载注入：`./control-plane/control-plane.json` → `/etc/dsh/control-plane.json`
- `DSH_HOME` 挂在 `./data/dsh-home-cp`
- 配对与设备令牌落在 `/home/node/.dsh/relay`（卷内），证书自签、指纹在配对页
- **密码不能写进 cordis 配置**：relay 不接受配置项/环境变量指定密码，只在 `relay/state.json` 存 scrypt(salt,hash)，
  且设置接口要求请求源是 loopback（容器内）。宿主/手机打开 `/relay/password` 会报
  `Set the password from the machine running the harness.`
- 声明式做法：`.env` 里填 `DSH_RELAY_PASSWORD`（≥10 字符），然后
  `./scripts/relay-password.sh`（从容器内 loopback 发起，幂等，随时可轮换）。

### 6.2 实例表

`control-plane/control-plane.json`，用 compose 服务名寻址（容器间走 `sanding` 网络）：

| 实例 id | 名称 | 地址 | 对应 compose 服务 |
| --- | --- | --- | --- |
| `dsh-worker-cto` | 技术总监 | `cto-agent:3080` | `cto-agent` |
| `dsh-worker-dev` | 开发团队 | `dev-agent:3080` | `dev-agent` |
| `dsh-worker-pm` | 产品经理 | `pm-agent:3080` | `pm-agent` |

改完实例表需要重建容器才生效（插件配置不热更新）：

```bash
docker compose up -d --no-build --force-recreate dsh-control-plane
```

### 6.3 常用命令

```bash
docker compose up -d --build dsh-control-plane      # 首次/改代码后构建
docker compose logs -f --tail=100 dsh-control-plane
docker compose ps dsh-control-plane                  # 期望 healthy
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3095/    # 401 = 正常（缺 token）
# 带 token 访问：从 docker compose logs 里取 ?token=... 的完整 URL，浏览器打开
```

### 6.4 注意

- 启动日志会打印带 `?token=` 的 URL，不带 token 是 401
- 构建参数 `DSH_CLIENT_COMMIT_HASH` 默认 `0000000`，需要真实 commit 时在 `.env` 设 `DSH_CONTROL_PLANE_COMMIT`
- 构建期用公共 npm 源（`DSH_CONTROL_PLANE_NPM_REGISTRY`），不继承宿主 `.env` 里指向本地 verdaccio 的 `NPM_REGISTRY`
- 镜像默认用 `Dockerfile.slim`（裁掉 codex / claude-sdk / libreoffice-wasm 等后端）；需要完整能力可设 `DSH_CONTROL_PLANE_DOCKERFILE=Dockerfile`

## 7.1 合并 Host（`dsh-agent`）

单 Host 多角色，三个角色包（`dsh-agent-cto` / `dsh-agent-pm` / `dsh-agent-dev`）装进同一个 profile。

**必须做的一件事**：三个包各带一份 `agent-preset-registry` insert，加载器按 id 合并，
最后一个 bundle 的 `default` 胜出（实测是 `pm`）。所以 `patches/dsh-agent.patch.yml` 里显式覆盖：

```yaml
- id: agent-preset-registry
  config:
    default: cto
```

`patches/dsh-agent.patch.yml` 同时声明 worker 承接全部 kind（requirement / design / breakdown / dev）——
角色由平台侧的 `kind → preset` 映射决定，不再靠「一台 host 只声明一组 kind」隐式表达。

**验收**（一条命令，容器内跑）：

```bash
docker compose exec dsh-agent node /opt/verify-presets.mjs --home /home/node/.dsh --profile web
```

断言：五个角色 preset（cto / pm / dev-leader / dev-developer / dev-tester）注册、默认 cto、
宿主层只有基础设施技能、每个 preset 的技能清单与预期逐字一致、persona 不串味。
基线 preset（standard / ptc / minimal / cordis）来自 `dsh-agent-base`，属正常。

**回退**：旧三台仍在运行（8090/8091/8093）；`dsh-agent` 出问题直接 `docker compose stop dsh-agent`。

### 7.2 权限矩阵

| 会话 | 权限预设 | 沙箱 / 审批 | 由谁设置 |
| --- | --- | --- | --- |
| cto | `workspace-write` | 工作区内可写，每次变更需确认 | 进程默认（`patches/dsh-agent.patch.yml` 的 `defaultPreset`） |
| pm | `workspace-write` | 同上 | 同上 |
| dev-leader / dev-developer / dev-tester | `danger-full-access` | 无沙箱限制，不弹审批 | `dsh-agent-dev` 在 `agent/created` 时按 preset 切换 |

为什么 dev 必须完全访问：编码 / 构建 / 验收都要指挥宿主 Docker 与 devcontainer，
`workspace-write` + `ask` 会让每条命令都弹确认，实际不可用。

**代价与兜底**：`dsh-agent` 挂了宿主 `docker.sock`，preset 只能收窄工具清单、收窄不了
进程能力——cto/pm 的 bash 理论上也能碰到 Docker。所以三条人设都写入了「破坏性操作红线」：
Docker 破坏性命令（rm/stop/prune）、容器/镜像重建、数据删除、强制推送、发布上线，
必须先说明命令与影响面并得到人工确认。这是自觉承担的风险（见架构文档 ADR-5）。


## 8. 与原部署方式的差异

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

## 9. 排障

- 控制面里某个实例连不上：先 `curl http://127.0.0.1:<端口>/` 确认该 Agent 宿主端口通，再看 `docker compose logs <服务>`；实例 id / 端口与 `control-plane/control-plane.json` 不一致也会连不上。
- `worker 'base'/'dev' 未注册`：看对应 agent 日志里的 `[dsh-echuan]` 行；多半是 `cordis.patch.yml` 的 `baseUrl` 或 `worker.poll.enable` 不对，或平台没起。
- agent 里访问平台 502：代理变量没排除 `host.docker.internal`。compose 已把大小写 `NO_PROXY` 成对覆盖，若自行加变量要保持成对。
- `dsh: skipping profile bundle ...`：profile 里残留了本容器没挂载的插件，删掉 `dsh-home-*/profiles/web/package.json` 中对应的 `dsh.profile.bundles` 与 `dependencies` 条目后重启。
- 容器 healthy 但 agent 打不开：token 在日志里，`docker compose logs cto-agent | grep token=`。
- `browserless` 返回 401：`BROWSERLESS_TOKEN` 与客户端使用的 token 不一致（所有端点都鉴权，包括 `/json/version`、`/pressure`）。
- `browserless` 日志报 `/data` 无权限：镜像内用户是 `blessuser`（UID 999），
  `chown -R 999:999 deployment/data/browserless` 后重启。
- `browserless` 反复重启 / Chrome 崩溃：确认 `shm_size` 为 `2g`。
- 从 agent 容器连不上 `127.0.0.1:3001`：容器里的 127.0.0.1 是它自己，必须用 `host.docker.internal:3001`。
