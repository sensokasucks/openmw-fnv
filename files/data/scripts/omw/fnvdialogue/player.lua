-- Dialogue window for FO3/FNV conversations (see scripts/omw/fnvdialogue/global.lua).
-- Shows the speaker's response and the topics or choices to answer with.

local ambient = require('openmw.ambient')
local async = require('openmw.async')
local core = require('openmw.core')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local dialogueCamera = require('scripts.omw.fnvdialogue.camera')

local frame = require('scripts.omw.fnvhud.frame')

local v2 = util.vector2

local WIDTH = 640
-- the dialogue menu's font (dialog_menu.xml: font 6, Monofonto Large)
local FONT = 'FalloutFont6'
local normalColor = util.color.rgb(0.79, 0.65, 0.38)
local hoverColor = util.color.rgb(1.0, 0.88, 0.6)
local noticeColor = util.color.rgb(0.55, 0.55, 0.55)

-- As the original's dialogue menu lays it out, the speaker's line is at the top and
-- the answers at the bottom, leaving the speaker's face in the middle of the view.
local window = nil -- the line
local choices = nil -- the answers
local open = false
local closingByScript = false
-- Opened, and the UiModeChanged for its Interface mode not seen yet (see UiModeChanged)
local openPending = false
local openPendingSince = 0

local function destroyWindow()
    if window then
        window:destroy()
        window = nil
    end
    if choices then
        choices:destroy()
        choices = nil
    end
end

-- The world goes on while talking, as in the original: the speaker keeps moving,
-- blinking and talking instead of standing frozen behind the window
-- (the HUD is hidden meanwhile, as the original hides it behind the dialogue menu).
-- Other sounds fade down fDialogueFadeDecibels over fDialogueFadeSecondsIn and come back
-- over fDialogueFadeSecondsOut (Fallout_default.ini [Audio]: 6 dB, 2 s, 1 s); the radio
-- goes to fRadioDialogMute (0.5) of its volume.
local FADE_DECIBELS = 6.0
local FADE_IN = 2.0
local FADE_OUT = 1.0
local RADIO_MUTE = 0.5

local function duck(on)
    local seconds = on and FADE_IN or FADE_OUT
    if ambient.setDucking then
        ambient.setDucking(on and 10 ^ (-FADE_DECIBELS / 20) or 1, seconds)
    end
    if I.FNVRadio and I.FNVRadio.setMute then I.FNVRadio.setMute(on and RADIO_MUTE or 1, seconds) end
end

local function setOpen(value)
    open = value
    I.UI.setPauseOnMode('Interface', not value)
    if I.FNVHud then I.FNVHud.setVisible(not value) end
    duck(value)
    if not value then dialogueCamera.stop() end
end

local function close()
    destroyWindow()
    if open then
        setOpen(false)
        closingByScript = true
        I.UI.setMode()
        closingByScript = false
        core.sendGlobalEvent('FNVDialogueClose')
    end
end

local function paragraph(text, color)
    return {
        type = ui.TYPE.TextEdit,
        props = {
            text = text,
            font = FONT,
            textSize = 20,
            textColor = color or normalColor,
            autoSize = true,
            readOnly = true,
            multiline = true,
            wordWrap = true,
            size = v2(WIDTH, 0),
        },
    }
end

local function gap(height)
    return { props = { size = v2(WIDTH, height) } }
end

local function optionLine(text, onClick)
    local line = {
        type = ui.TYPE.Text,
        props = {
            text = text,
            font = FONT,
            textSize = 20,
            textColor = normalColor,
            autoSize = true,
        },
    }
    line.events = {
        mouseClick = async:callback(onClick),
        focusGain = async:callback(function()
            line.props.textColor = hoverColor
            if choices then choices:update() end
        end),
        focusLoss = async:callback(function()
            line.props.textColor = normalColor
            if choices then choices:update() end
        end),
    }
    return line
end

