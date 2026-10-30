#include "loadrcct.hpp"

#include <components/debug/debuglog.hpp>

#include "reader.hpp"

void ESM4::RecipeCategory::load(ESM4::Reader& reader)
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
            case ESM::fourCC("DATA"):
                reader.get(mCategoryFlags);
                break;
            default:
                Log(Debug::Warning) << "ESM4::RCCT::load - skipping unknown subrecord "
                                    << ESM::printName(subHdr.typeId) << " in " << mEditorId;
                reader.skipSubRecordData();
                break;
        }
    }
}
