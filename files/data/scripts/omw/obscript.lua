-- Global-context handler for world mutations requested by transpiled
-- ObScript local scripts (see openmw_aux/obscript/bindings.lua).

local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local I = require('openmw.interfaces')

local function resolveRef(editorId, what)
    local formId = core.obscript.resolveRefEditorId(editorId)
    if formId == nil then
        print('[obscript] ' .. what .. ': unknown reference editor id: ' .. tostring(editorId))
        return nil
    end
    local obj = world.getObjectByFormId(formId)
    if obj == nil or not obj:isValid() then
        print('[obscript] ' .. what .. ': no valid object for ' .. tostring(editorId)
            .. ' (' .. tostring(formId) .. ')')
        return nil
    end
    return obj
end

local suppressed = {}  -- object id -> true once default activation is blocked

local function suppressDefaultActivation(obj)
    if suppressed[obj.id] then return end
    suppressed[obj.id] = true
    I.Activation.addHandlerForObject(obj, function() return false end)
end

local function activate(obj, actor, runOnActivateBlock)
    if obj == nil or actor == nil then return end
    if runOnActivateBlock then
        obj:activateBy(actor)
    else
        I.Activation.runDefaultActivation(obj, actor)
    end
end

return {
    eventHandlers = {
        ObScriptHasOnActivate = function(data)
            suppressDefaultActivation(data.object)
        end,
        ObScriptActivate = function(data)
            activate(data.object, data.actor, data.runOnActivateBlock)
        end,
        ObScriptActivateByRef = function(data)
            activate(resolveRef(data.editorId, 'Activate'), data.actor, data.runOnActivateBlock)
        end,
        ObScriptPlayGroupByRef = function(data)
            local obj = resolveRef(data.editorId, 'PlayGroup')
            if obj then
                core.obscript.playEmbeddedGroup(obj, data.group)
            end
        end,
        ObScriptSetOpenStateByRef = function(data)
            local obj = resolveRef(data.editorId, 'SetOpenState')
            if obj then
                core.obscript.setOpenState(obj, data.open)
            end
        end,
        ObScriptSetEnabled = function(data)
            data.object.enabled = data.enabled
        end,
        ObScriptSetEnabledByRef = function(data)
            local obj = resolveRef(data.editorId, 'SetEnabled')
            if obj then
                obj.enabled = data.enabled
            end
        end,
        ObScriptAddItem = function(data)
            local recordId = core.obscript.resolveItemEditorId(data.item)
            if recordId == nil then
                print('[obscript] AddItem: unknown item editor id: ' .. tostring(data.item))
                return
            end
            local count = math.max(1, math.floor(tonumber(data.count) or 1))
            local obj = world.createObject(recordId, count)
            local ok = pcall(function()
                obj:moveInto(types.Actor.inventory(world.players[1]))
            end)
            if not ok then
                -- ESM4 inventory support is not implemented yet; drop the item
                -- and record the limitation instead of erroring.
                obj:remove()
                print('[obscript] AddItem: engine cannot add this item type to inventories yet: '
                    .. tostring(data.item))
            end
        end,
    },
}
