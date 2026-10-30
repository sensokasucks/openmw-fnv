---
-- `openmw_aux.obscript.runtime` is the runtime library for transpiled
-- ObScript (see `openmw_aux.obscript.transpiler`).
-- It provides script-local storage, cross-script variables, an event registry,
-- per-frame scheduling, and a uniform dispatch layer where every engine command lands.
-- Engine bindings are installed with @{#runtime.bind};
-- any command without a binding is stubbed, counted, and evaluates to 0,
-- so every transpiled script loads and runs regardless of implementation coverage.
--
-- The semantics encode vanilla ObScript behavior:
--
--  * variables are zero-initialized
--  * conditions treat any nonzero number as true
--  * one shared variable namespace per script, readable cross-script
--  * GameMode blocks run every frame for every loaded script
-- Implementation can be found in `resources/vfs/openmw_aux/obscript/runtime.lua`.
-- @module runtime
-- @context global
-- @usage
-- local obs = require('openmw_aux.obscript.runtime')
-- obs.bind('ShowMessage', function(msgId) ... end)
-- obs.frame() -- from an onUpdate engine handler

local obs = {}

-- --------------------------- state

local zerotable_mt = { __index = function() return 0 end }

obs._scripts = {}      -- script name (lower) -> { locals = S, handlers = {event->fn} }
obs._globals = setmetatable({}, zerotable_mt)  -- global variables (GameHour etc.)
obs._bindings = {}     -- command name (lower) -> function
obs._unknown = {}      -- command name (lower) -> call count (coverage telemetry)
obs._log = nil         -- optional function(msg) for stub logging
obs._current = nil     -- script currently registering/executing
obs._block = nil       -- block currently executing (lowercase event name)
obs._actionRef = nil   -- activating/triggering reference while handling OnActivate/OnTrigger*
obs._triggerProbe = nil        -- function() -> list of actors inside this trigger volume (set by bindings.lua)
obs._onLocalScriptReady = nil  -- function(entry) called once from makeLocalScript (set by bindings.lua)

-- --------------------------- tracing
-- Opt-in via OPENMW_OBSCRIPT_TRACE=1 (exposed by the engine as core.obscript.traceEnabled).
-- [obscript-trace]   block entries and command calls; inside GameMode and OnTrigger each
--                    distinct line is logged once per script, since they run every frame
-- [obscript-missing] stubbed commands, unknown names and undispatched blocks, once per script

-- core.obscript is absent outside the engine (e.g. unit tests), hence the pcall
obs._trace = false
do
    local ok, enabled = pcall(function()
        return require('openmw.core').obscript.traceEnabled
    end)
    obs._trace = ok and enabled == true
end

local traceSeen = {}  -- script (lower) -> set of already-logged keys

local function currentScriptName()
    return obs._current and obs._current.name or "?"
end

local function traceOnce(prefix, key, msg)
    local script = currentScriptName()
    local seen = traceSeen[script:lower()]
    if not seen then
        seen = {}
        traceSeen[script:lower()] = seen
    end
    if seen[prefix .. key] then return end
    seen[prefix .. key] = true
    print(prefix .. ' ' .. script .. ': ' .. msg)
end

local function traceCall(name, implemented)
    if not obs._trace then return end
    if not implemented then
        traceOnce('[obscript-missing]', 'cmd:' .. name:lower(), 'command ' .. name)
    end
    local msg = (obs._block or '?') .. ' -> ' .. name .. (implemented and '' or ' (stub)')
    if obs._block == 'gamemode' or obs._block == 'ontrigger' then
        traceOnce('[obscript-trace]', 'call:' .. msg:lower(), msg)
    else
        print('[obscript-trace] ' .. currentScriptName() .. ': ' .. msg)
    end
end

local function traceBlock(event)
    if not obs._trace then return end
    if event == 'gamemode' or event == 'ontrigger' then
        traceOnce('[obscript-trace]', 'block:' .. event, 'enter ' .. event .. ' (first frame)')
    else
        print('[obscript-trace] ' .. currentScriptName() .. ': enter ' .. event)
    end
end

local function scriptEntry(name)
    local key = name:lower()
    local entry = obs._scripts[key]
    if not entry then
        -- handlers: event -> fn or list of fns; blocks: { event, fn, args } in source order
        entry = { name = name, locals = setmetatable({}, zerotable_mt), handlers = {}, blocks = {}, ints = {} }
        obs._scripts[key] = entry
    end
    return entry
end

-- --------------------------- API used by generated code

-- Returned by a block function for `Return`: ends the whole script run.
obs.RETURN = setmetatable({}, { __tostring = function() return 'obs.RETURN' end })

-- Truncation toward zero for short/int/long variables; references pass through.
function obs.int(x)
    if type(x) ~= 'number' then
        return x
    end
    if x >= 0 then
        return math.floor(x)
    end
    return math.ceil(x)
end

function obs.locals(scriptName, ints)
    local entry = scriptEntry(scriptName)
    obs._current = entry
    if ints then
        -- generated code defining the script: (re)register its blocks from scratch
        entry.blocks = {}
        entry.handlers = {}
        for _, name in ipairs(ints) do
            entry.ints[name] = true
        end
    end
    return entry.locals
end

function obs.on(event, fn, ...)
    -- registers a block handler for the script currently loading; extra
    -- arguments are the block's parameters (`Begin OnTriggerEnter player`)
    local entry = obs._current
    if entry == nil then
        entry = scriptEntry("__anonymous")
    end
    local key = event:lower()
    entry.blocks[#entry.blocks + 1] = { event = key, fn = fn, args = { ... } }
    local existing = entry.handlers[key]
    if existing == nil then
        entry.handlers[key] = fn
    elseif type(existing) == "table" then
        existing[#existing + 1] = fn
    else
        entry.handlers[key] = { existing, fn }
    end
end

-- ObScript truthiness: any nonzero number is true
function obs.b(x)
    if type(x) == "number" then
        return x ~= 0
    end
    return x and true or false
end

local function dispatch(name, ...)
    local key = name:lower()
    local fn = obs._bindings[key]
    traceCall(name, fn ~= nil)
    if fn then
        return fn(...) or 0
    end
    obs._unknown[key] = (obs._unknown[key] or 0) + 1
    if obs._log then
        obs._log("unimplemented: " .. name)
    end
    return 0
end

-- obs._callBase is the reference of the member call being dispatched
-- (`Ref.SayTo ...`), nil for a free call, so bindings can tell
-- `Ref.Cmd a b` from `Cmd ref a b`.
obs._callBase = nil

-- free function call: SetStage(...), ShowMessage(...)
function obs.f(name, ...)
    local prev = obs._callBase
    obs._callBase = nil
    local result = dispatch(name, ...)
    obs._callBase = prev
    return result
end

-- member call: player.AddItem(...), Ref.Say(...)
function obs.m(base, name, ...)
    local prev = obs._callBase
    obs._callBase = base
    local result = dispatch(name, obs.resolveRef(base), ...)
    obs._callBase = prev
    return result
end

-- bare name in value position: local was handled by the emitter, so this is a
-- global variable, a zero-arg command, or an editor id used as a value
function obs.v(name)
    local key = name:lower()
    if obs._bindings[key] then
        return dispatch(name)
    end
    if rawget(obs._globals, key) ~= nil then
        return obs._globals[key]
    end
    -- unknown: report once as coverage telemetry, evaluate as 0 (vanilla-ish)
    obs._unknown[key] = (obs._unknown[key] or 0) + 1
    if obs._trace then
        traceOnce('[obscript-missing]', 'name:' .. key,
            'name ' .. name .. ' (global, zero-arg command or editor id; evaluated as 0)')
    end
    return 0
end

-- Hooks for variables of scripts that live in another context (quest
-- variables seen from an object script); installed by bindings.lua.
--   obs._remoteVar(base, name) -> value, or nil when not known there
--   obs._remoteSet(base, name, value) -> true when handled
obs._remoteVar = nil
obs._remoteSet = nil
-- obs._publishLocals(entry, dt): called after each run of a local script, so
-- that other contexts can read its variables (Ref.var, GetScriptVariable).
obs._publishLocals = nil

-- cross-script variable read: Quest.var / Ref.var
function obs.mv(base, name)
    if obs._remoteVar and type(base) == 'string' then
        local value = obs._remoteVar(base, name)
        if value ~= nil then
            return value
        end
    end
    local entry = obs._scripts[tostring(base):lower()]
    if entry and rawget(entry.locals, name:lower()) ~= nil then
        return entry.locals[name:lower()]
    end
    -- zero-argument member command in value position: `player.GetLevel`, `Player.IsWeaponOut`
    if obs._bindings[name:lower()] then
        local prev = obs._callBase
        obs._callBase = base
        local result = dispatch(name, obs.resolveRef(base))
        obs._callBase = prev
        return result
    end
    if entry then
        return entry.locals[name:lower()]
    end
    -- script not loaded (or base is a ref whose script we don't know): 0
    return 0
end

function obs.setv(name, value)
    obs._globals[name:lower()] = value
end

function obs.msetv(base, name, value)
    local key = name:lower()
    if obs._remoteSet and type(base) == 'string' and obs._remoteSet(base, key, value) then
        return
    end
    local entry = scriptEntry(tostring(base))
    if entry.ints[key] then
        value = obs.int(value)
    end
    entry.locals[key] = value
end

function obs.discard(_) end

function obs.fx(value, ...)  -- call on arbitrary expression (rare)
    return value
end

-- --------------------------- engine-facing API

-- install an engine binding: obs.bind("SetStage", function(quest, stage) ... end)
function obs.bind(name, fn)
    obs._bindings[name:lower()] = fn
end

-- resolve a reference handle (string editor id, or already-resolved object)
-- engine installs the real resolver; default is identity
obs.resolveRef = function(x) return x end

-- run one block's handler(s) for a script; event is lowercase
local function runBlock(entry, event, h)
    obs._current = entry
    obs._block = event
    traceBlock(event)
    if type(h) == "table" then
        for _, fn in ipairs(h) do fn() end
    else
        h()
    end
    obs._current = nil
    obs._block = nil
end

-- run one frame: fire every loaded script's GameMode handlers
function obs.frame()
    for _, entry in pairs(obs._scripts) do
        local h = entry.handlers["gamemode"]
        if h then
            runBlock(entry, "gamemode", h)
        end
    end
end

-- fire a specific event on a specific script (OnActivate, OnDeath, ...)
function obs.fire(scriptName, event)
    local entry = obs._scripts[scriptName:lower()]
    if not entry then return false end
    local key = event:lower()
    local h = entry.handlers[key]
    if not h then return false end
    runBlock(entry, key, h)
    return true
end

-- --------------------------- one script run (the original's Script::Execute)

-- Whether `ref` passes a block's filter parameter (`Begin OnTriggerEnter player`).
-- The filter arrives as an editor id string or a ref variable's value. The
-- context installs the real comparison; the default only knows `player`.
obs.refMatches = function(ref, filter)
    if type(filter) == 'string' then
        local key = filter:lower()
        if key == 'player' or key == 'playerref' then
            return ref == 'player'
        end
        return tostring(ref):lower() == key
    end
    return ref == filter
end

-- Menu-mode parameters that are not single menus: 1 any menu, 2 console,
-- 3 a menu other than the console (inferred from GECK usage, not traced).
local function menuModeMatches(param, menu)
    if param == nil or param == 0 or param == 1 then
        return true
    end
    return param == menu
end

-- Picks the event entry a block reacts to; nil when it doesn't run.
local function blockEvent(block, events)
    local list = events and events[block.event]
    if list == nil then
        return nil
    end
    local filter = block.args[1]
    for _, ev in ipairs(list) do
        if filter == nil or (ev.ref ~= nil and obs.refMatches(ev.ref, filter)) then
            return ev
        end
    end
    return nil
end

--- Runs one execution of a script, the way the original engine does it: every
-- Begin block is visited in source order and runs when its predicate holds
-- (GameMode outside menus, MenuMode inside a matching menu, event blocks when
-- that event is pending and its filter parameter matches). `Return` ends the
-- whole run. Pending events are seen by this run only.
-- @param entry script entry (from obs._scripts)
-- @param #table ctx { menuMode = menu type or nil, events = { [event] = { {ref=...}, ... } } }
function obs.execute(entry, ctx)
    local prevCurrent, prevBlock, prevAction = obs._current, obs._block, obs._actionRef
    local menu = ctx and ctx.menuMode
    local events = ctx and ctx.events
    for _, block in ipairs(entry.blocks) do
        local event = block.event
        local run, ref = false, nil
        if event == 'gamemode' then
            run = menu == nil
        elseif event == 'menumode' then
            run = menu ~= nil and menuModeMatches(tonumber(block.args[1]), menu)
        elseif event ~= '__stray' then
            local ev = blockEvent(block, events)
            if ev then
                run, ref = true, ev.ref
            end
        end
        if run then
            obs._current = entry
            obs._block = event
            obs._actionRef = ref
            traceBlock(event)
            local result = block.fn()
            if result == obs.RETURN then
                break
            end
        end
    end
    obs._current, obs._block, obs._actionRef = prevCurrent, prevBlock, prevAction
end

-- Whether a script declares a block of this type.
function obs.hasBlock(entry, event)
    for _, block in ipairs(entry.blocks) do
        if block.event == event then
            return true
        end
    end
    return false
end

-- coverage report: which commands were called but unimplemented, by frequency
function obs.coverageReport(limit)
    local list = {}
    for name, count in pairs(obs._unknown) do
        list[#list + 1] = { name = name, count = count }
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    local out = {}
    for i = 1, math.min(limit or 25, #list) do
        out[#out + 1] = string.format("%6d  %s", list[i].count, list[i].name)
    end
    return table.concat(out, "\n")
end

-- --------------------------- local-script interface

-- blocks that have an event source in the local context; any other block a
-- script declares is reported as missing. Other systems can raise events on
-- an object with `obj:sendEvent('ObScriptEvent', { event = 'OnDeath', ref = killer })`.
local dispatchedBlocks = {
    gamemode = true, onactivate = true, onopen = true, onload = true,
    ontriggerenter = true, ontrigger = true, ontriggerleave = true,
    onhit = true, onhitwith = true, ondeath = true, onstartcombat = true, oncombatend = true, saytodone = true,
}

-- Trigger volumes have no physics callback in OpenMW, so every frame the
-- local script asks bindings.lua which actors are inside its primitive
-- (REFR XPRM bounds) and diffs that against the previous frame:
--   OnTriggerEnter  first frame an actor is inside
--   OnTrigger       every frame an actor is inside
--   OnTriggerLeave  first frame it is no longer inside
local function pollTriggers(post, state)
    local inside = obs._triggerProbe()
    local now = {}
    for _, actor in ipairs(inside) do
        now[actor.id] = actor
    end
    for id, actor in pairs(now) do
        if not state[id] then
            post('ontriggerenter', actor)
        end
        post('ontrigger', actor)
    end
    for id, actor in pairs(state) do
        if not now[id] then
            post('ontriggerleave', actor)
        end
    end
    for id in pairs(state) do state[id] = nil end
    for id, actor in pairs(now) do state[id] = actor end
end

--- Builds the local-script table (`engineHandlers`) for the script loaded in
-- this sandbox. Each attached object gets its own sandbox and therefore its
-- own runtime instance and locals. Called as the last line of generated code.
--
-- Engine callbacks only queue events; the script runs once per frame from
-- onUpdate with every pending event (see obs.execute), as in the original,
-- where events are consumed by the next run of the object's script.
function obs.makeLocalScript()
    -- engine bindings for the local context; absent outside it (e.g. console lab)
    pcall(require, 'openmw_aux.obscript.bindings')

    local entry = obs._current
    if entry == nil then
        for _, e in pairs(obs._scripts) do
            entry = e
            break
        end
    end
    if entry == nil then
        return {} -- script registered no blocks
    end

    if obs._trace then
        local blocks = {}
        for event in pairs(entry.handlers) do
            blocks[#blocks + 1] = event
        end
        table.sort(blocks)
        obs._current = entry
        print('[obscript-trace] ' .. entry.name .. ': attached; blocks: ' .. table.concat(blocks, ', '))
        for _, event in ipairs(blocks) do
            if not dispatchedBlocks[event] then
                traceOnce('[obscript-missing]', 'block:' .. event, 'block ' .. event .. ' (no event source yet)')
            end
        end
        obs._current = nil
    end

    if obs._onLocalScriptReady then
        obs._onLocalScriptReady(entry)
    end

    local hasTriggerBlocks = obs.hasBlock(entry, 'ontriggerenter')
        or obs.hasBlock(entry, 'ontrigger')
        or obs.hasBlock(entry, 'ontriggerleave')
    local triggerState = {}  -- actor id -> actor, for actors inside last frame

    local pending = {}  -- event -> list of { ref = ... }, consumed by the next run
    local function post(event, ref)
        local list = pending[event]
        if list == nil then
            list = {}
            pending[event] = list
        end
        list[#list + 1] = { ref = ref }
    end

    return {
        engineHandlers = {
            onUpdate = function(dt)
                obs._dt = dt
                if hasTriggerBlocks and obs._triggerProbe then
                    pollTriggers(post, triggerState)
                end
                local events = pending
                pending = {}
                obs.execute(entry, { events = events })
                if obs._publishLocals then
                    obs._publishLocals(entry, dt)
                end
            end,
            onActive = function()
                -- OnLoad: the object's 3D is loaded, i.e. it became active in the scene.
                post('onload', nil)
            end,
            onActivated = function(actor)
                -- Opening a container counts as activation, so OnOpen blocks
                -- are raised from here as well (the original raises OnOpen
                -- separately, when the door or container actually opens).
                post('onactivate', actor)
                post('onopen', actor)
            end,
            onSave = function()
                local locals = {}
                for k, v in pairs(entry.locals) do
                    locals[k] = v
                end
                return { locals = locals }
            end,
            onLoad = function(data)
                if data and data.locals then
                    entry.locals = setmetatable(data.locals, zerotable_mt)
                end
            end,
        },
        eventHandlers = {
            ObScriptEvent = function(data)
                post(tostring(data.event):lower(), data.ref)
            end,
            -- `set ThisRef.var to x` from another script
            ObScriptSetVar = function(data)
                local key = tostring(data.name):lower()
                local value = data.value
                if entry.ints[key] then value = obs.int(value) end
                entry.locals[key] = value
            end,
        },
    }
end

return obs
