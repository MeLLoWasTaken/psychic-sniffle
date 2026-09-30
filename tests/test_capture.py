"""Captured motion in clips (backlog X-01): tools/blender/animation.py's sampling of fitted captures."""
import copy
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "blender"))
import animation  # noqa: E402

ANIM = animation.load_set("humanoid")
CAPTURED = [n for n, c in ANIM["clips"].items() if c.get("capture")]


def test_run_and_idle_use_captures():
    assert {"run", "idle"} <= set(CAPTURED)


def test_captured_loops_join_seamlessly():
    """The fitted samples of a loop close exactly; sampled frames join within 0.1 degrees (the
    stored length_s is rounded, 0.7333 for 22 frames at 30 fps, which moves the last frame a
    hair past the loop point)."""
    for name in CAPTURED:
        if not ANIM["clips"][name]["loop"]:
            continue
        fitted = animation.load_capture(ANIM["clips"][name]["capture"]["source"])
        for bone, terms in fitted["channels"].items():
            for term, v in terms.items():
                assert v[0] == v[-1], f"{name} {bone}.{term}"
        for build in ("heavy", "lean"):
            frames = animation.sample_clip(ANIM, name, build)
            first, last = frames[0], frames[-1]
            for bone, terms in first.items():
                for term, v in terms.items():
                    assert abs(last[bone][term] - v) < 0.1, f"{name} {build} {bone}.{term}"


def test_run_starts_with_the_left_leg_forward():
    """Phase convention shared with the scripted clips (the free arm's keys depend on it)."""
    fitted = animation.load_capture("run")["channels"]
    swing = np.array(fitted["thigh_l"]["swing"][:-1])
    assert int(np.argmax(swing)) == 0
    right = np.array(fitted["thigh_r"]["swing"][:-1])
    assert 0.4 < np.argmax(right) / len(right) < 0.6


def test_gain_scales_the_movement_around_its_mean():
    anim = copy.deepcopy(ANIM)
    clip = anim["clips"]["run"]
    clip["keys"] = [{"t": 0.0, "pose": {}}, {"t": 0.1, "pose": {}}]
    clip["capture"]["gains"] = {"thigh.swing": 1.0}
    base = np.array([f["thigh_l"]["swing"] for f in animation.sample_clip(anim, "run", "heavy")])
    clip["capture"]["gains"] = {"thigh.swing": 2.0}
    double = np.array([f["thigh_l"]["swing"] for f in animation.sample_clip(anim, "run", "heavy")])
    mean = base[:-1].mean()
    assert np.allclose(double - mean, 2.0 * (base - mean), atol=0.05)


def test_relative_capture_keeps_the_clip_posture():
    """The idle takes only the captured movement: averaged over the loop, it adds nothing."""
    anim = copy.deepcopy(ANIM)
    with_cap = animation.sample_clip(anim, "idle", "heavy")
    del anim["clips"]["idle"]["capture"]
    without = animation.sample_clip(anim, "idle", "heavy")
    for bone in ("spine", "chest", "neck"):
        for term in with_cap[0][bone]:
            diff = [a[bone][term] - b.get(bone, {}).get(term, 0.0) for a, b in zip(with_cap[:-1], without[:-1])]
            assert abs(np.mean(diff)) < 0.2, f"{bone}.{term}"
            assert np.ptp(diff) > 0.3, f"{bone}.{term} does not move"


def test_idle_capture_leaves_the_feet_planted():
    """Only the upper body takes the idle capture: hips and legs stay as keyed, so the feet do not
    slide (the game's standing foot lock would otherwise engage on level floors)."""
    bones = set(ANIM["clips"]["idle"]["capture"]["bones"])
    assert not bones & {"root", "pelvis", "thigh_l", "thigh_r", "calf_l", "calf_r", "foot_l", "foot_r"}


def test_root_motion_scales_with_leg_length():
    heavy = np.array([f["root"]["up"] for f in animation.sample_clip(ANIM, "run", "heavy")])
    lean = np.array([f["root"]["up"] for f in animation.sample_clip(ANIM, "run", "lean")])
    ratio = ANIM["capture_leg_m"]["lean"] / ANIM["capture_leg_m"]["heavy"]
    assert np.allclose(lean, heavy * ratio, atol=1e-6)
