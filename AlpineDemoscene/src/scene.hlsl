// Alpine Dreaming - a 100% runtime procedural Direct3D 11 demoscene.
// Terrain fields and mesh geometry are generated at runtime. No image plates,
// prebuilt meshes, photographic textures or offline scene assets are loaded.

#include "frame_vertex.hlsli"
#include "detail_common.hlsli"
#include "cinematic_lighting.hlsli"

cbuffer Frame : register(b0)
{
    float4 G; // render width, render height, seconds, frame counter
    float4 G2; // session seed and host-reserved temporal data
};
Texture2D<float4> PlanarReflection : register(t5);

VSOut V(uint id : SV_VertexID)
{
    return BuildFrameVertex(id,G.z,G2.w);
}


float FBM2(float2 p)
{
    float s = 0.0;
    [unroll] for (int i = 0; i < 4; ++i)
    {
        s += Noise2(p) * (0.52 / exp2((float)i));
        p = float2(1.73 * p.x - 1.14 * p.y, 1.14 * p.x + 1.73 * p.y) + 7.1;
    }
    return s;
}

float Noise3(float3 p)
{
    float iy = floor(p.y), fy = frac(p.y);
    fy = fy * fy * (3.0 - 2.0 * fy);
    float2 skew = float2(37.0, 17.0) * iy;
    return lerp(Noise2(p.xz + skew), Noise2(p.xz + skew + float2(37.0, 17.0)), fy);
}

float FBM3(float3 p)
{
    float s = 0.0;
    [unroll] for (int i = 0; i < 3; ++i)
    {
        s += Noise3(p) * (0.56 / exp2((float)i));
        p = p * 1.93 + float3(7.1, 11.7, 3.9);
    }
    return s;
}

// Every animated layer samples this coherent periodic wind field.
float2 WindField(float2 xz, float loopA)
{
    float gust = sin(loopA * 3.0 + xz.x * 0.0021 + xz.y * 0.0013);
    float curl = sin(loopA * 5.0 - xz.x * 0.0012 + xz.y * 0.0023);
    return float2(0.72 + 0.28 * gust, 0.20 + 0.30 * curl);
}


float TraceTerrain(float3 ro, float3 rd, float maxT)
{
    float t = 0.05, lastT = 0.0;
    float slopeDen = max(abs(rd.y) + 9.0 * length(rd.xz), 0.12);
    // A height field is not an SDF. A global slope bound alone crawls at eye
    // height and exhausts the budget before reaching distant ground. Combine
    // safe clearance steps with bounded intervals, testing their midpoint and
    // bisecting crossings. This is a bounded approximation, not a guaranteed
    // intersection of every subpixel ridge in the 9 km view range.
    [loop] for (int i = 0; i < 320; ++i)
    {
        if (t > maxT) break;
        float3 p = ro + rd * t;
        float d = p.y - Terrain(p.xz);
        float epsilon = max(0.035, t * 0.00012);
        if (d > 0.0 && d <= epsilon) return t;
        if (d <= 0.0)
        {
            float lo = lastT, hi = t;
            [loop] for (int j = 0; j < 10; ++j)
            {
                float m = 0.5 * (lo + hi);
                float3 q = ro + rd * m;
                if (q.y > Terrain(q.xz)) lo = m; else hi = m;
            }
            return hi;
        }
        if(t>=maxT)break;
        float safeStep=min(d/slopeDen,240.0);
        float interval=min(max(1.0,t*0.025),80.0);
        float nextT=min(t+max(safeStep,interval),maxT);
        if(interval>safeStep)
        {
            float mid=0.5*(t+nextT);
            float3 mp=ro+rd*mid;
            if(mp.y-Terrain(mp.xz)<=max(0.035,mid*0.00012))
            {
                lastT=t;t=mid;continue;
            }
        }
        lastT=t;t=nextT;
    }
    return maxT + 1.0;
}

float3 TerrainNormal(float2 xz)
{
    float e = 3.5;
    float hx = Terrain(xz - float2(e, 0.0)) - Terrain(xz + float2(e, 0.0));
    float hz = Terrain(xz - float2(0.0, e)) - Terrain(xz + float2(0.0, e));
    return normalize(float3(hx, 2.0 * e, hz));
}

float TerrainShadow(float3 p, float3 sun)
{
    float visibility = 1.0, t = 9.0;
    [loop] for (int i = 0; i < 9; ++i)
    {
        float3 q = p + sun * t;
        float d = q.y - Terrain(q.xz);
        visibility = min(visibility, 7.5 * d / t);
        t *= 1.66;
    }
    return saturate(0.22 + 0.78 * visibility);
}

