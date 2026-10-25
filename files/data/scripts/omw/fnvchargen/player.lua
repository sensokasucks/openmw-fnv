-- FO3/FNV character creation menus: race (sex and name for now), name,
-- S.P.E.C.I.A.L., tag skills and traits.
--
-- Quest scripts open these with ShowRaceMenu, GetPlayerName / ShowNameMenu,
-- ShowSPECIALMenu / ShowLoveTesterMenuParams, ShowTagSkillMenu / SetTagSkills
-- and ShowTraitMenu. scripts/omw/fnvdialogue/global.lua runs those commands:
-- this script registers for them with the global event FNVRegisterMenu, gets
-- FNVOpenMenu { name, menuType } when one opens, and sends FNVMenuClosed
-- { menuType } when the player is done, so the quests' MenuMode blocks run.
-- The choices are applied by the global scripts/omw/fnvstats.lua.
--
-- Like the original, the menus can't be cancelled: Escape keeps them open.
--
-- Not implemented yet: race and face (the race menu only picks the sex), and
-- traits are not perks (HasPerk doesn't see them; only their plain actor value
-- effects are applied).

local async = require('openmw.async')
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local stats = core.obscript and core.obscript.stats
if stats == nil then
    return {}
end

local v2 = util.vector2

local colors = {
    normal = util.color.rgb(0.98, 0.70, 0.25),
    hover = util.color.rgb(1.0, 0.90, 0.60),
    selected = util.color.rgb(1.0, 0.95, 0.80),
    dim = util.color.rgb(0.50, 0.38, 0.16),
}
local textSize = 18
local WIDTH = 560

-- Menu types of the MenuMode blocks each menu runs (FNVMenuClosed), from the menu table FalloutNV.exe
-- registers (0x9ff970). SetTagSkills opens CharGenMenu.
local RACE_MENU = 1036
local NAME_MENU = 1051       -- TextEditMenu
local SPECIAL_MENU = 1060    -- SPECIALBookMenu
local LOVE_TESTER_MENU = 1074
local TAG_SKILL_MENU = 1048  -- CharGenMenu
local TRAIT_MENU = 1084

local SPECIAL = { 'Strength', 'Perception', 'Endurance', 'Charisma', 'Intelligence', 'Agility', 'Luck' }
-- The Vigor Tester's points: its parameter (VCG01 calls ShowLoveTesterMenuParams 40), else 35.
local SPECIAL_TOTAL = { ShowLoveTesterMenuParams = 40, ShowLoveTesterMenu = 35, ShowSPECIALMenu = 35 }
local SPECIAL_MIN, SPECIAL_MAX = 1, 10 -- inferred, not traced
local SPECIAL_TEXT = {
    Strength = 'Raw physical power. Affects carry weight and melee damage.',
    Perception = 'Awareness. Affects the compass range for enemies and Energy Weapons, Explosives and Lockpick.',
    Endurance = 'Stamina and toughness. Affects health and Survival and Unarmed.',
    Charisma = 'Charm. Affects companions\' nerve and Barter and Speech.',
    Intelligence = 'Knowledge and wits. Affects skill points per level and Medicine, Repair and Science.',
    Agility = 'Coordination. Affects action points and Guns and Sneak.',
    Luck = 'Fate. Affects critical chance and adds to every skill.',
}

-- Big Guns is not a FNV skill.
local SKILLS = { 'Barter', 'EnergyWeapons', 'Explosives', 'Guns', 'Lockpick', 'Medicine', 'MeleeWeapons',
    'Repair', 'Science', 'Sneak', 'Speech', 'Survival', 'Unarmed' }
local SKILL_LABEL = { EnergyWeapons = 'Energy Weapons', MeleeWeapons = 'Melee Weapons' }
local TAG_COUNT = 3 -- SetTagSkills 3 1

