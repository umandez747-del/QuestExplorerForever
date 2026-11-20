-- Sweep.lua
--
-- Builds a complete local reward database by asking the server about every quest id
-- QuestieDB knows, one controlled trickle at a time.
--
-- This is the honest alternative to scraping a quest site: the answers come from the server
-- you actually play on, so Forever's own changed and added quests are correct rather than
-- confidently wrong. What it cannot learn is the handful of quests the server declines to
-- answer for at all; those are counted and reported rather than guessed at.
--
-- The sweep is deliberately unhurried and interruptible:
--   * a configurable rate, defaulting to a few requests a second;
--   * a cap on how many are in flight at once;
--   * paused automatically in combat;
--   * the cursor is saved, so a sweep survives a reload, a logout, or a disconnect;
--   * quests already known are skipped, so re-running it only fills gaps.

local ADDON, QEF = ...

local Sweep = {}
QEF.Sweep = Sweep

local Source, Rewards

local REQUEST_LIFETIME = 5      -- seconds before an unanswered request is written off
local TICK = 0.2                -- seconds between batches

Sweep.state = {
    running = false,
    cursor = 0,
    total = 0,
    found = 0,       -- answered with rewards
    empty = 0,       -- answered, but the quest rewards no items or money
    missing = 0,     -- never answered
    skipped = 0,     -- already known before this run
    startedAt = nil,
    lastMilestone = 0,
}

local ids = {}
local pending = {}
local pendingCount = 0
local ticker

--- Fired on every tick and on every state change, for the window and the progress toast.
Sweep.OnProgress = nil

local function Notify()
    if Sweep.OnProgress then Sweep.OnProgress(Sweep.state) end
end

--------------------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------------------

local function Store()
    QuestExplorerForeverDB.sweep = QuestExplorerForeverDB.sweep or {}
    return QuestExplorerForeverDB.sweep
end

--- The cursor is only meaningful against the QuestieDB build it was taken from: a different
--- build can have a different id list, so a stale cursor would skip real quests.
local function StoredCursor()
    local store = Store()
    if store.build ~= (Source.buildCommit or "unknown") then return 0 end
    return QEF.Num(store.cursor) or 0
end

local function SaveCursor()
    local store = Store()
    store.build = Source.buildCommit or "unknown"
    store.cursor = Sweep.state.cursor
    store.found = Sweep.state.found
    store.empty = Sweep.state.empty
    store.missing = Sweep.state.missing
    store.completedAt = Sweep.state.completedAt
end

--------------------------------------------------------------------------------------------
-- Harvesting
--------------------------------------------------------------------------------------------

--- Whether this quest already has an exact, remembered answer.
local function AlreadyKnown(questId)
    local entry = QEF.learned and QEF.learned[questId]
    return entry ~= nil
end

--- Record what the server said. An answer of "nothing" is itself worth storing: it means the
--- quest rewards only experience, and it stops the addon guessing from QuestieDB for ever.
local function Harvest(questId)
    local record = Rewards.ReadQuestLog(questId)
    if record and (#record.choice > 0 or #record.fixed > 0 or (record.money or 0) > 0) then
        Rewards.Remember(questId, record)
        Sweep.state.found = Sweep.state.found + 1
    else
        QEF.learned[questId] = { e = true }
        Sweep.state.empty = Sweep.state.empty + 1
    end
    Rewards.Invalidate(questId)
end

--------------------------------------------------------------------------------------------
-- The pacer
--------------------------------------------------------------------------------------------

local function Retire(questId)
    if pending[questId] == nil then return false end
    pending[questId] = nil
    pendingCount = pendingCount - 1
    return true
end

local function Milestone()
    local state = Sweep.state
    if state.total == 0 then return end
    local percent = math.floor(state.cursor / state.total * 100)
    local step = percent - (percent % 25)
    if step > state.lastMilestone and step > 0 then
        state.lastMilestone = step
        QEF.Print(("sweep %d%% - %s quests with rewards learned so far"):format(
            step, QEF.Comma(state.found) or state.found))
    end
end

local function Tick()
    local state = Sweep.state
    if not state.running then return end

    -- Nothing this addon does is worth a single frame of a fight.
    if InCombatLockdown() then return end

    local now = GetTime()
    for questId, issuedAt in pairs(pending) do
        if now - issuedAt > REQUEST_LIFETIME then
            Retire(questId)
            state.missing = state.missing + 1
        end
    end

    local perTick = math.max(1, math.floor((QEF.Num(QEF.Get("sweepRate")) or 8) * TICK + 0.5))
    local maxInFlight = math.max(2, perTick * 3)
    local issued = 0

    while issued < perTick and pendingCount < maxInFlight and state.cursor < state.total do
        state.cursor = state.cursor + 1
        local questId = ids[state.cursor]
        if questId then
            if AlreadyKnown(questId) then
                state.skipped = state.skipped + 1
            else
                pending[questId] = now
                pendingCount = pendingCount + 1
                Rewards.Request(questId, true)
                issued = issued + 1
            end
        end
    end

    Milestone()
    SaveCursor()
    Notify()

    if state.cursor >= state.total and pendingCount == 0 then
        Sweep.Finish()
    end
end

--------------------------------------------------------------------------------------------
-- Control
--------------------------------------------------------------------------------------------

---@return boolean started
---@return string? reason
function Sweep.Start(restart)
    if Sweep.state.running then return false, "already running" end
    if not Source.available then
        return false, "QuestieDB is not loaded, so there is no quest id list to sweep"
    end
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.RequestLoadQuestByID) ~= "function" then
        return false, "this client cannot load quest data on request"
    end

    ids = Source.AllIds("Quest")
    if #ids == 0 then return false, "QuestieDB returned no quest ids" end

    local state = Sweep.state
    state.total = #ids
    if restart then
        state.cursor = 0
        state.found, state.empty, state.missing, state.skipped = 0, 0, 0, 0
        state.lastMilestone = 0
        state.completedAt = nil
    else
        state.cursor = math.min(StoredCursor(), state.total)
        local store = Store()
        state.found = QEF.Num(store.found) or state.found
        state.empty = QEF.Num(store.empty) or state.empty
        state.missing = QEF.Num(store.missing) or state.missing
        state.lastMilestone = state.total > 0
            and math.floor(state.cursor / state.total * 100 / 25) * 25 or 0
    end

    state.running = true
    state.startedAt = GetTime()
    wipe(pending)
    pendingCount = 0

    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(TICK, Tick)
    Notify()
    return true
