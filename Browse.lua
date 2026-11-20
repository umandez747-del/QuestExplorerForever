-- Browse.lua
--
-- The quest browser: search by name or id, narrow by zone, dungeon, faction or rewards, and
-- read the full preview for whatever is selected.
--
-- The detail pane has two tabs. **Preview** is the same row model the tooltip and side panel
-- draw. **Chain** is the whole chain laid out as an indented tree from its first quest to its
-- last, with each step's status, so you can see at a glance where a chain begins, how far
-- through it you are, and what is left.
--
-- Quest names are links throughout. Clicking one navigates to it and pushes the previous
-- quest onto a back stack, which is what makes "where does this chain start?" answerable in
-- two clicks rather than a search.

local ADDON, QEF = ...

local Browse = {}
QEF.Browse = Browse

local W, theme, Art
local Search, Render, Chain, Source

local PAD = 20
-- Sized for the names rather than for the window: at this width a quest name still has
-- ~50 characters at depth 0 and ~39 at the deepest indent, which covers all but a handful
-- of the longest names in the database.
local LIST_WIDTH = 360
local ROW_HEIGHT = 32
-- Roomier rows on a pad: the selection ring needs to read at a glance from across a room,
-- and there is no cursor to fine-tune with.
local CONTROLLER_ROW_HEIGHT = 40
local CHAIN_ROW_HEIGHT = 26
local INDENT_STEP = 14

-- Chain connectors in the results list. The depth cap is about the 300px the list has:
-- past six levels an extra indent costs more in lost name than it buys in structure, so
-- deeper quests sit at the sixth column rather than marching off the edge.
local LIST_INDENT = 12
local LIST_MAX_DEPTH = 6

--- The x of the connector column a quest at this depth hangs from.
local function RailX(depth)
    return (depth - 1) * LIST_INDENT + 7
end

local view, searchBox, zoneButton, zonePopup, resultCount, legendPopup, legendButton
local list, detail, detailTitle, detailMeta, emptyState, statusText
local detailStack, detailScroll, chainList, tabs, backButton, waypointButton, wowheadButton
local checklistButton
local chipDungeons, chipRewards, chipFaction

-- myFaction starts false here and is turned on in BuildToolbar, where the player's side is
-- known; filtering to an unknown faction would hide everything but the neutral quests.
local filters = { text = "", zone = nil, dungeonsOnly = false, rewardsOnly = false, myFaction = false }
local pendingQuery
local history = {}
local activeTab = "preview"

--------------------------------------------------------------------------------------------
-- Querying
--------------------------------------------------------------------------------------------

