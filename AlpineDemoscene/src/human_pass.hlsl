// Alpine Dreaming - bounded articulated-human composite pass.
// Input is the linear-HDR procedural world; only actual HumanMap geometry can
// replace it, and only when its signed logarithmic depth is nearer.

#include "human_procedural.hlsli"

cbuffer Frame : register(b0)
{
    float4 G;  // low width, low height, seconds, frame index
    float4 G2; // seed / host temporal data
};

Texture2D<float4> SceneLow : register(t0);

// One camera/terrain definition is shared with the world and temporal passes.
#include "frame_vertex.hlsli"
#include "cinematic_lighting.hlsli"
#include "people_motion.hlsli"
#define HP_PI PI
#define HP_TAU TAU
#define HP_MAX_DIST MAX_DIST
#define HP_DEPTH_K DEPTH_K
#define HPJitter TemporalJitter
#define HPCamera Camera

void HPPersonPose(int index,float time,float3 cameraPos,out float3 root,out float3 facing,
                  out float scale,out float personId,out float phase,out float speed)
{
    float2 c=PeopleCentre(index,time),velocity=PeopleVelocity(index,time);
    scale=PeopleScale(index);
    if(index==0)
    {
        personId=999.0;phase=0.7;
    }
    else
    {
        float fi=(float)index;
        personId=50.0+fi*19.0;phase=fi*1.37;
    }
    // Elevation is sampled only after the inexpensive horizontal ray rejection.
    root=float3(c.x,0.0,c.y);
    speed=length(velocity);
    float2 fv=normalize(velocity+0.001);
    facing=float3(fv.x,0,fv.y);
}

bool HPRayBox(float3 ro,float3 rd,float3 bmin,float3 bmax,out float tn,out float tf)
{
    // Preserve negative near-zero directions: adding epsilon can produce zero.
    float3 safe=(step(0.0,rd)*2.0-1.0)*max(abs(rd),0.000001);
    float3 a=(bmin-ro)/safe,b=(bmax-ro)/safe,lo=min(a,b),hi=max(a,b);
    tn=max(lo.x,max(lo.y,lo.z));tf=min(hi.x,min(hi.y,hi.z));
    return tf>=max(tn,0.0);
}

float3 HPSun(float loopA)
{
    float a=loopA-0.20;return normalize(float3(cos(a),0.28+0.38*sin(a),sin(a)));
}

float3 HPFresnel(float c,float3 f0){return f0+(1.0-f0)*pow(1.0-saturate(c),5.0);}

float3 HPPBR(float3 albedo,float3 n,float3 v,float3 l,float rough,float3 light)
{
    float3 hv=v+l;float3 h=hv*rsqrt(max(dot(hv,hv),1e-8));
    float nl=saturate(dot(n,l)),nv=max(saturate(dot(n,v)),1e-4);
    float nh=saturate(dot(n,h)),vh=saturate(dot(v,h));float a=max(0.045,rough*rough),a2=a*a;
    float den=nh*nh*(a2-1.0)+1.0,D=a2/max(HP_PI*den*den,1e-7);
    float gv=nl*sqrt(nv*nv*(1.0-a2)+a2),gl=nv*sqrt(nl*nl*(1.0-a2)+a2);
    float visibility=0.5/max(gv+gl,1e-5);
    float3 F=HPFresnel(vh,0.04);float3 spec=D*visibility*F;
    float daylight=smoothstep(-0.06,0.16,l.y);
    return albedo*(0.13+0.20*saturate(n.y*0.5+0.5))*lerp(0.10,1.0,daylight)
         +(albedo*(1.0-F)/HP_PI+spec)*light*nl*(3.2*daylight);
}

float3 HPShade(HumanSurface hs,float3 p,float3 rd,float3 sun)
{
    float3 v=-rd;
    float nl=saturate(dot(hs.normal,sun));
    float nv=saturate(dot(hs.normal,v));
    float visibility=CinematicShadow(p,hs.normal);
    float roughness=abs(hs.material-HUM_MAT_EYE)<0.5?0.09:hs.roughness;
    float3 col=CinematicLightingVisible(hs.normal,v,hs.albedo,roughness,0.0,hs.occlusion,visibility);
    if(abs(hs.material-HUM_MAT_SKIN)<0.5)
    {
        // Diffusion is approximated with a broad red-biased irradiance lobe;
        // thin ears transmit light while opaque cheeks do not glow through.
        float wrap=saturate((dot(hs.normal,sun)+0.38)/1.38);
        float back=pow(saturate(dot(-sun,v)),3.0)*hs.thinSkin;
        col+=CinematicSunColor()*hs.albedo*float3(1.0,0.43,0.25)
             *(0.14*max(0.0,wrap-nl)*hs.occlusion+0.20*back)*visibility;
    }
    else if(abs(hs.material-HUM_MAT_EYE)<0.5)
    {
        col+=pow(saturate(dot(reflect(-sun,hs.normal),v)),500.0)*CinematicSunColor()*0.20*visibility;
    }
    else if(abs(hs.material-HUM_MAT_LIP)<0.5)
        col+=pow(saturate(dot(reflect(-sun,hs.normal),v)),130.0)*CinematicSunColor()*(0.045*visibility);
    else if(abs(hs.material-HUM_MAT_HAIR)<0.5)
        col+=pow(1.0-nv,3.2)*nl*CinematicSunColor()*float3(0.035,0.025,0.018)*visibility;
    return col;
}

