// Development-only regression for values which final color clamping can hide.
// Use the production hit/normal functions, including their dispersion math.
#include "../src/scene.hlsl"

float4 WaterProbe(VSOut input):SV_Target
{
    float2 uv=input.pos.xy/G.xy;
    float a=FlightTime(G.z)*TAU/128.0;
    float unresolved;
    // Exercise the deep-water limit and all eight fine-wave bands even when
    // the current camera misses the lake. Large k*depth exposed FXC tanh's
    // exp overflow; the test must inspect normals before saturate/max masks it.
    float3 deepNormal=WaterShadingNormal(float3(LAKE_C.x+uv.x*100.0,10000.0,LAKE_C.y+uv.y*100.0),
        normalize(float3(.3,-.08,1)),a,.001,unresolved);
    float dielectric=WaterFresnel(uv.x);
    float invalid=(all(isfinite(deepNormal))&&isfinite(unresolved)&&unresolved>=0.0
        &&isfinite(dielectric)&&dielectric>=.02036&&dielectric<=1.00001)?0.0:1.0;
    float error=invalid?0.0:abs(length(deepNormal)-1.0);
    CameraFrame camera=GetCameraFrame(G.z);
    float3 rd=CameraRay(camera,uv,16.0/9.0);
    float terrainT=TraceTerrain(camera.origin,rd,MAX_DIST);
    float waterT=WaterHit(camera.origin,rd,terrainT,a);
    if(waterT>=terrainT)return float4(invalid,error,0,0);
    float3 p=camera.origin+rd*waterT;
    float footprint=2.0*waterT/(720.0*camera.lens);
    float3 n=WaterShadingNormal(p,rd,a,footprint,unresolved);
    CameraFrame mirrored=MirrorLakeCamera(camera);
    float3 direction=normalize(float3(p.x,LAKE_Y,p.z)-mirrored.origin);
    direction=normalize(direction+reflect(rd,n)-reflect(rd,float3(0,1,0)));
    float z;
    float2 reflectionUV=ProjectCamera(mirrored,mirrored.origin+direction*1000.0,16.0/9.0,z);
    bool finite=all(isfinite(n))&&all(isfinite(reflectionUV))&&isfinite(z);
    invalid+=finite?0.0:1.0;
    if(finite)error=max(error,abs(length(n)-1.0));
    return float4(invalid,error,finite?dot(n.xz,n.xz):0.0,1.0);
}
