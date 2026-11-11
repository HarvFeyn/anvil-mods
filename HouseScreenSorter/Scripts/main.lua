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
local Version = "0.2.0"

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

-- Identifies a game object by address and unique name without holding its userdata.
local function Identity(Object)
    return string.format("%X|%s", Object:GetAddress(), Object:GetFName():ToString())
end

-- Only widgets built at runtime live under /Engine/Transient. The others are
-- templates inside window classes (WidgetTree...) and must not be touched.
local function IsLiveWidget(Widget)
    local Path = string.match(Widget:GetFullName(), "^%S+%s+(%S+)")
    return Path ~= nil and string.sub(Path, 1, 17) == "/Engine/Transient"
end

local ROLE_RANKS = {
    ["founder"] = 1,
    ["manager"] = 2,
    ["member"]  = 3,
    ["guest"]   = 4,
    ["public"]  = 5
}

-- Transient state variables: we store ZERO live UObject pointers across ticks.
-- Widgets are resolved on the current tick from their live parent panel by address.
local isSorting = false
local wasWindowVisible = false
local onlineOnlyFilter = false
local onlineFilterBtnOffAddr = nil
local onlineFilterBtnOnAddr = nil
local configuredStripAddr = nil
local cachedItemWidgetClass = nil

local function ResetTransientState()
    onlineFilterBtnOffAddr = nil
    onlineFilterBtnOnAddr = nil
    configuredStripAddr = nil
    cachedItemWidgetClass = nil
    wasWindowVisible = false
    isSorting = false
end

local HooksOk = pcall(function()
    RegisterLoadMapPreHook(function()
        Loading = true
        ResetTransientState()
    end)
    RegisterLoadMapPostHook(function()
        Loading = false
        ResumeAt = os.clock() + ResumeSeconds
        ResetTransientState()
    end)
end)
if not HooksOk then Log("load map hooks not available: pausing on HUD changes only") end

-- Backup in case an area change happens without a map load: monitor AnvilHUD instance changes.
local LastHud = nil
local NextHudCheck = 0

local function WorldIsSettling()
    if Loading then
        ResetTransientState()
        return true
    end
    local Now = os.clock()
    if Now >= NextHudCheck then
        NextHudCheck = Now + 0.5
        local Hud = "none"
        for _, Actor in ipairs(FindAllOf("AnvilHUD") or {}) do
            if IsSafe(Actor) and not string.find(Actor:GetFullName(), "Default__", 1, true) then
                Hud = Identity(Actor)
                break
            end
        end
        if Hud ~= LastHud then
            if LastHud ~= nil then
                ResumeAt = math.max(ResumeAt, Now + ResumeSeconds)
                ResetTransientState()
            end
            LastHud = Hud
        end
    end
    return Now < ResumeAt
end

local function SafeString(textObj)
    if not textObj then return "" end
    if type(textObj) == "userdata" then
        local ok, str = pcall(function()
            local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
            if IsSafe(lib) and lib.Conv_TextToString then
                return lib:Conv_TextToString(textObj)
            end
            if textObj.ToString then return textObj:ToString() end
        end)
        if ok and str and type(str) == "string" then return str end
        if textObj.ToString then
            local ok2, str2 = pcall(function() return textObj:ToString() end)
            if ok2 and str2 then return str2 end
        end
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
    local activeTex = nil
    pcall(function()
        activeTex = StaticFindObject("/Game/Textures/UI/ActionButtons_Players.ActionButtons_Players")
    end)
    if not IsSafe(activeTex) then
        activeTex = LoadPngTexture(contextObj, "ActionButtons_Players.png")
    end
    if not IsSafe(activeTex) then
        pcall(function()
            activeTex = StaticFindObject("/Game/Textures/UI/Actions/ActionButtons_UpvoteActive.ActionButtons_UpvoteActive")
        end)
    end

    local deactiveTex = LoadPngTexture(contextObj, "ActionButtons_PlayersDeactivated.png")
    if not IsSafe(deactiveTex) then
        pcall(function()
            deactiveTex = StaticFindObject("/Game/Textures/UI/Actions/ActionButtons_UpvoteDeactive.ActionButtons_UpvoteDeactive")
        end)
    end

    return deactiveTex, activeTex
