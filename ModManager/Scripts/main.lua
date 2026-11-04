--[[
    ModManager: lists the UE4SS mods installed in ue4ss\Mods and turns them
    on or off. A change applies the next time the game starts: a Lua mod
    cannot be unloaded while the game runs.

    Adds a "Mods" button to the main menu (BPOpeningScreen).

    Click Enable or Disable next to a mod. Only mods with a modinfo.txt are
    listed; ModManager itself is locked.

    Keys (game window focused):
      Ctrl+F9  probe: log the main menu's layout and the installed mods
--]]

local UEHelpers = require("UEHelpers")

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.2"

local function Log(Format, ...)
    print("[ModManager] " .. string.format(Format, ...) .. "\n")
end

------------------------------------------------------------------------
-- Installed mods
------------------------------------------------------------------------

-- Folders in ue4ss\Mods that are not mods.
local NotMods = { shared = true }

local function ModsDirectory()
    local Ok, Dirs = pcall(IterateGameDirectories)
    if not Ok or not Dirs then return nil end
    local Win64 = Dirs.Game and Dirs.Game.Binaries and Dirs.Game.Binaries.Win64
    return Win64 and Win64.ue4ss and Win64.ue4ss.Mods
end

local function HasFile(Directory, Name)
    for _, File in pairs(Directory.__files or {}) do
        if string.lower(File.__name) == Name then return true end
    end
    return false
end

-- mods.txt lines "Name : 1" or "Name : 0", by mod name.
local function ReadModsTxt(ModsDir)
    local States = {}
    for _, File in pairs(ModsDir.__files or {}) do
        if string.lower(File.__name) == "mods.txt" then
            local Handle = io.open(File.__absolute_path, "r")
            if Handle then
                for Line in Handle:lines() do
                    local Name, State = string.match(Line, "^%s*([^;:%s][^:]-)%s*:%s*(%d)")
                    if Name then States[Name] = State == "1" end
                end
                Handle:close()
            end
        end
    end
    return States
end

