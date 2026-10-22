#include "obscriptstatsbindings.hpp"

#include <optional>
#include <stdexcept>
#include <string>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/lua/luastate.hpp>

#include "../mwclass/esm4stats.hpp"

#include "context.hpp"
#include "object.hpp"

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
        api["_modify"] = [](const Object& actor, const sol::object& av, float delta) {
            Stats::modify(actor.ptr(), actorValue(av), delta);
        };
        api["_damage"] = [](const Object& actor, const sol::object& av, float amount) {
            Stats::damage(actor.ptr(), actorValue(av), amount);
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
                change.mModifier = t.get_or("modifier", 0.f);
                change.mDamage = t.get_or("damage", 0.f);
                changes.push_back(change);
            }
            Stats::setChanges(changes);
        };

        return LuaUtil::makeReadOnly(api);
    }
}
