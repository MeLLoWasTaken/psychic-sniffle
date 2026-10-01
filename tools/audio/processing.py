"""Studio processing stage of the sound build (backlog X-04), driven by data.

After tools/audio/layers.py mixes a recipe's layers (or a builtin recipe renders), the signal
goes through a chain of named effects before synth.write_sound normalises it to the recipe's
peak and encodes it. Chains live in data/sound_processing/default.json (schema
sound_processing.schema.json): named chains of effects with parameters, a default chain per
sound category, and per category a window for the peak-to-loudness ratio and its spread that
tests/test_audio.py checks on every file. A sound
picks another chain with "processing": "<chain id>" in data/sounds/<id>.json, or "none".

Every effect is own numpy/scipy code; the ones that replaced pedalboard (Spotify's wrapper of
JUCE, whose native code crashed on some CI runners, KNOWN_ISSUES) follow JUCE's algorithms and
match pedalboard 0.9.25's output to within about 1e-4 of the peak (most within 1e-6), so the
sounds approved through pedalboard did not change audibly.

The chain's input is normalised to a peak of 1.0 (0 dBFS). Compressor and limiter thresholds are
relative to the peak of the signal reaching them (-18 = 18 dB below it), so an EQ boost or a
transient shaper earlier in the chain does not change how hard they work.

Effects ("fx") and their parameters:
  highpass / lowpass   hz, order (Butterworth, default 2)             rumble removal, top cut
  low_shelf / high_shelf / peak   hz, gain_db, q (default 0.707)     tone shaping (biquads with the
              formulas of JUCE's IIR filters, which pedalboard used)
  saturate    drive_db, mix, band [lo, hi] (optional)                 parallel tanh saturation of the
              band (or the whole sound), level-matched: out = x + mix * (sat(src) - src); sat is
              tanh(drive * x), as JUCE's Gain + WaveShaper (pedalboard's Distortion)
  transient   attack_db, sustain_db, fast_ms (1), slow_ms (25)       transient shaper: gain follows
              the ratio of a fast and a slow envelope (onsets louder, tails quieter or louder)
  compressor  threshold_db, ratio, attack_ms, release_ms, mix (1)     peak-detecting compressor, hard
              knee (juce::dsp::Compressor with its BallisticsFilter)
  limiter     threshold_db, release_ms, lookahead_ms (1.5)           look-ahead peak limiter, smooth
              gain, no hard clipping (own code: pedalboard's Limiter hard-clips at its ceiling)
  chorus      rate_hz, depth, centre_delay_ms, feedback, mix          sine-modulated delay line with
              linear interpolation and feedback (juce::dsp::Chorus)
  phaser      rate_hz, depth, centre_hz, feedback, mix                six swept first-order allpass
              stages with feedback (juce::dsp::Phaser)
  room        room_size, damping, wet, dry (1)                        algorithmic reverb (juce::Reverb,
              i.e. Freeverb, the same family as Godot's AudioEffectReverb on the arena bus; no chain
              uses it at present)
  plate       decay_s (time to -60 dB), predelay_ms, damping_hz, wet  convolution with a generated
              plate-like impulse (dense noise, highs dying faster than lows), energy-normalised
  varispeed   semitones [lo, hi]                                     per variation, a seeded pitch
              and length change (tape-style resampling), so repeats differ

Every effect also takes "mix" (0..1, default 1): out = (1 - mix) * dry + mix * processed, except
saturate (parallel by definition), room and plate (wet is added to the untouched dry signal).
Every effect but varispeed takes "above_hz": only the band above that frequency is processed
and the part below passes untouched (a chorus or reverb on the low end comb-filters and muddies
it: a 9 ms chorus delay cancels a 58 Hz tone by 8 dB at mix 0.3).

One-shots are padded with enough silence for the chain's tails (reverbs, releases) before
processing; after it the last 10 ms must be 60 dB below the peak, else the build stops
("tail cut off"). After every effect the signal may hold its peak for at most 3 samples in a row,
else the build stops ("clipped"). Loops are processed as several joined copies (three, more when
a reverb tail is longer than the loop) and a late copy is kept, so filters, compressors and
reverbs are in their steady state at the seam and the loop still joins; effects that change over
time (chorus, phaser, varispeed) are not allowed on loops.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from scipy import signal

SR = 48000
REPO = Path(__file__).resolve().parents[2]
DATA_FILE = REPO / "data" / "sound_processing" / "default.json"

TIME_VARYING = {"chorus", "phaser", "varispeed"}
REVERBS = {"room", "plate"}
TAIL_LIMIT_DB = -60.0
FLAT_TOP_LIMIT = 3  # samples in a row at the peak: more means something hard-clipped


def flat_top_run(x: np.ndarray, rel: float = 1e-6) -> int:
    """Longest run of consecutive samples at the peak magnitude (see analysis.flat_top_run)."""
    near = np.concatenate([[0], (np.abs(x) >= np.max(np.abs(x)) * (1 - rel)).astype(np.int8), [0]])
    edges = np.diff(near)
    return int((np.nonzero(edges == -1)[0] - np.nonzero(edges == 1)[0]).max())


# ----------------------------------------------------------------------------- data

_cache: dict[Path, dict] = {}


def load(path: Path = DATA_FILE) -> dict:
    if path not in _cache:
        _cache[path] = json.loads(path.read_text())
    return _cache[path]


def chain_id_for(recipe: dict, data: dict | None = None) -> str | None:
    """The chain a sound uses: its own "processing", else its category's; None for "none"."""
    data = data or load()
    cid = recipe.get("processing", data["categories"].get(recipe["category"], "none"))
    return None if cid == "none" else cid


