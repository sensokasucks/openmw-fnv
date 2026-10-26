-- FO3/FNV AI packages for ESM4 NPCs.
--
-- Every few seconds each NPC in the active cells picks its package the way
-- the original engine does: the first package of its list (highest priority
-- first) whose schedule covers the current game time and whose conditions
-- pass. The package then decides where the NPC walks; the engine walks it
-- there along the cell's navmesh (core.obscript.ai).
--
-- Supported for now: Travel, Sandbox (wander, sit on chairs, lean, use
-- idle markers), Wander, Sleep (lie in a free bed), Eat (sit down and eat),
-- Guard, Ambush and Use Item At (walk to the location and stay there),
-- Dialogue (walk there, then talk to the player once near), Escort (lead
-- the target there), Follow and Accompany (keep near the target). Moving to
-- another cell uses a door that leads there when the player can see the
-- NPC, and teleports it otherwise. Furniture and idle markers are handled
-- in furniture.lua, the animations come from the idle tree (idles.lua).
--
-- Packages that end: Travel, Find and Use Item At once the NPC is there
-- (a Travel to a piece of furniture ends with the NPC sitting or lying on
-- it), Escort once there with the target, Dialogue once the conversation
-- is over. The package's OnEnd script runs then and the package is picked
-- again: the original picker has no "done" check, so a package that still
-- passes stays current (the NPC stays where it went) until its conditions
-- send the NPC on to another one. OnBegin runs when a package starts,
-- OnChange when it is replaced before it ended. A script package
-- (AddScriptPackage) is dropped once it ends. Once per day packages run at
-- most once a game day.
--
-- From the console (luag): I.FNVAI.debug('DocMitchell') prints the NPC's
-- packages and which one runs.

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local ai = core.obscript and core.obscript.ai
if ai == nil or types.ESM4NPC == nil then
    return {}
end
local furniture = require('scripts.omw.fnvai.furniture')
local dlg = core.obscript.dialogue
local combat = core.obscript.combat

-- PlayerRef is form 0x14 of whichever file is loaded first, so only the low 24 bits tell
local function isPlayerRef(formId)
    local hex = type(formId) == 'string' and formId:match('^FormId:0x(%x+)$')
    return hex ~= nil and tonumber(hex, 16) % 0x1000000 == 0x14
end

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

-- Sandbox package specific flags (PKDT): what the NPC may not do
local SANDBOX_NO_EATING = 1
local SANDBOX_NO_SLEEPING = 2
local SANDBOX_NO_CONVERSATION = 4
local SANDBOX_NO_IDLE_MARKERS = 8
local SANDBOX_NO_FURNITURE = 16
local SANDBOX_NO_WANDERING = 32

local function hasFlag(flags, flag)
    return math.floor((flags or 0) / flag) % 2 == 1
end

-- general flags (PKDT)
local FLAG_ONCE_PER_DAY = 0x400
local FLAG_ALWAYS_RUN = 0x2000
local FLAG_SKIPPED = 0x8000 -- skipped by the picker unless Once per day is set too (picker 0x67e780)

-- fSandboxDurationMultFurniture / fSandboxDurationMultIdleMarker
local SANDBOX_FURNITURE_MULT = 3.0
local SANDBOX_IDLE_MARKER_MULT = 1.5

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

local scriptPackages = {} -- npc id -> package given by AddScriptPackage; it comes first
local ranOn = {} -- npc id -> package id -> game day a Once per day package last started

local function today()
    return math.floor(core.getGameTime() / 86400)
end

-- The flag checks of the picker: Once per day packages that already ran today are skipped (but not the one
-- running now, until it ends), and so are packages with flag 0x8000.
local function flagsAllow(npc, pkg, s)
    if hasFlag(pkg.flags, FLAG_ONCE_PER_DAY) then
        if s ~= nil and s.package ~= nil and s.package.id == pkg.id and not s.complete then return true end
        local ran = ranOn[npc.id]
        return not (ran ~= nil and ran[pkg.id] == today())
    end
    return not hasFlag(pkg.flags, FLAG_SKIPPED)
end

local function pickPackage(npc, s)
    local forced = scriptPackages[npc.id]
    if forced then return forced end
    local t = now()
    for _, pkg in ipairs(getPackages(npc)) do
        if flagsAllow(npc, pkg, s) and scheduleMatches(pkg.schedule, t) and conditionsPass(pkg, npc) then
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

