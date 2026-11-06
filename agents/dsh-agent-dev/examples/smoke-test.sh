#!/usr/bin/env bash
# dsh-agent-dev 冒烟验证：容器健康 → socket → dev-container skill → devcontainer CLI → 插件已装
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/5 容器健康 =="
state="$(docker inspect -f '{{.State.Health.Status}}' dsh-agent-dev 2>/dev/null || echo unknown)"
echo "health=$state"
[ "$state" = "healthy" ] || { echo "FAIL：容器未 healthy"; docker compose ps; exit 1; }

echo "== 2/5 Docker socket 连通 =="
docker compose exec -T dsh docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'

echo "== 3/5 dev-container skill 就位 =="
docker compose exec -T dsh sh -c 'ls -la "$DSH_HOME/profiles/${DSH_PROFILE:-web}/node_modules/dsh-agent-dev/skills/dev-container/SKILL.md"'

echo "== 4/5 devcontainer CLI 可用 =="
docker compose exec -T dsh devcontainer --version

echo "== 5/5 插件已装配 =="
docker compose exec -T dsh sh -c '
  for spec in $PLUGIN_SPECS; do
    name="${spec%@*}"
    path="$DSH_HOME/profiles/${DSH_PROFILE:-web}/node_modules/$name/package.json"
    [ -f "$path" ] || { echo "FAIL：$name 未安装"; exit 1; }
    echo "ok $spec"
  done'

echo "OK：全部通过。"
