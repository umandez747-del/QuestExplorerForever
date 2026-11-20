-- Tracker.lua
--
-- The run list as a narrow strip beside the game world: one line per step, grouped by the
-- zone you have to be standing in, with who to talk to underneath.
--
-- It is deliberately not a second quest log. Each quest shows the one thing it needs next -
-- pick it up, finish it, hand it in, or clear what is blocking it - and as the quest's state
-- changes the line changes with it. Finished quests drop to a single line at the bottom, and
-- the whole strip hides itself when the list is empty rather than sitting there as a box
-- with nothing in it.
--
-- Clicking: a step line puts the game's marker on it, its box ticks the quest off by hand,
-- right-clicking takes the quest off the list, a zone heading opens the travel directions
-- for that zone, and the finished line clears the finished quests away.

local ADDON, QEF = ...

local Tracker = {}
QEF.Tracker = Tracker

local W, theme, Art, Checklist, Guide

local WIDTH = 250
local PAD = 10
local HEADER_HEIGHT = 26
local FOOTER_HEIGHT = 18
local CHECK = 13
local GLYPH = 11
-- Past this the strip stops being something you glance at, so the rest is summarised in one
-- line rather than drawn. A dungeon rarely has this many steps outstanding anyway.
local MAX_ROWS = 18

-- Which mark each kind of step carries. The gossip icons are the ones the game already uses
-- for "there is a quest here" and "hand it in here", so they need no explaining.
local KIND_GLYPH = {
    pickup = "quest",    -- the ! an available quest has over its giver
    turnin = "active",   -- the ? a quest ready to hand in has
    blocked = "locked",
    finish = "waiting",  -- the ready-check hourglass: under way, not finished
}

local frame, body, titleText, progressText, footerText
local rows = {}
local refreshQueued = false

-- Forward declarations: the click handlers read the row model, which is built further down,
-- but the rows have to be wired the moment they are created.
local OnRowClick, OnCheckClick, OnRowEnter

--------------------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------------------

local function CreateRow()
    local row = CreateFrame("Button", nil, body)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetPoint("LEFT", body, "LEFT", 0, 0)
    row:SetPoint("RIGHT", body, "RIGHT", 0, 0)

    row.highlight = W.Fill(row, { theme.hover[1], theme.hover[2], theme.hover[3], 0 })

    -- The accent bar marks the step the game's marker is pointing at.
    row.marker = row:CreateTexture(nil, "ARTWORK")
    row.marker:SetWidth(2)
    row.marker:SetPoint("TOPLEFT", row, "TOPLEFT", -PAD + 2, 0)
    row.marker:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", -PAD + 2, 0)
    row.marker:SetColorTexture(unpack(theme.accent))
    row.marker:Hide()

    row.check = CreateFrame("Button", nil, row)
    row.check:SetSize(CHECK, CHECK)
    row.check:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    row.check.bg = W.Fill(row.check, theme.raised)
    W.Outline(row.check, theme.line)
    row.check.mark = row.check:CreateTexture(nil, "OVERLAY")
    row.check.mark:SetTexture(Art.status.completed.texture)
    row.check.mark:SetPoint("CENTER")
    row.check.mark:SetSize(CHECK - 1, CHECK - 1)
    row.check.mark:Hide()

    -- One texture reused for every kind of mark a row can carry, retextured per row rather
    -- than one hidden texture per kind.
    row.glyph = row:CreateTexture(nil, "ARTWORK")
    row.glyph:SetSize(GLYPH, GLYPH)
    row.glyph:SetPoint("TOPLEFT", row, "TOPLEFT", CHECK + 5, -1)
    row.glyph:Hide()

    row.text = W.Text(row, W.size.small, theme.text)
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.text:SetJustifyV("TOP")

    row.right = W.Text(row, W.size.tiny, theme.faint, "RIGHT")
    row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -1)

    row:SetScript("OnEnter", function(self)
        if not self.clickable then return end
        self.highlight:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 0.6)
        OnRowEnter(self)
    end)
    row:SetScript("OnLeave", function(self)
        self.highlight:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 0)
        GameTooltip:Hide()
    end)

    row:SetScript("OnClick", function(self, button) OnRowClick(self, button) end)
    row.check:SetScript("OnClick", function(self) OnCheckClick(self) end)

    return row
end

