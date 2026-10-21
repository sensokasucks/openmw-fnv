local async = require('openmw.async')
local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local util = require('openmw.util')
local auxUtil = require('openmw_aux.util')

local EnableObject = async:registerTimerCallback('EnableObject', function(obj) obj.enabled = true end)

local function ESM4DoorActivation(door, actor)
    -- TODO: Implement lockpicking minigame
    -- TODO: Play door opening animation
    local Door4 = types.ESM4Door
    core.sound.playSound3d(Door4.record(door).openSound, actor)
    if Door4.isTeleport(door) then
        actor:teleport(Door4.destCell(door), Door4.destPosition(door), Door4.destRotation(door))
    else
        door.enabled = false
        async:newSimulationTimer(5, EnableObject, door)
    end
    return false -- disable activation handling in C++ mwmechanics code
end

-- Furniture marker types (FO3/FNV furnituremarkerNN.nif) that are beds; the player sleeps there instead of sitting.
local bedMarkerTypes = { [1] = true, [2] = true, [3] = true, [4] = true }
-- Markers for working or leaning in place, not for sitting.
local standingMarkerTypes = { [19] = true, [22] = true, [23] = true, [26] = true }
-- Side entries (left, right) and stools: the seat is the furniture's origin.
local centeredSeatTypes = { [11] = true, [12] = true, [15] = true }

local seatedActors = {}

local function headingVector(yaw)
    return util.vector3(math.sin(yaw), math.cos(yaw), 0)
end

local function markerEnabled(record, marker)
    local flags = record.activeMarkerFlags
    return flags == 0 or (math.floor(flags / 2 ^ marker.index) % 2) == 1
end

-- Seat position and yaw in model space for a marker. A marker is where the actor stands facing the
-- furniture before the sit animation; without that animation we place the actor on the seat directly.
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
    types.ESM4Furniture._setActorCollision(actor, true)
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
    seatedActors[actor.id] = { cell = actor.cell, position = actor.position, rotation = actor.rotation }
    Furniture4._setActorCollision(actor, false)
    actor:teleport(furniture.cell, furniture.position + furniture.rotation:apply(seat * furniture.scale),
        { rotation = yawRotation, onGround = false })
    actor:sendEvent('FurnitureSit', { furniture = furniture })
    return false
end

local function ESM4BookActivation(book, actor)
    if actor.type == types.Player then
        actor:sendEvent('AddUiMode', { mode = 'Book', target = book })
    end
end

local handlersPerObject = {}
local handlersPerType = {}

handlersPerType[types.ESM4Book] = { ESM4BookActivation }
handlersPerType[types.ESM4Door] = { ESM4DoorActivation }
handlersPerType[types.ESM4Furniture] = { ESM4FurnitureActivation }

local function runDefaultActivation(obj, actor)
    local handled = auxUtil.callMultipleEventHandlers({ handlersPerType[obj.type] }, obj, actor)
    if handled then
        return
    end
    types.Actor.activeEffects(actor):remove('invisibility')
    world._runStandardActivationAction(obj, actor)
end

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
    eventHandlers = { FurnitureStandRequest = function(data) standUp(data.actor) end },
}
