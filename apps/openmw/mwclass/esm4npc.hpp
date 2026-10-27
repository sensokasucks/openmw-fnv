#ifndef GAME_MWCLASS_ESM4ACTOR_H
#define GAME_MWCLASS_ESM4ACTOR_H

#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadnpc.hpp>

#include "../mwgui/tooltips.hpp"

#include "../mwrender/objects.hpp"
#include "../mwrender/renderinginterface.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/registeredclass.hpp"

#include "esm4base.hpp"

namespace ESM4
{
    struct Weapon;
}

namespace MWClass
{
    class ESM4Npc final : public MWWorld::RegisteredClass<ESM4Npc>
    {
    public:
        ESM4Npc()
            : MWWorld::RegisteredClass<ESM4Npc>(ESM4::Npc::sRecordId)
        {
        }

        MWWorld::Ptr copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const override
        {
            const MWWorld::LiveCellRef<ESM4::Npc>* ref = ptr.get<ESM4::Npc>();
            return MWWorld::Ptr(cell.insert(ref), &cell);
        }

        void insertObjectRendering(const MWWorld::Ptr& ptr, const std::string& model,
            MWRender::RenderingInterface& renderingInterface) const override
        {
            renderingInterface.getObjects().insertNPC(ptr);
        }

        void insertObject(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override
        {
            insertObjectPhysics(ptr, model, rotation, physics);
        }

        void insertObjectPhysics(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override;

        // Drawn at the race's height (FO3/FNV child races are 0.8); collision keeps its own size
        void adjustScale(const MWWorld::ConstPtr& ptr, osg::Vec3f& scale, bool rendering) const override;

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override { return true; }
        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override
        {
            return ESM4Impl::getToolTipInfo(getName(ptr), count);
        }

        VFS::Path::NormalizedView getModel(const MWWorld::ConstPtr& ptr) const override;
        std::string_view getName(const MWWorld::ConstPtr& ptr) const override;

        static const ESM4::Npc* getTraitsRecord(const MWWorld::Ptr& ptr);
        static const ESM4::Npc* getAIPackagesRecord(const MWWorld::Ptr& ptr);
        static const ESM4::Race* getRace(const MWWorld::Ptr& ptr);
        static bool isFemale(const MWWorld::Ptr& ptr);
        // The record that holds the NPC's level, SPECIAL and skills (following "use stats" templates).
        static const ESM4::Npc* getStatsRecord(const MWWorld::Ptr& ptr);
        // The record whose factions the NPC belongs to (following "use factions" templates).
        static const ESM4::Npc* getFactionsRecord(const MWWorld::Ptr& ptr);
        static const std::vector<const ESM4::Armor*>& getEquippedArmor(const MWWorld::Ptr& ptr);
        static const std::vector<const ESM4::Clothing*>& getEquippedClothing(const MWWorld::Ptr& ptr);
        // For a body drawn from an NPC record that isn't placed (the FO3/FNV player's): its sex, and the apparel it
        // wears instead of the record's own outfit when apparel isn't null.
        static void setAppearance(
            const MWWorld::Ptr& ptr, bool female, const std::vector<const ESM4::Armor*>* apparel);
        // FO3/FONV: the weapon from the NPC's inventory it fights with (a gun if it has one), or nullptr.
        static const ESM4::Weapon* getEquippedWeapon(const MWWorld::Ptr& ptr);
        static const std::vector<const ESM4::Weapon*>& getWeapons(const MWWorld::Ptr& ptr);
        static void setEquippedWeapon(const MWWorld::Ptr& ptr, const ESM4::Weapon* weapon);

    private:
        static ESM4NpcCustomData& getCustomData(const MWWorld::ConstPtr& ptr);
    };
}

#endif // GAME_MWCLASS_ESM4ACTOR_H
