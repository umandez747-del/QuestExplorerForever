-- Widgets.lua
--
-- The look of the addon, and the small set of controls everything else is built from.
--
-- Deliberately not Blizzard's dialog chrome: flat dark surfaces, hairline separators, one
-- accent colour used sparingly, and type that carries the hierarchy instead of boxes and
-- borders. Everything is drawn from solid colour textures, so there are no art files to ship
-- and nothing to go stale against a client update.
--
-- Layout follows an 8px rhythm. Spacing is the main tool; borders are the last resort.

local ADDON, QEF = ...

local W = {}
QEF.Widgets = W

--------------------------------------------------------------------------------------------
-- Theme
--------------------------------------------------------------------------------------------

local function rgb(hex)
    return {
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255,
    }
end

-- Themed to the addon's own art: gold on warm dark, with the gem blue the frames carry.
--
-- The greys are the cool ones this was built with, with their red and blue channels
-- swapped - 16171B becomes 1B1716. That is not a trick for its own sake: the luminance of
-- each surface is unchanged, so every contrast ratio the layout was tuned against still
-- holds, and only the hue moves from blue-grey to brown-grey. Gold on a blue-grey panel
-- looks like gold on the wrong panel.
W.theme = {
    bg        = rgb("1B1716"),  -- window body
    raised    = rgb("26201E"),  -- nav rail, cards, selected rows
    hover     = rgb("322A27"),
    line      = rgb("3C322E"),  -- hairline separators and borders
    text      = rgb("EDE9E8"),
    dim       = rgb("9C8F8A"),  -- secondary text
    faint     = rgb("6B5F5A"),  -- tertiary, placeholders
    accent    = rgb("F2C75B"),  -- the gold of the frames and the pins
    accentDim = rgb("5E4414"),  -- the shadow side of that gold, for fills
    gem       = rgb("2E9BE8"),  -- the blue in the corner art, for anything secondary
    warn      = rgb("FF9A52"),
    danger    = rgb("FF6B6B"),
}

local theme = W.theme

--- The standard UI font family, so sizes can be set without shipping a font.
local FONT = select(1, GameFontNormal:GetFont())
-- Exposed so a module building its own edit box matches the rest of the window.
W.font = FONT

W.size = {
    h1 = 17,
    h2 = 13,
    body = 12,
    small = 11,
    tiny = 10,
}

--------------------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------------------

--- A flat colour texture filling its parent, or a named edge of it.
---@param parent table
---@param color table
---@param layer string?
---@return table texture
function W.Fill(parent, color, layer)
    local texture = parent:CreateTexture(nil, layer or "BACKGROUND")
    texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    texture:SetAllPoints(parent)
    return texture
end

--- A one pixel hairline. `side` is "TOP", "BOTTOM", "LEFT" or "RIGHT".
---@param parent table
---@param side string
---@param color table?
---@param inset number?
---@return table texture
function W.Hairline(parent, side, color, inset)
    color = color or theme.line
    inset = inset or 0
    local texture = parent:CreateTexture(nil, "BORDER")
    texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    if side == "TOP" or side == "BOTTOM" then
        texture:SetHeight(1)
        texture:SetPoint(side == "TOP" and "TOPLEFT" or "BOTTOMLEFT", parent,
            side == "TOP" and "TOPLEFT" or "BOTTOMLEFT", inset, 0)
        texture:SetPoint(side == "TOP" and "TOPRIGHT" or "BOTTOMRIGHT", parent,
            side == "TOP" and "TOPRIGHT" or "BOTTOMRIGHT", -inset, 0)
    else
        texture:SetWidth(1)
        texture:SetPoint(side == "LEFT" and "TOPLEFT" or "TOPRIGHT", parent,
            side == "LEFT" and "TOPLEFT" or "TOPRIGHT", 0, -inset)
        texture:SetPoint(side == "LEFT" and "BOTTOMLEFT" or "BOTTOMRIGHT", parent,
            side == "LEFT" and "BOTTOMLEFT" or "BOTTOMRIGHT", 0, inset)
    end
    return texture
end

--- A hairline box around a frame.
function W.Outline(frame, color)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        W.Hairline(frame, side, color)
    end
end

--- A font string with this addon's type scale.
---@param parent table
---@param size number?
---@param color table?
---@param justify string?
---@return table fontString
function W.Text(parent, size, color, justify)
    local fontString = parent:CreateFontString(nil, "ARTWORK")
    fontString:SetFont(FONT, size or W.size.body, "")
    color = color or theme.text
    fontString:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    fontString:SetJustifyH(justify or "LEFT")
    fontString:SetJustifyV("MIDDLE")
    return fontString
