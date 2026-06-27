local ADDON, ns = ...

-- RL-facing GUI: a movable window with two tabs.
--   Roster — everyone in the group right now: addon? / snapshot quality / source / age,
--            a coverage summary, and a "Refresh + inspect" button to fill the gaps.
--   Pulls  — recorded encounters from the DB, with per-participant coverage.
-- Plus a draggable minimap button to open it. No external libraries (none are embedded).
ns.UI = ns.UI or {}
local UI = ns.UI
local Coverage = ns.Coverage
local Comm = ns.Comm

local DIFF = { [3]="N10",[4]="N25",[5]="H10",[6]="H25",[7]="LFR",[14]="N",[15]="H",[16]="M",[17]="LFR",[23]="M" }

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    if c.colorStr then return "|c" .. c.colorStr end
    return string.format("|cff%02x%02x%02x", (c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255)
end
local function AgeText(age)
    if not age then return "—" end
    if age < 60 then return age .. "s" end
    if age < 3600 then return math.floor(age / 60) .. "m" end
    return math.floor(age / 3600) .. "h"
end
local QUALITY = {
    full    = "|cff40d070Full|r",
    partial = "|cffe6b800Partial|r",
    none    = "|cffe2566bNone|r",
}
local function AddonText(has) return has and "|cff40d070Yes|r" or "|cff888888No|r" end

-- ---------- a tiny wheel-scrolled list (row pool, no scrollbar) ----------
-- buildRow(row): create the row's fontstrings/scripts once. renderRow(row, item): fill it.
local function CreateList(parent, rowHeight, buildRow, renderRow)
    local list = CreateFrame("Frame", nil, parent)
    list.rows, list.data, list.offset = {}, {}, 0
    list.render = renderRow
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local visible = math.max(1, math.floor((self:GetHeight() or 0) / rowHeight))
        local maxOff = math.max(0, #self.data - visible)
        self.offset = math.min(maxOff, math.max(0, self.offset - delta))
        self:Refresh()
    end)
    function list:Refresh()
        local h = self:GetHeight()
        local visible = (h and h > 0) and math.floor(h / rowHeight) or 15
        if visible < 1 then visible = 1 end
        for i = 1, visible do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Button", nil, self)
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)
                buildRow(row)
                self.rows[i] = row
            end
            local item = self.data[i + self.offset]
            if item then
                row.item = item
                self.render(row, item)
                row:Show()
            else
                row:Hide()
            end
        end
        for i = visible + 1, #self.rows do self.rows[i]:Hide() end
    end
    function list:SetData(data, keepOffset)
        self.data = data or {}
        if not keepOffset then self.offset = 0 end
        self:Refresh()
    end
    return list
end

