-- FNV crafting: `player.ShowRecipeMenu <category>` (campfires, workbenches,
-- reloading benches) opens the crafting window (scripts/omw/fnvcrafting/player.lua)
-- with the recipes (RCPE) of that category (RCCT).
--
-- A recipe shows when its conditions pass on the player; it can be made when the
-- player's skill reaches its level and the inventory holds every input. Making it
-- takes the inputs and gives the outputs.
--
-- Events:
--   FNVRecipeOpen  { category }      from ShowRecipeMenu
--   FNVRecipeCraft { recipe, count } from the window
--   FNVRecipeClosed {}               from the window

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local obscript = core.obscript
if obscript == nil or obscript.dialogue == nil or obscript.dialogue.getRecipes == nil then
    return {}
end
local stats = obscript.stats

local session = nil -- { category, recipes, player }

local function countOf(inventory, recordId)
    local ok, n = pcall(inventory.countOf, inventory, recordId)
    return ok and n or 0
end

local function skillValue(player, skill)
    if skill == nil or skill < 0 then return 0 end
    local ok, value = pcall(stats.get, player, skill)
    return ok and value or 0
end

local function conditionsPass(recipe, player)
    if #recipe.conditions == 0 or I.FNVDialogue == nil or I.FNVDialogue.checkConditions == nil then return true end
    local ok, passed = pcall(I.FNVDialogue.checkConditions, recipe.conditions, player)
    return ok and passed == true
end

local function show()
    local s = session
    local inventory = types.Actor.inventory(s.player)
    local list = {}
    for _, recipe in ipairs(s.recipes) do
        if conditionsPass(recipe, s.player) then
            local entry = { id = recipe.id, name = recipe.name, inputs = {}, outputs = recipe.outputs, craftable = true }
            for _, input in ipairs(recipe.inputs) do
                local have = countOf(inventory, input.item)
                entry.inputs[#entry.inputs + 1] = { name = input.name, count = input.count, have = have }
                if have < input.count then entry.craftable = false end
            end
            if recipe.skill >= 0 then
                local ok, name = pcall(stats.actorValueName, recipe.skill)
                entry.skill = ok and name or tostring(recipe.skill)
                entry.skillLevel = recipe.skillLevel
                entry.skillValue = skillValue(s.player, recipe.skill)
                if entry.skillValue < recipe.skillLevel then entry.craftable = false end
            end
            list[#list + 1] = entry
        end
    end
    s.player:sendEvent('FNVRecipeShow', { category = s.category, recipes = list })
end

local function open(data)
    local player = world.players[1]
    if player == nil or data.category == nil then return end
    local recipes = obscript.dialogue.getRecipes(data.category)
    if #recipes == 0 then
        print('[fnvcrafting] no recipes in ' .. tostring(data.category))
        return
    end
    session = { category = data.category, recipes = recipes, player = player }
    show()
end

local function removeItems(inventory, recordId, count)
    local remaining = count
    for _, item in ipairs(inventory:getAll()) do
        if remaining <= 0 then return end
        if item.recordId:lower() == recordId:lower() then
            local n = math.min(item.count, remaining)
            item:remove(n)
            remaining = remaining - n
        end
    end
end

local function craft(data)
    local s = session
    if s == nil then return end
    local recipe
    for _, r in ipairs(s.recipes) do
        if r.id == data.recipe then recipe = r end
    end
    if recipe == nil or not conditionsPass(recipe, s.player) then return end
    if recipe.skill >= 0 and skillValue(s.player, recipe.skill) < recipe.skillLevel then return end
    local inventory = types.Actor.inventory(s.player)
    for _, input in ipairs(recipe.inputs) do
        if countOf(inventory, input.item) < input.count then return end
    end
    for _, input in ipairs(recipe.inputs) do removeItems(inventory, input.item, input.count) end
    for _, output in ipairs(recipe.outputs) do
        world.createObject(output.item, output.count):moveInto(inventory)
    end
    print('[fnvcrafting] made ' .. recipe.name)
    s.player:sendEvent('FNVRecipeMade', { name = recipe.name })
end

return {
    eventHandlers = {
        FNVRecipeOpen = open,
        FNVRecipeCraft = craft,
        FNVRecipeRefresh = function() if session then show() end end,
        FNVRecipeClosed = function() session = nil end,
    },
}
