// FO3/FONV dismemberment on ESM4NpcAnimation: lost limbs, severed limbs and limb gore.
//
// Body meshes (BSDismemberSkinInstance) split their triangles into partitions by body part: the limb itself (its
// part type, 3 for the left upper arm), the cap on the severed limb (100 + part), the cap on the body (200 + part)
// and body sections next to a limb (1000 x part). NifOsg keeps them on the source geometry (DismemberPartitions);
// here they are chosen per actor. FalloutNV.exe tears limbs off in FUN_008b52a0 (sever: a skinned copy of the limb
// thrown off at fCombatDismemberedLimbVelocity with sDismemberParticleDefault spraying from the stump; explode: the
// BPND's explosion, debris and limb replacement model). The original's Havok pieces are thrown here along simple
// arcs that stop on the ground below.

#include "esm4npcanimation.hpp"

#include <algorithm>
#include <cmath>
#include <random>
#include <set>
#include <string>

#include <osg/Group>
#include <osg/MatrixTransform>
#include <osgParticle/ParticleSystem>

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loaddebr.hpp>
#include <components/esm4/loadexpl.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/misc/strings/lower.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/dismemberpartitions.hpp>
#include <components/sceneutil/nodecallback.hpp>
#include <components/sceneutil/riggeometry.hpp>
#include <components/sceneutil/skeleton.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwmechanics/esm4gore.hpp"
#include "../mwphysics/collisiontype.hpp"
#include "../mwphysics/raycasting.hpp"
#include "../mwworld/esm4gamesettings.hpp"
#include "../mwworld/esmstore.hpp"

namespace MWRender
{
    namespace
    {
        using BodyPart = ESM4::BodyPartData::BodyPart;
        using Gore = MWMechanics::ESM4Gore::LimbMask;

        // Havok's gravity in game units (70 units to the metre)
        constexpr float sGravity = 9.8f * 70.f;

        osg::Matrix worldMatrix(const osg::Node& node)
        {
            const osg::NodePathList paths = node.getParentalNodePaths();
            return paths.empty() ? osg::Matrix() : osg::computeLocalToWorld(paths.front());
        }

        // Lower-case names of the bone and everything under it
        class CollectNamesVisitor : public osg::NodeVisitor
        {
        public:
            CollectNamesVisitor(std::set<std::string>& names)
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                , mNames(names)
            {
            }

            void apply(osg::Node& node) override
            {
                if (!node.getName().empty())
                    mNames.insert(Misc::StringUtils::lowerCase(node.getName()));
                traverse(node);
            }

            std::set<std::string>& mNames;
        };

        // Chooses the partitions of skinned shapes, and drops the shapes without any that do (body) or don't (a
        // severed limb) belong to the limb bones: rigid parts under them, skinned ones bound to them alone. Shapes are
        // shared between instances, so they are taken out of their (per instance) parent rather than hidden.
        class LimbFilterVisitor : public osg::NodeVisitor
        {
        public:
            using ShowPart = bool (*)(std::uint16_t bodyPart, Gore limbs);

            LimbFilterVisitor(ShowPart showPart, Gore limbs, const std::set<std::string>& bones, bool keepLimbBones)
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                , mShowPart(showPart)
                , mLimbs(limbs)
                , mBones(bones)
                , mKeepLimbBones(keepLimbBones)
            {
            }

            void apply(osg::Drawable& drawable) override
            {
                if (dynamic_cast<osgParticle::ParticleSystem*>(&drawable))
                {
                    // Effects (the blood spraying from a stump) stay on the body and stay off the severed limb
                    if (mKeepLimbBones)
                        remove(drawable);
                    return;
                }
                bool inLimb = false;
                if (auto* rig = dynamic_cast<SceneUtil::RigGeometry*>(&drawable))
                {
                    osg::ref_ptr<osg::Geometry> source = rig->getSourceGeometry();
                    if (source != nullptr)
                    {
                        if (const SceneUtil::DismemberPartitions* parts = SceneUtil::DismemberPartitions::get(*source))
                        {
                            osg::Geometry::PrimitiveSetList primitives;
                            for (const SceneUtil::DismemberPartitions::Part& part : parts->mParts)
                                if (mShowPart(part.mBodyPart, mLimbs))
                                    primitives.push_back(part.mPrimitives);
                            rig->setPrimitiveSets(primitives);
                            return;
                        }
                    }
                    const std::vector<std::string> bones = rig->getBoneNames();
                    inLimb = !bones.empty()
                        && std::all_of(bones.begin(), bones.end(), [&](const std::string& bone) { return mBones.count(bone) > 0; });
                }
                else
                {
                    for (const osg::Node* node : getNodePath())
                        if (!node->getName().empty() && mBones.count(Misc::StringUtils::lowerCase(node->getName())) > 0)
                        {
                            inLimb = true;
                            break;
                        }
                }
                if (inLimb != mKeepLimbBones)
                    remove(drawable);
            }

