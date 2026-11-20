-- MinimapButton.lua
--
-- The button on the minimap: the way to open the addon without remembering a slash command.
--
-- Written rather than taken from a library. LibDBIcon is the usual answer and a good one,
-- but it comes with LibStub and an embed, and this addon ships no libraries - the layout it
-- uses is four textures and an angle, which is less code than embedding it would be.
--
-- The angle is saved, so where you drag it is where it stays.

local ADDON, QEF = ...

local MinimapButton = {}
QEF.MinimapButton = MinimapButton

local Art

local button
-- Where the button sits when it has never been dragged: lower left of the minimap, which
-- is usually the emptiest corner.
local DEFAULT_ANGLE = 200

--------------------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------------------

local function Angle()
    local saved = QEF.Num(QEF.Get("minimapAngle"))
    return saved or DEFAULT_ANGLE
end

--- Seat the button on the minimap's edge at the saved angle.
local function UpdatePosition()
    if not button or not Minimap then return end
    local radians = math.rad(Angle())
    -- Measured from the minimap rather than assumed: a unit frame addon may have resized
    -- it, and a button floating ten pixels off the edge looks like a mistake.
    local radius = ((Minimap:GetWidth() or 140) / 2) + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(radians) * radius, math.sin(radians) * radius)
end

MinimapButton.UpdatePosition = UpdatePosition

local function OnDragUpdate()
    local centreX, centreY = Minimap:GetCenter()
    if not centreX then return end
    local scale = Minimap:GetEffectiveScale()
    if not scale or scale == 0 then return end

    local cursorX, cursorY = GetCursorPosition()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    QEF.Set("minimapAngle", math.deg(math.atan2(cursorY - centreY, cursorX - centreX)))
    UpdatePosition()
end

--------------------------------------------------------------------------------------------
-- Clicks
--------------------------------------------------------------------------------------------

local function OnClick(_, mouseButton)
    if mouseButton == "RightButton" then
        QEF.Window.Show("settings")
    elseif mouseButton == "MiddleButton" then
        QEF.Tracker.Toggle()
    else
        QEF.Window.Toggle()
    end
end

local function OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Quest Explorer |cfff2c75bForever|r")

    -- What the list is up to, since that is the thing worth knowing before you open it.
    local done, total = QEF.Checklist.Progress()
    if total > 0 then
        GameTooltip:AddLine(("Checklist: %d of %d done"):format(done, total), 0.95, 0.78, 0.36)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open the window", 0.6, 0.62, 0.67)
    GameTooltip:AddLine("Right-click for settings", 0.6, 0.62, 0.67)
    GameTooltip:AddLine("Middle-click for the checklist strip", 0.6, 0.62, 0.67)
    GameTooltip:AddLine("Drag to move it round the minimap", 0.45, 0.47, 0.52)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------------------

local function Build()
    if button or not Minimap then return button end

    button = CreateFrame("Button", "QuestExplorerForeverMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetSize(31, 31)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")

    -- The sizes and offsets are the ones every minimap button uses, because they are what
    -- line the icon up inside Blizzard's border art rather than beside it.
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("TOPLEFT", 7, -6)
    button.icon:SetTexture(Art.icon.addon)
    -- Icons carry a border in their outer pixels; cropped, the mark fills the button.
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    UpdatePosition()
    return button
end

--------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------

--- Show or hide it according to the setting, building it the first time it is wanted.
function MinimapButton.Update()
    if not QEF.Get("minimap") then
        if button then button:Hide() end
        return
    end
    if not Build() then return end
    UpdatePosition()
    button:Show()
end

---@return boolean shown
function MinimapButton.Toggle()
    QEF.Set("minimap", not QEF.Get("minimap"))
    MinimapButton.Update()
    return QEF.Get("minimap") and true or false
end

--- Put it back where it starts, for when it has been dragged somewhere awkward.
function MinimapButton.ResetPosition()
    QEF.Set("minimapAngle", DEFAULT_ANGLE)
    UpdatePosition()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("MinimapButton", function()
    Art = QEF.Art
    if not Minimap then
        QEF.Debug("no minimap frame on this client - no button")
        return
    end
    MinimapButton.Update()
end)
