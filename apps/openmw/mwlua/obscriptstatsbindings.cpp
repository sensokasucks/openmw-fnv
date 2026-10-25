#include "obscriptstatsbindings.hpp"

#include <algorithm>
#include <optional>
#include <stdexcept>
#include <string>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/loadperk.hpp>
#include <components/esm4/loadrepu.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>

#include "../mwbase/environment.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwmechanics/actorutil.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"

#include "context.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"
#include "obscriptdialoguebindings.hpp"

namespace MWLua
{
    namespace
    {
        namespace Stats = MWClass::ESM4Stats;

        std::optional<int> findActorValue(const sol::object& value)
        {
            if (value.is<double>())
            {
                const int av = static_cast<int>(value.as<double>());
                if (av >= 0 && av < Stats::Count)
                    return av;
                return std::nullopt;
            }
            if (value.is<std::string_view>())
                return Stats::findActorValue(value.as<std::string_view>());
            return std::nullopt;
        }

        int actorValue(const sol::object& value)
        {
            if (std::optional<int> av = findActorValue(value))
                return *av;
            throw std::runtime_error("Unknown actor value: " + LuaUtil::toString(value));
        }

        std::string formIdText(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return {};
            return ESM::RefId(id).serializeText();
        }
    }

    sol::table initObScriptStatsBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Actor value number for a name ("Lockpick") or number; nil if unknown.
        api["actorValue"] = [](const sol::object& nameOrIndex) -> sol::optional<int> {
            if (std::optional<int> av = findActorValue(nameOrIndex))
                return *av;
            return sol::nullopt;
        };
        api["actorValueName"] = [](int av) { return std::string(Stats::actorValueName(av)); };

        api["hasActorValues"] = [](const Object& actor) { return Stats::hasActorValues(actor.ptr()); };
        // GetActorValue: base + ModAV changes - damage.
        api["get"]
            = [](const Object& actor, const sol::object& av) { return Stats::getCurrent(actor.ptr(), actorValue(av)); };
        // GetBaseActorValue
        api["getBase"]
            = [](const Object& actor, const sol::object& av) { return Stats::getBase(actor.ptr(), actorValue(av)); };
        // GetPermanentActorValue
        api["getPermanent"] = [](const Object& actor, const sol::object& av) {
            return Stats::getPermanent(actor.ptr(), actorValue(av));
        };
        api["getLevel"] = [](const Object& actor) { return Stats::getLevel(actor.ptr()); };
        api["isFemale"] = [](const Object& actor) { return Stats::isFemale(actor.ptr()); };

        // Changing values is for global scripts (scripts/omw/fnvstats.lua); local ObScript sends it events.
        api["_setBase"] = [](const Object& actor, const sol::object& av, float value) {
            Stats::setBase(actor.ptr(), actorValue(av), value);
        };
        api["_addBasePoints"] = [](const Object& actor, const sol::object& av, float points) {
            Stats::addBasePoints(actor.ptr(), actorValue(av), points);
        };
        api["_modify"] = [](const Object& actor, const sol::object& av, float delta) {
            Stats::modify(actor.ptr(), actorValue(av), delta);
        };
        api["_damage"] = [](const Object& actor, const sol::object& av, float amount) {
            Stats::damage(actor.ptr(), actorValue(av), amount);
        };

        // The player's level (the engine level GetLevel reads); for the leveling in scripts/omw/fnvcharacter.lua.
        api["_setPlayerLevel"] = [context](int level) {
            context.mLuaManager->addAction(
                [level] {
                    const MWWorld::Ptr player = MWMechanics::getPlayer();
                    if (!player.isEmpty())
                        player.getClass().getCreatureStats(player).setLevel(std::max(1, level));
                },
                "obscriptSetPlayerLevelAction");
        };

        // FONV reputations (REPU): a list of { id, editorId, name, value }.
        api["reputations"] = [](sol::this_state s) {
            sol::state_view state(s);
            sol::table res(state, sol::create);
            const MWWorld::Store<ESM4::Reputation>& store
                = MWBase::Environment::get().getESMStore()->get<ESM4::Reputation>();
            for (size_t i = 0; i < store.getSize(); ++i)
            {
                const ESM4::Reputation& rep = *store.at(i);
                sol::table t(state, sol::create);
                t["id"] = formIdText(rep.mId);
                t["editorId"] = rep.mEditorId;
                t["name"] = rep.mFullName;
                t["value"] = rep.mValue;
                res[LuaUtil::toLuaIndex(i)] = t;
            }
            return res;
        };

