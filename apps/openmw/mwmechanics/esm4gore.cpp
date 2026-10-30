#include "esm4gore.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <random>

#include <osg/ComputeBoundsVisitor>
#include <osg/Node>

#include <components/esm/refid.hpp>
#include <components/esm4/loadbptd.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/misc/strings/algorithm.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwclass/esm4stats.hpp"
#include "../mwrender/esm4npcanimation.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/esmstore.hpp"

#include "actorutil.hpp"

namespace MWMechanics::ESM4Gore
{
    namespace
    {
        namespace Stats = MWClass::ESM4Stats;
        using BodyPart = ESM4::BodyPartData::BodyPart;

        // Hard-coded forms of FalloutNV.esm (0x1c and 0x1d), by editor id: the esm needn't be the first content file
        const ESM4::BodyPartData* findByEditorId(std::string_view editorId)
        {
            for (const ESM4::BodyPartData& data : MWBase::Environment::get().getESMStore()->get<ESM4::BodyPartData>())
                if (Misc::StringUtils::ciEqual(data.mEditorId, editorId))
                    return &data;
            return nullptr;
        }

        struct Lost
        {
            LimbMask mLimbs = 0;
            LimbMask mExploded = 0;
        };
        std::map<ESM::RefNum, Lost> sLost;

        int gmstInt(std::string_view name, int fallback)
        {
            return MWWorld::ESM4GameSettings::getInt(name, fallback);
        }

        MWRender::ESM4NpcAnimation* getAnimation(const MWWorld::Ptr& ptr)
        {
            return dynamic_cast<MWRender::ESM4NpcAnimation*>(MWBase::Environment::get().getWorld()->getAnimation(ptr));
        }

        // The game keeps a body part per limb (BGSBodyPartData, parts by part type)
        const BodyPart* findPart(const ESM4::BodyPartData& data, int limb)
        {
            for (const BodyPart& part : data.mBodyParts)
                if (part.mData.partType == limb)
                    return &part;
            return nullptr;
        }

        // FUN_005e5130: the first part with the condition actor value
        const BodyPart* findPartByActorValue(const ESM4::BodyPartData& data, int av)
        {
            for (const BodyPart& part : data.mBodyParts)
                if (part.mData.actorValue == av)
                    return &part;
            return nullptr;
        }

        bool hasFlag(const BodyPart& part, std::uint8_t flag)
        {
            return (part.mData.flags & flag) != 0;
        }

        bool isExplodable(const BodyPart& part)
        {
            return hasFlag(part, ESM4::BodyPartData::Flag_Explodable);
        }

        // Explodes whenever it goes: an absolute chance of 100
        bool alwaysExplodes(const BodyPart& part)
        {
            return isExplodable(part) && hasFlag(part, ESM4::BodyPartData::Flag_AbsoluteChance)
                && part.mData.explExplosionChance >= 100;
        }

        bool isLimbCondition(int av)
        {
            return av >= Stats::PerceptionCondition && av <= Stats::BrainCondition;
        }

        bool isCrippled(const MWWorld::Ptr& actor, int av)
        {
            return isLimbCondition(av) && Stats::getCurrent(actor, av) < 1.f;
        }

        // A limb to tear off with its sever and explode bonuses (FUN_008b43a0's lists)
        struct Candidate
        {
            int mActorValue;
            int mLimb;
            int mSeverBonus = 0;
            int mExplodeBonus = 0;
        };

        // FUN_00646e50: one roll decides between exploding and severing
        void rollPart(std::minstd_rand& random, const BodyPart& part, const Candidate& candidate,
            const ESM4::Weapon* weapon, bool& sever, bool& explode)
        {
            sever = false;
            explode = false;
            const int roll = static_cast<int>(random() % 100);
            const int explodeChance = isExplodable(part) ? part.mData.explExplosionChance : 0;
            int explodeThreshold = 0;
            if (hasFlag(part, ESM4::BodyPartData::Flag_AbsoluteChance))
                explodeThreshold = explodeChance + candidate.mExplodeBonus;
            else
                explodeThreshold = static_cast<int>(std::lround(explodeChance * 0.01
                    * (candidate.mExplodeBonus + gmstInt("iCombatExplodePartChance", 5))));
            const int severThreshold = candidate.mSeverBonus + gmstInt("iCombatDismemberPartChance", 25);
            if (roll < explodeThreshold)
                explode = true;
            else if (roll < severThreshold)
                sever = true;
            if (weapon == nullptr || !weapon->mHasFO3Data || (!sever && !explode))
                return;
            switch (weapon->mFO3Data.onHit)
            {
                case 1: // dismember only
                    sever = true;
                    explode = false;
                    break;
                case 2: // explode only
                    sever = false;
                    explode = true;
                    break;
                case 3: // neither
                    sever = false;
                    explode = false;
                    break;
                default:
                    break;
            }
        }

