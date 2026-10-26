-- Saving, loading and quitting for the FNV pause menu (scripts/omw/fnvmenus/player.lua), which runs in the
-- player's context and cannot reach openmw.menu. The save list goes back through player storage.
--
-- Menu events (types.Player.sendMenuEvent):
--   FNVListSaves {}                       -> storage.playerSection('FNVMenusSaves'): list
--   FNVSaveGame  { description, slot }    slot: an existing save's file name to overwrite, or nil for a new one
--   FNVLoadGame  { dir, slot }
--   FNVQuitGame  {}

local core = require('openmw.core')
local menu = require('openmw.menu')
local storage = require('openmw.storage')

-- Menu scripts start before the content files are known, so this one has no FO3/FNV check: only the FNV
-- pause menu sends it these events.

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

return {
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
