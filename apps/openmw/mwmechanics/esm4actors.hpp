#ifndef GAME_MWMECHANICS_ESM4ACTORS_H
#define GAME_MWMECHANICS_ESM4ACTORS_H

#include <map>
#include <optional>
#include <random>
#include <string>
#include <string_view>

#include <osg/Vec3f>

#include <components/esm3/refnum.hpp>

#include "../mwworld/ptr.hpp"

#include "esm4navigation.hpp"

namespace MWWorld
{
    class Ptr;
}

namespace MWMechanics
{
    // Moves FO3/FONV NPCs along their cell's navmesh. Which way to go is decided by the AI packages, evaluated in
    // Lua (scripts/omw/fnvai); this only walks there, turning the NPC and switching its walk/idle sequences.
    class ESM4Actors
    {
    public:
        enum class Status
        {
            None, // not asked to move, or stopped
            Moving,
            Arrived,
            NoPath,
        };

        struct MoveOptions
        {
            bool mRun = false;
            float mTolerance = 32.f; // how close counts as arrived
            std::optional<float> mFinalYaw; // radians, turned to on arrival
            bool mDirect = false; // without a navmesh route, go straight there
            bool mStraight = false; // go straight there, ignoring the navmesh
            float mSpeedMult = 1.f; // walk or run speed scaled (followers slowing down or catching up)
        };

        // How a piece of furniture is used, as the original engine does it: the actor stands on the furniture
        // marker facing its heading, the entry sequence carries its skeleton onto the seat, then the actor itself is
        // moved there (marker + offset, turned by headingDelta) for the seated loop, and the exit sequence brings it
        // back from the seat to the marker.
        struct FurnitureUse
        {
            osg::Vec3f mMarker; // world position of the marker
            float mHeading = 0.f; // yaw (radians) the actor faces at the marker
            osg::Vec3f mOffset; // seat relative to the marker, in marker space (x right, y along the heading)
            float mHeadingDelta = 0.f; // yaw added once seated
            std::string mEnter; // KF models under meshes/, empty for none
            std::string mLoop;
            std::string mExit;
            bool mSeated = false; // already seated (a loaded game): skip the entry sequence
        };

        enum class UsePhase
        {
            None,
            Entering,
            Using,
            Leaving,
        };

        static ESM4Actors& get();

        ESM4Navigation& getNavigation() { return mNavigation; }
        // Navmesh cover edges around the actor's position (see ESM4Navigation::findCoverEdges).
        std::vector<ESM4Navigation::CoverEdge> findCoverEdges(
            const MWWorld::Ptr& ptr, const osg::Vec3f& center, float radius, std::size_t maxCount);
        std::mt19937& getRandom() { return mRandom; }

        // False when no route exists (the status is then NoPath).
        bool moveTo(const MWWorld::Ptr& ptr, const osg::Vec3f& target, const MoveOptions& options);
        void stop(const MWWorld::Ptr& ptr);
        // Changes the speed and gait of the current move without finding a new path.
        void setPace(const MWWorld::Ptr& ptr, float speedMult, bool run);
        // Turns in place.
        void face(const MWWorld::Ptr& ptr, float yaw);
        Status getStatus(const MWWorld::Ptr& ptr) const;
        bool isMoving(const MWWorld::Ptr& ptr) const { return getStatus(ptr) == Status::Moving; }
        bool isRunning(const MWWorld::Ptr& ptr) const;

        // FO3/FONV NPC walk speed in units per second (ComputeActorWalkSpeed 0x647d10): SpeedMult percent of
        // fMoveBaseSpeed, slowed by crippled legs, medium/heavy armor and a drawn two-handed weapon. Running is
        // fMoveRunMult times faster (0x647f00).
        static float getWalkSpeed(const MWWorld::Ptr& ptr);
        static float getRunSpeed(const MWWorld::Ptr& ptr);

        // Plays a one-off sequence (an attack) and goes back to walking or standing when it ends. Returns its length,
        // 0 when the actor has no such sequence.
        float playAction(const MWWorld::Ptr& ptr, std::string_view file);
        bool isActing(const MWWorld::Ptr& ptr) const;

        // Starts using furniture: the actor is placed on the marker and plays the entry sequence. Any movement stops.
        void useFurniture(const MWWorld::Ptr& ptr, const FurnitureUse& use);
        // Plays the exit sequence; the actor stands on the marker again once it ends.
        void leaveFurniture(const MWWorld::Ptr& ptr);
        UsePhase getUsePhase(const MWWorld::Ptr& ptr) const;
        // Plays an idle sequence once (standing or seated), then returns to the idle or seated loop.
        void playIdle(const MWWorld::Ptr& ptr, const std::string& model);
        bool isIdlePlaying(const MWWorld::Ptr& ptr) const;
        // Head tracking: the actor's head follows target (the player's eyes, another actor's head) until
        // called with an empty target.
        void lookAt(const MWWorld::Ptr& ptr, const MWWorld::Ptr& target);

        void update(float duration, bool paused);
        void clear();

    private:
        struct State
        {
            Status mStatus = Status::None;
            ESM4Navigation::Path mPath;
            std::size_t mNextPoint = 0;
            std::size_t mCorridorIndex = 0;
            MoveOptions mOptions;
            osg::Vec3f mTarget;
            std::optional<float> mTurnTo;
            float mStuckTime = 0.f;
            float mActionTime = 0.f; // left of the one-off sequence playing

            UsePhase mUsePhase = UsePhase::None;
            FurnitureUse mFurniture;
            float mPhaseTimer = 0.f; // seconds left in the entry or exit sequence
            float mIdleTimer = 0.f; // seconds left in a one-shot idle, 0 when none plays

            // Actor avoidance
            float mAvoidCheck = 0.f; // seconds to the next look ahead
            float mBlockedTime = 0.f; // how long something has been in the way
            MWWorld::Ptr mBlocker; // what was in the way at the last look, only compared
            osg::Vec3f mBlockerPosition;
            bool mAvoidWaiting = false; // standing until the way clears
            float mAvoidWaitLeft = 0.f;
            float mAvoidResume = 0.f; // clear time still needed before walking on
            bool mWaitedOut = false; // waited the whole time for the same blocker
            float mIgnoreTime = 0.f; // no new reaction after going around
            int mDetours = 0; // side steps added to this path
        };

        // Returns false when the actor is done with this state (stopped, arrived and turned).
        bool updateActor(const MWWorld::Ptr& ptr, State& state, float duration);
        // Looks ahead along the path for other actors (and the player) in the way, as the original does: after
        // being blocked for a moment it waits for someone standing still and goes around someone moving. True
        // while the actor waits.
        bool avoidActors(const MWWorld::Ptr& ptr, State& state, float speed, float duration);
        void startUsing(const MWWorld::Ptr& ptr, State& state);
        void finishUsing(const MWWorld::Ptr& ptr, State& state);
        // Resumes the loop an idle interrupted: the seated loop or the standing idle.
        void resumeLoop(const MWWorld::Ptr& ptr, State& state);

        ESM4Navigation mNavigation;
        std::map<ESM::RefNum, State> mStates;
        // Actor -> what its head follows (the player has no RefNum of its own, hence the flag)
        struct LookTarget
        {
            ESM::RefNum mTarget;
            bool mPlayer = false;
        };
        std::map<ESM::RefNum, LookTarget> mLookTargets;
        void updateLookTargets();
        std::mt19937 mRandom{ std::random_device{}() };
    };
}

#endif