        osg::Vec3f worldPosition(const osg::Node& node)
        {
            const osg::NodePathList paths = node.getParentalNodePaths();
            if (paths.empty())
                return osg::Vec3f();
            return osg::Vec3f() * osg::computeLocalToWorld(paths.front());
        }

        // Closest distance between the ray and the segment a..b
        float rayToSegment(const osg::Vec3f& origin, const osg::Vec3f& dir, const osg::Vec3f& a, const osg::Vec3f& b)
        {
            const osg::Vec3f u = b - a;
            const osg::Vec3f w = a - origin;
            const float uu = u * u;
            const float ud = u * dir;
            const float uw = u * w;
            const float dw = dir * w;
            const float denominator = uu - ud * ud; // dir is unit length
            float s = 0.f;
            if (uu > 0.f)
                s = denominator > 1e-6f ? (ud * dw - uw) / denominator : 0.f;
            s = std::clamp(s, 0.f, 1.f);
            const osg::Vec3f onSegment = a + u * s;
            const float t = std::max(0.f, (onSegment - origin) * dir);
            return (origin + dir * t - onSegment).length();
        }
    }

    const ESM4::BodyPartData* getBodyPartData(const MWWorld::Ptr& actor)
    {
        const MWWorld::Store<ESM4::BodyPartData>& store
            = MWBase::Environment::get().getESMStore()->get<ESM4::BodyPartData>();
        if (actor.getType() == ESM::REC_CREA4)
        {
            const ESM4::Creature* creature = MWClass::ESM4Creature::getModelRecord(actor);
            if (creature == nullptr || creature->mBodyParts.empty())
                return nullptr;
            return store.search(ESM::RefId(creature->mBodyParts.front()));
        }
        if (actor == getPlayer())
            return findByEditorId("PlayerBodyPartData");
        if (actor.getType() == ESM::REC_NPC_4)
            return findByEditorId("DefaultBodyPartData");
        return nullptr;
    }

