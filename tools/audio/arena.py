"""Offline model of the arena reverb on the world bus (backlog X-04).

A numpy port of Godot 4.7's AudioEffectReverb (servers/audio/effects/reverb_filter.cpp, left
channel): the input plus a feedback echo spaced by the predelay, a one-pole high-pass, eight
Freeverb combs with a damping low-pass in their loops, four allpasses, then
out = wet * 0.6 * reverb + dry * input. There is no input scaling, so the wet signal is much
louder than Freeverb's usual: at wet 0.12 a hit's tail can carry as much energy as the hit.

Used by tests/test_audio.py (no world sound through the arena reverb may be as loud as the dry CC
warning) and by review.py to render how a sound will sound in a map. Every delay line is at least
10 samples long, so each filter is computed a block of its delay length at a time with numpy and
scipy.signal.lfilter instead of sample by sample.
"""
from __future__ import annotations

import numpy as np
from scipy import signal

COMB_TUNINGS = (0.025306122448979593, 0.026938775510204082, 0.028956916099773241, 0.03074829931972789,
                0.032244897959183672, 0.03380952380952381, 0.035306122448979592, 0.036666666666666667)
ALLPASS_TUNINGS = (0.0051020408163265302, 0.007732426303854875, 0.01, 0.012607709750566893)
ALLPASS_FEEDBACK = 0.7
WET_SCALE = 0.6
ROOM_SCALE, ROOM_OFFSET = 0.28, 0.7


def _feedback_delay(x: np.ndarray, delay: int, gain: float) -> np.ndarray:
    """w[n] = x[n] + gain * w[n - delay], a block of `delay` samples at a time."""
    w = x.astype(np.float64).copy()
    for s in range(delay, len(w), delay):
        e = min(s + delay, len(w))
        w[s:e] += gain * w[s - delay:e - delay]
    return w


def _comb(x: np.ndarray, delay: int, feedback: float, damp: float) -> np.ndarray:
    """Godot's comb: o[n] = (1-d) * f * b[n-L] + d * o[n-1]; b[n] = x[n] + o[n]; output o."""
    o = np.zeros(len(x))
    b = np.zeros(len(x))
    state = np.zeros(1)
    for s in range(0, len(x), delay):
        e = min(s + delay, len(x))
        prev_b = b[s - delay:e - delay] if s >= delay else np.zeros(e - s)
        o[s:e], state = signal.lfilter([(1 - damp) * feedback], [1.0, -damp], prev_b, zi=state)
        b[s:e] = x[s:e] + o[s:e]
    return o


def _allpass(x: np.ndarray, delay: int) -> np.ndarray:
    """buffer w[n] = x[n] + g * w[n-L]; y[n] = w[n-L] - g * w[n]."""
    w = _feedback_delay(x, delay, ALLPASS_FEEDBACK)
    delayed = np.concatenate([np.zeros(delay), w[:-delay]])
    return delayed - ALLPASS_FEEDBACK * w


def godot_reverb(x: np.ndarray, reverb: dict, sr: int = 48000, tail_s: float = 3.0,
                 extra_spread_base: float = 0.0) -> np.ndarray:
    """A mono signal through AudioEffectReverb with the settings of data/acoustics `reverb`
    (room_size, damping, spread, hipass, dry, wet, predelay_ms, predelay_feedback); `tail_s` of
    silence is appended so the tail can ring out."""
    x = np.concatenate([np.asarray(x, dtype=np.float64), np.zeros(int(tail_s * sr))])
    predelay = min(max(int(round(reverb["predelay_ms"] / 1000 * sr)), 10), int(0.5 * sr))
    inp = _feedback_delay(x, predelay, float(reverb["predelay_feedback"]))
    if reverb["hipass"] > 0:
        aux = np.exp(-2 * np.pi * reverb["hipass"] * 6000 / sr)
        inp = signal.lfilter([(1 + aux) / 2, -(1 + aux) / 2], [1.0, -aux], inp)
    feedback = float(np.clip(ROOM_OFFSET + reverb["room_size"] * ROOM_SCALE, ROOM_OFFSET, ROOM_OFFSET + ROOM_SCALE))
    auxdmp = (reverb["damping"] / 2 + 0.5) ** 2
    damp = float(np.exp(-2 * np.pi * auxdmp * 10000 / sr))
    extra = int(round(extra_spread_base * sr))
    shrink = int(round(extra * (1.0 - reverb["spread"])))
    wet = np.zeros(len(x))
    for t in COMB_TUNINGS:
        wet += _comb(inp, max(int(round(t * sr)) + extra - shrink, 5), feedback, damp)
    for t in ALLPASS_TUNINGS:
        wet = _allpass(wet, max(int(round(t * sr)) + extra - shrink, 5))
    return wet * reverb["wet"] * WET_SCALE + x * reverb["dry"]
