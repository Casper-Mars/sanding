#!/usr/bin/env bash
# 部署冒烟：四个服务连通性 + 两个 agent 已在驿传注册为 worker。
#
#   ./scripts/smoke-test.sh
#
# 退出码 0 = 全部通过；非 0 = 有失败项（逐项打印）。
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; . ./.env; set +a

ECHUAN_PORT="${ECHUAN_PORT:-8721}"
DSH_CTO_PORT="${DSH_CTO_PORT:-8090}"
DSH_DEV_PORT="${DSH_DEV_PORT:-8091}"
BROWSERLESS_PORT="${BROWSERLESS_PORT:-3001}"

fail=0
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; fail=$((fail + 1)); }

echo "== 1. 驿传平台 =="
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ECHUAN_PORT}/readyz" || echo 000)
[ "$code" = "200" ] && ok "GET /readyz → 200" || bad "GET /readyz → $code"

echo "== 2. Agent 容器 HTTP =="
# dsh web 默认 token 鉴权，未带 token 返回 401；有响应即说明服务已起。
for pair in "cto-agent:${DSH_CTO_PORT}" "dev-agent:${DSH_DEV_PORT}"; do
  name=${pair%%:*}; port=${pair##*:}
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" || echo 000)
  case "$code" in
    200|401|403) ok "$name :$port → $code（HTTP 已就绪）" ;;
    *)           bad "$name :$port → $code" ;;
  esac
done

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
      bad "GET /json/version → $code（token 不匹配：检查 .env 的 BROWSERLESS_TOKEN）"
      ;;
    000)
      bad "GET /json/version → 000（端口 ${BROWSERLESS_PORT} 无响应：容器未启动 / 端口未发布）"
      ;;
    *)
      bad "GET /json/version → $code：${body:0:120}"
      ;;
  esac
fi

echo "== 4. worker 注册 =="
if curl -s "http://127.0.0.1:${ECHUAN_PORT}/v1/workers" \
  | python3 "$(dirname "$0")/workers.py" --require-active base dev; then
  :
else
  fail=$((fail + 1))
  echo "    提示：检查 dsh-home-*/profiles/web/cordis.patch.yml 的 baseUrl 与 worker.poll.enable"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "冒烟通过。"
  exit 0
fi
echo "冒烟失败项：$fail"
exit 1