        // FO3/FONV perks and traits (PERK): a list of { id, editorId, name, description, isTrait, minLevel,
        // ranks, playable, hidden, conditions (CTDA requirements, as core.obscript.dialogue builds them),
        // entries = { { type = 'quest'|'ability'|'entryPoint', rank, quest, stage, spell, entryPoint,
        // func, values } } }.
        api["perks"] = [](sol::this_state s) {
            sol::state_view state(s);
            sol::table res(state, sol::create);
            const MWWorld::Store<ESM4::Perk>& store = MWBase::Environment::get().getESMStore()->get<ESM4::Perk>();
            for (size_t i = 0; i < store.getSize(); ++i)
            {
                const ESM4::Perk& perk = *store.at(i);
                sol::table t(state, sol::create);
                t["id"] = formIdText(perk.mId);
                t["editorId"] = perk.mEditorId;
                t["name"] = perk.mFullName;
                t["description"] = perk.mDesc;
                t["isTrait"] = perk.mIsTrait;
                t["minLevel"] = perk.mMinLevel;
                t["ranks"] = std::max<int>(1, perk.mRanks);
                t["playable"] = perk.mPlayable;
                t["hidden"] = perk.mHidden;
                t["conditions"] = makeObScriptConditions(state, perk.mConditions);
                sol::table entries(state, sol::create);
                for (size_t j = 0; j < perk.mEntries.size(); ++j)
                {
                    const ESM4::Perk::Entry& entry = perk.mEntries[j];
                    sol::table e(state, sol::create);
                    e["rank"] = entry.mRank;
                    switch (entry.mType)
                    {
                        case ESM4::Perk::Entry_Quest:
                            e["type"] = "quest";
                            e["quest"] = formIdText(entry.mQuest);
                            e["stage"] = entry.mStage;
                            break;
                        case ESM4::Perk::Entry_Ability:
                            e["type"] = "ability";
                            e["spell"] = formIdText(entry.mSpell);
                            break;
                        default:
                            e["type"] = "entryPoint";
                            e["entryPoint"] = entry.mEntryPoint;
                            e["func"] = entry.mFunction;
                            e["values"] = state.create_table_with(1, entry.mValues[0], 2, entry.mValues[1]);
                            break;
                    }
                    entries[LuaUtil::toLuaIndex(j)] = e;
                }
                t["entries"] = entries;
                res[LuaUtil::toLuaIndex(i)] = t;
            }
            return res;
        };

        // Saved-game state: a list of { actor = 'player' or reference form id, av =, base =, modifier =, damage = }.
        api["_getChanges"] = [](sol::this_state s) {
            sol::state_view state(s);
            sol::table res(state, sol::create);
            for (const Stats::Change& change : Stats::getChanges())
            {
                sol::table t(state, sol::create);
                t["actor"] = change.mActor.isSet() ? ESM::RefId(change.mActor).serializeText() : std::string("player");
                t["av"] = change.mValue;
                if (change.mBase)
                    t["base"] = *change.mBase;
                if (change.mPoints != 0)
                    t["points"] = change.mPoints;
                t["modifier"] = change.mModifier;
                t["damage"] = change.mDamage;
                res.add(t);
            }
            return res;
        };
        api["_setChanges"] = [](const sol::table& list) {
            std::vector<Stats::Change> changes;
            for (const auto& [_, value] : list)
            {
                if (!value.is<sol::table>())
                    continue;
                const sol::table t = value.as<sol::table>();
                Stats::Change change;
                const std::string actor = t.get_or<std::string>("actor", "player");
                if (actor != "player")
                {
                    const ESM::RefId id = ESM::RefId::deserializeText(actor);
                    const ESM::FormId* formId = id.getIf<ESM::FormId>();
                    if (formId == nullptr)
                        continue;
                    change.mActor = *formId;
                }
                change.mValue = t.get_or("av", -1);
                if (sol::optional<float> base = t.get<sol::optional<float>>("base"))
                    change.mBase = *base;
                change.mPoints = t.get_or("points", 0.f);
                change.mModifier = t.get_or("modifier", 0.f);
                change.mDamage = t.get_or("damage", 0.f);
                changes.push_back(change);
            }
            Stats::setChanges(changes);
        };

        return LuaUtil::makeReadOnly(api);
    }
}
