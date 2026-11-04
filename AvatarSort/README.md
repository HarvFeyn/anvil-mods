# AvatarSort

Sorts the avatar lists of **Anvil Empires** and shows each avatar's
skill on its tile.

**[Download AvatarSort.zip](../../../releases/latest/download/AvatarSort.zip)**
· [How to install](../README.md#installation)

Version 0.2.1, tested with the Anvil Empires playtest of November 2026 and
`UE4SS_v3.0.1-1181-g83330635`.

## What it does

A row of buttons appears above every avatar list (town center, family
area marker, caravan, inventory, deployment pop-up):

| Button | Sorts by |
|--------|----------|
| **All** | Overall level: the sum of the six skills |
| **Fitness** | Fitness |
| **Melee** | Melee Combat |
| **Ranged** | Ranged Combat |
| **Smith** | Blacksmithing |
| **Logging** | Logging & Mining |
| **Hunting** | Hunting |

After the buttons, the **Rested** check box: when it is ticked, only
avatars at full health and full stamina are shown. Auxiliaries are always shown.

- Highest first. When two avatars have the same value, the one with the
  higher maximum comes first.
- Each tile shows the sorted skill as `value/max` (for example `6/9`).
  In **All** mode it shows the sum of the values over the sum of the
  maximums.
- Auxiliaries always stay in the first cell, and empty cells always stay
  at the end.
- Cooking is ignored: the game does not use it yet.

The chosen sort applies to every list until you pick another one.

## What it does not do

It only moves tiles on your screen and adds the buttons and labels.
Clicking a tile, Ctrl + click to swap inventories, and tooltips work as
in the unmodded game. Nothing is sent to the server.

## Keys

| Key | Action |
|-----|--------|
| Ctrl + F6 | Next sort mode |
| Ctrl + F7 | Test window with fake avatars (works from the main menu): 6 columns, then 4, then closed |
| Ctrl + F8 | Write what the mod reads to `ue4ss\UE4SS.log` (for bug reports) |

On a laptop where F keys control volume or brightness, hold **Fn** too.

## Known limitations

- The game sometimes puts the tiles back in its own order; the mod sorts
  them again right away, so you may see a short flicker.
- "Level" is this mod's own measure (sum of skills), not a value from
  the game.
