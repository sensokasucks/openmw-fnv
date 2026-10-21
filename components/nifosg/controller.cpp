#include "controller.hpp"

#include <limits>

#include <osg/Material>
#include <osg/MatrixTransform>
#include <osg/TexMat>
#include <osg/Texture2D>

#include <osgAnimation/Bone>

#include <osgParticle/Emitter>

#include <components/nif/data.hpp>
#include <components/sceneutil/morphgeometry.hpp>

#include "matrixtransform.hpp"

namespace NifOsg
{

    ControllerFunction::ControllerFunction(const Nif::NiTimeController* ctrl)
        : mFrequency(ctrl->mFrequency)
        , mPhase(ctrl->mPhase)
        , mStartTime(ctrl->mTimeStart)
        , mStopTime(ctrl->mTimeStop)
        , mExtrapolationMode(ctrl->extrapolationMode())
    {
    }

    ControllerFunction::ControllerFunction(const Nif::NiControllerSequence* sequence)
        : mFrequency(sequence->mFrequency)
        , mPhase(0.f)
        , mStartTime(sequence->mStartTime)
        , mStopTime(sequence->mStopTime)
    {
        // Sequences store their cycle type as 0 = loop, 1 = reverse, 2 = clamp
        switch (static_cast<uint32_t>(sequence->mExtrapolationMode))
        {
            case 0:
                mExtrapolationMode = Nif::NiTimeController::ExtrapolationMode::Cycle;
                break;
            case 1:
                mExtrapolationMode = Nif::NiTimeController::ExtrapolationMode::Reverse;
                break;
            default:
                mExtrapolationMode = Nif::NiTimeController::ExtrapolationMode::Constant;
                break;
        }
    }

    float ControllerFunction::calculate(float value) const
    {
        float time = mFrequency * value + mPhase;
        if (time >= mStartTime && time <= mStopTime)
            return time;
        switch (mExtrapolationMode)
        {
            case Nif::NiTimeController::ExtrapolationMode::Cycle:
            {
                float delta = mStopTime - mStartTime;
                if (delta <= 0)
                    return mStartTime;
                float cycles = (time - mStartTime) / delta;
                float remainder = (cycles - std::floor(cycles)) * delta;
                return mStartTime + remainder;
            }
            case Nif::NiTimeController::ExtrapolationMode::Reverse:
            {
                float delta = mStopTime - mStartTime;
                if (delta <= 0)
                    return mStartTime;

                float cycles = (time - mStartTime) / delta;
                float remainder = (cycles - std::floor(cycles)) * delta;

                // Even number of cycles?
                if ((static_cast<int>(std::fabs(std::floor(cycles))) % 2) == 0)
                    return mStartTime + remainder;

                return mStopTime - remainder;
            }
            case Nif::NiTimeController::ExtrapolationMode::Constant:
            default:
            {
                if (time < mStartTime)
                    return mStartTime;
                if (time > mStopTime)
                    return mStopTime;
                return time;
            }
        }
    }

    float ControllerFunction::getMaximum() const
    {
        return mStopTime;
    }

    KeyframeController::KeyframeController() {}

    KeyframeController::KeyframeController(const KeyframeController& copy, const osg::CopyOp& copyop)
        : osg::Object(copy, copyop)
        , SceneUtil::KeyframeController(copy)
        , SceneUtil::NodeCallback<KeyframeController, NifOsg::MatrixTransform*>(copy, copyop)
        , mRotations(copy.mRotations)
        , mXRotations(copy.mXRotations)
        , mYRotations(copy.mYRotations)
        , mZRotations(copy.mZRotations)
        , mTranslations(copy.mTranslations)
        , mScales(copy.mScales)
        , mAxisOrder(copy.mAxisOrder)
    {
    }

