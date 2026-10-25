#ifndef ESM4_SPEL_H
#define ESM4_SPEL_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

#include "effect.hpp"

namespace ESM4
{
    class Reader;

    // Actor effect (SPEL): spells, abilities, diseases, addictions; FO3/FONV
    // layout. Other games' records load their names only.
    struct Spell
    {
        enum Type : std::uint32_t
        {
            Type_ActorEffect = 0,
            Type_Disease = 1,
            Type_Power = 2,
            Type_LesserPower = 3,
            Type_Ability = 4,
            Type_Poison = 5,
            Type_Addiction = 10,
        };

#pragma pack(push, 1)
        struct Data // SPIT, 16 bytes in FO3/FONV
        {
            std::uint32_t type;
            std::uint32_t cost;
            std::uint32_t level;
            std::uint8_t flags;
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

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_SPEL4;
    };
}

#endif // ESM4_SPEL_H
