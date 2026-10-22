#include "esm4npcanimation.hpp"

#include <components/esm4/loadarma.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadeyes.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loadhair.hpp>
#include <components/esm4/loadhdpt.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadrace.hpp>

#include <osg/Material>
#include <osg/Texture2D>
#include <osg/Transform>

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

#include "../mwbase/environment.hpp"
#include "esm4facegen.hpp"
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
    }

    void ESM4NpcAnimation::updateParts()
    {
        if (mObjectRoot == nullptr)
            return;
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

    void ESM4NpcAnimation::playIdleFONV()
    {
        // TODO: drive this through the character controller once FONV animation groups are mapped. For now loop the
        // standing idle that sits next to the skeleton so NPCs don't stand in the bind pose.
        const VFS::Path::Normalized skeletonPath = mPtr.getClass().getCorrectedModel(mPtr);
        const std::string_view skeleton = skeletonPath.value();
        const size_t slash = skeleton.find_last_of('/');
        if (slash == std::string_view::npos)
            return;
        const VFS::Path::Normalized idle(std::string(skeleton.substr(0, slash)) + "/locomotion/mtidle.kf");
        if (!mResourceSystem->getVFS()->exists(idle))
            return;

        osg::ref_ptr<const SceneUtil::KeyframeHolder> keyframes = mResourceSystem->getKeyframeManager()->get(idle);
        const NodeMap& nodeMap = getNodeMap();
        const auto source = std::make_shared<SceneUtil::FrameTimeSource>();
        const bool hasAccumRootTrack = keyframes->mKeyframeControllers.contains("Bip01");
        for (const auto& [name, controller] : keyframes->mKeyframeControllers)
        {
            // Without movement accumulation, "Bip01 NonAccum" carries the whole root offset, so it belongs on the
            // accumulation root that holds the pelvis height in the skeleton.
            const std::string_view target = !hasAccumRootTrack && name == "Bip01 NonAccum" ? "Bip01" : name;
            auto found = nodeMap.find(target);
            if (found == nodeMap.end() || !dynamic_cast<NifOsg::MatrixTransform*>(found->second.get()))
                continue;
            // The skeleton's own transform controllers have no time source and would reset the bone every frame.
            osg::Callback* callback = found->second->getUpdateCallback();
            while (callback != nullptr)
            {
                osg::Callback* next = callback->getNestedCallback();
                if (dynamic_cast<SceneUtil::KeyframeController*>(callback))
                    found->second->removeUpdateCallback(callback);
                callback = next;
            }
            osg::ref_ptr<SceneUtil::KeyframeController> cloned = osg::clone(controller.get(), osg::CopyOp::SHALLOW_COPY);
            cloned->setSource(source);
            found->second->addUpdateCallback(cloned->getAsCallback());
        }
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