float3 SunDirection(float loopA)
{
    return CinematicSunDirection(loopA);
}

float3 Sky(float3 rd, float3 sun)
{
    // Analytic single-scattering approximation: wavelength-dependent Rayleigh
    // extinction, aerosol Mie phase and finite horizon optical air mass.
    // It is not a pre-rendered skydome or a full multiple-scattering solver.
    float elevation=max(rd.y,0.0);
    float zenith=acos(clamp(elevation,0.0,1.0))*180.0/PI;
    float airMass=1.0/(elevation+0.15*pow(max(0.1,93.885-zenith),-1.253));
    float3 rayleigh=float3(5.802,13.558,33.100)*1e-6;
    float3 mie=float3(3.8,3.8,3.8)*1e-6;
    float3 extinction=exp(-(rayleigh*8000.0+mie*1200.0)*airMass);
    float mu=clamp(dot(rd,sun),-1.0,1.0);
    float rayleighPhase=(3.0/(16.0*PI))*(1.0+mu*mu);
    float g=0.76;
    float miePhase=(1.0-g*g)/(4.0*PI*pow(max(0.01,1.0+g*g-2.0*g*mu),1.5));
    float3 scattering=(rayleigh*rayleighPhase+mie*miePhase)/(rayleigh+mie);
    float3 col=(1.0-extinction)*scattering*10.5;
    col+=float3(0.012,0.018,0.026)*extinction;
    float3 sunTransmission=exp(-(rayleigh*8000.0+mie*1200.0)/max(sun.y,0.08));
    float disc=smoothstep(cos(0.0055),cos(0.0045),mu);
    col+=sunTransmission*disc*16.0;
    col=lerp(col,float3(0.05,0.065,0.05),1.0-smoothstep(-0.24,-0.015,rd.y));
    return max(col,0.0);
}

