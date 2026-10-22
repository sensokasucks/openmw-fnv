#include "esm4stats.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <map>

#include <components/esm3/loadnpc.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"

#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/creaturestats.hpp"

#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/livecellref.hpp"
#include "../mwworld/ptr.hpp"

#include "esm4npc.hpp"

namespace MWClass::ESM4Stats
{
    namespace
    {
        constexpr std::array<std::string_view, Count> sNames = {
            "Aggression",
            "Confidence",
            "Energy",
            "Responsibility",
            "Mood",
            "Strength",
            "Perception",
            "Endurance",
            "Charisma",
            "Intelligence",
            "Agility",
            "Luck",
            "ActionPoints",
            "CarryWeight",
            "CritChance",
            "HealRate",
            "Health",
            "MeleeDamage",
            "DamageResist",
            "PoisonResist",
            "RadResist",
            "SpeedMult",
            "Fatigue",
            "Karma",
            "XP",
            "PerceptionCondition",
            "EnduranceCondition",
            "LeftAttackCondition",
            "RightAttackCondition",
            "LeftMobilityCondition",
            "RightMobilityCondition",
            "BrainCondition",
            "Barter",
            "BigGuns",
            "EnergyWeapons",
            "Explosives",
            "Lockpick",
            "Medicine",
            "MeleeWeapons",
            "Repair",
            "Science",
            "Guns",
            "Sneak",
            "Speech",
            "Survival",
            "Unarmed",
            "InventoryWeight",
            "Paralysis",
            "Invisibility",
            "Chameleon",
            "NightEye",
            "Turbo",
            "FireResist",
            "WaterBreathing",
            "RadiationRads",
            "BloodyMess",
            "UnarmedDamage",
            "Assistance",
            "ElectricResist",
            "FrostResist",
            "EnergyResist",
            "EmpResist",
            "Variable01",
            "Variable02",
            "Variable03",
            "Variable04",
            "Variable05",
            "Variable06",
            "Variable07",
            "Variable08",
            "Variable09",
            "Variable10",
            "IgnoreCrippledLimbs",
            "Dehydration",
            "Hunger",
            "SleepDeprivation",
            "DamageThreshold",
        };

        // The SPECIAL stat each skill (Barter..Unarmed) starts from.
        constexpr std::array<int, 14> sGoverningAttribute = {
            Charisma, // Barter
            Endurance, // Big Guns
            Perception, // Energy Weapons
            Perception, // Explosives
            Perception, // Lockpick
            Intelligence, // Medicine
            Strength, // Melee Weapons
            Intelligence, // Repair
            Intelligence, // Science
            Agility, // Guns
            Agility, // Sneak
            Charisma, // Speech
            Endurance, // Survival
            Endurance, // Unarmed
        };

        struct Delta
        {
            std::optional<float> mBase;
            float mModifier = 0;
            float mDamage = 0;
        };

        std::map<ESM::FormId, std::map<int, Delta>> sChanges;

        bool isPlayer(const MWWorld::Ptr& actor)
        {
            return actor == MWMechanics::getPlayer();
        }

        ESM::FormId keyOf(const MWWorld::Ptr& actor)
        {
            if (isPlayer(actor))
                return ESM::FormId{};
            return actor.getCellRef().getRefNum();
        }

        const Delta* findDelta(const MWWorld::Ptr& actor, int av)
        {
            auto it = sChanges.find(keyOf(actor));
            if (it == sChanges.end())
                return nullptr;
            auto valueIt = it->second.find(av);
            return valueIt == it->second.end() ? nullptr : &valueIt->second;
        }

        // FNV's own player record ("Player", 0x7) holds the starting SPECIAL.
        const ESM4::Npc* fnvPlayerRecord()
        {
            static const MWWorld::ESMStore* cachedStore = nullptr;
            static const ESM4::Npc* cached = nullptr;
            const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();
            if (store != cachedStore)
            {
                cachedStore = store;
                cached = nullptr;
                for (const ESM4::Npc& npc : store->get<ESM4::Npc>())
                {
                    if (npc.mIsFONV && npc.mId.mIndex == 0x7 && Misc::StringUtils::ciEqual(npc.mEditorId, "Player"))
                    {
                        cached = &npc;
                        break;
                    }
                }
            }
            return cached;
        }

