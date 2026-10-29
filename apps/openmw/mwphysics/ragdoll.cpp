#include "ragdoll.hpp"

#include <algorithm>
#include <cmath>

#include <BulletCollision/BroadphaseCollision/btDbvtBroadphase.h>
#include <BulletCollision/CollisionDispatch/btCollisionDispatcher.h>
#include <BulletCollision/CollisionDispatch/btCollisionObject.h>
#include <BulletCollision/CollisionDispatch/btDefaultCollisionConfiguration.h>
#include <BulletCollision/CollisionShapes/btCollisionShape.h>
#include <BulletDynamics/ConstraintSolver/btConeTwistConstraint.h>
#include <BulletDynamics/ConstraintSolver/btHingeConstraint.h>
#include <BulletDynamics/ConstraintSolver/btPoint2PointConstraint.h>
#include <BulletDynamics/ConstraintSolver/btSequentialImpulseConstraintSolver.h>
#include <BulletDynamics/Dynamics/btDiscreteDynamicsWorld.h>
#include <BulletDynamics/Dynamics/btRigidBody.h>
#include <LinearMath/btDefaultMotionState.h>

#include <osg/Group>
#include <osg/NodeVisitor>

#include <components/debug/debuglog.hpp>
#include <components/misc/constants.hpp>
#include <components/misc/convert.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/nif/node.hpp>
#include <components/nif/physics.hpp>
#include <components/nifbullet/bulletnifloader.hpp>
#include <components/nifosg/matrixtransform.hpp>

#include "collisiontype.hpp"
#include "object.hpp"
#include "physicssystem.hpp"
#include "ptrholder.hpp"

namespace MWPhysics
{
    namespace
    {
        constexpr float sGravity = Constants::GravityConst * Constants::UnitsPerMeter;
        constexpr float sFixedStep = 1.f / 60.f;
        constexpr int sMaxSubSteps = 4;
        // Bullet's defaults (0.8 m/s, 1 rad/s) in game units
        constexpr float sLinearSleep = 0.8f * Constants::UnitsPerMeter;
        constexpr float sAngularSleep = 1.f;
        // A body counts as at rest once every part has been (nearly) still this long. Bullet's own sleeping rarely
        // happens to a chain of constrained bodies (they jitter forever), so the rest is judged from speeds
        constexpr float sRestSettle = 0.5f;
        // A lying FNV body's light parts (hands, feet) keep turning at 0.5..2 rad/s and drifting a few units per
        // second while the pelvis creeps at 1..3 units per second, so tighter limits never let it rest
        // ...judged on the pelvis and the mass-weighted mean of the body, since a light limb wedged against the
        // ground jitters at 20 units/s and several rad/s long after the body lies still
        constexpr float sRestLinearSpeed = 8.f; // game units per second (0.11 m/s)
        constexpr float sRestAngularSpeed = 1.f; // rad/s, the pelvis
        // Once the body has slowed to this, its damping goes up so the limbs settle instead of jittering
        constexpr float sSettleSpeed = 40.f;
        constexpr float sSettledLinearDamping = 0.6f;
        constexpr float sSettledAngularDamping = 0.95f;
        constexpr float sMinSimulated = 0.75f; // a body never rests before it has had time to fall
        // The whole body's launch speed is capped: a hard blow throws it, it doesn't fire it across the room
        constexpr float sMaxLaunchSpeed = 420.f; // game units per second (6 m/s)
        // Bodies lying this long are frozen whatever Bullet thinks (a limb wedged in a wall jitters forever)
        constexpr float sMaxSimulated = 12.f;
        constexpr float sProxyRadius = 1024.f;
        constexpr float sProxyCheckEvery = 0.5f;

        osg::Matrixf toOsg(const btTransform& transform)
        {
            osg::Matrixf matrix;
            btScalar values[16];
            transform.getOpenGLMatrix(values);
            for (int i = 0; i < 16; ++i)
                matrix.ptr()[i] = static_cast<float>(values[i]);
            return matrix;
        }

        btTransform toBullet(const osg::Matrixf& matrix)
        {
            osg::Matrixf rotation = matrix;
            rotation.orthoNormalize(matrix);
            btTransform transform;
            transform.setOrigin(Misc::Convert::toBullet(matrix.getTrans()));
            for (int i = 0; i < 3; ++i)
                for (int j = 0; j < 3; ++j)
                    transform.getBasis()[i][j] = rotation(j, i);
            return transform;
        }

