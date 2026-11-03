# ModManager

Turns the mods of this repository on or off from the **Anvil Empires**
main menu.

**[Download ModManager.zip](../../../releases/latest/download/ModManager.zip)**
· [How to install](../README.md#installation)

Version 0.1.0, tested with the Anvil Empires playtest of November 2026 and
`UE4SS_v3.0.1-1181-g83330635`.

## What it does

A **Mods** button appears in the main menu, above **Close Game**. It opens
a list of the installed mods, with for each one:

- an **Enable** / **Disable** button;
- its name and installed version;
- its state: **On**, **Off**, or **On after restart** / **Off after
  restart** when you changed it;
- a short description.

Changes apply the next time the game starts: a running mod cannot be
unloaded. ModManager itself is always on.

**Check for updates** opens the [Releases](../../../releases) page, where you
can compare your versions with the latest ones.

## Which mods it lists

Only mods with a `modinfo.txt` file in their folder, like the ones in this
repository:

```
name = AvatarSort
version = 0.1.1
description = Sorts avatar lists by level or by skill.
```

UE4SS's own mods and mods without this file are not listed, and the
manager never changes them.

## What it does not do

It only reads and writes files in `ue4ss\Mods\`: the mod's `enabled.txt`,
and its line in `mods.txt` when it has one. It does not connect to the
internet, and nothing is sent to the game's server.

## Keys

| Key | Action |
|-----|--------|
| Ctrl + F9 | Write the main menu's layout and the listed mods to `ue4ss\UE4SS.log` (for bug reports) |

On a laptop where F keys control volume or brightness, hold **Fn** too.
