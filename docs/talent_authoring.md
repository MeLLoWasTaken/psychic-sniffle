# Writing talent trees

How to write a class tree, a spec tree and a PvP talent row for one spec. The rules come from docs/DESIGN.md "Talent trees"; the mechanics from `game/core/talents.gd`; `tools/validate_data.py` checks everything below that can be checked.

## Files

| File | What |
| --- | --- |
| `data/talents/<class>_class.json` | Class tree, `kind: class`, `owner: <class id>`, 30 points, about 40 nodes |
| `data/talents/<spec>.json` | Spec tree, `kind: spec`, `owner: <spec id>`, 30 points, gates `[8, 20]`, about 40 nodes |
| `data/talents/<spec>_pvp.json` | PvP talents, `kind: pvp`, `owner: <spec id>`, `points: 3` (slots), exactly 12 nodes, no `pos`, no gates |
| `data/bots/<spec>.json` `builds` | At least three named builds the bots play; the first is the default |

Set `"status": "complete"` when a tree is finished: the validator then also checks point totals, gates, 12 PvP talents, and that every node has a description and an icon.

## Nodes

```json
{"id": "lingering_gash", "name": "Lingering Gash", "type": "passive", "ranks": 2, "pos": [3, 1],
 "requires_any": ["ruin_strike"], "gate": 0,
 "description": "Ruin Strike's bleed deals 90 more damage per tick per rank.",
 "icon": {"image": "lorc/ragged-wound", "school": "physical"},
 "effects": [{"modify": "ruin_bleed.periodic.effect.base", "per_rank": 90}]}
```

- `type`: `passive` (1 to 3 ranks), `active` (grants an ability, `grants_ability`), `choice` (two `choices`, each with `id`, `name`, `description`, `icon` and its own effects or grant; costs 1 point), `capstone` (behind the last gate).
- `pos`: `[column, row]`, columns 0 to 6, row 0 at the top. No two nodes share a position. Connections are drawn from `requires_any`, so a node's requirements should sit in rows above it.
- `requires_any`: node ids; the node unlocks when one of them is fully ranked. A top-row node either has no requirements or names an ability of the kit (it hangs off the action bar).
- `gate`: points that must be spent first, counting only nodes behind a lower gate. Spec trees use 8 and 20; capstones use 20. Class trees may use gates too.
- Descriptions state the exact change with numbers ("Break Free's cooldown is 15 s shorter"), the way tooltips read.

## Effects

Each effect changes one field of the player's own copy of an ability or aura, or the player:

| Effect | Meaning |
| --- | --- |
| `{"modify": "<ability or aura id>.<path>", "per_rank": x}` | add x per rank to a number (`effects.0.base`, `cooldown_s`, `cast_time_s`, `range_m`, `duration_s`, `periodic.effect.base`, `modifiers.0.value`, `cost.amount`, `pvp_modifier`, ...) |
| `{"modify": "<id>.<path>", "set": value}` | set a field to a value: a flag (`castable_while_moving: true`), a list (`effects` with an extra entry), a new field |
| `{"modify": "self.max_health" / "self.stats.haste" / "self.stats.crit_chance" / "self.stats.power_bonus" / "self.resource_max.<resource>", ...}` | the player's own numbers |
| node `grants_ability: "<ability id>"` | a new ability on the bar (an `active` node or a choice option) |
| node `grants_aura: "<aura id>"` | a permanent passive aura for the whole match (`duration_s: 0`, usually `hud_priority: hidden`); its `modifiers` give lasting changes such as `armor` (add), `damage_taken`, `healing_taken`, `move_speed`, `cooldown_rate` (multiply). Effects can then scale it per rank (`<aura>.modifiers.0.value`) |

Paths use field names and list indices exactly as in the data file. What talents cannot do yet: react to events ("after you Break Free, ..."), count stacks of other things, or change bot behavior. Stay within numbers, flags, extra ability effects, granted abilities and passive auras.

## A new ability from a talent

An `active` node's ability is an ordinary ability file with the same owner rules as the kit (owner: the class for class trees, the spec for spec trees; `kit_slot` as for the kit). It also needs:

- `data/effects/<id>.json`: its visual effect (see the existing files, or `"none": true` with a reason);
- an entry in `data/sound_map/default.json` under `abilities`, reusing existing sounds;
- an icon (below);
- a description whose numbers match the data (the validator recomputes them).

Keep actives few: two or three per tree.

## Class trees are shared

Every spec of a class uses its class tree (Warblade will have Carnage, Berserker and Bulwark). Most class nodes should therefore help any spec of the class: the player's own numbers, Break Free and other shared abilities, passive auras (armor, damage taken, movement, healing taken), and class abilities granted by the tree. A few nodes may improve one spec's kit, but no more than a quarter of the tree.

## PvP talents

Twelve arena-specific effects, three slots: shorter or longer crowd control, anti-healing, dispel protection, interrupt or Break Free tweaks, counters to specific threats. Each should change how a match is played, not just add numbers.

## Balance

- Health is 60,000 (tanks 72,000). A core ability hits for 3,000 to 8,000; a full rank of a passive should be worth roughly 2 to 4% of the spec's damage, healing or survival.
- Capstones are worth about three ordinary points.
- Each spec tree needs at least three viable builds: three distinct ways to spend 30 points (for example burst, sustained and control). The bot builds in `data/bots/<spec>.json` encode them; bot simulations must give each 40 to 60% win rate, and no node may be taken by more than 90% of the top builds.

## Names and icons

- Original names only: no names, phrases or lore from World of Warcraft or any other game.
- Icons are game-icons.net glyphs (CC BY 3.0 or CC0 authors listed in `AUTHORS` in `tools/build_icons.py`). Pick from a checkout of github.com/game-icons/icons, copy the SVG to `game/assets/icons/game-icons/<author>/<name>.svg`, then run `python3 tools/build_icons.py` to render glyphs and update the attribution. No two abilities of one spec share a glyph; talent nodes may reuse an ability's glyph only when the talent changes that ability.
