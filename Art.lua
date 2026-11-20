-- Art.lua
--
-- Iconography, kept in one place so the window has a consistent visual language.
--
-- No art files are shipped. Two techniques do the work instead:
--
--   * Blizzard's own icons, desaturated and tinted to a theme colour. A colourful 64px icon
--     dropped into a flat dark panel looks like a sticker; the same icon desaturated and
--     tinted at 14px reads as a monochrome glyph and belongs there.
--   * Flat colour textures for rules, markers and the accent underline.
--
-- Faction emblems are the exception: those are shown in their own colours, because the whole
-- point of them is to be recognised at a glance.

local ADDON, QEF = ...

local Art = {}
QEF.Art = Art

local W, theme

--------------------------------------------------------------------------------------------
-- Icon names
--------------------------------------------------------------------------------------------

-- Every path here ships with the client. Icons are chosen for silhouette rather than colour,
-- since colour is thrown away by the desaturation pass.
Art.icon = {
    -- The addon's own mark, and the same icon the .toc hands the addon list. A spyglass
    -- for an explorer, and deliberately the one the browser page already carries: the
    -- browser is the front door, so one mark does for both rather than inventing a second.
    addon    = "Interface\\Icons\\INV_Misc_Spyglass_02",
    browse   = "Interface\\Icons\\INV_Misc_Spyglass_02",
    sweep    = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    settings = "Interface\\Icons\\Trade_Engineering",
    quest    = "Interface\\GossipFrame\\AvailableQuestIcon",
    active   = "Interface\\GossipFrame\\ActiveQuestIcon",
    dungeon  = "Interface\\Icons\\INV_Misc_Key_03",
    chain    = "Interface\\Icons\\INV_Misc_ChainLink",
    waypoint = "Interface\\Icons\\INV_Misc_Map_01",
    travel   = "Interface\\Icons\\Ability_Mount_RidingHorse",
    locked   = "Interface\\Buttons\\LockButton-Locked-Up",
    article  = "Interface\\Icons\\INV_Misc_Book_09",
    checklist = "Interface\\Icons\\INV_Scroll_03",
    waiting  = "Interface\\RaidFrame\\ReadyCheck-Waiting",

    -- Long-standing interface art rather than spell icons. These are already flat single
    -- colour glyphs, so they must not have the icon border crop applied to them.
    caret    = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
    back     = "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up",
}

-- Interface art has no icon border, so cropping it would cut the glyph itself.
local NO_CROP = { caret = true, back = true, locked = true, quest = true, active = true,
    waiting = true }

Art.faction = {
    Alliance = {
        texture = "Interface\\PVPFrame\\PVP-Currency-Alliance",
        fallback = "Interface\\FriendsFrame\\PlusManz-Alliance",
        color = { 0.25, 0.49, 0.82 },
        short = "A",
        label = "Alliance",
    },
    Horde = {
        texture = "Interface\\PVPFrame\\PVP-Currency-Horde",
        fallback = "Interface\\FriendsFrame\\PlusManz-Horde",
        color = { 0.78, 0.19, 0.17 },
        short = "H",
        label = "Horde",
    },
}

--------------------------------------------------------------------------------------------
-- Glyphs
--------------------------------------------------------------------------------------------

--- A themed glyph: a client icon reduced to a tinted monochrome mark.
---@param parent table
---@param iconName string key into Art.icon
---@param size number
---@param color table?
---@return table texture
function Art.Glyph(parent, iconName, size, color)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(size, size)
    texture:SetTexture(Art.icon[iconName] or iconName)
    texture:SetDesaturated(true)
    -- Spell and item icons carry a border in the outer few pixels; cropping leaves just
    -- the mark. Interface art has none and must be left whole.
    if not NO_CROP[iconName] then
        texture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end
    color = color or theme.dim
    texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    texture.qpTint = function(_, newColor)
        texture:SetVertexColor(newColor[1], newColor[2], newColor[3], newColor[4] or 1)
    end
    return texture
