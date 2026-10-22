#include "esm4facegen.hpp"

#include <array>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>

#include <osg/Geometry>
#include <osg/Group>
#include <osg/NodeVisitor>

#include <components/debug/debuglog.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/sceneutil/riggeometry.hpp>
#include <components/vfs/manager.hpp>
#include <components/vfs/pathutil.hpp>

namespace MWRender
{
    namespace
    {
        // FaceGen "FREGM002": per vertex int16 offsets for each symmetric, then each asymmetric shape mode.
        struct Egm
        {
            struct Mode
            {
                float mScale;
                std::vector<std::int16_t> mOffsets; // x, y, z per vertex
            };

            std::uint32_t mNumVertices = 0;
            std::vector<Mode> mSymmetric;
            std::vector<Mode> mAsymmetric;
        };

        std::shared_ptr<const Egm> readEgm(std::istream& stream, std::string_view name)
        {
            std::array<char, 8> magic;
            stream.read(magic.data(), magic.size());
            if (!stream || std::memcmp(magic.data(), "FREGM002", magic.size()) != 0)
            {
                Log(Debug::Warning) << "Not a FaceGen EGM file: " << name;
                return nullptr;
            }
            std::uint32_t header[3];
            stream.read(reinterpret_cast<char*>(header), sizeof(header));
            stream.ignore(4 + 40); // geometry basis hash, reserved

            auto egm = std::make_shared<Egm>();
            egm->mNumVertices = header[0];
            auto readModes = [&](std::vector<Egm::Mode>& modes, std::uint32_t count) {
                modes.resize(count);
                for (Egm::Mode& mode : modes)
                {
                    stream.read(reinterpret_cast<char*>(&mode.mScale), sizeof(mode.mScale));
                    mode.mOffsets.resize(egm->mNumVertices * 3);
                    stream.read(reinterpret_cast<char*>(mode.mOffsets.data()), mode.mOffsets.size() * sizeof(std::int16_t));
                }
            };
            readModes(egm->mSymmetric, header[1]);
            readModes(egm->mAsymmetric, header[2]);
            if (!stream)
            {
                Log(Debug::Warning) << "Truncated FaceGen EGM file: " << name;
                return nullptr;
            }
            return egm;
        }

        std::shared_ptr<const Egm> getEgm(const VFS::Path::Normalized& path, const VFS::Manager& vfs)
        {
            static std::mutex mutex;
            static std::map<std::string, std::shared_ptr<const Egm>, std::less<>> cache;
            std::lock_guard lock(mutex);
            auto it = cache.find(path.value());
            if (it != cache.end())
                return it->second;
            std::shared_ptr<const Egm> egm;
            if (vfs.exists(path))
                egm = readEgm(*vfs.get(path), path.value());
            cache.emplace(std::string(path.value()), egm);
            return egm;
        }

        class CollectDrawablesVisitor : public osg::NodeVisitor
        {
        public:
            CollectDrawablesVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void apply(osg::Drawable& drawable) override
            {
                const osg::NodePath& path = getNodePath();
                osg::Group* parent = path.size() >= 2 ? path[path.size() - 2]->asGroup() : nullptr;
                mDrawables.emplace_back(&drawable, parent);
            }

            std::vector<std::pair<osg::Drawable*, osg::Group*>> mDrawables;
        };

        // Returns a copy of the geometry's vertices with the offsets added; the original arrays stay untouched since
        // they belong to the cached mesh shared by every NPC.
        osg::ref_ptr<osg::Geometry> morphedCopy(const osg::Geometry& geometry, const std::vector<osg::Vec3f>& offsets)
        {
            const osg::Vec3Array* vertices = dynamic_cast<const osg::Vec3Array*>(geometry.getVertexArray());
            if (vertices == nullptr)
                return nullptr;
            osg::ref_ptr<osg::Geometry> copy = new osg::Geometry(geometry, osg::CopyOp::SHALLOW_COPY);
            osg::ref_ptr<osg::Vec3Array> morphed = new osg::Vec3Array(*vertices);
            morphed->setVertexBufferObject(new osg::VertexBufferObject);
            const size_t count = std::min(morphed->size(), offsets.size());
            for (size_t i = 0; i < count; ++i)
                (*morphed)[i] += offsets[i];
            copy->setVertexArray(morphed);
            copy->dirtyBound();
            return copy;
        }
    }

    void applyFaceGenShape(osg::Node& part, std::string_view model, const std::vector<float>& symmetric,
        const std::vector<float>& asymmetric, const VFS::Manager& vfs)
    {
        if (symmetric.empty() && asymmetric.empty())
            return;
        std::string path = Misc::ResourceHelpers::correctMeshPath(VFS::Path::toNormalized(model)).value();
        const size_t dot = path.find_last_of('.');
        if (dot == std::string::npos)
            return;
        path.replace(dot, std::string::npos, ".egm");
        std::shared_ptr<const Egm> egm = getEgm(VFS::Path::Normalized(path), vfs);
        if (egm == nullptr)
            return;

        // Each mode moves the vertices by coefficient * scale * offset, symmetric and asymmetric modes alike.
        std::vector<osg::Vec3f> offsets(egm->mNumVertices);
        auto accumulate = [&](const std::vector<Egm::Mode>& modes, const std::vector<float>& coefficients) {
            for (size_t m = 0; m < modes.size() && m < coefficients.size(); ++m)
            {
                const float weight = coefficients[m] * modes[m].mScale;
                if (weight == 0.f)
                    continue;
                const std::vector<std::int16_t>& d = modes[m].mOffsets;
                for (size_t v = 0; v < offsets.size(); ++v)
                    offsets[v] += osg::Vec3f(d[v * 3], d[v * 3 + 1], d[v * 3 + 2]) * weight;
            }
        };
        accumulate(egm->mSymmetric, symmetric);
        accumulate(egm->mAsymmetric, asymmetric);

        CollectDrawablesVisitor collect;
        part.accept(collect);
        for (auto [drawable, parent] : collect.mDrawables)
        {
            if (auto* rig = dynamic_cast<SceneUtil::RigGeometry*>(drawable))
            {
                // Rigs are copied per instance, so only their source geometry has to be replaced.
                if (osg::ref_ptr<osg::Geometry> morphed = morphedCopy(*rig->getSourceGeometry(), offsets))
                    rig->setSourceGeometry(morphed);
            }
            else if (auto* geometry = dynamic_cast<osg::Geometry*>(drawable); geometry && parent)
            {
                if (osg::ref_ptr<osg::Geometry> morphed = morphedCopy(*geometry, offsets))
                    parent->replaceChild(geometry, morphed);
            }
        }
    }
}
