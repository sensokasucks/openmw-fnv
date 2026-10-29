#include "esm4physical.hpp"

#include <algorithm>
#include <map>
#include <random>

#include <components/debug/debuglog.hpp>
#include <components/esm3/refnum.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/cellref.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/worldmodel.hpp"

#include "esm4actors.hpp"
#include "esm4combat.hpp"
#include "esm4gore.hpp"

namespace MWMechanics::ESM4Physical
{
    namespace
    {
        namespace Stats = MWClass::ESM4Stats;
        using MWWorld::ESM4GameSettings::getFloat;

        // Without a ragdoll to come to rest, a knocked-down actor lies this long after its fall before getting up
        // (the original's knock state 2 waits for the ragdoll; fKnockDownTime:HIT 0.25 is only the delay before
        // the ragdoll takes over)
        constexpr float sLyingTime = 1.5f;
        // When the skeleton has no fall or get-up sequence the phases still take a moment
        constexpr float sDefaultFallTime = 0.8f;
        constexpr float sDefaultGetUpTime = 1.2f;
        // A ragdoll that hasn't settled in this long gets up anyway
        constexpr float sMaxRagdollWait = 10.f;
        // The original's force (fDeathForce*, 20..85) as the ragdoll's impulse: Havok N s to kg x game units per
        // second, with a body of around 10 kg per part this throws it a metre or two
        constexpr float sImpulsePerForce = 69.99125109f;
        // A non-lethal knockdown gets this much of the blow's death-force impulse
        constexpr float sKnockdownImpulseMult = 0.6f;

        std::map<ESM::RefNum, State> sStates;
        PostureListener sPostureListener;
        std::mt19937 sRandom{ std::random_device{}() };

        MWRender::ESM4NpcAnimation* getAnimation(const MWWorld::Ptr& ptr)
        {
            if (ptr.isEmpty())
                return nullptr;
            return dynamic_cast<MWRender::ESM4NpcAnimation*>(MWBase::Environment::get().getWorld()->getAnimation(ptr));
        }

        bool isActor(const MWWorld::Ptr& ptr)
        {
            return !ptr.isEmpty() && (ptr.getType() == ESM::REC_NPC_4 || ptr.getType() == ESM::REC_CREA4);
        }

        void setPosture(const MWWorld::Ptr& actor, State& state, Posture posture)
        {
            if (state.mPosture == posture)
                return;
            const Posture previous = state.mPosture;
            state.mPosture = posture;
            Log(Debug::Verbose) << "ESM4 physical: " << actor.getCellRef().getRefId() << " "
                                << postureName(previous) << " -> " << postureName(posture);
            if (sPostureListener)
                sPostureListener(actor, previous, posture);
        }

        // Moves the actor's reference to where its ragdoll lies (the pelvis, on the ground below it), facing the
        // way it did, and poses the frozen body from there again
        void settleAtBody(const MWWorld::Ptr& actor, MWRender::ESM4NpcAnimation& animation)
        {
            const std::optional<osg::Vec3f> pelvis = animation.getRagdollPosition();
            if (!pelvis)
                return;
            MWBase::World& world = *MWBase::Environment::get().getWorld();
            osg::Vec3f position = *pelvis;
            const MWPhysics::RayCastingResult ground = world.getRayCasting()->castRay(position,
                position - osg::Vec3f(0.f, 0.f, 256.f), MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap);
            position.z() = ground.mHit ? ground.mHitPos.z() : actor.getRefData().getPosition().asVec3().z();
            const MWWorld::Ptr moved = world.moveObject(actor, position);
            if (MWRender::ESM4NpcAnimation* movedAnimation = getAnimation(moved))
                movedAnimation->applyRagdollPose();
        }

