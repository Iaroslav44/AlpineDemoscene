#ifndef ALPINE_SCENE_COMMON
#define ALPINE_SCENE_COMMON
// Shared world, camera and depth contract for every render pass.
static const float PI = 3.14159265359;
static const float TAU = 6.28318530718;
static const float MAX_DIST = 9000.0;
static const float DEPTH_K = 0.002;
static const float2 TOWN_C = float2(0.0, 1800.0);
static const float2 LAKE_C = float2(-260.0, 4220.0);
static const float LAKE_Y = 320.0;
static const uint TERRAIN_RES = 4096;
static const float TERRAIN_TEXEL = 12000.0 / 4095.0;
// Shared pass ABI: x=mirrored lake view, y=planar reflection available.
cbuffer RenderPass : register(b2) { float4 PassMode; };

float Hash21(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float Noise2(float2 p)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = Hash21(i);
    float b = Hash21(i + float2(1.0, 0.0));
    float c = Hash21(i + float2(0.0, 1.0));
    float d = Hash21(i + 1.0);
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}


float ValleyCenter(float z)
{
    return 105.0 * sin(z * 0.00061 + 0.4) + 42.0 * sin(z * 0.00147 - 1.1);
}

// Continuous 128-second diurnal solar arc: low grazing alpenglow at loop ends,
// golden raking morning light through the village/portrait, crisp Alpine sun
// over the sailplanes/lake/waterfall, descending smoothly back to dusk.
float3 DiurnalSunDirection(float a)
{
    float c01 = 0.5 + 0.5 * cos(a);
    float twilightDip = c01 * c01;
    twilightDip *= twilightDip;
    float x = -0.82 + 0.12 * cos(a - 2.5);
    float y = 0.500 - 0.110 * c01 - 0.352 * twilightDip + 0.022 * sin(a);
    float z = -0.32 + 0.36 * sin(a) - 0.14 * cos(2.0 * a) + 0.12 * sin(2.0 * a);
    return normalize(float3(x, y, z));
}

// Gradient noise on a triangular lattice avoids the square grid visible in
// value-noise mountain faces. Evaluated only while generating the height field.
float GeologicalNoise(float2 p)
{
    float2 cell=floor(p+dot(p,float2(0.3660254,0.3660254)));
    float2 a=p-cell+dot(cell,float2(0.2113249,0.2113249));
    float2 corner=a.x>a.y?float2(1,0):float2(0,1);
    float2 b=a-corner+0.2113249,c=a-0.5773503;
    float3 angle=TAU*float3(Hash21(cell),Hash21(cell+corner),Hash21(cell+1.0));
    float3 gradient=float3(dot(a,float2(cos(angle.x),sin(angle.x))),
        dot(b,float2(cos(angle.y),sin(angle.y))),dot(c,float2(cos(angle.z),sin(angle.z))));
    float3 w=max(0.5-float3(dot(a,a),dot(b,b),dot(c,c)),0.0);
    w*=w;w*=w;
    return saturate(0.5+35.0*dot(w,gradient));
}

// Signed simplex noise and its analytic gradient. The same derivatives control
// the smaller relief bands: steep faces retain long connected grooves instead
// of an isotropic layer of little cones. This is a procedural erosion analogue,
// not a time integration of sediment transport or glacier flow.
float3 GeologicalField(float2 p)
{
    float2 cell=floor(p+dot(p,float2(.3660254,.3660254)));
    float2 a=p-cell+dot(cell,float2(.2113249,.2113249));
    float2 corner=a.x>a.y?float2(1,0):float2(0,1);
    float2 b=a-corner+.2113249,c=a-.5773503;
    float3 angle=TAU*float3(Hash21(cell),Hash21(cell+corner),Hash21(cell+1));
    float2 ga=float2(cos(angle.x),sin(angle.x));
    float2 gb=float2(cos(angle.y),sin(angle.y));
    float2 gc=float2(cos(angle.z),sin(angle.z));
    float3 d=float3(dot(a,ga),dot(b,gb),dot(c,gc));
    float3 w=max(.5-float3(dot(a,a),dot(b,b),dot(c,c)),0);
    float3 w3=w*w*w,w4=w3*w;
    float2 derivative=w4.x*ga+w4.y*gb+w4.z*gc
        -8.0*(w3.x*d.x*a+w3.y*d.y*b+w3.z*d.z*c);
    return 70.0*float3(dot(w4,d),derivative);
}

