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
    return DiurnalSunDirection(a);
}
// Spherical Rayleigh + Mie + Chappuis-ozone optical transmittance matching
// AtmosphereCS. Evaluating at receiver altitude yields physical rose-gold
// alpenglow on 2km peaks while low valleys sit in cool twilight sky fill.
float3 CinematicSolarTransmittance(float altitudeMetres,float3 sun)
{
    const float planetR=6360.0,atmoR=6460.0;
    float3 pos=float3(0,planetR+clamp(altitudeMetres*.001,.01,12.0),0);
    float b=dot(pos,sun),c=dot(pos,pos)-planetR*planetR;
    float discG=b*b-c;
    if(discG>0.0&&(-b-sqrt(discG))>.002)return 0;
    float cAtmo=dot(pos,pos)-atmoR*atmoR;
    float dist=max(0.0,-b+sqrt(max(0.0,b*b-cAtmo)));
    float3 optical=0;
    [unroll]for(int i=0;i<6;++i)
    {
        float a0=(float)i/6.0,a1=(i+1.0)/6.0;
        float t=dist*(a0*a0+a1*a1)*.5,ds=dist*(a1*a1-a0*a0);
        float h=max(0.0,length(pos+sun*t)-planetR);
        float3 dens=float3(exp(-h/8.0),exp(-h/1.2),max(0.0,1.0-abs(h-25.0)/15.0));
        optical+=(float3(.005802,.013558,.033100)*dens.x
                 +(.003996/.9)*dens.y
                 +float3(.000650,.001881,.000085)*dens.z)*ds;
    }
    return exp(-optical);
}
float3 CinematicSunColorAt(float altitudeMetres)
{
    float3 sun=CinematicFrame[8].xyz;
    float3 base=CinematicSolarTransmittance(altitudeMetres,sun)*float3(3.35,3.25,3.12);
    // High-altitude rose-coral Chappuis alpenglow on snow-clad Alpine peaks
    // during dawn and dusk blue hour when the low sun skims the horizon.
    float alpenglow=(1.0-smoothstep(.028,.135,sun.y))*smoothstep(980.0,1720.0,altitudeMetres);
    return base+alpenglow*float3(1.55,.72,.54);
}
float3 CinematicSunColor()
{
    return CinematicSunColorAt(max(145.0,CinematicFrame[0].y));
}
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
    // Continuous 4x4 bilinear-tent PCF with receiver-plane depth correction.
    // Eliminates integer-texel stair-stepping on village streets while keeping
    // oblique plaster free of acne and thin branch shadows attached.
    float nd=dot(n,-CinematicFrame[8].xyz);
    nd=(nd<0.0?-1.0:1.0)*max(abs(nd),0.12);
    float2 planeGradient=float2(-dot(n,CinematicFrame[k+1].xyz),dot(n,CinematicFrame[k+2].xyz))*
                         (CinematicFrame[k+1].w/(CinematicFrame[k+2].w*nd));
    float visibility=0.0;
    int resolution=farCascade?1024:2048;
    float2 texCoord=uv*(float)resolution-0.5;
    int2 baseTexel=int2(floor(texCoord));
    float2 fracTex=texCoord-float2(baseTexel);
    [unroll]for(int y=-1;y<=2;++y)[unroll]for(int x=-1;x<=2;++x)
    {
        float wx=x==-1?(1.0-fracTex.x):(x==2?fracTex.x:1.0);
        float wy=y==-1?(1.0-fracTex.y):(y==2?fracTex.y:1.0);
        int2 pixel=clamp(baseTexel+int2(x,y),int2(0,0),int2(resolution-1,resolution-1));
        float z=farCascade?CinematicFarShadowMap.Load(int3(pixel,0)):CinematicShadowMap.Load(int3(pixel,0));
        float2 deltaUV=(float2(pixel)+0.5)*CinematicFrame[k].w-uv;
        float receiver=q.z+dot(planeGradient,deltaUV);
        visibility+=((receiver-bias<=z)?1.0:0.0)*(wx*wy);
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
float3 CinematicLightingSun(float3 n,float3 bentNormal,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility,float3 dielectricF0,float3 sunColor)
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
    direct*=sunColor*CinematicFrame[8].w*sunVisibility;
    float3 sky=AtmosphereDiffuse(bentNormal);
    // Rayleigh/Chappuis zenith blue-hour skylight fill in shadowed valleys at
    // dawn/dusk keeps low mountain valleys luminous cobalt-slate rather than black.
    float twilightBlue=(1.0-smoothstep(.035,.135,l.y))*(.42+.58*saturate(bentNormal.y));
    sky=lerp(sky,sky*float3(.78,.96,1.34)+float3(.016,.032,.068),twilightBlue*.78);
    // Analytic split-sum DFG fit. The sky-view cache has no reflection mips,
    // so the lobe broadens toward the diffuse normal with increasing roughness.
    // At rough=1 its specular irradiance is the same hemispherical quadrature
    // used for diffuse. No unoccluded mirror sky is added to crevices.
    float4 c0=float4(-1.0,-.0275,-.572,.022),c1=float4(1.0,.0425,1.04,-.04);
    float4 r=rough*c0+c1;
    float a004=min(r.x*r.x,exp2(-9.28*nv))*r.x+r.y;
    float2 dfg=float2(-1.04,1.04)*a004+r.zw;
    float3 reflected=reflect(-v,n);
    float3 envDir=normalize(lerp(reflected,bentNormal,a*.65));
    // Smoothly blend across the planetary horizon so rough surfaces do not
    // project AtmosphereLUT's 1-texel hitGround cliff as a contour line.
    float horizonBlend=smoothstep(-.18*rough-.02,.04+.28*rough,envDir.y);
    float3 envSky=AtmosphereEnvironment(normalize(float3(envDir.x,max(envDir.y,.08),envDir.z)));
    float3 env=lerp(sky*.32,envSky,horizonBlend);
    env=lerp(env,sky,smoothstep(.35,1.0,rough));
    float specularOcclusion=saturate(pow(max(nv+ao,1e-4),exp2(-16.0*rough-1.0))-1.0+ao);
    float3 indirectSpecular=env*(f0*dfg.x+dfg.y)*specularOcclusion;
    float3 indirectDiffuse=albedo*(1.0-metal)*(1.0-f0)*sky*ao;
    return max(0,direct+indirectDiffuse+indirectSpecular);
}
float3 CinematicLightingAt(float3 p,float3 n,float3 bentNormal,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility,float3 dielectricF0)
{
    return CinematicLightingSun(n,bentNormal,v,albedo,rough,metal,ao,sunVisibility,dielectricF0,CinematicSunColorAt(p.y));
}
// Energy-conserving RGB wrapped subsurface diffuse + dual-lobe epidermal/oil
// specular for human skin. Softens hard Lambertian shadow terminators naturally.
float3 CinematicSkinLighting(float3 p,float3 n,float3 v,float3 albedo,float rough,float ao,float sunVisibility)
{
    float3 l=CinematicFrame[8].xyz,h=normalize(l+v+1e-6);
    float ndotl=dot(n,l),nv=max(.025,saturate(dot(n,v)));
    float nh=saturate(dot(n,h)),vh=saturate(dot(v,h));
    float3 wrap=float3(.38,.16,.06);
    float3 nlWrap=saturate((ndotl+wrap)/(1.0+wrap));
    float3 normWrap=1.0/(PI*(1.0+wrap*.45));
    float a0=max(.03,pow(rough*.72,2.0)),a1=max(.08,pow(min(1.0,rough*1.35),2.0));
    float a02=a0*a0,a12=a1*a1;
    float d0=a02/(PI*pow(nh*nh*(a02-1.0)+1.0,2.0));
    float d1=a12/(PI*pow(nh*nh*(a12-1.0)+1.0,2.0));
    float D=.64*d0+.36*d1;
    float nl=saturate(ndotl);
    float vis=.5/max(nl*sqrt(nv*nv*(1.0-a02)+a02)+nv*sqrt(nl*nl*(1.0-a02)+a02),1e-5);
    float3 f0=.028,F=f0+(1.0-f0)*pow(1.0-vh,5.0);
    float3 sunRad=CinematicSunColorAt(p.y)*CinematicFrame[8].w*sunVisibility;
    float back=pow(saturate(dot(-v,l+n*.35)),3.0)*(1.0-nv*.5);
    float3 direct=((1.0-F)*albedo*nlWrap*normWrap+D*vis*F*nl)*sunRad;
    direct+=albedo*float3(.26,.055,.020)*back*sunRad;
    float3 sky=AtmosphereDiffuse(n);
    float3 refl=reflect(-v,n);
    float3 envSky=AtmosphereEnvironment(normalize(float3(refl.x,max(refl.y,.12),refl.z)));
    float3 env=lerp(sky*.34,lerp(envSky,sky,smoothstep(.20,.85,rough)),smoothstep(-.18,.32,refl.y));
    float specAO=saturate(pow(max(nv+ao,1e-4),exp2(-12.0*rough-1.0))-1.0+ao);
    return max(0,direct+albedo*(1.0-f0)*sky*ao+env*(f0+.012*pow(1.0-nv,4.0))*specAO);
}
float3 CinematicLightingVisibleBentF0(float3 n,float3 bentNormal,float3 v,float3 albedo,float rough,float metal,float ao,float sunVisibility,float3 dielectricF0)
{
    return CinematicLightingSun(n,bentNormal,v,albedo,rough,metal,ao,sunVisibility,dielectricF0,CinematicSunColor());
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
    return CinematicLightingAt(p,n,n,v,albedo,rough,metal,ao,CinematicShadow(p,n)*sunVisibility,.04);
}
float3 CinematicLighting(float3 p,float3 n,float3 v,float3 albedo,float rough,float metal,float ao)
{
    return CinematicLightingShadow(p,n,v,albedo,rough,metal,ao,1.0);
}
float3 CinematicFog(float3 col,float3 world)
{
    float3 origin=CinematicViewOrigin(),delta=world-origin;
    float d=max(length(delta),.001);
    float3 rd=delta/d,sun=CinematicFrame[8].xyz;
    // Analytic optical depth of an exponential medium along the whole ray.
    // Evaluating only the midpoint made a low valley disappear when the far
    // endpoint was a high summit. Reciprocal form stays stable for horizontal
    // views and for a mirror camera below the lake plane.
    float3 scale=float3(8000.0,1800.0,165.0);
    float3 raw0=(origin.y-float3(0,0,142))/scale;
    float3 raw1=(world.y-float3(0,0,142))/scale;
    float3 aboveFraction=saturate(max(raw0,raw1)/max(abs(raw1-raw0),1e-4));
    float3 h0=max(raw0,0.0),h1=max(raw1,0.0);
    float3 dh=abs(h1-h0);
    float3 integral=exp(-min(h0,h1))*(1.0-exp(-dh))/max(dh,1e-4);
    integral=lerp(exp(-(h0+h1)*.5),integral,step(1e-4,dh));
    integral=lerp(1.0,integral,aboveFraction);
    // Stratified valley/lake condensate mist ribbons: cool silver-blue in the
    // morning/dusk valley, kept clear in the foreground so closeups stay sharp.
    float2 mistSampleXZ=lerp(origin.xz,world.xz,.65);
    float mistNoise=GeologicalNoise(mistSampleXZ*.0010+float2(7.3,19.1));
    float mistRibbon=smoothstep(.38,.74,mistNoise)*(.65+.35*sin(lerp(origin.y,world.y,.7)*.038+mistNoise*5.0));
    float dawnMist=1.0+1.45*(1.0-smoothstep(.04,.30,sun.y));
    float nearClear=smoothstep(45.0,320.0,d);
    float mistDensity=.000042*integral.z*mistRibbon*dawnMist*nearClear;
    float3 optical=d*(float3(5.802,13.558,33.100)*1e-6*integral.x
                     +.0000135*integral.y+mistDensity);
    float3 transmittance=exp(-optical);
    float3 inscatter=AtmosphereEnvironment(rd);
    float mistShare=saturate(mistDensity*d/max(dot(optical,float3(.333,.333,.333)),1e-5));
    float twilightMist=1.0-smoothstep(.035,.14,sun.y);
    float3 coolMist=AtmosphereDiffuse(float3(0,1,0))*lerp(float3(1.10,1.16,1.24),float3(.85,1.12,1.62),twilightMist)
                    +twilightMist*float3(.018,.034,.068);
    float mu=saturate(dot(rd,sun));
    float mieForward=pow(mu,5.0)*.18+pow(mu,1.6)*.04;
    coolMist+=CinematicSunColorAt(lerp(origin.y,world.y,.5))*CinematicFrame[8].w*mieForward*lerp(.14,.04,twilightMist);
    inscatter=lerp(inscatter,coolMist,mistShare*.74);
    return col*transmittance+inscatter*(1.0-transmittance);
}
#endif
