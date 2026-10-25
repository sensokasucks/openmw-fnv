#include "obscriptaibindings.hpp"

#include <cstdint>
#include <string>
#include <string_view>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/loadidle.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadpack.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>

#include "../mwbase/environment.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwmechanics/esm4actors.hpp"
#include "../mwworld/cell.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/store.hpp"

#include "context.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"
#include "obscriptdialoguebindings.hpp"

namespace MWLua
{
    namespace
    {
        std::string formIdText(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return {};
            return ESM::RefId(id).serializeText();
        }

        ESM::FormId parseFormId(std::string_view text)
        {
            ESM::RefId refId = ESM::RefId::deserializeText(text);
            if (const ESM::FormId* formId = refId.getIf<ESM::FormId>())
                return *formId;
            return {};
        }

        std::string_view typeName(std::int32_t type)
        {
            switch (type)
            {
                case ESM4::AIPackage::Type_Find:
                    return "Find";
                case ESM4::AIPackage::Type_Follow:
                    return "Follow";
                case ESM4::AIPackage::Type_Escort:
                    return "Escort";
                case ESM4::AIPackage::Type_Eat:
                    return "Eat";
                case ESM4::AIPackage::Type_Sleep:
                    return "Sleep";
                case ESM4::AIPackage::Type_Wander:
                    return "Wander";
                case ESM4::AIPackage::Type_Travel:
                    return "Travel";
                case ESM4::AIPackage::Type_Accompany:
                    return "Accompany";
                case ESM4::AIPackage::Type_UseItemAt:
                    return "UseItemAt";
                case ESM4::AIPackage::Type_Ambush:
                    return "Ambush";
                case ESM4::AIPackage::Type_FleeNotCombat:
                    return "FleeNotCombat";
                case ESM4::AIPackage::Type_CastMagic:
                    return "CastMagic";
                case ESM4::AIPackage::Type_Sandbox:
                    return "Sandbox";
                case ESM4::AIPackage::Type_Patrol:
                    return "Patrol";
                case ESM4::AIPackage::Type_Guard:
                    return "Guard";
                case ESM4::AIPackage::Type_Dialogue:
                    return "Dialogue";
                case ESM4::AIPackage::Type_UseWeapon:
                    return "UseWeapon";
            }
            return "Unknown";
        }

        sol::table makePackage(sol::state_view& lua, const ESM4::AIPackage& package)
        {
            sol::table res(lua, sol::create);
            res["id"] = formIdText(package.mId);
            res["editorId"] = package.mEditorId;
            res["type"] = package.mData.type;
            res["typeName"] = typeName(package.mData.type);
            res["flags"] = package.mData.flags;
            res["behaviourFlags"] = package.mBehaviourFlags;
            res["specificFlags"] = package.mSpecificFlags;

            // "Any" is -1 for month, day of week and hour, 0 for the date
            sol::table schedule(lua, sol::create);
            schedule["month"] = static_cast<std::int8_t>(package.mSchedule.month);
            schedule["dayOfWeek"] = static_cast<std::int8_t>(package.mSchedule.dayOfWeek);
            schedule["date"] = package.mSchedule.date;
            schedule["hour"] = static_cast<std::int8_t>(package.mSchedule.time);
            schedule["duration"] = static_cast<std::int32_t>(package.mSchedule.duration);
            res["schedule"] = schedule;

            sol::table locations(lua, sol::create);
            for (int i = 0; i < 2; ++i)
            {
                const ESM4::AIPackage::Location& location = package.mLocations[i];
                if (location.type == ESM4::AIPackage::Location_None)
                    continue;
                sol::table l(lua, sol::create);
                l["type"] = location.type;
                l["id"] = formIdText(location.location);
                l["objectType"] = location.objectType;
                l["radius"] = location.radius;
                locations[LuaUtil::toLuaIndex(i)] = l;
            }
            res["locations"] = locations;

            sol::table targets(lua, sol::create);
            for (int i = 0; i < 2; ++i)
            {
                const ESM4::AIPackage::Target& target = package.mTargets[i];
                if (target.type == 0xff)
                    continue;
                sol::table t(lua, sol::create);
                t["type"] = target.type;
                t["id"] = target.type == 2 ? std::string() : formIdText(target.target);
                t["objectType"] = target.type == 2 ? target.target.toUint32() : 0u;
                t["count"] = target.count;
                targets[LuaUtil::toLuaIndex(i)] = t;
            }
            res["targets"] = targets;

            res["conditions"] = makeObScriptConditions(lua, package.mFoConditions);

            // { idle, topic (form ids, empty for none), script (source text) }
            auto makeEvent = [&](const ESM4::AIPackage::Event& event) {
                sol::table e(lua, sol::create);
                e["idle"] = formIdText(event.mIdle);
                e["topic"] = formIdText(event.mTopic);
                e["script"] = event.mScript;
                return e;
            };
            res["onBegin"] = makeEvent(package.mOnBegin);
            res["onEnd"] = makeEvent(package.mOnEnd);
            res["onChange"] = makeEvent(package.mOnChange);

            sol::table dialogue(lua, sol::create);
            dialogue["fov"] = package.mDialogueFov;
            dialogue["topic"] = formIdText(package.mDialogueTopic);
            dialogue["flags"] = package.mDialogueFlags;
            dialogue["type"] = package.mDialogueType;
            res["dialogue"] = dialogue;
            return res;
        }

