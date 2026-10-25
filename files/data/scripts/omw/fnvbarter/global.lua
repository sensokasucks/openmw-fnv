-- FO3/FNV barter: `ShowBarterMenu` in a vendor's dialogue opens the trade window
-- (scripts/omw/fnvbarter/player.lua) over the vendor's merchant container (ACHR
-- XMRC) and the player's inventory.
--
-- Prices follow FalloutNV.exe (FUN_00649050, called when the barter menu opens
-- with the player's Barter skill, actor value 32):
--   buy  multiplier = fBarterBuyBase  + Barter * fBarterBuyMult  / 100   (1.55 .. 1.10)
--   sell multiplier = fBarterSellBase + Barter * fBarterSellMult / 100   (0.45 .. 0.90)
-- Prices are rounded to whole caps (inferred); the vendor's own Barter skill is
-- not used. Item condition does not change the value yet.
--
-- Events:
--   FNVBarterOpen  { merchant }                      from the dialogue (ShowBarterMenu)
--   FNVBarterTrade { buy = { {item, count} }, sell = { {item, count} } }   from the window
--   FNVBarterRefresh {}                              from the window, after a trade
--   FNVBarterClosed {}                               from the window

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')

local obscript = core.obscript
if obscript == nil or obscript.itemInfo == nil then
    return {}
end
local stats = obscript.stats

local CAPS = obscript.resolveItemEditorId('Caps001')

local session = nil -- { merchant, container, player }

local function gameSetting(name, default)
    local ok, value = pcall(stats.gameSetting, name)
    return (ok and type(value) == 'number') and value or default
end

local function multipliers(player)
    local ok, skill = pcall(stats.get, player, 'Barter')
    skill = ok and skill or 0
    local buy = gameSetting('fBarterBuyBase', 1.55) + skill * gameSetting('fBarterBuyMult', -0.45) / 100
    local sell = gameSetting('fBarterSellBase', 0.45) + skill * gameSetting('fBarterSellMult', 0.45) / 100
    return buy, sell
end

local function price(value, multiplier)
    if value <= 0 then return 0 end
    return math.max(1, math.floor(value * multiplier + 0.5))
end

local function isCaps(item)
    return CAPS ~= nil and item.recordId:lower() == CAPS:lower()
end

local function countCaps(inventory)
    if CAPS == nil then return 0 end
    local ok, n = pcall(inventory.countOf, inventory, CAPS)
    return ok and n or 0
end

-- Items that can change hands, with their prices: { item, name, count, value, price }
local function listItems(inventory, multiplier)
    local list = {}
    for _, item in ipairs(inventory:getAll()) do
        if not isCaps(item) then
            local ok, info = pcall(obscript.itemInfo, item)
            if ok and info.name ~= '' then
                list[#list + 1] = { item = item, name = info.name, count = item.count, value = info.value,
                    price = price(info.value, multiplier) }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function merchantName(merchant)
    local ok, name = pcall(obscript.combat.getName, merchant)
    return ok and name or ''
end

local function show()
    local s = session
    local buy, sell = multipliers(s.player)
    local merchantInventory = types.Container.inventory(s.container)
    local playerInventory = types.Actor.inventory(s.player)
    s.player:sendEvent('FNVBarterShow', {
        merchant = merchantName(s.merchant),
        merchantCaps = countCaps(merchantInventory),
        playerCaps = countCaps(playerInventory),
        merchantItems = listItems(merchantInventory, buy),
        playerItems = listItems(playerInventory, sell),
    })
end

local function open(data)
    local merchant = data.merchant
    local player = world.players[1]
    if merchant == nil or player == nil then return end
    local containerId = obscript.getMerchantContainer(merchant)
    local ok, container = pcall(world.getObjectByFormId, containerId or '')
    if not ok or container == nil then
        print('[fnvbarter] ' .. tostring(merchant) .. ' has no merchant container')
        return
    end
    -- containers resolve their levelled lists when first opened
    pcall(function() types.Container.inventory(container):resolve() end)
    session = { merchant = merchant, container = container, player = player }
    show()
end

local function move(item, count, inventory)
    if count >= item.count then
        item:moveInto(inventory)
    else
        item:split(count):moveInto(inventory)
    end
end

local function moveCaps(from, to, amount)
    local remaining = amount
    for _, item in ipairs(from:getAll()) do
        if remaining <= 0 then return end
        if isCaps(item) then
            local n = math.min(item.count, remaining)
            move(item, n, to)
            remaining = remaining - n
        end
    end
end

-- Checks the offer against what both sides still have, then swaps items and caps.
local function trade(data)
    local s = session
    if s == nil then return end
    local buyMult, sellMult = multipliers(s.player)
    local merchantInventory = types.Container.inventory(s.container)
    local playerInventory = types.Actor.inventory(s.player)
    local function total(lines, inventory, multiplier)
        local sum = 0
        for _, line in ipairs(lines or {}) do
            local item = line.item
            if item == nil or not item:isValid() or item.count < line.count or item.parentContainer == nil
                or (inventory == merchantInventory and item.parentContainer ~= s.container)
                or (inventory == playerInventory and item.parentContainer ~= s.player) then
                return nil
            end
            sum = sum + price(obscript.itemInfo(item).value, multiplier) * line.count
        end
        return sum
    end
    local cost = total(data.buy, merchantInventory, buyMult)
    local earned = total(data.sell, playerInventory, sellMult)
    if cost == nil or earned == nil then
        print('[fnvbarter] the offer no longer matches the inventories')
        show()
        return
    end
    local net = cost - earned -- caps the player pays
    if net > countCaps(playerInventory) then
        s.player:sendEvent('FNVBarterRefused', { reason = 'You do not have enough caps.' })
        return
    end
    if -net > countCaps(merchantInventory) then
        s.player:sendEvent('FNVBarterRefused', { reason = 'The merchant does not have enough caps.' })
        return
    end
    for _, line in ipairs(data.buy or {}) do move(line.item, line.count, playerInventory) end
    for _, line in ipairs(data.sell or {}) do move(line.item, line.count, merchantInventory) end
    if net > 0 then
        moveCaps(playerInventory, merchantInventory, net)
    elseif net < 0 then
        moveCaps(merchantInventory, playerInventory, -net)
    end
    print(('[fnvbarter] traded with %s: paid %d, got %d'):format(merchantName(s.merchant), cost, earned))
    -- the moves land with the next frame; the window asks for the new lists (FNVBarterRefresh)
    s.player:sendEvent('FNVBarterTraded', { paid = cost, earned = earned })
end

return {
    eventHandlers = {
        FNVBarterOpen = open,
        FNVBarterTrade = trade,
        FNVBarterRefresh = function() if session then show() end end,
        FNVBarterClosed = function() session = nil end,
    },
}
