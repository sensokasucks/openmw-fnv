#ifndef MWLUA_OBSCRIPTRADIOBINDINGS_H
#define MWLUA_OBSCRIPTRADIOBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.radio`: FNV radio stations (TACT references), their audio, and the records of the
    // location music system (audio markers, ALOC media location controllers, MSET media sets, MUSC).
    sol::table initObScriptRadioBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTRADIOBINDINGS_H
