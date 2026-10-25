---
-- `openmw_aux.obscript.stats` installs the ObScript actor value commands
-- (GetAV, SetAV, ModAV, GetLevel, GetIsSex, ...) on top of `core.obscript.stats`.
-- Used by local ObScript (openmw_aux.obscript.bindings) and dialogue result
-- scripts (scripts/omw/fnvdialogue/global.lua), which differ in who the
-- implicit subject is and how a change reaches the global stats script.
-- @module stats

local core = require('openmw.core')

local M = {}

---
-- @param obs the ObScript runtime
-- @param env table with
--   subject() -> the object a command without a reference acts on,
--   resolve(ref) -> object for a reference (editor id string or object), or nil,
--   change(object, op, av, value) applies 'setBase', 'modify' or 'damage'.
function M.install(obs, env)
    local stats = core.obscript and core.obscript.stats
    if stats == nil then return end

    local warned = {}
    local function warnOnce(key, msg)
        if warned[key] then return end
        warned[key] = true
        print('[obscript] ' .. msg)
    end

    -- A free call arrives as (av, ...), a member call as (ref, av, ...).
    local function split(a, b, c)
        if type(a) == 'string' and stats.actorValue(a) ~= nil and type(b) ~= 'string' then
            return env.subject(), a, b
        end
        if type(a) == 'number' and type(b) ~= 'string' then
            return env.subject(), a, b
        end
        local obj = env.resolve(a)
        if obj == nil then
            warnOnce('ref:' .. tostring(a), 'actor value command on an unknown or unloaded reference: ' .. tostring(a))
        end
        return obj, b, c
    end

    local function actorValue(av, command)
        local index = av ~= nil and stats.actorValue(av)
        if not index then
            warnOnce('av:' .. tostring(av), command .. ': unknown actor value ' .. tostring(av))
        end
        return index
    end

    local function getter(command, fn)
        return function(...)
            local obj, av = split(...)
            local index = actorValue(av, command)
            if obj == nil or not index then return 0 end
            return fn(obj, index)
        end
    end

    local function setter(command, op, sign)
        return function(...)
            local obj, av, value = split(...)
            local index = actorValue(av, command)
            if obj == nil or not index then return 0 end
            env.change(obj, op, index, (tonumber(value) or 0) * sign)
            return 0
        end
    end

    local get = getter('GetActorValue', stats.get)
    obs.bind('GetActorValue', get)
    obs.bind('GetAV', get)
    local getBase = getter('GetBaseActorValue', stats.getBase)
    obs.bind('GetBaseActorValue', getBase)
    obs.bind('GetBaseAV', getBase)
    obs.bind('GetPermanentActorValue', getter('GetPermanentActorValue', stats.getPermanent))

    local set = setter('SetActorValue', 'setBase', 1)
    obs.bind('SetActorValue', set)
    obs.bind('SetAV', set)
    obs.bind('ForceActorValue', set)
    obs.bind('ForceAV', set)
    local mod = setter('ModActorValue', 'modify', 1)
    obs.bind('ModActorValue', mod)
    obs.bind('ModAV', mod)
    local damage = setter('DamageActorValue', 'damage', 1)
    obs.bind('DamageActorValue', damage)
    obs.bind('DamageAV', damage)
    local restore = setter('RestoreActorValue', 'damage', -1)
    obs.bind('RestoreActorValue', restore)
    obs.bind('RestoreAV', restore)

    -- `GetLevel` / `Ref.GetLevel`
    obs.bind('GetLevel', function(ref)
        local obj = ref == nil and env.subject() or env.resolve(ref)
        if obj == nil then return 0 end
        return stats.getLevel(obj)
    end)

    -- `GetIsSex Male|Female` / `Ref.GetIsSex Female`
    local function isSex(obj, sex)
        if obj == nil or type(sex) ~= 'string' then return 0 end
        local female = stats.isFemale(obj)
        return ((sex:lower() == 'female') == female) and 1 or 0
    end
    obs.bind('GetIsSex', function(a, b)
        if b == nil then return isSex(env.subject(), a) end
        return isSex(env.resolve(a), b)
    end)
    obs.bind('GetPCIsSex', function(a, b)
        return isSex(env.resolve('player'), b or a)
    end)
end

return M