end

local TooltipAsset = "/Game/UI/Gameplay/BPTooltipWidget"
local TooltipClass = TooltipAsset .. ".BPTooltipWidget_C"
local SlateCollapsed = 1

-- Gives a button the game's native dark translucent BPTooltipWidget
local function SetNativeTooltip(Button, Header, Body)
    if not IsSafe(Button) then return end
    local ok = pcall(function()
        local Class = StaticFindObject(TooltipClass)
        if not Class or not IsSafe(Class) then
            LoadAsset(TooltipAsset)
            Class = StaticFindObject(TooltipClass)
        end
        local PlayerController = UEHelpers.GetPlayerController()
        local Library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local Tooltip = Library:Create(PlayerController, Class, PlayerController)
        if IsSafe(Tooltip) then
            if IsSafe(Tooltip.HeaderText) then
                Tooltip.HeaderText:SetText(FText(Header))
            end
            if IsSafe(Tooltip.BodyText) then
                Tooltip.BodyText:SetText(FText(Body))
            end
            for _, Unused in ipairs({ "BodyExtraText", "FooterText", "ResourceBar", "ResourcesContainer", "ResourcesFooterText" }) do
                pcall(function()
                    if IsSafe(Tooltip[Unused]) then
                        Tooltip[Unused]:SetVisibility(SlateCollapsed)
                    end
                end)
            end
            Button:SetToolTip(Tooltip)
            if IsSafe(Button.ActionButton) then
                Button.ActionButton:SetToolTip(Tooltip)
            end
        end
    end)
    if not ok then
        pcall(function()
            Button:SetToolTipText(FText(Header .. "\n" .. Body))
        end)
    end
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

-- Finds a live child widget inside a panel by memory address without retaining UObject references
local function FindChildByAddress(Panel, Address)
    if not IsSafe(Panel) or not Address then return nil end
    local count = 0
    pcall(function() count = Panel:GetChildrenCount() or 0 end)
    for Index = 0, count - 1 do
        local child = nil
        pcall(function() child = Panel:GetChildAt(Index) end)
        if IsSafe(child) and child:GetAddress() == Address then
            return child
        end
    end
    return nil
end

-- Swaps visibility between the OFF button (ActionButtons_PlayersDeactivated) and ON button (ActionButtons_Players)
local function UpdateOnlineFilterButtonVisuals(hbox)
    local offBtn = FindChildByAddress(hbox, onlineFilterBtnOffAddr)
    local onBtn  = FindChildByAddress(hbox, onlineFilterBtnOnAddr)

    pcall(function()
        if IsSafe(offBtn) then
            local showOff = not onlineOnlyFilter
            offBtn:SetVisibility(showOff and 0 or 1)
            local ab = offBtn.ActionButton
            if IsSafe(ab) then
                ab:SetVisibility(showOff and 0 or 1)
                ab:SetIsEnabled(true)
            end
        end

        if IsSafe(onBtn) then
            local showOn = onlineOnlyFilter
            onBtn:SetVisibility(showOn and 0 or 1)
            local ab = onBtn.ActionButton
            if IsSafe(ab) then
                ab:SetVisibility(showOn and 0 or 1)
                ab:SetIsEnabled(true)
            end
        end
    end)
end

