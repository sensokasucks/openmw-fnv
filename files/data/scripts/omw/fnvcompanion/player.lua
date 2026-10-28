-- The Companion Wheel window (menus\companion_wheel_menu.xml, ghidra-findings-11); the world side is
-- scripts/omw/fnvcompanion/global.lua.
--
-- Eight pie slices around the screen centre, hit-tested by angle (clockwise from the top) and by distance
-- (76..332 in the menus' 960-high space). The hovered slice lights up and its icon fades from off to on; a
-- two-state slice shows its current state and, while hovered, the state a click would give. Clicking says the
-- companion's line and keeps the wheel open, except Talk To, Back Up and Open Inventory, which close it.

local async = require('openmw.async')
local core = require('openmw.core')
local self = require('openmw.self')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local style = require('scripts.omw.fnvmenus.style')

local v2 = util.vector2
local gmst = style.gmst

local DIR = 'interface/companion_wheel/'
local WHEEL = 760 -- CWM_MainRect, 960-high units
local LIFT = 55 -- the wheel sits this much above the centre, making room for the subtitle
local INNER, OUTER = 76, 332 -- button_companion_wheel.xml user4 / user5
local ICON = 180

local SOUNDS = {
    open = 'sound/fx/ui/popup/ui_popup_messagegeneral.wav', -- UIPopUpMessageGeneral
    hover = 'sound/fx/ui/pipboy/ui_pipboy_scroll.wav', -- UIPipBoyScroll
    ok = 'sound/fx/ui/menu/ui_menu_ok.wav', -- UIMenuOK
}

-- id, slice angles (radians, clockwise from the top), icon position (user6, user7), icons, alt icons, state
local BUTTONS = {
    { id = 0, from = 0.523598, to = 1.047196, at = v2(467, 160), icons = { 'comp_peaceful_off', 'comp_peaceful_on' },
        alt = { 'comp_aggressive_off', 'comp_aggressive_on' }, state = 'aggressive' },
    { id = 1, from = 1.047196, to = 1.5707943, at = v2(532, 275), icons = { 'comp_stimpack_off', 'comp_stimpack_on' } },
    { id = 2, from = 1.5707943, to = 2.094329, at = v2(532, 404), icons = { 'comp_follow_off', 'comp_follow_on' },
        alt = { 'comp_stay_off', 'comp_stay_on' }, state = 'waiting' },
    { id = 3, from = 2.094329, to = 2.61799, at = v2(467, 510), icons = { 'comp_talk_off', 'comp_talk_on' } },
    { id = 4, from = 3.665186, to = 4.188784, at = v2(112, 500), icons = { 'comp_stepback_off', 'comp_stepback_on' } },
    { id = 5, from = 4.188784, to = 4.7123823, at = v2(52, 404), icons = { 'comp_stayclose_off', 'comp_stayclose_on' },
        alt = { 'comp_stayfar_off', 'comp_stayfar_on' }, state = 'long' },
    { id = 6, from = 4.7123823, to = 5.235980, at = v2(52, 275), icons = { 'comp_inven_off', 'comp_inven_on' } },
    { id = 7, from = 5.235980, to = 5.759578, at = v2(122, 160), icons = { 'comp_melee_off', 'comp_melee_on' },
        alt = { 'comp_ranged_off', 'comp_ranged_on' }, state = 'ranged' },
}

local wheel = nil -- { companion, aggressive, long, ranged, following, hover, subtitle }
local element = nil
local closingByScript = false

local function playSound(name)
    style.sound(SOUNDS[name])
end

local function stateOf(name)
    if name == 'waiting' then return not wheel.following end
    return wheel[name]
end

-- FUN_00755d90: what a click on the button would do
local function description(id)
    if id == 0 then return wheel.aggressive and gmst('sCWheelBePassive', 'Be Passive') or gmst('sCWheelBeAggressive', 'Be Aggressive') end
    if id == 1 then return gmst('sCWheelUseStimpak', 'Use Stimpak') end
    if id == 2 then return wheel.following and gmst('sCWheelWaitHere', 'Wait Here') or gmst('sCWheelFollowMe', 'Follow Me') end
    if id == 3 then return gmst('sCWheelTalkTo', 'Talk To') end
    if id == 4 then return gmst('sCWheelBackUp', 'Back Up') end
    if id == 5 then return wheel.long and gmst('sCWheelStayClose', 'Stay Close') or gmst('sCWheelKeepDistance', 'Keep Distance') end
    if id == 6 then return gmst('sCWheelOpenInventory', 'Open Inventory') end
    if id == 7 then return wheel.ranged and gmst('sCWheelUseMelee', 'Use Melee') or gmst('sCWheelUseRanged', 'Use Ranged') end
    if id == 11 then return gmst('sExit', 'Exit') end
    return ''
end

local function screen()
    local size = ui.screenSize()
    return size, size.y / 960
end

-- The button under a screen position: the slices measure from the screen centre (user0 / user1)
local function buttonAt(position)
    local size, k = screen()
    local d = position - size * 0.5
    local r = d:length() / k
    if r < INNER or r > OUTER then return nil end
    local angle = math.atan2(d.x, -d.y)
    if angle < 0 then angle = angle + 2 * math.pi end
    for _, b in ipairs(BUTTONS) do
        if angle >= b.from and angle < b.to then return b.id end
    end
    return nil
end

local render

local function close()
    if element then
        element:destroy()
        element = nil
    end
    if wheel then
        wheel = nil
        closingByScript = true
        if I.UI.getMode() == 'Interface' then I.UI.setMode() end
        closingByScript = false
    end
end

local function press(id)
    if wheel == nil then return end
    playSound('ok')
    local companion = wheel.companion
    local b = nil
    for _, x in ipairs(BUTTONS) do if x.id == id then b = x end end
    local on = nil
    if id == 0 then wheel.aggressive = not wheel.aggressive; on = wheel.aggressive
    elseif id == 2 then wheel.following = not wheel.following; on = wheel.following
    elseif id == 5 then wheel.long = not wheel.long; on = wheel.long
    elseif id == 7 then wheel.ranged = not wheel.ranged; on = wheel.ranged end
    if id == 3 or id == 4 or id == 6 or id == 11 then close() end
    if id ~= 11 and b ~= nil then
        core.sendGlobalEvent('FNVCompanionWheelButton', { player = self.object, companion = companion, button = id, on = on })
    end
    if wheel then render() end
end

local function hover(id)
    if wheel == nil or wheel.hover == id then return end
    wheel.hover = id
    playSound('hover')
    render()
end

local function image(name, position, size, alpha, color)
    return style.image(DIR .. name .. '.dds', { position = position, size = size, alpha = alpha, color = color })
end

render = function()
    if wheel == nil then return end
    local size, k = screen()
    local centre = v2(size.x / 2, size.y / 2 - LIFT * k)
    local origin = centre - v2(WHEEL, WHEEL) * (k / 2)
    local content = ui.content {}
    local function add(layout) if layout then content:add(layout) end end
    add(image('hud_comp_bkg', origin - v2(15, 15) * k, v2(WHEEL + 30, WHEEL + 30) * k, 0.6, util.color.rgb(0.5, 0.36, 0.13)))
    add(image('hud_comp_pie', origin, v2(WHEEL, WHEEL) * k, 1))
    for i, b in ipairs(BUTTONS) do
        local hovered = wheel.hover == b.id
        if hovered then add(image('hud_comp_slice' .. i, origin, v2(WHEEL, WHEEL) * k, 0.5)) end
        local alt = false
        if b.state then
            alt = stateOf(b.state) and true or false
            if hovered then alt = not alt end -- a hovered two-state button shows what a click would give
        end
        local icons = alt and b.alt or b.icons
        local at = origin + v2(b.at.x, b.at.y - 45) * k -- user7 is measured from the top of the 960 screen
        add(image(icons[hovered and 2 or 1], at, v2(ICON, ICON) * k, 1))
    end
    local function centredText(str, y, props)
        props = props or {}
        props.position = v2(size.x / 2, y * k)
        props.anchor = v2(0.5, 0)
        props.textAlignH = ui.ALIGNMENT.Center
        props.multiline = true
        props.wordWrap = true
        props.autoSize = true
        props.textSize = props.textSize or style.TEXT
        return style.text(str, props)
    end
    add(centredText(gmst('sCWheelTitle', 'Companion Commands'), 110))
    add(centredText(description(wheel.hover), 205, { font = style.FONT_SMALL, textSize = style.SMALL }))
    if wheel.subtitle and wheel.subtitle ~= '' then
        add(centredText(wheel.subtitle, 740, { font = style.FONT_DIALOG })) -- CWM_Subtitle, 960-high screen units
    end
    add(style.button({ id = 'exit', label = gmst('sExit', 'Exit'), position = origin + v2(WHEEL - 200, WHEEL + 20) * k,
        size = v2(200, 44) * k, onClick = function() press(11) end }, wheel, render))
    local root = {
        type = ui.TYPE.Widget,
        props = { relativeSize = v2(1, 1) },
        content = content,
        events = {
            mouseMove = async:callback(function(e) hover(buttonAt(e.position)) end),
            mouseClick = async:callback(function(e)
                local id = buttonAt(e.position)
                if id ~= nil then press(id) end
            end),
        },
    }
    if element then
        element.layout = root
        element:update()
    else
        element = ui.create { layer = 'Windows', type = ui.TYPE.Widget, props = { relativeSize = v2(1, 1) },
            content = ui.content { root } }
    end
end

return {
    engineHandlers = {
        onKeyPress = function(key)
            if wheel and key.code == require('openmw.input').KEY.E then press(11) end
        end,
    },
    eventHandlers = {
        FNVCompanionWheelOpen = function(e)
            close()
            wheel = { companion = e.companion, aggressive = e.aggressive, long = e.long, ranged = e.ranged,
                following = e.following, hover = nil, subtitle = '' }
            closingByScript = true
            I.UI.setMode('Interface', { windows = {} })
            closingByScript = false
            playSound('open')
            render()
        end,
        FNVCompanionWheelSubtitle = function(e)
            if wheel == nil then return end
            wheel.subtitle = e.text or ''
            render()
        end,
        FNVOpenTeammateContainer = function(e)
            if e.container == nil then return end
            I.UI.addMode('Container', { target = e.container })
        end,
        UiModeChanged = function(e)
            -- Escape or another window closed the wheel
            if wheel and not closingByScript and e.newMode ~= 'Interface' then
                wheel = nil
                if element then element:destroy(); element = nil end
            end
        end,
    },
}