-- Our mods carry a modinfo.txt ("key = value" lines: name, version,
-- description). Mods without one (UE4SS's own, other authors') are not
-- listed: this manager only handles the mods of this repository.
local function ReadModInfo(Directory)
    for _, File in pairs(Directory.__files or {}) do
        if string.lower(File.__name) == "modinfo.txt" then
            local Handle = io.open(File.__absolute_path, "r")
            if not Handle then return nil end
            local Info = {}
            for Line in Handle:lines() do
                local Key, Value = string.match(Line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
                if Key then Info[string.lower(Key)] = Value end
            end
            Handle:close()
            return Info
        end
    end
    return nil
end

-- Returns a list of { Name, Path, Version, Description, EnabledTxt,
-- ModsTxt (true, false or nil), Enabled }, sorted by name, or nil when the
-- Mods folder cannot be found.
local function ListMods()
    local ModsDir = ModsDirectory()
    if not ModsDir then return nil end
    local ModsTxt = ReadModsTxt(ModsDir)
    local List = {}
    for Name, Directory in pairs(ModsDir) do
        local Info = type(Name) == "string" and string.sub(Name, 1, 2) ~= "__" and type(Directory) == "table"
            and Directory.__files and not NotMods[Name] and ReadModInfo(Directory)
        if Info then
            List[#List + 1] = {
                Name = Name,
                Path = Directory.__absolute_path,
                Version = Info.version or "?",
                Description = Info.description or "",
                EnabledTxt = HasFile(Directory, "enabled.txt"),
                ModsTxt = ModsTxt[Name],
                Enabled = HasFile(Directory, "enabled.txt") or ModsTxt[Name] == true,
            }
        end
    end
    table.sort(List, function(A, B) return string.lower(A.Name) < string.lower(B.Name) end)
    return List
end

local function LogMods()
    local List = ListMods()
    if not List then
        Log("Mods folder not found")
        return
    end
    Log("%d mod(s) in ue4ss\\Mods:", #List)
    for _, Mod in ipairs(List) do
        Log("  %-24s enabled.txt %-3s  mods.txt %s", Mod.Name, Mod.EnabledTxt and "yes" or "no",
            Mod.ModsTxt == nil and "-" or (Mod.ModsTxt and "1" or "0"))
    end
end

-- Mods the manager will not turn on (or off), with the reason.
local Locked = {
    ModManager = "it would hide this menu",
}

-- What each mod was when the game started, to show which changes wait
-- for a restart.
local AtStart = {}
for _, Mod in ipairs(ListMods() or {}) do AtStart[Mod.Name] = Mod.Enabled end

-- Sets the mod's line in mods.txt to 1 or 0, if it has one.
local function SetModsTxtLine(Mod, On)
    local Path = string.match(Mod.Path, "^(.*)[/\\][^/\\]+$") .. "\\mods.txt"
    local Handle = io.open(Path, "r")
    if not Handle then return true end
    local Lines, Changed = {}, false
    for Line in Handle:lines() do
        local Name = string.match(Line, "^%s*([^;:%s][^:]-)%s*:%s*%d")
        if Name == Mod.Name then
            Line = Name .. " : " .. (On and "1" or "0")
            Changed = true
        end
        Lines[#Lines + 1] = Line
    end
    Handle:close()
    if not Changed then return true end
    Handle = io.open(Path, "w")
    if not Handle then return false end
    Handle:write(table.concat(Lines, "\n") .. "\n")
    Handle:close()
    return true
end

-- Turns a mod on or off for the next start: its enabled.txt, and its
-- mods.txt line when it has one, whichever file UE4SS reads first.
-- Returns true when done.
local function SetModEnabled(Mod, On)
    local EnabledTxt = Mod.Path .. "\\enabled.txt"
    local Ok = true
    if On then
        local Handle = io.open(EnabledTxt, "w")
        if Handle then Handle:close() else Ok = false end
    else
        local Handle = io.open(EnabledTxt, "r")
        if Handle then
            Handle:close()
            Ok = os.remove(EnabledTxt) ~= nil
        end
    end
    if Ok and Mod.ModsTxt ~= nil then Ok = SetModsTxtLine(Mod, On) end
    if not Ok then Log("could not change %s (files not writable?)", Mod.Name) end
    return Ok
end

------------------------------------------------------------------------
-- Main menu button
------------------------------------------------------------------------

local HAlignCenter = 2
local VAlignCenter = 2
local SlateVisible = 0
local SlateHidden = 2

local function NewWidget(ClassName, Outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. ClassName), Outer)
end

-- Only widgets built at runtime live under /Engine/Transient; the others
-- are templates and must not be touched.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

-- Opening screens UE4SS told us about, instead of searching every object
-- twice a second: in game an old opening screen stays in memory with its
-- buttons gone, and touching a widget being torn down may have crashed the
-- game (crashes of 2026-11-03 and 2026-11-04, both with ModManager on).
-- No object of the game is kept from one tick to the next: the screens,
-- their buttons and the mod's own buttons are found again among the live
-- objects each time, and an identity (address and unique name) tells the
-- same object apart without touching an old one.
-- Screens[i] = { Id, Ready (its buttons were seen), Since }
local Screens = {}
local ScreenWaitSeconds = 30

local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

-- Screens dropped for good (their buttons went): never watched again.
local Forgotten = {}

local function WatchScreen(Screen)
    local Id = Identity(Screen)
    if Forgotten[Id] then return end
    for _, Entry in ipairs(Screens) do
        if Entry.Id == Id then return end
    end
    Screens[#Screens + 1] = { Id = Id, Ready = false, Since = os.time() }
end

local function MenuReady(Screen)
    return Screen.OptionsButton:IsValid() and Screen.ExitButton:IsValid()
end

local function FindMenu()
    if #Screens == 0 then return nil end
    local Live = {}
    for _, Screen in ipairs(FindAllOf("OpeningScreen") or {}) do
        if Screen:IsValid() then Live[Identity(Screen)] = Screen end
    end
    for Index = #Screens, 1, -1 do
        local Entry = Screens[Index]
        local Screen = Live[Entry.Id]
        if not Screen then
            table.remove(Screens, Index)
            Forgotten[Entry.Id] = true
        elseif MenuReady(Screen) then
            Entry.Ready = true
            -- Hidden while the options or credits are open: still the menu.
            return Screen, Screen:IsVisible()
        elseif Entry.Ready or os.time() - Entry.Since > ScreenWaitSeconds then
            -- Its buttons are gone (left for the game) or never came:
            -- never touch it again.
            table.remove(Screens, Index)
            Forgotten[Entry.Id] = true
        end
    end
    return nil
end

local function StartWatchingScreens()
    local Ok, Error = pcall(function()
        NotifyOnNewObject("/Script/Anvil.OpeningScreen", function()
            -- The new screen is found again once built, among the live
            -- objects; templates are created too: only runtime widgets.
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function()
                    pcall(function()
                        for _, Screen in ipairs(FindAllOf("OpeningScreen") or {}) do
                            if Screen:IsValid() and IsLiveWidget(Screen) then WatchScreen(Screen) end
                        end
                    end)
                end)
            end)
        end)
    end)
    if not Ok then Log("cannot watch for the main menu: %s", tostring(Error)) end
    -- A menu already there when the mod loads.
    for _, Screen in ipairs(FindAllOf("OpeningScreen") or {}) do
        if Screen:IsValid() and IsLiveWidget(Screen) then WatchScreen(Screen) end
    end
end

local function ClassName(Object)
    return Object:GetClass():GetFName():ToString()
end

local function SamePanel(A, B)
    return A:IsValid() and B:IsValid() and A:GetAddress() == B:GetAddress()
end

-- The vertical box slot settings of a child, to put it back as it was.
local function SaveSlot(Child)
    local Slot = Child.Slot
    local Saved = {}
    pcall(function()
        local P = Slot.Padding
        Saved.Padding = { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }
    end)
    pcall(function() Saved.Size = { SizeRule = Slot.Size.SizeRule, Value = Slot.Size.Value } end)
    pcall(function() Saved.HAlign = Slot.HorizontalAlignment end)
    pcall(function() Saved.VAlign = Slot.VerticalAlignment end)
    return Saved
end

local function RestoreSlot(Slot, Saved)
    if Saved.Padding then pcall(function() Slot:SetPadding(Saved.Padding) end) end
    if Saved.Size then pcall(function() Slot:SetSize(Saved.Size) end) end
    if Saved.HAlign then pcall(function() Slot:SetHorizontalAlignment(Saved.HAlign) end) end
    if Saved.VAlign then pcall(function() Slot:SetVerticalAlignment(Saved.VAlign) end) end
end

-- Clickables[button address] = { Widget, OnClick, WasPressed }: every
-- button the mod added, polled for clicks.
local Clickables = {}

local function OnClick(Widget, Callback)
    Clickables[Widget:GetAddress()] = { Widget = Widget, OnClick = Callback, WasPressed = false }
end

local function SetLabel(Widget, Text)
    pcall(function() Widget.LabelText = FText(Text) end)
    pcall(function() Widget.ButtonText:SetText(FText(Text)) end)
end

-- A button built like the menu's own (BPAnvilButtonWidget), copied from
-- Model. Height overrides the model's height when given.
local function NewMenuButton(Model, Label, Height)
    local PlayerController = UEHelpers.GetPlayerController()
    local Library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local Widget = Library:Create(PlayerController, Model:GetClass(), PlayerController)
    if not Widget or not Widget:IsValid() then return nil end
    pcall(function() Widget.LabelFontSize = Model.LabelFontSize end)
    pcall(function() Widget.ButtonWidth = Model.ButtonWidth end)
    pcall(function() Widget.ButtonHeight = Height or Model.ButtonHeight end)
    if Height then pcall(function() Widget.SizeBox:SetHeightOverride(Height) end) end
    SetLabel(Widget, Label)
    return Widget
end

-- ModsButton = { MenuId, Address }: the button is only touched through
-- Clickables while its menu is alive.
local ModsButton = nil
local OpenPanel

local function HasButton(Menu)
    return ModsButton ~= nil and ModsButton.MenuId == Identity(Menu)
end

-- Adds a "Mods" button just before Exit, built like the menu's own buttons.
local function AddModsButton(Menu)
    if HasButton(Menu) then return end
    local Model = Menu.OptionsButton
    local Before = Menu.ExitButton
    -- In game the opening screen can outlive its buttons.
    if not Model:IsValid() or not Before:IsValid() then return end
    local Box = Model:GetParent()
    if not Box:IsValid() then return end

    local Widget = NewMenuButton(Model, "Mods")
    if not Widget then
        Log("could not create the Mods button")
        return
    end

    -- A panel can only append: take out Exit and what follows it, add the
    -- button, then put them back with their settings.
    local Moved = {}
    local Index = SamePanel(Before:GetParent(), Box) and Box:GetChildIndex(Before) or -1
    if Index >= 0 then
        while Box:GetChildrenCount() > Index do
            local Child = Box:GetChildAt(Index)
            Moved[#Moved + 1] = { Widget = Child, Slot = SaveSlot(Child) }
            Box:RemoveChild(Child)
        end
    end
    local Slot = Box:AddChild(Widget)
    RestoreSlot(Slot, SaveSlot(Model))
    -- The menu spaces its buttons with Spacer widgets: the one above Exit
    -- now sits above Mods, so add the same gap between Mods and Exit.
    local Added = 0
    pcall(function() Added = Model.SizeBox.HeightOverride end)
    local Gap = Index > 0 and Box:GetChildAt(Index - 1)
    if Gap and Gap:IsValid() and ClassName(Gap) == "Spacer" then
        local Spacer = StaticConstructObject(StaticFindObject("/Script/UMG.Spacer"), Menu.WidgetTree)
        pcall(function() Spacer:SetSize({ X = Gap.Size.X, Y = Gap.Size.Y }) end)
        RestoreSlot(Box:AddChild(Spacer), SaveSlot(Gap))
        pcall(function() Added = Added + Gap.Size.Y end)
    end
    for _, Item in ipairs(Moved) do
        RestoreSlot(Box:AddChild(Item.Widget), Item.Slot)
    end

    -- The box is anchored by its centre (or some point of it) on the menu's
    -- canvas: it grew upwards too and pushed Play onto the logo. Move it
    -- down by the part that grew above, so Play stays where it was.
    local Ok, Error = pcall(function()
        local CanvasSlot = Box.Slot
        local Position = CanvasSlot:GetPosition()
        local Shift = Added * CanvasSlot:GetAlignment().Y
        CanvasSlot:SetPosition({ X = Position.X, Y = Position.Y + Shift })
        Log("menu buttons moved down by %.0f (added height %.0f)", Shift, Added)
    end)
    if not Ok then Log("could not move the menu buttons: %s", tostring(Error)) end

    ModsButton = { MenuId = Identity(Menu), Address = Widget:GetAddress() }
    OnClick(Widget, function() OpenPanel(Menu) end)
    Log("Mods button added to the main menu")
end

------------------------------------------------------------------------
-- Mods panel: covers most of the main menu while open (the menu buttons,
-- logo and Discord button are hidden). One row per mod: a short Enable /
-- Disable button, the mod's name, its state and a short description.
------------------------------------------------------------------------

local RowHeight = 40
local ToggleWidth = 180
local NameWidth = 420
local StateWidth = 320

local OnColor = { R = 0.55, G = 0.85, B = 0.45, A = 1.0 }
local OffColor = { R = 0.6, G = 0.6, B = 0.6, A = 1.0 }
local DisabledColor = { R = 0.85, G = 0.45, B = 0.42, A = 1.0 }
local PendingColor = { R = 1.0, G = 0.8, B = 0.45, A = 1.0 }

-- Where players compare their versions with the latest ones.
local ReleasesUrl = "https://github.com/HarvFeyn/anvil-mods/releases"

-- Panel = { MenuId, Root, List, Hidden = { { Widget, Visibility } } }: only
-- used while its menu is alive.
local Panel = nil

-- The menu buttons' font, copied once. Reading Model.ButtonText.Font gives
-- the live struct: changing its Size shrank the menu's own font each time.
local BaseFont = nil

local function ScaledFont(Model, Scale)
    if not BaseFont then
        local Font = Model.ButtonText.Font
        BaseFont = {
            FontObject = Font.FontObject,
            FontMaterial = Font.FontMaterial,
            TypefaceFontName = Font.TypefaceFontName,
            Size = Font.Size,
            LetterSpacing = Font.LetterSpacing,
        }
    end
    local Font = {}
    for Key, Value in pairs(BaseFont) do Font[Key] = Value end
    Font.Size = math.floor(BaseFont.Size * Scale + 0.5)
    return Font
end

local function NewText(Tree, Model, Scale, Text)
    local Block = NewWidget("TextBlock", Tree)
    pcall(function() Block:SetFont(ScaledFont(Model, Scale)) end)
    Block:SetText(FText(Text))
    return Block
end

local function SetColor(Block, Color)
    pcall(function() Block:SetColorAndOpacity({ SpecifiedColor = Color, ColorUseRule = 0 }) end)
end

local function Fixed(Tree, Child, Width)
    local Box = NewWidget("SizeBox", Tree)
    Box:SetWidthOverride(Width)
    Box:AddChild(Child)
    return Box
end

local function ShowState(Mod, Toggle, State)
    if Locked[Mod.Name] then
        SetLabel(Toggle, "Locked")
    else
        SetLabel(Toggle, Mod.Enabled and "Disable" or "Enable")
    end
    local Pending = Mod.Enabled ~= AtStart[Mod.Name]
    local Text = Mod.Enabled and "On" or "Off"
    if Pending then Text = Text .. " after restart" end
    State:SetText(FText(Text))
    SetColor(State, Pending and PendingColor or (Mod.Enabled and OnColor or DisabledColor))
end

local function AddRow(Tree, Model, Mod)
    local Row = NewWidget("HorizontalBox", Tree)

    local Toggle = NewMenuButton(Model, "", RowHeight)
    if not Toggle then return end
    pcall(function() Toggle.ButtonText:SetFont(ScaledFont(Model, 0.85)) end)
    pcall(function() Toggle.SizeBox:SetWidthOverride(ToggleWidth) end)
    Row:AddChildToHorizontalBox(Toggle)

    -- Name, with the installed version under it.
    local NameBox = NewWidget("VerticalBox", Tree)
    NameBox:AddChildToVerticalBox(NewText(Tree, Model, 1.0, Mod.Name))
    local Version = NewText(Tree, Model, 0.65, "Version " .. Mod.Version)
    SetColor(Version, OffColor)
    NameBox:AddChildToVerticalBox(Version)
    local NameSlot = Row:AddChildToHorizontalBox(Fixed(Tree, NameBox, NameWidth))
    NameSlot:SetVerticalAlignment(VAlignCenter)
    NameSlot:SetPadding({ Left = 24, Top = 0, Right = 0, Bottom = 0 })

    local State = NewText(Tree, Model, 0.9, "")
    local StateSlot = Row:AddChildToHorizontalBox(Fixed(Tree, State, StateWidth))
    StateSlot:SetVerticalAlignment(VAlignCenter)

    local Description = NewText(Tree, Model, 0.75, Mod.Description)
    pcall(function() Description:SetAutoWrapText(true) end)
    SetColor(Description, OffColor)
    local DescriptionSlot = Row:AddChildToHorizontalBox(Description)
    DescriptionSlot:SetVerticalAlignment(VAlignCenter)
    pcall(function() DescriptionSlot:SetSize({ SizeRule = 1, Value = 1 }) end)

    local RowSlot = Panel.List:AddChildToVerticalBox(Row)
    RowSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 10 })

    ShowState(Mod, Toggle, State)
    OnClick(Toggle, function()
        if Locked[Mod.Name] then
            Log("%s is locked: %s", Mod.Name, Locked[Mod.Name])
            return
        end
        if SetModEnabled(Mod, not Mod.Enabled) then
            Mod.Enabled = not Mod.Enabled
            Log("%s turned %s (applies at the next start)", Mod.Name, Mod.Enabled and "on" or "off")
        end
        ShowState(Mod, Toggle, State)
    end)
