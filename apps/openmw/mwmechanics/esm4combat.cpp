#include "esm4combat.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <optional>
#include <random>
#include <set>
#include <sstream>
#include <string>

#include <osg/ComputeBoundsVisitor>
#include <osg/MatrixTransform>

#include <components/sceneutil/positionattitudetransform.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadexpl.hpp>
#include <components/esm4/loadfact.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadproj.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/lightmanager.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwrender/renderingmanager.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/scene.hpp"
#include "../mwworld/worldmodel.hpp"

#include "actorutil.hpp"
#include "creaturestats.hpp"
#include "esm4actors.hpp"
#include "esm4gore.hpp"
#include "esm4physical.hpp"
#include "esm4navigation.hpp"
#include "movement.hpp"

namespace MWMechanics::ESM4Combat
{
    namespace
    {
        namespace Stats = MWClass::ESM4Stats;

        float gmst(std::string_view name)
        {
            return MWWorld::ESM4GameSettings::getFloat(name);
        }

        // How far a bullet flies. The original engine moves projectiles; at gun ranges they are effectively instant.
        constexpr float sShotRange = 16384.f;

        // Weapon skill by DNAM animation type, for weapons without one
        int skillForAnimType(std::uint32_t animType)
        {
            switch (animType)
            {
                case 0:
                    return Stats::Unarmed;
                case 1:
                case 2:
                    return Stats::MeleeWeapons;
                case 4:
                case 7:
                    return Stats::EnergyWeapons;
                case 9:
                    return Stats::Explosives;
                case 10:
                case 11:
                case 12:
                    return Stats::Explosives;
                case 13:
                    return Stats::Survival;
                default:
                    return Stats::Guns;
            }
        }

        // Damage multiplier of a worn-out weapon (FUN_00646d00): full above 75% condition.
        float conditionMultiplier(float condition)
        {
            if (condition > 0.75f)
                return 1.f;
            return 1.f - (0.75f - condition) * 0.67f;
        }

        MWRender::ESM4NpcAnimation* getAnimation(const MWWorld::Ptr& ptr)
        {
            return dynamic_cast<MWRender::ESM4NpcAnimation*>(MWBase::Environment::get().getWorld()->getAnimation(ptr));
        }

        // Distance along the ray to where it enters the box, if it does within maxDistance.
        std::optional<float> intersect(
            const osg::BoundingBox& box, const osg::Vec3f& origin, const osg::Vec3f& direction, float maxDistance)
        {
            float tMin = 0.f;
            float tMax = maxDistance;
            for (int axis = 0; axis < 3; ++axis)
            {
                if (std::abs(direction[axis]) < 1e-6f)
                {
                    if (origin[axis] < box._min[axis] || origin[axis] > box._max[axis])
                        return std::nullopt;
                    continue;
                }
                float t1 = (box._min[axis] - origin[axis]) / direction[axis];
                float t2 = (box._max[axis] - origin[axis]) / direction[axis];
                if (t1 > t2)
                    std::swap(t1, t2);
                tMin = std::max(tMin, t1);
                tMax = std::min(tMax, t2);
                if (tMin > tMax)
                    return std::nullopt;
            }
            return tMin;
        }

        struct PendingHit
        {
            ESM::RefNum mAttacker;
            ESM::RefNum mTarget;
            float mTime; // until the blow lands
            float mReach;
            const ESM4::Weapon* mWeapon = nullptr; // melee weapon swung; unarmed when null
        };
        std::vector<PendingHit> sPendingHits;
        BlowListener sBlowListener;

        // A grenade or launcher shell in flight (or lying, waiting for its timer)
        struct FlyingProjectile
        {
            ESM::RefNum mAttacker;
            const ESM4::Weapon* mWeapon;
            const ESM4::Projectile* mProjectile;
            osg::ref_ptr<osg::MatrixTransform> mNode;
            osg::Vec3f mPosition;
            osg::Vec3f mVelocity;
            float mAge = 0.f;
            float mTravelled = 0.f;
            bool mResting = false;
            int mBounces = 0;
        };
        std::vector<FlyingProjectile> sProjectiles;

        // Actors crouched behind cover
        std::set<ESM::RefNum> sCrouched;
        std::set<ESM::RefNum> sBlocking; // actors holding their weapon up (BlockIdle)

        // Havok gravity, 9.81 m/s^2 at 69.99 units a metre [inferred: PROJ gravity is a multiple of it]
        constexpr float sGravity = 686.6f;

        std::mt19937& random()
        {
            static std::mt19937 generator{ std::random_device{}() };
            return generator;
        }

        // The player is a Morrowind actor: blows take its Morrowind health, so that death works as usual. The damage
        // is scaled from the player's FNV health to the Morrowind one, so fights last as long as in FNV.
        void hurtPlayer(const MWWorld::Ptr& player, float damage)
        {
            if (MWBase::Environment::get().getWorld()->getGodModeState())
                return; // tgm
            MWMechanics::CreatureStats& stats = player.getClass().getCreatureStats(player);
            MWMechanics::DynamicStat<float> health = stats.getHealth();
            const float fnvHealth = Stats::getPermanent(player, Stats::Health);
            const float scale = fnvHealth > 0.f ? health.getModified() / fnvHealth : 1.f;
            health.setCurrent(health.getCurrent() - damage * scale);
            Log(Debug::Verbose) << "ESM4 hit player for " << damage << " FNV damage (" << damage * scale
                                << " health), health " << health.getCurrent();
            stats.setHealth(health);
            Stats::damage(player, Stats::Health, damage);
            MWBase::Environment::get().getWindowManager()->activateHitOverlay();
        }

        template <class Record>
        void collectTargets(MWWorld::CellStore& cell, std::vector<MWWorld::Ptr>& out)
        {
            cell.forEachType<Record>([&](const MWWorld::Ptr& ptr) {
                if (ptr.getRefData().isEnabled() && ptr.getRefData().getBaseNode() != nullptr)
                    out.push_back(ptr);
                return true;
            });
        }
    }

    namespace
    {
        const std::vector<ESM4::ActorFaction>* factionsOf(const MWWorld::Ptr& actor)
        {
            if (actor.getType() == ESM::REC_NPC_4)
            {
                const ESM4::Npc* rec = MWClass::ESM4Npc::getFactionsRecord(actor);
                return rec ? &rec->mFactions : nullptr;
            }
            if (actor.getType() == ESM::REC_CREA4)
            {
                const ESM4::Creature* rec = MWClass::ESM4Creature::getFactionsRecord(actor);
                return rec ? &rec->mFactions : nullptr;
            }
            return nullptr;
        }

        // FNV's PlayerFaction, found by editor id since form ids depend on load order
        const ESM4::Faction* playerFaction()
        {
            static const MWWorld::ESMStore* cachedStore = nullptr;
            static const ESM4::Faction* cached = nullptr;
            const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();
            if (store != cachedStore)
            {
                cachedStore = store;
                cached = nullptr;
                for (const ESM4::Faction& faction : store->get<ESM4::Faction>())
                    if (Misc::StringUtils::ciEqual(faction.mEditorId, "PlayerFaction"))
                    {
                        cached = &faction;
                        break;
                    }
            }
            return cached;
        }

        std::optional<std::uint32_t> findReaction(const ESM4::Faction& from, ESM::FormId to)
        {
            for (const ESM4::Faction::Relation& relation : from.mRelations)
                if (relation.mFaction == to)
                    return relation.mReaction;
            return std::nullopt;
        }
    }

    Reaction getReactionToPlayer(const MWWorld::Ptr& actor)
    {
        const std::vector<ESM4::ActorFaction>* factions = factionsOf(actor);
        const ESM4::Faction* player = playerFaction();
        if (factions == nullptr || player == nullptr)
            return Reaction::Neutral;
        const MWWorld::Store<ESM4::Faction>& store = MWBase::Environment::get().getESMStore()->get<ESM4::Faction>();
        bool ally = false;
        bool friendly = false;
        for (const ESM4::ActorFaction& membership : *factions)
        {
            const ESM::FormId id = ESM::FormId::fromUint32(membership.faction);
            if (id == player->mId)
                return Reaction::Friend; // followers
            std::optional<std::uint32_t> reactions[2] = { findReaction(*player, id), std::nullopt };
            if (const ESM4::Faction* faction = store.search(id))
                reactions[1] = findReaction(*faction, player->mId);
            for (const std::optional<std::uint32_t>& reaction : reactions)
            {
                if (!reaction)
                    continue;
                if (*reaction == ESM4::Faction::Reaction_Enemy)
                    return Reaction::Enemy;
                ally = ally || *reaction == ESM4::Faction::Reaction_Ally;
                friendly = friendly || *reaction == ESM4::Faction::Reaction_Friend;
            }
        }
        if (ally)
            return Reaction::Ally;
        return friendly ? Reaction::Friend : Reaction::Neutral;
    }

    bool canBeHit(const MWWorld::Ptr& actor)
    {
        return Stats::hasActorValues(actor);
    }

