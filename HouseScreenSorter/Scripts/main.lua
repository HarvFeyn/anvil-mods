--[[
    HouseScreenSorter: sorts the family house member list by role and name,
    and adds an Online-Only filter toggle button to the House action strip.

    Display only: sorts existing member widgets in FamilyMembersScrollBox and
    toggles visibility on offline member rows. Never alters member roles or
    sends unauthorized commands to the server.

    Developer keys (game window focused; only with ue4ss\Mods\AnvilModsDev.txt,
    which install.ps1 creates):
      Ctrl+F4  probe: log the House window's member count and sort hierarchy
--]]

local UEHelpers = require("UEHelpers")

-- Bump with each release (and tag the release vX.Y.Z on GitHub).
local Version = "0.1.0"

local function Log(Format, ...)
    print("[HouseScreenSorter] " .. string.format(Format, ...) .. "\n")
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
-- and reading those parts crashed the game. IsSafe also refuses objects flagged as being
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

-- Pause while changing areas (connecting, caves, returning to main menu).
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

local ROLE_RANKS = {
    ["founder"] = 1,
    ["manager"] = 2,
    ["member"]  = 3,
    ["guest"]   = 4,
    ["public"]  = 5
}

local cachedItemWidgetClass = nil
local dummyWidgetClass = nil
local cachedActiveIconTex = nil
local cachedDeactiveIconTex = nil
local isSorting = false
local wasWindowVisible = false
local onlineOnlyFilter = false
local onlineFilterBtnOff = nil
local onlineFilterBtnOn = nil
local onlineFilterBtnOffAddr = nil
local onlineFilterBtnOnAddr = nil
local configuredStripAddr = nil

local function ResetTransientState()
    cachedItemWidgetClass = nil
    dummyWidgetClass = nil
    onlineFilterBtnOff = nil
    onlineFilterBtnOn = nil
    onlineFilterBtnOffAddr = nil
    onlineFilterBtnOnAddr = nil
    configuredStripAddr = nil
    wasWindowVisible = false
    isSorting = false
end

local function WorldIsSettling()
    if Loading then
        ResetTransientState()
        return true
    end
    if os.clock() < ResumeAt then
        return true
    end
    return false
end

local function SafeString(textObj)
    if not textObj then return "" end
    if type(textObj) == "userdata" and textObj.ToString then
        local ok, str = pcall(function() return textObj:ToString() end)
        if ok and str then return str end
    end
    return tostring(textObj)
end

local function Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Helper to import a .png from HouseScreenSorter/Scripts/ via UKismetRenderingLibrary::ImportFileAsTexture2D
local function LoadPngTexture(contextObj, fileName)
    local krl = nil
    pcall(function()
        krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    end)
    if not IsSafe(krl) then return nil end

    local candidatePaths = {}
    pcall(function()
        local src = debug.getinfo(1, "S").source or ""
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        local dir = src:match("^(.*[/\\])")
        if dir then
            table.insert(candidatePaths, dir .. fileName)
            table.insert(candidatePaths, (dir:gsub("\\", "/")) .. fileName)
        end
    end)
    table.insert(candidatePaths, "ue4ss/Mods/HouseScreenSorter/Scripts/" .. fileName)
    table.insert(candidatePaths, "Anvil/Binaries/Win64/ue4ss/Mods/HouseScreenSorter/Scripts/" .. fileName)

    local worldCtx = IsSafe(contextObj) and contextObj or krl
    for _, path in ipairs(candidatePaths) do
        local tex = nil
        pcall(function()
            tex = krl:ImportFileAsTexture2D(worldCtx, path)
        end)
        if IsSafe(tex) then
            return tex
        end
    end
    return nil
end

-- Resolves the Active (ActionButtons_Players) and Deactivated (ActionButtons_PlayersDeactivated) button textures
local function GetFilterButtonTextures(contextObj)
    if not IsSafe(cachedActiveIconTex) then
        pcall(function()
            cachedActiveIconTex = StaticFindObject("/Game/Textures/UI/ActionButtons_Players.ActionButtons_Players")
        end)
        if not IsSafe(cachedActiveIconTex) then
            cachedActiveIconTex = LoadPngTexture(contextObj, "ActionButtons_Players.png")
        end
        if not IsSafe(cachedActiveIconTex) then
            pcall(function()
                cachedActiveIconTex = StaticFindObject("/Game/Textures/UI/Actions/ActionButtons_UpvoteActive.ActionButtons_UpvoteActive")
            end)
        end
    end

    if not IsSafe(cachedDeactiveIconTex) then
        cachedDeactiveIconTex = LoadPngTexture(contextObj, "ActionButtons_PlayersDeactivated.png")
        if not IsSafe(cachedDeactiveIconTex) then
            pcall(function()
                cachedDeactiveIconTex = StaticFindObject("/Game/Textures/UI/Actions/ActionButtons_UpvoteDeactive.ActionButtons_UpvoteDeactive")
            end)
        end
    end

    return cachedDeactiveIconTex, cachedActiveIconTex
