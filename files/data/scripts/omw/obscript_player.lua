-- Player-context handler for ObScript commands that need the UI
-- (see openmw_aux/obscript/bindings.lua).

local core = require('openmw.core')
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
                -- No button box yet: list the choices so the player sees what the script offered.
                text = text .. '\n[' .. table.concat(msg.buttons, ' / ') .. ']'
            end
            ui.showMessage(text)
        end,
    },
}