end

function Sweep.Pause()
    if not Sweep.state.running then return false end
    Sweep.state.running = false
    if ticker then ticker:Cancel() ticker = nil end
    SaveCursor()
    Notify()
    return true
end

function Sweep.Finish()
    Sweep.state.running = false
    Sweep.state.completedAt = time()
    if ticker then ticker:Cancel() ticker = nil end
    SaveCursor()
    Notify()
    QEF.Print(("sweep complete - %s quests with rewards, %s with none, %s the server would not answer for"):format(
        QEF.Comma(Sweep.state.found) or 0,
        QEF.Comma(Sweep.state.empty) or 0,
        QEF.Comma(Sweep.state.missing) or 0))
end

--- Throw away everything the sweep learned, and the cursor with it.
function Sweep.Reset()
    Sweep.Pause()
    local cleared = 0
    for questId in pairs(QEF.learned or {}) do
        QEF.learned[questId] = nil
        cleared = cleared + 1
    end
    QuestExplorerForeverDB.sweep = nil
    local state = Sweep.state
    state.cursor, state.found, state.empty, state.missing, state.skipped = 0, 0, 0, 0, 0
    state.lastMilestone = 0
    state.completedAt = nil
    Rewards.Invalidate(nil)
    Notify()
    return cleared
end

--------------------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------------------

---@return number percent 0-100
function Sweep.Percent()
    local state = Sweep.state
    if state.total == 0 then return 0 end
    return math.min(100, state.cursor / state.total * 100)
end

--- Seconds remaining at the current rate, or nil when it cannot be estimated yet.
---@return number?
function Sweep.Remaining()
    local state = Sweep.state
    if not state.running or not state.startedAt then return nil end
    local done = state.cursor
    local elapsed = GetTime() - state.startedAt
    if elapsed < 2 or done <= 0 then return nil end
    local rate = done / elapsed
    if rate <= 0 then return nil end
    return (state.total - done) / rate
end

--- How many quests the local database has an exact answer for.
---@return number known
---@return number withRewards
function Sweep.Coverage()
    local known, withRewards = 0, 0
    for _, entry in pairs(QEF.learned or {}) do
        known = known + 1
        if not entry.e then withRewards = withRewards + 1 end
    end
    return known, withRewards
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Sweep", function()
    Source = QEF.Source
    Rewards = QEF.Rewards

    -- Runs after Rewards' own handler, which has already marked the request loaded, so the
    -- quest log API is ready to read by the time this fires.
    QEF.On("QUEST_DATA_LOAD_RESULT", function(questId, success)
        questId = QEF.QuestId(questId)
        if not questId then return end
        if not Retire(questId) then return end

        if success == false then
            Sweep.state.missing = Sweep.state.missing + 1
        else
            Harvest(questId)
        end
    end)

    -- Picking a sweep back up after a reload is the player's call, not the addon's, but the
    -- counters should still read correctly in the window before they press anything.
    local store = Store()
    if store and store.build == (Source.buildCommit or "unknown") then
        local state = Sweep.state
        state.cursor = QEF.Num(store.cursor) or 0
        state.found = QEF.Num(store.found) or 0
        state.empty = QEF.Num(store.empty) or 0
        state.missing = QEF.Num(store.missing) or 0
        state.completedAt = store.completedAt
        state.total = #Source.AllIds("Quest")
    end

    QEF.On("PLAYER_REGEN_ENABLED", function()
        if Sweep.state.running then Notify() end
    end)
end)