end

-- Checks whether a BPFamilyMemberListItem_C row is Online/Deployed (true) vs Offline (false)
local function IsMemberOnline(itemWidget)
    if not IsSafe(itemWidget) then return false end

    local isOnline = true
    pcall(function()
        local icon = itemWidget.OnlineStatusIcon
        if IsSafe(icon) then
            local res = icon.Brush and icon.Brush.ResourceObject
            if IsSafe(res) then
                local full = res:GetFullName()
                if full:find("Offline", 1, true) then
                    isOnline = false
                elseif full:find("Online", 1, true) or full:find("Deployed", 1, true) then
                    isOnline = true
                end
            end
        end
    end)

    return isOnline
end

-- Applies visibility filter (0 = Visible, 1 = Collapsed) to rows based on onlineOnlyFilter
local function ApplyOnlineVisibilityFilter(memberList)
    local onlineCount = 0
    for _, m in ipairs(memberList) do
        local w = m.widget
        if IsSafe(w) then
            local online = (m.isOnline ~= nil) and m.isOnline or IsMemberOnline(w)
            if online then
                onlineCount = onlineCount + 1
            end
            pcall(function()
                if onlineOnlyFilter and not online then
                    w:SetVisibility(1) -- ESlateVisibility::Collapsed
                else
                    w:SetVisibility(0) -- ESlateVisibility::Visible
                end
            end)
        end
    end
    return onlineCount
end

-- Swaps visibility between the OFF button (ActionButtons_PlayersDeactivated) and ON button (ActionButtons_Players)
local function UpdateOnlineFilterButtonVisuals()
    pcall(function()
        if IsSafe(onlineFilterBtnOff) then
            local showOff = not onlineOnlyFilter
            onlineFilterBtnOff:SetVisibility(showOff and 0 or 1)
            local ab = onlineFilterBtnOff.ActionButton
            if IsSafe(ab) then
                ab:SetVisibility(showOff and 0 or 1)
                ab:SetIsEnabled(true)
            end
        end

        if IsSafe(onlineFilterBtnOn) then
            local showOn = onlineOnlyFilter
            onlineFilterBtnOn:SetVisibility(showOn and 0 or 1)
            local ab = onlineFilterBtnOn.ActionButton
            if IsSafe(ab) then
                ab:SetVisibility(showOn and 0 or 1)
                ab:SetIsEnabled(true)
            end
        end
    end)
end