-- The base game's traits. `effects` are the actor value changes this engine can apply so far.
local TRAITS = {
    { id = 'BuiltToDestroy', name = 'Built to Destroy',
        text = 'Your weapons score critical hits more often, but they wear out faster.' },
    { id = 'FastShot', name = 'Fast Shot',
        text = 'You attack faster with guns and energy weapons, but less accurately in V.A.T.S.' },
    { id = 'FourEyes', name = 'Four Eyes',
        text = 'Perception is higher while you wear glasses and lower without them.' },
    { id = 'GoodNatured', name = 'Good Natured',
        text = '+5 to Barter, Medicine, Repair, Science and Speech; -5 to Energy Weapons, Explosives, Guns, '
            .. 'Melee Weapons and Unarmed.',
        effects = { Barter = 5, Medicine = 5, Repair = 5, Science = 5, Speech = 5,
            EnergyWeapons = -5, Explosives = -5, Guns = -5, MeleeWeapons = -5, Unarmed = -5 } },
    { id = 'HeavyHanded', name = 'Heavy Handed',
        text = 'Your melee and unarmed attacks hit harder, but their critical hits do less.' },
    { id = 'Kamikaze', name = 'Kamikaze',
        text = '+10 action points, but your Damage Threshold is lower.',
        effects = { ActionPoints = 10 } },
    { id = 'LooseCannon', name = 'Loose Cannon',
        text = 'You throw and place explosives faster, but less far.' },
    { id = 'SmallFrame', name = 'Small Frame',
        text = '+1 Agility, but your limbs are crippled more easily.',
        effects = { Agility = 1 } },
    { id = 'TriggerDiscipline', name = 'Trigger Discipline',
        text = 'You are more accurate with guns and energy weapons, but fire more slowly.' },
    { id = 'WildWasteland', name = 'Wild Wasteland',
        text = 'Unleashes the most bizarre and silly elements of post-apocalyptic America.' },
}
local TRAIT_BY_ID = {}
for _, trait in ipairs(TRAITS) do TRAIT_BY_ID[trait.id] = trait end

local COMMANDS = {
    ShowRaceMenu = 'race',
    GetPlayerName = 'name',
    ShowNameMenu = 'name',
    ShowSPECIALMenu = 'special',
    ShowLoveTesterMenuParams = 'special',
    ShowLoveTesterMenu = 'special',
    ShowTagSkillMenu = 'tags',
    SetTagSkills = 'tags',
    ShowTraitMenu = 'traits',
}
local DEFAULT_MENU_TYPE = {
    ShowRaceMenu = RACE_MENU,
    GetPlayerName = NAME_MENU,
    ShowNameMenu = NAME_MENU,
    ShowSPECIALMenu = SPECIAL_MENU,
    ShowLoveTesterMenuParams = LOVE_TESTER_MENU,
    ShowLoveTesterMenu = LOVE_TESTER_MENU,
    ShowTagSkillMenu = TAG_SKILL_MENU,
    SetTagSkills = TAG_SKILL_MENU,
    ShowTraitMenu = TRAIT_MENU,
}

-- ------------------------------------------------------------ state

local traits = {} -- chosen trait ids, saved with the game
local queue = {}  -- menus asked for while one is open: { kind, menuType }

local element = nil
local current = nil   -- the open menu: { kind, menuType, ... edit state }
local ownsMode = false
local changingMode = false

local function gameSetting(name, fallback)
    local value = stats.gameSetting(name)
    if type(value) == 'number' then return value end
    return fallback
end

local function skillLabel(av)
    return SKILL_LABEL[av] or av
end

local function playerName()
    local ok, rec = pcall(types.NPC.record, self.object)
    return ok and rec and rec.name or ''
end

local function isTagged(av)
    local n = stats.actorValue(av)
    for _, tagged in ipairs(stats.getTagSkills()) do
        if tagged == n then return true end
    end
    return false
end

-- ------------------------------------------------------------ widgets

local function text(str, color, size)
    return {
        type = ui.TYPE.Text,
        props = { text = str, textSize = size or textSize, textColor = color or colors.normal, autoSize = true },
    }
end

local function paragraph(str, color)
    return {
        type = ui.TYPE.TextEdit,
        props = {
            text = str,
            textSize = textSize - 2,
            textColor = color or colors.normal,
            autoSize = true,
            readOnly = true,
            multiline = true,
            wordWrap = true,
            size = v2(WIDTH, 0),
        },
    }
end

local function gap(height, width)
    return { props = { size = v2(width or WIDTH, height) } }
end

local function row(content)
    return { type = ui.TYPE.Flex, props = { horizontal = true, autoSize = true, arrange = ui.ALIGNMENT.Center },
        content = ui.content(content) }
end

-- Clickable text; `selected` draws it brighter, `disabled` dims it and ignores clicks.
local function button(label, onClick, opts)
    opts = opts or {}
    local base = opts.disabled and colors.dim or (opts.selected and colors.selected or colors.normal)
    local widget = text(opts.selected and ('[' .. label .. ']') or label, base)
    if opts.disabled then return widget end
    widget.events = {
        mouseClick = async:callback(onClick),
        focusGain = async:callback(function()
            widget.props.textColor = colors.hover
            if element then element:update() end
        end),
        focusLoss = async:callback(function()
            widget.props.textColor = base
            if element then element:update() end
        end),
    }
    return widget
