# What the mods rely on in the game

For mod makers: the game classes, files and behaviours each mod depends
on. After a game update, `check-build.ps1` compares the game's class dump
with the last checked one and lists every row below whose class changed,
with the mods that use the changed members. Read the matching rows, then
run the quick tests of [new-game-build.md](new-game-build.md).

A **name** dependency (a class, property or function the mod reads or
calls) shows in the dump diff. A **behaviour** dependency (something the
game does that the mod counts on) often does not: the dump only shows it
when a class it involves changes, sometimes by a member the mod never
names. Example (build of 2026-11-22): `UBountyBoardWindow` lost
`GetWithdrawSilverText`; no mod called it, but QuickBounty relied on the
withdraw text being bound to it, and the amount started to flicker.

Keep this table up to date when a mod starts to rely on something new.
The `Class` column holds the class name as the dump writes it (`U…`,
`A…`, `F…`, `E…`), or `-` for files and engine behaviour. Offsets matter
only where a row says so.

| Mod | Class | Relies on |
|-----|-------|-----------|
| AvatarSort | UAvatarStorageWidget | `AvatarProfileGridPanel` is a UniformGridPanel of tiles; the mod moves each tile's slot (row, column). The game lays the grid out again on its own (about 0.5 s after a sort): the mod sorts again when a slot moved. |
| AvatarSort | UAvatarProfileWidget | A tile is `ProfileButton > Overlay` with `ProfileImage`, `NameText`, `OwnerTypeIcon`, `StackSizeText`; the mod adds its label to that overlay. An empty or recycled tile has `ProfileImage` hidden. Owner = `OwnerTypeIcon` image compared with `AUIGlobals` `FamilyOwnerIconTexture` / `PublicOwnerIconTexture`. |
| AvatarSort | UAvatarProfileDetailsWidget | Skills are read from the tooltip's `…NumberText` texts (`FitnessNumberText` …), written `value/max` and filled when the window opens, without a hover. Rested = health and stamina limit bars at their maximum. |
| AvatarSort | EAnvilAvatarAttributeType | Skill order Fitness 0 … Hunting 5, Cooking 6 (ignored). |
| AvatarSort | AUIGlobals | `AvatarProfileIconMap` gives each tile's icon (test bench only). |
| ChatPlus | UChatWidget | Messages in `ChatHistoryListView`, one `UChatMessage` item each (no time in them); entries `BPChatEntryWidget_C` whose whole tree is `ChatEntryInternal`. The mod patches the entry class's widget tree (root becomes its row) with widgets kept in the root set. |
| ChatPlus | UChatWidget | Channel: `CurrentMode` 4 Empire, 5 Family, 6 Local; `ChatEntryDropdown` options "Empire", "Local", "Family". `OnModeOptionSelected(label, 2)` changes the channel; with select info Direct (3) the game ignores it. The game puts the channel back on Empire at each change of area, region crossing and death. |
| ChatPlus | UChatWidget | After a change of area the old chat stays in memory, hidden, until a garbage collection; the visible one is the live one. The game puts the same message items in the new chat. |
| ChatPlus | UChatEntryBase | `SenderName`, `Message`, `ChatType` (probe only). |
| CursorColor | - | The game pak (`Anvil-Windows.pak`) is version 11, not compressed, not encrypted, and holds the cursors as raw PNGs (24 x 24 RGBA): `Anvil/Content/Slate/MouseCursor`, `MouseCursorSword`, `MouseCursorHammer`, `MouseCursorAiming`, `AimReticleCenter`. The game lets its paks be renamed while it runs. |
| CursorColor | UUserInterfaceSettings | Hardware cursors only (Default `Slate/MouseCursor`, Crosshairs `Slate/AimReticleCenter`); the game's C++ switches to `Slate/MouseCursorSword` / `MouseCursorHammer` itself. |
| CursorColor | AVisPlayer | `AimMeshComponent` holds a dynamic instance of `/Game/FX/Materials/AimMesh`; its vector parameter `Emissive Colour` is the colour of the bow's aim line. |
| HouseScreenSorter | UFamilyWindow | Maintained by @gabrdeux: family member list, hooks on `UActionButtonWidget:OnClicked`, `UFamilyMemberListItemWidget:OnFamilyRoleSelectionChanged` / `OnKickButtonClicked`, `UGameplayScreen:HandleFamilyScreenButtonClicked`, textures `ActionButtons_Players`, `ActionButtons_Upvote…`. |
| KeybindPlus | UOptionsMenuKeybindWidget | The Keybinds menu is `KeybindWidgetContainer` holding `BPAnvilKeyEntryWidget_C` entries (`UAnvilKeyEntryWidget`: `ActionLabel` = the action mapping name, `LabelText`, `InputType` 0 Action); an entry made with `WidgetBlueprintLibrary.Create` and given those before it is added shows and changes its action's key with the game's own code. The item slots are the actions `SwapItem1` to `SwapItem8` (no entry in the game's menu). On AZERTY the number row is `Ampersand`, `E_AccentAigu`, `Quote` ... |
| ModManager | UOpeningScreen | Main menu buttons are `UAnvilButtonWidget` (`OptionsButton`, `ExitButton` …); the mod copies one to make its Mods button and puts it before `ExitButton`. |
| ModManager | UAnvilButtonWidget | `ButtonText`, `LabelText`, `Button`, `SizeBox`: style copied for the panel's buttons. |
| NameColors | UNameplateComponent | **Offsets**: `NameTypeColourList` (FLinearColor[5]) at 0x938 and `FamilyColour` at 0x988, read through custom properties. The mod checks colour 0 and the family colour against what UE4SS reads and leaves everything alone if they differ. |
| NameColors | AVisPlayer | Each player's nameplate is a `UNameplateComponent` on `BpVisPlayer_C`. |
| QuickBounty | UBountyBoardWindow | `WithdrawSilverText`: since the build of 2026-11-22 the game writes its counting amount itself every frame (it was bound to `GetWithdrawSilverText`); the mod collapses it and shows its own text in the same box (`WithdrawSilverBox`, a HorizontalBox). |
| QuickBounty | UBountyBoardWindow | After a hand-in `LoadingBox` shows while the server answers, then `SubmitBountyStatusMessageBox` ("Bounty complete", "…has been transferred…", English) for about 2 s; `HideBountyStatusMessageBox` hides it. The withdraw button stays disabled ~2.2 s (game side, left alone). |
| QuickBounty | UBountyBoardWindow | `BountyProgressBar.Percent` = silver earned today / daily cap; the cap is measured from the bar's move at a hand-in. `SubmitBountyHintText` shows above the bar when the window is opened away from a board. |
| QuickBounty | UBountyListViewItem | `bIsUnavailable` marks bounties that cannot be handed in (over the daily cap…); `bCanSubmitBounty` is true for all and is not used. |
| QuickBounty | UBountyWidget | Request in `BountyResourceWidget`: `ResourceIcon` texture name and `ResourceCostText` ("3x"); reward in `BountySilverText`. Hooks `OnSubmitBountyButtonClicked` and the window's `OnWithdrawSilverButtonClicked` fire. |
| QuickBounty | UInventoryWidget | One copy of the player inventory per window, updated only when its window opens; item icons (`ItemImage` texture names) match the bounty icons. |
| QuickBounty | UPlayerControllerDataComponent | `BountySilver` = silver waiting on the board, as the server sent it. |
| QuickBounty | UListView | The bounty list only builds widgets for the bounties on screen; `GetListItemObject` gives an entry's item; `ClearListItems` + `AddItem` reorder it. |
| all | AAnvilHUD | A new HUD at each change of area (backup signal for the pause around map loads). |
