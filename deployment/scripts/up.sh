#!/usr/bin/env bash
# 拉起三鼎全部服务（驿传 + 合并 Host + browserless），并等到 healthy。
#
#   ./scripts/up.sh              # 用已有镜像启动（缺镜像时 compose 自动拉）
#   ./scripts/up.sh --pull       # 先拉取 ACR 上的 echuan:latest 再启动
#   ./scripts/up.sh --build      # 用本地源码重建 echuan 镜像再启动
#
# 依赖：宿主机 docker、docker compose v2。
# 私有 ACR 需先登录一次：docker login registry.cn-hangzhou.aliyuncs.com
set -euo pipefail

cd "$(dirname "$0")/.."

[ -f .env ] || { echo "缺少 .env：先执行 cp .env.example .env 并填写路径" >&2; exit 1; }

BUILD=0
PULL=0
passthru=()
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --pull)  PULL=1 ;;
    *) passthru+=("$a") ;;
  esac
done

COMPOSE=(docker compose)
if [ "$BUILD" -eq 1 ]; then
  # 本地构建覆盖层：docker-compose.yml 本身只拉 ACR 镜像，不含 build 段。
  COMPOSE+=(-f docker-compose.yml -f docker-compose.build.yml)
fi

echo "== 启动（项目名 $(grep -E '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2 || echo sanding)） =="

if [ "$BUILD" -eq 1 ]; then
  echo "== 本地构建 echuan 镜像（源码 $(grep -E '^ECHUAN_SRC=' .env | cut -d= -f2-)） =="
  "${COMPOSE[@]}" build echuan
elif [ "$PULL" -eq 1 ]; then
  echo "== 拉取 echuan 镜像（私有仓库，需先 docker login） =="
  "${COMPOSE[@]}" pull echuan
fi

"${COMPOSE[@]}" up -d ${passthru[@]+"${passthru[@]}"}

echo
echo "== 等待健康检查 =="
deadline=$((SECONDS + 180))
while :; do
  unhealthy=$(docker compose ps --format '{{.Name}} {{.State}} {{.Status}}' | grep -vE 'running \(healthy\)' || true)
  if [ -z "$unhealthy" ]; then
    docker compose ps
    echo "全部服务 healthy。"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "超时：以下服务仍未 healthy" >&2
    echo "$unhealthy" >&2
    docker compose ps >&2
    exit 1
  fi
  sleep 3
done
