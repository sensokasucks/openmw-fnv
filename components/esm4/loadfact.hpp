#ifndef ESM4_FACT_H
#define ESM4_FACT_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FONV faction: name, flags and how its members treat other factions.
    struct Faction
    {
        enum CombatReaction : std::uint32_t
        {
            Reaction_Neutral = 0,
            Reaction_Enemy = 1,
            Reaction_Ally = 2,
            Reaction_Friend = 3,
        };

        struct Relation
        {
            ESM::FormId mFaction;
            std::int32_t mModifier = 0;
            std::uint32_t mReaction = Reaction_Neutral; // FONV; FO3 has only the modifier
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::uint32_t mFactionFlags = 0; // DATA: 0x01 hidden from PC, 0x02 evil, 0x04 special combat, ...
        std::vector<Relation> mRelations;
        ESM::FormId mReputation; // WMI1 (FONV): the reputation crimes against the faction count against

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_FACT4;
    };
}

#endif // ESM4_FACT_H
