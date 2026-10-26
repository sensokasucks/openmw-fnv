-- FNV menus in place of Morrowind's while FO3/FNV content is loaded:
--
--   Escape     the pause menu (menus\options\pause_menu.xml): Resume, Save, Load, Settings, Quit, as a
--              column on the right over the darkened game; Save and Load list the saves of FO3/FNV games
--              (through scripts/omw/fnvmenus/menu.lua), Settings opens OpenMW's settings window
--   Rest key   the wait menu (menus\sleep_wait_menu.xml): 1 to 24 hours on the wait meter, the hours pass
--              one by one (scripts/omw/fnvmenus/global.lua)
--   death      the pause menu without Resume and Save, once the death animation is over
--   containers the container menu (menus\container_menu.xml) in place of Morrowind's container window:
--              the player's items on the left, the container's on the right; click a line to move the
--              stack (shift: one), R or Take All takes everything, E or Exit leaves
--
-- The engine leaves Escape and the Rest key to these menus while the Fallout HUD is on
-- (MWInput::ActionManager), and the Container window is replaced through I.UI.registerWindow.
--
-- From the Lua console (`luap`): I.FNVMenus.open('pause'), I.FNVMenus.open('wait')

local async = require('openmw.async')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local style = require('scripts.omw.fnvmenus.style')

if core.obscript == nil or core.obscript.itemInfo == nil
    or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local v2 = util.vector2
local gmst = style.gmst

local current = nil -- 'pause', 'save', 'load', 'quit', 'wait', 'container'
local element = nil
local state = { hover = nil }
local closingByScript = false
local lastClosed = -1 -- real time a menu mode last closed: the Escape that closed it opens nothing
local settingsOpen = false
local message = nil

local saveScroll = 0
local saveStamp = nil
local selectedSave = nil
local confirmLoad = nil

local wait = { hours = 1, running = false, left = 0, timer = 0 }

local messages = {} -- message boxes with buttons waiting to be shown: { text, buttons }

local container = { target = nil, data = nil, scroll = { player = 0, container = 0 }, hoverItem = nil,
    hoverColumn = nil, refreshAt = nil, openedAt = 0 }

local render

local function destroy()
    if element then
        element:destroy()
        element = nil
    end
end

local function setHud(visible)
    if I.FNVHud then I.FNVHud.setVisible(visible) end
end

local function closeAll()
    destroy()
    if current ~= nil then setHud(true) end
    if settingsOpen and ui._isSettingsWindowVisible() then ui._toggleSettingsWindow() end
    settingsOpen = false
    current = nil
    state.hover = nil
    message = nil
    wait.running = false
    container.target = nil
    container.data = nil
end

-- Leave the menu mode (Interface for ours, Container for the container menu)
local function close()
    local mode = current == 'container' and 'Container' or 'Interface'
    closeAll()
    closingByScript = true
    if mode == 'Container' then I.UI.removeMode('Container') else I.UI.setMode() end
    closingByScript = false
    lastClosed = core.getRealTime()
end

local function open(which)
    if current == nil and which ~= 'container' then
        if I.UI.getMode() ~= nil then return end
        closingByScript = true
        I.UI.setMode('Interface', { windows = {} })
        closingByScript = false
        if which == 'pause' then style.sound('ok') end
    end
    if current == nil then setHud(false) end
    current = which
    state.hover = nil
    message = nil
    if which == 'save' or which == 'load' then
        saveScroll = 0
        selectedSave = nil
        confirmLoad = nil
        types.Player.sendMenuEvent(self, 'FNVListSaves', {})
    end
    render()
end

local function show(layout)
    destroy()
    element = ui.create {
        layer = 'Windows',
        props = { relativeSize = v2(1, 1) },
        content = ui.content(layout),
    }
end

-- ------------------------------------------------------------ pause menu

local function isDead()
    local ok, health = pcall(function() return types.Actor.stats.dynamic.health(self).current end)
    return ok and health <= 0
end

