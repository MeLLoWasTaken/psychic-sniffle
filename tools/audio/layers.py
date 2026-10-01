"""Sound recipes written as data: a list of layers mixed and post-processed (backlog M1-26).

A recipe lives in data/sounds/<id>.json (schema: data/schemas/sound.schema.json). Its "layers"
are rendered by this module into a mono float signal; tools/audio/synth.py then normalises it to
the recipe's peak, encodes Ogg Vorbis and writes Godot's import settings.

Every layer has: "type", "gain" (linear, default 1), "start_s" (offset, default 0), "env"
(envelope, below), optionally "am": [rate_hz, depth] (tremolo), "saturate" (drive) and "repeat" (render the layer several times with fresh random
draws: {"every_s", "count", "jitter_s", "gain_jitter"} or {"times": [s, ...]}).

Envelopes ("env"):
  {"attack_s": a, "decay_s": d}           percussive: fast attack, exponential decay (default)
  {"adsr": [a, d, s, r]}                  sustain level s fills the time between d and r
  {"swell": [rise_s, fall_s], "curve": c} rises (power curve) then decays exponentially
  {"hold": [fade_in_s, fade_out_s]}       flat, with fades at both ends of the layer's length
  "length_s" on any envelope limits the layer (default: to the end of the sound)

Layer types:
  noise     white noise through "band": [lo, hi] (or "lowpass" / "highpass" in Hz); "sweep_to":
            [lo, hi] glides the band over the layer with overlapping windows (no filter jumps);
  tone      sine(s): "freq" or "freqs": [[hz, weight], ...]; "to": end frequency ratio (glide,
            with "curve"); "detune_cents": [...] (chorus); "vibrato": [rate_hz, depth_ratio];
            "harmonics": [[ratio, amp], ...]
  saw       band-limited sawtooth with "freq", "to", "curve" through "formants": [[hz, q, amp]]
            (voices, roars, choirs) or "lowpass"
  resonant  noise through narrow inharmonic resonators: "base" Hz (± "jitter" ratio),
            "partials": [[ratio, q, amp, decay_s], ...], "highpass": Hz. Struck metal, ice, wood:
            material without a held pitch. "glide": [ratio, seconds] slides every partial to
            ratio x its frequency over that time (a blade's ring as the edge travels);
            "scrape": [depth, decay_s] roughens the start with slow noise (an edge scraping)
  whoosh    air pushed by a passing blade: noise through a resonance rising from "lo_hz" to
            "hi_hz" over "pre_s" up to "contact_s", then falling back over "fall_s" (Doppler),
            swelling in and dying with "decay_s" after contact; "q" (default 2.2). Carries its
            own envelope
  crackle   band-limited noise gated by random short grains: "band", "per_second", "grain_s"
  sub       low sine drop: "from_hz" -> "to_hz" with "curve" (weight, thuds); keep it <= 200 Hz

Post ("post"): "saturate" (drive), "lowpass" / "highpass" (Hz), "reverb" ({length_s, mix,
brightness}), "loop_fade_s" (crossfade the end into the start for a seamless loop).
"""
from __future__ import annotations

import numpy as np
from scipy import signal

import synth as S

SR = S.SAMPLE_RATE


# ----------------------------------------------------------------------------- envelopes

