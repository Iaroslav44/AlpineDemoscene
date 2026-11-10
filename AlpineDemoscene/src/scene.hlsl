// Alpine Dreaming - a 100% runtime procedural Direct3D 11 demoscene.
// Terrain fields and mesh geometry are generated at runtime. No image plates,
// prebuilt meshes, photographic textures or offline scene assets are loaded.

#include "frame_vertex.hlsli"
#include "detail_common.hlsli"
#include "cinematic_lighting.hlsli"
#include "material_common.hlsli"

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

// Tetrahedral gradient noise with an analytic derivative. Unlike stacked
// 2D slices it has no horizontal lattice planes on a tall exposed cliff.
float4 RockNoise(float3 p)
{
    float3 cell=floor(p+dot(p,float3(1.0/3.0,1.0/3.0,1.0/3.0)));
    float3 x0=p-cell+dot(cell,float3(1.0/6.0,1.0/6.0,1.0/6.0));
    float3 rank=step(x0.yzx,x0.xyz),inverse=1.0-rank;
    float3 i1=min(rank,inverse.zxy),i2=max(rank,inverse.zxy);
    float value=0;float3 gradient=0;
    [unroll]for(int corner=0;corner<4;++corner)
    {
        float3 offset=corner==0?float3(0,0,0):(corner==1?i1:(corner==2?i2:float3(1,1,1)));
        float3 c=cell+offset,x=x0-offset+(float)corner/6.0;
        float2 seed=c.xy+c.z*float2(19.19,73.13);
        float3 g=float3(Hash21(seed),Hash21(seed+31.7),Hash21(seed+83.1))*2.0-1.0;
        g*=rsqrt(max(dot(g,g),.001));
        float t=max(.6-dot(x,x),0),t2=t*t,t3=t2*t,t4=t2*t2,d=dot(g,x);
        value+=t4*d;gradient+=t4*g-8.0*t3*d*x;
    }
    return float4(.5+21.0*value,21.0*gradient);
}

// Every animated layer samples this coherent periodic wind field.
float2 WindField(float2 xz, float loopA)
{
    float gust = sin(loopA * 3.0 + xz.x * 0.0021 + xz.y * 0.0013);
    float curl = sin(loopA * 5.0 - xz.x * 0.0012 + xz.y * 0.0023);
    return float2(0.72 + 0.28 * gust, 0.20 + 0.30 * curl);
}


#include "terrain_trace.hlsli"

float3 TerrainNormal(float2 xz)
{
    float e = 3.5;
    float hx = Terrain(xz - float2(e, 0.0)) - Terrain(xz + float2(e, 0.0));
    float hz = Terrain(xz - float2(0.0, e)) - Terrain(xz + float2(0.0, e));
    return normalize(float3(hx, 2.0 * e, hz));
}

float TerrainShadow(float3 p, float3 sun)
{
    // The same conservative hierarchy is used for sun visibility. Sparse
    // samples leaked light through intervening mountain ridges.
    return TraceTerrain(p,sun,MAX_DIST)<=MAX_DIST?0.0:1.0;
}

float3 SunDirection(float loopA)
{
    return CinematicSunDirection(loopA);
}

float3 Sky(float3 rd, float3 sun)
{
    float3 sky=AtmosphereEnvironment(rd);
    float mu=saturate(dot(rd,sun));
    float disc=smoothstep(cos(.0056),cos(.0044),dot(rd,sun));
    float aureole=pow(mu,420.0)*1.35+pow(mu,32.0)*.11;
    // The direct water GGX lobe integrates the solar source separately.
    // Keep the visible disc and circumsolar corona out of its reflection cache.
    return sky+CinematicSunColor()*(disc*16.0+aureole)*(PassMode.x>.5?0.0:1.0);
}

#include "terrain_material.hlsli"

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

// The coarse surface is a numerical shallow-water solution, shared with
// diagnostics. Short capillary/gravity waves below grid scale affect shading.
float3 WaterField(float2 xz,float loopA)
{
    return PhysicalWaterField(xz);
}

float LakeMask(float2 xz)
{
    float lake=1.0-smoothstep(1.02,1.06,length((xz-LAKE_C)/float2(900.0,610.0)));
    float channel=(1.0-smoothstep(45.0,55.0,abs(xz.x-350.0)))
        *smoothstep(4610.0,4630.0,xz.y)*(1.0-smoothstep(4820.0,4845.0,xz.y));
    return max(lake,channel);
}

