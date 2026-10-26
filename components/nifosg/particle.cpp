#include "particle.hpp"

#include <algorithm>
#include <limits>
#include <optional>

#include <osg/Geometry>
#include <osg/MatrixTransform>
#include <osg/ValueObject>

#include <components/debug/debuglog.hpp>
#include <components/misc/rng.hpp>
#include <components/nif/data.hpp>
#include <components/sceneutil/morphgeometry.hpp>
#include <components/sceneutil/riggeometry.hpp>

namespace
{
    class FindFirstGeometry : public osg::NodeVisitor
    {
    public:
        FindFirstGeometry()
            : osg::NodeVisitor(osg::NodeVisitor::TRAVERSE_ALL_CHILDREN)
            , mGeometry(nullptr)
        {
        }

        void apply(osg::Node& node) override
        {
            if (mGeometry)
                return;

            traverse(node);
        }

        void apply(osg::Drawable& drawable) override
        {
            if (auto morph = dynamic_cast<SceneUtil::MorphGeometry*>(&drawable))
            {
                mGeometry = morph->getSourceGeometry();
                return;
            }
            else if (auto rig = dynamic_cast<SceneUtil::RigGeometry*>(&drawable))
            {
                mGeometry = rig->getSourceGeometry();
                return;
            }

            traverse(drawable);
        }

        void apply(osg::Geometry& geometry) override { mGeometry = &geometry; }

        osg::Geometry* mGeometry;
    };

    class LocalToWorldAccumulator : public osg::NodeVisitor
    {
    public:
        LocalToWorldAccumulator(osg::Matrix& matrix)
            : osg::NodeVisitor()
            , mMatrix(matrix)
        {
        }

        virtual void apply(osg::Transform& transform)
        {
            if (&transform != mLastAppliedTransform)
            {
                mLastAppliedTransform = &transform;
                mLastMatrix = mMatrix;
            }
            transform.computeLocalToWorldMatrix(mMatrix, this);
        }

        void accumulate(const osg::NodePath& path)
        {
            if (path.empty())
                return;

            size_t i = path.size();

            for (auto rit = path.rbegin(); rit != path.rend(); rit++, --i)
            {
                const osg::Camera* camera = (*rit)->asCamera();
                if (camera
                    && (camera->getReferenceFrame() != osg::Transform::RELATIVE_RF || camera->getParents().empty()))
                    break;
            }

            for (; i < path.size(); ++i)
                path[i]->accept(*this);
        }

        osg::Matrix& mMatrix;
        std::optional<osg::Matrix> mLastMatrix;
        osg::Transform* mLastAppliedTransform = nullptr;
    };
}

namespace NifOsg
{

    ParticleSystem::ParticleSystem()
        : osgParticle::ParticleSystem()
        , mQuota(std::numeric_limits<int>::max())
    {
        mNormalArray = new osg::Vec3Array(1);
        mNormalArray->setBinding(osg::Array::BIND_OVERALL);
        (*mNormalArray.get())[0] = osg::Vec3(0.3f, 0.3f, 0.3f);
    }

    ParticleSystem::ParticleSystem(const ParticleSystem& copy, const osg::CopyOp& copyop)
        : osgParticle::ParticleSystem(copy, copyop)
        , mQuota(copy.mQuota)
    {
        mNormalArray = new osg::Vec3Array(1);
        mNormalArray->setBinding(osg::Array::BIND_OVERALL);
        (*mNormalArray.get())[0] = osg::Vec3(0.3f, 0.3f, 0.3f);

        // For some reason the osgParticle constructor doesn't copy the particles
        for (int i = 0; i < copy.numParticles() - copy.numDeadParticles(); ++i)
            ParticleSystem::createParticle(copy.getParticle(i));
    }

    void ParticleSystem::setQuota(int quota)
    {
        mQuota = quota;
    }

    osgParticle::Particle* ParticleSystem::createParticle(const osgParticle::Particle* ptemplate)
    {
        if (numParticles() - numDeadParticles() < mQuota)
            return osgParticle::ParticleSystem::createParticle(ptemplate);
        return nullptr;
    }

