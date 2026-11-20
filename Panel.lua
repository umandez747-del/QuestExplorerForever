-- Panel.lua
--
-- The side panel: the same preview rows as the tooltip, but parked beside the quest giver
-- frame so it stays up while you read the quest text. Reward lines show the real item tooltip
-- on hover, which is the one thing a tooltip-inside-a-tooltip cannot do.

local ADDON, QEF = ...

local Panel = {}
QEF.Panel = Panel

local W, theme, Art
local Render

local frame, title, stack, tab
local currentQuestId, currentOpts

local PADDING = 14
-- Wide enough for an objective or a travel step on two lines rather than four.
local WIDTH = 380
local TAB_WIDTH = 22
-- The tab sits below the host's top corner, where it reads as a tab on the side rather
-- than as part of the frame's own edge - and clear of the buttons most frames put there.
local TAB_TOP_OFFSET = 34

-- Blizzard's parchment frames are drawn inside a decorative border, so the frame's own
-- rectangle runs well past the edge the player actually sees - about 35 pixels on the right
-- of a quest frame, and a dozen above its top. These trim the attachment back to the
-- visible edge. If a frame on this client is drawn differently, it is one number here.
local ATTACH_INSET = {
    QuestFrame     = { side = 34, top = 12 },
    QuestLogFrame  = { side = 34, top = 12 },
    GossipFrame    = { side = 34, top = 12 },
    -- The map-based frames have no decorative margin worth speaking of.
    QuestMapFrame  = { side = 0, top = 0 },
    WorldMapFrame  = { side = 0, top = 0 },
}

local DEFAULT_INSET = { side = 0, top = 0 }

-- Forward declaration: the tab is built alongside the panel but described further down.
local EnsureTab

