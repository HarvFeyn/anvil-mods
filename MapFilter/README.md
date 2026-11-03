# MapFilter

Shows or hides each kind of icon on the **Anvil Empires** map and compass.

**[Download MapFilter.zip](../../../releases/latest/download/MapFilter.zip)**
· [How to install](../README.md#installation)

Version 0.1.0, tested with the Anvil Empires playtest of November 2026 and
`UE4SS_v3.0.1-1181-g83330635`.

## What it does

An **Icons** button appears at the top right of the map. It opens a legend
with one line per kind of icon on the map: towns, markets, beacon towers,
mines, brigands, map posts, region names, and so on. Untick a line to hide
those icons on the map and on the compass; tick it again to show them.

- Only kinds of icon currently on the map are listed. A new kind (a camp
  once one is built, for example) gets its own line the first time it
  appears, ticked: nothing is hidden unless you untick it.
- Your choices are saved in `ue4ss\Mods\MapFilter\settings.txt` and kept
  for the next game. Updating the mod (deleting its folder) resets them.
- Hidden icons are made fully transparent. Hidden map posts also cannot be
  clicked.

## What it does not do

It only changes what your own screen shows. Nothing is sent to the game's
server, and icons are never moved or removed from the game's data.

## Keys

| Key | Action |
|-----|--------|
| Ctrl + F10 | Write the map's layout and every map and compass icon to `ue4ss\UE4SS.log` (for bug reports) |

On a laptop where F keys control volume or brightness, hold **Fn** too.
