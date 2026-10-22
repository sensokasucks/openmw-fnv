#include "esm4npcanimation.hpp"

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
#include <osg/io_utils>
#include <osg/Texture2D>
#include <osg/Transform>

#include <components/debug/debuglog.hpp>
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
#include <components/sceneutil/riggeometry.hpp>
#include <components/sceneutil/skeleton.hpp>
#include <components/sceneutil/visitor.hpp>
#include <components/vfs/manager.hpp>

#include "../mwbase/environment.hpp"
#include "esm4facegen.hpp"
#include "../mwclass/esm4creature.hpp"
#include "../mwmechanics/esm4combat.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwworld/esmstore.hpp"

namespace MWRender
{
    ESM4NpcAnimation::ESM4NpcAnimation(
        const MWWorld::Ptr& ptr, osg::ref_ptr<osg::Group> parentNode, Resource::ResourceSystem* resourceSystem)
        : Animation(ptr, std::move(parentNode), resourceSystem)
    {
        setObjectRoot(mPtr.getClass().getCorrectedModel(mPtr), true, true, false);
        updateParts();
        if (MWMechanics::ESM4Combat::isDead(mPtr))
            playDeath(true);
    }

    void ESM4NpcAnimation::updateParts()
    {
        if (mObjectRoot == nullptr)
            return;
        if (mPtr.getType() == ESM::REC_CREA4)
        {
            updatePartsCreature();
            playIdleFONV();
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
            playIdleFONV();
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
            for (const osg::Node* shape : collect.mShapes)
                handle->addChild(sceneManager->getInstance(shape));
            handle->getOrCreateUserDataContainer()->addUserObject(new Resource::TemplateRef(templateNode));
            mObjectRoot->addChild(handle);
            return handle;
        }

        // Skinned parts are bound to the NPC skeleton. The rest (hair, eyes, mouth...) hang off the head bone, which
        // is their "Prn" parent in FO3/FONV, but are modelled upright in skeleton axes like the skinned head.
        constexpr std::string_view headBone = "Bip01 Head";
        const NodeMap& nodeMap = getNodeMap();
        auto found = nodeMap.find(headBone);
        if (found == nodeMap.end())
            return SceneUtil::attach(std::move(templateNode), mObjectRoot, {}, mObjectRoot, sceneManager);
        if (!mHeadAttitude)
        {
            // The skeleton is still in its bind pose here.
            const osg::NodePathList paths = found->second->getParentalNodePaths(mObjectRoot);
            mHeadAttitude = paths.empty() ? osg::Quat() : osg::computeLocalToWorld(paths.front()).getRotate().inverse();
        }
        return SceneUtil::attach(
            std::move(templateNode), mObjectRoot, {}, found->second, sceneManager, &*mHeadAttitude);
    }

    static void tintHair(osg::Node& node, const ESM4::Npc::HairColour& colour)
    {
        // FO3/FONV hair textures are grey; the game colours them with the NPC's hair colour.
        const osg::Vec4f tint(colour.red / 255.f, colour.green / 255.f, colour.blue / 255.f, 1.f);
        osg::ref_ptr<osg::Material> material = new osg::Material;
        material->setColorMode(osg::Material::OFF);
        material->setDiffuse(osg::Material::FRONT_AND_BACK, tint);
        material->setAmbient(osg::Material::FRONT_AND_BACK, tint);
        osg::StateSet* stateset = node.getOrCreateStateSet();
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
        node.getOrCreateStateSet()->setTextureAttributeAndModes(
            0, texture2d, osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);
    }

    void ESM4NpcAnimation::applyFaceGen(osg::Node& node, std::string_view model, const ESM4::Npc& traits)
    {
        applyFaceGenShape(node, model, traits.mSymShapeModeCoefficients, traits.mAsymShapeModeCoefficients,
            *mResourceSystem->getVFS());
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
            attachPart(model.getOriginal());
        }

        // Race body: 0 upper body, 1 left hand, 2 right hand, 3 body texture (.egt)
        const std::vector<ESM4::Race::BodyPart>& bodyParts = isFemale ? race->mBodyPartsFemale : race->mBodyPartsMale;
        constexpr uint32_t bodySlots[] = { ESM4::Armor::FO3_UpperBody, ESM4::Armor::FO3_LeftHand,
            ESM4::Armor::FO3_RightHand };
        for (size_t i = 0; i < bodyParts.size() && i < std::size(bodySlots); ++i)
        {
            if (usedSlots & bodySlots[i])
                continue;
            // Races share body meshes and set their own skin with the part's texture
            if (osg::ref_ptr<osg::Node> node = attachPart(bodyParts[i].mesh))
                overrideDiffuse(*node, bodyParts[i].texture);
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
    }