    namespace
    {
        // Gamebryo stores KF curves as open uniform cubic B-splines (NiBSplineBasis<float, 3>).
        float evaluateBSpline(const std::vector<float>& points, size_t dimension, size_t component, float u)
        {
            constexpr size_t degree = 3;
            const size_t count = points.size() / dimension;
            if (count == 0)
                return 0.f;
            if (count <= degree)
                return points[component];
            const auto knot = [&](size_t j) -> float {
                if (j <= degree)
                    return 0.f;
                return static_cast<float>(std::min(j, count) - degree);
            };
            size_t span = degree;
            while (span + 1 < count && knot(span + 1) <= u)
                ++span;
            float d[degree + 1];
            for (size_t j = 0; j <= degree; ++j)
                d[j] = points[(span - degree + j) * dimension + component];
            for (size_t r = 1; r <= degree; ++r)
            {
                for (size_t j = degree; j >= r; --j)
                {
                    const float left = knot(span - degree + j);
                    const float right = knot(span + 1 + j - r);
                    const float alpha = right > left ? (u - left) / (right - left) : 0.f;
                    d[j] = (1.f - alpha) * d[j - 1] + alpha * d[j];
                }
            }
            return d[degree];
        }

        bool isValidHandle(uint32_t handle)
        {
            return handle != 0xffff && handle != 0xffffffff;
        }

        std::vector<float> getControlPoints(const Nif::NiBSplineInterpolator& interp, uint32_t handle,
            size_t dimension, float offset, float halfRange, bool compact)
        {
            const size_t count = interp.mBasisData->mNumControlPoints;
            std::vector<float> result(count * dimension);
            const Nif::NiBSplineData& data = *interp.mSplineData.getPtr();
            for (size_t i = 0; i < result.size(); ++i)
            {
                const size_t index = handle + i;
                if (compact)
                    result[i] = index < data.mCompactControlPoints.size()
                        ? offset + halfRange * (data.mCompactControlPoints[index] / 32767.f)
                        : 0.f;
                else
                    result[i] = index < data.mFloatControlPoints.size() ? data.mFloatControlPoints[index] : 0.f;
            }
            return result;
        }

        // Resample a B-spline transform into linear keys so the regular interpolators can play it.
        void sampleBSpline(const Nif::NiBSplineTransformInterpolator& interp, Nif::Vector3KeyMapPtr& translations,
            Nif::QuaternionKeyMapPtr& rotations, Nif::FloatKeyMapPtr& scales)
        {
            if (interp.mSplineData.empty() || interp.mBasisData.empty())
                return;
            const auto* comp = interp.mRecordType == Nif::RC_NiBSplineCompTransformInterpolator
                ? static_cast<const Nif::NiBSplineCompTransformInterpolator*>(&interp)
                : nullptr;
            const bool compact = comp != nullptr;
            const size_t count = interp.mBasisData->mNumControlPoints;
            const float duration = interp.mStopTime - interp.mStartTime;
            if (count == 0 || duration <= 0.f)
                return;
            const float range = static_cast<float>(count > 3 ? count - 3 : 1);
            const size_t samples = std::max<size_t>(2, static_cast<size_t>(duration * 30.f) + 1);

            auto forEachSample = [&](auto&& fn) {
                for (size_t i = 0; i < samples; ++i)
                {
                    const float t = interp.mStartTime + duration * i / (samples - 1);
                    fn(t, std::min(range, range * (t - interp.mStartTime) / duration));
                }
            };

            if (isValidHandle(interp.mTranslationHandle))
            {
                const std::vector<float> points = getControlPoints(interp, interp.mTranslationHandle, 3,
                    compact ? comp->mTranslationOffset : 0.f, compact ? comp->mTranslationHalfRange : 0.f, compact);
                translations = std::make_shared<Nif::Vector3KeyMap>();
                translations->mInterpolationType = Nif::InterpolationType_Linear;
                forEachSample([&](float t, float u) {
                    const osg::Vec3f value(evaluateBSpline(points, 3, 0, u), evaluateBSpline(points, 3, 1, u),
                        evaluateBSpline(points, 3, 2, u));
                    translations->mKeys.emplace_back(t, Nif::KeyT<osg::Vec3f>{ value, {}, {} });
                });
            }
            if (isValidHandle(interp.mRotationHandle))
            {
                const std::vector<float> points = getControlPoints(interp, interp.mRotationHandle, 4,
                    compact ? comp->mRotationOffset : 0.f, compact ? comp->mRotationHalfRange : 0.f, compact);
                rotations = std::make_shared<Nif::QuaternionKeyMap>();
                rotations->mInterpolationType = Nif::InterpolationType_Linear;
                forEachSample([&](float t, float u) {
                    // Control points are stored as w, x, y, z
                    osg::Quat value(evaluateBSpline(points, 4, 1, u), evaluateBSpline(points, 4, 2, u),
                        evaluateBSpline(points, 4, 3, u), evaluateBSpline(points, 4, 0, u));
                    const double length = value.length();
                    if (length > 0)
                        value /= length;
                    rotations->mKeys.emplace_back(t, Nif::KeyT<osg::Quat>{ value, {}, {} });
                });
            }
            if (isValidHandle(interp.mScaleHandle))
            {
                const std::vector<float> points = getControlPoints(interp, interp.mScaleHandle, 1,
                    compact ? comp->mScaleOffset : 0.f, compact ? comp->mScaleHalfRange : 0.f, compact);
                scales = std::make_shared<Nif::FloatKeyMap>();
                scales->mInterpolationType = Nif::InterpolationType_Linear;
                forEachSample([&](float t, float u) {
                    scales->mKeys.emplace_back(t, Nif::KeyT<float>{ evaluateBSpline(points, 1, 0, u), 0.f, 0.f });
                });
            }
        }
    }

