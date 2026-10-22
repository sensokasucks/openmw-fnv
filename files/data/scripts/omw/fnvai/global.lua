-- FO3/FNV AI packages for ESM4 NPCs.
--
-- Every few seconds each NPC in the active cells picks its package the way
-- the original engine does: the first package of its list (highest priority
-- first) whose schedule covers the current game time and whose conditions
-- pass. The package then decides where the NPC walks; the engine walks it
-- there along the cell's navmesh (core.obscript.ai).
--
-- Supported for now: Travel, Sandbox, Wander, Sleep and Eat (walk to the
-- place; using beds, chairs and idle markers is not done yet), Guard,
-- Ambush, Dialogue and Use Item At (walk to the location and stay there),
-- Follow, Accompany and Escort (keep near the target). Moving to another
-- cell uses a door that leads there when the player can see the NPC, and
-- teleports it otherwise.
--
-- From the console (luag): I.FNVAI.debug('DocMitchell') prints the NPC's
-- packages and which one runs.

local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local ai = core.obscript and core.obscript.ai
if ai == nil or types.ESM4NPC == nil then
    return {}
end
local dlg = core.obscript.dialogue
local combat = core.obscript.combat

local PLAYER_REF = 'FormId:0x14'

-- package types (PKDT)
local T = {
    Find = 0, Follow = 1, Escort = 2, Eat = 3, Sleep = 4, Wander = 5, Travel = 6, Accompany = 7,
    UseItemAt = 8, Ambush = 9, FleeNotCombat = 10, CastMagic = 11, Sandbox = 12, Patrol = 13,
    Guard = 14, Dialogue = 15, UseWeapon = 16,
}

-- location types (PLDT)
local L = {
    NearReference = 0, InCell = 1, NearCurrentLocation = 2, NearEditorLocation = 3, ObjectId = 4,
    ObjectType = 5, NearLinkedReference = 6, AtPackageLocation = 7,
}

local EVALUATE_EVERY = 2.0 -- seconds between package picks
local TICK_EVERY = 0.25 -- seconds between behaviour updates

local function log(msg)
    print('[fnvai] ' .. msg)
end

-- ---------------------------------------------------------------- game time

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- The game starts on October 19th; months and dates count from there.
local function calendar(dayIndex)
    local month, date = 10, 19 + dayIndex
    while date > MONTH_DAYS[month] do
        date = date - MONTH_DAYS[month]
        month = month % 12 + 1
    end
    return month - 1, date -- PSDT months are 0-based
end

local function now()
    local seconds = core.getGameTime()
    local day = math.floor(seconds / 86400)
    local month, date = calendar(day)
    return {
        hour = math.floor(seconds / 3600) % 24,
        dayOfWeek = day % 7,
        month = month,
        date = date,
        yesterday = { dayOfWeek = (day - 1) % 7, month = select(1, calendar(math.max(day - 1, 0))),
            date = select(2, calendar(math.max(day - 1, 0))) },
    }
end

-- PSDT day of week: 0-6 Sunday to Saturday, 7 weekdays, 8 weekends, 9 Monday/Wednesday/Friday,
-- 10 Tuesday/Thursday.
local function dayMatches(scheduled, day)
    if scheduled <= 6 then return scheduled == day end
    if scheduled == 7 then return day ~= 0 and day ~= 6 end
    if scheduled == 8 then return day == 0 or day == 6 end
    if scheduled == 9 then return day == 1 or day == 3 or day == 5 end
    if scheduled == 10 then return day == 2 or day == 4 end
    return false
end

-- Whether hour falls in [start, start + duration), wrapping past midnight.
local function hourMatches(start, duration, hour)
    if hour == start then return true end
    local stop = start + duration
    if stop < 24 then
        return start < hour and hour < stop
    end
    return (start < hour or hour < stop - 24) and hour < stop
end

