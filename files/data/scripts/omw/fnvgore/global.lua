-- FO3/FNV gore: limbs severed and exploded when an actor dies, as FalloutNV.exe does it.
--
-- The engine (core.obscript.combat) finds the limb a shot hits, takes its condition down, and decides what the
-- killing blow (or any later shot or blast on the corpse) tears off: a crippled limb comes off, now and then a
-- limb bursts, a blast can take every crippled limb, and the Bloody Mess perk takes more of the body with it
-- (rollDismemberment). This script turns each result into an event, dismember, which
-- shows it (combat.dismember: the limb flies off or bursts into gore) and keeps it with the save, so the corpse
-- stays in pieces.
--
-- Multiplayer: dismember is the one place gore happens, and everything it needs is in its arguments (actor,
-- limb, explode, direction, seed). A host can roll once and send those to the other players, who call
-- I.FNVGore.dismember with the same values and see the same pieces fly.
--
-- From the console (luag): I.FNVGore.dismember(obj, I.FNVGore.LIMB.Head1, true),
-- I.FNVGore.lostLimbs(obj)

local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')

local combat = core.obscript and core.obscript.combat
if combat == nil or combat.dismember == nil then
    return {}
end

local LIMB = combat.LIMB
local physical = core.obscript.physical

-- Lost limbs of the actors this game, by object id: { lost = mask, exploded = mask }
local lost = {}

local function bit(limb)
    return 2 ^ limb
end

local function has(mask, limb)
    return math.floor(mask / bit(limb)) % 2 == 1
end

local function record(actor, limb, explode)
    local entry = lost[actor.id] or { lost = 0, exploded = 0 }
    if has(entry.lost, limb) then return false end
    entry.lost = entry.lost + bit(limb)
    if explode then entry.exploded = entry.exploded + bit(limb) end
    lost[actor.id] = entry
    return true
end

--- Severs (or explodes) a limb of the actor with its gore, and remembers it.
-- @param actor
-- @param limb number (LIMB)
-- @param explode boolean
-- @param direction optional vector3 the pieces are pushed along (the shot)
-- @param seed optional integer; the same seed throws the pieces the same way
local function dismember(actor, limb, explode, direction, seed)
    if actor == nil or not actor:isValid() or limb == nil then return end
    if not record(actor, limb, explode == true) then return end
    combat.dismember(actor, limb, explode == true, direction or util.vector3(0, 0, 0),
        seed or math.random(1, 2147483646))
end

local function hasBloodyMess(attacker)
    if attacker == nil or not types.Player.objectIsInstance(attacker) then return false end
    local I = require('openmw.interfaces')
    local character = I.FNVCharacter
    if character == nil or character.hasPerk == nil then return false end
    local ok, result = pcall(character.hasPerk, 'BloodyMess')
    return ok and result == true
end

-- The killing blow of a shot or blast, or a later hit on the corpse (scripts/omw/fnvcombat/global.lua): roll what
-- comes off and send it flying.
local function onKilled(e)
    local target = e.target
    if target == nil or not target:isValid() then return end
    local seed = math.random(1, 2147483646)
    local results = combat.rollDismemberment(target, {
        limb = e.limb or -1,
        -- A blast's own hit carries no weapon (FUN_008b4d10), so a grenade's "On Hit" setting doesn't apply
        weapon = not e.explosion and e.weapon or nil,
        bloodyMess = hasBloodyMess(e.attacker),
        explosion = e.explosion == true,
        seed = seed,
    })
    for i, d in ipairs(results) do
        dismember(target, d.limb, d.explode, e.direction, seed + i)
    end
end

