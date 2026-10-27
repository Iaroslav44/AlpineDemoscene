#include "scene_common.hlsli"
#include "physics_common.hlsli"
// Build FlightCS with ALPINE_FLIGHT_SIM=1; WaterCS without it. They use u0
// for different resource types, so only one declaration is present per build.
cbuffer PhysicsStep : register(b3) { float4 Physics; }; // dt, seconds, mode, step

#if defined(ALPINE_FLIGHT_SIM)
RWStructuredBuffer<float4> FlightOutput : register(u0);
static const float FLIGHT_DT=1.0/120.0;
static const float GLIDER_MASS=420.0;
static const float GLIDER_AREA=11.0;
static const float GLIDER_SPAN=18.0;
static const float GRAVITY=9.81;

float AirDensity(float height){return 1.225*exp(-max(height,0.0)/8500.0);}
void AirFrame(float3 p,float3 velocity,float bank,float seconds,out float3 forward,out float3 up,out float speed)
{
    float3 air=velocity-PhysicalWind(p,seconds);
    speed=max(length(air),.1);forward=air/speed;
    float3 r=cross(float3(0,1,0),forward);r*=rsqrt(max(dot(r,r),1e-8));
    float3 u=cross(forward,r);up=u*cos(bank)-r*sin(bank);
}
float3 FlightAcceleration(float3 p,float3 velocity,float bank,float cl,float seconds)
{
    float3 f,u;float speed;AirFrame(p,velocity,bank,seconds,f,u,speed);
    float dynamicPressure=.5*AirDensity(p.y)*speed*speed;
    float induced=1.0/(PI*(GLIDER_SPAN*GLIDER_SPAN/GLIDER_AREA)*.82);
    float cd=.012+induced*cl*cl;
    return (u*cl-f*cd)*(dynamicPressure*GLIDER_AREA/GLIDER_MASS)+float3(0,-GRAVITY,0);
}
void StoreFlight(uint id,uint sample,float3 p,float3 velocity,float bank,float cl,float seconds)
{
    float3 f,u;float speed;AirFrame(p,velocity,bank,seconds,f,u,speed);
    uint i=(id*FLIGHT_SAMPLES+sample)*4;
    FlightOutput[i]=float4(p,bank);
    FlightOutput[i+1]=float4(velocity,speed);
    FlightOutput[i+2]=float4(f,cl);
    FlightOutput[i+3]=float4(u,p.y-Terrain(p.xz));
}
[numthreads(4,1,1)]
void FlightCS(uint3 tid:SV_DispatchThreadID)
{
    uint id=tid.x;if(id>=4)return;
    float radius=560.0+id*34.0,phase=id*1.55;
    float2 orbit=float2(-25,2850);
    float3 p=float3(orbit.x+radius*cos(phase),1100.0+id*45.0,orbit.y+radius*sin(phase));
    // Terrain is consulted only to place the initial state and to pilot away
    // from obstacles. Position is never snapped/clamped during integration.
    p.y=max(p.y,Terrain(p.xz)+300.0);
    float3 velocity=float3(-sin(phase)*32.0,-.82,cos(phase)*32.0)+PhysicalWind(p,0);
    float bank=atan(32.0*32.0/(GRAVITY*radius));
    float cl=GLIDER_MASS*GRAVITY/(.5*AirDensity(p.y)*32.0*32.0*GLIDER_AREA*cos(bank));
    StoreFlight(id,0,p,velocity,bank,cl,0);
    [loop]for(uint step=1;step<=15360;++step)
    {
        float t=(step-1)*FLIGHT_DT;
        float3 air=velocity-PhysicalWind(p,t);float speed=max(length(air),.1);
        float2 direction=normalize(air.xz+float2(0,1e-7));
        float2 radial=p.xz-orbit;float distance=max(length(radial),1.0);radial/=distance;
        float2 desired=normalize(float2(-radial.y,radial.x)-radial*((distance-radius)/radius)*1.8);
        float2 right=float2(direction.y,-direction.x);
        float headingError=atan2(dot(desired,right),dot(desired,direction));
        float bankTarget=clamp(atan(speed*speed/(GRAVITY*radius))-.95*headingError,-.55,.55);
        bank+=clamp((bankTarget-bank)/.75,-.55,.55)*FLIGHT_DT;
        float predictedGround=Terrain(p.xz+velocity.xz*8.0);
        float avoid=clamp((predictedGround+160.0-p.y)*.025,0.0,4.0);
        float load=clamp(1.0+.085*(-.82+avoid-air.y)+.015*(speed-32.0),.55,1.45);
        float targetCl=GLIDER_MASS*GRAVITY*load/(.5*AirDensity(p.y)*speed*speed*GLIDER_AREA*max(cos(bank),.6));
        targetCl=clamp(targetCl,.15,1.35);
        cl+=clamp((targetCl-cl)/.30,-1.5,1.5)*FLIGHT_DT;
        // Explicit midpoint RK2 of Newton's equation. Lift is perpendicular
        // to air velocity, drag opposes it; no engine force is added.
        float3 acceleration=FlightAcceleration(p,velocity,bank,cl,t);
        float3 midpointP=p+velocity*(.5*FLIGHT_DT);
        float3 midpointV=velocity+acceleration*(.5*FLIGHT_DT);
        p+=midpointV*FLIGHT_DT;
        velocity+=FlightAcceleration(midpointP,midpointV,bank,cl,t+.5*FLIGHT_DT)*FLIGHT_DT;
        if((step&3)==0)StoreFlight(id,step>>2,p,velocity,bank,cl,step*FLIGHT_DT);
    }
}
#else
RWTexture2D<float4> WaterOutput : register(u0);

