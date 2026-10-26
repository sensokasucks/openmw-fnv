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
--   * Aggressive actors attack the player on sight when their factions are
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

local combat = core.obscript and core.obscript.combat
if combat == nil or types.ESM4Creature == nil then
    return {}
end
local stats = core.obscript.stats
local ai = core.obscript.ai

local TICK_EVERY = 0.2 -- seconds between AI updates
local NOTICE_DISTANCE = 1500 -- how close aggressive actors notice the player
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

local function wantsFight(actor, player)
    local distance = (player.position - actor.position):length()
    if distance > NOTICE_DISTANCE then return false end
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

local function fight(s)
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
                if e.killed then scriptEvent(target, 'OnDeath', e.attacker) end
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
            for id, actor in pairs(tracked) do
                if not actor:isValid() or not ai.isInScene(actor) or not isAlive(actor) then
                    tracked[id] = nil
                    fighting[id] = nil
                elseif fighting[id] == nil and playerAlive and wantsFight(actor, player) then
                    startCombat(actor, player)
                    callForHelp(actor, player)
                end
            end
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
