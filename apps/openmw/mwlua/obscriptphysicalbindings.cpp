#include "obscriptphysicalbindings.hpp"

#include <string_view>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/lua/luastate.hpp>
#include <components/lua/serialization.hpp>
#include <components/lua/util.hpp>

#include "../mwmechanics/esm4physical.hpp"

#include "context.hpp"
#include "luaevents.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"

namespace MWLua
{
    namespace
    {
        namespace Physical = MWMechanics::ESM4Physical;

        std::string_view limbStateName(Physical::LimbState state)
        {
            switch (state)
            {
                case Physical::LimbState::Fine:
                    return "fine";
                case Physical::LimbState::Crippled:
                    return "crippled";
                case Physical::LimbState::Severed:
                    return "severed";
            }
            return "fine";
        }

        sol::table makeMobility(sol::state_view& lua, const Physical::Mobility& mobility)
        {
            sol::table t(lua, sol::create);
            t["speedMult"] = mobility.mSpeedMult;
            t["canRun"] = mobility.mCanRun;
            t["canStand"] = mobility.mCanStand;
            t["canAct"] = mobility.mCanAct;
            t["canAttack"] = mobility.mCanAttack;
            t["limping"] = mobility.mLimping;
            t["crippledLegs"] = mobility.mCrippledLegs;
            t["severedLegs"] = mobility.mSeveredLegs;
            t["leftArmUsable"] = mobility.mLeftArmUsable;
            t["rightArmUsable"] = mobility.mRightArmUsable;
            return t;
        }
    }

    sol::table initObScriptPhysicalBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Global event "FNVPhysical_Posture" { actor, previous, posture, knockState } whenever an actor's posture
        // changes (knocked down, getting up, standing again, dead), so the AI can drop its plan and re-plan after.
        Physical::setPostureListener(
            [context](const MWWorld::Ptr& actor, Physical::Posture previous, Physical::Posture posture) {
                context.mLua->protectedCall([&](LuaUtil::LuaView& view) {
                    sol::table data = view.newTable();
                    data["actor"] = GObject(actor);
                    data["previous"] = Physical::postureName(previous);
                    data["posture"] = Physical::postureName(posture);
                    data["knockState"] = Physical::getKnockState(posture);
                    context.mLuaEvents->addGlobalEvent(
                        { "FNVPhysical_Posture", LuaUtil::serialize(data, context.mSerializer) });
                });
            });

        // The posture names: standing, staggering, knockedDown, gettingUp, unconscious, dead
        sol::table postures(lua, sol::create);
        for (Physical::Posture posture : { Physical::Posture::Standing, Physical::Posture::Staggering,
                 Physical::Posture::KnockedDown, Physical::Posture::GettingUp, Physical::Posture::Unconscious,
                 Physical::Posture::Dead })
            postures[Physical::postureName(posture)] = Physical::postureName(posture);
        api["POSTURE"] = LuaUtil::makeReadOnly(postures);

        // { posture, knockState (the original's byte: 0 up, 1 unconscious, 2 down, 5 getting up), bleed, impulse
        // (direction x force of the last knockdown or killing blow), canAct, limbs (body part type -> "fine",
        // "crippled" or "severed", see combat.LIMB) }
        api["getState"] = [](const Object& actor, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            const Physical::State& state = Physical::getState(actor.ptr());
            sol::table t(lua, sol::create);
            t["posture"] = Physical::postureName(state.mPosture);
            t["knockState"] = Physical::getKnockState(state.mPosture);
            t["bleed"] = state.mBleed;
            t["impulse"] = state.mImpulse;
            t["canAct"] = Physical::canAct(actor.ptr());
            sol::table limbs(lua, sol::create);
            const auto states = Physical::getLimbStates(actor.ptr());
            for (std::size_t i = 0; i < states.size(); ++i)
                limbs[static_cast<int>(i)] = limbStateName(states[i]);
            t["limbs"] = limbs;
            return t;
        };
        api["getPosture"]
            = [](const Object& actor) -> std::string_view { return Physical::postureName(Physical::getPosture(actor.ptr())); };
        api["getKnockState"]
            = [](const Object& actor) -> int { return Physical::getKnockState(Physical::getPosture(actor.ptr())); };
        // Alive and on its feet: free to move, fight and idle
        api["canAct"] = [](const Object& actor) -> bool { return Physical::canAct(actor.ptr()); };
        api["getLimbState"] = [](const Object& actor, int limb) -> std::string_view {
            return limbStateName(Physical::getLimbState(actor.ptr(), limb));
        };
        // What the legs and arms leave the actor able to do: { speedMult, canRun, canStand, canAct, canAttack,
        // limping, crippledLegs, severedLegs, leftArmUsable, rightArmUsable }
        api["getMobility"] = [](const Object& actor, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            return makeMobility(lua, Physical::getMobility(actor.ptr()));
        };

        // Knocks the actor down (direction and force of the blow; unconscious keeps it down until wakeUp). It
        // gets up on its own.
        api["knockDown"] = [context](const Object& actor, sol::optional<osg::Vec3f> direction,
                               sol::optional<float> force, sol::optional<bool> unconscious) {
            context.mLuaManager->addAction(
                [actor = Object(actor), direction = direction.value_or(osg::Vec3f(0.f, 0.f, 1.f)),
                    force = force.value_or(35.f), unconscious = unconscious.value_or(false)] {
                    Physical::knockDown(actor.ptr(), direction, force, unconscious);
                },
                "obscriptPhysicalKnockDownAction");
        };
        api["stagger"] = [context](const Object& actor, sol::optional<float> seconds) {
            context.mLuaManager->addAction(
                [actor = Object(actor), seconds = seconds.value_or(0.5f)] { Physical::stagger(actor.ptr(), seconds); },
                "obscriptPhysicalStaggerAction");
        };
        api["wakeUp"] = [context](const Object& actor) {
            context.mLuaManager->addAction(
                [actor = Object(actor)] { Physical::wakeUp(actor.ptr()); }, "obscriptPhysicalWakeUpAction");
        };
        // Bleeding level (0 none); the opt-in bleed effects set it, the AI reads it.
        api["setBleed"] = [context](const Object& actor, float level) {
            context.mLuaManager->addAction(
                [actor = Object(actor), level] { Physical::setBleed(actor.ptr(), level); },
                "obscriptPhysicalSetBleedAction");
        };
        // The knockdown roll of a hit, as the engine makes it for weapon hits (for scripted damage).
        api["rollKnockdown"] = [](const Object& actor, float damage, float healthBefore, sol::optional<bool> killed) {
            return Physical::rollKnockdown(actor.ptr(), damage, healthBefore, killed.value_or(false));
        };

        return LuaUtil::makeReadOnly(api);
    }
}
