#include "effect.hpp"

#include "reader.hpp"

namespace ESM4
{
    bool readEffectSubRecord(Reader& reader, std::vector<EffectItem>& effects, std::uint32_t& pendingEffect)
    {
        const SubRecordHeader& subHdr = reader.subRecordHeader();
        switch (subHdr.typeId)
        {
            case ESM::fourCC("EFID"):
                if (subHdr.dataSize == 4)
                    reader.get(pendingEffect);
                else
                    reader.skipSubRecordData();
                return true;
            case ESM::fourCC("EFIT"):
            {
                if (subHdr.dataSize != 20)
                {
                    reader.skipSubRecordData();
                    pendingEffect = 0;
                    return true;
                }
                EffectItem& item = effects.emplace_back();
                item.mEffect = ESM::FormId::fromUint32(pendingEffect);
                reader.adjustFormId(item.mEffect);
                reader.get(item.mMagnitude);
                reader.get(item.mArea);
                reader.get(item.mDuration);
                reader.get(item.mRange);
                reader.get(item.mActorValue);
                pendingEffect = 0;
                return true;
            }
            case ESM::fourCC("CTDA"):
            {
                if (effects.empty() || subHdr.dataSize != 28)
                {
                    reader.skipSubRecordData();
                    return true;
                }
                TargetCondition cond;
                reader.get(cond);
                if (cond.reference)
                    reader.adjustFormId(cond.reference);
                addDialogCondition(reader, effects.back().mConditions, cond, true);
                return true;
            }
            default:
                return false;
        }
    }
}