float HPDecodeDepth(float a)
{
    float n=abs(a);return (exp2(n*log2(1.0+HP_MAX_DIST*HP_DEPTH_K))-1.0)/HP_DEPTH_K;
}

float HPEncodeDepth(float t)
{
    return max(0.0001,log2(1.0+min(t,HP_MAX_DIST)*HP_DEPTH_K)/log2(1.0+HP_MAX_DIST*HP_DEPTH_K));
}

float4 H(VSOut input):SV_Target
{
    int2 pixel=int2(input.pos.xy);
    float4 background=SceneLow.Load(int3(pixel,0));
    CameraFrame camera=CurrentFrameCamera(input);
    float3 ro=camera.origin;float lens=camera.lens;
    if(length(ro.xz-float2(0,1800))>1050.0)return background;

    float2 sampleUV=input.uv+HPJitter(((int)G.w)&7)/G.xy;
    float3 rd=CameraRay(camera,sampleUV,G.x/G.y);
    float sceneT=HPDecodeDepth(background.a);

    int selected=-1;float bestT=sceneT;
    HumanPrepared bestContext=(HumanPrepared)0;
    float bestId=0.0;
    [fastopt]for(int i=0;i<6;++i)
    {
        float3 root,facing;float scale,id,phase,speed;
        HPPersonPose(i,G.z,ro,root,facing,scale,id,phase,speed);
        float2 delta=root.xz-ro.xz;
        float horizontalRay=dot(rd.xz,rd.xz);
        float crossDistance=delta.x*rd.z-delta.y*rd.x;
        if(dot(delta,delta)>350.0*350.0)continue;
        if(horizontalRay>1.0e-9 && crossDistance*crossDistance>0.75*0.75*horizontalRay)continue;
        if(horizontalRay<=1.0e-9 && dot(delta,delta)>0.75*0.75)continue;
        root.y=Terrain(root.xz)+0.025;
        float3 ext=float3(0.72,1.12,0.72)*scale;
        float3 center=root+float3(0,0.91*scale,0);float tn,tf;
        if(!HPRayBox(ro,rd,center-ext,center+ext,tn,tf)||tn>=bestT||tf<=0.0)continue;
        HumanPrepared context=HumanPrepare(G.z,ro,root,facing,scale,id,phase,speed,
                                            max(0.0,tn)/(G.y*lens));
        float t=max(0.0,tn),farT=min(tf,bestT),lastT=t;
        [fastopt]for(int stepIndex=0;stepIndex<64;++stepIndex)
        {
            if(t>=farT)break;
            HumanHit hm=HumanMapPrepared(ro+rd*t,context);
            float eps=clamp(t/(G.y*lens)*0.25,0.0006,0.008);
            if(hm.material>0.0 && hm.distance<eps)
            {
                // A negative crossing is refined; exhausting the loop is never
                // treated as a hit. Other residents remain eligible after a miss.
                if(hm.distance<0.0 && t>lastT)
                {
                    float lo=lastT,hi=t;
                    [loop]for(int refine=0;refine<4;++refine)
                    {
                        float mid=(lo+hi)*0.5;
                        if(HumanMapPrepared(ro+rd*mid,context).distance>0.0)lo=mid;else hi=mid;
                    }
                    t=hi;
                }
                bestT=t;selected=i;bestContext=context;bestId=id;break;
            }
            lastT=t;
            t+=max(0.00035,hm.distance*0.70);
        }
    }
    if(selected<0||bestT>=sceneT)return background;
    float3 p=ro+rd*bestT;
    HumanSurface hs=HumanSurfacePrepared(p,bestContext,bestId,bestT/(G.y*lens));
    float3 color=HPShade(hs,p,rd,CinematicFrame[8].xyz);
    color=CinematicFog(color,p);
    return float4(max(color,0.0),-HPEncodeDepth(bestT));
}
