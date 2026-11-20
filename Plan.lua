-- Plan.lua
--
-- The run planner: pick a dungeon on the left, tick the quests you want on the right, and
-- the tracker beside the game world fills in with where to go and get them.
--
-- The quest list here is the browser's index filtered to one dungeon, so a dungeon's quests
-- means "quests whose zone is that dungeon" - which is how the game files group them, and
-- includes the ones handed out in the world a long way from the entrance. Those are exactly
-- the ones people miss, so they are the point of the whole page.

local ADDON, QEF = ...

local Plan = {}
QEF.Plan = Plan

local W, theme, Art, Search, Source, Checklist

local LIST_WIDTH = 260
local ROW_HEIGHT = 28
local PAD = 20

local view, dungeonList, questList, statusText, hintText
local headerText, subText, addButton, clearButton, trackerToggle
local selectedDungeon, currentResults = nil, {}
local dungeonFilter = ""
local waitTicker

--------------------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------------------

local function DungeonItems()
    local items = {}
    local needle = dungeonFilter ~= "" and dungeonFilter:lower() or nil
    for _, name in ipairs(Search.dungeonList) do
        if not needle or name:lower():find(needle, 1, true) then
            items[#items + 1] = { name = name, count = Search.dungeonCounts[name] or 0 }
        end
    end
    return items
end

--- How many of this dungeon's quests are on the list, and how many are still to fetch.
local function Tally()
    local listed, outstanding = 0, 0
    for _, entry in ipairs(currentResults) do
        if Checklist.Has(entry.id) then
            listed = listed + 1
            if not Checklist.IsDone(entry.id) then outstanding = outstanding + 1 end
        end
    end
    return listed, outstanding
end

local function RefreshHeader()
    if not selectedDungeon then
        headerText:SetText("Pick a dungeon")
        subText:SetText("Its quests appear here, including the ones given out in the world.")
        addButton:Hide()
        clearButton:Hide()
        return
    end
    headerText:SetText(selectedDungeon)
    local listed = Tally()
    subText:SetText(("%d quest%s - %d on your checklist"):format(
        #currentResults, #currentResults == 1 and "" or "s", listed))
    addButton:Show()
    clearButton:Show()
end

local function RefreshRows()
    if questList then questList:Refresh() end
    RefreshHeader()
end

local function LoadDungeon(name)
    selectedDungeon = name
    currentResults = Search.Query({
        zone = name,
        dungeonsOnly = true,
        -- The other faction's quests cannot be picked up at all, so they are never part of
        -- a plan. Unlike the browser there is no chip to put them back.
        myFaction = Art.PlayerFaction() ~= nil,
    })
    questList:SetData(currentResults)
    RefreshHeader()
end

--------------------------------------------------------------------------------------------
-- Opening on a named dungeon
--------------------------------------------------------------------------------------------

local pendingDungeon

--- Loosely: "wailing" finds Wailing Caverns. An exact name always wins over a partial one,
--- so a dungeon whose name is contained in another's is still reachable by typing it out.
local function MatchDungeon(needle)
    local partial
    for _, name in ipairs(Search.dungeonList) do
        local lowered = name:lower()
        if lowered == needle then return name end
        if not partial and lowered:find(needle, 1, true) then partial = name end
    end
    return partial
end

local function ApplyPending()
    if not pendingDungeon or not dungeonList then return false end
    local match = MatchDungeon(pendingDungeon)
    pendingDungeon = nil
    if not match then return false end

    -- A filter left in the box could hide the dungeon that was just asked for.
    dungeonFilter = ""
    local items = DungeonItems()
    dungeonList:SetData(items)
    for index, item in ipairs(items) do
        if item.name == match then
            dungeonList:Select(index)
            break
        end
    end
    LoadDungeon(match)
    return true
end

--- Open the planner on a dungeon by name. Returns false only when the index is ready and
--- nothing matched; before that the name is held and applied once the index finishes.
---@param name string
---@return boolean found
function Plan.Open(name)
    local needle = (QEF.Str(name) or ""):lower()
    if needle == "" then return false end
    pendingDungeon = needle
    if not Search.ready then return true end
    if not dungeonList then return true end
    return ApplyPending()
end

--------------------------------------------------------------------------------------------
-- Left list: dungeons
--------------------------------------------------------------------------------------------

local function CreateDungeonRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.bg = W.Fill(row, { 0, 0, 0, 0 })
    row.marker = row:CreateTexture(nil, "ARTWORK")
    row.marker:SetWidth(2)
    row.marker:SetPoint("TOPLEFT")
    row.marker:SetPoint("BOTTOMLEFT")
    row.marker:SetColorTexture(unpack(theme.accent))
    row.marker:Hide()

    row.label = W.Text(row, W.size.body, theme.text)
    row.label:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.label:SetWordWrap(false)

    row.count = W.Text(row, W.size.tiny, theme.faint, "RIGHT")
    row.count:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.label:SetPoint("RIGHT", row.count, "LEFT", -6, 0)

    row:SetScript("OnEnter", function(self)
        if self.selected then return end
        self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 0.5)
    end)
    row:SetScript("OnLeave", function(self)
        if self.selected then return end
        self.bg:SetColorTexture(0, 0, 0, 0)
    end)
    row:SetScript("OnClick", function(self)
        if not self.item then return end
        dungeonList:Select(self.dataIndex)
        LoadDungeon(self.item.name)
    end)
    return row
end

local function UpdateDungeonRow(row, item, _, selected)
    row.item = item
    row.selected = selected
    row.label:SetText(item.name)
    row.count:SetText(item.count)
    row.marker:SetShown(selected)
    if selected then
        row.bg:SetColorTexture(theme.raised[1], theme.raised[2], theme.raised[3], 1)
        row.label:SetTextColor(unpack(theme.text))
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
        row.label:SetTextColor(unpack(theme.dim))
    end
end

--------------------------------------------------------------------------------------------
-- Right list: quests, with a box each
--------------------------------------------------------------------------------------------

local function CreateQuestRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.bg = W.Fill(row, { 0, 0, 0, 0 })

    row.box = row:CreateTexture(nil, "ARTWORK")
    row.box:SetSize(13, 13)
    row.box:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.box:SetColorTexture(unpack(theme.raised))

    row.boxEdge = row:CreateTexture(nil, "BORDER")
    row.boxEdge:SetSize(15, 15)
    row.boxEdge:SetPoint("CENTER", row.box, "CENTER")
    row.boxEdge:SetColorTexture(unpack(theme.line))

    row.tick = row:CreateTexture(nil, "OVERLAY")
    row.tick:SetTexture(Art.status.completed.texture)
    row.tick:SetSize(13, 13)
    row.tick:SetPoint("CENTER", row.box, "CENTER")
    row.tick:Hide()

    row.level = W.Text(row, W.size.tiny, theme.faint, "RIGHT")
    row.level:SetWidth(22)
    row.level:SetPoint("LEFT", row.box, "RIGHT", 8, 0)

    row.status = Art.StatusIcon(row, 11)
    row.status:SetPoint("LEFT", row.level, "RIGHT", 6, 0)

    row.label = W.Text(row, W.size.body, theme.text)
    row.label:SetPoint("LEFT", row.status, "RIGHT", 5, 0)
    row.label:SetWordWrap(false)

    row.note = W.Text(row, W.size.tiny, theme.faint, "RIGHT")
    row.note:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.label:SetPoint("RIGHT", row.note, "LEFT", -8, 0)

    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 0.5)
    end)
    row:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0, 0, 0, 0)
    end)
    row:SetScript("OnClick", function(self)
        if not self.item then return end
        Plan.Toggle(self.item.id)
    end)
    return row
