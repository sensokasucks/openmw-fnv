#ifndef MWLUA_OBSCRIPTSTATSBINDINGS_H
#define MWLUA_OBSCRIPTSTATSBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.stats`: FO3/FNV actor values (SPECIAL, skills, ...) and levels of the player and
    // ESM4 NPCs, see MWClass::ESM4Stats.
    sol::table initObScriptStatsBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTSTATSBINDINGS_H