--- Put the kind mark on a row, as a tinted monochrome glyph. Done here rather than through
--- Art.Glyph because the texture is reused, and the crop differs between interface art and
--- icon art.
local function SetGlyph(row, iconName, color)
    if not iconName then
        row.glyph:Hide()
        return 0
    end
    local path = Art.icon[iconName]
    row.glyph:SetTexture(path)
    row.glyph:SetDesaturated(true)
    -- Spell and item icons carry a border in their outer pixels and want cropping; the
    -- interface art the step marks come from has none and would be cut by it.
    if path and path:find("\\Icons\\", 1, true) then
        row.glyph:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    else
        row.glyph:SetTexCoord(0, 1, 0, 1)
    end
    row.glyph:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    row.glyph:Show()
    return GLYPH + 4
end

--- Lay one row out and measure it. The text width is set outright rather than left to the
--- anchors, because a wrapped FontString only reports its height once it knows its width.
---@param row table
---@param item table
---@return number height
local function LayoutRow(row, item)
    local textLeft = 0
    row.check:Hide()
    -- Cleared as well as hidden: rows are reused for whatever line lands on them next, and
    -- a stale quest id on a hidden box is a tick waiting to happen to the wrong quest.
    row.check.questId = nil
    row.glyph:Hide()
    row.marker:Hide()
    row.right:SetText("")

    if item.kind == "step" then
        row.check:Show()
        row.check.questId = item.id
        row.check.mark:Hide()
        textLeft = CHECK + 5 + SetGlyph(row, KIND_GLYPH[item.step], item.color)
        row.text:SetTextColor(unpack(item.current and theme.text or theme.dim))
        row.marker:SetShown(item.current == true)
        if item.here then row.right:SetText("here") end

    elseif item.kind == "zone" then
        if item.otherContinent then
            textLeft = SetGlyph(row, "travel", theme.faint)
        end
        row.text:SetTextColor(unpack(theme.dim))
        if item.outstanding and item.outstanding > 1 then
            -- "in order" earns its place: it says the list below is a route rather than an
            -- arbitrary order, which is not otherwise visible from looking at it.
            row.right:SetText(item.walked
                and (item.outstanding .. " in order")
                or (item.outstanding .. " steps"))
        end

    elseif item.kind == "finished" then
        textLeft = SetGlyph(row, nil)
        row.text:SetTextColor(unpack(theme.faint))

    else
        textLeft = CHECK + 5 + GLYPH + 4
        row.text:SetTextColor(unpack(theme.faint))
    end

    local rightWidth = row.right:GetStringWidth() or 0
    if rightWidth > 0 then rightWidth = rightWidth + 8 end
    local available = WIDTH - PAD * 2 - textLeft - rightWidth
    if available < 40 then available = 40 end

    row.text:ClearAllPoints()
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", textLeft, 0)
    row.text:SetWidth(available)
    row.text:SetFont(W.font, item.kind == "detail" and W.size.tiny or W.size.small, "")
    row.text:SetText(item.text)

    local height = math.max(item.kind == "detail" and 12 or 15,
        (row.text:GetStringHeight() or 12) + 2)

    -- A detail line belongs to the step above it and acts on the same quest, so it lights
    -- up too. A zone heading only does anything when it has a quest to open directions for.
    row.clickable = item.id ~= nil or item.kind == "finished"
    row.item = item
    row:SetHeight(height)
    return height
end

local function AcquireRow(index)
    local row = rows[index]
    if not row then
        row = CreateRow()
        rows[index] = row
    end
    return row
end

--------------------------------------------------------------------------------------------
-- Building the row list
--------------------------------------------------------------------------------------------

local NOWHERE = "No recorded place"

local STEP_COLOR = {
    pickup = { 0.9, 0.9, 0.9 },
    turnin = { 1, 0.82, 0 },
    blocked = { 1, 0.6, 0.32 },
    finish = { 0.4, 0.8, 1 },
}

--- Where the step is, as a phrase: who to talk to and where they stand. This is the line
--- that answers "fine, but where do I get it?", so it carries the coordinates too.
local function WhereFor(step)
    if not step.npc then
        if step.kind == "turnin" then
            return "no turn-in NPC recorded - hand it in where the quest says"
        end
        if step.kind == "blocked" then return nil end
        if step.kind == "finish" then return "in your log - no mapped objective" end
        return "no quest giver recorded - starts from an object or an item"
    end

    local lead = "from "
    if step.kind == "turnin" then lead = "to " end
    if step.kind == "finish" then lead = "look for " end
    local text = lead .. step.npc
    if step.zone then text = text .. ", " .. step.zone end
    if step.x and step.y then text = text .. (" (%.0f, %.0f)"):format(step.x, step.y) end
    return text
