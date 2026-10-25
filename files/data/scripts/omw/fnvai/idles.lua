-- The FO3/FNV idle animation tree (IDLE records).
--
-- IDLE records form a tree: branch records name a folder, leaf records a
-- KF file, and every record carries conditions. The engine walks the tree
-- from a root, takes the first child whose conditions pass, and goes on
-- below it until a leaf is found; a branch with no passing leaf is
-- skipped. Which furniture sequence plays is decided this way too, with
-- GetSitting / GetSleeping (1 loop, 2 enter, 3 in use, 4 exit) and
-- GetFurnitureMarkerID as the conditions.

local core = require('openmw.core')
local I = require('openmw.interfaces')

local ai = core.obscript and core.obscript.ai

local M = {}

local tree = nil

local function log(msg)
    print('[fnvai] ' .. msg)
end

local function build()
    local idles = ai.getIdles()
    local children = {}
    local byEditorId = {}
    for _, idle in pairs(idles) do
        byEditorId[idle.editorId:lower()] = idle
        local list = children[idle.parent]
        if list == nil then
            list = {}
            children[idle.parent] = list
        end
        list[#list + 1] = idle
    end
    -- siblings are chained through "previous"
    for parent, list in pairs(children) do
        local byPrevious = {}
        for _, idle in ipairs(list) do
            if byPrevious[idle.previous] == nil then
                byPrevious[idle.previous] = idle
            end
        end
        local ordered, seen = {}, {}
        local current = byPrevious['']
        while current ~= nil and not seen[current.id] do
            ordered[#ordered + 1] = current
            seen[current.id] = true
            current = byPrevious[current.id]
        end
        for _, idle in ipairs(list) do
            if not seen[idle.id] then
                ordered[#ordered + 1] = idle
            end
        end
        children[parent] = ordered
    end
    tree = { idles = idles, children = children, byEditorId = byEditorId }
end

local function getTree()
    if tree == nil then
        build()
    end
    return tree
end

function M.isLeaf(idle)
    return idle.model:lower():sub(-3) == '.kf'
end

-- KF path of a leaf, as core.obscript.ai.playIdle wants it (under meshes/, as the record has it)
function M.modelPath(idle)
    return (idle.model:gsub('\\', '/'):lower())
end

function M.get(id)
    return getTree().idles[id]
end

function M.find(editorId)
    return getTree().byEditorId[editorId:lower()]
end

function M.children(idle)
    return getTree().children[idle.id] or {}
end

local function conditionsPass(idle, npc, overrides)
    if #idle.conditions == 0 then return true end
    local dialogue = I.FNVDialogue
    if dialogue == nil or dialogue.checkConditions == nil then return false end
    return (dialogue.checkConditions(idle.conditions, npc, overrides))
end

local function pickBelow(idle, npc, overrides, depth)
    for _, child in ipairs(M.children(idle)) do
        if conditionsPass(child, npc, overrides) then
            if M.isLeaf(child) then
                return child
            end
            local leaf = pickBelow(child, npc, overrides, depth + 1)
            if leaf ~= nil then return leaf end
        end
    end
    return nil
end

--- Picks the leaf the engine would play below a root record for npc.
-- overrides: condition function index -> function(cond, subject) (see FNVDialogue.checkConditions).
-- @return the IDLE record, or nil
function M.pick(root, npc, overrides)
    if type(root) == 'string' then
        root = M.find(root)
    end
    if root == nil then return nil end
    if not conditionsPass(root, npc, overrides) then return nil end
    if M.isLeaf(root) then return root end
    return pickBelow(root, npc, overrides, 0)
end

-- Condition answers for the furniture branch of the tree.
-- state: { sitting = 0..4, sleeping = 0..4, marker = marker type, furniture = object, usedItem = form id,
--          procedure = GetCurrentAIProcedure value, lastIdle = form id, package = package type }
function M.furnitureOverrides(state)
    return {
        [159] = function() return state.sitting or 0 end, -- GetSitting
        [49] = function() return state.sleeping or 0 end, -- GetSleeping
        [160] = function() return state.marker or 0 end, -- GetFurnitureMarkerID
        [163] = function(cond) -- IsCurrentFurnitureObj
            return (state.furniture ~= nil and cond.param1Form == state.furniture.recordId) and 1 or 0
        end,
        [246] = function(cond) -- GetIsUsedItem: 'random' stands for whatever food is in hand
            if state.usedItem == 'random' then return math.random() < 0.5 and 1 or 0 end
            return cond.param1Form == state.usedItem and 1 or 0
        end,
        [247] = function() return 0 end, -- GetIsUsedItemType
        [259] = function() return 0 end, -- GetUsedItemActivate
        [451] = function(cond) return cond.param1Form == state.lastIdle and 1 or 0 end, -- IsLastIdlePlayed
        [143] = function() return state.procedure or 0 end, -- GetCurrentAIProcedure
        [110] = function() return state.package or 0 end, -- GetCurrentAIPackage
        [141] = function() return 0 end, -- IsTalking
        [392] = function() return 0 end, -- IsPC1stPerson
        [365] = function() return 0 end, -- IsChild
        [36] = function() return 0 end, -- GetMenuMode
        [63] = function() return 0 end, -- GetAttacked
        [91] = function() return 0 end, -- GetIsAlerted
        [289] = function() return 0 end, -- IsInCombat
        [286] = function() return 0 end, -- IsSneaking
        [287] = function() return 0 end, -- IsRunning
        [288] = function() return 0 end, -- GetFriendHit
        [101] = function() return 0 end, -- IsWeaponOut
        [98] = function() return 0 end, -- GetPlayerControlsDisabled
    }
end

--- Lists the tree below a record, for the console.
function M.dump(root, depth)
    if type(root) == 'string' then root = M.find(root) end
    if root == nil then return end
    depth = depth or 0
    log(('%s%s %s'):format(('  '):rep(depth), root.editorId, root.model))
    for _, child in ipairs(M.children(root)) do
        M.dump(child, depth + 1)
    end
end

return M
