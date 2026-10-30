#ifndef GAME_MWCLASS_ESM4STATS_H
#define GAME_MWCLASS_ESM4STATS_H

#include <optional>
#include <string_view>
#include <vector>

#include <components/esm/formid.hpp>

namespace MWWorld
{
    class Ptr;
}

namespace MWClass::ESM4Stats
{
    // FO3/FNV actor values, numbered as in the game (the codes compiled scripts and CTDA conditions use).
    enum ActorValue : int
    {
        Aggression = 0,
        Confidence = 1,
        Energy = 2,
        Responsibility = 3,
        Mood = 4,
        Strength = 5,
        Perception = 6,
        Endurance = 7,
        Charisma = 8,
        Intelligence = 9,
        Agility = 10,
        Luck = 11,
        ActionPoints = 12,
        CarryWeight = 13,
        CritChance = 14,
        HealRate = 15,
        Health = 16,
        MeleeDamage = 17,
        DamageResist = 18,
        PoisonResist = 19,
        RadResist = 20,
        SpeedMult = 21,
        Fatigue = 22,
        Karma = 23,
        XP = 24,
        PerceptionCondition = 25,
        EnduranceCondition = 26,
        LeftAttackCondition = 27,
        RightAttackCondition = 28,
        LeftMobilityCondition = 29,
        RightMobilityCondition = 30,
        BrainCondition = 31,
        Barter = 32,
        BigGuns = 33,
        EnergyWeapons = 34,
        Explosives = 35,
        Lockpick = 36,
        Medicine = 37,
        MeleeWeapons = 38,
        Repair = 39,
        Science = 40,
        Guns = 41,
        Sneak = 42,
        Speech = 43,
        Survival = 44,
        Unarmed = 45,
        UnarmedDamage = 56,
        Assistance = 57,
        IgnoreCrippledLimbs = 72,
        DamageThreshold = 76,
        Count = 77,
    };

    // Actor value by name ("Lockpick", "Strength", case-insensitive) or by its number as text.
    std::optional<int> findActorValue(std::string_view name);
    std::string_view actorValueName(int av);

    // The player and FO3/FNV NPCs have actor values; everything else reads as 0.
    bool hasActorValues(const MWWorld::Ptr& actor);

    // Base value: from the actor's record (the player uses FNV's "Player" NPC record), or what SetAV set.
    // Skills without a stored value and derived values (action points, carry weight, ...) follow the
    // game's formulas from the actor's SPECIAL.
    float getBase(const MWWorld::Ptr& actor, int av);
    // Base plus ModAV changes.
    float getPermanent(const MWWorld::Ptr& actor, int av);
    // Permanent value minus DamageAV damage.
    float getCurrent(const MWWorld::Ptr& actor, int av);

    void setBase(const MWWorld::Ptr& actor, int av, float value); // SetAV, ForceAV
    void addBasePoints(const MWWorld::Ptr& actor, int av, float points); // skill points spent at level up
    void modify(const MWWorld::Ptr& actor, int av, float delta); // ModAV
    void damage(const MWWorld::Ptr& actor, int av, float amount); // DamageAV (negative restores)

    int getLevel(const MWWorld::Ptr& actor);
    bool isFemale(const MWWorld::Ptr& actor);

    // Changes made during play, saved by the Lua script scripts/omw/fnvstats.lua.
    struct Change
    {
        ESM::FormId mActor; // unset for the player
        int mValue;
        std::optional<float> mBase;
        float mPoints = 0;
        float mModifier = 0;
        float mDamage = 0;
    };
    std::vector<Change> getChanges();
    void setChanges(const std::vector<Change>& changes);

    // The player's tag skills (Barter..Unarmed), which get fAVDTagSkillBonus; set by character creation and saved
    // by scripts/omw/fnvstats.lua.
    std::vector<int> getPlayerTagSkills();
    void setPlayerTagSkills(const std::vector<int>& skills);
}

#endif // GAME_MWCLASS_ESM4STATS_H
