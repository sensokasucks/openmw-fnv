#ifndef ESM4_REPU_H
#define ESM4_REPU_H

#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;

    // FONV reputation (a town or faction the player has fame and infamy with).
    struct Reputation
    {
        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::string mIcon;
        std::string mMiniIcon;
        // DATA: the fame/infamy points for full standing; the tiers are fractions of it
        // (fReputationThresholdOne/Two/Three).
        float mValue = 0;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::REC_REPU4;
    };
}

#endif // ESM4_REPU_H