float3 ShadeTerrain(float3 p, float3 rd, float3 sun, float loopA,float footprint)
{
    float3 n = TerrainNormal(p.xz);
    float slope = saturate(1.0 - n.y);
    float fine = FBM2(p.xz * 0.016);
    float strata = 0.88 + 0.12 * Noise2(float2(p.x*0.011+p.z*0.007,p.y*0.049)+Noise2(p.xz*0.004)*3.0);
    float3 grass = lerp(float3(0.045,0.063,0.026), float3(0.19,0.21,0.095), fine);
    float3 rock = lerp(float3(0.085,0.083,0.077), float3(0.31,0.29,0.26), fine) * strata;
    float snowLine=80.0*(Noise2(p.xz*0.009)-0.5)+30.0*(Noise2(p.xz*0.037)-0.5);
    // Snow collects on sheltered shelves and in gullies, leaving exposed ribs.
    float shelter=saturate(0.60+0.35*n.y-0.25*dot(n,float3(-.7,0,.7)));
    float snow = smoothstep(790.0,1100.0,p.y+snowLine)*(1.0-smoothstep(0.18,0.62,slope))*shelter;
    float melt = 0.5 + 0.5 * sin(loopA - 0.6);
    snow *= lerp(1.0, 0.72, melt);
    float3 albedo = lerp(grass, rock, smoothstep(0.08, 0.43, slope));
    albedo = lerp(albedo, float3(0.82,0.88,0.93), snow);
    float forest = smoothstep(0.58, 0.77, Noise2(p.xz * 0.021 + 12.0));
    forest *= (1.0-snow)*(1.0-smoothstep(0.24,0.52,slope))*(1.0-smoothstep(610.0,1000.0,p.y));
    float2 wind = WindField(p.xz, loopA);
    float grassSway = 0.94 + 0.06 * sin(dot(p.xz, wind) * 0.12 + loopA * 19.0);
    albedo = lerp(albedo * grassSway, float3(0.026,0.043,0.021), forest * 0.32);
    float riverCenter = ValleyCenter(p.z) - 34.0;
    float river = (1.0 - smoothstep(7.0,18.0,abs(p.x-riverCenter))) * (1.0-smoothstep(120.0,370.0,p.y));
    albedo = lerp(albedo, float3(0.020,0.16,0.19), river * 0.88);
    float2 tq = p.xz - TOWN_C;
    float road = (1.0-smoothstep(2.8,3.5,abs(tq.x)))
                 * (1.0-smoothstep(170.0,240.0,abs(tq.y)));
    float plaza=1.0-smoothstep(6.0,10.0,length((p.xz-float2(0,1755))/float2(0.78,1.0)));
    road=max(road,plaza);
    albedo = lerp(albedo, float3(0.13,0.12,0.105), road);
    float wet = exp(-pow((p.x-350.0)/36.0,2.0))*smoothstep(5000.0,5160.0,p.z)*(1.0-smoothstep(315.0,780.0,p.y));
    wet *= 0.72 + 0.28 * sin(loopA * 7.0 + p.y * 0.08);
    albedo = lerp(albedo, float3(0.025,0.035,0.040), wet * 0.72);
    float rough = lerp(0.88, 0.48, saturate(slope + river + wet));
    float fp=max(footprint,0.002)/max(abs(dot(n,-rd)),0.28);
    float rockMask=smoothstep(0.06,0.36,slope)*(1.0-snow);
    float3 gradient=0;
    float grain=0;
    // Metre-scale fractures down to fine grains. Subpixel bands fade to their
    // average; the field stays fixed in world space while the camera moves.
    [loop]for(int band=0;band<3;++band)
    {
        float f=0.32*exp2((float)band*2.0);
        float visible=DetailBand(fp,f);
        if(visible>0.001)
        {
            float4 sample=DetailNoise3(p*f+float3(9.1,17.3,band*13.7));
            float amplitude=lerp(0.024,0.24,rockMask)*exp2(-(float)band*1.7);
            gradient+=sample.yzw*(f*amplitude*visible);
            grain+=(sample.x-0.5)*visible*exp2(-(float)band)*0.36;
        }
    }
    albedo*=1.0+grain*lerp(0.7,1.5,rockMask);
    rough=clamp(rough+grain*0.15,0.35,0.98);
    // Wind combs the snow surface; the filtered normal carries small ripples.
    float snowPhase=dot(p.xz,float2(2.8,0.85));
    float snowBand=DetailBand(fp,0.48)*snow;
    gradient+=float3(2.8,0,0.85)*cos(snowPhase)*0.018*snowBand;
    // Actual grass microstructure is a surface relief approximation, not
    // millions of disconnected hard speckles. Wind changes its lean coherently.
    float grassBand=DetailBand(fp,5.0)*(1.0-snow)*(1.0-rockMask)*(1.0-road);
    float3 stalkWarp=DetailNoise2(p.xz*1.7+float2(8.3,21.7));
    float stalkPhase=dot(p.xz,float2(27.0,9.0))+stalkWarp.x*11.0+sin(loopA*19.0+p.z*0.3)*0.7;
    float2 stalkGradient=float2(27,9)+stalkWarp.yz*18.7;
    gradient+=float3(stalkGradient.x,0,stalkGradient.y)*cos(stalkPhase)*0.0022*grassBand;
    albedo*=1.0-0.065*grassBand*(0.5+0.5*sin(stalkPhase));
    // Rounded, staggered cobbles and dark recessed joints across the square.
    if(road>0.01)
    {
        float2 stoneUV=p.xz/float2(0.38,0.24);
        stoneUV.x+=0.5*fmod(floor(stoneUV.y),2.0);
        float2 cell=floor(stoneUV),s=frac(stoneUV)-0.5;
        float aa=max(fp/0.24,0.012),edge=max(abs(s.x),abs(s.y));
        float joint=smoothstep(0.43-aa,0.48+aa,edge);
        float detail=DetailBand(fp,3.0);
        float id=Hash21(cell+31.7);
        float3 stone=lerp(float3(0.20,0.19,0.17),float3(0.39,0.37,0.32),id);
        stone=lerp(stone,float3(0.055,0.050,0.039),joint*0.85);
        float3 pavement=lerp(float3(0.25,0.24,0.21),stone,detail);
        albedo=lerp(albedo,pavement,road);
        gradient+=float3(s.x/0.38,0,s.y/0.24)*(-0.09*detail*road*(1.0-joint));
        rough=lerp(rough,0.78,road);
    }
    n=DetailNormal(n,gradient);
    float shadow = TerrainShadow(p + n * 4.0, sun);
    float cloudShadow = lerp(0.66, 1.0, smoothstep(0.47,0.73,
        Noise2(p.xz*0.0012 + WindField(p.xz,loopA)*0.42)));
    float warm = 1.0 - smoothstep(0.10, 0.45, sun.y);
    float3 light = lerp(float3(1.0,0.95,0.82), float3(1.0,0.37,0.10), warm);
    return CinematicLightingShadow(p,n,-rd,albedo,rough,0.0,1.0,shadow*cloudShadow);
}

