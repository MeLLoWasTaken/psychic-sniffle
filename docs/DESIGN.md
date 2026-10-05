# Arena PvP Game — Design Document

Source of truth: the living Claude Docs version (https://claude.ai/code/artifact/62e1d8a4-6826-4e23-a252-0f15cb34c58a). This file is a snapshot taken 2026-09-28. If the two differ, ask the human which one wins, then update this file.

## How to use this document

You are the implementing model. Build the game described here in small, verified increments, following the loop in "The iterative build loop". Never try to build the whole game in one pass.

**Rules for the implementing model**

1. Treat this document as the source of truth. It lives in the repo as `docs/DESIGN.md`.
2. Keep four living files in the repo root: `BACKLOG.md` (ordered work items with acceptance criteria), `DECISIONS.md` (every choice not specified here, with a one-line reason), `CHANGELOG.md` (one entry per loop iteration), and `KNOWN_ISSUES.md`.
3. When this document is silent, make the simplest choice that fits the pillars, record it in `DECISIONS.md`, and keep going. Stop and ask the human only for choices that are expensive to reverse (engine, network model, art style changes).
4. Everything gameplay-related is data-driven. Classes, abilities, talents, maps and tuning numbers live in data files, not in code branches per class.
5. Every change must pass the automated checks in "Testing and quality gates" before it is committed.
6. Look at your own output. Render screenshots of models, scenes and UI and inspect them before marking visual work done.
7. **Original IP only.** The game is inspired by World of Warcraft's feel and PvP structure. Do not use Blizzard names, lore, factions, zone names, ability names, icons, logos or assets. All names in this document are original placeholders and may be renamed.

**Glossary for non-specialists**

- *DPS*: damage-dealing role. *Healer*: restores allies' health. *Tank*: absorbs damage and controls enemies.
- *GCD (global cooldown)*: a short lockout after most abilities, which sets the pace of combat.
- *CC (crowd control)*: effects that remove control from a player, such as stuns or fears.
- *DR (diminishing returns)*: repeated CC of the same type lasts shorter each time.
- *Server-authoritative*: the server decides what really happened; clients only predict and display.
- *Headless Blender*: Blender run from the command line with Python scripts and no window.

## Vision, pillars and non-goals

A PC game of competitive fantasy PvP: arena matches of 1v1, 2v2 and 3v3, and 10v10 battlegrounds, with the class depth, pacing and readability of classic MMO PvP and a darker, harsher look.

**Pillars** (use these to settle any design question)

1. **Skill decides the match.** All players have equal stats. No gear grind, no pay-to-win. Rewards are cosmetic.
2. **Readable chaos.** In a fight with 20 players and dozens of effects, a player can always tell who is casting what, who is controlled, and who is in danger.
3. **Every spec has a job.** Each specialization has a clear role (DPS, healer or tank), a distinct playstyle, and real counterplay against it.
4. **Responsive controls.** Inputs feel instant under 150 ms of latency. Keybinds and the interface are fully customizable.
5. **Stylized, heavy, grim.** Chunky hand-painted fantasy shapes, darker palettes, visible wear, and spell effects that hit hard.

**Non-goals** (do not build these)

- No open world, questing, leveling, raids or dungeons.
- No gear with stats, no auction house, no crafting.
- No mobile or console versions at launch.
- No real-money shop in scope.

## Scope and milestone plan

Build a small, complete game first (the vertical slice), then widen it. A phase is finished only when its exit gate passes. Each phase builds on the one before it.

| Phase | Builds | Exit gate |
| --- | --- | --- |
| M0 Foundations | Repo, Godot project, headless server, data schemas, bot harness, automated checks | Two bots join a server, move, target and auto-attack for 5 minutes with no errors |
| **M1 Vertical slice: 2v2 arena** | 3 specs (melee, caster, healer), 1 arena, combat core, basic HUD, first Blender characters | A full 2v2 match plays start to finish with humans or bots, at 60 fps |
| M2 Combat depth and settings | Full CC and DR, talent trees, 1v1 and 3v3, 2 more arenas, keybinding and UI edit mode | Every combat rule has passing tests; every action is rebindable; UI layouts save and load |
| M3 Class waves | The other 10 classes in waves of 3 or 4, each with models, animations, effects, sounds | Per wave: each new spec wins 40 to 60% in bot simulations and passes the art checklist |
| M4 Battlegrounds: 10v10 | Capture-the-flag map, resource-control map, raid frames, scoreboard, minimap, bot fill | A 20-player match holds 60 fps on the target PC and the server stays within its tick budget |
| M5 Polish and balance | Art and audio pass, lighting, rated matchmaking, accessibility options, performance work | Quality bar met on every screen; no spec outside 45 to 55% win rate in simulated rated play |

The slice uses three specs chosen to test the three hardest systems: Warblade Carnage (melee, rage), Arcanist Rime (casting, interrupts, roots) and Oracle Grace (healing, dispels). Class waves in M3 should each include at least one healer or tank so role coverage grows evenly.

## Technical architecture

Use Godot 4 (4.7.2 stable, or the latest 4.7 patch) with statically typed GDScript, a dedicated headless server, and all gameplay rules in one shared library. Godot fits a model-driven build: scenes and resources are plain text, the editor is scriptable from the command line, it runs headless on a server, and it imports Blender's glTF output directly.

**Why Godot rather than Unreal or Unity.** Unreal 5 has the highest visual ceiling, but its best features (Nanite, Lumen, photoreal humans) serve realistic art, not this stylized look. Its assets are binary files a model cannot read or edit as text, and it needs a GPU workstation and an Epic account to run. Unity has similar limits on binary assets and editor-only workflows. The loop in this document depends on the model building, running, testing and screenshotting the game every cycle, and Godot 4.7 is the only one of the three that supports all of that from text files on a headless Linux machine. Godot's Forward+ renderer covers everything the art direction needs: global illumination, volumetric fog, bloom, ambient occlusion and custom shaders. Decided 2026-09-28.

**Architecture at a glance** (the server decides every outcome; clients predict and draw)

```
 Blender (headless) --models (.glb)--> Game client (Godot)            Server (Godot, headless)
                                       - input and keybinds           - simulation at 60 Hz
                                       - movement prediction          - range and sight checks
                                       - models, effects, audio       - match state, scoring
                                       - HUD and settings             - snapshot sender
                                              |  player inputs  -->          ^
                                              |  <-- world snapshots, 60 Hz  |
                                              +------ shared rules library --+   (combat math, auras, CC, DR;
                                                      ^                          same code on both sides)
                                                      |
                                               game data (JSON): abilities, talents, maps
                                                                          Matchmaker service --starts a match--> Server
```

**Networking**

- Server-authoritative. Clients send inputs; the server simulates at 60 ticks per second and sends delta-compressed snapshots at 60 Hz.
- Transport: ENet through Godot's `ENetMultiplayerPeer`. Movement snapshots go unreliable-sequenced; ability events, deaths and match events go reliable.
- Clients predict their own movement and reconcile against snapshots. Other players are drawn about 50 ms (3 ticks) in the past with interpolation.
- Ability presses are sent immediately; the client may start the cast bar and animation at once, but damage, healing and effects appear only when the server confirms.
- Hit, range and line-of-sight checks run on the server with a lag allowance of up to 200 ms.
- Target: playable at 150 ms latency and 2% packet loss.

**Project layout**

```
/game        Godot project (client + server export presets)
/game/core   shared rules library: stats, abilities, auras, CC, DR
/game/net    protocol, prediction, snapshots
/game/ui     HUD, frames, settings, edit mode
/data        JSON: classes, specs, abilities, talents, maps, tuning
/tools/blender  headless generation scripts, one per asset family
/tools/sim   bot framework and batch match simulator
/tests       unit, integration and screenshot tests
/docs        DESIGN.md, art bible, audio bible
```

**Other services**

- Matchmaker: a small standalone service (Python or Go) with SQLite during development and PostgreSQL later. It queues players, computes ratings and launches server instances.
- Bots: headless clients that speak the same protocol as players. They fill empty slots during development and power balance simulations.
- Accounts and anti-cheat beyond server authority are out of scope until M5.

## Core combat system

Combat is tab-target and ability-driven: players pick a target, press abilities on a global cooldown, and win by chaining damage and crowd control while their healer keeps them alive. All numbers below are starting values and live in `/data/tuning.json`.

**Pacing and casting**

- Global cooldown (GCD): 1.5 s, reduced by haste to a floor of 0.75 s. Energy-based specs use a fixed 1.0 s GCD.
- Spell queue window: 400 ms by default (player-adjustable from 0 to 400 ms). A press inside the window fires the moment the GCD ends.
- Abilities are instant, cast (a bar fills, movement cancels it) or channeled (effect ticks during the bar). An ability flagged `castable_while_moving` ignores the movement rule.
- Interrupts end a cast and lock that spell school (fire, frost, holy, and so on) for 3 to 4 s. Interrupt abilities have 15 to 24 s cooldowns.
- Movement: 7 m/s run speed, jumping, strafing, mouse steering. Only the strongest slow applies.

**Stats and damage**

- Every spec uses a fixed stat template from data. There is no gear. Health starts at 60,000 for DPS and healers and 72,000 for tanks.
- Damage = base × (1 + power bonus) × critical multiplier (1.5) × armor or resistance reduction × target modifiers × PvP modifier.
- Physical reduction by armor type: cloth 10%, leather 20%, mail 25%, plate 30%.
- Each ability carries a `pvp_modifier` so it can be tuned for arena without touching its base.

**Resources**

| Resource | Behavior | Used by |
| --- | --- | --- |
| Mana | Large pool, slow regeneration; spending it well matters for healers | Healers, casters, hybrids |
| Rage | Builds from dealing and taking damage, decays out of combat | Warblade |
| Energy + combo points | Fast regeneration; builders add points, finishers spend them | Shade, Feral Wildkin |
| Focus | Medium regeneration, spent on shots | Stalker |
| Runes + runic power | Six recharging runes; spending them builds a second resource | Deathsworn |
| Fury | Builds from attacks, spent on burst | Felhunter |
| Essence | A few charges that refill over time | Scalebinder |

**Crowd control and diminishing returns**

Each CC effect belongs to one category. Repeated CC in the same category lasts 100%, then 50%, then 25%, then the target is immune. The count resets 18 s after the last CC in that category ends.

| Category | Examples | Breaks on damage |
| --- | --- | --- |
| Stun | Charge stun, hammer stun | No |
| Incapacitate | Transform into a harmless beast, sap | Yes, any damage |
| Disorient | Fear, horror | After a damage threshold (10% of max health) |
| Silence | Spell lock | No |
| Root | Ice freezes the feet | After a damage threshold (on some roots) |
| Disarm | Weapon knocked away | No |
| Knockback | Push away | No DR, no category |

- Maximum duration of any single CC in PvP: 8 s.
- Every player has **Break Free**, which removes all CC and has a 90 s cooldown.
- Dispels remove effects by type: magic, curse, poison, disease. Offensive dispels strip one magic buff.

**Targeting and line of sight**

- Targets: current target, focus target, mouseover, self, arena enemies 1 to 3, party members 1 to 4. Each keybind can set which target an action uses, which replaces the need for macros.
- Line of sight: a ray from the caster's eye to the target's chest against the `los_blocker` collision layer. It is checked when a cast starts and when it finishes.
- Ranges: melee 5 m, most ranged abilities 40 m, healing 40 m.

**Arena rules**

- 60 s preparation phase behind closed gates, then the gates open.
- Dampening: from 3:00 of match time, all healing and new shields are reduced by 1% every 10 s, up to 100%. In 1v1, dampening is 10% when the gates open and grows 1% every 2 s, reaching 100% at 3:00, so a duel is decided rather than outlasted (changed 2026-10-03 by the human's decision: duels are balanced through dampening, leaving every kit untouched).
- A match ends when one team is fully dead, or at 20:00 as a draw.

## Classes and specializations

The full roster is 13 classes and 39 specializations: 26 DPS (one of them a support DPS), 7 healers and 6 tanks. Each class covers a familiar fantasy archetype under an original name.

| Class | Armor | Spec | Role | Playstyle |
| --- | --- | --- | --- | --- |
| Warblade | Plate | Carnage | DPS, melee | Two-handed weapon, huge single hits, execute on low-health targets |
| Warblade | Plate | Berserker | DPS, melee | Two weapons, sustained frenzy, heals itself through damage |
| Warblade | Plate | Bulwark | Tank | Shield, reflects spells, leaps to protect allies |
| Templar | Plate | Radiance | Healer | Strong single-target heals, short full immunity, can fight in melee |
| Templar | Plate | Vanguard | Tank | Holy damage around itself, protective blessings on allies |
| Templar | Plate | Zealot | DPS, melee | Burst windows, stuns, emergency heals on allies |
| Stalker | Mail | Beastbond | DPS, ranged | Pet deals much of the damage and carries its own CC |
| Stalker | Mail | Deadeye | DPS, ranged | Long cast shots, largest single burst at range |
| Stalker | Mail | Trapper | DPS, melee | Spear, traps, bleeds, pet support |
| Shade | Leather | Venom | DPS, melee | Poisons and bleeds, longest CC chains from stealth |
| Shade | Leather | Duelist | DPS, melee | Sustained damage, parries, pistol shots |
| Shade | Leather | Nightblade | DPS, melee | Stealth openers, shadow-step behind targets, big burst |
| Oracle | Cloth | Absolution | Healer | Absorb shields, turns its damage into healing |
| Oracle | Cloth | Grace | Healer | Direct and area healing, fear, strong dispels |
| Oracle | Cloth | Void | DPS, ranged | Damage over time, builds to a shadow burst, silences |
| Deathsworn | Plate | Frostgrave | DPS, melee | Frost burst, heavy slows |
| Deathsworn | Plate | Plague | DPS, melee | Diseases and undead minions |
| Deathsworn | Plate | Bloodbound | Tank | Heals from its own damage, pulls enemies to it |
| Stormcaller | Mail | Tempest | DPS, ranged | Lightning and lava casts, knockbacks |
| Stormcaller | Mail | Primal | DPS, melee | Elementally charged weapons, spirit wolves |
| Stormcaller | Mail | Tidesinger | Healer | Totems, bouncing heals, purges |
| Arcanist | Cloth | Rime | DPS, ranged | Frost control: roots, freezes, shatter combos |
| Arcanist | Cloth | Pyre | DPS, ranged | Fire damage over time and critical-hit streaks |
| Arcanist | Cloth | Aether | DPS, ranged | Mana-fueled burst, blink, counterspell |
| Occultist | Cloth | Blight | DPS, ranged | Curses and damage over time, fear |
| Occultist | Cloth | Summoner | DPS, ranged | Commands demons that fight and control |
| Occultist | Cloth | Ruin | DPS, ranged | Slow, massive casted nukes |
| Wildkin | Leather | Moonfury | DPS, ranged | Sun and moon casts, shapeshifts out of roots |
| Wildkin | Leather | Feral | DPS, melee | Cat form, stealth, bleeds |
| Wildkin | Leather | Ursine | Tank | Bear form, huge health, self-healing |
| Wildkin | Leather | Grove | Healer | Heals over time, high mobility, roots enemies |
| Ascetic | Leather | Stonewall | Tank | Delays damage taken and spreads it over time |
| Ascetic | Leather | Jade | Healer | Channeled and melee-driven healing |
| Ascetic | Leather | Windstrike | DPS, melee | Fast combos, rolls, flying kicks |
| Felhunter | Leather | Ravager | DPS, melee | Highest mobility, glides, burst transformation |
| Felhunter | Leather | Warden | Tank | Ground sigils for AoE control and self-healing |
| Scalebinder | Mail | Cinder | DPS, ranged | Charged breath attacks, released at chosen power |
| Scalebinder | Mail | Chrono | Healer | Rewinds recent damage, heals ahead of time |
| Scalebinder | Mail | Kindle | Support DPS | Moderate damage, strong buffs on allies |

**Ability kit template** (every spec must fill these slots; 14 to 18 abilities on the bars)

| Slot | Count | Purpose |
| --- | --- | --- |
| Core rotation | 4 to 6 | Builders, spenders or main heals |
| Burst or big cooldown | 1 to 2 | A 1 to 3 minute window the enemy must respond to |
| Crowd control | 2 to 3 | At least two different CC categories |
| Interrupt | 1 | All DPS and tanks; healers get a weaker or longer-cooldown one |
| Defensives | 2 to 3 | Personal damage reduction, immunity or escape |
| Mobility | 1 to 2 | Dash, blink, charge or teleport |
| Utility | 1 to 2 | Dispel, purge, slow, knockback or team buff |

**Counterplay rules**

- Every strong effect must be visible: a distinct animation, sound and icon on enemy frames.
- Every burst window must be answerable by at least two tools (interrupt, CC, defensive, line of sight).
- No spec may have more than one full immunity.

## Talent trees

Each spec has three talent layers: a class tree shared by all specs of the class, a spec tree, and a row of PvP talents. There is no leveling, so every player has all points from the start and can change talents freely outside a match.

| Layer | Nodes | Points to spend | Notes |
| --- | --- | --- | --- |
| Class tree | About 40 | 30 | Shared by the class's specs; utility, defensives, mobility |
| Spec tree | About 40 | 30 | Shapes the rotation and burst; gates at 8 and 20 points spent |
| PvP talents | 12 per spec | 3 slots | Arena-specific effects, such as shorter CC or anti-healing |

**Node types**

- *Passive*: changes numbers or behavior (1 to 3 ranks).
- *Active*: grants a new ability on the action bar.
- *Choice*: pick one of two options in the same node.
- *Capstone*: a large effect at the bottom of the tree, behind the 20-point gate.

**Rules**

- A node unlocks when at least one node connected above it is fully ranked, and the tree's gate has been reached.
- Each spec tree must offer at least three viable builds, and no single node may be taken by more than 90% of simulated top players.
- Players save up to 10 loadouts per spec. A loadout exports to a short text string for sharing.
- Talents lock when the arena gates open or the battleground starts.

**Data format** (one file per tree in `/data/talents/`)

```json
{
  "tree_id": "warblade_carnage",
  "points": 30,
  "gates": [8, 20],
  "nodes": [
    {
      "id": "lingering_gash",
      "type": "passive",
      "ranks": 2,
      "pos": [3, 1],
      "requires_any": ["ruin_strike"],
      "effects": [{"modify": "ruin_strike.bleed_damage", "per_rank": 0.15}]
    }
  ]
}
```

The talent screen draws itself from this data: node position, connecting lines, icons, tooltips and point counters. A validation script must reject trees with unreachable nodes, broken references or the wrong point totals.

## Game modes

There are three arena brackets and two battlegrounds at launch, each with an unrated and a rated queue.

| Mode | Team size | Win condition | Time limit | Maps at launch |
| --- | --- | --- | --- | --- |
| Arena 1v1 | 1 | Kill the opponent | 12 min | 2 small arenas |
| Arena 2v2 | 2 | Kill the enemy team | 20 min | 4 arenas |
| Arena 3v3 | 3 | Kill the enemy team | 20 min | 4 arenas |
| Capture the flag | 10 | First to 3 captures | 20 min, then most captures | 1 map |
| Resource control | 10 | First to 1,500 points from 5 held nodes | 25 min | 1 map |

**Arena maps**

- About 40 m across, with 3 to 5 pillars or walls for breaking line of sight, and two opposing starting rooms.
- Each map has one twist: a collapsing bridge, a rotating obstacle, a mid-match water flood, or a shrinking safe zone.
- Health and mana regeneration pickups spawn once, at 1:30, in 1v1 and 2v2.

**Battleground rules**

- Dead players respawn in waves every 30 s at a graveyard.
- The flag carrier takes 10% more damage per 45 s holding the flag, which prevents stalling.
- Matchmaking aims for 1 tank and 2 to 3 healers per team.
- Bots fill empty slots in unrated battlegrounds so matches start without waiting.

**Matchmaking and rating**

- Each bracket has its own rating using Glicko-2, a rating system that also tracks how certain it is about a player's skill.
- New players start at 1500 with high uncertainty, so early games move their rating quickly.
- The matchmaker widens the allowed rating gap by 50 points every 30 s of queue time.
- Visible tiers (for example Iron, Bronze, Silver, Gold, Obsidian, Champion) are cosmetic labels on top of rating; the tier names are placeholders.
- Seasons last about 12 weeks and reward cosmetic items, titles and weapon effects.

## Art direction

Stylized, hand-painted fantasy with heroic, slightly exaggerated proportions and dense surface detail, pushed darker: lower saturation in the world, harsh rim lighting, scars and wear, and saturated color reserved for spells and team markers.

**Shapes and proportions**

- Characters are about 7.5 heads tall. Hands, feet and shoulders are about 10% larger than realistic, not more. Silhouettes must be readable at 30 m. (Changed 2026-10-03 by the human, from 7 heads with oversized hands, feet and shoulders, for a less exaggerated look.)
- Plate is massive and angular with spikes, rivets and dents. Leather is layered and strapped. Cloth hangs heavy with torn hems.
- Weapons are 10 to 25% larger than realistic.
- Detail is modelled, not only painted: plate has bevelled edges, rolled rims, rivets and engraving; mail, quilting, stitching and leather grain are baked into normal maps.
- The Templar is a crusading knight: a flat-topped great helm with an eye slit and breaths, mail under plate, and a long surcoat or tabard with the order's sun emblem.

**Color and surface**

- Textures are painted-look: base color with baked light from above, darkened crevices (ambient occlusion) and lightened edges. No photo textures and no fine noise.
- Environments use muted stone, iron, bone and dark wood. Accent colors come only from spells, banners, fire and magical light.
- Team colors: one team crimson, the other steel blue, visible on banners, cloaks and nameplates.

**The edgier tone, in concrete terms**

- Darker ambient light and deeper shadows than a bright, friendly fantasy style.
- Visible battle damage: chipped armor, dried blood on weapons (no gore), bandages.
- Harsher facial features: heavier brows, scars, war paint.
- Arenas set in grim places: a gallows courtyard, a flooded crypt, a burning foundry, a bone-strewn colosseum.

**Spell color language** (the same color always means the same school)

| School | Colors | Shape language |
| --- | --- | --- |
| Fire | Orange, deep red | Rising flames, embers |
| Frost | Pale cyan, white | Sharp crystals, mist |
| Shadow | Violet, black | Smoke tendrils, inward pull |
| Holy | Gold, warm white | Rays, rings, runes |
| Nature | Green, amber | Leaves, vines, spirals |
| Storm | Electric blue | Forked arcs, flashes |
| Blood and plague | Dark red, sickly green | Drips, clouds |
| Fel and demonic | Acid green | Jagged flames |
| Time | Bronze, teal | Clock-like rings, afterimages |

**Budgets** (changed 2026-10-04 by the human: "the budget and graphical fidelity should approach" a current top-tier stylized MMO; this replaced 40,000 to 60,000 triangles per character, props of 500 to 5,000 triangles and arenas under 1.5 million visible triangles)

The extra triangles are for modelled detail that reads in play (rolled and bevelled plate edges, overlapping lames, rivets and buckles, straps, cloth folds, individual stones and chipped edges), not for smoothing flat surfaces.

- Characters: 100,000 to 150,000 triangles at LOD0 for an assembled character wearing every slot (body, head, hair and every armor piece), weapons not counted. Shares: body with head about 30,000 (the head and hands kept densest); hair 6,000 to 16,000; beards 2,000 to 6,000; chest 24,000; head 12,000; legs 12,000; shoulders 10,000; hands 8,000; back 8,000; feet 6,000; waist 3,000; an off-hand shield about 6,000.
- Weapons: 8,000 to 20,000 triangles.
- Character textures: 4096 px sets (base color, normal map, roughness and the dye mask at half size) for the body with head, the chest, legs and head pieces; 2048 px for the other pieces, hair and weapons. Pieces of one set share their textures across every character wearing them; dyes and skin tones are shader parameters, not texture copies.
- LODs at 50%, 25% and 10%, switched by screen size. A Model detail setting (in the graphics presets) raises the switching threshold so Low and Medium drop to lower LODs sooner. Texture memory is checked on the minimum PC once a GPU machine is available; if it does not fit, Low gets half-size texture imports.
- Environment kit pieces (walls, floors, pillars, stairs, gates): 5,000 to 25,000 triangles. Props: 2,000 to 20,000. Hero pieces (a gatehouse, the gallows, a furnace, a tomb): 30,000 to 80,000.
- Environment textures: tiling materials at 2048 px per surface type (stone, wood, iron, plaster) with normal and roughness maps, plus 4096 px unique bakes for hero pieces; dirt, moss and soot blended by vertex color or a mask.
- An arena map: under 6 million visible triangles at full detail, with automatic LODs and occlusion culling. A battleground map: under 10 million.

**Appearance and armor customization** (added 2026-10-03 by the human)

- Appearance is cosmetic only and never changes stats or hit boxes.
- Character creator: body type (two, male and female, both available to every class), height within ±4%, face (at least 6 presets), skin tone (at least 8), hair style (at least 6, hidden under helms) and hair color, beard (male body type), eye color, scars and war paint. No races: one people.
- Armor has eight slots: head, shoulders, chest, hands, waist, legs, feet and back (cape). The chest slot includes any surcoat or tabard. Every piece belongs to one armor type (cloth, leather, mail, plate), and a character can wear any piece of its class's armor type, mixed freely. Each class has at least one complete set as its default look, and each piece can be hidden except chest, legs and feet.
- Dyes: each piece has primary, secondary and metal channels chosen from a fixed palette.
- In matches, team color overrides the back slot and the tabard's primary channel, so teams stay readable. Because pieces mix within an armor type, a class is no longer always readable from armor alone: the weapon, the nameplate's class color and class icon, and spell colors identify the class.
- Appearance lives in the player's profile and is sent to the match server when joining; the server passes it to every client.

The art rules live in `docs/ART_BIBLE.md`, with reference renders added as they are approved.

## Asset pipeline: headless Blender

Every 3D asset is built by a Python script run in Blender without a window, from a JSON spec and a random seed, so any asset can be rebuilt, varied or improved by editing text. Scripts output `.glb` files that Godot imports directly, plus preview renders the model must inspect.

**Command shape**

```
blender -b -P tools/blender/build_character.py -- \
  --spec data/assets/warblade_carnage.json --seed 7 \
  --out game/assets/characters/warblade_carnage.glb \
  --previews previews/warblade_carnage/
```

In the cloud workspace, Blender is installed as the `bpy` Python module (Blender 4.5 LTS), so the equivalent is `python3 tools/blender/build_character.py --spec ...`.

**Characters**

1. *Body*: a parametric humanoid built from a vertex skeleton with the Skin modifier, then smoothed and remeshed. Two builds to start (heavy and lean), with sliders for height, shoulder width and limb thickness.
2. *Armor and weapons*: kitbashed from primitives with bevel, solidify, array, boolean and Geometry Nodes for spikes, rivets and trims. Armor is built as separate pieces per slot and per body type, each its own exported mesh, so the game assembles any mix (see Appearance and armor customization). Each class has its own default set; each spec varies color, trim and weapon.
3. *Rig*: one standard skeleton with fixed bone names for every humanoid. Body skin uses automatic weights; armor pieces are rigidly parented to single bones to avoid stretching.
4. *Animation*: keyframed by script from pose data, shared across all humanoids. Required set: idle, combat idle, run, strafe left and right, backpedal, jump, cast start, cast loop, cast release (per school), channel, 3 melee attacks, ranged shot, hit reaction, stunned, feared run, death, victory.
5. *Textures*: procedural materials baked into base color maps (sizes under Budgets) with light from above, darkened crevices and highlighted edges, which gives the hand-painted look. Also bake a normal map carrying fine modelled detail from a higher-resolution version (engraving, mail, stitching, dents), a roughness map, and dye masks. The higher-resolution version's curvature is painted into the base color too (hollows darker, ridges lighter), so modelled detail reads under flat or distant light.
6. *LODs*: three lower-detail versions at 50%, 25% and 10% of the triangles.

**Environments**

- A modular kit per arena theme: walls, pillars, floors, stairs, gates, braziers, banners, debris.
- Each kit piece is built from a dense, sculpted version (stones chipped at the edges and worn at the corners, timber grained and split, iron dented) reduced to its budget, with normal, roughness and color maps baked from the dense version (added 2026-10-04 with the new budgets).
- Maps are assembled in Godot scenes from kit pieces, with line-of-sight blockers on their own collision layer.

**Icons**

The game needs over 1,000 icons (abilities, talents, buffs). An icon generator renders a small Blender scene per icon (school color, symbol mesh, lighting preset) to 128 px, then adds a painted frame. Icons are described in the ability data, so a new ability gets its icon automatically.

**Validation** (a script that runs on every asset before commit)

- Triangle counts within budget; 1 Blender unit = 1 m; origin at the feet; character faces -Y in Blender (Blender's front view; the glTF exporter converts axes).
- Standard bone names present; every required animation present and named.
- No non-manifold geometry, no missing textures, texture sizes are powers of two.

**Preview renders** (the model must look at these before calling an asset done)

- A contact sheet with front, side, back and three-quarter views, plus the model in its idle, cast and attack poses.
- A lineup render placing the new character next to two approved ones, to check scale and style consistency.
- Renders use Eevee with the game's lighting preset, saved to `/previews`. Without a GPU, Eevee takes about 100 s per image (mostly shader compilation); Cycles on the CPU takes about 15 s and is an acceptable substitute for quick checks.

## Visual effects, lighting and audio

Effects and sound must feel powerful and stay readable: every ability has a distinct look and sound per stage, and the most dangerous enemy actions are always the easiest to notice.

**Spell effects**

- Each ability defines up to five effect stages in data: cast (glow on hands or weapon), projectile, impact, aura (lasting effect on the target) and ground effect.
- Built from Godot GPU particles, trail meshes, ground decals and custom shaders: dissolve, glowing edges (fresnel), scrolling noise, heat distortion.
- Enemy ground effects have a red-tinted outline; allied ones do not.
- Players can lower the opacity of other players' effects and turn off camera shake.
- Floating combat numbers for damage and healing, with larger text for critical hits.

**Lighting and post-processing**

- Arenas use baked lighting (Godot's LightmapGI) for the static scene, plus a limited number of dynamic lights from spells (cap: 16 visible at once).
- Post-processing: bloom, screen-space ambient occlusion, volumetric fog, a filmic tonemapper and a color grade per map.
- Every map ships with a lighting preset that the Blender preview renders also use, so previews match the game.

**Audio**

- Buses: Master, Music, Ambience, Effects (split into self, allies and enemies), Interface, Voice. Each has its own volume slider.
- Each ability has sounds for cast start, cast loop, release, impact and aura loop, matching its effect stages.
- 3D positional sound with distance falloff. A priority system caps simultaneous sounds at 64; enemy crowd control and burst cooldowns are never dropped.
- A distinct warning sound plays when an enemy starts a crowd control cast on you.
- Sound source (decide in M0): effects synthesized by Python scripts (layered noise, tones, filter sweeps and impacts) as the default, with optional CC0 sample libraries for realism. Music from licensed or CC0 tracks, or composed separately.

The audio rules live in `docs/AUDIO_BIBLE.md`.

## Interface, HUD and settings

Every interface element can be moved, resized and toggled in an edit mode, and every action can be rebound. Both are saved as named profiles that can be exported to a text string and shared.

**HUD elements**

- Action bars: up to 6 bars of 12 buttons, each bar with its own size, spacing, rows and visibility rules.
- Unit frames: player, target, target of target, focus, party (2 to 5), arena enemies 1 to 3, and raid frames for battlegrounds (up to 10).
- Arena enemy frames show health, resource, cast bar, spec icon, Break Free cooldown and a diminishing-returns tracker per CC category.
- Cast bars: player, target, focus and arena enemies. Interruptible casts and uninterruptible casts look different.
- Buffs and debuffs, with CC and major defensives shown larger and a big CC icon on the frame of any controlled ally.
- Nameplates over characters, with class color, health, cast bar and important debuffs.
- Also: team scoreboard, battleground minimap and objective tracker, match timer and dampening percentage, combat text, chat, and a loss-of-control alert in the screen center.

**Edit mode**

- A toggle that shows every element with a labeled outline. Drag to move, snap to a grid, scale from 50 to 200%, change opacity, and set per-element options.
- Layout profiles are separate for each spec if the player wants.

**Settings suite**

| Page | Settings |
| --- | --- |
| Keybinding | Every action, bar button and interface toggle; modifier keys (Shift, Ctrl, Alt); mouse buttons 1 to 5 and wheel; target mode per bind (target, focus, mouseover, self, arena 1 to 3); conflict warning; reset to default; import and export |
| Interface | Edit mode, global scale, font size, nameplate options, buff sizes, combat text options, tooltip position |
| Gameplay | Spell queue window, auto self-cast, target selection rules, camera distance and speed, mouse sensitivity, invert axis, click-to-target behavior |
| Graphics | Resolution, window mode, vertical sync, frame cap, render scale with FSR upscaling, quality presets, shadows, particle density, others' effect opacity, post-processing toggles, field of view |
| Audio | Volume per bus, output device, mute when unfocused, CC warning sound on or off |
| Accessibility | Color-blind modes for team colors and debuffs, larger text, reduce camera shake and flashing, subtitle-style event text |

**Interface rules**

- Interface art follows the game: dark iron frames, parchment panels, painted icons.
- Every setting applies instantly without a restart, except resolution changes that need one.
- The interface must render correctly at 1280×720, 1920×1080, 2560×1440, 3840×2160 and ultrawide 3440×1440.

## The iterative build loop

Work proceeds one backlog item at a time through a fixed six-step cycle, with a wider review pass every 10 items and at every milestone gate. An item is small enough to finish in one cycle: one ability, one UI frame, one asset, one rule.

```
1. Pick the top backlog item
2. Write acceptance criteria
3. Implement the change   <---------------------+
4. Run automated checks                         |
5. Inspect screenshots and logs                 |
   Meets the bar?  -- no: fix it, up to 3 tries-+
        | yes
6. Commit and log it  --> next item (back to 1)
        |
        +-- every 10th item --> Review pass --> new priorities (back to 1)
```

**Each step in detail**

1. **Pick.** Take the top item from `BACKLOG.md`. If it is too large for one cycle, split it and pick the first part.
2. **Criteria.** Write 2 to 5 testable acceptance criteria under the item, for example: "Interrupt locks the fire school for 4 s; test passes; cast bar shows the lock icon."
3. **Implement.** Change code, data or Blender scripts. Prefer data changes over code changes.
4. **Checks.** Run the automated checks from "Testing and quality gates". Any failure goes back to step 3.
5. **Inspect.** Capture and look at the result: screenshots of the scene or UI, Blender preview sheets, a short bot match log. Compare against the art bible and the item's criteria.
6. **Commit and log.** Commit with a clear message, add a `CHANGELOG.md` entry, mark the item done, and add any follow-up items found along the way to the backlog.

If an item fails three fix attempts, record it in `KNOWN_ISSUES.md` with what was tried, split it into smaller items, and move on.

**Review pass** (every 10 items, and before declaring a milestone gate passed)

- Run 1,000 simulated bot matches per bracket and report win rate per spec and per team composition.
- Render a lineup of all approved characters and a screenshot of each arena, and check them against the art bible side by side.
- Profile a 20-player bot battleground and record frame time, server tick time and memory.
- Re-order the backlog based on what the review found, and update this document's decisions if anything changed.

**Improving existing work**

Iteration also applies to work already done. Each review pass may add "improve" items to the backlog, such as raising a character's art quality, tuning a spec, or smoothing an animation. These go through the same six steps and must beat the old version on the same checks, shown with before and after screenshots.

## Testing and quality gates

A change is committed only when every check below that applies to it passes. One command, `tools/check_all`, runs them all and prints a pass or fail summary.

**Automated checks**

| Check | What it verifies | When it runs |
| --- | --- | --- |
| Unit tests | Combat math, auras, CC and DR, resources, talent rules (use a Godot test framework such as GdUnit4) | Every commit |
| Data validation | Every JSON file matches its schema; all references between abilities, talents and assets resolve | Every commit |
| Replay test | A recorded match replays from its input log to the same final state | Every commit |
| Network test | Bots play a match at 150 ms latency, 2% packet loss and 30 ms jitter without desync | Every commit touching networking |
| Asset validation | Budgets, bone names, animations, textures (see the pipeline section) | Every asset change |
| Screenshot capture | Fixed camera shots of each arena and each HUD layout at 3 resolutions | Every visual change |
| Balance simulation | Bot win rates per spec and composition | Every review pass |
| Performance run | 20-player bot battleground on the target PC profile | Every review pass |

Godot's headless mode does not render, so screenshot capture needs a GPU or a software renderer (for example, running under a virtual display with Mesa's software drivers).

**Performance targets**

- Recommended PC (6-core CPU, RTX 3060-class GPU, 16 GB RAM): 60 fps at 1080p on High during a 20-player battleground, with 95% of frames under 16.7 ms.
- Minimum PC (4-core CPU, GTX 1060-class GPU, 8 GB RAM): 60 fps at 1080p on Low in arenas.
- Server: under 8 ms per tick for a 20-player match (the tick budget at 60 Hz is 16.7 ms).
- Network: under 96 KB/s download per client in battlegrounds, using delta compression and sending distant players at a reduced rate.
- Load from menu into an arena in under 10 s.

Frame-rate targets can only be measured on real GPU hardware. In a GPU-less cloud workspace, measure server tick time and frame time on the software renderer as relative numbers, and leave the absolute fps checks for a GPU machine.

**Quality bar for visual and audio work**

- In their default sets, character silhouettes are distinguishable by class at 30 m in a grayscale screenshot; with any armor mix, by armor type and weapon. (Changed 2026-10-03: the human chose free armor mixing within an armor type, so armor alone cannot always show the class.)
- Each spell school is identifiable by color alone in a screenshot.
- A tester (or the model reviewing a screenshot) can name who is casting and who is crowd-controlled within 2 seconds of looking at a 3v3 frame.
- No clipping armor in the idle, run and cast poses of the preview sheet.
- No sound is louder than the enemy crowd control warning.

## Open decisions and risks

The biggest risk is art quality: fully scripted characters and animations may fall short of the stylized look this game needs, so the vertical slice must prove the pipeline before the class waves begin.

**Scale of the content**

The full roster means roughly 600 abilities, 2,500 talent nodes (13 class trees, 39 spec trees, 468 PvP talents), 13 armor kits, over 1,000 icons, 10 maps and several thousand sound files. This is why everything is data-driven and generated by script, and why class waves are gated.

**Open decisions**

| Decision | Default in this document | Alternatives | Decide by |
| --- | --- | --- | --- |
| Game engine | Godot 4 | Unreal Engine 5 (stronger visuals, much harder for a model to drive from text and scripts); Unity | Decided: Godot 4.7 |
| Character art source | Fully scripted in headless Blender | Allow CC0 base meshes or artist-made hero models if the slice falls short | Decided at the M1 art gate: fully scripted, improved by iteration (human, 2026-09-30) |
| Animation source | Keyframed by script | Retarget CC0 motion-capture data onto the standard skeleton | Decided: hybrid. Locomotion from retargeted CMU motion capture (commercial use allowed), stylised by data; combat, casts and crowd control scripted; foot IK and look-at in game (delegated by the human, 2026-09-30) |
| Sound effects | Synthesized by script, plus CC0 libraries | AI audio tools, a hired sound designer | Decided: synthesized by script with data-driven studio processing; the human reviews by ear |
| Music | Licensed or CC0 tracks | Commissioned composer | M5 |
| Playable races | None; two body builds per class | Races with cosmetic differences only | Decided: no races; two body types (male and female) open to every class, with a character creator (human, 2026-10-03) |
| Final names | Placeholders in this document | A naming pass with trademark checks | Before any public release |
| Server hosting | Self-hosted during development | Cloud game-server hosting | M4 |

**Risks**

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Scripted characters look crude | Game misses its visual goal | M1 art gate with lineup renders; fallback to CC0 or artist base meshes |
| Scripted animation looks stiff | Combat feels weak | Pose library with eased curves and scripted follow-through; fallback to motion-capture data |
| Bots do not play like people | Balance numbers mislead | Treat bot results as a floor; add human playtests from M2 |
| Too few players to fill queues | Long waits, poor matches | Bots fill unrated queues; rated queues widen rating range over time |
| Content volume stalls progress | Classes arrive unfinished | Waves of 3 to 4 classes, each fully done before the next starts |
| Network feel under latency | Abilities feel delayed | Instant cast feedback, measured at 150 ms from M1 onward |
