-- Index.lua
--
-- QuestieDB answers "what does this quest need?" and "which quests reward this item?". Both
-- of those point backwards. To say what a quest *leads to* and what a chain *ends with*, both
-- relations have to be inverted once at login.
--
-- Two indices are built:
--
--   children[questId]    -> { [nextQuestId] = edgeKind }
--   parents[questId]     -> { [previousQuestId] = edgeKind }
--   rewardItems[questId] -> { itemId, ... }
--
-- The parent map is the same edges read backwards, recorded as they are added, so it costs
-- nothing beyond its memory. The browser needs it to answer "is this quest's predecessor
-- also in the list?" for every row at once, which a per-quest field read cannot do cheaply.
--
-- Neither is persisted. The quest pass is 5,893 reads; the item pass is 23,859 existence
-- probes against the TOC metadata store (no decode) and only ~2,500 real reads. Both run on a
-- frame budget so login never stutters, and rebuilding from scratch avoids every class of bug
-- that comes from a cache going stale against an updated QuestieDB.

local ADDON, QEF = ...

local Index = {}
QEF.Index = Index

Index.children = {}
Index.parents = {}
Index.rewardItems = {}
Index.ready = false
Index.stats = {
    quests = 0,
    chainEdges = 0,
    items = 0,
    rewardQuests = 0,
    rewardRelations = 0,
    elapsedMs = 0,
    probed = false,
}

local Source

--------------------------------------------------------------------------------------------
-- Chain edges
--------------------------------------------------------------------------------------------

local function AddEdge(fromId, toId, kind)
    fromId = QEF.QuestId(fromId)
    toId = QEF.QuestId(toId)
    if not fromId or not toId or fromId == toId then return end

    local bucket = Index.children[fromId]
    if not bucket then
        bucket = {}
        Index.children[fromId] = bucket
    end
    if bucket[toId] == nil then
        bucket[toId] = kind
        Index.stats.chainEdges = Index.stats.chainEdges + 1
    end

    local back = Index.parents[toId]
    if not back then
        back = {}
        Index.parents[toId] = back
    end
    if back[fromId] == nil then back[fromId] = kind end
end

--- Both prerequisite fields are lists of quests that must come first, so each one is an edge
--- pointing at the quest being read.
local function AddPrerequisiteEdges(questId, fieldName, kind)
    local list = QEF.Tbl(Source.Quest(questId, fieldName))
    if not list then return end
    for _, prerequisiteId in ipairs(list) do
        AddEdge(prerequisiteId, questId, kind)
    end
end

local function IndexQuest(questId)
    AddPrerequisiteEdges(questId, "preQuestSingle", "pre")
    AddPrerequisiteEdges(questId, "preQuestGroup", "pre")

    -- A sub-quest needs its parent active, so the parent leads to it.
    AddEdge(QEF.Num(Source.Quest(questId, "parentQuest")), questId, "parent")
    -- "must be active or completed for this quest to become available"
    AddEdge(QEF.Num(Source.Quest(questId, "availableStartingWith")), questId, "pre")

    -- Forward links the DB states directly.
    AddEdge(questId, QEF.Num(Source.Quest(questId, "nextQuestInChain")), "next")
    AddEdge(questId, QEF.Num(Source.Quest(questId, "breadcrumbForQuestId")), "breadcrumb")

    local childQuests = QEF.Tbl(Source.Quest(questId, "childQuests"))
    if childQuests then
        for _, childId in ipairs(childQuests) do
            AddEdge(questId, childId, "child")
        end
    end
end

--------------------------------------------------------------------------------------------
-- Reward items
--------------------------------------------------------------------------------------------

local function AddReward(questId, itemId)
    questId = QEF.QuestId(questId)
    itemId = QEF.Num(itemId)
    if not questId or not itemId then return end

    local bucket = Index.rewardItems[questId]
    if not bucket then
        bucket = {}
        Index.rewardItems[questId] = bucket
        Index.stats.rewardQuests = Index.stats.rewardQuests + 1
    end
    for i = 1, #bucket do
        if bucket[i] == itemId then return end
    end
    bucket[#bucket + 1] = itemId
    Index.stats.rewardRelations = Index.stats.rewardRelations + 1
end

local function IndexItem(itemId)
    local quests = QEF.Tbl(Source.Item(itemId, "questRewards"))
    if not quests then return end
    for _, questId in ipairs(quests) do
        AddReward(questId, itemId)
    end
end

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function Build()
    local started = debugprofilestop()

    local questIds = Source.AllIds("Quest")
    Index.stats.quests = #questIds
    for i = 1, #questIds do
        IndexQuest(questIds[i])
        if i % 100 == 0 then QEF.Yield() end
    end
    QEF.Debug("chain index:", Index.stats.chainEdges, "edges over", Index.stats.quests, "quests")

    local itemIds = Source.AllIds("Item")
    Index.stats.items = #itemIds
    local canProbe = Source.CanProbe()
    Index.stats.probed = canProbe
    local rewardField = Source.ITEM_FIELD_QUEST_REWARDS

    for i = 1, #itemIds do
        local itemId = itemIds[i]
        -- The probe is the whole reason this pass is affordable: one metadata lookup per
        -- item, and a decode only for the few thousand that actually reward a quest.
        if (not canProbe) or Source.HasField("Item", itemId, rewardField) then
            IndexItem(itemId)
        end
        if i % 250 == 0 then QEF.Yield() end
    end

    Index.stats.elapsedMs = debugprofilestop() - started
    Index.ready = true
    QEF.Debug(string.format("index built in %.0f ms - %d quests with reward items, %d relations",
        Index.stats.elapsedMs, Index.stats.rewardQuests, Index.stats.rewardRelations))

    if Index.OnReady then Index.OnReady() end
end

--------------------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------------------

--- The quests this one leads to, as a sorted list of {id, kind}.
---@param questId number
---@return table[]
function Index.Children(questId)
    questId = QEF.QuestId(questId)
    local bucket = questId and Index.children[questId]
    if not bucket then return {} end

    local out = {}
    for childId, kind in pairs(bucket) do
        out[#out + 1] = { id = childId, kind = kind }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The quests that lead to this one, as a sorted list of {id, kind}. For a bulk walk read
--- Index.parents directly rather than calling this per quest; it allocates.
---@param questId number
---@return table[]
function Index.Parents(questId)
    questId = QEF.QuestId(questId)
    local bucket = questId and Index.parents[questId]
    if not bucket then return {} end

    local out = {}
    for parentId, kind in pairs(bucket) do
        out[#out + 1] = { id = parentId, kind = kind }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Items QuestieDB believes this quest can reward. Order is not meaningful and the list does
--- not distinguish a choice from a fixed reward - only the live client can say which.
---@param questId number
---@return number[]
function Index.RewardItems(questId)
    questId = QEF.QuestId(questId)
    local bucket = questId and Index.rewardItems[questId]
    if not bucket then return {} end
    local out = {}
    for i = 1, #bucket do out[i] = bucket[i] end
    return out
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Index", function()
    Source = QEF.Source
    if not Source.available then
        QEF.Debug("no QuestieDB - skipping index build, live client data only")
        return
    end
    QEF.RunBudgeted(Build, 6)
end)
