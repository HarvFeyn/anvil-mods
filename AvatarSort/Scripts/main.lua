--[[
    AvatarSort: reorders the avatar list (keep, caravan, deployment pop-up).

    Display only: the mod moves existing tiles inside AvatarProfileGridPanel
    by changing their row and column. It never creates, removes or clicks a
    tile, and never calls anything that talks to the server.

    A row of sort buttons is added above each avatar grid, with a "Rested"
    check box that hides the avatars not at full health and stamina.

    Developer keys (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates):
      Ctrl+F6  next sort mode (Level, then each skill)
      Ctrl+F7  test bench (works from the main menu): 6 columns like the
               deployment pop-up, then 4 like the caravan, then closed
      Ctrl+F8  probe: log what the mod can read from every open avatar grid
--]]

local UEHelpers = require("UEHelpers")

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.2.1"

local function Log(Format, ...)
    print("[AvatarSort] " .. string.format(Format, ...) .. "\n")
end

-- Developer keys (probes, test bench) only on the developer's machine:
-- install.ps1 leaves ue4ss\Mods\AnvilModsDev.txt there. Released zips and
-- the pack do not have it, so players get no extra keys.
local DevTools = false
do
    local Source = debug.getinfo(1, "S").source
    local ModsFolder = Source and string.match(Source, "^@(.*[\\/])[^\\/]+[\\/]Scripts[\\/][^\\/]+$")
    local Handle = ModsFolder and io.open(ModsFolder .. "AnvilModsDev.txt", "r")
    if Handle then
        Handle:close()
        DevTools = true
    end
end

local function RegisterDevKey(KeyName, Callback)
    if DevTools then RegisterKeyBind(KeyName, { ModifierKey.CONTROL }, Callback) end
end

-- No object of the game is kept from one poll to the next: the game
-- destroys windows and tiles when it changes area (entering a cave), and
-- touching a destroyed object can crash it (crashes of 2026-11-03 and
-- 2026-11-04, in UE4SS's Lua code). The mod keeps identities (address and
-- unique name) and finds the objects again among the live ones each time.
local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

-- Only widgets built at runtime live under /Engine/Transient. The others are
-- templates inside window classes (BPTownCenterWindow_C:WidgetTree...) and
-- must not be touched.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

-- Skills the game uses, as indices of FAvatarProfile.Attributes
-- (EAnvilAvatarAttributeType). Cooking (6) is not used by the game yet:
-- it is left out on purpose and never counts in the level.
local Skills = {
    { Index = 0, Name = "Fitness",       Short = "Fitness", Text = "FitnessNumberText" },
    { Index = 1, Name = "MeleeCombat",   Short = "Melee", Text = "MeleeCombatNumberText" },
    { Index = 2, Name = "RangedCombat",  Short = "Ranged", Text = "RangedCombatNumberText" },
    { Index = 3, Name = "Blacksmithing", Short = "Smith", Text = "BlacksmithingNumberText" },
    { Index = 4, Name = "LoggingMining", Short = "Logging", Text = "LoggingMiningNumberText" },
    { Index = 5, Name = "Hunting",       Short = "Hunting", Text = "HuntingNumberText" },
}