        std::string_view usePhaseName(MWMechanics::ESM4Actors::UsePhase phase)
        {
            switch (phase)
            {
                case MWMechanics::ESM4Actors::UsePhase::None:
                    return "none";
                case MWMechanics::ESM4Actors::UsePhase::Entering:
                    return "entering";
                case MWMechanics::ESM4Actors::UsePhase::Using:
                    return "using";
                case MWMechanics::ESM4Actors::UsePhase::Leaving:
                    return "leaving";
            }
            return "none";
        }

        std::string_view statusName(MWMechanics::ESM4Actors::Status status)
        {
            switch (status)
            {
                case MWMechanics::ESM4Actors::Status::None:
                    return "none";
                case MWMechanics::ESM4Actors::Status::Moving:
                    return "moving";
                case MWMechanics::ESM4Actors::Status::Arrived:
                    return "arrived";
                case MWMechanics::ESM4Actors::Status::NoPath:
                    return "nopath";
            }
            return "none";
        }

        std::optional<ESM::FormId> cellFormId(const MWWorld::Ptr& ptr)
        {
            if (ptr.getCell() == nullptr)
                return std::nullopt;
            if (const ESM::FormId* id = ptr.getCell()->getCell()->getId().getIf<ESM::FormId>())
                return *id;
            return std::nullopt;
        }
    }

    sol::table initObScriptAIBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Package record by form id.
        api["getPackage"] = [](std::string_view id, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const auto* package
                = MWBase::Environment::get().getESMStore()->get<ESM4::AIPackage>().search(parseFormId(id));
            if (package == nullptr)
                return sol::nil;
            return makePackage(lua, *package);
        };

