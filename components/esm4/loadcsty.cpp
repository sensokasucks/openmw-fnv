#include "loadcsty.hpp"

#include <cstring>
#include <vector>

#include "reader.hpp"

void ESM4::CombatStyle::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    while (reader.getSubRecordHeader())
    {
        const ESM4::SubRecordHeader& subHdr = reader.subRecordHeader();
        switch (subHdr.typeId)
        {
            case ESM::fourCC("EDID"):
                reader.getZString(mEditorId);
                break;
            case ESM::fourCC("CSTD"):
            {
                // FNV CSTD (92 bytes): Dodge % (u8 0), Left/Right % (1), timers, Block % (36), Attack % (37),
                // ..., flags (u16 80), checked against FalloutNV.esm (ghidra-findings-9)
                std::vector<std::uint8_t> raw(subHdr.dataSize);
                reader.get(raw.data(), raw.size());
                if (raw.size() >= 2)
                {
                    mDodgeChance = raw[0];
                    mLeftRightChance = raw[1];
                }
                if (raw.size() >= 38)
                {
                    mBlockChance = raw[36];
                    mAttackChance = raw[37];
                }
                if (raw.size() >= 82)
                {
                    std::uint16_t flags = 0;
                    std::memcpy(&flags, raw.data() + 80, 2);
                    mStyleFlags = flags;
                }
                mHasStandardData = true;
                break;
            }
            case ESM::fourCC("CSSD"):
            {
                // Cover Search Radius, Take Cover Chance, Wait Timer min/max, Wait To Fire Timer min/max, Fire Timer
                // min/max (floats, in this order: FalloutNV.exe reads them at these offsets)
                std::vector<std::uint8_t> raw(subHdr.dataSize);
                reader.get(raw.data(), raw.size());
                // then (FNV, 64 bytes): Ranged Weapon Range Mult min, unused, Weapon Restrictions (u32), Ranged
                // Weapon Range Mult max, Max Targeting FOV, Combat Radius, Semi-Auto Firing Delay Mult min/max
                float values[16] = {};
                for (int i = 0; i < 16 && static_cast<std::size_t>(i * 4 + 4) <= raw.size(); ++i)
                    std::memcpy(&values[i], raw.data() + i * 4, 4);
                if (raw.size() >= 64)
                {
                    mRangeMultMin = values[8];
                    std::memcpy(&mWeaponRestrictions, raw.data() + 40, 4);
                    mRangeMultMax = values[11];
                    mMaxTargetingFov = values[12];
                    mCombatRadius = values[13];
                    mSemiAutoDelayMultMin = values[14];
                    mSemiAutoDelayMultMax = values[15];
                }
                mCoverSearchRadius = values[0];
                mTakeCoverChance = values[1];
                mWaitTimerMin = values[2];
                mWaitTimerMax = values[3];
                mWaitToFireTimerMin = values[4];
                mWaitToFireTimerMax = values[5];
                mFireTimerMin = values[6];
                mFireTimerMax = values[7];
                mHasSimpleData = raw.size() >= 32;
                break;
            }
            default:
                reader.skipSubRecordData();
                break;
        }
    }
}
