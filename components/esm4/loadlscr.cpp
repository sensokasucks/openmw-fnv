#include "loadlscr.hpp"

#include "reader.hpp"

void ESM4::LoadScreen::load(ESM4::Reader& reader)
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
            case ESM::fourCC("ICON"):
                reader.getZString(mIcon);
                break;
            case ESM::fourCC("DESC"):
                reader.getLocalizedString(mText);
                break;
            case ESM::fourCC("LNAM"):
                if (subHdr.dataSize == 12)
                {
                    reader.getFormId(mLocation);
                    reader.getFormId(mLocationWorld);
                    reader.get(mGridY);
                    reader.get(mGridX);
                }
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("WMI1"):
                if (subHdr.dataSize == 4)
                    reader.getFormId(mType);
                else
                    reader.skipSubRecordData();
                break;
            default: // MICO, CTDA (TES4/5 conditions), NNAM (TES5 model) and others not used here
                reader.skipSubRecordData();
                break;
        }
    }
}