        // Packages of an ESM4 NPC reference in priority order (highest first), templates resolved; nil for
        // anything else.
        api["getPackages"] = [](const Object& object, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM::REC_NPC_4)
                return sol::nil;
            const ESM4::Npc* npc = MWClass::ESM4Npc::getAIPackagesRecord(ptr);
            if (npc == nullptr)
                npc = ptr.get<ESM4::Npc>()->mBase;
            const MWWorld::Store<ESM4::AIPackage>& store
                = MWBase::Environment::get().getESMStore()->get<ESM4::AIPackage>();
            sol::table res(lua, sol::create);
            int index = 1;
            for (ESM::FormId id : npc->mAIPackages)
                if (const ESM4::AIPackage* package = store.search(id))
                    res[index++] = makePackage(lua, *package);
            return res;
        };

        // Whether the object's cell has a navmesh to walk on.
        api["hasNavMesh"] = [](const Object& object) -> bool {
            const std::optional<ESM::FormId> cell = cellFormId(object.ptr());
            return cell && MWMechanics::ESM4Actors::get().getNavigation().hasNavMesh(*cell);
        };

        // Random reachable navmesh point within radius of center, in the object's cell (nil without a navmesh).
        api["randomPoint"]
            = [](const Object& object, const osg::Vec3f& center, float radius) -> sol::optional<osg::Vec3f> {
            const std::optional<ESM::FormId> cell = cellFormId(object.ptr());
            if (!cell)
                return sol::nullopt;
            MWMechanics::ESM4Actors& actors = MWMechanics::ESM4Actors::get();
            std::optional<osg::Vec3f> point
                = actors.getNavigation().randomPoint(*cell, center, radius, actors.getRandom());
            if (!point)
                return sol::nullopt;
            return *point;
        };

        // Walks the NPC to the position along the navmesh. options: run (bool), tolerance (units), yaw (radians to
        // face on arrival), direct (go straight there when the navmesh has no route), straight (go straight there,
        // ignoring the navmesh). The move starts with the next frame; status() reports how it goes.
        api["moveTo"] = [context](const Object& object, const osg::Vec3f& target, sol::optional<sol::table> options) {
            MWMechanics::ESM4Actors::MoveOptions moveOptions;
            if (options)
            {
                moveOptions.mRun = options->get_or("run", false);
                moveOptions.mTolerance = options->get_or("tolerance", moveOptions.mTolerance);
                moveOptions.mDirect = options->get_or("direct", false);
                moveOptions.mStraight = options->get_or("straight", false);
                if (sol::optional<float> yaw = options->get<sol::optional<float>>("yaw"))
                    moveOptions.mFinalYaw = *yaw;
            }
            context.mLuaManager->addAction(
                [object = Object(object), target, moveOptions] {
                    MWMechanics::ESM4Actors::get().moveTo(object.ptr(), target, moveOptions);
                },
                "obscriptAIMoveToAction");
        };

        api["stop"] = [context](const Object& object) {
            context.mLuaManager->addAction(
                [object = Object(object)] { MWMechanics::ESM4Actors::get().stop(object.ptr()); },
                "obscriptAIStopAction");
        };

        // Turns in place to face yaw (radians).
        api["face"] = [context](const Object& object, float yaw) {
            context.mLuaManager->addAction(
                [object = Object(object), yaw] { MWMechanics::ESM4Actors::get().face(object.ptr(), yaw); },
                "obscriptAIFaceAction");
        };

        // Whether the object is in an active cell (onObjectActive has no counterpart for leaving the scene).
        api["isInScene"] = [](const Object& object) -> bool {
            const MWWorld::Ptr ptr = object.ptrOrEmpty();
            return !ptr.isEmpty() && ptr.getRefData().getBaseNode() != nullptr;
        };

        // "none", "moving", "arrived" or "nopath"
        api["status"] = [](const Object& object) -> std::string_view {
            return statusName(MWMechanics::ESM4Actors::get().getStatus(object.ptr()));
        };

        // All IDLE records, keyed by form id: { id, editorId, model (KF under meshes/, or the folder of a branch),
        // parent, previous (sibling), groupSection, loopMin, loopMax, replayDelay, flags, conditions }. The idle
        // tree is rebuilt from parent/previous in Lua (scripts/omw/fnvai/idles.lua).
        api["getIdles"] = [](sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            for (const ESM4::IdleAnimation& idle : MWBase::Environment::get().getESMStore()->get<ESM4::IdleAnimation>())
            {
                sol::table t(lua, sol::create);
                t["id"] = formIdText(idle.mId);
                t["editorId"] = idle.mEditorId;
                t["model"] = idle.mModel.getOriginal();
                t["parent"] = formIdText(idle.mParent);
                t["previous"] = formIdText(idle.mPrevious);
                t["groupSection"] = idle.mAnimGroupSection;
                t["loopMin"] = idle.mLoopMin;
                t["loopMax"] = idle.mLoopMax;
                t["replayDelay"] = idle.mReplayDelay;
                t["flags"] = idle.mIdleFlags;
                t["conditions"] = makeObScriptConditions(lua, idle.mConditions);
                res[formIdText(idle.mId)] = t;
            }
            return res;
        };

        // Sits down on, lies in or leans on furniture. options: position (world position of the furniture marker),
        // yaw (radians the actor faces there), offset (vector3: seat relative to the marker, x right, y forward),
        // headingDelta (radians turned once seated), enter/loop/exit (KF models under meshes/, as IDLE records
        // name them; enter and exit may be nil). useStatus() follows the entry, use and exit.
        api["useFurniture"] = [context](const Object& object, const sol::table& options) {
            MWMechanics::ESM4Actors::FurnitureUse use;
            use.mMarker = options.get<osg::Vec3f>("position");
            use.mHeading = options.get_or("yaw", 0.f);
            if (sol::optional<osg::Vec3f> offset = options.get<sol::optional<osg::Vec3f>>("offset"))
                use.mOffset = *offset;
            use.mHeadingDelta = options.get_or("headingDelta", 0.f);
            use.mEnter = options.get_or("enter", std::string());
            use.mLoop = options.get_or("loop", std::string());
            use.mExit = options.get_or("exit", std::string());
            context.mLuaManager->addAction(
                [object = Object(object), use] { MWMechanics::ESM4Actors::get().useFurniture(object.ptr(), use); },
                "obscriptAIUseFurnitureAction");
        };

        api["leaveFurniture"] = [context](const Object& object) {
            context.mLuaManager->addAction(
                [object = Object(object)] { MWMechanics::ESM4Actors::get().leaveFurniture(object.ptr()); },
                "obscriptAILeaveFurnitureAction");
        };

        // "none", "entering", "using" or "leaving"
        api["useStatus"] = [](const Object& object) -> std::string_view {
            return usePhaseName(MWMechanics::ESM4Actors::get().getUsePhase(object.ptr()));
        };

        // Plays an idle sequence (KF model under meshes/) once, standing or seated; the idle or seated loop
        // resumes after it. isIdlePlaying() tells when it is over.
        api["playIdle"] = [context](const Object& object, std::string model) {
            context.mLuaManager->addAction(
                [object = Object(object), model = std::move(model)] {
                    MWMechanics::ESM4Actors::get().playIdle(object.ptr(), model);
                },
                "obscriptAIPlayIdleAction");
        };

        api["isIdlePlaying"] = [](const Object& object) -> bool {
            return MWMechanics::ESM4Actors::get().isIdlePlaying(object.ptr());
        };

        return LuaUtil::makeReadOnly(api);
    }
}
