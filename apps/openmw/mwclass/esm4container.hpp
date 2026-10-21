#ifndef GAME_MWCLASS_ESM4CONTAINER_H
#define GAME_MWCLASS_ESM4CONTAINER_H

#include <components/esm4/loadcont.hpp>

#include "../mwworld/containerstore.hpp"
#include "../mwworld/customdata.hpp"

#include "esm4base.hpp"

namespace MWClass
{
    class ESM4ContainerCustomData : public MWWorld::TypedCustomData<ESM4ContainerCustomData>
    {
    public:
        MWWorld::ContainerStore mStore;

        // ESM4 references are not saved yet, so the inventory is always rebuilt from the base record.
        explicit ESM4ContainerCustomData(const ESM4::Container& container);
    };

    class ESM4Container final : public MWWorld::RegisteredClass<ESM4Container, ESM4Base<ESM4::Container>>
    {
        friend MWWorld::RegisteredClass<ESM4Container, ESM4Base<ESM4::Container>>;

        ESM4Container();

        void ensureCustomData(const MWWorld::Ptr& ptr) const;

        MWWorld::Ptr copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const override;

    public:
        std::string_view getName(const MWWorld::ConstPtr& ptr) const override;

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override;

        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override;

        std::unique_ptr<MWWorld::Action> activate(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor) const override;

        MWWorld::ContainerStore& getContainerStore(const MWWorld::Ptr& ptr) const override;

        float getCapacity(const MWWorld::Ptr& ptr) const override;

        float getEncumbrance(const MWWorld::Ptr& ptr) const override;

        bool canLock(const MWWorld::ConstPtr& ptr) const override { return true; }
    };
}

#endif // GAME_MWCLASS_ESM4CONTAINER_H
