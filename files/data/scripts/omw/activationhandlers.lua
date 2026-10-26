local async = require('openmw.async')
local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local world = require('openmw.world')
local util = require('openmw.util')
local auxUtil = require('openmw_aux.util')

local EnableObject = async:registerTimerCallback('EnableObject', function(obj) obj.enabled = true end)

local function ESM4DoorActivation(door, actor)
    -- TODO: Implement lockpicking minigame
    local Door4 = types.ESM4Door
    if not Door4.isTeleport(door) then
        return -- C++ (MWClass::ESM4Door) plays the open/close animation and sound
    end
    core.sound.playSound3d(Door4.record(door).openSound, actor)
    actor:teleport(Door4.destCell(door), Door4.destPosition(door), Door4.destRotation(door))
    return false -- disable activation handling in C++ mwmechanics code
end

-- Furniture marker types (FO3/FNV furnituremarkerNN.nif) that are beds; the player sleeps there instead of sitting.
local bedMarkerTypes = { [1] = true, [2] = true, [3] = true, [4] = true }
-- Markers for working or leaning in place, not for sitting.
local standingMarkerTypes = { [19] = true, [22] = true, [23] = true, [26] = true }
-- Side entries (left, right) and stools: the seat is the furniture's origin.
local centeredSeatTypes = { [11] = true, [12] = true, [15] = true }

local seatedActors = {}

-- The player's FO3/FNV body (RenderingManager::hasPlayerBody) plays the loop the idle tree picks for the
-- furniture, as NPCs do (scripts/omw/fnvai/idles.lua); state: { sitting, sleeping, marker }.
local function playPlayerBodyIdle(player, state)
    local ai = core.obscript and core.obscript.ai
    if ai == nil or ai.setPlayerBodyIdle == nil then
        return
    end
    if state == nil then
        ai.setPlayerBodyIdle(nil)
        return
    end
    local ok, idles = pcall(require, 'scripts.omw.fnvai.idles')
    local leaf = ok and idles.pick('FurnitureIdles', player, idles.furnitureOverrides(state)) or nil
    ai.setPlayerBodyIdle(leaf and idles.modelPath(leaf) or nil)
end

-- The furniture each seated actor uses, for IsCurrentFurnitureRef in scripts:
-- actor id -> furniture reference form id.
local furnitureSection = storage.globalSection('ESM4CurrentFurniture')
furnitureSection:setLifeTime(storage.LIFE_TIME.GameSession)

local function headingVector(yaw)
    return util.vector3(math.sin(yaw), math.cos(yaw), 0)
end

local function markerEnabled(record, marker)
    local flags = record.activeMarkerFlags
    return flags == 0 or (math.floor(flags / 2 ^ marker.index) % 2) == 1
end

-- Seat position and yaw in model space for a marker. A marker is where the actor stands facing the
-- furniture before the sit animation; without that animation we place the actor on the seat directly.
-- The marker's height is the floor's; the player script lowers the camera to a seated eye height.
local function seatFromMarker(marker)
    local offset = marker.offset
    local facing = headingVector(marker.heading)
    local seat, yaw
    if centeredSeatTypes[marker.type] then
        seat = util.vector3(0, 0, offset.z)
    else
        local distance = math.max(0, -(offset.x * facing.x + offset.y * facing.y) - 10)
        seat = offset + facing * distance
    end
    if marker.type == 11 then
        yaw = marker.heading - math.pi / 2
    elseif marker.type == 12 then
        yaw = marker.heading + math.pi / 2
    else
        yaw = marker.heading + math.pi
    end
    return seat, yaw
end

local function standUp(actor)
    local seated = seatedActors[actor.id]
    if not seated then
        return
    end
    seatedActors[actor.id] = nil
    furnitureSection:set(tostring(actor.id), nil)
    types.ESM4Furniture._setActorCollision(actor, true)
    playPlayerBodyIdle(actor, nil)
    actor:teleport(seated.cell, seated.position, { rotation = seated.rotation, onGround = true })
    actor:sendEvent('FurnitureStand', {})
end