            void removeAll()
            {
                for (auto& [parent, child] : mRemove)
                    parent->removeChild(child);
                mRemove.clear();
            }

        private:
            void remove(osg::Drawable& drawable)
            {
                const osg::NodePath& path = getNodePath();
                if (path.size() < 2)
                    return;
                if (osg::Group* parent = path[path.size() - 2]->asGroup())
                    mRemove.emplace_back(parent, &drawable);
            }

            ShowPart mShowPart;
            Gore mLimbs;
            const std::set<std::string>& mBones;
            bool mKeepLimbBones;
            std::vector<std::pair<osg::ref_ptr<osg::Group>, osg::ref_ptr<osg::Node>>> mRemove;
        };

        // The body: parts but the lost limbs, their body caps (200 + part) and the body sections (1000 x part). A
        // lost torso takes everything.
        bool showOnBody(std::uint16_t bodyPart, Gore lost)
        {
            if ((lost & MWMechanics::ESM4Gore::limbBit(ESM4::BodyPartData::Part_Torso)) != 0)
                return false;
            if (bodyPart < 100)
                return (lost & MWMechanics::ESM4Gore::limbBit(bodyPart)) == 0;
            if (bodyPart >= 200 && bodyPart < 300)
                return (lost & MWMechanics::ESM4Gore::limbBit(bodyPart - 200)) != 0;
            return bodyPart >= 1000;
        }

        // A severed limb: the limb and its own cap (100 + part)
        bool showOnLimb(std::uint16_t bodyPart, Gore limb)
        {
            if (bodyPart < 100)
                return (limb & MWMechanics::ESM4Gore::limbBit(bodyPart)) != 0;
            if (bodyPart < 200)
                return (limb & MWMechanics::ESM4Gore::limbBit(bodyPart - 100)) != 0;
            return false;
        }

        class StripUpdateCallbacksVisitor : public osg::NodeVisitor
        {
        public:
            StripUpdateCallbacksVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void apply(osg::Node& node) override
            {
                node.setUpdateCallback(nullptr);
                traverse(node);
            }
        };

        // Throws a piece along an arc from where it is (start, in world space) and spins it about the pivot, until
        // it comes down on the ground.
        class FlightCallback : public SceneUtil::NodeCallback<FlightCallback, osg::MatrixTransform*>
        {
        public:
            FlightCallback(const osg::Matrix& start, const osg::Vec3f& pivot, const osg::Vec3f& velocity,
                const osg::Vec3f& spinAxis, float spin, float groundZ, float radius)
                : mStart(start)
                , mPivot(pivot)
                , mVelocity(velocity)
                , mSpinAxis(spinAxis)
                , mSpin(spin)
                , mGroundZ(groundZ)
                , mRadius(radius)
            {
            }

            void operator()(osg::MatrixTransform* node, osg::NodeVisitor* nv)
            {
                if (!mLanded && nv->getFrameStamp() != nullptr)
                {
                    const double now = nv->getFrameStamp()->getSimulationTime();
                    if (mStartTime < 0)
                        mStartTime = now;
                    float time = static_cast<float>(now - mStartTime);
                    osg::Vec3f offset = mVelocity * time + osg::Vec3f(0, 0, -0.5f * sGravity * time * time);
                    const float fall = mVelocity.z() - sGravity * time;
                    const float lowest = mGroundZ + mRadius;
                    if (fall < 0.f && mPivot.z() + offset.z() <= lowest)
                    {
                        offset.z() = lowest - mPivot.z();
                        mLanded = true;
                    }
                    // Give up on a piece that never finds the ground
                    if (time > 10.f)
                        mLanded = true;
                    const osg::Quat spin(mSpin * time, mSpinAxis);
                    node->setMatrix(mStart * osg::Matrix::translate(-mPivot) * osg::Matrix::rotate(spin)
                        * osg::Matrix::translate(mPivot + offset));
                }
                traverse(node, nv);
            }

