#include "esm4npcanimation.hpp"

#include <algorithm>
#include <cstdint>

#include <components/esm4/loadarma.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadeyes.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loadhair.hpp>
#include <components/esm4/loadhdpt.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadrace.hpp>

#include <span>

#include <osg/Material>
#include <osg/MatrixTransform>
#include <osg/io_utils>
#include <osg/Texture2D>
#include <osg/Transform>

#include <components/debug/debuglog.hpp>
#include <components/misc/constants.hpp>
#include <components/misc/mathutil.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/nifosg/matrixtransform.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/resource/imagemanager.hpp>
#include <components/resource/keyframemanager.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/attach.hpp>
#include <components/sceneutil/controller.hpp>
#include <components/sceneutil/keyframe.hpp>
#include <components/sceneutil/nodecallback.hpp>
#include <components/sceneutil/positionattitudetransform.hpp>
#include <components/sceneutil/riggeometry.hpp>
#include <components/sceneutil/skeleton.hpp>
#include <components/sceneutil/visitor.hpp>
#include <components/vfs/manager.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "esm4facegen.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwmechanics/esm4combat.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwworld/esmstore.hpp"

namespace MWRender
{
    namespace
    {
        class FaceCallback : public SceneUtil::NodeCallback<FaceCallback>
        {
        public:
            explicit FaceCallback(ESM4NpcAnimation* animation)
                : mAnimation(animation)
            {
            }

            void operator()(osg::Node* node, osg::NodeVisitor* nv)
            {
                const double time = nv->getFrameStamp() ? nv->getFrameStamp()->getSimulationTime() : 0.0;
                const float duration = mLastTime < 0.0 ? 0.f : static_cast<float>(time - mLastTime);
                mLastTime = time;
                mAnimation->updateFace(std::clamp(duration, 0.f, 0.1f));
                traverse(node, nv);
            }

        private:
            ESM4NpcAnimation* mAnimation;
            double mLastTime = -1.0;
        };
    }

    ESM4NpcAnimation::ESM4NpcAnimation(
        const MWWorld::Ptr& ptr, osg::ref_ptr<osg::Group> parentNode, Resource::ResourceSystem* resourceSystem)
        : Animation(ptr, std::move(parentNode), resourceSystem)
    {
        setObjectRoot(mPtr.getClass().getCorrectedModel(mPtr), true, true, false);
        updateParts();
        if (MWMechanics::ESM4Combat::isDead(mPtr))
            playDeath(true);
        if (mFace != nullptr && !mFace->empty() && mObjectRoot != nullptr)
        {
            mFaceRandom.seed(static_cast<unsigned>(reinterpret_cast<std::uintptr_t>(this)));
            mFaceCallback = new FaceCallback(this);
            mObjectRoot->addUpdateCallback(mFaceCallback);
        }
    }

    ESM4NpcAnimation::~ESM4NpcAnimation()
    {
        if (mFaceCallback != nullptr && mObjectRoot != nullptr)
            mObjectRoot->removeUpdateCallback(mFaceCallback);
    }

    void ESM4NpcAnimation::updateParts()
    {
        if (mObjectRoot == nullptr)
            return;
        if (mPtr.getType() == ESM::REC_CREA4)
        {
            updatePartsCreature();
            playStandingIdleFONV();
            return;
        }
        const ESM4::Npc* traits = MWClass::ESM4Npc::getTraitsRecord(mPtr);
        if (traits == nullptr)
            return;
        if (traits->mIsTES4)
            updatePartsTES4(*traits);
        else if (traits->mIsFONV)
        {
            updatePartsFONV(*traits);
            playStandingIdleFONV();
        }
        else
        {
            // There is no easy way to distinguish TES5 and FO3.
            // In case of FO3 the function shouldn't crash the game and will
            // only lead to the NPC not being rendered.
            updatePartsTES5(*traits);
        }
    }

    void ESM4NpcAnimation::updatePartsCreature()
    {
        const ESM4::Creature* rec = MWClass::ESM4Creature::getModelRecord(mPtr);
        if (rec == nullptr)
            return;
        // The body parts sit next to the skeleton
        const std::string_view skeleton = rec->mModel.getNormalized().value();
        const std::size_t slash = skeleton.find_last_of('/');
        const std::string dir = slash == std::string_view::npos ? std::string() : std::string(skeleton.substr(0, slash + 1));
        for (const std::string& part : rec->mNif)
            if (!part.empty())
                attachPart(dir + part);
    }

