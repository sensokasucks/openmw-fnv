-- Player side of sitting on ESM4 furniture (see ESM4FurnitureActivation in activationhandlers.lua).
-- There is no sit animation for the player yet, so sitting locks movement and lowers the first-person camera.

local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')

-- Standing eye height minus seated eye height, in game units.
local seatedCameraDrop = 35
-- Ignore the movement keys that were still held when the player sat down.
local standUpDelay = 0.5

local seated = false
local seatedTime = 0
local cameraOffset = nil
local standRequested = false
local jumpPressed = false

input.registerTriggerHandler('Jump', async:callback(function() jumpPressed = seated end))

local function sit()
    if not seated then
        cameraOffset = camera.getFirstPersonOffset()
    end
    seated = true
    seatedTime = 0
    standRequested = false
    jumpPressed = false
    I.Controls.overrideMovementControls(true)
    camera.setFirstPersonOffset(cameraOffset + util.vector3(0, 0, -seatedCameraDrop))
end

local function stand()
    if not seated then
        return
    end
    seated = false
    I.Controls.overrideMovementControls(false)
    camera.setFirstPersonOffset(cameraOffset)
end

local function wantsToStand()
    return input.getRangeActionValue('MoveForward') > 0 or input.getRangeActionValue('MoveBackward') > 0
        or input.getRangeActionValue('MoveLeft') > 0 or input.getRangeActionValue('MoveRight') > 0
        or jumpPressed
end

return {
    engineHandlers = {
        onFrame = function(dt)
            if not seated or standRequested or core.isWorldPaused() then
                return
            end
            seatedTime = seatedTime + dt
            if seatedTime <= standUpDelay then
                jumpPressed = false
            end
            if seatedTime > standUpDelay and wantsToStand() then
                standRequested = true
                core.sendGlobalEvent('FurnitureStandRequest', { actor = self.object })
            end
        end,
    },
    eventHandlers = {
        FurnitureSit = sit,
        FurnitureStand = stand,
    },
}
