-- The Companion Wheel, world side (ghidra-findings-11). The window is scripts/omw/fnvcompanion/player.lua.
--
-- Activating a player teammate (SetPlayerTeammate 1) that is alive and not hostile to the player opens the
-- wheel instead of dialogue; a teammate only talks through the wheel's Talk To, as in the original. No keyword
-- or variable gates it.
--
-- The two-state buttons make the companion say a topic: its first matching line is voiced, shown as the
-- wheel's subtitle, and both of its result scripts run at once, so the ESM's companion scripts change their own
-- variables (Waiting, IsFollowingLong, CombatStyleRanged, ...). Be Aggressive / Be Passive also writes
-- FollowerSwitchAggressive itself, whatever the line did.
--
-- Events:
--   FNVCompanionWheelButton { player, companion, button, on }   button ids as the menu XML numbers them
-- To the player:
--   FNVCompanionWheelOpen     { companion, aggressive, long, ranged, following }
--   FNVCompanionWheelSubtitle { text }

local core = require('openmw.core')
local storage = require('openmw.storage')
local types = require('openmw.types')
local I = require('openmw.interfaces')

if core.obscript == nil or core.obscript.dialogue == nil or types.ESM4NPC == nil then
    return {}
end

local dlg = core.obscript.dialogue
local stats = core.obscript.stats

local function log(msg)
    print('[companion] ' .. msg)
end

-- Variables of object scripts as their local scripts publish them (see scripts/omw/fnvdialogue)
local refVars = storage.globalSection('ObScriptRefVars')
local function refVar(obj, name)
    local ok, key = pcall(function() return dlg.getReferenceId(obj) end)
    local locals = ok and key and refVars:get(key)
    return locals and locals[name:lower()]
end

-- through the dialogue, so that the next line's GetScriptVariable condition sees it at once (run 25: Be Passive
-- right after Be Aggressive picked the "already passive" line)
local function setVar(obj, name, value)
    if I.FNVDialogue and I.FNVDialogue.setScriptVariable then
        I.FNVDialogue.setScriptVariable(obj, name, value)
    else
        obj:sendEvent('ObScriptSetVar', { name = name, value = value })
    end
end

local function isTeammate(npc)
    return I.FNVAI ~= nil and I.FNVAI.isTeammate ~= nil and I.FNVAI.isTeammate(npc)
end

-- FUN_00754d90: alive, conscious and not hostile to the player
local function canOpen(npc, player)
    local combat = I.FNVCombat
    if combat ~= nil then
        if combat.isDead and combat.isDead(npc) then return false end
        if combat.getTarget and combat.getTarget(npc) == player then return false end
    end
    return true
end

I.Activation.addHandlerForType(types.ESM4NPC, function(npc, actor)
    if not types.Player.objectIsInstance(actor) or not isTeammate(npc) then return end
    -- a dead teammate's body is searched like any other
    if I.FNVCombat and I.FNVCombat.isDead and I.FNVCombat.isDead(npc) then return end
    if canOpen(npc, actor) then
        actor:sendEvent('FNVCompanionWheelOpen', {
            companion = npc,
            aggressive = refVar(npc, 'FollowerSwitchAggressive') == 1,
            long = refVar(npc, 'IsFollowingLong') == 1,
            ranged = refVar(npc, 'CombatStyleRanged') == 1,
            following = refVar(npc, 'Waiting') ~= 1,
        })
    end
    -- a teammate that cannot open the wheel opens nothing (FUN_005fa330), never dialogue
    return false
end)

local function say(player, npc, topic)
    local text = I.FNVDialogue and I.FNVDialogue.wheelSay and I.FNVDialogue.wheelSay(npc, topic)
    player:sendEvent('FNVCompanionWheelSubtitle', { text = text or '' })
    return text ~= nil
end

-- the two-state buttons: id -> { topic when turned on, topic when turned off }
local TOGGLES = {
    [0] = { 'FollowersTacticsCombatAggressive', 'FollowersTacticsCombatPassive' },
    [2] = { 'FollowersLetsGo', 'FollowersWait' }, -- on = following
    [5] = { 'FollowersTacticsDistanceLong', 'FollowersTacticsDistanceDefault' },
    [7] = { 'FollowersTacticsCombatRanged', 'FollowersTacticsCombatMelee' },
}

-- Actor values 0x19..0x1F: the limb conditions (Perception, Endurance, Left/Right Attack, Left/Right Mobility,
-- Brain)
local LIMBS = { 25, 26, 27, 28, 29, 30, 31 }

-- Use Stimpak (FUN_00756490, ghidra-findings-5): with a Stimpak in the player's inventory, and the companion
-- hurt or with a crippled limb, one of the player's Stimpaks heals it (its effects only when hurt) and every
-- limb condition is restored; it says Regenerating. Otherwise nothing at all happens.
local function useStimpak(player, npc)
    local recordId = core.obscript.resolveItemEditorId and core.obscript.resolveItemEditorId('Stimpak')
    local stim = recordId and types.Actor.inventory(player):find(recordId)
    if stim == nil or stim.count <= 0 then return end
    local hurt = stats.get(npc, 'Health') < stats.getPermanent(npc, 'Health')
    local crippled = false
    for _, av in ipairs(LIMBS) do
        if av ~= 31 and stats.get(npc, av) <= 0 then crippled = true end
    end
    if not hurt and not crippled then return end
    if hurt and I.FNVEffects and I.FNVEffects.applyPotion then I.FNVEffects.applyPotion(npc, recordId) end
    stim:remove(1)
    for _, av in ipairs(LIMBS) do stats._damage(npc, av, -1e9) end
    log(('%s uses a Stimpak on %s'):format(player.recordId, npc.recordId))
    say(player, npc, 'Regenerating')
end

local function openInventory(player, npc)
    -- every companion's FollowersTrade line runs OpenTeammateContainer; a teammate without one opens it here
    if not say(player, npc, 'FollowersTrade') then
        player:sendEvent('FNVOpenTeammateContainer', { container = npc })
    end
end

return {
    eventHandlers = {
        FNVCompanionWheelButton = function(e)
            local player, npc, button = e.player, e.companion, e.button
            if player == nil or npc == nil or not npc:isValid() then return end
            local toggle = TOGGLES[button]
            if toggle then
                say(player, npc, e.on and toggle[1] or toggle[2])
                if button == 0 then setVar(npc, 'FollowerSwitchAggressive', e.on and 1 or 0) end
            elseif button == 1 then
                useStimpak(player, npc)
            elseif button == 3 then
                if I.FNVDialogue and I.FNVDialogue.startDialogue then I.FNVDialogue.startDialogue(npc, player) end
            elseif button == 4 then
                if I.FNVAI and I.FNVAI.backUp then I.FNVAI.backUp(npc, player) end
            elseif button == 6 then
                openInventory(player, npc)
            end
        end,
    },
}
