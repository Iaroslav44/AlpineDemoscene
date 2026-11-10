// A runtime sky-view transport cache. Spherical Rayleigh/Mie single scattering
// with ozone absorption and planet shadow, not an embedded skydome image.
#include "scene_common.hlsli"
#include "atmosphere_sh.hlsli"
StructuredBuffer<float4> AtmosphereFrame : register(t3);
RWTexture2D<float4> AtmosphereOutput : register(u0);
RWTexture2D<float4> AtmosphereIrradianceOutput : register(u1);
groupshared float3 SHReduction[64];
static const float PLANET_R=6360.0;
static const float ATMOSPHERE_R=6460.0;
static const float3 BETA_R=float3(.005802,.013558,.033100);
static const float3 BETA_M=float3(.003996,.003996,.003996);
static const float3 BETA_O=float3(.000650,.001881,.000085);
float2 AtmosphereSphere(float3 p,float3 d,float radius)
{
    float b=dot(p,d),c=dot(p,p)-radius*radius;
    float discriminant=b*b-c;if(discriminant<0)return float2(-1,-1);
    float root=sqrt(discriminant);return float2(-b-root,-b+root);
}
float3 AtmosphereDensity(float3 position)
{
    float h=max(0,length(position)-PLANET_R);
    return float3(exp(-h/8.0),exp(-h/1.2),max(0,1.0-abs(h-25.0)/15.0));
}
float3 AtmosphereExtinction(float3 density)
{
    return BETA_R*density.x+BETA_M*(density.y/.9)+BETA_O*density.z;
}
float3 AtmosphereSolar(float3 position,float3 sun)
{
    float2 ground=AtmosphereSphere(position,sun,PLANET_R);
    if(ground.x>.002)return 0;
    float distance=max(0,AtmosphereSphere(position,sun,ATMOSPHERE_R).y);
    float3 optical=0;
    [unroll]for(int i=0;i<8;++i)
    {
        float a=(float)i/8.0,b=(i+1.0)/8.0;
        float t=distance*(a*a+b*b)*.5,ds=distance*(b*b-a*a);
        optical+=AtmosphereExtinction(AtmosphereDensity(position+sun*t))*ds;
    }
    return exp(-optical);
}
float4 AtmosphereTransport(float3 rd)
{
    float3 sun=AtmosphereFrame[8].xyz;
    float3 origin=float3(0,PLANET_R+max(.01,AtmosphereFrame[0].y*.001),0);
    float distance=AtmosphereSphere(origin,rd,ATMOSPHERE_R).y;
    float ground=AtmosphereSphere(origin,rd,PLANET_R).x;
    bool hitGround=ground>0; if(hitGround)distance=min(distance,ground);
    float mu=dot(rd,sun),rayleighPhase=3.0*(1+mu*mu)/(16.0*PI),g=.76;
    float miePhase=3.0*(1-g*g)*(1+mu*mu)/(8.0*PI*(2+g*g)*pow(max(.001,1+g*g-2*g*mu),1.5));
    float3 solarExtra=float3(10.7,10.4,10.0);
    float twilight=1.0-smoothstep(.025,.16,sun.y);
    float3 radiance=0,transmission=1;
    [loop]for(int i=0;i<24;++i)
    {
        float a=(float)i/24.0,b=(i+1.0)/24.0;
        float ds=distance*(b*b-a*a),t=distance*(a*a+b*b)*.5;
        float3 p=origin+rd*t,density=AtmosphereDensity(p);
        float3 extinction=AtmosphereExtinction(density),stepTransmittance=exp(-extinction*ds);
        float3 scattering=BETA_R*density.x*rayleighPhase+BETA_M*density.y*miePhase;
        float3 multiScatter=AtmosphereSolar(p+normalize(p)*1.8,sun)*(BETA_R*density.x*.28+BETA_M*density.y*.09)/(4.0*PI);
        float3 source=(AtmosphereSolar(p,sun)*scattering+multiScatter)*solarExtra;
        // Upper-stratospheric blue-hour sky scatter keeps twilight valleys
        // luminous and cool cobalt-blue when the low sun only grazes summits.
        source+=density.x*float3(.00014,.00028,.00068)*twilight;
        // Integral of constant source over a homogeneous step, not source*alpha
        // without extinction normalization.
        radiance+=transmission*source*(1-stepTransmittance)/max(extinction,1e-7);
        transmission*=stepTransmittance;
    }
    if(hitGround)
    {
        float3 p=origin+rd*distance,normal=normalize(p);
        float3 irradiance=AtmosphereSolar(p+normal*.005,sun)*solarExtra*saturate(dot(normal,sun));
        radiance+=transmission*float3(.15,.16,.16)*(irradiance/PI+float3(.036,.054,.095)*(1.0+.85*twilight));
    }
    return float4(max(radiance,0),dot(transmission,float3(.2126,.7152,.0722)));
}
[numthreads(8,8,1)]
void AtmosphereCS(uint3 id:SV_DispatchThreadID,uint3 group:SV_GroupID,uint lane:SV_GroupIndex)
{
    float2 uv=(id.xy+.5)/float2(256,128);
    float phi=(uv.x-.5)*TAU,theta=uv.y*PI;
    float3 rd=float3(cos(phi)*sin(theta),cos(theta),sin(phi)*sin(theta));
    if(id.x<256&&id.y<128)AtmosphereOutput[id.xy]=AtmosphereTransport(rd);
    // Nine groups project the same analytic transport, not a partially written
    // LUT. Every lane participates in group-uniform reductions. 128 fixed
    // equal-area directions avoid a changing tangent frame at each pixel.
    if(group.y==0&&group.x<9)
    {
        float3 integral=0;
        [unroll]for(uint j=0;j<2;++j)
        {
            uint sample=lane+j*64;
            float y=1-2*(sample+.5)/128.0;
            float angle=sample*2.3999632297;
            float radius=sqrt(max(0,1-y*y));
            float3 direction=float3(cos(angle)*radius,y,sin(angle)*radius);
            integral+=AtmosphereTransport(direction).rgb*AtmosphereSHBasis(group.x,direction);
        }
        SHReduction[lane]=integral;GroupMemoryBarrierWithGroupSync();
        [unroll]for(uint stride=32;stride>0;stride>>=1)
        {
            if(lane<stride)SHReduction[lane]+=SHReduction[lane+stride];
            GroupMemoryBarrierWithGroupSync();
        }
        if(lane==0)
        {
            float cosineBand=group.x==0?1:(group.x<4?2.0/3.0:.25);
            AtmosphereIrradianceOutput[uint2(group.x,0)]=float4(SHReduction[0]*(4*PI/128)*cosineBand,0);
        }
    }
}
