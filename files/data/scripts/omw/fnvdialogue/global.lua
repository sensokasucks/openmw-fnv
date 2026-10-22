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

local function hasFlag(flags, flag)
    return util.bitAnd(flags or 0, flag) ~= 0
end

-- ---------------------------------------------------------------- persistent state

local state = {
    initialized = false,
    quests = {},     -- quest form id -> { running, completed, stage, done = {[stage] = true}, objectives = {} }
    saidOnce = {},   -- INFO form id -> true
    talkedTo = {},   -- NPC reference form id -> true
}

local function initState()
    if state.initialized then return end
    state.initialized = true
    for _, questId in ipairs(dlg.getStartGameEnabledQuests()) do
        state.quests[questId] = state.quests[questId] or { running = true, stage = 0, done = {}, objectives = {} }
    end
end

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

-- GLOB values: changed values live in obs._globals (shared with result
-- scripts, saved); unchanged ones come from the records.
local function globalValue(idOrEditorId)
    local record = dlg.getGlobal(idOrEditorId)
    if record == nil then return nil end
    local value = rawget(obs._globals, record.editorId:lower())
    if value ~= nil then return value end
    return record.value
end

-- Result scripts read globals as bare names; make record values visible.
do
    local baseV = obs.v
    obs.v = function(name)
        local key = name:lower()
        if obs._bindings[key] == nil and rawget(obs._globals, key) == nil then
            local record = dlg.getGlobal(name)
            if record then
                obs._globals[key] = record.value
            end
        end
        return baseV(name)
    end
end

-- ---------------------------------------------------------------- quests

local runScript -- forward

local function setStage(quest, stage)
    local s = questState(quest)
    stage = math.floor(tonumber(stage) or 0)
    s.running = true
    s.stage = stage
    s.done[stage] = true
    tlog('SetStage ' .. quest.editorId .. ' ' .. stage)
    for _, st in ipairs(quest.stages) do
        if st.index == stage then
            -- the first log entry runs (entry conditions are not evaluated yet)
            local entry = st.entries[1]
            if entry then
                if hasFlag(entry.flags, 0x01) then
                    s.completed = true
                    s.running = false
                end
                runScript(entry.script, quest.editorId .. ' stage ' .. stage)
            end
            break
        end
    end
end

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
functions[46] = function() return 0 end -- GetDead
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

local function questAllows(info, ignoreQuestState)
    if ignoreQuestState or info.quest == '' then return true end
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

