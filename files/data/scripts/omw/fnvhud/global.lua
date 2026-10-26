-- The global half of the FNV HUD (the player half is scripts/omw/fnvhud/player.lua).
--
-- Watches the quest state that scripts/omw/fnvdialogue/global.lua mirrors into
-- the 'ObScriptQuests' storage section and
--   * sends the player the corner notices for quests: "Quest added",
--     a new objective, a completed objective, "Quest completed";
--   * keeps the active quest (the original lets the player pick it in the
--     Pip-Boy; here it is the quest whose objectives changed last, or the one
--     chosen with I.FNVHud.setActiveQuest), and
--   * sends the player the compass markers of the active quest's open
--     objectives: each objective target (QSTA) whose conditions pass. A
--     target in another cell is shown at the door that leads towards it, as
--     in the original (inferred: one door deep, no path search).
--
-- From the Lua console (`luag`):
--   I.FNVHud.setActiveQuest('VMS01')
--   I.FNVHud.getMarkers()

local async = require('openmw.async')
local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local dlg = core.obscript and core.obscript.dialogue
if dlg == nil then
    return {}
end

local quests = storage.globalSection('ObScriptQuests')

local MARKER_INTERVAL = 0.5

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    if value == nil then return default end
    return value
end

-- What the player has already been told, per quest (lower-case editor id):
-- { added = true, completed = true, objectives = { [index] = 'displayed'|'completed' } }.
-- Saved with the game, so republishing every quest on load says nothing new.
local told = {}
local activeQuest = nil -- lower-case editor id
-- Quests changed since the last update. Storage callbacks run as soon as a
-- value is set, which on load is before this script's onLoad; so they only
-- note the quest, and onUpdate compares.
local changedQuests = {}
local allChanged = false
-- A game saved before this script existed: learn its quests without notices.
local quietUpdate = false
local markers = {}
local markerTimer = 0

local questRecords = {}
local function questRecord(key)
    local rec = questRecords[key]
    if rec == nil then
        rec = dlg.getQuest(key) or false
        questRecords[key] = rec
    end
    return rec or nil
end

local function questName(rec)
    if rec.name ~= nil and rec.name ~= '' then return rec.name end
    return rec.editorId
end

local function objectiveRecord(rec, index)
    for _, o in ipairs(rec.objectives) do
        if o.index == index then return o end
    end
    return nil
end

local function notify(text, kind)
    local player = world.players[1]
    if player and text ~= nil and text ~= '' and not quietUpdate then
        player:sendEvent('FNVHudNotify', { text = text, kind = kind })
    end
end

