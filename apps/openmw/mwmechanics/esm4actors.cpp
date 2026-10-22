#include "esm4actors.hpp"

#include <cmath>

#include <osg/Math>
#include <osg/io_utils>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/cell.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
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
        constexpr float sTurnSpeed = osg::PI * 1.5f; // radians per second

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

        void setLocomotion(const MWWorld::Ptr& ptr, MWRender::ESM4NpcAnimation::Locomotion locomotion)
        {
            if (MWRender::ESM4NpcAnimation* animation = getAnimation(ptr))
                animation->setLocomotion(locomotion);
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
        if (it->second.mActionTime > 0.f)
        {
            it->second.mStatus = Status::None;
            it->second.mTurnTo.reset();
        }
        else
            mStates.erase(it);
        setLocomotion(ptr, MWRender::ESM4NpcAnimation::Locomotion::Idle);
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
        if (state.mStatus == Status::Moving)
            return;
        state.mTurnTo = yaw;
    }

    ESM4Actors::Status ESM4Actors::getStatus(const MWWorld::Ptr& ptr) const
    {
        auto it = mStates.find(ptr.getCellRef().getRefNum());
        return it == mStates.end() ? Status::None : it->second.mStatus;
    }

    bool ESM4Actors::updateActor(const MWWorld::Ptr& ptr, State& state, float duration)
    {
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
            if (animation->getLocomotionSpeed() > 1.f)
                speed = animation->getLocomotionSpeed();
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

    void ESM4Actors::update(float duration, bool paused)
    {
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
    }
}
