"""Spell effect data checks in tools/validate_data.py (backlog M1-25) that need more than a
one-file fixture: coverage of every finished kit's abilities, and explicit "none" entries."""
import json
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
from validate_data import validate  # noqa: E402


def _copy(tmp_path: Path) -> Path:
    shutil.copytree(REPO / "data", tmp_path / "data")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "blender").symlink_to(REPO / "tools" / "blender")
    return tmp_path / "data"


def test_every_kit_ability_needs_an_effect_entry(tmp_path: Path):
    data = _copy(tmp_path)
    (data / "effects" / "wide_hew.json").unlink()
    (data / "effects" / "auto_attack.json").unlink()  # shared class ability
    errors = validate(data)
    assert any("ability 'wide_hew' has no effect entry" in e for e in errors), errors
    assert any("ability 'auto_attack' has no effect entry" in e for e in errors), errors


def test_none_entry_is_accepted_only_with_a_reason_and_no_stages(tmp_path: Path):
    data = _copy(tmp_path)
    path = data / "effects" / "wide_hew.json"
    path.write_text(json.dumps({"id": "wide_hew", "none": True, "reason": "test"}))
    assert validate(data) == []
    path.write_text(json.dumps({"id": "wide_hew", "none": True}))
    assert any("marked none without a reason" in e for e in validate(data))
    path.write_text(json.dumps({"id": "wide_hew", "none": True, "reason": "x", "melee": {"style": "arc"}}))
    assert any("marked none but has stages" in e for e in validate(data))


def test_every_applied_aura_needs_a_visual(tmp_path: Path):
    data = _copy(tmp_path)
    path = data / "effects" / "rimebind.json"
    doc = json.loads(path.read_text())
    del doc["auras"]
    path.write_text(json.dumps(doc))
    assert any("aura 'rimebound' applied by 'rimebind' has no visual" in e for e in validate(data))


def test_auras_that_only_talents_apply_need_a_visual_and_may_have_one(tmp_path: Path):
    """X-13: Throat Punch silences only with a PvP talent (windpipe_crushed). Its effect file may
    define that aura's visual, and must, since the talent makes the ability apply it."""
    data = _copy(tmp_path)
    path = data / "effects" / "throat_punch.json"
    doc = json.loads(path.read_text())
    assert doc["auras"]["windpipe_crushed"]["style"] == "silence"
    del doc["auras"]
    path.write_text(json.dumps(doc))
    assert any("aura 'windpipe_crushed' applied by 'throat_punch' has no visual" in e for e in validate(data))
    # an aura neither the ability nor any talented version of it applies is still refused
    doc["auras"] = {"windpipe_crushed": {"style": "silence"}, "bound_dazed": {"style": "slow"}}
    path.write_text(json.dumps(doc))
    assert any("aura 'bound_dazed' is not applied by ability 'throat_punch'" in e for e in validate(data))


def test_a_twist_must_take_away_colliders_that_exist_and_never_the_walls(tmp_path: Path):
    """M2-16: a collapse names collider tags of its map; walls and gates may not go."""
    data = _copy(tmp_path)
    path = data / "maps" / "gallows_courtyard.json"
    m = json.loads(path.read_text())
    m["twists"][0]["tags"] = ["scaffold"]
    path.write_text(json.dumps(m))
    assert any("takes away 'scaffold', which no collider has" in e for e in validate(data))
    m["twists"][0]["tags"] = ["wall"]
    m["twists"][0]["sound"] = "no_such_sound"
    path.write_text(json.dumps(m))
    errors = validate(data)
    assert any("the arena would open to its outside" in e for e in errors), errors
    assert any("sound 'no_such_sound' is not in data/sounds" in e for e in errors), errors


def test_a_turning_collider_keeps_room_along_its_whole_path(tmp_path: Path):
    """M2-10: a rotate twist turns circles only, and its path keeps 1 m from everything else."""
    data = _copy(tmp_path)
    path = data / "maps" / "burning_foundry.json"
    m = json.loads(path.read_text())
    assert not [e for e in validate(data) if "casting_wheel" in e and "passes" in e]
    m["colliders"][1]["center"] = [0, 4.5]  # a crucible ring that grazes the furnace
    path.write_text(json.dumps(m))
    assert any("passes" in e and "furnace" in e for e in validate(data))
    m["colliders"][1]["center"] = [0, 9]
    m["twists"][0]["tags"] = ["crucible", "mold"]
    path.write_text(json.dumps(m))
    assert any("only circle colliders can turn" in e for e in validate(data))
