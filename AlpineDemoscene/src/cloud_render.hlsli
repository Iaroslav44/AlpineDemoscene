#ifndef ALPINE_CLOUD_RENDER
#define ALPINE_CLOUD_RENDER
#include "sampler_common.hlsli"
// Include after Sky(), material_common.hlsli and cinematic_lighting.hlsli.
// The procedural volume is128^3 RGBA8 at t13; MaterialSampler(s2) must wrap.
// Shape/erosion follows the production Perlin-Worley approach presented by
// Schneider/Vos, SIGGRAPH2015. Lighting integrates Beer-Lambert extinction,
// dual Henyey-Greenstein phase, and three approximate scattering orders.
// The reduced scattering orders are an approximation, not full path tracing.
Texture3D<float4> CloudVolume : register(t13);
static const float CLOUD_BASE=850.0;
static const float CLOUD_TOP=1700.0;
static const float CLOUD_EXTINCTION=.012;
float3 CloudCoordinates(float3 p,float loopA)
{
    // A smooth periodic flow keeps the128s film loop continuous. Its maximum
    // horizontal speed is4.5m/s; rising air and altitude shear deform billows.
    float3 wind=float3(92.0*sin(loopA),14.0*sin(loopA*2.0),46.0*cos(loopA));
    float h=saturate((p.y-CLOUD_BASE)/(CLOUD_TOP-CLOUD_BASE));
    return (p-wind+float3(h*48.0,0,h*22.0))/2600.0;
}
float CloudDensity(float3 p,float loopA)
{
    float h=(p.y-CLOUD_BASE)/(CLOUD_TOP-CLOUD_BASE);
    if(h<=0.0||h>=1.0)return 0.0;
    float4 field=CloudVolume.SampleLevel(MaterialSampler,CloudCoordinates(p,loopA),0);
    // A flat condensation base and tapered upper billows distinguish cumulus
    // from uniformly fuzzy volume noise. Low-frequency coverage opens sky gaps.
    // A weather-cell threshold makes discrete cloud banks with genuine clear
    // air between them, including for cameras flying inside this height range.
    float weather=smoothstep(.40,.67,field.a);
    float coverage=.21+.48*weather;
    float shape=saturate((field.r-(1.0-coverage))/max(coverage,.01));
    float profile=smoothstep(.0,.075,h)*(1.0-smoothstep(.60+.13*field.a,1.0,h));
    shape*=profile;
    float erosion=(1.0-(field.g*.68+field.b*.32))*(.18+.16*h);
    return saturate((shape-erosion)/max(.01,1.0-erosion))*.94;
}
float CloudHG(float mu,float g)
{
    float denominator=max(.015,1.0+g*g-2.0*g*mu);
    return (1.0-g*g)/(4.0*PI*denominator*sqrt(denominator));
}
float CloudLightOpticalDepth(float3 p,float3 sun,float loopA,uint samples)
{
    float distance=0.0,optical=0.0;
    [loop]for(uint k=0;k<samples;++k)
    {
        // Expanding steps reach the edge of a dense billow without spending
        // the whole budget in its centre. Each contribution has metre units.
        float stepLength=samples==6?32.0*pow(1.6,(float)k):100.0*pow(2.0,(float)k);
        float3 q=p+sun*(distance+stepLength*.5);
        optical+=CloudDensity(q,loopA)*stepLength*CLOUD_EXTINCTION;
        distance+=stepLength;
    }
    return optical;
}
float4 TraceCloudVolume(float3 ro,float3 rd,float maxT,float3 sun,float loopA,float2 pixel,uint viewSteps,uint lightSteps)
{
    float nearT,farT;
    maxT=min(maxT,6500.0);
    if(abs(rd.y)<.0001)
    {
        if(ro.y<CLOUD_BASE||ro.y>CLOUD_TOP)return 0;
        nearT=0;farT=maxT;
    }
    else
    {
        float a=(CLOUD_BASE-ro.y)/rd.y,b=(CLOUD_TOP-ro.y)/rd.y;
        nearT=max(0.0,min(a,b));farT=min(maxT,max(a,b));
    }
    if(farT<=nearT)return 0;
    float baseStep=(farT-nearT)/viewSteps;
    float jitter=.22+.56*frac(52.9829189*frac(dot(floor(pixel),float2(.06711056,.00583715))));
    float distance=nearT,transmittance=1.0;float3 radiance=0;
    float mu=dot(rd,sun);
    float phase0=(.82*CloudHG(mu,.72)+.18*CloudHG(mu,-.24))*(4.0*PI);
    float phase1=(.82*CloudHG(mu,.36)+.18*CloudHG(mu,-.12))*(4.0*PI);
    float phase2=CloudHG(mu,.12)*(4.0*PI);
    float3 directSun=CinematicSunColor()*CinematicFrame[8].w*smoothstep(-.04,.08,sun.y);
    float3 skyLight=AtmosphereEnvironment(float3(.001,1,0));
    float3 horizonLight=AtmosphereEnvironment(normalize(float3(rd.x+.0001,.05,rd.z)));
    [loop]for(uint step=0;step<viewSteps;++step)
    {
        if(distance>=farT||transmittance<.012)break;
        float dt=min(baseStep,farT-distance);
        float3 p=ro+rd*(distance+dt*jitter);
        float density=CloudDensity(p,loopA);
        if(density<.001)
        {
            // No light march for empty space; advance two normal steps.
            distance+=dt*2.0;continue;
        }
        float optical=CloudLightOpticalDepth(p,sun,loopA,lightSteps);
        float direct=exp(-optical)*phase0;
        float multiple=.18*exp(-optical*.5)*phase1+.045*exp(-optical*.25)*phase2;
        float h=saturate((p.y-CLOUD_BASE)/(CLOUD_TOP-CLOUD_BASE));
        float3 ambient=skyLight*(.18+.32*h)+horizonLight*.08+float3(.012,.011,.008);
        float3 source=ambient+directSun*(direct+multiple)*.30;
        // Aerial perspective softens the far horizon without an abrupt end.
        float aerial=1.0-exp(-(distance+dt*.5)*.00012);
        source=lerp(source,horizonLight,aerial*.65);
        float fade=1.0-smoothstep(4200.0,6500.0,distance+dt*.5);
        float stepTransmittance=exp(-density*CLOUD_EXTINCTION*dt*fade);
        radiance+=transmittance*(1.0-stepTransmittance)*source;
        transmittance*=stepTransmittance;distance+=dt;
    }
    return float4(radiance,1.0-transmittance);
}
float4 CloudLayer(float3 ro,float3 rd,float maxT,float3 sun,float loopA,float2 pixel)
{
    return TraceCloudVolume(ro,rd,maxT,sun,loopA,pixel,32,6);
}
#ifndef ALPINE_CLOUD_NO_REFLECTION
float3 SkyWithCloudReflection(float3 rd,float3 p,float3 sun,float loopA)
{
    float3 background=Sky(rd,sun);
    // Reflections use the same3D density and optical model at a reduced LOD.
    // The main/reflected-world pass retains32 view and6 self-shadow samples.
    float4 clouds=TraceCloudVolume(p+rd*.2,rd,6500.0,sun,loopA,p.xz*.2,12,3);
    return clouds.rgb+background*(1.0-clouds.a);
}
#endif
#endif
