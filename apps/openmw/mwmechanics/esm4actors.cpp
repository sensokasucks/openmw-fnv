#include "esm4actors.hpp"

#include <algorithm>
#include <cmath>

#include <osg/Math>
#include <osg/io_utils>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadbptd.hpp>
#include <components/esm4/loadweap.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwrender/camera.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/cell.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/ptr.hpp"
#include "../mwworld/worldmodel.hpp"

#include "esm4combat.hpp"
#include "esm4gore.hpp"
#include "esm4physical.hpp"

namespace MWMechanics
{
    namespace
    {
        // Used when a locomotion sequence has no root motion to measure
        constexpr float sDefaultWalkSpeed = 90.f;
        constexpr float sDefaultRunSpeed = 300.f;
        const float sTurnSpeed = static_cast<float>(osg::PI) * 1.5f; // radians per second (osg::PI is not constexpr everywhere)
        // Movement smoothing (updateActor): pace is picked up at 3 x the pace a second, at least this, so any pace
        // is reached in about a third of a second; the slowest it creeps into a goal; a corner counts as rounded
        // this close; the actor turns on the spot before setting off when the way is more than this off; and
        // the tightest curve it rounds a corner on while moving.
        constexpr float sMinAcceleration = 200.f;
        constexpr float sCreepSpeed = 20.f;
        constexpr float sCornerRadius = 24.f;
        const float sTurnInPlaceAngle = static_cast<float>(osg::PI) / 3.f;
        constexpr float sMinTurnRadius = 16.f;

        // Actor avoidance (FalloutNV.exe 0x9e5690, 0x9e5ae0, 0x9e0a00; the :Pathfinding INI defaults)
        constexpr float sAvoidCheckInterval = 0.1f; // seconds between looks ahead
        constexpr float sAvoidTimeCheck = 0.75f; // fAvoidanceTimeCheck: seconds of walking looked ahead
        constexpr float sAvoidAllRadius = 100.f; // fAvoidanceAvoidAllRadius: shortest look ahead
        constexpr float sAvoidDetectionTime = 0.5f; // fAvoidanceDetectionTime: blocked this long before reacting
        constexpr float sAvoidWaitTime = 5.f; // fAvoidanceDefaultWaitTime: longest wait
        constexpr float sAvoidMinWaitTime = 0.25f; // fAvoidanceMinWaitTime: clear this long to walk on
        constexpr float sAvoidIgnoreTime = 5.f; // fAvoidanceIgnoreTime: no new reaction after going around
        constexpr float sAvoidIgnoreMinTime = 2.5f; // fAvoidanceIgnoreMinTime: the same, around the player
        constexpr float sAvoidActorRadius = 20.f; // an NPC's collision box is 40 units wide
        constexpr float sAvoidCircleMult = 1.5f; // avoid circles are 1.5 times the blocker's radius
        constexpr float sAvoidMovingSpeed = 20.f; // units per second above which a blocker counts as moving
        constexpr int sAvoidMaxDetours = 8;
        constexpr float sAvoidEyeHeight = 64.f;

        // Falls: a drop deeper than this isn't a step down but a fall under gravity (the Havok proxy's step
        // height is not located; the Morrowind controller's sStepSizeDown is 62)
        constexpr float sStepDown = 64.f;
        constexpr float sGravity = 8.96f * 69.99125109f; // Constants::GravityConst x UnitsPerMeter

        std::optional<ESM::FormId> getCellFormId(const MWWorld::Ptr& ptr)
        {
            if (ptr.getCell() == nullptr)
                return std::nullopt;
            const ESM::RefId& id = ptr.getCell()->getCell()->getId();
            if (const ESM::FormId* formId = id.getIf<ESM::FormId>())
                return *formId;
            return std::nullopt;
        }

        MWRender::ESM4NpcAnimation* getAnimation(const MWWorld::Ptr& ptr)
        {
            return dynamic_cast<MWRender::ESM4NpcAnimation*>(MWBase::Environment::get().getWorld()->getAnimation(ptr));
        }

