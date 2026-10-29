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
local DODGE_DISTANCE = 128 -- the original's DODGE_LOCATION step (ghidra-findings-10)
local DODGES_BEFORE_IGNORE = 3 -- [inferred] dodges without a clear shot before IGNORE_BLOCKED_TARGET
local IGNORE_BLOCKED_TIME = 10 -- [inferred] how long a blocked target is waited out (fCombatDetectionBufferTime)
local LOS_BUFFER_TIME = 5 -- fCombatLOSBufferTime: an ally saw the target this recently
local LOS_ALLY_RANGE = 8192 -- FUN_0099f480 ignores allies further away
local MOVE_TO_ACTOR_BUFFER = 64 -- fCombatMoveToActorBufferDistance
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
local thrownBy = {} -- actor id -> { weapon id -> grenades thrown }
local updateExplosiveBlocked -- below
local coverTaken = {} -- cover edge key -> actor id (one actor per cover)
local releaseCover -- below
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
    s.flushed = true
    s.failedCovers = {}
    s.style = combat.getCombatStyle and combat.getCombatStyle(actor) or nil
    -- grenades thrown in earlier fights are gone too
    thrownBy[actor.id] = thrownBy[actor.id] or {}
    s.thrown = thrownBy[actor.id]
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
        if releaseCover then releaseCover(s) end
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

-- How close gunmen get before they stop and shoot: the weapon's range, within reason; many FNV guns leave their
-- range at 0 [inferred: 1500 then, about where NPCs stop noticing each other]
local function gunRange(gun)
    local range = gun.maxRange or 0
    if range <= 0 then return 1500 end
    return math.min(math.max(range, 600), 2000)
end

local function approach(s, actor, target, reach, aroundObstacles)
    -- The navmesh ends where the target may not (rocks, furniture): when the route runs out short of the
    -- target, or it is close, go straight for it. Getting around something in the way needs the navmesh.
    local status = ai.status(actor)
    local toTarget = target.position - actor.position
    local close = toTarget:length() < STRAIGHT_DISTANCE
    -- a dodge in progress is left alone (run 20: the approach route replaced a side-step 0.2 s after it was sent)
    if simTime < (s.dodgeUntil or 0) and status == 'moving' then return end
    if aroundObstacles and (status == 'arrived' or status == 'nopath') then
        -- The route ended short of a clear shot: the target is blocked. The original's cheapest fix is DODGE
        -- (cost 0.1): a free spot 128 units to a side, forward or back (FUN_0099e190 mask 0xF, 128, 128;
        -- ghidra-findings-10). After a few dodges without a shot it takes IGNORE_BLOCKED_TARGET (1.5) instead
        -- [inferred count: runs 20-22 swept round a rock for a minute when no reachable spot saw the player].
        if simTime >= (s.dodgeUntil or 0) then
            if (s.dodges or 0) >= DODGES_BEFORE_IGNORE then
                s.dodges = 0
                s.ignoreBlockedUntil = simTime + IGNORE_BLOCKED_TIME
                s.goal = nil
                ai.stop(actor)
                s.replanAt = 0 -- the running MOVE step would send more orders until the next replan (run 23)
                print(('[combat] %s (%s) ignores blocked target %s for %.0f s after %d dodges'):format(
                    actor.recordId, tostring(actor.id), tostring(target.recordId), IGNORE_BLOCKED_TIME,
                    DODGES_BEFORE_IGNORE))
                return
            end
            s.dodges = (s.dodges or 0) + 1
            s.dodgeUntil = simTime + 2
            -- keep to one side; a missing path or a step that went nowhere turns to the next direction
            s.dodgeDir = s.dodgeDir or (math.random() < 0.5 and 1 or 2)
            local stuck = s.lastDodgeFrom ~= nil and (actor.position - s.lastDodgeFrom):length() < 32
            if status == 'nopath' or stuck then s.dodgeDir = s.dodgeDir % 4 + 1 end
            s.lastDodgeFrom = actor.position
            local flat = util.vector3(toTarget.x, toTarget.y, 0):normalize()
            local right = util.vector3(-flat.y, flat.x, 0)
            local dirs = { right, -right, flat, -flat }
            s.goal = nil
            ai.moveTo(actor, actor.position + dirs[s.dodgeDir] * DODGE_DISTANCE,
                { run = true, direct = false, tolerance = 32 })
        end
        return
    end
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
    if gun.automatic then
        -- 1 s bursts with a 1 s pause (ghidra-findings-7)
        s.burstUntil = s.burstUntil or simTime + 1
        if simTime >= s.burstUntil then
            delay, s.burstUntil = 1, nil
        end
    else
        -- semi-automatic: the weapon's Semi-Auto Fire Delay Min..Max, times the style's Semi-Auto Firing Delay Mult
        local min, max = gun.semiAutoDelayMin or 0, gun.semiAutoDelayMax or 0
        if max > 0 then
            local mult = s.style and s.style.semiAutoDelayMult or nil
            local m = mult and mult.max > 0 and (mult.min + math.random() * (mult.max - mult.min)) or 1
            -- the delay runs after the attack animation, which sets the pace by itself (see the tick)
            s.pendingDelay = (min + math.random() * (max - min)) * m
        else
            delay = delay + 0.4 + math.random() * 0.8
        end
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

-- What blocks the attacker's line of fire (diagnostics)
local function describeLine(actor, target)
    if combat.getLineOfFire == nil then return '?' end
    local line = combat.getLineOfFire(actor, target)
    local function v(p) return p and ('(%.0f %.0f %.0f)'):format(p.x, p.y, p.z) or '-' end
    return ('ray %s -> %s, actor at %s, target at %s, hit %s at %s'):format(v(line.from), v(line.to),
        v(actor.position), v(target.position), line.hit and (line.hitObject or 'terrain') or 'nothing',
        v(line.hitPosition))
end

-- ---------------------------------------------------------------- the combat planner (scripts/omw/fnvcombat/planner)
--
-- Every second (and whenever a step fails) the actor plans again from what it knows: the first of the original's
-- goals that yields a plan wins (FLEE, FIND_TARGET when it lost the target, KILL_TARGET, ...), and the plan's
-- first step runs as a procedure here. Grenades and launchers are planned; cover, flanking and combat items not yet.

local P = require('scripts.omw.fnvcombat.planner')
local PW = P.W
local REPLAN_EVERY = 1.0
-- seconds without noticing the target before it counts as lost (fCombatDetectionLostTime)
local function lostAfter() return gmst('fCombatDetectionLostTime', 15) end
local RECENT_LOS = 2 -- [inferred] how long a line of sight counts as recent (TARGET_360_LOS, TARGET_FLUSHED)
local STEP_TIMEOUT = 15
-- Grenades (ghidra-findings-4 §3): thrown from 256 units up to v^2/g, with no cooldown (only what the NPC
-- carries); scored at half their damage [inferred] so guns stay the usual choice. The blast-safety check latches
-- after fExplosiveProjectileBlockedWaitTime 2.5 s and is rechecked every fExplosiveProjectileBlockedResetTime 5 s.
local GRENADE_MIN = 256
local FLUSH_LAST_SEEN = 10 -- a hiding target's last-seen position is a grenade target for this long
local ACTOR_RADIUS = 32

local function lostRemoveTime()
    return gmst('fCombatTargetLostRemoveTime', 30)
end

-- How good a weapon is (ghidra-findings-6/7): its damage a second (skill-scaled damage x projectiles x shots a
-- second, grenades / 10, melee at half); a gun whose range (DNAM max range x the style's range mult, up to
-- fCombatAbsoluteMaxRangeMult) does not reach the target keeps 1/10000 of it, as does the type the style
-- forbids (Weapon Restrictions); the weapon in hand gets x1.25 so the NPC does not flip back and forth.
local function weaponDps(actor, weapon)
    if weapon == nil then return 0 end
    local skill = weapon.skill and weapon.skill >= 0 and stats.get(actor, weapon.skill) or 50
    local damage = (weapon.damage or 0) * (gmst('fDamageSkillBase', 0.5) + gmst('fDamageSkillMult', 0.5) * skill / 100)
    local rate = weapon.shotsPerSecond and weapon.shotsPerSecond > 0 and weapon.shotsPerSecond or 1
    local dps = damage * math.max(weapon.projectiles or 1, 1) * rate
    if weapon.type == PW.GRENADE then dps = dps / 10 end
    if weapon.type == PW.MINE then dps = 0 end
    if weapon.type == PW.MELEE then dps = dps * gmst('fPickupWeaponMeleeWeaponDPSMult', 0.5) end
    return math.max(dps, 0.01)
