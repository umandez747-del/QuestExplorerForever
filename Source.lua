-- Source.lua
--
-- The static-data layer: everything Quest Explorer reads out of QuestieDB, behind guards so the
-- addon still loads and still does its live-client half when QuestieDB is absent.
--
-- QuestieDB is a separate addon from Questie. It publishes the globals LibQuestieDB, QuestDB,
-- NpcDB, ItemDB and ObjectDB, and it does not need Questie itself to be loaded. Everything
-- here is addressed by field *name* rather than index, because the names are the stable part
-- of its contract.

local ADDON, QEF = ...

local Source = {}
QEF.Source = Source

Source.available = false
Source.questieAvailable = false
Source.readMode = nil
Source.buildCommit = nil
Source.flavor = nil
Source.contractNote = nil

-- The field names this addon reads. Kept here so /qef debug can dump exactly these.
Source.questFields = {
    "name", "startedBy", "finishedBy", "requiredLevel", "questLevel",
    "requiredRaces", "requiredClasses", "objectivesText", "objectives",
    "sourceItemId", "preQuestGroup", "preQuestSingle", "childQuests",
    "inGroupWith", "exclusiveTo", "zoneOrSort", "requiredSkill",
    "requiredMinRep", "requiredSourceItems", "nextQuestInChain", "questFlags",
    "specialFlags", "parentQuest", "reputationReward", "breadcrumbForQuestId",
    "breadcrumbs", "requiredSpell", "availableStartingWith",
}

--------------------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------------------

local lib, QuestDB, ItemDB, NpcDB

-- Forward declarations: Source.Init calls these, and they are defined further down beside
-- the faction and zone helpers that own them.
local BuildFactionNames, BuildZoneNames, Prettify

--- Dungeon area ids, including each dungeon's alternative ids, mapped to its display name.
Source.dungeonByArea = {}
--- Base quest XP table: questId -> {level, xp}
Source.xpDB = nil

local function BuildDungeonIndex()
    local zoneSupport = lib and lib.Support and lib.Support.Get and lib.Support.Get("ZoneDB")
    local private = zoneSupport and QEF.Tbl(zoneSupport.private)
    local dungeons = private and QEF.Tbl(private.dungeons)
    if not dungeons then
        QEF.Debug("no dungeon table in QuestieDB support data")
        return
    end

    local count = 0
    for areaId, entry in pairs(dungeons) do
        local name = QEF.Str(entry and entry[1])
        if name then
            Source.dungeonByArea[areaId] = name
            count = count + 1
            local alternatives = QEF.Tbl(entry[2])
            if alternatives then
                for _, altId in ipairs(alternatives) do
                    if QEF.Num(altId) then Source.dungeonByArea[altId] = name end
                end
            end
        end
    end
    QEF.Debug("indexed", count, "dungeons")
end

function Source.Init()
    lib = _G.LibQuestieDB
    Source.questieAvailable = _G.QuestieLoader ~= nil and _G.Questie ~= nil

    if not lib then
        QEF.Debug("QuestieDB not loaded - static quest data unavailable")
        return
    end

    QuestDB = _G.QuestDB
    ItemDB = _G.ItemDB
    NpcDB = _G.NpcDB

    if type(QuestDB) ~= "table" or type(QuestDB.Get) ~= "function" then
        QEF.Debug("QuestieDB present but QuestDB is not usable")
        return
    end

    -- A range check, not an equality check: QuestieDB keeps older consumers working. If it
    -- fails we carry on anyway, because every read here is by field name, and say so in
    -- /qef debug rather than silently behaving differently.
    if type(lib.RequireContract) == "function" then
        local ok, message = lib.RequireContract(4)
        if not ok then
            Source.contractNote = message or "contract check failed"
            QEF.Debug("QuestieDB contract note:", Source.contractNote)
        end
    end

    Source.readMode = QEF.Str(lib.readMode)
    Source.flavor = lib.flavor and QEF.Str(lib.flavor.name)
    Source.buildCommit = QEF.Str(QEF.Try(C_AddOns and C_AddOns.GetAddOnMetadata, "QuestieDB", "X-BUILD-COMMIT"))

    local xpSupport = lib.Support and lib.Support.Get and lib.Support.Get("QuestXP")
    Source.xpDB = xpSupport and QEF.Tbl(xpSupport.db) or nil

    BuildDungeonIndex()
    BuildFactionNames()
    BuildZoneNames()

    Source.available = true
    QEF.Debug("QuestieDB ready - mode", Source.readMode, "flavor", Source.flavor)