local function ESM4FurnitureActivation(furniture, actor)
    if actor.type ~= types.Player then
        return
    end
    local Furniture4 = types.ESM4Furniture
    local record = Furniture4.record(furniture)
    local best, bestDistance
    for _, marker in ipairs(Furniture4.markers(furniture)) do
        if markerEnabled(record, marker) and not standingMarkerTypes[marker.type] then
            local markerPos = furniture.position + furniture.rotation:apply(marker.offset * furniture.scale)
            local distance = (markerPos - actor.position):length()
            if not best or distance < bestDistance then
                best, bestDistance = marker, distance
            end
        end
    end
    if not best then
        return
    end
    if bedMarkerTypes[best.type] then
        actor:sendEvent('AddUiMode', { mode = 'Rest' })
        return false
    end

    local seat, yaw = seatFromMarker(best)
    local yawRotation = util.transform.rotateZ(furniture.rotation:getYaw() + yaw)
    seatedActors[actor.id] = { cell = actor.cell, position = actor.position, rotation = actor.rotation,
        furniture = furniture }
    local ok, furnitureId = pcall(function() return core.obscript.dialogue.getReferenceId(furniture) end)
    furnitureSection:set(tostring(actor.id), ok and furnitureId or '')
    Furniture4._setActorCollision(actor, false)
    actor:teleport(furniture.cell, furniture.position + furniture.rotation:apply(seat * furniture.scale),
        { rotation = yawRotation, onGround = false })
    actor:sendEvent('FurnitureSit', { furniture = furniture, pose = 'sitting' })
    playPlayerBodyIdle(actor, { sitting = 1, marker = best.type })
    return false
end

-- The bed next to the opening's start marker (VCG01PlayerStartMarkerREF beside Doc Mitchell's bed)
local function bedNear(marker)
    local best, bestDistance
    for _, furniture in ipairs(marker.cell:getAll(types.ESM4Furniture)) do
        local distance = (furniture.position - marker.position):length()
        if distance < 200 and (not best or distance < bestDistance) then
            for _, m in ipairs(types.ESM4Furniture.markers(furniture)) do
                if bedMarkerTypes[m.type] then
                    best, bestDistance = furniture, distance
                    break
                end
            end
        end
    end
    return best
end

-- Where the player gets up next to the bed: the marker touches the bed (and the chair beside it), and a
-- player placed there ends up standing on top of them. So the spot is a stride from the marker, in the
-- direction with the most room between the bed's bounds and the other furniture around.
local function standingSpot(marker, bed, box)
    local function clearance(point)
        local room = math.huge
        if box then
            local dx = math.max(math.abs(point.x - box.center.x) - box.halfSize.x, 0)
            local dy = math.max(math.abs(point.y - box.center.y) - box.halfSize.y, 0)
            room = math.sqrt(dx * dx + dy * dy)
        end
        for _, obj in ipairs(marker.cell:getAll(types.ESM4Furniture)) do
            if obj ~= bed then
                local d = obj.position - point
                room = math.min(room, util.vector2(d.x, d.y):length())
            end
        end
        return room
    end
    local best, bestRoom = marker.position, -1
    for i = 0, 7 do
        local angle = i * math.pi / 4
        local point = marker.position + util.vector3(math.cos(angle), math.sin(angle), 0) * 60
        local room = clearance(point)
        if room > bestRoom then
            best, bestRoom = point, room
        end
    end
    return best
end

