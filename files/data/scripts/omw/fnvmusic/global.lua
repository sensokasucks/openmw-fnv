-- What the FNV music of each player needs from the world: whether something
-- fights them (battle music), and PlayMusic from scripts. The music itself
-- plays in scripts/omw/fnvmusic/player.lua.

local core = require('openmw.core')
local world = require('openmw.world')
local I = require('openmw.interfaces')

if core.obscript == nil or core.obscript.radio == nil
    or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local CHECK_INTERVAL = 1.0

local inCombat = {} -- player id -> bool, as last sent
local nextCheck = 0

local function foughtBy(player)
    local combat = I.FNVCombat
    if combat == nil or combat.getTarget == nil then return false end
    -- ESM4 actors aren't in world.activeActors; the combat script knows who fights whom
    if combat.isTargeted ~= nil then return combat.isTargeted(player) end
    for _, actor in ipairs(world.activeActors) do
        if actor ~= player and combat.getTarget(actor) == player then
            return true
        end
    end
    return false
end

local bound = false
local function bindCommands()
    if bound or I.FNVDialogue == nil then return end
    bound = true
    -- PlayMusic <music type>: a stinger or a piece over the location music (1NoMusic: quiet)
    I.FNVDialogue.bindCommand('PlayMusic', function(_, music)
        if type(music) ~= 'string' then return 0 end
        for _, player in ipairs(world.players) do
            player:sendEvent('FNVMusicPlay', { music = music })
        end
        return 0
    end)
end
bindCommands()

return {
    engineHandlers = {
        onUpdate = function(dt)
            bindCommands()
            nextCheck = nextCheck - dt
            if nextCheck > 0 then return end
            nextCheck = CHECK_INTERVAL
            for _, player in ipairs(world.players) do
                local fighting = foughtBy(player)
                if fighting ~= (inCombat[player.id] == true) then
                    inCombat[player.id] = fighting
                    player:sendEvent('FNVMusicCombat', { inCombat = fighting })
                end
            end
        end,
        onLoad = function()
            inCombat = {}
            bindCommands()
        end,
    },
}