-- Compares a quest's published state with what the player was told.
local function questChanged(key)
    local data = quests:get(key)
    local rec = questRecord(key)
    if data == nil or rec == nil then return end
    local t = told[key]
    if t == nil then
        t = { objectives = {} }
        told[key] = t
    end
    local changed = false
    -- objectives in index order, so "added" comes before the first objective
    local indices = {}
    for index in pairs(data.objectives) do indices[#indices + 1] = index end
    table.sort(indices)
    for _, index in ipairs(indices) do
        local state = data.objectives[index]
        local before = t.objectives[index]
        if state ~= before then
            local o = objectiveRecord(rec, index)
            local text = o and o.text or ''
            if not t.added then
                t.added = true
                notify(gmst('sQuestAddedText', 'Quest added') .. ': ' .. questName(rec), 'questAdded')
            end
            if state == 'displayed' and before == nil then
                notify(text, 'objective')
            elseif state == 'completed' then
                notify(gmst('sHUDQuestCompleted', 'COMPLETED: ') .. text, 'objectiveCompleted')
            end
            t.objectives[index] = state
            changed = true
        end
    end
    if data.completed and not t.completed then
        t.completed = true
        if t.added then
            notify(gmst('sQuestCompletedText', 'Quest completed') .. ': ' .. questName(rec), 'questCompleted')
        end
        if activeQuest == key then activeQuest = nil end
    elseif changed and data.running and not data.completed then
        activeQuest = key
    end
    if changed then markerTimer = 0 end
end

quests:subscribe(async:callback(function(_, key)
    if key == nil then
        allChanged = true
    else
        changedQuests[key] = true
    end
end))

local function processChangedQuests()
    if allChanged then
        for k in pairs(quests:asTable()) do changedQuests[k] = true end
        allChanged = false
    end
    -- sorted, so that notices come in the same order every time
    local keys = {}
    for k in pairs(changedQuests) do keys[#keys + 1] = k end
    table.sort(keys)
    changedQuests = {}
    for _, k in ipairs(keys) do questChanged(k) end
    quietUpdate = false
end

-- ------------------------------------------------------------ compass markers

-- Where a target is: { position, isExterior, worldSpaceId, cellId, cell, object }.
-- A loaded reference gives its live position; one whose cell isn't loaded,
-- the position its record places it at.
local function findPlace(formId)
    if formId == nil or formId == '' then return nil end
    local ok, obj = pcall(world.getObjectByFormId, formId)
    if ok and obj and obj:isValid() and obj.cell ~= nil then
        if not obj.enabled then return nil end
        local cell = obj.cell
        return { position = obj.position, isExterior = cell.isExterior, worldSpaceId = cell.worldSpaceId,
            cellId = cell.id, cell = cell, object = obj }
    end
    local loc = core.obscript.getReferenceLocation(formId)
    if loc == nil then return nil end
    return { position = loc.position, isExterior = loc.isExterior, worldSpaceId = loc.worldSpaceId,
        cellId = loc.cell }
end

local function cellOf(place)
    if place.cell == nil and not place.isExterior then
        local ok, cell = pcall(world.getCellById, place.cellId)
        if ok then place.cell = cell end
    end
    return place.cell
end

local function inSpace(cell, place)
    if cell.isExterior and place.isExterior then return cell.worldSpaceId == place.worldSpaceId end
    return not cell.isExterior and not place.isExterior and cell.id == place.cellId
end

local function cellPlace(cell)
    return { isExterior = cell.isExterior, worldSpaceId = cell.worldSpaceId, cellId = cell.id, cell = cell }
end

-- The door in `cell` that leads towards `place`: one that goes there, else
-- (from an interior) one that goes outside, else any teleport door.
local function doorTowards(cell, place)
    local ok, doors = pcall(function() return cell:getAll(types.ESM4Door) end)
    if not ok then return nil end
    local outside, any
    for _, door in ipairs(doors) do
        if door.enabled and types.ESM4Door.isTeleport(door) then
            local dest = types.ESM4Door.destCell(door)
            if dest then
                if inSpace(dest, place) then return door end
                if dest.isExterior and outside == nil then outside = door end
                if any == nil then any = door end
            end
        end
    end
    return outside or any
end

-- Where the compass should point for a target: the target, or the door the
-- player has to take; nil if neither is known.
local function markerPosition(player, place)
    if inSpace(player.cell, place) then
        return place.position
    end
    if not player.cell.isExterior then
        local door = doorTowards(player.cell, place)
        return door and door.position
    end
    -- outside, the target indoors: the outside end of the door out of its cell
    local cell = cellOf(place)
    local exit = cell and doorTowards(cell, cellPlace(player.cell))
    if exit and inSpace(types.ESM4Door.destCell(exit), cellPlace(player.cell)) then
        return types.ESM4Door.destPosition(exit)
    end
    return nil
end

-- A target's conditions run on the target. One whose cell isn't loaded can't
-- be checked, so it shows.
local function targetPasses(target, place)
    if #target.conditions == 0 or place.object == nil then return true end
    local ok, passed = pcall(I.FNVDialogue.checkConditions, target.conditions, place.object)
    return ok and passed
end

local function updateMarkers()
    local player = world.players[1]
    markers = {}
    if player == nil or player.cell == nil then return end
    local key = activeQuest
    local data = key and quests:get(key)
    local rec = key and questRecord(key)
    if data == nil or rec == nil or not data.running or data.completed then
        player:sendEvent('FNVHudMarkers', { markers = markers })
        return
    end
    for _, o in ipairs(rec.objectives) do
        if data.objectives[o.index] == 'displayed' then
            for _, target in ipairs(o.targets or {}) do
                local place = findPlace(target.ref)
                if place and targetPasses(target, place) then
                    local position = markerPosition(player, place)
                    if position then
                        markers[#markers + 1] = { position = position, text = o.text, quest = questName(rec) }
                    end
                end
            end
        end
    end
    player:sendEvent('FNVHudMarkers', { markers = markers, quest = questName(rec) })
end

-- Where a place is on its worldspace's map: { position, worldSpaceId } outside; inside, the outside end of
-- the door out of its cell (inferred: one door deep); nil if neither is known.
local function worldPlace(place)
    if place.isExterior then return { position = place.position, worldSpaceId = place.worldSpaceId } end
    local cell = cellOf(place)
    if cell == nil then return nil end
    local ok, doors = pcall(function() return cell:getAll(types.ESM4Door) end)
    if not ok then return nil end
    for _, door in ipairs(doors) do
        if door.enabled and types.ESM4Door.isTeleport(door) then
            local dest = types.ESM4Door.destCell(door)
            if dest and dest.isExterior then
                return { position = types.ESM4Door.destPosition(door), worldSpaceId = dest.worldSpaceId }
            end
        end
    end
    return nil
end

-- The active quest's open objective targets on the world map: { position, worldSpaceId, text }.
local function worldMarkers()
    local res = {}
    local key = activeQuest
    local data = key and quests:get(key)
    local rec = key and questRecord(key)
    if data == nil or rec == nil or not data.running or data.completed then return res end
    for _, o in ipairs(rec.objectives) do
        if data.objectives[o.index] == 'displayed' then
            for _, target in ipairs(o.targets or {}) do
                local place = findPlace(target.ref)
                if place and targetPasses(target, place) then
                    local wp = worldPlace(place)
                    if wp then
                        wp.text = o.text
                        res[#res + 1] = wp
                    end
                end
            end
        end
    end
    return res
end

return {
    interfaceName = 'FNVHud',
    ---
    -- @module FNVHud
    -- @context global
    interface = {
        version = 0,
        --- Make a quest (editor id) the one the compass shows.
        setActiveQuest = function(q)
            activeQuest = q and tostring(q):lower() or nil
            markerTimer = 0
        end,
        getActiveQuest = function() return activeQuest end,
        --- The compass markers last sent to the player.
        getMarkers = function() return markers end,
        --- Show a notice in the HUD's corner.
        notify = notify,
        --- The active quest's targets on the world map: { position, worldSpaceId, text }.
        getWorldMarkers = worldMarkers,
        --- Where a reference or place is on the world map (see worldPlace), by form id.
        getWorldPlace = function(formId)
            local place = findPlace(formId)
            return place and worldPlace(place)
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            processChangedQuests()
            markerTimer = markerTimer - dt
            if markerTimer > 0 then return end
            markerTimer = MARKER_INTERVAL
            updateMarkers()
        end,
        -- onInit alone means a saved game from before this script: learn its
        -- quests quietly. A new game gets onNewGame after onInit.
        onInit = function()
            quietUpdate = true
            allChanged = true
        end,
        onNewGame = function()
            quietUpdate = false
        end,
        onSave = function()
            return { told = told, activeQuest = activeQuest }
        end,
        onLoad = function(data)
            told = data and data.told or {}
            activeQuest = data and data.activeQuest
            quietUpdate = data == nil
            allChanged = true
        end,
    },
    eventHandlers = {
        FNVHudSetActiveQuest = function(data)
            activeQuest = data.quest and tostring(data.quest):lower() or nil
            markerTimer = 0
        end,
    },
}
