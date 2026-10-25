#include "obscripteffectbindings.hpp"

#include <map>
#include <string>
#include <string_view>
#include <vector>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/effect.hpp>
#include <components/esm4/loadalch.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadench.hpp>
#include <components/esm4/loadmgef.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadscpt.hpp>
#include <components/esm4/loadspel.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/lower.hpp>

#include "../mwbase/environment.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/store.hpp"

#include "context.hpp"
#include "object.hpp"
#include "obscriptdialoguebindings.hpp"

namespace MWLua
{
    namespace
    {
        std::string formIdText(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return {};
            return ESM::RefId(id).serializeText();
        }

        // A record by serialized form id ("FormId:0x...") or editor id (any case).
        template <class T>
        const T* findRecord(std::string_view idOrEditorId)
        {
            const MWWorld::Store<T>& store = MWBase::Environment::get().getESMStore()->template get<T>();
            ESM::RefId refId = ESM::RefId::deserializeText(idOrEditorId);
            if (refId.is<ESM::FormId>())
                if (const T* record = store.search(refId))
                    return record;
            static const std::map<std::string, const T*> byEditorId = [&store] {
                std::map<std::string, const T*> res;
                for (size_t i = 0; i < store.getSize(); ++i)
                {
                    const T* record = store.at(i);
                    if (!record->mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(record->mEditorId), record);
                }
                return res;
            }();
            auto it = byEditorId.find(Misc::StringUtils::lowerCase(idOrEditorId));
            return it == byEditorId.end() ? nullptr : it->second;
        }

        template <class T>
        const T* searchFormId(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return nullptr;
            return MWBase::Environment::get().getESMStore()->template get<T>().search(ESM::RefId(id));
        }

        sol::table makeEffects(sol::state_view& lua, const std::vector<ESM4::EffectItem>& effects)
        {
            sol::table res(lua, sol::create);
            for (size_t i = 0; i < effects.size(); ++i)
            {
                const ESM4::EffectItem& item = effects[i];
                sol::table e(lua, sol::create);
                e["effect"] = formIdText(item.mEffect);
                e["magnitude"] = item.mMagnitude;
                e["area"] = item.mArea;
                e["duration"] = item.mDuration;
                e["range"] = item.mRange;
                e["actorValue"] = item.mActorValue;
                e["conditions"] = makeObScriptConditions(lua, item.mConditions);
                res[LuaUtil::toLuaIndex(i)] = e;
            }
            return res;
        }

