#include "obscriptstatsbindings.hpp"

#include <algorithm>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <variant>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm3/loadbody.hpp>
#include <components/esm3/loadnpc.hpp>
#include <components/esm4/loadperk.hpp>
#include <components/esm4/loadrepu.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/livecellref.hpp"
#include "../mwworld/ptr.hpp"

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

        void requireGlobal(const Context& context, std::string_view name)
        {
            if (context.mType != Context::Global)
                throw std::runtime_error(std::string(name) + " is only available in global scripts");
        }

        // The player's head or hair for their race and the given sex: the current one if it fits, else the first
        // playable one; the current one when the race has none.
        ESM::RefId playerBodyPart(const ESM::NPC& player, ESM::BodyPart::MeshPart part, bool female)
        {
            const ESM::RefId& current = part == ESM::BodyPart::MP_Head ? player.mHead : player.mHair;
            const MWWorld::Store<ESM::BodyPart>& parts = MWBase::Environment::get().getESMStore()->get<ESM::BodyPart>();
            const auto fits = [&](const ESM::BodyPart& bp) {
                return bp.mRace == player.mRace && bp.mData.mPart == part && bp.mData.mType == ESM::BodyPart::MT_Skin
                    && !bp.mData.mVampire && !(bp.mData.mFlags & ESM::BodyPart::BPF_NotPlayable)
                    && ((bp.mData.mFlags & ESM::BodyPart::BPF_Female) != 0) == female;
            };
            if (const ESM::BodyPart* bp = parts.search(current); bp != nullptr && fits(*bp))
                return current;
            for (const ESM::BodyPart& bp : parts)
                if (fits(bp))
                    return bp.mId;
            return current;
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

        // The player's tag skills, as actor value numbers.
        api["getTagSkills"] = [](sol::this_state s) {
            sol::table res(s, sol::create);
            for (int av : Stats::getPlayerTagSkills())
                res.add(av);
            return res;
        };
        // Replaces the player's tag skills with a list of actor value names or numbers.
        api["_setTagSkills"] = [](const sol::table& list) {
            std::vector<int> skills;
            for (const auto& [_, value] : list)
                if (std::optional<int> av = findActorValue(value))
                    skills.push_back(*av);
            Stats::setPlayerTagSkills(skills);
        };

        // A FNV game setting (GMST): the loaded files' value, else FalloutNV.exe's; nil if unknown.
        api["gameSetting"] = [](sol::this_state s, std::string_view name) -> sol::object {
            const ESM4::GameSetting::Data* data = MWWorld::ESM4GameSettings::find(name);
            if (data == nullptr)
                return sol::nil;
            return std::visit(
                [&](const auto& value) -> sol::object {
                    if constexpr (std::is_same_v<std::decay_t<decltype(value)>, std::monostate>)
                        return sol::nil;
                    else
                        return sol::make_object(s, value);
                },
                *data);
        };

        // Character creation: the player's name and sex. Global scripts only; applied after the Lua frame.
        api["_setPlayerName"] = [context](std::string_view name) {
            requireGlobal(context, "_setPlayerName");
            context.mLuaManager->addAction(
                [name = std::string(name)] { MWBase::Environment::get().getMechanicsManager()->setPlayerName(name); },
                "setPlayerName");
        };
        api["_setPlayerSex"] = [context](bool female) {
            requireGlobal(context, "_setPlayerSex");
            context.mLuaManager->addAction(
                [female] {
                    MWBase::World* world = MWBase::Environment::get().getWorld();
                    ESM::NPC player = *world->getPlayerPtr().get<ESM::NPC>()->mBase;
                    if (player.isMale() == !female)
                        return;
                    player.setIsMale(!female);
                    player.mHead = playerBodyPart(player, ESM::BodyPart::MP_Head, female);
                    player.mHair = playerBodyPart(player, ESM::BodyPart::MP_Hair, female);
                    world->getStore().insert(player);
                    world->renderPlayer();
                },
                "setPlayerSex");
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
