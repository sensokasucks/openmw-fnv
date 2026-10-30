#ifndef MWLUA_OBSCRIPTEFFECTBINDINGS_H
#define MWLUA_OBSCRIPTEFFECTBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.effects`: read access to FO3/FNV magic effects (MGEF),
    // actor effects (SPEL), object effects (ENCH) and the effect lists of
    // ingestibles (ALCH), for scripts/omw/fnveffects.
    sol::table initObScriptEffectBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTEFFECTBINDINGS_H
