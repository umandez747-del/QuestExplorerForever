-- Core.lua
--
-- Namespace, saved variables, event plumbing and the small helpers every other file uses.
--
-- This addon targets the Forever client (Interface 16000-16999), which is a Classic-era
-- ruleset on a modern API base. Two consequences shape most of the code here:
--
--   * values returned by the client may be "secret" (issecretvalue), so anything that comes
--     back from a Blizzard API is passed through Readable() before it is compared, formatted
--     or concatenated;
--   * nearly every API is probed with type() rather than assumed, so the addon degrades to
--     doing less instead of erroring on a client that lacks something.

local ADDON, QEF = ...
_G.QuestExplorerForever = QEF

QEF.addonName = ADDON
QEF.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "1.0.0"

--------------------------------------------------------------------------------------------
-- Client identity
--------------------------------------------------------------------------------------------

local _, buildNumber, _, interfaceVersion = GetBuildInfo()
QEF.buildNumber = buildNumber
QEF.interfaceVersion = interfaceVersion or 0
QEF.isForever = QEF.interfaceVersion >= 16000 and QEF.interfaceVersion < 17000

--------------------------------------------------------------------------------------------
-- Secret values
--------------------------------------------------------------------------------------------

local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable

--- True when a value came back readable, i.e. it is safe to compare, format or concatenate.
--- On clients with no secret-value support everything is readable.
---@param value any
---@return boolean
function QEF.Readable(value)
    if issecretvalue and issecretvalue(value) then return false end
    return true
end

--- A readable number, or nil. The single guard used before any arithmetic on an API result.
---@param value any
---@return number?
function QEF.Num(value)
    if not QEF.Readable(value) then return nil end
    if type(value) ~= "number" then return nil end
    return value
end

--- A readable, non-empty string, or nil.
---@param value any
---@return string?
function QEF.Str(value)
    if not QEF.Readable(value) then return nil end
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

--- A readable, non-secret table, or nil.
---@param value any
---@return table?
function QEF.Tbl(value)
    if not QEF.Readable(value) then return nil end
    if type(value) ~= "table" then return nil end
    if issecrettable and issecrettable(value) then return nil end
    return value
end

--- A readable positive quest id, or nil. Quest ids reach this addon from several APIs and
--- from another addon's data; every one of them goes through here.
---@param value any
---@return number?
function QEF.QuestId(value)
    local id = QEF.Num(value)
    if not id or id <= 0 or id % 1 ~= 0 then return nil end
    return id
end

--- pcall wrapper that returns nil instead of propagating. Used for every Blizzard quest API
--- that is known to be flaky or absent on some builds.
---@param fn any
---@param ... any
---@return ... any
local function unwrap(ok, ...)
    if not ok then return nil end
    return ...
end

function QEF.Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    -- Forwarded through a helper rather than packed into a table: quest APIs return nils in
    -- the middle of their result list, which makes unpack over a packed table lose values.
    return unwrap(pcall(fn, ...))
end

--------------------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------------------

