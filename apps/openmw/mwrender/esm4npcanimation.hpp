#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <map>
#include <string_view>
#include <utility>
#include <vector>


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

        enum class Locomotion
        {
            Idle,
            Walk,
            Run,
        };

        // FO3/FONV: loops the standing idle or a forward locomotion sequence.
        void setLocomotion(Locomotion locomotion);
        // Ground speed of the current locomotion sequence (units per second), 0 when standing or unknown.
        float getLocomotionSpeed() const;

    private:
        Locomotion mLocomotion = Locomotion::Idle;
        float mLocomotionSpeed = 0.f;
        std::vector<std::pair<osg::ref_ptr<osg::Node>, osg::ref_ptr<osg::Callback>>> mLoopCallbacks;
        std::map<const osg::Node*, osg::Vec3f> mRestTranslations;

        void insertPart(std::string_view model);
        osg::ref_ptr<osg::Node> attachPart(std::string_view model);
        void overrideDiffuse(osg::Node& node, std::string_view texture);
        void overrideDiffuse(osg::Node& node, osg::ref_ptr<osg::Image> image);
        osg::ref_ptr<osg::Image> getTexture(std::string_view texture);
        void applyFaceGen(osg::Node& node, std::string_view model, const ESM4::Npc& traits);

        // Works for FO3/FONV/TES5
        void insertHeadParts(const std::vector<ESM::FormId>& partIds, std::set<uint32_t>& usedHeadPartTypes);

        void updateParts();
        void updatePartsTES4(const ESM4::Npc& traits);
        void updatePartsTES5(const ESM4::Npc& traits);
        void updatePartsFONV(const ESM4::Npc& traits);
        void playIdleFONV();
        // stripRootMotion: keep the accumulation root in place, the AI moves the actor
        void playLoopFONV(std::string_view file, bool stripRootMotion);
    };
}

#endif // GAME_RENDER_ESM4NPCANIMATION_H
