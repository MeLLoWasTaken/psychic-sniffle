#!/usr/bin/env python3
"""Build the ability and aura icon art (backlog X-03) from game-icons.net glyphs.

Every ability and aura names its glyph in data as icon.image = "<author>/<name>". This script:

  1. copies the used SVGs from a game-icons checkout into game/assets/icons/game-icons/
     (only with --source; the copies in the repo are otherwise the input),
  2. renders each glyph to game/assets/icons/glyphs/<author>/<name>.png: a light engraved tone
     lit from the top left, a dark outline and a drop shadow, on transparency, 128 px,
  3. renders the shared layers, game/assets/icons/frame.png (bevelled dark-iron frame, clear
     center) and game/assets/icons/shade.png (vignette and painted grain),
  4. writes game/assets/icons/game-icons/ATTRIBUTION.md (icon, author, licence, used by).

The school color is not baked in: the HUD paints it at run time from the effect palette under
the shade, glyph and frame layers (game/ui/hud_style.gd), so a palette change needs no rebuild.

  python3 tools/build_icons.py --source /tmp/x03/icons   # copy new glyphs and render
  python3 tools/build_icons.py                           # re-render from the repo copies
  python3 tools/build_icons.py --check                   # exit 1 if any image is missing

Needs resvg-py, pillow, numpy and scipy (tools/env/setup_cloud.sh).
"""
from __future__ import annotations

import argparse
import io
import json
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

REPO = Path(__file__).resolve().parent.parent
ICONS = REPO / "game" / "assets" / "icons"
SVG_DIR = ICONS / "game-icons"
GLYPH_DIR = ICONS / "glyphs"
SIZE = 128  # output pixels; drawn at 50 logical px on the action bar, up to ~120 at 4K
SS = 4  # supersampling
GLYPH_FRAC = 0.74  # glyph box as a fraction of the icon

# game-icons.net contributors used (folder -> display name, licence). license.txt in the
# icons repository lists the authors; all are CC BY 3.0 except those it marks CC0.
AUTHORS = {
    "lorc": ("Lorc", "CC BY 3.0", "https://lorcblog.blogspot.com"),
    "delapouite": ("Delapouite", "CC BY 3.0", "https://delapouite.com"),
    "skoll": ("Skoll", "CC BY 3.0", "https://game-icons.net"),
    "sbed": ("Sbed", "CC BY 3.0", "https://opengameart.org/content/95-game-icons"),
    "zeromancer": ("Zeromancer", "CC0", "https://game-icons.net"),
    "viscious-speed": ("Viscious Speed", "CC0", "https://viscious-speed.deviantart.com"),
    "carl-olsen": ("Carl Olsen", "CC BY 3.0", "https://game-icons.net"),
    "darkzaitzev": ("DarkZaitzev", "CC BY 3.0", "https://darkzaitzev.deviantart.com"),
    "caro-asercion": ("Caro Asercion", "CC BY 3.0", "https://game-icons.net"),
    "cathelineau": ("Cathelineau", "CC BY 3.0", "https://game-icons.net"),
}

# Engraved glyph tone (warm bone), outline and shadow; neutral so the school tint shows through.
GLYPH_LIGHT = np.array([0.99, 0.95, 0.86])
GLYPH_DARK = np.array([0.62, 0.55, 0.45])
OUTLINE = np.array([0.05, 0.035, 0.025])
IRON_LIGHT = np.array([0.46, 0.43, 0.39])
IRON_DARK = np.array([0.10, 0.09, 0.08])
BRONZE = np.array([0.48, 0.39, 0.26])  # hud style frame_border #7a6443


def used_images(data: Path) -> dict[str, list[str]]:
    """image id -> ids of the abilities, auras and talents that use it."""
    out: dict[str, list[str]] = {}
    for folder in ("abilities", "auras"):
        for path in sorted((data / folder).glob("*.json")):
            doc = json.loads(path.read_text())
            img = doc.get("icon", {}).get("image")
            if img:
                out.setdefault(img, []).append(f"{folder[:-1] if folder == 'auras' else 'ability'}:{doc['id']}")
    for path in sorted((data / "talents").glob("*.json")):
        doc = json.loads(path.read_text())
        for n in doc["nodes"]:
            for item in [n] + n.get("choices", []):
                img = item.get("icon", {}).get("image")
                if img:
                    out.setdefault(img, []).append(f"talent:{item['id']}")
    return out


def _mask_from_svg(svg: Path, px: int) -> np.ndarray:
    """Glyph coverage 0..1 at px x px (game-icons: white shape on a black square)."""
    import resvg_py

    png = bytes(resvg_py.svg_to_bytes(svg_path=str(svg), width=px, height=px))
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    a = np.asarray(img, dtype=np.float32) / 255.0
    lum = a[..., :3].mean(axis=2) * a[..., 3]
    return np.clip(lum, 0.0, 1.0)


