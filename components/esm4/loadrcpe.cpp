#include "loadrcpe.hpp"

#include <components/debug/debuglog.hpp>

#include "reader.hpp"

void ESM4::Recipe::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    // RCQY follows the RCIL or RCOD it counts
    std::vector<Component>* last = nullptr;

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
                if (subHdr.dataSize == 16)
                {
                    reader.get(mSkill);
                    reader.get(mSkillLevel);
                    reader.getFormId(mCategory);
                    reader.getFormId(mSubCategory);
                }
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("CTDA"):
                if (subHdr.dataSize == 28)
                {
                    TargetCondition cond;
                    reader.get(cond);
                    if (cond.reference)
                        reader.adjustFormId(cond.reference);
                    addDialogCondition(reader, mConditions, cond, true);
                }
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("RCIL"):
                last = &mInputs;
                reader.getFormId(mInputs.emplace_back().mItem);
                break;
            case ESM::fourCC("RCOD"):
                last = &mOutputs;
                reader.getFormId(mOutputs.emplace_back().mItem);
                break;
            case ESM::fourCC("RCQY"):
                if (last != nullptr && !last->empty())
                    reader.get(last->back().mCount);
                else
                    reader.skipSubRecordData();
                break;
            default:
                Log(Debug::Warning) << "ESM4::RCPE::load - skipping unknown subrecord "
                                    << ESM::printName(subHdr.typeId) << " in " << mEditorId;
                reader.skipSubRecordData();
                break;
        }
    }
}
