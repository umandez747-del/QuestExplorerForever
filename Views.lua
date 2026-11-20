-- Views.lua
--
-- The Sweep and Settings views, plus the floating progress strip that keeps you informed
-- about a sweep while the window is closed.

local ADDON, QEF = ...

local Views = {}
QEF.Views = Views

local W, theme
local Sweep

local PAD = 20

--------------------------------------------------------------------------------------------
-- Shared bits
--------------------------------------------------------------------------------------------

--- One number with a caption under it. Four of these make the sweep's stat row.
local function Stat(parent, caption)
    local stat = CreateFrame("Frame", nil, parent)
    stat:SetHeight(44)
    stat.value = W.Text(stat, 20, theme.text)
    stat.value:SetPoint("TOPLEFT", stat, "TOPLEFT", 0, 0)
    stat.value:SetText("0")
    stat.caption = W.Text(stat, W.size.tiny, theme.faint)
    stat.caption:SetPoint("BOTTOMLEFT", stat, "BOTTOMLEFT", 0, 2)
    stat.caption:SetText(string.upper(caption))
    function stat:Set(value, color)
        self.value:SetText(QEF.Comma(value) or tostring(value))
        local c = color or theme.text
        self.value:SetTextColor(c[1], c[2], c[3])
    end
    return stat
end

local function Duration(seconds)
    if not seconds or seconds < 0 then return nil end
    if seconds < 60 then return ("%ds"):format(math.floor(seconds)) end
    if seconds < 3600 then
        return ("%dm %ds"):format(math.floor(seconds / 60), math.floor(seconds % 60))
    end
    return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

--------------------------------------------------------------------------------------------
-- Sweep view
--------------------------------------------------------------------------------------------

local sweepView, percentText, percentCaption, progressBar, etaText, noteText
local statScanned, statFound, statEmpty, statMissing
local startButton, resetButton, rateControl, coverageText

local function RefreshSweep()
    if not sweepView or not sweepView:IsShown() then return end

    local state = Sweep.state
    local percent = Sweep.Percent()
    percentText:SetText(("%d%%"):format(math.floor(percent)))
    progressBar:SetPercent(percent)

    statScanned:Set(state.cursor)
    statFound:Set(state.found, theme.accent)
    statEmpty:Set(state.empty)
    statMissing:Set(state.missing, state.missing > 0 and theme.warn or nil)

    local known = select(1, Sweep.Coverage())
    coverageText:SetText(("%s of %s quests have an exact answer stored"):format(
        QEF.Comma(known) or known, QEF.Comma(state.total) or state.total))

    if state.running then
        if InCombatLockdown() then
            percentCaption:SetText("paused for combat")
            etaText:SetText("")
        else
            percentCaption:SetText("sweeping")
            local remaining = Sweep.Remaining()
            etaText:SetText(remaining and ("about " .. Duration(remaining) .. " remaining") or "")
        end
        startButton.label:SetText("Pause")
    else
        etaText:SetText("")
        if state.completedAt then
            percentCaption:SetText("complete")
        elseif state.cursor > 0 then
            percentCaption:SetText("paused")
        else
            percentCaption:SetText("not started")
        end
        startButton.label:SetText(state.cursor > 0 and not state.completedAt
            and "Resume" or "Start sweep")
    end

    resetButton:SetEnabledState(state.cursor > 0 or known > 0)
    if QEF.Window.RefreshFooter then QEF.Window.RefreshFooter() end
end

Views.RefreshSweep = RefreshSweep

