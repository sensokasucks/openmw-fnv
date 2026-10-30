#ifndef ESM4_PROJ_H
#define ESM4_PROJ_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FONV projectile: bullets, missiles, thrown grenades and placed mines (PGRE/PMIS refs point at one).
    struct Projectile
    {
        enum Flags : std::uint16_t
        {
            Flag_Hitscan = 0x0001,
            Flag_Explosion = 0x0002,
            Flag_AltTrigger = 0x0004, // explodes on proximity or after the timer, not on impact
            Flag_MuzzleFlash = 0x0008,
            Flag_CanBeDisabled = 0x0020,
            Flag_CanBePickedUp = 0x0040,
            Flag_Supersonic = 0x0080,
            Flag_PinsLimbs = 0x0100,
            Flag_PassThroughSmallTransparent = 0x0200,
            Flag_Detonates = 0x0400,
            Flag_Rotation = 0x0800,
        };

        enum Type : std::uint16_t
        {
            Type_Missile = 1,
            Type_Lobber = 2,
            Type_Beam = 4,
            Type_Flame = 8,
            Type_ContinuousBeam = 16,
        };

        // FONV DATA (84 bytes; FO3 stops after mFadeDuration)
        struct Data
        {
            std::uint16_t flags = 0;
            std::uint16_t type = 0;
            float gravity = 0.f;
            float speed = 0.f;
            float range = 0.f;
            ESM::FormId light;
            ESM::FormId muzzleFlashLight;
            float tracerChance = 0.f;
            float explosionProximity = 0.f;
            float explosionTimer = 0.f;
            ESM::FormId explosion; // EXPL
            ESM::FormId sound;
            float muzzleFlashDuration = 0.f;
            float fadeDuration = 0.f;
            float impactForce = 0.f;
            ESM::FormId soundCountdown;
            ESM::FormId soundDisable;
            ESM::FormId defaultWeaponSource; // WEAP picked up from a disarmed mine
            float rotation[3] = { 0.f, 0.f, 0.f };
            float bouncyMult = 0.f;
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        ESM::Path mModel;
        ESM::Path mMuzzleFlashModel; // NAM1
        std::uint32_t mSoundLevel = 0; // VNAM: 0 loud, 1 normal, 2 silent

        Data mData;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_PROJ4;
    };
}

#endif // ESM4_PROJ_H