    void ParticleSystem::drawImplementation(osg::RenderInfo& renderInfo) const
    {
        osg::State& state = *renderInfo.getState();
        if (state.useVertexArrayObject(getUseVertexArrayObject()))
        {
            state.getCurrentVertexArrayState()->assignNormalArrayDispatcher();
            state.getCurrentVertexArrayState()->setNormalArray(state, mNormalArray);
        }
        else
        {
            state.getAttributeDispatchers().activateNormalArray(mNormalArray);
        }
        osgParticle::ParticleSystem::drawImplementation(renderInfo);
    }

    void InverseWorldMatrix::operator()(osg::MatrixTransform* node, osg::NodeVisitor* nv)
    {
        osg::NodePath path = nv->getNodePath();
        path.pop_back();

        osg::Matrix mat = osg::computeLocalToWorld(path);
        mat.orthoNormalize(mat); // don't undo the scale
        mat.invert(mat);
        node->setMatrix(mat);

        traverse(node, nv);
    }

    ParticleShooter::ParticleShooter(float minSpeed, float maxSpeed, float horizontalDir, float horizontalAngle,
        float verticalDir, float verticalAngle, float lifetime, float lifetimeRandom)
        : mMinSpeed(minSpeed)
        , mMaxSpeed(maxSpeed)
        , mHorizontalDir(horizontalDir)
        , mHorizontalAngle(horizontalAngle)
        , mVerticalDir(verticalDir)
        , mVerticalAngle(verticalAngle)
        , mLifetime(lifetime)
        , mLifetimeRandom(lifetimeRandom)
    {
    }

    ParticleShooter::ParticleShooter()
        : mMinSpeed(0.f)
        , mMaxSpeed(0.f)
        , mHorizontalDir(0.f)
        , mHorizontalAngle(0.f)
        , mVerticalDir(0.f)
        , mVerticalAngle(0.f)
        , mLifetime(0.f)
        , mLifetimeRandom(0.f)
    {
    }

    ParticleShooter::ParticleShooter(const ParticleShooter& copy, const osg::CopyOp& copyop)
        : osgParticle::Shooter(copy, copyop)
    {
        mMinSpeed = copy.mMinSpeed;
        mMaxSpeed = copy.mMaxSpeed;
        mHorizontalDir = copy.mHorizontalDir;
        mHorizontalAngle = copy.mHorizontalAngle;
        mVerticalDir = copy.mVerticalDir;
        mVerticalAngle = copy.mVerticalAngle;
        mLifetime = copy.mLifetime;
        mLifetimeRandom = copy.mLifetimeRandom;
    }

    void ParticleShooter::shoot(osgParticle::Particle* particle) const
    {
        float hdir = mHorizontalDir + mHorizontalAngle * (2.f * Misc::Rng::rollClosedProbability() - 1.f);
        float vdir = mVerticalDir + mVerticalAngle * (2.f * Misc::Rng::rollClosedProbability() - 1.f);

        osg::Vec3f dir
            = (osg::Quat(vdir, osg::Vec3f(0, 1, 0)) * osg::Quat(hdir, osg::Vec3f(0, 0, 1))) * osg::Vec3f(0, 0, 1);

        float vel = mMinSpeed + (mMaxSpeed - mMinSpeed) * Misc::Rng::rollClosedProbability();
        particle->setVelocity(dir * vel);

        // Not supposed to set this here, but there doesn't seem to be a better way of doing it
        particle->setLifeTime(std::max(
            std::numeric_limits<float>::epsilon(), mLifetime + mLifetimeRandom * Misc::Rng::rollClosedProbability()));
    }

    GrowFadeAffector::GrowFadeAffector(float growTime, float fadeTime, float baseScale)
        : mGrowTime(growTime)
        , mFadeTime(fadeTime)
        , mBaseScale(baseScale)
        , mCachedDefaultSize(0.f)
    {
    }

    GrowFadeAffector::GrowFadeAffector()
        : mGrowTime(0.f)
        , mFadeTime(0.f)
        , mCachedDefaultSize(0.f)
    {
    }