float RidgeJoin(float a,float b,float width)
{
    float overlap=max(width-abs(a-b),0)/width;
    return max(a,b)+overlap*overlap*width*.25;
}

// Long, meandering and asymmetric watershed spines replace the eight radial
// summits. Different along-ridge wavelengths give unequal saddles and crests.
float AlpineRidge(float2 xz,float2 origin,float2 direction,float width,float height,float seed)
{
    float2 q=xz-origin;
    float along=dot(q,direction),across=dot(q,float2(-direction.y,direction.x));
    float meander=210.0*(GeologicalNoise(float2(along*.00071,seed))-.5)
        +85.0*(GeologicalNoise(float2(along*.0017,seed+11.7))-.5);
    float asymmetry=lerp(.86,1.16,smoothstep(-180,180,across-meander));
    float distance=abs(across-meander)/(width*asymmetry);
    float crest=.70+.36*GeologicalNoise(float2(along*.00073,seed+27))
        +.13*GeologicalNoise(float2(along*.0021,seed-17));
    float shoulder=pow(saturate(1.0-distance),1.45);
    return height*crest*shoulder;
}

float AlpineFracture(float2 p)
{
    float sum=0,amplitude=1;
    float2 drainage=0;
    [unroll]for(int i=0;i<6;++i)
    {
        float3 n=GeologicalField(p+drainage*.055);
        float ridge=1.0-abs(n.x);
        float2 gradient=-sign(n.x)*n.yz;
        drainage+=gradient*.35;
        float erosion=rcp(1.0+.18*dot(drainage,drainage));
        sum+=amplitude*(ridge*ridge-.48)*erosion;
        p=float2(1.63*p.x-1.24*p.y,1.24*p.x+1.63*p.y)+float2(17.1,9.2);
        drainage=float2(.796*drainage.x-.605*drainage.y,.605*drainage.x+.796*drainage.y);
        amplitude*=.48;
    }
    return sum;
}

