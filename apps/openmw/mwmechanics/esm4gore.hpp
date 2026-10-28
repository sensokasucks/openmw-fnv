#ifndef GAME_MWMECHANICS_ESM4GORE_H
#define GAME_MWMECHANICS_ESM4GORE_H

#include <cstdint>
#include <vector>

#include <osg/Vec3f>

#include "../mwworld/ptr.hpp"

namespace ESM4
{
    struct BodyPartData;
    struct Weapon;
}

namespace MWMechanics::ESM4Gore
{
    // FO3/FONV limbs and dismemberment, following FalloutNV.exe (Actor dismemberment, FUN_008b43a0 and around).
    // Limbs are the body parts of the actor's body part data (BPTD), numbered by ESM4::BodyPartData::PartType;
    // each has a condition actor value (PerceptionCondition for the head ... RightMobilityCondition).
    //
    // Dismembering is an event: rollDismemberment decides on the authority (the global script), and dismember
    // replays the result anywhere, so a multiplayer host can decide once and send the outcome (limb, explode,
    // direction, seed) to the others, which see the same pieces fly.

    using LimbMask = std::uint32_t;
    constexpr LimbMask limbBit(int limb)
    {
        return limb >= 0 && limb < 32 ? LimbMask(1) << limb : 0;
    }

    // The body part data the actor uses: a creature's own (CREA PNAM, from its model template), the player's
    // PlayerBodyPartData and DefaultBodyPartData for NPCs, as the game does.
    const ESM4::BodyPartData* getBodyPartData(const MWWorld::Ptr& actor);

    // The limb a shot along the ray hits: the body part whose bones (BPNN to BPNT, carried on past the target as
    // far again) pass closest to it. -1 if the actor has no body part data or isn't drawn.
    int getHitLimb(const MWWorld::Ptr& actor, const osg::Vec3f& origin, const osg::Vec3f& direction);

    // Health damage multiplier of a limb (BPND, a head takes double).
    float getDamageMult(const MWWorld::Ptr& actor, int limb);

    // Takes the limb's condition down by the damage: the limb has its health percentage of the actor's full health,
    // and the weapon's limb damage multiplier applies.
    void damageLimb(const MWWorld::Ptr& actor, int limb, float damage, float weaponLimbMult);

    struct Dismemberment
    {
        int mLimb;
        bool mExplode;
    };

    struct KillingBlow
    {
        int mLimb = -1; // the limb the blow hit
        const ESM4::Weapon* mWeapon = nullptr; // its "On Hit" setting can rule out severing or exploding
        bool mBloodyMess = false; // the killer has the Bloody Mess perk
        bool mExplosion = false; // an explosion's blast: every crippled limb may go
        std::uint32_t mSeed = 0;
    };

    // Whether shots and blasts still land on the actor: alive, or a corpse with a body left to take apart.
    bool canTakeHits(const MWWorld::Ptr& actor);

    // An explosion's blast takes every limb's condition down by its damage.
    void damageAllLimbs(const MWWorld::Ptr& actor, float damage);

    // What the blow that killed the actor tears off: the hit limb if it was crippled (or it always explodes),
    // severed (iCombatDismemberPartChance) or exploded (its BPND explode chance x iCombatExplodePartChance). Bloody
    // Mess adds the other limbs (iMess* settings) and may blow the torso, and so the whole body, apart.
    std::vector<Dismemberment> rollDismemberment(const MWWorld::Ptr& actor, const KillingBlow& blow);

    // Severs or explodes a limb: hides it on the body, shows the caps, and sends the limb flying or bursts it into
    // gore, blood and debris (the seed picks the debris and its flight, direction pushes the pieces away).
    void dismember(const MWWorld::Ptr& actor, int limb, bool explode, const osg::Vec3f& direction, std::uint32_t seed);

    // Limbs the actor has lost, and the ones of them that exploded. Saved by scripts/omw/fnvgore; setting them
    // again (a loaded game) shows the body without them and plays no effects.
    LimbMask getLostLimbs(const MWWorld::Ptr& actor);
    LimbMask getExplodedLimbs(const MWWorld::Ptr& actor);
    void setLostLimbs(const MWWorld::Ptr& actor, LimbMask lost, LimbMask exploded);
    void clear();
}

#endif