        // The record that holds an NPC's stats, following "use stats" templates.
        const ESM4::Npc* statsRecord(const MWWorld::Ptr& actor)
        {
            if (isPlayer(actor))
                return fnvPlayerRecord();
            if (actor.getType() != ESM::REC_NPC_4)
                return nullptr;
            return ESM4Npc::getStatsRecord(actor);
        }

        float recordBase(const MWWorld::Ptr& actor, int av)
        {
            const ESM4::Npc* record = statsRecord(actor);
            const bool player = isPlayer(actor);

            if (av >= Strength && av <= Luck)
            {
                if (record != nullptr && record->mFO3Stats.hasSpecial)
                    return record->mFO3Stats.special[av - Strength];
                return 5;
            }
            if (av >= Barter && av <= Unarmed)
            {
                const int skill = av - Barter;
                // The player's skills follow their SPECIAL, which character creation changes.
                if (!player && record != nullptr && record->mFO3Stats.hasSkills)
                    return record->mFO3Stats.skills[skill];
                const float attribute = getPermanent(actor, sGoverningAttribute[skill]);
                const float luck = getPermanent(actor, Luck);
                return 2 + 2 * attribute + std::ceil(luck / 2);
            }

            switch (av)
            {
                case Aggression:
                case Confidence:
                case Energy:
                case Responsibility:
                case Mood:
                    if (record != nullptr && record->mFO3Stats.hasAIValues)
                        return record->mFO3Stats.aiValues[av - Aggression];
                    return 0;
                case Assistance:
                    return record != nullptr ? record->mFO3Stats.assistance : 0;
                case ActionPoints:
                    return 65 + 3 * getPermanent(actor, Agility);
                case CarryWeight:
                    return 150 + 10 * getPermanent(actor, Strength);
                case CritChance:
                    return getPermanent(actor, Luck);
                case MeleeDamage:
                    return getPermanent(actor, Strength) / 2;
                case PoisonResist:
                    return (getPermanent(actor, Endurance) - 1) * 5;
                case RadResist:
                    return (getPermanent(actor, Endurance) - 1) * 2;
                case Health:
                {
                    const float endurance = getPermanent(actor, Endurance);
                    const int level = getLevel(actor);
                    if (player)
                        return 100 + 20 * endurance + 5 * (level - 1);
                    const float base = record != nullptr ? record->mFO3Stats.baseHealth : 0;
                    return base + 5 * endurance + 10 * level;
                }
                case SpeedMult:
                    if (!player && record != nullptr && record->mIsFONV)
                        return record->mBaseConfig.fo3.speedMultiplier;
                    return 100;
                case Fatigue:
                    if (record != nullptr && record->mIsFONV)
                        return record->mBaseConfig.fo3.fatigue;
                    return 0;
                case Karma:
                    if (!player && record != nullptr && record->mIsFONV)
                        return record->mBaseConfig.fo3.karma;
                    return 0;
                default:
                    return 0;
            }
        }

        Delta& deltaFor(const MWWorld::Ptr& actor, int av)
        {
            return sChanges[keyOf(actor)][av];
        }

        bool valid(int av)
        {
            return av >= 0 && av < Count;
        }
    }

    std::optional<int> findActorValue(std::string_view name)
    {
        int number = 0;
        const auto [end, error] = std::from_chars(name.data(), name.data() + name.size(), number);
        if (error == std::errc() && end == name.data() + name.size())
            return valid(number) ? std::optional<int>(number) : std::nullopt;
        for (int i = 0; i < Count; ++i)
            if (Misc::StringUtils::ciEqual(sNames[i], name))
                return i;
        // Older names some scripts still use
        if (Misc::StringUtils::ciEqual(name, "SmallGuns"))
            return Guns;
        if (Misc::StringUtils::ciEqual(name, "Throwing"))
            return Survival;
        return std::nullopt;
    }

