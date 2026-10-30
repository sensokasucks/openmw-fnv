#include "bulletnifloader.hpp"

#include <cassert>
#include <sstream>
#include <tuple>
#include <variant>
#include <vector>

#include <components/debug/debuglog.hpp>
#include <components/files/conversion.hpp>
#include <components/misc/convert.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/nif/controller.hpp>
#include <components/nif/extra.hpp>
#include <components/nif/nifstream.hpp>
#include <components/nif/data.hpp>
#include <components/nif/node.hpp>
#include <components/nif/parent.hpp>
#include <components/nif/physics.hpp>

#include <BulletCollision/CollisionShapes/btBoxShape.h>
#include <BulletCollision/CollisionShapes/btConvexHullShape.h>
#include <BulletCollision/CollisionShapes/btMultiSphereShape.h>
#include <BulletCollision/CollisionShapes/btSphereShape.h>
#include <BulletCollision/CollisionShapes/btTriangleMesh.h>

namespace
{

    bool pathFileNameStartsWithX(const std::string& path)
    {
        const std::size_t slashpos = path.find_last_of("/\\");
        const std::size_t letterPos = slashpos == std::string::npos ? 0 : slashpos + 1;
        return letterPos < path.size() && (path[letterPos] == 'x' || path[letterPos] == 'X');
    }

}

namespace NifBullet
{

    float havokScaleFor(std::uint32_t bethVersion)
    {
        return bethVersion >= 83 ? 69.969f : 6.9969f;
    }

    bool isSolidLayer(int layer)
    {
        switch (layer)
        {
            case 8: // BIPED (ragdoll bodies)
            case 11: // WATER
            case 12: // TRIGGER
            case 14: // TRAP
            case 15: // NONCOLLIDABLE
            case 16: // CLOUDTRAP
            case 18: // PORTAL
            case 21: // ACOUSTIC_SPACE
            case 22: // ACTORZONE
            case 23: // PROJECTILEZONE
            case 24: // GASTRAP
            case 25: // SHELLCASING
            case 29: // DEADBIP
            case 30: // CHARCONTROLLER
                return false;
            default:
                return layer < 31 || layer > 42; // AVOIDBOX .. DROPPINGPICK
        }
    }

    namespace
    {
        btVector3 toBullet(const osg::Vec4f& v, float scale)
        {
            return btVector3(v.x() * scale, v.y() * scale, v.z() * scale);
        }

        btVector3 toBullet(const osg::Vec3f& v, float scale)
        {
            return btVector3(v.x() * scale, v.y() * scale, v.z() * scale);
        }

        std::unique_ptr<btCollisionShape> withTransform(
            std::unique_ptr<btCollisionShape> shape, const btTransform& transform)
        {
            if (shape == nullptr)
                return nullptr;
            if (transform.getOrigin().isZero() && transform.getRotation().angle(btQuaternion::getIdentity()) < 1e-4f)
                return shape;
            auto compound = std::make_unique<btCompoundShape>();
            compound->addChildShape(transform, shape.release());
            return compound;
        }

        btTransform bodyTransform(const Nif::bhkRigidBody& body, bool transformed, float havokScale)
        {
            btTransform transform = btTransform::getIdentity();
            if (!transformed)
                return transform;
            const osg::Quat& q = body.mInfo.mRotation;
            transform.setRotation(btQuaternion(q.x(), q.y(), q.z(), q.w()));
            transform.setOrigin(toBullet(body.mInfo.mTranslation, havokScale));
            return transform;
        }
    }


    osg::ref_ptr<Resource::BulletShape> BulletNifLoader::load(Nif::FileView nif)
    {
        mShape = new Resource::BulletShape;

        mCompoundShape.reset();
        mAvoidCompoundShape.reset();
        mAnimatedTargets.clear();
        mBhkFound = false;

        mShape->mFileHash = nif.getHash();

        const size_t numRoots = nif.numRoots();
        std::vector<const Nif::NiAVObject*> roots;
        for (size_t i = 0; i < numRoots; ++i)
        {
            const Nif::Record* r = nif.getRoot(i);
            if (!r)
                continue;
            const Nif::NiAVObject* node = dynamic_cast<const Nif::NiAVObject*>(r);
            if (node)
                roots.emplace_back(node);
        }
        mShape->mFileName = nif.getFilename();
        if (roots.empty())
        {
            warn("Found no root nodes in NIF file " + mShape->mFileName.value());
            return mShape;
        }

        for (const Nif::NiAVObject* node : roots)
            if (findBoundingBox(*node))
                break;

        HandleNodeArgs args;

        // files with the name convention xmodel.nif usually have keyframes stored in a separate file xmodel.kf (see
        // Animation::addAnimSource). assume all nodes in the file will be animated
        // TODO: investigate whether this should and could be optimized.
        args.mAnimated = pathFileNameStartsWithX(mShape->mFileName);

        for (const Nif::NiAVObject* node : roots)
            handleRoot(nif, *node, args);

        if (mCompoundShape)
            mShape->mCollisionShape = std::move(mCompoundShape);

        if (mAvoidCompoundShape)
            mShape->mAvoidCollisionShape = std::move(mAvoidCompoundShape);

        return mShape;
    }

