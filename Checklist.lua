-- Checklist.lua
--
-- The run list behind the dungeon tracker: which quests you mean to do, and the one errand
-- each of them needs next.
--
-- Two things make a dungeon run annoying to prepare for. The quests are scattered across
-- several zones and sometimes another continent, and a few of them are locked behind an
-- earlier quest you have to do first. So the model here is not "a list of quests" but "a
-- list of steps, grouped by where you have to stand to do them".
--
-- A quest contributes exactly one step at a time, decided by the state it is in: pick it
-- up, finish it, hand it in, or clear what is blocking it. That is what makes the list
-- walkable - every line is something you can act on now - and it is what lets the guide
-- point at one place at a time and move on by itself when the state changes.
--
-- Nothing in here draws anything. Tracker.lua shows the plan beside the game world,
-- Guide.lua points the game's marker at the current step, and Plan.lua is where you choose
-- what goes in it.

local ADDON, QEF = ...

local Checklist = {}
QEF.Checklist = Checklist

local Source, Chain, Travel

--------------------------------------------------------------------------------------------
-- Stored state
--------------------------------------------------------------------------------------------

-- Which quests you still have to do is a fact about one character's quest log, not about
-- the account, so the list is kept per character. Two characters on the same account
-- running the same dungeon want two different lists.
local function CharacterKey()
    local name = QEF.Str(QEF.Try(UnitName, "player")) or "unknown"
    local realm = QEF.Str(QEF.Try(GetRealmName)) or "unknown"
    return name .. "-" .. realm
end

--- The stored table for this character, created on first use.
--- Before saved variables load this hands back a scratch table and does not keep it, so an
--- early caller reads an empty list instead of erroring and the real one is picked up later.
---@return table data { dungeon, quests, ticked }
local function Data()
    local store = QEF.checklists
    if type(store) ~= "table" then
        return { quests = {}, ticked = {} }
    end
    local key = CharacterKey()
    local entry = store[key]
    if type(entry) ~= "table" then
        entry = { quests = {}, ticked = {} }
        store[key] = entry
    end
    if type(entry.quests) ~= "table" then entry.quests = {} end
    if type(entry.ticked) ~= "table" then entry.ticked = {} end
    return entry
end

Checklist.Data = Data

--------------------------------------------------------------------------------------------
-- Change notification
--------------------------------------------------------------------------------------------

local listeners = {}

