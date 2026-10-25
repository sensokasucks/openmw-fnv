-- The global half of the Pip-Boy (the screen is scripts/omw/fnvpipboy/player.lua).
--
-- Builds what the Pip-Boy shows that only global scripts can read (the quest
-- log, active effects) and carries out what the player does in the ITEMS tab:
--
--   * Apparel (ARMO) is worn here. Wearing an item takes off whatever shares
--     one of its biped slots (BMDT flags), and adds its damage threshold and
--     damage resistance (DNAM) to the player's DamageThreshold and
--     DamageResist, which FNV damage reads (MWMechanics::ESM4Combat::applyArmor).
--     Worn apparel is mirrored into storage.globalSection('FNVPlayerApparel')
--     for GetEquipped. Apparel that leaves the inventory comes off.
--   * Aid items are used through the ItemUsage interface (FNV potions are
--     applied by scripts/omw/fnveffects/global.lua).
--   * Dropped items land at the player's feet.
--
-- Weapons stay with scripts/omw/fnvcombat/player.lua, which the screen calls
-- directly.
--
-- From the Lua console (`luag`):
--   I.FNVPipBoy.wear(world.players[1], 'ArmorLeather')   -- record id or editor id
--   I.FNVPipBoy.getWorn(world.players[1])

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local obscript = core.obscript
if obscript == nil or obscript.itemInfo == nil or obscript.dialogue == nil then
    return {}
end
local stats = obscript.stats
local dlg = obscript.dialogue

local apparelSection = storage.globalSection('FNVPlayerApparel')
local quests = storage.globalSection('ObScriptQuests')

-- Worn apparel of the player: record id (lower case) -> { recordId, editorId, slots, dr, dt }
local worn = {}
local checkTimer = 0

local function log(msg)
    print('[fnvpipboy] ' .. msg)
end

