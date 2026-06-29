#!/usr/bin/env python3
"""Automated test for exact window switching via kitty (launch.py backend).

Opens 2 throwaway windows with the SAME cwd (the case Kaku/AX could not handle),
focuses each by id, and asserts kitty reports the right window focused.
Re-runnable:  python3 test_switch.py
"""
import json, sys, time
import launch  # the module under test

def focused_id():
    r = launch._k("ls")
    for o in json.loads(r.stdout):
        for t in o["tabs"]:
            for w in t["windows"]:
                if w.get("is_focused"):
                    return w["id"]
    return None

def spawn(cwd="/tmp"):
    r = launch._k("launch", "--type=os-window", "--cwd", cwd,
                  "--", "/bin/zsh", "-lc", "sleep 600")
    return int(r.stdout.strip())

def main():
    assert launch._ensure_kitty(), "kitty 起不来"
    print("开两个同 cwd(/tmp) 的窗口（Kaku 在此必败）…")
    w1, w2 = spawn(), spawn()
    print(f"  W1={w1}  W2={w2}")
    results = []
    for tgt, lbl in [(w1, "切到 W1"), (w2, "切到 W2"),
                     (w1, "切回 W1"), (w2, "再切 W2")]:
        launch._k("focus-window", "--match", f"id:{tgt}")
        time.sleep(0.6)
        f = focused_id()
        ok = (f == tgt)
        results.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {lbl}: 目标={tgt} 实际focused={f}")

    # reuse-after-close: closing a window must drop it from live ids
    launch._k("close-window", "--match", f"id:{w1}")
    time.sleep(0.4)
    closed_ok = w1 not in launch._live_ids()
    results.append(closed_ok)
    print(f"  [{'PASS' if closed_ok else 'FAIL'}] 关闭 W1 后不再算活窗口")

    launch._k("close-window", "--match", f"id:{w2}")
    n = sum(results)
    print(f"\n结果: {n}/{len(results)} 通过")
    sys.exit(0 if n == len(results) else 1)

if __name__ == "__main__":
    main()