        btVector3 xyz(const osg::Vec4f& v)
        {
            return btVector3(v.x(), v.y(), v.z());
        }

        // A constraint frame in a body's space: origin at the pivot (Havok units), X the twist or hinge axis,
        // Y the plane axis
        btTransform makeFrame(const osg::Vec4f& pivot, const osg::Vec4f& xAxis, const osg::Vec4f& yAxis, float havokScale)
        {
            btVector3 x = xyz(xAxis);
            btVector3 y = xyz(yAxis);
            if (x.length2() < 1e-6f)
                x = btVector3(1, 0, 0);
            x.normalize();
            if (y.length2() < 1e-6f || std::abs(x.dot(y.normalized())) > 0.99f)
                y = std::abs(x.z()) < 0.9f ? btVector3(0, 0, 1) : btVector3(0, 1, 0);
            btVector3 z = x.cross(y);
            z.normalize();
            y = z.cross(x);
            btTransform frame;
            frame.getBasis().setValue(x.x(), y.x(), z.x(), x.y(), y.y(), z.y(), x.z(), y.z(), z.z());
            frame.setOrigin(xyz(pivot) * havokScale);
            return frame;
        }

        // Scales a frame's origin by the actor's size (its axes are unit vectors)
        btTransform scaled(btTransform frame, float scale)
        {
            frame.setOrigin(frame.getOrigin() * scale);
            return frame;
        }

        // Every transform under the root in pre-order, with its parent index
        class CollectTransforms : public osg::NodeVisitor
        {
        public:
            CollectTransforms()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void apply(osg::MatrixTransform& node) override
            {
                if (auto* transform = dynamic_cast<NifOsg::MatrixTransform*>(&node))
                {
                    const int index = static_cast<int>(mNodes.size());
                    mNodes.push_back({ transform, mParents.empty() ? -1 : mParents.back(), -1 });
                    mParents.push_back(index);
                    traverse(node);
                    mParents.pop_back();
                    return;
                }
                traverse(node);
            }

            std::vector<std::pair<NifOsg::MatrixTransform*, int>> getFlat() const
            {
                std::vector<std::pair<NifOsg::MatrixTransform*, int>> out;
                for (const auto& n : mNodes)
                    out.emplace_back(n.mNode, n.mParent);
                return out;
            }

            struct Entry
            {
                NifOsg::MatrixTransform* mNode;
                int mParent;
                int mBone;
            };
            std::vector<Entry> mNodes;

        private:
            std::vector<int> mParents;
        };

        // The NIF's nodes with a Havok body, in tree order (the ragdoll bone order)
        struct NifBody
        {
            const Nif::NiAVObject* mNode;
            const Nif::bhkRigidBody* mBody;
            bool mTransformed;
        };

        void collectBodies(const Nif::NiAVObject& node, std::vector<NifBody>& out)
        {
            if (!node.mCollision.empty()
                && (node.mCollision->mRecordType == Nif::RC_bhkCollisionObject
                    || node.mCollision->mRecordType == Nif::RC_bhkBlendCollisionObject))
            {
                const auto& collision = static_cast<const Nif::bhkCollisionObject&>(node.mCollision.get());
                if (!collision.mBody.empty()
                    && (collision.mBody->mRecordType == Nif::RC_bhkRigidBody
                        || collision.mBody->mRecordType == Nif::RC_bhkRigidBodyT))
                    out.push_back({ &node, static_cast<const Nif::bhkRigidBody*>(collision.mBody.getPtr()),
                        collision.mBody->mRecordType == Nif::RC_bhkRigidBodyT });
            }
            if (const Nif::NiNode* ninode = dynamic_cast<const Nif::NiNode*>(&node))
                for (const auto& child : ninode->mChildren)
                    if (!child.empty())
                        collectBodies(child.get(), out);
        }

        osg::Matrixf worldMatrixOf(osg::Node& node)
        {
            const osg::NodePathList paths = node.getParentalNodePaths();
            if (paths.empty())
                return osg::Matrixf::identity();
            return osg::computeLocalToWorld(paths[0]);
        }
    }

