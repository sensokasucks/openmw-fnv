/*
  Copyright (C) 2019, 2020 cc9cii

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
#ifndef ESM4_TERM_H
#define ESM4_TERM_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

#include "loadinfo.hpp" // DialogCondition

namespace ESM4
{
    class Reader;
    class Writer;

    struct TerminalItem
    {
        enum Flags : std::uint8_t
        {
            Flag_AddNote = 0x01,
            Flag_ForceRedraw = 0x02,
        };

        std::string mText; // ITXT, the menu entry
        std::string mResultText; // RNAM, shown once the entry is picked
        std::uint8_t mFlags = 0; // ANAM
        ESM::FormId mDisplayNote; // INAM, NOTE shown (and added when Flag_AddNote)
        ESM::FormId mSubMenu; // TNAM, TERM opened instead
        std::string mScriptSource; // SCTX of the embedded result script
        bool mHasConditions = false; // CTDA present
        std::vector<DialogCondition> mConditions; // the entry shows only when they pass (run on the terminal)
    };

    struct Terminal
    {
        enum Flags : std::uint8_t
        {
            Flag_Leveled = 0x01,
            Flag_UnlockedAtStart = 0x02,
            Flag_AlternateColors = 0x04,
            Flag_HideWelcome = 0x08,
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::string mText;

        ESM::Path mModel;

        std::uint8_t mDifficulty = 0; // DNAM: 0 very easy .. 4 very hard, 5 requires key
        std::uint8_t mTerminalFlags = 0; // DNAM
        std::uint8_t mServerType = 0; // DNAM

        std::vector<TerminalItem> mItems;

        ESM::FormId mScriptId;
        ESM::FormId mPasswordNote;
        ESM::FormId mSound;

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_TERM4;
    };
}

#endif // ESM4_TERM_H
