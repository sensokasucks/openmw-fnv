#include "loadmesg.hpp"

#include <stdexcept>

#include <components/debug/debuglog.hpp>

#include "reader.hpp"

void ESM4::Message::load(ESM4::Reader& reader)
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
                reader.getLocalizedString(mText);
                break;
            case ESM::fourCC("INAM"):
                reader.getZString(mIcon);
                break;
            case ESM::fourCC("QNAM"):
                reader.getFormId(mQuest);
                break;
            case ESM::fourCC("DNAM"):
                reader.get(mMessageFlags);
                break;
            case ESM::fourCC("TNAM"):
                reader.get(mDisplayTime);
                break;
            case ESM::fourCC("ITXT"):
            {
                std::string button;
                reader.getLocalizedString(button);
                mButtons.push_back(std::move(button));
                break;
            }
            case ESM::fourCC("CTDA"): // button conditions
            case ESM::fourCC("NAM0"):
            case ESM::fourCC("NAM1"):
            case ESM::fourCC("NAM2"):
            case ESM::fourCC("NAM3"):
            case ESM::fourCC("NAM4"):
            case ESM::fourCC("NAM5"):
            case ESM::fourCC("NAM6"):
            case ESM::fourCC("NAM7"):
            case ESM::fourCC("NAM8"):
            case ESM::fourCC("NAM9"):
                reader.skipSubRecordData();
                break;
            default:
                // Our fork: tolerate unknown subrecords instead of aborting the whole load.
                Log(Debug::Warning) << "ESM4::MESG::load - skipping unknown subrecord "
                                    << ESM::printName(subHdr.typeId) << " in " << mEditorId;
                reader.skipSubRecordData();
                break;
        }
    }
}