    // ---------------------------------------------------------------- Ragdoll

    std::unique_ptr<Ragdoll> Ragdoll::create(
        Nif::FileView skeleton, osg::Group& skeletonRoot, float scale, RagdollWorld& world)
    {
        std::vector<NifBody> bodies;
        for (std::size_t i = 0; i < skeleton.numRoots(); ++i)
            if (const auto* root = dynamic_cast<const Nif::NiAVObject*>(skeleton.getRoot(i)))
                collectBodies(*root, bodies);
        if (bodies.empty())
            return nullptr;

        std::unique_ptr<Ragdoll> ragdoll(new Ragdoll);
        ragdoll->mRoot = &skeletonRoot;
        ragdoll->mWorld = &world;
        ragdoll->collectNodes(skeletonRoot);

        const float havokScale = NifBullet::havokScaleFor(skeleton.getBethVersion());
        std::map<const void*, std::size_t> boneByEntity;
        for (const NifBody& nifBody : bodies)
        {
            auto found = std::find_if(ragdoll->mNodes.begin(), ragdoll->mNodes.end(),
                [&](const Node& n) { return Misc::StringUtils::ciEqual(n.mNode->getName(), nifBody.mNode->mName); });
            if (found == ragdoll->mNodes.end())
            {
                Log(Debug::Verbose) << "Ragdoll: no bone " << nifBody.mNode->mName << " in the skeleton of "
                                    << skeleton.getFilename();
                continue;
            }
            if (nifBody.mBody->mShape.empty())
                continue;
            std::unique_ptr<btCollisionShape> shape
                = NifBullet::makeBhkShape(nifBody.mBody->mShape.get(), havokScale, 8, true);
            if (shape == nullptr)
                continue;
            shape->setLocalScaling(btVector3(scale, scale, scale));

            Bone bone;
            bone.mName = nifBody.mNode->mName;
            bone.mNode = found->mNode;
            bone.mShape.reset(shape.release());
            bone.mEntity = nifBody.mBody;
            const Nif::bhkRigidBodyCInfo& info = nifBody.mBody->mInfo;
            bone.mMass = info.mMass > 0.01f ? info.mMass : 1.f;
            bone.mFriction = info.mFriction;
            bone.mRestitution = info.mRestitution;
            bone.mLinearDamping = std::clamp(info.mLinearDamping, 0.f, 1.f);
            bone.mAngularDamping = std::clamp(info.mAngularDamping, 0.f, 1.f);
            if (nifBody.mTransformed)
            {
                const osg::Quat& q = info.mRotation;
                bone.mBoneToBody.setRotation(btQuaternion(q.x(), q.y(), q.z(), q.w()));
                bone.mBoneToBody.setOrigin(xyz(info.mTranslation) * havokScale * scale);
            }
            found->mBone = static_cast<int>(ragdoll->mBones.size());
            boneByEntity[nifBody.mBody] = ragdoll->mBones.size();
            ragdoll->mBones.push_back(std::move(bone));
        }
        if (ragdoll->mBones.empty())
            return nullptr;

        // Rigid bodies (kept out of the world until start)
        for (Bone& bone : ragdoll->mBones)
        {
            btVector3 inertia(0, 0, 0);
            bone.mShape->calculateLocalInertia(bone.mMass, inertia);
            bone.mMotion = std::make_unique<btDefaultMotionState>(btTransform::getIdentity());
            btRigidBody::btRigidBodyConstructionInfo info(bone.mMass, bone.mMotion.get(), bone.mShape.get(), inertia);
            info.m_friction = bone.mFriction;
            info.m_restitution = bone.mRestitution;
            info.m_linearDamping = bone.mLinearDamping;
            info.m_angularDamping = bone.mAngularDamping;
            bone.mBody = std::make_unique<btRigidBody>(info);
            bone.mBody->setSleepingThresholds(sLinearSleep, sAngularSleep);
            bone.mBody->setDeactivationTime(0.f);
            bone.mBody->setUserPointer(ragdoll.get());
        }

        // Joints
        for (const NifBody& nifBody : bodies)
        {
            for (const auto& constraintPtr : nifBody.mBody->mConstraints)
            {
                if (constraintPtr.empty())
                    continue;
                const auto* constraint = dynamic_cast<const Nif::bhkConstraint*>(constraintPtr.getPtr());
                if (constraint == nullptr)
                    continue;
                const auto entityA = boneByEntity.find(constraint->mInfo.mEntityA.getPtr());
                const auto entityB = boneByEntity.find(constraint->mInfo.mEntityB.getPtr());
                if (entityA == boneByEntity.end() || entityB == boneByEntity.end() || entityA == entityB)
                    continue;
                btRigidBody& a = *ragdoll->mBones[entityA->second].mBody;
                btRigidBody& b = *ragdoll->mBones[entityB->second].mBody;

                // A malleable constraint wraps one of the others
                Nif::HkConstraintType type;
                const Nif::bhkRagdollConstraintCInfo* ragdollInfo = nullptr;
                const Nif::bhkLimitedHingeConstraintCInfo* limitedHinge = nullptr;
                const Nif::bhkHingeConstraintCInfo* hinge = nullptr;
                const Nif::bhkBallAndSocketConstraintCInfo* ballSocket = nullptr;
                switch (constraint->mRecordType)
                {
                    case Nif::RC_bhkRagdollConstraint:
                        type = Nif::HkConstraintType::Ragdoll;
                        ragdollInfo = &static_cast<const Nif::bhkRagdollConstraint*>(constraint)->mConstraint;
                        break;
                    case Nif::RC_bhkLimitedHingeConstraint:
                        type = Nif::HkConstraintType::LimitedHinge;
                        limitedHinge = &static_cast<const Nif::bhkLimitedHingeConstraint*>(constraint)->mConstraint;
                        break;
                    case Nif::RC_bhkHingeConstraint:
                        type = Nif::HkConstraintType::Hinge;
                        hinge = &static_cast<const Nif::bhkHingeConstraint*>(constraint)->mConstraint;
                        break;
                    case Nif::RC_bhkBallAndSocketConstraint:
                        type = Nif::HkConstraintType::BallAndSocket;
                        ballSocket = &static_cast<const Nif::bhkBallAndSocketConstraint*>(constraint)->mConstraint;
                        break;
                    case Nif::RC_bhkMalleableConstraint:
                    {
                        const auto& malleable
                            = static_cast<const Nif::bhkMalleableConstraint*>(constraint)->mConstraint;
                        type = malleable.mType;
                        ragdollInfo = &malleable.mRagdollInfo;
                        limitedHinge = &malleable.mLimitedHingeInfo;
                        hinge = &malleable.mHingeInfo;
                        ballSocket = &malleable.mBallAndSocketInfo;
                        break;
                    }
                    default:
                        continue;
                }

                std::unique_ptr<btTypedConstraint> joint;
                switch (type)
                {
                    case Nif::HkConstraintType::Ragdoll:
                    {
                        if (ragdollInfo == nullptr)
                            break;
                        const auto& r = *ragdollInfo;
                        const btTransform frameA
                            = scaled(makeFrame(r.mDataA.mPivot, r.mDataA.mTwist, r.mDataA.mPlane, havokScale), scale);
                        const btTransform frameB
                            = scaled(makeFrame(r.mDataB.mPivot, r.mDataB.mTwist, r.mDataB.mPlane, havokScale), scale);
                        auto cone = std::make_unique<btConeTwistConstraint>(a, b, frameA, frameB);
                        // Swing about the frame's Z (across the plane) is the cone, about Y the plane limit, and
                        // the twist is about X; Bullet's limits are symmetric, so the wider side counts
                        const float coneAngle = std::clamp(std::abs(r.mConeMaxAngle), 0.01f, osg::PIf - 0.01f);
                        const float planeAngle = std::clamp(
                            std::max(std::abs(r.mPlaneMinAngle), std::abs(r.mPlaneMaxAngle)), 0.01f, osg::PIf - 0.01f);
                        const float twistAngle = std::clamp(
                            std::max(std::abs(r.mTwistMinAngle), std::abs(r.mTwistMaxAngle)), 0.01f, osg::PIf - 0.01f);
                        cone->setLimit(coneAngle, planeAngle, twistAngle, 0.9f, 0.3f, 1.f);
                        cone->setDamping(0.3f);
                        joint = std::move(cone);
                        break;
                    }
                    case Nif::HkConstraintType::LimitedHinge:
                    {
                        if (limitedHinge == nullptr)
                            break;
                        const auto& h = *limitedHinge;
                        // The hinge turns about the frame's Z axis
                        btTransform frameA = scaled(
                            makeFrame(h.mDataA.mPivot, h.mDataA.mPerpAxis1, h.mDataA.mPerpAxis2, havokScale), scale);
                        btTransform frameB = scaled(
                            makeFrame(h.mDataB.mPivot, h.mDataB.mPerpAxis1, h.mDataB.mPerpAxis2, havokScale), scale);
                        auto hingeJoint = std::make_unique<btHingeConstraint>(a, b, frameA, frameB, true);
                        float minAngle = std::min(h.mMinAngle, h.mMaxAngle);
                        float maxAngle = std::max(h.mMinAngle, h.mMaxAngle);
                        if (maxAngle - minAngle < 0.02f)
                            maxAngle = minAngle + 0.02f;
                        hingeJoint->setLimit(minAngle, maxAngle, 0.9f, 0.3f, 1.f);
                        joint = std::move(hingeJoint);
                        break;
                    }
                    case Nif::HkConstraintType::Hinge:
                    {
                        if (hinge == nullptr)
                            break;
                        const auto& h = *hinge;
                        btTransform frameA = scaled(
                            makeFrame(h.mDataA.mPivot, h.mDataA.mPerpAxis1, h.mDataA.mPerpAxis2, havokScale), scale);
                        btTransform frameB = scaled(
                            makeFrame(h.mDataB.mPivot, h.mDataB.mPerpAxis1, h.mDataB.mPerpAxis2, havokScale), scale);
                        joint = std::make_unique<btHingeConstraint>(a, b, frameA, frameB, true);
                        break;
                    }
                    case Nif::HkConstraintType::BallAndSocket:
                    {
                        if (ballSocket == nullptr)
                            break;
                        joint = std::make_unique<btPoint2PointConstraint>(
                            a, b, xyz(ballSocket->mPivotA) * havokScale * scale, xyz(ballSocket->mPivotB) * havokScale * scale);
                        break;
                    }
                    default:
                        break;
                }
                if (joint != nullptr)
                    ragdoll->mConstraints.push_back(std::move(joint));
            }
        }

        Log(Debug::Verbose) << "Ragdoll for " << skeleton.getFilename() << ": " << ragdoll->mBones.size()
                            << " bodies, " << ragdoll->mConstraints.size() << " joints";
        return ragdoll;
    }

