-- FO3/FNV AI packages for ESM4 NPCs and creatures.
--
-- Every few seconds each actor in the active cells picks its package the way
-- the original engine does: the first package of its list (highest priority
-- first) whose schedule covers the current game time and whose conditions
-- pass. The package then decides where the actor walks; the engine walks it
-- there along the cell's navmesh (core.obscript.ai).
--
-- Supported: Travel, Sandbox (wander, sit on chairs, lean, use idle markers,
-- with durations from the actor's Energy), Wander, Sleep (lie in a free bed),
-- Eat (sit down and eat), Guard, Ambush and Use Item At (walk to the location
-- and stay there), Dialogue (walk there, then talk to the player once near),
-- Escort (lead the target there), Follow and Accompany (keep near the
-- target), Patrol (walk the chain of linked references from the package
-- location, idling at idle markers), Find (go there and pick up the target
-- item), Use Weapon (go there and fire at the target as the package data
-- says) and Flee Not Combat (run away from the target). Moving to another
-- cell uses a door that leads there. Furniture and idle markers are handled
-- in furniture.lua, the animations come from the idle tree (idles.lua).
--
-- Packages that end: Travel, Find and Use Item At once the actor is there
-- (a Travel to a piece of furniture ends with the actor sitting or lying on
-- it), Escort once there with the target, Dialogue once the conversation
-- is over, a Patrol that is not repeatable at the end of its chain, Use
-- Weapon once its bursts are fired, Flee Not Combat once far enough. The
-- package's OnEnd script runs then and the package is picked again: the
-- original picker has no "done" check, so a package that still passes stays
-- current (the actor stays where it went) until its conditions send it on to
-- another one. OnBegin runs when a package starts, OnChange when it is
-- replaced before it ended. A script package (AddScriptPackage) is dropped
-- once it ends. Once per day packages run at most once a game day.
--
-- Combat (scripts/omw/fnvcombat) runs over the package like the original's
-- runtime Combat package: the scheduled package waits and goes on where it
-- was once the fight is over. What each actor is doing (package, patrol
-- point, seat or bed, timers) is saved with the game, and an actor that was
-- out of the player's reach keeps going in game time: when it comes back
-- into the scene it is found as far along as it could have walked, or
-- already seated or asleep at its package's place.
--
-- From the console (luag): I.FNVAI.debug('DocMitchell') prints the actor's
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
local stats = core.obscript.stats
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

local EVALUATE_EVERY = 2.0 -- seconds between package picks
local TICK_EVERY = 0.25 -- seconds between behaviour updates

local function log(msg)
    print('[fnvai] ' .. msg)
end

-- ---------------------------------------------------------------- per-actor random

-- Each actor draws from its own seeded sequence, saved with the game, so a run repeats (tests, and the same
-- result on every machine in multiplayer). Park-Miller minimal standard generator.
local function seedOf(id)
    local h = 5381
    id = tostring(id)
    for i = 1, #id do
        h = (h * 33 + id:byte(i)) % 2147483647
    end
    return math.max(h, 1)
end

-- Like math.random: rand(s) in [0, 1), rand(s, n) in 1..n, rand(s, m, n) in m..n.
local function rand(s, m, n)
    s.seed = (s.seed * 16807) % 2147483647
    local r = (s.seed - 1) / 2147483646
    if m == nil then return r end
    if n == nil then return math.floor(r * m) + 1 end
    return m + math.floor(r * (n - m + 1))
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

local warnedObjectType = {}

-- Where a package wants the actor: { cell =, position = (nil: anywhere in the cell), yaw =, radius =, ref = }.
-- index 1 is the package location (PLDT), 2 the second one (PLD2) of Patrol and Escort packages.
local function resolveLocation(npc, pkg, s, index)
    local loc = pkg.locations[index or 1]
    if loc == nil then
        if index ~= nil and index > 1 then return nil end
        return { cell = npc.cell, position = s.anchor, radius = 0 }
    end
    local radius = loc.radius or 0
    local function near(ref)
        return { cell = ref.cell, position = ref.position, yaw = ref.rotation:getYaw(), radius = radius, ref = ref }
    end
    if loc.type == L.NearReference then
        local ref = isPlayerRef(loc.id) and player() or getObject(loc.id)
        if ref == nil then return nil end
        return near(ref)
    elseif loc.type == L.InCell then
        local cell = getCell(loc.id)
        if cell == nil then return nil end
        return { cell = cell, radius = radius }
    elseif loc.type == L.NearEditorLocation then
        return { cell = npc.cell, position = npc.startingPosition, yaw = npc.startingRotation:getYaw(),
            radius = radius }
    elseif loc.type == L.NearLinkedReference then
        -- the actor's own linked reference (XLKR)
        local linked = core.obscript.getLinkedRef and core.obscript.getLinkedRef(npc)
        local ref = linked and getObject(linked)
        if ref ~= nil then return near(ref) end
    elseif loc.type == L.AtPackageLocation and (index or 1) > 1 then
        return resolveLocation(npc, pkg, s, 1)
    elseif loc.type == L.ObjectId then
        local best, bestDist = nil, math.huge
        for _, obj in ipairs(npc.cell:getAll()) do
            if obj.recordId == loc.id then
                local d = (obj.position - npc.position):length()
                if d < bestDist then best, bestDist = obj, d end
            end
        end
        if best ~= nil then return near(best) end
    elseif loc.type == L.ObjectType and not warnedObjectType[pkg.id] then
        warnedObjectType[pkg.id] = true
        log(('%s: object type %d locations are not supported yet, staying near'):format(pkg.editorId,
            loc.objectType or -1))
    end
    -- near the current location (also the fallback when a reference is missing)
    return { cell = npc.cell, position = s.anchor, radius = radius }
end

-- ---------------------------------------------------------------- settings

local function gmstFloat(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or default
end

local function isCreature(obj)
    return types.ESM4Creature ~= nil and types.ESM4Creature.objectIsInstance(obj)
end

local function isAIActor(obj)
    return types.ESM4NPC.objectIsInstance(obj) or isCreature(obj)
end

local function editorIdOf(npc)
    local actor = dlg and dlg.getActor and dlg.getActor(npc)
    return actor and actor.editorId or npc.recordId
end

-- ---------------------------------------------------------------- behaviour

local states = {} -- npc id -> state
local tracked = {} -- npc id -> npc
local simTime = 0

-- Head tracking outside conversations: an NPC near the player turns its head to
-- them (FalloutNV.exe: fAIMaxHeadTrackDistance 400; the choice is looked at again
-- every fUpdateDelaySecondsMin..Max:HeadTracking, 1 to 1.5 s). The head turns no
-- further than a neck allows and gives up on someone behind (ESM4NpcAnimation).
local function headTrack(npc, s, now)
    if not ai.lookAt or s.creature or now < (s.nextLook or 0) then return end
    s.nextLook = now + 1 + rand(s) * 0.5
    local p = player()
    local want = false
    if p ~= nil and (sameCell(npc.cell, p.cell) or (npc.cell.isExterior and p.cell.isExterior)) then
        want = (p.position - npc.position):length() <= gmstFloat('fAIMaxHeadTrackDistance', 400)
    end
    if want ~= (s.looking or false) then
        s.looking = want
        ai.lookAt(npc, want and p or nil)
    end
end

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

-- ---------------------------------------------------------------- moving between cells

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

-- Some position inside the cell to appear at when the actor is moved there without walking.
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
        moveTo(npc, s, door.position, { tolerance = 64, run = s.run })
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
    if best == nil then return false end
    local entrance = types.ESM4Door.destPosition(best)
    if s.door ~= best.id then
        s.door = best.id
        moveTo(npc, s, entrance, { tolerance = 64, run = s.run })
        return true
    end
    local status = moveStatus(npc, s)
    if status == 'arrived' or status == 'nopath' or nearlyAt(npc, entrance, 128) then
        local position, yaw = arrivalInside(cell, best)
        teleport(npc, cell, position, yaw)
        s.door = nil
        s.phase = nil
    end
    return true
end

-- Walks the actor towards dest's cell; true once it is there. An actor in the scene always walks, through
-- doors, as the original's high process does: only when no door leads the way is it moved there.
local function reachCell(npc, s, dest)
    if dest.cell == nil or sameCell(npc.cell, dest.cell) then
        s.door = nil
        return true
    end
    if npc.cell.isExterior and dest.cell.isExterior then
        return true -- one navmesh network across exterior cells
    end
    -- go the way the player would: through a door to the place, or outside first
    local door = findDoorTo(npc.cell, dest.cell)
    if door == nil and not npc.cell.isExterior then
        door = findDoorOutside(npc.cell)
    end
    if door ~= nil then
        useDoor(npc, s, door)
        return false
    elseif npc.cell.isExterior and enterFromOutside(npc, s, dest.cell) then
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

-- ---------------------------------------------------------------- sandbox durations

-- How long a sandboxing actor keeps at one activity (sandbox duration, FalloutNV.exe 0x6435c0):
-- fSandboxDurationBase x the activity's fSandboxDurationMult*, scaled by the actor's Energy, give or take
-- fSandboxDurationRangeMult. The ESM values are what the game uses.
local SANDBOX_ACTIVITY = {
    furniture = { mult = 'fSandboxDurationMultFurniture', default = 3.0,
        energy = 'fSandboxEnergyMultFurniture' },
    idleMarker = { mult = 'fSandboxDurationMultIdleMarker', default = 1.5,
        energy = 'fSandboxEnergyMultIdleMarker' },
    eating = { mult = 'fSandboxDurationMultEating', default = 0.75, energy = 'fSandboxEnergyMultEating' },
    wandering = { mult = 'fSandboxDurationMultWandering', default = 0.5,
        energy = 'fSandboxEnergyMultWandering' },
}

local function energyOf(npc)
    if stats == nil then return 50 end
    local ok, value = pcall(stats.get, npc, 'Energy')
    return ok and value or 50
end

local function sandboxDuration(npc, s, activity)
    local a = SANDBOX_ACTIVITY[activity]
    local duration = gmstFloat('fSandboxDurationBase', 10) * gmstFloat(a.mult, a.default)
    -- Energy 0..100: a low-energy actor lingers longer, an energetic one moves on sooner
    local energyMult = gmstFloat(a.energy, 0)
    duration = duration * math.max(1 + (50 - energyOf(npc)) / 100 * energyMult, 0.1)
    local range = gmstFloat('fSandboxDurationRangeMult', 0.25)
    return duration * (1 + (rand(s) * 2 - 1) * range)
end

-- ---------------------------------------------------------------- walking to the package location

-- Travel-like: walk to the place and stay. A Travel to a piece of furniture ends with the actor using it (Doc
-- Mitchell's Travel to his chair is how he sits down). arrived(npc, s) is called once the actor is there.
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
            -- no duration: the actor stays on it until the package changes
            furniture.begin(npc, s, seat, { sleep = seat.sleep, package = pkg.type, run = s.run,
                resume = s.resumeSeated }, simTime)
            s.resumeSeated = nil
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
    local sandbox = pkg ~= nil and pkg.type == T.Sandbox
    if s.phase == nil or (s.phase == 'wait' and simTime >= s.waitUntil) then
        local flags = sandbox and pkg.specificFlags or 0
        local roll = rand(s)
        if sandbox and not s.creature and not hasFlag(flags, SANDBOX_NO_FURNITURE) and roll < 0.45 then
            local target = furniture.findFurniture(npc, center, radius, false)
            if target ~= nil and not (s.avoid and s.avoid[target.object.id]) then
                furniture.begin(npc, s, target, { package = pkg.type,
                    duration = sandboxDuration(npc, s, 'furniture') }, simTime)
                s.phase = 'furniture'
                return
            end
        end
        if sandbox and not s.creature and not hasFlag(flags, SANDBOX_NO_IDLE_MARKERS) and roll < 0.75 then
            local target = furniture.findIdleMarker(npc, center, radius)
            if target ~= nil and not (s.avoid and s.avoid[target.object.id]) then
                local duration = target.record.idleTimer
                if duration <= 0 then duration = sandboxDuration(npc, s, 'idleMarker') end
                furniture.begin(npc, s, target, { package = pkg.type, duration = duration }, simTime)
                s.phase = 'furniture'
                return
            end
        end
        local linger = sandbox and sandboxDuration(npc, s, 'wandering') or (6 + rand(s) * 14)
        if hasFlag(flags, SANDBOX_NO_WANDERING) then
            s.phase, s.waitUntil = 'wait', simTime + linger
            return
        end
        local point = ai.randomPoint(npc, center, radius)
        if point == nil then
            s.phase, s.waitUntil = 'wait', simTime + 10
            return
        end
        s.linger = linger
        moveTo(npc, s, point, {})
    elseif s.phase == 'go' then
        local status = moveStatus(npc, s)
        if status ~= 'moving' then
            s.phase = 'wait'
            s.waitUntil = simTime + (s.linger or (6 + rand(s) * 14))
            s.linger = nil
            if rand(s) < 0.5 then
                ai.face(npc, (rand(s) * 2 - 1) * math.pi)
            end
        end
    end
end

-- The package's target (PTDT): a reference, the nearest object of a base record, or the actor's linked
-- reference. Object types are not resolved yet.
local function targetRef(pkg, npc, index)
    local target = pkg.targets[index or 1]
    if target == nil then return nil end
    if target.type == 0 then
        if isPlayerRef(target.id) then return player() end
        return getObject(target.id)
    elseif target.type == 1 and npc ~= nil then
        if isPlayerRef(target.id) then return player() end
        local best, bestDist = nil, math.huge
        for _, obj in ipairs(npc.cell:getAll()) do
            if obj.recordId == target.id and obj.enabled then
                local d = (obj.position - npc.position):length()
                if d < bestDist then best, bestDist = obj, d end
            end
        end
        return best
    elseif target.type == 3 and npc ~= nil then
        local linked = core.obscript.getLinkedRef and core.obscript.getLinkedRef(npc)
        return linked and getObject(linked)
    end
    if isPlayerRef(target.id) then return player() end
    return getObject(target.id)
end

local function follow(npc, s, pkg)
    local target = pkg.targets[1]
    local ref = targetRef(pkg, npc)
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
            furniture.begin(npc, s, bed, { sleep = true, package = T.Sleep, resume = s.resumeSeated }, simTime)
            s.resumeSeated = nil
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
            furniture.begin(npc, s, chair, { procedure = 10, usedItem = 'random', package = T.Eat,
                resume = s.resumeSeated }, simTime)
            s.resumeSeated = nil
            s.phase = 'furniture'
            return
        end
        s.noFurniture = true
    end
    roam(npc, s, { position = dest.position, radius = 512 })
end

-- ---------------------------------------------------------------- package events and ending

local idles = require('scripts.omw.fnvai.idles')

local function playIdleRecord(npc, idleId, packageType)
    local idle = idles.get(idleId)
    local leaf = idle and idles.pick(idle, npc, idles.furnitureOverrides({ package = packageType }))
    if leaf ~= nil then
        ai.playIdle(npc, idles.modelPath(leaf))
        return true
    end
    return false
end

-- Runs a package event (onBegin, onEnd, onChange): plays its idle and runs its result script on the actor.
local function runEvent(npc, pkg, name)
    local event = pkg[name]
    if event == nil then return end
    if event.idle ~= '' then
        playIdleRecord(npc, event.idle, pkg.type)
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

-- What the actor does once at a package's location.
local function arrived(npc, s)
    local pkg = s.package
    if pkg == nil then return end
    if pkg.type == T.Travel or pkg.type == T.UseItemAt then
        completePackage(npc, s, 'there')
    elseif pkg.type == T.Find then
        s.phase = 'acquire'
    elseif pkg.type == T.UseWeapon then
        s.phase = 'shoot'
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
    local ref = targetRef(pkg, npc)
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
local function escort(npc, s, dest, pkg)
    local ref = targetRef(pkg, npc)
    if dest.position == nil or ref == nil then
        follow(npc, s, pkg)
        return
    end
    -- PKE2, else fAIEscortWaitDistanceInterior (doubled outdoors)
    local wait = pkg.escortDistance and pkg.escortDistance > 0 and pkg.escortDistance
        or gmstFloat('fAIEscortWaitDistanceInterior', 512) * (npc.cell.isExterior and 2 or 1)
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

-- ---------------------------------------------------------------- patrol

-- Patrol: the actor walks the chain of linked references (XLKR) that starts at the package location. At an
-- idle marker it plays the marker's idles for the marker's idle timer; at any other point it waits the
-- package's idle timer (IDLT), playing the package's idles (IDLA), or goes straight on. At the end of the chain
-- (no linked reference, or back at the start) a repeatable patrol (PKPT) starts over from the first point;
-- one that is not ends there.
local function referenceIdOf(obj)
    local ok, id = pcall(function() return dlg.getReferenceId(obj) end)
    return ok and id or nil
end

local function patrolStart(npc, s, dest)
    local first = dest.ref and referenceIdOf(dest.ref)
    s.patrol = { first = first, current = first, laps = 0 }
end

-- The point after the current one; nil at the end of the chain.
local function patrolNext(p)
    local current = getObject(p.current)
    local linked = current and core.obscript.getLinkedRef and core.obscript.getLinkedRef(current)
    if linked == nil or linked == '' then return nil end
    return linked
end

local function patrolAdvance(npc, s, pkg)
    local p = s.patrol
    local nextId = patrolNext(p)
    if nextId == nil or nextId == p.first then
        p.laps = p.laps + 1
        if not pkg.patrolRepeatable then
            completePackage(npc, s, 'patrolled')
            s.phase = 'stay'
            return
        end
        nextId = p.first
    end
    p.current = nextId
    s.phase = nil
end

local function patrolIdle(npc, s, pkg)
    local list = pkg.idles and pkg.idles.list or {}
    if #list == 0 or ai.isIdlePlaying(npc) then return end
    local p = s.patrol
    local index
    if hasFlag(pkg.idles.flags, 1) then -- run in sequence
        index = (p.idleIndex or 0) % #list + 1
    else
        index = rand(s, #list)
    end
    if hasFlag(pkg.idles.flags, 4) and p.idlePlayed then return end -- do once
    p.idleIndex = index
    p.idlePlayed = true
    playIdleRecord(npc, list[index], pkg.type)
end

local function patrol(npc, s, dest, pkg)
    if s.patrol == nil then patrolStart(npc, s, dest) end
    local p = s.patrol
    local point = getObject(p.current)
    if point == nil then
        -- no chain to walk: stand at the location like a Guard
        goAndStay(npc, s, dest, pkg, function() end)
        return
    end
    if s.phase == nil then
        p.idlePlayed = nil
        local marker = not s.creature and types.ESM4IdleMarker ~= nil
            and types.ESM4IdleMarker.objectIsInstance(point) and point or nil
        if marker ~= nil then
            local record = types.ESM4IdleMarker.record(marker)
            if furniture.hasNpcIdles(record) and not (s.avoid and s.avoid[marker.id]) then
                local timer = record.idleTimer > 0 and record.idleTimer or (pkg.idles and pkg.idles.timer) or 0
                furniture.begin(npc, s, { object = marker, position = marker.position,
                    yaw = marker.rotation:getYaw(), record = record },
                    { package = pkg.type, duration = math.max(timer, 1), run = s.run }, simTime)
                s.phase = 'furniture'
                s.afterFurniture = 'patrol'
                return
            end
        end
        moveTo(npc, s, point.position, { run = s.run, tolerance = 48 })
        s.phase = 'go'
    elseif s.phase == 'go' then
        local status = moveStatus(npc, s)
        if status == 'arrived' or status == 'nopath' then
            local timer = pkg.idles and pkg.idles.timer or 0
            if timer > 0 then
                s.phase = 'wait'
                s.waitUntil = simTime + timer
                ai.face(npc, point.rotation:getYaw())
            else
                patrolAdvance(npc, s, pkg)
            end
        end
    elseif s.phase == 'wait' then
        if simTime >= s.waitUntil then
            patrolAdvance(npc, s, pkg)
        else
            patrolIdle(npc, s, pkg)
        end
    end
end

-- ---------------------------------------------------------------- find

-- Find: TRAVEL to the location, then ACQUIRE the target: walk to the nearest such item within the location's
-- radius and take it.
local function acquire(npc, s, dest, pkg)
    if s.phase == 'acquire' then
        local item = targetRef(pkg, npc)
        if item == nil or not item.enabled or (dest.position and dest.radius > 0
            and (item.position - dest.position):length() > math.max(dest.radius, 64)) then
            completePackage(npc, s, 'nothing to find')
            s.phase = 'stay'
            return
        end
        s.item = item
        moveTo(npc, s, item.position, { run = s.run, tolerance = 64, direct = true })
        s.phase = 'fetch'
    elseif s.phase == 'fetch' then
        local item = s.item
        local status = moveStatus(npc, s)
        if item == nil or not item:isValid() or not item.enabled then
            completePackage(npc, s, 'item gone')
            s.phase = 'stay'
        elseif status ~= 'moving' or nearlyAt(npc, item.position, 96) then
            if status == 'moving' then ai.stop(npc) end
            local ok = pcall(function() item:moveInto(types.Actor.inventory(npc)) end)
            log(('%s picks up %s%s'):format(npc.recordId, item.recordId, ok and '' or ' (could not take it)'))
            s.item = nil
            completePackage(npc, s, 'found')
            s.phase = 'stay'
        end
    else
        goAndStay(npc, s, dest, pkg, arrived)
    end
end

-- ---------------------------------------------------------------- use weapon

-- Use Weapon: TRAVEL to the location, then fire at the target the way the package data (PKW3) says: volleys of
-- shotsMin..shotsMax shots with pauseMin..pauseMax seconds between them, or one long burst (auto fire); for
-- the number of bursts, or for as long as the package runs (repeat fire).
local function useWeapon(npc, s, dest, pkg)
    if s.phase ~= 'shoot' then
        goAndStay(npc, s, dest, pkg, arrived)
        return
    end
    local target = targetRef(pkg, npc)
    local data = pkg.useWeapon or {}
    if target == nil or combat == nil then
        completePackage(npc, s, 'no target')
        s.phase = 'stay'
        return
    end
    local u = s.useWeapon
    if u == nil then
        local gun = combat.getActorWeapon(npc)
        if gun == nil or not gun.isGun then
            completePackage(npc, s, 'no gun')
            s.phase = 'stay'
            return
        end
        u = { gun = gun, clip = math.max(1, gun.clipSize), volleys = 0, shots = 0, next = simTime + 0.5 }
        s.useWeapon = u
        combat.drawWeapon(npc, true)
    end
    local d = target.position - npc.position
    ai.face(npc, math.atan2(d.x, d.y))
    if simTime < u.next or combat.isActing(npc) then return end
    if u.gun.clipSize > 0 and u.clip <= 0 then
        combat.reload(npc)
        u.clip = u.gun.clipSize
        u.next = simTime + math.max(u.gun.reloadTime or 1, 0.5)
        return
    end
    if data.holdFireWhenBlocked and not combat.hasLineOfFire(npc, target) then
        u.next = simTime + 0.5
        return
    end
    if u.shots <= 0 then
        -- a new volley
        if not data.repeatFire and u.volleys >= math.max(data.bursts or 1, 1) then
            combat.drawWeapon(npc, false)
            s.useWeapon = nil
            completePackage(npc, s, 'fired')
            s.phase = 'stay'
            return
        end
        u.volleys = u.volleys + 1
        if data.volley then
            u.shots = rand(s, math.max(data.shotsMin or 1, 1), math.max(data.shotsMax or 1, data.shotsMin or 1, 1))
        else
            u.shots = math.max(u.gun.clipSize, 1) -- auto fire: empty the clip
        end
    end
    combat.shoot(npc, target)
    u.clip = u.clip - math.max(1, u.gun.ammoUse or 1)
    u.shots = u.shots - 1
    local rate = u.gun.shotsPerSecond or 0
    u.next = simTime + (rate > 0 and 1 / rate or 1)
    if u.shots <= 0 then
        local pauseMin = data.pauseMin or 1
        local pauseMax = math.max(data.pauseMax or pauseMin, pauseMin)
        u.next = u.next + pauseMin + rand(s) * (pauseMax - pauseMin)
    end
end

-- ---------------------------------------------------------------- flee not combat

-- Flee Not Combat: run from the target (or from the package location when it has none) until
-- fFleeDistanceExterior / fFleeDistanceInterior away, then the package is done.
local function fleeNotCombat(npc, s, dest, pkg)
    local from = targetRef(pkg, npc)
    local fromPosition = from and sameCell(from.cell, npc.cell) and from.position or dest.position or s.anchor
    local safe = npc.cell.isExterior and gmstFloat('fFleeDistanceExterior', 5000)
        or gmstFloat('fFleeDistanceInterior', 3000)
    local offset = npc.position - fromPosition
    local distance = util.vector2(offset.x, offset.y):length()
    if distance >= safe then
        if s.phase == 'go' then ai.stop(npc) end
        completePackage(npc, s, 'fled')
        s.phase = 'stay'
        return
    end
    if s.phase ~= 'go' or moveStatus(npc, s) ~= 'moving' or simTime - s.goSince > 3 then
        local away = distance > 1 and util.vector3(offset.x, offset.y, 0):normalize()
            or util.vector3(math.sin(rand(s) * 2 * math.pi), math.cos(rand(s) * 2 * math.pi), 0)
        local goal = ai.randomPoint(npc, npc.position + away * math.min(safe - distance + 256, 2048), 512)
        moveTo(npc, s, goal or (npc.position + away * 1024), { run = true, direct = true, tolerance = 64 })
    end
end

-- ---------------------------------------------------------------- behaviour, continued

local startPackage

-- Runs the furniture use; true while the actor is busy with it.
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
        if s.afterFurniture == 'patrol' and s.package ~= nil then
            s.afterFurniture = nil
            patrolAdvance(npc, s, s.package)
            return false
        end
        if s.useAtEnd then
            -- could not use the furniture the package goes to: stand there instead
            s.useAtEnd = nil
            s.noFurniture = true
            s.phase = nil
            return false
        end
        s.phase = 'wait'
        s.waitUntil = simTime + 2 + rand(s) * 4
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
    if pkg.type == T.FleeNotCombat then
        fleeNotCombat(npc, s, dest, pkg)
        return
    end
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
    elseif pkg.type == T.Sleep and not s.creature then
        sleep(npc, s, dest)
    elseif pkg.type == T.Eat and not s.creature then
        eat(npc, s, dest)
    elseif pkg.type == T.Patrol then
        patrol(npc, s, dest, pkg)
    elseif pkg.type == T.Find then
        acquire(npc, s, dest, pkg)
    elseif pkg.type == T.UseWeapon then
        useWeapon(npc, s, dest, pkg)
    elseif pkg.type == T.Dialogue and (s.phase == 'converse' or s.phase == 'talking') then
        converse(npc, s, pkg)
    else
        goAndStay(npc, s, dest, pkg, arrived)
    end
end

-- Leaves what the old package left behind: a drawn weapon of Use Weapon.
local function cleanUp(npc, s)
    if s.useWeapon ~= nil then
        if combat ~= nil then combat.drawWeapon(npc, false) end
        s.useWeapon = nil
    end
    s.item = nil
    s.afterFurniture = nil
end

startPackage = function(npc, s, pkg)
    cleanUp(npc, s)
    s.package = pkg
    s.phase = nil
    s.anchor = npc.position
    s.anchorCell = npc.cell.id
    s.run = pkg ~= nil and hasFlag(pkg.flags, FLAG_ALWAYS_RUN)
    s.noFurniture = s.creature or nil
    s.useAtEnd = nil
    s.complete = false
    s.noReturn = nil
    s.patrol = nil
    s.resumeSeated = nil
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

-- Switches package; an actor using furniture gets up first and starts the new package once standing.
local function start(npc, s, pkg)
    local old = s.package
    if old ~= nil and not s.complete then
        runEvent(npc, old, 'onChange')
    end
    if furniture.inUse(s) then
        s.package = pkg
        s.complete = false
        s.useAtEnd = nil
        s.afterFurniture = nil
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
    elseif pkg ~= nil and s.dest ~= nil and s.dest.ref ~= nil and not s.complete and pkg.type ~= T.Patrol then
        -- a moving target, such as a reference that walks itself
        s.dest = resolveLocation(npc, pkg, s)
    end
end

-- ---------------------------------------------------------------- saved games and off-screen actors

-- Package lookup by form id among the actor's own packages and the script package.
local function findPackage(npc, packageId)
    if packageId == nil or packageId == '' then return nil end
    local forced = scriptPackages[npc.id]
    if forced ~= nil and forced.id == packageId then return forced end
    for _, pkg in ipairs(getPackages(npc)) do
        if pkg.id == packageId then return pkg end
    end
    return ai.getPackage(packageId)
end

local function saveState(s)
    if s.package == nil then return { seed = s.seed } end
    return {
        package = s.package.id,
        complete = s.complete,
        anchor = s.anchor,
        anchorCell = s.anchorCell,
        noReturn = s.noReturn,
        patrol = s.patrol and { first = s.patrol.first, current = s.patrol.current, laps = s.patrol.laps } or nil,
        furniture = furniture.save(s, simTime),
        useAtEnd = s.useAtEnd,
        seed = s.seed,
    }
end

-- Takes a saved state up again: same package (no OnBegin), same patrol point, seated where the actor sat.
local function restoreState(npc, s, saved)
    s.seed = saved.seed or s.seed
    local pkg = findPackage(npc, saved.package)
    if pkg == nil then return end
    s.package = pkg
    s.complete = saved.complete == true
    s.anchor = saved.anchor or npc.position
    s.anchorCell = saved.anchorCell or npc.cell.id
    s.noReturn = saved.noReturn
    s.run = hasFlag(pkg.flags, FLAG_ALWAYS_RUN)
    s.noFurniture = s.creature or nil
    s.patrol = saved.patrol
    s.dest = resolveLocation(npc, pkg, s)
    s.phase = nil
    if saved.furniture ~= nil and furniture.restore(npc, s, saved.furniture, simTime, getObject) then
        s.phase = 'furniture'
        s.useAtEnd = saved.useAtEnd
        if saved.patrol ~= nil and pkg.type == T.Patrol then s.afterFurniture = 'patrol' end
    elseif s.complete then
        s.phase = 'stay'
    end
end

local loadedStates = {} -- npc id -> saved state, until the actor is in the scene again
local offscreen = {} -- npc id -> { npc, since = game time it left the scene, budget = units it could walk }

local function walkSpeed(npc)
    local ok, speed = pcall(function() return ai.getWalkSpeed and ai.getWalkSpeed(npc) end)
    if ok and type(speed) == 'number' and speed > 0 then return speed end
    return gmstFloat('fMoveBaseSpeed', 77)
end

-- How far an actor away from the scene could have walked since it left: speed x (3600 / timescale) x game
-- hours, the distance budget of the original's low-process TRAVEL (Oblivion 0x645280, FalloutNV 0x90ad40).
local function walkBudget(npc, gameSeconds)
    local scale = core.getGameTimeScale and core.getGameTimeScale() or 30
    if scale <= 0 then scale = 30 end
    return walkSpeed(npc) * gameSeconds / scale
end

-- The actor comes back into the scene: it has gone on with its package in the meantime. A package place in
-- this cell it could have walked to is where it is found, seated or asleep if it went to a seat or bed.
local function catchUp(npc, s, away)
    local gameSeconds = core.getGameTime() - away.since
    if gameSeconds < 60 then return end
    evaluate(npc, s)
    local pkg, dest = s.package, s.dest
    if pkg == nil or dest == nil or dest.position == nil or not sameCell(dest.cell, npc.cell) then return end
    if pkg.type == T.Follow or pkg.type == T.Accompany or pkg.type == T.FleeNotCombat
        or pkg.type == T.Dialogue or pkg.type == T.Escort then
        return
    end
    local distance = (dest.position - npc.position):length()
    if distance <= math.max(dest.radius or 0, 64) or walkBudget(npc, gameSeconds) < distance then return end
    log(('%s went on with %s while away'):format(npc.recordId, pkg.editorId))
    teleport(npc, dest.cell, dest.position, dest.yaw)
    -- already seated or in bed if that is what it went for
    if not s.creature and (pkg.type == T.Sleep or pkg.type == T.Eat
        or (pkg.type == T.Travel and dest.ref ~= nil and furniture.markerOn(npc, dest.ref) ~= nil)) then
        s.resumeSeated = true
    end
    s.phase = nil
end

-- Actors out of the scene in another cell than their package place: moved there once they could have walked
-- it (the original's middle-low and low process lists, updated every 0.3 and 1 game hours).
local LOW_PROCESS_HOURS = 0.3
local nextLowProcess = 0

local function lowProcess()
    local gameNow = core.getGameTime()
    for id, away in pairs(offscreen) do
        local npc = away.npc
        if not npc:isValid() or (combat and combat.isDead(npc)) then
            offscreen[id] = nil
        elseif gameNow - (away.checked or away.since) >= LOW_PROCESS_HOURS * 3600 then
            away.checked = gameNow
            local ok, err = pcall(function()
                local s = away.state or { seed = seedOf(id), anchor = npc.position, anchorCell = npc.cell.id }
                away.state = s
                local pkg = pickPackage(npc, s)
                if pkg == nil or pkg.type == T.Follow or pkg.type == T.Accompany then return end
                local dest = resolveLocation(npc, pkg, s)
                if dest == nil or dest.cell == nil or sameCell(dest.cell, npc.cell) then return end
                -- straight-line distance in one worldspace, else a walk to a door and from the other one
                local distance = 4096
                if npc.cell.isExterior and dest.cell.isExterior and dest.position ~= nil then
                    distance = (dest.position - npc.position):length()
                end
                if walkBudget(npc, gameNow - away.since) < distance then return end
                local position, yaw = entryPoint(dest.cell, dest)
                if position == nil then return end
                log(('%s walked to %s off-screen (%s)'):format(npc.recordId, tostring(dest.cell), pkg.editorId))
                npc:teleport(dest.cell, position, yaw and util.transform.rotateZ(yaw) or nil)
                away.since = gameNow
            end)
            if not ok then
                log(('%s: off-screen update failed: %s'):format(tostring(npc.recordId), tostring(err)))
                offscreen[id] = nil
            end
        end
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

local function newState(npc)
    local s = {
        -- spread the package picks over time
        nextEvaluation = simTime + (seedOf(npc.id) % 1000) / 1000 * EVALUATE_EVERY,
        seed = seedOf(npc.id),
        creature = isCreature(npc),
    }
    local saved = loadedStates[npc.id]
    if saved ~= nil then
        loadedStates[npc.id] = nil
        restoreState(npc, s, saved)
        if s.package ~= nil then
            log(('%s goes on with %s (saved game)'):format(npc.recordId, s.package.editorId))
            s.nextEvaluation = simTime + EVALUATE_EVERY
        end
    end
    local away = offscreen[npc.id]
    if away ~= nil then
        offscreen[npc.id] = nil
        if saved == nil then catchUp(npc, s, away) end
    end
    return s
end

-- The actor left the scene (another cell, too far) or died.
local function drop(id, npc)
    local s = states[id]
    tracked[id] = nil
    if s ~= nil then furniture.release(s) end
    states[id] = nil
    publish(id, npc, nil)
    if npc:isValid() and not (combat and combat.isDead(npc)) and npc.enabled then
        offscreen[id] = { npc = npc, since = core.getGameTime() }
    end
end

return {
    interfaceName = 'FNVAI',
    interface = {
        version = 1,
        --- AddScriptPackage: the actor runs this package (form id) ahead of its own
        -- until RemoveScriptPackage; nil package removes it.
        setScriptPackage = function(npc, packageId)
            if npc == nil or not npc:isValid() then return end
            scriptPackages[npc.id] = packageId and ai.getPackage(packageId) or nil
            local s = states[npc.id]
            if s then s.nextEvaluation = simTime end
        end,
        --- EvaluatePackage: re-picks the actor's package at its next behaviour update.
        evaluate = function(npc)
            local s = npc and states[npc.id]
            if s then s.nextEvaluation = simTime end
        end,
        --- Makes an NPC (by editor id) use the nearest chair ('sit'), bed ('sleep') or idle marker
        -- ('idle') for duration seconds, for testing from the console: I.FNVAI.use('Trudy', 'sit').
        use = function(name, kind, duration)
            name = (name or ''):lower()
            for id, npc in pairs(tracked) do
                local editorId = editorIdOf(npc)
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
        --- Prints an actor's packages, whether each one applies now, and the running one; with no name, every
        -- actor in the scene.
        debug = function(name)
            name = (name or ''):lower()
            for id, npc in pairs(tracked) do
                local editorId = editorIdOf(npc)
                if name == '' or editorId:lower() == name then
                    local t = now()
                    log(('%s (%s) at %s, hour %d, energy %s'):format(editorId, id, tostring(npc.position), t.hour,
                        tostring(energyOf(npc))))
                    for _, pkg in ipairs(getPackages(npc)) do
                        log(('  %s %s flags=%s schedule=%s conditions=%s'):format(pkg.editorId, pkg.typeName,
                            tostring(flagsAllow(npc, pkg, states[id])), tostring(scheduleMatches(pkg.schedule, t)),
                            tostring(conditionsPass(pkg, npc))))
                    end
                    local s = states[id]
                    log('  running: ' .. tostring(s and s.package and s.package.editorId)
                        .. (s and s.complete and ' (finished)' or '') .. (s and s.suspended and ' (in combat)' or '')
                        .. ', phase ' .. tostring(s and s.phase) .. ', move ' .. ai.status(npc) .. ', furniture '
                        .. tostring(s and s.furn and s.furn.phase) .. '/' .. ai.useStatus(npc)
                        .. (s and s.patrol and (', patrol point ' .. tostring(s.patrol.current)) or ''))
                end
            end
            local count = 0
            for _ in pairs(offscreen) do count = count + 1 end
            log(('%d actors off-screen'):format(count))
        end,
    },
    engineHandlers = {
        onObjectActive = function(obj)
            if isAIActor(obj) then
                tracked[obj.id] = obj
            end
        end,
        onSave = function()
            local forced = {}
            for id, pkg in pairs(scriptPackages) do forced[id] = pkg.id end
            local saved = {}
            for id, s in pairs(states) do
                saved[id] = saveState(s)
            end
            -- actors not seen since the game was loaded keep what they had
            for id, data in pairs(loadedStates) do
                if saved[id] == nil then saved[id] = data end
            end
            local away = {}
            for id, a in pairs(offscreen) do
                away[id] = { npc = a.npc, since = a.since }
            end
            return { scriptPackages = forced, ranOn = ranOn, states = saved, offscreen = away, version = 1 }
        end,
        onLoad = function(data)
            if data == nil then return end
            ranOn = data.ranOn or {}
            for id, packageId in pairs(data.scriptPackages or {}) do
                scriptPackages[id] = ai.getPackage(packageId)
            end
            loadedStates = data.states or {}
            offscreen = {}
            for id, a in pairs(data.offscreen or {}) do
                if a.npc ~= nil and a.npc:isValid() then
                    offscreen[id] = { npc = a.npc, since = a.since or core.getGameTime() }
                end
            end
        end,
        onUpdate = function(dt)
            install()
            simTime = simTime + dt
            if simTime >= nextLowProcess then
                nextLowProcess = simTime + 5
                lowProcess()
            end
            if simTime < nextTick then return end
            nextTick = simTime + TICK_EVERY
            for id, npc in pairs(tracked) do
                if not npc:isValid() or not ai.isInScene(npc) or not npc.enabled
                    or (combat and combat.isDead(npc)) then
                    drop(id, npc)
                elseif I.FNVCombat and I.FNVCombat.isInCombat and I.FNVCombat.isInCombat(npc) then
                    -- fighting (scripts/omw/fnvcombat) runs over the package, like the original's runtime Combat
                    -- package; the package waits and goes on afterwards
                    local s = states[id]
                    if s ~= nil and not s.suspended then
                        s.suspended = true
                        if furniture.inUse(s) then ai.stop(npc) end
                        furniture.release(s)
                        if s.useWeapon ~= nil then s.useWeapon = nil end
                        s.door = nil
                    end
                    publish(id, npc, nil)
                else
                    local s = states[id]
                    if s == nil then
                        s = newState(npc)
                        states[id] = s
                    elseif s.suspended then
                        -- the fight is over: back to the package, where it was
                        s.suspended = nil
                        s.phase = nil
                        s.pending = nil
                        s.nextEvaluation = simTime
                        if s.package ~= nil then
                            log(('%s goes back to %s'):format(npc.recordId, s.package.editorId))
                        end
                    end
                    -- in conversation with the player the package waits (the world keeps
                    -- running while talking), and picks up where it was afterwards
                    local talking = I.FNVDialogue and I.FNVDialogue.isTalkingTo and I.FNVDialogue.isTalkingTo(npc)
                    if not talking and simTime >= s.nextEvaluation then
                        s.nextEvaluation = simTime + EVALUATE_EVERY
                        evaluate(npc, s)
                    end
                    if not talking then
                        tick(npc, s)
                        headTrack(npc, s, simTime)
                    else
                        -- the conversation has the head; it ends looking at no one
                        s.looking = nil
                        s.nextLook = simTime + 1
                    end
                    publish(id, npc, s)
                end
            end
        end,
    },
}
