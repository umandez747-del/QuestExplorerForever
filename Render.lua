-- Render.lua
--
-- Turns a quest id into a list of rows. Tooltip.lua, Panel.lua and QuestieBridge.lua all
-- consume the same rows, so the preview reads identically wherever it appears.
--
-- A row is one of:
--   { kind = "line",   left = string, indent = n, icon = fileId }
--   { kind = "double", left = string, right = string, indent = n, icon = fileId }
--   { kind = "blank" }

local ADDON, QEF = ...

local Render = {}
QEF.Render = Render

local Source, Index, Chain, Rewards, Art

local C = QEF.color

--------------------------------------------------------------------------------------------
-- Item display
--------------------------------------------------------------------------------------------

local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemIconFn = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
local RequestItemFn = C_Item and C_Item.RequestLoadItemDataByID

local QUALITY_FALLBACK = "|cffffffff"

local function QualityPrefix(quality)
    quality = QEF.Num(quality)
    if not quality then return QUALITY_FALLBACK end
    local colors = _G.ITEM_QUALITY_COLORS
    local entry = colors and colors[quality]
    if entry and entry.hex then return entry.hex end
    return QUALITY_FALLBACK
end

--- Everything the UI needs about one reward item. Falls back to QuestieDB's name and item
--- level for items the client has never cached, and asks the client to load them so the next
--- draw is complete.
---@param itemId number
---@param hint table? partial info already supplied by a quest API
---@return table info
function Render.ItemInfo(itemId, hint)
    itemId = QEF.Num(itemId)
    local info = {
        itemId = itemId,
        name = hint and QEF.Str(hint.name) or nil,
        icon = hint and QEF.Num(hint.icon) or nil,
        quality = hint and QEF.Num(hint.quality) or nil,
        count = hint and QEF.Num(hint.count) or nil,
        itemLevel = nil,
        slot = nil,
        cached = false,
    }
    if not itemId then
        info.name = info.name or UNKNOWN or "Unknown"
        return info
    end

    local name, _, quality, itemLevel, _, _, subType, _, equipLoc = QEF.Try(GetItemInfoFn, itemId)
    if QEF.Str(name) then
        info.cached = true
        info.name = QEF.Str(name)
        info.quality = QEF.Num(quality) or info.quality
        info.itemLevel = QEF.Num(itemLevel)
        local slotName = QEF.Str(equipLoc) and _G[equipLoc]
        slotName = QEF.Str(slotName)
        local subTypeName = QEF.Str(subType)
        if slotName and subTypeName then
            info.slot = slotName .. ", " .. subTypeName
        else
            info.slot = slotName or subTypeName
        end
    else
        -- Not in the client's item cache. Ask for it; GET_ITEM_INFO_RECEIVED redraws.
        if RequestItemFn then QEF.Try(RequestItemFn, itemId) end
        info.name = info.name or Source.ItemName(itemId)
        info.itemLevel = Source.ItemLevel(itemId)
    end

    if not info.icon then info.icon = QEF.Num(QEF.Try(GetItemIconFn, itemId)) end
    if not info.name then info.name = "item:" .. itemId end
    return info
end

