-- The player's Pip-Boy radio: which station is tuned in, and playing it.
--
-- Stations broadcast from scripts/omw/fnvradio/global.lua, which publishes
-- what each one plays in the 'FNVRadio' storage section; this script plays
-- the tuned station's current file in 2D, from where the broadcast is, and
-- follows it from line to line. A station is heard where its range reaches
-- (XRDO): everywhere, within a radius of where it broadcasts from (with
-- static towards the edge), the same worldspace and its interiors, or the
-- same cell. Each player has their own tuning (saved with the player), so in
-- co-op everyone picks their own station.
--
-- The Pip-Boy's Radio page uses I.FNVRadio: getStations, tune, turnOff.

local ambient = require('openmw.ambient')
local core = require('openmw.core')
local self = require('openmw.self')
local storage = require('openmw.storage')

local radio = core.obscript and core.obscript.radio
if radio == nil or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end

local STATIC_FILE = 'sound\\fx\\ui\\radio\\ui_radio_static_lp.wav'
local TUNE_SOUND = 'sound\\fx\\ui\\radio\\ui_radio_signalfound2.wav'

local published = storage.globalSection('FNVRadio')

local stations = {}
local byId = {}
for _, s in ipairs(radio.getStations()) do
    if not s.nonProxy then
        stations[#stations + 1] = s
        byId[s.id] = s
    end
end
table.sort(stations, function(a, b) return a.name < b.name end)

local tuned = nil -- station id, saved
local playing = nil -- { file, fileStart }
local volume = 1
-- Turned down while someone talks to the player (fRadioDialogMute; FNVRadio.setMute)
local mute, muteTarget, muteRate = 1, 1, 0
local staticVolume = 0

local function lower(x)
    return tostring(x or ''):lower()
end

-- How well the player gets a station: 0 (not at all) .. 1.
local function signal(s)
    local cell = self.cell
    if cell == nil then return 0 end
    local origin = s.origin or s
    local sameCell = lower(cell.id) == lower(origin.cell)
    local rangeType = s.rangeType
    if rangeType == 1 then return 1 end -- everywhere
    if rangeType == 3 or rangeType == 4 then -- linked interiors, current cell
        return sameCell and 1 or 0
    end
    if rangeType == 2 then -- the worldspace and its interiors
        if not cell.isExterior then return 1 end
        return lower(cell.worldSpaceId) == lower(origin.worldSpace) and 1 or 0
    end
    -- a radius around where it broadcasts from
    if sameCell then return 1 end
    if not cell.isExterior or origin.interior or lower(cell.worldSpaceId) ~= lower(origin.worldSpace) then
        return 0
    end
    local radius = s.radius or 0
    if radius <= 0 then return 0 end
    local d = (self.position - origin.position):length()
    if d >= radius then return 0 end
    return 1 - d / radius
end

-- Station volume and static volume for a signal strength: static fades in over the outer
-- staticPercent of the range.
local function mix(s, strength)
    local band = (s.staticPercent or 0) / 100
    if s.rangeType ~= 0 or band <= 0 or strength >= band then return 1, 0 end
    local t = 1 - strength / band
    return 1 - 0.6 * t, 0.5 * t
end

local function stationInfo(id)
    local list = published:get('stations')
    return list and list[id]
end

local function clock()
    return core.getRealTime() + (published:get('offset') or 0)
end

local function stopPlaying()
    if playing ~= nil then
        core.sound.stopSay(self)
        playing = nil
    end
end

local function setStatic(v)
    if v > 0.02 then
        if staticVolume <= 0.02 then
            ambient.playSoundFile(STATIC_FILE, { loop = true, volume = v })
        end
    elseif staticVolume > 0.02 then
        ambient.stopSoundFile(STATIC_FILE)
    end
    staticVolume = v
end

local function update()
    local s = tuned and byId[tuned]
    local info = s and stationInfo(tuned)
    local strength = s and signal(s) or 0
    if s == nil or info == nil or not info.active or strength <= 0 then
        stopPlaying()
        setStatic(0)
        return
    end
    local v, sv = mix(s, strength)
    v, sv = v * mute, sv * mute
    setStatic(sv)
    if info.file == nil then
        stopPlaying()
        return
    end
    local t = clock()
    local fresh = playing == nil or playing.file ~= info.file or playing.fileStart ~= info.fileStart
    local ended = not fresh and not core.sound.isSayActive(self)
    if fresh or (ended and info.fileEnd and t < info.fileEnd - 0.5) then
        radio.say(self, info.file, { offset = math.max(0, t - (info.fileStart or t)), volume = v })
        playing = { file = info.file, fileStart = info.fileStart }
        volume = v
    elseif math.abs(v - volume) > 0.02 then
        radio.setVolume(self, v)
        volume = v
    end
end

local function listStations()
    local res = {}
    for _, s in ipairs(stations) do
        local info = stationInfo(s.id)
        local strength = signal(s)
        if info and info.active and strength > 0 then
            res[#res + 1] = { id = s.id, name = s.name, strength = strength, tuned = s.id == tuned }
        end
    end
    return res
end

return {
    interfaceName = 'FNVRadio',
    interface = {
        version = 0,
        --- Stations the Pip-Boy can pick up here and now, by name: { id, name, strength (0..1), tuned }.
        getStations = listStations,
        --- What the tuned station says now: the DJ's line, or the song's title ("{Blue Moon}" in the data).
        getNowPlaying = function()
            local info = tuned and stationInfo(tuned)
            local text = info and info.active and info.text
            if not text or text == '' then return nil end
            local song = text:match('^%s*{(.-)}%s*$')
            return song and ('Now playing: ' .. song) or text
        end,
        --- The tuned station's id, nil when the radio is off.
        getTuned = function() return tuned end,
        --- Tunes in a station (id from getStations); the same one again turns the radio off.
        tune = function(id)
            if id == tuned then
                tuned = nil
            elseif byId[id] then
                tuned = id
                ambient.playSoundFile(TUNE_SOUND)
            end
            stopPlaying()
            update()
        end,
        --- Turns the radio down to factor of its volume over seconds (1 brings it back), as the
        -- original does while someone talks to the player.
        setMute = function(factor, seconds)
            muteTarget = factor
            muteRate = (seconds and seconds > 0) and math.abs(factor - mute) / seconds or math.huge
        end,
        turnOff = function()
            tuned = nil
            update()
        end,
        --- Whether the radio is on and picks up its station (location music stays quiet then).
        isPlaying = function()
            local s = tuned and byId[tuned]
            local info = s and stationInfo(tuned)
            return info ~= nil and info.active and signal(s) > 0
        end,
    },
    engineHandlers = {
        -- onFrame runs while the world is paused too (the Pip-Boy open)
        onFrame = function()
            if mute ~= muteTarget then
                local step = muteRate * core.getRealFrameDuration()
                if math.abs(muteTarget - mute) <= step then mute = muteTarget
                elseif mute < muteTarget then mute = mute + step
                else mute = mute - step end
            end
            update()
        end,
        onSave = function()
            return { tuned = tuned }
        end,
        onLoad = function(data)
            tuned = type(data) == 'table' and data.tuned or nil
            playing = nil
        end,
    },
}
