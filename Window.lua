-- Window.lua
--
-- The main window: a title bar, a left nav rail, and a content area that hosts one view at a
-- time. Views register themselves and are built the first time they are opened, so opening
-- the window costs nothing until you actually look at something.

local ADDON, QEF = ...

local Window = {}
QEF.Window = Window

local W, theme, Art

local RAIL_WIDTH = 170
local PAD = 20

local window, rail, content
local views = {}      -- key -> { key, label, build, frame }
local order = {}
local navButtons = {}
local activeKey

--------------------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------------------

--- Register a view. `build(parent)` runs once, the first time the view is opened, and must
--- return a frame anchored inside `parent`.
---@param key string
---@param label string
---@param build fun(parent: table): table
---@param icon string? key into Art.icon
function Window.RegisterView(key, label, build, icon)
    if views[key] then return end
    views[key] = { key = key, label = label, build = build, icon = icon }
    order[#order + 1] = key
end

--------------------------------------------------------------------------------------------
-- Nav rail
--------------------------------------------------------------------------------------------

local function CreateNavButton(key, label, index, icon)
    local button = CreateFrame("Button", nil, rail)
    button:SetHeight(38)
    -- Inset a pixel each side. A child frame draws above every texture of its parent, so a
    -- button flush with the rail paints over the window's left border and, worse, over the
    -- rail's right hairline - which makes the selected row look like a notch cut through the
    -- divider into the content area beside it.
    button:SetPoint("LEFT", rail, "LEFT", 1, 0)
    button:SetPoint("RIGHT", rail, "RIGHT", -1, 0)
    button:SetPoint("TOP", rail, "TOP", 0, -(index - 1) * 38 - 8)

    button.bg = W.Fill(button, { 0, 0, 0, 0 })

    button.marker = button:CreateTexture(nil, "ARTWORK")
    button.marker:SetWidth(2)
    button.marker:SetPoint("TOPLEFT")
    button.marker:SetPoint("BOTTOMLEFT")
    button.marker:SetColorTexture(unpack(theme.accent))
    button.marker:Hide()

    local textLeft = PAD
    if icon then
        -- Desaturated and tinted, so a colourful client icon reads as a monochrome glyph.
        button.glyph = Art.Glyph(button, icon, 14, theme.dim)
        button.glyph:SetPoint("LEFT", button, "LEFT", PAD, 0)
        textLeft = PAD + 22
    end

    button.label = W.Text(button, W.size.body, theme.dim)
    button.label:SetPoint("LEFT", button, "LEFT", textLeft, 0)
    -- Clamped to the rail: without a right edge a long view name is drawn straight over
    -- the content area beside it, since a FontString with one anchor sizes to its text.
    button.label:SetPoint("RIGHT", button, "RIGHT", -10, 0)
    button.label:SetJustifyH("LEFT")
    button.label:SetWordWrap(false)
    button.label:SetText(label)

    button:SetScript("OnClick", function() Window.Show(key) end)
    button:SetScript("OnEnter", function(self)
        if activeKey == key then return end
        -- Half strength, so hovering a row never looks like the selected one, which is the
        -- same colour at full opacity.
        self.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 0.5)
        self.label:SetTextColor(unpack(theme.text))
        Art.Tint(self.glyph, theme.text)
    end)
    button:SetScript("OnLeave", function(self)
        if activeKey == key then return end
        self.bg:SetColorTexture(0, 0, 0, 0)
        self.label:SetTextColor(unpack(theme.dim))
        Art.Tint(self.glyph, theme.dim)
    end)

    return button
end

local function UpdateNav()
    for key, button in pairs(navButtons) do
        local active = key == activeKey
        button.marker:SetShown(active)
        if active then
            -- Lighter than the rail, not darker. The rail is already a raised surface, so
            -- filling the selected row with the content colour made it read as a hole
            -- running into the pane beside it rather than as a selection.
            button.bg:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
            button.label:SetTextColor(unpack(theme.text))
            Art.Tint(button.glyph, theme.accent)
        else
            button.bg:SetColorTexture(0, 0, 0, 0)
            button.label:SetTextColor(unpack(theme.dim))
            Art.Tint(button.glyph, theme.dim)
        end
    end
end

--------------------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------------------

