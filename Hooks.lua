-- Hooks.lua
--
-- The quest giver side: previews while a quest is being offered, and while hovering the
-- entries in a gossip or greeting list.
--
-- Three different frame layouts have to be handled on this client, which is why this is
-- longer than it looks like it should be:
--
--   * QUEST_DETAIL - one quest on screen, GetQuestID() names it.
--   * QUEST_GREETING - the old multi-quest list. Forever's buttons come from a pool and are
--     unnamed, so they are enumerated rather than looked up by name, and the ids come from
--     GetActiveQuestID / GetAvailableQuestInfo (which puts the id in position 5 on Forever).
--   * GOSSIP_SHOW - the ScrollBox gossip frame. Blizzard's buttons feed the gamepad UI, so
--     their Setup is left alone and the list is walked on the next frame instead.
--
-- Anything that comes back from those APIs may be a secret value, so every id goes through
-- QEF.QuestId before it is used.

local ADDON, QEF = ...

local Hooks = {}
QEF.Hooks = Hooks

local Tooltip, Panel, Rewards

-- The quest the log panel is showing, declared up here so that hiding everything for
-- combat forgets it too - otherwise the poll would see no change and never put it back.
local logQuestId, logPoller, inCombat

--------------------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------------------

local function Mode()
    return QEF.Get("mode") or "tooltip"
end

local function ShowFor(questId, anchorTo, atGiver)
    if not QEF.Get("enabled") then return end
    questId = QEF.QuestId(questId)
    if not questId then return end

    local opts = { anchorTo = anchorTo, atGiver = atGiver }
    local mode = Mode()
    if mode == "panel" or mode == "both" then
        Panel.Show(questId, opts)
    end
    if mode == "tooltip" or mode == "both" then
        Tooltip.Show(anchorTo, questId, opts)
    end
end

local function HideAll()
    logQuestId = nil
    Tooltip.Hide()
    Panel.Hide()
end

--------------------------------------------------------------------------------------------
-- Hover wiring
--------------------------------------------------------------------------------------------

--- Attach hover handlers to a list button once. The quest id is re-read from the button at
--- hover time, because pooled buttons are reused for different quests.
---@param button table
---@param anchorTo table
local function WireHover(button, anchorTo)
    if not button or button.qpWired then return end
    button.qpWired = true

    button:HookScript("OnEnter", function(self)
        local questId = QEF.QuestId(self.qpQuestId)
        if not questId then return end
        if Mode() == "panel" then
            Panel.Show(questId, { anchorTo = self.qpAnchorTo or anchorTo })
        else
            Tooltip.Show(self, questId, { anchorTo = self.qpAnchorTo or anchorTo })
        end
    end)

    button:HookScript("OnLeave", function()
        if Mode() == "panel" then return end
        Tooltip.Hide()
    end)
end

--------------------------------------------------------------------------------------------
-- Quest greeting list
--------------------------------------------------------------------------------------------

--- Walk the greeting buttons however this client builds them.
---@param callback fun(button: table, index: number, isActive: boolean)
local function ForEachGreetingButton(callback)
    local panel = _G.QuestFrameGreetingPanel
    local pool = panel and panel.titleButtonPool

    if pool and pool.EnumerateActive then
        for button in pool:EnumerateActive() do
            if button:IsShown() then
                local index = QEF.Num(button:GetID())
                if index then callback(button, index, button.isActive == 1) end
            end
        end
        return
    end

    for i = 1, 32 do
        local button = _G["QuestTitleButton" .. i]
        if not button then break end
        if button:IsShown() then
            local index = QEF.Num(button:GetID())
            if index then callback(button, index, button.isActive == 1) end
        end
    end
end

--- The quest id behind one greeting entry. Forever returns a real id from both of these;
--- older builds only have titles, in which case Questie's name lookup is the fallback.
---@param index number
---@param isActive boolean
---@return number?
local function GreetingQuestId(index, isActive)
    local questId
    if isActive then
        questId = QEF.QuestId(QEF.Try(_G.GetActiveQuestID, index))
    else
        questId = QEF.QuestId(select(5, QEF.Try(_G.GetAvailableQuestInfo, index)))
    end
    if questId then return questId end

    local title = isActive and QEF.Str(QEF.Try(_G.GetActiveTitle, index))
        or QEF.Str(QEF.Try(_G.GetAvailableTitle, index))
    if not title then return nil end

    local npcGuid = UnitGUID("npc")
    if not QEF.Readable(npcGuid) then npcGuid = nil end
    return QEF.Source.QuestIdFromName(title, npcGuid, not isActive)
