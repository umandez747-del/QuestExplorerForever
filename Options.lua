-- Options.lua
--
-- Slash commands. Settings have a window now, so this is the keyboard route to the same
-- places plus the diagnostic reports, which belong in chat where you can read and copy them.

local ADDON, QEF = ...

local function Say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cfff2c75bQuest Explorer|r: " .. text)
end

local function OnOff(value)
    return value and "|cff40c040on|r" or "|cffff4040off|r"
end

--- Toggles that take an optional on/off and otherwise flip. These names and the report names
--- below share one namespace, so none of them may collide: the rewards report is `reward`,
--- and the quest giver dump is `giver`.
local TOGGLES = {
    objectives = { key = "showObjectives", label = "quest objectives" },
    rewards    = { key = "showRewards",    label = "rewards" },
    chain      = { key = "showChain",      label = "chain preview" },
    dungeon    = { key = "showDungeonGate", label = "dungeon gating" },
    rep        = { key = "showReputation", label = "reputation rewards" },
    ids        = { key = "showQuestIds",   label = "quest ids" },
    questie    = { key = "questie",        label = "Questie map icon integration" },
    questlog   = { key = "questLog",       label = "the preview beside the quest log" },
    attach     = { key = "panelAttach",    label = "attaching the panel to the frame" },
    minimise   = { key = "panelMinimised", label = "the panel folded into its tab" },
    frameart   = { key = "frameArt",      label = "the painted corners on windows" },
    lookahead  = { key = "liveLookahead",  label = "server lookahead for other quests" },
    learn      = { key = "learn",          label = "remembering exact rewards" },
    travel     = { key = "showTravel",     label = "travel directions" },
    routewindow = { key = "routeWindow",   label = "the travel directions window" },
    chainorder = { key = "chainOrder",     label = "grouping the quest list into chains" },
    trackersteps = { key = "trackerSteps", label = "quest givers under each checklist line" },
    walkorder  = { key = "walkOrder",      label = "walking order for the zone you are in" },
    toast      = { key = "sweepToast",     label = "the floating sweep progress strip" },
}

local function SetToggle(name, argument)
    local toggle = TOGGLES[name]
    local value
    if argument == "on" then value = true
    elseif argument == "off" then value = false
    else value = not QEF.Get(toggle.key) end
    QEF.Set(toggle.key, value)
    Say(toggle.label .. ": " .. OnOff(value))
    if toggle.key == "chainOrder" and QEF.Browse and QEF.Browse.Requery then
        QEF.Browse.Requery()
    elseif (toggle.key == "trackerSteps" or toggle.key == "walkOrder") and QEF.Tracker then
        QEF.Tracker.Update()
        if toggle.key == "walkOrder" and QEF.Guide then QEF.Guide.Refresh(true) end
    elseif toggle.key == "questLog" and QEF.Hooks and QEF.Hooks.RefreshLog then
        QEF.Hooks.RefreshLog()
    elseif toggle.key == "panelAttach" then
        QEF.Panel.Redraw()
    elseif toggle.key == "panelMinimised" then
        QEF.Panel.Present()
    elseif toggle.key == "frameArt" then
        QEF.Widgets.RefreshFrameArt()
    end
end

