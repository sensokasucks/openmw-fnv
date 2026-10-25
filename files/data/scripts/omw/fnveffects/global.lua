-- FO3/FNV active effects: what ingestibles (ALCH: stimpaks, food, chems),
-- actor effects (SPEL: abilities, addictions, CastImmediateOnSelf) and their
-- magic effects (MGEF) do to an actor while they last.
--
-- Each effect item of a source becomes one active effect instance:
--   Value Modifier (and Value And Parts, Limb Condition) effects change the
--     MGEF's actor value through I.FNVStats. With the MGEF's Recover flag the
--     change lasts while the effect does and is undone at the end (Buffout's
--     +Strength); without it the magnitude is damage or restoration, per
--     second over the duration or at once when there is none (Stimpak's
--     Health). Detrimental effects subtract. Counting values (rads, hardcore
--     needs) go up for detrimental effects instead, and not below 0.
--   Script effects run their SCPT (type 0x100) through the quest-script
--     runtime (I.FNVDialogue.runEffectScript), each instance with its own
--     locals: ScriptEffectStart, then ScriptEffectUpdate every frame, then
--     ScriptEffectFinish.
--   Cure Addiction ends the actor's addictions; Dispel ends other effects.
--   Other archetypes (invisibility, paralysis, turbo, ...) are kept as
--     instances for IsSpellTarget/HasMagicEffect but do nothing yet.
-- An effect item's conditions (CTDA, run on the affected actor) are checked
-- when it starts and every fActiveEffectConditionUpdateInterval seconds; the
-- effect does nothing while they fail, but its duration still runs.
--
-- Medicine items heal more with the Medicine skill and food with Survival
-- (fMagicMedicineSkillMult, fMagicSurvivalSkillMult). A chem with an
-- addiction SPEL can addict on use (the ALCH addiction chance); the
-- addiction SPEL then stays on the actor until cured, and its effects'
-- conditions decide when the withdrawal shows.
--
-- Using an ESM4 potion in the inventory consumes one and applies it. From the
-- Lua console (`luag`):
--   I.FNVEffects.applyPotion(world.players[1], 'Stimpak')
--   I.FNVEffects.list(world.players[1])

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local effects = core.obscript and core.obscript.effects
local stats = core.obscript and core.obscript.stats
if effects == nil or stats == nil or types.ESM4Potion == nil then
    return {}
end

local trace = core.obscript.traceEnabled

local function log(msg)
    print('[effects] ' .. msg)
end

local function tlog(msg)
    if trace then print('[effects-trace] ' .. msg) end
end

local warned = {}
local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    log(msg)
end

local function gmst(name, fallback)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or fallback
end

-- MGEF DATA flags and archetypes (components/esm4/loadmgef.hpp)
local FLAG_RECOVER = 0x2
local FLAG_DETRIMENTAL = 0x4

local ARCH_VALUE_MODIFIER = 0
local ARCH_SCRIPT = 1
local ARCH_DISPEL = 2
local ARCH_CURE_ADDICTION = 31
local ARCH_VALUE_AND_PARTS = 34
local ARCH_LIMB_CONDITION = 35

local SPELL_ABILITY = 4

-- ALCH ENIT flags
local ITEM_FOOD = 0x2
local ITEM_MEDICINE = 0x4

-- CTDA functions this script provides
local FUN_HAS_MAGIC_EFFECT = 214
local FUN_IS_SPELL_TARGET = 223

local function hasFlag(flags, flag)
    return math.floor((flags or 0) / flag) % 2 == 1
end

local function isValueModifier(archetype)
    return archetype == ARCH_VALUE_MODIFIER or archetype == ARCH_VALUE_AND_PARTS
        or archetype == ARCH_LIMB_CONDITION
end

-- Actor values that count up (radiation, hardcore needs): the harmful
-- direction raises them, and they don't go below 0.
local counterValues = {}
for _, name in ipairs({ 'RadiationRads', 'Dehydration', 'Hunger', 'SleepDeprivation' }) do
    local av = stats.actorValue(name)
    if av then counterValues[av] = true end
end
local HEALTH = stats.actorValue('Health')

-- ---------------------------------------------------------------- records (cached)

local function cached(getter)
    local cache = {}
    return function(id)
        if type(id) ~= 'string' or id == '' then return nil end
        local key = id:lower()
        local record = cache[key]
        if record == nil then
            record = getter(id) or false
            cache[key] = record
        end
        return record or nil
    end
