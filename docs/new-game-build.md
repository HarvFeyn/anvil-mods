# After a game update

For mod makers. Each new build of Anvil Empires can change what the mods
rely on ([game-dependencies.md](game-dependencies.md)). This procedure
takes about 15 minutes: it finds the likely problems from the class dump,
then checks every mod by hand with a few quick tests.

Needs the developer UE4SS (`.\switch-ue4ss.ps1 dev`) for the dump and the
dev keys.

## 1. Dump the new build

1. Start the game. If it crashes at once, check Windows first (Smart App
   Control blocked the game's new `R2.dll` on 2026-11-22: Windows Security
   → App & browser control → Smart App Control; Code Integrity events 3033
   / 3077 in the event log).
2. Go in game (not only the main menu).
3. Press **Ctrl+H** with the game window focused (or UE4SS window →
   Dumpers → Dump CXX Headers). Wait a few seconds.

## 2. Compare

```powershell
.\check-build.ps1
```

It compares the new dump with the last checked one and prints:

- every change in the game's classes, enums and the engine types the mods
  use, with `<< named by <Mod>` on members a mod's code names;
- the rows of `game-dependencies.md` whose class changed: **read each**
  and decide if the change can break what the row says. Remember that a
  mod can rely on a member it never names (QuickBounty and
  `GetWithdrawSilverText`, 2026-11-22).

Also read the game's patch notes, if any: a changed behaviour (new window,
new rule, new limit) often shows there before it shows in the dump.

## 3. Quick tests (every mod, every build)

Watch `ue4ss\UE4SS.log` while testing: each mod logs `vX loaded` at start
and its errors in its own lines (`[QuickBounty] … error`).

| Mod | Test | Expected |
|-----|------|----------|
| All | Start the game | Each mod logs `[<Mod>] vX loaded`; no `error` line |
| ModManager | Main menu → Mods | The list, versions, Settings of NameColors and CursorColor open and look right; Back works |
| AvatarSort | Open a keep's or camp's avatar list, click two sort buttons and a filter | Tiles sorted, value/max labels on tiles, auxiliaries first, empty cells last; deploying or opening a tile still works |
| ChatPlus | Send a message; enter and leave a cave; switch to Family, enter a cave | `[HH:MM]` before new messages; times kept after the cave; Family picked again after the cave |
| CursorColor | With a colour set: cursor in the menu, in game, in combat (sword), with a hammer; aim with a bow | Cursors in the colour (since the start of the game); aim line in the colour, orange past an obstacle; log has no `cannot` line |
| NameColors | Look at players of each faction and of your house | Names in the chosen colours; no `left alone` line in the log |
| QuickBounty | Open a bounty board, hand in one bounty, withdraw the silver; open bounties from the shortcut away from a board | Ready bounties first and framed; no pause after the hand-in; amount beside the withdraw button jumps to the right value (no counting); `N / cap silver today` above the bar, not over the hint text; log has `daily silver cap measured` |
| HouseScreenSorter | Open the house (family) screen | Members sorted by role then name; online filter button works (maintained by @gabrdeux) |

Rows of `game-dependencies.md` with no class (`-`) are files or engine
behaviour: CursorColor's pak (the mod rebuilds it when the game's pak
changes; the cursor test covers it).

## 4. Done

- Fix what broke, bump the mod's version, release it.
- Update the "tested with" line of the READMEs of the mods checked.
- Keep this build's dump as the reference for the next update:

```powershell
.\check-build.ps1 -Accept
```

- Add to `game-dependencies.md` anything new a mod started to rely on.