-- The opening of a new game: the player wakes lying in the bed, sits up on its edge, then gets up at the
-- start marker. The original plays the player's wake-up, sit-up and stand-up idles (VCG01's
-- VCG01PlayerSection packages); without a player body the camera takes those heights instead.
-- data: { pose = 'lying' | 'sitting' | 'standing', marker = start marker }
local function setPlayerPose(data)
    local player = world.players[1]
    local marker = data.marker
    if player == nil or marker == nil or not marker:isValid() or marker.cell == nil then
        return
    end
    if data.pose == 'standing' then
        standUp(player)
        return
    end
    local bed = bedNear(marker)
    if bed == nil then
        return
    end
    local ok, box = pcall(bed.getBoundingBox, bed)
    local center = ok and box and box.center or bed.position
    local floor = marker.position.z
    local spot = center
    if data.pose == 'sitting' then
        -- on the edge of the bed, on the marker's side
        spot = center + (marker.position - center) * 0.55
    end
    if not seatedActors[player.id] then
        seatedActors[player.id] = { cell = marker.cell, position = standingSpot(marker, bed, ok and box or nil),
            rotation = marker.rotation, furniture = bed }
    end
    types.ESM4Furniture._setActorCollision(player, false)
    player:teleport(marker.cell, util.vector3(spot.x, spot.y, floor), { rotation = marker.rotation, onGround = false })
    -- eyes just above the pillow, or those of someone sitting on the edge (the bounds take in the headboard,
    -- so the heights are the usual ones for a bed's mattress, about 40 units up)
    local eyeHeight = data.pose == 'lying' and 52 or 88
    player:sendEvent('FurnitureSit', { furniture = bed, pose = data.pose, eyeHeight = eyeHeight })
    if data.pose == 'lying' then
        playPlayerBodyIdle(player, { sleeping = 1, marker = 1 })
    else
        playPlayerBodyIdle(player, { sitting = 1, marker = 15 })
    end
end

local function ESM4BookActivation(book, actor)
    if actor.type == types.Player then
        actor:sendEvent('AddUiMode', { mode = 'Book', target = book })
    end
    return false -- read in place; C++ would otherwise pick the book up
end

local function ESM4NoteActivation(note, actor)
    if actor.type == types.Player then
        -- Notes go to the player's notes list (the Pip-Boy data tab), not the inventory.
        actor:sendEvent('ESM4PickUpNote', { note = note.recordId })
        note:remove()
    end
    return false
end

local function ESM4TerminalActivation(terminal, actor)
    if actor.type == types.Player then
        actor:sendEvent('ESM4OpenTerminal', { terminal = terminal })
    end
    return false
end

-- FO3/FNV locks: open with a carried key, or pick the lock (see MWClass::ESM4Lock).
-- Appended to the ESM4Door handlers so it runs before them.
local function ESM4LockActivation(obj, actor)
    if not types.Lockable._esm4TryOpen(obj, actor) then
        return false
    end
end

local handlersPerObject = {}
local handlersPerType = {}

handlersPerType[types.ESM4Book] = { ESM4BookActivation }
handlersPerType[types.ESM4Door] = { ESM4DoorActivation }
handlersPerType[types.ESM4Furniture] = { ESM4FurnitureActivation }
handlersPerType[types.ESM4Note] = { ESM4NoteActivation }
handlersPerType[types.ESM4Terminal] = { ESM4TerminalActivation }

local function runDefaultActivation(obj, actor)
    local handled = auxUtil.callMultipleEventHandlers({ handlersPerType[obj.type] }, obj, actor)
    if handled then
        return
    end
    types.Actor.activeEffects(actor):remove('invisibility')
    world._runStandardActivationAction(obj, actor)
end

table.insert(handlersPerType[types.ESM4Door], ESM4LockActivation)

local function onActivate(obj, actor)
    if world.isWorldPaused() then
        return
    end
    if obj.parentContainer then
        return
    end
    if seatedActors[actor.id] then
        standUp(actor)
        return
    end
    local handled = auxUtil.callMultipleEventHandlers({ handlersPerObject[obj.id] }, obj, actor)
    if handled then
        return
    end
    runDefaultActivation(obj, actor)
end

return {
    interfaceName = 'Activation',
    ---
    -- @module Activation
    -- @context global
    -- @usage require('openmw.interfaces').Activation
    interface = {
        --- Interface version
        -- @field [parent=#Activation] #number version
        version = 0,

        --- Add a new activation handler for a specific object.
        -- If `handler(object, actor)` returns false, other handlers for
        -- the same object (including type handlers) will be skipped.
        -- @function [parent=#Activation] addHandlerForObject
        -- @param openmw.core#GameObject obj The object.
        -- @param #function handler The handler.
        addHandlerForObject = function(obj, handler)
            local handlers = handlersPerObject[obj.id]
            if handlers == nil then
                handlers = {}
                handlersPerObject[obj.id] = handlers
            end
            handlers[#handlers + 1] = handler
        end,

        --- Add a new activation handler for a type of object.
        -- If `handler(object, actor)` returns false, other handlers for
        -- the same object (including type handlers) will be skipped.
        -- @function [parent=#Activation] addHandlerForType
        -- @param #any type A type from the `openmw.types` package.
        -- @param #function handler The handler.
        addHandlerForType = function(type, handler)
            local handlers = handlersPerType[type]
            if handlers == nil then
                handlers = {}
                handlersPerType[type] = handlers
            end
            handlers[#handlers + 1] = handler
        end,

        --- Run the default activation of an object (type handlers and the
        -- engine's standard action), skipping per-object handlers. Used by the
        -- ObScript `Activate` command, whose OnActivate block replaces the
        -- default activation and must be able to invoke it explicitly.
        -- @function [parent=#Activation] runDefaultActivation
        -- @param openmw.core#GameObject obj The object.
        -- @param openmw.core#GameObject actor The activating actor.
        runDefaultActivation = runDefaultActivation,
    },
    engineHandlers = { onActivate = onActivate },
    eventHandlers = {
        FurnitureStandRequest = function(data) standUp(data.actor) end,
        FNVPlayerPose = setPlayerPose,
    },
}
