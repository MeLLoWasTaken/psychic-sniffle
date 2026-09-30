"""Automated checks on generated sound effects (tools/audio/synth.py output).

Rules come from human listening feedback:
  - Impacts must not be tonal. weapon_impact v1 put 93% of its energy above 200 Hz into narrow
    tonal peaks and sounded "like you scored a point"; v2 has 0%.
  - Non-impact sounds must not click (a one-sample jump in level).
  - Heals must carry weight: holy_heal v1 had 20% of its energy below 250 Hz and felt light.
  - Peaks stay at or below -1 dBFS, the level reserved for the enemy CC warning.
Backlog M1-26 (sound v1) adds, for every sound built from data/sounds:
  - no file is louder than the CC warning, by peak, integrated loudness (BS.1770) and loudest
    400 ms (momentary);
  - every impact is non-tonal, every heal has low-end weight, smooth sounds do not click, loops
    have no jump at the seam;
  - weapon hits differ measurably by weapon (greatsword, mace, staff) and by armor;
  - plate footsteps are heavier than cloth;
  - the generated files match their recipes (manifest hash) and rebuilding gives the same samples.
"""
import json
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf
from scipy import signal

REPO = Path(__file__).resolve().parent.parent
SFX = REPO / "game" / "assets" / "audio" / "sfx"
sys.path.insert(0, str(REPO / "tools" / "audio"))
import analysis  # noqa: E402
import layers  # noqa: E402
import synth  # noqa: E402

warnings.filterwarnings("ignore", message="nperseg")
RECIPES = synth.load_sound_data()
SOUND_MAP = json.loads((REPO / "data" / "sound_map" / "default.json").read_text())
CC_WARNING = SOUND_MAP["cc_warning"]["sound"]


def files_of(sid: str) -> list[str]:
    return synth.output_stems(RECIPES[sid])


def of_category(*cats: str) -> list[str]:
    return [stem for sid, r in RECIPES.items() if r["category"] in cats for stem in files_of(sid)]


ALL_FILES = [stem for sid in RECIPES for stem in files_of(sid)]

IMPACTS = of_category("impact")  # includes the first impact_blunt, impact_slash, impact_pierce
# no sharp transients expected; rime_sepulcher starts with an ice crack by design
SMOOTH = [f for f in of_category("cast", "heal", "swing", "loop", "buff") if not f.startswith("rime_sepulcher")]
HEALS = of_category("heal")


def load(name: str) -> tuple[np.ndarray, int]:
    x, sr = sf.read(SFX / f"{name}.ogg")
    return x, sr


def tonal_share(x: np.ndarray, sr: int) -> float:
    """Share of energy above 200 Hz sitting in narrow spectral peaks (20x the local median).

    The median spans 31 bins (about 360 Hz). A much wider median (101 bins) misread steep
    filter edges in plain noise as peaks: a noise-only pierce sound measured 31% "tonal".
    """
    f, p = signal.welch(x, sr, nperseg=4096)
    p = p[f > 200]
    peaks = p > 20 * signal.medfilt(p, 31)
    return float(p[peaks].sum() / p.sum())


def test_tonality_detector_flags_the_chime_like_v1_hit():
    x, sr = sf.read(Path(__file__).resolve().parent.parent / "previews" / "audio" / "v1" / "weapon_impact.ogg")
    assert tonal_share(x, sr) > 0.8


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


# ----------------------------------------------------------------------------- M1-26

def test_every_recipe_has_its_files_and_they_are_up_to_date():
    manifest = json.loads((SFX / "manifest.json").read_text())
    for sid, r in RECIPES.items():
        for stem in files_of(sid):
            assert (SFX / f"{stem}.ogg").exists(), f"{stem}.ogg missing: run tools/audio/synth.py --data"
        if r.get("variants", 1) > 1:
            assert (SFX / f"{sid}.tres").exists(), f"{sid}.tres (randomizer) missing"
        assert manifest.get(sid, {}).get("hash") == synth.recipe_hash(r), \
            f"{sid}: recipe changed since its files were built; run tools/audio/synth.py --data"


