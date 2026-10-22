#include "esm4combat.hpp"

#include <algorithm>
#include <limits>

#include <osg/ComputeBoundsVisitor>

#include <components/sceneutil/positionattitudetransform.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadweap.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/scene.hpp"

#include "actorutil.hpp"
#include "esm4actors.hpp"

namespace MWMechanics::ESM4Combat
{
    namespace
    {
        namespace Stats = MWClass::ESM4Stats;

        // FalloutNV.esm game settings
        constexpr float fDamageSkillBase = 0.5f;
        constexpr float fDamageSkillMult = 0.5f;
        constexpr float fMinDamMultiplier = 0.2f;
        constexpr float fMaxArmorRating = 85.f;

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
        const float skillFactor = fDamageSkillBase + fDamageSkillMult * std::clamp(skillValue, 0.f, 100.f) / 100.f;
        return base * skillFactor * conditionMultiplier(condition);
    }

    float applyArmor(const MWWorld::Ptr& target, float damage)
    {
        if (damage <= 0.f)
            return 0.f;
        const float minimum = damage * fMinDamMultiplier;
        const float resistance = std::clamp(Stats::getCurrent(target, Stats::DamageResist), 0.f, fMaxArmorRating);
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

        std::vector<MWWorld::Ptr> candidates;
        for (MWWorld::CellStore* cell : MWBase::Environment::get().getWorldScene()->getActiveCells())
        {
            collectTargets<ESM4::Npc>(*cell, candidates);
            collectTargets<ESM4::Creature>(*cell, candidates);
        }
        for (const MWWorld::Ptr& candidate : candidates)
        {
            if (candidate == attacker || isDead(candidate))
                continue;
            osg::ComputeBoundsVisitor bounds;
            candidate.getRefData().getBaseNode()->accept(bounds);
            const osg::BoundingBox& box = bounds.getBoundingBox();
            if (!box.valid())
                continue;
            if (const std::optional<float> distance = intersect(box, origin, dir, range))
            {
                range = *distance;
                result.mTarget = candidate;
                result.mPosition = origin + dir * *distance;
            }
        }

        if (result.mTarget.isEmpty())
            return result;
        const int projectiles = weapon.mHasFO3Data ? std::max<int>(1, weapon.mFO3Data.projectileCount) : 1;
        float damage = 0.f;
        for (int i = 0; i < projectiles; ++i)
            damage += applyArmor(result.mTarget, getWeaponDamage(attacker, weapon));
        result.mDamage = hit(result.mTarget, attacker, damage);
        result.mKilled = isDead(result.mTarget);
        return result;
    }

    void kill(const MWWorld::Ptr& actor, bool instant)
    {
        ESM4Actors::get().stop(actor);
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
            animation->playDeath(instant);
    }
}
