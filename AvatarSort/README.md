# AvatarSort

Sorts the avatar lists of **Anvil Empires** and shows each avatar's
skill on its tile.

**[Download AvatarSort.zip](../../../releases/latest/download/AvatarSort.zip)**
· [How to install](../README.md#installation)

Version 0.3.0, tested with the Anvil Empires playtest of November 2026 and
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

Under the buttons, two filters, both off until you tick them:

- **Rested**: only avatars whose maximum health and maximum stamina are
  full are shown (an avatar that is only missing current health still
  counts as rested). Auxiliaries are always shown.
- **Personal**: only your personal avatars are shown; family and public
  avatars are hidden.

Ticked together, they show your personal avatars that are fully rested.

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

## Known limitations

- The game sometimes puts the tiles back in its own order; the mod sorts
  them again right away, so you may see a short flicker.
- "Level" is this mod's own measure (sum of skills), not a value from
  the game.