local function pickInfoImpl(topic, ignoreQuestState)
    local s = session
    local ctx = makeContext(s.speaker, s.player)
    local infos = getTopicInfos(topic.id, s.actor.recordId)
    local randoms = nil
    for _, info in ipairs(infos) do
        if questAllows(info, ignoreQuestState) and not state.saidOnce[info.id] then
            local passed, failed, value = conditions.evaluate(info.conditions, ctx)
            if passed then
                if not hasFlag(info.flags, INFO_RANDOM) then
                    if randoms == nil then return info end
                elseif randoms == nil then
                    randoms = { info }
                else
                    randoms[#randoms + 1] = info
                end
            elseif trace then
                tlog(('  %s %s: fails %s'):format(topic.editorId, info.id, conditions.describe(failed, value)))
            end
        end
    end
    if randoms then
        return randoms[math.random(1, #randoms)]
    end
    return nil
end

local function pickInfo(topic)
    local info = pickInfoImpl(topic, false)
    if info == nil then
        -- Quest start-up is not emulated yet (quest scripts do not run), so
        -- dialogue of a quest that is not running would never show. Fall back
        -- to ignoring the quest state and say so in the log.
        info = pickInfoImpl(topic, true)
        if info then
            log(('%s: using INFO %s of quest %s which is not running'):format(topic.editorId, info.id, info.quest))
        end
    end
    return info
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

runScript = function(source, label)
    if source == nil or source:match('^%s*$') then return end
    tlog('run result script (' .. label .. '):\n' .. source)
    local handler = compileScript(source)
    if not handler then return end
    -- stage scripts run from inside INFO scripts, so restore the outer state
    local prevCurrent, prevBlock = obs._current, obs._block
    obs._current = obs._scripts['anonymous']
    obs._block = 'result'
    local ok, err = pcall(handler)
    obs._current, obs._block = prevCurrent, prevBlock
    if not ok then
        log('result script error (' .. label .. '): ' .. tostring(err))
    end
end

-- ---------------------------------------------------------------- result script commands

local function questArg(q)
    local quest = getQuest(type(q) == 'string' and q or '')
    if quest == nil then
        notice('unknown quest: ' .. tostring(q))
    end
    return quest
end

local function speakerOr(ref)
    if ref == nil and session then return session.speaker end
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
    return (quest and questState(quest).done[stage]) and 1 or 0
end)
obs.bind('StartQuest', function(q)
    local quest = questArg(q)
    if quest then questState(quest).running = true end
    return 0
end)
obs.bind('StopQuest', function(q)
    local quest = questArg(q)
    if quest then questState(quest).running = false end
    return 0
end)
obs.bind('CompleteQuest', function(q)
    local quest = questArg(q)
    if quest then
        local s = questState(quest)
        s.completed = true
        s.running = false
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
    if quest and obs.b(flag or 1) then
        local o = questState(quest).objectives
        if o[index] ~= 'completed' then o[index] = 'displayed' end
    end
    return 0
end)
obs.bind('SetObjectiveCompleted', function(q, index, flag)
    local quest = questArg(q)
    if quest then
        questState(quest).objectives[index] = obs.b(flag or 1) and 'completed' or 'displayed'
    end
    return 0
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
    world.players[1]:sendEvent('ObScriptShowMessage', { editorId = msgId, args = args })
    return 0
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

-- `Ref.StartConversation player Topic`: continue with that topic.
obs.bind('StartConversation', function(a, b, c)
    local topic = c or b
    if type(topic) == 'string' and session then
        session.pendingTopic = topic
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

obs.bind('player', function() return 'player' end)

-- Menus the intro and many conversations open; not implemented yet. The
-- dialogue window reports them so the play-tester sees what was skipped.
for _, name in ipairs({ 'ShowRaceMenu', 'ShowNameMenu', 'ShowSPECIALMenu', 'ShowTagSkillMenu',
    'ShowBarterMenu', 'ShowRepairMenu', 'ShowRecipeMenu', 'ShowCompanionWheel', 'ForceGreet',
    'RewardXP', 'RewardKarma', 'AddPerk', 'ModPCSkill', 'SetEssential', 'AddScriptPackage', 'EVP',
    'MoveTo', 'SetPlayerTeammate', 'PlayGroup', 'Say', 'SayTo', 'StartCombat', 'StopCombat',
    'SetEnemy', 'SetAlly', 'AddTopic' }) do
    if obs._bindings[name:lower()] == nil then
        obs.bind(name, function()
            notice('(not implemented yet: ' .. name .. ')')
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
    for _, topicId in ipairs(getSpeakerTopics(session.actor.recordId)) do
        local topic = getTopic(topicId)
        if topic and topic.editorId:upper() ~= 'GREETING' then
            local option = topicOption(topicId)
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

local function say(info, topic)
    local s = session
    tlog(('%s: INFO %s (quest %s)'):format(topic and topic.editorId or '?', info.id, info.quest))
    if hasFlag(info.flags, INFO_SAY_ONCE) then
        state.saidOnce[info.id] = true
    end
    s.pendingTopic = nil
    runScript(info.scriptBegin, 'INFO ' .. info.id .. ' begin')
    runScript(info.scriptEnd, 'INFO ' .. info.id .. ' end')
    if session == nil then return end -- a script ended the conversation
    local text = infoText(info)
    if s.pendingTopic then
        local option = topicOption(s.pendingTopic)
        s.pendingTopic = nil
        if option then
            -- the follow-up topic is spoken right away
            local followText = infoText(option.info)
            text = (text ~= '' and (text .. '\n\n') or '') .. followText
            info = option.info
            runScript(info.scriptBegin, 'INFO ' .. info.id .. ' begin')
            runScript(info.scriptEnd, 'INFO ' .. info.id .. ' end')
        end
    end
    s.goodbye = hasFlag(info.flags, INFO_GOODBYE)
    s.options = buildOptions(info)
    sendScreen(text)
end

local function endDialogue()
    if session == nil then return end
    session.player:sendEvent('FNVDialogueClose')
    session = nil
end

local function startDialogue(speaker, player, topicIdOrEditorId)
    local actor = dlg.getActor(speaker)
    if actor == nil then return false end
    initState()
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

-- ---------------------------------------------------------------- save/load

local function saveScriptVars()
    local vars = {}
    for name, entry in pairs(obs._scripts) do
        if name ~= 'anonymous' then
            local locals = {}
            for k, v in pairs(entry.locals) do locals[k] = v end
            vars[name] = locals
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
        --- Evaluates a CTDA list (as built by core.obscript) with subject as
        -- the running object and the player as target; used by AI packages.
        -- overrides: optional function index -> function(cond, subject) answering
        -- in place of the engine (nil falls through).
        -- @return passed, failed condition, its value
        checkConditions = function(list, subject, overrides)
            initState()
            return conditions.evaluate(list, makeContext(subject, world.players[1], overrides))
        end,
    },
    eventHandlers = {
        FNVDialogueChoose = function(data)
            local s = session
            if s == nil then return end
            local option = s.options[data.index]
            if option == nil then
                endDialogue()
                return
            end
            say(option.info, option.topic)
        end,
        FNVDialogueClose = function()
            session = nil
        end,
    },
    engineHandlers = {
        onSave = function()
            local globals = {}
            for k, v in pairs(obs._globals) do globals[k] = v end
            return { state = state, globals = globals, vars = saveScriptVars() }
        end,
        onLoad = function(data)
            if data == nil then return end
            state = data.state or state
            for k, v in pairs(data.globals or {}) do obs._globals[k] = v end
            loadScriptVars(data.vars)
        end,
    },
}
