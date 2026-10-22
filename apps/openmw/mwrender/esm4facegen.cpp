#include "esm4facegen.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>

#include <osg/Geometry>
#include <osg/Image>
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

        // FaceGen "FREGT003": per mode a scale and one int8 plane per colour channel. Rows are stored bottom up.
        struct Egt
        {
            struct Mode
            {
                float mScale;
                std::vector<std::int8_t> mPlanes; // r, g, b planes of width * height, top row first
            };

            std::uint32_t mWidth = 0;
            std::uint32_t mHeight = 0;
            std::vector<Mode> mModes;
        };

        std::shared_ptr<const Egt> readEgt(std::istream& stream, std::string_view name)
        {
            std::array<char, 8> magic;
            stream.read(magic.data(), magic.size());
            if (!stream || std::memcmp(magic.data(), "FREGT003", magic.size()) != 0)
            {
                Log(Debug::Warning) << "Not a FaceGen EGT file: " << name;
                return nullptr;
            }
            std::uint32_t header[4]; // rows, columns, symmetric modes, asymmetric modes
            stream.read(reinterpret_cast<char*>(header), sizeof(header));
            stream.ignore(4 + 36); // geometry basis hash, reserved

            auto egt = std::make_shared<Egt>();
            egt->mHeight = header[0];
            egt->mWidth = header[1];
            // Rows are padded to a multiple of 8 bytes in the file.
            const std::uint32_t stride = (egt->mWidth + 7) & ~7u;
            std::vector<std::int8_t> row(stride);
            egt->mModes.resize(header[2]);
            for (Egt::Mode& mode : egt->mModes)
            {
                stream.read(reinterpret_cast<char*>(&mode.mScale), sizeof(mode.mScale));
                mode.mPlanes.resize(3 * egt->mWidth * egt->mHeight);
                for (std::uint32_t channel = 0; channel < 3; ++channel)
                {
                    for (std::uint32_t r = 0; r < egt->mHeight; ++r)
                    {
                        stream.read(reinterpret_cast<char*>(row.data()), stride);
                        const std::uint32_t y = egt->mHeight - 1 - r;
                        std::copy_n(row.begin(), egt->mWidth,
                            mode.mPlanes.begin() + (channel * egt->mHeight + y) * egt->mWidth);
                    }
                }
            }
            if (!stream)
            {
                Log(Debug::Warning) << "Truncated FaceGen EGT file: " << name;
                return nullptr;
            }
            return egt;
        }

        template <class T, class Read>
        std::shared_ptr<const T> getCached(const VFS::Path::Normalized& path, const VFS::Manager& vfs, Read read)
        {
            static std::mutex mutex;
            static std::map<std::string, std::shared_ptr<const T>, std::less<>> cache;
            std::lock_guard lock(mutex);
            auto it = cache.find(path.value());
            if (it != cache.end())
                return it->second;
            std::shared_ptr<const T> result;
            if (vfs.exists(path))
                result = read(*vfs.get(path), path.value());
            cache.emplace(std::string(path.value()), result);
            return result;
        }

        VFS::Path::Normalized withExtension(std::string_view model, std::string_view extension)
        {
            std::string path = Misc::ResourceHelpers::correctMeshPath(VFS::Path::toNormalized(model)).value();
            const size_t dot = path.find_last_of('.');
            if (dot != std::string::npos)
                path.replace(dot, std::string::npos, extension);
            return VFS::Path::Normalized(path);
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
        std::shared_ptr<const Egm> egm = getCached<Egm>(withExtension(model, ".egm"), vfs, readEgm);
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

    osg::ref_ptr<osg::Image> makeFaceGenTexture(const osg::Image& base, std::string_view model,
        const std::vector<float>& textureModes, const VFS::Manager& vfs)
    {
        if (textureModes.empty())
            return nullptr;
        std::shared_ptr<const Egt> egt = getCached<Egt>(withExtension(model, ".egt"), vfs, readEgt);
        if (egt == nullptr || egt->mWidth == 0 || egt->mHeight == 0)
            return nullptr;

        // Sum the modes at the morph resolution, in colour units of 0..255.
        const size_t planeSize = egt->mWidth * egt->mHeight;
        std::vector<float> offsets(3 * planeSize);
        for (size_t m = 0; m < egt->mModes.size() && m < textureModes.size(); ++m)
        {
            const float weight = textureModes[m] * egt->mModes[m].mScale;
            if (weight == 0.f)
                continue;
            const std::vector<std::int8_t>& planes = egt->mModes[m].mPlanes;
            for (size_t i = 0; i < offsets.size(); ++i)
                offsets[i] += planes[i] * weight;
        }

        // Add them onto the face texture. Decoding the compressed source is slow, so cap the result at 512 pixels;
        // the morphs themselves are 256 wide.
        const int width = std::min(base.s(), 512);
        const int height = std::min(base.t(), 512);
        osg::ref_ptr<osg::Image> result = new osg::Image;
        result->setFileName(base.getFileName());
        result->setOrigin(base.getOrigin());
        result->allocateImage(width, height, 1, GL_RGB, GL_UNSIGNED_BYTE);
        const bool flip = base.getOrigin() == osg::Image::BOTTOM_LEFT;
        for (int t = 0; t < height; ++t)
        {
            const int top = flip ? height - 1 - t : t;
            const float y = std::clamp((top + 0.5f) * egt->mHeight / height - 0.5f, 0.f, egt->mHeight - 1.f);
            const size_t y0 = static_cast<size_t>(y);
            const size_t y1 = std::min<size_t>(y0 + 1, egt->mHeight - 1);
            const float fy = y - y0;
            for (int s = 0; s < width; ++s)
            {
                const float x = std::clamp((s + 0.5f) * egt->mWidth / width - 0.5f, 0.f, egt->mWidth - 1.f);
                const size_t x0 = static_cast<size_t>(x);
                const size_t x1 = std::min<size_t>(x0 + 1, egt->mWidth - 1);
                const float fx = x - x0;
                osg::Vec4f colour = base.getColor(s * base.s() / width, t * base.t() / height);
                for (size_t c = 0; c < 3; ++c)
                {
                    const float* plane = offsets.data() + c * planeSize;
                    const float top0 = plane[y0 * egt->mWidth + x0] * (1 - fx) + plane[y0 * egt->mWidth + x1] * fx;
                    const float bottom = plane[y1 * egt->mWidth + x0] * (1 - fx) + plane[y1 * egt->mWidth + x1] * fx;
                    colour[c] = std::clamp(colour[c] + (top0 * (1 - fy) + bottom * fy) / 255.f, 0.f, 1.f);
                }
                result->setColor(colour, s, t);
            }
        }
        return result;
    }
}
