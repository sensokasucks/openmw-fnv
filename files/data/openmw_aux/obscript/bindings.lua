---
-- `openmw_aux.obscript.bindings` installs engine bindings for transpiled
-- ObScript running as a local script. Loaded by @{runtime#runtime.makeLocalScript};
-- requires the local context (`openmw.self`).
-- @module bindings
-- @context local

local anim = require('openmw.animation')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')

local obs = require('openmw_aux.obscript.runtime')

local function isObject(x)
    return type(x) == 'userdata'
end

local function player()
    return nearby.players[1]
end

local function warnOnce(key, msg)
    obs._warned = obs._warned or {}
    if obs._warned[key] then return end
    obs._warned[key] = true
    print('[obscript] ' .. msg)
end

-- A script with an OnActivate block replaces the object's default activation
-- (vanilla semantics); the block has to call `Activate` to get it back.
obs._onLocalScriptReady = function(entry)
    if entry.handlers['onactivate'] then
        core.sendGlobalEvent('ObScriptHasOnActivate', { object = self.object })
    end
end

-- Block filters (`Begin OnTriggerEnter player`): the filter is an editor id,
-- or the value of a ref variable.
obs.refMatches = function(ref, filter)
    if type(ref) == 'string' then -- SayToDone passes the topic
        return type(filter) == 'string' and ref:lower() == filter:lower()
    end
    if not isObject(ref) then return false end
    if isObject(filter) then return ref == filter end
    if type(filter) ~= 'string' then return false end
    local key = filter:lower()
    if key == 'player' or key == 'playerref' then
        return types.Player.objectIsInstance(ref)
    end
    local formId = core.obscript.resolveRefEditorId(filter)
    return formId ~= nil and tostring(ref.id) == formId
end

-- ---------------------------------------------------------------- quests
-- Quest state and quest variables live in the global script
-- scripts/omw/fnvdialogue/global.lua, which mirrors them into this storage
-- section. Reads are immediate; changes go there as events and show up here
-- in the next frame.
local quests = storage.globalSection('ObScriptQuests')

local function questData(name)
    if type(name) ~= 'string' then return nil end
    return quests:get(name:lower())
end

-- Variables of other objects' scripts (Ref.var), as the global script
-- republishes them.
local refVars = storage.globalSection('ObScriptRefVars')

obs._remoteVar = function(base, name)
    local q = questData(base)
    if q ~= nil then
        return q.vars[name:lower()] or 0
    end
    local key = core.obscript.resolveRefEditorId(base)
    local vars = key and refVars:get(key)
    if vars == nil then return nil end
    return vars[name:lower()] or 0
end

obs._remoteSet = function(base, name, value)
    if questData(base) ~= nil then
        core.sendGlobalEvent('ObScriptSetQuestVar', { quest = base, name = name, value = value })
        return true
    end
    local key = core.obscript.resolveRefEditorId(base)
    if key == nil then return false end
    core.sendGlobalEvent('ObScriptSetRefVar', { ref = key, name = name, value = value })
    return true
end

obs.bind('GetStage', function(q)
    local data = questData(q)
    return data and data.stage or 0
end)
obs.bind('GetStageDone', function(q, stage)
    local data = questData(q)
    return (data and data.done[math.floor(tonumber(stage) or -1)]) and 1 or 0
end)
obs.bind('GetQuestRunning', function(q)
    local data = questData(q)
    return (data and data.running) and 1 or 0
end)
obs.bind('GetQuestCompleted', function(q)
    local data = questData(q)
    return (data and data.completed) and 1 or 0
end)
obs.bind('GetObjectiveDisplayed', function(q, index)
    local data = questData(q)
    local o = data and data.objectives[math.floor(tonumber(index) or 0)]
    return (o == 'displayed' or o == 'completed') and 1 or 0
end)
obs.bind('GetObjectiveCompleted', function(q, index)
    local data = questData(q)
    return (data and data.objectives[math.floor(tonumber(index) or 0)] == 'completed') and 1 or 0
end)

-- This object's variables, for Ref.var and GetScriptVariable elsewhere:
-- sent to the global script when they changed, at most twice a second.
local published = {}
local publishTimer = 0
obs._publishLocals = function(entry, dt)
    publishTimer = publishTimer - dt
    if publishTimer > 0 then return end
    publishTimer = 0.5
    local changed = false
    local copy = {}
    for k, v in pairs(entry.locals) do
        if type(v) == 'number' or type(v) == 'string' then
            copy[k] = v
            if published[k] ~= v then changed = true end
        end
    end
    for k in pairs(published) do
        if copy[k] == nil then changed = true end
    end
    if changed then
        published = copy
        core.sendGlobalEvent('ObScriptLocals', { object = self.object, script = entry.name, locals = copy })
    end
end

-- ---------------------------------------------------------------- queries
-- Answered here, on this object or another reference.

local function refObject(ref)
    if isObject(ref) then return ref end
    if type(ref) ~= 'string' then return nil end
    local key = ref:lower()
    if key == 'player' or key == 'playerref' then return player() end
    -- a reference this local script can see
    local formId = core.obscript.resolveRefEditorId(ref)
    if formId == nil then return nil end
    for _, list in ipairs({ nearby.actors, nearby.items, nearby.activators, nearby.doors, nearby.containers }) do
        for _, obj in ipairs(list) do
            if tostring(obj.id) == formId or core.obscript.dialogue.getReferenceId(obj) == formId then
                return obj
            end
        end
    end
    return nil
end

-- (ref, rest...) for `Ref.Cmd a b` and `Cmd a b` (on this object)
local function refAndArgs(...)
    if obs._callBase ~= nil then
        return refObject(select(1, ...)), select(2, ...)
    end
    return self.object, ...
end

obs.bind('GetDead', function(...)
    local obj = refAndArgs(...)
    if obj == nil then return 0 end
    if types.Player.objectIsInstance(obj) then return types.Actor.isDead(obj) and 1 or 0 end
    local ok, dead = pcall(core.obscript.combat.isDead, obj)
    return (ok and dead) and 1 or 0
end)
obs.bind('GetDisabled', function(...)
    local obj = refAndArgs(...)
    return (obj ~= nil and not obj.enabled) and 1 or 0
end)
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
obs.bind('GetSelf', function(...)
    local obj = refAndArgs(...)
    return obj or 0
end)
obs.bind('GetDistance', function(...)
    local obj, other = refAndArgs(...)
    other = refObject(other)
    if obj == nil or other == nil or obj.cell == nil or other.cell == nil or obj.cell.id ~= other.cell.id then return 999999 end
    return (obj.position - other.position):length()
end)
obs.bind('GetIsReference', function(...)
    local obj, other = refAndArgs(...)
    other = refObject(other)
    return (obj ~= nil and obj == other) and 1 or 0
end)
obs.bind('GetLinkedRef', function(...)
    local obj = refAndArgs(...)
    local linked = obj and core.obscript.getLinkedRef(obj)
    if not linked then return 0 end
    for _, list in ipairs({ nearby.actors, nearby.items, nearby.activators, nearby.doors, nearby.containers }) do
        for _, o in ipairs(list) do
            if core.obscript.dialogue.getReferenceId(o) == linked then return o end
        end
    end
    return 0
end)
obs.bind('GetLocked', function(...)
    local obj = refAndArgs(...)
    local ok, locked = pcall(types.Lockable.isLocked, obj)
    return (ok and locked) and 1 or 0
end)
-- `Ref.IsCurrentFurnitureRef Furniture`: whether the actor sits on it.
local furniture = storage.globalSection('ESM4CurrentFurniture')
obs.bind('IsCurrentFurnitureRef', function(...)
    local actor, ref = refAndArgs(...)
    local current = actor and furniture:get(tostring(actor.id))
    local wanted = type(ref) == 'string' and core.obscript.resolveRefEditorId(ref)
    return (current and wanted and current == wanted) and 1 or 0
end)

obs.bind('GetCurrentTime', function()
    return core.obscript.getGameDate().hour
end)

-- Commands the global script carries out, with this object as the subject
-- of reference-less forms (`SayTo player Topic` on an NPC's own script).
for _, name in ipairs({ 'SetStage', 'StartQuest', 'StopQuest', 'CompleteQuest', 'SetQuestDelay',
    'SetObjectiveDisplayed', 'SetObjectiveCompleted', 'SayTo', 'Say', 'StartConversation', 'ForceGreet',
    'EvaluatePackage', 'EVP', 'ResetAI', 'DisablePlayerControls', 'EnablePlayerControls',
    'AddScriptPackage', 'RemoveScriptPackage', 'AddToFaction', 'RemoveFromFaction', 'SetFactionRank', 'StartCombat', 'StopCombat', 'KillActor', 'Lock', 'Unlock', 'MarkForDelete', 'RemoveMe', 'PlaceAtMe',
    'MoveTo', 'MoveToMarker', 'MoveToMarkerWithFade', 'AddTopic',
    'ShowRaceMenu', 'GetPlayerName', 'ShowNameMenu', 'ShowSPECIALMenu', 'ShowTagSkillMenu', 'SetTagSkills',
    'ShowTraitMenu', 'ShowTraitSelectMenu', 'ShowLoveTesterMenu', 'ShowLoveTesterMenuParams', 'ShowSPECIALBookMenu',
    'ShowSPECIALBookMenuParams' }) do
    obs.bind(name, function(...)
        local args = { ... }
        local n = select('#', ...)
        for i = 1, n do
            if args[i] == nil then args[i] = 0 end
        end
        core.sendGlobalEvent('ObScriptQuestCommand', {
            name = name, self = self.object, member = obs._callBase ~= nil, args = args, n = n,
        })
        return 0
    end)
end

-- ---------------------------------------------------------------- Activate
-- Forms: `Activate`, `Activate actor`, `Activate actor runOnActivateBlock`,
-- and the member forms `Ref.Activate ...`. A free call arrives as fn(actor, flag);
-- a member call as fn('<editor id>', actor, flag).
obs.bind('Activate', function(a, b, c)
    local ref, actor, flag
    if type(a) == 'string' then
        ref, actor, flag = a, b, c
    else
        actor, flag = a, b
    end
    if not isObject(actor) then
        -- a bare number here is the flag of the free form
        if type(actor) == 'number' and flag == nil then flag = actor end
        actor = obs._actionRef or player()
    end
    local runBlock = obs.b(flag or 0)
    if ref == nil then
        core.sendGlobalEvent('ObScriptActivate',
            { object = self.object, actor = actor, runOnActivateBlock = runBlock })
    else
        core.sendGlobalEvent('ObScriptActivateByRef',
            { editorId = ref, actor = actor, runOnActivateBlock = runBlock })
    end
    return 0
end)

-- ---------------------------------------------------------------- ShowMessage
-- `ShowMessage MsgEditorId [arg ...]`: the player script looks the MESG record
-- up and formats it. Button boxes are shown as plain text for now.
obs.bind('ShowMessage', function(msgId, ...)
    if type(msgId) ~= 'string' then return 0 end
    local args = { ... }
    for i, v in ipairs(args) do
        if isObject(v) then args[i] = tostring(v) end
    end
    player():sendEvent('ObScriptShowMessage', { editorId = msgId, args = args })
    return 0
end)

-- The button pressed in the last ShowMessage box, once; -1 until then.
obs.bind('GetButtonPressed', function()
    return core.obscript.getButtonPressed()
end)

-- ---------------------------------------------------------------- PlayGroup
-- `PlayGroup GroupName flags` on the script's own object, or `Ref.PlayGroup`.
-- Groups OpenMW does not know yet are looked up among the sequences embedded in
-- the model (levers' "Forward"/"Backward", terminals' "Open"), which are set up
-- on first use.
obs.bind('PlayGroup', function(a, b)
    local ref, group
    if type(a) == 'string' and type(b) == 'string' then
        ref, group = a, b
    else
        group = a
    end
    if type(group) ~= 'string' then return 0 end
    if ref ~= nil and ref:lower() ~= 'player' then
        core.sendGlobalEvent('ObScriptPlayGroupByRef', { editorId = ref, group = group })
        return 0
    end
    local ok, has = pcall(anim.hasGroup, self, group)
    if not ok or not has then
        core.obscript.playEmbeddedGroup(self.object, group)
        return 0
    end
    -- Play once; animations whose text keys loop keep looping on their own.
    anim.playBlended(self, group, { loops = 0, autoDisable = true })
    return 0
end)

-- ---------------------------------------------------------------- open state
-- `SetOpenState 1|0` and `GetOpenState` (1 open, 3 closed; the original also
-- reports 2 opening and 4 closing). Doors keep their own state; other objects
-- play their "Open" or "Close" sequence and remember the last state set here.
local openState = nil
obs.bind('SetOpenState', function(a, b)
    local ref, value
    if type(a) == 'string' then
        ref, value = a, b
    else
        value = a
    end
    local open = obs.b(value or 0)
    if ref ~= nil then
        core.sendGlobalEvent('ObScriptSetOpenStateByRef', { editorId = ref, open = open })
        return 0
    end
    openState = open
    core.obscript.setOpenState(self.object, open)
    return 0
end)

obs.bind('GetOpenState', function(ref)
    if type(ref) == 'string' then
        warnOnce('getopenstate:ref', 'GetOpenState on another reference is not supported yet: ' .. ref)
        return 3
    end
    local open = core.obscript.isDoorOpen(self.object)
    if open == nil then open = openState end
    return open and 1 or 3
end)

-- ---------------------------------------------------------------- trigger volumes
-- Returns the actors whose feet or chest point lies inside this reference's
-- primitive (REFR XPRM half extents in local space). Without a primitive the
-- render bounding box is used instead.
local triggerBounds = nil
obs._triggerProbe = function()
    if triggerBounds == nil then
        triggerBounds = core.obscript.getPrimitiveBounds(self.object)
        if triggerBounds == nil then
            local box = self.object:getBoundingBox()
            triggerBounds = box and box.halfSize or util.vector3(0, 0, 0)
        end
    end
    local b = triggerBounds
    if b.x <= 0 and b.y <= 0 and b.z <= 0 then return {} end
    local scale = self.object.scale or 1
    local hx, hy, hz = b.x * scale, b.y * scale, b.z * scale
    local center = self.object.position
    local radius2 = (hx * hx + hy * hy + hz * hz) + 64 * 64
    local inv = self.object.rotation:inverse()
    local inside = {}
    for _, actor in ipairs(nearby.actors) do
        local pos = actor.position
        if (pos - center):length2() <= radius2 then
            local function hit(p)
                local rel = inv:apply(p - center)
                return math.abs(rel.x) <= hx and math.abs(rel.y) <= hy and math.abs(rel.z) <= hz
            end
            if hit(pos) or hit(pos + util.vector3(0, 0, 64)) then
                inside[#inside + 1] = actor
            end
        end
    end
    return inside
end

obs.bind('GetSecondsPassed', function()
    return obs._dt or 0
end)

local function setEnabled(ref, enabled)
    if ref == nil then
        core.sendGlobalEvent('ObScriptSetEnabled', { object = self.object, enabled = enabled })
    elseif type(ref) == 'string' then
        core.sendGlobalEvent('ObScriptSetEnabledByRef', { editorId = ref, enabled = enabled })
    end
    return 0
end

-- Reference-less form acts on the script's own object; `SomeRef.Enable` is
-- resolved to the placed reference by the global handler.
obs.bind('Enable', function(ref)
    return setEnabled(ref, true)
end)

obs.bind('Disable', function(ref)
    return setEnabled(ref, false)
end)

-- The activating reference while handling OnActivate/OnOpen; 0 otherwise.
-- `player` resolves to the player object so `GetActionRef == player` compares by identity.
obs.bind('GetActionRef', function()
    return obs._actionRef
end)

obs.bind('player', player)

-- True while handling OnActivate triggered by the given reference.
obs.bind('IsActionRef', function(ref)
    local actor = obs._actionRef
    if actor == nil then
        return 0
    end
    if type(ref) == 'string' and ref:lower() == 'player' then
        return types.Player.objectIsInstance(actor) and 1 or 0
    end
    return 0
end)

-- AddItem on the player: resolve the item editor id and ask the global
-- obscript handler to create and move the items. Other targets come with
-- ref resolution later.
obs.bind('AddItem', function(ref, item, count, hideMessage)
    if type(ref) == 'string' and ref:lower() == 'player' and type(item) == 'string' then
        core.sendGlobalEvent('ObScriptAddItem', { item = item, count = count or 1,
            silent = hideMessage ~= nil and obs.b(hideMessage) })
    end
    return 0
end)

-- `AddNote NoteEditorId`: the player script keeps the notes list.
obs.bind('AddNote', function(a, b)
    local note = b or a  -- member form `player.AddNote X` arrives as ('player', 'X')
    if type(note) ~= 'string' then return 0 end
    player():sendEvent('ESM4AddNote', { editorId = note })
    return 0
end)

-- ---------------------------------------------------------------- actor values
-- GetAV/SetAV/ModAV/GetLevel/GetIsSex... (openmw_aux.obscript.stats). A local
-- script can only reach itself and the player; changes go through the global
-- script scripts/omw/fnvstats.lua.
require('openmw_aux.obscript.stats').install(obs, {
    subject = function() return self.object end,
    resolve = function(ref)
        if isObject(ref) then return ref end
        if type(ref) ~= 'string' then return nil end
        local key = ref:lower()
        if key == 'player' or key == 'playerref' then return player() end
        return nil
    end,
    change = function(object, op, av, value)
        core.sendGlobalEvent('FNVStatsChange', { object = object, op = op, av = av, value = value })
    end,
})

-- RewardXP, RewardKarma, AddReputation, GetReputationThreshold, HasPerk...
-- (openmw_aux.obscript.character): reads what scripts/omw/fnvcharacter/global.lua
-- publishes and sends it the changes.
local characterSection = storage.globalSection('FNVCharacter')
require('openmw_aux.obscript.character').install(obs, {
    subject = function() return self.object end,
    resolve = function(ref)
        if isObject(ref) then return ref end
        if type(ref) ~= 'string' then return nil end
        local key = ref:lower()
        if key == 'player' or key == 'playerref' then return player() end
        return nil
    end,
    data = function() return characterSection:get('state') end,
    command = function(name, ...)
        core.sendGlobalEvent('FNVCharacterCommand', { name = name, args = { ... } })
    end,
})

return obs