end

-- A label in a column of fixed width, so rows line up.
local function cell(widget, width)
    return { props = { size = v2(width, textSize + 6) }, content = ui.content { widget } }
end

-- ------------------------------------------------------------ window

local render -- forward
local finish -- forward

local function setInterfaceMode()
    changingMode = true
    I.UI.setMode('Interface', { windows = {} })
    changingMode = false
    ownsMode = true
end

local function destroyElement()
    if element then
        element:destroy()
        element = nil
    end
end

local function showWindow(title, content)
    destroyElement()
    local all = ui.content { text(title, colors.hover, 24), gap(10) }
    for _, widget in ipairs(content) do all:add(widget) end
    element = ui.create {
        layer = 'Windows',
        template = I.MWUI.templates.boxSolidThick,
        props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5) },
        content = ui.content {
            {
                template = I.MWUI.templates.padding,
                content = ui.content {
                    {
                        template = I.MWUI.templates.padding,
                        content = ui.content {
                            { type = ui.TYPE.Flex, props = { autoSize = true }, content = all },
                        },
                    },
                },
            },
        },
    }
end

-- ------------------------------------------------------------ race and name

local function nameField(state)
    return {
        template = I.MWUI.templates.box,
        content = ui.content {
            {
                template = I.MWUI.templates.textEditLine,
                props = { text = state.name, size = v2(300, textSize + 4), textSize = textSize,
                    textColor = colors.selected },
                events = {
                    -- No re-render here: that would reset the cursor.
                    textChanged = async:callback(function(s) state.name = s end),
                },
            },
        },
    }
end

local function renderRace(state)
    local content = {
        row { cell(text('Sex'), 120),
            button('Male', function() state.female = false render() end, { selected = not state.female }),
            gap(textSize, 24),
            button('Female', function() state.female = true render() end, { selected = state.female }) },
        gap(12),
        row { cell(text('Name'), 120), nameField(state) },
        gap(12),
        paragraph('Race and face are not available yet.', colors.dim),
        gap(12),
        button('Done', function() finish() end),
    }
    showWindow('Character', content)
end

local function renderName(state)
    showWindow('What is your name?', {
        nameField(state),
        gap(12),
        button('Done', function() finish() end),
    })
end

local function applyRace(state)
    core.sendGlobalEvent('FNVChargenSetSex', { female = state.female })
    if state.name:match('%S') and state.name ~= playerName() then
        core.sendGlobalEvent('FNVChargenSetName', { name = state.name })
    end
end

local function applyName(state)
    if state.name:match('%S') and state.name ~= playerName() then
        core.sendGlobalEvent('FNVChargenSetName', { name = state.name })
    end
end

-- ------------------------------------------------------------ S.P.E.C.I.A.L.

local function specialLeft(state)
    local used = 0
    for _, av in ipairs(SPECIAL) do used = used + state.values[av] end
    return state.total - used
end