local function Help()
    Say("|cffffd100/qef|r opens the window. Other commands:")
    local lines = {
        "|cffffd100/qef browse|r [text] - open the browser, optionally searching for something",
        "|cffffd100/qef sweep|r start | pause | reset | status",
        "|cffffd100/qef settings|r - the settings page",
        "|cffffd100/qef plan|r [dungeon] - pick a dungeon and tick the quests you want",
        "|cffffd100/qef checklist|r [clear] - what is on the list, in chat",
        "|cffffd100/qef tracker|r on | off | reset - the checklist strip on screen",
        "|cffffd100/qef guide|r on | off | next | reset - mark the step you are on",
        "|cffffd100/qef pins|r auto | on | off | available - this addon's own map pins",
        "|cffffd100/qef minimap|r [reset] - the minimap button",
        "|cffffd100/qef way|r [id] - waypoint to a quest giver",
        "|cffffd100/qef route|r [id] - directions to a quest giver, and what they were based on",
        "|cffffd100/qef wowhead|r [id] - the Wowhead link, in a box to copy",
        "|cffffd100/qef controller|r auto | on | off - the gamepad layout",
        "|cffffd100/qef welcome|r - show the intro again",
        " ",
        "|cffffd100/qef on|r | |cffffd100off|r, |cffffd100mode|r tooltip|panel|both, |cffffd100verbosity|r 1|2|3",
        "|cffffd100/qef|r objectives | rewards | chain | dungeon | rep | ids | questie | lookahead | learn | toast",
        "|cffffd100/qef questlog|r - the preview beside an open quest log",
        "|cffffd100/qef attach|r - panel flush against the frame, or floating beside it",
        "|cffffd100/qef minimise|r - fold the panel into its tab, or open it back up",
        "|cffffd100/qef|r travel | routewindow - directions, and whether they pop out or go to chat",
        "|cffffd100/qef trackersteps|r - name the quest giver under each checklist line",
        "|cffffd100/qef chainorder|r - group the quest list into chains, or list it flat by level",
        "|cffffd100/qef reset|r - put a dragged panel back beside the quest frame",
        " ",
        "|cffffd100/qef status|r - what loaded and from where",
        "|cffffd100/qef api|r - which quest APIs this client actually has",
        "|cffffd100/qef index|r - reverse index statistics and reward coverage",
        "|cffffd100/qef quest|r <id> - raw database fields and everything derived from them",
        "|cffffd100/qef reward|r <id> - resolve rewards for any quest and name the source",
        "|cffffd100/qef giver|r - dump what the open quest giver frame returns",
        "|cffffd100/qef debug|r on | off - verbose logging",
    }
    for _, line in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
    end
end

local function SweepCommand(argument)
    local state = QEF.Sweep.state
    if argument == "start" or argument == "resume" then
        local started, reason = QEF.Sweep.Start(false)
        Say(started and "sweep started - progress is saved as it goes"
            or ("cannot start: " .. (reason or "unknown")))
    elseif argument == "restart" then
        local started, reason = QEF.Sweep.Start(true)
        Say(started and "sweep restarted from the beginning"
            or ("cannot start: " .. (reason or "unknown")))
    elseif argument == "pause" or argument == "stop" then
        Say(QEF.Sweep.Pause() and "sweep paused" or "no sweep is running")
    elseif argument == "reset" then
        local cleared = QEF.Sweep.Reset()
        Say(("cleared %s stored reward sets"):format(QEF.Comma(cleared) or cleared))
    else
        local known, withRewards = QEF.Sweep.Coverage()
        Say(("sweep is %s - %d%% through %s quests"):format(
            state.running and "|cff40c040running|r" or "idle",
            math.floor(QEF.Sweep.Percent()), QEF.Comma(state.total) or state.total))
        DEFAULT_CHAT_FRAME:AddMessage(("  stored: %s quests, %s of them with rewards"):format(
            QEF.Comma(known) or known, QEF.Comma(withRewards) or withRewards))
        if state.missing > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(("  %s the server would not answer for"):format(
                QEF.Comma(state.missing) or state.missing))
        end
    end
end

