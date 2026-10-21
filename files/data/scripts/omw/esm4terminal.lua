-- Player-side reader for ESM4 terminals (TERM) and notes (NOTE).
--
-- Terminals open a full-screen style window with the welcome text and the
-- menu entries; picking an entry shows its result text, opens its sub-menu
-- or its note. Notes the player picks up (or gets from a terminal entry or
-- the ObScript `AddNote` command) are remembered and can be read again from
-- the notes list (N key), standing in for the Pip-Boy data tab.
--
-- Not implemented yet: hacking/passwords, entry conditions (CTDA, all
-- entries are shown) and the entries' embedded result scripts.

local ambient = require('openmw.ambient')
local async = require('openmw.async')
local core = require('openmw.core')
local input = require('openmw.input')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local v2 = util.vector2

local colors = {
    background = util.color.rgb(0.01, 0.05, 0.02),
    frame = util.color.rgb(0.10, 0.55, 0.20),
    text = util.color.rgb(0.25, 0.95, 0.45),
    dim = util.color.rgb(0.15, 0.60, 0.30),
    selected = util.color.rgb(0.85, 1.00, 0.85),
}
local textSize = 18
local lineHeight = textSize + 4
local padding = 16
local whiteTexture = ui.texture { path = 'white' }

-- ------------------------------------------------------------ notes

local knownNotes = {}  -- list of note record ids, in pickup order
local knownSet = {}    -- record id -> true

local function noteRecord(id)
    local ok, rec = pcall(types.ESM4Note.record, id)
    if ok then return rec end
    return nil
end

local function noteTitle(rec)
    if rec.name ~= '' then return rec.name end
    return rec.editorId
end

