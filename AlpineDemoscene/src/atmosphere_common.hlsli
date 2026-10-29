#ifndef ALPINE_ATMOSPHERE_COMMON
#define ALPINE_ATMOSPHERE_COMMON
Texture2D<float4> AtmosphereLUT : register(t10);
Texture2D<float4> AtmosphereIrradiance : register(t26);
#include "atmosphere_sh.hlsli"
#include "sampler_common.hlsli"
float3 AtmosphereEnvironment(float3 direction)
{
    direction=normalize(direction);
    float longitude=dot(direction.xz,direction.xz)>1e-10?atan2(direction.z,direction.x):0;
    float2 uv=float2(longitude/TAU+.5,acos(clamp(direction.y,-1.0,1.0))/PI);
    return AtmosphereLUT.SampleLevel(MaterialSampler,float2(uv.x,clamp(uv.y,.5/128.0,127.5/128.0)),0).rgb;
}
float3 AtmosphereDiffuse(float3 normal)
{
    // Lambertian convolution through order two (nine real SH coefficients).
    // Unlike five rotating hemisphere taps, this is continuous across every
    // normal direction and has no tangent-basis flip or sampled horizon bands.
    float3 radiance=0;
    [unroll]for(uint k=0;k<9;++k)
        radiance+=AtmosphereIrradiance.Load(int3(k,0,0)).rgb*AtmosphereSHBasis(k,normal);
    return max(0,radiance); // truncated SH can undershoot below zero
}
#endif
