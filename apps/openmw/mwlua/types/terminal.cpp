#include "types.hpp"

#include "modelproperty.hpp"

#include <components/esm4/loadterm.hpp>
#include <components/lua/util.hpp>
#include <components/lua/utilpackage.hpp>
#include <components/misc/convert.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/resource/resourcesystem.hpp>

namespace sol
{
    template <>
    struct is_automagical<ESM4::Terminal> : std::false_type
    {
    };
}

namespace MWLua
{

    void addESM4TerminalBindings(sol::table term, const Context& context)
    {
        addRecordFunctionBinding<ESM4::Terminal>(term, context, "ESM4Terminal");

        sol::usertype<ESM4::Terminal> record = context.sol().new_usertype<ESM4::Terminal>("ESM4_Terminal");
        record[sol::meta_function::to_string] = [](const ESM4::Terminal& rec) -> std::string {
            return "ESM4_Terminal[" + ESM::RefId(rec.mId).toDebugString() + "]";
        };
        record["id"] = sol::readonly_property(
            [](const ESM4::Terminal& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        record["editorId"]
            = sol::readonly_property([](const ESM4::Terminal& rec) -> std::string { return rec.mEditorId; });
        record["text"] = sol::readonly_property([](const ESM4::Terminal& rec) -> std::string { return rec.mText; });
        record["difficulty"] = sol::readonly_property([](const ESM4::Terminal& rec) -> int { return rec.mDifficulty; });
        record["flags"] = sol::readonly_property([](const ESM4::Terminal& rec) -> int { return rec.mTerminalFlags; });
        record["passwordNote"] = sol::readonly_property([](const ESM4::Terminal& rec) -> sol::optional<std::string> {
            if (rec.mPasswordNote.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(rec.mPasswordNote).serializeText();
        });
        record["items"] = sol::readonly_property([lua = context.sol()](const ESM4::Terminal& rec) {
            auto formIdOrNil = [](ESM::FormId id) -> sol::optional<std::string> {
                if (id.isZeroOrUnset())
                    return sol::nullopt;
                return ESM::RefId(id).serializeText();
            };
            sol::table items(lua, sol::create);
            for (size_t i = 0; i < rec.mItems.size(); ++i)
            {
                const ESM4::TerminalItem& item = rec.mItems[i];
                sol::table t(lua, sol::create);
                t["text"] = item.mText;
                t["resultText"] = item.mResultText;
                t["flags"] = item.mFlags;
                t["addNote"] = (item.mFlags & ESM4::TerminalItem::Flag_AddNote) != 0;
                t["forceRedraw"] = (item.mFlags & ESM4::TerminalItem::Flag_ForceRedraw) != 0;
                t["note"] = formIdOrNil(item.mDisplayNote);
                t["subMenu"] = formIdOrNil(item.mSubMenu);
                t["script"] = item.mScriptSource;
                t["hasConditions"] = item.mHasConditions;
                items[LuaUtil::toLuaIndex(i)] = t;
            }
            return items;
        });
        record["name"] = sol::readonly_property([](const ESM4::Terminal& rec) -> std::string { return rec.mFullName; });
        addModelProperty(record);
    }
}
