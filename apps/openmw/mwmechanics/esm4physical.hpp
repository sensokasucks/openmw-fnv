#ifndef GAME_MWMECHANICS_ESM4PHYSICAL_H
#define GAME_MWMECHANICS_ESM4PHYSICAL_H

#include <array>
#include <functional>
#include <optional>
#include <string_view>

#include <osg/Vec3f>

#include <components/esm4/loadbptd.hpp>

#include "../mwworld/ptr.hpp"

namespace MWMechanics::ESM4Physical
{
    // The physical state of an FO3/FONV actor: the one seam between physics and gore on one side and the AI and
    // its executor on the other (docs/fnv-plans/physics-gore.md in the TES3MP fork, "Schedule"). Physics, combat
    // and gore write it (knockdowns, death, crippled and severed limbs, bleeding); the AI (scripts/omw/fnvai,
    // fnvcombat) and ESM4Actors read it to pick what the actor can still do and how fast it moves.
    //
    // The original keeps a knock state byte on the actor process (+0x13C): 0 up, 1 unconscious, 2 down waiting
    // for the ragdoll to come to rest, 3 wants to get up, 4 just knocked down (ragdoll on, impulse pending),
    // 5 the get-up sequence playing. Posture maps onto it (getKnockState), so scripts and conditions
    // (GetKnockedState) read what vanilla reads.

    enum class Posture
    {
        Standing, // on its feet, free to act (walking, fighting, idling)
        Staggering, // on its feet but reeling from a hit: no attacks, movement goes on
        KnockedDown, // falling or lying after a knockdown; gets up on its own
        GettingUp, // the get-up sequence plays
        Unconscious, // lying until woken (a scripted knockout, a non-lethal takedown)
        Dead, // a corpse: the ragdoll or death pose
    };

    std::string_view postureName(Posture posture);

    // The original's knock state byte for the posture
    int getKnockState(Posture posture);

    enum class LimbState
    {
        Fine,
        Crippled, // its condition actor value is at 0
        Severed, // torn off (MWMechanics::ESM4Gore)
    };

    struct State
    {
        Posture mPosture = Posture::Standing;
        // Direction x force of the last knockdown or killing blow: the impulse the ragdoll gets (F3)
        osg::Vec3f mImpulse;
        float mBleed = 0.f; // bleeding level, 0 none (the opt-in bleed effects raise it)
        float mTimer = 0.f; // seconds left in the current phase (lying, getting up, staggering)
        bool mUnconscious = false; // the knockdown leaves the actor out until wakeUp
        bool mRagdoll = false; // the body is (or was) a ragdoll rather than a sequence
        bool mSettled = false; // the reference has been moved to where the body lies
    };

    // What the limbs leave the actor able to do; the executor picks the gait from it and the pathing uses the
    // speed. One crippled leg slows (fMoveOneCrippledLegSpeedMult), both cripple running
    // (fMoveTwoCrippledLegsSpeedMult, walk only); a severed leg takes the actor off its feet (only the modern
    // path can sever a living actor; vanilla severs at death).
    struct Mobility
    {
        float mSpeedMult = 1.f; // on the walk and run speed, from the legs
        bool mCanRun = true;
        bool mCanStand = true;
        bool mCanAct = true; // alive and on its feet (standing or staggering): moves, attacks, idles
        bool mCanAttack = true; // mCanAct and not staggering
        bool mLimping = false; // a leg crippled or gone
        int mCrippledLegs = 0;
        int mSeveredLegs = 0;
        bool mLeftArmUsable = true; // weapon arms: neither crippled nor gone
        bool mRightArmUsable = true;
    };

    const State& getState(const MWWorld::Ptr& actor);
    Posture getPosture(const MWWorld::Ptr& actor);
    bool canAct(const MWWorld::Ptr& actor);

    // Per body part (ESM4::BodyPartData::PartType), from the part's condition actor value and the limbs lost
    LimbState getLimbState(const MWWorld::Ptr& actor, int partType);
    std::array<LimbState, ESM4::BodyPartData::Part_Count> getLimbStates(const MWWorld::Ptr& actor);
    Mobility getMobility(const MWWorld::Ptr& actor);

    // The knockdown roll of a hit (FalloutNV.exe 0x00646400): never when the hit kills; always when the damage is
    // more than fKnockdownBaseHealthThreshold percent of the full health; else when it is more than
    // fKnockdownCurrentHealthThreshold percent of the health before the hit, with chance
    // (damage x fKnockdownDamageMult + fKnockdownDamageBase) / (Agility x 10 x fKnockdownAgilMult +
    // fKnockdownAgilBase), capped at fKnockdownChance. healthBefore: the target's health before the hit.
    bool rollKnockdown(const MWWorld::Ptr& target, float damage, float healthBefore, bool killed);

    // The impulse of a killing blow or knockdown: lerp(ForceMin, ForceMax, (damage - DamageMin) / (DamageMax -
    // DamageMin)) with the melee (fDeathForce*) or ranged (fDeathForceRanged*) settings.
    float getDeathForce(float damage, bool ranged);

    // Knocks the actor down: it drops as a ragdoll under the impulse of the blow (direction x force, in the
    // original's units; the fall sequence when the skeleton has no ragdoll or ragdolls are off), lies until the
    // body is at rest and gets up on its own, or stays down until wakeUp with unconscious. Any move, attack or
    // idle stops. hitPosition: where the blow landed, for the ragdoll. False for actors that can't be (dead, not
    // an FO3/FONV actor, already down).
    bool knockDown(const MWWorld::Ptr& actor, const osg::Vec3f& direction, float force, bool unconscious = false,
        const std::optional<osg::Vec3f>& hitPosition = std::nullopt);
    // Reels from a hit for a moment: no attacks until it is over (the modern brain's stumbles build on this).
    bool stagger(const MWWorld::Ptr& actor, float seconds);
    // An unconscious actor wants to get up.
    void wakeUp(const MWWorld::Ptr& actor);
    // Death: the posture is Dead and the body drops as a ragdoll under the blow's impulse (direction x force) when
    // it has one, which the caller learns from the return; otherwise it plays its death sequence. Called by
    // ESM4Combat::kill; instant for actors loaded dead.
    bool setDead(const MWWorld::Ptr& actor, const osg::Vec3f& impulse,
        const std::optional<osg::Vec3f>& hitPosition = std::nullopt, bool instant = false);
    // Force (the original's death force units) to the ragdoll impulse (kg x game units per second)
    float impulseScale();
    void setBleed(const MWWorld::Ptr& actor, float level);

    // Posture changes are reported (actor, previous, current) so the AI can re-plan after a get-up.
    using PostureListener = std::function<void(const MWWorld::Ptr&, Posture, Posture)>;
    void setPostureListener(PostureListener listener);

    void update(float duration, bool paused);
    void clear();
}

#endif
