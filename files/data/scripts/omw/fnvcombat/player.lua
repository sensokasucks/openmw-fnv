-- FO3/FNV guns for the player (see scripts/omw/fnvcombat/global.lua).
--
-- While an FNV weapon is equipped, Ready Weapon draws and holsters it and
-- Use fires it at the crosshair: semi-automatic weapons fire once per click,
-- no faster than the weapon's shots per second, automatic ones while the
-- button is held. The clip holds the weapon's clip size; R reloads, and an
-- empty clip reloads on the next shot. Ammunition in the inventory is not
-- counted yet. There is no first-person weapon model yet either.
--
-- From the console (luap):
--   I.FNVCombat.equip('WeapNV9mmPistol')   -- record id or editor id
--   I.FNVCombat.unequip()

local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local self = require('openmw.self')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local combat = core.obscript and core.obscript.combat
if combat == nil then
    return {}
end

-- The weapon the player starts with in New Vegas content until they pick another one
local DEFAULT_WEAPON = 'WeapNVVarmintRifle'

local hudColor = util.color.rgb(1.0, 0.71, 0.26)

local weapon = nil -- record table from combat.getWeapon
local drawn = false
local clip = 0
local cooldown = 0
local reloading = 0
local triggerHeld = false
local firedThisPress = false
local chosen = nil -- record id the player picked, saved with the game

local hud = nil
local notice = nil
local noticeTime = 0

local function hudText()
    if weapon == nil then return '' end
    local text = weapon.name .. '  ' .. clip .. '/' .. weapon.clipSize
    if reloading > 0 then
        text = text .. '  (reloading)'
    elseif not drawn then
        text = text .. '  (holstered)'
    end
    if notice then
        text = notice .. '\n' .. text
    end
    return text
end

local function updateHud()
    -- the FNV HUD (scripts/omw/fnvhud/player.lua) shows the ammo counter and the target's health
    if weapon == nil or I.FNVHud ~= nil then
        if hud then
            hud:destroy()
            hud = nil
        end
        return
    end
    if hud == nil then
        hud = ui.create {
            layer = 'HUD',
            type = ui.TYPE.Text,
            props = {
                relativePosition = util.vector2(1, 1),
                anchor = util.vector2(1, 1),
                position = util.vector2(-24, -64),
                textSize = 20,
                textColor = hudColor,
                textAlignH = ui.ALIGNMENT.End,
                multiline = true,
                autoSize = true,
                text = hudText(),
            },
        }
    else
        hud.layout.props.text = hudText()
        hud:update()
    end
end

local function showNotice(text)
    notice = text
    noticeTime = 2.5
    updateHud()
end

-- The global script mirrors this into storage.globalSection('FNVPlayerWeapon') for object
-- scripts (IsWeaponOut, GetWeaponAnimType, GetEquipped on the player).
local function publishWeapon()
    core.sendGlobalEvent('FNVCombat_PlayerWeapon', {
        weapon = weapon and weapon.id or nil,
        editorId = weapon and weapon.editorId or nil,
        animType = weapon and weapon.animType or 0,
        drawn = weapon ~= nil and drawn,
    })
end

local function equip(id)
    local record = combat.getWeapon(id)
    if record == nil then
        print('[fnvcombat] no weapon ' .. tostring(id))
        return false
    end
    weapon = record
    chosen = record.id
    clip = math.max(1, record.clipSize or 1)
    cooldown = 0
    reloading = 0
    drawn = true
    I.Controls.overrideCombatControls(true)
    types.Actor.setStance(self, types.Actor.STANCE.Nothing)
    updateHud()
    publishWeapon()
    return true
end

local function unequip()
    weapon = nil
    chosen = nil
    drawn = false
    I.Controls.overrideCombatControls(false)
    updateHud()
    publishWeapon()
end

local function reload()
    if weapon == nil or reloading > 0 or clip >= weapon.clipSize then return end
    reloading = math.max(0.5, weapon.reloadTime or 1)
    updateHud()
end