        // The condition actor value a body part's state comes from
        int conditionOf(const MWWorld::Ptr& actor, int partType)
        {
            if (const ESM4::BodyPartData* data = ESM4Gore::getBodyPartData(actor))
                for (const auto& part : data->mBodyParts)
                    if (part.mData.partType == partType)
                        return part.mData.actorValue;
            // Without body part data: the vanilla layout
            switch (partType)
            {
                case ESM4::BodyPartData::Part_Head1:
                case ESM4::BodyPartData::Part_Head2:
                    return Stats::PerceptionCondition;
                case ESM4::BodyPartData::Part_Torso:
                    return Stats::EnduranceCondition;
                case ESM4::BodyPartData::Part_LeftArm1:
                case ESM4::BodyPartData::Part_LeftArm2:
                    return Stats::LeftAttackCondition;
                case ESM4::BodyPartData::Part_RightArm1:
                case ESM4::BodyPartData::Part_RightArm2:
                    return Stats::RightAttackCondition;
                case ESM4::BodyPartData::Part_LeftLeg1:
                case ESM4::BodyPartData::Part_LeftLeg2:
                case ESM4::BodyPartData::Part_LeftLeg3:
                    return Stats::LeftMobilityCondition;
                case ESM4::BodyPartData::Part_RightLeg1:
                case ESM4::BodyPartData::Part_RightLeg2:
                case ESM4::BodyPartData::Part_RightLeg3:
                    return Stats::RightMobilityCondition;
                case ESM4::BodyPartData::Part_Brain:
                    return Stats::BrainCondition;
                default:
                    return -1;
            }
        }

        // Whether any part with the condition is gone
        bool isSevered(ESM4Gore::LimbMask lost, const MWWorld::Ptr& actor, int condition)
        {
            if (lost == 0)
                return false;
            for (int part = 0; part < ESM4::BodyPartData::Part_Count; ++part)
                if ((lost & ESM4Gore::limbBit(part)) != 0 && conditionOf(actor, part) == condition)
                    return true;
            return false;
        }

        LimbState stateOf(const MWWorld::Ptr& actor, ESM4Gore::LimbMask lost, int condition)
        {
            if (condition < 0)
                return LimbState::Fine;
            if (isSevered(lost, actor, condition))
                return LimbState::Severed;
            if (Stats::hasActorValues(actor) && Stats::getCurrent(actor, Stats::IgnoreCrippledLimbs) == 0
                && Stats::getCurrent(actor, condition) < 1.f)
                return LimbState::Crippled;
            return LimbState::Fine;
        }
    }

    std::string_view postureName(Posture posture)
    {
        switch (posture)
        {
            case Posture::Standing:
                return "standing";
            case Posture::Staggering:
                return "staggering";
            case Posture::KnockedDown:
                return "knockedDown";
            case Posture::GettingUp:
                return "gettingUp";
            case Posture::Unconscious:
                return "unconscious";
            case Posture::Dead:
                return "dead";
        }
        return "standing";
    }

    int getKnockState(Posture posture)
    {
        switch (posture)
        {
            case Posture::Standing:
            case Posture::Staggering:
            case Posture::Dead:
                return 0;
            case Posture::KnockedDown:
                return 2;
            case Posture::GettingUp:
                return 5;
            case Posture::Unconscious:
                return 1;
        }
        return 0;
    }

    const State& getState(const MWWorld::Ptr& actor)
    {
        static const State sNone;
        static State sDead;
        if (!isActor(actor))
            return sNone;
        auto it = sStates.find(actor.getCellRef().getRefNum());
        if (it != sStates.end())
            return it->second;
        if (ESM4Combat::isDead(actor))
        {
            sDead.mPosture = Posture::Dead;
            return sDead;
        }
        return sNone;
    }

    Posture getPosture(const MWWorld::Ptr& actor)
    {
        return getState(actor).mPosture;
    }

    bool canAct(const MWWorld::Ptr& actor)
    {
        const Posture posture = getPosture(actor);
        return posture == Posture::Standing || posture == Posture::Staggering;
    }

    LimbState getLimbState(const MWWorld::Ptr& actor, int partType)
    {
        if (!isActor(actor))
            return LimbState::Fine;
        return stateOf(actor, ESM4Gore::getLostLimbs(actor), conditionOf(actor, partType));
    }

    std::array<LimbState, ESM4::BodyPartData::Part_Count> getLimbStates(const MWWorld::Ptr& actor)
    {
        std::array<LimbState, ESM4::BodyPartData::Part_Count> states;
        states.fill(LimbState::Fine);
        if (!isActor(actor))
            return states;
        const ESM4Gore::LimbMask lost = ESM4Gore::getLostLimbs(actor);
        for (int part = 0; part < ESM4::BodyPartData::Part_Count; ++part)
            states[part] = stateOf(actor, lost, conditionOf(actor, part));
        return states;
    }

