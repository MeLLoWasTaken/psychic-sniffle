#!/usr/bin/env python3
"""Nightly balance simulation and performance profile (backlog X-06).

    python3 tools/sim/nightly.py --bracket 2v2 --matches 1000 --out previews/nightly
    python3 tools/sim/nightly.py --perf --out previews/nightly

--bracket: every composition of the playable specs (data/specs) of that size against every
other, mirrors included, spread evenly over --matches bot matches in one headless process
(game/tools/batch_sim.gd), then summarised by tools/sim/analyze_batch.py. Exit code 1 if a match
raised an error; specs and compositions outside 40-60% (the DESIGN.md balance target) are printed
as GitHub warnings and listed in the job summary, since known imbalances (backlog F-08) would
otherwise keep the job red every night.

--perf: the 20-player networked profile (one server, 20 bot clients) for 45 s, through
tools/sim/run_match.py; exit code 1 if the server tick average exceeds its budget.

Runs on GitHub Actions (.github/workflows/nightly.yml) on multi-core runners: the 2-core cloud
workspace skews these numbers (review pass 2).
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
import analyze_batch  # noqa: E402

TICK_BUDGET_MS = 8.0  # docs/DESIGN.md server budget per 60 Hz tick


def specs() -> list[str]:
    return sorted(p.stem for p in (REPO / "data" / "specs").glob("*.json"))


def comps(size: int) -> list[str]:
    teams = ["+".join(c) for c in itertools.combinations_with_replacement(specs(), size)]
    return [f"{a}:{b}" for a, b in itertools.combinations_with_replacement(teams, 2)]


def bracket(size: int, matches: int, out: Path, seed: int) -> int:
    report = out / f"sim_{size}v{size}.json"
    cmd = [shutil.which("godot") or "godot", "--headless", "--path", str(REPO / "game"), "-s",
           "res://tools/batch_sim.gd", "--", "--matches", str(matches), "--seed", str(seed),
           "--out", str(report)]
    for c in comps(size):
        cmd += ["--comp", c]
    print(f"{size}v{size}: {matches} matches over {len(comps(size))} pairings", flush=True)
    code = subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode
    s = analyze_batch.summarise(json.loads(report.read_text()))
    (out / f"summary_{size}v{size}.json").write_text(json.dumps(s, indent=1) + "\n")
    print(json.dumps({k: s[k] for k in ("matches", "kill_rate", "draws", "median_seconds", "errors", "flags")}, indent=1))
    for f in s["flags"]:
        print(f"::warning title={size}v{size} balance::{f}")
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(f"### {size}v{size}: {s['matches']} matches, kills {s['kill_rate']:.0%}, "
                     f"median {s['median_seconds']} s, errors {s['errors']}\n\n| Spec | Win rate | Games |\n| --- | --- | --- |\n")
            for name, v in s["specs"].items():
                fh.write(f"| {name} | {v['win_rate']:.0%} | {v['games']} |\n")
            fh.write("".join(f"\n- Outside 40-60%: {f}" for f in s["flags"]) + "\n\n")
    return 1 if code or s["errors"] else 0


def perf(out: Path) -> int:
    dest = out / "perf_20bots"
    code = subprocess.run([sys.executable, str(REPO / "tools" / "sim" / "run_match.py"), "--bots", "20",
                           "--seconds", "45", "--port", "24700", "--out", str(dest)]).returncode
    summary = json.loads((dest / "summary.json").read_text()) if (dest / "summary.json").exists() else {}
    print(json.dumps(summary, indent=1)[:4000])
    avg = summary.get("tick_ms", {}).get("avg")
    if avg is not None and avg > TICK_BUDGET_MS:
        print(f"server tick average {avg} ms over the {TICK_BUDGET_MS} ms budget")
        return 1
    return code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bracket", choices=["1v1", "2v2", "3v3"])
    ap.add_argument("--matches", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--perf", action="store_true")
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "nightly")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    code = 0
    if args.bracket:
        code |= bracket(int(args.bracket[0]), args.matches, args.out.resolve(), args.seed)
    if args.perf:
        code |= perf(args.out.resolve())
    if not args.bracket and not args.perf:
        ap.error("give --bracket and/or --perf")
    return code


if __name__ == "__main__":
    sys.exit(main())
