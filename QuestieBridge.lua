-- QuestieBridge.lua
--
-- Adds the preview to Questie's map and minimap icon tooltips.
--
-- Questie builds those in MapIconTooltip.ShowOnTooltip, which collects entries, assigns a
-- fresh Tooltip._Rebuild closure, calls it, and shows the tooltip. MODIFIER_STATE_CHANGED
-- re-runs _Rebuild on its own, which would wipe anything appended once, so this hooks both:
-- the function, for the first draw, and the closure it just installed, for later redraws.
--
-- Everything here is optional. With Questie absent the module simply never installs.

local ADDON, QEF = ...

local Bridge = {}
QEF.QuestieBridge = Bridge

Bridge.installed = false
Bridge.status = "not attempted"

local Render, Tooltip

local lastWrappedRebuild

--------------------------------------------------------------------------------------------
-- Appending
--------------------------------------------------------------------------------------------

--- The quest id behind a hovered Questie icon.
---@param icon table
---@return number?
local function QuestIdOf(icon)
    local data = icon and QEF.Tbl(icon.data)
    if not data then return nil end
    return QEF.QuestId(data.Id)
end

--- Add the preview to a Questie tooltip, unless the same preview is already on it.
---@param tooltip table
---@param questId number
local function AppendTo(tooltip, questId)
    if not tooltip or not questId then return end
    if not QEF.Get("enabled") or not QEF.Get("questie") then return end

    -- Questie debounces re-shows: when it returns early the tooltip still carries our lines
    -- from last time, and appending again would duplicate them.
    local lineCount = tooltip.NumLines and tooltip:NumLines() or 0
    if tooltip.qpQuestId == questId and tooltip.qpLinesAfter == lineCount then return end

    local rows = Render.Build(questId, { skipHeader = true })
    if #rows == 0 then return end

    tooltip:AddLine(" ")
    Tooltip.AppendRows(tooltip, rows)

    tooltip.qpQuestId = questId
    tooltip.qpLinesAfter = tooltip.NumLines and tooltip:NumLines() or 0
end

--- Keep the preview across Questie's own redraws (shift/ctrl change its contents).
local function WrapRebuild(tooltip, questId)
    local rebuild = tooltip._Rebuild
    if type(rebuild) ~= "function" then return end
    -- ShowOnTooltip installs a fresh closure on every real call. When it early-returned, the
    -- function still sitting there is our own wrapper from last time.
    if rebuild == lastWrappedRebuild then return end

    local wrapped = function(...)
        rebuild(...)
        tooltip.qpQuestId = nil
        tooltip.qpLinesAfter = nil
        AppendTo(tooltip, questId)
    end
    tooltip._Rebuild = wrapped
    lastWrappedRebuild = wrapped
end

--------------------------------------------------------------------------------------------
-- Installation
--------------------------------------------------------------------------------------------

local function Install()
    local loader = _G.QuestieLoader
    if not loader or type(loader.ImportModule) ~= "function" then
        Bridge.status = "Questie not loaded"
        return false
    end

    local MapIconTooltip = QEF.Try(loader.ImportModule, loader, "MapIconTooltip")
    if type(MapIconTooltip) ~= "table" or type(MapIconTooltip.ShowOnTooltip) ~= "function" then
        -- ImportModule hands back an empty table before Questie's own file has run.
        Bridge.status = "waiting for Questie's tooltip module"
        return false
    end

    local original = MapIconTooltip.ShowOnTooltip
    MapIconTooltip.ShowOnTooltip = function(icon, tooltip, owner, icons, ...)
        original(icon, tooltip, owner, icons, ...)

        local ok, err = pcall(function()
            if not tooltip then return end
            local questId = QuestIdOf(icon)
            if not questId then return end
            WrapRebuild(tooltip, questId)
            AppendTo(tooltip, questId)
            tooltip:Show()
        end)
        if not ok then QEF.Debug("Questie tooltip append failed:", err) end
    end

    Bridge.installed = true
    Bridge.status = "hooked MapIconTooltip.ShowOnTooltip"
    QEF.Debug("Questie integration installed")
    return true
end

--- Questie finishes loading after us, so installation is retried for a few seconds and then
--- quietly given up on.
local function TryInstall(attemptsLeft)
    if Bridge.installed then return end
    if Install() then return end
    if attemptsLeft <= 0 then
        if _G.QuestieLoader then
            Bridge.status = "gave up waiting for Questie's tooltip module"
            QEF.Debug(Bridge.status)
        end
        return
    end
    C_Timer.After(1, function() TryInstall(attemptsLeft - 1) end)
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("QuestieBridge", function()
    Render = QEF.Render
    Tooltip = QEF.Tooltip
    if not _G.QuestieLoader then
        Bridge.status = "Questie not installed"
        QEF.Debug("Questie absent - map icon integration skipped")
        return
    end
    TryInstall(15)
end)
