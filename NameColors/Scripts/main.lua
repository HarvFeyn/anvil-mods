--[[
    NameColors: changes the colours of player names: each faction's
    (Pagans, Ancients, Remnants) and your guild's. The colours are chosen in
    ModManager (Mods button, Settings) and saved in settings.txt.

    Names are drawn by the HUD's UNameplateComponent, which holds
    NameTypeColourList (five colours, by faction id) and FamilyColour (guild
    members, yellow). Display only: nothing is sent to the server.

    Developer keys (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates):
      Ctrl+F3  probe: log the name colours and the names on screen
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[NameColors] " .. string.format(Format, ...) .. "\n")
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

-- IsValid() only says an object is not deleted yet. An object the game has
-- started to destroy still passes it while its parts are being taken apart,
-- and reading those parts crashed the game (several crashes inside UE4SS's
-- Lua code, 2026-11-03 and 04). IsSafe also refuses objects flagged as being
-- destroyed or unreachable. Every object of the game goes through it before
-- the mod reads or changes anything on it, sub-objects included.
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

-- When the game changes area, it tears down its HUD and windows and builds
-- new ones. Every crash of 2026-11-03 and 04 happened around such a change,
-- while a mod read a widget being built or destroyed. Probe of 2026-11-04:
-- every change (connecting, entering or leaving a cave, back to the menu)
-- is a map load, announced by UE4SS's load map hooks: "start", then the old
-- HUD ends, the new HUD begins, "done" about 0.4 s later. A death and
-- redeploy is not a change of area. The mod touches nothing from "start"
-- until ResumeSeconds after "done", while the old objects are cleared and
-- the new windows finish building.
local ResumeSeconds = 0.3
local Loading = false
local ResumeAt = 0

local HooksOk = pcall(function()
    RegisterLoadMapPreHook(function()
        Loading = true
    end)
    RegisterLoadMapPostHook(function()
        Loading = false
        ResumeAt = os.clock() + ResumeSeconds
    end)
end)
if not HooksOk then Log("load map hooks not available: pausing on HUD changes only") end

-- Backup, in case a change of area ever comes without a map load: the HUD
-- changing (it is replaced at each change) also gives a pause.
-- Searching all objects of the game for the HUD has its own risk: twice a
-- second is enough for a backup.
local LastHud = nil
local NextHudCheck = 0

local function WorldIsSettling()
    if Loading then return true end
    local Now = os.clock()
    if Now >= NextHudCheck then
        NextHudCheck = Now + 0.5
        local Hud = "none"
        for _, Actor in ipairs(FindAllOf("AnvilHUD") or {}) do
            if IsSafe(Actor) and not string.find(Actor:GetFullName(), "Default__", 1, true) then
                Hud = string.format("%X|%s", Actor:GetAddress(), Actor:GetFName():ToString())
                break
            end
        end
        if Hud ~= LastHud then
            if LastHud ~= nil then ResumeAt = math.max(ResumeAt, Now + ResumeSeconds) end
            LastHud = Hud
        end
    end
    return Now < ResumeAt
end

-- No object of the game is kept between key presses: it is found again
-- among the live objects each time (the game destroys its HUD when it
-- changes area).
local function FindNameplates()
    local Found = {}
    for _, Component in ipairs(FindAllOf("NameplateComponent") or {}) do
        if IsSafe(Component) and not string.find(Component:GetFullName(), "Default__", 1, true) then
            Found[#Found + 1] = Component
        end
    end
    return Found
end

-- The four colours UE4SS does not show. NameTypeColourList is FLinearColor[5]
-- at 0x938 in UNameplateComponent and FamilyColour follows at 0x988 (class
-- dump of the 2026-11-03 patch). Each colour component is declared to UE4SS
-- as a float property at its offset: "NameColour2G" is the green of the
-- third colour. Before any use, colour 0 and the family colour read this
-- way must match the ones UE4SS reads itself, or the layout has changed
-- (game patch) and the mod leaves them alone.
local NameplateClass = "/Script/Anvil.NameplateComponent"
local ListOffset, ColourSize, ListCount = 0x938, 0x10, 5
local FamilyOffset = 0x988
local Channels = { "R", "G", "B", "A" }

local CustomOk, CustomError = pcall(function()
    for Index = 0, ListCount - 1 do
        for Channel, Name in ipairs(Channels) do
            RegisterCustomProperty({
                ["Name"] = string.format("NameColour%d%s", Index, Name),
                ["Type"] = PropertyTypes.FloatProperty,
                ["BelongsToClass"] = NameplateClass,
                ["OffsetInternal"] = ListOffset + Index * ColourSize + (Channel - 1) * 4,
            })
        end
    end
    for Channel, Name in ipairs(Channels) do
        RegisterCustomProperty({
            ["Name"] = "FamilyColourCheck" .. Name,
            ["Type"] = PropertyTypes.FloatProperty,
            ["BelongsToClass"] = NameplateClass,
            ["OffsetInternal"] = FamilyOffset + (Channel - 1) * 4,
        })
    end
end)
if not CustomOk then Log("cannot declare the hidden colours: %s", tostring(CustomError)) end

local function ReadHidden(Component, Index)
    local Colour = {}
    for _, Name in ipairs(Channels) do Colour[Name] = Component[string.format("NameColour%d%s", Index, Name)] end
    return Colour
end

local function WriteHidden(Component, Index, Colour)
    for _, Name in ipairs(Channels) do Component[string.format("NameColour%d%s", Index, Name)] = Colour[Name] end
end

local function Same(A, B)
    for _, Name in ipairs(Channels) do
        if math.abs(A[Name] - B[Name]) > 0.0001 then return false end
    end
    return true
end

-- True when the offsets still match this build of the game.
local function LayoutMatches(Component)
    if not CustomOk then return false end
    local Ok, Result = pcall(function()
        local Family = {}
        for _, Name in ipairs(Channels) do Family[Name] = Component["FamilyColourCheck" .. Name] end
        local First = Component.NameTypeColourList
        local FamilyColour = Component.FamilyColour
        return Same(ReadHidden(Component, 0), { R = First.R, G = First.G, B = First.B, A = First.A })
            and Same(Family, { R = FamilyColour.R, G = FamilyColour.G, B = FamilyColour.B, A = FamilyColour.A })
    end)
    return Ok and Result
end

local function ColorText(C)
    local Ok, Text = pcall(function()
        return string.format("%.2f/%.2f/%.2f/%.2f", C.R, C.G, C.B, C.A)
    end)
    return Ok and Text or ("unreadable (" .. type(C) .. ")")
end

-- NameTypeColourList is a fixed-size array (FLinearColor[5]). In the first
-- test UE4SS showed only its first colour: still try the other ways.
local ListSize = 5

local function ReadList(Component)
    local Results = {}
    local Ok, List = pcall(function() return Component.NameTypeColourList end)
    Results[#Results + 1] = "as a value: " .. (Ok and ColorText(List) or "error")
    for Index = 0, ListSize do
        local ItemOk, Item = pcall(function() return List[Index] end)
        if ItemOk and Item ~= nil then
            Results[#Results + 1] = string.format("[%d] %s", Index, ColorText(Item))
        end
    end
    return Results
end

------------------------------------------------------------------------
-- Probe (Ctrl+F3)
------------------------------------------------------------------------

-- UIGlobals. No live actor exists in game (second test, 2026-11-04): the
-- game reads its settings from the class default object, so that is the
-- one to change.
local GlobalsDefault = "/Game/Blueprints/BPUIGlobals.Default__BPUIGlobals_C"

local function FindGlobals()
    for _, ClassName in ipairs({ "BPUIGlobals_C", "UIGlobals" }) do
        for _, Globals in ipairs(FindAllOf(ClassName) or {}) do
            if IsSafe(Globals) and not string.find(Globals:GetFullName(), "Default__", 1, true) then
                return Globals
            end
        end
    end
    local Default = StaticFindObject(GlobalsDefault)
    if Default and IsSafe(Default) then return Default end
    return nil
end

local function ProbeFactionColours()
    local Globals = FindGlobals()
    if not Globals then
        Log("no live UIGlobals")
        return
    end
    local Parts = {}
    local Ok, Error = pcall(function()
        Globals.FactionColourMap:ForEach(function(Key, Value)
            Parts[#Parts + 1] = string.format("%s = %s", tostring(Key:get()), ColorText(Value:get()))
        end)
    end)
    Log("UIGlobals %s faction colours: %s", Globals:GetFName():ToString(),
        Ok and table.concat(Parts, ", ") or ("unreadable: " .. tostring(Error)))
end

RegisterDevKey(Key.F3, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            local Components = FindNameplates()
            Log("probe: %d nameplate component(s)", #Components)
            for _, Component in ipairs(Components) do
                Log("  %s", Component:GetFullName())
                for _, Line in ipairs(ReadList(Component)) do Log("    NameTypeColourList %s", Line) end
                Log("    FamilyColour %s, ChatColor %s", ColorText(Component.FamilyColour), ColorText(Component.ChatColor))
                if LayoutMatches(Component) then
                    for Index = 0, ListCount - 1 do
                        Log("    name colour %d: %s", Index, ColorText(ReadHidden(Component, Index)))
                    end
                else
                    Log("    hidden name colours: layout check failed%s", CustomOk and "" or " (not declared)")
                end
                -- The list keeps pointers to players that may have left: the
                -- game crashed when the probe read the name of one (14:21,
                -- 2026-11-04). Only its length is read; the players come
                -- from the live objects.
                local Count = -1
                pcall(function() Count = Component.NameplateInfos:GetArrayNum() end)
                local Names = {}
                for _, Player in ipairs(FindAllOf("BpVisPlayer_C") or {}) do
                    if IsSafe(Player) and not string.find(Player:GetFullName(), "Default__", 1, true) then
                        Names[#Names + 1] = Player:GetFName():ToString()
                    end
                end
                Log("    %d nameplate(s), %d live player(s): %s", Count, #Names, table.concat(Names, ", "))
            end
            ProbeFactionColours()
            Log("probe done")
        end)
        if not Ok then Log("probe error: %s", tostring(Error)) end
    end)
end)

------------------------------------------------------------------------
-- Applying the player's colours
--
-- Tests of 2026-11-04: the name colours are NameTypeColourList by faction
-- id (0 none, 1 Aranic = Pagans, 2 Mirrish = Ancients, 3 Novan =
-- Remnants, 4 unused grey) and FamilyColour for guild members. The
-- player's own name uses their faction's colour: the game has no colour of
-- its own for it. UIGlobals.FactionColourMap does not colour names.
------------------------------------------------------------------------

-- Settings keys (see modinfo.txt) and the colour each one sets.
local Targets = {
    { Key = "Pagans", Index = 1 },
    { Key = "Ancients", Index = 2 },
    { Key = "Remnants", Index = 3 },
    { Key = "Guild", Family = true },
}

-- settings.txt, written by ModManager: "Pagans = 0.20,0.85,0.10" lines.
-- A colour not in the file keeps the game's own.
local SettingsPath = nil
do
    local Source = debug.getinfo(1, "S").source
    local Folder = Source and string.match(Source, "^@(.*[\\/])Scripts[\\/][^\\/]+$")
    if Folder then SettingsPath = Folder .. "settings.txt" end
end

local function ReadSettings()
    local Wanted = {}
    local Handle = SettingsPath and io.open(SettingsPath, "r")
    if not Handle then return Wanted, "" end
    local Text = Handle:read("a") or ""
    Handle:close()
    for Line in string.gmatch(Text, "[^\r\n]+") do
        local Key, R, G, B = string.match(Line, "^%s*(%w+)%s*=%s*([%d.]+)%s*,%s*([%d.]+)%s*,%s*([%d.]+)")
        if Key then
            Wanted[Key] = { R = tonumber(R), G = tonumber(G), B = tonumber(B), A = 1 }
        end
    end
    return Wanted, Text
end

-- The game's colours of each nameplate component, read before the mod
-- first changed it: Defaults[component identity][key] = colour. The HUD is
-- rebuilt when the game changes area; a new one brings fresh defaults.
local Defaults = {}

local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

local function ReadTarget(Component, Target)
    if Target.Family then
        local C = Component.FamilyColour
        return { R = C.R, G = C.G, B = C.B, A = C.A }
    end
    return ReadHidden(Component, Target.Index)
end

local function WriteTarget(Component, Target, Colour)
    if Target.Family then
        Component.FamilyColour = Colour
    else
        WriteHidden(Component, Target.Index, Colour)
    end
end

local LayoutWarned = false
local LastText = nil

local function ApplyColours()
    if WorldIsSettling() then return end
    local Wanted, Text = ReadSettings()
    if Text ~= LastText then
        LastText = Text
        local Set = {}
        for Key in pairs(Wanted) do Set[#Set + 1] = Key end
        table.sort(Set)
        Log("colours from settings: %s", #Set > 0 and table.concat(Set, ", ") or "none (the game's own)")
    end
    for _, Component in ipairs(FindNameplates()) do
        if not LayoutMatches(Component) then
            if not LayoutWarned then
                LayoutWarned = true
                Log("the game's name colours are not where this version expects them (game update?): left alone")
            end
        else
            local Id = Identity(Component)
            if not Defaults[Id] then
                Defaults[Id] = {}
                for _, Target in ipairs(Targets) do Defaults[Id][Target.Key] = ReadTarget(Component, Target) end
            end
            for _, Target in ipairs(Targets) do
                local Colour = Wanted[Target.Key] or Defaults[Id][Target.Key]
                if not Same(ReadTarget(Component, Target), Colour) then WriteTarget(Component, Target, Colour) end
            end
        end
    end
end

-- Once a second: picks up a new HUD (after a change of area) and changes
-- made in ModManager. A callback queued to the game thread can be lost, so
-- a stuck queue is retried after a few seconds.
local StallSeconds = 3
local PollQueuedAt = nil
LoopAsync(1000, function()
    if PollQueuedAt and os.time() - PollQueuedAt < StallSeconds then return false end
    PollQueuedAt = os.time()
    ExecuteInGameThread(function()
        PollQueuedAt = nil
        local Ok, Error = pcall(ApplyColours)
        if not Ok then Log("apply error: %s", tostring(Error)) end
    end)
    return false
end)

Log("v%s loaded%s, settings %s", Version, DevTools and " (dev key: Ctrl+F3 probe)" or "", tostring(SettingsPath))