-- Sort modes, in the order Ctrl+F6 cycles through them and the buttons
-- are shown. "Level" is the sum of the six skills.
local Modes = { "Level" }
local ModeLabels = { Level = "All" }
-- Tooltip of each button, in the game's tooltip style (see AddSortBar).
local SkillTitles = {
    Fitness = "Fitness", MeleeCombat = "Melee Combat", RangedCombat = "Ranged Combat",
    Blacksmithing = "Blacksmithing", LoggingMining = "Logging & Mining", Hunting = "Hunting",
}
local ModeTooltips = {
    Level = {
        Header = "All skills",
        Body = "Sorts avatars by overall level, highest first: the sum of their six skills. Each tile shows this total over the highest total the avatar can reach.",
    },
}
for _, Skill in ipairs(Skills) do
    Modes[#Modes + 1] = Skill.Name
    ModeLabels[Skill.Name] = Skill.Short
    ModeTooltips[Skill.Name] = {
        Header = SkillTitles[Skill.Name],
        Body = "Sorts avatars by " .. SkillTitles[Skill.Name] .. ", highest first. Each tile shows the avatar's current level over its maximum.",
    }
end
local CurrentMode = 1
-- "Rested" filter: when on, only fully rested avatars are shown.
local RestedOnly = false
local RestedTooltip = {
    Header = "Fully rested",
    Body = "Shows only avatars at full health and full stamina. Auxiliaries are always shown.",
}

local StorageWidgetClass = "/Script/Anvil.AvatarStorageWidget"
local ProfileWidgetClass = "/Script/Anvil.AvatarProfileWidget"
local StorageWidgetAsset = "/Game/UI/Gameplay/StructureWindows/Avatars/BPAvatarStorageWidget"
local StorageWidgetBPClass = StorageWidgetAsset .. ".BPAvatarStorageWidget_C"

-- Fake skills for the test bench, keyed by tile identity.
local FakeSkills = {}
-- Fake rested state for the test bench, keyed by tile identity.
local FakeRested = {}
-- Game order of each tile (row * 1000 + column) the first time we saw it,
-- keyed by tile identity. Breaks ties so equal tiles keep the game's order.
local GameOrder = {}
-- The test bench's storage widget, by identity (it is not under
-- /Engine/Transient like the game's windows).
local TestBenchId = nil

-- The storage widgets alive right now, by identity: the game's windows
-- and the test bench.
local function LiveStorages()
    local Live = {}
    for _, Storage in ipairs(FindAllOf("AvatarStorageWidget") or {}) do
        if Storage:IsValid() then
            local Id = Identity(Storage)
            if Id == TestBenchId or IsLiveWidget(Storage) then Live[Id] = Storage end
        end
    end
    return Live
end
local TestBenchColumns = nil

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
    -- The game empties a cell by hiding its image and name (probe,
    -- 2026-11-03), not its tooltip: when an avatar leaves the list (killed,
    -- awaiting ransom), its cell keeps the old skills. Trust the image.
    local Ok, Visibility = pcall(function() return Tile.ProfileImage:GetVisibility() end)
    if Ok and (Visibility == 1 or Visibility == 2) then return nil end -- Collapsed, Hidden
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
    return FakeSkills[Identity(Tile)] or ReadSkillsFromTooltip(Tile)
end

-- Full health and full stamina, read from the tooltip's vitality bars
-- (StatBar.MainBar, a ProgressBar from 0 to 1). Returns true, false, or nil
-- when the bars cannot be read.
local function ReadBarPercent(Bar)
    local Ok, Percent = pcall(function() return Bar.MainBar.Percent end)
    if Ok and type(Percent) == "number" then return Percent end
    return nil
end

local function ReadRested(Tile)
    local Fake = FakeRested[Identity(Tile)]
    if Fake ~= nil then return Fake end
    local Ok, Vitality = pcall(function()
        return Tile.AvatarTooltipWidget.AvatarProfileDetailsWidget.VitalityStatus
    end)
    if not Ok or not Vitality or not Vitality:IsValid() then return nil end
    local Health = ReadBarPercent(Vitality.HealthBar)
    local Stamina = ReadBarPercent(Vitality.StaminaBar)
    if Health == nil or Stamina == nil then return nil end
    return Health >= 0.995 and Stamina >= 0.995
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
local ButtonWidth, ButtonHeight = 46, 22
-- Label size compared with the tile name font.
local LabelFontScale = 1.15
local ActiveColor = { R = 1.0, G = 0.8, B = 0.45, A = 1.0 }
local InactiveColor = { R = 0.55, G = 0.55, B = 0.55, A = 1.0 }

-- The Rested filter is a check box drawn with the game's own textures.
local CheckBoxFolder = "/Game/Textures/UI/"
local CheckBoxTextures = { Unchecked = "CheckboxEmpty", Checked = "CheckboxChecked" }
local CheckBoxSize = 14
local CheckBoxLabelColor = { R = 0.8, G = 0.8, B = 0.8, A = 1.0 }

-- Bars[storage identity] = { BarAddress, Bar = WrapBox, Buttons = { { Button,
--   Mode, WasPressed } }, Check = CheckBox, CheckLabel = TextBlock }. Its
-- widgets live in the storage's tree: only used after finding that very
-- storage among the live ones, with the bar still in its scroll box.
local Bars = {}

local function NewWidget(ClassName, Outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. ClassName), Outer)
end