@pytest.mark.parametrize("sid", ["hit_mace_plate", "frost_channel_loop", "cc_warning", "impact_blunt"])
def test_rebuilding_gives_the_same_samples(sid):
    a = synth.signal_for(RECIPES[sid], 7)
    b = synth.signal_for(RECIPES[sid], 7)
    assert np.array_equal(a, b)


@pytest.fixture(scope="module")
def warning_levels():
    x, sr = load(CC_WARNING)
    return analysis.peak_dbfs(x), analysis.integrated_loudness(x, sr), analysis.momentary_max(x, sr)


@pytest.mark.parametrize("name", [f for f in ALL_FILES if f != CC_WARNING])
def test_nothing_is_louder_than_the_cc_warning(name, warning_levels):
    peak, integrated, momentary = warning_levels
    x, sr = load(name)
    assert analysis.peak_dbfs(x) <= peak + 0.05, "peak"
    assert analysis.integrated_loudness(x, sr) < integrated - 1.0, "integrated loudness (at least 1 LU below)"
    assert analysis.momentary_max(x, sr) < momentary - 1.0, "loudest 400 ms (at least 1 LU below)"


def test_cc_warning_is_near_full_scale():
    x, sr = load(CC_WARNING)
    assert -2.0 <= analysis.peak_dbfs(x) <= -1.0
    assert analysis.integrated_loudness(x, sr) > -14.0  # dense and sustained, not a thin beep


@pytest.mark.parametrize("sid", [sid for sid, r in RECIPES.items() if r.get("loops")])
def test_loops_have_no_jump_at_the_seam(sid):
    x, sr = load(sid)
    typical = np.percentile(np.abs(np.diff(x)), 99)
    assert abs(x[0] - x[-1]) <= typical, "the end does not join the start"


def _mean_features(stems: list[str]) -> dict[str, np.ndarray]:
    out = {"high": [], "low": [], "mid": [], "decay": [], "centroid": []}
    for stem in stems:
        x, sr = load(stem)
        out["high"].append(analysis.band_share(x, sr, 24000, 2000))
        out["low"].append(analysis.band_share(x, sr, 250))
        out["mid"].append(analysis.band_share(x, sr, 2000, 250))
        out["decay"].append(analysis.decay_time(x, sr))
        out["centroid"].append(np.log2(analysis.spectral_centroid(x, sr)))
    return {k: np.array(v) for k, v in out.items()}


@pytest.mark.parametrize("armor", ["plate", "cloth"])
def test_weapon_hits_differ_by_weapon_type(armor):
    """Each weapon keeps its own signature on every variation (human feedback: a sword must
    sound like a slash, not a blunt hit): the greatsword's bright slash owns the band above
    2 kHz, the mace's blunt crack the weight below 250 Hz, the staff's wooden thud the mids
    (250 Hz to 2 kHz) with the shortest ring."""
    f = {w: _mean_features(files_of(f"hit_{w}_{armor}")) for w in ("greatsword", "mace", "staff")}
    others = lambda w, k: np.concatenate([f[o][k] for o in f if o != w])  # noqa: E731
    assert f["greatsword"]["high"].min() > 2 * others("greatsword", "high").max()
    assert f["mace"]["low"].min() > others("mace", "low").max()
    assert f["mace"]["centroid"].max() < others("mace", "centroid").min()
    assert f["staff"]["mid"].min() > 2 * others("staff", "mid").max()
    assert f["staff"]["decay"].max() < others("staff", "decay").min()


