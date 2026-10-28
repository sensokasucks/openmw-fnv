-- Opt-in trace of what the player's input and view are doing, for diagnosing soft locks (the game runs but
-- the controls or the view stop answering). Set OPENMW_FNV_UI_TRACE=1 before starting the game; every line
-- starts with "[ui-trace]". It logs UI mode changes, input actions and key presses with the UI mode and view
-- they happened in, view changes, control switch changes, and every 5 seconds a line with the whole state.

local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local types = require('openmw.types')
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

local function state()
    local pipboy = I.FNVPipBoy and I.FNVPipBoy.isOpen and I.FNVPipBoy.isOpen()
    return ('ui=%s view=%s paused=%s pipboy=%s | %s'):format(uiMode(), viewMode(), tostring(core.isWorldPaused()),
        tostring(pipboy), switchState())
end

local lastView = nil
local lastSwitches = nil
local heartbeat = 0

return {
    engineHandlers = {
        onInputAction = function(id)
            log(('action %s (%s)'):format(actionNames[id] or tostring(id), state()))
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
