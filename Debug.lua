-- Debug.lua
--
-- The point of this file is to let you check what the client and the databases actually hand
-- back, rather than trusting any claim this addon makes about them. Every command prints real
-- values read at the moment you run it, and says explicitly when something came back secret,
-- missing, or empty.
--
--   /qef status        what loaded, what version, what mode
--   /qef api           which quest APIs exist on this client, and whether they answer
--   /qef index         reverse-index statistics
--   /qef quest <id>    every QuestieDB field this addon reads, plus what it derived from them
--   /qef giver         what the open quest giver frame returns, field by field
--   /qef reward <id>   resolve rewards for any quest id and name the tier that answered

local ADDON, QEF = ...

-- Named Diagnostics rather than Debug because QEF.Debug is already the debug-print helper.
local Debug = {}
QEF.Diagnostics = Debug

local function Line(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888|r " .. text)
end

local function Head(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cfff2c75b" .. text .. "|r")
end

--------------------------------------------------------------------------------------------
-- Value formatting
--------------------------------------------------------------------------------------------

local function Describe(value, depth)
    depth = depth or 0
    if value == nil then return "|cff808080nil|r" end
    if not QEF.Readable(value) then return "|cffff8040<secret>|r" end

    local valueType = type(value)
    if valueType == "number" or valueType == "boolean" then return tostring(value) end
    if valueType == "string" then
        if #value > 70 then return '"' .. value:sub(1, 70) .. '..."' end
        return '"' .. value .. '"'
    end
    if valueType ~= "table" then return "<" .. valueType .. ">" end

    local tbl = QEF.Tbl(value)
    if not tbl then return "|cffff8040<secret table>|r" end
    if depth >= 2 then return "{...}" end

    local parts = {}
    local count = 0
    for _, entry in ipairs(tbl) do
        count = count + 1
        if count > 8 then parts[#parts + 1] = "..." break end
        parts[#parts + 1] = Describe(entry, depth + 1)
    end
    if count == 0 then
        for key, entry in pairs(tbl) do
            count = count + 1
            if count > 6 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(key) .. "=" .. Describe(entry, depth + 1)
        end
    end
    if count == 0 then return "{}" end
    return "{" .. table.concat(parts, ", ") .. "}"
end

Debug.Describe = Describe

--- Every module that registers an init, so the status report can name any that are absent.
--- A file that fails to compile does not announce itself: it is simply not there, and the
--- first symptom is some other file erroring on a nil it expected to exist.
Debug.expectedModules = {
    "Art", "Browse", "Chain", "Checklist", "Controller", "Guide", "Hooks", "Index",
    "Link", "MapPins", "MinimapButton", "Options", "Panel", "Plan", "QuestieBridge",
    "Render", "Rewards", "Route", "Search", "Source", "Sweep", "Tooltip", "Tracker",
    "Views", "Welcome", "Window",
}

--------------------------------------------------------------------------------------------
-- /qef status
--------------------------------------------------------------------------------------------

function Debug.Status()
    local Source = QEF.Source
    Head("Quest Explorer " .. QEF.version)
    Line(("client: build %s, interface %d%s"):format(
        tostring(QEF.buildNumber), QEF.interfaceVersion,
        QEF.isForever and " |cff40c040(Forever)|r" or ""))
    Line("secret values: " .. (_G.issecretvalue and "|cff40c040supported|r" or "not present"))

    if Source.available then
        Line(("QuestieDB: |cff40c040loaded|r, mode %s, flavor %s"):format(
            tostring(Source.readMode), tostring(Source.flavor)))
        Line("  build commit: " .. tostring(Source.buildCommit))
        Line("  cheap metadata probe: " .. (Source.CanProbe() and "yes" or "no"))
        Line("  quest XP table: " .. (Source.xpDB and "yes" or "|cffff8040missing|r"))
        local dungeons = 0
        for _ in pairs(Source.dungeonByArea) do dungeons = dungeons + 1 end
        Line("  dungeon area ids: " .. dungeons)
        if Source.contractNote then
            Line("  |cffff8040contract note:|r " .. Source.contractNote)
        end
    else
        Line("QuestieDB: |cffff4040not available|r - live client data only")
    end

    Line("Questie: " .. (Source.questieAvailable and "|cff40c040loaded|r" or "not loaded"))
    Line("  map icon integration: " .. tostring(QEF.QuestieBridge.status))

    Line("quest log preview: " .. (QEF.Get("questLog") and "|cff40c040on|r" or "off"))
    Line("  selection hooks: " .. QEF.Hooks.LogReport())
    -- A report that throws takes the rest of the report down with it, which is the worst
    -- possible failure for the thing you run when something is already wrong. Last time
    -- this line read `pcall(QEF.MapPins.Report)`, which indexes the module *before* pcall
    -- can catch anything - so a module that had not loaded killed the whole report and
    -- left no clue that it was missing.
    if type(QEF.MapPins) ~= "table" then
        Line("own map pins: |cffff4040MapPins.lua is not loaded|r")
    else
        local ok, pins = pcall(function() return QEF.MapPins.Report() end)
        Line("own map pins: "
            .. (ok and pins or ("|cffff4040report failed|r - " .. tostring(pins))))
    end

    -- Which files actually got in. A file that fails to compile is simply absent, with
    -- nothing in chat to say so unless Lua errors are switched on.
    local loaded, missing = {}, {}
    for _, module in ipairs(QEF.modules or {}) do loaded[module.name] = true end
    for _, name in ipairs(Debug.expectedModules) do
        if not loaded[name] then missing[#missing + 1] = name end
    end
    Line(("modules: %d registered%s"):format(#(QEF.modules or {}),
        #missing == 0 and "" or (", |cffff4040missing " .. table.concat(missing, ", ") .. "|r")))

    Line(("mode: %s, verbosity: %s, live lookahead: %s, learning: %s"):format(
        tostring(QEF.Get("mode")), tostring(QEF.Get("verbosity")),
        tostring(QEF.Get("liveLookahead")), tostring(QEF.Get("learn"))))

    local learned = 0
    for _ in pairs(QEF.learned or {}) do learned = learned + 1 end
    Line("learned reward sets: " .. learned)
end

--------------------------------------------------------------------------------------------
-- /qef api
--------------------------------------------------------------------------------------------

local API_CHECKS = {
    { "GetQuestID", "quest id of the open quest" },
    { "GetNumQuestChoices", "choice rewards at the giver" },
    { "GetNumQuestRewards", "fixed rewards at the giver" },
    { "GetQuestItemInfo", "reward detail at the giver" },
    { "GetQuestItemLink", "reward item link at the giver" },
    { "GetRewardXP", "XP at the giver" },
    { "GetRewardMoney", "money at the giver" },
    { "GetNumQuestLogRewards", "fixed rewards for any quest id" },
    { "GetNumQuestLogChoices", "choice rewards for any quest id" },
    { "GetQuestLogRewardInfo", "reward detail for any quest id" },
    { "GetQuestLogChoiceInfo", "choice detail for any quest id" },
    { "GetQuestLogRewardXP", "XP for any quest id" },
    { "GetQuestLogRewardMoney", "money for any quest id" },
    { "GetActiveQuestID", "greeting: active entry id" },
    { "GetAvailableQuestInfo", "greeting: available entry id (position 5 on Forever)" },
    { "GetActiveTitle", "greeting: active entry title" },
    { "GetAvailableTitle", "greeting: available entry title" },
    { "GetNumActiveQuests", "greeting: active count" },
    { "GetNumAvailableQuests", "greeting: available count" },
    { "GetFactionInfoByID", "faction names, pre-C_Reputation clients only" },
    { "issecretvalue", "secret value detection" },
    { "issecrettable", "secret table detection" },
}

local NAMESPACED_CHECKS = {
    { C_QuestLog, "RequestLoadQuestByID", "C_QuestLog.RequestLoadQuestByID", "load any quest id from the server" },
    { C_QuestLog, "GetQuestInfo", "C_QuestLog.GetQuestInfo", "title for any quest id" },
    { C_GossipInfo, "GetAvailableQuests", "C_GossipInfo.GetAvailableQuests", "gossip available list" },
    { C_GossipInfo, "GetActiveQuests", "C_GossipInfo.GetActiveQuests", "gossip active list" },
    { C_Item, "RequestLoadItemDataByID", "C_Item.RequestLoadItemDataByID", "warm the item cache" },
    { C_Item, "GetItemInfo", "C_Item.GetItemInfo", "item name, quality, item level" },
    { C_Reputation, "GetFactionDataByID", "C_Reputation.GetFactionDataByID", "faction names for reputation rewards" },
    { C_QuestLog, "IsQuestFlaggedCompleted", "C_QuestLog.IsQuestFlaggedCompleted", "whether a quest is done" },
    { C_QuestLog, "GetAllCompletedQuestIDs", "C_QuestLog.GetAllCompletedQuestIDs", "the whole completed set at once" },
    { C_QuestLog, "GetLogIndexForQuestID", "C_QuestLog.GetLogIndexForQuestID", "whether a quest is in your log" },
    { C_Map, "SetUserWaypoint", "C_Map.SetUserWaypoint", "place a waypoint" },
    { C_Map, "CanSetUserWaypointOnMap", "C_Map.CanSetUserWaypointOnMap", "whether a map accepts waypoints" },
    { C_Map, "GetUserWaypoint", "C_Map.GetUserWaypoint", "read a waypoint back, to verify it stuck" },
    { C_Map, "GetAreaInfo", "C_Map.GetAreaInfo", "zone names for the browser" },
    { C_SuperTrack, "SetSuperTrackedUserWaypoint", "C_SuperTrack.SetSuperTrackedUserWaypoint", "supertrack the waypoint" },
    { UiMapPoint, "CreateFromCoordinates", "UiMapPoint.CreateFromCoordinates", "build a map point" },
    { C_GamePad, "IsEnabled", "C_GamePad.IsEnabled", "whether the game reads pads at all" },
    { C_GamePad, "GetAllDeviceIDs", "C_GamePad.GetAllDeviceIDs", "which pads are connected" },
    { C_GamePad, "GetActiveDeviceID", "C_GamePad.GetActiveDeviceID", "the pad in use" },
}

function Debug.Api()
    Head("Quest APIs on this client")
    for _, check in ipairs(API_CHECKS) do
        local present = type(_G[check[1]]) == "function"
        Line((present and "|cff40c040 ok  |r" or "|cffff4040miss|r") ..
            " " .. check[1] .. " |cff808080- " .. check[2] .. "|r")
    end
    for _, check in ipairs(NAMESPACED_CHECKS) do
        local namespace, key = check[1], check[2]
        local present = type(namespace) == "table" and type(namespace[key]) == "function"
        Line((present and "|cff40c040 ok  |r" or "|cffff4040miss|r") ..
            " " .. check[3] .. " |cff808080- " .. check[4] .. "|r")
    end

    -- Stated outright rather than left to be inferred from the three lines above, since
    -- "is there a pad" is the question those lines are usually being read for.
    local detected, reason = QEF.Controller.Detected()
    Line((detected and "|cff40c040 ok  |r" or "|cffff4040 no  |r")
        .. " gamepad |cff808080- " .. (reason or "") .. "|r")
    Line("     controller layout |cff808080- setting "
        .. tostring(QEF.Get("controller")) .. ", "
        .. (QEF.Controller.active and "on" or "off") .. " right now|r")

    Line("|cff808080'miss' means this addon simply does not use that path on this client.|r")
end

--------------------------------------------------------------------------------------------
-- /qef index
--------------------------------------------------------------------------------------------

function Debug.Index()
    local stats = QEF.Index.stats
    Head("Reverse index")
    Line("ready: " .. tostring(QEF.Index.ready))
    if not QEF.Source.available then
        Line("no QuestieDB, nothing to index")
        return
    end
    Line(("quests scanned: %d, chain edges: %d"):format(stats.quests, stats.chainEdges))
    Line(("items scanned: %d (%s)"):format(stats.items,
        stats.probed and "metadata probe" or "full read"))
    Line(("quests with reward items: %d, item relations: %d"):format(
        stats.rewardQuests, stats.rewardRelations))
    Line(("build time: %.0f ms"):format(stats.elapsedMs))
    if stats.quests > 0 then
        Line(("reward coverage: %.0f%% of known quests"):format(
            stats.rewardQuests / stats.quests * 100))
    end
end

--------------------------------------------------------------------------------------------
-- /qef quest <id>
--------------------------------------------------------------------------------------------

function Debug.Quest(questId)
    questId = QEF.QuestId(questId)
    if not questId then
        Line("usage: /qef quest <questId>")
        return
    end

    local Source = QEF.Source
    Head("Quest " .. questId .. ": " .. (Source.QuestName(questId) or "|cffff4040not in QuestieDB|r"))

    if not Source.available then
        Line("QuestieDB not loaded; only live data below.")
    else
        Line("|cffffd100raw QuestieDB fields|r  |cff808080(nil means the field has no stored value)|r")
        for _, field in ipairs(Source.questFields) do
            local value = Source.Quest(questId, field)
            if value ~= nil then
                Line("  " .. field .. " = " .. Describe(value))
            end
        end
    end

    Line("|cffffd100derived|r")
    Line("  status: " .. tostring(Source.QuestStatus(questId))
        .. "  (completed flag: " .. tostring(Source.IsCompleted(questId)) .. ")")
    Line("  faction: " .. (Source.QuestFaction(questId) or "either"))

    local start = Source.QuestStart(questId)
    if start then
        local where = " - no recorded spawn"
        if start.x then
            where = (" at %s %.1f, %.1f (uiMap %s)"):format(
                start.zoneName or "?", start.x, start.y, tostring(start.uiMapId))
        end
        Line(("  starts at: %s (npc %s)%s"):format(
            start.name or "?", tostring(start.npcId), where))
    else
        Line("  starts at: |cff808080no NPC starter (item or object)|r")
    end

    local finish = Source.QuestEnd(questId)
    if finish then
        local where = " - no recorded spawn"
        if finish.x then
            where = (" at %s %.1f, %.1f (uiMap %s)"):format(
                finish.zoneName or "?", finish.x, finish.y, tostring(finish.uiMapId))
        end
        Line(("  turns in at: %s (npc %s)%s"):format(
            finish.name or "?", tostring(finish.npcId), where))
    else
        Line("  turns in at: |cff808080no NPC recorded (an object, or an item you use)|r")
    end

    local dungeon = Source.DungeonOf(questId)
    Line("  own dungeon: " .. (dungeon or "none"))
    Line("  base XP (scaled for your level): " .. tostring(Source.BaseXP(questId)))

    local children = QEF.Index.Children(questId)
    Line("  leads to: " .. (#children == 0 and "nothing" or ""))
    for _, edge in ipairs(children) do
        Line(("    %d %s |cff808080(%s)|r"):format(edge.id,
            Source.QuestName(edge.id) or "?", edge.kind))
    end

    local info = QEF.Chain.Analyse(questId)
    if info and info.path and #info.path > 1 then
        local names = {}
        for _, stepId in ipairs(info.path) do names[#names + 1] = tostring(stepId) end
        Line("  path from root: " .. table.concat(names, " -> "))
    end
    if info then
        Line(("  chain: step %d of about %d, root %d, %d nodes%s"):format(
            info.position, info.total, info.root, info.nodeCount,
            info.truncated and ", truncated" or ""))
        if info.final then
            Line(("    final quest: %d %s at depth %d"):format(
                info.final.id, info.final.name or "?", info.final.depth))
        end
        if info.dungeon then
            Line(("    unlocks %s quest: %s (%d ahead)"):format(
                info.dungeon.name, info.dungeon.questName or "?", info.dungeon.depth))
        end
    else
        Line("  chain: none found" .. (QEF.Index.ready and "" or " |cffff8040(index still building)|r"))
    end

    Debug.Rewards(questId, true)
end

--------------------------------------------------------------------------------------------
-- /qef reward <id>
--------------------------------------------------------------------------------------------

function Debug.Rewards(questId, quiet)
    questId = QEF.QuestId(questId)
    if not questId then
        Line("usage: /qef reward <questId>")
        return
    end
    if not quiet then Head("Rewards for quest " .. questId) end

    local record = QEF.Rewards.Get(questId, false)
    if not record then
        Line("  |cffff4040nothing known|r" ..
            (QEF.Rewards.IsPending(questId) and " yet - asked the server, try again in a moment" or ""))
        return
    end

    Line(("  source: |cffffd100%s|r, exact split: %s%s"):format(
        tostring(record.source), tostring(record.exact),
        record.pending and ", |cffff8040server request pending|r" or ""))

    local function dump(label, list)
        if #list == 0 then return end
        Line("  " .. label .. ":")
        for _, item in ipairs(list) do
            local info = QEF.Render.ItemInfo(item.itemId, item)
            Line(("    %d %s%s"):format(item.itemId, info.name or "?",
                info.itemLevel and (" |cff808080ilvl " .. info.itemLevel .. "|r") or ""))
        end
    end
    dump("choice", record.choice)
    dump("fixed", record.fixed)
    Line("  xp: " .. tostring(record.xp) .. ", money: " .. tostring(record.money))

    if record.pending then
        Line("  |cff808080run the command again once the server answers to see the exact split.|r")
    end
end

--------------------------------------------------------------------------------------------
-- /qef live
--------------------------------------------------------------------------------------------

function Debug.Live()
    Head("Open quest giver frame")

    local questId = QEF.Try(_G.GetQuestID)
    Line("GetQuestID() = " .. Describe(questId))

    local numChoices = QEF.Try(_G.GetNumQuestChoices)
    local numRewards = QEF.Try(_G.GetNumQuestRewards)
    Line("GetNumQuestChoices() = " .. Describe(numChoices))
    Line("GetNumQuestRewards() = " .. Describe(numRewards))
    Line("GetRewardXP() = " .. Describe(QEF.Try(_G.GetRewardXP)))
    Line("GetRewardMoney() = " .. Describe(QEF.Try(_G.GetRewardMoney)))
    Line("GetTitleText() = " .. Describe(QEF.Try(_G.GetTitleText)))
    Line("GetObjectiveText() = " .. Describe(QEF.Try(_G.GetObjectiveText)))

    local function dumpItems(itemType, count)
        count = QEF.Num(count) or 0
        for index = 1, count do
            local name, _, numItems, quality, _, itemId =
                QEF.Try(_G.GetQuestItemInfo, itemType, index)
            local link = QEF.Try(_G.GetQuestItemLink, itemType, index)
            Line(("  %s[%d] name=%s quality=%s count=%s itemId=%s"):format(
                itemType, index, Describe(name), Describe(quality),
                Describe(numItems), Describe(itemId)))
            Line("    link = " .. Describe(link))
        end
    end
    dumpItems("choice", numChoices)
    dumpItems("reward", numRewards)

    Head("Gossip / greeting lists")
    Line("GetNumAvailableQuests() = " .. Describe(QEF.Try(_G.GetNumAvailableQuests)))
    Line("GetNumActiveQuests() = " .. Describe(QEF.Try(_G.GetNumActiveQuests)))
    local numAvailable = QEF.Num(QEF.Try(_G.GetNumAvailableQuests)) or 0
    for index = 1, numAvailable do
        Line(("  GetAvailableQuestInfo(%d) = %s"):format(index,
            Describe({ QEF.Try(_G.GetAvailableQuestInfo, index) })))
        Line(("  GetAvailableTitle(%d) = %s"):format(index,
            Describe(QEF.Try(_G.GetAvailableTitle, index))))
    end
    local numActive = QEF.Num(QEF.Try(_G.GetNumActiveQuests)) or 0
    for index = 1, numActive do
        Line(("  GetActiveQuestID(%d) = %s"):format(index,
            Describe(QEF.Try(_G.GetActiveQuestID, index))))
        Line(("  GetActiveTitle(%d) = %s"):format(index,
            Describe(QEF.Try(_G.GetActiveTitle, index))))
    end

    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        Line("C_GossipInfo.GetAvailableQuests() = " ..
            Describe(QEF.Try(C_GossipInfo.GetAvailableQuests)))
    end
    if C_GossipInfo and C_GossipInfo.GetActiveQuests then
        Line("C_GossipInfo.GetActiveQuests() = " ..
            Describe(QEF.Try(C_GossipInfo.GetActiveQuests)))
    end

    Head("What Quest Explorer wired")
    QEF.Hooks.RefreshGossip()
    QEF.Hooks.RefreshGreeting()
    Line("see the lines above; enable /qef debug on for per-refresh counts")
end

--------------------------------------------------------------------------------------------
-- /qef pins
--------------------------------------------------------------------------------------------

--- Why the map is empty, step by step.
---
--- "None of them on this map" is the end of a chain of possibilities and says nothing about
--- which link gave way: the step may have no recorded place at all, its place may be in a
--- zone you are not looking at, or the projection onto the open map may be failing. This
--- runs each listed step through the same projection the drawing uses and prints what came
--- back, which is the only way to tell those apart from inside the game.
function Debug.Pins()
    local MapPins, Checklist = QEF.MapPins, QEF.Checklist
    Head("Map pins")
    Line(MapPins.Report())

    local open = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if not open then
        Line("|cffff8040the world map is closed|r - open it and run this again")
        return
    end
    local info = QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, open)) or {}
    Line(("open map: %s |cff808080(uiMap %d, type %s)|r"):format(
        QEF.Str(info.name) or "?", open, tostring(info.mapType)))

    -- Draw first, then ask the map what it is holding: the provider counting what it
    -- acquired proves nothing about what reached the canvas. Both steps report their own
    -- failure rather than taking the report down - this diagnostic has died mid-sentence
    -- twice now, and a half-printed report says nothing about why.
    local ok, err = pcall(MapPins.Refresh)
    if not ok then
        Line("|cffff4040drawing threw|r - " .. tostring(err))
    end

    local live, why = 0, nil
    ok, err = pcall(function() live, why = MapPins.LiveCount() end)
    if not ok then
        Line("|cffff4040counting threw|r - " .. tostring(err))
    else
        Line(("the provider drew %d, the canvas is holding %d%s"):format(
            MapPins.drawn or 0, live, why and (" |cff808080(" .. why .. ")|r") or ""))
    end
    if MapPins.lastError then
        Line("|cffff4040last draw error|r - " .. MapPins.lastError)
    end

    -- What the canvas will accept as a drawing level: the names are not the same on
    -- every client, and asking for one it does not know is an assert, not a nil.
    local manager = WorldMapFrame and WorldMapFrame.pinFrameLevelsManager
    if manager then
        local names = {}
        for key, value in pairs(manager) do
            if type(value) == "table" then
                for levelType in pairs(value) do
                    if type(levelType) == "string" then names[levelType] = true end
                end
            end
        end
        local list = {}
        for levelType in pairs(names) do list[#list + 1] = levelType end
        table.sort(list)
        Line(("frame level types: %s"):format(
            #list > 0 and table.concat(list, ", ") or "none the manager will name"))
        Line(("  ours: %s"):format(
            QEF.MapPins.frameLevelType == false and "|cffff8040refused, using a plain level|r"
            or QEF.MapPins.frameLevelType == true and "accepted"
            or "not asked for yet"))
    end

    local zone, carried = 0, 0
    local listedIds = {}
    for _, id in ipairs(Checklist.Ids()) do listedIds[id] = true end
    for _, pin in ipairs(MapPins.PinsFor(open)) do
        if pin.kind == "available" then zone = zone + 1
        elseif not listedIds[pin.questId] then carried = carried + 1 end
    end
    Line(("beyond the checklist: %s - %d going spare in the zone, %d from your log"):format(
        QEF.Get("mapAvailable") and "|cff40c040on|r" or "off", zone, carried))
    if QEF.Get("mapAvailable") and zone == 0 and QEF.Search and not QEF.Search.ready then
        Line("   the quest index is still building - they appear once it finishes")
    end

    local plan = Checklist.Plan()
    if plan.total == 0 then
        Line("the checklist is empty")
        return
    end

    for _, group in ipairs(plan.groups) do
        for _, entry in ipairs(group.entries) do
            local step = entry.step
            Line(("|cffffd100%s %s|r |cff808080(%s, #%d)|r"):format(
                step.verb or "?", step.subject or entry.name, step.kind, entry.id))

            if not step.uiMapId or not step.x or not step.y then
                Line("   |cffff8040no recorded place|r - "
                    .. (step.npc and ("npc " .. step.npc .. " has no mapped spawn")
                        or "nothing to point at"))
            else
                Line(("   %s |cff808080uiMap %d at %.1f, %.1f|r"):format(
                    step.zone or "?", step.uiMapId, step.x, step.y))
                if step.uiMapId == open then
                    Line("   |cff40c040on the open map|r - should be drawn")
                else
                    local px, py = MapPins.Project(step.uiMapId, step.x, step.y, open)
                    if px then
                        Line(("   |cff40c040projects onto the open map|r at %.1f, %.1f")
                            :format(px, py))
                    else
                        Line("   |cffff8040does not project onto the open map|r - "
                            .. "another continent, off its edge, or the client would not "
                            .. "convert the position")
                    end
                end
            end
        end
    end

    if #plan.finished > 0 then
        Line(("%d finished and not drawn"):format(#plan.finished))
    end
end
