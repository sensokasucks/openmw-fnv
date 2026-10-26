-- The look of FNV's menus for the Lua ones (scripts/omw/fnvmenus): text in the HUD colour in the game's
-- Monofonto fonts (Gui::FontLoader loads them as "FalloutFont1" .. "FalloutFont8"), at half strength until
-- the mouse is over it; buttons get a box around them then (menus\prefabs\text_box.xml, box.xml); panels
-- have a line along the top and the bottom with short lines fading from their ends (top_bracket.xml,
-- bottom_bracket.xml) over a dark fill.

local ambient = require('openmw.ambient')
local async = require('openmw.async')
local core = require('openmw.core')
local ui = require('openmw.ui')
local util = require('openmw.util')

local v2 = util.vector2

local M = {}

-- sHUDColor's default, 255, 182, 66, as in scripts/omw/fnvhud/player.lua
M.color = util.color.rgb(1.0, 0.714, 0.259)
M.black = util.color.rgb(0, 0, 0)
M.white = ui.texture { path = 'white' }

-- Fallout_default.ini's sFontFile_N, as the menu XMLs number them
M.FONT_GLOW = 'FalloutFont1'
M.FONT = 'FalloutFont2'
M.FONT_SMALL = 'FalloutFont3'
M.FONT_DIALOG = 'FalloutFont6'

M.TEXT = 22
M.SMALL = 18
M.LINE = 2 -- globals.xml _line_thickness
M.DIM = 0.5 -- _line_alpha of a button without the mouse over it (128 of 255)

function M.gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    if value == nil or value == '' then return default end
    return value
end

local SOUNDS = {
    focus = 'sound/fx/ui/menu/ui_menu_focus.wav',
    ok = 'sound/fx/ui/menu/ui_menu_ok.wav',
    cancel = 'sound/fx/ui/menu/ui_menu_cancel.wav',
    prevnext = 'sound/fx/ui/menu/ui_menu_prevnext.wav',
}
function M.sound(name)
    pcall(ambient.playSoundFile, SOUNDS[name] or name)
end

function M.text(str, props)
    props = props or {}
    props.text = tostring(str)
    props.textColor = props.textColor or M.color
    props.textSize = props.textSize or M.TEXT
    props.font = props.font or M.FONT
    if props.autoSize == nil then props.autoSize = props.size == nil end
    return { type = ui.TYPE.Text, props = props }
end

function M.rect(position, size, alpha, color)
    return { type = ui.TYPE.Image,
        props = { resource = M.white, position = position, size = size, color = color or M.color, alpha = alpha or 1 } }
end

local textures = {}
function M.texture(path)
    path = path:gsub('\\', '/'):lower()
    if not path:find('^textures/') then path = 'textures/' .. path end
    if textures[path] == nil then
        local ok, tex = pcall(ui.texture, { path = path })
        textures[path] = ok and tex or false
    end
    return textures[path] or nil
end

function M.image(path, props)
    local tex = M.texture(path)
    if tex == nil then return nil end
    props = props or {}
    props.resource = tex
    props.color = props.color or M.color
    return { type = ui.TYPE.Image, props = props }
end

-- A vertical line fading out along its length (fade_to_bottom.dds / fade_to_top.dds)
local function fadeLine(content, x, y, height, down)
    local steps = 8
    local step = height / steps
    for i = 0, steps - 1 do
        local alpha = 1 - (i + 0.5) / steps
        local sy = down and (y + i * step) or (y + height - (i + 1) * step)
        content:add(M.rect(v2(x, sy), v2(M.LINE, math.ceil(step)), alpha))
    end
end

-- The top and bottom brackets of a panel `size` big, into `content`
function M.brackets(content, size, sideHeight)
    sideHeight = sideHeight or 50
    content:add(M.rect(v2(0, 0), v2(size.x, M.LINE)))
    fadeLine(content, 0, 0, sideHeight, true)
    fadeLine(content, size.x - M.LINE, 0, sideHeight, true)
    content:add(M.rect(v2(0, size.y - M.LINE), v2(size.x, M.LINE)))
    fadeLine(content, 0, size.y - sideHeight, sideHeight, false)
    fadeLine(content, size.x - M.LINE, size.y - sideHeight, sideHeight, false)
end

-- An outline box (box.xml) at `position`, `size` big
function M.box(content, position, size, alpha, fill)
    if fill then content:add(M.rect(position, size, fill)) end
    content:add(M.rect(position, v2(size.x, M.LINE), alpha))
    content:add(M.rect(position + v2(0, size.y - M.LINE), v2(size.x, M.LINE), alpha))
    content:add(M.rect(position, v2(M.LINE, size.y), alpha))
    content:add(M.rect(position + v2(size.x - M.LINE, 0), v2(M.LINE, size.y), alpha))
end

-- A dark, see-through panel with brackets: the frame of most FNV menus
function M.panel(size, content, fill)
    local inner = ui.content {}
    inner:add(M.rect(v2(0, 0), size, fill or 0.75, M.black))
    M.brackets(inner, size)
    for _, child in ipairs(content or {}) do inner:add(child) end
    return { type = ui.TYPE.Widget, props = { size = size }, content = inner }
end

-- A button (text_box.xml): `def` = { id, label, position, size, align ('left' | 'center' | 'right'), enabled,
-- onClick }. `state.hover` is the id of the button under the mouse; `rerender` redraws the menu.
function M.button(def, state, rerender)
    local hovered = state.hover == def.id and def.enabled ~= false
    local size = def.size or v2(260, 44)
    local content = ui.content {}
    if hovered then M.box(content, v2(0, 0), size, 1, 0.12) end
    local align = def.align or 'center'
    local h = align == 'left' and ui.ALIGNMENT.Start or align == 'right' and ui.ALIGNMENT.End or ui.ALIGNMENT.Center
    content:add(M.text(def.label, {
        position = v2(10, 0), size = size - v2(20, 0), autoSize = false,
        textAlignH = h, textAlignV = ui.ALIGNMENT.Center, textSize = def.textSize or M.TEXT,
        font = def.font,
        alpha = def.enabled == false and 0.25 or (hovered and 1 or M.DIM),
    }))
    return {
        type = ui.TYPE.Widget,
        props = { position = def.position, size = size, anchor = def.anchor, relativePosition = def.relativePosition },
        content = content,
        events = {
            mouseClick = async:callback(function()
                if def.enabled == false then return end
                M.sound('ok')
                def.onClick()
            end),
            focusGain = async:callback(function()
                if state.hover ~= def.id then
                    state.hover = def.id
                    if def.enabled ~= false then M.sound('focus') end
                    rerender()
                end
            end),
            focusLoss = async:callback(function()
                if state.hover == def.id then
                    state.hover = nil
                    rerender()
                end
            end),
        },
    }
end

-- A full-screen layer that darkens the game behind a menu (the menus' explorefade)
function M.dim(alpha)
    return { type = ui.TYPE.Image,
        props = { resource = M.white, relativeSize = v2(1, 1), color = M.black, alpha = alpha or 0.5 } }
end

return M
