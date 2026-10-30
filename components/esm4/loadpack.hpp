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
#ifndef ESM4_PACK_H
#define ESM4_PACK_H

#include <cstdint>
#include <string>
#include <vector>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

#include "loadinfo.hpp" // DialogCondition

namespace ESM4
{
    class Reader;
    class Writer;

    struct AIPackage
    {
#pragma pack(push, 1)
        struct PKDT // data
        {
            std::uint32_t flags;
            std::int32_t type;
        };

        struct PSDT // schedule
        {
            std::uint8_t month; // Any = 0xff
            std::uint8_t dayOfWeek; // Any = 0xff
            std::uint8_t date; // Any = 0
            std::uint8_t time; // Any = 0xff
            std::uint32_t duration;
        };

        struct PLDT // location
        {
            std::int32_t type = 0xff; // 0 = near ref, 1 = in cell, 2 = current loc, 3 = editor loc, 4 = obj id, 5 = obj
                                      // type, 0xff = no location data
            ESM::FormId32 location; // uint32_t if type = 5
            std::int32_t radius;
        };

        struct PTDT // target
        {
            std::int32_t type = 0xff; // 0 = specific ref, 1 = obj id, 2 = obj type, 0xff = no target data
            ESM::FormId32 target; // uint32_t if type = 2
            std::int32_t distance;
        };

        // NOTE: param1/param2 can be FormId or number, but assume FormId so that adjustFormId
        // can be called
        struct CTDA
        {
            std::uint8_t condition;
            std::uint8_t unknown1; // probably padding
            std::uint8_t unknown2; // probably padding
            std::uint8_t unknown3; // probably padding
            float compValue;
            std::int32_t fnIndex;
            ESM::FormId32 param1;
            ESM::FormId32 param2;
            std::uint32_t unknown4; // probably padding
        };
#pragma pack(pop)

        // FO3/FONV package types (PKDT type)
        enum Type : std::int32_t
        {
            Type_Find = 0,
            Type_Follow = 1,
            Type_Escort = 2,
            Type_Eat = 3,
            Type_Sleep = 4,
            Type_Wander = 5,
            Type_Travel = 6,
            Type_Accompany = 7,
            Type_UseItemAt = 8,
            Type_Ambush = 9,
            Type_FleeNotCombat = 10,
            Type_CastMagic = 11,
            Type_Sandbox = 12,
            Type_Patrol = 13,
            Type_Guard = 14,
            Type_Dialogue = 15,
            Type_UseWeapon = 16,
        };

        // FO3/FONV location types (PLDT/PLD2 type)
        enum LocationType : std::int32_t
        {
            Location_NearReference = 0,
            Location_InCell = 1,
            Location_NearCurrentLocation = 2,
            Location_NearEditorLocation = 3,
            Location_ObjectId = 4,
            Location_ObjectType = 5,
            Location_NearLinkedReference = 6,
            Location_AtPackageLocation = 7,
            Location_None = 0xff,
        };

        // FO3/FONV target (PTDT/PTD2): 0 specific reference, 1 object id, 2 object type, 3 linked reference
        struct Target
        {
            std::int32_t type = 0xff;
            ESM::FormId target; // raw object type for type 2
            std::int32_t count = 0; // count or distance
            float unknown = 0.f;
        };

        // FO3/FONV location (PLDT/PLD2); the object type of type 5 is kept raw in objectType
        struct Location
        {
            std::int32_t type = Location_None;
            ESM::FormId location;
            std::uint32_t objectType = 0;
            std::int32_t radius = 0;
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;

        PKDT mData;
        std::uint16_t mBehaviourFlags = 0; // FO3/FONV
        std::uint16_t mSpecificFlags = 0; // FO3/FONV, meaning depends on the package type
        PSDT mSchedule;
        PLDT mLocation; // TES4
        PTDT mTarget; // TES4
        std::vector<CTDA> mConditions; // TES4
        Location mLocations[2]; // FO3/FONV: PLDT, PLD2
        Target mTargets[2]; // FO3/FONV: PTDT, PTD2
        std::vector<DialogCondition> mFoConditions; // FO3/FONV, in order

        // FO3/FONV package events: POBA (OnBegin), POEA (OnEnd), POCA (OnChange), each followed by an idle (INAM),
        // a result script (SCHR, SCDA, SCTX, SCRO...) and a topic (TNAM)
        struct Event
        {
            ESM::FormId mIdle;
            ESM::FormId mTopic;
            std::string mScript; // source text (SCTX)
        };
        Event mOnBegin;
        Event mOnEnd;
        Event mOnChange;

        // FO3/FONV Dialogue package data (PKDD)
        float mDialogueFov = 0.f; // degrees
        ESM::FormId mDialogueTopic;
        std::uint32_t mDialogueFlags = 0; // 1 no headtracking, 0x100 don't control target movement
        std::uint32_t mDialogueType = 0; // 0 conversation, 1 say to

        // FO3/FONV package idle animations (IDLF, IDLC, IDLT, IDLA): played while the package waits, such as at the
        // points of a patrol that are not idle markers
        std::uint8_t mIdleFlags = 0; // 1 run in sequence, 4 do once
        float mIdleTimer = 0.f; // seconds (IDLT)
        std::vector<ESM::FormId> mIdles; // IDLE records (IDLA)

        bool mPatrolRepeatable = false; // PKPT
        std::uint32_t mEscortDistance = 0; // PKE2
        float mFollowTriggerRadius = 0.f; // PKFD
        ESM::FormId mCombatStyle; // CNAM

        // FO3/FONV Use Weapon data (PKW3)
        struct UseWeaponData
        {
            std::uint32_t flags = 0; // 1 always hit, 0x100 do no damage, 0x10000 crouch to reload, 0x1000000 hold
                                     // fire when blocked
            std::uint8_t fireRate = 0; // 0 auto fire, 1 volley fire
            std::uint8_t fireCount = 0; // 0 number of bursts, 1 repeat fire
            std::uint16_t bursts = 0;
            std::uint16_t shotsPerVolleyMin = 0;
            std::uint16_t shotsPerVolleyMax = 0;
            float pauseMin = 0.f;
            float pauseMax = 0.f;
        };
        UseWeaponData mUseWeapon;
        bool mHasUseWeapon = false;

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_PACK4;
    };
}

#endif // ESM4_PACK_H