// One continuous Alpine height field shared by intersections and grounding.
// All geometry, placement, physics and shadow queries sample the generated
// bilinear field. This authoring function is evaluated once at startup.
float TerrainRaw(float2 xz)
{
    float2 p = xz * 0.00048 + float2(3.7, 8.1);
    float n0 = Noise2(p);
    float n1 = Noise2(p * 2.03 + 5.2);
    float n2 = Noise2(p * 4.17 - 9.4);
    float ridge = 1.0 - abs(2.0 * Noise2(p * 0.83 + 17.0) - 1.0);
    ridge *= ridge;
    float center = ValleyCenter(xz.y);
    float across = abs(xz.x - center);
    float wall = smoothstep(300.0, 2050.0, across);
    float floorY = 88.0 + xz.y * 0.041 + 22.0 * n1;
    float mountain = floorY + 35.0 * n0 + wall * (150.0 + 330.0 * ridge + 80.0 * n2);
    float h = lerp(floorY + 18.0 * n2, mountain, wall);
    float2 rockXZ=xz+float2(n1-.5,n2-.5)*90.0;
    float north=AlpineRidge(rockXZ,float2(0,7790),float2(.985,.173),2800,2380,7.1);
    float west=AlpineRidge(rockXZ,float2(-2660,5730),float2(.12,.99277),1940,1330,31.7);
    float east=AlpineRidge(rockXZ,float2(2680,5900),float2(-.19,.98178),2100,1610,67.2);
    float spur=AlpineRidge(rockXZ,float2(-1830,7330),float2(.685,.72854),1250,1380,93.5);
    float foothillFade=smoothstep(2530,5010,xz.y);
    float peaks=RidgeJoin(north,west*foothillFade,110);
    peaks=RidgeJoin(peaks,east*foothillFade,110);
    peaks=RidgeJoin(peaks,spur,85);
    // Debris and soil blanket the lower shoulders; sharp exposed bedrock is
    // reserved for the high divide. Without this belt every wooded foothill
    // acquired the same saw-tooth normals as a summit cliff.
    float mass=smoothstep(270,1120,peaks);
    // Folded rock relief is stretched along the regional structure, then
    // progressively damped in drainage directions. No radial/angular stripes.
    float2 structural=float2(xz.x*.00175+xz.y*.00037,xz.y*.00231-xz.x*.00028);
    float fracture=AlpineFracture(structural+float2(8.2,37.4));
    float spurs=AlpineFracture(structural*2.7+float2(31.2,11.7));
    h=RidgeJoin(h,floorY+peaks+(fracture*128+spurs*26)*mass,48);
    // Overdeepened U-profile with broad shoulders, changing width through the
    // valley. The downstream terrain keeps its established camera/road levels.
    float glacialWidth=500+120*GeologicalNoise(float2(xz.y*.0008,43.1));
    float u=max(0,across-glacialWidth*.38);
    float trough=floorY+26+.00053*u*u;
    float valleyReach=smoothstep(2620,3800,xz.y)*(1-smoothstep(5000,7970,xz.y));
    h=lerp(h,min(h,trough),valleyReach*.84);
    float town = 1.0 - smoothstep(245.0, 530.0, length((xz - TOWN_C) / float2(0.85, 1.0)));
    h = lerp(h, 145.0 + 3.5 * n2, town * 0.96);
    float2 lq = (xz - LAKE_C) / float2(900.0, 610.0);
    float lr = length(lq)+.035*(GeologicalNoise(xz*.0041)-.5)
        +.016*(GeologicalNoise(xz*.0107+11.0)-.5);
    float lake = 1.0 - smoothstep(0.82, 1.42, lr);
    float basin = LAKE_Y - 2.0 - 48.0 * pow(saturate(1.0 - lr),0.65) + 2.0 * n2;
    // A carved basin with a continuous sloping shoreline. Blending a flat
    // lakebed into a 1km mountain over a narrow ring made an artificial wall.
    float shoreDistance=(lr-.94)*610.0;
    float shoreRise=max(0.0,shoreDistance);
    float valleyCut=basin+shoreRise*.22+.0019*shoreRise*shoreRise;
    float bowl=1.0-smoothstep(1.12,1.72,lr);
    // Close the basin before the finite water solver domain ends. A minimum
    // alone left low valley sectors below water but outside its ellipse.
    float shoreFloor=LAKE_Y+3.0+shoreRise*.12;
    float carved=min(h,valleyCut);
    carved=lerp(carved,max(carved,shoreFloor),smoothstep(.94,1.015,lr));
    h=lerp(h,carved,bowl);
    // Hanging valley with irregular buttresses, a sloping talus apron and one
    // narrow cascade lip. Previously the entire 1.8km ledge rose 240m within
    // ten metres, producing an artificial curtain of parallel columns.
    float fallDistance=abs(xz.x-350.0);
    float fallCore=1-smoothstep(8,22,fallDistance);
    float lip=4908.0+135.0*(GeologicalNoise(float2(xz.x*.0023,17.3))
        -GeologicalNoise(float2(350.0*.0023,17.3)))
        +44.0*(GeologicalNoise(float2(xz.x*.0051,8.1))
        -GeologicalNoise(float2(350.0*.0051,8.1)));
    float shelfWidth=1-smoothstep(180,920,fallDistance);
    float upperRise=smoothstep(lip-lerp(54,4,fallCore),lip+lerp(58,4,fallCore),xz.y);
    float lowerRise=smoothstep(lip-240,lip-30,xz.y);
    float buttress=GeologicalNoise(float2(xz.x*.0051,xz.y*.0029)+float2(41.2,17.1));
    float cragFace=AlpineFracture(float2(xz.x*.007,xz.y*.012)+float2(7.1,53.7));
    float shelf=LAKE_Y+12+90*lowerRise+138*upperRise
        +100*smoothstep(4990,5910,xz.y);
    float irregular=(buttress-.5)*112+cragFace*28;
    // Quiet upper catchment at the physical source; rougher interlocking
    // facets on the surrounding rock, without height-dependent colour bands.
    shelf+=irregular*(1-fallCore*.72);
    float escarpmentWeight=shelfWidth*smoothstep(4660,4860,xz.y)
        *(1-smoothstep(5680,6350,xz.y));
    h=lerp(h,RidgeJoin(h,shelf,25),escarpmentWeight);
    float ledgeFace=escarpmentWeight*sqrt(saturate(4*upperRise*(1-upperRise)));
    float ledgeFracture=(GeologicalNoise(float2(xz.x*.019,xz.y*.033)+11.9)-.5)*38
        +(GeologicalNoise(float2(xz.x*.043,xz.y*.028)+71.1)-.5)*14
        +cragFace*18.0;
    h+=ledgeFace*ledgeFracture*(1-fallCore*.32);
    float gorge=1.0-smoothstep(27.0,91.0,fallDistance);
    gorge*=smoothstep(4590.0,4680.0,xz.y)*(1.0-smoothstep(4878.0,4904.0,xz.y));
    float channel=LAKE_Y-3.0+0.004*max(0.0,xz.y-4650.0);
    h=lerp(h,channel,gorge);
    // Resolved rocky relief, excluded from the village foundations/lake basin.
    // Unlike a colour overlay, these ridges alter silhouettes and intersections.
    float rugged=(1.0-town)*(1.0-lake);
    float crag=GeologicalNoise(xz*.038+float2(11.3,5.7))-.5;
    float talus=GeologicalNoise(xz*.091+float2(27.1,9.8))-.5;
    // No height-modulated noise rows. Metre relief is confined to massifs.
    float joints=1.0-abs(2.0*GeologicalNoise(xz*.011+float2(63.1,12.7))-1.0);
    float blocks=1.0-abs(2.0*GeologicalNoise(xz*.027+float2(7.3,39.2))-1.0);
    float foothillBench=(GeologicalNoise(xz*float2(.0014,.0020)+float2(41.7,19.3))-.5)*11.0;
    h+=rugged*(1.0-gorge)*smoothstep(230.0,520.0,h)*foothillBench;
    h+=rugged*(1.0-gorge)*smoothstep(340.0,780.0,h)*((joints-.62)*12.5+(blocks-.62)*4.8+crag*1.7+talus*.45);
    return h;
}