local function renderSpecial(state)
    local left = specialLeft(state)
    local content = {}
    for _, av in ipairs(SPECIAL) do
        local value = state.values[av]
        content[#content + 1] = row {
            cell(button(av, function() state.focus = av render() end, { selected = state.focus == av }), 200),
            cell(button('-', function()
                state.values[av] = value - 1
                state.focus = av
                render()
            end, { disabled = value <= SPECIAL_MIN }), 30),
            cell(text(tostring(value), colors.selected), 40),
            cell(button('+', function()
                state.values[av] = value + 1
                state.focus = av
                render()
            end, { disabled = value >= SPECIAL_MAX or left <= 0 }), 30),
        }
    end
    content[#content + 1] = gap(8)
    content[#content + 1] = text('Points left: ' .. left)
    content[#content + 1] = gap(8)
    content[#content + 1] = paragraph(SPECIAL_TEXT[state.focus] or '')
    content[#content + 1] = gap(12)
    content[#content + 1] = button('Done', function() finish() end, { disabled = left ~= 0 })
    showWindow('S.P.E.C.I.A.L.', content)
end

local function applySpecial(state)
    local values = {}
    for _, av in ipairs(SPECIAL) do
        if state.values[av] ~= state.start[av] then values[av] = state.values[av] end
    end
    if next(values) then
        core.sendGlobalEvent('FNVChargenSetBase', { player = self.object, values = values })
    end
end

-- ------------------------------------------------------------ tag skills

local function tagCount(state)
    local n = 0
    for _ in pairs(state.tags) do n = n + 1 end
    return n
end

local function renderTags(state)
    local bonus = gameSetting('fAVDTagSkillBonus', 15)
    local chosen = tagCount(state)
    local content = {
        text(string.format('Tag %d skills. Tagged skills start %d points higher.', state.count, bonus)),
        gap(8),
    }
    for _, av in ipairs(SKILLS) do
        local tagged = state.tags[av] == true
        -- the shown value follows the pending choice
        local value = stats.getBase(self.object, av)
        if tagged and not state.wasTagged[av] then value = value + bonus end
        if not tagged and state.wasTagged[av] then value = value - bonus end
        content[#content + 1] = row {
            cell(button(skillLabel(av), function()
                if tagged then
                    state.tags[av] = nil
                elseif chosen < state.count then
                    state.tags[av] = true
                end
                render()
            end, { selected = tagged, disabled = not tagged and chosen >= state.count }), 240),
            cell(text(tostring(math.floor(value + 0.5)), tagged and colors.selected or colors.normal), 50),
        }
    end
    content[#content + 1] = gap(8)
    content[#content + 1] = text(string.format('%d of %d tagged', chosen, state.count))
    content[#content + 1] = gap(12)
    content[#content + 1] = button('Done', function() finish() end, { disabled = chosen ~= state.count })
    showWindow('Tag Skills', content)
end

local function applyTags(state)
    local skills = {}
    for _, av in ipairs(SKILLS) do
        if state.tags[av] then skills[#skills + 1] = av end
    end
    core.sendGlobalEvent('FNVChargenSetTagSkills', { skills = skills })
end

-- ------------------------------------------------------------ traits

local function chosenTraits(state)
    local n = 0
    for _ in pairs(state.chosen) do n = n + 1 end
    return n
end

local function renderTraits(state)
    local chosen = chosenTraits(state)
    local content = {
        text(state.max == 1 and 'Choose 1 trait (optional).'
            or string.format('Choose up to %d traits (optional).', state.max)),
        gap(8),
    }
    for _, trait in ipairs(TRAITS) do
        local picked = state.chosen[trait.id] == true
        content[#content + 1] = button(trait.name, function()
            state.focus = trait.id
            if picked then
                state.chosen[trait.id] = nil
            elseif chosen < state.max then
                state.chosen[trait.id] = true
            end
            render()
        end, { selected = picked })
    end
    content[#content + 1] = gap(8)
    local focus = TRAIT_BY_ID[state.focus]
    content[#content + 1] = paragraph(focus and (focus.name .. ': ' .. focus.text) or '')
    content[#content + 1] = gap(8)
    content[#content + 1] = text(string.format('%d of %d selected', chosen, state.max))
    content[#content + 1] = gap(12)
    content[#content + 1] = button('Done', function() finish() end)
    showWindow('Traits', content)
end

local function applyTraitEffects(ids, sign)
    for _, id in ipairs(ids) do
        local trait = TRAIT_BY_ID[id]
        for av, delta in pairs(trait and trait.effects or {}) do
            core.sendGlobalEvent('FNVStatsChange', { object = self.object, op = 'modify', av = av, value = sign * delta })
        end
    end
end

local function applyTraits(state)
    local new = {}
    for _, trait in ipairs(TRAITS) do
        if state.chosen[trait.id] then new[#new + 1] = trait.id end
    end
    applyTraitEffects(traits, -1)
    applyTraitEffects(new, 1)
    traits = new
end

-- ------------------------------------------------------------ menus

local menus = {
    race = {
        init = function(state)
            state.female = stats.isFemale(self.object)
            state.name = playerName()
        end,
        render = renderRace,
        apply = applyRace,
    },
    name = {
        init = function(state) state.name = playerName() end,
        render = renderName,
        apply = applyName,
    },
    special = {
        init = function(state)
            state.values, state.start = {}, {}
            local sum = 0
            for _, av in ipairs(SPECIAL) do
                local value = math.floor(stats.getBase(self.object, av) + 0.5)
                value = math.max(SPECIAL_MIN, math.min(SPECIAL_MAX, value))
                state.values[av], state.start[av] = value, value
                sum = sum + value
            end
            state.total = math.max(state.points or SPECIAL_TOTAL[state.command] or 35, sum)
            state.focus = SPECIAL[1]
        end,
        render = renderSpecial,
        apply = applySpecial,
    },
    tags = {
        init = function(state)
            state.tags, state.wasTagged = {}, {}
            local count = 0
            for _, av in ipairs(SKILLS) do
                if isTagged(av) then
                    state.tags[av], state.wasTagged[av] = true, true
                    count = count + 1
                end
            end
            state.count = math.max(state.points or TAG_COUNT, count)
        end,
        render = renderTags,
        apply = applyTags,
    },
    traits = {
        init = function(state)
            state.chosen = {}
            for _, id in ipairs(traits) do state.chosen[id] = true end
            state.max = math.max(1, math.floor(gameSetting('iTraitMenuMaxNumTraits', 2)))
            state.focus = TRAITS[1].id
        end,
        render = renderTraits,
        apply = applyTraits,
    },
}

render = function()
    if current then menus[current.kind].render(current) end
end

-- `points`: the command's first parameter where it has one (SPECIAL points, number of tags), if known.
local function open(kind, menuType, command, points)
    current = { kind = kind, menuType = menuType, command = command, points = points }
    menus[kind].init(current)
    if I.UI.getMode() ~= 'Interface' then
        setInterfaceMode()
    end
    render()
end

finish = function()
    if current == nil then return end
    local menu = current
    current = nil
    destroyElement()
    menus[menu.kind].apply(menu)
    core.sendGlobalEvent('FNVMenuClosed', { menuType = menu.menuType })
    if #queue > 0 then
        local nextMenu = table.remove(queue, 1)
        open(nextMenu.kind, nextMenu.menuType, nextMenu.command, nextMenu.points)
        return
    end
    if ownsMode then
        ownsMode = false
        changingMode = true
        I.UI.removeMode('Interface')
        changingMode = false
    end
end

local function register()
    for command in pairs(COMMANDS) do
        core.sendGlobalEvent('FNVRegisterMenu', { name = command })
    end
end

return {
    interfaceName = 'FNVChargen',
    ---
    -- @module FNVChargen
    -- @context player
    -- @usage require('openmw.interfaces').FNVChargen.open('ShowSPECIALMenu')
    interface = {
        version = 0,
        --- Open the menu a command opens ('ShowRaceMenu', 'ShowTraitMenu', ...), for testing; `points` is its
        -- optional parameter (ShowLoveTesterMenuParams 40, SetTagSkills 3).
        open = function(command, points)
            local kind = COMMANDS[command]
            if kind == nil then error('Unknown menu command: ' .. tostring(command)) end
            local menu = { kind = kind, menuType = DEFAULT_MENU_TYPE[command], command = command, points = points }
            if current then
                queue[#queue + 1] = menu
            else
                open(menu.kind, menu.menuType, menu.command, menu.points)
            end
        end,
        --- The chosen trait ids ('GoodNatured', ...).
        getTraits = function()
            local copy = {}
            for i, id in ipairs(traits) do copy[i] = id end
            return copy
        end,
    },
    engineHandlers = {
        onInit = register,
        onSave = function()
            return { traits = traits }
        end,
        onLoad = function(data)
            traits = {}
            for _, id in ipairs(data and data.traits or {}) do
                if TRAIT_BY_ID[id] then traits[#traits + 1] = id end
            end
            register()
        end,
    },
    eventHandlers = {
        FNVOpenMenu = function(data)
            local kind = COMMANDS[data.name]
            if kind == nil then
                -- not ours: close it at once so the quest doesn't wait
                core.sendGlobalEvent('FNVMenuClosed', { menuType = data.menuType })
                return
            end
            -- `args` if the global script passes the command's parameters
            local points = data.args and tonumber(data.args[1])
            if points ~= nil and points <= 0 then points = nil end
            local menu = { kind = kind, menuType = data.menuType or DEFAULT_MENU_TYPE[data.name],
                command = data.name, points = points }
            if current then
                queue[#queue + 1] = menu
            else
                open(menu.kind, menu.menuType, menu.command, menu.points)
            end
        end,
        UiModeChanged = function(data)
            if changingMode or current == nil then return end
            if data.newMode ~= 'Interface' then
                -- Escape, or the dialogue window closing under the menu: keep the menu open
                setInterfaceMode()
                render()
            end
        end,
    },
}