@pytest.mark.parametrize("weapon", ["greatsword", "mace", "staff"])
def test_weapon_hits_differ_by_armor(weapon):
    """Plate and cloth hits of one weapon differ by more than 3 spreads in at least one feature."""
    p, c = _mean_features(files_of(f"hit_{weapon}_plate")), _mean_features(files_of(f"hit_{weapon}_cloth"))
    separations = [abs(p[k].mean() - c[k].mean()) / (np.sqrt((p[k].var() + c[k].var()) / 2) + 1e-3) for k in p]
    assert max(separations) > 3.0, dict(zip(p, np.round(separations, 1)))


def test_plate_footsteps_are_heavier_than_cloth():
    p, c = _mean_features(files_of("footstep_plate")), _mean_features(files_of("footstep_cloth"))
    assert p["low"].min() > c["low"].max()
    loud = lambda stems: [analysis.integrated_loudness(*load(s)) for s in stems]  # noqa: E731
    assert min(loud(files_of("footstep_plate"))) > max(loud(files_of("footstep_cloth")))


def test_static_rules_catch_a_tonal_impact_and_a_cut_off_layer():
    tonal = {"category": "impact", "duration_s": 0.5, "layers": [
        {"type": "tone", "freq": 880, "env": {"attack_s": 0.001, "decay_s": 0.3}}]}
    assert any("880 Hz" in p for p in layers.static_problems(tonal))
    ok = {"category": "impact", "duration_s": 0.5, "layers": [
        {"type": "sub", "from_hz": 150, "to_hz": 50, "env": {"attack_s": 0.001, "decay_s": 0.1}}]}
    assert layers.static_problems(ok) == []
    cut = {"category": "release", "duration_s": 0.3, "layers": [
        {"type": "noise", "band": [500, 2000], "env": {"attack_s": 0.001, "decay_s": 0.5}}]}
    assert any("still at" in p for p in layers.static_problems(cut))


def test_measured_impacts_back_up_the_static_rule():
    """The one tonal recipe the static rule rejects is also measured as tonal when rendered."""
    tonal = {"id": "t", "category": "impact", "peak_dbfs": -3, "duration_s": 0.6, "layers": [
        {"type": "tone", "freqs": [[660, 1], [880, 0.7]], "env": {"attack_s": 0.001, "decay_s": 0.3}},
        {"type": "noise", "highpass": 2000, "env": {"attack_s": 0.0003, "decay_s": 0.004}}]}
    x = layers.render(tonal, np.random.default_rng(1))
    assert tonal_share(x, 48000) > 0.5


# ----------------------------------------------------------------------------- X-04 processing

import arena  # noqa: E402
import processing  # noqa: E402

PROCESSING = json.loads((REPO / "data" / "sound_processing" / "default.json").read_text())
ACOUSTICS = {p.stem: json.loads(p.read_text()) for p in sorted((REPO / "data" / "acoustics").glob("*.json"))}
CATEGORY_OF = {stem: r["category"] for sid, r in RECIPES.items() for stem in files_of(sid)}
PEAK_OF = {stem: r["peak_dbfs"] for sid, r in RECIPES.items() for stem in files_of(sid)}
UNPROCESSED = {stem: r.get("processing") == "none" for sid, r in RECIPES.items() for stem in files_of(sid)}
ONE_SHOTS = [stem for sid, r in RECIPES.items() if not r.get("loops") for stem in files_of(sid)]
WORLD = [f for f in ALL_FILES if SOUND_MAP["categories"][CATEGORY_OF[f]]["positional"]]


@pytest.mark.parametrize("name", ALL_FILES)
def test_no_dc_offset(name):
    x, _ = load(name)
    assert analysis.dc_offset(x) < 10 ** (-46 / 20), "mean of the file above -46 dBFS"


@pytest.mark.parametrize("name", ONE_SHOTS)
def test_one_shot_tails_are_not_cut_off(name):
    """Build side: processing pads one-shots for their reverb and release tails and stops when a
    tail is still above -60 dB at the end of the pad; write_sound trims below -60 dBFS and fades
    the last 20 ms. So the last 5 ms of a file sit far below its peak (a reverb cut off while
    ringing at -10 dB would end near -22 dB)."""
    x, sr = load(name)
    assert analysis.tail_db(x, sr, 5) < -30.0


