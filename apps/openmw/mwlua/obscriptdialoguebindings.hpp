#ifndef MWLUA_OBSCRIPTDIALOGUEBINDINGS_H
#define MWLUA_OBSCRIPTDIALOGUEBINDINGS_H

#include <vector>

#include <sol/forward.hpp>

namespace ESM4
{
    struct DialogCondition;
}

namespace MWLua
{
    struct Context;

    // `core.obscript.dialogue`: read access to ESM4 dialogue records (DIAL,
    // INFO, QUST, GLOB) for the Lua dialogue system.
    sol::table initObScriptDialogueBindings(const Context& context);

    // CTDA list in the shape scripts/omw/fnvdialogue/conditions.lua evaluates.
    sol::table makeObScriptConditions(sol::state_view& lua, const std::vector<ESM4::DialogCondition>& conditions);
}

#endif // MWLUA_OBSCRIPTDIALOGUEBINDINGS_H