end

--- A small uppercase section label, the only place small caps are used.
function W.SectionLabel(parent, text)
    local fontString = W.Text(parent, W.size.tiny, theme.faint)
    fontString:SetText(string.upper(text))
    return fontString
end

--- "|cffRRGGBB" for a theme colour, for use inside tooltip strings.
---@param color table
---@return string
function W.Hex(color)
    return string.format("|cff%02x%02x%02x",
        math.floor(color[1] * 255), math.floor(color[2] * 255), math.floor(color[3] * 255))
end

--------------------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------------------

--- A flat text button. `kind` is "primary" (accent fill), "ghost" (text only) or nil (raised).
---@param parent table
---@param label string
---@param kind string?
---@return table button
function W.Button(parent, label, kind)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(28)

    local fillColor = kind == "primary" and theme.accentDim
        or kind == "ghost" and { 0, 0, 0, 0 }
        or theme.raised
    button.bg = W.Fill(button, fillColor)

    local textColor = kind == "primary" and theme.accent or theme.text
    button.label = W.Text(button, W.size.body, textColor, "CENTER")
    button.label:SetPoint("CENTER")
    button.label:SetText(label)

    button.kind = kind
    button.baseColor = fillColor

    button:SetScript("OnEnter", function(self)
        if not self:IsEnabled() then return end
        local c = self.kind == "ghost" and theme.raised or theme.hover
        self.bg:SetColorTexture(c[1], c[2], c[3], 1)
    end)
    button:SetScript("OnLeave", function(self)
        local c = self.baseColor
        self.bg:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    end)

    --- Width that fits the label, with comfortable side padding.
    function button:Fit(minimum)
        self:SetWidth(math.max(minimum or 72, self.label:GetStringWidth() + 32))
        return self
    end

    function button:SetEnabledState(enabled)
        self:SetEnabled(enabled)
        local c = enabled and theme.text or theme.faint
        if self.kind == "primary" then c = enabled and theme.accent or theme.faint end
        self.label:SetTextColor(c[1], c[2], c[3])
    end

    return button
end

--- The window's close glyph: a thin x, no Blizzard button art.
function W.CloseButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(28, 28)
    local glyph = W.Text(button, 15, theme.dim, "CENTER")
    glyph:SetPoint("CENTER")
    glyph:SetText("\195\151") -- multiplication sign
    button:SetScript("OnEnter", function() glyph:SetTextColor(unpack(theme.text)) end)
    button:SetScript("OnLeave", function() glyph:SetTextColor(unpack(theme.dim)) end)
    return button
end

--------------------------------------------------------------------------------------------
-- Toggle switch
--------------------------------------------------------------------------------------------

--- A pill switch rather than a checkbox: it reads as a state, not a form field.
---@param parent table
---@param onChange fun(value: boolean)
---@return table toggle
function W.Toggle(parent, onChange)
    local toggle = CreateFrame("Button", nil, parent)
    toggle:SetSize(34, 18)

    toggle.track = W.Fill(toggle, theme.line)
    toggle.knob = toggle:CreateTexture(nil, "ARTWORK")
    toggle.knob:SetSize(14, 14)
    toggle.knob:SetColorTexture(unpack(theme.dim))

    function toggle:SetValue(value, silent)
        self.value = value and true or false
        self.knob:ClearAllPoints()
        if self.value then
            self.knob:SetPoint("RIGHT", self, "RIGHT", -2, 0)
            self.track:SetColorTexture(theme.accentDim[1], theme.accentDim[2], theme.accentDim[3], 1)
            self.knob:SetColorTexture(unpack(theme.accent))
        else
            self.knob:SetPoint("LEFT", self, "LEFT", 2, 0)
            self.track:SetColorTexture(unpack(theme.line))
            self.knob:SetColorTexture(unpack(theme.dim))
        end
        if not silent and onChange then onChange(self.value) end
    end

    toggle:SetScript("OnClick", function(self) self:SetValue(not self.value) end)
    toggle:SetValue(false, true)
    return toggle
end

