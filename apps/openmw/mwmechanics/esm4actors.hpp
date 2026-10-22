#ifndef GAME_MWMECHANICS_ESM4ACTORS_H
#define GAME_MWMECHANICS_ESM4ACTORS_H

#include <map>
#include <optional>
#include <random>
#include <string>

#include <osg/Vec3f>

#include <components/esm3/refnum.hpp>

#include "esm4navigation.hpp"

namespace MWWorld
{
    class Ptr;
}

namespace MWMechanics
{
    // Moves FO3/FONV NPCs along their cell's navmesh and plays their idle and furniture sequences. What to do is
    // decided by the AI packages, evaluated in Lua (scripts/omw/fnvai); this only walks there, turns the NPC,
    // switches its walk/idle sequences and runs the enter/loop/exit steps of using a chair, bed or lean marker.
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
        std::mt19937& getRandom() { return mRandom; }

        // False when no route exists (the status is then NoPath).
        bool moveTo(const MWWorld::Ptr& ptr, const osg::Vec3f& target, const MoveOptions& options);
        void stop(const MWWorld::Ptr& ptr);
        // Turns in place.
        void face(const MWWorld::Ptr& ptr, float yaw);
        Status getStatus(const MWWorld::Ptr& ptr) const;

        // Starts using furniture: the actor is placed on the marker and plays the entry sequence. Any movement stops.
        void useFurniture(const MWWorld::Ptr& ptr, const FurnitureUse& use);
        // Plays the exit sequence; the actor stands on the marker again once it ends.
        void leaveFurniture(const MWWorld::Ptr& ptr);
        UsePhase getUsePhase(const MWWorld::Ptr& ptr) const;
        // Plays an idle sequence once (standing or seated), then returns to the idle or seated loop.
        void playIdle(const MWWorld::Ptr& ptr, const std::string& model);
        bool isIdlePlaying(const MWWorld::Ptr& ptr) const;

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

            UsePhase mUsePhase = UsePhase::None;
            FurnitureUse mFurniture;
            float mPhaseTimer = 0.f; // seconds left in the entry or exit sequence
            float mIdleTimer = 0.f; // seconds left in a one-shot idle, 0 when none plays
        };

        // Returns false when the actor is done with this state (stopped, arrived and turned).
        bool updateActor(const MWWorld::Ptr& ptr, State& state, float duration);
        void startUsing(const MWWorld::Ptr& ptr, State& state);
        void finishUsing(const MWWorld::Ptr& ptr, State& state);
        // Resumes the loop an idle interrupted: the seated loop or the standing idle.
        void resumeLoop(const MWWorld::Ptr& ptr, State& state);

        ESM4Navigation mNavigation;
        std::map<ESM::RefNum, State> mStates;
        std::mt19937 mRandom{ std::random_device{}() };
    };
}

#endif
