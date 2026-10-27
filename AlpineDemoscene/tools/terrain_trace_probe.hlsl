// QA only: real generated terrain and hierarchy, actual production tracer,
// independently sampled dense reference, plus analytic vertical/sky rays.
// RGBA32F: hierarchical t, reference t, signed hit residual, ray-class flags.
cbuffer Frame : register(b0) { float4 G; float4 O; };
#include "../src/scene_common.hlsli"
#include "../src/terrain_trace.hlsli"
struct VSOut { float4 pos:SV_POSITION; float2 uv:TEXCOORD0; };

float ReferenceHeight(float2 xz)
{
    // Evaluate the same mathematical surface with separate lerps. Hardware
    // texture filtering can quantize fractional interpolation weights, so it
    // is not a centimetre-accurate oracle on steep height-field cells.
    float2 g=clamp((xz-float2(-6000,-1500))/TERRAIN_TEXEL,0.0,4095.0);
    int2 cell=int2(floor(g)),q=min(cell+1,4095);float2 f=g-cell;
    float a=ProceduralHeight.Load(int3(cell,0)),b=ProceduralHeight.Load(int3(q.x,cell.y,0));
    float c=ProceduralHeight.Load(int3(cell.x,q.y,0)),d=ProceduralHeight.Load(int3(q,0));
    return lerp(lerp(a,b,f.x),lerp(c,d,f.x),f.y);
}

float DenseTerrainReference(float3 ro,float3 rd,float maxT)
{
    float2 safe=lerp(-1.0,1.0,step(0.0,rd.xz))*max(abs(rd.xz),1e-8);
    float2 a=(float2(-6000,-1500)-ro.xz)/safe,b=(float2(6000,10500)-ro.xz)/safe;
    float2 entry=min(a,b),leave=max(a,b);
    float t=max(.025,max(entry.x,entry.y)),end=min(maxT,min(leave.x,leave.y));
    if(t>=end)return maxT+1;
    float3 p=ro+rd*t;
    float previous=p.y-ReferenceHeight(p.xz);
    if(previous<=.0005)return t;
    // About one metre projected onto the height field. This is a dense
    // reference, not a proof for sub-step tangent contacts; CPU exact-cell
    // tests cover that case separately. Analytic vertical rays bypass it.
    float dt=.25*TERRAIN_TEXEL/max(length(rd.xz),.002);
    [loop]for(int i=0;i<16384;++i)
    {
        float next=min(t+dt,end);p=ro+rd*next;
        float gap=p.y-ReferenceHeight(p.xz);
        if(gap<=0)
        {
            float lo=t,hi=next;
            [loop]for(int j=0;j<18;++j)
            {
                float mid=(lo+hi)*.5;float3 q=ro+rd*mid;
                if(q.y-ReferenceHeight(q.xz)>0)lo=mid;else hi=mid;
            }
            return (lo+hi)*.5;
        }
        if(next>=end)return maxT+1;
        t=next;previous=gap;
    }
    return maxT+1;
}

float4 TerrainTraceProbe(VSOut input):SV_Target
{
    uint id=(uint)input.pos.y*(uint)G.x+(uint)input.pos.x;
    uint kind=id%5;
    float2 random=float2(frac(id*.61803398875+.19),frac(id*.38196601125+.37));
    float3 ro,rd;float reference=MAX_DIST+1;
    if(kind==0)
    {
        CameraFrame c=GetCameraFrame(G.z);
        ro=c.origin;rd=CameraRay(c,random,16.0/9.0);
    }
    else
    {
        float2 xz=float2(-5500,-1000)+random*float2(11000,11000);
        float ground=ReferenceHeight(xz);
        if(kind==1)
        {
            float height=1.0+frac(id*.754877666)*1800.0;
            ro=float3(xz.x,ground+height,xz.y);rd=float3(0,-1,0);reference=ro.y-ground;
        }
        else if(kind==2)
        {
            ro=float3(xz.x,4000,xz.y);
            rd=normalize(float3(cos(id*2.399963),.03+random.x*.3,sin(id*2.399963)));
        }
        else if(kind==3)
        {
            ro=float3(xz.x,ground+1.0+random.x*40.0,xz.y);
            rd=normalize(float3(cos(id*2.399963),-.015,sin(id*2.399963)));
        }
        else
        {
            float2 grid=floor((xz-float2(-6000,-1500))/TERRAIN_TEXEL);
            xz=float2(-6000,-1500)+grid*TERRAIN_TEXEL;
            ro=float3(xz.x,ReferenceHeight(xz)+3.0,xz.y);rd=normalize(float3(-1,-.12,-.3));
        }
    }
    float actual=TraceTerrain(ro,rd,MAX_DIST);
    if(kind!=1&&kind!=2)reference=DenseTerrainReference(ro,rd,MAX_DIST);
    bool actualHit=actual<=MAX_DIST,referenceHit=reference<=MAX_DIST;
    float3 p=ro+rd*actual;
    float residual=actualHit?p.y-ReferenceHeight(p.xz):0;
    uint flags=(actualHit?1:0)|(referenceHit?2:0)|(kind<<2);
    return float4(actual,reference,residual,(float)flags);
}
