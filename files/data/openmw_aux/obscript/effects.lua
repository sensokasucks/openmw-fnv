---
-- `openmw_aux.obscript.effects` installs the ObScript actor effect commands
-- (CastImmediateOnSelf, AddSpell, Dispel, IsSpellTarget, HasMagicEffect, ...)
-- for local scripts. The global script scripts/omw/fnveffects/global.lua
-- carries them out and publishes which effects are active, which the queries
-- read. Quest, result and effect scripts get the same commands from the
-- global script directly (through FNVDialogue.bindCommand).
-- @module effects
-- @context local

local core = require('openmw.core')
local storage = require('openmw.storage')

local M = {}

---
-- @param obs the ObScript runtime
-- @param env table with subject() -> this object, resolve(ref) -> object or nil
function M.install(obs, env)
    if core.obscript == nil or core.obscript.effects == nil then return end
    local section = storage.globalSection('FNVEffects')

    for _, name in ipairs({ 'CastImmediateOnSelf', 'Cast', 'AddSpell', 'RemoveSpell', 'Dispel',
        'DispelAllSpells' }) do
        obs.bind(name, function(...)
            local args = { ... }
            local n = select('#', ...)
            for i = 1, n do
                if args[i] == nil then args[i] = 0 end
            end
            core.sendGlobalEvent('FNVEffectsCommand', {
                name = name, self = env.subject(), member = obs._callBase ~= nil, args = args, n = n,
            })
            return 0
        end)
    end

    -- `IsSpellTarget Spell` / `Ref.IsSpellTarget Spell` (and HasMagicEffect)
    local function query(field, lookup)
        return function(...)
            local obj, id
            if obs._callBase ~= nil then
                obj, id = env.resolve(select(1, ...)), select(2, ...)
            else
                obj, id = env.subject(), ...
            end
            local record = type(id) == 'string' and lookup(id)
            local active = obj and section:get(obj.id)
            if not record or not active then return 0 end
            return active[field][record.id] and 1 or 0
        end
    end
    obs.bind('IsSpellTarget', query('spells', core.obscript.effects.getSpell))
    obs.bind('HasMagicEffect', query('effects', core.obscript.effects.getMagicEffect))
end

return M
