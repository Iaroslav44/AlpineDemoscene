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

float3 CompressRadiance(float3 c)
{
    c=max(c,0.0);
    return c/(1.0+dot(c,float3(.2126,.7152,.0722)));
}
float3 ExpandRadiance(float3 c)
{
    c=max(c,0.0);
    return c/max(.0001,1.0-dot(c,float3(.2126,.7152,.0722)));
}

float3 HistoryCubic(float2 uv)
{
    // Separable Catmull-Rom: combine the two positive middle weights into one
    // bilinear lookup, leaving 3x3 taps. A second bilinear reconstruction on
    // every frame used to progressively smear stone/roof details in motion.
    float2 position=uv*O.xy-.5,base=floor(position),f=position-base;
    float2 w0=f*(-.5+f*(1.0-.5*f));
    float2 w1=1.0+f*f*(-2.5+1.5*f);
    float2 w2=f*(.5+f*(2.0-1.5*f));
    float2 w3=f*f*(-.5+.5*f),w12=w1+w2;
    float2 middle=base+w2/w12;
    float3 result=0;
    [unroll]for(int y=0;y<3;++y)[unroll]for(int x=0;x<3;++x)
    {
        float px=x==0?base.x-1.0:(x==1?middle.x:base.x+2.0);
        float py=y==0?base.y-1.0:(y==1?middle.y:base.y+2.0);
        float wx=x==0?w0.x:(x==1?w12.x:w3.x);
        float wy=y==0?w0.y:(y==1?w12.y:w3.y);
        result+=Input1.SampleLevel(LinearClamp,(float2(px,py)+.5)/O.xy,0).rgb*(wx*wy);
    }
    return max(result,0.0);
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
            // Resolve/covariance in reversible luminance-compressed HDR space.
            // One solar glint must not pull an entire 3x3 neighborhood white.
            float3 compressed=CompressRadiance(tap.rgb);
            sum+=compressed*w; weightSum+=w;
            float3 yc=RGBToYCoCg(compressed);
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
    float3 history=HistoryCubic(historyUV);
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
    float3 historyYC=RGBToYCoCg(CompressRadiance(history));
    float3 currentYC=RGBToYCoCg(current);
    // Clip along the current->history segment, not independently per channel.
    // Both endpoints are valid compressed radiance; the segment stays inside
    // that convex domain. A component-wise YCoCg box clamp can combine colors
    // from different samples into luminance >=1 and explode during expansion.
    lo=min(lo,currentYC);hi=max(hi,currentYC);
    float3 difference=historyYC-currentYC;
    float3 room=lerp(currentYC-lo,hi-currentYC,step(0.0,difference));
    // An axis with zero travel does not constrain the segment (e.g. both
    // chroma axes of neutral grey). Treat it as fully accepted, even when
    // the variance box has zero width on that axis.
    float3 ratio=lerp(1.0,room/max(abs(difference),1e-6),step(1e-6,abs(difference)));
    float amount=saturate(min(1.0,min(ratio.x,min(ratio.y,ratio.z))));
    float3 clipped=YCoCgToRGB(lerp(currentYC,historyYC,amount));
    float motion=length((historyUV-uv)*O.xy);
    float lumaDelta=abs(historyYC.x-currentYC.x);
    float historyWeight=pow(.86,max(dt*60.0,1.0));
    historyWeight*=exp2(-.018*motion-3.0*lumaDelta)*depthConfidence;
    // Animated objects have no deformation motion vectors: use current frame.
    historyWeight*=reactive>.5||historyAlpha<0?0.0:1.0;
    if(reset||!inside)historyWeight=0;
    float3 resolved=ExpandRadiance(lerp(current,clipped,saturate(historyWeight)));
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

// AgX-inspired cinema filmic tonemapper with pre-curve gamut inset crosstalk.
// Prevents per-channel neon primary skews on sunlit grass, timber and skin while
// desaturating intense highlights smoothly into creamy photographic white.
float3 CinemaTonemap(float3 c)
{
    c=max(c,0.0);
    float3 inset=float3(dot(c,float3(.856,.092,.052)),
                        dot(c,float3(.074,.878,.048)),
                        dot(c,float3(.062,.088,.850)));
    float3 mapped=ACESCompact(inset);
    float luma=dot(mapped,float3(.2126,.7152,.0722));
    float satBoost=lerp(1.13,.96,smoothstep(.35,.92,luma));
    mapped=max(0.0,luma+(mapped-luma)*satBoost);
    // Subtle split-tone cinema negative balance: crisp cool-neutral deep shadows
    // and natural warm highlight rolloff without tinting neutral snow.
    float shadowMask=(1.0-smoothstep(.0,.18,luma))*luma;
    mapped+=shadowMask*float3(-.010,.002,.016);
    return saturate(mapped);
}

float3 CinemaBloom(float2 uv)
{
    float2 aspectScale=float2(O.y/max(O.x,1.0),1.0);
    float3 bloom=0,halation=0;
    [unroll]for(int i=0;i<12;++i)
    {
        float fi=(float)i+.5;
        float angle=fi*2.39996323;
        float2 dir=float2(cos(angle),sin(angle))*aspectScale;
        float rBloom=(4.5+36.0*(fi/12.0))/1080.0;
        float3 tap=max(Input0.SampleLevel(LinearClamp,uv+dir*rBloom,0.0).rgb,0.0);
        float luma=dot(tap,float3(.2126,.7152,.0722));
        float knee=smoothstep(.82,2.6,luma);
        bloom+=tap*(knee/(1.0+luma*.16));
        if(i<6)
        {
            float rHal=(2.0+7.5*(fi/6.0))/1080.0;
            float3 hTap=max(Input0.SampleLevel(LinearClamp,uv+dir*rHal,0.0).rgb,0.0);
            float hLuma=dot(hTap,float3(.2126,.7152,.0722));
            halation+=hTap*(smoothstep(1.15,3.4,hLuma)/(1.0+hLuma*.20));
        }
    }
    return (bloom/12.0)*.042+(halation/6.0)*float3(.022,.009,.003);
}

float ResolvedAlpha(float2 uv)
{
    int2 p=clamp(int2(uv*O.xy),int2(0,0),int2(O.xy)-1);
    return Input0.Load(int3(p,0)).a;
}

float3 DepthAwareDOF(float2 uv,CameraFrame camera,out float encodedDepth)
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
    // Thin-lens circle of confusion. A 24mm-tall sensor and the projection
    // lens determine focal length; landscapes use f/8, closeups f/2.6.
    float focalLength=.012*camera.lens,aperture=lerp(8.0,2.6,portrait);
    float viewDepth=max(.1,centreDepth*dot(CameraRay(camera,uv,O.x/O.y),camera.forward));
    float circle=focalLength*focalLength*abs(viewDepth-focusDepth)
        /(aperture*viewDepth*max(focusDepth-focalLength,.01));
    float cocPixels=min(9.5,.5*circle/.024*O.y);

    // Landscapes at f/8 normally have a subpixel CoC; the 16 texture taps
    // cannot change their resolved image meaningfully. Keep the physical
    // near-field blur while avoiding that work over the whole mountain view.
    float3 sum = centre.rgb;
    float weightSum = 1.0;
    [branch]if(cocPixels>=.35)
    {
    float dofIgn = frac(52.9829189 * frac(dot(floor(uv * O.xy) + 0.5, float2(0.06711056, 0.00583715))));
    [unroll]
    for (int i = 0; i < 16; ++i)
    {
        float fi = (float)i + 0.5;
        float angle = fi * 2.39996323 + dofIgn * TAU;
        float radius = sqrt(fi / 16.0) * cocPixels;
        float2 offset = float2(cos(angle), sin(angle)) * radius / O.xy;
        float4 tap = Input0.SampleLevel(LinearClamp, uv + offset, 0.0);
        tap.a=ResolvedAlpha(uv+offset);
        float tapDepth = DecodeDepth(abs(tap.a));
        float depthDelta = abs(tapDepth - centreDepth) / max(centreDepth, 1.0);
        // Prevent sharp foreground edges from bleeding into distant backgrounds,
        // while letting out-of-focus background highlights form smooth bokeh discs.
        float bgBlur = step(focusDepth * 1.18, tapDepth) * step(focusDepth * 1.18, centreDepth);
        float w = lerp(exp2(-18.0 * depthDelta), 1.0, bgBlur * 0.82);
        float tapLuma = dot(max(tap.rgb, 0.0), float3(.2126, .7152, .0722));
        w *= 1.0 + portrait * 0.28 * smoothstep(0.85, 3.2, tapLuma) / (1.0 + tapLuma * 0.12);
        sum += tap.rgb * w;
        weightSum += w;
    }
    }
    return sum / weightSum;
}