local function RunQuery()
    pendingQuery = nil
    if not Search.ready then
        list:SetData({})
        resultCount:SetText("")
        return
    end

    local results = Search.Query(filters)
    list:SetData(results)
    resultCount:SetText(("%s quest%s"):format(
        QEF.Comma(#results) or #results, #results == 1 and "" or "s"))

    if #results > 0 then
        list:Select(1)
        Browse.ShowQuest(results[1].id, true)
    else
        Browse.ShowQuest(nil)
    end
end

--- Searching on every keystroke over 5,900 quests is wasteful; a short settle is invisible to
--- the user and turns a burst of typing into one query.
local function QueueQuery()
    if pendingQuery then return end
    pendingQuery = true
    C_Timer.After(0.15, RunQuery)
end

--- Run the current query again, keeping the open quest selected when it is still in the
--- results. Used when a setting changes what the list contains or how it is ordered.
function Browse.Requery()
    if not view or not list or not Search.ready then return end
    local keep = Browse.shownQuestId
    RunQuery()
    if not keep then return end
    for index, item in ipairs(list.data or {}) do
        if item.id == keep then
            list:Select(index)
            Browse.ShowQuest(keep, true)
            return
        end
    end
end

--- Put text into the search box, as /qef browse <text> does. The box's own change handler
--- picks it up, so the query runs through exactly one path.
---@param text string
function Browse.SetSearch(text)
    if not searchBox then return end
    searchBox.edit:SetText(text or "")
end

--------------------------------------------------------------------------------------------
-- Chain tab
--------------------------------------------------------------------------------------------

local function RefreshChain(questId)
    if not chainList then return end
    local nodes = questId and Chain.FullTree(questId) or {}
    chainList:SetData(nodes)

    -- Scroll so the quest you are looking at is visible rather than making you hunt for it.
    for index, node in ipairs(nodes) do
        if node.isCurrent then
            chainList.selected = index
            local visible = math.max(1, math.floor((chainList:GetHeight() or 0) / CHAIN_ROW_HEIGHT))
            if index > visible then
                chainList.offset = math.max(0, index - math.floor(visible / 2))
            end
            break
        end
    end
    chainList:Refresh()
    return #nodes
end

local function SetTab(tab)
    activeTab = tab
    detailScroll:SetShown(tab == "preview")
    chainList:SetShown(tab == "chain")
    if tab == "chain" then RefreshChain(Browse.shownQuestId) end
end

--------------------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------------------

--- The checklist button says what clicking it will do, not what the state is, since that is
--- the thing a player is deciding.
function Browse.RefreshChecklistButton()
    if not checklistButton or not checklistButton.questId then return end
    local listed = QEF.Checklist.Has(checklistButton.questId)
    checklistButton.label:SetText(listed and "On the list" or "+ Checklist")
    checklistButton.label:SetTextColor(unpack(listed and theme.accent or theme.text))
    checklistButton:Fit(100)
end

---@param questId number?
---@param replaceHistory boolean? true when this is a fresh selection, not a link follow
function Browse.ShowQuest(questId, replaceHistory)
    if replaceHistory then history = {} end

    if not questId then
        detailTitle:SetText("")
        detailMeta:SetText("")
        detailStack:Clear()
        chainList:SetData({})
        emptyState:Show()
        waypointButton:Hide()
        wowheadButton:Hide()
        checklistButton:Hide()
        backButton:Hide()
        tabs:Hide()
        Browse.shownQuestId = nil
        return
    end

    emptyState:Hide()
    tabs:Show()
    Browse.shownQuestId = questId

    local name = Source.QuestName(questId) or ("Quest " .. questId)
    local status = Source.QuestStatus(questId)
    local faction = Source.QuestFaction(questId)
    detailTitle:SetText(Art.FactionMarkup(faction, 15) .. name)
    local titleColor = status == "completed" and theme.dim or theme.text
    detailTitle:SetTextColor(titleColor[1], titleColor[2], titleColor[3])

    local statusInfo = Art.StatusInfo(status)
    local questLevel, requiredLevel = Source.QuestLevels(questId)
    local zoneName = Source.ZoneName(Source.Quest(questId, "zoneOrSort"))
    local bits = {}
    if statusInfo then bits[#bits + 1] = statusInfo.label end
    if questLevel then bits[#bits + 1] = "Level " .. questLevel end
    if requiredLevel then bits[#bits + 1] = "requires " .. requiredLevel end
    if zoneName then bits[#bits + 1] = zoneName end
    bits[#bits + 1] = "#" .. questId
    detailMeta:SetText(table.concat(bits, "   \194\183   "))

    -- Set outright as well as from OnSizeChanged: the rows measure their wrapping against
    -- this width, and a stale one would wrap them to the wrong height.
    local paneWidth = detailScroll:GetWidth() or 0
    if paneWidth > 1 then detailStack:SetWidth(paneWidth) end

    local contentHeight = detailStack:SetRows(Render.Build(questId, { skipHeader = true }))
    -- At least the visible height, so the scroll child always fills the frame.
    detailStack:SetHeight(math.max(contentHeight, detailScroll:GetHeight() or 1, 1))
    detailScroll:SetVerticalScroll(0)

    local chainNodes = Chain.FullTree(questId)
    tabs.segments[2].label:SetText(("Chain (%d)"):format(#chainNodes))
    if activeTab == "chain" then RefreshChain(questId) end

    backButton:SetShown(#history > 0)

    -- The waypoint button is only offered when there is somewhere to point at.
    wowheadButton.questId = questId
    wowheadButton:Show()

    checklistButton.questId = questId
    checklistButton:Show()
    Browse.RefreshChecklistButton()

    local start = Source.QuestStart(questId)
    local canWaypoint = start and start.uiMapId and start.x and QEF.Waypoint.IsSupported()
    waypointButton.questId = questId
    if canWaypoint then
        waypointButton.label:SetText("Waypoint to " .. (start.name or "quest giver"))
        waypointButton:Fit(150)
        waypointButton:Show()
    else
        waypointButton:Hide()
    end

    -- Which buttons exist changed, so the focus ring may be sitting on a hidden one.
    if QEF.Controller.active then QEF.Controller.Refresh() end
end

--- Navigate to a quest from a link, remembering where we came from.
---@param questId number
function Browse.Open(questId)
    questId = QEF.QuestId(questId)
    if not questId then return end

    QEF.Window.Show("browse")
    if Browse.shownQuestId and Browse.shownQuestId ~= questId then
        history[#history + 1] = Browse.shownQuestId
    end
    Browse.ShowQuest(questId)

    -- Select it in the list when it happens to be in the current results.
    for index, item in ipairs(list.data or {}) do
        if item.id == questId then
            list:Select(index)
            break
        end
    end
end

local function GoBack()
    local previous = table.remove(history)
    if not previous then return end
    Browse.ShowQuest(previous)
end

--- Redraw the open quest when a late server answer or item load changes what is known.
function Browse.Refresh()
    if view and view:IsShown() and Browse.shownQuestId then
        local keep = history
        Browse.ShowQuest(Browse.shownQuestId)
        history = keep
        backButton:SetShown(#history > 0)
    end
end

--------------------------------------------------------------------------------------------
-- Zone picker
--------------------------------------------------------------------------------------------

local function ZoneLabel()
    return filters.zone or "All zones"
end

local function BuildZonePopup()
    zonePopup = CreateFrame("Frame", nil, view)
    zonePopup:SetSize(300, 360)
    zonePopup:SetPoint("TOPLEFT", zoneButton, "BOTTOMLEFT", 0, -4)
    -- Raised by level rather than by strata. It used to be lifted out of the window's
    -- strata entirely, which stopped working the moment the window itself moved up to
    -- DIALOG to clear the side panel.
    zonePopup:SetFrameLevel((view:GetFrameLevel() or 1) + 20)
    W.Fill(zonePopup, theme.raised)
    W.Outline(zonePopup, theme.line)
    zonePopup:Hide()

    zonePopup.allItems = {}

    -- There are well over a hundred zones, so the list needs filtering of its own rather
    -- than making you scroll for Un'Goro Crater.
    local filter = W.SearchBox(zonePopup, "Filter zones", function(text)
        zonePopup.filterText = (text or ""):lower()
        zonePopup:Apply()
    end)
    filter:SetPoint("TOPLEFT", zonePopup, "TOPLEFT", 1, -1)
    filter:SetPoint("TOPRIGHT", zonePopup, "TOPRIGHT", -1, -1)
    zonePopup.filter = filter

    local function CreateRow(parent)
        local row = CreateFrame("Button", nil, parent)
        row.bg = W.Fill(row, { 0, 0, 0, 0 })
        row.label = W.Text(row, W.size.small, theme.text)
        row.label:SetPoint("LEFT", row, "LEFT", 12, 0)
        row.label:SetWordWrap(false)
        row.count = W.Text(row, W.size.tiny, theme.faint, "RIGHT")
        row.count:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.label:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
        end)
        row:SetScript("OnLeave", function(self) self.bg:SetColorTexture(0, 0, 0, 0) end)
        row:SetScript("OnClick", function(self)
            filters.zone = self.zoneName
            zoneButton.label:SetText(ZoneLabel())
            zonePopup:Hide()
            QueueQuery()
        end)
        return row
    end

    local function UpdateRow(row, item)
        row.zoneName = item.zone
        row.label:SetText(item.label)
        row.count:SetText(item.count and tostring(item.count) or "")
        local color = item.zone == filters.zone and theme.accent or theme.text
        row.label:SetTextColor(color[1], color[2], color[3])
    end

    local picker = W.ScrollList(zonePopup, 24, CreateRow, UpdateRow)
    picker:SetPoint("TOPLEFT", filter, "BOTTOMLEFT", 0, -6)
    picker:SetPoint("BOTTOMRIGHT", zonePopup, "BOTTOMRIGHT", -4, 6)
    zonePopup.picker = picker

    zonePopup.empty = W.Text(zonePopup, W.size.small, theme.faint, "CENTER")
    zonePopup.empty:SetPoint("TOP", picker, "TOP", 0, -12)
    zonePopup.empty:SetPoint("LEFT", picker, "LEFT", 0, 0)
    zonePopup.empty:SetPoint("RIGHT", picker, "RIGHT", 0, 0)
    zonePopup.empty:SetText("No zone matches that.")
    zonePopup.empty:Hide()

    --- Apply the current filter text to the full zone list.
    function zonePopup:Apply()
        local needle = self.filterText
        local shown = {}
        for _, item in ipairs(self.allItems) do
            -- "All zones" always stays, so clearing the filter is one click away.
            if item.zone == nil or not needle or needle == ""
                or item.label:lower():find(needle, 1, true) then
                shown[#shown + 1] = item
            end
        end
        self.picker:SetData(shown)
        self.empty:SetShown(#shown <= 1 and needle and needle ~= "")
    end

    zonePopup:SetScript("OnHide", function(self)
        self.filter.edit:SetText("")
        self.filterText = nil
    end)
end

local function RefreshZonePopup()
    local items = { { zone = nil, label = "All zones" } }
    for _, zoneName in ipairs(Search.zoneList) do
        items[#items + 1] = {
            zone = zoneName,
            label = zoneName,
            count = Search.zoneCounts[zoneName],
        }
    end
    zonePopup.allItems = items
    zonePopup:Apply()
end

--------------------------------------------------------------------------------------------
-- Filter chips
--------------------------------------------------------------------------------------------

--- A small on/off pill. Chips read better than checkboxes in a toolbar and take less room.
local function CreateChip(parent, label, onToggle, iconTexture)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(26)
    chip.bg = W.Fill(chip, theme.raised)

    local textLeft = 13
    if iconTexture then
        chip.icon = chip:CreateTexture(nil, "ARTWORK")
        chip.icon:SetSize(12, 12)
        chip.icon:SetTexture(iconTexture)
        chip.icon:SetPoint("LEFT", chip, "LEFT", 9, 0)
        textLeft = 25
    end

    chip.label = W.Text(chip, W.size.small, theme.dim)
    chip.label:SetPoint("LEFT", chip, "LEFT", textLeft, 0)
    chip.label:SetText(label)
    chip:SetWidth(chip.label:GetStringWidth() + textLeft + 13)

    function chip:SetActive(active)
        self.active = active
        if active then
            self.bg:SetColorTexture(theme.accentDim[1], theme.accentDim[2], theme.accentDim[3], 1)
            self.label:SetTextColor(unpack(theme.accent))
        else
            self.bg:SetColorTexture(unpack(theme.raised))
            self.label:SetTextColor(unpack(theme.dim))
        end
    end

    chip:SetScript("OnClick", function(self)
        self:SetActive(not self.active)
        onToggle(self.active)
    end)
    chip:SetScript("OnEnter", function(self)
        if not self.active then self.label:SetTextColor(unpack(theme.text)) end
    end)
    chip:SetScript("OnLeave", function(self)
        if not self.active then self.label:SetTextColor(unpack(theme.dim)) end
    end)

    chip:SetActive(false)
    return chip
end

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function BuildToolbar()
    local toolbar = CreateFrame("Frame", nil, view)
    toolbar:SetHeight(30)
    toolbar:SetPoint("TOPLEFT", view, "TOPLEFT", PAD, -PAD)
    toolbar:SetPoint("TOPRIGHT", view, "TOPRIGHT", -PAD, -PAD)

    searchBox = W.SearchBox(toolbar, "Search quests by name or id", function(text)
        filters.text = text
        QueueQuery()
    end)
    searchBox:SetPoint("TOPLEFT", toolbar, "TOPLEFT", 0, 0)
    searchBox:SetWidth(250)

    zoneButton = W.Button(toolbar, ZoneLabel())
    zoneButton:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    -- Wide enough for the long dungeon names - "Excavation Site: Wetlands" and friends -
    -- and the label is clamped short of the caret so anything longer truncates instead of
    -- running out across the toolbar.
    zoneButton:SetWidth(210)
    zoneButton:SetHeight(30)
    zoneButton.label:ClearAllPoints()
    zoneButton.label:SetPoint("LEFT", zoneButton, "LEFT", 10, 0)
    zoneButton.label:SetPoint("RIGHT", zoneButton, "RIGHT", -24, 0)
    zoneButton.label:SetJustifyH("LEFT")
    zoneButton.label:SetWordWrap(false)
    local caret = Art.Glyph(zoneButton, "caret", 12, theme.faint)
    caret:SetPoint("RIGHT", zoneButton, "RIGHT", -8, 0)
    zoneButton:SetScript("OnClick", function()
        if zonePopup:IsShown() then
            zonePopup:Hide()
        else
            RefreshZonePopup()
            zonePopup:Show()
        end
    end)

    local playerFaction = Art.PlayerFaction()
    chipFaction = CreateChip(toolbar, playerFaction or "My faction", function(active)
        filters.myFaction = active
        QueueQuery()
    end, playerFaction and Art.faction[playerFaction].texture or nil)
    chipFaction:SetPoint("LEFT", zoneButton, "RIGHT", 10, 0)
    -- On from the start: almost nobody opens the browser to read the other side's quests.
    -- Only when the client actually named a side, though - with the faction unknown the
    -- filter keeps nothing but the neutral quests, which looks like a broken list.
    if playerFaction then
        filters.myFaction = true
        chipFaction:SetActive(true)
    end

    chipDungeons = CreateChip(toolbar, "Dungeons", function(active)
        filters.dungeonsOnly = active
        QueueQuery()
    end)
    chipDungeons:SetPoint("LEFT", chipFaction, "RIGHT", 8, 0)

    chipRewards = CreateChip(toolbar, "Rewards", function(active)
        filters.rewardsOnly = active
        QueueQuery()
    end)
    chipRewards:SetPoint("LEFT", chipDungeons, "RIGHT", 8, 0)

    BuildZonePopup()
    return toolbar
end

--------------------------------------------------------------------------------------------
-- Legend
--------------------------------------------------------------------------------------------

--- The key to the status marks, parked above the list. The marks are the densest thing in
--- the browser and the only part of it that has to be learned, so there is a visible way to
--- ask what they mean rather than a tooltip you have to find by accident.
local function BuildLegend(toolbar)
    local button = CreateFrame("Button", nil, view)
    legendButton = button
    button:SetHeight(18)
    button.bg = W.Fill(button, { 0, 0, 0, 0 })

    local glyph = Art.Glyph(button, "quest", 11, theme.faint)
    glyph:SetPoint("LEFT", button, "LEFT", 4, 0)

    local label = W.Text(button, W.size.tiny, theme.faint)
    label:SetPoint("LEFT", glyph, "RIGHT", 4, 0)
    label:SetText("What do the marks mean?")
    button:SetWidth(label:GetStringWidth() + 26)
    button:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", LIST_WIDTH - button:GetWidth(), -11)

    legendPopup = CreateFrame("Frame", nil, view)
    legendPopup:SetSize(300, 10)
    legendPopup:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -4)
    legendPopup:SetFrameLevel((view:GetFrameLevel() or 1) + 20)
    W.Fill(legendPopup, theme.raised)
    W.Outline(legendPopup, theme.line)
    legendPopup:Hide()

    local heading = W.SectionLabel(legendPopup, "Quest marks")
    heading:SetPoint("TOPLEFT", legendPopup, "TOPLEFT", 12, -12)

    local legend = Art.BuildLegend(legendPopup, 1, 276)
    legend:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)

    -- The one thing about the list that is not self-explanatory: why it is not simply
    -- ordered by level. This is where someone looks when they wonder.
    local note = W.Text(legendPopup, W.size.tiny, theme.faint)
    note:SetPoint("TOPLEFT", legend, "BOTTOMLEFT", 8, -10)
    note:SetWidth(264)
    note:SetJustifyH("LEFT")
    note:SetText("Quests are grouped into chains, each one indented under the quest it "
        .. "follows. Settings turns that off.")
    legendPopup:SetHeight(legend:GetHeight() + note:GetStringHeight() + 62)

    button:SetScript("OnClick", function()
        if legendPopup:IsShown() then
            legendPopup:Hide()
        else
            if zonePopup and zonePopup:IsShown() then zonePopup:Hide() end
            legendPopup:Show()
        end
    end)
    button:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
        label:SetTextColor(unpack(theme.text))
        Art.Tint(glyph, theme.accent)
    end)
    button:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0, 0, 0, 0)
        label:SetTextColor(unpack(theme.faint))
        Art.Tint(glyph, theme.faint)
    end)
end

local function BuildList(toolbar)
    resultCount = W.Text(view, W.size.tiny, theme.faint)
    resultCount:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -14)

    local function CreateRow(parent)
        local row = CreateFrame("Button", nil, parent)
        row.bg = W.Fill(row, { 0, 0, 0, 0 })

        row.marker = row:CreateTexture(nil, "ARTWORK")
        row.marker:SetWidth(2)
        row.marker:SetPoint("TOPLEFT")
        row.marker:SetPoint("BOTTOMLEFT")
        row.marker:SetColorTexture(unpack(theme.accent))
        row.marker:Hide()

        -- Chain connectors: a vertical for every ancestor column that still has rows below
        -- it, and an elbow into this row, so a follower reads as hanging off the quest above
        -- rather than as an unrelated entry that happens to be next.
        row.rails = {}
        for level = 1, LIST_MAX_DEPTH do
            local rail = row:CreateTexture(nil, "ARTWORK")
            rail:SetWidth(1)
            rail:SetColorTexture(theme.line[1], theme.line[2], theme.line[3], 1)
            rail:Hide()
            row.rails[level] = rail
        end

        row.elbow = row:CreateTexture(nil, "ARTWORK")
        row.elbow:SetHeight(1)
        row.elbow:SetColorTexture(theme.line[1], theme.line[2], theme.line[3], 1)
        row.elbow:Hide()

        row.status = Art.StatusIcon(row, 12)
        -- Centred rather than left-aligned: the padlock is drawn larger than the other
        -- marks, so a centred anchor grows it evenly instead of into the level badge.
        row.status:SetPoint("CENTER", row, "LEFT", 12, 0)

        row.level = W.Text(row, W.size.small, theme.dim, "RIGHT")
        row.level:SetPoint("LEFT", row, "LEFT", 20, 0)
        row.level:SetWidth(22)

        row.faction = Art.FactionIcon(row, nil, 12)
        row.faction:SetPoint("LEFT", row.level, "RIGHT", 6, 0)

        row.name = W.Text(row, W.size.body, theme.text)
        row.name:SetPoint("LEFT", row.faction, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -28, 0)
        -- One line, truncated: a name that wrapped would spill into the rows either side,
        -- since the list draws fixed-height rows.
        row.name:SetWordWrap(false)

        -- A key rather than a coloured square: "dungeon" is a thing with a picture, and a
        -- bare swatch is a legend entry nobody should have to look up.
        row.dungeon = Art.Glyph(row, "dungeon", 13, theme.warn)
        row.dungeon:SetPoint("RIGHT", row, "RIGHT", -9, 0)

        row:SetScript("OnEnter", function(self)
            if not self.isSelected then
                self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
            end
            if self.isDungeon or self.statusLabel then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.statusLabel then GameTooltip:AddLine(self.statusLabel, 1, 1, 1) end
                if self.isDungeon then
                    GameTooltip:AddLine("Dungeon quest: " .. (self.dungeonName or "?"), 1, 0.6, 0.3)
                end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self.isSelected then self.bg:SetColorTexture(0, 0, 0, 0) end
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self)
            if zonePopup and zonePopup:IsShown() then zonePopup:Hide() end
            if legendPopup and legendPopup:IsShown() then legendPopup:Hide() end
            list:Select(self.dataIndex)
            Browse.ShowQuest(self.questId, true)
        end)
        return row
    end

    local function UpdateRow(row, item, _, selected)
        row.questId = item.id
        row.isSelected = selected
        row.isDungeon = item.isDungeon
        row.dungeonName = item.zone

        local depth = math.min(item.depth or 0, LIST_MAX_DEPTH)
        local indent = depth * LIST_INDENT

        for level = 1, LIST_MAX_DEPTH do
            local rail = row.rails[level]
            rail:ClearAllPoints()
            if level == depth then
                -- This row's own column: down to the elbow when it is the last follower,
                -- through the row when there are more below it.
                rail:SetPoint("TOP", row, "TOPLEFT", RailX(level), 0)
                rail:SetPoint("BOTTOM", row, item.last and "LEFT" or "BOTTOMLEFT", RailX(level), 0)
                rail:Show()
            elseif level < depth and item.continues and item.continues[level] then
                rail:SetPoint("TOP", row, "TOPLEFT", RailX(level), 0)
                rail:SetPoint("BOTTOM", row, "BOTTOMLEFT", RailX(level), 0)
                rail:Show()
            else
                rail:Hide()
            end
        end

        row.elbow:ClearAllPoints()
        if depth > 0 then
            row.elbow:SetPoint("LEFT", row, "LEFT", RailX(depth), 0)
            row.elbow:SetPoint("RIGHT", row, "LEFT", indent + 4, 0)
            row.elbow:Show()
        else
            row.elbow:Hide()
        end

        row.status:ClearAllPoints()
        row.status:SetPoint("CENTER", row, "LEFT", indent + 12, 0)
        row.level:ClearAllPoints()
        row.level:SetPoint("LEFT", row, "LEFT", indent + 20, 0)

        local status = Source.QuestStatus(item.id)
        Art.SetStatus(row.status, status)
        local statusInfo = Art.StatusInfo(status)
        row.statusLabel = statusInfo and statusInfo.label or nil

        Art.SetFaction(row.faction, item.faction)
        row.name:SetText(item.name)
        row.level:SetText(item.level and tostring(item.level) or "\226\128\147")
        local levelColor = W.LevelColor(item.level)
        row.level:SetTextColor(levelColor[1], levelColor[2], levelColor[3])
        row.dungeon:SetShown(item.isDungeon)

        row.marker:SetShown(selected)
        if selected then
            row.bg:SetColorTexture(theme.raised[1], theme.raised[2], theme.raised[3], 1)
            row.name:SetTextColor(unpack(theme.text))
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
            local color = theme.dim
            if status == "completed" then
                color = theme.faint
            elseif status == "locked" then
                color = Art.StatusInfo("locked").color
            end
            row.name:SetTextColor(color[1], color[2], color[3])
        end
    end

    list = W.ScrollList(view, ROW_HEIGHT, CreateRow, UpdateRow)
    list:SetPoint("TOPLEFT", resultCount, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", PAD, PAD)
    list:SetWidth(LIST_WIDTH)
end

local function BuildChainList(parent)
    local function CreateRow(listParent)
        local row = CreateFrame("Button", nil, listParent)
        row.bg = W.Fill(row, { 0, 0, 0, 0 })

        -- A hairline at the indent position reads as the branch it belongs to without
        -- drawing an entire tree of connectors.
        row.rail = row:CreateTexture(nil, "ARTWORK")
        row.rail:SetWidth(1)
        row.rail:SetColorTexture(unpack(theme.line))

        row.status = Art.StatusIcon(row, 13)
        row.dot = Art.Dot(row, 4, theme.faint)
        row.level = W.Text(row, W.size.tiny, theme.dim, "RIGHT")
        row.level:SetWidth(20)
        row.faction = Art.FactionIcon(row, nil, 11)
        row.name = W.Text(row, W.size.small, theme.text)
        row.name:SetWordWrap(false)
        row.dungeon = Art.Glyph(row, "dungeon", 11, theme.warn)
        row.dungeon:SetPoint("RIGHT", row, "RIGHT", -7, 0)

        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.questName or "", 1, 1, 1)
            if self.statusLabel then
                GameTooltip:AddLine(self.statusLabel, 0.7, 0.7, 0.7)
            end
            if self.dungeonName then
                GameTooltip:AddLine("Dungeon quest: " .. self.dungeonName, 1, 0.6, 0.3)
            end
            GameTooltip:AddLine("Click to show this quest.", 0.5, 0.52, 0.57)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            if not self.isCurrent then self.bg:SetColorTexture(0, 0, 0, 0) end
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self)
            if self.questId then Browse.Open(self.questId) end
        end)
        return row
    end

    local function UpdateRow(row, node)
        row.questId = node.id
        row.questName = node.name
        row.dungeonName = node.isDungeon and node.dungeonName or nil
        row.isCurrent = node.isCurrent

        local indent = node.depth * INDENT_STEP
        row.rail:ClearAllPoints()
        if node.depth > 0 then
            row.rail:Show()
            row.rail:SetPoint("TOP", row, "TOPLEFT", indent - 8, 0)
            row.rail:SetPoint("BOTTOM", row, "BOTTOMLEFT", indent - 8, 0)
        else
            row.rail:Hide()
        end

        local hasArt = Art.SetStatus(row.status, node.status)
        row.status:ClearAllPoints()
        row.status:SetPoint("CENTER", row, "LEFT", indent + 8, 0)
        row.dot:ClearAllPoints()
        row.dot:SetPoint("LEFT", row, "LEFT", indent + 6, 0)
        row.dot:SetShown(not hasArt)

        row.level:ClearAllPoints()
        row.level:SetPoint("LEFT", row, "LEFT", indent + 18, 0)
        row.level:SetText(node.level and tostring(node.level) or "")
        local levelColor = W.LevelColor(node.level)
        row.level:SetTextColor(levelColor[1], levelColor[2], levelColor[3])

        row.faction:ClearAllPoints()
        row.faction:SetPoint("LEFT", row.level, "RIGHT", 5, 0)
        Art.SetFaction(row.faction, node.faction)

        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row.faction, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -22, 0)
        row.name:SetText(node.name)
        row.dungeon:SetShown(node.isDungeon and true or false)

        local statusInfo = Art.StatusInfo(node.status)
        row.statusLabel = statusInfo and statusInfo.label or nil

        if node.isCurrent then
            row.bg:SetColorTexture(theme.raised[1], theme.raised[2], theme.raised[3], 1)
            row.name:SetTextColor(unpack(theme.accent))
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
            local color = theme.text
            if node.status == "completed" then
                color = theme.faint
            elseif node.status == "locked" then
                color = Art.StatusInfo("locked").color
            end
            row.name:SetTextColor(color[1], color[2], color[3])
        end
    end

    chainList = W.ScrollList(parent, CHAIN_ROW_HEIGHT, CreateRow, UpdateRow)
    chainList:Hide()
end

local function BuildDetail(divider)
    detail = CreateFrame("Frame", nil, view)
    detail:SetPoint("TOPLEFT", divider, "TOPRIGHT", 20, 0)
    detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -PAD, PAD)

    backButton = W.Button(detail, "Back", "ghost")
    backButton:SetPoint("TOPLEFT", detail, "TOPLEFT", -8, 6)
    backButton:SetHeight(20)
    backButton:Fit(70)
    local backGlyph = Art.Glyph(backButton, "back", 12, theme.dim)
    backGlyph:SetPoint("RIGHT", backButton.label, "LEFT", -4, 0)
    backButton:SetScript("OnClick", GoBack)
    backButton:Hide()

    detailTitle = W.Text(detail, W.size.h1, theme.text)
    detailTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -24)
    detailTitle:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    detailTitle:SetHeight(22)
    detailTitle:SetWordWrap(false)

    -- The meta line can run long - a status, two levels, a zone and an id - so it is given
    -- two lines and a fixed height. Everything below anchors to the title instead, so a
    -- long meta never pushes the tabs and the preview down the pane.
    detailMeta = W.Text(detail, W.size.small, theme.faint)
    detailMeta:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -2)
    detailMeta:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    detailMeta:SetHeight(28)
    detailMeta:SetJustifyV("TOP")
    if detailMeta.SetMaxLines then detailMeta:SetMaxLines(2) end

    tabs = W.Segmented(detail, {
        { value = "preview", label = "Preview" },
        { value = "chain", label = "Chain" },
    }, function(value) SetTab(value) end)
    tabs:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -42)
    tabs:SetWidth(220)
    tabs:Layout()

    local detailRule = CreateFrame("Frame", nil, detail)
    detailRule:SetHeight(1)
    detailRule:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 0, -8)
    detailRule:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    W.Fill(detailRule, theme.line)

    waypointButton = W.Button(detail, "Waypoint", "primary")
    waypointButton:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", 0, 0)
    waypointButton:SetHeight(28)
    waypointButton:Fit(150)
    waypointButton:SetScript("OnClick", function(self)
        if self.questId then QEF.Waypoint.Go(self.questId) end
    end)
    waypointButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Set a Blizzard waypoint", 1, 1, 1)
        GameTooltip:AddLine("Pins the quest giver on your map and minimap, and supertracks it.",
            0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    waypointButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    waypointButton:Hide()

    -- Always offered, unlike the waypoint: a quest with no recorded giver still has an
    -- article, and that is usually exactly when you want to go and read one.
    wowheadButton = W.Button(detail, "Wowhead", "ghost")
    wowheadButton:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", -8, 0)
    wowheadButton:SetHeight(28)
    wowheadButton:Fit(110)
    local articleGlyph = Art.Glyph(wowheadButton, "article", 12, theme.dim)
    articleGlyph:SetPoint("RIGHT", wowheadButton.label, "LEFT", -4, 0)
    wowheadButton:SetScript("OnClick", function(self)
        if self.questId then QEF.Link.ShowQuest(self.questId) end
    end)
    wowheadButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Open the Wowhead link", 1, 1, 1)
        GameTooltip:AddLine("The client cannot open a browser, so the address comes up in a "
            .. "box to copy.", 0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    wowheadButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    wowheadButton:Hide()

    -- A quest found here is often one you want on the run checklist, and walking over to
    -- the planner to tick the same quest again would be silly.
    -- Kept short. It shares the bottom row with the Wowhead and waypoint buttons, and the
    -- waypoint one grows with the quest giver's name.
    checklistButton = W.Button(detail, "+ Checklist", "ghost")
    checklistButton:SetPoint("LEFT", wowheadButton, "RIGHT", 6, 0)
    checklistButton:SetHeight(28)
    checklistButton:Fit(100)
    checklistButton:SetScript("OnClick", function(self)
        if not self.questId then return end
        local wasEmpty = QEF.Checklist.Count() == 0
        local listed = QEF.Checklist.Toggle(self.questId)
        if listed and wasEmpty then
            QEF.Checklist.SetDungeon(Source.DungeonOf(self.questId))
            QEF.Tracker.Show()
        elseif QEF.Checklist.Count() == 0 then
            QEF.Checklist.SetDungeon(nil)
        end
        Browse.RefreshChecklistButton()
    end)
    checklistButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("The dungeon checklist", 1, 1, 1)
        GameTooltip:AddLine("A strip beside the world listing what you still have to go "
            .. "and pick up, and who to ask for it.", 0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    checklistButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    checklistButton:Hide()

    -- The preview scrolls. Rows wrap to as many lines as their text needs, so a verbose
    -- quest - long objectives, six rewards, a chain and directions - can run past the pane,
    -- and a row that falls off the bottom is a row the player never learns exists.
    detailScroll = CreateFrame("ScrollFrame", nil, detail)
    detailScroll:SetPoint("TOPLEFT", detailRule, "BOTTOMLEFT", 0, -14)
    detailScroll:SetPoint("BOTTOMRIGHT", waypointButton, "TOPRIGHT", 0, 10)

    -- A scroll child is positioned by its scroll frame, so it is sized and left unanchored.
    detailStack = W.RowStack(detailScroll)
    detailStack:SetSize(400, 400)
    detailScroll:SetScrollChild(detailStack)

    -- A scroll child needs a real width, and the row stack measures wrapping against it.
    detailScroll:SetScript("OnSizeChanged", function(self, width)
        if width and width > 1 then detailStack:SetWidth(width) end
    end)

    detailScroll:EnableMouseWheel(true)
    detailScroll:SetScript("OnMouseWheel", function(self, delta)
        local limit = math.max(0, (detailStack:GetHeight() or 0) - (self:GetHeight() or 0))
        local position = (self:GetVerticalScroll() or 0) - delta * 30
        self:SetVerticalScroll(math.min(limit, math.max(0, position)))
    end)

    BuildChainList(detail)
    chainList:SetPoint("TOPLEFT", detailRule, "BOTTOMLEFT", 0, -10)
    chainList:SetPoint("BOTTOMRIGHT", waypointButton, "TOPRIGHT", 0, 10)

    emptyState = W.Text(detail, W.size.body, theme.faint, "CENTER")
    emptyState:SetPoint("CENTER", detail, "CENTER", 0, 20)
    emptyState:SetText("Nothing matches those filters.")
    emptyState:Hide()

    -- Set after the panes exist, so the change handler has something to show and hide.
    tabs:SetValue("preview", true)
    SetTab("preview")
end

local function BuildView(parent)
    view = CreateFrame("Frame", nil, parent)
    view:SetAllPoints(parent)

    local toolbar = BuildToolbar()
    BuildLegend(toolbar)
    BuildList(toolbar)

    local divider = CreateFrame("Frame", nil, view)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", list, "TOPRIGHT", 16, 6)
    divider:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 16, 0)
    W.Fill(divider, theme.line)

    BuildDetail(divider)

    statusText = W.Text(view, W.size.body, theme.faint, "CENTER")
    statusText:SetPoint("CENTER", view, "CENTER", 0, 0)
    statusText:Hide()

    view.OnViewShown = Browse.OnShow
    return view
end

--------------------------------------------------------------------------------------------
-- Controller navigation
--------------------------------------------------------------------------------------------
--
-- Four columns the d-pad moves between: the rail, the toolbar across the top, the results
-- list, and the detail pane. Up and down work inside whichever one you are in; the list and
-- the preview pane only hand the movement on once they have run out of rows to scroll, so a
-- long list behaves like one continuous surface rather than a trap you have to step out of.

local PANE_SCROLL_STEP = 40

local function ListFrameForFocus()
    -- The ring belongs on the selected row, not around the whole list.
    local index = list and list.selected
    if not index then return list end
    local row = list.rows and list.rows[index - (list.offset or 0)]
    return (row and row:IsShown()) and row or list
end

local function ListDirection(action)
    if action ~= "up" and action ~= "down" then return false end
    local item = list:MoveSelection(action == "down" and 1 or -1)
    if not item then return false end
    Browse.ShowQuest(item.id, true)
    return true
end

local function DetailDirection(action)
    if action ~= "up" and action ~= "down" then return false end
    if QEF.Controller.FocusedFrame() ~= detailScroll then return false end
    if not detailScroll:IsShown() then return false end

    local limit = math.max(0, (detailStack:GetHeight() or 0) - (detailScroll:GetHeight() or 0))
    local current = detailScroll:GetVerticalScroll() or 0
    local wanted = current + (action == "down" and PANE_SCROLL_STEP or -PANE_SCROLL_STEP)
    wanted = math.min(limit, math.max(0, wanted))
    if wanted == current then return false end
    detailScroll:SetVerticalScroll(wanted)
    return true
end

--- Hand the controller layer this view's model. Rebuilt on each show, because which
--- controls exist depends on what is selected.
local function RegisterSurface()
    local toolbarItems = {
        { frame = searchBox, hint = "Type a search",
            activate = function() searchBox.edit:SetFocus() end,
            tooltip = "Search quests by name or id" },
        { frame = zoneButton, hint = "Pick a zone" },
        { frame = chipFaction, hint = "Toggle" },
        { frame = chipDungeons, hint = "Toggle" },
        { frame = chipRewards, hint = "Toggle" },
        { frame = legendButton, hint = "What the marks mean" },
    }

    local detailItems = {
        { frame = tabs, hint = "Switch tab", tooltip = "Preview or the whole chain",
            activate = function()
                tabs:SetValue(activeTab == "preview" and "chain" or "preview")
            end },
        { frame = detailScroll, hint = "Scroll", inset = 2,
            tooltip = "The preview - up and down scroll it" },
        { frame = wowheadButton, hint = "Wowhead link" },
        { frame = checklistButton, hint = "Checklist" },
        { frame = waypointButton, hint = "Set a waypoint" },
    }

    QEF.Controller.SetSurface({
        order = { "nav", "toolbar", "list", "detail" },
        start = "list",
        groups = {
            nav = QEF.Window.NavGroup("list"),
            toolbar = { axis = "horizontal", items = toolbarItems,
                down = "list", left = "nav" },
            list = { axis = "vertical", custom = true, inset = 1,
                frame = list, GetFrame = ListFrameForFocus, OnDirection = ListDirection,
                up = "toolbar", left = "nav", right = "detail",
                hint = "Open in the chain tab",
                OnActivate = function()
                    if Browse.shownQuestId then
                        tabs:SetValue("chain")
                        QEF.Controller.Focus("detail", 1)
                    end
                end },
            detail = { axis = "vertical", items = detailItems,
                OnDirection = DetailDirection, up = "toolbar", left = "list" },
        },
        backHint = function() return #history > 0 and "Back" or "Close" end,
        back = function()
            if #history > 0 then
                GoBack()
            else
                QEF.Window.Hide()
            end
        end,
        alt1 = { hint = "Waypoint", run = function()
            if Browse.shownQuestId then QEF.Waypoint.Go(Browse.shownQuestId) end
        end },
        alt2 = { hint = "Wowhead", run = function()
            if Browse.shownQuestId then QEF.Link.ShowQuest(Browse.shownQuestId) end
        end },
    })
end

--------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------

function Browse.OnShow()
    if not Source.available then
        statusText:SetText("QuestieDB is not loaded, so there is no quest list to browse.")
        statusText:Show()
        return
    end

    if Search.ready then
        statusText:Hide()
        if #list.data == 0 then RunQuery() end
        RegisterSurface()
        return
    end

    statusText:SetText("Building the quest index\226\128\166")
    statusText:Show()
    Search.OnProgress = function(progress)
        if progress >= 1 then
            Search.OnProgress = nil
            statusText:Hide()
            RunQuery()
            RegisterSurface()
        else
            statusText:SetText(("Building the quest index\226\128\166 %d%%"):format(progress * 100))
        end
    end
    Search.Ensure()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Browse", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
    Search = QEF.Search
    Render = QEF.Render
    Chain = QEF.Chain
    Source = QEF.Source
    QEF.Window.RegisterView("browse", "Browse quests", BuildView, "browse")

    -- The same quest can be added from the tracker or the planner, so the button follows
    -- the list rather than only its own clicks.
    QEF.Checklist.Subscribe(Browse.RefreshChecklistButton)

    QEF.Controller.OnApplied(function(active)
        if not list then return end
        list:SetRowHeight(active and CONTROLLER_ROW_HEIGHT or ROW_HEIGHT)
    end)
end)
