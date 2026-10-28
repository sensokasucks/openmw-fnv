-- World side of the opt-in trace (OPENMW_FNV_UI_TRACE=1, see scripts/omw/fnvuitrace.lua): every 10 seconds
-- a "[ai-trace]" line per actor within 3000 units of the player, with what it is doing: distance, dead or
-- not, its AI package and phase (scripts/omw/fnvai), whether it talks, its combat plan and target
-- (scripts/omw/fnvcombat), and whether it has noticed the player.

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

if not (core.obscript and core.obscript.uiTraceEnabled) then
    return {}
end

local RANGE = 3000
local PERIOD = 10

local function log(text)
    print('[ai-trace] ' .. text)
end

local function editorId(actor)
    local ok, data = pcall(function() return core.obscript.dialogue.getActor(actor) end)
    if ok and data and data.editorId and data.editorId ~= '' then return data.editorId end
    return actor.recordId
end

local function describe(actor, player)
    local parts = { ('%s (%s) %.0f units'):format(editorId(actor), tostring(actor.id),
        (actor.position - player.position):length()) }
    local combat = I.FNVCombat
    if combat then
        local ok, dead = pcall(combat.isDead, actor)
        if ok and dead then parts[#parts + 1] = 'DEAD' end
        if combat.health then
            local okH, health, full = pcall(combat.health, actor)
            if okH then parts[#parts + 1] = ('hp %.0f/%.0f'):format(health or 0, full or 0) end
        end
        if combat.getPlan then
            local okP, plan = pcall(combat.getPlan, actor)
            if okP and plan then
                local target = combat.getTarget and combat.getTarget(actor)
                parts[#parts + 1] = ('combat[%s vs %s]'):format(plan, target and editorId(target) or '?')
            end
        end
        if combat.noticesPlayer then
            local okN, notices = pcall(combat.noticesPlayer, actor)
            if okN and notices then parts[#parts + 1] = 'notices player' end
        end
    end
    if I.FNVAI and I.FNVAI.describe then
        local ok, d = pcall(I.FNVAI.describe, actor)
        if ok and d then
            parts[#parts + 1] = ('package %s/%s%s'):format(tostring(d.package), tostring(d.phase), d.talking and ' talking' or '')
        end
    end
    return table.concat(parts, ', ')
end

local timer = 0

return {
    engineHandlers = {
        onUpdate = function(dt)
            timer = timer - dt
            if timer > 0 then return end
            timer = PERIOD
            local player = world.players[1]
            if player == nil or not player:isValid() then return end
            local actors = I.FNVCombat and I.FNVCombat.actors and I.FNVCombat.actors() or {}
            local lines = {}
            for _, actor in pairs(actors) do
                if actor:isValid() and actor.cell ~= nil and actor.cell == player.cell
                    and (actor.position - player.position):length() <= RANGE then
                    lines[#lines + 1] = describe(actor, player)
                end
            end
            table.sort(lines)
            log(('%d actors near the player in %s:'):format(#lines,
                player.cell and (player.cell.name ~= '' and player.cell.name or player.cell.id) or '?'))
            for _, line in ipairs(lines) do log('  ' .. line) end
        end,
    },
}
