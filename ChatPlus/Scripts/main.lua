--[[
    ChatPlus: small improvements to the in-game chat: the time of each
    message, in the player's own time zone (the PC's clock), and a channel
    lock (the channel the player picked stays picked when the game would
    put it back on Empire).

    The chat (UChatWidget, in the gameplay overlay) lists its messages in a
    list view, ChatHistoryListView: one list item (UChatMessage, no readable
    fields) per message, shown by entry widgets (UChatEntryWidget) that the
    list reuses as it scrolls. Each entry holds the message itself in
    ChatEntryInternal (UChatEntryBase: SenderName, Message, ChatType).

    The client gets no time with a message (FClientChatMessage: TeamId,
    SenderId, SenderName, Text), so the mod notes the time a list item first
    appears: the time the message reached this PC. Messages already in the
    list when the mod first sees the chat get no time (their time is not
    known). Display only: nothing is sent to the server.

    Developer key (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates):
      Ctrl+F10  probe: log the chat's layout, its entries and what they hold
--]]

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[ChatPlus] " .. string.format(Format, ...) .. "\n")
end

-- Developer keys (probes) only on the developer's machine: install.ps1
-- leaves ue4ss\Mods\AnvilModsDev.txt there. Released zips and the pack do
-- not have it, so players get no extra keys.
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

-- When the game changes area (connecting, entering or leaving a cave, back
-- to the menu), it loads a map and tears down its HUD, chat included. The
-- mod touches nothing from the load's start until ResumeSeconds after it is
-- done, and the widgets it added are forgotten (EntriesStale).
local ResumeSeconds = 0.5
local Loading = false
local ResumeAt = 0
local EntriesStale = false

local HooksOk = pcall(function()
    RegisterLoadMapPreHook(function()
        Loading = true
        EntriesStale = true
    end)
    RegisterLoadMapPostHook(function()
        Loading = false
        ResumeAt = os.clock() + ResumeSeconds
    end)
end)
if not HooksOk then Log("load map hooks not available: pausing on HUD changes only") end

-- Backup: the HUD changing (it is replaced at each change of area) also
-- gives a pause. Twice a second is enough for a backup.
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
            if LastHud ~= nil then
                ResumeAt = math.max(ResumeAt, Now + ResumeSeconds)
                EntriesStale = true
            end
            LastHud = Hud
        end
    end
    return Now < ResumeAt
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

-- Objects of the game are never kept from one tick to the next: the game
-- destroys its widgets when it changes area, and touching a destroyed object
-- crashed the game. An identity (address and unique name) tells the same
-- object apart without touching an old one.
local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

local function ReadText(TextBlock)
    local Ok, Text = pcall(function() return TextBlock.Text:ToString() end)
    return Ok and Text or "?"
end

local function ReadString(Value)
    local Ok, Text = pcall(function() return Value:ToString() end)
    return Ok and Text or "?"
end

local SlateCollapsed = 1
local SlateHitTestInvisible = 3

-- The player's chat. After a change of area the old chat stays in memory
-- until the next garbage collection, beside the new one (test of
-- 2026-11-20, out of a cave): only the one IsVisible() (drawn on screen,
-- which the old one no longer is) is the player's chat.
--
-- Searching all objects of the game (FindAllOf) ten times a second would
-- cost frames: the chat in use is found again by its path (a quick lookup)
-- and its full name, and the search runs at most once a second, when that
-- chat is gone or off screen. While the chat is off screen (hidden by the
-- game), the one last used still gets its new messages noted.
local ChatPath = nil -- path of the chat in use
local ChatKey = nil -- its full name (path with unique numbers)
local NextChatSearch = 0
local PathLookupLogged = false

local function IsOnScreen(Widget)
    local Ok, Shown = pcall(function() return Widget:IsVisible() end)
    return Ok and Shown == true
end

local function ChatByPath()
    if not ChatPath then return nil end
    local Ok, Chat = pcall(StaticFindObject, ChatPath)
    if Ok and IsSafe(Chat) and Chat:GetFullName() == ChatKey then return Chat end
    return nil