    namespace
    {
        // Gamebryo marks unused interpolator defaults with -FLT_MAX
        bool isValidDefault(float value)
        {
            return value != -std::numeric_limits<float>::max() && value != std::numeric_limits<float>::max();
        }

        template <class MapPtr, class Value>
        MapPtr makeConstantKeys(const Value& value)
        {
            auto keys = std::make_shared<typename MapPtr::element_type>();
            keys->mInterpolationType = Nif::InterpolationType_Linear;
            keys->mKeys.emplace_back(0.f, typename MapPtr::element_type::KeyType{ value, {}, {} });
            return keys;
        }
    }

    KeyframeController::KeyframeController(const Nif::NiInterpolator* interpolator)
    {
        initFromInterpolator(interpolator);

        // In a sequence, a channel without keys holds its pose in the interpolator's default value.
        Nif::NiQuatTransform defaultTransform;
        if (interpolator->mRecordType == Nif::RC_NiTransformInterpolator)
            defaultTransform = static_cast<const Nif::NiTransformInterpolator*>(interpolator)->mDefaultValue;
        else
            defaultTransform = static_cast<const Nif::NiBSplineTransformInterpolator*>(interpolator)->mValue;
        const osg::Quat& rotation = defaultTransform.mRotation;
        const osg::Vec3f& translation = defaultTransform.mTranslation;
        if (mRotations.empty() && mXRotations.empty() && mYRotations.empty() && mZRotations.empty()
            && isValidDefault(rotation.w()))
            mRotations = QuaternionInterpolator(makeConstantKeys<Nif::QuaternionKeyMapPtr>(rotation));
        if (mTranslations.empty() && isValidDefault(translation.x()))
            mTranslations = Vec3Interpolator(makeConstantKeys<Nif::Vector3KeyMapPtr>(translation));
        if (mScales.empty() && isValidDefault(defaultTransform.mScale))
            mScales = FloatInterpolator(makeConstantKeys<Nif::FloatKeyMapPtr>(defaultTransform.mScale));
    }

    void KeyframeController::initFromInterpolator(const Nif::NiInterpolator* interpolator)
    {
        if (interpolator->mRecordType == Nif::RC_NiTransformInterpolator)
        {
            const Nif::NiTransformInterpolator* interp = static_cast<const Nif::NiTransformInterpolator*>(interpolator);
            const Nif::NiQuatTransform& defaultTransform = interp->mDefaultValue;
            if (!interp->mData.empty())
            {
                mRotations = QuaternionInterpolator(interp->mData->mRotations, defaultTransform.mRotation);
                mXRotations = FloatInterpolator(interp->mData->mXRotations);
                mYRotations = FloatInterpolator(interp->mData->mYRotations);
                mZRotations = FloatInterpolator(interp->mData->mZRotations);
                mTranslations = Vec3Interpolator(interp->mData->mTranslations, defaultTransform.mTranslation);
                mScales = FloatInterpolator(interp->mData->mScales, defaultTransform.mScale);

                mAxisOrder = interp->mData->mAxisOrder;
            }
            else
            {
                mRotations = QuaternionInterpolator(Nif::QuaternionKeyMapPtr(), defaultTransform.mRotation);
                mTranslations = Vec3Interpolator(Nif::Vector3KeyMapPtr(), defaultTransform.mTranslation);
                mScales = FloatInterpolator(Nif::FloatKeyMapPtr(), defaultTransform.mScale);
            }
        }
        else if (interpolator->mRecordType == Nif::RC_NiBSplineCompTransformInterpolator
            || interpolator->mRecordType == Nif::RC_NiBSplineTransformInterpolator)
        {
            const auto* interp = static_cast<const Nif::NiBSplineTransformInterpolator*>(interpolator);
            const Nif::NiQuatTransform& defaultTransform = interp->mValue;
            Nif::Vector3KeyMapPtr translations;
            Nif::QuaternionKeyMapPtr rotations;
            Nif::FloatKeyMapPtr scales;
            sampleBSpline(*interp, translations, rotations, scales);
            mRotations = QuaternionInterpolator(rotations, defaultTransform.mRotation);
            mTranslations = Vec3Interpolator(translations, defaultTransform.mTranslation);
            mScales = FloatInterpolator(scales, defaultTransform.mScale);
        }
    }

