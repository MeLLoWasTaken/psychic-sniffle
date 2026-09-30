#!/usr/bin/env python3
"""Spectrogram review of generated sounds (the model cannot listen; backlog M1-26).

Renders one spectrogram PNG per sound (waveform above, spectrogram below, with peak, loudness,
tonal share and decay in the title) and a contact sheet of several sounds side by side.

  python3 tools/audio/review.py                      # the representative set -> previews/audio/
  python3 tools/audio/review.py hit_mace_plate_01 cc_warning --sheet previews/audio/sheet_x.png
  python3 tools/audio/review.py --levels             # table of levels for every generated file
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
    args = ap.parse_args(argv)
    if args.levels:
        levels()
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
