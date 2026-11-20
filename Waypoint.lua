-- Waypoint.lua
--
-- Puts a waypoint on the quest giver using Blizzard's own user-waypoint and supertracking,
-- so it shows on the map, on the minimap and in the navigation arrow exactly like a /way
-- pin, with no extra pin layer of this addon's own.
--
-- Forever's user-waypoint API is known to be unreliable on some maps: ForeverDungeonJournal
-- avoids it for that reason, while EnhanceQoL and OpenMap use it with guards. Since the
-- Blizzard one is what was asked for, this guards the same way and then *verifies the result
-- by reading the waypoint back*, so a silent refusal is reported rather than leaving you
-- staring at an empty map.

local ADDON, QEF = ...

local Waypoint = {}
QEF.Waypoint = Waypoint

--------------------------------------------------------------------------------------------
-- Capability
--------------------------------------------------------------------------------------------

---@return boolean supported
---@return string? reason
function Waypoint.IsSupported()
    if type(C_Map) ~= "table" or type(C_Map.SetUserWaypoint) ~= "function" then
        return false, "this client has no user waypoint API"
    end
    if type(UiMapPoint) ~= "table" or type(UiMapPoint.CreateFromCoordinates) ~= "function" then
        return false, "this client cannot build map points"
    end
    return true
end

--------------------------------------------------------------------------------------------
-- Setting
--------------------------------------------------------------------------------------------

--- Place and supertrack a waypoint.
---@param uiMapId number
---@param x number 0-100
---@param y number 0-100
---@return boolean placed
---@return string? reason
function Waypoint.Set(uiMapId, x, y)
    local supported, reason = Waypoint.IsSupported()
    if not supported then return false, reason end

    uiMapId = QEF.Num(uiMapId)
    x, y = QEF.Num(x), QEF.Num(y)
    if not uiMapId or not x or not y then return false, "no coordinates recorded for it" end

    local mapInfo = QEF.Tbl(QEF.Try(C_Map.GetMapInfo, uiMapId))
    if not mapInfo then return false, "this client does not know that map" end

    if type(C_Map.CanSetUserWaypointOnMap) == "function"
        and not QEF.Try(C_Map.CanSetUserWaypointOnMap, uiMapId) then
        return false, ("waypoints are not allowed on %s"):format(QEF.Str(mapInfo.name) or "that map")
    end

    local point = QEF.Try(UiMapPoint.CreateFromCoordinates, uiMapId, x / 100, y / 100)
    if not point then return false, "could not build the map point" end

    local ok = pcall(C_Map.SetUserWaypoint, point)
    if not ok then return false, "the client refused the waypoint" end

    -- Forever can accept the call and still not keep the waypoint. Read it back rather than
    -- reporting success the client did not actually deliver.
    if type(C_Map.GetUserWaypoint) == "function" then
        local stored = QEF.Tbl(QEF.Try(C_Map.GetUserWaypoint))
        if not stored then
            return false, "the client accepted the waypoint but did not keep it"
        end
    end

    if type(C_SuperTrack) == "table"
        and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
        QEF.Try(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end

    Waypoint.lastMapId = uiMapId
    Waypoint.lastX, Waypoint.lastY = x, y
    return true
end

--- Place a waypoint on a quest's starting NPC.
---@param questId number
---@return boolean placed
---@return string? message  a reason on failure, or a description on success
function Waypoint.ToQuestStart(questId)
    questId = QEF.QuestId(questId)
    if not questId then return false, "no quest" end

    local start = QEF.Source.QuestStart(questId)
    if not start then
        return false, "no quest giver recorded - it may be started by an item or an object"
    end
    if not start.uiMapId or not start.x then
        return false, ("%s has no recorded location"):format(start.name or "that quest giver")
    end

    local placed, reason = Waypoint.Set(start.uiMapId, start.x, start.y)
    if not placed then return false, reason end

    return true, ("%s in %s (%.1f, %.1f)"):format(
        start.name or "quest giver", start.zoneName or "zone", start.x, start.y)
end

--- Place a waypoint and say what happened in chat, which is what every caller wants.
---@param questId number
function Waypoint.Go(questId)
    local placed, message = Waypoint.ToQuestStart(questId)
    if placed then
        QEF.Print("waypoint set: " .. message)
    else
        QEF.Print("|cffff8040no waypoint|r - " .. (message or "unknown reason"))
    end

    -- The directions are worth having either way: a pin you cannot place still has a route.
    if not QEF.Get("showTravel") then return placed end

    local note = placed and ("Map pin set on " .. message)
        or ("No map pin - " .. (message or "unknown reason"))

    if QEF.Get("routeWindow") and QEF.Route and QEF.Route.Show(questId, note) then
        return placed
    end
    if QEF.Travel then QEF.Travel.Announce(questId) end
    return placed
end

function Waypoint.Clear()
    if type(C_Map) == "table" and type(C_Map.ClearUserWaypoint) == "function" then
        QEF.Try(C_Map.ClearUserWaypoint)
    end
end