    GrowFadeAffector::GrowFadeAffector(const GrowFadeAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
    {
        mGrowTime = copy.mGrowTime;
        mFadeTime = copy.mFadeTime;
        mBaseScale = copy.mBaseScale;
        mCachedDefaultSize = copy.mCachedDefaultSize;
    }

    void GrowFadeAffector::beginOperate(osgParticle::Program* program)
    {
        mCachedDefaultSize = program->getParticleSystem()->getDefaultParticleTemplate().getSizeRange().minimum;
    }

    void GrowFadeAffector::operate(osgParticle::Particle* particle, double /* dt */)
    {
        float size = mCachedDefaultSize;
        if (particle->getAge() < mGrowTime && mGrowTime != 0.f)
            size *= mBaseScale + (1.f - mBaseScale) * static_cast<float>(particle->getAge() / mGrowTime);
        if (particle->getLifeTime() - particle->getAge() < mFadeTime && mFadeTime != 0.f)
            size *= static_cast<float>(particle->getLifeTime() - particle->getAge()) / mFadeTime;
        particle->setSizeRange(osgParticle::rangef(size, size));
    }

    ParticleColorAffector::ParticleColorAffector(const Nif::NiColorData* clrdata)
        : mData(clrdata->mKeyMap, osg::Vec4f(1, 1, 1, 1))
    {
    }

    ParticleColorAffector::ParticleColorAffector() {}

    ParticleColorAffector::ParticleColorAffector(const ParticleColorAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
    {
        mData = copy.mData;
    }

    void ParticleColorAffector::operate(osgParticle::Particle* particle, double /* dt */)
    {
        assert(particle->getLifeTime() > 0);
        float time = static_cast<float>(particle->getAge() / particle->getLifeTime());
        osg::Vec4f color = mData.interpKey(time);
        float alpha = color.a();
        color.a() = 1.0f;

        particle->setColorRange(osgParticle::rangev4(color, color));
        particle->setAlphaRange(osgParticle::rangef(alpha, alpha));
    }

    GravityAffector::GravityAffector(const Nif::NiGravity* gravity)
        : mForce(gravity->mForce)
        , mType(gravity->mType)
        , mPosition(gravity->mPosition)
        , mDirection(gravity->mDirection)
        , mDecay(gravity->mDecay)
    {
    }

    GravityAffector::GravityAffector(const GravityAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
    {
        mForce = copy.mForce;
        mType = copy.mType;
        mPosition = copy.mPosition;
        mDirection = copy.mDirection;
        mDecay = copy.mDecay;
        mCachedWorldPosition = copy.mCachedWorldPosition;
        mCachedWorldDirection = copy.mCachedWorldDirection;
    }

    void GravityAffector::beginOperate(osgParticle::Program* program)
    {
        bool absolute = (program->getReferenceFrame() == osgParticle::ParticleProcessor::ABSOLUTE_RF);

        // We don't need the position for Wind gravity, except if decay is being applied
        if (mType == Nif::ForceType::Point || mDecay != 0.f)
            mCachedWorldPosition = absolute ? program->transformLocalToWorld(mPosition) : mPosition;

        mCachedWorldDirection = absolute ? program->rotateLocalToWorld(mDirection) : mDirection;
        mCachedWorldDirection.normalize();
    }

    void GravityAffector::operate(osgParticle::Particle* particle, double dt)
    {
        const float magic = 1.6f;
        switch (mType)
        {
            case Nif::ForceType::Wind:
            {
                float decayFactor = 1.f;
                if (mDecay != 0.f)
                {
                    osg::Plane gravityPlane(mCachedWorldDirection, mCachedWorldPosition);
                    float distance = std::abs(gravityPlane.distance(particle->getPosition()));
                    decayFactor = std::exp(-1.f * mDecay * distance);
                }

                particle->addVelocity(mCachedWorldDirection * mForce * static_cast<float>(dt) * decayFactor * magic);

                break;
            }
            case Nif::ForceType::Point:
            {
                osg::Vec3f diff = mCachedWorldPosition - particle->getPosition();

                float decayFactor = 1.f;
                if (mDecay != 0.f)
                    decayFactor = std::exp(-1.f * mDecay * diff.length());

                diff.normalize();

                particle->addVelocity(diff * mForce * static_cast<float>(dt) * decayFactor * magic);
                break;
            }
        }
    }

    ParticleBomb::ParticleBomb(const Nif::NiParticleBomb* bomb)
        : mRange(bomb->mRange)
        , mStrength(bomb->mStrength)
        , mDecayType(bomb->mDecayType)
        , mSymmetryType(bomb->mSymmetryType)
        , mPosition(bomb->mPosition)
        , mDirection(bomb->mDirection)
    {
    }

    ParticleBomb::ParticleBomb(const ParticleBomb& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
    {
        mRange = copy.mRange;
        mStrength = copy.mStrength;
        mDecayType = copy.mDecayType;
        mSymmetryType = copy.mSymmetryType;
        mCachedWorldPosition = copy.mCachedWorldPosition;
        mCachedWorldDirection = copy.mCachedWorldDirection;
    }

    void ParticleBomb::beginOperate(osgParticle::Program* program)
    {
        bool absolute = (program->getReferenceFrame() == osgParticle::ParticleProcessor::ABSOLUTE_RF);

        mCachedWorldPosition = absolute ? program->transformLocalToWorld(mPosition) : mPosition;

        // We don't need the direction for Spherical bomb
        if (mSymmetryType != Nif::SymmetryType::Spherical)
        {
            mCachedWorldDirection = absolute ? program->rotateLocalToWorld(mDirection) : mDirection;
            mCachedWorldDirection.normalize();
        }
    }

    void ParticleBomb::operate(osgParticle::Particle* particle, double dt)
    {
        float decay = 1.f;
        osg::Vec3f explosionDir;

        osg::Vec3f particleDir = particle->getPosition() - mCachedWorldPosition;
        float distance = particleDir.length();
        particleDir.normalize();

        switch (mDecayType)
        {
            case Nif::DecayType::None:
                break;
            case Nif::DecayType::Linear:
                decay = 1.f - distance / mRange;
                break;
            case Nif::DecayType::Exponential:
                decay = std::exp(-distance / mRange);
                break;
        }

        if (decay <= 0.f)
            return;

        switch (mSymmetryType)
        {
            case Nif::SymmetryType::Spherical:
                explosionDir = particleDir;
                break;
            case Nif::SymmetryType::Cylindrical:
                explosionDir = particleDir - mCachedWorldDirection * (mCachedWorldDirection * particleDir);
                explosionDir.normalize();
                break;
            case Nif::SymmetryType::Planar:
                explosionDir = mCachedWorldDirection;
                if (explosionDir * particleDir < 0)
                    explosionDir = -explosionDir;
                break;
        }

        particle->addVelocity(explosionDir * mStrength * decay * static_cast<float>(dt));
    }

    Emitter::Emitter()
        : osgParticle::Emitter()
        , mFlags(0)
        , mGeometryEmitterTarget(std::nullopt)
    {
    }

    Emitter::Emitter(const Emitter& copy, const osg::CopyOp& copyop)
        : osgParticle::Emitter(copy, copyop)
        , mTargets(copy.mTargets)
        , mPlacer(copy.mPlacer)
        , mShooter(copy.mShooter)
        // need a deep copy because the remainder is stored in the object
        , mCounter(static_cast<osgParticle::Counter*>(copy.mCounter->clone(osg::CopyOp::DEEP_COPY_ALL)))
        , mFlags(copy.mFlags)
        , mGeometryEmitterTarget(copy.mGeometryEmitterTarget)
        , mCachedGeometryEmitter(copy.mCachedGeometryEmitter)
    {
    }

    Emitter::Emitter(const std::vector<int>& targets)
        : mTargets(targets)
        , mFlags(0)
        , mGeometryEmitterTarget(std::nullopt)
    {
    }

    void Emitter::emitParticles(double dt)
    {
        int n = mCounter->numParticlesToCreate(dt);
        if (n == 0)
            return;

        osg::Matrix worldToPs;

        // maybe this could be optimized by halting at the lowest common ancestor of the particle and emitter nodes
        osg::NodePathList partsysNodePaths = getParticleSystem()->getParentalNodePaths();
        if (!partsysNodePaths.empty())
        {
            osg::Matrix psToWorld = osg::computeLocalToWorld(partsysNodePaths[0]);
            worldToPs = osg::Matrix::inverse(psToWorld);
        }

        const osg::Matrix& ltw = getLocalToWorldMatrix();
        osg::Matrix emitterToPs = ltw * worldToPs;

        osg::ref_ptr<osg::Vec3Array> geometryVertices = nullptr;

        const bool useGeometryEmitter = mFlags & Nif::NiParticleSystemController::BSPArrayController_AtVertex;

        if (useGeometryEmitter || !mTargets.empty())
        {
            int recordIndex;

            if (useGeometryEmitter)
            {
                if (!mGeometryEmitterTarget.has_value())
                    return;

                recordIndex = mGeometryEmitterTarget.value();
            }
            else
            {
                size_t randomIndex = Misc::Rng::rollDice(mTargets.size());
                recordIndex = mTargets[randomIndex];
            }

            // we could use a map here for faster lookup
            FindGroupByRecordIndex visitor(recordIndex);
            getParent(0)->accept(visitor);

            if (!visitor.mFound)
            {
                Log(Debug::Info) << "Can't find emitter node" << recordIndex;
                return;
            }

            if (useGeometryEmitter)
            {
                if (!mCachedGeometryEmitter.lock(geometryVertices))
                {
                    FindFirstGeometry geometryVisitor;
                    visitor.mFound->accept(geometryVisitor);

                    if (geometryVisitor.mGeometry)
                    {
                        if (auto* vertices = dynamic_cast<osg::Vec3Array*>(geometryVisitor.mGeometry->getVertexArray()))
                        {
                            mCachedGeometryEmitter = osg::observer_ptr<osg::Vec3Array>(vertices);
                            geometryVertices = vertices;
                        }
                    }
                }
            }

            osg::NodePath path = visitor.mFoundPath;
            path.erase(path.begin());
            if (!useGeometryEmitter && (mFlags & Nif::NiParticleSystemController::BSPArrayController_AtNode)
                && path.size())
            {
                osg::Matrix current;

                LocalToWorldAccumulator accum(current);
                accum.accumulate(path);

                osg::Matrix parent = accum.mLastMatrix.value_or(current);

                auto p1 = parent.getTrans();
                auto p2 = current.getTrans();
                current.setTrans((p2 - p1) * Misc::Rng::rollClosedProbability() + p1);

                emitterToPs = current * emitterToPs;
            }
            else
            {
                emitterToPs = osg::computeLocalToWorld(path) * emitterToPs;
            }
        }

        emitterToPs.orthoNormalize(emitterToPs);

        if (useGeometryEmitter && (!geometryVertices.valid() || geometryVertices->empty()))
            return;

        for (int i = 0; i < n; ++i)
        {
            osgParticle::Particle* const particle = getParticleSystem()->createParticle(nullptr);
            if (particle)
            {
                if (useGeometryEmitter)
                    particle->setPosition((*geometryVertices)[Misc::Rng::rollDice(geometryVertices->getNumElements())]);
                else if (mPlacer)
                    mPlacer->place(particle);

                mShooter->shoot(particle);

                particle->transformPositionVelocity(emitterToPs);
            }
        }
    }

    FindGroupByRecordIndex::FindGroupByRecordIndex(unsigned int recordIndex)
        : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
        , mFound(nullptr)
        , mRecordIndex(recordIndex)
    {
    }

    void FindGroupByRecordIndex::apply(osg::Node& node)
    {
        applyNode(node);
    }

    void FindGroupByRecordIndex::apply(osg::MatrixTransform& node)
    {
        applyNode(node);
    }

    void FindGroupByRecordIndex::apply(osg::Geometry& node)
    {
        applyNode(node);
    }

    void FindGroupByRecordIndex::applyNode(osg::Node& searchNode)
    {
        unsigned int recordIndex;
        if (searchNode.getUserValue("recordIndex", recordIndex) && mRecordIndex == recordIndex)
        {
            osg::Group* group = searchNode.asGroup();
            if (!group)
                group = searchNode.getParent(0);

            mFound = group;
            mFoundPath = getNodePath();
            return;
        }
        traverse(searchNode);
    }

    PlanarCollider::PlanarCollider(const Nif::NiPlanarCollider* collider)
        : mBounceFactor(collider->mBounceFactor)
        , mExtents(collider->mExtents)
        , mPosition(collider->mPosition)
        , mXVector(collider->mXVector)
        , mYVector(collider->mYVector)
        , mPlane(-collider->mPlaneNormal, collider->mPlaneDistance)
    {
    }

    PlanarCollider::PlanarCollider(const PlanarCollider& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mBounceFactor(copy.mBounceFactor)
        , mExtents(copy.mExtents)
        , mPosition(copy.mPosition)
        , mPositionInParticleSpace(copy.mPositionInParticleSpace)
        , mXVector(copy.mXVector)
        , mXVectorInParticleSpace(copy.mXVectorInParticleSpace)
        , mYVector(copy.mYVector)
        , mYVectorInParticleSpace(copy.mYVectorInParticleSpace)
        , mPlane(copy.mPlane)
        , mPlaneInParticleSpace(copy.mPlaneInParticleSpace)
    {
    }

    void PlanarCollider::beginOperate(osgParticle::Program* program)
    {
        mPositionInParticleSpace = mPosition;
        mPlaneInParticleSpace = mPlane;
        mXVectorInParticleSpace = mXVector;
        mYVectorInParticleSpace = mYVector;
        if (program->getReferenceFrame() == osgParticle::ParticleProcessor::ABSOLUTE_RF)
        {
            mPositionInParticleSpace = program->transformLocalToWorld(mPosition);
            mPlaneInParticleSpace.transform(program->getLocalToWorldMatrix());
            mXVectorInParticleSpace = program->rotateLocalToWorld(mXVector);
            mYVectorInParticleSpace = program->rotateLocalToWorld(mYVector);
        }
    }

    void PlanarCollider::operate(osgParticle::Particle* particle, double dt)
    {
        const osg::Vec3 normal = mPlaneInParticleSpace.getNormal();

        // Does the particle in question move towards the collider?
        float distToPlane = mPlaneInParticleSpace.distance(particle->getPosition());
        float velDotProduct = particle->getVelocity() * normal;
        if (distToPlane * velDotProduct >= 0.0f)
            return;

        // Would it cross the collider?
        float nextDistToPlane = distToPlane + velDotProduct * static_cast<float>(dt);
        if (distToPlane * nextDistToPlane > 0.0f)
            return;

        // Is it inside the collider's bounds?
        osg::Vec3f relativePos = particle->getPosition() - mPositionInParticleSpace;
        float xDotProduct = relativePos * mXVectorInParticleSpace;
        float yDotProduct = relativePos * mYVectorInParticleSpace;
        // NB: extent components are intentionally swapped
        if (-mExtents.y() * 0.5f > xDotProduct || mExtents.y() * 0.5f < xDotProduct)
            return;
        if (-mExtents.x() * 0.5f > yDotProduct || mExtents.x() * 0.5f < yDotProduct)
            return;

        // Deflect the particle
        osg::Vec3 reflectedVelocity = particle->getVelocity() - normal * (2 * velDotProduct);
        reflectedVelocity *= mBounceFactor;
        particle->setVelocity(reflectedVelocity);
    }

    SphericalCollider::SphericalCollider(const Nif::NiSphericalCollider* collider)
        : mBounceFactor(collider->mBounceFactor)
        , mSphere(collider->mCenter, collider->mRadius)
    {
    }

    SphericalCollider::SphericalCollider()
        : mBounceFactor(1.0f)
    {
    }

    SphericalCollider::SphericalCollider(const SphericalCollider& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mBounceFactor(copy.mBounceFactor)
        , mSphere(copy.mSphere)
        , mSphereInParticleSpace(copy.mSphereInParticleSpace)
    {
    }

    void SphericalCollider::beginOperate(osgParticle::Program* program)
    {
        mSphereInParticleSpace = mSphere;
        if (program->getReferenceFrame() == osgParticle::ParticleProcessor::ABSOLUTE_RF)
            mSphereInParticleSpace.center() = program->transformLocalToWorld(mSphereInParticleSpace.center());
    }

    void SphericalCollider::operate(osgParticle::Particle* particle, double dt)
    {
        osg::Vec3f cent
            = (particle->getPosition() - mSphereInParticleSpace.center()); // vector from sphere center to particle

        bool insideSphere = cent.length2() <= mSphereInParticleSpace.radius2();

        if (insideSphere
            || (cent * particle->getVelocity()
                < 0.0f)) // if outside, make sure the particle is flying towards the sphere
        {
            // Collision test (finding point of contact) is performed by solving a quadratic equation:
            // ||vec(cent) + vec(vel)*k|| = R      /^2
            // k^2 + 2*k*(vec(cent)*vec(vel))/||vec(vel)||^2 + (||vec(cent)||^2 - R^2)/||vec(vel)||^2 = 0

            float b = -(cent * particle->getVelocity()) / particle->getVelocity().length2();

            osg::Vec3f u = cent + particle->getVelocity() * b;

            if (insideSphere || (u.length2() < mSphereInParticleSpace.radius2()))
            {
                float d = (mSphereInParticleSpace.radius2() - u.length2()) / particle->getVelocity().length2();
                float k = insideSphere ? (std::sqrt(d) + b) : (b - std::sqrt(d));

                if (k < dt)
                {
                    // collision detected; reflect off the tangent plane
                    osg::Vec3f contact = particle->getPosition() + particle->getVelocity() * k;

                    osg::Vec3 normal = (contact - mSphereInParticleSpace.center());
                    normal.normalize();

                    float dotproduct = particle->getVelocity() * normal;

                    osg::Vec3 reflectedVelocity = particle->getVelocity() - normal * (2 * dotproduct);
                    reflectedVelocity *= mBounceFactor;
                    particle->setVelocity(reflectedVelocity);
                }
            }
        }
    }

}

namespace NifOsg
{
    VolumePlacer::VolumePlacer(Shape shape, const osg::Vec3f& extents)
        : mShape(shape)
        , mExtents(extents)
    {
    }

    VolumePlacer::VolumePlacer(const VolumePlacer& copy, const osg::CopyOp& copyop)
        : osgParticle::Placer(copy, copyop)
        , mShape(copy.mShape)
        , mExtents(copy.mExtents)
    {
    }

    void VolumePlacer::place(osgParticle::Particle* particle) const
    {
        auto unit = [] { return 2.f * Misc::Rng::rollClosedProbability() - 1.f; };
        osg::Vec3f position;
        switch (mShape)
        {
            case Shape::Box:
                position = osg::Vec3f(unit() * mExtents.x(), unit() * mExtents.y(), unit() * mExtents.z()) * 0.5f;
                break;
            case Shape::Sphere:
            {
                osg::Vec3f v;
                do
                    v = osg::Vec3f(unit(), unit(), unit());
                while (v.length2() > 1.f);
                position = v * mExtents.x();
                break;
            }
            case Shape::Cylinder:
            {
                osg::Vec2f v;
                do
                    v = osg::Vec2f(unit(), unit());
                while (v.length2() > 1.f);
                // Gamebryo's emitter cylinders stand along the emitter's x axis
                position = osg::Vec3f(unit() * mExtents.y() * 0.5f, v.x() * mExtents.x(), v.y() * mExtents.x());
                break;
            }
        }
        particle->setPosition(position);
    }

    PSysGravityAffector::PSysGravityAffector(const Nif::NiPSysGravityModifier* gravity)
        : mAxis(gravity->mGravityAxis)
        , mStrength(gravity->mStrength)
        , mPoint(gravity->mForceType == Nif::ForceType::Point)
        , mWorldAligned(gravity->mWorldAligned)
    {
        mAxis.normalize();
    }

    PSysGravityAffector::PSysGravityAffector(const PSysGravityAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mAxis(copy.mAxis)
        , mStrength(copy.mStrength)
        , mPoint(copy.mPoint)
        , mWorldAligned(copy.mWorldAligned)
    {
    }

    void PSysGravityAffector::beginOperate(osgParticle::Program* program)
    {
        const bool absolute = program->getReferenceFrame() == osgParticle::ParticleProcessor::ABSOLUTE_RF;
        if (mWorldAligned)
            mCachedAxis = absolute ? mAxis : program->rotateWorldToLocal(mAxis);
        else
            mCachedAxis = absolute ? program->rotateLocalToWorld(mAxis) : mAxis;
        mCachedAxis.normalize();
        mCachedPosition = absolute ? program->transformLocalToWorld(osg::Vec3f()) : osg::Vec3f();
    }

    void PSysGravityAffector::operate(osgParticle::Particle* particle, double dt)
    {
        // Gravity pulls against its axis: blood (axis +z, worldaligned) falls
        osg::Vec3f pull = -mCachedAxis;
        if (mPoint)
        {
            pull = mCachedPosition - particle->getPosition();
            if (pull.normalize() == 0.f)
                return;
        }
        particle->addVelocity(pull * mStrength * static_cast<float>(dt));
    }

    PSysDragAffector::PSysDragAffector(float percentage)
        : mPercentage(percentage)
    {
    }

    PSysDragAffector::PSysDragAffector(const PSysDragAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mPercentage(copy.mPercentage)
    {
    }

    void PSysDragAffector::operate(osgParticle::Particle* particle, double dt)
    {
        const float keep = std::max(0.f, 1.f - mPercentage * static_cast<float>(dt));
        particle->setVelocity(particle->getVelocity() * keep);
    }

    SimpleColorAffector::SimpleColorAffector(const Nif::BSPSysSimpleColorModifier* modifier)
        : mFadeIn(modifier->mFadeInPercent)
        , mFadeOut(modifier->mFadeOutPercent)
        , mColor1Start(modifier->mColor1StartPercent)
        , mColor1End(modifier->mColor1EndPercent)
        , mColor2Start(modifier->mColor2StartPercent)
        , mColor2End(modifier->mColor2EndPercent)
    {
        for (std::size_t i = 0; i < 3; ++i)
            mColors[i] = i < modifier->mColors.size() ? modifier->mColors[i] : osg::Vec4f(1, 1, 1, 1);
    }

    SimpleColorAffector::SimpleColorAffector(const SimpleColorAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mFadeIn(copy.mFadeIn)
        , mFadeOut(copy.mFadeOut)
        , mColor1Start(copy.mColor1Start)
        , mColor1End(copy.mColor1End)
        , mColor2Start(copy.mColor2Start)
        , mColor2End(copy.mColor2End)
    {
        for (std::size_t i = 0; i < 3; ++i)
            mColors[i] = copy.mColors[i];
    }

    void SimpleColorAffector::operate(osgParticle::Particle* particle, double /* dt */)
    {
        const float life = static_cast<float>(particle->getLifeTime());
        const float t = life > 0.f ? std::clamp(static_cast<float>(particle->getAge()) / life, 0.f, 1.f) : 0.f;
        auto blend = [](const osg::Vec4f& a, const osg::Vec4f& b, float from, float to, float at) {
            if (to <= from)
                return at < to ? a : b;
            const float f = std::clamp((at - from) / (to - from), 0.f, 1.f);
            return a * (1.f - f) + b * f;
        };
        // Bethesda's three keys: the first colour blends into the second until the colour 1 end, the second holds
        // and blends into the third from the colour 2 start to the colour 2 end. Without percentages the second
        // colour is the particles' colour all their life (the first is often black, only a starting point).
        osg::Vec4f color = mColors[1];
        if (mColor1End > 0.f && t < mColor1End)
            color = blend(mColors[0], mColors[1], 0.f, mColor1End, t);
        else if (mColor2End > mColor2Start && t > mColor2Start)
            color = blend(mColors[1], mColors[2], mColor2Start, mColor2End, t);
        // Fade in over the first fade-in share of the life, out from the fade-out point on
        float alpha = color.a();
        if (mFadeIn > 0.f && t < mFadeIn)
            alpha *= t / mFadeIn;
        if (mFadeOut > 0.f && mFadeOut < 1.f && t > mFadeOut)
            alpha *= (1.f - t) / (1.f - mFadeOut);
        color.a() = 1.f;
        particle->setColorRange(osgParticle::rangev4(color, color));
        particle->setAlphaRange(osgParticle::rangef(alpha, alpha));
    }
}

namespace NifOsg
{
    RandomTileAffector::RandomTileAffector(int sTiles, int tTiles)
        : mSTiles(std::max(1, sTiles))
        , mTTiles(std::max(1, tTiles))
    {
    }

    RandomTileAffector::RandomTileAffector(const RandomTileAffector& copy, const osg::CopyOp& copyop)
        : osgParticle::Operator(copy, copyop)
        , mSTiles(copy.mSTiles)
        , mTTiles(copy.mTTiles)
    {
    }

    void RandomTileAffector::operate(osgParticle::Particle* particle, double /* dt */)
    {
        // A new particle still has the whole texture as its one tile
        if (particle->getTileS() == mSTiles && particle->getTileT() == mTTiles)
            return;
        const int tile = Misc::Rng::rollDice(mSTiles * mTTiles);
        particle->setTextureTileRange(mSTiles, mTTiles, tile, tile);
    }
}
