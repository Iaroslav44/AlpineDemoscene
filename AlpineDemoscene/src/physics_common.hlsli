#ifndef ALPINE_PHYSICS_COMMON
#define ALPINE_PHYSICS_COMMON
// Include after the shared Terrain function. SI units throughout. These
// buffers contain calculations made at runtime, never disk-authored assets.
static const uint FLIGHT_SAMPLES = 3841;
static const float FLIGHT_SAMPLE_RATE = 30.0;
static const float2 WATER_SPAN = float2(2200.0,1600.0);
static const float2 WATER_CELL = WATER_SPAN/256.0;
StructuredBuffer<float4> PhysicalFlight : register(t6);
Texture2D<float4> PhysicalWater : register(t7);
#if defined(ALPINE_TERRAIN_GENERATOR)
SamplerState TerrainSampler : register(s1);
#endif

float PhysicalWindOmega(uint harmonic)
{
    return (harmonic==0?3.0:(harmonic==1?5.0:11.0))*TAU/128.0;
}
float4 PhysicalWindGust(uint harmonic,float3 p,float seconds)
{
    float3 amplitude;
    float spatial;
    if(harmonic==0){amplitude=float3(1.1,0,.25);spatial=p.x*.0021+p.z*.0013;}
    else if(harmonic==1){amplitude=float3(-.18,0,.75);spatial=-p.x*.0012+p.z*.0023;}
    else{amplitude=float3(.25,.08,.18);spatial=p.x*.004-p.z*.003;}
    return float4(amplitude,PhysicalWindOmega(harmonic)*seconds+spatial);
}
float3 PhysicalWind(float3 p,float seconds)
{
    float3 wind=float3(3.2,0,1.2);
    [unroll]for(uint h=0;h<3;++h){float4 gust=PhysicalWindGust(h,p,seconds);wind+=gust.xyz*sin(gust.w);}
    float2 thermal=(p.xz-float2(-100,3000))/380.0;
    wind.y+=1.6*exp(-dot(thermal,thermal))*(1.0-smoothstep(1700.0,2300.0,p.y))
           *(.9+.1*sin(seconds*TAU*2.0/128.0));
    return wind;
}
float FlightTime(float seconds)
{
    return seconds-floor(seconds/128.0)*128.0;
}
void FlightKeys(uint id,float seconds,out uint a,out uint b,out float fraction)
{
    float sample=FlightTime(seconds)*FLIGHT_SAMPLE_RATE;
    uint index=min((uint)floor(sample),FLIGHT_SAMPLES-2);
    a=(min(id,3u)*FLIGHT_SAMPLES+index)*4;
    b=a+4;fraction=saturate(sample-index);
}
float3 PhysicalGliderCentre(uint id,float seconds)
{
    uint a,b;float u;FlightKeys(id,seconds,a,b,u);
    float u2=u*u,u3=u2*u;
    // Hermite reconstruction uses the integrated velocity, not finite
    // differencing of a scripted orbit. The cache itself is sampled at30Hz.
    return (2*u3-3*u2+1)*PhysicalFlight[a].xyz+(u3-2*u2+u)*PhysicalFlight[a+1].xyz/FLIGHT_SAMPLE_RATE
         +(-2*u3+3*u2)*PhysicalFlight[b].xyz+(u3-u2)*PhysicalFlight[b+1].xyz/FLIGHT_SAMPLE_RATE;
}
void PhysicalGliderPose(uint id,float seconds,out float3 center,out float3 right,out float3 up,out float3 forward)
{
    uint a,b;float u;FlightKeys(id,seconds,a,b,u);
    center=PhysicalGliderCentre(id,seconds);
    forward=normalize(lerp(PhysicalFlight[a+2].xyz,PhysicalFlight[b+2].xyz,u));
    float3 upHint=normalize(lerp(PhysicalFlight[a+3].xyz,PhysicalFlight[b+3].xyz,u));
    right=normalize(cross(upHint,forward));up=cross(forward,right);
}
bool PhysicalWaterDomain(float2 p)
{
    bool lake=length((p-LAKE_C)/float2(900,610))<1.06;
    bool channel=abs(p.x-350.0)<55.0&&p.y>4610.0&&p.y<4845.0;
    return lake||channel;
}
float PhysicalWaterDepth(float2 p)
{
    float depth=LAKE_Y-Terrain(p);
    return PhysicalWaterDomain(p)&&depth>.5?min(depth,50.0):0.0;
}
float2 PhysicalWaterUV(float2 p){return (p-(LAKE_C-WATER_SPAN*.5))/WATER_SPAN;}
float3 PhysicalWaterField(float2 p)
{
    float2 uv=PhysicalWaterUV(p),texel=1.0/256.0;
    float eta=PhysicalWater.SampleLevel(TerrainSampler,uv,0).x;
    float ex=PhysicalWater.SampleLevel(TerrainSampler,uv+float2(texel.x,0),0).x
            -PhysicalWater.SampleLevel(TerrainSampler,uv-float2(texel.x,0),0).x;
    float ez=PhysicalWater.SampleLevel(TerrainSampler,uv+float2(0,texel.y),0).x
            -PhysicalWater.SampleLevel(TerrainSampler,uv-float2(0,texel.y),0).x;
    return float3(eta,ex/(2.0*WATER_CELL.x),ez/(2.0*WATER_CELL.y));
}
float PhysicalWaterFoam(float2 p){return PhysicalWater.SampleLevel(TerrainSampler,PhysicalWaterUV(p),0).w;}
#endif