    Ragdoll::~Ragdoll()
    {
        removeFromWorld();
        if (mWorld != nullptr)
            mWorld->remove(this);
    }

    void Ragdoll::collectNodes(osg::Group& root)
    {
        CollectTransforms visitor;
        for (unsigned int i = 0; i < root.getNumChildren(); ++i)
            root.getChild(i)->accept(visitor);
        for (const CollectTransforms::Entry& entry : visitor.mNodes)
            mNodes.push_back({ entry.mNode, entry.mParent, -1 });
    }

    void Ragdoll::seedFromBones()
    {
        for (Bone& bone : mBones)
        {
            const btTransform boneWorld = toBullet(worldMatrixOf(*bone.mNode));
            const btTransform bodyWorld = boneWorld * bone.mBoneToBody;
            bone.mBody->setWorldTransform(bodyWorld);
            bone.mMotion->setWorldTransform(bodyWorld);
            bone.mBody->setLinearVelocity(btVector3(0, 0, 0));
            bone.mBody->setAngularVelocity(btVector3(0, 0, 0));
        }
    }

    void Ragdoll::addToWorld()
    {
        if (mActive || mWorld == nullptr)
            return;
        btDiscreteDynamicsWorld& world = mWorld->getWorld();
        for (Bone& bone : mBones)
        {
            bone.mBody->activate(true);
            world.addRigidBody(bone.mBody.get(), CollisionType_Actor, CollisionType_World | CollisionType_HeightMap | CollisionType_Door);
        }
        for (auto& constraint : mConstraints)
            world.addConstraint(constraint.get(), true);
        mActive = true;
        mRestTime = 0.f;
        mAge = 0.f;
    }