-- Constructs paired OFF/ON BPBaseActionButton_C widgets in BPFamilyWindow.BPActionStrip
local function EnsureOnlineFilterButton(window)
    if not IsSafe(window) then return end

    local actionStrip = nil
    pcall(function() actionStrip = window.BPActionStrip end)
    if not IsSafe(actionStrip) then return end

    local stripAddr = actionStrip:GetAddress()
    if configuredStripAddr == stripAddr
        and IsSafe(onlineFilterBtnOff)
        and IsSafe(onlineFilterBtnOn) then
        UpdateOnlineFilterButtonVisuals()
        return
    end

    local refBtn = nil
    pcall(function() refBtn = actionStrip.EditSignPost or actionStrip.ClaimFamilyArea end)
    if not IsSafe(refBtn) then return end

    local hbox = nil
    pcall(function() hbox = refBtn:GetParent() end)
    if not IsSafe(hbox) then return end

    local deactiveTex, activeTex = GetFilterButtonTextures(window)

    -- 1. Collapse BPActionStrip's fill Spacer (Slot[36]) so our button sits directly next to the 4 House buttons
    pcall(function()
        local count = hbox:GetChildrenCount() or 0
        for i = 0, count - 1 do
            local child = hbox:GetChildAt(i)
            if IsSafe(child) then
                local full = child:GetFullName()
                if full:find("Spacer", 1, true) then
                    child:SetVisibility(1) -- ESlateVisibility::Collapsed
                elseif i >= 42 then
                    child:SetVisibility(1)
                    if IsSafe(child.ActionButton) then
                        child.ActionButton:SetVisibility(1)
                    end
                end
            end
        end
    end)

    -- 2. Construct two fresh BPBaseActionButton_C widgets (OFF and ON)
    local function CreateStripButton(tex)
        local created = nil
        pcall(function()
            local btnClass = refBtn:GetClass()
            if IsSafe(btnClass) then
                local newBtn = StaticConstructObject(btnClass, actionStrip)
                if IsSafe(newBtn) then
                    -- ActionButtonType = 37 avoids the default tooltip
                    pcall(function() newBtn.ActionButtonType = 37 end)
                    if IsSafe(tex) then
                        newBtn.ButtonImageOverride = tex
                    end
                    local newSlot = hbox:AddChildToHorizontalBox(newBtn)
                    if IsSafe(newSlot) then
                        pcall(function() newSlot:SetVerticalAlignment(2) end) -- VAlign_Center
                    end
                    created = newBtn
                end
            end
        end)
        return created
    end

    onlineFilterBtnOff = CreateStripButton(deactiveTex or activeTex)
    onlineFilterBtnOn  = CreateStripButton(activeTex or deactiveTex)

    if IsSafe(onlineFilterBtnOff) and IsSafe(onlineFilterBtnOn) then
        onlineFilterBtnOffAddr = onlineFilterBtnOff:GetAddress()
        onlineFilterBtnOnAddr  = onlineFilterBtnOn:GetAddress()
        configuredStripAddr    = stripAddr
        UpdateOnlineFilterButtonVisuals()
    end
end

-- Cache the original BPFamilyMemberListItem_C UClass pointer before locking FamilyMemberListItemWidgetType
local function CacheOriginalWidgetClass(window)
    if IsSafe(cachedItemWidgetClass) then
        return cachedItemWidgetClass
    end

    if IsSafe(window) then
        pcall(function()
            local cur = window.FamilyMemberListItemWidgetType
            if IsSafe(cur) then
                local full = cur:GetFullName()
                if not full:find("UMG.UserWidget", 1, true) then
                    cachedItemWidgetClass = cur
                end
            end
        end)
    end

    if not IsSafe(cachedItemWidgetClass) then
        pcall(function()
            local items = FindAllOf("BPFamilyMemberListItem_C") or {}
            for _, item in ipairs(items) do
                if IsSafe(item) then
                    local cls = item:GetClass()
                    if IsSafe(cls) then
                        cachedItemWidgetClass = cls
                        break
                    end
                end
            end
        end)
    end

    if not IsSafe(cachedItemWidgetClass) then
        pcall(function()
            cachedItemWidgetClass = StaticFindObject("/Game/UI/Gameplay/StructureWindows/BPFamilyMemberListItem.BPFamilyMemberListItem_C")
        end)
    end

    return cachedItemWidgetClass
end

local function GetDummyWidgetClass()
    if not IsSafe(dummyWidgetClass) then
        pcall(function()
            dummyWidgetClass = StaticFindObject("/Script/UMG.UserWidget")
        end)
    end
    return dummyWidgetClass
end

-- Trips the IsChildOf(UFamilyMemberListItemWidget) check so UFamilyWindow::NativeTick
-- exits without overwriting FamilyMembersScrollBox children in-place.
local function LockWindowTick(window)
    if not IsSafe(window) then return end
    CacheOriginalWidgetClass(window)
    pcall(function()
        local dummy = GetDummyWidgetClass()
        if IsSafe(dummy) then
            window.FamilyMemberListItemWidgetType = dummy
        else
            window.FamilyMemberListItemWidgetType = nil
        end
    end)
end

-- Restores BPFamilyMemberListItem_C on UFamilyWindow so C++ NativeTick can populate rows
local function UnlockWindowTick(window)
    if not IsSafe(window) then return end
    CacheOriginalWidgetClass(window)
    if IsSafe(cachedItemWidgetClass) then
        pcall(function()
            window.FamilyMemberListItemWidgetType = cachedItemWidgetClass
        end)
    end
end