float WaterHit(float3 ro,float3 rd,float maxT,float loopA)
{
    if(abs(rd.y)<0.0001)return maxT+1.0;
    float boundsNear,boundsFar;
    if(!RayBox(ro,rd,float3(LAKE_C.x-960.0,LAKE_Y-3.3,LAKE_C.y-650.0),
                     float3(LAKE_C.x+960.0,LAKE_Y+3.3,LAKE_C.y+650.0),boundsNear,boundsFar)
       || boundsNear>maxT)return maxT+1.0;
    // Bracket the validated wave envelope and use safeguarded Newton steps,
    // including the horizontal derivative of the simulated surface.
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

#include "cloud_render.hlsli"

float3 WaterShadingNormal(float3 p,float3 rd,float loopA,float footprint,out float unresolved)
{
    float3 w=WaterField(p.xz,loopA);
    float2 rippleGradient=0;
    unresolved=0;
    float fp=footprint/max(abs(rd.y),0.08);
    // Sub-grid waves use the gravity/capillary dispersion relation in SI units:
    // omega?=(g*k+surfaceTension/density*k?)*tanh(k*depth).
    float localDepth=max(.1,p.y-Terrain(p.xz));
    [loop]for(int band=0;band<8;++band)
    {
        float b=(float)band,k=0.45*exp2(b*.9),amplitude=.014*exp2(-1.1*b);
        float2 direction=normalize(float2(cos(b*1.67+0.23),sin(b*1.37+0.51)));
        // FXC lowers tanh to exponentials: large positive k*depth can become
        // inf/inf on SM5 hardware. This equivalent positive-domain expression
        // stays bounded, including the deep-water limit of exactly1.
        float decay=exp(-2.0*k*localDepth);
        float finiteDepth=(1.0-decay)/(1.0+decay);
        float omega=sqrt((9.81*k+.000074*k*k*k)*finiteDepth);
        float phase=dot(p.xz,direction)*k-FlightTime(G.z)*omega+b*2.31;
        float2 phaseGradient=direction*k;
        // Reflection changes much faster than the water height. Filter the
        // short-wave slope conservatively, including the grazing footprint,
        // instead of reflecting sharp ridges through an undersampled grating.
        float visible=DetailBand(fp,k*3.5/TAU);
        rippleGradient+=phaseGradient*(amplitude*cos(phase)*visible);
        // Unresolved slopes contribute VARIANCE, not linearly accumulated
        // amplitude. Filtering must broaden the microfacet lobe while retaining
        // its integrated energy instead of making distant water perfectly flat.
        unresolved+=.5*amplitude*amplitude*k*k*(1.0-visible*visible);
    }
    float3 n=normalize(float3(-w.y-rippleGradient.x,1.0,-w.z-rippleGradient.y));
    return n;
}

float WaterFresnel(float cosine)
{
    // Unpolarized air/water dielectric Fresnel, n=1.333. Schlick noticeably
    // overestimated reflection in the middle angles used by the lake camera.
    float c=saturate(cosine),eta=1.333;
    float ct=sqrt(max(0.0,1.0-(1.0-c*c)/(eta*eta)));
    float rs=(c-eta*ct)/max(c+eta*ct,1e-6);
    float rp=(eta*c-ct)/max(eta*c+ct,1e-6);
    return .5*(rs*rs+rp*rp);
}

float3 WaterSunReflection(float3 p,float3 n,float3 v,float3 sun,float slopeVariance)
{
    float3 halfVector=sun+v;
    halfVector*=rsqrt(max(dot(halfVector,halfVector),1e-8));
    float nl=saturate(dot(n,sun)),nv=max(.001,saturate(dot(n,v)));
    float nh=saturate(dot(n,halfVector)),vh=saturate(dot(v,halfVector));
    // Beckmann-like slope variance is mapped to a GGX lobe. A finite solar
    // disc and analytic pixel-footprint variance bound the sharp lobe. Avoid
    // ddx/ddy inside the water-only branch: non-water quad neighbours at a
    // shoreline do not define the same normal and make derivatives undefined.
    float alpha2=clamp(.00008+slopeVariance,.00008,.12);
    float denominator=nh*nh*(alpha2-1.0)+1.0;
    float distribution=alpha2/(PI*denominator*denominator);
    float visibility=.5/max(nl*sqrt(nv*nv*(1.0-alpha2)+alpha2)
                         +nv*sqrt(nl*nl*(1.0-alpha2)+alpha2),1e-5);
    float spec=distribution*visibility*WaterFresnel(vh)*nl;
    float shadow=1.0;
    [branch]if(spec>.004)
        shadow=TerrainShadow(p+float3(0,.12,0),sun)*CinematicShadow(p,n);
    return CinematicSunColorAt(p.y)*(CinematicFrame[8].w*spec*shadow);
}

float3 ShadeWater(float3 p,float3 rd,float3 sun,float loopA,float footprint)
{
    float unresolved;
    float3 n=WaterShadingNormal(p,rd,loopA,footprint,unresolved);
    float fp=footprint/max(abs(rd.y),0.08);
    float3 reflectedRay=reflect(rd,n);
    float3 reflection=0;
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
        reflectionWeight=smoothstep(0.001,0.014,border);
        // Distorted lookups can cross into the part of the mirrored image
        // whose rays never reach the clipping plane. Blend to the real
        // surface-origin trace there instead of showing a white horizon seam.
        float planeT=(LAKE_Y+0.03-mirrored.origin.y)/max(planarDirection.y,0.00001);
        reflectionWeight*=step(0.00001,planarDirection.y)*(1.0-smoothstep(MAX_DIST*.85,MAX_DIST,planeT));
    }
    if(reflectionWeight<.999)
        reflection=SkyWithCloudReflection(reflectedRay,p,sun,loopA);
    // Water must reflect actual geometry, including the surrounding mountains.
    // Match ShadeTerrain's radiometric balance so edge fallback is seamless.
    if(reflectedRay.y<0.65&&reflectionWeight<0.999)
    {
        float3 reflectionOrigin=p+n*0.35;
        float rt=TraceTerrain(reflectionOrigin,reflectedRay,4200.0);
        if(rt<=4200.0)
        {
            float3 rp=reflectionOrigin+reflectedRay*rt;
            float3 rn=TerrainNormal(rp.xz);
            float rock=smoothstep(0.10,0.42,1.0-rn.y);
            float forestBelt=smoothstep(152.0,210.0,rp.y)*(1.0-smoothstep(1380.0,1750.0,rp.y))*(1.0-rock);
            float snow=smoothstep(1180.0,1540.0,rp.y)*(1.0-smoothstep(0.38,0.74,1.0-rn.y));
            float3 ra=lerp(float3(0.045,0.062,0.026),float3(0.016,0.035,0.018),forestBelt*0.85);
            ra=lerp(ra,float3(0.068,0.070,0.074),rock);
            ra=lerp(ra,float3(0.87,0.90,0.935),snow);
            float rShadow=TerrainShadow(rp+rn*2.2,sun);
            float3 rDirect=CinematicSunColorAt(rp.y)*(CinematicFrame[8].w*rShadow*saturate(dot(rn,sun))/PI);
            float3 reflectedTerrain=ra*(rDirect+AtmosphereDiffuse(rn));
            reflection=CinematicFog(reflectedTerrain,rp);
        }
    }
    if(reflectionWeight>0.001)
    {
        uint rw,rh;PlanarReflection.GetDimensions(rw,rh);
        float2 minUV=float2(0.5,0.5)/float2(rw,rh),maxUV=1.0-minUV;
        float2 texel=(.45+min(1.25,12.0*sqrt(unresolved)))/float2(rw,rh);
        float2 cUV=clamp(reflectionUV,minUV,maxUV);
        float3 planar=PlanarReflection.SampleLevel(CinematicSampler,cUV,0).rgb*.4;
        planar+=PlanarReflection.SampleLevel(CinematicSampler,clamp(reflectionUV+float2(texel.x,0),minUV,maxUV),0).rgb*.15;
        planar+=PlanarReflection.SampleLevel(CinematicSampler,clamp(reflectionUV-float2(texel.x,0),minUV,maxUV),0).rgb*.15;
        planar+=PlanarReflection.SampleLevel(CinematicSampler,clamp(reflectionUV+float2(0,texel.y),minUV,maxUV),0).rgb*.15;
        planar+=PlanarReflection.SampleLevel(CinematicSampler,clamp(reflectionUV-float2(0,texel.y),minUV,maxUV),0).rgb*.15;
        reflection=lerp(reflection,planar,reflectionWeight);
    }
    float depth=max(0.0,p.y-Terrain(p.xz));
    float3 refractedRay=refract(rd,n,1.0/1.333);
    float opticalDepth=depth/max(abs(refractedRay.y),0.12);
    float3 waterIrradiance=AtmosphereDiffuse(float3(0,1,0))+CinematicSunColorAt(p.y)*(CinematicFrame[8].w*max(0.0,sun.y)/PI);
    float3 bed=float3(.16,.17,.14)*waterIrradiance;
    if(depth<32.0)
    {
        float bt=TraceTerrain(p+n*.04,refractedRay,220.0);
        if(bt<220.0)
        {
            float3 bp=p+n*.04+refractedRay*bt;
            RuntimeMaterial gravel=SampleNaturalMaterial(7,bp.xz*.7);
            float3 bn=normalize(TerrainNormal(bp.xz)+float3(gravel.normal.x,0,gravel.normal.y)*.6);
            float3 bedDirect=CinematicSunColorAt(bp.y)*(CinematicFrame[8].w*saturate(dot(bn,sun))/PI);
            float3 resolvedBed=gravel.albedo*(AtmosphereDiffuse(bn)+bedDirect);
            resolvedBed*=exp(-depth*float3(.13,.046,.026)/max(sun.y,.14));
            // Fade the expensive bed trace into the deep-water approximation
            // continuously; a hard 26m switch drew a ring across the lake.
            float bedWeight=1.0-smoothstep(20.0,32.0,depth);
            bed=lerp(bed,resolvedBed,bedWeight);
            opticalDepth=lerp(opticalDepth,bt,bedWeight);
        }
    }
    // Glacial rock-flour hydro-optics: strong red absorption + turquoise-emerald
    // Mie backscattering modulated physically by surface sky and solar irradiance.
    float3 transmission=exp(-opticalDepth*float3(.145,.044,.030));
    float3 scatterAlbedo=float3(.012,.092,.096);
    float3 inscatter=scatterAlbedo*waterIrradiance*(.72+.28*saturate(dot(-rd,sun)));
    float3 refraction=bed*transmission+inscatter*(1.0-transmission);
    float fresnel=WaterFresnel(dot(n,-rd));
    float3 col=lerp(refraction,reflection,fresnel);
    col+=WaterSunReflection(p,n,-rd,sun,unresolved);
    float shoreNoise=Noise2(p.xz*0.18+WindField(p.xz,loopA)*0.5);
    float foam=(1.0-smoothstep(0.16,0.95,depth))*smoothstep(0.62,0.82,shoreNoise);
    float streakPhase=dot(p.xz,float2(0.91,0.38))+loopA*29.0;
    foam*=0.72+0.28*sin(streakPhase)*DetailBand(fp,0.16);
    foam=max(foam,PhysicalWaterFoam(p.xz));
    float3 foamLight=float3(.76,.80,.82)*(AtmosphereDiffuse(float3(0,1,0))+CinematicSunColorAt(p.y)*(CinematicFrame[8].w*max(0.0,sun.y)/PI));
    return lerp(col,foamLight,foam*0.30);
}

