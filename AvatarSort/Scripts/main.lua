--[[
    AvatarSort: reorders the avatar list (keep, caravan, deployment pop-up).

    Display only: the mod moves existing tiles inside AvatarProfileGridPanel
    by changing their row and column. It never creates, removes or clicks a
    tile, and never calls anything that talks to the server.

    A row of sort buttons is added above each avatar grid.

    Keys (game window focused):
      Ctrl+F6  next sort mode (Level, then each skill)
      Ctrl+F7  open / close the test bench (works from the main menu)
      Ctrl+F8  probe: log what the mod can read from every open avatar grid
--]]

local UEHelpers = require("UEHelpers")

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.1"

local function Log(Format, ...)
    print("[AvatarSort] " .. string.format(Format, ...) .. "\n")
end

-- Skills the game uses, as indices of FAvatarProfile.Attributes
-- (EAnvilAvatarAttributeType). Cooking (6) is not used by the game yet:
-- it is left out on purpose and never counts in the level.
local Skills = {
    { Index = 0, Name = "Fitness",       Short = "Fit", Text = "FitnessNumberText" },
    { Index = 1, Name = "MeleeCombat",   Short = "Mel", Text = "MeleeCombatNumberText" },
    { Index = 2, Name = "RangedCombat",  Short = "Rng", Text = "RangedCombatNumberText" },
    { Index = 3, Name = "Blacksmithing", Short = "Smi", Text = "BlacksmithingNumberText" },
    { Index = 4, Name = "LoggingMining", Short = "Log", Text = "LoggingMiningNumberText" },
    { Index = 5, Name = "Hunting",       Short = "Hun", Text = "HuntingNumberText" },
}

