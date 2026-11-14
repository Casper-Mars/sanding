#!/usr/bin/env bash
# 设置 / 轮换 dsh-relay 的登录密码。
#
# 背景：relay 只接受「从运行 harness 的机器」设置密码。容器化部署里那台机器
# 就是容器本身，所以从宿主或手机打开 /relay/password 会被拒：
#   "Set the password from the machine running the harness."
# 本脚本从容器内 loopback 发起，因此始终被认作 operator。
#
# 用法：
#   ./scripts/relay-password.sh                # 读 .env 的 DSH_RELAY_PASSWORD
#   ./scripts/relay-password.sh 'my-password'  # 或命令行显式给（≥10 字符）
set -euo pipefail
cd "$(dirname "$0")/.."

# 只读需要的键，不 source .env：.env 里有含空格的值（PLUGIN_SPECS），source 会炸
read_env() {
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

PW="${1:-$(read_env DSH_RELAY_PASSWORD)}"
[ -n "$PW" ] || { echo "错误：未提供密码（.env 的 DSH_RELAY_PASSWORD，或第一个参数）" >&2; exit 1; }
[ "${#PW}" -ge 10 ] || { echo "错误：relay 要求密码至少 10 个字符（当前 ${#PW}）" >&2; exit 1; }

CN="$(read_env DSH_CONTROL_PLANE_CONTAINER_NAME)"
CN="${CN:-dsh-control-plane}"

code="$(docker compose exec -T "$CN" \
  curl -k -s -o /dev/null -w '%{http_code}' \
  -X POST --data-urlencode "password=$PW" https://127.0.0.1:3443/relay/password)"

case "$code" in
  302|303) echo "✅ relay 密码已设置 (HTTP ${code})" ;;
  400)     echo "❌ relay 拒绝了该密码 (HTTP 400，通常是不满足强度要求)" >&2; exit 1 ;;
  *)       echo "❌ 设置失败: HTTP ${code}" >&2; exit 1 ;;
esac