def _downsample(rgba: np.ndarray, size: int) -> Image.Image:
    """Premultiplied Lanczos downsample (no dark fringes), straight alpha out."""
    alpha = rgba[..., 3:4]
    pre = np.concatenate([rgba[..., :3] * alpha, alpha], axis=2)
    chans = [Image.fromarray(pre[..., i].astype(np.float32), "F").resize((size, size), Image.LANCZOS) for i in range(4)]
    out = np.stack([np.asarray(c) for c in chans], axis=2)
    a = np.clip(out[..., 3:4], 0.0, 1.0)
    rgb = np.where(a > 1e-4, out[..., :3] / np.maximum(a, 1e-4), 0.0)
    res = np.concatenate([np.clip(rgb, 0, 1), a], axis=2)
    return Image.fromarray((res * 255.0 + 0.5).astype(np.uint8), "RGBA")


def _over(dst: np.ndarray, rgb: np.ndarray, a: np.ndarray) -> None:
    """Composite a straight-alpha layer over dst (straight alpha) in place."""
    a = a[..., None]
    da = dst[..., 3:4]
    out_a = a + da * (1.0 - a)
    dst[..., :3] = np.where(out_a > 1e-6, (rgb * a + dst[..., :3] * da * (1.0 - a)) / np.maximum(out_a, 1e-6), 0.0)
    dst[..., 3:4] = out_a


def render_glyph(svg: Path) -> Image.Image:
    n = SIZE * SS
    g = int(round(n * GLYPH_FRAC))
    m = np.zeros((n, n), np.float32)
    off = (n - g) // 2
    m[off:off + g, off:off + g] = _mask_from_svg(svg, g)
    inside = m > 0.5
    # outline: a round dilation, antialiased from the distance to the glyph
    d_out = ndimage.distance_transform_edt(~inside)
    r_out = n * 0.034
    outline = np.clip(r_out - d_out + 0.5 * SS, 0.0, 1.0)
    outline = np.maximum(outline, m)
    # drop shadow: the outlined shape, down and right, blurred
    shadow = ndimage.shift(outline, (n * 0.028, n * 0.018), order=1)
    shadow = ndimage.gaussian_filter(shadow, n * 0.02) * 0.8
    # engraved fill: vertical tone, lit from the top left by the gradient of a soft height map,
    # with darkened edges like a chiselled bevel
    d_in = ndimage.distance_transform_edt(inside)
    height = np.clip(d_in / (n * 0.03), 0.0, 1.0)
    height = ndimage.gaussian_filter(height, n * 0.006)
    gy, gx = np.gradient(height)
    light = -(gx * -0.62 + gy * -0.78) * (n * 0.03)  # light from the upper left
    ys = np.linspace(0.0, 1.0, n)[:, None]
    tone = 1.0 - 0.38 * ys  # brighter at the top
    base = GLYPH_DARK + (GLYPH_LIGHT - GLYPH_DARK) * tone[..., None]
    fill = base * (0.78 + 0.22 * height)[..., None]
    fill = fill + np.clip(light, 0, 1)[..., None] * 0.35 - np.clip(-light, 0, 1)[..., None] * 0.35
    rgba = np.zeros((n, n, 4), np.float32)
    _over(rgba, np.zeros(3), shadow)
    _over(rgba, OUTLINE, outline * 0.96)
    _over(rgba, np.clip(fill, 0, 1), m)
    return _downsample(rgba, SIZE)


def render_frame() -> Image.Image:
    """Bevelled dark-iron frame with a clear center, lit from the top left."""
    n = SIZE * SS
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) + 0.5
    edge = np.minimum(np.minimum(x, y), np.minimum(n - x, n - y))  # distance to the outer edge
    band = n * 0.085
    black = n * 0.014
    rgba = np.zeros((n, n, 4), np.float32)
    # which side each band pixel is on decides its light: top and left lit, bottom and right dark
    side_light = np.select([edge == y, edge == x, edge == n - y, edge == n - x], [1.0, 0.55, -0.9, -0.55], 0.0)
    t = np.clip((edge - black) / (band - black), 0.0, 1.0)  # 0 outer .. 1 inner across the band
    profile = np.sin(t * np.pi) * 0.5 + 0.5 * (1.0 - t)  # rounded bevel
    rng = np.random.default_rng(7)
    grain = ndimage.gaussian_filter(rng.standard_normal((n, n)).astype(np.float32), SS * 1.2) * 1.6
    k = np.clip(0.42 + 0.34 * side_light * profile + 0.05 * grain, 0.0, 1.0)
    iron = IRON_DARK + (IRON_LIGHT - IRON_DARK) * k[..., None]
    in_band = (edge < band).astype(np.float32)
    _over(rgba, iron, in_band)
    # outer black line and inner bronze hairline
    _over(rgba, OUTLINE, np.clip(black - edge + 0.5 * SS, 0.0, 1.0))
    bronze = np.clip(1.0 - np.abs(edge - band) / (SS * 0.8), 0.0, 1.0)
    _over(rgba, BRONZE * 1.1, bronze * 0.9)
    # small rivets in the corners of the band
    for cx, cy in ((band * 0.5, band * 0.5), (n - band * 0.5, band * 0.5), (band * 0.5, n - band * 0.5), (n - band * 0.5, n - band * 0.5)):
        d = np.hypot(x - cx, y - cy)
        rv = np.clip(n * 0.022 - d + 0.5 * SS, 0.0, 1.0)
        lit = np.clip(0.5 - ((x - cx) + (y - cy)) / (n * 0.05), 0.0, 1.0)
        _over(rgba, IRON_DARK + (IRON_LIGHT * 1.5 - IRON_DARK) * lit[..., None], rv)
    # inner shadow cast onto the icon face
    inner = np.clip(1.0 - (edge - band) / (n * 0.07), 0.0, 1.0) * (edge >= band)
    _over(rgba, np.zeros(3), inner ** 1.6 * 0.6)
    return _downsample(rgba, SIZE)


