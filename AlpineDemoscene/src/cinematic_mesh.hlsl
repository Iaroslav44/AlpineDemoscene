// Runtime geometry: no vertex buffers, imported meshes or bitmap textures.
// DrawInstanced(vertices, instances, 0, 0), with absolute type base in Batch.x:
// houses 11520,64,0; firs 15624,192,1000; grass48,12288,2000;
// rocks240,384,20000; gliders12288,4,30000. All entry points target SM5.
#include "cinematic_lighting.hlsli"
#include "physics_common.hlsli"
#include "people_motion.hlsli"
#include "material_common.hlsli"
#include "geomorph_common.hlsli"
cbuffer Frame : register(b0) { float4 G; float4 G2; };
// SM5 SV_InstanceID starts at zero for each draw. StartInstanceLocation only
// offsets instance-buffer fetches; it DOES NOT offset this system value.
cbuffer DrawBatch : register(b1) { uint4 Batch; };
RWStructuredBuffer<float4> FrameOutput : register(u0);
// SceneInstancesCS writes this table once after CameraCS; draw passes only read it.
// 31,360 objects have two float4 records each: house0, near tree64,
// far tree256, grass18688, rock30976. Record62720 begins96 branch wind
// records for each of192 near trees. Tree records end at118016;576 resident-rig records follow.
// Dispatch779 groups of64 (49,856 threads). Unbindt12 before its UAV is bound.
StructuredBuffer<float4> SceneInstanceData : register(t12);
float LoopAngle(){return fmod(G.z,128.0)*(TAU/128.0);}

float2 PlantDeflection(float3 root,float mass,float omega0,float dampingRatio,float area)
{
    // Steady response of m*x'' + c*x' + k*x = Fwind for the SAME harmonic
    // wind used by flight/water. Drag is linearized around the mean wind.
    // SI units: kg, rad/s, N/m, m². This is a reduced-order flexible beam,
    // not a per-vertex noise animation or a full tree FEM solver.
    float2 mean=float2(3.2,1.2);float speed=length(mean);
    float stiffness=mass*omega0*omega0,damping=2.0*dampingRatio*mass*omega0;
    float drag=.5*1.10*.8*area;
    float2 displacement=drag*speed*mean/stiffness;
    [unroll]for(uint harmonic=0;harmonic<3;++harmonic)
    {
        float4 gust=PhysicalWindGust(harmonic,root,G.z);
        float omega=PhysicalWindOmega(harmonic),re=stiffness-mass*omega*omega,im=damping*omega;
        float2 force=drag*(speed*gust.xz+mean*dot(mean,gust.xz)/speed);
        displacement+=force*(re*sin(gust.w)-im*cos(gust.w))/max(re*re+im*im,1e-7);
    }
    return displacement;
}

#include "ecology_generation.hlsli"

[numthreads(1,1,1)]
void CameraCS(uint3 id:SV_DispatchThreadID)
{
    CameraFrame c=GetCameraFrame(G.z),p=GetCameraFrame(G2.w);
    FrameOutput[0]=float4(c.origin,c.lens);FrameOutput[1]=float4(c.forward,0);
    FrameOutput[2]=float4(c.right,G.x/G.y);FrameOutput[3]=float4(c.up,0.10);
    FrameOutput[4]=float4(p.origin,p.lens);FrameOutput[5]=float4(p.forward,0);
    FrameOutput[6]=float4(p.right,0);FrameOutput[7]=float4(p.up,0);
    float3 sun=CinematicSunDirection(fmod(G.z,128.0)*TAU/128.0);
    float3 sr=normalize(cross(float3(0,1,0),-sun)),su=cross(-sun,sr);
    float village=(1.0-smoothstep(245.0,410.0,length(c.origin.xz-TOWN_C)))*
                  (1.0-smoothstep(16.0,58.0,c.origin.y-Terrain(c.origin.xz)));
    float extent=lerp(215.0,72.0,village),texel=2.0*extent/2048.0;
    float3 center=c.origin+c.forward*lerp(82.0,26.0,village);
    center.y=Terrain(center.xz)+24.0;
    // Snap light-space origin, not just world X/Z: static surfaces remain stable.
    center+=sr*(floor(dot(center,sr)/texel)*texel-dot(center,sr));
    center+=su*(floor(dot(center,su)/texel)*texel-dot(center,su));
    FrameOutput[8]=float4(sun,3.2);FrameOutput[9]=float4(center,1.0/2048.0);
    FrameOutput[10]=float4(sr,extent);FrameOutput[11]=float4(su,2000.0);
    float farExtent=1800.0,farTexel=2.0*farExtent/1024.0;
    float3 farCenter=c.origin+c.forward*900.0;
    farCenter.y=Terrain(farCenter.xz)+250.0;
    farCenter+=sr*(floor(dot(farCenter,sr)/farTexel)*farTexel-dot(farCenter,sr));
    farCenter+=su*(floor(dot(farCenter,su)/farTexel)*farTexel-dot(farCenter,su));
    FrameOutput[12]=float4(farCenter,1.0/1024.0);
    FrameOutput[13]=float4(sr,farExtent);FrameOutput[14]=float4(su,4000.0);
}