end

local function UpdateQuestRow(row, item)
    row.item = item
    row.label:SetText(item.name)
    row.level:SetText(item.level and tostring(item.level) or "")
    if item.level then
        row.level:SetTextColor(unpack(W.LevelColor(item.level)))
    end

    local status = Source.QuestStatus(item.id)
    local hasArt = Art.SetStatus(row.status, status)
    row.status:SetShown(hasArt)

    local listed = Checklist.Has(item.id)
    row.tick:SetShown(listed)
    row.box:SetColorTexture(unpack(listed and theme.accentDim or theme.raised))

    -- A quest you already hold or have finished can go on the list, but saying so up front
    -- saves the player ticking something that is already dealt with.
    local info = Art.StatusInfo(status)
    row.note:SetText(info and info.short or "")
    row.label:SetTextColor(unpack(listed and theme.text or theme.dim))
end

--- Put a quest on the list or take it off, keeping the dungeon name in step.
---@param questId number
function Plan.Toggle(questId)
    local wasEmpty = Checklist.Count() == 0
    local nowListed = Checklist.Toggle(questId)
    if nowListed and wasEmpty and selectedDungeon then
        Checklist.SetDungeon(selectedDungeon)
    elseif Checklist.Count() == 0 then
        Checklist.SetDungeon(nil)
    end
    RefreshRows()
