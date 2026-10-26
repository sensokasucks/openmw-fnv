-- The world side of the FNV menus (scripts/omw/fnvmenus/player.lua): waiting, and moving items in and out
-- of containers and bodies.
--
-- Events:
--   FNVWaitHour        { player }                         one hour passes (the wait menu sends one per step)
--   FNVContainerOpen   { player, container }              send the container menu its lists
--   FNVContainerMove   { player, container, item, count } move items between the player and the container
--   FNVContainerTakeAll { player, container }
-- Moves land a frame later, so the menu asks for its lists again after them.

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')

local obscript = core.obscript
if obscript == nil or obscript.itemInfo == nil
    or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local CAPS = obscript.resolveItemEditorId and obscript.resolveItemEditorId('Caps001')

local function inventoryOf(obj)
    if types.Actor.objectIsInstance(obj) then return types.Actor.inventory(obj) end
    return types.Container.inventory(obj)
end

local function nameOf(obj)
    local ok, record = pcall(function() return obj.type.record(obj) end)
    if ok and record and record.name and record.name ~= '' then return record.name end
    local ok2, name = pcall(obscript.combat.getName, obj)
    return ok2 and name or ''
end

-- { item, name, count, value, weight, icon, category }, by name
local function listItems(inventory)
    local list = {}
    for _, item in ipairs(inventory:getAll()) do
        local ok, info = pcall(obscript.itemInfo, item)
        if ok and info.name ~= '' then
            list[#list + 1] = { item = item, name = info.name, count = item.count, value = info.value,
                weight = info.weight, icon = info.icon, category = info.category,
                caps = CAPS ~= nil and item.recordId:lower() == CAPS:lower() }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function show(player, container)
    player:sendEvent('FNVContainerShow', {
        container = container,
        name = nameOf(container),
        playerItems = listItems(types.Actor.inventory(player)),
        containerItems = listItems(inventoryOf(container)),
    })
end

local function move(item, count, inventory)
    if count >= item.count then
        item:moveInto(inventory)
    else
        item:split(count):moveInto(inventory)
    end
end

return {
    eventHandlers = {
        FNVWaitHour = function()
            world.advanceTime(1)
        end,
        FNVContainerOpen = function(e)
            -- containers resolve their levelled lists when first opened
            pcall(function() inventoryOf(e.container):resolve() end)
            show(e.player, e.container)
        end,
        FNVContainerMove = function(e)
            local item = e.item
            if item == nil or not item:isValid() or item.count == 0 then return end
            local toContainer = item.parentContainer == e.player
            local target = toContainer and inventoryOf(e.container) or types.Actor.inventory(e.player)
            move(item, math.max(1, math.min(e.count or 1, item.count)), target)
        end,
        FNVContainerTakeAll = function(e)
            local playerInventory = types.Actor.inventory(e.player)
            for _, item in ipairs(inventoryOf(e.container):getAll()) do
                local ok, info = pcall(obscript.itemInfo, item)
                if ok and info.name ~= '' then move(item, item.count, playerInventory) end
            end
        end,
    },
}