local function Label(row, x, width, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", row, "LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- ---------- main frame ----------
local frame
local selectedPull

-- Confirmation for the Clear button: wiping is irreversible, and you should only do it
-- once your log is safely uploaded — so we make you confirm rather than one-click nuke.
StaticPopupDialogs["CROWLOGSHELPER_CLEAR"] = {
    text = "Wipe all CrowLogsHelper data?\n\nThis clears every recorded pull, loadout and pet owner. Do this only AFTER you've uploaded your log to the site.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() if ns.ClearData then ns.ClearData() end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3, -- avoids taint from the default StaticPopup index
}

-- Login reminder: stale data from a previous raid is still sitting in the DB. Per design,
-- "Clear logs" wipes immediately (the reminder itself is the confirmation); "Ignore" snoozes
-- it (Core), so a mid-session /reload doesn't re-nag but a fresh raid night still does. The
-- age string ("6 days") is passed in via StaticPopup_Show's first arg.
StaticPopupDialogs["CROWLOGSHELPER_OLD_LOGS"] = {
    text = "CrowLogsHelper: you still have raid data from %s ago that hasn't been cleared.\n\nIf you've already uploaded it to the site, clear it so tonight's log starts fresh and isn't mixed with old pulls.",
    button1 = "Clear logs",
    button2 = "Ignore",
    OnAccept = function() if ns.ClearData then ns.ClearData() end end,
    OnCancel = function() if ns.SnoozeOldLogsReminder then ns.SnoozeOldLogsReminder() end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3, -- avoids taint from the default StaticPopup index
}

-- Called by Core after a wipe (slash or button) so an open window reflects it at once.
function UI.OnDataCleared()
    selectedPull = nil
    if frame then
        UI.RefreshPulls()
        UI.RefreshRoster()
    end
end

local function BuildFrame()
    frame = CreateFrame("Frame", "CrowLogsHelperFrame", UIParent)
    frame:SetSize(540, 430)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    -- Manual cursor-follow drag: this client doesn't expose StopMovingSizing (so the
    -- StartMoving/StopMovingSizing pair leaves the frame stuck to the mouse). We track a
    -- `dragging` flag instead, move the frame in OnUpdate, and clear it on release/hide.
    frame:SetScript("OnDragStart", function(self)
        local s = self:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        self._ddx = (self:GetLeft() or 0) - cx / s
        self._ddy = (self:GetTop() or 0) - cy / s
        self.dragging = true
    end)
    local function stopDrag(self) self.dragging = false end
    frame:SetScript("OnDragStop", stopDrag)
    frame:SetScript("OnMouseUp", stopDrag) -- backup: cursor is over the frame on release
    frame:SetScript("OnHide", stopDrag)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "CrowLogsHelperFrame") -- closes on Escape

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("CrowLogsHelper" .. (Comm and Comm.VERSION and ("  v" .. Comm.VERSION) or ""))

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- tab buttons
    local rosterTab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rosterTab:SetSize(90, 22); rosterTab:SetPoint("TOPLEFT", 16, -40); rosterTab:SetText("Roster")
    local pullsTab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    pullsTab:SetSize(90, 22); pullsTab:SetPoint("LEFT", rosterTab, "RIGHT", 6, 0); pullsTab:SetText("Pulls")

    -- ===== Roster panel =====
    local rosterPanel = CreateFrame("Frame", nil, frame)
    rosterPanel:SetPoint("TOPLEFT", 14, -72)
    rosterPanel:SetPoint("BOTTOMRIGHT", -14, 44)

    local summary = rosterPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary:SetPoint("TOPLEFT", 4, 0)
    summary:SetPoint("TOPRIGHT", -4, 0)
    summary:SetJustifyH("LEFT")

    local headerY = -20
    local function colHead(text, x, w, justify)
        local fs = rosterPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", x, headerY); fs:SetWidth(w); fs:SetJustifyH(justify or "LEFT"); fs:SetText(text)
    end
    colHead("Name", 4, 150)
    colHead("Addon", 165, 50)
    colHead("Snapshot", 240, 70)
    colHead("Source", 330, 70)
    colHead("Age", 430, 50, "RIGHT")

    local rosterList = CreateList(rosterPanel, 18,
        function(row)
            row.name = Label(row, 4, 150)
            row.addon = Label(row, 165, 50)
            row.snap = Label(row, 240, 70)
            row.src = Label(row, 330, 70)
            row.age = Label(row, 426, 54, "RIGHT")
        end,
        function(row, s)
            row.name:SetText(ClassColor(s.class) .. (s.name or "?") .. (s.isSelf and " |cff888888(you)|r" or "") .. "|r")
            -- "Old" (yellow) when a confirmed addon user reports a version != ours.
            local outdated = s.hasAddon and not s.isSelf and s.version ~= Comm.VERSION
            row.addon:SetText(outdated and "|cffe6b800Old|r" or AddonText(s.hasAddon))
            row.snap:SetText(QUALITY[s.quality] or s.quality)
            row.src:SetText(s.source or "—")
            row.age:SetText(AgeText(s.age))
        end)
    rosterList:SetPoint("TOPLEFT", 0, headerY - 16)
    rosterList:SetPoint("BOTTOMRIGHT", 0, 0)

    -- ===== Pulls panel (master list + detail) =====
    local pullsPanel = CreateFrame("Frame", nil, frame)
    pullsPanel:SetPoint("TOPLEFT", 14, -72)
    pullsPanel:SetPoint("BOTTOMRIGHT", -14, 44) -- leave room for the always-on Clear button row
    pullsPanel:Hide()

    local pullList = CreateList(pullsPanel, 20,
        function(row)
            row:SetScript("OnClick", function(self) selectedPull = self.item; UI.RefreshPulls() end)
            row.text = Label(row, 4, 210)
        end,
        function(row, p)
            local diff = DIFF[p.difficultyID] or (p.difficultyID and tostring(p.difficultyID)) or "?"
            local res = (p.success == 1) and "|cff40d070✓|r" or "|cffe2566b✗|r"
            local mark = (p == selectedPull) and "|cffffd100>|r " or ""
            row.text:SetText(string.format("%s%s |cff999999%s|r %s |cff777777%s|r",
                mark, p.encounterName or "?", diff, res, (p.startClock or ""):sub(1, 11)))
        end)
    pullList:SetPoint("TOPLEFT", 0, 0)
    pullList:SetPoint("BOTTOMLEFT", 0, 0)
    pullList:SetWidth(230)

    local detailHead = pullsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detailHead:SetPoint("TOPLEFT", pullList, "TOPRIGHT", 12, 0)
    detailHead:SetText("Participants")

    local detailList = CreateList(pullsPanel, 18,
        function(row)
            row.name = Label(row, 4, 150)
            row.snap = Label(row, 158, 70)
            row.src = Label(row, 232, 70)
        end,
        function(row, d)
            row.name:SetText(ClassColor(d.class) .. (d.name or "?") .. "|r")
            row.snap:SetText(QUALITY[d.quality] or d.quality)
            row.src:SetText(d.source or "—")
        end)
    detailList:SetPoint("TOPLEFT", pullList, "TOPRIGHT", 12, -16)
    detailList:SetPoint("BOTTOMRIGHT", 0, 0)

    -- ===== Refresh button (roster tab) =====
    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(150, 24)
    refresh:SetPoint("BOTTOMRIGHT", -14, 14)
    refresh:SetText("Refresh + inspect")
    refresh:SetScript("OnClick", function()
        Coverage.Refresh()
        UI.RefreshRoster()
    end)

    -- ===== Clear button (both tabs, bottom-left — mirrors Refresh) =====
    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(150, 24)
    clear:SetPoint("BOTTOMLEFT", 16, 14)
    clear:SetText("Clear data")
    clear:SetScript("OnClick", function() StaticPopup_Show("CROWLOGSHELPER_CLEAR") end)
    clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Clear stored data")
        GameTooltip:AddLine("Wipes all recorded pulls, loadouts and pet owners.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Do this only AFTER uploading your log to the site.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    clear:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- expose pieces for the refreshers
    frame.summary, frame.rosterList, frame.pullList, frame.detailList = summary, rosterList, pullList, detailList
    frame.rosterPanel, frame.pullsPanel, frame.refresh = rosterPanel, pullsPanel, refresh

    local function ShowTab(which)
        local r = (which == "roster")
        rosterPanel:SetShown(r); refresh:SetShown(r)
        pullsPanel:SetShown(not r)
        if r then UI.RefreshRoster() else UI.RefreshPulls() end
    end
    rosterTab:SetScript("OnClick", function() ShowTab("roster") end)
    pullsTab:SetScript("OnClick", function() ShowTab("pulls") end)

    -- Drives both the manual drag (every frame while dragging) and the once-a-second
    -- roster refresh (comm/inspect data trickles in while the window is open).
    frame.elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        if self.dragging then
            local s = self:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / s + self._ddx, cy / s + self._ddy)
        end
        self.elapsed = self.elapsed + dt
        if self.elapsed < 1 then return end
        self.elapsed = 0
        if self.rosterPanel:IsShown() then UI.RefreshRoster() end
    end)
    frame:SetScript("OnShow", function() ShowTab("roster") end)
    frame:Hide() -- frames show on creation; start hidden so Toggle opens it on first /clh show
