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

// One continuous Alpine height field shared by intersections and grounding.
// Tracing uses finite steps and refinement; no mathematical watertight guarantee.
float Terrain(float2 xz)
{
    float2 p = xz * 0.00048 + float2(3.7, 8.1);
    float n0 = Noise2(p);
    float n1 = Noise2(p * 2.03 + 5.2);
    float n2 = Noise2(p * 4.17 - 9.4);
    float ridge = 1.0 - abs(2.0 * Noise2(p * 0.83 + 17.0) - 1.0);
    ridge *= ridge;
    float center = ValleyCenter(xz.y);
    float across = abs(xz.x - center);
    float wall = smoothstep(220.0, 1650.0, across);
    float floorY = 88.0 + xz.y * 0.041 + 22.0 * n1;
    float mountain = floorY + 130.0 * n0 + wall * (280.0 + 760.0 * ridge + 160.0 * n2);
    float h = lerp(floorY + 18.0 * n2, mountain, wall);
    float2 mq = (xz - float2(80.0, 6200.0)) / float2(1200.0, 900.0);
    h += 780.0 * exp(-dot(mq, mq)) * (0.45 + 0.55 * ridge);
    float town = 1.0 - smoothstep(390.0, 670.0, length((xz - TOWN_C) / float2(1.15, 1.0)));
    h = lerp(h, 145.0 + 3.5 * n2, town * 0.96);
    float2 lq = (xz - LAKE_C) / float2(900.0, 610.0);
    float lr = length(lq);
    float lake = 1.0 - smoothstep(0.78, 1.08, lr);
    float basin = LAKE_Y - 17.0 - 34.0 * saturate(1.0 - lr) + 3.0 * n2;
    h = lerp(h, min(h, basin), lake);
    float cliffGate = exp(-pow((xz.x - 350.0) / 720.0, 2.0));
    cliffGate *= smoothstep(4750.0, 5000.0, xz.y) * (1.0 - smoothstep(6400.0, 7400.0, xz.y));
    float plateau = 330.0 + 430.0 * smoothstep(5020.0, 5200.0, xz.y);
    h = lerp(h, max(h, plateau + 24.0 * n1), cliffGate * 0.88);
    // Resolved rocky relief, excluded from the village foundations/lake basin.
    // Unlike a colour overlay, these ridges alter silhouettes and intersections.
    float rugged=(1.0-town)*(1.0-lake);
    float2 erosionUV=float2(xz.x*0.031,xz.y*0.011+h*0.008);
    float ledges=1.0-abs(2.0*Noise2(erosionUV+float2(11.3,5.7))-1.0);
    float talus=Noise2(xz*0.074+float2(27.1,9.8))-0.5;
    float snowSoftening=1.0-0.72*smoothstep(570.0,800.0,h);
    h+=rugged*snowSoftening*((ledges-0.5)*(5.0+11.0*wall)+talus*2.0);
    return h;
}


int Wrap16(int i)
{
    if(i<0)i+=16;if(i>=16)i-=16;return i;
}

float3 PathPoint(int i)
{
    i=Wrap16(i);
    if(i==0)return float3(-900,520,250);
    if(i==1)return float3(-420,260,1050);
    if(i==2)return float3(18,150,1580);
    if(i==3)return float3(21,147,1756);
    if(i==4)return float3(18,150,1930);
    if(i==5)return float3(360,310,2540);
    if(i==6)return float3(430,910,3650);
    if(i==7)return float3(-180,730,4100);
    if(i==8)return float3(-700,390,4370);
    if(i==9)return float3(-160,410,4740);
    if(i==10)return float3(330,500,4960);
    if(i==11)return float3(720,930,5450);
    if(i==12)return float3(1080,920,4550);
    if(i==13)return float3(820,760,3270);
    if(i==14)return float3(210,650,1870);
    return float3(-650,590,760);
}

float3 FocusPoint(int i)
{
    i=Wrap16(i);
    if(i<=1)return float3(40,410,3350);
    if(i==2)return float3(24,147,1750);
    if(i==3)return float3(25,147,1759);
    if(i==4)return float3(22,147,1764);
    if(i==5)return float3(180,560,3370);
    if(i<=8)return float3(-260,325,4220);
    if(i<=11)return float3(350,500,5105);
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
    float streetCenter=12.0*sin(ro.z*0.006);
    ro.x=lerp(ro.x,clamp(ro.x,streetCenter-22.0,streetCenter+22.0),village);
    ro.y=lerp(ro.y,Terrain(ro.xz)+1.62,village);
    // Look along the street outside the portrait. Interpolated landmark Y=147
    // can be below actual ground, and a landmark behind the camera flips it up.
    float2 travel=normalize(SamplePath(s+0.02).xz-SamplePath(s-0.02).xz+float2(0.0001,0));
    float2 ahead=ro.xz+travel*35.0;
    float3 villageAim=float3(ahead.x,Terrain(ahead)+1.62,ahead.y);
    ta=lerp(ta,villageAim,village);
    float loopA=fmod(seconds,128.0)*(TAU/128.0);
    float2 heroC=float2(22.0+4.0*sin(loopA*2.0),1750.0+10.0*sin(loopA));
    float3 heroRoot=float3(heroC.x,Terrain(heroC),heroC.y);
    float2 heroForward=normalize(float2(8.0*cos(loopA*2.0),10.0*cos(loopA))+0.001);
    float2 heroRight=float2(-heroForward.y,heroForward.x);
    float3 heroHead=heroRoot+float3(0.0,1.64,0.0);
    float3 roPortrait=heroRoot+float3(+heroForward.x*1.12+heroRight.x*0.44,1.64,
                                      +heroForward.y*1.12+heroRight.y*0.44);
    float portrait=smoothstep(2.45,2.78,s)*(1.0-smoothstep(3.38,3.72,s));
    ro=lerp(ro,roPortrait,portrait);
    ta=lerp(ta,heroHead,portrait);
    float3 tangent0=normalize(ro-SamplePath(s-0.025)+float3(0.0001,0,0));
    float3 tangent1=normalize(SamplePath(s+0.025)-ro+float3(0.0001,0,0));
    float turn=dot(cross(tangent0,tangent1),float3(0,1,0));
    roll=lerp(clamp(-turn*5.5,-0.24,0.24),0.006*sin(loopA*11.0),village);
    roll=lerp(roll,0.012*sin(loopA*11.0),portrait);
    lens=1.72+0.15*sin((s/16.0)*TAU*3.0)+0.08*sin((s/16.0)*TAU*5.0);
    ro.y+=lerp(2.0*sin(loopA*8.0),0.018*sin(loopA*35.0),village);
    ro.y=max(ro.y,Terrain(ro.xz)+0.8);
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