#if defined(ALPINE_TERRAIN_GENERATOR)
float Terrain(float2 xz){return TerrainRaw(xz);}
#else
Texture2D<float> ProceduralHeight : register(t4);
SamplerState TerrainSampler : register(s1);
float Terrain(float2 xz)
{
    // Generated by TerrainCS at startup. No file texture or external asset is
    // sampled. The half-texel mapping agrees exactly with generation vertices.
    float2 uv=(xz-float2(-6000.0,-1500.0))/12000.0;
    return ProceduralHeight.SampleLevel(TerrainSampler,(uv*(TERRAIN_RES-1.0)+0.5)/TERRAIN_RES,0);
}
#endif

#include "physics_common.hlsli"

int Wrap16(int i)
{
    if(i<0)i+=16;if(i>=16)i-=16;return i;
}

float3 ProceduralGliderCentre(uint id,float seconds)
{
    return PhysicalGliderCentre(id,seconds);
}
void ProceduralGliderPose(uint id,float seconds,out float3 center,out float3 right,out float3 up,out float3 forward)
{
    PhysicalGliderPose(id,seconds,center,right,up,forward);
}

float3 PathPoint(int i)
{
    i=Wrap16(i);
    if(i==0)return float3(-620,420,550);
    if(i==1)return float3(-180,225,1270);
    if(i==2)return float3(0,150,1645);
    if(i==3)return float3(0,151,1756);
    if(i==4)return float3(0,150,1900);
    if(i==5)return float3(360,310,2540);
    if(i==6)return float3(430,910,3650);
    if(i==7)return float3(-180,730,4100);
    if(i==8)return float3(-610,321.8,4340);
    if(i==9)return float3(-650,324,4500);
    if(i==10)return float3(-160,430,4600);
    if(i==11)return float3(-420,740,4780);
    if(i==12)return float3(430,950,3550);
    if(i==13)return float3(820,760,3270);
    if(i==14)return float3(210,650,1870);
    return float3(-650,590,760);
}