    bool isDead(const MWWorld::Ptr& actor)
    {
        if (!canBeHit(actor) || actor == getPlayer())
            return false;
        // Records without health (e.g. creatures missing DATA) are never "dead"
        return Stats::getPermanent(actor, Stats::Health) > 0 && Stats::getCurrent(actor, Stats::Health) <= 0;
    }

    bool ensureStartsDead(const MWWorld::Ptr& actor)
    {
        if (!canBeHit(actor) || actor == getPlayer())
            return false;
        if (isDead(actor))
            return true;
        if (!actor.getCellRef().startsDead() || Stats::getPermanent(actor, Stats::Health) <= 0.f)
            return false;
        Stats::damage(actor, Stats::Health, Stats::getCurrent(actor, Stats::Health));
        ESM4Actors::get().stop(actor, true);
        cancelAttacks(actor);
        MWBase::Environment::get().getWorld()->enableActorCollision(actor, false);
        ESM4Physical::setDead(actor, osg::Vec3f(), std::nullopt, true);
        Log(Debug::Verbose) << "ESM4 placed corpse " << actor.getCellRef().getRefId() << " ref "
                            << actor.getCellRef().getRefNum().toString();
        return true;
    }

    namespace
    {
        // fDamageSkillBase + fDamageSkillMult x the attacker's skill with the weapon
        float skillFactor(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon)
        {
            int skill = weapon.mHasFO3Data ? weapon.mFO3Data.skill : -1;
            if (skill < 0 || skill >= Stats::Count)
                skill = skillForAnimType(weapon.mHasFO3Data ? weapon.mFO3Data.animType : 3);
            const float skillValue = canBeHit(attacker) ? Stats::getCurrent(attacker, skill) : 100.f;
            return gmst("fDamageSkillBase") + gmst("fDamageSkillMult") * std::clamp(skillValue, 0.f, 100.f) / 100.f;
        }
    }

    float getWeaponDamage(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, float condition)
    {
        const float base = weapon.mData.damage;
        int skill = weapon.mHasFO3Data ? weapon.mFO3Data.skill : -1;
        if (skill < 0 || skill >= Stats::Count)
            skill = skillForAnimType(weapon.mHasFO3Data ? weapon.mFO3Data.animType : 3);
        const float skillValue = canBeHit(attacker) ? Stats::getCurrent(attacker, skill) : 100.f;
        const float skillFactor
            = gmst("fDamageSkillBase") + gmst("fDamageSkillMult") * std::clamp(skillValue, 0.f, 100.f) / 100.f;
        return base * skillFactor * conditionMultiplier(condition);
    }

    float applyArmor(const MWWorld::Ptr& target, float damage)
    {
        if (damage <= 0.f)
            return 0.f;
        const float minimum = damage * gmst("fMinDamMultiplier");
        const float resistance
            = std::clamp(Stats::getCurrent(target, Stats::DamageResist), 0.f, gmst("fMaxArmorRating"));
        damage *= 1.f - resistance / 100.f;
        damage -= std::max(0.f, Stats::getCurrent(target, Stats::DamageThreshold));
        return std::max(damage, minimum);
    }

    float hit(const MWWorld::Ptr& target, const MWWorld::Ptr& attacker, float damage, HitResult* result, bool ranged)
    {
        if (!canBeHit(target) || isDead(target) || damage <= 0.f)
            return 0.f;
        const float healthBefore = Stats::getCurrent(target, Stats::Health);
        Stats::damage(target, Stats::Health, damage);
        Log(Debug::Verbose) << "ESM4 hit " << target.getCellRef().getRefId() << " for " << damage << ", health "
                            << Stats::getCurrent(target, Stats::Health) << "/"
                            << Stats::getPermanent(target, Stats::Health);
        const osg::Vec3f direction = result != nullptr ? result->mDirection : osg::Vec3f();
        const float force = ESM4Physical::getDeathForce(damage, ranged);
        const std::optional<osg::Vec3f> hitPosition
            = result != nullptr ? std::optional<osg::Vec3f>(result->mPosition) : std::nullopt;
        if (isDead(target))
            kill(target, false, direction * force, hitPosition);
        else if (result != nullptr && ESM4Physical::rollKnockdown(target, damage, healthBefore, false))
            result->mKnockedDown = ESM4Physical::knockDown(target, direction, force, false, hitPosition);
        return damage;
    }

    void cancelAttacks(const MWWorld::Ptr& attacker)
    {
        if (attacker.isEmpty())
            return;
        const ESM::RefNum refNum = attacker.getCellRef().getRefNum();
        std::erase_if(sPendingHits, [&](const PendingHit& blow) { return blow.mAttacker == refNum; });
    }

    HitResult fire(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, const osg::Vec3f& origin,
        const osg::Vec3f& direction)
    {
        HitResult result;
        osg::Vec3f dir = direction;
        if (dir.normalize() == 0.f)
            return result;

        // Walls, terrain and doors stop the shot
        MWBase::World* world = MWBase::Environment::get().getWorld();
        const osg::Vec3f end = origin + dir * sShotRange;
        const MWPhysics::RayCastingResult wall = world->getRayCasting()->castRay(origin, end, { attacker }, {},
            MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap | MWPhysics::CollisionType_Door);
        float range = wall.mHit ? (wall.mHitPos - origin).length() : sShotRange;
        result.mPosition = wall.mHit ? wall.mHitPos : end;
        if (wall.mHit)
            result.mObject = wall.mHitObject;

        std::vector<MWWorld::Ptr> candidates;
        for (MWWorld::CellStore* cell : MWBase::Environment::get().getWorldScene()->getActiveCells())
        {
            collectTargets<ESM4::Npc>(*cell, candidates);
            collectTargets<ESM4::Creature>(*cell, candidates);
        }
        const MWWorld::Ptr player = getPlayer();
        if (attacker != player && !player.getClass().getCreatureStats(player).isDead())
            candidates.push_back(player);
        for (const MWWorld::Ptr& candidate : candidates)
        {
            if (candidate == attacker || !ESM4Gore::canTakeHits(candidate))
                continue;
            // The collision box: the render bounds can take in far-off nodes, and the player's model may be the
            // first person one. Corpses lie down, so for them the render bounds it is.
            osg::BoundingBox box;
            if (isDead(candidate))
            {
                if (candidate.getRefData().getBaseNode() == nullptr)
                    continue;
                osg::ComputeBoundsVisitor bounds;
                candidate.getRefData().getBaseNode()->accept(bounds);
                box = bounds.getBoundingBox();
            }
            else
            {
                const osg::Vec3f half = world->getHalfExtents(candidate);
                const osg::Vec3f position = candidate.getRefData().getPosition().asVec3();
                box = osg::BoundingBox(position - osg::Vec3f(half.x(), half.y(), 0.f),
                    position + osg::Vec3f(half.x(), half.y(), half.z() * 2.f));
            }
            if (!box.valid())
                continue;
            if (const std::optional<float> distance = intersect(box, origin, dir, range))
            {
                range = *distance;
                result.mTarget = candidate;
                result.mObject = MWWorld::Ptr();
                result.mPosition = origin + dir * *distance;
            }
        }

        result.mDirection = dir;
        if (result.mTarget.isEmpty())
            return result;
        const int projectiles = weapon.mHasFO3Data ? std::max<int>(1, weapon.mFO3Data.projectileCount) : 1;
        float damage = 0.f;
        for (int i = 0; i < projectiles; ++i)
            damage += applyArmor(result.mTarget, getWeaponDamage(attacker, weapon));
        if (result.mTarget == player)
        {
            hurtPlayer(player, damage);
            result.mDamage = damage;
            return result;
        }
        // The limb hit takes its share: a head takes double, and the limb's condition goes down
        result.mLimb = ESM4Gore::getHitLimb(result.mTarget, origin, dir);
        if (result.mLimb >= 0)
            damage *= ESM4Gore::getDamageMult(result.mTarget, result.mLimb);
        // A corpse takes no more health, but its limbs still give way (scripts/omw/fnvgore)
        result.mCorpse = isDead(result.mTarget);
        if (!result.mCorpse)
            result.mDamage = hit(result.mTarget, attacker, damage, &result, true);
        else
            Log(Debug::Verbose) << "ESM4 shot corpse " << result.mTarget.getCellRef().getRefId() << " limb "
                                << result.mLimb << " for " << damage;
        if (result.mLimb >= 0)
            ESM4Gore::damageLimb(result.mTarget, result.mLimb, damage,
                weapon.mHasFO3Data && weapon.mFO3Data.limbDamageMult > 0.f ? weapon.mFO3Data.limbDamageMult : 1.f);
        result.mKilled = isDead(result.mTarget);
        return result;
    }

    namespace
    {
        // Animation group prefix by DNAM animation type
        std::string_view animPrefix(const ESM4::Weapon& weapon)
        {
            static constexpr std::string_view prefixes[]
                = { "h2h", "1hm", "2hm", "1hp", "1hp", "2hr", "2ha", "2hr", "2hh", "2hl", "1gt", "1lm", "1md", "1gt" };
            const std::uint32_t type = weapon.mHasFO3Data ? weapon.mFO3Data.animType : 3;
            return type < std::size(prefixes) ? prefixes[type] : std::string_view("1hp");
        }

