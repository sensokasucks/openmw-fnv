#ifndef OPENMW_COMPONENTS_NIFBULLET_BULLETNIFLOADER_HPP
#define OPENMW_COMPONENTS_NIFBULLET_BULLETNIFLOADER_HPP

#include <cassert>
#include <map>
#include <memory>
#include <set>
#include <string>

#include <osg/BoundingBox>
#include <osg/Referenced>
#include <osg/ref_ptr>

#include <BulletCollision/CollisionShapes/btCompoundShape.h>

#include <components/debug/debuglog.hpp>
#include <components/nif/niffile.hpp>
#include <components/resource/bulletshape.hpp>

class btTriangleMesh;
class btCompoundShape;
class btCollisionShape;

namespace Nif
{
    struct NiAVObject;
    struct NiNode;
    struct NiGeometry;
    struct Parent;
    struct bhkShape;
    struct bhkRigidBody;
}

namespace NifBullet
{
    // Havok units (meters) to game units: the community's bhkScaleFactor, 6.9969 for Oblivion, FO3 and FNV
    // (Bethesda version below 83) and ten times that for Skyrim
    float havokScaleFor(std::uint32_t bethVersion);

    // Collision layers (FalloutNV.exe layer name table) that are solid for the world; triggers, zones, pick
    // volumes, water and the ragdoll and character controller shapes of skeletons are not
    bool isSolidLayer(int layer);

    // A Bullet shape for a bhk shape record, nullptr for the kinds not built (phantoms, planes, compressed meshes)
    // and, unless anyLayer, for sub-shapes on layers that are not solid. Ragdoll bodies pass anyLayer.
    std::unique_ptr<btCollisionShape> makeBhkShape(
        const Nif::bhkShape& shape, float havokScale, int layer, bool anyLayer = false);

    /**
     *Load bulletShape from NIF files.
     */
    class BulletNifLoader
    {
    public:
        void warn(const std::string& msg) { Log(Debug::Warning) << "NIFLoader: Warn: " << msg; }

        [[noreturn]] void fail(const std::string& msg)
        {
            Log(Debug::Error) << "NIFLoader: Fail: " << msg;
            abort();
        }

        osg::ref_ptr<Resource::BulletShape> load(Nif::FileView file);

    private:
        bool findBoundingBox(const Nif::NiAVObject& node);

        struct HandleNodeArgs
        {
            bool mHasMarkers{ false };
            bool mHasTriMarkers{ false };
            bool mAnimated{ false };
            bool mGenerateCollision{ false };
            bool mAvoid{ false };
            const Nif::NiNode* mCollisionNode{ nullptr };
        };

        void handleRoot(Nif::FileView nif, const Nif::NiAVObject& node, HandleNodeArgs args);
        void handleNode(const Nif::NiAVObject& node, const Nif::Parent* parent, HandleNodeArgs args);
        void handleGeometry(const Nif::NiGeometry& nifNode, const Nif::Parent* parent, HandleNodeArgs args);

        // Bethesda Havok collision (bhkCollisionObject on the nodes, FO3/FNV/Skyrim): walks the tree and adds the
        // rigid bodies' shapes, scaled from Havok units by havokScale. True when any shape was found, in which case
        // the rendered geometry is not used for collision.
        bool handleBhkTree(const Nif::NiAVObject& node, const Nif::Parent* parent, HandleNodeArgs args, float havokScale);
        void handleBhkBody(const Nif::NiAVObject& node, const Nif::bhkRigidBody& body, bool transformed,
            const Nif::Parent* parent, const HandleNodeArgs& args, float havokScale);
        bool mBhkFound{ false };

        std::unique_ptr<btCompoundShape, Resource::DeleteCollisionShape> mCompoundShape;
        std::unique_ptr<btCompoundShape, Resource::DeleteCollisionShape> mAvoidCompoundShape;

        osg::ref_ptr<Resource::BulletShape> mShape;

        // Nodes moved by a NiMultiTargetTransformController higher up the tree (Bethesda embedded animations)
        std::set<const Nif::NiAVObject*> mAnimatedTargets;
    };

}

#endif