end

-- The chat, and whether it is on screen; nil when there is none.
local function FindChat()
    local Known = ChatByPath()
    if Known and IsOnScreen(Known) then return Known, true end
    local Now = os.clock()
    if Now >= NextChatSearch then
        NextChatSearch = Now + 1.0
        for _, Chat in ipairs(FindAllOf("ChatWidget") or {}) do
            if IsSafe(Chat) and IsLiveWidget(Chat) and IsOnScreen(Chat) then
                ChatKey = Chat:GetFullName()
                ChatPath = string.match(ChatKey, "^%S+%s+(%S+)")
                if not PathLookupLogged then
                    PathLookupLogged = true
                    if not ChatByPath() then Log("the chat cannot be found by its path: searched once a second") end
                end
                return Chat, true
            end
        end
    end
    return Known, false
end

local ListEntryLibrary = nil

-- The list item (UChatMessage) an entry widget shows, or nil.
local function ItemOf(Entry)
    if not ListEntryLibrary or not IsSafe(ListEntryLibrary) then
        ListEntryLibrary = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
    end
    local Ok, Item = pcall(function() return ListEntryLibrary:GetListItemObject(Entry) end)
    if Ok and Item and IsSafe(Item) then return Item end
    return nil
end

-- The entry widgets the list shows now.
local function DisplayedEntries(List)
    local Found = {}
    local Entries = List:GetDisplayedEntryWidgets()
    for Index = 1, #Entries do
        local Entry = Entries[Index]
        if type(Entry) == "userdata" and Entry.get then Entry = Entry:get() end
        if IsSafe(Entry) then Found[#Found + 1] = Entry end
    end
    return Found
end

------------------------------------------------------------------------
-- Message times. Stamps[item identity] = "14:32", noted when the item
-- first shows up in the list. Kept across changes of area: if the game
-- keeps its messages, they keep their time.
------------------------------------------------------------------------

local TimeFormat = "%H:%M"
local Stamps = {} -- item identity -> "14:32", or false (time unknown)
local StampCount = 0
local ChatsSeen = {} -- chat full name -> os.clock() when first seen
-- Only the messages already in the first chat of the game session, when
-- the mod first sees it, get no time (sent before; seen empty at each
-- connection so far). After a change of area the game puts the same
-- messages (same items) in the new chat, so they keep their time, and a
-- message new to the mod there was just sent: a first try that took the
-- first 5 s of each chat as history left a message sent while entering a
-- cave without a time (test of 2026-11-20).
local AnyChatSeen = false
-- Times of messages the list no longer holds are forgotten once there are
-- this many more than the list holds (only if the game drops old ones).
local ForgetMargin = 300

-- Notes one item. Returns true if it was known, false if new, nil if unsafe.
local function NoteItem(Item, Stamp)
    if not IsSafe(Item) then return nil end
    local Id = Identity(Item)
    if Stamps[Id] ~= nil then return true end
    Stamps[Id] = Stamp
    StampCount = StampCount + 1
    return false
end

local function ForgetOldStamps(Items, Count)
    local Live = {}
    for Index = 1, Count do
        local Item = Items[Index]
        if IsSafe(Item) then Live[Identity(Item)] = true end
    end
    local Kept, KeptCount = {}, 0
    for Id, Stamp in pairs(Stamps) do
        if Live[Id] then
            Kept[Id] = Stamp
            KeptCount = KeptCount + 1
        end
    end
    Log("forgot %d old message time(s), %d kept", StampCount - KeptCount, KeptCount)
    Stamps, StampCount = Kept, KeptCount
end

local function NoteNewItems(Chat, List)
    local Items = List.ListItems
    local Count = #Items
    local Key = Chat:GetFullName()
    local Clock = os.clock()
    local FirstSeen = ChatsSeen[Key]
    local NewChat = FirstSeen == nil
    if NewChat then
        FirstSeen = Clock
        ChatsSeen[Key] = Clock
    end
    local Stamp = os.date(TimeFormat)
    if NewChat and not AnyChatSeen then Stamp = false end
    AnyChatSeen = true
    local Added = 0
    if NewChat then
        for Index = 1, Count do
            if NoteItem(Items[Index], Stamp) == false then Added = Added + 1 end
        end
        Log("chat found: %d message(s) new to the mod%s", Added, Stamp and "" or ", shown without a time")
    else
        -- New messages come at one end of the list (the other end may lose
        -- old ones): each end is read up to three known messages in a row,
        -- so a long history is not read again for each message.
        for _, Range in ipairs({ { Count, 1, -1 }, { 1, Count, 1 } }) do
            local KnownInRow = 0
            for Index = Range[1], Range[2], Range[3] do
                local Known = NoteItem(Items[Index], Stamp)
                if Known == true then
                    KnownInRow = KnownInRow + 1
                    if KnownInRow >= 3 then break end
                elseif Known == false then
                    KnownInRow = 0
                    Added = Added + 1
                end
            end
        end
    end
    -- Not while a new chat is being filled (after a change of area the
    -- game puts the messages back in it).
    if StampCount > Count + ForgetMargin and Count > 0 and Clock - FirstSeen > 10 then
        ForgetOldStamps(Items, Count)
    end
end

------------------------------------------------------------------------
-- The time on each entry: a TextBlock before the message. Probe of
-- 2026-11-20: an entry's whole layout is its message widget
-- (ChatEntryInternal is the root of its widget tree), and a root cannot be
-- changed once the entry is drawn. Entries have no Blueprint logic, so no
-- event of theirs can be hooked between their creation and their drawing
-- (a hook on UserWidget:OnInitialized never fired for them).
--
-- So the mod changes the entry class's own widget tree, the model each new
-- entry is copied from: a HorizontalBox "ChatPlusRow" holding the time text
-- "ChatPlusTime" and the message. Only this PC's copy of the class
-- changes, for this game session.
--
-- The widgets it adds there are put in the root set: never freed. A first
-- try without it crashed the game about a minute later: the class is a
-- garbage collection cluster, whose references are fixed when it is
-- loaded, so the added widgets were not seen as used and were freed at the
-- next collection, leaving the model pointing at freed memory. The slots
-- the box creates for its children are kept by the box itself.
------------------------------------------------------------------------

local RowName = "ChatPlusRow"
local TimeName = "ChatPlusTime"
local PatchedClass = nil -- identity of the entry class already changed
local PatchLogged = false

local RootSetFlag = nil
pcall(function() RootSetFlag = EInternalObjectFlags.RootSet end)

-- A widget that is never freed, or nil when the root set flag is unknown.
local function NewKeptWidget(ClassPath, Outer, Name)
    if not RootSetFlag then return nil end
    local Widget = StaticConstructObject(StaticFindObject(ClassPath), Outer, FName(Name), 0, RootSetFlag)
    if not IsSafe(Widget) then return nil end
    local Kept = false
    pcall(function() Kept = Widget:HasAnyInternalFlags(RootSetFlag) end)
    if not Kept then return nil end
    return Widget
end

-- The game's fonts for the chat could not be read (probe of 2026-11-20:
-- neither the message's DefaultTextStyle nor the input box has a font
-- object; a TextBlock given a font without one draws nothing). The engine's
-- default font, at a chat size, looks right next to the messages.
local function StyleTimeText(Text)
    pcall(function()
        local Own = Text.Font
        Text:SetFont({
            FontObject = Own.FontObject,
            FontMaterial = Own.FontMaterial,
            TypefaceFontName = Own.TypefaceFontName,
            Size = 11,
            LetterSpacing = Own.LetterSpacing,
        })
    end)
    pcall(function()
        Text:SetColorAndOpacity({ SpecifiedColor = { R = 0.6, G = 0.6, B = 0.6, A = 1 }, ColorUseRule = 0 })
        Text:SetShadowOffset({ X = 1, Y = 1 })
        Text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.6 })
    end)
    Text:SetVisibility(SlateCollapsed) -- until a time is known
