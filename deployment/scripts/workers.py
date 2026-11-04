#!/usr/bin/env python3
"""驿传 worker 视图（读 stdin 的 GET /v1/workers JSON）。

  curl -s .../v1/workers | python3 workers.py
  curl -s .../v1/workers | python3 workers.py --require-active base dev
                                            # 断言这些 name 处于 active，缺失则退出码 1
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
        wanted = args[1:]
        active = {
            (w.get("metadata") or {}).get("name")
            for w in items
            if w.get("presence") == "active"
        }
        missing = [n for n in wanted if n not in active]
        for name in wanted:
            if name in missing:
                print(f"  ❌ worker '{name}' 未处于 active")
            else:
                print(f"  ✅ worker '{name}' 已注册且 active")
        return 1 if missing else 0

    if not items:
        print("  (暂无 worker)")
        return 0
    for w in items:
        md = w.get("metadata") or {}
        kinds = ",".join(w.get("kinds") or [])
        print(
            f"  {md.get('name', '?'):<6} {w.get('worker_id', ''):<28} "
            f"{w.get('presence', ''):<8} {w.get('state', ''):<8} "
            f"kinds=[{kinds}] last_seen={w.get('last_seen', '')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
