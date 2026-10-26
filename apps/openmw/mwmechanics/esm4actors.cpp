#include "esm4actors.hpp"

#include <cmath>

#include <osg/Math>
#include <osg/io_utils>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm4/loadarmo.hpp>
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

namespace MWMechanics
{
    namespace
    {
        // Used when a locomotion sequence has no root motion to measure
        constexpr float sDefaultWalkSpeed = 90.f;
        constexpr float sDefaultRunSpeed = 300.f;
        const float sTurnSpeed = static_cast<float>(osg::PI) * 1.5f; // radians per second (osg::PI is not constexpr everywhere)

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
        bool turnTowards(const MWWorld::Ptr& ptr, float yaw, float duration)
        {
            osg::Vec3f rot = ptr.getRefData().getPosition().asRotationVec3();
            const float diff = wrapAngle(yaw - rot.z());
            const float step = sTurnSpeed * duration;
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

    bool ESM4Actors::moveTo(const MWWorld::Ptr& ptr, const osg::Vec3f& target, const MoveOptions& options)
    {
        if (ESM4Combat::isDead(ptr))
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

    void ESM4Actors::stop(const MWWorld::Ptr& ptr)
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        if (it == mStates.end())
            return;
        const bool wasUsing = it->second.mUsePhase != UsePhase::None || it->second.mIdleTimer > 0.f;
        if (wasUsing)
            finishUsing(ptr, it->second);
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
        if (ESM4Combat::isDead(ptr))
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
        if (animation != nullptr && !use.mEnter.empty())
            length = animation->playIdleFONV(use.mEnter, true);
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
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr); animation != nullptr && !use.mEnter.empty())
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
            length = animation->playIdleFONV(use.mExit, true);
        if (length > 0.f)
        {
            state.mUsePhase = UsePhase::Leaving;
            state.mPhaseTimer = length;
        }
        else
            finishUsing(moved, state);
    }