    std::string_view actorValueName(int av)
    {
        return valid(av) ? sNames[av] : std::string_view{};
    }

    bool hasActorValues(const MWWorld::Ptr& actor)
    {
        return !actor.isEmpty() && (isPlayer(actor) || actor.getType() == ESM::REC_NPC_4);
    }

    float getBase(const MWWorld::Ptr& actor, int av)
    {
        if (!valid(av) || !hasActorValues(actor))
            return 0;
        if (const Delta* delta = findDelta(actor, av); delta != nullptr && delta->mBase)
            return *delta->mBase;
        return recordBase(actor, av);
    }

    float getPermanent(const MWWorld::Ptr& actor, int av)
    {
        const Delta* delta = valid(av) && hasActorValues(actor) ? findDelta(actor, av) : nullptr;
        return getBase(actor, av) + (delta != nullptr ? delta->mModifier : 0);
    }

    float getCurrent(const MWWorld::Ptr& actor, int av)
    {
        const Delta* delta = valid(av) && hasActorValues(actor) ? findDelta(actor, av) : nullptr;
        return getPermanent(actor, av) - (delta != nullptr ? delta->mDamage : 0);
    }

    void setBase(const MWWorld::Ptr& actor, int av, float value)
    {
        if (valid(av) && hasActorValues(actor))
            deltaFor(actor, av).mBase = value;
    }

    void modify(const MWWorld::Ptr& actor, int av, float delta)
    {
        if (valid(av) && hasActorValues(actor))
            deltaFor(actor, av).mModifier += delta;
    }

    void damage(const MWWorld::Ptr& actor, int av, float amount)
    {
        if (valid(av) && hasActorValues(actor))
        {
            Delta& delta = deltaFor(actor, av);
            delta.mDamage = std::max(0.f, delta.mDamage + amount);
        }
    }

    int getLevel(const MWWorld::Ptr& actor)
    {
        if (actor.isEmpty())
            return 0;
        if (isPlayer(actor))
            return actor.getClass().getCreatureStats(actor).getLevel();
        const ESM4::Npc* record = statsRecord(actor);
        if (record == nullptr || !record->mIsFONV)
            return 1;
        const ESM4::ACBS_FO3& config = record->mBaseConfig.fo3;
        if (!(config.flags & ESM4::Npc::FO3_PCLevelMult))
            return std::max<int>(1, config.levelOrMult);
        const MWWorld::Ptr player = MWMechanics::getPlayer();
        int level = static_cast<int>(std::lround(getLevel(player) * config.levelOrMult / 1000.0));
        level = std::max<int>(level, config.calcMinlevel);
        if (config.calcMaxlevel > 0)
            level = std::min<int>(level, config.calcMaxlevel);
        return std::max(1, level);
    }

    bool isFemale(const MWWorld::Ptr& actor)
    {
        if (actor.isEmpty())
            return false;
        if (actor.getType() == ESM::REC_NPC_)
            return !actor.get<ESM::NPC>()->mBase->isMale();
        if (actor.getType() == ESM::REC_NPC_4)
            return ESM4Npc::isFemale(actor);
        return false;
    }

    std::vector<Change> getChanges()
    {
        std::vector<Change> res;
        for (const auto& [actor, values] : sChanges)
            for (const auto& [av, delta] : values)
                if (delta.mBase || delta.mModifier != 0 || delta.mDamage != 0)
                    res.push_back(Change{ actor, av, delta.mBase, delta.mModifier, delta.mDamage });
        return res;
    }

    void setChanges(const std::vector<Change>& changes)
    {
        sChanges.clear();
        for (const Change& change : changes)
        {
            if (!valid(change.mValue))
                continue;
            Delta& delta = sChanges[change.mActor][change.mValue];
            delta.mBase = change.mBase;
            delta.mModifier = change.mModifier;
            delta.mDamage = change.mDamage;
        }
    }
}
