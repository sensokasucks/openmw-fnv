-- FO3/FNV actor values (SPECIAL, skills, XP, ...) of the player and ESM4 NPCs.
--
-- The engine reads base values from the NPC records (the player starts from
-- FNV's "Player" record) and keeps the changes ObScript makes with SetAV,
-- ModAV and DamageAV; this script saves those changes with the game and
-- applies the changes local scripts ask for.
--
-- From the Lua console (`luag`):
--   I.FNVStats.get(world.players[1], 'Lockpick')
--   I.FNVStats.setBase(world.players[1], 'Lockpick', 100)

local core = require('openmw.core')

local stats = core.obscript and core.obscript.stats
if stats == nil then
    return {}
end

local ops = {
    setBase = stats._setBase,
    modify = stats._modify,
    damage = stats._damage,
}

local function change(object, op, av, value)
    local fn = ops[op]
    if fn == nil or object == nil or not object:isValid() or stats.actorValue(av) == nil then
        print('[fnvstats] ignored change ' .. tostring(op) .. ' ' .. tostring(av) .. ' on ' .. tostring(object))
        return
    end
    fn(object, av, tonumber(value) or 0)
end

return {
    interfaceName = 'FNVStats',
    ---
    -- @module FNVStats
    -- @context global
    -- @usage require('openmw.interfaces').FNVStats.get(player, 'Science')
    interface = {
        version = 0,
        --- Current value (GetActorValue). `av` is a name such as 'Lockpick' or an actor value number.
        get = function(actor, av) return stats.get(actor, av) end,
        --- Base value (GetBaseActorValue).
        getBase = function(actor, av) return stats.getBase(actor, av) end,
        --- Set the base value (SetActorValue).
        setBase = function(actor, av, value) change(actor, 'setBase', av, value) end,
        --- Add to the value (ModActorValue).
        modify = function(actor, av, delta) change(actor, 'modify', av, delta) end,
        --- Damage the value; a negative amount restores it (DamageActorValue / RestoreActorValue).
        damage = function(actor, av, amount) change(actor, 'damage', av, amount) end,
        --- Apply op 'setBase', 'modify' or 'damage'.
        change = change,
        getLevel = function(actor) return stats.getLevel(actor) end,
        --- The player's tag skills, as actor value numbers.
        getTagSkills = function() return stats.getTagSkills() end,
        --- Replace the player's tag skills (a list of names such as 'Guns' or numbers).
        setTagSkills = function(skills) stats._setTagSkills(skills) end,
    },
    engineHandlers = {
        onInit = function()
            stats._setChanges({})
            stats._setTagSkills({})
        end,
        onSave = function()
            return { changes = stats._getChanges(), tagSkills = stats.getTagSkills() }
        end,
        onLoad = function(data)
            stats._setChanges(data and data.changes or {})
            stats._setTagSkills(data and data.tagSkills or {})
        end,
    },
    eventHandlers = {
        -- from local ObScript (openmw_aux.obscript.bindings)
        FNVStatsChange = function(data)
            change(data.object, data.op, data.av, data.value)
        end,
        -- from the character creation menus (scripts/omw/fnvchargen/player.lua)
        FNVChargenSetName = function(data)
            local name = tostring(data.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if name ~= '' then stats._setPlayerName(name) end
        end,
        FNVChargenSetSex = function(data)
            stats._setPlayerSex(data.female == true)
        end,
        FNVChargenSetBase = function(data)
            for av, value in pairs(data.values or {}) do
                change(data.player, 'setBase', av, value)
            end
        end,
        FNVChargenSetTagSkills = function(data)
            stats._setTagSkills(data.skills or {})
        end,
    },
}
