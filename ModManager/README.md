# ModManager

Turns the mods of this repository on or off from the **Anvil Empires**
main menu.

**[Download ModManager.zip](../../../releases/latest/download/ModManager.zip)**
· [How to install](../README.md#installation)
· Author: [Feyn](https://github.com/HarvFeyn)

Version 0.2.2, tested with the Anvil Empires playtest of November 2026 and
`UE4SS_v3.0.1-1181-g83330635`.

## What it does

A **Mods** button appears in the main menu, above **Close Game**. It opens
a list of the installed mods, with for each one:

- an **Enable** / **Disable** button;
- its name and installed version;
- its state: **On**, **Off**, or **On after restart** / **Off after
  restart** when you changed it;
- a short description;
- a **Settings** button for mods that have settings (NameColors, for
  example): pick a colour in a palette, or go back to the default.

Turning a mod on or off applies the next time the game starts: a running
mod cannot be unloaded. ModManager itself is always on. Settings apply
right away.

**Open GitHub page** opens the mods' [Releases](../../../releases) page in your
browser, where you can compare your versions with the latest ones.

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
