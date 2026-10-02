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


def run_batch(comp_list: list[str], matches: int, seed: int, report: Path, jobs: int, map_id: str = "all") -> int:
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
               "--matches", str(n), "--seed", str(seed + 100000 * j), "--out", str(part), "--map", map_id]
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


def bracket(size: int, matches: int, out: Path, seed: int, randoms: int = 0, jobs: int = 1,
            shard: int = 0, shards: int = 1, map_id: str = "all") -> int:
    """Simulate this shard's part of `matches` (all of them with one shard) and, with one shard,
    report it. With several, each writes sim_<b>_shard<i>.json and `--merge` reports them together
    (the CI runs shards as parallel jobs: one runner cannot finish 1,000 2v2 matches in its 4 hours)."""
    comp_list = build_comps(size, matches, randoms, seed) if randoms > 0 else comps(size)
    if shards > 1:
        comp_list = comp_list[shard::shards] if randoms > 0 else comp_list
        n = matches // shards + (1 if shard < matches % shards else 0)
        report = out / f"sim_{size}v{size}_shard{shard}.json"
    else:
        n = matches
        report = out / f"sim_{size}v{size}.json"
    print(f"{size}v{size}: {n} of {matches} matches over {len(comps(size))} pairings, arenas: {map_id}"
          + (f", {randoms} random builds per spec besides the named ones" if randoms else "")
          + (f", shard {shard + 1} of {shards}" if shards > 1 else "") + f", {jobs} processes", flush=True)
    code = run_batch(comp_list, n, seed + 1000003 * shard, report, jobs, map_id)
    if shards > 1:
        return code
    return report_bracket(size, json.loads(report.read_text()), out) | code


def merge(size: int, src: Path, out: Path) -> int:
    """Report a bracket from the shard reports found anywhere under `src`."""
    merged = {"matches": [], "summary": {"builds": {}}}
    parts = sorted(p for p in src.rglob(f"sim_{size}v{size}_shard*.json") if "_part" not in p.name)  # not the per-process parts
    for part in parts:
        r = json.loads(part.read_text())
        merged["matches"] += r["matches"]
        for k, v in r.get("summary", {}).get("builds", {}).items():
            merged["summary"]["builds"].setdefault(k, v)
    if not parts:
        print(f"::warning title={size}v{size}::no shard reports found under {src}")
        return 1
    (out / f"sim_{size}v{size}.json").write_text(json.dumps(merged) + "\n")
    print(f"{size}v{size}: merged {len(parts)} shards, {len(merged['matches'])} matches")
    return report_bracket(size, merged, out)


def report_bracket(size: int, report: dict, out: Path) -> int:
    s = analyze_batch.summarise(report)
    (out / f"summary_{size}v{size}.json").write_text(json.dumps(s, indent=1) + "\n")
    print(json.dumps({k: s[k] for k in ("matches", "kill_rate", "draws", "median_seconds", "errors", "flags")}, indent=1))
    for f in s["flags"]:
        print(f"::warning title={size}v{size} balance::{f}")
    # the whole table as notices too: annotations are what can be read back from a run
    print(f"::notice title={size}v{size} summary::{s['matches']} matches, kills {s['kill_rate']}, draws {s['draws']}, "
          f"median {s['median_seconds']} s; specs " + ", ".join(f"{k} {v['win_rate']} ({v['games']})" for k, v in s["specs"].items()))
    if s["matchups"]:
        print(f"::notice title={size}v{size} matchups::" + "; ".join(f"{k}: {v['first_wins']} ({v['decided']})" for k, v in s["matchups"].items()))
    if s.get("mirrors"):
        # F-08: mirror matches should end by a kill over 90% of the time
        top = sorted(s["mirrors"].items(), key=lambda kv: -kv[1]["games"])[:12]
        print(f"::notice title={size}v{size} mirrors::" + "; ".join(
            f"{k}: kills {v['kills']}/{v['games']}, draws {v['draws']}" for k, v in top))
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
            print(f"::warning title={size}v{size} builds::{sp}: {n} is in {v:.0%} of the top builds "
                  f"({b.get('all_share', {}).get(n, 0):.0%} of all its simulated builds)")
    return 1 if s["errors"] else 0


def perf(out: Path) -> int:
    dest = out / "perf_20bots"
    # 20 full Godot clients on one runner starve each other of CPU (X-19), so their snapshot rates
    # are recorded, not checked; the server's tick time is the budget this profile guards
    run = subprocess.run([sys.executable, str(REPO / "tools" / "sim" / "run_match.py"), "--bots", "20",
                          "--seconds", "45", "--port", "24700", "--profile", "--out", str(dest)], capture_output=True, text=True)
    code = run.returncode
    print(run.stdout[-6000:])
    if code:
        # CI shows annotations, not logs: the end of the run's output says what failed
        for line in (run.stdout + run.stderr).strip().splitlines()[-12:]:
            print(f"::error title=perf::{line[:300]}")
    summary = json.loads((dest / "summary.json").read_text()) if (dest / "summary.json").exists() else {}
    print(json.dumps(summary, indent=1)[:4000])
    tick = summary.get("tick_ms", {})
    report = json.loads((dest / "report.json").read_text()) if (dest / "report.json").exists() else {}
    rates = [b.get("snapshot_rate_hz", 0) for b in report.get("bots", {}).values()]
    print(f"::notice title=20-player profile::server tick avg {tick.get('avg')} ms, p95 {tick.get('p95')} ms, max {tick.get('max')} ms; "
          f"client snapshot rates {min(rates, default=0):.1f}-{max(rates, default=0):.1f} Hz on {os.cpu_count()} cores")
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
    ap.add_argument("--shard", type=int, default=0, help="this job's part (0-based) when --shards > 1")
    ap.add_argument("--shards", type=int, default=1, help="parts the bracket's matches are split into (parallel CI jobs)")
    ap.add_argument("--merge", type=Path, help="report --bracket from the shard reports under this folder")
    ap.add_argument("--map", default="all", help="an arena id, or all: every arena hosting the bracket in turn")
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "nightly")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    code = 0
    if args.bracket and args.merge:
        code |= merge(int(args.bracket[0]), args.merge.resolve(), args.out.resolve())
    elif args.bracket:
        code |= bracket(int(args.bracket[0]), args.matches, args.out.resolve(), args.seed, args.random_builds, args.jobs,
                        args.shard, args.shards, args.map)
    if args.perf:
        code |= perf(args.out.resolve())
    if not args.bracket and not args.perf:
        ap.error("give --bracket and/or --perf")
    return code


if __name__ == "__main__":
    sys.exit(main())
