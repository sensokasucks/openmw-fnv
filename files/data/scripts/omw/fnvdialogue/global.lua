-- FO3/FNV dialogue (DIAL/INFO) for ESM4 NPCs: greeting and topic selection,
-- CTDA conditions, quest stages and INFO result scripts. The dialogue window
-- itself lives in scripts/omw/fnvdialogue/player.lua.
--
-- Activating an ESM4 NPC opens dialogue (through the Activation interface,
-- so an NPC script's OnActivate block still runs first and must call
-- `Activate` to talk, as in the original game). While NPCs are not rendered
-- yet, dialogue can be opened from the console:
--   luag
--   I.FNVDialogue.talkTo('DocMitchell')

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local conditions = require('scripts.omw.fnvdialogue.conditions')

local dlg = core.obscript and core.obscript.dialogue
if dlg == nil or types.ESM4NPC == nil then
    return {}
end

local compiler = require('openmw_aux.obscript.compiler')
local obs = require('openmw_aux.obscript.runtime')

local trace = core.obscript.traceEnabled

local function log(msg)
    print('[dialogue] ' .. msg)
end

local function tlog(msg)
    if trace then print('[dialogue-trace] ' .. msg) end
end

local INFO_GOODBYE = 0x0001
local INFO_RANDOM = 0x0002
local INFO_SAY_ONCE = 0x0004
local INFO_RUN_IMMEDIATELY = 0x0008 -- the end script runs with the begin script
local INFO_RANDOM_END = 0x0020 -- closes a run of Random lines
local INFO_SAY_ONCE_A_DAY = 0x0100

local function hasFlag(flags, flag)
    return util.bitAnd(flags or 0, flag) ~= 0
end

-- ---------------------------------------------------------------- persistent state

local state = {
    initialized = false,
    -- quest form id -> { running, completed, failed, stage, done = {[stage] = true}, objectives = {},
    --                    delay (SetQuestDelay), countdown, elapsed (quest script scheduling) }
    quests = {},
    saidOnce = {},   -- INFO form id -> true
    saidAt = {},     -- INFO form id -> game time (s) it was last said, for Say Once a Day
    factions = {},    -- reference form id -> { [faction form id] = rank, or false when removed }
    knownTopics = {}, -- topic form id -> true: topics from AddTopic and INFO add-topics (top-level ones are always known)
    talkedTo = {},   -- NPC reference form id -> true
}

local initState -- forward; needs the quest functions below
local isNewGame = false

-- ---------------------------------------------------------------- records (cached)

local questCache = {}
local function getQuest(idOrEditorId)
    if type(idOrEditorId) ~= 'string' or idOrEditorId == '' then return nil end
    local key = idOrEditorId:lower()
    local quest = questCache[key]
    if quest == nil then
        quest = dlg.getQuest(idOrEditorId) or false
        questCache[key] = quest
    end
    return quest or nil
end

-- Quests flagged "start game enabled" (QUST DATA 0x01) run from the start. A quest first
-- looked at before initState (a condition, a greeting) must not be created as stopped.
local startEnabled = nil
local function isStartEnabled(questId)
    if startEnabled == nil then
        startEnabled = {}
        for _, id in ipairs(dlg.getStartGameEnabledQuests()) do startEnabled[id] = true end
    end
    return startEnabled[questId] == true
end

local function questState(quest)
    local s = state.quests[quest.id]
    if s == nil then
        s = { running = isStartEnabled(quest.id), stage = 0, done = {}, objectives = {} }
        state.quests[quest.id] = s
    end
    return s
end

local topicCache = {}
local function getTopic(idOrEditorId)
    local key = idOrEditorId:lower()
    local topic = topicCache[key]
    if topic == nil then
        topic = dlg.getTopic(idOrEditorId) or false
        topicCache[key] = topic
    end
    return topic or nil
end

local infoCache = {}
local function getTopicInfos(topicId, speakerRecordId)
    local key = topicId .. '|' .. speakerRecordId
    local infos = infoCache[key]
    if infos == nil then
        infos = dlg.getTopicInfos(topicId, speakerRecordId)
        infoCache[key] = infos
    end
    return infos
end

local speakerTopicCache = {}
local function getSpeakerTopics(speakerRecordId)
    local topics = speakerTopicCache[speakerRecordId]
    if topics == nil then
        topics = dlg.getSpeakerTopics(speakerRecordId)
        speakerTopicCache[speakerRecordId] = topics
    end
    return topics
end

-- ---------------------------------------------------------------- globals

-- The FNV clock globals are views of OpenMW's clock, so scripts, conditions,
-- AI schedules and the sky agree. GameDaysPassed counts fractional days.
local CLOCK = {
    gamehour = 'hour', gameday = 'day', gamemonth = 'month', gameyear = 'year',
    gamedayspassed = 'daysPassed', timescale = 'timeScale',
}

local function clockValue(key)
    local date = core.obscript.getGameDate()
    if key == 'gamedayspassed' then
        return date.daysPassed + date.hour / 24
    end
    return date[CLOCK[key]]
end

local function setClock(key, value)
    value = tonumber(value) or 0
    if key == 'gamedayspassed' then
        core.obscript.setGameDate('daysPassed', math.floor(value))
        core.obscript.setGameDate('hour', (value - math.floor(value)) * 24)
    else
        core.obscript.setGameDate(CLOCK[key], value)
    end
end

-- GLOB values: changed values live in obs._globals (shared with result
-- scripts, saved); unchanged ones come from the records.
local function globalValue(idOrEditorId)
    local record = dlg.getGlobal(idOrEditorId)
    if record == nil then return nil end
    local key = record.editorId:lower()
    if CLOCK[key] then return clockValue(key) end
    local value = rawget(obs._globals, key)
    if value ~= nil then return value end
    return record.value
end

-- Scripts read globals as bare names; make record values and the clock visible.
do
    local baseV = obs.v
    obs.v = function(name)
        local key = name:lower()
        if CLOCK[key] then return clockValue(key) end
        if obs._bindings[key] == nil and rawget(obs._globals, key) == nil then
            local record = dlg.getGlobal(name)
            if record then
                obs._globals[key] = record.value
            end
        end
        return baseV(name)
    end
    local baseSetV = obs.setv
    obs.setv = function(name, value)
        local key = name:lower()
        if CLOCK[key] then
            setClock(key, value)
            return
        end
        baseSetV(name, value)
    end
end

-- New game: the clock starts at the date FalloutNV.esm gives.
local function seedClock()
    for key in pairs(CLOCK) do
        local record = key ~= 'gamedayspassed' and dlg.getGlobal(key)
        if record then
            setClock(key, record.value)
        end
    end
end

-- ---------------------------------------------------------------- quests

local runScript -- forward
local setStage -- forward (quest host below)

-- ---------------------------------------------------------------- dialogue session

local session = nil -- { speaker, actor (from dlg.getActor), player, options, notices, pendingTopic }

