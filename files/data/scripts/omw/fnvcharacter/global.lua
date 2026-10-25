-- FNV XP and leveling, karma, reputation and perks of the player.
--
-- XP and Karma are actor values (scripts/omw/fnvstats.lua). This script
-- watches the player's XP and levels up when it reaches the next level of the
-- XP table, giving skill points and, every iLevelsPerPerk levels, a perk; the
-- player script (fnvcharacter/player.lua) shows the level-up window to spend
-- them. It also keeps the fame and infamy with each reputation (REPU) and the
-- perks the player has, and publishes them in the global storage section
-- 'FNVCharacter' for local scripts.
--
-- From the Lua console (`luag`):
--   I.FNVCharacter.rewardXP(1000)
--   I.FNVCharacter.addReputation('RepNVGoodsprings', 1, 3)
--   I.FNVCharacter.getState()

local core = require('openmw.core')
local storage = require('openmw.storage')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local character = require('openmw_aux.obscript.character')
local rules = require('scripts.omw.fnvcharacter.rules')

local stats = core.obscript and core.obscript.stats
if stats == nil then
    return {}
end

local gmst = character.gmst

local section = storage.globalSection('FNVCharacter')
section:setLifeTime(storage.LIFE_TIME.GameSession)

local function newState()
    return {
        level = nil, -- set from the engine level on the first update
        pendingSkillPoints = 0,
        pendingPerks = 0,
        reputation = {}, -- REPU form id -> { fame =, infamy = }
        perks = {}, -- PERK form id -> rank
        alignment = nil,
    }
end

local state = newState()
local dirty = true

local function log(msg)
    print('[fnvcharacter] ' .. msg)
end

local function player()
    return world.players[1]
end

local function message(text)
    local p = player()
    if p then p:sendEvent('FNVCharacterMessage', { text = text }) end
end

local function publish()
    section:set('state', {
        reputation = state.reputation,
        perks = state.perks,
        level = state.level,
    })
    dirty = false
end

-- ------------------------------------------------------------------ skills and perks

