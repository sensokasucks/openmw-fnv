/*
  Copyright (C) 2020 cc9cii

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
#ifndef ESM4_INFO_H
#define ESM4_INFO_H

#include <cstdint>
#include <string>
#include <vector>

#include "script.hpp" // TargetCondition
#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;
    class Writer;

    enum InfoFlag
    {
        INFO_Goodbye = 0x0001,
        INFO_Random = 0x0002,
        INFO_SayOnce = 0x0004,
        INFO_RunImmediately = 0x0008,
        INFO_InfoRefusal = 0x0010,
        INFO_RandomEnd = 0x0020,
        INFO_RunForRumors = 0x0040,
        INFO_SpeechChallenge = 0x0080,
        INFO_SayOnceADay = 0x0100,
        INFO_AlwaysDarken = 0x0200
    };

    // One CTDA condition with its form arguments resolved for the load order.
    // Whether a parameter is a form depends on the function, so both the raw
    // value (in mData) and the adjusted form id are kept.
    struct DialogCondition
    {
        TargetCondition mData;
        ESM::FormId mParam1;
        ESM::FormId mParam2;
        ESM::FormId mReference;
        ESM::FormId mGlobal; // comparison value when CTF_UseGlobal is set
    };

    // Appends one CTDA (already read into data) to conditions, adjusting its form arguments for the load order.
    // When hasReference is set, data.reference must already be adjusted.
    void addDialogCondition(
        Reader& reader, std::vector<DialogCondition>& conditions, const TargetCondition& data, bool hasReference);

    // Appends one CTDA (already read into data) to conditions, adjusting its form arguments for the load order.
    // When hasReference is set, data.reference must already be adjusted.
    void addDialogCondition(
        Reader& reader, std::vector<DialogCondition>& conditions, const TargetCondition& data, bool hasReference);

    // One spoken line (TRDT + NAM1 + NAM2) of an INFO; an INFO can have several.
    struct DialogResponse
    {
        TargetResponseData mData;
        std::string mText;
        std::string mNotes;
    };

    struct DialogInfo
    {
        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId; // FIXME: no such record for INFO, but keep here to avoid extra work for now

        ESM::FormId mQuest;
        ESM::FormId mSound; // unused?

        TargetResponseData mResponseData;
        std::string mResponse;
        std::string mNotes;
        std::string mEdits;

        std::uint8_t mDialType; // DialType
        std::uint8_t mNextSpeaker;
        std::uint16_t mInfoFlags; // see above enum

        TargetCondition mTargetCondition;
        ESM::FormId mParam3; // TES5 only

        ScriptDefinition mScript; // result script (begin)
        ScriptDefinition mScriptEnd; // FO3/FONV: result script (end), after the NEXT sub-record

        ESM::FormId mTopic; // parent DIAL, from the enclosing topic children group
        ESM::FormId mPrevInfo; // FO3/FONV PNAM: previous INFO in the topic
        ESM::FormId mSpeaker; // FO3/FONV ANAM
        std::string mPrompt; // FONV RNAM: text shown for this INFO's topic in the choice list
        std::vector<DialogCondition> mConditions; // all CTDA, in order
        std::vector<DialogResponse> mResponses; // all responses, in order
        std::vector<ESM::FormId> mChoices; // FO3/FONV TCLT: topics offered after this INFO
        std::vector<ESM::FormId> mLinkFrom; // FO3/FONV TCLF
        std::vector<ESM::FormId> mAddTopics; // NAME
        std::uint32_t mLoadIndex = 0; // order in which INFO records were read (file order)

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_INFO4;
    };
}

#endif // ESM4_INFO_H
