#ifndef ESM4_PERK_H
#define ESM4_PERK_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

#include "loadinfo.hpp"

namespace ESM4
{
    class Reader;

    // FO3/FONV perk or trait.
    struct Perk
    {
        enum EntryType : std::uint8_t
        {
            Entry_Quest = 0, // sets a quest stage
            Entry_Ability = 1, // adds a SPEL ability
            Entry_EntryPoint = 2, // modifies a value at one of the engine's perk entry points
        };

        // One PRKE ... PRKF block.
        struct Entry
        {
            std::uint8_t mType = Entry_Quest;
            std::uint8_t mRank = 0; // perk rank (0-based) the entry applies from
            std::uint8_t mPriority = 0;
            ESM::FormId mQuest; // Entry_Quest
            std::uint8_t mStage = 0;
            ESM::FormId mSpell; // Entry_Ability
            std::uint8_t mEntryPoint = 0; // Entry_EntryPoint
            std::uint8_t mFunction = 0; // 1 set value, 2 add value, 3 multiply value, ...
            std::uint8_t mFunctionDataType = 0; // EPFT: 1 one value, 2 two values, 3 leveled list, 4 activate choice
            float mValues[2] = { 0, 0 }; // EPFD for function data types 1 and 2
            ESM::FormId mForm; // EPFD for function data type 3 (leveled list)
            std::string mButtonLabel; // EPF2
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::string mDesc;
        std::string mIcon;

        // DATA
        bool mIsTrait = false;
        std::uint8_t mMinLevel = 0;
        std::uint8_t mRanks = 1;
        bool mPlayable = false;
        bool mHidden = false;

        std::vector<DialogCondition> mConditions; // requirements to take the perk (CTDA before the entries)
        std::vector<Entry> mEntries;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::REC_PERK4;
    };
}

#endif // ESM4_PERK_H
