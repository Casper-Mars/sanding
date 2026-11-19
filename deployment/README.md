# 三鼎（Sanding）统一部署

一套 compose 起**三个服务**（驿传平台 + 合并 Host + 共享无头浏览器）：

| compose 服务 | 容器名 | 镜像 | 宿主端口 | 作用 |
| --- | --- | --- | --- | --- |
| `echuan` | `echuan` | `echuan:local` | `127.0.0.1:8721` → 8720 | 驿传平台：状态唯一真相源 |
| `dsh-agent` | `dsh-agent` | `dsh-agent-dev:local` | `0.0.0.0:3443`（TLS，relay） | **合并 Host**：cto / pm / dev 三个角色包同 profile，对外只经 `dsh-relay` |
| `browserless` | `browserless` | `ghcr.io/browserless/chromium` | `127.0.0.1:3000` → 3000 | 无头 Chromium：CDP / HTTP 供 agent 调用 |

- compose 项目名：`sanding`；容器间经 `sanding` 网络用服务名互访（如 `echuan:8720`）。
- 启动顺序：`dsh-agent` 等 `echuan` 与 `browserless` healthy。
- **两个服务只绑回环**（echuan、browserless）；对外唯一入口是 `dsh-agent` 里的 relay（3443）。
- 旧三台（`cto-agent` / `pm-agent` / `dev-agent`）与控制面（`dsh-control-plane`）**已删除**。
  它们仍会向同一平台声明 kinds，一启动就抢卡（实测 requirement 卡被旧 worker 领走）。
  需要历史实现时看 git 历史（提交 `b497038` 之前）。

## 1. 依赖

宿主机上需要（路径写在 `.env`）：

- 源码：`ECHUAN_SRC`（同级仓库）+ `DSH_DEV_SRC`（本仓库 `agents/dsh-agent-dev`）
- **不需要宿主插件源码**：插件在容器启动时按 `.env` 的 `DSH_MERGED_PLUGIN_SPECS` 从 npm registry 装进 profile
- `browserless` 不构建镜像，只需能拉 `ghcr.io/browserless/chromium`

## 2. 配置

```bash
cp .env.example .env
```

`.env` 关键项：

| 变量 | 说明 |
| --- | --- |
| `ECHUAN_SRC` / `DSH_DEV_SRC` | 两个镜像的构建上下文 |
| `HOST_PROJECT_PATH` | agent 共享工作区（挂 `/workspace`） |
| `ECHUAN_DATA_DIR` | 驿传 SQLite / objects / workspaces 宿主目录（默认 `./echuan/data`） |
| `DSH_MERGED_HOME_DIR` | 合并 Host 的 dsh home（默认 `./data/dsh-home-agent`） |
| `ECHUAN_PORT` | 驿传宿主回环端口，默认 `8721` |
| `DSH_RELAY_PORT` / `DSH_RELAY_BIND` | 对外入口端口 / 绑定地址（默认 `3443` / `0.0.0.0`） |
| `DSH_MERGED_PLUGIN_SPECS` | 合并 Host 的插件清单（`<name>@<version>`，空格分隔，顺序即安装顺序） |
| `NPM_REGISTRY` | 插件安装源；指向本地 verdaccio 时写 `http://host.docker.internal:4873` |
| `DOCKER_SOCKET` | 合并 Host 指挥宿主 daemon 的 socket |
| `DOCKER_PROXY` | devcontainer / 插件访问外网的代理；空 = 直连 |
| `GH_TOKEN` | GitHub PAT；留空 = 容器内 gh 未登录 |
| `BROWSERLESS_TOKEN` | **必填**，`openssl rand -hex 32` 生成，不要用 `test-token` |
| `DEEPSEEK_API_KEY` | LLM 凭据（环境层优先，Web 设置页无法覆盖） |
| `DSH_RELAY_PLUGIN` / `DSH_RELAY_PASSWORD` | relay 插件版本 / 登录密码（≥10 字符） |

`.env`、`data/`、`secrets/` 都在 `.gitignore` 里，不会进仓。

## 3. 日常命令

```bash
./scripts/up.sh                # 启动并等到 healthy（加 --build 重建镜像）
./scripts/down.sh              # 停止并移除容器（数据保留）
./scripts/status.sh            # 容器状态 + 端口探活 + 已注册 worker
./scripts/smoke-test.sh        # 冒烟：readyz、relay health、browserless、worker 注册

docker compose logs -f --tail=100 dsh-agent
docker compose build echuan    # 只重建某个镜像
docker compose up -d echuan    # 只更新某个服务
```

> 如果以前起过旧三台 / 控制面，第一次用新 compose 会报 orphan containers：
> `docker compose up -d --remove-orphans` 清掉即可。它们都是 bind mount，删容器不丢数据。

## 4. 数据与备份

| 数据 | 位置 | 备份 |
| --- | --- | --- |
| 驿传库 / 资料 / 工作区 | `$ECHUAN_DATA_DIR`（默认 `./echuan/data`） | `echuan_v2/scripts/backup.sh` |
| 合并 Host 会话 / profile / relay 证书与配对设备 | `deployment/data/dsh-home-agent` | 目录整体打包即可 |
| 浏览器用户数据 / 下载 | `deployment/data/browserless` | 可删（丢 Cookie / 缓存）；按需备份 |

## 4.1 echuan 配置归属

echuan 的容器配置**归部署侧所有**：`deployment/echuan/echuan.container.toml`，只读挂载到
容器内 `/etc/echuan/echuan.toml`。

