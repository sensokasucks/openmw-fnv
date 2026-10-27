-- NPCs using FO3/FNV furniture and idle markers.
--
-- A furniture model carries markers (BSFurnitureMarker): where an actor
-- stands facing the furniture before using it, with a type that says what
-- the spot is (bed left/right, chair front/left/right/back entry, stool,
-- lean...). The idle tree (idles.lua) gives the entry, loop and exit
-- sequences for the marker type; the engine (core.obscript.ai) plays them
-- and moves the actor from the marker to the seat and back.
--
-- Idle markers (IDLM references) are spots where an NPC stands and plays
-- the marker's list of idle animations.

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')
local idles = require('scripts.omw.fnvai.idles')
local I = require('openmw.interfaces')

local ai = core.obscript and core.obscript.ai

local M = {}

local function log(msg)
    print('[fnvai] ' .. msg)
end

-- Marker type -> where the seat is relative to the marker (x right, y along the heading) and how much the
-- actor turns once seated; the fFurnitureMarkerNNDelta* game settings.
local HALF = math.pi / 2
local markerDelta = {
    [1] = { -7.99, 71.37, -HALF }, [2] = { 13.10, 70.59, HALF }, -- bed, from the left / right
    [3] = { 2.27, 55.89, -HALF }, [4] = { 2.27, 55.89, HALF }, -- floor bed
    [5] = { 2.27, 61.66, -HALF }, [6] = { 2.27, 48.99, HALF }, -- sleep on the floor
    [11] = { 2.61, 53.96, -HALF }, [12] = { 2.67, 53.65, HALF }, -- chair, from the left / right
    [13] = { 2.79, 57.42, 0 }, [14] = { 2.48, 57.36, math.pi }, -- chair, from the back / front
    [15] = { -16.40, 49.54, 0 }, -- stool
    [16] = { -26.58, 89.80, 1.4835 }, -- pod
    [17] = { -0.07, 55.01, math.pi }, -- sit on the floor
    [18] = { -1.43, 35.53, math.pi }, -- restrained
    [19] = { -1.98, 26.29, math.pi }, -- lean on a wall
    [20] = { 0, 36.88, 0 }, -- child at a bar
    [21] = { 2.55, 57.42, 0 },
    [23] = { -1.98, 33.47, -math.pi },
    [26] = { 0, 0, math.pi },
}

local sleepMarkers = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }
-- What a sandboxing NPC sits on or leans against
local sitMarkers = { [11] = true, [12] = true, [13] = true, [14] = true, [15] = true, [17] = true, [19] = true }

function M.isSleepMarker(markerType) return sleepMarkers[markerType] == true end
function M.isSitMarker(markerType) return sitMarkers[markerType] == true end

local function markerEnabled(record, marker)
    local flags = record.activeMarkerFlags
    return flags == 0 or (math.floor(flags / 2 ^ marker.index) % 2) == 1
end

-- World position and yaw of a marker: where the actor stands and which way it faces.
function M.markerWorld(furniture, marker)
    local position = furniture.position + furniture.rotation:apply(marker.offset * furniture.scale)
    return position, furniture.rotation:getYaw() + marker.heading
end

-- ---------------------------------------------------------------- reservations

local taken = {} -- furniture or idle marker id -> npc id

-- The furniture each seated actor uses, for IsCurrentFurnitureRef in scripts (also written for the player by
-- scripts/omw/activationhandlers.lua): actor id -> furniture reference form id.
local currentFurniture = storage.globalSection('ESM4CurrentFurniture')

local function setCurrentFurniture(npcId, furniture)
    local id = nil
    if furniture ~= nil then
        local ok, refId = pcall(function() return core.obscript.dialogue.getReferenceId(furniture) end)
        id = ok and refId or ''
    end
    currentFurniture:set(tostring(npcId), id)
end

