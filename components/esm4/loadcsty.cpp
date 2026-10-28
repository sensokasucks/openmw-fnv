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
                // Dodge % (u8), Left/Right % (u8), ... The flags' place in FNV's CSTD is not known yet, so
                // mStyleFlags stays 0 (nothing ignored).
                std::vector<std::uint8_t> raw(subHdr.dataSize);
                reader.get(raw.data(), raw.size());
                if (raw.size() >= 2)
                {
                    mDodgeChance = raw[0];
                    mLeftRightChance = raw[1];
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
                float values[8] = {};
                for (int i = 0; i < 8 && static_cast<std::size_t>(i * 4 + 4) <= raw.size(); ++i)
                    std::memcpy(&values[i], raw.data() + i * 4, 4);
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
