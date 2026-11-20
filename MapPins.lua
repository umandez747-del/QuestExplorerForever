-- MapPins.lua
--
-- The checklist, on the world map: a pin for every step you still owe, and for the
-- objectives of the ones already in your log.
--
-- These are the addon's own pins, not a hook into anyone else's. They go on the map the
-- way Blizzard's own do - a data provider and a pin pool on the map canvas - so they pan,
-- zoom and survive a map addon reskinning the frame around them.
--
-- With Questie loaded they stay off unless you ask for them. Questie already draws a map
-- full of quest icons, and two addons drawing the same quests is worse than either alone:
-- you cannot tell whose icon you are looking at, and clicking the wrong one does nothing
-- you expected. So "auto" means "only when nobody else is doing it".
--
-- What is drawn, and nothing beyond it: where to pick a quest up, where to hand it in, who
-- is in the way when it is locked, and - for a quest in your log - the creatures its
-- objectives name, both as pins of their own and as the place that quest's own step points
-- at. Objectives that are items to gather or objects to click need a lookup this does not
-- do, so those quests show their giver and their turn-in and nothing in the field.

local ADDON, QEF = ...

local MapPins = {}
QEF.MapPins = MapPins

local Art, Checklist, Source, Guide, Tooltip, Search

-- The pool is keyed by this in the map's own pin pools, which is how AcquirePin finds it
-- without an XML template to go with it.
local TEMPLATE = "QuestExplorerForeverMapPin"
-- Height, not size: the art is a teardrop and its width follows from that.
local PIN_HEIGHT = 26
-- An NPC can have a hundred recorded spawns and a zone can hold a lot of objectives. These
-- are the point where a map stops being readable, not a performance limit.
local MAX_SPAWNS_PER_NPC = 24
local MAX_OBJECTIVE_PINS = 24
-- How close two spawns have to be, in map percent, before they are one place rather than
-- two. A camp of eight murlocs is somewhere to go, not eight somewheres.
local CLUSTER_RADIUS = 6
-- And past this many camps a quest has stopped telling you where to go and started
-- colouring the zone in.
local MAX_CLUSTERS_PER_QUEST = 4
-- A zone can hold two hundred quests. Past this it stops being a map and starts being a
-- wall of exclamation marks, which is the failure mode of every addon that draws all of
-- them without asking.
local MAX_AVAILABLE_PINS = 60
-- Where to put a pin if the canvas will not place it itself.
local FALLBACK_FRAME_LEVEL = 500
-- How much of its normal size a pin keeps on a map that is not a zone. A pin holds its
-- size while the map around it shrinks, so the same mark that sits neatly over a building
-- in Hillsbrad covers half of Lordaeron on the continent. These are by map rather than by
-- zoom because the zoom is the canvas's business and the map is ours.
local MAP_SCALE = { continent = 0.72, world = 0.55 }

local provider, pinPool, refreshQueued
-- uiMapId -> the available-quest pins worked out for it, emptied whenever anything that
-- could change a quest's status happens.
local availableCache = {}
-- And the two passes together, which is what the drawing actually asks for.
local beyondCache = {}

--------------------------------------------------------------------------------------------
-- Capability
--------------------------------------------------------------------------------------------

---@return boolean supported
---@return string? reason
function MapPins.Supported()
    if type(WorldMapFrame) ~= "table" then
        return false, "this client has no world map frame"
    end
    if type(MapCanvasDataProviderMixin) ~= "table" or type(MapCanvasPinMixin) ~= "table" then
        return false, "this client's map takes no custom pins"
    end
    if type(WorldMapFrame.AddDataProvider) ~= "function"
        or type(WorldMapFrame.GetCanvas) ~= "function"
        or type(WorldMapFrame.pinPools) ~= "table" then
        return false, "this client's map canvas is missing the pin plumbing"
    end
    return true
end

--- Whether pins should be drawn at all.
--- "auto" is the default and means: stay out of Questie's way.
---@return boolean
function MapPins.Enabled()
    local setting = QEF.Get("mapPins")
    if setting == "off" then return false end
    if not MapPins.Supported() then return false end
    if setting == "on" then return true end
    return not (Source and Source.questieAvailable)
end

--------------------------------------------------------------------------------------------
-- What to draw
--------------------------------------------------------------------------------------------

--- Which mark a step wears, and in which style.
---
--- Every pin wears the one style the player chose, and the shape carries the meaning: a
--- bang for somewhere to go, a query for something to hand in. Six styles at once is a
--- fairground; one style reads as a system.
---@param kind string
---@param current boolean
---@return string mark
---@return string? style
local function PinArtFor(kind, current)
    local mark = (kind == "turnin") and "query" or "bang"
    -- The guide's step takes the glowing style whatever is set: that one is not
    -- decoration, it is which way to walk.
    if current then return mark, "glow" end
    return mark
end

--- Where a zone point falls on whatever map is open.
---
--- A step's coordinates belong to its own zone map, so matching them against the displayed
--- map only ever drew pins while you were looking at that exact zone - open the continent
--- and the map went empty, which is the opposite of useful for a run that crosses three
--- zones. Both points are converted to world coordinates and the target's own rectangle is
--- measured the same way, so the ratio comes out right without this code having to know
--- which axis the world runs along.
---@param fromMapId number
---@param x number 0-100 in its own zone
---@param y number
---@param toMapId number the map being displayed
---@return number? x
---@return number? y
local function Project(fromMapId, x, y, toMapId)
    if fromMapId == toMapId then return x, y end
    if type(C_Map) ~= "table" or type(C_Map.GetWorldPosFromMapPos) ~= "function"
        or type(CreateVector2D) ~= "function" then
        return nil
    end

    local instance, world = QEF.Try(C_Map.GetWorldPosFromMapPos, fromMapId,
        CreateVector2D(x / 100, y / 100))
    if not world then return nil end

    local targetInstance, topLeft = QEF.Try(C_Map.GetWorldPosFromMapPos, toMapId,
        CreateVector2D(0, 0))
    local _, bottomRight = QEF.Try(C_Map.GetWorldPosFromMapPos, toMapId,
        CreateVector2D(1, 1))
    if not topLeft or not bottomRight then return nil end
    -- Different continents share coordinate values and mean nothing by it.
    if instance ~= targetInstance then return nil end

    local worldX, worldY = QEF.Try(world.GetXY, world)
    local leftX, topY = QEF.Try(topLeft.GetXY, topLeft)
    local rightX, bottomY = QEF.Try(bottomRight.GetXY, bottomRight)
    worldX, worldY = QEF.Num(worldX), QEF.Num(worldY)
    leftX, topY = QEF.Num(leftX), QEF.Num(topY)
    rightX, bottomY = QEF.Num(rightX), QEF.Num(bottomY)
    -- All six, not just the three that get used first: this client can hand back a secret
    -- value for any of them, QEF.Num turns that into nil, and the arithmetic below would
    -- then throw inside a refresh that swallows its own errors - which is how a map ends
    -- up empty with nothing anywhere saying why.
    if not (worldX and worldY and leftX and topY and rightX and bottomY) then return nil end
    if rightX == leftX or bottomY == topY then return nil end

    local px = (worldX - leftX) / (rightX - leftX)
    local py = (worldY - topY) / (bottomY - topY)
    -- Off the edge of the map being looked at: not a pin, just arithmetic.
    if px < 0 or px > 1 or py < 0 or py > 1 then return nil end
    return px * 100, py * 100
