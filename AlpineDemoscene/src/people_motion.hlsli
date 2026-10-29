#ifndef ALPINE_PEOPLE_MOTION
#define ALPINE_PEOPLE_MOTION
#include "scene_common.hlsli"

// Shared trajectories for articulated residents and raster shadow proxies.
// Six actors, world XZ in metres; all paths repeat exactly every 128 seconds.
float2 PeopleCentre(int id,float seconds)
{
    float a=fmod(seconds,128.0)*(TAU/128.0);
    if(id==0)return float2(1.2*sin(2.0*a),1750.0+10.0*sin(a));
    float2 base=float2(-2.0,1804.0);
    if(id==1)base=float2(-2.0,1737.0);
    else if(id==2)base=float2(2.0,1768.0);
    else if(id==3)base=float2(-1.7,1781.0);
    else if(id==4)base=float2(2.0,1792.0);
    else base=float2(-2.0,1804.0);
    float rate=2.0+fmod((float)id,3.0);
    float phase=a*rate+(float)id*1.37;
    return base+float2(sin(phase)*0.45,cos(phase)*4.0);
}

float2 PeopleVelocity(int id,float seconds)
{
    float a=fmod(seconds,128.0)*(TAU/128.0);
    if(id==0)return float2(2.4*cos(2.0*a),10.0*cos(a))*(TAU/128.0);
    float rate=2.0+fmod((float)id,3.0);
    float phase=a*rate+(float)id*1.37;
    return float2(cos(phase)*0.45,-sin(phase)*4.0)*(rate*TAU/128.0);
}

float PeopleScale(int id)
{
    return id==0?1.02:0.94+0.02*fmod((float)id,5.0);
}

float3 PeopleRoot(int id,float seconds)
{
    float2 c=PeopleCentre(id,seconds);
    return float3(c.x,Terrain(c)+0.025,c.y);
}
#endif