def chain_for(recipe: dict, data: dict | None = None) -> list[dict]:
    data = data or load()
    cid = chain_id_for(recipe, data)
    return [] if cid is None else list(data["chains"][cid]["effects"])


# ----------------------------------------------------------------------------- effects

def _butter(x: np.ndarray, fx: dict, kind: str) -> np.ndarray:
    sos = signal.butter(int(fx.get("order", 2)), float(fx["hz"]), btype=kind, fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def eq_coefficients(kind: str, hz: float, gain_db: float, q: float) -> tuple[np.ndarray, np.ndarray]:
    """Biquad (b, a) for a shelf or peak EQ: the cookbook formulas JUCE uses for pedalboard's
    LowShelfFilter, HighShelfFilter and PeakFilter (juce::dsp::IIR::ArrayCoefficients), so the
    result matches them; computed here because pedalboard's filters crashed natively on some CI
    runners (KNOWN_ISSUES)."""
    big_a = np.sqrt(10.0 ** (gain_db / 20.0))
    w = 2.0 * np.pi * max(hz, 2.0) / SR
    cos_w = np.cos(w)
    if kind == "peak":
        alpha = np.sin(w) / (q * 2.0)
        b = [1.0 + alpha * big_a, -2.0 * cos_w, 1.0 - alpha * big_a]
        a = [1.0 + alpha / big_a, -2.0 * cos_w, 1.0 - alpha / big_a]
    else:
        am1, ap1 = big_a - 1.0, big_a + 1.0
        beta = np.sin(w) * np.sqrt(big_a) / q
        if kind == "low_shelf":
            b = [big_a * (ap1 - am1 * cos_w + beta), big_a * 2.0 * (am1 - ap1 * cos_w), big_a * (ap1 - am1 * cos_w - beta)]
            a = [ap1 + am1 * cos_w + beta, -2.0 * (am1 + ap1 * cos_w), ap1 + am1 * cos_w - beta]
        else:  # high_shelf
            b = [big_a * (ap1 + am1 * cos_w + beta), big_a * -2.0 * (am1 + ap1 * cos_w), big_a * (ap1 + am1 * cos_w - beta)]
            a = [ap1 - am1 * cos_w + beta, 2.0 * (am1 - ap1 * cos_w), ap1 - am1 * cos_w - beta]
    return np.array(b) / a[0], np.array(a) / a[0]


def _eq(x: np.ndarray, fx: dict) -> np.ndarray:
    b, a = eq_coefficients(fx["fx"], float(fx["hz"]), float(fx["gain_db"]), float(fx.get("q", 0.707)))
    return signal.lfilter(b, a, x)


def _rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x ** 2)) + 1e-12)


