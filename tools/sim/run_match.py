#!/usr/bin/env python3
"""Run a headless match: one server plus N bot clients, each a separate Godot process.

  tools/sim/run_match.py --bots 2 --minutes 5                  # the M0 exit gate
  tools/sim/run_match.py --bots 2 --seconds 30 --lag-ms 150 --jitter-ms 30 --loss 0.02

Checks (exit code 1 if any fails):
  - server and every bot exit cleanly
  - no ERROR or WARNING lines in any log (after removing known harmless lines)
  - each bot receives snapshots at the tick rate (within 1 Hz)
  - combat happened (at least one damage event) when the match lasts 30 s or more
  - with --lag-ms set: measured round trip within 10% of the setting,
    largest prediction correction under 0.5 m and average under 0.1 m
Writes <out>/summary.json, <out>/<bot>.json and all logs.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# Round trip on the local machine with no simulated lag, from polling at up to 240 frames per
# second on both ends (measured 8 to 10 ms). The simulator adds its delay on top of this.
BASE_RTT_MS = 10.0
HARMLESS = [
    re.compile(r"Remote Debugger"),
    re.compile(r"_try_connect"),
]


def godot() -> str:
    exe = shutil.which("godot")
    if not exe:
        sys.exit("godot not found (run tools/env/setup_cloud.sh)")
    return exe


def bad_lines(text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        if re.search(r"\b(ERROR|WARNING|SCRIPT ERROR|Parse Error)\b|^\S+ (WARN|ERROR) \[", line):
            if not any(h.search(line) for h in HARMLESS):
                out.append(line)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=2)
    ap.add_argument("--minutes", type=float, default=0)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--port", type=int, default=24600)
    ap.add_argument("--lag-ms", type=float, default=0)
    ap.add_argument("--jitter-ms", type=float, default=0)
    ap.add_argument("--loss", type=float, default=0)
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "matches" / "latest")
    args = ap.parse_args()
    seconds = args.minutes * 60 if args.minutes else args.seconds
    out = args.out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    g = godot()
    game = str(REPO / "game")
    base = [g, "--headless", "--path", game]

    server_log = open(out / "server.log", "w")
    server = subprocess.Popen(base + ["--", "--server", "--port", str(args.port), "--match-seconds",
                                      str(seconds + 0.3 * args.bots + 10), "--respawn", "--summary", str(out / "summary.json")],
                              stdout=server_log, stderr=subprocess.STDOUT)
    deadline = time.time() + 30
    while "server: listening" not in (out / "server.log").read_text():
        if time.time() > deadline or server.poll() is not None:
            print("FAIL server did not start"); print((out / "server.log").read_text()[-2000:])
            return 1
        time.sleep(0.2)

    bots = []
    for i in range(args.bots):
        name = f"bot{i + 1}"
        log = open(out / f"{name}.log", "w")
        cmd = base + ["--", "--bot", "--name", name, "--port", str(args.port), "--seconds", str(seconds),
                      "--stats", str(out / f"{name}.json")]
        if args.lag_ms or args.jitter_ms or args.loss:
            cmd += ["--lag-ms", str(args.lag_ms), "--jitter-ms", str(args.jitter_ms), "--loss", str(args.loss)]
        bots.append((name, subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)))
        time.sleep(0.3)

    print(f"running {args.bots} bots for {seconds:.0f} s ...", flush=True)
    failures: list[str] = []
    for name, p in bots:
        try:
            code = p.wait(timeout=seconds + 60)
        except subprocess.TimeoutExpired:
            p.kill(); code = -9
        if code != 0:
            failures.append(f"{name} exited with code {code}")
    try:
        code = server.wait(timeout=60)
    except subprocess.TimeoutExpired:
        server.kill(); code = -9
    if code != 0:
        failures.append(f"server exited with code {code}")

    for log in sorted(out.glob("*.log")):
        for line in bad_lines(log.read_text())[:5]:
            failures.append(f"{log.name}: {line.strip()}")

    summary = json.loads((out / "summary.json").read_text()) if (out / "summary.json").exists() else {}
    if not summary:
        failures.append("server wrote no summary")
    rate = summary.get("tick_rate_hz", 60)
    report = {"seconds": seconds, "bots": {}, "server": summary}
    for name, _ in bots:
        path = out / f"{name}.json"
        if not path.exists():
            failures.append(f"{name} wrote no stats"); continue
        st = json.loads(path.read_text())
        report["bots"][name] = st
        if abs(st["snapshot_rate_hz"] - rate) > 1.0 and not args.loss:
            failures.append(f"{name} snapshot rate {st['snapshot_rate_hz']:.2f} Hz, expected {rate} +/- 1")
        if args.loss and st["snapshot_rate_hz"] < rate * (1 - args.loss) - 1.5:
            failures.append(f"{name} snapshot rate {st['snapshot_rate_hz']:.2f} Hz too low for {args.loss:.0%} loss")
        if args.lag_ms:
            expected = args.lag_ms + BASE_RTT_MS
            if abs(st["rtt_avg_ms"] - expected) > 0.1 * args.lag_ms:
                failures.append(f"{name} measured RTT {st['rtt_avg_ms']:.1f} ms vs expected {expected:.0f} ms "
                                f"({args.lag_ms:.0f} ms simulated + {BASE_RTT_MS:.0f} ms local base)")
            if st["correction_max_m"] >= 0.5:
                failures.append(f"{name} largest correction {st['correction_max_m']:.3f} m (limit 0.5)")
            if st["correction_avg_m"] >= 0.1:
                failures.append(f"{name} average correction {st['correction_avg_m']:.3f} m (limit 0.1)")
    if seconds >= 30 and summary.get("damage_events", 0) == 0:
        failures.append("no combat happened (0 damage events)")

    (out / "report.json").write_text(json.dumps(report, indent=2))
    t = summary.get("tick_ms", {})
    print(f"server: {summary.get('ticks', 0)} ticks, tick avg {t.get('avg', 0):.3f} ms, p95 {t.get('p95', 0):.3f} ms, "
          f"max {t.get('max', 0):.3f} ms; {summary.get('damage_events', 0)} damage events, {summary.get('kills', 0)} kills")
    for name, st in report["bots"].items():
        print(f"{name}: {st['snapshot_rate_hz']:.2f} snapshots/s, rtt {st['rtt_avg_ms']:.1f} ms, "
              f"corrections {st['corrections']} (avg {st['correction_avg_m']:.3f} m, max {st['correction_max_m']:.3f} m)")
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("PASS match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
