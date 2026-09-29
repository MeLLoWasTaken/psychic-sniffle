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
VARIANTS: dict[str, int] = {}  # name -> number of seeded variations to render (_01, _02, ...)


def recipe(peak_dbfs: float, loops: bool = False, variants: int = 1):
    """Register a recipe. Sounds heard often (hits) get several seeded variations so repeats
    do not sound identical; the game picks one at random (AudioStreamRandomizer)."""
    def deco(fn):
        RECIPES[fn.__name__] = (fn, peak_dbfs, loops)
        VARIANTS[fn.__name__] = variants
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


def resonator(x: np.ndarray, freq: float, q: float) -> np.ndarray:
    """Narrow resonant band: noise through this sounds like struck material, not a pure note."""
    b, a = signal.iirpeak(freq, q, fs=SAMPLE_RATE)
    return signal.lfilter(b, a, x)


def grains(n: int, rng: np.random.Generator, per_second: float, decay_s: float) -> np.ndarray:
    """Random short impulses (a crackle envelope) for crunch and debris textures."""
    env = np.zeros(n)
    count = max(1, int(per_second * n / SAMPLE_RATE))
    g = env_exp(int(decay_s * 6 * SAMPLE_RATE), decay_s, attack_s=0.0005)
    for _ in range(count):
        s = rng.integers(0, n)
        e = min(n, s + len(g))
        env[s:e] += g[: e - s] * rng.uniform(0.3, 1.0)
    return env


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

@recipe(peak_dbfs=-3.0, variants=3)
def impact_blunt(rng: np.random.Generator) -> np.ndarray:
    """Blunt weapon (mace, hammer, staff, fist) hitting armour and body: crack, thud, crunch, clang.

    v2 (human feedback: v1 "sounds like you scored a point"). v1 was built on sustained pure
    tones, which read as a chime. v2 has no pure tone above 200 Hz: its energy is a sharp
    broadband crack, a heavy low thud, a crackling mid crunch, and metal made from narrow
    resonant noise bands that die away within about 0.1 s.
    """
    t = t_axis(0.8)
    n = len(t)
    white = noise(n, rng)
    # 1. crack: a few milliseconds of broadband noise, the moment of contact
    crack = highpass(white, 1500) * env_exp(n, 0.004, attack_s=0.0003) * 1.2
    # 2. thud: falling low sine (the weight behind the swing) plus a short sub push
    thud = sweep(t, 190, 48, curve=10) * env_exp(n, 0.075, attack_s=0.001) * 1.0
    sub = np.sin(2 * np.pi * 42 * t) * env_exp(n, 0.05, attack_s=0.003) * 0.6
    # 3. chunk: low-mid noise body (flesh and padding under the armour)
    chunk = bandpass(noise(n, rng), 120, 700) * env_exp(n, 0.05, attack_s=0.001) * 1.4
    # 4. crunch: mid noise shaped by a dense crackle, like links and plates grinding
    crunch_env = grains(n, rng, per_second=900, decay_s=0.003) * env_exp(n, 0.06)
    crunch = bandpass(noise(n, rng), 700, 4500) * crunch_env * 0.9
    # 5. clang: noise through inharmonic resonators, decaying fast so no note is heard
    clang = np.zeros(n)
    base = rng.uniform(900, 1300)
    for ratio, q, amp, dec in ((1.0, 18, 0.9, 0.07), (1.73, 22, 0.7, 0.055), (2.61, 25, 0.5, 0.045),
                               (3.94, 28, 0.35, 0.035), (5.37, 30, 0.25, 0.025)):
        clang += resonator(noise(n, rng), base * ratio, q) * env_exp(n, dec, attack_s=0.0005) * amp
    clang = highpass(clang, 700) * 0.9
    x = crack + thud + sub + chunk + crunch + clang
    x = saturate(normalize(x) * 1.0, 3.0)  # heavy saturation glues the layers and adds grit
    return simple_reverb(x, rng, length_s=0.5, mix=0.10, brightness=3500)


