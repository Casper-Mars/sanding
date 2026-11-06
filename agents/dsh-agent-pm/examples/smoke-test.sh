#!/usr/bin/env bash
# dsh-agent-pm 冒烟验证：容器健康 → dev-container 无关项省略 → 插件已装
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/3 容器健康 =="
state="$(docker inspect -f '{{.State.Health.Status}}' dsh-agent-pm 2>/dev/null || echo unknown)"
echo "health=$state"
[ "$state" = "healthy" ] || { echo "FAIL：容器未 healthy"; docker compose ps; exit 1; }

echo "== 2/3 dsh web 监听 =="
docker compose exec -T dsh sh -c 'hostname -i' >/dev/null
docker compose logs --tail 20 dsh 2>&1 | grep -q "dsh web: listening" || { echo "FAIL：dsh web 未监听"; exit 1; }
echo "ok"

echo "== 3/3 插件已装配 =="
docker compose exec -T dsh sh -c '
  for spec in $PLUGIN_SPECS; do
    name="${spec%@*}"
    path="$DSH_HOME/profiles/${DSH_PROFILE:-web}/node_modules/$name/package.json"
    [ -f "$path" ] || { echo "FAIL：$name 未安装"; exit 1; }
    echo "ok $spec"
  done'

echo "OK：全部通过。"