local function BuildSweepView(parent)
    sweepView = CreateFrame("Frame", nil, parent)
    sweepView:SetAllPoints(parent)

    local heading = W.Text(sweepView, W.size.h1, theme.text)
    heading:SetPoint("TOPLEFT", sweepView, "TOPLEFT", PAD, -PAD)
    heading:SetText("Build the local reward database")

    noteText = W.Text(sweepView, W.size.small, theme.dim)
    noteText:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    noteText:SetPoint("RIGHT", sweepView, "RIGHT", -PAD, 0)
    noteText:SetJustifyH("LEFT")
    noteText:SetHeight(48)
    noteText:SetText("Asks the server about every quest it knows, a few per second, and stores "
        .. "the exact rewards it sends back. These are this realm's own answers, so they are "
        .. "right where a Classic data dump would be wrong. It pauses in combat, and the "
        .. "position is saved, so you can stop and pick it up later.")

    ---------------------------------------------------------------- progress
    percentText = W.Text(sweepView, 38, theme.text)
    percentText:SetPoint("TOPLEFT", noteText, "BOTTOMLEFT", 0, -20)
    percentText:SetText("0%")

    percentCaption = W.Text(sweepView, W.size.small, theme.faint)
    percentCaption:SetPoint("LEFT", percentText, "RIGHT", 10, -2)
    percentCaption:SetText("not started")

    etaText = W.Text(sweepView, W.size.small, theme.faint, "RIGHT")
    etaText:SetPoint("RIGHT", sweepView, "RIGHT", -PAD, 0)
    etaText:SetPoint("TOP", percentCaption, "TOP", 0, 0)

    progressBar = W.ProgressBar(sweepView, 4)
    progressBar:SetPoint("TOPLEFT", percentText, "BOTTOMLEFT", 0, -12)
    progressBar:SetPoint("RIGHT", sweepView, "RIGHT", -PAD, 0)

    ---------------------------------------------------------------- stats
    statScanned = Stat(sweepView, "scanned")
    statFound = Stat(sweepView, "with rewards")
    statEmpty = Stat(sweepView, "experience only")
    statMissing = Stat(sweepView, "no answer")

    local stats = { statScanned, statFound, statEmpty, statMissing }
    for index, stat in ipairs(stats) do
        stat:SetWidth(150)
        if index == 1 then
            stat:SetPoint("TOPLEFT", progressBar, "BOTTOMLEFT", 0, -24)
        else
            stat:SetPoint("TOPLEFT", stats[index - 1], "TOPRIGHT", 20, 0)
        end
    end

    coverageText = W.Text(sweepView, W.size.small, theme.faint)
    coverageText:SetPoint("TOPLEFT", statScanned, "BOTTOMLEFT", 0, -16)

    ---------------------------------------------------------------- controls
    startButton = W.Button(sweepView, "Start sweep", "primary")
    startButton:SetPoint("BOTTOMLEFT", sweepView, "BOTTOMLEFT", PAD, PAD)
    startButton:SetWidth(130)
    startButton:SetHeight(32)
    startButton:SetScript("OnClick", function()
        if Sweep.state.running then
            Sweep.Pause()
        else
            local started, reason = Sweep.Start(false)
            if not started then QEF.Print(reason or "could not start") end
        end
        RefreshSweep()
    end)

    resetButton = W.Button(sweepView, "Clear stored data", "ghost")
    resetButton:SetPoint("LEFT", startButton, "RIGHT", 10, 0)
    resetButton:SetHeight(32)
    resetButton:Fit(140)
    resetButton:SetScript("OnClick", function()
        local cleared = Sweep.Reset()
        QEF.Print(("cleared %s stored reward sets"):format(QEF.Comma(cleared) or cleared))
        RefreshSweep()
    end)

    local rateLabel = W.Text(sweepView, W.size.tiny, theme.faint, "RIGHT")
    rateLabel:SetPoint("BOTTOMRIGHT", sweepView, "BOTTOMRIGHT", -PAD, PAD + 36)
    rateLabel:SetText(string.upper("requests per second"))

    rateControl = W.Segmented(sweepView, {
        { value = 4, label = "Gentle" },
        { value = 8, label = "Normal" },
        { value = 16, label = "Quick" },
    }, function(value) QEF.Set("sweepRate", value) end)
    rateControl:SetPoint("BOTTOMRIGHT", sweepView, "BOTTOMRIGHT", -PAD, PAD + 4)
    rateControl:SetWidth(210)
    rateControl:Layout()
    rateControl:SetValue(QEF.Get("sweepRate"), true)

    sweepView.OnViewShown = RefreshSweep
    return sweepView
end

--------------------------------------------------------------------------------------------
-- Settings view
--------------------------------------------------------------------------------------------