local function pauseMenu()
    local spacing = 60
    local buttons = {
        { id = 'resume', label = gmst('sContinue', 'Resume'), enabled = not isDead(), onClick = close },
        { id = 'save', label = gmst('sSave', 'Save'), enabled = not isDead(), onClick = function() open('save') end },
        { id = 'load', label = gmst('sLoad', 'Load'), onClick = function() open('load') end },
        { id = 'settings', label = gmst('sSettings', 'Settings'), onClick = function()
            settingsOpen = true
            destroy()
            ui._toggleSettingsWindow()
        end },
        { id = 'quit', label = gmst('sQuit', 'Quit'), onClick = function() open('quit') end },
    }
    local column = ui.content {}
    for i, b in ipairs(buttons) do
        b.position = v2(0, (i - 1) * spacing)
        b.size = v2(300, 48)
        b.align = 'right'
        b.label = b.label:upper()
        column:add(style.button(b, state, render))
    end
    return {
        style.dim(0.45),
        {
            type = ui.TYPE.Widget,
            props = { relativePosition = v2(1, 0.5), anchor = v2(1, 0.5), position = v2(-80, 0),
                size = v2(300, spacing * #buttons) },
            content = column,
        },
    }
end

local function quitMenu()
    local size = v2(560, 220)
    local content = {
        style.text(gmst('sQuitToDesktop', 'Quit to the desktop?'),
            { position = v2(0, 50), size = v2(size.x, 40), autoSize = false, textAlignH = ui.ALIGNMENT.Center,
                font = style.FONT_GLOW }),
        style.button({ id = 'yes', label = gmst('sYes', 'Yes'), position = v2(60, 130), size = v2(200, 48),
            onClick = function() types.Player.sendMenuEvent(self, 'FNVQuitGame', {}) end }, state, render),
        style.button({ id = 'no', label = gmst('sNo', 'No'), position = v2(size.x - 260, 130), size = v2(200, 48),
            onClick = function() open('pause') end }, state, render),
    }
    return {
        style.dim(0.45),
        { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
            content = ui.content { style.panel(size, content) } },
    }
end

-- ------------------------------------------------------------ save and load

local SAVE_ROWS = 12
local ROW = 34

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    return ('%d:%02d:%02d'):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function saveMenu()
    local saving = current == 'save'
    local size = v2(1000, 600)
    local list = storage.playerSection('FNVMenusSaves'):get('list') or {}
    if saving then
        -- only this character's saves can be overwritten
        local mine = {}
        for _, s in ipairs(list) do if s.current then mine[#mine + 1] = s end end
        list = mine
        table.insert(list, 1, { new = true, description = gmst('sNewSave', 'New Save') })
    end
    saveScroll = math.max(0, math.min(saveScroll, #list - SAVE_ROWS))
    local content = {
        style.text((saving and gmst('sSave', 'Save') or gmst('sLoad', 'Load')):upper(),
            { position = v2(30, 14), font = style.FONT_GLOW, textSize = 30 }),
    }
    for i = saveScroll + 1, math.min(#list, saveScroll + SAVE_ROWS) do
        local s = list[i]
        local label = s.new and s.description or ('%s'):format(s.description ~= '' and s.description or s.slot)
        content[#content + 1] = style.button({
            id = 'save' .. i, label = label, align = 'left', textSize = style.SMALL,
            position = v2(30, 70 + (i - saveScroll - 1) * ROW), size = v2(560, ROW - 2),
            onClick = function()
                if saving then
                    local where = self.cell and self.cell.name or ''
                    local description = ('%s, %s'):format(types.NPC.record(self).name or 'Courier',
                        where ~= '' and where or 'Wasteland')
                    types.Player.sendMenuEvent(self, 'FNVSaveGame',
                        { description = description, slot = not s.new and s.slot or nil })
                    message = gmst('sGameSaved', 'Game saved.')
                    render()
                elseif confirmLoad == i then
                    types.Player.sendMenuEvent(self, 'FNVLoadGame', { dir = s.dir, slot = s.slot })
                    closeAll()
                else
                    confirmLoad = i
                    selectedSave = s
                    message = 'Click again to load this game.'
                    render()
                end
            end,
        }, state, function()
            if state.hover and state.hover:find('^save') then
                selectedSave = list[tonumber(state.hover:sub(5))]
            end
            render()
        end)
    end
    if #list == 0 then
        content[#content + 1] = style.text(saving and '' or 'No saved games.',
            { position = v2(40, 76), textSize = style.SMALL, alpha = style.DIM })
    end
    -- the selected save's details
    local s = selectedSave
    if s and not s.new then
        local y = 76
        local function line(str)
            content[#content + 1] = style.text(str, { position = v2(620, y), textSize = style.SMALL })
            y = y + 30
        end
        line(s.playerName or '')
        line(('Level %s'):format(tostring(s.playerLevel or '?')))
        line(s.description or '')
        line(('Played %s'):format(formatTime(s.timePlayed)))
        local ok, date = pcall(function() return os.date('%Y-%m-%d %H:%M', math.floor(s.creationTime or 0)) end)
        if ok then line(date) end
    end
    -- scroll arrows
    if #list > SAVE_ROWS then
        content[#content + 1] = style.text(('%d-%d of %d'):format(saveScroll + 1,
            math.min(#list, saveScroll + SAVE_ROWS), #list), { position = v2(30, size.y - 60), textSize = style.SMALL,
            alpha = style.DIM })
    end
    if message then
        content[#content + 1] = style.text(message, { position = v2(620, size.y - 110), textSize = style.SMALL })
    end
    content[#content + 1] = style.button({ id = 'back', label = gmst('sBack', 'Back'), align = 'right',
        position = v2(size.x - 230, size.y - 70), size = v2(200, 46), onClick = function() open('pause') end },
        state, render)
    return {
        style.dim(0.45),
        { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
            content = ui.content { style.panel(size, content, 0.85) } },
    }
end

-- ------------------------------------------------------------ message box

-- message_menu.xml: the text over a column of buttons; the answer goes to GetButtonPressed
local function messageMenu()
    local m = messages[1]
    if m == nil then return {} end
    local width = 700
    local lines = 1
    for _ in tostring(m.text):gmatch('\n') do lines = lines + 1 end
    local textHeight = math.max(60, (lines + math.floor(#m.text / 55)) * 26)
    local height = 80 + textHeight + #m.buttons * 52 + 30
    local size = v2(width, height)
    local content = {
        style.text(m.text, { position = v2(40, 50), size = v2(width - 80, textHeight), autoSize = false,
            multiline = true, wordWrap = true, textAlignH = ui.ALIGNMENT.Center }),
    }
    for i, label in ipairs(m.buttons) do
        content[#content + 1] = style.button({ id = 'button' .. i, label = label,
            position = v2((width - 400) / 2, 70 + textHeight + (i - 1) * 52), size = v2(400, 46),
            onClick = function()
                core.obscript.setButtonPressed(i - 1)
                table.remove(messages, 1)
                if messages[1] then
                    state.hover = nil
                    render()
                else
                    close()
                end
            end }, state, render)
    end
    return {
        { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
            content = ui.content { style.panel(size, content, 0.85) } },
    }
end

-- ------------------------------------------------------------ wait

local function clock()
    local hours = (core.getGameTime() / 3600) % 24
    local h = math.floor(hours)
    local m = math.floor((hours - h) * 60)
    local suffix = h < 12 and 'AM' or 'PM'
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return ('%d:%02d %s'):format(h12, m, suffix)
end

local function waitMenu()
    local size = v2(860, 400)
    local hours = wait.running and wait.left or wait.hours
    local content = {
        style.text(wait.running and gmst('sWaiting', 'Waiting...') or gmst('sWaitHowLong', 'Wait how many hours?'),
            { position = v2(0, 50), size = v2(size.x, 40), autoSize = false, textAlignH = ui.ALIGNMENT.Center,
                font = style.FONT_GLOW, textSize = 28 }),
    }
    local meter = style.image('interface/wait/wait_meter.dds', { position = v2(50, 125), size = v2(765, 95.625) })
    if meter then content[#content + 1] = meter end
    local pointerX = 112.5 + (math.max(1, hours) - 1) / 23 * 640 - 24
    local pointer = style.image('interface/wait/wait_pointer.dds', { position = v2(pointerX, 105), size = v2(48, 48) })
    if pointer then content[#content + 1] = pointer end
    -- the meter as a clickable strip: click or drag to pick the hours
    content[#content + 1] = {
        type = ui.TYPE.Widget,
        props = { position = v2(112.5, 105), size = v2(640, 110) },
        events = {
            mousePress = async:callback(function(e)
                if wait.running then return end
                wait.hours = math.max(1, math.min(24, math.floor(e.offset.x / 640 * 23 + 1.5)))
                style.sound('prevnext')
                render()
            end),
        },
    }
    content[#content + 1] = style.text(('%d %s'):format(hours, hours == 1 and gmst('sHour', 'Hour')
        or gmst('sHours', 'Hours')), { position = v2(0, 220), size = v2(size.x, 46), autoSize = false,
        textAlignH = ui.ALIGNMENT.Center, font = style.FONT_DIALOG, textSize = 34 })
    content[#content + 1] = style.text(clock(), { position = v2(0, 300), size = v2(size.x, 30), autoSize = false,
        textAlignH = ui.ALIGNMENT.Center })
    if message then
        content[#content + 1] = style.text(message, { position = v2(0, 270), size = v2(size.x, 30),
            autoSize = false, textAlignH = ui.ALIGNMENT.Center, textSize = style.SMALL })
    end
    if not wait.running then
        content[#content + 1] = style.button({ id = 'wait', label = gmst('sWait', 'Wait') .. '  W', align = 'right',
            position = v2(size.x - 250, 265), size = v2(220, 44), onClick = function()
                wait.running = true
                wait.left = wait.hours
                wait.timer = 0
                render()
            end }, state, render)
    end
    content[#content + 1] = style.button({ id = 'cancel', label = gmst('sCancel', 'Cancel') .. '  E',
        align = 'right', position = v2(size.x - 250, 315), size = v2(220, 44), onClick = close }, state, render)
    return {
        { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
            content = ui.content { style.panel(size, content) } },
    }
end

local function hostilesNear()
    return I.FNVHud and I.FNVHud.hostilesNear and I.FNVHud.hostilesNear() or false
end

-- ------------------------------------------------------------ container

local LIST_ROWS = 13
local LIST_ROW = 28
local COLUMN = 464

local function carried()
    local total = 0
    for _, entry in ipairs(container.data and container.data.playerItems or {}) do
        total = total + (entry.weight or 0) * entry.count
    end
    return total
end

local function itemList(content, x, title, side)
    local list = container.data[side == 'player' and 'playerItems' or 'containerItems']
    local scroll = math.max(0, math.min(container.scroll[side], #list - LIST_ROWS))
    container.scroll[side] = scroll
    -- headline: a line with short ends, the title in it (CM_Items_headline_*)
    content[#content + 1] = style.rect(v2(x, 20), v2(style.LINE, 40))
    content[#content + 1] = style.rect(v2(x, 20), v2(30, style.LINE))
    content[#content + 1] = style.text(title, { position = v2(x + 40, 4), font = style.FONT_DIALOG, textSize = 30 })
    content[#content + 1] = style.rect(v2(x + COLUMN - style.LINE, 20), v2(style.LINE, 40))
    content[#content + 1] = style.rect(v2(x + COLUMN - 30, 20), v2(30, style.LINE))
    for i = scroll + 1, math.min(#list, scroll + LIST_ROWS) do
        local entry = list[i]
        local label = entry.name .. (entry.count > 1 and (' (' .. entry.count .. ')') or '')
        local id = side .. i
        content[#content + 1] = style.button({
            id = id, label = label, align = 'left', textSize = style.SMALL,
            position = v2(x + 10, 70 + (i - scroll - 1) * LIST_ROW), size = v2(COLUMN - 20, LIST_ROW - 2),
            onClick = function()
                local count = input.isShiftPressed() and 1 or entry.count
                core.sendGlobalEvent('FNVContainerMove', { player = self.object, container = container.target,
                    item = entry.item, count = count })
                container.refreshAt = core.getRealTime() + 0.1
            end,
        }, state, function()
            container.hoverItem = state.hover == id and entry or nil
            container.hoverColumn = side
            render()
        end)
    end
    if #list == 0 then
        content[#content + 1] = style.text(gmst('sEmpty', 'Empty'), { position = v2(x + 20, 76),
            textSize = style.SMALL, alpha = style.DIM })
    end
    -- footer
    content[#content + 1] = style.rect(v2(x, 440), v2(style.LINE, 40))
    content[#content + 1] = style.rect(v2(x, 480), v2(COLUMN, style.LINE))
    content[#content + 1] = style.rect(v2(x + COLUMN - style.LINE, 440), v2(style.LINE, 40))
    if #list > LIST_ROWS then
        content[#content + 1] = style.text(('%d-%d / %d'):format(scroll + 1, math.min(#list, scroll + LIST_ROWS),
            #list), { position = v2(x + 20, 448), textSize = style.SMALL, alpha = style.DIM })
    end
end

local function containerMenu()
    if container.data == nil then return {} end
    local size = v2(1000, 620)
    local content = {}
    itemList(content, 24, gmst('sInventoryItems', 'Items'), 'player')
    itemList(content, size.x - 24 - COLUMN, container.data.name ~= '' and container.data.name or 'Container',
        'container')
    -- the item under the mouse, and what the player carries
    local item = container.hoverItem
    if item then
        content[#content + 1] = style.text(('WG %s   VAL %d'):format(
            tostring(math.floor((item.weight or 0) * 10 + 0.5) / 10), item.value or 0),
            { position = v2(30, 500), textSize = style.SMALL })
    end
    local ok, capacity = pcall(core.obscript.stats.get, self.object, 'CarryWeight')
    content[#content + 1] = style.text(('WG %d/%d'):format(math.floor(carried() + 0.5),
        ok and math.floor(capacity + 0.5) or 0), { position = v2(30, 540), textSize = style.SMALL })
    content[#content + 1] = style.button({ id = 'takeall', label = gmst('sTakeAll', 'Take All') .. '  R',
        align = 'right', position = v2(size.x - 280, 500), size = v2(250, 44), onClick = function()
            core.sendGlobalEvent('FNVContainerTakeAll', { player = self.object, container = container.target })
            container.refreshAt = core.getRealTime() + 0.1
        end }, state, render)
    content[#content + 1] = style.button({ id = 'exit', label = gmst('sExit', 'Exit') .. '  E', align = 'right',
        position = v2(size.x - 280, 550), size = v2(250, 44), onClick = close }, state, render)
    return {
        { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
            content = ui.content { style.panel(size, content, 0.85) } },
    }
end

local function containerShown(target)
    if target == nil then return end
    if current == nil then setHud(false) end
    current = 'container'
    container.target = target
    container.data = nil
    container.scroll = { player = 0, container = 0 }
    container.hoverItem = nil
    container.openedAt = core.getRealTime()
    state.hover = nil
    core.sendGlobalEvent('FNVContainerOpen', { player = self.object, container = target })
end

local function containerHidden()
    if current == 'container' then
        closeAll()
        lastClosed = core.getRealTime()
    end
end

-- ------------------------------------------------------------

render = function()
    if current == nil or settingsOpen then
        destroy()
        return
    end
    if current == 'pause' then show(pauseMenu())
    elseif current == 'quit' then show(quitMenu())
    elseif current == 'save' or current == 'load' then show(saveMenu())
    elseif current == 'wait' then show(waitMenu())
    elseif current == 'container' then show(containerMenu())
    elseif current == 'message' then show(messageMenu())
    end
end

local windowsReplaced = false

return {
    interfaceName = 'FNVMenus',
    ---
    -- @module FNVMenus
    -- @context player
    interface = {
        version = 0,
        --- Open 'pause', 'save', 'load' or 'wait'.
        open = open,
        close = function() if current then close() end end,
        --- The open menu, or nil.
        current = function() return current end,
        --- A message box with buttons (ShowMessage); the button clicked goes to core.obscript.setButtonPressed.
        messageBox = function(text, buttons)
            messages[#messages + 1] = { text = tostring(text), buttons = buttons }
            if current == nil then
                open('message')
            elseif current == 'message' then
                render()
            end
        end,
        --- For tests: click button `index` (1 = the first) of the message box shown.
        answer = function(index)
            if current ~= 'message' or messages[1] == nil then return end
            core.obscript.setButtonPressed(index - 1)
            table.remove(messages, 1)
            if messages[1] then render() else close() end
        end,
        --- For tests: the container menu's lists.
        getContainerData = function() return container.data end,
        --- For tests: in the wait menu, wait `hours`.
        startWait = function(hours)
            if current ~= 'wait' then return end
            wait.hours = hours
            wait.running = true
            wait.left = hours
            wait.timer = 0
            render()
        end,
    },
    engineHandlers = {
        onInputAction = function(id)
            if id ~= input.ACTION.GameMenu and id ~= input.ACTION.Rest then return end
            -- the Escape that closed a window opens nothing
            if core.getRealTime() - lastClosed < 0.25 or I.UI.getMode() ~= nil or current ~= nil then return end
            if id == input.ACTION.GameMenu then
                open('pause')
            elseif not core.isWorldPaused() and types.Player.getControlSwitch(self,
                types.Player.CONTROL_SWITCH.Controls) then
                if hostilesNear() then
                    I.FNVHud.notify(gmst('sNoWaitHostileActors', 'You cannot wait with enemies nearby.'))
                    return
                end
                wait.hours = wait.hours or 1
                open('wait')
            end
        end,
        onKeyPress = function(key)
            if current == 'wait' and not wait.running then
                if key.code == input.KEY.LeftArrow or key.code == input.KEY.A then
                    wait.hours = math.max(1, wait.hours - 1)
                    style.sound('prevnext')
                    render()
                elseif key.code == input.KEY.RightArrow or key.code == input.KEY.D then
                    wait.hours = math.min(24, wait.hours + 1)
                    style.sound('prevnext')
                    render()
                elseif key.code == input.KEY.W or key.code == input.KEY.Enter then
                    wait.running = true
                    wait.left = wait.hours
                    wait.timer = 0
                    render()
                elseif key.code == input.KEY.E then
                    close()
                end
            elseif current == 'wait' and key.code == input.KEY.E then
                close()
            elseif current == 'container' then
                if key.code == input.KEY.R then
                    core.sendGlobalEvent('FNVContainerTakeAll', { player = self.object, container = container.target })
                    container.refreshAt = core.getRealTime() + 0.1
                elseif (key.code == input.KEY.E or key.code == input.KEY.Tab)
                    and core.getRealTime() - container.openedAt > 0.3 then
                    -- not the E that opened it
                    close()
                end
            end
        end,
        onMouseWheel = function(vertical)
            if vertical == 0 then return end
            local step = vertical > 0 and -1 or 1
            if current == 'wait' and not wait.running then
                wait.hours = math.max(1, math.min(24, wait.hours - step))
                render()
            elseif current == 'save' or current == 'load' then
                saveScroll = math.max(0, saveScroll + step)
                render()
            elseif current == 'container' and container.hoverColumn then
                local side = container.hoverColumn
                container.scroll[side] = math.max(0, container.scroll[side] + step)
                render()
            end
        end,
        onFrame = function(dt)
            if not windowsReplaced then
                windowsReplaced = true
                I.UI.registerWindow('Container', containerShown, containerHidden)
            end
            -- the save list arrives from scripts/omw/fnvmenus/menu.lua a frame or two after it is asked for
            if current == 'save' or current == 'load' then
                local stamp = storage.playerSection('FNVMenusSaves'):get('stamp')
                if stamp ~= saveStamp then
                    saveStamp = stamp
                    render()
                end
            end
            if settingsOpen and not ui._isSettingsWindowVisible() then
                settingsOpen = false
                render()
            end
            if current == 'wait' and wait.running then
                wait.timer = wait.timer + (core.getRealFrameDuration and core.getRealFrameDuration() or 1 / 60)
                if wait.timer >= 0.3 then
                    wait.timer = 0
                    core.sendGlobalEvent('FNVWaitHour', { player = self.object })
                    wait.left = wait.left - 1
                    if wait.left <= 0 then
                        close()
                        return
                    end
                    render()
                end
            end
            if current == nil and messages[1] and I.UI.getMode() == nil then open('message') end
            if container.refreshAt and core.getRealTime() >= container.refreshAt then
                container.refreshAt = nil
                if current == 'container' then
                    core.sendGlobalEvent('FNVContainerOpen', { player = self.object, container = container.target })
                end
            end
        end,
    },
    eventHandlers = {
        UiModeChanged = function(e)
            if closingByScript or current == nil or current == 'container' then return end
            if e.newMode ~= 'Interface' then
                local was = current
                closeAll()
                lastClosed = core.getRealTime()
                -- Escape on a page of the pause menu goes back to it; a message box waits for its answer
                if e.newMode == nil and (was == 'save' or was == 'load' or was == 'quit') then
                    open('pause')
                elseif e.newMode == nil and was == 'message' and messages[1] then
                    open('message')
                end
            end
        end,
        -- the death animation is over (MWState::StateManager::askLoadRecent): the pause menu, without Resume
        FNVPlayerDied = function()
            if current ~= nil then closeAll() end
            if I.UI.getMode() ~= nil then
                closingByScript = true
                I.UI.setMode()
                closingByScript = false
            end
            open('pause')
        end,
        FNVContainerShow = function(d)
            if current ~= 'container' or d.container ~= container.target then return end
            container.data = d
            container.hoverItem = nil
            render()
        end,
    },
}
