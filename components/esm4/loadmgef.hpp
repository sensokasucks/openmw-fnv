#ifndef ESM4_MGEF_H
#define ESM4_MGEF_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;

    // Magic effect (MGEF), FO3/FONV layout. Other games' records load their
    // names only.
    struct MagicEffect
    {
        enum Flags : std::uint32_t
        {
            Flag_Hostile = 0x00000001,
            Flag_Recover = 0x00000002, // the change is undone when the effect ends
            Flag_Detrimental = 0x00000004, // the magnitude is subtracted
            Flag_Self = 0x00000010,
            Flag_Touch = 0x00000020,
            Flag_Target = 0x00000040,
            Flag_NoDuration = 0x00000080,
            Flag_NoMagnitude = 0x00000100,
            Flag_NoArea = 0x00000200,
            Flag_FXPersist = 0x00000400,
            Flag_GoryVisuals = 0x00001000,
            Flag_DisplayNameOnly = 0x00002000,
            Flag_UseSkill = 0x00080000,
            Flag_UseAttribute = 0x00100000,
            Flag_Painless = 0x01000000,
            Flag_NoHitEffect = 0x08000000,
            Flag_NoDeathDispel = 0x10000000,
        };

        enum Archetype : std::uint32_t
        {
            Archetype_ValueModifier = 0,
            Archetype_Script = 1,
            Archetype_Dispel = 2,
            Archetype_CureDisease = 3,
            Archetype_Invisibility = 11,
            Archetype_Chameleon = 12,
            Archetype_Light = 13,
            Archetype_Lock = 16,
            Archetype_Open = 17,
            Archetype_BoundItem = 18,
            Archetype_SummonCreature = 19,
            Archetype_Paralysis = 24,
            Archetype_CureParalysis = 30,
            Archetype_CureAddiction = 31,
            Archetype_CurePoison = 32,
            Archetype_Concussion = 33,
            Archetype_ValueAndParts = 34,
            Archetype_LimbCondition = 35,
            Archetype_Turbo = 36,
        };

#pragma pack(push, 1)
        struct Data // FO3/FONV DATA, 72 bytes
        {
            std::uint32_t flags;
            float baseCost;
            ESM::FormId32 associatedItem; // SCPT of a Script effect, CREA/WEAP of summons
            std::int32_t magicSchool;
            std::int32_t resistValue; // actor value
            std::uint16_t counterEffectCount;
            std::uint16_t unused;
            ESM::FormId32 light;
            float projectileSpeed;
            ESM::FormId32 effectShader;
            ESM::FormId32 objectDisplayShader;
            ESM::FormId32 effectSound;
            ESM::FormId32 boltSound;
            ESM::FormId32 hitSound;
            ESM::FormId32 areaSound;
            float constantEffectEnchantmentFactor;
            float constantEffectBarterFactor;
            std::uint32_t archetype;
            std::int32_t actorValue;
        };
#pragma pack(pop)

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::string mDescription;
        std::string mIcon;
        std::string mMiniIcon;
        ESM::Path mModel;

        bool mHasData = false;
        Data mData{};
        ESM::FormId mAssociatedItem;
        std::vector<ESM::FormId> mCounterEffects;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_MGEF4;
    };
}

#endif // ESM4_MGEF_H
