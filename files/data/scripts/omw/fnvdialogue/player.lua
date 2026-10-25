-- Dialogue window for FO3/FNV conversations (see scripts/omw/fnvdialogue/global.lua).
-- Shows the speaker's response and the topics or choices to answer with.

local async = require('openmw.async')
local core = require('openmw.core')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local v2 = util.vector2

local WIDTH = 640
local normalColor = util.color.rgb(0.79, 0.65, 0.38)
local hoverColor = util.color.rgb(1.0, 0.88, 0.6)
local noticeColor = util.color.rgb(0.55, 0.55, 0.55)

local window = nil
local open = false
local closingByScript = false

local function destroyWindow()
    if window then
        window:destroy()
        window = nil
    end
end

local function close()
    destroyWindow()
    if open then
        open = false
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
            textSize = 18,
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
            textSize = 18,
            textColor = normalColor,
            autoSize = true,
        },
    }
    line.events = {
        mouseClick = async:callback(onClick),
        focusGain = async:callback(function()
            line.props.textColor = hoverColor
            if window then window:update() end
        end),
        focusLoss = async:callback(function()
            line.props.textColor = normalColor
            if window then window:update() end
        end),
    }
    return line
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
        open = true
        I.UI.setMode('Interface', { windows = {} })
    end

    local content = ui.content {}
    content:add {
        type = ui.TYPE.Text,
        props = {
            text = data.speaker or '',
            textSize = 22,
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
    if data.notices and #data.notices > 0 then
        content:add(gap(8))
    end
    for i, text in ipairs(data.options or {}) do
        content:add(optionLine(i .. '. ' .. text, function()
            core.sendGlobalEvent('FNVDialogueChoose', { index = i })
        end))
        content:add(gap(4))
    end
    if data.autoContinue then
        content:add(optionLine('Continue', function()
            continueAt = nil
            core.sendGlobalEvent('FNVDialogueContinue')
        end))
        content:add(gap(4))
    end
    content:add(gap(4))
    content:add(optionLine('Goodbye', close))

    window = ui.create {
        layer = 'Windows',
        template = I.MWUI.templates.boxSolidThick,
        props = {
            relativePosition = v2(0.5, 0.5),
            anchor = v2(0.5, 0.5),
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

return {
    engineHandlers = {
        onFrame = function()
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
        FNVDialogueShow = show,
        FNVDialogueClose = function()
            close()
        end,
        UiModeChanged = function(data)
            -- Escape or another window closed the dialogue
            if open and not closingByScript and data.newMode ~= 'Interface' then
                open = false
                destroyWindow()
                core.sendGlobalEvent('FNVDialogueClose')
            end
        end,
    },
}