    namespace
    {
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

    void ESM4NpcAnimation::playIdleFONV()
    {
        playLoopFONV("mtidle.kf", false);
    }

    void ESM4NpcAnimation::setLocomotion(Locomotion locomotion)
    {
        if (locomotion == mLocomotion || mDead)
            return;
        mLocomotion = locomotion;
        // An attack or other one-off sequence finishes first, resumeLocomotion picks the loop up again.
        if (!mInAction)
            playLocomotion();
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
                playLoopFONV("mtidle.kf", false);
                break;
            case Locomotion::Walk:
                playLoopFONV("mtforward.kf", true);
                break;
            case Locomotion::Run:
                playLoopFONV("mtfastforward.kf", true);
                break;
        }
    }

    void ESM4NpcAnimation::playDeath(bool instant)
    {
        if (mDead)
            return;
        mDead = true;
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
        source->mDuration = playKeyframesFONV(getUp ? *getUp : *pose, source, false);
    }

    bool ESM4NpcAnimation::isFemale() const
    {
        return mPtr.getType() == ESM::REC_NPC_4 && MWClass::ESM4Npc::isFemale(mPtr);
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
        if (!mResourceSystem->getVFS()->exists(path))
        {
            Log(Debug::Verbose) << "No " << path << " for " << mPtr.getCellRef().getRefId();
            return;
        }

        playKeyframesFONV(path, std::make_shared<SceneUtil::FrameTimeSource>(), stripRootMotion);
    }

    float ESM4NpcAnimation::playKeyframesFONV(const VFS::Path::Normalized& path,
        std::shared_ptr<SceneUtil::ControllerSource> source, bool stripRootMotion)
    {
        osg::ref_ptr<const SceneUtil::KeyframeHolder> keyframes = mResourceSystem->getKeyframeManager()->get(path);
        const NodeMap& nodeMap = getNodeMap();
        float duration = 0.f;

        // Drop the sequence played before
        for (auto& [node, callback] : mLoopCallbacks)
            node->removeUpdateCallback(callback);
        mLoopCallbacks.clear();

        const bool hasAccumRootTrack = keyframes->mKeyframeControllers.contains("Bip01");
        mLocomotionSpeed = 0.f;
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
            if (!mRestTranslations.contains(transform))
                mRestTranslations[transform] = transform->getMatrix().getTrans();

            osg::ref_ptr<SceneUtil::KeyframeController> cloned = osg::clone(controller.get(), osg::CopyOp::SHALLOW_COPY);
            cloned->setSource(source);
            transform->addUpdateCallback(cloned->getAsCallback());
            mLoopCallbacks.emplace_back(transform, cloned->getAsCallback());
            ++bound;
            if (const std::shared_ptr<SceneUtil::ControllerFunction> function = cloned->getFunction())
                duration = std::max(duration, function->getMaximum());

            if (stripRootMotion && target == "Bip01")
            {
                // Speed of the cycle, so feet don't slide: distance the root covers over one loop
                if (const std::shared_ptr<SceneUtil::ControllerFunction> function = cloned->getFunction())
                {
                    const float cycle = function->getMaximum();
                    if (cycle > 0.f)
                    {
                        osg::Vec3f delta = controller->getTranslation(cycle) - controller->getTranslation(0.f);
                        delta.z() = 0.f;
                        mLocomotionSpeed = delta.length() / cycle;
                        Log(Debug::Verbose) << "Root track " << name << " moves " << delta << " over " << cycle;
                    }
                }
                osg::ref_ptr<osg::Callback> strip = new StripHorizontalMotion(mRestTranslations[transform]);
                transform->addUpdateCallback(strip);
                mLoopCallbacks.emplace_back(transform, strip);
            }
        }
        Log(Debug::Verbose) << "Playing " << path << " on " << mPtr.getCellRef().getRefId() << ": " << bound << "/"
                            << keyframes->mKeyframeControllers.size() << " tracks bound, root accum track "
                            << hasAccumRootTrack << ", speed " << mLocomotionSpeed;
        return duration;
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
