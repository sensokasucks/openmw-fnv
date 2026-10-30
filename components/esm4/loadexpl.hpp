#ifndef ESM4_EXPL_H
#define ESM4_EXPL_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>
#include <components/esm/path.hpp>

namespace ESM4
{
    class Reader;

    // FO3/FONV explosion: grenades and mines, and the blood bursts of exploding limbs (BPTD).
    struct Explosion
    {
        // FONV DATA (52 bytes; FO3 stops after mSound2)
        struct Data
        {
            float force = 0.f;
            float damage = 0.f;
            float radius = 0.f;
            ESM::FormId light;
            ESM::FormId sound1;
            std::uint32_t flags = 0;
            float isRadius = 0.f;
            ESM::FormId impactDataSet; // IPDS
            ESM::FormId sound2;
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        ESM::Path mModel;
        ESM::FormId mEnchantment; // EITM
        ESM::FormId mImageSpaceModifier; // MNAM
        ESM::FormId mPlacedImpactObject; // INAM

        Data mData;

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_EXPL4;
    };
}

#endif // ESM4_EXPL_H
