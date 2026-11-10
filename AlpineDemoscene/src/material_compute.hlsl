// All material texels are generated from periodic mathematical fields on startup.
// Layer0 limestone,1 meadow,2 timber,3 plaster,4 slate,5 cobbles,6 skin,7 lake gravel.
RWTexture2DArray<float4> MaterialColorOutput : register(u0);
RWTexture2DArray<float4> MaterialNormalOutput : register(u1);
static const float MT=6.28318530718;
float MHash(float2 p)
{
    uint2 q=uint2(int2(p));uint h=q.x*1597334677u^q.y*3812015801u;
    h^=h>>16;h*=2246822519u;h^=h>>13;return (h&0x00ffffffu)/16777216.0;
}
float MNoise(float2 p,float2 period)
{
    float2 i=floor(p),f=frac(p);f=f*f*(3.0-2.0*f);
    float2 a=i-floor(i/period)*period,b=a+1.0;b-=floor(b/period)*period;
    return lerp(lerp(MHash(a),MHash(float2(b.x,a.y)),f.x),
                lerp(MHash(float2(a.x,b.y)),MHash(b),f.x),f.y);
}
float MFractal(float2 uv,float seed)
{
    float value=0.0;
    [unroll]for(int i=0;i<6;++i){float f=exp2(i+2.0);value+=MNoise(uv*f+seed,f)*exp2(-i)*.5079;}
    return value;
}
float3 MCells(float2 uv,float cells)
{
    float2 p=uv*cells,cell=floor(p),local=frac(p);float first=100,second=100,identity=0;
    [unroll]for(int j=-1;j<=1;++j)[unroll]for(int i=-1;i<=1;++i)
    {
        float2 offset=float2(i,j),id=cell+offset;id-=floor(id/cells)*cells;
        float2 site=.22+.56*float2(MHash(id+13),MHash(id+41));
        float d=length(offset+site-local);
        bool closer=d<first;
        second=min(second,closer?first:d);
        identity=closer?MHash(id+71):identity;
        first=min(first,d);
    }
    return float3(first,second-first,identity);
}
float MaterialHeight(uint layer,float2 uv)
{
    float f=MFractal(uv,11.0),fine=MNoise(uv*256,256),height=.5;
    if(layer==0)
    {
        // Weathered limestone: broken cleavage, shallow dissolved pits and
        // discontinuous bedding. Large flat Voronoi plates looked like paving
        // on mountains, so joints now occupy a narrow, irregular fraction.
        float2 warp=float2(MNoise(uv*8,8),MNoise(uv*8+21,8))*.055;
        float3 cells=MCells(uv+warp,7);
        float joints=1.0-smoothstep(.006,.052,cells.y);
        float beds=MNoise(float2(uv.x*16,uv.y*64)+float2(f*2.0,0),float2(16,64));
        float pits=pow(saturate((.39-MNoise(uv*128+37,128))/.39),2.0);
        height=.38+.23*f+.07*beds+.028*fine-.12*joints-.08*pits;
    }
    else if(layer==1)
    {
        float clumps=MNoise(uv*32+31,32);
        float litter=MNoise(float2(uv.x*128,uv.y*512)+21,float2(128,512));
        height=.34+.25*f+.13*clumps+.038*litter+.025*fine;
    }
    else if(layer==2)
    {
        float seam=smoothstep(.01,.045,abs(frac(uv.x*8+.5)-.5));
        float grain=.5+.5*sin(uv.x*MT*112+MNoise(uv*8,8)*7.0+MNoise(uv*32,32)*2.0);
        height=.22+.38*seam+.13*f+.035*grain+.025*fine;
    }
    else if(layer==3)height=.47+.16*f+.07*fine+.04*MNoise(uv*512,512);
    else if(layer==4)
    {
        float row=floor(uv.y*12),x=frac(uv.x*8+.5*fmod(row,2.0));
        float tileWarp=(MNoise(uv*24+17,24)-.5)*.06;
        float jointX=smoothstep(.008,.048,min(x,1-x)+tileWarp*.2),jointY=smoothstep(.008,.055,frac(uv.y*12));
        float split=smoothstep(.01,.04,abs(x-.5+(MHash(float2(floor(uv.x*8),row))-.5)*.22));
        height=.20+.46*jointX*jointY*(.90+.10*split)+.15*frac(uv.y*12)+.09*f+.02*fine;
    }
    else if(layer==5)
    {
        // Irregular Alpine granite/gneiss flagstones and cobbles instead of
        // uniform machine-laid rectangular bricks.
        float2 warp=float2(MNoise(uv*6,6),MNoise(uv*6+19,6))*.045;
        float3 stones=MCells(uv+warp,10);
        float bevel=smoothstep(.012,.095,stones.y);
        float crown=1.0-smoothstep(0.0,.48,stones.x)*.22;
        height=.14+.62*bevel*crown*(.82+.24*stones.z)+.11*f+.03*fine;
    }
    else if(layer==6)
    {
        float3 pore=MCells(uv,192);float indentation=1.0-smoothstep(.025,.16,pore.x);
        height=.55-.13*indentation+.045*f+.012*fine;
    }
    else
    {
        float3 stones=MCells(uv,26);
        height=.22+.54*smoothstep(.005,.105,stones.y)+.10*f+.035*fine;
    }
    return height;
}
float3 MaterialAlbedo(uint layer,float2 uv,float height,out float rough)
{
    float f=MFractal(uv,11),n=MNoise(uv*64,64),macro=MNoise(uv*4+31,4);rough=.85;
    float3 result=float3(.18,.18,.17);
    if(layer==0)
    {
        float mineral=MNoise(uv*16+63,16),lichen=smoothstep(.62,.79,macro)*smoothstep(.43,.61,n);
        float3 stone=lerp(float3(.115,.121,.119),float3(.285,.278,.254),smoothstep(.18,.82,f));
        stone=lerp(stone,stone*float3(1.16,.99,.78),smoothstep(.60,.78,mineral)*.36);
        stone=lerp(stone,float3(.235,.238,.191),lichen*.32);
        rough=clamp(.73+.17*n+.07*lichen,.66,.96);
        result=stone*(.88+.12*smoothstep(.36,.49,height));
    }
    else if(layer==1)
    {
        float soil=smoothstep(.56,.78,MNoise(uv*16+33,16));
        float dead=smoothstep(.52,.80,macro)*(.35+.65*n);
        float3 turf=lerp(float3(.028,.052,.018),float3(.078,.114,.034),f);
        turf=lerp(turf,float3(.128,.098,.046),dead*.48);
        turf=lerp(turf,float3(.058,.044,.026)*(.8+.4*f),soil*.42);
        rough=.89+.08*n;result=turf;
    }
    else if(layer==2)
    {
        rough=.68+.20*macro;float board=MHash(float2(floor(uv.x*8),0));
        float grain=.5+.5*sin(uv.x*MT*112+MNoise(uv*8,8)*7+MNoise(uv*32,32)*2);
        result=lerp(float3(.065,.035,.017),float3(.25,.15,.075),.30+.7*f)*(.82+.32*board)*(.90+.10*grain);
    }
    else if(layer==3){rough=.88;result=lerp(float3(.52,.47,.39),float3(.76,.72,.63),.5+.5*f)*(.95+.05*n);}
    else if(layer==4)
    {
        rough=.58+.22*n;float row=floor(uv.y*12);float tile=MHash(float2(floor(uv.x*8+.5*fmod(row,2)),row));
        float moss=smoothstep(.64,.82,macro)*smoothstep(.45,.70,n);
        result=lerp(float3(.048,.054,.058),float3(.17,.18,.185),tile)*(.84+.16*f)*(.68+.32*smoothstep(.22,.52,height));
        result=lerp(result,float3(.09,.11,.055),moss*.24);
    }
    else if(layer==5)
    {
        float2 warp=float2(MNoise(uv*6,6),MNoise(uv*6+19,6))*.045;
        float3 stones=MCells(uv+warp,10);
        float mortar=1.0-smoothstep(.010,.065,stones.y);
        float3 granite=lerp(float3(.13,.132,.128),float3(.26,.245,.22),stones.z);
        granite=lerp(granite,granite*float3(1.08,.98,.86),smoothstep(.4,.8,macro)*.45);
        float3 jointCol=float3(.078,.068,.052)*(.85+.3*f);
        result=lerp(granite*(.82+.18*smoothstep(.25,.60,height)),jointCol,mortar);
        rough=lerp(.64+.20*n,.93,mortar);
    }
    else if(layer==6){rough=.40+.18*f;result=float3(.52,.285,.19)*(.94+.10*f)+float3(.035,-.006,-.01)*(macro-.5);}
    else
    {
        float id=MCells(uv,26).z;rough=.63+.22*f;
        result=lerp(float3(.095,.10,.085),float3(.32,.31,.25),id)*(.76+.24*smoothstep(.3,.55,height));
    }
    return result;
}
[numthreads(8,8,1)]
void MaterialCS(uint3 id:SV_DispatchThreadID)
{
    if(any(id.xy>=1024)||id.z>=8)return;
    float2 uv=(id.xy+.5)/1024.0;float e=1.0/1024;
    float h=MaterialHeight(id.z,uv),rough;
    float hx=MaterialHeight(id.z,uv+float2(e,0))-MaterialHeight(id.z,uv-float2(e,0));
    float hy=MaterialHeight(id.z,uv+float2(0,e))-MaterialHeight(id.z,uv-float2(0,e));
    // Height is a normalized material relief. Layer-specific physical scales
    // keep skin pores shallow and masonry relief visibly rounded.
    float relief=id.z==6?.00035:(id.z==3?.003:(id.z==2?.009:(id.z==0?.10:(id.z==5?.012:(id.z==1?.024:.032)))));
    float3 normal=normalize(float3(-hx*relief/(2*e),-hy*relief/(2*e),1));
    MaterialColorOutput[id]=float4(MaterialAlbedo(id.z,uv,h,rough),h);
    MaterialNormalOutput[id]=float4(normal*.5+.5,rough);
}
