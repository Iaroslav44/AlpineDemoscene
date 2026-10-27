// Resource119: composite participating cloud media AFTER every opaque draw.
// The same pass runs after reflection meshes and after the main human draw.
// t0 is the completed opaque HDR image with signed logarithmic ray depth.
// Cloud transmittance therefore attenuates houses, trees, gliders and people
// together with terrain; no object can be pasted in front of a nearer cloud.
#include "frame_vertex.hlsli"
#include "cinematic_lighting.hlsli"
#define ALPINE_CLOUD_NO_REFLECTION
#include "cloud_render.hlsli"
cbuffer Frame : register(b0) { float4 G; float4 G2; };
Texture2D<float4> OpaqueFrame : register(t0);

float4 CloudCompositePS(VSOut input):SV_Target
{
    uint width,height;OpaqueFrame.GetDimensions(width,height);
    int2 pixel=clamp(int2(input.pos.xy),int2(0,0),int2(width,height)-1);
    float4 opaque=OpaqueFrame.Load(int3(pixel,0));
    CameraFrame camera=CurrentFrameCamera(input);
    float2 sampleUV=input.uv+TemporalJitter(((int)G.w)&7)/G.xy;
    float3 ray=CameraRay(camera,sampleUV,G.x/G.y);
    float limit=min(MAX_DIST,DecodeDepth(abs(opaque.a))),start=0.0;
    if(PassMode.x>.5)
    {
        // Match the reflection world's lake clip plane and mirrored camera.
        if(ray.y<=.00001)return opaque;
        start=max(0.0,(LAKE_Y+.03-camera.origin.y)/ray.y);
        if(start>=limit)return opaque;
    }
    float loopA=fmod(G.z,128.0)*(TAU/128.0);
    float4 cloud=CloudLayer(camera.origin+ray*start,ray,limit-start,
        CinematicFrame[8].xyz,loopA,input.pos.xy);
    float depth=abs(opaque.a);
    if(opaque.a<0||cloud.a>.015)depth=-max(depth,.0001);
    return float4(max(0.0,cloud.rgb+opaque.rgb*(1.0-cloud.a)),depth);
}