    KeyframeController::KeyframeController(const Nif::NiKeyframeController* keyctrl)
    {
        if (!keyctrl->mInterpolator.empty())
        {
            if (keyctrl->mInterpolator->mRecordType == Nif::RC_NiTransformInterpolator)
                initFromInterpolator(keyctrl->mInterpolator.getPtr());
        }
        else if (!keyctrl->mData.empty())
        {
            const Nif::NiKeyframeData* keydata = keyctrl->mData.getPtr();
            mRotations = QuaternionInterpolator(keydata->mRotations);
            mXRotations = FloatInterpolator(keydata->mXRotations);
            mYRotations = FloatInterpolator(keydata->mYRotations);
            mZRotations = FloatInterpolator(keydata->mZRotations);
            mTranslations = Vec3Interpolator(keydata->mTranslations);
            mScales = FloatInterpolator(keydata->mScales, 1.f);

            mAxisOrder = keydata->mAxisOrder;
        }
    }

    osg::Quat KeyframeController::getXYZRotation(float time) const
    {
        float xrot = 0, yrot = 0, zrot = 0;
        if (!mXRotations.empty())
            xrot = mXRotations.interpKey(time);
        if (!mYRotations.empty())
            yrot = mYRotations.interpKey(time);
        if (!mZRotations.empty())
            zrot = mZRotations.interpKey(time);
        osg::Quat xr(xrot, osg::X_AXIS);
        osg::Quat yr(yrot, osg::Y_AXIS);
        osg::Quat zr(zrot, osg::Z_AXIS);
        switch (mAxisOrder)
        {
            case Nif::NiKeyframeData::AxisOrder::Order_XYZ:
                return xr * yr * zr;
            case Nif::NiKeyframeData::AxisOrder::Order_XZY:
                return xr * zr * yr;
            case Nif::NiKeyframeData::AxisOrder::Order_YZX:
                return yr * zr * xr;
            case Nif::NiKeyframeData::AxisOrder::Order_YXZ:
                return yr * xr * zr;
            case Nif::NiKeyframeData::AxisOrder::Order_ZXY:
                return zr * xr * yr;
            case Nif::NiKeyframeData::AxisOrder::Order_ZYX:
                return zr * yr * xr;
            case Nif::NiKeyframeData::AxisOrder::Order_XYX:
                return xr * yr * xr;
            case Nif::NiKeyframeData::AxisOrder::Order_YZY:
                return yr * zr * yr;
            case Nif::NiKeyframeData::AxisOrder::Order_ZXZ:
                return zr * xr * zr;
        }
        return xr * yr * zr;
    }

    osg::Vec3f KeyframeController::getTranslation(float time) const
    {
        if (!mTranslations.empty())
            return mTranslations.interpKey(time);
        return osg::Vec3f();
    }

    void KeyframeController::operator()(NifOsg::MatrixTransform* node, osg::NodeVisitor* nv)
    {
        auto [translation, rotation, scale] = getCurrentTransformation(nv);

        if (rotation)
        {
            node->setRotation(*rotation);
        }
        else
        {
            // This is necessary to prevent first person animations glitching out due to RotationController
            node->setRotation(node->mRotationScale);
        }

        if (translation)
            node->setTranslation(*translation);

        if (scale)
            node->setScale(*scale);

        traverse(node, nv);
    }

