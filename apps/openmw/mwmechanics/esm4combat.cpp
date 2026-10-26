#include "esm4combat.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
#include <random>
#include <string>

#include <osg/ComputeBoundsVisitor>

#include <components/sceneutil/positionattitudetransform.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadfact.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
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
        };
        std::vector<PendingHit> sPendingHits;

        std::mt19937& random()
        {
            static std::mt19937 generator{ std::random_device{}() };
            return generator;
        }

        // The player is a Morrowind actor: blows take its Morrowind health, so that death works as usual. The damage
        // is scaled from the player's FNV health to the Morrowind one, so fights last as long as in FNV.
        void hurtPlayer(const MWWorld::Ptr& player, float damage)
        {
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

    float hit(const MWWorld::Ptr& target, const MWWorld::Ptr& attacker, float damage)
    {
        if (!canBeHit(target) || isDead(target) || damage <= 0.f)
            return 0.f;
        Stats::damage(target, Stats::Health, damage);
        Log(Debug::Verbose) << "ESM4 hit " << target.getCellRef().getRefId() << " for " << damage << ", health "
                            << Stats::getCurrent(target, Stats::Health) << "/"
                            << Stats::getPermanent(target, Stats::Health);
        if (isDead(target))
            kill(target);
        return damage;
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
            if (candidate == attacker || isDead(candidate))
                continue;
            osg::BoundingBox box;
            if (candidate == player)
            {
                // The player's model may be the first person one; use its collision box
                const osg::Vec3f half = world->getHalfExtents(candidate);
                const osg::Vec3f position = candidate.getRefData().getPosition().asVec3();
                box = osg::BoundingBox(position - osg::Vec3f(half.x(), half.y(), 0.f),
                    position + osg::Vec3f(half.x(), half.y(), half.z() * 2.f));
            }
            else
            {
                osg::ComputeBoundsVisitor bounds;
                candidate.getRefData().getBaseNode()->accept(bounds);
                box = bounds.getBoundingBox();
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
        result.mDamage = hit(result.mTarget, attacker, damage);
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

        osg::BoundingBox worldBounds(const MWWorld::Ptr& ptr)
        {
            osg::ComputeBoundsVisitor bounds;
            if (osg::Node* node = ptr.getRefData().getBaseNode())
                node->accept(bounds);
            return bounds.getBoundingBox();
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

    void drawWeapon(const MWWorld::Ptr& actor, bool drawn)
    {
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        const ESM4::Weapon* weapon = getActorWeapon(actor);
        if (animation == nullptr || weapon == nullptr || isDead(actor))
            return;
        animation->showWeapon(drawn ? weapon->mModel.getOriginal() : std::string_view());
        animation->setIdleSequence(drawn ? std::string(animPrefix(*weapon)) + "aim.kf" : std::string());
    }

    namespace
    {
        // Where an actor's shots start: about eye height
        osg::Vec3f muzzle(const MWWorld::Ptr& actor)
        {
            const osg::BoundingBox box = worldBounds(actor);
            const osg::Vec3f position = actor.getRefData().getPosition().asVec3();
            return osg::Vec3f(position.x(), position.y(),
                box.valid() ? box.zMin() + (box.zMax() - box.zMin()) * 0.85f : position.z() + 110.f);
        }

        // Where shots at an actor go: the upper body
        osg::Vec3f aimPoint(const MWWorld::Ptr& target)
        {
            const osg::Vec3f position = target.getRefData().getPosition().asVec3();
            if (target == getPlayer())
                return position
                    + osg::Vec3f(0, 0, MWBase::Environment::get().getWorld()->getHalfExtents(target).z() * 1.4f);
            const osg::BoundingBox box = worldBounds(target);
            if (!box.valid())
                return position + osg::Vec3f(0, 0, 60);
            return osg::Vec3f(position.x(), position.y(), box.zMin() + (box.zMax() - box.zMin()) * 0.65f);
        }
    }

    bool hasLineOfFire(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target)
    {
        const MWPhysics::RayCastingResult wall = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(
            muzzle(attacker), aimPoint(target), { attacker, target }, {},
            MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap | MWPhysics::CollisionType_Door);
        return !wall.mHit;
    }

    bool shoot(const MWWorld::Ptr& attacker, const MWWorld::Ptr& target, HitResult& result)
    {
        const ESM4::Weapon* weapon = getActorWeapon(attacker);
        if (weapon == nullptr || !isGun(*weapon) || isDead(attacker) || ESM4Actors::get().isActing(attacker))
            return false;
        if (ESM4Actors::get().playAction(attacker, attackSequence(*weapon)) <= 0.f)
            ESM4Actors::get().playAction(attacker, std::string(animPrefix(*weapon)) + "attackright.kf");

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

        result = fire(attacker, *weapon, origin, direction);
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
        // Creatures keep their attacks next to the skeleton
        static constexpr std::string_view attacks[]
            = { "h2hattackleft.kf", "h2hattackright.kf", "h2hattackpower.kf", "h2hattackforwardpower.kf" };
        const std::size_t first = std::uniform_int_distribution<std::size_t>(0, 1)(random());
        float length = 0.f;
        for (std::size_t i = 0; i < std::size(attacks) && length <= 0.f; ++i)
            length = ESM4Actors::get().playAction(attacker, attacks[(first + i) % std::size(attacks)]);
        if (length <= 0.f)
            length = 1.f; // no sequence: the blow still lands
        sPendingHits.push_back(
            { attacker.getCellRef().getRefNum(), target.getCellRef().getRefNum(), length * 0.45f, reach });
        return true;
    }

    void update(float duration, bool paused)
    {
        if (paused || sPendingHits.empty())
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
            const float damage = applyArmor(target, getUnarmedDamage(attacker));
            if (target == getPlayer())
                hurtPlayer(target, damage);
            else
                hit(target, attacker, damage);
        }
    }

    void clear()
    {
        sPendingHits.clear();
    }

    void kill(const MWWorld::Ptr& actor, bool instant)
    {
        ESM4Actors::get().stop(actor);
        MWBase::Environment::get().getWorld()->enableActorCollision(actor, false);
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
            animation->playDeath(instant);
    }
}
