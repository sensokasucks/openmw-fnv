#include "loadmgef.hpp"

#include "reader.hpp"

void ESM4::MagicEffect::load(ESM4::Reader& reader)
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
            case ESM::fourCC("DESC"):
                reader.getLocalizedString(mDescription);
                break;
            case ESM::fourCC("ICON"):
                reader.getZString(mIcon);
                break;
            case ESM::fourCC("MICO"):
                reader.getZString(mMiniIcon);
                break;
            case ESM::fourCC("MODL"):
                reader.getZString(mModel);
                break;
            case ESM::fourCC("DATA"):
                if (subHdr.dataSize != sizeof(Data))
                {
                    reader.skipSubRecordData();
                    break;
                }
                reader.get(mData);
                mHasData = true;
                for (ESM::FormId32* id : { &mData.associatedItem, &mData.light, &mData.effectShader,
                         &mData.objectDisplayShader, &mData.effectSound, &mData.boltSound, &mData.hitSound,
                         &mData.areaSound })
                    reader.adjustFormId(*id);
                mAssociatedItem = ESM::FormId::fromUint32(mData.associatedItem);
                break;
            case ESM::fourCC("ESCE"): // counter effects
            {
                if (!mHasData || subHdr.dataSize % 4 != 0) // TES4 lists effect codes
                {
                    reader.skipSubRecordData();
                    break;
                }
                for (std::uint32_t i = 0; i < subHdr.dataSize / 4; ++i)
                {
                    ESM::FormId id;
                    reader.getFormId(id);
                    mCounterEffects.push_back(id);
                }
                break;
            }
            default:
                // other games' sub-records (and FO3/FONV model data) are not used
                reader.skipSubRecordData();
                break;
        }
    }
}