local function BuildSettingsView(parent)
    local settings = CreateFrame("Frame", nil, parent)
    settings:SetAllPoints(parent)

    -- The settings outgrew the window a few features ago. Everything below lives in a
    -- scroll child rather than directly in the page, so a column can be as long as it
    -- needs to be and the rows at the bottom are still reachable on a short screen.
    local scroll = CreateFrame("ScrollFrame", nil, settings)
    scroll:SetPoint("TOPLEFT", settings, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", settings, "BOTTOMRIGHT", -10, 0)

    -- A scroll child is positioned by its scroll frame, so it is sized and left unanchored.
    local content = CreateFrame("Frame", nil, scroll)
    -- The page is built before the window is first shown, so a width of zero here is worth
    -- guarding: a scroll child with no width does not render at all.
    local pageWidth = parent:GetWidth() or 0
    content:SetSize(pageWidth > 1 and pageWidth or 820, 10)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(self, width)
        if width and width > 1 then content:SetWidth(width) end
    end)

    local track = W.ScrollWheel(scroll, content)

    local columnWidth = 390
    local columns = {}

    --- A column of grouped settings rows, laid out top down. No bottom anchor: the column
    --- is as tall as what it holds, which is what the scroll frame measures.
    local function Column(index)
        local column = columns[index]
        if column then return column end
        column = CreateFrame("Frame", nil, content)
        column:SetWidth(columnWidth)
        column:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + (index - 1) * (columnWidth + 30), -PAD)
        column:SetHeight(10)
        column.y = 0
        columns[index] = column
        return column
    end

    local function Section(columnIndex, title)
        local column = Column(columnIndex)
        if column.y ~= 0 then column.y = column.y - 18 end
        local label = W.SectionLabel(column, title)
        label:SetPoint("TOPLEFT", column, "TOPLEFT", 0, column.y)
        column.y = column.y - 20
        local rule = column:CreateTexture(nil, "ARTWORK")
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", column, "TOPLEFT", 0, column.y + 6)
        rule:SetPoint("TOPRIGHT", column, "TOPRIGHT", 0, column.y + 6)
        rule:SetColorTexture(unpack(theme.line))
        column.y = column.y - 6
    end

    local function ToggleRow(columnIndex, key, label, description)
        local column = Column(columnIndex)
        local row = W.Row(column, label, description)
        row:SetPoint("TOPLEFT", column, "TOPLEFT", 0, column.y)
        row:SetPoint("RIGHT", column, "RIGHT", 0, 0)
        local toggle = W.Toggle(row, function(value)
            QEF.Set(key, value)
            -- Ordering and filtering settings change the list itself, not just the preview
            -- drawn beside it, so those re-run the query.
            if key == "chainOrder" and QEF.Browse and QEF.Browse.Requery then
                QEF.Browse.Requery()
            elseif key == "frameArt" then
                QEF.Widgets.RefreshFrameArt()
            elseif key == "minimap" and QEF.MinimapButton then
                QEF.MinimapButton.Update()
            elseif (key == "mapAvailable" or key == "hideBlizzardPins") and QEF.MapPins then
                QEF.MapPins.Refresh()
            elseif key == "questLog" and QEF.Hooks and QEF.Hooks.RefreshLog then
                QEF.Hooks.RefreshLog()
            elseif key == "panelAttach" then
                QEF.Panel.Redraw()
            elseif key == "guide" and QEF.Guide then
                -- Starting and stopping does more than store the setting: it places the
                -- marker, or takes ours away again.
                if value then QEF.Guide.Start() else QEF.Guide.Stop() end
            elseif (key == "tracker" or key == "trackerSteps" or key == "walkOrder")
                and QEF.Tracker then
                QEF.Tracker.Update()
                if key == "walkOrder" and QEF.Guide then QEF.Guide.Refresh(true) end
            elseif QEF.Browse and QEF.Browse.Refresh then
                QEF.Browse.Refresh()
            end
        end)
        toggle:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        toggle:SetValue(QEF.Get(key) and true or false, true)
        column.y = column.y - row:GetHeight() - 2
        return row
    end

    local function SegmentedRow(columnIndex, key, label, options)
        local column = Column(columnIndex)
        local row = W.Row(column, label)
        row:SetHeight(52)
        row:SetPoint("TOPLEFT", column, "TOPLEFT", 0, column.y)
        row:SetPoint("RIGHT", column, "RIGHT", 0, 0)
        row.label:ClearAllPoints()
        row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)

        local control = W.Segmented(row, options, function(value)
            QEF.Set(key, value)
            -- The controller settings change the layout itself, so they take effect now
            -- rather than on the next reload.
            if key == "controller" or key == "controllerLabels" then
                QEF.Controller.Resolve()
                QEF.Controller.Apply()
            elseif (key == "mapPins" or key == "pinStyle") and QEF.MapPins then
                QEF.MapPins.Refresh()
            end
        end)
        control:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
        control:SetWidth(240)
        control:Layout()
        control:SetValue(QEF.Get(key), true)
        column.y = column.y - row:GetHeight() - 2
        return row
    end

    Section(1, "Where the preview appears")
    SegmentedRow(1, "mode", "Display", {
        { value = "tooltip", label = "Tooltip" },
        { value = "panel", label = "Panel" },
        { value = "both", label = "Both" },
    })
    SegmentedRow(1, "verbosity", "Detail", {
        { value = 1, label = "Brief" },
        { value = 2, label = "Normal" },
        { value = 3, label = "Everything" },
    })
    ToggleRow(1, "frameArt", "Painted window frames",
        "Gold corners and a divider, or plain hairlines")
    ToggleRow(1, "minimap", "Minimap button",
        "Click to open, right-click for settings, drag to move it")
    ToggleRow(1, "questie", "Questie map icons", "Add the preview to Questie's tooltips")
    ToggleRow(1, "questLog", "Beside the quest log",
        "The panel for whichever quest the log has open")
    ToggleRow(1, "panelAttach", "Attach the panel",
        "Flush against the frame, sharing its edge, rather than floating")
    ToggleRow(1, "chainOrder", "Group the list into chains",
        "Indent each quest under the one it follows")
    ToggleRow(1, "enabled", "Enabled")

    Section(1, "Controller")
    SegmentedRow(1, "controller", "Controller layout", {
        { value = "auto", label = "Auto" },
        { value = "on", label = "On" },
        { value = "off", label = "Off" },
    })
    SegmentedRow(1, "controllerLabels", "Button names", {
        { value = "xbox", label = "A B X Y" },
        { value = "playstation", label = "PlayStation" },
    })

    Section(2, "What it shows")
    ToggleRow(2, "showObjectives", "Objectives")
    ToggleRow(2, "showRewards", "Rewards")
    ToggleRow(2, "showChain", "Chain and final rewards")
    ToggleRow(2, "showDungeonGate", "Dungeon gating")
    ToggleRow(2, "showReputation", "Reputation")
    ToggleRow(2, "showQuestIds", "Quest ids")

    Section(2, "Data")
    ToggleRow(2, "liveLookahead", "Ask the server",
        "Look up quests further along a chain")
    ToggleRow(2, "learn", "Remember answers")
    ToggleRow(2, "sweepToast", "Show sweep progress when closed")
    ToggleRow(2, "showTravel", "Travel directions",
        "How to reach a quest giver on another continent")
    ToggleRow(2, "routeWindow", "Directions in a window",
        "Pop them out when you set a waypoint, instead of chat")

    Section(2, "Dungeon checklist")
    ToggleRow(2, "tracker", "Show it on screen",
        "The strip beside the world, while the list has anything on it")
    ToggleRow(2, "trackerSteps", "Name the quest givers",
        "A line under each step saying who to talk to, or what is in the way")
    ToggleRow(2, "guide", "Mark the step you are on",
        "The game's own marker, moved on when a step is done")
    ToggleRow(2, "walkOrder", "Order this zone as a walk",
        "Nearest step first, then nearest to that, where you are standing")
    ToggleRow(2, "mapAvailable", "Pin quests beyond the list",
        "The ones you are carrying and the ones the zone has going spare")
    ToggleRow(2, "hideBlizzardPins", "Hide the game's own quest pins",
        "While ours are drawn, so one turn-in is not marked twice")
    SegmentedRow(2, "pinStyle", "Pin style", {
        { value = "slate", label = "Slate" },
        { value = "blue", label = "Blue" },
        { value = "parchment", label = "Old" },
        { value = "gem", label = "Gem" },
        { value = "green", label = "Green" },
    })
    SegmentedRow(2, "mapPins", "Pins on the world map", {
        { value = "auto", label = "Auto" },
        { value = "on", label = "On" },
        { value = "off", label = "Off" },
    })

    -- Measured once, now that every row has been added: each column is as tall as it ended
    -- up, and the scroll child as tall as the longest of them.
    local tallest = 0
    for _, column in pairs(columns) do
        local used = -column.y + PAD
        column:SetHeight(math.max(10, used))
        if used > tallest then tallest = used end
    end
    content:SetHeight(tallest + PAD)

    -- The window can be rescaled by FitToScreen after this, so the indicator is refreshed
    -- on every open rather than only here.
    settings.OnViewShown = function() track:Update() end
    track:Update()

    return settings
