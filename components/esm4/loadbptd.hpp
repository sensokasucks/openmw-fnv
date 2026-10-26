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
#ifndef ESM4_BPTD_H
#define ESM4_BPTD_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;
    class Writer;

    struct BodyPartData
    {
        enum Flags : std::uint8_t
        {
            Flag_Severable = 0x01,
            Flag_IKData = 0x02,
            Flag_IKBipedData = 0x04,
            Flag_Explodable = 0x08,
            Flag_IKIsHead = 0x10,
            Flag_IKHeadtracking = 0x20,
            // FalloutNV.exe reads it as "explode chance is absolute": the chance isn't scaled by bonuses
            Flag_AbsoluteChance = 0x40,
        };

        // FO3/FONV limbs; also the body part ids of BSDismemberSkinInstance partitions, where 100 + limb is the cap
        // on the severed limb, 200 + limb the cap on the body and 1000 * limb the body section next to the limb.
        enum PartType : std::uint8_t
        {
            Part_Torso = 0,
            Part_Head1 = 1,
            Part_Head2 = 2,
            Part_LeftArm1 = 3,
            Part_LeftArm2 = 4,
            Part_RightArm1 = 5,
            Part_RightArm2 = 6,
            Part_LeftLeg1 = 7,
            Part_LeftLeg2 = 8,
            Part_LeftLeg3 = 9,
            Part_RightLeg1 = 10,
            Part_RightLeg2 = 11,
            Part_RightLeg3 = 12,
            Part_Brain = 13,
            Part_Weapon = 14,
            Part_Count = 15,
        };

#pragma pack(push, 1)
        struct BPND
        {
            float damageMult;

            // See Flags
            std::uint8_t flags;

            // FO3/FONV limb (LIMB_ENUM): see PartType
            std::uint8_t partType;

            std::uint8_t healthPercent;
            std::int8_t actorValue; //(Actor Values)
            std::uint8_t toHitChance;

            std::uint8_t explExplosionChance; // %
            std::uint16_t explDebrisCount;
            ESM::FormId32 explDebris;
            ESM::FormId32 explExplosion;
            float trackingMaxAngle;
            float explDebrisScale;

            std::int32_t sevDebrisCount;
            ESM::FormId32 sevDebris;
            ESM::FormId32 sevExplosion;
            float sevDebrisScale;

            // Struct - Gore Effects Positioning
            float transX;
            float transY;
            float transZ;
            float rotX;
            float rotY;
            float rotZ;

            ESM::FormId32 sevImpactDataSet;
            ESM::FormId32 explImpactDataSet;
            uint8_t sevDecalCount;
            uint8_t explDecalCount;
            uint16_t Unknown;
            float limbReplacementScale;
        };
#pragma pack(pop)

        struct BodyPart
        {
            std::string mPartName;
            std::string mNodeName;
            std::string mVATSTarget;
            std::string mIKStartNode;
            BPND mData;
            std::string mLimbReplacementModel;
            std::string mGoreEffectsTarget;

            // The forms of mData with the file's load order applied
            ESM::FormId mExplDebris; // DEBR
            ESM::FormId mExplExplosion; // EXPL
            ESM::FormId mSevDebris;
            ESM::FormId mSevExplosion;
            ESM::FormId mSevImpactDataSet; // IPDS
            ESM::FormId mExplImpactDataSet;

            void clear();
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        ESM::Path mModel;

        std::vector<BodyPart> mBodyParts;

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_BPTD4;
    };
}

#endif // ESM4_BPTD_H