end

--------------------------------------------------------------------------------------------
-- Quest reads
--------------------------------------------------------------------------------------------

--- One quest field, or nil. Safe to call when QuestieDB is absent.
---@param questId number
---@param key string
---@return any
function Source.Quest(questId, key)
    if not Source.available then return nil end
    questId = QEF.QuestId(questId)
    if not questId then return nil end
    return QEF.Try(QuestDB.Get, questId, key)
end

---@param questId number
---@return boolean
function Source.QuestExists(questId)
    if not Source.available then return false end
    questId = QEF.QuestId(questId)
    if not questId then return false end
    return QEF.Try(QuestDB.Exists, questId) == true
end

--- A quest's name from the static DB.
---@param questId number
---@return string?
function Source.QuestName(questId)
    return QEF.Str(Source.Quest(questId, "name"))
end

--- Quest level and required level, either of which may be nil.
---@param questId number
---@return number? questLevel
---@return number? requiredLevel
function Source.QuestLevels(questId)
    local level = QEF.Num(Source.Quest(questId, "questLevel"))
    local required = QEF.Num(Source.Quest(questId, "requiredLevel"))
    if level and level <= 0 then level = nil end
    if required and required <= 0 then required = nil end
    return level, required
end

--- The quest's objective lines, as a plain list of strings.
---@param questId number
---@return string[]
function Source.Objectives(questId)
    local out = {}
    local text = QEF.Tbl(Source.Quest(questId, "objectivesText"))
    if text then
        for _, line in ipairs(text) do
            local clean = QEF.Str(line)
            if clean then out[#out + 1] = clean end
        end
    end
    return out
end

--------------------------------------------------------------------------------------------
-- Faction names
--------------------------------------------------------------------------------------------

-- factionId -> name, built from QuestieDB's own constant table. Only a fallback: it is used
-- when the client cannot name a faction, which it cannot do for one the player has never
-- encountered.
Source.factionNameById = {}

local SMALL_WORDS = { ["of"] = true, ["the"] = true, ["and"] = true }

--- "GNOMEREGAN_EXILES" -> "Gnomeregan Exiles"
function Prettify(constantName)
    local words = {}
    for word in constantName:gmatch("[^_]+") do
        word = word:lower()
        if #words > 0 and SMALL_WORDS[word] then
            words[#words + 1] = word
        else
            words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
        end
    end
    return table.concat(words, " ")
end

function BuildFactionNames()
    local enum = lib and QEF.Tbl(lib.Enum)
    local factionIds = enum and QEF.Tbl(enum.factionIDs)
    if not factionIds then return end
    for constantName, factionId in pairs(factionIds) do
        if QEF.Num(factionId) and type(constantName) == "string" then
            Source.factionNameById[factionId] = Prettify(constantName)
        end
    end
end

--- The display name of a faction. The client is asked first, because it is localised and
--- authoritative; it returns nothing for factions the player has not met yet.
---@param factionId number
---@return string?
function Source.FactionName(factionId)
    factionId = QEF.Num(factionId)
    if not factionId then return nil end

    if C_Reputation and C_Reputation.GetFactionDataByID then
        local data = QEF.Tbl(QEF.Try(C_Reputation.GetFactionDataByID, factionId))
        local name = data and QEF.Str(data.name)
        if name then return name end
    end

    -- Pre-C_Reputation clients.
    local legacy = QEF.Str(QEF.Try(_G.GetFactionInfoByID, factionId))
    if legacy then return legacy end

    return Source.factionNameById[factionId]
end

--- Reputation rewards as a list of {factionId, value}.
---@param questId number
---@return table[]
function Source.ReputationRewards(questId)
    local out = {}
    local rewards = QEF.Tbl(Source.Quest(questId, "reputationReward"))
    if not rewards then return out end
    for _, pair in ipairs(rewards) do
        local factionId = QEF.Num(pair and pair[1])
        local value = QEF.Num(pair and pair[2])
        if factionId and value and value ~= 0 then
            out[#out + 1] = { factionId = factionId, value = value }
        end
    end
    return out
end

--- Base XP for a quest from QuestieDB's support table, scaled for the player's level with the
--- same cmangos formula Questie uses. Returns nil when the quest is not in the table.
---@param questId number
---@param ignorePlayerLevel boolean?
---@return number?
function Source.BaseXP(questId, ignorePlayerLevel)
    local db = Source.xpDB
    if not db then return nil end
    questId = QEF.QuestId(questId)
    if not questId then return nil end
    local entry = QEF.Tbl(db[questId])
    if not entry then return nil end

    local questLevel = QEF.Num(entry[1])
    local xp = QEF.Num(entry[2])
    if not questLevel or not xp or questLevel <= 0 or xp <= 0 then return nil end

    local playerLevel = QEF.Num(UnitLevel("player")) or questLevel
    local maxLevel = QEF.Num(QEF.Try(GetMaxPlayerLevel))
    if maxLevel and playerLevel >= maxLevel and not ignorePlayerLevel then return 0 end

    local multiplier = 2 * (questLevel - playerLevel) + 20
    if multiplier < 1 then multiplier = 1 elseif multiplier > 10 then multiplier = 10 end
    xp = xp * multiplier / 10

    if xp <= 100 then
        xp = 5 * math.floor((xp + 2) / 5)
    elseif xp <= 500 then
        xp = 10 * math.floor((xp + 5) / 10)
    elseif xp <= 1000 then
        xp = 25 * math.floor((xp + 12) / 25)
    else
        xp = 50 * math.floor((xp + 25) / 50)
    end
    return math.floor(xp)
end

--------------------------------------------------------------------------------------------
-- Dungeon gating
--------------------------------------------------------------------------------------------

--- The dungeon a quest belongs to, by its zoneOrSort, or nil.
--- A positive zoneOrSort is an AreaTable id; dungeons have several of those, which
--- BuildDungeonIndex has already flattened.
---@param questId number
---@return string? dungeonName
function Source.DungeonOf(questId)
    local zoneOrSort = QEF.Num(Source.Quest(questId, "zoneOrSort"))
    if not zoneOrSort or zoneOrSort <= 0 then return nil end
    return Source.dungeonByArea[zoneOrSort]
end

-- areaId -> name, inverted from QuestieDB's zone constants. Used only when the client cannot
-- name an area, which it cannot do for instance sub-areas on some builds.
Source.zoneNameById = {}

function BuildZoneNames()
    local enum = lib and QEF.Tbl(lib.Enum)
    local zoneIds = enum and QEF.Tbl(enum.zoneIDs)
    if not zoneIds then return end
    for constantName, areaId in pairs(zoneIds) do
        if QEF.Num(areaId) and type(constantName) == "string" then
            Source.zoneNameById[areaId] = Prettify(constantName)
        end
    end
end

--- The display name for a quest's zoneOrSort. A positive value is an AreaTable id; a negative
--- one is a QuestSort, which groups class and profession quests rather than naming a place.
---@param zoneOrSort number?
---@return string? name
---@return boolean isDungeon
function Source.ZoneName(zoneOrSort)
    zoneOrSort = QEF.Num(zoneOrSort)
    if not zoneOrSort or zoneOrSort == 0 then return nil, false end

    if zoneOrSort < 0 then
        return "Class & profession", false
    end

    local dungeon = Source.dungeonByArea[zoneOrSort]
    if dungeon then return dungeon, true end

    if C_Map and C_Map.GetAreaInfo then
        local name = QEF.Str(QEF.Try(C_Map.GetAreaInfo, zoneOrSort))
        if name then return name, false end
    end
    local legacy = QEF.Str(QEF.Try(_G.GetAreaInfo, zoneOrSort))
    if legacy then return legacy, false end

    return Source.zoneNameById[zoneOrSort], false
end

--------------------------------------------------------------------------------------------
-- Faction
--------------------------------------------------------------------------------------------

local band = bit and bit.band

--- Which faction can take a quest, from its allowed-race bitmask.
--- A mask of zero means no restriction, and a mask covering races on both sides means the
--- quest is shared, so both of those report nil rather than claiming a side.
---@param questId number
---@return string? faction "Alliance", "Horde", or nil when either can take it
function Source.QuestFaction(questId)
    if not Source.available or not band then return nil end
    local races = QEF.Num(Source.Quest(questId, "requiredRaces"))
    if not races or races == 0 then return nil end

    local enum = QEF.Tbl(lib and lib.Enum)
    local masks = enum and QEF.Tbl(enum.factionRaceMasks)
    if not masks then return nil end

    local alliance = QEF.Num(masks.Alliance)
    local horde = QEF.Num(masks.Horde)
    if not alliance or not horde then return nil end

    local isAlliance = band(races, alliance) > 0
    local isHorde = band(races, horde) > 0
    if isAlliance and isHorde then return nil end
    if isAlliance then return "Alliance" end
    if isHorde then return "Horde" end
    return nil
end

--------------------------------------------------------------------------------------------
-- Quest status
--------------------------------------------------------------------------------------------

-- The client knows what you have completed, but asking it per quest while drawing a chain of
-- forty is wasteful, so the completed set is pulled once and refreshed on the events that can
-- change it. Questie keeps its own completion record because the client API has historically
-- been unreliable for very old quests; when it is loaded, the two are merged.
local completedSet
local completedStale = true

local function RefreshCompleted()
    completedSet = {}
    completedStale = false

    local all = QEF.Tbl(QEF.Try(C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs))
    if all then
        for _, questId in ipairs(all) do
            questId = QEF.QuestId(questId)
            if questId then completedSet[questId] = true end
        end
    end

    local questie = _G.Questie
    local char = questie and QEF.Tbl(questie.db) and QEF.Tbl(questie.db.char)
    local questieComplete = char and QEF.Tbl(char.complete)
    if questieComplete then
        for questId, value in pairs(questieComplete) do
            if value and QEF.QuestId(questId) then completedSet[questId] = true end
        end
    end
end

function Source.InvalidateStatus()
    completedStale = true
end

---@param questId number
---@return boolean
function Source.IsCompleted(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    if completedStale or not completedSet then RefreshCompleted() end
    if completedSet[questId] then return true end
    -- A quest the bulk list missed is still worth one direct ask.
    return QEF.Try(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, questId) == true
end

---@param questId number
---@return number? logIndex
local function LogIndex(questId)
    return QEF.Num(QEF.Try(C_QuestLog and C_QuestLog.GetLogIndexForQuestID, questId))
end

--- Whether every prerequisite of a quest is satisfied.
---@param questId number
---@return boolean satisfied
local function PrerequisitesMet(questId)
    -- preQuestSingle: any one of them is enough.
    local single = QEF.Tbl(Source.Quest(questId, "preQuestSingle"))
    if single and #single > 0 then
        local any = false
        for _, prerequisiteId in ipairs(single) do
            if Source.IsCompleted(prerequisiteId) then any = true break end
        end
        if not any then return false end
    end

    -- preQuestGroup: all of them are required.
    local group = QEF.Tbl(Source.Quest(questId, "preQuestGroup"))
    if group then
        for _, prerequisiteId in ipairs(group) do
            if not Source.IsCompleted(prerequisiteId) then return false end
        end
    end

    return true
end

--- What state a quest is in for this character.
--- One of: "completed", "ready", "active", "available", "locked", "faction".
---@param questId number
---@return string status
function Source.QuestStatus(questId)
    questId = QEF.QuestId(questId)
    if not questId then return "available" end

    local logIndex = LogIndex(questId)
    if logIndex then
        if QEF.Try(C_QuestLog and C_QuestLog.IsComplete, questId) == true then return "ready" end
        return "active"
    end

    if Source.IsCompleted(questId) then return "completed" end

    if Source.available then
        local faction = Source.QuestFaction(questId)
        if faction then
            local player = QEF.Str(QEF.Try(UnitFactionGroup, "player"))
            if player and player ~= faction then return "faction" end
        end
        if not PrerequisitesMet(questId) then return "locked" end
    end

    return "available"
end

--------------------------------------------------------------------------------------------
-- Area to map
--------------------------------------------------------------------------------------------

-- QuestieDB ships these mappings as Lua source strings rather than tables, because Questie
-- decodes them once at startup. Questie's ZoneDB is preferred when it is loaded; otherwise
-- the same strings are decoded here, once, on first use.
local areaToUiMap

local function DecodeMapping(value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" then return nil end
    local chunk = loadstring(value)
    if not chunk then return nil end
    local ok, decoded = pcall(chunk)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function BuildAreaToUiMap()
    areaToUiMap = {}
    local zoneSupport = lib and lib.Support and lib.Support.Get and lib.Support.Get("ZoneDB")
    local private = zoneSupport and QEF.Tbl(zoneSupport.private)
    if not private then return end

    local base = DecodeMapping(private.areaIdToUiMapId)
    if base then
        for areaId, uiMapId in pairs(base) do areaToUiMap[areaId] = uiMapId end
    end
    -- Overrides are Questie's display policy and win over the raw relationships.
    local override = DecodeMapping(private.areaIdToUiMapIdOverride)
    if override then
        for areaId, uiMapId in pairs(override) do areaToUiMap[areaId] = uiMapId end
    end
    QEF.Debug("decoded area to map mapping")
end

--- The UI map a quest area belongs to, for placing a waypoint.
---@param areaId number
---@return number? uiMapId
function Source.UiMapIdForArea(areaId)
    areaId = QEF.Num(areaId)
    if not areaId then return nil end

    if _G.QuestieLoader then
        local ZoneDB = QEF.Try(_G.QuestieLoader.ImportModule, _G.QuestieLoader, "ZoneDB")
        if type(ZoneDB) == "table" and type(ZoneDB.GetUiMapIdByAreaId) == "function" then
            local uiMapId = QEF.Num(QEF.Try(ZoneDB.GetUiMapIdByAreaId, ZoneDB, areaId))
            if uiMapId and uiMapId > 0 then return uiMapId end
        end
    end

    if not areaToUiMap then BuildAreaToUiMap() end
    local uiMapId = QEF.Num(areaToUiMap[areaId])
    if uiMapId and uiMapId > 0 then return uiMapId end
    return nil
end

--------------------------------------------------------------------------------------------
-- Quest starters
--------------------------------------------------------------------------------------------

--- The first of these NPCs that is worth pointing at: a name, and a spawn point when one is
--- recorded. Shared by the quest's start and its turn-in, which are the same lookup against
--- different id lists.
---@param npcIds table?
---@return table? place { npcId, name, areaId, uiMapId, x, y, zoneName }
local function FirstNpcPlace(npcIds)
    npcIds = QEF.Tbl(npcIds)
    if not npcIds then return nil end

    for _, npcId in ipairs(npcIds) do
        npcId = QEF.Num(npcId)
        if npcId then
            local result = { npcId = npcId, name = Source.NpcName(npcId) }
            local spawns = QEF.Tbl(QEF.Try(NpcDB.Get, npcId, "spawns"))
            if spawns then
                for areaId, points in pairs(spawns) do
                    local list = QEF.Tbl(points)
                    local first = list and QEF.Tbl(list[1])
                    local x, y = QEF.Num(first and first[1]), QEF.Num(first and first[2])
                    -- A spawn recorded as 0,0 means "somewhere in this zone", not the corner.
                    if x and y and (x ~= 0 or y ~= 0) then
                        result.areaId = QEF.Num(areaId)
                        result.x, result.y = x, y
                        result.uiMapId = Source.UiMapIdForArea(areaId)
                        result.zoneName = Source.ZoneName(areaId)
                        break
                    end
                end
            end
            if result.name or result.x then return result end
        end
    end
    return nil
end

--- Where a quest is picked up: the first NPC that starts it, with a spawn point.
--- Quests started by an object or an item have no NPC, and quests whose starter has no
--- recorded spawn return the name without coordinates.
---@param questId number
---@return table? start { npcId, name, areaId, uiMapId, x, y }
function Source.QuestStart(questId)
    if not Source.available then return nil end
    local startedBy = QEF.Tbl(Source.Quest(questId, "startedBy"))
    return FirstNpcPlace(startedBy and startedBy[1])
end

--- Where a quest is handed in. Usually a different NPC from the one who gave it out, and
--- often in a different zone, which is the whole reason it is worth saying.
--- finishedBy has the same shape as startedBy: NPC ids first, object ids second. Only the
--- NPCs are used, since an object turn-in has no name worth pointing a player at.
---@param questId number
---@return table? finish { npcId, name, areaId, uiMapId, x, y, zoneName }
function Source.QuestEnd(questId)
    if not Source.available then return nil end
    local finishedBy = QEF.Tbl(Source.Quest(questId, "finishedBy"))
    return FirstNpcPlace(finishedBy and finishedBy[1])
end

--- Every recorded spawn of an NPC, as areaId -> { {x, y}, ... }.
--- QuestStart takes the first usable one, because a waypoint needs exactly one place. Map
--- pins want them all: the point of a map is seeing the four spots he patrols between.
---@param npcId number
---@return table? spawns
function Source.NpcSpawns(npcId)
    if not Source.available or type(NpcDB) ~= "table" then return nil end
    npcId = QEF.Num(npcId)
    if not npcId then return nil end
    return QEF.Tbl(QEF.Try(NpcDB.Get, npcId, "spawns"))
end

--- Where a quest's objectives are, as one place: the first creature it names that has a
--- recorded spawn, with the objective's own wording attached.
---
--- A quest sitting in your log is not "nowhere" - it is wherever the things it asks you to
--- kill or talk to are standing. Only creatures: an objective that is an item to gather or
--- an object to click needs a lookup this does not do, and guessing would be worse than the
--- honest blank.
---@param questId number
---@return table? place { npcId, name, areaId, uiMapId, x, y, zoneName, objective }
function Source.ObjectivePlace(questId)
    for _, creature in ipairs(Source.ObjectiveNpcs(questId)) do
        local place = FirstNpcPlace({ creature.id })
        if place and place.x then
            place.objective = creature.text
            return place
        end
    end
    return nil
end

--- The creatures a quest's objectives point at: kill these, talk to that one.
---
--- `objectives` is { creature, object, item, reputation, killCredit, spell } and the
--- creature slot is a list of { npcId, text }. Some rows store a single objective bare
--- rather than as a list of one, so both shapes are read. Object and item objectives need
--- their own lookups - an item means finding what drops it - and are not read here.
---@param questId number
---@return table[] creatures { id, text }
function Source.ObjectiveNpcs(questId)
    local out = {}
    local objectives = QEF.Tbl(Source.Quest(questId, "objectives"))
    local creatures = objectives and QEF.Tbl(objectives[1])
    if not creatures then return out end

    if QEF.Num(creatures[1]) then
        out[1] = { id = QEF.Num(creatures[1]), text = QEF.Str(creatures[2]) }
        return out
    end

    for _, entry in ipairs(creatures) do
        local row = QEF.Tbl(entry)
        local npcId = QEF.Num(row and row[1])
        if npcId then
            out[#out + 1] = { id = npcId, text = QEF.Str(row[2]) }
        end
    end
    return out
end

--------------------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------------------

---@param itemId number
---@param key string
---@return any
function Source.Item(itemId, key)
    if not Source.available or type(ItemDB) ~= "table" then return nil end
    itemId = QEF.Num(itemId)
    if not itemId then return nil end
    return QEF.Try(ItemDB.Get, itemId, key)
end

--- Item level from the static DB, for items the client has not cached yet.
---@param itemId number
---@return number?
function Source.ItemLevel(itemId)
    local level = QEF.Num(Source.Item(itemId, "itemLevel"))
    if level and level > 0 then return level end
    return nil
end

---@param itemId number
---@return string?
function Source.ItemName(itemId)
    return QEF.Str(Source.Item(itemId, "name"))
end

--------------------------------------------------------------------------------------------
-- NPCs
--------------------------------------------------------------------------------------------

---@param npcId number
---@return string?
function Source.NpcName(npcId)
    if not Source.available or type(NpcDB) ~= "table" then return nil end
    npcId = QEF.Num(npcId)
    if not npcId then return nil end
    return QEF.Str(QEF.Try(NpcDB.Get, npcId, "name"))
end

--------------------------------------------------------------------------------------------
-- Name lookup, via Questie when it is loaded
--------------------------------------------------------------------------------------------

--- Resolve a quest title to an id. Only Questie has the disambiguation logic for this (it
--- uses the quest giver to pick between same-named quests), so without Questie this gives up
--- rather than guessing.
---@param title string
---@param npcGuid string?
---@param isAvailable boolean
---@return number?
function Source.QuestIdFromName(title, npcGuid, isAvailable)
    title = QEF.Str(title)
    if not title then return nil end
    if not _G.QuestieLoader then return nil end

    local QuestieDB = QEF.Try(_G.QuestieLoader.ImportModule, _G.QuestieLoader, "QuestieDB")
    if type(QuestieDB) ~= "table" or type(QuestieDB.GetQuestIDFromName) ~= "function" then
        return nil
    end
    if not QEF.Readable(npcGuid) then npcGuid = nil end
    return QEF.QuestId(QEF.Try(QuestieDB.GetQuestIDFromName, title, npcGuid, isAvailable))
end

--------------------------------------------------------------------------------------------
-- Raw metadata probe
--------------------------------------------------------------------------------------------

-- QuestieDB's "baked" mode keeps every value in its own TOC metadata, keyed
-- X-<Entity>-<id>-<fieldIndex>, with scalars packed into X-<Entity>-<id>-S. Asking whether a
-- key exists is one GetAddOnMetadata call with no decode and no cache growth, which is what
-- makes building a reverse index over 23,000 items cheap. Index.lua uses this when the mode
-- is "baked" and falls back to ordinary reads otherwise.

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata

--- True when the cheap metadata probe is usable on this install.
---@return boolean
function Source.CanProbe()
    return Source.available
        and Source.readMode == "baked"
        and type(GetAddOnMetadata) == "function"
end

--- Whether an entity has a stored value for a table field, without decoding it.
---@param entityPrefix string "Item" or "Quest"
---@param id number
---@param fieldIndex number
---@return boolean
function Source.HasField(entityPrefix, id, fieldIndex)
    local value = QEF.Try(GetAddOnMetadata, "QuestieDB", "X-" .. entityPrefix .. "-" .. id .. "-" .. fieldIndex)
    return value ~= nil
end

-- Field index of Item.questRewards, from QuestieDB's itemMeta. Only used for the probe;
-- every actual read goes through the named API.
Source.ITEM_FIELD_QUEST_REWARDS = 6

--- Every id QuestieDB knows for an entity, ascending. Returns an empty list when unavailable.
---@param which string "Quest" or "Item"
---@return number[]
function Source.AllIds(which)
    local entity = which == "Item" and ItemDB or QuestDB
    if type(entity) ~= "table" or type(entity.GetAllIds) ~= "function" then return {} end
    local ids = QEF.Tbl(QEF.Try(entity.GetAllIds))
    return ids or {}
end

QEF.RegisterInit("Source", function()
    Source.Init()
    for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_REMOVED",
                             "QUEST_ACCEPTED", "PLAYER_ENTERING_WORLD" }) do
        QEF.On(event, Source.InvalidateStatus)
    end
end)
