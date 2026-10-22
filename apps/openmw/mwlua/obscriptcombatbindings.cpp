#include "obscriptcombatbindings.hpp"

#include <optional>
#include <string>
#include <string_view>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/serialization.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/esm4combat.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/store.hpp"

#include "context.hpp"
#include "luaevents.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"

namespace MWLua
{
    namespace
    {
        namespace Combat = MWMechanics::ESM4Combat;

        // By record id ("FormId:0x7ea24") or editor id ("WeapNVVarmintRifle")
        const ESM4::Weapon* findWeapon(std::string_view id)
        {
            const MWWorld::Store<ESM4::Weapon>& store = MWBase::Environment::get().getESMStore()->get<ESM4::Weapon>();
            if (const ESM4::Weapon* weapon = store.search(ESM::RefId::deserializeText(id)))
                return weapon;
            for (const ESM4::Weapon& weapon : store)
                if (Misc::StringUtils::ciEqual(weapon.mEditorId, id))
                    return &weapon;
            return nullptr;
        }

        std::string formIdText(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return {};
            return ESM::RefId(id).serializeText();
        }

        sol::table makeWeapon(sol::state_view& lua, const ESM4::Weapon& weapon)
        {
            sol::table t(lua, sol::create);
            t["id"] = formIdText(weapon.mId);
            t["editorId"] = weapon.mEditorId;
            t["name"] = weapon.mFullName;
            t["damage"] = weapon.mData.damage;
            t["clipSize"] = weapon.mData.clipSize;
            t["health"] = weapon.mData.health;
            t["ammo"] = formIdText(weapon.mAmmo);
            t["fireSound"] = formIdText(weapon.mFireSound);
            t["fireSound2D"] = formIdText(weapon.mFireSound2D);
            t["dryFireSound"] = formIdText(weapon.mDryFireSound);
            if (weapon.mHasFO3Data)
            {
                const ESM4::Weapon::DataFO3& d = weapon.mFO3Data;
                t["animType"] = d.animType;
                t["automatic"] = (d.flags1 & ESM4::Weapon::FO3_Automatic) != 0;
                t["ammoUse"] = d.ammoUse;
                t["projectiles"] = d.projectileCount;
                t["shotsPerSecond"] = d.shotsPerSecond;
                t["fireRate"] = d.fireRate;
                t["reloadTime"] = d.reloadTime;
                t["minSpread"] = d.minSpread;
                t["spread"] = d.spread;
                t["skill"] = d.skill;
                t["minRange"] = d.minRange;
                t["maxRange"] = d.maxRange;
            }
            return t;
        }
    }

    sol::table initObScriptCombatBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Weapon record (WEAP) by record id or editor id, nil if there is none.
        api["getWeapon"] = [](std::string_view id, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const ESM4::Weapon* weapon = findWeapon(id);
            if (weapon == nullptr)
                return sol::nil;
            return makeWeapon(lua, *weapon);
        };

        // Name shown for the object (follows creature and NPC templates)
        api["getName"] = [](const Object& object) {
            const MWWorld::Ptr& ptr = object.ptr();
            return std::string(ptr.getClass().getName(ptr));
        };

        api["canBeHit"] = [](const Object& actor) { return Combat::canBeHit(actor.ptr()); };
        api["isDead"] = [](const Object& actor) { return Combat::isDead(actor.ptr()); };

        // Damage one projectile of the weapon would do for the attacker, before armor.
        api["getWeaponDamage"] = [](const Object& attacker, std::string_view weaponId) -> float {
            const ESM4::Weapon* weapon = findWeapon(weaponId);
            return weapon ? Combat::getWeaponDamage(attacker.ptr(), *weapon) : 0.f;
        };

        // Changing the world is for global scripts (scripts/omw/fnvcombat); the player script sends them events.

        // Fires one shot of the weapon from origin along direction, with its sound. The shot is resolved with the
        // next frame; global scripts then receive the event "FNVCombat_Shot" with
        // { attacker, weapon (record id), target (nil on a miss), damage, killed, position }.
        api["fire"] = [context](const Object& attacker, std::string_view weaponId, const osg::Vec3f& origin,
                          const osg::Vec3f& direction) {
            const ESM4::Weapon* weapon = findWeapon(weaponId);
            if (weapon == nullptr)
                throw std::runtime_error("Unknown weapon " + std::string(weaponId));
            context.mLuaManager->addAction(
                [context, attacker = Object(attacker), weapon, origin, direction] {
                    const MWWorld::Ptr attackerPtr = attacker.ptr();
                    MWBase::SoundManager* sounds = MWBase::Environment::get().getSoundManager();
                    const bool player = attackerPtr == MWMechanics::getPlayer();
                    const ESM::FormId sound
                        = player && !weapon->mFireSound2D.isZeroOrUnset() ? weapon->mFireSound2D : weapon->mFireSound;
                    if (!sound.isZeroOrUnset())
                    {
                        if (player)
                            sounds->playSound(ESM::RefId(sound), 1.f, 1.f);
                        else
                            sounds->playSound3D(attackerPtr, ESM::RefId(sound), 1.f, 1.f);
                    }

                    const Combat::HitResult hit = Combat::fire(attackerPtr, *weapon, origin, direction);
                    context.mLua->protectedCall([&](LuaUtil::LuaView& view) {
                        sol::table data = view.newTable();
                        data["attacker"] = GObject(attackerPtr);
                        data["weapon"] = formIdText(weapon->mId);
                        if (!hit.mTarget.isEmpty())
                            data["target"] = GObject(hit.mTarget);
                        data["damage"] = hit.mDamage;
                        data["killed"] = hit.mKilled;
                        data["position"] = hit.mPosition;
                        context.mLuaEvents->addGlobalEvent(
                            { "FNVCombat_Shot", LuaUtil::serialize(data, context.mSerializer) });
                    });
                },
                "obscriptCombatFireAction");
        };

        // Damages the target's health directly (melee hits, scripted damage); kills it when health runs out.
        api["hit"] = [context](const Object& target, sol::optional<Object> attacker, float damage) {
            context.mLuaManager->addAction(
                [target = Object(target), attacker = attacker ? std::optional<Object>(*attacker) : std::nullopt, damage] {
                    const MWWorld::Ptr attackerPtr = attacker ? attacker->ptrOrEmpty() : MWWorld::Ptr();
                    Combat::hit(target.ptr(), attackerPtr, Combat::applyArmor(target.ptr(), damage));
                },
                "obscriptCombatHitAction");
        };

        return LuaUtil::makeReadOnly(api);
    }
}