end

local function PatchEntryClass(List)
    local Class = List.EntryWidgetClass
    if not IsSafe(Class) then return end
    local ClassId = Identity(Class)
    if PatchedClass == ClassId then return end
    local Tree = Class.WidgetTree
    if not IsSafe(Tree) then
        if not PatchLogged then
            PatchLogged = true
            Log("no time shown: the chat entry class %s has no widget tree", Class:GetFName():ToString())
        end
        return
    end
    local Root = Tree.RootWidget
    if IsSafe(Root) and Root:GetFName():ToString() == RowName then
        PatchedClass = ClassId
        return
    end
    if not IsSafe(Root) or not string.find(ClassName(Root), "ChatEntry", 1, true) then
        if not PatchLogged then
            PatchLogged = true
            Log("no time shown: the chat entry's root is a %s", IsSafe(Root) and ClassName(Root) or "nothing")
        end
        return
    end
    local Box = NewKeptWidget("/Script/UMG.HorizontalBox", Tree, RowName)
    local Text = Box and NewKeptWidget("/Script/UMG.TextBlock", Tree, TimeName)
    if not Box or not Text then
        -- Leaves the class as it is: a widget that may be freed must not
        -- go into it. (The box, if made, stays alone, unused.)
        if not PatchLogged then
            PatchLogged = true
            Log("no time shown: cannot make widgets that stay (root set flag %s)", tostring(RootSetFlag))
        end
        PatchedClass = ClassId
        return
    end
    StyleTimeText(Text)
    local TextSlot = Box:AddChildToHorizontalBox(Text)
    pcall(function()
        TextSlot:SetPadding({ Left = 0, Top = 0, Right = 4, Bottom = 0 })
        TextSlot:SetVerticalAlignment(1) -- Top: next to the first line
    end)
    local InnerSlot = Box:AddChildToHorizontalBox(Root)
    pcall(function()
        InnerSlot:SetSize({ SizeRule = 1, Value = 1.0 }) -- Fill the rest
        InnerSlot:SetHorizontalAlignment(0)
        InnerSlot:SetVerticalAlignment(0)
    end)
    Tree.RootWidget = Box
    PatchedClass = ClassId
    Log("chat entry class %s changed: new messages get a time", Class:GetFName():ToString())
