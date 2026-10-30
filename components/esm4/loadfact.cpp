#include "loadfact.hpp"

#include <algorithm>
#include <cstring>

#include "reader.hpp"

void ESM4::Faction::load(ESM4::Reader& reader)
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
            case ESM::fourCC("FULL"):
                reader.getLocalizedString(mFullName);
                break;
            case ESM::fourCC("XNAM"):
            {
                Relation relation;
                reader.getFormId(relation.mFaction);
                reader.get(relation.mModifier);
                if (subHdr.dataSize >= 12)
                    reader.get(relation.mReaction);
                if (subHdr.dataSize > 12)
                    reader.skipSubRecordData(subHdr.dataSize - 12);
                mRelations.push_back(relation);
                break;
            }
            case ESM::fourCC("DATA"):
            {
                std::uint8_t data[4] = {};
                const std::size_t size = std::min<std::size_t>(subHdr.dataSize, sizeof(data));
                reader.get(data, size);
                if (subHdr.dataSize > size)
                    reader.skipSubRecordData(subHdr.dataSize - static_cast<std::uint32_t>(size));
                std::memcpy(&mFactionFlags, data, sizeof(mFactionFlags));
                break;
            }
            case ESM::fourCC("WMI1"):
                reader.getFormId(mReputation);
                break;
            default:
                // Ranks and crime data
                reader.skipSubRecordData();
                break;
        }
    }
}