end

--- How big a pin should be on this map.
---
--- Enum.UIMapType counts up from the cosmic map: 0 cosmic, 1 world, 2 continent, 3 zone,
--- and everything more detailed than a zone above that. Anything at zone level or finer
--- gets a full-size pin; the wider views get a smaller one so the marks still read as
--- marks rather than as a lid over the landscape.
---@param uiMapId number
---@return number scale
local function ScaleForMap(uiMapId)
    local info = QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, uiMapId))
    local mapType = info and QEF.Num(info.mapType)
    if not mapType or mapType >= 3 then return 1 end
    if mapType == 2 then return MAP_SCALE.continent end
    return MAP_SCALE.world
end

--- Every spawn of an NPC that is on the map being looked at.
---@param npcId number
---@param uiMapId number
---@return table[] points { x, y }
local function SpawnsOnMap(npcId, uiMapId)
    local points = {}
    local spawns = Source.NpcSpawns(npcId)
    if not spawns then return points end

    for areaId, list in pairs(spawns) do
        local spawnMapId = Source.UiMapIdForArea(areaId)
        if spawnMapId then
            for _, point in ipairs(QEF.Tbl(list) or {}) do
                local pair = QEF.Tbl(point)
                local x, y = QEF.Num(pair and pair[1]), QEF.Num(pair and pair[2])
                -- 0,0 means "somewhere in this zone", which is not a place to draw.
                if x and y and (x ~= 0 or y ~= 0) then
                    -- Projected like the steps are, so the creatures show on a continent
                    -- map too rather than only in their own zone.
                    local px, py = Project(spawnMapId, x, y, uiMapId)
                    if px then
                        -- Both: where to draw it on the map being looked at, and where it
                        -- really is. A waypoint wants the second - a continent map will
                        -- not take one, and projected coordinates mean nothing off the
                        -- map they were projected onto.
                        points[#points + 1] = {
                            x = px, y = py,
                            mapId = spawnMapId, mapX = x, mapY = y,
                        }
                        if #points >= MAX_SPAWNS_PER_NPC then return points end
                    end
                end
            end
        end
    end
    return points
end

--- Gather points that sit on top of each other into one point apiece.
---
--- A quest's objective NPC is recorded once per spawn, and a camp of them is a dozen
--- spawns a few yards apart. Drawn literally that is a dozen identical pins in a huddle,
--- which says nothing a single pin does not and buries the rest of the map. Each cluster
--- keeps a running mean of what joined it, so the pin lands in the middle of the camp
--- rather than on whichever corner of it happened to be read first.
---@param points table[] { x, y, label }
---@return table[] clusters { x, y, count, label }, busiest first
local function Cluster(points)
    local clusters = {}
    for _, point in ipairs(points) do
        local joined = false
        for _, cluster in ipairs(clusters) do
            local dx, dy = point.x - cluster.x, point.y - cluster.y
            if dx * dx + dy * dy <= CLUSTER_RADIUS * CLUSTER_RADIUS then
                cluster.count = cluster.count + 1
                cluster.x = cluster.x + (point.x - cluster.x) / cluster.count
                cluster.y = cluster.y + (point.y - cluster.y) / cluster.count
                if point.label and not cluster.label then cluster.label = point.label end
                joined = true
                break
            end
        end
        if not joined then
            clusters[#clusters + 1] = {
                x = point.x, y = point.y, count = 1, label = point.label,
                -- The cluster's own centre is in projected coordinates; this is a real
                -- place inside it, which is what a waypoint can be set on.
                mapId = point.mapId, mapX = point.mapX, mapY = point.mapY,
            }
        end
    end

    -- Busiest first, so a quest that is capped keeps the places most of its targets are.
    table.sort(clusters, function(a, b) return a.count > b.count end)
    return clusters
end

