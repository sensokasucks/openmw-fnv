#ifndef ESM4_CSTY_H
#define ESM4_CSTY_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FONV combat style: the parts the combat AI reads (CSTD flags and dodge chance, CSSD cover timers)
    struct CombatStyle
    {
        enum Flags : std::uint32_t
        {
            Flag_ChooseAttackUsingPercentChance = 0x01,
            Flag_MeleeAlertOk = 0x02,
            Flag_FleeBasedOnPersonalSurvival = 0x04,
            Flag_IgnoreThreats = 0x10,
            Flag_IgnoreDamagingSelf = 0x20,
            Flag_IgnoreDamagingGroup = 0x40,
            Flag_IgnoreDamagingSpectators = 0x80,
            Flag_CannotUseStealthboy = 0x100,
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details
        std::string mEditorId;

        // CSTD
        std::uint8_t mDodgeChance = 0;
        std::uint8_t mLeftRightChance = 0;
        std::uint32_t mStyleFlags = 0;
        std::uint8_t mBlockChance = 0; // CSTD 36
        std::uint8_t mAttackChance = 0; // CSTD 37
        bool mHasStandardData = false;

        // CSSD (simple data)
        float mCoverSearchRadius = 2048.f;
        float mTakeCoverChance = 0.f;
        float mWaitTimerMin = 0.f, mWaitTimerMax = 0.f;
        float mWaitToFireTimerMin = 0.f, mWaitToFireTimerMax = 0.f;
        float mFireTimerMin = 0.f, mFireTimerMax = 0.f;
        float mRangeMultMin = 1.f, mRangeMultMax = 1.f; // Ranged Weapon Range Mult
        std::uint32_t mWeaponRestrictions = 0; // 0 none, 1 melee only, 2 ranged only
        float mMaxTargetingFov = 0.f; // 0: no check
        float mCombatRadius = 0.f;
        float mSemiAutoDelayMultMin = 1.f, mSemiAutoDelayMultMax = 1.f;
        bool mHasSimpleData = false;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_CSTY4;
    };
}

#endif // ESM4_CSTY_H