    void Ragdoll::removeFromWorld()
    {
        if (!mActive || mWorld == nullptr)
            return;
        btDiscreteDynamicsWorld& world = mWorld->getWorld();
        for (auto& constraint : mConstraints)
            world.removeConstraint(constraint.get());
        for (Bone& bone : mBones)
            world.removeRigidBody(bone.mBody.get());
        mActive = false;
    }

    void Ragdoll::start(const osg::Vec3f& impulse, const std::optional<osg::Vec3f>& hitPosition)
    {
        if (mStarted)
            return;
        mStarted = true;
        seedFromBones();
        mWorld->updateStaticProxies(getRootPosition(), sProxyRadius);
        mWorld->add(this);
        addToWorld();
        if (impulse.length2() > 0.f)
        {
            // The blow lands on the body nearest to where it hit, the pelvis without one
            Bone* target = &mBones.front();
            if (hitPosition)
            {
                float best = std::numeric_limits<float>::max();
                const btVector3 hit = Misc::Convert::toBullet(*hitPosition);
                for (Bone& bone : mBones)
                {
                    const float distance = (bone.mBody->getWorldTransform().getOrigin() - hit).length2();
                    if (distance < best)
                    {
                        best = distance;
                        target = &bone;
                    }
                }
            }
            float totalMass = 0.f;
            for (const Bone& bone : mBones)
                totalMass += bone.mMass;
            // The impulse is the body's momentum whatever bone takes it: the launch speed is the same for a hand
            // and the chest, and no more than sMaxLaunchSpeed
            btVector3 total = Misc::Convert::toBullet(impulse);
            const float speed = static_cast<float>(total.length()) / totalMass;
            if (speed > sMaxLaunchSpeed)
                total *= sMaxLaunchSpeed / speed;
            // Half of it lands on the bone hit, the rest spreads over the body by mass, so it doesn't fold around
            // the hit
            const float restMass = totalMass - target->mMass;
            target->mBody->applyCentralImpulse(total * (restMass > 0.f ? 0.5f : 1.f));
            if (restMass > 0.f)
                for (Bone& bone : mBones)
                    if (&bone != target)
                        bone.mBody->applyCentralImpulse(total * 0.5f * bone.mMass / restMass);
        }
        applyToBones();
    }

