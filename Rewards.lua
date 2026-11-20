-- Rewards.lua
--
-- Resolving what a quest actually gives you, in four tiers, best first:
--
--   1. "giver"   - the quest giver frame that is open right now. Exact, instant, and the only
--                  source that distinguishes a choice from a fixed reward with certainty.
--   2. "learned" - anything tier 1 or 3 established earlier, kept in saved variables.
--   3. "live"    - C_QuestLog.RequestLoadQuestByID for any quest id at all, answered
--                  asynchronously by the server. Exact when it answers; some Forever quests
--                  it never answers for, so it times out rather than hanging a preview.
--   4. "db"      - QuestieDB's item->quest reward relation, inverted by Index.lua, plus its
--                  base XP table. Approximate: it lists the items a quest can reward but not
--                  whether you pick one or get all of them.
--
-- Every tier is optional. With no QuestieDB and no server answer, tier 1 still works, which
-- is the case that matters most: standing in front of the quest giver.

local ADDON, QEF = ...

local Rewards = {}
QEF.Rewards = Rewards

local Source, Index

-- questId -> record
local cache = {}
-- questId -> { state = "pending"|"loaded"|"failed", retryAt = seconds }
local requests = {}

local REQUEST_TIMEOUT = 3
local RETRY_AFTER_FAILURE = 30
local RETRY_AFTER_TIMEOUT = 300

--------------------------------------------------------------------------------------------
-- Compatibility
--------------------------------------------------------------------------------------------

local function Api(name)
    local fn = _G[name]
    return type(fn) == "function" and fn or nil
end

local function ItemIdFromLink(link)
    link = QEF.Str(link)
    if not link then return nil end
    return QEF.Num(tonumber(link:match("item:(%d+)")))
end

--------------------------------------------------------------------------------------------
-- Record shape
--------------------------------------------------------------------------------------------

local function NewRecord(source)
    return {
        source = source,
        choice = {},
        fixed = {},
        xp = nil,
        money = nil,
        -- Whether the choice/fixed split is known rather than guessed.
        exact = false,
        pending = false,
    }
end

local function AddItem(list, itemId, name, icon, quality, count)
    itemId = QEF.Num(itemId)
    if not itemId then return end
    for i = 1, #list do
        if list[i].itemId == itemId then return end
    end
    list[#list + 1] = {
        itemId = itemId,
        name = QEF.Str(name),
        icon = QEF.Num(icon),
        quality = QEF.Num(quality),
        count = QEF.Num(count),
    }
end

--------------------------------------------------------------------------------------------
-- Tier 1: the open quest giver frame
--------------------------------------------------------------------------------------------

--- Read the rewards off whichever quest frame is currently open. Returns nil when nothing is
--- open or the client reports nothing readable.
---@return table? record
function Rewards.ReadOpenFrame()
    local getNumChoices = Api("GetNumQuestChoices")
    local getNumRewards = Api("GetNumQuestRewards")
    local getItemInfo = Api("GetQuestItemInfo")
    local getItemLink = Api("GetQuestItemLink")
    if not getItemInfo then return nil end

    local record = NewRecord("giver")
    record.exact = true

    local function readList(itemType, count, into)
        for index = 1, count do
            local name, icon, numItems, quality, _, itemId = QEF.Try(getItemInfo, itemType, index)
            if not QEF.Num(itemId) and getItemLink then
                itemId = ItemIdFromLink(QEF.Try(getItemLink, itemType, index))
            end
            AddItem(into, itemId, name, icon, quality, numItems)
        end
    end

    local numChoices = QEF.Num(QEF.Try(getNumChoices)) or 0
    local numRewards = QEF.Num(QEF.Try(getNumRewards)) or 0
    readList("choice", numChoices, record.choice)
    readList("reward", numRewards, record.fixed)

    record.xp = QEF.Num(QEF.Try(Api("GetRewardXP")))
    record.money = QEF.Num(QEF.Try(Api("GetRewardMoney")))

    if #record.choice == 0 and #record.fixed == 0 and not record.xp and not record.money then
        return nil
    end
    return record
end

--------------------------------------------------------------------------------------------
-- Tier 2: learned
--------------------------------------------------------------------------------------------

