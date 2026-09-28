#!/usr/bin/env python3
"""Procedural sound effect generator.

Each recipe is a function that returns a mono float signal at SAMPLE_RATE. Recipes are built
from layers (tones, filtered noise, envelopes) so a sound can be tuned by editing numbers.
The same recipe and seed always produce the same file.

Usage:
  python3 tools/audio/synth.py --list
  python3 tools/audio/synth.py weapon_impact frost_cast_loop holy_heal
  python3 tools/audio/synth.py --all --spectrograms previews/audio
Output: game/assets/audio/sfx/<name>.ogg (Ogg Vorbis, 48 kHz mono).

Loudness rule (docs/DESIGN.md): no sound is louder than the enemy CC warning. Every recipe
declares a peak level in dBFS; the CC warning will use the highest (-1 dBFS), others stay below.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "game" / "assets" / "audio" / "sfx"
SAMPLE_RATE = 48000

RECIPES: dict[str, tuple[callable, float, bool]] = {}  # name -> (fn, peak_dbfs, loops)


def recipe(peak_dbfs: float, loops: bool = False):
    def deco(fn):
        RECIPES[fn.__name__] = (fn, peak_dbfs, loops)
        return fn
    return deco


# ----------------------------------------------------------------------------- building blocks

def t_axis(dur: float) -> np.ndarray:
    return np.arange(int(dur * SAMPLE_RATE)) / SAMPLE_RATE


def env_adsr(n: int, a: float, d: float, s: float, r: float) -> np.ndarray:
    """Attack, decay, release in seconds; sustain level 0..1 fills the remaining time."""
    a_n, d_n, r_n = int(a * SAMPLE_RATE), int(d * SAMPLE_RATE), int(r * SAMPLE_RATE)
    s_n = max(n - a_n - d_n - r_n, 0)
    e = np.concatenate([
        np.linspace(0, 1, a_n, endpoint=False) ** 0.5,
        np.linspace(1, s, d_n, endpoint=False),
        np.full(s_n, s),
        s * np.linspace(1, 0, r_n) ** 2,  # starts exactly at the sustain level: no jump
    ])
    return np.pad(e, (0, max(n - len(e), 0)))[:n]


def env_exp(n: int, decay_s: float, attack_s: float = 0.002) -> np.ndarray:
    t = np.arange(n) / SAMPLE_RATE
    atk = np.clip(t / max(attack_s, 1e-6), 0, 1)
    return atk * np.exp(-t / decay_s)


def sweep(t: np.ndarray, f0: float, f1: float, curve: float = 3.0) -> np.ndarray:
    """Sine whose frequency glides from f0 to f1 (exponential-ish)."""
    k = (1 - np.exp(-curve * t / t[-1])) / (1 - np.exp(-curve))
    freq = f0 + (f1 - f0) * k
    return np.sin(2 * np.pi * np.cumsum(freq) / SAMPLE_RATE)


def noise(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.standard_normal(n)


def bandpass(x: np.ndarray, lo: float, hi: float, order: int = 4) -> np.ndarray:
    sos = signal.butter(order, [lo, hi], btype="band", fs=SAMPLE_RATE, output="sos")
    return signal.sosfilt(sos, x)


def lowpass(x: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    sos = signal.butter(order, cutoff, btype="low", fs=SAMPLE_RATE, output="sos")
    return signal.sosfilt(sos, x)


def highpass(x: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    sos = signal.butter(order, cutoff, btype="high", fs=SAMPLE_RATE, output="sos")
    return signal.sosfilt(sos, x)


def saturate(x: np.ndarray, drive: float) -> np.ndarray:
    return np.tanh(x * drive) / np.tanh(drive)


def normalize(x: np.ndarray) -> np.ndarray:
    peak = np.max(np.abs(x))
    return x / peak if peak > 0 else x


def simple_reverb(x: np.ndarray, rng: np.random.Generator, length_s: float = 1.2, mix: float = 0.25,
                  brightness: float = 6000) -> np.ndarray:
    """Convolution with a decaying noise tail: a cheap, stone-room style reverb."""
    n = int(length_s * SAMPLE_RATE)
    ir = lowpass(noise(n, rng), brightness) * env_exp(n, length_s / 5)
    wet = np.pad(signal.fftconvolve(x, ir), (0, 1))[: len(x) + n]
    dry = np.pad(x, (0, n))
    return (1 - mix) * dry + mix * normalize(wet) * np.max(np.abs(x))


def make_loop(x: np.ndarray, fade_s: float = 0.25) -> np.ndarray:
    """Crossfade the tail into the head so the sound loops without a click."""
    f = int(fade_s * SAMPLE_RATE)
    head, body, tail = x[:f], x[f:-f], x[-f:]
    ramp = np.linspace(0, 1, f)
    return np.concatenate([tail * (1 - ramp) + head * ramp, body])


# ----------------------------------------------------------------------------- recipes

@recipe(peak_dbfs=-3.0)
def weapon_impact(rng: np.random.Generator) -> np.ndarray:
    """Heavy two-handed blade hitting plate: body thump, crunch, metal ring."""
    t = t_axis(1.8)  # long enough for the ring to decay fully (cutting it off clicks)
    n = len(t)
    thump = sweep(t, 140, 45, curve=8) * env_exp(n, 0.09) * 1.0
    crunch = bandpass(noise(n, rng), 900, 5200) * env_exp(n, 0.035) * 0.8
    grit = highpass(noise(n, rng), 5000) * env_exp(n, 0.012) * 0.35
    ring = np.zeros(n)
    base = 780 + rng.uniform(-40, 40)
    for ratio, amp, dec in ((1.0, 0.30, 0.28), (2.76, 0.18, 0.18), (5.40, 0.10, 0.10), (8.93, 0.05, 0.06)):
        ring += amp * np.sin(2 * np.pi * base * ratio * t + rng.uniform(0, 6.28)) * env_exp(n, dec)
    x = saturate(thump + crunch + grit + ring, 1.8)
    return simple_reverb(x, rng, length_s=0.9, mix=0.18)


@recipe(peak_dbfs=-6.0, loops=True)
def frost_cast_loop(rng: np.random.Generator) -> np.ndarray:
    """Held frost cast: icy wind, a cold shimmering drone and crystal glints. Loops seamlessly."""
    dur = 2.5
    t = t_axis(dur)
    n = len(t)
    wind = bandpass(noise(n, rng), 2500, 9000) * (0.55 + 0.25 * np.sin(2 * np.pi * 0.8 * t))
    drone = np.zeros(n)
    for f, a in ((392.0, 0.25), (587.3, 0.18), (1174.7, 0.08)):
        vib = 1 + 0.004 * np.sin(2 * np.pi * 5.1 * t + rng.uniform(0, 6.28))
        drone += a * np.sin(2 * np.pi * np.cumsum(f * vib) / SAMPLE_RATE)
    drone *= 0.6 + 0.4 * np.sin(2 * np.pi * 0.4 * t) ** 2
    glints = np.zeros(n)
    for _ in range(18):
        start = rng.integers(0, n - 6000)
        f = rng.uniform(2600, 6200)
        g_t = np.arange(6000) / SAMPLE_RATE
        glints[start:start + 6000] += 0.22 * np.sin(2 * np.pi * f * g_t) * env_exp(6000, 0.03)
    x = 0.5 * wind + drone + glints
    x = simple_reverb(x, rng, length_s=1.4, mix=0.3, brightness=9000)[:n]
    return make_loop(x, fade_s=0.3)


@recipe(peak_dbfs=-4.0)
def holy_heal(rng: np.random.Generator) -> np.ndarray:
    """Warm heal landing: a rising major chord swell with a bright bell shimmer on top."""
    t = t_axis(2.8)  # long enough for the bells to decay fully
    n = len(t)
    pad = np.zeros(n)
    for f in (220.0, 277.2, 329.6, 440.0, 554.4):  # A major
        for detune in (-0.25, 0.0, 0.3):  # slight detune makes it choir-like
            ff = f * (1 + detune / 100) * (1 + 0.02 * np.minimum(t / 0.6, 1))
            pad += np.sin(2 * np.pi * np.cumsum(ff) / SAMPLE_RATE) * (1 / (1 + f / 400))
    pad = lowpass(pad, 3500) * env_adsr(n, 0.25, 0.3, 0.55, 1.2)
    bell = np.zeros(n)
    for f, a in ((1760.0, 0.25), (2217.5, 0.18), (2637.0, 0.14), (3520.0, 0.08)):
        onset = int(rng.uniform(0.18, 0.32) * SAMPLE_RATE)
        seg = n - onset
        bell[onset:] += a * np.sin(2 * np.pi * f * np.arange(seg) / SAMPLE_RATE) * env_exp(seg, 0.45)
    air = bandpass(noise(n, rng), 6000, 14000) * env_adsr(n, 0.3, 0.2, 0.3, 0.8) * 0.08
    x = normalize(pad) * 0.8 + bell + air
    return simple_reverb(x, rng, length_s=1.6, mix=0.3, brightness=8000)


# ----------------------------------------------------------------------------- output

def render(name: str, out_dir: Path, seed: int = 1) -> Path:
    fn, peak_dbfs, loops = RECIPES[name]
    rng = np.random.default_rng(seed)
    x = normalize(fn(rng)) * 10 ** (peak_dbfs / 20)
    if not loops:  # trim trailing silence below -60 dB and fade the last 20 ms
        idx = np.nonzero(np.abs(x) > 10 ** (-60 / 20))[0]
        x = x[: idx[-1] + 1] if len(idx) else x
        f = min(int(0.02 * SAMPLE_RATE), len(x))
        x[-f:] *= np.linspace(1, 0, f)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{name}.ogg"
    # Vorbis encoding can raise peaks by 1 to 2 dB; measure the encoded file and correct.
    target = 10 ** (peak_dbfs / 20)
    for _ in range(4):
        sf.write(path, x.astype(np.float32), SAMPLE_RATE, format="OGG", subtype="VORBIS")
        peak = np.max(np.abs(sf.read(path)[0]))
        if peak <= target * 1.03:
            break
        x = x * (target / peak)
    return path


def spectrogram(path: Path, out_png: Path) -> Path:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    x, sr = sf.read(path)
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 5), sharex=True,
                                   gridspec_kw={"height_ratios": [1, 3]})
    t = np.arange(len(x)) / sr
    ax1.plot(t, x, linewidth=0.4, color="#333")
    ax1.set_ylim(-1, 1)
    ax1.set_ylabel("amplitude")
    ax1.set_title(f"{path.stem}  ({len(x) / sr:.2f} s, peak {20 * np.log10(np.max(np.abs(x)) + 1e-9):.1f} dBFS)")
    ax2.specgram(x, NFFT=1024, Fs=sr, noverlap=768, cmap="magma", vmin=-120)
    ax2.set_ylim(0, 16000)
    ax2.set_ylabel("frequency (Hz)")
    ax2.set_xlabel("time (s)")
    fig.tight_layout()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=90)
    plt.close(fig)
    return out_png


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate procedural sound effects")
    parser.add_argument("names", nargs="*")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--out", type=Path, default=OUT_DIR)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--spectrograms", type=Path, help="Folder for spectrogram PNGs to review")
    args = parser.parse_args(argv)
    args.out = args.out.resolve()
    if args.spectrograms:
        args.spectrograms = args.spectrograms.resolve()
    if args.list:
        for name, (fn, peak, loops) in RECIPES.items():
            print(f"{name:20s} peak {peak:5.1f} dBFS  {'loop' if loops else 'one-shot'}  {fn.__doc__.splitlines()[0]}")
        return 0
    names = list(RECIPES) if args.all else args.names
    unknown = [n for n in names if n not in RECIPES]
    if unknown or not names:
        parser.error(f"unknown or missing sound names: {unknown or '(none)'}; use --list")
    for name in names:
        path = render(name, args.out, args.seed)
        print(f"WROTE {path.relative_to(REPO)}")
        if args.spectrograms:
            png = spectrogram(path, args.spectrograms / f"{name}.png")
            print(f"SPECTROGRAM {png.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
