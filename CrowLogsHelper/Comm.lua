local ADDON, ns = ...

ns.Comm = ns.Comm or {}
local Comm = ns.Comm

local PREFIX = "CLH"
local CHUNK = 230            -- max body chars per addon message (255 hard limit incl. header)
local FIELD = "~"           -- top-level field separator (absent from names/guids/item strings)
local VERSION = (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
Comm.VERSION = VERSION

-- ---------- serialization ----------

-- loadout table -> single compact string
local function Serialize(l)
    local talents = {}
    for tier = 1, 7 do talents[tier] = tostring(l.talents[tier] or 0) end

    local gear = {}
    for _, slot in ipairs(ns.Capture.SLOTS) do
        if l.gear[slot] then gear[#gear + 1] = slot .. "=" .. l.gear[slot] end
    end

    return table.concat({
        l.name or "",
        l.guid or "",
        l.class or "",
        tostring(l.specID or 0),
        l.specName or "",
        tostring(l.ilvl or 0),
        table.concat(talents, ","),
        table.concat(gear, ";"),
        VERSION, -- our addon version (gear has no FIELD chars, so this stays field 9)
    }, FIELD)
end

-- compact string -> loadout table + sender's addon version (hash recomputed locally).
-- Version is field 9; pre-version addons send 8 fields, so it comes back nil.
local function Deserialize(str)
    local name, guid, class, specID, specName, ilvl, talentStr, gearStr, version =
        strsplit(FIELD, str, 9)
    if not guid or guid == "" then return nil end

    local talents = {}
    local i = 1
    for tid in string.gmatch(talentStr or "", "([^,]+)") do
        local n = tonumber(tid)
        if n and n > 0 then talents[i] = n end
        i = i + 1
    end

    local gear = {}
    for entry in string.gmatch(gearStr or "", "([^;]+)") do
        local slot, itemStr = entry:match("^(%d+)=(.+)$")
        if slot then gear[tonumber(slot)] = itemStr end
    end

    local l = {
        name = name,
        guid = guid,
        class = class ~= "" and class or nil,
        specID = tonumber(specID) ~= 0 and tonumber(specID) or nil,
        specName = specName ~= "" and specName or nil,
        ilvl = tonumber(ilvl) or 0,
        talents = talents,
        gear = gear,
        source = "comm",
        capturedAt = time(),
    }
    return ns.Capture.AddHash(l), version
end

-- ---------- outgoing queue (spaced to avoid throttle) ----------

local outQueue = {}
local ticker

local function Channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Flush()
    local channel = Channel()
    local msg = table.remove(outQueue, 1)
    if msg and channel then
        SendAddonMessage(PREFIX, msg, channel)
    end
    if #outQueue == 0 and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function Enqueue(msg)
    outQueue[#outQueue + 1] = msg
    if not ticker then
        Flush()
        ticker = C_Timer.NewTicker(0.25, Flush)
    end
end

-- ---------- public send ----------

function Comm.SendSelf()
    if not Channel() then return end
    local body = Serialize(ns.Capture.BuildSelf())
    local total = math.max(1, math.ceil(#body / CHUNK))
    for seq = 1, total do
        local chunk = body:sub((seq - 1) * CHUNK + 1, seq * CHUNK)
        Enqueue(table.concat({ "LOAD", seq, total, chunk }, FIELD))
    end
end

function Comm.SendRequest()
    if not Channel() then return end
    Enqueue(table.concat({ "REQ", 0, 0, "" }, FIELD))
end

-- ---------- addon-user presence ----------
-- Guids we've received a loadout broadcast from = people confirmed running the addon.
-- Lets the RL roster show "has addon" accurately, independent of whether we've stored
-- their loadout yet. (REQ carries no guid, so only LOAD replies mark presence.)
Comm.addonUsers = {}
Comm.addonVersions = {} -- [guid] = version string reported in their last comm reply
function Comm.HasAddon(guid)
    return guid ~= nil and Comm.addonUsers[guid] ~= nil
end
function Comm.VersionFor(guid)
    return guid and Comm.addonVersions[guid] or nil
end

-- ---------- incoming reassembly ----------

local buffers = {} -- [sender] = { total = n, parts = {} }

function Comm.OnMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX then return end
    local msgType, seq, total, body = strsplit(FIELD, text, 4)
    seq, total = tonumber(seq), tonumber(total)

    if msgType == "REQ" then
        -- Someone (the RL) asked for loadouts; reply with our own.
        Comm.SendSelf()
        return
    end

    if msgType ~= "LOAD" or not seq or not total then return end

    local buf = buffers[sender]
    if not buf or buf.total ~= total then
        buf = { total = total, parts = {} }
        buffers[sender] = buf
    end
    buf.parts[seq] = body or ""

    -- Complete?
    for i = 1, total do
        if buf.parts[i] == nil then return end
    end
    buffers[sender] = nil

    local loadout, version = Deserialize(table.concat(buf.parts))
    if loadout then
        Comm.addonUsers[loadout.guid] = time() -- confirmed addon user
        Comm.addonVersions[loadout.guid] = version -- nil for pre-version addons → flagged "Old"
        ns.Storage.AddParticipant(loadout)
    end
end

function Comm.Register()
    if RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(PREFIX)
    end
end

Comm.PREFIX = PREFIX
