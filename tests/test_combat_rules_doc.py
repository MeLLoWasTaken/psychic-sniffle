"""docs/combat_rules.md (backlog M2-01): every combat rule names its test, and every named test
exists; a rule without a test names the backlog item that will add one."""
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOC = REPO / "docs" / "combat_rules.md"


def rows():
    out = []
    for line in DOC.read_text().splitlines():
        if not line.startswith("| ") or line.startswith("| Area") or line.startswith("| ---"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        assert len(cells) == 4, f"malformed row: {line}"
        out.append(cells)
    return out


def test_the_table_has_the_rules():
    assert len(rows()) >= 40


def test_every_rule_names_a_test_or_a_plan():
    for area, rule, tests, planned in rows():
        assert tests or planned, f"{area}: '{rule}' names neither a test nor a planned backlog item"
        if planned:
            assert re.search(r"\bM\d+(-\d+)?\b", planned), f"'{rule}': planned '{planned}' names no backlog item"


def test_every_named_test_exists():
    for _area, rule, tests, _planned in rows():
        for ref in filter(None, (t.strip() for t in tests.split(";"))):
            path, _, name = ref.partition("::")
            base = REPO / "game" / "test" if path.endswith(".gd") else REPO / "tests"
            f = base / path
            assert f.exists(), f"'{rule}': {path} does not exist"
            pattern = rf"^func {re.escape(name)}\(" if path.endswith(".gd") else rf"^def {re.escape(name)}\("
            assert re.search(pattern, f.read_text(), re.M), f"'{rule}': {path} has no {name}"
