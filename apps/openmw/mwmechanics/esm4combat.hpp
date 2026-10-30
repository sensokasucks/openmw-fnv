#ifndef GAME_MWMECHANICS_ESM4COMBAT_H
#define GAME_MWMECHANICS_ESM4COMBAT_H

#include <functional>
#include <optional>
#include <vector>

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
    // A placed corpse (CellRef::startsDead) that still has its health is put to death on the spot, with no
    // sequence or ragdoll (the animation then poses it). Called as the actor is first shown. True when it is dead.
    bool ensureStartsDead(const MWWorld::Ptr& actor);

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
        bool mCorpse = false; // the target was already dead: no health is taken, its limbs can still come off
        bool mExplosion = false; // the hit is an explosion's blast
        bool mKnockedDown = false; // the hit knocked the target off its feet (MWMechanics::ESM4Physical)
        bool mBlocked = false; // the target blocked a melee blow (less damage, BlockHit played)
    };

    // Damages the target's health; kills it when health runs out. Returns the health taken. With a result, the
    // hit rolls for a knockdown (ESM4Physical::rollKnockdown) along the result's direction, and a killing blow
    // leaves its impulse (fDeathForce*, ranged for shots and blasts) on the body for the ragdoll.
    float hit(const MWWorld::Ptr& target, const MWWorld::Ptr& attacker, float damage, HitResult* result = nullptr,
        bool ranged = false);
    // Drops the attacker's melee blows still in the air (it was knocked down).
    void cancelAttacks(const MWWorld::Ptr& attacker);

    // Called when a melee weapon, unarmed or creature blow lands: attacker, weapon (nullptr unarmed), result.
    using BlowListener = std::function<void(const MWWorld::Ptr&, const ESM4::Weapon*, const HitResult&)>;
    void setBlowListener(BlowListener listener);

    // Thrown grenades and launcher shells (weapons whose projectile explodes and is not hitscan): lobbers fly an arc
    // under gravity and bounce until their timer runs out, or go off where they land without one; missiles fly
    // straight and go off where they hit. The explosion hurts the FO3/FONV actors and the player within its
    // radius that it can reach; each one hurt is reported to the blow listener. False if the weapon has no such
    // projectile.
    bool isExplosiveProjectile(const ESM4::Weapon& weapon);
    // Where the weapon's explosion still does fDangerousProjectileExplosionDamage 5: R x sqrt(1 - 5/D); 0 when it
    // is not dangerous (FalloutNV.exe 0x992720).
    float getBlastDangerRadius(const ESM4::Weapon& weapon);
    // How far a grenade can be thrown (v^2/g) or a shell fired; 0 for other weapons.
    float getThrowRange(const ESM4::Weapon& weapon);
    bool launch(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, const osg::Vec3f& origin,
        const osg::Vec3f& targetPosition);
    // An NPC throws or fires its grenade or launcher at the target (attack sequence and sound, then launch).
    // at: where to aim instead of the target's position (a hiding target's last-seen position)
    bool launchAt(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, std::optional<osg::Vec3f> at = {});
    // The nearest grenade or shell that threatens the position (within its dangerous radius plus radius), if any.
    std::optional<osg::Vec3f> findProjectileNear(const osg::Vec3f& position, float radius);

    // Cover from a target (FalloutNV.exe cover search, ghidra-findings-4 §1): navmesh cover edges are tried
    // nearest first along the navmesh within searchRadius of the actor; the first one passing the checks wins:
    // its cover point is out of the target's sight, it lies minDistance..maxDistance from the target, no grenade
    // threatens it, the target is not within 256 of it, and (when needFire) the step-out point past one of its
    // open ends sees the target. Edges whose keys are in excluded (reserved or recently failed) are skipped.
    struct Cover
    {
        osg::Vec3f mCoverPoint;
        osg::Vec3f mFirePoint;
        std::uint64_t mKey = 0;
    };
    std::optional<Cover> findCover(const MWWorld::Ptr& actor, const MWWorld::Ptr& target,
        const osg::Vec3f& targetPosition, float searchRadius, float minDistance, float maxDistance, bool needFire,
        const std::vector<std::uint64_t>& excluded);
    // Whether the target could see the point at the actor's head height: crouched if the actor has a crouch
    // loop (see setCrouched), else standing.
    bool canTargetSee(const MWWorld::Ptr& actor, const MWWorld::Ptr& target, const osg::Vec3f& point);

    // Crouches behind cover (the sneak idle with the drawn weapon) or stands up again. False when the actor has no
    // crouch loop. A crouched actor's shots start lower.
    bool setCrouched(const MWWorld::Ptr& actor, bool crouched);

    // Raises the actor's melee weapon or fists (BlockIdle) or lowers them again: a blocking actor takes less from a
    // melee blow (see update). False when the actor has no block loop (then it does not block).
    bool setBlocking(const MWWorld::Ptr& actor, bool blocking);
    bool isBlocking(const MWWorld::Ptr& actor);

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

    // The combat planner's weapon types (FalloutNV.exe): 0 explosive (launchers), 1 ranged, 2 melee, 3 grenade,
    // 4 mine, 6 hand to hand.
    int getWeaponType(const ESM4::Weapon& weapon);

    // Every weapon an FO3/FONV NPC carries, and putting one in its hands.
    const std::vector<const ESM4::Weapon*>& getActorWeapons(const MWWorld::Ptr& actor);
    void equipWeapon(const MWWorld::Ptr& actor, const ESM4::Weapon* weapon);

    // Takes the actor's weapon in hand and aims it (true), or puts it away.
    void drawWeapon(const MWWorld::Ptr& actor, bool drawn);

    // The actor fires its gun at the target: the weapon's attack sequence and sound, and one shot whose aim wanders
    // more the worse the actor's weapon skill is. False if it can't shoot now.
    bool shoot(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, HitResult& result);

    // Whether nothing solid stands between the attacker's eyes and the target's upper body.
    bool hasLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target);

    // The ray hasLineOfFire casts and what stops it (for diagnostics).
    struct LineOfFire
    {
        osg::Vec3f mFrom, mTo, mHitPosition;
        bool mHit = false;
        MWWorld::Ptr mHitObject; // empty for terrain, or when nothing was hit
    };
    LineOfFire getLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target);

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

    // Lays the actor down and stops it moving. impulse: direction x force of the killing blow, for the body,
    // hitPosition where it landed.
    void kill(const MWWorld::Ptr& actor, bool instant = false, const osg::Vec3f& impulse = osg::Vec3f(),
        const std::optional<osg::Vec3f>& hitPosition = std::nullopt);

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
