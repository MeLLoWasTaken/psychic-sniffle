#!/usr/bin/env python3
"""Measure each school's effect color in the effects review screenshot (backlog M1-25).

"Each spell school is identifiable by color alone in a screenshot" (docs/DESIGN.md quality bar).
Takes the school sheet (scenes/tests/effects_view.tscn --mode schools), the same frame rendered
without effects (--no-effects) and the cell layout the scene wrote, finds the effect pixels of each
cell (those that differ from the background), and reports their mean hue (circular, weighted by
how much each pixel changed and by its saturation), saturation and value, as seen on screen.

Two schools are told apart when their hues are at least --min-hue degrees apart (both colorful),
or their value or saturation differ clearly (for white or dark schools such as physical and
blood). Exit code 1 when any pair is too close.

  python3 tools/effects_hues.py --image previews/effects/schools.png \
      --background previews/effects/schools_bg.png --layout previews/effects/schools_layout.json \
      --out previews/effects/school_hues.json
"""
from __future__ import annotations

import argparse
import colorsys
import itertools
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

CHROMATIC_SAT = 0.18  # below this mean saturation (as seen, over a grey-brown floor) a school counts as white or grey
MIN_VALUE_GAP = 0.18
MIN_SAT_GAP = 0.15


def measure(img: np.ndarray, bg: np.ndarray, rect: list[int], threshold: float) -> dict:
    x0, y0, x1, y1 = (max(0, v) for v in rect)
    a = img[y0:y1, x0:x1].reshape(-1, 3)
    b = bg[y0:y1, x0:x1].reshape(-1, 3)
    diff = np.abs(a - b).sum(axis=1)
    mask = diff > threshold
    if mask.sum() < 50:
        return {"pixels": int(mask.sum())}
    px = a[mask]
    w = diff[mask]
    hsv = np.array([colorsys.rgb_to_hsv(*p) for p in px])
    h, s, v = hsv[:, 0] * 2 * math.pi, hsv[:, 1], hsv[:, 2]
    hw = w * s
    mean_h = math.degrees(math.atan2((np.sin(h) * hw).sum(), (np.cos(h) * hw).sum())) % 360
    # how concentrated the hues are (1: one hue, 0: spread all round)
    spread = math.hypot((np.sin(h) * hw).sum(), (np.cos(h) * hw).sum()) / max(hw.sum(), 1e-9)
    added = (a[mask] - b[mask]).clip(0, 1)
    add_rgb = (added * w[:, None]).sum(axis=0) / w.sum()
    add_h, add_s, add_v = colorsys.rgb_to_hsv(*add_rgb)
    return {
        "pixels": int(mask.sum()),
        "hue_deg": round(mean_h, 1),
        "hue_concentration": round(spread, 3),
        "saturation": round(float((s * w).sum() / w.sum()), 3),
        "value": round(float((v * w).sum() / w.sum()), 3),
        "mean_rgb": [round(float(c), 3) for c in (px * w[:, None]).sum(axis=0) / w.sum()],
        "added_hue_deg": round(add_h * 360, 1),
        "added_saturation": round(add_s, 3),
    }


def hue_gap(a: float, b: float) -> float:
    d = abs(a - b) % 360
    return min(d, 360 - d)


def compare(results: dict, min_hue: float) -> list[dict]:
    pairs = []
    for (na, ra), (nb, rb) in itertools.combinations(results.items(), 2):
        if "hue_deg" not in ra or "hue_deg" not in rb:
            pairs.append({"a": na, "b": nb, "ok": False, "why": "no effect pixels"})
            continue
        gap = hue_gap(ra["hue_deg"], rb["hue_deg"])
        dv = abs(ra["value"] - rb["value"])
        ds = abs(ra["saturation"] - rb["saturation"])
        chroma_a, chroma_b = ra["saturation"] >= CHROMATIC_SAT, rb["saturation"] >= CHROMATIC_SAT
        if chroma_a and chroma_b:
            ok = gap >= min_hue or dv >= MIN_VALUE_GAP
            why = f"hue {gap:.0f} deg apart" + (f", value differs {dv:.2f}" if dv >= MIN_VALUE_GAP else "")
        elif chroma_a != chroma_b:
            ok = ds >= MIN_SAT_GAP or dv >= MIN_VALUE_GAP
            why = f"saturation differs {ds:.2f}, value {dv:.2f}"
        else:
            ok = dv >= MIN_VALUE_GAP or gap >= min_hue
            why = f"both pale: value differs {dv:.2f}, hue {gap:.0f} deg"
        pairs.append({"a": na, "b": nb, "ok": bool(ok), "hue_gap_deg": round(gap, 1), "why": why})
    return pairs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--image", type=Path, required=True)
    ap.add_argument("--background", type=Path, required=True)
    ap.add_argument("--layout", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--min-hue", type=float, default=30.0)
    ap.add_argument("--threshold", type=float, default=0.12, help="summed RGB change (0-3) that marks an effect pixel")
    args = ap.parse_args()
    img = np.asarray(Image.open(args.image).convert("RGB"), dtype=np.float64) / 255.0
    bg = np.asarray(Image.open(args.background).convert("RGB"), dtype=np.float64) / 255.0
    layout = json.loads(args.layout.read_text())
    # the layout is in the viewport's coordinates, which the window may scale (stretch mode)
    sx = img.shape[1] / float(layout.get("viewport", [img.shape[1]])[0])
    sy = img.shape[0] / float(layout.get("viewport", [0, img.shape[0]])[1])
    results = {}
    for c in layout["cells"]:
        x0, y0, x1, y1 = c["rect"]
        rect = [round(x0 * sx), round(y0 * sy), round(x1 * sx), round(y1 * sy)]
        results[c["name"]] = measure(img, bg, rect, args.threshold)
    pairs = compare(results, args.min_hue)
    close = [p for p in pairs if not p["ok"]]
    report = {"image": str(args.image), "min_hue_deg": args.min_hue, "schools": results,
              "closest_pairs": sorted((p for p in pairs if "hue_gap_deg" in p), key=lambda p: p["hue_gap_deg"])[:8],
              "failing_pairs": close, "pass": not close}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    for name, r in results.items():
        if "hue_deg" in r:
            print(f"{name:10s} hue {r['hue_deg']:6.1f}  sat {r['saturation']:.2f}  val {r['value']:.2f}  px {r['pixels']}")
        else:
            print(f"{name:10s} no effect pixels")
    for p in close:
        print(f"TOO CLOSE {p['a']} / {p['b']}: {p['why']}")
    print("PASS school colors are distinct" if not close else f"FAIL {len(close)} pair(s) too close")
    return 0 if not close else 1


if __name__ == "__main__":
    sys.exit(main())