-- Sort modes, in the order Ctrl+F6 cycles through them and the buttons
-- are shown. "Level" is the sum of the six skills.
local Modes = { "Level" }
local ModeLabels = { Level = "Lvl" }
local ModeTooltips = { Level = "Sort by level (sum of skills)" }
for _, Skill in ipairs(Skills) do
    Modes[#Modes + 1] = Skill.Name
    ModeLabels[Skill.Name] = Skill.Short
    ModeTooltips[Skill.Name] = "Sort by " .. Skill.Name
end
local CurrentMode = 1

local StorageWidgetClass = "/Script/Anvil.AvatarStorageWidget"
local ProfileWidgetClass = "/Script/Anvil.AvatarProfileWidget"
local StorageWidgetAsset = "/Game/UI/Gameplay/StructureWindows/Avatars/BPAvatarStorageWidget"
local StorageWidgetBPClass = StorageWidgetAsset .. ".BPAvatarStorageWidget_C"

-- Fake skills for the test bench, keyed by tile address.
local FakeSkills = {}
-- Game order of each tile (row * 1000 + column) the first time we saw it,
-- keyed by tile address. Breaks ties so equal tiles keep the game's order.
local GameOrder = {}
local TestBench = nil

------------------------------------------------------------------------
-- Reading skills
------------------------------------------------------------------------

-- Text of a TextBlock, or nil. Reads the Text property first: calling
-- GetText() while the game is still building the window failed in game.
local function ReadText(TextBlock)
    if not TextBlock or not TextBlock:IsValid() then return nil end
    local Ok, Text = pcall(function() return TextBlock.Text:ToString() end)
    if Ok and type(Text) == "string" then return Text end
    Ok, Text = pcall(function() return TextBlock:GetText():ToString() end)
    if Ok and type(Text) == "string" then return Text end
    return nil
end

-- The game shows a skill as "value/max" (for example "6/9"). Returns
-- value, max, or nil for anything else: an empty cell keeps the designer
-- text "8", and so does a tile the game has not filled yet.
local function ReadValueAndMax(TextBlock)
    local Text = ReadText(TextBlock)
    if not Text then return nil end
    local Value, Max = string.match(Text, "(%-?%d+%.?%d*)%s*/%s*(%d+%.?%d*)")
    if Value then return tonumber(Value), tonumber(Max) end
    return nil
end

-- Reads the six skills from the tile's tooltip (BPAvatarProfileDetailsWidget).
-- Verified in game: the texts are filled when the window opens, no hover
-- needed. Returns nil for an empty cell.
local function ReadSkillsFromTooltip(Tile)
    local Tooltip = Tile.AvatarTooltipWidget
    if not Tooltip or not Tooltip:IsValid() then return nil end
    local Details = Tooltip.AvatarProfileDetailsWidget
    if not Details or not Details:IsValid() then return nil end

    local Values = { Current = {}, Max = {} }
    for _, Skill in ipairs(Skills) do
        local Value, Max = ReadValueAndMax(Details[Skill.Text])
        if Value == nil then return nil end
        Values.Current[Skill.Name] = Value
        Values.Max[Skill.Name] = Max
    end
    return Values
end

-- Returns { Current = { Fitness = n, ... }, Max = { Fitness = n or nil, ... } }
-- or nil when unknown.
local function ReadSkills(Tile)
    return FakeSkills[Tile:GetAddress()] or ReadSkillsFromTooltip(Tile)
end

-- Sum of the six skills, and of their maximums (nil if one is unknown).
local function LevelOf(Values)
    local Sum, MaxSum = 0, 0
    for _, Skill in ipairs(Skills) do
        Sum = Sum + Values.Current[Skill.Name]
        local Max = Values.Max[Skill.Name]
        MaxSum = (MaxSum and Max) and MaxSum + Max or nil
    end
    return Sum, MaxSum
end

-- Value and max shown for the current mode.
local function ModeValue(Values)
    local Mode = Modes[CurrentMode]
    if Mode == "Level" then return LevelOf(Values) end
    return Values.Current[Mode], Values.Max[Mode]
end

-- Sort key of a tile for the current mode; nil sorts last. Equal values
-- are ordered by the higher max.
local function SortKey(Values)
    if Values == nil then return nil end
    local Value, Max = ModeValue(Values)
    return Value * 1000 + (Max or 0)
end

-- Auxiliaries are basic troops, not named avatars: every skill is 1/1 and
-- they stack in one tile. They always go first in the grid.
local function IsAuxiliary(Values)
    if Values == nil then return false end
    for _, Skill in ipairs(Skills) do
        if Values.Current[Skill.Name] ~= 1 or Values.Max[Skill.Name] ~= 1 then return false end
    end
    return true
end

local function ModeText(Values)
    local Value, Max = ModeValue(Values)
    if Max then return string.format("%d/%d", Value, Max) end
    return string.format("%d", Value)
end

------------------------------------------------------------------------
-- Reordering the grid
------------------------------------------------------------------------

local function ForEachTile(Storage, Callback)
    local Grid = Storage.AvatarProfileGridPanel
    if not Grid or not Grid:IsValid() then return end
    Grid.Slots:ForEach(function(_, Element)
        local Slot = Element:get()
        if Slot:IsValid() and Slot.Content:IsValid() then
            Callback(Slot.Content, Slot)
        end
    end)
end

------------------------------------------------------------------------
-- Sort buttons: a row of small buttons added above the grid, inside the
-- grid's scroll box, so the host window keeps its size. UE4SS Lua cannot
-- bind a button's OnClicked, so clicks are detected by polling IsPressed.
------------------------------------------------------------------------

local HAlignLeft, VAlignTop, VAlignCenter, HAlignCenter = 1, 1, 2, 2
local ButtonWidth, ButtonHeight = 31, 20
local ActiveColor = { R = 1.0, G = 0.8, B = 0.45, A = 1.0 }
local InactiveColor = { R = 0.55, G = 0.55, B = 0.55, A = 1.0 }

-- Bars[storage address] = { Bar = HorizontalBox, Buttons = { { Button, Mode, WasPressed } } }
local Bars = {}

local function NewWidget(ClassName, Outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. ClassName), Outer)
end

local function RefreshButtonColors()
    for Address, Entry in pairs(Bars) do
        if Entry.Bar:IsValid() then
            for _, Item in ipairs(Entry.Buttons) do
                Item.Button:SetBackgroundColor(Item.Mode == CurrentMode and ActiveColor or InactiveColor)
            end
        else
            Bars[Address] = nil
        end
    end
end