end

-- The entry's time text (in a ChatPlusRow), or nil.
local function TimeTextOf(Entry)
    local Inner = Entry.ChatEntryInternal
    if not IsSafe(Inner) then return nil end
    local Box = Inner:GetParent()
    if not IsSafe(Box) or Box:GetFName():ToString() ~= RowName then return nil end
    local Text = Box:GetChildAt(0)
    if IsSafe(Text) and Text:GetFName():ToString() == TimeName then return Text end
    return nil
end

local ShowLogged = 0

local function UpdateEntries(List)
    for _, Entry in ipairs(DisplayedEntries(List)) do
        local Ok, Error = pcall(function()
            local Item = ItemOf(Entry)
            if not Item then return end
            local Stamp = Stamps[Identity(Item)]
            local Text = TimeTextOf(Entry)
            if not Text then return end
            local Wanted = Stamp and ("[" .. Stamp .. "]") or ""
            if ReadText(Text) ~= Wanted then
                Text:SetText(FText(Wanted))
                if ShowLogged < 3 and Wanted ~= "" then
                    ShowLogged = ShowLogged + 1
                    Log("time %s shown on a message", Wanted)
                end
            end
            local Visibility = Wanted ~= "" and SlateHitTestInvisible or SlateCollapsed
            if Text:GetVisibility() ~= Visibility then Text:SetVisibility(Visibility) end
        end)
        if not Ok then Log("chat entry error: %s", tostring(Error)) end
    end
end