--- A labelled settings row: description on the left, control on the right.
---@param parent table
---@param label string
---@param description string?
---@return table row
function W.Row(parent, label, description)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(description and 44 or 32)

    row.label = W.Text(row, W.size.body, theme.text)
    row.label:SetPoint("LEFT", row, "LEFT", 0, description and 8 or 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -50, description and 8 or 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetText(label)

    if description then
        row.description = W.Text(row, W.size.small, theme.faint)
        row.description:SetPoint("LEFT", row, "LEFT", 0, -9)
        row.description:SetPoint("RIGHT", row, "RIGHT", -120, -9)
        row.description:SetText(description)
        row.description:SetJustifyH("LEFT")
    end
    return row
end

--------------------------------------------------------------------------------------------
-- Segmented control
--------------------------------------------------------------------------------------------

--- Two to four mutually exclusive options in one strip. Replaces a dropdown for small sets.
---@param parent table
---@param options table[] { {value, label}, ... }
---@param onChange fun(value: any)
---@return table control
function W.Segmented(parent, options, onChange)
    local control = CreateFrame("Frame", nil, parent)
    control:SetHeight(24)
    control.segments = {}

    local count = #options
    for index, option in ipairs(options) do
        local segment = CreateFrame("Button", nil, control)
        segment:SetHeight(24)
        segment.bg = W.Fill(segment, theme.raised)
        segment.label = W.Text(segment, W.size.small, theme.dim, "CENTER")
        segment.label:SetPoint("CENTER")
        segment.label:SetText(option.label)
        segment.underline = segment:CreateTexture(nil, "OVERLAY")
        segment.underline:SetHeight(2)
        segment.underline:SetPoint("BOTTOMLEFT", 0, 0)
        segment.underline:SetPoint("BOTTOMRIGHT", 0, 0)
        segment.underline:SetColorTexture(unpack(theme.accent))
        segment.underline:Hide()
        segment.value = option.value

        segment:SetScript("OnClick", function(self)
            control:SetValue(self.value)
        end)
        segment:SetScript("OnEnter", function(self)
            if control.value ~= self.value then
                self.label:SetTextColor(unpack(theme.text))
            end
        end)
        segment:SetScript("OnLeave", function(self)
            if control.value ~= self.value then
                self.label:SetTextColor(unpack(theme.dim))
            end
        end)

        control.segments[index] = segment
        if index == 1 then
            segment:SetPoint("LEFT", control, "LEFT", 0, 0)
        else
            segment:SetPoint("LEFT", control.segments[index - 1], "RIGHT", 1, 0)
        end
    end

    --- Segments share the width evenly; call after the control's own width is set.
    function control:Layout()
        local total = self:GetWidth()
        local each = math.floor((total - (count - 1)) / count)
        for _, segment in ipairs(self.segments) do segment:SetWidth(each) end
    end

    function control:SetValue(value, silent)
        self.value = value
        for _, segment in ipairs(self.segments) do
            local selected = segment.value == value
            segment.underline:SetShown(selected)
            local c = selected and theme.accent or theme.dim
            segment.label:SetTextColor(c[1], c[2], c[3])
        end
        if not silent and onChange then onChange(value) end
    end

    return control
end

--------------------------------------------------------------------------------------------
-- Search box
--------------------------------------------------------------------------------------------

--- A flat search field: no border except a baseline that lights up on focus.
---@param parent table
---@param placeholder string
---@param onChange fun(text: string)
---@return table box
function W.SearchBox(parent, placeholder, onChange)
    local box = CreateFrame("Frame", nil, parent)
    box:SetHeight(30)
    W.Fill(box, theme.raised)
    box.baseline = W.Hairline(box, "BOTTOM", theme.line)

    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("LEFT", box, "LEFT", 10, 0)
    edit:SetPoint("RIGHT", box, "RIGHT", -28, 0)
    edit:SetHeight(28)
    edit:SetFont(FONT, W.size.body, "")
    edit:SetTextColor(unpack(theme.text))
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(60)
    box.edit = edit

    local hint = W.Text(box, W.size.body, theme.faint)
    hint:SetPoint("LEFT", edit, "LEFT", 1, 0)
    hint:SetText(placeholder)

    local clear = CreateFrame("Button", nil, box)
    clear:SetSize(20, 20)
    clear:SetPoint("RIGHT", box, "RIGHT", -6, 0)
    local clearGlyph = W.Text(clear, 13, theme.faint, "CENTER")
    clearGlyph:SetPoint("CENTER")
    clearGlyph:SetText("\195\151")
    clear:Hide()
    clear:SetScript("OnEnter", function() clearGlyph:SetTextColor(unpack(theme.text)) end)
    clear:SetScript("OnLeave", function() clearGlyph:SetTextColor(unpack(theme.faint)) end)
    clear:SetScript("OnClick", function()
        edit:SetText("")
        edit:ClearFocus()
    end)

    local function changed()
        local text = edit:GetText() or ""
        hint:SetShown(text == "")
        clear:SetShown(text ~= "")
        if onChange then onChange(text) end
    end

    edit:SetScript("OnTextChanged", changed)
    edit:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function()
        box.baseline:SetColorTexture(unpack(theme.accent))
    end)
    edit:SetScript("OnEditFocusLost", function()
        box.baseline:SetColorTexture(unpack(theme.line))
    end)

    return box
