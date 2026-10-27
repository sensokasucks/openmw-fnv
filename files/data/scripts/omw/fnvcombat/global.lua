-- FO3/FNV combat: resolves the shots the player script fires
-- (scripts/omw/fnvcombat/player.lua) and runs creature and NPC combat AI.
--
-- The engine (core.obscript.combat) finds what a shot hits, applies the
-- weapon's damage with the target's damage threshold and resistance the way
-- the original game does, and lays the target down when its health runs out.
-- Health is the FNV actor value (see scripts/omw/fnvstats.lua), so damage is
-- saved with the game.
--
-- Combat AI, following the AI data of the actor's record and its factions'
-- relations with the player's (FACT combat reactions, either way round):
--   * Actors notice the player by the original detection score (core.obscript.combat.detect: distance, line of
--     sight, light, footsteps, Perception against Sneak), re-checked every fDetectionTimerSetting seconds; a
--     score above fSneakNoticedMin counts. The HUD shows [HIDDEN], [CAUTION] (noticed by someone) or [DANGER]
--     (someone fights the player) while sneaking.
--   * Aggressive actors attack the player once they notice them when their factions are
--     enemies of the player's, Very Aggressive ones also when neutral,
--     Frenzied ones always. Creatures with an aggro radius attack inside it
--     unless friendly. Allies and friends only fight when attacked. Anyone
--     shot fights back.
--   * Actors with Assistance help others of their kind (same name) nearby.
--   * Confidence decides when an actor runs away, as the original's threat
--     ratio check: every fCombatThreatRatioUpdateTime it compares its side's
--     health with the enemy side's; Cowardly actors always run, Foolhardy and
--     Frenzied ones never, and nobody starts running after 2 minutes.
--   * Player teammates (SetPlayerTeammate) join fights against the player's
--     side, unless FollowerSwitchAggressive is 0 (passive) and nobody attacks
--     them. Targets are picked by the original's score.
--   * At most 15 actors that only heard the player join a fight against it.
--   * What an attacker does next comes from the original's combat planner
--     (scripts/omw/fnvcombat/planner.lua): every second it tries the goals in
--     order (flee, find a lost target, kill the target, ...) and runs the first
--     step of the cheapest plan: draw or switch to its best weapon for the
--     distance, run to the target along the navmesh (straight when there is no
--     route), swing a melee weapon, fists or creature attacks within reach,
--     shoot from within gun range with a line of fire (aim error from the weapon
--     skill, reloading when the clip runs dry), or search where the target was
--     last noticed, giving up after fCombatTargetLostRemoveTime.
-- While an NPC fights, its AI package (scripts/omw/fnvai) waits.
--
-- From the console (luag): I.FNVCombat.kill(obj), I.FNVCombat.health(obj),
-- I.FNVCombat.startCombat(obj, world.players[1]), I.FNVCombat.stopCombat(obj)

local core = require('openmw.core')
local types = require('openmw.types')
local storage = require('openmw.storage')
local util = require('openmw.util')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local combat = core.obscript and core.obscript.combat
if combat == nil or types.ESM4Creature == nil then
    return {}
end
local stats = core.obscript.stats
local ai = core.obscript.ai

local TICK_EVERY = 0.2 -- seconds between AI updates
local GIVE_UP_DISTANCE = 6000 -- combat ends when the target gets this far
local ASSIST_DISTANCE = 1500
local REACH = 150 -- unarmed and creature attacks
local STRAIGHT_DISTANCE = 600 -- closer than this, attackers leave the navmesh and go straight for the target
local FLEE_DISTANCE = 2000 -- how far a fleeing actor runs from its attacker
-- Flee check (FalloutNV.exe 0x9a1380): an actor wants to flee when its Confidence value, less a per-fight random
-- modifier (fCombatConfidenceModifierMin..Max), is above the threat ratio, its side's strength over the enemy's.
-- Values by Confidence (Cowardly .. Foolhardy) as FalloutNV.esm sets them; Foolhardy (0) never flees.
local CONFIDENCE_FLEE = { [0] = 1000, [1] = 0.375, [2] = 0.1875, [3] = 0.0375, [4] = 0 }
local THREAT_RATIO_STOP = 120 -- seconds into a fight after which the ratio is no longer checked
local PLAYER_ATTACKER_SOFT_CAP = 15 -- iCombatTargetPlayerSoftCap

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or default
end

local function displayName(obj)
    local name = combat.getName(obj)
    if name == '' then
        return obj.recordId
    end
    return name
end

local function isActor(obj)
    return types.ESM4Creature.objectIsInstance(obj) or types.ESM4NPC.objectIsInstance(obj)
end

local function isAlive(obj)
    if obj == nil or not obj:isValid() or not obj.enabled then return false end
    if types.Player.objectIsInstance(obj) then
        return not types.Actor.isDead(obj)
    end
    return combat.canBeHit(obj) and not combat.isDead(obj)
end

-- Raises an ObScript block (OnHit, OnDeath, OnStartCombat, ...) on the
-- object's script, if it has one (openmw_aux/obscript/runtime.lua).
local function scriptEvent(obj, event, ref)
    if obj ~= nil and obj:isValid() then
        obj:sendEvent('ObScriptEvent', { event = event, ref = ref })
    end
