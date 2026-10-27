-- FO3/FNV AI packages for ESM4 NPCs and creatures.
--
-- Every few seconds each actor in the active cells picks its package the way
-- the original engine does: the first package of its list (highest priority
-- first) whose schedule covers the current game time and whose conditions
-- pass. The package then decides where the actor walks; the engine walks it
-- there along the cell's navmesh (core.obscript.ai).
--
-- Supported: Travel, Sandbox (wander, sit on chairs, lean, use idle markers,
-- talk with other sandboxing NPCs, eat in the actor's meal windows and sleep in
-- its sleep window, with durations from the actor's Energy), Wander, Sleep (lie in a free bed),
-- Eat (sit down and eat), Guard, Ambush and Use Item At (walk to the location
-- and stay there), Dialogue (walk there, then talk to the player once near),
-- Escort (lead the target there), Follow and Accompany (keep near the
-- target, queued behind other followers, through doors and fast travel after
-- the player; SetPlayerTeammate companions stay put while Waiting is 1), Patrol (walk the chain of linked references from the package
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

local simTime = 0 -- seconds of simulation since the script started

local function pickPackage(npc, s)
    local forced = scriptPackages[npc.id]
    if forced then return forced end
    local t = now()
    local failed = s and s.failedUntil or {}
    for _, pkg in ipairs(getPackages(npc)) do
        if simTime >= (failed[pkg.id] or 0) and flagsAllow(npc, pkg, s) and scheduleMatches(pkg.schedule, t)
            and conditionsPass(pkg, npc) then
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

-- ---------------------------------------------------------------- sandbox

-- Sandbox activity types of the original (SandBoxActorPackageData, FalloutNV.exe 0x9f4700)
local SIT, SLEEP, EAT, WANDER, IDLE_MARKER, CONVERSATION = 0, 1, 2, 3, 4, 5
local SANDBOX_NAMES = { [SIT] = 'sits', [SLEEP] = 'sleeps', [EAT] = 'eats', [WANDER] = 'wanders',
    [IDLE_MARKER] = 'uses an idle marker', [CONVERSATION] = 'talks' }

-- How long a sandboxing actor keeps at one activity (FalloutNV.exe 0x6435c0):
-- fSandboxDurationBase x duration mult x (1 + Energy x fSandboxEnergyMult x energy mult), give or take
-- fSandboxDurationRangeMult. Energy is the actor's AIDT Energy, 0 to 100: a lively actor sits and eats for less
-- time and wanders and idles for longer. Conversations use the wandering values.
local SANDBOX_DURATION = {
    [SIT] = { 'fSandboxDurationMultFurniture', 3.0, 'fSandboxEnergyMultFurniture', -0.1 },
    [SLEEP] = { 'fSandboxDurationMultFurniture', 3.0, 'fSandboxEnergyMultFurniture', -0.1 },
    [EAT] = { 'fSandboxDurationMultEating', 0.75, 'fSandboxEnergyMultEating', -0.05 },
    [WANDER] = { 'fSandboxDurationMultWandering', 0.5, 'fSandboxEnergyMultWandering', 0.2 },
    [IDLE_MARKER] = { 'fSandboxDurationMultIdleMarker', 1.5, 'fSandboxEnergyMultIdleMarker', 0.05 },
    [CONVERSATION] = { 'fSandboxDurationMultWandering', 0.5, 'fSandboxEnergyMultWandering', 0.2 },
}

local function energyOf(npc)
    if stats == nil then return 50 end
    local ok, value = pcall(stats.get, npc, 'Energy')
    return ok and value or 50
end

local function sandboxDuration(npc, s, activity)
    local a = SANDBOX_DURATION[activity]
    local duration = gmstFloat('fSandboxDurationBase', 10) * gmstFloat(a[1], a[2])
        * (1 + energyOf(npc) * gmstFloat('fSandboxEnergyMult', 0.05) * gmstFloat(a[3], a[4]))
    local range = gmstFloat('fSandboxDurationRangeMult', 0.25)
    return math.max(duration, 0) * (1 + (rand(s) * 2 - 1) * range)
end

-- Meal and sleep windows (FalloutNV.exe 0x9f3e80). Each sandboxing actor keeps one upcoming window at a time:
-- sleep (starting fSandboxSleepStartMin..Max, 19:00 to 01:00, for fSandboxSleepDurationMin..Max hours), breakfast,
-- lunch or dinner (starting fSandbox<Meal>Min..Max, for fSandboxMealDurationMin..Max hours). When its window is
-- over, all four are rolled again and the one in progress, else the soonest, is kept; the one that just ended is
-- skipped unless its new roll falls on the next day. While the window is open and its bed or seat is found, the
-- sandbox favours that activity (weight 10); otherwise it sandboxes as usual and never sleeps.
local WINDOW_WEIGHT = 10
local WINDOWS = {
    { kind = SLEEP, start = { 'fSandboxSleepStartMin', 19, 'fSandboxSleepStartMax', 1 },
        duration = { 'fSandboxSleepDurationMin', 6, 'fSandboxSleepDurationMax', 10 } },
    { kind = EAT, start = { 'fSandboxBreakfastMin', 6, 'fSandboxBreakfastMax', 9 },
        duration = { 'fSandboxMealDurationMin', 0.5, 'fSandboxMealDurationMax', 2 } },
    { kind = EAT, start = { 'fSandboxLunchMin', 11, 'fSandboxLunchMax', 14 },
        duration = { 'fSandboxMealDurationMin', 0.5, 'fSandboxMealDurationMax', 2 } },
    { kind = EAT, start = { 'fSandboxDinnerMin', 17, 'fSandboxDinnerMax', 20 },
        duration = { 'fSandboxMealDurationMin', 0.5, 'fSandboxMealDurationMax', 2 } },
}

local function between(s, setting)
    local lo, hi = gmstFloat(setting[1], setting[2]), gmstFloat(setting[3], setting[4])
    if hi < lo then hi = hi + 24 end
    local value = lo + rand(s) * (hi - lo)
    return value >= 24 and value - 24 or value
end

-- s.window = { id, kind, start = absolute game hour it opens, finish }
local function chooseWindow(s, nowHours)
    local w = s.window
    if w ~= nil and nowHours < w.finish then return end
    local today = math.floor(nowHours / 24) * 24
    local hour = nowHours - today
    local best, bestUntil = nil, math.huge
    for id, def in ipairs(WINDOWS) do
        local start, duration = between(s, def.start), between(s, def.duration)
        local untilStart, tomorrow = start - hour, false
        if start + duration <= hour then
            untilStart, tomorrow = start + 24 - hour, true
        end
        if not (w ~= nil and w.id == id and not tomorrow) then
            if untilStart <= 0 then
                best, bestUntil = { id = id, kind = def.kind, start = today + start, finish = today + start + duration }, -1
                break
            elseif untilStart < bestUntil then
                local opens = today + start + (tomorrow and 24 or 0)
                best, bestUntil = { id = id, kind = def.kind, start = opens, finish = opens + duration }, untilStart
            end
        end
    end
    s.window = best
end

-- The window open now, if any: { kind = EAT or SLEEP, left = real seconds until it closes }
local function sandboxWindow(s)
    local nowHours = core.getGameTime() / 3600
    chooseWindow(s, nowHours)
    local w = s.window
    if w == nil or nowHours < w.start or nowHours >= w.finish then return nil end
    local scale = math.max(core.getGameTimeScale and core.getGameTimeScale() or 30, 1)
    return { kind = w.kind, left = (w.finish - nowHours) * 3600 / scale }
end

-- Picks the next activity like the original: every candidate (each free seat, each idle marker the actor can
-- use, one entry for wandering) weighs as much as its type's age, the number of picks since that type was last
-- chosen, so what an actor has not done for a while gets likelier. The thing used last is left alone for
-- iSandBoxPreventRepeatedActionTime. The search radius is the package location's, else fSandBoxSearchRadius.
-- Eating and sleeping happen in the actor's meal and sleep windows: eating sits down at a free seat and plays the
-- eating idles (no food item is taken from the inventory yet), sleeping lies down in a free bed until the window
-- closes. Conversations are not a sandbox activity: any actor may start one (see conversations below).
local function sandboxPick(npc, s, center, radius, flags)
    local age = s.sandboxAge
    if age == nil then
        age = { [SIT] = 1, [SLEEP] = 1, [EAT] = 1, [WANDER] = 1, [IDLE_MARKER] = 1, [CONVERSATION] = 1 }
        s.sandboxAge = age
    end
    local window = not s.creature and sandboxWindow(s) or nil
    local weights = { [SIT] = age[SIT], [SLEEP] = 0, [EAT] = 0, [WANDER] = age[WANDER],
        [IDLE_MARKER] = age[IDLE_MARKER], [CONVERSATION] = 0 }
    if window ~= nil then weights[window.kind] = WINDOW_WEIGHT end
    local blocked = s.sandboxLast ~= nil and simTime < s.sandboxLast.until_ and s.sandboxLast.id or nil
    local candidates, total = {}, 0
    local function add(kind, target)
        local w = weights[kind]
        if w <= 0 or (target ~= nil and (target.object.id == blocked or (s.avoid and s.avoid[target.object.id]))) then
            return
        end
        candidates[#candidates + 1] = { kind = kind, target = target, weight = w }
        total = total + w
    end
    if not s.creature then
        if not hasFlag(flags, SANDBOX_NO_FURNITURE) then
            for _, target in ipairs(furniture.listFurniture(npc, center, radius, false)) do
                add(SIT, target)
                if not hasFlag(flags, SANDBOX_NO_EATING) then add(EAT, target) end
            end
            if weights[SLEEP] > 0 and not hasFlag(flags, SANDBOX_NO_SLEEPING) then
                for _, target in ipairs(furniture.listFurniture(npc, center, radius, true)) do add(SLEEP, target) end
            end
        end
        if not hasFlag(flags, SANDBOX_NO_IDLE_MARKERS) then
            for _, target in ipairs(furniture.listIdleMarkers(npc, center, radius)) do add(IDLE_MARKER, target) end
        end
    end
    if not hasFlag(flags, SANDBOX_NO_WANDERING) then add(WANDER, nil) end
    if total <= 0 then return nil end
    local r = rand(s) * total
    local chosen = candidates[#candidates]
    for _, c in ipairs(candidates) do
        r = r - c.weight
        if r < 0 then
            chosen = c
            break
        end
    end
    for kind, value in pairs(age) do
        age[kind] = math.min(value + 1, 255)
    end
    age[chosen.kind] = 1
    chosen.window = window
    if chosen.target ~= nil then
        s.sandboxLast = { id = chosen.target.object.id,
            until_ = simTime + gmstFloat('iSandBoxPreventRepeatedActionTime', 30) }
    end
    return chosen
end

local function sandbox(npc, s, dest, pkg)
    local center = dest.position or s.anchor
    local radius = (dest.radius or 0) >= 1 and dest.radius or gmstFloat('fSandBoxSearchRadius', 6000)
    if s.phase == nil or (s.phase == 'wait' and simTime >= s.waitUntil) then
        local chosen = sandboxPick(npc, s, center, radius, pkg.specificFlags or 0)
        if chosen ~= nil and (chosen.kind == EAT or chosen.kind == SLEEP or chosen.window ~= nil) then
            log(('%s (%s) sandbox: %s%s'):format(npc.recordId, tostring(npc.id), SANDBOX_NAMES[chosen.kind],
                chosen.window and (' (in its %s window)'):format(chosen.window.kind == SLEEP and 'sleep' or 'meal')
                or ''))
        end
        if chosen == nil then
            -- nothing to do here: look again after iMin..iMaxSandboxRescanSeconds
            s.phase = 'wait'
            s.waitUntil = simTime + rand(s, gmstFloat('iMinSandboxRescanSeconds', 3),
                math.max(gmstFloat('iMaxSandboxRescanSeconds', 6), gmstFloat('iMinSandboxRescanSeconds', 3)))
            return
        end
        local duration = sandboxDuration(npc, s, chosen.kind)
        if chosen.kind == WANDER then
            s.activityUntil = simTime + duration
            local point = ai.randomPoint(npc, center, math.min(radius, 6000))
            if point == nil then
                s.phase, s.waitUntil = 'wait', s.activityUntil
                return
            end
            moveTo(npc, s, point, {})
            return
        end
        if chosen.kind == IDLE_MARKER and chosen.target.record.idleTimer > 0 then
            duration = chosen.target.record.idleTimer
        end
        local options = { package = pkg.type, duration = duration }
        if chosen.kind == SLEEP then
            options.sleep = true
            options.duration = chosen.window and chosen.window.left or duration
        elseif chosen.kind == EAT then
            -- GetCurrentAIProcedure 10 = eating; the food idles check which item is in hand
            options.procedure = 10
            options.usedItem = 'random'
        end
        furniture.begin(npc, s, chosen.target, options, simTime)
        s.phase = 'furniture'
    elseif s.phase == 'go' then
        if moveStatus(npc, s) ~= 'moving' then
            -- at the wander spot: stand there for what is left of the activity
            s.phase = 'wait'
            s.waitUntil = math.max(s.activityUntil or simTime, simTime + 1)
            if rand(s) < 0.5 then
                ai.face(npc, (rand(s) * 2 - 1) * math.pi)
            end
        end
    end
end

-- Wander: walk to random spots around the place and linger there.
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
            s.waitUntil = simTime + 6 + rand(s) * 14
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

-- ---------------------------------------------------------------- following

local function walkSpeed(npc)
    local ok, speed = pcall(function() return ai.getWalkSpeed and ai.getWalkSpeed(npc) end)
    if ok and type(speed) == 'number' and speed > 0 then return speed end
    return gmstFloat('fMoveBaseSpeed', 77)
end


-- Player teammates (SetPlayerTeammate): id -> actor. They follow the player through doors unless their script
-- variable Waiting is 1, as companions told to wait.
local teammates = {}
local refVarSection = storage.globalSection('ObScriptRefVars')

local function isWaiting(npc)
    local key = dlg and dlg.getReferenceId and select(2, pcall(dlg.getReferenceId, npc))
    local locals = key and refVarSection:get(key)
    return locals ~= nil and (locals.waiting or 0) ~= 0
end

local completePackage -- below

-- Followers per leader, for the queue: leader id -> { follower id -> { seen, keep, distance } }
local followersOf = {}
-- Actors whose package follows the player: id -> actor (kept while they are off-screen)
local followsPlayer = {}

-- Follow and Accompany (FOLLOW procedure, FalloutNV.exe 0x8e0f80). The follow distance D is the package target's
-- distance, else iAIDistanceRadiusMinLocation. Followers of one leader queue up in order of distance, each one
-- further back by the one before plus both bound radii plus fFollowSpaceBetweenFollowers. The stop distance S is
-- max(D - fFollowSlowdownZoneWidth, D x fFollowStopZoneMinMult). The follower paths to the leader (arriving within
-- S while the leader moves, D while it stands) once the leader moves or it is more than D + 64 away, and again
-- whenever the leader has moved min(0.75 x that radius, fAIMoveDistanceToRecalcFollowPath) or the path is done. It
-- walks while within D of a still leader, and runs when the leader runs or once more than
-- fFollowMatchSpeedZoneWidth beyond D. Its speed matches the leader's: inside D it ramps down towards S, beyond D
-- it is up to fFollowExtraCatchUpSpeedMult faster, always between fFollowWalkMinSlowdownMultiplier and
-- fFollowWalkMaxSpeedupMultiplier of its own. Accompany fails when the leader gets more than 300 beyond D.
local FOLLOWER_RADIUS = 32 -- bound radius of a person, about
local FAST_TRAVEL_DISTANCE = 16384 -- a follower this far from the player outside was left behind by fast travel
local ACCOMPANY_FAIL_MARGIN = 300

local function followQueueDistance(npc, leader, distance)
    local set = followersOf[leader.id]
    if set == nil then
        set = {}
        followersOf[leader.id] = set
    end
    set[npc.id] = { seen = simTime, keep = distance, distance = (leader.position - npc.position):length() }
    local list = {}
    for id, f in pairs(set) do
        if simTime - f.seen > 2 then
            set[id] = nil
        else
            list[#list + 1] = { id = id, keep = f.keep, distance = f.distance }
        end
    end
    table.sort(list, function(x, y)
        if x.distance ~= y.distance then return x.distance < y.distance end
        return x.id < y.id
    end)
    local spacing = gmstFloat('fFollowSpaceBetweenFollowers', 192)
    local offset = 0
    for i, f in ipairs(list) do
        if i > 1 then offset = offset + 2 * FOLLOWER_RADIUS + spacing end
        offset = math.max(offset, f.keep)
        if f.id == npc.id then return offset end
    end
    return distance
end

local function follow(npc, s, pkg)
    local target = pkg.targets[1]
    local leader = targetRef(pkg, npc)
    if leader == nil then return end
    followsPlayer[npc.id] = types.Player.objectIsInstance(leader) and npc or nil
    if not sameCell(leader.cell, npc.cell) then
        -- through the door after the leader (followers of the player are brought along by bringFollowers)
        if types.Player.objectIsInstance(leader) then return end
        if not (leader.cell.isExterior and npc.cell.isExterior) then
            reachCell(npc, s, { cell = leader.cell, position = leader.position })
            return
        end
    end
    local base = target.count and target.count >= 1 and target.count
        or gmstFloat('iAIDistanceRadiusMinLocation', 100)
    local keep = followQueueDistance(npc, leader, base)
    local distance = (leader.position - npc.position):length()
    if pkg.type == T.Accompany and distance > keep + ACCOMPANY_FAIL_MARGIN then
        completePackage(npc, s, 'left behind')
        return
    end
    local stopAt = math.max(keep - gmstFloat('fFollowSlowdownZoneWidth', 150),
        keep * gmstFloat('fFollowStopZoneMinMult', 0.5))
    local matchZone = gmstFloat('fFollowMatchSpeedZoneWidth', 128)
    -- the leader's speed, from where it was at the last update
    local leaderSpeed = 0
    if s.leaderSeen ~= nil and simTime > s.leaderSeen.time then
        leaderSpeed = (leader.position - s.leaderSeen.position):length() / (simTime - s.leaderSeen.time)
    end
    s.leaderSeen = { position = leader.position, time = simTime }
    local walk = math.max(walkSpeed(npc), 1)
    local leaderMoving = leaderSpeed > 10
    local leaderRuns = leaderSpeed > walk * 1.3
    local run = s.run or false
    if not (distance < keep * gmstFloat('fFollowWalkZoneMult', 1) and not leaderMoving) then
        run = run or leaderRuns or distance > keep + matchZone
    end
    -- speed matching, relative to the follower's own speed for its gait
    local own = run and walk * gmstFloat('fMoveRunMult', 4) or walk
    local speed
    if distance < keep then
        speed = math.max(0, distance - stopAt) / math.max(keep - stopAt, 1) * math.min(own, leaderSpeed)
    else
        speed = leaderSpeed * (1 + (distance - keep) / matchZone * gmstFloat('fFollowExtraCatchUpSpeedMult', 0.2))
    end
    speed = math.min(math.max(speed, own * gmstFloat('fFollowWalkMinSlowdownMultiplier', 0.75)),
        own * gmstFloat('fFollowWalkMaxSpeedupMultiplier', 1.5))
    local mult = speed / own
    local radius = leaderMoving and stopAt or keep
    local status = s.phase == 'go' and moveStatus(npc, s) or 'none'
    if leaderMoving or distance > keep + matchZone * 0.5 then
        local recalc = math.min(0.75 * radius, gmstFloat('fAIMoveDistanceToRecalcFollowPath', 300))
        -- (a new path at most twice a second while the old one is still being walked)
        if s.followFrom == nil or status ~= 'moving'
            or ((leader.position - s.followFrom):length() > recalc and simTime - (s.goSince or 0) >= 0.5) then
            if distance > radius then
                s.followFrom = leader.position
                -- straight at the leader where the navmesh has no route (across exterior cell borders)
                moveTo(npc, s, leader.position, { run = run, tolerance = radius, speedMult = mult, direct = true })
                return
            end
        end
    end
    if status == 'moving' then
        if ai.setPace then ai.setPace(npc, mult, run) end
    elseif s.phase ~= 'stay' then
        -- there: wait for the leader, facing it
        s.phase = 'stay'
        s.followFrom = nil
        local d = leader.position - npc.position
        ai.face(npc, math.atan2(d.x, d.y))
    end
end

-- Brings the player's teammates and followers along when the player goes through a door or fast travels, as the
-- original does (PlayerCharacter 0x973ee0, group move 0x8ad1c0): each comes out behind the player, one behind the
-- other fFollowSpaceBetweenFollowers plus its radius further back, facing the way the player faces. The dead,
-- the disabled and companions told to wait (script variable Waiting 1) stay. The original has followers that are
-- not teammates walk to the door the player used and go through; here they are brought along the same way.
local function bringFollowers()
    local p = player()
    if p == nil then return end
    local moving = {}
    local function consider(id, npc)
        if moving[id] then return end
        if not npc:isValid() or (combat and combat.isDead(npc)) then
            followsPlayer[id] = nil
            return
        end
        local bothOutside = npc.cell.isExterior and p.cell.isExterior
        local otherWorld = bothOutside and npc.cell.worldSpaceId ~= nil and p.cell.worldSpaceId ~= nil
            and npc.cell.worldSpaceId ~= p.cell.worldSpaceId
        local away = (not bothOutside and not sameCell(npc.cell, p.cell)) or otherWorld
            -- fast travel: far out of the loaded cells
            or (bothOutside and (npc.position - p.position):length() > FAST_TRAVEL_DISTANCE)
        if npc.enabled and away and not isWaiting(npc) then moving[id] = npc end
    end
    for id, npc in pairs(teammates) do consider(id, npc) end
    for id, npc in pairs(followsPlayer) do consider(id, npc) end
    local yaw = p.rotation:getYaw()
    local back = util.vector3(math.sin(yaw), math.cos(yaw), 0) * -1
    local offset = 0
    local ids = {}
    for id in pairs(moving) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local npc = moving[id]
        if furniture.inUse(states[id] or {}) then furniture.release(states[id]) end
        offset = offset + gmstFloat('fFollowSpaceBetweenFollowers', 192) + FOLLOWER_RADIUS
        teleport(npc, p.cell, p.position + back * offset, yaw)
        local s = states[id]
        if s ~= nil then
            s.phase = nil
            s.followFrom = nil
            s.leaderSeen = nil
        end
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
completePackage = function(npc, s, why)
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

-- Patrol (PATROL procedure, FalloutNV.exe 0x92acd0): the route is the chain of linked references (XLKR) from
-- the package location, followed until a point repeats or the chain ends. At each point the actor waits that
-- point's own patrol idle time (XPRD); an idle marker plays its idles meanwhile, a piece of furniture is used.
-- At the end of the route a patrol that is not repeatable (PKPT) is done; a repeatable one goes on from the
-- point the route loops back to, or, when it does not loop, walks it back the other way. A repeatable patrol
-- starts at the point nearest the actor. It walks, unless the package has Always Run.
local PATROL_ARRIVE_RADIUS = 32

local function referenceIdOf(obj)
    local ok, id = pcall(function() return dlg.getReferenceId(obj) end)
    return ok and id or nil
end

local function patrolRoute(dest, pkg)
    local first = dest.ref and referenceIdOf(dest.ref)
    local points, seen = {}, {}
    local loopTo = nil
    local current = first
    while current ~= nil and current ~= '' and #points < 256 do
        if seen[current] ~= nil then
            if pkg.patrolRepeatable then loopTo = seen[current] end
            break
        end
        points[#points + 1] = current
        seen[current] = #points
        local obj = getObject(current)
        current = obj and core.obscript.getLinkedRef and core.obscript.getLinkedRef(obj) or nil
    end
    return points, loopTo
end

local function patrolStart(npc, s, dest, pkg)
    local points, loopTo = patrolRoute(dest, pkg)
    local index = 1
    if pkg.patrolRepeatable then
        local bestDistance = math.huge
        for i, id in ipairs(points) do
            local obj = getObject(id)
            if obj ~= nil and sameCell(obj.cell, npc.cell) then
                local distance = (obj.position - npc.position):length()
                if distance < bestDistance then index, bestDistance = i, distance end
            end
        end
    end
    s.patrol = { points = points, loopTo = loopTo, index = index, step = 1 }
end

-- Moves on to the next point; false once a patrol that is not repeatable is at its end.
local function patrolStep(p, pkg)
    local count = #p.points
    if count <= 1 then return pkg.patrolRepeatable end
    local nextIndex = p.index + p.step
    if nextIndex >= 1 and nextIndex <= count then
        p.index = nextIndex
        return true
    end
    if not pkg.patrolRepeatable then return false end
    if p.loopTo ~= nil then
        p.index = p.loopTo
    else
        p.step = -p.step -- back the way it came
        p.index = p.index + p.step
    end
    return true
end

local function patrolAdvance(npc, s, pkg)
    if not patrolStep(s.patrol, pkg) then
        completePackage(npc, s, 'patrolled')
        s.phase = 'stay'
        return
    end
    s.phase = nil
end

local function patrol(npc, s, dest, pkg)
    if s.patrol == nil or s.patrol.points == nil then patrolStart(npc, s, dest, pkg) end
    local p = s.patrol
    local point = getObject(p.points[p.index])
    if #p.points == 0 then
        -- no chain of linked references: the original's patrol fails to start (0x92adb0) and the next package
        -- in the list runs. The chain can't appear later, so it is left out of the picks while the actor stays in
        -- the scene (the original fails it again at every pick, which comes to the same)
        log(('%s (%s): %s has no patrol route, picks another package'):format(npc.recordId, tostring(npc.id),
            pkg.editorId))
        s.failedUntil = s.failedUntil or {}
        s.failedUntil[pkg.id] = math.huge
        s.patrol = nil
        s.nextEvaluation = simTime
        return
    end
    if point == nil then
        -- the point isn't loaded: stand at the location
        goAndStay(npc, s, dest, pkg, function() end)
        return
    end
    local wait = core.obscript.getPatrolIdleTime and core.obscript.getPatrolIdleTime(point) or 0
    if s.phase == nil then
        local isFurniture = types.ESM4Furniture ~= nil and types.ESM4Furniture.objectIsInstance(point)
        local isMarker = types.ESM4IdleMarker ~= nil and types.ESM4IdleMarker.objectIsInstance(point)
        if not s.creature and (isFurniture or (isMarker and wait > 0)) and not (s.avoid and s.avoid[point.id]) then
            local target
            if isFurniture then
                target = furniture.markerOn(npc, point)
            else
                local record = types.ESM4IdleMarker.record(point)
                if furniture.hasNpcIdles(record) then
                    target = { object = point, position = point.position, yaw = point.rotation:getYaw(),
                        record = record }
                end
            end
            if target ~= nil then
                furniture.begin(npc, s, target, { package = pkg.type, duration = math.max(wait, 1),
                    sleep = target.sleep, run = s.run }, simTime)
                s.phase = 'furniture'
                s.afterFurniture = 'patrol'
                return
            end
        end
        if nearlyAt(npc, point.position, PATROL_ARRIVE_RADIUS) then
            s.phase = 'go'
            s.goSince = simTime - 1
        else
            local run = s.run and (point.position - npc.position):length() > 64
            local yaw = isMarker and point.rotation:getYaw() or nil
            moveTo(npc, s, point.position, { run = run, tolerance = PATROL_ARRIVE_RADIUS, yaw = yaw })
        end
    elseif s.phase == 'go' then
        local status = moveStatus(npc, s)
        if status ~= 'moving' then
            if wait > 0 then
                s.phase = 'wait'
                s.waitUntil = simTime + wait
            else
                patrolAdvance(npc, s, pkg)
            end
        end
    elseif s.phase == 'wait' and simTime >= s.waitUntil then
        patrolAdvance(npc, s, pkg)
    end
end

-- ---------------------------------------------------------------- find

-- Find (TRAVEL, ACQUIRE; FalloutNV.exe 0x8ebc60): go to the location, then take the target, the nearest match
-- within the location's radius (fAIAcquireObjectDistance outdoors when it has none, the whole cell indoors).
-- Not done yet: items inside containers and corpses, object type targets, and counts above one.
local function acquire(npc, s, dest, pkg)
    if s.phase == 'acquire' then
        local item = targetRef(pkg, npc)
        local center = dest.position or npc.position
        local radius = (dest.radius or 0) > 0 and dest.radius
            or (npc.cell.isExterior and gmstFloat('fAIAcquireObjectDistance', 4000) or math.huge)
        if item == nil or not item.enabled or not sameCell(item.cell, npc.cell)
            or (item.position - center):length() > radius then
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

-- Use Weapon (TRAVEL, USE_WEAPON; FalloutNV.exe 0x8f7730): go to the location, then fire at the target (a
-- reference or the linked reference) while the player is within fAIUseWeaponDistance. Each volley is
-- shotsMin..shotsMax shots (volley fire) or a clip (auto fire), with pauseMin..pauseMax seconds between
-- volleys; after the number of bursts the weapon goes away and the package is done, unless it repeats. Hold
-- Fire When Blocked holds the shot while a friendly actor stands within 30 degrees of the line of fire.
local HOLD_FIRE_CONE = math.cos(math.rad(30))

local function friendlyInLine(npc, target)
    local toTarget = target.position - npc.position
    local distance = toTarget:length()
    if distance < 1 then return false end
    local direction = toTarget / distance
    for id, other in pairs(tracked) do
        if other ~= npc and other ~= target and other:isValid() and not (combat and combat.isDead(other)) then
            local offset = other.position - npc.position
            local d = offset:length()
            if d > 1 and d < distance and (offset / d):dot(direction) >= HOLD_FIRE_CONE
                and not (I.FNVCombat and I.FNVCombat.getTarget and I.FNVCombat.getTarget(other) == npc) then
                return true
            end
        end
    end
    return false
end

local function useWeapon(npc, s, dest, pkg)
    if s.phase ~= 'shoot' then
        goAndStay(npc, s, dest, pkg, arrived)
        return
    end
    local target = pkg.targets[1] and (pkg.targets[1].type == 0 or pkg.targets[1].type == 3) and targetRef(pkg, npc)
    local data = pkg.useWeapon or {}
    if target == nil or combat == nil then
        completePackage(npc, s, 'no target')
        s.phase = 'stay'
        return
    end
    local p = player()
    if p == nil or not sameCell(p.cell, npc.cell) and not (p.cell.isExterior and npc.cell.isExterior)
        or (p.position - npc.position):length() > gmstFloat('fAIUseWeaponDistance', 15000) then
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
        u = { gun = gun, clip = math.max(1, gun.clipSize), bursts = 0, shots = 0, next = simTime + 0.5 }
        s.useWeapon = u
        combat.drawWeapon(npc, true)
    end
    local d = target.position - npc.position
    ai.face(npc, math.atan2(d.x, d.y))
    if simTime < u.next or combat.isActing(npc) then return end
    if u.shots <= 0 then
        -- a new volley; done after the number of bursts unless the package repeats
        if not data.repeatFire and u.bursts >= math.max(data.bursts or 1, 1) then
            combat.drawWeapon(npc, false)
            s.useWeapon = nil
            completePackage(npc, s, 'fired')
            s.phase = 'stay'
            return
        end
        if data.volley then
            local low = math.max(data.shotsMin or 0, 0)
            local high = math.max(data.shotsMax or 0, low)
            u.shots = high > 0 and rand(s, low, high) or 0
        end
        if u.shots <= 0 then u.shots = math.max(1, u.gun.clipSize) end
    end
    if u.gun.clipSize > 0 and u.clip <= 0 then
        combat.reload(npc)
        u.clip = u.gun.clipSize
        u.next = simTime + math.max(u.gun.reloadTime or 1, 0.5)
        return
    end
    if data.holdFireWhenBlocked and friendlyInLine(npc, target) then
        u.next = simTime + 0.25
        return
    end
    combat.shoot(npc, target)
    u.clip = u.clip - math.max(1, u.gun.ammoUse or 1)
    u.shots = u.shots - 1
    local rate = u.gun.shotsPerSecond or 0
    u.next = simTime + (rate > 0 and 1 / rate or 1)
    if u.shots <= 0 then
        u.bursts = u.bursts + 1
        if data.volley then
            local pauseMin = data.pauseMin or 0
            local pauseMax = math.max(data.pauseMax or pauseMin, pauseMin)
            u.next = u.next + pauseMin + rand(s) * (pauseMax - pauseMin)
        end
    end
end

-- ---------------------------------------------------------------- flee not combat

-- Flee Not Combat (FLEE_NON_COMBAT, FalloutNV.exe 0x8ddac0): run from the package target to the package location
-- reference. Done once within the location's radius; without a place to run to, once the target's distance
-- (PTDT) away, or else safe beyond fFleeDoneDistanceInterior/Exterior for 5 seconds after running
-- fFleeDistanceInterior/Exterior from it. Nothing to run from and nowhere to go: done at once.
local FLEE_SAFE_SECONDS = 5
local FLEE_REPATH_SECONDS = 20

local function fleeNotCombat(npc, s, dest, pkg)
    local from = targetRef(pkg, npc)
    if from ~= nil and not sameCell(from.cell, npc.cell) and not (from.cell.isExterior and npc.cell.isExterior) then
        from = nil
    end
    local to = dest.ref
    local done
    if to ~= nil then
        done = nearlyAt(npc, to.position, math.max(dest.radius or 0, 64)) and sameCell(to.cell, npc.cell)
    elseif from ~= nil then
        local distance = (npc.position - from.position):length()
        local wanted = pkg.targets[1] and (pkg.targets[1].count or 0) or 0
        if wanted > 0 then
            done = distance >= wanted
        else
            local safe = npc.cell.isExterior and gmstFloat('fFleeDoneDistanceExterior', 2500)
                or gmstFloat('fFleeDoneDistanceInterior', 600)
            if distance >= safe then
                s.safeSince = s.safeSince or simTime
            else
                s.safeSince = nil
            end
            done = s.safeSince ~= nil and simTime - s.safeSince >= FLEE_SAFE_SECONDS
        end
    else
        done = true
    end
    if done then
        if s.phase == 'go' then ai.stop(npc) end
        completePackage(npc, s, 'fled')
        s.phase = 'stay'
        return
    end
    if s.phase == 'stay' then return end
    if to ~= nil then
        if not reachCell(npc, s, dest) then return end
        if s.phase ~= 'go' or moveStatus(npc, s) ~= 'moving' then
            moveTo(npc, s, to.position, { run = true, tolerance = math.max(dest.radius or 0, 32) })
        end
        return
    end
    if s.safeSince ~= nil then
        if s.phase == 'go' then ai.stop(npc) end
        s.phase = 'wait'
        return
    end
    if s.phase ~= 'go' or moveStatus(npc, s) ~= 'moving' or simTime - s.goSince > FLEE_REPATH_SECONDS then
        local flee = pkg.targets[1] and (pkg.targets[1].count or 0) or 0
        if flee <= 0 then
            flee = npc.cell.isExterior and gmstFloat('fFleeDistanceExterior', 5000)
                or gmstFloat('fFleeDistanceInterior', 3000)
        end
        local offset = npc.position - from.position
        local away = offset:length() > 1 and util.vector3(offset.x, offset.y, 0):normalize()
            or util.vector3(math.sin(rand(s) * 2 * math.pi), math.cos(rand(s) * 2 * math.pi), 0)
        local goal = ai.randomPoint(npc, from.position + away * flee, 512)
        moveTo(npc, s, goal or (npc.position + away * math.min(flee, 2048)), { run = true, direct = true,
            tolerance = 64 })
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

-- ---------------------------------------------------------------- conversations between NPCs

-- NPC-to-NPC conversations (FalloutNV.exe 0x904800, checked every update): once its conversation cooldown is over
-- (fAISocialTimerForConversationsMin..Max, 30 to 60 s from the last one it started), an NPC finds another NPC
-- within 200 units that is free to talk and not talked to in the last fAItalktosameNPCtimer seconds, and starts
-- one with fAISocialchanceForConversation percent chance. Followers, escorts and accompanying NPCs only talk with
-- their package target; Sleep, Use Item At, Ambush, Guard, Dialogue and Use Weapon packages never talk, nor do
-- sandboxes that forbid it. Both stop and turn to each other (unless seated) and the conversation runs in
-- scripts/omw/fnvdialogue: HELLO, then each line's follow-up topics, to Goodbye or 100 lines. The package waits
-- meanwhile.
local CONVERSATION_DISTANCE = 200
local NO_CONVERSATION = { [T.Sleep] = true, [T.UseItemAt] = true, [T.Ambush] = true, [T.Guard] = true,
    [T.Dialogue] = true, [T.UseWeapon] = true }
local PARTNER_IS_TARGET = { [T.Follow] = true, [T.Escort] = true, [T.Accompany] = true }

local function conversing(npc)
    return I.FNVDialogue ~= nil and I.FNVDialogue.isConversing ~= nil and I.FNVDialogue.isConversing(npc)
end

local function conversationCooldown(s)
    return rand(s, gmstFloat('fAISocialTimerForConversationsMin', 30),
        math.max(gmstFloat('fAISocialTimerForConversationsMax', 60), gmstFloat('fAISocialTimerForConversationsMin', 30)))
end

local function freeToTalk(npc, s)
    local pkg = s and s.package
    if pkg == nil or s.creature or s.suspended or s.talk ~= nil or NO_CONVERSATION[pkg.type] then return false end
    if pkg.type == T.Sandbox and hasFlag(pkg.specificFlags or 0, SANDBOX_NO_CONVERSATION) then return false end
    if I.FNVDialogue and I.FNVDialogue.isTalkingTo and I.FNVDialogue.isTalkingTo(npc) then return false end
    return not conversing(npc)
end

local function conversationPartner(npc, s)
    local recent = s.talkedWith or {}
    local function fits(other)
        local os = states[other.id]
        return other ~= npc and other:isValid() and not types.Player.objectIsInstance(other) and os ~= nil
            and sameCell(other.cell, npc.cell) and (other.position - npc.position):length() <= CONVERSATION_DISTANCE
            and simTime >= (recent[other.id] or 0) and freeToTalk(other, os)
    end
    if PARTNER_IS_TARGET[s.package.type] then
        local target = targetRef(s.package, npc)
        return target ~= nil and fits(target) and target or nil
    end
    for _, other in pairs(tracked) do
        if fits(other) then return other end
    end
    return nil
end

-- Starts or follows a conversation; true while the actor is in one (its package waits).
local function conversation(npc, s)
    if s.talk ~= nil then
        local partner = s.talk.partner
        if conversing(npc) and partner:isValid() and simTime < s.talk.giveUp then return true end
        s.talk = nil
        if not furniture.inUse(s) and s.phase == 'talk' then s.phase = nil end
        return false
    end
    if not freeToTalk(npc, s) then return false end
    s.talkCooldown = s.talkCooldown or (simTime + conversationCooldown(s))
    if simTime < s.talkCooldown then return false end
    local chance = gmstFloat(npc.cell.isExterior and 'fAISocialchanceForConversation'
        or 'fAISocialchanceForConversationInterior', 25)
    if rand(s) * 100 >= chance then return false end
    local partner = conversationPartner(npc, s)
    if partner == nil then return false end
    local ps = states[partner.id]
    s.talkCooldown = simTime + conversationCooldown(s)
    local block = gmstFloat('fAItalktosameNPCtimer', 120)
    s.talkedWith = s.talkedWith or {}
    ps.talkedWith = ps.talkedWith or {}
    s.talkedWith[partner.id] = simTime + block
    ps.talkedWith[npc.id] = simTime + block
    if not (I.FNVDialogue and I.FNVDialogue.converseWith and I.FNVDialogue.converseWith(npc, partner, 'HELLO')) then
        return false
    end
    log(('%s talks with %s'):format(npc.recordId, partner.recordId))
    local d = partner.position - npc.position
    for _, side in ipairs({ { npc, s, d }, { partner, ps, d * -1 } }) do
        local actor, state, toOther = side[1], side[2], side[3]
        state.talk = { partner = actor == npc and partner or npc, giveUp = simTime + 300 }
        if not furniture.inUse(state) then
            if state.phase == 'go' then ai.stop(actor) end
            state.phase = 'talk'
            ai.face(actor, math.atan2(toOther.x, toOther.y))
        end
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
    elseif pkg.type == T.Sandbox then
        sandbox(npc, s, dest, pkg)
    elseif pkg.type == T.Wander then
        roam(npc, s, dest)
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
    s.safeSince = nil
    s.activityUntil = nil
    s.leaderSeen = nil
    s.followFrom = nil
    s.talk = nil
    followsPlayer[npc.id] = nil
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
        log(('%s (%s) picked package %s (%s)'):format(npc.recordId, tostring(npc.id), pkg.editorId, pkg.typeName))
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
        patrol = s.patrol and { points = s.patrol.points, loopTo = s.patrol.loopTo, index = s.patrol.index,
            step = s.patrol.step } or nil,
        furniture = furniture.save(s, simTime),
        useAtEnd = s.useAtEnd,
        seed = s.seed,
        window = s.window,
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
    s.window = saved.window
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
local nextTeamCheck = 0

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
        --- SetPlayerTeammate: teammates follow the player through doors (unless Waiting is 1).
        setTeammate = function(npc, on)
            if npc == nil or not npc:isValid() then return end
            teammates[npc.id] = on and npc or nil
            log(('%s %s the player\'s team'):format(npc.recordId, on and 'joins' or 'leaves'))
        end,
        isTeammate = function(npc)
            return npc ~= nil and teammates[npc.id] ~= nil
        end,
        teammateCount = function()
            local count = 0
            for _, npc in pairs(teammates) do
                if npc:isValid() and not (combat and combat.isDead(npc)) then count = count + 1 end
            end
            return count
        end,
        --- For testing: the actor follows the player (a Follow package of distance 0, ahead of its own) until
        -- called again with on = false. I.FNVAI.testFollow(obj, true)
        testFollow = function(npc, on)
            if npc == nil or not npc:isValid() then return end
            if not on then
                scriptPackages[npc.id] = nil
            else
                scriptPackages[npc.id] = { id = 'TestFollowPlayer', editorId = 'TestFollowPlayer', type = T.Follow,
                    typeName = 'Follow', flags = 0, specificFlags = 0, conditions = {},
                    schedule = { month = -1, dayOfWeek = -1, date = 0, hour = -1, duration = 0 },
                    targets = { { type = 0, id = 'FormId:0x14', count = 0 } }, locations = {},
                    onBegin = { idle = '', topic = '', script = '' }, onEnd = { idle = '', topic = '', script = '' },
                    onChange = { idle = '', topic = '', script = '' }, idles = { flags = 0, timer = 0, list = {} } }
            end
            local s = states[npc.id]
            if s then s.nextEvaluation = simTime end
        end,
        --- What the actor is doing, for scripts and tests: package editor id, phase, cell id.
        describe = function(npc)
            local s = npc and states[npc.id]
            return { package = s and s.package and s.package.editorId, phase = s and s.phase,
                talking = s and s.talk ~= nil, cell = npc and npc.cell and npc.cell.id }
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
                        .. (s and s.patrol and s.patrol.points and (', patrol point ' .. tostring(s.patrol.index) .. '/'
                            .. tostring(#s.patrol.points)) or ''))
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
            local team, followers = {}, {}
            for id, npc in pairs(teammates) do team[id] = npc end
            for id, npc in pairs(followsPlayer) do followers[id] = npc end
            return { scriptPackages = forced, ranOn = ranOn, states = saved, offscreen = away, teammates = team, followers = followers,
                version = 2 }
        end,
        onLoad = function(data)
            if data == nil then return end
            ranOn = data.ranOn or {}
            for id, packageId in pairs(data.scriptPackages or {}) do
                scriptPackages[id] = ai.getPackage(packageId)
            end
            loadedStates = data.states or {}
            teammates = {}
            for id, npc in pairs(data.teammates or {}) do
                if npc:isValid() then teammates[id] = npc end
            end
            followsPlayer = {}
            for id, npc in pairs(data.followers or {}) do
                if npc:isValid() then followsPlayer[id] = npc end
            end
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
            if simTime >= nextTeamCheck then
                nextTeamCheck = simTime + 0.5
                bringFollowers()
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
                    if not talking and s.talk == nil and simTime >= s.nextEvaluation then
                        s.nextEvaluation = simTime + EVALUATE_EVERY
                        evaluate(npc, s)
                    end
                    if not talking then
                        if not conversation(npc, s) then tick(npc, s) end
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
