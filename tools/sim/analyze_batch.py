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
TOP_SIGNIFICANCE = 0.05  # ... unless that many would take it by chance (its share of all builds)


def binomial_tail(k: int, n: int, p: float) -> float:
    """P(X >= k) for X ~ Binomial(n, p)."""
    from math import comb
    return sum(comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k, n + 1))


def node_id(entry: str) -> str:
    """A node from Talents.picked_nodes without its rank: "keen_fan:2" -> "keen_fan"; PvP talents
    keep their "pvp:" prefix ("pvp:quick_sever")."""
    head, _, tail = entry.rpartition(":")
    return head if head and tail.isdigit() else entry


def builds(report: dict) -> dict:
    """Talent builds (M2-04): each spec@build's win rate over non-mirror compositions (counted like
    specs), which builds are viable (40-60% with at least MIN_GAMES games), and, among each
    spec's top half of builds by win rate (at least 3), the share of builds taking each node; a
    node in more than TOP_SHARE of them means the trees push every good build the same way, when
    the top builds take it more than chance would (binomial test against its share of all the
    spec's builds, TOP_SIGNIFICANCE). A node most legal builds take is in the top builds whatever
    its strength; those are listed apart as "common" (DECISIONS.md 2026-10-02)."""
    ms = report["matches"]
    nodes = {k: v.get("nodes", []) for k, v in report.get("summary", {}).get("builds", {}).items()}
    tally = defaultdict(lambda: [0, 0])
    vs = defaultdict(lambda: [0, 0])  # (spec@build, opposing composition) -> [wins, games]
    for m in ms:
        a, b = comp_of(m, 0), comp_of(m, 1)
        if a == b:
            continue
        for u in m["units"].values():
            k = f"{u['spec']}@{u.get('build', 'none')}"
            tally[k][1] += 1
            tally[k][0] += m["winner"] == u["team"]
            opp = b if u["team"] == 0 else a
            vs[(k, opp)][1] += 1
            vs[(k, opp)][0] += m["winner"] == u["team"]
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
        # the same share over every simulated build of the spec: a node most legal builds take
        # (the tree's shape) is in the top builds whatever its strength
        every = defaultdict(int)
        for k in ranked:
            for n in {node_id(x) for x in nodes.get(k, [])}:
                every[n] += 1
        all_share = {n: round(every[n] / len(ranked), 3) for n in shares if ranked}
        high = {n: v for n, v in shares.items() if v > TOP_SHARE and len(top) >= 3}
        favoured = {n: v for n, v in high.items()
                    if binomial_tail(round(v * len(top)), len(top), every[n] / len(ranked)) < TOP_SIGNIFICANCE}
        # what each node is worth (F-08): the games won by builds taking it against builds without
        # it, both sides with at least 2 builds; the strongest effects first
        impact = {}
        for n in every:
            with_n = [k for k in ranked if n in {node_id(x) for x in nodes.get(k, [])}]
            without = [k for k in ranked if k not in with_n]
            if len(with_n) < 2 or len(without) < 2:
                continue
            rate = lambda ks: sum(tally[k][0] for k in ks) / max(1, sum(tally[k][1] for k in ks))
            impact[n] = round(rate(with_n) - rate(without), 3)
        out_impact = dict(sorted(impact.items(), key=lambda kv: -abs(kv[1]))[:8])
        # the same against each opposing composition (duels: each opposing spec), all builds counted
        impact_vs = {}
        for opp in sorted({o for (k, o) in vs if k.startswith(sp + "@")}):
            per = {}
            keys = [k for k in bs if vs[(k, opp)][1] > 0]
            for n in every:
                w = [k for k in keys if n in {node_id(x) for x in nodes.get(k, [])}]
                wo = [k for k in keys if k not in w]
                if len(w) < 2 or len(wo) < 2:
                    continue
                r = lambda ks: sum(vs[(k, opp)][0] for k in ks) / max(1, sum(vs[(k, opp)][1] for k in ks))
                per[n] = round(r(w) - r(wo), 3)
            impact_vs[opp] = dict(sorted(per.items(), key=lambda kv: -abs(kv[1]))[:6])
        out[sp] = {"builds": dict(sorted(bs.items(), key=lambda kv: -kv[1]["win_rate"])),
                   "impact": out_impact, "impact_vs": impact_vs,
                   "viable": sum(v["viable"] for v in bs.values()), "top": top,
                   "over_share": favoured,
                   "common": {n: v for n, v in high.items() if n not in favoured},
                   "all_share": all_share,
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
