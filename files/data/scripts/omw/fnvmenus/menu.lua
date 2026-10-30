-- The FNV title menu (menus\options\start_menu.xml) while FO3/FNV content is loaded and no game runs:
-- Continue (the newest save), New, Load, Settings, Quit on the right over FNV's title picture, which
-- MWGui::MainMenu draws in place of Morrowind's menu.
--
-- Also saving, loading and quitting for the FNV pause menu (scripts/omw/fnvmenus/player.lua), which runs in
-- the player's context and cannot reach openmw.menu. The save list goes back through player storage.
--
-- Menu events (types.Player.sendMenuEvent):
--   FNVListSaves {}                       -> storage.playerSection('FNVMenusSaves'): list
--   FNVSaveGame  { description, slot }    slot: an existing save's file name to overwrite, or nil for a new one
--   FNVLoadGame  { dir, slot }
--   FNVQuitGame  {}

local core = require('openmw.core')
local input = require('openmw.input')
local menu = require('openmw.menu')
local storage = require('openmw.storage')
local ui = require('openmw.ui')
local util = require('openmw.util')

local style = require('scripts.omw.fnvmenus.style')

local v2 = util.vector2

-- Saves of games with FO3/FNV content, newest first: { dir, slot, description, playerName, playerLevel,
-- timePlayed, creationTime, current }
local function listSaves()
    local current = menu.getCurrentSaveDir()
    local list = {}
    for dir, saves in pairs(menu.getAllSaves()) do
        for slot, info in pairs(saves) do
            local fallout = false
            for _, file in ipairs(info.contentFiles) do
                if file == 'falloutnv.esm' or file == 'fallout3.esm' then fallout = true end
            end
            if fallout then
                list[#list + 1] = { dir = dir, slot = slot, description = info.description,
                    playerName = info.playerName, playerLevel = info.playerLevel, timePlayed = info.timePlayed,
                    creationTime = info.creationTime, current = dir == current }
            end
        end
    end
    table.sort(list, function(a, b) return a.creationTime > b.creationTime end)
    return list
end

local function publish()
    -- fetched each time: a new game or a load drops temporary sections, and a view kept from before would
    -- write to the dropped one
    local section = storage.playerSection('FNVMenusSaves')
    section:setLifeTime(storage.LIFE_TIME.Temporary)
    section:set('list', listSaves())
    section:set('stamp', core.getRealTime())
end

-- ------------------------------------------------------------ title menu

-- Menu scripts start before the content files are known, so this asks each time.
local function isFallout()
    local ok, has = pcall(function()
        return core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')
    end)
    return ok and has
end

local element = nil
local page = 'main' -- 'main', 'load', 'quit'
local state = { hover = nil }
local saves = {}
local scroll = 0
local settingsOpen = false
local leaving = false -- a game is starting or loading
local render

local function leave()
    leaving = true
end

local function destroy()
    if element then
        element:destroy()
        element = nil
    end
end

local function titleShown()
    return isFallout() and menu.getState() == menu.STATE.NoGame
end

local function setPage(p)
    page = p
    state.hover = nil
    scroll = 0
    if p == 'load' or p == 'main' then saves = listSaves() end
    render()
end