end

--------------------------------------------------------------------------------------------
-- Map pin art
--------------------------------------------------------------------------------------------

-- The one place the addon ships art of its own rather than borrowing the client's. A map
-- pin has to read at twenty pixels against a painted map, which a tinted interface glyph
-- does not: these are drawn for the job.
--
-- Each file is a 128x128 TGA - the client wants powers of two - with the pin scaled to the
-- full height and the width left transparent, so `u` is how much of the texture is actually
-- the pin. Draw it with SetTexCoord(0, u, 0, 1) and a frame of that aspect, or it stretches.
Art.pinPath = "Interface\\AddOns\\QuestExplorerForever\\art\\"

-- Six styles of the same two marks. A map wearing all six at once is a fairground; one
-- style reads as a system, so the style is chosen once and every pin wears it. The `u` is
-- how much of each texture is pin rather than transparent padding.
Art.pinArt = {
    ["bang-slate"]      = 0.7109, ["query-slate"]     = 0.6953,
    ["bang-blue"]       = 0.6953, ["query-blue"]      = 0.6797,
    ["bang-parchment"]  = 0.7109, ["query-parchment"] = 0.6719,
    ["bang-gem"]        = 0.6797, ["query-gem"]       = 0.6719,
    ["bang-glow"]       = 0.6719, ["query-glow"]      = 0.7031,
    ["bang-green"]      = 0.7109, ["query-green"]     = 0.6797,
}

--- The styles a player can pick between, in the order the setting offers them.
Art.pinStyles = { "slate", "blue", "parchment", "gem", "glow", "green" }

--- Put a pin texture on a texture object, with the coordinates that cut off the
--- transparent padding.
---@param texture table
---@param mark string "bang" for something to go to, "query" for something to hand in
---@param style string? one of Art.pinStyles; the chosen style when omitted
---@return number aspect  width over height, for sizing the frame it sits in
function Art.SetPin(texture, mark, style)
    style = style or QEF.Get("pinStyle") or "slate"
    local file = (mark == "query" and "query-" or "bang-") .. style
    local u = Art.pinArt[file]
    if not u then
        file = (mark == "query" and "query-" or "bang-") .. "slate"
        u = Art.pinArt[file]
    end

    texture:SetTexture(Art.pinPath .. file .. ".tga")
    texture:SetTexCoord(0, u, 0, 1)
    texture:SetDesaturated(false)
    texture:SetVertexColor(1, 1, 1, 1)
    return u
end

--------------------------------------------------------------------------------------------
-- Window frame art
--------------------------------------------------------------------------------------------

-- One corner texture, used four times. The art is flush with its texture's top left and
-- the rest of the square is transparent, which means the other three corners are the same
-- file with its coordinates flipped - no second file, and no chance of the four drifting
-- apart when one of them is redrawn.
local CORNER_COORDS = {
    TOPLEFT     = { 0, 1, 0, 1 },
    TOPRIGHT    = { 1, 0, 0, 1 },
    BOTTOMLEFT  = { 0, 1, 1, 0 },
    BOTTOMRIGHT = { 1, 0, 1, 0 },
}

-- The divider is a wide thin ornament that fills the top of its texture; the rest is
-- padding, and this is how much of it to draw.
local DIVIDER_V = 0.7969

-- The edge art is a horizontal rod, so the two upright edges are the same texture turned a
-- quarter turn. The eight-argument form of SetTexCoord says which part of the texture goes
-- to each corner of the quad, which is the only way to rotate a texture that is not square
-- without it clipping itself.
local EDGE_TURNED = { 0, 1, 1, 1, 0, 0, 1, 0 }

