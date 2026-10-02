# Arena PvP: playtest build

Thank you for testing. This build is the end of milestone 2: three classes, 1v1, 2v2 and 3v3 arenas against bots, three arenas with a twist each, talents, keybinding, HUD editing and settings. Everything runs on your own PC; there is no online play yet.

## Install and run

1. Unzip the whole folder anywhere (keep `ArenaPvP.exe` and `ArenaPvP.pck` together).
2. Run `ArenaPvP.exe`. Windows may warn that the program is unrecognised, because the build is not signed: choose **More info**, then **Run anyway**.

Linux: unzip, then run `./ArenaPvP.x86_64`.

You need a 64-bit PC with a graphics card that supports Vulkan (most cards from 2016 on). A match starts a small local server and the bots as background copies of the game; they close when the match ends.

## What to play

On the main menu, pick your specialization first (top of the menu):

- **Warblade (Carnage):** a plate-armoured melee fighter with a two-handed sword.
- **Arcanist (Rime):** a frost caster who slows, roots and freezes.
- **Oracle (Grace):** a healer with some holy damage and crowd control.

Then:

- **Practice:** a 2v2 on Gallows Courtyard run entirely inside the game (no background server), with three bots. Good for learning the controls and abilities.
- **Play 1v1 vs a bot**, **Play 2v2 vs bots**, **Play 3v3 vs bots:** a full match with a preparation phase, gates, and a scoreboard at the end. You get one of three arenas at random:
  - **Gallows Courtyard:** at 5:00 the gallows in the middle collapse and open up the centre.
  - **Flooded Crypt:** at 3:00 the nave floods; wading is slow except in the side aisles.
  - **Burning Foundry:** at 2:30 the casting wheel starts turning, and the two crucibles circle the furnace, moving the cover and pushing aside anyone in the way.
- **Talents:** pick talents for each specialization and save loadouts. You can also change them during a match's preparation phase from the Escape menu.

## Controls (defaults; all can be changed in Settings, Keybindings)

| Action | Key |
| --- | --- |
| Move forward and back | W, S |
| Turn | A, D (or hold the right mouse button and move the mouse) |
| Strafe | Q, E |
| Jump | Space |
| Target the nearest enemy, cycle targets | Tab |
| Clear target, open the menu | Escape |
| Abilities | 1 to 0, minus and equals; Shift with the same keys for the second bar |
| Break free of crowd control | Shift+R |
| Set focus | Shift+F |
| Scoreboard | H |
| Edit the HUD (move and scale every element) | F10 |
| Camera | Hold the left mouse button to look around; mouse wheel to zoom |

## Before you start

In **Settings, Interface**, turn on **Show frame rate**. It shows the frame rate in the corner, and it helps a lot to know what your PC gets. The game also writes the frame rate to its log after every match either way.

## What I would like to know

Short notes are fine. Anything that felt wrong is worth a line.

1. **Controls and camera:** does moving, turning and steering feel responsive? Anything awkward?
2. **Combat feel:** do abilities fire when you press them? Can you tell what is happening: who is casting, who is crowd-controlled, who is low on health?
3. **Each class:** which did you play, and how did it feel (too strong, too weak, boring, fun)?
4. **Bots:** do they play believably? Anything silly (getting stuck, ignoring you, running into walls)?
5. **Arenas and twists:** do the arenas read well? Did you notice the twists, and were they fun or annoying?
6. **Sound:** do the hits, spells and warnings sound right? (The sword hits were redone several times; is the slash convincing now?)
7. **Performance:** your frame rate in a 3v3 match, and your graphics card if you know it.
8. **Bugs:** anything broken, with roughly what you were doing.

## Sending files back (optional, very useful)

The game keeps logs and records your matches, so I can replay exactly what you saw. They are in:

- Windows: `%APPDATA%\Godot\app_userdata\Arena PvP\` (paste that into the File Explorer address bar)
- Linux: `~/.local/share/godot/app_userdata/Arena PvP/`

Useful files: everything in `logs`, and in `recordings` the match files (`.bin`) of any match where something went wrong (the newest 20 are kept). Attach them in the chat with your notes. Recording can be turned off in Settings, Gameplay.

## Known issues

- 1v1 balance is off with some talent builds: the Arcanist wins most duels, and two Oracles in a duel often reach the 12-minute limit.
- Bots do not see a foundry crucible coming; they get pushed and then steer away.
- There is no sound when a foundry crucible pushes you.
- Only three of the planned thirteen classes exist; battlegrounds come in a later milestone.
- Visual polish varies: the Gallows Courtyard is plainer than the other two arenas.