    Mobility getMobility(const MWWorld::Ptr& actor)
    {
        Mobility mobility;
        if (!isActor(actor))
            return mobility;
        const Posture posture = getPosture(actor);
        mobility.mCanAct = posture == Posture::Standing || posture == Posture::Staggering;
        mobility.mCanAttack = posture == Posture::Standing;

        const ESM4Gore::LimbMask lost = ESM4Gore::getLostLimbs(actor);
        const LimbState leftLeg = stateOf(actor, lost, Stats::LeftMobilityCondition);
        const LimbState rightLeg = stateOf(actor, lost, Stats::RightMobilityCondition);
        for (LimbState leg : { leftLeg, rightLeg })
        {
            if (leg == LimbState::Crippled)
                ++mobility.mCrippledLegs;
            else if (leg == LimbState::Severed)
                ++mobility.mSeveredLegs;
        }
        mobility.mLimping = mobility.mCrippledLegs + mobility.mSeveredLegs > 0;
        // ComputeActorWalkSpeed (0x647d10): the leg multipliers
        if (mobility.mCrippledLegs + mobility.mSeveredLegs >= 2)
            mobility.mSpeedMult = getFloat("fMoveTwoCrippledLegsSpeedMult", 0.6f);
        else if (mobility.mLimping)
            mobility.mSpeedMult = getFloat("fMoveOneCrippledLegSpeedMult", 0.75f);
        // Both legs hurt: a limp, not a run. A leg gone: off its feet.
        mobility.mCanRun = mobility.mCrippledLegs + mobility.mSeveredLegs < 2;
        mobility.mCanStand = mobility.mSeveredLegs == 0;
        if (!mobility.mCanStand)
        {
            mobility.mCanAct = false;
            mobility.mCanAttack = false;
            mobility.mCanRun = false;
        }
        mobility.mLeftArmUsable = stateOf(actor, lost, Stats::LeftAttackCondition) == LimbState::Fine;
        mobility.mRightArmUsable = stateOf(actor, lost, Stats::RightAttackCondition) == LimbState::Fine;
        return mobility;
    }

    bool rollKnockdown(const MWWorld::Ptr& target, float damage, float healthBefore, bool killed)
    {
        if (killed || damage <= 0.f || !isActor(target) || !Stats::hasActorValues(target))
            return false;
        const float baseHealth = Stats::getPermanent(target, Stats::Health);
        if (baseHealth > 0.f && damage / baseHealth * 100.f > getFloat("fKnockdownBaseHealthThreshold", 75.f))
            return true;
        if (healthBefore <= 0.f || damage / healthBefore * 100.f <= getFloat("fKnockdownCurrentHealthThreshold", 25.f))
            return false;
        const float agility = Stats::getCurrent(target, Stats::Agility);
        const float denominator
            = agility * 10.f * getFloat("fKnockdownAgilMult", 1.f) + getFloat("fKnockdownAgilBase", 0.f);
        if (denominator <= 0.f)
            return false;
        float chance = (damage * getFloat("fKnockdownDamageMult", 0.3f) + getFloat("fKnockdownDamageBase", 0.f))
            / denominator;
        chance = std::min(chance, getFloat("fKnockdownChance", 0.25f));
        // rolled per mille
        std::uniform_int_distribution<int> roll(0, 999);
        return roll(sRandom) < static_cast<int>(chance * 1000.f);
    }

    float getDeathForce(float damage, bool ranged)
    {
        const float forceMin = getFloat(ranged ? "fDeathForceRangedForceMin" : "fDeathForceForceMin", ranged ? 20.f : 35.f);
        const float forceMax = getFloat(ranged ? "fDeathForceRangedForceMax" : "fDeathForceForceMax", ranged ? 40.f : 85.f);
        const float damageMin = getFloat(ranged ? "fDeathForceRangedDamageMin" : "fDeathForceDamageMin", ranged ? 0.1f : 0.f);
        const float damageMax = getFloat(ranged ? "fDeathForceRangedDamageMax" : "fDeathForceDamageMax", ranged ? 10.f : 50.f);
        float t = damageMax > damageMin ? (damage - damageMin) / (damageMax - damageMin) : 1.f;
        t = std::clamp(t, 0.f, 1.f);
        return forceMin + (forceMax - forceMin) * t;
    }