    void Ragdoll::startFrozen(const std::map<std::string, btTransform, std::less<>>& pose)
    {
        if (mStarted)
            return;
        mStarted = true;
        seedFromBones();
        for (Bone& bone : mBones)
        {
            auto found = pose.find(bone.mName);
            if (found == pose.end())
                continue;
            bone.mBody->setWorldTransform(found->second);
            bone.mMotion->setWorldTransform(found->second);
        }
        applyToBones();
    }

    bool Ragdoll::isAtRest() const
    {
        if (!mStarted)
            return false;
        if (!mActive)
            return true;
        return mRestTime >= sRestSettle;
    }

    void Ragdoll::freeze()
    {
        removeFromWorld();
    }

    void Ragdoll::onStepped(float dt)
    {
        if (!mActive)
            return;
        mAge += dt;
        float totalMass = 0.f;
        float meanSpeed = 0.f;
        for (const Bone& bone : mBones)
        {
            totalMass += bone.mMass;
            meanSpeed += bone.mMass * static_cast<float>(bone.mBody->getLinearVelocity().length());
        }
        meanSpeed = totalMass > 0.f ? meanSpeed / totalMass : 0.f;
        const btRigidBody& pelvis = *mBones.front().mBody;
        const float pelvisSpeed = static_cast<float>(pelvis.getLinearVelocity().length());
        const float pelvisSpin = static_cast<float>(pelvis.getAngularVelocity().length());
        if (!mSettling && mAge >= sMinSimulated && meanSpeed < sSettleSpeed)
        {
            mSettling = true;
            for (Bone& bone : mBones)
                bone.mBody->setDamping(sSettledLinearDamping, sSettledAngularDamping);
        }
        const bool still = mAge >= sMinSimulated && pelvisSpeed < sRestLinearSpeed && meanSpeed < sRestLinearSpeed
            && pelvisSpin < sRestAngularSpeed;
        if (still)
            mRestTime += dt;
        else
            mRestTime = 0.f;
        if (mAge > sMaxSimulated)
            mRestTime = std::max(mRestTime, sRestSettle);
        applyToBones();
        if (isAtRest())
            freeze();
    }