end

local tracked = {} -- id -> actor in an active cell
local fighting = {} -- id -> { actor, target, fleeing, nextAttack, nextMove }
local simTime, nextTick = 0, 0
local wantsToFlee -- below
local nextDetection = 0

local function startCombat(actor, target)
    if not isAlive(actor) or not isAlive(target) or actor == target then return end
    local s = fighting[actor.id]
    if s and s.target == target then return end
    s = { actor = actor, target = target, fleeing = false, nextAttack = 0, nextMove = 0, since = simTime,
        confidenceMod = gmst('fCombatConfidenceModifierMin', -0.25) + math.random()
            * (gmst('fCombatConfidenceModifierMax', 1.0) - gmst('fCombatConfidenceModifierMin', -0.25)),
        nextThreatCheck = simTime + math.random() * gmst('fCombatThreatRatioUpdateTime', 7.5) }
    -- what it carries and holds, for the combat planner (weapon types: 1 ranged, 2 melee, 6 hand to hand, 7 none drawn)
    s.equippedType, s.drawnType = 6, 6
    if types.ESM4NPC.objectIsInstance(actor) then
        s.weapons = combat.getActorWeapons(actor)
        local weapon = combat.getActorWeapon(actor)
        if weapon then
            s.inHand = weapon
            s.equippedType, s.drawnType = weapon.type, 7
        end
    end
    fighting[actor.id] = s
    tracked[actor.id] = actor
    print(('[combat] %s (%s) fights %s'):format(actor.recordId, tostring(actor.id), tostring(target.recordId)))
    scriptEvent(actor, 'OnStartCombat', target)
end

local function stopCombat(actor, why)
    local s = fighting[actor.id]
    if s then
        print(('[combat] %s (%s) stops fighting (%s)'):format(actor.recordId, tostring(actor.id), why or 'told to'))
        fighting[actor.id] = nil
        scriptEvent(actor, 'OnCombatEnd', s.target)
        if actor:isValid() then
            ai.stop(actor)
            if s.drawnType ~= 7 and s.inHand ~= nil then combat.drawWeapon(actor, false) end
        end
    end
end

local function callForHelp(actor, target)
    local name = combat.getName(actor)
    for id, other in pairs(tracked) do
        if other ~= actor and fighting[id] == nil and other:isValid() and isAlive(other)
            and stats.get(other, 'Assistance') >= 1 and combat.getName(other) == name
            and (other.position - actor.position):length() <= ASSIST_DISTANCE then
            startCombat(other, target)
        end
    end
end


-- Detection of the player: actor id -> { score, sight }
local detection = {}
local detectionSection = storage.globalSection('FNVDetection')
detectionSection:setLifeTime(storage.LIFE_TIME.GameSession)
local actorAI = storage.globalSection('ESM4ActorAI')

local function noticesPlayer(actor)
    local d = detection[actor.id]
    return d ~= nil and d.score > gmst('fSneakNoticedMin', -20)
end

-- How the actor's factions treat the player; factions the player has made enemies of by crime count as enemies.
local function reactionOf(actor)
    if I.FNVCrime and I.FNVCrime.isFactionEnemy(actor) then return 'enemy' end
    return combat.getReaction(actor)
end

-- Whether the actor attacks the player now that it has seen a crime, by its Aggression and how its factions
-- treat the player (FalloutNV.exe 0x8b06d0, without the detection and soft cap checks of wantsFight).
local function shouldAttack(actor)
    if I.FNVAI and I.FNVAI.isTeammate and I.FNVAI.isTeammate(actor) then return false end
    local aggression = stats.get(actor, 'Aggression')
    if aggression >= 3 then return true end
    local reaction = reactionOf(actor)
    if reaction == 'ally' or reaction == 'friend' then return false end
    if reaction == 'enemy' then return aggression >= 1 end
    return aggression >= 2
end

local function wantsFight(actor, player)
    if I.FNVAI and I.FNVAI.isTeammate and I.FNVAI.isTeammate(actor) then return false end
    local distance = (player.position - actor.position):length()
    if not noticesPlayer(actor) then return false end
    -- iCombatTargetPlayerSoftCap: once 15 fight the player, only those that see it join
    local d = detection[actor.id]
    if d.score <= gmst('fSneakSeenMin', 0) then
        local attackers = 0
        for _, other in pairs(fighting) do
            if other.target == player then attackers = attackers + 1 end
        end
        if attackers >= PLAYER_ATTACKER_SOFT_CAP then return false end
    end
    -- a crime against it (scripts/omw/fnvcrime) makes it attack whatever its aggression
    if I.FNVCrime and I.FNVCrime.isPlayerEnemy(actor) then return true end
    local aggression = stats.get(actor, 'Aggression')
    if aggression >= 3 then return true end
    local reaction = reactionOf(actor)
    if reaction == 'ally' or reaction == 'friend' then return false end
    if types.ESM4Creature.objectIsInstance(actor) then
        local aggro = combat.getAggroRadius(actor)
        if aggro and aggro.enabled and aggro.radius > 0 and distance <= aggro.radius then
            return true
        end
    end
    if reaction == 'enemy' then return aggression >= 1 end
    return aggression >= 2
