#!/usr/bin/env python3
"""Spectrogram review of generated sounds (the model cannot listen; backlog M1-26).

Renders one spectrogram PNG per sound (waveform above, spectrogram below, with peak, loudness,
tonal share and decay in the title) and a contact sheet of several sounds side by side.

  python3 tools/audio/review.py                      # the representative set -> previews/audio/
  python3 tools/audio/review.py hit_mace_plate_01 cc_warning --sheet previews/audio/sheet_x.png
  python3 tools/audio/review.py --levels             # table of levels for every generated file
  python3 tools/audio/review.py --compare OLD_SFX_DIR [sheet_weapons ...]
      # before/after table per category and sheets -> previews/audio/x04/ (X-04 processing);
      # OLD_SFX_DIR holds the files of an earlier build, e.g. from `git worktree add` at an older commit
  python3 tools/audio/review.py --arena gallows_courtyard   # sounds through the map's arena reverb
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).parent))
import analysis  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SFX = REPO / "game" / "assets" / "audio" / "sfx"
PREVIEWS = REPO / "previews" / "audio"

# One per school cast and impact, each weapon hit type, footsteps, the CC warning (backlog M1-26)
REPRESENTATIVE = {
    "sheet_weapons": ["hit_greatsword_plate_01", "hit_greatsword_cloth_01", "hit_mace_plate_01", "hit_mace_cloth_01",
                      "hit_staff_plate_01", "hit_staff_cloth_01", "swing_greatsword_01", "swing_mace_01", "swing_staff_01"],
    "sheet_frost": ["frost_cast_start", "frost_cast_loop", "rime_bolt_release", "rime_bolt_impact_01",
                    "frost_channel_loop", "frost_effigy_impact", "rime_fan_release", "interrupt_impact"],
    "sheet_holy": ["holy_cast_start", "holy_cast_loop", "holy_release", "castigate_impact_01", "holy_heal", "heal_quick",
                   "heal_chorus", "seraphic_surge"],
    "sheet_physical_shadow": ["headsmans_verdict_impact", "charge_impact", "dread_roar", "psalm_of_dread", "red_mist",
                              "shield_breaker_impact", "break_free", "gash_wet_01"],
    "sheet_more_impacts": ["hail_impact_01", "heartfreeze_impact", "shiver_lance_impact", "winters_lash_release",
                           "frost_step", "pommel_crack_impact", "throat_punch_impact", "chains_of_awe_impact",
                           "dispel_impact"],
    "sheet_move_ui_warning": ["footstep_plate_01", "footstep_cloth_01", "land_plate_01", "ui_click", "ui_target",
                              "ui_error", "cc_warning", "cc_incoming"],
}


def _measure(x: np.ndarray, sr: int) -> str:
    return (f"peak {analysis.peak_dbfs(x):.1f} dBFS, {analysis.integrated_loudness(x, sr):.1f} LUFS, "
            f"tonal {analysis.tonal_share(x, sr):.0%}, -20 dB in {analysis.decay_time(x, sr) * 1000:.0f} ms")


def _plot(ax_wave, ax_spec, x: np.ndarray, sr: int, title: str, fmax: float = 16000) -> None:
    t = np.arange(len(x)) / sr
    ax_wave.plot(t, x, linewidth=0.4, color="#333")
    ax_wave.set_ylim(-1, 1)
    ax_wave.set_xlim(0, max(t[-1], 0.05))
    ax_wave.set_title(title, fontsize=7)
    ax_wave.tick_params(labelsize=6)
    nfft = 1024 if len(x) > 4096 else 256
    ax_spec.specgram(x, NFFT=nfft, Fs=sr, noverlap=nfft * 3 // 4, cmap="magma", vmin=-120)
    ax_spec.set_ylim(0, fmax)
    ax_spec.set_xlim(0, max(t[-1], 0.05))
    ax_spec.tick_params(labelsize=6)


def _plot_log(ax_wave, ax_spec, x: np.ndarray, sr: int, title: str) -> None:
    """Like _plot, with a logarithmic frequency axis (30 Hz to 16 kHz) so the low-mid body of a
    hit (100-500 Hz) gets as much room as the top octaves."""
    from scipy import signal as sg
    t = np.arange(len(x)) / sr
    ax_wave.plot(t, x, linewidth=0.4, color="#333")
    ax_wave.set_ylim(-1, 1)
    ax_wave.set_xlim(0, max(t[-1], 0.05))
    ax_wave.set_title(title, fontsize=7)
    ax_wave.tick_params(labelsize=6)
    f, tt, s = sg.spectrogram(x, sr, nperseg=2048, noverlap=2048 - 256, mode="psd")
    keep = (f >= 30) & (f <= 16000)
    ax_spec.pcolormesh(tt, f[keep], 10 * np.log10(s[keep] + 1e-14), cmap="magma", vmin=-120, vmax=-30, shading="auto")
    ax_spec.set_yscale("log")
    ax_spec.set_ylim(30, 16000)
    ax_spec.set_yticks([50, 100, 250, 500, 1000, 2500, 5000, 10000])
    ax_spec.set_yticklabels(["50", "100", "250", "500", "1k", "2.5k", "5k", "10k"])
    ax_spec.axhspan(100, 500, color="#6cf", alpha=0.08)  # the low-mid body band
    ax_spec.set_xlim(0, max(t[-1], 0.05))
    ax_spec.tick_params(labelsize=6)


def spectrogram_png(name: str, out: Path) -> Path:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    x, sr = sf.read(SFX / f"{name}.ogg")
    fig, (a, b) = plt.subplots(2, 1, figsize=(8, 5), sharex=True, gridspec_kw={"height_ratios": [1, 3]})
    _plot(a, b, x, sr, f"{name} ({len(x) / sr:.2f} s) - {_measure(x, sr)}")
    b.set_ylabel("frequency (Hz)")
    b.set_xlabel("time (s)")
    fig.tight_layout()
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=90)
    plt.close(fig)
    return out


def sheet(names: list[str], out: Path, cols: int = 3) -> Path:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    names = [n for n in names if (SFX / f"{n}.ogg").exists()]
    rows = (len(names) + cols - 1) // cols
    fig = plt.figure(figsize=(cols * 4.2, rows * 3.0))
    gs = fig.add_gridspec(rows * 2, cols, height_ratios=[1, 3] * rows, hspace=0.55, wspace=0.25)
    for i, n in enumerate(names):
        r, c = divmod(i, cols)
        x, sr = sf.read(SFX / f"{n}.ogg")
        aw = fig.add_subplot(gs[r * 2, c])
        asp = fig.add_subplot(gs[r * 2 + 1, c], sharex=aw)
        m = (f"{analysis.peak_dbfs(x):.1f} dBFS  {analysis.integrated_loudness(x, sr):.1f} LUFS  "
             f"tonal {analysis.tonal_share(x, sr):.0%}")
        _plot(aw, asp, x, sr, f"{n}\n{m}")
        aw.tick_params(labelbottom=False)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=80, bbox_inches="tight")
    plt.close(fig)
    return out


def _categories() -> dict[str, str]:
    """File stem -> category, from the build manifest."""
    import json
    man = json.loads((SFX / "manifest.json").read_text())
    return {stem: m["category"] for m in man.values() for stem in m["files"]}


def _features(x: np.ndarray, sr: int) -> dict[str, float]:
    return {"peak": analysis.peak_dbfs(x), "lufs": analysis.integrated_loudness(x, sr),
            "momentary": analysis.momentary_max(x, sr), "crest": analysis.crest_factor_db(x, sr),
            "low_mid": analysis.low_mid_share(x, sr), "mud": analysis.mud_share(x, sr),
            "harsh": analysis.harsh_share(x, sr), "decay_ms": analysis.decay_time(x, sr) * 1000}


def compare_table(before: Path) -> str:
    """Mean measurements per category, before (files in `before`) and after (the current files).
    low_mid = share of energy 100-500 Hz, mud = 250-500 Hz, harsh = 2.5-5 kHz."""
    cats = _categories()
    rows: dict[str, list[tuple[dict, dict]]] = {}
    for stem, cat in cats.items():
        if not (before / f"{stem}.ogg").exists():
            continue
        a, sr = sf.read(before / f"{stem}.ogg")
        b, _ = sf.read(SFX / f"{stem}.ogg")
        rows.setdefault(cat, []).append((_features(a, sr), _features(b, sr)))
    keys = ["peak", "lufs", "momentary", "crest", "low_mid", "mud", "harsh", "decay_ms"]
    out = [f"{'category':10s} {'n':>3s}  " + "  ".join(f"{k:>15s}" for k in keys)]
    for cat in sorted(rows):
        cells = []
        for k in keys:
            a = np.mean([r[0][k] for r in rows[cat]])
            b = np.mean([r[1][k] for r in rows[cat]])
            pct = k in ("low_mid", "mud", "harsh")
            cells.append(f"{a * 100:6.0f}%>{b * 100:5.0f}%" if pct else f"{a:7.1f}>{b:7.1f}")
        out.append(f"{cat:10s} {len(rows[cat]):3d}  " + "  ".join(f"{c:>15s}" for c in cells))
    return "\n".join(out)


def compare_sheet(names: list[str], before: Path, out: Path) -> Path:
    """Before (left) and after (right) spectrograms of each sound, with crest factor and the
    low-mid share in the titles."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    names = [n for n in names if (SFX / f"{n}.ogg").exists() and (before / f"{n}.ogg").exists()]
    rows = len(names)
    fig = plt.figure(figsize=(2 * 4.6, rows * 2.7))
    gs = fig.add_gridspec(rows * 2, 2, height_ratios=[1, 3] * rows, hspace=0.6, wspace=0.18)
    for i, n in enumerate(names):
        for c, (label, folder) in enumerate((("before", before), ("after", SFX))):
            x, sr = sf.read(folder / f"{n}.ogg")
            f = _features(x, sr)
            aw = fig.add_subplot(gs[i * 2, c])
            asp = fig.add_subplot(gs[i * 2 + 1, c], sharex=aw)
            title = (f"{n} ({label})\n{f['peak']:.1f} dBFS  max {f['momentary']:.1f} LUFS  crest {f['crest']:.1f} dB  "
                     f"100-500 Hz {f['low_mid']:.0%}  2.5-5 kHz {f['harsh']:.0%}")
            _plot_log(aw, asp, x, sr, title)
            aw.tick_params(labelbottom=False)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=72, bbox_inches="tight")
    plt.close(fig)
    return out


