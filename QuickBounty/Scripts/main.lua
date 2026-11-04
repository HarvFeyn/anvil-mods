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

    Keys (game window focused):
      Ctrl+F5  probe: log the bounty board window's layout, then for 6 s
               every 100 ms what changes in it (hand in a bounty meanwhile)
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[QuickBounty] " .. string.format(Format, ...) .. "\n")
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
        if Window:IsValid() and IsLiveWidget(Window) then
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
        if Data:IsValid() and not string.find(Data:GetFullName(), "Default__", 1, true) then
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
        if not Widget or not Widget:IsValid() then return "missing" end
        local Visibility = Widget:GetVisibility()
        return string.format("%s%s%s", Visibilities[Visibility] or tostring(Visibility),
            Widget:GetIsEnabled() and "" or " disabled",
            Widget:GetRenderOpacity() < 1 and string.format(" opacity %.2f", Widget:GetRenderOpacity()) or "")
    end)
    return Ok and Text or "?"
end

local function LogTree(Widget, Depth)
    if Depth > 7 or not Widget or not Widget:IsValid() then return end
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
        if Bounty:IsValid() and IsLiveWidget(Bounty) then
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

RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
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
                        ExecuteWithDelay(100, Sample)
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

------------------------------------------------------------------------
-- Hide the status message once the server has answered
------------------------------------------------------------------------

local SlateCollapsed = 1

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
-- window is built again, so it is kept up to date here every tick.
local function ShowFinalSilver(Window, Silver)
    if type(Silver) ~= "number" then return end
    local Text = string.format("%dx", Silver)
    if ReadText(Window.WithdrawSilverText) ~= Text then
        Window.WithdrawSilverText:SetText(FText(Text))
    end
end

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

local function ManageWithdrawButton(Window, Silver)
    if type(Silver) ~= "number" then return end
    local Button = Window.WithdrawSilverButton
    local Pressed = Button:IsPressed()
    if WithdrawWasPressed and not Pressed and Button:IsHovered() then
        WithdrawClickedAt = os.clock()
        WithdrawSawLoading = false
    end
    WithdrawWasPressed = Pressed
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

local function PollWindow()
    Ticks = Ticks + 1
    -- Found again every tick: see Identity.
    local Window = FindWindow()
    if not Window then
        ErrorShown = nil
        WithdrawWasPressed = false
        return
    end
    local Silver = ReadSilver()
    local SilverOk, SilverError = pcall(ShowFinalSilver, Window, Silver)
    if not SilverOk then Log("silver error: %s", tostring(SilverError)) end
    local ButtonOk, ButtonError = pcall(ManageWithdrawButton, Window, Silver)
    if not ButtonOk then Log("withdraw button error: %s", tostring(ButtonError)) end
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
    local Ok = pcall(function() Window:HideBountyStatusMessageBox() end)
    if not Ok or IsShown(Window.SubmitBountyStatusMessageBox) then
        Window.SubmitBountyStatusMessageBox:SetVisibility(SlateCollapsed)
    end
    Log("hid '%s'%s", Message, Ok and "" or " (by hand: the game's hide function failed)")
end

-- A callback queued to the game thread can be lost, so a stuck queue is
-- retried after a few seconds.
local StallSeconds = 3
local PollQueuedAt = nil
LoopAsync(50, function()
    if PollQueuedAt and os.time() - PollQueuedAt < StallSeconds then return false end
    PollQueuedAt = os.time()
    ExecuteInGameThread(function()
        PollQueuedAt = nil
        local Ok, Error = pcall(PollWindow)
        if not Ok then Log("poll error: %s", tostring(Error)) end
    end)
    return false
end)

Log("v%s loaded (Ctrl+F5 probe)", Version)