local function mainButtons()
    local buttons = {}
    if saves[1] then
        buttons[#buttons + 1] = { id = 'continue', label = style.gmst('sContinue', 'Continue'), onClick = function()
            leave()
            destroy()
            menu.loadGame(saves[1].dir, saves[1].slot)
        end }
    end
    buttons[#buttons + 1] = { id = 'new', label = style.gmst('sNew', 'New'), onClick = function()
        leave()
        destroy()
        menu.newGame()
    end }
    if saves[1] then
        buttons[#buttons + 1] = { id = 'load', label = style.gmst('sLoad', 'Load'), onClick = function()
            setPage('load')
        end }
    end
    buttons[#buttons + 1] = { id = 'settings', label = style.gmst('sSettings', 'Settings'), onClick = function()
        settingsOpen = true
        destroy()
        ui._toggleSettingsWindow()
    end }
    buttons[#buttons + 1] = { id = 'quit', label = style.gmst('sQuit', 'Quit'), onClick = function()
        menu.quit()
    end }
    local spacing = 52
    local column = ui.content {}
    for i, b in ipairs(buttons) do
        b.position = v2(0, (i - 1) * spacing)
        b.size = v2(300, 46)
        b.align = 'right'
        b.label = b.label:upper()
        column:add(style.button(b, state, render))
    end
    return {
        type = ui.TYPE.Widget,
        props = { relativePosition = v2(1, 1), anchor = v2(1, 1), position = v2(-80, -80),
            size = v2(300, spacing * #buttons) },
        content = column,
    }
end

local ROWS = 12
local ROW = 34

local function loadPage()
    local size = v2(1000, 600)
    scroll = math.max(0, math.min(scroll, #saves - ROWS))
    local content = {
        style.text(style.gmst('sLoad', 'Load'):upper(), { position = v2(30, 14), font = style.FONT_GLOW, textSize = 30 }),
    }
    for i = scroll + 1, math.min(#saves, scroll + ROWS) do
        local s = saves[i]
        local label = ('%s   %s, Level %s'):format(s.description ~= '' and s.description or s.slot,
            s.playerName or '', tostring(s.playerLevel or '?'))
        content[#content + 1] = style.button({ id = 'save' .. i, label = label, align = 'left', textSize = style.SMALL,
            position = v2(30, 70 + (i - scroll - 1) * ROW), size = v2(size.x - 60, ROW - 2), onClick = function()
                leave()
                destroy()
                menu.loadGame(s.dir, s.slot)
            end }, state, render)
    end
    content[#content + 1] = style.button({ id = 'back', label = style.gmst('sBack', 'Back'), align = 'right',
        position = v2(size.x - 230, size.y - 70), size = v2(200, 46), onClick = function() setPage('main') end },
        state, render)
    return { type = ui.TYPE.Widget, props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5), size = size },
        content = ui.content { style.panel(size, content, 0.85) } }
end

render = function()
    destroy()
    if not titleShown() or settingsOpen then return end
    local layout = {}
    -- the game's title, as start_menu.xml's main_title
    local title = style.image('interface/main/main_title.dds',
        { position = v2(80, 60), size = v2(512, 128) * 1.25, color = util.color.rgb(1, 1, 1) })
    if title then layout[#layout + 1] = title end
    if page == 'load' then
        layout[#layout + 1] = loadPage()
    else
        layout[#layout + 1] = mainButtons()
    end
    element = ui.create {
        layer = 'MainMenu', -- over MWGui::MainMenu's background
        props = { relativeSize = v2(1, 1) },
        content = ui.content(layout),
    }
end

local function refresh()
    leaving = false
    if titleShown() then
        setPage('main')
    else
        destroy()
        page = 'main'
    end
end

return {
    engineHandlers = {
        onStateChanged = refresh,
        onFrame = function()
            if element == nil and not settingsOpen and not leaving and titleShown() then refresh() end
            if settingsOpen and not ui._isSettingsWindowVisible() then
                settingsOpen = false
                render()
            end
            if element and not titleShown() then destroy() end
        end,
        onKeyPress = function(key)
            if element and page == 'load' and key.code == input.KEY.Escape then setPage('main') end
        end,
        onMouseWheel = function(vertical)
            if element and page == 'load' and vertical ~= 0 then
                scroll = math.max(0, scroll + (vertical > 0 and -1 or 1))
                render()
            end
        end,
    },
    eventHandlers = {
        FNVListSaves = publish,
        FNVSaveGame = function(e)
            menu.saveGame(e.description or '', e.slot)
            publish()
        end,
        FNVLoadGame = function(e)
            menu.loadGame(e.dir, e.slot)
        end,
        FNVQuitGame = function()
            menu.quit()
        end,
    },
}
