#ifndef GAME_MWMECHANICS_ESM4COMBAT_H
#define GAME_MWMECHANICS_ESM4COMBAT_H

#include <osg/Vec3f>

#include "../mwworld/ptr.hpp"

namespace ESM4
{
    struct Weapon;
}

namespace MWMechanics::ESM4Combat
{
    // FO3/FONV combat: weapon damage, damage threshold/resistance and death, following the original engine.
    // Health and the other actor values live in MWClass::ESM4Stats.

    // Actors that take damage: the player, ESM4 NPCs and creatures.
    bool canBeHit(const MWWorld::Ptr& actor);
    bool isDead(const MWWorld::Ptr& actor);

    // Damage of one projectile of the weapon in the attacker's hands, before the target's armor: base damage scaled
    // by the attacker's weapon skill and the weapon's condition (0-1).
    float getWeaponDamage(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, float condition = 1.f);

    // Reduces damage by the target's damage resistance (percent, capped) and threshold, keeping at least a fraction
    // of it (fMinDamMultiplier).
    float applyArmor(const MWWorld::Ptr& target, float damage);

    struct HitResult
    {
        MWWorld::Ptr mTarget; // empty if nothing that can be hurt was hit
        MWWorld::Ptr mObject; // the world object that stopped the shot when no actor was hit (OnHitWith)
        osg::Vec3f mPosition; // where the shot ended
        osg::Vec3f mDirection; // of the shot
        float mDamage = 0.f; // health taken
        bool mKilled = false;
        int mLimb = -1; // body part hit (ESM4::BodyPartData::PartType), see ESM4Gore
    };

    // Damages the target's health; kills it when health runs out. Returns the health taken.
    float hit(const MWWorld::Ptr& target, const MWWorld::Ptr& attacker, float damage);

    // Fires one shot of a gun along a ray: the first FO3/FONV actor in front of any wall takes the weapon's damage.
    HitResult fire(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, const osg::Vec3f& origin,
        const osg::Vec3f& direction);

    // How the actor's factions (FACT relations, both ways) feel about the player's: FNV combat reactions.
    enum class Reaction
    {
        Neutral,
        Enemy,
        Ally,
        Friend,
    };
    Reaction getReactionToPlayer(const MWWorld::Ptr& actor);

    // The weapon an FO3/FONV NPC fights with (from its inventory), nullptr for creatures and the unarmed.
    const ESM4::Weapon* getActorWeapon(const MWWorld::Ptr& actor);
    bool isGun(const ESM4::Weapon& weapon);

    // Takes the actor's weapon in hand and aims it (true), or puts it away.
    void drawWeapon(const MWWorld::Ptr& actor, bool drawn);

    // The actor fires its gun at the target: the weapon's attack sequence and sound, and one shot whose aim wanders
    // more the worse the actor's weapon skill is. False if it can't shoot now.
    bool shoot(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, HitResult& result);

    // Whether nothing solid stands between the attacker's eyes and the target's upper body.
    bool hasLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target);

    // How well the observer detects the target (CalcDetectionScore, FalloutNV.exe 0x642ed0): sound and sight fall
    // off with distance (fSneakMaxDistance, doubled outdoors), sight needs a line of sight inside the observer's
    // view cone (fDetectionViewCone) and scales with the light, and the observer's Perception counts against the
    // target's Sneak skill while the target sneaks. Above fSneakNoticedMin the target is noticed, above
    // fSneakSeenMin seen. The light level is approximated: outdoors from the sun, indoors from the cell's ambient
    // and directional light.
    struct DetectionContext
    {
        bool mSleeping = false; // the observer is asleep
        bool mInCombat = false; // the observer is fighting
        bool mAlert = false; // the observer has its weapon out
    };
    struct Detection
    {
        float mScore = -100.f;
        bool mLineOfSight = false; // in the view cone with nothing in between
    };
    Detection detect(const MWWorld::Ptr& observer, const MWWorld::Ptr& target, const DetectionContext& context);

    // Plays the weapon's reload sequence; returns how long it takes (the weapon's reload time if longer).
    float reload(const MWWorld::Ptr& actor);

    // Lays the actor down and stops it moving.
    void kill(const MWWorld::Ptr& actor, bool instant = false);

    // Unarmed or creature attack (one of the actor's attack sequences). Partway through, the target takes the
    // attacker's damage if it is still within reach. False if the actor can't attack now.
    bool attack(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, float reach);

    // Damage of the attacker's unarmed or creature attack, before armor.
    float getUnarmedDamage(const MWWorld::Ptr& attacker);

    // Resolves attacks in progress.
    void update(float duration, bool paused);
    void clear();
}

#endif
