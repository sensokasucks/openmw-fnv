#ifndef ESM4_RCPE_H
#define ESM4_RCPE_H

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

    // FONV crafting recipe (RCPE), shown by ShowRecipeMenu at campfires, workbenches and reloading benches.
    struct Recipe
    {
        struct Component
        {
            ESM::FormId mItem;
            std::uint32_t mCount = 1;
        };

        ESM::FormId mId; // from the header
        std::uint32_t mFlags; // from the header, see enum type RecordFlag for details

        std::string mEditorId;
        std::string mFullName;
        std::int32_t mSkill = -1; // DATA: actor value of the skill it needs, -1 for none
        std::uint32_t mSkillLevel = 0; // DATA
        ESM::FormId mCategory; // DATA: RCCT (CampfireRecipes, WorkbenchRecipes, ...)
        ESM::FormId mSubCategory; // DATA: RCCT
        std::vector<DialogCondition> mConditions; // CTDA, on the player
        std::vector<Component> mInputs; // RCIL + RCQY
        std::vector<Component> mOutputs; // RCOD + RCQY

        void load(ESM4::Reader& reader);

        static constexpr ESM::RecNameInts sRecordId = ESM::RecNameInts::REC_RCPE4;
    };
}

#endif // ESM4_RCPE_H
