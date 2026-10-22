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
        osg::Vec3f mPosition; // where the shot ended
        float mDamage = 0.f; // health taken
        bool mKilled = false;
    };

    // Damages the target's health; kills it when health runs out. Returns the health taken.
    float hit(const MWWorld::Ptr& target, const MWWorld::Ptr& attacker, float damage);

    // Fires one shot of a gun along a ray: the first FO3/FONV actor in front of any wall takes the weapon's damage.
    HitResult fire(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, const osg::Vec3f& origin,
        const osg::Vec3f& direction);

    // Lays the actor down and stops it moving.
    void kill(const MWWorld::Ptr& actor, bool instant = false);
}

#endif
