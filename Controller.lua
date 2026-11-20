-- Controller.lua
--
-- A gamepad-navigable layout: focus you can move with the d-pad, a visible focus bracket,
-- a button hint bar, and roomier rows.
--
-- Three things make a mouse interface unusable on a pad, and all three are handled here:
--
--   * nothing can be reached without a cursor, so every control a view cares about is
--     registered as a focus target and reached directionally;
--   * information hidden behind hover is invisible, so focusing a target shows the same
--     tooltip hovering it would;
--   * the buttons are unlabelled, so the bar along the bottom says what each one does
--     *here*, and changes as focus moves.
--
-- Input is taken two ways. Gamepad buttons arrive through OnGamePadButtonDown where the
-- client has it; the same actions are also on the arrow keys, Enter and Escape. The keyboard
-- half is only ever enabled in controller mode, because the arrow keys are turn-left and
-- turn-right by default and silently eating them would be hostile.
--
-- Nothing here is required for the addon to work. With no pad and the setting on auto, none
-- of it switches on.

local ADDON, QEF = ...

local Controller = {}
QEF.Controller = Controller

local W, theme

--- True when the roomier layout and the hint bar are in use.
Controller.active = false
Controller.applyHandlers = {}

local surface          -- the current screen's focus model
local focusGroup, focusIndex
local ring, hintBar, hintText
local host             -- the frame input is read from

--------------------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------------------

--- Whether this client can report gamepad buttons to an addon at all.
---@return boolean
function Controller.Supported()
    local frame = QEF.frame
    return type(frame) == "table" and type(frame.EnableGamePadButton) == "function"
end