        // DNAM attack animation: 26 left, 32 right, then attack3 .. attack8 in steps of 6, 74 loop
        std::string attackSequence(const ESM4::Weapon& weapon)
        {
            const int anim = weapon.mHasFO3Data ? weapon.mFO3Data.attackAnim : 255;
            std::string suffix = "attackright";
            if (anim == 26)
                suffix = "attackleft";
            else if (anim >= 38 && anim <= 68 && (anim - 38) % 6 == 0)
                suffix = "attack" + std::to_string(3 + (anim - 38) / 6);
            else if (anim == 74)
                suffix = "attackloop";
            return std::string(animPrefix(weapon)) + suffix + ".kf";
        }

        // Plays an attack sequence: the game's regular swings come in two takes, <name>_a.kf and <name>_b.kf (no
        // plain <name>.kf exists for them), so one of the takes is tried first, then the other, then the plain file.
        float playAttack(const MWWorld::Ptr& actor, const std::string& file)
        {
            std::string base = file;
            if (Misc::StringUtils::ciEndsWith(base, ".kf"))
                base.resize(base.size() - 3);
            const bool bFirst = std::uniform_int_distribution<int>(0, 1)(random()) == 1;
            const std::string takes[] = { base + (bFirst ? "_b.kf" : "_a.kf"), base + (bFirst ? "_a.kf" : "_b.kf"),
                base + ".kf" };
            for (const std::string& take : takes)
                if (const float length = ESM4Actors::get().playAction(actor, take); length > 0.f)
                    return length;
            return 0.f;
        }

        // Two-handed weapons by DNAM animation type (FUN_00646cb0)
        bool isTwoHanded(const ESM4::Weapon& weapon)
        {
            switch (weapon.mHasFO3Data ? weapon.mFO3Data.animType : 3)
            {
                case 2:
                case 5:
                case 6:
                case 8:
                case 9:
                    return true;
                default:
                    return false;
            }
        }

        // An NPC's gun wobble (CalcActorGunWobble 0x646910): stance, crippled arm and requirement penalties, scaled
        // down by the weapon skill. NPCs don't crouch or aim down the sights, so they always pay the standing and
        // unaimed penalties.
        float gunWobble(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon)
        {
            float wobble = gmst("fStandingSpreadPenalty") + gmst("fUnaimedSpreadPenalty");
            if (ESM4Actors::get().isMoving(attacker))
                wobble += ESM4Actors::get().isRunning(attacker) ? gmst("fRunningSpreadPenalty")
                                                                 : gmst("fWalkingSpreadPenalty");

            if (Stats::getCurrent(attacker, Stats::IgnoreCrippledLimbs) == 0)
            {
                const bool left = Stats::getCurrent(attacker, Stats::LeftAttackCondition) <= 0;
                const bool right = Stats::getCurrent(attacker, Stats::RightAttackCondition) <= 0;
                const bool twoHanded = isTwoHanded(weapon);
                if (left && right)
                    wobble += gmst(twoHanded ? "fCrippledArms2HSpreadPenalty" : "fCrippledArms1HSpreadPenalty");
                else if (twoHanded && (left || right))
                    wobble += gmst("fCrippledArm2HSpreadPenalty");
                else if (right)
                    wobble += gmst("fCrippledArm1HSpreadPenalty");
            }

            int skill = weapon.mHasFO3Data ? weapon.mFO3Data.skill : -1;
            if (skill < 0 || skill >= Stats::Count)
                skill = Stats::Guns;
            const float skillValue = std::round(Stats::getCurrent(attacker, skill));
            if (weapon.mHasFO3Data)
            {
                // A point of penalty per missing Strength point and per missing 10 skill points, up to 10 each
                const float strength = std::round(Stats::getCurrent(attacker, Stats::Strength));
                const float strengthReq = static_cast<float>(weapon.mFO3Data.strengthRequirement);
                if (strengthReq >= strength)
                    wobble += std::clamp(strengthReq - strength, 0.f, 10.f) * gmst("fWeapStrengthReqPenalty");
                const float skillReq = static_cast<float>(weapon.mFO3Data.skillRequirement);
                if (skillReq >= skillValue)
                    wobble += std::clamp(std::ceil((skillReq - skillValue) / 10.f), 0.f, 10.f)
                        * gmst("fWeapSkillReqPenalty");
            }

            wobble *= 1.f - skillValue * gmst("fWobbleToSkillConversion") * 0.01f;
            return std::max(wobble, gmst("fMinGunSpreadValue"));
        }

        // How far off an NPC's shot may go: the wobble times fNPCMaxGunWobbleAngle (fire, 0x524024), plus the
        // weapon's own spread.
        float aimErrorDegrees(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon)
        {
            const float weaponSpread = weapon.mHasFO3Data ? weapon.mFO3Data.minSpread + weapon.mFO3Data.spread : 0.f;
            return weaponSpread + gunWobble(attacker, weapon) * gmst("fNPCMaxGunWobbleAngle");
        }
    }

    const ESM4::Weapon* getActorWeapon(const MWWorld::Ptr& actor)
    {
        if (actor.getType() != ESM::REC_NPC_4)
            return nullptr;
        return MWClass::ESM4Npc::getEquippedWeapon(actor);
    }

    bool isGun(const ESM4::Weapon& weapon)
    {
        return weapon.mHasFO3Data && weapon.mFO3Data.animType >= 3 && weapon.mFO3Data.animType <= 9;
    }

    int getWeaponType(const ESM4::Weapon& weapon)
    {
        // DNAM anim types: 0 hand to hand, 1-2 melee, 3-8 guns, 9 launchers, 10/13 grenades, 11/12 mines
        const std::uint32_t anim = weapon.mHasFO3Data ? weapon.mFO3Data.animType : 3;
        if (anim == 0)
            return 6;
        if (anim <= 2)
            return 2;
        if (anim <= 8)
            return 1;
        if (anim == 9)
            return 0;
        if (anim == 10 || anim == 13)
            return 3;
        return 4;
    }

    const std::vector<const ESM4::Weapon*>& getActorWeapons(const MWWorld::Ptr& actor)
    {
        static const std::vector<const ESM4::Weapon*> none;
        if (actor.getType() != ESM::REC_NPC_4)
            return none;
        return MWClass::ESM4Npc::getWeapons(actor);
    }

    void equipWeapon(const MWWorld::Ptr& actor, const ESM4::Weapon* weapon)
    {
        if (actor.getType() != ESM::REC_NPC_4 || getActorWeapon(actor) == weapon)
            return;
        drawWeapon(actor, false);
        MWClass::ESM4Npc::setEquippedWeapon(actor, weapon);
    }

    void drawWeapon(const MWWorld::Ptr& actor, bool drawn)
    {
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        const ESM4::Weapon* weapon = getActorWeapon(actor);
        if (animation == nullptr || weapon == nullptr || isDead(actor))
            return;
        sCrouched.erase(actor.getCellRef().getRefNum());
        sBlocking.erase(actor.getCellRef().getRefNum());
        animation->showWeapon(drawn ? weapon->mModel.getOriginal() : std::string_view());
        animation->setIdleSequence(drawn ? std::string(animPrefix(*weapon)) + "aim.kf" : std::string());
    }

    namespace
    {
        // The crouched idle for the drawn weapon (locomotion/sneak/), else the plain sneak idle [inferred names]
        std::string crouchLoop(const MWRender::ESM4NpcAnimation& animation, const ESM4::Weapon* weapon)
        {
            std::vector<std::string> candidates;
            if (weapon != nullptr)
            {
                const std::string aim = std::string(animPrefix(*weapon)) + "aim.kf";
                candidates.push_back("sneak/" + aim);
                candidates.push_back("sneak" + aim);
            }
            candidates.push_back("sneak/mtidle.kf");
            candidates.push_back("sneakmtidle.kf");
            for (const std::string& file : candidates)
                if (animation.hasLoopFONV(file))
                    return file;
            return {};
        }
    }

    bool setCrouched(const MWWorld::Ptr& actor, bool crouched)
    {
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        if (animation == nullptr || isDead(actor))
            return false;
        const ESM::RefNum ref = actor.getCellRef().getRefNum();
        const ESM4::Weapon* weapon = getActorWeapon(actor);
        const bool drawn = weapon != nullptr && animation->isWeaponShown();
        if (!crouched)
        {
            if (sCrouched.erase(ref) != 0)
                animation->setIdleSequence(drawn ? std::string(animPrefix(*weapon)) + "aim.kf" : std::string());
            return true;
        }
        const std::string loop = crouchLoop(*animation, drawn ? weapon : nullptr);
        if (loop.empty())
        {
            Log(Debug::Verbose) << "ESM4 no crouch loop for " << actor.getCellRef().getRefId();
            return false;
        }
        if (sCrouched.insert(ref).second)
            Log(Debug::Verbose) << "ESM4 crouch " << actor.getCellRef().getRefId() << " with " << loop;
        animation->setIdleSequence(loop);
        return true;
    }

