-- The view while talking, as FalloutNV.exe frames it (DialogMenu update 0x762950 and
-- PlayerCharacter::FocusOnActor 0x953060):
--
-- * the view goes to first person and turns onto the speaker's face, a little below
--   the middle of the head (fDlgLookAdj), while the field of view narrows until the
--   head fills about fDlgFocus head sizes: FOV = atan(fDlgFocus * r / d) * 100 degrees,
--   no wider than the normal FOV. Both ease in over fDialogZoomInSeconds: each frame
--   moves dt / ((1 - zoom) * fDialogZoomInSeconds) of the way, zoom being the share of
--   that time gone by.
-- * once zoomed in, the view only follows the speaker when the face drifts more than
--   fDlgLookDegStart degrees (fewer the narrower the view) off centre, at fDlgLookMult
--   times the angle per second, and stops within fDlgLookDegStop.
-- * leaving, the view widens back over fDialogZoomOutSeconds and the player is left
--   facing the speaker.
-- * meanwhile what is nearer or further than the speaker blurs, fully at
--   fDialogFocalDepthRange from them, fDialogFocalDepthStrength times the zoom
--   (shaders/fnvdialoguedof.omwfx; only with post-processing turned on).

local camera = require('openmw.camera')
local core = require('openmw.core')
local self = require('openmw.self')
local util = require('openmw.util')

local MODE = camera.MODE

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or default
end

-- [Interface] settings of the original; Fallout_default.ini leaves them at these
local DLG_FOCUS = 3.2
local DLG_LOOK_ADJ = -5.0
local DLG_LOOK_DEG_START = 13.0
local DLG_LOOK_DEG_STOP = 0.2
local DLG_LOOK_MULT = 2.0

-- "Bip01 Head" sits at the top of the neck; the middle of a head is about this far
-- above it, and the original's head bound (all head parts) is about this wide
local HEAD_CENTRE_UP = 9
local HEAD_RADIUS = 12

local M = {}

local state = nil

-- The background blur; nil when post-processing can't load it
local blurShader = nil
local blurTried = false
local blurOn = false

local function setBlur(strength, focus)
    if not blurTried then
        blurTried = true
        local ok, postprocessing = pcall(require, 'openmw.postprocessing')
        if ok then
            local loaded, shader = pcall(postprocessing.load, 'fnvdialoguedof')
            if loaded then blurShader = shader end
        end
    end
    if blurShader == nil then return end
    if strength <= 0 then
        if blurOn then
            blurShader:disable()
            blurOn = false
        end
        return
    end
    if not blurOn then
        blurShader:enable()
        blurOn = true
    end
    blurShader:setFloat('uStrength', strength)
    blurShader:setFloat('uRange', gmst('fDialogFocalDepthRange', 300))
    if focus then blurShader:setFloat('uFocus', focus) end
end

local function wrap(angle)
    return util.normalizeAngle(angle)
end

local function lookPoint(speaker)
    if not speaker:isValid() then return nil end
    local ai = core.obscript and core.obscript.ai
    local head = ai and ai.getHeadPosition and ai.getHeadPosition(speaker)
    if head == nil then
        local ok, box = pcall(function() return speaker:getBoundingBox() end)
        if not ok or box == nil then return nil end
        head = box.center + util.vector3(0, 0, box.halfSize.z - HEAD_CENTRE_UP)
    end
    return head + util.vector3(0, 0, HEAD_CENTRE_UP + DLG_LOOK_ADJ)
end

-- Yaw and pitch (object rotation convention: pitch > 0 looks down) from the eye to p
local function anglesTo(p)
    local d = p - camera.getPosition()
    local horizontal = math.sqrt(d.x * d.x + d.y * d.y)
    return math.atan2(d.x, d.y), -math.atan2(d.z, horizontal), d:length()
end

local function apply()
    camera.setFieldOfView(state.fov)
    camera.setExtraYaw(wrap(state.yaw - self.rotation:getYaw()))
    camera.setExtraPitch(state.pitch - self.rotation:getPitch())
end