-- Finds an asset's object, loading the asset if needed. Nil if missing.
local function LoadObject(Folder, Name)
    local Path = Folder .. Name .. "." .. Name
    local Object = StaticFindObject(Path)
    if not Object or not Object:IsValid() then
        LoadAsset(Folder .. Name)
        Object = StaticFindObject(Path)
    end
    if Object and Object:IsValid() then return Object end
    return nil
end

-- The bars whose storage is alive with the bar still first in its scroll
-- box (compared by address, without touching the bar). Bars of storages
-- gone, or whose bar the game removed, are forgotten untouched.
-- Returns { { Storage, Entry } }.
local function LiveBars()
    local Live = LiveStorages()
    local Found = {}
    for Id, Entry in pairs(Bars) do
        local Storage = Live[Id]
        local InPlace = false
        if Storage then
            pcall(function()
                local First = Storage.AvatarProfileGridPanel:GetParent():GetChildAt(0)
                InPlace = First:IsValid() and First:GetAddress() == Entry.BarAddress
            end)
        end
        if InPlace then
            Found[#Found + 1] = { Storage = Storage, Entry = Entry }
        else
            Bars[Id] = nil
        end
    end
    return Found
end

local function RefreshButtonColors()
    for _, Live in ipairs(LiveBars()) do
        local Entry = Live.Entry
        for _, Item in ipairs(Entry.Buttons) do
            local Active = Item.Mode == CurrentMode
            Item.Button:SetBackgroundColor(Active and ActiveColor or InactiveColor)
        end
        if Entry.Check:IsChecked() ~= RestedOnly then Entry.Check:SetIsChecked(RestedOnly) end
        Entry.CheckLabel:SetColorAndOpacity({
            SpecifiedColor = RestedOnly and ActiveColor or CheckBoxLabelColor, ColorUseRule = 0,
        })
    end
end

local TooltipAsset = "/Game/UI/Gameplay/BPTooltipWidget"
local TooltipClass = TooltipAsset .. ".BPTooltipWidget_C"
local SlateCollapsed = 1

-- Gives a button the game's own tooltip (BPTooltipWidget: header and
-- body; its gold footer is hidden), or a plain text tooltip if that widget cannot be made.
local function SetTooltip(Button, Help)
    local Ok, Error = pcall(function()
        local Class = StaticFindObject(TooltipClass)
        if not Class or not Class:IsValid() then
            LoadAsset(TooltipAsset)
            Class = StaticFindObject(TooltipClass)
        end
        local PlayerController = UEHelpers.GetPlayerController()
        local Library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local Tooltip = Library:Create(PlayerController, Class, PlayerController)
        Tooltip.HeaderText:SetText(FText(Help.Header))
        Tooltip.BodyText:SetText(FText(Help.Body))
        for _, Unused in ipairs({ "BodyExtraText", "FooterText", "ResourceBar", "ResourcesContainer", "ResourcesFooterText" }) do
            pcall(function() Tooltip[Unused]:SetVisibility(SlateCollapsed) end)
        end
        Button:SetToolTip(Tooltip)
    end)
    if not Ok then
        Log("game tooltip not available (%s), using plain text", tostring(Error))
        Button:SetToolTipText(FText(Help.Header .. ": " .. Help.Body))
    end
end

-- The bar is the first child of the live storage's scroll box: compared by
-- address, without touching the bar.
local function HasBar(Storage, ScrollBox)
    local Entry = Bars[Identity(Storage)]
    if not Entry then return false end
    local First = ScrollBox:GetChildAt(0)
    return First:IsValid() and First:GetAddress() == Entry.BarAddress
end