end

--------------------------------------------------------------------------------------------
-- Progress bar
--------------------------------------------------------------------------------------------

--- A hairline-thin progress bar. Height is deliberately small; the number above it carries
--- the information.
---@param parent table
---@param height number?
---@return table bar
--- Turn a ScrollFrame into something a player can actually drive: the wheel scrolls it, and
--- a thin indicator appears on the right while there is more than fits. Deliberately the
--- same hairline track W.ScrollList draws, and like that one it hides itself entirely when
--- everything fits rather than sitting there greyed out.
---
--- The child must have a real height for any of this to mean anything; the caller sets that
--- once it has laid its content out, then calls Update.
---@param scrollFrame table
---@param child table the scroll child
---@param step number? pixels per wheel click
---@return table track  with :Update()
function W.ScrollWheel(scrollFrame, child, step)
    step = step or 40

    local track = CreateFrame("Frame", nil, scrollFrame)
    track:SetWidth(3)
    track:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 6, 0)
    track:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 6, 0)
    W.Fill(track, theme.raised)
    track:Hide()

    local thumb = track:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(unpack(theme.line))
    thumb:SetPoint("TOPLEFT")
    thumb:SetPoint("TOPRIGHT")
    thumb:SetHeight(20)

    ---@return number maximum scroll offset
    local function Limit()
        return math.max(0, (child:GetHeight() or 0) - (scrollFrame:GetHeight() or 0))
    end

    function track:Update()
        local limit = Limit()
        if limit <= 1 then
            -- Snap back as well as hide: a window that grew while scrolled down would
            -- otherwise keep its offset and look like it had lost its first rows.
            scrollFrame:SetVerticalScroll(0)
            self:Hide()
            return
        end
        self:Show()

        local visible = scrollFrame:GetHeight() or 1
        local total = child:GetHeight() or 1
        local thumbHeight = math.max(20, visible * visible / total)
        local progress = (scrollFrame:GetVerticalScroll() or 0) / limit
        thumb:SetHeight(thumbHeight)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -(visible - thumbHeight) * progress)
        thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -(visible - thumbHeight) * progress)
    end

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local wanted = (self:GetVerticalScroll() or 0) - delta * step
        self:SetVerticalScroll(math.min(Limit(), math.max(0, wanted)))
        track:Update()
    end)
    scrollFrame:HookScript("OnSizeChanged", function() track:Update() end)

    return track
end

function W.ProgressBar(parent, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height or 4)
    W.Fill(bar, theme.line)

    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetColorTexture(unpack(theme.accent))
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    bar.fill:SetWidth(0.001)

    ---@param percent number 0-100
    function bar:SetPercent(percent)
        percent = math.max(0, math.min(100, percent or 0))
        local width = self:GetWidth() or 0
        self.fill:SetWidth(math.max(0.001, width * percent / 100))
    end

    function bar:SetColor(color)
        self.fill:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    end

    return bar
end

--------------------------------------------------------------------------------------------
-- Scrolling list
--------------------------------------------------------------------------------------------

