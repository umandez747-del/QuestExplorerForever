-- Chain.lua
--
-- Where a quest sits in its chain, what it leads to, what the chain ends with, and whether it
-- gates a dungeon quest.
--
-- Chains in the data are graphs, not lines: a quest can have several prerequisites, several
-- successors, and branches that rejoin. So "step 2 of 4" is the quest's depth from the root
-- against the longest path through the whole chain, which is an estimate and is described as
-- one. Everything here is cycle-safe and capped, because a bad correction in any quest
-- database can produce a loop and a tooltip is not the place to find out.

local ADDON, QEF = ...

local Chain = {}
QEF.Chain = Chain

local Source, Index

local MAX_NODES = 60
local MAX_BACKWARD_STEPS = 20

local analysisCache = {}

--------------------------------------------------------------------------------------------
-- Walking backwards to the start of the chain
--------------------------------------------------------------------------------------------

--- The first prerequisite of a quest, whichever field supplies it.
---@param questId number
---@return number?
local function FirstPrerequisite(questId)
    local single = QEF.Tbl(Source.Quest(questId, "preQuestSingle"))
    if single and single[1] then return QEF.QuestId(single[1]) end

    local group = QEF.Tbl(Source.Quest(questId, "preQuestGroup"))
    if group and group[1] then return QEF.QuestId(group[1]) end

    local parent = QEF.QuestId(Source.Quest(questId, "parentQuest"))
    if parent then return parent end

    return QEF.QuestId(Source.Quest(questId, "availableStartingWith"))
end