end

local function yawTo(from, to)
    local d = to - from
    return math.atan2(d.x, d.y)
end

-- How close gunmen get before they stop and shoot: the weapon's range, within reason
local function gunRange(gun)
    return math.min(math.max(gun.maxRange or 0, 600), 1500)
end

local function approach(s, actor, target, reach, aroundObstacles)
    -- The navmesh ends where the target may not (rocks, furniture): when the route runs out short of the
    -- target, or it is close, go straight for it. Getting around something in the way needs the navmesh.
    local status = ai.status(actor)
    local close = (target.position - actor.position):length() < STRAIGHT_DISTANCE
    if status == 'arrived' or status == 'nopath' or (close and not aroundObstacles) then
        s.straight = true
    end
    local moved = s.goal == nil or (s.goal - target.position):length() > 64
    if status ~= 'moving' or (moved and simTime >= s.nextMove) then
        s.nextMove = simTime + 0.5
        s.goal = target.position
        ai.moveTo(actor, target.position, { run = true, direct = true, straight = s.straight, tolerance = reach * 0.7 })
    end
end

-- Fires at the rate the weapon allows, with a short pause between shots as FNV NPCs take; reloads an empty clip.
local function shootAt(s, actor, target)
    local gun = s.gun
    if gun.clipSize > 0 and s.clip <= 0 then
        combat.reload(actor)
        s.clip = gun.clipSize
        s.nextAttack = simTime + math.max(gun.reloadTime or 1, 0.5)
        return
    end
    combat.shoot(actor, target)
    s.clip = s.clip - math.max(1, gun.ammoUse or 1)
    local rate = gun.shotsPerSecond or 0
    local delay = rate > 0 and 1 / rate or 1
    if not gun.automatic then
        delay = delay + 0.4 + math.random() * 0.8
    end
    s.nextAttack = simTime + delay
end

-- ---------------------------------------------------------------- teammates and target selection


local function isTeammate(actor)
    return I.FNVAI ~= nil and I.FNVAI.isTeammate ~= nil and I.FNVAI.isTeammate(actor)
end

-- An object script variable (lower-case name) as published by scripts/omw/fnvdialogue, nil if unknown.
local refVars = storage.globalSection('ObScriptRefVars')
local function refVar(obj, name)
    local dlg = core.obscript.dialogue
    local ok, key = pcall(function() return dlg.getReferenceId(obj) end)
    local locals = ok and key and refVars:get(key)
    return locals and locals[name]
end

local function onPlayerSide(actor)
    return types.Player.objectIsInstance(actor) or isTeammate(actor)
end

-- Target score of the original's combat target selection (FalloutNV.exe): +1000 when seen, +100 with a line of
-- sight, +100 for the current target and +1000 more if it was seen in the last 2 s, up to +1000 for being close
-- (nothing from 2048 units on). Dead targets are left out (the original takes 500 off).
local RESELECT_EVERY = 1.0
local CLOSE_RANGE = 2048

local function targetScore(s, actor, target)
    local score = 0
    local d = combat.detect and select(1, combat.detect(actor, target, { inCombat = true, alert = true }))
    local seen = d ~= nil and d > gmst('fSneakNoticedMin', -20)
    local sight = combat.hasLineOfFire(actor, target)
    s.seen = s.seen or {}
    if seen then
        score = score + 1000
        s.seen[target.id] = simTime
    end
    if sight then score = score + 100 end
    if target == s.target then
        score = score + 100
        if simTime - (s.seen[target.id] or -math.huge) <= 2 then score = score + 1000 end
    end
    local distance = (target.position - actor.position):length()
    score = score + math.max(0, 1000 * (1 - distance / CLOSE_RANGE))
    return score
end