--- A fixed-row virtualised list: only the visible rows exist as frames, however long the data
--- gets. `createRow` builds one row frame; `updateRow(row, item, index, selected)` fills it.
---@param parent table
---@param rowHeight number
---@param createRow fun(listParent: table): table
---@param updateRow fun(row: table, item: any, index: number, selected: boolean)
---@return table list
function W.ScrollList(parent, rowHeight, createRow, updateRow)
    local list = CreateFrame("Frame", nil, parent)
    list.rowHeight = rowHeight
    list.offset = 0
    list.data = {}
    list.rows = {}

    local track = CreateFrame("Frame", nil, list)
    track:SetWidth(3)
    track:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    W.Fill(track, theme.raised)
    track.thumb = track:CreateTexture(nil, "ARTWORK")
    track.thumb:SetColorTexture(unpack(theme.line))
    track.thumb:SetPoint("TOPLEFT")
    track.thumb:SetPoint("TOPRIGHT")
    track.thumb:SetHeight(20)
    list.track = track

    local function VisibleCount()
        return math.max(1, math.floor((list:GetHeight() or rowHeight) / rowHeight))
    end

    function list:Refresh()
        local visible = VisibleCount()
        local total = #self.data
        local maxOffset = math.max(0, total - visible)
        if self.offset > maxOffset then self.offset = maxOffset end
        if self.offset < 0 then self.offset = 0 end

        for index = 1, visible do
            local row = self.rows[index]
            if not row then
                row = createRow(self)
                row:SetHeight(rowHeight)
                row:SetPoint("LEFT", self, "LEFT", 0, 0)
                row:SetPoint("RIGHT", self.track, "LEFT", -6, 0)
                row:SetPoint("TOP", self, "TOP", 0, -(index - 1) * rowHeight)
                self.rows[index] = row
            end
            local dataIndex = index + self.offset
            local item = self.data[dataIndex]
            if item then
                row.dataIndex = dataIndex
                updateRow(row, item, dataIndex, self.selected == dataIndex)
                row:Show()
            else
                row.dataIndex = nil
                row:Hide()
            end
        end
        for index = visible + 1, #self.rows do self.rows[index]:Hide() end

        -- Scrollbar: hidden entirely when everything fits, rather than greyed out.
        if total <= visible then
            track:Hide()
        else
            track:Show()
            local height = track:GetHeight() or 1
            local thumbHeight = math.max(20, height * visible / total)
            track.thumb:SetHeight(thumbHeight)
            track.thumb:ClearAllPoints()
            track.thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0,
                -(height - thumbHeight) * (self.offset / maxOffset))
            track.thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0,
                -(height - thumbHeight) * (self.offset / maxOffset))
        end
    end

    ---@param data table[]
    ---@param keepPosition boolean?
    function list:SetData(data, keepPosition)
        self.data = data or {}
        if not keepPosition then
            self.offset = 0
            self.selected = nil
        end
        self:Refresh()
    end

    function list:Select(dataIndex)
        self.selected = dataIndex
        self:Refresh()
    end

    function list:SelectedItem()
        return self.selected and self.data[self.selected] or nil
    end

    --- Change the row height after the fact, for the roomier controller layout.
    ---@param height number
    function list:SetRowHeight(height)
        height = tonumber(height)
        if not height or height == rowHeight then return end
        rowHeight = height
        self.rowHeight = height
        for index, row in ipairs(self.rows) do
            row:SetHeight(rowHeight)
            row:ClearAllPoints()
            row:SetPoint("LEFT", self, "LEFT", 0, 0)
            row:SetPoint("RIGHT", self.track, "LEFT", -6, 0)
            row:SetPoint("TOP", self, "TOP", 0, -(index - 1) * rowHeight)
        end
        self:Refresh()
    end

    --- Move the selection, scrolling to keep it on screen. Returns nil when the move would
    --- run off the end, which is how directional navigation knows to leave the list.
    ---@param delta number
    ---@return table? item
    ---@return number? index
    function list:MoveSelection(delta)
        local total = #self.data
        if total == 0 then return nil end
        local current = self.selected or (delta > 0 and 0 or total + 1)
        local index = current + delta
        if index < 1 or index > total then return nil end

        self.selected = index
        local visible = VisibleCount()
        if index <= self.offset then
            self.offset = index - 1
        elseif index > self.offset + visible then
            self.offset = index - visible
        end
        self:Refresh()
        return self.data[index], index
    end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta * 3
        self:Refresh()
    end)
    list:SetScript("OnSizeChanged", function(self) self:Refresh() end)

    return list
end

--------------------------------------------------------------------------------------------
-- Preview row stack
--------------------------------------------------------------------------------------------

-- Row heights, and the space that opens up around a heading. The preview reads as a set of
-- short blocks rather than one dense column, so the heading spacing matters more than the
-- row spacing: a section needs air above it and almost none below.
local ROW = {
    line = 17,
    double = 17,
    item = 21,
    section = 18,
    blank = 9,
}
local SECTION_TOP_PAD = 12
local INDENT_PX = 14
-- Added to the measured text height when a row wraps, so two lines do not touch the rows
-- above and below them.
local WRAP_PAD = 5