    namespace
    {
        // The animation prefix of what the actor would block with: its melee weapon's, else "mt" (the game ships
        // 1hm/2hm/mt blockidle and blockhit, none for h2h: fists and hand to hand weapons use the mt ones)
        std::string blockPrefix(const MWRender::ESM4NpcAnimation& animation, const MWWorld::Ptr& actor)
        {
            const ESM4::Weapon* weapon = getActorWeapon(actor);
            if (weapon != nullptr && getWeaponType(*weapon) == 2)
                return std::string(animPrefix(*weapon));
            if (weapon != nullptr && getWeaponType(*weapon) == 6
                && animation.hasLoopFONV(std::string(animPrefix(*weapon)) + "blockidle.kf"))
                return std::string(animPrefix(*weapon));
            return "mt";
        }
    }

    bool setBlocking(const MWWorld::Ptr& actor, bool blocking)
    {
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        if (animation == nullptr || isDead(actor))
            return false;
        const ESM::RefNum ref = actor.getCellRef().getRefNum();
        const ESM4::Weapon* weapon = getActorWeapon(actor);
        const bool drawn = weapon != nullptr && animation->isWeaponShown();
        if (!blocking)
        {
            if (sBlocking.erase(ref) != 0)
                animation->setIdleSequence(drawn ? std::string(animPrefix(*weapon)) + "aim.kf" : std::string());
            return true;
        }
        const std::string loop = blockPrefix(*animation, actor) + "blockidle.kf";
        if (!animation->hasLoopFONV(loop))
        {
            // no guard to show: the actor does not block (it would take less damage for no visible reason)
            Log(Debug::Verbose) << "ESM4 no block loop " << loop << " for " << actor.getCellRef().getRefId();
            return false;
        }
        sCrouched.erase(ref);
        sBlocking.insert(ref);
        animation->setIdleSequence(loop);
        return true;
    }

    bool isBlocking(const MWWorld::Ptr& actor)
    {
        return sBlocking.count(actor.getCellRef().getRefNum()) != 0;
    }

    namespace
    {
        // Where an actor's shots start: about eye height. Uses the collision size, not the render bounds, which
        // can take in far-off nodes and put the muzzle thousands of units up.
        osg::Vec3f muzzle(const MWWorld::Ptr& actor)
        {
            const float half = MWBase::Environment::get().getWorld()->getHalfExtents(actor).z();
            const float eyes = sCrouched.count(actor.getCellRef().getRefNum()) != 0 ? 1.1f : 1.7f;
            return actor.getRefData().getPosition().asVec3() + osg::Vec3f(0, 0, half > 0.f ? half * eyes : 110.f);
        }

        // Where shots at an actor go: the upper body
        osg::Vec3f aimPoint(const MWWorld::Ptr& target)
        {
            const float half = MWBase::Environment::get().getWorld()->getHalfExtents(target).z();
            const float scale = target == getPlayer() ? 1.4f : 1.3f;
            return target.getRefData().getPosition().asVec3() + osg::Vec3f(0, 0, half > 0.f ? half * scale : 60.f);
        }
    }