struct Geometry { float3 p; float3 n; float2 uv; float3 local; float material; float seed; float moving; float3 learnedColor; };
struct MeshOut
{
    float4 position:SV_POSITION;
    float3 world:TEXCOORD0;
    float3 normal:TEXCOORD1;
    float2 uv:TEXCOORD2;
    float3 local:TEXCOORD3;
    nointerpolation float3 tag:TEXCOORD4; // material, seed, dynamic
    float3 learnedColor:TEXCOORD5;
    float clipDistance:SV_ClipDistance0;
};
float2 Corner(uint i)
{
    i%=6;
    if(i==0||i==3)return float2(0,0);
    if(i==1)return float2(1,0);
    if(i==2||i==4)return float2(1,1);
    return float2(0,1);
}
void Cube(uint vertex,out float3 p,out float3 n,out float2 uv)
{
    uv=Corner(vertex);float2 q=uv*2.0-1.0;uint face=vertex/6;
    if(face==0){p=float3(1,q.y,-q.x);n=float3(1,0,0);}
    else if(face==1){p=float3(-1,q.y,q.x);n=float3(-1,0,0);}
    else if(face==2){p=float3(q.x,1,-q.y);n=float3(0,1,0);}
    else if(face==3){p=float3(q.x,-1,q.y);n=float3(0,-1,0);}
    else if(face==4){p=float3(q.x,q.y,1);n=float3(0,0,1);}
    else{p=float3(-q.x,q.y,-1);n=float3(0,0,-1);}
}
float3 RotateY(float3 p,float a){float s=sin(a),c=cos(a);return float3(c*p.x+s*p.z,p.y,-s*p.x+c*p.z);}
float3 RotateZ(float3 p,float a){float s=sin(a),c=cos(a);return float3(c*p.x-s*p.y,s*p.x+c*p.y,p.z);}
void Box(uint v,float3 center,float3 halfSize,inout Geometry g)
{
    Cube(v,g.p,g.n,g.uv);g.p=g.p*halfSize+center;
}
void Cylinder(uint v,uint sides,float3 a,float3 b,float radius,inout Geometry g)
{
    float2 uv=Corner(v);float angle=(floor(v/6.0)+uv.x)*TAU/sides;
    float3 axis=normalize(b-a),r=normalize(cross(axis,abs(axis.y)<0.94?float3(0,1,0):float3(1,0,0))),u=cross(axis,r);
    float3 normal=r*cos(angle)+u*sin(angle);
    g.p=lerp(a,b,uv.y)+normal*radius*(1.0-uv.y*0.95);g.n=normal;g.uv=uv;
}
void Gable(uint v,float width,float rise,float depth,float base,inout Geometry g)
{
    uint tri=v/3,k=v%3;float3 a,b,c;
    float3 lf=float3(-width,base,depth),rf=float3(width,base,depth),tf=float3(0,base+rise,depth);
    float3 lb=float3(-width,base,-depth),rb=float3(width,base,-depth),tb=float3(0,base+rise,-depth);
    if(tri==0){a=lf;b=rf;c=tf;}else if(tri==1){a=rb;b=lb;c=tb;}
    else if(tri==2){a=lf;b=tf;c=tb;}else if(tri==3){a=lf;b=tb;c=lb;}
    else if(tri==4){a=tf;b=rf;c=rb;}else if(tri==5){a=tf;b=rb;c=tb;}
    else if(tri==6){a=lb;b=rb;c=rf;}else if(tri==7){a=lb;b=rf;c=lf;}
    else{a=b=c=lf;}
    g.p=k==0?a:(k==1?b:c);float3 n=cross(b-a,c-a);g.n=n*rsqrt(max(dot(n,n),1e-8));g.uv=g.p.xy;
}
#include "settlement_geometry.hlsli"
#include "neural_resident.hlsli"
#include "ecology_geometry.hlsli"
void TreePlacementRaw(uint id,out float3 center,out float height,out float seed,out float survival)
{
    seed=Hash21(float2(id,111));
    if(id<32)seed*=.74; // village street & chalet yard conifers are evergreen spruce/pine/fir
    float2 xz;
    if(id<16)xz=float2((id%2==0?-1:1)*(8.2+seed*.8),1668.0+floor(id/2.0)*39.0+Hash21(float2(id,119))*7.0);
    else if(id<96)xz=float2((id%2==0?-1:1)*(64.0+seed*75.0),1570.0+Hash21(float2(id,112))*445.0);
    else
    {
        float a=(id-96)*2.39996323;float r=0.98+seed*0.20;
        xz=LAKE_C+float2(cos(a)*930.0,sin(a)*650.0)*r;
    }
    center=float3(xz.x,Terrain(xz)-0.08,xz.y);
    height=id<16?8.0+Hash21(float2(id,117))*5.0:12.0+Hash21(float2(id,117))*15.0;
    float2 gradient=float2(Terrain(xz+float2(3,0))-Terrain(xz-float2(3,0)),Terrain(xz+float2(0,3))-Terrain(xz-float2(0,3)))/6;
    EcologyAdjustPlacement(id,center,gradient,WorldEcology(xz),height,seed,survival);
    if(id<16)survival=1;
}
void TreePlacement(uint id,out float3 center,out float height,out float seed)
{
    float4 a=SceneInstanceData[(64+id)*2],b=SceneInstanceData[(64+id)*2+1];
    center=a.xyz;height=a.w;seed=b.x;
}
void NearTreeBranch(uint segment,uint id,float height,float seed,out float3 start,out float3 end,out float branchSeed)
{
    float tier=segment/95.0;branchSeed=Hash21(float2(segment,id+9));
    float y=(0.16+tier*0.80+(branchSeed-0.5)*0.016)*height;
    float a=segment*2.39996323+seed*TAU;
    float len=pow(saturate(1.0-y/height),0.72)*(3.0+height*0.10)*(0.66+branchSeed*0.40);
    start=float3(0,y,0);end=float3(cos(a)*len,y-len*(0.12+branchSeed*0.17),sin(a)*len);
}
Geometry TreeGeometry(uint v,uint id)
{
    return EcologyNearTreeGeometry(v,id);
}
void GrassPlacementRaw(uint id,out float3 center,out float seed,out float valid)
{
    float2 cell=float2(id%128,id/128)-float2(64,48)+floor(CinematicFrame[0].xz/.72);
    seed=Hash21(cell);float2 xz=(cell+float2(seed,Hash21(cell+73.0)))*.72;
    float ground=Terrain(xz);center=float3(xz.x,ground-.015,xz.y);
    bool road=(abs(xz.x)<3.85||length(xz-float2(0,1755))<10.35)&&xz.y>1600.0&&xz.y<2020.0;
    bool water=ground<LAKE_Y+.4&&length((xz-LAKE_C)/float2(930,650))<1.1;
    valid=(!road&&!water&&ground<=680.0&&length(center-CinematicFrame[0].xyz)<=84.0)?1.0:0.0;
}
Geometry GrassGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=22;g.moving=1;
    float4 placement=SceneInstanceData[(18688+id)*2],motion=SceneInstanceData[(18688+id)*2+1];
    float seed=placement.w;g.seed=seed;float3 origin=placement.xyz;
    float2 cell=floor(origin.xz/.72);
    uint blade=v/12,segment=(v%12)/6;float2 uv=Corner(v);uv.y=(segment+uv.y)*.5;
    float a=seed*TAU+blade*2.39996323,height=.12+Hash21(cell+blade*19.0)*.27;
    float3 right=float3(cos(a),0,sin(a));float2 deflection=motion.xy*height;
    float3 bend=float3(deflection.x,0,deflection.y)+float3(sin(a),0,-cos(a))*height*.22;
    float2 tuftOffset=float2(cos(a),sin(a))*(.07+.07*seed);
    g.p=origin+float3(tuftOffset.x,0,tuftOffset.y)+right*((uv.x-.5)*(.019+seed*.015)*(1.0-uv.y*.97))+float3(0,uv.y*height,0)+bend*uv.y*uv.y;
    g.n=normalize(cross(right,float3(0,height,0)+bend*2.0*uv.y));g.uv=uv;g.local=g.p-origin;
    if(motion.z<.5)g.p=origin;
    return g;
}
void RockPlacementRaw(uint id,out float3 center,out float size,out float seed)
{
    seed=Hash21(float2(id,211));
    float2 xz;
    if(id<160)xz=float2((id%2==0?-1:1)*(5.0+seed*100.0),1600+Hash21(float2(id,213))*430.0);
    else
    {
        float a=id*2.39996323,r=0.87+seed*0.22;
        xz=LAKE_C+float2(cos(a)*930,sin(a)*650)*r;
    }
    size=0.24+pow(seed,3.0)*2.8;
    float2 gradient=float2(Terrain(xz+float2(3,0))-Terrain(xz-float2(3,0)),Terrain(xz+float2(0,3))-Terrain(xz-float2(0,3)))/6;
    float burial;EcologyAdjustRock(WorldEcology(xz),gradient,size,burial);
    center=float3(xz.x,Terrain(xz)-size*burial,xz.y);
}
Geometry RockGeometry(uint v,uint id)
{
    return EcologyRockGeometry(v,id);
}
float2 SurfaceGrid(uint v,uint columns,uint rows)
{
    uint patch=v/6;
    return (float2(patch%columns,patch/columns)+Corner(v))/float2(columns,rows);
}
float AirfoilThickness(float x,float ratio)
{
    // Closed trailing-edge NACA four-digit thickness distribution. The wing
    // has an actual rounded leading edge and upper/lower surfaces, not a box.
    x=saturate(x);
    return 5.0*ratio*(.2969*sqrt(x)-.1260*x-.3516*x*x+.2843*x*x*x-.1036*x*x*x*x);
}
float3 GliderSurface(uint section,float2 uv)
{
    float u=uv.x,a=uv.y*TAU;
    if(section==0)
    {
        float z=lerp(-3.5,3.3,u);
        float r=lerp(.055,.30,smoothstep(.14,.69,u))*sqrt(max(0.0,sin(u*PI)));
        float cy=.018+.075*smoothstep(.43,.76,u);
        return float3(cos(a)*r,sin(a)*r*.89+cy,z);
    }
    float chordX=(1.0-cos(a))*.5;
    float signY=sin(a)>=0.0?1.0:-1.0;
    if(section==1||section==2)
    {
        float side=section==1?-1.0:1.0;
        float winglet=smoothstep(.94,1.0,u);
        float chord=lerp(.86,.36,u)*sqrt(saturate((1.0-u)*32.0));
        float thickness=AirfoilThickness(chordX,lerp(.135,.105,u))*chord;
        float camber=.018*4.0*chordX*(1.0-chordX)*chord;
        return float3(side*(u*9.24-.24*winglet),.12+u*.315+winglet*.62+camber+signY*thickness,
                      -.10-.32*pow(u,1.4)+chord*(.38-chordX));
    }
    if(section==3||section==4)
    {
        float side=section==3?-1.0:1.0;
        float chord=lerp(.55,.29,u)*sqrt(saturate((1.0-u)*24.0));
        return float3(side*u*1.55,1.30+u*.025+signY*AirfoilThickness(chordX,.10)*chord,
                      -2.80-u*.12+chord*(.40-chordX));
    }
    float chord=lerp(.88,.42,u)*sqrt(saturate((1.0-u)*32.0));
    return float3(signY*AirfoilThickness(chordX,.12)*chord,.13+u*1.19,
                  -2.53-u*.30+chord*(.40-chordX));
}
void GliderParametric(uint v,uint columns,uint rows,uint section,inout Geometry g)
{
    float2 uv=SurfaceGrid(v,columns,rows);g.p=GliderSurface(section,uv);g.uv=uv;
    float e=.0005;
    float3 du=GliderSurface(section,float2(min(1.0,uv.x+e),uv.y))-GliderSurface(section,float2(max(0.0,uv.x-e),uv.y));
    float3 dv=GliderSurface(section,float2(uv.x,uv.y+e))-GliderSurface(section,float2(uv.x,uv.y-e));
    float a=uv.y*TAU;
    float3 hint=section==0?float3(cos(a),sin(a),0):(section==5?float3(sin(a),0,cos(a)):float3(0,sin(a),cos(a)));
    float3 n=cross(du,dv);
    if(dot(n,n)<1e-14)n=section==0?float3(0,0,uv.x<.5?-1:1):hint;
    n*=rsqrt(max(dot(n,n),1e-14));g.n=dot(n,hint)<0.0?-n:n;
}
Geometry GliderGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=30;g.moving=1;g.seed=(float)id;
    float3 center,rr,uu,forward;
    ProceduralGliderPose(id,G.z,center,rr,uu,forward);
    if(v<3072)GliderParametric(v,32,16,0,g);
    else if(v<7680)
    {
        uint q=v-3072;GliderParametric(q%2304,32,12,1+q/2304,g);
    }
    else if(v<8832){uint q=v-7680;GliderParametric(q%576,12,8,3+q/576,g);}
    else if(v<9408)GliderParametric(v-8832,12,8,5,g);
    else if(v<11712)
    {
        float2 uv=SurfaceGrid(v-9408,16,24);float a=uv.x*PI*.5,b=uv.y*TAU;
        float3 sphere=float3(sin(a)*cos(b),cos(a),sin(a)*sin(b));
        float3 radius=float3(.282,.355,1.08);
        g.p=float3(0,.24,1.27)+sphere*radius;g.n=normalize(sphere/radius);g.uv=uv;g.material=31;
    }
    else
    {
        float2 uv=SurfaceGrid(v-11712,8,12);float a=uv.x*PI,b=uv.y*TAU;
        float3 sphere=float3(sin(a)*cos(b),cos(a),sin(a)*sin(b));
        float3 radius=float3(.085,.115,.095);
        g.p=float3(0,.42,1.30)+sphere*radius;g.n=normalize(sphere/radius);g.uv=uv;g.material=32;
    }
    g.local=g.p;g.p=center+rr*g.p.x+uu*g.p.y+forward*g.p.z;g.n=normalize(rr*g.n.x+uu*g.n.y+forward*g.n.z);return g;
}
void ForestPlacementRaw(uint id,out float3 center,out float height,out float seed,out float ground,out float survival)
{
    seed=Hash21(float2(id,317));
    float2 xz;
    if(id<6000)
    {
        float a=id*2.39996323;
        float2 direction=float2(cos(a),sin(a));
        float edge=.99+.034*sin(a*3.0)+.022*sin(a*7.0);
        float width=.25+.065*sin(a*5.0+1.7);
        float edgeNoise=(Noise2(direction*4.3+17.0)-.5)*.085;
        width+=edgeNoise;
        float r=sqrt(lerp(edge*edge,(edge+width)*(edge+width),Hash21(float2(id,323))));
        if(Hash21(float2(id,337))<.20)
        {
            // A half-normal woodland fringe keeps a dense core while sparse
            // young stands extend around 120m past its irregular outer edge.
            float gaussian=abs(sqrt(-2.0*log(max(.008,Hash21(float2(id,339)))))*cos(TAU*Hash21(float2(id,341))));
            r=edge+width-.022+min(2.8,gaussian)*.085;
        }
        xz=LAKE_C+direction*float2(900.0,610.0)*r;
    }
    else if(id<12912)
    {
        uint k=id-6000;float z=860.0+Hash21(float2(k,322))*3680.0;
        // Keep chalet parcels open at z=1580..2030 while letting woodland groves
        // sweep across the foothills north and south of the village.
        float inTown=(smoothstep(1545.0,1625.0,z))*(1.0-smoothstep(2005.0,2080.0,z));
        float groveGap=smoothstep(.35,.72,Noise2(float2(z*.0048,19.3)));
        float edge=lerp(10.0+46.0*groveGap,194.0,inTown)+18.0*sin(z*.006)+(Noise2(float2(z*.004,11.0))-.5)*28.0;
        edge=max(edge,lerp(6.0,185.0,inTown));
        float width=lerp(580.0,235.0,inTown)+85.0*sin(z*.0038+1.3),offset=edge+seed*width;
        float fringe=Hash21(float2(k,343));
        float gaussian=abs(sqrt(-2.0*log(max(.008,Hash21(float2(k,347)))))*cos(TAU*Hash21(float2(k,349))));
        if(fringe<.22)offset=edge+width-22.0+min(2.8,gaussian)*110.0;
        else if(fringe>.95)offset=max(lerp(4.0,182.0,inTown),edge-gaussian*26.0);
        float x=ValleyCenter(z)+(k%2==0?-1.0:1.0)*offset;
        xz=float2(x,z);
    }
    else
    {
        // Colonies on the lower mountain shoulders break the former uniform
        // ring of trees. Stratified trees form irregular overlapping groves,
        // spanning both the lake amphitheatre and village backdrop slopes.
        uint k=id-12912,colony=k/48,member=k%48;
        float ca=TAU*Hash21(float2(colony,411));
        float2 colonyCentre;
        if(colony<45)
        {
            float radius=1.16+1.20*Hash21(float2(colony,413));
            colonyCentre=LAKE_C+float2(cos(ca)*930.0,sin(ca)*660.0)*radius;
        }
        else
        {
            float z=960.0+Hash21(float2(colony,417))*5660.0;
            float offset=395.0+Hash21(float2(colony,419))*1280.0;
            colonyCentre=float2(ValleyCenter(z)+(colony%2==0?-offset:offset),z);
        }
        float radius=72.0+Hash21(float2(colony,421))*115.0;
        float angle=member*2.39996323+ca;
        float r=sqrt((member+.2+.6*seed)/48.0)*radius;
        xz=colonyCentre+float2(cos(angle),sin(angle))*r;
        xz+=float2(Hash21(float2(k,423)),Hash21(float2(k,427)))*8.0-4.0;
    }
    ground=Terrain(xz);
    height=(16.0+seed*15.0)*lerp(1.0,.47,smoothstep(1350.0,1900.0,ground));
    center=float3(xz.x,ground-0.05,xz.y);
    float2 gradient=float2(Terrain(xz+float2(3,0))-Terrain(xz-float2(3,0)),Terrain(xz+float2(0,3))-Terrain(xz-float2(0,3)))/6;
    EcologyAdjustPlacement(id+192,center,gradient,WorldEcology(xz),height,seed,survival);
}
void ForestPlacement(uint id,out float3 center,out float height,out float seed,out float ground)
{
    float4 a=SceneInstanceData[(256+id)*2],b=SceneInstanceData[(256+id)*2+1];
    center=a.xyz;height=a.w;seed=b.x;ground=center.y+.05;
}
[numthreads(64,1,1)]
void SceneInstancesCS(uint3 thread:SV_DispatchThreadID)
{
    uint id=thread.x;float4 a=0,b=0;
    if(id>=49792){if(id<49798)NeuralWriteResidentRig(id-49792,G.z);return;}
    // Never call the cached wrappers here: t12 is unbound while u0 writes it.
    if(id>=31360)
    {
        uint k=id-31360,tree=k/96,segment=k%96;
        if(tree>=192)return;
        float3 center;float height,seed,survival;
        TreePlacementRaw(tree,center,height,seed,survival);
        EcologyStoreBranch(tree,segment,center,height,seed);return;
    }
    if(id<64)
    {
        float3 center,size;float angle,seed;
        HousePlacementRaw(id,center,size,angle,seed);
        a=float4(center,angle);b=float4(size,seed);
    }
    else if(id<18688)
    {
        float3 center;float height,seed,ground,valid=1.0;
        if(id<256)
        {
            TreePlacementRaw(id-64,center,height,seed,valid);ground=center.y;
            bool inFall=abs(center.x-350.0)<98.0&&center.z>4580.0&&center.z<4970.0;
            if(ground>930.0||inFall||(ground<LAKE_Y+.9&&length((center.xz-LAKE_C)/float2(972,692))<1.085))valid=0;
        }
        else
        {
            ForestPlacementRaw(id-256,center,height,seed,ground,valid);
            float2 xz=center.xz;
            float slope=length(float2(Terrain(xz+float2(3,0))-Terrain(xz-float2(3,0)),Terrain(xz+float2(0,3))-Terrain(xz-float2(0,3))))/6.0;
            float treeline=1.0-smoothstep(1400.0,1830.0,ground+(Noise2(xz*.004)-.5)*180.0);
            bool inFall=abs(xz.x-350.0)<98.0&&xz.y>4580.0&&xz.y<4970.0;
            bool inTownOpen=(abs(xz.x)<182.0&&xz.y>1565.0&&xz.y<2035.0);
            if(ground<118.0||slope>1.25||inFall||inTownOpen||Hash21(float2(id,431))>treeline||
                (ground<LAKE_Y+1.4&&length((xz-LAKE_C)/float2(975,695))<1.09))valid=0;
        }
        float2 wind=PlantDeflection(center,.20*height*height,2.6*20.0/height,.22,.7*height);
        a=float4(center,height);b=float4(seed,wind,valid);
    }
    else if(id<30976)
    {
        float3 center;float seed,valid;
        GrassPlacementRaw(id-18688,center,seed,valid);
        float2 wind=PlantDeflection(center,.0015,22.0,.35,.012/.4);
        a=float4(center,seed);b=float4(wind,valid,0);
    }
    else
    {
        float3 center;float size,seed;RockPlacementRaw(id-30976,center,size,seed);
        a=float4(center,size);b=float4(float3(1.0,.65+seed*.43,.71+seed*.41)*size,seed);
    }
    FrameOutput[id*2]=a;FrameOutput[id*2+1]=b;
}
Geometry ForestGeometry(uint v,uint id)
{
    return EcologyForestGeometry(v,id);
}
Geometry CoarseNearTreeGeometry(uint v,uint id)
{
    return EcologyCoarseNearTreeGeometry(v,id);
}
Geometry PersonShadowGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=30;g.moving=1;
    uint part=v/72,q=v%72;float3 c=0,b=float3(0.1,0.1,0.1);
    float2 velocity=PeopleVelocity(id,G.z);float speed=length(velocity);
    float2 f=velocity/max(speed,0.001);float3 forward=float3(f.x,0,f.y),right=float3(f.y,0,-f.x);
    float gait=sin(G.z*TAU*16.0/128.0+id*1.3)*saturate(speed*2.0);
    if(part==0){c=float3(0,1.17,0);b=float3(0.17,0.28,0.09);}
    else if(part==1){c=float3(0,1.66,0.008);b=float3(0.073,0.117,0.079);}
    else
    {
        float side=part%2==0?-1.0:1.0;
        if(part<4){c=float3(side*0.215,1.14,-side*gait*0.06);b=float3(0.045,0.29,0.048);}
        else{c=float3(side*0.095,0.47,side*gait*0.05);b=float3(0.054,0.44,0.058);}
    }
    uint patch=q/6;float2 uv=Corner(q);
    float longitude=(patch%6+uv.x)*TAU/6.0,latitude=(patch/6+uv.y)*PI/2.0;
    float3 sphere=float3(cos(longitude)*sin(latitude),cos(latitude),sin(longitude)*sin(latitude));
    g.p=c+sphere*b;g.n=normalize(sphere/b);g.uv=uv;
    g.local=g.p;g.p=PeopleRoot(id,G.z)+(right*g.p.x+float3(0,g.p.y,0)+forward*g.p.z)*PeopleScale(id);
    g.n=right*g.n.x+float3(0,g.n.y,0)+forward*g.n.z;return g;
}
Geometry BuildGeometry(uint vertex,uint instance)
{
    Geometry g=(Geometry)0;
    if(instance>=70000)g=NeuralHeadGeometry(vertex,instance-70000);
    else if(instance>=60000)g=NeuralPersonGeometry(vertex,instance-60000);
    else if(instance>=50000)g=PersonShadowGeometry(vertex,instance-50000);
    else if(instance>=40000)g=ForestGeometry(vertex,instance-40000);
    else if(instance>=30000)g=GliderGeometry(vertex,instance-30000);
    else if(instance>=20000)g=RockGeometry(vertex,instance-20000);
    else if(instance>=2000)g=GrassGeometry(vertex,instance-2000);
    else if(instance>=1000)
    {
        if(PassMode.z>.5)g=CoarseNearTreeGeometry(vertex,instance-1000);
        else g=TreeGeometry(vertex,instance-1000);
    }
    else g=HouseGeometry(vertex,instance);
    return g;
}
MeshOut PackGeometry(Geometry g)
{
    MeshOut o;o.world=g.p;o.normal=g.n;o.uv=g.uv;o.local=g.local;o.tag=float3(g.material,g.seed,g.moving);o.learnedColor=g.learnedColor;o.position=0;o.clipDistance=1;return o;
}
bool OutsideMeshBounds(float3 center,float radius,bool shadowPass)
{
    // Cull only entire conservative bounds, independently in each pass.
    // A shadow caster outside the camera still survives the light-space test.
    if(shadowPass)
    {
        float3 q=CinematicShadowPosition(center);
        float xyExtent=PassMode.z>.5?CinematicFrame[13].w:CinematicFrame[10].w;
        float zExtent=PassMode.z>.5?CinematicFrame[14].w:CinematicFrame[11].w;
        float xyRadius=radius/xyExtent;
        float zRadius=radius/(2.0*zExtent);
        return any(abs(q.xy)>1.0+xyRadius)||q.z+zRadius<0.0||q.z-zRadius>1.0;
    }
    CameraFrame camera;
    camera.origin=CinematicFrame[0].xyz;camera.lens=CinematicFrame[0].w;
    camera.forward=CinematicFrame[1].xyz;camera.right=CinematicFrame[2].xyz;camera.up=CinematicFrame[3].xyz;
    camera=PassCameraFrame(camera);
    float3 d=center-camera.origin;
    float z=dot(d,camera.forward),x=dot(d,camera.right),y=dot(d,camera.up);
    // Expand the side planes by a full pixel for the subpixel raster jitter.
    float horizontal=CinematicFrame[2].w*(1.0+2.0/G.x),vertical=1.0+2.0/G.y;
    float lens=camera.lens;
    return z+radius<.1||z-radius>MAX_DIST||
           abs(x)*lens>z*horizontal+radius*sqrt(lens*lens+horizontal*horizontal)||
           abs(y)*lens>z*vertical+radius*sqrt(lens*lens+vertical*vertical)||
           (PassMode.x>.5&&center.y+radius<LAKE_Y);
}
bool CullMeshGroup(uint vertex,uint instance,bool shadowPass)
{
    float3 center=0;float height=0,seed=0;
    if(instance>=60000)
    {
        bool head=instance>=70000;
        uint person=head?instance-70000:instance-60000;
        center=PeopleRoot((int)(person%6u),G.z);
        center.y+=head?1.57:.9;
        return OutsideMeshBounds(center,head?.45:1.6,shadowPass);
    }
    if(instance>=50000)return !shadowPass;
    if(instance>=40000)
    {
        float ground;
        ForestPlacement((instance-40000)*3+vertex/96,center,height,seed,ground);
        if(SceneInstanceData[(256+(instance-40000)*3+vertex/96)*2+1].w<.5)return true;
        return OutsideMeshBounds(center+float3(0,height*.5,0),EcologyBoundsRadius(height,seed,SceneInstanceData[(256+(instance-40000)*3+vertex/96)*2+1].yz),shadowPass);
    }
    if(instance>=20000)return false;
    if(instance>=2000)
    {
        // Existing blades are rejected above680m or beyond84m from the MAIN
        // camera in every pass. This whole-batch bound has exactly that effect.
        if(CinematicFrame[0].y>764.0)return true;
        uint id=instance-2000;
        center=SceneInstanceData[(18688+id)*2].xyz;
        if(SceneInstanceData[(18688+id)*2+1].z<.5)return true;
        return OutsideMeshBounds(center+float3(0,.32,0),1.0,shadowPass);
    }
    if(instance>=1000)
    {
        TreePlacement(instance-1000,center,height,seed);
        if(SceneInstanceData[(64+instance-1000)*2+1].w<.5)return true;
        return OutsideMeshBounds(center+float3(0,height*.5,0),EcologyBoundsRadius(height,seed,SceneInstanceData[(64+instance-1000)*2+1].yz),shadowPass);
    }
    float3 size;float angle;
    HousePlacement(instance,center,size,angle,seed);
    // Includes roofs, chimney, balcony, stairs and the complete fence rails.
    return OutsideMeshBounds(center+float3(0,instance==31?13.0:6.0,0),instance==31?38.0:26.0,shadowPass);
}
MeshOut CulledMeshVertex()
{
    MeshOut o=(MeshOut)0;o.position=float4(0,0,-1,1);o.clipDistance=-1;return o;
}
MeshOut MeshVS(uint vertex:SV_VertexID,uint instance:SV_InstanceID)
{
    instance+=Batch.x;
    [branch]if(CullMeshGroup(vertex,instance,false))return CulledMeshVertex();
    Geometry g=BuildGeometry(vertex,instance);MeshOut o=PackGeometry(g);
    CameraFrame camera;camera.origin=CinematicFrame[0].xyz;camera.lens=CinematicFrame[0].w;
    camera.forward=CinematicFrame[1].xyz;camera.right=CinematicFrame[2].xyz;camera.up=CinematicFrame[3].xyz;
    camera=PassCameraFrame(camera);
    float3 d=g.p-camera.origin;float z=dot(d,camera.forward),lens=camera.lens;
    float2 xy=float2(dot(d,camera.right)/CinematicFrame[2].w,dot(d,camera.up))*lens;
    float2 jitter=TemporalJitter(((int)G.w)&7)*float2(-2.0/G.x,2.0/G.y);
    o.position=float4(xy+jitter*z,z*(MAX_DIST/(MAX_DIST-0.1))-0.1*MAX_DIST/(MAX_DIST-0.1),z);
    if(instance>=50000&&instance<60000)o.position=float4(0,0,-1,1);
    o.clipDistance=PassMode.x>0.5?g.p.y-LAKE_Y:1.0;
    return o;
}
MeshOut ShadowVS(uint vertex:SV_VertexID,uint instance:SV_InstanceID)
{
    instance+=Batch.x;
    [branch]if(CullMeshGroup(vertex,instance,true))return CulledMeshVertex();
    Geometry g=BuildGeometry(vertex,instance);MeshOut o=PackGeometry(g);
    o.position=float4(CinematicShadowPosition(g.p),1);return o;
}
void FoliageCoverage(MeshOut i)
{
    if(i.tag.x==50)
    {
        // Clean collar rim around the base of the neck while clearing shoulders/jaw.
        float collarTop=1.452-.022*smoothstep(.058,.095,length(i.local.xz));
        clip(collarTop-i.local.y);
    }
    if(i.tag.x==51)clip(NeuralHeadCropCoverage(i.local));
    if(i.tag.x==27)clip(EcologyCrownOccupancy(i.local,i.uv,i.tag.y));
    if(i.tag.x==25)clip(EcologyShootOccupancy(i.local,i.uv,i.tag.y));
    if(i.tag.x==21)
    {
        float2 uv=i.uv;float seed=i.tag.y;
        float span=0.42+seed*0.24,halfWidth=0.085+seed*0.035;
        float u=uv.x*span,v=abs((uv.y-0.5)*2.0*halfWidth);
        float envelope=halfWidth*(0.22+0.78*pow(saturate(sin(uv.x*PI)),0.62));
        envelope*=.88+.075*sin(uv.x*43.0+seed*29.0)+.045*sin(uv.x*97.0+seed*17.0);
        // Fine 14mm spruce/fir needle pitch prevents coarse comb gaps up close
        // while converging cleanly to its area-average bough silhouette afar.
        float pitch=.0145;
        float dx=(frac((u-v*.68)/pitch+seed*.4+.5)-.5)*pitch;
        float needlePhase=v/0.0065-abs(dx)*82.0;
        float needleDistance=abs(frac(needlePhase)-.5)*.0065;
        float needleRadius=.0011+min(.0018,fwidth(needlePhase)*.0015);
        float needles=min(.0060-abs(dx),needleRadius-needleDistance);
        float offshoot=max(.0022-abs(dx),needles);
        float footprint=max(fwidth(u),fwidth(v));
        float resolved=max(.0032-v,offshoot);
        float integrated=max(.0032-v,.0056-abs(dx));
        float coverage=lerp(resolved,integrated,smoothstep(.0016,.0065,footprint));
        clip(min(envelope-v,coverage));
    }
    else if(i.tag.x==24)
    {
        float2 uv=i.uv;float x=abs(uv.x*2.0-1.0);
        float lobes=.87+.08*sin(uv.y*37.0+i.tag.y*39.0)+.05*sin(uv.x*61.0+i.tag.y*17.0);
        float envelope=(1.0-uv.y*.94)*lobes;
        clip(min(envelope-x,uv.y+.025-.065*x));
    }
    else if(i.tag.x==37||i.tag.x==38)
    {
        float2 q=i.uv*2.0-1.0;
        float petals=i.tag.x==38?.82+.18*cos(atan2(q.y,q.x)*5.0):1.0;
        clip(petals-length(q));
    }
}
float ShadowPS(MeshOut i):SV_Target
{
    FoliageCoverage(i);return saturate(CinematicShadowPosition(i.world).z);
}
float FilteredLines(float x,float width)
{
    float aa=max(fwidth(x),0.0005),d=abs(frac(x+0.5)-0.5);
    return lerp(1.0-smoothstep(width-aa,width+aa,d),min(1.0,width*2.0),saturate(aa-0.45));
}
float CanopyRayEllipsoid(float3 ro,float3 rd,float3 center,float3 radii)
{
    float3 o=(ro-center)/radii,d=rd/radii;
    float a=dot(d,d),b=dot(o,d),c=dot(o,o)-1.0,h=b*b-a*c;
    if(h<0.0)return 1e6;
    float t=(-b-sqrt(h))/a;return t>.0001?t:1e6;
}
float3 CanopyInterior(float3 p,float3 localView,float3 localNormal)
{
    float3 ray=refract(-localView,localNormal,1.0/1.49);
    if(dot(ray,ray)<.01)ray=-localView;
    float3 origin=p+ray*.002;
    float head=CanopyRayEllipsoid(origin,ray,float3(0,.42,1.30),float3(.085,.115,.095));
    float torso=CanopyRayEllipsoid(origin,ray,float3(0,.18,1.13),float3(.17,.23,.32));
    float seat=CanopyRayEllipsoid(origin,ray,float3(0,.16,1.02),float3(.23,.26,.62));
    float3 color=float3(.025,.033,.037);
    if(seat<1e5)color=float3(.035,.045,.050);
    if(torso<min(head,seat))color=float3(.038,.065,.083);
    if(head<min(torso,seat))
    {
        float3 hp=origin+ray*head;
        float3 normal=normalize((hp-float3(0,.42,1.30))/float3(.007225,.013225,.009025));
        color=float3(.35,.19,.12)*(.28+.58*saturate(normal.y*.5+.5));
        if(hp.y>.48)color=float3(.026,.020,.014);
    }
    return color*float3(.86,.94,.97);
}
float4 MeshPS(MeshOut i,bool front:SV_IsFrontFace):SV_Target
{
    FoliageCoverage(i);float mat=i.tag.x,seed=i.tag.y;
    float3 n=normalize(i.normal),view=normalize(CinematicViewOrigin()-i.world);
    float3 neuralReceiverNormal=n;
    if(mat==50||mat==51)
    {
        // The shadow filter extrapolates a receiver plane across its PCF taps.
        // Learned detail normals describe shading, not that triangle's plane;
        // using them here turns fine normal variation into patchy self-shadow.
        // Keep learned BRDF normals, but derive the receiver from posed geometry.
        float3 geometric=cross(ddy(i.world),ddx(i.world));
        float magnitudeSquared=dot(geometric,geometric);
        if(magnitudeSquared>1e-20)
        {
            geometric*=rsqrt(magnitudeSquared);
            neuralReceiverNormal=dot(geometric,n)<0.0?-geometric:geometric;
        }
    }
    if(mat==21||mat==22||mat==24)n=dot(n,view)>=0.0?n:-n;
    float3 color=float3(0.65,0.61,0.51),dielectricF0=.04;float rough=0.78,metal=0,ao=1;
    float neuralBareCoverage=0,neuralBareRough=.5,skinWeight=0;float3 neuralBareF0=.04;
    float mottling=Noise2(i.world.xz*0.57+i.world.y*0.37);
    if(mat==1)
    {
        RuntimeMaterial plaster=TriplanarRuntimeMaterial(3,i.world,n,.24,.45);
        color=plaster.albedo*lerp(float3(.90,.85,.75),float3(1.06,.99,.87),seed);
        n=plaster.normal;rough=plaster.roughness;
        float eaveAO=1.0-.16*smoothstep(3.3,5.4,i.local.y)*(1.0-smoothstep(6.4,9.2,i.local.y));
        ao=lerp(.64,1.0,smoothstep(.15,1.8,i.local.y))*eaveAO;
        float groundStain=(1.0-smoothstep(.12,1.60,i.local.y))*(.15+.18*Noise2(i.world.xz*.71));
        color*=1.0-groundStain;
    }
    else if(mat==2||mat==23)
    {
        RuntimeMaterial stone=TriplanarRuntimeMaterial(0,i.world,n,.48,.58);
        float3 geometricNormal=n;
        color=stone.albedo*lerp(.74,1.06,mottling);n=stone.normal;
        float4 habitat=WorldEcology(i.world.xz);
        // Opaque weathering deposits over the glossy learned aggregate.
        // .04 is the authored dielectric F0 (IOR 1.5), not a rescaling of
        // PhotoMat's correctly linear learned specular output.
        neuralBareCoverage=1-clamp(.90+.08*saturate(habitat.y*.65+habitat.x*.25+mottling*.30),.90,.98);
        neuralBareF0=stone.specular;neuralBareRough=stone.roughness;
        if(mat==2)
        {
            float horizontal=abs(n.x)>abs(n.z)?i.local.z:i.local.x;
            float mortar=max(FilteredLines(i.local.y*3.0,0.045),FilteredLines(horizontal*1.8+floor(i.local.y*3.0)*0.5,0.045));
            color=lerp(color,float3(0.15,0.155,0.145),mortar*0.62);
            neuralBareCoverage*=1-mortar;
            n=normalize(lerp(n,geometricNormal,mortar));
            ao=lerp(.72,1.0,smoothstep(.05,.95,i.local.y));
        }
        rough=.82;
    }
    else if(mat==3||mat==6||mat==7||mat==35)
    {
        RuntimeMaterial timber=TriplanarRuntimeMaterial(2,i.world*float3(1,.8,1),n,.62,.48);
        float horizontal=abs(n.x)>abs(n.z)?i.local.z:i.local.x;
        float boardCoordinate=(mat==7?i.local.z:i.local.y)*(mat==6?8.0:5.8);
        float boardID=floor(boardCoordinate),boardSeed=Hash21(float2(boardID,seed*97.0));
        float weather=Noise2(float2(horizontal*.21,i.local.y*.35)+seed*43.0);
        float silver=saturate((weather-.42)*1.25+boardSeed*.16)*(1.0-smoothstep(2.8,5.2,i.local.y)*.55);
        // Sun-baked Alpine larch and spruce timber tones, from roasted chestnut
        // to warm honey-amber, with restrained silvering on exposed faces.
        float3 woodTint=lerp(float3(.54,.31,.155),float3(.98,.70,.42),seed);
        woodTint*=lerp(float3(.92,.86,.80),float3(1.08,1.03,.96),boardSeed);
        color=timber.albedo*woodTint;
        float luminance=dot(color,float3(.30,.59,.11));
        color=lerp(color,luminance*float3(1.06,1.03,.96)+float3(.014,.014,.013),silver*.28);
        float board=FilteredLines(boardCoordinate,.024);
        float endGrain=FilteredLines(horizontal*.34+boardSeed*17.0,.008);
        color*=(.82+.28*boardSeed)*(1.0-.48*board)*(1.0-.18*endGrain);
        float bevel=sin((frac(boardCoordinate)-.5)*TAU)*.14*(1.0-saturate(fwidth(boardCoordinate)*1.6));
        n=normalize(timber.normal+(mat==7?float3(0,0,bevel):float3(0,bevel,0)));
        rough=lerp(timber.roughness,.86,silver*.55);dielectricF0=timber.specular;
        if(mat==6)color=lerp(color,lerp(float3(.042,.088,.058),float3(.155,.038,.024),step(.74,seed)),step(.38,seed));
        if(mat==35)
        {
            float eaveAO=1.0-.18*smoothstep(3.4,5.4,i.local.y);
            color*=(.82+.18*smoothstep(0,2.2,i.local.y));
            ao=.84*eaveAO;
        }
        else ao=.84;
    }
    else if(mat==4)
    {
        float row=floor(i.local.z*3.2),tile=Hash21(float2(floor(i.local.x*2.8+row*0.5),row)+seed*71);
        RuntimeMaterial slate=TriplanarRuntimeMaterial(4,i.world,n,.45,.42);
        color=slate.albedo*lerp(.74,1.16,tile);n=slate.normal;
        float3 roofTint=lerp(float3(.82,.86,.92),lerp(float3(.94,.78,.62),float3(1.12,.58,.36),step(.80,seed)),step(.54,seed));
        color*=roofTint;
        float mortar=max(FilteredLines(i.local.z*3.2,0.055),FilteredLines(i.local.x*2.8+row*0.5,0.045));
        color*=1.0-mortar*0.44;rough=lerp(.58,.78,tile);ao=1.0-mortar*.22;
    }
    else if(mat==5||mat==31){color=float3(0.022,0.032,0.040);rough=0.075;ao=0.20;}
    else if(mat==20)
    {
        float azimuth=atan2(i.local.z+.00001,i.local.x);
        float2 barkUV=float2(azimuth*3.18,i.local.y*.40);
        float bark=Noise2(barkUV*float2(1.7,.8));
        float fissures=FilteredLines(barkUV.x+Noise2(barkUV*.51)*.32,.09);
        float plates=FilteredLines(barkUV.y*3.0+floor(barkUV.x)*.47,.018);
        color=lerp(float3(.048,.038,.029),float3(.15,.115,.082),bark);
        color*=1.0-.64*fissures;color*=1.0-.24*plates;
        float lichen=smoothstep(.66,.82,Noise2(i.world.xz*7.1+i.world.y*.63));
        color=lerp(color,float3(.15,.17,.12),lichen*.26);
        float3 tangent=float3(-sin(azimuth),0,cos(azimuth));
        n=normalize(n+tangent*sin(barkUV.x*TAU+bark*2.0)*.14);
        rough=.96;
    }
    else if(mat==25||mat==26||mat==27)
    {
        float density=mat==26?1:EcologyNeedleDensity(i.local,i.uv,seed);
        color=EcologyNeedleAlbedo(seed,density);rough=.82;
        if(mat==27)
        {
            float crownH=saturate(i.local.y/max(i.uv.y*2.0,.01)+.5);
            float whorl=sin(crownH*34.0+seed*19.0)*.14;
            n=normalize(n+float3(0,whorl,0));
            ao=lerp(.44,.94,lerp(density,crownH,.35));
        }
        else if(mat==25)
        {
            float3 tuft=float3(sin(i.local.y*95.0+i.local.z*62.0+seed*31.0),
                               cos(i.local.x*84.0+i.local.y*110.0),
                               sin(i.local.x*78.0-i.local.y*92.0+seed*17.0));
            n=normalize(n+tuft*.28);
            ao=lerp(.48,.90,density);
        }
        else ao=lerp(.52,.92,density);
        if(mat==26)n=dot(n,view)>=0?n:-n;
    }
    else if(mat==21||mat==24)
    {
        float tip=mat==21?saturate(.5+i.local.y*.8):i.uv.x;
        color=EcologyNeedleAlbedo(seed,.66+.30*tip);
        rough=.80;ao=.54+.36*tip;
    }
    else if(mat==22){color=lerp(float3(.032,.060,.016),float3(.105,.135,.032),seed);color*=.52+.48*i.uv.y;rough=.88;ao=.58+.42*i.uv.y;}
    else if(mat==30)
    {
        color=float3(.76,.78,.77);rough=.18;
        float tips=smoothstep(7.8,8.2,abs(i.local.x));
        float tail=step(.45,i.local.y)*(1.0-smoothstep(-2.48,-2.32,i.local.z));
        float stripe=(1.0-smoothstep(.015,.032,abs(i.local.z+.41+.32*pow(saturate(abs(i.local.x)/9.0),1.4))))*step(.6,abs(i.local.x));
        color=lerp(color,float3(.68,.15,.032),max(tips,max(tail,stripe)));
    }
    else if(mat==32){color=float3(.35,.19,.12);rough=.52;skinWeight=1.0;}
    else if(mat==36){color=float3(.16,.17,.16);rough=.36;metal=.78;}
    else if(mat==37){color=lerp(float3(.022,.048,.012),float3(.072,.115,.024),mottling);rough=.90;ao=.65;}
    else if(mat==38){color=lerp(float3(.42,.028,.026),float3(.54,.21,.045),step(.55,seed));rough=.80;ao=.8;}
    else if(mat==39)
    {
        RuntimeMaterial paving=TriplanarRuntimeMaterial(5,i.world,n,.6,.6);
        color=paving.albedo;n=paving.normal;rough=paving.roughness;ao=.84;
    }
    else if(mat==40)
    {
        float slats=FilteredLines(i.local.y*9.0,.14);
        color=lerp(float3(.012,.009,.006),float3(.07,.045,.022),slats);rough=.82;ao=.3;
    }
    else if(mat==41)
    {
        float2 q=i.uv*2.0-1.0;float r=length(q),angle=atan2(q.y,q.x);
        float ring=smoothstep(.77,.82,r),minuteMark=step(.91,cos(angle*12.0))*smoothstep(.58,.68,r);
        float hands=max((1.0-smoothstep(.018,.035,abs(q.x+.25*q.y)))*step(0,q.y),
            (1.0-smoothstep(.018,.035,abs(q.y-.45*q.x)))*step(0,q.x)*(1.0-smoothstep(.40,.5,r)));
        color=lerp(float3(.58,.52,.38),float3(.018,.019,.015),saturate(ring+minuteMark+hands));rough=.62;
    }
    else if(mat==50)
    {
        // gDNA predicts geometry/normal/skinning, not albedo. Authored Alpine
        // cold-weather jacket, trekking trousers, leather boots and skin tones.
        float skin=smoothstep(.68,.78,abs(i.local.x));
        float trousers=1.0-smoothstep(.82,.94,i.local.y);
        float boots=1.0-smoothstep(.16,.22,i.local.y);
        float jacket=(1.0-skin)*(1.0-trousers);
        float3 shirt=NeuralResidentShirtColor(seed);
        float3 pants=lerp(float3(.028,.033,.040),float3(.048,.045,.038),step(.5,seed));
        color=lerp(shirt,pants,trousers);
        color=lerp(color,float3(.042,.026,.016),boots*(1.0-skin));
        color=lerp(color,float3(.34,.195,.138),skin);
        // Wide 10.5cm Alpine down-jacket baffles + matte woven outdoor textile.
        float bafflePhase=i.local.y*9.5;
        float baffleSeam=FilteredLines(bafflePhase,.030);
        float weave=Noise2(i.local.xy*420.0+i.local.z*290.0)-.5;
        n=normalize(n+float3(weave*.09*(1.0-skin),sin(bafflePhase*TAU)*.065*jacket,-weave*.09*(1.0-skin)));
        float micro=Noise2(i.local.xy*370.0+i.local.z*119.0);
        color*=(.95+.10*micro)*(1.0-.14*baffleSeam*jacket);
        dielectricF0=lerp(.016,.036,max(skin,boots*(1.0-skin)));
        rough=lerp(lerp(.82,.88,trousers),lerp(.48,.54,micro),skin);
        rough=lerp(rough,.52,boots*(1.0-skin));
        ao=1.0-.15*baffleSeam*jacket;
        skinWeight=skin;
    }
    else if(mat==51)
    {
        // GANHead predicts scanner appearance in sRGB. Convert to linear light
        // and balance cool studio scan white-point to natural Alpine daylight.
        float3 srgb=saturate(i.learnedColor);
        color=float3(srgb.x<=.04045?srgb.x/12.92:pow((srgb.x+.055)/1.055,2.4),
                     srgb.y<=.04045?srgb.y/12.92:pow((srgb.y+.055)/1.055,2.4),
                     srgb.z<=.04045?srgb.z/12.92:pow((srgb.z+.055)/1.055,2.4));
        color*=float3(1.06,.99,.94);
        float pore=Noise2(i.local.xy*420.0+i.local.z*310.0);
        rough=lerp(.74,.44,smoothstep(.05,.32,dot(srgb,float3(.3,.59,.11))))+(pore-.5)*.06;
        float clothing=NeuralHeadClothingCoverage(i.local);
        color=lerp(color,NeuralResidentShirtColor(seed),clothing);
        rough=lerp(rough,.76,clothing);
        float luma=dot(color,float3(.2126,.7152,.0722));
        skinWeight=(1.0-clothing)*smoothstep(.045,.13,luma)*smoothstep(-.04,.02,i.local.z)*(1.0-smoothstep(1.69,1.74,i.local.y));
    }
    float sunVisibility=CinematicShadow(i.world,(mat==50||mat==51)?neuralReceiverNormal:n);
#if defined(ALPINE_QA_CHARACTER_UNSHADOWED)
    if(mat==50||mat==51)sunVisibility=1;
#endif
    float3 lit=CinematicLightingAt(i.world,n,n,view,color,rough,metal,ao,sunVisibility,dielectricF0);
    if(skinWeight>.001)
    {
        float3 skinLit=CinematicSkinLighting(i.world,n,view,color,rough,ao,sunVisibility);
        lit=lerp(lit,skinLit,skinWeight);
    }
    if(mat==2||mat==23)
        lit=lerp(lit,CinematicLightingAt(i.world,n,n,view,color,neuralBareRough,metal,ao,sunVisibility,neuralBareF0),neuralBareCoverage);
    if(mat==21||mat==22||mat==24||mat==25||mat==26||mat==27)
    {
        float transmission=pow(saturate(dot(-view,CinematicFrame[8].xyz)),3.0);
        lit+=color*CinematicSunColorAt(i.world.y)*transmission*(mat==22?.34:.26)*sunVisibility;
    }
    if(mat==40)
    {
        float warmHours=1.0-smoothstep(.10,.28,CinematicFrame[8].y);
        float slats=1.0-FilteredLines(i.local.y*9.0,.14);
        lit+=float3(1.55,.72,.22)*warmHours*slats*.65;
    }
    if(mat==5)
    {
        float fresnel=0.04+0.96*pow(1.0-saturate(dot(n,view)),5.0);
        float3 tangent=normalize(cross(abs(n.y)<.95?float3(0,1,0):float3(1,0,0),n));
        float3 vertical=cross(n,tangent);
        float2 roomUV=i.uv+float2(dot(view,tangent),dot(view,vertical))*.32/max(.15,abs(dot(n,view)));
        float floorMask=1.0-smoothstep(.08,.18,roomUV.y);
        float wallEdge=smoothstep(.0,.09,roomUV.x)*(1.0-smoothstep(.91,1.0,roomUV.x));
        float3 room=lerp(float3(.022,.016,.010),float3(.053,.043,.032),floorMask)*lerp(.55,1.0,wallEdge);
        float curtainEdge=.16+.035*sin(i.uv.y*18.0+seed*19.0);
        float curtain=1.0-smoothstep(curtainEdge,curtainEdge+.035,min(i.uv.x,1.0-i.uv.x));
        room=lerp(room,float3(.12,.11,.083)*(.80+.20*sin(i.uv.x*71.0)),curtain*.85);
        float winHash=Hash21(floor(i.world.xz*.42)+floor(i.local.y*.45)*13.7+seed*31.0);
        float warmHours=1.0-smoothstep(.10,.30,CinematicFrame[8].y);
        float lampOn=step(.30,winHash)*warmHours+.14*step(.84,winHash);
        float3 lampColor=lerp(float3(2.25,.98,.30),float3(2.95,1.48,.56),frac(winHash*7.3));
        float interiorGlow=smoothstep(.08,.55,roomUV.y)*(1.0-smoothstep(.72,.98,roomUV.y))*lerp(.45,1.0,wallEdge);
        room+=lampColor*lampOn*interiorGlow*lerp(1.0,.42,curtain);
        lit=room*(1.0-fresnel)+AtmosphereEnvironment(reflect(-view,n))*fresnel+lit*.25;
    }
    else if(mat==31)
    {
        float3 center,r,u,f;ProceduralGliderPose((uint)(seed+.01),G.z,center,r,u,f);
        float3 localView=float3(dot(view,r),dot(view,u),dot(view,f));
        float3 localNormal=float3(dot(n,r),dot(n,u),dot(n,f));
        float3 inside=CanopyInterior(i.local,localView,localNormal);
        float3 reflected=reflect(-view,n);
        float3 sky=AtmosphereEnvironment(reflected);
        float sunGlint=pow(saturate(dot(reflected,CinematicFrame[8].xyz)),900.0);
        sky+=CinematicSunColorAt(i.world.y)*sunGlint*3.2*sunVisibility;
        float fresnel=.039+(.961)*pow(1.0-saturate(dot(n,view)),5.0);
        lit=lerp(inside,sky,fresnel);
        float frame=(1.0-smoothstep(.006,.014,abs(i.local.y-.24)))+
                    (1.0-smoothstep(.008,.022,abs(i.local.z-.42)));
        lit=lerp(lit,color*1.6,saturate(frame));
    }
    float depth=EncodeDepth(length(i.world-CinematicViewOrigin()));
    return float4(CinematicFog(lit,i.world),i.tag.z>0.5?-depth:depth);
}