--- Renders the row model Render.Build produces into real frames. Shared by the quest giver
--- side panel and the browser's detail pane, so a preview looks the same in both.
--- Reward rows carry an item id and show the real item tooltip on hover; rows carrying a
--- quest id are links that open that quest in the browser.
---@param parent table
---@return table stack
function W.RowStack(parent)
    local stack = CreateFrame("Frame", nil, parent)
    stack.pool = {}

    local function Acquire(index)
        local row = stack.pool[index]
        if row then return row end

        row = CreateFrame("Button", nil, stack)
        row:SetPoint("LEFT", stack, "LEFT", 0, 0)
        row:SetPoint("RIGHT", stack, "RIGHT", 0, 0)

        row.highlight = row:CreateTexture(nil, "BACKGROUND")
        row.highlight:SetPoint("TOPLEFT", row, "TOPLEFT", -6, 0)
        row.highlight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 6, 0)
        row.highlight:SetColorTexture(theme.hover[1], theme.hover[2], theme.hover[3], 1)
        row.highlight:Hide()

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.left = W.Text(row, W.size.small, theme.text)
        row.right = W.Text(row, W.size.small, theme.dim, "RIGHT")
        row.right:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        row:SetScript("OnEnter", function(self)
            if self.questId then
                self.highlight:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.questName or "Quest", 1, 1, 1)
                GameTooltip:AddLine("Click to open this quest in the browser.", 0.55, 0.57, 0.62)
                GameTooltip:Show()
                return
            end
            if not self.itemId then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetItemByID then
                GameTooltip:SetItemByID(self.itemId)
            else
                GameTooltip:SetHyperlink("item:" .. self.itemId)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self)
            if self.questId and QEF.Browse and QEF.Browse.Open then
                QEF.Browse.Open(self.questId)
            end
        end)

        stack.pool[index] = row
        return row
    end

    --- Lay out a row model. Returns the total height used, so the caller can size itself.
    ---@param model table[]
    ---@return number height
    function stack:SetRows(model)
        local used = 0
        local y = 0
        local previousKind

        for _, row in ipairs(model or {}) do
            if row.kind == "blank" then
                y = y - ROW.blank
            else
                -- A heading gets its air above it, unless it is the very first thing or
                -- already follows a deliberate gap.
                if row.kind == "section" and previousKind and previousKind ~= "blank" then
                    y = y - SECTION_TOP_PAD
                end

                used = used + 1
                local widget = Acquire(used)
                local isSection = row.kind == "section"
                local baseHeight = isSection and ROW.section
                    or (row.icon and ROW.item)
                    or ROW[row.kind] or ROW.line

                widget:ClearAllPoints()
                widget:SetPoint("LEFT", self, "LEFT", 0, 0)
                widget:SetPoint("RIGHT", self, "RIGHT", 0, 0)
                widget:SetPoint("TOP", self, "TOP", 0, y)

                local indent = (row.indent or 0) * INDENT_PX

                -- The right-hand value is laid out first, because how much room it takes
                -- decides how much the left text has to wrap into. It sits on the first
                -- line, so a wrapped row still reads as one entry.
                widget.right:ClearAllPoints()
                widget.right:SetPoint("TOPRIGHT", widget, "TOPRIGHT", 0, 0)
                widget.right:SetHeight(baseHeight)
                -- Both halves are top-aligned, so a value stays level with the first line
                -- of a label that wrapped.
                widget.right:SetJustifyV("TOP")
                widget.right:SetText((not isSection) and row.kind == "double"
                    and row.right or "")

                local iconWidth = 0
                widget.left:ClearAllPoints()
                if row.icon then
                    widget.icon:Show()
                    widget.icon:SetSize(16, 16)
                    widget.icon:SetTexture(row.icon)
                    widget.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    widget.icon:ClearAllPoints()
                    widget.icon:SetPoint("TOPLEFT", widget, "TOPLEFT", indent, -2)
                    iconWidth = 23
                else
                    widget.icon:Hide()
                end
                widget.left:SetPoint("TOPLEFT", widget, "TOPLEFT", indent + iconWidth, 0)
                widget.left:SetJustifyV("TOP")

                if isSection then
                    -- Headings are the only small caps in the preview, and they are faint:
                    -- they label the block without competing with its contents.
                    widget.left:SetFont(select(1, GameFontNormal:GetFont()), W.size.tiny, "")
                    widget.left:SetTextColor(unpack(theme.faint))
                    widget.left:SetText(string.upper(row.left or ""))
                else
                    widget.left:SetFont(select(1, GameFontNormal:GetFont()), W.size.small, "")
                    widget.left:SetTextColor(unpack(theme.text))
                    widget.left:SetText(row.left or "")
                end

                -- Wrap rather than clip. An objective or a travel step is routinely longer
                -- than the pane is wide, and losing its tail loses the point of the line.
                -- The width is set outright rather than left to the anchors, so the height
                -- can be measured in this pass instead of a frame later.
                local height = baseHeight
                local stackWidth = self:GetWidth() or 0
                if stackWidth > 1 then
                    local rightWidth = widget.right:GetStringWidth() or 0
                    if rightWidth > 0 then rightWidth = rightWidth + 10 end
                    local available = stackWidth - indent - iconWidth - rightWidth
                    if available < 40 then available = 40 end
                    widget.left:SetWidth(available)
                    local textHeight = widget.left:GetStringHeight() or 0
                    if textHeight + WRAP_PAD > height then
                        height = math.ceil(textHeight) + WRAP_PAD
                    end
                end
                widget:SetHeight(height)
                widget.itemId = row.itemId
                -- A row carrying a quest id is a link: clicking it opens that quest, which is
                -- how a player walks back up a chain to find where it starts.
                widget.questId = row.questId
                widget.questName = row.questName
                widget:EnableMouse(row.itemId ~= nil or row.questId ~= nil)
                widget:Show()

                y = y - height
            end
            previousKind = row.kind
        end

        for index = used + 1, #self.pool do self.pool[index]:Hide() end
        self.usedRows = used
        return -y
    end

    function stack:Clear()
        for _, row in ipairs(self.pool) do row:Hide() end
        self.usedRows = 0
    end

    return stack