IN_ARENA = ["hit_mace_plate_01", "hit_greatsword_plate_01", "rime_bolt_release", "frost_cast_start", "holy_heal",
            "dread_roar", "footstep_plate_01", "cc_warning"]


def arena_sheet(map_id: str, out: Path) -> Path:
    """Each sound as built (left) and as heard in a map (right): through the world bus's arena
    reverb (tools/audio/arena.py, data/acoustics), except the warnings, which stay dry."""
    import json
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import arena
    acoustics_dir = REPO / "data" / "acoustics"
    path = acoustics_dir / f"{map_id}.json"
    reverb = json.loads((path if path.exists() else acoustics_dir / "default.json").read_text())["reverb"]
    cats = _categories()
    names = [n for n in IN_ARENA if (SFX / f"{n}.ogg").exists()]
    fig = plt.figure(figsize=(2 * 4.6, len(names) * 2.7))
    gs = fig.add_gridspec(len(names) * 2, 2, height_ratios=[1, 3] * len(names), hspace=0.6, wspace=0.18)
    for i, n in enumerate(names):
        x, sr = sf.read(SFX / f"{n}.ogg")
        dry = cats.get(n) in ("interface", "warning")
        y = x if dry else arena.godot_reverb(x, reverb, sr, tail_s=1.0)
        for c, (label, s) in enumerate((("as built", x), ("dry: warning bus" if dry else f"in {map_id}", y))):
            s = np.concatenate([s, np.zeros(max(0, len(y) - len(s)))])
            f = _features(s, sr)
            aw = fig.add_subplot(gs[i * 2, c])
            asp = fig.add_subplot(gs[i * 2 + 1, c], sharex=aw)
            _plot_log(aw, asp, s, sr, f"{n} ({label})\n{f['peak']:.1f} dBFS  max {f['momentary']:.1f} LUFS  "
                                      f"-20 dB in {f['decay_ms']:.0f} ms")
            aw.tick_params(labelbottom=False)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=72, bbox_inches="tight")
    plt.close(fig)
    return out


