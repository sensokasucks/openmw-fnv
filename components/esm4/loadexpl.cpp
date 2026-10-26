#include "loadexpl.hpp"

#include "reader.hpp"

void ESM4::Explosion::load(ESM4::Reader& reader)
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
            case ESM::fourCC("MODL"):
                reader.getZString(mModel);
                break;
            case ESM::fourCC("EITM"):
                reader.getFormId(mEnchantment);
                break;
            case ESM::fourCC("MNAM"):
                reader.getFormId(mImageSpaceModifier);
                break;
            case ESM::fourCC("INAM"):
                reader.getFormId(mPlacedImpactObject);
                break;
            case ESM::fourCC("DATA"):
            {
                if (subHdr.dataSize < 36) // TES5 and later differ
                {
                    reader.skipSubRecordData();
                    break;
                }
                Data& d = mData;
                reader.get(d.force);
                reader.get(d.damage);
                reader.get(d.radius);
                reader.getFormId(d.light);
                reader.getFormId(d.sound1);
                reader.get(d.flags);
                reader.get(d.isRadius);
                reader.getFormId(d.impactDataSet);
                reader.getFormId(d.sound2);
                if (subHdr.dataSize > 36)
                    reader.skipSubRecordData(subHdr.dataSize - 36);
                break;
            }
            default: // OBND, MODT, MODS, radiation and the later games' fields
                reader.skipSubRecordData();
                break;
        }
    }
}