-- The skills the level-up window offers (FNV's Big Guns is unused).
local skills = { 'Barter', 'EnergyWeapons', 'Explosives', 'Guns', 'Lockpick', 'Medicine', 'MeleeWeapons',
    'Repair', 'Science', 'Sneak', 'Speech', 'Survival', 'Unarmed' }
local skillNames = {
    EnergyWeapons = 'Energy Weapons', MeleeWeapons = 'Melee Weapons',
}

local function conditionsPass(perk, p)
    if perk.conditions == nil or #perk.conditions == 0 then return true end
    local dialogue = I.FNVDialogue
    if dialogue == nil or dialogue.checkConditions == nil then return true end
    local ok, passed = pcall(dialogue.checkConditions, perk.conditions, p)
    return ok and passed == true
end

-- Perks the player can take now: playable, not a trait, level and requirements met, ranks left.
local function availablePerks()
    local p = player()
    local res = {}
    if p == nil then return res end
    local level = state.level or stats.getLevel(p)
    for _, perk in ipairs(character.records().perkList) do
        local rank = state.perks[perk.id] or 0
        if perk.playable and not perk.isTrait and not perk.hidden and perk.name ~= ''
            and perk.minLevel <= level and rank < perk.ranks and conditionsPass(perk, p) then
            res[#res + 1] = {
                id = perk.id, name = perk.name, description = perk.description,
                rank = rank, ranks = perk.ranks, minLevel = perk.minLevel,
            }
        end
    end
    table.sort(res, function(a, b)
        if a.minLevel ~= b.minLevel then return a.minLevel < b.minLevel end
        return a.name < b.name
    end)
    return res
end

local function addPerk(id)
    local perk = character.perk(id)
    if perk == nil then return false end
    local rank = state.perks[perk.id] or 0
    if rank >= perk.ranks then return false end
    state.perks[perk.id] = rank + 1
    dirty = true
    for _, entry in ipairs(perk.entries or {}) do
        if entry.rank == rank then
            if entry.type == 'quest' and I.FNVDialogue then
                I.FNVDialogue.setStage(entry.quest, entry.stage)
            elseif entry.type == 'ability' then
                log(('perk %s: ability %s is not applied yet'):format(perk.editorId, entry.spell))
            end
        end
    end
    return true
end

local function removePerk(id)
    local perk = character.perk(id)
    if perk == nil or state.perks[perk.id] == nil then return end
    state.perks[perk.id] = nil
    dirty = true
end

-- ------------------------------------------------------------------ leveling

local function levelUpData()
    local p = player()
    local list = {}
    for _, name in ipairs(skills) do
        list[#list + 1] = {
            av = name,
            name = skillNames[name] or name,
            value = math.floor(stats.getBase(p, name)),
        }
    end
    local perks = state.pendingPerks > 0 and availablePerks() or {}
    return {
        level = state.level,
        skillPoints = state.pendingSkillPoints,
        perks = state.pendingPerks,
        skills = list,
        perkChoices = perks,
    }
end

local function hasSomethingToSpend()
    local p = player()
    if state.pendingSkillPoints > 0 then
        for _, name in ipairs(skills) do
            if stats.getBase(p, name) < 100 then return true end
        end
    end
    return state.pendingPerks > 0 and #availablePerks() > 0
end

local function offerLevelUp()
    local p = player()
    if p and hasSomethingToSpend() then
        p:sendEvent('FNVLevelUp', levelUpData())
    end
end

local function checkLevel()
    local p = player()
    if p == nil then return end
    if state.level == nil then
        state.level = stats.getLevel(p)
        dirty = true
    end
    local xp = stats.get(p, 'XP')
    local max = rules.maxLevel(gmst)
    local leveled = false
    while state.level < max and xp >= rules.xpForLevel(state.level + 1, gmst) do
        state.level = state.level + 1
        -- Perk entry point 10 (Adjust Gained Skill Points: Educated, Skilled) is not applied yet.
        state.pendingSkillPoints = state.pendingSkillPoints
            + rules.skillPoints(state.level, stats.getPermanent(p, 'Intelligence'))
        if rules.perkAtLevel(state.level, gmst) then
            state.pendingPerks = state.pendingPerks + 1
        end
        leveled = true
    end
    if leveled then
        stats._setPlayerLevel(state.level)
        dirty = true
        message(('You have reached level %d.'):format(state.level))
        offerLevelUp()
    end
end

local function rewardXP(amount)
    amount = math.floor(tonumber(amount) or 0)
    local p = player()
    if p == nil or amount == 0 then return end
    I.FNVStats.modify(p, 'XP', amount)
    if amount > 0 then message(('+%d XP'):format(amount)) end
    checkLevel()
end

-- AdvancePCLevel: XP up to the next level.
local function advanceLevel()
    local p = player()
    if p == nil then return end
    checkLevel()
    if state.level >= rules.maxLevel(gmst) then return end
    local need = rules.xpForLevel(state.level + 1, gmst) - stats.get(p, 'XP')
    if need > 0 then I.FNVStats.modify(p, 'XP', need) end
    checkLevel()
end

-- ResetXP: back to the start of the current level.
local function resetXP()
    local p = player()
    if p == nil then return end
    checkLevel()
    local delta = rules.xpForLevel(state.level, gmst) - stats.get(p, 'XP')
    if delta ~= 0 then I.FNVStats.modify(p, 'XP', delta) end
end

-- The level-up window's answer: skill points per skill and the chosen perk.
local function spend(data)
    local p = player()
    if p == nil or type(data) ~= 'table' then return end
    for av, points in pairs(data.skillPoints or {}) do
        points = math.floor(tonumber(points) or 0)
        if stats.actorValue(av) and points > 0 then
            local room = 100 - stats.getBase(p, av)
            points = math.max(0, math.min(points, state.pendingSkillPoints, math.floor(room)))
            if points > 0 then
                stats._addBasePoints(p, av, points)
                state.pendingSkillPoints = state.pendingSkillPoints - points
            end
        end
    end
    if data.perk and state.pendingPerks > 0 then
        for _, perk in ipairs(availablePerks()) do
            if perk.id == data.perk then
                if addPerk(perk.id) then
                    state.pendingPerks = state.pendingPerks - 1
                    message('Perk: ' .. perk.name)
                end
                break
            end
        end
    end
    dirty = true
    offerLevelUp()
end

-- ------------------------------------------------------------------ karma

local function rewardKarma(amount)
    amount = tonumber(amount) or 0
    local p = player()
    if p == nil or amount == 0 then return end
    local current = stats.get(p, 'Karma')
    local target = rules.clampKarma(current + amount, gmst)
    if target ~= current then I.FNVStats.modify(p, 'Karma', target - current) end
    message(amount > 0 and 'You gained karma.' or 'You lost karma.')
end

local function checkAlignment()
    local p = player()
    if p == nil then return end
    local alignment = rules.alignmentOf(stats.get(p, 'Karma'), gmst)
    if state.alignment ~= nil and state.alignment ~= alignment then
        message('Karma: ' .. rules.alignmentNames[alignment])
    end
    state.alignment = alignment
end

-- ------------------------------------------------------------------ reputation

local function repEntry(rep)
    local entry = state.reputation[rep.id]
    if entry == nil then
        entry = { fame = 0, infamy = 0 }
        state.reputation[rep.id] = entry
    end
    return entry
end

local function standing(rep)
    return rules.standing(character.threshold(state, rep, 1), character.threshold(state, rep, 0))
end

local function changeReputation(repKey, which, fn)
    local rep = character.reputation(repKey)
    if rep == nil then
        log('unknown reputation ' .. tostring(repKey))
        return
    end
    local before = standing(rep)
    local entry = repEntry(rep)
    local kind = character.kind(which)
    -- clamped to the REPU DATA value, as AddReputation 0x615c90 does
    entry[kind] = math.max(0, math.min(rep.value, fn(entry[kind])))
    dirty = true
    local after = standing(rep)
    if after ~= before then
        message(('%s: %s'):format(rep.name ~= '' and rep.name or rep.editorId, after))
    end
end

local commands = {
    rewardXP = rewardXP,
    rewardKarma = rewardKarma,
    advanceLevel = advanceLevel,
    resetXP = resetXP,
    addReputation = function(rep, which, size)
        local amount = rules.bump(size, gmst)
        changeReputation(rep, which, function(v) return v + amount end)
    end,
    removeReputation = function(rep, which, size)
        local amount = rules.bump(size, gmst)
        changeReputation(rep, which, function(v) return v - amount end)
    end,
    addReputationExact = function(rep, which, amount)
        changeReputation(rep, which, function(v) return v + (tonumber(amount) or 0) end)
    end,
    removeReputationExact = function(rep, which, amount)
        changeReputation(rep, which, function(v) return v - (tonumber(amount) or 0) end)
    end,
    setReputation = function(rep, which, amount)
        changeReputation(rep, which, function() return tonumber(amount) or 0 end)
    end,
    addPerk = addPerk,
    removePerk = removePerk,
}

local function runCommand(name, ...)
    local fn = commands[name]
    if fn == nil then
        log('unknown command ' .. tostring(name))
        return
    end
    fn(...)
end

return {
    interfaceName = 'FNVCharacter',
    ---
    -- @module FNVCharacter
    -- @context global
    interface = {
        version = 0,
        rewardXP = rewardXP,
        rewardKarma = rewardKarma,
        advanceLevel = advanceLevel,
        resetXP = resetXP,
        addReputation = commands.addReputation,
        removeReputation = commands.removeReputation,
        addReputationExact = commands.addReputationExact,
        removeReputationExact = commands.removeReputationExact,
        setReputation = commands.setReputation,
        --- Fame (which = 1) or infamy (which = 0) points with a reputation (editor id or form id).
        getReputation = function(rep, which) return character.points(state, character.reputation(rep), which) end,
        --- Tier 0..3 (GetReputationThreshold).
        getReputationThreshold = function(rep, which)
            return character.threshold(state, character.reputation(rep), which)
        end,
        --- Named standing ('Neutral', 'Liked', 'Smiling Troublemaker', ...).
        getStanding = function(rep)
            rep = character.reputation(rep)
            return rep and standing(rep)
        end,
        addPerk = addPerk,
        removePerk = removePerk,
        hasPerk = function(perk) return character.perkRank(state, character.perk(perk)) > 0 end,
        availablePerks = availablePerks,
        --- Shows the level-up window if there are skill points or a perk to spend.
        showLevelUp = offerLevelUp,
        --- The saved state, for debugging.
        getState = function() return state end,
        --- Runs one of the commands ObScript uses (see openmw_aux.obscript.character).
        command = runCommand,
    },
    engineHandlers = {
        onInit = function()
            state = newState()
            dirty = true
        end,
        onSave = function()
            return { state = state }
        end,
        onLoad = function(data)
            state = newState()
            for k, v in pairs(data and data.state or {}) do state[k] = v end
            if state.level ~= nil then stats._setPlayerLevel(state.level) end
            dirty = true
        end,
        onUpdate = function()
            checkLevel()
            checkAlignment()
            if dirty then publish() end
        end,
        onPlayerAdded = function()
            offerLevelUp()
        end,
    },
    eventHandlers = {
        -- from local ObScript (openmw_aux.obscript.bindings)
        FNVCharacterCommand = function(data)
            runCommand(data.name, table.unpack(data.args or {}))
        end,
        -- from the level-up window
        FNVCharacterSpend = spend,
        FNVCharacterLevelUpWanted = offerLevelUp,
    },
}
