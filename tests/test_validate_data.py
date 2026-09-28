"""Tests for tools/validate_data.py.

The real data must pass. Each fixture in tests/data_fixtures injects one mistake into a copy
of the real data, and the validator must report it with the expected message.
Fixture format: {"description", "file", "set": {json_pointer: value}, "delete": [json_pointer], "expect"}.
"""
import json
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
from validate_data import validate  # noqa: E402

FIXTURES = sorted((REPO / "tests" / "data_fixtures").glob("*.json"))


def _walk(doc, pointer):
    parts = [p.replace("~1", "/").replace("~0", "~") for p in pointer.lstrip("/").split("/")]
    for p in parts[:-1]:
        doc = doc[int(p)] if isinstance(doc, list) else doc[p]
    last = parts[-1]
    return doc, (int(last) if isinstance(doc, list) else last)


def _copy_repo(tmp_path: Path) -> Path:
    shutil.copytree(REPO / "data", tmp_path / "data")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "blender").symlink_to(REPO / "tools" / "blender")
    return tmp_path / "data"


def test_real_data_is_valid():
    errors = validate(REPO / "data")
    assert errors == [], "\n".join(errors)


def test_at_least_six_fixtures():
    assert len(FIXTURES) >= 6


@pytest.mark.parametrize("fixture", FIXTURES, ids=lambda p: p.stem)
def test_fixture_is_caught(fixture: Path, tmp_path: Path):
    spec = json.loads(fixture.read_text())
    data_dir = _copy_repo(tmp_path)
    target = data_dir / spec["file"]
    doc = json.loads(target.read_text())
    for pointer, value in spec.get("set", {}).items():
        parent, key = _walk(doc, pointer)
        parent[key] = value
    for pointer in spec.get("delete", []):
        parent, key = _walk(doc, pointer)
        del parent[key]
    target.write_text(json.dumps(doc))
    errors = validate(data_dir)
    assert any(spec["expect"] in e for e in errors), (
        f"expected an error containing {spec['expect']!r}; got:\n" + "\n".join(errors)
    )
