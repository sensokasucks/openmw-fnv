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

-- How good a weapon is: damage over time, more for guns at range and for melee up close (inferred: the
-- original's weapon suitability is not decoded yet).
local function weaponScore(weapon, weaponType, distance)
    local damage = math.max(weapon.damage or 1, 1)
    local rate = weapon.shotsPerSecond and weapon.shotsPerSecond > 0 and weapon.shotsPerSecond or 1
    if weaponType == PW.RANGED or weaponType == PW.EXPLOSIVE then
        local range = gunRange(weapon)
        return damage * rate * (distance > range * 1.5 and 0.7 or 1)
    end
    if weaponType == PW.GRENADE then
        return damage * 0.5
    end
    return damage * (distance > STRAIGHT_DISTANCE and 0.5 or 1)
end

-- The NPC's best weapon of each type it carries (creatures fight hand to hand with their own attacks)
-- Combat items (ghidra-findings-5): every fCombatInventoryUpdateTimer 5 s the actor's own ingestibles (ALCH) are
-- scored; RESTORE is the one whose Self-range Health effects (archetypes 0 Value Modifier, 34 Value And Parts)
-- add up to the most magnitude x max(duration, 1), detrimental effects counting against. Food counts, Buffout
-- outranks a Super Stimpak outranks a Stimpak. BUFF (Chameleon, the Stealth Boy) is blocked by the combat style
-- flag 0x100, which every vanilla style but the Marked Men's sets [style flags are not read yet, so never].
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

local function scanCombatItems(s)
    if simTime < (s.nextItemScan or 0) then return end
    s.nextItemScan = simTime + ITEM_SCAN_EVERY
    s.restoreItem = nil
    if types.ESM4Potion == nil then return end
    local ok, items = pcall(function() return types.Actor.inventory(s.actor):getAll(types.ESM4Potion) end)
    if not ok then return end
    local best = 0
    for _, item in ipairs(items) do
        local score = restoreScore(item.recordId)
        if score > best then best, s.restoreItem = score, item.recordId end
    end
end

-- The item the planner's USE_COMBAT_ITEM goal is about: the healing item once its cooldown has run out and health
-- is below iAICombatRestoreHealthPercentage (60). The original re-arms both slots with fCombatItemBuffTimer 45 s
-- (its restore case falls through into the buff case, so fCombatItemRestoreTimer 3 never applies); kept as is.
local function combatItem(s)
    if s.restoreItem == nil or simTime < (s.itemCooldownUntil or 0) then return nil end
    local health, max = stats.get(s.actor, 'Health'), stats.getPermanent(s.actor, 'Health')
    if max <= 0 or health / max * 100 >= gmst('iAICombatRestoreHealthPercentage', 60) then return nil end
    return s.restoreItem
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
            local score = weaponScore(weapon, t, distance)
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
    return s.useCover and simTime >= (s.noCoverUntil or 0) and types.ESM4NPC.objectIsInstance(s.actor)
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
        print(('[combat] %s (%s) takes cover %s, %.0f from %s (cover %s, fire %s)'):format(s.actor.recordId,
            tostring(s.actor.id), found.key, (found.cover - s.target.position):length(), tostring(s.target.recordId),
            tostring(found.cover), tostring(found.fire)))
    end
    return found
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
        if kind == L.AVOID_THREAT then return s.threat == nil end
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
        if fact == P_F.USED_COMBAT_ITEM then return 0 end
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
    local locations = { P.L.TARGET, P.L.MELEE, P.L.FLEE, P.L.LOS, P.L.INVESTIGATE, P.L.AVOID_THREAT }
    if coverWanted(s) then locations[#locations + 1] = P.L.COVER end
    scanCombatItems(s)
    local ctx = { actorType = actorType, locations = locations, item = combatItem(s),
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
        if s.cover == nil and findCover(s) == nil then
            s.noCoverUntil = simTime + 3
            return 'failed'
        end
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
    if s.gun ~= nil and not los and distance < 1000 and not s.blockedLogged then
        s.blockedLogged = true
        print(('[combat] %s (%s) has no line of fire to %s at %.0f: %s'):format(actor.recordId, tostring(actor.id),
            tostring(target.recordId), distance, describeLine(actor, target)))
    end
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

local procedures = {
    USE_COMBAT_ITEM = function(s, step) return useCombatItem(s, step) end,
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