float3 FocusPoint(int i)
{
    i=Wrap16(i);
    if(i<=1)return float3(40,410,3350);
    if(i==2)return float3(0,152,1750);
    if(i==3)return float3(0,152,1759);
    if(i==4)return float3(0,152,1764);
    if(i==5)return float3(180,560,3370);
    if(i<=7)return float3(-260,390,4680);
    if(i==8)return float3(200,480,4880);
    if(i<=11)return float3(350,480,4845);
    if(i<=13)return float3(0,390,2850);
    return float3(0,230,1600);
}

float3 Catmull(float3 p0,float3 p1,float3 p2,float3 p3,float t)
{
    float t2=t*t,t3=t2*t;
    return 0.5*((2.0*p1)+(-p0+p2)*t+(2.0*p0-5.0*p1+4.0*p2-p3)*t2+(-p0+3.0*p1-3.0*p2+p3)*t3);
}

float3 SamplePath(float s)
{
    s=fmod(s+32.0,16.0);int i=(int)floor(s);float f=frac(s);
    return Catmull(PathPoint(i-1),PathPoint(i),PathPoint(i+1),PathPoint(i+2),f);
}

float3 SampleFocus(float s)
{
    s=fmod(s+32.0,16.0);int i=(int)floor(s);float f=frac(s);
    return Catmull(FocusPoint(i-1),FocusPoint(i),FocusPoint(i+1),FocusPoint(i+2),f);
}

void Camera(float seconds,out float3 ro,out float3 ta,out float lens,out float roll)
{
    float s=fmod(seconds,128.0)*(16.0/128.0);
    ro=SamplePath(s);ta=SampleFocus(s);
    float village=smoothstep(1.72,2.12,s)*(1.0-smoothstep(4.35,4.78,s));
    // Catmull overshoot otherwise carries the camera through the first row of
    // houses between sampled control points. Keep the walk in the clear lane.
    float streetCenter=0.0;
    ro.x=lerp(ro.x,clamp(ro.x,streetCenter-2.4,streetCenter+2.4),village);
    ro.y=lerp(ro.y,Terrain(ro.xz)+1.62,village);
    // Look along the street outside the portrait. Interpolated landmark Y=147
    // can be below actual ground, and a landmark behind the camera flips it up.
    float2 travel=normalize(SamplePath(s+0.02).xz-SamplePath(s-0.02).xz+float2(0.0001,0));
    float2 ahead=ro.xz+travel*35.0;
    float3 villageAim=float3(ahead.x,Terrain(ahead)+1.62,ahead.y);
    ta=lerp(ta,villageAim,village);
    float loopA=fmod(seconds,128.0)*(TAU/128.0);
    float2 heroC=float2(1.2*sin(loopA*2.0),1750.0+10.0*sin(loopA));
    float3 heroRoot=float3(heroC.x,Terrain(heroC),heroC.y);
    float2 heroForward=normalize(float2(2.4*cos(loopA*2.0),10.0*cos(loopA))+0.001);
    float2 heroRight=float2(-heroForward.y,heroForward.x);
    float3 heroHead=heroRoot+float3(0.0,1.43,0.0);
    float3 roPortrait=heroRoot+float3(+heroForward.x*2.4+heroRight.x*0.68,1.64,
                                      +heroForward.y*2.4+heroRight.y*0.68);
    float portrait=smoothstep(2.45,2.78,s)*(1.0-smoothstep(3.38,3.72,s));
    ro=lerp(ro,roPortrait,portrait);
    ta=lerp(ta,heroHead,portrait);
    // A real tracking shot follows the same flight path as the generated
    // sailplane; it cannot silently look past the actors after terrain edits.
    float3 glider,right,up,forward;
    ProceduralGliderPose(0,seconds,glider,right,up,forward);
    float tracking=smoothstep(10.9,11.65,s)*(1.0-smoothstep(12.8,13.4,s));
    ro=lerp(ro,glider-forward*43.0+right*24.0+float3(0,13,0),tracking);
    ta=lerp(ta,glider+forward*5.0,tracking);
    float3 tangent0=normalize(ro-SamplePath(s-0.025)+float3(0.0001,0,0));
    float3 tangent1=normalize(SamplePath(s+0.025)-ro+float3(0.0001,0,0));
    float turn=dot(cross(tangent0,tangent1),float3(0,1,0));
    roll=lerp(clamp(-turn*0.55,-0.025,0.025),0.003*sin(loopA*11.0),village);
    roll=lerp(roll,0.002*sin(loopA*11.0),portrait);
    lens=lerp(2.20+0.10*sin(loopA*3.0),3.8,portrait);
    ro.y+=lerp(2.0*sin(loopA*8.0),0.018*sin(loopA*35.0),village);
    float lowLake=smoothstep(7.65,7.9,s)*(1.0-smoothstep(9.15,9.55,s));
    float clearance=lerp(70.0,0.8,max(village,lowLake));
    ro.y=max(ro.y,Terrain(ro.xz)+clearance);
    // Catmull-Rom overshoot between low lake shots can put the camera below
    // the surface even though it clears the lakebed. The validated numerical
    // wave envelope is below0.25m; leave an eye-height1.65m above the plane.
    if(length((ro.xz-LAKE_C)/float2(900.0,610.0))<1.05)
        ro.y=max(ro.y,LAKE_Y+1.65);
}

