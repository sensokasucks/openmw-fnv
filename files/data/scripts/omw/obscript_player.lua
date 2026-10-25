-- Player-context handler for ObScript commands that need the UI
-- (see openmw_aux/obscript/bindings.lua).

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local ui = require('openmw.ui')

-- Substitute `%.0f`-style format specs in a MESG text with the ShowMessage arguments.
local function formatMessage(text, args)
    local i = 0
    return (text:gsub('%%([%-+ #0-9.]*[a-zA-Z])', function(spec)
        i = i + 1
        local v = args[i]
        if v == nil then return '%' .. spec end
        local ok, out = pcall(string.format, '%' .. spec, v)
        if ok then return out end
        return tostring(v)
    end))
end

return {
    eventHandlers = {
        ObScriptShowMessage = function(data)
            local msg = core.obscript.getMessage(data.editorId)
            if msg == nil then
                print('[obscript] ShowMessage: unknown message editor id: ' .. tostring(data.editorId))
                return
            end
            local text = formatMessage(msg.text or '', data.args or {})
            if msg.title and msg.title ~= '' then
                text = msg.title .. '\n' .. text
            end
            if #msg.buttons > 0 then
                -- a blocking box; GetButtonPressed reads the answer
                core.obscript.showMessageBox(text, msg.buttons)
            else
                ui.showMessage(text)
            end
        end,
        -- A line spoken outside the dialogue window (SayTo, Say).
        FNVSubtitle = function(data)
            ui.showMessage(tostring(data.speaker) .. ': ' .. tostring(data.text))
        end,
        -- Short notices such as a new quest objective.
        ObScriptNotify = function(data)
            ui.showMessage(tostring(data.text))
        end,
        -- DisablePlayerControls / EnablePlayerControls.
        ObScriptPlayerControls = function(data)
            local f = data.flags
            local switches = {
                { f.movement, types.Player.CONTROL_SWITCH.Controls },
                { f.movement, types.Player.CONTROL_SWITCH.Jumping },
                { f.fighting, types.Player.CONTROL_SWITCH.Fighting },
                { f.fighting, types.Player.CONTROL_SWITCH.Magic },
                { f.pov, types.Player.CONTROL_SWITCH.ViewMode },
                { f.looking, types.Player.CONTROL_SWITCH.Looking },
            }
            for _, s in ipairs(switches) do
                if s[1] then
                    types.Player.setControlSwitch(self, s[2], data.enable)
                end
            end
        end,
    },
}
