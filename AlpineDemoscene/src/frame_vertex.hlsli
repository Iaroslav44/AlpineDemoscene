#ifndef ALPINE_FRAME_VERTEX
#define ALPINE_FRAME_VERTEX
#include "scene_common.hlsli"

// Uniform camera state is evaluated by three vertices, not by every pixel.
// Flat interpolation preserves identical current/previous frames in all passes.
struct VSOut
{
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
    nointerpolation float4 cameraOriginLens : TEXCOORD1;
    nointerpolation float3 cameraForward : TEXCOORD2;
    nointerpolation float3 cameraRight : TEXCOORD3;
    nointerpolation float3 cameraUp : TEXCOORD4;
    nointerpolation float4 previousOriginLens : TEXCOORD5;
    nointerpolation float3 previousForward : TEXCOORD6;
    nointerpolation float3 previousRight : TEXCOORD7;
    nointerpolation float3 previousUp : TEXCOORD8;
};

VSOut BuildFrameVertex(uint id,float seconds,float previousSeconds)
{
    VSOut o;
    o.uv=float2((id<<1)&2,id&2);
    o.pos=float4(o.uv*float2(2,-2)+float2(-1,1),0,1);
    CameraFrame c=PassCameraFrame(GetCameraFrame(seconds)),p=PassCameraFrame(GetCameraFrame(previousSeconds));
    o.cameraOriginLens=float4(c.origin,c.lens);
    o.cameraForward=c.forward;o.cameraRight=c.right;o.cameraUp=c.up;
    o.previousOriginLens=float4(p.origin,p.lens);
    o.previousForward=p.forward;o.previousRight=p.right;o.previousUp=p.up;
    return o;
}

CameraFrame CurrentFrameCamera(VSOut v)
{
    CameraFrame c;
    c.origin=v.cameraOriginLens.xyz;c.lens=v.cameraOriginLens.w;
    c.forward=v.cameraForward;c.right=v.cameraRight;c.up=v.cameraUp;
    return c;
}
CameraFrame PreviousFrameCamera(VSOut v)
{
    CameraFrame c;
    c.origin=v.previousOriginLens.xyz;c.lens=v.previousOriginLens.w;
    c.forward=v.previousForward;c.right=v.previousRight;c.up=v.previousUp;
    return c;
}
#endif