--- "Shadowfang  (ilvl 38, Main Hand, Sword)" coloured by quality.
---@param info table
---@param verbose boolean
---@return string left
---@return string? right
local function ItemLine(info, verbose)
    local text = QualityPrefix(info.quality) .. info.name .. "|r"
    if info.count and info.count > 1 then
        text = text .. C.label .. " x" .. info.count .. "|r"
    end

    local right
    if verbose then
        local bits = {}
        if info.itemLevel and info.itemLevel > 0 then bits[#bits + 1] = "ilvl " .. info.itemLevel end
        if info.slot then bits[#bits + 1] = info.slot end
        if #bits > 0 then right = C.label .. table.concat(bits, ", ") .. "|r" end
    end
    return text, right
end

--------------------------------------------------------------------------------------------
-- Row helpers
--------------------------------------------------------------------------------------------

local function Rows()
    local rows = {}

    function rows:Line(text, indent, icon, itemId)
        if not text then return end
        self[#self + 1] = { kind = "line", left = text, indent = indent or 0, icon = icon, itemId = itemId }
    end

    function rows:Double(left, right, indent, icon, itemId)
        if not left then return end
        if not right then return self:Line(left, indent, icon, itemId) end
        self[#self + 1] = { kind = "double", left = left, right = right, indent = indent or 0,
            icon = icon, itemId = itemId }
    end

    --- A row that links to another quest. Clicking it opens that quest in the browser, which
    --- is how a player follows a chain back to the quest that starts it.
    --- `fromZone` is the zone of the quest being previewed. When a linked quest is filed
    --- under a different one, that zone is named: a chain that starts in Stormwind and
    --- finishes in the Wetlands is a different proposition from one that stays put, and
    --- nothing else on the line would tell you.
    function rows:QuestLink(questId, indent, prefix, fromZone)
        local name = Source.QuestName(questId) or ("Quest " .. questId)
        local status = Source.QuestStatus(questId)
        local level = select(1, Source.QuestLevels(questId))
        local faction = Source.QuestFaction(questId)

        local text = Art.StatusMarkup(status, 12) .. Art.FactionMarkup(faction, 12)
        if level then text = text .. C.label .. "[" .. level .. "] |r" end
        text = text .. C.text .. name .. "|r" .. Art.StatusSuffix(status)

        local zone = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))
        if zone and fromZone and zone ~= fromZone then
            text = text .. C.chain .. "  \226\134\146 " .. zone .. "|r"
        end

        if prefix then text = C.label .. prefix .. ": |r" .. text end

        self[#self + 1] = {
            kind = "line", left = text, indent = indent or 0,
            questId = questId, questName = name,
        }
    end

    --- A section heading. The stack renders these small, faint and upper case, with space
    --- above, which is what stops the preview reading as one dense column.
    function rows:Section(text)
        if not text then return end
        self[#self + 1] = { kind = "section", left = text, indent = 0 }
    end

    function rows:Blank()
        if #self == 0 then return end
        if self[#self].kind == "blank" then return end
        self[#self + 1] = { kind = "blank" }
    end

    return rows
end

--------------------------------------------------------------------------------------------
-- Sections
--------------------------------------------------------------------------------------------

local function AddHeader(rows, questId, opts)
    local name = Source.QuestName(questId) or opts.title
    local questLevel, requiredLevel = Source.QuestLevels(questId)

    local title = name or ("Quest " .. questId)
    if questLevel then
        title = C.label .. "[" .. questLevel .. "] |r" .. C.header .. title .. "|r"
    else
        title = C.header .. title .. "|r"
    end
    local headerStatus = Source.QuestStatus(questId)
    title = Art.StatusMarkup(headerStatus, 14)
        .. Art.FactionMarkup(Source.QuestFaction(questId), 14) .. title
    title = title .. Art.StatusSuffix(headerStatus)
    if QEF.Get("showQuestIds") then
        title = title .. C.label .. " (" .. questId .. ")|r"
    end
    rows:Line(title)

    local faction = Source.QuestFaction(questId)
    if faction then
        local player = Art.PlayerFaction()
        if player and player ~= faction then
            rows:Line(C.warn .. (Art.FactionLabel(faction) or faction)
                .. " only - you cannot take this|r", 1)
        end
    end
    if headerStatus == "locked" then
        rows:Line(C.warn .. "Locked - an earlier quest is needed first|r", 1)
    end

    local playerLevel = QEF.Num(UnitLevel("player")) or 0
    if requiredLevel and requiredLevel > playerLevel then
        rows:Line(C.warn .. "Requires level " .. requiredLevel .. "|r", 1)
    elseif requiredLevel and QEF.Get("verbosity") >= 3 then
        rows:Line(C.label .. "Requires level " .. requiredLevel .. "|r", 1)
    end
end

local function AddObjectives(rows, questId, opts)
    if not QEF.Get("showObjectives") then return end
    -- In the quest log the objectives are already on screen, in full, with their progress
    -- counts. Repeating them beside the frame that is showing them is wasted space.
    if opts.skipObjectives then return end
    local verbosity = QEF.Get("verbosity")
    if verbosity < 2 then return end

    local objectives = Source.Objectives(questId)
    if #objectives == 0 and QEF.Str(opts.objectiveText) then
        objectives = { opts.objectiveText }
    end
    if #objectives == 0 then return end

    local limit = verbosity >= 3 and 5 or 2
    local clipTo = verbosity >= 3 and 160 or 90

    rows:Section("Asks you to")
    for index = 1, math.min(#objectives, limit) do
        local line = QEF.Clip(objectives[index], clipTo)
        if line then rows:Line(C.text .. line .. "|r", 1) end
    end
    if #objectives > limit then
        rows:Line(C.label .. "... and " .. (#objectives - limit) .. " more|r", 1)
    end
end

--- One block of reward items with a heading that is honest about what is known.
local function AddRewardItems(rows, record, verbose)
    local maxLines = QEF.Num(QEF.Get("maxRewardLines")) or 6

    local function block(list, heading)
        if #list == 0 then return end
        rows:Section(heading)
        for index = 1, math.min(#list, maxLines) do
            local item = list[index]
            local info = Render.ItemInfo(item.itemId, item)
            local left, right = ItemLine(info, verbose)
            rows:Double(left, right, 1, info.icon, info.itemId)
        end
        if #list > maxLines then
            rows:Line(C.label .. "... and " .. (#list - maxLines) .. " more|r", 1)
        end
    end

    if record.exact then
        block(record.choice, "Choose one")
        block(record.fixed, "You receive")
    else
        -- QuestieDB knows which items a quest can give but not how they are given out.
        block(record.choice, "Possible rewards")
    end
end

local function AddRewards(rows, questId, opts)
    if not QEF.Get("showRewards") then return end

    local record = Rewards.Get(questId, opts.atGiver)
    if not record then return end
    local verbose = QEF.Get("verbosity") >= 2

    AddRewardItems(rows, record, verbose)

    if #record.choice == 0 and #record.fixed == 0 then rows:Section("Rewards") end

    local xp = QEF.Num(record.xp)
    local money = QEF.Money(record.money)
    if xp and xp > 0 then
        rows:Double(C.label .. "Experience|r", C.xp .. (QEF.Comma(xp) or xp) .. " XP|r", 1)
    end
    if money then
        rows:Double(C.label .. "Money|r", money, 1)
    end

    if QEF.Get("showReputation") then
        local reputations = Source.ReputationRewards(questId)
        for index = 1, math.min(#reputations, 3) do
            local entry = reputations[index]
            local factionName = Source.FactionName(entry.factionId)
                or ("faction " .. entry.factionId)
            local sign = entry.value > 0 and "+" or ""
            rows:Double(C.label .. "Reputation|r",
                C.rep .. factionName .. " " .. sign .. entry.value .. "|r", 1)
        end
    end

    if record.pending then
        rows:Line(C.label .. "asking the server for exact rewards...|r", 1)
    end
    if QEF.Get("verbosity") >= 3 then
        rows:Line(C.label .. "reward source: " .. tostring(record.source) .. "|r", 1)
    end
end

--- What stands between the player and this quest, and where the chain actually begins.
--- This is the section that answers "I cannot pick this up, so where do I start?".
local function AddPrerequisites(rows, questId)
    if not QEF.Get("showChain") then return end

    local info = Chain.Analyse(questId)
    if not info then return end

    local prerequisites = info.prerequisites or {}
    local status = Source.QuestStatus(questId)
    local verbosity = QEF.Get("verbosity")
    -- What counts as "somewhere else" for the rows below.
    local ownZone = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))

    -- Nothing to say when the quest is already open to you and nothing came before it.
    if #prerequisites == 0 and (not info.path or #info.path <= 1) then return end

    if #prerequisites > 0 then
        local allRequired = prerequisites[1].required == "all" and #prerequisites > 1
        local heading = status == "locked" and "You need these first" or "Comes after"
        if allRequired then heading = heading .. " - all of them" end
        rows:Section(heading)

        local limit = verbosity >= 3 and 6 or 3
        for index = 1, math.min(#prerequisites, limit) do
            rows:QuestLink(prerequisites[index].id, 1, nil, ownZone)
        end
        if #prerequisites > limit then
            rows:Line(C.label .. "... and " .. (#prerequisites - limit) .. " more|r", 1)
        end
    end

    -- The far end of the backward walk, when it is not simply the quest before this one.
    local path = info.path
    if path and #path > 2 then
        local rootId = path[1]
        if rootId ~= questId and (#prerequisites == 0 or prerequisites[1].id ~= rootId) then
            rows:QuestLink(rootId, 1, "Chain starts at", ownZone)
        end
    end
end

--- Who hands the quest out, and where. The waypoint itself is a button in the panel and the
--- browser; a tooltip can only state the place.
local function AddQuestGiver(rows, questId)
    if QEF.Get("verbosity") < 2 then return end

    local start = Source.QuestStart(questId)
    if not start or not start.name then return end

    rows:Section("Quest giver")
    local location = start.zoneName
    if location and start.x then
        location = ("%s  %.0f, %.0f"):format(location, start.x, start.y)
    end
    rows:Double(C.text .. start.name .. "|r",
        location and (C.label .. location .. "|r") or nil, 0)

    -- Directions only earn their space when the destination is somewhere else.
    if QEF.Get("showTravel") and QEF.Travel and start.uiMapId then
        local route = QEF.Travel.Route(start.uiMapId, start.zoneName)
        if route and #route.steps > 0 and not route.sameContinent then
            rows:Section("Getting there")
            for _, step in ipairs(route.steps) do
                rows:Line(C.text .. step .. "|r", 1)
            end
        end
    end
end

local function AddChain(rows, questId)
    if not QEF.Get("showChain") then return end

    local info = Chain.Analyse(questId)
    if not info then return end

    rows:Section("Chain")

    -- The zone the rows below are measured against: a step filed anywhere else says so.
    local ownZone = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))

    if info.total > 1 then
        rows:Line(C.chain .. "Step " .. info.position .. " of about " .. info.total .. "|r")
    end

    local verbosity = QEF.Get("verbosity")

    -- The line forward, not just the quest after this one. Standing at a quest giver, the
    -- dialog has already told you what this quest asks for and what it pays; what it never
    -- says is that this is the first of four, or that the third one is in a dungeon. That
    -- is the part worth the space.
    local aheadLimit = verbosity >= 3 and 6 or (verbosity >= 2 and 4 or 1)
    local ahead, carriesOn = Chain.PathAhead(questId, aheadLimit)

    for index, step in ipairs(ahead) do
        rows:QuestLink(step.id, 1, index == 1 and "Next" or "then", ownZone)
    end

    if #ahead == 0 then
        -- No walkable line - usually the index is still building. The immediate successors
        -- are still worth naming.
        for index = 1, math.min(#info.next, 2) do
            local entry = info.next[index]
            rows:QuestLink(entry.id, 1, entry.kind == "breadcrumb" and "Leads to" or "Next", ownZone)
        end
    elseif carriesOn then
        rows:Line(C.label .. "... and it carries on from there|r", 1)
    end

    -- Branches are counted rather than drawn: a preview that forks is a preview nobody
    -- reads, and the browser's chain tab shows the whole tree for anyone who wants it.
    local branches = #info.next - 1
    if #ahead > 0 and branches > 0 then
        rows:Line(C.label .. ("plus %d other branch%s from here|r"):format(
            branches, branches == 1 and "" or "es"), 1)
    end

    -- What the chain is actually worth: the rewards of whatever ends it.
    local finalIds = Chain.FinalQuestIds(info)
    if #finalIds > 0 and info.final and info.final.depth > 0 then
        local shown = 0
        for _, finalId in ipairs(finalIds) do
            local record = Rewards.Get(finalId, false)
            local items = record and (#record.choice > 0 and record.choice or record.fixed)
            if items and #items > 0 then
                local stepNumber = info.position + info.final.depth
                rows:Line(C.chain .. "Chain ends at step " .. stepNumber .. " with|r", 1)
                for index = 1, math.min(#items, 3) do
                    local item = items[index]
                    local itemInfo = Render.ItemInfo(item.itemId, item)
                    local left, right = ItemLine(itemInfo, verbosity >= 2)
                    rows:Double(left, right, 2, itemInfo.icon, itemInfo.itemId)
                end
                shown = shown + 1
                if shown >= 2 then break end
            elseif record and record.pending then
                rows:Line(C.label .. "checking what the chain ends with...|r", 1)
                break
            end
        end
        if shown == 0 and info.final.name then
            rows:Line(C.chain .. "Chain ends with |r" .. C.text .. info.final.name .. "|r", 1)
        end
    elseif info.endsHere and info.total > 1 then
        rows:Line(C.label .. "This is the last quest in the chain|r", 1)
    end

    if info.truncated and verbosity >= 3 then
        rows:Line(C.label .. "chain is larger than the walk limit|r", 1)
    end
end

local function AddDungeon(rows, questId)
    if not QEF.Get("showDungeonGate") then return end

    local info = Chain.Analyse(questId)
    local ownDungeon = Source.DungeonOf(questId)

    if ownDungeon then
        rows:Section("Dungeon")
        rows:Line(C.dungeon .. ownDungeon .. "|r")
    end

    if info and info.dungeon then
        if not ownDungeon then rows:Section("Dungeon") end
        local questName = info.dungeon.questName
        if questName then
            rows:Line(C.dungeon .. "Unlocks a " .. info.dungeon.name .. " quest|r")
            rows:Line(C.text .. questName .. C.label
                .. " (" .. info.dungeon.depth .. " step"
                .. (info.dungeon.depth == 1 and "" or "s") .. " ahead)|r", 1)
        else
            rows:Line(C.dungeon .. "Leads to a quest in " .. info.dungeon.name .. "|r")
        end
    end
end

local function AddFlags(rows, questId)
    if QEF.Get("verbosity") < 2 then return end

    local specialFlags = QEF.Num(Source.Quest(questId, "specialFlags")) or 0
    -- Bit 1 of specialFlags is Questie's repeatable marker.
    if specialFlags % 2 == 1 then
        rows:Section("Notes")
        rows:Line(C.label .. "Repeatable|r")
    end

    local breadcrumbFor = QEF.QuestId(Source.Quest(questId, "breadcrumbForQuestId"))
    if breadcrumbFor then
        local name = Source.QuestName(breadcrumbFor)
        rows:Line(C.label .. "Optional breadcrumb"
            .. (name and (" for " .. name) or "") .. "|r")
    end

    if QEF.Get("verbosity") >= 3 then
        local exclusive = QEF.Tbl(Source.Quest(questId, "exclusiveTo"))
        if exclusive and #exclusive > 0 then
            local names = {}
            for index = 1, math.min(#exclusive, 3) do
                names[#names + 1] = Source.QuestName(exclusive[index]) or tostring(exclusive[index])
            end
            rows:Line(C.warn .. "Taking this locks out: |r" .. C.text
                .. table.concat(names, ", ") .. "|r")
        end
    end
end

--------------------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------------------

--- Build the preview rows for a quest.
---@param questId number
---@param opts table? { atGiver = boolean, title = string, objectiveText = string }
---@return table[] rows
function Render.Build(questId, opts)
    opts = opts or {}
    questId = QEF.QuestId(questId)
    local rows = Rows()
    if not questId then return rows end

    if not opts.skipHeader then AddHeader(rows, questId, opts) end
    AddObjectives(rows, questId, opts)
    AddRewards(rows, questId, opts)
    AddPrerequisites(rows, questId)
    AddChain(rows, questId)
    AddDungeon(rows, questId)
    AddQuestGiver(rows, questId)
    AddFlags(rows, questId)

    if not Source.available and #rows <= 1 then
        rows:Line(C.label .. "QuestieDB not loaded - chain and reward lookahead unavailable|r", 1)
    elseif Source.available and not Index.ready then
        rows:Line(C.label .. "building quest index...|r", 1)
    end

    return rows
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Render", function()
    Source = QEF.Source
    Index = QEF.Index
    Chain = QEF.Chain
    Rewards = QEF.Rewards
    Art = QEF.Art
end)