    float impulseScale()
    {
        return sImpulsePerForce;
    }

    bool knockDown(const MWWorld::Ptr& actor, const osg::Vec3f& direction, float force, bool unconscious,
        const std::optional<osg::Vec3f>& hitPosition)
    {
        if (!isActor(actor) || ESM4Combat::isDead(actor))
            return false;
        State& state = sStates[actor.getCellRef().getRefNum()];
        if (state.mPosture == Posture::KnockedDown || state.mPosture == Posture::Unconscious
            || state.mPosture == Posture::Dead)
            return false;
        osg::Vec3f dir = direction;
        if (dir.normalize() == 0.f)
            dir = osg::Vec3f(0.f, 0.f, 1.f);
        state.mImpulse = dir * force;
        state.mUnconscious = unconscious;

        ESM4Combat::cancelAttacks(actor);
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        // The ragdoll starts from the pose the actor is in right now, before anything resets its sequence (stop()
        // below would put the bones back in the bind pose, and the body would drop from a T-pose). A knockdown is
        // a shove, not a killing blow: the body goes over, it doesn't fly
        state.mRagdoll = animation != nullptr
            && animation->startRagdoll(state.mImpulse * sImpulsePerForce * sKnockdownImpulseMult, hitPosition);
        // Whatever it was doing stops: the move, the attack, the idle; a seated actor is knocked out of its seat
        // where it sits (the animation ignores locomotion changes while the body is down)
        ESM4Actors::get().stop(actor, true);
        MWBase::Environment::get().getWorld()->enableActorCollision(actor, false);
        if (state.mRagdoll)
            state.mTimer = sMaxRagdollWait;
        else
        {
            float fall = animation != nullptr ? animation->playKnockdown() : 0.f;
            if (fall <= 0.f)
                fall = sDefaultFallTime;
            state.mTimer = fall + sLyingTime;
        }
        setPosture(actor, state, unconscious ? Posture::Unconscious : Posture::KnockedDown);
        return true;
    }

    bool stagger(const MWWorld::Ptr& actor, float seconds)
    {
        if (!isActor(actor) || ESM4Combat::isDead(actor))
            return false;
        State& state = sStates[actor.getCellRef().getRefNum()];
        if (state.mPosture != Posture::Standing && state.mPosture != Posture::Staggering)
            return false;
        state.mTimer = std::max(state.mTimer, seconds);
        setPosture(actor, state, Posture::Staggering);
        return true;
    }

    void wakeUp(const MWWorld::Ptr& actor)
    {
        if (!isActor(actor))
            return;
        auto it = sStates.find(actor.getCellRef().getRefNum());
        if (it == sStates.end() || it->second.mPosture != Posture::Unconscious)
            return;
        it->second.mUnconscious = false;
        it->second.mTimer = std::min(it->second.mTimer, 0.5f);
    }

    bool setDead(const MWWorld::Ptr& actor, const osg::Vec3f& impulse, const std::optional<osg::Vec3f>& hitPosition,
        bool instant)
    {
        if (!isActor(actor))
            return false;
        State& state = sStates[actor.getCellRef().getRefNum()];
        state.mImpulse = impulse;
        state.mTimer = 0.f;
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        if (!instant && animation != nullptr)
        {
            // A body already falling as a ragdoll (killed while knocked down) just stays down
            if (animation->isRagdollActive())
                state.mRagdoll = true;
            else
                state.mRagdoll = animation->startRagdoll(impulse * sImpulsePerForce, hitPosition);
        }
        else
            state.mRagdoll = false;
        setPosture(actor, state, Posture::Dead);
        return state.mRagdoll;
    }

    void setBleed(const MWWorld::Ptr& actor, float level)
    {
        if (!isActor(actor))
            return;
        if (level <= 0.f)
        {
            auto it = sStates.find(actor.getCellRef().getRefNum());
            if (it != sStates.end())
                it->second.mBleed = 0.f;
            return;
        }
        sStates[actor.getCellRef().getRefNum()].mBleed = level;
    }

    void setPostureListener(PostureListener listener)
    {
        sPostureListener = std::move(listener);
    }

