#include "obscriptbindings.hpp"

#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <string_view>

#include <sol/state_view.hpp>
#include <sol/table.hpp>
#include <sol/usertype.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm4/loadalch.hpp>
#include <components/esm4/loadammo.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadbook.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loaddoor.hpp>
#include <components/esm4/loadingr.hpp>
#include <components/esm4/loadmesg.hpp>
#include <components/esm4/loadmisc.hpp>
#include <components/esm4/loadrefr.hpp>
#include <components/esm4/loadscpt.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/lower.hpp>

#include "../mwbase/environment.hpp"
#include "../mwclass/esm4base.hpp"
#include "../mwclass/esm4door.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/store.hpp"

#include "context.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"

namespace sol
{
    template <>
    struct is_automagical<ESM4::Script> : std::false_type
    {
    };

    template <>
    struct is_automagical<MWWorld::Store<ESM4::Script>> : std::false_type
    {
    };
}

namespace MWLua
{
    sol::table initCoreObScriptBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        auto recordBindingsClass = lua.new_usertype<ESM4::Script>("ESM4_Script");
        recordBindingsClass[sol::meta_function::to_string]
            = [](const ESM4::Script& rec) { return "ESM4_Script[" + ESM::RefId(rec.mId).toDebugString() + "]"; };
        recordBindingsClass["id"] = sol::readonly_property(
            [](const ESM4::Script& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        recordBindingsClass["editorId"]
            = sol::readonly_property([](const ESM4::Script& rec) -> std::string_view { return rec.mEditorId; });
        recordBindingsClass["text"] = sol::readonly_property(
            [](const ESM4::Script& rec) -> std::string_view { return rec.mScript.scriptSource; });

        using StoreT = MWWorld::Store<ESM4::Script>;
        sol::usertype<StoreT> storeBindingsClass = lua.new_usertype<StoreT>("ESM4_Script Store");
        storeBindingsClass[sol::meta_function::to_string]
            = [](const StoreT& store) { return "{" + std::to_string(store.getSize()) + " ESM4_Script records}"; };
        storeBindingsClass[sol::meta_function::length] = [](const StoreT& store) { return store.getSize(); };
        storeBindingsClass[sol::meta_function::index] = sol::overload(
            [](const StoreT& store, size_t index) -> const ESM4::Script* {
                if (index == 0 || index > store.getSize())
                    return nullptr;
                return store.at(LuaUtil::fromLuaIndex(index));
            },
            [](const StoreT& store, std::string_view id) -> const ESM4::Script* {
                return store.search(ESM::RefId::deserializeText(id));
            });
        storeBindingsClass[sol::meta_function::ipairs] = lua["ipairsForArray"].get<sol::function>();
        storeBindingsClass[sol::meta_function::pairs] = lua["ipairsForArray"].get<sol::function>();

        api["records"] = &MWBase::Environment::get().getESMStore()->get<ESM4::Script>();

        // Case-insensitive editor-id lookup, built lazily on first use.
        using EditorIdIndex = std::map<std::string, ESM::RefId>;
        auto resolve = [](const EditorIdIndex& index, std::string_view editorId) -> sol::optional<std::string> {
            auto it = index.find(Misc::StringUtils::lowerCase(editorId));
            if (it == index.end())
                return sol::nullopt;
            return it->second.serializeText();
        };

        // Item record types, for ObScript arguments like `player.AddItem <EditorId> <count>`.
        api["resolveItemEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                auto addAll = [&](const auto& s) {
                    for (size_t i = 0; i < s.getSize(); ++i)
                    {
                        const auto& record = *s.at(i);
                        if (!record.mEditorId.empty())
                            res.emplace(Misc::StringUtils::lowerCase(record.mEditorId), ESM::RefId(record.mId));
                    }
                };
                addAll(store.get<ESM4::Ammunition>());
                addAll(store.get<ESM4::Armor>());
                addAll(store.get<ESM4::Book>());
                addAll(store.get<ESM4::Clothing>());
                addAll(store.get<ESM4::Ingredient>());
                addAll(store.get<ESM4::MiscItem>());
                addAll(store.get<ESM4::Potion>());
                addAll(store.get<ESM4::Weapon>());
                return res;
            }();
            return resolve(index, editorId);
        };