bool RayBox(float3 ro, float3 rd, float3 bmin, float3 bmax, out float tNear, out float tFar)
{
    // Preserve the sign for nearly parallel rays. Adding epsilon to a small
    // negative direction can turn it positive (or produce a zero divisor).
    float3 safeRd = lerp(-1.0, 1.0, step(0.0, rd)) * max(abs(rd), 0.00001);
    float3 a = (bmin - ro) / safeRd;
    float3 b = (bmax - ro) / safeRd;
    float3 lo = min(a, b), hi = max(a, b);
    tNear = max(lo.x, max(lo.y, lo.z));
    tFar = min(hi.x, min(hi.y, hi.z));
    return tFar >= max(tNear, 0.0);
}

// Six travelling sine-wave components (height field, not Gerstner displacement).
// Integer temporal phase counts make the
// 128-second visual and musical loops meet without a discontinuity.
float3 WaterField(float2 xz,float loopA)
{
    float h=0.0,dx=0.0,dz=0.0;
    float gustPhase = loopA*3.0 + dot(xz,float2(0.0010,0.0013));
    float gust = 0.12*sin(gustPhase);
    float2 gustGradient = 0.12*cos(gustPhase)*float2(0.0010,0.0013);
    [unroll]for(int i=0;i<6;++i)
    {
        float fi=(float)i;
        float2 dir=normalize(float2(cos(1.73*fi+0.4),sin(2.11*fi+0.8)));
        float k=0.012*exp2(fi*0.43),amp=1.15*exp2(-fi*0.63),speed=17.0+8.0*fi;
        float ph=dot(xz,dir)*k+loopA*speed+fi*1.9+gust;
        float2 gradient = dir*k + gustGradient;
        h+=amp*sin(ph);dx+=amp*gradient.x*cos(ph);dz+=amp*gradient.y*cos(ph);
    }
    return float3(h,dx,dz);
}

float LakeMask(float2 xz)
{
    return 1.0-smoothstep(0.92,1.0,length((xz-LAKE_C)/float2(900.0,610.0)));
}

float WaterHit(float3 ro,float3 rd,float maxT,float loopA)
{
    if(abs(rd.y)<0.0001)return maxT+1.0;
    float boundsNear,boundsFar;
    if(!RayBox(ro,rd,float3(LAKE_C.x-900.0,LAKE_Y-3.3,LAKE_C.y-610.0),
                     float3(LAKE_C.x+900.0,LAKE_Y+3.3,LAKE_C.y+610.0),boundsNear,boundsFar)
       || boundsNear>maxT)return maxT+1.0;
    // The sum of all six amplitudes is below 3.3 m. Bracket that entire slab
    // and use safeguarded Newton steps, including the horizontal derivative.
    // Fixed point division by rd.y diverged precisely at reflective grazing angles.
    float a=(LAKE_Y-3.3-ro.y)/rd.y,b=(LAKE_Y+3.3-ro.y)/rd.y;
    float lo=max(0.0,min(a,b)),hi=min(maxT,max(a,b));
    if(hi<=lo)return maxT+1.0;
    float3 plo=ro+rd*lo,phi=ro+rd*hi;
    float flo=plo.y-LAKE_Y-WaterField(plo.xz,loopA).x;
    float fhi=phi.y-LAKE_Y-WaterField(phi.xz,loopA).x;
    if(flo*fhi>0.0)return maxT+1.0;
    float t=clamp((LAKE_Y-ro.y)/rd.y,lo,hi);
    [loop]for(int i=0;i<10;++i)
    {
        float3 sampleP=ro+rd*t;
        float3 wave=WaterField(sampleP.xz,loopA);
        float f=sampleP.y-LAKE_Y-wave.x;
        if(abs(f)<0.015)break;
        if(f*flo>0.0){lo=t;flo=f;}else hi=t;
        float derivative=rd.y-dot(wave.yz,rd.xz);
        float next=t-f/(abs(derivative)>0.0001?derivative:0.0001);
        t=(next>lo&&next<hi)?next:0.5*(lo+hi);
    }
    float3 p=ro+rd*t;
    if(t>0.0&&t<maxT&&LakeMask(p.xz)>0.01&&Terrain(p.xz)<p.y-0.5)return t;
    return maxT+1.0;
}

float CloudDensity(float3 p,float loopA)
{
    float2 wind=WindField(p.xz,loopA)*0.38;
    float deform=0.08*sin(loopA*4.0+p.y*0.009)+0.06*cos(loopA*7.0+p.x*0.003);
    float n=FBM3(p*0.00118+float3(wind.x,deform,wind.y));
    float vertical=smoothstep(650.0,760.0,p.y)*(1.0-smoothstep(1030.0,1190.0,p.y));
    return smoothstep(0.54,0.77,n)*vertical;
}