    void update(float duration, bool paused)
    {
        if (paused || duration <= 0.f || sStates.empty())
            return;
        MWWorld::WorldModel& worldModel = *MWBase::Environment::get().getWorldModel();
        for (auto it = sStates.begin(); it != sStates.end();)
        {
            const MWWorld::Ptr actor = worldModel.getPtr(it->first);
            State& state = it->second;
            if (actor.isEmpty() || actor.getRefData().getBaseNode() == nullptr)
            {
                // Out of the scene: a knockdown doesn't outlive it; a dead body stays dead through ESM4Combat
                it = sStates.erase(it);
                continue;
            }
            if (state.mPosture == Posture::Dead)
            {
                // A corpse that has come to rest is moved to where its body lies, so looting and distances work
                // on the body rather than where it stood
                if (state.mRagdoll && !state.mSettled)
                {
                    MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
                    if (animation != nullptr && animation->isRagdollAtRest())
                    {
                        settleAtBody(actor, *animation);
                        state.mSettled = true;
                    }
                }
                ++it;
                continue;
            }
            if (ESM4Combat::isDead(actor))
            {
                setPosture(actor, state, Posture::Dead);
                ++it;
                continue;
            }
            switch (state.mPosture)
            {
                case Posture::Staggering:
                    state.mTimer -= duration;
                    if (state.mTimer <= 0.f)
                    {
                        state.mTimer = 0.f;
                        setPosture(actor, state, Posture::Standing);
                    }
                    break;
                case Posture::KnockedDown:
                case Posture::Unconscious:
                {
                    state.mTimer -= duration;
                    MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
                    // A ragdoll waits until the body has come to rest (knock state 2), or long enough
                    bool wantsUp = state.mTimer <= 0.f;
                    if (state.mRagdoll && animation != nullptr)
                    {
                        if (!state.mSettled && animation->isRagdollAtRest())
                        {
                            settleAtBody(actor, *animation);
                            state.mSettled = true;
                            if (!state.mUnconscious)
                                state.mTimer = std::min(state.mTimer, sLyingTime);
                        }
                        wantsUp = state.mTimer <= 0.f && (state.mSettled || state.mTimer < -sMaxRagdollWait);
                    }
                    if (wantsUp && !(state.mPosture == Posture::Unconscious && state.mUnconscious))
                    {
                        // Wants to get up (knock state 3): the get-up sequence (the original picks it from the IDLE
                        // tree by the pose it lies in; the skeleton's own get-up file stands in for that)
                        if (state.mRagdoll && animation != nullptr && !state.mSettled)
                        {
                            settleAtBody(actor, *animation);
                            state.mSettled = true;
                        }
                        // The get-up sequence starts from a lying pose of its own, placed from the actor: the actor
                        // turns and moves so that pose lies where the body does
                        if (state.mRagdoll && animation != nullptr)
                            if (const auto alignment = animation->getGetUpAlignment())
                            {
                                MWBase::World& world = *MWBase::Environment::get().getWorld();
                                osg::Vec3f rotation = actor.getRefData().getPosition().asRotationVec3();
                                rotation.z() += alignment->first;
                                world.rotateObject(actor, rotation);
                                const osg::Vec3f position
                                    = actor.getRefData().getPosition().asVec3() + alignment->second;
                                const MWWorld::Ptr moved = world.moveObject(actor, position);
                                animation = getAnimation(moved);
                                if (animation != nullptr)
                                    animation->applyRagdollPose();
                            }
                        float length = 0.f;
                        if (animation != nullptr)
                            length = animation->playGetUp();
                        state.mTimer = length > 0.f ? length : sDefaultGetUpTime;
                        setPosture(actor, state, Posture::GettingUp);
                    }
                    break;
                }
                case Posture::GettingUp:
                    state.mTimer -= duration;
                    if (state.mTimer <= 0.f)
                    {
                        state.mTimer = 0.f;
                        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
                            animation->standUp();
                        MWBase::Environment::get().getWorld()->enableActorCollision(actor, true);
                        state.mRagdoll = false;
                        state.mSettled = false;
                        setPosture(actor, state, Posture::Standing);
                    }
                    break;
                default:
                    break;
            }
            // Standing with nothing pending needs no entry (bleed level aside)
            if (state.mPosture == Posture::Standing && state.mBleed <= 0.f && state.mTimer <= 0.f)
                it = sStates.erase(it);
            else
                ++it;
        }
    }

    void clear()
    {
        sStates.clear();
    }
}
