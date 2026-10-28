-- Opt-in trace of what the player's input and view are doing, for diagnosing soft locks (the game runs but
-- the controls or the view stop answering) and things that don't answer to activation. Set
-- OPENMW_FNV_UI_TRACE=1 before starting the game; every line starts with "[ui-trace]". It logs UI mode
-- changes, input actions and key presses with the UI mode and view they happened in, what is under the
-- crosshair when Activate is pressed (with a door's destination and lock state), cell changes, view changes,
-- control switch changes, and every 5 seconds a line with the whole state. The world side
-- (scripts/omw/fnvaitrace.lua) logs what the actors around the player are doing.

local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')

if not (core.obscript and core.obscript.uiTraceEnabled) then
    return {}
end

local actionNames = {}
for name, id in pairs(input.ACTION) do actionNames[id] = name end
local modeNames = {}
for name, id in pairs(camera.MODE) do modeNames[id] = name end
local switches = {}
for name, id in pairs(types.Player.CONTROL_SWITCH) do switches[#switches + 1] = { name = name, id = id } end
table.sort(switches, function(a, b) return a.name < b.name end)

local function log(text)
    print('[ui-trace] ' .. text)
end

local function uiMode()
    local ok, mode = pcall(function() return I.UI and I.UI.getMode() end)
    return ok and tostring(mode) or '?'
end

local function viewMode()
    return modeNames[camera.getMode()] or tostring(camera.getMode())
end

local function switchState()
    local parts = {}
    for _, s in ipairs(switches) do
        local ok, on = pcall(types.Player.getControlSwitch, self, s.id)
        parts[#parts + 1] = s.name .. '=' .. (ok and (on and '1' or '0') or '?')
    end
    return table.concat(parts, ' ')
end

local function cellName(cell)
    if cell == nil then return 'nil' end
    return (cell.name ~= '' and cell.name or cell.id) .. (cell.isExterior and (' (%d,%d)'):format(cell.gridX, cell.gridY) or '')
end

local function state()
    local pipboy = I.FNVPipBoy and I.FNVPipBoy.isOpen and I.FNVPipBoy.isOpen()
    return ('ui=%s view=%s paused=%s pipboy=%s cell=%s | %s'):format(uiMode(), viewMode(), tostring(core.isWorldPaused()),
        tostring(pipboy), cellName(self.cell), switchState())
end

local function typeName(obj)
    for name, t in pairs(types) do
        if type(t) == 'table' and t == obj.type then return name end
    end
    return '?'
end

-- What the crosshair is on, as the activation ray sees it (up to 400 units)
local function lookTarget()
    local from = camera.getPosition()
    local direction = camera.viewportToWorldVector(util.vector2(0.5, 0.5))
    local ok, result = pcall(nearby.castRay, from, from + direction * 400, { ignore = self })
    if not ok then return 'ray failed: ' .. tostring(result) end
    if not result.hit then return 'nothing within 400' end
    local distance = (result.hitPos - from):length()
    local obj = result.hitObject
    if obj == nil then return ('world geometry at %.0f'):format(distance) end
    local extra = ''
    if types.ESM4Door and types.ESM4Door.objectIsInstance(obj) then
        local okT, teleport = pcall(types.ESM4Door.isTeleport, obj)
        local okC, cell = pcall(types.ESM4Door.destCell, obj)
        extra = (' door teleport=%s dest=%s'):format(tostring(okT and teleport),
            okC and (cell and cellName(cell) or 'none') or ('error: ' .. tostring(cell)))
    end
    pcall(function()
        if types.Lockable.objectIsInstance(obj) then extra = extra .. ' locked=' .. tostring(types.Lockable.isLocked(obj)) end
    end)
    pcall(function()
        if I.FNVCombat and I.FNVCombat.isDead and (types.ESM4NPC.objectIsInstance(obj) or types.ESM4Creature.objectIsInstance(obj)) then
            extra = extra .. ' dead=' .. tostring(I.FNVCombat.isDead(obj))
        end
    end)
    return ('%s %s (%s) at %.0f%s'):format(typeName(obj), obj.recordId, tostring(obj.id), distance, extra)
end

local lastView = nil
local lastSwitches = nil
local lastCell = nil
local heartbeat = 0

return {
    engineHandlers = {
        onInputAction = function(id)
            local name = actionNames[id] or tostring(id)
            if name == 'Activate' then
                log(('action Activate on %s (%s)'):format(lookTarget(), state()))
            else
                log(('action %s (%s)'):format(name, state()))
            end
        end,
        onKeyPress = function(key)
            log(('key down %s/%s (%s)'):format(tostring(key.code), tostring(key.symbol), state()))
        end,
        onFrame = function(dt)
            local view = viewMode()
            if view ~= lastView then
                log(('view %s -> %s (ui=%s)'):format(tostring(lastView), view, uiMode()))
                lastView = view
            end
            local cell = self.cell
            if cell ~= lastCell then
                log(('cell %s -> %s at %s'):format(cellName(lastCell), cellName(cell), tostring(self.position)))
                lastCell = cell
            end
            local sw = switchState()
            if sw ~= lastSwitches then
                log('control switches ' .. sw)
                lastSwitches = sw
            end
            heartbeat = heartbeat - core.getRealFrameDuration()
            if heartbeat <= 0 then
                heartbeat = 5
                log('state ' .. state())
            end
        end,
    },
    eventHandlers = {
        UiModeChanged = function(data)
            log(('ui mode %s -> %s (arg %s, view=%s)'):format(tostring(data.oldMode), tostring(data.newMode),
                tostring(data.arg), viewMode()))
        end,
    },
}
