#ifndef OPENMW_MWWORLD_ESM4GAMESETTINGS_H
#define OPENMW_MWWORLD_ESM4GAMESETTINGS_H

#include <cstdint>
#include <string_view>
#include <variant>
#include <vector>

#include <components/esm4/loadgmst.hpp>

namespace MWWorld::ESM4GameSettings
{
    // A FNV game setting (GMST) by editor id, ignoring case: the value of the last loaded ESM4 file that sets it,
    // else the FalloutNV.exe default. nullptr when neither knows the name.
    const ESM4::GameSetting::Data* find(std::string_view name);

    // Numeric settings convert between float, int and bool; a missing name or a string gives the fallback.
    float getFloat(std::string_view name, float fallback = 0.f);
    int getInt(std::string_view name, int fallback = 0);
    bool getBool(std::string_view name, bool fallback = false);
    // A missing name or a number gives the fallback.
    std::string_view getString(std::string_view name, std::string_view fallback = {});

    struct Default
    {
        std::string_view mName;
        std::variant<float, std::int32_t, bool, std::string_view> mValue;
    };

    // Every GMST FalloutNV.exe defines with its built-in value (esm4gamesettingdefaults.cpp, generated).
    const std::vector<Default>& exeDefaults();
}

#endif
