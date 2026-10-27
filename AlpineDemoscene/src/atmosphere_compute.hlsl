// A runtime sky-view transport cache. Spherical Rayleigh/Mie single scattering
// with ozone absorption and planet shadow, not an embedded skydome image.
#include "scene_common.hlsli"
StructuredBuffer<float4> AtmosphereFrame : register(t3);
RWTexture2D<float4> AtmosphereOutput : register(u0);
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
[numthreads(8,8,1)]
void AtmosphereCS(uint3 id:SV_DispatchThreadID)
{
    if(id.x>=256||id.y>=128)return;
    float2 uv=(id.xy+.5)/float2(256,128);
    float phi=(uv.x-.5)*TAU,theta=uv.y*PI;
    float3 rd=float3(cos(phi)*sin(theta),cos(theta),sin(phi)*sin(theta));
    float3 sun=AtmosphereFrame[8].xyz;
    float3 origin=float3(0,PLANET_R+max(.01,AtmosphereFrame[0].y*.001),0);
    float distance=AtmosphereSphere(origin,rd,ATMOSPHERE_R).y;
    float ground=AtmosphereSphere(origin,rd,PLANET_R).x;
    bool hitGround=ground>0; if(hitGround)distance=min(distance,ground);
    float mu=dot(rd,sun),rayleighPhase=3.0*(1+mu*mu)/(16.0*PI),g=.76;
    float miePhase=3.0*(1-g*g)*(1+mu*mu)/(8.0*PI*(2+g*g)*pow(max(.001,1+g*g-2*g*mu),1.5));
    float3 radiance=0,transmission=1;
    [loop]for(int i=0;i<24;++i)
    {
        float a=(float)i/24.0,b=(i+1.0)/24.0;
        float ds=distance*(b*b-a*a),t=distance*(a*a+b*b)*.5;
        float3 p=origin+rd*t,density=AtmosphereDensity(p);
        float3 extinction=AtmosphereExtinction(density),stepTransmittance=exp(-extinction*ds);
        float3 scattering=BETA_R*density.x*rayleighPhase+BETA_M*density.y*miePhase;
        float3 source=AtmosphereSolar(p,sun)*float3(7.8,7.55,7.2)*scattering;
        // Integral of constant source over a homogeneous step, not source*alpha
        // without extinction normalization.
        radiance+=transmission*source*(1-stepTransmittance)/max(extinction,1e-7);
        transmission*=stepTransmittance;
    }
    if(hitGround)
    {
        float3 p=origin+rd*distance,normal=normalize(p);
        float3 irradiance=AtmosphereSolar(p+normal*.005,sun)*7.8*saturate(dot(normal,sun));
        radiance+=transmission*float3(.10,.13,.067)*(irradiance/PI+.035);
    }
    AtmosphereOutput[id.xy]=float4(max(radiance,0),dot(transmission,float3(.2126,.7152,.0722)));
}
