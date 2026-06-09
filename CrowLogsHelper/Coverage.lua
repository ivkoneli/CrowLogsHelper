local ADDON, ns = ...

-- Coverage = the RL-facing "who do we have data for" layer. Pure status derivation over
-- the loadout pool + comm presence, plus the one "fix the gaps" action (re-request +
-- leader inspect). Used by the GUI (UI.lua) and the post-pull chat summary (Core.lua).
ns.Coverage = ns.Coverage or {}
local Coverage = ns.Coverage

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCrowLogsHelper|r: " .. msg)
end

-- Snapshot status for one guid from what we currently have stored.
-- { hasAddon, quality = "full"|"partial"|"none", source, age, ilvl, specName }
function Coverage.StatusForGUID(guid)
    local lo = ns.Storage.LoadoutForGUID(guid)
    local hasAddon = ns.Comm.HasAddon(guid)
    if lo and (lo.source == "self" or lo.source == "comm") then hasAddon = true end
    local quality = "none"
    if lo then quality = ns.Capture.IsComplete(lo) and "full" or "partial" end
    return {
        guid = guid,
        hasAddon = hasAddon,
        quality = quality,
        source = lo and lo.source or nil,
        age = lo and (time() - (lo.capturedAt or 0)) or nil,
        ilvl = lo and lo.ilvl or nil,
        specName = lo and lo.specName or nil,
        version = ns.Comm.VersionFor(guid),
    }
end

-- Walk the current group (raid or party), calling fn(unit, guid, name, class, isSelf).
function Coverage.ForEachMember(fn)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local _, class = UnitClass(unit)
                fn(unit, UnitGUID(unit), UnitName(unit), class, UnitIsUnit(unit, "player"))
            end
        end
    elseif IsInGroup() then
        fn("player", UnitGUID("player"), UnitName("player"), select(2, UnitClass("player")), true)
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local _, class = UnitClass(unit)
                fn(unit, UnitGUID(unit), UnitName(unit), class, false)
            end
        end
    else
        fn("player", UnitGUID("player"), UnitName("player"), select(2, UnitClass("player")), true)
    end
end

-- Live coverage list for everyone currently in the group (sorted self-first, then name).
function Coverage.Roster()
    local list = {}
    Coverage.ForEachMember(function(unit, guid, name, class, isSelf)
        if not guid then return end
        local s
        if isSelf then
            -- Build self live so the RL's own row is always current/full, even pre-pull.
            local lo = ns.Capture.BuildSelf()
            s = {
                guid = guid, hasAddon = true,
                quality = ns.Capture.IsComplete(lo) and "full" or "partial",
                source = "self", age = 0, ilvl = lo.ilvl, specName = lo.specName,
                version = ns.Comm.VERSION,
            }
        else
            s = Coverage.StatusForGUID(guid)
        end
        s.name, s.class, s.isSelf = name, class, isSelf
        list[#list + 1] = s
    end)
    table.sort(list, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

-- Counts for a roster list: { total, full, partial, none, noAddon }.
function Coverage.Summarize(roster)
    local c = { total = 0, full = 0, partial = 0, none = 0, noAddon = 0 }
    for _, s in ipairs(roster) do
        c.total = c.total + 1
        c[s.quality] = (c[s.quality] or 0) + 1
        if not s.hasAddon then c.noAddon = c.noAddon + 1 end
    end
    return c
end

-- Coverage of a recorded pull: { captured, full, partial, missing = {names}, missingAddon = {names} }.
-- `missing` = group members present now but absent from the pull's participants.
function Coverage.PullSummary(pull)
    local pool = CrowLogsHelperDB.loadouts
    local res = { captured = 0, full = 0, partial = 0, missing = {}, missingAddon = {} }
    for _, hash in pairs(pull.participants or {}) do
        res.captured = res.captured + 1
        local lo = pool[hash]
        if lo and ns.Capture.IsComplete(lo) then res.full = res.full + 1
        else res.partial = res.partial + 1 end
    end
    Coverage.ForEachMember(function(_, guid, name, _, isSelf)
        if not guid then return end
        if not (pull.participants and pull.participants[guid]) then
            res.missing[#res.missing + 1] = name
        end
        if not isSelf and not ns.Comm.HasAddon(guid) then
            res.missingAddon[#res.missingAddon + 1] = name
        end
    end)
    return res
end

-- Print a one-line post-pull coverage report (leader-only caller).
function Coverage.PrintPullSummary(pull)
    if not pull or not pull.participants then return end
    local r = Coverage.PullSummary(pull)
    local boss = pull.encounterName or "pull"
    local parts = { string.format("%s: captured %d (%d full, %d partial)", boss, r.captured, r.full, r.partial) }
    if #r.missing > 0 then
        parts[#parts + 1] = "missing: " .. table.concat(r.missing, ", ")
    end
    Print(table.concat(parts, " — "))
end

-- The "fix the gaps" action: re-ask addon users for their loadout, and (leader only) queue
-- inspects for anyone we don't already have a COMPLETE snapshot for. Silent — no nagging.
function Coverage.Refresh()
    ns.Comm.SendRequest()
    if IsInGroup() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
        local seen = { [UnitGUID("player")] = true }
        for _, s in ipairs(Coverage.Roster()) do
            if s.quality == "full" then seen[s.guid] = true end
        end
        ns.Inspect.QueueMissing(seen)
    end
end