QEF.defaults = {
    enabled = true,
    -- "tooltip" attaches the preview to a tooltip; "panel" opens a side panel beside the
    -- quest giver frame; "both" does each where it fits.
    mode = "tooltip",
    -- 1 brief (name, rewards, chain end), 2 normal, 3 everything the addon knows.
    verbosity = 2,
    showObjectives = true,
    showRewards = true,
    showChain = true,
    showDungeonGate = true,
    showReputation = true,
    showQuestIds = false,
    -- Add the preview to Questie's map and minimap icon tooltips.
    questie = true,
    -- The painted gold corners and the divider under a window title. Off leaves the plain
    -- hairline chrome the addon was built with.
    frameArt = true,
    -- A button on the minimap to open the window. The angle it sits at is saved as you
    -- drag it round the edge.
    minimap = true,
    minimapAngle = 200,
    -- The addon's own pins on the world map, for the checklist's steps and the objectives
    -- of quests on it. "auto" draws them only when Questie is not already drawing its own;
    -- "on" draws them regardless, "off" never does.
    mapPins = "auto",
    -- Pin quests that are not on your checklist as well: the ones you are already
    -- carrying - where to hand them in, what their objectives are - and the ones the open
    -- zone has going spare. Off leaves the map to your own list.
    mapAvailable = true,
    -- Which of the painted pin styles the map wears. The marks carry the meaning; the
    -- style is a preference, except for the guide's own step, which always glows.
    pinStyle = "slate",
    -- Two addons drawing a turn-in over the same NPC is one too many, and the one that
    -- wins is whichever drew last. While ours are on, Blizzard's step aside.
    hideBlizzardPins = true,
    -- What the client's own quest-pin setting was before we touched it, so it can be put
    -- back exactly as found. Saved rather than remembered, because a client that closes
    -- unexpectedly would otherwise leave the player's map permanently changed.
    questPOIWas = false,
    -- Show the panel beside an open quest log, for the quest selected there. Always the
    -- panel, whatever `mode` says: there is nothing to hover in a quest log.
    questLog = true,
    -- Sit the panel flush against the frame it belongs to, sharing its edge, rather than
    -- floating beside it. Dragging the panel detaches it either way.
    panelAttach = true,
    -- Folded away into its tab. Set by the panel's own minimise button and kept, so it
    -- stays folded until you click the tab rather than springing open on the next quest.
    panelMinimised = false,
    -- Ask the server for reward data for quests further along a chain.
    liveLookahead = true,
    -- Remember exact rewards seen at a quest giver, so the next preview is exact too.
    learn = true,
    maxChainDepth = 12,
    -- Group the browser's results into their chains, each quest indented under the one it
    -- follows. Off gives a flat list ordered by quest level.
    chainOrder = true,
    -- "auto" turns the controller layout on only when a pad is connected, so a keyboard
    -- player never meets it. "on" forces it, "off" keeps it away.
    controller = "auto",
    -- Which family of face-button names the hint bar prints.
    controllerLabels = "xbox",
    maxRewardLines = 6,
    -- Quest-data requests per second during a sweep. Low on purpose: this talks to the
    -- server, and there is no hurry.
    sweepRate = 8,
    -- Show the floating progress strip while a sweep runs with the window closed.
    sweepToast = true,
    -- Directions to a quest giver on another continent.
    showTravel = true,
    -- Show those directions in a pop-out window when a waypoint is set. Off sends them to
    -- chat instead, which is where they used to go.
    routeWindow = true,
    -- Show the dungeon checklist beside the game world while it has anything on it. Off
    -- keeps the list but stops it appearing; /qef tracker brings it back.
    tracker = true,
    -- Name the quest giver and zone under each tracker line. Off leaves just the names,
    -- for a player who only wants the tally.
    trackerSteps = true,
    -- Where the tracker sits, saved as it is dragged: { point, x, y }.
    trackerPoint = nil,
    -- Point the game's own marker at the checklist step you are on, and move it to the
    -- next one when that step is done.
    guide = true,
    -- Order the steps in the zone you are standing in as a walk - nearest first, then
    -- nearest to that - instead of by what kind of step they are.
    walkOrder = true,
    debug = false,
}

--- Settings live here after ADDON_LOADED; until then reads fall back to the defaults.
QEF.db = nil

---@param key string
---@return any
function QEF.Get(key)
    local db = QEF.db
    if db and db[key] ~= nil then return db[key] end
    return QEF.defaults[key]
end

---@param key string
---@param value any
function QEF.Set(key, value)
    if QEF.db then QEF.db[key] = value end
end

--------------------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------------------

local PREFIX = "|cfff2c75bQuest Explorer|r: "

function QEF.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = QEF.Readable(v) and tostring(v) or "<secret>"
    end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. table.concat(parts, " "))
end

--- Debug output, off unless /qef debug on.
function QEF.Debug(...)
    if not QEF.Get("debug") then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = QEF.Readable(v) and tostring(v) or "<secret>"
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888QP|r " .. table.concat(parts, " "))
end

--------------------------------------------------------------------------------------------
-- Colours and formatting
--------------------------------------------------------------------------------------------

QEF.color = {
    header   = "|cffffd100",
    label    = "|cff9d9d9d",
    text     = "|cffffffff",
    good     = "|cff40c040",
    warn     = "|cffff8040",
    chain    = "|cff66ccff",
    dungeon  = "|cffff6060",
    money    = "|cffffcc33",
    xp       = "|cffa335ee",
    rep      = "|cff00c0c0",
}

local GOLD = "|cffffd700g|r"
local SILVER = "|cffc7c7cfs|r"
local COPPER = "|cffeda55fc|r"

--- Copper to a short "12g 34s" string. Zero returns nil so callers can omit the line.
---@param copper number?
---@return string?
function QEF.Money(copper)
    copper = QEF.Num(copper)
    if not copper or copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. GOLD end
    if s > 0 then out[#out + 1] = s .. SILVER end
    if c > 0 and g == 0 then out[#out + 1] = c .. COPPER end
    return table.concat(out, " ")
end

--- 12345 -> "12,345".
---@param value number?
---@return string?
function QEF.Comma(value)
    value = QEF.Num(value)
    if not value then return nil end
    local s = tostring(math.floor(value))
    while true do
        local replaced
        s, replaced = s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then break end
    end
    return s
end

--- Clip a string to a length, on a word boundary where there is one nearby.
---@param text string?
---@param limit number
---@return string?
function QEF.Clip(text, limit)
    text = QEF.Str(text)
    if not text then return nil end
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #text <= limit then return text end
    local cut = text:sub(1, limit)
    local space = cut:find("%s[^%s]*$")
    if space and space > limit * 0.6 then cut = cut:sub(1, space - 1) end
    return cut .. "..."
end

--------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "QuestExplorerForeverEventFrame")
QEF.frame = frame

local handlers = {}

--- Register a handler. Events the client does not have are skipped rather than erroring.
---@param event string
---@param fn function
function QEF.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            handlers[event] = nil
            QEF.Debug("event not available on this client:", event)
            return
        end
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end)