    // Find a bounding box in the node hierarchy to use for actor collision
    bool BulletNifLoader::findBoundingBox(const Nif::NiAVObject& node)
    {
        if (Misc::StringUtils::ciEqual(node.mName, "Bounding Box"))
        {
            if (node.mBounds.mType == Nif::BoundingVolume::Type::BOX_BV
                && std::ranges::all_of(node.mBounds.mBox.mExtents._v, [](float extent) { return extent > 0.f; }))
            {
                mShape->mCollisionBox.mExtents = node.mBounds.mBox.mExtents;
                mShape->mCollisionBox.mCenter = node.mBounds.mBox.mCenter;
            }
            else
            {
                warn("Invalid Bounding Box node bounds in file " + mShape->mFileName.value());
            }
            return true;
        }

        if (auto ninode = dynamic_cast<const Nif::NiNode*>(&node))
            for (const auto& child : ninode->mChildren)
                if (!child.empty() && findBoundingBox(child.get()))
                    return true;

        return false;
    }

    void BulletNifLoader::handleRoot(Nif::FileView nif, const Nif::NiAVObject& node, HandleNodeArgs args)
    {
        // Gamebryo/Bethbryo meshes
        if (nif.getVersion() >= Nif::NIFStream::generateVersion(10, 0, 1, 0))
        {
            // Handle BSXFlags
            const Nif::NiIntegerExtraData* bsxFlags = nullptr;
            for (const auto& e : node.getExtraList())
            {
                if (!e.empty() && e->mRecordType == Nif::RC_BSXFlags)
                {
                    bsxFlags = static_cast<const Nif::NiIntegerExtraData*>(e.getPtr());
                    break;
                }
            }

            // Collision flag
            if (!bsxFlags || !(bsxFlags->mData & 2))
                return;

            // Editor marker flag
            if (bsxFlags->mData & 32)
                args.mHasMarkers = true;

            // The Bethesda Havok data (bhkCollisionObject on the nodes) is the collision the game plays with:
            // collision-only geometry, invisible walls, no collision on leaves and clutter the designers left out.
            // Only a file without any falls back on its rendered geometry.
            if (handleBhkTree(node, nullptr, args, havokScaleFor(nif.getBethVersion())))
                return;
            args.mGenerateCollision = true;
        }
        // Pre-Gamebryo meshes
        else
        {
            bool recursiveRcn = false;
            // Check for extra data
            for (const auto& e : node.getExtraList())
            {
                if (!e.empty() && e->mRecordType == Nif::RC_NiStringExtraData)
                {
                    // String markers may contain important information
                    // affecting the entire subtree of this node
                    auto sd = static_cast<const Nif::NiStringExtraData*>(e.getPtr());

                    // Editor marker flag
                    if (sd->mData == "MRK")
                        args.mHasTriMarkers = true;
                    else if (Misc::StringUtils::ciStartsWith(sd->mData, "NC"))
                    {
                        // NC prefix is case-insensitive but the second C in NCC flag needs be uppercase.

                        // Collide only with camera.
                        if (sd->mData.length() > 2 && sd->mData[2] == 'C')
                            mShape->mVisualCollisionType = Resource::VisualCollisionType::Camera;
                        // No collision.
                        else
                            mShape->mVisualCollisionType = Resource::VisualCollisionType::Default;
                    }
                    else if (sd->mData == "RCN")
                        recursiveRcn = true;
                }
            }

            const Nif::NiNode* ninode = dynamic_cast<const Nif::NiNode*>(&node);
            if (ninode)
                args.mCollisionNode = ninode->findRootCollisionNode(recursiveRcn);
            if (!args.mCollisionNode)
                args.mGenerateCollision = true;
            else if (args.mCollisionNode->mChildren.empty())
            {
                // FIXME: BulletNifLoader should never have to provide rendered geometry for camera collision
                args.mGenerateCollision = true;
                mShape->mVisualCollisionType = Resource::VisualCollisionType::Camera;
            }
        }

        handleNode(node, nullptr, args);
    }