end

--------------------------------------------------------------------------------------------
-- Floating progress strip
--------------------------------------------------------------------------------------------

local toast

local function BuildToast()
    if toast then return toast end

    toast = CreateFrame("Button", "QuestExplorerForeverSweepToast", UIParent)
    toast:SetSize(230, 38)
    toast:SetFrameStrata("MEDIUM")
    toast:SetClampedToScreen(true)
    toast:SetMovable(true)
    toast:RegisterForDrag("LeftButton")
    toast:Hide()

    W.Fill(toast, { theme.bg[1], theme.bg[2], theme.bg[3], 0.92 })
    W.Outline(toast, theme.line)

    toast.label = W.Text(toast, W.size.small, theme.dim)
    toast.label:SetPoint("TOPLEFT", toast, "TOPLEFT", 12, -9)
    toast.label:SetText("Sweeping quests")

    toast.percent = W.Text(toast, W.size.small, theme.accent, "RIGHT")
    toast.percent:SetPoint("TOPRIGHT", toast, "TOPRIGHT", -12, -9)

    toast.bar = W.ProgressBar(toast, 2)
    toast.bar:SetPoint("BOTTOMLEFT", toast, "BOTTOMLEFT", 12, 9)
    toast.bar:SetPoint("BOTTOMRIGHT", toast, "BOTTOMRIGHT", -12, 9)

    toast:SetScript("OnDragStart", function(self) self:StartMoving() end)
    toast:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        QuestExplorerForeverDB.toastPoint = { point = point, x = x, y = y }
    end)
    toast:SetScript("OnClick", function() QEF.Window.Show("sweep") end)
    toast:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Quest Explorer", 1, 1, 1)
        GameTooltip:AddLine("Building the local reward database.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Click to open, drag to move.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    toast:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local saved = QuestExplorerForeverDB.toastPoint
    toast:ClearAllPoints()
    if saved and saved.point then
        toast:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
    else
        toast:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -30, -220)
    end
    return toast
