-- FNV radio stations: what each one broadcasts, and when.
--
-- A station is a placed talking activator (TACT) flagged Radio Station. What
-- it says is dialogue of type Radio: a line is an INFO whose responses are
-- voice files (the DJ, under the station's voice type) or songs (the
-- response's own sound). After a line, the station goes on with the first of
-- the line's choices (TCLT) that has a line to say; with none, a Continuous
-- Broadcast station starts over at RadioHello and any other station goes
-- quiet until a script calls StartRadioConversation again. So Radio New Vegas
-- runs Hello, news intro, stories, transitions, post, song intro and three
-- songs (counted by RadioNewVegas.nTracksPlayed), then Hello again, all from
-- the INFO conditions and result scripts.
--
-- Stations broadcast on a clock of real seconds (it keeps going while the
-- Pip-Boy is open and the world is paused), whether anyone listens or not.
-- The global storage section 'FNVRadio' tells the player scripts what each
-- station plays: { offset = clock - core.getRealTime(), stations = { [id] =
-- { active, file, fileStart, fileEnd, info, text } } }, so a listener starts a song where the
-- broadcast is. scripts/omw/fnvradio/player.lua plays the tuned station on
-- the Pip-Boy; this script plays the stations that only sound where they
-- stand (Non-Proxy: casino lounges, the Goodsprings store), and the radios
-- (activators with a station) that were switched on, at the object.
--
-- ObScript: SetBroadcastState 0/1 (station off/on), StartRadioConversation
-- [topic] (a station speaks now, from RadioHello by default).

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local radio = core.obscript and core.obscript.radio
if radio == nil or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end
local dlg = core.obscript.dialogue

local INFO_RUN_IMMEDIATELY = 0x0008 -- the end script runs with the begin script
local GAP = 0.5 -- quiet between two lines, seconds (a guess)
local SILENT_LINE = 1.0 -- a response with no sound file still takes this long
local MAX_STEPS = 64 -- lines a station may run through in one update (after a long load)
local HEARING_DISTANCE = 4096 -- a 3D station plays when a player is in its cell or this close

local function log(msg)
    print('[fnvradio] ' .. msg)
end

local published = storage.globalSection('FNVRadio')
published:setLifeTime(storage.LIFE_TIME.GameSession)

-- ---------------------------------------------------------------- stations

local stations = {} -- list from radio.getStations()
local byId = {}
local byBase = {} -- TACT form id -> first station of it
for _, s in ipairs(radio.getStations()) do
    stations[#stations + 1] = s
    byId[s.id] = s
    if byBase[s.base] == nil then byBase[s.base] = s end
end

-- Saved with the game.
local state = {
    clock = 0,
    stations = {}, -- id -> { off, info, choices, responses = { { file, duration } }, index, fileStart, endsAt, endScript }
    radios = {}, -- activator reference form id -> true while switched on
}
local offset = 0 -- clock - core.getRealTime()
local started = false

local function now()
    return core.getRealTime() + offset
end

local function stationState(id)
    local st = state.stations[id]
    if st == nil then
        st = {}
        state.stations[id] = st
    end
    return st
end

local objectCache = {}
local function stationObject(s)
    local obj = objectCache[s.id]
    if obj ~= nil and obj:isValid() then return obj end
    local ok, found = pcall(world.getObjectByFormId, s.id)
    if ok and found ~= nil and found:isValid() then
        objectCache[s.id] = found
        return found
    end
    return nil
end

-- Broadcasting: the station's reference is enabled and SetBroadcastState did not turn it off.
local function isOn(s)
    local st = stationState(s.id)
    if st.off then return false end
    local obj = stationObject(s)
    if obj == nil then return false end
    return obj.enabled
end

local dirty = true

local function finishLine(s, st)
    if st.endScript and st.endScript ~= '' then
        I.FNVDialogue.runResultScript(st.endScript, 'radio end ' .. tostring(st.info), stationObject(s))
    end
    st.info, st.endScript, st.responses, st.index, st.fileStart, st.endsAt = nil, nil, nil, nil, nil, nil
    dirty = true
end

local function pickLine(s, topics)
    local obj = stationObject(s)
    if obj == nil then return nil end
    for _, topic in ipairs(topics) do
        local info = I.FNVDialogue.pickInfo(topic, obj, s.base)
        if info ~= nil then return info end
    end
    return nil
end

-- Starts a line at clock time `at`; returns false when the INFO has nothing to play.
local function startLine(s, st, info, at)
    local obj = stationObject(s)
    I.FNVDialogue.markSaid(info)
    if info.scriptBegin ~= '' then
        I.FNVDialogue.runResultScript(info.scriptBegin, 'radio ' .. info.id, obj)
    end
    local immediate = util.bitAnd(info.flags or 0, INFO_RUN_IMMEDIATELY) ~= 0
    if immediate and info.scriptEnd ~= '' then
        I.FNVDialogue.runResultScript(info.scriptEnd, 'radio end ' .. info.id, obj)
    end
    local responses = {}
    for _, r in ipairs(info.responses) do
        local file = radio.getResponseAudio(info.id, r.number, s.voiceType)
        local duration = file and radio.getDuration(file) or nil
        responses[#responses + 1] = { file = file, duration = duration or SILENT_LINE, text = r.text }
    end
    if #responses == 0 then
        responses[1] = { duration = SILENT_LINE }
    end
    st.info = info.id
    st.topic = info.topic
    st.choices = info.choices
    st.endScript = (not immediate) and info.scriptEnd or nil
    st.responses = responses
    st.index = 1
    st.fileStart = at
    st.endsAt = at + responses[1].duration
    dirty = true
    return true
end

local function startTopic(s, st, topics, at)
    local info = pickLine(s, topics)
    if info == nil then return false end
    return startLine(s, st, info, at)
end

-- Runs a station forward to `t`: next response, next line, or quiet.
local function advance(s, st, t)
    for _ = 1, MAX_STEPS do
        if st.endsAt == nil then
            if not s.continuous then return end
            -- a continuous station that has nothing to say tries RadioHello again a bit later
            if st.retryAt ~= nil and t < st.retryAt then return end
            if not startTopic(s, st, { 'RadioHello' }, t) then
                st.retryAt = t + 10
                return
            end
            st.retryAt = nil
        end
        if t < st.endsAt then return end
        local ended = st.endsAt
        if st.index < #st.responses then
            st.index = st.index + 1
            st.fileStart = ended
            st.endsAt = ended + st.responses[st.index].duration
            dirty = true
        else
            local choices = st.choices or {}
            finishLine(s, st)
            local at = ended + GAP
            if not startTopic(s, st, choices, at) then
                if not s.continuous or not startTopic(s, st, { 'RadioHello' }, at) then
                    return
                end
            end
        end
    end
end

-- A continuous station that starts up is somewhere in a line already, as if it had always been on.
local function joinBroadcast(s, st, t)
    if not startTopic(s, st, { 'RadioHello' }, t) then return end
    local into = math.random() * 0.8 * st.responses[1].duration
    st.fileStart = st.fileStart - into
    st.endsAt = st.endsAt - into
end

-- ---------------------------------------------------------------- publishing

local function publish()
    local list = {}
    for _, s in ipairs(stations) do
        local st = stationState(s.id)
        local on = isOn(s)
        local r = st.responses and st.responses[st.index]
        list[s.id] = {
            active = on and st.endsAt ~= nil,
            file = on and r and r.file or nil,
            fileStart = st.fileStart,
            fileEnd = st.endsAt,
            info = st.info,
            text = on and r and r.text or nil,
        }
    end
    published:set('offset', offset)
    published:set('stations', list)
    dirty = false
end

-- ---------------------------------------------------------------- 3D playback

local playing = {} -- object id -> { file, fileStart, object }

local function stopAt(key)
    local p = playing[key]
    if p == nil then return end
    if p.object:isValid() then
        pcall(core.sound.stopSay, p.object)
    end
    playing[key] = nil
end

local function playAt(key, obj, s, st, t)
    local r = st.responses and st.responses[st.index]
    local file = r and r.file
    local p = playing[key]
    if file == nil then
        stopAt(key)
        return
    end
    if p ~= nil and p.file == file and p.fileStart == st.fileStart then
        if core.sound.isSayActive(obj) or t - st.fileStart > r.duration - 0.5 then return end
    end
    if p == nil or p.file ~= file then
        log(('%s plays %s'):format(tostring(obj.recordId), file))
    end
    radio.say(obj, file, {
        offset = math.max(0, t - st.fileStart),
        minDistance = s.minDistance or 0,
        maxDistance = s.maxDistance or 0,
    })
    playing[key] = { file = file, fileStart = st.fileStart, object = obj }
end

local function nearAPlayer(obj)
    if obj == nil or obj.cell == nil then return false end
    for _, player in ipairs(world.players) do
        if player.cell == obj.cell then return true end
        if player.cell ~= nil and player.cell.isExterior and obj.cell.isExterior
            and player.cell.worldSpaceId == obj.cell.worldSpaceId
            and (player.position - obj.position):length() < HEARING_DISTANCE then
            return true
        end
    end
    return false
end

local radioObjects = {} -- activator reference form id -> object

local function update3D(t)
    for _, s in ipairs(stations) do
        if s.nonProxy then
            local obj = stationObject(s)
            if isOn(s) and nearAPlayer(obj) then
                playAt(s.id, obj, s, stationState(s.id), t)
            else
                stopAt(s.id)
            end
        end
    end
    for refId in pairs(state.radios) do
        local obj = radioObjects[refId]
        if obj == nil or not obj:isValid() then
            local ok, found = pcall(world.getObjectByFormId, refId)
            obj = ok and found or nil
            radioObjects[refId] = obj
        end
        local stationId = obj and radio.getActivatorStation(obj)
        local s = stationId and byBase[stationId]
        if s ~= nil and obj.enabled and isOn(s) and nearAPlayer(obj) then
            playAt(refId, obj, s, stationState(s.id), t)
        else
            stopAt(refId)
        end
    end
end

-- ---------------------------------------------------------------- update

local next3D = 0

local function start()
    started = true
    offset = state.clock - core.getRealTime()
    local t = now()
    for _, s in ipairs(stations) do
        local st = stationState(s.id)
        if s.continuous and st.endsAt == nil and isOn(s) then
            joinBroadcast(s, st, t)
        end
    end
    publish()
end

local function onUpdate()
    if I.FNVDialogue == nil then return end
    if not started then start() end
    local t = now()
    state.clock = t
    for _, s in ipairs(stations) do
        local st = stationState(s.id)
        if isOn(s) then
            if st.wasOff and s.continuous and st.endsAt == nil then
                joinBroadcast(s, st, t)
            end
            st.wasOff = nil
            advance(s, st, t)
        elseif not st.wasOff then
            st.wasOff = true
            dirty = true
        end
    end
    if dirty then publish() end
    if t >= next3D then
        next3D = t + 0.25
        update3D(t)
    end
end

-- ---------------------------------------------------------------- commands

local function stationOf(obj)
    if obj == nil then return nil end
    local ok, id = pcall(dlg.getReferenceId, obj)
    return ok and id and byId[id] or nil
end

local function startConversation(s, topic)
    local st = stationState(s.id)
    if st.endsAt ~= nil and not s.continuous then
        return -- already speaking
    end
    if st.endsAt ~= nil then
        finishLine(s, st)
    end
    st.off = nil
    startTopic(s, st, { type(topic) == 'string' and topic or 'RadioHello' }, now())
end

local commandsBound = false
local function bindCommands()
    if commandsBound or I.FNVDialogue == nil then return end
    commandsBound = true
    I.FNVDialogue.bindCommand('SetBroadcastState', function(obj, value)
        local s = stationOf(obj)
        if s == nil then return 0 end
        local st = stationState(s.id)
        st.off = (tonumber(value) or 0) == 0 or nil
        if st.off and st.endsAt ~= nil then finishLine(s, st) end
        dirty = true
        return 0
    end)
    I.FNVDialogue.bindCommand('StartRadioConversation', function(obj, topic)
        local s = stationOf(obj)
        if s ~= nil then startConversation(s, topic) end
        return 0
    end)
    I.FNVDialogue.bindCommand('SetTalkingActivatorActor', function() return 0 end)
end

-- Radios (activators with a station, RNAM) switch on and off when used. False for other objects.
local function switchRadio(obj)
    if radio.getActivatorStation(obj) == nil then return false end
    local ok, refId = pcall(dlg.getReferenceId, obj)
    if not ok or refId == nil then return false end
    if state.radios[refId] then
        state.radios[refId] = nil
        stopAt(refId)
    else
        state.radios[refId] = true
        radioObjects[refId] = obj
        next3D = 0
    end
    return true
end

if I.Activation then
    I.Activation.addHandlerForType(types.ESM4Activator, function(obj)
        if switchRadio(obj) then return false end
    end)
end

bindCommands()

return {
    interfaceName = 'FNVRadio',
    interface = {
        version = 0,
        --- Station records from core.obscript.radio.getStations, by reference form id.
        getStation = function(id) return byId[id] end,
        --- What a station is doing: { on, info, topic, file, fileStart, endsAt }.
        getStationState = function(id)
            local s = byId[id]
            if s == nil then return nil end
            local st = stationState(id)
            local r = st.responses and st.responses[st.index]
            return { on = isOn(s), info = st.info, topic = st.topic, file = r and r.file,
                fileStart = st.fileStart, endsAt = st.endsAt }
        end,
        --- Switches a radio (an activator with a station) on or off; false for anything else.
        switchRadio = switchRadio,
        --- StartRadioConversation for tests.
        startConversation = function(id, topic)
            local s = byId[id]
            if s then startConversation(s, topic) end
        end,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = function()
            state.clock = now()
            return state
        end,
        onLoad = function(data)
            if type(data) == 'table' then
                state = data
                state.stations = state.stations or {}
                state.radios = state.radios or {}
                state.clock = state.clock or 0
            end
            started = false
            playing = {}
            bindCommands()
        end,
    },
}
