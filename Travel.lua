-- Travel.lua
--
-- "How do I get there from here?" for a quest giver in another part of the world.
--
-- A word about scope, because this is the one part of the addon that is **authored rather
-- than derived**. Everything else reads real data: the quest database, the item database,
-- the server's own reward answers. There is no machine-readable table of boats and zeppelins
-- anywhere on disk, so the crossings below are written out by hand.
--
-- That makes them the one thing here that can be wrong without the addon being able to tell,
-- so the scope is deliberately narrow:
--
--   * it only solves the genuinely hard part, which is **crossing between continents**;
--   * within a continent it says "travel to <zone>" and leaves you to the flight network,
--     rather than pretending to know a zone-by-zone route;
--   * it offers the crossings your faction can use and lets you pick, rather than claiming
--     one is best;
--   * the table is plain prose in one place, easy to correct if this realm differs.
--
-- Check what it decided with /qef route <questId>.

local ADDON, QEF = ...

local Travel = {}
QEF.Travel = Travel

--------------------------------------------------------------------------------------------
-- Continents
--------------------------------------------------------------------------------------------

-- Fallbacks only. The parent walk below is preferred, because it needs no hardcoded ids.
local CONTINENT = {
    [1414] = "Kalimdor",
    [1415] = "EasternKingdoms",
}

local CONTINENT_NAME = {
    Kalimdor = "Kalimdor",
    EasternKingdoms = "the Eastern Kingdoms",
}

--- Walk a map up to the continent it belongs to.
---@param uiMapId number?
---@return string? key
---@return number? continentMapId
function Travel.ContinentOf(uiMapId)
    uiMapId = QEF.Num(uiMapId)
    if not uiMapId then return nil end

    local continentType = Enum and Enum.UIMapType and Enum.UIMapType.Continent
    local current = uiMapId

    for _ = 1, 12 do
        if CONTINENT[current] then return CONTINENT[current], current end

        local info = QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, current))
        if not info then return nil end
        if continentType and QEF.Num(info.mapType) == continentType then
            return CONTINENT[current] or QEF.Str(info.name), current
        end
        local parent = QEF.Num(info.parentMapID)
        if not parent or parent == 0 or parent == current then return nil end
        current = parent
    end
    return nil
end

--- Where the player is now.
---@return number? uiMapId
---@return string? continentKey
function Travel.PlayerLocation()
    local uiMapId = QEF.Num(QEF.Try(C_Map and C_Map.GetBestMapForUnit, "player"))
    if not uiMapId then return nil end
    return uiMapId, (Travel.ContinentOf(uiMapId))
end

--- Where the player is standing, in the same 0-100 coordinates the quest data uses. The one
--- place that reads a live position, so the checklist's walking order and the guide's
--- "you are here" cannot disagree about it.
---@return number? uiMapId
---@return number? x
---@return number? y
function Travel.PlayerPoint()
    local uiMapId = QEF.Num(QEF.Try(C_Map and C_Map.GetBestMapForUnit, "player"))
    if not uiMapId then return nil end

    local position = QEF.Tbl(QEF.Try(C_Map and C_Map.GetPlayerMapPosition, uiMapId, "player"))
    if not position then return uiMapId end

    local x, y = QEF.Try(position.GetXY, position)
    x, y = QEF.Num(x), QEF.Num(y)
    if not x or not y then return uiMapId end
    return uiMapId, x * 100, y * 100
end

--------------------------------------------------------------------------------------------
-- The crossings
--------------------------------------------------------------------------------------------

-- Authored, not derived. `faction` nil means either side can use it.
-- Edit freely: nothing else in the addon depends on the wording.
Travel.crossings = {
    -- Eastern Kingdoms to Kalimdor
    {
        from = "EasternKingdoms", to = "Kalimdor", faction = "Alliance", kind = "boat",
        text = "Take the boat from Menethil Harbor in the Wetlands to Auberdine in Darkshore.",
    },
    {
        from = "EasternKingdoms", to = "Kalimdor", faction = "Alliance", kind = "boat",
        text = "Or take the boat from Menethil Harbor to Theramore Isle in Dustwallow Marsh, "
            .. "for the southern half of Kalimdor.",
    },
    {
        from = "EasternKingdoms", to = "Kalimdor", faction = "Horde", kind = "zeppelin",
        text = "Take the zeppelin from Durotar's tower outside Orgrimmar - from the Undercity "
            .. "side, the tower outside the Undercity bank.",
    },
    {
        from = "EasternKingdoms", to = "Kalimdor", faction = "Horde", kind = "zeppelin",
        text = "Or take the Grom'gol zeppelin in Stranglethorn Vale to Orgrimmar.",
    },
    {
        from = "EasternKingdoms", to = "Kalimdor", kind = "boat",
        text = "Either faction can take the boat from Booty Bay in Stranglethorn Vale to "
            .. "Ratchet in the Barrens.",
    },

    -- Kalimdor to Eastern Kingdoms
    {
        from = "Kalimdor", to = "EasternKingdoms", faction = "Alliance", kind = "boat",
        text = "Take the boat from Auberdine in Darkshore to Menethil Harbor in the Wetlands.",
    },
    {
        from = "Kalimdor", to = "EasternKingdoms", faction = "Alliance", kind = "boat",
        text = "Or take the boat from Theramore Isle in Dustwallow Marsh to Menethil Harbor.",
    },
    {
        from = "Kalimdor", to = "EasternKingdoms", faction = "Horde", kind = "zeppelin",
        text = "Take a zeppelin from the towers outside Orgrimmar: one to the Undercity, one "
            .. "to Grom'gol in Stranglethorn Vale.",
    },
    {
        from = "Kalimdor", to = "EasternKingdoms", kind = "boat",
        text = "Either faction can take the boat from Ratchet in the Barrens to Booty Bay in "
            .. "Stranglethorn Vale.",
    },
}