end

local function RefreshGreeting()
    local anchorTo = _G.QuestFrame
    local count = 0
    ForEachGreetingButton(function(button, index, isActive)
        -- A stale event can arrive before Blizzard has released the previous greeting's
        -- buttons, which would read an index past the end of the list.
        local limit = isActive and (QEF.Num(QEF.Try(_G.GetNumActiveQuests)) or 0)
            or (QEF.Num(QEF.Try(_G.GetNumAvailableQuests)) or 0)
        if index < 1 or index > limit then
            button.qpQuestId = nil
            return
        end
        button.qpQuestId = GreetingQuestId(index, isActive)
        button.qpAnchorTo = anchorTo
        WireHover(button, anchorTo)
        if button.qpQuestId then count = count + 1 end
    end)
    QEF.Debug("greeting: wired", count, "entries")
end

--------------------------------------------------------------------------------------------
-- Gossip list
--------------------------------------------------------------------------------------------

local function RefreshModernGossip()
    local gossipFrame = _G.GossipFrame
    local panel = gossipFrame and gossipFrame:IsShown() and gossipFrame.GreetingPanel
    local scrollBox = panel and panel.ScrollBox
    if not scrollBox or not scrollBox.ForEachFrame then return false end

    local count = 0
    scrollBox:ForEachFrame(function(button)
        local elementData = button.GetElementData and QEF.Try(button.GetElementData, button)
        elementData = QEF.Tbl(elementData)
        local info = elementData and QEF.Tbl(elementData.info)
        local questId = info and QEF.QuestId(info.questID)

        if not questId and info then
            local npcGuid = UnitGUID("npc")
            if not QEF.Readable(npcGuid) then npcGuid = nil end
            questId = QEF.Source.QuestIdFromName(QEF.Str(info.title), npcGuid,
                elementData.availableQuestButton == true)
        end

        button.qpQuestId = questId
        button.qpAnchorTo = gossipFrame
        WireHover(button, gossipFrame)
        if questId then count = count + 1 end
    end)
    QEF.Debug("gossip: wired", count, "entries")
    return true
end

--- The pre-ScrollBox gossip frame. Sections are offset by one button between the available
--- and active lists, which is why the index is tracked rather than derived.
local function RefreshLegacyGossip()
    local gossipFrame = _G.GossipFrame
    if not gossipFrame or not gossipFrame:IsShown() then return end

    local available = QEF.Tbl(QEF.Try(C_GossipInfo and C_GossipInfo.GetAvailableQuests)) or {}
    local active = QEF.Tbl(QEF.Try(C_GossipInfo and C_GossipInfo.GetActiveQuests)) or {}
    local index = 0

    local function wire(list, isAvailable)
        for i = 1, #list do
            index = index + 1
            local button = _G["GossipTitleButton" .. index]
            if button then
                local entry = QEF.Tbl(list[i])
                local questId = entry and QEF.QuestId(entry.questID)
                if not questId and entry then
                    local npcGuid = UnitGUID("npc")
                    if not QEF.Readable(npcGuid) then npcGuid = nil end
                    questId = QEF.Source.QuestIdFromName(QEF.Str(entry.title), npcGuid, isAvailable)
                end
                button.qpQuestId = questId
                button.qpAnchorTo = gossipFrame
                WireHover(button, gossipFrame)
            end
        end
    end

    wire(available, true)
    if #available > 0 and #active > 0 then index = index + 1 end
    wire(active, false)
end

local function RefreshGossip()
    if not RefreshModernGossip() then
        RefreshLegacyGossip()
    end
end

--------------------------------------------------------------------------------------------
-- Quest log
--------------------------------------------------------------------------------------------
--
-- The log tells you what a quest asks for. It does not tell you that it is the third of
-- five, that the next one is in a dungeon, or who you hand it back to - which is what the
-- preview is for, so it is worth having beside an open log as well as at a quest giver.
--
-- Which frame that is depends on the build: a Classic-style QuestLogFrame, or the map-based
-- QuestMapFrame. Rather than betting on one, every selection function that exists is hooked
-- and a quarter-second poll backs them up while a log frame is open, so a layout this does
-- not anticipate still works.

