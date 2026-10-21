#include "esm4lock.hpp"

#include <cstdlib>

#include <components/esm3/loadskil.hpp>
#include <components/esm4/loadmisc.hpp>
#include <components/esm4/loadsoun.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/misc/strings/format.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/windowmanager.hpp"

#include "../mwworld/class.hpp"
#include "../mwworld/containerstore.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/ptr.hpp"

#include "../mwmechanics/actorutil.hpp"

namespace MWClass::ESM4Lock
{
    namespace
    {
        // FNV lock levels are 0, 25, 50, 75 or 100. The byte 255 ("requires key") reads back as -1.
        bool requiresKey(int level)
        {
            return level == -1 || level > 100;
        }

        std::string_view levelName(int level)
        {
            if (requiresKey(level))
                return "Requires Key";
            if (level >= 100)
                return "Very Hard";
            if (level >= 75)
                return "Hard";
            if (level >= 50)
                return "Average";
            if (level >= 25)
                return "Easy";
            return "Very Easy";
        }

        template <class Record>
        ESM::RefId findByEditorId(std::string_view editorId)
        {
            const auto& store = MWBase::Environment::get().getESMStore()->get<Record>();
            for (const Record& record : store)
                if (Misc::StringUtils::ciEqual(record.mEditorId, editorId))
                    return record.mId;
            return ESM::RefId();
        }

        // FNV's bobby pin is the misc item "Lockpick". Looked up by editor id since form ids depend on load order.
        const ESM::RefId& bobbyPinId()
        {
            static const ESM::RefId id = findByEditorId<ESM4::MiscItem>("Lockpick");
            return id;
        }

        void unlock(const MWWorld::Ptr& ptr)
        {
            ptr.getCellRef().setLocked(false);
            static const ESM::RefId sound = findByEditorId<ESM4::Sound>("UILockpickingUnlock");
            if (!sound.empty())
                MWBase::Environment::get().getSoundManager()->playSound3D(ptr, sound, 1.f, 1.f);
        }

        void tell(const MWWorld::Ptr& actor, std::string_view message)
        {
            if (actor == MWMechanics::getPlayer())
                MWBase::Environment::get().getWindowManager()->messageBox(message);
        }
    }

    bool tryOpen(const MWWorld::Ptr& ptr, const MWWorld::Ptr& actor)
    {
        if (!ptr.getCellRef().isLocked())
            return true;

        const MWWorld::Class& actorClass = actor.getClass();
        if (!actorClass.isActor())
            return false;

        const ESM::RefId key = ptr.getCellRef().getKey();
        if (!key.empty() && actorClass.getContainerStore(actor).count(key) > 0)
        {
            unlock(ptr);
            const MWWorld::Ptr keyItem = actorClass.getContainerStore(actor).search(key);
            if (!keyItem.isEmpty() && !keyItem.getClass().getName(keyItem).empty())
                tell(actor, Misc::StringUtils::format("Opened with %s", keyItem.getClass().getName(keyItem)));
            return true;
        }

        if (actor != MWMechanics::getPlayer())
            return false;

        const int level = ptr.getCellRef().getLockLevel();
        if (requiresKey(level))
        {
            tell(actor, "This lock requires a key.");
            return false;
        }

        const int needed = std::abs(level);
        const float skill = actorClass.getSkill(actor, ESM::Skill::Security);
        if (skill < needed)
        {
            tell(actor,
                Misc::StringUtils::format("This lock is %s. You need a Lockpick skill of %d (yours is %d).",
                    levelName(needed), needed, static_cast<int>(skill)));
            return false;
        }

        if (bobbyPinId().empty() || actorClass.getContainerStore(actor).count(bobbyPinId()) <= 0)
        {
            tell(actor, "You don't have any bobby pins.");
            return false;
        }

        unlock(ptr);
        actorClass.skillUsageSucceeded(actor, ESM::Skill::Security, ESM::Skill::Security_PickLock);
        tell(actor, "Lock picked.");
        return true;
    }

    std::string describe(const MWWorld::ConstPtr& ptr)
    {
        if (!ptr.getCellRef().isLocked())
            return {};
        const int level = ptr.getCellRef().getLockLevel();
        if (requiresKey(level))
            return "Lock: Requires Key";
        return Misc::StringUtils::format("Lock: %s (%d)", levelName(level), std::abs(level));
    }
}