--------------------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return end

    frame = CreateFrame("Frame", "QuestExplorerForeverPanel", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetHeight(140)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.userMoved = true
    end)
    frame:Hide()

    W.Fill(frame, { theme.bg[1], theme.bg[2], theme.bg[3], 0.95 })

    -- The four edges are kept apart rather than drawn with W.Outline, because the one
    -- against the frame it is attached to has to come off: two hairlines a pixel apart read
    -- as two windows that happen to touch, and one reads as a panel on the side of a frame.
    frame.border = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        frame.border[side] = W.Hairline(frame, side, theme.line)
    end

    -- The joined edge, in the accent colour: the seam that says this belongs to that.
    frame.seam = frame:CreateTexture(nil, "OVERLAY")
    frame.seam:SetWidth(2)
    frame.seam:SetColorTexture(unpack(theme.accent))
    frame.seam:Hide()

    title = W.Text(frame, W.size.small, theme.faint)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -10)
    title:SetText("QUEST EXPLORER")

    -- The addon's mark: a panel parked against a Blizzard frame should say whose it is.
    local mark = Art.Brand(frame, 12)
    mark:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -8)
    title:ClearAllPoints()
    title:SetPoint("LEFT", mark, "RIGHT", 6, 0)

    local close = W.CloseButton(frame)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() Panel.Minimise() end)
    -- Hooked rather than set: W.CloseButton already lights the glyph on hover.
    close:HookScript("OnEnter", function()
        GameTooltip:SetOwner(close, "ANCHOR_TOP")
        GameTooltip:AddLine("Minimise the preview", 1, 1, 1)
        GameTooltip:AddLine("It folds into a tab on the edge of the frame and stays there "
            .. "until you click it.", 0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    close:HookScript("OnLeave", function() GameTooltip:Hide() end)

    stack = W.RowStack(frame)
    stack:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -30)
    stack:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
    stack:SetHeight(400)

    EnsureTab()
end

--- The closed state: a slim tab on the frame's edge, in place of the panel.
--- A preview you cannot get rid of is a nuisance, and one you cannot get back is worse, so
--- closing it leaves this behind rather than nothing.
function EnsureTab()  -- luacheck: ignore (forward declared above)
    if tab then return end

    tab = CreateFrame("Button", nil, UIParent)
    tab:SetSize(TAB_WIDTH, 96)
    tab:SetFrameStrata("HIGH")
    tab:Hide()

    W.Fill(tab, { theme.raised[1], theme.raised[2], theme.raised[3], 0.95 })
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        W.Hairline(tab, side, theme.line)
    end

    tab.seam = tab:CreateTexture(nil, "OVERLAY")
    tab.seam:SetWidth(2)
    tab.seam:SetColorTexture(unpack(theme.accent))
    tab.seam:Hide()

    local dot = tab:CreateTexture(nil, "ARTWORK")
    dot:SetSize(5, 5)
    dot:SetPoint("TOP", tab, "TOP", 0, -8)
    dot:SetColorTexture(unpack(theme.accent))

    -- One letter per line: the only way to run text down a tab in this UI.
    tab.label = W.Text(tab, W.size.tiny, theme.dim, "CENTER")
    tab.label:SetPoint("TOP", dot, "BOTTOM", 0, -6)
    tab.label:SetWidth(TAB_WIDTH)
    tab.label:SetText("P\nR\nE\nV\nI\nE\nW")
    tab.label:SetSpacing(-1)

    tab:SetScript("OnEnter", function(self)
        self.label:SetTextColor(unpack(theme.text))
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Quest Explorer", 1, 1, 1)
        local name = currentQuestId and QEF.Source.QuestName(currentQuestId)
        if name then
            GameTooltip:AddLine(name, 0.95, 0.78, 0.36, true)
        end
        GameTooltip:AddLine("Click to open it back up.", 0.6, 0.62, 0.67, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function(self)
        self.label:SetTextColor(unpack(theme.dim))
        GameTooltip:Hide()
    end)
    tab:SetScript("OnClick", function() Panel.Restore() end)
end

--------------------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------------------

---@param anchorTo table?
---@return table inset
local function InsetFor(anchorTo)
    local name = anchorTo and anchorTo.GetName and anchorTo:GetName()
    return (name and ATTACH_INSET[name]) or DEFAULT_INSET
end

--- The host's left and right edges in the same units as the screen width. A frame reports
--- its edges in its own scale, and an addon that resizes or rescales the world map - which
--- is exactly the sort of frame this attaches to - makes that scale different from the
--- interface's own.
---@param anchorTo table
---@return number left
---@return number right
local function Edges(anchorTo)
    local hostScale = (anchorTo.GetEffectiveScale and anchorTo:GetEffectiveScale()) or 1
    local uiScale = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local factor = (uiScale > 0) and (hostScale / uiScale) or 1
    return (anchorTo:GetLeft() or 0) * factor, (anchorTo:GetRight() or 0) * factor
end

--- Which side of the host to sit on. A wide frame - a maximised map, say - may have room
--- for the panel on neither side, in which case it takes the roomier one and the clamp
--- pulls it back on screen.
---@param anchorTo table
---@return boolean onLeft
local function PreferLeft(anchorTo)
    local screen = GetScreenWidth() or 1024
    local left, right = Edges(anchorTo)
    local roomLeft, roomRight = left, screen - right

    if roomRight >= WIDTH then return false end
    if roomLeft >= WIDTH then return true end
    return roomLeft > roomRight
end

--- Seat a frame against the host, flush when attached and floating beside it when not.
---@param what table the panel or the tab
---@param anchorTo table
---@param onLeft boolean
---@param attached boolean
---@param dropBy number? extra distance below the host's top edge
local function Seat(what, anchorTo, onLeft, attached, dropBy)
    local inset = attached and InsetFor(anchorTo) or DEFAULT_INSET
    -- Attached, the two frames overlap by a pixel so their borders land on each other and
    -- read as one line. Floating, they sit eight apart.
    local gap = attached and -1 or 8
    local top = inset.top + (dropBy or 0)

    what:ClearAllPoints()
    if onLeft then
        what:SetPoint("TOPRIGHT", anchorTo, "TOPLEFT", inset.side - gap, -top)
    else
        what:SetPoint("TOPLEFT", anchorTo, "TOPRIGHT", gap - inset.side, -top)
    end
end

--- A frame is somewhere to attach to only while it is really on screen. IsShown is not that
--- test: a panel inside a closed window still reports itself as shown.
---@param anchorTo table?
---@return boolean
local function Usable(anchorTo)
    return anchorTo ~= nil and anchorTo.IsVisible ~= nil and anchorTo:IsVisible() == true
end

local function Anchor()
    if not frame then return end

    local anchorTo = currentOpts and currentOpts.anchorTo
    local attached = QEF.Get("panelAttach") and Usable(anchorTo) and not frame.userMoved

    -- A panel the player has dragged somewhere is theirs: it keeps all four of its edges
    -- and none of the attachment.
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        frame.border[side]:Show()
    end
    frame.seam:Hide()

    if frame.userMoved then return end

    if not Usable(anchorTo) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 340, 0)
        return
    end

    local onLeft = PreferLeft(anchorTo)
    Seat(frame, anchorTo, onLeft, attached)

    if not attached then return end

    -- Drop the hairline on the joined edge and run the accent seam down it instead.
    local joined = onLeft and "RIGHT" or "LEFT"
    frame.border[joined]:Hide()
    frame.seam:ClearAllPoints()
    frame.seam:SetPoint("TOP" .. joined, frame, "TOP" .. joined, 0, 0)
    frame.seam:SetPoint("BOTTOM" .. joined, frame, "BOTTOM" .. joined, 0, 0)
    frame.seam:Show()
end

--- Put the tab on the host's edge, a little below the top so it reads as a tab on the side
--- rather than a stub of the frame's own corner.
local function AnchorTab()
    if not tab then return end
    local anchorTo = currentOpts and currentOpts.anchorTo
    if not Usable(anchorTo) then
        tab:Hide()
        return
    end

    local onLeft = PreferLeft(anchorTo)
    local attached = QEF.Get("panelAttach") == true
    Seat(tab, anchorTo, onLeft, attached, TAB_TOP_OFFSET)

    -- The same seam the panel has, so the tab reads as the same thing folded away.
    local joined = onLeft and "RIGHT" or "LEFT"
    tab.seam:ClearAllPoints()
    tab.seam:SetPoint("TOP" .. joined, tab, "TOP" .. joined, 0, 0)
    tab.seam:SetPoint("BOTTOM" .. joined, tab, "BOTTOM" .. joined, 0, 0)
    tab.seam:SetShown(attached)
end

function Panel.Redraw()
    if not frame or not frame:IsShown() or not currentQuestId then return end
    local height = stack:SetRows(Render.Build(currentQuestId, currentOpts))
    frame:SetHeight(math.max(70, height + 42))
    Anchor()
end

--------------------------------------------------------------------------------------------
-- Show / hide / minimise
--------------------------------------------------------------------------------------------

---@return boolean
local function Minimised()
    return QEF.Get("panelMinimised") == true
end

--- Draw whichever of the two the current state calls for: the panel, or the tab standing
--- in for it. Every entry point goes through here so the two can never both be up.
local function Present()
    if not frame then return end

    if not currentQuestId then
        tab:Hide()
        frame:Hide()
        return
    end

    -- Minimising needs something to minimise onto. A panel floating in the middle of the
    -- screen has no edge to tuck against, so there it is an ordinary close.
    if Minimised() and Usable(currentOpts and currentOpts.anchorTo) then
        frame:Hide()
        AnchorTab()
        tab:Show()
        return
    end

    tab:Hide()
    frame:Show()
    Panel.Redraw()
end

Panel.Present = Present

---@param questId number
---@param opts table? { anchorTo = frame, atGiver = boolean }
function Panel.Show(questId, opts)
    if not QEF.Get("enabled") then return end
    questId = QEF.QuestId(questId)
    if not questId then return end

    EnsureFrame()
    currentQuestId = questId
    currentOpts = opts or {}
    Present()
end

function Panel.Hide()
    currentQuestId = nil
    currentOpts = nil
    if tab then tab:Hide() end
    if frame then frame:Hide() end
end

--- Fold the panel away into its tab. Sticky: it stays folded as you click down a quest log
--- rather than springing open on every selection, which is the whole point of minimising
--- something. The tab follows along and names whatever is selected.
function Panel.Minimise()
    if not Usable(currentOpts and currentOpts.anchorTo) then
        -- Nothing to tuck against, so the close button means close.
        Panel.Hide()
        return
    end
    QEF.Set("panelMinimised", true)
    Present()
end

function Panel.Restore()
    QEF.Set("panelMinimised", false)
    Present()
end

---@return boolean
function Panel.IsMinimised()
    return Minimised()
end

--- The quest the panel stands for, whether it is open or folded into its tab. A caller that
--- redraws on a timer asks this rather than IsShown, which would be false while minimised
--- and would have it rebuilding on every tick.
---@return number?
function Panel.CurrentQuestId()
    return currentQuestId
end

function Panel.IsShown()
    return frame ~= nil and frame:IsShown()
end

--- Forget a dragged position, so the panel goes back to tracking the quest frame.
function Panel.ResetPosition()
    if frame then
        frame.userMoved = nil
        Anchor()
    end
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Panel", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
    Render = QEF.Render
end)
