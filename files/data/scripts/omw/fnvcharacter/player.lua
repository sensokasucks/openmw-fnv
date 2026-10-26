-- Level-up window for FNV leveling (see scripts/omw/fnvcharacter/global.lua):
-- spend the skill points of the new level and pick a perk. Also shows the
-- XP, karma and reputation messages the global script sends.

local async = require('openmw.async')
local core = require('openmw.core')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local frame = require('scripts.omw.fnvhud.frame')

local v2 = util.vector2

local WIDTH = 520
local PERKS_PER_PAGE = 10
local REOPEN_DELAY = 10 -- seconds of play before a dismissed window comes back

local normalColor = util.color.rgb(0.79, 0.65, 0.38)
local hoverColor = util.color.rgb(1.0, 0.88, 0.6)
local dimColor = util.color.rgb(0.45, 0.4, 0.3)

local window = nil
local open = false
local closingByScript = false
local data = nil -- the last FNVLevelUp event
local alloc = {} -- skill -> points added in this window
local chosenPerk = nil
local perkPage = 1
local reopenTimer = nil

local function destroyWindow()
    if window then
        window:destroy()
        window = nil
    end
end

local function setOpen(value)
    if value == open then return end
    open = value
    closingByScript = true
    if value then
        I.UI.setMode('Interface', { windows = {} })
    else
        I.UI.setMode()
    end
    closingByScript = false
end

local function spent()
    local total = 0
    for _, n in pairs(alloc) do total = total + n end
    return total
end

-- Points that can still go somewhere (skills cap at 100).
local function room()
    local total = 0
    for _, skill in ipairs(data.skills) do
        total = total + math.max(0, 100 - skill.value - (alloc[skill.av] or 0))
    end
    return total
end

local function canFinish()
    if data == nil then return false end
    local left = data.skillPoints - spent()
    if left > 0 and room() > 0 then return false end
    if data.perks > 0 and #data.perkChoices > 0 and chosenPerk == nil then return false end
    return true
end

local render

local function text(str, size, color)
    return {
        type = ui.TYPE.Text,
        props = { text = str, textSize = size or 18, textColor = color or normalColor, autoSize = true },
    }
end

local function gap(height)
    return { props = { size = v2(WIDTH, height) } }
end

local function button(str, enabled, onClick, color)
    local line = text(str, 18, enabled and (color or normalColor) or dimColor)
    if enabled then
        local base = color or normalColor
        line.events = {
            mouseClick = async:callback(onClick),
            focusGain = async:callback(function()
                line.props.textColor = hoverColor
                if window then window:update() end
            end),
            focusLoss = async:callback(function()
                line.props.textColor = base
                if window then window:update() end
            end),
        }
    end
    return line
end

local function row(cells)
    local content = ui.content {}
    for _, cell in ipairs(cells) do
        content:add(cell)
    end
    return {
        type = ui.TYPE.Flex,
        props = { horizontal = true, autoSize = true },
        content = content,
    }
end

local function fixed(width, child)
    return { props = { size = v2(width, 24) }, content = ui.content { child } }
end

local function finish()
    if not canFinish() then return end
    core.sendGlobalEvent('FNVCharacterSpend', { skillPoints = alloc, perk = chosenPerk })
    data = nil
    alloc = {}
    chosenPerk = nil
    destroyWindow()
    setOpen(false)
end

local function skillRows(content)
    local left = data.skillPoints - spent()
    content:add(text(('Skill points left: %d'):format(left), 20, hoverColor))
    content:add(gap(6))
    for _, skill in ipairs(data.skills) do
        local added = alloc[skill.av] or 0
        local value = skill.value + added
        content:add(row {
            fixed(220, text(skill.name)),
            fixed(70, text(tostring(value), 18, added > 0 and hoverColor or normalColor)),
            fixed(40, button('[-]', added > 0, function()
                alloc[skill.av] = added - 1
                render()
            end)),
            fixed(40, button('[+]', left > 0 and value < 100, function()
                alloc[skill.av] = added + 1
                render()
            end)),
        })
    end
