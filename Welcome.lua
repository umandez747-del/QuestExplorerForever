-- Welcome.lua
--
-- The first-run modal: what the addon does, where to look, and the one thing worth doing
-- once up front, which is starting the reward sweep.
--
-- Shown once, a few seconds after the first login so it does not fight the loading screen,
-- and never again unless asked for with /qef welcome. It is dismissable with Escape, it never
-- appears in combat, and it starts nothing without being told to.

local ADDON, QEF = ...

local Welcome = {}
QEF.Welcome = Welcome

local W, theme, Art

local modal

--------------------------------------------------------------------------------------------
-- Content
--------------------------------------------------------------------------------------------

local STEPS = {
    {
        icon = "quest",
        title = "At a quest giver",
        body = "Open any quest giver, or hover an entry in a gossip list. You get the "
            .. "objectives, the rewards with item levels, the experience, and what the rest "
            .. "of the chain leads to.",
    },
    {
        icon = "chain",
        title = "Follow the chain",
        body = "Quest names in a preview are links. Click one to open it, and use Back to "
            .. "retrace. The Chain tab lays a whole chain out from its first quest to its "
            .. "last, marking what you have already done.",
    },
    {
        icon = "waypoint",
        title = "Find the start",
        body = "When a quest is locked behind something else, the preview names what you "
            .. "need first. Waypoint sets a Blizzard map pin on the quest giver.",
    },
    {
        icon = "sweep",
        title = "Build the reward database",
        body = "Rewards are not in any quest database, so they are asked of the server. "
            .. "Run the sweep once and it learns them all, a few quests a second, pausing in "
            .. "combat. You can stop and resume it whenever you like.",
    },
}

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function BuildStep(parent, step, index, previous)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(58)
    row:SetPoint("LEFT", parent, "LEFT", 0, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    if previous then
        row:SetPoint("TOP", previous, "BOTTOM", 0, -14)
    else
        row:SetPoint("TOP", parent, "TOP", 0, 0)
    end

    local badge = CreateFrame("Frame", nil, row)
    badge:SetSize(34, 34)
    badge:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    W.Fill(badge, theme.raised)

    local glyph = Art.Glyph(badge, step.icon, 17, theme.accent)
    glyph:SetPoint("CENTER", badge, "CENTER", 0, 0)

    local number = W.Text(row, W.size.tiny, theme.faint)
    number:SetPoint("TOPLEFT", badge, "BOTTOMLEFT", 0, -4)
    number:SetWidth(34)
    number:SetJustifyH("CENTER")
    number:SetText(tostring(index))

    local title = W.Text(row, W.size.h2, theme.text)
    title:SetPoint("TOPLEFT", badge, "TOPRIGHT", 14, -1)
    title:SetText(step.title)

    local body = W.Text(row, W.size.small, theme.dim)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    body:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    body:SetJustifyH("LEFT")
    body:SetHeight(36)
    body:SetText(step.body)

    return row
end

local function Build()
    if modal then return modal end

    modal = W.Window("QuestExplorerForeverWelcome", 600, 660, "Quest Explorer")
    modal:SetFrameStrata("FULLSCREEN_DIALOG")
    modal.subtitle:SetText(QEF.version)

    local shade = CreateFrame("Frame", nil, UIParent)
    shade:SetAllPoints(UIParent)
    shade:SetFrameStrata("FULLSCREEN")
    shade:EnableMouse(true)
    W.Fill(shade, { 0, 0, 0, 0.45 })
    shade:Hide()
    modal.shade = shade

    local body = CreateFrame("Frame", nil, modal)
    body:SetPoint("TOPLEFT", modal.titleBar, "BOTTOMLEFT", 24, -20)
    body:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -24, 64)

    local lead = W.Text(body, W.size.body, theme.text)
    lead:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    lead:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    lead:SetJustifyH("LEFT")
    lead:SetHeight(32)
    lead:SetText("Shows what a quest involves, what it pays and where its chain ends "
        .. "\226\128\148 before you accept it.")

    local rule = CreateFrame("Frame", nil, body)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", lead, "BOTTOMLEFT", 0, -12)
    rule:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    W.Fill(rule, theme.line)

    local steps = CreateFrame("Frame", nil, body)
    steps:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -18)
    steps:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    steps:SetHeight(300)

    local previous
    for index, step in ipairs(STEPS) do
        previous = BuildStep(steps, step, index, previous)
    end

    ---------------------------------------------------------------- legend
    -- The status marks are the one part of the addon that has to be learned, so they are
    -- taught here rather than left to be discovered by hovering something.
    local legendRule = CreateFrame("Frame", nil, body)
    legendRule:SetHeight(1)
    legendRule:SetPoint("TOPLEFT", steps, "BOTTOMLEFT", 0, -4)
    legendRule:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    W.Fill(legendRule, theme.line)

    local legendLabel = W.SectionLabel(body, "What the marks mean")
    legendLabel:SetPoint("TOPLEFT", legendRule, "BOTTOMLEFT", 0, -14)

    local legend = Art.BuildLegend(body, 2, 552)
    legend:SetPoint("TOPLEFT", legendLabel, "BOTTOMLEFT", -8, -6)

    local hint = W.Text(body, W.size.small, theme.faint)
    hint:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    hint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Open it any time with |cfff2c75b/qef|r. |cfff2c75b/qef help|r lists everything else.")

    ---------------------------------------------------------------- buttons
    local sweepButton = W.Button(modal, "Start the sweep now", "primary")
    sweepButton:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -24, 20)
    sweepButton:SetHeight(30)
    sweepButton:Fit(170)
    sweepButton:SetScript("OnClick", function()
        local started, reason = QEF.Sweep.Start(false)
        if started then
            QEF.Print("sweep started - it will pause in combat and remember where it got to")
        else
            QEF.Print("|cffff8040could not start the sweep|r - " .. (reason or "unknown"))
        end
        Welcome.Hide()
        QEF.Window.Show("sweep")
    end)

    local laterButton = W.Button(modal, "Not now", "ghost")
    laterButton:SetPoint("RIGHT", sweepButton, "LEFT", -8, 0)
    laterButton:SetHeight(30)
    laterButton:Fit(90)
    laterButton:SetScript("OnClick", function() Welcome.Hide() end)

    local tourButton = W.Button(modal, "Open the browser", "ghost")
    tourButton:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", 16, 20)
    tourButton:SetHeight(30)
    tourButton:Fit(140)
    tourButton:SetScript("OnClick", function()
        Welcome.Hide()
        QEF.Window.Show("browse")
    end)

    modal:SetScript("OnHide", function() shade:Hide() end)
    -- Accept dismisses rather than starting the sweep: a tutorial should not be one
    -- accidental button press away from kicking off a long job.
    QEF.Controller.AttachDialog(modal)
    return modal
end

--------------------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------------------

function Welcome.Show()
    Build()
    modal.shade:Show()
    modal:Show()
end

function Welcome.Hide()
    if not modal then return end
    modal:Hide()
    modal.shade:Hide()
end

--- Show it once per installation. The flag is only written when it has actually been shown,
--- so a first login that happens in combat still gets the modal next time.
local function MaybeShowFirstRun()
    if QuestExplorerForeverDB.welcomeSeen then return end
    if InCombatLockdown() then return end
    QuestExplorerForeverDB.welcomeSeen = true
    Welcome.Show()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Welcome", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art

    if QuestExplorerForeverDB.welcomeSeen then return end
    -- Far enough after login that the loading screen and everyone else's start-up chatter
    -- are out of the way.
    C_Timer.After(6, MaybeShowFirstRun)
end)
