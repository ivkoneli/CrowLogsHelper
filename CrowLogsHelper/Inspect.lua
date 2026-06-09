local ADDON, ns = ...

ns.Inspect = ns.Inspect or {}
local Inspect = ns.Inspect

local queue = {}        -- list of unit tokens to inspect
local current           -- { unit, guid } currently awaiting INSPECT_READY
local timeout           -- C_Timer handle guarding a stuck inspect
local DELAY = 1.5       -- spacing between inspects (server throttle)

local function Next()
    current = nil
    if timeout then timeout:Cancel(); timeout = nil end

    local unit = table.remove(queue, 1)
    if not unit then return end

    if not UnitExists(unit) or not CanInspect(unit) then
        C_Timer.After(0.1, Next)
        return
    end

    current = { unit = unit, guid = UnitGUID(unit) }
    NotifyInspect(unit)
    -- If the data never arrives (out of range), skip after a short wait.
    timeout = C_Timer.NewTimer(3, function()
        ClearInspectPlayer()
        C_Timer.After(DELAY, Next)
    end)
end

local MAX_TRIES = 5     -- re-reads after INSPECT_READY while gear is still populating
local RETRY = 0.3       -- spacing between re-reads (~1.5s total worst case)

-- Called from Core on INSPECT_READY(guid). Returns true if we consumed it.
function Inspect.OnReady(guid)
    if not current or current.guid ~= guid then return false end
    if current.building then return true end -- already re-reading this one
    if timeout then timeout:Cancel(); timeout = nil end

    -- Re-read the gear a few times because WoW fills inspect slots in progressively — a
    -- single read right at INSPECT_READY can be partial (missing a trinket, etc.). We keep
    -- `current` held (so a pre-inspect tick can't start a parallel inspect) and DON'T
    -- ClearInspectPlayer between tries, or we'd wipe the cache we're waiting on. Next()
    -- clears `current` once we finish.
    current.building = true
    local unit, tries = current.unit, 0

    local function finish(loadout)
        if loadout then ns.Storage.AddParticipant(loadout) end
        ClearInspectPlayer()
        C_Timer.After(DELAY, Next)
    end

    local function attempt()
        local loadout = ns.Capture.BuildInspect(unit)
        if loadout and ns.Capture.IsComplete(loadout) then
            finish(loadout)
        elseif tries < MAX_TRIES then
            tries = tries + 1
            C_Timer.After(RETRY, attempt)
        else
            finish(loadout) -- accept whatever we have rather than drop the player entirely
        end
    end
    attempt()
    return true
end

-- Enqueue raid/party members whose GUID is not already in `seen`.
-- `seen` is a set: { [guid] = true }.
function Inspect.QueueMissing(seen)
    if not IsInGroup() then return end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    local myGUID = UnitGUID("player")

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and guid ~= myGUID and not seen[guid] then
                queue[#queue + 1] = unit
            end
        end
    end

    if not current then Next() end
end

function Inspect.Reset()
    wipe(queue)
    current = nil
    if timeout then timeout:Cancel(); timeout = nil end
end
