-- FO3/FNV combat: resolves the shots the player script fires (scripts/omw/fnvcombat/player.lua).
--
-- The engine (core.obscript.combat) finds what the shot hits, applies the
-- weapon's damage with the target's damage threshold and resistance the way
-- the original game does, and lays the target down when its health runs out.
-- Health is the FNV actor value (see scripts/omw/fnvstats.lua), so damage is
-- saved with the game.
--
-- From the console (luag): I.FNVCombat.kill(obj), I.FNVCombat.health(obj)

local core = require('openmw.core')
local types = require('openmw.types')

local combat = core.obscript and core.obscript.combat
if combat == nil then
    return {}
end
local stats = core.obscript.stats

local function displayName(obj)
    local name = combat.getName(obj)
    if name == '' then
        return obj.recordId
    end
    return name
end

return {
    interfaceName = 'FNVCombat',
    ---
    -- @module FNVCombat
    -- @context global
    interface = {
        version = 0,
        --- Current and full health of an actor.
        health = function(actor)
            return stats.get(actor, 'Health'), stats.getPermanent(actor, 'Health')
        end,
        isDead = function(actor) return combat.isDead(actor) end,
        --- Damage an actor's health (after its armor); attacker may be nil.
        hit = function(target, attacker, damage) combat.hit(target, attacker, damage) end,
        kill = function(target) combat.hit(target, nil, 1e9) end,
    },
    eventHandlers = {
        -- From the player script: { weapon = record id, origin = vec3, direction = vec3 }
        FNVCombat_Fire = function(e)
            local player = e.attacker
            if player == nil or not player:isValid() or e.weapon == nil then return end
            combat.fire(player, e.weapon, e.origin, e.direction)
        end,
        -- From the engine once a shot is resolved
        FNVCombat_Shot = function(e)
            if e.attacker == nil or not e.attacker:isValid() or not types.Player.objectIsInstance(e.attacker) then
                return
            end
            local result = { damage = e.damage, killed = e.killed }
            if e.target ~= nil and e.target:isValid() then
                result.target = e.target
                result.name = displayName(e.target)
                result.health, result.maxHealth = stats.get(e.target, 'Health'), stats.getPermanent(e.target, 'Health')
            end
            e.attacker:sendEvent('FNVCombat_ShotResult', result)
        end,
    },
}
