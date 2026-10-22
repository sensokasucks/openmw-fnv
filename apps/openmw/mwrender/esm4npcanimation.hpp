#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <map>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

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

        enum class Locomotion
        {
            Idle,
            Walk,
            Run,
        };

        // FO3/FONV: loops the standing idle or a forward locomotion sequence. With force, the sequence is started
        // again even if it is the current locomotion (after an idle or furniture sequence replaced it).
        void setLocomotion(Locomotion locomotion, bool force = false);
        // Ground speed of the current locomotion sequence (units per second), 0 when standing or unknown.
        float getLocomotionSpeed() const;

        // FO3/FONV: plays the KF file of an IDLE record (path under meshes/, e.g.
        // characters/_male/idleanims/chair_forwardenter.kf) in place of the locomotion sequence. Looping or
        // one-shot as the sequence's cycle type says. With keepRootMotion the accumulation root ("Bip01") moves
        // with the sequence, as furniture enter/exit sequences carry the actor from the marker to the seat;
        // otherwise it is held in place like a locomotion cycle. Returns the length of the sequence in seconds,
        // 0 if the file is missing.
        float playIdleFONV(std::string_view model, bool keepRootMotion);
        // Horizontal distance the accumulation root covers over the sequence last started with keepRootMotion,
        // in skeleton space (x right, y forward).
        osg::Vec3f getRootMotion() const { return mRootMotion; }

    private:
        Locomotion mLocomotion = Locomotion::Idle;
        float mLocomotionSpeed = 0.f;
        osg::Vec3f mRootMotion;
        std::vector<std::pair<osg::ref_ptr<osg::Node>, osg::ref_ptr<osg::Callback>>> mLoopCallbacks;
        struct RestPose
        {
            osg::Vec3f mTranslation;
            osg::Quat mRotation;
        };
        std::map<const osg::Node*, RestPose> mRestPoses;

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
        void playStandingIdleFONV();
        // stripRootMotion: keep the accumulation root in place, the AI moves the actor
        void playLoopFONV(std::string_view file, bool stripRootMotion);
        // Plays one KF sequence on the skeleton, replacing the one played before. Returns its length, 0 if missing.
        float playSequenceFONV(const VFS::Path::Normalized& path, bool stripRootMotion);
    };
}

#endif // GAME_RENDER_ESM4NPCANIMATION_H
