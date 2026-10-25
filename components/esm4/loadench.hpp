#ifndef ESM4_ENCH_H
#define ESM4_ENCH_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

#include "effect.hpp"

namespace ESM4
{
    class Reader;

    // Object effect (ENCH) of weapons and apparel; FO3/FONV layout. Other
    // games' records load their names only.
    struct Enchantment
    {
        enum Type : std::uint32_t
        {
            Type_Weapon = 2,
            Type_Apparel = 3,
        };

#pragma pack(push, 1)
        struct Data // ENIT, 16 bytes in FO3/FONV
        {
            std::uint32_t type;
            std::uint32_t chargeAmount; // unused
            std::uint32_t enchantCost; // unused
            std::uint8_t flags; // 0x01 no auto-calc, 0x04 hide effect
            std::uint8_t unused[3];
        };
#pragma pack(pop)

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;

        Data mData{};
        std::vector<EffectItem> mEffects;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_ENCH4;
    };
}

#endif // ESM4_ENCH_H