        // Persistent placed references (e.g. `GSSchoolTerminal01Ref.Disable`).
        api["resolveRefEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                const MWWorld::Store<ESM4::Reference>& refs = store.get<ESM4::Reference>();
                for (size_t i = 0; i < refs.getSize(); ++i)
                {
                    const ESM4::Reference& ref = *refs.at(i);
                    if (!ref.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(ref.mEditorId), ESM::RefId(ref.mId));
                }
                return res;
            }();
            return resolve(index, editorId);
        };

        // Message boxes (MESG) for `ShowMessage <EditorId> [args...]`.
        // Returns { title=, text=, buttons={...}, messageBox=bool, displayTime=n } or nil.
        api["getMessage"] = [lua](std::string_view editorId) -> sol::object {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                const MWWorld::Store<ESM4::Message>& msgs = store.get<ESM4::Message>();
                for (size_t i = 0; i < msgs.getSize(); ++i)
                {
                    const ESM4::Message& msg = *msgs.at(i);
                    if (!msg.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(msg.mEditorId), ESM::RefId(msg.mId));
                }
                return res;
            }();
            auto it = index.find(Misc::StringUtils::lowerCase(editorId));
            if (it == index.end())
                return sol::nil;
            const ESM4::Message* msg
                = MWBase::Environment::get().getESMStore()->get<ESM4::Message>().search(it->second);
            if (msg == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["title"] = msg->mFullName;
            res["text"] = msg->mText;
            res["messageBox"] = (msg->mMessageFlags & ESM4::Message::Flag_MessageBox) != 0;
            res["displayTime"] = msg->mDisplayTime;
            sol::table buttons(lua, sol::create);
            for (size_t i = 0; i < msg->mButtons.size(); ++i)
                buttons[LuaUtil::toLuaIndex(i)] = msg->mButtons[i];
            res["buttons"] = buttons;
            return res;
        };

        // Half extents of a placed trigger volume (REFR XPRM), nil when the reference has none.
        api["getPrimitiveBounds"] = [](const Object& object) -> sol::optional<osg::Vec3f> {
            const osg::Vec3f bounds = object.ptr().getCellRef().getPrimitiveBounds();
            if (bounds.x() <= 0.f && bounds.y() <= 0.f && bounds.z() <= 0.f)
                return sol::nullopt;
            return bounds;
        };

        // Sequences embedded in the object's model (NiControllerSequences such as "Forward" of a lever or "Open" of a
        // terminal). Group names are lower case. Plays once and holds the last frame.
        api["playEmbeddedGroup"] = [context](const Object& object, std::string_view group) {
            context.mLuaManager->addAction(
                [object = Object(object), group = Misc::StringUtils::lowerCase(group)] {
                    // Some scripts play a group every frame, so report each missing group once.
                    static std::set<std::string> reported;
                    if (!MWClass::ESM4Impl::playEmbeddedAnimation(object.ptr(), group) && reported.insert(group).second)
                        Log(Debug::Verbose)
                            << "[obscript] no embedded animation \"" << group << "\" on " << object.id().toString();
                },
                "obscriptPlayEmbeddedGroupAction");
        };

        // SetOpenState: doors keep their own open state, other objects (terminals, switches, containers) play their
        // "Open" or "Close" sequence.
        api["setOpenState"] = [context](const Object& object, bool open) {
            context.mLuaManager->addAction(
                [object = Object(object), open] {
                    const MWWorld::Ptr& ptr = object.ptr();
                    if (ptr.getType() == ESM4::Door::sRecordId)
                    {
                        if (MWClass::ESM4Door::isOpen(ptr) != open)
                            MWClass::ESM4Door::toggle(ptr);
                        return;
                    }
                    MWClass::ESM4Impl::playEmbeddedAnimation(ptr, open ? "open" : "close");
                },
                "obscriptSetOpenStateAction");
        };

        // Whether a door is open; nil for anything else.
        api["isDoorOpen"] = [](const Object& object) -> sol::optional<bool> {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM4::Door::sRecordId)
                return sol::nullopt;
            return MWClass::ESM4Door::isOpen(ptr);
        };

        // Opt-in runtime tracing (OPENMW_OBSCRIPT_TRACE=1); the Lua sandbox has no os.getenv.
        api["traceEnabled"] = [] {
            const char* value = std::getenv("OPENMW_OBSCRIPT_TRACE");
            return value != nullptr && *value != '\0' && std::string_view(value) != "0";
        }();

        return LuaUtil::makeReadOnly(api);
    }
}