local function HasBar(Storage, ScrollBox)
    local Entry = Bars[Storage:GetAddress()]
    if not Entry or not Entry.Bar:IsValid() then return false end
    local First = ScrollBox:GetChildAt(0)
    return First:IsValid() and First:GetAddress() == Entry.Bar:GetAddress()
end

-- Adds the button row to a storage widget. StyleTile is one of its tiles,
-- used to copy the game's button style and font.
local function AddSortBar(Storage, StyleTile)
    local Grid = Storage.AvatarProfileGridPanel
    local ScrollBox = Grid:GetParent()
    if not ScrollBox:IsValid() or HasBar(Storage, ScrollBox) then return end

    local Tree = Storage.WidgetTree
    local Bar = NewWidget("HorizontalBox", Tree)
    local Buttons = {}

    for Mode, Name in ipairs(Modes) do
        local Box = NewWidget("SizeBox", Tree)
        Box:SetWidthOverride(ButtonWidth)
        Box:SetHeightOverride(ButtonHeight)

        local Button = NewWidget("Button", Tree)
        pcall(function() Button:SetStyle(StyleTile.ProfileButton.WidgetStyle) end)
        Button:SetToolTipText(FText(ModeTooltips[Name]))
        Box:AddChild(Button)

        local Label = NewWidget("TextBlock", Tree)
        pcall(function() Label:SetFont(StyleTile.NameText.Font) end)
        Label:SetText(FText(ModeLabels[Name]))
        local LabelSlot = Button:AddChild(Label)
        LabelSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        LabelSlot:SetHorizontalAlignment(HAlignCenter)
        LabelSlot:SetVerticalAlignment(VAlignCenter)

        local BoxSlot = Bar:AddChildToHorizontalBox(Box)
        BoxSlot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 })
        Buttons[#Buttons + 1] = { Button = Button, Mode = Mode, WasPressed = false }
    end

    -- The scroll box can only append: take the grid out, add the bar,
    -- then put the grid back under it. The tiles stay in the grid.
    ScrollBox:RemoveChild(Grid)
    local BarSlot = ScrollBox:AddChild(Bar)
    BarSlot:SetHorizontalAlignment(HAlignLeft)
    BarSlot:SetVerticalAlignment(VAlignTop)
    BarSlot:SetPadding({ Left = 2, Top = 2, Right = 2, Bottom = 2 })
    local GridSlot = ScrollBox:AddChild(Grid)
    GridSlot:SetHorizontalAlignment(HAlignLeft)
    GridSlot:SetVerticalAlignment(VAlignTop)

    Bars[Storage:GetAddress()] = { Bar = Bar, Buttons = Buttons }
    RefreshButtonColors()
end

------------------------------------------------------------------------
-- Tile labels: a small "value/max" text for the current mode, added to the
-- tile's main overlay (the one holding the owner icon), centred on the icon.
------------------------------------------------------------------------

-- TileLabels[tile address] = TextBlock; LabelTexts[label address] = shown text
local TileLabels = {}
local LabelTexts = {}

local function UpdateTileLabel(Tile, Values)
    local Overlay = Tile.OwnerTypeIcon:GetParent()
    if not Overlay:IsValid() then return end

    local Label = TileLabels[Tile:GetAddress()]
    local Parent = Label and Label:IsValid() and Label:GetParent()
    if not Parent or not Parent:IsValid() or Parent:GetAddress() ~= Overlay:GetAddress() then
        Label = NewWidget("TextBlock", Tile.WidgetTree)
        pcall(function() Label:SetFont(Tile.StackSizeText.Font) end)
        local LabelSlot = Overlay:AddChildToOverlay(Label)
        LabelSlot:SetHorizontalAlignment(HAlignCenter)
        LabelSlot:SetVerticalAlignment(VAlignCenter)
        LabelSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        TileLabels[Tile:GetAddress()] = Label
        -- A freed label's address can come back: forget what it showed.
        LabelTexts[Label:GetAddress()] = nil
    end
    -- No label on auxiliaries: always 1/1, and the stack count is enough.
    local Shown = Values and not IsAuxiliary(Values)
    local Text = Shown and ModeText(Values) or ""
    if LabelTexts[Label:GetAddress()] ~= Text then
        Label:SetText(FText(Text))
        LabelTexts[Label:GetAddress()] = Text
    end
end

-- Layouts[storage address] = { Storage, Count, Items = { { Slot, Row, Column } } }:
-- where the mod last put each tile, to notice when the game moves them back.
local Layouts = {}

local function SortStorage(Storage)
    local Entries = {}
    local StyleTile = nil
    local NumColumns = 0

    ForEachTile(Storage, function(Tile, Slot)
        local Address = Tile:GetAddress()
        if GameOrder[Address] == nil then
            GameOrder[Address] = Slot.Row * 1000 + Slot.Column
        end
        NumColumns = math.max(NumColumns, Slot.Column + 1)
        StyleTile = StyleTile or Tile
        local Values = ReadSkills(Tile)
        local LabelOk, LabelError = pcall(UpdateTileLabel, Tile, Values)
        if not LabelOk then Log("tile label failed: %s", tostring(LabelError)) end
        Entries[#Entries + 1] = {
            Slot = Slot,
            Order = GameOrder[Address],
            Auxiliary = IsAuxiliary(Values),
            Key = SortKey(Values),
        }
    end)
    if #Entries == 0 then return end
    local BarOk, BarError = pcall(AddSortBar, Storage, StyleTile)
    if not BarOk then Log("sort buttons failed on %s: %s", Storage:GetFullName(), tostring(BarError)) end
    if Storage.PreferredNumColumns > 0 then
        NumColumns = math.max(NumColumns, Storage.PreferredNumColumns)
    end

    table.sort(Entries, function(A, B)
        if A.Auxiliary ~= B.Auxiliary then return A.Auxiliary end
        if A.Key ~= B.Key then
            if A.Key == nil then return false end
            if B.Key == nil then return true end
            return A.Key > B.Key
        end
        return A.Order < B.Order
    end)

    local Items = {}
    for Position, Entry in ipairs(Entries) do
        local Row = (Position - 1) // NumColumns
        local Column = (Position - 1) % NumColumns
        if Entry.Slot.Row ~= Row then Entry.Slot:SetRow(Row) end
        if Entry.Slot.Column ~= Column then Entry.Slot:SetColumn(Column) end
        Items[#Items + 1] = { Slot = Entry.Slot, Row = Row, Column = Column }
    end
    Layouts[Storage:GetAddress()] = { Storage = Storage, Count = #Entries, Items = Items }
end

-- Only widgets built at runtime live under /Engine/Transient. The others are
-- templates inside window classes (BPTownCenterWindow_C:WidgetTree...) and
-- must not be touched.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

local function ForEachStorage(Callback)
    for _, Storage in ipairs(FindAllOf("AvatarStorageWidget") or {}) do
        if Storage:IsValid() and IsLiveWidget(Storage) then
            Callback(Storage)
        end
    end
end

-- Defined with the poll loop below; keeps that loop alive.
local EnsurePollLoop

-- A callback handed to the game thread or to a delay can be lost (seen once
-- in a long session: the poll stopped for good, with no error). Anything
-- waiting on one gives up after this long.
local StallSeconds = 3

local function SortAll()
    EnsurePollLoop()
    ForEachStorage(function(Storage)
        local Ok, Error = pcall(SortStorage, Storage)
        if not Ok then Log("sort failed on %s: %s", Storage:GetFullName(), tostring(Error)) end
    end)
end

-- Tiles are created one by one before the grid is complete, and the game
-- may fill their texts a little later: sort the whole batch a few times
-- after the last tile appears. Sorting again changes nothing once in order.
local SortDelays = { 150, 600, 1500 }
local SortPendingAt = nil
local function ScheduleSort()
    local Delayed = SortDelays[#SortDelays] / 1000
    if SortPendingAt and os.time() - SortPendingAt < Delayed + StallSeconds then return end
    SortPendingAt = os.time()
    for Index, Delay in ipairs(SortDelays) do
        ExecuteWithDelay(Delay, function()
            ExecuteInGameThread(function()
                if Index == #SortDelays then SortPendingAt = nil end
                SortAll()
            end)
        end)
    end
end

NotifyOnNewObject(ProfileWidgetClass, function()
    ScheduleSort()
end)

------------------------------------------------------------------------
-- Test bench (Ctrl+F7): shows the game's own storage widget with its ten
-- designer tiles, gives them fake skills and sorts them.
------------------------------------------------------------------------

-- Icons per dominant skill, male and female. Read from the game's own
-- AUIGlobals maps when an instance exists; otherwise these textures, with
-- Fitness on the spearman as a guess.
local IconFolder = "/Game/Textures/UI/Items/"
local SlateVisible, SlateHidden = 0, 2 -- ESlateVisibility
local FallbackIcons = {
    [0] = "IconAvatarSpearman", [1] = "IconAvatarSoldier", [2] = "IconAvatarArcher",
    [3] = "IconAvatarBlacksmith", [4] = "IconAvatarWoodsman", [5] = "IconAvatarHunter",
}

local function LoadTexture(Name)
    local Path = IconFolder .. Name .. "." .. Name
    local Texture = StaticFindObject(Path)
    if not Texture or not Texture:IsValid() then
        LoadAsset(IconFolder .. Name)
        Texture = StaticFindObject(Path)
    end
    if Texture and Texture:IsValid() then return Texture end
    return nil
end

-- Returns { Male = { [skill index] = texture }, Female = { ... } }.
local function AvatarIcons()
    local Icons = { Male = {}, Female = {} }
    local Globals = FindFirstOf("UIGlobals")
    if Globals and Globals:IsValid() then
        pcall(function()
            Globals.AvatarProfileIconMap:ForEach(function(Key, Value) Icons.Male[Key:get()] = Value:get() end)
            Globals.AvatarProfileIconMapFemale:ForEach(function(Key, Value) Icons.Female[Key:get()] = Value:get() end)
        end)
    end
    if next(Icons.Male) ~= nil then
        Log("test bench: icons from UIGlobals")
        return Icons
    end
    for Index, Name in pairs(FallbackIcons) do
        Icons.Male[Index] = LoadTexture(Name)
        Icons.Female[Index] = LoadTexture(Name .. "Female")
    end
    Log("test bench: icons from fallback textures")
    return Icons
end

-- Index of the skill with the highest value (ties: higher max).
local function DominantSkill(Values)
    local Best, BestKey = nil, -1
    for _, Skill in ipairs(Skills) do
        local Key = Values.Current[Skill.Name] * 1000 + Values.Max[Skill.Name]
        if Key > BestKey then Best, BestKey = Skill.Index, Key end
    end
    return Best
end

local function OpenTestBench()
    local Class = StaticFindObject(StorageWidgetBPClass)
    if not Class or not Class:IsValid() then
        LoadAsset(StorageWidgetAsset)
        Class = StaticFindObject(StorageWidgetBPClass)
    end
    if not Class or not Class:IsValid() then
        Log("test bench: cannot load %s", StorageWidgetBPClass)
        return
    end

    local PlayerController = UEHelpers.GetPlayerController()
    if not PlayerController or not PlayerController:IsValid() then
        Log("test bench: no player controller yet")
        return
    end

    local Library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local Widget = Library:Create(PlayerController, Class, PlayerController)
    if not Widget or not Widget:IsValid() then
        Log("test bench: widget creation failed")
        return
    end
    Widget:AddToViewport(100)
    TestBench = Widget

    -- Distinct names make it easy to follow each tile when it moves.
    local Names = { "Aldric", "Brenna", "Cedric", "Dagny", "Edwin",
                    "Freya", "Godric", "Hilda", "Ivo", "Jorun", "Kael", "Liese" }
    local Icons = AvatarIcons()
    local AuxiliaryIcon = LoadTexture("IconAvatarDefault")
    -- The fifth tile (middle of the grid) is a stack of auxiliaries, to see
    -- it jump to the first cell.
    local AuxiliaryTile = 5
    math.randomseed(42)
    local Count = 0
    ForEachTile(Widget, function(Tile)
        Count = Count + 1
        local Values = { Current = {}, Max = {} }
        local Name, Texture, Stack

        if Count == AuxiliaryTile then
            for _, Skill in ipairs(Skills) do
                Values.Max[Skill.Name] = 1
                Values.Current[Skill.Name] = 1
            end
            Name, Texture, Stack = "Auxiliary", AuxiliaryIcon, "12"
        else
            -- Like the game: a max of 3 to 10 per skill, a value from 1 up to that max.
            for _, Skill in ipairs(Skills) do
                local Max = math.random(3, 10)
                Values.Max[Skill.Name] = Max
                Values.Current[Skill.Name] = math.random(1, Max)
            end
            local Set = math.random(2) == 1 and Icons.Male or Icons.Female
            Name, Texture = Names[(Count - 1) % #Names + 1], Set[DominantSkill(Values)]
        end
        FakeSkills[Tile:GetAddress()] = Values

        if Tile.NameText:IsValid() then Tile.NameText:SetText(FText(Name)) end
        if Texture and Tile.ProfileImage:IsValid() then
            Tile.ProfileImage:SetBrushFromTexture(Texture, false)
        end
        -- Only a stack shows its count badge.
        if Tile.StackSizeBox:IsValid() then
            Tile.StackSizeBox:SetVisibility(Stack and SlateVisible or SlateHidden)
        end
        if Stack and Tile.StackSizeText:IsValid() then Tile.StackSizeText:SetText(FText(Stack)) end
    end)
    Log("test bench open: %d tiles with fake skills, mode %s", Count, Modes[CurrentMode])

    SortStorage(Widget)
end

local function CloseTestBench()
    if TestBench and TestBench:IsValid() then TestBench:RemoveFromParent() end
    TestBench = nil
    FakeSkills = {}
    Log("test bench closed")
end

RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            if TestBench and TestBench:IsValid() then CloseTestBench() else OpenTestBench() end
        end)
        if not Ok then Log("test bench error: %s", tostring(Error)) end
    end)
end)

------------------------------------------------------------------------
-- Sort mode (buttons and Ctrl+F6)
------------------------------------------------------------------------

-- Must run on the game thread.
local function SetMode(Mode)
    CurrentMode = Mode
    Log("sort mode: %s", Modes[CurrentMode])
    RefreshButtonColors()
    SortAll()
end

RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        SetMode(CurrentMode % #Modes + 1)
    end)
end)

-- A click is a press followed by a release with the mouse still over the
-- button. Polled every 30 ms, only while at least one bar exists.
local PollQueuedAt = nil
local function PollButtons()
    for Address, Entry in pairs(Bars) do
        if not Entry.Bar:IsValid() then
            Bars[Address] = nil
        else
            for _, Item in ipairs(Entry.Buttons) do
                local Pressed = Item.Button:IsPressed()
                if Item.WasPressed and not Pressed and Item.Button:IsHovered() then
                    Item.WasPressed = false
                    SetMode(Item.Mode)
                    return
                end
                Item.WasPressed = Pressed
            end
        end
    end
end

-- The game puts the tiles back in its own order now and then (seen in the
-- deployment pop-up about half a second after a sort) without creating new
-- tiles. Notice it at the next poll and sort again. Once a second, sort
-- anyway, in case the game changed a tile's avatar without moving it.
local function GameMovedTiles(Layout)
    local Grid = Layout.Storage.AvatarProfileGridPanel
    if Grid:GetChildrenCount() ~= Layout.Count then return true end
    for _, Item in ipairs(Layout.Items) do
        if Item.Slot:IsValid() and (Item.Slot.Row ~= Item.Row or Item.Slot.Column ~= Item.Column) then
            return true
        end
    end
    return false
end

local WatchTicks = 0
local ResortLogged = 0
local function WatchLayouts()
    WatchTicks = WatchTicks + 1
    local Periodic = WatchTicks % 33 == 0
    for Address, Layout in pairs(Layouts) do
        if not Layout.Storage:IsValid() then
            Layouts[Address] = nil
        elseif Periodic or GameMovedTiles(Layout) then
            if not Periodic and ResortLogged < 5 then
                ResortLogged = ResortLogged + 1
                Log("game moved the tiles back, sorting again")
            end
            local Ok, Error = pcall(SortStorage, Layout.Storage)
            if not Ok then
                Layouts[Address] = nil
                Log("re-sort failed: %s", tostring(Error))
            end
        end
    end
end

local function PollUi()
    PollQueuedAt = nil
    WatchLayouts()
    PollButtons()
end

local function PollTick()
    if next(Bars) == nil and next(Layouts) == nil then return end
    if PollQueuedAt then
        if os.time() - PollQueuedAt < StallSeconds then return end
        Log("poll callback was lost, queueing it again")
    end
    PollQueuedAt = os.time()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(PollUi)
        if not Ok then
            PollQueuedAt = nil
            Log("poll error: %s", tostring(Error))
        end
    end)
