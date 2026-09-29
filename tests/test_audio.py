"""Automated checks on generated sound effects (tools/audio/synth.py output).

Rules come from human listening feedback:
  - Impacts must not be tonal. weapon_impact v1 put 93% of its energy above 200 Hz into narrow
    tonal peaks and sounded "like you scored a point"; v2 has 0%.
  - Non-impact sounds must not click (a one-sample jump in level).
  - Heals must carry weight: holy_heal v1 had 20% of its energy below 250 Hz and felt light.
  - Peaks stay at or below -1 dBFS, the level reserved for the enemy CC warning.
"""
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf
from scipy import signal

SFX = Path(__file__).resolve().parent.parent / "game" / "assets" / "audio" / "sfx"

IMPACTS = ["weapon_impact"]
SMOOTH = ["frost_cast_loop", "holy_heal"]  # no sharp transients expected
HEALS = ["holy_heal"]


def load(name: str) -> tuple[np.ndarray, int]:
    x, sr = sf.read(SFX / f"{name}.ogg")
    return x, sr


def tonal_share(x: np.ndarray, sr: int) -> float:
    """Share of energy above 200 Hz sitting in narrow spectral peaks (20x the local median)."""
    f, p = signal.welch(x, sr, nperseg=4096)
    p = p[f > 200]
    peaks = p > 20 * signal.medfilt(p, 101)
    return float(p[peaks].sum() / p.sum())


@pytest.mark.parametrize("name", IMPACTS)
def test_impacts_are_not_tonal(name):
    x, sr = load(name)
    assert tonal_share(x, sr) < 0.20


def click_score(x: np.ndarray, sr: int, frame: int = 64) -> float:
    """Largest ratio of a frame's energy above 10 kHz to the median of its neighbours.

    A click is a sudden broadband burst (a vertical line on a spectrogram); steady bright noise
    such as wind has high energy up there too, but spread evenly, so it scores low. Only bursts
    within 40 dB of the sound's loudest frame count (quieter ones cannot be heard), and the
    first frames are skipped (filter start-up).
    """
    n = len(x) // frame
    full = (x[: n * frame].reshape(n, frame) ** 2).mean(axis=1)
    sos = signal.butter(4, 10000, btype="high", fs=sr, output="sos")
    hi = signal.sosfilt(sos, x)
    e = (hi[: n * frame].reshape(n, frame) ** 2).mean(axis=1)
    audible = e > full.max() * 1e-4
    audible[:4] = False
    if not audible.any():
        return 0.0
    local = signal.medfilt(e, 101) + full.max() * 1e-6
    return float((e / local)[audible].max())


def test_click_detector_catches_a_click():
    sr = 48000
    t = np.arange(sr) / sr
    smooth = np.sin(2 * np.pi * 220 * t) * 0.5
    clicky = smooth.copy()
    cut = sr // 2 + sr // (4 * 220)  # at a wave crest, so the level drop is a real jump
    clicky[cut:] *= 0.2  # like a sound cut off mid-note
    assert click_score(smooth, sr) < 8
    assert click_score(clicky, sr) > 8


@pytest.mark.parametrize("name", SMOOTH)
def test_smooth_sounds_do_not_click(name):
    x, sr = load(name)
    assert click_score(x, sr) < 8


@pytest.mark.parametrize("name", HEALS)
def test_heals_have_low_end_weight(name):
    x, sr = load(name)
    f, p = signal.welch(x, sr, nperseg=8192)
    assert p[f < 250].sum() / p.sum() > 0.40


def test_no_sound_exceeds_cc_warning_level():
    for path in SFX.glob("*.ogg"):
        x, _ = sf.read(path)
        assert np.abs(x).max() <= 10 ** (-1 / 20) * 1.01, path.name
