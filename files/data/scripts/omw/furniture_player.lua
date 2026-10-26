-- Player side of sitting on ESM4 furniture (see ESM4FurnitureActivation in activationhandlers.lua).
-- There is no sit animation for the player yet, so sitting locks movement and lowers the first-person camera
-- to the eye height of someone seated (or lying, in the opening of a new game). Without the FO3/FNV player
-- body the Morrowind body would stand in the seat, so then the view stays in first person until the player gets up.

local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')

-- Seated eye height over standing eye height
local seatedEyeRatio = 0.68
-- Standing eye height above the feet when the camera can't tell (third person)
local defaultStandingEye = 120
-- Ignore the movement keys that were still held when the player sat down.
local standUpDelay = 0.5

local seated = false
local seatedTime = 0
-- How far the first-person camera is lowered while seated. The camera script resets the offset on every
-- update, so it is set again each frame.
local cameraDrop = 0
local standRequested = false
local jumpPressed = false
-- View mode and vanity camera switch from before sitting down
local previousMode = nil
local previousVanity = true

input.registerTriggerHandler('Jump', async:callback(function() jumpPressed = seated end))

-- Eye height above the feet without the first-person offset
local function standingEye()
    if camera.getMode() ~= camera.MODE.FirstPerson then
        return defaultStandingEye
    end
    local eye = camera.getPosition().z - self.position.z - camera.getFirstPersonOffset().z
    if eye < 40 or eye > 250 then
        return defaultStandingEye
    end
    return eye
end

local function applyCameraDrop()
    camera.setFirstPersonOffset(util.vector3(0, 0, -cameraDrop))
end

-- data: { furniture, pose = 'sitting' | 'lying', eyeHeight = eye height above the feet (optional) }
local function lockFirstPerson()
    local ai = core.obscript and core.obscript.ai
    if ai and ai.hasPlayerBody and ai.hasPlayerBody() then
        -- the FO3/FNV body sits for real (RenderingManager::hasPlayerBody), so any view will do
        previousMode = nil
        return
    end
    previousMode = camera.getMode()
    previousVanity = types.Player.getControlSwitch(self, types.Player.CONTROL_SWITCH.VanityMode)
    types.Player.setControlSwitch(self, types.Player.CONTROL_SWITCH.VanityMode, false)
    I.Camera.disableModeControl('furniture')
    I.Camera.disableStandingPreview('furniture')
    camera.setMode(camera.MODE.FirstPerson, true)
end

local function unlockFirstPerson()
    if previousMode == nil then
        return
    end
    I.Camera.enableModeControl('furniture')
    I.Camera.enableStandingPreview('furniture')
    types.Player.setControlSwitch(self, types.Player.CONTROL_SWITCH.VanityMode, previousVanity)
    if previousMode == camera.MODE.ThirdPerson then
        camera.setMode(camera.MODE.ThirdPerson)
    end
end

local function sit(data)
    if not seated then
        lockFirstPerson()
    end
    local eye = standingEye()
    local target = data and data.eyeHeight or eye * seatedEyeRatio
    seated = true
    seatedTime = 0
    standRequested = false
    jumpPressed = false
    I.Controls.overrideMovementControls(true)
    cameraDrop = math.max(0, eye - target)
    applyCameraDrop()
end

local function stand()
    if not seated then
        return
    end
    seated = false
    I.Controls.overrideMovementControls(false)
    cameraDrop = 0
    applyCameraDrop()
    unlockFirstPerson()
end

local function wantsToStand()
    -- Scripts that take the player's movement away (DisablePlayerControls) keep the player seated.
    if not types.Player.getControlSwitch(self, types.Player.CONTROL_SWITCH.Controls) then
        return false
    end
    return input.getRangeActionValue('MoveForward') > 0 or input.getRangeActionValue('MoveBackward') > 0
        or input.getRangeActionValue('MoveLeft') > 0 or input.getRangeActionValue('MoveRight') > 0
        or jumpPressed
end

return {
    engineHandlers = {
        onFrame = function(dt)
            if not seated then
                return
            end
            applyCameraDrop()
            if standRequested or core.isWorldPaused() then
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