function M.release(s)
    local f = s.furn
    if f ~= nil and f.target ~= nil and taken[f.target.object.id] == f.npcId then
        taken[f.target.object.id] = nil
    end
    if f ~= nil and f.seated then
        setCurrentFurniture(f.npcId, nil)
    end
    s.furn = nil
end

-- ---------------------------------------------------------------- finding

local function isFree(obj, npc)
    return taken[obj.id] == nil or taken[obj.id] == npc.id
end

-- Nearest usable furniture marker of the wanted kind within radius of center.
-- @return { object = furniture, marker = marker, position = where the actor stands, yaw = its heading } or nil
function M.findFurniture(npc, center, radius, wantSleep)
    if types.ESM4Furniture == nil then return nil end
    local best, bestDistance = nil, math.huge
    for _, obj in ipairs(npc.cell:getAll()) do
        if types.ESM4Furniture.objectIsInstance(obj) and obj.enabled and isFree(obj, npc)
            and (obj.position - center):length() <= radius then
            local record = types.ESM4Furniture.record(obj)
            for _, marker in ipairs(types.ESM4Furniture.markers(obj)) do
                local kind = wantSleep and sleepMarkers[marker.type] or (not wantSleep and sitMarkers[marker.type])
                if kind and markerEnabled(record, marker) and markerDelta[marker.type] ~= nil then
                    local position, yaw = M.markerWorld(obj, marker)
                    local distance = (position - npc.position):length()
                    if distance < bestDistance then
                        best = { object = obj, marker = marker, position = position, yaw = yaw }
                        bestDistance = distance
                    end
                end
            end
        end
    end
    return best
end

-- The marker of one piece of furniture the NPC would use, nearest first: seats and lean spots, else beds.
-- nil when another actor uses it or it has no usable marker.
-- @return a target as findFurniture returns it, with sleep = true for a bed
function M.markerOn(npc, obj)
    if types.ESM4Furniture == nil or not types.ESM4Furniture.objectIsInstance(obj) or not isFree(obj, npc) then
        return nil
    end
    local record = types.ESM4Furniture.record(obj)
    local best, bestDistance, bestSleep = nil, math.huge, true
    for _, marker in ipairs(types.ESM4Furniture.markers(obj)) do
        local sleep = sleepMarkers[marker.type] == true
        if (sleep or sitMarkers[marker.type]) and markerEnabled(record, marker) and markerDelta[marker.type] ~= nil then
            local position, yaw = M.markerWorld(obj, marker)
            local distance = (position - npc.position):length()
            if (bestSleep and not sleep) or (sleep == bestSleep and distance < bestDistance) then
                best = { object = obj, marker = marker, position = position, yaw = yaw, sleep = sleep }
                bestDistance, bestSleep = distance, sleep
            end
        end
    end
    return best
end

-- Whether a marker's idles are for humans (markers for dogs, robots... use creature folders).
function M.hasNpcIdles(record)
    for _, id in ipairs(record.idles) do
        local idle = idles.get(id)
        if idle ~= nil and idle.model:lower():find('characters', 1, true) == 1 then
            return true
        end
    end
    return false
end

-- Nearest idle marker within radius of center that has idle animations.
function M.findIdleMarker(npc, center, radius)
    if types.ESM4IdleMarker == nil then return nil end
    local best, bestDistance = nil, math.huge
    for _, obj in ipairs(npc.cell:getAll()) do
        if types.ESM4IdleMarker.objectIsInstance(obj) and obj.enabled and isFree(obj, npc)
            and (obj.position - center):length() <= radius then
            local record = types.ESM4IdleMarker.record(obj)
            if M.hasNpcIdles(record) then
                local distance = (obj.position - npc.position):length()
                if distance < bestDistance then
                    best = { object = obj, position = obj.position, yaw = obj.rotation:getYaw(), record = record }
                    bestDistance = distance
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------- using