def envelope(spec: dict | None, n: int) -> np.ndarray:
    spec = spec or {"attack_s": 0.002, "decay_s": 0.1}
    length = int(spec.get("length_s", n / SR) * SR)
    length = max(1, min(length, n))
    if "adsr" in spec:
        a, d, s, r = spec["adsr"]
        e = S.env_adsr(length, a, d, s, r)
    elif "swell" in spec:
        rise, fall = spec["swell"]
        rn = min(int(rise * SR), length)
        curve = float(spec.get("curve", 2.0))
        up = np.linspace(0, 1, rn, endpoint=False) ** curve
        down = np.exp(-np.arange(length - rn) / SR / max(fall, 1e-4))
        e = np.concatenate([up, down])
    elif "hold" in spec:
        fi, fo = spec["hold"]
        e = np.ones(length)
        fin, fon = min(int(fi * SR), length), min(int(fo * SR), length)
        if fin:
            e[:fin] = np.linspace(0, 1, fin) ** 2
        if fon:
            e[length - fon:] *= np.linspace(1, 0, fon) ** 2
    else:
        e = S.env_exp(length, float(spec.get("decay_s", 0.1)), float(spec.get("attack_s", 0.002)))
    if length < n:  # fade out a cut envelope (30 ms, or a tenth of it if longer) so it never clicks
        f = min(max(int(0.03 * SR), length // 10), length)
        e = e.copy()
        e[length - f:] *= np.linspace(1, 0, f)
        e = np.pad(e, (0, n - length))
    return e


# ----------------------------------------------------------------------------- helpers

def _glide(n: int, f0: float, ratio: float, curve: float) -> np.ndarray:
    """Frequency track from f0 to f0 * ratio (exponential-ish when curve > 0)."""
    if ratio == 1.0 or n < 2:
        return np.full(n, f0)
    t = np.linspace(0, 1, n)
    k = (1 - np.exp(-curve * t)) / (1 - np.exp(-curve)) if curve else t
    return f0 * (1 + (ratio - 1) * k)


def _phase(freq: np.ndarray) -> np.ndarray:
    return 2 * np.pi * np.cumsum(freq) / SR


def _filt(x: np.ndarray, layer: dict, key_band: str = "band") -> np.ndarray:
    if key_band in layer:
        lo, hi = layer[key_band]
        return S.bandpass(x, lo, min(hi, SR / 2 - 100))
    if "lowpass" in layer:
        x = S.lowpass(x, layer["lowpass"])
    if "highpass" in layer:
        x = S.highpass(x, layer["highpass"])
    return x


# ----------------------------------------------------------------------------- layer types

def _noise(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    w = S.noise(n, rng)
    if "sweep_to" in layer and "band" in layer:
        # overlapping Hann windows (hop = half a window, so they sum to 1) crossfade from band to
        # band; the first band holds before the sweep and the last band holds after it
        steps = int(layer.get("steps", 8))
        bands = np.geomspace(layer["band"], layer["sweep_to"], steps)
        span = int(envelope_length(layer, n) * float(layer.get("sweep_share", 1.0)))
        hop = max(span // (steps + 1), 32)
        k = np.arange(n)
        x = np.zeros(n)
        for i, (lo, hi) in enumerate(bands):
            c = (i + 1) * hop
            win = 0.5 + 0.5 * np.cos(np.pi * np.clip((k - c) / hop, -1, 1))
            if i == 0:
                win[k < c] = 1.0
            if i == steps - 1:
                win[k > c] = 1.0
            x += S.bandpass(w, lo, min(hi, SR / 2 - 100)) * win
    else:
        x = _filt(w, layer)
    return x


def envelope_length(layer: dict, n: int) -> float:
    return min(n, int(layer.get("env", {}).get("length_s", n / SR) * SR))


def _tone(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    freqs = layer.get("freqs", [[layer.get("freq", 440.0), 1.0]])
    harmonics = layer.get("harmonics", [[1.0, 1.0]])
    detunes = layer.get("detune_cents", [0.0])
    x = np.zeros(n)
    t = np.arange(n) / SR
    for f, w in freqs:
        track = _glide(n, f, float(layer.get("to", 1.0)), float(layer.get("curve", 3.0)))
        if "vibrato" in layer:
            rate, depth = layer["vibrato"]
            track = track * (1 + depth * np.sin(2 * np.pi * rate * t + rng.uniform(0, 6.28)))
        for c in detunes:
            ph = _phase(track * 2 ** (c / 1200)) + rng.uniform(0, 6.28)
            for ratio, amp in harmonics:
                x += w * amp * np.sin(ph * ratio)
    return x / max(len(detunes), 1)


def _saw(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    f0 = float(layer.get("freq", 100.0))
    track = _glide(n, f0, float(layer.get("to", 1.0)), float(layer.get("curve", 3.0)))
    if "vibrato" in layer:
        rate, depth = layer["vibrato"]
        t = np.arange(n) / SR
        track = track * (1 + depth * np.sin(2 * np.pi * rate * t + rng.uniform(0, 6.28)))
    if "jitter" in layer:  # rough, growling pitch
        j = S.lowpass(S.noise(n, rng), 30) * float(layer["jitter"])
        track = track * (1 + j / (np.std(j) + 1e-9) * 0.5 * float(layer["jitter"]))
    ph = _phase(track)
    x = np.zeros(n)
    top = int(min(40, (SR / 2 - 200) / max(track.max(), 1)))
    for k in range(1, top + 1):  # additive, so nothing aliases
        x += np.sin(ph * k) / k
    if "noise_mix" in layer:
        x = x + S.noise(n, rng) * float(layer["noise_mix"])
    if "formants" in layer:
        y = np.zeros(n)
        for f, q, amp in layer["formants"]:
            y += S.resonator(x, f, q) * amp
        x = y
    return _filt(x, layer, "band")


def tv_resonator(x: np.ndarray, freq: np.ndarray, q: float) -> np.ndarray:
    """Two-pole resonator whose centre frequency follows `freq` (Hz per sample): a ring or a
    filtered whoosh that glides, which fixed filters cannot do."""
    w = 2 * np.pi * np.asarray(freq, float) / SR
    r = np.exp(-w / (2 * q))
    a1, a2, g = -2 * r * np.cos(w), r * r, (1 - r * r) * 0.5
    y = np.zeros(len(x))
    y1 = y2 = 0.0
    xs = x.tolist()
    a1s, a2s, gs = a1.tolist(), a2.tolist(), g.tolist()
    for i in range(len(xs)):
        v = gs[i] * xs[i] - a1s[i] * y1 - a2s[i] * y2
        y[i] = v
        y2, y1 = y1, v
    return y


def _resonant(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    base = float(layer["base"]) * (1 + rng.uniform(-1, 1) * float(layer.get("jitter", 0.0)))
    x = np.zeros(n)
    atk = float(layer.get("env", {}).get("attack_s", 0.0005))
    t = np.arange(n) / SR
    glide = None
    if "glide" in layer:
        ratio, secs = layer["glide"]
        glide = 1 + (float(ratio) - 1) * np.clip(t / float(secs), 0, 1)
    for ratio, q, amp, dec in layer["partials"]:
        f = base * ratio
        if f >= SR / 2 - 200:
            continue
        if glide is not None:
            ring = tv_resonator(S.noise(n, rng), np.minimum(f * glide, SR / 2 - 500), q)
        else:
            ring = S.resonator(S.noise(n, rng), f, q)
        x += ring * S.env_exp(n, dec, attack_s=atk) * amp
    if "scrape" in layer:
        depth, dec = layer["scrape"]
        slow = S.lowpass(S.noise(n, rng), 120)
        x = x * np.clip(1 + float(depth) * slow / 0.05 * np.exp(-t / float(dec)), 0, 2.5)
    if "highpass" in layer:
        x = S.highpass(x, layer["highpass"])
    return x


def _whoosh(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    t = np.arange(n) / SR
    tc, pre = float(layer["contact_s"]), float(layer.get("pre_s", 0.13))
    lo, hi = float(layer.get("lo_hz", 450)), float(layer.get("hi_hz", 2400))
    u = np.clip((t - (tc - pre)) / pre, 0, 1)
    f = lo + (hi - lo) * u ** 1.5
    f = np.where(t > tc, hi - (hi - lo) * np.clip((t - tc) / float(layer.get("fall_s", 0.12)), 0, 1), f)
    amp = np.where(t <= tc, u ** 3, np.exp(-(t - tc) / float(layer.get("decay_s", 0.05))))
    return tv_resonator(S.noise(n, rng), f, float(layer.get("q", 2.2))) * amp


def _crackle(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    """Noise gated by grains, then band-limited: filtering after the gate keeps each grain inside
    the band (gating filtered noise spreads every grain's sharp onset across the spectrum, which
    showed as broadband clicks in the first hailstorm loop)."""
    g = S.grains(n, rng, per_second=float(layer.get("per_second", 800)), decay_s=float(layer.get("grain_s", 0.003)))
    return _filt(S.noise(n, rng) * g, layer)


def _sub(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    f0, f1 = float(layer.get("from_hz", 120.0)), float(layer.get("to_hz", 45.0))
    track = _glide(n, f0, f1 / f0, float(layer.get("curve", 8.0)))
    return np.sin(_phase(track))


LAYER_TYPES = {"noise": _noise, "tone": _tone, "saw": _saw, "resonant": _resonant, "crackle": _crackle, "sub": _sub,
               "whoosh": _whoosh}
ENV_DEFAULT_TYPES = {"resonant", "whoosh"}  # resonant layers carry their own per-partial decay


def render_layer(layer: dict, n: int, rng: np.random.Generator) -> np.ndarray:
    fn = LAYER_TYPES[layer["type"]]
    x = fn(layer, n, rng)
    if "am" in layer:  # tremolo, any layer type
        rate, depth = layer["am"]
        t = np.arange(n) / SR
        x = x * (1 - depth * 0.5 * (1 + np.sin(2 * np.pi * rate * t + rng.uniform(0, 6.28))))
    if layer["type"] not in ENV_DEFAULT_TYPES or "env" in layer:
        x = x * envelope(layer.get("env"), n)
    if "saturate" in layer:
        x = S.saturate(S.normalize(x), float(layer["saturate"]))
    return S.normalize(x) * float(layer.get("gain", 1.0))


def render(recipe: dict, rng: np.random.Generator) -> np.ndarray:
    """Mix a data recipe's layers and apply its post-processing."""
    n = int(float(recipe["duration_s"]) * SR)
    out = np.zeros(n)
    for layer in recipe["layers"]:
        rep = layer.get("repeat")
        if rep and "times" in rep:
            starts = list(rep["times"])
        elif rep:
            starts = [i * float(rep["every_s"]) for i in range(int(rep["count"]))]
        else:
            starts = [0.0]
        for i, s in enumerate(starts):
            s = float(layer.get("start_s", 0.0)) + s
            if rep and i > 0 and rep.get("jitter_s"):
                s += rng.uniform(-1, 1) * float(rep["jitter_s"])
            a = max(0, int(s * SR))
            if a >= n:
                continue
            x = render_layer(layer, n - a, rng)
            if rep and rep.get("gain_jitter"):
                x = x * (1 - rng.uniform(0, float(rep["gain_jitter"])))
            out[a:] += x
    if not recipe.get("loops"):
        # Layers still ringing at duration_s would stop dead there (a click, seen as a vertical
        # edge in the first spectrograms); fade the dry mix over the last 15% (at most 120 ms).
        f = min(int(0.15 * n), int(0.12 * SR))
        out[n - f:] *= np.linspace(1, 0, f) ** 2
    post = recipe.get("post", {})
    if "saturate" in post:
        out = S.saturate(S.normalize(out), float(post["saturate"]))
    if "lowpass" in post:
        out = S.lowpass(out, post["lowpass"])
    if "highpass" in post:
        out = S.highpass(out, post["highpass"])
    if "reverb" in post:
        rv = post["reverb"]
        out = S.simple_reverb(out, rng, float(rv.get("length_s", 0.8)), float(rv.get("mix", 0.2)),
                              float(rv.get("brightness", 6000)))
        if recipe.get("loops"):
            out = _wrap_tail(out, n)
    if recipe.get("loops"):
        out = S.make_loop(out[:n] if len(out) > n else out, float(post.get("loop_fade_s", 0.25)))
    return out


def _wrap_tail(x: np.ndarray, n: int) -> np.ndarray:
    """For loops: fold the reverb tail past the end back onto the start (it rings into the next
    repetition), so the loop has the same density at its seam as in its middle."""
    y = x[:n].copy()
    tail = x[n:]
    y[: min(len(tail), n)] += tail[: n]
    return y


def end_level_db(recipe: dict) -> list[tuple[int, float]]:
    """Estimated level of each layer (dB below its own peak) when the sound or the layer's
    envelope ends. A layer still loud at the end is cut off (heard as a click or a sudden stop)."""
    out = []
    if recipe.get("loops") or "layers" not in recipe:
        return out
    dur = float(recipe["duration_s"])
    for i, layer in enumerate(recipe["layers"]):
        env = layer.get("env", {})
        rep = layer.get("repeat", {})
        last = max(rep.get("times", [0.0])) if "times" in rep else \
            (float(rep.get("every_s", 0)) * (int(rep.get("count", 1)) - 1) if rep else 0.0)
        start = float(layer.get("start_s", 0.0)) + last
        cut = "length_s" in env
        t = (float(env["length_s"]) if cut else dur - start)
        if layer["type"] == "resonant" and "env" not in layer or (layer["type"] == "resonant" and "decay_s" not in env
                                                                  and "swell" not in env):
            decay = max(p[3] for p in layer["partials"])
            db = -8.686 * t / decay
        elif "adsr" in env or "hold" in env:
            db = -120.0 if not cut or "hold" in env else -8.686 * 3  # release ends at the envelope's end
        elif "swell" in env:
            rise, fall = env["swell"]
            db = 0.0 if t <= rise else -8.686 * (t - rise) / max(fall, 1e-4)
        else:
            db = -8.686 * t / float(env.get("decay_s", 0.1))
        if cut:
            db -= 12.0  # the 30 ms fade at the cut takes about 12 dB off what is heard as a stop
        out.append((i, db))
    return out


END_LEVEL_LIMIT_DB = -30.0


def static_problems(recipe: dict) -> list[str]:
    """Rules that can be checked on the recipe text (the tests measure the rendered sound too).

    Impacts (human feedback, DECISIONS.md 2026-09-29): no sustained pure tone above 200 Hz. A
    tone, saw or sub layer in an impact must stay at or below 200 Hz, or decay within 30 ms.
    """
    out = []
    for i, db in end_level_db(recipe):
        if db > END_LEVEL_LIMIT_DB:
            out.append(f"layer {i} is still at {db:.0f} dB when it ends; lengthen duration_s (or the envelope) "
                       f"so it has decayed below {END_LEVEL_LIMIT_DB:.0f} dB")
    if recipe.get("category") != "impact":
        return out
    for i, layer in enumerate(recipe.get("layers", [])):
        t = layer["type"]
        if t not in ("tone", "saw", "sub"):
            continue
        env = layer.get("env", {})
        short = "decay_s" in env and float(env["decay_s"]) <= 0.03 and "adsr" not in env and "hold" not in env
        if t == "sub":
            top = max(float(layer.get("from_hz", 120)), float(layer.get("to_hz", 45)))
        elif t == "saw":
            top = float(layer.get("freq", 100)) * max(1.0, float(layer.get("to", 1.0)))
            if "formants" in layer or "lowpass" not in layer or float(layer["lowpass"]) > 200:
                top = max(top, 201.0) if not short else top
        else:
            freqs = [f for f, _ in layer.get("freqs", [[layer.get("freq", 440.0), 1]])]
            ratios = [r for r, _ in layer.get("harmonics", [[1.0, 1.0]])]
            top = max(freqs) * max(ratios) * max(1.0, float(layer.get("to", 1.0)))
        if top > 200 and not short:
            out.append(f"impact layer {i} ({t}) holds a tone up to {top:.0f} Hz; impacts may only hold "
                       f"tones at or below 200 Hz (use resonant noise for metal and ice)")
    return out
