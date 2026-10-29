#ifndef ALPINE_CINEMATIC_LIGHTING
#define ALPINE_CINEMATIC_LIGHTING
#include "scene_common.hlsli"
#include "atmosphere_common.hlsli"

// GPU frame contract, generated once by CameraCS. Bind the same SRVs to VS/PS.
// 0..3 current camera origin/lens, forward, right/aspect, up/near;
// 4..7 previous origin/lens, forward, right, up;
// 8 sun direction/intensity; 9 shadow centre/texel size;
// 10 shadow right/XY half extent; 11 shadow up/depth half extent;
// 12..14 distant shadow centre/texel size, right/extent, up/depth extent.
StructuredBuffer<float4> CinematicFrame : register(t3);
Texture2D<float> CinematicShadowMap : register(t2);
Texture2D<float> CinematicFarShadowMap : register(t11);
SamplerState CinematicSampler : register(s0);

float3 CinematicSunDirection(float a)
{
    return normalize(float3(-0.68+0.10*cos(a),0.60+0.10*sin(a-0.5),-0.58+0.20*sin(a)));
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
    uint k=PassMode.z>.5?12:9;
    float3 d=p-CinematicFrame[k].xyz;
    return float3(dot(d,CinematicFrame[k+1].xyz)/CinematicFrame[k+1].w,
                  dot(d,CinematicFrame[k+2].xyz)/CinematicFrame[k+1].w,
                  0.5-dot(d,CinematicFrame[8].xyz)/(2.0*CinematicFrame[k+2].w));
}
float ShadowCascade(float3 p,float3 n,bool farCascade,out float border)
{
    uint k=farCascade?12:9;
    float3 d=p-CinematicFrame[k].xyz;
    float3 q=float3(dot(d,CinematicFrame[k+1].xyz)/CinematicFrame[k+1].w,
                  dot(d,CinematicFrame[k+2].xyz)/CinematicFrame[k+1].w,
                  0.5-dot(d,CinematicFrame[8].xyz)/(2.0*CinematicFrame[k+2].w));
    border=max(abs(q.x),abs(q.y));
    if(any(abs(q.xy)>0.995)||q.z<=0.0||q.z>=1.0)return 1.0;
    float2 uv=q.xy*float2(0.5,-0.5)+0.5;
    // World-space normal/slope bias; a normal offset alone loses thin twigs.
    float bias=(farCascade?.45:.025)+(farCascade?1.1:.075)*(1.0-saturate(dot(n,CinematicFrame[8].xyz)));
    bias/=2.0*CinematicFrame[k+2].w;
    // PCF taps lie at different positions on the receiver. Comparing every tap
    // to the centre depth produces a regular acne pattern on oblique plaster.
    // Correct each tap to its receiver-plane depth instead of adding a large,
    // detached-shadow bias. A grazing guard bounds the planar approximation.
    float nd=dot(n,-CinematicFrame[8].xyz);
    nd=(nd<0.0?-1.0:1.0)*max(abs(nd),0.12);
    float2 planeGradient=float2(-dot(n,CinematicFrame[k+1].xyz),dot(n,CinematicFrame[k+2].xyz))*
                         (CinematicFrame[k+1].w/(CinematicFrame[k+2].w*nd));
    float visibility=0.0;
    int resolution=farCascade?1024:2048;
    [unroll]for(int y=-1;y<=1;++y)[unroll]for(int x=-1;x<=1;++x)
    {
        int2 pixel=clamp(int2(uv/CinematicFrame[k].w)+int2(x,y),int2(0,0),int2(resolution-1,resolution-1));
        float z=farCascade?CinematicFarShadowMap.Load(int3(pixel,0)):CinematicShadowMap.Load(int3(pixel,0));
        float2 deltaUV=(float2(pixel)+0.5)*CinematicFrame[k].w-uv;
        float receiver=q.z+dot(planeGradient,deltaUV);
        visibility+=(receiver-bias<=z)?1.0:0.0;
    }
    return visibility/9.0;
}
float CinematicShadow(float3 p,float3 n)
{
    float nearBorder,farBorder;
    float nearVisibility=ShadowCascade(p,n,false,nearBorder);
    if(nearBorder<.75)return nearVisibility;
    float farVisibility=ShadowCascade(p,n,true,farBorder);
    return lerp(nearVisibility,farVisibility,smoothstep(.75,.97,nearBorder));
}
float3 CinematicLightingVisibleBentF0(float3 n,float3 bentNormal,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility,float3 dielectricF0)
{
    float3 l=CinematicFrame[8].xyz,h=l+v;
    h*=rsqrt(max(dot(h,h),1e-8));
    float nl=saturate(dot(n,l)),nv=max(0.025,saturate(dot(n,v)));
    float nh=saturate(dot(n,h)),vh=saturate(dot(v,h));
    rough=clamp(rough,.045,1.0);metal=saturate(metal);ao=saturate(ao);
    float a=max(0.025,rough*rough),a2=a*a;
    float den=nh*nh*(a2-1.0)+1.0;
    float D=a2/(PI*den*den);
    float visibility=0.5/max(nl*sqrt(nv*nv*(1.0-a2)+a2)+nv*sqrt(nl*nl*(1.0-a2)+a2),1e-5);
    float3 f0=lerp(clamp(dielectricF0,.002,.95),albedo,metal),F=f0+(1.0-f0)*pow(1.0-vh,5.0);
    // Rough diffuse retroreflection. The Fresnel factors reduce grazing
    // transmission; rough stone no longer responds like a uniformly painted
    // Lambert surface. This remains an analytic surface model, not full GI.
    float fd90=.5+2.0*rough*vh*vh;
    float diffuse=(1.0+(fd90-1.0)*pow(1.0-nl,5.0))
                 *(1.0+(fd90-1.0)*pow(1.0-nv,5.0));
    diffuse*=1.0-.18*rough; // bounds the high-roughness diffuse boost
    float3 direct=((1.0-F)*albedo*((1.0-metal)*diffuse/PI)+D*visibility*F)*nl;
    direct*=CinematicSunColor()*CinematicFrame[8].w*sunVisibility;
    float3 sky=AtmosphereDiffuse(bentNormal);
    // Analytic split-sum DFG fit. The sky-view cache has no reflection mips,
    // so the lobe broadens toward the diffuse normal with increasing roughness.
    // At rough=1 its specular irradiance is the same hemispherical quadrature
    // used for diffuse. No unoccluded mirror sky is added to crevices.
    float4 c0=float4(-1.0,-.0275,-.572,.022),c1=float4(1.0,.0425,1.04,-.04);
    float4 r=rough*c0+c1;
    float a004=min(r.x*r.x,exp2(-9.28*nv))*r.x+r.y;
    float2 dfg=float2(-1.04,1.04)*a004+r.zw;
    float3 reflected=reflect(-v,n);
    float3 env=AtmosphereEnvironment(normalize(lerp(reflected,bentNormal,a*.65)));
    env=lerp(env,sky,smoothstep(.35,1.0,rough));
    float specularOcclusion=saturate(pow(nv+ao,exp2(-16.0*rough-1.0))-1.0+ao);
    float3 indirectSpecular=env*(f0*dfg.x+dfg.y)*specularOcclusion;
    float3 indirectDiffuse=albedo*(1.0-metal)*(1.0-f0)*sky*ao;
    return max(0,direct+indirectDiffuse+indirectSpecular);
}
float3 CinematicLightingVisibleBent(float3 n,float3 bentNormal,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility)
{
    return CinematicLightingVisibleBentF0(n,bentNormal,v,albedo,rough,metal,ao,sunVisibility,.04);
}
float3 CinematicLightingVisible(float3 n,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility)
{
    return CinematicLightingVisibleBent(n,n,v,albedo,rough,metal,ao,sunVisibility);
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
    float d=max(length(delta),.001);
    // Analytic optical depth of an exponential medium along the whole ray.
    // Evaluating only the midpoint made a low valley disappear when the far
    // endpoint was a high summit. Reciprocal form stays stable for horizontal
    // views and for a mirror camera below the lake plane.
    float3 scale=float3(8000.0,1800.0,240.0);
    float3 raw0=(origin.y-float3(0,0,130))/scale;
    float3 raw1=(world.y-float3(0,0,130))/scale;
    float3 aboveFraction=saturate(max(raw0,raw1)/max(abs(raw1-raw0),1e-4));
    float3 h0=max(raw0,0.0),h1=max(raw1,0.0);
    float3 dh=abs(h1-h0);
    float3 integral=exp(-min(h0,h1))*(1.0-exp(-dh))/max(dh,1e-4);
    integral=lerp(exp(-(h0+h1)*.5),integral,step(1e-4,dh));
    integral=lerp(1.0,integral,aboveFraction);
    float3 optical=d*(float3(5.802,13.558,33.100)*1e-6*integral.x
                     +.0000155*integral.y+.000022*integral.z);
    float3 transmittance=exp(-optical);
    return col*transmittance+AtmosphereEnvironment(delta/d)*(1.0-transmittance);
}
#endif