local function publishApparel()
    local list = {}
    for _, w in pairs(worn) do
        list[#list + 1] = { recordId = w.recordId, editorId = w.editorId }
    end
    apparelSection:set('worn', list)
end

local function itemInfo(item)
    local ok, info = pcall(obscript.itemInfo, item)
    return ok and info or nil
end

local function findItem(player, id)
    if type(id) ~= 'string' then return id end
    local inventory = types.Actor.inventory(player)
    local item = inventory:find(id)
    if item == nil and obscript.resolveItemEditorId then
        local resolved = obscript.resolveItemEditorId(id)
        if resolved then item = inventory:find(resolved) end
    end
    return item
end

local function applyArmor(player, entry, sign)
    if entry.dt ~= 0 then pcall(stats._modify, player, 'DamageThreshold', sign * entry.dt) end
    if entry.dr ~= 0 then pcall(stats._modify, player, 'DamageResist', sign * entry.dr) end
end

local function takeOff(player, key)
    local entry = worn[key]
    if entry == nil then return end
    worn[key] = nil
    applyArmor(player, entry, -1)
end

local function wear(player, item)
    item = findItem(player, item)
    if item == nil or not item:isValid() then return false end
    local info = itemInfo(item)
    if info == nil or info.category ~= 'apparel' or not info.playable then return false end
    local key = info.recordId:lower()
    if worn[key] then return true end
    for k, other in pairs(worn) do
        if util.bitAnd(other.slots, info.slots) ~= 0 then takeOff(player, k) end
    end
    local entry = { recordId = info.recordId, editorId = info.editorId or '', slots = info.slots,
        dr = info.dr or 0, dt = info.dt or 0 }
    worn[key] = entry
    applyArmor(player, entry, 1)
    publishApparel()
    return true
end

local function remove(player, item)
    local key = type(item) == 'string' and item:lower() or (item and item.recordId:lower())
    if key == nil or worn[key] == nil then return false end
    takeOff(player, key)
    publishApparel()
    return true
end

-- Apparel that left the inventory (sold, dropped, RemoveItem) comes off.
local function checkWorn(player)
    local inventory = types.Actor.inventory(player)
    local changed = false
    for key, entry in pairs(worn) do
        local ok, n = pcall(inventory.countOf, inventory, entry.recordId)
        if ok and n <= 0 then
            takeOff(player, key)
            changed = true
        end
    end
    if changed then publishApparel() end
end

-- ------------------------------------------------------------ the quest log

local function questName(rec)
    if rec.name ~= nil and rec.name ~= '' then return rec.name end
    return rec.editorId
end

-- Quests the player has seen an objective of: { key, name, completed, failed, objectives = { { text, completed } } },
-- current ones first, each group in the order of the quest's editor id.
local function questLog()
    local list = {}
    for key, data in pairs(quests:asTable()) do
        local ok, rec = pcall(dlg.getQuest, key)
        if ok and rec and data.objectives then
            local objectives = {}
            for _, o in ipairs(rec.objectives or {}) do
                local state = data.objectives[o.index]
                if state == 'displayed' or state == 'completed' then
                    objectives[#objectives + 1] = { index = o.index, text = o.text, completed = state == 'completed' }
                end
            end
            if #objectives > 0 then
                table.sort(objectives, function(a, b) return a.index < b.index end)
                list[#list + 1] = { key = key, name = questName(rec), completed = data.completed and true or false,
                    failed = data.failed and true or false, objectives = objectives }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.completed ~= b.completed then return not a.completed end
        return a.name < b.name
    end)
    return list
end

local function effectList(player)
    local res = {}
    if I.FNVEffects == nil then return res end
    local ok, list = pcall(I.FNVEffects.list, player)
    if not ok then return res end
    for _, e in ipairs(list) do
        if e.active and e.name ~= '' then
            res[#res + 1] = { name = e.name, magnitude = e.magnitude, remaining = e.remaining, source = e.source }
        end
    end
    return res
end

local function sendData(player)
    local activeQuest = I.FNVHud and I.FNVHud.getActiveQuest and I.FNVHud.getActiveQuest() or nil
    local wornList = {}
    for key in pairs(worn) do wornList[#wornList + 1] = key end
    player:sendEvent('FNVPipBoyData', {
        quests = questLog(),
        activeQuest = activeQuest,
        effects = effectList(player),
        worn = wornList,
    })
end

local function drop(player, item, count)
    if item == nil or not item:isValid() or item.count <= 0 then return end
    remove(player, item)
    count = math.max(1, math.min(item.count, count or 1))
    local forward = player.rotation:apply(util.vector3(0, 1, 0))
    local position = player.position + forward * 60 + util.vector3(0, 0, 40)
    item:split(count):teleport(player.cell, position, { onGround = true })
end

return {
    interfaceName = 'FNVPipBoy',
    ---
    -- @module FNVPipBoy
    -- @context global
    interface = {
        version = 0,
        --- Put on an apparel item from the actor's inventory (item, record id or editor id); false if it can't be worn.
        wear = wear,
        --- Take off an apparel item (item or record id).
        remove = remove,
        --- Record ids (lower case) of the worn apparel.
        getWorn = function()
            local res = {}
            for key in pairs(worn) do res[#res + 1] = key end
            table.sort(res)
            return res
        end,
        isWorn = function(recordId) return recordId ~= nil and worn[recordId:lower()] ~= nil end,
    },
    eventHandlers = {
        FNVPipBoyRefresh = function(e)
            if e.player then sendData(e.player) end
        end,
        -- { player, item, action = 'wear'|'remove'|'use'|'drop', count }
        FNVPipBoyItem = function(e)
            local player, item = e.player, e.item
            if player == nil or item == nil or not item:isValid() then return end
            if e.action == 'wear' then
                if not wear(player, item) then
                    player:sendEvent('FNVPipBoyMessage', { text = 'You cannot wear that.' })
                end
            elseif e.action == 'remove' then
                remove(player, item)
            elseif e.action == 'use' then
                core.sendGlobalEvent('UseItem', { object = item, actor = player })
            elseif e.action == 'drop' then
                drop(player, item, e.count)
            end
            sendData(player)
        end,
        -- `player.EquipItem <apparel>` from a script, by record id or editor id
        FNVPipBoyWear = function(e)
            if e.player then wear(e.player, e.item) end
        end,
        FNVPipBoySetActiveQuest = function(e)
            if I.FNVHud and I.FNVHud.setActiveQuest then I.FNVHud.setActiveQuest(e.quest) end
            if e.player then sendData(e.player) end
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            checkTimer = checkTimer - dt
            if checkTimer > 0 then return end
            checkTimer = 1
            local player = world.players[1]
            if player then checkWorn(player) end
        end,
        onSave = function()
            return { worn = worn }
        end,
        -- the DT and DR worn apparel added are saved with the actor values
        onLoad = function(data)
            worn = data and data.worn or {}
            publishApparel()
        end,
    },
}