local function scheduleMatches(s, t)
    -- A package running past midnight also counts for the day it started on.
    local wraps = s.hour ~= -1 and s.hour + s.duration > 24
    if s.month ~= -1 and s.month ~= t.month and not (wraps and s.month == t.yesterday.month) then
        return false
    end
    if s.date ~= 0 and s.date ~= t.date and not (wraps and s.date == t.yesterday.date) then
        return false
    end
    if s.dayOfWeek ~= -1 and not dayMatches(s.dayOfWeek, t.dayOfWeek)
        and not (wraps and dayMatches(s.dayOfWeek, t.yesterday.dayOfWeek)) then
        return false
    end
    if s.hour ~= -1 and not hourMatches(s.hour, s.duration, t.hour) then
        return false
    end
    return true
end

-- ---------------------------------------------------------------- package choice

local packagesByRecord = {}

local function getPackages(npc)
    local key = npc.recordId
    local list = packagesByRecord[key]
    if list == nil then
        list = ai.getPackages(npc) or {}
        packagesByRecord[key] = list
    end
    return list
end

local function conditionsPass(pkg, npc)
    if #pkg.conditions == 0 then return true end
    local dialogue = I.FNVDialogue
    if dialogue == nil or dialogue.checkConditions == nil then return true end
    return (dialogue.checkConditions(pkg.conditions, npc))
end

local function pickPackage(npc)
    local t = now()
    for _, pkg in ipairs(getPackages(npc)) do
        if scheduleMatches(pkg.schedule, t) and conditionsPass(pkg, npc) then
            return pkg
        end
    end
    return nil
end

-- ---------------------------------------------------------------- locations

local function player()
    return world.players[1]
end

local function sameCell(a, b)
    return a ~= nil and b ~= nil and a.id == b.id
end

local function getObject(formId)
    if formId == nil or formId == '' then return nil end
    local ok, obj = pcall(world.getObjectByFormId, formId)
    if ok and obj ~= nil and obj:isValid() then return obj end
    return nil
end

local function getCell(formId)
    local ok, cell = pcall(world.getCellById, formId)
    if ok then return cell end
    return nil
end

-- Where a package wants the NPC: { cell =, position = (nil: anywhere in the cell), yaw =, radius = }
local function resolveLocation(npc, pkg, s)
    local loc = pkg.locations[1]
    if loc == nil then
        return { cell = npc.cell, position = s.anchor, radius = 0 }
    end
    local radius = loc.radius or 0
    if loc.type == L.NearReference then
        local ref = getObject(loc.id)
        if ref == nil then return nil end
        return { cell = ref.cell, position = ref.position, yaw = ref.rotation:getYaw(), radius = radius, ref = ref }
    elseif loc.type == L.InCell then
        local cell = getCell(loc.id)
        if cell == nil then return nil end
        return { cell = cell, radius = radius }
    elseif loc.type == L.NearEditorLocation then
        return { cell = npc.cell, position = npc.startingPosition, yaw = npc.startingRotation:getYaw(),
            radius = radius }
    elseif loc.type == L.ObjectId then
        local best, bestDist = nil, math.huge
        for _, obj in ipairs(npc.cell:getAll()) do
            if obj.recordId == loc.id then
                local d = (obj.position - npc.position):length()
                if d < bestDist then best, bestDist = obj, d end
            end
        end
        if best ~= nil then
            return { cell = best.cell, position = best.position, yaw = best.rotation:getYaw(), radius = radius,
                ref = best }
        end
    end
    -- near the current location (also the fallback for linked refs and object types)
    return { cell = npc.cell, position = s.anchor, radius = radius }
end

-- ---------------------------------------------------------------- moving between cells

local function playerSees(npc)
    local p = player()
    if p == nil then return false end
    if npc.cell.isExterior and p.cell.isExterior then
        return (npc.position - p.position):length() < 8192
    end
    return sameCell(npc.cell, p.cell)
end

-- ---------------------------------------------------------------- behaviour

local states = {} -- npc id -> state
local tracked = {} -- npc id -> npc
local simTime = 0

local function moveTo(npc, s, position, options)
    ai.moveTo(npc, position, options)
    s.phase = 'go'
    s.goSince = simTime
end

