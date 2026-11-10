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
static const float CLOUD_BASE=1320.0;
static const float CLOUD_TOP=2620.0;
static const float CLOUD_EXTINCTION=.0135;
float3 CloudCoordinates(float3 p,float loopA)
{
    // A smooth periodic flow keeps the128s film loop continuous. Its maximum
    // horizontal speed is4.5m/s; rising air and altitude shear deform billows.
    float3 wind=float3(92.0*sin(loopA),14.0*sin(loopA*2.0),46.0*cos(loopA));
    float h=saturate((p.y-CLOUD_BASE)/(CLOUD_TOP-CLOUD_BASE));
    return (p-wind+float3(h*58.0,0,h*28.0))/2900.0;
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
    float weather=smoothstep(.39,.70,field.a);
    float coverage=.21+.43*weather;
    float shape=saturate((field.r-(1.0-coverage))/max(coverage,.01));
    float profile=smoothstep(.0,.09,h)*(1.0-smoothstep(.58+.18*field.a,1.0,h));
    shape*=profile;
    float erosion=(1.0-(field.g*.62+field.b*.38))*(.27+.25*h);
    return saturate((shape-erosion)/max(.01,1.0-erosion))*.82;
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
        optical+=CloudDensity(q,loopA)*stepLength*(CLOUD_EXTINCTION*1.45);
        distance+=stepLength;
    }
    return optical;
}
float4 TraceCloudVolume(float3 ro,float3 rd,float maxT,float3 sun,float loopA,float2 pixel,uint viewSteps,uint lightSteps)
{
    float nearT,farT;
    maxT=min(maxT,11500.0);
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
    farT=min(farT,nearT+6800.0);
    float baseStep=(farT-nearT)/viewSteps;
    float jitter=.15+.70*frac(52.9829189*frac(dot(floor(pixel),float2(.06711056,.00583715))));
    float distance=nearT,transmittance=1.0;float3 radiance=0;
    float mu=dot(rd,sun);
    float phase0=(.78*CloudHG(mu,.72)+.22*CloudHG(mu,-.26))*(4.0*PI);
    float phase1=(.76*CloudHG(mu,.36)+.24*CloudHG(mu,-.14))*(4.0*PI);
    float phase2=CloudHG(mu,.10)*(4.0*PI);
    float3 directSun=CinematicSunColorAt(1850.0)*CinematicFrame[8].w*smoothstep(.005,.095,sun.y);
    float3 skyLight=AtmosphereEnvironment(float3(.001,1,0));
    float3 horizonLight=AtmosphereEnvironment(normalize(float3(rd.x+.0001,.05,rd.z)));
    float diurnalCloud=lerp(.26,1.0,smoothstep(.05,.15,sun.y));
    bool coarse=false;
    [loop]for(uint step=0;step<viewSteps;++step)
    {
        if(distance>=farT||transmittance<.010)break;
        float dt=min(baseStep,farT-distance);
        float3 p=ro+rd*(distance+dt*jitter);
        float density=CloudDensity(p,loopA)*diurnalCloud*smoothstep(110.0,520.0,distance);
        if(density<.001)
        {
            // Advance two steps in clear air; refine back one step upon entry.
            coarse=true;
            distance+=dt*2.0;continue;
        }
        if(coarse)
        {
            coarse=false;
            distance=max(nearT,distance-dt);
            dt=min(baseStep,farT-distance);
            p=ro+rd*(distance+dt*jitter);
            density=CloudDensity(p,loopA)*diurnalCloud*smoothstep(110.0,520.0,distance);
            if(density<.001){distance+=dt;continue;}
        }
        float optical=CloudLightOpticalDepth(p,sun,loopA,lightSteps);
        float powder=1.0-.56*exp(-density*15.0)*(1.0-saturate(mu));
        float3 multi=exp(-optical)*phase0*powder
                    +.28*exp(-optical*float3(.52,.48,.42))*phase1
                    +.10*exp(-optical*float3(.24,.22,.19))*phase2;
        float h=saturate((p.y-CLOUD_BASE)/(CLOUD_TOP-CLOUD_BASE));
        float3 ambient=skyLight*(.20+.38*h)+horizonLight*(.11+.08*(1.0-h));
        float3 source=ambient+directSun*multi*.30;
        // Aerial perspective softens the far horizon without an abrupt end.
        float aerial=1.0-exp(-(distance+dt*.5)*.000095);
        source=lerp(source,horizonLight,aerial*.62);
        float fade=1.0-smoothstep(7400.0,11000.0,distance+dt*.5);
        float stepTransmittance=exp(-density*CLOUD_EXTINCTION*dt*fade);
        radiance+=transmittance*(1.0-stepTransmittance)*source;
        transmittance*=stepTransmittance;distance+=dt;
    }
    return float4(radiance,1.0-transmittance);
}
float4 CloudLayer(float3 ro,float3 rd,float maxT,float3 sun,float loopA,float2 pixel)
{
    return TraceCloudVolume(ro,rd,maxT,sun,loopA,pixel,48,6);
}
#ifndef ALPINE_CLOUD_NO_REFLECTION
float3 SkyWithCloudReflection(float3 rd,float3 p,float3 sun,float loopA)
{
    // Solar surface reflection comes from WaterSunReflection's GGX lobe;
    // including the sky disc here would count that same light a second time.
    float3 background=AtmosphereEnvironment(rd);
    // Avoid quantising world-space p.xz in floor(pixel), which drew 5m tiles on water.
    float4 clouds=TraceCloudVolume(p+rd*.2,rd,11500.0,sun,loopA,float2(3.7,7.1),18,3);
    return clouds.rgb+background*(1.0-clouds.a);
}
#endif
#endif
