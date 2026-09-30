#!/usr/bin/env python3
"""End-to-end test of the match flow (backlog M1-28), headless, with real processes.

  tools/match_flow_e2e.py [--spec warblade_carnage] [--prep 5] [--port 25400] [--timeout 900]

Starts the game client as a player would (no scene argument: boot -> main menu) with
`--auto-flow play --pilot`: the client clicks "Play 2v2 vs bots" on the real menu, the local
server and three bot clients start as separate processes, the player's unit is played through its
own controls by ScriptedPilot (input events into PlayerController), the match runs under the real
arena rules until a team is eliminated, the end screen shows, the client clicks "Back to menu" and
the main menu is back. Preparation is shortened with --prep (the only rule changed).

Checks (exit code 1 if any fails):
  - the client exits 0 and its flow went loading, prep, active, ended, scoreboard, menu
  - every automated click reached its button; the menu is shown again at the end
  - a team was eliminated (server summary and the client's end reason agree on the winner)
  - the end screen's scoreboard has nonzero damage for every unit and nonzero healing for every
    healer, and matches the server's own totals per unit (damage + absorbed, healing, kills)
  - the player's unit (driven by input events) dealt damage and pressed abilities
  - no ERROR or WARNING line from any process (client, server, bots share the output)
  - no process the client started is still running
Writes <out>/client.log and <out>/report.json.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HARMLESS = [re.compile(r"Remote Debugger"), re.compile(r"_try_connect")]
FLOW = ["loading", "prep", "active", "ended", "scoreboard", "menu"]


def bad_lines(text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        if re.search(r"\b(ERROR|WARNING|SCRIPT ERROR|Parse Error)\b|^\S+ (WARN|ERROR) \[", line):
            if not any(h.search(line) for h in HARMLESS):
                out.append(line.strip())
    return out


def running(pid: int) -> bool:
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        return False


def ticks_total(scene: dict) -> int:
    return max(int(scene.get("ticks", 0)), 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", default="warblade_carnage")
    ap.add_argument("--prep", type=float, default=5.0)
    ap.add_argument("--port", type=int, default=25400, help="first port of the local server's range")
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "matches" / "match_flow")
    args = ap.parse_args()
    godot = shutil.which("godot")
    if not godot:
        sys.exit("godot not found (run tools/env/setup_cloud.sh)")
    out = args.out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    flow_report = out / "flow.json"
    cmd = [godot, "--headless", "--path", str(REPO / "game"), "--", "--auto-flow", "play", "--pilot",
           "--spec", args.spec, "--prep", str(args.prep), "--port-min", str(args.port), "--no-kit", "--no-gi",
           "--flow-timeout", str(args.timeout - 30), "--flow-report", str(flow_report)]
    print(f"running the match flow as {args.spec} (prep {args.prep:.0f} s) ...", flush=True)
    start = time.time()
    with open(out / "client.log", "w") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            code = -9
    took = time.time() - start
    text = (out / "client.log").read_text()
    failures: list[str] = []
    if code != 0:
        failures.append(f"client exited with code {code}")
    for line in bad_lines(text)[:10]:
        failures.append(f"log: {line}")
    rep = json.loads(flow_report.read_text()) if flow_report.exists() else {}
    if not rep:
        failures.append("the client wrote no flow report")
    res = rep.get("result", {})
    summary = res.get("server_summary", {})
    if rep and not rep.get("ok"):
        failures.append(f"client reported failure: {rep.get('failure') or 'errors in its log'}")
    if res.get("history") != FLOW:
        failures.append(f"flow went {res.get('history')}, expected {FLOW}")
    for c in rep.get("clicks", []):
        if not c.get("hit"):
            failures.append(f"click on {c['control']} did not reach it")
    if rep and not (rep.get("menu_visible") and rep.get("menu_returns", 0) >= 1):
        failures.append("the main menu was not shown again")
    if summary.get("winner_team") not in (0, 1):
        failures.append(f"no team was eliminated (server winner {summary.get('winner_team')}, "
                        f"end {summary.get('end_reason')})")
    if res.get("reason") != "team_eliminated" or res.get("winner") != summary.get("winner_team"):
        failures.append(f"client end ({res.get('reason')}, winner {res.get('winner')}) disagrees with the server")

    specs = {p.stem: json.loads(p.read_text()) for p in (REPO / "data" / "specs").glob("*.json")}
    board = res.get("scoreboard", {})
    by_unit = summary.get("by_unit", {})
    names = res.get("unit_names", {})
    if len(board) != 4:
        failures.append(f"scoreboard has {len(board)} units, expected 4")
    rows = []
    for uid, row in sorted(board.items(), key=lambda kv: int(kv[0])):
        srv = by_unit.get(uid, {})
        label = f"unit {uid} {names.get(uid, '')} ({row['spec']})"
        rows.append(f"  {label:34s} damage {row['damage']:>8,}  healing {row['healing']:>8,}  kills {row['kills']}  "
                    f"interrupts {row['interrupts']}")
        if row["damage"] <= 0:
            failures.append(f"{label}: no damage on the scoreboard")
        if specs.get(row["spec"], {}).get("role") == "healer" and row["healing"] <= 0:
            failures.append(f"{label}: a healer with no healing on the scoreboard")
        want_dmg = int(srv.get("damage", 0)) + int(srv.get("absorbed", 0))
        if row["damage"] != want_dmg or row["healing"] != int(srv.get("healing", 0)) or row["kills"] != int(srv.get("kills", 0)):
            failures.append(f"{label}: scoreboard damage/healing/kills {row['damage']}/{row['healing']}/{row['kills']} "
                            f"differ from the server's {want_dmg}/{srv.get('healing', 0)}/{srv.get('kills', 0)}")
    me = str(res.get("my_id", -1))
    if board.get(me, {}).get("damage", 0) <= 0:
        failures.append("the player's unit dealt no damage")
    pilot = res.get("pilot", {})
    if pilot.get("presses", 0) <= 0:
        failures.append("the pilot pressed no action bar key")
    leftover = [p for p in res.get("pids_started", []) if running(int(p))]
    if leftover or res.get("pids_running"):
        failures.append(f"processes still running: {leftover or res.get('pids_running')}")
    if len(res.get("pids_started", [])) != 4:
        failures.append(f"expected 4 processes started (server and 3 bots), got {res.get('pids_started')}")

    # M1-29: the match's input log replays to the server's final state hash
    log_path = summary.get("input_log", "")
    replay = {}
    if not log_path or not Path(log_path).exists():
        failures.append("the match wrote no input log")
    else:
        rp = subprocess.run([godot, "--headless", "--path", str(REPO / "game"), "-s", "res://tools/replay.gd", "--",
                             "--log", log_path], capture_output=True, text=True, timeout=600)
        line = next((ln for ln in rp.stdout.splitlines() if ln.startswith("REPLAY ")), "")
        replay = json.loads(line[len("REPLAY "):]) if line else {"ok": False, "error": rp.stdout[-400:]}
        if not replay.get("ok") or replay.get("hash") != summary.get("state_hash"):
            failures.append(f"the replay did not reproduce the final state hash: {replay}")

    scene = res.get("scene", {})
    client = res.get("client", {})
    if int(scene.get("held_draw_ticks", 0)) > 0.02 * ticks_total(scene):
        failures.append(f"the renderer skipped {scene.get('held_draw_ticks')} of {scene.get('ticks')} ticks (over 2%)")
    report = {"seconds": took, "exit_code": code, "flow": res.get("history"), "outcome": res.get("outcome"),
              "match_seconds": res.get("match_seconds"), "scoreboard": board, "server_by_unit": by_unit,
              "server_tick_ms": summary.get("tick_ms"), "pilot": pilot, "scene": scene,
              "client_snapshot_rate_hz": client.get("snapshot_rate_hz"), "clicks": rep.get("clicks"),
              "replay": replay, "failures": failures}
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(f"flow {res.get('history')} in {took:.0f} s; {res.get('outcome')} after {res.get('match_seconds', 0):.0f} s "
          f"of match time; server tick avg {summary.get('tick_ms', {}).get('avg', 0):.3f} ms")
    print("\n".join(rows))
    ticks = max(int(scene.get("ticks", 0)), 1)
    print(f"client: {scene.get('ticks', 0)} ticks, {scene.get('stale_view_ticks', 0)} without a new snapshot "
          f"({100.0 * scene.get('stale_view_ticks', 0) / ticks:.1f}%), {scene.get('held_draw_ticks', 0)} not drawn "
          f"({100.0 * scene.get('held_draw_ticks', 0) / ticks:.2f}%), {scene.get('events', 0)} events; "
          f"pilot {pilot.get('presses', 0)} key presses, {pilot.get('tabs', 0)} Tab, {pilot.get('frame_clicks', 0)} frame clicks")
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("PASS match flow")
    return 0


if __name__ == "__main__":
    sys.exit(main())
