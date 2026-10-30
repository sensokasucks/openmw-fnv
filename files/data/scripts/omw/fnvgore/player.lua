-- Console commands for testing gore (the engine routes them here, see MWGui::Console::execute):
--   gib [limb]     blows the selected NPC's or creature's limb (or every limb) apart
--   sever [limb]   cuts it off instead
-- limb: head, torso, leftarm, rightarm, leftleg, rightleg (or all). Click the body in the console to select it.
-- Physics (scripts/omw/fnvgore/global.lua, core.obscript.physical):
--   knockdown [force]  knocks the selected actor down away from the player (ragdoll); it gets up on its own
--   stagger [seconds]  makes it reel for a moment

local core = require('openmw.core')
local self = require('openmw.self')
local ui = require('openmw.ui')

local function onConsoleCommand(mode, cmd, selectedObject)
    if mode ~= '' then return end
    local verb, limb = cmd:lower():match('^%s*(%a+)%s*(%a*)')
    if verb == 'knockdown' or verb == 'stagger' then
        if selectedObject == nil then
            ui.printToConsole('No selected object: click an NPC first', ui.CONSOLE_COLOR.Error)
            return
        end
        local amount = cmd:match('^%s*%a+%s+([%d%.]+)')
        core.sendGlobalEvent('FNVPhysical_Console', { player = self.object, target = selectedObject, verb = verb,
            amount = tonumber(amount), from = self.object.position })
        return
    end
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
