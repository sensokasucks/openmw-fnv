#ifndef GAME_MWMECHANICS_ESM4ACTORS_H
#define GAME_MWMECHANICS_ESM4ACTORS_H

#include <map>
#include <optional>
#include <random>
#include <string_view>

#include <osg/Vec3f>

#include <components/esm3/refnum.hpp>

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

        // Plays a one-off sequence (an attack) and goes back to walking or standing when it ends. Returns its length,
        // 0 when the actor has no such sequence.
        float playAction(const MWWorld::Ptr& ptr, std::string_view file);
        bool isActing(const MWWorld::Ptr& ptr) const;

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
        };

        // Returns false when the actor is done with this state (stopped, arrived and turned).
        bool updateActor(const MWWorld::Ptr& ptr, State& state, float duration);

        ESM4Navigation mNavigation;
        std::map<ESM::RefNum, State> mStates;
        std::mt19937 mRandom{ std::random_device{}() };
    };
}

#endif