    int getHitLimb(const MWWorld::Ptr& actor, const osg::Vec3f& origin, const osg::Vec3f& direction)
    {
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        MWRender::ESM4NpcAnimation* animation = getAnimation(actor);
        if (data == nullptr || animation == nullptr)
            return -1;
        osg::Vec3f dir = direction;
        if (dir.normalize() == 0.f)
            return -1;
        int best = -1;
        float bestDistance = std::numeric_limits<float>::max();
        const LimbMask lost = getLostLimbs(actor);
        for (const BodyPart& part : data->mBodyParts)
        {
            // A limb that is gone can't be hit
            if ((lost & limbBit(part.mData.partType)) != 0)
                continue;
            const osg::Node* start = animation->getNode(part.mNodeName);
            if (start == nullptr)
                continue;
            const osg::Node* end = animation->getNode(part.mVATSTarget);
            const osg::Vec3f a = worldPosition(*start);
            osg::Vec3f b = end != nullptr && end != start ? worldPosition(*end) : a;
            // The bones end at the start of the limb's last segment: reach on to cover it (the forearm and hand
            // past the elbow, the head past the neck). The torso runs from the pelvis to the chest.
            const float reach = part.mData.partType == ESM4::BodyPartData::Part_Torso ? 0.3f : 1.f;
            b = b + (b - a) * reach;
            const float distance = rayToSegment(origin, dir, a, b);
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = part.mData.partType;
            }
        }
        return best;
    }

    float getDamageMult(const MWWorld::Ptr& actor, int limb)
    {
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        const BodyPart* part = data != nullptr ? findPart(*data, limb) : nullptr;
        return part != nullptr && part->mData.damageMult > 0.f ? part->mData.damageMult : 1.f;
    }

    void damageLimb(const MWWorld::Ptr& actor, int limb, float damage, float weaponLimbMult)
    {
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        const BodyPart* part = data != nullptr ? findPart(*data, limb) : nullptr;
        if (part == nullptr || !isLimbCondition(part->mData.actorValue) || damage <= 0.f)
            return;
        const float health = Stats::getPermanent(actor, Stats::Health);
        const float limbHealth = health * part->mData.healthPercent / 100.f;
        if (limbHealth <= 0.f)
            return;
        float conditionLoss = damage * weaponLimbMult / limbHealth * 100.f;
        if (actor == getPlayer())
            conditionLoss *= MWWorld::ESM4GameSettings::getFloat("fCombatPlayerLimbDamageMult", 1.f);
        const int av = part->mData.actorValue;
        conditionLoss = std::min(conditionLoss, std::max(0.f, Stats::getCurrent(actor, av)));
        if (conditionLoss > 0.f)
            Stats::damage(actor, av, conditionLoss);
    }

    bool canTakeHits(const MWWorld::Ptr& actor)
    {
        if (!Stats::hasActorValues(actor))
            return false;
        if (actor == getPlayer())
            return true;
        const bool dead = Stats::getPermanent(actor, Stats::Health) > 0 && Stats::getCurrent(actor, Stats::Health) <= 0;
        if (!dead)
            return true;
        // A body blown apart (its torso gone) has nothing left to hit
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        return data != nullptr
            && (getLostLimbs(actor) & limbBit(ESM4::BodyPartData::Part_Torso)) == 0;
    }

    void damageAllLimbs(const MWWorld::Ptr& actor, float damage)
    {
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        if (data == nullptr)
            return;
        for (const BodyPart& part : data->mBodyParts)
            damageLimb(actor, part.mData.partType, damage, 1.f);
    }

    std::vector<Dismemberment> rollDismemberment(const MWWorld::Ptr& actor, const KillingBlow& blow)
    {
        std::vector<Dismemberment> result;
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        if (data == nullptr)
            return result;
        std::minstd_rand random(blow.mSeed == 0 ? 1u : blow.mSeed);
        const BodyPart* hitPart = findPart(*data, blow.mLimb);
        const LimbMask alreadyLost = getLostLimbs(actor);

        std::vector<Candidate> candidates;
        bool torsoExplodes = false;
        int torsoLimb = -1;
        if (!blow.mBloodyMess && blow.mExplosion)
        {
            // FUN_008b43a0 for a blast: every crippled limb the blast reached, each with its own roll
            for (const BodyPart& part : data->mBodyParts)
            {
                const int limb = part.mData.partType;
                if ((limb != ESM4::BodyPartData::Part_Torso || alwaysExplodes(part))
                    && isCrippled(actor, part.mData.actorValue)
                    && std::none_of(candidates.begin(), candidates.end(),
                        [&](const Candidate& c) { return c.mActorValue == part.mData.actorValue; }))
                    candidates.push_back({ part.mData.actorValue, limb });
            }
        }
        else if (!blow.mBloodyMess)
        {
            // Only a crippled limb comes off, and the torso only if it always explodes
            if (hitPart != nullptr && (alwaysExplodes(*hitPart) || blow.mLimb != ESM4::BodyPartData::Part_Torso)
                && isCrippled(actor, hitPart->mData.actorValue))
                candidates.push_back({ hitPart->mData.actorValue, blow.mLimb });
        }
        else
        {
            int hitActorValue = -1;
            if (hitPart != nullptr)
            {
                hitActorValue = hitPart->mData.actorValue;
                if (hitActorValue == Stats::EnduranceCondition)
                {
                    // A blow to the torso may blow the whole body apart
                    if (isExplodable(*hitPart)
                        && (alwaysExplodes(*hitPart)
                            || static_cast<int>(random() % 100) < gmstInt("iMessTorsoExplodeChance", 50)))
                    {
                        torsoExplodes = true;
                        torsoLimb = hitPart->mData.partType;
                    }
                }
                else if (isLimbCondition(hitActorValue))
                    candidates.push_back({ hitActorValue, blow.mLimb, 100,
                        alwaysExplodes(*hitPart) ? 100 : gmstInt("iMessTargetedLimbExplodeBonus", 50) });
            }
            for (int av = Stats::PerceptionCondition; av <= Stats::BrainCondition; ++av)
            {
                if (av == hitActorValue || av == Stats::EnduranceCondition)
                    continue;
                const BodyPart* part = findPartByActorValue(*data, av);
                if (part == nullptr)
                    continue;
                const bool always = alwaysExplodes(*part);
                if (isCrippled(actor, av))
                    candidates.push_back({ av, part->mData.partType, 100,
                        always ? 100 : gmstInt("iMessCrippledLimbExplodeBonus", 50) });
                else
                {
                    if (!always && !torsoExplodes
                        && static_cast<int>(random() % 100) > gmstInt("iMessIntactLimbDismemberChance", 75))
                        continue;
                    candidates.push_back({ av, part->mData.partType, 100,
                        always ? 100 : gmstInt("iMessIntactLimbExplodeBonus", 50) });
                }
            }
            if (torsoExplodes)
                candidates.push_back({ Stats::EnduranceCondition, torsoLimb, 100, 100 });
        }

        // bDismemberOneLimb:Combat (an INI setting, off)
        constexpr bool oneLimb = false;
        for (const Candidate& candidate : candidates)
        {
            const BodyPart* candidatePart = findPart(*data, candidate.mLimb);
            if (candidatePart == nullptr || !isLimbCondition(candidate.mActorValue))
                continue;
            // FUN_008b4d10
            bool sever = false;
            bool explode = alwaysExplodes(*candidatePart)
                || (torsoExplodes && candidate.mActorValue == Stats::EnduranceCondition);
            if (!explode)
                rollPart(random, *candidatePart, candidate, blow.mWeapon, sever, explode);
            if (!sever && !explode)
                continue;
            // Every part on the limb's condition goes, unless bDismemberOneLimb
            for (const BodyPart& part : data->mBodyParts)
            {
                if (part.mData.actorValue != candidate.mActorValue)
                    continue;
                const int limb = part.mData.partType;
                if (oneLimb && limb != candidate.mLimb)
                    continue;
                if ((alreadyLost & limbBit(limb)) != 0)
                    continue;
                if (std::any_of(result.begin(), result.end(),
                        [&](const Dismemberment& d) { return d.mLimb == limb; }))
                    continue;
                const bool partExplodes = explode && isExplodable(part);
                if (!partExplodes && !hasFlag(part, ESM4::BodyPartData::Flag_Severable))
                    continue;
                result.push_back({ limb, partExplodes });
            }
        }
        return result;
    }

    void dismember(const MWWorld::Ptr& actor, int limb, bool explode, const osg::Vec3f& direction, std::uint32_t seed)
    {
        const ESM4::BodyPartData* data = getBodyPartData(actor);
        const BodyPart* part = data != nullptr ? findPart(*data, limb) : nullptr;
        if (part == nullptr)
            return;
        Lost& lost = sLost[actor.getCellRef().getRefNum()];
        if ((lost.mLimbs & limbBit(limb)) != 0)
            return;
        lost.mLimbs |= limbBit(limb);
        if (explode)
            lost.mExploded |= limbBit(limb);
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
            animation->dismember(*data, *part, explode, direction, seed, lost.mLimbs);
    }

    LimbMask getLostLimbs(const MWWorld::Ptr& actor)
    {
        auto found = sLost.find(actor.getCellRef().getRefNum());
        return found != sLost.end() ? found->second.mLimbs : 0;
    }

    LimbMask getExplodedLimbs(const MWWorld::Ptr& actor)
    {
        auto found = sLost.find(actor.getCellRef().getRefNum());
        return found != sLost.end() ? found->second.mExploded : 0;
    }

    void setLostLimbs(const MWWorld::Ptr& actor, LimbMask lost, LimbMask exploded)
    {
        const ESM::RefNum refNum = actor.getCellRef().getRefNum();
        if (lost == 0)
            sLost.erase(refNum);
        else
            sLost[refNum] = { lost, exploded & lost };
        if (MWRender::ESM4NpcAnimation* animation = getAnimation(actor))
            animation->showLostLimbs();
    }

    void clear()
    {
        sLost.clear();
    }
}
