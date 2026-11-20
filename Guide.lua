-- Guide.lua
--
-- Points the game's own marker at the step you are on, and moves it to the next one when
-- that step is done.
--
-- The marker is Blizzard's user waypoint with supertracking turned on, which is the same
-- thing /way gives you: a pin on the map, an arrow on the minimap, and the floating marker
-- in the world. Nothing here draws a pin of its own.
--
-- What counts as "reached" is the quest's state changing, not your position. Standing on a
-- quest giver is not the same as having the quest, and a marker that jumped away while you
-- were still reading the quest text would be worse than no marker at all. Arriving is still
-- detected, but all it does is say so on the strip. The moment you accept, hand in, or
-- unblock something, the state changes and the marker moves on by itself.

local ADDON, QEF = ...

local Guide = {}
QEF.Guide = Guide

local Checklist, Waypoint, Travel

-- Map percent, not yards: the client will not say how big a zone is on every build, and a
-- percent of the map is close enough for "you are at the right place".
local ARRIVE_RADIUS = 1.5
local POLL_SECONDS = 0.5

--- The step the marker is on: { questId, kind, uiMapId, x, y, npc, text }
Guide.current = nil
--- True once the player is standing at the current step's place.
Guide.arrived = false
--- A quest the player asked for by hand, which wins over the plan's own order.
Guide.pinned = nil

-- Steps the marker could not be placed on, so the next refresh does not try them again and
-- again. Cleared whenever the list changes, since the reason may have been a transient one.
local refused = {}
local refreshQueued = false
local poller

--------------------------------------------------------------------------------------------
-- Picking a step
--------------------------------------------------------------------------------------------

local function StepKey(entry)
    return entry.id .. "/" .. (entry.step and entry.step.kind or "?")
end

--- A step the marker can actually be put on. A "finish" step has one when its objectives
--- name a creature the database knows, so the marker can send you to the murlocs; a quest
--- asking for an item or an object still has nowhere to point.
local function Targetable(entry)
    local step = entry.step
    return step ~= nil and step.uiMapId ~= nil and step.x ~= nil and step.y ~= nil
end

---@param steps table[]
---@return table? entry
local function Pick(steps)
    if Guide.pinned then
        for _, entry in ipairs(steps) do
            if entry.id == Guide.pinned and Targetable(entry) then return entry end
        end
        -- The pinned quest has moved on or left the list, so the pin has served its purpose.
        Guide.pinned = nil
    end
    for _, entry in ipairs(steps) do
        if Targetable(entry) and not refused[StepKey(entry)] then return entry end
    end
    return nil
end

--- Is the marker still on a step that is in the plan? Order can change underfoot - walking
--- into a zone promotes it to the top - and a marker that slid to another quest while you
--- were on your way to this one would be infuriating. It only moves when its own step is
--- gone, which is what "reached" means here.
local function CurrentStillStands(steps)
    local current = Guide.current
    if not current then return false end
    for _, entry in ipairs(steps) do
        if entry.id == current.questId and entry.step.kind == current.kind then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------------------
-- Setting the marker
--------------------------------------------------------------------------------------------

---@param entry table
---@return string
function Guide.Describe(entry)
    local step = entry.step
    local text = ("%s %s"):format(step.verb or "Go to", entry.name)
    if step.kind == "blocked" and step.blockers and step.blockers[1] then
        text = ("Unlock %s - %s first"):format(entry.name, step.blockers[1])
    end
    return text
end

local function Announce(entry)
    local step = entry.step
    local where = step.npc or "the marked spot"
    if step.zone then where = where .. ", " .. step.zone end
    QEF.Print(("|cfff2c75bnext:|r %s |cff808080(%s)|r"):format(Guide.Describe(entry), where))
end

--- Put the marker on one step. Returns false when the client refused the waypoint, which
--- it does for some maps on this build - the caller then tries the step after it.
---@param entry table
---@return boolean placed
local function Point(entry, announce)
    local step = entry.step
    local placed, reason = Waypoint.Set(step.uiMapId, step.x, step.y)
    if not placed then
        refused[StepKey(entry)] = true
        QEF.Debug("guide could not mark", entry.name, "-", reason or "no reason given")
        return false
    end

    Guide.current = {
        questId = entry.id,
        kind = step.kind,
        uiMapId = step.uiMapId,
        x = step.x, y = step.y,
        npc = step.npc,
        zone = step.zone,
        text = Guide.Describe(entry),
    }
    Guide.arrived = false
    if announce then Announce(entry) end
    return true
end

--------------------------------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------------------------------

---@return boolean enabled
function Guide.Enabled()
    return QEF.Get("guide") == true
end

