#ifndef MWLUA_OBSCRIPTDIALOGUEBINDINGS_H
#define MWLUA_OBSCRIPTDIALOGUEBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.dialogue`: read access to ESM4 dialogue records (DIAL,
    // INFO, QUST, GLOB) for the Lua dialogue system.
    sol::table initObScriptDialogueBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTDIALOGUEBINDINGS_H
