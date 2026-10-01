"""Combat rules that live in the data rather than the code (backlog M2-01, docs/combat_rules.md).

docs/DESIGN.md "Core combat system": interrupts lock a school for 3 to 4 s and have 15 to 24 s
cooldowns (healers get a weaker or longer-cooldown one, per the kit template); Break Free has a
90 s cooldown; health comes from a role template; most ranged abilities and all healing reach 40 m.
"""
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "data"


def _load(folder):
    return {p.stem: json.loads(p.read_text()) for p in sorted((DATA / folder).glob("*.json"))}


ABILITIES = _load("abilities")
SPECS = _load("specs")
TUNING = json.loads((DATA / "tuning.json").read_text())


def _effects(ab, kind):
    return [e for e in ab.get("effects", []) if e["type"] == kind]


def _role(ab):
    return SPECS.get(ab["owner"], {}).get("role", "shared")


def test_interrupts_lock_a_school_for_3_to_4_s():
    found = 0
    for ab in ABILITIES.values():
        for e in _effects(ab, "interrupt"):
            found += 1
            assert 3 <= e["school_lock_s"] <= 4, f"{ab['id']} locks for {e['school_lock_s']} s"
    assert found >= 3


def test_interrupt_cooldowns_are_15_to_24_s_and_healers_may_wait_longer():
    for ab in ABILITIES.values():
        if not _effects(ab, "interrupt"):
            continue
        cd = ab["cooldown_s"]
        if _role(ab) == "healer":
            assert cd >= 15, f"{ab['id']}: a healer's interrupt is weaker or slower, not faster ({cd} s)"
        else:
            assert 15 <= cd <= 24, f"{ab['id']}: interrupt cooldown {cd} s is outside 15 to 24 s"


def test_break_free_has_a_90_s_cooldown():
    ab = ABILITIES["break_free"]
    assert ab["cooldown_s"] == 90
    assert _effects(ab, "remove_cc")
    assert ab["owner"] == "shared"


def test_health_comes_from_the_role_template():
    assert TUNING["health"]["dps"] == 60000
    assert TUNING["health"]["healer"] == 60000
    assert TUNING["health"]["tank"] == 72000
    for spec_id, spec in SPECS.items():
        assert spec["role"] in TUNING["health"], spec_id
        assert "health_override" not in spec, f"{spec_id} overrides the role's health template"


CLASSES = _load("classes")


def _ranged_owner(owner):
    """True for abilities of ranged specs (casters and healers), or of a class whose specs all are."""
    if owner in SPECS:
        return SPECS[owner]["range"] != "melee"
    if owner in CLASSES:
        return all(SPECS[s]["range"] != "melee" for s in CLASSES[owner]["specs"] if s in SPECS)
    return False


def test_healing_reaches_40_m_and_most_ranged_abilities_do():
    ranged = []
    for ab in ABILITIES.values():
        if ab["target"] == "self":
            continue
        assert ab["range_m"] <= 40, f"{ab['id']} reaches {ab['range_m']} m, past the 40 m maximum"
        if ab["target"] == "ally" and (_effects(ab, "heal") or _effects(ab, "apply_aura")):
            assert ab["range_m"] == 40, f"{ab['id']} heals at {ab['range_m']} m"
        if ab["target"] == "enemy" and _ranged_owner(ab["owner"]):
            ranged.append(ab)  # a melee spec's gap closers and pulls are not what the rule is about
    at_40 = [ab for ab in ranged if ab["range_m"] == 40]
    assert len(at_40) * 3 >= len(ranged) * 2, f"only {len(at_40)} of {len(ranged)} ranged abilities reach 40 m"


AURAS = _load("auras")

# docs/DESIGN.md "Crowd control and diminishing returns": the break rule of each category.
BREAK_RULES = {
    "stun": {"never"},
    "incapacitate": {"any"},
    "disorient": {"threshold"},
    "silence": {"never"},
    "root": {"never", "threshold"},  # "after a damage threshold (on some roots)"
    "disarm": {"never"},
}


def test_crowd_control_auras_follow_their_category_break_rule():
    seen = set()
    for aura in AURAS.values():
        cat = aura["cc_category"]
        if cat in ("none", "knockback"):
            continue
        seen.add(cat)
        brk = aura.get("breaks_on_damage", "never")
        assert brk in BREAK_RULES[cat], f"{aura['id']} ({cat}) breaks on damage '{brk}'"
        if cat == "disorient":
            assert aura["damage_threshold_pct"] == 10, f"{aura['id']}: disorients break past 10% of max health"
        if brk == "threshold":
            assert 0 < aura["damage_threshold_pct"] <= 50, aura["id"]
    assert {"stun", "incapacitate", "disorient", "silence", "root"} <= seen
