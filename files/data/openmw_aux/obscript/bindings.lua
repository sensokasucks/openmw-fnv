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

-- No button message box exists yet, so no button is ever pressed (vanilla: -1).
obs.bind('GetButtonPressed', function()
    return -1
end)

-- ---------------------------------------------------------------- PlayGroup
-- `PlayGroup GroupName flags` on the script's own object. OpenMW only plays
-- animations it has text keys for, so a missing group is reported once.
obs.bind('PlayGroup', function(a, b)
    local ref, group
    if type(a) == 'string' and type(b) == 'string' then
        ref, group = a, b
    else
        group = a
    end
    if type(group) ~= 'string' then return 0 end
    if ref ~= nil and ref:lower() ~= 'player' then
        warnOnce('playgroup:ref', 'PlayGroup on another reference is not supported yet: ' .. ref)
        return 0
    end
    local ok, has = pcall(anim.hasGroup, self, group)
    if not ok or not has then
        warnOnce('playgroup:' .. group:lower(),
            'PlayGroup: no animation group "' .. group .. '" on ' .. tostring(self.object)
            .. (ok and '' or ' (no animation)'))
        return 0
    end
    -- Play once; animations whose text keys loop keep looping on their own.
    anim.playBlended(self, group, { loops = 0, autoDisable = true })
    return 0
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
obs.bind('AddItem', function(ref, item, count)
    if type(ref) == 'string' and ref:lower() == 'player' and type(item) == 'string' then
        core.sendGlobalEvent('ObScriptAddItem', { item = item, count = count or 1 })
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

return obs
