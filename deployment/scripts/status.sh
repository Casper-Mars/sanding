#!/usr/bin/env bash
# 三鼎运行态一览：容器状态 + 驿传 readyz + relay 健康 + worker 注册情况。
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

ECHUAN_PORT="${ECHUAN_PORT:-8721}"
ECHUAN_HOST="${ECHUAN_BIND:-127.0.0.1}"
DSH_RELAY_PORT="${DSH_RELAY_PORT:-3443}"
BROWSERLESS_PORT="${BROWSERLESS_PORT:-3000}"

echo "== 容器 =="
docker compose ps

echo
echo "== 端口探活 =="
printf 'echuan      %s:%s  readyz=%s\n' "$ECHUAN_HOST" "$ECHUAN_PORT" "$(curl -s -o /dev/null -w '%{http_code}' "http://${ECHUAN_HOST}:${ECHUAN_PORT}/readyz" || echo 000)"
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
echo "== GitHub webhook 中继 =="
SMEE_NAME="${SMEE_CONTAINER_NAME:-dsh-smee}"
AGENT_NAME="${DSH_CONTAINER_NAME:-dsh-agent}"
if docker ps --format '{{.Names}}' | grep -qx "$SMEE_NAME"; then
  smee_started=$(docker inspect -f '{{.State.StartedAt}}' "$SMEE_NAME" 2>/dev/null)
  agent_started=$(docker inspect -f '{{.State.StartedAt}}' "$AGENT_NAME" 2>/dev/null)
  # smee 用 network_mode: service:dsh-agent 共享网络命名空间。
  # dsh-agent 后启动 = smee 还挂在旧（已销毁）的 netns 上：DNS/路由全废，
  # webhook 全部丢在 smee.io 云端，本地看不到任何请求。
  if [ -n "$smee_started" ] && [ -n "$agent_started" ] && [[ "$agent_started" > "$smee_started" ]]; then
    printf 'smee        %s  网络已失效（dsh-agent 比 smee 后启动）\n' "$SMEE_NAME"
    printf '            修复：docker compose up -d --force-recreate --no-deps smee\n'
  else
    printf 'smee        %s  %s\n' "$SMEE_NAME" "$(docker logs --tail 1 "$SMEE_NAME" 2>&1 | tail -1)"
  fi
else
  printf 'smee        未运行 —— GitHub webhook 不会送达 dsh-agent:/github\n'
fi

echo
echo "== 已注册 worker =="
curl -s "http://${ECHUAN_HOST}:${ECHUAN_PORT}/v1/workers" | python3 "$(dirname "$0")/workers.py" \
  || echo "  (查询失败：驿传未就绪?)"