def levels() -> None:
    for p in sorted(SFX.glob("*.ogg")):
        x, sr = sf.read(p)
        print(f"{p.stem:28s} {analysis.peak_dbfs(x):6.1f} dBFS {analysis.integrated_loudness(x, sr):6.1f} LUFS "
              f"(max {analysis.momentary_max(x, sr):6.1f})  tonal {analysis.tonal_share(x, sr):4.0%}  "
              f"centroid {analysis.spectral_centroid(x, sr):5.0f} Hz  <250 Hz {analysis.band_share(x, sr, 250):4.0%}  "
              f"decay {analysis.decay_time(x, sr) * 1000:4.0f} ms  {len(x) / sr:.2f} s")


def main(argv: list[str]) -> int:
    import warnings
    warnings.filterwarnings("ignore")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--sheet", type=Path)
    ap.add_argument("--levels", action="store_true")
    ap.add_argument("--compare", type=Path, metavar="BEFORE_DIR",
                    help="folder of earlier .ogg files: per-category table and before/after sheets (X-04)")
    ap.add_argument("--arena", metavar="MAP_ID", help="sheet of sounds as heard through a map's arena reverb (X-04)")
    args = ap.parse_args(argv)
    if args.levels:
        levels()
        return 0
    if args.compare:
        print(compare_table(args.compare))
        for sheet_name, names in REPRESENTATIVE.items():
            if args.names and sheet_name not in args.names:
                continue
            print(compare_sheet(names, args.compare, PREVIEWS / "x04" / f"compare_{sheet_name}.png"))
        return 0
    if args.arena:
        print(arena_sheet(args.arena, PREVIEWS / "x04" / f"in_{args.arena}.png"))
        return 0
    if args.names:
        if args.sheet:
            print(sheet(args.names, args.sheet))
        else:
            for n in args.names:
                print(spectrogram_png(n, PREVIEWS / f"{n}.png"))
        return 0
    for sheet_name, names in REPRESENTATIVE.items():
        print(sheet(names, PREVIEWS / f"{sheet_name}.png"))
        for n in names:
            if (SFX / f"{n}.ogg").exists():
                spectrogram_png(n, PREVIEWS / f"{n}.png")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