        sol::object makeMagicEffect(sol::state_view& lua, const ESM4::MagicEffect* effect)
        {
            if (effect == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["id"] = formIdText(effect->mId);
            res["editorId"] = effect->mEditorId;
            res["name"] = effect->mFullName;
            res["description"] = effect->mDescription;
            res["icon"] = effect->mIcon;
            res["flags"] = effect->mData.flags;
            res["archetype"] = effect->mData.archetype;
            res["actorValue"] = effect->mData.actorValue;
            res["resistValue"] = effect->mData.resistValue;
            res["baseCost"] = effect->mData.baseCost;
            res["associatedItem"] = formIdText(effect->mAssociatedItem);
            // the SCPT of a Script effect
            if (const ESM4::Script* script = searchFormId<ESM4::Script>(effect->mAssociatedItem))
            {
                res["script"] = formIdText(script->mId);
                res["scriptEditorId"] = script->mEditorId;
            }
            sol::table counters(lua, sol::create);
            for (size_t i = 0; i < effect->mCounterEffects.size(); ++i)
                counters[LuaUtil::toLuaIndex(i)] = formIdText(effect->mCounterEffects[i]);
            res["counterEffects"] = counters;
            return res;
        }

        sol::object makeSpell(sol::state_view& lua, const ESM4::Spell* spell)
        {
            if (spell == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["id"] = formIdText(spell->mId);
            res["editorId"] = spell->mEditorId;
            res["name"] = spell->mFullName;
            res["type"] = spell->mData.type;
            res["cost"] = spell->mData.cost;
            res["level"] = spell->mData.level;
            res["flags"] = spell->mData.flags;
            res["effects"] = makeEffects(lua, spell->mEffects);
            return res;
        }

        sol::object makeEnchantment(sol::state_view& lua, const ESM4::Enchantment* ench)
        {
            if (ench == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["id"] = formIdText(ench->mId);
            res["editorId"] = ench->mEditorId;
            res["name"] = ench->mFullName;
            res["type"] = ench->mData.type;
            res["flags"] = ench->mData.flags;
            res["effects"] = makeEffects(lua, ench->mEffects);
            return res;
        }

        sol::object makePotion(sol::state_view& lua, const ESM4::Potion* potion)
        {
            if (potion == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["id"] = formIdText(potion->mId);
            res["editorId"] = potion->mEditorId;
            res["name"] = potion->mFullName;
            res["flags"] = potion->mItem.flags & 0xFF;
            res["value"] = potion->mItem.value;
            res["addiction"] = formIdText(ESM::FormId::fromUint32(potion->mItem.withdrawl));
            res["addictionChance"] = potion->mItem.chanceAddition;
            res["consumeSound"] = formIdText(ESM::FormId::fromUint32(potion->mItem.sound));
            res["effects"] = makeEffects(lua, potion->mEffects);
            return res;
        }
    }

    sol::table initObScriptEffectBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Each takes a form id ("FormId:0x...", e.g. an object's recordId) or an editor id; nil if not found.
        // Effect lists are { effect (MGEF id), magnitude, area, duration, range, actorValue, conditions }.

        // MGEF: { id, editorId, name, description, icon, flags, archetype, actorValue, resistValue,
        //         baseCost, associatedItem, script, scriptEditorId (Script effects), counterEffects }
        api["getMagicEffect"] = [](std::string_view id, sol::this_state s) {
            sol::state_view lua(s);
            return makeMagicEffect(lua, findRecord<ESM4::MagicEffect>(id));
        };
        // SPEL: { id, editorId, name, type, cost, level, flags, effects }
        api["getSpell"] = [](std::string_view id, sol::this_state s) {
            sol::state_view lua(s);
            return makeSpell(lua, findRecord<ESM4::Spell>(id));
        };
        // ENCH: { id, editorId, name, type, flags, effects }
        api["getEnchantment"] = [](std::string_view id, sol::this_state s) {
            sol::state_view lua(s);
            return makeEnchantment(lua, findRecord<ESM4::Enchantment>(id));
        };
        // ALCH: { id, editorId, name, flags (1 no auto-calc, 2 food, 4 medicine), value,
        //         addiction (SPEL id), addictionChance, consumeSound (SOUN id, for core.sound), effects }
        api["getPotion"] = [](std::string_view id, sol::this_state s) {
            sol::state_view lua(s);
            return makePotion(lua, findRecord<ESM4::Potion>(id));
        };
        // Actor effects (SPLO) of an ESM4 NPC or creature record: list of SPEL ids.
        api["getActorSpells"] = [](const Object& actor, sol::this_state s) {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Ptr& ptr = actor.ptr();
            const std::vector<ESM::FormId>* spells = nullptr;
            if (ptr.getType() == ESM::REC_NPC_4)
                spells = &ptr.get<ESM4::Npc>()->mBase->mSpell;
            else if (ptr.getType() == ESM::REC_CREA4)
                spells = &ptr.get<ESM4::Creature>()->mBase->mSpell;
            if (spells != nullptr)
            {
                size_t n = 0;
                for (ESM::FormId id : *spells)
                    if (searchFormId<ESM4::Spell>(id) != nullptr)
                        res[LuaUtil::toLuaIndex(n++)] = formIdText(id);
            }
            return res;
        };

        return LuaUtil::makeReadOnly(api);
    }
}
