#include "loadperk.hpp"

#include "reader.hpp"

void ESM4::Perk::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    Entry* entry = nullptr; // inside PRKE ... PRKF
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
                reader.getLocalizedString(mDesc);
                break;
            case ESM::fourCC("ICON"):
                reader.getZString(mIcon);
                break;
            case ESM::fourCC("CTDA"):
            {
                if (entry != nullptr || subHdr.dataSize != 28) // entry conditions (PRKC tabs) aren't used yet
                {
                    reader.skipSubRecordData();
                    break;
                }
                TargetCondition data;
                reader.get(data);
                if (data.reference)
                    reader.adjustFormId(data.reference);
                addDialogCondition(reader, mConditions, data, true);
                break;
            }
            case ESM::fourCC("DATA"):
            {
                if (entry == nullptr)
                {
                    if (subHdr.dataSize < 4)
                    {
                        reader.skipSubRecordData();
                        break;
                    }
                    std::uint8_t trait, playable;
                    reader.get(trait);
                    reader.get(mMinLevel);
                    reader.get(mRanks);
                    reader.get(playable);
                    mIsTrait = trait != 0;
                    mPlayable = playable != 0;
                    if (subHdr.dataSize >= 5)
                    {
                        std::uint8_t hidden;
                        reader.get(hidden);
                        mHidden = hidden != 0;
                        reader.skipSubRecordData(subHdr.dataSize - 5);
                    }
                    break;
                }
                if (entry->mType == Entry_Quest && subHdr.dataSize >= 5)
                {
                    reader.getFormId(entry->mQuest);
                    reader.get(entry->mStage);
                    reader.skipSubRecordData(subHdr.dataSize - 5);
                }
                else if (entry->mType == Entry_Ability && subHdr.dataSize == 4)
                    reader.getFormId(entry->mSpell);
                else if (entry->mType == Entry_EntryPoint && subHdr.dataSize >= 2)
                {
                    reader.get(entry->mEntryPoint);
                    reader.get(entry->mFunction);
                    reader.skipSubRecordData(subHdr.dataSize - 2);
                }
                else
                    reader.skipSubRecordData();
                break;
            }
            case ESM::fourCC("PRKE"):
            {
                entry = &mEntries.emplace_back();
                if (subHdr.dataSize < 3)
                {
                    reader.skipSubRecordData();
                    break;
                }
                reader.get(entry->mType);
                reader.get(entry->mRank);
                reader.get(entry->mPriority);
                reader.skipSubRecordData(subHdr.dataSize - 3);
                break;
            }
            case ESM::fourCC("EPFT"):
                if (entry != nullptr && subHdr.dataSize == 1)
                    reader.get(entry->mFunctionDataType);
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("EPFD"):
                if (entry != nullptr && (entry->mFunctionDataType == 1 || entry->mFunctionDataType == 2)
                    && subHdr.dataSize >= 4)
                {
                    reader.get(entry->mValues[0]);
                    if (subHdr.dataSize >= 8)
                    {
                        reader.get(entry->mValues[1]);
                        reader.skipSubRecordData(subHdr.dataSize - 8);
                    }
                    else
                        reader.skipSubRecordData(subHdr.dataSize - 4);
                }
                else if (entry != nullptr && entry->mFunctionDataType == 3 && subHdr.dataSize == 4)
                    reader.getFormId(entry->mForm);
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("EPF2"):
                if (entry != nullptr)
                    reader.getZString(entry->mButtonLabel);
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("PRKF"):
                entry = nullptr;
                reader.skipSubRecordData();
                break;
            default: // MICO, PRKC, EPF3, embedded entry scripts (SCHR, SCDA, SCTX, SCRO, ...)
                reader.skipSubRecordData();
                break;
        }
    }
}
