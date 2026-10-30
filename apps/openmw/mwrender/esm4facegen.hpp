#ifndef GAME_RENDER_ESM4FACEGEN_H
#define GAME_RENDER_ESM4FACEGEN_H

#include <array>
#include <memory>
#include <string>
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

    // FO3/FONV lip sync (the .lip next to a voice file): 30 frames a second, each with the weights of the 16 speech
    // morphs (sLipSyncPhonemes) and 17 modifiers (blinks, brows, eye looks, squints, then head pitch, roll and yaw
    // in radians).
    struct LipSync
    {
        using Frame = std::array<float, 33>;
        static constexpr float sFrameRate = 30.f;
        // Seconds the face moves ahead of the voice
        float mLeadIn = 0.f;
        std::vector<Frame> mFrames;

        float getDuration() const { return mFrames.size() / sFrameRate; }
    };

    // Speech morphs in .lip order, and the modifiers that are morphs (the last three turn the head)
    extern const std::array<std::string_view, 16> sLipSyncPhonemes;
    extern const std::array<std::string_view, 14> sLipSyncModifiers;

    // The lip sync of a voice file (e.g. sound/voice/falloutnv.esm/maleuniquedocmitchell/x.ogg), or null if it
    // has none.
    std::shared_ptr<const LipSync> getLipSync(std::string_view voiceFile, const VFS::Manager& vfs);

    // The expression, mouth and blink morphs of an FO3/FONV head (FaceGen .tri files next to the head part meshes:
    // "Aah", "BigAah", "BMP" ... for speech, "Anger", "Happy" ... for moods, "BlinkLeft", "BlinkRight", ...).
    class FaceMorphs
    {
    public:
        FaceMorphs();
        ~FaceMorphs();

        // Lets the morphs of the part's .tri move the part, on top of its FaceGen shape (so call it after
        // applyFaceGenShape). False if the part has no morphs.
        bool add(osg::Node& part, std::string_view model, const VFS::Manager& vfs);

        bool empty() const { return mTargets.empty(); }

        // Weight of a morph by name (0 rests, 1 is the full expression); names a part lacks are ignored.
        void setWeight(std::string_view name, float weight);

        // Moves the vertices for the weights set since the last call.
        void apply();

    private:
        struct Target;
        std::vector<std::unique_ptr<Target>> mTargets;
        std::vector<std::pair<std::string, float>> mWeights;
        bool mDirty = false;
    };
}

#endif
