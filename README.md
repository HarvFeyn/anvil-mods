# Anvil Empires mods

Small client-side mods for **Anvil Empires**, made with
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).

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

| Mod | What it does | Download |
|-----|--------------|----------|
| [AvatarSort](AvatarSort/README.md) | Sorts avatar lists by level or by skill, and shows each avatar's value/max on its tile | [AvatarSort.zip](../../releases/latest/download/AvatarSort.zip) |

All releases and their changes: [Releases](../../releases).

## Installation

### 1. Install UE4SS (once)

1. Download UE4SS from its
   [experimental-latest release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest):
   take the `UE4SS_v3.x.x-….zip` file (not the `zDEV` one).
   Tested with `UE4SS_v3.0.1-1181-g83330635`.
2. Open the game's folder: in Steam, right-click the game → **Manage** →
   **Browse local files**. Then go to `Anvil\Binaries\Win64\` (the folder
   with `Anvil-Win64-Shipping.exe`).
3. Extract the UE4SS zip there. You should get:

   ```
   Win64\
   ├── Anvil-Win64-Shipping.exe
   ├── dwmapi.dll
   └── ue4ss\
   ```

4. Recommended: open `ue4ss\UE4SS-settings.ini` and set
   `GuiConsoleEnabled = 0` and `ConsoleEnabled = 0`, so UE4SS does not
   open its debug windows next to the game.

### 2. Install a mod

1. Download the mod's zip from the table above.
2. Extract it into `Win64\ue4ss\Mods\`. You should get, for example,
   `ue4ss\Mods\AvatarSort\enabled.txt` and `ue4ss\Mods\AvatarSort\Scripts\main.lua`.
3. Start the game.

To check that a mod is running, open `ue4ss\UE4SS.log`: it should contain
a line such as `[AvatarSort] v0.1.0 loaded`.

### Update a mod

Delete the mod's folder in `ue4ss\Mods\`, then install the new zip.

### Uninstall

- One mod: delete its folder in `ue4ss\Mods\`.
- Everything: delete `dwmapi.dll` in `Win64\`. Nothing from UE4SS loads
  without it; you can also delete the `ue4ss` folder.

## Game updates

A game update can break a mod. Each mod's page says which game version it
was tested with. If something looks wrong after an update, uninstall the
mod and check for a new release.

## License

[MIT](LICENSE).
