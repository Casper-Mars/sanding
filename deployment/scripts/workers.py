#!/usr/bin/env python3
"""驿传 V3 worker 视图（读 stdin 的 GET /v1/workers JSON）。

  curl -s .../v1/workers | python3 workers.py
  curl -s .../v1/workers | python3 workers.py --require-active
                                            # 断言至少一个 worker 已注册且声明了 kinds
"""
import json
import sys


def main() -> int:
    try:
        items = json.load(sys.stdin).get("items", [])
    except json.JSONDecodeError as exc:
        print(f"  (返回不是合法 JSON：{exc})")
        return 2

    args = sys.argv[1:]
    if args and args[0] == "--require-active":
        active = [
            w for w in items
            if w.get("state") in ("idle", "busy") and (w.get("kinds") or [])
        ]
        if not active:
            print("  ❌ 没有已注册且声明 kinds 的 worker")
            return 1
        for worker in active:
            kinds = ",".join(worker.get("kinds") or [])
            print(f"  ✅ worker {worker.get('worker_id', '')} active，kinds=[{kinds}]")
        return 0

    if not items:
        print("  (暂无 worker)")
        return 0
    for w in items:
        md = w.get("metadata") or {}
        kinds = ",".join(w.get("kinds") or [])
        print(
            f"  {md.get('name', 'worker'):<8} {w.get('worker_id', ''):<40} "
            f"{w.get('state', ''):<6} kinds=[{kinds}] last_seen={w.get('last_seen', '')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
