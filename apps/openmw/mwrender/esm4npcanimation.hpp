#ifndef GAME_RENDER_ESM4NPCANIMATION_H
#define GAME_RENDER_ESM4NPCANIMATION_H

#include "animation.hpp"

#include <components/vfs/pathutil.hpp>

#include <osg/MatrixTransform>
#include <osg/Matrixf>

#include <components/esm4/loadbptd.hpp>

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

namespace MWPhysics
{
    class Ragdoll;
}

namespace MWRender
{
    class FaceMorphs;
    struct LipSync;

    class ESM4NpcAnimation : public Animation
    {
    public:
        // skeleton: a model in place of the actor's own (the player's first-person arms use
        // characters/_1stperson/skeleton.nif); firstPerson leaves the head, hair and face out.
        ESM4NpcAnimation(const MWWorld::Ptr& ptr, osg::ref_ptr<osg::Group> parentNode,
            Resource::ResourceSystem* resourceSystem, VFS::Path::NormalizedView skeleton = {},
            bool firstPerson = false);
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
        // With once, the sequence plays to its end and holds its last frame there (whatever its cycle type) until
        // the next one replaces it.
        float playIdleFONV(std::string_view model, bool keepRootMotion, bool once = false);
        // Horizontal distance the accumulation root covers over the sequence last started with keepRootMotion,
        // in skeleton space (x right, y forward).
        osg::Vec3f getRootMotion() const { return mRootMotion; }
        // Plays an attack (or another one-off sequence) next to the skeleton or in idleanims/ once, then holds its
        // last frame until resumeLocomotion. Returns its length, 0 if there is no such file.
        float playActionFONV(std::string_view file);
        void resumeLocomotion();

        // Whether a loop with this name exists next to the skeleton (locomotion/<sex>/, locomotion/, ...)
        bool hasLoopFONV(std::string_view file) const { return !findLoopFONV(file).empty(); }

        // Sequence looped while standing instead of mtidle.kf (e.g. "2hraim.kf" with a rifle drawn); empty resets.
        void setIdleSequence(std::string_view file);
        // Puts a weapon model on the "Weapon" bone of the right hand; empty takes it away.
        void showWeapon(std::string_view model);

        // FO3/FONV dismemberment (see MWMechanics::ESM4Gore, which keeps the lost limbs): the limb's partitions go and
        // the body's caps for it show; severed, a copy of the limb flies off with a spray of blood from the stump,
        // exploded, it bursts into the explosion, debris and limb replacement gore of its BPND. lost holds every limb
        // gone now, this one included. Implemented in esm4dismember.cpp.
        void dismember(const ESM4::BodyPartData& data, const ESM4::BodyPartData::BodyPart& part, bool explode,
            const osg::Vec3f& direction, std::uint32_t seed, std::uint32_t lost);
        // Shows the body without the limbs ESM4Gore says the actor has lost, without any effects.
        void showLostLimbs();

        // Lays the actor down and keeps it there; instant for actors that were already dead when loaded.
        void playDeath(bool instant);
        bool isDead() const { return mDead; }

        // FO3/FONV knockdown (MWMechanics::ESM4Physical): the actor falls (the get-up sequence run backwards, in
        // place of the ragdoll until F3) and stays down until playGetUp, which stands it up again over the returned
        // seconds; standUp then hands the body back to the locomotion. Locomotion, idles and actions are ignored
        // while down. Each returns the length of the sequence played, 0 when the skeleton has none.
        float playKnockdown();
        float playGetUp();
        void standUp();
        bool isDown() const { return mDown; }

        // FO3/FNV ragdoll (MWPhysics::Ragdoll, from the skeleton's Havok bodies): the body drops out of its pose
        // under the blow's impulse (kg x units per second, at hitPosition when given) and the physics poses the
        // bones until it comes to rest. The sequences stop; a knocked-down actor gets up again through endRagdoll.
        // False when the skeleton has no ragdoll or ragdolls are off ("fnv ragdolls" setting).
        bool startRagdoll(const osg::Vec3f& impulse, const std::optional<osg::Vec3f>& hitPosition);
        bool hasRagdoll() const { return mRagdoll != nullptr; }
        bool isRagdollActive() const;
        bool isRagdollAtRest() const;
        bool isRagdollFaceUp() const;
        // Where the pelvis lies
        std::optional<osg::Vec3f> getRagdollPosition() const;
        // Poses the bones from the (frozen) ragdoll again, after the actor was moved to where it lies
        void applyRagdollPose();
        // The ragdoll lets go of the bones; a living actor is down and plays its get-up next (playGetUp)
        void endRagdoll();
        // A placed corpse takes the pose its reference carries (ESM4 XRGD/XRGB) as a frozen ragdoll. False without a
        // pose or a ragdoll, or if the pose doesn't fit the skeleton.
        bool applyPlacedPose();

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
        // Where the eyes of an animation's skeleton are: "Bip01 Head" (or "Head") sits at the top of the neck,
        // and the eyes a little above it. Used to look from and at, so gazes meet eyes rather than foreheads.
        static std::optional<osg::Vec3f> getEyePosition(const Animation& animation);
        // Turns the head bone for the frame, after the sequence and any blend have posed it. Called by the head's
        // update callback.
        void updateLook(osg::MatrixTransform& head, float duration);

    private:
        // FO3/FONV: places rigid head parts in the skinned head's space under the head bone
        osg::Matrixf mHeadBinding;

        bool mFirstPerson = false;
        VFS::Path::Normalized mSkeletonPath; // the skeleton the sequences are looked up next to
        Locomotion mLocomotion = Locomotion::Idle;
        Direction mDirection = Direction::Forward;
        bool mDead = false;
        bool mDown = false; // knocked down or getting up (playKnockdown)
        std::unique_ptr<MWPhysics::Ragdoll> mRagdoll;
        bool mRagdollPosing = false; // the ragdoll has the bones
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
        // The poses the last switch blends from, and whether it has been shown yet
        std::map<const osg::Node*, RestPose> mBlendFrom;
        std::shared_ptr<bool> mBlendStarted;

        std::optional<osg::Vec3f> mLookTarget;
        float mLookYaw = 0.f;
        float mLookPitch = 0.f;
        // Head pitch, roll and yaw of the lip sync frame being spoken (radians), on top of the look
        osg::Vec3f mLipTurn;
        osg::ref_ptr<osg::MatrixTransform> mLookBone;
        osg::ref_ptr<osg::Callback> mLookCallback;

        // Hides the limbs of the mask on the body and shows their caps (esm4dismember.cpp)
        void hideLimbs(const ESM4::BodyPartData& data, std::uint32_t lost);
        void spawnSeveredLimb(const ESM4::BodyPartData::BodyPart& part, const osg::Vec3f& direction, std::uint32_t seed);
        void spawnLimbGore(const ESM4::BodyPartData::BodyPart& part, const osg::Vec3f& direction, std::uint32_t seed);

        // The skeleton's get-up sequence (idleanims/getup.kf and its variants), or the lying death pose when it has
        // none; the second is true for a get-up sequence (which starts lying down and ends standing).
        std::optional<std::pair<VFS::Path::Normalized, bool>> findGetUpSequence() const;

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
        // Drops the sequence playing and puts its bones back at rest
        void stopSequence();
        // Builds the skeleton's ragdoll (MWPhysics::Ragdoll) if it has one and there is none yet
        bool ensureRagdoll();
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
