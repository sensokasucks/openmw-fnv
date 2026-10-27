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
--   * Confidence decides when an actor runs away: Cowardly at once,
--     Cautious below half health, Average below a quarter, Brave below a
--     tenth, Foolhardy never.
--   * Attackers run to the target along the navmesh (straight when there is
--     no route) and use their unarmed or creature attacks within reach. NPCs
--     with a gun draw it, stop within its range and shoot (aim error from
--     their weapon skill), reloading when the clip runs dry.
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
local FLEE_HEALTH = { [0] = 1.01, [1] = 0.5, [2] = 0.25, [3] = 0.1, [4] = 0 } -- by Confidence

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
local nextDetection = 0

local function startCombat(actor, target)
    if not isAlive(actor) or not isAlive(target) or actor == target then return end
    local s = fighting[actor.id]
    if s and s.target == target then return end
    s = { actor = actor, target = target, fleeing = false, nextAttack = 0, nextMove = 0 }
    if types.ESM4NPC.objectIsInstance(actor) then
        local weapon = combat.getActorWeapon(actor)
        if weapon and weapon.isGun then
            s.gun = weapon
            s.clip = math.max(1, weapon.clipSize)
            s.reloadUntil = 0
            combat.drawWeapon(actor, true)
        end
    end
    fighting[actor.id] = s
    tracked[actor.id] = actor
    scriptEvent(actor, 'OnStartCombat', target)
end

local function stopCombat(actor)
    local s = fighting[actor.id]
    if s then
        fighting[actor.id] = nil
        scriptEvent(actor, 'OnCombatEnd', s.target)
        if actor:isValid() then
            ai.stop(actor)
            if s.gun then combat.drawWeapon(actor, false) end
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

local function healthFraction(actor)
    local full = stats.getPermanent(actor, 'Health')
    if full <= 0 then return 1 end
    return stats.get(actor, 'Health') / full
end

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or default
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

local function wantsFight(actor, player)
    if I.FNVAI and I.FNVAI.isTeammate and I.FNVAI.isTeammate(actor) then return false end
    local distance = (player.position - actor.position):length()
    if not noticesPlayer(actor) then return false end
    local aggression = stats.get(actor, 'Aggression')
    if aggression >= 3 then return true end
    local reaction = combat.getReaction(actor)
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
            for otherId, other in pairs(fighting) do
                if otherId ~= id and other.target ~= nil and onPlayerSide(other.target)
                    and not onPlayerSide(other.actor) and isAlive(other.actor)
                    and (other.actor.position - mate.position):length() <= GIVE_UP_DISTANCE then
                    startCombat(mate, other.actor)
                    break
                end
            end
        end
    end
end

local function fight(s)
    selectTarget(s, world.players[1])
    local actor, target = s.actor, s.target
    if not isAlive(target) then
        stopCombat(actor)
        return
    end
    local offset = target.position - actor.position
    local distance = util.vector2(offset.x, offset.y):length()
    if distance > GIVE_UP_DISTANCE or actor.cell.worldSpaceId ~= target.cell.worldSpaceId then
        stopCombat(actor)
        return
    end

    local confidence = math.floor(stats.get(actor, 'Confidence'))
    if not s.fleeing and healthFraction(actor) < (FLEE_HEALTH[confidence] or 0.25) then
        s.fleeing = true
        s.nextMove = 0
    end
    if s.fleeing then
        if distance >= FLEE_DISTANCE then
            ai.stop(actor)
            return
        end
        if simTime >= s.nextMove then
            s.nextMove = simTime + 1.0
            local away = util.vector3(-offset.x, -offset.y, 0):normalize() * FLEE_DISTANCE
            ai.moveTo(actor, actor.position + away, { run = true, direct = true, tolerance = 64 })
        end
        return
    end

    if combat.isActing(actor) then return end
    local reach = s.gun and gunRange(s.gun) or REACH
    -- Gunmen move up until they have a clear shot
    local blocked = s.gun and not combat.hasLineOfFire(actor, target)
    if distance > reach or (blocked and distance > REACH) then
        approach(s, actor, target, blocked and REACH or reach, blocked)
        return
    end
    s.straight = false
    if ai.status(actor) == 'moving' then
        ai.stop(actor)
    end
    ai.face(actor, yawTo(actor.position, target.position))
    if simTime < s.nextAttack then return end
    if s.gun then
        shootAt(s, actor, target)
    else
        s.nextAttack = simTime + 1.2 + math.random() * 0.8
        combat.attack(actor, target, REACH)
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
        getTarget = function(actor)
            local s = fighting[actor.id]
            return s and s.target
        end,
        startCombat = startCombat,
        stopCombat = stopCombat,
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
        -- From the engine once a shot is resolved
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
                if detectionSection:get('state') ~= state then detectionSection:set('state', state) end
            end
            for id, actor in pairs(tracked) do
                if not actor:isValid() or not ai.isInScene(actor) or not isAlive(actor) then
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
