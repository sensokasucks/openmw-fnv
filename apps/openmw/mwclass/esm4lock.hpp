#ifndef GAME_MWCLASS_ESM4LOCK_H
#define GAME_MWCLASS_ESM4LOCK_H

#include <string>

namespace MWWorld
{
    class Ptr;
    class ConstPtr;
}

namespace MWClass::ESM4Lock
{
    // Locks on FO3/FNV doors and containers. Returns true if `ptr` is unlocked or `actor` just unlocked it,
    // either with the matching key or (player only) by picking it. Shows the player why it stays shut.
    //
    // Picking has no minigame yet: it succeeds when the player has a bobby pin and their skill reaches the
    // lock level. The skill is the FNV Lockpick actor value (see ESM4Stats).
    bool tryOpen(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor);

    // Tooltip line such as "Lock: Average (50)", or empty if not locked.
    std::string describe(const MWWorld::ConstPtr& ptr);
}

#endif // GAME_MWCLASS_ESM4LOCK_H
