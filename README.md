# Anvil Empires QoL mods

Small **quality of life** mods for **Anvil Empires**, made with
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): clearer lists, handier
windows, more readable colours, more keyboards supported. They only change
the interface and what your own screen shows. They give no advantage in a
fight, do not play for you and send nothing of their own to the game's
server.

> Unofficial and not affiliated with Siege Camp. These mods only change
> what your own screen shows: they never change what the game sends to
> the server. They run on UE4SS, an external tool: please use it only to
> run mods like these, never to gain an advantage over other players. Use
> them at your own risk, and check the developers' rules on mods first.
>
> **To the Anvil Empires developers:** if you think any of these mods is a
> problem, please [open an issue](../../issues) or contact me, and I will
> take it down right away.

## Mods

| Mod | What it does | Author | Download |
|-----|--------------|--------|----------|
| [AvatarSort](AvatarSort/README.md) | Sorts avatar lists by level or by skill, and shows each avatar's value/max on its tile | [Feyn](https://github.com/HarvFeyn) | [AvatarSort.zip](../../releases/latest/download/AvatarSort.zip) |
| [ChatPlus](ChatPlus/README.md) | Shows the time of each chat message, in your own time zone, and keeps the chat channel you picked | [Feyn](https://github.com/HarvFeyn) | [ChatPlus.zip](../../releases/latest/download/ChatPlus.zip) |
| [CursorColor](CursorColor/README.md) | Colours the mouse cursor and the bow's aim line, in the colour you choose | [Feyn](https://github.com/HarvFeyn) | [CursorColor.zip](../../releases/latest/download/CursorColor.zip) |
| [HouseScreenSorter](HouseScreenSorter/README.md) | Sorts family house members by role and alphabetically, with an online-only filter button | [@gabrdeux](https://github.com/gabrdeux) | [HouseScreenSorter.zip](../../releases/latest/download/HouseScreenSorter.zip) |
| [KeybindPlus](KeybindPlus/README.md) | Adds the item slots (1 to 8) to the game's Keybinds menu, so you can change their keys (for AZERTY keyboards) | [Feyn](https://github.com/HarvFeyn) | [KeybindPlus.zip](../../releases/latest/download/KeybindPlus.zip) |
| [ModManager](ModManager/README.md) | Adds a Mods button to the main menu to turn these mods on or off, see their versions and change their settings | [Feyn](https://github.com/HarvFeyn) | [ModManager.zip](../../releases/latest/download/ModManager.zip) |
| [NameColors](NameColors/README.md) | Lets you choose the colours of player names: each faction and your guild | [Feyn](https://github.com/HarvFeyn) | [NameColors.zip](../../releases/latest/download/NameColors.zip) |
| [QuickBounty](QuickBounty/README.md) | Puts the bounties you can hand in first, removes the pause after a hand-in and shows your daily silver | [Feyn](https://github.com/HarvFeyn) | [QuickBounty.zip](../../releases/latest/download/QuickBounty.zip) |

All releases and their changes: [Releases](../../releases).

## Installation

1. Download **[AnvilMods-Pack.zip](../../releases/latest/download/AnvilMods-Pack.zip)**.
   It holds the official UE4SS loader (`UE4SS_v3.0.1-1181-g83330635`) and
   all the mods above, and nothing else: UE4SS's debug window is off, and
   its cheat, console and dump mods are left out.
2. Open the game's folder: in Steam, right-click the game → **Manage** →
   **Browse local files**. Then go to `Anvil\Binaries\Win64\` (the folder
   with `Anvil-Win64-Shipping.exe`).
3. Extract the zip there. You should get:

   ```
   Win64\
   ├── Anvil-Win64-Shipping.exe
   ├── dwmapi.dll
   └── ue4ss\
       ├── UE4SS.dll
       └── Mods\
           ├── AvatarSort\
           ├── ChatPlus\
           ├── CursorColor\
           ├── HouseScreenSorter\
           ├── KeybindPlus\
           ├── ModManager\
           ├── NameColors\
           ├── QuickBounty\
           └── shared\
   ```

4. Start the game. The **Mods** button in the main menu lists the mods,
   with their versions, and turns them on or off.

To check that a mod is running, open the **Mods** menu: it shows **On**
next to it. The file `ue4ss\UE4SS.log` also has one line per mod at each
start, such as `[AvatarSort] v0.3.0 loaded`.

### Already using UE4SS?

Do not extract the pack: it would replace your UE4SS settings. Take each
mod's zip from the table above and extract it into `ue4ss\Mods\`. Mods are
tested with the UE4SS version named above only.

The full UE4SS release enables `CheatManagerEnablerMod` and
`ConsoleEnablerMod` by default. Before playing online, set them to `0` in
`ue4ss\Mods\mods.txt` or delete their folders in `ue4ss\Mods\`.

### Update

When a new release is out (the **Mods** menu shows your versions; **Open
GitHub page** shows the latest ones), update everything at once:

1. Close the game.
2. Download the new **[AnvilMods-Pack.zip](../../releases/latest/download/AnvilMods-Pack.zip)**.
3. Extract it into `Anvil\Binaries\Win64\`, exactly as for the first
   installation. When Windows asks, choose **Replace the files in the
   destination**.

Your settings (the colours of NameColors and CursorColor) are kept: the
pack has no settings file, so yours are not replaced. Mods you turned off
in the **Mods** menu are on again after an update: turn them off again if
you want.

If something looks wrong after an update, do a clean install: delete
`dwmapi.dll` and the `ue4ss` folder in `Win64\` (and
`Anvil\Content\Paks\zCursorColor_P.pak` if you use CursorColor), then
install the pack again as the first time. You only lose your colour
choices.

If you install the mods one by one (see *Already using UE4SS?*), update a
mod the same way: extract its new zip into `ue4ss\Mods\` and replace the
files.

### Uninstall

- One mod: turn it off in the **Mods** menu, or delete its folder in
  `ue4ss\Mods\`. For CursorColor, turn it off in the menu (it removes its
  cursor file), or also delete `Anvil\Content\Paks\zCursorColor_P.pak`.
- Everything: delete `dwmapi.dll` and the `ue4ss` folder in `Win64\`. If
  you used CursorColor, also delete `Anvil\Content\Paks\zCursorColor_P.pak`
  (or turn CursorColor off in the Mods menu first).

## Game updates

A game update can break a mod. Each mod's page says which game version it
was tested with. If something looks wrong after an update, turn the mod
off in the **Mods** menu and check for a new release.

## FAQ

**Do other players see my changes?**
No. The mods only change what your own screen shows. Nothing they do is
sent to the game's server.

**The game crashes or does not start since I installed the pack, or since
a game update.**
On Windows 11, *Smart App Control* blocks programs and files that are not
signed and that Microsoft does not know yet. It can block UE4SS
(`dwmapi.dll`), and it even blocked a file of the game itself after a
game update (November 2026). To check: Windows Security → App & browser
control → Smart App Control. Turning it off is your decision: on many
Windows versions it cannot be turned back on without reinstalling
Windows. To test the game without the mods, rename `dwmapi.dll` in
`Win64\` to `dwmapi.dll.off` (rename it back to get the mods again).

**There is no Mods button in the main menu.**
Check that `dwmapi.dll` and the `ue4ss` folder are next to
`Anvil-Win64-Shipping.exe` (step 3 above), not in a subfolder. If they
are, open `ue4ss\UE4SS.log` and look for the lines of ModManager.

**Where are my settings?**
In `settings.txt` in each mod's folder, written by the **Mods** menu.
Delete it to go back to the defaults.

**I found a bug, or I have an idea.**
[Open an issue](../../issues) (a free GitHub account is needed). For a
bug, say which mod and version (shown in the **Mods** menu), what you did
and what happened, and add the mod's lines from `ue4ss\UE4SS.log` (the
lines that start with the mod's name). Hide player names if the lines
show some.

## License

[MIT](LICENSE). UE4SS is made by its own authors and has its own MIT
license, included in the pack as `ue4ss\LICENSE`.
