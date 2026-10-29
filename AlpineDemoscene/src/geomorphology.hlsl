// Conservative virtual-pipe water/sediment transport with separate talus creep.
// This is an accelerated landscape authoring simulation, not a calibrated
// prediction of erosion over geological time. No stored height/biome image.
cbuffer WorldStep:register(b0){uint Phase,Iteration,Resolution,FullResolution;};
Texture2D<float4> State:register(t0);
Texture2D<float4> Flux:register(t1);
Texture2D<float> InitialHeight:register(t2);
Texture2D<float> InitialLow:register(t3);
SamplerState WorldLinear:register(s0);
RWTexture2D<float4> StateOutput:register(u0);
RWTexture2D<float> HeightOutput:register(u1);
static const int2 Directions[4]={int2(-1,0),int2(1,0),int2(0,-1),int2(0,1)};
static const uint Opposite[4]={1,0,3,2};
int2 Bound(int2 p){return clamp(p,int2(0,0),int2(Resolution-1,Resolution-1));}
bool Inside(int2 p){return all(p>=0)&&all(p<(int)Resolution);}
float4 ReadState(int2 p){return State.Load(int3(Bound(p),0));}
float2 WorldPosition(uint2 p){return float2(-6000,-1500)+(float2(p)+.5)*(12000.0/Resolution);}
float Protected(float2 p)
{
    float town=1-smoothstep(330,620,length((p-float2(0,1800))/float2(.85,1)));
    float lake=1-smoothstep(1.17,1.75,length((p-float2(-260,4220))/float2(900,610)));
    float source=(1-smoothstep(105,270,abs(p.x-350)))*smoothstep(4450,4650,p.y)*(1-smoothstep(5200,5500,p.y));
    return max(town,max(lake,source));
}
float Rain(int2 p)
{
    // Deterministic, smooth prevailing-wind rainfall field; not frame noise.
    float2 w=WorldPosition(p);
    return .035*(.72+.28*sin(w.x*.00073+w.y*.00031))*
        (.90+.10*sin((Iteration+.5)*.31));
}
float Hardness(float2 p)
{
    // Fold orientation and mineral bands control incision resistance.
    return .45+.45*pow(.5+.5*sin(p.x*.0031+p.y*.0017+1.7*sin(p.y*.00071)),2);
}
[numthreads(8,8,1)]
void WorldCS(uint3 tid:SV_DispatchThreadID)
{
    uint2 id=tid.xy;
    if(Phase==6)
    {
        if(any(id>=FullResolution))return;
        float2 uv=(float2(id)+.5)/FullResolution;
        float eroded=State.SampleLevel(WorldLinear,uv,0).x;
        float original=InitialLow.SampleLevel(WorldLinear,uv,0);
        HeightOutput[id]+=eroded-original;
        return;
    }
    if(any(id>=Resolution))return;
    int2 p=int2(id);float dx=12000.0/Resolution;
    float2 world=WorldPosition(id);float protection=Protected(world);
    if(Phase==0)
    {
        // Use a small area average, not a single displaced sample.
        int2 q=int2((float2(id)+.5)*FullResolution/Resolution);
        float h=0;
        [unroll]for(int j=-1;j<=1;j+=2)[unroll]for(int i=-1;i<=1;i+=2)
            h+=InitialHeight.Load(int3(clamp(q+int2(i,j),0,(int)FullResolution-1),0))*.25;
        StateOutput[id]=float4(h,.12,0,0);HeightOutput[id]=h;return;
    }
    float4 s=ReadState(p);
    if(Phase==1)
    {
        float water=s.y+Rain(p),surface=s.x+water;
        float4 flow=0;
        [unroll]for(uint k=0;k<4;++k)
        {
            int2 q=p+Directions[k];float4 n=ReadState(q);
            if(Inside(q))flow[k]=max(0,surface-n.x-n.y-Rain(q))*.075*(1-protection)*(1-Protected(WorldPosition(q)));
        }
        flow*=min(1.0,water/max(dot(flow,1),1e-8));
        StateOutput[id]=flow;return;
    }
    if(Phase==2)
    {
        float4 outgoing=Flux.Load(int3(p,0));float water=s.y+Rain(p);
        float concentration=s.z/max(water,1e-5),sediment=s.z-dot(outgoing,1)*concentration;
        float incomingWater=0,incomingSediment=0;float2 velocity=0;float maximumSlope=0;
        [unroll]for(uint k=0;k<4;++k)
        {
            int2 q=p+Directions[k];float4 n=ReadState(q);
            float inflow=Inside(q)?Flux.Load(int3(Bound(q),0))[Opposite[k]]:0;
            incomingWater+=inflow;incomingSediment+=inflow*n.z/max(n.y+Rain(q),1e-5);
            // Directions point out of this cell. Incoming water travels in
            // the opposite direction; adding it would cancel steady flow.
            velocity+=float2(Directions[k])*(outgoing[k]-inflow);
            maximumSlope=max(maximumSlope,abs(s.x-n.x)/dx);
        }
        water=max(0,water+incomingWater-dot(outgoing,1));
        sediment=max(0,sediment+incomingSediment);
        float transportSpeed=length(velocity)/max(water,.01);
        float capacity=water*(.15+transportSpeed*3.4)*sqrt(maximumSlope+.001);
        float original=InitialLow.Load(int3(p,0));
        float erosion=min(max(0,capacity-sediment)*.18*(1-Hardness(world)),max(0,s.x-original+18));
        float deposition=max(0,sediment-capacity)*.32;
        erosion*=1-protection;deposition*=1-protection;
        s.x+=deposition-erosion;sediment+=erosion-deposition;
        // Evaporation removes only water; carried solid mass remains.
        water*=.975;
        if(water<.005){s.x+=sediment*(1-protection);sediment*=protection;}
        float drainage=lerp(s.w,incomingWater+dot(outgoing,1),.055);
        StateOutput[id]=float4(s.x,water,sediment,drainage);return;
    }
    if(Phase==3)
    {
        float4 creep=0;float mobility=(1-protection)*(1-Hardness(world)*.65);
        [unroll]for(uint k=0;k<4;++k)
        {
            int2 q=p+Directions[k];float difference=s.x-ReadState(q).x;
            // Angle of repose: 34 degrees, transfer limited to avoid overshoot.
            if(Inside(q))creep[k]=max(0,difference-dx*.6745)*.075*mobility*(1-Protected(WorldPosition(q)));
        }
        StateOutput[id]=creep;return;
    }
    if(Phase==4)
    {
        float change=-dot(Flux.Load(int3(p,0)),1);
        [unroll]for(uint k=0;k<4;++k){int2 q=p+Directions[k];if(Inside(q))change+=Flux.Load(int3(q,0))[Opposite[k]];}
        s.x+=change;StateOutput[id]=s;return;
    }
    if(Phase==5)
    {
        float original=InitialLow.Load(int3(p,0));
        float gradientX=(ReadState(p+int2(1,0)).x-ReadState(p-int2(1,0)).x)/(2*dx);
        float gradientZ=(ReadState(p+int2(0,1)).x-ReadState(p-int2(0,1)).x)/(2*dx);
        float3 normal=normalize(float3(-gradientX,1,-gradientZ));
        float blocked=0;
        [unroll]for(uint k=0;k<8;++k)
        {
            float angle=(k+.25)*.7853981634;float2 direction=float2(cos(angle),sin(angle));float horizon=0;
            [unroll]for(uint j=0;j<4;++j)
            {
                float distance=exp2(2*j);int2 offset=int2(round(direction*distance));
                float3 delta=float3(float2(offset).x*dx,ReadState(p+offset).x-s.x,float2(offset).y*dx);
                horizon=max(horizon,saturate(dot(normal,normalize(delta))));
            }
            blocked+=horizon*horizon;
        }
        float flow=saturate(log2(1+s.w*7)*.28);
        float soil=saturate(.42+(s.x-original)*.065+s.z*.08);
        float aspect=saturate(dot(normal,float3(.24,0,.97))*.5+.5);
        float moisture=saturate(.20+flow*.55+soil*.22+aspect*.12-saturate((s.x-700)/1400)*.3);
        StateOutput[id]=float4(moisture,soil,flow,1-min(.75,blocked*.105));return;
    }
    if(Phase==7)
    {
        // End the authoring storm by returning all suspended solid material
        // to the bed. Dropping the scratch sediment field would lose mass.
        s.x+=s.z;s.z=0;s.y=0;StateOutput[id]=s;return;
    }
}