-- Constructs paired OFF/ON BPBaseActionButton_C widgets in BPFamilyWindow.BPActionStrip.
-- Matches native brown bevel button styling, 32x32 size, and hover/click cues.
local function EnsureOnlineFilterButton(window)
    if not IsSafe(window) then return end

    local actionStrip = nil
    pcall(function() actionStrip = window.BPActionStrip end)
    if not IsSafe(actionStrip) then return end

    local stripAddr = actionStrip:GetAddress()
    local refBtn = nil
    pcall(function() refBtn = actionStrip.EditSignPost or actionStrip.ClaimFamilyArea end)
    if not IsSafe(refBtn) then return end

    local hbox = nil
    pcall(function() hbox = refBtn:GetParent() end)
    if not IsSafe(hbox) then return end

    if configuredStripAddr == stripAddr
        and onlineFilterBtnOffAddr and FindChildByAddress(hbox, onlineFilterBtnOffAddr)
        and onlineFilterBtnOnAddr  and FindChildByAddress(hbox, onlineFilterBtnOnAddr) then
        UpdateOnlineFilterButtonVisuals(hbox)
        return
    end

    -- 1. Clean up BPActionStrip children:
    --    - Collapse BPActionStrip's fill Spacer (Spacer_77) so our button sits directly next to the House buttons.
    --    - Collapse any leftover injected buttons from prior Ctrl+R hot-reloads (matching by class name).
    pcall(function()
        local count = hbox:GetChildrenCount() or 0
        for i = 0, count - 1 do
            local child = hbox:GetChildAt(i)
            if IsSafe(child) then
                local name = child:GetFName():ToString()
                if name:find("^Spacer") or name:find("^SizeBox_") or name:find("^BPBaseActionButton_C_") then
                    child:SetVisibility(1) -- ESlateVisibility::Collapsed
                end
            end
        end
    end)

    -- Dynamically copy ActionButtonType from the native Upgrade button on the same strip.
    -- In UActionButtonWidget::NativeOnMouseEnter (0x144CE5F90), ActionButtonType == Upgrade with
    -- GetCurrentStructureEntity() == nullptr skips CreateActionButtonTooltip entirely, preserving
    -- our custom tooltip without hardcoding fragile enum values across game patches.
    local safeActionType = 39 -- default for current build
    pcall(function()
        if IsSafe(actionStrip.Upgrade) then
            safeActionType = actionStrip.Upgrade.ActionButtonType
        end
    end)

    local deactiveTex, activeTex = GetFilterButtonTextures(window)

    local function CreateStripButton(tex, headerText, bodyText)
        local created = nil
        pcall(function()
            local btnClass = refBtn:GetClass()
            if IsSafe(btnClass) then
                local newBtn = StaticConstructObject(btnClass, actionStrip)
                if IsSafe(newBtn) then
                    pcall(function() newBtn.ActionButtonType = safeActionType end)
                    if IsSafe(tex) then
                        newBtn.ButtonImageOverride = tex
                    end
                    local newSlot = hbox:AddChildToHorizontalBox(newBtn)
                    if IsSafe(newSlot) then
                        pcall(function() newSlot:SetVerticalAlignment(2) end) -- VAlign_Center
                    end
                    SetNativeTooltip(newBtn, headerText, bodyText)
                    created = newBtn
                end
            end
        end)
        return created
    end

    local offBtn = CreateStripButton(
        deactiveTex or activeTex,
        "Hide Offline Members",
        "Hide offline members from the House roster to display only members currently online."
    )
    local onBtn = CreateStripButton(
        activeTex or deactiveTex,
        "Show All Members",
        "Display all House members, including those who are currently offline."
    )

    if IsSafe(offBtn) and IsSafe(onBtn) then
        onlineFilterBtnOffAddr = offBtn:GetAddress()
        onlineFilterBtnOnAddr  = onBtn:GetAddress()
        configuredStripAddr    = stripAddr
        UpdateOnlineFilterButtonVisuals(hbox)
        Log("Added native BPBaseActionButton_C pair to House action strip (Off: 0x%X, On: 0x%X)",
            onlineFilterBtnOffAddr, onlineFilterBtnOnAddr)
    end
end

