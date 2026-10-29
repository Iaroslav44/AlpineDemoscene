#ifndef ALPINE_GEOMORPH_COMMON
#define ALPINE_GEOMORPH_COMMON
// Runtime-simulated watershed state: moisture, soil/deposition, drainage, sky visibility.
Texture2D<float4> WorldEcotope : register(t19);
float4 WorldEcology(float2 xz)
{
    float2 uv=(xz-float2(-6000,-1500))/12000.0;
    return WorldEcotope.SampleLevel(TerrainSampler,saturate(uv),0);
}
#endif
