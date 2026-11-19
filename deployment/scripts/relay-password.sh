#!/usr/bin/env bash
# 设置 / 轮换 dsh-relay 的登录密码。
#
# 背景：relay 只接受「从运行 harness 的机器」设置密码。容器化部署里那台机器
# 就是容器本身，所以从宿主或手机打开 /relay/password 会被拒：
#   "Set the password from the machine running the harness."
# 本脚本从容器内 loopback 发起，因此始终被认作 operator。
#
# 用法：
#   ./scripts/relay-password.sh                      # 合并 Host（dsh-agent）
#   ./scripts/relay-password.sh --one                # 一体化主智能体（dsh-agent-one）
#   ./scripts/relay-password.sh --container dsh-xxx  # 指定任意容器
#   ./scripts/relay-password.sh --one 'my-password'  # 显式给密码（≥10 字符）
#
# 不给密码时读 .env 的 DSH_RELAY_PASSWORD；容器名默认取 .env 的
# DSH_MERGED_CONTAINER_NAME / DSH_ONE_CONTAINER_NAME，再回落固定值。
# 环境变量 RELAY_CONTAINER 仍可覆盖默认容器。
set -euo pipefail
cd "$(dirname "$0")/.."

# 只读需要的键，不 source .env：.env 里有含空格的值（PLUGIN_SPECS），source 会炸
read_env() {
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

usage() {
  sed -n '2,17p' "$0" | sed -e 's/^# \{0,1\}//'
}

CN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --one)
      CN="$(read_env DSH_ONE_CONTAINER_NAME)"
      CN="${CN:-dsh-agent-one}"
      shift
      ;;
    --container|-c)
      [ $# -ge 2 ] || { echo "错误：$1 需要一个容器名" >&2; exit 1; }
      CN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "错误：未知选项 $1（-h 看用法）" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

PW="${1:-$(read_env DSH_RELAY_PASSWORD)}"
[ -n "$PW" ] || { echo "错误：未提供密码（.env 的 DSH_RELAY_PASSWORD，或最后一个参数）" >&2; exit 1; }
[ "${#PW}" -ge 10 ] || { echo "错误：relay 要求密码至少 10 个字符（当前 ${#PW}）" >&2; exit 1; }

if [ -z "$CN" ]; then
  CN="${RELAY_CONTAINER:-$(read_env DSH_MERGED_CONTAINER_NAME)}"
  CN="${CN:-dsh-agent}"
fi

# 容器不在跑就没必要继续（docker compose exec 会报难看的长错）
docker compose ps --status running --format '{{.Name}}' | grep -qx "$CN" \
  || { echo "错误：容器 $CN 不在运行（docker compose ps 看一眼）" >&2; exit 1; }

echo "目标容器：$CN"
code="$(docker compose exec -T "$CN" \
  curl -k -s -o /dev/null -w '%{http_code}' \
  -X POST --data-urlencode "password=$PW" https://127.0.0.1:3443/relay/password)"

case "$code" in
  302|303) echo "✅ relay 密码已设置 (HTTP ${code})" ;;
  400)     echo "❌ relay 拒绝了该密码 (HTTP 400，通常是不满足强度要求)" >&2; exit 1 ;;
  *)       echo "❌ 设置失败: HTTP ${code}" >&2; exit 1 ;;
esac
