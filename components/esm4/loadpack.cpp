/*
  Copyright (C) 2020-2021 cc9cii

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  cc9cii cc9c@iinet.net.au

  Much of the information on the data structures are based on the information
  from Tes4Mod:Mod_File_Format and Tes5Mod:File_Formats but also refined by
  trial & error.  See http://en.uesp.net/wiki for details.

*/
#include "loadpack.hpp"

#include <cstring>
#include <stdexcept>

#include "reader.hpp"
//#include "writer.hpp"

void ESM4::AIPackage::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    Event* event = nullptr; // the POBA/POEA/POCA block being read

    while (reader.getSubRecordHeader())
    {
        const ESM4::SubRecordHeader& subHdr = reader.subRecordHeader();
        switch (subHdr.typeId)
        {
            case ESM::fourCC("EDID"):
                reader.getZString(mEditorId);
                break;
            case ESM::fourCC("PKDT"):
            {
                if (subHdr.dataSize == 12) // FO3/FONV
                {
                    std::uint8_t type = 0;
                    std::uint8_t unused = 0;
                    std::uint16_t padding = 0;
                    reader.get(mData.flags);
                    reader.get(type);
                    reader.get(unused);
                    reader.get(mBehaviourFlags);
                    reader.get(mSpecificFlags);
                    reader.get(padding);
                    mData.type = type;
                }
                else if (subHdr.dataSize == sizeof(mData))
                    reader.get(mData);
                else if (subHdr.dataSize == 4)
                {
                    reader.get(mData.flags);
                    mData.type = 0; // FIXME
                }
                else
                    reader.skipSubRecordData();

                break;
            }
            case ESM::fourCC("PSDT"):
            {
                if (subHdr.dataSize != sizeof(mSchedule))
                    reader.skipSubRecordData(); // FIXME: TES5
                else
                    reader.get(mSchedule);

                break;
            }
            case ESM::fourCC("PLDT"):
            case ESM::fourCC("PLD2"):
            {
                if (subHdr.dataSize != sizeof(PLDT))
                {
                    reader.skipSubRecordData(); // FIXME:
                    break;
                }
                PLDT data;
                reader.get(data);
                // Location types 4 (object id) and 5 (object type) mean the same in TES4 and FO3/FONV.
                Location& location = mLocations[subHdr.typeId == ESM::fourCC("PLD2") ? 1 : 0];
                location.type = data.type;
                location.radius = data.radius;
                if (data.type == Location_ObjectType)
                    location.objectType = data.location;
                else
                {
                    location.location = ESM::FormId::fromUint32(data.location);
                    reader.adjustFormId(location.location);
                    data.location = location.location.toUint32();
                }
                if (subHdr.typeId == ESM::fourCC("PLDT"))
                    mLocation = data;

                break;
            }
            case ESM::fourCC("PTDT"):
            case ESM::fourCC("PTD2"):
            {
                if (subHdr.dataSize == sizeof(mTarget)) // TES4
                {
                    reader.get(mTarget);
                    if (mTarget.type != 2)
                        reader.adjustFormId(mTarget.target);
                }
                else if (subHdr.dataSize == 16) // FO3/FONV
                {
                    Target& target = mTargets[subHdr.typeId == ESM::fourCC("PTD2") ? 1 : 0];
                    std::uint32_t form = 0;
                    reader.get(target.type);
                    reader.get(form);
                    reader.get(target.count);
                    reader.get(target.unknown);
                    target.target = ESM::FormId::fromUint32(form);
                    if (target.type != 2)
                        reader.adjustFormId(target.target);
                }
                else
                    reader.skipSubRecordData();

                break;
            }
            case ESM::fourCC("CTDA"):
            {
                if (subHdr.dataSize == 28) // FO3/FONV
                {
                    TargetCondition condition;
                    reader.get(condition);
                    if (condition.reference)
                        reader.adjustFormId(condition.reference);
                    addDialogCondition(reader, mFoConditions, condition, true);
                    break;
                }
                if (subHdr.dataSize != sizeof(CTDA))
                {
                    reader.skipSubRecordData(); // FIXME: FO3
                    break;
                }

                CTDA condition;
                reader.get(condition);
                // FIXME: how to "unadjust" if not FormId?
                // adjustFormId(condition.param1);
                // adjustFormId(condition.param2);
                mConditions.push_back(condition);

                break;
            }
            case ESM::fourCC("POBA"): // FO3
            case ESM::fourCC("POEA"): // FO3
            case ESM::fourCC("POCA"): // FO3
            {
                if (subHdr.typeId == ESM::fourCC("POBA"))
                    event = &mOnBegin;
                else if (subHdr.typeId == ESM::fourCC("POEA"))
                    event = &mOnEnd;
                else
                    event = &mOnChange;
                reader.skipSubRecordData();
                break;
            }
            case ESM::fourCC("INAM"): // FO3: the event's idle
            case ESM::fourCC("TNAM"): // FO3: the event's topic
            {
                if (event == nullptr || subHdr.dataSize != 4)
                {
                    reader.skipSubRecordData();
                    break;
                }
                reader.getFormId(subHdr.typeId == ESM::fourCC("INAM") ? event->mIdle : event->mTopic);
                break;
            }
            case ESM::fourCC("SCTX"): // FO3: the event's script source
            {
                if (event == nullptr)
                    reader.skipSubRecordData();
                else
                    reader.getString(event->mScript);
                break;
            }
            case ESM::fourCC("PKDD"): // FO3
            {
                if (subHdr.dataSize < 8)
                {
                    reader.skipSubRecordData();
                    break;
                }
                reader.get(mDialogueFov);
                reader.getFormId(mDialogueTopic);
                std::uint32_t left = subHdr.dataSize - 8;
                if (left >= 4)
                {
                    reader.get(mDialogueFlags);
                    left -= 4;
                }
                if (left >= 8)
                {
                    reader.skipSubRecordData(4); // unused
                    reader.get(mDialogueType);
                    left -= 8;
                }
                if (left > 0)
                    reader.skipSubRecordData(left);
                break;
            }
            case ESM::fourCC("CTDT"): // always 20 for TES4
            case ESM::fourCC("CNAM"): // FO3
            case ESM::fourCC("SCHR"): // FO3
            case ESM::fourCC("SCDA"): // FO3
            case ESM::fourCC("SCRO"): // FO3
            case ESM::fourCC("IDLA"): // FO3
            case ESM::fourCC("IDLC"): // FO3
            case ESM::fourCC("IDLF"): // FO3
            case ESM::fourCC("IDLT"): // FO3
            case ESM::fourCC("PKD2"): // FO3
            case ESM::fourCC("PKPT"): // FO3
            case ESM::fourCC("PKED"): // FO3
            case ESM::fourCC("PKE2"): // FO3
            case ESM::fourCC("PKAM"): // FO3
            case ESM::fourCC("PUID"): // FO3
            case ESM::fourCC("PKW3"): // FO3
            case ESM::fourCC("PKFD"): // FO3
            case ESM::fourCC("SLSD"): // FO3
            case ESM::fourCC("SCVR"): // FO3
            case ESM::fourCC("SCRV"): // FO3
            case ESM::fourCC("IDLB"): // FO3
            case ESM::fourCC("ANAM"): // TES5
            case ESM::fourCC("BNAM"): // TES5
            case ESM::fourCC("FNAM"): // TES5
            case ESM::fourCC("PNAM"): // TES5
            case ESM::fourCC("QNAM"): // TES5
            case ESM::fourCC("UNAM"): // TES5
            case ESM::fourCC("XNAM"): // TES5
            case ESM::fourCC("PDTO"): // TES5
            case ESM::fourCC("PTDA"): // TES5
            case ESM::fourCC("PFOR"): // TES5
            case ESM::fourCC("PFO2"): // TES5
            case ESM::fourCC("PRCB"): // TES5
            case ESM::fourCC("PKCU"): // TES5
            case ESM::fourCC("PKC2"): // TES5
            case ESM::fourCC("CITC"): // TES5
            case ESM::fourCC("CIS1"): // TES5
            case ESM::fourCC("CIS2"): // TES5
            case ESM::fourCC("VMAD"): // TES5
            case ESM::fourCC("TPIC"): // TES5
                reader.skipSubRecordData();
                break;
            default:
                throw std::runtime_error("ESM4::PACK::load - Unknown subrecord " + ESM::printName(subHdr.typeId));
        }
    }
}

// void ESM4::AIPackage::save(ESM4::Writer& writer) const
//{
// }

// void ESM4::AIPackage::blank()
//{
// }