-- Picks the sequence for a furniture state from the idle tree.
local function furnitureIdle(npc, f, state)
    local marker = f.target.marker
    local overrides = idles.furnitureOverrides({
        sitting = f.sleep and 0 or state,
        sleeping = f.sleep and state or 0,
        marker = marker.type,
        furniture = f.target.object,
        usedItem = f.usedItem,
        procedure = f.procedure,
        lastIdle = f.lastIdle,
        package = f.package,
    })
    return idles.pick('FurnitureIdles', npc, overrides)
end

local function modelOf(idle)
    return idle and idles.modelPath(idle) or nil
end

local arrive -- below

--- Starts using furniture or an idle marker: the NPC walks to the marker first.
-- target: from findFurniture or findIdleMarker
-- opts: { sleep = bool, procedure = GetCurrentAIProcedure value, usedItem = form id of the food in hand,
--         package = package type, duration = seconds to stay (nil: until told to leave) }
function M.begin(npc, s, target, opts, now)
    M.release(s)
    opts = opts or {}
    taken[target.object.id] = npc.id
    s.furn = {
        npcId = npc.id,
        target = target,
        idleMarker = target.marker == nil,
        sleep = opts.sleep == true,
        procedure = opts.procedure,
        usedItem = opts.usedItem,
        package = opts.package,
        phase = 'go',
        since = now,
        leaveAt = opts.duration and (now + opts.duration) or nil,
        nextIdle = now,
        idleIndex = 0,
    }
    if opts.resume then
        -- a loaded game: the actor is already there
        arrive(npc, s.furn, now, true)
        if s.furn.phase == 'failed' then M.release(s) end
        return
    end
    ai.moveTo(npc, target.position, { yaw = target.yaw, tolerance = 24, run = opts.run })
end

--- What to save of the use, nil when there is nothing to come back to (still walking there, getting up).
function M.save(s, now)
    local f = s.furn
    if f == nil or f.phase ~= 'use' then return nil end
    local ok, refId = pcall(function() return core.obscript.dialogue.getReferenceId(f.target.object) end)
    if not ok or refId == nil or refId == '' then return nil end
    return {
        object = refId,
        marker = f.target.marker and f.target.marker.index or nil,
        sleep = f.sleep,
        procedure = f.procedure,
        usedItem = f.usedItem,
        package = f.package,
        leaveIn = f.leaveAt and math.max(f.leaveAt - now, 0) or nil,
    }
end

--- Takes a saved use up again, seated at once. False when the furniture or marker is gone or taken.
function M.restore(npc, s, saved, now, getObject)
    local obj = getObject(saved.object)
    if obj == nil or not isFree(obj, npc) then return false end
    local target
    if saved.marker == nil then
        if types.ESM4IdleMarker == nil or not types.ESM4IdleMarker.objectIsInstance(obj) then return false end
        target = { object = obj, position = obj.position, yaw = obj.rotation:getYaw(),
            record = types.ESM4IdleMarker.record(obj) }
    else
        if types.ESM4Furniture == nil or not types.ESM4Furniture.objectIsInstance(obj) then return false end
        for _, marker in ipairs(types.ESM4Furniture.markers(obj)) do
            if marker.index == saved.marker then
                local position, yaw = M.markerWorld(obj, marker)
                target = { object = obj, marker = marker, position = position, yaw = yaw }
            end
        end
        if target == nil then return false end
    end
    M.begin(npc, s, target, { sleep = saved.sleep, procedure = saved.procedure, usedItem = saved.usedItem,
        package = saved.package, duration = saved.leaveIn, resume = true }, now)
    return s.furn ~= nil
end

function M.inUse(s)
    return s.furn ~= nil
end

