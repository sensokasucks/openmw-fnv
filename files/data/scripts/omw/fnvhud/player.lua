-- The FNV HUD, drawn in Lua over the game while FNV content is loaded; the
-- Morrowind HUD's bars, boxes and minimap are hidden (the crosshair stays).
--
--   top left      notices: "Quest added", objectives, items added, ShowMessage
--                 texts; shown one at a time, in order (HUDMainMenu's queue)
--   bottom left   HP bar, and the compass with the active quest's markers
--                 (from scripts/omw/fnvhud/global.lua) and red ticks for
--                 hostile actors close by
--   bottom right  AP bar, the ammo counter (clip / ammo carried) of the
--                 equipped FNV gun
--   centre        the activation prompt under the crosshair ("E) Talk"),
--                 the sneak state above it
--   bottom centre subtitles of lines spoken outside dialogue, and the health
--                 bar of the last actor the player shot
--
-- Not done yet: weapon condition, the XP bar, radiation, hit direction
-- markers, location markers, icons in the notices, the [CAUTION] sneak state.
--
-- From the Lua console (`luap`):
--   I.FNVHud.notify('Hello')
--   I.FNVHud.setVisible(false)

local ambient = require('openmw.ambient')
local camera = require('openmw.camera')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local keys = require('scripts.omw.fnvhud.keys')

if core.obscript == nil or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
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

-- sHUDColor is the name of the setting; FNV's default HUD colour is 255, 182, 66
local color = util.color.rgb(1.0, 0.714, 0.259)
local dimColor = util.color.rgba(1.0, 0.714, 0.259, 0.3)
local enemyColor = util.color.rgb(0.95, 0.25, 0.15)
local shadowColor = util.color.rgb(0, 0, 0)
local whiteTexture = ui.texture { path = 'white' }

local TEXT_SIZE = 18
local SMALL_TEXT = 15
local MARGIN = 40
local BAR_WIDTH = 220
local BAR_HEIGHT = 9
local COMPASS_WIDTH = 300
local COMPASS_HEIGHT = 30
local COMPASS_FOV = math.pi / 2 -- half of the arc the compass shows
local ENEMY_RANGE = 4000
local MAX_ENEMY_TICKS = gmst('iHUDMaxCompassNPCTicks', 10)
local NOTICE_TIME = 3.5
local NOTICE_GAP = 0.25

local visible = true

-- ------------------------------------------------------------ widgets

local function text(props)
    props.textColor = props.textColor or color
    props.textShadow = true
    props.textShadowColor = shadowColor
    props.textSize = props.textSize or TEXT_SIZE
    -- Monofonto. hud_main_menu.xml has font 7, the same with a glow baked in, but its glyphs reach 10 pixels past
    -- their advance and MyGUI cuts the last one off; the shadow stands in for the glow.
    props.font = props.font or 'FalloutFont2'
    props.autoSize = props.autoSize ~= false
    return { type = ui.TYPE.Text, props = props }
end

local function rect(position, size, col, alpha)
    return {
        type = ui.TYPE.Image,
        props = { resource = whiteTexture, position = position, size = size, color = col, alpha = alpha or 1 },
    }
end

-- "HP [=======   ]": a label and a bar filled to `fraction`
local function bar(label, fraction, col)
    fraction = math.max(0, math.min(1, fraction or 0))
    local x = 34
    return {
        type = ui.TYPE.Widget,
        props = { size = v2(x + BAR_WIDTH, 20) },
        content = ui.content {
            text { text = label, position = v2(0, 0) },
            rect(v2(x, 6), v2(BAR_WIDTH, BAR_HEIGHT), col, 0.25),
            rect(v2(x, 6), v2(math.floor(BAR_WIDTH * fraction + 0.5), BAR_HEIGHT), col),
        },
    }
end

-- One element per HUD part, rebuilt only when what it shows changes.
local parts = {}
local function setPart(name, key, makeLayout)
    local part = parts[name]
    if part and part.key == key then return end
    if key == nil then
        if part then
            part.element:destroy()
            parts[name] = nil
        end
        return
    end
    local layout = makeLayout()
    layout.layer = 'HUD'
    if part then
        part.key = key
        part.element.layout = layout
        part.element:update()
    else
        parts[name] = { key = key, element = ui.create(layout) }
    end
end

local function anchored(relative, anchor, position, content, size)
    return {
        type = ui.TYPE.Widget,
        props = { relativePosition = relative, anchor = anchor, position = position, size = size },
        content = ui.content(content),
    }
end

-- ------------------------------------------------------------ notices

local notices = {} -- { text, time, sound }
local notice = nil -- the one on screen
local noticeTimer = 0

local NOTICE_SOUNDS = {
    questAdded = { 'UIPopUpQuestNew', 'UIQuestNew' },
    objective = { 'UIPopUpQuestUpdate', 'UIQuestUpdate' },
    objectiveCompleted = { 'UIPopUpQuestUpdate', 'UIQuestUpdate' },
    questCompleted = { 'UIPopUpQuestComplete', 'UIQuestComplete' },
    message = { 'UIPopUpMessageGeneral' },
}
local soundIds = {}
local function noticeSound(kind)
    if soundIds[kind] == nil then
        soundIds[kind] = false
        for _, editorId in ipairs(NOTICE_SOUNDS[kind] or {}) do
            local id = core.obscript.resolveSoundEditorId and core.obscript.resolveSoundEditorId(editorId)
            if id then
                soundIds[kind] = id
                break
            end
        end
    end
    return soundIds[kind] or nil
end

local function notify(message, options)
    if message == nil or message == '' then return end
    options = options or {}
    local duration = tonumber(options.duration)
    if duration == nil or duration <= 0 then duration = NOTICE_TIME end
    notices[#notices + 1] = {
        text = keys.expand(tostring(message)), time = duration, sound = noticeSound(options.kind or 'message'),
    }
end

local function updateNotices(dt)
    noticeTimer = noticeTimer - dt
    if notice and noticeTimer <= 0 then
        notice = nil
        noticeTimer = NOTICE_GAP
    end
    if notice == nil and noticeTimer <= 0 and #notices > 0 then
        notice = table.remove(notices, 1)
        noticeTimer = notice.time
        if notice.sound then pcall(ambient.playSound, notice.sound) end
    end
    local shown = notice and visible
    setPart('notice', shown and (notice.text .. #notices) or nil, function()
        local content = { text { text = notice.text, multiline = true, wordWrap = true, autoSize = false,
            size = v2(420, 70), textAlignV = ui.ALIGNMENT.Start } }
        if #notices > 0 then
            content[#content + 1] = text { text = '+' .. #notices, textSize = SMALL_TEXT, position = v2(0, 72),
                textColor = dimColor }
        end
        return anchored(v2(0, 0), v2(0, 0), v2(MARGIN, MARGIN), content, v2(420, 90))
    end)
end

-- ------------------------------------------------------------ subtitles and the target's health

local subtitle = nil -- { text, time }
local target = nil -- { name, fraction, time }

local function updateSubtitle(dt)
    if subtitle then
        subtitle.time = subtitle.time - dt
        if subtitle.time <= 0 then subtitle = nil end
    end
    setPart('subtitle', (subtitle and visible) and subtitle.text or nil, function()
        return anchored(v2(0.5, 1), v2(0.5, 1), v2(0, -150), {
            text { text = subtitle.text, multiline = true, wordWrap = true, autoSize = false, size = v2(800, 60),
                textAlignH = ui.ALIGNMENT.Center, textAlignV = ui.ALIGNMENT.End, textColor = util.color.rgb(1, 1, 1) },
        }, v2(800, 60))
    end)
end

local function updateTarget(dt)
    if target then
        target.time = target.time - dt
        if target.time <= 0 then target = nil end
    end
    local key = (target and visible) and (target.name .. math.floor(target.fraction * 100)) or nil
    setPart('target', key, function()
        local width = 260
        return anchored(v2(0.5, 1), v2(0.5, 1), v2(0, -MARGIN), {
            text { text = target.name, position = v2(0, 0), autoSize = false, size = v2(width, 20),
                textAlignH = ui.ALIGNMENT.Center },
            rect(v2(0, 24), v2(width, BAR_HEIGHT), enemyColor, 0.25),
            rect(v2(0, 24), v2(math.floor(width * target.fraction + 0.5), BAR_HEIGHT), enemyColor),
        }, v2(width, 36))
    end)
end

-- ------------------------------------------------------------ HP, AP, sneak

local function updateBars()
    local health = types.Actor.stats.dynamic.health(self)
    local maxHealth = health.base + health.modifier
    local hp = maxHealth > 0 and health.current / maxHealth or 0
    local ap, maxAp = 0, 0
    pcall(function()
        ap = stats.get(self.object, 'ActionPoints')
        maxAp = stats.getPermanent(self.object, 'ActionPoints')
    end)
    local apFraction = maxAp > 0 and ap / maxAp or 0
    setPart('hp', visible and math.floor(hp * 200) or nil, function()
        return anchored(v2(0, 1), v2(0, 1), v2(MARGIN, -MARGIN - COMPASS_HEIGHT - 6),
            { bar('HP', hp, color) }, v2(34 + BAR_WIDTH, 20))
    end)
    setPart('ap', visible and math.floor(apFraction * 200) or nil, function()
        return anchored(v2(1, 1), v2(1, 1), v2(-MARGIN, -MARGIN - COMPASS_HEIGHT - 6),
            { bar(gmst('sStatsAP', 'AP'), apFraction, color) }, v2(34 + BAR_WIDTH, 20))
    end)

    local sneakText = nil
    if self.controls.sneak then
        -- the detection of the player by FNV actors (scripts/omw/fnvcombat)
        local state = storage.globalSection('FNVDetection'):get('state')
        if state == 'danger' then
            sneakText = gmst('sSneakDanger', '[DANGER]')
        elseif state == 'caution' then
            sneakText = gmst('sSneakCaution', '[CAUTION]')
        elseif state == 'hidden' then
            sneakText = gmst('sSneakHidden', '[HIDDEN]')
        else
            sneakText = ui._isSneakHidden() and gmst('sSneakHidden', '[HIDDEN]') or gmst('sSneakDetected', '[DETECTED]')
        end
    end
    setPart('sneak', visible and sneakText or nil, function()
        return anchored(v2(0.5, 0.5), v2(0.5, 1), v2(0, -28), {
            text { text = sneakText, autoSize = false, size = v2(200, 22), textAlignH = ui.ALIGNMENT.Center },
        }, v2(200, 22))
    end)
end

-- ------------------------------------------------------------ compass

local questMarkers = {} -- { position, text } from the global script
local enemies = {} -- positions of hostile actors close by
local enemyTimer = 0

local function updateEnemies(dt)
    enemyTimer = enemyTimer - dt
    if enemyTimer > 0 then return end
    enemyTimer = 0.25
    enemies = {}
    local origin = self.position
    for _, actor in ipairs(nearby.actors) do
        if actor ~= self.object and #enemies < MAX_ENEMY_TICKS then
            local ok, hostile = pcall(function()
                return (actor.position - origin):length() < ENEMY_RANGE and not combat.isDead(actor)
                    and combat.getReaction(actor) == 'enemy'
            end)
            if ok and hostile then enemies[#enemies + 1] = actor.position end
        end
    end
end

local function wrapAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

-- Horizontal place of a direction on the compass (0 = left edge), or nil
-- when it is behind; `clamp` pins it to the nearer edge instead.
local function compassX(angle, yaw, clamp)
    local rel = wrapAngle(angle - yaw)
    if math.abs(rel) > COMPASS_FOV then
        if not clamp then return nil end
        rel = rel > 0 and COMPASS_FOV or -COMPASS_FOV
    end
    return (rel / COMPASS_FOV + 1) / 2 * COMPASS_WIDTH
end

local function bearing(position)
    local d = position - self.position
    return math.atan2(d.x, d.y) -- 0 = north (+y), clockwise
end

local LETTERS = { { 'N', 0 }, { 'E', math.pi / 2 }, { 'S', math.pi }, { 'W', -math.pi / 2 } }

local function updateCompass()
    if not visible then
        setPart('compass', nil)
        return
    end
    local yaw = camera.getYaw()
    local items = {}
    local keyParts = { math.floor(math.deg(yaw) * 2) }
    for _, l in ipairs(LETTERS) do
        local x = compassX(l[2], yaw, false)
        if x then items[#items + 1] = { 'letter', x, l[1] } end
    end
    for i = 0, 15 do
        local x = compassX(i * math.pi / 8, yaw, false)
        if x and i % 4 ~= 0 then items[#items + 1] = { 'tick', x } end
    end
    for _, position in ipairs(enemies) do
        local x = compassX(bearing(position), yaw, false)
        if x then
            items[#items + 1] = { 'enemy', x }
            keyParts[#keyParts + 1] = math.floor(x)
        end
    end
    for _, m in ipairs(questMarkers) do
        local rel = wrapAngle(bearing(m.position) - yaw)
        local x = compassX(bearing(m.position), yaw, true)
        items[#items + 1] = { 'quest', x, math.abs(rel) > COMPASS_FOV }
        keyParts[#keyParts + 1] = 'q' .. math.floor(x)
    end
    setPart('compass', table.concat(keyParts, ','), function()
        local content = {
            rect(v2(0, COMPASS_HEIGHT - 2), v2(COMPASS_WIDTH, 2), color, 0.6),
        }
        for _, item in ipairs(items) do
            local kind, x = item[1], item[2]
            if kind == 'letter' then
                content[#content + 1] = text { text = item[3], position = v2(x - 6, 4) }
            elseif kind == 'tick' then
                content[#content + 1] = rect(v2(x - 1, COMPASS_HEIGHT - 9), v2(2, 7), color, 0.6)
            elseif kind == 'enemy' then
                content[#content + 1] = rect(v2(x - 2, COMPASS_HEIGHT - 14), v2(4, 12), enemyColor)
            end
        end
        -- quest markers last, on top: a filled square, hollow when off the compass
        for _, item in ipairs(items) do
            if item[1] == 'quest' then
                local x, off = item[2], item[3]
                content[#content + 1] = rect(v2(x - 6, 0), v2(12, 12), color, off and 0.35 or 1)
                content[#content + 1] = rect(v2(x - 1, 12), v2(2, COMPASS_HEIGHT - 12), color, off and 0.35 or 1)
            end
        end
        return anchored(v2(0, 1), v2(0, 1), v2(MARGIN, -MARGIN), content, v2(COMPASS_WIDTH, COMPASS_HEIGHT))
    end)
end

-- ------------------------------------------------------------ activation prompt

local LOCK_LEVELS = {
    { 100, 'sLockLevelNameVeryHard', 'Very Hard' },
    { 75, 'sLockLevelNameHard', 'Hard' },
    { 50, 'sLockLevelNameAverage', 'Average' },
    { 25, 'sLockLevelNameEasy', 'Easy' },
    { 0, 'sLockLevelNameVeryEasy', 'Very Easy' },
}

local function lockName(level)
    if level == nil or level < 0 or level > 100 then
        return gmst('sLockLevelNameImpossible', 'Requires Key')
    end
    for _, l in ipairs(LOCK_LEVELS) do
        if level >= l[1] then return gmst(l[2], l[3]) end
    end
end

local function isLocked(obj)
    local ok, locked = pcall(types.Lockable.isLocked, obj)
    return ok and locked
end

local ITEM_TYPES = {
    'ESM4Ammunition', 'ESM4Armor', 'ESM4Clothing', 'ESM4Ingredient', 'ESM4ItemMod', 'ESM4Key', 'ESM4Light',
    'ESM4Miscellaneous', 'ESM4Potion', 'ESM4Weapon', 'ESM4Note',
}

local function isType(obj, name)
    local t = types[name]
    return t ~= nil and t.objectIsInstance(obj)
end

-- Name and verb for the object under the crosshair, or nil.
local function prompt(obj)
    local ok, name = pcall(combat.getName, obj)
    if not ok then name = '' end
    local verb = nil
    local extra = nil
    if isType(obj, 'ESM4NPC') or isType(obj, 'ESM4Creature') then
        if combat.isDead(obj) then
            verb = gmst('sSearch', 'Search')
        elseif isType(obj, 'ESM4NPC') and combat.getReaction(obj) ~= 'enemy' then
            verb = 'Talk'
        end
    elseif isType(obj, 'ESM4Door') then
        if types.ESM4Door.isTeleport(obj) then
            local dest = types.ESM4Door.destCell(obj)
            if dest and dest.name and dest.name ~= '' then name = dest.name end
        end
        verb = 'Open'
    elseif isType(obj, 'ESM4Container') then
        verb = 'Open'
    elseif isType(obj, 'ESM4Terminal') then
        verb = 'Access'
    elseif isType(obj, 'ESM4Furniture') then
        verb = 'Sit'
    elseif isType(obj, 'ESM4Book') then
        verb = 'Read'
    elseif isType(obj, 'ESM4Activator') or isType(obj, 'ESM4Flora') then
        verb = 'Activate'
    else
        for _, t in ipairs(ITEM_TYPES) do
            if isType(obj, t) then
                verb = 'Take'
                if obj.count and obj.count > 1 then name = ('%s (%d)'):format(name, obj.count) end
                break
            end
        end
    end
    if name == '' and verb == nil then return nil end
    if isLocked(obj) then
        local ok2, level = pcall(types.Lockable.getLockLevel, obj)
        extra = gmst('sLocked', 'Locked') .. ' (' .. lockName(ok2 and level or nil) .. ')'
        -- a lock that needs a key keeps its verb: activating it tries the key
        local keyLock = not ok2 or level == nil or level < 0 or level > 100
        if not keyLock then verb = gmst('sPick', 'Pick') end
    end
    return name, verb, extra
end

local function updatePrompt()
    local obj = nil
    if visible and I.UI.getMode() == nil then
        obj = ui._getFocusObject()
        if obj and not obj:isValid() then obj = nil end
    end
    local name, verb, extra
    if obj then name, verb, extra = prompt(obj) end
    local key = name and (name .. '|' .. tostring(verb) .. '|' .. tostring(extra)) or nil
    setPart('prompt', key, function()
        local content = {}
        local y = 0
        if name ~= '' then
            content[#content + 1] = text { text = name, position = v2(0, y), autoSize = false, size = v2(400, 22),
                textAlignH = ui.ALIGNMENT.Center }
            y = y + 22
        end
        if extra then
            content[#content + 1] = text { text = extra, position = v2(0, y), autoSize = false, size = v2(400, 20),
                textAlignH = ui.ALIGNMENT.Center, textSize = SMALL_TEXT }
            y = y + 20
        end
        if verb then
            local activateKey = keys.key('Activate') or 'E'
            content[#content + 1] = text { text = activateKey .. ') ' .. verb, position = v2(0, y), autoSize = false,
                size = v2(400, 22), textAlignH = ui.ALIGNMENT.Center }
            y = y + 22
        end
        return anchored(v2(0.5, 0.5), v2(0.5, 0), v2(0, 28), content, v2(400, y))
    end)
end

-- ------------------------------------------------------------ ammo counter

local ammoCount = 0
local ammoTimer = 0

local function countAmmo(weapon)
    local inventory = types.Actor.inventory(self)
    local total = 0
    for _, ammo in ipairs(weapon.ammoTypes or {}) do
        local ok, n = pcall(inventory.countOf, inventory, ammo.id)
        if ok then total = total + n end
    end
    return total
end

local function updateAmmo(dt)
    local weapon = I.FNVCombat and I.FNVCombat.getWeapon()
    if weapon == nil or not visible then
        setPart('ammo', nil)
        return
    end
    ammoTimer = ammoTimer - dt
    if ammoTimer <= 0 then
        ammoTimer = 0.5
        ammoCount = countAmmo(weapon)
    end
    local clip = I.FNVCombat.getClip and I.FNVCombat.getClip() or 0
    local status = ''
    if I.FNVCombat.isReloading and I.FNVCombat.isReloading() then
        status = gmst('sActionPointsReload', 'Reload')
    elseif not I.FNVCombat.isDrawn() then
        status = 'Holstered'
    end
    local counter
    if (weapon.clipSize or 0) > 0 then
        counter = ('%d/%d'):format(clip, ammoCount)
    else
        counter = '--'
    end
    local key = table.concat({ weapon.name, counter, status }, '|')
    setPart('ammo', key, function()
        local width = 34 + BAR_WIDTH
        return anchored(v2(1, 1), v2(1, 1), v2(-MARGIN, -MARGIN), {
            text { text = weapon.name, position = v2(0, 0), autoSize = false, size = v2(width - 90, 20),
                textSize = SMALL_TEXT },
            text { text = status, position = v2(0, 16), autoSize = false, size = v2(width - 90, 16),
                textSize = SMALL_TEXT - 2, textColor = dimColor },
            text { text = counter, position = v2(width - 90, 0), autoSize = false, size = v2(90, COMPASS_HEIGHT),
                textSize = 24, textAlignH = ui.ALIGNMENT.End },
        }, v2(width, COMPASS_HEIGHT))
    end)
end

-- ------------------------------------------------------------ setup

local function enable()
    ui._setFalloutHud(true)
    -- Fallout has no vanity camera: Morrowind's would swing out to a view of the player's body after a while
    -- without input, which is what the player's FO3/FNV body is drawn for.
    types.Player.setControlSwitch(self, types.Player.CONTROL_SWITCH.VanityMode, false)
end

return {
    interfaceName = 'FNVHud',
    ---
    -- @module FNVHud
    -- @context player
    -- @usage require('openmw.interfaces').FNVHud.notify('Quest added')
    interface = {
        version = 0,
        --- Queue a notice in the top-left corner. `options`: duration (seconds), kind
        -- ('message', 'questAdded', 'objective', 'objectiveCompleted', 'questCompleted'; picks the sound).
        notify = notify,
        --- Hostile actors are close by (the compass's red ticks); the wait menu does not open then.
        hostilesNear = function() return #enemies > 0 end,
        --- Show a subtitle at the bottom of the screen for `duration` seconds.
        subtitle = function(message, duration)
            subtitle = { text = tostring(message), time = tonumber(duration) or 3 }
        end,
        --- Hide or show the whole Fallout HUD (the Morrowind one stays hidden).
        setVisible = function(v) visible = v and true or false end,
        isVisible = function() return visible end,
        --- The compass markers of the active quest, { position, text }.
        getQuestMarkers = function() return questMarkers end,
    },
    engineHandlers = {
        onInit = enable,
        onLoad = enable,
        onFrame = function(dt)
            if core.isWorldPaused() then dt = 0 end
            updateNotices(dt)
            updateSubtitle(dt)
            updateTarget(dt)
            updateBars()
            updateEnemies(dt)
            updateCompass()
            updatePrompt()
            updateAmmo(dt)
        end,
    },
    eventHandlers = {
        -- { text, duration, kind } from global scripts (scripts/omw/fnvhud/global.lua, obscript.lua)
        FNVHudNotify = function(data)
            notify(data.text, data)
        end,
        -- engine message boxes and ui.showMessage, which the Fallout HUD shows here (WindowManager::messageBox)
        FNVMessageBox = function(data)
            notify(data.text)
        end,
        FNVHudMarkers = function(data)
            questMarkers = data.markers or {}
        end,
        FNVCombat_ShotResult = function(e)
            if e.target == nil or (e.maxHealth or 0) <= 0 then return end
            target = { name = e.name or '', fraction = e.killed and 0 or math.max(0, e.health / e.maxHealth),
                time = 3 }
        end,
    },
}