-- Reads player name, role, and online status
local function GetMemberInfo(itemWidget)
    if not IsSafe(itemWidget) then return nil end

    local name = ""
    local role = ""

    pcall(function()
        local fnText = itemWidget:GetPlayerNameText()
        if fnText then
            name = Trim(SafeString(fnText))
        end
    end)
    if name == "" then
        pcall(function()
            local nameBox = itemWidget.PlayerNameText
            if IsSafe(nameBox) then
                name = Trim(SafeString(nameBox:GetText()))
            end
        end)
    end

    pcall(function()
        local fnRole = itemWidget:GetRoleText()
        if fnRole then
            role = Trim(SafeString(fnRole))
        end
    end)
    if role == "" then
        pcall(function()
            if IsSafe(itemWidget.RoleComboBox) then
                local sel = itemWidget.RoleComboBox:GetSelectedOption()
                if sel then role = Trim(SafeString(sel)) end
            end
            if role == "" and IsSafe(itemWidget.RoleTextBlock) then
                role = Trim(SafeString(itemWidget.RoleTextBlock:GetText()))
            end
        end)
    end

    local lowerRole = string.lower(role)
    local rank = 5
    for keyword, rRank in pairs(ROLE_RANKS) do
        if lowerRole:find(keyword, 1, true) then
            rank = rRank
            break
        end
    end

    return {
        widget   = itemWidget,
        name     = name,
        role     = role,
        rank     = rank,
        isOnline = IsMemberOnline(itemWidget)
    }
end

local function ResolveScrollBoxChildren(scrollBox, window)
    local items = {}

    local childCount = -1
    local ok1 = pcall(function() childCount = scrollBox:GetChildrenCount() end)
    if ok1 and childCount and childCount > 0 then
        for i = 0, childCount - 1 do
            local ok, child = pcall(function() return scrollBox:GetChildAt(i) end)
            if ok and IsSafe(child) then
                table.insert(items, child)
            end
        end
        return items
    end

    if scrollBox.Slots then
        pcall(function()
            local numSlots = #scrollBox.Slots
            for i = 1, numSlots do
                local slot = scrollBox.Slots[i]
                if IsSafe(slot) and IsSafe(slot.Content) then
                    table.insert(items, slot.Content)
                end
            end
        end)
        if #items > 0 then
            return items
        end
    end

    if IsSafe(window) then
        local winName = window:GetFName():ToString()
        local allItems = FindAllOf("BPFamilyMemberListItem_C") or {}
        for _, item in ipairs(allItems) do
            if IsSafe(item) then
                local full = item:GetFullName()
                if full:find(winName, 1, true) and not full:find("Default__") then
                    table.insert(items, item)
                end
            end
        end
    end

    return items
end

local function GetActiveFamilyWindow()
    if WorldIsSettling() then return nil end

    local windows = FindAllOf("BPFamilyWindow_C") or {}
    if #windows == 0 then
        windows = FindAllOf("FamilyWindow") or {}
    end

    for _, win in ipairs(windows) do
        if IsSafe(win) then
            local full = win:GetFullName()
            if not full:find("Default__") then
                return win
            end
        end
    end
    return nil
end

local function SortFamilyMembers(window, forceLock)
    if isSorting then return false end
    if not IsSafe(window) or WorldIsSettling() then return false end

    EnsureOnlineFilterButton(window)

    local scrollBox = window.FamilyMembersScrollBox
    if not IsSafe(scrollBox) then return false end

    CacheOriginalWidgetClass(window)
    isSorting = true

    local items = ResolveScrollBoxChildren(scrollBox, window)
    if #items == 0 then
        isSorting = false
        return false
    end

    local memberList = {}
    local namedCount = 0
    for idx, child in ipairs(items) do
        local info = GetMemberInfo(child)
        if info and info.name ~= "" then
            info.origIndex = idx
            namedCount = namedCount + 1
            table.insert(memberList, info)
        else
            table.insert(memberList, {
                widget    = child,
                name      = "~~~",
                role      = info and info.role or "unknown",
                rank      = (info and info.rank) or 99,
                isOnline  = info and info.isOnline or false,
                origIndex = idx
            })
        end
    end

    if namedCount == 0 and not forceLock then
        isSorting = false
        return false
    end

    table.sort(memberList, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        local nameA = string.lower(a.name)
        local nameB = string.lower(b.name)
        if nameA ~= nameB then
            return nameA < nameB
        end
        return a.origIndex < b.origIndex
    end)

    local alreadySorted = true
    for i = 1, #items do
        if items[i]:GetAddress() ~= memberList[i].widget:GetAddress() then
            alreadySorted = false
            break
        end
    end

    if not alreadySorted and #items > 1 then
        pcall(function()
            scrollBox:ClearChildren()
            for _, m in ipairs(memberList) do
                scrollBox:AddChild(m.widget)
            end
        end)
    end

    ApplyOnlineVisibilityFilter(memberList)

    if namedCount >= #items or forceLock then
        LockWindowTick(window)
    end

    isSorting = false
    return true