-- Within-continent hints worth stating, where a route is not simply "use a flight path".
Travel.hints = {
    {
        continent = "EasternKingdoms", faction = "Alliance",
        text = "The Deeprun Tram connects Stormwind and Ironforge.",
    },
}

--------------------------------------------------------------------------------------------
-- Routing
--------------------------------------------------------------------------------------------

--- Steps from where the player is standing to a quest giver's zone.
---@param targetUiMapId number?
---@param targetZoneName string?
---@return table route { steps = string[], sameContinent = boolean, from, to }
function Travel.Route(targetUiMapId, targetZoneName)
    local route = { steps = {}, sameContinent = nil }

    local playerMapId, playerContinent = Travel.PlayerLocation()
    local targetContinent = Travel.ContinentOf(targetUiMapId)

    route.fromContinent = playerContinent
    route.toContinent = targetContinent

    local playerZone = playerMapId
        and QEF.Str((QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, playerMapId)) or {}).name)
    route.fromZone = playerZone

    -- Without both ends there is nothing honest to say beyond the destination.
    if not playerContinent or not targetContinent then
        if targetZoneName then
            route.steps[1] = "Travel to " .. targetZoneName .. "."
        end
        route.unknown = true
        return route
    end

    local faction = QEF.Art and QEF.Art.PlayerFaction() or nil
    route.sameContinent = playerContinent == targetContinent

    if route.sameContinent then
        if targetZoneName then
            route.steps[#route.steps + 1] = ("You are already in %s. Travel to %s."):format(
                CONTINENT_NAME[playerContinent] or playerContinent, targetZoneName)
        end
        for _, hint in ipairs(Travel.hints) do
            if hint.continent == playerContinent
                and (not hint.faction or hint.faction == faction) then
                route.steps[#route.steps + 1] = hint.text
            end
        end
        return route
    end

    route.steps[#route.steps + 1] = ("%s is in %s, and you are in %s."):format(
        targetZoneName or "That quest giver",
        CONTINENT_NAME[targetContinent] or targetContinent,
        CONTINENT_NAME[playerContinent] or playerContinent)

    local found = 0
    for _, crossing in ipairs(Travel.crossings) do
        if crossing.from == playerContinent and crossing.to == targetContinent
            and (not crossing.faction or crossing.faction == faction) then
            route.steps[#route.steps + 1] = crossing.text
            found = found + 1
        end
    end
    if found == 0 then
        route.steps[#route.steps + 1] = "No crossing is recorded for your faction between "
            .. "those continents."
    end

    if targetZoneName then
        route.steps[#route.steps + 1] = "Then travel to " .. targetZoneName .. "."
    end
    return route
end

--- The route to a quest's starting NPC.
---@param questId number
---@return table? route
function Travel.ToQuestStart(questId)
    local start = QEF.Source.QuestStart(questId)
    if not start then return nil end
    local route = Travel.Route(start.uiMapId, start.zoneName)
    route.start = start
    return route
end

--- Print the route to any recorded place. The checklist points at turn-in NPCs and at the
--- givers of other people's prerequisites, and neither of those is a quest's own start.
---@param place table { zoneName, uiMapId }
---@return boolean said
function Travel.AnnouncePlace(place)
    if type(place) ~= "table" then return false end
    local route = Travel.Route(place.uiMapId, place.zoneName)
    if not route or #route.steps == 0 then return false end
    for index, step in ipairs(route.steps) do
        DEFAULT_CHAT_FRAME:AddMessage(("|cfff2c75b  %d.|r %s"):format(index, step))
    end
    return true
end

--- Print the route in chat, which is what the waypoint button does alongside setting the pin.
---@param questId number
function Travel.Announce(questId)
    local route = Travel.ToQuestStart(questId)
    if not route or #route.steps == 0 then return end
    for index, step in ipairs(route.steps) do
        DEFAULT_CHAT_FRAME:AddMessage(("|cfff2c75b  %d.|r %s"):format(index, step))
    end
end