        private:
            osg::Matrix mStart;
            osg::Vec3f mPivot;
            osg::Vec3f mVelocity;
            osg::Vec3f mSpinAxis;
            float mSpin;
            float mGroundZ;
            float mRadius;
            double mStartTime = -1;
            bool mLanded = false;
        };

        float groundBelow(const osg::Vec3f& position, const MWWorld::Ptr& actor)
        {
            const MWPhysics::RayCastingResult hit
                = MWBase::Environment::get().getWorld()->getRayCasting()->castRay(position + osg::Vec3f(0, 0, 32),
                    position - osg::Vec3f(0, 0, 4096), { actor }, {},
                    MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap);
            return hit.mHit ? hit.mHitPos.z() : position.z() - 128.f;
        }

        float uniform(std::minstd_rand& random, float min, float max)
        {
            return std::uniform_real_distribution<float>(min, max)(random);
        }

        osg::Vec3f randomDirection(std::minstd_rand& random)
        {
            osg::Vec3f v(uniform(random, -1.f, 1.f), uniform(random, -1.f, 1.f), uniform(random, -1.f, 1.f));
            if (v.normalize() == 0.f)
                return osg::Vec3f(0, 0, 1);
            return v;
        }

        // Launches a piece already placed at start (world space); it lands on the ground below the actor's feet.
        void launch(osg::MatrixTransform& piece, const osg::Matrix& start, const osg::Vec3f& pivot,
            const osg::Vec3f& velocity, std::minstd_rand& random, float groundZ, float radius)
        {
            piece.setMatrix(start);
            piece.addUpdateCallback(new FlightCallback(
                start, pivot, velocity, randomDirection(random), uniform(random, 3.f, 9.f), groundZ, radius));
        }

