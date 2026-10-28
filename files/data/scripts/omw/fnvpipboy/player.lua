-- The Pip-Boy 3000, as a flat screen over the game while FNV content is loaded.
-- Tab, as in FNV, or the Inventory key opens it in place of the Morrowind
-- inventory, map, magic and stats windows, which it replaces (I.UI.registerWindow)
-- so that nothing opens them; Tab or Escape closes it. The Journal key opens DATA >
-- Quests. The Inventory key does nothing while it is on the right mouse button,
-- FNV's aim button. Tab no longer switches between first and third person while
-- FNV content is loaded.
--
--   STATS   Status (derived statistics and active effects), S.P.E.C.I.A.L.,
--           Skills, Perks (and traits), General (level, karma, reputations)
--   ITEMS   Weapons, Apparel, Aid, Misc, Ammo: hover for details, click (or
--           Enter) to equip, wear, take off or use, R to drop one (shift: all)
--   DATA    Local Map (OpenMW's top-down render, doors, quest targets),
--           World Map (wheel to zoom, drag to move, click a discovered place
--           twice to fast travel), Quests (click one to make it the compass's
--           quest), Notes
--
-- F1 / F2 / F3 pick STATS / ITEMS / DATA, Left / Right the sub-tab, Up / Down
-- and the mouse wheel move through the list.
--
-- The world pauses while the Pip-Boy is open, as in the original; in co-op it
-- must not, so I.FNVPipBoy.setPauseWhileOpen(false) keeps it running (saved
-- with the game).
--
-- DATA > Radio lists the stations picked up here (scripts/omw/fnvradio);
-- click one to tune in, again to turn the radio off.
--
-- Not done yet: item condition, the limb
-- condition figure on the Status page, the 3D Pip-Boy on the arm.
--
-- From the Lua console (`luap`):
--   I.FNVPipBoy.open('items')
--   I.FNVPipBoy.setPauseWhileOpen(false)

local ambient = require('openmw.ambient')
local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local vfs = require('openmw.vfs')
local I = require('openmw.interfaces')

local rules = require('scripts.omw.fnvcharacter.rules')

if core.obscript == nil or core.obscript.itemInfo == nil
    or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local stats = core.obscript.stats
local combat = core.obscript.combat

local v2 = util.vector2

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    if value == nil then return default end
    return value
end

-- the HUD colour (sHUDColor default 255, 182, 66), as the Pip-Boy's in FNV
local color = util.color.rgb(1.0, 0.714, 0.259)
local dimColor = util.color.rgba(1.0, 0.714, 0.259, 0.45)
local darkColor = util.color.rgb(0.06, 0.04, 0.0)
local backColor = util.color.rgb(0.02, 0.015, 0.0)
local whiteTexture = ui.texture { path = 'white' }

local WIDTH, HEIGHT = 1000, 640
local PAD = 24
local LIST_WIDTH = 400
local ROW = 26
local TEXT = 18
local SMALL = 15
local ICON = 220

local SOUND_DIR = 'sound/fx/ui/pipboy/'
local HUM = SOUND_DIR .. 'ui_pipboy_hum_lp.wav'

local TABS = {
    { id = 'stats', name = 'STATS', subs = {
        { id = 'status', name = 'Status' }, { id = 'special', name = 'S.P.E.C.I.A.L.' },
        { id = 'skills', name = 'Skills' }, { id = 'perks', name = 'Perks' }, { id = 'general', name = 'General' } } },
    { id = 'items', name = 'ITEMS', subs = {
        { id = 'weapon', name = 'Weapons' }, { id = 'apparel', name = 'Apparel' }, { id = 'aid', name = 'Aid' },
        { id = 'misc', name = 'Misc' }, { id = 'ammo', name = 'Ammo' } } },
    { id = 'data', name = 'DATA', subs = { { id = 'local', name = 'Local Map' }, { id = 'map', name = 'World Map' }, { id = 'quests', name = 'Quests' },
        { id = 'notes', name = 'Notes' }, { id = 'radio', name = 'Radio' } } },
}

local element = nil
local open = false
local radioPageTime = 0
local closingByScript = false
local pauseWhileOpen = true
local tabIndex = 1
local subIndex = { 1, 1, 1 }
local selected = {} -- sub-tab id -> row index
local scroll = {} -- sub-tab id -> first row shown
local rows = {} -- rows of the current sub-tab
local data = { quests = {}, effects = {}, worn = {} } -- from scripts/omw/fnvpipboy/global.lua
local message = nil
local messageTime = 0
-- The view (first or third person) when Tab went down, and frames left to put it back: OpenMW's view toggle
-- (scripts/omw/camera) is also on Tab and switches the view when the Pip-Boy closes.
local viewMode = nil
local viewRestoreFrames = 0
-- The view toggle is off from a Tab press until Tab is up again (see onKeyPress).
local tabBlocksView = false

-- ------------------------------------------------------------ helpers

local textures = {}
local function texture(path)
    if path == nil or path == '' then return nil end
    path = path:gsub('\\', '/'):lower()
    if not path:find('^textures/') then path = 'textures/' .. path end
    if textures[path] == nil then
        local ok, tex = pcall(ui.texture, { path = path })
        textures[path] = ok and tex or false
    end
    return textures[path] or nil
end

local function playSound(name)
    pcall(ambient.playSoundFile, SOUND_DIR .. name .. '.wav')
end

local function text(str, props)
    props = props or {}
    props.text = tostring(str)
    props.textColor = props.textColor or color
    props.textSize = props.textSize or TEXT
    props.font = props.font or 'FalloutFont2' -- stats_menu.xml's and inventory_menu.xml's font: Monofonto
    if props.autoSize == nil then props.autoSize = props.size == nil end
    return { type = ui.TYPE.Text, props = props }
end

local function rect(position, size, col, alpha)
    return { type = ui.TYPE.Image,
        props = { resource = whiteTexture, position = position, size = size, color = col or color, alpha = alpha or 1 } }
end

local function image(path, position, size)
    local tex = texture(path)
    if tex == nil then return nil end
    return { type = ui.TYPE.Image, props = { resource = tex, position = position, size = size, color = color } }
end

local function stat(name)
    local ok, value = pcall(stats.get, self.object, name)
    return ok and value or 0
end

local function permanent(name)
    local ok, value = pcall(stats.getPermanent, self.object, name)
    return ok and value or 0
end

local function round(x)
    return math.floor(x + 0.5)
end

local function showMessage(str)
    message = str
    messageTime = 3
end

-- ------------------------------------------------------------ STATS

local SPECIAL = { 'Strength', 'Perception', 'Endurance', 'Charisma', 'Intelligence', 'Agility', 'Luck' }

local SKILLS = {
    { 'Barter', 'Barter', 'barter' }, { 'EnergyWeapons', 'Energy Weapons', 'energy_weapons' },
    { 'Explosives', 'Explosives', 'explosives' }, { 'Guns', 'Guns', 'small_guns' },
    { 'Lockpick', 'Lockpick', 'lockpick' }, { 'Medicine', 'Medicine', 'medicine' },
    { 'MeleeWeapons', 'Melee Weapons', 'melee' }, { 'Repair', 'Repair', 'repair' },
    { 'Science', 'Science', 'science' }, { 'Sneak', 'Sneak', 'sneak' }, { 'Speech', 'Speech', 'speech' },
    { 'Survival', 'Survival', 'survival' }, { 'Unarmed', 'Unarmed', 'unarmed' },
}

local DERIVED = 'interface/icons/pipboyimages/derived statistics/'

local function statusRows()
    local list = {}
    local function add(label, value, icon)
        list[#list + 1] = { label = label, value = value, icon = icon and (DERIVED .. icon .. '.dds') }
    end
    add('Hit Points', ('%d/%d'):format(round(stat('Health')), round(permanent('Health'))), 'hit_points')
    add('Action Points', ('%d/%d'):format(round(stat('ActionPoints')), round(permanent('ActionPoints'))),
        'actions_points')
    add('Carry Weight', round(stat('CarryWeight')), 'carry_weight')
    add('Damage Threshold', round(stat('DamageThreshold')), 'damage_resistance')
    add('Damage Resistance', round(stat('DamageResist')) .. '%', 'damage_resistance')
    add('Critical Chance', round(stat('CritChance')) .. '%', 'critical_chance')
    add('Melee Damage', round(stat('MeleeDamage')), 'melee_damage')
    add('Unarmed Damage', round(stat('UnarmedDamage')), 'melee_damage')
    add('Poison Resistance', round(stat('PoisonResist')) .. '%', 'poison_resistance')
    add('Rad. Resistance', round(stat('RadResist')) .. '%', 'radiation_resistance')
    add('Radiation', round(stat('RadiationRads')), 'radiation_resistance')
    for _, e in ipairs(data.effects) do
        local left = ''
        if e.remaining and e.remaining >= 0 and e.remaining < 86400 then left = ('%ds'):format(math.ceil(e.remaining)) end
        list[#list + 1] = { label = e.name, value = left, detail = 'Active effect' }
    end
    return list
end

local function specialRows()
    local list = {}
    for _, name in ipairs(SPECIAL) do
        list[#list + 1] = { label = name, value = round(stat(name)),
            icon = 'interface/icons/pipboyimages/s.p.e.c.i.a.l/special_' .. name:lower() .. '.dds' }
    end
    return list
end

local function skillRows()
    local tagged = {}
    local ok, tags = pcall(stats.getTagSkills)
    if ok then for _, av in ipairs(tags) do tagged[av] = true end end
    local list = {}
    for _, s in ipairs(SKILLS) do
        local av = stats.actorValue(s[1])
        list[#list + 1] = { label = s[2] .. (tagged[av] and ' (Tagged)' or ''), value = round(stat(s[1])),
            icon = 'interface/icons/pipboyimages/items/items_skill_mags_' .. s[3] .. '.dds' }
    end
    return list
end

local perkRecords = nil
local function perkRecord(id)
    if perkRecords == nil then
        perkRecords = {}
        local ok, list = pcall(stats.perks)
        if ok then for _, p in ipairs(list) do perkRecords[p.id:lower()] = p end end
    end
    return perkRecords[tostring(id):lower()]
end

local function characterState()
    return storage.globalSection('FNVCharacter'):get('state') or {}
end

local function perkRows()
    local list = {}
    for id, rank in pairs(characterState().perks or {}) do
        local p = perkRecord(id)
        if p and not p.hidden and rank > 0 then
            local label = p.name ~= '' and p.name or p.editorId
            if p.ranks > 1 then label = ('%s (%d/%d)'):format(label, rank, p.ranks) end
            list[#list + 1] = { label = label, value = p.isTrait and 'Trait' or '', icon = p.icon, detail = p.description,
                trait = p.isTrait }
        end
    end
    table.sort(list, function(a, b)
        if a.trait ~= b.trait then return a.trait end
        return a.label < b.label
    end)
    if #list == 0 then list[1] = { label = 'No perks yet.', dim = true } end
    return list
end

local KARMA_ICONS = { [3] = 'karma_saintly', [0] = 'karma_good', [1] = 'karma_neutral', [2] = 'karma_bad',
    [4] = 'karma_evil' }

local reputationRecords = nil
local function generalRows()
    local list = {}
    local level = stats.getLevel(self.object)
    local xp = stat('XP')
    local nextXp = rules.xpForLevel(level + 1, gmst)
    list[#list + 1] = { label = 'Level', value = level }
    list[#list + 1] = { label = 'Experience', value = ('%d/%d'):format(round(xp), nextXp) }
    local karma = round(stat('Karma'))
    local alignment = rules.alignmentOf(karma, gmst)
    list[#list + 1] = { label = 'Karma: ' .. rules.alignmentNames[alignment], value = karma,
        icon = 'interface/icons/pipboyimages/karma icons/' .. KARMA_ICONS[alignment] .. '.dds' }
    if reputationRecords == nil then
        reputationRecords = {}
        local ok, reps = pcall(stats.reputations)
        if ok then for _, r in ipairs(reps) do reputationRecords[r.id:lower()] = r end end
    end
    local reps = {}
    for id, points in pairs(characterState().reputation or {}) do
        local r = reputationRecords[tostring(id):lower()]
        if r and ((points.fame or 0) > 0 or (points.infamy or 0) > 0) then
            local fame = rules.tier(points.fame or 0, r.value, gmst)
            local infamy = rules.tier(points.infamy or 0, r.value, gmst)
            reps[#reps + 1] = { label = r.name ~= '' and r.name or r.editorId, value = rules.standing(fame, infamy),
                detail = ('Fame %d, infamy %d'):format(points.fame or 0, points.infamy or 0) }
        end
    end
    table.sort(reps, function(a, b) return a.label < b.label end)
    for _, r in ipairs(reps) do list[#list + 1] = r end
    return list
end

-- ------------------------------------------------------------ ITEMS

local CAPS = core.obscript.resolveItemEditorId and core.obscript.resolveItemEditorId('Caps001')

local function isCaps(item)
    return CAPS ~= nil and item.recordId:lower() == CAPS:lower()
end

local function playerWeaponId()
    local weapon = I.FNVCombat and I.FNVCombat.getWeapon()
    return weapon and weapon.id:lower() or nil
end

local function isWorn(recordId)
    local key = recordId:lower()
    for _, w in ipairs(data.worn) do
        if w == key then return true end
    end
    return false
end

-- FNV items in the inventory, with what the list and the detail panel show
local function inventoryItems()
    local list = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        local ok, info = pcall(core.obscript.itemInfo, item)
        if ok and info.editorId ~= nil and info.name ~= '' and not isCaps(item) then
            list[#list + 1] = { item = item, info = info }
        end
    end
    return list
end

local function capsCount()
    if CAPS == nil then return 0 end
    local inventory = types.Actor.inventory(self)
    local ok, n = pcall(inventory.countOf, inventory, CAPS)
    return ok and n or 0
end

local function carried()
    local total = 0
    for _, e in ipairs(inventoryItems()) do total = total + (e.info.weight or 0) * e.item.count end
    return total
end

local function itemRows(category)
    local weaponId = playerWeaponId()
    local list = {}
    for _, e in ipairs(inventoryItems()) do
        if e.info.category == category then
            local info = e.info
            local equipped = false
            if category == 'weapon' then
                equipped = weaponId ~= nil and info.recordId:lower() == weaponId
            elseif category == 'apparel' then
                equipped = isWorn(info.recordId)
            end
            local label = info.name
            if e.item.count > 1 then label = ('%s (%d)'):format(label, e.item.count) end
            list[#list + 1] = { label = label, item = e.item, info = info, equipped = equipped, icon = info.icon }
        end
    end
    table.sort(list, function(a, b) return a.info.name < b.info.name end)
    if #list == 0 then list[1] = { label = 'Nothing here.', dim = true } end
    return list
end

local function itemDetails(row)
    local info = row.info
    local lines = {}
    if info.category == 'weapon' then
        local ok, w = pcall(combat.getWeapon, info.recordId)
        if ok and w then
            lines[#lines + 1] = { 'DAM', round(w.damage or 0) }
            if (w.clipSize or 0) > 0 then
                local ammo = w.ammoTypes and w.ammoTypes[1]
                lines[#lines + 1] = { 'Ammo', ammo and (ammo.shortName ~= '' and ammo.shortName or ammo.name) or '--' }
                lines[#lines + 1] = { 'Clip', w.clipSize }
            end
        end
    elseif info.category == 'apparel' then
        lines[#lines + 1] = { 'DT', round(info.dt or 0) }
        if (info.dr or 0) ~= 0 then lines[#lines + 1] = { 'DR', round(info.dr) } end
    end
    lines[#lines + 1] = { 'WG', ('%g'):format(math.floor((info.weight or 0) * 10 + 0.5) / 10) }
    lines[#lines + 1] = { 'VAL', info.value or 0 }
    return lines
end

-- ------------------------------------------------------------ DATA

local function questRows()
    local list = {}
    for _, q in ipairs(data.quests) do
        list[#list + 1] = { label = q.name, quest = q, dim = q.completed, active = q.key == data.activeQuest }
    end
    if #list == 0 then list[1] = { label = 'No quests yet.', dim = true } end
    return list
end

local function noteRecord(id)
    local ok, rec = pcall(types.ESM4Note.record, id)
    return ok and rec or nil
end

local function noteRows()
    local list = {}
    local ids = I.ESM4Notes and I.ESM4Notes.getNotes() or {}
    for i = #ids, 1, -1 do -- newest first
        local rec = noteRecord(ids[i])
        if rec then
            list[#list + 1] = { label = rec.name ~= '' and rec.name or rec.editorId, note = rec }
        end
    end
    if #list == 0 then list[1] = { label = 'No notes yet.', dim = true } end
    return list
end

-- Stations the Pip-Boy picks up here (scripts/omw/fnvradio/player.lua); the tuned one is marked.
local function radioRows()
    local list = {}
    local r = I.FNVRadio
    for _, s in ipairs(r and r.getStations() or {}) do
        list[#list + 1] = { label = s.name, station = s, active = s.tuned }
    end
    if #list == 0 then list[1] = { label = 'No signal.', dim = true } end
    return list
end

-- ------------------------------------------------------------ actions

local render

local function currentSub()
    return TABS[tabIndex].subs[subIndex[tabIndex]].id
end

local function activate(row)
    if row == nil or row.dim and row.quest == nil then return end
    local sub = currentSub()
    if row.item then
        local info = row.info
        if info.category == 'weapon' then
            if row.equipped then
                I.FNVCombat.unequip()
            else
                I.FNVCombat.equip(info.recordId)
            end
            playSound('ui_pipboy_select')
        elseif info.category == 'apparel' then
            core.sendGlobalEvent('FNVPipBoyItem',
                { player = self.object, item = row.item, action = row.equipped and 'remove' or 'wear' })
            playSound('ui_pipboy_select')
        elseif info.category == 'aid' then
            core.sendGlobalEvent('FNVPipBoyItem', { player = self.object, item = row.item, action = 'use' })
            playSound('ui_pipboy_select')
        end
    elseif row.quest then
        core.sendGlobalEvent('FNVPipBoySetActiveQuest', { player = self.object, quest = row.quest.key })
        data.activeQuest = row.quest.key
        playSound('ui_pipboy_select')
    elseif row.note and row.note.noteType == 'Sound' and row.note.sound then
        pcall(ambient.playSound, row.note.sound)
    elseif row.station and I.FNVRadio then
        I.FNVRadio.tune(row.station.id) -- the tuned one again turns the radio off
    end
    render()
end

local function drop(row, all)
    if row == nil or row.item == nil then return end
    if row.info.category == 'weapon' and row.equipped then I.FNVCombat.unequip() end
    core.sendGlobalEvent('FNVPipBoyItem',
        { player = self.object, item = row.item, action = 'drop', count = all and row.item.count or 1 })
    playSound('ui_pipboy_select')
end

local function select(index, quiet)
    local sub = currentSub()
    index = math.max(1, math.min(#rows, index))
    if selected[sub] == index then return end
    selected[sub] = index
    if not quiet then playSound('ui_pipboy_highlight') end
    render()
end

local function setTab(t, s)
    if t ~= tabIndex then playSound('ui_pipboy_tab') elseif s ~= subIndex[t] then playSound('ui_pipboy_mode') end
    tabIndex = t
    if s then subIndex[t] = s end
    render()
end

-- ------------------------------------------------------------ layout

local function buildRows()
    local sub = currentSub()
    if sub == 'status' then return statusRows() end
    if sub == 'special' then return specialRows() end
    if sub == 'skills' then return skillRows() end
    if sub == 'perks' then return perkRows() end
    if sub == 'general' then return generalRows() end
    if sub == 'quests' then return questRows() end
    if sub == 'notes' then return noteRows() end
    if sub == 'radio' then return radioRows() end
    if sub == 'map' or sub == 'local' then return {} end
    return itemRows(sub)
end

local function header()
    local tab = TABS[tabIndex].id
    local parts = {}
    if tab == 'stats' then
        local level = stats.getLevel(self.object)
        parts = {
            ('LVL %d'):format(level),
            ('HP %d/%d'):format(round(stat('Health')), round(permanent('Health'))),
            ('AP %d/%d'):format(round(stat('ActionPoints')), round(permanent('ActionPoints'))),
            ('XP %d/%d'):format(round(stat('XP')), rules.xpForLevel(level + 1, gmst)),
        }
    elseif tab == 'items' then
        parts = {
            ('WG %d/%d'):format(round(carried()), round(stat('CarryWeight'))),
            ('HP %d/%d'):format(round(stat('Health')), round(permanent('Health'))),
            ('DT %d'):format(round(stat('DamageThreshold'))),
            ('CAPS %d'):format(capsCount()),
        }
    else
        local ok, date = pcall(core.obscript.getGameDate)
        if ok and date then
            local hour = date.hour or 0
            parts = { ('%02d.%02d.%d, %02d:%02d'):format((date.month or 0) + 1, date.day or 1, date.year or 2281,
                math.floor(hour), math.floor((hour % 1) * 60)) }
        end
    end
    return table.concat(parts, '    ')
end

local function rowWidget(i, row, y, isSelected)
    local content = {}
    if isSelected then content[#content + 1] = rect(v2(0, 0), v2(LIST_WIDTH, ROW), color, 0.9) end
    local fg = isSelected and darkColor or (row.dim and dimColor or color)
    local mark = ''
    if row.equipped or row.active then mark = '> ' end
    content[#content + 1] = text(mark .. row.label, { position = v2(8, 3), size = v2(LIST_WIDTH - 110, ROW),
        textColor = fg })
    if row.value ~= nil and row.value ~= '' then
        content[#content + 1] = text(row.value, { position = v2(LIST_WIDTH - 108, 3), size = v2(100, ROW),
            textColor = fg, textAlignH = ui.ALIGNMENT.End })
    end
    return {
        type = ui.TYPE.Widget,
        props = { position = v2(0, y), size = v2(LIST_WIDTH, ROW) },
        content = ui.content(content),
        events = {
            focusGain = async:callback(function() select(i) end),
            mouseClick = async:callback(function()
                select(i, true)
                activate(rows[i])
            end),
        },
    }
end

local function detailPanel(row, width, height)
    local content = {}
    if row == nil then return content end
    local y = 0
    local icon = row.icon and image(row.icon, v2((width - ICON) / 2, 0), v2(ICON, ICON))
    if icon then
        content[#content + 1] = icon
        y = ICON + 12
    end
    if row.item then
        content[#content + 1] = text(row.info.name, { position = v2(0, y), size = v2(width, 24), textSize = 20,
            textAlignH = ui.ALIGNMENT.Center })
        y = y + 32
        local lines = itemDetails(row)
        local cell = math.floor(width / #lines)
        for i, l in ipairs(lines) do
            content[#content + 1] = rect(v2((i - 1) * cell + 2, y), v2(cell - 4, 44), color, 0.12)
            content[#content + 1] = text(l[1], { position = v2((i - 1) * cell, y + 2), size = v2(cell, 20),
                textSize = SMALL, textAlignH = ui.ALIGNMENT.Center })
            content[#content + 1] = text(l[2], { position = v2((i - 1) * cell, y + 20), size = v2(cell, 22),
                textAlignH = ui.ALIGNMENT.Center })
        end
        y = y + 56
        local hint
        local cat = row.info.category
        if cat == 'weapon' or cat == 'apparel' then
            hint = row.equipped and 'Click) Unequip' or 'Click) Equip'
        elseif cat == 'aid' then
            hint = 'Click) Use'
        end
        hint = (hint and (hint .. '    ') or '') .. 'R) Drop'
        content[#content + 1] = text(hint, { position = v2(0, y), size = v2(width, 20), textSize = SMALL,
            textColor = dimColor, textAlignH = ui.ALIGNMENT.Center })
    elseif row.quest then
        content[#content + 1] = text(row.quest.name, { position = v2(0, y), size = v2(width, 24), textSize = 20 })
        y = y + 34
        for _, o in ipairs(row.quest.objectives) do
            content[#content + 1] = text((o.completed and '[x] ' or '[ ] ') .. o.text, {
                position = v2(0, y), size = v2(width, 44), multiline = true, wordWrap = true,
                textColor = o.completed and dimColor or color })
            y = y + 46
            if y > height - 40 then break end
        end
        if not row.quest.completed then
            content[#content + 1] = text(row.active and 'Shown on the compass' or 'Click) Show on the compass', {
                position = v2(0, height - 20), size = v2(width, 20), textSize = SMALL, textColor = dimColor })
        end
    elseif row.station then
        local s = row.station
        content[#content + 1] = text(s.name, { position = v2(0, y), size = v2(width, 24), textSize = 20,
            textAlignH = ui.ALIGNMENT.Center })
        y = y + 40
        -- signal strength, as five bars
        local bars = math.max(1, math.ceil(s.strength * 5))
        for i = 1, 5 do
            local h = 8 + i * 8
            content[#content + 1] = rect(v2(width / 2 - 70 + (i - 1) * 28, y + 48 - h), v2(20, h), color,
                i <= bars and 0.9 or 0.15)
        end
        y = y + 64
        local now = row.active and I.FNVRadio.getNowPlaying and I.FNVRadio.getNowPlaying()
        if now and now ~= '' then
            content[#content + 1] = text(now, { position = v2(0, y), size = v2(width, height - y - 30),
                multiline = true, wordWrap = true, textSize = SMALL, textAlignH = ui.ALIGNMENT.Center,
                textAlignV = ui.ALIGNMENT.Start })
        end
        content[#content + 1] = text(row.active and 'Click) Turn the radio off' or 'Click) Tune in', {
            position = v2(0, height - 20), size = v2(width, 20), textSize = SMALL, textColor = dimColor,
            textAlignH = ui.ALIGNMENT.Center })
    elseif row.note then
        local rec = row.note
        content[#content + 1] = text(row.label, { position = v2(0, y), size = v2(width, 24), textSize = 20 })
        y = y + 34
        if rec.noteType == 'Image' and rec.texture ~= '' then
            local img = image(rec.texture, v2(0, y), v2(width, math.min(width, height - y)))
            if img then content[#content + 1] = img end
        else
            local body = rec.text
            if rec.noteType ~= 'Text' then
                body = (rec.noteType == 'Sound' and rec.sound) and 'Click) Play the recording'
                    or ('(' .. rec.noteType .. ' recording: playback is not supported yet.)')
            end
            content[#content + 1] = text(body, { position = v2(0, y), size = v2(width, height - y), multiline = true,
                wordWrap = true, textSize = SMALL, textAlignV = ui.ALIGNMENT.Start })
        end
    else
        content[#content + 1] = text(row.label, { position = v2(0, y), size = v2(width, 24), textSize = 20,
            textAlignH = ui.ALIGNMENT.Center })
        y = y + 32
        if row.value ~= nil and row.value ~= '' then
            content[#content + 1] = text(row.value, { position = v2(0, y), size = v2(width, 30), textSize = 26,
                textAlignH = ui.ALIGNMENT.Center })
            y = y + 38
        end
        if row.detail and row.detail ~= '' then
            content[#content + 1] = text(row.detail, { position = v2(0, y), size = v2(width, height - y),
                multiline = true, wordWrap = true, textSize = SMALL, textAlignV = ui.ALIGNMENT.Start })
        end
    end
    return content
end

local function tabStrip(labels, current, y, onClick, size)
    local content = {}
    local gap = 28
    local widths = {}
    local total = 0
    for i, label in ipairs(labels) do
        widths[i] = #label * (size * 0.6) + 16
        total = total + widths[i] + (i > 1 and gap or 0)
    end
    local x = (WIDTH - total) / 2
    for i, label in ipairs(labels) do
        local w = widths[i]
        local isCurrent = i == current
        local item = {
            type = ui.TYPE.Widget,
            props = { position = v2(x, y), size = v2(w, size + 10) },
            content = ui.content {
                isCurrent and rect(v2(0, 0), v2(w, size + 10), color, 1) or rect(v2(0, size + 8), v2(w, 2), color, 0.4),
                text(label, { position = v2(0, 4), size = v2(w, size + 4), textSize = size,
                    textColor = isCurrent and darkColor or color, textAlignH = ui.ALIGNMENT.Center }),
            },
            events = { mouseClick = async:callback(function() onClick(i) end) },
        }
        content[#content + 1] = item
        x = x + w + gap
    end
    return content
end

-- ------------------------------------------------------------ the world map

local MARKER_ICONS = { 'city', 'settlement', 'encampment', 'natural_landmark', 'cave', 'factory', 'monument',
    'military', 'office', 'ruins_town', 'ruins_urban', 'ruins_sewer', 'metro', 'vault' }
local MARKER_SIZE = 24

local mapZoom = 0.35 -- part of the map's width on screen
local mapCenter = nil -- normalized map position in the middle of the view; nil: the player
local mapDrag = nil -- { start mouse position, start center }
local hoveredMarker = nil
local pendingTravel = nil

-- Width and height of a DDS texture, from its header.
local textureSizes = {}
local function textureSize(path)
    if textureSizes[path] == nil then
        textureSizes[path] = false
        local ok, file = pcall(vfs.open, path)
        if ok and file then
            local header = file:read(20)
            file:close()
            if header and #header >= 20 and header:sub(1, 4) == 'DDS ' then
                local function u32(at)
                    local a, b, c, d = header:byte(at, at + 3)
                    return a + b * 256 + c * 65536 + d * 16777216
                end
                textureSizes[path] = { x = u32(17), y = u32(13) }
            end
        end
    end
    return textureSizes[path] or nil
end

local function mapTexturePath(map)
    local path = map.texture:gsub('\\', '/'):lower()
    if not path:find('^textures/') then path = 'textures/' .. path end
    return path
end

-- Normalized map position (0..1 across the usable part of the texture) of a world position, from the MNAM
-- cell bounds; FONV's ONAM scale and cell offsets are applied to the cell coordinates (inferred).
local function mapPoint(map, position)
    local cx, cy = position.x / 4096, position.y / 4096
    if map.offsetScale then
        cx = cx * map.offsetScale + map.offsetCellX
        cy = cy * map.offsetScale + map.offsetCellY
    end
    local u = (cx - map.nwCellX) / math.max(1, map.seCellX - map.nwCellX)
    local v = (map.nwCellY - cy) / math.max(1, map.nwCellY - map.seCellY)
    return u, v
end

local cropTextures = {}
local cropCount = 0
local function cropTexture(path, offset, size)
    local key = ('%s|%d|%d|%d|%d'):format(path, offset.x, offset.y, size.x, size.y)
    if cropTextures[key] == nil then
        if cropCount > 64 then
            cropTextures = {}
            cropCount = 0
        end
        cropTextures[key] = ui.texture { path = path, offset = offset, size = size }
        cropCount = cropCount + 1
    end
    return cropTextures[key]
end

local function markerWidget(marker, p)
    local icon = marker.discovered and MARKER_ICONS[marker.type] or 'undiscovered'
    local tex = texture('interface/icons/world map/icon_map_' .. (icon or 'undiscovered') .. '.dds')
    local half = MARKER_SIZE / 2
    local inner = {}
    if hoveredMarker == marker.id then inner[#inner + 1] = rect(v2(0, 0), v2(MARKER_SIZE, MARKER_SIZE), color, 0.35) end
    if tex then
        inner[#inner + 1] = { type = ui.TYPE.Image, props = { resource = tex, size = v2(MARKER_SIZE, MARKER_SIZE),
            color = color, alpha = marker.discovered and 1 or 0.6 } }
    else
        inner[#inner + 1] = rect(v2(8, 8), v2(8, 8), color)
    end
    return {
        type = ui.TYPE.Widget,
        props = { position = p - v2(half, half), size = v2(MARKER_SIZE, MARKER_SIZE) },
        content = ui.content(inner),
        events = {
            focusGain = async:callback(function()
                if hoveredMarker ~= marker.id then
                    hoveredMarker = marker.id
                    playSound('ui_pipboy_highlight')
                    render()
                end
            end),
            mouseClick = async:callback(function()
                if not marker.discovered then
                    showMessage(gmst('sNoFastTravelUndiscovered', 'You cannot fast travel to an undiscovered location.'))
                    render()
                elseif pendingTravel == marker.id then
                    pendingTravel = nil
                    playSound('ui_pipboy_select')
                    core.sendGlobalEvent('FNVPipBoyFastTravel', { player = self.object, marker = marker.id })
                    I.FNVPipBoy.close()
                else
                    pendingTravel = marker.id
                    showMessage(('Click again to fast travel to %s.'):format(marker.name))
                    render()
                end
            end),
        },
    }
end

local function mapView(width, height)
    local content = {}
    local m = data.map
    if m == nil or m.map == nil or m.map.texture == '' then
        content[1] = text('No map here.', { position = v2(0, 0), size = v2(width, 24), textAlignH = ui.ALIGNMENT.Center })
        return content
    end
    local map = m.map
    local path = mapTexturePath(map)
    local texSize = textureSize(path)
    -- MNAM's usable size is in pixels of the 2048 map; FONV ships the 1024 one, so the usable part is
    -- capped at the texture's size
    local tw, th = texSize and texSize.x or 1024, texSize and texSize.y or 1024
    local usable = v2(map.width > 0 and math.min(map.width, tw) or tw, map.height > 0 and math.min(map.height, th) or th)
    -- the visible part of the usable area, in texture pixels
    local viewW = math.min(usable.x, usable.x * mapZoom)
    local viewH = math.min(usable.y, viewW * height / width)
    viewW = viewH * width / height
    local center = mapCenter
    if center == nil then
        local u, v = mapPoint(map, m.player.position)
        center = { u = u, v = v }
    end
    local cx = math.max(viewW / 2, math.min(usable.x - viewW / 2, center.u * usable.x))
    local cy = math.max(viewH / 2, math.min(usable.y - viewH / 2, center.v * usable.y))
    local origin = v2(math.floor(cx - viewW / 2), math.floor(cy - viewH / 2))
    local tex = cropTexture(path, origin, v2(math.floor(viewW), math.floor(viewH)))
    local scale = width / viewW
    local function toScreen(position)
        local u, v = mapPoint(map, position)
        return v2((u * usable.x - origin.x) * scale, (v * usable.y - origin.y) * scale)
    end
    local function inside(p)
        return p.x >= 0 and p.y >= 0 and p.x <= width and p.y <= height
    end

    content[#content + 1] = {
        type = ui.TYPE.Image,
        props = { resource = tex, size = v2(width, height), color = color },
        events = {
            mousePress = async:callback(function(e)
                mapDrag = { start = e.position, u = cx / usable.x, v = cy / usable.y }
            end),
            mouseRelease = async:callback(function() mapDrag = nil end),
            mouseMove = async:callback(function(e)
                if mapDrag == nil then return end
                local d = e.position - mapDrag.start
                mapCenter = { u = mapDrag.u - d.x / scale / usable.x, v = mapDrag.v - d.y / scale / usable.y }
                render()
            end),
        },
    }
    content[#content + 1] = rect(v2(0, 0), v2(width, 1), color, 0.6)
    content[#content + 1] = rect(v2(0, height - 1), v2(width, 1), color, 0.6)

    for _, marker in ipairs(m.markers) do
        local p = toScreen(marker.position)
        if inside(p) then content[#content + 1] = markerWidget(marker, p) end
    end
    -- quest targets: a filled square on a stem, as on the compass
    for _, q in ipairs(m.quest or {}) do
        local p = toScreen(q.position)
        if inside(p) then
            content[#content + 1] = rect(p - v2(7, 18), v2(14, 14), color)
            content[#content + 1] = rect(p - v2(1, 4), v2(2, 6), color)
        end
    end
    -- the player: a square with a dark core, and "You"
    local pp = toScreen(m.player.position)
    if inside(pp) then
        content[#content + 1] = rect(pp - v2(7, 7), v2(14, 14), color)
        content[#content + 1] = rect(pp - v2(3, 3), v2(6, 6), darkColor)
        content[#content + 1] = text('You', { position = pp + v2(10, -10), textSize = SMALL })
    end

    local caption = map.name or ''
    for _, marker in ipairs(m.markers) do
        if marker.id == hoveredMarker then
            caption = marker.discovered and marker.name or '???'
            if marker.discovered then caption = caption .. '    Click) Fast travel' end
        end
    end
    content[#content + 1] = rect(v2(0, height - 26), v2(width, 26), backColor, 0.8)
    content[#content + 1] = text(caption, { position = v2(8, height - 24), size = v2(width - 16, 22),
        textAlignH = ui.ALIGNMENT.Center })
    content[#content + 1] = text('Wheel) Zoom   Drag) Move', { position = v2(width - 220, 4), size = v2(212, 20),
        textSize = SMALL, textColor = dimColor, textAlignH = ui.ALIGNMENT.End })
    return content
end

-- ------------------------------------------------------------ the local map

local localZoom = { exterior = 360, interior = 1400 } -- screen pixels per map tile
local localMap = nil -- the last core.obscript.getLocalMap()
local localMapTime = -1
local localRerender = true -- render the cells around the player again on the next ask (once per opening)

local tileTextures = {}
local function localTileTexture(tile)
    -- render targets are stored bottom row first: show them flipped
    if tileTextures[tile.texture] == nil then
        tileTextures[tile.texture] = ui.texture { path = tile.texture, offset = v2(0, tile.height),
            size = v2(tile.width, -tile.height) }
    end
    return tileTextures[tile.texture]
end

local function localView(width, height)
    local content = {}
    local now = core.getRealTime()
    if localMap == nil or now - localMapTime > 0.5 then
        local ok, res = pcall(core.obscript.getLocalMap, localRerender)
        localRerender = false
        localMap = ok and res or nil
        localMapTime = now
    end
    local ok, here = pcall(core.obscript.localMapPoint, self.position)
    if localMap == nil or not ok or here == nil then
        content[1] = text('No map here.', { position = v2(0, 0), size = v2(width, 24), textAlignH = ui.ALIGNMENT.Center })
        return content
    end
    local zoom = localMap.interior and localZoom.interior or localZoom.exterior
    local center = v2(width / 2, height / 2)
    local origin = v2(here.x + here.u, -here.y + here.v)
    local function toScreen(point)
        return (v2(point.x + point.u, -point.y + point.v) - origin) * zoom + center
    end
    local tiles = {}
    for _, tile in ipairs(localMap.tiles) do
        local topLeft = (v2(tile.x, -tile.y) - origin) * zoom + center
        if topLeft.x < width and topLeft.y < height and topLeft.x + zoom > 0 and topLeft.y + zoom > 0 then
            tiles[#tiles + 1] = { type = ui.TYPE.Image,
                props = { resource = localTileTexture(tile), position = topLeft, size = v2(zoom, zoom),
                    color = color } }
        end
    end
    content[#content + 1] = { type = ui.TYPE.Widget, props = { size = v2(width, height) }, content = ui.content(tiles) }
    content[#content + 1] = rect(v2(0, 0), v2(width, 1), color, 0.6)
    content[#content + 1] = rect(v2(0, height - 1), v2(width, 1), color, 0.6)

    local function inside(p)
        return p.x >= 0 and p.y >= 0 and p.x <= width and p.y <= height
    end
    local doorTex = texture('interface/icons/local map/icon_local_door.dds')
    local m = data.map
    for _, door in ipairs(m and m.doors or {}) do
        local okDoor, point = pcall(core.obscript.localMapPoint, door.position)
        local p = okDoor and point and toScreen(point)
        if p and inside(p) then
            if doorTex then
                content[#content + 1] = { type = ui.TYPE.Image,
                    props = { resource = doorTex, position = p - v2(10, 10), size = v2(20, 20), color = color } }
            else
                content[#content + 1] = rect(p - v2(5, 5), v2(10, 10), color)
            end
            if door.name ~= '' then
                content[#content + 1] = text(door.name, { position = p + v2(12, -9), textSize = SMALL })
            end
        end
    end
    for _, q in ipairs(I.FNVHud and I.FNVHud.getQuestMarkers() or {}) do
        local okQuest, point = pcall(core.obscript.localMapPoint, q.position)
        local p = okQuest and point and toScreen(point)
        if p and inside(p) then
            content[#content + 1] = rect(p - v2(7, 18), v2(14, 14), color)
            content[#content + 1] = rect(p - v2(1, 4), v2(2, 6), color)
        end
    end
    content[#content + 1] = rect(center - v2(7, 7), v2(14, 14), color)
    content[#content + 1] = rect(center - v2(3, 3), v2(6, 6), darkColor)

    content[#content + 1] = rect(v2(0, height - 26), v2(width, 26), backColor, 0.8)
    content[#content + 1] = text(self.cell and self.cell.name or '', { position = v2(8, height - 24),
        size = v2(width - 16, 22), textAlignH = ui.ALIGNMENT.Center })
    content[#content + 1] = text('Wheel) Zoom', { position = v2(width - 220, 4), size = v2(212, 20),
        textSize = SMALL, textColor = dimColor, textAlignH = ui.ALIGNMENT.End })
    return content
end

local function visibleRows(listHeight)
    return math.floor(listHeight / ROW)
end

render = function()
    if not open then return end
    rows = buildRows()
    local sub = currentSub()
    local listTop = 70
    local listHeight = HEIGHT - listTop - 110
    local shown = visibleRows(listHeight)
    local sel = math.max(1, math.min(#rows, selected[sub] or 1))
    selected[sub] = sel
    local first = scroll[sub] or 1
    if sel < first then first = sel end
    if sel >= first + shown then first = sel - shown + 1 end
    first = math.max(1, math.min(first, math.max(1, #rows - shown + 1)))
    scroll[sub] = first

    local content = {
        rect(v2(0, 0), v2(WIDTH, HEIGHT), backColor, 0.92),
        rect(v2(0, 0), v2(WIDTH, 2), color, 0.8),
        rect(v2(0, HEIGHT - 2), v2(WIDTH, 2), color, 0.8),
        rect(v2(0, 0), v2(2, HEIGHT), color, 0.8),
        rect(v2(WIDTH - 2, 0), v2(2, HEIGHT), color, 0.8),
        text(TABS[tabIndex].name, { position = v2(PAD, 18), textSize = 30 }),
        text(header(), { position = v2(PAD + 140, 24), size = v2(WIDTH - 2 * PAD - 140, 24),
            textAlignH = ui.ALIGNMENT.End }),
        rect(v2(PAD, 58), v2(WIDTH - 2 * PAD, 2), color, 0.6),
    }

    if sub == 'map' or sub == 'local' then
        local view = sub == 'map' and mapView or localView
        content[#content + 1] = {
            type = ui.TYPE.Widget,
            props = { position = v2(PAD, listTop), size = v2(WIDTH - 2 * PAD, listHeight) },
            content = ui.content(view(WIDTH - 2 * PAD, listHeight)),
        }
    end

    local list = {}
    for i = first, math.min(#rows, first + shown - 1) do
        list[#list + 1] = rowWidget(i, rows[i], (i - first) * ROW, i == sel)
    end
    content[#content + 1] = {
        type = ui.TYPE.Widget,
        props = { position = v2(PAD, listTop), size = v2(LIST_WIDTH, listHeight) },
        content = ui.content(list),
    }
    if #rows > shown then
        local barHeight = math.max(20, listHeight * shown / #rows)
        local barY = (listHeight - barHeight) * (first - 1) / math.max(1, #rows - shown)
        content[#content + 1] = rect(v2(PAD + LIST_WIDTH + 6, listTop), v2(2, listHeight), color, 0.25)
        content[#content + 1] = rect(v2(PAD + LIST_WIDTH + 4, listTop + barY), v2(6, barHeight), color, 0.8)
    end

    local detailX = PAD + LIST_WIDTH + 40
    local detailWidth = WIDTH - detailX - PAD
    if sub ~= 'map' and sub ~= 'local' then content[#content + 1] = {
        type = ui.TYPE.Widget,
        props = { position = v2(detailX, listTop), size = v2(detailWidth, listHeight) },
        content = ui.content(detailPanel(rows[sel], detailWidth, listHeight)),
    } end

    if message then
        local messageY = (sub == 'map' or sub == 'local') and 76 or HEIGHT - 128
        content[#content + 1] = text(message, { position = v2(PAD, messageY), size = v2(WIDTH - 2 * PAD, 20),
            textSize = SMALL, textAlignH = ui.ALIGNMENT.Center })
    end

    local subLabels = {}
    for i, s in ipairs(TABS[tabIndex].subs) do subLabels[i] = s.name end
    for _, w in ipairs(tabStrip(subLabels, subIndex[tabIndex], HEIGHT - 100, function(i) setTab(tabIndex, i) end,
        SMALL)) do
        content[#content + 1] = w
    end
    local tabLabels = {}
    for i, t in ipairs(TABS) do tabLabels[i] = t.name end
    for _, w in ipairs(tabStrip(tabLabels, tabIndex, HEIGHT - 56, function(i) setTab(i) end, 22)) do
        content[#content + 1] = w
    end

    local screen = ui.screenSize()
    local scale = math.min(1, screen.x / (WIDTH + 40), screen.y / (HEIGHT + 40))
    local layout = {
        layer = 'Windows',
        type = ui.TYPE.Widget,
        props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = v2(WIDTH, HEIGHT) },
        content = ui.content(content),
    }
    if scale < 1 then
        -- smaller screens: keep the layout and let it shrink
        layout.props.size = v2(WIDTH * scale, HEIGHT * scale)
        layout.content = ui.content { {
            type = ui.TYPE.Widget,
            props = { size = v2(WIDTH, HEIGHT), relativeSize = v2(1, 1) },
            content = ui.content(content),
        } }
    end
    if element then
        element.layout = layout
        element:update()
    else
        element = ui.create(layout)
    end
end

-- ------------------------------------------------------------ open and close

local function destroy()
    if element then
        element:destroy()
        element = nil
    end
end

local function refresh()
    core.sendGlobalEvent('FNVPipBoyRefresh', { player = self.object, map = true })
end

local function show(tab, sub)
    for i, t in ipairs(TABS) do
        if t.id == tab then
            tabIndex = i
            for j, s in ipairs(t.subs) do
                if s.id == sub then subIndex[i] = j end
            end
        end
    end
    if not open then
        open = true
        localRerender = true
        if not pauseWhileOpen then I.UI.setPauseOnMode('Interface', false) end
        closingByScript = true
        I.UI.setMode('Interface', { windows = {} })
        closingByScript = false
        playSound('ui_pipboy_access_up')
        pcall(ambient.playSoundFile, HUM, { loop = true, volume = 0.5 })
        if I.FNVHud then I.FNVHud.setVisible(false) end
    end
    refresh()
    render()
end

local function closed()
    if not open then return end
    open = false
    destroy()
    I.UI.setPauseOnMode('Interface', true)
    pcall(ambient.stopSoundFile, HUM)
    playSound('ui_pipboy_access_down')
    if I.FNVHud then I.FNVHud.setVisible(true) end
end

local function close()
    if not open then return end
    closed()
    closingByScript = true
    I.UI.setMode()
    closingByScript = false
end

-- The Inventory or Journal key (scripts/omw/input/playercontrols.lua)
local function menuKey(tab, sub)
    if open then
        close()
        return
    end
    if I.UI.getMode() ~= nil or core.isWorldPaused() then return end
    if tab == nil then
        local ok, name = pcall(input._getActionKeyName, input.ACTION.Inventory)
        if ok and name and name:gsub('#{sMouse}', 'Mouse') == 'Mouse 3' then return end
    end
    show(tab, sub)
end

-- The Morrowind windows of the Interface mode: whatever opens that mode with them (a script, a mod, the
-- Inventory key) gets the Pip-Boy instead, through UiModeChanged below. I.UI (scripts/omw/ui.lua) loads
-- after this script, so this waits for the first frame.
local windowsReplaced = false
local function replaceWindows()
    windowsReplaced = true
    for _, window in ipairs({ 'Inventory', 'Map', 'Magic', 'Stats' }) do
        I.UI.registerWindow(window, function() end, function() end)
    end
end

local function moveSelection(delta)
    if #rows == 0 then return end
    select((selected[currentSub()] or 1) + delta)
end

local function cycleSub(delta)
    local n = #TABS[tabIndex].subs
    setTab(tabIndex, (subIndex[tabIndex] - 1 + delta) % n + 1)
end

return {
    interfaceName = 'FNVPipBoy',
    ---
    -- @module FNVPipBoy
    -- @context player
    interface = {
        version = 0,
        --- Open the Pip-Boy, on 'stats', 'items' or 'data' (default: the last tab), and optionally a sub-tab
        -- ('quests', 'map', ...).
        open = show,
        --- What the Inventory key does (the Journal key passes 'data', 'quests').
        menuKey = menuKey,
        close = close,
        isOpen = function() return open end,
        --- Whether the world pauses while the Pip-Boy is open (on by default; off for co-op).
        setPauseWhileOpen = function(v) pauseWhileOpen = v and true or false end,
        getPauseWhileOpen = function() return pauseWhileOpen end,
        --- Zoom the world map: the part of the map's width on screen (0.08 .. 1).
        setMapZoom = function(z) mapZoom = math.max(0.08, math.min(1, z)); render() end,
        --- For tests: what the global script last sent (quests, effects, worn, map).
        getData = function() return data end,
        --- For tests: the rows of the current page, { label, value, ... }.
        getRows = function() return rows end,
        --- For tests: pick a tab and sub-tab by id, select row `index` and activate it.
        activateRow = function(tab, sub, index)
            for i, t in ipairs(TABS) do
                if t.id == tab then
                    tabIndex = i
                    for j, s in ipairs(t.subs) do
                        if s.id == sub then subIndex[i] = j end
                    end
                end
            end
            selected[currentSub()] = index
            render()
            activate(rows[index])
        end,
    },
    engineHandlers = {
        onKeyPress = function(key)
            local code = key.code
            if code == input.KEY.Tab then
                -- Tab is FNV's Pip-Boy key, and OpenMW's view toggle: keep the view as it is
                local mode = camera.getMode()
                if mode == camera.MODE.FirstPerson or mode == camera.MODE.ThirdPerson then viewMode = mode end
                viewRestoreFrames = 0
                -- Held in third person, the view toggle goes to the orbiting preview view at once, and its
                -- release can be lost to the Pip-Boy or another menu, leaving the view stuck there.
                if not tabBlocksView then
                    tabBlocksView = true
                    I.Camera.disableModeControl('pipboy-tab')
                end
                if open then
                    close()
                elseif I.UI.getMode() == nil and not core.isWorldPaused() then
                    show()
                end
                return
            end
            if not open then return end
            if code == input.KEY.F1 then setTab(1)
            elseif code == input.KEY.F2 then setTab(2)
            elseif code == input.KEY.F3 then setTab(3)
            elseif code == input.KEY.LeftArrow or code == input.KEY.A then cycleSub(-1)
            elseif code == input.KEY.RightArrow or code == input.KEY.D then cycleSub(1)
            elseif code == input.KEY.UpArrow or code == input.KEY.W then moveSelection(-1)
            elseif code == input.KEY.DownArrow or code == input.KEY.S then moveSelection(1)
            elseif code == input.KEY.Enter or code == input.KEY.E then activate(rows[selected[currentSub()] or 1])
            elseif code == input.KEY.R then drop(rows[selected[currentSub()] or 1], input.isShiftPressed())
            end
        end,
        onKeyRelease = function(key)
            if key.code == input.KEY.Tab and viewMode then viewRestoreFrames = 30 end
        end,
        onMouseWheel = function(vertical)
            if not open or vertical == 0 then return end
            if currentSub() == 'local' then
                local key = localMap and localMap.interior and 'interior' or 'exterior'
                localZoom[key] = math.max(120, math.min(4000, localZoom[key] * (vertical > 0 and 1.25 or 0.8)))
                render()
                return
            end
            if currentSub() == 'map' then
                mapZoom = math.max(0.08, math.min(1, mapZoom * (vertical > 0 and 0.8 or 1.25)))
                render()
                return
            end
            moveSelection(vertical > 0 and -1 or 1)
        end,
        onFrame = function(dt)
            if not windowsReplaced then replaceWindows() end
            -- the local map's tiles arrive a frame after they are asked for
            if open and currentSub() == 'local' and core.getRealTime() - localMapTime > 0.5 then render() end
            -- the view toggle comes back once Tab is up, out of every menu
            if tabBlocksView and I.UI.getMode() == nil and not input.isKeyPressed(input.KEY.Tab) then
                tabBlocksView = false
                I.Camera.enableModeControl('pipboy-tab')
                if camera.getMode() == camera.MODE.Preview and viewMode then camera.setMode(viewMode) end
            end
            if viewRestoreFrames > 0 and I.UI.getMode() == nil then
                viewRestoreFrames = viewRestoreFrames - 1
                local mode = camera.getMode()
                if mode ~= viewMode and (mode == camera.MODE.FirstPerson or mode == camera.MODE.ThirdPerson
                    or mode == camera.MODE.Preview) then
                    camera.setMode(viewMode)
                end
                if viewRestoreFrames == 0 then viewMode = nil end
            end
            if not open then return end
            -- the radio page follows the signal and what plays
            if currentSub() == 'radio' and core.getRealTime() - radioPageTime > 1 then
                radioPageTime = core.getRealTime()
                render()
            end
            if message then
                messageTime = messageTime - dt
                if messageTime <= 0 then
                    message = nil
                    render()
                end
            end
        end,
        onSave = function()
            return { pauseWhileOpen = pauseWhileOpen, tab = tabIndex, sub = subIndex }
        end,
        onLoad = function(saved)
            if saved == nil then return end
            if saved.pauseWhileOpen ~= nil then pauseWhileOpen = saved.pauseWhileOpen end
            tabIndex = saved.tab or 1
            subIndex = saved.sub or subIndex
        end,
    },
    eventHandlers = {
        UiModeChanged = function(e)
            if open then
                if not closingByScript and e.newMode ~= 'Interface' then closed() end
                return
            end
            -- Something opened the Morrowind windows: show the Pip-Boy instead. Windows of FNV scripts
            -- (dialogue, terminals, barter) open Interface mode with no Morrowind windows.
            if e.newMode == 'Interface' and not closingByScript and I.UI.isWindowVisible('Inventory') then
                show()
            end
        end,
        FNVPipBoyData = function(d)
            data = d
            if d.quests == nil then data.quests = {} end
            render()
        end,
        FNVPipBoyMessage = function(e)
            showMessage(e.text)
            render()
        end,
        -- `player.EquipItem <apparel>` from a script; weapons go to scripts/omw/fnvcombat/player.lua
        FNVEquipItem = function(e)
            if e.item and not combat.getWeapon(e.item) then
                core.sendGlobalEvent('FNVPipBoyWear', { player = self.object, item = e.item })
            end
        end,
    },
}
