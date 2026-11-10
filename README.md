# 三鼎（Sanding）

人、Agent、平台三层协作的交付系统。系统叫「三鼎」——人、Agent、平台三足鼎立，缺一足则倾；鼎亦是百工所铸的重器。

平台（协调面）仍叫「驿传」。系统原名「百工」，2026-11-04 定名「三鼎」。

架构文档：《百工 交付系统架构设计 v3.5》
https://ecn3asgw8dff.feishu.cn/wiki/H5m4wpOFoiu3Wvk6JAYc7ZMcnsd

## 本仓库是什么

**以部署为主，含两个 Agent 镜像的源码。** `agents/dsh-agent-base`（cto / pm 共用，角色由插件清单决定）与 `agents/dsh-agent-dev`，其余组件各自独立成仓：

| 服务 | 角色 | 仓库 |
| --- | --- | --- |
| `echuan` | 驿传平台（协调面：需求/方案/任务/交付/待办/审计） | `../echuan_v2` |
| `cto-agent` | CTO Agent（dsh-agent-base 镜像 + cto 插件组） | `agents/dsh-agent-base`（本仓库） |
| `pm-agent` | 产品经理 Agent（同一镜像 + pm 插件组） | `agents/dsh-agent-base`（本仓库） |
| `dev-agent` | 开发 Agent（dsh + 插件 + docker/devcontainer） | `agents/dsh-agent-dev`（本仓库） |
| `dsh-web-control` | Web 控制面：一个界面管 cto / pm / dev（开发预览，非 compose 服务） | `../dsh-web-control` |

Web 控制面（`dsh-web-control`）是**可选组件**：不在本仓库，也不进 `deployment` 的 compose，
而是宿主上独立起的进程，通过三个 Agent 的宿主回环端口接入，只做接入 / 路由 / 呈现 / 审计。
任务编排、重试与验收仍归驿传。启动方式见
[deployment/README.md](deployment/README.md#6-web-控制面可选开发态)。

## 目录

```
sanding/
├── agents/
│   ├── dsh-agent-base/  # 角色 Agent 基座镜像（cto / pm 共用；examples/ 是部署示例）
│   └── dsh-agent-dev/   # 开发 Agent 镜像（含 docker / devcontainer / gh）
└── deployment/          # 统一 docker compose 部署
    ├── docker-compose.yml
    ├── .env.example     # 配置模板（.env 本机私有，已 git 忽略）
    ├── scripts/         # up / down / status / smoke-test
    ├── data/            # 运行期 dsh home（git 忽略）
    └── secrets/         # gh 令牌等（git 忽略）
```

## 快速开始

```bash
cd deployment
cp .env.example .env      # 填源码路径、工作区、数据目录
./scripts/up.sh
./scripts/smoke-test.sh
```

详见 [deployment/README.md](deployment/README.md)。
