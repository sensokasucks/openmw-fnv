#include "esm4container.hpp"
#include "esm4lock.hpp"

#include <MyGUI_TextIterator.h>
#include <MyGUI_UString.h>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwgui/tooltips.hpp"

#include "../mwworld/actionopen.hpp"
#include "../mwworld/failedaction.hpp"
#include "../mwworld/nullaction.hpp"
#include "../mwworld/worldmodel.hpp"

namespace MWClass
{
    ESM4ContainerCustomData::ESM4ContainerCustomData(const ESM4::Container& container)
    {
        mStore.fillESM4(container.mInventory, MWBase::Environment::get().getWorld()->getPrng());
    }

    ESM4Container::ESM4Container()
        : MWWorld::RegisteredClass<ESM4Container, ESM4Base<ESM4::Container>>(ESM4::Container::sRecordId)
    {
    }

    void ESM4Container::ensureCustomData(const MWWorld::Ptr& ptr) const
    {
        if (!ptr.getRefData().getCustomData())
        {
            MWBase::Environment::get().getWorldModel()->registerPtr(ptr);
            const MWWorld::LiveCellRef<ESM4::Container>* ref = ptr.get<ESM4::Container>();
            ptr.getRefData().setCustomData(std::make_unique<ESM4ContainerCustomData>(*ref->mBase));
            getContainerStore(ptr).setPtr(ptr);
        }
    }

    MWWorld::Ptr ESM4Container::copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const
    {
        const MWWorld::LiveCellRef<ESM4::Container>* ref = ptr.get<ESM4::Container>();
        MWWorld::Ptr newPtr(cell.insert(ref), &cell);
        if (newPtr.getRefData().getCustomData())
        {
            MWBase::Environment::get().getWorldModel()->registerPtr(newPtr);
            getContainerStore(newPtr).setPtr(newPtr);
        }
        return newPtr;
    }

    std::string_view ESM4Container::getName(const MWWorld::ConstPtr& ptr) const
    {
        return ptr.get<ESM4::Container>()->mBase->mFullName;
    }

    bool ESM4Container::hasToolTip(const MWWorld::ConstPtr& ptr) const
    {
        return !getName(ptr).empty();
    }

    MWGui::ToolTipInfo ESM4Container::getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const
    {
        MWGui::ToolTipInfo info = ESM4Impl::getToolTipInfo(getName(ptr), count);
        const std::string lock = ESM4Lock::describe(ptr);
        if (!lock.empty())
            info.text = "\n" + lock;
        return info;
    }

    std::unique_ptr<MWWorld::Action> ESM4Container::activate(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor) const
    {
        if (!MWBase::Environment::get().getWindowManager()->isAllowed(MWGui::GW_Inventory))
            return std::make_unique<MWWorld::NullAction>();

        if (!ESM4Lock::tryOpen(ptr, actor))
            return std::make_unique<MWWorld::FailedAction>(std::string_view{}, ptr);

        std::unique_ptr<MWWorld::Action> action = std::make_unique<MWWorld::ActionOpen>(ptr);
        action->setSound(ptr.get<ESM4::Container>()->mBase->mOpenSound);
        return action;
    }

    MWWorld::ContainerStore& ESM4Container::getContainerStore(const MWWorld::Ptr& ptr) const
    {
        ensureCustomData(ptr);
        return static_cast<ESM4ContainerCustomData&>(*ptr.getRefData().getCustomData()).mStore;
    }

    float ESM4Container::getCapacity(const MWWorld::Ptr& ptr) const
    {
        // The FNV container weight field is not a carry limit.
        return std::numeric_limits<float>::max();
    }

    float ESM4Container::getEncumbrance(const MWWorld::Ptr& ptr) const
    {
        return getContainerStore(ptr).getWeight();
    }
}