        std::string meshPath(std::string_view model)
        {
            return Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model)).value();
        }

        // The limb's gore positioning (BPND translation and rotation) on its gore effects bone
        osg::Matrix goreOffset(const BodyPart& part)
        {
            const ESM4::BodyPartData::BPND& d = part.mData;
            return osg::Matrix::rotate(d.rotX, osg::X_AXIS, d.rotY, osg::Y_AXIS, d.rotZ, osg::Z_AXIS)
                * osg::Matrix::translate(d.transX, d.transY, d.transZ);
        }
    }

    void ESM4NpcAnimation::showLostLimbs()
    {
        const Gore lost = MWMechanics::ESM4Gore::getLostLimbs(mPtr);
        if (lost == 0)
            return;
        if (const ESM4::BodyPartData* data = MWMechanics::ESM4Gore::getBodyPartData(mPtr))
            hideLimbs(*data, lost);
    }

    void ESM4NpcAnimation::hideLimbs(const ESM4::BodyPartData& data, std::uint32_t lost)
    {
        if (mObjectRoot == nullptr)
            return;
        std::set<std::string> bones;
        CollectNamesVisitor collect(bones);
        for (const BodyPart& part : data.mBodyParts)
        {
            if ((lost & MWMechanics::ESM4Gore::limbBit(part.mData.partType)) == 0
                || part.mData.partType == ESM4::BodyPartData::Part_Torso)
                continue;
            if (const osg::Node* bone = getNode(part.mNodeName))
                const_cast<osg::Node*>(bone)->accept(collect);
        }
        const bool torso = (lost & MWMechanics::ESM4Gore::limbBit(ESM4::BodyPartData::Part_Torso)) != 0;
        if (torso)
        {
            // Nothing stays of a body blown apart
            CollectNamesVisitor all(bones);
            mObjectRoot->accept(all);
        }
        LimbFilterVisitor filter(&showOnBody, lost, bones, false);
        mObjectRoot->accept(filter);
        filter.removeAll();
    }

    void ESM4NpcAnimation::dismember(const ESM4::BodyPartData& data, const BodyPart& part, bool explode,
        const osg::Vec3f& direction, std::uint32_t seed, std::uint32_t lost)
    {
        if (mObjectRoot == nullptr)
            return;
        // The copy of the limb is taken before the limb goes from the body
        if (!explode)
            spawnSeveredLimb(part, direction, seed);
        hideLimbs(data, lost);
        if (explode)
            spawnLimbGore(part, direction, seed);

        // Blood sprays from the stump
        if (part.mData.partType != ESM4::BodyPartData::Part_Torso)
        {
            bool robot = false;
            if (mPtr.getType() == ESM::REC_CREA4)
                if (const ESM4::Creature* creature = MWClass::ESM4Creature::getModelRecord(mPtr))
                    robot = creature->mFO3Data.type == 6;
            const std::string_view spray = robot
                ? MWWorld::ESM4GameSettings::getString("sDismemberRobotParticleDefault", "Gore\\RobotLimbSpray01.nif")
                : MWWorld::ESM4GameSettings::getString("sDismemberParticleDefault", "Gore\\BloodSprayLimb01.nif");
            const std::string& boneName = part.mGoreEffectsTarget.empty() ? part.mNodeName : part.mGoreEffectsTarget;
            Log(Debug::Verbose) << "Dismember " << mPtr.getCellRef().getRefId() << " limb "
                                << static_cast<int>(part.mData.partType) << (explode ? " explodes" : " severed")
                                << ", spray '" << spray << "' on " << boneName;
            if (!spray.empty() && getNode(boneName) != nullptr)
                addEffect(meshPath(spray), "dismember" + std::to_string(part.mData.partType), false, boneName, {},
                    false, false, goreOffset(part));
        }
    }

    void ESM4NpcAnimation::spawnSeveredLimb(const BodyPart& part, const osg::Vec3f& direction, std::uint32_t seed)
    {
        const osg::Node* bone = getNode(part.mNodeName);
        if (bone == nullptr || mInsert == nullptr || mInsert->getNumParents() == 0)
            return;
        std::minstd_rand random(seed * 31u + part.mData.partType + 1u);

        // A copy of the whole actor in its pose, showing only the limb
        osg::ref_ptr<osg::Node> copy = mResourceSystem->getSceneManager()->getInstance(mObjectRoot.get());
        StripUpdateCallbacksVisitor strip;
        copy->accept(strip);
        std::set<std::string> bones;
        CollectNamesVisitor collect(bones);
        const_cast<osg::Node*>(bone)->accept(collect);
        LimbFilterVisitor filter(&showOnLimb, MWMechanics::ESM4Gore::limbBit(part.mData.partType), bones, true);
        copy->accept(filter);
        filter.removeAll();

        osg::ref_ptr<osg::MatrixTransform> piece = new osg::MatrixTransform;
        piece->setName("SeveredLimb");
        piece->addChild(copy);
        mInsert->getParent(0)->addChild(piece);

        const osg::Matrix start = worldMatrix(*mObjectRoot);
        const osg::Vec3f pivot = osg::Vec3f() * worldMatrix(*bone);
        osg::Vec3f away = direction;
        away.z() = 0.f;
        if (away.normalize() == 0.f)
            away = randomDirection(random);
        osg::Vec3f launchDir = away * 0.8f + osg::Vec3f(0, 0, 0.5f) + randomDirection(random) * 0.2f;
        launchDir.normalize();
        // Havok units (a tenth of a metre, 7 game units) per second, doubled: the original also pushes the limb
        // with the shot's impulse
        const float speed = MWWorld::ESM4GameSettings::getFloat("fCombatDismemberedLimbVelocity", 10.f) * 14.f;
        launch(*piece, start, pivot, launchDir * speed, random, groundBelow(pivot, mPtr), 6.f);
    }

    void ESM4NpcAnimation::spawnLimbGore(const BodyPart& part, const osg::Vec3f& direction, std::uint32_t seed)
    {
        const osg::Node* bone = getNode(part.mNodeName);
        if (bone == nullptr || mInsert == nullptr || mInsert->getNumParents() == 0)
            return;
        std::minstd_rand random(seed * 31u + part.mData.partType + 1u);
        osg::Group* parent = mInsert->getParent(0);
        Resource::SceneManager* sceneManager = mResourceSystem->getSceneManager();
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
        MWBase::World* world = MWBase::Environment::get().getWorld();

        const osg::Vec3f position = osg::Vec3f() * worldMatrix(*bone);
        const float groundZ = groundBelow(position, mPtr);
        const std::string& goreBoneName = part.mGoreEffectsTarget.empty() ? part.mNodeName : part.mGoreEffectsTarget;
        const osg::Node* goreBone = getNode(goreBoneName);
        const osg::Matrix goreMatrix = goreOffset(part) * worldMatrix(goreBone != nullptr ? *goreBone : *bone);
        osg::Vec3f away = direction;
        if (away.normalize() == 0.f)
            away = osg::Vec3f(0, 0, 1);

        // The burst of blood (and its sound)
        if (const ESM4::Explosion* explosion = store.get<ESM4::Explosion>().search(ESM::RefId(part.mExplExplosion)))
        {
            if (!explosion->mModel.empty())
                world->spawnEffect(VFS::Path::Normalized(meshPath(explosion->mModel.getOriginal())), {}, position,
                    1.f, false, false);
            if (!explosion->mData.sound1.isZeroOrUnset())
                MWBase::Environment::get().getSoundManager()->playSound3D(
                    position, ESM::RefId(explosion->mData.sound1), 1.f, 1.f);
        }

        auto throwPiece = [&](osg::ref_ptr<osg::Node> node, const osg::Matrix& start, float force) {
            osg::ref_ptr<osg::MatrixTransform> piece = new osg::MatrixTransform;
            piece->setName("LimbGore");
            piece->addChild(node);
            parent->addChild(piece);
            const osg::Vec3f pivot = node->getBound().center() * start;
            osg::Vec3f dir = randomDirection(random) + away * 0.5f + osg::Vec3f(0, 0, 0.9f);
            dir.normalize();
            launch(*piece, start, pivot, dir * force * uniform(random, 0.6f, 1.2f), random, groundZ,
                std::min(node->getBound().radius(), 8.f));
        };

        // Debris: meat bits
        if (const ESM4::Debris* debris = store.get<ESM4::Debris>().search(ESM::RefId(part.mExplDebris)))
        {
            int total = 0;
            for (const ESM4::Debris::Model& model : debris->mModels)
                total += model.percentage;
            const float scale = part.mData.explDebrisScale > 0.f ? part.mData.explDebrisScale : 1.f;
            for (int i = 0; i < part.mData.explDebrisCount && total > 0; ++i)
            {
                int pick = static_cast<int>(random() % static_cast<unsigned>(total));
                const ESM4::Debris::Model* chosen = &debris->mModels.front();
                for (const ESM4::Debris::Model& model : debris->mModels)
                {
                    if (pick < model.percentage)
                    {
                        chosen = &model;
                        break;
                    }
                    pick -= model.percentage;
                }
                if (chosen->model.empty())
                    continue;
                osg::ref_ptr<osg::Node> node
                    = sceneManager->getInstance(VFS::Path::Normalized(meshPath(chosen->model.getOriginal())));
                const osg::Matrix start = osg::Matrix::scale(scale, scale, scale)
                    * osg::Matrix::rotate(uniform(random, 0.f, 6.28f), randomDirection(random))
                    * osg::Matrix::translate(position + randomDirection(random) * 4.f);
                throwPiece(node, start, 400.f);
            }
        }

        // The limb replacement model: separate pieces (a head's eyes, jaw and skull), each thrown on its own
        if (!part.mLimbReplacementModel.empty())
        {
            osg::ref_ptr<osg::Node> model
                = sceneManager->getInstance(VFS::Path::Normalized(meshPath(part.mLimbReplacementModel)));
            const float scale = part.mData.limbReplacementScale > 0.f ? part.mData.limbReplacementScale : 1.f;
            const osg::Matrix rootMatrix = osg::Matrix::scale(scale, scale, scale) * goreMatrix;
            osg::Group* root = model->asGroup();
            std::vector<osg::ref_ptr<osg::Node>> children;
            if (root != nullptr)
                for (unsigned int i = 0; i < root->getNumChildren(); ++i)
                    if (root->getChild(i)->asTransform() != nullptr)
                        children.push_back(root->getChild(i));
            if (children.empty())
                throwPiece(model, rootMatrix, 300.f);
            for (osg::ref_ptr<osg::Node>& child : children)
            {
                root->removeChild(child);
                osg::ref_ptr<osg::Group> holder = new osg::Group;
                holder->setStateSet(root->getStateSet());
                holder->addChild(child);
                throwPiece(holder, rootMatrix, 300.f);
            }
        }
    }
}
