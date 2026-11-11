--[[
    QuickBounty: removes the pause after handing in a bounty or taking the
    silver on the bounty board.

    Probe of 2026-11-04: the game shows LoadingBox while it waits for the
    server (under 0.2 s), then a message ("Bounty complete", "Bounty Silver
    has been transferred...") for about 2 s over the bounty list, with the
    withdraw button disabled. The mod hides that message as soon as the
    LoadingBox is gone, with the game's own HideBountyStatusMessageBox. It
    never touches the LoadingBox: while the game waits for the server,
    everything stays blocked as before.

    It also shows the final silver on the withdraw button at once (the game
    counts up to it), and enables that button as soon as the server has
    answered: the game kept it greyed ~2 s more, a delay of the window only
    (closing and opening the window skipped it). Same requests as the game.

    Bounties the player can hand in now (the item a bounty shows it wants,
    found in the player's inventory widget in that number) move to the top
    of the list, in a gold frame. The game's click functions
    are hooked, so the mod watches the window closely only for a few seconds
    after a click; otherwise it checks twice a second whether it is open.

    Developer keys (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates):
      Ctrl+F5  probe: log the bounty board window's layout, then for 6 s
               every 100 ms what changes in it (hand in a bounty meanwhile)
      Ctrl+F6  probe: what each bounty asks for, and the inventory widgets
      Ctrl+F7  check: each inventory copy, the counts used, the ready bounties
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.2.0"

local function Log(Format, ...)
    print("[QuickBounty] " .. string.format(Format, ...) .. "\n")
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
local ResumeSeconds = 0.5
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

local Visibilities = { [0] = "Visible", "Collapsed", "Hidden", "HitTestInvisible", "SelfHitTestInvisible" }

-- Only touch live widgets: FindAllOf also returns the Blueprint templates.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

local function ClassName(Object)
    local Ok, Name = pcall(function() return Object:GetClass():GetFName():ToString() end)
    return Ok and Name or "?"
end

-- Objects of the game are never kept from one tick to the next: the game
-- destroys windows and player data when it changes area (entering a cave),
-- and touching a destroyed object crashed the game (crash of 2026-11-04 at
-- a cave entrance, in UE4SS's Lua code). Each tick finds them again
-- among the live objects. An identity (address and unique name) tells the
-- same object apart without touching an old one.
local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

-- The open bounty board window, or the one with this identity.
local function FindWindow(WantedIdentity)
    for _, Window in ipairs(FindAllOf("BountyBoardWindow") or {}) do
        if IsSafe(Window) and IsLiveWidget(Window) then
            if WantedIdentity then
                if Identity(Window) == WantedIdentity then return Window end
            elseif Window:IsVisible() then
                return Window
            end
        end
    end
    return nil
end

local function ReadText(TextBlock)
    local Ok, Text = pcall(function() return TextBlock.Text:ToString() end)
    return Ok and Text or "?"
end

-- The silver waiting on the bounty board, as the server sent it:
-- UPlayerControllerDataComponent.BountySilver. The withdraw button counts
-- up to it slowly after a hand-in; the mod shows it at once.
-- Only used when there is exactly one such component (the local player).
local SilverDataCount = 0

local function FindSilverData()
    local Found = {}
    for _, Data in ipairs(FindAllOf("PlayerControllerDataComponent") or {}) do
        if IsSafe(Data) and not string.find(Data:GetFullName(), "Default__", 1, true) then
            Found[#Found + 1] = Data
        end
    end
    SilverDataCount = #Found
    if #Found == 1 then return Found[1] end
    return nil
end

local function ReadSilver()
    local Data = FindSilverData()
    if not Data then return nil end
    local Ok, Silver = pcall(function() return Data.BountySilver end)
    return Ok and Silver or nil
end

-- "Visible, enabled, opacity 1.00" for one widget, or "missing".
local function Looks(Widget)
    local Ok, Text = pcall(function()
        if not Widget or not IsSafe(Widget) then return "missing" end
        local Visibility = Widget:GetVisibility()
        return string.format("%s%s%s", Visibilities[Visibility] or tostring(Visibility),
            Widget:GetIsEnabled() and "" or " disabled",
            Widget:GetRenderOpacity() < 1 and string.format(" opacity %.2f", Widget:GetRenderOpacity()) or "")
    end)
    return Ok and Text or "?"
end

local function LogTree(Widget, Depth)
    if Depth > 7 or not Widget or not IsSafe(Widget) then return end
    Log("%s%s %s: %s", string.rep("  ", Depth), ClassName(Widget), Widget:GetFName():ToString(), Looks(Widget))
    local Ok, Count = pcall(function() return Widget:GetChildrenCount() end)
    if not Ok then return end
    for Index = 0, Count - 1 do LogTree(Widget:GetChildAt(Index), Depth + 1) end
end

-- One line describing everything that may block the window.
local function State(Window)
    local Parts = {
        "window " .. Looks(Window),
        "loading " .. Looks(Window.LoadingBox),
        "status " .. Looks(Window.SubmitBountyStatusMessageBox) .. " '" .. ReadText(Window.SubmitBountyStatusMessageText) .. "'",
        "list " .. Looks(Window.BountyListView),
        "withdraw box " .. Looks(Window.WithdrawSilverBox),
        "withdraw button " .. Looks(Window.WithdrawSilverButton) .. " '" .. ReadText(Window.WithdrawSilverText) .. "'",
        "hint '" .. ReadText(Window.SubmitBountyHintText) .. "'",
    }
    pcall(function() Parts[#Parts + 1] = "throbber " .. Looks(Window.InventoryThrobber) end)
    -- The hand-in buttons of the bounties shown.
    local Enabled, Total = 0, 0
    for _, Bounty in ipairs(FindAllOf("BountyWidget") or {}) do
        if IsSafe(Bounty) and IsLiveWidget(Bounty) then
            local Ok, On = pcall(function() return Bounty.SubmitBountyButton:GetIsEnabled() end)
            Total = Total + 1
            if Ok and On then Enabled = Enabled + 1 end
        end
    end
    Parts[#Parts + 1] = string.format("hand-in buttons enabled %d of %d", Enabled, Total)
    Parts[#Parts + 1] = string.format("silver data %s (%d component(s))", tostring(ReadSilver()), SilverDataCount)
    return table.concat(Parts, ", ")
end

local Sampling = false

RegisterDevKey(Key.F5, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            if Sampling then return end
            local Window = FindWindow()
            if not Window then
                Log("probe: no bounty board window open")
                return
            end
            local WindowIdentity = Identity(Window)
            Log("probe: %s, layout:", Window:GetFName():ToString())
            LogTree(Window.WidgetTree.RootWidget, 1)
            Sampling = true
            local Last = nil
            local Samples = 0
            local function Sample()
                ExecuteInGameThread(function()
                    local SampleOk, SampleError = pcall(function()
                        local Window = FindWindow(WindowIdentity)
                        if not Window then
                            Log("window closed")
                            Samples = 60
                            return
                        end
                        local Now = State(Window)
                        -- Log only what changed, with the time since the key press.
                        if Now ~= Last then
                            Log("+%d ms: %s", math.floor(Samples * 100), Now)
                            Last = Now
                        end
                    end)
                    if not SampleOk then Log("sample error: %s", tostring(SampleError)) end
                    Samples = Samples + 1
                    if Samples < 60 then
                        ExecuteInGameThreadWithDelay(100, Sample)
                    else
                        Sampling = false
                        Log("probe done")
                    end
                end)
            end
            Sample()
        end)
        if not Ok then
            Sampling = false
            Log("probe error: %s", tostring(Error))
        end
    end)
end)

-- Probe (Ctrl+F6): what a bounty asks for, and what the player's inventory
-- widgets show, to find a way to tell which bounties can be handed in.
local function TextureName(Image)
    local Ok, Name = pcall(function()
        local Resource = Image.Brush.ResourceObject
        if not Resource or not IsSafe(Resource) then return "none" end
        return Resource:GetFName():ToString()
    end)
    return Ok and Name or "?"
end

local function ProbeBounties()
    local Count = 0
    for _, Bounty in ipairs(FindAllOf("BountyWidget") or {}) do
        if IsSafe(Bounty) and IsLiveWidget(Bounty) then
            Count = Count + 1
            local Ok, Error = pcall(function()
                local Resource = Bounty.BountyResourceWidget
                Log("bounty %s %s: header '%s', description '%s', stack '%s', silver '%s', root %s, button %s",
                    Bounty:GetFName():ToString(), Looks(Bounty), ReadText(Bounty.HeaderText),
                    ReadText(Bounty.DescriptionText), ReadText(Bounty.StackSizeText), ReadText(Bounty.BountySilverText),
                    ClassName(Bounty.WidgetTree.RootWidget), Looks(Bounty.SubmitBountyButton))
                if IsSafe(Resource) then
                    Log("    asks: name '%s', cost '%s', icon %s", ReadText(Resource.ResourceNameText),
                        ReadText(Resource.ResourceCostText), TextureName(Resource.ResourceIcon))
                else
                    Log("    no resource widget")
                end
            end)
            if not Ok then Log("    bounty error: %s", tostring(Error)) end
        end
    end
    Log("%d live bounty widget(s)", Count)
    pcall(function()
        local Window = FindWindow()
        if not Window then return end
        local Entries = Window.BountyListView:GetDisplayedEntryWidgets()
        Log("GetDisplayedEntryWidgets returned a %s", type(Entries))
        pcall(function() Log("  #%d, first %s", #Entries, tostring(Entries[1])) end)
    end)
end

local function ProbeInventories()
    for _, ClassNameWanted in ipairs({ "InventoryWidget", "InventoryHUDWidget", "InventoryAvatarWidget" }) do
        for _, Grid in ipairs(FindAllOf(ClassNameWanted) or {}) do
            if IsSafe(Grid) and IsLiveWidget(Grid) then
                local Ok, Error = pcall(function()
                    local Player = ""
                    pcall(function() Player = Grid.bIsPlayerInventory and " player" or " not player" end)
                    local Parts = {}
                    for Index = 0, Grid:GetChildrenCount() - 1 do
                        local Item = Grid:GetChildAt(Index)
                        if IsSafe(Item) then
                            local Icon, Quantity = "?", "?"
                            pcall(function() Icon = TextureName(Item.ItemImage) end)
                            pcall(function() Quantity = ReadText(Item.ItemQuantityText) end)
                            if Icon ~= "none" and Icon ~= "?" then
                                Parts[#Parts + 1] = string.format("%s x%s", Icon, Quantity)
                            end
                        end
                    end
                    Log("%s %s%s, %s, %d slots: %s", ClassNameWanted, Grid:GetFullName(), Player, Looks(Grid),
                        Grid:GetChildrenCount(), table.concat(Parts, ", "))
                end)
                if not Ok then Log("inventory error: %s", tostring(Error)) end
            end
        end
    end
end

RegisterDevKey(Key.F6, function()
    ExecuteInGameThread(function()
        Log("bounty probe:")
        local Ok, Error = pcall(ProbeBounties)
        if not Ok then Log("bounty probe error: %s", tostring(Error)) end
        Ok, Error = pcall(ProbeInventories)
        if not Ok then Log("inventory probe error: %s", tostring(Error)) end
        Log("bounty probe done")
    end)
end)

------------------------------------------------------------------------
-- Hide the status message once the server has answered
------------------------------------------------------------------------

local SlateCollapsed = 1
local SlateVisible = 0
local SlateHitTestInvisible = 3

local function IsShown(Widget)
    local Ok, Visibility = pcall(function() return Widget:GetVisibility() end)
    return Ok and Visibility ~= SlateCollapsed and Visibility ~= 2 -- Hidden
end

-- Messages seen in game (2026-11-04), in English: "Bounty complete",
-- "Bounty Silver has been transferred to your inventory".
local function IsSuccessMessage(Message)
    local Lower = string.lower(Message)
    return Lower == "bounty complete" or string.find(Lower, "has been transferred", 1, true) ~= nil
end

-- The game shows a message for about 2 s.
local ErrorSeconds = 1.0
-- The error message on screen and when it appeared (os.clock is wall time
-- on Windows).
local ErrorShown = nil

local Ticks = 0

-- Puts the final amount on the withdraw button instead of letting it count
-- up. Setting the text replaces the game's own text binding until the
-- window is built again, so it is kept up to date at every check.
local function ShowFinalSilver(Window, Silver)
    if type(Silver) ~= "number" then return end
    local Text = string.format("%dx", Silver)
    if ReadText(Window.WithdrawSilverText) ~= Text then
        Window.WithdrawSilverText:SetText(FText(Text))
    end
end

------------------------------------------------------------------------
-- Clicks. The game's own click functions are hooked: the mod does real
-- work only for a few seconds after a hand-in or a withdrawal (waiting for
-- the server's answer). Otherwise it only checks twice a second whether
-- the window is open. If the hooks cannot be set, it falls back to
-- watching the window every 50 ms, as before.
------------------------------------------------------------------------

-- How long to watch closely after a click: the server answers in < 0.2 s.
local WatchSeconds = 3
local WatchUntil = 0
local HooksSet = false

-- The withdraw button. The game keeps it disabled ~2 s after a hand-in or
-- a withdrawal, even after the server answered, and enables it again at
-- once if the window is closed and opened (seen by the user): a delay of
-- the window only. The mod enables it once the server has answered and
-- there is silver to take, and disables it while the game waits for the
-- server and right after a click, so one click sends one request.
local ClickLockSeconds = 3
local WithdrawWasPressed = false
local WithdrawClickedAt = nil
local WithdrawSawLoading = false

local function OnWithdrawClicked()
    WithdrawClickedAt = os.clock()
    WithdrawSawLoading = false
    WatchUntil = os.clock() + WatchSeconds
end

local function ManageWithdrawButton(Window, Silver)
    if type(Silver) ~= "number" then return end
    local Button = Window.WithdrawSilverButton
    if not HooksSet then
        -- No hook: a click is a press then a release over the button.
        local Pressed = Button:IsPressed()
        if WithdrawWasPressed and not Pressed and Button:IsHovered() then OnWithdrawClicked() end
        WithdrawWasPressed = Pressed
    end
    local Loading = IsShown(Window.LoadingBox)
    if WithdrawClickedAt then
        if Loading then WithdrawSawLoading = true end
        -- Locked until the server answered this click (or a few seconds).
        if (WithdrawSawLoading and not Loading) or os.clock() - WithdrawClickedAt > ClickLockSeconds then
            WithdrawClickedAt = nil
        end
    end
    local Enabled = Silver > 0 and not Loading and not WithdrawClickedAt
    if Button:GetIsEnabled() ~= Enabled then Button:SetIsEnabled(Enabled) end
end

-- Set further down: notes what a hand-in click is about to consume.
local OnHandInClicked = nil

-- Hooks run inline in the game's click, on the game thread: they only note
-- the time. The pre-callback of the withdraw click also disables the
-- button at once, before the request leaves.
do
    local Ok, Error = pcall(function()
        RegisterHook("/Script/Anvil.BountyWidget:OnSubmitBountyButtonClicked", function(Context)
            WatchUntil = os.clock() + WatchSeconds
            if OnHandInClicked then
                local Ok, Error = pcall(OnHandInClicked, Context)
                if not Ok then Log("hand-in note error: %s", tostring(Error)) end
            end
        end)
        RegisterHook("/Script/Anvil.BountyBoardWindow:OnWithdrawSilverButtonClicked", function()
            OnWithdrawClicked()
        end)
    end)
    HooksSet = Ok
    if not Ok then Log("click hooks not available (%s): watching the window instead", tostring(Error)) end
end

------------------------------------------------------------------------
-- Ready bounties: first in the list, in a gold frame. The client does not
-- know which bounties the player can hand in (bCanSubmitBounty was true
-- for all 18 bounties of a board, 2026-11-11; the server answers "Missing
-- one or more items" otherwise). The mod works it out from what the game
-- shows: a bounty widget shows the item it asks for (icon and "3x"), and
-- the player's inventory widget shows each item's icon and count. Same
-- icon, enough of it: ready. Display only.
--
-- The list view only builds widgets for the bounties on screen, so a
-- bounty's request is learnt when its widget is seen, by BountyId (read
-- from the widget's list item). Requests[BountyId] = { Icon, Count }, for
-- the window as long as it stays open.
------------------------------------------------------------------------

local Requests = {}
local ListEntryLibrary = nil

local function TextureName(Image)
    local Resource = Image.Brush.ResourceObject
    if not Resource or not IsSafe(Resource) then return nil end
    return Resource:GetFName():ToString()
end

-- "3x" -> 3; "" (a single item shows no count) -> 1.
local function CountOf(Text)
    local Number = tonumber(string.match(Text or "", "%d+") or "")
    return Number or 1
end

-- True when a widget and everything above it is shown: hidden windows keep
-- old copies of the inventory (seen 2026-11-11: a trophy taken out still
-- counted, from a closed window's copy).
local UserWidgetClass = nil
local function IsOnScreen(Widget)
    UserWidgetClass = UserWidgetClass or StaticFindObject("/Script/UMG.UserWidget")
    local Current = Widget
    for _ = 1, 40 do
        if not IsSafe(Current) then return false end
        local Visibility = Current:GetVisibility()
        if Visibility == 1 or Visibility == 2 then return false end -- Collapsed, Hidden
        -- Faded out.
        local OpacityOk, Opacity = pcall(function() return Current:GetRenderOpacity() end)
        if OpacityOk and type(Opacity) == "number" and Opacity < 0.01 then return false end
        local Parent = Current:GetParent()
        if IsSafe(Parent) then
            -- A widget switcher only shows its active child.
            if ClassName(Parent) == "WidgetSwitcher" then
                local Active = Parent:GetActiveWidget()
                if not IsSafe(Active) or Active:GetAddress() ~= Current:GetAddress() then return false end
            end
            Current = Parent
        else
            -- The top of a widget tree: carry on with the user widget that
            -- owns the tree (tree -> its outer).
            local Owner = nil
            pcall(function()
                local Tree = Current:GetOuter()
                local Candidate = IsSafe(Tree) and Tree:GetOuter()
                if IsSafe(Candidate) and Candidate:IsA(UserWidgetClass)
                    and Candidate:GetAddress() ~= Current:GetAddress() then
                    Owner = Candidate
                end
            end)
            if not Owner then return true end
            Current = Owner
        end
    end
    return false
end

-- What a bounty widget asks for: { Icon, Count }, or nil.
local function RequestOf(Entry)
    local Resource = Entry.BountyResourceWidget
    if not IsSafe(Resource) then return nil end
    local Icon = TextureName(Resource.ResourceIcon)
    if not Icon then return nil end
    return { Icon = Icon, Count = CountOf(ReadText(Resource.ResourceCostText)) }
end

local InventorySource = "none"

-- Where the mod reads what the player carries. The game keeps one copy of
-- the player inventory per window, and a copy is only brought up to date
-- when its window opens (seen 2026-11-11): the panel beside the board was
-- not updated after a hand-in; the inventory window's copy lacked three
-- trophies picked up since it was last opened; an old window's copy was
-- empty. Being "on screen" told nothing: closed windows passed for shown.
-- So the mod follows which copy changed last: CopyState[copy identity] =
-- { Sig = its contents, Changed = when they last changed (os.clock) }. A
-- copy seen for the first time counts as just changed (a new window, just
-- filled), except at the first reading, when nothing is known. The copies
-- that changed last are used (highest count of each item if several), and
-- hand-ins not shown yet are taken off (Ledger, below).
-- Copies: { { Id = identity, Here = { [icon] = count } } }.
-- InventorySource: where the counts came from, for the log.
local CopyState = {}
local CopiesSeen = false

local function CopyName(Grid)
    local Name = "?"
    pcall(function() Name = Grid:GetOuter():GetOuter():GetFName():ToString() end)
    return Name
end

local function ReadCopies()
    InventorySource = "none"
    local All = {}
    local Now = os.clock()
    for _, Grid in ipairs(FindAllOf("InventoryWidget") or {}) do
        if IsSafe(Grid) and IsLiveWidget(Grid) and Grid.bIsPlayerInventory then
            local Here = {}
            for Index = 0, Grid:GetChildrenCount() - 1 do
                local Item = Grid:GetChildAt(Index)
                if IsSafe(Item) then
                    pcall(function()
                        -- An emptied slot may keep its last image, hidden:
                        -- only count images on show.
                        if not IsShown(Item) or not IsShown(Item.ItemImage) then return end
                        local Icon = TextureName(Item.ItemImage)
                        if Icon then Here[Icon] = (Here[Icon] or 0) + CountOf(ReadText(Item.ItemQuantityText)) end
                    end)
                end
            end
            local Parts = {}
            for Icon, Count in pairs(Here) do Parts[#Parts + 1] = Icon .. "=" .. Count end
            table.sort(Parts)
            local Sig = table.concat(Parts, " ")
            local Id = Identity(Grid)
            local State = CopyState[Id]
            if not State then
                CopyState[Id] = { Sig = Sig, Changed = CopiesSeen and Now or 0 }
            elseif State.Sig ~= Sig then
                State.Sig = Sig
                State.Changed = Now
            end
            All[#All + 1] = { Id = Id, Here = Here, Name = CopyName(Grid), Changed = CopyState[Id].Changed }
        end
    end
    CopiesSeen = CopiesSeen or #All > 0
    local Latest = -1
    for _, Copy in ipairs(All) do Latest = math.max(Latest, Copy.Changed) end
    local Used = {}
    for _, Copy in ipairs(All) do
        if Copy.Changed == Latest then Used[#Used + 1] = Copy end
    end
    if #Used > 0 then
        InventorySource = string.format("%s%s", Used[1].Name, #Used > 1 and string.format(" and %d other(s)", #Used - 1) or "")
        if Latest == 0 then InventorySource = InventorySource .. ", no change seen yet" end
    end
    return Used
end

-- Hand-ins the inventory widgets may not show yet. The copy of the player
-- inventory shown beside the board was not updated after a hand-in
-- (2026-11-11: 3 wolf trophies still shown after handing in a 3x wolf
-- bounty). A hand-in click notes, for each copy, the count it showed
-- (Raw); once the server confirmed ("Bounty complete"), a copy still
-- showing that count gets the bounty's count taken off. A copy whose count
-- changed has been updated and is left alone. Ledger = { { Icon, Count,
-- Raw = { [copy identity] = count } } }, emptied at each change of area.
local PendingHandIn = nil
local Ledger = {}

OnHandInClicked = function(Context)
    local Entry = Context:get()
    if not IsSafe(Entry) then return end
    local Request = RequestOf(Entry)
    if not Request then return end
    local Raw = {}
    for _, Copy in ipairs(ReadCopies()) do Raw[Copy.Id] = Copy.Here[Request.Icon] or 0 end
    PendingHandIn = { Icon = Request.Icon, Count = Request.Count, Raw = Raw, At = os.clock() }
end

-- Called when the hand-in message is read: keep the note on success.
local function SettleHandIn(Success)
    if not PendingHandIn then return end
    if Success and os.clock() - PendingHandIn.At < 10 then
        Ledger[#Ledger + 1] = PendingHandIn
        Log("handed in %dx %s", PendingHandIn.Count, PendingHandIn.Icon)
    end
    PendingHandIn = nil
end

local function ApplyLedger(Copies)
    for _, Copy in ipairs(Copies) do
        local Taken = {}
        for _, Note in ipairs(Ledger) do
            local Before = Note.Raw[Copy.Id]
            if Before ~= nil then
                if (Copy.Here[Note.Icon] or 0) == Before then
                    Taken[Note.Icon] = (Taken[Note.Icon] or 0) + Note.Count
                else
                    Note.Raw[Copy.Id] = nil -- this copy has been updated
                end
            end
        end
        for Icon, Count in pairs(Taken) do
            Copy.Here[Icon] = math.max(0, (Copy.Here[Icon] or 0) - Count)
        end
    end
    for Index = #Ledger, 1, -1 do
        if next(Ledger[Index].Raw) == nil then table.remove(Ledger, Index) end
    end
end

local function PlayerItems()
    local Copies = ReadCopies()
    if #Copies == 0 then return nil end
    ApplyLedger(Copies)
    local Counts = {}
    -- Highest count of each icon across the copies kept.
    for _, Copy in ipairs(Copies) do
        for Icon, Count in pairs(Copy.Here) do
            if Count > (Counts[Icon] or 0) then Counts[Icon] = Count end
        end
    end
    return Counts
end

-- The list item (UBountyListViewItem) a bounty widget shows, or nil.
local ItemLookupLogged = false
local function ItemOf(Entry)
    if not ListEntryLibrary or not IsSafe(ListEntryLibrary) then
        ListEntryLibrary = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
    end
    local Ok, Item = pcall(function() return ListEntryLibrary:GetListItemObject(Entry) end)
    if Ok and Item and IsSafe(Item) then return Item end
    if not ItemLookupLogged then
        ItemLookupLogged = true
        Log("cannot read a bounty widget's list item (%s): no sorting, frames only", tostring(Item))
    end
    return nil
end

local function IsReady(Request, Items)
    return Request ~= nil and Items ~= nil and (Items[Request.Icon] or 0) >= Request.Count
end

-- The bounty widgets on screen (the list view's displayed entries).
local function DisplayedEntries(Window)
    local Found = {}
    local List = Window.BountyListView
    if not IsSafe(List) then return Found end
    local Entries = List:GetDisplayedEntryWidgets()
    for Index = 1, #Entries do
        local Entry = Entries[Index]
        if type(Entry) == "userdata" and Entry.get then Entry = Entry:get() end
        if IsSafe(Entry) then Found[#Found + 1] = Entry end
    end
    return Found
end

local SortLogged = 0

-- Puts the list view in the wanted order when it is not: ready bounties
-- first, the others after, each group in the game's order. Bounties not
-- seen yet count as not ready.
local function SortBounties(Window, Items)
    local List = Window.BountyListView
    if not IsSafe(List) then return end
    local Ready, Others = {}, {}
    local GameItems = Window.BountyListViewItems
    for Index = 1, #GameItems do
        local Item = GameItems[Index]
        if not IsSafe(Item) then return end
        if IsReady(Requests[Item.BountyId], Items) then Ready[#Ready + 1] = Item else Others[#Others + 1] = Item end
    end
    for _, Item in ipairs(Others) do Ready[#Ready + 1] = Item end
    local Wanted = Ready
    if #Wanted == 0 then return end
    local Shown = List.ListItems
    local Same = #Shown == #Wanted
    if Same then
        for Index = 1, #Wanted do
            local Item = Shown[Index]
            if not IsSafe(Item) or Item:GetAddress() ~= Wanted[Index]:GetAddress() then
                Same = false
                break
            end
        end
    end
    if Same then return end
    -- The items stay alive meanwhile: the window holds them too
    -- (BountyListViewItems).
    List:ClearListItems()
    for _, Item in ipairs(Wanted) do List:AddItem(Item) end
    if SortLogged < 5 then
        SortLogged = SortLogged + 1
        Log("bounty list sorted: ready ones first (%d items)", #Wanted)
    end
end

-- The gold frame: a Border drawn over the bounty, outline only with a
-- faint gold fill, letting clicks through. A bounty widget's root is a
-- Border (seen 2026-11-11): its content is moved into an Overlay with the
-- frame on top, once per widget. Frames[entry identity] = frame address,
-- found again in that overlay each time.
local Gold = { R = 1.0, G = 0.78, B = 0.25, A = 1.0 }
local Frames = {}
local FrameLogged = false
local PaddingLogged = false
-- Pixels between the gold frame and the bounty's text.
local FrameGap = 8

local function NewFrame(Entry)
    local Frame = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), Entry.WidgetTree)
    pcall(function()
        local Brush = Frame.Background
        Brush.DrawAs = 4 -- RoundedBox
        Brush.TintColor = { SpecifiedColor = { R = Gold.R, G = Gold.G, B = Gold.B, A = 0.10 }, ColorUseRule = 0 }
        Brush.OutlineSettings.CornerRadii = { X = 4, Y = 4, Z = 4, W = 4 }
        Brush.OutlineSettings.Color = { SpecifiedColor = Gold, ColorUseRule = 0 }
        Brush.OutlineSettings.Width = 2
        Brush.OutlineSettings.RoundingType = 0 -- FixedRadius
        Brush.OutlineSettings.bUseBrushTransparency = false
    end)
    Frame:SetVisibility(SlateHitTestInvisible)
    return Frame
end

local function FindFrame(Entry, Address)
    local Root = Entry.WidgetTree.RootWidget
    if not IsSafe(Root) then return nil end
    local Overlay = Root:GetContent()
    if not IsSafe(Overlay) or ClassName(Overlay) ~= "Overlay" then return nil end
    for Index = 0, Overlay:GetChildrenCount() - 1 do
        local Child = Overlay:GetChildAt(Index)
        if IsSafe(Child) and Child:GetAddress() == Address then return Child end
    end
    return nil
end

local function EnsureFrame(Entry)
    local Id = Identity(Entry)
    if Frames[Id] then return Frames[Id] ~= 0 and FindFrame(Entry, Frames[Id]) or nil end
    local Root = Entry.WidgetTree.RootWidget
    if not IsSafe(Root) or ClassName(Root) ~= "Border" then
        if not FrameLogged then
            FrameLogged = true
            Log("no gold frame: the bounty widget's root is a %s", IsSafe(Root) and ClassName(Root) or "?")
        end
        Frames[Id] = 0
        return nil
    end
    local Content = Root:GetContent()
    if not IsSafe(Content) then
        Frames[Id] = 0
        return nil
    end
    local Overlay = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), Entry.WidgetTree)
    -- Adding the content to the overlay takes it out of the border.
    local ContentSlot = Overlay:AddChildToOverlay(Content)
    ContentSlot:SetHorizontalAlignment(0) -- Fill
    ContentSlot:SetVerticalAlignment(0) -- Fill
    local Frame = NewFrame(Entry)
    local FrameSlot = Overlay:AddChildToOverlay(Frame)
    FrameSlot:SetHorizontalAlignment(0)
    FrameSlot:SetVerticalAlignment(0)
    -- The frame sits inside the border's padding, right on the text: push
    -- it out to the card's edge (negative padding, 1 px inside), and keep
    -- at least FrameGap pixels between it and the text.
    pcall(function()
        local P = Root.Padding
        local Sides = { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }
        if not PaddingLogged then
            PaddingLogged = true
            Log("bounty card padding: %.0f %.0f %.0f %.0f", Sides.Left, Sides.Top, Sides.Right, Sides.Bottom)
        end
        local Out, In = {}, {}
        for Side, Value in pairs(Sides) do
            Out[Side] = -math.max(0, Value - 1)
            In[Side] = math.max(0, FrameGap - Value)
        end
        FrameSlot:SetPadding(Out)
        ContentSlot:SetPadding(In)
    end)
    Root:SetContent(Overlay)
    Frames[Id] = Frame:GetAddress()
    return Frame
end

-- Learns the requests of the bounties on screen and frames the ready ones.
-- Entries are reused as the list scrolls: checked each time. While
-- Learning (the scan), frames are only hidden, never shown or added.
-- Returns how many requests were new.
local function UpdateEntries(Window, Items, Learning)
    local New = 0
    for _, Entry in ipairs(DisplayedEntries(Window)) do
        local Ok, Error = pcall(function()
            local Request = RequestOf(Entry)
            local Item = ItemOf(Entry)
            if Request and Item and not Requests[Item.BountyId] then
                Requests[Item.BountyId] = Request
                New = New + 1
            end
            local Frame = nil
            if Learning then
                local Address = Frames[Identity(Entry)]
                if Address and Address ~= 0 then Frame = FindFrame(Entry, Address) end
            else
                Frame = EnsureFrame(Entry)
            end
            if Frame then
                local Wanted = (not Learning and IsReady(Request, Items)) and SlateHitTestInvisible or SlateCollapsed
                if Frame:GetVisibility() ~= Wanted then Frame:SetVisibility(Wanted) end
            end
        end)
        if not Ok then Log("bounty widget error: %s", tostring(Error)) end
    end
    return New
end

local function UpdateBoard(Window)
    local Items = PlayerItems()
    UpdateEntries(Window, Items)
    SortBounties(Window, Items)
end

-- Developer check (Ctrl+F7): every copy of the player inventory, whether
-- it counts as on screen, its bounty item counts, then the counts the mod
-- uses and the bounties it calls ready. Run it before and after a hand-in.
RegisterDevKey(Key.F7, function()
    ExecuteInGameThread(function()
        local Ok, Error = pcall(function()
            local Wanted = {}
            for _, Request in pairs(Requests) do Wanted[Request.Icon] = true end
            local function Summary(Counts)
                local Parts = {}
                for Icon in pairs(Wanted) do Parts[#Parts + 1] = string.format("%s=%d", Icon, Counts[Icon] or 0) end
                table.sort(Parts)
                return #Parts > 0 and table.concat(Parts, " ") or "(no bounty seen yet)"
            end
            for _, Grid in ipairs(FindAllOf("InventoryWidget") or {}) do
                if IsSafe(Grid) and IsLiveWidget(Grid) and Grid.bIsPlayerInventory then
                    local Here = {}
                    for Index = 0, Grid:GetChildrenCount() - 1 do
                        local Item = Grid:GetChildAt(Index)
                        pcall(function()
                            if not IsShown(Item) or not IsShown(Item.ItemImage) then return end
                            local Icon = TextureName(Item.ItemImage)
                            if Icon then Here[Icon] = (Here[Icon] or 0) + CountOf(ReadText(Item.ItemQuantityText)) end
                        end)
                    end
                    local Owner = "?"
                    pcall(function()
                        local Path = string.match(Grid:GetFullName(), "^%S+%s+(%S+)") or ""
                        Owner = string.gsub(string.gsub(Path, "^.-HUDWidget%.", ""), "WidgetTree_%d+%.", "")
                    end)
                    local All = {}
                    for Icon, Count in pairs(Here) do All[#All + 1] = string.format("%s=%d", Icon, Count) end
                    table.sort(All)
                    Log("check: copy %s %s %s: %s", Owner, Identity(Grid), IsOnScreen(Grid) and "ON SCREEN" or "hidden",
                        table.concat(All, " "))
                end
            end
            local Asked = {}
            for Id, Request in pairs(Requests) do Asked[#Asked + 1] = string.format("#%d %dx %s", Id, Request.Count, Request.Icon) end
            table.sort(Asked)
            Log("check: bounties ask: %s", table.concat(Asked, ", "))
            local Items = PlayerItems()
            Log("check: used (%s): %s", InventorySource, Items and Summary(Items) or "nothing")
            local Notes = {}
            for _, Note in ipairs(Ledger) do
                local Copies = 0
                for _ in pairs(Note.Raw) do Copies = Copies + 1 end
                Notes[#Notes + 1] = string.format("%dx %s (%d copy/copies not updated yet)", Note.Count, Note.Icon, Copies)
            end
            Log("check: hand-ins taken off: %s", #Notes > 0 and table.concat(Notes, ", ") or "none")
            local Ready = {}
            for Id, Request in pairs(Requests) do
                if IsReady(Request, Items) then Ready[#Ready + 1] = string.format("#%d %dx %s", Id, Request.Count, Request.Icon) end
            end
            table.sort(Ready)
            Log("check: ready bounties: %s", #Ready > 0 and table.concat(Ready, ", ") or "none")
        end)
        if not Ok then Log("check error: %s", tostring(Error)) end
    end)
end)

-- Bounties whose request is not known yet (never on screen).
local function UnknownCount(Window)
    local Unknown = 0
    local GameItems = Window.BountyListViewItems
    for Index = 1, #GameItems do
        local Item = GameItems[Index]
        if IsSafe(Item) and not Requests[Item.BountyId] then Unknown = Unknown + 1 end
    end
    return Unknown
end

------------------------------------------------------------------------
-- The scan: the list view only builds widgets for the bounties on screen.
-- When the board opens (or gets bounties never seen), the mod scrolls the
-- list from top to bottom, a screen at a time, with the list made fully
-- transparent, reading each screen's bounties; then it scrolls back to the
-- top, shows the list again and sorts it. About 40 ms per screen. Nothing
-- is kept between steps but the window's identity.
------------------------------------------------------------------------

-- Each step waits one frame (the list view builds the widgets of the new
-- screen in its next tick); a step that found nothing new waits one more
-- frame, at most twice, before scrolling on.
local ScanMaxSteps = 40
local ScanMaxWaits = 2

-- Runs Callback on the game thread after one frame (or 15 ms if this UE4SS
-- has no frame-based delay).
local function NextFrame(Callback)
    local Ok = pcall(ExecuteInGameThreadAfterFrames, 1, Callback)
    if not Ok then ExecuteInGameThreadWithDelay(15, Callback) end
end
-- Scan = { WindowId, Offset, Steps, Waits, Started } while a scan runs. ScannedCount: the
-- number of bounties when the window was last scanned, so a bounty whose
-- request cannot be read does not start a scan at every check.
local Scan = nil
local ScannedCount = nil

local function ShowList(Window)
    pcall(function() Window.BountyListView:SetRenderOpacity(1.0) end)
end

-- Back to the top, sorted; the list shows again one frame later, once the
-- top screen is built (else the last scanned screen flashes).
local function EndScan(Window)
    local WindowId = Scan and Scan.WindowId
    Scan = nil
    if not Window then return end
    pcall(function() Window.BountyListView:SetScrollOffset(0) end)
    local Ok, Error = pcall(UpdateBoard, Window)
    if not Ok then Log("bounty list error: %s", tostring(Error)) end
    if not WindowId then
        ShowList(Window)
        return
    end
    NextFrame(function()
        local Again = FindWindow(WindowId)
        if Again then ShowList(Again) end
    end)
end

local ScanStep
ScanStep = function()
    NextFrame(function()
        if not Scan then return end
        local Window = (not WorldIsSettling()) and FindWindow(Scan.WindowId) or nil
        if not Window then
            Scan = nil
            return
        end
        local Ok, Error = pcall(function()
            local New = UpdateEntries(Window, nil, true)
            Scan.Steps = Scan.Steps + 1
            local Total = #Window.BountyListViewItems
            if UnknownCount(Window) == 0 or Scan.Offset >= Total - 1 or Scan.Steps >= ScanMaxSteps then
                Log("bounty scan done: %d steps, %.0f ms, %d of %d bounties read", Scan.Steps,
                    (os.clock() - Scan.Started) * 1000, Total - UnknownCount(Window), Total)
                EndScan(Window)
                return
            end
            -- Nothing new: the new screen may not be built yet.
            if New == 0 and Scan.Waits < ScanMaxWaits then
                Scan.Waits = Scan.Waits + 1
                ScanStep()
                return
            end
            Scan.Waits = 0
            -- One screen further: the bounties shown are Offset onwards.
            local OnScreen = #DisplayedEntries(Window)
            Scan.Offset = Scan.Offset + math.max(1, OnScreen)
            Window.BountyListView:SetScrollOffset(Scan.Offset)
            ScanStep()
        end)
        if not Ok then
            Log("bounty scan error: %s", tostring(Error))
            EndScan(Window)
        end
    end)
end

local function StartScan(Window)
    ScannedCount = #Window.BountyListViewItems
    Scan = { WindowId = Identity(Window), Offset = 0, Steps = 0, Waits = 0, Started = os.clock() }
    Window.BountyListView:SetRenderOpacity(0.0)
    Window.BountyListView:SetScrollOffset(0)
    ScanStep()
end

------------------------------------------------------------------------
-- The check, every 50 ms but returning at once unless the window was just
-- clicked, or half a second has passed.
------------------------------------------------------------------------

local WindowOpen = false
local NextCheck = 0

local function PollWindow()
    Ticks = Ticks + 1
    if WorldIsSettling() then
        -- New windows after a change of area: forget the old entries.
        if next(Frames) ~= nil then Frames = {} end
        if #Ledger > 0 then Ledger = {} end
        if next(CopyState) ~= nil then CopyState = {} end
        CopiesSeen = false
        PendingHandIn = nil
        return
    end
    local Now = os.clock()
    -- Close watch: after a click, or always while open when hooks failed.
    local Watching = Now < WatchUntil or (WindowOpen and not HooksSet)
    if not Watching and Now < NextCheck then return end
    NextCheck = Now + 0.5
    -- Found again at every check (see Identity).
    local Window = FindWindow()
    if Window and not WindowOpen then
        -- In case a scan was cut short with the list transparent.
        if not Scan then ShowList(Window) end
        local Count = 0
        pcall(function() Count = #Window.BountyListViewItems end)
        local Read = PlayerItems() ~= nil
        Log("bounty board open: %d bounties, inventory %s (%s)", Count, Read and "read" or "not read", InventorySource)
    end
    WindowOpen = Window ~= nil
    if not Window then
        -- A bounty's request is only trusted while its window is open.
        if next(Requests) ~= nil then Requests = {} end
        ScannedCount = nil
        ErrorShown = nil
        WithdrawWasPressed = false
        return
    end
    local Silver = ReadSilver()
    local SilverOk, SilverError = pcall(ShowFinalSilver, Window, Silver)
    if not SilverOk then Log("silver error: %s", tostring(SilverError)) end
    local ButtonOk, ButtonError = pcall(ManageWithdrawButton, Window, Silver)
    if not ButtonOk then Log("withdraw button error: %s", tostring(ButtonError)) end
    -- Sort and frames once the server has answered, never while it is
    -- being waited for.
    if not IsShown(Window.LoadingBox) then
        if not Scan then
            local BoardOk, BoardError = pcall(function()
                -- Bounties never on screen: scan the list once for them.
                if UnknownCount(Window) > 0 and ScannedCount ~= #Window.BountyListViewItems then
                    StartScan(Window)
                else
                    UpdateBoard(Window)
                end
            end)
            if not BoardOk then Log("bounty list error: %s", tostring(BoardError)) end
        end
    end
    -- Keep watching while a message is up or the server is awaited.
    if IsShown(Window.SubmitBountyStatusMessageBox) or IsShown(Window.LoadingBox) then
        WatchUntil = math.max(WatchUntil, Now + 0.2)
    end
    if not IsShown(Window.SubmitBountyStatusMessageBox) then
        ErrorShown = nil
        return
    end
    -- Still waiting for the server: leave everything blocked.
    if IsShown(Window.LoadingBox) then return end
    local Message = ReadText(Window.SubmitBountyStatusMessageText)
    -- An error ("Missing one or more items required for this Bounty") stays
    -- half as long as the game shows it, so it can still be read.
    if not IsSuccessMessage(Message) then
        if not ErrorShown or ErrorShown.Message ~= Message then
            ErrorShown = { Message = Message, At = os.clock() }
            return
        end
        if os.clock() - ErrorShown.At < ErrorSeconds then return end
        ErrorShown = nil
    end
    SettleHandIn(IsSuccessMessage(Message))
    local Ok = pcall(function() Window:HideBountyStatusMessageBox() end)
    if not Ok or IsShown(Window.SubmitBountyStatusMessageBox) then
        Window.SubmitBountyStatusMessageBox:SetVisibility(SlateCollapsed)
    end
    Log("hid '%s'%s", Message, Ok and "" or " (by hand: the game's hide function failed)")
end

-- On the game thread, between frames: UE4SS's async loop (LoopAsync) ran
-- Lua on its own thread while the game thread ran ours, which corrupted the
-- Lua state and crashed the game now and then.
LoopInGameThreadWithDelay(50, function()
    local Ok, Error = pcall(PollWindow)
    if not Ok then Log("poll error: %s", tostring(Error)) end
end)

Log("v%s loaded%s", Version, DevTools and " (dev key: Ctrl+F5 probe)" or "")
