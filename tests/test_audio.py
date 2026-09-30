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