end

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function BuildLeft()
    local search = W.SearchBox(view, "Filter dungeons", function(text)
        dungeonFilter = text or ""
        dungeonList:SetData(DungeonItems())
    end)
    search:SetPoint("TOPLEFT", view, "TOPLEFT", PAD, -PAD)
    search:SetWidth(LIST_WIDTH)

    dungeonList = W.ScrollList(view, ROW_HEIGHT, CreateDungeonRow, UpdateDungeonRow)
    dungeonList:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -10)
    dungeonList:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", PAD, PAD)
    dungeonList:SetWidth(LIST_WIDTH)
end

local function BuildRight()
    local divider = CreateFrame("Frame", nil, view)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", dungeonList, "TOPRIGHT", 16, 6)
    divider:SetPoint("BOTTOMLEFT", dungeonList, "BOTTOMRIGHT", 16, 0)
    W.Fill(divider, theme.line)

    -- The right hand quarter is the controls, so the heading and its line below are clamped
    -- well clear of them: a dungeon name with nothing stopping it would run straight under
    -- the switch.
    local CONTROL_SPACE = 260

    headerText = W.Text(view, W.size.h2, theme.text)
    headerText:SetPoint("TOPLEFT", divider, "TOPRIGHT", 18, -4)
    headerText:SetPoint("RIGHT", view, "RIGHT", -CONTROL_SPACE, 0)
    headerText:SetHeight(20)
    headerText:SetWordWrap(false)

    subText = W.Text(view, W.size.small, theme.faint)
    subText:SetPoint("TOPLEFT", headerText, "BOTTOMLEFT", 0, -5)
    subText:SetPoint("RIGHT", view, "RIGHT", -CONTROL_SPACE, 0)
    subText:SetHeight(16)
    subText:SetWordWrap(false)

    trackerToggle = W.Toggle(view, function(value)
        QEF.Set("tracker", value)
        QEF.Tracker.Update()
    end)
    trackerToggle:SetPoint("TOPRIGHT", view, "TOPRIGHT", -PAD, -PAD - 2)

    local toggleLabel = W.Text(view, W.size.small, theme.dim, "RIGHT")
    toggleLabel:SetPoint("RIGHT", trackerToggle, "LEFT", -8, 0)
    toggleLabel:SetText("Show the checklist on screen")

    addButton = W.Button(view, "Add what is left", "primary")
    addButton:SetWidth(140)
    addButton:SetPoint("TOPRIGHT", view, "TOPRIGHT", -PAD, -46)
    addButton:SetScript("OnClick", function()
        if not selectedDungeon then return end
        local added = Checklist.AddAll(selectedDungeon, currentResults)
        if added == 0 then
            QEF.Print("nothing left to add for " .. selectedDungeon
                .. " - every quest here is already on the list or already yours")
        else
            QEF.Print(("added %d quest%s for %s"):format(
                added, added == 1 and "" or "s", selectedDungeon))
            -- Adding a list and not seeing it would be baffling, so this turns the strip
            -- back on; the switch beside the button has to follow it.
            QEF.Tracker.Show()
            trackerToggle:SetValue(true, true)
            -- A list that does not appear on the map looks broken rather than deferential.
            if QEF.MapPins then QEF.MapPins.HintIfSuppressed() end
        end
        RefreshRows()
    end)

    clearButton = W.Button(view, "Clear the list", "ghost")
    clearButton:SetWidth(110)
    clearButton:SetPoint("RIGHT", addButton, "LEFT", -8, 0)
    clearButton:SetScript("OnClick", function()
        local removed = Checklist.Clear()
        QEF.Print(("checklist cleared (%d quest%s)"):format(
            removed, removed == 1 and "" or "s"))
        RefreshRows()
    end)

    questList = W.ScrollList(view, ROW_HEIGHT, CreateQuestRow, UpdateQuestRow)
    questList:SetPoint("TOPLEFT", divider, "TOPRIGHT", 12, -62)
    questList:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -PAD, PAD + 20)

    hintText = W.Text(view, W.size.tiny, theme.faint)
    hintText:SetPoint("BOTTOMLEFT", questList, "BOTTOMLEFT", 6, -16)
    hintText:SetText("Click a quest to put it on the checklist. "
        .. "Quests for the other faction are left out.")
