#ifndef ALPINE_ATMOSPHERE_COMMON
#define ALPINE_ATMOSPHERE_COMMON
Texture2D<float4> AtmosphereLUT : register(t10);
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
    float3 tangent=normalize(cross(abs(normal.y)<.95?float3(0,1,0):float3(1,0,0),normal));
    float3 bitangent=cross(normal,tangent);
    // Deterministic cosine-weighted hemispherical quadrature, in radiance
    // units (irradiance/PI). Sky colours now come from the transport cache.
    float3 radiance=AtmosphereEnvironment(normal)*.25;
    radiance+=AtmosphereEnvironment(normal*.7071+tangent*.7071)*.1875;
    radiance+=AtmosphereEnvironment(normal*.7071-tangent*.7071)*.1875;
    radiance+=AtmosphereEnvironment(normal*.7071+bitangent*.7071)*.1875;
    radiance+=AtmosphereEnvironment(normal*.7071-bitangent*.7071)*.1875;
    return radiance;
}
#endif