--------------------------------------------------------------------------------------------
-- Frame budgeted work
--------------------------------------------------------------------------------------------

local workers = {}
local worker = CreateFrame("Frame")
worker:Hide()

--- Run a coroutine a few milliseconds per frame. Used for the one-off index build so a login
--- never stutters, however slow the metadata store turns out to be on a given machine.
---@param fn function
---@param budgetMs number?
function QEF.RunBudgeted(fn, budgetMs)
    local co = coroutine.create(fn)
    workers[#workers + 1] = { co = co, budget = budgetMs or 6 }
    worker:Show()
end

worker:SetScript("OnUpdate", function()
    local i = 1
    while i <= #workers do
        local job = workers[i]
        local started = debugprofilestop()
        local alive = true
        while alive and debugprofilestop() - started < job.budget do
            local ok, err = coroutine.resume(job.co)
            if not ok then
                QEF.Print("|cffff4040error|r in background work:", err)
                alive = false
            elseif coroutine.status(job.co) == "dead" then
                alive = false
            end
        end
        if alive then
            i = i + 1
        else
            table.remove(workers, i)
        end
    end
    if #workers == 0 then worker:Hide() end
end)

--- Yield from inside a budgeted job. The OnUpdate loop decides when to stop for the frame.
function QEF.Yield()
    coroutine.yield()
end

--------------------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------------------

QEF.modules = {}

--- Modules register an Init to run once saved variables exist and the other addons have had
--- their chance to load.
---@param name string
---@param fn function
function QEF.RegisterInit(name, fn)
    table.insert(QEF.modules, { name = name, fn = fn })
end

local started = false

local function Start()
    if started then return end
    started = true
    for _, module in ipairs(QEF.modules) do
        local ok, err = pcall(module.fn)
        if not ok then
            QEF.Print("|cffff4040error|r initialising", module.name .. ":", err)
        end
    end
    QEF.Debug("started, interface", QEF.interfaceVersion, "forever:", tostring(QEF.isForever))
end

--- Settings, learned rewards and checklists written under the addon's old name.
--- The addon was called QuestPreview until 2.0.0; renaming it gave the game a new saved
--- variables file, so the old table is declared in the .toc alongside the new one and
--- adopted whole the first time it is seen. Only ever when the new table is untouched -
--- a merge would be guesswork about which copy is current - and it is cleared afterwards
--- so the old name does not get written back out forever.
---@return boolean migrated
local function AdoptOldSavedVariables()
    local old = QuestPreviewDB
    if type(old) ~= "table" or next(old) == nil then return false end
    if type(QuestExplorerForeverDB) == "table" and next(QuestExplorerForeverDB) ~= nil then
        QuestPreviewDB = nil
        return false
    end

    QuestExplorerForeverDB = old
    QuestPreviewDB = nil
    return true
end

QEF.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end

    local migrated = AdoptOldSavedVariables()

    QuestExplorerForeverDB = QuestExplorerForeverDB or {}
    QuestExplorerForeverDB.settings = QuestExplorerForeverDB.settings or {}
    -- Exact rewards seen at a quest giver, so a later preview of the same quest is exact.
    QuestExplorerForeverDB.learned = QuestExplorerForeverDB.learned or {}
    -- Dungeon checklists, keyed by character: what one character still has to go and pick
    -- up says nothing about the others on the account.
    QuestExplorerForeverDB.checklists = QuestExplorerForeverDB.checklists or {}
    QEF.db = QuestExplorerForeverDB.settings
    QEF.learned = QuestExplorerForeverDB.learned
    QEF.checklists = QuestExplorerForeverDB.checklists

    for key, value in pairs(QEF.defaults) do
        if QEF.db[key] == nil then QEF.db[key] = value end
    end

    if migrated then
        -- Said at login rather than left silent: a rename that quietly lost your settings
        -- and a rename that kept them look identical until you go looking.
        QEF.migratedFromQuestPreview = true
    end
end)

QEF.On("PLAYER_LOGIN", Start)