end

-- Ammunition (the original, and ghidra-findings-6): an NPC's rounds are never spent, but a gun is of use to it only
-- while it carries at least one round of a type the gun takes; without any, the gun scores as unusable, and a gun it
-- would pick up needs its ammunition with it (on the same corpse) or lying within reach, which it fetches first.
local function hasAmmoFor(actor, weapon)
    local ammoTypes = weapon.ammoTypes
    if ammoTypes == nil or #ammoTypes == 0 or not types.ESM4NPC.objectIsInstance(actor) then return true end
    local ok, inventory = pcall(types.Actor.inventory, actor)
    if not ok or inventory == nil then return true end
    for _, ammo in ipairs(ammoTypes) do
        local okCount, n = pcall(inventory.countOf, inventory, ammo.id)
        if okCount and (n or 0) > 0 then return true end
    end
    return false
end

local function takesAmmo(weapon)
    return weapon.isGun and weapon.ammoTypes ~= nil and #weapon.ammoTypes > 0
end

local function styleRange(s, weapon)
    local range = weapon.maxRange or 0
    if range <= 0 then return 1500 end
    local mult = s.style and s.style.rangeMult and s.style.rangeMult.max or 1
    if mult <= 0 then mult = 1 end
    return range * mult * gmst('fCombatAbsoluteMaxRangeMult', 4)
end

local function weaponScore(s, weapon, weaponType, distance)
    local score = weaponDps(s.actor, weapon)
    if weaponType == PW.RANGED or weaponType == PW.EXPLOSIVE then
        if distance > styleRange(s, weapon) then score = score / 10000 end
    elseif weaponType == PW.GRENADE then
        if distance > (weapon.throwRange or 0) then score = score / 10000 end
    end
    if takesAmmo(weapon) and not hasAmmoFor(s.actor, weapon) then score = score / 10000 end
    local restriction = s.style and s.style.weaponRestrictions or 0
    local melee = weaponType == PW.MELEE or weaponType == PW.HAND_TO_HAND
    if (restriction == 1 and not melee) or (restriction == 2 and melee) then score = score / 10000 end
    if s.inHand and s.inHand.id == weapon.id then score = score * 1.25 end
    return score
end

-- The NPC's best weapon of each type it carries (creatures fight hand to hand with their own attacks)
-- Combat items (ghidra-findings-5): every fCombatInventoryUpdateTimer 5 s the actor's own ingestibles (ALCH) are
-- scored; RESTORE is the one whose Self-range Health effects (archetypes 0 Value Modifier, 34 Value And Parts)
-- add up to the most magnitude x max(duration, 1), detrimental effects counting against. Food counts, Buffout
-- outranks a Super Stimpak outranks a Stimpak. BUFF (Chameleon, the Stealth Boy) is blocked by the combat style
-- flag 0x100, which every vanilla style but the Marked Men's sets (see buffScore).
local ITEM_SCAN_EVERY = 5
local AV_HEALTH = 16
local MGEF_DETRIMENTAL = 0x4
local effectsApi = core.obscript and core.obscript.effects
local restoreScores = {}
local function restoreScore(recordId)
    local cached = restoreScores[recordId]
    if cached ~= nil then return cached end
    local score = 0
    local potion = effectsApi and effectsApi.getPotion(recordId)
    for _, e in ipairs(potion and potion.effects or {}) do
        if e.range == 0 then
            local mgef = effectsApi.getMagicEffect(e.effect)
            if mgef and (mgef.archetype == 0 or mgef.archetype == 34) and mgef.actorValue == AV_HEALTH then
                local part = e.magnitude * math.max(e.duration, 1)
                if mgef.flags % (MGEF_DETRIMENTAL * 2) >= MGEF_DETRIMENTAL then part = -part end
                score = score + part
            end
        end
    end
    restoreScores[recordId] = score
    return score
end

-- BUFF (ghidra-findings-5): the same sum over the Self-range Chameleon effects (archetype 12): the Stealth Boy.
local MGEF_CHAMELEON = 12
local CSTY_NO_STEALTH_BOY = 0x100 -- "Cannot Use Stealthboy", set on every vanilla style but the Marked Men's
local buffScores = {}
local function buffScore(recordId)
    local cached = buffScores[recordId]
    if cached ~= nil then return cached end
    local score = 0
    local potion = effectsApi and effectsApi.getPotion(recordId)
    for _, e in ipairs(potion and potion.effects or {}) do
        if e.range == 0 then
            local mgef = effectsApi.getMagicEffect(e.effect)
            if mgef and mgef.archetype == MGEF_CHAMELEON then score = score + e.magnitude * math.max(e.duration, 1) end
        end
    end
    buffScores[recordId] = score
    return score
end

local function mayUseStealthBoy(s)
    local flags = s.style and s.style.flags
    -- (a style without flags is read as a vanilla one, which forbids it)
    return flags ~= nil and flags % (CSTY_NO_STEALTH_BOY * 2) < CSTY_NO_STEALTH_BOY
end

local function scanCombatItems(s)
    if simTime < (s.nextItemScan or 0) then return end
    s.nextItemScan = simTime + ITEM_SCAN_EVERY
    s.restoreItem, s.buffItem = nil, nil
    if types.ESM4Potion == nil then return end
    -- getAll takes no ESM4 type filter yet
    local ok, items = pcall(function() return types.Actor.inventory(s.actor):getAll() end)
    if not ok then return end
    local best, bestBuff = 0, 0
    local stealthBoy = mayUseStealthBoy(s)
    for _, item in ipairs(items) do
        if types.ESM4Potion.objectIsInstance(item) then
            local score = restoreScore(item.recordId)
            if score > best then best, s.restoreItem = score, item.recordId end
            if stealthBoy then
                local buff = buffScore(item.recordId)
                if buff > bestBuff then bestBuff, s.buffItem = buff, item.recordId end
            end
        end
    end
end

-- The item the planner's USE_COMBAT_ITEM goal is about: the healing item once its cooldown has run out and health
-- is below iAICombatRestoreHealthPercentage (60). The original re-arms both slots with fCombatItemBuffTimer 45 s
-- (its restore case falls through into the buff case, so fCombatItemRestoreTimer 3 never applies); kept as is.
-- The BUFF item (a Stealth Boy) goes whenever the cooldown has run out, with no condition on health.
local function combatItem(s)
    if simTime < (s.itemCooldownUntil or 0) then return nil end
    if s.restoreItem ~= nil then
        local health, max = stats.get(s.actor, 'Health'), stats.getPermanent(s.actor, 'Health')
        if max > 0 and health / max * 100 < gmst('iAICombatRestoreHealthPercentage', 60) then return s.restoreItem end
    end
    return s.buffItem
end

-- Weapons to pick up (ghidra-findings-6): every fCombatFindBetterWeaponTime 5 s (2.5 s while unarmed) the loose
-- weapons and the weapons on corpses around the actor are scored by damage a second; one beats the bar when it does
-- more than fPickupWeaponMinDPSImprovementPercent (1.5 x) the actor's best, melee weapons at half. The reach is a
-- band set by what the actor holds (ranged 512-2048, melee 256-1024, fists 256-2048), doubled while unarmed,
-- stretching with score over bar up to fPickupWeaponDistanceMinMaxDPSMult 5 [band formula inferred]. Candidates
-- rank by dps x 10000 / max(distance, 64). A gun that needs rounds the actor lacks is taken with the rounds on its
-- corpse, or the rounds lying within reach are fetched first (see hasAmmoFor); containers are not modelled yet.
local PICKUP_IDLE = 'characters/_male/idleanims/pickupgroundobject_0.3.kf'
local PICKUP_TAKE_AT = 0.3
local PICKUP_REACH = 32 + ACTOR_RADIUS + 16 -- fPickupItemDistanceFudge + the two radii
local pickupBlocked = {} -- ref id -> until (unreachable or gone)

