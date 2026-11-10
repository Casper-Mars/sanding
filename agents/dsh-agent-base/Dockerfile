# syntax=docker/dockerfile:1
#
# dsh-agent-base 镜像：角色型 Agent（CTO / PM）的通用基座 + 启动时从 npm 安装插件
#
# 设计边界（重要）：
#   1. 镜像【不包含】任何业务插件。装哪个角色由部署时的 PLUGIN_SPECS 决定 ——
#      CTO 与 PM 用同一个镜像，只是插件清单不同。
#   2. 镜像只提供运行时：dsh + git + pnpm。不含 docker CLI / devcontainer CLI / gh
#      （那是 dsh-agent-dev 的能力；角色 Agent 不做代码交付）。
#   3. 插件不入镜像、不挂宿主目录，也不需要宿主编译。
#
# 构建：  docker build -t dsh-agent-base:local .


# ---------------------------------------------------------------------------
# 运行时镜像
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS runtime

# 国内镜像源（构建加速）。默认阿里云 apt + npmmirror npm；
# apt 用 http 协议：node:22-bookworm-slim 基础镜像不含 ca-certificates 包，
#   apt 访问 https 源会报 "certificate issuer is unknown"（证书验证失败）。
ARG APT_MIRROR=http://mirrors.aliyun.com/debian
ARG APT_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security
ARG NPM_REGISTRY=https://registry.npmmirror.com

# dsh 版本钉死（不用 latest）：npm 上 @deepseek-ai/dsh-* 的 latest 是 0.0.1-rc.1，
# 与插件 peer 要求不兼容，会被 dsh 兼容性守卫拒绝。
ARG DSH_VERSION=0.2.1-rc.2

# pnpm 版本：与插件仓库 packageManager 字段一致
ARG PNPM_VERSION=11.7.0

# GitHub CLI 版本：与宿主 gh 对齐（2.95.0）。升级时显式改这里。
# 镜像只装官方 release 的 .deb，不含任何凭据。
ARG GH_VERSION=2.95.0

# 构建期访问 github.com 的代理（留空 = 直连 / 沿用 Docker Desktop 注入的构建代理）
ARG GH_PROXY=

# 系统依赖：git（dsh 工作流 / 项目根探测）、ca-certificates、bubblewrap（命令级沙箱）。
# 容器以 root 运行 dsh（不降权）：root 免除 dsh home 与 workspace 的写权限问题。
RUN set -eux; \
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy FTP_PROXY ftp_proxy NO_PROXY no_proxy || true; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    printf 'deb %s bookworm main\ndeb %s bookworm-updates main\ndeb %s bookworm-security main\n' \
      "$APT_MIRROR" "$APT_MIRROR" "$APT_SECURITY_MIRROR" > /etc/apt/sources.list; \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates bubblewrap curl \
 && rm -rf /var/lib/apt/lists/*

 # ---------------------------------------------------------------------------
# GitHub CLI（gh）：
#   官方 release 的 .deb（按 dpkg 架构选包），版本钉死 + checksums 校验。
#   镜像只装二进制，不含任何令牌；PAT 在运行时由部署层以 GH_TOKEN 注入（见 entrypoint.sh）。
#   注意：.deb 必须保留官方文件名，checksums.txt 里记录的是原文件名。
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -n "$GH_PROXY" ]; then \
      export HTTP_PROXY="$GH_PROXY" HTTPS_PROXY="$GH_PROXY" \
             http_proxy="$GH_PROXY" https_proxy="$GH_PROXY"; \
    fi; \
    arch="$(dpkg --print-architecture)"; \
    deb="gh_${GH_VERSION}_linux_${arch}.deb"; \
    base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o "/tmp/${deb}" "${base}/${deb}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/gh.sha256 "${base}/gh_${GH_VERSION}_checksums.txt"; \
    ( cd /tmp && grep " ${deb}\$" gh.sha256 | sha256sum -c - ); \
    dpkg -i "/tmp/${deb}"; \
    rm -f "/tmp/${deb}" /tmp/gh.sha256; \
    gh --version

# gh 的容器内配置（非机密，随镜像发布）：
#   容器里没有宿主 keychain，git 操作一律走 HTTPS + 令牌，
#   避免因为没有 ssh key（或 key 带 passphrase）而失败。
RUN mkdir -p /root/.config/gh \
 && printf 'git_protocol: https\nprompt: disabled\n' > /root/.config/gh/config.yml

ENV GH_CONFIG_DIR=/root/.config/gh \
    GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1

# DeepSeek Harness + pnpm（npm 走国内 npmmirror 镜像）
#   pnpm 用 corepack 激活：`dsh plugin` 会把参数转发给 pnpm，运行期必需。
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN set -eux; \
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy FTP_PROXY ftp_proxy NO_PROXY no_proxy || true; \
    npm config set --global registry "$NPM_REGISTRY"; \
    printf 'registry=%s\n' "$NPM_REGISTRY" > /root/.npmrc; \
    npm install --global "@deepseek-ai/dsh@${DSH_VERSION}"; \
    corepack enable; \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate; \
    pnpm --version; \
    npm cache clean --force

# 入口：装配（profile / 插件）+ 启动（eth0 绑定 + dsh web）
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# 数据目录预建（profile / 插件安装结果落在挂载出来的 dsh home）
RUN mkdir -p /home/node/.dsh

WORKDIR /workspace

EXPOSE 3080
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web"]
