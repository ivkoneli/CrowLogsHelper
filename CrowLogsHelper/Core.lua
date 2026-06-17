local ADDON, ns = ...

local Capture, Storage, Comm, Inspect = ns.Capture, ns.Storage, ns.Comm, ns.Inspect
local Coverage, UI = ns.Coverage, ns.UI

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCrowLogsHelper|r: " .. msg)
end

local function IsLeader()
    return IsInGroup() and UnitIsGroupLeader("player")
end

-- Who's allowed to run the proactive inspects / coverage chatter: the leader OR a raid
-- assistant. Each collector builds their own independent DB, and the site imports only one
-- .lua per log, so there's no cross-file merge to go inconsistent — broadening to assists
-- just lets an assistant's file also capture non-addon raiders (via their own inspects).
local function CanCollect()
    return IsInGroup() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
end

-- Best-effort "what we attacked" at pull start.
local function TargetInfo()
    if UnitExists("boss1") then
        return { guid = UnitGUID("boss1"), name = UnitName("boss1") }
    elseif UnitExists("target") and UnitCanAttack("player", "target") then
        return { guid = UnitGUID("target"), name = UnitName("target") }
    end
    return {}
end

-- Decide whether the current combat looks like a boss fight (fallback path).
local function LooksLikeBoss()
    if UnitExists("boss1") then return true end
    if UnitExists("target") and UnitCanAttack("player", "target") then
        local c = UnitClassification("target")
        if c == "worldboss" or UnitLevel("target") == -1 then return true end
    end
    return false
end

-- ---------- pull lifecycle ----------

-- Iterate present (non-self) group member units, calling fn(unit, guid).
local function ForEachGroupMember(fn)
    if not IsInGroup() then return end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    local myGUID = UnitGUID("player")
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and guid ~= myGUID then fn(unit, guid) end
        end
    end
end

-- Record each present member's pet GUID -> owner GUID (self + the whole group), so the
-- site can fold a permanent pet (Water Elemental, ghoul, …) into its owner even when the
-- combat log has no SPELL_SUMMON for it. UnitGUID works for group pets regardless of
-- range, and the pet unit token differs by build, so we try both documented forms.
local function RecordGroupPets()
    Storage.RecordPet(UnitGUID("pet"), UnitGUID("player")) -- self
    if not IsInGroup() then return end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local petGUID = UnitGUID(prefix .. "pet" .. i) or UnitGUID(unit .. "pet")
            Storage.RecordPet(petGUID, UnitGUID(unit))
        end
    end
end

-- Attach the best loadout we already have for each present member, so even a pull that
-- ends before inspects land (an 11s boss kill) still records everyone we've seen before.
-- A fresher comm reply or the +5s inspect can still overwrite this within the same pull.
local function AttachKnown()
    ForEachGroupMember(function(_, guid)
        local lo = Storage.LoadoutForGUID(guid)
        if lo then Storage.AddParticipant(lo) end
    end)
end

-- Out-of-combat warming: keep the loadout pool fresh so AttachKnown has current data the
-- instant a pull starts (and short pulls no longer miss non-addon players). Leader-only,
-- like the in-pull inspect, so we don't have every raider hammering NotifyInspect.
local PREINSPECT_FRESH = 90 -- re-inspect a member only if their loadout is older than this
local function PreInspect()
    if InCombatLockdown() or not CanCollect() then return end
    Inspect.QueueMissing(Storage.FreshGUIDs(PREINSPECT_FRESH))
end

local function StartPull(info)
    if Storage.HasOpenPull() then return end
    Storage.OpenPull(info)

    -- Snapshot ourselves immediately, then attach everyone we already have data for.
    Storage.AddParticipant(Capture.BuildSelf())
    AttachKnown()
    RecordGroupPets()

    -- Ask everyone running the addon to report their loadout.
    Comm.SendRequest()

    -- After replies have had time to arrive, the leader inspects anyone still missing.
    C_Timer.After(5, function()
        local pull = Storage.CurrentPull()
        if not pull or not CanCollect() then return end
        local seen = {}
        for guid in pairs(pull.participants) do seen[guid] = true end
        Inspect.QueueMissing(seen)
    end)
end

local function EndPull(success)
    -- Grab the pull before ClosePull clears `current`, so the leader can print a one-line
    -- coverage report (captured / full / partial / who was missing).
    local pull = Storage.CurrentPull()
    Storage.ClosePull(success)
    if pull and CanCollect() and Coverage then Coverage.PrintPullSummary(pull) end
end

-- ---------- combat logging (so you never forget /combatlog) ----------

-- True while WoW combat logging was turned on *by us*, so we only auto-disable our own
-- logging on leaving a raid and never fight a manual /combatlog the user set themselves.
local loggingByAddon = false

local function SetLogging(on)
    if on and not LoggingCombat() then
        LoggingCombat(true)
        loggingByAddon = true
        Print("combat logging |cff4cd07denabled|r.")
    elseif not on and LoggingCombat() then
        LoggingCombat(false)
        loggingByAddon = false
        Print("combat logging |cffe2566bdisabled|r.")
    end
end

-- Enable logging when in a raid instance, disable it again on leaving (only if we enabled
-- it). Honors the db.autoLog toggle. Called on zone/instance transitions.
local function UpdateCombatLogging()
    if not CrowLogsHelperDB or not CrowLogsHelperDB.autoLog then return end
    local _, instanceType = IsInInstance()
    if instanceType == "raid" then
        SetLogging(true)
    elseif loggingByAddon then
        SetLogging(false)
    end
end

-- ---------- self-loadout change broadcasting (debounced) ----------

local lastHash
local pendingBroadcast