--- Frame a window in the gold art: four corners, and a rod along each edge between them.
---
--- On a layer of its own rather than on the window: a child frame draws above every texture
--- of its parent whatever the layer says, so corners drawn on the window itself disappear
--- behind the first thing anchored over them - which on the browser is the nav rail sitting
--- on the bottom left one.
---
--- Sized from the window rather than fixed, because the corner that suits a 480 pixel
--- dialog is a postage stamp on a 1080 pixel browser.
---@param window table
---@return table overlay  the frame holding all eight pieces, to show and hide as one
function Art.WindowFrame(window)
    local width = window:GetWidth() or 400
    local size = math.max(26, math.min(46, width * 0.045))

    local overlay = CreateFrame("Frame", nil, window)
    overlay:SetAllPoints(window)
    overlay:SetFrameLevel((window:GetFrameLevel() or 1) + 50)
    -- Decoration only: clicks belong to whatever is underneath.
    overlay:EnableMouse(false)

    -- Edges first, corners over them: the rods run the whole way to the corners and the
    -- corner art covers where they end, so no join has to line up to the pixel.
    local thickness = 14
    local tuck = size - 10

    local function edge(from, to, horizontal)
        local texture = overlay:CreateTexture(nil, "OVERLAY")
        texture:SetTexture(Art.pinPath .. "edge.tga")
        if horizontal then
            texture:SetHeight(thickness)
            texture:SetPoint(from, overlay, from, tuck, 0)
            texture:SetPoint(to, overlay, to, -tuck, 0)
        else
            texture:SetTexCoord(unpack(EDGE_TURNED))
            texture:SetWidth(thickness)
            texture:SetPoint(from, overlay, from, 0, -tuck)
            texture:SetPoint(to, overlay, to, 0, tuck)
        end
    end

    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)

    for point, coords in pairs(CORNER_COORDS) do
        local texture = overlay:CreateTexture(nil, "OVERLAY")
        texture:SetTexture(Art.pinPath .. "corner.tga")
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        texture:SetSize(size, size)
        texture:SetPoint(point, overlay, point, 0, 0)
    end
    return overlay
end

--- The gold ornament that marks a title bar's lower edge.
---
--- Straddling the seam rather than hanging below it: a band under the title bar is a second
--- piece of chrome competing with whatever the window puts at the top of its content, which
--- on the browser is a toolbar. Sat on the line, it decorates the line.
---
--- It is also small. The art is ten times wider than it is tall, so a width set from the
--- window's turns a 1080 pixel window's ornament into a seventy pixel banner.
---@param titleBar table  the ornament belongs to the bar, so that it draws above its fill
---@param width number? overridden within sane bounds
---@return table texture
function Art.Divider(titleBar, width)
    local drawn = math.max(170, math.min(300, width or 260))

    local texture = titleBar:CreateTexture(nil, "OVERLAY")
    texture:SetTexture(Art.pinPath .. "divider.tga")
    texture:SetTexCoord(0, 1, 0, DIVIDER_V)
    texture:SetSize(drawn, drawn * 0.10)
    texture:SetPoint("CENTER", titleBar, "BOTTOM", 0, 0)
    return texture
end

--- The addon's mark, for a window or panel header. Tinted like every other glyph so it
--- reads as part of the interface rather than as a sticker on it.
---@param parent table
---@param size number?
---@return table texture
function Art.Brand(parent, size)
    return Art.Glyph(parent, "addon", size or 14, theme.accent)
end

--- Retint a glyph made by Art.Glyph.
function Art.Tint(texture, color)
    if not texture or not color then return end
    texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
end

--------------------------------------------------------------------------------------------
-- Faction emblems
--------------------------------------------------------------------------------------------

--- A faction emblem texture, in its own colours.
---@param parent table
---@param faction string? "Alliance", "Horde" or nil
---@param size number
---@return table texture
function Art.FactionIcon(parent, faction, size)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(size, size)
    Art.SetFaction(texture, faction)
    return texture
end

---@param texture table
---@param faction string?
function Art.SetFaction(texture, faction)
    local entry = faction and Art.faction[faction]
    if not entry then
        texture:Hide()
        return
    end
    texture:SetTexture(entry.texture)
    texture:SetVertexColor(1, 1, 1, 1)
    texture:Show()
