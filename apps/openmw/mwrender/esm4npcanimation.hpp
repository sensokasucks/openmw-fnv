#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <osg/MatrixTransform>
#include <osg/Matrixf>

#include <map>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace SceneUtil
{
    class ControllerSource;
}

namespace ESM4
{
    struct Npc;
}

namespace osg
{
    class Callback;
}

namespace MWRender
{
    class FaceMorphs;
    struct LipSync;

    class ESM4NpcAnimation : public Animation
    {
    public:
        ESM4NpcAnimation(
            const MWWorld::Ptr& ptr, osg::ref_ptr<osg::Group> parentNode, Resource::ResourceSystem* resourceSystem);
        ~ESM4NpcAnimation() override;

        enum class Locomotion
        {
            Idle,
            Walk,
            Run,
        };

        // FO3/FONV: loops the standing idle or a forward locomotion sequence. With force, the sequence is started
        // again even if it is the current locomotion (after an idle or furniture sequence replaced it).
        void setLocomotion(Locomotion locomotion, bool force = false);

        // Which way the walk and run loops go (mtforward, mtbackward, mtleft, mtright and their fast variants);
        // the AI only walks forward, the player's body strafes and backs up.
        enum class Direction
        {
            Forward,
            Backward,
            Left,
            Right,
        };
        void setLocomotionDirection(Direction direction);
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
        // Plays an attack (or another one-off sequence) next to the skeleton or in idleanims/ once, then holds its
        // last frame until resumeLocomotion. Returns its length, 0 if there is no such file.
        float playActionFONV(std::string_view file);
        void resumeLocomotion();

        // Sequence looped while standing instead of mtidle.kf (e.g. "2hraim.kf" with a rifle drawn); empty resets.
        void setIdleSequence(std::string_view file);
        // Puts a weapon model on the "Weapon" bone of the right hand; empty takes it away.
        void showWeapon(std::string_view model);

        // Lays the actor down and keeps it there; instant for actors that were already dead when loaded.
        void playDeath(bool instant);
        bool isDead() const { return mDead; }

        // Ground speed of the current locomotion sequence (units per second), 0 when standing or unknown.
        float getLocomotionSpeed() const;
        // Playback rate of the walk and run loops: the actor's speed over getLocomotionSpeed.
        void setLocomotionRate(float rate);
        bool isWeaponShown() const { return mWeapon != nullptr; }

        // FO3/FONV: the mood the face shows while speaking a dialogue line, from its INFO response (emotion type
        // 0 neutral, 1 anger, 2 disgust, 3 fear, 4 sad, 5 happy, 6 surprise, 7 pained; value 0-100). It fades once
        // the actor stops talking.
        void setEmotion(int type, float value);

        // FO3/FONV: the voice file the actor just started saying. Its lip sync (.lip) moves the mouth, brows and
        // eyes; without one the mouth follows the voice's loudness.
        void startLipSync(std::string_view voiceFile);

        // Moves the face for the frame: the mouth follows the loudness of the voice line being said, the eyes
        // blink now and then, and the mood shows. Called by the face's update callback.
        void updateFace(float duration);

        // FO3/FONV head tracking: the head turns toward a point in world space (a speaker's listener, or the
        // player's eyes), within what a neck allows, and back to the animation's own pose without one.
        void setLookTarget(const std::optional<osg::Vec3f>& target) { mLookTarget = target; }
        // World position of "Bip01 Head", if the skeleton has one.
        std::optional<osg::Vec3f> getHeadPosition() const;
        // Turns the head bone for the frame, after the sequence and any blend have posed it. Called by the head's
        // update callback.
        void updateLook(osg::MatrixTransform& head, float duration);

    private:
        // FO3/FONV: places rigid head parts in the skinned head's space under the head bone
        osg::Matrixf mHeadBinding;

        Locomotion mLocomotion = Locomotion::Idle;
        Direction mDirection = Direction::Forward;
        bool mDead = false;
        bool mInAction = false;
        std::string mIdleSequence;
        osg::ref_ptr<osg::Node> mWeapon;
        float mLocomotionSpeed = 0.f;
        std::shared_ptr<float> mLocomotionRate = std::make_shared<float>(1.f);
        osg::Vec3f mRootMotion;