float4 CloudLayer(float3 ro,float3 rd,float maxT,float3 sun,float loopA,float2 pixel)
{
    float tn,tf;
    if(abs(rd.y)<0.002){if(ro.y<650.0||ro.y>1190.0)return 0.0;tn=0.0;tf=maxT;}
    else{float a=(650.0-ro.y)/rd.y,b=(1190.0-ro.y)/rd.y;tn=max(0.0,min(a,b));tf=min(maxT,max(a,b));}
    if(tf<=tn)return 0.0;
    float span=tf-tn,jitter=Hash21(pixel+floor(G.z*24.0)*0.37);
    float3 accum=0.0;float trans=1.0;
    [loop]for(int i=0;i<6;++i)
    {
        float t=tn+span*((i+jitter)/6.0);float3 p=ro+rd*t;float den=CloudDensity(p,loopA);
        // Beer-Lambert optical depth integrates density times EACH step length.
        float alpha=1.0-exp(-den*(span/6.0)*0.00105);
        float light=saturate(0.35+0.65*dot(sun,float3(0,1,0)));
        float3 cc=lerp(float3(0.25,0.29,0.34),float3(1.0,0.91,0.75),light);
        cc+=pow(saturate(dot(rd,sun)),12.0)*float3(0.38,0.20,0.07);
        accum+=trans*alpha*cc;trans*=1.0-alpha;
    }
    return float4(accum,1.0-trans);
}

float3 SkyWithCloudReflection(float3 rd,float3 p,float3 sun,float loopA)
{
    float3 col=Sky(rd,sun);
    if(rd.y>0.025)
    {
        float t=(900.0-p.y)/rd.y;
        float2 wind=WindField(p.xz,loopA)*0.38;
        float n=FBM2((p.xz+rd.xz*t)*0.0012+wind);
        float cloud=smoothstep(0.61,0.81,n);
        col=lerp(col,float3(0.78,0.82,0.84),cloud*0.58);
    }
    return col;
}

