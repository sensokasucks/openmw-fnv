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

local function questState(quest)
    local s = state.quests[quest.id]
    if s == nil then
        s = { running = false, stage = 0, done = {}, objectives = {} }
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

local function objectForRunOn(cond, subject, target)
    if cond.runOn == 0 then return subject end
    if cond.runOn == 1 then return target end
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
    return a ~= nil and a.recordId == cond.param1Form
end
functions[136] = function(cond, obj) -- GetIsReference
    if isPlayer(obj) then return formIndex(cond.param1) == 0x14 end
    if formIndex(cond.param1) == 0x14 then return false end
    return obj ~= nil and dlg.getReferenceId(obj) == cond.param1Form
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
functions[71] = function(cond, obj) -- GetInFaction (only the first faction is loaded)
    local a = actorData(obj)
    return a ~= nil and a.faction == cond.param1Form
end
functions[73] = function(cond, obj) -- GetFactionRank
    local a = actorData(obj)
    if a ~= nil and a.faction == cond.param1Form then return a.factionRank end
    return -1
end
functions[50] = function(_, obj) -- GetTalkedToPC
    if obj == nil or isPlayer(obj) then return 0 end
    return state.talkedTo[dlg.getReferenceId(obj)] == true
end
local function isDead(obj)
    local c = I.FNVCombat
    if obj == nil or c == nil or c.isDead == nil then return false end
    local ok, dead = pcall(c.isDead, obj)
    return ok and dead == true
