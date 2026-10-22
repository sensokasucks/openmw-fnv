#include "esm4base.hpp"

#include <MyGUI_TextIterator.h>
#include <MyGUI_UString.h>

#include <components/misc/constants.hpp>
#include <components/sceneutil/positionattitudetransform.hpp>
#include <components/sceneutil/util.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwgui/tooltips.hpp"

#include "../mwrender/animation.hpp"
#include "../mwrender/objects.hpp"
#include "../mwrender/renderinginterface.hpp"
#include "../mwrender/vismask.hpp"

#include "../mwphysics/physicssystem.hpp"
#include "../mwworld/ptr.hpp"

namespace MWClass
{
    void ESM4Impl::insertObjectRendering(
        const MWWorld::Ptr& ptr, const std::string& model, MWRender::RenderingInterface& renderingInterface)
    {
        if (model.empty())
            return;

        MWRender::Objects& objects = renderingInterface.getObjects();
        objects.insertModel(ptr, model);

        // Models with an embedded "Idle" sequence (e.g. waving flags) loop it while loaded, as in the original engine.
        // The character controller added here plays the "idle" group of non-actors.
        MWRender::Animation* anim = objects.getAnimation(ptr);
        if (anim != nullptr && SceneUtil::hasUserDescription(anim->getObjectRoot(), Constants::EmbeddedIdleLabel)
            && anim->addEmbeddedAnimSource(model))
        {
            MWBase::Environment::get().getMechanicsManager()->add(ptr);
            return;
        }

        ptr.getRefData().getBaseNode()->setNodeMask(MWRender::Mask_Static);
    }

    bool ESM4Impl::prepareEmbeddedAnimation(const MWWorld::Ptr& ptr, std::string_view group)
    {
        // getAnimation also takes the object out of a paged chunk if needed, which inserts its rendering again.
        MWRender::Animation* anim = MWBase::Environment::get().getWorld()->getAnimation(ptr);
        if (anim == nullptr)
            return false;
        if (anim->hasAnimation(group))
            return true;

        // Objects without an "Idle" sequence get their animations only when first needed, so that every container
        // in a cell does not need a character controller.
        const VFS::Path::Normalized model = ptr.getClass().getCorrectedModel(ptr);
        if (!anim->addEmbeddedAnimSource(std::string(model.value())) || !anim->hasAnimation(group))
            return false;
        ptr.getRefData().getBaseNode()->setNodeMask(MWRender::Mask_Object);
        MWBase::Environment::get().getMechanicsManager()->add(ptr);
        return true;
    }

    bool ESM4Impl::playEmbeddedAnimation(const MWWorld::Ptr& ptr, std::string_view group)
    {
        if (!prepareEmbeddedAnimation(ptr, group))
            return false;
        // Mode 1 replaces a sequence that is still playing (e.g. "Close" while "Open" runs).
        return MWBase::Environment::get().getMechanicsManager()->playAnimationGroup(ptr, group, 1, 0, true);
    }

    void ESM4Impl::insertObjectPhysics(
        const MWWorld::Ptr& ptr, const std::string& model, const osg::Quat& rotation, MWPhysics::PhysicsSystem& physics)
    {
        physics.addObject(ptr, VFS::Path::toNormalized(model), rotation, MWPhysics::CollisionType_World);
    }

    MWGui::ToolTipInfo ESM4Impl::getToolTipInfo(std::string_view name, int count)
    {
        MWGui::ToolTipInfo info;
        info.caption = MyGUI::TextIterator::toTagsString(MyGUI::UString(name)) + MWGui::ToolTips::getCountString(count);
        return info;
    }
}
