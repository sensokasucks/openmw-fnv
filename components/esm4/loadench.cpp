#include "loadench.hpp"

#include "reader.hpp"

void ESM4::Enchantment::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    std::uint32_t pendingEffect = 0;
    while (reader.getSubRecordHeader())
    {
        const ESM4::SubRecordHeader& subHdr = reader.subRecordHeader();
        if (readEffectSubRecord(reader, mEffects, pendingEffect))
            continue;
        switch (subHdr.typeId)
        {
            case ESM::fourCC("EDID"):
                reader.getZString(mEditorId);
                break;
            case ESM::fourCC("FULL"):
                reader.getLocalizedString(mFullName);
                break;
            case ESM::fourCC("ENIT"):
                if (subHdr.dataSize == sizeof(Data))
                    reader.get(mData);
                else
                    reader.skipSubRecordData();
                break;
            default:
                reader.skipSubRecordData();
                break;
        }
    }
}