local function markerIdle(npc, f)
    local record = f.target.record
    local count = #record.idles
    if count == 0 then return nil end
    local index
    if math.floor(record.idleFlags / 1) % 2 == 1 then -- run in sequence
        index = f.idleIndex % count + 1
    else
        index = math.random(count)
    end
    f.idleIndex = index
    local idle = idles.get(record.idles[index])
    if idle == nil then return nil end
    local overrides = idles.furnitureOverrides({ package = f.package, procedure = f.procedure })
    local leaf = idles.pick(idle, npc, overrides)
    if leaf == nil and not f.loggedMiss then
        f.loggedMiss = true
        local dialogue = I.FNVDialogue
        local _, failed, value = dialogue.checkConditions(idle.conditions, npc, overrides)
        log(('%s: idle %s not playable (%s)'):format(npc.recordId, idle.editorId,
            failed and ('function %d got %s'):format(failed.func, tostring(value)) or 'no leaf'))
    end
    return leaf
end

arrive = function(npc, f, now, seated)
    local target = f.target
    if f.idleMarker then
        ai.face(npc, target.yaw)
        f.phase = 'use'
        f.nextIdle = now + 0.5
        return
    end
    local enter = furnitureIdle(npc, f, 2)
    local loop = furnitureIdle(npc, f, 1)
    local exit = furnitureIdle(npc, f, 4)
    if loop == nil then
        log(('%s: no idle for furniture marker %d'):format(npc.recordId, target.marker.type))
        f.phase = 'failed'
        return
    end
    local delta = markerDelta[target.marker.type]
    ai.useFurniture(npc, {
        position = target.position,
        yaw = target.yaw,
        offset = util.vector3(delta[1], delta[2], 0),
        headingDelta = delta[3],
        enter = modelOf(enter),
        loop = modelOf(loop),
        exit = modelOf(exit),
        seated = seated == true,
    })
    log(('%s uses %s marker %d: %s / %s / %s'):format(npc.recordId, target.object.recordId, target.marker.type,
        enter and enter.editorId or '-', loop.editorId, exit and exit.editorId or '-'))
    f.seated = true
    setCurrentFurniture(f.npcId, target.object)
    f.phase = 'use'
    f.nextIdle = now + 4 + math.random() * 8
end

--- Advances the use; call every tick while s.furn is set.
-- @return 'go', 'use', 'leave', 'done' or 'failed'
function M.tick(npc, s, now)
    local f = s.furn
    if f == nil then return 'done' end
    if f.phase == 'go' then
        local status = ai.status(npc)
        if now - f.since > 0.5 and status == 'arrived' then
            arrive(npc, f, now)
        elseif now - f.since > 0.5 and status == 'nopath' then
            f.phase = 'failed'
        elseif now - f.since > 90 then
            f.phase = 'failed'
        end
    elseif f.phase == 'use' then
        if f.leaveAt ~= nil and now >= f.leaveAt then
            M.leave(npc, s)
        elseif f.idleMarker then
            if now >= f.nextIdle and not ai.isIdlePlaying(npc) then
                local idle = markerIdle(npc, f)
                if idle ~= nil then
                    f.lastIdle = idle.id
                    ai.playIdle(npc, idles.modelPath(idle))
                end
                f.nextIdle = now + 1 + math.random() * 3
            end
        elseif ai.useStatus(npc) == 'using' and now >= f.nextIdle and not ai.isIdlePlaying(npc) then
            -- a special idle over the seated loop now and then: eating, fidgeting, stirring in sleep
            local idle = furnitureIdle(npc, f, 3)
            if idle ~= nil then
                f.lastIdle = idle.id
                ai.playIdle(npc, idles.modelPath(idle))
            end
            f.nextIdle = now + 6 + math.random() * 12
        end
    elseif f.phase == 'leave' then
        if ai.useStatus(npc) == 'none' then
            M.release(s)
            return 'done'
        end
    end
    if f.phase == 'failed' then
        M.release(s)
    end
    return f.phase
end

--- Gets up / stops idling. tick() reports 'done' once the NPC stands on the marker again.
function M.leave(npc, s)
    local f = s.furn
    if f == nil then return end
    if f.phase == 'go' or f.idleMarker then
        ai.stop(npc)
        f.phase = 'leave'
    elseif f.phase == 'use' then
        ai.leaveFurniture(npc)
        f.phase = 'leave'
    end
end

return M
