-- Console commands for testing gore (the engine routes them here, see MWGui::Console::execute):
--   gib [limb]     blows the selected NPC's or creature's limb (or every limb) apart
--   sever [limb]   cuts it off instead
-- limb: head, torso, leftarm, rightarm, leftleg, rightleg (or all). Click the body in the console to select it.

local core = require('openmw.core')
local self = require('openmw.self')
local ui = require('openmw.ui')

local function onConsoleCommand(mode, cmd, selectedObject)
    if mode ~= '' then return end
    local verb, limb = cmd:lower():match('^%s*(%a+)%s*(%a*)')
    if verb ~= 'gib' and verb ~= 'sever' then return end
    if selectedObject == nil then
        ui.printToConsole('No selected object: click an NPC or a body first', ui.CONSOLE_COLOR.Error)
        return
    end
    core.sendGlobalEvent('FNVGore_Console',
        { player = self.object, target = selectedObject, limb = limb, explode = verb == 'gib' })
end

return {
    engineHandlers = { onConsoleCommand = onConsoleCommand },
}
