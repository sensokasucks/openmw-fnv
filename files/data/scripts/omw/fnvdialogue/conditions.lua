-- Evaluation of FO3/FNV CTDA condition lists (INFO, quest stage entries).
-- Pure Lua: the engine-facing parts are passed in as a context, so this
-- module can be tested outside the engine.
--
-- A condition is the table built by core.obscript.dialogue:
--   { func=<function index>, op='=='|'~='|'>'|'>='|'<'|'<=', isOr=bool,
--     runOn=0 subject|1 target|2 reference|3 combat target|4 linked ref,
--     value=<number> or global=<GLOB form id>, param1=, param2=,
--     param1Form=, param2Form=, reference= }
--
-- Consecutive conditions flagged OR form one group which passes if any of
-- its members passes; groups and plain conditions are AND-ed, which is how
-- the GECK evaluates condition lists.

local M = {}

-- Function index -> name, for logs. Indices from components/esm4/script.hpp.
M.names = {
    [1] = 'GetDistance', [5] = 'GetLocked', [12] = 'GetSecondsPassed', [14] = 'GetActorValue',
    [18] = 'GetCurrentTime', [24] = 'GetScale', [27] = 'GetLineOfSight', [32] = 'GetInSameCell',
    [35] = 'GetDisabled', [36] = 'MenuMode', [42] = 'SameFaction', [43] = 'SameRace', [44] = 'SameSex',
    [45] = 'GetDetected', [46] = 'GetDead', [47] = 'GetItemCount', [48] = 'GetGold', [49] = 'GetSleeping',
    [50] = 'GetTalkedToPC', [53] = 'GetScriptVariable', [56] = 'GetQuestRunning', [58] = 'GetStage',
    [59] = 'GetStageDone', [61] = 'GetAlarmed', [63] = 'GetAttacked', [64] = 'GetIsCreature',
    [67] = 'GetInCell', [68] = 'GetIsClass', [69] = 'GetIsRace', [70] = 'GetIsSex', [71] = 'GetInFaction',
    [72] = 'GetIsID', [73] = 'GetFactionRank', [74] = 'GetGlobalValue', [76] = 'GetDisposition',
    [77] = 'GetRandomPercent', [79] = 'GetQuestVariable', [80] = 'GetLevel', [84] = 'GetDeadCount',
    [91] = 'GetIsAlerted', [98] = 'GetPlayerControlsDisabled', [101] = 'IsWeaponOut',
    [110] = 'GetCurrentAIPackage', [125] = 'IsGuard', [129] = 'GetPCIsClass', [130] = 'GetPCIsRace',
    [131] = 'GetPCIsSex', [132] = 'GetPCInFaction', [136] = 'GetIsReference', [141] = 'IsTalking',
    [159] = 'GetSitting', [161] = 'GetIsCurrentPackage', [170] = 'GetDayOfWeek', [172] = 'GetTalkedToPCParam',
    [182] = 'GetEquipped', [224] = 'GetVATSMode', [242] = 'GetUnconscious', [254] = 'GetIsPlayableRace',
    [255] = 'GetOffersServicesNow', [277] = 'GetBaseActorValue', [286] = 'IsSneaking', [289] = 'IsInCombat',
    [300] = 'IsInInterior', [309] = 'IsXBox', [310] = 'GetInWorldspace', [353] = 'IsActor',
    [354] = 'IsEssential', [365] = 'IsChild', [372] = 'IsInList', [382] = 'GetHasNote', [415] = 'Exists',
    [420] = 'GetObjectiveCompleted', [421] = 'GetObjectiveDisplayed', [427] = 'GetIsVoiceType',
    [431] = 'GetHealthPercentage', [435] = 'GetDialogueEmotion', [436] = 'GetDialogueEmotionValue',
    [449] = 'HasPerk', [454] = 'GetPlayerTeammate', [455] = 'GetPlayerTeammateCount',
    [462] = 'IsPlayerTagSkill', [474] = 'GetIsAlignment', [495] = 'GetPermanentActorValue',
    [523] = 'IsPS3', [524] = 'IsWin32', [546] = 'GetQuestCompleted', [573] = 'GetReputation',
    [574] = 'GetReputationPct', [575] = 'GetReputationThreshold', [586] = 'IsHardcore',
    [619] = 'IsAlwaysHardcore',
}

function M.name(func)
    return M.names[func] or ('Function#' .. tostring(func))
end

local compare = {
    ['=='] = function(a, b) return a == b end,
    ['~='] = function(a, b) return a ~= b end,
    ['>'] = function(a, b) return a > b end,
    ['>='] = function(a, b) return a >= b end,
    ['<'] = function(a, b) return a < b end,
    ['<='] = function(a, b) return a <= b end,
}

-- Human-readable form of one condition, for traces.
function M.describe(cond, value)
    local rhs = cond.global and ('global ' .. tostring(cond.global)) or tostring(cond.value)
    local args = cond.param1Form ~= '' and cond.param1Form or tostring(cond.param1)
    local text = ('%s(%s) %s %s'):format(M.name(cond.func), args, cond.op, rhs)
    if value ~= nil then
        text = text .. ' [got ' .. tostring(value) .. ']'
    end
    return text
end

---
-- Evaluates one condition.
-- ctx.call(cond) returns the function's value, or nil when the function is
-- not implemented (the condition then fails, so unsupported dialogue stays
-- hidden instead of showing out of place).
-- ctx.global(id) returns a global's value for conditions comparing to a global.
-- @return passed, value
function M.check(cond, ctx)
    local value = ctx.call(cond)
    if value == nil then
        return false, nil
    end
    if type(value) == 'boolean' then
        value = value and 1 or 0
    end
    local rhs = cond.value
    if cond.global then
        rhs = ctx.global(cond.global) or 0
    end
    local fn = compare[cond.op] or compare['==']
    return fn(value, rhs or 0), value
end

---
-- Evaluates a condition list.
-- @return passed, failedCondition, failedValue (the first condition, or
-- OR-group member, that made the list fail)
function M.evaluate(conditions, ctx)
    local groupPassed = nil  -- nil outside an OR group
    local groupFail, groupFailValue = nil, nil
    for _, cond in ipairs(conditions or {}) do
        local passed, value = M.check(cond, ctx)
        if cond.isOr then
            if passed then
                groupPassed = true
            elseif groupPassed == nil then
                groupPassed = false
                groupFail, groupFailValue = cond, value
            end
        else
            if groupPassed ~= nil then
                -- last member of the OR group
                if passed or groupPassed then
                    passed = true
                elseif groupFail then
                    cond, value = groupFail, groupFailValue
                end
                groupPassed, groupFail, groupFailValue = nil, nil, nil
            end
            if not passed then
                return false, cond, value
            end
        end
    end
    if groupPassed == false then
        return false, groupFail, groupFailValue
    end
    return true
end

return M
