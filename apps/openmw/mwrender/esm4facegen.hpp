#ifndef GAME_RENDER_ESM4FACEGEN_H
#define GAME_RENDER_ESM4FACEGEN_H

#include <string_view>
#include <vector>

namespace osg
{
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
}

#endif
