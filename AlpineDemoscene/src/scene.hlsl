// Alpine Dreaming - a 100% runtime procedural Direct3D 11 demoscene.
// No textures, depth plates, meshes, crossfades or offline assets are used.

#include "frame_vertex.hlsli"
#include "detail_common.hlsli"

cbuffer Frame : register(b0)
{
    float4 G; // render width, render height, seconds, frame counter
    float4 G2; // session seed and host-reserved temporal data
};

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

float SdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float SdCapsule(float3 p, float3 a, float3 b, float r)
{
    float3 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - r;
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
    float slopeDen = max(abs(rd.y) + 5.25 * length(rd.xz), 0.12);
    // A height field is not an SDF. A global slope bound alone crawls at eye
    // height and exhausts the budget before reaching distant ground. Combine
    // safe clearance steps with bounded intervals, testing their midpoint and
    // bisecting crossings. Minimum progress covers the full 9 km in <192 steps.
    [loop] for (int i = 0; i < 192; ++i)
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
        float interval=min(max(2.0,t*0.04),128.0);
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

float3 FresnelSchlick(float cosTheta, float3 f0)
{
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}

float3 PBR(float3 albedo, float3 n, float3 v, float3 l,
           float roughness, float metallic, float shadow, float3 lightColor)
{
    float3 halfVector = v + l;
    float3 h = halfVector * rsqrt(max(dot(halfVector, halfVector), 1e-8));
    float nl = saturate(dot(n, l));
    float nv = max(saturate(dot(n, v)), 1e-4);
    float nh = saturate(dot(n, h));
    float vh = saturate(dot(v, h));
    float a = max(0.045, roughness * roughness);
    float a2 = a * a;
    float den = nh * nh * (a2 - 1.0) + 1.0;
    float D = a2 / max(PI * den * den, 1e-7);
    // Height-correlated Smith GGX visibility (Filament / Heitz). The previous
    // 0.001 denominator clamp flattened every smooth dielectric highlight.
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float visibility = 0.5 / max(gv + gl, 1e-5);
    float3 f0 = lerp(0.04, albedo, metallic);
    float3 F = FresnelSchlick(vh, f0);
    float3 spec = D * visibility * F;
    float3 diffuse = (1.0 - F) * (1.0 - metallic) * albedo / PI;
    float hemi = 0.13 + 0.20 * saturate(n.y * 0.5 + 0.5);
    float daylight = smoothstep(-0.06, 0.16, l.y);
    return albedo * hemi * lerp(0.10, 1.0, daylight)
         + (diffuse + spec) * lightColor * nl * shadow * (3.2 * daylight);
}

float3 SunDirection(float loopA)
{
    float a = loopA - 0.20;
    return normalize(float3(cos(a), 0.28 + 0.38 * sin(a), sin(a)));
}

float3 Sky(float3 rd, float3 sun)
{
    float h = saturate(rd.y * 0.72 + 0.28);
    float daylight = smoothstep(-0.08, 0.22, sun.y);
    float3 col = lerp(lerp(float3(0.012,0.018,0.045), float3(0.48,0.62,0.73), daylight),
                      lerp(float3(0.002,0.005,0.019), float3(0.055,0.19,0.42), daylight), pow(h, 0.62));
    float warm = 1.0 - smoothstep(0.12, 0.48, sun.y);
    float3 sunCol = lerp(float3(1.0,0.94,0.78), float3(1.0,0.25,0.055), warm);
    float sd = saturate(dot(rd, sun));
    col += sunCol * pow(sd, 420.0) * 9.0 * smoothstep(-0.03, 0.04, sun.y);
    col += sunCol * pow(sd, 18.0) * 0.34;
    col += sunCol * exp(-abs(rd.y) * 10.0) * warm * 0.09;
    return col;
}

float TownGroundShadow(float3 p,float3 sun)
{
    if(max(abs(p.x-TOWN_C.x),abs(p.z-TOWN_C.y))>420.0||p.y>185.0||sun.y<0.03)return 1.0;
    float visibility=1.0;
    float2 originCell=floor((p.xz-TOWN_C)/float2(70,75)+0.5);
    float3 inv=(step(0.0,sun)*2.0-1.0)/max(abs(sun),0.0001);
    // Nine nearby wall boxes provide coherent cast shadows on the pavement.
    // This intentionally omits window/roof microgeometry, not an SDF self-shadow.
    [loop]for(uint cell=0;cell<9;++cell)
    {
        float2 id=originCell+float2(cell%3,cell/3)-1.0;
        if(abs(id.x)>4.0||abs(id.y)>4.0||abs(id.x)<1.0)continue;
        float r=Hash21(id+3.1);
        float2 hc=TOWN_C+id*float2(70,75);
        hc.x+=12.0*sin(hc.y*0.006);
        float3 center=float3(hc.x,156.0+4.0*r,hc.y);
        float3 halfSize=float3(13.0+3.0*r,11.0+4.0*r,17.0);
        float3 a=(center-halfSize-p)*inv,b=(center+halfSize-p)*inv;
        float3 lo=min(a,b),hi=max(a,b);
        float nearT=max(lo.x,max(lo.y,lo.z)),farT=min(hi.x,min(hi.y,hi.z));
        if(farT>=max(nearT,0.12))visibility=0.22;
    }
    return visibility;
}

float3 ShadeTerrain(float3 p, float3 rd, float3 sun, float loopA,float footprint)
{
    float3 n = TerrainNormal(p.xz);
    float slope = saturate(1.0 - n.y);
    float fine = FBM2(p.xz * 0.016);
    float strata = 0.90 + 0.10 * sin(p.y * 0.11 + Noise2(p.xz * 0.007) * 8.0);
    float3 grass = lerp(float3(0.025,0.075,0.020), float3(0.20,0.29,0.065), fine);
    float3 rock = lerp(float3(0.105,0.095,0.085), float3(0.39,0.35,0.30), fine) * strata;
    float snowLine=48.0*(Noise2(p.xz*0.027)-0.5)+22.0*sin(p.x*0.032+p.z*0.018);
    float snow = smoothstep(590.0, 760.0, p.y+snowLine) * (1.0 - smoothstep(0.30, 0.72, slope));
    float melt = 0.5 + 0.5 * sin(loopA - 0.6);
    snow *= lerp(1.0, 0.72, melt);
    float3 albedo = lerp(grass, rock, smoothstep(0.08, 0.43, slope));
    albedo = lerp(albedo, float3(0.82,0.88,0.93), snow);
    float forest = smoothstep(0.58, 0.77, Noise2(p.xz * 0.021 + 12.0));
    forest *= (1.0 - snow) * (1.0 - smoothstep(0.24, 0.52, slope));
    float2 wind = WindField(p.xz, loopA);
    float grassSway = 0.94 + 0.06 * sin(dot(p.xz, wind) * 0.12 + loopA * 19.0);
    albedo = lerp(albedo * grassSway, float3(0.012,0.048,0.018), forest * 0.68);
    float riverCenter = ValleyCenter(p.z) - 34.0;
    float river = (1.0 - smoothstep(7.0,18.0,abs(p.x-riverCenter))) * (1.0-smoothstep(120.0,370.0,p.y));
    albedo = lerp(albedo, float3(0.020,0.16,0.19), river * 0.88);
    float2 tq = p.xz - TOWN_C;
    float road = (1.0-smoothstep(5.0,11.0,abs(tq.x-18.0*sin(tq.y*0.006))))
                 * (1.0-smoothstep(320.0,430.0,abs(tq.y)));
    float plaza=1.0-smoothstep(45.0,66.0,length((p.xz-float2(14,1755))/float2(0.78,1.0)));
    road=max(road,plaza);
    albedo = lerp(albedo, float3(0.13,0.12,0.105), road);
    float wet = exp(-pow((p.x-350.0)/115.0,2.0))*smoothstep(5000.0,5160.0,p.z)*(1.0-smoothstep(315.0,780.0,p.y));
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
    shadow*=TownGroundShadow(p+float3(0,0.08,0),sun);
    float cloudShadow = lerp(0.66, 1.0, smoothstep(0.47,0.73,
        Noise2(p.xz*0.0012 + WindField(p.xz,loopA)*0.42)));
    float warm = 1.0 - smoothstep(0.10, 0.45, sun.y);
    float3 light = lerp(float3(1.0,0.95,0.82), float3(1.0,0.37,0.10), warm);
    return PBR(albedo, n, -rd, sun, rough, 0.0, shadow * cloudShadow, light);
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

// World-space line coverage converges to its average when details become
// subpixel. No screen-space random grain is used for building materials.
float TownLine(float coordinate,float period,float halfWidth,float footprint)
{
    float edge=abs(frac(coordinate/period+0.5)-0.5)*period;
    float aa=max(0.015,footprint*0.55);
    float cover=1.0-smoothstep(halfWidth-aa,halfWidth+aa,edge);
    return lerp(saturate(2.0*halfWidth/period),cover,1.0-smoothstep(period*0.25,period,footprint));
}

void HouseCoordinates(float3 p,out float3 q,out float3 halfSize,out float seed,out float2 id)
{
    id=floor((p.xz-TOWN_C)/float2(70.0,75.0)+0.5);
    seed=Hash21(id+3.1);
    float2 center=TOWN_C+id*float2(70.0,75.0);
    center.x+=12.0*sin(center.y*0.006);
    q=p-float3(center.x,156.0+4.0*seed,center.y);
    halfSize=float3(13.0+3.0*seed,11.0+4.0*seed,17.0);
}

float TownMap(float3 p, float loopA, float3 cameraPos, out float material)
{
    float d = 100000.0;
    material = 1.0;
    float2 gp = (p.xz - TOWN_C) / float2(70.0, 75.0);
    float2 id = floor(gp + 0.5);
    if (abs(id.x) <= 4.0 && abs(id.y) <= 4.0 && abs(id.x) >= 1.0)
    {
        float3 q,hs;float r;float2 houseId;
        HouseCoordinates(p,q,hs,r,houseId);
        float house = SdBox(q,hs);
        float side=step(abs(q.z)/hs.z,abs(q.x)/hs.x);
        float wallU=lerp(q.x,q.z,side);
        float wallDepth=lerp(abs(q.z)-hs.z,abs(q.x)-hs.x,side);
        float2 cell=float2(frac((wallU+2.25)/4.5)*4.5-2.25,
                           frac((p.y-152.1+2.1)/4.2)*4.2-2.1);
        float centerY=q.y-cell.y;
        float windowPart=100000.0,windowMaterial=10.0;
        if(p.y-cell.y>151.2 && centerY<hs.y-1.3 && abs(wallU-cell.x)<lerp(hs.x,hs.z,side)-1.6
           && !(abs(wallU-cell.x)<0.1&&p.y-cell.y<154.0))
        {
            float3 local=float3(cell,wallDepth);
            float opening=SdBox(local+float3(0,0,0.10),float3(0.70,1.00,0.30));
            house=max(house,-opening);
            float glass=SdBox(local+float3(0,0,0.34),float3(0.68,0.98,0.04));
            windowPart=glass;windowMaterial=9.0;
            float frame=max(SdBox(local-float3(0,0,0.04),float3(0.81,1.11,0.08)),
                           -SdBox(local,float3(0.65,0.95,0.3)));
            float bars=min(SdBox(local-float3(0,0,0.05),float3(0.045,0.97,0.08)),
                           SdBox(local-float3(0,0.10,0.05),float3(0.68,0.045,0.08)));
            frame=min(frame,bars);
            if(frame<windowPart){windowPart=frame;windowMaterial=10.0;}
            float shutterDepth=0.09+0.06*sin(loopA*3.0+r*TAU)*saturate(abs(cell.x)-0.74);
            float shutter=SdBox(float3(abs(cell.x)-1.06,cell.y,wallDepth-shutterDepth),float3(0.30,1.02,0.07));
            if(shutter<windowPart){windowPart=shutter;windowMaterial=12.0;}
        }
        // The flattened village surface is ~149.7 m; the original box base
        // (145 m) is buried. Doors start at 149.75, with 2.2 m clear height.
        float3 doorLocal=float3(wallU,p.y-150.85,wallDepth);
        float doorway=SdBox(doorLocal+float3(0,0,0.10),float3(0.52,1.12,0.30));
        house=max(house,-doorway);
        float door=SdBox(doorLocal+float3(0,0,0.32),float3(0.50,1.10,0.08));
        if(door<windowPart){windowPart=door;windowMaterial=8.0;}
        if (house < d) { d = house; material = 1.0; }
        if(windowPart<d){d=windowPart;material=windowMaterial;}
        // Eaves meet the wall top exactly; the old profile floated 5 m above
        // the walls and truncated the gable before it reached its ridge.
        float3 rq = q-float3(0,hs.y,0);
        float roof = max(abs(rq.z) - 20.0,
                     max(-rq.y, (abs(rq.x) + 1.15 * rq.y - (16.5 + 3.0 * r))*0.6562));
        if (roof < d) { d = roof; material = 2.0; }
        float chimneyY=hs.y+(16.5+3.0*r-5.0)/1.15+0.55;
        float chimney=SdBox(q-float3(5.0,chimneyY,6.0),float3(0.30,0.75,0.35));
        if(chimney<d){d=chimney;material=11.0;}
        if(r>0.34)
        {
            float facing=houseId.x>0.0?-1.0:1.0;
            float3 balcony=float3(q.x*facing-hs.x-1.1,q.y-1.5,q.z);
            float timber=SdBox(balcony,float3(1.2,0.09,7.8));
            float frontRail=SdBox(balcony-float3(1.05,1.14,0),float3(0.06,0.06,7.7));
            float sideRail=SdBox(float3(balcony.x,balcony.y-1.14,abs(balcony.z)-7.6),float3(1.1,0.06,0.06));
            float spindle=SdBox(float3(balcony.x-1.05,balcony.y-0.615,
                frac((balcony.z+0.35)/0.70)*0.70-0.35),float3(0.045,0.525,0.045));
            spindle=max(spindle,abs(balcony.z)-7.7);
            timber=min(timber,min(frontRail,min(sideRail,spindle)));
            if(timber<d){d=timber;material=8.0;}
        }
    }

    float church = SdBox(p - float3(-72.0, 162.0, 1770.0), float3(17.0, 17.0, 31.0));
    float tower = SdBox(p - float3(-72.0, 190.0, 1748.0), float3(8.0, 35.0, 8.0));
    float3 sq = p - float3(-72.0, 231.0, 1748.0);
    float spire = max(length(sq.xz) * 0.72 + sq.y * 0.30 - 5.0, abs(sq.y) - 18.0);
    float landmark = min(church, min(tower, spire));
    if (landmark < d) { d = landmark; material = 3.0; }

    // Conifers use exactly the same periodic wind as grass, clouds and smoke.
    float2 tg = (p.xz - TOWN_C) / 54.0;
    float2 tid = floor(tg + 0.5);
    float ring = max(abs(tid.x), abs(tid.y));
    float tr = Hash21(tid + 19.3);
    if (ring >= 4.0 && ring <= 6.0 && tr > 0.27 && abs(tid.x)>=1.0)
    {
        float2 tc = TOWN_C + tid * 54.0 + (tr - 0.5) * float2(18.0, 13.0);
        float height = 30.0 + 18.0 * tr;
        float3 q = p - float3(tc.x, 145.0, tc.y);
        float y01 = saturate(q.y / height);
        q.xz -= WindField(tc, loopA) * (y01 * y01) * 3.0;
        float trunk = SdCapsule(q, float3(0,0,0), float3(0,height*0.77,0), 0.55+0.10*tr);
        float angle=dot(q.xz,q.xz)<1e-8?0.0:atan2(q.z,q.x);
        // Asymmetric branch skirts: short rising edge, long taper, irregular
        // whorl spacing and angular branch tips instead of rounded torus rings.
        float layer=frac(q.y/5.2+tr*2.1+0.12*sin(q.y*0.43+tr*11.0));
        float skirt=smoothstep(0.0,0.15,layer)*(1.0-smoothstep(0.15,1.0,layer));
        float tier=0.56+0.44*skirt;
        float branchPhase=angle*7.0+tr*17.0+sin(q.y*0.41+tr);
        float lobes=0.78+0.16*cos(branchPhase)+0.06*cos(angle*17.0+q.y*0.91+tr*7.0);
        float radius=9.5*pow(saturate(1.0-y01),0.77)*tier*lobes;
        float footprint=1.8*length(p-cameraPos)/max(G.y,1.0);
        float twig=0.30*sin(q.x*1.13+q.y*0.51)*sin(q.z*1.31-q.y*0.73);
        twig*=1.0-smoothstep(0.25,1.2,footprint);
        float radial = length(q.xz)-radius-twig;
        // Sharp branch skirts require a smaller distance bound. An enclosing
        // box restores efficient empty-space traversal outside the actual crown.
        float crownBounds=SdBox(q-float3(0,(height+4.5)*0.5,0),float3(9.5,(height-4.5)*0.5,9.5));
        float foliage = max(radial * 0.14,crownBounds);
        float tree = min(trunk, foliage);
        if (tree < d) { d = tree; material = 6.0; }
    }

    // A real waving cloth sheet and pole on the village square.
    float3 fp = p - float3(83.0, 145.0, 1734.0);
    float pole = SdCapsule(fp, float3(0,0,0), float3(0,23,0), 0.34);
    if (pole < d) { d = pole; material = 3.0; }
    float clothWave = 1.6 * sin(loopA * 13.0 + fp.x * 0.42) * saturate(fp.x / 10.0);
    float cloth = SdBox(fp - float3(5.2, 19.5, clothWave), float3(5.2, 3.0, 0.16));
    if (cloth < d) { d = cloth; material = 7.0; }

    return d;
}

float TraceTown(float3 ro, float3 rd, float maxT, float loopA, out float material)
{
    material = 0.0;
    float tn, tf;
    if (!RayBox(ro, rd, float3(-390.0,140.0,1400.0), float3(390.0,275.0,2200.0), tn, tf))
        return maxT + 1.0;
    float t = max(0.0, tn), endT = min(tf, maxT);
    // Fine branch skirts converge slowly on grazing rays; 112 steps skipped
    // tested genuine intersections. Keep their conservative distance bound.
    [loop] for (int i = 0; i < 192; ++i)
    {
        if (t >= endT) break;
        float m;
        float3 p=ro+rd*t;
        float d=TownMap(p,loopA,ro,m);
        float eps=max(0.012,t*0.00006);
        if(d<eps){material=m;return t;}
        // Repeated cells select one house/tree, not the nearest neighbor SDF.
        // Do not step across a cell boundary using the previous cell's distance.
        float2 houseCell=frac((p.xz-TOWN_C)/float2(70.0,75.0)+0.5);
        float2 treeCell=frac((p.xz-TOWN_C)/54.0+0.5);
        float2 positive=step(0.0,rd.xz);
        float2 inverseDir=1.0/max(abs(rd.xz),0.00001);
        float2 houseEdge=lerp(houseCell,1.0-houseCell,positive)*float2(70.0,75.0)*inverseDir;
        float2 treeEdge=lerp(treeCell,1.0-treeCell,positive)*54.0*inverseDir;
        float boundary=min(min(houseEdge.x,houseEdge.y),min(treeEdge.x,treeEdge.y));
        t+=min(clamp(d*0.68,0.02,24.0),max(0.02,boundary+0.002));
    }
    return maxT + 1.0;
}

float3 TownNormal(float3 p, float loopA, float3 cameraPos)
{
    float e=clamp(length(p-cameraPos)*0.00035,0.012,0.20),m;
    float3 gradient=0.0;
    // Four tetrahedral samples in a real loop keep detailed TownMap bytecode
    // single-copy and preserve narrow frame/mullion normals at close range.
    [loop]for(int i=0;i<4;++i)
    {
        float3 axis=i==0?float3(1,-1,-1):(i==1?float3(-1,-1,1):(i==2?float3(-1,1,-1):float3(1,1,1)));
        gradient+=axis*TownMap(p+axis*e,loopA,cameraPos,m);
    }
    return gradient*rsqrt(max(dot(gradient,gradient),1e-10));
}

float3 ShadeTown(float3 p,float3 rd,float3 sun,float material,float loopA,float3 cameraPos)
{
    float3 n=TownNormal(p,loopA,cameraPos);
    float3 q,hs;float seed;float2 houseId;
    HouseCoordinates(p,q,hs,seed,houseId);
    float footprint=max(0.025,1.8*length(p-cameraPos)/max(G.y,1.0));
    float fine=1.0-smoothstep(0.20,1.25,footprint);
    float side=step(abs(n.z),abs(n.x));
    float u=lerp(q.x,q.z,side);
    float woodSeam=TownLine(q.y,0.28,0.015,footprint);
    float grain=sin(u*2.8+2.3*sin(q.y*1.7+seed*13.0));
    float3 wood=lerp(float3(0.12,0.055,0.021),float3(0.30,0.145,0.060),seed);
    wood*=1.0-0.30*woodSeam+0.08*grain*fine;
    float row=floor((p.y-149.7)/0.35);
    float mortar=max(TownLine(p.y-149.7,0.35,0.020,footprint),
                     TownLine(u+frac(row*0.5)*0.62,0.62,0.025,footprint));
    float stoneVariation=lerp(0.5,Noise2(float2(u,p.y)*0.57),1.0-smoothstep(0.6,2.5,footprint));
    float3 stone=lerp(float3(0.22,0.225,0.19),float3(0.48,0.45,0.36),stoneVariation);
    stone=lerp(stone,float3(0.09,0.085,0.075),mortar*0.75);
    float3 albedo=lerp(float3(0.67,0.64,0.50),float3(0.77,0.71,0.59),seed);
    float rough=0.84,emission=0.0;
    if(material<1.5)
    {
        float timber=smoothstep(-0.3,0.1,q.y)*(0.55+0.45*step(0.42,seed));
        albedo=lerp(albedo,wood,timber);
        float plinth=1.0-smoothstep(151.0,151.4,p.y);
        albedo=lerp(albedo,stone,plinth);
        float broadStain=lerp(0.5,Noise2(float2(u*0.18,p.y*0.31)+seed*11.0),1.0-smoothstep(1.2,4.0,footprint));
        albedo*=0.93+0.14*broadStain;
        float underEave=1.0-0.24*exp(-abs(q.y-hs.y)*0.42);
        albedo*=underEave;
    }
    else if(material<2.5)
    {
        float2 roofUV=float2(q.z,abs(q.x)*1.524);
        float tileRow=floor(roofUV.y/0.44);
        float joints=max(TownLine(roofUV.y,0.44,0.020,footprint),
            TownLine(roofUV.x+frac(tileRow*0.5)*0.28,0.28,0.014,footprint));
        float broad=lerp(0.5,Noise2(roofUV*0.32+seed*17.0),1.0-smoothstep(1.2,4.0,footprint));
        albedo=lerp(float3(0.14,0.042,0.022),float3(0.36,0.13,0.063),broad);
        albedo*=1.0-0.45*joints;
        float ridge=1.0-smoothstep(0.16,0.42,abs(q.x));
        albedo=lerp(albedo,float3(0.33,0.12,0.058),ridge);
        rough=0.82;
    }
    else if(material<3.5){albedo=stone*1.22;rough=0.9;}
    else if(material>5.5&&material<6.5)
    {
        float branchShade=0.84+0.10*sin(p.y*1.7)+0.06*sin(p.y*2.93+1.1);
        float crown=lerp(0.5,Noise2(p.xz*0.22+p.y*0.031),1.0-smoothstep(1.6,5.0,footprint));
        albedo=lerp(float3(0.012,0.035,0.012),float3(0.065,0.13,0.037),crown)*branchShade;
        float trunkMask=1.0-smoothstep(148.8,150.0,p.y);
        albedo=lerp(albedo,float3(0.12,0.070,0.034),trunkMask);
        rough=0.94;
    }
    else if(material<7.5&&material>6.5)
    {
        albedo=float3(0.60,0.025,0.012);
        float2 flagUV=float2(p.x-88.2,p.y-164.5);
        float crossMask=max((1.0-smoothstep(0.55,0.7,abs(flagUV.x)))*(1.0-smoothstep(1.9,2.1,abs(flagUV.y))),
                            (1.0-smoothstep(1.9,2.1,abs(flagUV.x)))*(1.0-smoothstep(0.55,0.7,abs(flagUV.y))));
        albedo=lerp(albedo,float3(0.78,0.80,0.72),crossMask);
    }
    else if(material>7.5&&material<8.5){albedo=wood;rough=0.73;}
    else if(material>8.5&&material<9.5){albedo=float3(0.018,0.043,0.048);rough=0.10;emission=1.0;}
    else if(material>9.5&&material<10.5){albedo=float3(0.44,0.38,0.23);rough=0.65;}
    else if(material>10.5&&material<11.5){albedo=stone;rough=0.88;}
    else if(material>11.5)
    {
        albedo=lerp(float3(0.055,0.13,0.13),float3(0.09,0.15,0.047),seed);
        albedo*=1.0-0.28*TownLine(q.y,0.16,0.009,footprint);
        rough=0.72;
    }
    float warm = 1.0 - smoothstep(0.10,0.45,sun.y);
    float3 light = lerp(float3(1.0,0.95,0.82),float3(1.0,0.34,0.08),warm);
    float3 col = PBR(albedo,n,-rd,sun,rough,0.0,0.88,light);
    if(emission>0.5)
    {
        float fresnel=0.04+0.96*pow(1.0-saturate(dot(n,-rd)),5.0);
        col=lerp(col,Sky(reflect(rd,n),sun),fresnel*0.85);
        float occupied=step(0.30,Hash21(houseId+floor((p.y-152.1)/4.2)*11.7));
        col+=warm*occupied*(0.98+0.02*sin(loopA*2.0+seed*TAU))*float3(1.1,0.36,0.085);
    }
    return col;
}

void GliderPose(int which, float loopA, out float3 center, out float3 right, out float3 up, out float3 forward)
{
    float a = which == 0 ? loopA * 2.0 + 0.35 : -loopA * 3.0 + 2.0;
    float radiusX = which == 0 ? 690.0 : 940.0;
    float radiusZ = which == 0 ? 510.0 : 720.0;
    float2 base = which == 0 ? LAKE_C : float2(120.0,3470.0);
    center = float3(base.x+radiusX*cos(a),(which==0?650.0:790.0)+80.0*sin(a*2.0),base.y+radiusZ*sin(a));
    // The second orbit runs backwards in phase; orient it along its velocity.
    forward = normalize((which==0?1.0:-1.0)*float3(-radiusX*sin(a),160.0*cos(a*2.0),radiusZ*cos(a)));
    float3 flatRight = normalize(cross(float3(0,1,0),forward));
    float3 flatUp = normalize(cross(forward,flatRight));
    float bank = (which==0?0.58:-0.46)*sin(a);
    right = flatRight*cos(bank)+flatUp*sin(bank);
    up = normalize(cross(forward,right));
}

float GliderSDF(float3 p, float3 center, float3 right, float3 up, float3 forward)
{
    float3 a=p-center;
    // The model's nose is -Z, while the flight frame points forwards in +Z.
    float3 q=float3(dot(a,right),dot(a,up),-dot(a,forward));
    float wing=max(abs(q.y+0.020*abs(q.x))-0.72,max(abs(q.z+0.075*abs(q.x))-(2.6+0.025*abs(q.x)),abs(q.x)-45.0));
    float body=SdCapsule(q,float3(0,0,-17),float3(0,0,18),2.0);
    float tail=SdBox(q-float3(0,0.3,14),float3(10.5,0.48,3.2));
    float fin=SdBox(q-float3(0,2.4,14.5),float3(0.55,3.2,3.1));
    return min(wing,min(body,min(tail,fin)));
}

bool RaySphere(float3 ro,float3 rd,float3 center,float radius,out float tn,out float tf)
{
    float3 oc=ro-center; float b=dot(oc,rd),c=dot(oc,oc)-radius*radius; float h=b*b-c;
    if(h<0.0){tn=tf=0.0;return false;} h=sqrt(h);tn=-b-h;tf=-b+h;return tf>0.0;
}

float TraceOneGlider(float3 ro,float3 rd,float maxT,int which,float loopA)
{
    float3 c,r,u,f; GliderPose(which,loopA,c,r,u,f); float tn,tf;
    if(!RaySphere(ro,rd,c,54.0,tn,tf))return maxT+1.0;
    float t=max(0.0,tn),endT=min(maxT,tf);
    [loop]for(int i=0;i<52;++i){if(t>=endT)break;float d=GliderSDF(ro+rd*t,c,r,u,f);if(d<0.20)return t;t+=max(0.16,d*0.72);}
    return maxT+1.0;
}

float TraceGliders(float3 ro,float3 rd,float maxT,float loopA,out float which)
{
    float a=TraceOneGlider(ro,rd,maxT,0,loopA),b=TraceOneGlider(ro,rd,maxT,1,loopA);
    which=a<b?0.0:1.0;return min(a,b);
}

float3 ShadeGlider(float3 p,float3 rd,float3 sun,int which,float loopA)
{
    float3 c,r,u,f;GliderPose(which,loopA,c,r,u,f);float e=0.32;
    float3 n=normalize(float3(GliderSDF(p+float3(e,0,0),c,r,u,f)-GliderSDF(p-float3(e,0,0),c,r,u,f),
        GliderSDF(p+float3(0,e,0),c,r,u,f)-GliderSDF(p-float3(0,e,0),c,r,u,f),
        GliderSDF(p+float3(0,0,e),c,r,u,f)-GliderSDF(p-float3(0,0,e),c,r,u,f)));
    float3 a=p-c;float3 q=float3(dot(a,r),dot(a,u),-dot(a,f));
    float orange=(1.0-smoothstep(1.1,2.2,abs(q.x)))*smoothstep(-9.0,-2.0,q.z)*(1.0-smoothstep(-1.0,5.0,q.z));
    float canopy=(1.0-smoothstep(0.8,2.2,abs(q.x)))*smoothstep(-8.0,-2.0,q.z)*smoothstep(0.6,1.2,q.y);
    float3 albedo=lerp(float3(0.78,0.82,0.85),float3(1.0,0.12,0.015),orange);
    albedo=lerp(albedo,float3(0.015,0.055,0.075),canopy);
    return PBR(albedo,n,-rd,sun,0.24,0.16,1.0,float3(1.0,0.92,0.78));
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
    // Water must reflect actual geometry, including the surrounding mountains.
    // Restrict this extra trace to the hemisphere that can reach the horizon.
    if(reflectedRay.y<0.65)
    {
        float3 reflectionOrigin=p+n*0.35;
        float rt=TraceTerrain(reflectionOrigin,reflectedRay,4200.0);
        if(rt<=4200.0)
        {
            float3 rp=reflectionOrigin+reflectedRay*rt;
            // Reflection LOD avoids another full shadow march per water pixel.
            float3 rn=TerrainNormal(rp.xz);
            float rock=smoothstep(0.08,0.43,1.0-rn.y);
            float snow=smoothstep(590.0,760.0,rp.y)*(1.0-smoothstep(0.30,0.72,1.0-rn.y));
            float3 ra=lerp(float3(0.07,0.16,0.035),float3(0.25,0.23,0.20),rock);
            ra=lerp(ra,float3(0.82,0.88,0.93),snow);
            float3 reflectedTerrain=ra*(0.22+2.4*saturate(dot(rn,sun))*smoothstep(-0.06,0.16,sun.y));
            float aerial=1.0-exp(-rt*0.00018);
            reflection=lerp(reflectedTerrain,Sky(reflectedRay,sun),aerial);
        }
    }
    float depth=max(0.0,p.y-Terrain(p.xz));float shallow=exp(-depth*0.055);
    float3 refraction=lerp(float3(0.010,0.075,0.090),float3(0.20,0.24,0.16),shallow);
    float3 refractedRay=refract(rd,n,1.0/1.333);
    float opticalDepth=depth/max(abs(refractedRay.y),0.12);
    refraction*=exp(-opticalDepth*float3(0.010,0.004,0.002));
    float fresnel=0.02037+0.97963*pow(1.0-saturate(dot(n,-rd)),5.0);
    float3 col=lerp(refraction,reflection,fresnel);
    float specPower=lerp(220.0,90.0,saturate(unresolved*7.0));
    float spec=pow(saturate(dot(reflect(-sun,n),-rd)),specPower);
    col+=spec*float3(4.0,3.2,2.1)*smoothstep(-0.06,0.16,sun.y);
    float shoreNoise=Noise2(p.xz*0.18+WindField(p.xz,loopA)*0.5);
    float foam=(1.0-smoothstep(0.7,4.0,depth))*smoothstep(0.38,0.72,shoreNoise);
    float streakPhase=dot(p.xz,float2(0.91,0.38))+loopA*29.0;
    foam*=0.72+0.28*sin(streakPhase)*DetailBand(fp,0.16);
    return lerp(col,float3(0.70,0.78,0.76),foam*0.58);
}

float WaterfallHit(float3 ro,float3 rd,float maxT,float loopA)
{
    // The escarpment is sloped. A vertical card detached its upper stream and
    // buried its lower half. Trace a thin cascade following the actual terrain.
    float tn,tf;
    if(!RayBox(ro,rd,float3(269.0,295.0,5010.0),float3(431.0,820.0,5240.0),tn,tf))return maxT+1.0;
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
            float width=54.0+22.0*(1.0-smoothstep(330.0,760.0,q.y));
            if(abs(q.x-350.0)<width)return t;
            break;
        }
        t+=min(d/slopeDen,28.0);
    }
    return maxT+1.0;
}