// Ballistic jet: horizontal launch velocity 15m/s and gravity 9.81m/s^2.
// The flow follows a trajectory through space, not the shape of the cliff.
float3 WaterfallSource()
{
    return float3(350.0,Terrain(float2(350.0,4915.0))+1.2,4915.0);
}
float3 WaterfallTrajectory(float age)
{
    float3 source=WaterfallSource();
    return source+float3(0.0,-4.905*age*age,-15.0*age);
}
float4 WaterfallVolume(float3 ro,float3 rd,float maxT,float seconds,out float firstDepth)
{
    float3 source=WaterfallSource();
    float fallAge=sqrt(max(0.0,2.0*(source.y-LAKE_Y)/9.81));
    float tn,tf;firstDepth=maxT+1.0;
    if(!RayBox(ro,rd,float3(306.0,LAKE_Y,source.z-15.0*fallAge-35.0),
        float3(394.0,source.y+2.0,source.z+4.0),tn,tf))return 0;
    tn=max(0.0,tn);tf=min(tf,maxT);
    if(tf<=tn)return 0;
    float ds=(tf-tn)/48.0,trans=1.0;
    float3 result=0;
    float3 sun=CinematicFrame[8].xyz;
    float sunVis=.28+.72*TerrainShadow(float3(source.x,lerp(LAKE_Y,source.y,.58),source.z-38.0),sun);
    float3 skyFill=AtmosphereDiffuse(normalize(float3(0,.45,-1.0)));
    float3 sunFill=CinematicSunColorAt(lerp(LAKE_Y,source.y,.5))*CinematicFrame[8].w*sunVis;
    [loop]for(int i=0;i<48;++i)
    {
        float t=tn+(i+.5)*ds;float3 p=ro+rd*t;
        float age=sqrt(max(0.0,2.0*(source.y-p.y)/9.81));
        float centreZ=source.z-15.0*age;
        float width=6.2+age*.58,thickness=1.2+age*.34;
        float parcelAge=age-seconds;
        float turbulence=smoothstep(.25,3.8,age);
        float centreX=source.x+turbulence*(1.05*sin(parcelAge*2.4)+.62*sin(parcelAge*5.1));
        float2 q=float2((p.x-centreX)/width,(p.z-centreZ)/thickness);
        // Secondary side-ledge cascades flanking the main cataract core.
        float2 qSideL=float2((p.x-(source.x-9.5-age*.45))/(2.3+age*.28),(p.z-(centreZ+1.6))/(0.85+age*.22));
        float2 qSideR=float2((p.x-(source.x+8.8+age*.40))/(2.0+age*.25),(p.z-(centreZ+2.1))/(0.80+age*.20));
        float plume=exp(-dot(q,q)*1.8)+.34*exp(-dot(qSideL,qSideL)*2.1)+.28*exp(-dot(qSideR,qSideR)*2.1);
        float parcel=Noise3(float3(p.x*.38,p.z*.28,(age-seconds)*2.3));
        float fine=Noise3(float3(p.x*.95,p.z*.58,(age-seconds)*5.9));
        float breakup=smoothstep(.10,.84,parcel*.62+fine*.38);
        // Constant mass flux: expansion and acceleration dilute the jet;
        // entrained bubbles/droplet area increase the scattering cross-section.
        float speed=sqrt(225.0+pow(9.81*age,2.0));
        float dilution=(15.0/speed)*(6.2*1.2)/(width*thickness);
        float bubbles=1.0+5.2*smoothstep(.35,5.8,age);
        float strands=.5+.5*sin((p.x-centreX)*1.25+sin(parcelAge*3.7)*.85);
        float density=plume*(.15+.85*breakup)*lerp(1.0,.32+.98*strands,turbulence)*dilution*bubbles;
        density*=step(p.y,source.y)*step(LAKE_Y,p.y);
        float alpha=1.0-exp(-density*ds*1.18);
        if(1.0-trans*(1.0-alpha)>.001&&firstDepth>maxT)firstDepth=t;
        float back=pow(saturate(dot(rd,sun)),3.0);
        float3 jetNormal=normalize(float3((p.x-centreX)/max(width,1.0),.35,-1.0));
        float nl=.38+.62*saturate(dot(jetNormal,sun));
        float3 light=float3(.86,.90,.93)*(skyFill*.92+sunFill*(nl*.28+back*.22));
        light*=.80+.20*breakup;
        result+=trans*alpha*light;trans*=1.0-alpha;
        if(trans<.015)break;
    }
    return float4(result,1.0-trans);
}

