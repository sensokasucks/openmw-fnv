#ifndef ESM4_RCCT_H
#define ESM4_RCCT_H

#include <cstdint>
#include <string>

#include <components/esm/defs.hpp>
#include <components/esm/formid.hpp>

namespace ESM4
{
    class Reader;
    class Writer;

    // FONV recipe category (RCCT): CampfireRecipes, WorkbenchRecipes, ReloadingBenchRecipes and their subcategories.
    struct RecipeCategory
    {
        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::uint8_t mCategoryFlags = 0; // DATA

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_RCCT4;
    };
}

#endif // ESM4_RCCT_H