end

--------------------------------------------------------------------------------------------
-- Window shell
--------------------------------------------------------------------------------------------

--- Every window this makes, so a look-and-feel setting can reach the ones already built.
W.windows = {}

--- Show or hide the painted frame art on every window at once.
function W.RefreshFrameArt()
    local shown = QEF.Get("frameArt") and true or false
    for _, window in ipairs(W.windows) do
        if window.SetFrameArt then window:SetFrameArt(shown) end
    end
end

--- A draggable, escapable window with a title bar and no Blizzard chrome.
---@param globalName string
---@param width number
---@param height number
---@param titleText string
---@return table window
function W.Window(globalName, width, height, titleText)
    local window = CreateFrame("Frame", globalName, UIParent)
    window:SetSize(width, height)
    window:SetPoint("CENTER")
    -- Above the side panel, which is HIGH. The two are different kinds of thing: the panel
    -- rides along with whatever Blizzard frame is open, while a window of this addon's own
    -- is something you deliberately opened, so it belongs in front rather than tied for
    -- position and settled by whichever frame happened to be built first.
    window:SetFrameStrata("DIALOG")
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:Hide()

    W.Fill(window, theme.bg)
    W.Outline(window, theme.line)

    local titleBar = CreateFrame("Frame", nil, window)
    titleBar:SetHeight(46)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)
    window.titleBar = titleBar

    local title = W.Text(titleBar, W.size.h1, theme.text)
    title:SetPoint("LEFT", titleBar, "LEFT", 20, 0)
    title:SetText(titleText)
    window.title = title

    -- The addon's mark where the accent dot used to be. Art.lua loads after this file, so
    -- it is asked for when a window is built rather than captured up front, and the dot
    -- remains the fallback for the case where it is not there. The mark needs more room
    -- than a six pixel dot, so the title moves over for it rather than the other way.
    local mark
    if QEF.Art and QEF.Art.Brand then
        mark = QEF.Art.Brand(titleBar, 15)
        mark:SetPoint("LEFT", titleBar, "LEFT", 18, 0)
        title:ClearAllPoints()
        title:SetPoint("LEFT", mark, "RIGHT", 9, 0)
    else
        mark = titleBar:CreateTexture(nil, "ARTWORK")
        mark:SetSize(6, 6)
        mark:SetColorTexture(unpack(theme.accent))
        mark:SetPoint("RIGHT", title, "LEFT", -8, 1)
    end
    window.mark = mark

    local close = W.CloseButton(titleBar)
    close:SetPoint("RIGHT", titleBar, "RIGHT", -10, 0)
    close:SetScript("OnClick", function() window:Hide() end)

    -- The painted frame: gold at the four corners and a thin ornament under the title.
    -- Built whether or not it is switched on, and shown or hidden from the setting, so
    -- turning it off is something you see rather than something you reload for.
    if QEF.Art and QEF.Art.WindowFrame then
        window.frameArt = QEF.Art.WindowFrame(window)
        -- Sized from the window but kept small: it marks the title bar's edge rather than
        -- spanning it.
        window.divider = QEF.Art.Divider(titleBar, width * 0.26)
    end

    ---@param shown boolean
    function window:SetFrameArt(shown)
        if self.frameArt then self.frameArt:SetShown(shown) end
        if self.divider then self.divider:SetShown(shown) end
    end

    W.windows[#W.windows + 1] = window
    window:SetFrameArt(QEF.Get("frameArt") and true or false)

    window.subtitle = W.Text(titleBar, W.size.small, theme.faint, "RIGHT")
    window.subtitle:SetPoint("RIGHT", close, "LEFT", -12, 0)
    window.subtitle:SetWordWrap(false)

    --- Shrink the window if it would not fit the screen at this player's UI scale.
    --- A window taller than the screen loses its bottom row of buttons and cannot be
    --- dragged back into view, which is a much worse failure than slightly smaller text.
    --- Recomputed from the unscaled size each time, so it is safe to call repeatedly and
    --- after the window has changed height.
    function window:FitToScreen()
        local availableWidth = (UIParent:GetWidth() or 1024) - 24
        local availableHeight = (UIParent:GetHeight() or 768) - 24
        local ownWidth = self:GetWidth() or 1
        local ownHeight = self:GetHeight() or 1
        if ownWidth <= 0 or ownHeight <= 0 then return end
        local fit = math.min(1, availableWidth / ownWidth, availableHeight / ownHeight)
        -- Past about two thirds the text stops being readable, and a clipped window is
        -- then the better of two bad options.
        self:SetScale(math.max(fit, 0.65))
    end

    window:FitToScreen()
    window:HookScript("OnShow", window.FitToScreen)
    for _, event in ipairs({ "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
        QEF.On(event, function()
            if window:IsShown() then window:FitToScreen() end
        end)
    end

    tinsert(UISpecialFrames, globalName)
    return window
end

--------------------------------------------------------------------------------------------
-- Focus ring
--------------------------------------------------------------------------------------------

--- A bracket drawn around whatever currently has focus. Corner brackets rather than a full
--- outline: a box around a row that already has a background reads as a second border, while
--- brackets read as a cursor.
---@param parent table
---@return table ring
function W.FocusRing(parent)
    local ring = CreateFrame("Frame", nil, parent)
    ring:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    ring:Hide()

    local LENGTH, THICKNESS = 9, 2
    local corners = {
        { "TOPLEFT", 1, -1 }, { "TOPRIGHT", -1, -1 },
        { "BOTTOMLEFT", 1, 1 }, { "BOTTOMRIGHT", -1, 1 },
    }
    for _, corner in ipairs(corners) do
        local point, xDirection, yDirection = corner[1], corner[2], corner[3]
        local horizontal = ring:CreateTexture(nil, "OVERLAY")
        horizontal:SetSize(LENGTH, THICKNESS)
        horizontal:SetPoint(point, ring, point, 0, 0)
        horizontal:SetColorTexture(unpack(theme.accent))

        local vertical = ring:CreateTexture(nil, "OVERLAY")
        vertical:SetSize(THICKNESS, LENGTH)
        vertical:SetPoint(point, ring, point, 0, 0)
        vertical:SetColorTexture(unpack(theme.accent))
        -- Unused, but kept readable: the direction values say which way each arm runs.
        ring[point] = { horizontal, vertical, xDirection, yDirection }
    end

    --- Put the ring around a frame, or hide it when there is nothing focused.
    ---@param frame table?
    ---@param inset number?
    function ring:Attach(frame, inset)
        if not frame or not frame.GetObjectType then
            self:Hide()
            return
        end
        inset = inset or 3
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", frame, "TOPLEFT", -inset, inset)
        self:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", inset, -inset)
        self:Show()
    end

    return ring
end

--------------------------------------------------------------------------------------------
-- Quest level colouring
--------------------------------------------------------------------------------------------

--- Blizzard's difficulty colour for a quest level, which gives the browser its level badges.
---@param questLevel number?
---@return table color
function W.LevelColor(questLevel)
    questLevel = QEF.Num(questLevel)
    if not questLevel then return theme.dim end
    local playerLevel = QEF.Num(UnitLevel("player")) or questLevel
    local difference = questLevel - playerLevel
    if difference >= 5 then return theme.danger end
    if difference >= 3 then return W.theme.warn end
    if difference >= -2 then return { 1, 1, 0.3 } end
    if difference >= -7 then return { 0.3, 0.85, 0.3 } end
    return theme.faint
end
