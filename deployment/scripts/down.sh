#!/usr/bin/env bash
# 停止并移除三鼎全部容器（数据目录 / dsh home 保留）。
#
#   ./scripts/down.sh            # 停容器
#   ./scripts/down.sh --volumes  # 额外删匿名卷（bind mount 数据不受影响）
set -euo pipefail

cd "$(dirname "$0")/.."
docker compose down "$@"
