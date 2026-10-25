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
#ifndef ESM4_EFFECT_H
#define ESM4_EFFECT_H

#include <cstdint>
#include <vector>

#include <components/esm/formid.hpp>

#include "loadinfo.hpp" // DialogCondition

namespace ESM4
{
#pragma pack(push, 1)
    union EFI_Label
    {
        std::uint32_t value;
        char effect[4];
    };

    struct ScriptEffect
    {
        ESM::FormId32 formId; // Script effect (Magic effect must be SEFF)
        std::int32_t school; // Magic school. See Magic schools for more information.
        EFI_Label visualEffect; // Visual effect name or 0x00000000 if None
        std::uint8_t flags; // 0x01 = Hostile
        std::uint8_t unknown1;
        std::uint8_t unknown2;
        std::uint8_t unknown3;
    };
#pragma pack(pop)

    class Reader;

    // One entry of an FO3/FONV effect list (ALCH, SPEL, ENCH, INGR): EFID, EFIT
    // and the CTDA conditions that follow them.
    struct EffectItem
    {
        enum Range : std::uint32_t
        {
            Range_Self = 0,
            Range_Touch = 1,
            Range_Target = 2,
        };

        ESM::FormId mEffect; // MGEF
        std::uint32_t mMagnitude = 0;
        std::uint32_t mArea = 0;
        std::uint32_t mDuration = 0; // seconds; 0 = instant
        std::uint32_t mRange = Range_Self;
        std::int32_t mActorValue = -1; // only used by some archetypes
        std::vector<DialogCondition> mConditions;
    };

    // Reads EFID/EFIT/CTDA of an FO3/FONV effect list into `effects`; returns
    // false for any other sub-record. Other games' layouts (TES4 EFIT is 24
    // bytes, TES5 12) are skipped. `pendingEffect` holds the EFID until its EFIT.
    bool readEffectSubRecord(Reader& reader, std::vector<EffectItem>& effects, std::uint32_t& pendingEffect);
}

#endif // ESM4_EFFECT_H
