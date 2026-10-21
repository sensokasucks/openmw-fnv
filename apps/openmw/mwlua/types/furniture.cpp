#include "types.hpp"

#include "modelproperty.hpp"

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadfurn.hpp>
#include <components/lua/utilpackage.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/nif/extra.hpp>
#include <components/nif/niffile.hpp>
#include <components/resource/niffilemanager.hpp>
#include <components/resource/resourcesystem.hpp>

#include "apps/openmw/mwbase/environment.hpp"
#include "apps/openmw/mwbase/world.hpp"

#include "../luamanagerimp.hpp"
#include "../object.hpp"

namespace sol
{
    template <>
    struct is_automagical<ESM4::Furniture> : std::false_type
    {
    };
}

namespace MWLua
{
    namespace
    {
        // Furniture markers (BSFurnitureMarker) on the root of the furniture model. Offsets are in model space;
        // a heading is the yaw the actor faces at that point (FO3/FNV store it in milliradians).
        sol::table getFurnitureMarkers(sol::state_view lua, const ESM4::Furniture& rec)
        {
            sol::table result(lua, sol::create);
            if (rec.mModel.empty())
                return result;
            const VFS::Path::Normalized path = Misc::ResourceHelpers::correctMeshPath(rec.mModel.getNormalized());
            Nif::NIFFilePtr file;
            try
            {
                file = MWBase::Environment::get().getResourceSystem()->getNifFileManager()->get(path);
            }
            catch (const std::exception& e)
            {
                Log(Debug::Warning) << "Can't read furniture markers from " << path << ": " << e.what();
                return result;
            }

            const Nif::FileView view(*file);
            for (std::size_t i = 0; i < view.numRoots(); ++i)
            {
                const auto* root = dynamic_cast<const Nif::NiObjectNET*>(view.getRoot(i));
                if (root == nullptr)
                    continue;
                for (const Nif::ExtraPtr& extra : root->getExtraList())
                {
                    const auto* marker = dynamic_cast<const Nif::BSFurnitureMarker*>(extra.getPtr());
                    if (marker == nullptr)
                        continue;
                    for (const auto& pos : marker->mLegacyMarkers)
                    {
                        sol::table m(lua, sol::create);
                        m["index"] = result.size();
                        m["offset"] = pos.mOffset;
                        m["heading"] = pos.mOrientation / 1000.f;
                        m["type"] = pos.mPositionRef;
                        result.add(m);
                    }
                    for (const auto& pos : marker->mMarkers)
                    {
                        sol::table m(lua, sol::create);
                        m["index"] = result.size();
                        m["offset"] = pos.mOffset;
                        m["heading"] = pos.mHeading;
                        m["type"] = pos.mType;
                        m["entryPoint"] = pos.mEntryPoint;
                        result.add(m);
                    }
                }
            }
            return result;
        }
    }

    void addESM4FurnitureBindings(sol::table furn, const Context& context)
    {
        addRecordFunctionBinding<ESM4::Furniture>(furn, context, "ESM4Furniture");

        furn["markers"] = [](sol::this_state lua, const Object& o) {
            const MWWorld::Ptr& ptr = verifyType(ESM::REC_FURN4, o.ptr());
            return getFurnitureMarkers(lua, *ptr.get<ESM4::Furniture>()->mBase);
        };

        // Used by the activation handler while the player is seated; the physics actor would otherwise be
        // pushed out of the furniture's collision.
        furn["_setActorCollision"] = [context](const GObject& actor, bool enabled) {
            context.mLuaManager->addAction(
                [actor, enabled] {
                    const MWWorld::Ptr& ptr = actor.ptr();
                    MWBase::Environment::get().getWorld()->setActorCollisionMode(ptr, enabled, enabled);
                },
                "SetActorCollisionAction");
        };

        sol::usertype<ESM4::Furniture> record = context.sol().new_usertype<ESM4::Furniture>("ESM4_Furniture");
        record[sol::meta_function::to_string] = [](const ESM4::Furniture& rec) -> std::string {
            return "ESM4_Furniture[" + ESM::RefId(rec.mId).toDebugString() + "]";
        };
        record["id"] = sol::readonly_property(
            [](const ESM4::Furniture& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        record["editorId"]
            = sol::readonly_property([](const ESM4::Furniture& rec) -> std::string { return rec.mEditorId; });
        record["name"]
            = sol::readonly_property([](const ESM4::Furniture& rec) -> std::string { return rec.mFullName; });
        record["activeMarkerFlags"] = sol::readonly_property(
            [](const ESM4::Furniture& rec) -> std::uint32_t { return rec.mActiveMarkerFlags; });
        addModelProperty(record);
    }
}
