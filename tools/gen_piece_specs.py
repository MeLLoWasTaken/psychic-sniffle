#!/usr/bin/env python3
"""Write the asset specs (data/assets/<set>_<slot>_<body type>.json, kind "piece") for every piece
of every armor set (data/armor_sets), so each piece builds per body type with build_piece.py.

    python3 tools/gen_piece_specs.py [--check]

--check fails when a spec is missing or out of date (run by the data validator's callers)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BODY_TYPES = ("male", "female")


def specs() -> dict[str, dict]:
    out = {}
    for path in sorted((REPO / "data" / "armor_sets").glob("*.json")):
        st = json.loads(path.read_text())
        for slot, piece in st["pieces"].items():
            for t in BODY_TYPES:
                sid = f"{st['id']}_{slot}_{t}"
                out[sid] = {
                    "id": sid, "kind": "piece", "builder": "build_piece.py", "seed": 1, "body_build": t,
                    "tri_budget": {"min": int(piece["tris"] * 0.8), "max": int(piece["tris"] * 1.1)},
                    "texture_size": int(piece.get("texture_size", 2048)),
                    "params": {"slot": slot, "design": piece["design"], "set": st["id"], "armor_type": st["armor_type"],
                               "tris": int(piece["tris"])},
                    "out": f"game/assets/armor/{sid}.gltf", "status": "draft",
                }
    return out


def main() -> int:
    check = "--check" in sys.argv
    bad = 0
    for sid, spec in specs().items():
        path = REPO / "data" / "assets" / f"{sid}.json"
        text = json.dumps(spec, indent=2) + "\n"
        if path.exists() and path.read_text() == text:
            continue
        if check:
            print(f"out of date: {path.relative_to(REPO)}")
            bad += 1
        else:
            path.write_text(text)
            print(f"wrote {path.relative_to(REPO)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