-- Adds the button row to a storage widget. StyleTile is one of its tiles,
-- used to copy the game's button style and font.
local function AddSortBar(Storage, StyleTile)
    local Grid = Storage.AvatarProfileGridPanel
    local ScrollBox = Grid:GetParent()
    if not ScrollBox:IsValid() or HasBar(Storage, ScrollBox) then return end

    local Tree = Storage.WidgetTree
    -- A wrap box: in narrow windows (4 columns) the buttons go on two rows.
    local Bar = NewWidget("WrapBox", Tree)
    -- Wrap at the grid's width (62 px tiles, 2 px padding on each side):
    -- the scroll box would otherwise let the row grow as wide as it likes.
    local Columns = Storage.PreferredNumColumns > 0 and Storage.PreferredNumColumns or 6
    pcall(function()
        Bar.WrapSize = Columns * 66
        Bar.bExplicitWrapSize = true
    end)
    local Buttons = {}

    -- Copy the font first: NameText.Font is the tile's live struct.
    local function NewLabel(Text)
        local Label = NewWidget("TextBlock", Tree)
        pcall(function()
            local Font = StyleTile.NameText.Font
            Label:SetFont({
                FontObject = Font.FontObject,
                FontMaterial = Font.FontMaterial,
                TypefaceFontName = Font.TypefaceFontName,
                Size = math.floor(Font.Size * LabelFontScale + 0.5),
                LetterSpacing = Font.LetterSpacing,
            })
        end)
        Label:SetText(FText(Text))
        return Label
    end

    local Entries = {}
    for Mode, Name in ipairs(Modes) do
        Entries[#Entries + 1] = { Mode = Mode, Label = ModeLabels[Name], Help = ModeTooltips[Name] }
    end

    for _, Entry in ipairs(Entries) do
        local Box = NewWidget("SizeBox", Tree)
        Box:SetWidthOverride(ButtonWidth)
        Box:SetHeightOverride(ButtonHeight)

        local Button = NewWidget("Button", Tree)
        pcall(function() Button:SetStyle(StyleTile.ProfileButton.WidgetStyle) end)
        SetTooltip(Button, Entry.Help)
        Box:AddChild(Button)

        local Label = NewLabel(Entry.Label)
        local LabelSlot = Button:AddChild(Label)
        LabelSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        LabelSlot:SetHorizontalAlignment(HAlignCenter)
        LabelSlot:SetVerticalAlignment(VAlignCenter)

        local BoxSlot = Bar:AddChildToWrapBox(Box)
        BoxSlot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 2 })
        Buttons[#Buttons + 1] = { Button = Button, Mode = Entry.Mode, WasPressed = false }
    end

    -- The Rested filter: a check box with its label as content, so a click
    -- on the text toggles it too. It toggles itself; PollButtons notices.
    local Check = NewWidget("CheckBox", Tree)
    local Ok, Error = pcall(function()
        local Unchecked = LoadObject(CheckBoxFolder, CheckBoxTextures.Unchecked)
        local Checked = LoadObject(CheckBoxFolder, CheckBoxTextures.Checked)
        if not Unchecked or not Checked then error("textures not found") end
        local Style = Check.WidgetStyle
        local function SetBrush(Field, Texture, Brightness)
            local Brush = Style[Field]
            Brush.ResourceObject = Texture
            Brush.ImageSize = { X = CheckBoxSize, Y = CheckBoxSize }
            Brush.DrawAs = 3 -- Image
            Brush.TintColor = {
                SpecifiedColor = { R = Brightness, G = Brightness, B = Brightness, A = 1.0 }, ColorUseRule = 0,
            }
        end
        SetBrush("UncheckedImage", Unchecked, 0.85)
        SetBrush("UncheckedHoveredImage", Unchecked, 1.0)
        SetBrush("UncheckedPressedImage", Unchecked, 0.7)
        SetBrush("CheckedImage", Checked, 0.85)
        SetBrush("CheckedHoveredImage", Checked, 1.0)
        SetBrush("CheckedPressedImage", Checked, 0.7)
    end)
    if not Ok then Log("game check box textures not used (%s)", tostring(Error)) end
    SetTooltip(Check, RestedTooltip)
    local CheckLabel = NewLabel("Rested")
    local CheckLabelSlot = Check:SetContent(CheckLabel)
    pcall(function()
        CheckLabelSlot:SetPadding({ Left = 3, Top = 0, Right = 0, Bottom = 0 })
        CheckLabelSlot:SetVerticalAlignment(VAlignCenter)
    end)
    Check:SetIsChecked(RestedOnly)
    local CheckBox = NewWidget("SizeBox", Tree)
    CheckBox:SetHeightOverride(ButtonHeight)
    CheckBox:AddChild(Check)
    local CheckSlot = Bar:AddChildToWrapBox(CheckBox)
    -- A little apart from the sort buttons: it is a setting, not a sort.
    CheckSlot:SetPadding({ Left = 4, Top = 0, Right = 2, Bottom = 2 })

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

    Bars[Identity(Storage)] = {
        BarAddress = Bar:GetAddress(), Bar = Bar, Buttons = Buttons, Check = Check, CheckLabel = CheckLabel,
    }
    RefreshButtonColors()
end

------------------------------------------------------------------------
-- Tile labels: a small "value/max" text for the current mode, added to the
-- tile's main overlay (the one holding the owner icon), centred on the icon.
------------------------------------------------------------------------

-- LabelAddress[tile identity] = address of its label; LabelTexts[tile
-- identity] = shown text. The label is found again among the live tile's
-- overlay children by address, never kept.
local LabelAddress = {}
local LabelTexts = {}

local function FindChildAt(Panel, Address)
    for Index = 0, Panel:GetChildrenCount() - 1 do
        local Child = Panel:GetChildAt(Index)
        if Child:IsValid() and Child:GetAddress() == Address then return Child end
    end
    return nil
end

local function UpdateTileLabel(Tile, Values)
    local Overlay = Tile.OwnerTypeIcon:GetParent()
    if not Overlay:IsValid() then return end

    local TileId = Identity(Tile)
    local Label = LabelAddress[TileId] and FindChildAt(Overlay, LabelAddress[TileId])
    if not Label then
        Label = NewWidget("TextBlock", Tile.WidgetTree)
        pcall(function() Label:SetFont(Tile.StackSizeText.Font) end)
        local LabelSlot = Overlay:AddChildToOverlay(Label)
        LabelSlot:SetHorizontalAlignment(HAlignCenter)
        LabelSlot:SetVerticalAlignment(VAlignCenter)
        LabelSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        LabelAddress[TileId] = Label:GetAddress()
        LabelTexts[TileId] = nil
    end
    -- No label on auxiliaries: always 1/1, and the stack count is enough.
    local Shown = Values and not IsAuxiliary(Values)
    local Text = Shown and ModeText(Values) or ""
    if LabelTexts[TileId] ~= Text then
        Label:SetText(FText(Text))
        LabelTexts[TileId] = Text
    end
end

-- Tiles the Rested filter collapsed: HiddenTiles[tile identity] = the
-- visibility to give back. Always called with a live tile.
local HiddenTiles = {}

local function SetTileHidden(Tile, Hidden)
    local TileId = Identity(Tile)
    local Before = HiddenTiles[TileId]
    if Hidden then
        if Before == nil then HiddenTiles[TileId] = Tile:GetVisibility() end
        -- Checked on every sort: the game may show the tile again.
        if Tile:GetVisibility() ~= SlateCollapsed then Tile:SetVisibility(SlateCollapsed) end
    elseif Before ~= nil then
        Tile:SetVisibility(Before)
        HiddenTiles[TileId] = nil
    end
end

-- Layouts[storage identity] = { Count, Items = { [tile identity] = { Row,
-- Column } } }: where the mod last put each tile, to notice when the game
-- moves them back.
local Layouts = {}

local function SortStorage(Storage)
    local Entries = {}
    local StyleTile = nil
    local NumColumns = 0

    ForEachTile(Storage, function(Tile, Slot)
        local TileId = Identity(Tile)
        if GameOrder[TileId] == nil then
            GameOrder[TileId] = Slot.Row * 1000 + Slot.Column
        end
        NumColumns = math.max(NumColumns, Slot.Column + 1)
        StyleTile = StyleTile or Tile
        local Values = ReadSkills(Tile)
        local LabelOk, LabelError = pcall(UpdateTileLabel, Tile, Values)
        if not LabelOk then Log("tile label failed: %s", tostring(LabelError)) end
        local Auxiliary = IsAuxiliary(Values)
        -- Only named avatars are filtered: never auxiliaries or empty cells,
        -- nor an avatar whose bars cannot be read.
        local Hidden = RestedOnly and Values ~= nil and not Auxiliary and ReadRested(Tile) == false
        SetTileHidden(Tile, Hidden)
        Entries[#Entries + 1] = {
            TileId = TileId,
            Slot = Slot,
            Order = GameOrder[TileId],
            Auxiliary = Auxiliary,
            Hidden = Hidden,
            Key = SortKey(Values),
        }
    end)
    if #Entries == 0 then return end
    local BarOk, BarError = pcall(AddSortBar, Storage, StyleTile)
    if not BarOk then Log("sort buttons failed on %s: %s", Storage:GetFullName(), tostring(BarError)) end
    if Storage.PreferredNumColumns > 0 then
        NumColumns = math.max(NumColumns, Storage.PreferredNumColumns)
    end

    -- Hidden tiles go after everything, empty cells included, so the shown
    -- avatars stay together at the top.
    table.sort(Entries, function(A, B)
        if A.Hidden ~= B.Hidden then return B.Hidden end
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
        Items[Entry.TileId] = { Row = Row, Column = Column }
    end
    Layouts[Identity(Storage)] = { Count = #Entries, Items = Items }
end

local function ForEachStorage(Callback)
    for _, Storage in pairs(LiveStorages()) do Callback(Storage) end
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
    return LoadObject(IconFolder, Name)
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

local function OpenTestBench(Columns)
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
    -- Same column count as the window it stands for.
    pcall(function() Widget.PreferredNumColumns = Columns end)
    Widget:AddToViewport(100)
    TestBenchId = Identity(Widget)
    TestBenchColumns = Columns

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
        FakeSkills[Identity(Tile)] = Values
        if Count ~= AuxiliaryTile then FakeRested[Identity(Tile)] = math.random(2) == 1 end

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
    Log("test bench open: %d columns, %d tiles with fake skills, mode %s", Columns, Count, Modes[CurrentMode])

    SortStorage(Widget)
end

local function CloseTestBench()
    local Bench = TestBenchId and LiveStorages()[TestBenchId]
    if Bench then Bench:RemoveFromParent() end
    TestBenchId = nil
    FakeSkills = {}
    FakeRested = {}
    Log("test bench closed")
end

RegisterDevKey(Key.F7, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            -- Closed, then 6 columns (deployment), 4 columns (caravan), closed.
            local Open = TestBenchId ~= nil and LiveStorages()[TestBenchId] ~= nil
            local Columns = Open and TestBenchColumns
            if Open then CloseTestBench() end
            if not Open then
                OpenTestBench(6)
            elseif Columns == 6 then
                OpenTestBench(4)
            end
        end)
        if not Ok then Log("test bench error: %s", tostring(Error)) end
    end)
end)

------------------------------------------------------------------------
-- Sort mode (buttons and Ctrl+F6)
------------------------------------------------------------------------

-- Must run on the game thread.
local function SetRestedOnly(On)
    RestedOnly = On
    Log("rested filter: %s", On and "on" or "off")
    RefreshButtonColors()
    SortAll()
end

local function SetMode(Mode)
    CurrentMode = Mode
    Log("sort mode: %s", Modes[CurrentMode])
    RefreshButtonColors()
    SortAll()
end

RegisterDevKey(Key.F6, function()
    ExecuteInGameThread(function()
        SetMode(CurrentMode % #Modes + 1)
    end)
end)

-- A click is a press followed by a release with the mouse still over the
-- button. Polled every 30 ms, only while at least one bar exists.
local PollQueuedAt = nil
local function PollButtons()
    for _, Live in ipairs(LiveBars()) do
        local Entry = Live.Entry
        for _, Item in ipairs(Entry.Buttons) do
            local Pressed = Item.Button:IsPressed()
            if Item.WasPressed and not Pressed and Item.Button:IsHovered() then
                Item.WasPressed = false
                SetMode(Item.Mode)
                return
            end
            Item.WasPressed = Pressed
        end
        local Checked = Entry.Check:IsChecked()
        if Checked ~= RestedOnly then
            SetRestedOnly(Checked)
            return
        end
    end
end

-- The game puts the tiles back in its own order now and then (seen in the
-- deployment pop-up about half a second after a sort) without creating new
-- tiles. Notice it at the next poll and sort again. Once a second, sort
-- anyway, in case the game changed a tile's avatar without moving it.
local function GameMovedTiles(Storage, Layout)
    local Grid = Storage.AvatarProfileGridPanel
    if Grid:GetChildrenCount() ~= Layout.Count then return true end
    local Moved = false
    ForEachTile(Storage, function(Tile, Slot)
        local Item = Layout.Items[Identity(Tile)]
        if not Item or Slot.Row ~= Item.Row or Slot.Column ~= Item.Column then Moved = true end
    end)
    return Moved
end

local WatchTicks = 0
local ResortLogged = 0
local function WatchLayouts()
    WatchTicks = WatchTicks + 1
    local Periodic = WatchTicks % 33 == 0
    local Live = LiveStorages()
    for Id, Layout in pairs(Layouts) do
        local Storage = Live[Id]
        if not Storage then
            Layouts[Id] = nil
        elseif Periodic or GameMovedTiles(Storage, Layout) then
            if not Periodic and ResortLogged < 5 then
                ResortLogged = ResortLogged + 1
                Log("game moved the tiles back, sorting again")
            end
            local Ok, Error = pcall(SortStorage, Storage)
            if not Ok then
                Layouts[Id] = nil
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
    -- How the game draws the tile: a greyed tile (seen after an avatar died)
    -- may be disabled, faded, or have its parts hidden.
    local Looks = {}
    for _, Part in ipairs({ "Self", "ProfileButton", "ProfileImage", "NameText", "OwnerTypeIcon" }) do
        local Widget = Part == "Self" and Tile or Tile[Part]
        local Ok, Text = pcall(function()
            return string.format("%s vis %d enabled %s opacity %.2f", Part, Widget:GetVisibility(),
                tostring(Widget:GetIsEnabled()), Widget:GetRenderOpacity())
        end)
        Looks[#Looks + 1] = Ok and Text or (Part .. " ?")
    end
    pcall(function()
        local Resource = Tile.ProfileImage.Brush.ResourceObject
        Looks[#Looks + 1] = "image " .. (Resource:IsValid() and Resource:GetFName():ToString() or "none")
    end)
    -- Since the November 2026 patch the tile has DisableEmptyColor and
    -- DisableInaccessibleColor (a dead avatar awaiting ransom?): log the
    -- colours the game set, to see which part it tints.
    local function ColorText(C)
        return string.format("%.2f/%.2f/%.2f/%.2f", C.R, C.G, C.B, C.A)
    end
    for _, Field in ipairs({ "DisableEmptyColor", "DisableInaccessibleColor" }) do
        pcall(function() Looks[#Looks + 1] = Field .. " " .. ColorText(Tile[Field]) end)
    end
    pcall(function() Looks[#Looks + 1] = "button bg " .. ColorText(Tile.ProfileButton.BackgroundColor) end)
    pcall(function() Looks[#Looks + 1] = "image tint " .. ColorText(Tile.ProfileImage.ColorAndOpacity) end)
    pcall(function() Looks[#Looks + 1] = "tile tint " .. ColorText(Tile.ColorAndOpacity) end)
    pcall(function() Looks[#Looks + 1] = "bounty icon vis " .. Tile.BountyEligibleIcon:GetVisibility() end)
    Log("    %s", table.concat(Looks, ", "))
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
    local Bars = {}
    for _, Name in ipairs({ "HealthBar", "StaminaBar" }) do
        local Ok, Text = pcall(function()
            local Bar = Details.VitalityStatus[Name]
            return string.format("%s main %.3f limit %.3f", Name, Bar.MainBar.Percent, Bar.LimitBar.Percent)
        end)
        Bars[#Bars + 1] = Ok and Text or (Name .. " unreadable")
    end
    Log("    %s, rested %s", table.concat(Bars, ", "), tostring(ReadRested(Tile)))
end

RegisterDevKey(Key.F8, function()
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

Log("v%s loaded, sort mode %s%s", Version, Modes[CurrentMode],
    DevTools and " (dev keys: Ctrl+F6 mode, Ctrl+F7 test bench, Ctrl+F8 probe)" or "")
