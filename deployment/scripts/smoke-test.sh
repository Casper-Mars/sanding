#!/usr/bin/env bash
# 部署冒烟：三个服务连通性 + 合并 Host 已在驿传注册为 worker。
#
#   ./scripts/smoke-test.sh
#
# 退出码 0 = 全部通过；非 0 = 有失败项（逐项打印）。
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; . ./.env; set +a

ECHUAN_PORT="${ECHUAN_PORT:-8721}"
ECHUAN_HOST="${ECHUAN_BIND:-127.0.0.1}"
DSH_RELAY_PORT="${DSH_RELAY_PORT:-3443}"
BROWSERLESS_PORT="${BROWSERLESS_PORT:-3000}"

fail=0
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; fail=$((fail + 1)); }

echo "== 1. 驿传平台 =="
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${ECHUAN_HOST}:${ECHUAN_PORT}/readyz" || echo 000)
[ "$code" = "200" ] && ok "GET /readyz → 200" || bad "GET /readyz → $code"

echo "== 2. dsh-agent（dsh-relay） =="
# relay 健康端点不需要认证；harness 本身只绑容器回环，宿主侧只能经 3443 验。
relay=$(curl -sk -m 10 "https://127.0.0.1:${DSH_RELAY_PORT}/relay/health" || true)
if printf '%s' "$relay" | grep -q '"service":"dsh-relay"'; then
  ok "GET https://127.0.0.1:${DSH_RELAY_PORT}/relay/health → ok"
else
  bad "GET https://127.0.0.1:${DSH_RELAY_PORT}/relay/health 未返回 dsh-relay 健康响应：${relay:0:120}"
fi

echo "== 3. browserless（无头 Chromium） =="
# 所有端点都需要 token；/json/version 是只读的版本探针，能同时验证鉴权与 Chromium 可用。
if [ -z "${BROWSERLESS_TOKEN:-}" ]; then
  bad "BROWSERLESS_TOKEN 未配置（.env 中必须设置，openssl rand -hex 32）"
else
  resp=$(curl -s -m 10 -w '\n%{http_code}' \
    "http://127.0.0.1:${BROWSERLESS_PORT}/json/version?token=${BROWSERLESS_TOKEN}" || true)
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  case "$code" in
    200)
      if printf '%s' "$body" | grep -q '"webSocketDebuggerUrl"'; then
        ok "GET /json/version → 200（CDP 可用）"
      else
        bad "GET /json/version → 200，但响应不含 webSocketDebuggerUrl：${body:0:120}"
      fi
      ;;
    401|403)
      bad "GET /json/version → ${code}（token 不匹配：检查 .env 的 BROWSERLESS_TOKEN）"
      ;;
    000)
      bad "GET /json/version → 000（端口 ${BROWSERLESS_PORT} 无响应：容器未启动 / 端口未发布）"
      ;;
    *)
      bad "GET /json/version → ${code}：${body:0:120}"
      ;;
  esac
fi

echo "== 4. worker 注册 =="
if curl -s "http://${ECHUAN_HOST}:${ECHUAN_PORT}/v1/workers" \
  | python3 "$(dirname "$0")/workers.py" --require-active; then
  :
else
  fail=$((fail + 1))
  echo "    提示：检查 agents/dsh-agent.patch.yml 的 baseUrl、worker.poll.enable 与 worker.presetByKind"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "冒烟通过。"
  exit 0
fi
echo "冒烟失败项：$fail"
exit 1
