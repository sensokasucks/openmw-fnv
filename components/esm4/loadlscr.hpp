#ifndef ESM4_LSCR_H
#define ESM4_LSCR_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FNV loading screen: the tip shown while loading, where (LNAM), and the 3D scene type (WMI1, LSCT)
    struct LoadScreen
    {
        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mIcon; // FO3: the picture
        std::string mText; // DESC: the tip

        // LNAM: shown in this cell or worldspace (mLocation), or this worldspace's grid square; all zero for anywhere
        ESM::FormId mLocation;
        ESM::FormId mLocationWorld;
        std::int16_t mGridY = 0;
        std::int16_t mGridX = 0;

        ESM::FormId mType; // WMI1: LSCT

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_LSCR4;
    };
}

#endif // ESM4_LSCR_H
