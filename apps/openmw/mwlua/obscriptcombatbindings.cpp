#include "obscriptcombatbindings.hpp"

#include <optional>
#include <string>
#include <string_view>
#include <tuple>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/loadammo.hpp>
#include <components/esm4/loadcell.hpp>
#include <components/esm4/loadclas.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadfact.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadflst.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/serialization.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwmechanics/esm4actors.hpp"
#include "../mwmechanics/esm4combat.hpp"
#include "../mwmechanics/esm4gore.hpp"
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
        namespace Gore = MWMechanics::ESM4Gore;

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

        const ESM4::Cell* cellRecordOf(const MWWorld::Ptr& ptr)
        {
            if (ptr.getCell() == nullptr)
                return nullptr;
            const ESM::FormId* id = ptr.getCell()->getCell()->getId().getIf<ESM::FormId>();
            if (id == nullptr)
                return nullptr;
            return MWBase::Environment::get().getESMStore()->get<ESM4::Cell>().search(ESM::RefId(*id));
        }

        bool isFactionForm(ESM::FormId id)
        {
            return MWBase::Environment::get().getESMStore()->get<ESM4::Faction>().search(ESM::RefId(id)) != nullptr;
        }

        // Global event "FNVCombat_Shot" { attacker, weapon (record id), target (nil on a miss), object (what stopped
        // a miss, if anything), damage, killed, position, direction, limb (body part hit, see LIMB) }
        void sendShot(const Context& context, const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon,
            const Combat::HitResult& hit)
        {
            context.mLua->protectedCall([&](LuaUtil::LuaView& view) {
                sol::table data = view.newTable();
                data["attacker"] = GObject(attacker);
                data["weapon"] = formIdText(weapon.mId);
                if (!hit.mTarget.isEmpty())
                    data["target"] = GObject(hit.mTarget);
                else if (!hit.mObject.isEmpty())
                    data["object"] = GObject(hit.mObject);
                data["damage"] = hit.mDamage;
                data["killed"] = hit.mKilled;
                data["position"] = hit.mPosition;
                data["direction"] = hit.mDirection;
                if (hit.mLimb >= 0)
                    data["limb"] = hit.mLimb;
                context.mLuaEvents->addGlobalEvent(
                    { "FNVCombat_Shot", LuaUtil::serialize(data, context.mSerializer) });
            });
        }

        // The ammunition a weapon takes: its NAM0 is an AMMO record or a form list of them.
        void addAmmoTypes(sol::state_view& lua, sol::table& list, ESM::FormId id, int depth)
        {
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            if (const ESM4::Ammunition* ammo = store.get<ESM4::Ammunition>().search(ESM::RefId(id)))
            {
                sol::table t(lua, sol::create);
                t["id"] = formIdText(ammo->mId);
                t["editorId"] = ammo->mEditorId;
                t["name"] = ammo->mFullName;
                t["shortName"] = ammo->mShortName;
                t["abbrev"] = ammo->mAbbrev;
                list[list.size() + 1] = t;
            }
            else if (const ESM4::FormIdList* formList = store.get<ESM4::FormIdList>().search(ESM::RefId(id)))
            {
                if (depth < 4)
                    for (ESM::FormId entry : formList->mObjects)
                        addAmmoTypes(lua, list, entry, depth + 1);
            }
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
            sol::table ammoTypes(lua, sol::create);
            if (!weapon.mAmmo.isZeroOrUnset())
                addAmmoTypes(lua, ammoTypes, weapon.mAmmo, 0);
            t["ammoTypes"] = ammoTypes; // { { id, editorId, name, shortName, abbrev }, ... }
            t["fireSound"] = formIdText(weapon.mFireSound);
            t["fireSound2D"] = formIdText(weapon.mFireSound2D);
            t["dryFireSound"] = formIdText(weapon.mDryFireSound);
            if (weapon.mHasFO3Data)
            {
                const ESM4::Weapon::DataFO3& d = weapon.mFO3Data;
                t["animType"] = d.animType;
                t["reach"] = d.reach;
                t["animMult"] = d.animMult;
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

        // Aggro radius of a creature (AIDT): { radius = units, enabled = bool }; nil for anything else. Aggression,
        // confidence and assistance are actor values (core.obscript.stats).
        api["getAggroRadius"] = [](const Object& object, sol::this_state s) -> sol::object {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM::REC_CREA4)
                return sol::nil;
            const ESM4::Creature* rec = MWClass::ESM4Creature::getAIDataRecord(ptr);
            if (rec == nullptr || !rec->mHasFO3AIData)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["radius"] = rec->mFO3AIData.aggroRadius;
            t["enabled"] = rec->mFO3AIData.aggroRadiusBehavior;
            return t;
        };

        // How the actor's factions treat the player: "enemy", "neutral", "ally" or "friend".
        api["getReaction"] = [](const Object& actor) -> std::string_view {
            switch (Combat::getReactionToPlayer(actor.ptr()))
            {
                case Combat::Reaction::Enemy:
                    return "enemy";
                case Combat::Reaction::Ally:
                    return "ally";
                case Combat::Reaction::Friend:
                    return "friend";
                default:
                    return "neutral";
            }
        };

        // Crime (FalloutNV.exe 0x567790, 0x546da0): ownership, factions and guards.

        // Factions of an NPC or creature record (template-resolved): { { id, rank }, ... }.
        api["getFactions"] = [](const Object& actor, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Ptr& ptr = actor.ptr();
            const std::vector<ESM4::ActorFaction>* factions = nullptr;
            if (ptr.getType() == ESM::REC_NPC_4)
            {
                if (const ESM4::Npc* rec = MWClass::ESM4Npc::getFactionsRecord(ptr))
                    factions = &rec->mFactions;
            }
            else if (ptr.getType() == ESM::REC_CREA4)
            {
                if (const ESM4::Creature* rec = MWClass::ESM4Creature::getFactionsRecord(ptr))
                    factions = &rec->mFactions;
            }
            if (factions == nullptr)
                return res;
            for (const ESM4::ActorFaction& membership : *factions)
            {
                sol::table t(lua, sol::create);
                t["id"] = formIdText(ESM::FormId::fromUint32(membership.faction));
                t["rank"] = membership.rank;
                res[res.size() + 1] = t;
            }
            return res;
        };

        // A faction (FACT) by form id: { id, editorId, name, evil (DATA 0x02), trackCrime (0x100), reputation (WMI1) },
        // nil if none.
        api["getFaction"] = [](std::string_view id, sol::this_state s) -> sol::object {
            const ESM::RefId refId = ESM::RefId::deserializeText(id);
            const ESM::FormId* formId = refId.getIf<ESM::FormId>();
            if (formId == nullptr)
                return sol::nil;
            const ESM4::Faction* faction
                = MWBase::Environment::get().getESMStore()->get<ESM4::Faction>().search(ESM::RefId(*formId));
            if (faction == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["id"] = formIdText(faction->mId);
            t["editorId"] = faction->mEditorId;
            t["name"] = faction->mFullName;
            t["evil"] = (faction->mFactionFlags & 0x02) != 0;
            t["trackCrime"] = (faction->mFactionFlags & 0x100) != 0;
            if (!faction->mReputation.isZeroOrUnset())
                t["reputation"] = formIdText(faction->mReputation);
            return t;
        };

        // Guards: the class (CLAS) flag 0x02.
        api["isGuard"] = [](const Object& actor) -> bool {
            const MWWorld::Ptr& ptr = actor.ptr();
            if (ptr.getType() != ESM::REC_NPC_4)
                return false;
            const ESM4::Npc* traits = MWClass::ESM4Npc::getTraitsRecord(ptr);
            if (traits == nullptr)
                traits = ptr.get<ESM4::Npc>()->mBase;
            const ESM4::Class* cls
                = MWBase::Environment::get().getESMStore()->get<ESM4::Class>().search(ESM::RefId(traits->mClass));
            return cls != nullptr && (cls->mClassFlags & 0x02) != 0;
        };

        // Ownership of the cell an object is in: { owner, isFaction, global, rank (XRNK), public (CELL 0x20) };
        // owner is nil when nobody owns it.
        api["cellOwnership"] = [](const Object& object, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            const ESM4::Cell* cell = cellRecordOf(object.ptr());
            t["public"] = cell != nullptr && (cell->mCellFlags & ESM4::CELL_Public) != 0;
            if (cell != nullptr && !cell->mOwner.isZeroOrUnset())
            {
                t["owner"] = formIdText(cell->mOwner);
                t["isFaction"] = isFactionForm(cell->mOwner);
                if (!cell->mGlobal.isZeroOrUnset())
                    t["global"] = formIdText(cell->mGlobal);
                t["rank"] = cell->mFactionRank;
            }
            return t;
        };

        // Who owns an object (FalloutNV.exe 0x567790): its own XOWN, else, unless it is a door or an activator,
        // its cell's owner. { owner, isFaction, global, rank } or nil when nobody does. Items in a container are
        // asked with the container as `holder`.
        api["ownership"] = [](const Object& object, sol::optional<Object> holder, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const MWWorld::Ptr& ptr = object.ptr();
            auto own = [&](const MWWorld::Ptr& p) -> sol::object {
                const ESM::RefId owner = p.getCellRef().getOwner();
                const ESM::FormId* formId = owner.getIf<ESM::FormId>();
                if (formId == nullptr || formId->isZeroOrUnset())
                    return sol::nil;
                sol::table t(lua, sol::create);
                t["owner"] = formIdText(*formId);
                t["isFaction"] = isFactionForm(*formId);
                const ESM::FormId global = p.getCellRef().getOwnerGlobal();
                if (!global.isZeroOrUnset())
                    t["global"] = formIdText(global);
                t["rank"] = -1;
                return t;
            };
            sol::object res = own(ptr);
            if (res != sol::nil)
                return res;
            MWWorld::Ptr placed = ptr;
            if (holder)
            {
                placed = holder->ptr();
                res = own(placed);
                if (res != sol::nil)
                    return res;
            }
            const unsigned int type = placed.getType();
            if (type == ESM::REC_DOOR4 || type == ESM::REC_ACTI4 || type == ESM::REC_NPC_4 || type == ESM::REC_CREA4)
                return sol::nil;
            const ESM4::Cell* cell = cellRecordOf(placed);
            if (cell == nullptr || cell->mOwner.isZeroOrUnset())
                return sol::nil;
            sol::table t(lua, sol::create);
            t["owner"] = formIdText(cell->mOwner);
            t["isFaction"] = isFactionForm(cell->mOwner);
            if (!cell->mGlobal.isZeroOrUnset())
                t["global"] = formIdText(cell->mGlobal);
            t["rank"] = cell->mFactionRank;
            return t;
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
                    sendShot(context, attackerPtr, *weapon, hit);
                },
                "obscriptCombatFireAction");
        };

        // Unarmed or creature attack on the target: plays one of the attacker's attack sequences; the blow lands
        // partway through if the target is still within reach (units).
        api["attack"] = [context](const Object& attacker, const Object& target, sol::optional<float> reach) {
            context.mLuaManager->addAction(
                [attacker = Object(attacker), target = Object(target), reach = reach.value_or(150.f)] {
                    Combat::attack(attacker.ptr(), target.ptr(), reach);
                },
                "obscriptCombatAttackAction");
        };
        // Whether an attack (or another one-off sequence) is playing.
        api["isActing"]
            = [](const Object& actor) { return MWMechanics::ESM4Actors::get().isActing(actor.ptr()); };
        api["getUnarmedDamage"] = [](const Object& actor) { return Combat::getUnarmedDamage(actor.ptr()); };

        // The weapon an NPC fights with (a gun if it has one), as getWeapon returns it; nil if it has none.
        api["getActorWeapon"] = [](const Object& actor, sol::this_state s) -> sol::object {
            const ESM4::Weapon* weapon = Combat::getActorWeapon(actor.ptr());
            if (weapon == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t = makeWeapon(lua, *weapon);
            t["isGun"] = Combat::isGun(*weapon);
            t["type"] = Combat::getWeaponType(*weapon);
            return t;
        };

        // Every weapon the NPC carries: weapon tables as getWeapon, plus isGun and the combat planner's type
        // (0 explosive, 1 ranged, 2 melee, 3 grenade, 4 mine, 6 hand to hand).
        api["getActorWeapons"] = [](const Object& actor, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            for (const ESM4::Weapon* weapon : Combat::getActorWeapons(actor.ptr()))
            {
                sol::table t = makeWeapon(lua, *weapon);
                t["isGun"] = Combat::isGun(*weapon);
                t["type"] = Combat::getWeaponType(*weapon);
                res[res.size() + 1] = t;
            }
            return res;
        };

        // Puts one of the NPC's weapons (record id) in its hands, holstered; drawWeapon shows it.
        api["equipWeapon"] = [context](const Object& actor, std::string_view weaponId) {
            const ESM4::Weapon* weapon = findWeapon(weaponId);
            if (weapon == nullptr)
                return;
            context.mLuaManager->addAction(
                [actor = Object(actor), weapon] { Combat::equipWeapon(actor.ptr(), weapon); },
                "obscriptCombatEquipWeaponAction");
        };

        // Shows the NPC's weapon in its hand and aims it (true), or puts it away.
        api["drawWeapon"] = [context](const Object& actor, bool drawn) {
            context.mLuaManager->addAction(
                [actor = Object(actor), drawn] { Combat::drawWeapon(actor.ptr(), drawn); },
                "obscriptCombatDrawWeaponAction");
        };

        // The NPC fires its gun at the target (attack sequence, sound, one shot with skill-based aim error).
        // Global scripts then receive "FNVCombat_Shot" as for fire.
        api["shoot"] = [context](const Object& actor, const Object& target) {
            context.mLuaManager->addAction(
                [context, actor = Object(actor), target = Object(target)] {
                    Combat::HitResult hit;
                    if (Combat::shoot(actor.ptr(), target.ptr(), hit))
                        sendShot(context, actor.ptr(), *Combat::getActorWeapon(actor.ptr()), hit);
                },
                "obscriptCombatShootAction");
        };

        // Whether nothing solid stands between the actor's eyes and the target's upper body.
        api["hasLineOfFire"] = [](const Object& actor, const Object& target) {
            return Combat::hasLineOfFire(actor.ptr(), target.ptr());
        };

        // Plays the NPC's reload sequence.
        // Whether the actor (the player too) is sneaking.
        api["isSneaking"] = [](const Object& actor) -> bool {
            const MWWorld::Ptr ptr = actor.ptrOrEmpty();
            if (ptr.isEmpty() || !ptr.getClass().isActor() || ptr.getType() == ESM::REC_NPC_4
                || ptr.getType() == ESM::REC_CREA4)
                return false;
            return ptr.getClass().getCreatureStats(ptr).getStance(MWMechanics::CreatureStats::Stance_Sneak);
        };
        // detect(observer, target, { sleeping, inCombat, alert }): the detection score (CalcDetectionScore) and
        // whether the observer has a line of sight to the target.
        api["detect"] = [](const Object& observer, const Object& target, sol::optional<sol::table> options)
            -> std::tuple<float, bool> {
            Combat::DetectionContext context;
            if (options)
            {
                context.mSleeping = options->get_or("sleeping", false);
                context.mInCombat = options->get_or("inCombat", false);
                context.mAlert = options->get_or("alert", false);
            }
            const Combat::Detection detection = Combat::detect(observer.ptr(), target.ptr(), context);
            return { detection.mScore, detection.mLineOfSight };
        };

        api["reload"] = [context](const Object& actor) {
            context.mLuaManager->addAction(
                [actor = Object(actor)] { Combat::reload(actor.ptr()); }, "obscriptCombatReloadAction");
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

        // FO3/FONV limbs (body part types of BPTD, ESM4::BodyPartData::PartType)
        sol::table limbs(lua, sol::create);
        static constexpr std::string_view limbNames[] = { "Torso", "Head1", "Head2", "LeftArm1", "LeftArm2",
            "RightArm1", "RightArm2", "LeftLeg1", "LeftLeg2", "LeftLeg3", "RightLeg1", "RightLeg2", "RightLeg3",
            "Brain", "Weapon" };
        for (std::size_t i = 0; i < std::size(limbNames); ++i)
            limbs[limbNames[i]] = static_cast<int>(i);
        api["LIMB"] = LuaUtil::makeReadOnly(limbs);

        // What the blow that killed the actor tears off, as FalloutNV.exe decides it: a list of { limb, explode }.
        // blow: { limb (the limb hit), weapon (record id, its "On Hit" setting counts), bloodyMess (the killer has
        // the perk), seed (integer: the same seed gives the same result) }.
        api["rollDismemberment"] = [](const Object& actor, sol::table blow, sol::this_state s) {
            Gore::KillingBlow killingBlow;
            killingBlow.mLimb = blow.get_or("limb", -1);
            killingBlow.mBloodyMess = blow.get_or("bloodyMess", false);
            killingBlow.mSeed = static_cast<std::uint32_t>(blow.get_or<double>("seed", 0));
            if (sol::optional<std::string_view> weapon = blow.get<sol::optional<std::string_view>>("weapon"))
                killingBlow.mWeapon = findWeapon(*weapon);
            sol::state_view lua(s);
            sol::table result(lua, sol::create);
            for (const Gore::Dismemberment& d : Gore::rollDismemberment(actor.ptr(), killingBlow))
            {
                sol::table entry(lua, sol::create);
                entry["limb"] = d.mLimb;
                entry["explode"] = d.mExplode;
                result.add(entry);
            }
            return result;
        };

        // Severs (or explodes) the actor's limb with its gore; direction (optional) pushes the pieces away and the
        // seed picks how they fly. Global scripts call it through I.FNVGore.dismember, which saves it.
        api["dismember"] = [context](const Object& actor, int limb, bool explode, sol::optional<osg::Vec3f> direction,
                               sol::optional<double> seed) {
            context.mLuaManager->addAction(
                [actor = Object(actor), limb, explode, direction = direction.value_or(osg::Vec3f()),
                    seed = static_cast<std::uint32_t>(seed.value_or(0))] {
                    Gore::dismember(actor.ptr(), limb, explode, direction, seed);
                },
                "obscriptCombatDismemberAction");
        };

        // Limbs the actor has lost and the ones of them that exploded, as bit masks (1 << limb).
        api["getLostLimbs"] = [](const Object& actor) {
            return std::make_tuple(Gore::getLostLimbs(actor.ptr()), Gore::getExplodedLimbs(actor.ptr()));
        };
        // Restores lost limbs from a saved game: the body shows without them, nothing flies.
        api["setLostLimbs"] = [context](const Object& actor, std::uint32_t lost, sol::optional<std::uint32_t> exploded) {
            context.mLuaManager->addAction(
                [actor = Object(actor), lost, exploded = exploded.value_or(0)] {
                    Gore::setLostLimbs(actor.ptr(), lost, exploded);
                },
                "obscriptCombatSetLostLimbsAction");
        };

        return LuaUtil::makeReadOnly(api);
    }
}
