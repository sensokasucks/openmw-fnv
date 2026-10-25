/*
  Copyright (C) 2016, 2018-2020 cc9cii

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
#ifndef ESM4_WEAP_H
#define ESM4_WEAP_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;
    class Writer;

    struct Weapon
    {
        struct Data
        {
            // type
            // 0 = Blade One Hand
            // 1 = Blade Two Hand
            // 2 = Blunt One Hand
            // 3 = Blunt Two Hand
            // 4 = Staff
            // 5 = Bow
            std::uint32_t type;
            float speed;
            float reach;
            std::uint32_t flags;
            std::uint32_t value; // gold
            std::uint32_t health;
            float weight;
            std::uint16_t damage;
            std::uint8_t clipSize; // FO3/FONV only

            Data()
                : type(0)
                , speed(0.f)
                , reach(0.f)
                , flags(0)
                , value(0)
                , health(0)
                , weight(0.f)
                , damage(0)
                , clipSize(0)
            {
            }
        };

        // FO3/FONV DNAM, the fields combat uses (offsets in the subrecord)
        struct DataFO3
        {
            // 0 hand to hand, 1 melee 1H, 2 melee 2H, 3 pistol ballistic, 4 pistol energy, 5 rifle ballistic,
            // 6 rifle automatic, 7 rifle energy, 8 handle, 9 launcher, 10 grenade throw, 11 land mine,
            // 12 mine drop, 13 thrown
            std::uint32_t animType = 0; // 0
            float animMult = 1.f; // 4
            float reach = 0.f; // 8
            std::uint8_t flags1 = 0; // 12
            std::uint8_t ammoUse = 1; // 14
            std::uint8_t reloadAnim = 0; // 15
            float minSpread = 0.f; // 16
            float spread = 0.f; // 20
            ESM::FormId projectile; // 36
            std::uint8_t attackAnim = 255; // 41: 26 left, 32 right, 38 attack3 ... 68 attack8 (steps of 6), 74 loop
            std::uint8_t projectileCount = 1; // 42
            float minRange = 0.f; // 44
            float maxRange = 0.f; // 48
            std::uint32_t flags2 = 0; // 56
            float animAttackMult = 1.f; // 60
            float fireRate = 1.f; // 64
            float actionPoints = 0.f; // 68
            float shotsPerSecond = 0.f; // 88
            float reloadTime = 0.f; // 92
            float jamTime = 0.f; // 96
            std::int32_t skill = -1; // 104, actor value
            float limbDamageMult = 1.f; // 116
            std::int32_t resistType = -1; // 120, actor value
            float semiAutoDelayMin = 0.f; // 128
            float semiAutoDelayMax = 0.f; // 132
            std::uint32_t strengthRequirement = 0; // 168
            std::uint32_t skillRequirement = 0; // 200
        };

        enum Flags1FO3
        {
            FO3_IgnoresNormalResist = 0x01,
            FO3_Automatic = 0x02,
            FO3_HasScope = 0x04,
            FO3_CantDrop = 0x08,
            FO3_HideBackpack = 0x10,
            FO3_EmbeddedWeapon = 0x20,
            FO3_NoFirstPersonModel = 0x40,
            FO3_NonPlayable = 0x80,
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        ESM::Path mModel;
        std::string mText;
        std::string mIcon;
        std::string mMiniIcon;

        ESM::FormId mPickUpSound;
        ESM::FormId mDropSound;

        float mBoundRadius;

        ESM::FormId mScriptId;
        std::uint16_t mEnchantmentPoints;
        ESM::FormId mEnchantment;

        Data mData;

        // FO3/FONV
        DataFO3 mFO3Data;
        bool mHasFO3Data = false;
        ESM::FormId mAmmo; // AMMO or FLST of ammo (NAM0)
        ESM::FormId mFireSound; // 3D (first SNAM)
        ESM::FormId mFireSoundDist; // distant (second SNAM)
        ESM::FormId mFireSound2D; // player (XNAM)
        ESM::FormId mDryFireSound; // TNAM
        ESM::FormId mImpactDataSet; // INAM
        std::uint16_t mCritDamage = 0; // CRDT
        float mCritChanceMult = 1.f;

        void load(ESM4::Reader& reader);
        // void save(ESM4::Writer& writer) const;

        // void blank();
        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_WEAP4;
    };
}

#endif // ESM4_WEAP_H
