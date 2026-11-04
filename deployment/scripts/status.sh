#!/usr/bin/env bash
# 百工运行态一览：容器状态 + 驿传 readyz + worker 注册情况。
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

ECHUAN_PORT="${ECHUAN_PORT:-8721}"
DSH_BASE_PORT="${DSH_BASE_PORT:-8090}"
DSH_DEV_PORT="${DSH_DEV_PORT:-8091}"

echo "== 容器 =="
docker compose ps

echo
echo "== 端口探活（本机回环） =="
printf 'echuan    127.0.0.1:%s  readyz=%s\n' "$ECHUAN_PORT" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ECHUAN_PORT}/readyz" || echo 000)"
printf 'cto-agent 127.0.0.1:%s  http=%s\n'   "$DSH_BASE_PORT" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DSH_BASE_PORT}/" || echo 000)"
printf 'dev-agent 127.0.0.1:%s  http=%s\n'   "$DSH_DEV_PORT" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DSH_DEV_PORT}/" || echo 000)"

echo
echo "== 已注册 worker =="
curl -s "http://127.0.0.1:${ECHUAN_PORT}/v1/workers" | python3 "$(dirname "$0")/workers.py" \
  || echo "  (查询失败：驿传未就绪?)"