    void Ragdoll::applyToBones()
    {
        if (!mStarted || mNodes.empty())
            return;
        // World matrices top down: a bone with a body takes the body's, the rest follow their parents; then each
        // bone's local matrix is what gets it there from its parent
        const osg::Matrixf rootWorld = worldMatrixOf(*mRoot);
        std::vector<osg::Matrixf> world(mNodes.size());
        for (std::size_t i = 0; i < mNodes.size(); ++i)
        {
            const Node& node = mNodes[i];
            const osg::Matrixf parentWorld = node.mParent >= 0 ? world[node.mParent] : rootWorld;
            if (node.mBone >= 0)
            {
                const Bone& bone = mBones[node.mBone];
                const btTransform bodyWorld = bone.mBody->getWorldTransform();
                const btTransform boneWorld = bodyWorld * bone.mBoneToBody.inverse();
                world[i] = toOsg(boneWorld);
                const osg::Matrixf local = world[i] * osg::Matrixf::inverse(parentWorld);
                node.mNode->setRotation(local.getRotate());
                node.mNode->setTranslation(local.getTrans());
            }
            else
                world[i] = node.mNode->getMatrix() * parentWorld;
        }
    }

    osg::Vec3f Ragdoll::getRootPosition() const
    {
        if (mBones.empty())
            return osg::Vec3f();
        const Bone& pelvis = mBones.front();
        if (mStarted)
            return Misc::Convert::toOsg(pelvis.mBody->getWorldTransform().getOrigin());
        return worldMatrixOf(*pelvis.mNode).getTrans();
    }

    bool Ragdoll::isFaceUp() const
    {
        if (mBones.empty())
            return true;
        // Bip01 Pelvis: its local X points up the spine and Z forward out of the belly (Gamebryo bipeds), so a body
        // on its back has that axis pointing up
        const btTransform pelvis = mBones.front().mBody->getWorldTransform() * mBones.front().mBoneToBody.inverse();
        const btVector3 forward = pelvis.getBasis().getColumn(2);
        return forward.z() > 0.f;
    }

    std::map<std::string, btTransform, std::less<>> Ragdoll::getPose() const
    {
        std::map<std::string, btTransform, std::less<>> pose;
        for (const Bone& bone : mBones)
            pose[bone.mName] = bone.mBody->getWorldTransform();
        return pose;
    }

    // ---------------------------------------------------------------- RagdollWorld

    RagdollWorld::RagdollWorld(PhysicsSystem& physics)
        : mPhysics(physics)
        , mConfiguration(std::make_unique<btDefaultCollisionConfiguration>())
        , mDispatcher(std::make_unique<btCollisionDispatcher>(mConfiguration.get()))
        , mBroadphase(std::make_unique<btDbvtBroadphase>())
        , mSolver(std::make_unique<btSequentialImpulseConstraintSolver>())
        , mWorld(std::make_unique<btDiscreteDynamicsWorld>(
              mDispatcher.get(), mBroadphase.get(), mSolver.get(), mConfiguration.get()))
    {
        mWorld->setGravity(btVector3(0, 0, -sGravity));
        mWorld->getSolverInfo().m_numIterations = 8;
    }

    RagdollWorld::~RagdollWorld()
    {
        for (Ragdoll* ragdoll : std::vector<Ragdoll*>(mRagdolls))
            ragdoll->freeze();
        for (auto& [source, proxy] : mProxies)
            mWorld->removeRigidBody(proxy.mBody.get());
        mProxies.clear();
    }

    void RagdollWorld::add(Ragdoll* ragdoll)
    {
        if (std::find(mRagdolls.begin(), mRagdolls.end(), ragdoll) == mRagdolls.end())
            mRagdolls.push_back(ragdoll);
        // Over the budget: the oldest moving body freezes where it lies
        while (getActiveCount() > sMaxActive)
        {
            auto oldest = std::find_if(mRagdolls.begin(), mRagdolls.end(),
                [&](Ragdoll* r) { return r != ragdoll && r->isActive(); });
            if (oldest == mRagdolls.end())
                break;
            (*oldest)->freeze();
        }
    }