-- Travel-like: walk to the place and stay. A Travel to a piece of furniture ends with the NPC using it (Doc
-- Mitchell's Travel to his chair is how he sits down). arrived(npc, s) is called once the NPC is there.
local function goAndStay(npc, s, dest, pkg, arrived)
    if dest.position == nil then
        -- anywhere in the cell will do
        if s.phase == nil then
            s.phase = 'stay'
            arrived(npc, s)
        end
        return
    end
    if s.phase == nil then
        local seat = pkg.type == T.Travel and not s.noFurniture and dest.ref ~= nil
            and furniture.markerOn(npc, dest.ref) or nil
        if seat ~= nil then
            -- no duration: the NPC stays on it until the package changes
            furniture.begin(npc, s, seat, { sleep = seat.sleep, package = pkg.type }, simTime)
            s.phase = 'furniture'
            s.useAtEnd = true
            return
        end
        if nearlyAt(npc, dest.position, dest.radius) then
            s.phase = 'stay'
            if dest.radius == 0 and dest.yaw then ai.face(npc, dest.yaw) end
            arrived(npc, s)
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
                s.noReturn = true
            end
            arrived(npc, s)
        end
    elseif s.phase == 'stay' and s.complete and not s.noReturn
        and not nearlyAt(npc, dest.position, (dest.radius or 0) + 256) then
        -- pushed or moved away from where a finished package left it: picked again, the package walks back
        s.phase = nil
        s.complete = false
    end
end

-- Sandbox/Wander: walk to random spots around the place and linger there; a sandboxing NPC also sits on
-- the chairs and uses the idle markers nearby.
local function roam(npc, s, dest, pkg)
    local center = dest.position or s.anchor
    local radius = dest.radius
    if radius == nil or radius <= 0 then
        radius = dest.position and 512 or 1024
    end
    if s.phase == nil or (s.phase == 'wait' and simTime >= s.waitUntil) then
        local flags = pkg and pkg.type == T.Sandbox and pkg.specificFlags or 0
        local linger = 8 + math.random() * 8
        local roll = math.random()
        if pkg and pkg.type == T.Sandbox and not hasFlag(flags, SANDBOX_NO_FURNITURE) and roll < 0.45 then
            local target = furniture.findFurniture(npc, center, radius, false)
            if target ~= nil and not (s.avoid and s.avoid[target.object.id]) then
                furniture.begin(npc, s, target, { package = pkg.type, duration = linger * SANDBOX_FURNITURE_MULT },
                    simTime)
                s.phase = 'furniture'
                return
            end
        end
        if pkg and pkg.type == T.Sandbox and not hasFlag(flags, SANDBOX_NO_IDLE_MARKERS) and roll < 0.75 then
            local target = furniture.findIdleMarker(npc, center, radius)
            if target ~= nil and not (s.avoid and s.avoid[target.object.id]) then
                local duration = target.record.idleTimer
                if duration <= 0 then duration = linger * SANDBOX_IDLE_MARKER_MULT end
                furniture.begin(npc, s, target, { package = pkg.type, duration = duration }, simTime)
                s.phase = 'furniture'
                return
            end
        end
        if hasFlag(flags, SANDBOX_NO_WANDERING) then
            s.phase, s.waitUntil = 'wait', simTime + linger
            return
        end
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

local function targetRef(pkg)
    local target = pkg.targets[1]
    if target == nil then return nil end
    if isPlayerRef(target.id) then return player() end
    return getObject(target.id)
end

local function follow(npc, s, pkg)
    local target = pkg.targets[1]
    local ref = targetRef(pkg)
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

-- Sleep: lie down in a free bed near the place (anywhere in the cell without one), else linger there.
local function sleep(npc, s, dest)
    if s.phase == nil and not s.noFurniture then
        local center = dest.position or npc.position
        local radius = dest.position and math.max(dest.radius or 0, 512) or math.huge
        local bed = furniture.findFurniture(npc, center, radius, true)
        if bed ~= nil and not (s.avoid and s.avoid[bed.object.id]) then
            furniture.begin(npc, s, bed, { sleep = true, package = T.Sleep }, simTime)
            s.phase = 'furniture'
            return
        end
        s.noFurniture = true
    end
    roam(npc, s, { position = dest.position, radius = 512 })
end

-- Eat: sit on a chair near the place and eat there, else linger.
local function eat(npc, s, dest)
    if s.phase == nil and not s.noFurniture then
        local center = dest.position or npc.position
        local radius = dest.position and math.max(dest.radius or 0, 512) or 1024
        local chair = furniture.findFurniture(npc, center, radius, false)
        if chair ~= nil and not (s.avoid and s.avoid[chair.object.id]) then
            -- GetCurrentAIProcedure 10 = eating; the food idles check which item is in hand
            furniture.begin(npc, s, chair, { procedure = 10, usedItem = 'random', package = T.Eat }, simTime)
            s.phase = 'furniture'
            return
        end
        s.noFurniture = true
    end
    roam(npc, s, { position = dest.position, radius = 512 })
end

-- ---------------------------------------------------------------- package events and ending

local idles = require('scripts.omw.fnvai.idles')

-- Runs a package event (onBegin, onEnd, onChange): plays its idle and runs its result script on the NPC.
local function runEvent(npc, pkg, name)
    local event = pkg[name]
    if event == nil then return end
    if event.idle ~= '' then
        local idle = idles.get(event.idle)
        local leaf = idle and idles.pick(idle, npc, idles.furnitureOverrides({ package = pkg.type }))
        if leaf ~= nil then ai.playIdle(npc, idles.modelPath(leaf)) end
    end
    if event.script ~= '' and I.FNVDialogue and I.FNVDialogue.runResultScript then
        I.FNVDialogue.runResultScript(event.script, pkg.editorId .. ' ' .. name, npc)
    end
    if event.topic ~= '' then
        log(('%s: %s %s topic %s is not said yet'):format(npc.recordId, pkg.editorId, name, event.topic))
    end
end

-- The package's procedures reached DONE: OnEnd runs and the package is picked again.
local function completePackage(npc, s, why)
    local pkg = s.package
    if pkg == nil or s.complete then return end
    s.complete = true
    log(('%s finished package %s (%s)'):format(npc.recordId, pkg.editorId, why))
    local forced = scriptPackages[npc.id]
    if forced ~= nil and forced.id == pkg.id then
        scriptPackages[npc.id] = nil
    end
    runEvent(npc, pkg, 'onEnd')
    s.nextEvaluation = simTime
end

-- What the NPC does once at a package's location.
local function arrived(npc, s)
    local pkg = s.package
    if pkg == nil then return end
    if pkg.type == T.Travel or pkg.type == T.Find or pkg.type == T.UseItemAt then
        completePackage(npc, s, 'there')
    elseif pkg.type == T.Dialogue then
        s.phase = 'converse'
    end
end

-- Dialogue: once there, wait for the target (the player) to come within the package's distance, turn to it and
-- talk; the package ends when the conversation does.
local DIALOGUE_DISTANCE = 420

local function converse(npc, s, pkg)
    if s.phase == 'talking' then
        if not (I.FNVDialogue and I.FNVDialogue.isTalkingTo(npc)) then
            completePackage(npc, s, 'talked')
            s.phase = 'stay'
        end
        return
    end
    local target = pkg.targets[1]
    local ref = targetRef(pkg)
    if ref == nil or not isPlayerRef(target.id) or not sameCell(ref.cell, npc.cell) then return end
    local distance = target.count and target.count > 0 and target.count or DIALOGUE_DISTANCE
    local d = ref.position - npc.position
    if d:length() > distance then return end
    ai.face(npc, math.atan2(d.x, d.y))
    local topic = pkg.dialogue and pkg.dialogue.topic ~= '' and pkg.dialogue.topic or nil
    if I.FNVDialogue and I.FNVDialogue.startConversation(npc, topic) then
        log(('%s starts a conversation (%s)'):format(npc.recordId, pkg.editorId))
        s.phase = 'talking'
    end
end

-- Escort: lead the target to the place, waiting whenever it falls behind; ends once both are there.
local ESCORT_WAIT_DISTANCE = 512 -- fAIEscortWaitDistanceInterior

local function escort(npc, s, dest, pkg)
    local ref = targetRef(pkg)
    if dest.position == nil or ref == nil then
        follow(npc, s, pkg)
        return
    end
    local wait = ESCORT_WAIT_DISTANCE * (npc.cell.isExterior and 2 or 1)
    local behind = not sameCell(ref.cell, npc.cell) or (ref.position - npc.position):length() > wait
    if nearlyAt(npc, dest.position, dest.radius) then
        if s.phase == 'go' then ai.stop(npc) end
        s.phase = 'stay'
        if not behind then completePackage(npc, s, 'escorted') end
    elseif behind then
        if s.phase == 'go' then
            ai.stop(npc)
            s.phase = 'wait'
        end
        if sameCell(ref.cell, npc.cell) then
            local d = ref.position - npc.position
            ai.face(npc, math.atan2(d.x, d.y))
        end
    elseif s.phase ~= 'go' or moveStatus(npc, s) ~= 'moving' then
        moveTo(npc, s, dest.position, { run = s.run })
    end
end

-- ---------------------------------------------------------------- behaviour, continued

local startPackage

-- Runs the furniture use; true while the NPC is busy with it.
local function tickFurniture(npc, s)
    if not furniture.inUse(s) then return false end
    local phase = furniture.tick(npc, s, simTime)
    if phase == 'done' or phase == 'failed' then
        if phase == 'failed' then
            s.avoid = s.avoid or {}
            local target = s.lastTarget
            if target ~= nil then s.avoid[target] = true end
        end
        if s.pending ~= nil then
            local pending = s.pending
            s.pending = nil
            startPackage(npc, s, pending.pkg)
            return true
        end
        if s.useAtEnd then
            -- could not use the furniture the package goes to: stand there instead
            s.useAtEnd = nil
            s.noFurniture = true
            s.phase = nil
            return false
        end
        s.phase = 'wait'
        s.waitUntil = simTime + 2 + math.random() * 4
        return false
    end
    if s.furn ~= nil and s.furn.target ~= nil then
        s.lastTarget = s.furn.target.object.id
    end
    if phase == 'use' and s.useAtEnd and not s.complete then
        completePackage(npc, s, 'using ' .. tostring(s.furn and s.furn.target.object.recordId))
    end
    return true
end

local function tick(npc, s)
    if tickFurniture(npc, s) then return end
    local pkg = s.package
    if pkg == nil then return end
    if pkg.type == T.Follow or pkg.type == T.Accompany then
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
    if pkg.type == T.Escort then
        escort(npc, s, dest, pkg)
    elseif pkg.type == T.Sandbox or pkg.type == T.Wander then
        roam(npc, s, dest, pkg)
    elseif pkg.type == T.Sleep then
        sleep(npc, s, dest)
    elseif pkg.type == T.Eat then
        eat(npc, s, dest)
    elseif pkg.type == T.Dialogue and (s.phase == 'converse' or s.phase == 'talking') then
        converse(npc, s, pkg)
    else
        goAndStay(npc, s, dest, pkg, arrived)
    end
end

startPackage = function(npc, s, pkg)
    s.package = pkg
    s.phase = nil
    s.anchor = npc.position
    s.anchorCell = npc.cell.id
    s.run = pkg ~= nil and hasFlag(pkg.flags, FLAG_ALWAYS_RUN)
    s.noFurniture = nil
    s.useAtEnd = nil
    s.complete = false
    s.noReturn = nil
    if pkg ~= nil then
        s.dest = resolveLocation(npc, pkg, s)
        log(('%s picked package %s (%s)'):format(npc.recordId, pkg.editorId, pkg.typeName))
        if hasFlag(pkg.flags, FLAG_ONCE_PER_DAY) then
            ranOn[npc.id] = ranOn[npc.id] or {}
            ranOn[npc.id][pkg.id] = today()
        end
        runEvent(npc, pkg, 'onBegin')
    else
        s.dest = nil
        ai.stop(npc)
    end
end

-- Switches package; an NPC using furniture gets up first and starts the new package once standing.
local function start(npc, s, pkg)
    local old = s.package
    if old ~= nil and not s.complete then
        runEvent(npc, old, 'onChange')
    end
    if furniture.inUse(s) then
        s.package = pkg
        s.complete = false
        s.useAtEnd = nil
        s.pending = { pkg = pkg }
        furniture.leave(npc, s)
        return
    end
    startPackage(npc, s, pkg)
end

local function evaluate(npc, s)
    local pkg = pickPackage(npc, s)
    local id = pkg and pkg.id
    if id ~= (s.package and s.package.id) then
        start(npc, s, pkg)
    elseif pkg ~= nil and s.dest ~= nil and s.dest.ref ~= nil and not s.complete then
        -- a moving target, such as a reference that walks itself
        s.dest = resolveLocation(npc, pkg, s)
    end
end

-- ---------------------------------------------------------------- state for scripts

-- GetSitting / GetSleeping: 0 no, 1 going to the seat or bed, 2 sitting / lying down, 3 seated / asleep,
-- 4 getting up.
local function furnitureState(npc, s)
    local f = s and s.furn
    if f == nil or f.idleMarker then return 0, 0 end
    local value = 1
    if f.phase == 'use' then
        local status = ai.useStatus(npc)
        value = (status == 'entering' and 2) or (status == 'leaving' and 4) or 3
    elseif f.phase == 'leave' then
        value = 4
    end
    if f.sleep then return 0, value end
    return value, 0
end

-- What object scripts (openmw_aux/obscript/bindings.lua) read: actor id -> { package, packageType, sitting,
-- sleeping }.
local actorAI = storage.globalSection('ESM4ActorAI')
actorAI:setLifeTime(storage.LIFE_TIME.GameSession)
local published = {}

local function publish(id, npc, s)
    if s == nil then
        if published[id] ~= nil then
            published[id] = nil
            actorAI:set(tostring(id), nil)
        end
        return
    end
    local sitting, sleeping = furnitureState(npc, s)
    local pkg = s.package
    local packageId = pkg and pkg.id or ''
    local last = published[id]
    if last ~= nil and last.package == packageId and last.sitting == sitting and last.sleeping == sleeping then
        return
    end
    local value = { package = packageId, packageType = pkg and pkg.type or 0, sitting = sitting, sleeping = sleeping }
    published[id] = value
    actorAI:set(tostring(id), value)
end

-- Condition functions and commands of quest, result and dialogue scripts.
local installed = false
local function install()
    if installed then return end
    installed = true
    local dialogue = I.FNVDialogue
    if dialogue == nil or dialogue.setConditionFunction == nil then return end
    local function stateOf(obj)
        return obj ~= nil and states[obj.id] or nil
    end
    local function currentPackage(obj)
        local s = stateOf(obj)
        return s and s.package
    end
    local function sitting(obj)
        if obj == nil then return 0 end
        local s = stateOf(obj)
        if s ~= nil then return (furnitureState(obj, s)) end
        local current = storage.globalSection('ESM4CurrentFurniture'):get(tostring(obj.id))
        return (current and current ~= '') and 3 or 0
    end
    local function sleeping(obj)
        return select(2, furnitureState(obj, stateOf(obj)))
    end
    dialogue.setConditionFunction(110, function(_, obj) -- GetCurrentAIPackage
        local pkg = currentPackage(obj)
        return pkg and pkg.type or 0
    end)
    dialogue.setConditionFunction(161, function(cond, obj) -- GetIsCurrentPackage
        local pkg = currentPackage(obj)
        return pkg ~= nil and pkg.id == cond.param1Form
    end)
    dialogue.setConditionFunction(159, function(_, obj) return sitting(obj) end) -- GetSitting
    dialogue.setConditionFunction(49, function(_, obj) return sleeping(obj) end) -- GetSleeping
    dialogue.bindCommand('GetCurrentAIPackage', function(obj)
        local pkg = currentPackage(obj)
        return pkg and pkg.type or 0
    end)
    dialogue.bindCommand('GetIsCurrentPackage', function(obj, package)
        local pkg = currentPackage(obj)
        local wanted = type(package) == 'string' and core.obscript.resolvePackageEditorId(package)
        return (pkg ~= nil and wanted and pkg.id == wanted) and 1 or 0
    end)
    dialogue.bindCommand('GetSitting', sitting)
    dialogue.bindCommand('GetSleeping', sleeping)
end

local nextTick = 0

return {
    interfaceName = 'FNVAI',
    interface = {
        version = 0,
        --- AddScriptPackage: the NPC runs this package (form id) ahead of its own
        -- until RemoveScriptPackage; nil package removes it.
        setScriptPackage = function(npc, packageId)
            if npc == nil or not npc:isValid() then return end
            scriptPackages[npc.id] = packageId and ai.getPackage(packageId) or nil
            local s = states[npc.id]
            if s then s.nextEvaluation = simTime end
        end,
        --- EvaluatePackage: re-picks the NPC's package at its next behaviour update.
        evaluate = function(npc)
            local s = npc and states[npc.id]
            if s then s.nextEvaluation = simTime end
        end,
        --- Makes an NPC (by editor id) use the nearest chair ('sit'), bed ('sleep') or idle marker
        -- ('idle') for duration seconds, for testing from the console: I.FNVAI.use('Trudy', 'sit').
        use = function(name, kind, duration)
            name = (name or ''):lower()
            for id, npc in pairs(tracked) do
                local actor = dlg and dlg.getActor(npc)
                local editorId = actor and actor.editorId or ''
                if editorId:lower() == name then
                    local s = states[id]
                    if s == nil then
                        log(editorId .. ': not updated yet')
                        return false
                    end
                    local target
                    if kind == 'idle' then
                        target = furniture.findIdleMarker(npc, npc.position, 4096)
                    else
                        target = furniture.findFurniture(npc, npc.position, 4096, kind == 'sleep')
                    end
                    if target == nil then
                        log(editorId .. ': nothing to use nearby')
                        return false
                    end
                    ai.stop(npc)
                    s.phase = 'furniture'
                    furniture.begin(npc, s, target, { sleep = kind == 'sleep', duration = duration or 30,
                        procedure = kind == 'eat' and 10 or nil, usedItem = kind == 'eat' and 'random' or nil },
                        simTime)
                    return true
                end
            end
            log(name .. ': not tracked (' .. tostring(next(tracked)) .. ')')
            return false
        end,
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
                        log(('  %s %s flags=%s schedule=%s conditions=%s'):format(pkg.editorId, pkg.typeName,
                            tostring(flagsAllow(npc, pkg, states[id])), tostring(scheduleMatches(pkg.schedule, t)),
                            tostring(conditionsPass(pkg, npc))))
                    end
                    local s = states[id]
                    log('  running: ' .. tostring(s and s.package and s.package.editorId)
                        .. (s and s.complete and ' (finished)' or '') .. ', phase '
                        .. tostring(s and s.phase) .. ', move ' .. ai.status(npc) .. ', furniture '
                        .. tostring(s and s.furn and s.furn.phase) .. '/' .. ai.useStatus(npc))
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
        onSave = function()
            local forced = {}
            for id, pkg in pairs(scriptPackages) do forced[id] = pkg.id end
            return { scriptPackages = forced, ranOn = ranOn }
        end,
        onLoad = function(data)
            if data == nil then return end
            ranOn = data.ranOn or {}
            for id, packageId in pairs(data.scriptPackages or {}) do
                scriptPackages[id] = ai.getPackage(packageId)
            end
        end,
        onUpdate = function(dt)
            install()
            simTime = simTime + dt
            if simTime < nextTick then return end
            nextTick = simTime + TICK_EVERY
            for id, npc in pairs(tracked) do
                if not npc:isValid() or not ai.isInScene(npc) or not npc.enabled
                    or (combat and combat.isDead(npc)) then
                    tracked[id] = nil
                    if states[id] ~= nil then furniture.release(states[id]) end
                    states[id] = nil
                    publish(id, npc, nil)
                elseif I.FNVCombat and I.FNVCombat.isInCombat and I.FNVCombat.isInCombat(npc) then
                    -- fighting (scripts/omw/fnvcombat); the package is picked again afterwards
                    if states[id] ~= nil then
                        if furniture.inUse(states[id]) then ai.stop(npc) end
                        furniture.release(states[id])
                    end
                    states[id] = nil
                    publish(id, npc, nil)
                else
                    local s = states[id]
                    if s == nil then
                        -- spread the package picks over time
                        s = { nextEvaluation = simTime + math.random() * EVALUATE_EVERY }
                        states[id] = s
                    end
                    -- in conversation with the player the package waits (the world keeps
                    -- running while talking), and picks up where it was afterwards
                    local talking = I.FNVDialogue and I.FNVDialogue.isTalkingTo and I.FNVDialogue.isTalkingTo(npc)
                    if not talking and simTime >= s.nextEvaluation then
                        s.nextEvaluation = simTime + EVALUATE_EVERY
                        evaluate(npc, s)
                    end
                    if not talking then tick(npc, s) end
                    publish(id, npc, s)
                end
            end
        end,
    },
}