# Own versions of the JUCE dsp effects pedalboard wrapped (Distortion, Compressor, Chorus, Phaser,
# Reverb). pedalboard's native code died with "Illegal instruction" on some GitHub Actions CPUs
# (KNOWN_ISSUES), so these follow JUCE 7's juce_dsp code step by step, in float32 where it matters
# (oscillator phase, delay times, filter cutoffs), and match pedalboard's output to about 1e-6 of
# the peak (the chorus to 1e-4: the wheel's sinf differs from a correctly rounded one by ~1e-6,
# which moves a delay time by a float32 step now and then); tests/test_audio.py compares them with
# pedalboard where it runs. They process one mono channel with the parameters fixed, as pedalboard
# did (it resets every plugin per call, which snaps JUCE's parameter smoothing to its target).

F32 = np.float32
TWO_PI_F32 = F32(2.0 * np.pi)


def juce_distortion(x: np.ndarray, drive_db: float) -> np.ndarray:
    """juce::dsp::Gain then WaveShaper(tanh), as pedalboard.Distortion: tanh(x * gain), float32."""
    gain = F32(10.0) ** (F32(drive_db) * F32(0.05))
    return np.tanh(x.astype(F32) * gain).astype(np.float64)


def juce_compressor(x: np.ndarray, threshold_db: float, ratio: float, attack_ms: float,
                    release_ms: float) -> np.ndarray:
    """juce::dsp::Compressor: a peak BallisticsFilter (attack when the level rises, release when it
    falls), then gain = (env / threshold) ** (1 / ratio - 1) above the threshold."""
    exp_factor = -2.0 * np.pi * 1000.0 / SR

    def cte(ms: float) -> float:
        return 0.0 if ms < 1e-3 else float(F32(np.exp(exp_factor / float(F32(ms)))))

    c_att, c_rel = cte(attack_ms), cte(release_ms)
    rect = np.abs(x.astype(F32)).astype(np.float64).tolist()
    env = rect  # overwritten in place: env[i] only needs rect[i] and env[i - 1]
    y = 0.0
    for i, v in enumerate(rect):
        y = v + (c_att if v > y else c_rel) * (y - v)
        env[i] = y
    env = np.array(env)
    thr = float(F32(10.0) ** (F32(threshold_db) * F32(0.05)))
    gain = np.ones_like(env)
    over = env >= thr
    gain[over] = (env[over] / thr) ** (1.0 / float(F32(ratio)) - 1.0)
    return gain * x.astype(F32)


def juce_oscillator(n: int, rate_hz: float, sr: float) -> np.ndarray:
    """n values of juce::dsp::Oscillator with sin as its function: sin(phase - pi), the phase
    starting at 0 and advancing by 2*pi*rate/sr per value, accumulated and wrapped in float32 like
    juce::dsp::Phase (float32 rounding shifts the LFO by several samples over a second)."""
    inc = (TWO_PI_F32 / F32(sr)) * F32(rate_hz)
    phases = np.empty(n, dtype=F32)
    p = F32(0.0)
    i = 0
    while i < n:
        m = min(n - i, int((float(TWO_PI_F32) - float(p)) / max(float(inc), 1e-30)) + 3)
        seg = np.full(m, inc, dtype=F32)
        seg[0] = p
        seg = np.cumsum(seg, dtype=F32)  # sequential float32 adds, like the C++ loop
        wrap = np.nonzero(seg >= TWO_PI_F32)[0]
        if len(wrap) == 0:
            phases[i:i + m] = seg
            p = seg[-1] + inc
            i += m
            if p >= TWO_PI_F32:
                p = p - TWO_PI_F32
            continue
        j = int(wrap[0])
        phases[i:i + j] = seg[:j]
        p = seg[j] - TWO_PI_F32
        i += j
    return np.sin((phases - F32(np.pi)).astype(np.float64)).astype(F32)  # sinf, correctly rounded


