#include "loadrepu.hpp"

#include "reader.hpp"

void ESM4::Reputation::load(ESM4::Reader& reader)
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
            case ESM::fourCC("ICON"):
                reader.getZString(mIcon);
                break;
            case ESM::fourCC("MICO"):
                reader.getZString(mMiniIcon);
                break;
            case ESM::fourCC("DATA"):
                if (subHdr.dataSize == 4)
                    reader.get(mValue);
                else
                    reader.skipSubRecordData();
                break;
            default:
                reader.skipSubRecordData();
                break;
        }
    }
}
