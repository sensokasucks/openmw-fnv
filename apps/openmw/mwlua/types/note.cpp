#include "types.hpp"

#include "modelproperty.hpp"

#include <components/esm4/loadnote.hpp>
#include <components/lua/utilpackage.hpp>

namespace sol
{
    template <>
    struct is_automagical<ESM4::Note> : std::false_type
    {
    };
}

namespace MWLua
{

    void addESM4NoteBindings(sol::table note, const Context& context)
    {
        addRecordFunctionBinding<ESM4::Note>(note, context, "ESM4Note");

        sol::usertype<ESM4::Note> record = context.sol().new_usertype<ESM4::Note>("ESM4_Note");
        record[sol::meta_function::to_string] = [](const ESM4::Note& rec) -> std::string {
            return "ESM4_Note[" + ESM::RefId(rec.mId).toDebugString() + "]";
        };
        record["id"] = sol::readonly_property(
            [](const ESM4::Note& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        record["editorId"] = sol::readonly_property([](const ESM4::Note& rec) -> std::string { return rec.mEditorId; });
        record["name"] = sol::readonly_property([](const ESM4::Note& rec) -> std::string { return rec.mFullName; });
        record["noteType"] = sol::readonly_property([](const ESM4::Note& rec) -> std::string_view {
            switch (rec.mNoteType)
            {
                case ESM4::Note::Type_Sound:
                    return "Sound";
                case ESM4::Note::Type_Text:
                    return "Text";
                case ESM4::Note::Type_Image:
                    return "Image";
                case ESM4::Note::Type_Voice:
                    return "Voice";
                default:
                    return "Unknown";
            }
        });
        record["text"] = sol::readonly_property([](const ESM4::Note& rec) -> std::string { return rec.mText; });
        record["texture"] = sol::readonly_property([](const ESM4::Note& rec) -> std::string { return rec.mTexture; });
        record["sound"] = sol::readonly_property([](const ESM4::Note& rec) -> sol::optional<std::string> {
            if (rec.mSound.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(rec.mSound).serializeText();
        });
        record["topic"] = sol::readonly_property([](const ESM4::Note& rec) -> sol::optional<std::string> {
            if (rec.mTopic.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(rec.mTopic).serializeText();
        });
        record["pickUpSound"] = sol::readonly_property([](const ESM4::Note& rec) -> sol::optional<std::string> {
            if (rec.mPickUpSound.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(rec.mPickUpSound).serializeText();
        });
        addModelProperty(record);
    }
}