local function notice(msg)
    log(msg)
    if session then
        session.notices[#session.notices + 1] = msg
    end
end

-- ---------------------------------------------------------------- conditions

local stats = core.obscript.stats

-- PlayerRef (0x14) is an engine form, not a record of FalloutNV.esm, so its
-- form id gets the master's load-order byte like any other and names no
-- object here; only its low 24 bits identify it.
local function isPlayerRefId(formIdText)
    local hex = type(formIdText) == 'string' and formIdText:match('0x(%x+)')
    return hex ~= nil and tonumber(hex, 16) % 0x1000000 == 0x14
end

local function objectForRunOn(cond, subject, target)
    if cond.runOn == 0 then return subject end
    if cond.runOn == 1 then return target end
    if cond.runOn == 2 and isPlayerRefId(cond.reference) then return world.players[1] end
    if cond.runOn == 2 and cond.reference ~= '' then
        local ok, obj = pcall(world.getObjectByFormId, cond.reference)
        if ok and obj and obj:isValid() then return obj end
    end
    if cond.runOn == 3 then -- the subject's combat target
        local c = I.FNVCombat
        return subject ~= nil and c and c.getTarget and c.getTarget(subject) or nil
    end
    if cond.runOn == 4 then -- the subject's linked reference
        local linked = subject ~= nil and core.obscript.getLinkedRef(subject)
        if not linked then return nil end
        local ok, obj = pcall(world.getObjectByFormId, linked)
        if ok and obj and obj:isValid() then return obj end
    end
    return nil
end

-- The form id of a placed reference; nil for objects created in game.
local function referenceId(obj)
    local ok, id = pcall(dlg.getReferenceId, obj)
    return ok and id or nil
end

local function isPlayer(obj)
    return obj ~= nil and types.Player.objectIsInstance(obj)
end

-- the low 24 bits of a form id; 0x14 is PlayerRef, 0x7 the Player base record
local function formIndex(raw)
    return (raw or 0) % 0x1000000
end

local function actorData(obj)
    if obj == nil or isPlayer(obj) then return nil end
    return dlg.getActor(obj)
end

local function playerIsFemale(obj)
    return obj ~= nil and stats.isFemale(obj)
end

local functions = {}

functions[72] = function(cond, obj) -- GetIsID
    if isPlayer(obj) then return formIndex(cond.param1) == 0x7 end
    local a = actorData(obj)
    if a == nil then -- talking activators (radio stations) and other objects
        return obj ~= nil and tostring(obj.recordId):lower() == tostring(cond.param1Form):lower()
    end
    return a.recordId == cond.param1Form
end
functions[136] = function(cond, obj) -- GetIsReference
    if isPlayer(obj) then return formIndex(cond.param1) == 0x14 end
    if formIndex(cond.param1) == 0x14 then return false end
    return obj ~= nil and referenceId(obj) == cond.param1Form
end
functions[58] = function(cond) -- GetStage
    local quest = getQuest(cond.param1Form)
    return quest and questState(quest).stage or 0
end
functions[59] = function(cond) -- GetStageDone
    local quest = getQuest(cond.param1Form)
    return quest ~= nil and questState(quest).done[cond.param2] == true
end
functions[56] = function(cond) -- GetQuestRunning
    local quest = getQuest(cond.param1Form)
    return quest ~= nil and questState(quest).running == true
end
functions[546] = function(cond) -- GetQuestCompleted
    local quest = getQuest(cond.param1Form)
    return quest ~= nil and questState(quest).completed == true
end
functions[420] = function(cond) -- GetObjectiveCompleted
    local quest = getQuest(cond.param1Form)
    return quest ~= nil and questState(quest).objectives[cond.param2] == 'completed'
end
functions[421] = function(cond) -- GetObjectiveDisplayed
    local quest = getQuest(cond.param1Form)
    local o = quest and questState(quest).objectives[cond.param2]
    return o == 'displayed' or o == 'completed'
end
functions[74] = function(cond) -- GetGlobalValue
    return globalValue(cond.param1Form) or 0
end
functions[79] = function(cond) -- GetQuestVariable
    local quest = getQuest(cond.param1Form)
    if quest == nil then return 0 end
    local name = quest.variables[cond.param2]
    if name == nil then return 0 end
    return obs.mv(quest.editorId, name)
end
functions[70] = function(cond, obj) -- GetIsSex (0 male, 1 female)
    if obj == nil or not stats.hasActorValues(obj) then return 0 end
    return ((stats.isFemale(obj) and 1 or 0) == cond.param1)
end
functions[131] = function(cond, _, _, target) -- GetPCIsSex
    return ((playerIsFemale(target) and 1 or 0) == cond.param1)
end
functions[69] = function(cond, obj) -- GetIsRace
    local a = actorData(obj)
    return a ~= nil and a.race == cond.param1Form
end
functions[68] = function(cond, obj) -- GetIsClass
    local a = actorData(obj)
    return a ~= nil and a.class == cond.param1Form
end
-- An NPC's rank in a faction: its record's ranks, changed by AddToFaction,
-- RemoveFromFaction and SetFactionRank; nil when not a member.
local function factionRank(a, factionId)
    if a == nil then return nil end
    local changes = state.factions[a.reference]
    local changed = changes and changes[factionId]
    if changed ~= nil then
        return changed or nil
    end
    return a.factions[factionId]
end
-- the player's own faction changes (AddToFaction on the player) are kept under 'player'
local function rankOf(obj, factionId)
    if isPlayer(obj) then
        local changed = state.factions.player and state.factions.player[factionId]
        return changed or nil
    end
    return factionRank(actorData(obj), factionId)
end
functions[71] = function(cond, obj) -- GetInFaction
    return rankOf(obj, cond.param1Form) ~= nil
end
functions[73] = function(cond, obj) -- GetFactionRank
    return rankOf(obj, cond.param1Form) or -1
end
functions[50] = function(_, obj) -- GetTalkedToPC
    if obj == nil or isPlayer(obj) then return 0 end
    return state.talkedTo[referenceId(obj)] == true
end
-- ESM4 actors in the active cells. world.activeActors leaves them out (their classes aren't
-- Morrowind actors), so they are collected as they become active.
local esm4Actors = {} -- id -> object
local function activeEsm4Actors()
    local list = {}
    local inScene = core.obscript.ai and core.obscript.ai.isInScene
    for id, obj in pairs(esm4Actors) do
        if not obj:isValid() or (inScene and not inScene(obj)) then
            esm4Actors[id] = nil
        else
            list[#list + 1] = obj
        end
    end
    return list
end

-- The same cell, or both outside in the same worldspace (exterior grid squares are cells of their own).
local function sameSpace(a, b)
    if a == nil or b == nil then return false end
    if a.id == b.id then return true end
    return a.isExterior and b.isExterior
end

local function isDead(obj)
    local c = I.FNVCombat
    if obj == nil or c == nil or c.isDead == nil then return false end
    local ok, dead = pcall(c.isDead, obj)
    return ok and dead == true
end
functions[46] = function(_, obj) return isDead(obj) end -- GetDead
local voiceTypeExplained = {} -- 'voice type|npc' -> true, logged once each
local function explainVoiceType(key)
    if voiceTypeExplained[key] then return false end
    voiceTypeExplained[key] = true
    return true
end
functions[427] = function(cond, obj) -- GetIsVoiceType: a voice type, or a form list of them
    if obj == nil or isPlayer(obj) then
        if explainVoiceType(cond.param1Form .. '|' .. tostring(cond.runOn)) then
            log(('GetIsVoiceType %s runs on %s (runOn %s, reference %s): false'):format(cond.param1Form,
                obj == nil and 'nothing' or 'the player', tostring(cond.runOn), tostring(cond.reference)))
        end
        return false
    end
    if dlg.isVoiceType then
        local yes = dlg.isVoiceType(obj, cond.param1Form)
        if not yes and dlg.describeVoiceType and explainVoiceType(cond.param1Form .. '|' .. tostring(obj.recordId)) then
            log(('GetIsVoiceType %s is false for %s: %s'):format(cond.param1Form, tostring(obj.recordId),
                dlg.describeVoiceType(obj, cond.param1Form)))
        end
        return yes
    end
    return dlg.getVoiceType(obj) == cond.param1Form
end
-- Variables of object scripts, as their local scripts publish them
-- (ObScriptLocals): reference form id -> { script = editor id, locals = {...} }.
local refVars = {}
local refVarSection = storage.globalSection('ObScriptRefVars')
refVarSection:setLifeTime(storage.LIFE_TIME.GameSession)

local scriptVarNames = {} -- script editor id -> { [index] = name }
local function scriptVariableName(scriptEditorId, index)
    local names = scriptVarNames[scriptEditorId]
    if names == nil then
        local record = dlg.getScript(scriptEditorId)
        names = record and dlg.getScriptVariables(record.id) or {}
        scriptVarNames[scriptEditorId] = names
    end
    return names[index]
end

functions[53] = function(cond) -- GetScriptVariable ref index
    local vars = refVars[cond.param1Form]
    if vars == nil then return 0 end
    local name = scriptVariableName(vars.script, cond.param2)
    return name and vars.locals[name:lower()] or 0
end

functions[226] = function() -- GetSandman: no Sandman perk kills
    return 0
end
functions[610] = function() -- GetCasinoWinningStage: no casino winnings yet
    return 0
end
functions[454] = function(cond, obj) -- GetPlayerTeammate
    return obj ~= nil and I.FNVAI and I.FNVAI.isTeammate and I.FNVAI.isTeammate(obj) and 1 or 0
end
functions[455] = function() -- GetPlayerTeammateCount
    return I.FNVAI and I.FNVAI.teammateCount and I.FNVAI.teammateCount() or 0
end

functions[462] = function(cond) -- IsPlayerTagSkill
    local av = stats.actorValue(cond.param1)
    if av == nil or stats.getTagSkills == nil then return false end
    for _, tagged in ipairs(stats.getTagSkills()) do
        if tagged == av then return true end
    end
    return false
end

functions[5] = function(_, obj) -- GetLocked
    local ok, locked = pcall(types.Lockable.isLocked, obj)
    return ok and locked == true
end
functions[32] = function(cond, obj) -- GetInSameCell
    local ok, other = pcall(world.getObjectByFormId, cond.param1Form)
    if formIndex(cond.param1) == 0x14 then ok, other = true, world.players[1] end
    return obj ~= nil and ok and other ~= nil and obj.cell ~= nil and other.cell ~= nil and obj.cell.id == other.cell.id
end
functions[289] = function(_, obj) -- IsInCombat
    local c = I.FNVCombat
    return obj ~= nil and c ~= nil and c.isInCombat ~= nil and c.isInCombat(obj) == true
end
local isSpeaking -- forward (spoken lines below)
functions[141] = function(_, obj) -- IsTalking
    return obj ~= nil and (isSpeaking(obj) or (session ~= nil and session.speaker == obj))
end
functions[64] = function(_, obj) -- GetIsCreature
    return obj ~= nil and types.ESM4Creature ~= nil and types.ESM4Creature.objectIsInstance(obj)
end

-- GetDeadCount: deaths of actors with this base record seen so far (see trackDeaths)
functions[84] = function(cond)
    return state.deadCounts and state.deadCounts[cond.param1Form] or 0
end
functions[35] = function(_, obj) return obj ~= nil and not obj.enabled end -- GetDisabled
functions[47] = function(cond, obj) -- GetItemCount
    if obj == nil or cond.param1Form == '' then return 0 end
    local ok, count = pcall(function() return types.Actor.inventory(obj):countOf(cond.param1Form) end)
    return ok and count or 0
end
local function actorValueFunction(fn)
    return function(cond, obj)
        if obj == nil or not stats.actorValue(cond.param1) then return 0 end
        return fn(obj, cond.param1)
    end
end
functions[14] = actorValueFunction(stats.get) -- GetActorValue
functions[277] = actorValueFunction(stats.getBase) -- GetBaseActorValue
functions[495] = actorValueFunction(stats.getPermanent) -- GetPermanentActorValue
functions[1] = function(cond, obj, subject, target) -- GetDistance
    local other
    if formIndex(cond.param1) == 0x14 then
        other = target
    elseif cond.param1Form ~= '' then
        local ok, o = pcall(world.getObjectByFormId, cond.param1Form)
        if ok then other = o end
    end
    if obj == nil or other == nil or not other:isValid() or obj.cell == nil or other.cell == nil
        or tostring(obj.cell.id) ~= tostring(other.cell.id) then
        return 999999
    end
    return (obj.position - other.position):length()
end
functions[67] = function(cond, obj) -- GetInCell
    return obj ~= nil and obj.cell ~= nil and tostring(obj.cell.id) == cond.param1Form
end
functions[300] = function(_, obj) return obj ~= nil and obj.cell ~= nil and not obj.cell.isExterior end -- IsInInterior
functions[18] = function() return (core.getGameTime() / 3600) % 24 end -- GetCurrentTime
functions[170] = function() return math.floor(core.getGameTime() / 86400) % 7 end -- GetDayOfWeek
functions[77] = function() return math.random(0, 99) end -- GetRandomPercent
functions[76] = function() return 50 end -- GetDisposition
functions[80] = function(_, obj) -- GetLevel
    if obj == nil then return 0 end
    return stats.getLevel(obj)
end
functions[431] = function() return 1 end -- GetHealthPercentage
functions[415] = function(_, obj) return obj ~= nil end -- Exists
functions[353] = function(_, obj) return obj ~= nil end -- IsActor
functions[254] = function() return 1 end -- GetIsPlayableRace
functions[524] = function() return 1 end -- IsWin32
-- Reputation, perks and karma (scripts/omw/fnvcharacter/global.lua)
local character = require('openmw_aux.obscript.character')
local characterRules = require('scripts.omw.fnvcharacter.rules')
local function characterState()
    return I.FNVCharacter and I.FNVCharacter.getState()
end
functions[573] = function(cond) -- GetReputation rep (1 fame, 0 infamy)
    return character.points(characterState(), character.reputation(cond.param1Form), cond.param2)
end
functions[574] = function(cond) -- GetReputationPct
    return character.percent(characterState(), character.reputation(cond.param1Form), cond.param2)
end
functions[575] = function(cond) -- GetReputationThreshold rep axis (0 mixed, 1 fame, 2 infamy)
    return character.threshold(characterState(), character.reputation(cond.param1Form), cond.param2)
end
functions[449] = function(cond, obj) -- HasPerk (only the player has perks)
    if not isPlayer(obj) then return 0 end
    return character.perkRank(characterState(), character.perk(cond.param1Form)) > 0
end
functions[474] = function(cond, obj) -- GetIsAlignment 0 good, 1 neutral, 2 evil, 3 very good, 4 very evil
    if obj == nil or not stats.hasActorValues(obj) then return 0 end
    return characterRules.alignmentOf(stats.get(obj, 'Karma'), character.gmst) == cond.param1
end
-- states the engine does not track for ESM4 actors yet: always "no"
for _, f in ipairs({ 36, 45, 49, 61, 63, 91, 98, 101, 125, 159, 182, 224, 242, 286, 309, 354, 365, 382, 435, 436,
    523, 586, 619 }) do
    functions[f] = function() return 0 end
end

local missingFunctions = {}

-- overrides: optional function index -> function(cond, subject) returning the value, for callers that know
-- better than the engine (the AI's idle picker answers GetSitting and GetFurnitureMarkerID itself).
local function makeContext(subject, target, overrides)
    return {
        call = function(cond)
            if overrides ~= nil and overrides[cond.func] ~= nil then
                local value = overrides[cond.func](cond, subject)
                if value ~= nil then return value end
            end
            local fn = functions[cond.func]
            if fn == nil then
                if not missingFunctions[cond.func] then
                    missingFunctions[cond.func] = true
                    log('condition function not implemented (treated as failing): ' .. conditions.name(cond.func))
                end
                return nil
            end
            return fn(cond, objectForRunOn(cond, subject, target), subject, target)
        end,
        global = function(id) return globalValue(id) end,
    }
end

-- ---------------------------------------------------------------- INFO selection

-- Only lines of running quests are eligible (and lines without a quest), and only
-- when the quest's own dialogue conditions pass too (WaterBeggars: GetIsID of the
-- beggar, so no one else begs for water).
local function questAllows(info, ctx)
    if info.quest == '' then return true end
    local quest = getQuest(info.quest)
    if quest == nil then return true end
    if questState(quest).running ~= true then return false end
    if ctx and quest.conditions and #quest.conditions > 0 then
        return (conditions.evaluate(quest.conditions, ctx))
    end
    return true
end

local function infoText(info)
    local lines = {}
    for _, r in ipairs(info.responses) do
        if r.text ~= '' then lines[#lines + 1] = r.text end
    end
    return table.concat(lines, '\n\n')
end

-- The first INFO of a topic whose quest is running and whose conditions pass
-- for this speaker and target; Random lines are picked among the passing ones.
local DAY = 24 * 3600

local function available(info)
    if state.saidOnce[info.id] then return false end
    if hasFlag(info.flags, INFO_SAY_ONCE_A_DAY) then
        local at = state.saidAt[info.id]
        if at and core.getGameTime() - at < DAY then return false end
    end
    return true
end

-- Random lines form a pool that ends at the line flagged Random End (or at
-- the first line that is not Random); one passing line of the pool is picked.
local function pickInfoFor(topic, speaker, actor, target)
    local ctx = makeContext(speaker, target)
    local infos = getTopicInfos(topic.id, actor.recordId)
    local randoms = nil
    for _, info in ipairs(infos) do
        local random = hasFlag(info.flags, INFO_RANDOM)
        if randoms and not random then
            break -- the pool ended without a Random End line
        end
        if questAllows(info, ctx) and available(info) then
            local passed, failed, value = conditions.evaluate(info.conditions, ctx)
            if passed then
                if not random then
                    return info
                end
                randoms = randoms or {}
                randoms[#randoms + 1] = info
            elseif trace then
                tlog(('  %s %s: fails %s'):format(topic.editorId, info.id, conditions.describe(failed, value)))
            end
        end
        if randoms and hasFlag(info.flags, INFO_RANDOM_END) then
            break
        end
    end
    if randoms then
        return randoms[math.random(1, #randoms)]
    end
    return nil
end

-- What saying a line changes: Say Once (a Day), and the topics it adds to
-- the player's known topics.
local function markSaid(info)
    if hasFlag(info.flags, INFO_SAY_ONCE) then
        state.saidOnce[info.id] = true
    end
    if hasFlag(info.flags, INFO_SAY_ONCE_A_DAY) then
        state.saidAt[info.id] = core.getGameTime()
    end
    for _, topicId in ipairs(info.addTopics) do
        state.knownTopics[topicId] = true
    end
end

local function pickInfo(topic)
    local s = session
    return pickInfoFor(topic, s.speaker, s.actor, s.player)
end

-- ---------------------------------------------------------------- result scripts

local scriptEnv = {
    require = function(name)
        if name == 'openmw_aux.obscript.runtime' then return obs end
        return require(name)
    end,
}

local compiledScripts = {} -- source -> handler function, or false if it does not compile

local function compileScript(source)
    local handler = compiledScripts[source]
    if handler ~= nil then return handler end
    handler = false
    local ok, luaSource = pcall(compiler.compile, source)
    if not ok then
        log('result script does not compile: ' .. tostring(luaSource) .. '\n' .. source)
    else
        -- the generated tail builds a local script; result scripts only need the statements
        luaSource = luaSource:gsub('return obs%.makeLocalScript%(%)%s*$', '')
        local loaded, chunk = pcall(util.loadCode, luaSource, scriptEnv)
        if not loaded then
            log('result script does not load: ' .. tostring(chunk))
        else
            local entry = obs._scripts['anonymous']
            if entry then entry.handlers['__stray'] = nil end
            local ran, err = pcall(chunk)
            entry = obs._scripts['anonymous']
            if not ran then
                log('result script failed to initialize: ' .. tostring(err))
            elseif entry and type(entry.handlers['__stray']) == 'function' then
                handler = entry.handlers['__stray']
                entry.handlers['__stray'] = nil
            end
        end
    end
    compiledScripts[source] = handler
    return handler
end

-- The object a result or stage script runs on when it names no reference
-- (`Disable`, `SayTo player X`); the speaker during dialogue otherwise.
local scriptSubject = nil

-- Result scripts get fresh locals for every run, as in the original (which
-- gives each run a temporary event list).
runScript = function(source, label, subject)
    if source == nil or source:match('^%s*$') then return end
    tlog('run result script (' .. label .. '):\n' .. source)
    local handler = compileScript(source)
    if not handler then return end
    -- stage scripts run from inside INFO scripts, so restore the outer state
    local prevCurrent, prevBlock, prevSubject = obs._current, obs._block, scriptSubject
    local entry = obs._scripts['anonymous']
    local S = entry.locals
    local saved = {}
    for k, v in pairs(S) do saved[k] = v end
    for k in pairs(saved) do S[k] = nil end
    obs._current = entry
    obs._block = 'result'
    scriptSubject = subject
    local ok, err = pcall(handler)
    for k in pairs(S) do S[k] = nil end
    for k, v in pairs(saved) do S[k] = v end
    obs._current, obs._block, scriptSubject = prevCurrent, prevBlock, prevSubject
    if not ok then
        log('result script error (' .. label .. '): ' .. tostring(err))
    end
end

-- ---------------------------------------------------------------- quest scripts
-- Each running quest with a script runs it on its own countdown: the quest's
-- delay (QUST DATA, SetQuestDelay), or fQuestScriptDelayTime (5 s) when that
-- is 0. Countdowns start staggered so that quest scripts don't all run in the
-- same frame. GetSecondsPassed is the time since the quest's previous run.
-- The quest's variables are its script's locals, reachable as Quest.var from
-- every script (object scripts through the storage section below).

local QUEST_SCRIPT_DELAY = 5.0 -- fQuestScriptDelayTime:MAIN

local questScripts = {} -- quest form id -> script entry, or false
local publishQuest -- forward

local function stripLocalScriptTail(luaSource)
    return (luaSource:gsub('return obs%.makeLocalScript%(%)%s*$', ''))
end

-- Compiles a quest's script and makes its entry reachable under the quest's
-- editor id too (Quest.var). Variables set before the script loaded (by
-- result scripts, or restored from a save) are kept.
local function loadQuestScript(quest)
    local cached = questScripts[quest.id]
    if cached ~= nil then return cached or nil end
    questScripts[quest.id] = false
    if quest.script == '' then return nil end
    local record = dlg.getScript(quest.script)
    if record == nil or record.source == '' then return nil end
    local ok, luaSource = pcall(compiler.compile, record.source)
    if not ok then
        log('quest script ' .. record.editorId .. ' does not compile: ' .. tostring(luaSource))
        return nil
    end
    local loaded, chunk = pcall(util.loadCode, stripLocalScriptTail(luaSource), scriptEnv)
    if not loaded then
        log('quest script ' .. record.editorId .. ' does not load: ' .. tostring(chunk))
        return nil
    end
    local prevCurrent = obs._current
    local ran, err = pcall(chunk)
    local entry = obs._current
    obs._current = prevCurrent
    if not ran or entry == nil then
        log('quest script ' .. record.editorId .. ' failed to initialize: ' .. tostring(err))
        return nil
    end
    local questKey = quest.editorId:lower()
    local earlier = obs._scripts[questKey]
    if earlier and earlier ~= entry then
        for k, v in pairs(earlier.locals) do
            if rawget(entry.locals, k) == nil then entry.locals[k] = v end
        end
    end
    obs._scripts[questKey] = entry
    entry.quest = quest
    questScripts[quest.id] = entry
    tlog('quest script ' .. record.editorId .. ' loaded for ' .. quest.editorId)
    return entry
end

-- Binary fractions 0, 1/2, 1/4, 3/4, 1/8, ... of the delay, for staggering.
local staggerIndex = 0
local function nextStagger()
    local n, f, x = staggerIndex, 0.5, 0
    staggerIndex = staggerIndex + 1
    while n > 0 do
        if n % 2 == 1 then x = x + f end
        n = math.floor(n / 2)
        f = f / 2
    end
    return x
end

local function questDelay(quest, s)
    local delay = s.delay or quest.delay or 0
    if delay <= 0 then delay = QUEST_SCRIPT_DELAY end
    return delay
end

local questScriptErrors = {}
local function runQuestScript(quest, entry, menuMode)
    local ok, err = pcall(obs.execute, entry, { menuMode = menuMode })
    if not ok and not questScriptErrors[quest.id] then
        questScriptErrors[quest.id] = true
        log('quest script of ' .. quest.editorId .. ' failed: ' .. tostring(err))
    end
    publishQuest(quest)
end

local function runningQuests()
    local list = {}
    for questId, s in pairs(state.quests) do
        if s.running then
            local quest = getQuest(questId)
            if quest then list[#list + 1] = { quest = quest, s = s } end
        end
    end
    -- a stable order, so that a frame's runs don't depend on table layout
    table.sort(list, function(a, b) return a.quest.id < b.quest.id end)
    return list
end

local function tickQuestScripts(dt)
    for _, q in ipairs(runningQuests()) do
        local entry = loadQuestScript(q.quest)
        if entry and q.s.running then
            local s = q.s
            if s.countdown == nil then
                s.countdown = questDelay(q.quest, s) * nextStagger()
            end
            s.elapsed = (s.elapsed or 0) + dt
            s.countdown = s.countdown - dt
            if s.countdown <= 0 then
                s.countdown = questDelay(q.quest, s)
                obs._dt = s.elapsed
                s.elapsed = 0
                runQuestScript(q.quest, entry, nil)
            end
        end
    end
end

-- One run of every running quest script that has MenuMode blocks, for a menu
-- that opened (menus the engine doesn't have yet are opened and closed at once).
local function runMenuMode(menuType)
    for _, q in ipairs(runningQuests()) do
        local entry = loadQuestScript(q.quest)
        if entry and obs.hasBlock(entry, 'menumode') then
            obs._dt = 0
            runQuestScript(q.quest, entry, menuType)
        end
    end
end

-- SetStage the original way: an undefined stage does nothing; the quest
-- keeps the highest stage reached; every log entry of the stage whose
-- conditions pass against the player runs once, applying its complete/fail
-- flags and its result script. A stage that is already done runs again only
-- for quests that allow repeated stages.
setStage = function(quest, stage)
    stage = math.floor(tonumber(stage) or 0)
    local stageRecord = nil
    for _, st in ipairs(quest.stages) do
        if st.index == stage then
            stageRecord = st
            break
        end
    end
    if stageRecord == nil then
        tlog('SetStage ' .. quest.editorId .. ' ' .. stage .. ': no such stage')
        return
    end
    local s = questState(quest)
    local again = s.done[stage] == true
    if not s.running and not s.completed then s.running = true end
    s.stage = math.max(s.stage or 0, stage)
    s.done[stage] = true
    tlog('SetStage ' .. quest.editorId .. ' ' .. stage .. (again and ' (again)' or ''))
    publishQuest(quest)
    if again and not quest.allowRepeatedStages then return end
    local player = world.players[1]
    local ctx = makeContext(player, player)
    for i, entry in ipairs(stageRecord.entries) do
        local passed, failed, value = conditions.evaluate(entry.conditions, ctx)
        if passed then
            if hasFlag(entry.flags, 0x01) then
                s.completed = true
                s.running = false
            end
            if hasFlag(entry.flags, 0x02) then
                s.failed = true
                s.running = false
            end
            if entry.log ~= '' then
                tlog('  log: ' .. entry.log)
            end
            runScript(entry.script, quest.editorId .. ' stage ' .. stage .. ' entry ' .. i, player)
        elseif trace then
            tlog(('  %s stage %d entry %d: fails %s'):format(quest.editorId, stage, i,
                conditions.describe(failed, value)))
        end
    end
    publishQuest(quest)
end

-- ------------------------------------------------ quest state for object scripts
-- Object scripts run in local contexts and can't call into this script, so
-- every quest's state and variables are mirrored into a global storage
-- section they can read (openmw_aux/obscript/bindings.lua); their quest
-- commands come back as ObScriptQuestCommand events.

local questSection = storage.globalSection('ObScriptQuests')
questSection:setLifeTime(storage.LIFE_TIME.GameSession)

local dirtyQuests = {}
publishQuest = function(quest)
    dirtyQuests[quest.id] = quest
end

local function questSnapshot(quest)
    local s = questState(quest)
    local vars = {}
    local entry = obs._scripts[quest.editorId:lower()]
    if entry then
        for k, v in pairs(entry.locals) do
            if type(v) == 'number' or type(v) == 'string' then vars[k] = v end
        end
    end
    local done = {}
    for stage in pairs(s.done) do done[stage] = true end
    local objectives = {}
    for index, o in pairs(s.objectives) do objectives[index] = o end
    return {
        stage = s.stage or 0, running = s.running == true, completed = s.completed == true,
        done = done, objectives = objectives, vars = vars,
    }
end

local function flushQuests()
    for id, quest in pairs(dirtyQuests) do
        questSection:set(quest.editorId:lower(), questSnapshot(quest))
        dirtyQuests[id] = nil
    end
end

local function publishAllQuests()
    for _, questId in ipairs(dlg.getAllQuests()) do
        local quest = getQuest(questId)
        if quest then publishQuest(quest) end
    end
    flushQuests()
end

-- ------------------------------------------------ spoken lines
-- An INFO is said response by response. A response with a voice file
-- (dlg.getVoiceFile) plays as 3D speech on the speaker and lasts as long as
-- the sound; without one it lasts as long as its subtitle (inferred:
-- fNoticeTextTimePerCharacter 0.06 s per character, at least 2 s, plus
-- fSubtitleSpeechDelay 0.15 s).
--
-- SayTo and friends: the speaker says the topic's first eligible line to the
-- target, with subtitles. The INFO's begin script runs when the line starts
-- and its end script when it finishes. In the dialogue window the same speech
-- plays without subtitles, and the window runs the end script itself.

local speaking = {} -- { speaker, info, responses, index, timeLeft, voiced, subtitles, onDone }

local VOICE_GRACE = 0.3 -- seconds before a started voice counts as finished when the sound isn't reported playing

local function lineDuration(text)
    return math.max(2.0, #text * 0.06) + 0.15
end

local function speakerName(speaker)
    local actor = dlg.getActor(speaker)
    if actor == nil then return '' end
    return actor.name ~= '' and actor.name or actor.editorId
end

-- Starts the next response of a line; false when there is none left.
local function nextResponse(line)
    line.index = line.index + 1
    local response = line.responses[line.index]
    if response == nil then return false end
    local text = response.text or ''
    local file = line.speaker:isValid() and dlg.getVoiceFile(line.info.id, line.speaker, response.number)
    line.voiced = false
    line.timeLeft = lineDuration(text)
    line.elapsed = 0
    if file then
        local ok, err = pcall(core.sound.say, file, line.speaker)
        if ok then
            line.voiced = true
        else
            tlog('voice ' .. file .. ' did not play: ' .. tostring(err))
        end
    end
    local ai = core.obscript.ai
    if ai and ai.setEmotion and line.speaker:isValid() and types.ESM4NPC.objectIsInstance(line.speaker) then
        ai.setEmotion(line.speaker, response.emotion or 0, response.emotionValue or 0)
        if line.voiced and ai.startLipSync then
            ai.startLipSync(line.speaker, file)
        end
    end
    if line.subtitles and text ~= '' then
        world.players[1]:sendEvent('FNVSubtitle', { speaker = speakerName(line.speaker), text = text })
    end
    return true
end

local function stopSpeech(line)
    if line.voiced and line.speaker:isValid() then
        pcall(core.sound.stopSay, line.speaker)
    end
end

-- The gesture an INFO asks the speaker to make with the line (SNAM, an IDLE or a
-- branch of the idle tree, e.g. Doc Mitchell's shrug), and the reaction it asks of
-- the one spoken to (LNAM, an NPC a SayTo is aimed at), played once over the stance.
local idleTree = nil
local function playLineIdle(actor, idleId, info)
    local ai = core.obscript.ai
    if not idleId or idleId == '' or not (ai and ai.playIdle) or not actor or not actor:isValid() then return end
    if not types.ESM4NPC.objectIsInstance(actor) and not types.ESM4Creature.objectIsInstance(actor) then return end
    idleTree = idleTree or require('scripts.omw.fnvai.idles')
    local idle = idleTree.get(idleId)
    if idle and not idleTree.isLeaf(idle) then idle = idleTree.pick(idle, actor) end
    if idle and idleTree.isLeaf(idle) then
        tlog(('%s plays %s with INFO %s'):format(tostring(actor.recordId), idle.editorId, info.id))
        ai.playIdle(actor, idleTree.modelPath(idle))
    end
end

local function startSpeech(speaker, info, subtitles, onDone)
    for _, line in ipairs(speaking) do
        if line.speaker == speaker then line.interrupted = true end
    end
    playLineIdle(speaker, info.speakerIdle, info)
    local responses = {}
    for _, r in ipairs(info.responses) do responses[#responses + 1] = r end
    table.sort(responses, function(a, b) return (a.number or 0) < (b.number or 0) end)
    local line = { speaker = speaker, info = info, responses = responses, index = 0,
        subtitles = subtitles, onDone = onDone }
    speaking[#speaking + 1] = line
    if not nextResponse(line) then
        line.timeLeft = 0
    end
    return line
end

-- `afterward(info)`, if given, runs once the line is over.
local function sayLine(speaker, target, topicIdOrEditorId, afterward)
    local actor = dlg.getActor(speaker)
    if actor == nil then
        tlog('SayTo: ' .. tostring(speaker) .. ' is not an NPC')
        return false
    end
    local topic = getTopic(topicIdOrEditorId)
    if topic == nil then
        log('SayTo: unknown topic ' .. tostring(topicIdOrEditorId))
        return false
    end
    -- Object scripts reach this a frame late, so a trigger's OnTriggerEnter and OnTrigger
    -- blocks can both ask for the line before either sees what it changed (VCG02SunnyBark);
    -- a SayTo of the topic the speaker is still saying is the same request.
    for _, line in ipairs(speaking) do
        if line.speaker == speaker and not line.interrupted and line.info.topic == topic.id then
            tlog(('SayTo: %s is already saying %s'):format(actor.editorId, topic.editorId))
            return false
        end
    end
    local info = pickInfoFor(topic, speaker, actor, target or world.players[1])
    if info == nil then
        tlog('SayTo: ' .. actor.editorId .. ' has no line for ' .. topic.editorId)
        return false
    end
    tlog(('SayTo: %s says %s INFO %s'):format(actor.editorId, topic.editorId, info.id))
    markSaid(info)
    local label = 'INFO ' .. info.id
    local endDone = false
    runScript(info.scriptBegin, label .. ' begin', speaker)
    if hasFlag(info.flags, INFO_RUN_IMMEDIATELY) then
        runScript(info.scriptEnd, label .. ' end', speaker)
        endDone = true
    end
    playLineIdle(target, info.listenerIdle, info)
    startSpeech(speaker, info, true, function()
        if not endDone then
            runScript(info.scriptEnd, label .. ' end', speaker)
        end
        -- `Begin SayToDone Topic` on the speaker's own script
        if speaker:isValid() then
            speaker:sendEvent('ObScriptEvent', { event = 'SayToDone', ref = topic.editorId })
        end
        if afterward then afterward(info) end
    end)
    return true
end

-- A conversation between two NPCs (StartConversation without the player):
-- they take turns, each answering with the first of the previous line's
-- choices (TCLT) that has a line for them, until a line has no choices or is
-- a Goodbye. The original also walks them to each other first (inferred: a
-- conversation package); here they talk where they stand.
local MAX_CONVERSATION_LINES = 100 -- the original stops a conversation after this many lines
local conversing = {} -- npc id -> true while in a conversation with another NPC

local function converse(speaker, listener, topicIdOrEditorId)
    local lines = 0
    local used = {}
    local function over()
        conversing[speaker.id] = nil
        conversing[listener.id] = nil
    end
    local function turn(a, b, topicId)
        lines = lines + 1
        return sayLine(a, b, topicId, function(info)
            if hasFlag(info.flags, INFO_GOODBYE) or lines >= MAX_CONVERSATION_LINES
                or not (a:isValid() and b:isValid()) then
                return over()
            end
            -- the next topic is a random one of the line's choices not used yet in this conversation
            local options = {}
            for _, choice in ipairs(info.choices) do
                if not used[choice] then options[#options + 1] = choice end
            end
            local actor = dlg.getActor(b)
            while #options > 0 and actor do
                local i = math.random(#options)
                local choice = options[i]
                table.remove(options, i)
                local topic = getTopic(choice)
                if topic and pickInfoFor(topic, b, actor, a) then
                    used[choice] = true
                    if not turn(b, a, choice) then over() end
                    return
                end
            end
            over()
        end)
    end
    local started = turn(speaker, listener, topicIdOrEditorId)
    -- no opening line: the original falls back to GOODBYE
    if not started and topicIdOrEditorId == 'HELLO' then started = turn(speaker, listener, 'GOODBYE') end
    if started then
        conversing[speaker.id] = true
        conversing[listener.id] = true
    end
    return started
end

local function lineOver(line, dt)
    if line.interrupted then return true end
    line.elapsed = line.elapsed + dt
    if line.voiced then
        if line.elapsed < VOICE_GRACE then return false end
        local ok, active = pcall(core.sound.isSayActive, line.speaker)
        if ok and active then return false end
    else
        line.timeLeft = line.timeLeft - dt
        if line.timeLeft > 0 then return false end
    end
    return not nextResponse(line)
end

local function tickSpeaking(dt)
    local finished = {}
    local still = {}
    for _, line in ipairs(speaking) do
        if lineOver(line, dt) then
            finished[#finished + 1] = line
        else
            still[#still + 1] = line
        end
    end
    speaking = still
    for _, line in ipairs(finished) do
        if line.interrupted then stopSpeech(line) end
        if line.onDone then line.onDone() end
    end
end

isSpeaking = function(obj)
    for _, line in ipairs(speaking) do
        if line.speaker == obj then return true end
    end
    return false
end

-- Ends a speaker's speech at once (the player left the dialogue window or moved on).
local function stopSpeaking(obj)
    local still = {}
    for _, line in ipairs(speaking) do
        if line.speaker == obj then
            stopSpeech(line)
        else
            still[#still + 1] = line
        end
    end
    speaking = still
end

-- ------------------------------------------------ greetings (Hello barks)
-- An NPC that is not busy says a HELLO line when the player comes within
-- fAIMinGreetingDistance, at most once per fAIGreetingTimer seconds, as
-- FalloutNV.exe does it: only if it has detected the player (scripts/omw/fnvcombat)
-- and the player is not sneaking.
local function gmst(name, fallback)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or fallback
end

local lastHello = {} -- npc id -> simulation time of its last greeting
local helloCheck = 0
local simTime = 0

-- Idle chatter (FalloutNV.exe 0x8eeec0): every NPC near the player says an IdleChatter line when its timer runs
-- out, then waits fIdleChatterCommentTimer..Max seconds (15 to 60) for the next one.
local IDLE_CHATTER_RANGE = 4096
local nextChatter = {} -- npc id -> simulation time

local function chatterDelay()
    local lo = gmst('fIdleChatterCommentTimer', 15)
    return lo + math.random() * math.max(gmst('fIdleChatterCommentTimerMax', 60) - lo, 0)
end

local chatterTries, chatterSaid, chatterReport = 0, 0, 60
local chatterExplained = 0
local questConditionsDumped = {}

-- Why a speaker has no line for a topic: how many of its INFOs a stopped quest, Say Once
-- or a condition holds back, with the first failing condition of a few of them.
local function explainNoLine(npc, topicEditorId)
    local actor = dlg.getActor(npc)
    local topic = getTopic(topicEditorId)
    if actor == nil or topic == nil then return end
    local ctx = makeContext(npc, world.players[1])
    local infos = getTopicInfos(topic.id, actor.recordId)
    local byQuest, bySaid, byCondition, shown = 0, 0, 0, 0
    local stopped = {}
    local questFails = {}
    for _, info in ipairs(infos) do
        if not questAllows(info, ctx) then
            byQuest = byQuest + 1
            stopped[info.quest] = true
            local quest = info.quest ~= '' and getQuest(info.quest)
            if quest and questFails[info.quest] == nil then
                local qs = questState(quest)
                local why = qs.running and 'running' or ('not running' .. (qs.completed and ', completed' or '')
                    .. (qs.failed and ', failed' or '') .. (qs.stopped and ', stopped' or '') .. ', stage ' .. tostring(qs.stage))
                if qs.running and quest.conditions and #quest.conditions > 0 then
                    local _, failed, value = conditions.evaluate(quest.conditions, ctx)
                    why = why .. ', its dialogue conditions fail: ' .. conditions.describe(failed, value)
                    if not questConditionsDumped[info.quest] then
                        questConditionsDumped[info.quest] = true
                        for i, cond in ipairs(quest.conditions) do
                            local ok, got = conditions.check(cond, ctx)
                            log(('    %s condition %d: %s%s runOn %s -> %s'):format(quest.editorId, i,
                                conditions.describe(cond, got), cond.isOr and ' OR' or '', tostring(cond.runOn),
                                ok and 'passes' or 'fails'))
                        end
                    end
                end
                questFails[info.quest] = why
                log(('  quest %s: %s'):format(quest.editorId, why))
            end
        elseif not available(info) then
            bySaid = bySaid + 1
        else
            local passed, failed, value = conditions.evaluate(info.conditions, ctx)
            if not passed then
                byCondition = byCondition + 1
                if shown < 4 then
                    shown = shown + 1
                    log(('  %s INFO %s fails %s'):format(topicEditorId, info.id, conditions.describe(failed, value)))
                end
            end
        end
    end
    local quests = {}
    for q in pairs(stopped) do
        local quest = getQuest(q)
        quests[#quests + 1] = (quest and quest.editorId or q) .. (isStartEnabled(q) and '[start-enabled]' or '')
        if #quests >= 6 then break end
    end
    log(('%s has no %s line: %d INFOs, %d held back by their quest (%s), %d said already, %d by conditions')
        :format(actor.editorId, topicEditorId, #infos, byQuest, table.concat(quests, ' '), bySaid, byCondition))
end
local function tickChatter(player)
    if getTopic('IdleChatter') == nil then
        if chatterReport ~= nil then
            log('no IdleChatter topic: idle chatter is off')
            chatterReport = nil
        end
        return
    end
    if chatterReport ~= nil and simTime >= chatterReport then
        if chatterTries > 0 then
            log(('idle chatter: %d NPCs had their turn, %d had a line'):format(chatterTries, chatterSaid))
        end
        chatterReport = simTime + 60
    end
    for _, npc in ipairs(activeEsm4Actors()) do
        if types.ESM4NPC.objectIsInstance(npc) and sameSpace(npc.cell, player.cell)
            and (npc.position - player.position):length() <= IDLE_CHATTER_RANGE then
            local due = nextChatter[npc.id]
            if due == nil then
                nextChatter[npc.id] = simTime + chatterDelay()
            elseif simTime >= due then
                nextChatter[npc.id] = simTime + chatterDelay()
                if not isSpeaking(npc) and not isDead(npc) and not conversing[npc.id]
                    and not (I.FNVCombat and I.FNVCombat.isInCombat and I.FNVCombat.isInCombat(npc)) then
                    chatterTries = chatterTries + 1
                    if sayLine(npc, nil, 'IdleChatter') then
                        chatterSaid = chatterSaid + 1
                        log(('%s (%s) says an IdleChatter line'):format(npc.recordId, tostring(npc.id)))
                    elseif chatterExplained < 3 then
                        chatterExplained = chatterExplained + 1
                        explainNoLine(npc, 'IdleChatter')
                    end
                end
            end
        end
    end
end

local function tickGreetings(dt)
    simTime = simTime + dt
    helloCheck = helloCheck - dt
    if helloCheck > 0 or session then return end
    helloCheck = 0.5
    local player = world.players[1]
    if player == nil then return end
    tickChatter(player)
    if core.obscript.combat and core.obscript.combat.isSneaking and core.obscript.combat.isSneaking(player) then
        return
    end
    local distance = gmst('fAIMinGreetingDistance', 150)
    local cooldown = gmst('fAIGreetingTimer', 20)
    for _, npc in ipairs(activeEsm4Actors()) do
        if types.ESM4NPC.objectIsInstance(npc) and sameSpace(npc.cell, player.cell)
            and (npc.position - player.position):length() <= distance
            and simTime - (lastHello[npc.id] or -cooldown) >= cooldown
            and not isSpeaking(npc) and not isDead(npc)
            and not (I.FNVCombat and I.FNVCombat.noticesPlayer and not I.FNVCombat.noticesPlayer(npc))
            and not (I.FNVCombat and I.FNVCombat.isInCombat and I.FNVCombat.isInCombat(npc)) then
            lastHello[npc.id] = simTime
            if sayLine(npc, player, 'HELLO') then
                log(('%s (%s) greets the player'):format(npc.recordId, tostring(npc.id)))
                return
            end
        end
    end
end

-- ------------------------------------------------ menus the engine doesn't have yet
-- Character creation menus (race, name, SPECIAL, tag skills, traits) are
-- player scripts that register here with the global event
-- `FNVRegisterMenu { name = <command> }` (or I.FNVDialogue.registerMenu). Opening
-- one sends it `FNVOpenMenu { name, menuType }`; when it closes it sends the
-- global event `FNVMenuClosed { menuType }`, and the quest scripts' MenuMode
-- blocks run once for it. A menu nobody registered closes at once.
local registeredMenus = {} -- lower-case command name -> true
local pendingMenus = {}
local function openStandInMenu(name, menuType, args)
    if registeredMenus[name:lower()] then
        local player = world.players[1]
        if player then
            player:sendEvent('FNVOpenMenu', { name = name, menuType = menuType, args = args or {} })
            return
        end
    end
    log('(not implemented yet: ' .. name .. ', closed at once)')
    pendingMenus[#pendingMenus + 1] = menuType
end

local function tickMenus()
    local menus = pendingMenus
    pendingMenus = {}
    for _, menuType in ipairs(menus) do
        runMenuMode(menuType)
    end
end

-- ------------------------------------------------ deaths, for GetDeadCount
local deathCheckTimer = 0
local function trackDeaths(dt)
    deathCheckTimer = deathCheckTimer - dt
    if deathCheckTimer > 0 then return end
    deathCheckTimer = 1
    state.deadRefs = state.deadRefs or {}
    state.deadCounts = state.deadCounts or {}
    for _, actor in ipairs(activeEsm4Actors()) do
        if types.ESM4NPC.objectIsInstance(actor) and isDead(actor) then
            local data = dlg.getActor(actor)
            if data and not state.deadRefs[data.reference] then
                state.deadRefs[data.reference] = true
                state.deadCounts[data.recordId] = (state.deadCounts[data.recordId] or 0) + 1
            end
        end
    end
end

initState = function()
    if state.initialized then return end
    state.initialized = true
    for _, questId in ipairs(dlg.getStartGameEnabledQuests()) do
        state.quests[questId] = state.quests[questId] or { running = true, stage = 0, done = {}, objectives = {} }
    end
    if isNewGame then
        seedClock()
        -- The intro cinematic (quest VCG00) ends with SetStage VCG01 0, which
        -- starts Doc Mitchell's scenes. The cinematic doesn't exist here, so a
        -- new game that starts in Doc Mitchell's house takes that step itself.
        local player = world.players[1]
        local docId = core.obscript.resolveRefEditorId('DocMitchellREF')
        local ok, doc = pcall(world.getObjectByFormId, docId or '')
        local vcg01 = getQuest('VCG01')
        if vcg01 and player and ok and doc and doc:isValid() and doc.cell and player.cell
            and doc.cell.id == player.cell.id then
            log("new game in Doc Mitchell's house: SetStage VCG01 0 (stands in for the intro cinematic)")
            -- VCG00 ends with `player.moveto VCG01PlayerStartMarkerREF`, next to Doc's bed
            local markerId = core.obscript.resolveRefEditorId('VCG01PlayerStartMarkerREF')
            local found, marker = pcall(world.getObjectByFormId, markerId or '')
            if found and marker and marker.cell then
                player:teleport(marker.cell, marker.position, { rotation = marker.rotation, onGround = true })
            end
            setStage(vcg01, 0)
        end
    end
    publishAllQuests()
end

-- ---------------------------------------------------------------- result script commands

local function questArg(q)
    local quest = getQuest(type(q) == 'string' and q or '')
    if quest == nil then
        notice('unknown quest: ' .. tostring(q))
    end
    return quest
end

local function resolveObject(ref)
    if type(ref) == 'string' then
        if ref:lower() == 'player' or ref:lower() == 'playerref' then return world.players[1] end
        local formId = core.obscript.resolveRefEditorId(ref)
        if formId then
            local ok, obj = pcall(world.getObjectByFormId, formId)
            if ok and obj and obj:isValid() then return obj end
        end
        return nil
    end
    return ref
end

-- The object a command acts on: the named reference, else the script's
-- subject (the speaker, or the object an object script asked for).
local function speakerOr(ref)
    if ref == nil then
        if scriptSubject then return scriptSubject end
        if session then return session.speaker end
        return nil
    end
    return resolveObject(ref)
end

-- Splits a binding's arguments into (reference, rest...) for commands that
-- work both as `Ref.Cmd a b` and `Cmd a b` (on the script's subject).
local function refAndArgs(...)
    if obs._callBase ~= nil then
        return speakerOr(select(1, ...)), select(2, ...)
    end
    return speakerOr(nil), ...
end

local function playerEvent(name, data)
    local player = world.players[1]
    if player then player:sendEvent(name, data) end
end

-- GetAV/SetAV/ModAV/GetLevel/GetIsSex... on the speaker or a named reference
require('openmw_aux.obscript.stats').install(obs, {
    subject = function() return speakerOr(nil) end,
    resolve = speakerOr,
    change = function(object, op, av, value) I.FNVStats.change(object, op, av, value) end,
})

-- RewardXP, RewardKarma, AddReputation, HasPerk... (scripts/omw/fnvcharacter/global.lua)
require('openmw_aux.obscript.character').install(obs, {
    subject = function() return speakerOr(nil) end,
    resolve = speakerOr,
    data = function() return I.FNVCharacter and I.FNVCharacter.getState() end,
    command = function(name, ...)
        if I.FNVCharacter then I.FNVCharacter.command(name, ...) end
    end,
})

obs.bind('SetStage', function(q, stage)
    local quest = questArg(q)
    if quest then setStage(quest, stage) end
    return 0
end)
obs.bind('GetStage', function(q)
    local quest = questArg(q)
    return quest and questState(quest).stage or 0
end)
obs.bind('GetStageDone', function(q, stage)
    local quest = questArg(q)
    return (quest and questState(quest).done[math.floor(tonumber(stage) or -1)]) and 1 or 0
end)
obs.bind('StartQuest', function(q)
    local quest = questArg(q)
    if quest then
        local s = questState(quest)
        s.running = true
        s.stopped = nil
        publishQuest(quest)
    end
    return 0
end)
obs.bind('StopQuest', function(q)
    local quest = questArg(q)
    if quest then
        local s = questState(quest)
        s.running = false
        s.stopped = true
        publishQuest(quest)
    end
    return 0
end)
obs.bind('CompleteQuest', function(q)
    local quest = questArg(q)
    if quest then
        local s = questState(quest)
        s.completed = true
        s.running = false
        publishQuest(quest)
    end
    return 0
end)
obs.bind('SetQuestDelay', function(q, delay)
    local quest = questArg(q)
    if quest then
        local s = questState(quest)
        s.delay = tonumber(delay) or 0
        s.countdown = math.min(s.countdown or 0, questDelay(quest, s))
    end
    return 0
end)
obs.bind('GetQuestRunning', function(q)
    local quest = questArg(q)
    return (quest and questState(quest).running) and 1 or 0
end)
obs.bind('GetQuestCompleted', function(q)
    local quest = questArg(q)
    return (quest and questState(quest).completed) and 1 or 0
end)

obs.bind('SetObjectiveDisplayed', function(q, index, flag)
    local quest = questArg(q)
    index = math.floor(tonumber(index) or 0)
    if quest and obs.b(flag or 1) then
        -- the HUD shows the new objective (scripts/omw/fnvhud/global.lua)
        local o = questState(quest).objectives
        if o[index] ~= 'completed' then o[index] = 'displayed' end
        publishQuest(quest)
    end
    return 0
end)
obs.bind('SetObjectiveCompleted', function(q, index, flag)
    local quest = questArg(q)
    index = math.floor(tonumber(index) or 0)
    if quest then
        questState(quest).objectives[index] = obs.b(flag or 1) and 'completed' or 'displayed'
        publishQuest(quest)
    end
    return 0
end)
obs.bind('GetObjectiveDisplayed', function(q, index)
    local quest = questArg(q)
    local o = quest and questState(quest).objectives[math.floor(tonumber(index) or 0)]
    return (o == 'displayed' or o == 'completed') and 1 or 0
end)
obs.bind('GetObjectiveCompleted', function(q, index)
    local quest = questArg(q)
    return (quest and questState(quest).objectives[math.floor(tonumber(index) or 0)] == 'completed') and 1 or 0
end)

-- Time since the running quest script's previous run (0 in result scripts).
obs.bind('GetSecondsPassed', function()
    return obs._dt or 0
end)

-- `player.AddItem Item count` / `AddItem Item count` (the speaker); only the
-- player's inventory is supported.
obs.bind('AddItem', function(a, b, c, d)
    local ref, item, count, hideMessage = nil, a, b, c
    if type(a) == 'string' and type(b) == 'string' then ref, item, count, hideMessage = a, b, c, d end
    local target = speakerOr(ref)
    if not isPlayer(target) then
        tlog('AddItem to a non-player is ignored: ' .. tostring(item))
        return 0
    end
    core.sendGlobalEvent('ObScriptAddItem', { item = item, count = count or 1,
        silent = hideMessage ~= nil and obs.b(hideMessage) })
    return 0
end)

obs.bind('RemoveItem', function(a, b, c)
    local ref, item, count = nil, a, b
    if type(a) == 'string' and type(b) == 'string' then ref, item, count = a, b, c end
    local target = speakerOr(ref)
    local recordId = type(item) == 'string' and core.obscript.resolveItemEditorId(item)
    if target == nil or not recordId then return 0 end
    pcall(function()
        local found = types.Actor.inventory(target):find(recordId)
        if found then found:remove(math.max(1, math.floor(tonumber(count) or 1))) end
    end)
    return 0
end)

-- `player.EquipItem Item`: the player readies an FNV weapon (scripts/omw/fnvcombat/player.lua). Worn items
-- (Pip-Boy, armor, clothing) have no ESM4 equipment slots for the player yet, so they stay in the inventory.
obs.bind('EquipItem', function(a, b)
    local ref, item = nil, a
    if type(a) == 'string' and type(b) == 'string' then ref, item = a, b end
    local target = speakerOr(ref)
    if not isPlayer(target) or type(item) ~= 'string' then
        tlog('EquipItem on a non-player is ignored: ' .. tostring(item))
        return 0
    end
    target:sendEvent('FNVEquipItem', { item = item })
    return 0
end)

obs.bind('ShowMessage', function(msgId, ...)
    if type(msgId) ~= 'string' then return 0 end
    local args = { ... }
    for i, v in ipairs(args) do
        if type(v) == 'userdata' then args[i] = tostring(v) end
    end
    playerEvent('ObScriptShowMessage', { editorId = msgId, args = args })
    return 0
end)

-- The button the player pressed in the last ShowMessage box, once; -1 until then.
obs.bind('GetButtonPressed', function()
    return core.obscript.getButtonPressed()
end)

local function setEnabled(ref, enabled)
    local obj = speakerOr(ref)
    if obj then
        obj.enabled = enabled
    else
        notice((enabled and 'Enable' or 'Disable') .. ': unknown reference ' .. tostring(ref))
    end
    return 0
end
obs.bind('Enable', function(ref) return setEnabled(ref, true) end)
obs.bind('Disable', function(ref) return setEnabled(ref, false) end)
obs.bind('GetDisabled', function(ref)
    local obj = speakerOr(ref)
    return (obj ~= nil and not obj.enabled) and 1 or 0
end)
obs.bind('GetDead', function(ref)
    return isDead(speakerOr(ref)) and 1 or 0
end)

-- `Ref.SayTo target Topic` / `SayTo target Topic`; `Ref.Say Topic`.
obs.bind('SayTo', function(...)
    local speaker, target, topic = refAndArgs(...)
    if speaker == nil or type(topic) ~= 'string' then return 0 end
    sayLine(speaker, resolveObject(target), topic)
    return 0
end)
obs.bind('Say', function(...)
    local speaker, topic = refAndArgs(...)
    if speaker == nil or type(topic) ~= 'string' then return 0 end
    sayLine(speaker, world.players[1], topic)
    return 0
end)
obs.bind('IsTalking', function(...)
    local obj = refAndArgs(...)
    return isSpeaking(obj) and 1 or 0
end)

local startDialogue -- forward (screens below)

-- `Ref.StartConversation player Topic`: inside a conversation, continue with
-- that topic; otherwise, when the player is the target, open dialogue on it.
-- NPC-to-NPC conversations are not done yet.
obs.bind('StartConversation', function(...)
    local speaker, target, topic = refAndArgs(...)
    if type(topic) ~= 'string' then topic = nil end
    if session then
        if topic then session.pendingTopic = topic end
        return 0
    end
    local targetObj = resolveObject(target)
    if speaker and isPlayer(targetObj) then
        startDialogue(speaker, targetObj, topic)
    elseif speaker and targetObj and topic then
        converse(speaker, targetObj, topic)
    end
    return 0
end)

-- `Ref.ForceGreet`: the NPC opens dialogue with the player (its greeting).
obs.bind('ForceGreet', function(...)
    local speaker = refAndArgs(...)
    local player = world.players[1]
    if speaker and player and not session then
        startDialogue(speaker, player, nil)
    end
    return 0
end)

obs.bind('GetIsID', function(a, b)
    local ref, id = nil, a
    if b ~= nil then ref, id = a, b end
    local obj = speakerOr(ref)
    local data = actorData(obj)
    return (data and type(id) == 'string' and data.editorId:lower() == id:lower()) and 1 or 0
end)

obs.bind('GetLinkedRef', function(...)
    local obj = refAndArgs(...)
    local linked = obj and core.obscript.getLinkedRef(obj)
    return linked and resolveObject(linked) or 0
end)

-- EvaluatePackage and ResetAI: the AI picks the NPC's package again.
local function evaluatePackage(...)
    local obj = refAndArgs(...)
    if obj and I.FNVAI and I.FNVAI.evaluate then I.FNVAI.evaluate(obj) end
    return 0
end
obs.bind('EvaluatePackage', evaluatePackage)
obs.bind('EVP', evaluatePackage)
obs.bind('ResetAI', evaluatePackage)

-- DisablePlayerControls / EnablePlayerControls movement pipboy fighting pov
-- looking rollover sneaking. Without arguments every control is meant; with
-- some, the missing ones are left alone (inferred).
local CONTROLS = { 'movement', 'pipboy', 'fighting', 'pov', 'looking', 'rollover', 'sneaking' }
local function playerControls(enable, ...)
    local args = { ... }
    local flags = {}
    for i, name in ipairs(CONTROLS) do
        if #args == 0 then
            flags[name] = true
        else
            flags[name] = obs.b(args[i] or 0)
        end
    end
    playerEvent('ObScriptPlayerControls', { enable = enable, flags = flags })
    return 0
end
obs.bind('DisablePlayerControls', function(...) return playerControls(false, ...) end)
obs.bind('EnablePlayerControls', function(...) return playerControls(true, ...) end)

-- Character creation menus: stand-ins (see openStandInMenu). 1036 is the
-- race menu, as VCG01SCRIPT's `MenuMode 1036` block shows.
obs.bind('ShowRaceMenu', function(...) openStandInMenu('ShowRaceMenu', 1036, { ... }) return 0 end)
-- Menu types from FalloutNV.exe's menu table (0x9ff970).
local CHARGEN_MENUS = {
    GetPlayerName = 1051, ShowNameMenu = 1051, -- TextEditMenu
    ShowLoveTesterMenu = 1074, ShowLoveTesterMenuParams = 1074, -- the Vigor Tester (SPECIAL)
    ShowSPECIALBookMenu = 1060, ShowSPECIALBookMenuParams = 1060,
    SetTagSkills = 1048, ShowTagSkillMenu = 1048, -- CharGenMenu
    ShowTraitMenu = 1084, ShowTraitSelectMenu = 1076,
}
for name, menuType in pairs(CHARGEN_MENUS) do
    obs.bind(name, function(...) openStandInMenu(name, menuType, { ... }) return 0 end)
end

-- Presentation commands with no effect on script flow; logged once each.
local quietStubs = {}
for _, name in ipairs({ 'ApplyImageSpaceModifier',
    'RemoveImageSpaceModifier', 'SetDestroyed', 'PlayIdle', 'AutoDisplayObjectives', 'AutoSave',
    'AddAchievement', 'Look', 'StopLook', 'SetScreenSplatterFade', 'PlaySound', 'PlaySound3D' }) do
    obs.bind(name, function()
        if not quietStubs[name] then
            quietStubs[name] = true
            log('(not implemented yet, ignored: ' .. name .. ')')
        end
        return 0
    end)
end

-- Ref.var in quest and result scripts: object script variables come from the
-- published copies, and sets go to the object's own script.
obs._remoteVar = function(base, name)
    if obs._scripts[base:lower()] then return nil end -- a quest
    local key = core.obscript.resolveRefEditorId(base)
    local vars = key and refVars[key]
    if vars == nil then return nil end
    return vars.locals[name:lower()] or 0
end
local function setRefVar(key, name, value)
    local ok, obj = pcall(world.getObjectByFormId, key)
    if not ok or obj == nil or not obj:isValid() then return false end
    obj:sendEvent('ObScriptSetVar', { name = name, value = value })
    local vars = refVars[key]
    if vars then vars.locals[name:lower()] = value end
    return true
end
obs._remoteSet = function(base, name, value)
    if obs._scripts[base:lower()] then return false end
    local key = core.obscript.resolveRefEditorId(base)
    return key ~= nil and setRefVar(key, name, value)
end

-- `AddTopic Topic`: the player knows the topic from now on.
obs.bind('AddTopic', function(topicId)
    local topic = type(topicId) == 'string' and getTopic(topicId)
    if topic then
        state.knownTopics[topic.id] = true
    else
        tlog('AddTopic: unknown topic ' .. tostring(topicId))
    end
    return 0
end)

-- `Ref.MoveTo Target [x y z]` (and MoveToMarker, MoveToMarkerWithFade, whose
-- fade is not done): puts the reference at the target, offset in world units.
local function moveTo(...)
    local obj, target, x, y, z = refAndArgs(...)
    local dest = resolveObject(target)
    if obj == nil or dest == nil or dest.cell == nil then
        tlog('MoveTo: unknown reference or target ' .. tostring(target))
        return 0
    end
    local offset = util.vector3(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
    local ok, err = pcall(function()
        obj:teleport(dest.cell, dest.position + offset, { rotation = dest.rotation })
    end)
    if not ok then tlog('MoveTo failed: ' .. tostring(err)) end
    return 0
end
obs.bind('MoveTo', moveTo)
obs.bind('MoveToMarker', moveTo)
obs.bind('MoveToMarkerWithFade', moveTo)

-- ---------------------------------------------------- more commands, by how often FNV uses them

local function combatApi(name)
    return I.FNVCombat and I.FNVCombat[name]
end

-- `Ref.StartCombat Target` / `StopCombat`
obs.bind('StartCombat', function(...)
    local actor, target = refAndArgs(...)
    local start = combatApi('startCombat')
    target = resolveObject(target) or world.players[1]
    if actor and target and start then start(actor, target) end
    return 0
end)
obs.bind('StopCombat', function(...)
    local actor = refAndArgs(...)
    local stop = combatApi('stopCombat')
    if actor and stop then stop(actor) end
    return 0
end)
obs.bind('IsInCombat', function(...)
    local actor = refAndArgs(...)
    local check = combatApi('isInCombat')
    return (actor and check and check(actor)) and 1 or 0
end)
obs.bind('GetCombatTarget', function(...)
    local actor = refAndArgs(...)
    local get = combatApi('getTarget')
    return actor and get and get(actor) or 0
end)
-- `Ref.KillActor [Killer] [DismemberLimb] [CauseOfDeath]`: a limb comes off (bursts if the cause is 0,
-- an explosion) through scripts/omw/fnvgore.
obs.bind('KillActor', function(...)
    local actor, _, limb, cause = refAndArgs(...)
    local kill = combatApi('kill')
    if actor and kill and not isDead(actor) then kill(actor) end
    limb = tonumber(limb)
    if actor and limb and limb >= 0 and I.FNVGore then
        I.FNVGore.dismember(actor, limb, tonumber(cause) == 0)
    end
    return 0
end)
-- `Ref.IsLimbGone Limb`
obs.bind('IsLimbGone', function(...)
    local actor, limb = refAndArgs(...)
    limb = tonumber(limb)
    if actor == nil or limb == nil or I.FNVGore == nil then return 0 end
    return I.FNVGore.isLimbGone(actor, limb) and 1 or 0
end)

-- The player's packages in the opening: lying in Doc Mitchell's bed (wake up, sit up), sitting on its
-- edge, standing up. activationhandlers.lua puts the player there (FNVPlayerPose).
local PLAYER_POSES = {
    vcg01playersection0 = 'lying',
    vcg01playersection1 = 'sitting',
    vcg01playersection2 = 'standing',
}

-- `Ref.AddScriptPackage Package` / `Ref.RemoveScriptPackage`
-- `ref.SetPlayerTeammate 1`: the actor joins the player's team (scripts/omw/fnvai): it follows the
-- player through doors unless its Waiting variable is 1, and fights the player's enemies.
obs.bind('SetPlayerTeammate', function(...)
    local npc, flag = refAndArgs(...)
    if npc and not isPlayer(npc) and I.FNVAI and I.FNVAI.setTeammate then
        I.FNVAI.setTeammate(npc, (tonumber(flag) or 0) ~= 0)
    end
    return 0
end)
obs.bind('GetPlayerTeammate', function(...)
    local npc = refAndArgs(...)
    return npc and I.FNVAI and I.FNVAI.isTeammate and I.FNVAI.isTeammate(npc) and 1 or 0
end)

obs.bind('AddScriptPackage', function(...)
    local npc, package = refAndArgs(...)
    local pose = isPlayer(npc) and type(package) == 'string' and PLAYER_POSES[package:lower()]
    if pose then
        core.sendGlobalEvent('FNVPlayerPose',
            { pose = pose, marker = resolveObject('VCG01PlayerStartMarkerREF') })
        return 0
    end
    local packageId = type(package) == 'string' and core.obscript.resolvePackageEditorId(package)
    if npc and packageId and types.ESM4NPC.objectIsInstance(npc) and I.FNVAI and I.FNVAI.setScriptPackage then
        I.FNVAI.setScriptPackage(npc, packageId)
    end
    return 0
end)
obs.bind('RemoveScriptPackage', function(...)
    local npc = refAndArgs(...)
    if npc and types.ESM4NPC.objectIsInstance(npc) and I.FNVAI and I.FNVAI.setScriptPackage then
        I.FNVAI.setScriptPackage(npc, nil)
    end
    return 0
end)

-- `Ref.AddToFaction Faction rank`, `Ref.RemoveFromFaction Faction`,
-- `Ref.SetFactionRank Faction rank` (-1 removes), `GetInFaction`, `GetFactionRank`.
local function setFactionRank(npc, faction, rank)
    local a = actorData(npc)
    if a == nil and isPlayer(npc) then a = { reference = 'player' } end -- the player's factions (crime, trespass)
    local factionId = type(faction) == 'string' and core.obscript.resolveFactionEditorId(faction)
    if a == nil or not factionId then
        tlog('faction change: unknown NPC or faction ' .. tostring(faction))
        return
    end
    local changes = state.factions[a.reference] or {}
    state.factions[a.reference] = changes
    if rank == nil or rank < 0 then
        changes[factionId] = false
    else
        changes[factionId] = math.floor(rank)
    end
end
obs.bind('AddToFaction', function(...)
    local npc, faction, rank = refAndArgs(...)
    setFactionRank(npc, faction, tonumber(rank) or 0)
    return 0
end)
obs.bind('RemoveFromFaction', function(...)
    local npc, faction = refAndArgs(...)
    setFactionRank(npc, faction, nil)
    return 0
end)
obs.bind('SetFactionRank', function(...)
    local npc, faction, rank = refAndArgs(...)
    setFactionRank(npc, faction, tonumber(rank) or -1)
    return 0
end)
obs.bind('GetInFaction', function(...)
    local npc, faction = refAndArgs(...)
    local a = actorData(npc)
    local factionId = type(faction) == 'string' and core.obscript.resolveFactionEditorId(faction)
    return (a and factionId and factionRank(a, factionId) ~= nil) and 1 or 0
end)
obs.bind('GetFactionRank', function(...)
    local npc, faction = refAndArgs(...)
    local a = actorData(npc)
    local factionId = type(faction) == 'string' and core.obscript.resolveFactionEditorId(faction)
    return (a and factionId and factionRank(a, factionId)) or -1
end)

-- `Ref.Lock [level]` / `Ref.Unlock`
obs.bind('Lock', function(...)
    local obj, level = refAndArgs(...)
    if obj then pcall(types.Lockable.lock, obj, math.floor(tonumber(level) or 0)) end
    return 0
end)
obs.bind('Unlock', function(...)
    local obj = refAndArgs(...)
    if obj then pcall(types.Lockable.unlock, obj) end
    return 0
end)
obs.bind('GetLocked', function(...)
    local obj = refAndArgs(...)
    local ok, locked = pcall(types.Lockable.isLocked, obj)
    return (ok and locked) and 1 or 0
end)

-- MarkForDelete and RemoveMe: the reference goes away (at once here; the
-- original waits until it is unloaded).
local function removeRef(...)
    local obj = refAndArgs(...)
    if obj and obj:isValid() and not isPlayer(obj) then
        pcall(function() obj:remove() end)
    end
    return 0
end
obs.bind('MarkForDelete', removeRef)
obs.bind('RemoveMe', removeRef)

-- `Ref.PlaceAtMe Base [count]`: new objects at the reference; returns the last one.
obs.bind('PlaceAtMe', function(...)
    local anchor, base, count = refAndArgs(...)
    local recordId = type(base) == 'string' and core.obscript.resolveBaseEditorId(base)
    if anchor == nil or not recordId or anchor.cell == nil then
        tlog('PlaceAtMe: unknown object ' .. tostring(base))
        return 0
    end
    local placed = 0
    for _ = 1, math.max(1, math.floor(tonumber(count) or 1)) do
        local ok, obj = pcall(world.createObject, recordId, 1)
        if ok and obj then
            obj:teleport(anchor.cell, anchor.position, { rotation = anchor.rotation })
            placed = obj
        end
    end
    return placed
end)

-- `Ref.GetItemCount Item`
obs.bind('GetItemCount', function(...)
    local obj, item = refAndArgs(...)
    local recordId = type(item) == 'string' and core.obscript.resolveItemEditorId(item)
    if obj == nil or not recordId then return 0 end
    local ok, count = pcall(function()
        local inventory = types.Actor.objectIsInstance(obj) and types.Actor.inventory(obj)
            or types.Container.inventory(obj)
        return inventory:countOf(recordId)
    end)
    return ok and count or 0
end)

obs.bind('GetRandomPercent', function() return math.random(0, 99) end)

-- `Ref.IsCurrentFurnitureRef Furniture`: whether the actor sits on it
-- (players only so far: NPCs don't use furniture yet).
local furnitureSection = storage.globalSection('ESM4CurrentFurniture')
obs.bind('IsCurrentFurnitureRef', function(...)
    local actor, furniture = refAndArgs(...)
    local current = actor and furnitureSection:get(tostring(actor.id))
    local wanted = type(furniture) == 'string' and core.obscript.resolveRefEditorId(furniture)
    return (current and wanted and current == wanted) and 1 or 0
end)
obs.bind('GetCurrentTime', function() return clockValue('gamehour') end)

-- `Ref.GetSelf`: the reference the script runs on.
obs.bind('GetSelf', function(...)
    local obj = refAndArgs(...)
    return obj or 0
end)

-- `Ref.GetIsReference Other`
obs.bind('GetIsReference', function(...)
    local obj, other = refAndArgs(...)
    other = resolveObject(other)
    return (obj ~= nil and other ~= nil and obj == other) and 1 or 0
end)

-- `Ref.GetDistance Other`: distance in the same cell, else very far.
obs.bind('GetDistance', function(...)
    local obj, other = refAndArgs(...)
    other = resolveObject(other)
    if obj == nil or other == nil or obj.cell == nil or other.cell == nil or obj.cell.id ~= other.cell.id then
        return 999999
    end
    return (obj.position - other.position):length()
end)
obs.bind('GetInSameCell', function(...)
    local obj, other = refAndArgs(...)
    other = resolveObject(other)
    return (obj ~= nil and other ~= nil and obj.cell ~= nil and other.cell ~= nil and obj.cell.id == other.cell.id) and 1 or 0
end)

obs.bind('player', function() return 'player' end)

-- `ShowBarterMenu` (a vendor's "Show me what you have for sale"): the trade window
-- opens over the conversation with the speaker's merchant container
-- (scripts/omw/fnvbarter); leaving it returns to the conversation, as in the original.
obs.bind('ShowBarterMenu', function(ref)
    local merchant = speakerOr(ref)
    if merchant == nil then return 0 end
    core.sendGlobalEvent('FNVBarterOpen', { merchant = merchant })
    return 0
end)

-- `OpenTeammateContainer` (every companion's FollowersTrade line, the companion wheel's Open Inventory): the
-- companion's inventory in the container menu (scripts/omw/fnvmenus)
obs.bind('OpenTeammateContainer', function(ref)
    local mate = speakerOr(ref)
    if mate == nil or not mate:isValid() then return 0 end
    world.players[1]:sendEvent('FNVOpenTeammateContainer', { container = mate })
    return 0
end)

-- `player.ShowRecipeMenu CampfireRecipes` (campfires, workbenches): the crafting window
-- for that recipe category (scripts/omw/fnvcrafting).
obs.bind('ShowRecipeMenu', function(...)
    local category
    for _, arg in ipairs({ ... }) do
        if type(arg) == 'string' and arg:lower() ~= 'player' then category = arg end
    end
    if category == nil then return 0 end
    core.sendGlobalEvent('FNVRecipeOpen', { category = category })
    return 0
end)

-- Menus the intro and many conversations open; not implemented yet. The
-- dialogue window reports them so the play-tester sees what was skipped.
for _, name in ipairs({ 'ShowBarterMenu', 'ShowRepairMenu', 'ShowRecipeMenu', 'ShowCompanionWheel',
    'RewardXP', 'RewardKarma', 'AddPerk', 'ModPCSkill', 'SetEssential', 'SetPlayerTeammate',
    'PlayGroup', 'StartCombat', 'StopCombat', 'SetEnemy', 'SetAlly' }) do
    if obs._bindings[name:lower()] == nil then
        local reported = false
        obs.bind(name, function()
            -- in a conversation every call is shown; otherwise logged once
            if session or not reported then
                reported = true
                notice('(not implemented yet: ' .. name .. ')')
            end
            return 0
        end)
    end
end

-- ---------------------------------------------------------------- screens

local function topicOption(topicId)
    local topic = getTopic(topicId)
    if topic == nil then return nil end
    local info = pickInfo(topic)
    if info == nil then return nil end
    local text = info.prompt ~= '' and info.prompt or topic.name
    -- designer notes in braces ({Evil 2+}...) are never shown
    text = text:gsub('%b{}', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then text = topic.editorId end
    return { topic = topic, info = info, text = text }
end

local function buildOptions(info)
    local options = {}
    if info and hasFlag(info.flags, INFO_GOODBYE) then
        return options
    end
    if info and #info.choices > 0 then
        for _, choiceId in ipairs(info.choices) do
            local option = topicOption(choiceId)
            if option then options[#options + 1] = option end
        end
        if #options > 0 then return options end
    end
    -- the player's known topics: every top-level topic, plus those added by
    -- AddTopic and by lines said; ordered by priority, then name
    local topics = {}
    local seen = {}
    for _, topicId in ipairs(getSpeakerTopics(session.actor.recordId)) do
        local topic = getTopic(topicId)
        if topic then
            topics[#topics + 1] = topic
            seen[topic.id] = true
        end
    end
    for topicId in pairs(state.knownTopics) do
        local topic = getTopic(topicId)
        if topic and not seen[topic.id] and topic.type == 0 then
            topics[#topics + 1] = topic
            seen[topic.id] = true
        end
    end
    table.sort(topics, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.name < b.name
    end)
    for _, topic in ipairs(topics) do
        if topic.editorId:upper() ~= 'GREETING' then
            local option = topicOption(topic.id)
            if option then options[#options + 1] = option end
        end
    end
    return options
end

local function sendScreen(text)
    local s = session
    local list = {}
    for i, o in ipairs(s.options) do list[i] = o.text end
    s.player:sendEvent('FNVDialogueShow', {
        speaker = s.actor.name ~= '' and s.actor.name or s.actor.editorId,
        text = text,
        options = list,
        notices = s.notices,
        -- a Goodbye line with nothing to answer closes by itself once said (the game is
        -- paused in the window, so the player script times it)
        autoClose = (s.goodbye and not s.continuing and #list == 0 and text ~= '') and lineDuration(text) or nil,
        -- a line with a follow-up goes on by itself once said (FNVDialogueContinue)
        autoContinue = s.continuing and lineDuration(text) or nil,
        speakerObject = s.speaker,
    })
    s.notices = {}
end

-- In the dialogue window an INFO's end script runs when its line is over,
-- which (without voice) is when the player moves on: picks an answer or
-- leaves. A topic the end script starts (StartConversation) is said next.
local function finishLine(keepSpeech)
    local s = session
    local info = s and s.saying
    if info == nil then return end
    s.saying = nil
    if not keepSpeech then stopSpeaking(s.speaker) end
    runScript(info.scriptEnd, 'INFO ' .. info.id .. ' end', s.speaker)
end

local function say(info, topic)
    local s = session
    tlog(('%s: INFO %s (quest %s)'):format(topic and topic.editorId or '?', info.id, info.quest))
    markSaid(info)
    s.pendingTopic = nil
    runScript(info.scriptBegin, 'INFO ' .. info.id .. ' begin', s.speaker)
    if session == nil then return end -- a script ended the conversation
    s.saying = info
    s.lastInfo = info
    stopSpeaking(s.speaker)
    startSpeech(s.speaker, info, false, nil)
    if hasFlag(info.flags, INFO_RUN_IMMEDIATELY) then
        finishLine(true)
        if session == nil then return end
    end
    s.goodbye = hasFlag(info.flags, INFO_GOODBYE)
    -- with follow-ups the answers come after the last of them (continueLine); a line whose
    -- end script opens a menu (ShowBarterMenu after "Can do.") runs it once said, as the
    -- original does, instead of waiting for the player to answer
    s.continuing = #(info.followUps or {}) > 0
        or (info.scriptEnd ~= nil and info.scriptEnd:lower():find('show%a*menu') ~= nil)
    s.options = s.continuing and {} or buildOptions(info)
    sendScreen(infoText(info))
end

-- Follow-up INFOs (TCFU): once a line is over the speaker goes on with the
-- first of them that may be said, before the player answers. Inferred from
-- FalloutNV.esm: Doc Mitchell's farewell chains GREETING 001057E8 -> 001057E4
-- -> 001057E5 (female) / 001057E6 (male), and only the last ones have choices.
local function pickFollowUp(info)
    local s = session
    local ctx = makeContext(s.speaker, s.player)
    for _, id in ipairs(info.followUps or {}) do
        local follow = dlg.getInfo(id)
        if follow and questAllows(follow, ctx) and available(follow) and (conditions.evaluate(follow.conditions, ctx)) then
            return follow
        end
    end
    return nil
end

local moveOn

local function continueLine()
    local s = session
    if s == nil or not s.continuing then return end
    s.continuing = false
    local info = s.saying or s.lastInfo
    if moveOn() or session == nil then return end
    local follow = info and pickFollowUp(info)
    if follow then
        say(follow, getTopic(follow.topic))
        return
    end
    s.options = buildOptions(info)
    sendScreen(info and infoText(info) or '')
end

-- Ends the current line; true when its end script started another topic,
-- which is then said instead of whatever the player picked.
moveOn = function()
    finishLine()
    local s = session
    if s == nil then return true end
    if s.pendingTopic then
        local option = topicOption(s.pendingTopic)
        s.pendingTopic = nil
        if option then
            say(option.info, option.topic)
            return true
        end
    end
    return false
end

-- The one spoken to stops what it was doing, turns to the player (unless seated)
-- and keeps its eyes on them until the conversation is over.
local function engage(speaker, player)
    local ai = core.obscript.ai
    if not (ai and ai.lookAt) or not speaker:isValid() then return end
    if types.ESM4NPC.objectIsInstance(speaker) or types.ESM4Creature.objectIsInstance(speaker) then
        if ai.useStatus(speaker) == 'none' then
            if ai.status(speaker) == 'moving' then ai.stop(speaker) end
            local d = player.position - speaker.position
            ai.face(speaker, math.atan2(d.x, d.y))
        end
        ai.lookAt(speaker, player)
    end
end

local function disengage(speaker)
    local ai = core.obscript.ai
    if ai and ai.lookAt and speaker and speaker:isValid() then ai.lookAt(speaker, nil) end
end

local function endDialogue()
    if session == nil then return end
    finishLine()
    if session == nil then return end
    session.player:sendEvent('FNVDialogueClose')
    disengage(session.speaker)
    session = nil
end

startDialogue = function(speaker, player, topicIdOrEditorId)
    local actor = dlg.getActor(speaker)
    if actor == nil then return false end
    initState()
    if session then
        finishLine()
        if session and session.speaker ~= speaker then disengage(session.speaker) end
    end
    session = { speaker = speaker, actor = actor, player = player, options = {}, notices = {} }
    engage(speaker, player)
    tlog('start dialogue with ' .. actor.editorId .. ' (' .. actor.recordId .. ')')
    local topic = getTopic(topicIdOrEditorId or 'GREETING')
    local info = topic and pickInfo(topic)
    state.talkedTo[actor.reference] = true
    if info then
        say(info, topic)
    else
        log('no greeting for ' .. actor.editorId)
        session.options = buildOptions(nil)
        sendScreen('')
    end
    return true
end

-- ---------------------------------------------------------------- activation

I.Activation.addHandlerForType(types.ESM4NPC, function(npc, actor)
    -- a dead NPC is looted: the engine opens it as a container (MWClass::ESM4Npc::activate)
    if isDead(npc) then return end
    if types.Player.objectIsInstance(actor) then
        -- sneaking up to an NPC opens its pockets instead (ghidra-findings-12; teammates got the wheel before this)
        local sneaking = core.obscript.combat and core.obscript.combat.isSneaking
            and core.obscript.combat.isSneaking(actor)
        if sneaking and I.FNVCrime and I.FNVCrime.canPickpocket then
            local ok, message = I.FNVCrime.canPickpocket(actor, npc)
            if ok then
                actor:sendEvent('FNVOpenPickpocket', { target = npc })
                return false
            elseif message ~= nil then
                actor:sendEvent('FNVHudNotify', { text = message })
                return false
            end
        end
        startDialogue(npc, actor)
        return false
    end
end)

-- ---------------------------------------------------------------- object script requests
-- Quest commands of object scripts (see openmw_aux/obscript/bindings.lua).
-- `self` is the object whose script asked; `member` says whether the command
-- was called as `Ref.Cmd`, so that refAndArgs splits the arguments the same way.
local forwardedCommands = {
    setstage = true, startquest = true, stopquest = true, completequest = true, setquestdelay = true,
    setobjectivedisplayed = true, setobjectivecompleted = true,
    sayto = true, say = true, startconversation = true, forcegreet = true, evaluatepackage = true, evp = true, resetai = true,
    disableplayercontrols = true, enableplayercontrols = true,
    addscriptpackage = true, removescriptpackage = true, addtofaction = true, removefromfaction = true,
    setfactionrank = true, startcombat = true, stopcombat = true, killactor = true, lock = true, unlock = true,
    markfordelete = true, removeme = true, placeatme = true, moveto = true, movetomarker = true,
    movetomarkerwithfade = true, addtopic = true, showmessage = true,
    showracemenu = true, getplayername = true, shownamemenu = true, showspecialmenu = true,
    showtagskillmenu = true, settagskills = true, showtraitmenu = true, showtraitselectmenu = true,
    showlovetestermenu = true, showlovetestermenuparams = true, showspecialbookmenu = true,
    showspecialbookmenuparams = true, showrecipemenu = true, showbartermenu = true,
    -- scripts/omw/fnvradio/global.lua
    setbroadcaststate = true, startradioconversation = true, settalkingactivatoractor = true, playmusic = true,
}

local function runForwardedCommand(data)
    local name = tostring(data.name):lower()
    local fn = obs._bindings[name]
    if fn == nil or not forwardedCommands[name] then
        log('object script command not handled here: ' .. tostring(data.name))
        return
    end
    initState()
    local prevSubject, prevBase = scriptSubject, obs._callBase
    scriptSubject = data.self
    obs._callBase = data.member and data.args[1] or nil
    local ok, err = pcall(fn, table.unpack(data.args, 1, data.n or #data.args))
    scriptSubject, obs._callBase = prevSubject, prevBase
    if not ok then log('object script command ' .. name .. ' failed: ' .. tostring(err)) end
end

local function setQuestVar(data)
    local quest = getQuest(tostring(data.quest))
    if quest == nil then return end
    loadQuestScript(quest)
    obs.msetv(quest.editorId, data.name, data.value)
    publishQuest(quest)
end

-- ---------------------------------------------------------------- effect scripts
-- Scripts of Script effects (SCPT type 0x100), run by scripts/omw/fnveffects
-- for every active effect instance, each with its own locals:
-- ScriptEffectStart on the first run, ScriptEffectUpdate every frame and
-- ScriptEffectFinish at the end. Commands without a reference act on the
-- actor the effect is on.

local effectScripts = {} -- SCPT form id or editor id -> script entry, or false

local function loadEffectScript(scriptId)
    local cached = effectScripts[scriptId]
    if cached ~= nil then return cached or nil end
    effectScripts[scriptId] = false
    local record = dlg.getScript(scriptId)
    if record == nil or record.source == '' then return nil end
    local ok, luaSource = pcall(compiler.compile, record.source)
    if not ok then
        log('effect script ' .. record.editorId .. ' does not compile: ' .. tostring(luaSource))
        return nil
    end
    local loaded, chunk = pcall(util.loadCode, stripLocalScriptTail(luaSource), scriptEnv)
    if not loaded then
        log('effect script ' .. record.editorId .. ' does not load: ' .. tostring(chunk))
        return nil
    end
    local prevCurrent = obs._current
    local ran, err = pcall(chunk)
    local entry = obs._current
    obs._current = prevCurrent
    if not ran or entry == nil then
        log('effect script ' .. record.editorId .. ' failed to initialize: ' .. tostring(err))
        return nil
    end
    -- the shared entry only holds the blocks; each instance brings its locals
    entry.effect = true
    for k in pairs(entry.locals) do entry.locals[k] = nil end
    effectScripts[scriptId] = entry
    tlog('effect script ' .. record.editorId .. ' loaded')
    return entry
end

local effectScriptErrors = {}

-- One run of an effect script with an instance's locals (updated in place).
local function runEffectScript(scriptId, subject, locals, events, dt)
    initState()
    local entry = loadEffectScript(scriptId)
    if entry == nil then return false end
    local S = entry.locals
    local outer = {}
    for k, v in pairs(S) do outer[k] = v end
    for k in pairs(outer) do S[k] = nil end
    for k, v in pairs(locals) do S[k] = v end
    local prevSubject, prevDt = scriptSubject, obs._dt
    scriptSubject = subject
    obs._dt = dt or 0
    local ok, err = pcall(obs.execute, entry, { events = events })
    scriptSubject, obs._dt = prevSubject, prevDt
    local result = {}
    for k, v in pairs(S) do result[k] = v end
    for k in pairs(locals) do locals[k] = nil end
    for k, v in pairs(result) do
        locals[k] = v
        S[k] = nil
    end
    for k, v in pairs(outer) do S[k] = v end
    if not ok and not effectScriptErrors[scriptId] then
        effectScriptErrors[scriptId] = true
        log('effect script ' .. tostring(entry.name) .. ' failed: ' .. tostring(err))
    end
    return true
end

-- ---------------------------------------------------------------- save/load

local function saveScriptVars()
    local vars = {}
    local seen = {}
    for _, entry in pairs(obs._scripts) do
        -- quest scripts are reachable under two names; save each once
        if entry.name ~= 'anonymous' and not seen[entry] then
            seen[entry] = true
            local locals = {}
            for k, v in pairs(entry.locals) do
                if type(v) == 'number' or type(v) == 'string' then locals[k] = v end
            end
            vars[entry.name:lower()] = locals
        end
    end
    return vars
end

local function loadScriptVars(vars)
    for name, locals in pairs(vars or {}) do
        local S = obs.locals(name)
        for k, v in pairs(locals) do S[k] = v end
    end
    obs._current = nil
end

return {
    interfaceName = 'FNVDialogue',
    interface = {
        version = 0,
        --- Open dialogue with the nearest ESM4 NPC in the player's cell whose
        -- editor id or name matches (case-insensitive); for testing.
        talkTo = function(name, topic)
            local player = world.players[1]
            name = (name or ''):lower()
            for _, obj in ipairs(player.cell:getAll()) do
                local a = types.ESM4NPC.objectIsInstance(obj) and dlg.getActor(obj)
                if a and (name == '' or a.editorId:lower() == name or a.name:lower() == name) then
                    return startDialogue(obj, player, topic)
                end
            end
            log('no ESM4 NPC named "' .. name .. '" in ' .. tostring(player.cell))
            return false
        end,
        --- Quest state for debugging: stage, running, completed.
        getQuestState = function(q)
            local quest = getQuest(q)
            return quest and questState(quest)
        end,
        setStage = function(q, stage)
            local quest = getQuest(q)
            if quest then setStage(quest, stage) end
        end,
        --- A conversation between two NPCs (sandbox conversations, scripts/omw/fnvai): the speaker opens with
        -- the topic (HELLO by default) and they take turns until a Goodbye line or 100 lines.
        -- @return whether the speaker had a line
        converseWith = function(speaker, listener, topic)
            if conversing[speaker.id] or conversing[listener.id] or isSpeaking(speaker) or isSpeaking(listener) then
                return false
            end
            return converse(speaker, listener, topic or 'HELLO')
        end,
        isConversing = function(npc)
            return conversing[npc.id] == true
        end,
        --- Opens dialogue with `npc` as activating it would (the companion wheel's Talk To).
        startDialogue = function(npc, player)
            return startDialogue(npc, player or world.players[1])
        end,
        --- The companion wheel's "says topic X" (ghidra-findings-11, FUN_007573d0 / FUN_007575b0): the
        -- companion's first matching line of the topic is voiced and both its result scripts run at once.
        -- @return the line's text for the wheel's subtitle, nil if it has no line
        wheelSay = function(npc, topicIdOrEditorId)
            local actor = dlg.getActor(npc)
            local topic = getTopic(topicIdOrEditorId)
            if actor == nil or topic == nil then return nil end
            local info = pickInfoFor(topic, npc, actor, world.players[1])
            if info == nil then
                tlog(('wheel: %s has no line for %s'):format(actor.editorId, topic.editorId))
                return nil
            end
            tlog(('wheel: %s says %s INFO %s'):format(actor.editorId, topic.editorId, info.id))
            markSaid(info)
            local label = 'INFO ' .. info.id .. ' (companion wheel)'
            runScript(info.scriptBegin, label .. ' begin', npc)
            runScript(info.scriptEnd, label .. ' end', npc)
            local line = startSpeech(npc, info, false, nil)
            local first = line.responses[1]
            -- without the {emotion} and <action> notes the subtitles leave out
            local text = first and first.text or ''
            text = text:gsub('%b{}', ''):gsub('%b<>', ''):gsub('%s%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
            return text
        end,
        --- Sets an object script variable on `obj` and in the copy dialogue conditions read
        -- (GetScriptVariable), which its script only republishes a frame later.
        setScriptVariable = function(obj, name, value)
            local ok, key = pcall(dlg.getReferenceId, obj)
            if ok and key then setRefVar(key, name, value) else obj:sendEvent('ObScriptSetVar', { name = name, value = value }) end
        end,
        --- Declares that a player script shows the menu a command opens
        -- (`ShowRaceMenu`, `GetPlayerName`, `ShowSPECIALMenu`, `SetTagSkills`,
        -- `ShowTraitMenu`, ...); see openStandInMenu.
        registerMenu = function(commandName)
            registeredMenus[commandName:lower()] = true
        end,
        --- A quest variable (Quest.var) for debugging.
        getQuestVar = function(q, name)
            local quest = getQuest(q)
            return quest and obs.mv(quest.editorId, name)
        end,
        --- Evaluates a CTDA list (as built by core.obscript) with subject as
        -- the running object and the player as target; used by AI packages.
        -- overrides: optional function index -> function(cond, subject) answering
        -- in place of the engine (nil falls through).
        -- @return passed, failed condition, its value
        checkConditions = function(list, subject, overrides)
            initState()
            return conditions.evaluate(list, makeContext(subject, world.players[1], overrides))
        end,
        --- Runs an effect script (SCPT type 0x100, by form id or editor id) once
        -- on `subject` with `locals` (a table owned by the caller, updated in
        -- place) and pending `events`, e.g. { scripteffectstart = { { ref = caster } } }.
        -- @return false if the script does not exist or does not compile
        runEffectScript = runEffectScript,
        --- Installs an ObScript command for quest, result and effect scripts:
        -- fn(object, ...) gets the named reference of `Ref.Cmd a b`, or the
        -- running script's subject for `Cmd a b`, followed by the arguments.
        bindCommand = function(name, fn)
            obs.bind(name, function(...) return fn(refAndArgs(...)) end)
        end,
        --- Runs a result script (ObScript source, e.g. an AI package's OnEnd) once
        -- with `subject` as the object it runs on; label names it in the log.
        runResultScript = function(source, label, subject)
            initState()
            runScript(source, label, subject)
        end,
        --- The INFO a speaker would say for a topic (form id or editor id), as
        -- dialogue picks it: quest running, conditions passing with `speaker` as
        -- subject and the player as target, Random pools. speakerRecordId leaves
        -- out INFOs meant for others (GetIsID); radio stations pass their TACT.
        -- @return the INFO table (core.obscript.dialogue.getInfo shape) or nil
        pickInfo = function(topic, speaker, speakerRecordId)
            initState()
            local t = getTopic(topic)
            if t == nil then return nil end
            return pickInfoFor(t, speaker, { recordId = speakerRecordId or '' }, world.players[1])
        end,
        --- Records that an INFO picked with pickInfo was said (Say Once, add topics).
        markSaid = function(info)
            initState()
            markSaid(info)
        end,
        --- Marks a Say Once INFO (form id, e.g. FormId:0x210558f) as said, as if the
        -- conversation that says it had happened; for tests that jump ahead in a quest.
        markInfoSaid = function(infoId)
            initState()
            state.saidOnce[infoId] = true
        end,
        --- Opens dialogue between the NPC and the player (Dialogue AI packages);
        -- topic: form id or editor id, nil for the greeting. False when a
        -- conversation is already going on.
        startConversation = function(speaker, topic)
            if session ~= nil then return false end
            local player = world.players[1]
            if player == nil then return false end
            return startDialogue(speaker, player, topic) == true
        end,
        --- Whether the player is in a conversation with the NPC.
        isTalkingTo = function(speaker)
            return session ~= nil and session.speaker == speaker
        end,
        --- Installs a CTDA condition function: fn(cond, object, subject, target)
        -- returns the function's value (object is the one the condition runs on).
        --- The rank of an actor (the player too) in a faction (form id), nil when it is not a member.
        factionRank = rankOf,
        --- A global's value (form id or editor id), with script changes; nil if there is no such global.
        globalValue = function(id) return globalValue(id) end,
        --- Has the NPC say a line of the first of the topics (editor ids) that exists, to the target (default the
        -- player), as SayTo does. @return whether it had a line
        say = function(npc, topics, target)
            if type(topics) == 'string' then topics = { topics } end
            for _, topic in ipairs(topics) do
                if getTopic(topic) ~= nil then
                    return sayLine(npc, target, topic)
                end
            end
            return false
        end,
        setConditionFunction = function(index, fn)
            functions[index] = fn
            missingFunctions[index] = nil
        end,
    },
    eventHandlers = {
        FNVDialogueChoose = function(data)
            local s = session
            if s == nil then return end
            if s.continuing then -- answering while a follow-up is due skips ahead to it
                continueLine()
                return
            end
            local option = s.options[data.index]
            if moveOn() then return end
            if option == nil then
                endDialogue()
                return
            end
            say(option.info, option.topic)
        end,
        FNVDialogueContinue = continueLine,
        FNVDialogueClose = function()
            if session then finishLine() end
            if session then disengage(session.speaker) end
            session = nil
        end,
        ObScriptQuestCommand = runForwardedCommand,
        -- Terminal entries (scripts/omw/esm4terminal.lua): which entries of a
        -- terminal page show (their conditions run on the terminal, with the
        -- player as target), and running an entry's result script.
        FNVTerminalCheck = function(data)
            initState()
            local ok, rec = pcall(types.ESM4Terminal.record, data.record)
            if not ok or rec == nil or data.player == nil then return end
            local ctx = makeContext(data.terminal, data.player)
            local visible = {}
            for i, item in ipairs(rec.items) do
                visible[i] = (#item.conditions == 0) or (conditions.evaluate(item.conditions, ctx)) == true
            end
            data.player:sendEvent('FNVTerminalChecked', { record = data.record, visible = visible })
        end,
        FNVTerminalRun = function(data)
            initState()
            local ok, rec = pcall(types.ESM4Terminal.record, data.record)
            local item = ok and rec and rec.items[data.index]
            if item and item.script ~= '' then
                runScript(item.script, 'TERM ' .. tostring(rec.editorId) .. ' entry ' .. data.index, data.terminal)
            end
        end,
        FNVRegisterMenu = function(data)
            registeredMenus[tostring(data.name):lower()] = true
        end,
        FNVMenuClosed = function(data)
            pendingMenus[#pendingMenus + 1] = data.menuType
        end,
        ObScriptLocals = function(data)
            if data.object == nil or not data.object:isValid() then return end
            local key = referenceId(data.object)
            if key == nil then return end
            refVars[key] = { script = data.script, locals = data.locals }
            refVarSection:set(key, data.locals)
        end,
        ObScriptSetRefVar = function(data)
            setRefVar(data.ref, data.name, data.value)
        end,
        ObScriptSetQuestVar = setQuestVar,
    },
    engineHandlers = {
        onNewGame = function()
            isNewGame = true
        end,
        onObjectActive = function(obj)
            if types.ESM4NPC.objectIsInstance(obj) or types.ESM4Creature.objectIsInstance(obj) then
                esm4Actors[obj.id] = obj
            end
        end,
        onUpdate = function(dt)
            if not state.initialized then initState() end
            tickMenus()
            tickQuestScripts(dt)
            tickSpeaking(dt)
            tickGreetings(dt)
            trackDeaths(dt)
            flushQuests()
        end,
        onSave = function()
            local globals = {}
            for k, v in pairs(obs._globals) do globals[k] = v end
            return { state = state, globals = globals, vars = saveScriptVars() }
        end,
        onLoad = function(data)
            if data == nil then return end
            state = data.state or state
            state.initialized = true
            state.saidAt = state.saidAt or {}
            state.knownTopics = state.knownTopics or {}
            state.factions = state.factions or {}
            for k, v in pairs(data.globals or {}) do obs._globals[k] = v end
            loadScriptVars(data.vars)
            -- Saves from before questState knew start-game-enabled quests can hold them as
            -- stopped without anything having stopped them (GenericIdleChatter): those that
            -- never advanced and were never stopped run again.
            for id, s in pairs(state.quests) do
                if not s.running and not s.completed and not s.failed and not s.stopped
                    and (s.stage or 0) == 0 and next(s.done or {}) == nil and isStartEnabled(id) then
                    s.running = true
                end
            end
            publishAllQuests()
        end,
    },
}