    KeyframeController::KfTransform KeyframeController::getCurrentTransformation(osg::NodeVisitor* nv)
    {
        KfTransform out;

        if (hasInput())
        {
            float time = getInputValue(nv);

            if (!mRotations.empty())
                out.mRotation = mRotations.interpKey(time);
            else if (!mXRotations.empty() || !mYRotations.empty() || !mZRotations.empty())
                out.mRotation = getXYZRotation(time);

            if (!mTranslations.empty())
                out.mTranslation = mTranslations.interpKey(time);

            if (!mScales.empty())
                out.mScale = mScales.interpKey(time);
        }

        return out;
    }

    GeomMorpherController::GeomMorpherController() {}

    GeomMorpherController::GeomMorpherController(const GeomMorpherController& copy, const osg::CopyOp& copyop)
        : Controller(copy)
        , SceneUtil::NodeCallback<GeomMorpherController, SceneUtil::MorphGeometry*>(copy, copyop)
        , mKeyFrames(copy.mKeyFrames)
        , mWeights(copy.mWeights)
    {
    }

    GeomMorpherController::GeomMorpherController(const Nif::NiGeomMorpherController* ctrl)
    {
        if (ctrl->mInterpolators.size() == 0)
        {
            if (!ctrl->mData.empty())
            {
                for (const auto& morph : ctrl->mData->mMorphs)
                    mKeyFrames.emplace_back(morph.mKeyFrames);
            }
            return;
        }

        mKeyFrames.resize(ctrl->mInterpolators.size());
        mWeights = ctrl->mWeights;

        for (std::size_t i = 0, n = ctrl->mInterpolators.size(); i < n; ++i)
        {
            if (!ctrl->mInterpolators[i].empty() && ctrl->mInterpolators[i]->mRecordType == Nif::RC_NiFloatInterpolator)
            {
                auto interpolator = static_cast<const Nif::NiFloatInterpolator*>(ctrl->mInterpolators[i].getPtr());
                mKeyFrames[i] = FloatInterpolator(interpolator);
            }
        }
    }

