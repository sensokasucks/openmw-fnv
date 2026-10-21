#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <optional>

#include <osg/Quat>

namespace ESM4
{
    struct Npc;
}

namespace MWRender
{
    class ESM4NpcAnimation : public Animation
    {
    public:
        ESM4NpcAnimation(
            const MWWorld::Ptr& ptr, osg::ref_ptr<osg::Group> parentNode, Resource::ResourceSystem* resourceSystem);

    private:
        // FO3/FONV: rotation that puts rigid head parts upright under the head bone
        std::optional<osg::Quat> mHeadAttitude;

        void insertPart(std::string_view model);
        osg::ref_ptr<osg::Node> attachPart(std::string_view model);

        // Works for FO3/FONV/TES5
        void insertHeadParts(const std::vector<ESM::FormId>& partIds, std::set<uint32_t>& usedHeadPartTypes);

        void updateParts();
        void updatePartsTES4(const ESM4::Npc& traits);
        void updatePartsTES5(const ESM4::Npc& traits);
        void updatePartsFONV(const ESM4::Npc& traits);
        void playIdleFONV();
    };
}

#endif // GAME_RENDER_ESM4NPCANIMATION_H