@pytest.mark.parametrize("cat", sorted(PROCESSING["loudness"]))
def test_loudness_per_category_within_its_window(cat):
    """Peak-to-loudness ratio (recipe peak minus loudest 400 ms) inside the category's window, and
    its spread within the category no wider than allowed: consistent density after processing.
    Sounds marked "processing": "none" (the human-approved originals, kept bit-exact) are not
    processed, so this window does not apply to them; every other audio test still does."""
    lo, hi = PROCESSING["loudness"][cat]["plr_lu"]
    plr = {f: PEAK_OF[f] - analysis.momentary_max(*load(f)) for f in ALL_FILES
           if CATEGORY_OF[f] == cat and not UNPROCESSED.get(f)}
    outside = {f: round(v, 1) for f, v in plr.items() if not lo <= v <= hi}
    assert not outside, f"outside {lo}..{hi} LU: {outside}"
    assert np.std(list(plr.values())) <= PROCESSING["loudness"][cat]["max_spread_lu"]


def _godot_reverb_reference(x, p, sr=48000):
    """Sample-by-sample transcription of Godot's Reverb::process (reverb_filter.cpp, left channel)."""
    import math
    n = len(x)
    pre = min(max(int(round(p["predelay_ms"] / 1000 * sr)), 10), int(0.5 * sr))
    echo, ep, inp = [0.0] * sr, 0, []
    for i in range(n):
        v = echo[(ep - pre) % sr] * p["predelay_feedback"] + x[i]
        echo[ep] = v
        ep = (ep + 1) % sr
        inp.append(v)
    aux = math.exp(-2 * math.pi * p["hipass"] * 6000 / sr)
    h1 = h2 = 0.0
    for i in range(n):
        v = inp[i]
        inp[i] = v * (1 + aux) / 2 - h1 * (1 + aux) / 2 + h2 * aux
        h2, h1 = inp[i], v
    fb = min(max(0.7 + p["room_size"] * 0.28, 0.7), 0.98)
    d = math.exp(-2 * math.pi * ((p["damping"] / 2 + 0.5) ** 2) * 10000 / sr)
    dst = [0.0] * n
    for t in arena.COMB_TUNINGS:
        size = int(round(t * sr))
        buf, pos, dh = [0.0] * size, 0, 0.0
        for j in range(n):
            out = buf[pos] * fb * (1 - d) + dh * d
            dh = out
            buf[pos] = inp[j] + out
            dst[j] += out
            pos = (pos + 1) % size
    for t in arena.ALLPASS_TUNINGS:
        size = int(round(t * sr))
        buf, pos = [0.0] * size, 0
        for j in range(n):
            a = buf[pos]
            buf[pos] = 0.7 * a + dst[j]
            dst[j] = a - 0.7 * buf[pos]
            pos = (pos + 1) % size
    return np.array([dst[i] * p["wet"] * 0.6 + x[i] * p["dry"] for i in range(n)])


def test_arena_model_matches_godots_reverb():
    """tools/audio/arena.py (block-wise numpy) gives the same samples as Godot's algorithm."""
    x = np.random.default_rng(3).standard_normal(2000) * np.exp(-np.arange(2000) / 400)
    for p in (r["reverb"] for r in ACOUSTICS.values()):
        fast = arena.godot_reverb(x, p, tail_s=0.3)
        assert np.max(np.abs(fast - _godot_reverb_reference(np.concatenate([x, np.zeros(14400)]), p))) < 1e-9


