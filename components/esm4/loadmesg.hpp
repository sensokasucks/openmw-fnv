#ifndef ESM4_MESG_H
#define ESM4_MESG_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;
    class Writer;

    // FO3/FNV message box (MESG). Shown by the ObScript ShowMessage command.
    struct Message
    {
        enum Flags : std::uint32_t
        {
            Flag_MessageBox = 0x01, // otherwise an auto-display (corner) notification
            Flag_AutoDisplay = 0x02,
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName; // title
        std::string mText; // DESC
        std::string mIcon;
        ESM::FormId mQuest;
        std::uint32_t mMessageFlags = 0; // DNAM
        std::uint32_t mDisplayTime = 0; // TNAM, seconds
        std::vector<std::string> mButtons; // ITXT, in order

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_MESG4;
    };
}

#endif // ESM4_MESG_H
