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
#include "loadinfo.hpp"

#include <cstring>
#include <cstring>
#include <stdexcept>

#include <components/esm/refid.hpp>

#include "grouptype.hpp"
#include "reader.hpp"
//#include "writer.hpp"

namespace
{
    void addCondition(ESM4::Reader& reader, std::vector<ESM4::DialogCondition>& conditions,
        const ESM4::TargetCondition& data, bool hasReference)
    {
        ESM4::DialogCondition& cond = conditions.emplace_back();
        cond.mData = data;
        cond.mParam1 = ESM::FormId::fromUint32(data.param1);
        reader.adjustFormId(cond.mParam1);
        cond.mParam2 = ESM::FormId::fromUint32(data.param2);
        reader.adjustFormId(cond.mParam2);
        if (hasReference && data.reference)
            cond.mReference = ESM::FormId::fromUint32(data.reference); // already adjusted in place
        if (data.condition & ESM4::CTF_UseGlobal)
        {
            std::uint32_t global;
            std::memcpy(&global, &data.comparison, sizeof(global));
            cond.mGlobal = ESM::FormId::fromUint32(global);
            reader.adjustFormId(cond.mGlobal);
        }
    }
}

void ESM4::DialogInfo::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    mEditorId = ESM::RefId(mId).serializeText(); // FIXME: quick workaround to use existing code

    static std::uint32_t sLoadIndex = 0;
    mLoadIndex = ++sLoadIndex;

    // INFO records live in the topic children group of their DIAL
    if (reader.stackSize() > 0 && reader.grp().type == ESM4::Grp_TopicChild)
        mTopic = ESM::FormId::fromUint32(reader.grp().label.value);

    ScriptDefinition* script = &mScript; // switches to mScriptEnd after NEXT

    while (reader.getSubRecordHeader())
    {
        const ESM4::SubRecordHeader& subHdr = reader.subRecordHeader();
        switch (subHdr.typeId)
        {
            case ESM::fourCC("QSTI"):
                reader.getFormId(mQuest);
                break; // FormId quest id
            case ESM::fourCC("SNDD"):
                reader.getFormId(mSound);
                break; // FO3 (not used in FONV?)
            case ESM::fourCC("TRDT"):
            {
                if (subHdr.dataSize == 16) // TES4
                    reader.get(&mResponseData, 16);
                else if (subHdr.dataSize == 20) // FO3
                    reader.get(&mResponseData, 20);
                else // FO3/FONV
                {
                    reader.get(mResponseData);
                    if (mResponseData.sound)
                        reader.adjustFormId(mResponseData.sound);
                }
                mResponses.emplace_back().mData = mResponseData;

                break;
            }
            case ESM::fourCC("NAM1"):
                reader.getLocalizedString(mResponse);
                if (mResponses.empty())
                    mResponses.emplace_back();
                mResponses.back().mText = mResponse;
                break; // response text
            case ESM::fourCC("NAM2"):
                reader.getZString(mNotes);
                if (!mResponses.empty())
                    mResponses.back().mNotes = mNotes;
                break; // actor notes
            case ESM::fourCC("NAM3"):
                reader.getZString(mEdits);
                break; // not in TES4
            case ESM::fourCC("CTDA"): // FIXME: how to detect if 1st/2nd param is a formid?
            {
                if (subHdr.dataSize == 24) // TES4
                {
                    mTargetCondition = {};
                    reader.get(&mTargetCondition, 24);
                    addCondition(reader, mConditions, mTargetCondition, false);
                }
                else if (subHdr.dataSize == 20) // FO3
                {
                    mTargetCondition = {};
                    reader.get(&mTargetCondition, 20);
                    addCondition(reader, mConditions, mTargetCondition, false);
                }
                else if (subHdr.dataSize == 28)
                {
                    reader.get(mTargetCondition); // FO3/FONV
                    if (mTargetCondition.reference)
                        reader.adjustFormId(mTargetCondition.reference);
                    addCondition(reader, mConditions, mTargetCondition, true);
                }
                else // TES5
                {
                    reader.get(&mTargetCondition, 20);
                    if (subHdr.dataSize == 36)
                        reader.getFormId(mParam3);
                    reader.get(mTargetCondition.runOn);
                    reader.get(mTargetCondition.reference);
                    if (mTargetCondition.reference)
                        reader.adjustFormId(mTargetCondition.reference);
                    reader.skipSubRecordData(4); // unknown
                }

                break;
            }
            case ESM::fourCC("SCHR"):
            {
                reader.get(script->scriptHeader);
                break;
            }
            case ESM::fourCC("SCDA"):
                reader.skipSubRecordData();
                break; // compiled script data
            case ESM::fourCC("SCTX"):
                reader.getString(script->scriptSource);
                break;
            case ESM::fourCC("SCRO"):
                reader.getFormId(script->globReference);
                break;
            case ESM::fourCC("SLSD"):
            {
                ScriptLocalVariableData localVar;
                reader.get(localVar.index);
                reader.get(localVar.unknown1);
                reader.get(localVar.unknown2);
                reader.get(localVar.unknown3);
                reader.get(localVar.type);
                reader.get(localVar.unknown4);
                script->localVarData.push_back(std::move(localVar));
                // WARN: assumes SCVR will follow immediately

                break;
            }
            case ESM::fourCC("SCVR"): // assumed always pair with SLSD
            {
                if (!script->localVarData.empty())
                    reader.getZString(script->localVarData.back().variableName);
                else
                    reader.skipSubRecordData();

                break;
            }
            case ESM::fourCC("SCRV"):
            {
                std::uint32_t index;
                reader.get(index);

                script->localRefVarIndex.push_back(index);

                break;
            }
            case ESM::fourCC("NEXT"): // FO3/FONV marker for next script header
            {
                script = &mScriptEnd;

                break;
            }
            case ESM::fourCC("DATA"): // always 3 for TES4 ?
            {
                if (subHdr.dataSize == 4) // FO3/FONV
                {
                    reader.get(mDialType);
                    reader.get(mNextSpeaker);
                    reader.get(mInfoFlags);
                }
                else
                    reader.skipSubRecordData(); // FIXME
                break;
            }
            case ESM::fourCC("NAME"): // FormId add topic (not always present)
                if (subHdr.dataSize == 4)
                    reader.getFormId(mAddTopics.emplace_back());
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("TCLT"): // FormId choice
                if (subHdr.dataSize == 4)
                    reader.getFormId(mChoices.emplace_back());
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("TCLF"): // FormId
                if (subHdr.dataSize == 4)
                    reader.getFormId(mLinkFrom.emplace_back());
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("PNAM"): // FO3/FONV previous INFO (TES4 DLC: unknown)
                if (subHdr.dataSize == 4)
                    reader.getFormId(mPrevInfo);
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("ANAM"): // FO3 speaker formid
                if (subHdr.dataSize == 4)
                    reader.getFormId(mSpeaker);
                else
                    reader.skipSubRecordData();
                break;
            case ESM::fourCC("RNAM"): // FONV/TES5 prompt
                reader.getLocalizedString(mPrompt);
                break;
            case ESM::fourCC("CTDT"): // older version of CTDA? 20 bytes
            case ESM::fourCC("SCHD"): // 28 bytes
            case ESM::fourCC("TPIC"): // TES4 DLC
            case ESM::fourCC("DNAM"): // FO3 speech challenge
            case ESM::fourCC("KNAM"): // FO3 formid
            case ESM::fourCC("LNAM"): // FONV
            case ESM::fourCC("TCFU"): // FONV
            case ESM::fourCC("TIFC"): // TES5
            case ESM::fourCC("TWAT"): // TES5
            case ESM::fourCC("CIS1"): // TES5
            case ESM::fourCC("CIS2"): // TES5
            case ESM::fourCC("CNAM"): // TES5
            case ESM::fourCC("ENAM"): // TES5
            case ESM::fourCC("EDID"): // TES5
            case ESM::fourCC("VMAD"): // TES5
            case ESM::fourCC("BNAM"): // TES5
            case ESM::fourCC("SNAM"): // TES5
            case ESM::fourCC("ONAM"): // TES5
            case ESM::fourCC("QNAM"): // TES5 for mScript
            case ESM::fourCC("ALFA"): // FO4
            case ESM::fourCC("GNAM"): // FO4
            case ESM::fourCC("GREE"): // FO4
            case ESM::fourCC("INAM"): // FO4
            case ESM::fourCC("INCC"): // FO4
            case ESM::fourCC("INTV"): // FO4
            case ESM::fourCC("IOVR"): // FO4
            case ESM::fourCC("MODQ"): // FO4
            case ESM::fourCC("NAM0"): // FO4
            case ESM::fourCC("NAM4"): // FO4
            case ESM::fourCC("NAM9"): // FO4
            case ESM::fourCC("SRAF"): // FO4
            case ESM::fourCC("TIQS"): // FO4
            case ESM::fourCC("TNAM"): // FO4
            case ESM::fourCC("TRDA"): // FO4
            case ESM::fourCC("TSCE"): // FO4
            case ESM::fourCC("WZMD"): // FO4
                reader.skipSubRecordData();
                break;
            default:
                throw std::runtime_error("ESM4::INFO::load - Unknown subrecord " + ESM::printName(subHdr.typeId));
        }
    }
}

// void ESM4::DialogInfo::save(ESM4::Writer& writer) const
//{
// }

// void ESM4::DialogInfo::blank()
//{
// }