    void GeomMorpherController::operator()(SceneUtil::MorphGeometry* node, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            if (mKeyFrames.size() <= 1)
                return;
            float input = getInputValue(nv);
            unsigned int i = 1;
            for (std::vector<FloatInterpolator>::iterator it = mKeyFrames.begin() + 1; it != mKeyFrames.end();
                 ++it, ++i)
            {
                float val = 0;
                if (!(*it).empty())
                {
                    val = it->interpKey(input);
                    if (i < mWeights.size())
                        val *= mWeights[i];
                }

                SceneUtil::MorphGeometry::MorphTarget& target = node->getMorphTarget(i);
                if (target.getWeight() != val)
                {
                    target.setWeight(val);
                    node->dirty();
                }
            }
        }
    }

    UVController::UVController(const Nif::NiUVData* data, const std::set<unsigned int>& textureUnits)
        : mUTrans(data->mKeyList[0], 0.f)
        , mVTrans(data->mKeyList[1], 0.f)
        , mUScale(data->mKeyList[2], 1.f)
        , mVScale(data->mKeyList[3], 1.f)
        , mTextureUnits(textureUnits)
    {
    }

    UVController::UVController(const UVController& copy, const osg::CopyOp& copyop)
        : osg::Object(copy, copyop)
        , StateSetUpdater(copy, copyop)
        , Controller(copy)
        , mUTrans(copy.mUTrans)
        , mVTrans(copy.mVTrans)
        , mUScale(copy.mUScale)
        , mVScale(copy.mVScale)
        , mTextureUnits(copy.mTextureUnits)
    {
    }

    void UVController::setDefaults(osg::StateSet* stateset)
    {
        osg::ref_ptr<osg::TexMat> texMat(new osg::TexMat);
        for (unsigned int unit : mTextureUnits)
            stateset->setTextureAttributeAndModes(unit, texMat, osg::StateAttribute::ON);
    }

    void UVController::apply(osg::StateSet* stateset, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            float value = getInputValue(nv);

            // First scale the UV relative to its center, then apply the offset.
            // U offset is flipped regardless of the graphics library
            osg::Vec3f uvOrigin(0.5f, 0.5f, 0.f);
            osg::Vec3f uvScale(mUScale.interpKey(value), mVScale.interpKey(value), 1.f);
            osg::Vec3f uvTrans(-mUTrans.interpKey(value), mVTrans.interpKey(value), 0.f);

            osg::Matrixf mat = osg::Matrixf::translate(uvOrigin);
            mat.preMultScale(uvScale);
            mat.preMultTranslate(-uvOrigin);
            mat.setTrans(mat.getTrans() + uvTrans);

            // setting once is enough because all other texture units share the same TexMat (see setDefaults).
            if (!mTextureUnits.empty())
            {
                osg::TexMat* texMat = static_cast<osg::TexMat*>(
                    stateset->getTextureAttribute(*mTextureUnits.begin(), osg::StateAttribute::TEXMAT));
                texMat->setMatrix(mat);
            }
        }
    }

    VisController::VisController(const Nif::NiVisController* ctrl, unsigned int mask)
        : mMask(mask)
    {
        if (!ctrl->mInterpolator.empty())
        {
            if (ctrl->mInterpolator->mRecordType != Nif::RC_NiBoolInterpolator)
                return;

            mInterpolator = { static_cast<const Nif::NiBoolInterpolator*>(ctrl->mInterpolator.getPtr()) };
        }
        else if (!ctrl->mData.empty())
            mData = ctrl->mData->mKeys;
    }

    VisController::VisController() {}

    VisController::VisController(const VisController& copy, const osg::CopyOp& copyop)
        : SceneUtil::NodeCallback<VisController>(copy, copyop)
        , Controller(copy)
        , mData(copy.mData)
        , mInterpolator(copy.mInterpolator)
        , mMask(copy.mMask)
    {
    }

    bool VisController::calculate(float time) const
    {
        if (!mInterpolator.empty())
            return mInterpolator.interpKey(time);

        if (mData->empty())
            return true;

        auto iter = std::upper_bound(mData->begin(), mData->end(), time,
            [](float t, const std::pair<float, bool>& key) { return t < key.first; });
        if (iter != mData->begin())
            --iter;
        return iter->second;
    }

    void VisController::operator()(osg::Node* node, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            bool vis = calculate(getInputValue(nv));
            node->setNodeMask(vis ? ~0 : mMask);
        }
        traverse(node, nv);
    }

    RollController::RollController(const Nif::NiRollController* ctrl)
    {
        if (!ctrl->mInterpolator.empty())
        {
            if (ctrl->mInterpolator->mRecordType == Nif::RC_NiFloatInterpolator)
                mData = FloatInterpolator(static_cast<const Nif::NiFloatInterpolator*>(ctrl->mInterpolator.getPtr()));
        }
        else if (!ctrl->mData.empty())
            mData = FloatInterpolator(ctrl->mData->mKeyList, 1.f);
    }

    RollController::RollController(const RollController& copy, const osg::CopyOp& copyop)
        : SceneUtil::NodeCallback<RollController, osg::MatrixTransform*>(copy, copyop)
        , Controller(copy)
        , mData(copy.mData)
        , mStartingTime(copy.mStartingTime)
    {
    }

    void RollController::operator()(osg::MatrixTransform* node, osg::NodeVisitor* nv)
    {
        traverse(node, nv);

        if (hasInput())
        {
            double newTime = nv->getFrameStamp()->getSimulationTime();
            double duration = newTime - mStartingTime;
            mStartingTime = newTime;

            float value = mData.interpKey(getInputValue(nv));

            // Rotate around "roll" axis.
            // Note: in original game rotation speed is the framerate-dependent in a very tricky way.
            // Do not replicate this behaviour until we will really need it.
            // For now consider controller's current value as an angular speed in radians per 1/60 seconds.
            node->preMult(osg::Matrix::rotate(value * duration * 60.f, 0, 0, 1));

            // Note: doing it like this means RollControllers are not compatible with KeyframeControllers.
            // KeyframeController currently wins the conflict.
            // However unlikely that is, NetImmerse might combine the transformations somehow.
        }
    }

    AlphaController::AlphaController() {}

    AlphaController::AlphaController(const Nif::NiAlphaController* ctrl, const osg::Material* baseMaterial)
        : mBaseMaterial(baseMaterial)
    {
        if (!ctrl->mInterpolator.empty())
        {
            if (ctrl->mInterpolator->mRecordType == Nif::RC_NiFloatInterpolator)
                mData = FloatInterpolator(static_cast<const Nif::NiFloatInterpolator*>(ctrl->mInterpolator.getPtr()));
        }
        else if (!ctrl->mData.empty())
            mData = FloatInterpolator(ctrl->mData->mKeyList, 1.f);
    }

    AlphaController::AlphaController(const AlphaController& copy, const osg::CopyOp& copyop)
        : StateSetUpdater(copy, copyop)
        , Controller(copy)
        , mData(copy.mData)
        , mBaseMaterial(copy.mBaseMaterial)
    {
    }

    void AlphaController::setDefaults(osg::StateSet* stateset)
    {
        stateset->setAttribute(
            static_cast<osg::Material*>(mBaseMaterial->clone(osg::CopyOp::DEEP_COPY_ALL)), osg::StateAttribute::ON);
    }

    void AlphaController::apply(osg::StateSet* stateset, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            float value = mData.interpKey(getInputValue(nv));
            osg::Material* mat = static_cast<osg::Material*>(stateset->getAttribute(osg::StateAttribute::MATERIAL));
            osg::Vec4f diffuse = mat->getDiffuse(osg::Material::FRONT_AND_BACK);
            diffuse.a() = value;
            mat->setDiffuse(osg::Material::FRONT_AND_BACK, diffuse);
        }
    }

    MaterialColorController::MaterialColorController() = default;

    MaterialColorController::MaterialColorController(
        const Nif::NiMaterialColorController* ctrl, const osg::Material* baseMaterial)
        : mTargetColor(ctrl->mTargetColor)
        , mBaseMaterial(baseMaterial)
    {
        if (!ctrl->mInterpolator.empty())
        {
            if (ctrl->mInterpolator->mRecordType == Nif::RC_NiPoint3Interpolator)
                mData = Vec3Interpolator(static_cast<const Nif::NiPoint3Interpolator*>(ctrl->mInterpolator.getPtr()));
        }
        else if (!ctrl->mData.empty())
            mData = Vec3Interpolator(ctrl->mData->mKeyList, osg::Vec3f(1, 1, 1));
    }

    MaterialColorController::MaterialColorController(const MaterialColorController& copy, const osg::CopyOp& copyop)
        : StateSetUpdater(copy, copyop)
        , Controller(copy)
        , mData(copy.mData)
        , mTargetColor(copy.mTargetColor)
        , mBaseMaterial(copy.mBaseMaterial)
    {
    }

    void MaterialColorController::setDefaults(osg::StateSet* stateset)
    {
        stateset->setAttribute(
            static_cast<osg::Material*>(mBaseMaterial->clone(osg::CopyOp::DEEP_COPY_ALL)), osg::StateAttribute::ON);
    }

    void MaterialColorController::apply(osg::StateSet* stateset, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            osg::Vec3f value = mData.interpKey(getInputValue(nv));
            osg::Material* mat = static_cast<osg::Material*>(stateset->getAttribute(osg::StateAttribute::MATERIAL));
            using TargetColor = Nif::NiMaterialColorController::TargetColor;
            switch (mTargetColor)
            {
                case TargetColor::Diffuse:
                {
                    osg::Vec4f diffuse = mat->getDiffuse(osg::Material::FRONT_AND_BACK);
                    diffuse.set(value.x(), value.y(), value.z(), diffuse.a());
                    mat->setDiffuse(osg::Material::FRONT_AND_BACK, diffuse);
                    break;
                }
                case TargetColor::Specular:
                {
                    osg::Vec4f specular = mat->getSpecular(osg::Material::FRONT_AND_BACK);
                    specular.set(value.x(), value.y(), value.z(), specular.a());
                    mat->setSpecular(osg::Material::FRONT_AND_BACK, specular);
                    break;
                }
                case TargetColor::Emissive:
                {
                    osg::Vec4f emissive = mat->getEmission(osg::Material::FRONT_AND_BACK);
                    emissive.set(value.x(), value.y(), value.z(), emissive.a());
                    mat->setEmission(osg::Material::FRONT_AND_BACK, emissive);
                    break;
                }
                case TargetColor::Ambient:
                default:
                {
                    osg::Vec4f ambient = mat->getAmbient(osg::Material::FRONT_AND_BACK);
                    ambient.set(value.x(), value.y(), value.z(), ambient.a());
                    mat->setAmbient(osg::Material::FRONT_AND_BACK, ambient);
                }
            }
        }
    }

    FlipController::FlipController(
        const Nif::NiFlipController* ctrl, const std::vector<osg::ref_ptr<osg::Texture2D>>& textures)
        : mTexSlot(0) // always affects diffuse
        , mDelta(ctrl->mDelta)
        , mTextures(textures)
    {
        if (!ctrl->mInterpolator.empty() && ctrl->mInterpolator->mRecordType == Nif::RC_NiFloatInterpolator)
            mData = static_cast<const Nif::NiFloatInterpolator*>(ctrl->mInterpolator.getPtr());
    }

    FlipController::FlipController(int texSlot, float delta, const std::vector<osg::ref_ptr<osg::Texture2D>>& textures)
        : mTexSlot(texSlot)
        , mDelta(delta)
        , mTextures(textures)
    {
    }

    FlipController::FlipController(const FlipController& copy, const osg::CopyOp& copyop)
        : StateSetUpdater(copy, copyop)
        , Controller(copy)
        , mTexSlot(copy.mTexSlot)
        , mDelta(copy.mDelta)
        , mTextures(copy.mTextures)
        , mData(copy.mData)
    {
    }

    void FlipController::apply(osg::StateSet* stateset, osg::NodeVisitor* nv)
    {
        if (hasInput() && !mTextures.empty())
        {
            int curTexture = 0;
            if (mDelta != 0)
                curTexture = int(getInputValue(nv) / mDelta) % mTextures.size();
            else
                curTexture = int(mData.interpKey(getInputValue(nv))) % mTextures.size();
            stateset->setTextureAttribute(mTexSlot, mTextures[curTexture]);
        }
    }

    ParticleSystemController::ParticleSystemController(const Nif::NiParticleSystemController* ctrl)
        : mEmitStart(ctrl->mEmitStartTime)
        , mEmitStop(ctrl->mEmitStopTime)
    {
    }

    ParticleSystemController::ParticleSystemController(const ParticleSystemController& copy, const osg::CopyOp& copyop)
        : SceneUtil::NodeCallback<ParticleSystemController, osgParticle::ParticleProcessor*>(copy, copyop)
        , Controller(copy)
        , mEmitStart(copy.mEmitStart)
        , mEmitStop(copy.mEmitStop)
    {
    }

    void ParticleSystemController::operator()(osgParticle::ParticleProcessor* node, osg::NodeVisitor* nv)
    {
        if (hasInput())
        {
            float time = getInputValue(nv);
            node->getParticleSystem()->setFrozen(false);
            node->setEnabled(time >= mEmitStart && time < mEmitStop);
        }
        else
            node->getParticleSystem()->setFrozen(true);
        traverse(node, nv);
    }

    PathController::PathController(const PathController& copy, const osg::CopyOp& copyop)
        : SceneUtil::NodeCallback<PathController, NifOsg::MatrixTransform*>(copy, copyop)
        , Controller(copy)
        , mPath(copy.mPath)
        , mPercent(copy.mPercent)
        , mFlags(copy.mFlags)
    {
    }

    PathController::PathController(const Nif::NiPathController* ctrl)
        : mPath(ctrl->mPathData->mKeyList, osg::Vec3f())
        , mPercent(ctrl->mPercentData->mKeyList, 1.f)
        , mFlags(ctrl->mPathFlags)
    {
    }

    float PathController::getPercent(float time) const
    {
        float percent = mPercent.interpKey(time);
        if (percent < 0.f)
            percent = std::fmod(percent, 1.f) + 1.f;
        else if (percent > 1.f)
            percent = std::fmod(percent, 1.f);
        return percent;
    }

    void PathController::operator()(NifOsg::MatrixTransform* node, osg::NodeVisitor* nv)
    {
        if (mPath.empty() || mPercent.empty() || !hasInput())
        {
            traverse(node, nv);
            return;
        }

        float time = getInputValue(nv);
        float percent = getPercent(time);
        node->setTranslation(mPath.interpKey(percent));

        traverse(node, nv);
    }

}
