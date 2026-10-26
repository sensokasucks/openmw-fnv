#ifndef ESM4_DEBR_H
#define ESM4_DEBR_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FONV debris: the bits that fly when a limb explodes (BPTD) or something is destroyed.
    struct Debris
    {
        struct Model
        {
            std::uint8_t percentage = 0; // chance each piece uses this model
            ESM::Path model;
            std::uint8_t flags = 0; // 1: has collision data
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::vector<Model> mModels;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_DEBR4;
    };
}

#endif // ESM4_DEBR_H