    void BulletNifLoader::handleNode(const Nif::NiAVObject& node, const Nif::Parent* parent, HandleNodeArgs args)
    {
        // TODO: allow on-the fly collision switching via toggling this flag
        if (node.mRecordType == Nif::RC_NiCollisionSwitch && !node.collisionActive())
            return;

        for (Nif::NiTimeControllerPtr ctrl = node.mController; !ctrl.empty(); ctrl = ctrl->mNext)
        {
            if (args.mAnimated)
                break;
            if (!ctrl->isActive())
                continue;
            switch (ctrl->mRecordType)
            {
                case Nif::RC_NiKeyframeController:
                case Nif::RC_NiPathController:
                case Nif::RC_NiRollController:
                    args.mAnimated = true;
                    break;
                case Nif::RC_NiMultiTargetTransformController:
                    // Usually on the root of FO3/FNV doors and gates; the nodes it moves are its extra targets
                    for (const auto& target : static_cast<const Nif::NiMultiTargetTransformController&>(ctrl.get())
                                                  .mExtraTargets)
                        if (!target.empty())
                            mAnimatedTargets.insert(target.getPtr());
                    break;
                default:
                    continue;
            }
        }

        if (mAnimatedTargets.contains(&node))
            args.mAnimated = true;

        if (node.mRecordType == Nif::RC_RootCollisionNode)
        {
            // Encountered our RootCollisionNode inside an autogenerated mesh.
            // We treat empty RootCollisionNodes as NCC flag (set collisionType to `Camera`)
            // and generate the camera collision shape based on rendered geometry.
            if (args.mCollisionNode == &node && args.mGenerateCollision
                && mShape->mVisualCollisionType == Resource::VisualCollisionType::Camera)
                return;

            // Standard handling
            if (!args.mCollisionNode)
            {
                Log(Debug::Info) << "BulletNifLoader: Unexpected RootCollisionNode in " << mShape->mFileName
                                 << ". Treating as visible geometry.";
            }
            else if (args.mCollisionNode != &node)
            {
                Log(Debug::Info) << "BulletNifLoader: Extra RootCollisionNode in " << mShape->mFileName
                                 << ". Treating as visible geometry.";
            }
            else
            {
                args.mGenerateCollision = true;
            }
        }

        // Don't collide with AvoidNode shapes
        if (node.mRecordType == Nif::RC_AvoidNode)
            args.mAvoid = true;

        if (args.mGenerateCollision)
        {
            auto geometry = dynamic_cast<const Nif::NiGeometry*>(&node);
            if (geometry)
                handleGeometry(*geometry, parent, args);
        }

        // For NiNodes, loop through children
        if (const Nif::NiNode* ninode = dynamic_cast<const Nif::NiNode*>(&node))
        {
            const Nif::Parent currentParent{ *ninode, parent };
            for (const auto& child : ninode->mChildren)
            {
                if (!child.empty())
                {
                    assert(std::find(child->mParents.begin(), child->mParents.end(), ninode) != child->mParents.end());
                    handleNode(child.get(), &currentParent, args);
                }
                // For NiSwitchNodes and NiFltAnimationNodes, only use the first child
                // TODO: must synchronize with the rendering scene graph somehow
                // Doing this for NiLODNodes is unsafe (the first level might not be the closest)
                if (node.mRecordType == Nif::RC_NiSwitchNode || node.mRecordType == Nif::RC_NiFltAnimationNode)
                    break;
            }
        }
    }