        void setLocomotion(
            const MWWorld::Ptr& ptr, MWRender::ESM4NpcAnimation::Locomotion locomotion, bool force = false)
        {
            if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr))
                animation->setLocomotion(locomotion, force);
        }

        void setYaw(const MWWorld::Ptr& ptr, float yaw)
        {
            float wrapped = yaw;
            while (wrapped > osg::PI)
                wrapped -= 2 * osg::PI;
            while (wrapped < -osg::PI)
                wrapped += 2 * osg::PI;
            MWBase::Environment::get().getWorld()->rotateObject(
                ptr, osg::Vec3f(0.f, 0.f, wrapped), MWBase::RotationFlag_none);
        }

        // Marker space (x right, y along the heading) to world: the heading is the yaw the actor faces, measured
        // like actor rotations (0 = +y, clockwise).
        osg::Vec3f markerToWorld(const osg::Vec3f& marker, float heading, const osg::Vec3f& offset)
        {
            const float s = std::sin(heading);
            const float c = std::cos(heading);
            return marker + osg::Vec3f(offset.x() * c + offset.y() * s, -offset.x() * s + offset.y() * c, offset.z());
        }

        float wrapAngle(float angle)
        {
            while (angle > osg::PI)
                angle -= 2 * osg::PI;
            while (angle < -osg::PI)
                angle += 2 * osg::PI;
            return angle;
        }

        // Turns the actor towards yaw; true once it faces it.
        bool turnTowards(const MWWorld::Ptr& ptr, float yaw, float duration, float turnSpeed = sTurnSpeed)
        {
            osg::Vec3f rot = ptr.getRefData().getPosition().asRotationVec3();
            const float diff = wrapAngle(yaw - rot.z());
            const float step = turnSpeed * duration;
            const bool done = std::abs(diff) <= step;
            rot.x() = 0.f;
            rot.y() = 0.f;
            rot.z() = done ? yaw : rot.z() + (diff > 0 ? step : -step);
            MWBase::Environment::get().getWorld()->rotateObject(ptr, rot, MWBase::RotationFlag_none);
            return done;
        }
    }

    ESM4Actors& ESM4Actors::get()
    {
        static ESM4Actors instance;
        return instance;
    }

    void ESM4Actors::landFromFall(const MWWorld::Ptr& ptr, State& state, float groundZ)
    {
        const float height = state.mFallFrom ? *state.mFallFrom - groundZ : 0.f;
        state.mFallFrom.reset();
        state.mFallSpeed = 0.f;
        using MWWorld::ESM4GameSettings::getFloat;
        const float minHeight = getFloat("fJumpFallHeightMin", 256.f);
        if (height <= minHeight || ESM4Combat::isDead(ptr))
            return;
        const float damage = std::pow(height - minHeight, getFloat("fJumpFallHeightExponent", 2.f))
            * getFloat("fJumpFallHeightMult", 0.025f);
        if (damage <= 0.f)
            return;
        Log(Debug::Verbose) << "ESM4 AI: " << ptr.getCellRef().getRefNum().toString() << " falls " << height
                            << " for " << damage;
        const float legDamage = damage * getFloat("fFallLegDamageMult", 0.5f);
        const int legChance = MWWorld::ESM4GameSettings::getInt("iFallLegDamageChance", 50);
        std::uniform_int_distribution<int> roll(0, 99);
        for (int leg : { ESM4::BodyPartData::Part_LeftLeg1, ESM4::BodyPartData::Part_RightLeg1 })
            if (roll(mRandom) < legChance)
                ESM4Gore::damageLimb(ptr, leg, legDamage, 1.f);
        ESM4Combat::hit(ptr, MWWorld::Ptr(), damage);
    }

    bool ESM4Actors::moveTo(const MWWorld::Ptr& ptr, const osg::Vec3f& target, const MoveOptions& options)
    {
        if (ESM4Combat::isDead(ptr) || !ESM4Physical::canAct(ptr))
            return false;
        State& state = mStates[ptr.getCellRef().getRefNum()];
        if (state.mUsePhase != UsePhase::None)
            finishUsing(ptr, state);
        state.mIdleTimer = 0.f;
        state.mOptions = options;
        state.mTarget = target;
        state.mTurnTo.reset();
        state.mStuckTime = 0.f;
        state.mNextPoint = 0;
        state.mCorridorIndex = 0;
        state.mDetours = 0;
        state.mAvoidWaiting = false;
        state.mBlockedTime = 0.f;

        const std::optional<ESM::FormId> cell = getCellFormId(ptr);
        const osg::Vec3f position = ptr.getRefData().getPosition().asVec3();
        std::optional<ESM4Navigation::Path> path;
        if (cell && !options.mStraight)
            path = mNavigation.findPath(*cell, position, target);
        if (!path && (options.mDirect || options.mStraight))
        {
            path = ESM4Navigation::Path();
            path->mPoints.push_back(target);
        }
        else if (path && options.mDirect && !path->mPoints.empty())
        {
            // The navmesh got only part of the way (the goal is past the edge of the loaded navmesh, such as
            // across an exterior cell border): go on straight from where it ends
            const osg::Vec3f& end = path->mPoints.back();
            if (osg::Vec2f(target.x() - end.x(), target.y() - end.y()).length() > std::max(options.mTolerance, 64.f))
                path->mPoints.push_back(target);
        }
        if (!path)
        {
            Log(Debug::Verbose) << "ESM4 AI: no path for " << ptr.getCellRef().getRefNum().toString() << " from "
                                << position << " to " << target << (cell ? "" : " (cell without form id)");
            state.mStatus = Status::NoPath;
            setLocomotion(ptr, MWRender::ESM4NpcAnimation::Locomotion::Idle);
            return false;
        }
        state.mPath = std::move(*path);
        state.mStatus = Status::Moving;
        Log(Debug::Verbose) << "ESM4 AI: " << ptr.getCellRef().getRefNum().toString() << " walks to " << target
                            << " in " << state.mPath.mPoints.size() << " legs over " << state.mPath.mCorridor.size()
                            << " triangles";
        return true;
    }

    void ESM4Actors::setPace(const MWWorld::Ptr& ptr, float speedMult, bool run)
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        if (it == mStates.end())
            return;
        it->second.mOptions.mSpeedMult = std::clamp(speedMult, 0.f, 2.f);
        it->second.mOptions.mRun = run;
    }

    void ESM4Actors::stop(const MWWorld::Ptr& ptr, bool inPlace)
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        if (it == mStates.end())
            return;
        const bool wasUsing = it->second.mUsePhase != UsePhase::None || it->second.mIdleTimer > 0.f;
        if (wasUsing)
            finishUsing(ptr, it->second, inPlace);
        if (it->second.mActionTime > 0.f)
        {
            it->second.mStatus = Status::None;
            it->second.mTurnTo.reset();
        }
        else
            mStates.erase(it);
        setLocomotion(ptr, MWRender::ESM4NpcAnimation::Locomotion::Idle, wasUsing);
    }

    void ESM4Actors::useFurniture(const MWWorld::Ptr& ptr, const FurnitureUse& use)
    {
        if (ESM4Combat::isDead(ptr) || !ESM4Physical::canAct(ptr))
            return;
        State& state = mStates[ptr.getCellRef().getRefNum()];
        if (state.mUsePhase != UsePhase::None)
            finishUsing(ptr, state);
        state.mStatus = Status::None;
        state.mTurnTo.reset();
        state.mIdleTimer = 0.f;
        state.mActionTime = 0.f;
        state.mFurniture = use;

        MWBase::World& world = *MWBase::Environment::get().getWorld();
        // The seat is inside the furniture's collision; the actor would be pushed out of it.
        world.setActorCollisionMode(ptr, false, false);
        MWWorld::Ptr moved = world.moveObject(ptr, use.mMarker);
        setYaw(moved, use.mHeading);

        MWRender::ESM4NpcAnimation* animation = getAnimation(moved);
        float length = 0.f;
        if (animation != nullptr && !use.mEnter.empty() && !use.mSeated)
            length = animation->playIdleFONV(use.mEnter, true, true);
        Log(Debug::Verbose) << "ESM4 AI: " << moved.getCellRef().getRefNum().toString() << " uses furniture at "
                            << use.mMarker << " (" << use.mEnter << ", " << length << "s)";
        if (length > 0.f)
        {
            state.mUsePhase = UsePhase::Entering;
            state.mPhaseTimer = length;
        }
        else
            startUsing(moved, state);
    }

    void ESM4Actors::startUsing(const MWWorld::Ptr& ptr, State& state)
    {
        const FurnitureUse& use = state.mFurniture;
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        osg::Vec3f offset = use.mOffset;
        // Prefer where the entry sequence actually left the root over the nominal marker offset
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
            animation != nullptr && !use.mEnter.empty() && !use.mSeated)
        {
            const osg::Vec3f motion = animation->getRootMotion();
            if (motion.length2() > 1.f)
                offset = osg::Vec3f(motion.x(), motion.y(), use.mOffset.z());
        }
        MWWorld::Ptr moved = world.moveObject(ptr, markerToWorld(use.mMarker, use.mHeading, offset));
        setYaw(moved, use.mHeading + use.mHeadingDelta);
        state.mUsePhase = UsePhase::Using;
        state.mPhaseTimer = 0.f;
        resumeLoop(moved, state);
    }

    void ESM4Actors::leaveFurniture(const MWWorld::Ptr& ptr)
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        if (it == mStates.end() || it->second.mUsePhase == UsePhase::None || it->second.mUsePhase == UsePhase::Leaving)
            return;
        State& state = it->second;
        const FurnitureUse& use = state.mFurniture;
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        MWWorld::Ptr moved = world.moveObject(ptr, use.mMarker);
        setYaw(moved, use.mHeading);
        state.mIdleTimer = 0.f;

        float length = 0.f;
        MWRender::ESM4NpcAnimation* animation = getAnimation(moved);
        if (animation != nullptr && !use.mExit.empty())
            length = animation->playIdleFONV(use.mExit, true, true);
        if (length > 0.f)
        {
            state.mUsePhase = UsePhase::Leaving;
            state.mPhaseTimer = length;
        }
        else
            finishUsing(moved, state);
    }

    void ESM4Actors::finishUsing(const MWWorld::Ptr& ptr, State& state, bool inPlace)
    {
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        if (!inPlace && (state.mUsePhase == UsePhase::Using || state.mUsePhase == UsePhase::Entering))
        {
            // Stand on the marker again, as after the exit sequence
            MWWorld::Ptr moved = world.moveObject(ptr, state.mFurniture.mMarker);
            setYaw(moved, state.mFurniture.mHeading);
        }
        if (state.mUsePhase != UsePhase::None)
            world.setActorCollisionMode(ptr, true, true);
        state.mUsePhase = UsePhase::None;
        state.mPhaseTimer = 0.f;
        state.mIdleTimer = 0.f;
        setLocomotion(ptr, MWRender::ESM4NpcAnimation::Locomotion::Idle, true);
    }

    ESM4Actors::UsePhase ESM4Actors::getUsePhase(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it == mStates.end() ? UsePhase::None : it->second.mUsePhase;
    }

    void ESM4Actors::playIdle(const MWWorld::Ptr& ptr, const std::string& model)
    {
        if (ESM4Combat::isDead(ptr) || !ESM4Physical::canAct(ptr))
            return;
        State& state = mStates[ptr.getCellRef().getRefNum()];
        if (state.mStatus == Status::Moving || state.mActionTime > 0.f || state.mUsePhase == UsePhase::Entering
            || state.mUsePhase == UsePhase::Leaving)
            return;
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        if (animation == nullptr)
            return;
        // Seated idles leave the root alone; standing ones may shuffle around, which the actor doesn't follow
        const float length = animation->playIdleFONV(model, false, true);
        if (length <= 0.f)
            return;
        state.mIdleTimer = length;
        // a turn under way (toward someone to talk to) goes on during the idle
    }

    bool ESM4Actors::isIdlePlaying(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it != mStates.end() && it->second.mIdleTimer > 0.f;
    }

    void ESM4Actors::resumeLoop(const MWWorld::Ptr& ptr, State& state)
    {
        state.mIdleTimer = 0.f;
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        if (animation == nullptr)
            return;
        if (state.mUsePhase == UsePhase::Using && !state.mFurniture.mLoop.empty()
            && animation->playIdleFONV(state.mFurniture.mLoop, false) > 0.f)
            return;
        animation->setLocomotion(MWRender::ESM4NpcAnimation::Locomotion::Idle, true);
    }

    float ESM4Actors::playAction(const MWWorld::Ptr& ptr, std::string_view file)
    {
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        if (animation == nullptr || ESM4Combat::isDead(ptr) || !ESM4Physical::canAct(ptr))
            return 0.f;
        const float length = animation->playActionFONV(file);
        if (length > 0.f)
            mStates[ptr.getCellRef().getRefNum()].mActionTime = length;
        return length;
    }

    bool ESM4Actors::isActing(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it != mStates.end() && it->second.mActionTime > 0.f;
    }

    void ESM4Actors::face(const MWWorld::Ptr& ptr, float yaw)
    {
        if (ESM4Combat::isDead(ptr) || !ESM4Physical::canAct(ptr))
            return;
        State& state = mStates[ptr.getCellRef().getRefNum()];
        if (state.mStatus == Status::Moving || state.mUsePhase != UsePhase::None)
            return;
        state.mTurnTo = yaw;
    }

    bool ESM4Actors::isRunning(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it != mStates.end() && it->second.mStatus == Status::Moving && it->second.mOptions.mRun;
    }

    float ESM4Actors::getWalkSpeed(const MWWorld::Ptr& ptr)
    {
        namespace Stats = MWClass::ESM4Stats;
        using MWWorld::ESM4GameSettings::getFloat;

        float penalty = 0.f;
        if (ptr.getType() == ESM::REC_NPC_4)
        {
            // Heaviest armor worn
            float armor = 0.f;
            for (const ESM4::Armor* worn : MWClass::ESM4Npc::getEquippedArmor(ptr))
            {
                if (worn->mGeneralFlags & ESM4::Armor::FO3_HeavyArmor)
                    armor = std::max(armor, getFloat("fMoveHeavyArmorPenalty"));
                else if (worn->mGeneralFlags & ESM4::Armor::FO3_MediumArmor)
                    armor = std::max(armor, getFloat("fMoveMediumArmorPenalty"));
            }
            penalty += armor;

            const MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
            const ESM4::Weapon* weapon = MWClass::ESM4Npc::getEquippedWeapon(ptr);
            if (weapon != nullptr && weapon->mHasFO3Data && animation != nullptr && animation->isWeaponShown())
            {
                switch (weapon->mFO3Data.animType)
                {
                    case 2: // melee 2H
                    case 8: // handle
                    case 9: // launcher
                        penalty += getFloat("fMove2HBigPenalty");
                        break;
                    case 5: // rifles
                    case 6:
                        penalty += getFloat("fMove2HRPenalty");
                        break;
                    default:
                        break;
                }
            }
        }

        // The legs: one crippled slows, both more so (ESM4Physical::getMobility, the same multipliers the
        // original applies here)
        const float legs = ESM4Physical::getMobility(ptr).mSpeedMult;

        const float speed
            = Stats::getCurrent(ptr, Stats::SpeedMult) * 0.01f * getFloat("fMoveBaseSpeed") * legs * (1.f - penalty);
        return std::max(0.f, speed);
    }

    float ESM4Actors::getRunSpeed(const MWWorld::Ptr& ptr)
    {
        return getWalkSpeed(ptr) * MWWorld::ESM4GameSettings::getFloat("fMoveRunMult");
    }

    ESM4Actors::Status ESM4Actors::getStatus(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it == mStates.end() ? Status::None : it->second.mStatus;
    }

    bool ESM4Actors::updateActor(const MWWorld::Ptr& ptr, State& state, float duration)
    {
        if (state.mUsePhase == UsePhase::Entering || state.mUsePhase == UsePhase::Leaving)
        {
            state.mPhaseTimer -= duration;
            if (state.mPhaseTimer <= 0.f)
            {
                if (state.mUsePhase == UsePhase::Entering)
                    startUsing(ptr, state);
                else
                    finishUsing(ptr, state);
            }
            return true;
        }
        if (state.mIdleTimer > 0.f)
        {
            state.mIdleTimer -= duration;
            if (state.mIdleTimer <= 0.f)
                resumeLoop(ptr, state);
            if (state.mUsePhase == UsePhase::None && state.mTurnTo && turnTowards(ptr, *state.mTurnTo, duration))
                state.mTurnTo.reset();
            return true;
        }
        if (state.mUsePhase == UsePhase::Using)
            return true;

        if (state.mActionTime > 0.f)
        {
            state.mActionTime -= duration;
            if (state.mActionTime <= 0.f)
            {
                state.mActionTime = 0.f;
                if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr))
                    animation->resumeLocomotion();
            }
        }
        // Knocked down or getting up: nothing moves until it stands again (knockDown stopped the move; this
        // covers a knockdown mid-turn or mid-action)
        if (!ESM4Physical::canAct(ptr))
        {
            state.mSpeed = 0.f;
            return state.mStatus != Status::None || state.mTurnTo || state.mActionTime > 0.f;
        }
        if (state.mStatus != Status::Moving)
        {
            if (state.mTurnTo && turnTowards(ptr, *state.mTurnTo, duration))
                state.mTurnTo.reset();
            return state.mStatus != Status::None || state.mTurnTo || state.mActionTime > 0.f;
        }

        MWBase::World& world = *MWBase::Environment::get().getWorld();
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        // Both legs crippled: a limp, however much the AI wants to run (the plan's "no running")
        if (state.mOptions.mRun && !ESM4Physical::getMobility(ptr).mCanRun)
            state.mOptions.mRun = false;
        {
            const float lookSpeed = state.mOptions.mRun ? getRunSpeed(ptr) : getWalkSpeed(ptr);
            if (avoidActors(ptr, state, lookSpeed > 1.f ? lookSpeed : sDefaultWalkSpeed, duration))
            {
                state.mSpeed = 0.f;
                if (animation != nullptr)
                    animation->setLocomotion(MWRender::ESM4NpcAnimation::Locomotion::Idle);
                return true;
            }
            if (state.mStatus != Status::Moving)
                return true;
        }
        const auto locomotion = state.mOptions.mRun ? MWRender::ESM4NpcAnimation::Locomotion::Run
                                                    : MWRender::ESM4NpcAnimation::Locomotion::Walk;
        // The pace asked for: the formula speed times the caller's multiplier
        float speed = state.mOptions.mRun ? sDefaultRunSpeed : sDefaultWalkSpeed;
        float animationSpeed = 0.f;
        if (animation != nullptr)
        {
            animationSpeed = animation->getLocomotionSpeed();
            if (ptr.getType() == ESM::REC_NPC_4)
                // NPC speed comes from the formula; the walk or run loop is played faster or slower to keep pace
                speed = (state.mOptions.mRun ? getRunSpeed(ptr) : getWalkSpeed(ptr)) * state.mOptions.mSpeedMult;
            else
            {
                if (animationSpeed > 1.f)
                    speed = animationSpeed;
                speed *= state.mOptions.mSpeedMult;
            }
        }
        else
            speed *= state.mOptions.mSpeedMult;

        osg::Vec3f position = ptr.getRefData().getPosition().asVec3();
        // Close enough to the goal counts as there (attackers stop at arm's length)
        const osg::Vec2f toGoal(state.mTarget.x() - position.x(), state.mTarget.y() - position.y());
        if (toGoal.length() <= state.mOptions.mTolerance)
            state.mNextPoint = state.mPath.mPoints.size();
        // Corners reached, or passed while rounding them, are done with
        while (state.mNextPoint + 1 < state.mPath.mPoints.size())
        {
            const osg::Vec3f& point = state.mPath.mPoints[state.mNextPoint];
            const osg::Vec3f& next = state.mPath.mPoints[state.mNextPoint + 1];
            const osg::Vec2f to(point.x() - position.x(), point.y() - position.y());
            const osg::Vec2f leg(next.x() - point.x(), next.y() - point.y());
            if (to.length() <= sCornerRadius || to * leg < 0.f)
                ++state.mNextPoint;
            else
                break;
        }

        osg::Vec3f moved = position;
        if (state.mNextPoint < state.mPath.mPoints.size())
        {
            // The actor walks the way it faces and turns towards the next corner as it goes, picking up and losing
            // pace instead of jumping to it (a new order while moving keeps the pace), slowing into the goal and
            // turning on the spot first when the way is far off to the side: a walk that reads as one movement
            // rather than a point sliding along the route.
            const osg::Vec3f& point = state.mPath.mPoints[state.mNextPoint];
            const osg::Vec2f to(point.x() - position.x(), point.y() - position.y());
            float pathLeft = to.length();
            for (std::size_t i = state.mNextPoint + 1; i < state.mPath.mPoints.size(); ++i)
                pathLeft += osg::Vec2f(state.mPath.mPoints[i].x() - state.mPath.mPoints[i - 1].x(),
                    state.mPath.mPoints[i].y() - state.mPath.mPoints[i - 1].y())
                                .length();
            pathLeft = std::max(pathLeft - state.mOptions.mTolerance, 0.f);
            const float accel = std::max(3.f * speed, sMinAcceleration);
            float targetSpeed = std::min(speed, std::max(std::sqrt(2.f * accel * pathLeft), sCreepSpeed));
            const float desiredYaw = std::atan2(to.x(), to.y());
            const float heading = ptr.getRefData().getPosition().rot[2];
            if (std::abs(wrapAngle(desiredYaw - heading)) > sTurnInPlaceAngle && state.mSpeed < 0.5f * speed)
                targetSpeed = 0.f;
            if (targetSpeed > state.mSpeed)
                state.mSpeed = std::min(targetSpeed, state.mSpeed + accel * duration);
            else
                state.mSpeed = std::max(targetSpeed, state.mSpeed - accel * duration);
            // (turning quicker when fast, so the curve it rounds a corner on stays within a stride)
            turnTowards(ptr, desiredYaw, duration, std::max(sTurnSpeed, state.mSpeed / sMinTurnRadius));
            const float yaw = ptr.getRefData().getPosition().rot[2];
            float remaining = state.mSpeed * duration;
            if (state.mNextPoint + 1 == state.mPath.mPoints.size())
                remaining = std::min(remaining, std::max(toGoal.length() - state.mOptions.mTolerance, 0.f));
            moved.x() += std::sin(yaw) * remaining;
            moved.y() += std::cos(yaw) * remaining;
        }
        else
            state.mSpeed = 0.f;
        position = moved;

        if (animation != nullptr)
        {
            const bool standing = state.mSpeed < 1.f;
            animation->setLocomotion(standing ? MWRender::ESM4NpcAnimation::Locomotion::Idle : locomotion);
            if (!standing)
            {
                // the loop is played at the pace actually moved
                if (ptr.getType() == ESM::REC_NPC_4)
                    animation->setLocomotionRate(animationSpeed > 1.f ? state.mSpeed / animationSpeed : 1.f);
                else
                    animation->setLocomotionRate(speed > 1.f ? state.mOptions.mSpeedMult * state.mSpeed / speed : 1.f);
            }
        }

        // Follow the ground of the navmesh along the corridor
        const auto& corridor = state.mPath.mCorridor;
        bool onCorridor = false;
        for (std::size_t i = state.mCorridorIndex; i < corridor.size() && i < state.mCorridorIndex + 16; ++i)
        {
            if (ESM4Navigation::contains2D(corridor[i], position.x(), position.y()))
            {
                state.mCorridorIndex = i;
                position.z() = ESM4Navigation::heightAt(corridor[i], position.x(), position.y());
                onCorridor = true;
                break;
            }
        }

        if (!onCorridor)
        {
            // Straight moves, and the straight end of a path beyond the navmesh, keep to the ground below; a drop
            // deeper than a step is a fall under gravity, with the original's fall damage on landing
            // (render-anim-physics.md 2: h over fJumpFallHeightMin, (h - min) ^ exponent x mult, legs with
            // fFallLegDamageMult at iFallLegDamageChance)
            const osg::Vec3f up(0.f, 0.f, sStepDown);
            const MWPhysics::RayCastingResult ground = world.getRayCasting()->castRay(position + up,
                position - osg::Vec3f(0.f, 0.f, 4096.f), MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap);
            const float groundZ = ground.mHit ? ground.mHitPos.z() : position.z();
            if (groundZ >= position.z() - sStepDown || !ground.mHit)
            {
                if (state.mFallFrom)
                    landFromFall(ptr, state, groundZ);
                position.z() = groundZ;
            }
            else
            {
                if (!state.mFallFrom)
                {
                    state.mFallFrom = position.z();
                    state.mFallSpeed = 0.f;
                }
                state.mFallSpeed += sGravity * duration;
                position.z() = std::max(groundZ, position.z() - state.mFallSpeed * duration);
                if (position.z() <= groundZ)
                    landFromFall(ptr, state, groundZ);
            }
        }
        else if (state.mFallFrom)
            landFromFall(ptr, state, position.z());

        MWWorld::Ptr movedPtr = world.moveObject(ptr, position);

        if (state.mNextPoint >= state.mPath.mPoints.size())
        {
            state.mStatus = Status::Arrived;
            state.mTurnTo = state.mOptions.mFinalYaw;
            setLocomotion(movedPtr, MWRender::ESM4NpcAnimation::Locomotion::Idle);
        }
        return true;
    }

    std::vector<ESM4Navigation::CoverEdge> ESM4Actors::findCoverEdges(
        const MWWorld::Ptr& ptr, const osg::Vec3f& center, float radius, std::size_t maxCount)
    {
        const std::optional<ESM::FormId> cell = getCellFormId(ptr);
        if (!cell)
            return {};
        return mNavigation.findCoverEdges(*cell, center, radius, maxCount);
    }

    bool ESM4Actors::avoidActors(const MWWorld::Ptr& ptr, State& state, float speed, float duration)
    {
        if (state.mIgnoreTime > 0.f)
            state.mIgnoreTime -= duration;
        state.mAvoidCheck -= duration;
        if (state.mAvoidCheck > 0.f)
            return state.mAvoidWaiting;
        const float elapsed = sAvoidCheckInterval - state.mAvoidCheck;
        state.mAvoidCheck = sAvoidCheckInterval;
        if (state.mNextPoint >= state.mPath.mPoints.size())
            return false;

        const osg::Vec3f position = ptr.getRefData().getPosition().asVec3();
        osg::Vec3f toPoint = state.mPath.mPoints[state.mNextPoint] - position;
        toPoint.z() = 0.f;
        const float pointDistance = toPoint.length();
        if (pointDistance < 1.f)
            return false;
        const osg::Vec3f direction = toPoint / pointDistance;
        const osg::Vec3f right(direction.y(), -direction.x(), 0.f);

        // What is in the way within the look ahead: three rays at chest height, along the path and at either
        // shoulder (the original tests a cone of fAvoidanceConeAngle 45 degrees either side against the actors
        // within reach)
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        const MWPhysics::RayCastingInterface& rays = *world.getRayCasting();
        const float lookAhead = std::max(speed * sAvoidTimeCheck, sAvoidAllRadius);
        const osg::Vec3f eye(0.f, 0.f, sAvoidEyeHeight);
        const std::vector<MWWorld::ConstPtr> ignore{ ptr };
        MWWorld::Ptr obstacle;
        float obstacleDistance = lookAhead;
        for (float side : { 0.f, -sAvoidActorRadius, sAvoidActorRadius })
        {
            const osg::Vec3f from = position + eye + right * side;
            const MWPhysics::RayCastingResult hit
                = rays.castRay(from, from + direction * lookAhead, ignore, {}, MWPhysics::CollisionType_Actor);
            if (!hit.mHit || hit.mHitObject.isEmpty())
                continue;
            const float distance = (hit.mHitPos - from).length();
            if (distance < obstacleDistance)
            {
                obstacle = hit.mHitObject;
                obstacleDistance = distance;
            }
        }

        if (state.mAvoidWaiting)
        {
            // Waiting: walk on once the way has been clear for fAvoidanceMinWaitTime, or the wait is over
            state.mAvoidWaitLeft -= elapsed;
            if (obstacle.isEmpty())
                state.mAvoidResume -= elapsed;
            else
                state.mAvoidResume = sAvoidMinWaitTime;
            if (state.mAvoidResume > 0.f && state.mAvoidWaitLeft > 0.f)
                return true;
            state.mAvoidWaiting = false;
            state.mBlockedTime = 0.f;
            // Waited it out and still blocked: next time go around it instead of waiting again
            state.mWaitedOut = state.mAvoidWaitLeft <= 0.f && !obstacle.isEmpty();
            return false;
        }

        if (obstacle.isEmpty() || state.mIgnoreTime > 0.f)
        {
            state.mBlockedTime = std::max(0.f, state.mBlockedTime - elapsed);
            state.mBlocker = MWWorld::Ptr();
            return false;
        }

        const osg::Vec3f obstaclePosition = obstacle.getRefData().getPosition().asVec3();
        bool moving = false;
        if (obstacle == state.mBlocker)
            moving = (obstaclePosition - state.mBlockerPosition).length() > sAvoidMovingSpeed * elapsed;
        else
            state.mWaitedOut = false;
        state.mBlocker = obstacle;
        state.mBlockerPosition = obstaclePosition;
        const bool player = obstacle == world.getPlayerPtr();

        // Someone standing at the goal is who the actor is walking up to (a follower's leader, a conversation
        // partner), not something in the way: no waiting or detour, and close enough counts as there. (Run 29:
        // judging "close enough" by the look-ahead hit stopped a follower dead 220 units from the player.)
        const bool lastLeg = state.mNextPoint + 1 == state.mPath.mPoints.size();
        if (lastLeg)
        {
            const osg::Vec2f obstacleToGoal(state.mTarget.x() - obstaclePosition.x(), state.mTarget.y() - obstaclePosition.y());
            if (obstacleToGoal.length() <= 2 * sAvoidActorRadius + state.mOptions.mTolerance)
            {
                // (run 30: with a wide tolerance, judging it by the goal's distance still stopped a follower at
                // 220; it is there once it touches whoever stands there)
                if (obstacleDistance <= 2 * sAvoidActorRadius + 8.f)
                {
                    state.mNextPoint = state.mPath.mPoints.size();
                    state.mStatus = Status::Arrived;
                    state.mTurnTo = state.mOptions.mFinalYaw;
                    setLocomotion(ptr, MWRender::ESM4NpcAnimation::Locomotion::Idle);
                }
                state.mBlockedTime = 0.f;
                return false;
            }
        }

        // Blocked time counts double for a blocker standing still
        state.mBlockedTime += elapsed * (moving || player ? 1.f : 2.f);
        if (state.mBlockedTime <= sAvoidDetectionTime)
            return false;
        state.mBlockedTime = 0.f;

        if (!moving && !state.mWaitedOut)
        {
            // Someone standing in the way: wait for them to move
            state.mAvoidWaiting = true;
            state.mAvoidWaitLeft = sAvoidWaitTime;
            state.mAvoidResume = sAvoidMinWaitTime;
            return true;
        }

        // Go around it: a point beside the blocker, outside its avoid circle, on the side it leaves free, where
        // the navmesh goes and nothing is in the way
        state.mWaitedOut = false;
        state.mIgnoreTime = player ? std::max(sAvoidIgnoreTime, sAvoidIgnoreMinTime) : sAvoidIgnoreTime;
        if (state.mDetours >= sAvoidMaxDetours)
            return false;
        osg::Vec3f offset = obstaclePosition - position;
        offset.z() = 0.f;
        const float lateral = offset * right;
        const float clearance = sAvoidActorRadius * sAvoidCircleMult + sAvoidActorRadius;
        const std::optional<ESM::FormId> cell = getCellFormId(ptr);
        for (float side : { lateral > 0.f ? -1.f : 1.f, lateral > 0.f ? 1.f : -1.f })
        {
            osg::Vec3f detour = obstaclePosition + right * (side * clearance);
            detour.z() = position.z();
            if (cell)
            {
                const std::optional<ESM4Navigation::Triangle> triangle = mNavigation.locate(*cell, detour);
                if (!triangle || !ESM4Navigation::contains2D(*triangle, detour.x(), detour.y()))
                    continue;
                const float height = ESM4Navigation::heightAt(*triangle, detour.x(), detour.y());
                if (std::abs(height - position.z()) > 64.f)
                    continue;
                detour.z() = height;
            }
            const MWPhysics::RayCastingResult blocked = rays.castRay(position + eye, detour + eye, ignore, {},
                MWPhysics::CollisionType_World | MWPhysics::CollisionType_Door | MWPhysics::CollisionType_Actor);
            if (blocked.mHit)
                continue;
            state.mPath.mPoints.insert(
                state.mPath.mPoints.begin() + static_cast<std::ptrdiff_t>(state.mNextPoint), detour);
            ++state.mDetours;
            return false;
        }
        return false;
    }

    void ESM4Actors::lookAt(const MWWorld::Ptr& ptr, const MWWorld::Ptr& target)
    {
        const ESM::RefNum actor = ptr.getCellRef().getRefNum();
        if (target.isEmpty())
        {
            mLookTargets.erase(actor);
            if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr))
                animation->setLookTarget(std::nullopt);
            return;
        }
        const bool player = target == MWBase::Environment::get().getWorld()->getPlayerPtr();
        mLookTargets[actor] = { player ? ESM::RefNum() : target.getCellRef().getRefNum(), player };
    }

    void ESM4Actors::updateLookTargets()
    {
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        MWWorld::WorldModel& worldModel = *MWBase::Environment::get().getWorldModel();
        for (auto it = mLookTargets.begin(); it != mLookTargets.end();)
        {
            const MWWorld::Ptr ptr = worldModel.getPtr(it->first);
            MWRender::ESM4NpcAnimation* animation = ptr.isEmpty() ? nullptr : getAnimation(ptr);
            if (animation == nullptr)
            {
                it = mLookTargets.erase(it);
                continue;
            }
            std::optional<osg::Vec3f> position;
            if (it->second.mPlayer)
            {
                // The player's eyes: the camera in first person; from any other view the camera is away from
                // the body, so the head of the FO3/FNV player body (or the standing eye height without one).
                const MWRender::Camera& camera = *world.getCamera();
                const MWWorld::Ptr player = world.getPlayerPtr();
                if (camera.getMode() == MWRender::Camera::Mode::FirstPerson)
                    position = osg::Vec3f(camera.getPosition());
                else if (const MWRender::Animation* playerAnimation = world.getAnimation(player))
                    position = MWRender::ESM4NpcAnimation::getEyePosition(*playerAnimation);
                if (!position)
                    position = player.getRefData().getPosition().asVec3() + osg::Vec3f(0, 0, 120);
            }
            else
            {
                const MWWorld::Ptr target = worldModel.getPtr(it->second.mTarget);
                if (!target.isEmpty() && target.getRefData().getBaseNode() != nullptr)
                {
                    if (auto* targetAnimation = getAnimation(target))
                        position = MWRender::ESM4NpcAnimation::getEyePosition(*targetAnimation);
                    if (!position)
                        position = target.getRefData().getPosition().asVec3() + osg::Vec3f(0, 0, 100);
                }
            }
            animation->setLookTarget(position);
            ++it;
        }
    }

    void ESM4Actors::update(float duration, bool paused)
    {
        if (!paused && !mLookTargets.empty())
            updateLookTargets();
        if (paused || duration <= 0.f || mStates.empty())
            return;
        MWWorld::WorldModel& worldModel = *MWBase::Environment::get().getWorldModel();
        for (auto it = mStates.begin(); it != mStates.end();)
        {
            const MWWorld::Ptr ptr = worldModel.getPtr(it->first);
            if (ptr.isEmpty() || ptr.getRefData().getBaseNode() == nullptr || !ptr.getRefData().isEnabled())
            {
                it = mStates.erase(it);
                continue;
            }
            if (!updateActor(ptr, it->second, duration))
                it = mStates.erase(it);
            else
                ++it;
        }
    }

    void ESM4Actors::clear()
    {
        mStates.clear();
        mLookTargets.clear();
    }
}