local function ScheduleBroadcast()
    if pendingBroadcast then return end
    pendingBroadcast = true
    C_Timer.After(1, function()
        pendingBroadcast = false
        local self = Capture.BuildSelf()
        if self.hash ~= lastHash then
            lastHash = self.hash
            Comm.SendSelf()
        end
    end)
end

-- ---------- events ----------

local frame = CreateFrame("Frame")
local events = {}

function events.ADDON_LOADED(name)
    if name ~= ADDON then return end
    Storage.Init()
    Comm.Register()
end

function events.PLAYER_LOGIN()
    lastHash = Capture.BuildSelf().hash
    Print("loaded. Boss pulls will be recorded. Type /clh for options, /clh show for the window.")
    if UI then UI.Init() end
    -- Periodically warm the loadout pool (leader-only, out of combat) so a pull starting
    -- moments later already has everyone's current build via AttachKnown.
    C_Timer.NewTicker(30, PreInspect)
end

function events.PLAYER_ENTERING_WORLD()
    -- Fires on login, /reload, and every zone/instance transition — the right hook to
    -- flip combat logging on entering a raid and off again on leaving.
    UpdateCombatLogging()
end

function events.ENCOUNTER_START(encounterID, encounterName, difficultyID, groupSize)
    local info = TargetInfo()
    info.encounterID = encounterID
    info.encounterName = encounterName
    info.difficultyID = difficultyID
    info.groupSize = groupSize

    local pull = Storage.CurrentPull()
    if pull then
        -- A pull was already opened by the combat fallback (ENCOUNTER_START can
        -- fire just after PLAYER_REGEN_DISABLED). Upgrade it with the real
        -- encounter id / name / difficulty rather than leaving them nil.
        pull.encounterID = encounterID
        pull.encounterName = encounterName
        pull.difficultyID = difficultyID
        pull.groupSize = groupSize
        if info.guid and not (pull.target and pull.target.guid) then
            pull.target = info
        end
    else
        StartPull(info)
    end
end

function events.ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)
    EndPull(success == 1)
end

function events.PLAYER_REGEN_DISABLED()
    -- Fallback for servers that don't fire ENCOUNTER_START.
    if not Storage.HasOpenPull() and LooksLikeBoss() then
        local info = TargetInfo()
        info.encounterName = info.name or "Unknown"
        StartPull(info)
    end
end

function events.PLAYER_REGEN_ENABLED()
    -- Safety net: close any pull still open when combat ends.
    if Storage.HasOpenPull() then EndPull(false) end
    -- Combat ended: re-warm loadouts so the next pull (e.g. the next boss) starts informed.
    PreInspect()
end

function events.CHAT_MSG_ADDON(prefix, text, channel, sender)
    Comm.OnMessage(prefix, text, channel, sender)
end

function events.INSPECT_READY(guid)
    Inspect.OnReady(guid)
end

function events.GROUP_ROSTER_UPDATE()
    if CanCollect() then Comm.SendRequest() end
    -- A new member joined / roster changed: warm any loadouts we don't have yet.
    PreInspect()
    RecordGroupPets()
end

events.PLAYER_EQUIPMENT_CHANGED = ScheduleBroadcast
events.PLAYER_TALENT_UPDATE = ScheduleBroadcast
events.PLAYER_SPECIALIZATION_CHANGED = ScheduleBroadcast
events.ACTIVE_TALENT_GROUP_CHANGED = ScheduleBroadcast

frame:SetScript("OnEvent", function(_, event, ...)
    local handler = events[event]
    if handler then handler(...) end
end)
for event in pairs(events) do frame:RegisterEvent(event) end

-- ---------- slash command ----------

SLASH_CROWLOGSHELPER1 = "/clh"
SlashCmdList.CROWLOGSHELPER = function(msg)
    msg = (msg or ""):lower():gsub("%s+", "")
    -- Bare "/clh" shows status too, so it works even if the chat autocomplete eats the arg.
    if msg == "" or msg == "status" then
        local self = Capture.BuildSelf()
        local db = CrowLogsHelperDB
        local loadouts = 0
        for _ in pairs(db.loadouts) do loadouts = loadouts + 1 end
        Print(string.format("spec=%s ilvl=%d | stored: %d loadouts, %d pulls | leader=%s | logging=%s autolog=%s",
            self.specName or "?", self.ilvl, loadouts, #db.pulls, tostring(IsLeader()),
            tostring(LoggingCombat()), tostring(db.autoLog)))
    elseif msg == "log" then
        -- Manual toggle (macro-friendly), e.g. for dungeons where autolog stays off.
        SetLogging(not LoggingCombat())
    elseif msg == "autolog" then
        CrowLogsHelperDB.autoLog = not CrowLogsHelperDB.autoLog
        Print("auto combat-logging in raids: " .. (CrowLogsHelperDB.autoLog and "|cff4cd07dON|r" or "|cffe2566bOFF|r"))
        UpdateCombatLogging()
    elseif msg == "show" or msg == "gui" then
        if UI then UI.Toggle() end
    elseif msg == "pull" then
        local info = TargetInfo()
        info.encounterName = info.name or "Manual"
        StartPull(info)
        Print("manual pull started.")
    elseif msg == "end" then
        EndPull(false)
        Print("pull closed.")
    elseif msg == "clear" then
        wipe(CrowLogsHelperDB.pulls)
        wipe(CrowLogsHelperDB.loadouts)
        wipe(CrowLogsHelperDB.pets)
        Print("cleared stored pulls and loadouts.")
    else
        Print("commands: |cffffff00show|r (coverage window), |cffffff00status|r, |cffffff00log|r (toggle combat log now), |cffffff00autolog|r (auto in raids), |cffffff00pull|r, |cffffff00end|r, |cffffff00clear|r")
    end
end