float2 WaterCellPosition(int2 cell)
{
    return LAKE_C-WATER_SPAN*.5+(float2(cell)+.5)*WATER_CELL;
}
float CellDepth(int2 cell)
{
    if(any(cell<0)||any(cell>=256))return 0;
    return PhysicalWaterDepth(WaterCellPosition(cell));
}
float4 CellState(int2 cell)
{
    if(any(cell<0)||any(cell>=256))return 0;
    return PhysicalWater.Load(int3(cell,0));
}
float SurfacePressure(float2 p,float seconds)
{
    float3 wind=PhysicalWind(float3(p.x,LAKE_Y,p.y),seconds);
    float airPressure=.5*(1.225/1000.0)*dot(wind.xz,wind.xz)
       *(0.65+0.35*sin(p.x*.015+p.y*.009));
    float2 impact=(p-float2(350,4785))/28.0;
    float waterfall=.65*exp(-dot(impact,impact))*(.75+.25*sin(seconds*TAU*9.0/128.0));
    // Pressure/rho (m²/s²), not an arbitrary change in water volume.
    return airPressure+waterfall;
}
float FaceVelocity(int2 cell,int2 axis,float dt,float seconds,bool forcing)
{
    float h0=CellDepth(cell),h1=CellDepth(cell+axis);
    if(min(h0,h1)<=0)return 0; // reflecting, no-normal-flow wet/dry boundary
    float4 a=CellState(cell),b=CellState(cell+axis);
    float spacing=axis.x!=0?WATER_CELL.x:WATER_CELL.y;
    float old=axis.x!=0?a.y:a.z;
    float pressure=9.81*(b.x-a.x);
    if(forcing)pressure+=SurfacePressure(WaterCellPosition(cell+axis),seconds)-SurfacePressure(WaterCellPosition(cell),seconds);
    return (old-dt*pressure/spacing)/(1.0+.018*dt); // bottom/viscous drag
}
float FaceDepth(int2 cell,int2 axis)
{
    return min(CellDepth(cell),CellDepth(cell+axis));
}
[numthreads(8,8,1)]
void WaterCS(uint3 tid:SV_DispatchThreadID)
{
    int2 cell=int2(tid.xy);if(any(cell>=256))return;
    float depth=CellDepth(cell);
    if(depth<=0){WaterOutput[cell]=0;return;}
    uint mode=(uint)round(Physics.z);
    if(mode==0||mode==3)
    {
        float2 q=(WaterCellPosition(cell)-(LAKE_C+float2(-80,0)))/70.0;
        WaterOutput[cell]=float4(mode==3?.12*exp(-dot(q,q)):0,0,0,0);
        return;
    }
    float dt=Physics.x;bool forcing=mode==1;
    float east=FaceVelocity(cell,int2(1,0),dt,Physics.y,forcing);
    float west=FaceVelocity(cell-int2(1,0),int2(1,0),dt,Physics.y,forcing);
    float north=FaceVelocity(cell,int2(0,1),dt,Physics.y,forcing);
    float south=FaceVelocity(cell-int2(0,1),int2(0,1),dt,Physics.y,forcing);
    float fluxX=FaceDepth(cell,int2(1,0))*east-FaceDepth(cell-int2(1,0),int2(1,0))*west;
    float fluxZ=FaceDepth(cell,int2(0,1))*north-FaceDepth(cell-int2(0,1),int2(0,1))*south;
    float4 old=CellState(cell);
    float eta=old.x-dt*(fluxX/WATER_CELL.x+fluxZ/WATER_CELL.y);
    float convergence=max(0.0,-(east-west)/WATER_CELL.x-(north-south)/WATER_CELL.y);
    float foam=saturate(old.w*exp(-dt*.55)+dt*convergence*2.0);
    WaterOutput[cell]=float4(eta,east,north,foam);
}
#endif