local function ownDps(s)
    local best = math.max(stats.get(s.actor, 'MeleeDamage') or 1, 1) -- fists, once a second
    for _, weapon in ipairs(s.weapons or {}) do
        if weapon.type ~= PW.GRENADE and weapon.type ~= PW.MINE
            and not (takesAmmo(weapon) and not hasAmmoFor(s.actor, weapon)) then
            best = math.max(best, weaponDps(s.actor, weapon))
        end
    end
    return best
end

local function pickupBand(s)
    local held = s.inHand and s.inHand.type
    if held == PW.RANGED or held == PW.EXPLOSIVE then return 512, 2048 end
    if held == PW.MELEE then return 256, 1024 end
    return 256, 2048
end

local function scanPickups(s)
    local unarmed = s.inHand == nil or s.inHand.type == PW.HAND_TO_HAND
    local every = unarmed and gmst('fCombatFindBetterWeaponTime', 5) / 2 or gmst('fCombatFindBetterWeaponTime', 5)
    if simTime < (s.nextPickupScan or 0) then return end
    s.nextPickupScan = simTime + every
    s.pickup = nil
    local actor = s.actor
    -- what it carries may have changed (scripts, pickups): the original rescans the inventory on its own timer too
    if types.ESM4NPC.objectIsInstance(actor) then s.weapons = combat.getActorWeapons(actor) end
    if actor.cell == nil or not types.ESM4NPC.objectIsInstance(actor) or types.ESM4Weapon == nil then return end
    local bar = ownDps(s) * (1 + gmst('fPickupWeaponMinDPSImprovementPercent', 0.5))
    if s.disarmed ~= nil then bar = math.min(bar, s.disarmed.dps) end
    local minDist, maxDist = pickupBand(s)
    if unarmed then minDist, maxDist = minDist * gmst('fDisarmedPickupWeaponDistanceMult', 2),
        maxDist * gmst('fDisarmedPickupWeaponDistanceMult', 2) end
    local best, bestRank = nil, 0
    local looseAmmo -- the ammunition lying around, gathered when a gun first needs it
    local cells = { actor.cell }
    if actor.cell.isExterior then
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local ok, cell = pcall(world.getExteriorCell, actor.cell.gridX + dx, actor.cell.gridY + dy, actor.cell)
                    if ok and cell then cells[#cells + 1] = cell end
                end
            end
        end
    end
    -- the nearest ammunition for the gun lying within reach, or nil
    local function nearestAmmo(rec, reach)
        if looseAmmo == nil then
            looseAmmo = {}
            if types.ESM4Ammunition ~= nil then
                for _, cell in ipairs(cells) do
                    local ok, list = pcall(cell.getAll, cell, types.ESM4Ammunition)
                    for _, obj in ipairs(ok and list or {}) do looseAmmo[#looseAmmo + 1] = obj end
                end
            end
        end
        local nearest, nearestDistance
        for _, obj in ipairs(looseAmmo) do
            if obj:isValid() and obj.count > 0 and simTime >= (pickupBlocked[obj.id] or 0) then
                for _, ammo in ipairs(rec.ammoTypes) do
                    if ammo.id == obj.recordId then
                        local d = (obj.position - actor.position):length()
                        if d <= reach and (nearestDistance == nil or d < nearestDistance) then
                            nearest, nearestDistance = obj, d
                        end
                    end
                end
            end
        end
        return nearest
    end
    local function holderHasAmmo(holder, rec)
        local okItems, items = pcall(function() return types.Actor.inventory(holder):getAll() end)
        for _, item in ipairs(okItems and items or {}) do
            for _, ammo in ipairs(rec.ammoTypes) do
                if ammo.id == item.recordId and item.count > 0 then return true end
            end
        end
        return false
    end
    -- obj: the weapon (loose, on the corpse `holder`, or `carried` already); the pickup is the weapon, or the
    -- ammunition it needs first
    local function consider(obj, holder, carried)
        if not carried and (not obj:isValid() or obj.count <= 0) then return end
        local rec = carried and obj or combat.getWeapon(obj.recordId)
        if rec == nil then return end
        local dps = weaponDps(actor, rec)
        if dps <= bar then return end
        local where = carried and actor.position or holder and holder.position or obj.position
        local distance = (where - actor.position):length()
        local ammoNeeded = takesAmmo(rec) and not hasAmmoFor(actor, rec)
        if ammoNeeded and holder ~= nil and not carried then
            -- a corpse's gun comes with the rounds on the corpse, or stays
            if not holderHasAmmo(holder, rec) then return end
            ammoNeeded = false
        end
        -- the band opens with the margin over the bar: fully at fPickupWeaponDistanceMinMaxDPSMult 5 x
        local over = math.min(dps / bar, gmst('fPickupWeaponDistanceMinMaxDPSMult', 5))
        local reach = minDist + (maxDist - minDist) * math.max(over - 1, 0) / (gmst('fPickupWeaponDistanceMinMaxDPSMult', 5) - 1)
        if distance > reach then return end
        if not carried and simTime < (pickupBlocked[obj.id] or 0) then return end
        local target, forGun = obj, nil
        if ammoNeeded then
            -- the rounds first (the original fills its ammunition slot before the weapon slot)
            target = nearestAmmo(rec, reach)
            if target == nil then return end
            forGun = rec.editorId
            where = target.position
            distance = (where - actor.position):length()
        elseif carried then
            return
        end
        if s.threat and (where - s.threat):length() <= 128 then return end
        local rank = dps * 10000 / math.max(distance, 64)
        if rank > bestRank then
            bestRank = rank
            best = { obj = target, holder = (not ammoNeeded) and holder or nil, position = where,
                key = 'pickup:' .. tostring(target.id), editorId = ammoNeeded and target.recordId or rec.editorId,
                forGun = forGun, dps = dps }
        end
    end
    -- rounds for a gun it carries dry
    for _, weapon in ipairs(s.weapons or {}) do
        if takesAmmo(weapon) then consider(weapon, nil, true) end
    end
    for _, cell in ipairs(cells) do
        local ok, loose = pcall(cell.getAll, cell, types.ESM4Weapon)
        for _, obj in ipairs(ok and loose or {}) do consider(obj, nil) end
        local okNpcs, npcs = pcall(cell.getAll, cell, types.ESM4NPC)
        for _, npc in ipairs(okNpcs and npcs or {}) do
            if npc ~= actor and combat.isDead(npc) and (npc.position - actor.position):length() <= maxDist then
                local okItems, items = pcall(function() return types.Actor.inventory(npc):getAll() end)
                for _, item in ipairs(okItems and items or {}) do
                    if types.ESM4Weapon.objectIsInstance(item) then consider(item, npc) end
                end
            end
        end
    end
    if best and (s.pickupLogged ~= best.key) then
        s.pickupLogged = best.key
        print(('[combat] %s (%s) wants to pick up %s%s (%.1f dps over %.1f) %.0f away%s'):format(actor.recordId,
            tostring(actor.id), tostring(best.editorId), best.forGun and (' for ' .. best.forGun) or '', best.dps, bar,
            (best.position - actor.position):length(), best.holder and (' from ' .. tostring(best.holder.recordId)) or ''))
    end
    s.pickup = best
end

local function bestWeapons(s, distance)
    local best = {}
    for _, weapon in ipairs(s.weapons or {}) do
        local t = weapon.type
        -- grenades while some are left; mines are not used
        local usable = t == PW.RANGED or t == PW.MELEE or t == PW.HAND_TO_HAND
            or (t == PW.EXPLOSIVE and weapon.isGun)
            or (t == PW.GRENADE and weapon.explosive and (s.thrown[weapon.id] or 0) < (weapon.count or 1))
        if usable then
            local score = weaponScore(s, weapon, t, distance)
            if best[t] == nil or score > best[t].score then best[t] = { weapon = weapon, score = score } end
        end
    end
    if next(best) == nil then best[PW.HAND_TO_HAND] = { score = 1 } end
    return best
end

-- How far the actor's grenades go (the shortest throw of those it has), 0 without any
local function throwRange(s)
    local range
    for _, weapon in ipairs(s.weapons or {}) do
        if weapon.type == PW.GRENADE and weapon.explosive and (weapon.throwRange or 0) > 0 then
            range = math.min(range or math.huge, weapon.throwRange)
        end
    end
    return range or 0
end

-- The blast radius that matters for safety (FalloutNV.exe 0x992720): the largest of its explosives
local function blastRadius(s)
    local radius = 0
    for _, weapon in ipairs(s.weapons or {}) do
        if weapon.explosive then radius = math.max(radius, weapon.blastRadius or 0) end
    end
    return radius
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
    return simTime - (s.lastSeenAt or s.since) > lostAfter()
end

local function inGunRange(s, distance)
    return s.gun ~= nil and distance <= gunRange(s.gun)
end

-- Cover (ghidra-findings-4 §1): USE_COVER is rolled every 10 s with the combat style's Take Cover Chance; a
-- cover search that found nothing keeps it off for a few seconds [inferred: the original remembers failed edges
-- for 3 s]
local COVER_ROLL_EVERY = 10
local function coverWanted(s)
    if simTime >= (s.nextCoverRoll or 0) then
        s.nextCoverRoll = simTime + COVER_ROLL_EVERY
        local chance = s.style and s.style.takeCoverChance or 0
        s.useCover = chance > 0 and math.random() * 100 < chance
    end
    return s.useCover and types.ESM4NPC.objectIsInstance(s.actor)
end

releaseCover = function(s)
    local c = s.cover
    if c and coverTaken[c.key] == s.actor.id then coverTaken[c.key] = nil end
    s.cover, s.inCoverLoop = nil, false
    if s.crouched then
        s.crouched = false
        if combat.setCrouched and s.actor:isValid() then combat.setCrouched(s.actor, false) end
    end
end

-- The range band cover is searched in (FalloutNV.exe 0x9a9180): the gun's range, else 512-1024
local function coverBand(s)
    local gun = s.gun or (s.best and s.best[PW.RANGED] and s.best[PW.RANGED].weapon)
    local min, max = 512, 1024
    if gun then
        max = gun.maxRange and gun.maxRange > 0 and gun.maxRange or gunRange(gun)
        min = math.max(0, math.min(gun.minRange or 0, max - 256))
    end
    local absMax = max * gmst('fCombatAbsoluteMaxRangeMult', 4)
    return math.max(min, 512), math.min(max * gmst('fCombatCoverMaxRangeMult', 1.5), absMax)
end

local function findCover(s)
    local excluded = {}
    for key, owner in pairs(coverTaken) do
        if owner ~= s.actor.id then excluded[#excluded + 1] = key end
    end
    s.failedCovers = s.failedCovers or {}
    for key, at in pairs(s.failedCovers) do
        if simTime - at < 3 then excluded[#excluded + 1] = key end
    end
    local min, max = coverBand(s)
    local found = combat.findCover(s.actor, s.target, {
        searchRadius = s.style and s.style.coverSearchRadius > 0 and s.style.coverSearchRadius or 2048,
        minDistance = min, maxDistance = max, fire = true, excluded = excluded })
    if found then
        releaseCover(s)
        coverTaken[found.key] = s.actor.id
        s.cover = found
        if s.coverLogged ~= found.key then
            s.coverLogged = found.key
            print(('[combat] %s (%s) finds cover %s, %.0f from %s (cover %s, fire %s)'):format(s.actor.recordId,
                tostring(s.actor.id), found.key, (found.cover - s.target.position):length(),
                tostring(s.target.recordId), tostring(found.cover), tostring(found.fire)))
        end
    end
    return found
end

local function worldState(s, distance, los)
    local P_F, L = P.F, P.L
    local best = s.best
    local function at(kind)
        if kind == L.TARGET then
            -- a gunman has not reached its target while something blocks the shot: run 18 had one standing 127
            -- units from the player behind a rock, "arrived" and never firing
            if s.gun ~= nil then
                return (los and inGunRange(s, distance)) or simTime < (s.ignoreBlockedUntil or 0)
            end
            return distance <= closeEnough(s, los)
        end
        if kind == L.MELEE then return distance <= meleeReach(s) end
        if kind == L.FLEE then return distance >= FLEE_DISTANCE end
        if kind == L.LOS then
            if los and (s.gun == nil or inGunRange(s, distance)) then return true end
            local ally = s.losAlly
            return ally ~= nil and ally:isValid()
                and (s.actor.position - ally.position):length() <= 2 * ACTOR_RADIUS + MOVE_TO_ACTOR_BUFFER
        end
        if kind == L.INVESTIGATE then
            return s.searchPos ~= nil and (s.actor.position - s.searchPos):length() <= 128
        end
        if kind == L.AVOID_THREAT then return s.threat == nil end
        if s.pickup and kind == s.pickup.key then
            return (s.actor.position - s.pickup.position):length() <= PICKUP_REACH
        end
        if kind == L.COVER then
            local c = s.cover
            return c ~= nil and (s.inCoverLoop or (s.actor.position - c.cover):length() <= 40
                or (s.actor.position - c.fire):length() <= 40)
        end
        return kind == L.DESTINATION or kind == L.GUARD or kind == L.CLUSTER or kind == L.COMBAT_AREA
    end
    return function(fact, param)
        if fact == P_F.TARGET_DEAD then return isAlive(s.target) and 0 or 1 end
        if fact == P_F.AT_LOCATION then return at(param) and 1 or 0 end
        if fact == P_F.NOT_AT_LOCATION then return at(param) and 0 or 1 end
        if fact == P_F.TARGET_LOST then return targetLost(s) and 1 or 0 end
        if fact == P_F.TARGET_DETECTED then return targetLost(s) and 0 or 1 end
        if fact == P_F.TARGET_360_LOS then
            if not los then return 0 end
            if s.drawnType == PW.RANGED or s.drawnType == PW.EXPLOSIVE then return inGunRange(s, distance) and 1 or 0 end
            if s.drawnType == PW.GRENADE then return distance <= throwRange(s) and 1 or 0 end
            return 1
        end
        -- the blast would hurt the actor, its side or bystanders (latched), or the target is out of throwing range
        if fact == P_F.EXPLOSIVE_PROJECTILE_BLOCKED then
            return (s.explBlocked or distance < GRENADE_MIN or distance > throwRange(s)) and 1 or 0
        end
        -- out in the open while seen; a target that has gone out of sight is hiding, and a grenade flushes it out
        if fact == P_F.TARGET_FLUSHED then return s.flushed and 1 or 0 end
        if fact == P_F.TARGET_SPACE_DIFFERENT then
            return (s.target.cell ~= nil and s.actor.cell ~= nil and not (s.target.cell.isExterior and s.actor.cell.isExterior)
                and s.target.cell.id ~= s.actor.cell.id) and 1 or 0
        end
        if fact == P_F.THREATENED then return s.threat ~= nil and 1 or 0 end
        if fact == P_F.WEAPON_DRAWN then return s.drawnType end
        if fact == P_F.WEAPON_TYPE_EQUIPPED then return s.equippedType end
        if fact == P_F.HAS_WEAPON_TYPE then return best[param] ~= nil and 1 or 0 end
        if fact == P_F.WANTS_TO_FLEE then return s.fleeing and 1 or 0 end
        -- the original never writes USED_COMBAT_ITEM; the goal stops once the cooldown re-arms
        if fact == P_F.HAS_COMBAT_ITEM then return (param ~= nil and param == s.restoreItem) and 1 or 0 end
        -- a weapon to pick up is never "used": the USE goal passes it by, ACTIVATE fetches it
        if fact == P_F.USED_COMBAT_ITEM then return (s.pickup and param == s.pickup.key) and 1 or 0 end
        if fact == P_F.EXECUTION_FLAGS then
            if param == P.X.COVER then return coverWanted(s) and 1 or 0 end
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
    local L = P.L
    return function(action, param)
        -- a move costs its path (ghidra-findings-9): clamp((distance / 768)^2, 0.01, 1e6) for the target, melee
        -- range, cover and the search spot; so near cover beats far cover, and shooting from where it stands beats
        -- a long walk to cover
        if action.move then
            local to
            if param == L.TARGET or param == L.MELEE then to = s.target.position
            elseif param == L.COVER then to = s.cover and s.cover.cover
            elseif param == L.INVESTIGATE then to = s.searchPos
            elseif param == L.LOS then to = s.losAlly and s.losAlly:isValid() and s.losAlly.position or nil
            elseif s.pickup and param == s.pickup.key then to = s.pickup.position end
            if to == nil then return action.cost end
            local d = (to - s.actor.position):length() / 768
            return action.cost + math.min(math.max(d * d, 0.01), 1e6)
        end
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

-- FUN_0099f480: the nearest member of the actor's combat group (here: others fighting the same target on the
-- same side) within 8192 that saw the target within fCombatLOSBufferTime 5 s. The current one is kept while it
-- still qualifies.
local function losAlly(s)
    local function qualifies(o)
        return o ~= s and o.actor:isValid() and isAlive(o.actor) and o.target == s.target and not o.fleeing
            and simTime - (o.lastLosAt or -math.huge) <= LOS_BUFFER_TIME
            and (o.actor.position - s.actor.position):length() <= LOS_ALLY_RANGE
    end
    if s.losAlly ~= nil then
        local o = fighting[s.losAlly.id]
        if o ~= nil and qualifies(o) then return s.losAlly end
    end
    local best, bestD
    for _, o in pairs(fighting) do
        if qualifies(o) then
            local d = (o.actor.position - s.actor.position):length()
            if bestD == nil or d <= bestD then best, bestD = o.actor, d end
        end
    end
    return best
end

local checkDisarm -- below, with the weapon drops

local function replan(s, distance, los)
    if s.refreshWeaponsUntil then
        s.weapons = combat.getActorWeapons(s.actor)
        if simTime > s.refreshWeaponsUntil then s.refreshWeaponsUntil = nil end
    end
    s.best = bestWeapons(s, distance)
    local actorType = s.equippedType
    if actorType == PW.NONE then actorType = PW.HAND_TO_HAND end
    local weaponTypes = {}
    for t in pairs(s.best) do weaponTypes[#weaponTypes + 1] = t end
    local locations = { P.L.TARGET, P.L.MELEE, P.L.FLEE, P.L.INVESTIGATE, P.L.AVOID_THREAT }
    -- ACQUIRE_LINE_OF_SIGHT walks to an ally that sees the target; a lone actor never gets it (ghidra-findings-10)
    s.losAlly = losAlly(s)
    if s.losAlly ~= nil then locations[#locations + 1] = P.L.LOS end
    -- cover is searched while planning (ghidra-findings-9): the cover plan is only on offer when a spot exists,
    -- and a failed search is forgotten with the pass (only the failed spots are remembered, for 3 s)
    if coverWanted(s) and not s.inCoverLoop and s.cover == nil then findCover(s) end
    if coverWanted(s) and s.cover ~= nil then locations[#locations + 1] = P.L.COVER end
    checkDisarm(s)
    scanCombatItems(s)
    scanPickups(s)
    local item = combatItem(s)
    if item == nil and s.pickup and not s.fleeing then
        item = s.pickup.key
        locations[#locations + 1] = s.pickup.key
    end
    local ctx = { actorType = actorType, locations = locations, item = item,
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
    local usesCover = false
    for _, step in ipairs(plan) do
        labels[#labels + 1] = stepLabel(step)
        if step.param == P.L.COVER or step.name:sub(-10) == 'FROM_COVER' then usesCover = true end
    end
    -- a spot found for this pass but not used goes back for others; it is searched again next pass
    if not usesCover and s.cover ~= nil and not s.inCoverLoop then releaseCover(s) end
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
    if (weaponType == PW.RANGED or weaponType == PW.EXPLOSIVE) and s.inHand and s.inHand.isGun then
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
    if kind == L.COVER then
        if s.cover == nil then return 'failed' end
        if (actor.position - s.cover.cover):length() <= 40 then
            holdStill(actor)
            return 'done'
        end
        if not state.sent or ai.status(actor) == 'idle' then
            state.sent = true
            ai.moveTo(actor, s.cover.cover, { run = true, direct = true, tolerance = 24 })
        elseif ai.status(actor) == 'nopath' then
            s.failedCovers[s.cover.key] = simTime
            releaseCover(s)
            return 'failed'
        end
        return 'running'
    end
    if s.pickup and kind == s.pickup.key then
        local obj = s.pickup.obj
        if not obj:isValid() or obj.count <= 0 then
            s.pickup, s.nextPickupScan = nil, 0
            return 'failed'
        end
        if (actor.position - s.pickup.position):length() <= PICKUP_REACH then
            holdStill(actor)
            return 'done'
        end
        if not state.sent or ai.status(actor) == 'idle' then
            state.sent = true
            ai.moveTo(actor, s.pickup.position, { run = true, direct = true, tolerance = 24 })
        elseif ai.status(actor) == 'nopath' then
            pickupBlocked[obj.id] = simTime + 30
            s.pickup, s.nextPickupScan = nil, 0
            return 'failed'
        end
        return 'running'
    end
    if kind == L.AVOID_THREAT then
        if s.threat == nil then
            holdStill(actor)
            return 'done'
        end
        if simTime >= (state.nextMove or 0) then
            -- run from the grenade, a little more than its likely blast
            state.nextMove = simTime + 0.5
            local away = actor.position - s.threat
            away = util.vector3(away.x, away.y, 0)
            if away:length() < 1 then away = util.vector3(1, 0, 0) end
            ai.moveTo(actor, actor.position + away:normalize() * 600,
                { run = true, direct = true, straight = true, tolerance = 64 })
        end
        return 'running'
    end
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
    if kind == L.LOS and s.losAlly ~= nil then
        local ally = s.losAlly
        if not ally:isValid() then return 'failed' end
        if los and (s.gun == nil or inGunRange(s, distance)) then return 'done' end
        if (actor.position - ally.position):length() <= 2 * ACTOR_RADIUS + MOVE_TO_ACTOR_BUFFER then
            holdStill(actor)
            return 'done'
        end
        if not state.sent or ai.status(actor) == 'idle' or simTime >= (state.resend or 0) then
            state.sent, state.resend = true, simTime + 1
            ai.moveTo(actor, ally.position, { run = true, direct = true,
                tolerance = 2 * ACTOR_RADIUS + MOVE_TO_ACTOR_BUFFER })
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
        if los and (s.gun == nil or inGunRange(s, distance)) or kind == L.TARGET and s.gun == nil and distance <= reach
        then
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
    if s.gun ~= nil and not los and distance < 1000 and not s.blockedLogged then
        s.blockedLogged = true
        print(('[combat] %s (%s) has no line of fire to %s at %.0f: %s'):format(actor.recordId, tostring(actor.id),
            tostring(target.recordId), distance, describeLine(actor, target)))
    end
    if s.gun ~= nil and not los and simTime < (s.ignoreBlockedUntil or 0) then
        -- IGNORE_BLOCKED_TARGET: wait it out where it stands, aimed at the target [inferred]
        holdStill(actor)
        ai.face(actor, yawTo(actor.position, target.position))
        return 'running'
    end
    if s.gun == nil or not los or not inGunRange(s, distance) then return 'failed' end
    s.dodges = 0
    s.ignoreBlockedUntil = nil
    s.straight = false
    holdStill(actor)
    ai.face(actor, yawTo(actor.position, target.position))
    if simTime >= s.nextAttack then shootAt(s, actor, target) else s.fireNow = true end
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
        -- In reach the original rolls attack / block / hold each decision (ghidra-findings-7): attack = Attack % +
        -- 20 x skill/100 (plus bonuses), block = Block % x fBlockScoreNoShieldMult 0.5, x0.25 more when not under
        -- attack, hold = max(100 - attack - block, 30). Blocks are not animated yet, so a block is a hold here.
        local style = s.style
        local skill = s.inHand and s.inHand.skill and s.inHand.skill >= 0 and stats.get(actor, s.inHand.skill) or 50
        local attack = (style and style.attackChance or 40) + 20 * skill / 100
        local block = (style and style.blockChance or 30) * gmst('fBlockScoreNoShieldMult', 0.5)
        local underAttack = simTime - (s.lastHitAt or -math.huge) <= 1.5
        if not underAttack then block = block * 0.25 end
        local hold = math.max(100 - attack - block, 30)
        local roll = math.random() * (attack + block + hold)
        if roll < attack then
            s.nextAttack = simTime + 1.2 + math.random() * 0.8
            combat.attack(actor, target, reach)
        else
            -- hold (or block) for the style's Hold Timer [0.5-1.5 s in the default style]
            s.nextAttack = simTime + 0.5 + math.random()
        end
    end
    return 'running'
end

-- The blast-safety check (FalloutNV.exe 0x992720): an explosion at the target would hurt the actor, someone on
-- its side, or (with Responsibility >= iAvoidHurtingNonTargetsResponsibility 50) a bystander. Latched after
-- fExplosiveProjectileBlockedWaitTime of failing, cleared on a recheck every fExplosiveProjectileBlockedResetTime.
local function blastUnsafe(s)
    local radius = blastRadius(s)
    if radius <= 0 then return false end
    local actor, target = s.actor, s.target
    local at = target.position
    local function near(other) return (other.position - at):length() <= radius + ACTOR_RADIUS end
    if near(actor) then return true end
    local careful = stats.get(actor, 'Responsibility') >= gmst('iAvoidHurtingNonTargetsResponsibility', 50)
    for id, other in pairs(tracked) do
        if other ~= actor and other ~= target and other:isValid() and isAlive(other) and near(other) then
            local f = fighting[id]
            local sameSide = (f ~= nil and f.target == target) or (onPlayerSide(actor) and onPlayerSide(other))
            if sameSide or careful then return true end
        end
    end
    local player = world.players[1]
    if player ~= nil and player ~= target and onPlayerSide(actor) and near(player) then return true end
    return false
end

updateExplosiveBlocked = function(s, distance)
    if blastRadius(s) <= 0 then return end
    if s.explBlocked then
        if simTime >= (s.explRecheckAt or 0) then
            s.explRecheckAt = simTime + gmst('fExplosiveProjectileBlockedResetTime', 5)
            if not blastUnsafe(s) then
                s.explBlocked = false
                s.replanAt = 0
            end
        end
        return
    end
    if blastUnsafe(s) then
        s.unsafeSince = s.unsafeSince or simTime
        if simTime - s.unsafeSince >= gmst('fExplosiveProjectileBlockedWaitTime', 2.5) then
            s.explBlocked = true
            s.explRecheckAt = simTime + gmst('fExplosiveProjectileBlockedResetTime', 5)
            s.replanAt = 0
        end
    else
        s.unsafeSince = nil
    end
end

-- Throws the grenade in hand at the target (or where it hides, to flush it out)
local function throwGrenade(s, distance, flush)
    local actor, target = s.actor, s.target
    local state = s.stepState
    if state.thrownAt then
        return simTime >= state.thrownAt + 1.2 and 'done' or 'running'
    end
    if s.inHand == nil or not s.inHand.explosive or distance < GRENADE_MIN or distance > throwRange(s) then
        return 'failed'
    end
    -- the target where it is if seen, else where it was last seen up to FLUSH_LAST_SEEN s ago
    local at
    if not s.recentLos then
        if s.lastLosPos == nil or simTime - (s.lastLosAt or -math.huge) > FLUSH_LAST_SEEN then return 'failed' end
        at = s.lastLosPos
    end
    holdStill(actor)
    ai.face(actor, yawTo(actor.position, (at or target.position)))
    combat.launchAt(actor, target, at)
    state.thrownAt = simTime
    s.thrown[s.inHand.id] = (s.thrown[s.inHand.id] or 0) + 1
    -- [inferred] one throw per hiding: the target counts as flushed until it is seen and hides again
    s.flushed, s.hidingHandled = true, true
    print(('[combat] %s (%s) throws %s at %s from %.0f%s'):format(actor.recordId, tostring(actor.id),
        tostring(s.inHand.editorId), tostring(target.recordId), distance, flush and ' to flush it out' or ''))
    return 'running'
end

-- A combat style timer, with defaults when the style leaves it at 0 [inferred]
local function styleTimer(s, name, defaultMin, defaultMax)
    local range = s.style and s.style[name]
    local min, max = range and range.min or 0, range and range.max or 0
    if max <= 0 then min, max = defaultMin, defaultMax end
    return min + math.random() * (max - min)
end

-- CombatProcedureBeInCover (FalloutNV.exe 0x9d25b0): wait behind cover, step out to the fire point, wait to
-- fire, fire for a while, step back in; reload behind cover under fCoverWaitReloadClipPercent 0.33, go back in
-- under fCoverFiringReloadClipPercent 0.25. When the target can see the cover point, hold 2 s and give it up.
local function beInCover(s, distance, los, grenade)
    local actor, target, c, st = s.actor, s.target, s.cover, s.stepState
    if c == nil then return 'failed' end
    s.inCoverLoop = true
    st.phase = st.phase or 'movingIn'
    local function fail()
        s.failedCovers[c.key] = simTime
        releaseCover(s)
        return 'failed'
    end
    if st.phase ~= st.loggedPhase then
        st.loggedPhase = st.phase
        print(('[combat] %s (%s) cover: %s (%.0f from %s, line of fire %s; %s)'):format(actor.recordId,
            tostring(actor.id), st.phase, distance, tostring(target.recordId), tostring(los),
            describeLine(actor, target)))
    end
    local function near(point) return (actor.position - point):length() <= 40 end
    local function go(point)
        if not st.sent or ai.status(actor) == 'idle' then
            st.sent = true
            ai.moveTo(actor, point, { run = true, direct = true, tolerance = 24 })
        end
    end
    if st.phase == 'waiting' and simTime >= (st.nextCheck or 0) then
        st.nextCheck = simTime + 1
        if combat.canTargetSee(actor, target, actor.position) then
            st.holdUntil = st.holdUntil or simTime + 2
        else
            st.holdUntil = nil
        end
    end
    if st.holdUntil and (simTime >= st.holdUntil or (distance < 512 and simTime >= st.holdUntil - 1.5)) then
        return fail() -- Target has LOS on Cover position
    end
    if st.phase == 'movingIn' then
        if near(c.cover) then
            holdStill(actor)
            -- crouch behind it (low cover hides a crouched actor only)
            s.crouched = combat.setCrouched ~= nil and combat.setCrouched(actor, true)
            st.phase, st.sent = 'waiting', false
            st.untilT = simTime + styleTimer(s, 'waitTimer', 1, 3)
        else
            go(c.cover)
        end
    elseif st.phase == 'waiting' then
        ai.face(actor, yawTo(actor.position, target.position))
        if s.gun and s.gun.clipSize > 0 and s.clip < s.gun.clipSize * gmst('fCoverWaitReloadClipPercent', 0.33)
            and not st.reloaded then
            combat.reload(actor)
            s.clip = s.gun.clipSize
            st.reloaded = true
        end
        if simTime >= st.untilT then
            if s.crouched then
                s.crouched = false
                combat.setCrouched(actor, false)
            end
            st.phase, st.sent = 'movingOut', false
        end
    elseif st.phase == 'movingOut' then
        if near(c.fire) then
            holdStill(actor)
            st.phase, st.fired = 'out', false
            st.untilT = simTime + styleTimer(s, 'waitToFireTimer', 0.5, 1.5)
        else
            go(c.fire)
        end
    elseif st.phase == 'out' then
        ai.face(actor, yawTo(actor.position, target.position))
        if los and simTime >= s.nextAttack then
            if grenade then
                if not st.fired and s.inHand and s.inHand.explosive then
                    combat.launchAt(actor, target)
                    s.thrown[s.inHand.id] = (s.thrown[s.inHand.id] or 0) + 1
                    print(('[combat] %s (%s) throws %s at %s from cover'):format(actor.recordId, tostring(actor.id),
                        tostring(s.inHand.editorId), tostring(target.recordId)))
                    st.fired, st.untilT = true, simTime + 1.2
                end
            elseif s.gun then
                shootAt(s, actor, target)
                if not st.fired then
                    st.fired = true
                    st.untilT = simTime + styleTimer(s, 'fireTimer', 1.5, 3)
                end
            end
        elseif los and not grenade and s.gun then
            s.fireNow = true -- the shot itself runs every frame (see onUpdate)
        end
        if not st.fired and simTime >= st.untilT then
            print(('[combat] %s (%s) waited out of cover without firing'):format(actor.recordId, tostring(actor.id)))
            return fail() -- Waited out of cover without firing
        end
        local lowClip = s.gun and s.gun.clipSize > 0
            and s.clip < s.gun.clipSize * gmst('fCoverFiringReloadClipPercent', 0.25)
        if st.fired and (simTime >= st.untilT or lowClip) then
            st.phase, st.sent, st.reloaded = 'movingIn', false, false
        end
    end
    return 'running'
end

-- CombatProcedureUseCombatItem (FalloutNV.exe 0x9daab0): stand still; only the Stimpak has an idle
-- (3rdP_2HH_Stimpak.kf, 3.83 s), everything else is used at once; then re-arm the cooldown and consume it. The
-- ingestible goes through the same path as the player's (effects applied, one removed), without addiction.
local STIMPAK_IDLE = 'characters/_male/idleanims/3rdp_2hh_stimpak.kf'
local function useCombatItem(s, step)
    local actor, st = s.actor, s.stepState
    local recordId = step.param
    if recordId == nil then return 'failed' end
    holdStill(actor)
    if not st.started then
        st.started = true
        local potion = effectsApi and effectsApi.getPotion(recordId)
        local editorId = potion and potion.editorId or ''
        st.until_ = simTime
        if editorId:lower() == 'stimpak' and ai.playIdle then
            ai.playIdle(actor, STIMPAK_IDLE)
            st.until_ = simTime + 3.83
        end
        print(('[combat] %s (%s) uses %s at %.0f/%.0f health'):format(actor.recordId, tostring(actor.id),
            editorId ~= '' and editorId or tostring(recordId), stats.get(actor, 'Health'),
            stats.getPermanent(actor, 'Health')))
    end
    if simTime < st.until_ then return 'running' end
    s.itemCooldownUntil = simTime + gmst('fCombatItemBuffTimer', 45)
    s.nextItemScan = 0
    local ok, item = pcall(function() return types.Actor.inventory(actor):find(recordId) end)
    if ok and item ~= nil and I.FNVEffects then
        item:remove(1)
        I.FNVEffects.applyPotion(actor, recordId)
    end
    return 'done'
end

-- The NPC drops the weapon in its hands beside it, where the living can pick it up; the weapon's visible copy on
-- the body goes with it. @return the weapon record dropped, or nil
local function dropHeldWeapon(target)
    if not types.ESM4NPC.objectIsInstance(target) or target.cell == nil then return nil end
    local weapon = combat.getActorWeapon(target)
    if weapon == nil or weapon.type == PW.HAND_TO_HAND then return nil end
    local ok, item = pcall(function() return types.Actor.inventory(target):find(weapon.id) end)
    if not ok or item == nil then return nil end
    local angle = math.random() * 2 * math.pi
    local at = target.position + util.vector3(math.cos(angle) * 40, math.sin(angle) * 40, 8)
    local okDrop = pcall(function()
        local one = item.count > 1 and item:split(1) or item
        one:teleport(target.cell, at, { rotation = util.transform.rotateZ(math.random() * 2 * math.pi) })
    end)
    if not okDrop then return nil end
    pcall(combat.equipWeapon, target, nil)
    print(('[combat] %s (%s) drops %s'):format(target.recordId, tostring(target.id), tostring(weapon.editorId)))
    return weapon
end

-- A dying NPC drops the weapon in its hands with iDeathDropWeaponChance (100 in the ESM).
local function dropWeaponOnDeath(target)
    if math.random(0, 99) >= gmst('iDeathDropWeaponChance', 0) then return end
    dropHeldWeapon(target)
end

-- Disarm (ghidra-findings-6, hook 0x97f6d0): an NPC whose weapon arm is crippled (the left counts too for a
-- two-handed weapon) drops what it holds. It remembers the weapon's damage a second, and its search for a weapon to
-- pick up starts fCombatDisarmedFindBetterWeaponInitialTime 1 s later with a bar of min(1.5 x what it has left,
-- that), so the dropped weapon itself qualifies, over twice the reach (fDisarmedPickupWeaponDistanceMult). [The
-- original's other causes, a disarming hit and a weapon breaking, have no counterpart here yet.]
local TWO_HANDED_ANIM_TYPES = { [2] = true, [5] = true, [6] = true, [8] = true, [9] = true }
checkDisarm = function(s)
    local actor = s.actor
    if not types.ESM4NPC.objectIsInstance(actor) then return end
    local right = (stats.get(actor, 'RightAttackCondition') or 1) <= 0
    local left = (stats.get(actor, 'LeftAttackCondition') or 1) <= 0
    local held = s.inHand
    if held ~= nil and held.type ~= PW.HAND_TO_HAND then
        -- a newly crippled arm (one crippled already when the weapon was taken up is lived with)
        local twoHanded = TWO_HANDED_ANIM_TYPES[held.animType or 0] == true
        local crippledNow = (right and not s.rightArmCrippled) or (twoHanded and left and not s.leftArmCrippled)
        if crippledNow then
            local lostDps = weaponDps(actor, held)
            if dropHeldWeapon(actor) ~= nil then
                s.disarmed = { dps = lostDps, at = simTime }
                s.inHand, s.gun = nil, nil
                s.equippedType, s.drawnType = PW.HAND_TO_HAND, PW.HAND_TO_HAND
                s.refreshWeaponsUntil = simTime + 1.5
                s.nextPickupScan = simTime + gmst('fCombatDisarmedFindBetterWeaponInitialTime', 1)
                s.replanAt = simTime
                print(('[combat] %s (%s) is disarmed: %s arm crippled'):format(actor.recordId, tostring(actor.id),
                    right and 'right' or 'left'))
            end
        end
    elseif s.disarmed ~= nil and held ~= nil then
        s.disarmed = nil
    end
    s.rightArmCrippled, s.leftArmCrippled = right, left
end

-- CombatProcedureActivateObject (FalloutNV.exe 0x9ca760): the pickup idle (PickUpGroundObject_0.3) and the item
-- taken at its 0.3 s mark; from a corpse the whole stack, with its ammo [the original takes every slotted item].
-- Nothing equips it here: once it is the best of its type, the next plan switches to it (SWITCH_WEAPON).
local function activateCombatItem(s, step)
    local actor, st = s.actor, s.stepState
    local pickup = s.pickup
    if pickup == nil or step.param ~= pickup.key then return 'failed' end
    local obj = pickup.obj
    if not obj:isValid() or obj.count <= 0 then
        s.pickup, s.nextPickupScan = nil, 0
        return 'failed'
    end
    holdStill(actor)
    if not st.started then
        st.started = true
        st.takeAt = simTime
        if pickup.holder == nil and ai.playIdle then
            ai.playIdle(actor, PICKUP_IDLE)
            st.takeAt = simTime + PICKUP_TAKE_AT
        end
    end
    if simTime < st.takeAt then return 'running' end
    local inventory = types.Actor.inventory(actor)
    local okMove = pcall(function() obj:moveInto(inventory) end)
    if okMove and pickup.holder ~= nil then
        -- the ammo that goes with it
        local rec = combat.getWeapon(obj.recordId)
        local okItems, items = pcall(function() return types.Actor.inventory(pickup.holder):getAll() end)
        for _, item in ipairs(okItems and items or {}) do
            if rec and rec.ammoTypes then
                for _, ammo in ipairs(rec.ammoTypes) do
                    if ammo.id == item.recordId then pcall(function() item:moveInto(inventory) end) end
                end
            end
        end
    end
    print(('[combat] %s (%s) picks up %s%s'):format(actor.recordId, tostring(actor.id), tostring(pickup.editorId),
        pickup.holder and (' from ' .. tostring(pickup.holder.recordId)) or ' from the ground'))
    pickupBlocked[obj.id] = simTime + 5
    s.pickup, s.nextPickupScan = nil, 0
    -- moveInto lands with the next frame: re-read the weapons at the replans of the next moment, so the new gun
    -- counts and the plan switches to it (SWITCH_WEAPON)
    s.refreshWeaponsUntil = simTime + 1.5
    s.replanAt = simTime + 0.25
    return okMove and 'done' or 'failed'
end

local procedures = {
    USE_COMBAT_ITEM = function(s, step) return useCombatItem(s, step) end,
    ACTIVATE_COMBAT_ITEM = function(s, step) return activateCombatItem(s, step) end,
    MOVE = function(s, step, distance, los) return moveTowards(s, step.param, distance, los) end,
    MOVE_AND_SWITCH_TO_MELEE = function(s, step, distance, los)
        if s.equippedType ~= PW.MELEE or s.drawnType ~= PW.MELEE then equipType(s, PW.MELEE) end
        return moveTowards(s, step.param, distance, los)
    end,
    MOVE_AND_ATTACK_RANGED = function(s, step, distance, los)
        if los and s.gun and inGunRange(s, distance) then
            if simTime >= s.nextAttack then shootAt(s, s.actor, s.target) else s.fireNow = true end
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
    ATTACK_RANGED_EXPLOSIVE = function(s, step, distance, los) return attackRanged(s, distance, los) end,
    ATTACK_GRENADE = function(s, step, distance) return throwGrenade(s, distance, false) end,
    ATTACK_GRENADE_FLUSH_TARGET = function(s, step, distance) return throwGrenade(s, distance, true) end,
    AVOID_THREAT = function(s) return s.threat == nil and 'done' or 'running' end,
    ATTACK_RANGED_FROM_COVER = function(s, step, distance, los) return beInCover(s, distance, los, false) end,
    ATTACK_RANGED_EXPLOSIVE_FROM_COVER = function(s, step, distance, los) return beInCover(s, distance, los, false) end,
    ATTACK_GRENADE_FROM_COVER = function(s, step, distance, los) return beInCover(s, distance, los, true) end,
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
procedures.MOVE_AND_ATTACK_RANGED_EXPLOSIVE = procedures.MOVE_AND_ATTACK_RANGED
procedures.MOVE_AND_ATTACK_GRENADE = procedures.MOVE
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
            print(('[combat] %s (%s) %s (Confidence %s, Aggression %s, threat ratio %.2f, own health %.0f)'):format(
                actor.recordId, tostring(actor.id), wants and 'wants to flee' or 'stops fleeing',
                tostring(stats.get(actor, 'Confidence')), tostring(stats.get(actor, 'Aggression')), threatRatio(s),
                stats.get(actor, 'Health')))
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
    if not noticed and not targetLost(s) and simTime - (s.lastSeenAt or s.since) + TICK_EVERY > lostAfter() then
        local score = combat.detect and select(1, combat.detect(actor, target, { inCombat = true, alert = true }))
        print(('[combat] %s (%s) loses %s at %.0f (detection %s, line of fire %s, moving %s; %s)')
            :format(actor.recordId, tostring(actor.id), tostring(target.recordId), distance, tostring(score),
                tostring(los), tostring(ai.status(actor)), describeLine(actor, target)))
    end
    if noticed then
        if targetLost(s) then s.replanAt = 0 end
        s.lastSeenAt, s.lastSeenPos = simTime, target.position
        s.searchPos = target.position
    elseif simTime - (s.lastSeenAt or s.since) > lostRemoveTime() then
        stopCombat(actor, 'target lost')
        return
    end

    -- a live grenade close by
    -- only while the AVOID_THREATS roll (fCombatAvoidThreatsChance 0.5, every 5 s) is on, or a threat is already
    -- being avoided
    if simTime >= (s.nextThreatRoll or 0) then
        s.nextThreatRoll = simTime + 5
        s.avoidThreats = math.random() < gmst('fCombatAvoidThreatsChance', 0.5)
    end
    local threat
    if (s.avoidThreats or s.threat ~= nil) and combat.findProjectileNear then
        threat = combat.findProjectileNear(actor.position, ACTOR_RADIUS)
    end
    if (threat ~= nil) ~= (s.threat ~= nil) then s.replanAt = 0 end
    s.threat = threat

    -- line of sight history: recent LOS, out in the open (TARGET_FLUSHED)
    if los then
        s.lastLosAt, s.lastLosPos = simTime, target.position
        s.flushed, s.hidingHandled = true, false
    end
    s.recentLos = simTime - (s.lastLosAt or -math.huge) <= RECENT_LOS
    if not s.recentLos and not s.hidingHandled and not s.inCoverLoop
        and simTime - (s.lastLosAt or -math.huge) <= FLUSH_LAST_SEEN then
        -- it has gone out of sight: hiding (an actor behind its own cover sees nothing, which is not the target
        -- hiding [inferred])
        s.flushed = false
    end
    updateExplosiveBlocked(s, distance)

    if combat.isActing(actor) then return end
    if s.pendingDelay then
        s.nextAttack = math.max(s.nextAttack or 0, simTime + s.pendingDelay)
        s.pendingDelay = nil
    end
    if s.plan == nil or s.stepFailed or simTime >= (s.replanAt or 0) then
        replan(s, distance, los)
    end
    local step = s.plan and s.plan[s.step]
    if step == nil then
        holdStill(actor)
        return
    end
    if step.name:sub(-10) ~= 'FROM_COVER' then
        s.inCoverLoop = false
        if s.crouched then
            s.crouched = false
            combat.setCrouched(actor, false)
        end
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
        hit = function(target, attacker, damage)
            local wasAlive = isAlive(target)
            combat.hit(target, attacker, damage)
            if wasAlive and not isAlive(target) then
                scriptEvent(target, 'OnDeath', attacker)
                dropWeaponOnDeath(target)
            end
        end,
        kill = function(target)
            local wasAlive = isAlive(target)
            combat.hit(target, nil, 1e9)
            if wasAlive and not isAlive(target) then
                scriptEvent(target, 'OnDeath', nil)
                dropWeaponOnDeath(target)
            end
        end,
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
            if e.corpse then
                -- A corpse still comes apart (scripts/omw/fnvgore), nothing else happens
                if target ~= nil and target:isValid() then
                    core.sendGlobalEvent('FNVGore_Killed', {
                        target = target,
                        attacker = e.attacker,
                        weapon = e.weapon,
                        limb = e.limb,
                        direction = e.direction,
                        explosion = e.explosion,
                        corpse = true,
                    })
                end
                return
            end
            if target ~= nil and target:isValid() and isActor(target) then
                if fighting[target.id] then fighting[target.id].lastHitAt = simTime end
                scriptEvent(target, 'OnHit', e.attacker)
                if e.killed then
                    scriptEvent(target, 'OnDeath', e.attacker)
                    dropWeaponOnDeath(target)
                    -- Limbs may come off (scripts/omw/fnvgore)
                    core.sendGlobalEvent('FNVGore_Killed', {
                        target = target,
                        attacker = e.attacker,
                        weapon = e.weapon,
                        limb = e.limb,
                        direction = e.direction,
                        explosion = e.explosion,
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
            -- Shot timing runs every frame: on the 0.2 s tick each semi-auto gap stretched by up to a tick and
            -- came out quantized (run 17: always 1.6 or 1.8 s)
            for _, s in pairs(fighting) do
                if (s.pendingDelay or s.fireNow) and s.actor:isValid() and not combat.isActing(s.actor) then
                    if s.pendingDelay then
                        s.nextAttack = math.max(s.nextAttack or 0, simTime + s.pendingDelay)
                        s.pendingDelay = nil
                    end
                    if s.fireNow and s.gun and simTime >= s.nextAttack and s.target and s.target:isValid() then
                        s.fireNow = nil
                        shootAt(s, s.actor, s.target)
                        local st = s.stepState
                        if st and st.phase == 'out' and not st.fired then
                            st.fired = true
                            st.untilT = simTime + styleTimer(s, 'fireTimer', 1.5, 3)
                        end
                    end
                end
            end
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
                s.fireNow = nil -- set again below while an attack step waits for its shot
                if tracked[id] == nil or not s.actor:isValid() then
                    fighting[id] = nil
                else
                    fight(s)
                end
            end
        end,
    },
}
