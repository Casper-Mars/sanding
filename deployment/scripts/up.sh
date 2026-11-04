#!/usr/bin/env bash
# 拉起三鼎全部服务（驿传 + CTO Agent + 开发 Agent），并等到 healthy。
#
#   ./scripts/up.sh              # 用已有镜像启动
#   ./scripts/up.sh --build      # 先重建镜像再启动
#
# 依赖：宿主机 docker、docker compose v2。
set -euo pipefail

cd "$(dirname "$0")/.."

[ -f .env ] || { echo "缺少 .env：先执行 cp .env.example .env 并填写路径" >&2; exit 1; }

echo "== 启动（项目名 $(grep -E '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2 || echo sanding)） =="
docker compose up -d "$@"

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
