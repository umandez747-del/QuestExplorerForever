-- Route.lua
--
-- The travel directions as a pop-out window rather than four lines of chat.
--
-- Directions are read once and acted on, which is exactly the thing chat is worst at: by the
-- time you have mounted up they have scrolled away behind someone's trade spam. A small
-- window stays put until you close it, can be dragged next to the map, and closes with
-- Escape like every other Blizzard dialog.
--
-- It is opened by the Waypoint button, and can be turned off in Settings, in which case the
-- directions go back to chat.

local ADDON, QEF = ...

local Route = {}
QEF.Route = Route

local W, theme

local modal, body, destination, footerText
local stepRows = {}

-- The crossing lines are full sentences; at this width they take two lines, not four.
local WIDTH = 480
local SIDE_PAD = 22
local BADGE = 20
local TEXT_WIDTH = WIDTH - SIDE_PAD * 2 - BADGE - 10

--------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------

local function StepRow(index)
    local row = stepRows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, body)

    local badge = CreateFrame("Frame", nil, row)
    badge:SetSize(BADGE, BADGE)
    badge:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    W.Fill(badge, theme.raised)

    row.number = W.Text(badge, W.size.tiny, theme.accent, "CENTER")
    row.number:SetAllPoints(badge)

    row.text = W.Text(row, W.size.small, theme.text)
    row.text:SetPoint("TOPLEFT", badge, "TOPRIGHT", 10, -3)
    row.text:SetWidth(TEXT_WIDTH)
    row.text:SetJustifyH("LEFT")

    stepRows[index] = row
    return row
end

local function Build()
    if modal then return modal end

    modal = W.Window("QuestExplorerForeverRoute", WIDTH, 260, "Getting there")
    -- A step above the windows it is opened from, like the Wowhead and welcome dialogs.
    modal:SetFrameStrata("FULLSCREEN_DIALOG")

    body = CreateFrame("Frame", nil, modal)
    body:SetPoint("TOPLEFT", modal.titleBar, "BOTTOMLEFT", SIDE_PAD, -2)
    body:SetPoint("RIGHT", modal, "RIGHT", -SIDE_PAD, 0)
    body:SetHeight(10)

    destination = W.Text(body, W.size.body, theme.dim)
    destination:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    destination:SetWidth(WIDTH - SIDE_PAD * 2)
    destination:SetJustifyH("LEFT")

    footerText = W.Text(modal, W.size.tiny, theme.faint)
    footerText:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", SIDE_PAD, 18)
    footerText:SetWidth(WIDTH - SIDE_PAD * 2 - 130)
    footerText:SetJustifyH("LEFT")

    -- Turning it off here rather than only in Settings, because here is where someone
    -- decides they did not want it.
    local dismiss = W.Button(modal, "Don't show this", "ghost")
    dismiss:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -16, 14)
    dismiss:SetHeight(24)
    dismiss:Fit(120)
    dismiss:SetScript("OnClick", function()
        QEF.Set("routeWindow", false)
        QEF.Print("travel directions will go to chat from now on - "
            .. "|cfff2c75b/qef routewindow on|r puts the window back")
        Route.Hide()
    end)
    dismiss:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Send directions to chat instead", 1, 1, 1)
        GameTooltip:AddLine("You can switch back in Settings.", 0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    dismiss:SetScript("OnLeave", function() GameTooltip:Hide() end)

    QEF.Controller.AttachDialog(modal)
    return modal
end

--------------------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------------------

--- Show the route to any recorded place: a quest giver, a turn-in NPC, or whoever hands out
--- the quest that is blocking one of yours. The checklist points at all three, so the
--- directions cannot be tied to a quest's own starting NPC.
---@param place table { name, zoneName, uiMapId, x, y }
---@param subtitle string? what these directions are for, shown in the title bar
---@param note string? a line about the map pin, shown in the footer
---@return boolean shown  false when there was nothing to say, so the caller can fall back
function Route.ShowPlace(place, subtitle, note)
    if type(place) ~= "table" or not QEF.Travel then return false end

    local route = QEF.Travel.Route(place.uiMapId, place.zoneName)
    if not route or #route.steps == 0 then return false end

    Build()

    modal.subtitle:SetText(QEF.Clip(subtitle, 40) or "")

    local target = place.name or "the marked spot"
    local zone = place.zoneName
    local coordinates = (place.x and place.y) and ("%.0f, %.0f"):format(place.x, place.y) or nil
    destination:SetText(("%s%s%s%s"):format(
        W.Hex(theme.text) .. target .. "|r",
        zone and (" " .. W.Hex(theme.faint) .. "\226\128\162|r ") or "",
        zone and (W.Hex(theme.dim) .. zone .. "|r") or "",
        coordinates and ("   " .. W.Hex(theme.faint) .. coordinates .. "|r") or ""))

    local y = -(destination:GetStringHeight() or 14) - 14

    for index, step in ipairs(route.steps) do
        local row = StepRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
        row:SetPoint("RIGHT", body, "RIGHT", 0, 0)
        row.number:SetText(tostring(index))
        row.text:SetText(step)
        -- Steps wrap to two or three lines often enough that a fixed row height would
        -- either clip them or leave a gap under every short one.
        local height = math.max(BADGE, (row.text:GetStringHeight() or 12) + 6)
        row:SetHeight(height)
        row:Show()
        y = y - height - 9
    end
    for index = #route.steps + 1, #stepRows do
        stepRows[index]:Hide()
    end

    body:SetHeight(-y)
    footerText:SetText(note or "")

    -- Title bar, body, and a footer row tall enough for however many lines the note took.
    local footerHeight = math.max(14, footerText:GetStringHeight() or 14)
    modal:SetHeight(46 + (-y) + footerHeight + 42)
    modal:FitToScreen()
    modal:Show()
    return true
end

--- Show the route to a quest's starting NPC, which is what the waypoint button wants.
---@param questId number
---@param note string? a line about the map pin, shown in the footer
---@return boolean shown
function Route.Show(questId, note)
    questId = QEF.QuestId(questId)
    if not questId then return false end
    local start = QEF.Source.QuestStart(questId)
    if not start then return false end
    return Route.ShowPlace(start,
        QEF.Source.QuestName(questId) or ("Quest " .. questId), note)
end

function Route.Hide()
    if modal then modal:Hide() end
end

function Route.IsShown()
    return modal ~= nil and modal:IsShown()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Route", function()
    W = QEF.Widgets
    theme = W.theme
end)