end

local getMagicEffect = cached(effects.getMagicEffect)
local getSpell = cached(effects.getSpell)
local getPotion = cached(effects.getPotion)

-- ---------------------------------------------------------------- persistent state

local state = {
    nextId = 1,
    -- instance id -> { id, actor, caster, source = { kind, id, name }, index (in the source's effect list),
    --   effect (MGEF id), magnitude, duration (0 instant, -1 until removed), elapsed, actorValue,
    --   archetype, flags, script, locals, active (conditions pass), applied (Recover change in place),
    --   rate (per second), started (start actions done), finished }
    -- source.kind: 'potion', 'spell' (cast), 'ability' (AddSpell), 'addiction'
    active = {},
    -- actor id -> { [addiction SPEL id] = true }
    addictions = {},
}

local function actorKey(actor)
    return actor and actor.id
end

-- Which actor effects and magic effects are active on each actor, for the
-- queries of local scripts (openmw_aux/obscript/effects.lua); rebuilt on load.
local section = storage.globalSection('FNVEffects')
section:setLifeTime(storage.LIFE_TIME.Temporary)
local dirty = {} -- actor id -> true

local function markDirty(actor)
    if actor then dirty[actor.id] = true end
end

local function publish()
    for key in pairs(dirty) do
        local spells, effectIds, any = {}, {}, false
        for _, inst in pairs(state.active) do
            if actorKey(inst.actor) == key and not inst.finished then
                spells[inst.source.id] = true
                effectIds[inst.effect] = true
                any = true
            end
        end
        section:set(key, any and { spells = spells, effects = effectIds } or nil)
    end
    dirty = {}
end

local function sourceName(source)
    return (source.name or '') ~= '' and source.name or source.id
end

local function changeStat(actor, op, av, value)
    if value == 0 or I.FNVStats == nil then return end
    I.FNVStats.change(actor, op, av, value)
end

-- Changes a counter actor value by delta, keeping it >= 0; returns the change made.
local function changeCounter(actor, av, delta)
    local ok, current = pcall(stats.get, actor, av)
    if ok and current + delta < 0 then delta = -current end
    changeStat(actor, 'modify', av, delta)
    return delta
end

-- The effect item an instance came from (for its conditions); not saved.
local function effectItem(inst)
    local record
    local kind = inst.source.kind
    if kind == 'potion' then
        record = getPotion(inst.source.id)
    else
        record = getSpell(inst.source.id)
    end
    return record and record.effects[inst.index]
end

local function conditionsPass(conditions, actor)
    if conditions == nil or #conditions == 0 then return true end
    if I.FNVDialogue == nil or I.FNVDialogue.checkConditions == nil then return true end
    local ok, passed = pcall(I.FNVDialogue.checkConditions, conditions, actor)
    return not ok or passed == true
end

-- ---------------------------------------------------------------- effect scripts

local runningInstance = nil -- for ScriptEffectElapsedSeconds

local function runScript(inst, event, dt)
    local runner = I.FNVDialogue and I.FNVDialogue.runEffectScript
    if runner == nil then
        warnOnce('noRunner', 'effect scripts need FNVDialogue.runEffectScript; ' .. inst.script .. ' does not run')
        return
    end
    local prev = runningInstance
    runningInstance = inst
    local ok, found = pcall(runner, inst.script, inst.actor, inst.locals,
        { [event] = { { ref = inst.caster or inst.actor } } }, dt)
    runningInstance = prev
    if not ok then
        warnOnce('script:' .. inst.script, 'effect script ' .. inst.script .. ' failed: ' .. tostring(found))
    elseif not found then
        warnOnce('script:' .. inst.script, 'effect script not found or does not compile: ' .. inst.script)
    end
end

-- ---------------------------------------------------------------- instances

local finish -- forward
local cureAddictions -- forward

-- The effect starts acting (when it is applied, or when its conditions pass again).
local function activate(inst)
    inst.active = true
    local actor = inst.actor
    local first = not inst.started
    inst.started = true
    if inst.archetype == ARCH_SCRIPT then
        if first and inst.script then runScript(inst, 'scripteffectstart', 0) end
    elseif isValueModifier(inst.archetype) and inst.actorValue then
        local sign = hasFlag(inst.flags, FLAG_DETRIMENTAL) and -1 or 1
        local counter = counterValues[inst.actorValue]
        if counter then sign = -sign end
        if hasFlag(inst.flags, FLAG_RECOVER) then
            if counter then
                inst.applied = changeCounter(actor, inst.actorValue, sign * inst.magnitude)
            else
                inst.applied = sign * inst.magnitude
                changeStat(actor, 'modify', inst.actorValue, inst.applied)
            end
        elseif inst.duration ~= 0 then
            inst.rate = sign * inst.magnitude -- per second, see tick
        elseif first then
            if counter then
                changeCounter(actor, inst.actorValue, sign * inst.magnitude)
            else
                -- damage takes a positive amount; restoring is negative damage
                changeStat(actor, 'damage', inst.actorValue, -sign * inst.magnitude)
            end
        end
    elseif first and inst.archetype == ARCH_CURE_ADDICTION then
        cureAddictions(actor)
    elseif first and inst.archetype == ARCH_DISPEL then
        for _, other in pairs(state.active) do
            if other ~= inst and other.actor == actor and other.duration >= 0 and not other.finished then
                finish(other)
            end
        end
    elseif first and not isValueModifier(inst.archetype) then
        local mgef = getMagicEffect(inst.effect)
        warnOnce('arch:' .. tostring(inst.archetype),
            'magic effect archetype ' .. tostring(inst.archetype) .. ' is not implemented yet (first seen: '
            .. tostring(mgef and mgef.editorId or inst.effect) .. ')')
    end
end

-- Undoes a Recover change in place.
local function undoChange(inst)
    if inst.applied and inst.applied ~= 0 and inst.actor:isValid() then
        if counterValues[inst.actorValue] then
            changeCounter(inst.actor, inst.actorValue, -inst.applied)
        else
            changeStat(inst.actor, 'modify', inst.actorValue, -inst.applied)
        end
    end
    inst.applied = nil
end

-- The effect stops acting while its conditions fail.
local function deactivate(inst)
    inst.active = false
    undoChange(inst)
end

-- Ends an instance: undoes Recover changes and runs ScriptEffectFinish.
finish = function(inst)
    if inst.finished then return end
    inst.finished = true
    undoChange(inst)
    if inst.started and inst.archetype == ARCH_SCRIPT and inst.script and inst.actor:isValid() then
        runScript(inst, 'scripteffectfinish', 0)
    end
    state.active[inst.id] = nil
    markDirty(inst.actor)
    tlog('effect ' .. tostring(inst.effect) .. ' from ' .. sourceName(inst.source) .. ' ended on '
        .. tostring(inst.actor))
end

local function tick(inst, dt, recheck)
    local actor = inst.actor
    if actor == nil or not actor:isValid() then
        state.active[inst.id] = nil
        return
    end
    if recheck then
        local item = effectItem(inst)
        local passes = conditionsPass(item and item.conditions, actor)
        if passes and not inst.active then
            activate(inst)
        elseif inst.active and not passes then
            deactivate(inst)
        end
    end
    if inst.active then
        if inst.archetype == ARCH_SCRIPT and inst.script then
            runScript(inst, 'scripteffectupdate', dt)
        end
        if inst.rate then
            local step = dt
            if inst.duration >= 0 then step = math.min(dt, math.max(0, inst.duration - inst.elapsed)) end
            if step > 0 then
                if counterValues[inst.actorValue] then
                    changeCounter(actor, inst.actorValue, inst.rate * step)
                else
                    changeStat(actor, 'damage', inst.actorValue, -inst.rate * step)
                end
            end
        end
    end
    inst.elapsed = inst.elapsed + dt
    if inst.duration >= 0 and inst.elapsed >= inst.duration then
        finish(inst)
    end
end

-- Medicine items heal more with Medicine, food with Survival (guessed
-- formula: x(1 + skill/100 * (mult - 1)), i.e. double at skill 100).
local function skillScale(actor, flags, item, mgef)
    if mgef.actorValue ~= HEALTH or hasFlag(mgef.flags, FLAG_DETRIMENTAL) then return 1 end
    local skill, setting
    if hasFlag(flags, ITEM_MEDICINE) then
        skill, setting = 'Medicine', 'fMagicMedicineSkillMult'
    elseif hasFlag(flags, ITEM_FOOD) then
        skill, setting = 'Survival', 'fMagicSurvivalSkillMult'
    else
        return 1
    end
    local ok, value = pcall(stats.get, actor, skill)
    if not ok then return 1 end
    return 1 + math.max(0, value) / 100 * (gmst(setting, 2) - 1)
end

---
-- Applies a source's effect list to an actor.
-- @param source { kind, id, name, effects, flags (ALCH) }
-- @param permanent effects last until removed (abilities, AddSpell, addictions)
local function applyEffects(actor, source, caster, permanent)
    for index, item in ipairs(source.effects or {}) do
        local mgef = getMagicEffect(item.effect)
        if mgef == nil then
            warnOnce('mgef:' .. tostring(item.effect), 'unknown magic effect ' .. tostring(item.effect)
                .. ' in ' .. sourceName(source))
        else
            local av = mgef.actorValue
            if av == nil or av < 0 then av = item.actorValue end
            local magnitude = item.magnitude or 0
            if source.kind == 'potion' then magnitude = magnitude * skillScale(actor, source.flags, item, mgef) end
            local inst = {
                id = state.nextId,
                actor = actor,
                caster = caster,
                source = { kind = source.kind, id = source.id, name = source.name or '' },
                index = index,
                effect = mgef.id,
                magnitude = magnitude,
                duration = permanent and -1 or (item.duration or 0),
                elapsed = 0,
                actorValue = (av ~= nil and av >= 0) and av or nil,
                archetype = mgef.archetype,
                flags = mgef.flags,
                script = mgef.archetype == ARCH_SCRIPT and (mgef.script or nil) or nil,
                locals = {},
                active = false,
            }
            state.nextId = state.nextId + 1
            state.active[inst.id] = inst
            markDirty(actor)
            tlog(('effect %s (archetype %s) from %s on %s: magnitude %g, duration %d'):format(mgef.editorId,
                tostring(mgef.archetype), sourceName(source), tostring(actor), inst.magnitude, inst.duration))
            if conditionsPass(item.conditions, actor) then activate(inst) end
            -- instant effects end at once; the rest tick from the next frame
            if inst.duration == 0 then finish(inst) end
        end
    end
end

local function sourceInstances(actor, kind, id)
    local list = {}
    for _, inst in pairs(state.active) do
        if inst.actor == actor and inst.source.id == id and (kind == nil or inst.source.kind == kind) then
            list[#list + 1] = inst
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function removeSource(actor, kind, id)
    local list = sourceInstances(actor, kind, id)
    for _, inst in ipairs(list) do finish(inst) end
    return #list
end

-- ---------------------------------------------------------------- spells and potions

local function findSpell(spellId)
    local spell = getSpell(spellId)
    if spell == nil then
        warnOnce('spell:' .. tostring(spellId), 'unknown actor effect (SPEL) ' .. tostring(spellId))
    end
    return spell
end

local function spellSource(spell, kind)
    return { kind = kind, id = spell.id, name = spell.name, effects = spell.effects }
end

local function castSpell(actor, spellId, caster)
    local spell = findSpell(spellId)
    if spell == nil or actor == nil then return false end
    if spell.type == SPELL_ABILITY then
        if #sourceInstances(actor, 'ability', spell.id) == 0 then
            applyEffects(actor, spellSource(spell, 'ability'), caster, true)
        end
    else
        applyEffects(actor, spellSource(spell, 'spell'), caster, false)
    end
    return true
end

-- AddSpell: the actor effect stays until RemoveSpell.
local function addSpell(actor, spellId)
    local spell = findSpell(spellId)
    if spell == nil or actor == nil then return false end
    if #sourceInstances(actor, 'ability', spell.id) == 0 then
        applyEffects(actor, spellSource(spell, 'ability'), actor, true)
    end
    return true
end

local function removeSpell(actor, spellId)
    local spell = getSpell(spellId)
    if spell == nil or actor == nil then return false end
    return removeSource(actor, 'ability', spell.id) > 0
end

local function playerNotice(text)
    local player = world.players[1]
    if player then player:sendEvent('ObScriptNotify', { text = text }) end
end

local function addAddiction(actor, spell, chemName)
    local key = actorKey(actor)
    state.addictions[key] = state.addictions[key] or {}
    state.addictions[key][spell.id] = true
    if #sourceInstances(actor, 'addiction', spell.id) == 0 then
        applyEffects(actor, spellSource(spell, 'addiction'), actor, true)
    end
    tlog(tostring(actor) .. ' is now addicted: ' .. spell.editorId)
    if types.Player.objectIsInstance(actor) then
        local text = core.getFNVGMST and core.getFNVGMST('sChemsAddicted')
        if type(text) ~= 'string' or text == '' then text = 'You are addicted to %s.' end
        if text:find('%%s') then text = text:format(chemName) end
        playerNotice(text)
    end
end

cureAddictions = function(actor)
    local key = actorKey(actor)
    for spellId in pairs(state.addictions[key] or {}) do
        removeSource(actor, 'addiction', spellId)
    end
    state.addictions[key] = nil
end

local function applyPotion(actor, potionId)
    local potion = getPotion(potionId)
    if potion == nil or actor == nil then
        warnOnce('potion:' .. tostring(potionId), 'unknown ingestible (ALCH) ' .. tostring(potionId))
        return false
    end
    applyEffects(actor, {
        kind = 'potion', id = potion.id, name = potion.name, effects = potion.effects, flags = potion.flags,
    }, actor, false)
    if potion.consumeSound ~= '' then
        pcall(core.sound.playSound3d, potion.consumeSound, actor)
    end
    local addiction = potion.addiction ~= '' and getSpell(potion.addiction)
    if addiction then
        local list = state.addictions[actorKey(actor)]
        local chance = potion.addictionChance or 0
        if chance > 1 then chance = chance / 100 end -- in case it is a percentage
        if not (list and list[addiction.id]) and math.random() < chance then
            addAddiction(actor, addiction, potion.name)
        end
    end
    return true
end

-- ---------------------------------------------------------------- inventory use

I.ItemUsage.addHandlerForType(types.ESM4Potion, function(item, actor)
    local recordId = item.recordId
    if getPotion(recordId) == nil then return end
    item:remove(1)
    applyPotion(actor, recordId)
    return false
end)

-- ---------------------------------------------------------------- ObScript commands and conditions

local function hasMagicEffect(actor, mgefId)
    local mgef = getMagicEffect(mgefId)
    if mgef == nil or actor == nil then return 0 end
    for _, inst in pairs(state.active) do
        if inst.actor == actor and inst.effect == mgef.id and not inst.finished then return 1 end
    end
    return 0
end

local function isSpellTarget(actor, spellId)
    local spell = getSpell(spellId)
    if spell == nil or actor == nil then return 0 end
    return #sourceInstances(actor, nil, spell.id) > 0 and 1 or 0
end

local function resolveObject(ref)
    if type(ref) ~= 'string' then return ref end
    local lower = ref:lower()
    if lower == 'player' or lower == 'playerref' then return world.players[1] end
    local formId = core.obscript.resolveRefEditorId(ref)
    if formId then
        local ok, obj = pcall(world.getObjectByFormId, formId)
        if ok and obj and obj:isValid() then return obj end
    end
    return nil
end

-- name -> fn(subject, ...): the object the command acts on, then its arguments
local commands = {
    CastImmediateOnSelf = function(subject, spellId)
        castSpell(subject, spellId, subject)
        return 0
    end,
    -- `Ref.Cast Spell Target`: Ref casts at Target (at itself without one)
    Cast = function(subject, spellId, target)
        castSpell(resolveObject(target) or subject, spellId, subject)
        return 0
    end,
    AddSpell = function(subject, spellId)
        addSpell(subject, spellId)
        return 0
    end,
    RemoveSpell = function(subject, spellId)
        removeSpell(subject, spellId)
        return 0
    end,
    Dispel = function(subject, spellId)
        local spell = getSpell(spellId)
        if spell and subject then removeSource(subject, nil, spell.id) end
        return 0
    end,
    DispelAllSpells = function(subject)
        for _, inst in pairs(state.active) do
            if inst.actor == subject and inst.duration >= 0 then finish(inst) end
        end
        return 0
    end,
    IsSpellTarget = function(subject, spellId)
        return isSpellTarget(subject, spellId)
    end,
    HasMagicEffect = function(subject, mgefId)
        return hasMagicEffect(subject, mgefId)
    end,
    ScriptEffectElapsedSeconds = function()
        return runningInstance and runningInstance.elapsed or 0
    end,
    GetSelf = function(subject)
        return subject or 0
    end,
}

local installed = false
local function install()
    if installed then return end
    installed = true
    local dlgI = I.FNVDialogue
    if dlgI == nil or dlgI.bindCommand == nil then
        warnOnce('noBind', 'FNVDialogue.bindCommand is missing; quest and effect scripts lack effect commands')
    else
        for name, fn in pairs(commands) do dlgI.bindCommand(name, fn) end
    end
    if dlgI and dlgI.setConditionFunction then
        dlgI.setConditionFunction(FUN_HAS_MAGIC_EFFECT, function(cond, obj)
            return hasMagicEffect(obj, cond.param1Form)
        end)
        dlgI.setConditionFunction(FUN_IS_SPELL_TARGET, function(cond, obj)
            return isSpellTarget(obj, cond.param1Form)
        end)
    end
end

-- ---------------------------------------------------------------- interface

local function list(actor)
    local res = {}
    for _, inst in pairs(state.active) do
        if actor == nil or inst.actor == actor then
            local mgef = getMagicEffect(inst.effect)
            res[#res + 1] = {
                id = inst.id,
                actor = inst.actor,
                source = sourceName(inst.source),
                sourceKind = inst.source.kind,
                effect = mgef and mgef.editorId or inst.effect,
                name = mgef and mgef.name or '',
                magnitude = inst.magnitude,
                duration = inst.duration,
                remaining = inst.duration >= 0 and math.max(0, inst.duration - inst.elapsed) or -1,
                active = inst.active,
            }
        end
    end
    table.sort(res, function(a, b) return a.id < b.id end)
    return res
end

local conditionTimer = 0

return {
    interfaceName = 'FNVEffects',
    ---
    -- @module FNVEffects
    -- @context global
    interface = {
        version = 0,
        --- Applies an ingestible (ALCH, by record id or editor id) to an actor, as when it is consumed.
        applyPotion = applyPotion,
        --- Casts an actor effect (SPEL) on an actor (CastImmediateOnSelf); abilities stay.
        cast = function(actor, spellId, caster) return castSpell(actor, spellId, caster or actor) end,
        --- AddSpell / RemoveSpell.
        addSpell = addSpell,
        removeSpell = removeSpell,
        --- Active effects on an actor (or on everyone): list of { id, actor, source, sourceKind,
        -- effect, name, magnitude, duration, remaining (-1 = until removed), active }.
        list = list,
        --- 1 if an effect of the actor effect (SPEL) is on the actor (IsSpellTarget).
        isSpellTarget = isSpellTarget,
        --- 1 if the magic effect (MGEF) is on the actor (HasMagicEffect).
        hasMagicEffect = hasMagicEffect,
        --- Addiction SPEL ids of an actor.
        addictions = function(actor)
            local res = {}
            for id in pairs(state.addictions[actorKey(actor)] or {}) do res[#res + 1] = id end
            table.sort(res)
            return res
        end,
        --- Ends all of an actor's addictions (as the Fixer does).
        cureAddictions = function(actor) cureAddictions(actor) end,
    },
    eventHandlers = {
        -- from local ObScript (openmw_aux/obscript/effects.lua):
        -- { name, self (the object whose script ran it), member, args, n }
        FNVEffectsCommand = function(data)
            local fn = commands[data.name]
            if fn == nil then return end
            local args = data.args or {}
            local subject = data.self
            local first = 1
            if data.member then
                subject = resolveObject(args[1])
                first = 2
            end
            local ok, err = pcall(fn, subject, table.unpack(args, first, data.n or #args))
            if not ok then log('command ' .. tostring(data.name) .. ' failed: ' .. tostring(err)) end
        end,
        -- { actor, potion = record id or editor id }
        FNVApplyPotion = function(data)
            applyPotion(data.actor, data.potion)
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            install()
            conditionTimer = conditionTimer - dt
            local recheck = conditionTimer <= 0
            if recheck then conditionTimer = gmst('fActiveEffectConditionUpdateInterval', 1) end
            local list = {}
            for _, inst in pairs(state.active) do list[#list + 1] = inst end
            table.sort(list, function(a, b) return a.id < b.id end)
            for _, inst in ipairs(list) do
                if not inst.finished then
                    local ok, err = pcall(tick, inst, dt, recheck)
                    if not ok then
                        warnOnce('tick:' .. tostring(inst.effect), 'effect ' .. tostring(inst.effect) .. ' failed: '
                            .. tostring(err))
                        state.active[inst.id] = nil
                        markDirty(inst.actor)
                    end
                end
            end
            publish()
        end,
        onSave = function()
            return { state = state }
        end,
        onLoad = function(data)
            if data and data.state then
                state = data.state
                state.active = state.active or {}
                state.addictions = state.addictions or {}
                state.nextId = state.nextId or 1
            end
            for _, inst in pairs(state.active) do markDirty(inst.actor) end
        end,
    },
}