    void BulletNifLoader::handleGeometry(
        const Nif::NiGeometry& niGeometry, const Nif::Parent* nodeParent, HandleNodeArgs args)
    {
        // This flag comes from BSXFlags
        if (args.mHasMarkers && Misc::StringUtils::ciStartsWith(niGeometry.mName, "EditorMarker"))
            return;

        // This flag comes from Morrowind
        if (args.mHasTriMarkers && Misc::StringUtils::ciStartsWith(niGeometry.mName, "Tri EditorMarker"))
            return;

        if (!niGeometry.mSkin.empty())
            args.mAnimated = false;

        std::unique_ptr<btCollisionShape> childShape = niGeometry.getCollisionShape();
        if (childShape == nullptr)
            return;

        osg::Matrixf transform = niGeometry.mTransform.toMatrix();
        for (const Nif::Parent* parent = nodeParent; parent != nullptr; parent = parent->mParent)
            transform *= parent->mNiNode.mTransform.toMatrix();

        if (childShape->getShapeType() == TRIANGLE_MESH_SHAPE_PROXYTYPE)
        {
            auto scaledShape = std::make_unique<Resource::ScaledTriangleMeshShape>(
                static_cast<btBvhTriangleMeshShape*>(childShape.get()), Misc::Convert::toBullet(transform.getScale()));
            std::ignore = childShape.release();

            childShape = std::move(scaledShape);
        }
        else
        {
            childShape->setLocalScaling(Misc::Convert::toBullet(transform.getScale()));
        }

        transform.orthoNormalize(transform);

        btTransform trans;
        trans.setOrigin(Misc::Convert::toBullet(transform.getTrans()));
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                trans.getBasis()[i][j] = transform(j, i);

        if (!args.mAvoid)
        {
            if (!mCompoundShape)
                mCompoundShape.reset(new btCompoundShape);

            if (args.mAnimated)
                mShape->mAnimatedShapes.emplace(niGeometry.mRecordIndex, mCompoundShape->getNumChildShapes());
            mCompoundShape->addChildShape(trans, childShape.get());
        }
        else
        {
            if (!mAvoidCompoundShape)
                mAvoidCompoundShape.reset(new btCompoundShape);
            mAvoidCompoundShape->addChildShape(trans, childShape.get());
        }

        std::ignore = childShape.release();
    }


    bool BulletNifLoader::handleBhkTree(
        const Nif::NiAVObject& node, const Nif::Parent* parent, HandleNodeArgs args, float havokScale)
    {
        if (node.mRecordType == Nif::RC_NiCollisionSwitch && !node.collisionActive())
            return false;

        for (Nif::NiTimeControllerPtr ctrl = node.mController; !ctrl.empty(); ctrl = ctrl->mNext)
        {
            if (args.mAnimated)
                break;
            if (!ctrl->isActive())
                continue;
            switch (ctrl->mRecordType)
            {
                case Nif::RC_NiKeyframeController:
                case Nif::RC_NiPathController:
                case Nif::RC_NiRollController:
                    args.mAnimated = true;
                    break;
                case Nif::RC_NiMultiTargetTransformController:
                    for (const auto& target : static_cast<const Nif::NiMultiTargetTransformController&>(ctrl.get())
                                                  .mExtraTargets)
                        if (!target.empty())
                            mAnimatedTargets.insert(target.getPtr());
                    break;
                default:
                    continue;
            }
        }
        if (mAnimatedTargets.contains(&node))
            args.mAnimated = true;

        bool found = false;
        if (!node.mCollision.empty()
            && (node.mCollision->mRecordType == Nif::RC_bhkCollisionObject
                || node.mCollision->mRecordType == Nif::RC_bhkBlendCollisionObject))
        {
            const auto& collision = static_cast<const Nif::bhkCollisionObject&>(node.mCollision.get());
            if (!collision.mBody.empty()
                && (collision.mBody->mRecordType == Nif::RC_bhkRigidBody
                    || collision.mBody->mRecordType == Nif::RC_bhkRigidBodyT))
            {
                const auto& body = static_cast<const Nif::bhkRigidBody&>(collision.mBody.get());
                const int before = mCompoundShape ? mCompoundShape->getNumChildShapes() : 0;
                handleBhkBody(node, body, collision.mBody->mRecordType == Nif::RC_bhkRigidBodyT, parent, args,
                    havokScale);
                found = mCompoundShape && mCompoundShape->getNumChildShapes() > before;
            }
        }

        if (const Nif::NiNode* ninode = dynamic_cast<const Nif::NiNode*>(&node))
        {
            const Nif::Parent currentParent{ *ninode, parent };
            for (const auto& child : ninode->mChildren)
            {
                if (!child.empty())
                    found = handleBhkTree(child.get(), &currentParent, args, havokScale) || found;
                if (node.mRecordType == Nif::RC_NiSwitchNode || node.mRecordType == Nif::RC_NiFltAnimationNode)
                    break;
            }
        }
        return found;
    }