--- Whether a pad is connected *and* the client is set up to deliver its buttons.
---
--- Deliberately strict, and every step has to say yes. Three things could each look like a
--- pad without one being usable, and all three were treated as evidence before:
---
---   * the client can refuse to read pads at all (the GamePadEnable setting), in which case
---     a pad plugged in for some other game delivers nothing here;
---   * a device id of 0 is a number, and "is this a number" is not the same question as
---     "is there a device";
---   * a build that cannot report buttons to an addon at all would give a layout you could
---     see but not drive.
---
--- The reason is returned alongside so /qef controller can say what it went on.
---@return boolean detected
---@return string reason
function Controller.Detected()
    if not Controller.Supported() then
        return false, "this client cannot report gamepad buttons to an addon"
    end
    if type(C_GamePad) ~= "table" then
        return false, "this client has no gamepad API"
    end

    -- Is the client reading pads at all?
    if type(C_GamePad.IsEnabled) == "function" then
        if QEF.Try(C_GamePad.IsEnabled) ~= true then
            return false, "gamepad input is switched off in the game's settings"
        end
    elseif type(GetCVarBool) == "function" then
        if not QEF.Try(GetCVarBool, "GamePadEnable") then
            return false, "gamepad input is switched off in the game's settings"
        end
    end

    -- Is there a device? A list is the clearest answer when the client offers one.
    local devices = QEF.Tbl(QEF.Try(C_GamePad.GetAllDeviceIDs))
    if devices then
        if #devices > 0 then
            return true, ("%d pad%s connected"):format(#devices, #devices == 1 and "" or "s")
        end
        return false, "no pad connected"
    end

    -- Otherwise ask after the active device, and confirm it by reading it back rather than
    -- trusting that an id was returned.
    local active = QEF.Num(QEF.Try(C_GamePad.GetActiveDeviceID))
    if not active then return false, "no pad connected" end
    if type(C_GamePad.GetDeviceMappedState) == "function" then
        if QEF.Tbl(QEF.Try(C_GamePad.GetDeviceMappedState, active)) then
            return true, "a pad is active"
        end
        return false, "no pad connected"
    end
    -- No way to confirm, so an id of 0 is read as "none" rather than as device zero.
    if active > 0 then return true, "a pad is active" end
    return false, "no pad connected"
end

--- Resolve the setting against what is plugged in. "auto" turns the layout on only when a
--- pad is there, so a keyboard player never meets it.
---@return boolean active
function Controller.Resolve()
    local mode = QEF.Get("controller")
    local present, reason = Controller.Detected()
    Controller.padPresent = present
    Controller.detectReason = reason

    local wanted
    if mode == "on" then
        wanted = true
    elseif mode == "off" then
        wanted = false
    else
        wanted = present
    end

    if wanted ~= Controller.active then
        Controller.active = wanted
        if not wanted then Controller.Blur() end
    end
    return Controller.active
end

--- Views register here to resize themselves when the layout turns on or off.
---@param fn fun(active: boolean)
function Controller.OnApplied(fn)
    if type(fn) == "function" then
        Controller.applyHandlers[#Controller.applyHandlers + 1] = fn
    end
end

--------------------------------------------------------------------------------------------
-- Button labels
--------------------------------------------------------------------------------------------

-- Face buttons are named by position, not by letter, because the letter depends on the pad
-- in the player's hands. The setting picks which family of names to print.
local LABELS = {
    xbox = { accept = "A", back = "B", alt1 = "X", alt2 = "Y",
             left = "LB", right = "RB", move = "D-pad" },
    playstation = { accept = "Cross", back = "Circle", alt1 = "Square", alt2 = "Triangle",
                    left = "L1", right = "R1", move = "D-pad" },
    keys = { accept = "Click", back = "Esc", alt1 = "W", alt2 = "L",
             left = "PgUp", right = "PgDn", move = "Arrows" },
}

---@return table labels
function Controller.Labels()
    -- Forced on with no pad attached, the hints name keys rather than face buttons: telling
    -- someone to press A when they are holding a keyboard is worse than no hint at all.
    if not Controller.active or not Controller.padPresent then return LABELS.keys end
    return LABELS[QEF.Get("controllerLabels")] or LABELS.xbox
end

--------------------------------------------------------------------------------------------
-- Input mapping
--------------------------------------------------------------------------------------------

-- Gamepad button names and the keyboard equivalents, mapped onto one set of actions.
local ACTION = {
    PADDUP = "up", PADDDOWN = "down", PADDLEFT = "left", PADDRIGHT = "right",
    PADLSTICKUP = "up", PADLSTICKDOWN = "down",
    PADLSTICKLEFT = "left", PADLSTICKRIGHT = "right",
    PAD1 = "accept", PAD2 = "back", PAD3 = "alt1", PAD4 = "alt2",
    PADLSHOULDER = "prevView", PADRSHOULDER = "nextView",

    UP = "up", DOWN = "down", LEFT = "left", RIGHT = "right",
    ESCAPE = "back",
    W = "alt1", L = "alt2",
    PAGEUP = "prevView", PAGEDOWN = "nextView",
}

-- Enter is deliberately not in that table. It was the keyboard's accept, which meant that
-- with the layout on and a window open, pressing Enter to talk did nothing whatsoever: the
-- window marked the key handled and stopped it reaching the game. Enter belongs to chat.
-- A pad's A button still accepts, and the mouse was never not an option.

-- Keys the keyboard half may take. Anything else is passed straight through to the game,
-- so the window never swallows a keybind it has no use for.
local KEYBOARD_ACTIONS = {
    up = true, down = true, left = true, right = true,
    accept = true, back = true, prevView = true, nextView = true,
}

--------------------------------------------------------------------------------------------
-- The focus model
--------------------------------------------------------------------------------------------
--
-- A surface is a few named groups, each a row or a column of targets, wired to each other by
-- direction. Explicit wiring rather than a geometric search: there are three groups on the
-- one screen that needs this, and a wrong guess about what is "to the left" is worse than a
-- table saying so.
--
--   group = {
--     axis   = "vertical" | "horizontal",
--     items  = { target, ... },     -- a target is { frame, activate, hint, tooltip }
--     up/down/left/right = "<other group key>",
--   }

local function CurrentGroup()
    return surface and surface.groups[focusGroup] or nil
end

local function CurrentTarget()
    local group = CurrentGroup()
    if not group then return nil end
    if group.custom then return group end
    return group.items and group.items[focusIndex] or nil
end

--- A target can name its frame outright or work it out when asked, which is how the list
--- puts the ring around the selected row rather than around the whole list.
local function TargetFrame(target)
    if not target then return nil end
    if target.GetFrame then return target.GetFrame() end
    return target.frame
end

--- The frame focus is on, for a view that needs to behave differently depending.
---@return table?
function Controller.FocusedFrame()
    return TargetFrame(CurrentTarget())
end

--- A target is skipped when its frame is gone or hidden, so a hidden Waypoint button is not
--- a dead stop in the middle of a column.
local function Usable(target)
    if not target then return false end
    local frame = target.frame
    if not frame then return false end
    if frame.IsShown and not frame:IsShown() then return false end
    if frame.IsEnabled and frame:IsEnabled() == false then return false end
    return true
end

local function ShowHint()
    if not hintBar or not Controller.active then return end
    local labels = Controller.Labels()
    local target = CurrentTarget()
    local parts = {}

    local accent = W.Hex(theme.accent)
    local function add(button, text)
        if not text then return end
        parts[#parts + 1] = accent .. button .. "|r " .. text
    end

    -- The back hint changes with the history, so a surface may give a function for it.
    local backHint = surface and surface.backHint
    if type(backHint) == "function" then backHint = backHint() end

    add(labels.move, "Move")
    add(labels.accept, (target and target.hint) or "Select")
    add(labels.back, backHint or "Close")
    if surface and surface.alt1 then add(labels.alt1, surface.alt1.hint) end
    if surface and surface.alt2 then add(labels.alt2, surface.alt2.hint) end
    add(labels.left .. "/" .. labels.right, "Switch view")

    hintText:SetText(table.concat(parts, "    "))
end

local function ShowTooltipFor(target)
    if not target then return end
    local frame = TargetFrame(target)
    if target.tooltip then
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:AddLine(target.tooltip, 1, 1, 1)
        GameTooltip:Show()
    elseif frame and frame:GetScript("OnEnter") then
        -- Reuse whatever the mouse would have shown, so focusing explains as much as
        -- hovering does.
        frame:GetScript("OnEnter")(frame)
    end
end

--- Put focus on a group and index, with the ring and the hints following it.
---@param groupKey string
---@param index number?
function Controller.Focus(groupKey, index)
    if not surface then return end
    local group = surface.groups[groupKey]
    if not group then return end

    GameTooltip:Hide()
    focusGroup = groupKey
    focusIndex = index or group.lastIndex or 1

    if group.custom then
        if ring then ring:Attach(TargetFrame(group), group.inset) end
    else
        -- Land on something usable rather than on a hidden button.
        local items = group.items or {}
        if not Usable(items[focusIndex]) then
            -- Search outwards from where focus was asked for, so a hidden Waypoint button
            -- is stepped over rather than being a dead stop in the middle of a column.
            local found
            for step = 0, #items do
                if Usable(items[focusIndex + step]) then
                    found = focusIndex + step
                    break
                end
                if Usable(items[focusIndex - step]) then
                    found = focusIndex - step
                    break
                end
            end
            focusIndex = found or 1
        end
        group.lastIndex = focusIndex
        local target = items[focusIndex]
        if ring then ring:Attach(TargetFrame(target), target and target.inset) end
        ShowTooltipFor(target)
    end

    if group.OnFocus then group.OnFocus(focusIndex) end
    ShowHint()
end

function Controller.Blur()
    GameTooltip:Hide()
    if ring then ring:Attach(nil) end
    focusGroup, focusIndex = nil, nil
end

--------------------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------------------

local function StepWithin(group, delta)
    local items = group.items or {}
    local index = focusIndex
    for _ = 1, #items do
        index = index + delta
        if index < 1 or index > #items then return false end
        if Usable(items[index]) then
            Controller.Focus(focusGroup, index)
            return true
        end
    end
    return false
end

local function LeaveTo(direction)
    local group = CurrentGroup()
    local nextKey = group and group[direction]
    if not nextKey or not surface.groups[nextKey] then return false end
    Controller.Focus(nextKey)
    return true
end

--- Move focus. A group whose contents scroll gets first refusal on the movement and only
--- hands it on when it has nothing left to scroll, which is what makes a long list feel
--- like one continuous surface rather than a trap.
---@param action string
---@return boolean handled
function Controller.Move(action)
    local group = CurrentGroup()
    if not group then
        if surface then Controller.Focus(surface.start or surface.order[1]) end
        return true
    end

    if group.OnDirection and group.OnDirection(action) then
        ShowHint()
        return true
    end

    local horizontal = action == "left" or action == "right"
    local along = (group.axis == "horizontal") == horizontal

    if along then
        local delta = (action == "down" or action == "right") and 1 or -1
        if StepWithin(group, delta) then return true end
    end
    return LeaveTo(action)
end

--------------------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------------------

local function Activate()
    local group = CurrentGroup()
    if group and group.OnActivate then
        group.OnActivate()
        return true
    end
    local target = CurrentTarget()
    if not target then return false end
    if target.activate then
        target.activate()
        return true
    end
    local frame = target.frame
    if frame and frame.Click then
        frame:Click()
        return true
    end
    return false
end

---@param action string
---@return boolean handled
function Controller.Do(action)
    if not surface then return false end

    if action == "up" or action == "down" or action == "left" or action == "right" then
        return Controller.Move(action)
    end
    if action == "accept" then
        local handled = Activate()
        ShowHint()
        return handled
    end
    if action == "back" then
        if surface.back then
            surface.back()
            ShowHint()
            return true
        end
        return false
    end
    if action == "alt1" and surface.alt1 then
        surface.alt1.run()
        return true
    end
    if action == "alt2" and surface.alt2 then
        surface.alt2.run()
        return true
    end
    if action == "prevView" or action == "nextView" then
        if QEF.Window and QEF.Window.CycleView then
            QEF.Window.CycleView(action == "nextView" and 1 or -1)
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------------------
-- Surfaces
--------------------------------------------------------------------------------------------

--- Hand the controller layer a screen's focus model. Views call this when they are shown.
---@param spec table
function Controller.SetSurface(spec)
    surface = spec
    focusGroup, focusIndex = nil, nil
    if not spec then
        Controller.Blur()
        return
    end
    if Controller.active then
        Controller.Focus(spec.start or spec.order[1])
    end
end

function Controller.ClearSurface()
    Controller.SetSurface(nil)
end

--- Re-apply the ring and hints after a view rebuilt its contents.
function Controller.Refresh()
    if not Controller.active or not surface or not focusGroup then return end
    Controller.Focus(focusGroup, focusIndex)
end

--------------------------------------------------------------------------------------------
-- Input plumbing
--------------------------------------------------------------------------------------------

--- Attach the input handlers, the focus ring and the hint bar to the main window.
---@param window table
---@param hintParent table
function Controller.Attach(window, hintParent)
    if host then return end
    host = window

    ring = W.FocusRing(window)

    hintBar = CreateFrame("Frame", nil, hintParent or window)
    hintBar:SetHeight(30)
    hintBar:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 0, 0)
    hintBar:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
    W.Fill(hintBar, theme.raised)
    W.Hairline(hintBar, "TOP", theme.line)
    hintBar:Hide()
    Controller.hintBar = hintBar

    hintText = W.Text(hintBar, W.size.small, theme.dim)
    hintText:SetPoint("LEFT", hintBar, "LEFT", 20, 0)
    hintText:SetPoint("RIGHT", hintBar, "RIGHT", -20, 0)
    hintText:SetJustifyH("LEFT")
    hintText:SetWordWrap(false)

    -- Gamepad input, where the client has it. This path never touches the keyboard, so it
    -- is safe to leave on whether or not the roomier layout is in use.
    if Controller.Supported() then
        pcall(window.EnableGamePadButton, window, true)
        -- Through pcall: a client that has the enable call but not the script type would
        -- otherwise take the whole window down on the way up.
        pcall(window.SetScript, window, "OnGamePadButtonDown", function(self, button)
            if not Controller.active then return end
            local action = ACTION[button]
            if action then Controller.Do(action) end
        end)
    end

    -- Keyboard equivalents, only while the controller layout is on: the arrow keys are
    -- turn-left and turn-right, and taking them from someone who did not ask would be rude.
    window:SetScript("OnKeyDown", function(self, key)
        -- Someone typing in a search box owns the keyboard: arrows move their cursor, not
        -- the focus ring, and nothing here gets a say until they are finished.
        if GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() then
            self:SetPropagateKeyboardInput(true)
            return
        end

        local action = Controller.active and ACTION[key] or nil
        local handled = false
        if action and KEYBOARD_ACTIONS[action] then
            handled = Controller.Do(action)
        end
        self:SetPropagateKeyboardInput(not handled)
    end)

    window:HookScript("OnShow", function()
        Controller.Resolve()
        Controller.Apply()
        if Controller.active and surface and not focusGroup then
            Controller.Focus(surface.start or surface.order[1])
        end
    end)
    window:HookScript("OnHide", function()
        GameTooltip:Hide()
        Controller.Blur()
    end)
end

--- Give a dialog the two buttons a dialog needs. Separate from the main window's input,
--- because a modal is its own surface: there is nothing to navigate, only to dismiss.
---@param dialog table
---@param onAccept function?
function Controller.AttachDialog(dialog, onAccept)
    if not Controller.Supported() then return end
    pcall(dialog.EnableGamePadButton, dialog, true)
    pcall(dialog.SetScript, dialog, "OnGamePadButtonDown", function(self, button)
        local action = ACTION[button]
        if action == "back" then
            self:Hide()
        elseif action == "accept" then
            if onAccept then onAccept() else self:Hide() end
        end
    end)
end

--- Turn the layout on or off on the frames that care.
function Controller.Apply()
    if not host then return end
    local active = Controller.active

    host:EnableKeyboard(active)
    if active then host:SetPropagateKeyboardInput(true) end
    if hintBar then hintBar:SetShown(active) end
    if not active and ring then ring:Attach(nil) end

    if QEF.Window and QEF.Window.SetHintBarShown then
        QEF.Window.SetHintBarShown(active)
    end
    for _, handler in ipairs(Controller.applyHandlers) do
        pcall(handler, active)
    end
    if active then ShowHint() end
end

--------------------------------------------------------------------------------------------

QEF.RegisterInit("Controller", function()
    W = QEF.Widgets
    theme = W.theme

    Controller.Resolve()

    -- A pad plugged in or unplugged mid-session changes the answer under "auto", and so
    -- does switching the game's own gamepad support on or off.
    for _, event in ipairs({ "GAME_PAD_CONNECTED", "GAME_PAD_DISCONNECTED" }) do
        QEF.On(event, function()
            Controller.Resolve()
            Controller.Apply()
        end)
    end

    QEF.On("CVAR_UPDATE", function(name)
        local cvar = QEF.Str(name)
        if cvar and cvar:lower():find("gamepad", 1, true) then
            Controller.Resolve()
            Controller.Apply()
        end
    end)
end)
