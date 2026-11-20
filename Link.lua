-- Link.lua
--
-- Wowhead links for a quest.
--
-- The client cannot open a browser, and chat does not make a URL clickable, so the only
-- thing that actually works is handing you the address in a box you can copy out of. That
-- is what this does: one small window, the URL already selected, Ctrl+C and Escape.
--
-- The links point at **Classic** Wowhead, because this is a Classic-era ruleset. Quest ids
-- come from QuestieDB, which is built for this server, so a quest the realm has added or
-- rewritten can have an id Wowhead does not know or describes differently. The window says
-- so rather than pretending every link is good.

local ADDON, QEF = ...

local Link = {}
QEF.Link = Link

local W, theme, Art

local modal, caption, editBox, subcaption
local WIDTH = 520
local HEIGHT = 215

--- Change these two lines to point somewhere else; nothing depends on the host.
Link.base = "https://www.wowhead.com/classic/"
Link.pattern = {
    quest = "quest=%d",
    npc = "npc=%d",
    item = "item=%d",
}

--------------------------------------------------------------------------------------------
-- URLs
--------------------------------------------------------------------------------------------

--- A Wowhead URL, or nil when the kind or the id is not usable.
---@param kind string "quest", "npc" or "item"
---@param id number
---@return string?
function Link.Url(kind, id)
    local pattern = Link.pattern[kind]
    id = QEF.Num(id)
    if not pattern or not id or id <= 0 then return nil end
    return Link.base .. pattern:format(id)
end

---@param questId number
---@return string?
function Link.QuestUrl(questId)
    return Link.Url("quest", QEF.QuestId(questId))
end

--------------------------------------------------------------------------------------------
-- The copy window
--------------------------------------------------------------------------------------------

local function Build()
    if modal then return modal end

    modal = W.Window("QuestExplorerForeverLink", WIDTH, HEIGHT, "Wowhead")
    modal:SetFrameStrata("FULLSCREEN_DIALOG")

    local glyph = Art.Glyph(modal, "article", 15, theme.accent)
    glyph:SetPoint("TOPLEFT", modal.titleBar, "BOTTOMLEFT", 22, -4)

    caption = W.Text(modal, W.size.body, theme.text)
    caption:SetPoint("LEFT", glyph, "RIGHT", 8, 0)
    caption:SetPoint("RIGHT", modal, "RIGHT", -22, 0)
    caption:SetJustifyH("LEFT")

    local box = CreateFrame("Frame", nil, modal)
    box:SetHeight(32)
    box:SetPoint("TOPLEFT", modal, "TOPLEFT", 22, -92)
    box:SetPoint("RIGHT", modal, "RIGHT", -22, 0)
    W.Fill(box, theme.raised)
    W.Hairline(box, "BOTTOM", theme.accentDim)

    editBox = CreateFrame("EditBox", nil, box)
    editBox:SetPoint("LEFT", box, "LEFT", 10, 0)
    editBox:SetPoint("RIGHT", box, "RIGHT", -10, 0)
    editBox:SetHeight(30)
    editBox:SetFont(W.font, W.size.body, "")
    editBox:SetTextColor(unpack(theme.text))
    editBox:SetAutoFocus(false)
    -- Long enough for any of these, and the text is never meant to be typed into anyway.
    editBox:SetMaxLetters(200)

    -- The box exists to be copied from, not edited. Anything typed into it puts the URL
    -- straight back, so a stray keypress cannot hand you a broken address.
    editBox:SetScript("OnTextChanged", function(self, byUser)
        if byUser and self.url and self:GetText() ~= self.url then
            self:SetText(self.url)
            self:HighlightText()
        end
    end)
    editBox:SetScript("OnEscapePressed", function() Link.Hide() end)
    editBox:SetScript("OnEnterPressed", function(self) self:HighlightText() end)

    subcaption = W.Text(modal, W.size.tiny, theme.faint)
    subcaption:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 1, -10)
    subcaption:SetPoint("RIGHT", modal, "RIGHT", -22, 0)
    subcaption:SetJustifyH("LEFT")
    subcaption:SetText("|cfff2c75bCtrl+C|r copies it. Ids come from QuestieDB, so a quest "
        .. "this realm added or changed may not match Wowhead.")

    local done = W.Button(modal, "Done", "primary")
    done:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -22, 16)
    done:SetHeight(26)
    done:Fit(90)
    done:SetScript("OnClick", function() Link.Hide() end)

    modal:SetScript("OnHide", function() editBox:ClearFocus() end)
    QEF.Controller.AttachDialog(modal)
    return modal
end

--- Show a URL ready to copy.
---@param url string
---@param text string? what the link is, shown above the box
---@param subtitle string? the small right-hand line in the title bar
---@return boolean shown
function Link.ShowUrl(url, text, subtitle)
    url = QEF.Str(url)
    if not url then return false end

    Build()
    caption:SetText(text or "Link")
    modal.subtitle:SetText(subtitle or "")
    editBox.url = url
    editBox:SetText(url)
    modal:Show()
    -- Focused and selected, so copying is one keystroke rather than a drag.
    editBox:SetFocus()
    editBox:HighlightText()
    return true
end

--- Show the Wowhead link for a quest.
---@param questId number
---@return boolean shown
function Link.ShowQuest(questId)
    questId = QEF.QuestId(questId)
    local url = questId and Link.QuestUrl(questId)
    if not url then return false end

    local name = QEF.Source.QuestName(questId)
    return Link.ShowUrl(url, QEF.Clip(name, 48) or ("Quest " .. questId), "#" .. questId)
end

function Link.Hide()
    if modal then modal:Hide() end
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Link", function()
    W = QEF.Widgets
    theme = W.theme
    Art = QEF.Art
end)