    void BulletNifLoader::handleBhkBody(const Nif::NiAVObject& node, const Nif::bhkRigidBody& body,
        bool transformed, const Nif::Parent* parent, const HandleNodeArgs& args, float havokScale)
    {
        if (body.mShape.empty())
            return;
        const int layer = body.mHavokFilter.mLayer;
        if (!isSolidLayer(layer))
            return;
        std::unique_ptr<btCollisionShape> shape = makeBhkShape(body.mShape.get(), havokScale, layer, false);
        if (shape == nullptr)
            return;
        // The body sits in the node's space (a bhkRigidBodyT with its own offset, which the shape keeps as its own
        // compound so an animated node moves it along), the node in the world's
        shape = withTransform(std::move(shape), bodyTransform(body, transformed, havokScale));

        osg::Matrixf transform = node.mTransform.toMatrix();
        for (const Nif::Parent* p = parent; p != nullptr; p = p->mParent)
            transform *= p->mNiNode.mTransform.toMatrix();
        shape->setLocalScaling(Misc::Convert::toBullet(transform.getScale()));
        transform.orthoNormalize(transform);

        btTransform trans;
        trans.setOrigin(Misc::Convert::toBullet(transform.getTrans()));
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                trans.getBasis()[i][j] = transform(j, i);

        if (!mCompoundShape)
            mCompoundShape.reset(new btCompoundShape);
        if (args.mAnimated)
            mShape->mAnimatedShapes.emplace(node.mRecordIndex, mCompoundShape->getNumChildShapes());
        mCompoundShape->addChildShape(trans, shape.release());
        mBhkFound = true;

        // A body with a dynamic motion type and a mass on the root (the first body found) is loose clutter the
        // game can push around; a second body on the file makes it a jointed thing this doesn't handle
        using Nif::HkMotionType;
        const HkMotionType motion = body.mInfo.mMotionType;
        const bool dynamic = motion == HkMotionType::Motion_Dynamic || motion == HkMotionType::Motion_SphereInertia
            || motion == HkMotionType::Motion_SphereStabilized || motion == HkMotionType::Motion_BoxInertia
            || motion == HkMotionType::Motion_BoxStabilized || motion == HkMotionType::Motion_ThinBox;
        if (mCompoundShape->getNumChildShapes() == 1 && parent == nullptr && dynamic && body.mInfo.mMass > 0.f)
        {
            Resource::BulletShape::DynamicBody info;
            info.mMass = body.mInfo.mMass;
            info.mFriction = body.mInfo.mFriction;
            info.mRestitution = body.mInfo.mRestitution;
            info.mLinearDamping = body.mInfo.mLinearDamping;
            info.mAngularDamping = body.mInfo.mAngularDamping;
            info.mWind = (body.mBodyFlags & 1) != 0;
            mShape->mDynamicBody = info;
        }
        else
            mShape->mDynamicBody.reset();
    }