float ScreenContactOcclusion(CameraFrame camera,float2 uv,float depth)
{
    if(depth>90.0||depth<0.15)return 1.0;
    float2 pixel=1.0/O.xy;
    float radius=clamp(0.28*camera.lens*O.y/max(depth,0.6),2.5,28.0);
    float ign=frac(52.9829189*frac(dot(floor(uv*O.xy)+0.5,float2(0.06711056,0.00583715))));
    // Symmetric second-difference depth-crease occlusion with a deadzone above
    // FP16 radial depth quantization (~0.001*depth) so planar/sloped walls are
    // 100% free of concentric quantization rings while concave corners darken.
    float deadzone=depth*0.0045+0.008;
    float range=max(depth*0.085,0.18);
    float occlusion=0.0;
    [unroll]for(int i=0;i<4;++i)
    {
        float angle=(i+ign)*0.78539816;
        float2 offset=float2(cos(angle),sin(angle))*(radius*sqrt((i+0.5)/4.0))*pixel;
        float dPos=DecodeDepth(ResolvedAlpha(uv+offset));
        float dNeg=DecodeDepth(ResolvedAlpha(uv-offset));
        float crease=max(0.0,depth-0.5*(dPos+dNeg)-deadzone);
        float weight=exp2(-abs(dPos-dNeg)/range);
        occlusion+=saturate(crease/(depth*0.035+0.04))*weight;
    }
    // Applied only at display, not recursively baked into the HDR history.
    // This is local screen-space contact shading, not global illumination.
    return 1.0-min(0.26,occlusion*0.18);
}