local function Handle(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local command, rest = input:match("^(%S*)%s*(.*)$")
    command = (command or ""):lower()

    if command == "" then
        QEF.Window.Toggle()

    elseif command == "help" then
        Help()

    elseif command == "browse" then
        QEF.Window.Show("browse")
        if rest ~= "" then QEF.Browse.SetSearch(rest) end

    elseif command == "settings" or command == "options" or command == "config" then
        QEF.Window.Show("settings")

    elseif command == "sweep" then
        if rest == "" or rest == "status" then
            SweepCommand("status")
        else
            SweepCommand(rest:lower())
        end

    elseif command == "on" or command == "off" then
        QEF.Set("enabled", command == "on")
        Say("enabled: " .. OnOff(QEF.Get("enabled")))
        if command == "off" then
            QEF.Tooltip.Hide()
            QEF.Panel.Hide()
        end

    elseif command == "mode" then
        local mode = rest:lower()
        if mode ~= "tooltip" and mode ~= "panel" and mode ~= "both" then
            Say("mode is currently |cffffd100" .. tostring(QEF.Get("mode"))
                .. "|r - use tooltip, panel or both")
        else
            QEF.Set("mode", mode)
            Say("mode: |cffffd100" .. mode .. "|r")
        end

    elseif command == "verbosity" then
        local level = tonumber(rest)
        if level ~= 1 and level ~= 2 and level ~= 3 then
            Say("verbosity is currently |cffffd100" .. tostring(QEF.Get("verbosity"))
                .. "|r - use 1 (brief), 2 (normal) or 3 (everything)")
        else
            QEF.Set("verbosity", level)
            Say("verbosity: |cffffd100" .. level .. "|r")
        end

    elseif TOGGLES[command] then
        SetToggle(command, rest:lower())

    elseif command == "reset" then
        QEF.Panel.ResetPosition()
        Say("panel position reset")

    elseif command == "forget" then
        local cleared = QEF.Sweep.Reset()
        Say(("forgot %s remembered reward sets"):format(QEF.Comma(cleared) or cleared))

    elseif command == "debug" then
        local value = rest:lower()
        if value == "on" then QEF.Set("debug", true)
        elseif value == "off" then QEF.Set("debug", false)
        else QEF.Set("debug", not QEF.Get("debug")) end
        Say("debug logging: " .. OnOff(QEF.Get("debug")))

    elseif command == "status" then
        QEF.Diagnostics.Status()

    elseif command == "api" then
        QEF.Diagnostics.Api()

    elseif command == "index" then
        QEF.Diagnostics.Index()

    elseif command == "quest" then
        QEF.Diagnostics.Quest(tonumber(rest))

    elseif command == "reward" then
        QEF.Diagnostics.Rewards(tonumber(rest))

    elseif command == "giver" then
        QEF.Diagnostics.Live()

    elseif command == "welcome" or command == "intro" then
        QEF.Welcome.Show()

    elseif command == "route" then
        local questId = tonumber(rest) or QEF.Browse.shownQuestId
        if not questId then
            Say("usage: |cffffd100/qef route <questId>|r, or open a quest in the browser first")
        else
            local route = QEF.Travel.ToQuestStart(questId)
            if not route then
                Say("no quest giver recorded for that quest")
            else
                Say(("route to %s"):format(
                    route.start and route.start.name or ("quest " .. questId)))
                DEFAULT_CHAT_FRAME:AddMessage(("  |cff808080from %s (%s) to %s|r"):format(
                    tostring(route.fromZone), tostring(route.fromContinent),
                    tostring(route.toContinent)))
                -- The same window the Waypoint button opens, so this command shows what a
                -- player would actually see; the chat lines above still name the inputs.
                if not (QEF.Get("routeWindow") and QEF.Route and QEF.Route.Show(questId)) then
                    QEF.Travel.Announce(questId)
                end
            end
        end

    elseif command == "controller" or command == "pad" then
        local wanted = rest and rest:lower()
        if wanted == "auto" or wanted == "on" or wanted == "off" then
            QEF.Set("controller", wanted)
            QEF.Controller.Resolve()
            QEF.Controller.Apply()
        elseif wanted ~= "" and wanted ~= nil then
            Say("usage: |cffffd100/qef controller auto|on|off|r")
            return
        end
        local detected, reason = QEF.Controller.Detected()
        Say(("controller layout: setting |cffffd100%s|r, %s right now"):format(
            tostring(QEF.Get("controller")),
            QEF.Controller.active and "|cff40c040on|r" or "|cffff4040off|r"))
        DEFAULT_CHAT_FRAME:AddMessage(("  |cff808080detection: %s - %s|r"):format(
            detected and "pad found" or "no pad", reason or "no reason given"))

    elseif command == "plan" or command == "dungeon" then
        QEF.Window.Show("plan")
        if rest ~= "" and not QEF.Plan.Open(rest) then
            Say(("no dungeon matches '%s'"):format(rest))
        end

    elseif command == "tracker" then
        local value = rest:lower()
        if value == "reset" then
            QEF.Tracker.ResetPosition()
            Say("checklist strip moved back to the right hand edge")
        elseif value == "on" then
            QEF.Tracker.Show()
            Say("dungeon checklist: " .. OnOff(true))
        elseif value == "off" then
            QEF.Tracker.Hide()
            Say("dungeon checklist: " .. OnOff(false))
        else
            Say("dungeon checklist: " .. OnOff(QEF.Tracker.Toggle()))
        end

    elseif command == "minimap" then
        if rest:lower() == "reset" then
            QEF.MinimapButton.ResetPosition()
            Say("minimap button moved back to its corner")
        else
            Say("minimap button: " .. OnOff(QEF.MinimapButton.Toggle()))
        end

    elseif command == "pins" or command == "map" then
        local wanted = rest and rest:lower()
        if wanted == "auto" or wanted == "on" or wanted == "off" then
            QEF.Set("mapPins", wanted)
            QEF.MapPins.Refresh()
        elseif wanted:match("^style") then
            local chosen = wanted:match("^style%s+(%a+)")
            local valid = {}
            for _, name in ipairs(QEF.Art.pinStyles) do valid[name] = true end
            if chosen and valid[chosen] then
                QEF.Set("pinStyle", chosen)
                QEF.MapPins.Refresh()
                Say("pin style: |cffffd100" .. chosen .. "|r")
            else
                Say("pin styles: |cffffd100" .. table.concat(QEF.Art.pinStyles, ", ") .. "|r"
                    .. " (now: " .. tostring(QEF.Get("pinStyle")) .. ")")
            end
            return
        elseif wanted == "blizzard" or wanted == "blizz" then
            QEF.Set("hideBlizzardPins", not QEF.Get("hideBlizzardPins"))
            Say("the game's own quest pins: "
                .. (QEF.Get("hideBlizzardPins") and "hidden while ours are up" or "left alone"))
            QEF.MapPins.Refresh()
            return
        elseif wanted == "mouse" or wanted == "hover" then
            for _, line in ipairs(QEF.MapPins.MouseReport()) do Say(line) end
            return
        elseif wanted == "test" then
            local placed, why = QEF.MapPins.TestPin()
            Say((placed and "test pin: " or "|cffff4040no test pin|r: ") .. why)
            return
        elseif wanted == "available" or wanted == "zone" then
            QEF.Set("mapAvailable", not QEF.Get("mapAvailable"))
            Say("quests going spare in the zone: " .. OnOff(QEF.Get("mapAvailable")))
            QEF.MapPins.Refresh()
        elseif wanted ~= "" and wanted ~= nil then
            Say("usage: |cffffd100/qef pins auto|on|off|available|blizzard|style <name>|mouse|r")
            return
        end
        -- The full picture rather than the summary: this is the command people run
        -- when the map is empty, and the summary is what fails to explain it.
        QEF.Diagnostics.Pins()

    elseif command == "guide" or command == "marker" then
        local value = rest:lower()
        if value == "next" or value == "skip" then
            if QEF.Guide.Next() then
                Say("marker moved on")
            else
                Say("nothing else on the list has a place to mark")
            end
        elseif value == "reset" then
            QEF.Guide.Reset()
            Say("marker reset - every step is in play again")
        elseif value == "on" then
            QEF.Guide.Start()
            Say("step marker: " .. OnOff(true))
        elseif value == "off" then
            QEF.Guide.Stop()
            Say("step marker: " .. OnOff(false))
        else
            Say("step marker: " .. OnOff(QEF.Guide.Toggle()))
        end
        local current = QEF.Guide.current
        if current then
            DEFAULT_CHAT_FRAME:AddMessage(("  |cff808080on: %s%s|r"):format(
                current.text, current.npc and (" - " .. current.npc) or ""))
        end

    elseif command == "checklist" then
        local action = rest:lower()
        if action == "clear" then
            local removed = QEF.Checklist.Clear()
            Say(("checklist cleared (%d quest%s)"):format(
                removed, removed == 1 and "" or "s"))
        else
            local plan = QEF.Checklist.Plan()
            if plan.total == 0 then
                Say("the checklist is empty - |cffffd100/qef plan|r picks a dungeon to fill it")
            else
                Say(("%s - %d of %d done"):format(
                    plan.dungeon or "checklist", plan.done, plan.total))
                for _, group in ipairs(plan.groups) do
                    DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%s|r%s"):format(
                        group.zone or "no recorded place",
                        group.otherContinent and " |cff808080(another continent)|r" or ""))
                    for _, entry in ipairs(group.entries) do
                        local step = entry.step
                        DEFAULT_CHAT_FRAME:AddMessage(("    %s %s%s"):format(
                            step.verb or "Go to", entry.name,
                            step.npc and (" |cff808080- " .. step.npc .. "|r") or ""))
                    end
                end
                if #plan.finished > 0 then
                    DEFAULT_CHAT_FRAME:AddMessage(("  |cff40c040%d finished|r"):format(
                        #plan.finished))
                end
            end
        end

    elseif command == "wowhead" or command == "link" then
        local questId = tonumber(rest) or QEF.Browse.shownQuestId
        if not questId then
            Say("usage: |cffffd100/qef wowhead <questId>|r, or open a quest in the browser first")
        elseif not QEF.Link.ShowQuest(questId) then
            Say("no link for that quest id")
        end

    elseif command == "way" or command == "waypoint" then
        local questId = tonumber(rest) or QEF.Browse.shownQuestId
        if questId then
            QEF.Waypoint.Go(questId)
        else
            Say("usage: |cffffd100/qef way <questId>|r, or open a quest in the browser first")
        end

    else
        Say("unknown command '" .. command .. "' - try |cffffd100/qef help|r")
    end
end

QEF.RegisterInit("Options", function()
    SLASH_QUESTEXPLORERFOREVER1 = "/qef"
    SLASH_QUESTEXPLORERFOREVER2 = "/questexplorer"
    -- The old command, kept because it is what the fingers know and nothing else claims it
    -- now that the addon it belonged to has become this one.
    SLASH_QUESTEXPLORERFOREVER3 = "/qp"
    SlashCmdList["QUESTEXPLORERFOREVER"] = Handle

    if QEF.migratedFromQuestPreview then
        Say("renamed from QuestPreview - your settings, learned rewards and dungeon "
            .. "checklists came with it")
    end

    if not QEF.Source.available then
        -- Names the fix, not just the fault. QuestieDB is a separate addon from Questie and
        -- is easy to disable by accident, so the one line someone sees at login should say
        -- where to get it back rather than only what stopped working.
        Say("QuestieDB is not loaded - the browser, chain previews, the run planner and the "
            .. "reward sweep are unavailable. Rewards at the quest giver still work.")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff808080Install |r|cffffd100QuestieDB|r|cff808080 "
            .. "from CurseForge - it is its own addon, separate from Questie. "
            .. "|r|cffffd100/qef status|r|cff808080 for detail.|r")
    end
end)
