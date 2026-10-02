"""How much choice a talent tree leaves (backlog M2-04b): the share of random legal builds that take
each node. A node most legal builds take is near-mandatory whatever its strength, so the balance
simulations' "no node in over 90% of the top builds" (DESIGN.md) cannot pass for it.

The rules mirror game/core/talents.gd: a tree has `points`; a node is open when the points spent on
nodes behind lower gates reach its gate, and it is a root, hangs off an ability (a requires_any
name that is not a node of the tree) or a node it requires is fully ranked; a choice node costs 1.
Random builds are drawn like Talents.random_build: one rank at a time to a random open node until
no point can be placed (statistically the same, not the same numbers: Python's generator).

    python3 tools/sim/tree_shape.py [--builds 400] [--over 0.8] [tree ids...]

Exits 1 when a node is in more than --over of the builds (with --check).
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
TALENTS = REPO / "data" / "talents"


def max_rank(n: dict) -> int:
    return 1 if n["type"] == "choice" else int(n.get("ranks", 1))


def cost(n: dict, value: int) -> int:
    return 1 if n["type"] == "choice" else value


def unlocked(nodes: dict, picks: dict, n: dict) -> bool:
    gate = int(n.get("gate", 0))
    if gate > 0:
        before = sum(cost(nodes[i], v) for i, v in picks.items() if int(nodes[i].get("gate", 0)) < gate)
        if before < gate:
            return False
    reqs = n.get("requires_any", [])
    if not reqs:
        return True
    for r in reqs:
        if r not in nodes:
            return True  # an ability the spec has
        if picks.get(r, 0) >= max_rank(nodes[r]):
            return True
    return False


def random_build(tree: dict, rng: random.Random) -> dict:
    nodes = {n["id"]: n for n in tree["nodes"]}
    picks: dict = {}
    points = int(tree["points"])
    while True:
        spent = sum(cost(nodes[i], v) for i, v in picks.items())
        options = []
        for n in tree["nodes"]:
            v = picks.get(n["id"], 0)
            if v < max_rank(n) and spent + 1 <= points and unlocked(nodes, picks, n):  # every step costs 1
                options.append(n["id"])
        if not options:
            return picks
        i = rng.choice(options)
        picks[i] = picks.get(i, 0) + 1


def shares(tree: dict, builds: int, seed: int = 1) -> dict[str, float]:
    rng = random.Random(seed)
    count: dict[str, int] = {n["id"]: 0 for n in tree["nodes"]}
    for _ in range(builds):
        for i in random_build(tree, rng):
            count[i] += 1
    return {i: c / builds for i, c in count.items()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("trees", nargs="*", help="tree ids (data/talents/<id>.json); default every class and spec tree")
    ap.add_argument("--builds", type=int, default=400)
    ap.add_argument("--over", type=float, default=0.8)
    ap.add_argument("--check", action="store_true", help="exit 1 when a node is in more than --over of the builds")
    args = ap.parse_args()
    ids = args.trees or sorted(p.stem for p in TALENTS.glob("*.json") if not p.stem.endswith("_pvp"))
    bad = 0
    for tid in ids:
        tree = json.loads((TALENTS / f"{tid}.json").read_text())
        s = shares(tree, args.builds)
        over = {i: v for i, v in sorted(s.items(), key=lambda kv: -kv[1]) if v > args.over}
        bad += len(over)
        top = sorted(s.items(), key=lambda kv: -kv[1])
        print(f"{tid}: {len(over)} nodes over {args.over:.0%}; most taken "
              + ", ".join(f"{i} {v:.0%}" for i, v in top[:6]) + f"; least taken {top[-1][0]} {top[-1][1]:.0%}")
    return 1 if args.check and bad else 0


if __name__ == "__main__":
    sys.exit(main())
