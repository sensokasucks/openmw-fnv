#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <map>
#include <memory>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include <osg/Quat>

namespace SceneUtil
{
    class ControllerSource;
}

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
        // Plays an attack (or another one-off sequence) next to the skeleton or in idleanims/ once, then holds its
        // last frame until resumeLocomotion. Returns its length, 0 if there is no such file.
        float playActionFONV(std::string_view file);
        void resumeLocomotion();

        // Lays the actor down and keeps it there; instant for actors that were already dead when loaded.
        void playDeath(bool instant);
        bool isDead() const { return mDead; }

        // Ground speed of the current locomotion sequence (units per second), 0 when standing or unknown.
        float getLocomotionSpeed() const;

    private:
        Locomotion mLocomotion = Locomotion::Idle;
        bool mDead = false;
        bool mInAction = false;
        float mLocomotionSpeed = 0.f;
        std::vector<std::pair<osg::ref_ptr<osg::Node>, osg::ref_ptr<osg::Callback>>> mLoopCallbacks;
        std::map<const osg::Node*, osg::Vec3f> mRestTranslations;

        // FO3/FONV: rotation that puts rigid head parts upright under the head bone
        std::optional<osg::Quat> mHeadAttitude;

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
        void updatePartsCreature();
        bool isFemale() const;
        void playIdleFONV();
        void playLocomotion();
        // stripRootMotion: keep the accumulation root in place, the AI moves the actor
        void playLoopFONV(std::string_view file, bool stripRootMotion);
        // Binds the sequence's tracks to the skeleton, replacing the one played before. Returns its length.
        float playKeyframesFONV(const VFS::Path::Normalized& path, std::shared_ptr<SceneUtil::ControllerSource> source,
            bool stripRootMotion);
    };
}

#endif // GAME_RENDER_ESM4NPCANIMATION_H