local function fire()
    if cooldown > 0 or reloading > 0 then return end
    if weapon.clipSize > 0 and clip <= 0 then
        if weapon.dryFireSound ~= '' then
            core.sound.playSound3d(weapon.dryFireSound, self)
        end
        reload()
        return
    end
    local origin = camera.getPosition()
    local direction = camera.viewportToWorldVector(util.vector2(0.5, 0.5))
    core.sendGlobalEvent('FNVCombat_Fire', {
        attacker = self.object,
        weapon = weapon.id,
        origin = origin,
        direction = direction,
    })
    if weapon.clipSize > 0 then
        clip = clip - math.max(1, weapon.ammoUse or 1)
    end
    local rate = weapon.shotsPerSecond or 0
    cooldown = rate > 0 and 1 / rate or 0.5
    updateHud()
end

input.registerTriggerHandler('ToggleWeapon', async:callback(function()
    if weapon == nil or core.isWorldPaused() then return end
    drawn = not drawn
    updateHud()
    publishWeapon()
end))

input.registerActionHandler('Use', async:callback(function(value)
    triggerHeld = value
    if not value then firedThisPress = false end
end))

return {
    interfaceName = 'FNVCombat',
    ---
    -- @module FNVCombat
    -- @context player
    interface = {
        version = 0,
        --- Equip an FNV weapon by record id or editor id; returns false if there is no such weapon.
        equip = equip,
        unequip = unequip,
        --- The equipped weapon record (see core.obscript.combat.getWeapon), or nil.
        getWeapon = function() return weapon end,
        isDrawn = function() return weapon ~= nil and drawn end,
        --- Rounds left in the clip.
        getClip = function() return clip end,
        isReloading = function() return reloading > 0 end,
    },
    engineHandlers = {
        onInit = function()
            if core.contentFiles.has('falloutnv.esm') then
                equip(DEFAULT_WEAPON)
            end
        end,
        onSave = function()
            return { weapon = chosen, clip = clip }
        end,
        onLoad = function(data)
            if data and data.weapon and equip(data.weapon) then
                clip = math.min(data.clip or clip, weapon.clipSize)
                updateHud()
            elseif data == nil and core.contentFiles.has('falloutnv.esm') then
                equip(DEFAULT_WEAPON)
            end
        end,
        onKeyPress = function(key)
            if key.code == input.KEY.R and weapon ~= nil and drawn and not core.isWorldPaused() then
                reload()
            end
        end,
        onFrame = function(dt)
            -- this script's onInit/onLoad run before the HUD's script is loaded
            if hud ~= nil and I.FNVHud ~= nil then updateHud() end
            if weapon == nil or core.isWorldPaused() then return end
            if types.Actor.getStance(self) ~= types.Actor.STANCE.Nothing then
                types.Actor.setStance(self, types.Actor.STANCE.Nothing)
            end
            if noticeTime > 0 then
                noticeTime = noticeTime - dt
                if noticeTime <= 0 then
                    notice = nil
                    updateHud()
                end
            end
            if cooldown > 0 then cooldown = math.max(0, cooldown - dt) end
            if reloading > 0 then
                reloading = reloading - dt
                if reloading <= 0 then
                    reloading = 0
                    clip = weapon.clipSize
                    updateHud()
                end
            end
            if drawn and triggerHeld and I.UI.getMode() == nil and (weapon.automatic or not firedThisPress) then
                if cooldown <= 0 and reloading <= 0 then
                    firedThisPress = true
                    fire()
                end
            end
        end,
    },
    eventHandlers = {
        -- `player.EquipItem <weapon>` from a script (Doc Mitchell, Sunny Smiles)
        FNVEquipItem = function(e)
            if combat.getWeapon(e.item) then equip(e.item) end
        end,
        FNVCombat_ShotResult = function(e)
            if e.target == nil then return end
            if e.killed then
                showNotice(e.name .. ' killed')
            else
                showNotice(string.format('%s  -%d  (%d/%d)', e.name, math.floor(e.damage + 0.5),
                    math.max(0, math.floor(e.health + 0.5)), math.floor(e.maxHealth + 0.5)))
            end
        end,
    },
}