end

local function FindByName(Widget, Name)
    if Widget:GetFName():ToString() == Name then return Widget end
    local IsPanel, Count = pcall(function() return Widget:GetChildrenCount() end)
    if IsPanel and type(Count) == "number" then
        for Index = 0, Count - 1 do
            local Found = FindByName(Widget:GetChildAt(Index), Name)
            if Found then return Found end
        end
    end
    return nil
end

local function ClosePanel()
    if not Panel then return end
    if Panel.Root:IsValid() then Panel.Root:RemoveFromParent() end
    for _, Item in ipairs(Panel.Hidden) do
        if Item.Widget:IsValid() then Item.Widget:SetVisibility(Item.Visibility) end
    end
    Panel = nil
    -- The panel's buttons are gone with it: forget them, keep the Mods button.
    for Address in pairs(Clickables) do
        if not (ModsButton and Address == ModsButton.Address) then Clickables[Address] = nil end
    end
end

OpenPanel = function(Menu)
    if Panel then return end
    local Model = Menu.OptionsButton
    local Box = Model:GetParent()
    local Canvas = Box:GetParent()
    local Tree = Menu.WidgetTree

    -- Dark background over most of the screen.
    local Root = NewWidget("Border", Tree)
    pcall(function() Root:SetBrushColor({ R = 0.02, G = 0.02, B = 0.02, A = 0.85 }) end)
    pcall(function() Root:SetPadding({ Left = 48, Top = 32, Right = 48, Bottom = 32 }) end)
    local Content = NewWidget("VerticalBox", Tree)
    Root:SetContent(Content)

    local Title = NewText(Tree, Model, 1.5, "Mods")
    Content:AddChildToVerticalBox(Title):SetHorizontalAlignment(HAlignCenter)

    local Note = NewText(Tree, Model, 0.8, "Changes apply the next time the game starts.")
    SetColor(Note, OffColor)
    local NoteSlot = Content:AddChildToVerticalBox(Note)
    NoteSlot:SetHorizontalAlignment(HAlignCenter)
    NoteSlot:SetPadding({ Left = 0, Top = 4, Right = 0, Bottom = 24 })

    local Scroll = NewWidget("ScrollBox", Tree)
    local List = NewWidget("VerticalBox", Tree)
    Scroll:AddChild(List)
    local ScrollSlot = Content:AddChildToVerticalBox(Scroll)
    pcall(function() ScrollSlot:SetSize({ SizeRule = 1, Value = 1 }) end)

    -- Bottom: where to find the latest versions, and Back.
    local Latest = NewText(Tree, Model, 0.7, "Latest versions: " .. ReleasesUrl)
    SetColor(Latest, OffColor)
    local LatestSlot = Content:AddChildToVerticalBox(Latest)
    LatestSlot:SetHorizontalAlignment(HAlignCenter)
    LatestSlot:SetPadding({ Left = 0, Top = 16, Right = 0, Bottom = 0 })

    local Buttons = NewWidget("HorizontalBox", Tree)
    local Releases = NewMenuButton(Model, "Check for updates")
    pcall(function() Releases.ButtonText:SetFont(ScaledFont(Model, 0.85)) end)
    Buttons:AddChildToHorizontalBox(Releases):SetPadding({ Left = 0, Top = 0, Right = 24, Bottom = 0 })
    local Back = NewMenuButton(Model, "Back")
    Buttons:AddChildToHorizontalBox(Back)
    local ButtonsSlot = Content:AddChildToVerticalBox(Buttons)
    ButtonsSlot:SetHorizontalAlignment(HAlignCenter)
    ButtonsSlot:SetPadding({ Left = 0, Top = 12, Right = 0, Bottom = 0 })
    OnClick(Releases, function()
        Log("opening %s", ReleasesUrl)
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LaunchURL(ReleasesUrl)
    end)

    local RootSlot = Canvas:AddChildToCanvas(Root)
    pcall(function()
        RootSlot:SetAnchors({ Minimum = { X = 0.06, Y = 0.08 }, Maximum = { X = 0.94, Y = 0.9 } })
        RootSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        RootSlot:SetAlignment({ X = 0, Y = 0 })
        RootSlot:SetZOrder(100)
    end)

    -- Hide what the panel covers, to put it back as it was on Back.
    local Hidden = {}
    for _, Widget in ipairs({ Box, Menu.DiscordRoleButton, FindByName(Canvas, "Logo"), FindByName(Canvas, "ShardSelectorBorder") }) do
        if Widget and Widget:IsValid() then
            Hidden[#Hidden + 1] = { Widget = Widget, Visibility = Widget:GetVisibility() }
            Widget:SetVisibility(SlateHidden)
        end
    end

    Panel = { MenuId = Identity(Menu), Root = Root, List = List, Hidden = Hidden }
    for _, Mod in ipairs(ListMods() or {}) do
        local Ok, Error = pcall(AddRow, Tree, Model, Mod)
        if not Ok then Log("row for %s failed: %s", Mod.Name, tostring(Error)) end
    end
    OnClick(Back, ClosePanel)
    Log("Mods panel opened")
end

------------------------------------------------------------------------
-- Poll: adds the button when the menu exists, and detects clicks (Lua
-- cannot bind OnClicked). A callback queued to the game thread can be
-- lost, so a stuck queue is retried after a few seconds.
------------------------------------------------------------------------

local Ticks = 0
local function PollUi()
    Ticks = Ticks + 1
    local Menu, Visible = FindMenu()
    if not Menu then
        -- In game: forget every widget of the old menu without touching it.
        Clickables = {}
        ModsButton = nil
        Panel = nil
        return
    end
    local MenuId = Identity(Menu)
    if ModsButton and ModsButton.MenuId ~= MenuId then
        Clickables = {}
        ModsButton = nil
        Panel = nil
    end
    if not Visible then return end
    AddModsButton(Menu)
    if Panel and Panel.MenuId ~= MenuId then Panel = nil end
    for _, Item in pairs(Clickables) do
        local Button = Item.Widget.Button
        local Pressed = Button:IsPressed()
        if Item.WasPressed and not Pressed and Button:IsHovered() then
            Item.WasPressed = false
            Item.OnClick()
            return
        end
        Item.WasPressed = Pressed
    end
end

local StallSeconds = 3
local PollQueuedAt = nil
LoopAsync(50, function()
    if PollQueuedAt and os.time() - PollQueuedAt < StallSeconds then return false end
    PollQueuedAt = os.time()
    ExecuteInGameThread(function()
        PollQueuedAt = nil
        local Ok, Error = pcall(PollUi)
        if not Ok then Log("poll error: %s", tostring(Error)) end
    end)
    return false
end)

------------------------------------------------------------------------
-- Probe (Ctrl+F9)
------------------------------------------------------------------------

local function LogTree(Widget, Depth)
    if Depth > 6 then return end
    local Line = string.rep("  ", Depth) .. ClassName(Widget) .. " " .. Widget:GetFName():ToString()
    local Ok, Slot = pcall(function() return Widget.Slot end)
    if Ok and Slot and Slot:IsValid() then Line = Line .. "  [" .. ClassName(Slot) .. "]" end
    Log("%s", Line)
    local IsPanel, Count = pcall(function() return Widget:GetChildrenCount() end)
    if IsPanel and type(Count) == "number" then
        for Index = 0, Count - 1 do
            LogTree(Widget:GetChildAt(Index), Depth + 1)
        end
    end
end

RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            local Menu = FindMenu()
            if Menu then
                Log("main menu %s, visible %s", Menu:GetFullName(), tostring(Menu:IsVisible()))
                local Box = Menu.OptionsButton:GetParent()
                if Box:IsValid() then LogTree(Box, 0) end
            else
                Log("main menu not found")
            end
            LogMods()
        end)
        if not Ok then Log("probe error: %s", tostring(Error)) end
    end)
end)

StartWatchingScreens()
Log("v%s loaded (Ctrl+F9 probe)", Version)
