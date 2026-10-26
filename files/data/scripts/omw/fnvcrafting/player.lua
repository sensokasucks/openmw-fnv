-- FNV crafting window (see scripts/omw/fnvcrafting/global.lua): the recipes of
-- one category with what each needs; clicking one that can be made makes one.

local async = require('openmw.async')
local core = require('openmw.core')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local frame = require('scripts.omw.fnvhud.frame')

local v2 = util.vector2

local WIDTH = 560
local ROWS = 14
local normalColor = util.color.rgb(0.79, 0.65, 0.38)
local hoverColor = util.color.rgb(1.0, 0.88, 0.6)
local dimColor = util.color.rgb(0.55, 0.55, 0.55)

local window = nil
local open = false
local closingByScript = false
local sharedMode = false -- opened over another window (the dialogue); leaving goes back to it
local data = nil
local page = 1
local message = nil
local refreshAt = nil

local function destroyWindow()
    if window then
        window:destroy()
        window = nil
    end
end

local function close()
    destroyWindow()
    data = nil
    if open then
        open = false
        if not sharedMode then
            closingByScript = true
            I.UI.setMode()
            closingByScript = false
        end
        core.sendGlobalEvent('FNVRecipeClosed', {})
    end
end

local function text(str, color, size)
    return { type = ui.TYPE.Text, props = { text = str, textSize = size or 17, textColor = color or normalColor, autoSize = true,
        font = 'FalloutFont2' } }
end

local function gap(height)
    return { props = { size = v2(WIDTH, height) } }
end

local function clickable(str, onClick, color)
    local line = text(str, color)
    line.events = {
        mouseClick = async:callback(onClick),
        focusGain = async:callback(function()
            line.props.textColor = hoverColor
            if window then window:update() end
        end),
        focusLoss = async:callback(function()
            line.props.textColor = color or normalColor
            if window then window:update() end
        end),
    }
    return line
end

local function needs(recipe)
    local parts = {}
    for _, input in ipairs(recipe.inputs) do
        parts[#parts + 1] = ('%s %d/%d'):format(input.name, input.have, input.count)
    end
    if recipe.skill then
        parts[#parts + 1] = ('%s %d/%d'):format(recipe.skill, recipe.skillValue, recipe.skillLevel)
    end
    return table.concat(parts, ', ')
end

local function render()
    destroyWindow()
    if data == nil then return end
    local content = ui.content {}
    content:add(text('Crafting', hoverColor, 22))
    content:add(gap(8))
    local pageCount = math.max(1, math.ceil(#data.recipes / ROWS))
    page = math.min(page, pageCount)
    local first = (page - 1) * ROWS + 1
    for i = first, math.min(#data.recipes, first + ROWS - 1) do
        local recipe = data.recipes[i]
        if recipe.craftable then
            content:add(clickable(recipe.name, function()
                core.sendGlobalEvent('FNVRecipeCraft', { recipe = recipe.id, count = 1 })
            end))
        else
            content:add(text(recipe.name, dimColor))
        end
        content:add(text('   ' .. needs(recipe), dimColor, 15))
    end
    if #data.recipes == 0 then content:add(text('(no recipes)', dimColor)) end
    if pageCount > 1 then
        content:add(gap(4))
        content:add(clickable(('Page %d of %d (next)'):format(page, pageCount), function()
            page = page % pageCount + 1
            render()
        end, dimColor))
    end
    content:add(gap(8))
    if message then content:add(text(message)) end
    content:add(clickable('Leave', close))
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
                        content = ui.content { { type = ui.TYPE.Flex, props = { autoSize = true }, content = content } },
                    },
                },
            },
        },
    }
end

return {
    interfaceName = 'FNVCrafting',
    ---
    -- @module FNVCrafting
    -- @context player
    interface = {
        version = 0,
        isOpen = function() return open end,
        getData = function() return data end,
        --- For tests: make the first craftable recipe whose name contains `name`.
        craft = function(name)
            if data == nil then return false end
            for _, recipe in ipairs(data.recipes) do
                if recipe.craftable and recipe.name:find(name, 1, true) then
                    core.sendGlobalEvent('FNVRecipeCraft', { recipe = recipe.id, count = 1 })
                    return true
                end
            end
            return false
        end,
        close = close,
    },
    engineHandlers = {
        onFrame = function()
            if refreshAt and core.getRealTime() >= refreshAt then
                refreshAt = nil
                core.sendGlobalEvent('FNVRecipeRefresh', {})
            end
        end,
    },
    eventHandlers = {
        FNVRecipeShow = function(d)
            data = d
            if not open then
                open = true
                page = 1
                message = nil
                sharedMode = I.UI.getMode() == 'Interface'
                if not sharedMode then I.UI.setMode('Interface', { windows = {} }) end
            end
            render()
        end,
        FNVRecipeMade = function(e)
            message = e.name .. ' made.'
            refreshAt = core.getRealTime() + 0.2
        end,
        UiModeChanged = function(e)
            if open and not closingByScript and e.newMode ~= 'Interface' then
                open = false
                destroyWindow()
                data = nil
                core.sendGlobalEvent('FNVRecipeClosed', {})
            end
        end,
    },
}