end

--- The line under a step. For a step that exists to unlock something else, what it unlocks
--- is the point of it, so that is said here rather than left to the tooltip.
local function DetailFor(entry)
    local step = entry.step
    if step.kind == "blocked" then
        return "needs " .. table.concat(step.blockers, ", ") .. " first"
    end
    if step.kind == "finish" and not step.npc then
        return "in your log - finish the objectives"
    end

    local text = WhereFor(step)
    if step.unlocks and #step.unlocks > 0 then
        local unlocks = "unlocks " .. table.concat(step.unlocks, " and ")
        text = text and (text .. " - " .. unlocks) or unlocks
    end
    return text
end

--- Flatten the plan into the lines the strip draws.
---@param plan table
---@return table[] items
local function ItemsFor(plan)
    local items = {}
    local current = Guide and Guide.current

    for _, group in ipairs(plan.groups) do
        items[#items + 1] = {
            kind = "zone",
            text = group.zone or NOWHERE,
            outstanding = group.outstanding,
            otherContinent = group.otherContinent,
            id = group.nextId,
            place = group.place,
            walked = group.walked,
            zoneRow = true,
        }
        for _, entry in ipairs(group.entries) do
            local step = entry.step
            local isCurrent = current ~= nil and current.questId == entry.id
                and current.kind == step.kind
            local stepItem = {
                kind = "step",
                step = step.kind,
                id = entry.id,
                covers = entry.covers,
                text = ("%s %s"):format(step.verb or "Go to", step.subject or entry.name),
                where = WhereFor(step),
                unlocks = step.unlocks,
                color = STEP_COLOR[step.kind] or theme.dim,
                current = isCurrent,
                here = isCurrent and Guide.arrived or false,
            }
            items[#items + 1] = stepItem
            if QEF.Get("trackerSteps") then
                items[#items + 1] = {
                    kind = "detail", text = DetailFor(entry), id = entry.id,
                    parent = stepItem,
                }
            end
        end
    end

    if #plan.finished > 0 then
        items[#items + 1] = {
            kind = "finished",
            text = ("%d finished - click to clear"):format(#plan.finished),
        }
    end
    return items
end

--------------------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------------------

function Tracker.Refresh()
    if not frame or not frame:IsShown() then return end

    local plan = Checklist.Plan()
    titleText:SetText(plan.dungeon or "Dungeon checklist")
    progressText:SetText(("%d/%d"):format(plan.done, plan.total))

    local items = ItemsFor(plan)
    local overflow = 0
    if #items > MAX_ROWS then
        overflow = #items - MAX_ROWS
        for index = #items, MAX_ROWS + 1, -1 do items[index] = nil end
        -- A zone heading left with nothing under it reads as a bug rather than as a cut,
        -- so the cut moves up to take the heading with it.
        while #items > 0 and items[#items].kind == "zone" do
            items[#items] = nil
            overflow = overflow + 1
        end
    end

    local y = 0
    for index, item in ipairs(items) do
        -- A little air above a zone heading and the finished line, so the groups read as
        -- groups rather than as one column of text.
        if (item.kind == "zone" or item.kind == "finished") and index > 1 then y = y + 6 end
        local row = AcquireRow(index)
        row:ClearAllPoints()
        row:SetPoint("LEFT", body, "LEFT", 0, 0)
        row:SetPoint("RIGHT", body, "RIGHT", 0, 0)
        row:SetPoint("TOP", body, "TOP", 0, -y)
        y = y + LayoutRow(row, item)
        row:Show()
    end
    for index = #items + 1, #rows do rows[index]:Hide() end

    if overflow > 0 then
        footerText:SetText(("+%d more - open the planner to see them"):format(overflow))
    elseif plan.total > 0 and plan.done == plan.total then
        footerText:SetText("Everything on the list is done.")
    elseif Guide and not Guide.Enabled() then
        footerText:SetText("Marker off - |cffffd100/qef guide|r turns it on")
    elseif Guide and Guide.arrived then
        footerText:SetText("You are there - the marker moves on by itself")
    else
        footerText:SetText("Click a step to mark it, right-click to drop it")
    end

    body:SetHeight(math.max(1, y))
    frame:SetHeight(HEADER_HEIGHT + y + FOOTER_HEIGHT + PAD * 2)
end

--- Show or hide according to the setting and whether there is anything to show.
function Tracker.Update()
    if not frame then return end
    local wanted = QEF.Get("tracker") and Checklist.Count() > 0
    if wanted then
        frame:Show()
        Tracker.Refresh()
    else
        frame:Hide()
    end
end

-- Quest events arrive in bursts - accepting one quest can fire three of them - so the
-- rebuild is coalesced into the next tick rather than run per event.
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.3, function()
        refreshQueued = false
        Tracker.Update()
    end)
end

Tracker.Queue = QueueRefresh

--------------------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------------------

local function SavePosition()
    local point, _, _, x, y = frame:GetPoint(1)
    if not point then return end
    QEF.Set("trackerPoint", { point = point, x = x, y = y })
end

local function RestorePosition()
    local saved = QEF.Tbl(QEF.Get("trackerPoint"))
    frame:ClearAllPoints()
    if saved and QEF.Str(saved.point) then
        frame:SetPoint(saved.point, UIParent, saved.point, saved.x or 0, saved.y or 0)
    else
        -- Right hand side, below where the objective tracker usually ends.
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -24, 40)
    end
end

local function Build()
    if frame then return end

    frame = CreateFrame("Frame", "QuestExplorerForeverTracker", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetHeight(120)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:Hide()
    W.Fill(frame, { theme.bg[1], theme.bg[2], theme.bg[3], 0.88 })
    W.Outline(frame, theme.line)
    Tracker.frame = frame

    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)
    W.Fill(header, theme.raised)
    W.Hairline(header, "BOTTOM", theme.line)

    local mark = Art.Brand(header, 12)
    mark:SetPoint("LEFT", header, "LEFT", PAD - 2, 0)

    titleText = W.Text(header, W.size.small, theme.text)
    titleText:SetPoint("LEFT", mark, "RIGHT", 6, 0)
    titleText:SetWordWrap(false)

    local close = CreateFrame("Button", nil, header)
    close:SetSize(18, 18)
    close:SetPoint("RIGHT", header, "RIGHT", -6, 0)
    local closeGlyph = W.Text(close, 13, theme.faint, "CENTER")
    closeGlyph:SetPoint("CENTER")
    closeGlyph:SetText("\195\151")
    close:SetScript("OnEnter", function() closeGlyph:SetTextColor(unpack(theme.text)) end)
    close:SetScript("OnLeave", function() closeGlyph:SetTextColor(unpack(theme.faint)) end)
    -- Closing hides the strip without emptying the list, which is nearly always what
    -- someone means by closing a tracker.
    close:SetScript("OnClick", function()
        QEF.Set("tracker", false)
        Tracker.Update()
        QEF.Print("checklist hidden - |cffffd100/qef tracker|r brings it back")
    end)

    progressText = W.Text(header, W.size.tiny, theme.accent, "RIGHT")
    progressText:SetPoint("RIGHT", close, "LEFT", -4, 0)
    -- The title gives way to the count rather than running under it.
    titleText:SetPoint("RIGHT", progressText, "LEFT", -6, 0)

    body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", PAD, -PAD)
    body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -PAD, -PAD)
    body:SetHeight(1)

    footerText = W.Text(frame, W.size.tiny, theme.faint)
    footerText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 7)
    footerText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 7)
    footerText:SetWordWrap(false)

    RestorePosition()
