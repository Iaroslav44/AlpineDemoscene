// Runtime HDR reconstruction: camera reprojection, disocclusion rejection and
// variance-clipped history. No learned model or claimed neural inference.
#include "frame_vertex.hlsli"
cbuffer Frame : register(b0)
{
    float4 G; // low width/height, current seconds, frame
    float4 O; // output width/height, seed, previous seconds
};
Texture2D<float4> Input0 : register(t0);
Texture2D<float4> Input1 : register(t1);
SamplerState LinearClamp : register(s0);

float4 LoadLow(int2 p)
{
    return Input0.Load(int3(clamp(p,int2(0,0),int2(G.xy)-1),0));
}
float3 RGBToYCoCg(float3 c)
{
    return float3(dot(c,float3(.25,.5,.25)),.5*(c.r-c.b),dot(c,float3(-.25,.5,-.25)));
}
float3 YCoCgToRGB(float3 c)
{
    return float3(c.x+c.y-c.z,c.x+c.z,c.x-c.y-c.z);
}

float4 Temporal(VSOut input) : SV_Target
{
    float2 uv=input.uv;
    float2 jitter=TemporalJitter(((int)G.w)&7);
    float2 lowPosition=uv*G.xy-.5-jitter;
    int2 base=int2(floor(lowPosition+.5));
    float2 sub=lowPosition-float2(base);
    float4 centre=LoadLow(base);
    float centreDepth=abs(centre.a);
    float3 sum=0,mean=0,secondMoment=0;
    float weightSum=0;
    float3 localMin=1e6,localMax=-1e6;
    float reactive=centre.a<0?1.0:0.0;
    [unroll] for(int y=-1;y<=1;++y)
    {
        [unroll] for(int x=-1;x<=1;++x)
        {
            float4 tap=LoadLow(base+int2(x,y));
            float2 delta=float2(x,y)-sub;
            float w=exp2(-2.0*dot(delta,delta)-96.0*abs(abs(tap.a)-centreDepth));
            sum+=tap.rgb*w; weightSum+=w;
            float3 yc=RGBToYCoCg(tap.rgb);
            mean+=yc; secondMoment+=yc*yc;
            localMin=min(localMin,yc);localMax=max(localMax,yc);
            reactive=max(reactive,tap.a<0?1.0:0.0);
        }
    }
    float3 current=max(0.0,sum/max(weightSum,1e-6));
    mean/=9.0;secondMoment/=9.0;
    float3 sigma=sqrt(max(0.0,secondMoment-mean*mean));
    float3 lo=max(localMin,mean-1.25*sigma);
    float3 hi=min(localMax,mean+1.25*sigma);
    CameraFrame cam=CurrentFrameCamera(input);
    CameraFrame prev=PreviousFrameCamera(input);
    // Depth belongs to the nearest actual low-resolution sample, not a blend
    // across foreground/background surfaces.
    float2 sampleUV=(float2(base)+.5+jitter)/G.xy;
    float3 ray=CameraRay(cam,sampleUV,G.x/G.y);
    float distance=DecodeDepth(centreDepth);
    bool sky=centreDepth>=.9995;
    float3 world=sky?prev.origin+ray*MAX_DIST:cam.origin+ray*distance;
    float viewZ;
    float2 historyUV=ProjectCamera(prev,world,G.x/G.y,viewZ)+(uv-sampleUV);
    bool inside=all(historyUV>0)&&all(historyUV<1)&&viewZ>0;
    float4 history=Input1.SampleLevel(LinearClamp,historyUV,0);
    int2 hp=clamp(int2(historyUV*O.xy),int2(0,0),int2(O.xy)-1);
    // Never interpolate the sign of a reactive flag or depth at an edge.
    float historyAlpha=Input1.Load(int3(hp,0)).a;
    float expectedDepth=length(world-prev.origin);
    float oldDepth=DecodeDepth(historyAlpha);
    float tolerance=max(.025,expectedDepth*.008);
    float depthConfidence=1.0-smoothstep(tolerance,tolerance*3.0,abs(oldDepth-expectedDepth));
    if(sky)depthConfidence=abs(historyAlpha)>.9995?1.0:0.0;
    float dt=G.z-O.w;
    bool reset=G.w<1||dt<0||dt>.25||abs(historyAlpha)<1e-5;
    float3 historyYC=RGBToYCoCg(history.rgb);
    float3 clipped=YCoCgToRGB(clamp(historyYC,lo,hi));
    float motion=length((historyUV-uv)*O.xy);
    float lumaDelta=abs(historyYC.x-RGBToYCoCg(current).x);
    float historyWeight=pow(.86,max(dt*60.0,1.0));
    historyWeight*=exp2(-.018*motion-3.0*lumaDelta)*depthConfidence;
    // Animated objects have no deformation motion vectors: use current frame.
    historyWeight*=reactive>.5||historyAlpha<0?0.0:1.0;
    if(reset||!inside)historyWeight=0;
    float3 resolved=max(0.0,lerp(current,clipped,saturate(historyWeight)));
    return float4(resolved,reactive>.5?-max(centreDepth,1e-4):max(centreDepth,1e-4));
}

float Hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + O.z * 7.1);
    return frac((p3.x + p3.y) * p3.z);
}

float3 ACESCompact(float3 x)
{
    return saturate((x * (2.51 * x + 0.03)) /
                    (x * (2.43 * x + 0.59) + 0.14));
}

float ResolvedAlpha(float2 uv)
{
    int2 p=clamp(int2(uv*O.xy),int2(0,0),int2(O.xy)-1);
    return Input0.Load(int3(p,0)).a;
}

