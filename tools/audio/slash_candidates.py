#!/usr/bin/env python3
"""Four different readings of "slash" for the human to choose from (human feedback: three slash
versions in a row did not sound like slashes; see KNOWN_ISSUES.md).

    python3 tools/audio/slash_candidates.py [--out previews/audio/slash_candidates]

A  air whoosh + cut   the blade's whoosh swells into the contact, then a crisp cut and a wet slap
B  steel ring         the movie "shing": a bright metallic ring sliding down in pitch over a short
                      swish, the edge scraping at the start
C  meaty slash        a sharp cut and dense wet tearing over a thump; no ring, no long whoosh
D  combined           A's whoosh, C's cut and tear, and B's ring at half level

Each candidate is written as one listening file: the hit twice (two variations), then twice more
after the greatsword swing as the game plays them (swing at the attack's start, hit at contact),
and as single hits (<id>_hit_0N.ogg). Everything goes through the slash processing chain.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).parent))
import processing  # noqa: E402
import synth as S  # noqa: E402

SR = S.SAMPLE_RATE
REPO = Path(__file__).resolve().parents[2]


def tv_resonator(x: np.ndarray, freq: np.ndarray, q: float) -> np.ndarray:
    """Two-pole resonator whose centre frequency follows `freq` (Hz per sample): a ring or a
    filtered whoosh that glides, which fixed filters cannot do."""
    y = np.zeros_like(x)
    y1 = y2 = 0.0
    for i in range(len(x)):
        w = 2 * np.pi * freq[i] / SR
        r = np.exp(-w / (2 * q))
        a1, a2 = -2 * r * np.cos(w), r * r
        g = (1 - r * r) * 0.5
        v = g * x[i] - a1 * y1 - a2 * y2
        y[i] = v
        y2, y1 = y1, v
    return y


def env_at(n: int, start: int, attack_s: float, decay_s: float) -> np.ndarray:
    e = np.zeros(n)
    t = (np.arange(n - start)) / SR
    e[start:] = np.clip(t / max(attack_s, 1e-5), 0, 1) * np.exp(-t / decay_s)
    return e


def whoosh(n: int, contact: int, rng, lo: float = 450, hi: float = 2400, pre_s: float = 0.13) -> np.ndarray:
    """Air pushed by a blade: noise through a resonance that rises to `hi` at contact and falls
    after it (the Doppler of a passing edge), swelling in and dying fast after contact."""
    t = np.arange(n) / SR
    tc = contact / SR
    u = np.clip((t - (tc - pre_s)) / pre_s, 0, 1)
    f = lo + (hi - lo) * u ** 1.5
    f = np.where(t > tc, hi - (hi - lo) * np.clip((t - tc) / 0.12, 0, 1), f)
    amp = np.where(t <= tc, u ** 3, np.exp(-(t - tc) / 0.05))
    return tv_resonator(S.noise(n, rng), f, 2.2) * amp * 3.0


def cut(n: int, contact: int, rng, gain: float = 1.0) -> np.ndarray:
    tick = S.highpass(S.noise(n, rng), 2500) * env_at(n, contact, 0.0003, 0.006) * 1.2
    sl = S.bandpass(S.noise(n, rng), 1800, 7000) * env_at(n, contact, 0.001, 0.035)
    return (tick + sl) * gain


def wet(n: int, contact: int, rng, gain: float = 1.0, dense: bool = False) -> np.ndarray:
    slap = S.bandpass(S.noise(n, rng), 250, 1200) * env_at(n, contact, 0.001, 0.025) * 1.2
    g = S.grains(n, rng, per_second=3200 if dense else 1500, decay_s=0.0015)
    tear = S.bandpass(S.noise(n, rng) * g, 900, 5000) * env_at(n, contact + int(0.004 * SR), 0.004, 0.09 if dense else 0.05)
    return (slap + tear * (1.4 if dense else 0.8)) * gain


def thump(n: int, contact: int, hz0: float = 120, hz1: float = 58, gain: float = 0.4) -> np.ndarray:
    t = np.arange(n - contact) / SR
    out = np.zeros(n)
    out[contact:] = S.sweep(t, hz0, hz1, curve=10) * np.exp(-t / 0.03) * np.clip(t / 0.001, 0, 1)
    return out * gain


def ring(n: int, contact: int, rng, gain: float = 1.0) -> np.ndarray:
    """Steel: inharmonic partials of a struck bar, each a narrow resonance sliding about 7% down
    as the edge travels, roughened at the start like a blade scraping."""
    t = np.arange(n) / SR
    tc = contact / SR
    base = rng.uniform(2700, 3200)
    glide = 1 - 0.07 * np.clip((t - tc) / 0.3, 0, 1)
    out = np.zeros(n)
    for ratio, q, amp, dec in ((1.0, 140, 1.0, 0.2), (1.47, 160, 0.7, 0.17), (2.09, 180, 0.5, 0.14),
                               (2.76, 200, 0.35, 0.11), (3.52, 220, 0.25, 0.08)):
        f = np.minimum(base * ratio * glide, SR / 2 - 500)
        out += tv_resonator(S.noise(n, rng), f, q) * env_at(n, contact, 0.002, dec) * amp
    scrape = 1 + 0.8 * S.lowpass(S.noise(n, rng), 120) / 0.05 * np.exp(-np.clip(t - tc, 0, None) / 0.08)
    out = out * np.clip(scrape, 0, 2.5)
    swish = S.bandpass(S.noise(n, rng), 3000, 9000) * env_at(n, max(0, contact - int(0.03 * SR)), 0.02, 0.05) * 0.5
    return S.highpass(out, 1500) * 6.0 * gain + swish


def candidate(kind: str, rng) -> np.ndarray:
    n = int(1.1 * SR)
    contact = int(0.14 * SR)  # A and D need room for the whoosh before contact
    if kind == "A":
        x = whoosh(n, contact, rng) + cut(n, contact, rng) + wet(n, contact, rng, 0.8) + thump(n, contact)
    elif kind == "B":
        contact = int(0.04 * SR)
        x = cut(n, contact, rng, 0.6) + ring(n, contact, rng) + thump(n, contact, gain=0.25)
    elif kind == "C":
        contact = int(0.02 * SR)
        x = (cut(n, contact, rng, 1.0) + wet(n, contact, rng, 1.3, dense=True) + thump(n, contact, 140, 55, 0.6)
             + S.bandpass(S.noise(n, rng), 2500, 8000) * env_at(n, contact, 0.002, 0.05) * 0.5)
    else:
        x = (whoosh(n, contact, rng) + cut(n, contact, rng) + wet(n, contact, rng, 1.0, dense=True)
             + ring(n, contact, rng, 0.5) + thump(n, contact))
    x[-int(0.15 * SR):] *= np.linspace(1, 0, int(0.15 * SR)) ** 2  # no ring cut off at the end
    x = S.saturate(S.normalize(x), 1.6)
    chain = processing.load()["chains"]["slash"]["effects"]
    y = S.normalize(processing.apply_chain(x, chain, rng)) * 10 ** (-3 / 20)
    idx = np.nonzero(np.abs(y) > 10 ** (-60 / 20))[0]  # trim trailing silence
    y = y[: idx[-1] + 1] if len(idx) else y
    y[-int(0.02 * SR):] *= np.linspace(1, 0, int(0.02 * SR))
    return y, contact


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "audio" / "slash_candidates")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    swing, sr = sf.read(REPO / "game" / "assets" / "audio" / "sfx" / "swing_greatsword_01.ogg")
    assert sr == SR
    swing = swing * 10 ** (-4 / 20)
    swing_lead = int(0.28 * SR)  # the attack's contact comes this long after the swing starts
    for kind in "ABCD":
        pieces = []
        for v in range(2):
            hit, _c = candidate(kind, np.random.default_rng(100 + v))
            sf.write(args.out / f"{kind}_hit_{v + 1:02d}.ogg", hit, SR)
            pieces += [hit, np.zeros(int(0.6 * SR))]
        for v in range(2):
            hit, contact = candidate(kind, np.random.default_rng(200 + v))
            n = max(len(swing), swing_lead - contact + len(hit))
            mix = np.zeros(n)
            mix[: len(swing)] += swing
            a = swing_lead - contact
            mix[a:a + len(hit)] += hit
            pieces += [mix / max(1.0, np.max(np.abs(mix)) / 10 ** (-1 / 20)), np.zeros(int(0.7 * SR))]
        sf.write(args.out / f"slash_{kind}.ogg", np.concatenate(pieces), SR)
        print(f"slash_{kind}.ogg")


if __name__ == "__main__":
    main()
