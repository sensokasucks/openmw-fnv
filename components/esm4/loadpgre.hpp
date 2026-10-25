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

  Also see https://tes5edit.github.io/fopdoc/ for FO3/FONV specific details.

*/
#ifndef ESM4_PGRE_H
#define ESM4_PGRE_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/position.hpp>

#include "reference.hpp" // EnableParent

namespace ESM4
{
    class Reader;
    class Writer;

    // A placed projectile: PGRE (placed grenade, how FNV places mines) or PMIS (placed missile). The base
    // object is a PROJ record; the reference sits in a cell like a REFR.
    struct PlacedProjectile
    {
        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details
        ESM::FormId mParent; // cell FormId, from the loading sequence

        std::string mEditorId;

        ESM::FormId mBaseObj;
        ESM::Position mPos;
        float mScale = 1.0f;
        ESM::FormId mOwner;
        std::int32_t mFactionRank = -1;
        EnableParent mEsp;

        void load(ESM4::Reader& reader);
    };

    struct PlacedGrenade : PlacedProjectile
    {
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_PGRE4;
    };

    struct PlacedMissile : PlacedProjectile
    {
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_PMIS4;
    };
}

#endif // ESM4_PGRE_H
