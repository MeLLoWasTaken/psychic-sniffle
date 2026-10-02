"""Smoke test of an exported game package (backlog P-01): run its executable as a headless server
and two headless bots for a short skirmish, then check the server's summary: it ticked, the bots
joined and fought, and nothing logged an error. Runs the same on Windows and Linux.

    python3 tools/sim/package_smoke.py build/windows/ArenaPvP.console.exe [--seconds 30]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("exe", type=Path)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--port", type=int, default=25990)
    ap.add_argument("--out", type=Path, default=Path("smoke"))
    ap.add_argument("--pack", type=Path, help="run this .pck with the given engine binary (testing the script)")
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    exe = str(args.exe.resolve())
    pre = ["--main-pack", str(args.pack.resolve())] if args.pack else []
    summary = out / "summary.json"
    server_log = open(out / "server.log", "w")
    server = subprocess.Popen([exe, *pre, "--headless", "--", "--server", "--port", str(args.port), "--mode", "skirmish",
                               "--respawn", "--match-seconds", str(args.seconds + 15), "--summary", str(summary)],
                              stdout=server_log, stderr=subprocess.STDOUT)
    time.sleep(4)
    bots = []
    for i, spec in enumerate(["warblade_carnage", "arcanist_rime"]):
        log = open(out / f"bot{i + 1}.log", "w")
        bots.append(subprocess.Popen([exe, *pre, "--headless", "--", "--bot", "--name", f"bot{i + 1}", "--port", str(args.port),
                                      "--seconds", str(args.seconds), "--spec", spec,
                                      "--stats", str(out / f"bot{i + 1}.json")], stdout=log, stderr=subprocess.STDOUT))
    problems: list[str] = []
    for i, b in enumerate(bots):
        try:
            if b.wait(timeout=args.seconds + 60) != 0:
                problems.append(f"bot{i + 1} exited with code {b.returncode}")
        except subprocess.TimeoutExpired:
            b.kill()
            problems.append(f"bot{i + 1} did not finish")
    try:
        server.wait(timeout=60)
    except subprocess.TimeoutExpired:
        server.kill()
        problems.append("the server did not finish")
    if not summary.exists():
        problems.append("the server wrote no summary")
    else:
        s = json.loads(summary.read_text())
        print(json.dumps({k: s.get(k) for k in ("ticks", "damage_events", "kills", "log_errors", "memory_peak_mb")}))
        if int(s.get("ticks", 0)) < 60 * args.seconds * 0.8:
            problems.append(f"the server ran only {s.get('ticks')} ticks")
        if int(s.get("damage_events", 0)) == 0:
            problems.append("the bots never hit each other")
        if int(s.get("log_errors", 0)):
            problems.append(f"the server logged {s['log_errors']} errors")
    for i in range(len(bots)):
        st = out / f"bot{i + 1}.json"
        if not st.exists():
            problems.append(f"bot{i + 1} wrote no stats")
        elif int(json.loads(st.read_text()).get("log_errors", 0)):
            problems.append(f"bot{i + 1} logged errors")
    if problems:
        for p in problems:
            print(f"::error title=package smoke::{p}")
        for name in ["server.log", "bot1.log", "bot2.log"]:
            tail = " | ".join((out / name).read_text(errors="replace").splitlines()[-12:])
            print(f"::error title=package smoke {name}::{tail[:3500]}")
        return 1
    print("package smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
