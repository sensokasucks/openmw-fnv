#include "types.hpp"

#include "modelproperty.hpp"

#include <string>
#include <vector>

#include <components/esm4/loadidlm.hpp>
#include <components/lua/utilpackage.hpp>

#include "../luamanagerimp.hpp"

namespace sol
{
    template <>
    struct is_automagical<ESM4::IdleMarker> : std::false_type
    {
    };
}

namespace MWLua
{
    void addESM4IdleMarkerBindings(sol::table idlm, const Context& context)
    {
        addRecordFunctionBinding<ESM4::IdleMarker>(idlm, context, "ESM4IdleMarker");

        sol::usertype<ESM4::IdleMarker> record = context.sol().new_usertype<ESM4::IdleMarker>("ESM4_IdleMarker");
        record[sol::meta_function::to_string] = [](const ESM4::IdleMarker& rec) -> std::string {
            return "ESM4_IdleMarker[" + ESM::RefId(rec.mId).toDebugString() + "]";
        };
        record["id"] = sol::readonly_property(
            [](const ESM4::IdleMarker& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        record["editorId"]
            = sol::readonly_property([](const ESM4::IdleMarker& rec) -> std::string { return rec.mEditorId; });
        // IDLF: 1 = run in sequence, 4 = do once
        record["idleFlags"]
            = sol::readonly_property([](const ESM4::IdleMarker& rec) -> int { return rec.mIdleFlags; });
        // Seconds an actor stays at the marker (0: the package decides)
        record["idleTimer"]
            = sol::readonly_property([](const ESM4::IdleMarker& rec) -> float { return rec.mIdleTimer; });
        // Form ids of the IDLE records played at the marker (see core.obscript.ai.getIdles)
        record["idles"] = sol::readonly_property([](const ESM4::IdleMarker& rec) {
            std::vector<std::string> res;
            for (ESM::FormId id : rec.mIdleAnim)
                if (!id.isZeroOrUnset())
                    res.push_back(ESM::RefId(id).serializeText());
            return sol::as_table(res);
        });
        addModelProperty(record);
    }
}