local LOG_FRAMES = { "QuestLogFrame", "QuestLogExFrame", "QuestMapFrame", "WorldMapFrame" }

Hooks.logHooks = {}

--- The window the log lives in, rather than the log itself. QuestMapFrame is a panel inside
--- the world map, and attaching to it puts the preview over the map it is part of; what the
--- preview wants is the outside edge of the whole window.
---@param frame table
---@return table outermost
local function OutermostAncestor(frame)
    local top = frame
    for _ = 1, 8 do
        local parent = top.GetParent and top:GetParent()
        if not parent or parent == UIParent or not parent.IsVisible then break end
        top = parent
    end
    return top
end

---@return table? frame the window an open log is in
local function LogFrame()
    for _, name in ipairs(LOG_FRAMES) do
        local frame = _G[name]
        -- IsVisible, not IsShown: a panel keeps its own shown flag while the window that
        -- contains it is closed, which had the preview opening over the world the moment
        -- the map was shut.
        if frame and frame.IsVisible and frame:IsVisible() then
            return OutermostAncestor(frame)
        end
    end
    return nil
end

--- The quest the log is showing, by whichever route this client offers.
---@return number? questId
local function SelectedLogQuestId()
    local questId = QEF.QuestId(QEF.Try(C_QuestLog and C_QuestLog.GetSelectedQuest))
    if questId then return questId end

    local index = QEF.Num(QEF.Try(_G.GetQuestLogSelection))
    if not index or index < 1 then return nil end

    local info = QEF.Tbl(QEF.Try(C_QuestLog and C_QuestLog.GetInfo, index))
    if info then
        if info.isHeader then return nil end
        return QEF.QuestId(info.questID)
    end

    -- The old API: a header has no quest behind it, and the id is the eighth return on the
    -- builds that give one at all.
    local _, _, _, isHeader = QEF.Try(_G.GetQuestLogTitle, index)
    if isHeader then return nil end
    return QEF.QuestId(select(8, QEF.Try(_G.GetQuestLogTitle, index)))
end

local function HideLogPanel()
    if not logQuestId then return end
    logQuestId = nil
    Panel.Hide()
end

--- The log itself has gone, so the panel and its tab go with it. Whether it was minimised
--- is a preference and survives: fold it away once and it stays folded next time.
local function ForgetLog()
    HideLogPanel()
end

local function RefreshLog()
    if not QEF.Get("enabled") or not QEF.Get("questLog") then
        HideLogPanel()
        return
    end
    -- Everything else gets out of the way when a fight starts; the log preview should not
    -- be the one thing that argues about it.
    if inCombat then
        HideLogPanel()
        return
    end

    local frame = LogFrame()
    if not frame then
        ForgetLog()
        return
    end

    local questId = SelectedLogQuestId()
    if not questId then
        HideLogPanel()
        return
    end

    -- Asked by quest, not by whether the panel is open: while it is minimised the tab is
    -- standing in for the same quest, and rebuilding it every quarter second would undo
    -- the minimising on every tick.
    if questId == logQuestId and Panel.CurrentQuestId() == questId then return end

    logQuestId = questId
    -- Always the panel, whatever the display mode says: there is nothing to hover in a
    -- quest log. The objectives are skipped because the log is already showing them.
    Panel.Show(questId, { anchorTo = frame, inLog = true, skipObjectives = true })
end

Hooks.RefreshLog = RefreshLog

--- Which selection hooks this client turned out to have, and what the panel is attached to
--- right now - which is the thing to look at when it attaches somewhere unexpected, since a
--- map addon can change both the frame and its scale.
---@return string
function Hooks.LogReport()
    local hooks = #Hooks.logHooks == 0 and "no selection hook - the poll is doing it alone"
        or table.concat(Hooks.logHooks, ", ")
    local frame = LogFrame()
    local name = frame and frame.GetName and frame:GetName()
    return hooks .. "; attached to: " .. (name or "nothing open")
end

