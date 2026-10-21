#include "esm4npcanimation.hpp"

#include <components/esm4/loadarma.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loadhair.hpp>
#include <components/esm4/loadhdpt.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadrace.hpp>

#include <components/misc/resourcehelpers.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/attach.hpp>
#include <components/sceneutil/visitor.hpp>

#include "../mwbase/environment.hpp"
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
            updatePartsFONV(*traits);
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

    osg::ref_ptr<osg::Node> ESM4NpcAnimation::attachPart(std::string_view model)
    {
        if (model.empty() || !Misc::StringUtils::ciEndsWith(model, ".nif"))
            return nullptr;
        Resource::SceneManager* sceneManager = mResourceSystem->getSceneManager();
        osg::ref_ptr<const osg::Node> templateNode
            = sceneManager->getTemplate(Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(model)));

        // Skinned parts are bound to the NPC skeleton. The rest (hair, eyes, mouth...) are modelled relative to the
        // head bone, which is their "Prn" parent in FO3/FONV.
        constexpr std::string_view headBone = "Bip01 Head";
        const NodeMap& nodeMap = getNodeMap();
        auto found = nodeMap.find(headBone);
        osg::Group* attachNode = found != nodeMap.end() ? found->second.get() : mObjectRoot.get();
        return SceneUtil::attach(std::move(templateNode), mObjectRoot, {}, attachNode, sceneManager);
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
            if (!(usedSlots & bodySlots[i]))
                attachPart(bodyParts[i].mesh);

        if (usedSlots & ESM4::Armor::FO3_Head)
            return;

        // Race head: head, ears, mouth, lower teeth, upper teeth, tongue, left eye, right eye
        for (const ESM4::Race::BodyPart& part : isFemale ? race->mHeadPartsFemale : race->mHeadParts)
            attachPart(part.mesh);

        for (ESM::FormId partId : traits.mHeadParts)
        {
            if (partId.isZeroOrUnset())
                continue;
            if (const ESM4::HeadPart* part = store->get<ESM4::HeadPart>().search(partId))
                attachPart(part->mModel.getOriginal());
            else
                Log(Debug::Error) << "Head part not found: " << ESM::RefId(partId);
        }

        if (!traits.mHair.isZeroOrUnset() && !(usedSlots & ESM4::Armor::FO3_Hair))
        {
            const ESM4::Hair* hair = store->get<ESM4::Hair>().search(traits.mHair);
            if (hair == nullptr)
                Log(Debug::Error) << "Hair not found: " << ESM::RefId(traits.mHair);
            else if (osg::ref_ptr<osg::Node> node = attachPart(hair->mModel.getOriginal()))
            {
                // Hair meshes carry a full and a trimmed variant; show the one that fits under a hat.
                const bool hat = usedSlots & ESM4::Armor::FO3_Hat;
                SceneUtil::FindByNameVisitor findHidden(hat ? "NoHat" : "Hat");
                node->accept(findHidden);
                if (findHidden.mFoundNode)
                    findHidden.mFoundNode->setNodeMask(0);
            }
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
