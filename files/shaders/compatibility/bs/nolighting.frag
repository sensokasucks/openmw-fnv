#version 120
#pragma import_defines(FORCE_OPAQUE)

#if @useGPUShader4
    #extension GL_EXT_gpu_shader4: require
#endif

#if @diffuseMap
uniform sampler2D diffuseMap;
varying vec2 diffuseMapUV;
#endif

varying vec3 passViewPos;
varying vec3 passNormal;
varying float euclideanDepth;
varying float linearDepth;
varying float passFalloff;

uniform vec2 screenRes;
uniform bool useFalloff;
uniform float far;
uniform float near;
uniform float alphaRef;
// The material's own alpha (NiMaterialProperty, animated by NiAlphaController): with vertex colours on,
// gl_FrontMaterial tracks the vertex colour and loses it
uniform float materialAlpha;

#include "lib/core/fragment.h.glsl"
#include "lib/material/alpha.glsl"

#include "compatibility/vertexcolors.glsl"
#include "compatibility/fog.glsl"
#include "compatibility/shadows_fragment.glsl"

#if @softParticles
#include "lib/particle/soft.glsl"

uniform float particleSize;
uniform bool particleFade;
uniform float softFalloffDepth;
#endif

void main()
{
#if @diffuseMap
    gl_FragData[0] = texture2D(diffuseMap, diffuseMapUV);
    gl_FragData[0].a *= coveragePreservingAlphaScale(diffuseMap, diffuseMapUV);
#else
    gl_FragData[0] = vec4(1.0);
#endif

    gl_FragData[0] *= getDiffuseColor();

    // Gamebryo multiplies the vertex alpha by the material's alpha; the colour mode above swaps the material
    // out for the vertex colour, so the material alpha (an animated fade on FO3/FNV dust, mist and beams)
    // has to be put back
    if (colorMode == ColorMode_AmbientAndDiffuse || colorMode == ColorMode_Diffuse)
        gl_FragData[0].a *= materialAlpha;

    if (useFalloff)
        gl_FragData[0].a *= passFalloff;

    gl_FragData[0].a = alphaTest(gl_FragData[0].a, alphaRef);

    gl_FragData[0] = applyFogAtDist(gl_FragData[0], euclideanDepth, linearDepth, far);

#if !defined(FORCE_OPAQUE) && @softParticles
    vec2 screenCoords = gl_FragCoord.xy / screenRes;
    vec3 viewVec = normalize(passViewPos.xyz);
    vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);

    gl_FragData[0].a *= calcSoftParticleFade(
        viewVec,
        passViewPos,
        viewNormal,
        near,
        far,
        sampleOpaqueDepthTex(screenCoords).x,
        particleSize,
        particleFade,
        softFalloffDepth
    );
#endif

#if defined(FORCE_OPAQUE) && FORCE_OPAQUE
    gl_FragData[0].a = 1.0;
#endif

#if !defined(FORCE_OPAQUE) && !@disableNormals
    vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);
    gl_FragData[1].xyz = viewNormal * 0.5 + 0.5;
#endif

    applyShadowDebugOverlay();
}