------------------------------------------------------------------------
------------------------------------------------------------------------
-- Channel lock. The chat sends to one channel at a time, picked in its
-- menu (ChatEntryDropdown) or with a keyword typed in the message box:
-- UChatWidget.CurrentMode (EAnvilChatType: 4 WorldTeam "Empire", 5
-- WorldFamily "Family", 6 Local). The game puts it back on Empire when the
-- area changes (a new chat) and when the player changes avatar, so a
-- message meant for the family can reach the whole faction.
--
-- The mod remembers the last channel the player picked, for this game
-- session only (not kept when the game is closed), and picks it again in
-- the chat's menu when the game changes it on its own. It is the same as
-- picking it by hand: the game sends messages as before, to the channel
-- the player chose.
--
-- A change is the player's when it follows, within a second, one of the
-- player's actions in the chat: a pick in the menu with the mouse or the
-- keyboard (OnModeOptionSelected, not "Direct", which is a pick made by
-- code), or typing in the message box (OnEntryChanged / OnEntryCommitted:
-- the keywords). Any other change is the game's.
------------------------------------------------------------------------

-- ESelectInfo: how a menu pick was made. The game ignores picks "by code"
-- (Direct): test of 2026-11-20, SetSelectedOption and OnModeOptionSelected
-- with Direct changed the menu's text but CurrentMode stayed on Empire, so
-- the menu showed Family while messages went to Empire. The mod picks the
-- channel as a mouse click would; the hook knows it is the mod's
-- (Restoring) and does not take it as the player's choice.
local SelectDirect = 3
local SelectMouseClick = 2
local PlayerActionAt = -100
local PlayerAction = "" -- what the player did last, for the log
local Restoring = false
local Wanted = nil -- { Mode, Label } the player picked last
local LabelOfMode = {} -- menu text of each mode, learnt from the player's picks
-- A restore waiting for the channel to be back in the menu: on the
-- deployment screen after a death the menu has no Family (no avatar out)
-- for as long as the player waits to respawn (2026-11-21), and while the
-- game refills it when crossing into another region. Tried twice a second
-- until the channel is back, the chat is on it, or the player picks one.
local Pending = false
local NextRetry = 0
-- Not forever: after this long the wait is dropped (the channel may never
-- come back, for example after leaving the family).
local PendingLimitSeconds = 30 * 60
local PendingSince = 0
-- A pick in the menu by the player, even of the channel already in use:
-- that is the channel wanted from now on, and any wait ends.
local PlayerPicked = false
local SeenMode = nil -- mode last seen on the chat in use
local SeenChat = nil -- full name of that chat
local Restores = {} -- os.clock() of recent restores, to never fight the game
local LockLogged = {}

local function LogOnce(Key, Format, ...)
    if LockLogged[Key] then return end
    LockLogged[Key] = true
    Log(Format, ...)
end

local function NoteAction(What)
    if Restoring then return end
    PlayerActionAt = os.clock()
    PlayerAction = What
end

local function StringOf(Value)
    if type(Value) == "string" then return Value end
    local Ok, Text = pcall(function() return Value:ToString() end)
    return Ok and Text or nil
end

local LockHooksOk, LockHooksError = pcall(function()
    RegisterHook("/Script/Anvil.ChatWidget:OnModeOptionSelected", function(Context, Item, Type)
        if Restoring then return end
        local How, Label = nil, nil
        pcall(function() How = Type:get() end)
        pcall(function() Label = StringOf(Item:get()) end)
        if How ~= SelectDirect then
            NoteAction(string.format("menu pick '%s'", tostring(Label)))
            PlayerPicked = true
        end
    end)
    RegisterHook("/Script/Anvil.ChatWidget:OnEntryChanged", function() NoteAction("typing") end)
    RegisterHook("/Script/Anvil.ChatWidget:OnEntryCommitted", function() NoteAction("sending") end)
end)
if not LockHooksOk then Log("cannot watch the chat's channel menu (%s): no channel lock", tostring(LockHooksError)) end