def juce_chorus(x: np.ndarray, rate_hz: float, depth: float, centre_delay_ms: float,
                feedback: float) -> np.ndarray:
    """juce::dsp::Chorus at mix 1: a linearly interpolated delay line whose delay swings
    20 ms * depth/2 * sin around the centre delay (at least 1 ms), with feedback subtracted from the
    input. Computed in blocks shorter than the shortest delay, so the feedback needs no
    per-sample loop."""
    n = len(x)
    if n == 0:
        return np.zeros(0)
    centre = F32(min(max(centre_delay_ms, 1.0), 100.0))
    lfo = juce_oscillator(n, rate_hz, SR) * (F32(depth) * F32(0.5))
    # 20 * lfo + centre in one rounding: the pedalboard wheel was built with fused multiply-add
    ms = np.maximum(1.0, 20.0 * lfo.astype(np.float64) + float(centre)).astype(F32)
    d = (ms.astype(np.float64) * SR / 1000.0).astype(F32)
    d_int = np.floor(d).astype(np.int64)
    frac = (d - d_int.astype(F32)).astype(np.float64)
    fb = float(F32(feedback))
    xin = x.astype(F32).astype(np.float64)
    w = np.zeros(n)  # what goes into the delay line: input minus fed-back output
    y = np.zeros(n)
    step = int(d_int.min())
    idx = np.arange(n)
    for s in range(0, n, step):
        e = min(n, s + step)
        i1 = idx[s:e] - d_int[s:e]
        v1 = np.where(i1 >= 0, w[np.maximum(i1, 0)], 0.0)
        v2 = np.where(i1 - 1 >= 0, w[np.maximum(i1 - 1, 0)], 0.0)
        y[s:e] = v1 + frac[s:e] * (v2 - v1)
        prev = np.concatenate([[y[s - 1] if s > 0 else 0.0], y[s:e - 1]])
        w[s:e] = xin[s:e] - fb * prev
    return y


def juce_phaser(x: np.ndarray, rate_hz: float, depth: float, centre_hz: float, feedback: float) -> np.ndarray:
    """juce::dsp::Phaser at mix 1: six first-order TPT allpass stages sharing one cutoff, which an
    LFO (updated every 4 samples) sweeps on a log scale from 20 Hz to 20 kHz around the centre
    frequency; the output, times feedback, is subtracted from the next input."""
    lo, hi = F32(20.0), F32(20000.0)
    log_lo, log_hi = np.log10(lo), np.log10(hi)
    norm_centre = (np.log10(F32(centre_hz)) - log_lo) / (log_hi - log_lo)
    n = len(x)
    lfo = juce_oscillator((n + 3) // 4, rate_hz, SR / 4) * (F32(depth) * F32(0.5))
    v = np.clip(lfo + norm_centre, F32(0.0), F32(1.0))
    cutoff = F32(10.0) ** (v * (log_hi - log_lo) + log_lo)
    g = np.tan(np.pi * cutoff.astype(np.float64) / SR).astype(F32)
    big_g = (g / (F32(1.0) + g)).astype(np.float64).tolist()
    fb = float(F32(feedback))
    xin = x.astype(F32).astype(np.float64).tolist()
    out = [0.0] * n
    s1 = s2 = s3 = s4 = s5 = s6 = 0.0
    last = 0.0
    gg = 0.0
    for i in range(n):
        if i & 3 == 0:
            gg = big_g[i >> 2]
        u = xin[i] - last
        v_ = gg * (u - s1); yy = v_ + s1; s1 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        v_ = gg * (u - s2); yy = v_ + s2; s2 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        v_ = gg * (u - s3); yy = v_ + s3; s3 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        v_ = gg * (u - s4); yy = v_ + s4; s4 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        v_ = gg * (u - s5); yy = v_ + s5; s5 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        v_ = gg * (u - s6); yy = v_ + s6; s6 = yy + v_; u = 2.0 * yy - u  # noqa: E702
        out[i] = u
        last = u * fb
    return np.array(out)


FREEVERB_COMBS = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)  # samples at 44.1 kHz
FREEVERB_ALLPASSES = (556, 441, 341, 225)