float3 DepthAwareDOF(float2 uv, out float encodedDepth)
{
    float4 centre = Input0.SampleLevel(LinearClamp, uv, 0.0);
    centre.a=ResolvedAlpha(uv);
    encodedDepth = abs(centre.a);
    float centreDepth = DecodeDepth(encodedDepth);

    // Median of three real depths, never a bilinear blend of signed reactive
    // flags: opposite signs would cancel to a fictitious near-camera surface.
    float2 focusUV = float2(0.5, 0.5);
    float a=abs(ResolvedAlpha(focusUV));
    float b=abs(ResolvedAlpha(focusUV+float2(2.0/O.x,0)));
    float c=abs(ResolvedAlpha(focusUV-float2(2.0/O.x,0)));
    float focusEncoded=max(min(a,b),min(max(a,b),c));
    float focusDepth = clamp(DecodeDepth(focusEncoded), 1.0, MAX_DIST);

    float portrait = 1.0 - smoothstep(35.0, 180.0, focusDepth);
    // Moderate aperture: retain architecture/material detail outside a closeup.
    float maxCoCPixels = lerp(0.35, 2.0, portrait);
    float relativeDefocus = abs(centreDepth - focusDepth) / max(focusDepth, 1.0);
    float cocPixels = maxCoCPixels * smoothstep(0.025, 0.55, relativeDefocus);
    float centreReactive = centre.a < 0.0 ? 1.0 : 0.0;
    cocPixels *= lerp(1.0, 0.18, centreReactive);

    float3 sum = centre.rgb;
    float weightSum = 1.0;
    [unroll]
    for (int i = 0; i < 7; ++i)
    {
        float fi = (float)i + 0.5;
        float angle = fi * 2.39996323;
        float radius = sqrt(fi / 7.0) * cocPixels;
        float2 offset = float2(cos(angle), sin(angle)) * radius / O.xy;
        float4 tap = Input0.SampleLevel(LinearClamp, uv + offset, 0.0);
        tap.a=ResolvedAlpha(uv+offset);
        float tapDepth = DecodeDepth(abs(tap.a));
        float depthDelta = abs(tapDepth - centreDepth) / max(centreDepth, 1.0);
        float w = exp2(-18.0 * depthDelta);
        w *= tap.a < 0.0 ? 0.20 : 1.0;
        sum += tap.rgb * w;
        weightSum += w;
    }
    return sum / weightSum;
}

float3 ResolvedWorld(CameraFrame camera,float2 uv)
{
    return camera.origin+CameraRay(camera,uv,O.x/O.y)*DecodeDepth(ResolvedAlpha(uv));
}

float ScreenContactOcclusion(CameraFrame camera,float2 uv,float depth)
{
    if(depth>90.0||depth<0.15)return 1.0;
    float3 p=ResolvedWorld(camera,uv);
    float2 pixel=1.0/O.xy;
    float3 xp=ResolvedWorld(camera,uv+float2(pixel.x*2,0))-p;
    float3 xm=p-ResolvedWorld(camera,uv-float2(pixel.x*2,0));
    float3 yp=ResolvedWorld(camera,uv+float2(0,pixel.y*2))-p;
    float3 ym=p-ResolvedWorld(camera,uv-float2(0,pixel.y*2));
    float3 dx=dot(xp,xp)<dot(xm,xm)?xp:xm;
    float3 dy=dot(yp,yp)<dot(ym,ym)?yp:ym;
    float3 normal=cross(dx,dy);
    normal*=rsqrt(max(dot(normal,normal),1e-12));
    if(dot(normal,camera.origin-p)<0.0)normal=-normal;
    float radius=clamp(0.32*camera.lens*O.y/max(depth,0.1),3.0,46.0);
    float occlusion=0.0;
    [unroll]for(int i=0;i<8;++i)
    {
        float angle=(i+0.5)*2.39996323;
        float2 offset=float2(cos(angle),sin(angle))*radius*sqrt((i+0.5)/8.0)*pixel;
        float2 sampleUV=uv+offset;
        if(any(sampleUV<=0.0)||any(sampleUV>=1.0))continue;
        float3 delta=ResolvedWorld(camera,sampleUV)-p;
        float d2=dot(delta,delta);
        float horizon=max(0.0,dot(normal,delta)-0.025);
        occlusion+=horizon*rsqrt(max(d2,0.0004))*saturate(1.0-d2/1.44);
    }
    // Applied only at display, not recursively baked into the HDR history.
    // This is local screen-space contact shading, not global illumination.
    return 1.0-min(0.32,occlusion*0.23);
}

float4 Display(VSOut input) : SV_Target
{
    float2 uv = input.uv;
    float encodedDepth;
    float3 colour = max(DepthAwareDOF(uv, encodedDepth), 0.0);
    colour*=ScreenContactOcclusion(CurrentFrameCamera(input),uv,DecodeDepth(encodedDepth));
    colour = ACESCompact(colour * 1.02);
    float2 v = uv * 2.0 - 1.0;
    colour *= saturate(1.0 - 0.055 * dot(v * v, float2(0.72, 0.46)));
    float noise = Hash12(input.pos.xy + float2(G.w * 17.0, G.w * 43.0)) - 0.5;
    float dither = (frac(dot(input.pos.xy, float2(0.754877666, 0.569840296)) + G.w * 0.618) - 0.5);
    colour = pow(saturate(colour), 1.0 / 2.2);
    colour = saturate(colour + (noise * 0.70 + dither * 0.30) / 255.0);
    return float4(colour, 1.0);
}
