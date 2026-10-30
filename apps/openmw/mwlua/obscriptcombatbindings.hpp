#ifndef MWLUA_OBSCRIPTCOMBATBINDINGS_H
#define MWLUA_OBSCRIPTCOMBATBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.combat`: FO3/FONV weapons, shooting and death, for scripts/omw/fnvcombat.
    sol::table initObScriptCombatBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTCOMBATBINDINGS_H