local function panel(content, position, anchor)
    return ui.create {
        layer = 'Windows',
        template = frame.boxSolidThick,
        props = {
            relativePosition = position,
            anchor = anchor,
        },
        content = ui.content {
            {
                template = I.MWUI.templates.padding,
                content = ui.content {
                    {
                        template = I.MWUI.templates.padding,
                        content = ui.content {
                            {
                                type = ui.TYPE.Flex,
                                props = { autoSize = true },
                                content = content,
                            },
                        },
                    },
                },
            },
        },
    }
end

local optionCount = 0
local closeAt = nil -- real time to close a Goodbye line with nothing to answer
local closeSpeaker = nil
local continueAt = nil -- real time to go on with a follow-up line

local function show(data)
    optionCount = #(data.options or {})
    closeAt = data.autoClose and (core.getRealTime() + data.autoClose) or nil
    continueAt = data.autoContinue and (core.getRealTime() + data.autoContinue) or nil
    closeSpeaker = data.speakerObject
    destroyWindow()
    if not open then
        setOpen(true)
        openPending = I.UI.getMode() ~= 'Interface'
        openPendingSince = core.getRealTime()
        I.UI.setMode('Interface', { windows = {} })
        if data.speakerObject then dialogueCamera.start(data.speakerObject) end
    end

    local content = ui.content {}
    content:add {
        type = ui.TYPE.Text,
        props = {
            text = data.speaker or '',
            font = FONT,
            textSize = 24,
            textColor = hoverColor,
            autoSize = true,
        },
    }
    content:add(gap(8))
    if data.text and data.text ~= '' then
        content:add(paragraph(data.text))
        content:add(gap(12))
    end
    for _, note in ipairs(data.notices or {}) do
        content:add(paragraph(note, noticeColor))
    end
    local answers = ui.content {}
    for i, text in ipairs(data.options or {}) do
        answers:add(optionLine(i .. '. ' .. text, function()
            core.sendGlobalEvent('FNVDialogueChoose', { index = i })
        end))
        answers:add(gap(4))
    end
    if data.autoContinue then
        answers:add(optionLine('Continue', function()
            continueAt = nil
            core.sendGlobalEvent('FNVDialogueContinue')
        end))
        answers:add(gap(4))
    end
    answers:add(optionLine('Goodbye', close))

    window = panel(content, v2(0.5, 0.04), v2(0.5, 0))
    choices = panel(answers, v2(0.5, 0.96), v2(0.5, 1))
end

return {
    engineHandlers = {
        onFrame = function(dt)
            dialogueCamera.update(core.getRealFrameDuration())
            -- in case the change to Interface mode never comes as an event
            if openPending and core.getRealTime() - openPendingSince > 1 then openPending = false end
            if open and continueAt ~= nil and core.getRealTime() >= continueAt then
                local ok, talking = pcall(core.sound.isSayActive, closeSpeaker)
                if not (ok and talking) then
                    continueAt = nil
                    core.sendGlobalEvent('FNVDialogueContinue')
                end
            end
            if not open or closeAt == nil or core.getRealTime() < closeAt then return end
            -- wait for the voice too, when there is one
            local ok, talking = pcall(core.sound.isSayActive, closeSpeaker)
            if ok and talking then return end
            closeAt = nil
            close()
        end,
        -- Number keys pick the answer with that number, as in the original.
        onKeyPress = function(key)
            if not open then return end
            local n = tonumber(key.symbol)
            if n and n >= 1 and n <= optionCount then
                core.sendGlobalEvent('FNVDialogueChoose', { index = n })
            end
        end,
    },
    eventHandlers = {
        -- from scripts/omw/furniture_player.lua: the view the player should be in once the dialogue ends
        FNVFurnitureView = function(data)
            dialogueCamera.setPreviousMode(data.mode)
        end,
        FNVDialogueShow = show,
        FNVDialogueClose = function()
            close()
        end,
        UiModeChanged = function(data)
            -- Escape or another window closed the dialogue. UiModeChanged comes a frame or two late, so the
            -- close of a conversation that ended just before this one opened is ignored (as in fnvpipboy).
            if data.newMode == 'Interface' then
                openPending = false
            elseif open and not closingByScript and not openPending then
                setOpen(false)
                destroyWindow()
                core.sendGlobalEvent('FNVDialogueClose')
            end
        end,
    },
}
