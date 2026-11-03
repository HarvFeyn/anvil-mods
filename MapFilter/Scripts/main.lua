--[[
    MapFilter: shows or hides each kind of icon on the map and the compass.
    Display only: it shrinks icon widgets to nothing, nothing is sent to
    the server.

    An "Icons" button on the map opens a legend: one check box per kind of
    icon seen so far, with the icon itself. Untick a kind to hide it. The
    choices are saved in settings.txt, next to this mod's Scripts folder.

    Keys (game window focused):
      Ctrl+F10  probe: log the map's layout and every map and compass icon
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[MapFilter] " .. string.format(Format, ...) .. "\n")
end

-- EMapIconType (Anvil_enums.hpp, game patch of 2026-11-03).
local IconTypes = {
    [0] = "None", "Player", "DeathMarker", "Spawner", "MinorStructure",
    "MediumStructure", "MajorStructure", "TownCenter", "CampTownCenter",
    "MinorLocation", "MajorLocation", "MarketShop", "Mine", "BeaconTower",
    "BeaconTowerPlayerInfo", "FamilyMarker", "FamilyCenter", "WorldEntrance",
    "Temple", "RelicSite",
}

-- Types that hold several different icons (seen in game: "Mine" holds
-- brigand camps, malachite and animal dens): one legend line per image.
local SplitByImage = {
    Spawner = true, MinorStructure = true, MediumStructure = true, MajorStructure = true,
    MinorLocation = true, Mine = true, WorldEntrance = true,
    -- What a beacon tower sees: players, player homes, and the towers.
    BeaconTowerPlayerInfo = true,
}

-- Icons grouped by their image, whatever their type: the same image can
-- come under different types (brigands under Mine and WorldEntrance).
-- Only images seen on the map (2026-11-03): the game also has brigand 02,
-- wolf, boar, bat and elite den images, unused for now.
local KindByImage = {
    Brigand01MapIcon = "Brigands", Brigand03MapIcon = "Brigands",
    MapIconAnimalDenBear = "BearDens",
    MapIconAnimalDenRaven = "RavenDens",
    MapIconSilverMine = "Mines",
    IconResourceMalachite = "Malachite",
    IconTownCraftingArea = "TownWorkshop",
    IconTownFoodArea = "Tavern",
    -- What a beacon tower sees: the towers, players, player homes.
    MapBeaconBeacon = "BeaconTower",
    MapBeaconPlayer = "PlayersSpotted",
    MapBeaconHomestead = "PlayerHomes",
}

-- The image a merged kind shows in the legend: the family marker's star
-- is rarely seen in game, the family center banner is.
local LegendImages = {
    FamilyCenter = "FamilyCenterKeystoneIcon",
}

-- Types shown as one legend line with another.
local MergedKinds = {
    FamilyMarker = "FamilyCenter",
}

-- Legend names. Kinds not listed here get a name made from their image.
local KindNames = {
    Player = "You",
    DeathMarker = "Death marker",
    FamilyCenter = "Family centers",
    TownCenter = "Towns",
    CampTownCenter = "Camps",
    MarketShop = "Markets",
    BeaconTower = "Beacon towers",
    MajorLocation = "Region names",
    Temple = "Temples",
    RelicSite = "Relic sites",
    Brigands = "Brigands",
    BearDens = "Bear dens",
    RavenDens = "Raven dens",
    Mines = "Mines",
    Malachite = "Malachite",
    TownWorkshop = "Town workshop",
    Tavern = "Tavern",
    PlayersSpotted = "Players spotted",
    PlayerHomes = "Player homes",
    MapPosts = "Map posts",
}

local SlateVisible, SlateCollapsed = 0, 1
local VAlignCenter = 2
local CheckBoxFolder = "/Game/Textures/UI/"
local LegendIconSize = 22
local ButtonColor = { R = 1.0, G = 0.8, B = 0.45, A = 1.0 }
local TextColor = { R = 0.9, G = 0.88, B = 0.82, A = 1.0 }
local DimColor = { R = 0.55, G = 0.55, B = 0.55, A = 1.0 }

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- Only touch live widgets: FindAllOf also returns the Blueprint templates.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

local function NameOf(Object)
    local Ok, Name = pcall(function()
        if Object and Object:IsValid() then return Object:GetFName():ToString() end
        return nil
    end)
    return Ok and Name or nil
end

local function ClassName(Object)
    return NameOf(Object:GetClass()) or "?"
end

local function NewWidget(ClassName, Outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. ClassName), Outer)
end

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

local function DrawnTexture(Image)
    local Ok, Texture = pcall(function()
        local Resource = Image.Brush.ResourceObject
        if Resource:IsValid() then return Resource end
        return nil
    end)
    return Ok and Texture or nil
end

-- The image an icon draws: IconBox (UMapIcon) or MapItemImage (world
-- entity icons), else the type's icon.
local function IconTexture(Icon)
    for _, Field in ipairs({ "IconBox", "MapItemImage" }) do
        local Ok, Image = pcall(function() return Icon[Field] end)
        if Ok and Image and Image:IsValid() then
            local Texture = DrawnTexture(Image)
            if Texture then return Texture end
        end
    end
    local Ok, Texture = pcall(function() return Icon.InstanceProperty.Icon end)
    if Ok and Texture and Texture:IsValid() then return Texture end
    return nil
end

-- Returns the icon's kind and a texture for the legend (nil for text).
local function KindOf(Icon)
    local Ok, Type = pcall(function() return Icon.InstanceProperty.MapActorType end)
    local TypeName = Ok and IconTypes[Type] or "Other"
    local Texture = IconTexture(Icon)
    local Image = NameOf(Texture) or "none"
    if KindByImage[Image] then return KindByImage[Image], Texture end
    if SplitByImage[TypeName] then return TypeName .. ":" .. Image, Texture end
    return MergedKinds[TypeName] or TypeName, Texture
end

local function KindName(Kind)
    if KindNames[Kind] then return KindNames[Kind] end
    -- "Mine:MapIconSomethingNew" -> "Something New"
    local Name = string.match(Kind, ":(.+)$") or Kind
    Name = Name:gsub("^MapIcon", ""):gsub("^Icon", ""):gsub("MapIcon$", "")
    Name = Name:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2")
    return Name
end

------------------------------------------------------------------------
-- Settings: one "Kind = hidden" line per hidden kind, in settings.txt
------------------------------------------------------------------------

local SettingsPath = nil
do
    local Source = debug.getinfo(1, "S").source
    local Folder = Source and string.match(Source, "^@(.*[\\/])Scripts[\\/][^\\/]+$")
    if Folder then SettingsPath = Folder .. "settings.txt" end
end

-- HiddenKinds[kind] = true
local HiddenKinds = {}

-- A kind saved by an older version ("Mine:MapIconAnimalDenBear",
-- "FamilyMarker") as the kind it belongs to now.
local function SavedKind(Kind)
    local Image = string.match(Kind, ":(.+)$")
    return (Image and KindByImage[Image]) or MergedKinds[Kind] or Kind
end

local function LoadSettings()
    if not SettingsPath then return end
    local Handle = io.open(SettingsPath, "r")
    if not Handle then return end
    for Line in Handle:lines() do
        local Kind, Value = string.match(Line, "^%s*([^=#]-)%s*=%s*(%S+)")
        if Kind and Value == "hidden" then HiddenKinds[SavedKind(Kind)] = true end
    end
    Handle:close()
end

local function SaveSettings()
    if not SettingsPath then return end
    local Kinds = {}
    for Kind in pairs(HiddenKinds) do Kinds[#Kinds + 1] = Kind end
    table.sort(Kinds)
    local Handle = io.open(SettingsPath, "w")
    if not Handle then
        Log("cannot write %s", SettingsPath)
        return
    end
    Handle:write("# Map icon kinds hidden by MapFilter. Delete this file to show everything.\n")
    for _, Kind in ipairs(Kinds) do Handle:write(Kind .. " = hidden\n") end
    Handle:close()
end

------------------------------------------------------------------------
-- Hiding. The game resets the visibility of some icons many times a second
-- (towns, markets, beacon towers, family centers). Their render scale held
-- at zero (tested 2026-11-03), but the game sizes icons with the map's zoom,
-- so a shrunk icon came back at the wrong size. An icon is now hidden by
-- making it fully transparent: its colour tint (UserWidget ColorAndOpacity,
-- or an Image's on the compass), which the zoom and the flashing (render
-- opacity) leave alone.
------------------------------------------------------------------------

-- Kinds seen this session: Seen[kind] = { Texture, Count }
local Seen = {}
-- Compass images are matched to a kind by their texture.
local KindByTexture = {}
-- Widgets this mod made transparent: Faded[address] = { Widget, Color before }
local Faded = {}

local function TintOf(Widget)
    local Ok, Color = pcall(function()
        local C = Widget.ColorAndOpacity
        -- An Image's tint is an FLinearColor; a UserWidget's too.
        return { R = C.R, G = C.G, B = C.B, A = C.A }
    end)
    return Ok and Color or nil
end

-- Collapse: also collapse the widget, so a hidden map post cannot be
-- clicked. Not for icons: the game shows some of them again at once.
local function SetFaded(Widget, Hide, Collapse)
    local Address = Widget:GetAddress()
    local Entry = Faded[Address]
    if Hide then
        local Color = TintOf(Widget)
        if Color and Color.A ~= 0 then
            if not Entry then
                Entry = { Widget = Widget, Color = Color, Visibility = Widget:GetVisibility() }
                Faded[Address] = Entry
            end
            Widget:SetColorAndOpacity({ R = Color.R, G = Color.G, B = Color.B, A = 0 })
        end
        if Collapse and Entry and Widget:GetVisibility() ~= SlateCollapsed then Widget:SetVisibility(SlateCollapsed) end
    elseif Entry then
        Widget:SetColorAndOpacity(Entry.Color)
        if Collapse then Widget:SetVisibility(Entry.Visibility) end
        Faded[Address] = nil
    end
end

local LegendChanged = false

local function ApplyToMapIcons()
    local Counts = {}
    for _, Icon in ipairs(FindAllOf("MapIconBase") or {}) do
        if Icon:IsValid() and IsLiveWidget(Icon) then
            local Kind, Texture = KindOf(Icon)
            Counts[Kind] = (Counts[Kind] or 0) + 1
            if not Seen[Kind] then
                Seen[Kind] = { Texture = Texture }
                LegendChanged = true
            elseif Texture and (not Seen[Kind].Texture or NameOf(Texture) == LegendImages[Kind]) then
                Seen[Kind].Texture = Texture
            end
            local TextureName = NameOf(Texture)
            if TextureName then KindByTexture[TextureName] = Kind end
            SetFaded(Icon, HiddenKinds[Kind] == true)
        end
    end
    for Kind, Entry in pairs(Seen) do Entry.Count = Counts[Kind] or 0 end
end

local function ApplyToCompass()
    for _, Compass in ipairs(FindAllOf("CompassWidget") or {}) do
        if Compass:IsValid() and IsLiveWidget(Compass) then
            local Panel = Compass.CompassIconPanel
            for Index = 0, Panel:GetChildrenCount() - 1 do
                local Child = Panel:GetChildAt(Index)
                local Kind = KindByTexture[NameOf(DrawnTexture(Child)) or ""]
                if Kind then SetFaded(Child, HiddenKinds[Kind] == true) end
            end
        end
    end
end

-- Map posts (players' notes on the map) are not map icons: one kind.
local function ApplyToMapPosts()
    local Count = 0
    for _, Post in ipairs(FindAllOf("MapPostWidget") or {}) do
        if Post:IsValid() and IsLiveWidget(Post) then
            Count = Count + 1
            SetFaded(Post, HiddenKinds.MapPosts == true, true)
        end
    end
    if Count > 0 and not Seen.MapPosts then
        Seen.MapPosts = {}
        LegendChanged = true
    end
    if Seen.MapPosts then Seen.MapPosts.Count = Count end
end

local function ApplyAll()
    ApplyToMapIcons()
    ApplyToCompass()
    ApplyToMapPosts()
end

------------------------------------------------------------------------
-- Legend panel on the map
------------------------------------------------------------------------

-- UI = { Map, Button, Panel, List, Rows = { { Check, Kind } }, ButtonWasPressed }
local UI = nil

-- A font for our texts: the map's place names (copied, it is a live struct).
local function MapFont(Size)
    local Font = nil
    pcall(function()
        for _, Icon in ipairs(FindAllOf("MapIcon") or {}) do
            if Icon:IsValid() and IsLiveWidget(Icon) and Icon.LabelBox:IsValid() then
                local F = Icon.LabelBox.Font
                Font = { FontObject = F.FontObject, FontMaterial = F.FontMaterial,
                    TypefaceFontName = F.TypefaceFontName, Size = Size, LetterSpacing = F.LetterSpacing }
                return
            end
        end
    end)
    return Font
end

local function NewText(Tree, Font, Text, Color)
    local Label = NewWidget("TextBlock", Tree)
    if Font then pcall(function() Label:SetFont(Font) end) end
    Label:SetText(FText(Text))
    pcall(function() Label:SetColorAndOpacity({ SpecifiedColor = Color or TextColor, ColorUseRule = 0 }) end)
    return Label
end

-- A check box drawn with the game's own check box textures.
local function NewCheckBox(Tree)
    local Check = NewWidget("CheckBox", Tree)
    pcall(function()
        local Unchecked = LoadObject(CheckBoxFolder, "CheckboxEmpty")
        local Checked = LoadObject(CheckBoxFolder, "CheckboxChecked")
        if not Unchecked or not Checked then return end
        local Style = Check.WidgetStyle
        local function SetBrush(Field, Texture, Brightness)
            local Brush = Style[Field]
            Brush.ResourceObject = Texture
            Brush.ImageSize = { X = 16, Y = 16 }
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
    return Check
end

-- Top of the button, from the top right corner of the map: below the
-- "PRE-ALPHA" banner.
local PanelTop = 170

-- Solid colour boxes, from Slate's white square texture.
local function SetPlainStyle(Button)
    local Ok, Error = pcall(function()
        local White = LoadObject("/Engine/EngineResources/", "WhiteSquareTexture")
        local Style = Button.WidgetStyle
        local function SetBrush(Field, Grey, Alpha)
            local Brush = Style[Field]
            if White then Brush.ResourceObject = White end
            Brush.DrawAs = 3 -- Image
            Brush.TintColor = { SpecifiedColor = { R = Grey, G = Grey, B = Grey, A = Alpha }, ColorUseRule = 0 }
        end
        SetBrush("Normal", 0.12, 0.85)
        SetBrush("Hovered", 0.22, 0.9)
        SetBrush("Pressed", 0.06, 0.9)
    end)
    if not Ok then Log("plain button style not applied (%s)", tostring(Error)) end
end

-- Legend order chosen by the user; kinds not listed come last, by name.
local KindOrder = {
    "MapPosts", "MajorLocation", "Player", "DeathMarker", "PlayersSpotted", "PlayerHomes",
    "FamilyCenter", "TownCenter", "CampTownCenter", "MarketShop", "TownWorkshop", "Tavern",
    "BeaconTower", "Mines", "Malachite", "Brigands", "RavenDens", "BearDens",
}
local KindRank = {}
for Index, Kind in ipairs(KindOrder) do KindRank[Kind] = Index end

local function SortedKinds()
    local Kinds = {}
    for Kind in pairs(Seen) do Kinds[#Kinds + 1] = Kind end
    table.sort(Kinds, function(A, B)
        local RankA, RankB = KindRank[A] or 1000, KindRank[B] or 1000
        if RankA ~= RankB then return RankA < RankB end
        return KindName(A) < KindName(B)
    end)
    return Kinds
end

-- (Re)builds the legend rows from the kinds seen so far.
local function FillLegend()
    local Tree = UI.Map.WidgetTree
    UI.List:ClearChildren()
    UI.Rows = {}
    local Font = MapFont(14)
    for _, Kind in ipairs(SortedKinds()) do
        local Check = NewCheckBox(Tree)
        local Content = NewWidget("HorizontalBox", Tree)

        local IconBox = NewWidget("SizeBox", Tree)
        IconBox:SetWidthOverride(LegendIconSize)
        IconBox:SetHeightOverride(LegendIconSize)
        local Texture = Seen[Kind].Texture
        if Texture then
            local Image = NewWidget("Image", Tree)
            Image:SetBrushFromTexture(Texture, false)
            IconBox:AddChild(Image)
        end
        local IconSlot = Content:AddChildToHorizontalBox(IconBox)
        pcall(function() IconSlot:SetVerticalAlignment(VAlignCenter) end)
        pcall(function() IconSlot:SetPadding({ Left = 6, Top = 0, Right = 6, Bottom = 0 }) end)

        local Label = NewText(Tree, Font, KindName(Kind))
        local LabelSlot = Content:AddChildToHorizontalBox(Label)
        pcall(function() LabelSlot:SetVerticalAlignment(VAlignCenter) end)

        Check:SetContent(Content)
        Check:SetIsChecked(not HiddenKinds[Kind])
        local RowSlot = UI.List:AddChildToVerticalBox(Check)
        pcall(function() RowSlot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 2 }) end)
        UI.Rows[#UI.Rows + 1] = { Check = Check, Kind = Kind }
    end
    LegendChanged = false
end

local function IsPanelOpen()
    return UI.Panel:GetVisibility() ~= SlateCollapsed
end

local function SetPanelOpen(Open)
    UI.Panel:SetVisibility(Open and SlateVisible or SlateCollapsed)
    if Open then FillLegend() end
end

local function FindMap()
    for _, Map in ipairs(FindAllOf("MapWidget") or {}) do
        if Map:IsValid() and IsLiveWidget(Map) then return Map end
    end
    return nil
end

local function AddLegend(Map)
    local Root = Map.WidgetTree.RootWidget
    if not Root:IsValid() or ClassName(Root) ~= "CanvasPanel" then
        Log("map root is %s, not a canvas panel: no Icons button", Root:IsValid() and ClassName(Root) or "missing")
        return false
    end
    local Tree = Map.WidgetTree

    -- The button: a plain dark box like the map's "Win Conditions" panel
    -- (the map's own button texture stretched badly at this size).
    local Button = NewWidget("Button", Tree)
    SetPlainStyle(Button)
    local ButtonLabel = NewText(Tree, MapFont(16), "Icons", ButtonColor)
    local ButtonLabelSlot = Button:AddChild(ButtonLabel)
    pcall(function() ButtonLabelSlot:SetPadding({ Left = 14, Top = 4, Right = 14, Bottom = 4 }) end)
    local ButtonSlot = Root:AddChildToCanvas(Button)
    pcall(function()
        ButtonSlot:SetAutoSize(true)
        ButtonSlot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        ButtonSlot:SetAlignment({ X = 1, Y = 0 })
        ButtonSlot:SetPosition({ X = -24, Y = PanelTop })
        ButtonSlot:SetZOrder(100)
    end)

    -- The legend, under the button.
    local Panel = NewWidget("Border", Tree)
    pcall(function() Panel:SetBrushColor({ R = 0.05, G = 0.05, B = 0.04, A = 0.9 }) end)
    pcall(function() Panel:SetPadding({ Left = 12, Top = 10, Right = 16, Bottom = 10 }) end)
    local Content = NewWidget("VerticalBox", Tree)
    Panel:SetContent(Content)
    Content:AddChildToVerticalBox(NewText(Tree, MapFont(18), "Map icons", ButtonColor))
    local Note = NewText(Tree, MapFont(12), "Untick a kind of icon to hide it.", DimColor)
    local NoteSlot = Content:AddChildToVerticalBox(Note)
    pcall(function() NoteSlot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 8 }) end)
    local Scroll = NewWidget("ScrollBox", Tree)
    local List = NewWidget("VerticalBox", Tree)
    Scroll:AddChild(List)
    local Limit = NewWidget("SizeBox", Tree)
    pcall(function() Limit:SetMaxDesiredHeight(460) end)
    Limit:AddChild(Scroll)
    Content:AddChildToVerticalBox(Limit)
    local PanelSlot = Root:AddChildToCanvas(Panel)
    pcall(function()
        PanelSlot:SetAutoSize(true)
        PanelSlot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        PanelSlot:SetAlignment({ X = 1, Y = 0 })
        PanelSlot:SetPosition({ X = -24, Y = PanelTop + 40 })
        PanelSlot:SetZOrder(100)
    end)

    UI = { Map = Map, Button = Button, Panel = Panel, List = List, Rows = {}, ButtonWasPressed = false }
    SetPanelOpen(false)
    Log("Icons button added to the map")
    return true
end

local function PollLegend()
    if not UI or not UI.Map:IsValid() or not UI.Button:IsValid() then
        UI = nil
        local Map = FindMap()
        if not Map or not AddLegend(Map) then return end
    end
    -- The button: a press then a release with the mouse still over it.
    local Pressed = UI.Button:IsPressed()
    if UI.ButtonWasPressed and not Pressed and UI.Button:IsHovered() then
        SetPanelOpen(not IsPanelOpen())
    end
    UI.ButtonWasPressed = Pressed

    if not IsPanelOpen() then return end
    if LegendChanged then FillLegend() end
    local Changed = false
    for _, Row in ipairs(UI.Rows) do
        local Hide = not Row.Check:IsChecked()
        if Hide ~= (HiddenKinds[Row.Kind] == true) then
            HiddenKinds[Row.Kind] = Hide or nil
            Log("%s: %s", Row.Kind, Hide and "hidden" or "shown")
            Changed = true
        end
    end
    if Changed then
        SaveSettings()
        ApplyAll()
    end
end

------------------------------------------------------------------------
-- Poll: clicks every 30 ms, icons every 300 ms (new icons appear as the
-- map loads and as you explore). A callback queued to the game thread can
-- be lost, so a stuck queue is retried after a few seconds.
------------------------------------------------------------------------

local Ticks = 0
local function PollTick()
    Ticks = Ticks + 1
    local Ok, Error = pcall(PollLegend)
    if not Ok then Log("legend error: %s", tostring(Error)) end
    if Ticks % 10 == 0 then
        Ok, Error = pcall(ApplyAll)
        if not Ok then Log("filter error: %s", tostring(Error)) end
    end
end

local StallSeconds = 3
local PollQueuedAt = nil
LoopAsync(30, function()
    if PollQueuedAt and os.time() - PollQueuedAt < StallSeconds then return false end
    PollQueuedAt = os.time()
    ExecuteInGameThread(function()
        PollQueuedAt = nil
        PollTick()
    end)
    return false
end)

------------------------------------------------------------------------
-- Probe (Ctrl+F10)
------------------------------------------------------------------------

local function LogTree(Widget, Depth)
    if Depth > 4 or not Widget:IsValid() then return end
    Log("%s%s %s", string.rep("  ", Depth), ClassName(Widget), Widget:GetFName():ToString())
    local Ok, Count = pcall(function() return Widget:GetChildrenCount() end)
    if not Ok then return end
    -- The sheets hold hundreds of icons: list the panel, not them.
    if Count > 40 then
        Log("%s  (%d children)", string.rep("  ", Depth), Count)
        return
    end
    for Index = 0, Count - 1 do LogTree(Widget:GetChildAt(Index), Depth + 1) end
end

RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            Log("probe: settings %s", tostring(SettingsPath))
            local Map = FindMap()
            if Map then
                Log("map %s, visible %s, layout:", Map:GetFName():ToString(), tostring(Map:IsVisible()))
                LogTree(Map.WidgetTree.RootWidget, 1)
            end
            ApplyToMapIcons()
            for _, Kind in ipairs(SortedKinds()) do
                Log("  %s (%s): %d icon(s), texture %s, %s", Kind, KindName(Kind), Seen[Kind].Count or 0,
                    tostring(NameOf(Seen[Kind].Texture)), HiddenKinds[Kind] and "hidden" or "shown")
            end
            for _, Compass in ipairs(FindAllOf("CompassWidget") or {}) do
                if Compass:IsValid() and IsLiveWidget(Compass) then
                    local Panel = Compass.CompassIconPanel
                    local Parts = {}
                    for Index = 0, Panel:GetChildrenCount() - 1 do
                        local Child = Panel:GetChildAt(Index)
                        local Texture = NameOf(DrawnTexture(Child)) or ClassName(Child)
                        Parts[#Parts + 1] = Texture .. " -> " .. tostring(KindByTexture[Texture])
                    end
                    Log("compass: %s", table.concat(Parts, ", "))
                end
            end
            Log("probe done")
        end)
        if not Ok then Log("probe error: %s", tostring(Error)) end
    end)
end)

LoadSettings()
Log("v%s loaded (Ctrl+F10 probe), settings %s", Version, tostring(SettingsPath))
