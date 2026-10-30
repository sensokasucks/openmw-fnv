#include "esm4door.hpp"

#include <components/esm3/doorstate.hpp>
#include <components/sceneutil/positionattitudetransform.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwgui/tooltips.hpp"

#include "../mwmechanics/character.hpp"

#include "../mwrender/animation.hpp"
#include "../mwrender/objects.hpp"
#include "../mwrender/renderinginterface.hpp"
#include "../mwrender/vismask.hpp"

#include "../mwworld/action.hpp"
#include "../mwworld/failedaction.hpp"

namespace MWClass
{
    namespace
    {
        class ActionToggleDoor final : public MWWorld::Action
        {
            void executeImp(const MWWorld::Ptr& actor) override { ESM4Door::toggle(getTarget()); }

        public:
            explicit ActionToggleDoor(const MWWorld::Ptr& door)
                : MWWorld::Action(false, door)
            {
            }
        };
    }

    ESM4Door::ESM4Door()
        : MWWorld::RegisteredClass<ESM4Door, ESM4Base<ESM4::Door>>(ESM4::Door::sRecordId)
    {
    }

    ESM4DoorCustomData& ESM4Door::getCustomData(const MWWorld::Ptr& ptr)
    {
        if (!ptr.getRefData().getCustomData())
            ptr.getRefData().setCustomData(std::make_unique<ESM4DoorCustomData>());
        return static_cast<ESM4DoorCustomData&>(*ptr.getRefData().getCustomData());
    }

    bool ESM4Door::isOpen(const MWWorld::ConstPtr& ptr)
    {
        const MWWorld::CustomData* data = ptr.getRefData().getCustomData();
        return data != nullptr && static_cast<const ESM4DoorCustomData*>(data)->mOpen;
    }

    std::string_view ESM4Door::getName(const MWWorld::ConstPtr& ptr) const
    {
        return ptr.get<ESM4::Door>()->mBase->mFullName;
    }

    bool ESM4Door::hasToolTip(const MWWorld::ConstPtr& ptr) const
    {
        return !getName(ptr).empty();
    }

    MWGui::ToolTipInfo ESM4Door::getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const
    {
        MWGui::ToolTipInfo info = ESM4Impl::getToolTipInfo(getName(ptr), count);
        if (ptr.getCellRef().isLocked())
            info.text = "\n#{sLockLevel}: " + MWGui::ToolTips::toString(ptr.getCellRef().getLockLevel());
        return info;
    }

    void ESM4Door::insertObjectRendering(
        const MWWorld::Ptr& ptr, const std::string& model, MWRender::RenderingInterface& renderingInterface) const
    {
        if (model.empty())
            return;

        MWRender::Objects& objects = renderingInterface.getObjects();
        objects.insertModel(ptr, model);

        MWRender::Animation* anim = objects.getAnimation(ptr);
        if (anim == nullptr || !anim->addEmbeddedAnimSource(model))
        {
            // Nothing to animate (e.g. most load doors), render it like other ESM4 objects.
            ptr.getRefData().getBaseNode()->setNodeMask(MWRender::Mask_Static);
            return;
        }

        // Hold the door on the last frame of its last sequence, so it rests fully open or closed. This also keeps a
        // door open that was opened before its cell was unloaded.
        const std::string_view restGroup = isOpen(ptr) ? sOpenGroup : sCloseGroup;
        if (anim->hasAnimation(restGroup))
            anim->play(restGroup, MWMechanics::Priority_Scripted, MWRender::BlendMask_All, false, 1.f, "start", "stop",
                1.f, 0);
    }

    void ESM4Door::readAdditionalState(const MWWorld::Ptr& ptr, const ESM::ObjectState& state) const
    {
        if (!state.mHasCustomState)
            return;

        // Read before the door is drawn, so insertObjectRendering rests it open.
        getCustomData(ptr).mOpen = state.asDoorState().mDoorState != 0;
    }

    void ESM4Door::writeAdditionalState(const MWWorld::ConstPtr& ptr, ESM::ObjectState& state) const
    {
        if (!ptr.getRefData().getCustomData())
        {
            state.mHasCustomState = false;
            return;
        }

        // 1 is MWWorld::DoorState::Opening; ESM4 doors have no moving state worth keeping.
        state.asDoorState().mDoorState = isOpen(ptr) ? 1 : 0;
    }

    std::unique_ptr<MWWorld::Action> ESM4Door::activate(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor) const
    {
        // TODO: keys and lockpicking for ESM4 locks
        if (ptr.getCellRef().isLocked())
            return std::make_unique<MWWorld::FailedAction>("Locked", ptr);

        const ESM4::Door* door = ptr.get<ESM4::Door>()->mBase;
        std::unique_ptr<MWWorld::Action> action = std::make_unique<ActionToggleDoor>(ptr);
        action->setSound(isOpen(ptr) ? door->mCloseSound : door->mOpenSound);
        return action;
    }

    void ESM4Door::toggle(const MWWorld::Ptr& ptr)
    {
        ESM4DoorCustomData& data = getCustomData(ptr);
        data.mOpen = !data.mOpen;
        const std::string_view group = data.mOpen ? sOpenGroup : sCloseGroup;

        // getAnimation also takes the door out of a paged object chunk if needed.
        MWRender::Animation* anim = MWBase::Environment::get().getWorld()->getAnimation(ptr);
        if (anim == nullptr || !anim->hasAnimation(group))
            return;

        // Scripted animations stay on their last frame, so the door stays open (or closed) when done.
        // Mode 1 replaces the other group right away if the door is still moving.
        MWBase::MechanicsManager* mechanics = MWBase::Environment::get().getMechanicsManager();
        if (!mechanics->playAnimationGroup(ptr, group, 1, 0, true))
        {
            // A door taken out of a paged chunk has no animation controller yet.
            mechanics->add(ptr);
            mechanics->playAnimationGroup(ptr, group, 1, 0, true);
        }
    }
}