end

--- An inline faction emblem for a tooltip or preview row.
--- Falls back to a coloured letter when the texture is missing, which keeps the information
--- even on a client where the emblem path has moved.
---@param faction string?
---@param size number?
---@return string markup
function Art.FactionMarkup(faction, size)
    local entry = faction and Art.faction[faction]
    if not entry then return "" end
    size = size or 14
    return ("|T%s:%d:%d:0:0|t"):format(entry.texture, size, size)
end

--- "|cffRRGGBBAlliance|r"
---@param faction string?
---@return string?
function Art.FactionLabel(faction)
    local entry = faction and Art.faction[faction]
    if not entry then return nil end
    return W.Hex(entry.color) .. entry.label .. "|r"
end

--- The player's own faction, as the keys used here.
---@return string? faction
function Art.PlayerFaction()
    local faction = QEF.Str(QEF.Try(UnitFactionGroup, "player"))
    if faction == "Alliance" or faction == "Horde" then return faction end
    return nil
end

--------------------------------------------------------------------------------------------
-- Quest status
--------------------------------------------------------------------------------------------

-- Ready-check and gossip icons are used as status marks because they ship with every client
-- and already mean roughly the right things to anyone who plays the game.
Art.status = {
    completed = {
        texture = "Interface\\RaidFrame\\ReadyCheck-Ready",
        label = "Completed", short = "done", color = { 0.3, 0.8, 0.4 },
    },
    ready = {
        texture = "Interface\\GossipFrame\\ActiveQuestIcon",
        label = "Ready to turn in", short = "turn in", color = { 1, 0.82, 0 },
    },
    active = {
        texture = "Interface\\RaidFrame\\ReadyCheck-Waiting",
        label = "In your quest log", short = "on it", color = { 1, 0.82, 0 },
    },
    available = {
        texture = "Interface\\GossipFrame\\AvailableQuestIcon",
        label = "Available", short = nil, color = { 0.9, 0.9, 0.9 },
    },
    locked = {
        texture = "Interface\\Buttons\\LockButton-Locked-Up",
        label = "Locked - you need an earlier quest first", short = "locked",
        color = { 1, 0.6, 0.32 },
        -- The padlock sits in the middle of its texture with a wide transparent margin, so
        -- at a shared size it reads far smaller than the ! and ? marks beside it. Drawn
        -- larger, and nudged down, it matches them optically rather than numerically.
        scale = 1.6, offsetY = -2,
    },
    faction = {
        texture = nil,
        label = "Other faction", short = "other faction", color = { 0.45, 0.47, 0.52 },
    },
}

---@param status string?
---@return table? entry
function Art.StatusInfo(status)
    return status and Art.status[status] or nil
end

--- An inline status mark for a preview row. Statuses with no icon get nothing, because a
--- preview full of grey dots is worse than a preview without them.
---@param status string?
---@param size number?
---@return string markup
function Art.StatusMarkup(status, size)
    local entry = Art.StatusInfo(status)
    if not entry or not entry.texture then return "" end
    size = size or 12
    local drawn = math.floor(size * (entry.scale or 1) + 0.5)
    return ("|T%s:%d:%d:0:%d|t "):format(entry.texture, drawn, drawn, entry.offsetY or 0)
end

--- " (done)" style suffix, coloured, or an empty string for the unremarkable states.
---@param status string?
---@return string
function Art.StatusSuffix(status)
    local entry = Art.StatusInfo(status)
    if not entry or not entry.short then return "" end
    return " " .. W.Hex(entry.color) .. "(" .. entry.short .. ")|r"
end

--- A status texture for a real row widget. Returns the texture and whether it has art; when
--- it has none the caller should show its dot instead.
---@param parent table
---@param size number
---@return table texture
function Art.StatusIcon(parent, size)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(size, size)
    -- Remembered so SetStatus can apply a per-status scale without the caller knowing.
    texture.qpBaseSize = size
    return texture