- 部署不引用 `echuan_v2/configs/echuan.container.toml`（那是该仓库**独立部署**时用的）
- 改监听 / 租约 / worker TTL / 飞书等参数，改本目录这一份，然后 `docker compose restart echuan`
- 优先级：环境变量（`ECHUAN_*`）> 本文件 > 内置默认值

## 5. 对外入口（`dsh-relay`）

```
手机 / 浏览器 ──TLS──▶ dsh-agent:3443（relay）──HTTP──▶ 127.0.0.1:3080（harness）
                         ├─ /relay/login     密码登录
                         ├─ /relay/password  设密码（只接受本机）
                         ├─ /relay/pair      配对设备（QR / 8 位码）
                         └─ /relay/devices   逐设备吊销
```

- **harness 只绑回环**：`DSH_BIND_HOST=loopback`。relay 发现 webserver 已监听网络地址会拒绝启动，
  所以「relay 挂了」的结果是连不上，而不是裸奔在网络上。
- **设 / 改密码**（relay 只接受「运行 harness 的机器」设密码，容器化后就是容器本身）：

  ```bash
  ./scripts/relay-password.sh                      # 合并 Host（dsh-agent）
  ./scripts/relay-password.sh --container dsh-xxx  # 任意容器
  ```
  不给密码时读 `.env` 的 `DSH_RELAY_PASSWORD`，两个 relay 共用同一个密码。

- **配对设备**：本机打开 `https://127.0.0.1:3443/relay/pair`（自签证书点「继续」），手机扫码或输 8 位码。
- 自签证书、已配对设备在 `data/dsh-home-agent/relay/`，重建容器不丢。
- **组网访问（xedge / Tailscale 等）**：relay 只信任 loopback + `publicHostnames` 里列出的地址，
  否则 403 `untrusted-host`。当前 `agents/dsh-agent.patch.yml` 已加入 xedge 的 `100.64.0.1`；
  换网段或绑了域名时把新地址加进去，重建容器即可（证书 SAN 会同步更新）。
- **不要**在 relay 前面再套 nginx / Caddy / Tailscale Serve：那些代理从回环连进来，
  relay 会当成「本机操作员」，等于免密。

## 6. 合并 Host 与角色

三个角色包（`dsh-agent-cto` / `dsh-agent-pm` / `dsh-agent-dev`）装进同一个 profile。

- **必须**在 `agents/dsh-agent.patch.yml` 覆盖 `agent-preset-registry.default: cto`
  （三个包各带一份 insert，最后一个 bundle 的 default 胜出，实测是 pm）。
- 派单只下发 `kind`；kit 按 `worker.presetByKind` 在本机解析 preset（默认
  `requirement=pm, design=cto, breakdown=cto, dev=dev-leader`），再按 `项目号:preset` 建会话。
  新增角色只改这一处 + 装好 preset，平台零改动。

验收（容器内跑）：

```bash
docker compose exec dsh-agent node /opt/verify-presets.mjs --home /home/node/.dsh --profile web
```

断言：五个 preset（cto / pm / dev-leader / dev-developer / dev-tester）注册、默认 cto、
宿主层只有基础设施技能、每个 preset 的技能清单与预期逐字一致、persona 不串味。

### 6.1 权限矩阵

| 会话 | 权限预设 | 沙箱 / 审批 | 由谁设置 |
| --- | --- | --- | --- |
| cto | `workspace-write` | 工作区内可写，每次变更需确认 | `agents/dsh-agent.patch.yml` 的 `defaultPreset` |
| pm | `workspace-write` | 同上 | 同上 |
| dev-leader / dev-developer / dev-tester | `danger-full-access` | 无沙箱限制，不弹审批 | `dsh-agent-dev` 在 `agent/created` 时按 preset 切换 |

为什么 dev 必须完全访问：编码 / 构建 / 验收都要指挥宿主 Docker 与 devcontainer。

**代价与兜底**：`dsh-agent` 挂了宿主 `docker.sock`，preset 只能收窄工具清单、收窄不了进程能力
——cto/pm 的 bash 理论上也能碰 Docker。三个人设都写入了破坏性操作红线：Docker 破坏性命令、
容器/镜像重建、数据删除、强制推送、发布上线，必须先说明影响面并得到人工确认（ADR-5）。

## 7. 排障

- `orphan containers` 告警：旧三台已从 compose 删除，`docker compose up -d --remove-orphans`。
- `worker 'core' 未注册`：看 `docker compose logs dsh-agent | grep dsh-echuan`；
  多半是 `baseUrl`、`worker.poll.enable` 或 `worker.presetByKind` 为空。
- agent 里访问平台 502：代理变量没排除 `host.docker.internal`。compose 已把大小写
  `NO_PROXY` 成对覆盖，自行加变量时保持成对。
- 手机访问 403 `untrusted-host`：把访问用的地址/域名加进 relay 的 `publicHostnames`。
- 手机只看到 403「Not signed in」：Host 已放行，只是没登录 —— 输入 `DSH_RELAY_PASSWORD`。
- `dsh: skipping profile bundle ...`：profile 里残留了没挂载的插件，删掉
  `data/dsh-home-agent/profiles/web/package.json` 里对应的 bundle 与 dependency 后重启。
- `browserless` 401：`BROWSERLESS_TOKEN` 与客户端 token 不一致（所有端点都鉴权）。
- `browserless` 报 `/data` 无权限：镜像内是 `blessuser`（UID 999），
  `chown -R 999:999 data/browserless` 后重启。
- `browserless` 反复重启 / Chrome 崩溃：确认 `shm_size` 为 `2g`。
- 容器里连 `127.0.0.1:3000` 连不上：容器里的 127.0.0.1 是它自己，必须用 `host.docker.internal:3000`。
