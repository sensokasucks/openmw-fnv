-- FNV music for the player: location music from audio markers, battle music,
-- and PlayMusic.
--
-- FNV places audio markers (REFR with MMRK) over the world. Each names a
-- media location controller (ALOC) and a radius; the closest marker the
-- player stands in (by fraction of its radius) picks the music. The
-- controller lists location media sets (MSET; a faction's place has sets for
-- how the faction sees the player instead), each with day and night files
-- in three layers: the outer one plays anywhere in the radius, the middle one
-- from the marker's layer 2 point inwards, the inner one from layer 3. The
-- original mixes the layers together; here the innermost reached layer plays,
-- and a layer change crossfades. When a piece ends the controller's looping
-- option decides: loop it, pick another set, retrigger after a delay, or stay
-- quiet. Fighting switches to one of the controller's battle sets until the
-- fight is over. Cells with no marker play their music type (CELL XCMO) when
-- it names a file; 1NoMusic and the FO3 folders FNV doesn't ship stay quiet.
--
-- The Pip-Boy radio takes over while it plays (as in FNV, the music stops).

local ambient = require('openmw.ambient')
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local radio = core.obscript and core.obscript.radio
if radio == nil or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local CHECK_INTERVAL = 1.0
local FADE = 2.0
local COMBAT_LINGER = 5.0 -- fCombatMusicStopTime

-- ---------------------------------------------------------------- records