end

local LastLoopTick = nil
local function StartPollLoop()
    LastLoopTick = os.time()
    LoopAsync(30, function()
        LastLoopTick = os.time()
        local Ok, Error = pcall(PollTick)
        if not Ok then Log("poll loop error: %s", tostring(Error)) end
        return false
    end)
end

EnsurePollLoop = function()
    if os.time() - LastLoopTick < StallSeconds then return end
    Log("poll loop had stopped, starting it again")
    StartPollLoop()
end

StartPollLoop()

------------------------------------------------------------------------
-- Probe (Ctrl+F8): logs what can be read, to settle in a test session
-- where the skills of each tile are available.
------------------------------------------------------------------------

local function TextOf(TextBlock)
    return ReadText(TextBlock) or "<none>"
end

local function ProbeTile(Tile, Slot)
    Log("  tile %s at row %d col %d, address 0x%X", Tile:GetFName():ToString(), Slot.Row, Slot.Column, Tile:GetAddress())
    Log("    name '%s', stack '%s'", TextOf(Tile.NameText), TextOf(Tile.StackSizeText))
    local Tooltip = Tile.AvatarTooltipWidget
    if not Tooltip or not Tooltip:IsValid() then
        Log("    no tooltip widget yet")
        return
    end
    local Details = Tooltip.AvatarProfileDetailsWidget
    if not Details or not Details:IsValid() then
        Log("    tooltip has no details widget")
        return
    end
    local Parts = {}
    for _, Skill in ipairs(Skills) do
        Parts[#Parts + 1] = string.format("%s=%s", Skill.Short, TextOf(Details[Skill.Text]))
    end
    Log("    tooltip name '%s', skills %s", TextOf(Details.NameText), table.concat(Parts, " "))
end

RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local Found = 0
        ForEachStorage(function(Storage)
            Found = Found + 1
            Log("storage %s (PreferredNumColumns %d)", Storage:GetFullName(), Storage.PreferredNumColumns)
            ForEachTile(Storage, function(Tile, Slot)
                local Ok, Error = pcall(ProbeTile, Tile, Slot)
                if not Ok then Log("    probe error: %s", tostring(Error)) end
            end)
        end)
        Log("probe done: %d avatar grid(s)", Found)
    end)
