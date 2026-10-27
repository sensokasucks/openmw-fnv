-- The FNV combat planner (FalloutNV.exe CombatPlanner, ghidra-findings-2.md §2): goals tried in a fixed order,
-- each planned by a backward A* search over the 27 combat actions; the first goal that yields a plan wins.
--
-- World state is a function ws(fact, param) returning a number (booleans as 0/1). A condition is
-- { fact, param, value }; it holds when ws(fact, param) == value. Placeholder params ACTOR_TYPE and ITEM are
-- resolved per actor (the type of weapon the actor fights with; the goal's combat item).
--
-- This file has no OpenMW dependencies (scripts/omw/fnvcombat/global.lua builds the world state and runs the
-- chosen actions as procedures), so the search can be tested on its own.

local M = {}

local F = {
    TARGET_DEAD = 0, AT_LOCATION = 1, NOT_AT_LOCATION = 2, TARGET_LOST = 3, TARGET_DETECTED = 4,
    TARGET_360_LOS = 5, TARGET_BLOCKED = 6, TARGET_SPACE_DIFFERENT = 7, EXPLOSIVE_PROJECTILE_BLOCKED = 8,
    TARGET_FLUSHED = 9, WEAPON_DRAWN = 10, WEAPON_TYPE_EQUIPPED = 11, HAS_WEAPON_TYPE = 12, HAS_COMBAT_ITEM = 13,
    THREATENED = 14, WANTS_TO_FLEE = 15, USED_COMBAT_ITEM = 16, HIDING = 17, EXECUTION_FLAGS = 18,
    GROUP_STRATEGY_ASSIGNMENT = 19,
    -- filter-only pseudo facts: the goal's combat item is unset / set
    ITEM_UNSET = 21, ITEM_SET = 22,
}
M.F = F

-- Location kinds (AT_LOCATION / NOT_AT_LOCATION params)
local L = { TARGET = 0, MELEE = 1, COVER = 2, DODGE = 3, FLANK = 4, FALLBACK = 5, ADVANCE = 6, DESTINATION = 7,
    GUARD = 8, CLUSTER = 9, HIDE = 10, FLEE = 12, LOS = 13, AVOID_THREAT = 14, INVESTIGATE = 15, COMBAT_AREA = 16 }
M.L = L

-- Weapon types
local W = { EXPLOSIVE = 0, RANGED = 1, MELEE = 2, GRENADE = 3, MINE = 4, HAND_TO_HAND = 6, NONE = 7 }
M.W = W

-- Execution flags (EXECUTION_FLAGS params)
local X = { COVER = 0, SEARCH = 16, MOVE = 17, MELEE = 18 }
M.X = X

local ACTOR_TYPE, ITEM = 'actorType', 'item'

local function c(fact, param, value)
    return { fact = fact, param = param, value = value == nil and 1 or value }
end

-- ---------------------------------------------------------------- goals (§2b), in priority order

M.goals = {
    { id = 0, name = 'STAY_IN_COMBAT_AREA', filter = { c(F.NOT_AT_LOCATION, L.COMBAT_AREA) },
        goal = { c(F.AT_LOCATION, L.COMBAT_AREA) } },
    { id = 1, name = 'USE_COMBAT_ITEM', filter = { c(F.ITEM_SET) }, goal = { c(F.USED_COMBAT_ITEM, ITEM) } },
    -- the filter's AT_LOCATION(8) and (7) are left out: read as "any of" in the original, never both
    { id = 2, name = 'FLEE', filter = { c(F.WANTS_TO_FLEE) }, goal = { c(F.WANTS_TO_FLEE, nil, 0) } },
    { id = 3, name = 'AVOID_THREATS', filter = { c(F.THREATENED), c(F.WANTS_TO_FLEE, nil, 0) },
        goal = { c(F.THREATENED, nil, 0) } },
    { id = 4, name = 'ACTIVATE_COMBAT_ITEM', filter = { c(F.ITEM_SET), c(F.WANTS_TO_FLEE, nil, 0) },
        goal = { c(F.HAS_COMBAT_ITEM, ITEM) } },
    { id = 5, name = 'REACH_DESTINATION', filter = { c(F.NOT_AT_LOCATION, L.DESTINATION) },
        goal = { c(F.AT_LOCATION, L.DESTINATION) } },
    { id = 6, name = 'GUARD', filter = { c(F.NOT_AT_LOCATION, L.GUARD) }, goal = { c(F.AT_LOCATION, L.GUARD) } },
    { id = 7, name = 'CLUSTER', filter = { c(F.NOT_AT_LOCATION, L.CLUSTER) }, goal = { c(F.AT_LOCATION, L.CLUSTER) } },
    { id = 8, name = 'ADVANCE', filter = { c(F.GROUP_STRATEGY_ASSIGNMENT, nil, 4) },
        goal = { c(F.AT_LOCATION, L.ADVANCE) } },
    { id = 9, name = 'AMBUSH', filter = { c(F.GROUP_STRATEGY_ASSIGNMENT, nil, 3) }, goal = { c(F.HIDING, nil, 15) } },
    { id = 10, name = 'FALLBACK', filter = { c(F.GROUP_STRATEGY_ASSIGNMENT, nil, 2) },
        goal = { c(F.AT_LOCATION, L.FALLBACK) } },
    { id = 11, name = 'FLANK', filter = { c(F.GROUP_STRATEGY_ASSIGNMENT, nil, 1) },
        goal = { c(F.AT_LOCATION, L.FLANK) } },
    { id = 12, name = 'FIND_TARGET', filter = { c(F.EXECUTION_FLAGS, X.SEARCH), c(F.TARGET_LOST) },
        goal = { c(F.TARGET_LOST, nil, 0) } },
    { id = 13, name = 'FLUSH_TARGET', filter = { c(F.TARGET_LOST, nil, 0), c(F.TARGET_FLUSHED, nil, 0) },
        goal = { c(F.TARGET_FLUSHED) } },
    { id = 14, name = 'KILL_TARGET', filter = { c(F.TARGET_LOST, nil, 0) }, goal = { c(F.TARGET_DEAD) } },
    { id = 15, name = 'HIDE_FROM_TARGET', filter = { c(F.TARGET_LOST, nil, 0) }, goal = { c(F.HIDING, nil, 60) } },
}

-- ---------------------------------------------------------------- actions (§2c)

local function attackRanged(name, cost, weaponType, filter, extraPre)
    local pre = { c(F.WEAPON_TYPE_EQUIPPED, nil, weaponType), c(F.WEAPON_DRAWN, nil, weaponType) }
    for _, p in ipairs(extraPre or {}) do pre[#pre + 1] = p end
    return { name = name, cost = cost, attack = weaponType, filter = filter, pre = pre, effects = { c(F.TARGET_DEAD) } }
end

local NOT_LOST = c(F.TARGET_LOST, nil, 0)
local NOT_EXPL_BLOCKED = c(F.EXPLOSIVE_PROJECTILE_BLOCKED, nil, 0)
local FROM_COVER = { c(F.EXECUTION_FLAGS, X.COVER), c(F.EXECUTION_FLAGS, X.MOVE), c(F.TARGET_DETECTED),
    c(F.TARGET_SPACE_DIFFERENT, nil, 0) }
local function with(list, ...)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = x end
    for _, x in ipairs({ ... }) do out[#out + 1] = x end
    return out
end
local LOS_CLEAR = { c(F.TARGET_360_LOS), c(F.TARGET_BLOCKED, nil, 0) }

M.actions = {
    attackRanged('ATTACK_RANGED_EXPLOSIVE', 1.5, W.EXPLOSIVE, { NOT_LOST, NOT_EXPL_BLOCKED }, LOS_CLEAR),
    attackRanged('ATTACK_RANGED_EXPLOSIVE_FROM_COVER', 1.0, W.EXPLOSIVE, with(FROM_COVER, NOT_EXPL_BLOCKED),
        { c(F.AT_LOCATION, L.COVER) }),
    attackRanged('ATTACK_RANGED', 1.5, W.RANGED, { NOT_LOST }, LOS_CLEAR),
    attackRanged('ATTACK_RANGED_FROM_COVER', 1.0, W.RANGED, FROM_COVER, { c(F.AT_LOCATION, L.COVER) }),
    attackRanged('ATTACK_GRENADE', 1.5, W.GRENADE, { NOT_LOST, NOT_EXPL_BLOCKED }, { c(F.TARGET_360_LOS) }),
    { name = 'ATTACK_GRENADE_FLUSH_TARGET', cost = 1.25, attack = W.GRENADE,
        filter = { NOT_EXPL_BLOCKED, c(F.TARGET_SPACE_DIFFERENT, nil, 0) },
        pre = { c(F.WEAPON_TYPE_EQUIPPED, nil, W.GRENADE), c(F.WEAPON_DRAWN, nil, W.GRENADE) },
        effects = { c(F.TARGET_FLUSHED) } },
    attackRanged('ATTACK_GRENADE_FROM_COVER', 1.0, W.GRENADE, with(FROM_COVER, NOT_EXPL_BLOCKED),
        { c(F.AT_LOCATION, L.COVER) }),
    attackRanged('ATTACK_MELEE', 2.0, W.MELEE,
        { c(F.EXECUTION_FLAGS, X.MOVE), NOT_LOST, c(F.EXECUTION_FLAGS, X.MELEE) }, { c(F.AT_LOCATION, L.MELEE) }),
    attackRanged('ATTACK_HAND_TO_HAND', 2.0, W.HAND_TO_HAND,
        { c(F.EXECUTION_FLAGS, X.MOVE), NOT_LOST, c(F.EXECUTION_FLAGS, X.MELEE) }, { c(F.AT_LOCATION, L.MELEE) }),
    -- MOVE and the MoveAnd* actions take the location kind as their parameter (see expand)
    { name = 'MOVE', cost = 0, move = true, filter = { c(F.EXECUTION_FLAGS, X.MOVE) },
        pre = { c(F.WEAPON_DRAWN, nil, ACTOR_TYPE) }, sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'MOVE_AND_SWITCH_TO_MELEE', cost = 0, move = true,
        filter = { c(F.EXECUTION_FLAGS, X.MOVE), c(F.HAS_WEAPON_TYPE, W.MELEE) }, pre = {},
        effects = { c(F.WEAPON_TYPE_EQUIPPED, nil, W.MELEE), c(F.WEAPON_DRAWN, nil, W.MELEE) },
        sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'MOVE_AND_ATTACK_RANGED', cost = 0, move = true, attack = W.RANGED,
        filter = { c(F.EXECUTION_FLAGS, X.MOVE), c(F.WANTS_TO_FLEE, nil, 0) },
        pre = { c(F.WEAPON_TYPE_EQUIPPED, nil, W.RANGED), c(F.WEAPON_DRAWN, nil, W.RANGED) },
        sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'MOVE_AND_ATTACK_RANGED_EXPLOSIVE', cost = 0, move = true, attack = W.EXPLOSIVE,
        filter = { c(F.EXECUTION_FLAGS, X.MOVE), c(F.WANTS_TO_FLEE, nil, 0), NOT_EXPL_BLOCKED },
        pre = { c(F.WEAPON_TYPE_EQUIPPED, nil, W.EXPLOSIVE), c(F.WEAPON_DRAWN, nil, W.EXPLOSIVE) },
        sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'MOVE_AND_ATTACK_GRENADE', cost = 0, move = true, attack = W.GRENADE,
        filter = { c(F.EXECUTION_FLAGS, X.MOVE), c(F.WANTS_TO_FLEE, nil, 0), NOT_EXPL_BLOCKED },
        pre = { c(F.WEAPON_TYPE_EQUIPPED, nil, W.GRENADE), c(F.WEAPON_DRAWN, nil, W.GRENADE) },
        sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
    -- DRAW_WEAPON and SWITCH_WEAPON take the weapon type as their parameter
    { name = 'DRAW_WEAPON', cost = 1.0, weapon = true, drawnOnly = true, filter = {}, pre = {} },
    { name = 'SWITCH_WEAPON', cost = 2.0, weapon = true, filter = {}, pre = {} },
    { name = 'AVOID_THREAT', cost = 0, filter = { c(F.EXECUTION_FLAGS, X.MOVE) },
        pre = { c(F.AT_LOCATION, L.AVOID_THREAT) }, effects = { c(F.THREATENED, nil, 0) } },
    { name = 'SEARCH', cost = 3.0, filter = { c(F.EXECUTION_FLAGS, X.MOVE) },
        pre = { c(F.WEAPON_DRAWN, nil, ACTOR_TYPE) }, effects = { c(F.TARGET_LOST, nil, 0) } },
    { name = 'INVESTIGATE', cost = 1.0, filter = {},
        pre = { c(F.WEAPON_DRAWN, nil, ACTOR_TYPE), c(F.AT_LOCATION, L.INVESTIGATE) },
        effects = { c(F.TARGET_LOST, nil, 0) } },
    { name = 'DODGE', cost = 0.1, filter = {}, pre = { c(F.AT_LOCATION, L.DODGE) },
        effects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'IGNORE_BLOCKED_TARGET', cost = 1.5, filter = {}, pre = {}, effects = { c(F.TARGET_BLOCKED, nil, 0) } },
    { name = 'FLEE', cost = 0, filter = {}, pre = { c(F.AT_LOCATION, L.FLEE) }, effects = { c(F.WANTS_TO_FLEE, nil, 0) } },
    { name = 'ACTIVATE_COMBAT_ITEM', cost = 1.0, filter = {}, pre = { c(F.AT_LOCATION, ITEM) },
        effects = { c(F.HAS_COMBAT_ITEM, ITEM) } },
    { name = 'USE_COMBAT_ITEM', cost = 1.0, filter = {}, pre = { c(F.HAS_COMBAT_ITEM, ITEM) },
        effects = { c(F.USED_COMBAT_ITEM, ITEM) } },
    { name = 'ACQUIRE_LINE_OF_SIGHT', cost = 2.0, filter = { NOT_LOST }, pre = { c(F.AT_LOCATION, L.LOS) },
        effects = { c(F.TARGET_360_LOS) } },
    { name = 'HIDE', cost = 1.0, filter = {}, pre = { c(F.AT_LOCATION, L.HIDE) }, effects = { c(F.HIDING, nil, 60) } },
    { name = 'APPROACH_TARGET', cost = 1.0, filter = { NOT_LOST }, pre = { c(F.AT_LOCATION, L.TARGET) },
        effects = { c(F.TARGET_360_LOS) }, sideEffects = { c(F.TARGET_BLOCKED, nil, 0) } },
}

-- ---------------------------------------------------------------- search (§2d)

local MAX_EXPANSIONS = 400
local INF = math.huge

local function resolve(cond, ctx)
    local param, value = cond.param, cond.value
    if param == ACTOR_TYPE then param = ctx.actorType end
    if value == ACTOR_TYPE then value = ctx.actorType end
    if param == ITEM then param = ctx.item end
    return param, value
end

local function holds(cond, ws, ctx)
    local param, value = resolve(cond, ctx)
    if cond.fact == F.ITEM_SET then return ctx.item ~= nil end
    if cond.fact == F.ITEM_UNSET then return ctx.item == nil end
    return ws(cond.fact, param) == value
end

local function allHold(list, ws, ctx)
    for _, cond in ipairs(list or {}) do
        if not holds(cond, ws, ctx) then return false end
    end
    return true
end

local function condKey(fact, param)
    return tostring(fact) .. ':' .. tostring(param)
end

-- An action instance: the action with its parameter (move location kind, weapon type) bound
local function instances(action, ws, ctx)
    local list = {}
    if action.move then
        for _, kind in ipairs(ctx.locations) do
            local effects = { c(F.AT_LOCATION, kind), c(F.NOT_AT_LOCATION, kind, 0) }
            for _, e in ipairs(action.effects or {}) do effects[#effects + 1] = e end
            list[#list + 1] = { action = action, param = kind, effects = effects }
        end
    elseif action.weapon then
        for _, weaponType in ipairs(ctx.weaponTypes) do
            if ws(F.HAS_WEAPON_TYPE, weaponType) == 1
                and (not action.drawnOnly or ws(F.WEAPON_DRAWN) == W.NONE) then
                list[#list + 1] = { action = action, param = weaponType,
                    effects = { c(F.WEAPON_TYPE_EQUIPPED, nil, weaponType), c(F.WEAPON_DRAWN, nil, weaponType) } }
            end
        end
    else
        list[1] = { action = action, effects = action.effects or {} }
    end
    return list
end

-- Plans one goal: the cheapest chain of actions (first to last) whose effects make the goal state hold, or nil.
local function planGoal(goal, ws, ctx)
    local open = {}
    local count = 0
    for _, cond in ipairs(goal.goal) do
        if not holds(cond, ws, ctx) then
            local param, value = resolve(cond, ctx)
            open[condKey(cond.fact, param)] = { fact = cond.fact, param = param, value = value }
            count = count + 1
        end
    end
    if count == 0 then return nil end
    -- the frontier, kept sorted by cost (small: a linear insert is fine)
    local frontier = { { open = open, cost = 0 } }
    local expansions = 0
    while #frontier > 0 and expansions < MAX_EXPANSIONS do
        local node = table.remove(frontier, 1)
        if next(node.open) == nil then
            local plan = {}
            local n = node
            while n.instance do
                plan[#plan + 1] = { name = n.instance.action.name, action = n.instance.action, param = n.instance.param }
                n = n.parent
            end
            return plan, node.cost
        end
        expansions = expansions + 1
        for _, want in pairs(node.open) do
            for _, inst in ipairs(ctx.byEffect[want.fact] or {}) do
                local action = inst.action
                local satisfies = false
                for _, e in ipairs(inst.effects) do
                    local param, value = resolve(e, ctx)
                    if e.fact == want.fact and param == want.param and value == want.value then
                        satisfies = true
                        break
                    end
                end
                if satisfies and allHold(action.filter, ws, ctx) then
                    local cost = ctx.cost(action, inst.param)
                    if cost < INF then
                        local childOpen = {}
                        for k, v in pairs(node.open) do childOpen[k] = v end
                        for _, list in ipairs({ inst.effects, action.sideEffects or {} }) do
                            for _, e in ipairs(list) do
                                local param, value = resolve(e, ctx)
                                local k = condKey(e.fact, param)
                                if childOpen[k] and childOpen[k].value == value then childOpen[k] = nil end
                            end
                        end
                        local loops = false
                        for _, p in ipairs(action.pre or {}) do
                            if not holds(p, ws, ctx) then
                                local param, value = resolve(p, ctx)
                                local k = condKey(p.fact, param)
                                if childOpen[k] and childOpen[k].value ~= value then loops = true end
                                childOpen[k] = { fact = p.fact, param = param, value = value }
                            end
                        end
                        -- an action never feeds itself (MOVE for MOVE)
                        local n, depth = node, 0
                        while n and n.instance do
                            if n.instance == inst then loops = true end
                            n = n.parent
                            depth = depth + 1
                        end
                        if not loops and depth < 6 then
                            local child = { open = childOpen, cost = node.cost + cost, parent = node, instance = inst }
                            local at = #frontier + 1
                            for i, f in ipairs(frontier) do
                                if f.cost > child.cost then
                                    at = i
                                    break
                                end
                            end
                            table.insert(frontier, at, child)
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ctx: { actorType, item, locations = { location kinds the actor can be sent to },
--        weaponTypes = { weapon types it can draw }, cost = function(action, param) -> number (INF to refuse) }
-- @return goal, plan (list of { name, action, param }, first step first), cost; nil when no goal can be planned
function M.plan(ws, ctx)
    ctx.byEffect = {}
    for _, action in ipairs(M.actions) do
        for _, inst in ipairs(instances(action, ws, ctx)) do
            local seen = {}
            for _, list in ipairs({ inst.effects, action.sideEffects or {} }) do
                for _, e in ipairs(list) do
                    if not seen[e.fact] then
                        seen[e.fact] = true
                        local byFact = ctx.byEffect[e.fact] or {}
                        ctx.byEffect[e.fact] = byFact
                        byFact[#byFact + 1] = inst
                    end
                end
            end
        end
    end
    for _, goal in ipairs(M.goals) do
        if allHold(goal.filter, ws, ctx) then
            local plan, cost = planGoal(goal, ws, ctx)
            if plan then return goal, plan, cost end
        end
    end
    return nil
end

M.INF = INF
return M