end

--------------------------------------------------------------------------------------------
-- Clicks
--------------------------------------------------------------------------------------------

--- Put the marker on a step, say in chat where that is, and open the directions when it is
--- not the map you are standing on. Clicking a line should answer "where is that?" on its
--- own: the whole problem with a prerequisite is that you have never been told where it
--- starts.
local function MarkStep(item)
    if not Guide.Pin(item.id) then return end

    local current = Guide.current
    local where = current.npc or "the marked spot"
    if current.zone then where = where .. ", " .. current.zone end
    if current.x and current.y then
        where = where .. (" (%.0f, %.0f)"):format(current.x, current.y)
    end
    QEF.Print("marker set: " .. where)

    -- Directions only earn a window when the place is on another map. Standing in the right
    -- zone, the pin and the coordinates are the whole answer.
    if not (QEF.Get("routeWindow") and QEF.Get("showTravel") and QEF.Route) then return end
    if Guide.PlayerMapId() == current.uiMapId then return end

    QEF.Route.ShowPlace({
        name = current.npc, zoneName = current.zone,
        uiMapId = current.uiMapId, x = current.x, y = current.y,
    }, item.text, "Map pin set on " .. where)
end

function OnRowClick(row, button)
    local item = row.item
    if not item or not row.clickable then return end

    if item.kind == "finished" then
        local removed = Checklist.RemoveFinished()
        QEF.Print(("cleared %d finished quest%s off the checklist"):format(
            removed, removed == 1 and "" or "s"))
        return
    end

    if item.zoneRow then
        -- Directions to the group, not to any one quest in it. A group with nowhere
        -- recorded has nothing to say, and saying nothing beats sending someone to the
        -- wrong NPC.
        if not item.place then return end
        if QEF.Get("routeWindow") and QEF.Route
            and QEF.Route.ShowPlace(item.place, item.text) then
            return
        end
        if QEF.Travel then QEF.Travel.AnnouncePlace(item.place) end
        return
    end

    -- A detail line belongs to the step above it and does the same thing.
    local step = item.parent or item

    if button == "RightButton" then
        local covers = step.covers or { step.id }
        for _, questId in ipairs(covers) do Checklist.Remove(questId) end
        if #covers > 1 then
            QEF.Print(("dropped %d quests - that one step was holding up both"):format(#covers))
        end
        return
    end

    -- Left click marks this step, rather than always pointing at the quest's start: on a
    -- quest you are already holding, the start is the one place you do not want to go.
    MarkStep(step)
end

--- What a line is really about, spelled out: the game gives you no way to find out where a
--- quest you have not got yet is handed out.
function OnRowEnter(row)
    local item = row.item
    if not item then return end
    local step = item.parent or item
    if step.kind ~= "step" then return end

    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:AddLine(step.text, 1, 1, 1)
    if step.where then
        GameTooltip:AddLine(step.where, 0.6, 0.62, 0.67, true)
    end
    if step.unlocks and #step.unlocks > 0 then
        GameTooltip:AddLine("Unlocks " .. table.concat(step.unlocks, " and "),
            0.4, 0.8, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(step.current and "Marked on your map now"
        or "Click to mark it on your map", 0.95, 0.78, 0.36)
    local covers = step.covers and #step.covers or 1
    GameTooltip:AddLine(covers > 1
        and ("Right-click to drop all %d quests this clears"):format(covers)
        or "Right-click to drop it from the list", 0.55, 0.57, 0.62)
    GameTooltip:Show()
end

function OnCheckClick(check)
    if not check.questId then return end
    -- Only the manual tick is ours to flip. A quest the game says you have finished cannot
    -- be un-ticked here, because the next refresh would tick it straight back.
    local done, status = Checklist.IsDone(check.questId)
    if done and not Checklist.IsTicked(check.questId) then
        QEF.Print("that quest is already " .. status .. " - nothing to tick off")
        return
    end
    Checklist.SetTicked(check.questId, not Checklist.IsTicked(check.questId))
end

--------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------

--- Show the strip, building it on first use.
function Tracker.Show()
    Build()
    QEF.Set("tracker", true)
    Tracker.Update()
end

function Tracker.Hide()
    QEF.Set("tracker", false)
    Tracker.Update()
end

---@return boolean shown
function Tracker.Toggle()
    if QEF.Get("tracker") then
        Tracker.Hide()
        return false
    end
    Tracker.Show()
    return true
end

--- Put the strip back where it starts, for when it has been dragged off a resized screen.
function Tracker.ResetPosition()
    Build()
    QEF.Set("trackerPoint", nil)
    RestorePosition()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Tracker", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
    Checklist = QEF.Checklist
    Guide = QEF.Guide

    Build()

    Checklist.Subscribe(Tracker.Update)
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
                             "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA",
                             "PLAYER_ENTERING_WORLD" }) do
        QEF.On(event, QueueRefresh)
    end

    Tracker.Update()
end)