--- Where to go for one quest you are already carrying: a handful of pins, not a cloud.
---@param questId number
---@param name string
---@param uiMapId number
---@return table[] pins
local function ObjectivePins(questId, name, uiMapId)
    local points = {}
    for _, creature in ipairs(Source.ObjectiveNpcs(questId)) do
        local label = creature.text or Source.NpcName(creature.id)
        for _, point in ipairs(SpawnsOnMap(creature.id, uiMapId)) do
            points[#points + 1] = { x = point.x, y = point.y, label = label }
        end
    end

    local pins = {}
    for index, cluster in ipairs(Cluster(points)) do
        if index > MAX_CLUSTERS_PER_QUEST then break end
        pins[#pins + 1] = {
            kind = "objective",
            questId = questId,
            title = name,
            subtitle = cluster.label,
            spawns = cluster.count,
            x = cluster.x, y = cluster.y,
            mapId = cluster.mapId, mapX = cluster.mapX, mapY = cluster.mapY,
        }
    end
    return pins
end

--- The quests already in your log, drawn the same way the checklist's are.
---
--- This is the half that was missing. The checklist draws what you planned; the game draws
--- a `?` over anything you can hand in whether you planned it or not, and until now this
--- addon drew nothing for a quest you were simply carrying - so a turn-in you had not put
--- on a list showed Blizzard's mark and none of ours, which reads as ours being broken.
---@param uiMapId number
---@return table[] pins
local function LogPins(uiMapId)
    local pins = {}
    if type(C_QuestLog) ~= "table" then return pins end

    local entries = QEF.Num(QEF.Try(C_QuestLog.GetNumQuestLogEntries)) or 0
    local objectives = 0

    for index = 1, entries do
        local info = QEF.Tbl(QEF.Try(C_QuestLog.GetInfo, index))
        local questId = info and not info.isHeader and QEF.QuestId(info.questID) or nil
        -- Anything on the checklist already has a step of its own, with the guide's ring.
        if questId and not (Checklist and Checklist.Has(questId)) then
            local name = Source.QuestName(questId) or ("Quest " .. questId)

            if QEF.Try(C_QuestLog.IsComplete, questId) == true then
                local finish = Source.QuestEnd(questId)
                if finish and finish.uiMapId and finish.x and finish.y then
                    local px, py = Project(finish.uiMapId, finish.x, finish.y, uiMapId)
                    if px then
                        pins[#pins + 1] = {
                            kind = "turnin", questId = questId,
                            title = "Hand in " .. name, subtitle = finish.name,
                            x = px, y = py,
                            mapId = finish.uiMapId, mapX = finish.x, mapY = finish.y,
                        }
                    end
                end
            elseif objectives < MAX_OBJECTIVE_PINS then
                for _, pin in ipairs(ObjectivePins(questId, name, uiMapId)) do
                    pins[#pins + 1] = pin
                    objectives = objectives + 1
                    if objectives >= MAX_OBJECTIVE_PINS then break end
                end
            end
        end
    end

    return pins
end

--- Quests in the open zone that you could go and pick up now.
---
--- The browser's index already knows every quest by zone and faction, so this is a filter
--- over data that is built either way; the cost is one spawn lookup per quest that passes,
--- which is why the answer is cached per map and thrown away whenever a quest event could
--- have changed it.
---@param uiMapId number
---@return table[] pins
local function AvailablePins(uiMapId)
    if not QEF.Get("mapAvailable") then return {} end
    if availableCache[uiMapId] then return availableCache[uiMapId] end

    -- The index is built on first use and is not worth blocking on: ask for it, draw the
    -- checklist meanwhile, and the next refresh will have it. Deliberately not cached.
    if not Search or not Search.ready then
        if Search then Search.Ensure() end
        return {}
    end

    local info = QEF.Tbl(QEF.Try(C_Map and C_Map.GetMapInfo, uiMapId))
    local zone = info and QEF.Str(info.name)
    if not zone then return {} end

    local pins = {}
    for _, entry in ipairs(Search.Query({
        zone = zone,
        myFaction = Art ~= nil and Art.PlayerFaction() ~= nil,
    })) do
        if #pins >= MAX_AVAILABLE_PINS then break end
        -- Anything on the checklist is already drawn as a step, with the guide's ring and
        -- its own art; drawing it again as a plain available quest would be two pins for
        -- one quest and the wrong one on top.
        if not (Checklist and Checklist.Has(entry.id))
            and Source.QuestStatus(entry.id) == "available" then
            local start = Source.QuestStart(entry.id)
            if start and start.uiMapId and start.x and start.y then
                local px, py = Project(start.uiMapId, start.x, start.y, uiMapId)
                if px then
                    pins[#pins + 1] = {
                        kind = "available",
                        questId = entry.id,
                        title = entry.name,
                        subtitle = start.name,
                        x = px, y = py,
                        mapId = start.uiMapId, mapX = start.x, mapY = start.y,
                    }
                end
            end
        end
    end

    availableCache[uiMapId] = pins
    return pins
end

--- Everything this addon draws that is not on the checklist: the quests you are carrying
--- and the quests the zone has going spare. One cache, because one quest event can change
--- either of them.
---@param uiMapId number
---@return table[] pins
local function BeyondTheList(uiMapId)
    if not QEF.Get("mapAvailable") then return {} end
    if beyondCache[uiMapId] then return beyondCache[uiMapId] end

    local pins = LogPins(uiMapId)
    for _, pin in ipairs(AvailablePins(uiMapId)) do pins[#pins + 1] = pin end

    -- Only kept once the index is ready; before that the available half is empty and would
    -- cache a wrong answer.
    if Search and Search.ready then beyondCache[uiMapId] = pins end
    return pins
end

--- The pins for one map: the checklist's own steps, the objectives of the quests on it you
--- are already carrying, and everything beyond the list.
---@param uiMapId number
---@return table[] pins
function MapPins.PinsFor(uiMapId)
    local pins = {}

    -- An empty checklist is no longer the end of it: the zone's own quests are drawn
    -- whether or not you have planned anything.
    if not Checklist or Checklist.Count() == 0 then
        for _, pin in ipairs(BeyondTheList(uiMapId)) do pins[#pins + 1] = pin end
        return pins
    end

    local plan = Checklist.Plan()
    local current = Guide and Guide.current

    for _, group in ipairs(plan.groups) do
        for _, entry in ipairs(group.entries) do
            local step = entry.step
            local x, y
            if step.uiMapId and step.x and step.y then
                x, y = Project(step.uiMapId, step.x, step.y, uiMapId)
            end
            if x then
                pins[#pins + 1] = {
                    kind = step.kind,
                    questId = entry.id,
                    title = ("%s %s"):format(step.verb or "Go to", step.subject or entry.name),
                    subtitle = step.npc,
                    x = x, y = y,
                    mapId = step.uiMapId, mapX = step.x, mapY = step.y,
                    current = current ~= nil and current.questId == entry.id
                        and current.kind == step.kind,
                }
            end
        end
    end

    -- Objectives, for the quests on the list that are already in your log. A quest you have
    -- not picked up yet has a giver to draw and nothing else worth saying.
    local objectivePins = 0
    for _, group in ipairs(plan.groups) do
        for _, entry in ipairs(group.entries) do
            if entry.status == "active" or entry.status == "ready" then
                for _, pin in ipairs(ObjectivePins(entry.id, entry.name, uiMapId)) do
                    pins[#pins + 1] = pin
                    objectivePins = objectivePins + 1
                    if objectivePins >= MAX_OBJECTIVE_PINS then return pins end
                end
            end
        end
    end

    for _, pin in ipairs(BeyondTheList(uiMapId)) do pins[#pins + 1] = pin end
    return pins
end

--------------------------------------------------------------------------------------------
-- The pin
--------------------------------------------------------------------------------------------

local PinMixin = {}

--- Let the canvas place the pin, and place it ourselves only if it will not.
---
--- Setting a plain level instead and skipping `UseFrameLevelType` looked like the obvious
--- way to climb above the frame that was taking our hovers. It is not: the canvas asks
--- each pin to reapply its own level during a refresh, a pin that never registered a level
--- type has nothing to reapply, and that throws inside the canvas's own loop and takes the
--- entire draw with it. Every pin disappeared. So the canvas gets its way here, and the
--- mouse is won somewhere it cannot interfere with - see the hover watcher below.
---
--- The call is still contained: it asserts rather than returning nil on a type it does not
--- know, and that assert lands inside Blizzard's AcquirePin.
---@param pin table
local function TakeFrameLevel(pin)
    if MapPins.frameLevelType == false then
        local canvas = pin:GetParent()
        local base = (canvas and canvas.GetFrameLevel and canvas:GetFrameLevel()) or 1
        pcall(pin.SetFrameLevel, pin, base + FALLBACK_FRAME_LEVEL)
        return
    end

    if pcall(pin.UseFrameLevelType, pin, "PIN_FRAME_LEVEL_AREA_POI") then
        MapPins.frameLevelType = true
        return
    end

    MapPins.frameLevelType = false
    QEF.Debug("map pins: the canvas refused PIN_FRAME_LEVEL_AREA_POI, using a plain level")
    TakeFrameLevel(pin)
end

function PinMixin:OnLoad()
    TakeFrameLevel(self)
    -- Held at whatever the current map calls for. Both ends of the limit are the same
    -- number on purpose: the canvas clamps its own zoom scaling into that range, so
    -- setting both pins the size rather than leaving it a band the canvas can drift
    -- across while you zoom.
    local scale = MapPins.drawScale or 1
    pcall(self.SetScalingLimits, self, 1, scale, scale)
    pcall(self.SetScale, self, scale)
end

function PinMixin:OnAcquired(data)
    -- Re-taken on each acquire, because a released pin does not keep its level - but
    -- contained, so a canvas that refuses the named type cannot break the draw.
    TakeFrameLevel(self)
    -- Re-asserted per acquire, for the same reason the frame level is.
    pcall(self.SetMouseMotionEnabled, self, true)
    pcall(self.SetMouseClickEnabled, self, true)
    local scale = MapPins.drawScale or 1
    pcall(self.SetScalingLimits, self, 1, scale, scale)
    pcall(self.SetScale, self, scale)
    self:SetPosition(data.x / 100, data.y / 100)
    self.data = data

    local aspect
    if data.test then
        -- A texture that ships with the client, so the test pin cannot fail for the same
        -- reason the real ones might.
        self.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        self.icon:SetTexCoord(0, 1, 0, 1)
        self.icon:SetVertexColor(1, 1, 1, 1)
        aspect = 1
    else
        aspect = Art.SetPin(self.icon, PinArtFor(data.kind, data.current))
    end
    -- The art is a tall teardrop, so the frame has to match its shape or the pin squashes.
    local width = PIN_HEIGHT * aspect
    self:SetSize(width, PIN_HEIGHT)

    -- SetPosition centres the frame on the coordinate, which for a teardrop puts the spot
    -- being marked halfway up the drop. The art is hung above the centre instead, so the
    -- point of it lands on the place - the whole reason this shape is a teardrop.
    self.icon:ClearAllPoints()
    self.icon:SetPoint("BOTTOM", self, "CENTER", 0, 0)
    self.icon:SetSize(width, PIN_HEIGHT)

    -- Which is why the pins had no tooltips: the frame is centred on the spot but the art
    -- hangs above it, so the mouse area and the thing you can see only overlapped in their
    -- bottom and top halves respectively - hover the teardrop and you hit nothing. The hit
    -- area is lifted to sit exactly on the art. Negative insets grow the area, positive
    -- ones shrink it.
    self:SetHitRectInsets(0, 0, -PIN_HEIGHT / 2, PIN_HEIGHT / 2)
    self:Show()
end

function PinMixin:OnReleased()
    self.data = nil
    self:Hide()
end

-- Blizzard calls this on pins in combat on some builds; harmless to answer for.
PinMixin.SetPassThroughButtons = function() end

local function OnPinEnter(pin)
    local data = pin.data
    if not data then return end
    -- While the watcher is running it owns hovering outright, and the frame system's own
    -- OnEnter is ignored. Two of them taking turns is how the tooltip ended up depending
    -- on which fired first, and one owner is worth more here than one less function call.
    if not MapPins.callingByHand then
        MapPins.mouseWorks = true
        if MapPins.handHovering then return end
    end
    -- Grown from the point rather than from the middle, so hovering does not move the
    -- spot it is marking.
    pin.icon:SetSize((pin:GetWidth() or 18) * 1.18, (pin:GetHeight() or 26) * 1.18)

    -- The addon's own tooltip, which is the whole preview rather than a name and a dash.
    -- If it has nothing to say - the preview is switched off, or the quest is not in the
    -- data - the plain one below goes up instead. A pin that answers nothing is
    -- indistinguishable from a pin that is not listening, which is how three versions went
    -- by with this looking like a mouse problem.
    if Tooltip and data.questId and Tooltip.Show(pin, data.questId, {
            atGiver = false,
            footer = "Click to mark the spot - shift-click to open it here",
        }) then
        MapPins.lastTooltip = "the preview"
        return
    end

    MapPins.lastTooltip = "the plain one"
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(data.title, 1, 1, 1)
    if data.subtitle then GameTooltip:AddLine(data.subtitle, 0.6, 0.62, 0.67, true) end
    GameTooltip:AddLine(("%.1f, %.1f"):format(data.x or 0, data.y or 0), 0.55, 0.57, 0.62)
    GameTooltip:AddLine("Click to mark the spot - shift-click to open it here",
        0.42, 0.37, 0.35)
    GameTooltip:Show()
end

local function OnPinLeave(pin)
    if MapPins.handHovering and not MapPins.callingByHand then return end
    pin.icon:SetSize(pin:GetWidth() or 18, pin:GetHeight() or 26)
    if Tooltip then Tooltip.Hide() end
    GameTooltip:Hide()
end

--- Read a console variable without caring which of the two ways this client offers it.
---@param name string
---@return string? value
local function CVar(name)
    if C_CVar and type(C_CVar.GetCVar) == "function" then
        return QEF.Str(QEF.Try(C_CVar.GetCVar, name))
    end
    if type(GetCVar) == "function" then return QEF.Str(QEF.Try(GetCVar, name)) end
    return nil
end

---@param name string
---@param value string
---@return boolean set
local function SetCVarSafely(name, value)
    if C_CVar and type(C_CVar.SetCVar) == "function" then
        return pcall(C_CVar.SetCVar, name, value)
    end
    if type(SetCVar) == "function" then return pcall(SetCVar, name, value) end
    return false
end

--- Make sure the arrow the marker draws is actually switched on.
---
--- Placing a waypoint while the in-game navigation is off is the kind of failure that
--- looks like the addon doing nothing: the waypoint is really there, on the map and the
--- minimap, and the thing the player was watching for - the arrow and the distance in the
--- world - never appears.
local function EnsureNavigation()
    local current = CVar("showInGameNavigation")
    if current == nil or current == "1" then return end
    if SetCVarSafely("showInGameNavigation", "1") then
        QEF.Print("turned the in-game navigation arrow on, so the marker shows in the world")
    end
end

--- Click to mark the spot; shift-click to read about the quest.
---@param pin table
local function OnPinClick(pin)
    local data = pin.data
    if not data or not data.questId then return end

    -- The pin's own script and the canvas-wide fallback below can both fire for one
    -- click. Whichever arrives first does the work and the other finds the door shut.
    local now = GetTime and GetTime() or 0
    if now - (MapPins.lastClick or 0) < 0.15 then return end
    MapPins.lastClick = now
    MapPins.clicks = (MapPins.clicks or 0) + 1

    -- Shift is the game's own convention for "tell me more about this" rather than "act on
    -- it", and the browser is where this addon keeps everything it knows about a quest.
    if IsShiftKeyDown and IsShiftKeyDown() then
        if QEF.Browse then QEF.Browse.Open(data.questId) end
        return
    end

    -- A quest on the checklist belongs to the guide, which places the marker itself and
    -- moves it on as you finish each step. Taking it over here would strand it.
    if Checklist and Checklist.Has(data.questId) then
        if Guide and Guide.Pin(data.questId) then EnsureNavigation() end
        return
    end

    -- Anything else gets a marker on this pin's own place. Its real coordinates, not the
    -- ones it is drawn at: a pin on a continent map is drawn where its zone sits on the
    -- continent, and a waypoint set there would point at a stretch of coastline.
    local waypoint = QEF.Waypoint
    if not waypoint then return end

    local placed, why = waypoint.Set(
        data.mapId or data.uiMapId,
        data.mapX or data.x,
        data.mapY or data.y)

    if placed then
        EnsureNavigation()
        QEF.Print(("marking |cfff2c75b%s|r"):format(data.title or "that spot"))
    else
        QEF.Print("|cffff8040no marker|r - " .. (why or "the client would not take one"))
    end
end

--------------------------------------------------------------------------------------------
-- Hovering, when the canvas will not do it for us
--------------------------------------------------------------------------------------------

-- A pin is a frame with an OnEnter on it, which on a well-behaved canvas is the whole
-- story. This canvas is not obliged to be well-behaved: it owns its pins' mouse state
-- through the mixin, and on a client where that routing never reaches an addon's own pool
-- the scripts simply do not fire and the pins are decoration you cannot ask about. So the
-- hover is also worked out by hand, from the cursor and the pins' own rectangles - but
-- only until the real thing fires once, after which this turns itself off for the session
-- and costs nothing for the rest of it.
local hoverWatch, hovered
local StopHoverWatch

--- Which of our live pins the cursor is over, by arithmetic rather than by frame.
---@return table? pin
local function PinUnderCursor()
    if not provider or not provider.GetMap then return nil end
    local map = provider:GetMap()
    if not map or not map.EnumeratePinsByTemplate then return nil end

    local cursorX, cursorY = GetCursorPosition()
    if not cursorX or not cursorY then return nil end

    for pin in map:EnumeratePinsByTemplate(TEMPLATE) do
        if pin.data and pin:IsVisible() then
            local scale = pin:GetEffectiveScale() or 1
            local x, y = cursorX / scale, cursorY / scale
            local left, bottom = pin:GetLeft(), pin:GetBottom()
            local width, height = pin:GetWidth(), pin:GetHeight()
            if left and bottom and width and height then
                -- The art hangs above the frame's centre so its point marks the spot,
                -- which puts what you can see half a pin higher than the frame itself.
                local lift = height / 2
                if x >= left and x <= left + width
                    and y >= bottom + lift and y <= bottom + height + lift then
                    return pin
                end
            end
        end
    end
    return nil
end

StopHoverWatch = function()
    if hovered then
        MapPins.callingByHand = true
        OnPinLeave(hovered)
        MapPins.callingByHand = nil
        hovered = nil
    end
    MapPins.handHovering = nil
    if hoverWatch then
        hoverWatch:SetScript("OnUpdate", nil)
        hoverWatch.running = false
    end
end

local function WatchHover()
    -- A redraw releases pins, and a released pin is not what anyone is hovering.
    if hovered and not (hovered.data and hovered:IsVisible()) then hovered = nil end

    local pin = PinUnderCursor()
    if pin == hovered then return end

    MapPins.callingByHand = true
    if hovered then OnPinLeave(hovered) end
    hovered = pin
    if pin then
        MapPins.handEnters = (MapPins.handEnters or 0) + 1
        OnPinEnter(pin)
    end
    MapPins.callingByHand = nil
end

--- Catch clicks on the map for whichever pin the watcher says is under the cursor.
---
--- Hovering had to be worked out by hand because the canvas does not reliably pass it to
--- an addon's own pins, and a click is the same arrangement with the same hole in it: the
--- pin's OnMouseUp fires when the canvas feels like routing it and not otherwise. The
--- canvas itself always gets the click, though, so it is hooked - additively, so nothing
--- of Blizzard's own panning and zooming is disturbed - and the pin under the cursor is
--- the one that gets told. A click with no pin under it falls through untouched.
---@param map table
local function HookCanvasClicks(map)
    if not map then return end

    -- Both, where both exist: the scroll container is what takes the click on a stock
    -- map, and the canvas is what takes it where a map addon has rearranged things.
    local targets = {
        map.ScrollContainer,
        map.GetCanvas and map:GetCanvas() or nil,
    }

    for _, frame in ipairs(targets) do
        if frame and frame.HookScript and not frame.qefClickHook then
            frame.qefClickHook = true
            pcall(frame.HookScript, frame, "OnMouseUp", function()
                if hovered then OnPinClick(hovered) end
            end)
        end
    end
end

local function StartHoverWatch()
    hoverWatch = hoverWatch or CreateFrame("Frame")
    if hoverWatch.running then return end
    hoverWatch.running = true
    MapPins.handHovering = true

    local since = 0
    hoverWatch:SetScript("OnUpdate", function(_, delta)
        since = since + delta
        -- Twenty times a second over at most a few dozen rectangles: far below the cost
        -- of the map redrawing itself, and indistinguishable from a real hover.
        if since < 0.05 then return end
        since = 0
        MapPins.hoverTicks = (MapPins.hoverTicks or 0) + 1
        if not WorldMapFrame or not WorldMapFrame:IsVisible() then
            StopHoverWatch()
            return
        end
        WatchHover()
    end)
end

local function CreatePin()
    local pin = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
    pin:SetSize(PIN_HEIGHT * 0.7, PIN_HEIGHT)
    Mixin(pin, MapCanvasPinMixin, PinMixin)

    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints(pin)

    -- The canvas manages its pins' mouse state through the mixin and overrides a plain
    -- EnableMouse on acquire, which is why these pins had no tooltips.
    pin:EnableMouse(true)
    pcall(pin.SetMouseMotionEnabled, pin, true)
    pcall(pin.SetMouseClickEnabled, pin, true)
    pin:SetScript("OnEnter", OnPinEnter)
    pin:SetScript("OnLeave", OnPinLeave)
    pin:SetScript("OnMouseUp", OnPinClick)
    return pin
end

--------------------------------------------------------------------------------------------
-- The provider
--------------------------------------------------------------------------------------------

--- Put our pool in the canvas's own table of them, replacing anything else under our
--- template name.
---
--- AcquirePin looks a pool up by template and, finding none, builds one itself from an XML
--- template of that name - which for us does not exist, so the frames it makes carry none
--- of the pin mixin and the very next line calls a method they do not have. It then keeps
--- that broken pool forever, so losing the race once means losing it for the session.
---
--- Registering at build time is not enough on its own: the canvas empties `pinPools` when
--- it loads, a map addon can replace the frame, and the world map is load-on-demand on some
--- builds. So this runs again before every draw, which costs one table compare.
---@param map table
local function InstallPool(map)
    HookCanvasClicks(map)
    local pools = map and map.pinPools
    if pools and pinPool and pools[TEMPLATE] ~= pinPool then
        pools[TEMPLATE] = pinPool
        QEF.Debug("map pins: pool re-registered with the canvas")
    end
end

local function BuildProvider()
    if provider then return provider end

    -- A pool registered under our own template name. AcquirePin looks pools up by template
    -- and only builds one itself when there is none, so seeding it here is what lets a pin
    -- made in Lua take part in the canvas's own acquire and release.
    -- Two pool systems exist, and which one the canvas uses decides whether our frames
    -- get built by our function or by the pool itself. On the newer one a pool made with
    -- CreateFramePool hands back bare frames whatever createFunc says - no mixin, and the
    -- canvas's own next line calls a method they do not have. CreateUnsecuredRegionPoolInstance
    -- is the one that honours it, so it is used wherever it exists.
    if CreateUnsecuredRegionPoolInstance then
        pinPool = CreateUnsecuredRegionPoolInstance(TEMPLATE)
    else
        pinPool = CreateFramePool("FRAME")
    end
    pinPool.parent = WorldMapFrame:GetCanvas()
    pinPool.createFunc = CreatePin
    pinPool.resetFunc = function(_, pin)
        pin:Hide()
        pin:ClearAllPoints()
        pin.data = nil
    end
    -- Both spellings: the pool fields were renamed and either may be the live one.
    pinPool.creationFunc = pinPool.createFunc
    pinPool.resetterFunc = pinPool.resetFunc
    InstallPool(WorldMapFrame)

    provider = CreateFromMixins(MapCanvasDataProviderMixin)

    function provider:RemoveAllData()
        local map = self:GetMap()
        if not map then return end
        -- Releasing a pin calls a method on it, and a pin from a pool that was not ours
        -- has none. This runs inside the canvas's own refresh, so it must not throw.
        local ok, err = pcall(map.RemoveAllPinsByTemplate, map, TEMPLATE)
        if not ok then QEF.Debug("map pins: releasing failed -", err) end
    end

    -- The canvas calls this when the map is shown, before our first draw: the sooner our
    -- pool is in place, the smaller the window in which the canvas builds one of its own
    -- under our name.
    function provider:OnShow()
        InstallPool(self:GetMap())
        StartHoverWatch()
    end

    function provider:OnHide()
        StopHoverWatch()
    end

    function provider:RefreshAllData()
        self:RemoveAllData()
        if not MapPins.Enabled() then return end

        local map = self:GetMap()
        local uiMapId = map and map:GetMapID()
        if not uiMapId then return end

        -- Worked out once per draw rather than once per pin: every pin on one map wants
        -- the same answer.
        MapPins.drawScale = ScaleForMap(uiMapId)
        MapPins.ApplyBlizzardPins()

        -- Every draw, not just OnShow: the canvas is not obliged to call that, and a
        -- watcher that never started is a pin that never answers.
        StartHoverWatch()
        InstallPool(map)

        local ok, pins = pcall(MapPins.PinsFor, uiMapId)
        if not ok then
            -- Caught so a bad pin cannot break the map, but remembered so that the thing
            -- you run to ask why the map is empty can tell you.
            MapPins.lastError = tostring(pins)
            QEF.Debug("map pins failed to build:", pins)
            return
        end
        MapPins.lastError = nil

        -- Acquiring is as able to throw as building was, and this half runs inside the
        -- map's own refresh: an error here takes Blizzard's code down with it, which is a
        -- popup every time the map opens and no clue which pin did it.
        local drawn = 0
        for _, data in ipairs(pins) do
            local placed, err = pcall(map.AcquirePin, map, TEMPLATE, data)
            if placed then
                drawn = drawn + 1
            else
                MapPins.lastError = ("acquiring a %s pin: %s"):format(
                    tostring(data.kind), tostring(err))
                QEF.Debug("map pin failed to acquire:", err)
                break
            end
        end
        MapPins.drawn = drawn
    end

    WorldMapFrame:AddDataProvider(provider)
    return provider
end

--------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------

--- Build the layer if it is not built yet. The world map is load-on-demand on some builds,
--- and a map addon can replace the frame outright, so the provider cannot be registered
--- once at login and assumed: every entry point tries again, and the attempt is cheap
--- because it stops at the first missing piece.
---@return boolean ready
function MapPins.Ensure()
    if provider then return true end
    if not MapPins.Supported() then return false end
    return BuildProvider() ~= nil
end

--- Redraw, if the map is open to see it. The provider does this itself when the map opens
--- or changes zone; this is for when the list behind it changed instead.
function MapPins.Refresh()
    -- Before the early return: ours being switched off is exactly when Blizzard's need
    -- putting back, and that is a moment Ensure can refuse to get past.
    pcall(MapPins.ApplyBlizzardPins)
    if not MapPins.Ensure() then return end
    if not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    -- A reload with the map already open never sees the provider's OnShow, and the map
    -- being open is the only moment hovering matters.
    StartHoverWatch()
    provider:RefreshAllData()
end

local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    -- Quest events are exactly what makes an available quest stop being available.
    wipe(availableCache)
    wipe(beyondCache)
    C_Timer.After(0.3, function()
        refreshQueued = false
        MapPins.Refresh()
    end)
end

MapPins.Queue = QueueRefresh

-- Exposed for the diagnostic. "None of them on this map" has several possible causes, and
-- the only way to tell them apart is to put one step's coordinates through the very same
-- projection the drawing uses and see what comes back.
MapPins.Project = Project

--- Say once, at the moment someone has just built a checklist and would reasonably expect
--- to see it on the map, that the pins are being held back for Questie. Staying quiet about
--- it looks exactly like being broken.
function MapPins.HintIfSuppressed()
    if MapPins.hinted or MapPins.Enabled() then return end
    if QEF.Get("mapPins") ~= "auto" then return end
    MapPins.hinted = true
    QEF.Print("map pins are off while Questie draws its own - "
        .. "|cfff2c75b/qef pins on|r puts this addon's on the map as well")
end

--- How many of our pins the canvas is actually holding.
--- The provider counting what it acquired is not the same as the map having them: this
--- asks the map itself, which is the only side of that exchange worth believing.
---@return number live
---@return string? reason
function MapPins.LiveCount()
    if not provider then return 0, "no provider" end
    local map = provider.GetMap and provider:GetMap()
    if not map or not map.EnumeratePinsByTemplate then return 0, "the map cannot be asked" end

    local live = 0
    for _ in map:EnumeratePinsByTemplate(TEMPLATE) do live = live + 1 end
    return live
end

--- Put one pin on the map at a known place with a texture the client definitely owns.
--- If this appears and the real ones do not, the fault is our art or our sizing; if even
--- this does not appear, nothing we hand the canvas is being drawn at all.
---@return boolean placed
---@return string reason
function MapPins.TestPin()
    if not MapPins.Ensure() then return false, "the layer is not registered with the map" end
    local map = provider:GetMap()
    local uiMapId = map and map.GetMapID and map:GetMapID()
    if not uiMapId then return false, "no map is open" end

    local pin = map:AcquirePin(TEMPLATE, {
        kind = "test", questId = nil, title = "Test pin",
        x = 50, y = 50, test = true,
    })
    if not pin then return false, "AcquirePin returned nothing" end
    return true, ("placed at the middle of uiMap %d, level %s, %dx%d, shown %s"):format(
        uiMapId, tostring(pin.GetFrameLevel and pin:GetFrameLevel()),
        pin:GetWidth() or 0, pin:GetHeight() or 0, tostring(pin:IsShown()))
end

--- Put Blizzard's own quest pins out of the way, or back, to match our own.
---
--- Two addons drawing a turn-in over the same NPC is one too many: the marks sit on top of
--- each other, and which one you end up hovering is down to whichever drew last. The
--- client's `questPOI` setting is the switch for its own, so it is turned off while ours
--- are up - and the value it had first is written down, so turning ours off puts the map
--- back exactly as it was rather than to whatever we assume the default is.
function MapPins.ApplyBlizzardPins()
    local name = "questPOI"
    local current = CVar(name)
    -- A client without the setting is not a client to start guessing on.
    if current == nil then return end

    local hide = MapPins.Enabled() and QEF.Get("hideBlizzardPins") and true or false

    if hide then
        if QEF.Get("questPOIWas") == false then QEF.Set("questPOIWas", current) end
        if current ~= "0" then SetCVarSafely(name, "0") end
        return
    end

    local was = QEF.Get("questPOIWas")
    if was == false then return end
    SetCVarSafely(name, was)
    QEF.Set("questPOIWas", false)
end

--- Why a pin does or does not answer the mouse.
---
--- Two quite different things look identical from the outside - the canvas not routing the
--- mouse to our pins at all, and the mouse arriving somewhere that is not where the pin
--- appears to be - and no amount of reading the code from here settles which. This asks
--- the client.
---@return string[] lines
function MapPins.MouseReport()
    local lines = {}
    local function Line(text) lines[#lines + 1] = text end

    Line(("canvas routes the mouse to our pins: %s"):format(
        MapPins.mouseWorks and "|cff40ff40yes, its own OnEnter has fired|r"
        or "|cffff8040never|r"))
    Line(("hovering is owned by: %s"):format(
        MapPins.handHovering and "this addon, worked out from the cursor" or "the frame system"))
    Line(("  watcher has looked %d times and found a pin under the cursor %d times"):format(
        MapPins.hoverTicks or 0, MapPins.handEnters or 0))
    Line(("  last hover put up: %s"):format(MapPins.lastTooltip or "|cffff8040nothing|r"))
    Line(("  clicks acted on: %d"):format(MapPins.clicks or 0))
    Line(("  the preview last said: %s"):format(
        (QEF.Tooltip and QEF.Tooltip.lastReason) or "nothing, it has not been asked"))
    Line(("  the quest preview itself is: %s"):format(
        QEF.Get("enabled") and "on" or "|cffff8040off, so pins fall back to a plain tooltip|r"))
    Line(("hand-worked hover running: %s"):format(
        hoverWatch and hoverWatch.running and "|cff40ff40yes|r" or "no"))

    local map = provider and provider.GetMap and provider:GetMap()
    local sample
    if map and map.EnumeratePinsByTemplate then
        -- A released pin is still enumerated and has no position, which is what made the
        -- first run of this report describe a pin that was nowhere and invisible.
        for pin in map:EnumeratePinsByTemplate(TEMPLATE) do
            if pin.data and pin:IsVisible() then sample = pin break end
        end
    end

    if not sample then
        Line("|cffff4040no live pin to ask about|r - open the map on a zone with pins first")
        return lines
    end

    Line(("one pin: %dx%d at %s, level %s, strata %s, visible %s"):format(
        sample:GetWidth() or 0, sample:GetHeight() or 0,
        sample:GetLeft() and ("%.0f, %.0f"):format(sample:GetLeft(), sample:GetBottom() or 0)
            or "nowhere",
        tostring(sample.GetFrameLevel and sample:GetFrameLevel()),
        tostring(sample.GetFrameStrata and sample:GetFrameStrata()),
        tostring(sample:IsVisible())))

    local motion = sample.IsMouseMotionEnabled and select(2, pcall(sample.IsMouseMotionEnabled, sample))
    Line(("  mouse: enabled %s, motion %s, OnEnter %s"):format(
        tostring(sample:IsMouseEnabled()),
        sample.IsMouseMotionEnabled and tostring(motion) or "no such method here",
        sample:GetScript("OnEnter") and "set" or "|cffff4040missing|r"))

    local left, right, top, bottom = sample:GetHitRectInsets()
    Line(("  hit area inset by %s, %s, %s, %s"):format(
        tostring(left), tostring(right), tostring(top), tostring(bottom)))

    -- Built here and now for the pin being reported on, so "the preview had nothing to
    -- say" and "the preview was never asked" stop looking the same from the outside.
    if sample.data and sample.data.questId and QEF.Render then
        local ok, rows = pcall(QEF.Render.Build, sample.data.questId, { atGiver = false })
        Line(("  the preview for quest %s builds %s row(s)"):format(
            tostring(sample.data.questId),
            ok and tostring(rows and #rows or 0)
                or ("|cffff4040it errored|r: " .. tostring(rows))))
    end

    local underCursor = PinUnderCursor()
    Line(("  cursor is over one of our pins right now: %s"):format(
        underCursor and "|cff40ff40yes|r" or "no"))

    -- And what the client itself thinks the mouse is on, which names the frame sitting
    -- over our pins if one is.
    local focus
    if GetMouseFoci then
        local list = GetMouseFoci()
        focus = type(list) == "table" and list[1] or nil
    elseif GetMouseFocus then
        focus = GetMouseFocus()
    end
    if focus then
        local name = focus.GetName and focus:GetName()
        Line(("  the client says the mouse is on: %s (%s, level %s)"):format(
            name or "an unnamed frame",
            tostring(focus.GetObjectType and focus:GetObjectType()),
            tostring(focus.GetFrameLevel and focus:GetFrameLevel())))
    else
        Line("  the client says the mouse is on nothing")
    end

    return lines
end

--- What /qef status and /qef pins say about the layer.
--- Nothing on the map has four quite different causes - the client cannot take the pins,
--- the setting says not to, the checklist is empty, or none of it is on the map you are
--- looking at - and a line that says only "no pins" leaves you guessing which.
---@return string
function MapPins.Report()
    local supported, reason = MapPins.Supported()
    if not supported then return "unavailable - " .. (reason or "no reason given") end

    local setting = tostring(QEF.Get("mapPins"))
    local state = setting
    if setting == "auto" then
        state = (Source and Source.questieAvailable)
            and "auto - off, Questie is drawing them"
            or "auto - on, nobody else is"
    end

    if not MapPins.Enabled() then return state end
    if not provider then return state .. ", not registered with the map yet" end
    if MapPins.lastError then
        return state .. ", |cffff4040last draw failed|r - " .. MapPins.lastError
    end

    local listed = Checklist and Checklist.Count() or 0
    local zoneQuests = QEF.Get("mapAvailable") and "on" or "off"

    local map = WorldMapFrame and WorldMapFrame:IsVisible()
        and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if not map then
        return ("%s, %d on the checklist, zone quests %s (open the map to draw)"):format(
            state, listed, zoneQuests)
    end

    -- Counted by where each pin came from: "nothing is drawn" means something different
    -- when the checklist is empty than when the zone simply has no quests left in it.
    local fromList, fromZone = 0, 0
    for _, pin in ipairs(MapPins.PinsFor(map)) do
        if pin.kind == "available" then fromZone = fromZone + 1 else fromList = fromList + 1 end
    end
    if fromList + fromZone == 0 then
        return ("%s, %d on the checklist, zone quests %s, nothing to draw on this map")
            :format(state, listed, zoneQuests)
    end
    return ("%s, %d drawn here - %d from the checklist, %d going spare in the zone"):format(
        state, fromList + fromZone, fromList, fromZone)
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("MapPins", function()
    Art = QEF.Art
    Search = QEF.Search
    Checklist = QEF.Checklist
    Source = QEF.Source
    Guide = QEF.Guide
    Tooltip = QEF.Tooltip

    if not MapPins.Ensure() then
        -- Not an error: the world map may simply not be loaded yet. Ensure runs again from
        -- every refresh, and this catches the moment it arrives.
        local _, reason = MapPins.Supported()
        QEF.Debug("map pins not registered at login:", reason or "no reason given")
        QEF.On("ADDON_LOADED", function(name)
            if QEF.Str(name) and name:find("WorldMap", 1, true) then
                if MapPins.Ensure() then QEF.Debug("map pins registered late") end
            end
        end)
        QEF.On("PLAYER_ENTERING_WORLD", MapPins.Ensure)
    end

    Checklist.Subscribe(QueueRefresh)
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
                             "QUEST_LOG_UPDATE" }) do
        QEF.On(event, QueueRefresh)
    end
end)
