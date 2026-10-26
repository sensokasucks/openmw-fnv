#ifndef GAME_MWCLASS_ESM4BASE_H
#define GAME_MWCLASS_ESM4BASE_H

#include <components/esm4/inventory.hpp>
#include <components/esm4/loadidlm.hpp>
#include <components/esm4/loadstat.hpp>
#include <components/esm4/loadtree.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"

#include "../mwgui/tooltips.hpp"

#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/registeredclass.hpp"

#include "classmodel.hpp"

namespace MWClass
{

    namespace ESM4Impl
    {
        void insertObjectRendering(
            const MWWorld::Ptr& ptr, const std::string& model, MWRender::RenderingInterface& renderingInterface);
        void insertObjectPhysics(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics);
        MWGui::ToolTipInfo getToolTipInfo(std::string_view name, int count);

        // Gives an FO3/FNV NPC or creature the body other actors collide with (see PhysicsSystem::addActorBody).
        // halfExtents is used when the actor's rendered model has no usable bounds, or always when fromBounds is
        // false. The body is off for dead actors.
        void insertActorBody(const MWWorld::Ptr& ptr, const osg::Quat& rotation, MWPhysics::PhysicsSystem& physics,
            osg::Vec3f halfExtents, bool fromBounds);

        // Starts the object's ambient loop (ACTI/MSTT looping sound, LIGH sound) at its position. Sounds the game
        // plays at random times (SOUN flag Play At Random) are left out.
        void playLoopingSound(const MWWorld::Ptr& ptr, ESM::FormId sound);

        // Makes the sequence embedded in the object's model (e.g. "open" of a footlocker) playable through the
        // mechanics manager. Returns false if the model has no such sequence.
        bool prepareEmbeddedAnimation(const MWWorld::Ptr& ptr, std::string_view group);

        // Plays a sequence embedded in the object's model once and holds its last frame, like the original engine
        // does for PlayGroup and SetOpenState. Returns false if the model has no such sequence.
        bool playEmbeddedAnimation(const MWWorld::Ptr& ptr, std::string_view group);

        // We don't handle ESM4 player stats yet, so for resolving levelled object we use an arbitrary number.
        constexpr int sDefaultLevel = 5;

        template <class LevelledRecord, class TargetRecord>
        const TargetRecord* resolveLevelled(const ESM::RefId& id, int level = sDefaultLevel)
        {
            if (id.empty())
                return nullptr;
            const MWWorld::ESMStore* esmStore = MWBase::Environment::get().getESMStore();
            const auto& targetStore = esmStore->get<TargetRecord>();
            const TargetRecord* res = targetStore.search(id);
            if (res)
                return res;
            const LevelledRecord* lvlRec = esmStore->get<LevelledRecord>().search(id);
            if (!lvlRec)
                return nullptr;
            for (const ESM4::LVLO& obj : lvlRec->mLvlObject)
            {
                ESM::RefId candidateId = ESM::FormId::fromUint32(obj.item);
                if (candidateId == id)
                    continue;
                const TargetRecord* candidate = resolveLevelled<LevelledRecord, TargetRecord>(candidateId, level);
                if (candidate && (!res || obj.level <= level))
                    res = candidate;
            }
            return res;
        }

        // TODO: Figure out a better way to find markers and LOD meshes
        inline bool isMarkerModel(std::string_view model)
        {
            return Misc::StringUtils::ciStartsWith(model, "marker");
        }
        inline bool isLodModel(std::string_view model)
        {
            return Misc::StringUtils::ciEndsWith(model, "lod.nif");
        }
    }

    // Base for many ESM4 Classes
    template <typename Record>
    class ESM4Base : public MWWorld::Class
    {
        MWWorld::Ptr copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const override
        {
            const MWWorld::LiveCellRef<Record>* ref = ptr.get<Record>();
            return MWWorld::Ptr(cell.insert(ref), &cell);
        }

    protected:
        explicit ESM4Base(unsigned type)
            : MWWorld::Class(type)
        {
        }

    public:
        void insertObjectRendering(const MWWorld::Ptr& ptr, const std::string& model,
            MWRender::RenderingInterface& renderingInterface) const override
        {
            ESM4Impl::insertObjectRendering(ptr, model, renderingInterface);
        }

        void insertObject(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override
        {
            insertObjectPhysics(ptr, model, rotation, physics);
            if constexpr (requires { ptr.get<Record>()->mBase->mLoopingSound; })
                ESM4Impl::playLoopingSound(ptr, ptr.get<Record>()->mBase->mLoopingSound);
        }

        void insertObjectPhysics(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override
        {
            ESM4Impl::insertObjectPhysics(ptr, model, rotation, physics);
        }

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override { return false; }

        std::string_view getName(const MWWorld::ConstPtr& ptr) const override { return {}; }

        VFS::Path::NormalizedView getModel(const MWWorld::ConstPtr& ptr) const override
        {
            const VFS::Path::NormalizedView model = getClassModel<Record>(ptr);

            // TODO: There should be a better way to hide markers
            if (ESM4Impl::isMarkerModel(model.value()) || ESM4Impl::isLodModel(model.value()))
                return {};

            return model;
        }
    };

    class ESM4Static final : public MWWorld::RegisteredClass<ESM4Static, ESM4Base<ESM4::Static>>
    {
        friend MWWorld::RegisteredClass<ESM4Static, ESM4Base<ESM4::Static>>;
        ESM4Static()
            : MWWorld::RegisteredClass<ESM4Static, ESM4Base<ESM4::Static>>(ESM4::Static::sRecordId)
        {
        }
    };

    // FO3/FONV idle markers: invisible spots where AI packages play the marker's idle animations.
    class ESM4IdleMarker final : public MWWorld::RegisteredClass<ESM4IdleMarker, ESM4Base<ESM4::IdleMarker>>
    {
        friend MWWorld::RegisteredClass<ESM4IdleMarker, ESM4Base<ESM4::IdleMarker>>;
        ESM4IdleMarker()
            : MWWorld::RegisteredClass<ESM4IdleMarker, ESM4Base<ESM4::IdleMarker>>(ESM4::IdleMarker::sRecordId)
        {
        }

    public:
        VFS::Path::NormalizedView getModel(const MWWorld::ConstPtr& ptr) const override { return {}; }
    };

    class ESM4Tree final : public MWWorld::RegisteredClass<ESM4Tree, ESM4Base<ESM4::Tree>>
    {
        friend MWWorld::RegisteredClass<ESM4Tree, ESM4Base<ESM4::Tree>>;
        ESM4Tree()
            : MWWorld::RegisteredClass<ESM4Tree, ESM4Base<ESM4::Tree>>(ESM4::Tree::sRecordId)
        {
        }
    };

    // For records with `mFullName` that should be shown as a tooltip.
    // All objects with a tooltip can be activated (activation can be handled in Lua).
    template <typename Record>
    class ESM4Named : public MWWorld::RegisteredClass<ESM4Named<Record>, ESM4Base<Record>>
    {
    public:
        ESM4Named()
            : MWWorld::RegisteredClass<ESM4Named, ESM4Base<Record>>(Record::sRecordId)
        {
        }

        std::string_view getName(const MWWorld::ConstPtr& ptr) const override
        {
            return ptr.get<Record>()->mBase->mFullName;
        }

        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override
        {
            return ESM4Impl::getToolTipInfo(getName(ptr), count);
        }

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override { return !getName(ptr).empty(); }
    };
}

#endif // GAME_MWCLASS_ESM4BASE_H
