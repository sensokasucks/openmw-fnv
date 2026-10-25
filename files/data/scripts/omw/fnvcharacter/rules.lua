-- FNV character rules: XP table, level-up rewards, karma bands and
-- reputation tiers. Pure Lua: game settings come from a gmst(name, fallback)
-- function, so this module can be tested outside the engine.
--
-- Formulas from FalloutNV.exe (see character.md in the project notes):
--   CalcXPRequiredForLevel 0x648b50, CalcLevelUpSkillPoints 0x648c10,
--   ShowLevelUpMenu 0x784c80, GetReputationTier 0x616950.

local M = {}

-- XP needed to reach `level`: 0 below level 2, else the sum over k = 0 .. level-2
-- of iXPBase + k * iXPBumpBase. With FalloutNV.esm (200, 150) this is
-- 25 (L-1)(3L+2): 200, 550, 1050, ...
function M.xpForLevel(level, gmst)
    if level < 2 then return 0 end
    local base = gmst('iXPBase', 200)
    local bump = gmst('iXPBumpBase', 150)
    local n = level - 1
    return n * base + bump * n * (n - 1) / 2
end

function M.maxLevel(gmst)
    return gmst('iMaxCharacterLevel', 30)
end

-- The level `xp` experience points give, capped at the maximum level.
function M.levelForXP(xp, gmst)
    local level = 1
    local max = M.maxLevel(gmst)
    while level < max and xp >= M.xpForLevel(level + 1, gmst) do
        level = level + 1
    end
    return level
end

-- Skill points for reaching `level`: 10 + Int/2 (truncated), plus 1 on even
-- levels when Intelligence is odd. The game hardcodes these numbers
-- (iLevelUpSkillPointsBase is never read).
function M.skillPoints(level, intelligence)
    intelligence = math.floor(intelligence)
    local points = 10 + math.floor(intelligence / 2)
    if intelligence % 2 == 1 and level % 2 == 0 then
        points = points + 1
    end
    return points
end

-- Whether reaching `level` gives a perk (every iLevelsPerPerk levels).
function M.perkAtLevel(level, gmst)
    local every = gmst('iLevelsPerPerk', 2)
    return every > 0 and level % every == 0
end

-- ------------------------------------------------------------------ karma

function M.clampKarma(karma, gmst)
    return math.max(gmst('iKarmaMin', -1000), math.min(gmst('iKarmaMax', 1000), karma))
end

-- GetIsAlignment values
M.alignment = { good = 0, neutral = 1, evil = 2, veryGood = 3, veryEvil = 4 }
M.alignmentNames = { [0] = 'Good', [1] = 'Neutral', [2] = 'Evil', [3] = 'Very Good', [4] = 'Very Evil' }

function M.alignmentOf(karma, gmst)
    if karma >= gmst('fAlignVeryGoodMinKarma', 750) then return M.alignment.veryGood end
    if karma >= gmst('fAlignGoodMinKarma', 250) then return M.alignment.good end
    if karma <= gmst('fAlignVeryEvilMaxKarma', -750) then return M.alignment.veryEvil end
    if karma <= gmst('fAlignEvilMaxKarma', -250) then return M.alignment.evil end
    return M.alignment.neutral
end

-- ------------------------------------------------------------- reputation

-- AddReputation / RemoveReputation amounts, by the script's size argument 1..5
M.bumpSettings = { 'fReputationBumpVeryMinor', 'fReputationBumpMinor', 'fReputationBumpAverage',
    'fReputationBumpMajor', 'fReputationBumpVeryMajor' }
local bumpDefaults = { 1, 2, 4, 7, 12 }

function M.bump(size, gmst)
    size = math.floor(tonumber(size) or 0)
    if size < 1 then return 0 end
    size = math.min(size, #M.bumpSettings)
    return gmst(M.bumpSettings[size], bumpDefaults[size])
end

-- Tier 0..3 of `points` fame or infamy with a reputation whose DATA value is `value`.
function M.tier(points, value, gmst)
    if value == nil or value <= 0 or points <= 0 then return 0 end
    local fraction = points / value
    if fraction >= gmst('fReputationThresholdThree', 1.0) then return 3 end
    if fraction >= gmst('fReputationThresholdTwo', 0.5) then return 2 end
    if fraction >= gmst('fReputationThresholdOne', 0.15) then return 1 end
    return 0
end

-- The named standing for fame tier f and infamy tier i (the 16 states of the Pip-Boy).
local standings = {
    [0] = { [0] = 'Neutral', 'Shunned', 'Hated', 'Vilified' },
    [1] = { [0] = 'Accepted', 'Mixed', 'Sneering Punk', 'Merciful Thug' },
    [2] = { [0] = 'Liked', 'Smiling Troublemaker', 'Unpredictable', 'Soft-Hearted Devil' },
    [3] = { [0] = 'Idolized', 'Good-Natured Rascal', 'Dark Hero', 'Wild Child' },
}

function M.standing(fameTier, infamyTier)
    return standings[fameTier][infamyTier]
end

return M