-- Who an actor could fight: for the player's side, those fighting it; for the others, the player and its
-- teammates if they fight one of them.
local function candidateTargets(s, actor, player)
    local list = {}
    if onPlayerSide(actor) then
        for id, other in pairs(fighting) do
            if id ~= actor.id and other.target ~= nil and onPlayerSide(other.target) and not onPlayerSide(other.actor)
                and isAlive(other.actor) then
                list[#list + 1] = other.actor
            end
        end
    elseif s.target ~= nil and onPlayerSide(s.target) then
        if isAlive(player) then list[#list + 1] = player end
        for id, other in pairs(tracked) do
            if other:isValid() and isAlive(other) and isTeammate(other) and other.cell ~= nil and actor.cell ~= nil
                and other.cell.id == actor.cell.id then
                list[#list + 1] = other
            end
        end
    end
    return list
end

local function selectTarget(s, player)
    if s.fleeing or simTime < (s.nextSelect or 0) then return end
    s.nextSelect = simTime + RESELECT_EVERY
    local best, bestScore = nil, -math.huge
    for _, candidate in ipairs(candidateTargets(s, s.actor, player)) do
        local score = targetScore(s, s.actor, candidate)
        if score > bestScore then best, bestScore = candidate, score end
    end
    if best ~= nil and best ~= s.target then
        s.target = best
        s.straight = false
    end
end

-- Teammates join every fight against the player or another teammate, as the original's teammates take on the
-- player's enemies.
local function teammatesHelp(player)
    if I.FNVAI == nil or I.FNVAI.isTeammate == nil then return end
    for id, mate in pairs(tracked) do
        if fighting[id] == nil and mate:isValid() and isAlive(mate) and isTeammate(mate) then
            -- FollowerSwitchAggressive 0: passive, fights only whoever attacks it
            local passive = refVar(mate, 'followerswitchaggressive') == 0
            for otherId, other in pairs(fighting) do
                if otherId ~= id and other.target ~= nil and (passive and other.target == mate
                    or not passive and onPlayerSide(other.target))
                    and not onPlayerSide(other.actor) and isAlive(other.actor)
                    and (other.actor.position - mate.position):length() <= GIVE_UP_DISTANCE then
                    startCombat(mate, other.actor)
                    break
                end
            end
        end
    end
end

-- Strength of one side of a fight: the health of everyone on it.
local function sideHealth(members)
    local total = 0
    for _, m in ipairs(members) do
        if isAlive(m) then total = total + math.max(stats.get(m, 'Health'), 0) end
    end
    return total
end

-- The threat ratio (FalloutNV.exe 0x9a1060): own side's strength over the enemy side's, 100 without data. The
-- own side is everyone fighting the same enemies; the enemy side is the target and, for the player, its teammates.
local function threatRatio(s)
    local own, enemies = { s.actor }, { s.target }
    for id, other in pairs(fighting) do
        if other ~= s and other.target == s.target and not onPlayerSide(other.actor) then own[#own + 1] = other.actor end
    end
    if onPlayerSide(s.target) then
        for id, other in pairs(tracked) do
            if other ~= s.target and isTeammate(other) and isAlive(other) and fighting[id] ~= nil then
                enemies[#enemies + 1] = other
            end
        end
    end
    local enemy = sideHealth(enemies)
    if enemy <= 0 then return 100 end
    return sideHealth(own) / enemy
end

wantsToFlee = function(s)
    local actor = s.actor
    if stats.get(actor, 'Aggression') >= 3 or simTime - s.since > THREAT_RATIO_STOP then return s.fleeing end
    local confidence = math.floor(stats.get(actor, 'Confidence'))
    local t = CONFIDENCE_FLEE[confidence] or CONFIDENCE_FLEE[2]
    if t > 0 then t = t - s.confidenceMod end
    return t > threatRatio(s)
end

-- ---------------------------------------------------------------- the combat planner (scripts/omw/fnvcombat/planner)
--
-- Every second (and whenever a step fails) the actor plans again from what it knows: the first of the original's
-- goals that yields a plan wins (FLEE, FIND_TARGET when it lost the target, KILL_TARGET, ...), and the plan's
-- first step runs as a procedure here. Cover, flanking, grenades and combat items are not planned yet.

local P = require('scripts.omw.fnvcombat.planner')
local PW = P.W
local REPLAN_EVERY = 1.0
local LOST_AFTER = 3 -- seconds without noticing the target before it counts as lost
local STEP_TIMEOUT = 15

local function lostRemoveTime()
    return gmst('fCombatTargetLostRemoveTime', 30)
end

-- How good a weapon is: damage over time, more for guns at range and for melee up close (inferred: the
-- original's weapon suitability is not decoded yet).
local function weaponScore(weapon, weaponType, distance)
    local damage = math.max(weapon.damage or 1, 1)
    local rate = weapon.shotsPerSecond and weapon.shotsPerSecond > 0 and weapon.shotsPerSecond or 1
    if weaponType == PW.RANGED then
        local range = gunRange(weapon)
        return damage * rate * (distance > range * 1.5 and 0.7 or 1)
    end
    return damage * (distance > STRAIGHT_DISTANCE and 0.5 or 1)
end

-- The NPC's best weapon of each type it carries (creatures fight hand to hand with their own attacks)
local function bestWeapons(s, distance)
    local best = {}
    for _, weapon in ipairs(s.weapons or {}) do
        local t = weapon.type
        -- explosives, grenades and mines wait for their procedures
        if t == PW.RANGED or t == PW.MELEE or t == PW.HAND_TO_HAND then
            local score = weaponScore(weapon, t, distance)
            if best[t] == nil or score > best[t].score then best[t] = { weapon = weapon, score = score } end
        end
    end
    if next(best) == nil then best[PW.HAND_TO_HAND] = { score = 1 } end
    return best
end

local function meleeReach(s)
    local weapon = s.inHand
    if weapon and (weapon.type == PW.MELEE or weapon.type == PW.HAND_TO_HAND) and (weapon.reach or 0) > 0 then
        return math.min(math.max(REACH * weapon.reach, 100), 250)
    end
    return REACH
end

-- How close counts as at the target: gunmen without a line of fire come right up (the navmesh may end short)
local function closeEnough(s, los)
    return (s.gun ~= nil and not los) and REACH or 300
end

local function targetLost(s)
    return simTime - (s.lastSeenAt or s.since) > LOST_AFTER
end

local function inGunRange(s, distance)
    return s.gun ~= nil and distance <= gunRange(s.gun)
end

local function worldState(s, distance, los)
    local P_F, L = P.F, P.L
    local best = s.best
    local function at(kind)
        if kind == L.TARGET then return distance <= closeEnough(s, los) or (los and inGunRange(s, distance)) end
        if kind == L.MELEE then return distance <= meleeReach(s) end
        if kind == L.FLEE then return distance >= FLEE_DISTANCE end
        if kind == L.LOS then return los and (s.gun == nil or inGunRange(s, distance)) end
        if kind == L.INVESTIGATE then
            return s.searchPos ~= nil and (s.actor.position - s.searchPos):length() <= 128
        end
        return kind == L.DESTINATION or kind == L.GUARD or kind == L.CLUSTER or kind == L.COMBAT_AREA
    end
    return function(fact, param)
        if fact == P_F.TARGET_DEAD then return isAlive(s.target) and 0 or 1 end
        if fact == P_F.AT_LOCATION then return at(param) and 1 or 0 end
        if fact == P_F.NOT_AT_LOCATION then return at(param) and 0 or 1 end
        if fact == P_F.TARGET_LOST then return targetLost(s) and 1 or 0 end
        if fact == P_F.TARGET_DETECTED then return targetLost(s) and 0 or 1 end
        if fact == P_F.TARGET_360_LOS then return los and (s.drawnType ~= PW.RANGED or inGunRange(s, distance)) and 1 or 0 end
        if fact == P_F.WEAPON_DRAWN then return s.drawnType end
        if fact == P_F.WEAPON_TYPE_EQUIPPED then return s.equippedType end
        if fact == P_F.HAS_WEAPON_TYPE then return best[param] ~= nil and 1 or 0 end
        if fact == P_F.WANTS_TO_FLEE then return s.fleeing and 1 or 0 end
        if fact == P_F.EXECUTION_FLAGS then
            return (param == P.X.SEARCH or param == P.X.MOVE or param == P.X.MELEE) and 1 or 0
        end
        return 0
    end
end

-- Base cost, plus for attacks the original's weapon suitability term: the best weapon's score less this one's
-- (FalloutNV.exe 0x97ac30). A teammate told to fight in melee (CombatStyleMelee 1) never shoots.
local function planCost(s)
    local topScore = 0
    for _, b in pairs(s.best) do topScore = math.max(topScore, b.score) end
    local meleeOnly = isTeammate(s.actor) and refVar(s.actor, 'combatstylemelee') == 1
    return function(action, param)
        local weaponType = action.attack
        if action.weapon then weaponType = param end
        if weaponType == nil then return action.cost end
        local b = s.best[weaponType]
        if b == nil or b.score <= 0 then return P.INF end
        if meleeOnly and (weaponType == PW.RANGED or weaponType == PW.EXPLOSIVE or weaponType == PW.GRENADE) then
            return P.INF
        end
        return action.cost + (topScore - b.score)
    end
end

local function stepLabel(step)
    return step.name .. (step.param ~= nil and ('(' .. step.param .. ')') or '')
end

local function replan(s, distance, los)
    s.best = bestWeapons(s, distance)
    local actorType = s.equippedType
    if actorType == PW.NONE then actorType = PW.HAND_TO_HAND end
    local weaponTypes = {}
    for t in pairs(s.best) do weaponTypes[#weaponTypes + 1] = t end
    local ctx = { actorType = actorType, locations = { P.L.TARGET, P.L.MELEE, P.L.FLEE, P.L.LOS, P.L.INVESTIGATE },
        weaponTypes = weaponTypes, cost = planCost(s) }
    local goal, plan = P.plan(worldState(s, distance, los), ctx)
    s.replanAt = simTime + REPLAN_EVERY
    s.stepFailed = false
    local current = s.plan and s.plan[s.step]
    if plan == nil then
        s.plan, s.step = nil, nil
        return
    end
    local labels = {}
    for _, step in ipairs(plan) do labels[#labels + 1] = stepLabel(step) end
    local text = goal.name .. ': ' .. table.concat(labels, ' > ')
    if text ~= s.planText then
        print(('[combat] %s (%s) plans %s'):format(s.actor.recordId, tostring(s.actor.id), text))
        s.planText = text
    end
    -- the same first step carries on where it was
    if current == nil or current.name ~= plan[1].name or current.param ~= plan[1].param then
        s.stepStarted = simTime
        s.stepState = {}
    end
    s.plan, s.step = plan, 1
end

-- ---------------------------------------------------------------- procedures: 'running', 'done' or 'failed'

local function holdStill(actor)
    if ai.status(actor) == 'moving' then ai.stop(actor) end
end

local function equipType(s, weaponType)
    local b = s.best[weaponType]
    local actor = s.actor
    if b and b.weapon then
        if s.inHand == nil or s.inHand.id ~= b.weapon.id then
            combat.equipWeapon(actor, b.weapon.id)
            s.inHand = b.weapon
        end
        combat.drawWeapon(actor, true)
    elseif types.ESM4NPC.objectIsInstance(actor) then
        combat.drawWeapon(actor, false) -- fists
        s.inHand = nil
    end
    s.equippedType, s.drawnType = weaponType, weaponType
    if weaponType == PW.RANGED and s.inHand and s.inHand.isGun then
        if s.gun == nil or s.gun.id ~= s.inHand.id then
            s.gun = s.inHand
            s.clip = math.max(1, s.gun.clipSize)
        end
    else
        s.gun = nil
    end
end

local function moveTowards(s, kind, distance, los)
    local actor, target = s.actor, s.target
    local L = P.L
    local state = s.stepState
    if kind == L.FLEE then
        if distance >= FLEE_DISTANCE then
            holdStill(actor)
            return 'done'
        end
        if simTime >= (state.nextMove or 0) then
            state.nextMove = simTime + 1.0
            local offset = target.position - actor.position
            local away = util.vector3(-offset.x, -offset.y, 0):normalize() * FLEE_DISTANCE
            ai.moveTo(actor, actor.position + away, { run = true, direct = true, tolerance = 64 })
        end
        return 'running'
    end
    if kind == L.INVESTIGATE then
        if s.searchPos == nil then return 'failed' end
        if (actor.position - s.searchPos):length() <= 128 then
            holdStill(actor)
            return 'done'
        end
        if state.sentTo ~= s.searchPos or ai.status(actor) == 'idle' then
            state.sentTo = s.searchPos
            ai.moveTo(actor, s.searchPos, { run = true, direct = true, tolerance = 96 })
        elseif ai.status(actor) == 'nopath' then
            return 'failed'
        end
        return 'running'
    end
    -- the target, a spot in melee reach or one with a line of fire
    local reach
    if kind == L.MELEE then
        reach = meleeReach(s)
        if distance <= reach then return 'done' end
    else
        reach = closeEnough(s, los)
        if los and (s.gun == nil or inGunRange(s, distance)) or kind == L.TARGET and distance <= reach then
            s.straight = false
            return 'done'
        end
        if not los then reach = REACH end
    end
    approach(s, actor, target, reach, s.gun ~= nil and not los)
    return 'running'
end

local function attackRanged(s, distance, los)
    local actor, target = s.actor, s.target
    if s.gun == nil or not los or not inGunRange(s, distance) then return 'failed' end
    s.straight = false
    holdStill(actor)
    ai.face(actor, yawTo(actor.position, target.position))
    if simTime >= s.nextAttack then shootAt(s, actor, target) end
    return 'running'
end

local function attackMelee(s, distance)
    local actor, target = s.actor, s.target
    local reach = meleeReach(s)
    if distance > reach * 1.3 then return 'failed' end
    s.straight = false
    holdStill(actor)
    ai.face(actor, yawTo(actor.position, target.position))
    if simTime >= s.nextAttack then
        s.nextAttack = simTime + 1.2 + math.random() * 0.8
        combat.attack(actor, target, reach)
    end
    return 'running'
end

local procedures = {
    MOVE = function(s, step, distance, los) return moveTowards(s, step.param, distance, los) end,
    MOVE_AND_SWITCH_TO_MELEE = function(s, step, distance, los)
        if s.equippedType ~= PW.MELEE or s.drawnType ~= PW.MELEE then equipType(s, PW.MELEE) end
        return moveTowards(s, step.param, distance, los)
    end,
    MOVE_AND_ATTACK_RANGED = function(s, step, distance, los)
        if los and s.gun and simTime >= s.nextAttack and inGunRange(s, distance) then
            shootAt(s, s.actor, s.target)
        end
        return moveTowards(s, step.param, distance, los)
    end,
    DRAW_WEAPON = function(s, step)
        local state = s.stepState
        if state.readyAt == nil then
            equipType(s, step.param)
            state.readyAt = simTime + 0.6
        end
        return simTime >= state.readyAt and 'done' or 'running'
    end,
    ATTACK_RANGED = function(s, step, distance, los) return attackRanged(s, distance, los) end,
    ATTACK_MELEE = function(s, step, distance) return attackMelee(s, distance) end,
    ATTACK_HAND_TO_HAND = function(s, step, distance) return attackMelee(s, distance) end,
    APPROACH_TARGET = function() return 'done' end,
    ACQUIRE_LINE_OF_SIGHT = function() return 'done' end,
    IGNORE_BLOCKED_TARGET = function() return 'done' end,
    -- looks around where the target was last noticed, then tries another spot near it
    INVESTIGATE = function(s)
        local state = s.stepState
        holdStill(s.actor)
        state.until_ = state.until_ or simTime + 3
        if simTime < state.until_ then return 'running' end
        local from = s.lastSeenPos or s.actor.position
        local angle = math.random() * 2 * math.pi
        local radius = 256 + math.random() * 512
        s.searchPos = from + util.vector3(math.cos(angle) * radius, math.sin(angle) * radius, 0)
        return 'done'
    end,
    -- runs off until far enough, then stays away while it still wants to flee
    FLEE = function(s, step, distance)
        if distance < FLEE_DISTANCE * 0.75 then return 'failed' end
        holdStill(s.actor)
        return 'running'
    end,
}
procedures.SWITCH_WEAPON = procedures.DRAW_WEAPON
procedures.SEARCH = procedures.INVESTIGATE

local function fight(s)
    selectTarget(s, world.players[1])
    local actor, target = s.actor, s.target
    if not isAlive(target) then
        stopCombat(actor, 'target dead or gone')
        return
    end
    local offset = target.position - actor.position
    local distance = util.vector2(offset.x, offset.y):length()
    if distance > GIVE_UP_DISTANCE or actor.cell.worldSpaceId ~= target.cell.worldSpaceId then
        stopCombat(actor, 'target too far')
        return
    end

    if simTime >= s.nextThreatCheck then
        s.nextThreatCheck = simTime + gmst('fCombatThreatRatioUpdateTime', 7.5)
        local wants = wantsToFlee(s)
        if wants ~= s.fleeing then
            ai.stop(actor)
            s.replanAt = 0
        end
        s.fleeing = wants
    end

    -- where the target was last noticed
    local los = combat.hasLineOfFire(actor, target)
    local noticed
    if types.Player.objectIsInstance(target) then
        noticed = noticesPlayer(actor)
    else
        -- the same detection score as for the player, in combat and alert
        local score = combat.detect and select(1, combat.detect(actor, target, { inCombat = true, alert = true }))
        noticed = los or distance <= REACH * 2 or (score ~= nil and score > gmst('fSneakNoticedMin', -20))
    end
    if not noticed and not targetLost(s) and simTime - (s.lastSeenAt or s.since) + TICK_EVERY > LOST_AFTER then
        local score = combat.detect and select(1, combat.detect(actor, target, { inCombat = true, alert = true }))
        print(('[combat] %s (%s) loses %s at %.0f (detection %s, line of fire %s, height difference %.0f, moving %s)')
            :format(actor.recordId, tostring(actor.id), tostring(target.recordId), distance, tostring(score),
                tostring(los), target.position.z - actor.position.z, tostring(ai.status(actor))))
    end
    if noticed then
        if targetLost(s) then s.replanAt = 0 end
        s.lastSeenAt, s.lastSeenPos = simTime, target.position
        s.searchPos = target.position
    elseif simTime - (s.lastSeenAt or s.since) > lostRemoveTime() then
        stopCombat(actor, 'target lost')
        return
    end

    if combat.isActing(actor) then return end
    if s.plan == nil or s.stepFailed or simTime >= (s.replanAt or 0) then
        replan(s, distance, los)
    end
    local step = s.plan and s.plan[s.step]
    if step == nil then
        holdStill(actor)
        return
    end
    local procedure = procedures[step.name]
    local result = procedure and procedure(s, step, distance, los) or 'failed'
    if step.action.move and step.param ~= P.L.FLEE then
        local state = s.stepState
        state.startDistance = state.startDistance or distance
        if not state.awayLogged and distance > state.startDistance + 300 then
            state.awayLogged = true
            print(('[combat] %s (%s) moves away from %s on %s: %.0f -> %.0f (moving %s, straight %s)'):format(
                actor.recordId, tostring(actor.id), tostring(target.recordId), stepLabel(step), state.startDistance,
                distance, tostring(ai.status(actor)), tostring(s.straight)))
        end
    end
    if result == 'running' and simTime - (s.stepStarted or simTime) > STEP_TIMEOUT
        and step.name:sub(1, 6) ~= 'ATTACK' and step.name ~= 'FLEE' then
        result = 'failed'
    end
    if result == 'done' then
        s.step = s.step + 1
        s.stepStarted, s.stepState = simTime, {}
        if s.plan[s.step] == nil then s.plan = nil end
    elseif result == 'failed' then
        s.stepFailed = true
    end
end

return {
    interfaceName = 'FNVCombat',
    ---
    -- @module FNVCombat
    -- @context global
    interface = {
        version = 0,
        --- Current and full health of an actor.
        health = function(actor)
            return stats.get(actor, 'Health'), stats.getPermanent(actor, 'Health')
        end,
        isDead = function(actor) return combat.isDead(actor) end,
        --- Damage an actor's health (after its armor); attacker may be nil.
        hit = function(target, attacker, damage) combat.hit(target, attacker, damage) end,
        kill = function(target) combat.hit(target, nil, 1e9) end,
        --- Whether the actor is fighting or running away; its AI package waits meanwhile.
        isInCombat = function(actor) return fighting[actor.id] ~= nil end,
        --- Whether the actor's detection score of the player is above fSneakNoticedMin (checked every
        -- fDetectionTimerSetting seconds).
        noticesPlayer = function(actor) return noticesPlayer(actor) end,
        --- Whether anyone fights the target (battle music).
        isTargeted = function(target)
            for _, s in pairs(fighting) do
                if s.target == target and not s.fleeing then return true end
            end
            return false
        end,
        getTarget = function(actor)
            local s = fighting[actor.id]
            return s and s.target
        end,
        --- The actor's combat plan as text ("KILL_TARGET: MOVE(0) > APPROACH_TARGET > ATTACK_RANGED"), nil if none.
        getPlan = function(actor)
            local s = fighting[actor.id]
            return s and s.planText
        end,
        startCombat = startCombat,
        stopCombat = stopCombat,
        shouldAttack = shouldAttack,
        --- The actors in the scene the combat AI knows about (id -> object).
        actors = function() return tracked end,
    },
    eventHandlers = {
        -- From the player script: { attacker, weapon = record id, origin = vec3, direction = vec3 }
        FNVCombat_Fire = function(e)
            local player = e.attacker
            if player == nil or not player:isValid() or e.weapon == nil then return end
            combat.fire(player, e.weapon, e.origin, e.direction)
        end,
        FNVCombat_PlayerWeapon = function(e)
            local section = storage.globalSection('FNVPlayerWeapon')
            section:set('weapon', e.weapon)
            section:set('editorId', e.editorId)
            section:set('animType', e.animType or 0)
            section:set('drawn', e.drawn == true)
            -- the player's FO3/FNV body holds it (RenderingManager::hasPlayerBody)
            local ai = core.obscript and core.obscript.ai
            if ai and ai.setPlayerBodyWeapon then
                ai.setPlayerBodyWeapon(e.weapon, e.drawn == true)
            end
        end,
        -- From the engine once a shot is resolved, or a melee, unarmed or creature blow lands (melee = true)
        FNVCombat_Shot = function(e)
            if e.attacker == nil or not e.attacker:isValid() then return end
            local target = e.target
            -- `Begin OnHitWith` on whatever the shot hit (the VCG02 sarsaparilla bottles)
            local struck = target or e.object
            if struck ~= nil and struck:isValid() then
                scriptEvent(struck, 'OnHitWith', e.attacker)
            end
            if target ~= nil and target:isValid() and isActor(target) then
                scriptEvent(target, 'OnHit', e.attacker)
                if e.killed then
                    scriptEvent(target, 'OnDeath', e.attacker)
                    -- Limbs may come off (scripts/omw/fnvgore)
                    core.sendGlobalEvent('FNVGore_Killed', {
                        target = target,
                        attacker = e.attacker,
                        weapon = e.weapon,
                        limb = e.limb,
                        direction = e.direction,
                    })
                end
            end
            if target ~= nil and target:isValid() and isActor(target) and I.FNVCrime then
                -- assault and murder (scripts/omw/fnvcrime), before the target turns on the attacker
                I.FNVCrime.attacked(target, e.attacker, e.killed == true, fighting[target.id] ~= nil
                    and fighting[target.id].target == e.attacker)
            end
            if target ~= nil and target:isValid() and not e.killed and isActor(target) then
                startCombat(target, e.attacker)
                callForHelp(target, e.attacker)
            end
            if not types.Player.objectIsInstance(e.attacker) then return end
            local result = { damage = e.damage, killed = e.killed }
            if target ~= nil and target:isValid() then
                result.target = target
                result.name = displayName(target)
                result.health, result.maxHealth = stats.get(target, 'Health'), stats.getPermanent(target, 'Health')
            end
            e.attacker:sendEvent('FNVCombat_ShotResult', result)
        end,
    },
    engineHandlers = {
        onObjectActive = function(obj)
            if isActor(obj) then
                tracked[obj.id] = obj
            end
        end,
        onUpdate = function(dt)
            simTime = simTime + dt
            if simTime < nextTick then return end
            nextTick = simTime + TICK_EVERY
            local player = world.players[1]
            local playerAlive = player ~= nil and isAlive(player)
            if simTime >= nextDetection and playerAlive and combat.detect then
                -- staggered like the original's 0.3 s timer
                nextDetection = simTime + gmst('fDetectionTimerSetting', 0.3)
                local noticed, danger = false, false
                for id, actor in pairs(tracked) do
                    if actor:isValid() and isAlive(actor) then
                        local aiState = actorAI:get(tostring(id))
                        local s = fighting[id]
                        local score, sight = combat.detect(actor, player, {
                            sleeping = aiState ~= nil and (aiState.sleeping or 0) >= 2,
                            inCombat = s ~= nil,
                            alert = s ~= nil and s.gun ~= nil,
                        })
                        detection[id] = { score = score, sight = sight }
                        if score > gmst('fSneakNoticedMin', -20) then noticed = true end
                        if s ~= nil and s.target == player and not s.fleeing then danger = true end
                    else
                        detection[id] = nil
                    end
                end
                local state = danger and 'danger' or (noticed and 'caution' or 'hidden')
                if detectionSection:get('state') ~= state then
                    print(('[combat] detection: %s'):format(state))
                    detectionSection:set('state', state)
                end
            end
            for id, actor in pairs(tracked) do
                if not actor:isValid() or not ai.isInScene(actor) or not isAlive(actor) then
                    if fighting[id] ~= nil then
                        print(('[combat] %s (%s) leaves combat (%s)'):format(actor.recordId, tostring(id),
                            not actor:isValid() and 'gone' or (not ai.isInScene(actor) and 'out of the scene'
                                or 'dead or cannot be hit')))
                    end
                    tracked[id] = nil
                    fighting[id] = nil
                elseif fighting[id] == nil and playerAlive and wantsFight(actor, player) then
                    startCombat(actor, player)
                    callForHelp(actor, player)
                end
            end
            if playerAlive then teammatesHelp(player) end
            for id, s in pairs(fighting) do
                if tracked[id] == nil or not s.actor:isValid() then
                    fighting[id] = nil
                else
                    fight(s)
                end
            end
        end,
    },
}
