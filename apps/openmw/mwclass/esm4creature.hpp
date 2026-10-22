#ifndef GAME_MWCLASS_ESM4CREATURE_H
#define GAME_MWCLASS_ESM4CREATURE_H

#include <components/esm4/loadcrea.hpp>

#include "../mwworld/class.hpp"
#include "../mwworld/registeredclass.hpp"

namespace MWClass
{
    // FO3/FONV creatures (CREA). Spawn points are creatures whose template is a levelled creature list; the parts
    // of the record a creature takes from its template follow the ACBS template flags, as for NPCs.
    class ESM4Creature final : public MWWorld::RegisteredClass<ESM4Creature>
    {
    public:
        ESM4Creature()
            : MWWorld::RegisteredClass<ESM4Creature>(ESM4::Creature::sRecordId)
        {
        }

        MWWorld::Ptr copyToCellImpl(const MWWorld::ConstPtr& ptr, MWWorld::CellStore& cell) const override;

        void insertObjectRendering(const MWWorld::Ptr& ptr, const std::string& model,
            MWRender::RenderingInterface& renderingInterface) const override;
        void insertObject(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override;
        void insertObjectPhysics(const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation,
            MWPhysics::PhysicsSystem& physics) const override;

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override { return !getName(ptr).empty(); }
        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override;

        VFS::Path::NormalizedView getModel(const MWWorld::ConstPtr& ptr) const override;
        std::string_view getName(const MWWorld::ConstPtr& ptr) const override;

        // The record that provides the skeleton, body parts and animations
        static const ESM4::Creature* getModelRecord(const MWWorld::ConstPtr& ptr);
        // The record that holds health, damage, skills and SPECIAL
        static const ESM4::Creature* getStatsRecord(const MWWorld::ConstPtr& ptr);
        static const ESM4::Creature* getAIDataRecord(const MWWorld::ConstPtr& ptr);
        static const ESM4::Creature* getAIPackagesRecord(const MWWorld::ConstPtr& ptr);
        static const ESM4::Creature* getBaseDataRecord(const MWWorld::ConstPtr& ptr);
    };
}

#endif