local function Build()
    if window then return end

    -- Wide enough that a long quest name fits the list and a full meta line fits the detail
    -- pane; FitToScreen shrinks it on a display that cannot take it.
    window = W.Window("QuestExplorerForeverWindow", 1080, 620, "Quest Explorer")
    window.subtitle:SetText(QEF.version)
    Window.frame = window

    rail = CreateFrame("Frame", nil, window)
    rail:SetWidth(RAIL_WIDTH)
    rail:SetPoint("TOPLEFT", window.titleBar, "BOTTOMLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 0, 0)
    W.Fill(rail, theme.raised)
    W.Hairline(rail, "RIGHT", theme.line)
    W.Hairline(window.titleBar, "BOTTOM", theme.line)
    -- A short accent gradient under the title, fading out across the rail. Enough to give the
    -- header an edge without drawing a loud coloured line across the whole window.
    Art.AccentUnderline(window, window.titleBar, RAIL_WIDTH + 60, 10)

    content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", rail, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
    Window.content = content

    -- The controller layer owns the hint bar; the window only has to give it room.
    QEF.Controller.Attach(window, window)

    for index, key in ipairs(order) do
        navButtons[key] = CreateNavButton(key, views[key].label, index, views[key].icon)
    end

    -- A quiet footer line in the rail: the one place the data source is stated outright.
    local footer = W.Text(rail, W.size.tiny, theme.faint)
    footer:SetPoint("BOTTOMLEFT", rail, "BOTTOMLEFT", PAD, 14)
    footer:SetPoint("RIGHT", rail, "RIGHT", -12, 0)
    footer:SetJustifyH("LEFT")
    Window.footer = footer
    Window.RefreshFooter()
end

function Window.RefreshFooter()
    if not Window.footer then return end
    local parts = {}
    parts[#parts + 1] = QEF.Source.available and "QuestieDB" or "no QuestieDB"
    if QEF.Source.questieAvailable then parts[#parts + 1] = "Questie" end
    local known = select(1, QEF.Sweep.Coverage())
    if known > 0 then parts[#parts + 1] = (QEF.Comma(known) or known) .. " learned" end
    Window.footer:SetText(table.concat(parts, "\n"))
end

--------------------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------------------

---@param key string?
function Window.Show(key)
    Build()
    key = key or activeKey or order[1]
    local view = views[key]
    if not view then return end

    if not view.frame then
        view.frame = view.build(content)
    end
    for _, other in pairs(views) do
        if other.frame and other.key ~= key then other.frame:Hide() end
    end
    view.frame:Show()
    activeKey = key
    UpdateNav()
    Window.RefreshFooter()

    window:Show()
    -- The rail model first, so a view with nothing of its own is still navigable; a view
    -- that has one replaces it from OnViewShown.
    QEF.Controller.SetSurface(Window.NavSurface())
    if view.frame.OnViewShown then view.frame.OnViewShown() end
end

--- Give the hint bar its strip at the bottom, or take it back.
---@param shown boolean
function Window.SetHintBarShown(shown)
    if not content then return end
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", rail, "TOPRIGHT", 0, 0)
    local hintBar = QEF.Controller.hintBar
    if shown and hintBar then
        content:SetPoint("BOTTOMRIGHT", hintBar, "TOPRIGHT", 0, 0)
        rail:SetPoint("BOTTOMLEFT", hintBar, "TOPLEFT", 0, 0)
    else
        content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
        rail:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 0, 0)
    end
end

--- The nav rail as a focus group, so every view is reachable on a pad whether or not it has
--- registered a model of its own. A view that has one wires its first column onto this.
---@param rightKey string? the group to the right of the rail
---@return table group
function Window.NavGroup(rightKey)
    local items = {}
    for _, key in ipairs(order) do
        local button = navButtons[key]
        if button then
            local viewKey = key
            items[#items + 1] = {
                frame = button,
                hint = views[key].label,
                activate = function() Window.Show(viewKey) end,
            }
        end
    end
    return { axis = "vertical", items = items, right = rightKey }
end

--- The fallback model: the rail and nothing else.
---@return table surface
function Window.NavSurface()
    return {
        order = { "nav" },
        start = "nav",
        groups = { nav = Window.NavGroup() },
        backHint = "Close",
        back = function() Window.Hide() end,
    }
end

--- Step to the next or previous view, which is what the shoulder buttons do.
---@param delta number
function Window.CycleView(delta)
    if #order == 0 then return end
    local current = 1
    for index, key in ipairs(order) do
        if key == activeKey then current = index break end
    end
    local nextIndex = current + delta
    if nextIndex < 1 then nextIndex = #order end
    if nextIndex > #order then nextIndex = 1 end
    Window.Show(order[nextIndex])
end

function Window.Hide()
    if window then window:Hide() end
end

function Window.Toggle(key)
    if window and window:IsShown() and (not key or key == activeKey) then
        Window.Hide()
    else
        Window.Show(key)
    end
end

function Window.IsShown()
    return window ~= nil and window:IsShown()
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Window", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
end)
