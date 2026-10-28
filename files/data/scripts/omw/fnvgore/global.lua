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
        weapon = e.weapon,
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