--- Called whenever the list changes. The tracker, the guide and the planner all watch it,
--- so none of them has to know the others exist.
---@param fn function
function Checklist.Subscribe(fn)
    listeners[#listeners + 1] = fn
end

local function Changed()
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then QEF.Debug("checklist listener error:", err) end
    end
end

Checklist.Changed = Changed

--------------------------------------------------------------------------------------------
-- Membership
--------------------------------------------------------------------------------------------

local function IndexOf(quests, questId)
    for index = 1, #quests do
        if quests[index] == questId then return index end
    end
    return nil
end

---@param questId number
---@return boolean
function Checklist.Has(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    return IndexOf(Data().quests, questId) ~= nil
end

---@param questId number
---@return boolean added
function Checklist.Add(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    local data = Data()
    if IndexOf(data.quests, questId) then return false end
    data.quests[#data.quests + 1] = questId
    Changed()
    return true
end

---@param questId number
---@return boolean removed
function Checklist.Remove(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    local data = Data()
    local index = IndexOf(data.quests, questId)
    if not index then return false end
    table.remove(data.quests, index)
    data.ticked[questId] = nil
    Changed()
    return true
end

--- Add or remove, and say which it ended up doing.
---@param questId number
---@return boolean nowListed
function Checklist.Toggle(questId)
    if Checklist.Has(questId) then
        Checklist.Remove(questId)
        return false
    end
    Checklist.Add(questId)
    return true
end

--- Empty the list. The dungeon name goes with it: an empty list belongs to no run.
---@return number removed
function Checklist.Clear()
    local data = Data()
    local removed = #data.quests
    wipe(data.quests)
    wipe(data.ticked)
    data.dungeon = nil
    Changed()
    return removed
end

---@return number
function Checklist.Count()
    return #Data().quests
end

--- A copy, so a caller sorting or filtering it cannot disturb the stored order.
---@return number[]
function Checklist.Ids()
    local out = {}
    for index, id in ipairs(Data().quests) do out[index] = id end
    return out
end

--- The dungeon the list is for, used as the tracker's title. Set when quests are added
--- from the planner; nil when the list was assembled by hand from the browser.
---@param name string?
function Checklist.SetDungeon(name)
    local data = Data()
    local wanted = QEF.Str(name)
    if data.dungeon == wanted then return end
    data.dungeon = wanted
    Changed()
end

---@return string?
function Checklist.Dungeon()
    return Data().dungeon
end

--------------------------------------------------------------------------------------------
-- Done, and what counts as done
--------------------------------------------------------------------------------------------

-- A quest in your log is under way, not finished: with turn-ins on the list, handing it in
-- is a step like any other, and it is usually the step people forget. So only "completed"
-- takes a quest off the list, where an earlier version of this stopped at "picked up".

--- Whether a quest is finished with, and the status it was judged on.
--- The manual tick exists for the cases the client cannot see: a quest another addon
--- abandoned, or one you have decided to skip.
---@param questId number
---@return boolean done
---@return string status
function Checklist.IsDone(questId)
    local status = Source and Source.QuestStatus(questId) or "available"
    if Data().ticked[questId] then return true, status end
    return status == "completed", status
end

---@param questId number
---@param value boolean
function Checklist.SetTicked(questId, value)
    questId = QEF.QuestId(questId)
    if not questId then return end
    Data().ticked[questId] = value and true or nil
    Changed()
end

---@param questId number
---@return boolean
function Checklist.IsTicked(questId)
    return Data().ticked[questId] and true or false
end

---@return number done
---@return number total
function Checklist.Progress()
    local data = Data()
    local done = 0
    for _, questId in ipairs(data.quests) do
        if Checklist.IsDone(questId) then done = done + 1 end
    end
    return done, #data.quests
end

--------------------------------------------------------------------------------------------
-- Steps
--------------------------------------------------------------------------------------------

-- Within one zone these are the order worth doing them in. A turn-in is almost always the
-- thing you are already standing next to, and a quest you cannot start yet is the one to
-- look at last.
local KIND_RANK = { turnin = 1, pickup = 2, finish = 3, blocked = 4 }

-- How far back to walk when the quest in front of you is locked. Five is past any real
-- chain's worth of prerequisites, and it stops a cycle in the data spinning.
local MAX_BLOCKER_HOPS = 5

--- The first quest in the way that you can actually do something about.
--- A prerequisite can be locked itself, two or three deep, and sending someone to an NPC
--- who will not talk to them is the exact failure this is here to avoid.
---@param questId number
---@return table? prerequisite { id, name, status }
local function ActionableBlocker(questId)
    if not Chain then return nil end
    local seen = {}
    local current = questId

    for _ = 1, MAX_BLOCKER_HOPS do
        if seen[current] then return nil end
        seen[current] = true

        local fallback
        for _, prerequisite in ipairs(Chain.Prerequisites(current)) do
            if prerequisite.status ~= "completed" then
                -- Anything not locked is something you can go and do right now.
                if prerequisite.status ~= "locked" then return prerequisite end
                fallback = fallback or prerequisite
            end
        end

        if not fallback then return nil end
        current = fallback.id
    end
    return nil
end

--- The one errand a quest needs next.
--- A step has a place when there is somewhere to send the player. A "finish" step takes
--- the first creature its objectives name that the database can find - a quest in your log
--- is not nowhere - and has no place at all when the objective is an item to gather or an
--- object to click, which needs a lookup this does not do. Inventing one would be worse
--- than the honest blank.
---@param questId number
---@param status string
---@return table step { kind, verb, place, blockers, blockerId, subject }
local function StepFor(questId, status)
    if status == "ready" then
        return { kind = "turnin", verb = "Hand in", place = Source and Source.QuestEnd(questId) }
    end

    if status == "active" then
        local step = { kind = "finish", verb = "Finish" }
        if Source then
            -- The quest's own zone, so the line groups with the rest of that zone's work
            -- rather than under "no recorded place".
            step.zoneOnly = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))
            -- And a place, when the objectives name a creature the database can find: a
            -- quest in your log is not nowhere, it is wherever those are standing. Quests
            -- asking for an item or an object still have none, and say so.
            step.place = Source.ObjectivePlace(questId)
        end
        return step
    end

    if status == "locked" then
        local blocker = ActionableBlocker(questId)
        if blocker then
            -- The step becomes that quest's own step - pick it up, finish it, hand it in -
            -- because "Unlock Heart of Disruption" tells you nothing about where to go,
            -- and "Pick up An Alarming Request, from Emissary Jacques" tells you exactly.
            -- The blocker is never locked itself, so this recurses once and no further.
            local step = StepFor(blocker.id, blocker.status)
            step.blockerId = blocker.id
            step.subject = blocker.name or ("quest " .. tostring(blocker.id))
            step.unlocks = {}
            return step
        end

        -- Nothing walkable: name what is in the way and leave it at that.
        local step = { kind = "blocked", verb = "Unlock", blockers = {} }
        for _, prerequisite in ipairs(Chain and Chain.Prerequisites(questId) or {}) do
            if prerequisite.status ~= "completed" then
                step.blockers[#step.blockers + 1] =
                    prerequisite.name or ("quest " .. tostring(prerequisite.id))
            end
        end
        return step
    end

    return { kind = "pickup", verb = "Pick up", place = Source and Source.QuestStart(questId) }
end

--- Everything worth showing about one quest on the list, including its current step.
---@param questId number
---@return table entry
function Checklist.Entry(questId)
    local done, status = Checklist.IsDone(questId)
    local entry = {
        id = questId,
        name = (Source and Source.QuestName(questId)) or ("Quest " .. tostring(questId)),
        status = status,
        done = done,
        ticked = Checklist.IsTicked(questId),
    }
    if Source then
        entry.level = select(1, Source.QuestLevels(questId))
    end
    if not done then
        local step = StepFor(questId, status)
        entry.step = step
        -- What the line is about: usually this quest, but a blocked quest's line is about
        -- the quest standing in its way.
        step.subject = step.subject or entry.name
        if step.blockerId then step.unlocks = { entry.name } end

        local place = step.place
        if place then
            step.npc = place.name
            step.zone = place.zoneName
            step.uiMapId = place.uiMapId
            step.x, step.y = place.x, place.y
        elseif step.zoneOnly then
            step.zone = step.zoneOnly
        end
    end
    return entry
end

--------------------------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------------------------

--------------------------------------------------------------------------------------------
-- Walking order
--------------------------------------------------------------------------------------------

--- Reorder a zone's steps into the order you would actually walk them, nearest first and
--- then nearest to that, rather than by what kind of step they are.
---
--- Nearest-neighbour, not a shortest path: the exact answer is the travelling salesman and
--- the inputs do not deserve it - a handful of points, straight-line distances that ignore
--- every cliff and river between them. What it buys is real all the same, because the thing
--- it replaces is an order with no relation to the ground at all.
---
--- Only ever applied to the zone the player is standing in, since that is the only one
--- there is a starting point for. Steps with no recorded place keep their order at the end.
---@param entries table[]
---@param fromX number
---@param fromY number
local function WalkOrder(entries, fromX, fromY)
    local placed, unplaced = {}, {}
    for _, entry in ipairs(entries) do
        local step = entry.step
        if step.x and step.y then
            placed[#placed + 1] = entry
        else
            unplaced[#unplaced + 1] = entry
        end
    end
    if #placed < 2 then return end

    local route = {}
    local x, y = fromX, fromY
    while #placed > 0 do
        local best, bestIndex, bestDistance
        for index, entry in ipairs(placed) do
            local dx, dy = entry.step.x - x, entry.step.y - y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestIndex, bestDistance = entry, index, distance
            end
        end
        route[#route + 1] = best
        -- Each leg starts where the last one ended, which is what makes this a walk rather
        -- than a list sorted by how far each point is from the door.
        x, y = best.step.x, best.step.y
        table.remove(placed, bestIndex)
    end

    for _, entry in ipairs(unplaced) do
        route[#route + 1] = entry
    end
    for index = 1, #entries do
        entries[index] = route[index]
    end
end

-- Groups are ordered by how soon you can act on them: the zone you are standing in, then
-- zones with work left, then the steps with no recorded place at all.
local function GroupRank(group, playerZone)
    if not group.zone then return 3 end
    if playerZone and group.zone == playerZone then return 1 end
    return 2
end

--- The whole list as steps grouped by where they are done, plus the quests already
--- finished with, which are kept out of the way rather than mixed in.
---@return table plan { dungeon, done, total, groups, steps, finished }
function Checklist.Plan()
    local data = Data()
    local plan = {
        dungeon = data.dungeon, done = 0, total = 0,
        groups = {}, steps = {}, finished = {},
    }

    local playerMapId, playerX, playerY
    if Travel then playerMapId, playerX, playerY = Travel.PlayerPoint() end
    local playerContinent = playerMapId and Travel and Travel.ContinentOf(playerMapId) or nil
    local playerZone = playerMapId
        and QEF.Str((QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, playerMapId)) or {}).name)

    -- Every quest's current step, before any folding together.
    local outstanding = {}
    for _, questId in ipairs(data.quests) do
        local entry = Checklist.Entry(questId)
        plan.total = plan.total + 1
        if entry.done then
            plan.done = plan.done + 1
            plan.finished[#plan.finished + 1] = entry
        else
            -- Which of your quests this one line stands in for. Dropping the line drops
            -- all of them, and the strip says so before it does.
            entry.covers = { entry.id }
            outstanding[#outstanding + 1] = entry
        end
    end

    -- One errand, one line. Two quests waiting on the same prerequisite share a step, and
    -- so does a quest that is itself on your list - otherwise the prerequisite is drawn
    -- once as itself and again under everything it unblocks.
    local realById, byBlocker = {}, {}
    for _, entry in ipairs(outstanding) do
        if not entry.step.blockerId then realById[entry.id] = entry end
    end

    local rows = {}
    for _, entry in ipairs(outstanding) do
        local blockerId = entry.step.blockerId
        local target = blockerId and (realById[blockerId] or byBlocker[blockerId]) or nil
        if target then
            target.covers[#target.covers + 1] = entry.id
            target.step.unlocks = target.step.unlocks or {}
            local unlocks = target.step.unlocks
            unlocks[#unlocks + 1] = entry.name
        else
            if blockerId then byBlocker[blockerId] = entry end
            rows[#rows + 1] = entry
        end
    end

    local byZone, order = {}, {}
    for _, entry in ipairs(rows) do
        local step = entry.step
        local key = step.zone or "\1nowhere"
        local group = byZone[key]
        if not group then
            group = { zone = step.zone, uiMapId = step.uiMapId, entries = {} }
            if Travel and step.uiMapId and playerContinent then
                local continent = Travel.ContinentOf(step.uiMapId)
                group.otherContinent = continent ~= nil and continent ~= playerContinent
            end
            byZone[key] = group
            order[#order + 1] = group
        end
        group.entries[#group.entries + 1] = entry
    end

    for _, group in ipairs(order) do
        table.sort(group.entries, function(a, b)
            local rankA = KIND_RANK[a.step.kind] or 9
            local rankB = KIND_RANK[b.step.kind] or 9
            if rankA ~= rankB then return rankA < rankB end
            if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
            return a.name < b.name
        end)
        -- The zone you are standing in is the one with a starting point, so it is the one
        -- that can be put in walking order.
        if QEF.Get("walkOrder") and playerX and playerY
            and group.uiMapId and group.uiMapId == playerMapId then
            WalkOrder(group.entries, playerX, playerY)
            group.walked = true
        end

        group.outstanding = #group.entries
        group.nextId = group.entries[1] and group.entries[1].id or nil

        -- Somewhere for the zone heading to point at: the first step in it with a place.
        for _, entry in ipairs(group.entries) do
            local step = entry.step
            if step.uiMapId and step.x and step.y then
                group.place = {
                    name = step.npc, zoneName = step.zone,
                    uiMapId = step.uiMapId, x = step.x, y = step.y,
                }
                break
            end
        end
    end

    table.sort(order, function(a, b)
        local rankA, rankB = GroupRank(a, playerZone), GroupRank(b, playerZone)
        if rankA ~= rankB then return rankA < rankB end
        return (a.zone or "") < (b.zone or "")
    end)

    -- One flat ordered list of the same steps. The tracker draws from the groups and the
    -- guide walks this, and because both come out of the same sort, "the next step" means
    -- the same thing in the strip and on the marker.
    for _, group in ipairs(order) do
        for _, entry in ipairs(group.entries) do
            plan.steps[#plan.steps + 1] = entry
        end
    end

    plan.groups = order
    plan.playerZone = playerZone
    return plan
end

--- The current steps on their own, in the order the strip lists them.
---@return table[] entries
function Checklist.Steps()
    return Checklist.Plan().steps
end

--- Take every finished quest off the list, which is how the strip gets tidied up after a
--- run without throwing away what is still outstanding.
---@return number removed
function Checklist.RemoveFinished()
    local data = Data()
    local removed = 0
    for index = #data.quests, 1, -1 do
        local questId = data.quests[index]
        if Checklist.IsDone(questId) then
            table.remove(data.quests, index)
            data.ticked[questId] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then Changed() end
    return removed
end

--------------------------------------------------------------------------------------------
-- Bulk edits from the planner
--------------------------------------------------------------------------------------------

--- Put a whole dungeon's quests on the list.
--- Quests you have already finished are skipped, and so is anything already listed. One you
--- are holding is not skipped: handing it in is a step the list is there to remember.
---@param dungeonName string
---@param entries table[] { id = number } as the planner has them
---@return number added
function Checklist.AddAll(dungeonName, entries)
    local data = Data()
    local added = 0
    for _, entry in ipairs(entries or {}) do
        local questId = QEF.QuestId(entry.id)
        if questId and not Checklist.Has(questId) and not Checklist.IsDone(questId) then
            data.quests[#data.quests + 1] = questId
            added = added + 1
        end
    end
    if added > 0 then
        data.dungeon = QEF.Str(dungeonName) or data.dungeon
        Changed()
    end
    return added
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Checklist", function()
    Source = QEF.Source
    Chain = QEF.Chain
    Travel = QEF.Travel
end)
