#ifndef GAME_RENDER_ESM4FACEGEN_H
#define GAME_RENDER_ESM4FACEGEN_H

#include <string_view>
#include <vector>

#include <osg/ref_ptr>

namespace osg
{
    class Image;
    class Node;
}

namespace VFS
{
    class Manager;
}

namespace MWRender
{
    // Applies FaceGen shape morphs (the .egm next to a head part mesh) to an attached FO3/FONV head part.
    // symmetric/asymmetric are the NPC's FGGS and FGGA coefficients.
    void applyFaceGenShape(osg::Node& part, std::string_view model, const std::vector<float>& symmetric,
        const std::vector<float>& asymmetric, const VFS::Manager& vfs);

    // Returns the face texture with the FaceGen texture morphs (the .egt next to the head mesh) added, or null when
    // the mesh has none. textureModes are the NPC's FGTS coefficients.
    osg::ref_ptr<osg::Image> makeFaceGenTexture(const osg::Image& base, std::string_view model,
        const std::vector<float>& textureModes, const VFS::Manager& vfs);
}

#endif