    void ESM4NpcAnimation::insertPart(std::string_view model)
    {
        if (model.empty())
            return;
        mResourceSystem->getSceneManager()->getInstance(
            Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model)), mObjectRoot.get());
    }

    template <class Record>
    static std::string_view chooseTes4EquipmentModel(const Record* rec, bool isFemale)
    {
        if (isFemale && !rec->mModelFemale.empty())
            return rec->mModelFemale.getOriginal();
        else if (!isFemale && !rec->mModelMale.empty())
            return rec->mModelMale.getOriginal();
        else
            return rec->mModel.getOriginal();
    }

    void ESM4NpcAnimation::updatePartsTES4(const ESM4::Npc& traits)
    {
        const ESM4::Race* race = MWClass::ESM4Npc::getRace(mPtr);
        bool isFemale = MWClass::ESM4Npc::isFemale(mPtr);

        // TODO: Body and head parts are placed incorrectly, need to attach to bones

        for (const ESM4::Race::BodyPart& bodyPart : (isFemale ? race->mBodyPartsFemale : race->mBodyPartsMale))
            insertPart(bodyPart.mesh);
        for (const ESM4::Race::BodyPart& bodyPart : race->mHeadParts)
            insertPart(bodyPart.mesh);
        if (!traits.mHair.isZeroOrUnset())
        {
            const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();
            if (const ESM4::Hair* hair = store->get<ESM4::Hair>().search(traits.mHair))
                insertPart(hair->mModel.getOriginal());
            else
                Log(Debug::Error) << "Hair not found: " << ESM::RefId(traits.mHair);
        }

        for (const ESM4::Armor* armor : MWClass::ESM4Npc::getEquippedArmor(mPtr))
            insertPart(chooseTes4EquipmentModel(armor, isFemale));
        for (const ESM4::Clothing* clothing : MWClass::ESM4Npc::getEquippedClothing(mPtr))
            insertPart(chooseTes4EquipmentModel(clothing, isFemale));
    }

    namespace
    {
        // Collects the shapes of a skinned part without the bone nodes the part file carries along, so that the
        // copies bind to the NPC skeleton instead of to the part's own static bones.
        class CollectRigsVisitor : public osg::NodeVisitor
        {
        public:
            CollectRigsVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void apply(osg::Drawable& drawable) override
            {
                if (!dynamic_cast<SceneUtil::RigGeometry*>(&drawable))
                    return;
                // The shape's own node carries its material and textures; anything above it is skeleton.
                const osg::NodePath& path = getNodePath();
                const osg::Node* node = &drawable;
                if (path.size() >= 3)
                    node = path[path.size() - 2];
                if (std::find(mShapes.begin(), mShapes.end(), node) == mShapes.end())
                    mShapes.push_back(node);
            }

            std::vector<const osg::Node*> mShapes;
        };
    }

    osg::ref_ptr<osg::Node> ESM4NpcAnimation::attachPart(std::string_view model)
    {
        if (model.empty() || !Misc::StringUtils::ciEndsWith(model, ".nif"))
            return nullptr;
        Resource::SceneManager* sceneManager = mResourceSystem->getSceneManager();
        osg::ref_ptr<const osg::Node> templateNode
            = sceneManager->getTemplate(Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model)));

        if (dynamic_cast<const SceneUtil::Skeleton*>(templateNode.get()))
        {
            CollectRigsVisitor collect;
            const_cast<osg::Node*>(templateNode.get())->accept(collect);
            osg::ref_ptr<osg::Group> handle = new osg::Group;
            // The shape's own transform stays: the loader pairs it with the skin transform (head meshes sit at
            // +112 on their node and -112 in their skin data), so dropping either one moves the part.
            for (const osg::Node* shape : collect.mShapes)
                handle->addChild(sceneManager->getInstance(shape));
            handle->getOrCreateUserDataContainer()->addUserObject(new Resource::TemplateRef(templateNode));
            mObjectRoot->addChild(handle);
            return handle;
        }

        // Skinned parts are bound to the NPC skeleton. The rest (hair, eyes, mouth, hats...) hang off the head bone,
        // their "Prn" parent in FO3/FONV, and are modelled in the same space as the skinned head mesh. Place them
        // with the head mesh's own binding to that bone so they follow it exactly like the skinned head does.
        constexpr std::string_view headBone = "Bip01 Head";
        const NodeMap& nodeMap = getNodeMap();
        auto found = nodeMap.find(headBone);
        if (found == nodeMap.end())
            return SceneUtil::attach(std::move(templateNode), mObjectRoot, {}, mObjectRoot, sceneManager);
        // The game keeps a head part's root transform, which the NIF reader drops; some parts need it (HairBun.NIF
        // turns its root one way and its shapes back, so without it the bun hangs in front of the face).
        osg::Matrixf root;
        if (!templateNode->getUserValue(Constants::DiscardedRootTransform, root))
            root.makeIdentity();
        osg::ref_ptr<osg::MatrixTransform> binding = new osg::MatrixTransform(root * mHeadBinding);
        found->second->addChild(binding);
        return SceneUtil::attach(std::move(templateNode), mObjectRoot, {}, binding, sceneManager);
    }

    void ESM4NpcAnimation::initHeadBinding(std::string_view headModel)
    {
        mHeadBinding = osg::Matrixf();
        if (headModel.empty())
            return;
        osg::ref_ptr<const osg::Node> head = mResourceSystem->getSceneManager()->getTemplate(
            Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(headModel)));
        CollectRigsVisitor collect;
        const_cast<osg::Node*>(head.get())->accept(collect);
        for (const osg::Node* shape : collect.mShapes)
        {
            const osg::Group* group = shape->asGroup();
            for (unsigned int i = 0; group && i < group->getNumChildren(); ++i)
            {
                const auto* rig = dynamic_cast<const SceneUtil::RigGeometry*>(group->getChild(i));
                if (const osg::Matrixf* bind = rig ? rig->getInvBindMatrix("Bip01 Head") : nullptr)
                {
                    mHeadBinding = *bind;
                    return;
                }
            }
        }
    }

    // Parts are instances of cached meshes whose state sets are shared between NPCs, so copy before changing one.
    static osg::StateSet* getUniqueStateSet(osg::Node& node)
    {
        if (const osg::StateSet* shared = node.getStateSet())
            node.setStateSet(osg::clone(shared, osg::CopyOp::SHALLOW_COPY));
        return node.getOrCreateStateSet();
    }

    static void tintHair(osg::Node& node, const ESM4::Npc::HairColour& colour)
    {
        // FO3/FONV hair textures are grey; the game colours them with the NPC's hair colour.
        const osg::Vec4f tint(colour.red / 255.f, colour.green / 255.f, colour.blue / 255.f, 1.f);
        osg::ref_ptr<osg::Material> material = new osg::Material;
        material->setColorMode(osg::Material::OFF);
        material->setDiffuse(osg::Material::FRONT_AND_BACK, tint);
        material->setAmbient(osg::Material::FRONT_AND_BACK, tint);
        osg::StateSet* stateset = getUniqueStateSet(node);
        stateset->setAttributeAndModes(material, osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);
        stateset->addUniform(new osg::Uniform("colorMode", 0), osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);
    }

    osg::ref_ptr<osg::Image> ESM4NpcAnimation::getTexture(std::string_view texture)
    {
        if (texture.empty())
            return nullptr;
        return mResourceSystem->getImageManager()->getImage(
            Misc::ResourceHelpers::correctTexturePath(VFS::Path::toNormalized(texture), *mResourceSystem->getVFS()));
    }

    void ESM4NpcAnimation::overrideDiffuse(osg::Node& node, std::string_view texture)
    {
        overrideDiffuse(node, getTexture(texture));
    }

    void ESM4NpcAnimation::overrideDiffuse(osg::Node& node, osg::ref_ptr<osg::Image> image)
    {
        if (!image)
            return;
        osg::ref_ptr<osg::Texture2D> texture2d = new osg::Texture2D(image);
        texture2d->setTextureSize(image->s(), image->t());
        texture2d->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
        texture2d->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);
        // The base texture of a BSShaderTextureSet is always bound to the first unit.
        getUniqueStateSet(node)->setTextureAttributeAndModes(
            0, texture2d, osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);
    }

    void ESM4NpcAnimation::applyFaceGen(osg::Node& node, std::string_view model, const ESM4::Npc& traits)
    {
        applyFaceGenShape(node, model, traits.mSymShapeModeCoefficients, traits.mAsymShapeModeCoefficients,
            *mResourceSystem->getVFS());
    }

    void ESM4NpcAnimation::addFaceMorphs(osg::Node& node, std::string_view model)
    {
        if (mFace == nullptr)
            mFace = std::make_unique<FaceMorphs>();
        if (mFace->add(node, model, *mResourceSystem->getVFS()))
            Log(Debug::Verbose) << "Face morphs from " << model << " on " << mPtr.toString();
    }

    namespace
    {
        // Speech morphs of the head .tri files, picked in turn while the actor talks, and how far each opens
        struct Viseme
        {
            std::string_view mMorph;
            float mWeight;
        };
        constexpr Viseme sVisemes[] = { { "Aah", 1.f }, { "BigAah", 0.7f }, { "Eh", 1.f }, { "Oh", 1.f },
            { "OohQ", 0.9f }, { "Ee", 0.9f }, { "I", 1.f }, { "K", 0.8f }, { "N", 0.8f }, { "DST", 0.8f },
            { "Th", 0.7f }, { "R", 0.8f }, { "W", 0.8f }, { "ChJSh", 0.8f }, { "FV", 0.7f }, { "BMP", 0.6f } };

        // Morph of each INFO emotion type, 1 to 7 (0 is neutral)
        constexpr std::string_view sEmotionMorphs[]
            = { "", "Anger", "Disgust", "Fear", "Sad", "Happy", "Surprise", "Pained" };
    }

    void ESM4NpcAnimation::setEmotion(int type, float value)
    {
        if (type <= 0 || type >= static_cast<int>(std::size(sEmotionMorphs)))
        {
            mEmotionValue = 0.f;
            return;
        }
        if (type != mEmotion && mFace != nullptr)
        {
            mFace->setWeight(sEmotionMorphs[mEmotion], 0.f);
            mEmotionLevel = 0.f;
        }
        mEmotion = type;
        mEmotionValue = std::clamp(value / 100.f, 0.f, 1.f);
        mSilentTime = 0.f;
    }

    void ESM4NpcAnimation::startLipSync(std::string_view voiceFile)
    {
        mLipSync = getLipSync(voiceFile, *mResourceSystem->getVFS());
        mLipSyncTime = mLipSync ? mLipSync->mLeadIn : 0.f;
        Log(Debug::Verbose) << "Lip sync for " << voiceFile << ": "
                            << (mLipSync ? std::to_string(mLipSync->mFrames.size()) + " frames" : "none");
        mSilentTime = 0.f;
    }

    void ESM4NpcAnimation::updateFace(float duration)
    {
        if (mFace == nullptr || mFace->empty())
            return;
        if (mDead)
        {
            for (const Viseme& viseme : sVisemes)
                mFace->setWeight(viseme.mMorph, 0.f);
            mFace->setWeight("BlinkLeft", 1.f);
            mFace->setWeight("BlinkRight", 1.f);
            mFace->apply();
            return;
        }
        std::uniform_real_distribution<float> random(0.f, 1.f);

        const MWBase::SoundManager* sounds = MWBase::Environment::get().getSoundManager();
        const bool talking = sounds->sayActive(mPtr);

        // The line's lip sync, if it has one, drives the mouth, brows and eyes frame by frame.
        const LipSync::Frame* lipFrame = nullptr;
        LipSync::Frame interpolated{};
        if (mLipSync != nullptr && (!talking || mLipSyncTime >= mLipSync->getDuration()))
            mLipSync = nullptr;
        if (mLipSync != nullptr)
        {
            mLipSyncTime += duration;
            const float position = std::max(0.f, mLipSyncTime * LipSync::sFrameRate);
            const std::size_t first = std::min(static_cast<std::size_t>(position), mLipSync->mFrames.size() - 1);
            const std::size_t second = std::min(first + 1, mLipSync->mFrames.size() - 1);
            const float blend = std::min(1.f, position - first);
            for (std::size_t i = 0; i < interpolated.size(); ++i)
                interpolated[i] = mLipSync->mFrames[first][i] * (1.f - blend) + mLipSync->mFrames[second][i] * blend;
            lipFrame = &interpolated;
        }

        // Without lip sync the mouth opens with the loudness of the voice line, quickly, and closes a little slower.
        const float loudness = talking ? std::clamp(sounds->getSaySoundLoudness(mPtr) * 2.f, 0.f, 1.f) : 0.f;
        const float rate = loudness > mMouthOpen ? 30.f : 12.f;
        mMouthOpen += (loudness - mMouthOpen) * std::min(1.f, duration * rate);

        // A new mouth shape every tenth of a second or so, blended in over 70 ms
        mVisemeTime -= duration;
        if (talking && mVisemeTime <= 0.f)
        {
            mPreviousViseme = mViseme;
            mViseme = (mViseme + 1 + static_cast<std::size_t>(random(mFaceRandom) * (std::size(sVisemes) - 1)))
                % std::size(sVisemes);
            mVisemeBlend = 0.f;
            mVisemeTime = 0.08f + 0.1f * random(mFaceRandom);
        }
        mVisemeBlend = std::min(1.f, mVisemeBlend + duration / 0.07f);
        if (lipFrame != nullptr)
        {
            for (std::size_t i = 0; i < sLipSyncPhonemes.size(); ++i)
                mFace->setWeight(sLipSyncPhonemes[i], (*lipFrame)[i]);
        }
        else
        {
            for (std::size_t i = 0; i < std::size(sVisemes); ++i)
            {
                float weight = 0.f;
                if (i == mViseme)
                    weight += mVisemeBlend;
                if (i == mPreviousViseme && i != mViseme)
                    weight += 1.f - mVisemeBlend;
                mFace->setWeight(sVisemes[i].mMorph, weight * mMouthOpen * sVisemes[i].mWeight);
            }
        }

        // Blinks every two to six seconds, a sixth of a second each
        mBlinkWait -= duration;
        if (mBlinkWait <= 0.f)
        {
            mBlinkWait = 2.f + 4.f * random(mFaceRandom);
            mBlinkTime = 0.f;
        }
        float blink = 0.f;
        if (mBlinkTime >= 0.f)
        {
            mBlinkTime += duration;
            constexpr float blinkLength = 0.16f;
            blink = 1.f - std::abs(mBlinkTime / blinkLength * 2.f - 1.f);
            if (mBlinkTime >= blinkLength)
            {
                mBlinkTime = -1.f;
                blink = 0.f;
            }
        }
        for (std::size_t i = 2; i < sLipSyncModifiers.size(); ++i)
            mFace->setWeight(sLipSyncModifiers[i], lipFrame ? (*lipFrame)[16 + i] : 0.f);
        mFace->setWeight("BlinkLeft", std::max(blink, lipFrame ? (*lipFrame)[16] : 0.f));
        mFace->setWeight("BlinkRight", std::max(blink, lipFrame ? (*lipFrame)[17] : 0.f));

        // Mood: shows while the line is spoken and fades a couple of seconds after
        mSilentTime = talking ? 0.f : mSilentTime + duration;
        const float mood = mSilentTime > 2.f ? 0.f : mEmotionValue;
        mEmotionLevel += (mood - mEmotionLevel) * std::min(1.f, duration * 3.f);
        if (mEmotion > 0)
            mFace->setWeight(sEmotionMorphs[mEmotion], mEmotionLevel);

        mFace->apply();
    }

    namespace
    {
        // Finds the skin-shaded shapes of an outfit, tagged by the NIF loader.
        class CollectSkinVisitor : public osg::NodeVisitor
        {
        public:
            CollectSkinVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void apply(osg::Node& node) override
            {
                bool skin = false;
                if (node.getUserValue("bsSkin", skin) && skin)
                    mNodes.push_back(&node);
                traverse(node);
            }

            std::vector<osg::Node*> mNodes;
        };

        // FO3/FONV hand FaceGen files follow the body's: UpperBodyHumanOldFemale.egt -> LeftHandOldFemale.egt
        std::string handEgt(std::string_view bodyEgt, std::string_view side)
        {
            std::string path = Misc::StringUtils::lowerCase(bodyEgt);
            std::replace(path.begin(), path.end(), '/', '\\');
            const size_t slash = path.find_last_of('\\');
            std::string name = path.substr(slash == std::string::npos ? 0 : slash + 1);
            for (std::string_view prefix : { "upperbodyhuman", "upperbody" })
            {
                if (name.starts_with(prefix))
                {
                    name.erase(0, prefix.size());
                    return path.substr(0, slash + 1) + std::string(side) + name;
                }
            }
            return {};
        }
    }

    void ESM4NpcAnimation::updatePartsFONV(const ESM4::Npc& traits)
    {
        const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();
        const ESM4::Race* race = MWClass::ESM4Npc::getRace(mPtr);
        const bool isFemale = MWClass::ESM4Npc::isFemale(mPtr);

        // The skeleton carries a facial animation helper shape that the game never draws.
        SceneUtil::FindByNameVisitor findHeadAnims("HeadAnims");
        mObjectRoot->accept(findHeadAnims);
        if (findHeadAnims.mFoundNode)
            findHeadAnims.mFoundNode->setNodeMask(0);

        initHeadBinding(race->mHeadParts.empty() ? std::string_view()
                                                 : std::string_view((isFemale ? race->mHeadPartsFemale
                                                                              : race->mHeadParts)[0].mesh));

        // Every human race shares the same skin textures; the NPC's FaceGen texture modes give it its colour, on the
        // body and hands as on the face. Race body parts: 0 upper body, 1 left hand, 2 right hand, 3 body .egt
        const std::vector<ESM4::Race::BodyPart>& bodyParts = isFemale ? race->mBodyPartsFemale : race->mBodyPartsMale;
        const VFS::Manager& vfs = *mResourceSystem->getVFS();
        auto skinTexture = [&](std::string_view texture, std::string_view egt) {
            osg::ref_ptr<osg::Image> base = getTexture(texture);
            if (!base || egt.empty())
                return base;
            osg::ref_ptr<osg::Image> skin = makeFaceGenTexture(*base, egt, traits.mSymTextureModeCoefficients, vfs);
            return skin ? skin : base;
        };
        const std::string_view bodyEgt = bodyParts.size() > 3 ? std::string_view(bodyParts[3].mesh) : std::string_view();
        osg::ref_ptr<osg::Image> bodySkin = bodyParts.size() > 0 ? skinTexture(bodyParts[0].texture, bodyEgt) : nullptr;
        osg::ref_ptr<osg::Image> leftHandSkin
            = bodyParts.size() > 1 ? skinTexture(bodyParts[1].texture, handEgt(bodyEgt, "lefthand")) : nullptr;
        osg::ref_ptr<osg::Image> rightHandSkin
            = bodyParts.size() > 2 ? skinTexture(bodyParts[2].texture, handEgt(bodyEgt, "righthand")) : nullptr;

        // Equip at most one armor per biped slot, in inventory order.
        uint32_t usedSlots = 0;
        for (const ESM4::Armor* armor : MWClass::ESM4Npc::getEquippedArmor(mPtr))
        {
            const uint32_t slots = armor->mArmorFlags & 0x000fffff;
            if (slots == 0 || (slots & usedSlots))
                continue;
            const ESM::Path& model
                = isFemale && !armor->mModelFemale.empty() ? armor->mModelFemale : armor->mModelMale;
            if (model.empty())
                continue;
            usedSlots |= slots;
            osg::ref_ptr<osg::Node> node = attachPart(model.getOriginal());
            if (!node)
                continue;
            // Bare skin in outfits is painted with the generic body or hand texture; use the NPC's instead.
            CollectSkinVisitor collectSkin;
            node->accept(collectSkin);
            for (osg::Node* skinNode : collectSkin.mNodes)
            {
                const osg::StateSet* stateset = skinNode->getStateSet();
                const osg::Texture* texture = stateset ? dynamic_cast<const osg::Texture*>(
                                                  stateset->getTextureAttribute(0, osg::StateAttribute::TEXTURE))
                                                       : nullptr;
                const osg::Image* image = texture ? texture->getImage(0) : nullptr;
                const std::string name = image ? Misc::StringUtils::lowerCase(image->getFileName()) : std::string();
                if (name.find("hand") != std::string::npos)
                    overrideDiffuse(*skinNode, leftHandSkin);
                else if (name.find("upperbody") != std::string::npos)
                    overrideDiffuse(*skinNode, bodySkin);
            }
        }

        const osg::ref_ptr<osg::Image> bodySkins[] = { bodySkin, leftHandSkin, rightHandSkin };
        constexpr uint32_t bodySlots[] = { ESM4::Armor::FO3_UpperBody, ESM4::Armor::FO3_LeftHand,
            ESM4::Armor::FO3_RightHand };
        for (size_t i = 0; i < bodyParts.size() && i < std::size(bodySlots); ++i)
        {
            if (usedSlots & bodySlots[i])
                continue;
            if (osg::ref_ptr<osg::Node> node = attachPart(bodyParts[i].mesh))
                overrideDiffuse(*node, bodySkins[i]);
        }

        if (usedSlots & ESM4::Armor::FO3_Head)
            return;

        // Race head: head, ears, mouth, lower teeth, upper teeth, tongue, left eye, right eye
        const ESM4::Eyes* eyes = traits.mEyes.isZeroOrUnset() ? nullptr : store->get<ESM4::Eyes>().search(traits.mEyes);
        const std::vector<ESM4::Race::BodyPart>& headParts = isFemale ? race->mHeadPartsFemale : race->mHeadParts;
        for (size_t i = 0; i < headParts.size(); ++i)
        {
            osg::ref_ptr<osg::Node> node = attachPart(headParts[i].mesh);
            if (!node)
                continue;
            applyFaceGen(*node, headParts[i].mesh, traits);
            addFaceMorphs(*node, headParts[i].mesh);
            // The race picks the skin (old races have their own head texture); the NPC's EYES record picks the
            // eye colour.
            if (eyes && (i == 6 || i == 7))
                overrideDiffuse(*node, eyes->mIcon);
            else if (osg::ref_ptr<osg::Image> skin = getTexture(headParts[i].texture))
            {
                // The NPC's complexion is morphed onto the race's face texture.
                osg::ref_ptr<osg::Image> face = makeFaceGenTexture(
                    *skin, headParts[i].mesh, traits.mSymTextureModeCoefficients, *mResourceSystem->getVFS());
                overrideDiffuse(*node, face ? face : skin);
            }
        }

        for (ESM::FormId partId : traits.mHeadParts)
        {
            if (partId.isZeroOrUnset())
                continue;
            const ESM4::HeadPart* part = store->get<ESM4::HeadPart>().search(partId);
            if (part == nullptr)
            {
                Log(Debug::Error) << "Head part not found: " << ESM::RefId(partId);
                continue;
            }
            osg::ref_ptr<osg::Node> node = attachPart(part->mModel.getOriginal());
            if (!node)
                continue;
            applyFaceGen(*node, part->mModel.getOriginal(), traits);
            addFaceMorphs(*node, part->mModel.getOriginal());
            // Eyebrows and beards live next to the hair meshes and take the hair colour too.
            if (part->mModel.getNormalized().value().starts_with("characters/hair/"))
                tintHair(*node, traits.mHairColour);
        }

        if (!traits.mHair.isZeroOrUnset() && !(usedSlots & ESM4::Armor::FO3_Hair))
        {
            const ESM4::Hair* hair = store->get<ESM4::Hair>().search(traits.mHair);
            if (hair == nullptr)
                Log(Debug::Error) << "Hair not found: " << ESM::RefId(traits.mHair);
            else if (osg::ref_ptr<osg::Node> node = attachPart(hair->mModel.getOriginal()))
            {
                applyFaceGen(*node, hair->mModel.getOriginal(), traits);
                // Hair meshes carry a full and a trimmed variant; show the one that fits under a hat.
                const bool hat = usedSlots & ESM4::Armor::FO3_Hat;
                SceneUtil::FindByNameVisitor findHidden(hat ? "NoHat" : "Hat");
                node->accept(findHidden);
                if (findHidden.mFoundNode)
                    findHidden.mFoundNode->setNodeMask(0);
                tintHair(*node, traits.mHairColour);
                // Several hair styles share one mesh and differ only by texture (e.g. balding).
                overrideDiffuse(*node, hair->mIcon);
            }
        }
    }

    namespace
    {
        // Holds a bone at its rest position in the horizontal plane. Locomotion sequences move the accumulation root
        // ("Bip01") forward over a cycle; the actor itself is moved by the AI instead.
        class StripHorizontalMotion : public SceneUtil::NodeCallback<StripHorizontalMotion, NifOsg::MatrixTransform*>
        {
        public:
            explicit StripHorizontalMotion(const osg::Vec3f& rest)
                : mRest(rest)
            {
            }

            void operator()(NifOsg::MatrixTransform* node, osg::NodeVisitor* nv)
            {
                osg::Vec3f translation = node->getMatrix().getTrans();
                translation.x() = mRest.x();
                translation.y() = mRest.y();
                node->setTranslation(translation);
                traverse(node, nv);
            }

        private:
            osg::Vec3f mRest;
        };

        // Rotation a NIF transform was given, without whatever the head tracking put on its matrix since
        osg::Quat getNifRotation(const NifOsg::MatrixTransform& node)
        {
            osg::Matrixf rotation;
            for (int i = 0; i < 3; ++i)
                for (int j = 0; j < 3; ++j)
                    rotation(i, j) = node.mRotationScale.mValues[j][i];
            return rotation.getRotate();
        }

        // Eases a bone from the pose it had when a sequence was replaced into the pose the new sequence gives it
        // (or the rest pose, for a bone the new sequence leaves alone), as the original engine blends sequences
        // over fAnimationDefaultBlend instead of cutting from one to the next.
        class BlendFromPose : public SceneUtil::NodeCallback<BlendFromPose, NifOsg::MatrixTransform*>
        {
        public:
            // from: the bone's pose when the sequence was replaced. rest: its pose in the skeleton, which a bone
            // the new sequence has no track (or no translation or rotation keys) for goes back to.
            BlendFromPose(const osg::Vec3f& fromTranslation, const osg::Quat& fromRotation,
                const osg::Vec3f& restTranslation, const osg::Quat& restRotation, float duration)
                : mFromTranslation(fromTranslation)
                , mFromRotation(fromRotation)
                , mRestTranslation(restTranslation)
                , mRestRotation(restRotation)
                , mDuration(duration)
            {
            }

            void operator()(NifOsg::MatrixTransform* node, osg::NodeVisitor* nv)
            {
                const double now = nv->getFrameStamp() ? nv->getFrameStamp()->getSimulationTime() : 0.0;
                if (!mStart)
                    mStart = now;
                // What the sequence posed the bone in this frame; where it didn't write over the blend of the
                // frame before, the bone is headed for its rest pose
                osg::Vec3f translation = node->getMatrix().getTrans();
                osg::Quat rotation = getNifRotation(*node);
                if (mWritten && translation == mWrittenTranslation)
                    translation = mRestTranslation;
                if (mWritten && rotation == mWrittenRotation)
                    rotation = mRestRotation;
                if (!mDone)
                {
                    const float t = std::min(1.f, static_cast<float>(now - *mStart) / mDuration);
                    const float weight = t * t * (3.f - 2.f * t);
                    osg::Quat blended;
                    blended.slerp(weight, mFromRotation, rotation);
                    node->setRotation(blended);
                    node->setTranslation(mFromTranslation * (1.f - weight) + translation * weight);
                    mWrittenTranslation = node->getMatrix().getTrans();
                    mWrittenRotation = getNifRotation(*node);
                    mWritten = true;
                    mDone = t >= 1.f;
                }
                traverse(node, nv);
            }

        private:
            osg::Vec3f mFromTranslation;
            osg::Quat mFromRotation;
            osg::Vec3f mRestTranslation;
            osg::Quat mRestRotation;
            float mDuration;
            std::optional<double> mStart;
            bool mWritten = false;
            bool mDone = false;
            osg::Vec3f mWrittenTranslation;
            osg::Quat mWrittenRotation;
        };

        class LookCallback : public SceneUtil::NodeCallback<LookCallback, osg::MatrixTransform*>
        {
        public:
            explicit LookCallback(ESM4NpcAnimation* animation)
                : mAnimation(animation)
            {
            }

            void operator()(osg::MatrixTransform* node, osg::NodeVisitor* nv)
            {
                const double time = nv->getFrameStamp() ? nv->getFrameStamp()->getSimulationTime() : 0.0;
                const float duration = mLastTime < 0.0 ? 0.f : static_cast<float>(time - mLastTime);
                mLastTime = time;
                mAnimation->updateLook(*node, std::clamp(duration, 0.f, 0.1f));
                traverse(node, nv);
            }

        private:
            ESM4NpcAnimation* mAnimation;
            double mLastTime = -1.0;
        };
    }

    namespace
    {
        // Loop time that runs at a rate the AI can change while the loop plays, so the walk keeps pace with the
        // actor's speed.
        class RateTimeSource : public SceneUtil::ControllerSource
        {
        public:
            explicit RateTimeSource(std::shared_ptr<const float> rate)
                : mRate(std::move(rate))
            {
            }

            float getValue(osg::NodeVisitor* nv) override
            {
                const double now = nv->getFrameStamp()->getSimulationTime();
                if (mLast)
                    mTime += (now - *mLast) * *mRate;
                mLast = now;
                return static_cast<float>(mTime);
            }

        private:
            std::shared_ptr<const float> mRate;
            double mTime = 0;
            std::optional<double> mLast;
        };

        // Plays a sequence once, backwards when asked, and holds the frame it ends on.
        class OnceTimeSource : public SceneUtil::ControllerSource
        {
        public:
            OnceTimeSource(bool reverse, bool skipToEnd)
                : mReverse(reverse)
                , mSkipToEnd(skipToEnd)
            {
            }

            float getValue(osg::NodeVisitor* nv) override
            {
                const double now = nv->getFrameStamp()->getSimulationTime();
                if (!mStart)
                    mStart = now;
                const float elapsed
                    = mSkipToEnd ? mDuration : std::min(mDuration, static_cast<float>(now - *mStart));
                return mReverse ? mDuration - elapsed : elapsed;
            }

            float mDuration = 0.f;

        private:
            bool mReverse;
            bool mSkipToEnd;
            std::optional<double> mStart;
        };
    }

    namespace
    {
        // Sequence time counted from the frame the sequence started on, so one-shot sequences (furniture entries,
        // special idles) begin at their first key; looping ones cycle on from there.
        class RelativeTimeSource : public SceneUtil::ControllerSource
        {
        public:
            float getValue(osg::NodeVisitor* nv) override
            {
                const double now = nv->getFrameStamp()->getSimulationTime();
                if (!mStart)
                    mStart = now;
                return static_cast<float>(now - *mStart);
            }

        private:
            std::optional<double> mStart;
        };
    }

    void ESM4NpcAnimation::playStandingIdleFONV()
    {
        playLoopFONV("mtidle.kf", false);
    }

    void ESM4NpcAnimation::setLocomotion(Locomotion locomotion, bool force)
    {
        if (mDead)
            return;
        if (locomotion == mLocomotion && !force)
            return;
        mLocomotion = locomotion;
        // Forcing cuts a one-off sequence short (a furniture or idle sequence is over)
        if (force)
            mInAction = false;
        // An attack or other one-off sequence finishes first, resumeLocomotion picks the loop up again.
        if (!mInAction)
            playLocomotion();
    }

    float ESM4NpcAnimation::playIdleFONV(std::string_view model, bool keepRootMotion)
    {
        if (mDead)
            return 0.f;
        const VFS::Path::Normalized path = Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model));
        if (!mResourceSystem->getVFS()->exists(path))
        {
            Log(Debug::Verbose) << "No " << path << " for " << mPtr.getCellRef().getRefId();
            return 0.f;
        }
        // Replaces any attack in progress; the caller resumes the locomotion when it is done
        mInAction = false;
        return playKeyframesFONV(
            path, std::make_shared<RelativeTimeSource>(), !keepRootMotion, sDefaultBlendTime, keepRootMotion);
    }

    void ESM4NpcAnimation::resumeLocomotion()
    {
        if (!mInAction || mDead)
            return;
        mInAction = false;
        playLocomotion();
    }

    float ESM4NpcAnimation::playActionFONV(std::string_view file)
    {
        if (mDead)
            return 0.f;
        // Attacks sit next to the skeleton, idles in idleanims/
        const VFS::Path::Normalized skeletonPath = mPtr.getClass().getCorrectedModel(mPtr);
        const std::string_view skeleton = skeletonPath.value();
        const std::size_t slash = skeleton.find_last_of('/');
        if (slash == std::string_view::npos)
            return 0.f;
        const std::string dir = std::string(skeleton.substr(0, slash + 1));
        VFS::Path::Normalized path(dir + std::string(file));
        if (!mResourceSystem->getVFS()->exists(path))
            path = VFS::Path::Normalized(dir + "idleanims/" + std::string(file));
        if (!mResourceSystem->getVFS()->exists(path))
        {
            Log(Debug::Verbose) << "No " << file << " for " << mPtr.getCellRef().getRefId();
            return 0.f;
        }
        const auto source = std::make_shared<OnceTimeSource>(false, false);
        source->mDuration = playKeyframesFONV(path, source, true);
        mInAction = source->mDuration > 0.f;
        if (!mInAction)
            playLocomotion();
        return source->mDuration;
    }

    void ESM4NpcAnimation::playLocomotion()
    {
        switch (mLocomotion)
        {
            case Locomotion::Idle:
                playLoopFONV(mIdleSequence.empty() ? std::string_view("mtidle.kf") : mIdleSequence, false);
                break;
            case Locomotion::Walk:
                playLoopFONV("mtforward.kf", true);
                break;
            case Locomotion::Run:
                playLoopFONV("mtfastforward.kf", true);
                break;
        }
    }

    void ESM4NpcAnimation::setIdleSequence(std::string_view file)
    {
        if (file == mIdleSequence)
            return;
        mIdleSequence = file;
        if (mLocomotion == Locomotion::Idle && !mInAction && !mDead)
            playLocomotion();
    }

    void ESM4NpcAnimation::showWeapon(std::string_view model)
    {
        if (mWeapon != nullptr)
        {
            for (osg::Group* parent : mWeapon->getParents())
                parent->removeChild(mWeapon);
            mWeapon = nullptr;
        }
        if (model.empty() || mObjectRoot == nullptr)
            return;
        // FO3/FONV skeletons carry a "Weapon" bone in the right hand that weapon models are made to sit on. It has
        // no controller, so it may not be a transform the node map knows.
        osg::Group* bone = nullptr;
        SceneUtil::FindByNameVisitor findWeaponBone("Weapon");
        mObjectRoot->accept(findWeaponBone);
        bone = findWeaponBone.mFoundNode;
        if (bone == nullptr)
        {
            const NodeMap& nodeMap = getNodeMap();
            if (auto found = nodeMap.find("Bip01 R Hand"); found != nodeMap.end())
                bone = found->second;
        }
        if (bone == nullptr)
        {
            Log(Debug::Verbose) << "No weapon bone for " << mPtr.getCellRef().getRefId();
            return;
        }
        Resource::SceneManager* sceneManager = mResourceSystem->getSceneManager();
        osg::ref_ptr<const osg::Node> templateNode
            = sceneManager->getTemplate(Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model)));
        // Weapon files can carry bones of their own (SceneUtil::attach would then look for skinned shapes only), so
        // the whole model hangs off the bone as it is.
        mWeapon = sceneManager->getInstance(templateNode);
        bone->addChild(mWeapon);
    }

    void ESM4NpcAnimation::playDeath(bool instant)
    {
        if (mDead)
            return;
        mDead = true;
        showWeapon({});
        // The original engine drops the body as a ragdoll. Without one, a creature's get-up sequence played backwards
        // lays it down; humans have death poses.
        const VFS::Path::Normalized skeletonPath = mPtr.getClass().getCorrectedModel(mPtr);
        const std::string_view skeleton = skeletonPath.value();
        const std::size_t slash = skeleton.find_last_of('/');
        if (slash == std::string_view::npos)
            return;
        const std::string idles = std::string(skeleton.substr(0, slash)) + "/idleanims/";
        // Get-up sequences start lying down; death poses are the lying pose itself.
        static constexpr std::string_view getUpFiles[] = { "getup.kf", "specialidle_getupfaceup.kf",
            "specialidle_getup.kf", "getupleft.kf", "mtspecialidle_getupleft.kf", "specialidle_getupleft.kf" };
        static constexpr std::string_view poseFiles[] = { "deathpose1.kf", "deathpose2.kf" };
        const VFS::Manager& vfs = *mResourceSystem->getVFS();
        auto findFile = [&](std::span<const std::string_view> names) -> std::optional<VFS::Path::Normalized> {
            for (std::string_view name : names)
            {
                VFS::Path::Normalized path(idles + std::string(name));
                if (vfs.exists(path))
                    return path;
            }
            return std::nullopt;
        };
        const std::optional<VFS::Path::Normalized> getUp = findFile(getUpFiles);
        const std::optional<VFS::Path::Normalized> pose = getUp ? std::nullopt : findFile(poseFiles);
        if (!getUp && !pose)
        {
            Log(Debug::Verbose) << "No death sequence for " << mPtr.getCellRef().getRefId();
            return;
        }
        const auto source = std::make_shared<OnceTimeSource>(getUp.has_value(), instant);
        source->mDuration
            = playKeyframesFONV(getUp ? *getUp : *pose, source, false, instant ? 0.f : sDefaultBlendTime);
    }

    bool ESM4NpcAnimation::isFemale() const
    {
        return mPtr.getType() == ESM::REC_NPC_4 && MWClass::ESM4Npc::isFemale(mPtr);
    }

    void ESM4NpcAnimation::setLocomotionRate(float rate)
    {
        *mLocomotionRate = rate;
    }

    float ESM4NpcAnimation::getLocomotionSpeed() const
    {
        return mLocomotionSpeed;
    }

    void ESM4NpcAnimation::playLoopFONV(std::string_view file, bool stripRootMotion)
    {
        // TODO: drive this through the character controller once FONV animation groups are mapped. For now loop the
        // sequences that sit next to the skeleton so NPCs don't stand in the bind pose.
        const VFS::Path::Normalized skeletonPath = mPtr.getClass().getCorrectedModel(mPtr);
        const std::string_view skeleton = skeletonPath.value();
        const size_t slash = skeleton.find_last_of('/');
        if (slash == std::string_view::npos)
            return;
        // Walks and runs are per sex (locomotion/male, locomotion/female), the idle is shared
        const std::string dir = std::string(skeleton.substr(0, slash)) + "/locomotion/";
        VFS::Path::Normalized path(
            dir + (isFemale() ? "female/" : "male/") + std::string(file));
        if (!mResourceSystem->getVFS()->exists(path))
            path = VFS::Path::Normalized(dir + std::string(file));
        // Creatures keep their idle next to the skeleton (creatures/nvgecko/mtidle.kf)
        if (!mResourceSystem->getVFS()->exists(path))
            path = VFS::Path::Normalized(std::string(skeleton.substr(0, slash + 1)) + std::string(file));
        if (!mResourceSystem->getVFS()->exists(path))
        {
            Log(Debug::Verbose) << "No " << path << " for " << mPtr.getCellRef().getRefId();
            return;
        }

        std::shared_ptr<SceneUtil::ControllerSource> source;
        if (stripRootMotion)
            source = std::make_shared<RateTimeSource>(mLocomotionRate);
        else
            source = std::make_shared<SceneUtil::FrameTimeSource>();
        playKeyframesFONV(path, source, stripRootMotion);
    }

    float ESM4NpcAnimation::playKeyframesFONV(const VFS::Path::Normalized& path,
        std::shared_ptr<SceneUtil::ControllerSource> source, bool stripRootMotion, float blendTime,
        bool keepsRootMotion)
    {
        osg::ref_ptr<const SceneUtil::KeyframeHolder> keyframes = mResourceSystem->getKeyframeManager()->get(path);
        const NodeMap& nodeMap = getNodeMap();
        float duration = 0.f;

        // The pose the previous sequence left each bone in, to blend from. Not for the roots when either sequence
        // carries the actor with them (a furniture entry or exit): the actor is moved onto the seat as the next
        // sequence starts, and the roots must jump with it.
        std::map<NifOsg::MatrixTransform*, RestPose> blendFrom;
        if (blendTime > 0.f)
        {
            for (auto& [node, callback] : mLoopCallbacks)
            {
                auto* transform = dynamic_cast<NifOsg::MatrixTransform*>(node.get());
                if (transform == nullptr || blendFrom.contains(transform))
                    continue;
                const std::string& name = transform->getName();
                if ((keepsRootMotion || mKeepsRootMotion) && (name == "Bip01" || name == "Bip01 NonAccum"))
                    continue;
                blendFrom[transform] = { transform->getMatrix().getTrans(), getNifRotation(*transform) };
            }
        }

        // Drop the sequence played before, and put its bones back at rest: bones the new sequence doesn't drive
        // would otherwise keep the last pose, e.g. the walk's root lift on "Bip01 NonAccum" once the idle (which
        // lifts "Bip01" instead) takes over, leaving the NPC floating.
        for (auto& [node, callback] : mLoopCallbacks)
        {
            node->removeUpdateCallback(callback);
            if (auto* transform = dynamic_cast<NifOsg::MatrixTransform*>(node.get()))
            {
                // Rotation too: a furniture entry leaves "Bip01 NonAccum" turned around
                if (auto rest = mRestPoses.find(transform); rest != mRestPoses.end())
                {
                    transform->setRotation(rest->second.mRotation);
                    transform->setTranslation(rest->second.mTranslation);
                }
                else
                    transform->setRotation(transform->mRotationScale);
            }
        }
        mLoopCallbacks.clear();

        const bool hasAccumRootTrack = keyframes->mKeyframeControllers.contains("Bip01");
        mLocomotionSpeed = 0.f;
        mRootMotion = osg::Vec3f();
        std::size_t bound = 0;
        for (const auto& [name, controller] : keyframes->mKeyframeControllers)
        {
            // Without movement accumulation, "Bip01 NonAccum" carries the whole root offset, so it belongs on the
            // accumulation root that holds the pelvis height in the skeleton.
            const std::string_view target
                = !hasAccumRootTrack && name == "Bip01 NonAccum" ? std::string_view("Bip01") : std::string_view(name);
            auto found = nodeMap.find(target);
            if (found == nodeMap.end())
            {
                Log(Debug::Verbose) << "  no node " << target;
                continue;
            }
            auto* transform = dynamic_cast<NifOsg::MatrixTransform*>(found->second.get());
            if (transform == nullptr)
            {
                Log(Debug::Verbose) << "  not a NIF transform: " << target << " " << found->second->className();
                continue;
            }
            // The skeleton's own transform controllers have no time source and would reset the bone every frame.
            osg::Callback* callback = transform->getUpdateCallback();
            while (callback != nullptr)
            {
                osg::Callback* next = callback->getNestedCallback();
                if (dynamic_cast<SceneUtil::KeyframeController*>(callback))
                    transform->removeUpdateCallback(callback);
                callback = next;
            }
            if (!mRestPoses.contains(transform))
                mRestPoses[transform] = { transform->getMatrix().getTrans(), transform->getMatrix().getRotate() };

            osg::ref_ptr<SceneUtil::KeyframeController> cloned = osg::clone(controller.get(), osg::CopyOp::SHALLOW_COPY);
            cloned->setSource(source);
            transform->addUpdateCallback(cloned->getAsCallback());
            mLoopCallbacks.emplace_back(transform, cloned->getAsCallback());
            ++bound;
            if (const std::shared_ptr<SceneUtil::ControllerFunction> function = cloned->getFunction())
                duration = std::max(duration, function->getMaximum());

            if (target == "Bip01")
            {
                // Distance the root covers over the sequence: the speed of a locomotion cycle (so feet don't
                // slide), or where a furniture entry leaves the actor
                if (const std::shared_ptr<SceneUtil::ControllerFunction> function = cloned->getFunction())
                {
                    const float cycle = function->getMaximum();
                    if (cycle > 0.f)
                    {
                        osg::Vec3f delta = controller->getTranslation(cycle) - controller->getTranslation(0.f);
                        delta.z() = 0.f;
                        mRootMotion = delta;
                        if (stripRootMotion)
                            mLocomotionSpeed = delta.length() / cycle;
                        Log(Debug::Verbose) << "Root track " << name << " moves " << delta << " over " << cycle;
                    }
                }
                if (stripRootMotion)
                {
                    osg::ref_ptr<osg::Callback> strip = new StripHorizontalMotion(mRestPoses[transform].mTranslation);
                    transform->addUpdateCallback(strip);
                    mLoopCallbacks.emplace_back(transform, strip);
                }
            }
        }
        mKeepsRootMotion = keepsRootMotion;

        // Last on each bone, after the new tracks (and the root's motion stripping) have posed it
        for (const auto& [transform, from] : blendFrom)
        {
            const auto rest = mRestPoses.find(transform);
            if (rest == mRestPoses.end())
                continue;
            osg::ref_ptr<osg::Callback> blend = new BlendFromPose(
                from.mTranslation, from.mRotation, rest->second.mTranslation, rest->second.mRotation, blendTime);
            transform->addUpdateCallback(blend);
            mLoopCallbacks.emplace_back(transform, blend);
        }
        attachLookCallback();

        Log(Debug::Verbose) << "Playing " << path << " on " << mPtr.getCellRef().getRefId() << ": " << bound << "/"
                            << keyframes->mKeyframeControllers.size() << " tracks bound, root accum track "
                            << hasAccumRootTrack << ", speed " << mLocomotionSpeed;
        return duration;
    }

    std::optional<osg::Vec3f> ESM4NpcAnimation::getHeadPosition() const
    {
        const osg::Node* head = getNode("Bip01 Head");
        if (head == nullptr)
            return std::nullopt;
        const osg::NodePathList paths = head->getParentalNodePaths();
        if (paths.empty())
            return std::nullopt;
        return osg::Vec3f(osg::computeLocalToWorld(paths[0]).getTrans());
    }

    void ESM4NpcAnimation::attachLookCallback()
    {
        if (mLookBone == nullptr)
        {
            const NodeMap& nodeMap = getNodeMap();
            auto found = nodeMap.find("Bip01 Head");
            if (found == nodeMap.end())
                return;
            mLookBone = found->second;
            mLookCallback = new LookCallback(this);
        }
        mLookBone->removeUpdateCallback(mLookCallback);
        mLookBone->addUpdateCallback(mLookCallback);
    }

    void ESM4NpcAnimation::updateLook(osg::MatrixTransform& head, float duration)
    {
        // Where the target is from the actor, as yaw and pitch; the head turns no further than a neck would
        // (the limits of OpenMW's own head tracking) and gives up on a target behind the actor.
        float yaw = 0.f;
        float pitch = 0.f;
        if (mLookTarget && !mDead && mPtr.getRefData().getBaseNode() != nullptr)
        {
            if (const std::optional<osg::Vec3f> headPosition = getHeadPosition())
            {
                osg::Vec3f direction = *mLookTarget - *headPosition;
                if (direction.normalize() > 0.f)
                {
                    const osg::Vec3f facing = mPtr.getRefData().getBaseNode()->getAttitude() * osg::Vec3f(0, 1, 0);
                    yaw = static_cast<float>(Misc::normalizeAngle(
                        std::atan2(facing.x(), facing.y()) - std::atan2(direction.x(), direction.y())));
                    if (std::abs(yaw) > osg::DegreesToRadians(110.f))
                        yaw = 0.f;
                    else
                    {
                        yaw *= 1.f - direction.z() * direction.z();
                        pitch = std::asin(direction.z());
                    }
                }
            }
        }
        const float yawLimit = osg::DegreesToRadians(60.f);
        const float pitchLimit = osg::DegreesToRadians(35.f);
        yaw = std::clamp(yaw, -yawLimit, yawLimit);
        pitch = std::clamp(pitch, -pitchLimit, pitchLimit);
        const float factor = std::min(1.f, duration * 4.f);
        mLookYaw += (yaw - mLookYaw) * factor;
        mLookPitch += (pitch - mLookPitch) * factor;
        if (std::abs(mLookYaw) < 1e-4f && std::abs(mLookPitch) < 1e-4f)
            return;

        // The sequence's own rotation of the head, turned in the actor's space (as MWRender::RotateController
        // does, but from the NIF rotation so the turn doesn't pile up on bones no track drives)
        auto* nifHead = dynamic_cast<NifOsg::MatrixTransform*>(&head);
        if (nifHead == nullptr || head.getNumParents() == 0)
            return;
        const osg::NodePathList paths = head.getParent(0)->getParentalNodePaths(mObjectRoot.get());
        if (paths.empty())
            return;
        const osg::Quat parent = osg::computeLocalToWorld(paths[0]).getRotate();
        const osg::Quat turn = osg::Quat(mLookPitch, osg::Vec3f(1, 0, 0)) * osg::Quat(mLookYaw, osg::Vec3f(0, 0, 1));
        const osg::Quat rotation = getNifRotation(*nifHead) * parent * turn * parent.inverse();
        osg::Matrix matrix = head.getMatrix();
        matrix.setRotate(rotation);
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                matrix(i, j) *= nifHead->mScale;
        head.setMatrix(matrix);
    }

    void ESM4NpcAnimation::insertHeadParts(
        const std::vector<ESM::FormId>& partIds, std::set<uint32_t>& usedHeadPartTypes)
    {
        const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();
        for (ESM::FormId partId : partIds)
        {
            if (partId.isZeroOrUnset())
                continue;
            const ESM4::HeadPart* part = store->get<ESM4::HeadPart>().search(partId);
            if (!part)
            {
                Log(Debug::Error) << "Head part not found: " << ESM::RefId(partId);
                continue;
            }
            if (usedHeadPartTypes.emplace(part->mType).second)
                insertPart(part->mModel.getOriginal());
        }
    }

    void ESM4NpcAnimation::updatePartsTES5(const ESM4::Npc& traits)
    {
        const MWWorld::ESMStore* store = MWBase::Environment::get().getESMStore();

        const ESM4::Race* race = MWClass::ESM4Npc::getRace(mPtr);
        bool isFemale = MWClass::ESM4Npc::isFemale(mPtr);

        std::vector<const ESM4::ArmorAddon*> armorAddons;

        auto findArmorAddons = [&](const ESM4::Armor* armor) {
            for (ESM::FormId armaId : armor->mAddOns)
            {
                if (armaId.isZeroOrUnset())
                    continue;
                const ESM4::ArmorAddon* arma = store->get<ESM4::ArmorAddon>().search(armaId);
                if (!arma)
                {
                    Log(Debug::Error) << "ArmorAddon not found: " << ESM::RefId(armaId);
                    continue;
                }
                bool compatibleRace = arma->mRacePrimary == traits.mRace;
                for (auto r : arma->mRaces)
                    if (r == traits.mRace)
                        compatibleRace = true;
                if (compatibleRace)
                    armorAddons.push_back(arma);
            }
        };

        for (const ESM4::Armor* armor : MWClass::ESM4Npc::getEquippedArmor(mPtr))
            findArmorAddons(armor);
        if (!traits.mWornArmor.isZeroOrUnset())
        {
            if (const ESM4::Armor* armor = store->get<ESM4::Armor>().search(traits.mWornArmor))
                findArmorAddons(armor);
            else
                Log(Debug::Error) << "Worn armor not found: " << ESM::RefId(traits.mWornArmor);
        }
        if (!race->mSkin.isZeroOrUnset())
        {
            if (const ESM4::Armor* armor = store->get<ESM4::Armor>().search(race->mSkin))
                findArmorAddons(armor);
            else
                Log(Debug::Error) << "Skin not found: " << ESM::RefId(race->mSkin);
        }

        if (isFemale)
            std::sort(armorAddons.begin(), armorAddons.end(),
                [](auto x, auto y) { return x->mFemalePriority > y->mFemalePriority; });
        else
            std::sort(armorAddons.begin(), armorAddons.end(),
                [](auto x, auto y) { return x->mMalePriority > y->mMalePriority; });

        uint32_t usedParts = 0;
        for (const ESM4::ArmorAddon* arma : armorAddons)
        {
            const uint32_t covers = arma->mBodyTemplate.bodyPart;
            // if body is already covered, skip to avoid clipping
            if (covers & usedParts & ESM4::Armor::TES5_Body)
                continue;
            // if covers at least something that wasn't covered before - add model
            if (covers & ~usedParts)
            {
                usedParts |= covers;
                insertPart(isFemale ? arma->mModelFemale.getOriginal() : arma->mModelMale.getOriginal());
            }
        }

        std::set<uint32_t> usedHeadPartTypes;
        if (usedParts & ESM4::Armor::TES5_Hair)
            usedHeadPartTypes.insert(ESM4::HeadPart::Type_Hair);
        insertHeadParts(traits.mHeadParts, usedHeadPartTypes);
        insertHeadParts(isFemale ? race->mHeadPartIdsFemale : race->mHeadPartIdsMale, usedHeadPartTypes);
    }
}