float3 ShadeWater(float3 p,float3 rd,float3 sun,float loopA,float footprint)
{
    float3 w=WaterField(p.xz,loopA);
    float2 rippleGradient=0;
    float unresolved=0;
    float fp=footprint/max(abs(rd.y),0.08);
    // Short wind waves modulate the true water normal rather than translating
    // a reflection image. All phase counts are integral over the128s loop.
    [loop]for(int band=0;band<4;++band)
    {
        float b=(float)band,k=0.21*exp2(b*0.91),amplitude=0.045*exp2(-1.25*b);
        float2 direction=normalize(float2(cos(b*1.67+0.23),sin(b*1.37+0.51)));
        float3 warp=DetailNoise2(p.xz*(k*0.23)+float2(b*17.1,9.7));
        float phase=dot(p.xz,direction)*k+warp.x*5.0+loopA*(67.0+23.0*b);
        float2 phaseGradient=direction*k+warp.yz*(k*1.15);
        // Reflection changes much faster than the water height. Filter the
        // short-wave slope conservatively, including the grazing footprint,
        // instead of reflecting sharp ridges through an undersampled grating.
        float visible=DetailBand(fp,k*3.5/TAU);
        rippleGradient+=phaseGradient*(amplitude*cos(phase)*visible);
        unresolved+=amplitude*k*(1.0-visible);
    }
    float3 n=normalize(float3(-w.y-rippleGradient.x,1.0,-w.z-rippleGradient.y));
    float3 reflectedRay=reflect(rd,n);
    float3 reflection=SkyWithCloudReflection(reflectedRay,p,sun,loopA);
    CameraFrame camera;
    camera.origin=CinematicFrame[0].xyz;camera.lens=CinematicFrame[0].w;
    camera.forward=CinematicFrame[1].xyz;camera.right=CinematicFrame[2].xyz;camera.up=CinematicFrame[3].xyz;
    CameraFrame mirrored=MirrorLakeCamera(camera);
    float3 planarDirection=normalize(float3(p.x,LAKE_Y,p.z)-mirrored.origin);
    planarDirection=normalize(planarDirection+reflectedRay-reflect(rd,float3(0,1,0)));
    float reflectionZ;
    float2 reflectionUV=ProjectCamera(mirrored,mirrored.origin+planarDirection*1000.0,G.x/G.y,reflectionZ);
    float reflectionWeight=0;
    if(PassMode.y>0.5&&reflectionZ>0.0)
    {
        uint rw,rh;PlanarReflection.GetDimensions(rw,rh);
        reflectionUV-=TemporalJitter(((int)G.w)&7)/float2(rw,rh);
        float border=min(min(reflectionUV.x,reflectionUV.y),min(1.0-reflectionUV.x,1.0-reflectionUV.y));
        reflectionWeight=smoothstep(0.0,0.025,border);
        // Distorted lookups can cross into the part of the mirrored image
        // whose rays never reach the clipping plane. Blend to the real
        // surface-origin trace there instead of showing a white horizon seam.
        float planeT=(LAKE_Y+0.03-mirrored.origin.y)/max(planarDirection.y,0.00001);
        reflectionWeight*=step(0.00001,planarDirection.y)*(1.0-smoothstep(MAX_DIST*.85,MAX_DIST,planeT));
    }
    // Water must reflect actual geometry, including the surrounding mountains.
    // Restrict this extra trace to the hemisphere that can reach the horizon.
    if(reflectedRay.y<0.65&&reflectionWeight<0.999)
    {
        float3 reflectionOrigin=p+n*0.35;
        float rt=TraceTerrain(reflectionOrigin,reflectedRay,4200.0);
        if(rt<=4200.0)
        {
            float3 rp=reflectionOrigin+reflectedRay*rt;
            // Reflection LOD avoids another full shadow march per water pixel.
            float3 rn=TerrainNormal(rp.xz);
            float rock=smoothstep(0.08,0.43,1.0-rn.y);
            float snow=smoothstep(790.0,1100.0,rp.y)*(1.0-smoothstep(0.18,0.62,1.0-rn.y));
            float3 ra=lerp(float3(0.06,0.09,0.035),float3(0.25,0.23,0.20),rock);
            ra=lerp(ra,float3(0.82,0.88,0.93),snow);
            float3 reflectedTerrain=ra*(0.22+2.4*saturate(dot(rn,sun))*smoothstep(-0.06,0.16,sun.y));
            float aerial=1.0-exp(-rt*0.00018);
            reflection=lerp(reflectedTerrain,Sky(reflectedRay,sun),aerial);
        }
    }
    if(reflectionWeight>0.001)
    {
        uint rw,rh;PlanarReflection.GetDimensions(rw,rh);
        float2 texel=0.45/float2(rw,rh);
        float3 planar=PlanarReflection.SampleLevel(CinematicSampler,reflectionUV+texel,0).rgb;
        planar+=PlanarReflection.SampleLevel(CinematicSampler,reflectionUV-texel,0).rgb;
        reflection=lerp(reflection,planar*0.5,reflectionWeight);
    }
    float depth=max(0.0,p.y-Terrain(p.xz));float shallow=exp(-depth*0.055);
    float3 refractedRay=refract(rd,n,1.0/1.333);
    float opticalDepth=depth/max(abs(refractedRay.y),0.12);
    float3 bed=float3(.23,.25,.18);
    if(depth<26.0)
    {
        float bt=TraceTerrain(p+n*.04,refractedRay,220.0);
        if(bt<220.0)
        {
            float3 bp=p+n*.04+refractedRay*bt;
            float sediment=Noise2(bp.xz*.42)*.65+Noise2(bp.xz*1.7)*.35;
            bed=lerp(float3(.14,.16,.12),float3(.37,.39,.29),sediment);
            bed*=.35+.85*saturate(dot(TerrainNormal(bp.xz),sun));
            opticalDepth=bt;
        }
    }
    float3 transmission=exp(-opticalDepth*float3(.12,.047,.024));
    float3 refraction=bed*transmission+float3(.008,.067,.073)*(1.0-transmission);
    float fresnel=0.02037+0.97963*pow(1.0-saturate(dot(n,-rd)),5.0);
    float3 col=lerp(refraction,reflection,fresnel);
    float specPower=lerp(220.0,90.0,saturate(unresolved*7.0));
    float spec=pow(saturate(dot(reflect(-sun,n),-rd)),specPower);
    col+=spec*float3(4.0,3.2,2.1)*smoothstep(-0.06,0.16,sun.y);
    float shoreNoise=Noise2(p.xz*0.18+WindField(p.xz,loopA)*0.5);
    float foam=(1.0-smoothstep(0.18,1.1,depth))*smoothstep(0.61,0.80,shoreNoise);
    float streakPhase=dot(p.xz,float2(0.91,0.38))+loopA*29.0;
    foam*=0.72+0.28*sin(streakPhase)*DetailBand(fp,0.16);
    return lerp(col,float3(0.63,0.69,0.65),foam*0.32);
}

