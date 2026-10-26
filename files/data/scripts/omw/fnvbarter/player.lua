-- FO3/FNV barter window (see scripts/omw/fnvbarter/global.lua).
--
-- The vendor's goods are on the left with what they cost, the player's on the
-- right with what they fetch. Clicking an item puts one into the offer (shift:
-- the whole stack); clicking an offer line takes one back. Accept trades the
-- offer for the caps difference; Leave or Escape closes the window.

local async = require('openmw.async')
local core = require('openmw.core')
local input = require('openmw.input')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local frame = require('scripts.omw.fnvhud.frame')

local v2 = util.vector2

local COLUMN = 360
local ROWS = 16
local normalColor = util.color.rgb(0.79, 0.65, 0.38)
local hoverColor = util.color.rgb(1.0, 0.88, 0.6)
local dimColor = util.color.rgb(0.55, 0.55, 0.55)
local warnColor = util.color.rgb(0.9, 0.35, 0.3)

local window = nil
local open = false
local closingByScript = false
local sharedMode = false -- opened over another window (the dialogue); leaving goes back to it
local data = nil -- the last FNVBarterShow
local offer = { buy = {}, sell = {} } -- item id -> count
local pages = { merchantItems = 1, playerItems = 1 }
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
        core.sendGlobalEvent('FNVBarterClosed', {})
    end
end

local function text(str, color, size)
    return { type = ui.TYPE.Text, props = { text = str, textSize = size or 17, textColor = color or normalColor, autoSize = true,
        font = 'FalloutFont2' } }
end

local function gap(height, width)
    return { props = { size = v2(width or COLUMN, height) } }
end

local render

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

local function offered(side, entry)
    return offer[side][entry.item.id] or 0
end

local function totals()
    local cost, earned = 0, 0
    for _, entry in ipairs(data.merchantItems) do cost = cost + offered('buy', entry) * entry.price end
    for _, entry in ipairs(data.playerItems) do earned = earned + offered('sell', entry) * entry.price end
    return cost, earned
end

