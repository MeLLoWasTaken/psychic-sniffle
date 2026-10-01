#!/usr/bin/env python3
"""Summarise batch arena simulations (review pass balance check).

    python3 tools/sim/analyze_batch.py docs/reports/review_02/sim_2v2.json [more.json ...] [--out summary.json]

For each report: matches, share ended by a kill, draws, median length, team-side balance, and win
rates per composition and per spec counted over non-mirror matches only (a mirror is 50% by
construction). Flags compositions and specs outside 40-60% (DESIGN.md balance target) when they
have at least 30 non-mirror matches.
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

LOW, HIGH, MIN_GAMES = 0.40, 0.60, 30


def comp_of(match: dict, team: int) -> str:
    return "+".join(sorted(u["spec"] for u in match["units"].values() if u["team"] == team))


def summarise(report: dict) -> dict:
    ms = report["matches"]
    kills = sum(m["end_reason"] == "team_eliminated" for m in ms)
    draws = sum(m["winner"] < 0 for m in ms)
    side = [m["winner"] for m in ms if m["winner"] >= 0]
    comp = defaultdict(lambda: [0, 0])     # comp -> [wins, games], non-mirror only
    spec = defaultdict(lambda: [0, 0])
    pair = defaultdict(lambda: [0, 0])     # "a vs b" -> [a wins, decided games]
    mirrors = defaultdict(lambda: {"games": 0, "kills": 0, "draws": 0})
    for m in ms:
        a, b = comp_of(m, 0), comp_of(m, 1)
        if a == b:
            mm = mirrors[a]
            mm["games"] += 1
            mm["kills"] += m["end_reason"] == "team_eliminated"
            mm["draws"] += m["winner"] < 0
            continue
        for team, c in ((0, a), (1, b)):
            comp[c][1] += 1
            comp[c][0] += m["winner"] == team
            for s in {u["spec"] for u in m["units"].values() if u["team"] == team}:
                spec[s][1] += 1
                spec[s][0] += m["winner"] == team
        key, first = (f"{a} vs {b}", 0) if a < b else (f"{b} vs {a}", 1)
        if m["winner"] >= 0:
            pair[key][1] += 1
            pair[key][0] += m["winner"] == first
    rate = lambda w, g: round(w / g, 3) if g else None  # noqa: E731
    out = {
        "matches": len(ms),
        "kill_rate": rate(kills, len(ms)),
        "draws": draws,
        "median_seconds": round(statistics.median(m["seconds"] for m in ms), 1) if ms else None,
        "team0_win_rate": rate(side.count(0), len(side)),
        "errors": sum(m["errors"] for m in ms),
        "comps": {c: {"win_rate": rate(w, g), "games": g} for c, (w, g) in sorted(comp.items())},
        "specs": {s: {"win_rate": rate(w, g), "games": g} for s, (w, g) in sorted(spec.items())},
        "matchups": {k: {"first_wins": rate(w, g), "decided": g} for k, (w, g) in sorted(pair.items())},
        "mirrors": dict(mirrors),
    }
    out["flags"] = [f"{kind} {name}: {v['win_rate']:.0%} over {v['games']}"
                    for kind, table in (("comp", out["comps"]), ("spec", out["specs"]))
                    for name, v in table.items()
                    if v["games"] >= MIN_GAMES and v["win_rate"] is not None and not LOW <= v["win_rate"] <= HIGH]
    if any(u.get("build", "none") != "none" for m in ms for u in m["units"].values()):
        out["builds"] = builds(report)
    return out


TOP_SHARE = 0.9  # M2-04: no talent node in more than 90% of the top builds


def node_id(entry: str) -> str:
    """A node from Talents.picked_nodes without its rank: "keen_fan:2" -> "keen_fan"; PvP talents
    keep their "pvp:" prefix ("pvp:quick_sever")."""
    head, _, tail = entry.rpartition(":")
    return head if head and tail.isdigit() else entry


def builds(report: dict) -> dict:
    """Talent builds (M2-04): each spec@build's win rate over non-mirror compositions (counted like
    specs), which builds are viable (40-60% with at least MIN_GAMES games), and, among each
    spec's top half of builds by win rate (at least 3), the share of builds taking each node; a
    node in more than TOP_SHARE of them means the trees push every good build the same way."""
    ms = report["matches"]
    nodes = {k: v.get("nodes", []) for k, v in report.get("summary", {}).get("builds", {}).items()}
    tally = defaultdict(lambda: [0, 0])
    for m in ms:
        a, b = comp_of(m, 0), comp_of(m, 1)
        if a == b:
            continue
        for u in m["units"].values():
            k = f"{u['spec']}@{u.get('build', 'none')}"
            tally[k][1] += 1
            tally[k][0] += m["winner"] == u["team"]
    per_spec = defaultdict(dict)
    for k, (w, g) in tally.items():
        sp = k.split("@")[0]
        per_spec[sp][k] = {"win_rate": round(w / g, 3), "games": g, "viable": g >= MIN_GAMES and LOW <= w / g <= HIGH}
    out = {}
    for sp, bs in sorted(per_spec.items()):
        ranked = sorted((k for k in bs if bs[k]["games"] >= MIN_GAMES), key=lambda k: -bs[k]["win_rate"])
        top = ranked[:max(3, len(ranked) // 2)]
        share = defaultdict(int)
        for k in top:
            for n in {node_id(x) for x in nodes.get(k, [])}:  # a node counts once whatever its rank
                share[n] += 1
        shares = {n: round(c / len(top), 3) for n, c in sorted(share.items(), key=lambda kv: -kv[1])} if top else {}
        out[sp] = {"builds": dict(sorted(bs.items(), key=lambda kv: -kv[1]["win_rate"])),
                   "viable": sum(v["viable"] for v in bs.values()), "top": top,
                   "over_share": {n: v for n, v in shares.items() if v > TOP_SHARE and len(top) >= 3},
                   "top_node_share": next(iter(shares.values()), None)}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", nargs="+", type=Path)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    result = {}
    for p in args.reports:
        s = summarise(json.loads(p.read_text()))
        result[p.stem] = s
        print(f"== {p.stem}: {s['matches']} matches, kills {s['kill_rate']:.0%}, draws {s['draws']}, "
              f"median {s['median_seconds']} s, team 0 wins {s['team0_win_rate']:.0%}, errors {s['errors']}")
        for name, v in s["specs"].items():
            print(f"   spec {name:20s} {v['win_rate']:.0%} of {v['games']}")
        for name, v in s["comps"].items():
            print(f"   comp {name:48s} {v['win_rate']:.0%} of {v['games']}")
        for f in s["flags"]:
            print(f"   OUTSIDE 40-60%: {f}")
    if args.out:
        args.out.write_text(json.dumps(result, indent=1) + "\n")


if __name__ == "__main__":
    main()
