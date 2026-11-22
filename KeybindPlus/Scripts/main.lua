--[[
    KeybindPlus: more shortcuts in the game's key settings.

    The game's Keybinds menu (UOptionsMenuKeybindWidget, BPOptionsMenuKeybindWidget)
    is a list of entries (BPAnvilKeyEntryWidget, UAnvilKeyEntryWidget), each
    tied to one of the game's action mappings by its ActionLabel; the
    entry's own code shows the action's key and, when the player picks a
    new one, changes the mapping and saves it like any other key. Some
    actions have no entry, among them the quick item slots SwapItem1 to
    SwapItem8 (keys One ... Eight). On a French AZERTY keyboard those keys
    are named after the character they type (Ampersand, E_AccentAigu ...),
    so the slots never fire, and the player could not change them.

    The mod adds the missing entries to the menu each time it opens; the
    player then binds the keys they want. The mod itself never changes a
    key: the game's entry does, and the game saves it with the player's
    other keys (Saved\Config\Windows\Input.ini), so chosen keys stay even if
    the mod is turned off later. Nothing is sent to the server.
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[KeybindPlus] " .. string.format(Format, ...) .. "\n")
end

local DyingFlags = 0x8000 | 0x10000 -- RF_BeginDestroyed, RF_FinishDestroyed
local InternalDyingFlags = nil
pcall(function()
    DyingFlags = (EObjectFlags.RF_BeginDestroyed or 0x8000) | (EObjectFlags.RF_FinishDestroyed or 0x10000)
end)
pcall(function()
    local Flags = 0
    for _, Name in ipairs({ "Unreachable", "PendingKill", "Garbage" }) do
        if EInternalObjectFlags[Name] then Flags = Flags | EInternalObjectFlags[Name] end
    end
    if Flags ~= 0 then InternalDyingFlags = Flags end
end)

local function IsSafe(Object)
    if not Object then return false end
    local Ok, Safe = pcall(function()
        if not Object:IsValid() then return false end
        if Object:HasAnyFlags(DyingFlags) then return false end
        if InternalDyingFlags and Object:HasAnyInternalFlags(InternalDyingFlags) then return false end
        return true
    end)
    return Ok and Safe == true
end

-- Pause around map loads, like the other mods.
local ResumeSeconds = 0.5
local Loading = false
local ResumeAt = 0
pcall(function()
    RegisterLoadMapPreHook(function() Loading = true end)
    RegisterLoadMapPostHook(function()
        Loading = false
        ResumeAt = os.clock() + ResumeSeconds
    end)
end)

local function WorldIsSettling()
    return Loading or os.clock() < ResumeAt
end

-- Only touch live widgets: FindAllOf also returns the Blueprint templates.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

local function ClassName(Object)
    local Ok, Name = pcall(function() return Object:GetClass():GetFName():ToString() end)
    return Ok and Name or "?"
end

-- The entries added: the game's action and the label shown.
local Entries = {
    { Action = "SwapItem1", Label = "Item Slot 1" },
    { Action = "SwapItem2", Label = "Item Slot 2" },
    { Action = "SwapItem3", Label = "Item Slot 3" },
    { Action = "SwapItem4", Label = "Item Slot 4" },
    { Action = "SwapItem5", Label = "Item Slot 5" },
    { Action = "SwapItem6", Label = "Item Slot 6" },
    { Action = "SwapItem7", Label = "Item Slot 7" },
    { Action = "SwapItem8", Label = "Item Slot 8" },
}
local EntryClassPath = "/Game/UI/BPAnvilKeyEntryWidget.BPAnvilKeyEntryWidget_C"
local EInputTypeAction = 0

-- The actions the game has (action mappings of the input settings).
local function GameActions()
    local Found = {}
    local Settings = StaticFindObject("/Script/Engine.Default__InputSettings")
    if not IsSafe(Settings) then return Found end
    local Mappings = Settings.ActionMappings
    for Index = 1, #Mappings do Found[Mappings[Index].ActionName:ToString()] = true end
    return Found
end

-- The ActionLabel of each entry already in the menu, and the first entry
-- (to copy its slot padding).
local function ReadMenu(Container)
    local Labels, First = {}, nil
    for Index = 0, Container:GetChildrenCount() - 1 do
        local Child = Container:GetChildAt(Index)
        if IsSafe(Child) and ClassName(Child) == "BPAnvilKeyEntryWidget_C" then
            local Ok, Label = pcall(function() return Child.ActionLabel:ToString() end)
            if Ok and Label then Labels[Label] = true end
            First = First or Child
        end
    end
    return Labels, First
end

local Warned = {}
local MenusDone = {} -- menu identity -> true once the entries are in it

local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

local function AddEntries(Menu)
    local Container = Menu.KeybindWidgetContainer
    if not IsSafe(Container) then return end
    local Labels, First = ReadMenu(Container)
    if not First then return end -- the menu is not built yet
    local EntryClass = StaticFindObject(EntryClassPath)
    if not IsSafe(EntryClass) then
        if not Warned.Class then
            Warned.Class = true
            Log("key entry class %s not found (game update?): no entries added", EntryClassPath)
        end
        return
    end
    local Library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not IsSafe(Library) then return end
    local Actions = GameActions()
    local Padding = nil
    pcall(function()
        local P = First.Slot.Padding
        Padding = { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }
    end)
    local Added = 0
    for _, Item in ipairs(Entries) do
        if Labels[Item.Action] then
            -- The game has an entry for it already (game update): leave it.
        elseif not Actions[Item.Action] then
            if not Warned[Item.Action] then
                Warned[Item.Action] = true
                Log("the game has no action %s (game update?): no entry for it", Item.Action)
            end
        else
            local Entry = Library:Create(Menu, EntryClass, nil)
            if IsSafe(Entry) then
                -- Set before the entry is shown: it reads them when built.
                Entry.ActionLabel = FName(Item.Action)
                Entry.LabelText = FText(Item.Label)
                Entry.InputType = EInputTypeAction
                local Slot = Container:AddChild(Entry)
                if Padding and Slot then pcall(function() Slot:SetPadding(Padding) end) end
                Added = Added + 1
            end
        end
    end
    if Added > 0 then Log("%d key entries added to the Keybinds menu", Added) end
end

-- Reset Keybinds puts every action back on its default key, but only the
-- game's own entries show it: the added ones keep showing the old key.
-- After a reset the mod takes its entries out and adds them again, and the
-- new ones read the keys as they are now. The hook only notes the click
-- (it runs inside the game's call); the loop does the work.
local ResetClicked = false
do
    local Ok, Error = pcall(function()
        RegisterHook("/Script/Anvil.OptionsMenuKeybindWidget:OnResetKeyBinds", function()
            ResetClicked = true
        end)
    end)
    if not Ok then Log("reset hook not available (%s): the entries show new keys at the next opening", tostring(Error)) end
end

local OurActions = {}
for _, Item in ipairs(Entries) do OurActions[Item.Action] = true end

-- Takes the added entries out of every open Keybinds menu.
local function RemoveEntries()
    local Removed = 0
    for _, Menu in ipairs(FindAllOf("OptionsMenuKeybindWidget") or {}) do
        if IsSafe(Menu) and IsLiveWidget(Menu) then
            local Container = Menu.KeybindWidgetContainer
            if IsSafe(Container) then
                local Ours = {}
                for Index = 0, Container:GetChildrenCount() - 1 do
                    local Child = Container:GetChildAt(Index)
                    if IsSafe(Child) and ClassName(Child) == "BPAnvilKeyEntryWidget_C" then
                        local Ok, Label = pcall(function() return Child.ActionLabel:ToString() end)
                        if Ok and OurActions[Label] then Ours[#Ours + 1] = Child end
                    end
                end
                for _, Child in ipairs(Ours) do
                    Child:RemoveFromParent()
                    Removed = Removed + 1
                end
            end
            MenusDone[Identity(Menu)] = nil
        end
    end
    return Removed
end

LoopInGameThreadWithDelay(250, function()
    if WorldIsSettling() then return end
    local Ok, Error = pcall(function()
        if ResetClicked then
            ResetClicked = false
            Log("keys reset: %d entries built again", RemoveEntries())
        end
        for _, Menu in ipairs(FindAllOf("OptionsMenuKeybindWidget") or {}) do
            if IsSafe(Menu) and IsLiveWidget(Menu) then
                local Id = Identity(Menu)
                if not MenusDone[Id] then
                    AddEntries(Menu)
                    -- Done once its entries are there (ours or the game's).
                    local Container = Menu.KeybindWidgetContainer
                    if IsSafe(Container) then
                        local Labels = ReadMenu(Container)
                        if Labels[Entries[1].Action] then MenusDone[Id] = true end
                    end
                end
            end
        end
    end)
    if not Ok then Log("error: %s", tostring(Error)) end
end)

Log("v%s loaded", Version)