def render_shade() -> Image.Image:
    """Neutral light and grain over the school gradient: vignette, top-left glow, brush grain."""
    n = SIZE * SS
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) / n
    rgba = np.zeros((n, n, 4), np.float32)
    r = np.hypot(x - 0.5, y - 0.5) / 0.7071
    _over(rgba, np.zeros(3), np.clip(r - 0.35, 0.0, 1.0) ** 1.4 * 0.75)
    glow = np.exp(-(((x - 0.32) ** 2 + (y - 0.28) ** 2) / 0.06))
    _over(rgba, np.array([1.0, 0.97, 0.9]), glow * 0.16)
    rng = np.random.default_rng(3)
    noise = rng.standard_normal((n, n)).astype(np.float32)
    strokes = ndimage.gaussian_filter(noise, (SS * 10, SS * 1.5))  # streaky, like brushed paint
    strokes = ndimage.rotate(strokes, 35, reshape=False, mode="wrap")
    strokes /= max(1e-6, float(np.abs(strokes).max()))
    _over(rgba, np.zeros(3), np.clip(-strokes, 0, 1) * 0.22)
    _over(rgba, np.ones(3), np.clip(strokes, 0, 1) * 0.08)
    return _downsample(rgba, SIZE)


def write_attribution(images: dict[str, list[str]]) -> None:
    names = sorted({AUTHORS[i.split("/")[0]][0] for i in images})
    who = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
    lines = [
        "# game-icons.net glyphs",
        "",
        "Icons from https://game-icons.net (git: github.com/game-icons/icons), used under the licence of",
        f"each author. Icons made by {who} (see the table). The SVGs here are",
        "unmodified; the game renders them with its own colors, outline, shading and frame",
        "(tools/build_icons.py). Written by tools/build_icons.py; do not edit by hand.",
        "",
        "| Icon | Author | Licence | Used by |",
        "| --- | --- | --- | --- |",
    ]
    for img in sorted(images):
        author, name = img.split("/")
        disp, lic, _url = AUTHORS[author]
        lines.append(f"| {name} | {disp} | {lic} | {', '.join(images[img])} |")
    lines.append("")
    (SVG_DIR / "ATTRIBUTION.md").write_text("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, help="game-icons checkout to copy the used SVGs from")
    ap.add_argument("--check", action="store_true", help="only report missing SVGs or PNGs")
    args = ap.parse_args()
    images = used_images(REPO / "data")
    problems = []
    for img in sorted(images):
        author = img.split("/")[0]
        if author not in AUTHORS:
            problems.append(f"{img}: author '{author}' has no licence entry in AUTHORS")
        svg = SVG_DIR / f"{img}.svg"
        if args.source and not args.check:
            src = args.source / f"{img}.svg"
            if not src.exists():
                problems.append(f"{img}: not in {args.source}")
                continue
            svg.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, svg)
        if not svg.exists():
            problems.append(f"{img}: {svg.relative_to(REPO)} missing")
        if args.check and not (GLYPH_DIR / f"{img}.png").exists():
            problems.append(f"{img}: glyphs/{img}.png missing (run tools/build_icons.py)")
    if problems:
        print("\n".join(problems))
        return 1
    if args.check:
        print(f"{len(images)} icon images present")
        return 0
    outputs = []
    for img in sorted(images):
        out = GLYPH_DIR / f"{img}.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        render_glyph(SVG_DIR / f"{img}.svg").save(out, optimize=True)
        outputs.append(out)
    render_frame().save(ICONS / "frame.png", optimize=True)
    render_shade().save(ICONS / "shade.png", optimize=True)
    outputs += [ICONS / "frame.png", ICONS / "shade.png"]
    for out in outputs:
        # the HUD draws these 128 px layers at 20-60 px: import them with mipmaps (Godot fills in
        # the rest of the import file on the next --import)
        imp = out.with_suffix(".png.import")
        if not imp.exists():
            imp.write_text('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\nmipmaps/generate=true\n')
    write_attribution(images)
    # remove SVGs and PNGs no longer used by any ability or aura
    for folder, ext in ((SVG_DIR, ".svg"), (GLYPH_DIR, ".png")):
        for f in folder.glob(f"*/*{ext}"):
            if f"{f.parent.name}/{f.stem}" not in images:
                f.unlink()
                imp = f.with_suffix(f.suffix + ".import")
                if imp.exists():
                    imp.unlink()
    print(f"rendered {len(images)} glyphs, frame and shade into {ICONS.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