    std::unique_ptr<btCollisionShape> makeBhkShape(
        const Nif::bhkShape& shape, float havokScale, int layer, bool anyLayer)
    {
        const auto solid = [anyLayer](int l) { return anyLayer || isSolidLayer(l); };
        switch (shape.mRecordType)
        {
            case Nif::RC_bhkBoxShape:
            {
                const auto& box = static_cast<const Nif::bhkBoxShape&>(shape);
                return std::make_unique<btBoxShape>(toBullet(box.mExtents, havokScale));
            }
            case Nif::RC_bhkSphereShape:
            {
                const auto& sphere = static_cast<const Nif::bhkSphereShape&>(shape);
                return std::make_unique<btSphereShape>(sphere.mRadius * havokScale);
            }
            case Nif::RC_bhkCapsuleShape:
            {
                // Two spheres joined: a capsule along any axis
                const auto& capsule = static_cast<const Nif::bhkCapsuleShape&>(shape);
                const btVector3 positions[2]
                    = { toBullet(capsule.mPoint1, havokScale), toBullet(capsule.mPoint2, havokScale) };
                const btScalar radii[2] = { capsule.mRadius1 * havokScale, capsule.mRadius2 * havokScale };
                return std::make_unique<btMultiSphereShape>(positions, radii, 2);
            }
            case Nif::RC_bhkMultiSphereShape:
            {
                const auto& multi = static_cast<const Nif::bhkMultiSphereShape&>(shape);
                if (multi.mSpheres.empty())
                    return nullptr;
                std::vector<btVector3> positions;
                std::vector<btScalar> radii;
                for (const osg::BoundingSpheref& sphere : multi.mSpheres)
                {
                    positions.push_back(toBullet(sphere.center(), havokScale));
                    radii.push_back(sphere.radius() * havokScale);
                }
                return std::make_unique<btMultiSphereShape>(
                    positions.data(), radii.data(), static_cast<int>(positions.size()));
            }
            case Nif::RC_bhkCylinderShape:
            {
                // A cylinder along any axis: the convex hull of two rings
                const auto& cylinder = static_cast<const Nif::bhkCylinderShape&>(shape);
                const btVector3 a = toBullet(cylinder.mVertexA, havokScale);
                const btVector3 b = toBullet(cylinder.mVertexB, havokScale);
                btVector3 axis = b - a;
                if (axis.length2() < 1e-6f)
                    return nullptr;
                axis.normalize();
                btVector3 side = axis.cross(std::abs(axis.z()) < 0.9f ? btVector3(0, 0, 1) : btVector3(1, 0, 0));
                side.normalize();
                const btVector3 up = axis.cross(side);
                auto hull = std::make_unique<btConvexHullShape>();
                const float radius = cylinder.mCylinderRadius * havokScale;
                for (int i = 0; i < 16; ++i)
                {
                    const float angle = static_cast<float>(i) / 16.f * 2.f * osg::PIf;
                    const btVector3 ring = (side * std::cos(angle) + up * std::sin(angle)) * radius;
                    hull->addPoint(a + ring, false);
                    hull->addPoint(b + ring, false);
                }
                hull->recalcLocalAabb();
                return hull;
            }
            case Nif::RC_bhkConvexVerticesShape:
            {
                const auto& convex = static_cast<const Nif::bhkConvexVerticesShape&>(shape);
                if (convex.mVertices.size() < 3)
                    return nullptr;
                auto hull = std::make_unique<btConvexHullShape>();
                for (const osg::Vec4f& vertex : convex.mVertices)
                    hull->addPoint(toBullet(vertex, havokScale), false);
                hull->recalcLocalAabb();
                return hull;
            }
            case Nif::RC_bhkConvexTransformShape:
            {
                const auto& transformShape = static_cast<const Nif::bhkConvexTransformShape&>(shape);
                if (transformShape.mShape.empty())
                    return nullptr;
                std::unique_ptr<btCollisionShape> child = makeBhkShape(transformShape.mShape.get(), havokScale, layer, anyLayer);
                if (child == nullptr)
                    return nullptr;
                osg::Matrixf matrix = transformShape.mTransform;
                btTransform transform;
                transform.setOrigin(Misc::Convert::toBullet(matrix.getTrans()) * havokScale);
                matrix.orthoNormalize(matrix);
                for (int i = 0; i < 3; ++i)
                    for (int j = 0; j < 3; ++j)
                        transform.getBasis()[i][j] = matrix(j, i);
                auto compound = std::make_unique<btCompoundShape>();
                compound->addChildShape(transform, child.release());
                return compound;
            }
            case Nif::RC_bhkListShape:
            {
                const auto& list = static_cast<const Nif::bhkListShape&>(shape);
                auto compound = std::make_unique<btCompoundShape>();
                for (std::size_t i = 0; i < list.mSubshapes.size(); ++i)
                {
                    const auto& sub = list.mSubshapes[i];
                    if (sub.empty())
                        continue;
                    const int subLayer = i < list.mHavokFilters.size() ? list.mHavokFilters[i].mLayer : layer;
                    if (!solid(subLayer))
                        continue;
                    if (std::unique_ptr<btCollisionShape> child = makeBhkShape(sub.get(), havokScale, subLayer, anyLayer))
                        compound->addChildShape(btTransform::getIdentity(), child.release());
                }
                if (compound->getNumChildShapes() == 0)
                    return nullptr;
                return compound;
            }
            case Nif::RC_bhkMoppBvTreeShape:
            {
                // The MOPP code is Havok's own acceleration tree; Bullet builds its own over the mesh
                const auto& mopp = static_cast<const Nif::bhkMoppBvTreeShape&>(shape);
                if (mopp.mShape.empty())
                    return nullptr;
                return makeBhkShape(mopp.mShape.get(), havokScale, layer, anyLayer);
            }
            case Nif::RC_bhkPackedNiTriStripsShape:
            {
                const auto& packed = static_cast<const Nif::bhkPackedNiTriStripsShape&>(shape);
                if (packed.mData.empty())
                    return nullptr;
                const auto& data = static_cast<const Nif::hkPackedNiTriStripsData&>(packed.mData.get());
                if (data.mVertices.empty() || data.mTriangles.empty())
                    return nullptr;
                // The subshapes own runs of vertices in turn; a triangle belongs to the subshape of its vertices
                const std::vector<Nif::hkSubPartData>& subshapes
                    = data.mSubshapes.empty() ? packed.mSubshapes : data.mSubshapes;
                std::vector<bool> solidVertex(data.mVertices.size(), true);
                if (!subshapes.empty())
                {
                    std::size_t vertex = 0;
                    for (const Nif::hkSubPartData& sub : subshapes)
                    {
                        const bool subSolid = solid(sub.mHavokFilter.mLayer);
                        for (std::uint32_t i = 0; i < sub.mNumVertices && vertex < solidVertex.size(); ++i, ++vertex)
                            solidVertex[vertex] = subSolid;
                    }
                }
                const btVector3 scale(havokScale, havokScale, havokScale);
                auto mesh = std::make_unique<btTriangleMesh>();
                for (const Nif::TriangleData& triangle : data.mTriangles)
                {
                    const auto& t = triangle.mTriangle;
                    if (t[0] >= data.mVertices.size() || t[1] >= data.mVertices.size() || t[2] >= data.mVertices.size())
                        continue;
                    if (!solidVertex[t[0]] && !solidVertex[t[1]] && !solidVertex[t[2]])
                        continue;
                    mesh->addTriangle(Misc::Convert::toBullet(data.mVertices[t[0]]) * scale,
                        Misc::Convert::toBullet(data.mVertices[t[1]]) * scale,
                        Misc::Convert::toBullet(data.mVertices[t[2]]) * scale);
                }
                if (mesh->getNumTriangles() == 0)
                    return nullptr;
                auto meshShape = std::make_unique<Resource::TriangleMeshShape>(mesh.get(), true);
                std::ignore = mesh.release();
                return meshShape;
            }
            case Nif::RC_bhkNiTriStripsShape:
            {
                const auto& strips = static_cast<const Nif::bhkNiTriStripsShape&>(shape);
                const btVector3 scale(havokScale * strips.mScale.x(), havokScale * strips.mScale.y(),
                    havokScale * strips.mScale.z());
                auto mesh = std::make_unique<btTriangleMesh>();
                for (std::size_t i = 0; i < strips.mData.size(); ++i)
                {
                    const auto& dataPtr = strips.mData[i];
                    if (dataPtr.empty())
                        continue;
                    const int subLayer = i < strips.mHavokFilters.size() ? strips.mHavokFilters[i].mLayer : layer;
                    if (!solid(subLayer))
                        continue;
                    const Nif::NiTriStripsData& data = dataPtr.get();
                    for (const std::vector<unsigned short>& strip : data.mStrips)
                    {
                        if (strip.size() < 3)
                            continue;
                        for (std::size_t j = 0; j + 2 < strip.size(); ++j)
                        {
                            const unsigned short a = strip[j], b = strip[j + 1], c = strip[j + 2];
                            if (a == b || b == c || a == c)
                                continue;
                            if (a >= data.mVertices.size() || b >= data.mVertices.size() || c >= data.mVertices.size())
                                continue;
                            if (j % 2 == 0)
                                mesh->addTriangle(Misc::Convert::toBullet(data.mVertices[a]) * scale,
                                    Misc::Convert::toBullet(data.mVertices[b]) * scale,
                                    Misc::Convert::toBullet(data.mVertices[c]) * scale);
                            else
                                mesh->addTriangle(Misc::Convert::toBullet(data.mVertices[a]) * scale,
                                    Misc::Convert::toBullet(data.mVertices[c]) * scale,
                                    Misc::Convert::toBullet(data.mVertices[b]) * scale);
                        }
                    }
                }
                if (mesh->getNumTriangles() == 0)
                    return nullptr;
                auto meshShape = std::make_unique<Resource::TriangleMeshShape>(mesh.get(), true);
                std::ignore = mesh.release();
                return meshShape;
            }
            default:
                // Phantoms, planes, heightfields and Skyrim's compressed meshes are not built
                return nullptr;
        }
    }

} // namespace NifBullet