--- Persist what tier 1 or 3 found, so the same quest previews exactly next time even before
--- the server answers. XP is deliberately not persisted: it scales with the player's level,
--- and a stale number is worse than one recomputed from QuestieDB's base table.
function Rewards.Remember(questId, record)
    if not QEF.Get("learn") then return end
    if not record or not record.exact then return end
    if not QEF.learned then return end

    local entry = { c = {}, f = {} }
    for _, item in ipairs(record.choice) do entry.c[#entry.c + 1] = item.itemId end
    for _, item in ipairs(record.fixed) do entry.f[#entry.f + 1] = item.itemId end
    if record.money and record.money > 0 then entry.m = record.money end
    if #entry.c == 0 and #entry.f == 0 and not entry.m then return end

    QEF.learned[questId] = entry
    QEF.Debug("learned rewards for quest", questId,
        "-", #entry.c, "choice,", #entry.f, "fixed")
end

local function FromLearned(questId)
    local entry = QEF.learned and QEF.Tbl(QEF.learned[questId])
    if not entry then return nil end

    local record = NewRecord("learned")
    record.exact = true
    if entry.e then
        -- The server answered and said this quest rewards no items and no money. That is a
        -- real answer, so it must stop the database fallback filling in guesses.
        record.complete = true
        return record
    end
    for _, itemId in ipairs(QEF.Tbl(entry.c) or {}) do AddItem(record.choice, itemId) end
    for _, itemId in ipairs(QEF.Tbl(entry.f) or {}) do AddItem(record.fixed, itemId) end
    record.money = QEF.Num(entry.m)
    return record
end

--------------------------------------------------------------------------------------------
-- Tier 3: ask the server for any quest id
--------------------------------------------------------------------------------------------

--- Read the quest-log reward APIs for a quest the server has already answered for. Public
--- because the sweep harvests with it directly.
---@param questId number
---@return table? record
function Rewards.ReadQuestLog(questId)
    local numRewards = QEF.Num(QEF.Try(Api("GetNumQuestLogRewards"), questId)) or 0
    local numChoices = QEF.Num(QEF.Try(Api("GetNumQuestLogChoices"), questId)) or 0
    local rewardInfo = Api("GetQuestLogRewardInfo")
    local choiceInfo = Api("GetQuestLogChoiceInfo")

    local record = NewRecord("live")
    record.exact = true

    if rewardInfo then
        for index = 1, numRewards do
            local name, icon, count, quality, _, itemId = QEF.Try(rewardInfo, index, questId)
            AddItem(record.fixed, itemId, name, icon, quality, count)
        end
    end
    if choiceInfo then
        for index = 1, numChoices do
            local name, icon, count, quality, _, itemId = QEF.Try(choiceInfo, index, questId)
            AddItem(record.choice, itemId, name, icon, quality, count)
        end
    end

    -- Forever can return a secret or stale value here; QEF.Num drops anything unreadable.
    record.xp = QEF.Num(QEF.Try(Api("GetQuestLogRewardXP"), questId))
    record.money = QEF.Num(QEF.Try(Api("GetQuestLogRewardMoney"), questId))

    if #record.choice == 0 and #record.fixed == 0 and not record.money
        and (not record.xp or record.xp == 0) then
        return nil
    end
    return record
end

--- Ask the server to load a quest. Harmless to call repeatedly; backs off on failure.
---@param questId number
---@param questId number
---@param force boolean? Bypass the lookahead setting and the failure backoff; used by the sweep.
function Rewards.Request(questId, force)
    questId = QEF.QuestId(questId)
    if not questId then return end
    if not force and not QEF.Get("liveLookahead") then return end

    local request = C_QuestLog and C_QuestLog.RequestLoadQuestByID
    if type(request) ~= "function" then return end

    local now = GetTime()
    local existing = requests[questId]
    if existing and not force
        and (existing.state ~= "failed" or now < (existing.retryAt or 0)) then return end

    -- Marked before the call: a quest the client already has answers synchronously, and the
    -- event handler needs to find a pending entry when it does.
    local pending = { state = "pending" }
    requests[questId] = pending

    local ok = pcall(request, questId)
    if not ok then
        requests[questId] = { state = "failed", retryAt = now + RETRY_AFTER_FAILURE }
        return
    end

    C_Timer.After(REQUEST_TIMEOUT, function()
        if requests[questId] == pending and pending.state == "pending" then
            -- Some Forever quests are never answered for. Stop waiting and let the preview
            -- fall through to QuestieDB rather than showing a spinner for ever.
            requests[questId] = { state = "failed", retryAt = GetTime() + RETRY_AFTER_TIMEOUT }
            QEF.Debug("quest data request timed out for", questId)
            Rewards.Invalidate(questId)
            if Rewards.OnUpdate then Rewards.OnUpdate(questId) end
        end
    end)
end

---@param questId number
---@return boolean
function Rewards.IsPending(questId)
    local request = requests[QEF.QuestId(questId) or -1]
    return request ~= nil and request.state == "pending"
end

--------------------------------------------------------------------------------------------
-- Tier 4: QuestieDB
--------------------------------------------------------------------------------------------

local function FromStaticDb(questId)
    local record = NewRecord("db")
    record.exact = false

    for _, itemId in ipairs(Index.RewardItems(questId)) do
        -- Without a choice/fixed split these go in `choice`, and Render labels the block
        -- "possible rewards" rather than claiming you pick one.
        AddItem(record.choice, itemId)
    end
    record.xp = Source.BaseXP(questId)

    if #record.choice == 0 and not record.xp then return nil end
    return record
end

--------------------------------------------------------------------------------------------
-- The resolver
--------------------------------------------------------------------------------------------

--- Fill in anything a better tier did not supply from a worse one, so a learned item list can
--- still pick up XP from QuestieDB.
local function Merge(primary, secondary)
    if not secondary then return primary end
    if not primary then return secondary end
    if not primary.xp then primary.xp = secondary.xp end
    if not primary.money then primary.money = secondary.money end
    if #primary.choice == 0 and #primary.fixed == 0 and not primary.complete then
        primary.choice = secondary.choice
        primary.fixed = secondary.fixed
        primary.exact = secondary.exact
    end
    return primary
end

--- Everything known about a quest's rewards right now. Never blocks: when only the server can
--- answer, the request is started and the best available tier is returned with `pending` set,
--- and Rewards.OnUpdate fires when the answer lands.
---@param questId number
---@param isOpenAtGiver boolean? True when this quest is the one on screen.
---@return table? record
function Rewards.Get(questId, isOpenAtGiver)
    questId = QEF.QuestId(questId)
    if not questId then return nil end

    if isOpenAtGiver then
        local fromFrame = Rewards.ReadOpenFrame()
        if fromFrame then
            Rewards.Remember(questId, fromFrame)
            cache[questId] = fromFrame
            return Merge(fromFrame, FromStaticDb(questId))
        end
    end

    local cached = cache[questId]
    if cached then return cached end

    local record

    local request = requests[questId]
    if request and request.state == "loaded" then
        record = Rewards.ReadQuestLog(questId)
        if record then Rewards.Remember(questId, record) end
    end

    if not record then record = FromLearned(questId) end

    if not record or not record.exact then
        -- Nothing exact yet: ask, and show what QuestieDB knows meanwhile.
        if not request or (request.state == "failed" and GetTime() >= (request.retryAt or 0)) then
            Rewards.Request(questId)
        end
    end

    record = Merge(record, FromStaticDb(questId))
    if record then
        record.pending = Rewards.IsPending(questId)
        -- Only a settled record is worth caching; a pending one must be recomputed.
        if not record.pending then cache[questId] = record end
    end
    return record
end

---@param questId number
function Rewards.Invalidate(questId)
    questId = QEF.QuestId(questId)
    if questId then cache[questId] = nil else cache = {} end
end

--- Set by Render/Tooltip so an answer that arrives late can redraw whatever is on screen.
Rewards.OnUpdate = nil

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Rewards", function()
    Source = QEF.Source
    Index = QEF.Index

    QEF.On("QUEST_DATA_LOAD_RESULT", function(questId, success)
        questId = QEF.QuestId(questId)
        if not questId or not requests[questId] then return end
        if success == false then
            requests[questId] = { state = "failed", retryAt = GetTime() + RETRY_AFTER_FAILURE }
        else
            requests[questId] = { state = "loaded" }
        end
        Rewards.Invalidate(questId)
        if Rewards.OnUpdate then Rewards.OnUpdate(questId) end
    end)

    -- An item whose name/quality was not cached when a preview was drawn.
    QEF.On("GET_ITEM_INFO_RECEIVED", function()
        if Rewards.OnUpdate then Rewards.OnUpdate(nil) end
    end)

    -- Cached records carry an XP figure scaled for the level the player was at when it was
    -- read, so every one of them is wrong the moment they level.
    QEF.On("PLAYER_LEVEL_UP", function()
        Rewards.Invalidate(nil)
        if Rewards.OnUpdate then Rewards.OnUpdate(nil) end
    end)
end)