float WaterfallHit(float3 ro,float3 rd,float maxT,float loopA)
{
    // The escarpment is sloped. A vertical card detached its upper stream and
    // buried its lower half. Trace a thin cascade following the actual terrain.
    float tn,tf;
    if(!RayBox(ro,rd,float3(320.0,295.0,5010.0),float3(380.0,820.0,5240.0),tn,tf))return maxT+1.0;
    float t=max(0.0,tn),endT=min(tf,maxT);
    float slopeDen=max(abs(rd.y)+5.35*length(rd.xz),0.12);
    [loop]for(int i=0;i<96;++i)
    {
        if(t>=endT)break;
        float3 q=ro+rd*t;
        float film=0.80+0.25*sin(q.x*0.072+loopA*31.0)+0.15*sin(q.z*0.041+loopA*43.0);
        float d=q.y-Terrain(q.xz)-film;
        if(d<max(0.035,t*0.00010))
        {
            float width=14.0+8.0*(1.0-smoothstep(330.0,760.0,q.y));
            if(abs(q.x-350.0)<width)return t;
            break;
        }
        t+=min(d/slopeDen,28.0);
    }
    return maxT+1.0;
}

float FallingNoise(float2 p)
{
    float2 cell=floor(p),f=frac(p);f=f*f*(3.0-2.0*f);
    float y0=fmod(fmod(cell.y,64.0)+64.0,64.0),y1=fmod(y0+1.0,64.0);
    return lerp(lerp(Hash21(float2(cell.x,y0)),Hash21(float2(cell.x+1.0,y0)),f.x),
        lerp(Hash21(float2(cell.x,y1)),Hash21(float2(cell.x+1.0,y1)),f.x),f.y);
}

float4 ShadeWaterfall(float3 p,float3 rd,float3 sun,float loopA)
{
    // Wrapped noise advection gives the water irregular falling parcels, rather
    // than bright sine stripes painted across a flat blue ribbon.
    float phase=loopA*19.0;
    float2 turbulence=float2(Noise2(float2(p.x*.025,p.y*.013)+float2(cos(phase),sin(phase))),
        Noise2(float2(p.x*.041,p.y*.009)+float2(sin(phase),cos(phase))*1.7));
    float travel=loopA*(64.0/TAU);
    float flow=FallingNoise(float2(p.x*.19+turbulence.x*1.4,p.y*.023+travel*2.0));
    float small=FallingNoise(float2(p.x*.67+turbulence.y,p.y*.083+travel*7.0));
    float aeration=smoothstep(.29,.72,flow*.75+small*.25);
    float dhdx=0.25*0.072*cos(p.x*0.072+loopA*31.0),dhdz=0.15*0.041*cos(p.z*0.041+loopA*43.0);
    float3 baseN=TerrainNormal(p.xz);
    float3 n=normalize(float3(baseN.x/max(baseN.y,0.05)-dhdx,1.0,baseN.z/max(baseN.y,0.05)-dhdz));
    if(dot(n,-rd)<0.0)n=-n;
    float spec=pow(saturate(dot(reflect(-sun,n),-rd)),90.0);
    float3 col=lerp(float3(.14,.20,.21),float3(.72,.78,.77),aeration)+spec*float3(1.2,1.1,.9);
    float edge=smoothstep(5010.0,5026.0,p.z)*(1.0-smoothstep(5218.0,5240.0,p.z));
    float width=14.0+8.0*(1.0-smoothstep(330.0,760.0,p.y));
    edge*=1.0-smoothstep(width-4.0,width,abs(p.x-350.0)+turbulence.x*3.0);
    return float4(col,(.40+.49*aeration)*edge);
}

float4 SprayLayer(float3 ro,float3 rd,float maxT,float loopA,float2 pixel)
{
    float3 center=float3(350.0,Terrain(float2(350.0,5020.0))+12.0,5015.0),radius=float3(90.0,65.0,90.0);
    float3 o=(ro-center)/radius,d=rd/radius;float A=dot(d,d),B=dot(o,d),C=dot(o,o)-1.0,H=B*B-A*C;
    if(H<=0.0)return 0.0;H=sqrt(H);float tn=max(0.0,(-B-H)/A),tf=min(maxT,(-B+H)/A);
    if(tf<=tn)return 0.0;float span=tf-tn,jitter=Hash21(pixel+91.0),density=0.0;
    [loop]for(int i=0;i<5;++i)
    {
        float t=tn+span*((i+jitter)/5.0);float3 p=ro+rd*t,q=(p-center)/radius;
        float2 wind=WindField(p.xz,loopA);
        float n=FBM3(p*0.013+float3(wind.x,sin(loopA*5.0),wind.y));
        density+=exp(-dot(q,q)*2.2)*smoothstep(0.48,0.78,n);
    }
    float alpha=1.0-exp(-density*(span/5.0)*0.0042);return float4(float3(0.60,0.70,0.75)*alpha,alpha);
}