float2 TemporalJitter(int phase)
{
    if(phase==0)return float2( 0.000000,-0.166667);
    if(phase==1)return float2(-0.250000, 0.166667);
    if(phase==2)return float2( 0.250000,-0.388889);
    if(phase==3)return float2(-0.375000,-0.055556);
    if(phase==4)return float2( 0.125000, 0.277778);
    if(phase==5)return float2(-0.125000,-0.277778);
    if(phase==6)return float2( 0.375000, 0.055556);
    return float2(-0.437500,0.388889);
}


struct CameraFrame
{
    float3 origin;
    float3 forward;
    float3 right;
    float3 up;
    float lens;
};

CameraFrame GetCameraFrame(float seconds)
{
    CameraFrame c;
    float3 target; float roll;
    Camera(seconds,c.origin,target,c.lens,roll);
    c.forward=normalize(target-c.origin);
    float3 r=normalize(cross(float3(0,1,0),c.forward));
    float3 u=cross(c.forward,r);
    c.right=r*cos(roll)+u*sin(roll);
    c.up=u*cos(roll)-r*sin(roll);
    return c;
}

CameraFrame MirrorLakeCamera(CameraFrame c)
{
    c.origin.y=2.0*LAKE_Y-c.origin.y;
    c.forward.y=-c.forward.y;c.right.y=-c.right.y;c.up.y=-c.up.y;
    return c;
}
CameraFrame PassCameraFrame(CameraFrame c)
{
    if(PassMode.x>0.5)c=MirrorLakeCamera(c);
    return c;
}

float3 CameraRay(CameraFrame c,float2 uv,float aspect)
{
    float2 q=uv*2.0-1.0;
    return normalize(c.forward*c.lens+c.right*(q.x*aspect)-c.up*q.y);
}

float2 ProjectCamera(CameraFrame c,float3 world,float aspect,out float viewZ)
{
    float3 delta=world-c.origin;
    viewZ=dot(delta,c.forward);
    float2 q=float2(dot(delta,c.right)/aspect,-dot(delta,c.up))*c.lens/max(viewZ,1e-5);
    return q*0.5+0.5;
}

float EncodeDepth(float rayT)
{
    return max(1e-4,log2(1.0+min(rayT,MAX_DIST)*DEPTH_K)/log2(1.0+MAX_DIST*DEPTH_K));
}
float DecodeDepth(float depth)
{
    return (exp2(saturate(abs(depth))*log2(1.0+MAX_DIST*DEPTH_K))-1.0)/DEPTH_K;
}

#endif

