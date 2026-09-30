"""Measurements of generated sounds, shared by tests/test_audio.py and the review sheet.

Loudness follows ITU-R BS.1770-4 (K-weighting, 400 ms blocks with 75% overlap, absolute gate at
-70 LUFS and relative gate at -10 LU). Sounds shorter than one block are padded with silence
to 400 ms, so a short hit is measured as it sounds within a 400 ms window. `momentary_max` is
the loudest single 400 ms block, closer to how loud a short sound feels.
"""
from __future__ import annotations

import numpy as np
from scipy import signal

# K-weighting at 48 kHz (BS.1770-4 table 1 and 2)
_SHELF = ([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585])
_HIGHPASS = ([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])


def _blocks(x: np.ndarray, sr: int) -> np.ndarray:
    assert sr == 48000, "K-weighting coefficients are for 48 kHz"
    y = signal.lfilter(*_SHELF, x)
    y = signal.lfilter(*_HIGHPASS, y)
    block, hop = int(0.4 * sr), int(0.1 * sr)
    if len(y) < block:
        y = np.pad(y, (0, block - len(y)))
    starts = range(0, len(y) - block + 1, hop)
    return np.array([np.mean(y[s:s + block] ** 2) for s in starts])


def _lufs(z: np.ndarray) -> float:
    return float(-0.691 + 10 * np.log10(np.mean(z) + 1e-20))


def integrated_loudness(x: np.ndarray, sr: int) -> float:
    z = _blocks(x, sr)
    loud = -0.691 + 10 * np.log10(z + 1e-20)
    z = z[loud > -70]
    if len(z) == 0:
        return -70.0
    rel = _lufs(z) - 10
    loud = -0.691 + 10 * np.log10(z + 1e-20)
    return _lufs(z[loud > rel])


def momentary_max(x: np.ndarray, sr: int) -> float:
    z = _blocks(x, sr)
    return float(-0.691 + 10 * np.log10(z.max() + 1e-20))


def peak_dbfs(x: np.ndarray) -> float:
    return float(20 * np.log10(np.max(np.abs(x)) + 1e-12))


def tonal_share(x: np.ndarray, sr: int) -> float:
    """Share of energy above 200 Hz sitting in narrow spectral peaks (20x the local median);
    the same measure as tests/test_audio.py (31-bin median, about 360 Hz)."""
    f, p = signal.welch(x, sr, nperseg=4096)
    p = p[f > 200]
    peaks = p > 20 * signal.medfilt(p, 31)
    return float(p[peaks].sum() / (p.sum() + 1e-20))


def spectral_centroid(x: np.ndarray, sr: int) -> float:
    f, p = signal.welch(x, sr, nperseg=4096)
    return float((f * p).sum() / (p.sum() + 1e-20))


def band_share(x: np.ndarray, sr: int, hi: float, lo: float = 0.0) -> float:
    f, p = signal.welch(x, sr, nperseg=8192)
    return float(p[(f >= lo) & (f < hi)].sum() / (p.sum() + 1e-20))


def decay_time(x: np.ndarray, sr: int, drop_db: float = 20.0) -> float:
    """Seconds from the loudest 5 ms frame until the level stays drop_db below it."""
    frame = int(0.005 * sr)
    n = len(x) // frame
    e = 10 * np.log10((x[: n * frame].reshape(n, frame) ** 2).mean(axis=1) + 1e-20)
    top = int(np.argmax(e))
    above = np.nonzero(e[top:] > e[top] - drop_db)[0]
    return float((above[-1] + 1) * frame / sr) if len(above) else 0.0


def attack_time(x: np.ndarray, sr: int) -> float:
    """Seconds from the start until the loudest 5 ms frame."""
    frame = int(0.005 * sr)
    n = len(x) // frame
    e = (x[: n * frame].reshape(n, frame) ** 2).mean(axis=1)
    return float(np.argmax(e) * frame / sr)
