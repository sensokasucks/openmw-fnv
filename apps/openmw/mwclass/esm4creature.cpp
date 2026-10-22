#include "esm4creature.hpp"

#include <algorithm>

#include <components/esm4/loadlvlc.hpp>

#include "../mwgui/tooltips.hpp"
#include "../mwrender/objects.hpp"
#include "../mwrender/renderinginterface.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/customdata.hpp"
#include "../mwworld/esmstore.hpp"

#include "esm4base.hpp"

namespace MWClass
{
    namespace
    {
        // Same bits as ESM4::Npc::Template_*
        enum TemplateFlags : std::uint16_t
        {
            UseStats = 0x0002,
            UseAIData = 0x0010,
            UseAIPackages = 0x0020,
            UseModel = 0x0040,
            UseBaseData = 0x0080,
        };

        class ESM4CreatureCustomData : public MWWorld::TypedCustomData<ESM4CreatureCustomData>
        {
        public:
            const ESM4::Creature* mModel = nullptr;
            const ESM4::Creature* mStats = nullptr;
            const ESM4::Creature* mAIData = nullptr;
            const ESM4::Creature* mAIPackages = nullptr;
            const ESM4::Creature* mBaseData = nullptr;
        };

        // The record itself followed by the records its template chain resolves to.
        std::vector<const ESM4::Creature*> templateChain(const ESM4::Creature* rec)
        {
            std::vector<const ESM4::Creature*> chain{ rec };
            while (!rec->mBaseTemplate.isZeroOrUnset() && chain.size() < 16)
            {
                const ESM4::Creature* next
                    = ESM4Impl::resolveLevelled<ESM4::LevelledCreature, ESM4::Creature>(rec->mBaseTemplate);
                if (next == nullptr || std::find(chain.begin(), chain.end(), next) != chain.end())
                    break;
                chain.push_back(rec = next);
            }
            return chain;
        }

        const ESM4::Creature* choose(const std::vector<const ESM4::Creature*>& chain, std::uint16_t flag)
        {
            for (const ESM4::Creature* rec : chain)
                if (!(rec->mBaseConfig.fo3.templateFlags & flag) || rec->mBaseTemplate.isZeroOrUnset())
                    return rec;
            return chain.back();
        }

        const ESM4CreatureCustomData& getCustomData(const MWWorld::ConstPtr& ptr)
        {
            // getModel and getName take a ConstPtr, see ESM4Npc::getCustomData
            MWWorld::RefData& refData = const_cast<MWWorld::RefData&>(ptr.getRefData());
            if (MWWorld::CustomData* data = refData.getCustomData())
                if (auto* creatureData = dynamic_cast<ESM4CreatureCustomData*>(data))
                    return *creatureData;

            auto data = std::make_unique<ESM4CreatureCustomData>();
            const ESM4::Creature* base = ptr.get<ESM4::Creature>()->mBase;
            const std::vector<const ESM4::Creature*> chain = templateChain(base);
            data->mModel = choose(chain, UseModel);
            // Spawn points leave the model empty even when they don't take it from the template
            if (data->mModel->mModel.empty())
            {
                auto withModel = std::find_if(
                    chain.begin(), chain.end(), [](const ESM4::Creature* rec) { return !rec->mModel.empty(); });
                if (withModel != chain.end())
                    data->mModel = *withModel;
            }
            data->mStats = choose(chain, UseStats);
            data->mAIData = choose(chain, UseAIData);
            data->mAIPackages = choose(chain, UseAIPackages);
            data->mBaseData = choose(chain, UseBaseData);
            if (data->mBaseData->mFullName.empty())
                data->mBaseData = data->mModel;

            const ESM4CreatureCustomData& res = *data;
            refData.setCustomData(std::move(data));
            return res;
        }
    }

    MWWorld::Ptr ESM4Creature::copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const
    {
        const MWWorld::LiveCellRef<ESM4::Creature>* ref = ptr.get<ESM4::Creature>();
        return MWWorld::Ptr(cell.insert(ref), &cell);
    }

    void ESM4Creature::insertObjectRendering(
        const MWWorld::Ptr& ptr, const std::string& model, MWRender::RenderingInterface& renderingInterface) const
    {
        if (model.empty())
            return;
        renderingInterface.getObjects().insertNPC(ptr);
    }

    void ESM4Creature::insertObject(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
        MWPhysics::PhysicsSystem& physics) const
    {
        insertObjectPhysics(ptr, model, rotation, physics);
    }

    void ESM4Creature::insertObjectPhysics(const MWWorld::Ptr& ptr, const std::string& model,
        const osg::Quat& rotation, MWPhysics::PhysicsSystem& physics) const
    {
        // No collision yet, as for ESM4 NPCs: the skeleton only carries ragdoll shapes.
    }

    MWGui::ToolTipInfo ESM4Creature::getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const
    {
        return ESM4Impl::getToolTipInfo(getName(ptr), count);
    }

    VFS::Path::NormalizedView ESM4Creature::getModel(const MWWorld::ConstPtr& ptr) const
    {
        const ESM4::Creature* rec = getCustomData(ptr).mModel;
        if (rec == nullptr || ESM4Impl::isMarkerModel(rec->mModel.getNormalized().value()))
            return {};
        return rec->mModel.getNormalized();
    }

    std::string_view ESM4Creature::getName(const MWWorld::ConstPtr& ptr) const
    {
        const ESM4::Creature* rec = getCustomData(ptr).mBaseData;
        return rec != nullptr ? std::string_view(rec->mFullName) : std::string_view();
    }

    const ESM4::Creature* ESM4Creature::getModelRecord(const MWWorld::ConstPtr& ptr)
    {
        return getCustomData(ptr).mModel;
    }

    const ESM4::Creature* ESM4Creature::getStatsRecord(const MWWorld::ConstPtr& ptr)
    {
        return getCustomData(ptr).mStats;
    }

    const ESM4::Creature* ESM4Creature::getAIDataRecord(const MWWorld::ConstPtr& ptr)
    {
        return getCustomData(ptr).mAIData;
    }

    const ESM4::Creature* ESM4Creature::getAIPackagesRecord(const MWWorld::ConstPtr& ptr)
    {
        return getCustomData(ptr).mAIPackages;
    }

    const ESM4::Creature* ESM4Creature::getBaseDataRecord(const MWWorld::ConstPtr& ptr)
    {
        return getCustomData(ptr).mBaseData;
    }
}
