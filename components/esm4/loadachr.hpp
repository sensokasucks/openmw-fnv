/*
  Copyright (C) 2016, 2018, 2020-2021 cc9cii

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
#ifndef ESM4_ACHR_H
#define ESM4_ACHR_H

#include <cstdint>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/position.hpp>
#include <components/esm/refid.hpp>

#include "reference.hpp" // Placement, EnableParent

namespace ESM4
{
    class Reader;
    class Writer;

    struct ActorCharacter
    {
        ESM::FormId mId; // from the header
        ESM::RefId mParent; // cell FormId , from the loading sequence
                            // NOTE: for exterior cells it will be the dummy cell FormId
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        ESM::FormId mBaseObj;

        ESM::Position mPos;
        float mScale = 1.0f;
        ESM::FormId mOwner;
        ESM::FormId mGlobal;
        ESM::FormId mLinkedRef; // XLKR (FO3/FONV), GetLinkedRef
        ESM::FormId mMerchantContainer; // XMRC (FO3/FONV): the container a vendor sells from

        EnableParent mEsp;

        std::int32_t mCount = 1;

        // XRGD (FO3/FONV): the ragdoll pose of a placed dead actor (FalloutNV.exe ExtraRagDollData, loader 0x004d94a0,
        // applied by 0x004d9dc0): one 28-byte entry per skeleton node with a Havok body, in NIF tree order (pre-order).
        // Each is that node's local transform, relative to its parent node, in game units; the rotation is
        // NiMatrix3::FromEulerAnglesXYZ (radians). mBodyPart is the body's biped part (its collision filter
        // bits 8-12), which the game checks against the skeleton before posing.
        struct RagdollBone
        {
            std::uint8_t mBodyPart;
            float mPosition[3];
            float mRotation[3];
        };
        std::vector<RagdollBone> mRagdollPose;
        // XRGB: the Euler rotation of the skeleton root's first child (Bip01) for that pose
        bool mHasRagdollRootRotation = false;
        float mRagdollRootRotation[3] = { 0.f, 0.f, 0.f };

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::REC_ACHR4;
    };

    struct ActorCreature : public ActorCharacter
    {
        static constexpr ESM::RecNameInts sRecordId = ESM::REC_ACRE4;
    };
}

#endif // ESM4_ACHR_H