    bool hasLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target)
    {
        const MWPhysics::RayCastingResult wall = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(
            muzzle(attacker), aimPoint(target), { attacker, target }, {},
            MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap | MWPhysics::CollisionType_Door);
        return !wall.mHit;
    }

    LineOfFire getLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target)
    {
        LineOfFire result;
        result.mFrom = muzzle(attacker);
        result.mTo = aimPoint(target);
        const MWPhysics::RayCastingResult wall = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(
            result.mFrom, result.mTo, { attacker, target }, {},
            MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap | MWPhysics::CollisionType_Door);
        result.mHit = wall.mHit;
        result.mHitPosition = wall.mHitPos;
        result.mHitObject = wall.mHitObject;
        return result;
    }

    namespace
    {
        // Light on the target, 0 to 100 [inferred: FNV reads the light level of the actor's position; this uses
        // the sun outdoors and the cell lighting indoors]
        float lightLevel(const MWWorld::Ptr& target)
        {
            MWBase::World& world = *MWBase::Environment::get().getWorld();
            const MWWorld::CellStore* cell = target.getCell();
            if (cell == nullptr || cell->getCell()->isExterior() || cell->getCell()->isQuasiExterior())
                return 15.f + 65.f * std::clamp(world.getSunPercentage() * world.getSunVisibility(), 0.f, 1.f);
            auto luminance = [](std::uint32_t rgba) {
                const float r = static_cast<float>(rgba & 0xff);
                const float g = static_cast<float>((rgba >> 8) & 0xff);
                const float b = static_cast<float>((rgba >> 16) & 0xff);
                return (0.299f * r + 0.587f * g + 0.114f * b) / 255.f;
            };
            const auto& mood = cell->getCell()->getMood();
            return std::clamp(100.f * (luminance(mood.mAmbiantColor) + 0.5f * luminance(mood.mDirectionalColor)), 0.f,
                100.f);
        }

        bool isMoving(const MWWorld::Ptr& actor)
        {
            if (actor.getType() == ESM::REC_NPC_4 || actor.getType() == ESM::REC_CREA4)
                return ESM4Actors::get().isMoving(actor);
            const osg::Vec3f& movement = actor.getClass().getMovementSettings(actor).asVec3();
            return movement.x() != 0.f || movement.y() != 0.f;
        }

        bool isRunning(const MWWorld::Ptr& actor)
        {
            if (actor.getType() == ESM::REC_NPC_4 || actor.getType() == ESM::REC_CREA4)
                return ESM4Actors::get().isRunning(actor);
            return actor.getClass().getCreatureStats(actor).getStance(CreatureStats::Stance_Run);
        }

        bool isSneaking(const MWWorld::Ptr& actor)
        {
            // FO3/FONV actors sneak by crouching (setCrouched: cover, companions sneaking with the player)
            if (actor.getType() == ESM::REC_NPC_4 || actor.getType() == ESM::REC_CREA4)
                return sCrouched.count(actor.getCellRef().getRefNum()) != 0;
            return actor.getClass().getCreatureStats(actor).getStance(CreatureStats::Stance_Sneak);
        }
    }

    Detection detect(const MWWorld::Ptr& observer, const MWWorld::Ptr& target, const DetectionContext& context)
    {
        using MWWorld::ESM4GameSettings::getFloat;
        using MWWorld::ESM4GameSettings::getInt;
        namespace Stats = MWClass::ESM4Stats;
        Detection result;
        if (observer.getCell() == nullptr || target.getCell() == nullptr)
            return result;
        const MWWorld::Cell& observerCell = *observer.getCell()->getCell();
        const MWWorld::Cell& targetCell = *target.getCell()->getCell();
        if (observerCell.isExterior() != targetCell.isExterior()
            || (!observerCell.isExterior() && observer.getCell() != target.getCell()))
            return result;

        const osg::Vec3f from = observer.getRefData().getPosition().asVec3();
        const osg::Vec3f to = target.getRefData().getPosition().asVec3();
        const float distance = (to - from).length();
        float maxDistance = getFloat("fSneakMaxDistance", 2500.f);
        if (observerCell.isExterior())
            maxDistance *= getFloat("fSneakExteriorDistanceMult", 2.f);
        if (maxDistance <= 0.f || distance >= maxDistance)
            return result;
        const float distanceFactor = std::pow(std::max((maxDistance - distance) / maxDistance, 0.f),
            getFloat("fSneakDistanceAttenuationExponent", 2.f));

        // Line of sight: inside the view cone (half of fDetectionViewCone either side) with nothing in between
        osg::Vec3f toTarget = to - from;
        toTarget.z() = 0.f;
        const float facing = observer.getRefData().getPosition().rot[2];
        const osg::Vec3f forward(std::sin(facing), std::cos(facing), 0.f);
        const float halfCone = osg::DegreesToRadians(getFloat("fDetectionViewCone", 190.f) * 0.5f);
        const bool inCone = toTarget.length2() < 1.f
            || (toTarget * forward) / toTarget.length() >= std::cos(std::min(halfCone, static_cast<float>(osg::PI)));
        result.mLineOfSight = !context.mSleeping && inCone && hasLineOfFire(observer, target);

        const bool moving = isMoving(target);
        const bool running = moving && isRunning(target);
        const bool sneaking = isSneaking(target);
        const MWWorld::Ptr player = getPlayer();
        if (context.mTeammate && sneaking && !context.mTargetInCombat && target != player && !player.isEmpty())
        {
            // a sneaking teammate is as hidden as the player (the sentinel in FUN_008a0d10)
            DetectionContext own = context;
            own.mTeammate = false;
            const Detection viaPlayer = detect(observer, player, own);
            result.mScore = viaPlayer.mScore;
            return result;
        }

        // Sound: footsteps, louder running, carried further with a line of sight
        const float soundFactor
            = result.mLineOfSight ? distanceFactor : distanceFactor * getFloat("fSneakSoundLosMult", 0.1f);
        float footsteps = 0.f;
        if (moving)
            footsteps = getFloat("fSneakBootWeightBase", 12.f) * (running ? getFloat("fSneakRunningMult", 1.5f) : 1.f);
        const float sound = std::max(0.f, footsteps * soundFactor);

        // Sight: the light on the target, more so when it moves
        float sight = 0.f;
        if (result.mLineOfSight)
            sight = std::max(0.f,
                distanceFactor
                    * (1.f + (running ? getFloat("fSneakLightRunMult", 0.2f) : 0.f)
                        + (moving ? getFloat("fSneakLightMoveMult", 0.01f) : 0.f))
                    * getFloat("fSneakLightMult", 1.4f)
                    * (lightLevel(target) + getFloat("fDetectionSneakLightMod", 0.f)));

        // Perception against Sneak
        const float perception = Stats::getCurrent(observer, Stats::Perception);
        const float perceptionMin = getFloat("fSneakPerceptionSkillMin", 10.f);
        const float perceptionMax = getFloat("fSneakPerceptionSkillMax", 90.f);
        const float awareness = 1.f + (context.mAlert ? getFloat("fSneakAlertMod", 0.2f) : 0.f)
            + (context.mSleeping ? getFloat("fSneakSleepBonus", -0.2f) : 0.f)
            + (context.mInCombat ? getFloat("fSneakCombatMod", -0.4f) : 0.f);
        float skill = awareness * (perceptionMin + perception / 10.f * (perceptionMax - perceptionMin)) * distanceFactor;
        if (sneaking)
        {
            const int level = Stats::getLevel(target);
            const float startBonus = static_cast<float>(std::max(
                getInt("iSneakStartBonus", 50) - level * getInt("iSneakStartBonusLevelPenatly", 10), 0));
            float sneakSkill = Stats::getCurrent(target, Stats::Sneak);
            if (context.mTeammate && !player.isEmpty() && target != player)
                sneakSkill = std::max(sneakSkill, Stats::getCurrent(player, Stats::Sneak));
            skill -= sneakSkill + startBonus;
        }
        skill *= getFloat("fSneakSkillMult", 0.5f);

        float score = getFloat("fSneakBaseValue", -35.f) + sound + sight + skill;
        // between 0 and 1 counts as 1, the rest is truncated
        if (score > 0.f && score < 1.f)
            score = 1.f;
        else
            score = std::trunc(score);
        result.mScore = score;
        return result;
    }

    bool shoot(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, HitResult& result)
    {
        const ESM4::Weapon* weapon = getActorWeapon(attacker);
        if (weapon == nullptr || !isGun(*weapon) || isDead(attacker) || ESM4Actors::get().isActing(attacker))
            return false;
        if (playAttack(attacker, attackSequence(*weapon)) <= 0.f)
            playAttack(attacker, std::string(animPrefix(*weapon)) + "attackright.kf");

        if (!weapon->mFireSound.isZeroOrUnset())
            MWBase::Environment::get().getSoundManager()->playSound3D(
                attacker, ESM::RefId(weapon->mFireSound), 1.f, 1.f);

        const osg::Vec3f origin = muzzle(attacker);
        osg::Vec3f direction = aimPoint(target) - origin;
        direction.normalize();

        // Turn the shot by a random angle within the aim error
        const float error = osg::DegreesToRadians(aimErrorDegrees(attacker, *weapon));
        std::uniform_real_distribution<float> unit(-1.f, 1.f);
        osg::Vec3f side = direction ^ osg::Vec3f(0, 0, 1);
        if (side.normalize() == 0.f)
            side = osg::Vec3f(1, 0, 0);
        const osg::Vec3f up = side ^ direction;
        const float yaw = error * unit(random());
        const float pitch = error * unit(random());
        direction = direction + side * std::tan(yaw) + up * std::tan(pitch);

        // Launchers fire shells that fly and burst (the blast is reported later, to the blow listener)
        if (isExplosiveProjectile(*weapon))
        {
            direction.normalize();
            result = HitResult();
            result.mDirection = direction;
            launch(attacker, *weapon, origin, origin + direction * (aimPoint(target) - origin).length());
            return true;
        }
        result = fire(attacker, *weapon, origin, direction);
        const osg::Vec3f aim = aimPoint(target);
        const osg::Vec3f half = MWBase::Environment::get().getWorld()->getHalfExtents(target);
        Log(Debug::Verbose) << "ESM4 shot by " << attacker.getCellRef().getRefId() << " from " << origin.x() << " "
                            << origin.y() << " " << origin.z() << " at " << aim.x() << " " << aim.y() << " "
                            << aim.z() << " (target half " << half.x() << " " << half.y() << " " << half.z()
                            << "), error " << aimErrorDegrees(attacker, *weapon) << " deg, yaw "
                            << osg::RadiansToDegrees(yaw) << " pitch " << osg::RadiansToDegrees(pitch) << ", hit "
                            << (result.mTarget.isEmpty() ? std::string("-")
                                                         : result.mTarget.getCellRef().getRefId().toDebugString())
                            << " at " << result.mPosition.x() << " " << result.mPosition.y() << " "
                            << result.mPosition.z();
        return true;
    }

    float reload(const MWWorld::Ptr& actor)
    {
        const ESM4::Weapon* weapon = getActorWeapon(actor);
        if (weapon == nullptr || isDead(actor))
            return 0.f;
        const int letter = weapon->mHasFO3Data ? weapon->mFO3Data.reloadAnim : 0;
        const std::string prefix(animPrefix(*weapon));
        float length = 0.f;
        if (letter >= 0 && letter < 26)
            length = ESM4Actors::get().playAction(actor, prefix + "reload" + char('a' + letter) + ".kf");
        if (length <= 0.f)
            length = ESM4Actors::get().playAction(actor, prefix + "reloada.kf");
        return std::max(length, weapon->mHasFO3Data ? weapon->mFO3Data.reloadTime : 1.f);
    }

    float getUnarmedDamage(const MWWorld::Ptr& attacker)
    {
        if (attacker.getType() == ESM::REC_CREA4)
            return Stats::getCurrent(attacker, Stats::MeleeDamage);
        // fAVDUnarmedDamageBase + fAVDUnarmedDamageMult x Unarmed
        return Stats::getCurrent(attacker, Stats::UnarmedDamage);
    }

    bool attack(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, float reach)
    {
        if (isDead(attacker) || ESM4Actors::get().isActing(attacker))
            return false;
        setBlocking(attacker, false);
        // NPCs with a melee weapon (or a hand to hand one, like a power fist) in hand swing it
        const ESM4::Weapon* weapon = getActorWeapon(attacker);
        if (weapon != nullptr && getWeaponType(*weapon) != 2 && getWeaponType(*weapon) != 6)
            weapon = nullptr;
        float length = 0.f;
        if (weapon != nullptr)
            length = playAttack(attacker, attackSequence(*weapon));
        // Fists and creatures (which keep their attacks next to the skeleton)
        static constexpr std::string_view attacks[]
            = { "h2hattackleft.kf", "h2hattackright.kf", "h2hattackpower.kf", "h2hattackforwardpower.kf" };
        const std::size_t first = std::uniform_int_distribution<std::size_t>(0, 1)(random());
        for (std::size_t i = 0; i < std::size(attacks) && length <= 0.f; ++i)
            length = playAttack(attacker, std::string(attacks[(first + i) % std::size(attacks)]));
        if (length <= 0.f)
            length = 1.f; // no sequence: the blow still lands
        sPendingHits.push_back(
            { attacker.getCellRef().getRefNum(), target.getCellRef().getRefNum(), length * 0.45f, reach, weapon });
        return true;
    }

    namespace
    {
        const ESM4::Projectile* projectileOf(const ESM4::Weapon& weapon)
        {
            if (!weapon.mHasFO3Data || weapon.mFO3Data.projectile.isZeroOrUnset())
                return nullptr;
            return MWBase::Environment::get().getESMStore()->get<ESM4::Projectile>().search(
                ESM::RefId(weapon.mFO3Data.projectile));
        }

        void removeNode(FlyingProjectile& projectile)
        {
            if (projectile.mNode == nullptr)
                return;
            while (projectile.mNode->getNumParents() > 0)
                projectile.mNode->getParent(0)->removeChild(projectile.mNode);
            projectile.mNode = nullptr;
        }

        // The point an explosion damages an actor at: the middle of its body
        osg::Vec3f bodyCentre(const MWWorld::Ptr& actor)
        {
            const osg::Vec3f position = actor.getRefData().getPosition().asVec3();
            return position + osg::Vec3f(0, 0, MWBase::Environment::get().getWorld()->getHalfExtents(actor).z());
        }

        void explode(const FlyingProjectile& projectile)
        {
            MWBase::World* world = MWBase::Environment::get().getWorld();
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM4::Explosion* explosion
                = store.get<ESM4::Explosion>().search(ESM::RefId(projectile.mProjectile->mData.explosion));
            const osg::Vec3f at = projectile.mPosition;
            if (explosion == nullptr)
                return;
            if (!explosion->mModel.empty())
                world->spawnEffect(Misc::ResourceHelpers::correctMeshPath(
                                       VFS::Path::Normalized(explosion->mModel.getOriginal())),
                    {}, at, 1.f, false, false);
            if (!explosion->mData.sound1.isZeroOrUnset())
                MWBase::Environment::get().getSoundManager()->playSound3D(
                    at, ESM::RefId(explosion->mData.sound1), 1.f, 1.f);

            const float radius = explosion->mData.radius;
            if (radius <= 0.f)
                return;
            // The EXPL damage, times the thrower's skill while it still holds the weapon (FalloutNV.exe 0x9b0f80);
            // the weapon's own damage is not used
            const MWWorld::Ptr attacker = MWBase::Environment::get().getWorldModel()->getPtr(projectile.mAttacker);
            float baseDamage = explosion->mData.damage;
            if (!attacker.isEmpty() && projectile.mWeapon != nullptr && getActorWeapon(attacker) == projectile.mWeapon)
                baseDamage *= skillFactor(attacker, *projectile.mWeapon);
            const bool ignoreLOS = (explosion->mData.flags & 0x10) != 0;

            std::vector<MWWorld::Ptr> candidates;
            for (MWWorld::CellStore* cell : MWBase::Environment::get().getWorldScene()->getActiveCells())
            {
                collectTargets<ESM4::Npc>(*cell, candidates);
                collectTargets<ESM4::Creature>(*cell, candidates);
            }
            const MWWorld::Ptr player = getPlayer();
            if (!player.getClass().getCreatureStats(player).isDead())
                candidates.push_back(player);
            const osg::Vec3f from = at + osg::Vec3f(0, 0, 8);
            Log(Debug::Info) << "ESM4 explosion " << explosion->mEditorId << " at " << at.x() << " " << at.y() << " "
                             << at.z() << ", radius " << radius << ", damage " << baseDamage;
            for (const MWWorld::Ptr& candidate : candidates)
            {
                if (candidate != player && !ESM4Gore::canTakeHits(candidate))
                    continue;
                const bool corpse = candidate != player && isDead(candidate);
                // A corpse lies on the ground
                const osg::Vec3f centre = corpse
                    ? candidate.getRefData().getPosition().asVec3() + osg::Vec3f(0, 0, 16)
                    : bodyCentre(candidate);
                const float distance = (centre - at).length();
                if (distance > radius)
                    continue;
                // Walls and terrain shield from the blast, unless the explosion ignores LOS (EXPL flag 0x10); the
                // original tries seven rays per actor, this one to its middle
                if (!ignoreLOS)
                {
                    const MWPhysics::RayCastingResult wall = world->getRayCasting()->castRay(from, centre,
                        { candidate }, {},
                        MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap
                            | MWPhysics::CollisionType_Door);
                    if (wall.mHit)
                    {
                        Log(Debug::Info) << "ESM4 explosion blocked from " << candidate.getCellRef().getRefId()
                                         << " at " << distance;
                        continue;
                    }
                }
                // 1 - (d/R)^2: no full-damage core (FalloutNV.exe 0x647920)
                const float falloff = 1.f - (distance / radius) * (distance / radius);
                const float damage = applyArmor(candidate, baseDamage * falloff);
                HitResult result;
                result.mTarget = candidate;
                result.mPosition = centre;
                result.mDirection = centre - at;
                result.mDirection.normalize();
                result.mExplosion = true;
                result.mCorpse = corpse;
                if (corpse)
                    ESM4Gore::damageAllLimbs(candidate, damage);
                else if (candidate == player)
                {
                    hurtPlayer(candidate, damage);
                    result.mDamage = damage;
                    result.mKilled = candidate.getClass().getCreatureStats(candidate).isDead();
                }
                else
                {
                    result.mDamage = hit(candidate, attacker, damage, &result, true);
                    ESM4Gore::damageAllLimbs(candidate, damage);
                    result.mKilled = isDead(candidate);
                }
                if (sBlowListener && !attacker.isEmpty())
                    sBlowListener(attacker, projectile.mWeapon, result);
            }
        }

        // Moves one projectile; true once it has gone off (or flown out of range)
        bool stepProjectile(FlyingProjectile& projectile, float duration)
        {
            const ESM4::Projectile::Data& data = projectile.mProjectile->mData;
            projectile.mAge += duration;
            const bool timed = data.explosionTimer > 0.f;
            if (timed && projectile.mAge >= data.explosionTimer)
                return true;
            if (projectile.mResting)
                return false;
            projectile.mVelocity.z() -= sGravity * data.gravity * duration;
            const osg::Vec3f next = projectile.mPosition + projectile.mVelocity * duration;
            MWBase::World* world = MWBase::Environment::get().getWorld();
            std::vector<MWWorld::ConstPtr> ignore;
            // the thrower's own body for the first moment
            if (projectile.mAge < 0.3f)
                ignore.push_back(MWBase::Environment::get().getWorldModel()->getPtr(projectile.mAttacker));
            const MWPhysics::RayCastingResult hit = world->getRayCasting()->castRay(projectile.mPosition, next, ignore,
                {},
                MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap | MWPhysics::CollisionType_Door
                    | MWPhysics::CollisionType_Actor);
            if (hit.mHit)
            {
                projectile.mPosition = hit.mHitPos + hit.mHitNormal * 2.f;
                if (!timed)
                    return true;
                // Grenades bounce and roll until their fuse runs out
                const float bounce = data.bouncyMult > 0.f ? std::min(data.bouncyMult, 1.f) : 0.3f;
                const osg::Vec3f normal = hit.mHitNormal;
                projectile.mVelocity = (projectile.mVelocity - normal * (2.f * (projectile.mVelocity * normal))) * bounce;
                if (++projectile.mBounces <= 4)
                    Log(Debug::Info) << "ESM4 bounce at " << hit.mHitPos.x() << " " << hit.mHitPos.y() << " "
                                     << hit.mHitPos.z() << ", normal " << normal.x() << " " << normal.y() << " "
                                     << normal.z() << ", off "
                                     << (hit.mHitObject.isEmpty() ? std::string("terrain")
                                                                  : hit.mHitObject.getCellRef().getRefId().toDebugString())
                                     << ", now " << projectile.mVelocity.x() << " " << projectile.mVelocity.y() << " "
                                     << projectile.mVelocity.z();
                if (projectile.mVelocity.length() < 40.f)
                    projectile.mResting = true;
            }
            else
            {
                projectile.mTravelled += (next - projectile.mPosition).length();
                projectile.mPosition = next;
            }
            if (projectile.mNode != nullptr)
                projectile.mNode->setMatrix(osg::Matrix::translate(projectile.mPosition));
            const float range = data.range > 0.f ? data.range : 20000.f;
            return !timed && projectile.mTravelled > range;
        }

        void updateProjectiles(float duration)
        {
            for (std::size_t i = 0; i < sProjectiles.size();)
            {
                if (stepProjectile(sProjectiles[i], duration))
                {
                    FlyingProjectile projectile = sProjectiles[i];
                    sProjectiles.erase(sProjectiles.begin() + static_cast<std::ptrdiff_t>(i));
                    removeNode(projectile);
                    explode(projectile);
                }
                else
                    ++i;
            }
        }
    }

    namespace
    {
        float projectileSpeed(const ESM4::Projectile& projectile)
        {
            return projectile.mData.speed > 0.f ? projectile.mData.speed : 1000.f;
        }

        // Whether an arc is clear: iBallisticProjectilePathPickSegments 4 straight pieces, accepted when nothing
        // is hit or the first hit comes after fGrenadeThrowHitFractionThreshold 0.8 of the way
        bool arcClear(const MWWorld::Ptr& attacker, const osg::Vec3f& origin, const osg::Vec3f& velocity,
            float gravity, float time)
        {
            constexpr int segments = 4;
            const float total = velocity.length() * time;
            float travelled = 0.f;
            osg::Vec3f from = origin;
            for (int i = 1; i <= segments; ++i)
            {
                const float t = time * i / segments;
                const osg::Vec3f to = origin + velocity * t - osg::Vec3f(0, 0, 0.5f * gravity * t * t);
                const MWPhysics::RayCastingResult hit
                    = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(from, to, { attacker }, {},
                        MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap
                            | MWPhysics::CollisionType_Door);
                if (hit.mHit)
                    return total <= 0.f || (travelled + (hit.mHitPos - from).length()) / total >= 0.8f;
                travelled += (to - from).length();
                from = to;
            }
            return true;
        }

        // Launch velocity at the target (FalloutNV.exe 0x9a7670): the low arc at the projectile's speed if it
        // is clear, else the high arc at fGrenadeHighArcSpeedPercentage 0.67 of it; 45 degrees when neither
        // reaches. Without gravity: straight at it.
        osg::Vec3f throwVelocity(const MWWorld::Ptr& attacker, const ESM4::Projectile& projectile,
            const osg::Vec3f& origin, const osg::Vec3f& target)
        {
            const float speed = projectileSpeed(projectile);
            const float gravity = sGravity * projectile.mData.gravity;
            osg::Vec3f delta = target - origin;
            osg::Vec3f flat(delta.x(), delta.y(), 0.f);
            const float d = flat.normalize();
            const float h = delta.z();
            if (gravity <= 0.f || d < 1.f)
            {
                delta.normalize();
                return delta * speed;
            }
            std::optional<osg::Vec3f> fallback;
            for (const auto& [v, high] : { std::pair{ speed, false }, std::pair{ speed * 0.67f, true } })
            {
                const float v2 = v * v;
                const float root = v2 * v2 - gravity * (gravity * d * d + 2.f * h * v2);
                if (root < 0.f)
                    continue;
                const float angle = std::atan((v2 + (high ? 1.f : -1.f) * std::sqrt(root)) / (gravity * d));
                const osg::Vec3f velocity = (flat * std::cos(angle) + osg::Vec3f(0, 0, std::sin(angle))) * v;
                if (!fallback)
                    fallback = velocity;
                const float time = d / (v * std::cos(angle));
                if (arcClear(attacker, origin, velocity, gravity, time))
                    return velocity;
            }
            if (fallback)
                return *fallback;
            const float angle = osg::DegreesToRadians(45.f);
            return (flat * std::cos(angle) + osg::Vec3f(0, 0, std::sin(angle))) * speed;
        }
    }

    float getBlastDangerRadius(const ESM4::Weapon& weapon)
    {
        const ESM4::Projectile* projectile = projectileOf(weapon);
        if (projectile == nullptr)
            return 0.f;
        const ESM4::Explosion* explosion = MWBase::Environment::get().getESMStore()->get<ESM4::Explosion>().search(
            ESM::RefId(projectile->mData.explosion));
        if (explosion == nullptr || explosion->mData.damage < 5.f)
            return 0.f;
        const float radius = explosion->mData.radius * std::sqrt(1.f - 5.f / explosion->mData.damage);
        return radius >= 30.f ? radius : 0.f;
    }

    float getThrowRange(const ESM4::Weapon& weapon)
    {
        const ESM4::Projectile* projectile = projectileOf(weapon);
        if (projectile == nullptr)
            return 0.f;
        const float gravity = sGravity * projectile->mData.gravity;
        const float speed = projectileSpeed(*projectile);
        // the 45 degree range v^2/g; shells without gravity go as far as the projectile flies
        if (gravity <= 0.f)
            return projectile->mData.range > 0.f ? projectile->mData.range : 4096.f;
        return speed * speed / gravity;
    }

    bool isExplosiveProjectile(const ESM4::Weapon& weapon)
    {
        const ESM4::Projectile* projectile = projectileOf(weapon);
        return projectile != nullptr && (projectile->mData.flags & ESM4::Projectile::Flag_Explosion) != 0
            && (projectile->mData.flags & ESM4::Projectile::Flag_Hitscan) == 0;
    }

    bool launch(const MWWorld::Ptr& attacker, const ESM4::Weapon& weapon, const osg::Vec3f& origin,
        const osg::Vec3f& targetPosition)
    {
        if (!isExplosiveProjectile(weapon))
            return false;
        const ESM4::Projectile* data = projectileOf(weapon);
        FlyingProjectile projectile;
        projectile.mAttacker = attacker.getCellRef().getRefNum();
        projectile.mWeapon = &weapon;
        projectile.mProjectile = data;
        projectile.mPosition = origin;
        projectile.mVelocity = throwVelocity(attacker, *data, origin, targetPosition);
        Log(Debug::Info) << "ESM4 launch " << data->mEditorId << " from " << origin.x() << " " << origin.y() << " "
                         << origin.z() << " at " << targetPosition.x() << " " << targetPosition.y() << " "
                         << targetPosition.z() << ", speed " << projectile.mVelocity.length() << ", gravity "
                         << data->mData.gravity << ", timer " << data->mData.explosionTimer;
        if (!data->mModel.empty())
        {
            osg::ref_ptr<osg::Node> model = MWBase::Environment::get().getResourceSystem()->getSceneManager()->getInstance(
                Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(data->mModel.getOriginal())));
            projectile.mNode = new osg::MatrixTransform(osg::Matrix::translate(origin));
            projectile.mNode->setName("ESM4Projectile");
            projectile.mNode->addChild(model);
            MWBase::Environment::get().getWorld()->getRenderingManager()->getLightRoot()->addChild(projectile.mNode);
        }
        sProjectiles.push_back(std::move(projectile));
        return true;
    }

    bool launchAt(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, std::optional<osg::Vec3f> at)
    {
        const ESM4::Weapon* weapon = getActorWeapon(attacker);
        if (weapon == nullptr || !isExplosiveProjectile(*weapon) || isDead(attacker)
            || ESM4Actors::get().isActing(attacker))
            return false;
        // Thrown weapons have their own throw sequence; launchers fire like guns
        const std::string prefix(animPrefix(*weapon));
        if (playAttack(attacker, prefix + "attackthrow.kf") <= 0.f && playAttack(attacker, attackSequence(*weapon)) <= 0.f)
            playAttack(attacker, prefix + "attackright.kf");
        if (!weapon->mFireSound.isZeroOrUnset())
            MWBase::Environment::get().getSoundManager()->playSound3D(
                attacker, ESM::RefId(weapon->mFireSound), 1.f, 1.f);
        // Aim point (FalloutNV.exe 0x9a8bf0): 0.75 of the target's height for a lobbed projectile, its feet for a
        // slow shell with a big blast (speed <= fCombatSplashDamageMaxSpeed 3000, radius > 50, damage > 20),
        // otherwise its middle
        const ESM4::Projectile* projectile = projectileOf(*weapon);
        const osg::Vec3f feet = at.value_or(target.getRefData().getPosition().asVec3());
        const float height = MWBase::Environment::get().getWorld()->getHalfExtents(target).z() * 2.f;
        float fraction = 0.5f;
        const ESM4::Explosion* explosion = MWBase::Environment::get().getESMStore()->get<ESM4::Explosion>().search(
            ESM::RefId(projectile->mData.explosion));
        if (projectile->mData.gravity > 0.f)
            fraction = 0.75f;
        else if (projectileSpeed(*projectile) <= 3000.f && explosion != nullptr && explosion->mData.radius > 50.f
            && explosion->mData.damage > 20.f)
            fraction = 0.f;
        return launch(attacker, *weapon, muzzle(attacker), feet + osg::Vec3f(0, 0, height * fraction));
    }

    namespace
    {
        bool clearRay(const osg::Vec3f& from, const osg::Vec3f& to, const MWWorld::Ptr& a, const MWWorld::Ptr& b)
        {
            const MWPhysics::RayCastingResult wall
                = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(from, to, { a, b }, {},
                    MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap
                        | MWPhysics::CollisionType_Door);
            return !wall.mHit;
        }

        // The target's eyes
        osg::Vec3f eyesOf(const MWWorld::Ptr& target)
        {
            const osg::Vec3f position = target.getRefData().getPosition().asVec3();
            return position + osg::Vec3f(0, 0, MWBase::Environment::get().getWorld()->getHalfExtents(target).z() * 1.8f);
        }
    }

    bool canTargetSee(const MWWorld::Ptr& actor, const MWWorld::Ptr& target, const osg::Vec3f& point)
    {
        // the head: crouched if the actor can crouch [inferred: the original tests the cover point against the
        // target's LOS]
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        const bool canCrouch = animation != nullptr && !crouchLoop(*animation, getActorWeapon(actor)).empty();
        const float head = MWBase::Environment::get().getWorld()->getHalfExtents(actor).z() * (canCrouch ? 1.2f : 1.7f);
        return clearRay(eyesOf(target), point + osg::Vec3f(0, 0, head), actor, target);
    }

    namespace
    {
        std::map<ESM::RefNum, std::string> sNoCoverLogged;
    }

    std::optional<Cover> findCover(const MWWorld::Ptr& actor, const MWWorld::Ptr& target,
        const osg::Vec3f& targetPosition, float searchRadius, float minDistance, float maxDistance, bool needFire,
        const std::vector<std::uint64_t>& excluded)
    {
        const osg::Vec3f position = actor.getRefData().getPosition().asVec3();
        const osg::Vec3f half = MWBase::Environment::get().getWorld()->getHalfExtents(actor);
        const float radius = std::max(half.x(), half.y());
        const osg::Vec3f aim = targetPosition
            + osg::Vec3f(0, 0, MWBase::Environment::get().getWorld()->getHalfExtents(target).z() * 1.3f);
        int checked = 0, closed = 0, band = 0, facing = 0, seen = 0, noFire = 0;
        for (const ESM4Navigation::CoverEdge& edge :
            ESM4Actors::get().findCoverEdges(actor, position, searchRadius, 64))
        {
            ++checked;
            if (std::find(excluded.begin(), excluded.end(), edge.mKey) != excluded.end())
                continue;
            const bool noOpenEnd = !edge.mOpenA && !edge.mOpenB;
            if (needFire && noOpenEnd)
                ++closed; // No edges are open: only usable by firing over it (below)
            const osg::Vec3f mid = (edge.mA + edge.mB) * 0.5f;
            const osg::Vec3f coverPoint = mid + edge.mInward * (radius + 8.f);
            const float toTarget = (coverPoint - targetPosition).length();
            if (toTarget < minDistance || toTarget > maxDistance)
            {
                ++band;
                continue; // Too close / Too far
            }
            if ((coverPoint - targetPosition).length() < 256.f)
                continue; // Hostiles near
            // The cover has to stand between the actor and the target: the target on the edge's outer side
            // [inferred: the original's edges face away from where the actor stands]
            osg::Vec3f toTargetFlat = targetPosition - mid;
            toTargetFlat.z() = 0.f;
            toTargetFlat.normalize();
            if (toTargetFlat * edge.mInward > -0.5f)
            {
                ++facing;
                continue;
            }
            if (findProjectileNear(coverPoint, 0.f))
                continue; // Cover threatened
            if (canTargetSee(actor, target, coverPoint))
            {
                ++seen;
                continue; // Target has Cover LOS
            }
            Cover cover{ coverPoint, coverPoint, edge.mKey };
            if (needFire)
            {
                // Step out past an open end, far enough to clear the edge [inferred: the original's fire point]
                osg::Vec3f along = edge.mB - edge.mA;
                along.z() = 0.f;
                along.normalize();
                bool found = false;
                for (int end = 0; end < 2 && !found; ++end)
                {
                    if ((end == 0 && !edge.mOpenA) || (end == 1 && !edge.mOpenB))
                        continue;
                    const osg::Vec3f corner = end == 0 ? edge.mA : edge.mB;
                    const osg::Vec3f out = end == 0 ? -along : along;
                    const osg::Vec3f firePoint = corner + out * (radius + 24.f) + edge.mInward * (radius + 8.f);
                    if (findProjectileNear(firePoint, 0.f))
                        continue; // Fire threatened
                    if (!clearRay(firePoint + osg::Vec3f(0, 0, half.z() * 1.7f), aim, actor, target))
                        continue; // No LOS from Fire position
                    cover.mFirePoint = firePoint;
                    found = true;
                }
                if (!found && noOpenEnd && !findProjectileNear(coverPoint, 0.f)
                    && clearRay(coverPoint + osg::Vec3f(0, 0, half.z() * 1.7f), aim, actor, target))
                {
                    // Low cover with no open end: stand up and fire over it from the cover point [inferred; the
                    // sight line from standing height decides whether the cover is low enough]. Run 17 had
                    // 60 % of the edges near Goodsprings closed at both ends, so nobody found cover.
                    cover.mFirePoint = coverPoint;
                    found = true;
                }
                if (!found)
                {
                    ++noFire;
                    continue;
                }
            }
            sNoCoverLogged.erase(actor.getCellRef().getRefNum());
            return cover;
        }
        std::ostringstream why;
        why << "ESM4 no cover for " << actor.getCellRef().getRefId() << ": " << checked << " edges, " << closed
            << " closed at both ends, " << band << " out of " << minDistance << "-" << maxDistance << ", " << facing
            << " not facing the target, " << seen << " seen by it, " << noFire << " without a fire point";
        // The original searches on every replan (about once a second); log only when the outcome changes
        std::string& last = sNoCoverLogged[actor.getCellRef().getRefNum()];
        if (last != why.str())
        {
            last = why.str();
            Log(Debug::Verbose) << last;
        }
        return std::nullopt;
    }

    std::optional<osg::Vec3f> findProjectileNear(const osg::Vec3f& position, float radius)
    {
        // Threats as the original's threat map has them (FalloutNV.exe 0x9a52f0): explosions doing more than
        // fDangerousProjectileExplosionDamage 5 within their dangerous radius R x sqrt(1 - 5/D) (where the
        // damage has fallen to 5), above fDangerousProjectileExplosionRadius 30; timed fuses only in their last
        // fCombatThreatTimedExplosionLength 5 s
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
        std::optional<osg::Vec3f> nearest;
        float best = std::numeric_limits<float>::max();
        for (const FlyingProjectile& projectile : sProjectiles)
        {
            const ESM4::Projectile::Data& data = projectile.mProjectile->mData;
            const ESM4::Explosion* explosion = store.get<ESM4::Explosion>().search(ESM::RefId(data.explosion));
            if (explosion == nullptr || explosion->mData.damage <= 5.f)
                continue;
            const float dangerous = explosion->mData.radius * std::sqrt(1.f - 5.f / explosion->mData.damage);
            if (dangerous <= 30.f)
                continue;
            if (data.explosionTimer > 0.f && data.explosionTimer - projectile.mAge > 5.f)
                continue;
            const float distance = (projectile.mPosition - position).length();
            if (distance <= dangerous + radius && distance < best)
            {
                best = distance;
                nearest = projectile.mPosition;
            }
        }
        return nearest;
    }

    void update(float duration, bool paused)
    {
        if (paused)
            return;
        updateProjectiles(duration);
        if (sPendingHits.empty())
            return;
        MWWorld::WorldModel& worldModel = *MWBase::Environment::get().getWorldModel();
        std::vector<PendingHit> landed;
        for (auto it = sPendingHits.begin(); it != sPendingHits.end();)
        {
            it->mTime -= duration;
            if (it->mTime > 0.f)
            {
                ++it;
                continue;
            }
            landed.push_back(*it);
            it = sPendingHits.erase(it);
        }
        for (const PendingHit& blow : landed)
        {
            const MWWorld::Ptr attacker = worldModel.getPtr(blow.mAttacker);
            const MWWorld::Ptr target = worldModel.getPtr(blow.mTarget);
            if (attacker.isEmpty() || target.isEmpty() || isDead(attacker) || isDead(target))
                continue;
            if (target == getPlayer() && target.getClass().getCreatureStats(target).isDead())
                continue;
            const osg::Vec3f delta
                = target.getRefData().getPosition().asVec3() - attacker.getRefData().getPosition().asVec3();
            if (delta.length() > blow.mReach * 1.5f)
                continue;
            float damage = applyArmor(target,
                blow.mWeapon != nullptr ? getWeaponDamage(attacker, *blow.mWeapon) : getUnarmedDamage(attacker));
            HitResult result;
            // A target holding its weapon up blocks: [inferred, after Oblivion/FO3] the blow loses
            // fBlockAmountWeaponMult (hands: fBlockAmountHandToHandMult) x (fBlockSkillBase + fBlockSkillMult x
            // skill 50 / 100), at most fBlockMax, and the BlockHit sequence plays. Blocking while swinging fails.
            if (target != getPlayer() && isBlocking(target) && !ESM4Actors::get().isActing(target))
            {
                const ESM4::Weapon* held = getActorWeapon(target);
                const bool withWeapon = held != nullptr && getWeaponType(*held) == 2;
                const float skillTerm = gmst("fBlockSkillBase") + gmst("fBlockSkillMult") * 0.5f;
                const float amount = std::clamp(
                    gmst(withWeapon ? "fBlockAmountWeaponMult" : "fBlockAmountHandToHandMult") * skillTerm, 0.f,
                    gmst("fBlockMax"));
                damage *= 1.f - amount;
                result.mBlocked = true;
                if (MWRender::ESM4NpcAnimation* animation = getAnimation(target))
                    ESM4Actors::get().playAction(target, blockPrefix(*animation, target) + "blockhit.kf");
            }
            result.mTarget = target;
            result.mPosition = target.getRefData().getPosition().asVec3();
            result.mDirection = delta;
            result.mDirection.normalize();
            if (target == getPlayer())
            {
                hurtPlayer(target, damage);
                result.mDamage = damage;
                result.mKilled = target.getClass().getCreatureStats(target).isDead();
            }
            else
            {
                result.mDamage = hit(target, attacker, damage, &result, false);
                result.mKilled = isDead(target);
            }
            if (sBlowListener)
                sBlowListener(attacker, blow.mWeapon, result);
        }
    }

    void setBlowListener(BlowListener listener)
    {
        sBlowListener = std::move(listener);
    }

    void clear()
    {
        sPendingHits.clear();
        for (FlyingProjectile& projectile : sProjectiles)
            removeNode(projectile);
        sProjectiles.clear();
    }

    void kill(const MWWorld::Ptr& actor, bool instant, const osg::Vec3f& impulse,
        const std::optional<osg::Vec3f>& hitPosition)
    {
        ESM4Actors::get().stop(actor, true);
        cancelAttacks(actor);
        MWBase::Environment::get().getWorld()->enableActorCollision(actor, false);
        // The body drops as a ragdoll where it has one; the death sequence otherwise
        const bool ragdoll = ESM4Physical::setDead(actor, impulse, hitPosition, instant);
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
            animation->playDeath(instant || ragdoll);
    }
}
