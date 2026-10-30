#ifndef GAME_MWCLASS_ESM4ITEM_H
#define GAME_MWCLASS_ESM4ITEM_H

#include <map>

#include <components/esm4/loadalch.hpp>
#include <components/esm4/loadammo.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadbook.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loadimod.hpp>
#include <components/esm4/loadingr.hpp>
#include <components/esm4/loadkeym.hpp>
#include <components/esm4/loadmisc.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/vfs/pathutil.hpp>

#include "../mwworld/action.hpp"

#include "esm4base.hpp"

namespace MWClass
{
    namespace ESM4Impl
    {
        inline float getItemWeight(const ESM4::Potion& rec)
        {
            return rec.mData.weight;
        }
        inline int getItemValue(const ESM4::Potion& rec)
        {
            return rec.mItem.value;
        }
        inline float getItemWeight(const ESM4::Ammunition& rec)
        {
            return rec.mData.mWeight;
        }
        inline int getItemValue(const ESM4::Ammunition& rec)
        {
            return static_cast<int>(rec.mData.mValue);
        }
        inline float getItemWeight(const ESM4::ItemMod& rec)
        {
            return rec.mData.mWeight;
        }
        inline int getItemValue(const ESM4::ItemMod& rec)
        {
            return static_cast<int>(rec.mData.mValue);
        }
        template <class Record>
        float getItemWeight(const Record& rec)
        {
            return rec.mData.weight;
        }
        template <class Record>
        int getItemValue(const Record& rec)
        {
            return static_cast<int>(rec.mData.value);
        }

        inline const std::string& getItemIcon(const ESM4::Armor& rec)
        {
            return rec.mIconMale;
        }
        inline const std::string& getItemIcon(const ESM4::Clothing& rec)
        {
            return rec.mIconMale;
        }
        template <class Record>
        const std::string& getItemIcon(const Record& rec)
        {
            return rec.mIcon;
        }

        template <class Record>
        ESM::RefId getItemUpSound(const Record& rec)
        {
            if constexpr (requires { rec.mPickUpSound; })
                return rec.mPickUpSound;
            else
                return ESM::RefId();
        }
        template <class Record>
        ESM::RefId getItemDownSound(const Record& rec)
        {
            if constexpr (requires { rec.mDropSound; })
                return rec.mDropSound;
            else
                return ESM::RefId();
        }

        // ESM4 icon paths are relative to "textures"; returns the full VFS path, cached per record.
        VFS::Path::NormalizedView getItemIconPath(const void* record, std::string_view icon);

        MWGui::ToolTipInfo getItemToolTipInfo(std::string_view name, int count, float weight, int value);
    }

    // ESM4 records that can be picked up and carried in a ContainerStore.
    template <typename Record>
    class ESM4Item : public MWWorld::RegisteredClass<ESM4Item<Record>, ESM4Base<Record>>
    {
    public:
        ESM4Item()
            : MWWorld::RegisteredClass<ESM4Item, ESM4Base<Record>>(Record::sRecordId)
        {
        }

        std::string_view getName(const MWWorld::ConstPtr& ptr) const override
        {
            return ptr.get<Record>()->mBase->mFullName;
        }

        bool hasToolTip(const MWWorld::ConstPtr& ptr) const override { return !getName(ptr).empty(); }

        MWGui::ToolTipInfo getToolTipInfo(const MWWorld::ConstPtr& ptr, int count) const override
        {
            const Record& rec = *ptr.get<Record>()->mBase;
            return ESM4Impl::getItemToolTipInfo(
                getName(ptr), count, ESM4Impl::getItemWeight(rec), ESM4Impl::getItemValue(rec));
        }

        std::unique_ptr<MWWorld::Action> activate(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor) const override
        {
            return this->defaultItemActivate(ptr, actor);
        }

        float getWeight(const MWWorld::ConstPtr& ptr) const override
        {
            return ESM4Impl::getItemWeight(*ptr.get<Record>()->mBase);
        }

        int getValue(const MWWorld::ConstPtr& ptr) const override
        {
            return ESM4Impl::getItemValue(*ptr.get<Record>()->mBase);
        }

        VFS::Path::NormalizedView getInventoryIcon(const MWWorld::ConstPtr& ptr) const override
        {
            const Record* rec = ptr.get<Record>()->mBase;
            return ESM4Impl::getItemIconPath(rec, ESM4Impl::getItemIcon(*rec));
        }

        const ESM::RefId& getUpSoundId(const MWWorld::ConstPtr& ptr) const override
        {
            return cacheSound(ptr, mUpSounds, &ESM4Impl::getItemUpSound<Record>);
        }

        const ESM::RefId& getDownSoundId(const MWWorld::ConstPtr& ptr) const override
        {
            return cacheSound(ptr, mDownSounds, &ESM4Impl::getItemDownSound<Record>);
        }

    private:
        using SoundCache = std::map<const Record*, ESM::RefId>;
        mutable SoundCache mUpSounds;
        mutable SoundCache mDownSounds;

        static const ESM::RefId& cacheSound(
            const MWWorld::ConstPtr& ptr, SoundCache& cache, ESM::RefId (*get)(const Record&))
        {
            const Record* rec = ptr.get<Record>()->mBase;
            auto it = cache.find(rec);
            if (it == cache.end())
                it = cache.emplace(rec, get(*rec)).first;
            return it->second;
        }
    };
}

#endif // GAME_MWCLASS_ESM4ITEM_H
