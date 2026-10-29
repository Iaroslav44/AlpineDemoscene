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

float3 HPSkinLighting(HumanSurface hs,float3 v,float3 l,float visibility)
{
    float3 n=hs.normal,macroNormal=hs.geometricNormal;
    float3 hv=v+l;float3 h=hv*rsqrt(max(dot(hv,hv),1e-8));
    float nl=saturate(dot(n,l)),nv=max(saturate(dot(n,v)),1e-4);
    float nh=saturate(dot(n,h)),vh=saturate(dot(v,h));
    float f0=.028; // dielectric interface close to IOR 1.4
    float3 F=HPFresnel(vh,f0),specular=0,environmentWeight=0;
    // Two normalized GGX lobes approximate rough epidermis + the narrower
    // sebum reflection. Convex weights preserve energy; no painted white glint.
    [unroll]for(int i=0;i<2;++i)
    {
        float weight=i==0?.86:.14;
        float rough=i==0?hs.roughness:max(.40,hs.roughness*.76);
        float a=max(.025,rough*rough),a2=a*a;
        float den=nh*nh*(a2-1.0)+1.0,D=a2/max(PI*den*den,1e-7);
        float gv=nl*sqrt(nv*nv*(1.0-a2)+a2),gl=nv*sqrt(nl*nl*(1.0-a2)+a2);
        specular+=weight*D*(.5/max(gv+gl,1e-5))*F*nl;
        float4 fit=rough*float4(-1,-.0275,-.572,.022)+float4(1,.0425,1.04,-.04);
        float a004=min(fit.x*fit.x,exp2(-9.28*nv))*fit.x+fit.y;
        float2 dfg=float2(-1.04,1.04)*a004+fit.zw;
        environmentWeight+=weight*(f0*dfg.x+dfg.y);
    }
    // Wavelength-dependent wrapped irradiance is a local diffusion
    // approximation, not BSSRDF transport. Squared normalization keeps each
    // lobe's spherical integral equal to the original Lambert lobe's PI.
    // Pores affect interface reflections, not millimetre-scale diffusion.
    float mu=dot(macroNormal,l);
    float3 width=float3(.36,.19,.085);
    float3 diffused=max(mu+width,0.0)/((1.0+width)*(1.0+width));
    float3 diffuse=lerp(saturate(mu),diffused,.72)*hs.albedo*((1.0-f0)/PI);
    float3 light=CinematicSunColor()*CinematicFrame[8].w*visibility;
    float3 result=(diffuse+specular)*light;
    float3 ambient=AtmosphereDiffuse(macroNormal);
    result+=hs.albedo*(1.0-f0)*ambient*sqrt(hs.occlusion);
    float3 reflection=normalize(lerp(reflect(-v,n),macroNormal,hs.roughness*hs.roughness*.4));
    float3 environment=lerp(AtmosphereEnvironment(reflection),ambient,hs.roughness*hs.roughness);
    result+=environment*environmentWeight*hs.occlusion;
    float back=saturate(-mu)*(.45+.55*pow(saturate(dot(-l,v)),3.0))*hs.thinSkin;
    result+=light*hs.albedo*float3(.16,.042,.014)*back;
    return max(result,0);
}

float3 HPShade(HumanSurface hs,float3 p,float3 rd,float3 sun,float localVisibility)
{
    float3 v=-rd;
    float nl=saturate(dot(hs.normal,sun));
    float nv=saturate(dot(hs.normal,v));
    float visibility=CinematicShadow(p,hs.normal)*localVisibility;
    float roughness=abs(hs.material-HUM_MAT_EYE)<0.5?0.09:hs.roughness;
    float3 col=0;
    if(abs(hs.material-HUM_MAT_SKIN)<0.5)
    {
        col=HPSkinLighting(hs,v,sun,visibility);
    }
    else col=CinematicLightingVisible(hs.normal,v,hs.albedo,roughness,0.0,hs.occlusion,visibility);
    // The shared interface now includes the sky specular lobe. Adding a
    // second corneal reflection or painted lip glint would count it twice.
    if(abs(hs.material-HUM_MAT_HAIR)<0.5)
    {
        float3 tangent=cross(hs.normal,cross(float3(0,1,0),hs.normal));
        tangent*=rsqrt(max(dot(tangent,tangent),1e-6));
        float3 halfVector=normalize(sun+v);
        float along=dot(tangent,halfVector);
        float fibre=pow(sqrt(saturate(1.0-along*along)),45.0);
        col+=fibre*nl*CinematicSunColor()*float3(.025,.019,.014)*visibility;
    }
    return col;
}

float HPNoseVisibility(float3 p,float3 normal,float3 sun,HumanPrepared context)
{
    float3 local=HumanPreparedLocal(p+normal*.0012,context);
    if(local.y<1.57||local.y>1.69)return 1.0;
    float bob=.012*(1.0-cos(context.pose.gait*2.0))*context.pose.walking+.004*context.pose.breath;
    float sway=.012*sin(context.pose.gait)*context.pose.walking;
    float3 hp=HumRotateHead(local-float3(sway,1.485+bob,0),context.pose.headYaw,context.pose.headPitch)+float3(0,1.485,0);
    if(hp.z<.04||abs(hp.x)>.07)return 1.0;
    float3 direction=float3(dot(sun,context.right),sun.y,dot(sun,context.front));
    direction=HumRotateHead(direction,context.pose.headYaw,context.pose.headPitch);
    float visibility=1.0,t=.003;
    [loop]for(int i=0;i<7;++i)
    {
        float d=HumNoseDistance(hp+direction*t);
        visibility=min(visibility,saturate(d*22.0/t));
        t+=max(.003,min(d,.014));
    }
    // The compact visibility test resolves only the nose, and otherwise misses
    // cheek-to-nose diffuse transport. Retain that broad local contribution so
    // a seven-step binary occluder cannot paint the whole nasal base black.
    return lerp(.32,1.0,visibility);
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
    float localVisibility=abs(hs.material-HUM_MAT_SKIN)<.5?HPNoseVisibility(p,hs.normal,CinematicFrame[8].xyz,bestContext):1.0;
    float3 color=HPShade(hs,p,rd,CinematicFrame[8].xyz,localVisibility);
    color=CinematicFog(color,p);
    return float4(max(color,0.0),-HPEncodeDepth(bestT));
}
