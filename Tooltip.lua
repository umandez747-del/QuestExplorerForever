-- Tooltip.lua
--
-- Quest Explorer's own tooltip, used when hovering a gossip or greeting entry (Blizzard shows
-- nothing there), plus the helper that appends preview rows to somebody else's tooltip, which
-- is how the Questie integration works.

local ADDON, QEF = ...

local Tooltip = {}
QEF.Tooltip = Tooltip

local Render

local tip
local current = { questId = nil, owner = nil, opts = nil }

--------------------------------------------------------------------------------------------
-- Row rendering
--------------------------------------------------------------------------------------------

local function Indent(level)
    if not level or level <= 0 then return "" end
    return string.rep("   ", level)
end

local function IconMarkup(icon)
    icon = QEF.Num(icon)
    if not icon then return "" end
    return "|T" .. icon .. ":14:14:0:0|t "
end

--- Append preview rows to any GameTooltip-like frame.
---@param target table
---@param rows table[]
---@return number added
function Tooltip.AppendRows(target, rows)
    if not target or not rows then return 0 end
    local added = 0
    for _, row in ipairs(rows) do
        if row.kind == "blank" then
            target:AddLine(" ")
            added = added + 1
        elseif row.kind == "double" then
            target:AddDoubleLine(Indent(row.indent) .. IconMarkup(row.icon) .. row.left,
                row.right, 1, 1, 1, 1, 1, 1)
            added = added + 1
        elseif row.kind == "line" then
            target:AddLine(Indent(row.indent) .. IconMarkup(row.icon) .. row.left, 1, 1, 1, false)
            added = added + 1
        elseif row.kind == "section" then
            -- These were being dropped on the floor. The panel renders them small and
            -- faint with space above; a tooltip cannot do small, but it can do faint and
            -- spaced, and a preview without its headings reads as one dense column.
            if added > 0 then
                target:AddLine(" ")
                added = added + 1
            end
            target:AddLine("|cff9C8F8A" .. row.left .. "|r", 1, 1, 1, false)
            added = added + 1
        end
    end
    return added
end

--------------------------------------------------------------------------------------------
-- The addon's own tooltip
--------------------------------------------------------------------------------------------

local function EnsureTip()
    if tip then return tip end
    tip = CreateFrame("GameTooltip", "QuestExplorerForeverTooltip", UIParent, "GameTooltipTemplate")
    tip:SetFrameStrata("TOOLTIP")
    return tip
end

--- Fill the tooltip and put it up.
---
--- The order matters and used to be wrong. A GameTooltip with no lines in it hides itself
--- the moment you call Show, so showing first and filling afterwards means the fill never
--- happens: the guard below sees a tooltip that is not shown and gives up. That is the
--- whole of why map pins fell back to a plain tooltip while the preview itself was
--- building eleven perfectly good rows.
---@param force boolean? true when the caller is putting the tooltip up rather than
---                      refreshing one already on screen, which is the only case where a
---                      hidden tooltip should be revived
local function Redraw(force)
    if not current.questId or not tip then return end
    if not force and not tip:IsShown() then return end
    local owner = current.owner
    if not owner then return end

    tip:ClearLines()
    tip:SetOwner(owner, "ANCHOR_NONE")
    -- Prefer the left of the quest frame so the preview never covers the dialogue the player
    -- is reading; fall back to the right at the screen edge.
    local anchorTo = current.opts and current.opts.anchorTo or owner
    tip:ClearAllPoints()
    -- Converted to the screen's own coordinates before being compared against the screen
    -- width. A map pin lives on a canvas with a scale of its own, so its raw left edge is
    -- not a number that means anything next to GetScreenWidth - and getting that wrong
    -- puts the preview off the edge rather than beside the pin.
    local left = (anchorTo:GetLeft() or 0)
        * (anchorTo:GetEffectiveScale() or 1)
        / (UIParent:GetEffectiveScale() or 1)
    if left > (GetScreenWidth() or 1024) * 0.45 then
        tip:SetPoint("TOPRIGHT", anchorTo, "TOPLEFT", -4, 0)
    else
        tip:SetPoint("TOPLEFT", anchorTo, "TOPRIGHT", 4, 0)
    end

    -- Kept, because it is the only honest answer to "did that tooltip say anything":
    -- asking the frame how many lines it is holding depends on when it is asked.
    Tooltip.lastReason = "built"
    current.rows = Tooltip.AppendRows(tip, Render.Build(current.questId, current.opts))

    -- A footer the caller can add: what the thing being hovered does when you click it.
    -- Worth saying on the map, where a pin looks like a label rather than a control.
    local footer = current.opts and current.opts.footer
    if footer and current.rows > 0 then
        tip:AddLine(" ")
        tip:AddLine("|cff6B5F5A" .. footer .. "|r", 1, 1, 1, false)
        current.rows = current.rows + 2
    end

    tip:Show()
end

--- Show the preview for a quest, anchored beside a frame.
---@param owner table the frame being hovered
---@param questId number
---@param opts table? { anchorTo = frame, atGiver = boolean, title = string }
---@return boolean shown  false when there is nothing to show or the preview is switched
---                       off, so a caller with a plainer tooltip to fall back on can
---                       use it rather than leaving the player hovering nothing
function Tooltip.Show(owner, questId, opts)
    -- Every exit says why. A preview that declines silently is indistinguishable from a
    -- frame that never got the mouse, and telling those two apart by reading the code has
    -- cost more versions than it should have.
    if not QEF.Get("enabled") then
        Tooltip.lastReason = "the addon is switched off"
        return false
    end
    questId = QEF.QuestId(questId)
    if not questId then
        Tooltip.lastReason = "no usable quest id"
        return false
    end
    if not owner then
        Tooltip.lastReason = "no owner frame"
        return false
    end

    EnsureTip()
    current.questId = questId
    current.owner = owner
    current.opts = opts or {}
    current.rows = 0
    Tooltip.lastReason = "the tooltip would not redraw"
    Redraw(true)

    if (current.rows or 0) > 0 then
        Tooltip.lastReason = "shown, " .. current.rows .. " rows"
        return true
    end
    if Tooltip.lastReason == "built" then
        Tooltip.lastReason = "the preview built no rows for this quest"
    end
    return false
end

function Tooltip.Hide()
    current.questId = nil
    current.owner = nil
    current.opts = nil
    if tip then tip:Hide() end
end

---@return number? questId
function Tooltip.CurrentQuest()
    return current.questId
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Tooltip", function()
    Render = QEF.Render

    -- A late answer from the server, or an item that has just arrived in the client's cache,
    -- redraws whatever preview is on screen.
    local previous = QEF.Rewards.OnUpdate
    QEF.Rewards.OnUpdate = function(questId)
        if previous then previous(questId) end
        Redraw()
        if QEF.Panel and QEF.Panel.Redraw then QEF.Panel.Redraw() end
    end
end)
