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
           └── shared\
   ```

4. Start the game.

To check that a mod is running, open `ue4ss\UE4SS.log`: it should contain
a line such as `[AvatarSort] v0.1.1 loaded`.

### Already using UE4SS?

Do not extract the pack: it would replace your UE4SS settings. Take each
mod's zip from the table above and extract it into `ue4ss\Mods\`. Mods are
tested with the UE4SS version named above only.

The full UE4SS release enables `CheatManagerEnablerMod` and
`ConsoleEnablerMod` by default. Before playing online, set them to `0` in
`ue4ss\Mods\mods.txt` or delete their folders in `ue4ss\Mods\`.

### Update a mod

Download the mod's zip from the table above, delete the mod's folder in
`ue4ss\Mods\`, then extract the zip there.

### Uninstall

- One mod: delete its folder in `ue4ss\Mods\`.
- Everything: delete `dwmapi.dll` and the `ue4ss` folder in `Win64\`.

## Game updates

A game update can break a mod. Each mod's page says which game version it
was tested with. If something looks wrong after an update, uninstall the
mod and check for a new release.

## License

[MIT](LICENSE). UE4SS is made by its own authors and has its own MIT
license, included in the pack as `ue4ss\LICENSE`.
