---
-- `openmw_aux.obscript.character` installs the ObScript commands for XP,
-- leveling, karma, reputation and perks (RewardXP, RewardKarma,
-- AddReputation, GetReputationThreshold, HasPerk, ...). The global script
-- scripts/omw/fnvcharacter/global.lua owns the state; local ObScript
-- (openmw_aux.obscript.bindings) reads what it publishes and sends it
-- events, dialogue and quest scripts (scripts/omw/fnvdialogue/global.lua)
-- call it directly.
-- @module character

local core = require('openmw.core')

local rules = require('scripts.omw.fnvcharacter.rules')

local M = {}

local function gmst(name, fallback)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    if type(value) == 'boolean' then return value and 1 or 0 end
    if type(value) ~= 'number' then return fallback end
    return value
end
M.gmst = gmst

---
-- Records by lowercase editor id and by form id: { reputations = {...}, perks = {...}, perkList = {...} }.
-- Loaded once; the perk list (with its CTDA requirements) is only built when asked for.
local records = nil
function M.records()
    if records ~= nil then return records end
    records = { reputations = {}, perks = {}, perkList = {} }
    local stats = core.obscript and core.obscript.stats
    if stats == nil or stats.reputations == nil then return records end
    for _, rep in ipairs(stats.reputations()) do
        records.reputations[rep.id:lower()] = rep
        if rep.editorId ~= '' then records.reputations[rep.editorId:lower()] = rep end
    end
    for _, perk in ipairs(stats.perks()) do
        records.perkList[#records.perkList + 1] = perk
        records.perks[perk.id:lower()] = perk
        if perk.editorId ~= '' then records.perks[perk.editorId:lower()] = perk end
    end
    return records
end

local function lookup(map, key)
    if type(key) ~= 'string' or key == '' then return nil end
    return M.records()[map][key:lower()]
end

function M.reputation(key) return lookup('reputations', key) end
function M.perk(key) return lookup('perks', key) end

-- Script argument 0 = infamy, 1 = fame.
local function kind(which)
    return (tonumber(which) or 1) ~= 0 and 'fame' or 'infamy'
end
M.kind = kind

---
-- Values computed from the published state { reputation = { [repId] = { fame =, infamy = } },
-- perks = { [perkId] = rank } }, shared by the global script and local readers.
function M.points(data, rep, which)
    if rep == nil or data == nil then return 0 end
    local entry = data.reputation and data.reputation[rep.id]
    return entry and entry[kind(which)] or 0
end

-- Tier 0..3 of the fame (which = 1) or infamy (which = 0) points.
function M.tier(data, rep, which)
    if rep == nil then return 0 end
    return rules.tier(M.points(data, rep, which), rep.value, gmst)
end

-- GetReputationThreshold rep axis (0 mixed, 1 fame, 2 infamy); nil for another axis.
function M.threshold(data, rep, axis)
    return rules.threshold(math.floor(tonumber(axis) or -1), M.tier(data, rep, 1), M.tier(data, rep, 0))
end

function M.percent(data, rep, which)
    if rep == nil or rep.value <= 0 then return 0 end
    return M.points(data, rep, which) / rep.value
end

function M.perkRank(data, perk)
    if perk == nil or data == nil or data.perks == nil then return 0 end
    return data.perks[perk.id] or 0
end

local alignmentByName = {
    good = rules.alignment.good, neutral = rules.alignment.neutral, evil = rules.alignment.evil,
    verygood = rules.alignment.veryGood, veryevil = rules.alignment.veryEvil,
}

local function alignmentArg(value)
    if type(value) == 'number' then return value end
    if type(value) == 'string' then
        return alignmentByName[value:lower():gsub('[%s_]', '')] or tonumber(value)
    end
    return nil
end

---
-- @param obs the ObScript runtime
-- @param env table with
--   subject() -> the object a command without a reference acts on,
--   resolve(ref) -> object for a reference (editor id string or object), or nil,
--   data() -> the published state (see M.points),
--   command(name, ...) runs a state-changing command in the global script.
function M.install(obs, env)
    local stats = core.obscript and core.obscript.stats
    if stats == nil then return end

    local warned = {}
    local function warnOnce(key, msg)
        if warned[key] then return end
        warned[key] = true
        print('[obscript] ' .. msg)
    end

    local function repArg(value, command)
        local rep = M.reputation(value)
        if rep == nil then warnOnce('rep:' .. tostring(value), command .. ': unknown reputation ' .. tostring(value)) end
        return rep
    end

    local function isPlayer(obj)
        return obj ~= nil and obj == env.resolve('player')
    end

    -- `RewardXP amount`
    obs.bind('RewardXP', function(a, b)
        env.command('rewardXP', tonumber(b or a) or 0)
        return 0
    end)
    -- `RewardKarma amount`
    obs.bind('RewardKarma', function(a, b)
        env.command('rewardKarma', tonumber(b or a) or 0)
        return 0
    end)
    obs.bind('AdvancePCLevel', function()
        env.command('advanceLevel')
        return 0
    end)
    obs.bind('AdvLevel', function()
        env.command('advanceLevel')
        return 0
    end)
    obs.bind('ResetXP', function()
        env.command('resetXP')
        return 0
    end)
    obs.bind('GetXPForNextLevel', function()
        local player = env.resolve('player')
        if player == nil then return 0 end
        local level = stats.getLevel(player)
        if level >= rules.maxLevel(gmst) then return -1 end
        return rules.xpForLevel(level + 1, gmst)
    end)

    -- `[ref.]GetIsAlignment Good|Neutral|Evil|VeryGood|VeryEvil` (or 0..4)
    obs.bind('GetIsAlignment', function(a, b)
        local obj, alignment = env.subject(), a
        if b ~= nil then obj, alignment = env.resolve(a), b end
        alignment = alignmentArg(alignment)
        if obj == nil or alignment == nil or not stats.hasActorValues(obj) then return 0 end
        return rules.alignmentOf(stats.get(obj, 'Karma'), gmst) == alignment and 1 or 0
    end)

    -- Reputation: `AddReputation RepNVGoodsprings 1 3` (1 fame / 0 infamy, size 1..5)
    for _, entry in ipairs({
        { 'AddReputation', 'addReputation' }, { 'RemoveReputation', 'removeReputation' },
        { 'AddReputationExact', 'addReputationExact' }, { 'RemoveReputationExact', 'removeReputationExact' },
        { 'SetReputation', 'setReputation' },
    }) do
        local name, command = entry[1], entry[2]
        obs.bind(name, function(rep, which, amount)
            rep = repArg(rep, name)
            if rep then env.command(command, rep.id, tonumber(which) or 1, tonumber(amount) or 0) end
            return 0
        end)
    end
    obs.bind('GetReputation', function(rep, which)
        return M.points(env.data(), repArg(rep, 'GetReputation'), which)
    end)
    obs.bind('GetReputationPct', function(rep, which)
        return M.percent(env.data(), repArg(rep, 'GetReputationPct'), which)
    end)
    obs.bind('GetReputationThreshold', function(rep, which)
        return M.threshold(env.data(), repArg(rep, 'GetReputationThreshold'), which) or 0
    end)

    -- Perks are only tracked for the player: `player.AddPerk Perk`, `HasPerk Perk`.
    local function perkCall(command, a, b)
        local perk = M.perk(a)
        local obj = env.subject()
        if perk == nil then
            obj = env.resolve(a)
            perk = M.perk(b)
        end
        if perk == nil then
            warnOnce('perk:' .. tostring(b or a), command .. ': unknown perk ' .. tostring(b or a))
        end
        return obj, perk
    end
    obs.bind('AddPerk', function(a, b)
        local obj, perk = perkCall('AddPerk', a, b)
        if perk and isPlayer(obj) then env.command('addPerk', perk.id) end
        return 0
    end)
    obs.bind('RemovePerk', function(a, b)
        local obj, perk = perkCall('RemovePerk', a, b)
        if perk and isPlayer(obj) then env.command('removePerk', perk.id) end
        return 0
    end)
    obs.bind('HasPerk', function(a, b)
        local obj, perk = perkCall('HasPerk', a, b)
        if not isPlayer(obj) then return 0 end
        return M.perkRank(env.data(), perk) > 0 and 1 or 0
    end)
end

return M
