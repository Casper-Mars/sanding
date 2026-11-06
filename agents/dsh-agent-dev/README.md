# dsh-agent-dev

开发用 Agent 镜像：以 [`dsh-agent-devcontainer`](../../../dsh-agent-devcontainer) 为基础，把 dsh、docker CLI、
devcontainer CLI、git、gh 等运行时装进镜像；业务插件（dev 领域、驿传接入、浏览器工具）**不进镜像**，
容器启动时按 `PLUGIN_SPECS` 从 npm registry 装进 profile。

| 能力 | 来源 |
|---|---|
| dsh + docker CLI + devcontainer CLI（均为客户端）+ git + pnpm + gh | 镜像 |
| `dev-container` 技能、`dsh-agent-dev`（dev 领域 + Leader/Developer/Tester preset） | npm 包 `dsh-agent-dev` |
| `dsh-agent-base`（基座能力） | npm 包 `dsh-agent-base` |
| `dsh-echuan`（驿传平台接入） | npm 包 `dsh-echuan` |
| `dsh-browser-native`（浏览器工具，走 CDP） | npm 包 `dsh-browser-native` |

镜像：`dsh-agent-dev:local`

## 构建

```bash
docker build -t dsh-agent-dev:local .
```

构建参数（`--build-arg`）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `DSH_VERSION` | `0.2.1-rc.2` | 镜像内 `@deepseek-ai/dsh` 版本；插件 peer 钉在同一版本，改它需同步插件 |
| `GH_VERSION` | `2.95.0` | gh 官方 release 版本（下载后校验 checksums） |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | 构建期 npm 源 |
| `APT_MIRROR` / `APT_SECURITY_MIRROR` | 阿里云 | 构建期 apt 源 |
| `PNPM_VERSION` | `11.7.0` | corepack 激活的 pnpm 版本（与插件 `packageManager` 一致） |
| `GH_PROXY` | 空 | 构建期下载 gh 的代理，留空沿用 Docker Desktop 注入的构建代理 |

镜像**不含任何凭据**，也不含插件源码。

## 容器启动时做什么

`entrypoint.sh`（镜像入口）幂等执行：

1. **profile 初始化**：`$DSH_HOME/profiles/<profile>` 不存在时用 `dsh plugin list` 初始化
   （dsh 会写入 `nodeLinker: hoisted` + `autoInstallPeers: false` 的 pnpm 设置）。
2. **装插件**：按 `PLUGIN_SPECS` 逐条 `dsh plugin add <name>@<version> --registry=<NPM_REGISTRY>`。
   `add` 自己写 `dsh.profile.bundles`，pnpm 对同版本重复 add 幂等，所以不需要任何中间工具。
3. **gh 凭据**：有 `GH_TOKEN` 时执行 `gh auth setup-git`，git 的 HTTPS 操作复用同一个 PAT。
4. **启动**：`web` 模式自动绑定容器 eth0 IP（`dsh web --host` 拒绝 `0.0.0.0`，只绑 127.0.0.1 宿主访问不到）；
   其他模式原样透传。

**peer 依赖为什么不会被复制**：profile 的 `pnpm-workspace.yaml` 是 `nodeLinker: hoisted` +
`autoInstallPeers: false`，插件的 `@deepseek-ai/*` peer 走 dsh 安装目录的运行时解析，全进程共用一份实例。
若 peers 被装进 profile，`dsh-tools` 的 `TOOL_RUNTIME_SCHEDULER` Symbol 会分裂，任何工具调用都报
`Cannot read properties of undefined (reading 'prepare')`。

插件自己的配置（echuan 平台地址、browser-native 的 CDP 地址等）属于 dsh 的 profile 配置，
写在 `$DSH_HOME/profiles/<profile>/cordis.patch.yml`，不由部署层注入。

## 部署示例

`examples/` 是**部署示例**，不是项目主体：一份 compose + 一份 `.env.example` + 一个冒烟脚本。

```bash
cd examples
cp .env.example .env      # 设置 HOST_PROJECT_PATH（插件版本在 PLUGIN_SPECS 里）
docker compose up -d --build
./smoke-test.sh
```

- Web UI：`http://127.0.0.1:3081/`（token 见 `docker compose logs`）
- 容器名 `dsh-agent-dev`，挂宿主 docker.sock 供 devcontainer CLI 指挥宿主 daemon
- 项目目录按宿主路径挂进 `/workspace`，`--workspace-folder` 可直接工作

主要变量见 `examples/.env.example`；完整清单在文件内有注释。

### GitHub PAT

镜像内置官方 `gh`，不含凭据。PAT 写在 `examples/.env`（已 gitignore），compose 注入 `GH_TOKEN`：

```bash
echo 'GH_TOKEN=<classic PAT，scope: repo / read:org>' >> examples/.env
```

换 PAT 只改这一行后 `docker compose up -d`，不需要交互登录。
注意 `.env` 里的 PAT 对 `docker inspect` / `docker compose config` 可见，别同步到云盘。

## 更新插件

插件不在镜像里，**改插件版本不需要重建镜像**：

```bash
# 插件仓库：改版本号 → build → publish
pnpm -C ../dsh-plugins/dsh-agent-dev build && npm publish

# 部署侧：改 examples/.env 的 PLUGIN_SPECS，重启
docker compose up -d
```

回滚同理。npmmirror 对刚发布的版本有分钟级延迟，急的话临时把 `NPM_REGISTRY` 指到官方源。

## 目录

```text
Dockerfile                  镜像构建（两阶段：docker-cli / 运行时）
entrypoint.sh               容器入口：profile 初始化 → 装插件 → gh → 启动 dsh
examples/                   部署示例：compose / .env.example / smoke-test.sh
```

## 已知边界

- 镜像不含模型 API Key；首次访问 Web UI 自己配。
- devcontainer 的实际构建发生在宿主 Docker daemon，镜像内只有客户端。
- 插件必须可从 registry 取到；`PLUGIN_SPECS` 也接受 tarball / git spec，但该包需自带构建产物。
- 插件装在 `DSH_HOME_DIR` 挂出来的 profile 里：换 home 目录等于重装插件。