end

---@param texture table
---@param status string?
---@return boolean hasArt
function Art.SetStatus(texture, status)
    local entry = Art.StatusInfo(status)
    if not entry or not entry.texture then
        texture:Hide()
        return false
    end
    local base = texture.qpBaseSize
    if base then
        local drawn = base * (entry.scale or 1)
        texture:SetSize(drawn, drawn)
    end
    texture:SetTexture(entry.texture)
    texture:SetVertexColor(1, 1, 1, 1)
    texture:Show()
    return true
end

--------------------------------------------------------------------------------------------
-- Legend
--------------------------------------------------------------------------------------------

-- The marks a player meets in the browser and in a preview, in the order they make sense
-- read together: what you can do now, what you are doing, what you have done, what you
-- cannot do yet, and what the row is flagged as.
Art.legend = {
    { status = "available", text = "Available to pick up" },
    { status = "ready",     text = "Ready to turn in" },
    { status = "active",    text = "In your quest log" },
    { status = "completed", text = "Already completed" },
    { status = "locked",    text = "Locked - an earlier quest comes first" },
    { icon = "dungeon", color = "warn", text = "Dungeon quest" },
}

--- Build a legend into a parent frame, laid out in columns. Sets the frame's height to
--- whatever the rows needed, so the caller can anchor beneath it.
---@param parent table
---@param columns number?
---@param width number
---@return table frame
function Art.BuildLegend(parent, columns, width)
    columns = columns or 2
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetWidth(width)

    local ROW_HEIGHT = 20
    local ICON = 13
    local columnWidth = width / columns
    local rows = math.ceil(#Art.legend / columns)

    for index, item in ipairs(Art.legend) do
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = column * columnWidth
        local y = -row * ROW_HEIGHT

        local mark
        if item.status then
            local entry = Art.StatusInfo(item.status)
            mark = frame:CreateTexture(nil, "ARTWORK")
            local drawn = ICON * (entry.scale or 1)
            mark:SetSize(drawn, drawn)
            mark:SetTexture(entry.texture)
        else
            mark = Art.Glyph(frame, item.icon, ICON, theme[item.color] or theme.dim)
        end
        mark:SetPoint("LEFT", frame, "TOPLEFT", x + 8, y - ROW_HEIGHT / 2)

        local label = W.Text(frame, W.size.small, theme.dim)
        label:SetPoint("LEFT", frame, "TOPLEFT", x + 26, y - ROW_HEIGHT / 2)
        label:SetWidth(columnWidth - 32)
        label:SetJustifyH("LEFT")
        label:SetText(item.text)
    end

    frame:SetHeight(rows * ROW_HEIGHT)
    return frame
end

--------------------------------------------------------------------------------------------
-- Decoration
--------------------------------------------------------------------------------------------

--- A hairline that starts at the accent colour and fades out along its length. Used under the
--- title bar, where a flat rule looked abrupt and a full accent line looked loud.
---@param parent table
---@param anchorFrame table
---@param totalWidth number
---@param segments number?
function Art.AccentUnderline(parent, anchorFrame, totalWidth, segments)
    segments = segments or 8
    local segmentWidth = totalWidth / segments
    for index = 1, segments do
        local piece = parent:CreateTexture(nil, "OVERLAY")
        piece:SetHeight(1)
        piece:SetWidth(segmentWidth)
        piece:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", (index - 1) * segmentWidth, 0)
        local alpha = (1 - (index - 1) / segments) * 0.8
        piece:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], alpha)
    end
end

--- A small square marker, used for the dungeon dot and similar.
---@param parent table
---@param size number
---@param color table
---@return table texture
function Art.Dot(parent, size, color)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(size, size)
    texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return texture
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Art", function()
    W = QEF.Widgets
    theme = W.theme
end)
