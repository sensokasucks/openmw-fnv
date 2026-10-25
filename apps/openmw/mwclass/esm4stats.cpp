#include "esm4stats.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <map>

#include <components/esm3/loadnpc.hpp>
#include <components/esm4/loadclas.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"

#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/creaturestats.hpp"

#include "../mwworld/class.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/livecellref.hpp"
#include "../mwworld/ptr.hpp"

#include "esm4creature.hpp"
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

        bool isPlayerTagSkill(int av);

        float gmst(std::string_view name)
        {
            return MWWorld::ESM4GameSettings::getFloat(name);
        }

        // The game setting with each skill's (Barter..Unarmed) starting value.
        constexpr std::array<std::string_view, 14> sSkillBaseSettings = {
            "fAVDSkillBarterBase",
            "fAVDSkillBigGunsBase",
            "fAVDSkillEnergyWeaponsBase",
            "fAVDSkillExplosivesBase",
            "fAVDSkillLockpickBase",
            "fAVDSkillMedicineBase",
            "fAVDSkillMeleeWeaponsBase",
            "fAVDSkillRepairBase",
            "fAVDSkillScienceBase",
            "fAVDSkillSmallGunsBase",
            "fAVDSkillSneakBase",
            "fAVDSkillSpeechBase",
            "fAVDSkillSurvivalBase",
            "fAVDSkillUnarmedBase",
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
            float mPoints = 0; // added to the base: skill points spent at level up
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

        // The class of an AutoCalcStats NPC, which its SPECIAL and skills come from; nullptr otherwise.
        const ESM4::Class* autoCalcClass(const MWWorld::Ptr& actor, const ESM4::Npc* record)
        {
            if (isPlayer(actor) || record == nullptr || !record->mIsFONV
                || !(record->mBaseConfig.fo3.flags & ESM4::Npc::FO3_AutoCalcStats))
                return nullptr;
            const ESM4::Npc* traits = ESM4Npc::getTraitsRecord(actor);
            if (traits == nullptr || traits->mClass.isZeroOrUnset())
                return nullptr;
            const ESM4::Class* cls = MWBase::Environment::get().getESMStore()->get<ESM4::Class>().search(traits->mClass);
            return cls != nullptr && cls->mHasFO3Data ? cls : nullptr;
        }

        bool isTagSkill(const ESM4::Class& cls, int av)
        {
            return std::find(std::begin(cls.mTagSkills), std::end(cls.mTagSkills), av) != std::end(cls.mTagSkills);
        }

        // Skills of an AutoCalcStats NPC (CalcNPCAutoStatsSkills 0x603be0): each starts from its initial value;
        // the class's tag skills get fAVDTagSkillBonus plus the level-up points (10 + Int/2 per level after the
        // first) shared between them, what a tag skill can't take above 100 going to the next one.
        float autoCalcSkill(const MWWorld::Ptr& actor, const ESM4::Class& cls, int av)
        {
            int tags = 0;
            for (std::int32_t tag : cls.mTagSkills)
                if (tag >= Barter && tag <= Unarmed)
                    ++tags;
            const int pointsPerLevel = static_cast<int>(10 + 0.5f * getPermanent(actor, Intelligence));
            const int points = (getLevel(actor) - 1) * pointsPerLevel;
            const float perTag = tags > 0
                ? std::floor(static_cast<float>(points) / tags) * MWWorld::ESM4GameSettings::getInt("iSkillPointsTagSkillMult")
                : 0.f;
            const float luck = getPermanent(actor, Luck);
            float overflow = 0;
            int tagsLeft = tags - 1;
            for (int skill = Barter; skill <= Unarmed; ++skill)
            {
                const int index = skill - Barter;
                float value = gmst(sSkillBaseSettings[index])
                    + gmst("fAVDSkillPrimaryBonusMult") * getPermanent(actor, sGoverningAttribute[index])
                    + std::ceil(gmst("fAVDSkillLuckBonusMult") * luck);
                if (isTagSkill(cls, skill))
                {
                    value += gmst("fAVDTagSkillBonus") + perTag + overflow;
                    overflow = 0;
                    if (value > 100 && tagsLeft != 0)
                        overflow = (value - 100) / tagsLeft;
                    --tagsLeft;
                }
                if (skill == av)
                    return std::min(value, 100.f);
            }
            return 0;
        }

        // FO3/FONV creatures: health and SPECIAL come straight from DATA; the combat skill stands for every weapon
        // skill and the stealth skill for Sneak.
        float creatureBase(const MWWorld::Ptr& actor, int av)
        {
            if ((av >= Aggression && av <= Mood) || av == Assistance)
            {
                const ESM4::Creature* aiRecord = ESM4Creature::getAIDataRecord(actor);
                if (aiRecord == nullptr || !aiRecord->mHasFO3AIData)
                    return 0;
                const ESM4::Creature::AIDataFO3& ai = aiRecord->mFO3AIData;
                switch (av)
                {
                    case Aggression:
                        return ai.aggression;
                    case Confidence:
                        return ai.confidence;
                    case Energy:
                        return ai.energy;
                    case Responsibility:
                        return ai.responsibility;
                    case Mood:
                        return ai.mood;
                    default:
                        return ai.assistance;
                }
            }
            const ESM4::Creature* record = ESM4Creature::getStatsRecord(actor);
            if (record == nullptr || !record->mHasFO3Data)
                return 0;
            const ESM4::Creature::DataFO3& data = record->mFO3Data;
            if (av >= Strength && av <= Luck)
                return data.special[av - Strength];
            switch (av)
            {
                case BigGuns:
                case EnergyWeapons:
                case Explosives:
                case MeleeWeapons:
                case Guns:
                case Unarmed:
                    return data.combat;
                case Sneak:
                    return data.stealth;
                case Health:
                    return data.health;
                case ActionPoints:
                    return record->mBaseConfig.fo3.fatigue;
                case SpeedMult:
                    return record->mBaseConfig.fo3.speedMultiplier;
                case MeleeDamage:
                    return data.damage;
                case CritChance:
                    return data.special[Luck - Strength];
                default:
                    return 0;
            }
        }

        float recordBase(const MWWorld::Ptr& actor, int av)
        {
            // Limbs start healthy
            if (av >= PerceptionCondition && av <= BrainCondition)
                return gmst("fAVDDefaultBodyPartCondition");
            if (actor.getType() == ESM::REC_CREA4)
                return creatureBase(actor, av);
            const ESM4::Npc* record = statsRecord(actor);
            const bool player = isPlayer(actor);

            const ESM4::Class* cls = autoCalcClass(actor, record);
            if (av >= Strength && av <= Luck)
            {
                if (cls != nullptr)
                    return std::min<float>(cls->mSpecial[av - Strength], 10);
                if (record != nullptr && record->mFO3Stats.hasSpecial)
                    return record->mFO3Stats.special[av - Strength];
                return 5;
            }
            if (av >= Barter && av <= Unarmed)
            {
                const int skill = av - Barter;
                if (cls != nullptr)
                    return autoCalcSkill(actor, *cls, av);
                // The player's skills follow their SPECIAL, which character creation changes.
                if (!player && record != nullptr && record->mFO3Stats.hasSkills)
                    return record->mFO3Stats.skills[skill];
                const float attribute = getPermanent(actor, sGoverningAttribute[skill]);
                const float luck = getPermanent(actor, Luck);
                float value = gmst(sSkillBaseSettings[skill]) + gmst("fAVDSkillPrimaryBonusMult") * attribute
                    + std::ceil(gmst("fAVDSkillLuckBonusMult") * luck);
                if (player && isPlayerTagSkill(av))
                    value += gmst("fAVDTagSkillBonus");
                return value;
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
                    return gmst("fAVDActionPointsBase") + gmst("fAVDActionPointsMult") * getPermanent(actor, Agility);
                case CarryWeight:
                    return gmst("fAVDCarryWeightsBase") + gmst("fAVDCarryWeightMult") * getPermanent(actor, Strength);
                case CritChance:
                    return gmst("fAVDCritLuckBase") + gmst("fAVDCritLuckMult") * getPermanent(actor, Luck);
                case MeleeDamage:
                    return std::max(0.f,
                        std::floor(gmst("fAVDMeleeDamageStrengthMult")
                            * (getPermanent(actor, Strength) + gmst("fAVDMeleeDamageStrengthOffset"))));
                case PoisonResist:
                    return gmst("fAVDPoisonResistEnduranceMult")
                        * (getPermanent(actor, Endurance) + gmst("fAVDPoisonResistEnduranceOffset"));
                case RadResist:
                    return gmst("fAVDRadResistEnduranceMult")
                        * (getPermanent(actor, Endurance) + gmst("fAVDRadResistEnduranceOffset"));
                case HealRate: // 0x643a70
                {
                    const int endurance = static_cast<int>(std::lround(getPermanent(actor, Endurance)));
                    if (endurance < 6)
                        return 0;
                    static constexpr std::string_view bonuses[] = { "fAVDHealRateEndurance6Bonus",
                        "fAVDHealRateEndurance7Bonus", "fAVDHealRateEndurance8Bonus", "fAVDHealRateEndurance9Bonus",
                        "fAVDHealRateEndurance10Bonus" };
                    return gmst(bonuses[std::min(endurance, 10) - 6]);
                }
                case UnarmedDamage: // 0x643ed0
                    return gmst("fAVDUnarmedDamageBase") + gmst("fAVDUnarmedDamageMult") * getPermanent(actor, Unarmed);
                case Health:
                {
                    // DATA health plus the Endurance bonus (0x6436c0). Only the player and AutoCalcStats NPCs
                    // (0x603fc0) get a level term.
                    const float endurance = getPermanent(actor, Endurance);
                    const int level = getLevel(actor);
                    const float base = record != nullptr ? record->mFO3Stats.baseHealth : (player ? 100 : 0);
                    if (player)
                        return base
                            + gmst("fAVDHealthEnduranceMult") * (endurance + gmst("fAVDHealthEnduranceOffset"))
                            + gmst("fAVDHealthLevelMult") * (level - 1);
                    float bonus
                        = gmst("fAVDNPCHealthEnduranceMult") * (endurance + gmst("fAVDNPCHealthEnduranceOffset"));
                    if (record != nullptr && record->mIsFONV
                        && (record->mBaseConfig.fo3.flags & ESM4::Npc::FO3_AutoCalcStats))
                        bonus = std::max(0.f, std::trunc(bonus + gmst("fAVDNPCHealthLevelMult") * (level - 1)));
                    return base + bonus;
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

        // The player's tag skills, chosen in character creation (saved by scripts/omw/fnvstats.lua).
        std::vector<int> sPlayerTagSkills;

        Delta& deltaFor(const MWWorld::Ptr& actor, int av)
        {
            return sChanges[keyOf(actor)][av];
        }

        bool valid(int av)
        {
            return av >= 0 && av < Count;
        }

        bool isPlayerTagSkill(int av)
        {
            return std::find(sPlayerTagSkills.begin(), sPlayerTagSkills.end(), av) != sPlayerTagSkills.end();
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
        return !actor.isEmpty()
            && (isPlayer(actor) || actor.getType() == ESM::REC_NPC_4 || actor.getType() == ESM::REC_CREA4);
    }

    float getBase(const MWWorld::Ptr& actor, int av)
    {
        if (!valid(av) || !hasActorValues(actor))
            return 0;
        const Delta* delta = findDelta(actor, av);
        if (delta == nullptr)
            return recordBase(actor, av);
        return (delta->mBase ? *delta->mBase : recordBase(actor, av)) + delta->mPoints;
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
        {
            Delta& delta = deltaFor(actor, av);
            delta.mBase = value;
            delta.mPoints = 0;
        }
    }

    void addBasePoints(const MWWorld::Ptr& actor, int av, float points)
    {
        if (valid(av) && hasActorValues(actor))
            deltaFor(actor, av).mPoints += points;
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
                if (delta.mBase || delta.mPoints != 0 || delta.mModifier != 0 || delta.mDamage != 0)
                    res.push_back(Change{ actor, av, delta.mBase, delta.mPoints, delta.mModifier, delta.mDamage });
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
            delta.mPoints = change.mPoints;
            delta.mModifier = change.mModifier;
            delta.mDamage = change.mDamage;
        }
    }

    std::vector<int> getPlayerTagSkills()
    {
        return sPlayerTagSkills;
    }

    void setPlayerTagSkills(const std::vector<int>& skills)
    {
        sPlayerTagSkills.clear();
        for (int av : skills)
            if (av >= Barter && av <= Unarmed && !isPlayerTagSkill(av))
                sPlayerTagSkills.push_back(av);
    }
}
