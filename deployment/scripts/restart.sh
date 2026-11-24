#!/usr/bin/env bash
# 强制重启：删除本地镜像 → 重新拉取 → 重建容器 → 等 healthy。
#
# 默认只处理 echuan；目前支持从 registry 拉取的服务：
#   echuan / browserless
# dsh-agent 是本地构建镜像（dsh-agent-dev:local），不能走这个脚本，请用 ./scripts/up.sh --build。
#
# 用法：
#   ./scripts/restart.sh                 # 强制重启 echuan
#   ./scripts/restart.sh browserless     # 强制重启 browserless
#   ./scripts/restart.sh --all           # echuan + browserless
#   ./scripts/restart.sh --yes echuan    # 跳过确认
#   ./scripts/restart.sh --dry-run       # 只打印将要执行的命令，不删不拉
#
# 数据都在 bind mount（./data、./echuan/data），删容器/镜像不影响数据；
# 但期间目标服务会中断，browserless 重启还会中断正在跑的浏览器任务。
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env：先在 deployment/ 下配置" >&2; exit 1; }

YES=0
DRY=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    --all) TARGETS=(echuan browserless) ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) TARGETS+=("$arg") ;;
  esac
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=(echuan)
fi

for svc in "${TARGETS[@]}"; do
  case "$svc" in
    echuan|browserless) ;;
    *)
      echo "不支持的服务：$svc" >&2
      echo "只支持 echuan / browserless；dsh-agent 是本地构建镜像，请用 ./scripts/up.sh --build" >&2
      exit 2
      ;;
  esac
done

# 从 compose 解析镜像名（会读取 .env，且不依赖 jq）
CONFIG=$(docker compose config --format json)
image_of() {
  printf '%s' "$CONFIG" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$1"
}
digest_of() {
  docker image inspect "$1" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | sed 's/.*@//' || true
}
remote_ok() {
  if docker buildx version >/dev/null 2>&1; then
    docker buildx imagetools inspect "$1" >/dev/null 2>&1
  else
    docker manifest inspect "$1" >/dev/null 2>&1
  fi
}

echo "== 目标 =="
for svc in "${TARGETS[@]}"; do
  image=$(image_of "$svc")
  echo "  $svc"
  echo "    镜像: $image"
  echo "    本地: $(digest_of "$image" || true)"
done

if [ "$YES" -ne 1 ]; then
  echo
  read -r -p "将删除以上本地镜像并重建容器，期间服务中断。继续？[y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "已取消"; exit 1 ;;
  esac
fi

for svc in "${TARGETS[@]}"; do
  image=$(image_of "$svc")
  echo
  echo "== 重建 $svc =="

  # 先确认远端可达/有权限，避免删了本地才发现拉不到
  if ! remote_ok "$image"; then
    echo "远端不可达或无权限：$image" >&2
    echo "私有 ACR 先执行：docker login registry.cn-hangzhou.aliyuncs.com" >&2
    exit 1
  fi
  echo "远端可达"

  if [ "$DRY" -eq 1 ]; then
    echo "[dry-run] docker compose rm -sf $svc"
    echo "[dry-run] docker rmi $image"
    echo "[dry-run] docker compose pull $svc"
    echo "[dry-run] docker compose up -d $svc"
    continue
  fi

  docker compose rm -sf "$svc" >/dev/null 2>&1 || true
  if docker image inspect "$image" >/dev/null 2>&1; then
    if ! docker rmi "$image" >/dev/null; then
      echo "删除本地镜像失败（可能被其他容器占用）；恢复 $svc" >&2
      docker compose up -d "$svc" >/dev/null 2>&1 || true
      exit 1
    fi
    echo "已删除本地镜像: $image"
  else
    echo "本地无该镜像，跳过删除"
  fi

  docker compose pull "$svc"
  docker compose up -d "$svc"

  # 等健康检查通过
  deadline=$((SECONDS + 180))
  while :; do
    cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
    state="missing"
    has_health="no"
    if [ -n "$cid" ]; then
      state=$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo unknown)
      has_health=$(docker inspect "$cid" --format '{{if .State.Health}}yes{{else}}no{{end}}' 2>/dev/null || echo no)
    fi
    if { [ "$has_health" = "yes" ] && [ "$state" = "healthy" ]; } || { [ "$has_health" = "no" ] && [ "$state" = "running" ]; }; then
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "超时：$svc 未就绪（状态 $state）" >&2
      docker compose logs --tail=80 "$svc" >&2 || true
      exit 1
    fi
    sleep 3
  done

  echo "完成: $svc"
  echo "  新 digest: $(digest_of "$image" || true)"
done

echo
echo "全部完成。"