local function addNote(id, quiet)
    local rec = noteRecord(id)
    if rec == nil then
        print('[esm4terminal] unknown note: ' .. tostring(id))
        return false
    end
    if knownSet[rec.id] then return false end
    knownSet[rec.id] = true
    knownNotes[#knownNotes + 1] = rec.id
    if not quiet then
        ui.showMessage('Note added: ' .. noteTitle(rec))
    end
    return true
end

-- ------------------------------------------------------------ text layout

-- MyGUI reads '#' as the start of a colour code.
local function escape(text)
    return (text:gsub('#', '##'))
end

local function windowSize()
    local screen = ui.screenSize()
    return v2(math.min(860, math.floor(screen.x * 0.85)), math.min(640, math.floor(screen.y * 0.85)))
end

-- Word-wrap `text` into lines of at most `width` characters.
local function wrap(text, width)
    local lines = {}
    text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
    for paragraph in (text .. '\n'):gmatch('(.-)\n') do
        if paragraph == '' then
            lines[#lines + 1] = ''
        else
            local line = ''
            for word in paragraph:gmatch('%S+') do
                while #word > width do
                    if line ~= '' then
                        lines[#lines + 1] = line
                        line = ''
                    end
                    lines[#lines + 1] = word:sub(1, width)
                    word = word:sub(width + 1)
                end
                if line == '' then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. ' ' .. word
                else
                    lines[#lines + 1] = line
                    line = word
                end
            end
            lines[#lines + 1] = line
        end
    end
    while #lines > 0 and lines[#lines] == '' do
        lines[#lines] = nil
    end
    return lines
end

-- ------------------------------------------------------------ window

local element = nil
local pageStack = {}   -- pages; the last one is shown
local bodyPage = 1     -- page of the shown body text
local selected = 1     -- highlighted entry
local shownEntries = {}

local render  -- forward

local function close()
    if element then
        element:destroy()
        element = nil
    end
    pageStack = {}
    shownEntries = {}
    if I.UI.getMode() == 'Interface' then
        I.UI.removeMode('Interface')
    end
end

local function show(page)
    pageStack[#pageStack + 1] = page
    bodyPage = 1
    selected = 1
    render()
end

local function replace(page)
    pageStack[#pageStack] = page
    bodyPage = 1
    selected = 1
    render()
end

local function back()
    pageStack[#pageStack] = nil
    if #pageStack == 0 then
        close()
        return
    end
    bodyPage = 1
    selected = 1
    render()
end

local function choose(index)
    local entry = shownEntries[index]
    if entry then entry.action() end
end

local function textLayout(text, color, size)
    return {
        type = ui.TYPE.Text,
        props = {
            text = escape(text),
            textSize = textSize,
            textColor = color,
            size = size,
            multiline = true,
            wordWrap = false,
        },
    }
end

local function entryLayout(index, entry, width)
    local isSelected = index == selected
    local label = (index <= 9 and (index .. '. ') or '   ') .. entry.text
    local layout = textLayout((isSelected and '> ' or '  ') .. label, isSelected and colors.selected or colors.text,
        v2(width, lineHeight))
    layout.events = {
        mouseClick = async:callback(function() choose(index) end),
        focusGain = async:callback(function()
            if selected ~= index then
                selected = index
                render()
            end
        end),
    }
    return layout
end

render = function()
    local page = pageStack[#pageStack]
    if page == nil then return end

    local size = windowSize()
    local innerWidth = size.x - 2 * padding
    local charsPerLine = math.max(20, math.floor(innerWidth / (textSize * 0.55)))

    local entries = {}
    for _, e in ipairs(page.entries or {}) do entries[#entries + 1] = e end

    -- Fit the body into the space the header and entries leave over.
    local bodyLines = wrap(page.body or '', charsPerLine)
    local headerLines = page.title and 2 or 0
    local function capacity(entryCount)
        local free = size.y - 2 * padding - (headerLines + entryCount + 1) * lineHeight
        if page.image then free = free - page.imageHeight - lineHeight end
        return math.max(1, math.floor(free / lineHeight))
    end
    local perPage = capacity(#entries)
    local pageCount = 1
    if #bodyLines > perPage then
        perPage = capacity(#entries + 2)
        pageCount = math.ceil(#bodyLines / perPage)
    end
    bodyPage = math.max(1, math.min(bodyPage, pageCount))
    if pageCount > 1 then
        local nav = {}
        if bodyPage < pageCount then
            nav[#nav + 1] = { text = 'Next page', action = function() bodyPage = bodyPage + 1; selected = 1; render() end }
        end
        if bodyPage > 1 then
            nav[#nav + 1] = { text = 'Previous page', action = function() bodyPage = bodyPage - 1; selected = 1; render() end }
        end
        for i = #nav, 1, -1 do table.insert(entries, 1, nav[i]) end
    end
    selected = math.max(1, math.min(selected, #entries))
    shownEntries = entries

    local first = (bodyPage - 1) * perPage + 1
    local visible = {}
    for i = first, math.min(#bodyLines, first + perPage - 1) do visible[#visible + 1] = bodyLines[i] end

    local column = {}
    if page.title then
        local title = page.title
        if pageCount > 1 then title = title .. string.format('   [page %d/%d]', bodyPage, pageCount) end
        column[#column + 1] = textLayout(title, colors.selected, v2(innerWidth, lineHeight))
        column[#column + 1] = textLayout(string.rep('-', charsPerLine), colors.dim, v2(innerWidth, lineHeight))
    end
    if page.image then
        column[#column + 1] = {
            type = ui.TYPE.Image,
            props = {
                resource = ui.texture { path = page.image },
                size = v2(page.imageHeight, page.imageHeight),
            },
        }
        column[#column + 1] = textLayout('', colors.text, v2(innerWidth, lineHeight))
    end
    column[#column + 1] = textLayout(table.concat(visible, '\n'), colors.text,
        v2(innerWidth, #visible * lineHeight))
    column[#column + 1] = textLayout('', colors.text, v2(innerWidth, lineHeight))
    for i, entry in ipairs(entries) do
        column[#column + 1] = entryLayout(i, entry, innerWidth)
    end

    local layout = {
        layer = 'Windows',
        props = {
            relativePosition = v2(0.5, 0.5),
            anchor = v2(0.5, 0.5),
            size = size,
        },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                props = { resource = whiteTexture, color = colors.frame, relativeSize = v2(1, 1) },
            },
            {
                type = ui.TYPE.Image,
                props = {
                    resource = whiteTexture,
                    color = colors.background,
                    position = v2(3, 3),
                    size = size - v2(6, 6),
                },
            },
            {
                type = ui.TYPE.Flex,
                props = { position = v2(padding, padding) },
                content = ui.content(column),
            },
        },
    }

    if element then
        element.layout = layout
        element:update()
    else
        element = ui.create(layout)
    end
end

local function open(page)
    if element == nil then
        I.UI.addMode('Interface', { windows = {} })
    end
    show(page)
end

-- ------------------------------------------------------------ pages

local function backEntry(label)
    return { text = label or 'Back', action = back }
end

local function notePage(rec)
    local page = { title = noteTitle(rec), entries = { backEntry() } }
    if rec.noteType == 'Text' then
        page.body = rec.text
    elseif rec.noteType == 'Image' and rec.texture ~= '' then
        page.image = 'textures/' .. rec.texture
        page.imageHeight = math.min(384, windowSize().y - 6 * lineHeight - 2 * padding)
        page.body = ''
    else
        page.body = '(' .. rec.noteType .. ' recording: playback is not supported yet.)'
        if rec.noteType == 'Sound' and rec.sound then
            table.insert(page.entries, 1, {
                text = 'Play recording',
                action = function()
                    if not pcall(ambient.playSound, rec.sound) then
                        print('[esm4terminal] cannot play note sound ' .. tostring(rec.sound))
                    end
                end,
            })
        end
    end
    return page
end

local function notesListPage()
    local page = { title = 'Notes', entries = {} }
    if #knownNotes == 0 then
        page.body = 'No notes yet.'
    else
        page.body = string.format('%d note(s).', #knownNotes)
    end
    for i = #knownNotes, 1, -1 do  -- newest first
        local rec = noteRecord(knownNotes[i])
        if rec then
            page.entries[#page.entries + 1] = { text = noteTitle(rec), action = function() show(notePage(rec)) end }
        end
    end
    page.entries[#page.entries + 1] = backEntry('Close')
    return page
end

local terminalPage  -- forward

local function itemAction(item)
    return function()
        if item.script ~= '' then
            print('[esm4terminal] entry "' .. item.text .. '" has a result script that is not run yet:\n' .. item.script)
        end
        if item.note then
            local rec = noteRecord(item.note)
            if rec then
                if item.addNote then addNote(rec.id) end
                local page = notePage(rec)
                if item.resultText ~= '' then
                    page.body = item.resultText .. '\n\n' .. (page.body or '')
                end
                show(page)
                return
            end
        end
        if item.subMenu then
            local ok, sub = pcall(types.ESM4Terminal.record, item.subMenu)
            if ok and sub then
                show(terminalPage(sub, item.resultText))
                return
            end
            print('[esm4terminal] unknown sub-menu terminal: ' .. tostring(item.subMenu))
        end
        show({
            title = pageStack[#pageStack] and pageStack[#pageStack].title,
            body = item.resultText ~= '' and item.resultText or '(no response)',
            entries = { backEntry() },
        })
    end
end

terminalPage = function(rec, intro)
    local body = rec.text
    if intro and intro ~= '' then
        body = intro .. '\n\n' .. body
    end
    local page = { title = rec.name ~= '' and rec.name or rec.editorId, body = body, entries = {} }
    for _, item in ipairs(rec.items) do
        page.entries[#page.entries + 1] = { text = item.text, action = itemAction(item) }
    end
    page.entries[#page.entries + 1] = backEntry(#pageStack == 0 and 'Exit' or 'Back')
    return page
end

-- ------------------------------------------------------------ handlers

local keyToIndex = {}
for i = 1, 9 do
    keyToIndex[input.KEY['_' .. i]] = i
end

local function onKeyPress(key)
    if element then
        local index = keyToIndex[key.code]
        if index then
            choose(index)
        elseif key.code == input.KEY.UpArrow then
            selected = math.max(1, selected - 1)
            render()
        elseif key.code == input.KEY.DownArrow then
            selected = math.min(#shownEntries, selected + 1)
            render()
        elseif key.code == input.KEY.Enter then
            choose(selected)
        elseif key.code == input.KEY.Backspace then
            back()
        end
        return
    end
    if key.code == input.KEY.N and I.UI.getMode() == nil and not core.isWorldPaused() then
        open(notesListPage())
    end
end

return {
    interfaceName = 'ESM4Notes',
    ---
    -- @module ESM4Notes
    -- @context player
    -- @usage require('openmw.interfaces').ESM4Notes.addNote('FormId:0x...')
    interface = {
        version = 0,
        --- Remember a note (NOTE record id). Returns true if it was new.
        addNote = function(id) return addNote(id) end,
        --- List of known note record ids, in pickup order.
        getNotes = function()
            local res = {}
            for i, id in ipairs(knownNotes) do res[i] = id end
            return res
        end,
        --- Open the notes list.
        openNotes = function() open(notesListPage()) end,
    },
    engineHandlers = {
        onKeyPress = onKeyPress,
        onSave = function()
            return { notes = knownNotes }
        end,
        onLoad = function(data)
            knownNotes, knownSet = {}, {}
            if data and data.notes then
                for _, id in ipairs(data.notes) do addNote(id, true) end
            end
        end,
    },
    eventHandlers = {
        ESM4OpenTerminal = function(data)
            if element then return end
            open(terminalPage(types.ESM4Terminal.record(data.terminal)))
        end,
        ESM4PickUpNote = function(data)
            local rec = noteRecord(data.note)
            if rec == nil then return end
            if rec.pickUpSound then pcall(ambient.playSound, rec.pickUpSound) end
            addNote(rec.id)
        end,
        ESM4AddNote = function(data)
            local id = data.note or core.obscript.resolveNoteEditorId(data.editorId)
            if id == nil then
                print('[esm4terminal] AddNote: unknown note editor id: ' .. tostring(data.editorId))
                return
            end
            addNote(id)
        end,
        UiModeChanged = function(data)
            -- Esc (or anything else) took the interface away: drop the window.
            if element and data.newMode == nil then
                element:destroy()
                element = nil
                pageStack = {}
                shownEntries = {}
            end
        end,
    },
}