float4 ShadeWaterfall(float3 p,float3 rd,float3 sun,float loopA)
{
    float2 wind=WindField(p.xz,loopA);
    float flow=0.5+0.5*sin(p.z*0.19+loopA*43.0+sin(p.x*0.3));
    flow=lerp(flow,Noise2(p.xz*0.075+wind*0.4),0.35);
    float strands=pow(saturate(0.5+0.5*sin(p.x*0.52+flow*8.0-loopA*37.0)),7.0);
    float dhdx=0.25*0.072*cos(p.x*0.072+loopA*31.0),dhdz=0.15*0.041*cos(p.z*0.041+loopA*43.0);
    float3 baseN=TerrainNormal(p.xz);
    float3 n=normalize(float3(baseN.x/max(baseN.y,0.05)-dhdx,1.0,baseN.z/max(baseN.y,0.05)-dhdz));
    if(dot(n,-rd)<0.0)n=-n;
    float spec=pow(saturate(dot(reflect(-sun,n),-rd)),90.0);
    float3 col=lerp(float3(0.20,0.43,0.58),float3(0.72,0.88,0.96),strands)+spec*float3(2.2,1.9,1.5);
    float edge=smoothstep(5010.0,5026.0,p.z)*(1.0-smoothstep(5218.0,5240.0,p.z));
    return float4(col,saturate(0.36+0.46*strands+0.16*flow)*edge);
}