local function WireQuestLog()
    local function queue() C_Timer.After(0, RefreshLog) end

    -- Minimising is the panel's own business now: it keeps the quest, swaps itself for the
    -- tab, and this side carries on telling it which quest is selected either way.

    for _, name in ipairs({ "QuestLog_SetSelection", "QuestMapFrame_ShowQuestDetails" }) do
        if type(_G[name]) == "function" then
            if pcall(hooksecurefunc, name, queue) then
                Hooks.logHooks[#Hooks.logHooks + 1] = name
            end
        end
    end
    if C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" then
        if pcall(hooksecurefunc, C_QuestLog, "SetSelectedQuest", queue) then
            Hooks.logHooks[#Hooks.logHooks + 1] = "C_QuestLog.SetSelectedQuest"
        end
    end

    for _, name in ipairs(LOG_FRAMES) do
        local frame = _G[name]
        if frame and frame.HookScript then
            frame:HookScript("OnShow", queue)
            frame:HookScript("OnHide", ForgetLog)
        end
    end

    -- The backstop. Selection can change with none of the above firing on a layout this
    -- does not know about, and it costs four table lookups a quarter second while a log
    -- is open, nothing at all when one is not.
    logPoller = CreateFrame("Frame")
    logPoller.elapsed = 0
    logPoller:SetScript("OnUpdate", function(self, delta)
        self.elapsed = self.elapsed + delta
        if self.elapsed < 0.25 then return end
        self.elapsed = 0
        if not LogFrame() and not logQuestId then return end
        local ok, err = pcall(RefreshLog)
        if not ok then QEF.Debug("quest log poll error:", err) end
    end)
end

--------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------

local function OnQuestDetail()
    local questId = QEF.QuestId(QEF.Try(_G.GetQuestID))
    if not questId then
        -- Without an id there is nothing to look a chain up by. The frame already shows the
        -- rewards, so staying silent is the right failure here.
        QEF.Debug("QUEST_DETAIL with no readable quest id")
        return
    end
    -- Reading the frame now both drives this preview and teaches the saved-variable cache
    -- the exact choice/fixed split for later previews of the same quest.
    Rewards.Get(questId, true)
    ShowFor(questId, _G.QuestFrame, true)
end

local function OnQuestProgressOrComplete()
    local questId = QEF.QuestId(QEF.Try(_G.GetQuestID))
    if not questId then return end
    Rewards.Get(questId, true)
end

function Hooks.Init()
    Tooltip = QEF.Tooltip
    Panel = QEF.Panel
    Rewards = QEF.Rewards

    QEF.On("QUEST_DETAIL", OnQuestDetail)
    QEF.On("QUEST_PROGRESS", OnQuestProgressOrComplete)
    QEF.On("QUEST_COMPLETE", OnQuestProgressOrComplete)

    QEF.On("QUEST_GREETING", function()
        C_Timer.After(0, RefreshGreeting)
    end)

    QEF.On("GOSSIP_SHOW", function()
        -- Blizzard fills the gossip list after this event on Forever.
        C_Timer.After(0, RefreshGossip)
    end)

    QEF.On("QUEST_LOG_UPDATE", function()
        if _G.GossipFrame and _G.GossipFrame:IsShown() then
            C_Timer.After(0, RefreshGossip)
        end
        if _G.QuestFrameGreetingPanel and _G.QuestFrameGreetingPanel:IsShown() then
            C_Timer.After(0, RefreshGreeting)
        end
    end)

    QEF.On("QUEST_FINISHED", HideAll)
    QEF.On("GOSSIP_CLOSED", HideAll)
    QEF.On("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        HideAll()
    end)
    QEF.On("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        -- The log is often still open when a fight ends, so put its preview back.
        C_Timer.After(0, RefreshLog)
    end)

    WireQuestLog()
    -- Abandoning or accepting a quest reorders the log, so the selection can land on a
    -- different quest without anything else telling us.
    QEF.On("QUEST_LOG_UPDATE", function()
        if logQuestId then C_Timer.After(0, RefreshLog) end
    end)

    -- The greeting panel can be rebuilt without an event we see.
    if _G.QuestFrameGreetingPanel then
        _G.QuestFrameGreetingPanel:HookScript("OnShow", function()
            C_Timer.After(0, RefreshGreeting)
        end)
        _G.QuestFrameGreetingPanel:HookScript("OnHide", HideAll)
    end
    if _G.QuestFrame then
        _G.QuestFrame:HookScript("OnHide", HideAll)
    end
    if _G.GossipFrame then
        _G.GossipFrame:HookScript("OnHide", HideAll)
    end
end

--- Exposed for /qef debug, which re-runs the wiring and reports what it found.
Hooks.RefreshGossip = RefreshGossip
Hooks.RefreshGreeting = RefreshGreeting

QEF.RegisterInit("Hooks", Hooks.Init)
