-- Window frames in the FNV style for the Lua menus of FNV content (dialogue, character creation,
-- barter, crafting, level up): a thin border in the HUD colour around a dark, see-through panel,
-- in place of Morrowind's carved borders (scripts/omw/mwui/borders.lua). Same layout as the
-- Morrowind templates, so they swap in one for one:
--
--   local frame = require('scripts.omw.fnvhud.frame')
--   { template = frame.boxSolidThick, content = ui.content { ... } }

local ui = require('openmw.ui')
local util = require('openmw.util')

local v2 = util.vector2

-- sHUDColor's default, 255, 182, 66, as in scripts/omw/fnvhud/player.lua
local color = util.color.rgb(1.0, 0.714, 0.259)
local white = ui.texture { path = 'white' }

local sideParts = {
    left = v2(0, 0),
    right = v2(1, 0),
    top = v2(0, 0),
    bottom = v2(0, 1),
}
local cornerParts = {
    top_left = v2(0, 0),
    top_right = v2(1, 0),
    bottom_left = v2(0, 1),
    bottom_right = v2(1, 1),
}

local function piece(props)
    props.resource = white
    props.color = color
    return { type = ui.TYPE.Image, props = props }
end

-- `background`: the panel's opacity, or nil for none
local function frame(borderSize, background)
    local borderV = v2(1, 1) * borderSize
    local box = {
        type = ui.TYPE.Container,
        content = ui.content {},
    }
    if background then
        box.content:add {
            type = ui.TYPE.Image,
            props = {
                resource = white,
                color = util.color.rgb(0, 0, 0),
                alpha = background,
                relativeSize = v2(1, 1),
                size = borderV * 2,
            },
        }
    end
    for k, v in pairs(sideParts) do
        local direction = (k == 'top' or k == 'bottom') and v2(1, 0) or v2(0, 1)
        box.content:add(piece {
            position = (direction + v) * borderSize,
            relativePosition = v,
            size = (v2(1, 1) - direction) * borderSize,
            relativeSize = direction,
        })
    end
    for _, v in pairs(cornerParts) do
        box.content:add(piece {
            position = v * borderSize,
            relativePosition = v,
            size = borderV,
        })
    end
    box.content:add {
        external = { slot = true },
        props = {
            position = borderV,
            relativeSize = v2(1, 1),
        },
    }
    return box
end

return {
    color = color,
    box = frame(1, nil),
    boxSolid = frame(1, 0.85),
    boxSolidThick = frame(2, 0.85),
}