end

local function BuildView(parent)
    view = CreateFrame("Frame", nil, parent)
    view:SetAllPoints(parent)

    BuildLeft()
    BuildRight()

    statusText = W.Text(view, W.size.body, theme.faint, "CENTER")
    statusText:SetPoint("CENTER", view, "CENTER", 0, 0)
    statusText:Hide()

    view.OnViewShown = Plan.OnShow
    return view
end

--------------------------------------------------------------------------------------------
-- Controller navigation
--------------------------------------------------------------------------------------------

local function DungeonFrameForFocus()
    local index = dungeonList and dungeonList.selected
    if not index then return dungeonList end
    local row = dungeonList.rows and dungeonList.rows[index - (dungeonList.offset or 0)]
    return (row and row:IsShown()) and row or dungeonList
end

local function QuestFrameForFocus()
    local index = questList and questList.selected
    if not index then return questList end
    local row = questList.rows and questList.rows[index - (questList.offset or 0)]
    return (row and row:IsShown()) and row or questList
end

local function DungeonDirection(action)
    if action ~= "up" and action ~= "down" then return false end
    local item = dungeonList:MoveSelection(action == "down" and 1 or -1)
    if not item then return false end
    LoadDungeon(item.name)
    return true
end

local function QuestDirection(action)
    if action ~= "up" and action ~= "down" then return false end
    return questList:MoveSelection(action == "down" and 1 or -1) ~= nil
end

local function RegisterSurface()
    QEF.Controller.SetSurface({
        order = { "nav", "dungeons", "quests", "actions" },
        start = "dungeons",
        groups = {
            nav = QEF.Window.NavGroup("dungeons"),
            dungeons = { axis = "vertical", custom = true, inset = 1,
                frame = dungeonList, GetFrame = DungeonFrameForFocus,
                OnDirection = DungeonDirection, left = "nav", right = "quests",
                hint = "Open this dungeon" },
            quests = { axis = "vertical", custom = true, inset = 1,
                frame = questList, GetFrame = QuestFrameForFocus,
                OnDirection = QuestDirection, left = "dungeons", up = "actions",
                hint = "Put it on the checklist",
                OnActivate = function()
                    local item = questList:SelectedItem()
                    if item then Plan.Toggle(item.id) end
                end },
            actions = { axis = "horizontal", down = "quests", left = "dungeons",
                items = {
                    { frame = clearButton, hint = "Clear the checklist" },
                    { frame = addButton, hint = "Add what is left" },
                    { frame = trackerToggle, hint = "Show or hide the checklist" },
                } },
        },
        backHint = "Close",
        back = function() QEF.Window.Hide() end,
    })
end

--------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------

local function Populate()
    statusText:Hide()
    trackerToggle:SetValue(QEF.Get("tracker") and true or false, true)
    dungeonList:SetData(DungeonItems())
    if not ApplyPending() then
        if selectedDungeon then
            LoadDungeon(selectedDungeon)
        else
            RefreshHeader()
        end
    end
    RegisterSurface()
end

function Plan.OnShow()
    if not Source.available then
        statusText:SetText("QuestieDB is not loaded, so there is no dungeon list to plan from.")
        statusText:Show()
        return
    end

    if Search.ready then
        Populate()
        return
    end

    -- The browser owns Search.OnProgress while it is building, so this page watches for the
    -- index instead of hooking it, and the two pages never fight over the callback.
    statusText:SetText("Building the quest index\226\128\166")
    statusText:Show()
    Search.Ensure()
    if waitTicker then return end
    waitTicker = C_Timer.NewTicker(0.5, function()
        if not Search.ready then return end
        if waitTicker then waitTicker:Cancel() waitTicker = nil end
        if view and view:IsShown() then Populate() end
    end)
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Plan", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
    Search = QEF.Search
    Source = QEF.Source
    Checklist = QEF.Checklist

    QEF.Window.RegisterView("plan", "Dungeon runs", BuildView, "checklist")

    -- The tracker and this page edit the same list, so each redraws when the other does.
    Checklist.Subscribe(function()
        if not view or not view:IsShown() then return end
        if trackerToggle then trackerToggle:SetValue(QEF.Get("tracker") and true or false, true) end
        RefreshRows()
    end)
end)