float4 Display(VSOut input) : SV_Target
{
    float2 uv = input.uv;
    CameraFrame cam = CurrentFrameCamera(input);
    float encodedDepth;
    float3 colour = max(DepthAwareDOF(uv,cam,encodedDepth),0.0);
    colour*=ScreenContactOcclusion(cam,uv,DecodeDepth(encodedDepth));
    colour+=CinemaBloom(uv);
    float sunY=DiurnalSunDirection(fmod(G.z,128.0)*(TAU/128.0)).y;
    float exposure=lerp(1.88,.86,smoothstep(.038,.44,sunY));
    float2 v = uv * 2.0 - 1.0;
    colour *= exposure * saturate(1.0 - 0.085 * dot(v * v, float2(0.74, 0.48)));
    colour = CinemaTonemap(colour);
    float noise = Hash12(input.pos.xy + float2(G.w * 17.0, G.w * 43.0)) - 0.5;
    float dither = (frac(dot(input.pos.xy, float2(0.754877666, 0.569840296)) + G.w * 0.618) - 0.5);
    float luma = dot(colour, float3(.2126, .7152, .0722));
    float filmGrain = noise * lerp(1.1, 2.2, 4.0 * luma * (1.0 - luma));
    // Exact sRGB output transfer, including its linear toe (the swapchain is
    // UNORM, not an automatic sRGB render target).
    colour = lerp(12.92*colour,1.055*pow(max(colour,0.0),1.0/2.4)-.055,step(.0031308,colour));
    colour = saturate(colour + (filmGrain * 0.72 + dither * 0.35) / 255.0);
    // A physical trajectory is not forced to close by injecting energy.
    // Editorial fades cover the explicit reset of the 128s demonstration.
    float phase=FlightTime(G.z);
    colour*=smoothstep(0.0,.8,phase)*(1.0-smoothstep(127.2,128.0,phase));
    return float4(colour, 1.0);
}