float4 SprayLayer(float3 ro,float3 rd,float maxT,float loopA,float2 pixel)
{
    float3 source=WaterfallSource();
    float impactAge=sqrt(max(0.0,2.0*(source.y-LAKE_Y)/9.81));
    float3 impact=float3(source.x,LAKE_Y,source.z-15.0*impactAge);
    float seconds=FlightTime(G.z);
    float3 wind=PhysicalWind(impact,seconds);
    float3 center=impact+float3(wind.x*2.8,19.0,wind.z*2.8-10.0);
    float3 radius=float3(105.0,58.0,98.0);
    float3 o=(ro-center)/radius,d=rd/radius;
    float A=dot(d,d),B=dot(o,d),C=dot(o,o)-1.0,H=B*B-A*C;
    if(H<=0.0)return 0;H=sqrt(H);
    float tn=max(0.0,(-B-H)/A),tf=min(maxT,(-B+H)/A);
    if(tf<=tn)return 0;
    float3 sun=CinematicFrame[8].xyz;
    float sunVis=.30+.70*TerrainShadow(center+float3(0,24.0,-24.0),sun);
    float3 sunRad=CinematicSunColorAt(center.y)*CinematicFrame[8].w*sunVis;
    float3 skyAmb=AtmosphereDiffuse(float3(0,1,0));
    float forwardScatter=pow(saturate(dot(rd,sun)),4.0)*.38+.18;
    // Primary optical rainbow dispersion + sunlit mist halo in waterfall spray.
    float antiSun=dot(-rd,sun);
    float bowAngle=antiSun>.0?(antiSun-.736)/.028:(dot(rd,normalize(float3(sun.x,0,sun.z)))-.56)/.14;
    float bowMask=exp(-pow((bowAngle-.5)*2.2,2.0))*smoothstep(.12,.26,sun.y)*sunVis;
    float3 rainbow=float3(exp(-pow((bowAngle-.20)*3.6,2.0)),
                          exp(-pow((bowAngle-.52)*3.6,2.0)),
                          exp(-pow((bowAngle-.82)*3.6,2.0)))*bowMask;
    float jitter=.20+.60*frac(52.9829189*frac(dot(floor(pixel),float2(.06711056,.00583715))));
    float ds=(tf-tn)/16.0,trans=1.0;float3 accum=0;
    [loop]for(int i=0;i<16;++i)
    {
        float t=tn+(i+jitter)*ds;float3 p=ro+rd*t,q=(p-center)/radius;
        // Strictly C^2 compact-support radial envelope eliminates any visible
        // bounding ellipsoid shell, leaving only turbulent billowing mist plumes.
        float shell=pow(saturate(1.0-dot(q,q)),2.8);
        float billow=FBM3((p-wind*seconds*.8)*.036+float3(0,-seconds*.28,0));
        float fine=FBM3((p-wind*seconds*1.2)*.095+float3(13.7,-seconds*.55,7.1));
        float wisp=smoothstep(.30,.76,billow*.65+fine*.35);
        float3 qCore=(p-(impact+float3(0,3.5,-3.0)))/float3(25.0,13.0,23.0);
        float core=pow(saturate(1.0-dot(qCore,qCore)),2.2)*(.45+.55*fine);
        float waterFade=smoothstep(LAKE_Y-.5,LAKE_Y+7.0,p.y);
        float density=(shell*wisp*.34+core*.85)*waterFade;
        float alpha=1.0-exp(-density*ds*.016);
        float heightShade=.74+.26*saturate((p.y-LAKE_Y)/52.0);
        float3 sprayLight=(skyAmb*.95+sunRad*forwardScatter)*heightShade+sunRad*rainbow*.16;
        accum+=trans*alpha*sprayLight;trans*=1.0-alpha;
    }
    return float4(accum,1.0-trans);
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
    float waterfallT=MAX_DIST+1.0;
    float4 fall=validTerrainRay?WaterfallVolume(effectsOrigin,rd,max(0.0,solidT-rayStart),FlightTime(G.z),waterfallT):0;
    waterfallT+=rayStart;
    if(fall.a>.001)
    {
        float3 wp=ro+rd*min(waterfallT,MAX_DIST);
        col=lerp(col,ApplyFog(fall.rgb/max(fall.a,.001),rd,waterfallT,wp,sun),fall.a);
        if(fall.a>.65)solidT=min(solidT,waterfallT);
        reactive=1.0;
    }

    // All participating media stop at the nearest procedural surface.
    float depthLimit=min(solidT,MAX_DIST);
    // Clouds are composited after ALL opaque geometry, using its final depth.
    // Doing this here left trees and aircraft visible in front of opaque fog.
    // The old smoke grid does not match the new geometry and is disabled.
    float4 smoke=0;
    col=smoke.rgb+col*(1.0-smoke.a);
    float4 spray=validTerrainRay?SprayLayer(effectsOrigin,rd,max(0.0,depthLimit-rayStart),loopA,input.pos.xy):0;
    col=spray.rgb+col*(1.0-spray.a);
    reactive=max(reactive,step(0.015,max(smoke.a,spray.a)));

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