def juce_reverb(x: np.ndarray, room_size: float, damping: float) -> np.ndarray:
    """The wet output of juce::Reverb (Freeverb) on one channel at width 0, as pedalboard.Reverb
    with wet_level 1, dry_level 0: 8 damped feedback combs in parallel into 4 allpasses in series.
    Each comb and allpass is computed in blocks of its own length (its feedback is that late)."""
    damp = float(F32(damping) * F32(0.4))
    fb = float(F32(room_size) * F32(0.28) + F32(0.7))
    inp = x.astype(F32).astype(np.float64) * float(F32(0.015))
    n = len(x)
    acc = np.zeros(n)
    for tuning in FREEVERB_COMBS:
        size = (SR * tuning) // 44100
        w = np.zeros(n + size)  # w[k + size] is what was written at sample k; the first size are 0
        last = 0.0
        for s in range(0, n, size):
            e = min(n, s + size)
            out = w[s:e]  # written `size` samples ago
            lp, _ = signal.lfilter([1.0 - damp], [1.0, -damp], out, zi=[damp * last])
            last = float(lp[-1])
            w[s + size:e + size] = inp[s:e] + lp * fb
            acc[s:e] += out
    y = acc
    for tuning in FREEVERB_ALLPASSES:
        size = (SR * tuning) // 44100
        t = np.zeros(n + size)
        out = np.empty(n)
        for s in range(0, n, size):
            e = min(n, s + size)
            buffered = t[s:e]
            t[s + size:e + size] = y[s:e] + buffered * 0.5
            out[s:e] = buffered - y[s:e]
        y = out
    return y * float(F32(1.5))


def _saturate(x: np.ndarray, fx: dict) -> np.ndarray:
    if "band" in fx:
        lo, hi = fx["band"]
        src = signal.sosfilt(signal.butter(2, [lo, hi], btype="band", fs=SR, output="sos"), x)
    else:
        src = x
    peak = np.max(np.abs(src)) + 1e-12
    wet = juce_distortion(src / peak, float(fx["drive_db"]))
    wet *= _rms(src) / _rms(wet)  # level-matched: saturation adds harmonics, not loudness
    return x + float(fx.get("mix", 0.5)) * (wet - src)


def _one_pole(x: np.ndarray, ms: float) -> np.ndarray:
    a = np.exp(-1.0 / (max(ms, 0.01) * 1e-3 * SR))
    return signal.lfilter([1 - a], [1, -a], x)


def _transient(x: np.ndarray, fx: dict) -> np.ndarray:
    rect = np.abs(x)
    fast = _one_pole(rect, float(fx.get("fast_ms", 1.0))) + 1e-9
    slow = _one_pole(rect, float(fx.get("slow_ms", 25.0))) + 1e-9
    d = 20 * np.log10(fast / slow)  # > 0 at onsets, < 0 in decaying tails
    gain_db = float(fx.get("attack_db", 0.0)) * np.clip(d / 6.0, 0, 1) \
        + float(fx.get("sustain_db", 0.0)) * np.clip(-d / 6.0, 0, 1)
    gain_db = _one_pole(gain_db, 0.5)  # smooth the gain so it never steps (a click)
    return x * 10 ** (gain_db / 20)


def _peak_db(x: np.ndarray) -> float:
    return float(20 * np.log10(np.max(np.abs(x)) + 1e-12))


def _compressor(x: np.ndarray, fx: dict) -> np.ndarray:
    return juce_compressor(x, _peak_db(x) + float(fx["threshold_db"]), float(fx["ratio"]),
                           float(fx["attack_ms"]), float(fx["release_ms"]))


def _limiter(x: np.ndarray, fx: dict) -> np.ndarray:
    """Look-ahead peak limiter with a smooth gain curve. (pedalboard's Limiter ends in a hard clip
    at the ceiling: it flattened 10,000 samples of the CC warning, audible as distortion.)"""
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    ceiling = 10 ** ((_peak_db(x) + float(fx["threshold_db"])) / 20)
    look = max(1, int(float(fx.get("lookahead_ms", 1.5)) * 1e-3 * SR))
    g = np.minimum(1.0, ceiling / (np.abs(x) + 1e-12))
    # every sample within `look` of a peak takes that peak's gain; averaging over the same span
    # then ramps the gain down ahead of the peak and still reaches the peak's gain at the peak
    g = uniform_filter1d(minimum_filter1d(g, 2 * look + 1, mode="nearest"), 2 * look + 1, mode="nearest")
    g = np.minimum(g, 1.0)
    rel = 1 - np.exp(-1.0 / (float(fx["release_ms"]) * 1e-3 * SR))
    out = g.tolist()
    prev = 1.0
    for i, target in enumerate(out):  # release: the gain drops at once but recovers smoothly
        prev = target if target < prev else prev + (target - prev) * rel
        out[i] = prev  # never above target, so the ceiling holds
    return x * np.array(out)