end)

-- The deployment pop-up receives full profiles through a hookable
-- function: log them so we can compare with what the tiles show.
local function OnDeploymentData(_, Success, Data)
    local Ok, Error = pcall(function()
        Log("deployment data received (success %s)", tostring(Success:get()))
        Data:get().AvatarProfiles:ForEach(function(Index, Element)
            local Profile = Element:get()
            local Parts = {}
            for _, Skill in ipairs(Skills) do
                Parts[#Parts + 1] = string.format("%s=%s", Skill.Short, tostring(Profile.Attributes[Skill.Index + 1]))
            end
            Log("  profile %d: id %d, stack %d, %s", Index, Profile.AvatarId, Profile.StackSize, table.concat(Parts, " "))
        end)
    end)
    if not Ok then Log("deployment hook error: %s", tostring(Error)) end
end

local HookOk, HookError = pcall(RegisterHook,
    "/Script/Anvil.DeploymentAvatarWidget:OnDeploymentAvatarDataAtEntityUpdated", OnDeploymentData)
if not HookOk then Log("deployment hook not registered: %s", tostring(HookError)) end

Log("v%s loaded, sort mode %s (Ctrl+F6 mode, Ctrl+F7 test bench, Ctrl+F8 probe)", Version, Modes[CurrentMode])
