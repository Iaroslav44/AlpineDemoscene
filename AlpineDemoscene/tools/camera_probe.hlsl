cbuffer Frame : register(b0) { float4 G; float4 O; };
#include "../src/scene_common.hlsli"
struct VSOut { float4 pos:SV_POSITION; float2 uv:TEXCOORD0; };
float4 CameraProbe(VSOut input):SV_Target
{
    float seconds=G.z+(input.pos.x-0.5)*G.w/O.x;
    CameraFrame camera=GetCameraFrame(seconds);
    float2 uv=float2(frac(input.pos.y*0.6180339),frac(input.pos.y*0.381966));
    float3 ray=CameraRay(camera,uv,16.0/9.0);
    float z;
    float2 roundtrip=ProjectCamera(camera,camera.origin+ray*100.0,16.0/9.0,z);
    bool overLake=length((camera.origin.xz-LAKE_C)/float2(900.0,610.0))<1.05;
    float waterClearance=overLake?camera.origin.y-LAKE_Y:9999.0;
    return float4(camera.origin.y-Terrain(camera.origin.xz),length(roundtrip-uv),waterClearance,Terrain(TOWN_C));
}
