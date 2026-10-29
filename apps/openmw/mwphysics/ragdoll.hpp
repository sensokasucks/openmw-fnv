#ifndef OPENMW_MWPHYSICS_RAGDOLL_H
#define OPENMW_MWPHYSICS_RAGDOLL_H

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <osg/Quat>
#include <osg/Vec3f>
#include <osg/ref_ptr>

#include <LinearMath/btTransform.h>

#include <components/nif/niffile.hpp>
#include <components/nif/niftypes.hpp>
#include <components/resource/bulletshape.hpp>

class btBroadphaseInterface;
class btCollisionDispatcher;
class btCollisionObject;
class btDefaultCollisionConfiguration;
class btDiscreteDynamicsWorld;
class btRigidBody;
class btDefaultMotionState;
class btSequentialImpulseConstraintSolver;
class btTypedConstraint;

namespace osg
{
    class Group;
}

namespace NifOsg
{
    class MatrixTransform;
}

namespace MWPhysics
{
    class PhysicsSystem;
    class RagdollWorld;

    // A Bullet ragdoll built from a Bethesda skeleton's Havok data (FO3/FNV/Skyrim skeleton.nif): the bones with a
    // bhkBlendCollisionObject give the rigid bodies (capsules, with their mass, friction and damping), and the
    // bodies' bhkRagdollConstraint / bhkLimitedHingeConstraint / bhkBallAndSocketConstraint entries the joints.
    // Keyframed while the actor lives (the animation poses the bones), it takes over on death or a knockdown
    // (start): the bodies are seeded from the bones' pose, given the blow's impulse, simulated in the RagdollWorld,
    // and written back into the bones every frame (applyToBones), so the skinned body follows. Once every body
    // sleeps the ragdoll is at rest and freezes into its pose.
    class Ragdoll
    {
    public:
        struct Bone
        {
            std::string mName;
            osg::ref_ptr<NifOsg::MatrixTransform> mNode;
            Resource::CollisionShapePtr mShape;
            std::unique_ptr<btDefaultMotionState> mMotion;
            std::unique_ptr<btRigidBody> mBody;
            // The body in the bone's space (a bhkRigidBodyT's offset): body = boneToBody x bone, world units
            btTransform mBoneToBody = btTransform::getIdentity();
            float mMass = 1.f;
            float mFriction = 0.5f;
            float mRestitution = 0.f;
            float mLinearDamping = 0.05f;
            float mAngularDamping = 0.85f;
            const void* mEntity = nullptr; // the NIF record, to match constraints
            int mNifIndex = -1; // among the skeleton's bodies in NIF tree order (a placed pose's entry)
            int mBodyPart = -1; // the biped part in the body's collision filter (bits 8-12)
        };

        // A bone's local transform in a placed corpse's pose (ESM4 XRGD), relative to its parent node
        struct PlacedBone
        {
            int mBodyPart = -1;
            Nif::Matrix3 mRotation;
            osg::Vec3f mTranslation;
        };

        // Builds the ragdoll of a skeleton for the bones under skeletonRoot (matched by name), scaled by scale (the
        // race height). nullptr when the skeleton carries no Havok bodies.
        static std::unique_ptr<Ragdoll> create(
            Nif::FileView skeleton, osg::Group& skeletonRoot, float scale, RagdollWorld& world);
        ~Ragdoll();

