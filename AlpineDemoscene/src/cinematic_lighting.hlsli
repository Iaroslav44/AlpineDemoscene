#ifndef ALPINE_CINEMATIC_LIGHTING
#define ALPINE_CINEMATIC_LIGHTING
#include "scene_common.hlsli"

// GPU frame contract, generated once by CameraCS. Bind the same SRVs to VS/PS.
// 0..3 current camera origin/lens, forward, right/aspect, up/near;
// 4..7 previous origin/lens, forward, right, up;
// 8 sun direction/intensity; 9 shadow centre/texel size;
// 10 shadow right/XY half extent; 11 shadow up/depth half extent.
StructuredBuffer<float4> CinematicFrame : register(t3);
Texture2D<float> CinematicShadowMap : register(t2);
SamplerState CinematicSampler : register(s0);

float3 CinematicSunDirection(float a)
{
    return normalize(float3(-0.55+0.18*cos(a),0.28+0.12*sin(a-0.5),0.8+0.18*sin(a)));
}
float3 CinematicSunColor() { return float3(1.0,0.87,0.72); }
float3 CinematicViewOrigin()
{
    float3 p=CinematicFrame[0].xyz;
    if(PassMode.x>0.5)p.y=2.0*LAKE_Y-p.y;
    return p;
}
float3 CinematicShadowPosition(float3 p)
{
    float3 d=p-CinematicFrame[9].xyz;
    return float3(dot(d,CinematicFrame[10].xyz)/CinematicFrame[10].w,
                  dot(d,CinematicFrame[11].xyz)/CinematicFrame[10].w,
                  0.5-dot(d,CinematicFrame[8].xyz)/(2.0*CinematicFrame[11].w));
}
float CinematicShadow(float3 p,float3 n)
{
    float3 q=CinematicShadowPosition(p);
    if(any(abs(q.xy)>0.995)||q.z<=0.0||q.z>=1.0)return 1.0;
    float2 uv=q.xy*float2(0.5,-0.5)+0.5;
    // World-space normal/slope bias; a normal offset alone loses thin twigs.
    float bias=(0.025+0.075*(1.0-saturate(dot(n,CinematicFrame[8].xyz))))/
               (2.0*CinematicFrame[11].w);
    // PCF taps lie at different positions on the receiver. Comparing every tap
    // to the centre depth produces a regular acne pattern on oblique plaster.
    // Correct each tap to its receiver-plane depth instead of adding a large,
    // detached-shadow bias. A grazing guard bounds the planar approximation.
    float nd=dot(n,-CinematicFrame[8].xyz);
    nd=(nd<0.0?-1.0:1.0)*max(abs(nd),0.12);
    float2 planeGradient=float2(-dot(n,CinematicFrame[10].xyz),dot(n,CinematicFrame[11].xyz))*
                         (CinematicFrame[10].w/(CinematicFrame[11].w*nd));
    float visibility=0.0;
    [unroll]for(int y=-1;y<=1;++y)[unroll]for(int x=-1;x<=1;++x)
    {
        int2 pixel=clamp(int2(uv/CinematicFrame[9].w)+int2(x,y),int2(0,0),int2(2047,2047));
        float z=CinematicShadowMap.Load(int3(pixel,0));
        float2 deltaUV=(float2(pixel)+0.5)*CinematicFrame[9].w-uv;
        float receiver=q.z+dot(planeGradient,deltaUV);
        visibility+=(receiver-bias<=z)?1.0:0.0;
    }
    return visibility/9.0;
}
float3 CinematicLightingVisible(float3 n,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility)
{
    float3 l=CinematicFrame[8].xyz,h=l+v;
    h*=rsqrt(max(dot(h,h),1e-8));
    float nl=saturate(dot(n,l)),nv=max(0.025,saturate(dot(n,v)));
    float nh=saturate(dot(n,h)),vh=saturate(dot(v,h));
    float a=max(0.045,rough*rough),a2=a*a;
    float den=nh*nh*(a2-1.0)+1.0;
    float D=a2/(PI*den*den);
    float visibility=0.5/max(nl*sqrt(nv*nv*(1.0-a2)+a2)+nv*sqrt(nl*nl*(1.0-a2)+a2),1e-5);
    float3 F=lerp(0.04,albedo,metal)+(1.0-lerp(0.04,albedo,metal))*pow(1.0-vh,5.0);
    float3 direct=((1.0-F)*albedo*(1.0-metal)/PI+D*visibility*F)*nl;
    direct*=CinematicSunColor()*CinematicFrame[8].w*sunVisibility;
    float hemi=saturate(n.y*0.5+0.5);
    float3 sky=lerp(float3(0.055,0.059,0.043),float3(0.20,0.26,0.33),hemi);
    return direct+albedo*sky*ao;
}
float3 CinematicLightingShadow(float3 p,float3 n,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility)
{
    return CinematicLightingVisible(n,v,albedo,rough,metal,ao,CinematicShadow(p,n)*sunVisibility);
}
float3 CinematicLighting(float3 p,float3 n,float3 v,float3 albedo,float rough,float metal,float ao)
{
    return CinematicLightingShadow(p,n,v,albedo,rough,metal,ao,1.0);
}
float3 CinematicFog(float3 col,float3 world)
{
    float3 origin=CinematicViewOrigin(),delta=world-origin;
    float d=length(delta),h=max(0.0,(world.y+origin.y)*0.5-145.0);
    float fog=1.0-exp(-d*0.000065*exp(-h*0.0008));
    float sun=pow(saturate(dot(normalize(delta),CinematicFrame[8].xyz)),12.0);
    return lerp(col,float3(0.40,0.53,0.66)+sun*float3(0.22,0.15,0.07),fog);
}
#endif
