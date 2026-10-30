#include "esm4item.hpp"

#include <map>

#include <MyGUI_TextIterator.h>
#include <MyGUI_UString.h>

#include "../mwgui/tooltips.hpp"

namespace MWClass
{
    VFS::Path::NormalizedView ESM4Impl::getItemIconPath(const void* record, std::string_view icon)
    {
        if (icon.empty())
            return {};

        static std::map<const void*, VFS::Path::Normalized> cache;
        auto it = cache.find(record);
        if (it == cache.end())
        {
            std::string path = "textures\\";
            path += icon;
            it = cache.emplace(record, VFS::Path::Normalized(path)).first;
        }
        return it->second;
    }

    MWGui::ToolTipInfo ESM4Impl::getItemToolTipInfo(std::string_view name, int count, float weight, int value)
    {
        MWGui::ToolTipInfo info;
        info.caption = MyGUI::TextIterator::toTagsString(MyGUI::UString(name)) + MWGui::ToolTips::getCountString(count);
        info.text = MWGui::ToolTips::getWeightString(weight, "#{sWeight}")
            + MWGui::ToolTips::getValueString(value, "#{sValue}");
        return info;
    }
}