end

local function perkRows(content)
    local choices = data.perkChoices
    content:add(text('Choose a perk', 20, hoverColor))
    content:add(gap(6))
    local pages = math.max(1, math.ceil(#choices / PERKS_PER_PAGE))
    perkPage = math.min(perkPage, pages)
    local first = (perkPage - 1) * PERKS_PER_PAGE + 1
    local chosen = nil
    for i = first, math.min(#choices, first + PERKS_PER_PAGE - 1) do
        local perk = choices[i]
        local label = perk.name
        if perk.ranks > 1 then label = ('%s (rank %d/%d)'):format(label, perk.rank + 1, perk.ranks) end
        local selected = perk.id == chosenPerk
        if selected then chosen = perk end
        content:add(button((selected and '> ' or '  ') .. label, true, function()
            chosenPerk = perk.id
            render()
        end, selected and hoverColor or normalColor))
    end
    if pages > 1 then
        content:add(row {
            fixed(90, button('< Prev', perkPage > 1, function()
                perkPage = perkPage - 1
                render()
            end)),
            fixed(120, text(('%d / %d'):format(perkPage, pages))),
            fixed(90, button('Next >', perkPage < pages, function()
                perkPage = perkPage + 1
                render()
            end)),
        })
    end
    if chosen and chosen.description ~= '' then
        content:add(gap(6))
        content:add {
            type = ui.TYPE.TextEdit,
            props = {
                text = chosen.description, textSize = 16, textColor = normalColor, autoSize = true,
                readOnly = true, multiline = true, wordWrap = true, size = v2(WIDTH, 0),
            },
        }
    end
end

render = function()
    destroyWindow()
    if data == nil then return end
    local content = ui.content {}
    content:add(text(('Level %d'):format(data.level or 0), 24, hoverColor))
    content:add(gap(10))
    if data.skillPoints > 0 then
        skillRows(content)
        content:add(gap(12))
    end
    if data.perks > 0 and #data.perkChoices > 0 then
        perkRows(content)
        content:add(gap(12))
    end
    content:add(button('Done', canFinish(), finish))

    window = ui.create {
        layer = 'Windows',
        template = frame.boxSolidThick,
        props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5) },
        content = ui.content {
            {
                template = I.MWUI.templates.padding,
                content = ui.content {
                    {
                        template = I.MWUI.templates.padding,
                        content = ui.content {
                            { type = ui.TYPE.Flex, props = { autoSize = true }, content = content },
                        },
                    },
                },
            },
        },
    }
end

local function show()
    if data == nil then return end
    reopenTimer = nil
    if I.UI.getMode() ~= nil and not open then
        -- another window is open: come back when it closes
        reopenTimer = 0
        return
    end
    setOpen(true)
    render()
end

return {
    engineHandlers = {
        onFrame = function(dt)
            if reopenTimer == nil or data == nil or open then return end
            if I.UI.getMode() ~= nil or core.isWorldPaused() then return end
            reopenTimer = reopenTimer + dt
            if reopenTimer >= REOPEN_DELAY then show() end
        end,
    },
    eventHandlers = {
        FNVLevelUp = function(levelUp)
            data = levelUp
            alloc = {}
            chosenPerk = nil
            perkPage = 1
            if open then
                render()
            else
                -- give the level-up message a moment before the window takes over
                reopenTimer = REOPEN_DELAY - 1.5
            end
        end,
        FNVCharacterMessage = function(msg)
            if msg and msg.text then ui.showMessage(msg.text) end
        end,
        UiModeChanged = function(change)
            -- Escape or another window closed the level-up window: offer it again later
            if open and not closingByScript and change.newMode ~= 'Interface' then
                open = false
                destroyWindow()
                reopenTimer = 0
            end
        end,
    },
}