-- Safely retrieves and caches the genuine BPFamilyMemberListItem_C UClass pointer
local function CacheOriginalWidgetClass(window)
    if IsSafe(cachedItemWidgetClass) then return cachedItemWidgetClass end
    if not IsSafe(window) then return nil end

    pcall(function()
        local cur = window.FamilyMemberListItemWidgetType
        if IsSafe(cur) then
            local full = cur:GetFullName()
            if not full:find("UMG.UserWidget", 1, true) then
                cachedItemWidgetClass = cur
            end
        end
    end)

    if not IsSafe(cachedItemWidgetClass) then
        pcall(function()
            local found = StaticFindObject("/Game/UI/Gameplay/StructureWindows/BPFamilyMemberListItem.BPFamilyMemberListItem_C")
            if IsSafe(found) then cachedItemWidgetClass = found end
        end)
    end

    return cachedItemWidgetClass
end

-- Trips the IsChildOf(UFamilyMemberListItemWidget) check so UFamilyWindow::NativeTick
-- exits without overwriting FamilyMembersScrollBox children in-place.
local function LockWindowTick(window)
    if not IsSafe(window) then return end
    CacheOriginalWidgetClass(window)
    pcall(function()
        local dummy = StaticFindObject("/Script/UMG.UserWidget")
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
    local origClass = CacheOriginalWidgetClass(window)
    if IsSafe(origClass) then
        pcall(function()
            window.FamilyMemberListItemWidgetType = origClass
        end)
    end
end

-- Reads player name, role, and online status safely
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

-- Resolves member row widgets exclusively through the engine's GetChildrenCount and GetChildAt.
-- No global GUObjectArray sweeps or FindAllOf fallbacks.
local function ResolveScrollBoxChildren(scrollBox)
    local items = {}
    if not IsSafe(scrollBox) then return items end

    local childCount = 0
    local ok = pcall(function() childCount = scrollBox:GetChildrenCount() or 0 end)
    if ok and childCount > 0 then
        for i = 0, childCount - 1 do
            local okChild, child = pcall(function() return scrollBox:GetChildAt(i) end)
            if okChild and IsSafe(child) then
                table.insert(items, child)
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
        if IsSafe(win) and IsLiveWidget(win) then
            return win
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

    isSorting = true
    local sortOk, sortRes = pcall(function()
        local items = ResolveScrollBoxChildren(scrollBox)
        if #items == 0 then
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
            Log("Sorted %d members (%d named)", #memberList, namedCount)
        end

        ApplyOnlineVisibilityFilter(memberList)

        if namedCount >= #items or forceLock then
            LockWindowTick(window)
        end

        return true
    end)

    isSorting = false
    if not sortOk then
        Log("error during sort: %s", tostring(sortRes))
        UnlockWindowTick(window)
        return false
    end
    return sortRes == true
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

-- Checks if a clicked ActionButtonWidget is our online filter button
local function IsOurFilterButton(btn)
    if not IsSafe(btn) then return false end
    local addr = btn:GetAddress()
    return (addr ~= nil) and (addr == onlineFilterBtnOffAddr or addr == onlineFilterBtnOnAddr)
end

-- Intercept native ActionButtonWidget clicks safely
pcall(function()
    RegisterHook("/Script/Anvil.ActionButtonWidget:OnClicked",
        function(Context)
            local self = Context:get()
            if IsOurFilterButton(self) then
                -- Disable button immediately so native C++ OnClicked exits early at instruction 7
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
                Log("Filter toggled: %s", onlineOnlyFilter and "ONLINE ONLY" or "ALL MEMBERS")

                local win = GetActiveFamilyWindow()
                if IsSafe(win) then
                    local actionStrip = win.BPActionStrip
                    if IsSafe(actionStrip) then
                        local refBtn = actionStrip.EditSignPost or actionStrip.ClaimFamilyArea
                        if IsSafe(refBtn) then
                            local hbox = refBtn:GetParent()
                            if IsSafe(hbox) then
                                UpdateOnlineFilterButtonVisuals(hbox)
                            end
                        end
                    end
                    SortFamilyMembers(win, true)
                end
                RefreshAndSortWindow()
            end
        end
    )
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
RegisterDevKey(Key.F4, function()
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

-- Main keeper loop running every 200ms on the game thread
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