float4 SprayLayer(float3 ro,float3 rd,float maxT,float loopA,float2 pixel)
{
    float3 center=float3(350.0,Terrain(float2(350.0,5020.0))+12.0,5015.0),radius=float3(190.0,105.0,155.0);
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

// Several chimneys merge into a wind-bent, depth-aware village smoke volume.
float4 TownSmokeLayer(float3 ro,float3 rd,float maxT,float loopA,float2 pixel)
{
    float3 center=float3(10.0,225.0,1810.0),radius=float3(170.0,105.0,190.0);
    float3 o=(ro-center)/radius,d=rd/radius;float A=dot(d,d),B=dot(o,d),C=dot(o,o)-1.0,H=B*B-A*C;
    if(H<=0.0)return 0.0;H=sqrt(H);float tn=max(0.0,(-B-H)/A),tf=min(maxT,(-B+H)/A);
    if(tf<=tn)return 0.0;float span=tf-tn,jitter=Hash21(pixel+217.0),density=0.0;
    [loop]for(int i=0;i<5;++i)
    {
        float t=tn+span*((i+jitter)/5.0);float3 p=ro+rd*t;
        float y=saturate((p.y-165.0)/150.0);float2 bend=WindField(p.xz,loopA)*y*y*90.0;
        float2 chimney=floor((p.xz-TOWN_C)/75.0+0.5)*75.0+TOWN_C;
        float plume=exp(-dot((p.xz-chimney-bend)/float2(18.0+55.0*y,18.0+55.0*y),
                              (p.xz-chimney-bend)/float2(18.0+55.0*y,18.0+55.0*y)));
        float n=FBM3(p*0.018+float3(bend.x*0.01,sin(loopA*4.0),bend.y*0.01));
        density+=plume*smoothstep(0.47,0.76,n)*smoothstep(165.0,190.0,p.y)*(1.0-smoothstep(260.0,330.0,p.y));
    }
    float alpha=1.0-exp(-density*(span/5.0)*0.0020);return float4(float3(0.35,0.38,0.39)*alpha,alpha);
}

float3 ApplyFog(float3 col,float3 rd,float dist,float3 p,float3 sun)
{
    float valley=exp(-max(0.0,0.5*(p.y+240.0))/310.0);float density=0.000075+0.00015*valley;
    float trans=exp(-dist*density),warm=1.0-smoothstep(0.12,0.42,sun.y);
    float3 fogCol=lerp(float3(0.42,0.55,0.62),float3(0.66,0.29,0.12),warm*0.55);
    fogCol+=pow(saturate(dot(rd,sun)),8.0)*float3(0.28,0.16,0.06);
    return lerp(fogCol,col,trans);
}


float4 P(VSOut input):SV_Target
{
    float loopA=fmod(G.z,128.0)*(TAU/128.0);
    CameraFrame cam=CurrentFrameCamera(input);
    float3 ro=cam.origin;
    float2 sampleUV=input.uv+TemporalJitter(((int)G.w)&7)/G.xy;
    float3 rd=CameraRay(cam,sampleUV,G.x/G.y),sun=SunDirection(loopA);

    float terrainT=TraceTerrain(ro,rd,MAX_DIST),solidT=terrainT;
    int surface=terrainT<=MAX_DIST?1:0;
    float townMaterial;float townT=TraceTown(ro,rd,solidT,loopA,townMaterial);
    if(townT<solidT){solidT=townT;surface=2;}
    float waterT=WaterHit(ro,rd,solidT,loopA);
    if(waterT<solidT){solidT=waterT;surface=3;}
    float gliderWhich;float gliderT=TraceGliders(ro,rd,solidT,loopA,gliderWhich);
    if(gliderT<solidT){solidT=gliderT;surface=4;}
    // Shade the visible surface only. Detailed terrain behind windows/water
    // need not consume a second material and shadow evaluation.
    float3 hitP=ro+rd*min(solidT,MAX_DIST),col;
    float footprint=2.0*min(solidT,MAX_DIST)/(G.y*cam.lens),reactive=0.0;
    if(surface==1)col=ShadeTerrain(hitP,rd,sun,loopA,footprint);
    else if(surface==2)
    {
        col=ShadeTown(hitP,rd,sun,townMaterial,loopA,ro);
        reactive=(abs(townMaterial-6.0)<0.5||abs(townMaterial-7.0)<0.5||abs(townMaterial-12.0)<0.5)?1.0:0.0;
    }
    else if(surface==3){col=ShadeWater(hitP,rd,sun,loopA,footprint);reactive=1.0;}
    else if(surface==4){col=ShadeGlider(hitP,rd,sun,(int)gliderWhich,loopA);reactive=1.0;}
    else col=Sky(rd,sun);
    if(solidT<=MAX_DIST)col=ApplyFog(col,rd,solidT,hitP,sun);

    float waterfallT=WaterfallHit(ro,rd,solidT,loopA);
    if(waterfallT<solidT)
    {
        float3 wp=ro+rd*waterfallT;float4 fall=ShadeWaterfall(wp,rd,sun,loopA);
        col=lerp(col,ApplyFog(fall.rgb,rd,waterfallT,wp,sun),fall.a);
        solidT=min(solidT,waterfallT);
        reactive=1.0;
    }

    // All participating media stop at the nearest procedural surface.
    float depthLimit=min(solidT,MAX_DIST);
    float4 clouds=CloudLayer(ro,rd,depthLimit,sun,loopA,input.pos.xy);
    col=clouds.rgb+col*(1.0-clouds.a);
    float4 smoke=TownSmokeLayer(ro,rd,depthLimit,loopA,input.pos.xy);
    col=smoke.rgb+col*(1.0-smoke.a);
    float4 spray=SprayLayer(ro,rd,depthLimit,loopA,input.pos.xy);
    col=spray.rgb+col*(1.0-spray.a);
    reactive=max(reactive,step(0.015,max(clouds.a,max(smoke.a,spray.a))));

    // Linear HDR leaves exposure, tonemapping, gamma and grain to the temporal
    // reconstruction pass. Alpha carries signed logarithmic depth; moving or
    // deforming pixels are negative so history is rejected without ghosting.
    float logDepth=log2(1.0+min(solidT,MAX_DIST)*DEPTH_K)/log2(1.0+MAX_DIST*DEPTH_K);
    logDepth=max(logDepth,0.0001);
    return float4(max(col,0.0),reactive>0.5?-logDepth:logDepth);
}