--- Walk back to the first quest in the chain, recording the route.
--- Returns the quest itself when it has no prerequisite, and gives up at MAX_BACKWARD_STEPS
--- or on a cycle rather than looping.
---@param questId number
---@return number root
---@return number stepsBack
---@return number[] path  root first, the quest itself last
function Chain.Root(questId)
    local current = QEF.QuestId(questId)
    if not current then return questId, 0, {} end

    local seen = { [current] = true }
    local reverse = { current }
    local steps = 0
    while steps < MAX_BACKWARD_STEPS do
        local previous = FirstPrerequisite(current)
        if not previous or seen[previous] then break end
        seen[previous] = true
        current = previous
        steps = steps + 1
        reverse[#reverse + 1] = current
    end

    local path = {}
    for index = #reverse, 1, -1 do path[#path + 1] = reverse[index] end
    return current, steps, path
end

--- Every quest a given quest depends on directly, which is what a player needs in order to
--- go and find the start of a chain they cannot pick up yet.
---@param questId number
---@return table[] entries { id, name, level, status, required }
function Chain.Prerequisites(questId)
    local entries = {}
    if not Source.available then return entries end

    local function add(list, required)
        for _, prerequisiteId in ipairs(QEF.Tbl(list) or {}) do
            prerequisiteId = QEF.QuestId(prerequisiteId)
            if prerequisiteId then
                entries[#entries + 1] = {
                    id = prerequisiteId,
                    name = Source.QuestName(prerequisiteId),
                    level = select(1, Source.QuestLevels(prerequisiteId)),
                    status = Source.QuestStatus(prerequisiteId),
                    required = required,
                }
            end
        end
    end

    -- "any" means one of them unlocks this quest; "all" means every one is needed.
    add(Source.Quest(questId, "preQuestSingle"), "any")
    add(Source.Quest(questId, "preQuestGroup"), "all")
    return entries
end

--------------------------------------------------------------------------------------------
-- Walking forwards
--------------------------------------------------------------------------------------------

--- Breadth-first walk forward from a quest. Returns nodes keyed by id with their depth, in
--- discovery order, plus whether the walk hit a cap.
---@param startId number
---@param maxDepth number
---@return table[] nodes  list of { id = number, depth = number }
---@return boolean truncated
---@return table cameFrom  id -> the id it was first reached from, for walking a line back
local function Forward(startId, maxDepth)
    local nodes = {}
    local depthOf = { [startId] = 0 }
    local cameFrom = {}
    local queue = { startId }
    local head = 1
    local truncated = false

    while head <= #queue do
        local id = queue[head]
        head = head + 1
        local depth = depthOf[id]
        nodes[#nodes + 1] = { id = id, depth = depth }

        if #nodes >= MAX_NODES then
            truncated = head <= #queue
            break
        end
        if depth >= maxDepth then
            truncated = true
        else
            for _, edge in ipairs(Index.Children(id)) do
                if depthOf[edge.id] == nil then
                    depthOf[edge.id] = depth + 1
                    cameFrom[edge.id] = id
                    queue[#queue + 1] = edge.id
                end
            end
        end
    end

    return nodes, truncated, cameFrom
end

--------------------------------------------------------------------------------------------
-- Analysis
--------------------------------------------------------------------------------------------

--- Everything Quest Explorer can say about a quest's chain. Returns nil when there is no static
--- quest database to read, or when the quest is not part of a chain at all.
---@param questId number
---@return table? info
function Chain.Analyse(questId)
    questId = QEF.QuestId(questId)
    if not questId then return nil end
    if not Source.available or not Index.ready then return nil end

    local cached = analysisCache[questId]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local maxDepth = QEF.Num(QEF.Get("maxChainDepth")) or 12
    local root, stepsBack, path = Chain.Root(questId)

    -- The whole chain from its root, so "of 4" counts the chain rather than what is left.
    local allNodes, truncated = Forward(root, maxDepth + stepsBack)
    local total = 0
    for _, node in ipairs(allNodes) do
        if node.depth > total then total = node.depth end
    end

    -- What is still ahead of the player's quest.
    local aheadNodes, aheadTruncated = Forward(questId, maxDepth)
    truncated = truncated or aheadTruncated

    local info = {
        questId = questId,
        root = root,
        position = stepsBack + 1,
        total = total + 1,
        nodeCount = #allNodes,
        truncated = truncated,
        path = path,
        next = {},
        prerequisites = Chain.Prerequisites(questId),
        terminals = {},
        final = nil,
        dungeon = nil,
        isDungeonQuest = nil,
    }

    -- Immediate successors.
    for _, edge in ipairs(Index.Children(questId)) do
        local level = select(1, Source.QuestLevels(edge.id))
        info.next[#info.next + 1] = {
            id = edge.id,
            kind = edge.kind,
            name = Source.QuestName(edge.id),
            level = level,
        }
    end

    -- Terminals: quests ahead of this one that lead nowhere further.
    local deepest = -1
    for _, node in ipairs(aheadNodes) do
        if node.id ~= questId and #Index.Children(node.id) == 0 then
            local terminal = { id = node.id, depth = node.depth, name = Source.QuestName(node.id) }
            info.terminals[#info.terminals + 1] = terminal
            if node.depth > deepest then
                deepest = node.depth
                info.final = terminal
            end
        end
    end

    -- A quest that ends the chain itself has no terminal ahead of it.
    if not info.final and #info.next == 0 then
        info.endsHere = true
    end

    -- Dungeon gating. The quest's own dungeon is reported separately from a dungeon quest
    -- further along, because "this is a Uldaman quest" and "this unlocks a Uldaman quest" are
    -- different things to the player.
    info.isDungeonQuest = Source.DungeonOf(questId)
    local bestDepth
    for _, node in ipairs(aheadNodes) do
        if node.id ~= questId then
            local dungeon = Source.DungeonOf(node.id)
            if dungeon and (not bestDepth or node.depth < bestDepth) then
                bestDepth = node.depth
                info.dungeon = {
                    name = dungeon,
                    questId = node.id,
                    questName = Source.QuestName(node.id),
                    depth = node.depth,
                }
            end
        end
    end

    -- A chain of one, going nowhere, is not worth a line in a tooltip.
    if info.total <= 1 and #info.next == 0 and #info.prerequisites == 0 and not info.dungeon then
        analysisCache[questId] = false
        return nil
    end

    analysisCache[questId] = info
    return info
end

--- The quests whose rewards are worth showing as "what this chain ends with": the deepest
--- terminal, plus any other terminal at the same depth.
---@param info table
---@return number[] questIds
function Chain.FinalQuestIds(info)
    if not info then return {} end
    if not info.final then return {} end

    local out = {}
    for _, terminal in ipairs(info.terminals) do
        if terminal.depth == info.final.depth then
            out[#out + 1] = terminal.id
        end
    end
    return out
end

--------------------------------------------------------------------------------------------
-- Where it goes from here
--------------------------------------------------------------------------------------------

--- The line of quests from this one to the far end of its chain.
---
--- The quest dialog already tells you what this quest asks for and what it pays. What it
--- never tells you is that it is the first of four, that the third one is in a dungeon, or
--- that the real reward is at the end - which is the whole question when you are deciding
--- whether to take it. This is that line: the main path forward, not every branch.
---
--- Branches are reported as a count rather than drawn, because a preview that forks is a
--- preview nobody reads. The path followed is the one that reaches the deepest terminal,
--- which is the chain's own main line.
---@param questId number
---@param limit number? how many steps ahead to return, default 4
---@return table[] steps { id, name, level, status, depth, dungeon }
---@return boolean truncated  true when the chain carries on past the limit
function Chain.PathAhead(questId, limit)
    questId = QEF.QuestId(questId)
    limit = limit or 4
    if not questId or not Source.available or not Index.ready then return {}, false end

    local maxDepth = QEF.Num(QEF.Get("maxChainDepth")) or 12
    local nodes, _, cameFrom = Forward(questId, maxDepth)
    if #nodes <= 1 then return {}, false end

    -- The deepest node reached is the end of the main line. Ties go to whichever the
    -- breadth-first walk found first, which is the lowest quest id at that depth.
    local target, targetDepth
    for _, node in ipairs(nodes) do
        if not targetDepth or node.depth > targetDepth then
            target, targetDepth = node.id, node.depth
        end
    end
    if not target or target == questId then return {}, false end

    -- Walk the parent pointers back from the end, then reverse: that is the line forwards.
    local reversed = {}
    local id = target
    while id and id ~= questId do
        reversed[#reversed + 1] = id
        id = cameFrom[id]
    end

    local steps = {}
    for index = #reversed, 1, -1 do
        local stepId = reversed[index]
        steps[#steps + 1] = {
            id = stepId,
            name = Source.QuestName(stepId) or ("Quest " .. stepId),
            level = select(1, Source.QuestLevels(stepId)),
            status = Source.QuestStatus(stepId),
            depth = #reversed - index + 1,
            dungeon = Source.DungeonOf(stepId),
        }
        if #steps >= limit then
            return steps, index > 1
        end
    end
    return steps, false
end

--------------------------------------------------------------------------------------------
-- The whole chain, as a tree
--------------------------------------------------------------------------------------------

--- Every quest in a chain, from its root, in reading order, with each one's depth and status.
--- Depth-first so a branch stays together instead of being interleaved with its siblings,
--- which is what makes an indented list readable.
---@param questId number
---@return table[] nodes { id, depth, name, level, status, isDungeon, faction, isCurrent, last }
function Chain.FullTree(questId)
    questId = QEF.QuestId(questId)
    if not questId or not Source.available or not Index.ready then return {} end

    local root = Chain.Root(questId)
    local nodes = {}
    local visited = {}
    local maxDepth = (QEF.Num(QEF.Get("maxChainDepth")) or 12) + MAX_BACKWARD_STEPS

    local function visit(id, depth, isLast)
        if visited[id] or #nodes >= MAX_NODES or depth > maxDepth then return end
        visited[id] = true

        local level = select(1, Source.QuestLevels(id))
        local dungeon = Source.DungeonOf(id)
        nodes[#nodes + 1] = {
            id = id,
            depth = depth,
            name = Source.QuestName(id) or ("Quest " .. id),
            level = level,
            status = Source.QuestStatus(id),
            isDungeon = dungeon ~= nil,
            dungeonName = dungeon,
            faction = Source.QuestFaction(id),
            isCurrent = id == questId,
            last = isLast,
        }

        local children = Index.Children(id)
        for index, edge in ipairs(children) do
            visit(edge.id, depth + 1, index == #children)
        end
    end

    visit(root, 0, true)
    return nodes
end

function Chain.Invalidate()
    analysisCache = {}
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Chain", function()
    Source = QEF.Source
    Index = QEF.Index
    -- The index arrives a second or so after login; anything analysed before then would have
    -- been answered with an empty chain.
    Index.OnReady = function()
        Chain.Invalidate()
        if QEF.Rewards and QEF.Rewards.OnUpdate then QEF.Rewards.OnUpdate(nil) end
    end

    -- Analyses carry each quest's status, so completing or accepting one makes them stale.
    for _, event in ipairs({ "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED" }) do
        QEF.On(event, function()
            Chain.Invalidate()
            if QEF.Browse and QEF.Browse.Refresh then QEF.Browse.Refresh() end
        end)
    end
end)
