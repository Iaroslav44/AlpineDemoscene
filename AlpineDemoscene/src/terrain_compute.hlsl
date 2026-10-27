#define ALPINE_TERRAIN_GENERATOR 1
#include "scene_common.hlsli"
RWTexture2D<float> HeightOutput : register(u0);

// Sixteen million world heights are synthesized once into GPU memory. The EXE
// stores these equations, not a pre-generated terrain image or mesh.
[numthreads(8,8,1)]
void TerrainCS(uint3 thread : SV_DispatchThreadID)
{
    if(any(thread.xy>=TERRAIN_RES))return;
    float2 xz=float2(-6000.0,-1500.0)+float2(thread.xy)*TERRAIN_TEXEL;
    HeightOutput[thread.xy]=TerrainRaw(xz);
}
