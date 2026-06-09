local ADDON, ns = ...

ns.Capture = ns.Capture or {}
local Capture = ns.Capture

-- Equipment slots we care about (1..19 covers head..ranged/relic; 13/14 = trinkets).
local SLOTS = {}
for i = 1, 19 do SLOTS[#SLOTS + 1] = i end

-- Pull the bare "item:..." payload out of a full item link.
local function ItemString(link)
    if not link then return nil end
    return link:match("|H(item:[%-:%d]+)|h")
end

-- Read the 7-tier talent selection for a unit. For inspect, pass isInspect=true + unit.
local function ReadTalents(group, isInspect, unit)
    local talents = {}
    for tier = 1, 7 do
        for col = 1, 3 do
            local id, _, _, selected = GetTalentInfo(tier, col, group, isInspect, unit)
            if selected then
                talents[tier] = id
                break
            end
        end
    end
    return talents
end

-- djb2 string hash -> 8-hex-digit string, used to dedup identical loadouts.
local function Hash(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 4294967296
    end
    -- Format as two 16-bit halves: WoW's Lua 5.1 treats "%x" as a SIGNED 32-bit int, so a
    -- hash >= 2^31 (e.g. 4033600710) overflows ("integer overflow attempting to store ...").
    -- Each half is < 65536, so neither overflows, and the result is identical to "%08x" for
    -- the values that already worked.
    return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

-- Canonical string for hashing: spec + talents + per-slot item strings (order-stable).
local function Canonical(loadout)
    local parts = { "s", tostring(loadout.specID) }
    parts[#parts + 1] = "t"
    for tier = 1, 7 do
        parts[#parts + 1] = tostring(loadout.talents[tier] or 0)
    end
    parts[#parts + 1] = "g"
    for _, slot in ipairs(SLOTS) do
        parts[#parts + 1] = slot .. "=" .. (loadout.gear[slot] or "")
    end
    return table.concat(parts, "|")
end

function Capture.AddHash(loadout)
    loadout.hash = Hash(Canonical(loadout))
    return loadout
end

-- Build the local player's loadout snapshot.
function Capture.BuildSelf()
    local specIndex = GetSpecialization()
    local specID, specName = nil, nil
    if specIndex then
        specID, specName = GetSpecializationInfo(specIndex)
    end

    local gear = {}
    for _, slot in ipairs(SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        local itemStr = ItemString(link)
        if itemStr then gear[slot] = itemStr end
    end

    local loadout = {
        name = UnitName("player"),
        guid = UnitGUID("player"),
        class = select(2, UnitClass("player")),
        specID = specID,
        specName = specName,
        talents = ReadTalents(GetActiveSpecGroup(), false, nil),
        gear = gear,
        ilvl = math.floor((select(2, GetAverageItemLevel())) or 0),
        source = "self",
        capturedAt = time(),
    }
    return Capture.AddHash(loadout)
end

-- Build a loadout for an inspected unit (called after INSPECT_READY).
function Capture.BuildInspect(unit)
    if not unit or not UnitExists(unit) then return nil end

    local gear = {}
    for _, slot in ipairs(SLOTS) do
        local link = GetInventoryItemLink(unit, slot)
        local itemStr = ItemString(link)
        if itemStr then gear[slot] = itemStr end
    end

    -- No gear means inspect data hasn't arrived (out of range / not ready).
    if not next(gear) then return nil end

    local specID = GetInspectSpecialization(unit)
    local specName
    if specID and specID > 0 then
        specName = select(2, GetSpecializationInfoByID(specID))
    end

    local loadout = {
        name = UnitName(unit),
        guid = UnitGUID(unit),
        class = select(2, UnitClass(unit)),
        specID = (specID and specID > 0) and specID or nil,
        specName = specName,
        talents = ReadTalents(GetActiveSpecGroup(), true, unit),
        gear = gear,
        ilvl = 0,
        source = "inspect",
        capturedAt = time(),
    }
    return Capture.AddHash(loadout)
end

-- Inspect gear fills in progressively after INSPECT_READY, so a snapshot read too early
-- can be partial (e.g. only one trinket). Treat it as complete only once most slots are
-- populated. 12 is well under a geared raider's ~15-17 equipped items, but far above the
-- handful a still-loading inspect returns — Inspect.OnReady re-reads until this passes.
local MIN_COMPLETE_SLOTS = 12
function Capture.IsComplete(loadout)
    if not loadout or not loadout.gear then return false end
    local n = 0
    for _ in pairs(loadout.gear) do n = n + 1 end
    return n >= MIN_COMPLETE_SLOTS
end

Capture.Hash = Hash
Capture.SLOTS = SLOTS