def _chorus(x: np.ndarray, fx: dict) -> np.ndarray:
    return juce_chorus(x, float(fx["rate_hz"]), float(fx["depth"]), float(fx.get("centre_delay_ms", 7.0)),
                       float(fx.get("feedback", 0.0)))


def _phaser(x: np.ndarray, fx: dict) -> np.ndarray:
    return juce_phaser(x, float(fx["rate_hz"]), float(fx["depth"]), float(fx.get("centre_hz", 1300.0)),
                       float(fx.get("feedback", 0.0)))


def _room(x: np.ndarray, fx: dict) -> np.ndarray:
    wet = juce_reverb(x, float(fx["room_size"]), float(fx["damping"]))
    return float(fx.get("dry", 1.0)) * x + float(fx["wet"]) * wet


def plate_ir(decay_s: float, predelay_ms: float, damping_hz: float, seed: int = 11) -> np.ndarray:
    """A plate-like impulse response: dense noise decaying to -60 dB at decay_s, with the band
    above damping_hz dying twice as fast (a real plate darkens as it rings). Unit energy."""
    rng = np.random.default_rng(seed)
    n = int(decay_s * SR)
    t = np.arange(n) / SR
    w = rng.standard_normal(n)
    lo = signal.sosfilt(signal.butter(2, damping_hz, btype="low", fs=SR, output="sos"), w)
    hi = w - lo
    ir = lo * np.exp(-6.91 * t / decay_s) + hi * np.exp(-6.91 * 2 * t / decay_s)
    ir *= np.clip(t / 0.004, 0, 1)  # 4 ms fade-in: no hard first reflection
    ir = np.concatenate([np.zeros(int(predelay_ms * 1e-3 * SR)), ir])
    return ir / np.sqrt(np.sum(ir ** 2))


def _plate(x: np.ndarray, fx: dict) -> np.ndarray:
    ir = plate_ir(float(fx["decay_s"]), float(fx.get("predelay_ms", 0.0)), float(fx.get("damping_hz", 6000.0)))
    wet = signal.fftconvolve(x, ir)[: len(x)]
    return x + float(fx["wet"]) * wet


def _varispeed(x: np.ndarray, fx: dict, rng: np.random.Generator) -> np.ndarray:
    lo, hi = fx["semitones"]
    ratio = 2 ** (rng.uniform(lo, hi) / 12)  # > 1: higher and shorter
    up, down = 1000, int(round(1000 * ratio))
    return signal.resample_poly(x, up, down) if up != down else x


EFFECTS = {
    "highpass": lambda x, fx, r: _butter(x, fx, "high"),
    "lowpass": lambda x, fx, r: _butter(x, fx, "low"),
    "low_shelf": lambda x, fx, r: _eq(x, fx),
    "high_shelf": lambda x, fx, r: _eq(x, fx),
    "peak": lambda x, fx, r: _eq(x, fx),
    "saturate": lambda x, fx, r: _saturate(x, fx),
    "transient": lambda x, fx, r: _transient(x, fx),
    "compressor": lambda x, fx, r: _compressor(x, fx),
    "limiter": lambda x, fx, r: _limiter(x, fx),
    "chorus": lambda x, fx, r: _chorus(x, fx),
    "phaser": lambda x, fx, r: _phaser(x, fx),
    "room": lambda x, fx, r: _room(x, fx),
    "plate": lambda x, fx, r: _plate(x, fx),
    "varispeed": _varispeed,
}
OWN_MIX = {"saturate", "room", "plate", "varispeed"}


def tail_s(chain: list[dict]) -> float:
    """Silence to append to a one-shot so the chain's tails can ring out."""
    t = 0.0
    for fx in chain:
        k = fx["fx"]
        if k == "plate":
            t += float(fx.get("predelay_ms", 0)) * 1e-3 + float(fx["decay_s"])
        elif k == "room":
            t += 0.6 + 5.0 * float(fx["room_size"]) ** 2
        elif k in ("compressor", "limiter"):
            t += float(fx["release_ms"]) * 1e-3
        elif k in ("chorus", "phaser", "highpass", "lowpass", "low_shelf", "high_shelf", "peak"):
            t += 0.03
    return t


