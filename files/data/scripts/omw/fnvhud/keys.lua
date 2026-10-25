-- Replaces the key tokens in FNV texts with the key bound here: tutorial
-- messages say "Use &-sUActnForward;&-sUActnSldleft;&-sUActnBack; to move",
-- and the original puts the key of each user action (sUActn<Name>) there.
-- Player context only (openmw.input).

local input = require('openmw.input')

local M = {}

-- FNV user action -> OpenMW action, or a fixed key where OpenMW has no action
local ACTIONS = {
    forward = 'MoveForward',
    back = 'MoveBackward',
    sldleft = 'MoveLeft',
    sldright = 'MoveRight',
    activate = 'Activate',
    use = 'Use',
    attack = 'Use',
    run = 'Run',
    alwaysrun = 'AlwaysRun',
    automove = 'AutoMove',
    jump = 'Jump',
    crouch = 'Sneak',
    sneak = 'Sneak',
    togglepov = 'TogglePOV',
    menumode = 'Inventory',
    pipboy = 'Inventory',
    rest = 'Rest',
    wait = 'Rest',
    readyitem = 'ToggleWeapon',
    readyweapon = 'ToggleWeapon',
    quicksave = 'QuickSave',
    quickload = 'QuickLoad',
}
for i = 1, 8 do ACTIONS['hotkey' .. i] = 'QuickKey' .. i end
-- keys scripts/omw/fnvcombat/player.lua reads itself, and FNV's defaults for the rest
local FIXED = {
    reload = 'R',
    block = 'Right Mouse',
    aim = 'Right Mouse',
    grab = 'Z',
    vats = 'V',
}

local function keyName(action)
    local ok, name = pcall(input._getActionKeyName, action)
    if not ok or name == nil or name == '' or name:find('Interface:None', 1, true) then return nil end
    name = name:gsub('#{sMouse}', 'Mouse'):gsub('##', '#')
    if name == 'Mouse 1' then return 'Left Mouse' end
    if name == 'Mouse 3' then return 'Right Mouse' end
    return name
end

--- The key for an FNV user action name ('Forward', 'Sldleft', ...), or nil.
function M.key(fnvName)
    local lower = fnvName:lower()
    if FIXED[lower] then return FIXED[lower] end
    local name = ACTIONS[lower]
    local action = name and input.ACTION[name]
    return action and keyName(action)
end

--- `text` with every `&-sUActn<Name>;` (or `&sUActn<Name>;`) replaced by its key.
function M.expand(text)
    if type(text) ~= 'string' or not text:find('&', 1, true) then return text end
    return (text:gsub('&%-?sUActn(%w+);', function(name)
        return M.key(name) or name
    end))
end

return M