        // FO3/FONV facial animation (FaceGen .tri morphs of the head parts)
        std::unique_ptr<FaceMorphs> mFace;
        osg::ref_ptr<osg::Callback> mFaceCallback;
        std::minstd_rand mFaceRandom;
        float mMouthOpen = 0.f;
        std::size_t mViseme = 0;
        std::size_t mPreviousViseme = 0;
        float mVisemeTime = 0.f;
        float mVisemeBlend = 1.f;
        float mBlinkWait = 3.f;
        float mBlinkTime = -1.f;
        int mEmotion = 0;
        float mEmotionValue = 0.f;
        float mEmotionLevel = 0.f;
        float mSilentTime = 0.f;
        std::shared_ptr<const LipSync> mLipSync;
        float mLipSyncTime = 0.f;
        std::vector<std::pair<osg::ref_ptr<osg::Node>, osg::ref_ptr<osg::Callback>>> mLoopCallbacks;
        struct RestPose
        {
            osg::Vec3f mTranslation;
            osg::Quat mRotation;
        };
        std::map<const osg::Node*, RestPose> mRestPoses;
        // The current sequence moves the actor with its accumulation root (a furniture entry or exit)
        bool mKeepsRootMotion = false;

        std::optional<osg::Vec3f> mLookTarget;
        float mLookYaw = 0.f;
        float mLookPitch = 0.f;
        osg::ref_ptr<osg::MatrixTransform> mLookBone;
        osg::ref_ptr<osg::Callback> mLookCallback;

        void insertPart(std::string_view model);
        osg::ref_ptr<osg::Node> attachPart(std::string_view model);
        void initHeadBinding(std::string_view headModel);
        void overrideDiffuse(osg::Node& node, std::string_view texture);
        void overrideDiffuse(osg::Node& node, osg::ref_ptr<osg::Image> image);
        osg::ref_ptr<osg::Image> getTexture(std::string_view texture);
        void applyFaceGen(osg::Node& node, std::string_view model, const ESM4::Npc& traits);
        // Lets the head part move with speech, blinks and moods if it has FaceGen morphs (.tri)
        void addFaceMorphs(osg::Node& node, std::string_view model);

        // Works for FO3/FONV/TES5
        void insertHeadParts(const std::vector<ESM::FormId>& partIds, std::set<uint32_t>& usedHeadPartTypes);

        void updateParts();
        void updatePartsTES4(const ESM4::Npc& traits);
        void updatePartsTES5(const ESM4::Npc& traits);
        void updatePartsFONV(const ESM4::Npc& traits);
        void updatePartsCreature();
        bool isFemale() const;
        void playStandingIdleFONV();
        void playLocomotion();
        // stripRootMotion: keep the accumulation root in place, the AI moves the actor
        void playLoopFONV(std::string_view file, bool stripRootMotion);
        // Where a locomotion loop lives for this actor (locomotion/child, locomotion/male or female, locomotion,
        // next to the skeleton), or an empty path if it is nowhere
        VFS::Path::Normalized findLoopFONV(std::string_view file) const;
        // Binds the sequence's tracks to the skeleton, replacing the one played before, which it blends out of over
        // blendTime seconds (the original's fAnimationDefaultBlend) instead of snapping. Returns its length.
        float playKeyframesFONV(const VFS::Path::Normalized& path, std::shared_ptr<SceneUtil::ControllerSource> source,
            bool stripRootMotion, float blendTime = sDefaultBlendTime, bool keepsRootMotion = false);
        // Puts the head-tracking callback last on the head bone, after the sequence's controllers
        void attachLookCallback();

        // fAnimationDefaultBlend:General (FalloutNV.exe default; Fallout.ini doesn't set it)
        static constexpr float sDefaultBlendTime = 0.2f;
    };
}

#endif // GAME_RENDER_ESM4NPCANIMATION_H