float3 ApplyFog(float3 col,float3 rd,float dist,float3 p,float3 sun)
{
    return CinematicFog(col,p);
}


struct WorldOutput
{
    float4 color:SV_Target;
    float depth:SV_Depth;
};

WorldOutput P(VSOut input)
{
    float loopA=fmod(G.z,128.0)*(TAU/128.0);
    CameraFrame cam=CurrentFrameCamera(input);
    float3 ro=cam.origin;
    float2 sampleUV=input.uv+TemporalJitter(((int)G.w)&7)/G.xy;
    float3 rd=CameraRay(cam,sampleUV,G.x/G.y),sun=SunDirection(loopA);

    float rayStart=0.0;
    bool validTerrainRay=true;
    if(PassMode.x>0.5)
    {
        // A mirrored camera can lie below the terrain. Begin at the lake
        // clipping plane so it never sees the underside of the height field.
        validTerrainRay=rd.y>0.00001;
        rayStart=validTerrainRay?max(0.0,(LAKE_Y+0.03-ro.y)/rd.y):MAX_DIST;
        validTerrainRay=validTerrainRay&&rayStart<MAX_DIST;
    }
    float terrainT=validTerrainRay?rayStart+TraceTerrain(ro+rd*rayStart,rd,MAX_DIST-rayStart):MAX_DIST+1.0;
    float solidT=terrainT;
    int surface=terrainT<=MAX_DIST?1:0;
    float waterT=PassMode.x>0.5?MAX_DIST+1.0:WaterHit(ro,rd,solidT,loopA);
    if(waterT<solidT){solidT=waterT;surface=3;}
    // Shade the visible surface only. Detailed terrain behind windows/water
    // need not consume a second material and shadow evaluation.
    float3 hitP=ro+rd*min(solidT,MAX_DIST),col;
    float footprint=2.0*min(solidT,MAX_DIST)/(G.y*cam.lens),reactive=0.0;
    if(surface==1)col=ShadeTerrain(hitP,rd,sun,loopA,footprint);
    else if(surface==3){col=ShadeWater(hitP,rd,sun,loopA,footprint);reactive=1.0;}
    else col=Sky(rd,sun);
    if(solidT<=MAX_DIST)col=ApplyFog(col,rd,solidT,hitP,sun);

    float3 effectsOrigin=ro+rd*rayStart;
    float waterfallT=validTerrainRay?rayStart+WaterfallHit(effectsOrigin,rd,max(0.0,solidT-rayStart),loopA):MAX_DIST+1.0;
    if(waterfallT<solidT)
    {
        float3 wp=ro+rd*waterfallT;float4 fall=ShadeWaterfall(wp,rd,sun,loopA);
        col=lerp(col,ApplyFog(fall.rgb,rd,waterfallT,wp,sun),fall.a);
        solidT=min(solidT,waterfallT);
        reactive=1.0;
    }

    // All participating media stop at the nearest procedural surface.
    float depthLimit=min(solidT,MAX_DIST);
    float4 clouds=validTerrainRay?CloudLayer(effectsOrigin,rd,max(0.0,depthLimit-rayStart),sun,loopA,input.pos.xy):0;
    col=clouds.rgb+col*(1.0-clouds.a);
    // The old smoke grid does not match the new geometry and is disabled.
    float4 smoke=0;
    col=smoke.rgb+col*(1.0-smoke.a);
    float4 spray=validTerrainRay?SprayLayer(effectsOrigin,rd,max(0.0,depthLimit-rayStart),loopA,input.pos.xy):0;
    col=spray.rgb+col*(1.0-spray.a);
    reactive=max(reactive,step(0.015,max(clouds.a,max(smoke.a,spray.a))));

    // Linear HDR leaves exposure, tonemapping, gamma and grain to the temporal
    // reconstruction pass. Alpha carries signed logarithmic depth; moving or
    // deforming pixels are negative so history is rejected without ghosting.
    float logDepth=log2(1.0+min(solidT,MAX_DIST)*DEPTH_K)/log2(1.0+MAX_DIST*DEPTH_K);
    logDepth=max(logDepth,0.0001);
    WorldOutput output;
    output.color=float4(max(col,0.0),reactive>0.5?-logDepth:logDepth);
    float viewZ=max(0.1,min(solidT,MAX_DIST)*dot(rd,cam.forward));
    output.depth=solidT>=MAX_DIST?1.0:saturate((MAX_DIST/(MAX_DIST-0.1))*(1.0-0.1/viewZ));
    return output;
}