end

function UI.RefreshRoster()
    if not frame then return end
    local roster = Coverage.Roster()
    local c = Coverage.Summarize(roster)
    frame.summary:SetText(string.format(
        "|cffffffff%d|r in group · |cff40d070%d full|r · |cffe6b800%d partial|r · |cffe2566b%d none|r · |cff888888%d no addon|r",
        c.total, c.full or 0, c.partial or 0, c.none or 0, c.noAddon))
    frame.rosterList:SetData(roster, true)
end

function UI.RefreshPulls()
    if not frame then return end
    local pulls = CrowLogsHelperDB and CrowLogsHelperDB.pulls or {}
    local display = {}
    for i = #pulls, 1, -1 do display[#display + 1] = pulls[i] end -- newest first
    frame.pullList:SetData(display, true)

    local detail = {}
    if selectedPull and selectedPull.participants then
        local pool = CrowLogsHelperDB.loadouts
        for _, hash in pairs(selectedPull.participants) do
            local lo = pool[hash]
            detail[#detail + 1] = {
                name = lo and lo.name or "?",
                class = lo and lo.class,
                quality = (lo and ns.Capture.IsComplete(lo)) and "full" or (lo and "partial" or "none"),
                source = lo and lo.source,
            }
        end
        table.sort(detail, function(a, b) return (a.name or "") < (b.name or "") end)
    end
    frame.detailList:SetData(detail)
end

function UI.Toggle()
    if not frame then BuildFrame() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- ---------- minimap button (self-contained, draggable around the minimap) ----------
local function BuildMinimapButton()
    local db = CrowLogsHelperDB
    db.minimap = db.minimap or { angle = 215 }

    local btn = CreateFrame("Button", "CrowLogsHelperMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\AddOns\\CrowLogsHelper\\logo.tga")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    local function UpdatePos()
        local a = math.rad(db.minimap.angle or 215)
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
    end
    UpdatePos()

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            cx, cy = cx / scale, cy / scale
            db.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePos()
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnClick", function() UI.Toggle() end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("CrowLogsHelper" .. (Comm and Comm.VERSION and ("  v" .. Comm.VERSION) or ""))
        GameTooltip:AddLine("|cffffffffClick|r to open the coverage window.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Built after the DB exists (Core calls this on PLAYER_LOGIN).
function UI.Init()
    BuildMinimapButton()
end