return {
    interfaceName = 'FNVGore',
    ---
    -- @module FNVGore
    -- @context global
    interface = {
        version = 0,
        LIMB = LIMB,
        dismember = dismember,
        --- Bit masks of the limbs the actor has lost (1 << limb) and of those that exploded.
        lostLimbs = function(actor)
            local entry = lost[actor.id]
            if entry == nil then return 0, 0 end
            return entry.lost, entry.exploded
        end,
        isLimbGone = function(actor, limb)
            local entry = lost[actor.id]
            return entry ~= nil and has(entry.lost, limb)
        end,
    },
    eventHandlers = {
        -- { target, attacker, weapon, limb, direction, explosion, corpse }
        FNVGore_Killed = onKilled,
        -- { actor, limb, explode, direction, seed }: replays a dismemberment decided elsewhere
        FNVGore_Dismember = function(e)
            dismember(e.actor, e.limb, e.explode, e.direction, e.seed)
        end,
        -- The console's gib / sever commands (scripts/omw/fnvgore/player.lua): { player, target, limb = name
        -- or '' for every limb, explode }
        FNVGore_Console = function(e)
            local function say(msg, isError)
                if e.player then e.player:sendEvent(isError and 'OMWConsoleError' or 'OMWConsolePrint', msg) end
            end
            local target = e.target
            if target == nil or not target:isValid()
                or not (types.ESM4NPC.objectIsInstance(target) or types.ESM4Creature.objectIsInstance(target)) then
                say('gib: select an NPC or a creature (click it in the console)', true)
                return
            end
            local names = { head = 'Head1', torso = 'Torso', leftarm = 'LeftArm1', rightarm = 'RightArm1',
                leftleg = 'LeftLeg1', rightleg = 'RightLeg1' }
            local limbs
            if e.limb == nil or e.limb == '' or e.limb == 'all' then
                limbs = { 'Head1', 'LeftArm1', 'RightArm1', 'LeftLeg1', 'RightLeg1', 'Torso' }
            elseif names[e.limb] then
                limbs = { names[e.limb] }
            else
                say('gib: unknown limb "' .. tostring(e.limb) .. '"; use head, torso, leftarm, rightarm, leftleg, rightleg or nothing for all', true)
                return
            end
            -- a live target dies first; the torso goes last since it takes the whole body with it
            if combat.isDead and not combat.isDead(target) then combat.hit(target, nil, 1e9) end
            for _, name in ipairs(limbs) do
                dismember(target, LIMB[name], e.explode == true)
            end
            say(('%s: %s %s'):format(e.explode and 'gib' or 'sever', target.recordId, table.concat(limbs, ', ')))
        end,
        -- The console's knockdown / stagger commands (scripts/omw/fnvgore/player.lua): { player, target, verb,
        -- amount (force or seconds), from (the player's position: the blow comes from there) }
        FNVPhysical_Console = function(e)
            local function say(msg, isError)
                if e.player then e.player:sendEvent(isError and 'OMWConsoleError' or 'OMWConsolePrint', msg) end
            end
            local target = e.target
            if physical == nil then
                say(e.verb .. ': no physical API in this build', true)
                return
            end
            if target == nil or not target:isValid()
                or not (types.ESM4NPC.objectIsInstance(target) or types.ESM4Creature.objectIsInstance(target)) then
                say(e.verb .. ': select an NPC or a creature (click it in the console)', true)
                return
            end
            if e.verb == 'stagger' then
                physical.stagger(target, e.amount or 1.0)
                say(('stagger: %s for %.1fs'):format(target.recordId, e.amount or 1.0))
                return
            end
            local away = target.position - (e.from or target.position)
            away = util.vector3(away.x, away.y, 0)
            if away:length() < 1 then away = util.vector3(0, 1, 0) end
            away = away:normalize() + util.vector3(0, 0, 0.6)
            local force = e.amount or 35
            physical.knockDown(target, away:normalize(), force)
            say(('knockdown: %s, force %.0f (posture was %s)'):format(target.recordId, force,
                physical.getPosture(target)))
        end,
    },
    engineHandlers = {
        onSave = function()
            return { lost = lost }
        end,
        onLoad = function(data)
            lost = (data and data.lost) or {}
        end,
        onObjectActive = function(obj)
            local entry = lost[obj.id]
            if entry ~= nil then
                combat.setLostLimbs(obj, entry.lost, entry.exploded)
            end
        end,
    },
}