end

local function RefreshToast()
    local state = Sweep.state
    local shouldShow = state.running and QEF.Get("sweepToast")
        and not (QEF.Window.IsShown() and QEF.Window.frame)

    if not shouldShow then
        if toast then toast:Hide() end
        return
    end

    BuildToast()
    local percent = Sweep.Percent()
    toast.percent:SetText(("%d%%"):format(math.floor(percent)))
    toast.bar:SetPercent(percent)
    toast.label:SetText(InCombatLockdown() and "Sweep paused for combat" or "Sweeping quests")
    toast:Show()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Views", function()
    W = QEF.Widgets
    theme = W.theme
    Sweep = QEF.Sweep

    QEF.Window.RegisterView("sweep", "Reward sweep", BuildSweepView, "sweep")
    QEF.Window.RegisterView("settings", "Settings", BuildSettingsView, "settings")

    Sweep.OnProgress = function()
        RefreshSweep()
        RefreshToast()
    end

    -- A sweep answer can change what the browser is showing.
    local previousUpdate = QEF.Rewards.OnUpdate
    QEF.Rewards.OnUpdate = function(questId)
        if previousUpdate then previousUpdate(questId) end
        if QEF.Browse and QEF.Browse.Refresh then QEF.Browse.Refresh() end
    end
end)
