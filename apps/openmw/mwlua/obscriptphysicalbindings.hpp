#ifndef MWLUA_OBSCRIPTPHYSICALBINDINGS_H
#define MWLUA_OBSCRIPTPHYSICALBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    // `core.obscript.physical`: the physical state of FO3/FONV actors (posture, limbs, bleeding) that physics and
    // gore write and the AI reads (MWMechanics::ESM4Physical).
    sol::table initObScriptPhysicalBindings(const Context& context);
}

#endif // MWLUA_OBSCRIPTPHYSICALBINDINGS_H
