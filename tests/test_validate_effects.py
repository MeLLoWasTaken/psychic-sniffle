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
