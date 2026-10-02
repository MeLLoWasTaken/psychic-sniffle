"""Balance simulation analysis (tools/sim/analyze_batch.py, tools/sim/nightly.py): talent build
win rates, viability and the shared-node check of backlog M2-04, on synthetic reports."""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "sim"))
import analyze_batch  # noqa: E402
import nightly  # noqa: E402


def _match(a_build: str, b_build: str, winner: int) -> dict:
    return {"winner": winner, "end_reason": "team_eliminated", "seconds": 90.0, "errors": 0,
            "units": {"1": {"spec": "warblade_carnage", "build": a_build, "team": 0},
                      "2": {"spec": "oracle_grace", "build": b_build, "team": 1}}}


def test_build_win_rates_viability_and_the_shared_node_check():
    ms = []
    # four warblade builds against one oracle build; w1 wins 50%, w2 45%, w3 55%, w4 never
    for build, wins in (("w1", 15), ("w2", 14), ("w3", 17), ("w4", 0)):
        ms += [_match(build, "o1", 0) for _ in range(wins)] + [_match(build, "o1", 1) for _ in range(31 - wins)]
    nodes = {"warblade_carnage@w1": ["core", "a", "pvp:p1"], "warblade_carnage@w2": ["core:2", "b", "pvp:p2"],
             "warblade_carnage@w3": ["core", "c", "pvp:p3"], "warblade_carnage@w4": ["d"], "oracle_grace@o1": ["x"]}
    report = {"matches": ms, "summary": {"builds": {k: {"nodes": v} for k, v in nodes.items()}}}
    b = analyze_batch.summarise(report)["builds"]["warblade_carnage"]
    assert b["viable"] == 3
    assert b["builds"]["warblade_carnage@w4"]["win_rate"] == 0.0
    assert set(b["top"]) == {"warblade_carnage@w1", "warblade_carnage@w2", "warblade_carnage@w3"}
    # every top build takes "core" (whatever the rank; PvP talents count apart), but so do three of
    # the four builds: three of three by chance is likely, so it is common, not favoured
    assert b["over_share"] == {}
    assert b["common"] == {"core": 1.0}
    assert b["top_node_share"] == 1.0
    assert b["all_share"]["core"] == 0.75


def test_a_node_only_the_top_builds_take_is_favoured():
    ms, nodes = [], {"oracle_grace@o1": ["x"]}
    for i in range(12):  # twelve builds; the six best take "edge", all take "base"
        wins = 20 - i
        ms += [_match(f"w{i}", "o1", 0) for _ in range(wins)] + [_match(f"w{i}", "o1", 1) for _ in range(31 - wins)]
        nodes[f"warblade_carnage@w{i}"] = ["base"] + (["edge"] if i < 6 else [])
    report = {"matches": ms, "summary": {"builds": {k: {"nodes": v} for k, v in nodes.items()}}}
    b = analyze_batch.summarise(report)["builds"]["warblade_carnage"]
    assert b["over_share"] == {"edge": 1.0}  # 6 of 6 against a 50% share: 1.6% by chance
    assert b["common"] == {"base": 1.0}


def test_build_compositions_give_every_unit_a_build_of_its_spec():
    cs = nightly.build_comps(2, 30, 4, seed=3)
    assert len(cs) == 30
    for c in cs:
        for side in c.split(":"):
            for unit in side.split("+"):
                spec, build = unit.split("@")
                assert build in nightly.build_names(spec, 4)
    assert nightly.build_comps(2, 30, 4, seed=3) == cs  # the same seed, the same matches


def test_the_report_names_mirror_kill_rates(tmp_path, capsys):
    ms = [_match("w1", "o1", 0) for _ in range(4)]
    mirror = {"winner": -1, "end_reason": "time_limit", "seconds": 720.0, "errors": 0,
              "units": {"1": {"spec": "oracle_grace", "build": "o1", "team": 0},
                        "2": {"spec": "oracle_grace", "build": "o1", "team": 1}}}
    ms += [mirror, mirror]
    nightly.report_bracket(1, {"matches": ms, "summary": {"builds": {}}}, tmp_path)
    line = next(ln for ln in capsys.readouterr().out.splitlines() if "mirrors::" in ln)
    assert "kills 0/2, draws 2" in line