@recipe(peak_dbfs=-3.0, variants=3)
def impact_slash(rng: np.random.Generator) -> np.ndarray:
    """Edged weapon (sword, axe) cutting through armour and body: bright edge, swish, wet cut.

    Human feedback on the single weapon hit: it sounded blunt, and a sword should sound like a
    slash. A slash is brighter and moves: the edge rings briefly as it draws across, the noise
    sweeps downward like a blade passing, and the low thud is light.
    """
    t = t_axis(0.7)
    n = len(t)
    # 1. swish: noise bands from bright to darker, each faded in and out by an overlapping
    #    window so the sweep is smooth (switching filters abruptly leaves clicks)
    sw = noise(n, rng)
    swish = np.zeros(n)
    seg = int(0.12 * SAMPLE_RATE)
    bands = np.linspace([5200, 9000], [1400, 3600], 6)
    width = seg // 3
    for i, (lo, hi) in enumerate(bands):
        centre = int(i * (seg - width) / (len(bands) - 1)) + width // 2
        win = np.zeros(n)
        a = max(centre - width // 2, 0)
        win[a:a + width] = np.hanning(width)[: min(width, n - a)]
        swish += bandpass(sw, lo, hi) * win
    swish *= 0.8
    # 2. edge: bright metal "shing" from resonant noise, short (a long ring reads as a chime)
    edge = np.zeros(n)
    base = rng.uniform(2600, 3400)
    for ratio, q, amp, dec in ((1.0, 18, 0.9, 0.05), (1.52, 20, 0.6, 0.04), (2.31, 22, 0.4, 0.03)):
        edge += resonator(noise(n, rng), base * ratio, q) * env_exp(n, dec, attack_s=0.002) * amp
    edge = highpass(edge, 1800) * 1.0
    # 3. cut: wet, crackling mid noise (the blade through padding and flesh)
    cut_env = grains(n, rng, per_second=1400, decay_s=0.002) * env_exp(n, 0.05, attack_s=0.001)
    cut = bandpass(noise(n, rng), 900, 3800) * cut_env * 0.9
    # 4. light thud: much less weight than a blunt hit
    thud = sweep(t, 140, 70, curve=10) * env_exp(n, 0.035, attack_s=0.001) * 0.45
    tick = highpass(noise(n, rng), 3000) * env_exp(n, 0.003, attack_s=0.0003) * 0.8
    x = swish + edge + cut + thud + tick
    x = saturate(normalize(x), 2.0)
    return simple_reverb(x, rng, length_s=0.5, mix=0.10, brightness=6000)


@recipe(peak_dbfs=-3.0, variants=3)
def impact_pierce(rng: np.random.Generator) -> np.ndarray:
    """Piercing weapon (dagger, spear, arrow) striking: tight thunk, sharp tip click, short and dry."""
    t = t_axis(0.35)
    n = len(t)
    tip = highpass(noise(n, rng), 2500) * env_exp(n, 0.0025, attack_s=0.0002) * 1.1
    # thunk mostly from low noise: a saturated low sine alone adds evenly spaced harmonics that
    # read as a pitch (measured 50% tonal before this change)
    thunk = lowpass(noise(n, rng), 450) * env_exp(n, 0.03, attack_s=0.0008) * 1.8
    body = bandpass(noise(n, rng), 250, 1200) * env_exp(n, 0.025, attack_s=0.0008) * 0.9
    wet_env = grains(n, rng, per_second=700, decay_s=0.002) * env_exp(n, 0.03)
    wet = bandpass(noise(n, rng), 1200, 4000) * wet_env * 0.6
    x = tip + thunk + body + wet
    x = saturate(normalize(x), 1.6)
    return simple_reverb(x, rng, length_s=0.35, mix=0.08, brightness=4000)


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
    """Heal landing with weight: a short build-up, a soft deep impact, a warm chord, a lower shimmer.

    v2 (human feedback: v1 "pretty decent, but needs to sound meatier"; its light, high ring
    alone had no weight). v2 adds a sub and low-octave body, a soft low impact where the heal
    lands, and a rising build-up into it; the shimmer moves down an octave and is quieter.
    """
    t = t_axis(3.2)
    n = len(t)
    land = int(0.22 * SAMPLE_RATE)  # the moment the heal lands
    # 1. build-up: filtered noise rising into the landing, then falling away quickly (not cut
    #    off: an instant stop clicks)
    rise = np.zeros(n)
    rise[:land] = np.linspace(0, 1, land) ** 2.5
    rise[land:] = env_exp(n - land, 0.04, attack_s=0.0)
    build = bandpass(noise(n, rng), 400, 5000) * rise * 0.35
    # 2. impact: soft, deep "whomp" at the landing (sine drop plus a muffled air push)
    t_land = np.arange(n - land) / SAMPLE_RATE
    whomp = np.zeros(n)
    whomp[land:] = np.sin(2 * np.pi * np.cumsum(55 + 75 * np.exp(-t_land / 0.05)) / SAMPLE_RATE) \
        * env_exp(n - land, 0.28, attack_s=0.004) * 1.0
    push = np.zeros(n)
    push[land:] = lowpass(noise(n - land, rng), 700) * env_exp(n - land, 0.12, attack_s=0.003) * 0.9
    # 3. body: A major chord with a low octave and a sub, lightly saturated for warmth
    body = np.zeros(n)
    for f, w in ((55.0, 1.0), (110.0, 0.9), (220.0, 0.6), (277.2, 0.45), (329.6, 0.45), (440.0, 0.3)):
        for detune in (-0.3, 0.0, 0.25):
            ff = f * (1 + detune / 100)
            body += w * np.sin(2 * np.pi * np.cumsum(np.full(n, ff)) / SAMPLE_RATE)
    # quiet under the build-up, then up to full over 20 ms at the landing (a one-sample jump clicks)
    pre = np.linspace(0, 1, land) ** 1.5 * 0.2
    jump = int(0.02 * SAMPLE_RATE)
    body_env = np.concatenate([pre, np.linspace(0.2, 1.0, jump), np.ones(n - land - jump)])
    body = saturate(lowpass(body, 2500) / 6, 1.6) * body_env * env_adsr(n, 0.001, 0.4, 0.6, 1.6) * 1.2
    # 4. ring: bells two octaves below v1 (feedback on v2: "lower the pitch of the ring"), each
    #    with soft inharmonic overtones so a low bell still sounds like a bell, not a hum
    bell = np.zeros(n)
    for f, a in ((440.0, 0.22), (554.4, 0.16), (659.3, 0.13)):
        onset = land + int(rng.uniform(0.0, 0.05) * SAMPLE_RATE)
        seg = n - onset
        ts = np.arange(seg) / SAMPLE_RATE
        for ratio, pa, dec in ((1.0, 1.0, 0.7), (2.0, 0.35, 0.45), (2.76, 0.18, 0.3), (5.4, 0.06, 0.15)):
            bell[onset:] += a * pa * np.sin(2 * np.pi * f * ratio * ts) * env_exp(seg, dec)
    x = build + whomp + push + normalize(body) * 0.9 + bell
    return simple_reverb(x, rng, length_s=1.6, mix=0.25, brightness=6000)


# ----------------------------------------------------------------------------- output

def render(name: str, out_dir: Path, seed: int = 1, stem: str | None = None) -> Path:
    fn, peak_dbfs, loops = RECIPES[name]
    rng = np.random.default_rng(seed)
    x = normalize(fn(rng)) * 10 ** (peak_dbfs / 20)
    if not loops:  # trim trailing silence below -60 dB and fade the last 20 ms
        idx = np.nonzero(np.abs(x) > 10 ** (-60 / 20))[0]
        x = x[: idx[-1] + 1] if len(idx) else x
        f = min(int(0.02 * SAMPLE_RATE), len(x))
        x[-f:] *= np.linspace(1, 0, f)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{stem or name}.ogg"
    # Vorbis encoding can raise peaks by 1 to 2 dB; measure the encoded file and correct.
    target = 10 ** (peak_dbfs / 20)
    for _ in range(4):
        sf.write(path, x.astype(np.float32), SAMPLE_RATE, format="OGG", subtype="VORBIS")
        peak = np.max(np.abs(sf.read(path)[0]))
        if peak <= target * 1.03:
            break
        x = x * (target / peak)
    _set_godot_loop(path, loops)
    return path


def _set_godot_loop(path: Path, loops: bool) -> None:
    """Write the loop flag into Godot's .import file (Godot keeps import settings there).

    If the file does not exist yet, write a minimal one; Godot fills in the rest on import.
    """
    imp = path.with_name(path.name + ".import")
    flag = "true" if loops else "false"
    if imp.exists():
        text = imp.read_text()
        if "loop=" in text:
            import re
            text = re.sub(r"(?m)^loop=\w+$", f"loop={flag}", text)
        else:
            text += f"\nloop={flag}\n"
        imp.write_text(text)
    else:
        imp.write_text(
            '[remap]\n\nimporter="oggvorbisstr"\ntype="AudioStreamOggVorbis"\n\n'
            f"[params]\n\nloop={flag}\nloop_offset=0\nbpm=0\nbeat_count=0\nbar_beats=4\n"
        )


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
        count = VARIANTS.get(name, 1)
        paths = []
        for v in range(1, count + 1):
            stem = f"{name}_{v:02d}" if count > 1 else name
            path = render(name, args.out, args.seed + v - 1, stem)
            paths.append(path)
            print(f"WROTE {path.relative_to(REPO)}")
            if args.spectrograms:
                png = spectrogram(path, args.spectrograms / f"{stem}.png")
                print(f"SPECTROGRAM {png.relative_to(REPO)}")
        if count > 1:
            print(f"WROTE {write_randomizer(name, paths).relative_to(REPO)}")
    return 0


def write_randomizer(name: str, paths: list[Path]) -> Path:
    """Godot AudioStreamRandomizer that picks one variation per play, with slight pitch and
    volume changes, so repeated hits never sound identical. Play `res://.../<name>.tres`."""
    lines = [f'[gd_resource type="AudioStreamRandomizer" load_steps={len(paths) + 1} format=3]', ""]
    for i, p in enumerate(paths):
        res = "res://" + str(p.relative_to(REPO / "game"))
        lines.append(f'[ext_resource type="AudioStream" path="{res}" id="{i + 1}"]')
    lines += ["", "[resource]", "random_pitch = 1.06", "random_volume_offset_db = 1.5",
              f"streams_count = {len(paths)}"]
    for i in range(len(paths)):
        lines += [f'stream_{i}/stream = ExtResource("{i + 1}")', f"stream_{i}/weight = 1.0"]
    out = paths[0].parent / f"{name}.tres"
    out.write_text("\n".join(lines) + "\n")
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
