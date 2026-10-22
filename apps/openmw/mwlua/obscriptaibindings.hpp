#ifndef MWLUA_OBSCRIPTAIBINDINGS_H
#define MWLUA_OBSCRIPTAIBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.ai`: FO3/FONV AI packages of ESM4 NPCs and navmesh movement, for scripts/omw/fnvai.
    sol::table initObScriptAIBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTAIBINDINGS_H