function M.start(speaker)
    if state then
        state.speaker = speaker
        state.phase = 'in'
        state.elapsed = 0
        state.zoom = 0
        state.targetFov = nil
        return
    end
    local mode = camera.getMode()
    state = {
        speaker = speaker,
        phase = 'in',
        elapsed = 0,
        zoom = 0,
        previousMode = mode,
        baseFov = camera.getFieldOfView(),
        fov = camera.getFieldOfView(),
        yaw = camera.getYaw() + camera.getExtraYaw(),
        pitch = camera.getPitch() + camera.getExtraPitch(),
        following = { yaw = false, pitch = false },
    }
    if mode ~= MODE.FirstPerson then
        camera.setMode(MODE.FirstPerson, true)
        state.yaw = self.rotation:getYaw()
        state.pitch = self.rotation:getPitch()
    end
end

function M.stop()
    if state == nil or state.phase == 'out' then return end
    state.phase = 'out'
    state.elapsed = 0
    state.outFrom = state.fov
end

function M.isActive()
    return state ~= nil
end

-- Moves the view toward the target angle by `step` (0-1) of the way, or, once zoomed
-- in, only after it has drifted fDlgLookDegStart off and until within fDlgLookDegStop.
local function follow(axis, target, step, fovRatio, dt)
    local diff = wrap(target - state[axis])
    if state.zoom < 1 then
        state[axis] = state[axis] + diff * step
        return
    end
    local magnitude = math.abs(diff)
    if magnitude > math.rad(DLG_LOOK_DEG_START) * fovRatio then
        state.following[axis] = true
    end
    if state.following[axis] then
        state[axis] = state[axis] + diff * math.min(1, DLG_LOOK_MULT * dt)
        if math.abs(wrap(target - state[axis])) < math.rad(DLG_LOOK_DEG_STOP) * fovRatio then
            state.following[axis] = false
        end
    end
end

function M.update(dt)
    if state == nil or dt <= 0 then return end
    state.elapsed = state.elapsed + dt

    if state.phase == 'out' then
        local zoomOut = gmst('fDialogZoomOutSeconds', 0.5)
        local t = zoomOut > 0 and math.min(1, state.elapsed / zoomOut) or 1
        state.fov = state.outFrom + (state.baseFov - state.outFrom) * t
        -- the player turns to where the view looks, so the view stays put as the
        -- offsets run out
        self.controls.yawChange = wrap(state.yaw - self.rotation:getYaw())
        self.controls.pitchChange = state.pitch - self.rotation:getPitch()
        apply()
        setBlur(gmst('fDialogFocalDepthStrength', 0.65) * (1 - t), nil)
        if t >= 1 then
            setBlur(0)
            camera.setFieldOfView(state.baseFov)
            camera.setExtraYaw(0)
            camera.setExtraPitch(0)
            if state.previousMode ~= MODE.FirstPerson and camera.getMode() == MODE.FirstPerson then
                camera.setMode(state.previousMode, true)
            end
            state = nil
        end
        return
    end

    local point = lookPoint(state.speaker)
    if point == nil then return end
    local yaw, pitch, distance = anglesTo(point)
    local zoomIn = gmst('fDialogZoomInSeconds', 1.5)
    if state.targetFov == nil and distance > 0 then
        state.targetFov = math.min(state.baseFov, math.atan(DLG_FOCUS * HEAD_RADIUS / distance) * 100 * math.pi / 180)
    end
    local step = 1
    if state.zoom < 1 and zoomIn > 0 then
        step = math.min(1, dt / ((1 - state.zoom) * zoomIn))
    end
    if state.targetFov then
        state.fov = state.fov + (state.targetFov - state.fov) * step
    end
    local fovRatio = state.fov / state.baseFov
    follow('yaw', yaw, step, fovRatio, dt)
    follow('pitch', pitch, step, fovRatio, dt)
    state.zoom = zoomIn > 0 and math.min(1, state.elapsed / zoomIn) or 1
    apply()
    setBlur(gmst('fDialogFocalDepthStrength', 0.65) * state.zoom, distance)
end

return M
