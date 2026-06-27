local ADDON, ns = ...

ns.Storage = ns.Storage or {}
local Storage = ns.Storage

local current -- the currently open pull record (or nil)

function Storage.Init()
    if type(CrowLogsHelperDB) ~= "table" then CrowLogsHelperDB = {} end
    local db = CrowLogsHelperDB
    db.version = 1
    if type(db.loadouts) ~= "table" then db.loadouts = {} end
    if type(db.pulls) ~= "table" then db.pulls = {} end
    -- petGUID -> ownerGUID, so the site can fold a pet (e.g. a Water Elemental that was
    -- out before logging, hence no SPELL_SUMMON) into its owner even with two mages.
    if type(db.pets) ~= "table" then db.pets = {} end
    -- guid -> name of everyone confirmed running the addon (replied over comms at least
    -- once). Lets the site count addon users even when a player's build was frozen from an
    -- inspect (they never changed gear, so they only ever got inspected, not broadcast).
    if type(db.addonUsers) ~= "table" then db.addonUsers = {} end
    -- Auto-enable WoW combat logging in CURRENT-content raids (so you never forget).
    if db.autoLog == nil then db.autoLog = true end
    -- Also auto-log legacy (older) raids. Off by default; toggled with /clh legacy.
    if db.logLegacy == nil then db.logLegacy = false end
    return db
end

-- Wipe all recorded data (pulls, loadouts, pet owners). Shared by /clh clear and the
-- GUI's Clear button. Settings (autoLog/logLegacy/minimap) are kept.
function Storage.ClearAll()
    wipe(CrowLogsHelperDB.pulls)
    wipe(CrowLogsHelperDB.loadouts)
    wipe(CrowLogsHelperDB.pets)
    wipe(CrowLogsHelperDB.addonUsers)
end

-- Newest timestamp across recorded data — the latest of any pull start or loadout capture,
-- or nil when the DB holds nothing. Lets us tell stale data from a past raid (a day+ old)
-- apart from tonight's, so the login reminder only nags when it's actually worth clearing.
function Storage.LastActivityEpoch()
    local newest
    for _, p in ipairs(CrowLogsHelperDB.pulls) do
        if p.startEpoch and (not newest or p.startEpoch > newest) then newest = p.startEpoch end
    end
    for _, lo in pairs(CrowLogsHelperDB.loadouts) do
        if lo.capturedAt and (not newest or lo.capturedAt > newest) then newest = lo.capturedAt end
    end
    return newest
end

-- Mark a guid as a confirmed addon user (received a comm reply from them). Persisted so
-- the site can report how many raiders ran the addon, regardless of comm vs inspect.
function Storage.RecordAddonUser(guid, name)
    if not guid then return end
    CrowLogsHelperDB.addonUsers[guid] = name or true
end

-- Store a loadout in the dedup pool keyed by its hash; returns the hash.
function Storage.UpsertLoadout(loadout)
    if not loadout or not loadout.hash then return nil end
    local pool = CrowLogsHelperDB.loadouts
    local existing = pool[loadout.hash]
    -- Prefer richer sources (self/comm over a sparse inspect) when replacing.
    if not existing or (existing.source == "inspect" and loadout.source ~= "inspect") then
        pool[loadout.hash] = loadout
    end
    return loadout.hash
end

-- Open a new pull record and make it current.
function Storage.OpenPull(info)
    local pull = {
        encounterID = info.encounterID,
        encounterName = info.encounterName,
        difficultyID = info.difficultyID,
        groupSize = info.groupSize,
        startEpoch = time(),
        startClock = date("%m/%d %H:%M:%S"),
        startGetTime = GetTime(),
        target = info.target,
        myGUID = UnitGUID("player"),
        participants = {},
    }
    table.insert(CrowLogsHelperDB.pulls, pull)
    current = pull
    return pull
end

-- Remember a pet's owner (petGUID -> ownerGUID). GUIDs match the combat log exactly,
-- so the site can credit the pet's damage/healing to the player who owns it.
function Storage.RecordPet(petGUID, ownerGUID)
    if not petGUID or not ownerGUID then return end
    CrowLogsHelperDB.pets[petGUID] = ownerGUID
end

-- Attach a loadout (self/comm/inspect) to the current pull, if one is open.
function Storage.AddParticipant(loadout)
    if not loadout or not loadout.guid then return end
    local hash = Storage.UpsertLoadout(loadout)
    if current then
        current.participants[loadout.guid] = hash
    end
end

function Storage.ClosePull(success)
    if not current then return end
    current.endEpoch = time()
    current.durationSec = math.max(0, current.endEpoch - current.startEpoch)
    current.success = success and 1 or 0
    current = nil
end

function Storage.CurrentPull()
    return current
end

function Storage.HasOpenPull()
    return current ~= nil
end

-- Best stored loadout for a guid — the floor we attach at pull start so a short fight still
-- records people we've already seen (self/comm/inspect). Prefers a COMPLETE snapshot over a
-- partial one (a half-loaded inspect), then the most recent. nil if unseen.
function Storage.LoadoutForGUID(guid)
    local best, bestComplete
    for _, lo in pairs(CrowLogsHelperDB.loadouts) do
        if lo.guid == guid then
            local complete = ns.Capture.IsComplete(lo)
            if not best
                or (complete and not bestComplete)
                or (complete == bestComplete and (lo.capturedAt or 0) > (best.capturedAt or 0)) then
                best, bestComplete = lo, complete
            end
        end
    end
    return best
end

-- Set of guids we already have a fresh, COMPLETE loadout for — used to skip re-inspecting
-- them during pre-inspect warming. A partial snapshot does NOT count, so a half-loaded
-- inspect keeps getting retried on the next tick instead of being locked in for maxAgeSec.
function Storage.FreshGUIDs(maxAgeSec)
    local now = time()
    local set = {}
    for _, lo in pairs(CrowLogsHelperDB.loadouts) do
        if lo.guid and (now - (lo.capturedAt or 0)) <= maxAgeSec and ns.Capture.IsComplete(lo) then
            set[lo.guid] = true
        end
    end
    return set
end
