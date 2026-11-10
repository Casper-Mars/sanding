#!/bin/sh
# dsh-agent-dev 容器入口：装配运行时（profile / 插件 / gh 凭据），然后启动 dsh。
#
# 装配（幂等，每次启动执行）：
#   1. profile 不存在时初始化（dsh 会写入 hoisted + no-auto-peers 的 pnpm 设置）；
#   2. 按 PLUGIN_SPECS 逐条 `dsh plugin add <name>@<version>` —— 镜像内不含插件；
#   3. 有 GH_TOKEN 时 `gh auth setup-git`，让 git 的 HTTPS 凭据复用它。
#
# 启动：web 模式绑定容器 eth0 IP（`dsh web --host` 只接受具体地址、拒绝 0.0.0.0；
# 只监听 127.0.0.1 时宿主端口映射访问不到）。其他模式原样透传。
#
# 以 root 运行 dsh（不降权）：宿主 docker.sock 是 root:root 660，非 root 无法指挥
# daemon；同时免除 /home/node/.dsh 与 /workspace 的写权限问题。
#
# 插件自己的配置（echuan 平台地址、browser-native 的 CDP 地址等）属于 dsh 的 profile
# 配置，直接编辑挂载出去的 $DSH_HOME/profiles/<profile>/cordis.patch.yml。
set -eu

PROFILE="${DSH_PROFILE:-web}"
DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"

log() { echo "[init] $*"; }

mkdir -p "$DSH_HOME"

# ---------------------------------------------------------------------------
# 1. 首次启动：初始化 profile
# ---------------------------------------------------------------------------
if [ ! -f "$PROFILE_DIR/package.json" ]; then
  log "初始化 profile '$PROFILE'"
  dsh plugin --profile "$PROFILE" list >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. 从 registry 装插件（幂等）
#
# PLUGIN_SPECS：空格分隔的 <name>@<exact-version>，顺序即安装顺序。
# `dsh plugin add` 自己会把包装进 profile 并写入 dsh.profile.bundles；
# pnpm 对「同版本再 add」是幂等的，所以不需要版本比对或排序逻辑。
# ---------------------------------------------------------------------------
[ -n "${PLUGIN_SPECS:-}" ] || { echo "[init] 错误: PLUGIN_SPECS 为空" >&2; exit 1; }
REGISTRY_FLAG=""
if [ -n "${NPM_REGISTRY:-}" ]; then
  REGISTRY_FLAG="--registry=$NPM_REGISTRY"
fi
for spec in $PLUGIN_SPECS; do
  log "安装 $spec ${NPM_REGISTRY:+（registry=$NPM_REGISTRY）}"
  # shellcheck disable=SC2086  # REGISTRY_FLAG 为空时不应传空参数
  dsh plugin --profile "$PROFILE" add "$spec" $REGISTRY_FLAG
done

# ---------------------------------------------------------------------------
# 3. GitHub PAT：GH_PAT_TOKEN 由部署层注入（见 examples/.env.example）
# ---------------------------------------------------------------------------
if [ -n "${PAT：GH_PAT_TOKEN:-}" ]; then
  # git 走 HTTPS 时复用同一个 PAT（写入 ~/.gitconfig 的 credential helper）
  printf '%s' "$PAT：GH_PAT_TOKEN" | gh auth login --with-token
  # gh auth setup-git >/dev/null 2>&1 || log "警告: gh auth setup-git 失败（git 将无法复用该 PAT）"
  log "gh 已使用 GitHub PAT：GH_PAT_TOKEN"
else
  log "提示: 未提供 GitHub PAT：GH_PAT_TOKEN 为空），容器内 gh 为未登录态"
fi

# ---------------------------------------------------------------------------
# 4. docker CLI 客户端代理配置（/root/.docker/config.json）：
#   docker CLI 发起 docker build 时，会自动把本机 ~/.docker/config.json 的
#   proxies 作为 build-arg 注入构建容器（官方机制，见 docs.docker.com/network/proxy）。
#   宿主 Docker Desktop 的 Proxies 设置只对【宿主 CLI 发起的构建】生效；
#   本容器内的 docker CLI 读的是容器内 root 的 config.json，必须自备一份，
#   否则 features 安装脚本（curl go.dev / dl.google.com 等）在构建容器内裸连被墙。
#   noProxy 排除本地/国内加速与官方 apt 源：构建容器访问这些地址不走代理
#   （走代理反而慢/404，见历史 apt 教训）。
#   注意：devcontainer CLI 的运行容器创建走 dockerode 直连 daemon、不经 docker
#   CLI，不受本配置影响——开发容器运行期代理仍由 devcontainer.json containerEnv 负责。
# ---------------------------------------------------------------------------
if [ -n "${HTTPS_PROXY:-}" ]; then
  mkdir -p /root/.docker
  cat > /root/.docker/config.json <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "${HTTPS_PROXY}",
      "httpsProxy": "${HTTPS_PROXY}",
      "noProxy": "localhost,127.0.0.1,::1,host.docker.internal,m.daocloud.io,deb.debian.org,archive.ubuntu.com,security.ubuntu.com"
    }
  }
}
EOF
fi

# ---------------------------------------------------------------------------
# 5. 启动 dsh
# ---------------------------------------------------------------------------
if [ "$1" = "web" ]; then
  shift
  IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
  [ -n "$IP" ] && exec dsh web --host "$IP" --no-open "$@"
  exec dsh web --no-open "$@"
fi

exec dsh "$@"