    void RagdollWorld::remove(Ragdoll* ragdoll)
    {
        std::erase(mRagdolls, ragdoll);
    }

    std::size_t RagdollWorld::getActiveCount() const
    {
        return static_cast<std::size_t>(std::count_if(mRagdolls.begin(), mRagdolls.end(), [](const Ragdoll* r) { return r->isActive(); }));
    }

    void RagdollWorld::step(float dt)
    {
        mTime += dt;
        if (getActiveCount() == 0)
        {
            // Nothing falls: the mirrored world isn't needed
            if (!mProxies.empty())
            {
                for (auto& [source, proxy] : mProxies)
                    mWorld->removeRigidBody(proxy.mBody.get());
                mProxies.clear();
            }
            return;
        }
        mProxyCheck -= dt;
        if (mProxyCheck <= 0.f)
        {
            mProxyCheck = sProxyCheckEvery;
            for (Ragdoll* ragdoll : mRagdolls)
                if (ragdoll->isActive())
                    updateStaticProxies(ragdoll->getRootPosition(), sProxyRadius);
        }
        mWorld->stepSimulation(std::min(dt, 0.1f), sMaxSubSteps, sFixedStep);
        for (Ragdoll* ragdoll : std::vector<Ragdoll*>(mRagdolls))
            ragdoll->onStepped(dt);
    }

    namespace
    {
        struct CollectStatics : btBroadphaseAabbCallback
        {
            std::vector<const btCollisionObject*> mFound;
            bool process(const btBroadphaseProxy* proxy) override
            {
                const auto* object = static_cast<const btCollisionObject*>(proxy->m_clientObject);
                if (object != nullptr
                    && (proxy->m_collisionFilterGroup
                        & (CollisionType_World | CollisionType_HeightMap | CollisionType_Door)))
                    mFound.push_back(object);
                return true;
            }
        };
    }

    void RagdollWorld::updateStaticProxies(const osg::Vec3f& position, float radius)
    {
        const btVector3 centre = Misc::Convert::toBullet(position);
        const btVector3 extent(radius, radius, radius);
        CollectStatics callback;
        mPhysics.aabbTest(centre - extent, centre + extent, callback);
        for (const btCollisionObject* source : callback.mFound)
        {
            auto found = mProxies.find(source);
            if (found != mProxies.end())
            {
                // Doors and other animated objects move: the proxy follows
                found->second.mBody->setWorldTransform(source->getWorldTransform());
                found->second.mLastUsed = mTime;
                continue;
            }
            Proxy proxy;
            // Bullet's constructor wants a mutable shape; a massless proxy never writes to it
            btRigidBody::btRigidBodyConstructionInfo info(
                0.f, nullptr, const_cast<btCollisionShape*>(source->getCollisionShape()));
            info.m_startWorldTransform = source->getWorldTransform();
            info.m_friction = 0.8f;
            proxy.mBody = std::make_unique<btRigidBody>(info);
            proxy.mBody->setCollisionFlags(proxy.mBody->getCollisionFlags() | btCollisionObject::CF_STATIC_OBJECT);
            if (const auto* holder = static_cast<const PtrHolder*>(source->getUserPointer()))
                if (const auto* object = dynamic_cast<const Object*>(holder))
                    proxy.mShapeInstance = object->getShapeInstance();
            proxy.mLastUsed = mTime;
            mWorld->addRigidBody(proxy.mBody.get(), CollisionType_World, CollisionType_Actor);
            mProxies.emplace(source, std::move(proxy));
        }
        // Proxies nothing has needed for a while go
        for (auto it = mProxies.begin(); it != mProxies.end();)
        {
            if (mTime - it->second.mLastUsed > 5.f)
            {
                mWorld->removeRigidBody(it->second.mBody.get());
                it = mProxies.erase(it);
            }
            else
                ++it;
        }
    }

    void RagdollWorld::onCollisionObjectRemoved(const btCollisionObject* object)
    {
        auto found = mProxies.find(object);
        if (found == mProxies.end())
            return;
        mWorld->removeRigidBody(found->second.mBody.get());
        mProxies.erase(found);
    }
}