end
functions[46] = function(_, obj) return isDead(obj) end -- GetDead
functions[427] = function(cond, obj) -- GetIsVoiceType (the race's default voice is not loaded yet)
    if obj == nil or isPlayer(obj) then return false end
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
-- states the engine does not track for ESM4 actors yet: always "no"
for _, f in ipairs({ 36, 45, 49, 61, 63, 64, 91, 98, 101, 125, 141, 159, 182, 224, 242, 286, 289, 309, 354,
    365, 382, 435, 436, 449, 454, 455, 462, 523, 573, 574, 575, 586, 619 }) do
    functions[f] = function() return 0 end
end

local missingFunctions = {}

local function makeContext(subject, target)
    return {
        call = function(cond)
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

-- Only lines of running quests are eligible (and lines without a quest).
local function questAllows(info)
    if info.quest == '' then return true end
    local quest = getQuest(info.quest)
    if quest == nil then return true end
    return questState(quest).running == true
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
        if questAllows(info) and available(info) then
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

-- ------------------------------------------------ lines spoken outside the dialogue window
-- SayTo and friends: the speaker says the topic's first eligible line to the
-- target. The INFO's begin script runs when the line starts and its end
-- script when it finishes. Voice files are not played yet, so a line lasts as
-- long as its subtitle (inferred: fNoticeTextTimePerCharacter 0.06 s per
-- character, at least 2 s, plus fSubtitleSpeechDelay 0.15 s).

local speaking = {} -- { speaker, info, label, timeLeft }

local function lineDuration(text)
    return math.max(2.0, #text * 0.06) + 0.15
end

local function sayLine(speaker, target, topicIdOrEditorId)
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
    local info = pickInfoFor(topic, speaker, actor, target or world.players[1])
    if info == nil then
        tlog('SayTo: ' .. actor.editorId .. ' has no line for ' .. topic.editorId)
        return false
    end
    tlog(('SayTo: %s says %s INFO %s'):format(actor.editorId, topic.editorId, info.id))
    markSaid(info)
    for _, line in ipairs(speaking) do
        if line.speaker == speaker then line.interrupted = true end
    end
    local text = infoText(info)
    local line = { speaker = speaker, info = info, topic = topic.editorId, label = 'INFO ' .. info.id,
        timeLeft = lineDuration(text) }
    speaking[#speaking + 1] = line
    runScript(info.scriptBegin, line.label .. ' begin', speaker)
    if hasFlag(info.flags, INFO_RUN_IMMEDIATELY) then
        runScript(info.scriptEnd, line.label .. ' end', speaker)
        line.endDone = true
    end
    if text ~= '' then
        world.players[1]:sendEvent('FNVSubtitle', {
            speaker = actor.name ~= '' and actor.name or actor.editorId,
            text = text,
            duration = line.timeLeft,
        })
    end
    return true
end

local function tickSpeaking(dt)
    local finished = {}
    local still = {}
    for _, line in ipairs(speaking) do
        line.timeLeft = line.timeLeft - dt
        if line.timeLeft <= 0 or line.interrupted then
            finished[#finished + 1] = line
        else
            still[#still + 1] = line
        end
    end
    speaking = still
    for _, line in ipairs(finished) do
        if not line.endDone then
            runScript(line.info.scriptEnd, line.label .. ' end', line.speaker)
        end
        -- `Begin SayToDone Topic` on the speaker's own script
        if line.speaker:isValid() then
            line.speaker:sendEvent('ObScriptEvent', { event = 'SayToDone', ref = line.topic })
        end
    end
end

local function isSpeaking(obj)
    for _, line in ipairs(speaking) do
        if line.speaker == obj then return true end
    end
    return false
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
local function openStandInMenu(name, menuType)
    if registeredMenus[name:lower()] then
        local player = world.players[1]
        if player then
            player:sendEvent('FNVOpenMenu', { name = name, menuType = menuType })
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
    for _, actor in ipairs(world.activeActors) do
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
        questState(quest).running = true
        publishQuest(quest)
    end
    return 0
end)
obs.bind('StopQuest', function(q)
    local quest = questArg(q)
    if quest then
        questState(quest).running = false
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

local function objectiveText(quest, index)
    for _, o in ipairs(quest.objectives) do
        if o.index == index then return o.text end
    end
    return ''
end

obs.bind('SetObjectiveDisplayed', function(q, index, flag)
    local quest = questArg(q)
    index = math.floor(tonumber(index) or 0)
    if quest and obs.b(flag or 1) then
        local o = questState(quest).objectives
        if o[index] == nil then
            local text = objectiveText(quest, index)
            if text ~= '' then playerEvent('ObScriptNotify', { text = text }) end
        end
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
obs.bind('AddItem', function(a, b, c)
    local ref, item, count = nil, a, b
    if type(a) == 'string' and type(b) == 'string' then ref, item, count = a, b, c end
    local target = speakerOr(ref)
    if not isPlayer(target) then
        tlog('AddItem to a non-player is ignored: ' .. tostring(item))
        return 0
    end
    core.sendGlobalEvent('ObScriptAddItem', { item = item, count = count or 1 })
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
    else
        tlog('StartConversation between NPCs is not done yet')
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
obs.bind('ShowRaceMenu', function() openStandInMenu('ShowRaceMenu', 1036) return 0 end)
for _, name in ipairs({ 'GetPlayerName', 'ShowNameMenu', 'ShowSPECIALMenu', 'ShowTagSkillMenu', 'SetTagSkills',
    'ShowTraitMenu', 'ShowLoveTesterMenuParams' }) do
    obs.bind(name, function() openStandInMenu(name, nil) return 0 end)
end

-- Presentation commands with no effect on script flow; logged once each.
local quietStubs = {}
for _, name in ipairs({ 'AddScriptPackage', 'RemoveScriptPackage', 'ApplyImageSpaceModifier',
    'RemoveImageSpaceModifier', 'SetDestroyed', 'PlayIdle', 'AutoDisplayObjectives', 'AutoSave',
    'AddAchievement', 'SexChange', 'Look', 'StopLook', 'SetScreenSplatterFade', 'PlaySound', 'PlaySound3D' }) do
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

obs.bind('player', function() return 'player' end)

-- Menus the intro and many conversations open; not implemented yet. The
-- dialogue window reports them so the play-tester sees what was skipped.
for _, name in ipairs({ 'ShowBarterMenu', 'ShowRepairMenu', 'ShowRecipeMenu', 'ShowCompanionWheel', 'ForceGreet',
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
    })
    s.notices = {}
end

-- In the dialogue window an INFO's end script runs when its line is over,
-- which (without voice) is when the player moves on: picks an answer or
-- leaves. A topic the end script starts (StartConversation) is said next.
local function finishLine()
    local s = session
    local info = s and s.saying
    if info == nil then return end
    s.saying = nil
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
    if hasFlag(info.flags, INFO_RUN_IMMEDIATELY) then
        finishLine()
        if session == nil then return end
    end
    s.goodbye = hasFlag(info.flags, INFO_GOODBYE)
    s.options = buildOptions(info)
    sendScreen(infoText(info))
end

-- Ends the current line; true when its end script started another topic,
-- which is then said instead of whatever the player picked.
local function moveOn()
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

local function endDialogue()
    if session == nil then return end
    finishLine()
    if session == nil then return end
    session.player:sendEvent('FNVDialogueClose')
    session = nil
end

startDialogue = function(speaker, player, topicIdOrEditorId)
    local actor = dlg.getActor(speaker)
    if actor == nil then return false end
    initState()
    if session then finishLine() end
    session = { speaker = speaker, actor = actor, player = player, options = {}, notices = {} }
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
    if types.Player.objectIsInstance(actor) then
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
    sayto = true, say = true, startconversation = true, evaluatepackage = true, evp = true, resetai = true,
    disableplayercontrols = true, enableplayercontrols = true,
    showracemenu = true, getplayername = true, shownamemenu = true, showspecialmenu = true,
    showtagskillmenu = true, settagskills = true, showtraitmenu = true, showlovetestermenuparams = true,
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
        -- @return passed, failed condition, its value
        checkConditions = function(list, subject)
            initState()
            return conditions.evaluate(list, makeContext(subject, world.players[1]))
        end,
    },
    eventHandlers = {
        FNVDialogueChoose = function(data)
            local s = session
            if s == nil then return end
            local option = s.options[data.index]
            if moveOn() then return end
            if option == nil then
                endDialogue()
                return
            end
            say(option.info, option.topic)
        end,
        FNVDialogueClose = function()
            if session then finishLine() end
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
            local key = dlg.getReferenceId(data.object)
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
        onUpdate = function(dt)
            if not state.initialized then initState() end
            tickMenus()
            tickQuestScripts(dt)
            tickSpeaking(dt)
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
            for k, v in pairs(data.globals or {}) do obs._globals[k] = v end
            loadScriptVars(data.vars)
            publishAllQuests()
        end,
    },
}