def apply_chain(x: np.ndarray, chain: list[dict], rng: np.random.Generator, loops: bool = False,
                where: str = "sound") -> np.ndarray:
    """Run a signal through a chain. Raises ValueError if a one-shot's tail is cut off."""
    x = np.asarray(x, dtype=np.float64)
    if not chain:
        return x
    peak = np.max(np.abs(x))
    if peak <= 0:
        return x
    x = x / peak
    n = len(x)
    if loops:
        tiles = 3 + int(np.ceil(tail_s(chain) / (n / SR)))
        y = np.tile(x, tiles)
    else:
        y = np.concatenate([x, np.zeros(int((tail_s(chain) + 0.15) * SR))])
    for fx in chain:
        low = None
        src = y
        if "above_hz" in fx:  # process only the band above; the part below passes untouched
            low = signal.sosfilt(signal.butter(4, float(fx["above_hz"]), btype="low", fs=SR, output="sos"), y)
            src = y - low  # complementary: low + src == y exactly
        out = EFFECTS[fx["fx"]](src, fx, rng)
        if fx["fx"] not in OWN_MIX and "mix" in fx:
            m = float(fx["mix"])
            out = (1 - m) * src + m * out[: len(src)]
        y = out if low is None else low + out[: len(low)]
        flat = flat_top_run(y)
        if flat > FLAT_TOP_LIMIT:
            raise ValueError(f"{where}: {fx['fx']} clipped the signal (a flat top of {flat} samples at its peak)")
    if loops:
        return y[(tiles - 2) * n:(tiles - 1) * n]
    end = y[-int(0.01 * SR):]
    end_db = 20 * np.log10(np.max(np.abs(end)) / (np.max(np.abs(y)) + 1e-12) + 1e-12)
    if end_db > TAIL_LIMIT_DB:
        raise ValueError(f"{where}: processing tail cut off ({end_db:.0f} dB at the end of the padded buffer)")
    return y


# ----------------------------------------------------------------------------- data checks

def problems(data: dict, sounds: dict[str, dict]) -> list[tuple[str, str]]:
    """Rules the schema cannot express. Returns (file, message) pairs."""
    out = []
    rel = f"sound_processing/{data['id']}.json"
    chains = data["chains"]
    for cat, cid in data["categories"].items():
        if cid != "none" and cid not in chains:
            out.append((rel, f"categories/{cat}: unknown chain '{cid}'"))
    for cid, c in chains.items():
        kinds = [fx["fx"] for fx in c["effects"]]
        if not kinds or kinds[0] != "highpass":
            out.append((rel, f"chains/{cid}: must start with a highpass (rumble and DC removal)"))
        if c.get("dry") and REVERBS.intersection(kinds) | TIME_VARYING.intersection(kinds):
            out.append((rel, f"chains/{cid}: a dry chain may not use reverb, chorus, phaser or varispeed"))
    for sid, s in sounds.items():
        where = f"sounds/{sid}.json"
        cid = s.get("processing", data["categories"].get(s["category"]))
        if cid is None:
            out.append((rel, f"categories: no chain (or \"none\") for category '{s['category']}'"))
            continue
        if cid == "none":
            continue
        if cid not in chains:
            out.append((where, f"processing: unknown chain '{cid}' (see data/sound_processing)"))
            continue
        kinds = {fx["fx"] for fx in chains[cid]["effects"]}
        if s.get("loops") and kinds & TIME_VARYING:
            out.append((where, f"chain '{cid}' uses {', '.join(sorted(kinds & TIME_VARYING))}, which would "
                               f"break the loop seam; loops need a chain without time-varying effects"))
        if s["category"] in data.get("dry_categories", []) and not chains[cid].get("dry"):
            out.append((where, f"category '{s['category']}' must stay dry and on top: chain '{cid}' is not "
                               f"marked \"dry\""))
    for cat in data.get("loudness", {}):
        if cat not in data["categories"]:
            out.append((rel, f"loudness/{cat}: not a category with a chain"))
    return out