@pytest.mark.parametrize("acoustics", sorted(ACOUSTICS))
def test_arena_reverb_keeps_the_cc_warning_the_loudest(acoustics, warning_levels):
    """World sounds pass through the arena reverb on the world bus; the warnings stay dry on the
    Interface bus. After the reverb every world sound is still at least 1 LU quieter than the
    warning (integrated and loudest 400 ms) and not above its peak."""
    peak, integrated, momentary = warning_levels
    rv = ACOUSTICS[acoustics]["reverb"]
    worst = {}
    for f in WORLD:
        x, sr = load(f)
        y = arena.godot_reverb(x, rv, sr)
        levels = (analysis.peak_dbfs(y) - peak, analysis.integrated_loudness(y, sr) - integrated,
                  analysis.momentary_max(y, sr) - momentary)
        if levels[0] > 0.05 or levels[1] >= -1.0 or levels[2] >= -1.0:
            worst[f] = np.round(levels, 1)
    assert not worst, f"louder than the CC warning through {acoustics} (peak, integrated, momentary vs warning): {worst}"


_RENDERS: dict = {}


def _render(sid: str, processed_flag: bool) -> np.ndarray:
    """First variation of a recipe at its peak: the raw mix rendered (cached: rendering is slow), or
    processed, which is the built file."""
    if (sid, processed_flag) not in _RENDERS:
        r = RECIPES[sid]
        if processed_flag:
            _RENDERS[(sid, True)] = load(files_of(sid)[0])[0]
        else:
            x = synth.signal_for(r, int(r.get("seed", 1)), processed=False)
            _RENDERS[(sid, False)] = x / np.max(np.abs(x)) * 10 ** (r["peak_dbfs"] / 20)
    return _RENDERS[(sid, processed_flag)]


def _mean(sids, fn, processed_flag):
    return float(np.mean([fn(_render(sid, processed_flag), 48000) for sid in sids]))


@pytest.fixture(scope="module")
def impact_features():
    # the default impact chain's goal (body and punch); the other impact chains have their own
    # goals, tested below (slash: brighter, human feedback that a sword must sound like a slash;
    # impact_low: lower, human feedback on the mace; light and tight: onset only)
    sids = [sid for sid, r in RECIPES.items() if r["category"] == "impact" and r.get("processing", "impact") == "impact"]
    feats = {"low_mid": analysis.low_mid_share, "crest": analysis.crest_factor_db, "mud": analysis.mud_share,
             "harsh": analysis.harsh_share, "momentary": analysis.momentary_max, "decay": analysis.decay_time}
    return {k: (_mean(sids, fn, False), _mean(sids, fn, True)) for k, fn in feats.items()}


def test_processing_gives_impacts_body_and_punch_without_mud_or_harshness(impact_features):
    """X-04 goal, measured on every impact recipe (first variation), raw mix vs processed, both at
    the recipe's peak: more low-mid body (100-500 Hz), transient punch kept (crest factor not lower),
    no louder or quieter on average by more than 1.5 LU, no more mud (250-500 Hz) than 1.5 points,
    less harshness (2.5-5 kHz), and the ring at most 30% longer."""
    f = impact_features
    assert f["low_mid"][1] > f["low_mid"][0] + 0.02, f["low_mid"]
    assert f["crest"][1] >= f["crest"][0] - 0.1, f["crest"]
    assert abs(f["momentary"][1] - f["momentary"][0]) <= 1.5, f["momentary"]
    assert f["mud"][1] <= f["mud"][0] + 0.015, f["mud"]
    assert f["harsh"][1] < f["harsh"][0], f["harsh"]
    assert f["decay"][1] <= f["decay"][0] * 1.3, f["decay"]


def _chain_sids(chain):
    return [sid for sid, r in RECIPES.items() if r.get("processing") == chain]


def test_slash_chain_brightens_and_keeps_the_draw():
    """Slashes: more energy above 2 kHz after processing, and the draw is not shortened."""
    sids = _chain_sids("slash")
    assert sids
    high = [_mean(sids, lambda x, sr: analysis.band_share(x, sr, 24000, 2000), p) for p in (False, True)]
    decay = [_mean(sids, analysis.decay_time, p) for p in (False, True)]
    assert high[1] >= high[0], high
    assert decay[1] >= decay[0] * 0.9, decay