--- Work out which step the marker belongs on, and move it if that is not where it is.
---@param force boolean? true re-places the marker even if the step has not changed
function Guide.Refresh(force)
    if not Guide.Enabled() then return end
    if not Checklist or Checklist.Count() == 0 then
        Guide.current = nil
        return
    end

    local steps = Checklist.Steps()
    if not force and CurrentStillStands(steps) then return end

    local previous = Guide.current
    Guide.current = nil

    -- Walk forwards from the chosen step: when the client refuses a map, the one after it
    -- is still worth offering rather than giving up on the whole list.
    local entry = Pick(steps)
    while entry do
        if Point(entry, previous ~= nil or force == true) then break end
        entry = Pick(steps)
    end

    if not Guide.current and previous then
        QEF.Debug("guide has no step it can mark")
    end
    if QEF.Tracker then QEF.Tracker.Refresh() end
end

local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.3, function()
        refreshQueued = false
        Guide.Refresh()
    end)
end

Guide.Queue = QueueRefresh

--------------------------------------------------------------------------------------------
-- Arriving
--------------------------------------------------------------------------------------------

-- Travel owns reading the player's position, so the walking order the checklist works out
-- and the "you are here" on the strip are measured from the same point.
---@return number? mapId
---@return number? x percent
---@return number? y percent
local function PlayerPosition()
    if not Travel then return nil end
    return Travel.PlayerPoint()
end

--- The map the player is on, for deciding whether a step is somewhere else entirely.
---@return number? uiMapId
function Guide.PlayerMapId()
    return (PlayerPosition())
end

--- True when the player is standing at the current step's place.
---@return boolean
function Guide.AtCurrent()
    local current = Guide.current
    if not current then return false end
    local mapId, x, y = PlayerPosition()
    if not mapId or mapId ~= current.uiMapId then return false end
    local dx, dy = x - current.x, y - current.y
    return (dx * dx + dy * dy) <= (ARRIVE_RADIUS * ARRIVE_RADIUS)
end

local function Poll()
    if not Guide.Enabled() or not Guide.current then return end
    local arrived = Guide.AtCurrent()
    if arrived == Guide.arrived then return end
    Guide.arrived = arrived
    -- Only the strip changes. Arriving does not advance the marker; doing the thing does.
    if QEF.Tracker then QEF.Tracker.Refresh() end
end

--------------------------------------------------------------------------------------------
-- Public controls
--------------------------------------------------------------------------------------------

--- Point at one quest's step now, and keep it there until that step is done.
---@param questId number
---@return boolean pointed
function Guide.Pin(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    QEF.Set("guide", true)
    Guide.pinned = questId
    refused[questId .. "/pickup"] = nil
    refused[questId .. "/turnin"] = nil
    refused[questId .. "/blocked"] = nil
    Guide.Refresh(true)
    if Guide.current and Guide.current.questId == questId then return true end

    QEF.Print("|cffff8040no marker|r - that step has no recorded place to stand")
    return false
end

--- Leave this step alone and mark the next one. The step stays on the list; it just stops
--- being the one in front of you.
---@return boolean moved
function Guide.Next()
    if not Guide.current then
        Guide.Refresh(true)
        return Guide.current ~= nil
    end
    refused[Guide.current.questId .. "/" .. Guide.current.kind] = true
    Guide.pinned = nil
    Guide.Refresh(true)
    return Guide.current ~= nil
end

--- Forget which steps were skipped or refused, so the whole list is in play again.
function Guide.Reset()
    wipe(refused)
    Guide.pinned = nil
    Guide.Refresh(true)
end

function Guide.Start()
    QEF.Set("guide", true)
    wipe(refused)
    Guide.Refresh(true)
end

--- Stop guiding, and take the marker away if it is still the one we placed. A waypoint the
--- player has since set themselves is left where it is.
function Guide.Stop()
    QEF.Set("guide", false)
    local current = Guide.current
    if current and Waypoint.lastMapId == current.uiMapId
        and Waypoint.lastX == current.x and Waypoint.lastY == current.y then
        Waypoint.Clear()
    end
    Guide.current = nil
    Guide.arrived = false
    if QEF.Tracker then QEF.Tracker.Refresh() end
end

---@return boolean running
function Guide.Toggle()
    if Guide.Enabled() then
        Guide.Stop()
        return false
    end
    Guide.Start()
    return true
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Guide", function()
    Checklist = QEF.Checklist
    Waypoint = QEF.Waypoint
    Travel = QEF.Travel

    Checklist.Subscribe(function()
        wipe(refused)
        Guide.Refresh()
    end)

    -- Status changes are what move the marker on, and these are the events that produce
    -- them. Source clears its completed-quest cache on the same events, and it registered
    -- first, so by the time this runs the statuses are fresh.
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
                             "QUEST_LOG_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        QEF.On(event, QueueRefresh)
    end

    poller = CreateFrame("Frame")
    poller.elapsed = 0
    poller:SetScript("OnUpdate", function(self, delta)
        self.elapsed = self.elapsed + delta
        if self.elapsed < POLL_SECONDS then return end
        self.elapsed = 0
        local ok, err = pcall(Poll)
        if not ok then QEF.Debug("guide poll error:", err) end
    end)

    Guide.Refresh()
end)
