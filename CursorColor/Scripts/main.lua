--[[
    CursorColor: colours the mouse cursor and the bow's aim line.

    Cursors: the game uses hardware cursors, drawn by Windows from image
    files the engine loads from the game's pak (Slate/MouseCursor and the
    sword, hammer and aiming cursors the game switches to on its own). A
    tint cannot be put on them, so the mod writes a small pak of its own,
    zCursorColor_P.pak in Content\Paks, with tinted copies of those images
    under the same paths (CursorPak.lua). The engine reads paks at start:
    a new colour shows at the next start of the game.

    Aim line: the bow's aim line is a mesh on the player's visual actor
    (AVisPlayer.AimMeshComponent) with a dynamic material whose
    "Emissive Colour" parameter is the line's colour; the mod sets it, and
    it shows at once. The part of the line past an obstacle keeps the
    game's orange.

    The colour comes from settings.txt (written by ModManager: Mods button,
    Settings): "Colour = r,g,b". No colour line (ModManager's Default) means no
    colour: the pak is removed and the aim line gets the game's colour back. Display only: nothing is sent to the server.

    Developer key (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates; F1, F2, F3 and F11 are the game's own keys):
      Ctrl+F12  probe: log the colour, the pak and the aim line's material
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[CursorColor] " .. string.format(Format, ...) .. "\n")
end

local ModFolder = nil -- absolute, ends with a slash
local DevTools = false
do
    local Source = debug.getinfo(1, "S").source
    ModFolder = Source and string.match(Source, "^@(.*[\\/])Scripts[\\/][^\\/]+$")
    local ModsFolder = ModFolder and string.match(ModFolder, "^(.*[\\/])[^\\/]+[\\/]$")
    local Handle = ModsFolder and io.open(ModsFolder .. "AnvilModsDev.txt", "r")
    if Handle then
        Handle:close()
        DevTools = true
    end
end

local function RegisterDevKey(KeyName, Callback)
    if DevTools then RegisterKeyBind(KeyName, { ModifierKey.CONTROL }, Callback) end
end

local CursorPak = require("CursorPak")

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

-- Pause around map loads, like the other mods; the aim line cache is
-- forgotten (new player visuals, new materials).
local ResumeSeconds = 0.5
local Loading = false
local ResumeAt = 0
local Applied = {} -- material identity -> colour key set on it
pcall(function()
    RegisterLoadMapPreHook(function()
        Loading = true
        Applied = {}
    end)
    RegisterLoadMapPostHook(function()
        Loading = false
        ResumeAt = os.clock() + ResumeSeconds
    end)
end)

local function WorldIsSettling()
    return Loading or os.clock() < ResumeAt
end

local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

------------------------------------------------------------------------
-- Colour from settings.txt.
------------------------------------------------------------------------

-- No "Colour" line (ModManager's Default) = no colour: Colour is nil, no
-- pak, and the aim line keeps (or gets back) the game's colour.
local SettingsPath = ModFolder and (ModFolder .. "settings.txt")
local Colour = nil
local ColourKey = ""
local LastSettingsText = nil

local function Clamp01(Value)
    if Value ~= Value or Value < 0 then return 0 end -- NaN or below 0
    if Value > 1 then return 1 end
    return Value
end

-- Reads settings.txt; returns true when the colour changed.
local function ReadColour()
    local Text = ""
    local Handle = SettingsPath and io.open(SettingsPath, "r")
    if Handle then
        Text = Handle:read("a") or ""
        Handle:close()
    end
    if Text == LastSettingsText then return false end
    LastSettingsText = Text
    local Wanted = nil
    for Line in string.gmatch(Text, "[^\r\n]+") do
        local Key, R, G, B = string.match(Line, "^%s*(%w+)%s*=%s*([%d.]+)%s*,%s*([%d.]+)%s*,%s*([%d.]+)")
        if Key == "Colour" then
            Wanted = { R = Clamp01(tonumber(R) or 0), G = Clamp01(tonumber(G) or 0), B = Clamp01(tonumber(B) or 0) }
        end
    end
    local Key = Wanted and string.format("%.3f,%.3f,%.3f", Wanted.R, Wanted.G, Wanted.B) or "off"
    if Key == ColourKey then return false end
    Colour, ColourKey = Wanted, Key
    Log("colour %s", Wanted and Key or "none (the game's own)")
    return true
end

------------------------------------------------------------------------
-- The cursor pak.
------------------------------------------------------------------------

-- <game>\Anvil\Binaries\Win64\ue4ss\Mods\CursorColor\ -> <game>\Anvil\
local GameFolder = ModFolder and string.match(ModFolder, "^(.*[\\/])Binaries[\\/]Win64[\\/]ue4ss[\\/]Mods[\\/][^\\/]+[\\/]$")
local GamePak = GameFolder and (GameFolder .. "Content\\Paks\\Anvil-Windows.pak")
local OurPak = GameFolder and (GameFolder .. "Content\\Paks\\zCursorColor_P.pak")
local StatePath = ModFolder and (ModFolder .. "pak.txt") -- what the pak was made from
local PakFormat = 1

local function ReadFile(Path)
    local Handle = Path and io.open(Path, "rb")
    if not Handle then return nil end
    local Data = Handle:read("a")
    Handle:close()
    return Data
end

local function WriteFile(Path, Data)
    local Handle = io.open(Path, "wb")
    if not Handle then return false end
    local Ok = Handle:write(Data) ~= nil
    Handle:close()
    return Ok
end

local function FileSize(Path)
    local Handle = io.open(Path, "rb")
    if not Handle then return nil end
    local Size = Handle:seek("end")
    Handle:close()
    return Size
end

-- What the pak should be made from: the colour and the game's pak (a game
-- update may change its cursors).
local function PakKey()
    return string.format("format %d colour %s game %s", PakFormat, ColourKey, tostring(FileSize(GamePak)))
end

-- Writes the pak when it is missing or made for another colour. The game
-- keeps its paks open but lets them be renamed: the old pak goes to .old
-- (removed at the next start), the new one takes its name.
local function UpdatePak()
    if not OurPak then
        Log("cannot find the game folder from %s: no cursor colour", tostring(ModFolder))
        return true
    end
    if not Colour then
        -- No colour: no pak, the game's own cursors at the next start.
        if FileSize(OurPak) then
            os.remove(OurPak .. ".old")
            local Removed, RemoveError = os.remove(OurPak)
            local Renamed, RenameError = nil, nil
            if not Removed then Renamed, RenameError = os.rename(OurPak, OurPak .. ".old") end
            if not Removed and not Renamed then
                Log("cannot remove the cursor pak yet (%s; %s)", tostring(RemoveError), tostring(RenameError))
                return false
            end
            Log("cursor pak removed: the game's own cursors show at the next start of the game")
        end
        os.remove(StatePath)
        return true
    end
    local Key = PakKey()
    if FileSize(OurPak) and ReadFile(StatePath) == Key then return true end
    local Started = os.clock()
    local Data, Error = CursorPak.Make(GamePak, Colour.R, Colour.G, Colour.B)
    if not Data then
        Log("cannot make the cursor pak: %s", tostring(Error))
        return true -- making it again would fail the same way
    end
    if ReadFile(OurPak) ~= Data then
        local NewPath, OldPath = OurPak .. ".new", OurPak .. ".old"
        if not WriteFile(NewPath, Data) then
            Log("cannot write %s", NewPath)
            return false
        end
        if FileSize(OurPak) then
            os.remove(OldPath)
            if not os.rename(OurPak, OldPath) then os.remove(OurPak) end
        end
        local Ok, RenameError = os.rename(NewPath, OurPak)
        if not Ok then
            Log("cannot put the cursor pak in place yet: %s", tostring(RenameError))
            os.remove(NewPath)
            return false
        end
        Log("cursor pak written (%d bytes, %.0f ms): the new colour shows at the next start of the game",
            #Data, (os.clock() - Started) * 1000)
    end
    WriteFile(StatePath, Key)
    return true
end

------------------------------------------------------------------------
-- The bow's aim line.
------------------------------------------------------------------------

local AimParameter = "Emissive Colour"

local function AimMaterialOf(Player)
    local Component = Player.AimMeshComponent
    if not IsSafe(Component) then return nil end
    local Material = Component:GetMaterial(0)
    if not IsSafe(Material) then return nil end
    -- Only the game's dynamic instance of the aim line material.
    local Name = Material:GetFullName()
    if not string.find(Name, "MaterialInstanceDynamic", 1, true) or not string.find(Name, "AimMesh", 1, true) then return nil end
    return Material
end

-- The game's colour of each aim line material the mod changed (identity ->
-- colour), to put it back when the colour is set to none. Kept across map
-- loads: the materials come from the game instance's cache and can outlive
-- one.
local Original = {}

local function ColourAimLines()
    if WorldIsSettling() then return end
    for _, Player in ipairs(FindAllOf("VisPlayer") or {}) do
        if IsSafe(Player) and not string.find(Player:GetFullName(), "Default__", 1, true) then
            local Ok, Error = pcall(function()
                local Material = AimMaterialOf(Player)
                if not Material then return end
                local Id = Identity(Material)
                if Applied[Id] == ColourKey then return end
                if Colour then
                    if not Original[Id] then
                        local C = Material:K2_GetVectorParameterValue(FName(AimParameter))
                        Original[Id] = { R = C.R, G = C.G, B = C.B, A = C.A }
                    end
                    Material:SetVectorParameterValue(FName(AimParameter), { R = Colour.R, G = Colour.G, B = Colour.B, A = 1.0 })
                elseif Original[Id] then
                    Material:SetVectorParameterValue(FName(AimParameter), Original[Id])
                end
                Applied[Id] = ColourKey
            end)
            if not Ok then Log("aim line error: %s", tostring(Error)) end
        end
    end
end

------------------------------------------------------------------------

-- While the game starts, its pak loading holds our pak without letting it
-- be renamed or removed (seen 2026-11-22: both failed at load, both work
-- once the game is up). A failed change is tried again every 5 s, at most
-- 24 times (2 minutes).
local PakRetries = 0
local NextPakTry = 0

local function TryUpdatePak()
    local Ok, Done = pcall(UpdatePak)
    if not Ok then
        Log("cursor pak error: %s", tostring(Done))
        Done = true
    end
    if Done then
        PakRetries = 0
    else
        PakRetries = PakRetries + 1
        NextPakTry = os.clock() + 5
        if PakRetries > 24 then
            Log("gave up changing the cursor pak: try again at the next start")
            PakRetries = 0
        end
    end
end

ReadColour()
-- A pak replaced in an earlier session is no longer open: remove it.
if OurPak then os.remove(OurPak .. ".old") end
TryUpdatePak()

-- Settings are read again every 2 s (ModManager writes them while the game
-- runs), the aim line checked every second.
local NextSettings = 0
LoopInGameThreadWithDelay(1000, function()
    local Ok, Error = pcall(function()
        local Now = os.clock()
        if Now >= NextSettings then
            NextSettings = Now + 2
            if ReadColour() then
                Applied = {}
                PakRetries = 0
                TryUpdatePak()
            end
        end
        if PakRetries > 0 and Now >= NextPakTry then TryUpdatePak() end
        ColourAimLines()
    end)
    if not Ok then Log("loop error: %s", tostring(Error)) end
end)

RegisterDevKey(Key.F12, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            Log("probe: colour %s, settings %s", ColourKey, tostring(SettingsPath))
            Log("probe: pak %s (%s bytes), state '%s', wanted '%s'", tostring(OurPak), tostring(OurPak and FileSize(OurPak)),
                tostring(ReadFile(StatePath)), PakKey())
            local Shown = 0
            for _, Player in ipairs(FindAllOf("VisPlayer") or {}) do
                if Shown < 4 and IsSafe(Player) and not string.find(Player:GetFullName(), "Default__", 1, true) then
                    Shown = Shown + 1
                    pcall(function()
                        local Material = AimMaterialOf(Player)
                        if not Material then
                            Log("probe: %s: no aim line material", Player:GetFName():ToString())
                            return
                        end
                        local C = Material:K2_GetVectorParameterValue(FName(AimParameter))
                        Log("probe: %s: aim line %s, '%s' = %.2f %.2f %.2f", Player:GetFName():ToString(),
                            tostring(Player.AimMeshComponent:IsVisible()), AimParameter, C.R, C.G, C.B)
                    end)
                end
            end
        end)
        if not Ok then Log("probe error: %s", tostring(Error)) end
    end)
end)

Log("v%s loaded%s", Version, DevTools and " (dev key: Ctrl+F12 probe)" or "")
