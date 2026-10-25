#include "esm4gamesettings.hpp"

#include <mutex>
#include <string>
#include <type_traits>
#include <unordered_set>
#include <unordered_map>

#include <components/debug/debuglog.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"

#include "esmstore.hpp"

namespace MWWorld::ESM4GameSettings
{
    namespace
    {
        using Values = std::unordered_map<std::string, ESM4::GameSetting::Data, Misc::StringUtils::CiHash,
            Misc::StringUtils::CiEqual>;

        std::mutex sMutex;
        const ESMStore* sStore = nullptr;
        Values sValues;
        std::unordered_set<std::string, Misc::StringUtils::CiHash, Misc::StringUtils::CiEqual> sWarned;

        // Built on first use and again whenever the content (the ESMStore) changes.
        const Values& values()
        {
            const ESMStore* store = MWBase::Environment::get().getESMStore();
            std::lock_guard lock(sMutex);
            if (store == sStore && !sValues.empty())
                return sValues;
            sStore = store;
            sValues.clear();
            for (const Default& value : exeDefaults())
                std::visit(
                    [&](const auto& v) {
                        using V = std::decay_t<decltype(v)>;
                        if constexpr (std::is_same_v<V, std::string_view>)
                            sValues[std::string(value.mName)] = std::string(v);
                        else
                            sValues[std::string(value.mName)] = v;
                    },
                    value.mValue);
            if (store != nullptr)
            {
                // The store keeps one record per FormId and a later file's record replaces the earlier one, which
                // is how the DLCs override FalloutNV.esm settings.
                for (const ESM4::GameSetting& setting : store->get<ESM4::GameSetting>())
                {
                    if (setting.mEditorId.empty() || std::holds_alternative<std::monostate>(setting.mData))
                        continue;
                    sValues[setting.mEditorId] = setting.mData;
                }
            }
            return sValues;
        }

        template <class T>
        T toNumber(const ESM4::GameSetting::Data* value, T fallback)
        {
            if (value == nullptr)
                return fallback;
            return std::visit(
                [&](const auto& v) -> T {
                    using V = std::decay_t<decltype(v)>;
                    if constexpr (std::is_arithmetic_v<V>)
                        return static_cast<T>(v);
                    else
                        return fallback;
                },
                *value);
        }

        const ESM4::GameSetting::Data* findOrWarn(std::string_view name)
        {
            const ESM4::GameSetting::Data* value = find(name);
            if (value == nullptr)
            {
                std::lock_guard lock(sMutex);
                if (sWarned.emplace(name).second)
                    Log(Debug::Warning) << "Unknown FNV game setting " << name;
            }
            return value;
        }
    }

    const ESM4::GameSetting::Data* find(std::string_view name)
    {
        const Values& all = values();
        auto it = all.find(name);
        return it == all.end() ? nullptr : &it->second;
    }

    float getFloat(std::string_view name, float fallback)
    {
        return toNumber(findOrWarn(name), fallback);
    }

    int getInt(std::string_view name, int fallback)
    {
        return toNumber(findOrWarn(name), fallback);
    }

    bool getBool(std::string_view name, bool fallback)
    {
        return toNumber(findOrWarn(name), fallback);
    }

    std::string_view getString(std::string_view name, std::string_view fallback)
    {
        const ESM4::GameSetting::Data* value = findOrWarn(name);
        if (value == nullptr)
            return fallback;
        if (const std::string* text = std::get_if<std::string>(value))
            return *text;
        return fallback;
    }
}
