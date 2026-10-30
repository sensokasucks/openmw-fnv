#ifndef OPENMW_COMPONENTS_SCENEUTIL_DISMEMBERPARTITIONS_H
#define OPENMW_COMPONENTS_SCENEUTIL_DISMEMBERPARTITIONS_H

#include <cstdint>
#include <vector>

#include <osg/Geometry>
#include <osg/Object>
#include <osg/PrimitiveSet>

namespace SceneUtil
{
    /// The body part partitions (BSDismemberSkinInstance) of a skinned shape, with their primitive sets, so dismembered
    /// limbs can be hidden and their caps shown. Kept in the user data container of the source geometry; the geometry's
    /// own primitive sets are the intact body (every part but the caps, 100-999).
    class DismemberPartitions : public osg::Object
    {
    public:
        DismemberPartitions() = default;
        DismemberPartitions(const DismemberPartitions& copy, const osg::CopyOp& copyop)
            : osg::Object(copy, copyop)
            , mParts(copy.mParts)
        {
        }

        META_Object(SceneUtil, DismemberPartitions)

        struct Part
        {
            std::uint16_t mBodyPart;
            osg::ref_ptr<osg::PrimitiveSet> mPrimitives;
        };
        std::vector<Part> mParts;

        static bool isCap(std::uint16_t bodyPart) { return bodyPart >= 100 && bodyPart < 1000; }

        static const DismemberPartitions* get(const osg::Geometry& geometry)
        {
            const osg::UserDataContainer* container = geometry.getUserDataContainer();
            if (container == nullptr)
                return nullptr;
            for (unsigned int i = 0; i < container->getNumUserObjects(); ++i)
                if (auto parts = dynamic_cast<const DismemberPartitions*>(container->getUserObject(i)))
                    return parts;
            return nullptr;
        }
    };
}

#endif
