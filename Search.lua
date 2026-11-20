-- Search.lua
--
-- The index behind the browser: every quest QuestieDB knows, with the handful of fields the
-- list and its filters need.
--
-- Built on first use rather than at login, because nobody who never opens the browser should
-- pay for it. Reading a quest's name, levels and zone costs one scalar-row decode, and
-- Index.lua has usually warmed those already, so in practice this is quick.

local ADDON, QEF = ...

local Search = {}
QEF.Search = Search

local Source

Search.ready = false
Search.building = false
Search.progress = 0

-- Parallel arrays rather than a table per quest: 5,900 small tables is a lot of garbage for
-- data that is only ever read in bulk.
local ids, names, lowered, levels, required, zones, dungeons, factions =
    {}, {}, {}, {}, {}, {}, {}, {}
local count = 0

--- Zone name -> number of quests, for the zone filter.
Search.zoneCounts = {}
Search.zoneList = {}

--- The subset of those zones that are dungeons, for the run planner. Collected in the same
--- pass, since the build already works out which zones are dungeons.
Search.dungeonCounts = {}
Search.dungeonList = {}

--- Called as the build progresses and once when it finishes.
Search.OnProgress = nil

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function Build()
    local questIds = Source.AllIds("Quest")
    local total = #questIds
    count = 0
    wipe(ids) wipe(names) wipe(lowered) wipe(levels)
    wipe(required) wipe(zones) wipe(dungeons) wipe(factions)
    wipe(Search.zoneCounts) wipe(Search.zoneList)
    wipe(Search.dungeonCounts) wipe(Search.dungeonList)

    for position = 1, total do
        local questId = questIds[position]
        local name = Source.QuestName(questId)
        if name then
            local questLevel, requiredLevel = Source.QuestLevels(questId)
            local zoneName, isDungeon = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))

            count = count + 1
            ids[count] = questId
            names[count] = name
            lowered[count] = name:lower()
            levels[count] = questLevel
            required[count] = requiredLevel
            zones[count] = zoneName
            dungeons[count] = isDungeon and zoneName or nil
            factions[count] = Source.QuestFaction(questId)

            if zoneName then
                Search.zoneCounts[zoneName] = (Search.zoneCounts[zoneName] or 0) + 1
                if isDungeon then
                    Search.dungeonCounts[zoneName] =
                        (Search.dungeonCounts[zoneName] or 0) + 1
                end
            end
        end

        if position % 150 == 0 then
            Search.progress = position / total
            if Search.OnProgress then Search.OnProgress(Search.progress) end
            QEF.Yield()
        end
    end

    for zoneName in pairs(Search.zoneCounts) do
        Search.zoneList[#Search.zoneList + 1] = zoneName
    end
    table.sort(Search.zoneList)

    for dungeonName in pairs(Search.dungeonCounts) do
        Search.dungeonList[#Search.dungeonList + 1] = dungeonName
    end
    table.sort(Search.dungeonList)

    Search.progress = 1
    Search.ready = true
    Search.building = false
    QEF.Debug("search index:", count, "quests across", #Search.zoneList, "zones")
    if Search.OnProgress then Search.OnProgress(1) end
end

--- Start building if it has not been built already. Safe to call repeatedly.
---@return boolean ready
function Search.Ensure()
    if Search.ready then return true end
    if Search.building then return false end
    if not Source.available then return false end
    Search.building = true
    Search.progress = 0
    QEF.RunBudgeted(Build, 8)
    return false
end

--- Drop the index so the next open rebuilds it, after a locale or database change.
function Search.Invalidate()
    Search.ready = false
    Search.building = false
    count = 0
end

---@return number
function Search.Count()
    return count
end

--------------------------------------------------------------------------------------------
-- Chain ordering
--------------------------------------------------------------------------------------------
--
-- A flat level-sorted list scatters a chain across the whole window: the quest that follows
-- the one you are reading is forty rows down, because it is two levels higher. So the
-- results are regrouped into the chains they belong to, each quest indented under the one it
-- comes after.
--
-- Only quests that matched the filters are shown. A follower whose predecessor was filtered
-- out is attached to its nearest ancestor that *is* in the list, so the indent always means
-- "comes after the row above" rather than silently inventing rows.

-- How far up a chain to look for a predecessor that is in the list. Chains run to about ten
-- steps; beyond that the quest is better treated as a root than tied to something far away.
local MAX_ANCESTOR_STEPS = 10

--- The nearest predecessor of a quest that is also in the result set.
--- A breadth-first walk upwards, since a quest can have several prerequisites; the lowest id
--- wins a tie so the same list always comes out the same way.
---@param questId number
---@param byId table id -> entry
---@return number? parentId
local function NearestShownAncestor(questId, byId)
    local parents = QEF.Index and QEF.Index.parents
    if not parents then return nil end

    local seen = { [questId] = true }
    local frontier = { questId }

    for _ = 1, MAX_ANCESTOR_STEPS do
        local nextFrontier, best = {}, nil
        for _, id in ipairs(frontier) do
            for parentId in pairs(parents[id] or {}) do
                if not seen[parentId] then
                    seen[parentId] = true
                    if byId[parentId] then
                        if not best or parentId < best then best = parentId end
                    else
                        nextFrontier[#nextFrontier + 1] = parentId
                    end
                end
            end
        end
        if best then return best end
        if #nextFrontier == 0 then return nil end
        frontier = nextFrontier
    end
    return nil
end

--- Regroup a sorted result list into chain order, annotating each entry with its depth, its
--- place among its siblings, and which ancestor columns still have rows below them, which is
--- everything the list rows need to draw the connectors.
---@param results table[] sorted
---@return table[] ordered
local function ChainOrder(results)
    local byId = {}
    for _, entry in ipairs(results) do byId[entry.id] = entry end

    -- Buckets inherit the sort order of `results`, since they are filled in that order.
    local childrenOf, roots = {}, {}
    for _, entry in ipairs(results) do
        local parentId = NearestShownAncestor(entry.id, byId)
        if parentId then
            local bucket = childrenOf[parentId]
            if not bucket then
                bucket = {}
                childrenOf[parentId] = bucket
            end
            bucket[#bucket + 1] = entry
        else
            roots[#roots + 1] = entry
        end
    end

    local ordered, placed, stack = {}, {}, {}

    local function emit(entry, depth, isLast)
        -- Chains in the data are graphs and a bad correction can make a loop; `placed` is
        -- what stops one becoming an infinite list.
        if placed[entry.id] then return end
        placed[entry.id] = true

        local continues
        if depth > 1 then
            continues = {}
            for level = 1, depth - 1 do continues[level] = stack[level] end
        end

        entry.depth = depth
        entry.last = isLast
        entry.continues = continues
        ordered[#ordered + 1] = entry

        local kids = childrenOf[entry.id]
        if not kids then return end
        if depth >= 1 then stack[depth] = not isLast end
        for index, kid in ipairs(kids) do
            emit(kid, depth + 1, index == #kids)
        end
        if depth >= 1 then stack[depth] = nil end
    end

    for index, entry in ipairs(roots) do
        emit(entry, 0, index == #roots)
    end
    -- Anything left is in a cycle, so it has a parent but was never reached from a root.
    -- Showing it as a root of its own is better than dropping it.
    for _, entry in ipairs(results) do
        if not placed[entry.id] then emit(entry, 0, true) end
    end

    return ordered
end

--------------------------------------------------------------------------------------------
-- Query
--------------------------------------------------------------------------------------------

--- A plain-text match. A query that is only digits also matches the quest id exactly, so
--- pasting an id from /qef debug finds the quest.
---@param filters table { text, zone, dungeonsOnly, rewardsOnly, myFaction, levelMin, levelMax }
---@return table[] results  { id, name, level, required, zone, isDungeon, faction }
function Search.Query(filters)
    filters = filters or {}
    local results = {}
    if not Search.ready then return results end

    local text = filters.text
    if text == "" then text = nil end
    local needle = text and text:lower() or nil
    local wantedId = text and tonumber(text) or nil

    local playerFaction = QEF.Art and QEF.Art.PlayerFaction() or nil
    local zoneFilter = filters.zone
    local levelMin = QEF.Num(filters.levelMin)
    local levelMax = QEF.Num(filters.levelMax)

    for index = 1, count do
        local include = true

        if needle then
            include = lowered[index]:find(needle, 1, true) ~= nil
            if not include and wantedId and ids[index] == wantedId then include = true end
        end
        if include and zoneFilter then
            include = zones[index] == zoneFilter
        end
        if include and filters.dungeonsOnly then
            include = dungeons[index] ~= nil
        end
        if include and filters.myFaction then
            -- A quest with no faction requirement is open to everyone, so it stays in.
            local questFaction = factions[index]
            include = questFaction == nil or questFaction == playerFaction
        end
        if include and (levelMin or levelMax) then
            local level = levels[index]
            if not level then
                include = false
            else
                if levelMin and level < levelMin then include = false end
                if levelMax and level > levelMax then include = false end
            end
        end
        if include and filters.rewardsOnly then
            -- A learned answer is authoritative, including a learned "nothing"; only fall
            -- back to the database relation when the server has never been asked.
            local questId = ids[index]
            local learned = QEF.learned and QEF.learned[questId]
            if learned then
                include = not learned.e
            else
                include = #QEF.Index.RewardItems(questId) > 0
            end
        end

        if include then
            results[#results + 1] = {
                id = ids[index],
                name = names[index],
                level = levels[index],
                required = required[index],
                zone = zones[index],
                isDungeon = dungeons[index] ~= nil,
                faction = factions[index],
            }
        end
    end

    -- Quest level first, then name: a level-ordered list is how you actually plan a session.
    -- Chain ordering keeps this ordering within each chain and for the chain starts, so a
    -- grouped list is still a level-ordered one at every branch.
    table.sort(results, function(a, b)
        local levelA = a.level or 999
        local levelB = b.level or 999
        if levelA ~= levelB then return levelA < levelB end
        return a.name < b.name
    end)

    if QEF.Get("chainOrder") and QEF.Index and QEF.Index.ready then
        return ChainOrder(results)
    end
    for _, entry in ipairs(results) do
        entry.depth = 0
    end
    return results
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Search", function()
    Source = QEF.Source
end)
