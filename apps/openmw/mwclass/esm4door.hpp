#ifndef GAME_MWCLASS_ESM4DOOR_H
#define GAME_MWCLASS_ESM4DOOR_H

#include <components/esm4/loaddoor.hpp>

#include "../mwworld/customdata.hpp"

#include "esm4base.hpp"

namespace MWClass
{
    class ESM4DoorCustomData : public MWWorld::TypedCustomData<ESM4DoorCustomData>
    {
    public:
        bool mOpen = false;
    };

    // Non-teleport ESM4 doors play the "Open" and "Close" sequences embedded in their model.
    // Teleport doors are handled in Lua (scripts/omw/activationhandlers.lua).
    class ESM4Door final : public MWWorld::RegisteredClass<ESM4Door, ESM4Base<ESM4::Door>>
    {
        friend MWWorld::RegisteredClass<ESM4Door, ESM4Base<ESM4::Door>>;

        ESM4Door();

        static ESM4DoorCustomData& getCustomData(const MWWorld::Ptr& ptr);

    public:
        static constexpr std::string_view sOpenGroup = "open";
        static constexpr std::string_view sCloseGroup = "close";

        std::string_view getName(const MWWorld::ConstPtr& ptr) const override;

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override;

        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override;

        void insertObjectRendering(const MWWorld::Ptr& ptr, const std::string& model,
            MWRender::RenderingInterface& renderingInterface) const override;

        bool useAnim() const override { return true; }

        std::unique_ptr<MWWorld::Action> activate(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor) const override;

        bool canLock(const MWWorld::ConstPtr& ptr) const override { return true; }

        void readAdditionalState(const MWWorld::Ptr& ptr, const ESM::ObjectState& state) const override;

        void writeAdditionalState(const MWWorld::ConstPtr& ptr, ESM::ObjectState& state) const override;

        static bool isOpen(const MWWorld::ConstPtr& ptr);

        /// Opens a closed door or closes an open one, playing its animation if the model has one.
        static void toggle(const MWWorld::Ptr& ptr);
    };
}

#endif // GAME_MWCLASS_ESM4DOOR_H