end

local function RefreshAndSortWindow()
    ExecuteInGameThread(function()
        if WorldIsSettling() then return end
        local win = GetActiveFamilyWindow()
        if IsSafe(win) then
            UnlockWindowTick(win)
            EnsureOnlineFilterButton(win)
        end
    end)

    local delays = {60, 160, 350}
    for idx, d in ipairs(delays) do
        local isFinal = (idx == #delays)
        ExecuteInGameThreadWithDelay(d, function()
            if WorldIsSettling() then return end
            local win = GetActiveFamilyWindow()
            if IsSafe(win) then
                local isVis = false
                pcall(function() isVis = win:IsVisible() end)
                if isVis then
                    SortFamilyMembers(win, isFinal)
                end
            end
        end)
    end
end

local function IsOurFilterButton(btn)
    if not IsSafe(btn) then return false end
    local addr = btn:GetAddress()
    return (addr ~= nil) and (addr == onlineFilterBtnOffAddr or addr == onlineFilterBtnOnAddr)
end

pcall(function()
    RegisterHook("/Script/Anvil.ActionButtonWidget:OnClicked",
        function(Context)
            local self = Context:get()
            if IsOurFilterButton(self) then
                pcall(function()
                    if IsSafe(self.ActionButton) then
                        self.ActionButton:SetIsEnabled(false)
                    end
                end)
            end
        end,
        function(Context)
            local self = Context:get()
            if IsOurFilterButton(self) then
                onlineOnlyFilter = not onlineOnlyFilter
                UpdateOnlineFilterButtonVisuals()
                local win = GetActiveFamilyWindow()
                if IsSafe(win) then
                    SortFamilyMembers(win, true)
                end
                RefreshAndSortWindow()
            end
        end
    )
end)

-- Hook F2 (native Toggle House Screen key) safely on game thread
RegisterKeyBind(Key.F2, {}, function()
    ExecuteInGameThread(function()
        RefreshAndSortWindow()
    end)
end)

pcall(function()
    RegisterHook("/Script/Anvil.GameplayScreen:HandleFamilyScreenButtonClicked", function(self)
        ExecuteInGameThread(function()
            RefreshAndSortWindow()
        end)
    end)
end)

pcall(function()
    RegisterHook("/Script/Anvil.FamilyMemberListItemWidget:OnFamilyRoleSelectionChanged", function(self)
        ExecuteInGameThread(function()
            RefreshAndSortWindow()
        end)
    end)
end)

pcall(function()
    RegisterHook("/Script/Anvil.FamilyMemberListItemWidget:OnKickButtonClicked", function(self)
        ExecuteInGameThread(function()
            RefreshAndSortWindow()
        end)
    end)
end)

-- Developer probe key: Ctrl+F4 logs House screen debug information
RegisterDevKey("F4", function()
    ExecuteInGameThread(function()
        local win = GetActiveFamilyWindow()
        if not IsSafe(win) then
            Log("probe: no active House window found")
            return
        end
        local scrollBox = win.FamilyMembersScrollBox
        local count = IsSafe(scrollBox) and (scrollBox:GetChildrenCount() or 0) or 0
        Log("probe: House window 0x%X, %d member rows, online-only filter: %s",
            win:GetAddress(), count, tostring(onlineOnlyFilter))
    end)
end)

-- Main keeper loop running strictly in the game thread
LoopInGameThreadWithDelay(200, function()
    if WorldIsSettling() then
        wasWindowVisible = false
        return
    end

    local win = GetActiveFamilyWindow()
    if not IsSafe(win) then
        wasWindowVisible = false
        return
    end

    local isVis = false
    pcall(function() isVis = win:IsVisible() end)

    if isVis then
        if not wasWindowVisible then
            wasWindowVisible = true
            UnlockWindowTick(win)
            RefreshAndSortWindow()
        else
            SortFamilyMembers(win, false)
        end
    else
        if wasWindowVisible then
            wasWindowVisible = false
            UnlockWindowTick(win)
        end
    end
end)

Log("v%s loaded", Version)