local function column(title, listName, side)
    local list = data[listName]
    local content = ui.content {}
    content:add(text(title, hoverColor, 20))
    content:add(gap(6))
    local pageCount = math.max(1, math.ceil(#list / ROWS))
    pages[listName] = math.min(pages[listName], pageCount)
    local first = (pages[listName] - 1) * ROWS + 1
    for i = first, math.min(#list, first + ROWS - 1) do
        local entry = list[i]
        local left = entry.count - offered(side, entry)
        local label = ('%s%s  (%d)'):format(entry.name, entry.count > 1 and (' x' .. left) or '', entry.price)
        if left > 0 then
            content:add(clickable(label, function()
                local n = input.isShiftPressed() and left or 1
                offer[side][entry.item.id] = offered(side, entry) + n
                message = nil
                render()
            end))
        else
            content:add(text(label, dimColor))
        end
    end
    if #list == 0 then content:add(text('(nothing)', dimColor)) end
    if pageCount > 1 then
        content:add(gap(4))
        content:add(clickable(('Page %d of %d (next)'):format(pages[listName], pageCount), function()
            pages[listName] = pages[listName] % pageCount + 1
            render()
        end, dimColor))
    end
    return { type = ui.TYPE.Flex, props = { size = v2(COLUMN, 0), autoSize = true }, content = content }
end

local function offerLines(content, side, listName, verb)
    for _, entry in ipairs(data[listName]) do
        local n = offered(side, entry)
        if n > 0 then
            content:add(clickable(('%s %s%s  %d caps'):format(verb, entry.name, n > 1 and (' x' .. n) or '', n * entry.price),
                function()
                    offer[side][entry.item.id] = n - 1
                    message = nil
                    render()
                end))
        end
    end
end

local function lines(side, listName)
    local result = {}
    for _, entry in ipairs(data[listName]) do
        local n = offered(side, entry)
        if n > 0 then result[#result + 1] = { item = entry.item, count = n } end
    end
    return result
end

render = function()
    destroyWindow()
    if data == nil then return end
    local cost, earned = totals()
    local net = cost - earned
    local content = ui.content {}
    content:add(text(data.merchant ~= '' and data.merchant or 'Barter', hoverColor, 22))
    content:add(gap(8, 2 * COLUMN + 24))
    content:add({
        type = ui.TYPE.Flex,
        props = { horizontal = true, autoSize = true },
        content = ui.content {
            column('For sale', 'merchantItems', 'buy'),
            gap(0, 24),
            column('Yours', 'playerItems', 'sell'),
        },
    })
    content:add(gap(10))
    offerLines(content, 'buy', 'merchantItems', 'Buy')
    offerLines(content, 'sell', 'playerItems', 'Sell')
    content:add(gap(6))
    local summary
    if net > 0 then
        summary = ('You pay %d caps. You have %d.'):format(net, data.playerCaps)
    elseif net < 0 then
        summary = ('You receive %d caps. The merchant has %d.'):format(-net, data.merchantCaps)
    else
        summary = ('Your caps: %d. Merchant caps: %d.'):format(data.playerCaps, data.merchantCaps)
    end
    local affordable = net <= data.playerCaps and -net <= data.merchantCaps
    content:add(text(summary, affordable and normalColor or warnColor))
    if message then content:add(text(message, warnColor)) end
    content:add(gap(8))
    if cost > 0 or earned > 0 then
        content:add(clickable('Accept', function()
            if not affordable then
                message = net > 0 and 'You do not have enough caps.' or 'The merchant does not have enough caps.'
                render()
                return
            end
            core.sendGlobalEvent('FNVBarterTrade', { buy = lines('buy', 'merchantItems'), sell = lines('sell', 'playerItems') })
        end))
        content:add(gap(4))
    end
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
    interfaceName = 'FNVBarter',
    ---
    -- @module FNVBarter
    -- @context player
    interface = {
        version = 0,
        isOpen = function() return open end,
        close = function() close() end,
        --- The last lists the window got: { merchant, merchantCaps, playerCaps, merchantItems, playerItems }.
        getData = function() return data end,
        --- For tests: put `count` of the n-th listed item into the offer and accept.
        offerAndAccept = function(buyIndex, buyCount, sellIndex, sellCount)
            if data == nil then return false end
            offer = { buy = {}, sell = {} }
            local buy, sell = data.merchantItems[buyIndex or 0], data.playerItems[sellIndex or 0]
            if buy then offer.buy[buy.item.id] = buyCount or 1 end
            if sell then offer.sell[sell.item.id] = sellCount or 1 end
            core.sendGlobalEvent('FNVBarterTrade', { buy = lines('buy', 'merchantItems'), sell = lines('sell', 'playerItems') })
            return true
        end,
    },
    engineHandlers = {
        onFrame = function()
            if refreshAt and core.getRealTime() >= refreshAt then
                refreshAt = nil
                core.sendGlobalEvent('FNVBarterRefresh', {})
            end
        end,
    },
    eventHandlers = {
        FNVBarterShow = function(d)
            data = d
            offer = { buy = {}, sell = {} }
            if not open then
                open = true
                pages = { merchantItems = 1, playerItems = 1 }
                sharedMode = I.UI.getMode() == 'Interface'
                if not sharedMode then I.UI.setMode('Interface', { windows = {} }) end
            end
            render()
        end,
        FNVBarterTraded = function()
            message = nil
            refreshAt = core.getRealTime() + 0.2
        end,
        FNVBarterRefused = function(e)
            message = e.reason
            render()
        end,
        UiModeChanged = function(e)
            -- Escape or another window closed the barter window
            if open and not closingByScript and e.newMode ~= 'Interface' then
                open = false
                destroyWindow()
                data = nil
                core.sendGlobalEvent('FNVBarterClosed', {})
            end
        end,
    },
}
