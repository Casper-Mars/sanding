#!/usr/bin/env bash
# 三鼎运行态一览：容器状态 + 驿传 readyz + relay 健康 + worker 注册情况。
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

ECHUAN_PORT="${ECHUAN_PORT:-8721}"
DSH_RELAY_PORT="${DSH_RELAY_PORT:-3443}"
BROWSERLESS_PORT="${BROWSERLESS_PORT:-3000}"

echo "== 容器 =="
docker compose ps

echo
echo "== 端口探活（本机回环） =="
printf 'echuan      127.0.0.1:%s  readyz=%s\n' "$ECHUAN_PORT" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ECHUAN_PORT}/readyz" || echo 000)"
printf 'dsh-agent   127.0.0.1:%s  relay/health=%s\n' "$DSH_RELAY_PORT" "$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${DSH_RELAY_PORT}/relay/health" || echo 000)"

# browserless 所有端点都鉴权；未配置 token 时只提示，不算失败。
if [ -n "${BROWSERLESS_TOKEN:-}" ]; then
  # curl 连不上时自己也会输出 000，这里只兜底空值，避免拼成 000000
  bl_code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${BROWSERLESS_PORT}/json/version?token=${BROWSERLESS_TOKEN}" 2>/dev/null || true)
  [ -n "$bl_code" ] || bl_code=000
  printf 'browserless 127.0.0.1:%s  cdp=%s\n' "$BROWSERLESS_PORT" "$bl_code"
  [ "$bl_code" = "200" ] || echo "  (提示：browserless 未就绪或 token 不匹配，不影响其它服务)"
else
  printf 'browserless 127.0.0.1:%s  cdp=skipped（未配置 BROWSERLESS_TOKEN）\n' "$BROWSERLESS_PORT"
fi

echo
echo "== 已注册 worker =="
curl -s "http://127.0.0.1:${ECHUAN_PORT}/v1/workers" | python3 "$(dirname "$0")/workers.py" \
  || echo "  (查询失败：驿传未就绪?)"