    void ESM4Actors::finishUsing(const MWWorld::Ptr& ptr, State& state)
    {
        MWBase::World& world = *MWBase::Environment::get().getWorld();
        if (state.mUsePhase == UsePhase::Using || state.mUsePhase == UsePhase::Entering)
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
        if (ESM4Combat::isDead(ptr))
            return;
        State& state = mStates[ptr.getCellRef().getRefNum()];
        if (state.mStatus == Status::Moving || state.mActionTime > 0.f || state.mUsePhase == UsePhase::Entering
            || state.mUsePhase == UsePhase::Leaving)
            return;
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        if (animation == nullptr)
            return;
        // Seated idles leave the root alone; standing ones may shuffle around, which the actor doesn't follow
        const float length = animation->playIdleFONV(model, false);
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
        if (animation == nullptr || ESM4Combat::isDead(ptr))
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
        if (ESM4Combat::isDead(ptr))
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

        float legs = 1.f;
        if (Stats::getCurrent(ptr, Stats::IgnoreCrippledLimbs) == 0)
        {
            const int crippled = (Stats::getCurrent(ptr, Stats::LeftMobilityCondition) <= 0 ? 1 : 0)
                + (Stats::getCurrent(ptr, Stats::RightMobilityCondition) <= 0 ? 1 : 0);
            if (crippled == 1)
                legs = getFloat("fMoveOneCrippledLegSpeedMult");
            else if (crippled == 2)
                legs = getFloat("fMoveTwoCrippledLegsSpeedMult");
        }

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
        if (state.mStatus != Status::Moving)
        {
            if (state.mTurnTo && turnTowards(ptr, *state.mTurnTo, duration))
                state.mTurnTo.reset();
            return state.mStatus != Status::None || state.mTurnTo || state.mActionTime > 0.f;
        }

        MWBase::World& world = *MWBase::Environment::get().getWorld();
        MWRender::ESM4NpcAnimation* animation = getAnimation(ptr);
        const auto locomotion = state.mOptions.mRun ? MWRender::ESM4NpcAnimation::Locomotion::Run
                                                    : MWRender::ESM4NpcAnimation::Locomotion::Walk;
        float speed = state.mOptions.mRun ? sDefaultRunSpeed : sDefaultWalkSpeed;
        if (animation != nullptr)
        {
            animation->setLocomotion(locomotion);
            const float animationSpeed = animation->getLocomotionSpeed();
            if (ptr.getType() == ESM::REC_NPC_4)
            {
                // NPC speed comes from the formula; the walk or run loop is played faster or slower to keep pace
                speed = state.mOptions.mRun ? getRunSpeed(ptr) : getWalkSpeed(ptr);
                animation->setLocomotionRate(animationSpeed > 1.f ? speed / animationSpeed : 1.f);
            }
            else if (animationSpeed > 1.f)
                speed = animationSpeed;
        }

        osg::Vec3f position = ptr.getRefData().getPosition().asVec3();
        float remaining = speed * duration;
        // Close enough to the goal counts as there (attackers stop at arm's length)
        const osg::Vec2f toGoal(state.mTarget.x() - position.x(), state.mTarget.y() - position.y());
        if (toGoal.length() <= state.mOptions.mTolerance)
            state.mNextPoint = state.mPath.mPoints.size();
        else if (state.mNextPoint + 1 == state.mPath.mPoints.size())
            remaining = std::min(remaining, toGoal.length() - state.mOptions.mTolerance);
        osg::Vec3f direction;
        while (remaining > 0.f && state.mNextPoint < state.mPath.mPoints.size())
        {
            const osg::Vec3f& point = state.mPath.mPoints[state.mNextPoint];
            osg::Vec3f delta = point - position;
            delta.z() = 0.f;
            const float distance = delta.length();
            if (distance > 1e-3f)
                direction = delta / distance;
            if (distance <= remaining)
            {
                position.x() = point.x();
                position.y() = point.y();
                remaining -= distance;
                ++state.mNextPoint;
            }
            else
            {
                position += direction * remaining;
                remaining = 0.f;
            }
        }

        // Follow the ground of the navmesh along the corridor
        const auto& corridor = state.mPath.mCorridor;
        for (std::size_t i = state.mCorridorIndex; i < corridor.size() && i < state.mCorridorIndex + 16; ++i)
        {
            if (ESM4Navigation::contains2D(corridor[i], position.x(), position.y()))
            {
                state.mCorridorIndex = i;
                position.z() = ESM4Navigation::heightAt(corridor[i], position.x(), position.y());
                break;
            }
        }

        if (corridor.empty())
        {
            // Straight moves keep to the ground below
            const osg::Vec3f up(0.f, 0.f, 128.f);
            const MWPhysics::RayCastingResult ground = world.getRayCasting()->castRay(position + up,
                position - up * 4.f, MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap);
            if (ground.mHit)
                position.z() = ground.mHitPos.z();
        }

        MWWorld::Ptr moved = world.moveObject(ptr, position);
        if (direction.length2() > 0.f)
            turnTowards(moved, std::atan2(direction.x(), direction.y()), duration);

        if (state.mNextPoint >= state.mPath.mPoints.size())
        {
            state.mStatus = Status::Arrived;
            state.mTurnTo = state.mOptions.mFinalYaw;
            setLocomotion(moved, MWRender::ESM4NpcAnimation::Locomotion::Idle);
        }
        return true;
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
                // the player's eyes, whichever view the camera is in
                position = osg::Vec3f(world.getCamera()->getPosition());
            else
            {
                const MWWorld::Ptr target = worldModel.getPtr(it->second.mTarget);
                if (!target.isEmpty() && target.getRefData().getBaseNode() != nullptr)
                {
                    if (auto* targetAnimation = getAnimation(target))
                        position = targetAnimation->getHeadPosition();
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
