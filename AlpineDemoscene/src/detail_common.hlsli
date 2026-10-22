#ifndef ALPINE_DETAIL_COMMON
#define ALPINE_DETAIL_COMMON
#include "scene_common.hlsli"

// Stable world-space value noise with exact spatial derivatives. These are
// material fields evaluated at runtime, not sampled/embedded asset textures.
float3 DetailNoise2(float2 p)
{
    float2 i=floor(p),f=frac(p);
    float2 u=f*f*(3.0-2.0*f),du=6.0*f*(1.0-f);
    float a=Hash21(i),b=Hash21(i+float2(1,0));
    float c=Hash21(i+float2(0,1)),d=Hash21(i+1.0);
    float v=lerp(lerp(a,b,u.x),lerp(c,d,u.x),u.y);
    return float3(v,lerp(b-a,d-c,u.y)*du.x,lerp(c-a,d-b,u.x)*du.y);
}

float4 DetailNoise3(float3 p)
{
    float iy=floor(p.y),fy=frac(p.y),u=fy*fy*(3.0-2.0*fy);
    float3 a=DetailNoise2(p.xz+float2(37,17)*iy);
    float3 b=DetailNoise2(p.xz+float2(37,17)*(iy+1.0));
    return float4(lerp(a.x,b.x,u),lerp(a.y,b.y,u),
                  (b.x-a.x)*6.0*fy*(1.0-fy),lerp(a.z,b.z,u));
}

float DetailBand(float footprint,float frequency)
{
    // Fade wavelengths below roughly two pixels before they can sparkle.
    return 1.0-smoothstep(0.18,0.65,footprint*frequency);
}

float3 DetailNormal(float3 normal,float3 gradient)
{
    float3 tangent=gradient-normal*dot(normal,gradient);
    return normalize(normal-tangent);
}
#endif