def test_low_impact_chain_lowers_the_pitch():
    """impact_low (the mace): the spectral centroid drops by at least 2 semitones."""
    sids = _chain_sids("impact_low")
    assert sids
    c = [_mean(sids, lambda x, sr: np.log2(analysis.spectral_centroid(x, sr)), p) for p in (False, True)]
    assert c[0] - c[1] > 2 / 12, c


def test_processing_gives_casts_space_and_keeps_their_low_end_dry():
    """Casts, buffs and releases: the plate adds a tail (the -20 dB decay gets longer) while the low
    end stays dry (the share of energy below 250 Hz does not drop by more than 5 points)."""
    sids = [sid for sid, r in RECIPES.items() if r["category"] in ("cast", "buff", "release")]
    decay = _mean(sids, analysis.decay_time, False), _mean(sids, analysis.decay_time, True)
    low = [_mean(sids, lambda x, sr: analysis.band_share(x, sr, 250), p) for p in (False, True)]
    assert decay[1] > decay[0] * 1.1, decay
    assert low[1] >= low[0] - 0.05, low


def test_limiter_is_clean_and_the_build_catches_clipping():
    """The limiter holds its ceiling without a flat top; an effect that hard-clips stops the build."""
    t = np.arange(48000) / 48000
    x = np.sin(2 * np.pi * 220 * t) * np.where((t > 0.3) & (t < 0.35), 1.0, 0.2)  # a loud burst
    chain = [{"fx": "limiter", "threshold_db": -6, "release_ms": 50}]
    y = processing.apply_chain(x, chain, np.random.default_rng(1))
    burst = np.max(np.abs(y[int(0.3 * 48000):int(0.35 * 48000)]))
    quiet = np.max(np.abs(y[int(0.6 * 48000):]))
    assert 20 * np.log10(burst / quiet) < 14.0 - 6.0 + 0.5  # the 14 dB burst now stands 6 dB lower
    assert processing.flat_top_run(y) <= processing.FLAT_TOP_LIMIT
    assert processing.flat_top_run(np.clip(x * 4, -1, 1)) > processing.FLAT_TOP_LIMIT
    processing.EFFECTS["_clip"] = lambda s, fx, r: np.clip(s * 4 / np.max(np.abs(s)), -1, 1)
    try:
        with pytest.raises(ValueError, match="clipped"):
            processing.apply_chain(x, [{"fx": "_clip"}], np.random.default_rng(1))
    finally:
        del processing.EFFECTS["_clip"]


def test_the_build_catches_a_reverb_tail_cut_off(monkeypatch):
    monkeypatch.setattr(processing, "tail_s", lambda chain: 0.0)
    x = np.zeros(4800)
    x[100] = 1.0
    with pytest.raises(ValueError, match="tail cut off"):
        processing.apply_chain(x, [{"fx": "highpass", "hz": 30}, {"fx": "plate", "decay_s": 2.0, "wet": 0.5}],
                               np.random.default_rng(1))


def test_loops_stay_seamless_through_processing():
    """Loops are processed as three joined copies; the kept copy joins end to start like the raw loop."""
    for sid in [s for s, r in RECIPES.items() if r.get("loops")]:
        y = synth.signal_for(RECIPES[sid], 1)
        typical = np.percentile(np.abs(np.diff(y)), 99)
        assert abs(y[0] - y[-1]) <= typical, sid


def test_no_processing_leaves_the_raw_mix():
    """A sound with "processing": "none" is its raw mix, sample for sample."""
    r = dict(RECIPES["ui_click"], processing="none")
    assert np.array_equal(synth.signal_for(r, 1), synth.signal_for(r, 1, processed=False))