-- Status of the last moveTo once the engine has taken it on.
local function moveStatus(npc, s)
    if simTime - (s.goSince or 0) < 0.5 then return 'moving' end
    return ai.status(npc)
end

local function nearlyAt(npc, position, radius)
    local d = npc.position - position
    return util.vector2(d.x, d.y):length() <= math.max(radius or 0, 64)
end

-- cell:getAll() takes no ESM4 type filters
local function teleportDoors(cell)
    local doors = {}
    if types.ESM4Door == nil then return doors end
    for _, obj in ipairs(cell:getAll()) do
        if types.ESM4Door.objectIsInstance(obj) and types.ESM4Door.isTeleport(obj) then
            doors[#doors + 1] = obj
        end
    end
    return doors
end

local function findDoorTo(cell, target)
    for _, door in ipairs(teleportDoors(cell)) do
        if sameCell(types.ESM4Door.destCell(door), target) then
            return door
        end
    end
    return nil
end

local function findDoorOutside(cell)
    for _, door in ipairs(teleportDoors(cell)) do
        local dest = types.ESM4Door.destCell(door)
        if dest ~= nil and dest.isExterior then
            return door
        end
    end
    return nil
end

local function teleport(npc, cell, position, yaw)
    local rotation = yaw and util.transform.rotateZ(yaw) or nil
    log(('%s goes to %s'):format(npc.recordId, tostring(cell)))
    ai.stop(npc)
    npc:teleport(cell, position, rotation)
end

-- Where an actor coming in through a door of the interior cell appears: the destination of the door on the other
-- side that leads back in.
local function arrivalInside(cell, doorInside)
    local out = types.ESM4Door.destCell(doorInside)
    local back = out and findDoorTo(out, cell)
    if back ~= nil then
        return types.ESM4Door.destPosition(back), types.ESM4Door.destRotation(back):getYaw()
    end
    return doorInside.position, doorInside.rotation:getYaw()
end

-- Some position inside the cell to appear at when the NPC is moved there out of the player's sight.
local function entryPoint(cell, dest)
    if dest.position ~= nil then return dest.position, dest.yaw end
    local door = teleportDoors(cell)[1]
    if door ~= nil then
        return arrivalInside(cell, door)
    end
    return nil
end

-- Walks to the door and goes through it once there.
local function useDoor(npc, s, door)
    if s.door ~= door.id then
        s.door = door.id
        moveTo(npc, s, door.position, { tolerance = 64 })
        return
    end
    local status = moveStatus(npc, s)
    if status == 'arrived' or status == 'nopath' or nearlyAt(npc, door.position, 96) then
        teleport(npc, types.ESM4Door.destCell(door), types.ESM4Door.destPosition(door),
            types.ESM4Door.destRotation(door):getYaw())
        s.door = nil
        s.phase = nil
    end
end

-- Walks outside to the entrance of the interior cell and comes in there.
local function enterFromOutside(npc, s, cell)
    local best, bestDistance = nil, math.huge
    for _, door in ipairs(teleportDoors(cell)) do
        local dest = types.ESM4Door.destCell(door)
        if dest ~= nil and dest.isExterior then
            local distance = (types.ESM4Door.destPosition(door) - npc.position):length()
            if distance < bestDistance then
                best, bestDistance = door, distance
            end
        end
    end
    if best == nil then return end
    local entrance = types.ESM4Door.destPosition(best)
    if s.door ~= best.id then
        s.door = best.id
        moveTo(npc, s, entrance, { tolerance = 64 })
        return
    end
    local status = moveStatus(npc, s)
    if status == 'arrived' or status == 'nopath' or nearlyAt(npc, entrance, 128) then
        local position, yaw = arrivalInside(cell, best)
        teleport(npc, cell, position, yaw)
        s.door = nil
        s.phase = nil
    end
end

-- Walks or teleports the NPC towards dest's cell; true once it is there.
local function reachCell(npc, s, dest)
    if dest.cell == nil or sameCell(npc.cell, dest.cell) then
        s.door = nil
        return true
    end
    if npc.cell.isExterior and dest.cell.isExterior then
        return true -- one navmesh network across exterior cells
    end
    if playerSees(npc) then
        -- go the way the player would: through a door to the place, or outside first
        local door = findDoorTo(npc.cell, dest.cell)
        if door == nil and not npc.cell.isExterior then
            door = findDoorOutside(npc.cell)
        end
        if door ~= nil then
            useDoor(npc, s, door)
        elseif npc.cell.isExterior then
            enterFromOutside(npc, s, dest.cell)
        end
        return false
    end
    local position, yaw = entryPoint(dest.cell, dest)
    if position ~= nil then
        teleport(npc, dest.cell, position, yaw)
    end
    s.door = nil
    s.phase = nil
    return false
end

-- Travel-like: walk to the place and stay.
local function goAndStay(npc, s, dest)
    if dest.position == nil then
        -- anywhere in the cell will do
        if s.phase == nil then s.phase = 'stay' end
        return
    end
    if s.phase == nil then
        if nearlyAt(npc, dest.position, dest.radius) then
            s.phase = 'stay'
            if dest.radius == 0 and dest.yaw then ai.face(npc, dest.yaw) end
            return
        end
        local yaw = dest.radius == 0 and dest.yaw or nil
        moveTo(npc, s, dest.position, { yaw = yaw, run = s.run })
    elseif s.phase == 'go' then
        local status = moveStatus(npc, s)
        if status == 'arrived' or status == 'nopath' then
            s.phase = 'stay'
            if status == 'nopath' then
                log(('%s: no path to %s'):format(npc.recordId, tostring(dest.position)))
            end
        end
    end
end

-- Sandbox/Wander: walk to random spots around the place and linger there.
local function roam(npc, s, dest)
    local center = dest.position or s.anchor
    local radius = dest.radius
    if radius == nil or radius <= 0 then
        radius = dest.position and 512 or 1024
    end
    if s.phase == nil or (s.phase == 'wait' and simTime >= s.waitUntil) then
        local point = ai.randomPoint(npc, center, radius)
        if point == nil then
            s.phase, s.waitUntil = 'wait', simTime + 10
            return
        end
        moveTo(npc, s, point, {})
    elseif s.phase == 'go' then
        local status = moveStatus(npc, s)
        if status ~= 'moving' then
            s.phase = 'wait'
            s.waitUntil = simTime + 6 + math.random() * 14
            if math.random() < 0.5 then
                ai.face(npc, (math.random() * 2 - 1) * math.pi)
            end
        end
    end
end

local function follow(npc, s, pkg)
    local target = pkg.targets[1]
    local ref = target and (target.id == PLAYER_REF and player() or getObject(target.id))
    if ref == nil or not sameCell(ref.cell, npc.cell) then return end
    local distance = (ref.position - npc.position):length()
    local keep = math.max(target.count or 0, 150)
    if distance > keep + 100 and (s.phase ~= 'go' or simTime - s.goSince > 1) then
        moveTo(npc, s, ref.position, { run = distance > 600, tolerance = keep })
    elseif distance <= keep and s.phase == 'go' then
        ai.stop(npc)
        s.phase = nil
    end
end

-- Nearest bed of the NPC's cell that no other NPC has taken. TODO: lie down in it (furniture markers).
local bedTakenBy = {} -- bed id -> npc id
local function findBed(npc)
    if types.ESM4Furniture == nil then return nil end
    local best, bestDistance = nil, math.huge
    for _, obj in ipairs(npc.cell:getAll()) do
        if types.ESM4Furniture.objectIsInstance(obj) and (bedTakenBy[obj.id] == nil or bedTakenBy[obj.id] == npc.id) then
            local model = (types.ESM4Furniture.record(obj).model or ''):lower()
            if model:find('bed') or model:find('mattress') then
                local distance = (obj.position - npc.position):length()
                if distance < bestDistance then best, bestDistance = obj, distance end
            end
        end
    end
    if best ~= nil then bedTakenBy[best.id] = npc.id end
    return best
end

local function tick(npc, s)
    local pkg = s.package
    if pkg == nil then return end
    if pkg.type == T.Follow or pkg.type == T.Accompany or pkg.type == T.Escort then
        follow(npc, s, pkg)
        return
    end
    local dest = s.dest
    if dest == nil then return end
    if not reachCell(npc, s, dest) then return end
    if s.anchorCell ~= npc.cell.id then
        -- arrived in another cell: "near the current location" now means here
        s.anchorCell = npc.cell.id
        s.anchor = npc.position
    end
    if pkg.type == T.Sandbox or pkg.type == T.Wander then
        roam(npc, s, dest)
    elseif dest.position == nil and pkg.type == T.Sleep then
        local bed = s.bed or findBed(npc)
        s.bed = bed or false
        if bed then
            goAndStay(npc, s, { position = bed.position, radius = 96 })
        else
            roam(npc, s, { radius = 512 })
        end
    elseif dest.position == nil and pkg.type == T.Eat then
        roam(npc, s, { radius = 512 })
    else
        goAndStay(npc, s, dest)
    end
end

local function start(npc, s, pkg)
    s.package = pkg
    s.phase = nil
    s.anchor = npc.position
    s.anchorCell = npc.cell.id
    s.bed = nil
    s.run = false
    if pkg ~= nil then
        s.dest = resolveLocation(npc, pkg, s)
        log(('%s picked package %s (%s)'):format(npc.recordId, pkg.editorId, pkg.typeName))
    else
        s.dest = nil
        ai.stop(npc)
    end
end

local function evaluate(npc, s)
    local pkg = pickPackage(npc)
    local id = pkg and pkg.id
    if id ~= (s.package and s.package.id) then
        start(npc, s, pkg)
    elseif pkg ~= nil and s.dest ~= nil and s.dest.ref ~= nil then
        -- a moving target, such as a reference that walks itself
        s.dest = resolveLocation(npc, pkg, s)
    end
end

local nextTick = 0

return {
    interfaceName = 'FNVAI',
    interface = {
        version = 0,
        --- Prints an NPC's packages, whether each one applies now, and the running one.
        debug = function(name)
            name = (name or ''):lower()
            for id, npc in pairs(tracked) do
                local actor = dlg and dlg.getActor(npc)
                local editorId = actor and actor.editorId or ''
                if name == '' or editorId:lower() == name then
                    local t = now()
                    log(('%s (%s) at %s, hour %d'):format(editorId, id, tostring(npc.position), t.hour))
                    for _, pkg in ipairs(getPackages(npc)) do
                        log(('  %s %s schedule=%s conditions=%s'):format(pkg.editorId, pkg.typeName,
                            tostring(scheduleMatches(pkg.schedule, t)), tostring(conditionsPass(pkg, npc))))
                    end
                    local s = states[id]
                    log('  running: ' .. tostring(s and s.package and s.package.editorId) .. ', phase '
                        .. tostring(s and s.phase) .. ', move ' .. ai.status(npc))
                end
            end
        end,
    },
    engineHandlers = {
        onObjectActive = function(obj)
            if types.ESM4NPC.objectIsInstance(obj) then
                tracked[obj.id] = obj
            end
        end,
        onUpdate = function(dt)
            simTime = simTime + dt
            if simTime < nextTick then return end
            nextTick = simTime + TICK_EVERY
            for id, npc in pairs(tracked) do
                if not npc:isValid() or not ai.isInScene(npc) or not npc.enabled
                    or (combat and combat.isDead(npc)) then
                    tracked[id] = nil
                    states[id] = nil
                elseif I.FNVCombat and I.FNVCombat.isInCombat and I.FNVCombat.isInCombat(npc) then
                    -- fighting (scripts/omw/fnvcombat); the package is picked again afterwards
                    states[id] = nil
                else
                    local s = states[id]
                    if s == nil then
                        -- spread the package picks over time
                        s = { nextEvaluation = simTime + math.random() * EVALUATE_EVERY }
                        states[id] = s
                    end
                    if simTime >= s.nextEvaluation then
                        s.nextEvaluation = simTime + EVALUATE_EVERY
                        evaluate(npc, s)
                    end
                    tick(npc, s)
                end
            end
        end,
    },
}