local function ModeOf(Chat)
    local Ok, Mode = pcall(function() return Chat.CurrentMode end)
    return Ok and tonumber(Mode) or nil
end

local function SelectedLabel(Chat)
    local Ok, Label = pcall(function() return StringOf(Chat.ChatEntryDropdown:GetSelectedOption()) end)
    return Ok and Label or nil
end

-- Picks Label in the chat's menu as a click would. Returns the mode after.
local function Pick(Chat, Dropdown, Label)
    Restoring = true
    pcall(function() Dropdown:SetSelectedOption(Label) end)
    pcall(function() Chat:OnModeOptionSelected(Label, SelectMouseClick) end)
    Restoring = false
    return ModeOf(Chat)
end

-- Returns "later" when the channel is not in the menu yet, true when
-- picked again, false otherwise.
local function Restore(Chat, Now)
    local Dropdown = Chat.ChatEntryDropdown
    if not IsSafe(Dropdown) then return "later" end
    local Index = -1
    pcall(function() Index = Dropdown:FindOptionIndex(Wanted.Label) end)
    if Index < 0 then
        -- The game empties and refills the menu when it changes the channel
        -- (crossing into another region, 2026-11-21) and while a chat is
        -- being taken down: tried again for a few seconds.
        return "later"
    end
    -- At most 3 restores in 10 s: if the game keeps changing it back, let
    -- it.
    local Recent = {}
    for _, At in ipairs(Restores) do
        if Now - At < 10 then Recent[#Recent + 1] = At end
    end
    Restores = Recent
    if #Restores >= 3 then
        LogOnce("fight", "the game keeps changing the channel back: left as the game wants")
        return false
    end
    Restores[#Restores + 1] = Now
    local Before = ModeOf(Chat)
    local BeforeLabel = SelectedLabel(Chat)
    local After = Pick(Chat, Dropdown, Wanted.Label)
    if After == Wanted.Mode then
        Log("channel picked again: %s (was %s)", Wanted.Label, tostring(Before))
        return true
    end
    -- The chat did not follow: the menu must not show a channel the
    -- messages do not go to. Back to what it showed.
    local Shown = LabelOfMode[After] or BeforeLabel
    if Shown and Shown ~= "" then
        Restoring = true
        pcall(function() Dropdown:SetSelectedOption(Shown) end)
        Restoring = false
    end
    Log("channel NOT picked again: %s wanted, chat stays on %s (menu shows '%s')", Wanted.Label,
        tostring(After), tostring(SelectedLabel(Chat)))
    return false
end

local function LockChannel(Chat)
    local Key = Chat:GetFullName()
    local Mode = ModeOf(Chat)
    if Mode == nil then return end
    local Now = os.clock()
    local NewChat = Key ~= SeenChat
    SeenChat = Key
    if PlayerPicked and Now - PlayerActionAt >= 0.1 then
        -- The game has applied the pick by now (the hook runs before it).
        PlayerPicked = false
        Pending = false
        SeenMode = Mode
        local Label = SelectedLabel(Chat)
        if Label and Label ~= "" then
            if not Wanted or Wanted.Mode ~= Mode then
                Log("channel chosen: %s (%d), after %s", Label, Mode, PlayerAction)
            end
            Wanted = { Mode = Mode, Label = Label }
            LabelOfMode[Mode] = Label
        end
        return
    end
    if not NewChat and Mode == SeenMode then
        if Pending and Now >= NextRetry then
            NextRetry = Now + 0.5
            if not Wanted or Mode == Wanted.Mode then
                Pending = false
            elseif Now - PendingSince > PendingLimitSeconds then
                Pending = false
                Log("channel '%s' not back in the chat's menu after %d min: no longer waited for",
                    Wanted.Label, PendingLimitSeconds // 60)
            elseif Now - PlayerActionAt >= 1.0 then
                if Restore(Chat, Now) ~= "later" then Pending = false end
                SeenMode = ModeOf(Chat)
            end
        end
        return
    end
    Pending = false
    SeenMode = Mode
    if Now - PlayerActionAt < 1.0 then
        local Label = SelectedLabel(Chat)
        if Label and Label ~= "" then
            if not Wanted or Wanted.Mode ~= Mode then
                Log("channel chosen: %s (%d), after %s", Label, Mode, PlayerAction)
            end
            Wanted = { Mode = Mode, Label = Label }
            LabelOfMode[Mode] = Label
        end
        return
    end
    if Wanted and Mode ~= Wanted.Mode then
        if Restore(Chat, Now) == "later" then
            Pending = true
            PendingSince = Now
            NextRetry = Now + 0.5
            Log("channel '%s' is not in the chat's menu now: picked again when it is back", Wanted.Label)
        end
        SeenMode = ModeOf(Chat)
    end
end


-- Poll. The messages changed when the chat, the count, or the first or
-- last message changed (with a capped history the count stays the same
-- while a new message pushes an old one out). The entries change when the
-- messages change or the list scrolls (entries reused for other
-- messages): they are refreshed for a second after either, and every 2 s
-- anyway.
------------------------------------------------------------------------

local LastItems = nil
local LastOffset = nil
local BusyUntil = 0
local NextFullUpdate = 0

local function EndIdentity(Items, Index)
    if Index < 1 then return "-" end
    local Item = Items[Index]
    return IsSafe(Item) and Identity(Item) or "?"
end

local function Poll()
    if WorldIsSettling() then return end
    if EntriesStale then
        EntriesStale = false
        LastItems = nil
        LastOffset = nil
        ChatPath, ChatKey = nil, nil
    end
    local Chat, OnScreen = FindChat()
    if not Chat then return end
    local List = Chat.ChatHistoryListView
    if not IsSafe(List) then return end
    local Items = List.ListItems
    local Count = #Items
    local ItemsNow = string.format("%s|%d|%s|%s", Chat:GetFullName(), Count, EndIdentity(Items, 1),
        EndIdentity(Items, Count))
    local Now = os.clock()
    if ItemsNow ~= LastItems then
        LastItems = ItemsNow
        BusyUntil = Now + 1.0
        local PatchOk, PatchError = pcall(PatchEntryClass, List)
        if not PatchOk then Log("entry class error: %s", tostring(PatchError)) end
        NoteNewItems(Chat, List)
    end
    local Offset = 0
    pcall(function() Offset = List:GetScrollOffset() end)
    if Offset ~= LastOffset then
        LastOffset = Offset
        BusyUntil = Now + 1.0
    end
    if OnScreen and LockHooksOk then
        local LockOk, LockError = pcall(LockChannel, Chat)
        if not LockOk then Log("channel lock error: %s", tostring(LockError)) end
    end
    if OnScreen and (Now < BusyUntil or Now >= NextFullUpdate) then
        NextFullUpdate = Now + 2.0
        UpdateEntries(List)
    end
end

------------------------------------------------------------------------
-- Probe (Ctrl+F10): the chat's layout and what its entries hold.
------------------------------------------------------------------------

local Visibilities = { [0] = "Visible", "Collapsed", "Hidden", "HitTestInvisible", "SelfHitTestInvisible" }

local function Looks(Widget)
    local Ok, Text = pcall(function()
        if not Widget or not IsSafe(Widget) then return "missing" end
        local Visibility = Widget:GetVisibility()
        return Visibilities[Visibility] or tostring(Visibility)
    end)
    return Ok and Text or "?"
end

local function LogTree(Widget, Depth)
    if Depth > 8 or not Widget or not IsSafe(Widget) then return end
    local Extra = ""
    if ClassName(Widget) == "TextBlock" then Extra = " '" .. ReadText(Widget) .. "'" end
    Log("%s%s %s: %s%s", string.rep("  ", Depth), ClassName(Widget), Widget:GetFName():ToString(), Looks(Widget), Extra)
    local Ok, Count = pcall(function() return Widget:GetChildrenCount() end)
    if not Ok then return end
    for Index = 0, Count - 1 do LogTree(Widget:GetChildAt(Index), Depth + 1) end
end

local function Probe()
    for _, Each in ipairs(FindAllOf("ChatWidget") or {}) do
        if IsSafe(Each) and IsLiveWidget(Each) then
            local Shown = "?"
            pcall(function() Shown = tostring(Each:IsVisible()) end)
            Log("live chat %s, on screen %s", Identity(Each), Shown)
        end
    end
    local Chat = FindChat()
    if not Chat then
        Log("probe: no live chat widget")
        return
    end
    Log("chat %s, %s, mode %s", Chat:GetFullName(), Looks(Chat), tostring(Chat.CurrentMode))
    pcall(function()
        local Dropdown = Chat.ChatEntryDropdown
        local Options = {}
        for Index = 0, Dropdown:GetOptionCount() - 1 do
            Options[#Options + 1] = tostring(StringOf(Dropdown:GetOptionAtIndex(Index)))
        end
        Log("channel menu: '%s' selected, options %s; locked on %s", tostring(SelectedLabel(Chat)),
            table.concat(Options, ", "), Wanted and string.format("%s (%d)", Wanted.Label, Wanted.Mode) or "nothing")
    end)
    LogTree(Chat.WidgetTree.RootWidget, 1)
    local List = Chat.ChatHistoryListView
    local Items = List.ListItems
    Log("list: %d item(s), scroll offset %s", #Items, tostring(List:GetScrollOffset()))
    pcall(function()
        local Class = List.EntryWidgetClass
        local Root = Class.WidgetTree.RootWidget
        local Kept = "?"
        pcall(function() Kept = tostring(Root:HasAnyInternalFlags(RootSetFlag)) end)
        Log("entry class %s, its root %s %s (kept: %s)", Class:GetFullName(), ClassName(Root),
            Root:GetFName():ToString(), Kept)
    end)
    for Index = math.max(1, #Items - 4), #Items do
        local Item = Items[Index]
        if IsSafe(Item) then
            local Stamp = Stamps[Identity(Item)]
            Log("  item %d: %s %s, time %s", Index, ClassName(Item), Identity(Item), tostring(Stamp))
        end
    end
    local Entries = DisplayedEntries(List)
    Log("%d displayed entr(ies)", #Entries)
    for Index, Entry in ipairs(Entries) do
        local Inner = Entry.ChatEntryInternal
        local Item = ItemOf(Entry)
        Log("entry %d %s: item %s, sender '%s', message '%s', type %s, team %s", Index, Identity(Entry),
            Item and Identity(Item) or "none", IsSafe(Inner) and ReadString(Inner.SenderName) or "?",
            IsSafe(Inner) and ReadString(Inner.Message) or "?", IsSafe(Inner) and tostring(Inner.ChatType) or "?",
            IsSafe(Inner) and tostring(Inner.TeamId) or "?")
        if Index <= 2 then LogTree(Entry.WidgetTree.RootWidget, 1) end
    end
end

RegisterDevKey(Key.F10, function()
    ExecuteInGameThread(function()
        Log("chat probe:")
        local Ok, Error = pcall(Probe)
        if not Ok then Log("probe error: %s", tostring(Error)) end
        Log("chat probe done")
        -- Test of the widgets added to the entry class: a garbage
        -- collection right now (the game crashed at one with 0.1.0's
        -- first try).
        local GcOk = pcall(function() StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage() end)
        Log("garbage collection %s", GcOk and "asked" or "could not be asked")
    end)
end)

-- On the game thread, between frames (never UE4SS's async loop: it runs
-- Lua on its own thread and corrupted the Lua state).
LoopInGameThreadWithDelay(100, function()
    local Ok, Error = pcall(Poll)
    if not Ok then Log("poll error: %s", tostring(Error)) end
end)

Log("v%s loaded%s", Version, DevTools and " (dev key: Ctrl+F10 probe)" or "")