local markersByPlace = {} -- lower-case world space id (exterior) or cell id (interior) -> markers
for _, m in ipairs(radio.getAudioMarkers()) do
    if not m.initiallyDisabled and m.controller ~= '' and m.radius > 0 then
        local key = (m.interior and m.cell or m.worldSpace):lower()
        local list = markersByPlace[key]
        if list == nil then
            list = {}
            markersByPlace[key] = list
        end
        list[#list + 1] = m
    end
end

local cache = {}
local function cached(kind, id, fn)
    local key = kind .. id
    local v = cache[key]
    if v == nil then
        v = fn(id) or false
        cache[key] = v
    end
    return v or nil
end
local function controller(id) return cached('aloc', id, radio.getMediaLocation) end
local function mediaSet(id) return cached('mset', id, radio.getMediaSet) end
local function musicType(id) return cached('musc', id, radio.getMusic) end

-- ---------------------------------------------------------------- where the player is

local function closestMarker()
    local cell = self.cell
    if cell == nil then return nil end
    local key = (cell.isExterior and tostring(cell.worldSpaceId) or tostring(cell.id)):lower()
    local list = markersByPlace[key]
    if list == nil then return nil end
    local best, bestFraction = nil, 1
    local pos = self.position
    for _, m in ipairs(list) do
        local f = (pos - m.position):length() / m.radius
        if f < bestFraction then
            best, bestFraction = m, f
        end
    end
    return best, bestFraction
end

local function isNight(c)
    local hour = (core.getGameTime() / 3600) % 24
    local dayStart, nightStart = 6, 23.9 -- the defaults (6:00, 23:54)
    if c.looping < 4 then
        dayStart = c.dayStart or dayStart
        nightStart = c.nightStart or nightStart
    end
    return hour < dayStart or hour >= nightStart
end

-- The file of a location set for the layer reached (1 outer .. 3 inner), falling back outwards.
local function locationFile(set, layer, night)
    local first = night and 5 or 2
    for l = layer, 1, -1 do
        local bit = 2 ^ (first - 2 + l - 1)
        local file = set.files[first + l - 1]
        if file ~= nil and math.floor(set.enabled / bit) % 2 == 1 then
            return file
        end
    end
    -- some sets only fill the day files
    for l = layer, 1, -1 do
        local file = set.files[1 + l]
        if file ~= nil then return file end
    end
    return nil
end

-- ---------------------------------------------------------------- playing

local current = nil -- { kind = 'location' | 'battle' | 'cell' | 'scripted', file, controller, set }
local inCombat = false
local combatEndsAt = nil
local retriggerAt = nil
local scriptedUntilEnd = false
local chosenSets = {} -- controller id -> location set id

local function play(file, kind, extra)
    print(('[fnvmusic] %s: %s'):format(kind, file))
    ambient.streamMusic(file, { fadeOut = FADE })
    current = { kind = kind, file = file }
    for k, v in pairs(extra or {}) do current[k] = v end
end

local function stop()
    if current ~= nil then
        ambient.stopMusic()
        current = nil
    end
end

local function pickSet(c, list, avoid)
    if #list == 0 then return nil end
    if #list == 1 then return list[1] end
    for _ = 1, 4 do
        local id = list[math.random(1, #list)]
        if id ~= avoid then return id end
    end
    return list[1]
end

-- The sets a controller plays here: its location sets, or (controllers of a faction's place, like
-- musCtrlGoodsprings) the sets for how the faction sees the player. Reputation isn't asked yet: the
-- controller's "faction not found" choice decides (0 neutral, 1 enemy, 2 ally, 3 friend, 4 location, 5 none).
local function locationSets(c)
    if #c.locationSets > 0 or c.conditionalFaction == '' then return c.locationSets end
    local choice = ({ [0] = c.neutralSets, [1] = c.enemySets, [2] = c.allySets, [3] = c.friendSets,
        [4] = c.locationSets })[c.factionNotFound]
    if choice and #choice > 0 then return choice end
    if c.factionNotFound == 5 then return {} end
    for _, list in ipairs({ c.neutralSets, c.friendSets, c.allySets, c.enemySets }) do
        if #list > 0 then return list end
    end
    return {}
end

local function battleFile(c)
    local id = c and pickSet(c, c.battleSets)
    local set = id and mediaSet(id)
    return set and set.files[2]
end

local function cellFile()
    local info = radio.getCellMusic(self.object)
    local m = info and info.cellMusic ~= '' and musicType(info.cellMusic)
    if not m or m.file == '' then return nil end
    if m.file:sub(-1) == '\\' then
        local files = radio.listSoundFiles(m.file)
        if #files == 0 then return nil end
        return files[math.random(1, #files)]
    end
    return m.file
end

local function update()
    if types.Actor.isDead(self) then return end
    local radioOn = I.FNVRadio and I.FNVRadio.isPlaying and I.FNVRadio.isPlaying()
    if radioOn then
        if current ~= nil and current.kind ~= 'scripted' then stop() end
        return
    end
    local musicPlaying = ambient.isMusicPlaying()
    if current and current.kind == 'scripted' then
        if musicPlaying then return end
        current = nil
    end

    local marker, fraction = closestMarker()
    local c = marker and controller(marker.controller)

    -- battle
    local fighting = inCombat or (combatEndsAt ~= nil and core.getRealTime() < combatEndsAt)
    if fighting then
        if current and current.kind == 'battle' and musicPlaying then return end
        local file = battleFile(c) or (current and current.kind == 'battle' and current.file)
        if file then
            play(file, 'battle')
            return
        end
    elseif current and current.kind == 'battle' then
        stop()
    end

    -- location
    if c then
        local setId = chosenSets[c.id]
        if setId == nil then
            setId = pickSet(c, locationSets(c))
            chosenSets[c.id] = setId
        end
        local set = setId and mediaSet(setId)
        if set == nil then
            stop()
            return
        end
        local layer = 1
        if fraction <= 1 - (marker.layer2 or 0) then layer = 2 end
        if fraction <= 1 - (marker.layer3 or 0) then layer = 3 end
        local file = locationFile(set, layer, isNight(c))
        if file == nil then
            stop()
            return
        end
        if current and current.kind == 'location' and current.controller == c.id then
            if current.file == file and musicPlaying then return end
            if current.file ~= file and musicPlaying then
                play(file, 'location', { controller = c.id }) -- layer or day/night change
                return
            end
            -- the piece ended
            local looping = c.looping % 4
            if looping == 3 then return end -- none
            if looping == 1 then -- random
                chosenSets[c.id] = pickSet(c, locationSets(c), setId)
                set = mediaSet(chosenSets[c.id]) or set
                file = locationFile(set, layer, isNight(c)) or file
            elseif looping == 2 then -- retrigger after a delay
                if retriggerAt == nil then
                    retriggerAt = core.getRealTime() + (c.retriggerDelay or 0)
                    return
                end
                if core.getRealTime() < retriggerAt then return end
            end
            retriggerAt = nil
        end
        play(file, 'location', { controller = c.id })
        return
    end

    -- the cell's own music type
    if current and current.kind == 'cell' and musicPlaying then return end
    local file = cellFile()
    if file then
        play(file, 'cell')
    else
        stop()
    end
end

local nextCheck = 0

return {
    eventHandlers = {
        FNVMusicCombat = function(data)
            if data.inCombat then
                inCombat, combatEndsAt = true, nil
            elseif inCombat then
                inCombat = false
                combatEndsAt = core.getRealTime() + COMBAT_LINGER
            end
            nextCheck = 0
        end,
        FNVMusicPlay = function(data)
            local m = musicType(data.music)
            if not m or m.file == '' then
                stop()
                current = { kind = 'scripted', file = '' } -- 1NoMusic: quiet until the next piece would start
                return
            end
            local file = m.file
            if file:sub(-1) == '\\' then
                local files = radio.listSoundFiles(file)
                file = files[1]
            end
            if file then play(file, 'scripted') end
        end,
    },
    engineHandlers = {
        onFrame = function(dt)
            nextCheck = nextCheck - (dt > 0 and dt or 0.016)
            if nextCheck > 0 then return end
            nextCheck = CHECK_INTERVAL
            update()
        end,
        onLoad = function()
            current = nil
        end,
    },
}
