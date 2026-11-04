# 三鼎（Sanding）

人、Agent、平台三层协作的交付系统。系统叫「三鼎」——人、Agent、平台三足鼎立，缺一足则倾；鼎亦是百工所铸的重器。

平台（协调面）仍叫「驿传」。系统原名「百工」，2026-11-04 定名「三鼎」。

架构文档：《百工 交付系统架构设计 v3.5》
https://ecn3asgw8dff.feishu.cn/wiki/H5m4wpOFoiu3Wvk6JAYc7ZMcnsd

## 本仓库是什么

**只有部署，不含源码。** 三个组成组件各自独立成仓，本仓库负责把它们作为一套系统编排、启动、验证：

| 服务 | 角色 | 仓库 |
| --- | --- | --- |
| `echuan` | 驿传平台（协调面：需求/方案/任务/交付/待办/审计） | `../echuan_v2` |
| `cto-agent` | CTO Agent（dsh + dsh-rsi-agent + dsh-domain + dsh-echuan） | `../dsh-agent/dsh-agent-base` |
| `dev-agent` | 开发 Agent（dsh + dsh-rsi-agent + dsh-dev-domain + dsh-echuan + docker/devcontainer） | `../dsh-agent/dsh-dev-agent` |

## 目录

```
sanding/
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
