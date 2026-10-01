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


def build_names(spec: str, randoms: int) -> list[str]:
    named = [b["name"] for b in json.loads((REPO / "data" / "bots" / f"{spec}.json").read_text()).get("builds", [])]
    return named + [f"random{i}" for i in range(1, randoms + 1)]


def build_comps(size: int, matches: int, randoms: int, seed: int) -> list[str]:
    """One composition per match, the pairings in turn, each unit on a random build of its spec
    (its bot profile's named builds and `randoms` random legal builds), so every build meets
    every pairing (M2-04)."""
    import random
    rng = random.Random(seed)
    names = {s: build_names(s, randoms) for s in specs()}
    pairings = comps(size)
    out = []
    for i in range(matches):
        sides = pairings[i % len(pairings)].split(":")
        out.append(":".join("+".join(f"{sp}@{rng.choice(names[sp])}" for sp in side.split("+")) for side in sides))
    return out


def run_batch(comp_list: list[str], matches: int, seed: int, report: Path, jobs: int) -> int:
    """Run the matches in `jobs` headless processes at once (CI runners have several cores) and
    merge their reports into `report`. Each process takes a share of the compositions in order."""
    godot = shutil.which("godot") or "godot"
    jobs = max(1, min(jobs, matches))
    procs = []
    for j in range(jobs):
        n = matches // jobs + (1 if j < matches % jobs else 0)
        part = report.with_name(f"{report.stem}_part{j}.json")
        cs = comp_list[j::jobs] or comp_list
        cmd = [godot, "--headless", "--path", str(REPO / "game"), "-s", "res://tools/batch_sim.gd", "--",
               "--matches", str(n), "--seed", str(seed + 100000 * j), "--out", str(part)]
        for c in cs:
            cmd += ["--comp", c]
        procs.append((subprocess.Popen(cmd, stdout=subprocess.DEVNULL), part))
    code = 0
    merged = {"matches": [], "summary": {"builds": {}}}
    for p, part in procs:
        code |= p.wait()
        if part.exists():
            r = json.loads(part.read_text())
            merged["matches"] += r["matches"]
            for k, v in r.get("summary", {}).get("builds", {}).items():
                merged["summary"]["builds"].setdefault(k, {"nodes": v.get("nodes", [])})
    report.write_text(json.dumps(merged) + "\n")
    return code


def bracket(size: int, matches: int, out: Path, seed: int, randoms: int = 0, jobs: int = 1) -> int:
    report = out / f"sim_{size}v{size}.json"
    comp_list = build_comps(size, matches, randoms, seed) if randoms > 0 else comps(size)
    print(f"{size}v{size}: {matches} matches over {len(comps(size))} pairings"
          + (f", {randoms} random builds per spec besides the named ones" if randoms else "") + f", {jobs} processes", flush=True)
    code = run_batch(comp_list, matches, seed, report, jobs)
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
            for sp, b in s.get("builds", {}).items():
                fh.write(f"#### {sp}: {b['viable']} viable builds; top builds {', '.join(b['top'])}; "
                         f"most shared node in the top builds: {b['top_node_share']:.0%}\n\n| Build | Win rate | Games |\n| --- | --- | --- |\n"
                         if b["top_node_share"] is not None else f"#### {sp}: {b['viable']} viable builds\n\n| Build | Win rate | Games |\n| --- | --- | --- |\n")
                for k, v in b["builds"].items():
                    fh.write(f"| {k} | {v['win_rate']:.0%} | {v['games']} |\n")
                fh.write("".join(f"\n- In more than 90% of the top builds: {n} ({v:.0%})" for n, v in b["over_share"].items()) + "\n\n")
    for sp, b in s.get("builds", {}).items():
        print(f"{sp}: {b['viable']} viable builds, top {b['top']}, over 90%: {b['over_share']}")
        if b["viable"] < 3:
            print(f"::warning title={size}v{size} builds::{sp} has {b['viable']} viable builds (M2-04 wants 3)")
        for n, v in b["over_share"].items():
            print(f"::warning title={size}v{size} builds::{sp}: {n} is in {v:.0%} of the top builds")
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
    ap.add_argument("--random-builds", type=int, default=0,
                    help="each unit plays a random build: its named builds or one of N random legal builds (M2-04)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="headless processes at once")
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "nightly")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    code = 0
    if args.bracket:
        code |= bracket(int(args.bracket[0]), args.matches, args.out.resolve(), args.seed, args.random_builds, args.jobs)
    if args.perf:
        code |= perf(args.out.resolve())
    if not args.bracket and not args.perf:
        ap.error("give --bracket and/or --perf")
    return code


if __name__ == "__main__":
    sys.exit(main())
