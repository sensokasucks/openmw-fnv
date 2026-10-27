-- FO3/FNV crime: stealing, assault, murder and trespass, as FalloutNV.exe raises and punishes them
-- (ghidra-findings-3-crime.md). There are no bounties, fines or jail in FNV; a crime costs karma, counts
-- against the victim's factions (and their reputation's infamy) and turns the victim, or whole factions,
-- against the player.
--
--   * Steal (0x8bfa40): taking an owned item from the world or a container. Owner: the item's own XOWN, then
--     its container's, then (not for doors and activators) the cell's; an XGLB global that is set makes it
--     free, and faction-owned things are free to the faction's members. Karma fKarmaModStealing (-5) unless the
--     owner is evil, seen or not. Only the owner (or the nearest loaded member of the owning faction) can catch
--     the player, when it detects them: it says Steal, the owning factions get a minor crime and infamy
--     fReputationMinorCrimeNeg, and the first iStealWarnings (2) times that is all; after that the victim turns
--     on the player, as it does at once when caught twice on the same day.
--   * Assault (0x8c0460) and murder (0x8c09e0): hitting or killing an NPC that was not fighting the player
--     (murder also by a teammate). Every actor that detects the player is a witness. When one of the victim's
--     factions tracks crime (FACT 0x100) the factions become enemies of the player and the witnesses say
--     Assault / Murder (murder: the victim's own faction members attack); otherwise they say the NoCrime topic
--     and attack only if their Aggression says so. Murder seen by anyone: major crime and infamy
--     fReputationMajorCrimeNeg; assault seen: major crime.
--   * Karma for any kill by the player (0x89d900), by the victim's alignment: Good fKarmaModMurderingGoodNPC,
--     Very Good ...VeryGoodNPC, Evil fKarmaModKillingEvilActor, Very Evil ...VeryEvilActor.
--   * Trespass (0x546da0): in a cell with an owner, not Public and without XGLB, that is not the player's (an NPC
--     owner, or a faction the player ranks below the cell's XRNK in). The owner or an owning faction member that
--     detects the player says GuardTrespass; fAITrespassWarningTimer (10 s) later, if the player is still there,
--     SendTrespassAlarm: those of them that detect the player attack, and the owners get a minor crime.
-- Not done: pickpocketing (there is no pickpocket menu yet), owned beds, warners walking up to the player.
--
-- Conditions and script functions: GetCrime, GetCrimeKnown, IsTrespassing, GetTrespassWarningLevel,
-- IsInMyOwnedCell, IsGuard, IsPCAMurderer, GetMinorCrimeCount, GetMajorCrimeCount, GetPCEnemyofFaction,
-- SetPCEnemyofFaction, GetActorCrimePlayerEnemy, GetActorFactionPlayerEnemy, ClearFactionPlayerEnemyFlag,
-- ClearActorsFactionsPlayerEnemyFlag, SendAssaultAlarm, SendTrespassAlarm, IgnoreCrime, GetIgnoreCrime.

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local combat = core.obscript and core.obscript.combat
if combat == nil or combat.ownership == nil or types.ESM4NPC == nil
    or not (core.contentFiles.has('falloutnv.esm') or core.contentFiles.has('fallout3.esm')) then
    return {}
end
local stats = core.obscript.stats
local rules = require('scripts.omw.fnvcharacter.rules')

local STEAL, TRESPASS, ASSAULT, MURDER = 0, 2, 3, 4 -- crime types (1 is pickpocket)
local RESPONSE_DISTANCE = 10000 -- iCrimeAlarmRecDistance
local TRESPASS_CHECK_EVERY = 1.0

-- the default topics the original speaks (group 2), by their editor ids
local TOPICS = {
    steal = { 'Steal' },
    assault = { 'Assault' },
    murder = { 'Murder' },
    assaultNoCrime = { 'AssaultNoCrime', 'AssaultNC' },
    murderNoCrime = { 'MurderNoCrime', 'MurderNC' },
    trespass = { 'GuardTrespass', 'Trespass' },
}

local state -- see newState
local function newState()
    return {
        version = 1,
        crimes = {}, -- victim id -> { { type, warned }, ... }: the victim treats the player as an enemy (2d)
        factionEnemy = {}, -- faction form id -> true (FACT runtime flag 0x10)
        minor = {}, -- faction form id -> count
        major = {},
        warnings = 0, -- steal warnings given (player+0x228)
        caughtDay = nil, -- the day the player was last caught stealing
        murderer = false,
        counts = { [0] = 0, 0, 0, 0, 0 }, -- crimes of each type (player stats)
        ignore = {}, -- actor id -> true (IgnoreCrime)
    }
end
state = newState()

local simTime = 0
local nextTrespassCheck = 0
local trespass = nil -- { cell, owner, warnedBy, alarmAt, alarmed } while the player trespasses

local function log(text)
    print('[crime] ' .. text)
end

local function gmst(name, default)
    local value = core.getFNVGMST and core.getFNVGMST(name)
    return type(value) == 'number' and value or default
end

local function isPlayer(obj)
    return obj ~= nil and types.Player.objectIsInstance(obj)
end

local function isNpc(obj)
    return obj ~= nil and types.ESM4NPC.objectIsInstance(obj)
end

local function isAlive(obj)
    return obj ~= nil and obj:isValid() and obj.enabled and not combat.isDead(obj)
end

local function key(obj)
    return tostring(obj.id)
end

local function sameId(a, b)
    return a ~= nil and b ~= nil and tostring(a):lower() == tostring(b):lower()
end

-- the low 24 bits of a form id written as FormId:0x...
local function formIndex(text)
    local hex = type(text) == 'string' and text:match('0x(%x+)')
    return hex and tonumber(hex, 16) % 0x1000000
end

local function day()
    return math.floor(core.getGameTime() / 86400)
end

local function sameCell(a, b)
    return a ~= nil and b ~= nil and a.id == b.id
end

local function isTeammate(actor)
    return I.FNVAI ~= nil and I.FNVAI.isTeammate ~= nil and I.FNVAI.isTeammate(actor)
end

local function detectsPlayer(actor)
    return I.FNVCombat ~= nil and I.FNVCombat.noticesPlayer(actor)
end

local function say(actor, topics, target)
    if isNpc(actor) and I.FNVDialogue and I.FNVDialogue.say then
        I.FNVDialogue.say(actor, topics, target)
    end
end

local function startCombat(actor, target)
    if I.FNVCombat then I.FNVCombat.startCombat(actor, target) end
end

local function factionRank(obj, faction)
    if I.FNVDialogue and I.FNVDialogue.factionRank then
        return I.FNVDialogue.factionRank(obj, faction)
    end
    for _, f in ipairs(combat.getFactions(obj)) do
        if sameId(f.id, faction) then return f.rank end
    end
    return nil
end

-- the factions an actor belongs to (its record's, with AddToFaction changes for those)
local function factionsOf(actor)
    local list = {}
    for _, f in ipairs(combat.getFactions(actor)) do
        if factionRank(actor, f.id) ~= nil then list[#list + 1] = f.id end
    end
    return list
end

local factionCache = {}
local function faction(id)
    local f = factionCache[id]
    if f == nil then
        f = combat.getFaction(id) or false
        factionCache[id] = f
    end
    return f or nil
end

local function isPlayerFaction(id)
    local f = faction(id)
    return f ~= nil and f.editorId:lower() == 'playerfaction'
end

local function actors()
    local list = {}
    if I.FNVCombat == nil or I.FNVCombat.actors == nil then return list end
    for _, actor in pairs(I.FNVCombat.actors()) do
        if isAlive(actor) then list[#list + 1] = actor end
    end
    return list
end

local function globalSet(id)
    local value = I.FNVDialogue and I.FNVDialogue.globalValue and I.FNVDialogue.globalValue(id)
    return value ~= nil and value ~= 0
end

-- IsOwnedBy (0x5785e0) for the player: its own things, PlayerFaction's, and a faction's for its members
local function ownedByPlayer(own, player)
    if own.global and globalSet(own.global) then return true end
    if formIndex(own.owner) == 0x7 then return true end
    if own.isFaction then
        return isPlayerFaction(own.owner) or factionRank(player, own.owner) ~= nil
    end
    return false
end

local function loadedOwner(owner)
    for _, actor in ipairs(actors()) do
        if sameId(actor.recordId, owner) then return actor end
    end
    return nil
end

local function nearestMember(factionId, near)
    local best, bestDistance = nil, RESPONSE_DISTANCE
    for _, actor in ipairs(actors()) do
        if not isTeammate(actor) and factionRank(actor, factionId) ~= nil then
            local d = (actor.position - near.position):length()
            if d <= bestDistance then best, bestDistance = actor, d end
        end
    end
    return best
end

local function alignmentOf(actor)
    return rules.alignmentOf(stats.get(actor, 'Karma'), gmst)
end

local function isEvil(alignment)
    return alignment == rules.alignment.evil or alignment == rules.alignment.veryEvil
end

-- ---------------------------------------------------------------- crime records

local function addCrime(victim, crimeType, warned)
    local list = state.crimes[key(victim)] or {}
    state.crimes[key(victim)] = list
    list[#list + 1] = { type = crimeType, warned = warned or false, day = day() }
    state.counts[crimeType] = (state.counts[crimeType] or 0) + 1
end

local function isPlayerEnemy(actor)
    local list = state.crimes[key(actor)]
    if list == nil then return false end
    for _, crime in ipairs(list) do
        if not crime.warned then return true end
    end
    return false
end

local function isFactionEnemy(actor)
    if next(state.factionEnemy) == nil then return false end
    for _, id in ipairs(factionsOf(actor)) do
        if state.factionEnemy[id] then return true end
    end
    return false
end

-- The victim's factions that track crime (0x8b8360); marks them enemies of the player when `enemies`.
local function trackedFactions(victim, enemies)
    local list = {}
    for _, id in ipairs(factionsOf(victim)) do
        local f = faction(id)
        if f and f.trackCrime then
            list[#list + 1] = id
            if enemies and not state.factionEnemy[id] then
                state.factionEnemy[id] = true
                log(('%s is now an enemy of the player'):format(f.editorId))
            end
        end
    end
    return list
end

-- Faction crime counters (0x5fda00 / 0x5fda50) and the infamy of their reputations
local function countCrime(factions, major, infamy)
    local counts = major and state.major or state.minor
    for _, id in ipairs(factions) do
        counts[id] = (counts[id] or 0) + 1
        local f = faction(id)
        if infamy and f and f.reputation and I.FNVCharacter and I.FNVCharacter.addReputationExact then
            local amount = major and gmst('fReputationMajorCrimeNeg', 30) or gmst('fReputationMinorCrimeNeg', 2)
            I.FNVCharacter.addReputationExact(f.reputation, 0, amount)
        end
    end
end

local function karma(amount)
    if amount ~= 0 and I.FNVCharacter and I.FNVCharacter.rewardKarma then
        I.FNVCharacter.rewardKarma(amount)
    end
end

-- Everyone who sees the criminal (0x970f60): the actors that detect the player.
local function witnesses(criminal, except)
    local list = {}
    for _, actor in ipairs(actors()) do
        if actor ~= except and actor ~= criminal and not isTeammate(actor) and not state.ignore[key(actor)]
            and detectsPlayer(actor) then
            list[#list + 1] = actor
        end
    end
    return list
end

-- ---------------------------------------------------------------- steal

-- The player takes `count` of `item` (in the world, or in `holder`).
local function took(player, item, count, holder)
    if not isPlayer(player) or item == nil or not item:isValid() then return end
    local own = combat.ownership(item, holder)
    if own == nil or ownedByPlayer(own, player) then return end
    local victim, karmaHit
    if own.isFaction then
        local f = faction(own.owner)
        karmaHit = not (f and f.evil)
        victim = nearestMember(own.owner, player)
    else
        victim = loadedOwner(own.owner)
        karmaHit = victim == nil or not isEvil(alignmentOf(victim))
    end
    if victim ~= nil and (isTeammate(victim) or state.ignore[key(victim)]) then victim = nil end
    log(('the player takes %d %s owned by %s (%s)'):format(count or 1, tostring(item.recordId), own.owner,
        victim and ('seen by ' .. tostring(victim.recordId) .. '? ' .. tostring(detectsPlayer(victim)))
            or 'nobody near'))
    if karmaHit then karma(gmst('fKarmaModStealing', -5)) end
    if victim == nil or not isAlive(victim) or not detectsPlayer(victim) then return end
    local warn = state.warnings < gmst('iStealWarnings', 2)
    local today = day()
    if state.caughtDay == today then
        addCrime(victim, STEAL, false)
        countCrime(trackedFactions(victim, false), false, true)
        log(('%s caught the player stealing again today and attacks'):format(tostring(victim.recordId)))
        startCombat(victim, player)
        return
    end
    state.caughtDay = today
    addCrime(victim, STEAL, warn)
    countCrime(trackedFactions(victim, false), false, true)
    if warn then state.warnings = state.warnings + 1 end
    log(('%s caught the player stealing (%s)'):format(tostring(victim.recordId),
        warn and ('warning ' .. state.warnings) or 'no warnings left'))
    say(victim, TOPICS.steal, player)
end

-- ---------------------------------------------------------------- assault and murder

local function sameFaction(a, b)
    for _, id in ipairs(factionsOf(a)) do
        if factionRank(b, id) ~= nil then return true end
    end
    return false
end

local function shouldAttack(actor)
    return I.FNVCombat ~= nil and I.FNVCombat.shouldAttack ~= nil and I.FNVCombat.shouldAttack(actor)
end

local function assault(victim, attacker, fromScript)
    if not isAlive(victim) or state.ignore[key(victim)] then return end
    if I.FNVCombat and I.FNVCombat.getTarget(victim) == attacker then return end -- already fighting
    addCrime(victim, ASSAULT, false)
    local tracked = trackedFactions(victim, true)
    local seen = detectsPlayer(victim) and 1 or 0
    for _, w in ipairs(witnesses(attacker, victim)) do
        if (fromScript and w == victim) or #tracked > 0 then
            say(w, TOPICS.assault, attacker)
            seen = seen + 1
        elseif shouldAttack(w) then
            startCombat(w, attacker)
        else
            say(w, TOPICS.assaultNoCrime, attacker)
        end
    end
    log(('the player assaults %s: %d witnesses%s'):format(tostring(victim.recordId), seen,
        #tracked > 0 and ', its factions turn hostile' or ''))
    if seen > 0 then countCrime(tracked, not fromScript, false) end
end

local function murder(victim, killer)
    addCrime(victim, MURDER, false)
    local tracked = trackedFactions(victim, true)
    local seen = 0
    for _, w in ipairs(witnesses(killer, victim)) do
        if #tracked == 0 then
            if shouldAttack(w) or (sameFaction(w, victim) and not I.FNVCombat.isInCombat(w)) then
                startCombat(w, killer)
            else
                say(w, TOPICS.murderNoCrime, killer)
            end
        else
            say(w, TOPICS.murder, killer)
            seen = seen + 1
            if sameFaction(w, victim) then startCombat(w, killer) end
        end
    end
    log(('%s murders %s: %d witnesses'):format(tostring(killer.recordId), tostring(victim.recordId), seen))
    if seen > 0 then
        state.murderer = true
        countCrime(tracked, true, true)
    end
end

-- Karma for a kill by the player (0x89d900), by the victim's alignment
local function killKarma(victim)
    local base = types.ESM4Creature.objectIsInstance(victim) and gmst('fKarmaModMurderingNonEvilCreature', 0)
        or gmst('fKarmaModMurderingNonEvilNPC', 0)
    local alignment = alignmentOf(victim)
    local A = rules.alignment
    local amount = base
    if alignment == A.good then amount = gmst('fKarmaModMurderingGoodNPC', -50)
    elseif alignment == A.veryGood then amount = gmst('fKarmaModMurderingVeryGoodNPC', -100)
    elseif alignment == A.evil then amount = gmst('fKarmaModKillingEvilActor', 100)
    elseif alignment == A.veryEvil then amount = gmst('fKarmaModKillingVeryEvilActor', 2)
    end
    karma(amount)
end

-- From fnvcombat for every hit on an actor: the attacker, whether it died, and whether the target already
-- fought the attacker.
local function attacked(target, attacker, killed, alreadyFighting)
    if attacker == nil or target == nil or isPlayer(target) then return end
    local byPlayer = isPlayer(attacker)
    if killed then
        if byPlayer then killKarma(target) end
        -- any kill counts, also of an actor that was fighting the player (killing members of a faction that
        -- already hates the player still costs infamy)
        if byPlayer or isTeammate(attacker) then
            murder(target, world.players[1])
        end
    elseif byPlayer and not alreadyFighting and not isPlayerEnemy(target) and not isFactionEnemy(target)
        and not isTeammate(target) then
        assault(target, attacker, false)
    end
end

-- ---------------------------------------------------------------- trespass

local function isTrespassing(player)
    local cell = combat.cellOwnership(player)
    if cell.owner == nil or cell.public or cell.global ~= nil then return false, cell end
    if formIndex(cell.owner) == 0x7 then return false, cell end
    if cell.isFaction then
        if isPlayerFaction(cell.owner) then return false, cell end
        return (factionRank(player, cell.owner) or -1) < (cell.rank or 0), cell
    end
    return true, cell
end

-- the owner, or an owning faction's member or a guard, in the player's cell
local function isTrespassOwner(actor, cell)
    if not sameCell(actor.cell, world.players[1].cell) then return false end
    if cell.isFaction then
        return factionRank(actor, cell.owner) ~= nil or combat.isGuard(actor)
    end
    return sameId(actor.recordId, cell.owner)
end

local function trespassAlarm(player, cell)
    local attackers = 0
    for _, actor in ipairs(actors()) do
        if not isTeammate(actor) and isTrespassOwner(actor, cell) and detectsPlayer(actor) then
            startCombat(actor, player)
            attackers = attackers + 1
        end
    end
    state.counts[TRESPASS] = (state.counts[TRESPASS] or 0) + 1
    local factions = {}
    if cell.isFaction then
        local f = faction(cell.owner)
        if f and f.trackCrime then factions = { cell.owner } end
    else
        local owner = loadedOwner(cell.owner)
        if owner then factions = trackedFactions(owner, false) end
    end
    countCrime(factions, false, true)
    log(('trespass alarm: %d attack'):format(attackers))
end

local function tickTrespass(player)
    local now, cell = isTrespassing(player)
    if not now then
        if trespass then log('the player is no longer trespassing') end
        trespass = nil
        return
    end
    if trespass == nil or not sameCell(trespass.cell, player.cell) then
        trespass = { cell = player.cell }
        log(('the player is trespassing in %s (owner %s)'):format(tostring(player.cell), cell.owner))
    end
    if trespass.alarmed then return end
    if trespass.warnedBy == nil then
        for _, actor in ipairs(actors()) do
            if not isTeammate(actor) and isTrespassOwner(actor, cell) and detectsPlayer(actor)
                and not I.FNVCombat.isInCombat(actor) then
                trespass.warnedBy = actor
                trespass.alarmAt = simTime + gmst('fAITrespassWarningTimer', 10)
                log(('%s warns the player off'):format(tostring(actor.recordId)))
                say(actor, TOPICS.trespass, player)
                break
            end
        end
    elseif simTime >= trespass.alarmAt then
        trespass.alarmed = true
        trespassAlarm(player, cell)
    end
end

-- ---------------------------------------------------------------- conditions and script functions

local function crimeCount(obj, major)
    local counts = major and state.major or state.minor
    local total = 0
    if isPlayer(obj) then
        for _, n in pairs(counts) do total = total + n end
    elseif obj ~= nil then
        for _, id in ipairs(factionsOf(obj)) do total = total + (counts[id] or 0) end
    end
    return total
end

local function hasCrime(victim, crimeType)
    local list = victim ~= nil and state.crimes[key(victim)]
    if not list then return false end
    for _, crime in ipairs(list) do
        if crimeType == nil or crimeType < 0 or crime.type == crimeType then return true end
    end
    return false
end

local function resolveFaction(f)
    if type(f) ~= 'string' then return nil end
    if f:match('^FormId:') then return f end
    return core.obscript.resolveFactionEditorId and core.obscript.resolveFactionEditorId(f)
end

local function inOwnedCell(actor)
    local cell = combat.cellOwnership(actor)
    if cell.owner == nil then return false end
    if cell.isFaction then return (factionRank(actor, cell.owner) or -1) >= (cell.rank or 0) end
    return sameId(actor.recordId, cell.owner)
end

local installed = false
local function install()
    if installed or I.FNVDialogue == nil then return end
    installed = true
    local D = I.FNVDialogue
    local function cond(index, fn)
        if D.setConditionFunction then D.setConditionFunction(index, fn) end
    end
    cond(116, function(_, obj) return crimeCount(obj, false) end) -- GetMinorCrimeCount
    cond(117, function(_, obj) return crimeCount(obj, true) end) -- GetMajorCrimeCount
    cond(122, function(c, obj) return hasCrime(obj, c.param2) end) -- GetCrime criminal type (player crimes only)
    cond(125, function(_, obj) return obj ~= nil and combat.isGuard(obj) end) -- IsGuard
    cond(144, function(_, obj) -- GetTrespassWarningLevel
        return trespass ~= nil and trespass.warnedBy == obj and 1 or 0
    end)
    cond(145, function(_, obj) return isPlayer(obj) and trespass ~= nil end) -- IsTrespassing
    cond(146, function(_, obj) return obj ~= nil and not isPlayer(obj) and inOwnedCell(obj) end) -- IsInMyOwnedCell
    cond(176, function() return state.murderer end) -- IsPCAMurderer
    cond(192, function(_, obj) return obj ~= nil and state.ignore[key(obj)] == true end) -- GetIgnoreCrime
    cond(197, function(c) return state.factionEnemy[c.param1Form] == true end) -- GetPCEnemyofFaction
    cond(459, function(_, obj) return obj ~= nil and isPlayerEnemy(obj) end) -- GetActorCrimePlayerEnemy
    cond(460, function(_, obj) return obj ~= nil and isFactionEnemy(obj) end) -- GetActorFactionPlayerEnemy

    if D.bindCommand == nil then return end
    local function bind(name, fn) D.bindCommand(name, fn) end
    bind('GetMinorCrimeCount', function(obj) return crimeCount(obj or world.players[1], false) end)
    bind('GetMajorCrimeCount', function(obj) return crimeCount(obj or world.players[1], true) end)
    bind('GetCrime', function(obj, _, crimeType) return hasCrime(obj, tonumber(crimeType)) and 1 or 0 end)
    bind('GetCrimeKnown', function(_, crimeType, _, victim) -- GetCrimeKnown type criminal victim
        return hasCrime(victim, tonumber(crimeType)) and 1 or 0
    end)
    bind('IsGuard', function(obj) return obj ~= nil and combat.isGuard(obj) and 1 or 0 end)
    bind('IsTrespassing', function(obj) return isPlayer(obj) and trespass ~= nil and 1 or 0 end)
    bind('GetTrespassWarningLevel', function(obj) return trespass ~= nil and trespass.warnedBy == obj and 1 or 0 end)
    bind('IsInMyOwnedCell', function(obj) return obj ~= nil and not isPlayer(obj) and inOwnedCell(obj) and 1 or 0 end)
    bind('IsPCAMurderer', function() return state.murderer and 1 or 0 end)
    bind('GetPCEnemyofFaction', function(_, f)
        local id = resolveFaction(f)
        return id and state.factionEnemy[id] and 1 or 0
    end)
    bind('SetPCEnemyofFaction', function(_, f, on)
        local id = resolveFaction(f)
        if id then state.factionEnemy[id] = (tonumber(on) or 1) ~= 0 or nil end
        return 0
    end)
    bind('ClearFactionPlayerEnemyFlag', function(_, f)
        local id = resolveFaction(f)
        if id then state.factionEnemy[id] = nil end
        return 0
    end)
    bind('ClearActorsFactionsPlayerEnemyFlag', function(obj)
        if obj ~= nil then
            state.crimes[key(obj)] = nil
            for _, id in ipairs(factionsOf(obj)) do state.factionEnemy[id] = nil end
        end
        return 0
    end)
    bind('GetActorCrimePlayerEnemy', function(obj) return obj ~= nil and isPlayerEnemy(obj) and 1 or 0 end)
    bind('GetActorFactionPlayerEnemy', function(obj) return obj ~= nil and isFactionEnemy(obj) and 1 or 0 end)
    bind('SendAssaultAlarm', function(obj)
        local player = world.players[1]
        if obj ~= nil and player ~= nil and not isPlayer(obj) then assault(obj, player, true) end
        return 0
    end)
    bind('SendTrespassAlarm', function()
        local player = world.players[1]
        if player ~= nil then
            local now, cell = isTrespassing(player)
            if now then trespassAlarm(player, cell) end
        end
        return 0
    end)
    bind('IgnoreCrime', function(obj, on)
        if obj ~= nil then state.ignore[key(obj)] = (tonumber(on) or 1) ~= 0 or nil end
        return 0
    end)
    bind('GetIgnoreCrime', function(obj) return obj ~= nil and state.ignore[key(obj)] and 1 or 0 end)
end

-- World pick-ups: activating an item in the world takes it
local ITEM_TYPES = { 'ESM4Ammunition', 'ESM4Armor', 'ESM4Book', 'ESM4Clothing', 'ESM4Ingredient', 'ESM4ItemMod',
    'ESM4Key', 'ESM4MiscItem', 'ESM4Potion', 'ESM4Weapon', 'ESM4Note' }
if I.Activation then
    for _, name in ipairs(ITEM_TYPES) do
        local t = types[name]
        if t ~= nil then
            I.Activation.addHandlerForType(t, function(obj, actor)
                if isPlayer(actor) and obj.parentContainer == nil then
                    pcall(took, actor, obj, obj.count, nil)
                end
            end)
        end
    end
end

return {
    interfaceName = 'FNVCrime',
    interface = {
        version = 0,
        --- The player takes count of item, in the world or from holder (a container or body); called before the
        -- move (scripts/omw/fnvmenus).
        took = took,
        --- A hit on an actor (scripts/omw/fnvcombat): raises assault or murder.
        attacked = attacked,
        --- Whether a crime against the actor makes it attack the player on sight.
        isPlayerEnemy = isPlayerEnemy,
        --- Whether one of the actor's factions is an enemy of the player through crime.
        isFactionEnemy = isFactionEnemy,
        isTrespassing = function() return trespass ~= nil end,
        --- For the console: the crime state.
        getState = function() return state end,
        --- For testing: forget all crimes.
        reset = function() state = newState(); trespass = nil end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            simTime = simTime + dt
            install()
            if simTime < nextTrespassCheck then return end
            nextTrespassCheck = simTime + TRESPASS_CHECK_EVERY
            local player = world.players[1]
            if player ~= nil and not types.Actor.isDead(player) then tickTrespass(player) end
        end,
        onSave = function()
            return state
        end,
        onLoad = function(data)
            state = newState()
            if type(data) == 'table' and data.version == 1 then
                for k, v in pairs(data) do state[k] = v end
            end
        end,
    },
}