        // Lets the body go from the pose the bones are in. The impulse (kg x game units per second) goes to the
        // body nearest hitPosition, or the pelvis without one.
        void start(const osg::Vec3f& impulse, const std::optional<osg::Vec3f>& hitPosition);
        // Puts the body into a placed corpse's pose, frozen at once (FalloutNV.exe 0x004d9dc0): entry i is the local
        // transform of the i-th body's bone in NIF tree order. The root bone (Bip01, the first body's parent) sits at
        // the reference's origin, turned by rootRotation if given. False, and nothing posed, if the pose doesn't fit
        // the skeleton (entry count or body parts differ, as the game checks).
        bool startPlaced(const std::vector<PlacedBone>& pose, const Nif::Matrix3* rootRotation);
        bool isStarted() const { return mStarted; }
        // Simulated right now
        bool isActive() const { return mActive; }
        // Every body sleeps: the pose is final
        bool isAtRest() const;
        // Seconds the body has lain still (0 while it moves)
        float getRestTime() const { return mRestTime; }
        // Out of the simulation, the pose stays
        void freeze();
        // Writes the bodies' transforms into the bones for the frame (RagdollWorld does this after each step)
        void applyToBones();
        // Where the pelvis (the first body) is in the world
        osg::Vec3f getRootPosition() const;
        // Whether the body lies on its back: the pelvis bone's forward axis points up
        bool isFaceUp() const;
        const std::vector<Bone>& getBones() const { return mBones; }
        // World transforms of the bodies, by bone name (to save a pose)
        std::map<std::string, btTransform, std::less<>> getPose() const;

        // Called by the world each step
        void onStepped(float dt);

    private:
        Ragdoll() = default;
        void seedFromBones();
        void addToWorld();
        void removeFromWorld();
        void collectNodes(osg::Group& root);

        struct Node
        {
            osg::ref_ptr<NifOsg::MatrixTransform> mNode;
            int mParent = -1; // index into mNodes, -1 for the skeleton root's children
            int mBone = -1; // index into mBones, -1 for a bone without a body
        };

        std::vector<Bone> mBones;
        std::vector<std::unique_ptr<btTypedConstraint>> mConstraints;
        std::vector<Node> mNodes; // every transform under the root, parents first
        osg::ref_ptr<osg::Group> mRoot;
        RagdollWorld* mWorld = nullptr;
        bool mStarted = false;
        bool mActive = false;
        bool mSettling = false; // the body has slowed and its damping is up
        bool mWindowValid = false; // the rest window's start positions are set
        float mWindowTime = 0.f;
        btVector3 mWindowPelvis;
        btVector3 mWindowCentre;
        float mRestTime = 0.f;
        float mAge = 0.f;
    };

    // The dynamics world the ragdolls fall in. OpenMW's own physics is a collision world without dynamics, so the
    // ragdolls get a btDiscreteDynamicsWorld of their own; the static world around them (walls, floors, terrain,
    // doors) is mirrored into it as massless proxies sharing the collision shapes, within reach of the active
    // bodies, and the proxies go when the physics system drops their source.
    class RagdollWorld
    {
    public:
        explicit RagdollWorld(PhysicsSystem& physics);
        ~RagdollWorld();

        void step(float dt);
        btDiscreteDynamicsWorld& getWorld() { return *mWorld; }

        void add(Ragdoll* ragdoll);
        void remove(Ragdoll* ragdoll);
        // The static world within radius of position is mirrored for the bodies to land on
        void updateStaticProxies(const osg::Vec3f& position, float radius);
        // The physics system is dropping this collision object: its proxy goes too
        void onCollisionObjectRemoved(const btCollisionObject* object);

        std::size_t getActiveCount() const;
        // At most this many ragdolls simulate at once; the oldest freeze where they lie
        static constexpr std::size_t sMaxActive = 10;

    private:
        PhysicsSystem& mPhysics;
        std::unique_ptr<btDefaultCollisionConfiguration> mConfiguration;
        std::unique_ptr<btCollisionDispatcher> mDispatcher;
        std::unique_ptr<btBroadphaseInterface> mBroadphase;
        std::unique_ptr<btSequentialImpulseConstraintSolver> mSolver;
        std::unique_ptr<btDiscreteDynamicsWorld> mWorld;

        struct Proxy
        {
            std::unique_ptr<btRigidBody> mBody;
            osg::ref_ptr<const Resource::BulletShapeInstance> mShapeInstance; // keeps a shared shape alive
            float mLastUsed = 0.f;
        };
        std::map<const btCollisionObject*, Proxy> mProxies;
        std::vector<Ragdoll*> mRagdolls;
        float mTime = 0.f;
        float mProxyCheck = 0.f;
    };
}

#endif
