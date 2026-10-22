// Runtime geometry: no vertex buffers, imported meshes or bitmap textures.
// DrawInstanced(vertices, instances, 0, 0), with absolute type base in Batch.x:
// houses 3600,32,0; firs 8712,192,1000; grass18,12288,2000;
// rocks240,384,20000; gliders216,4,30000. All entry points target SM5.
#include "cinematic_lighting.hlsli"
#include "people_motion.hlsli"
cbuffer Frame : register(b0) { float4 G; float4 G2; };
// SM5 SV_InstanceID starts at zero for each draw. StartInstanceLocation only
// offsets instance-buffer fetches; it DOES NOT offset this system value.
cbuffer DrawBatch : register(b1) { uint4 Batch; };
RWStructuredBuffer<float4> FrameOutput : register(u0);
float LoopAngle(){return fmod(G.z,128.0)*(TAU/128.0);}

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
    float village=(1.0-smoothstep(210.0,340.0,length(c.origin.xz-TOWN_C)))*
                  (1.0-smoothstep(6.0,40.0,c.origin.y-Terrain(c.origin.xz)));
    float extent=lerp(240.0,80.0,village),texel=2.0*extent/2048.0;
    float3 center=c.origin+c.forward*lerp(85.0,25.0,village);
    center.y=Terrain(center.xz)+24.0;
    // Snap light-space origin, not just world X/Z: static surfaces remain stable.
    center+=sr*(floor(dot(center,sr)/texel)*texel-dot(center,sr));
    center+=su*(floor(dot(center,su)/texel)*texel-dot(center,su));
    FrameOutput[8]=float4(sun,3.2);FrameOutput[9]=float4(center,1.0/2048.0);
    FrameOutput[10]=float4(sr,extent);FrameOutput[11]=float4(su,2000.0);
}

struct Geometry { float3 p; float3 n; float2 uv; float3 local; float material; float seed; float moving; };
struct MeshOut
{
    float4 position:SV_POSITION;
    float3 world:TEXCOORD0;
    float3 normal:TEXCOORD1;
    float2 uv:TEXCOORD2;
    float3 local:TEXCOORD3;
    nointerpolation float3 tag:TEXCOORD4; // material, seed, dynamic
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
void HousePlacement(uint id,out float3 center,out float3 size,out float angle,out float seed)
{
    seed=Hash21(float2(id,71));uint col=id%4,row=id/4;
    float x=(col==0?-46.0:(col==1?-14.4:(col==2?14.4:46.0)));
    float z=1658.0+row*37.0+Hash21(float2(id,39))*7.0;
    x+=(Hash21(float2(id,19))-0.5)*(col==1||col==2?2.8:9.0);
    center=float3(x,Terrain(float2(x,z))-0.08,z);
    size=float3(4.0+seed*2.5,6.0+Hash21(float2(id,43))*3.0,4.0+Hash21(float2(id,47))*2.0);
    angle=(Hash21(float2(id,53))-0.5)*0.10+(x<0.0?PI:0.0);
}
Geometry HouseGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;float3 center,hs;float angle,seed;
    HousePlacement(id,center,hs,angle,seed);g.seed=seed;g.material=1;
    uint part=v/36,q=v%36;float3 c=0,b=0;
    float roofRise=hs.x*0.64,roofAngle=atan(0.64),roofHalf=hs.x+0.62;
    if(part==0){c=float3(0,0.42,0);b=float3(hs.x+0.12,0.50,hs.z+0.12);g.material=2;}
    else if(part==1){c=float3(0,hs.y*0.5,0);b=float3(hs.x,hs.y*0.5,hs.z);}
    else if(part==2){c=float3(0,hs.y-0.40,0);b=float3(hs.x+0.08,0.40,hs.z+0.08);g.material=3;}
    else if(part==3||part==4)
    {
        float side=part==3?-1.0:1.0;
        Box(q,0,float3(roofHalf*0.5*sqrt(1.0+0.64*0.64),0.11,hs.z+0.65),g);
        g.p=RotateZ(g.p,-side*roofAngle)+float3(side*roofHalf*0.5,hs.y+roofRise-roofHalf*0.32,0);
        g.n=RotateZ(g.n,-side*roofAngle);g.material=4;
    }
    else if(part==5||part==6)
    {
        Gable(q,hs.x,roofRise,0.07,hs.y,g);g.p.z+=(part==5?1.0:-1.0)*(hs.z-0.07);g.material=3;
    }
    else if(part==7){c=float3(hs.x*0.37,hs.y+roofRise-0.15,hs.z*0.35);b=float3(0.36,1.25,0.40);g.material=2;}
    else if(part==8){c=float3(-hs.x-0.85,0.15,0);b=float3(0.85,0.16,1.45);g.material=2;}
    else if(part==9){c=float3(-hs.x-0.025,1.10,0);b=float3(0.08,1.10,0.63);g.material=3;}
    else if(part==10){c=float3(-hs.x-0.12,1.12,0);b=float3(0.025,1.01,0.49);g.material=7;}
    else if(part<83)
    {
        uint wi=(part-11)/6,wp=(part-11)%6;
        // Four windows on each street facade, two on each gable facade.
        uint face=wi/4;uint w=wi%4;float side=(face==0?-1.0:1.0);
        float height=(w/2==0?2.05:4.85);
        float along=(w%2==0?-1.0:1.0)*(face<2?hs.z*0.54:hs.x*0.54);
        float3 wc=face<2?float3(side*(hs.x+0.085),height,along):float3(along,height,hs.z+0.085);
        float3 wb=float3(0.11,1.01,0.79);float3 offset=0;
        g.material=3;
        if(wp==1){wb=float3(0.027,0.88,0.66);offset.x=0.12;g.material=5;}
        else if(wp==2){wb=float3(0.036,0.90,0.026);offset.x=0.16;}
        else if(wp==3){wb=float3(0.038,0.032,0.68);offset.x=0.16;}
        else if(wp==4||wp==5){wb=float3(0.075,0.96,0.24);offset=float3(0.015,0,(wp==4?-1.0:1.0)*1.05);g.material=6;}
        if(face<2){offset.x*=side;c=wc+offset;b=wb;}
        else{c=wc+float3(offset.z,offset.y,offset.x);b=wb.zyx;}
    }
    else if(part==83){c=float3(-hs.x-0.85,3.53,0);b=float3(1.05,0.11,hs.z*0.80);g.material=3;}
    else if(part==84){c=float3(-hs.x-1.85,4.58,0);b=float3(0.055,0.05,hs.z*0.81);g.material=3;}
    else if(part==85){c=float3(-hs.x-1.85,4.01,0);b=float3(0.07,0.52,0.065);g.material=3;}
    else if(part<90)
    {
        uint rail=part-86;c=float3((rail<2?-1.0:1.0)*(hs.x+1.3),0.55+(rail%2)*0.40,hs.z+2.1);
        b=float3(0.045,0.048,3.5);g.material=3;
    }
    else if(part<98)
    {
        uint post=part-90;c=float3((post<4?-1.0:1.0)*(hs.x+1.3),0.59,hs.z-1.4+(post%4)*2.33);
        b=float3(0.055,0.62,0.055);g.material=3;
    }
    else{float step=part-98;c=float3(-hs.x-1.15-step*0.42,0.10-step*0.035,0);b=float3(0.30,0.11-step*0.035,1.05);g.material=2;}
    if(part!=3&&part!=4&&part!=5&&part!=6)Box(q,c,b,g);
    g.local=g.p;g.p=RotateY(g.p,angle)+center;g.n=RotateY(g.n,angle);
    return g;
}
void TreePlacement(uint id,out float3 center,out float height,out float seed)
{
    seed=Hash21(float2(id,111));float2 xz;
    if(id<16)xz=float2((id%2==0?-1:1)*(8.5+seed),1678.0+floor(id/2.0)*37.0);
    else if(id<96)xz=float2((id%2==0?-1:1)*(64.0+seed*75.0),1570.0+Hash21(float2(id,112))*445.0);
    else
    {
        float a=(id-96)*2.39996323;float r=0.98+seed*0.20;
        xz=LAKE_C+float2(cos(a)*930.0,sin(a)*650.0)*r;
    }
    center=float3(xz.x,Terrain(xz)-0.08,xz.y);height=14.0+Hash21(float2(id,117))*11.0;
}
Geometry TreeGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;float3 center;float height,seed;
    TreePlacement(id,center,height,seed);g.seed=seed;g.moving=1;g.material=20;
    if(v<72)Cylinder(v,12,0,float3(0,height,0),0.20+height*0.008,g);
    else
    {
        uint segment=(v-72)/90,part=(v-72)%90;
        float tier=segment/95.0,branchSeed=Hash21(float2(segment,id+9));
        float y=(0.16+tier*0.80+(branchSeed-0.5)*0.016)*height;
        float a=segment*2.39996323+seed*TAU;
        float len=pow(saturate(1.0-y/height),0.72)*(3.0+height*0.10)*(0.66+branchSeed*0.40);
        float3 start=float3(0,y,0),end=float3(cos(a)*len,y-len*(0.12+branchSeed*0.17),sin(a)*len);
        float wind=sin(LoopAngle()*15.0+center.x*0.07+center.z*0.035+tier*0.25);
        end+=float3(0.19*wind,0.025*sin(LoopAngle()*35.0+segment),0.10*wind)*(y/height);
        if(part<18)Cylinder(part,3,start,end,0.038*(1.0-tier*0.72),g);
        else
        {
            uint card=(part-18)/6,clump=card/2;float2 uv=Corner(part-18);
            float t=0.28+clump*0.135,cardAngle=(card%2)*PI*0.5+branchSeed;
            float3 axis=normalize(end-start),side=normalize(cross(axis,float3(0,1,0))),up=cross(axis,side);
            float twigSide=clump%2==0?-1.0:1.0;
            float3 twigAxis=normalize(axis*0.68+side*twigSide*0.66+up*(0.15+branchSeed*0.15));
            float3 twigRight=normalize(cross(twigAxis,up)),twigUp=cross(twigAxis,twigRight);
            float3 radial=twigRight*cos(cardAngle)+twigUp*sin(cardAngle);
            float span=0.38+branchSeed*0.25,width=0.17+branchSeed*0.045;
            g.p=lerp(start,end,t)+twigAxis*(uv.x*span)+radial*((uv.y-0.5)*width*2.0);
            g.n=normalize(cross(twigAxis,radial));g.uv=uv;g.material=21;g.seed=branchSeed;
        }
    }
    float bend=pow(saturate(g.p.y/height),2.0);
    g.p.x+=bend*0.32*sin(LoopAngle()*15.0+center.z*0.021);g.p.z+=bend*0.21*sin(LoopAngle()*13.0+center.x*0.03);
    g.local=g.p;g.p+=center;
    bool water=center.y<LAKE_Y+0.7&&length((center.xz-LAKE_C)/float2(970,690))<1.08;
    if(water||center.y>930.0)g.p=center;
    return g;
}
Geometry GrassGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=22;g.moving=1;
    float2 cell=float2(id%128,id/128)-float2(64,48)+floor(CinematicFrame[0].xz/1.05);
    float seed=Hash21(cell);g.seed=seed;
    float2 xz=(cell+float2(seed,Hash21(cell+73.0)))*1.05;
    float ground=Terrain(xz);uint blade=v/6;float2 uv=Corner(v);
    float a=seed*TAU+blade*2.1,height=0.20+Hash21(cell+blade*19.0)*0.43;
    float3 right=float3(cos(a),0,sin(a)),origin=float3(xz.x,ground-0.015,xz.y);
    float3 bend=float3(0.11*sin(LoopAngle()*33.0+xz.x*0.55+xz.y*0.21),0,0.06*cos(LoopAngle()*27.0+xz.y*0.23));
    g.p=origin+right*((uv.x-0.5)*(0.035+seed*0.025)*(1.0-uv.y*0.94))+float3(0,uv.y*height,0)+bend*uv.y*uv.y;
    g.n=normalize(cross(right,float3(0,1,0)+bend));g.uv=uv;g.local=g.p-origin;
    // Include maximum blade bend so no tips grow across cobbles/plaza edges.
    bool road=(abs(xz.x)<3.85||length(xz-float2(0,1755))<10.35)&&xz.y>1600.0&&xz.y<2020.0;
    bool water=ground<LAKE_Y+0.4&&length((xz-LAKE_C)/float2(930,650))<1.1;
    if(road||water||ground>680.0||length(origin-CinematicFrame[0].xyz)>84.0)g.p=origin;
    return g;
}
Geometry RockGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=23;float seed=Hash21(float2(id,211));g.seed=seed;
    float2 xz;
    if(id<160)xz=float2((id%2==0?-1:1)*(5.0+seed*100.0),1600+Hash21(float2(id,213))*430.0);
    else
    {
        float a=id*2.39996323,r=0.87+seed*0.22;
        xz=LAKE_C+float2(cos(a)*930,sin(a)*650)*r;
    }
    float size=0.24+pow(seed,3.0)*2.8;float3 center=float3(xz.x,Terrain(xz)-size*0.24,xz.y);
    uint quad=v/6;float2 uv=Corner(v);float a=(quad%10+uv.x)*TAU/10.0,b=(quad/10+uv.y)*PI/4.0;
    float3 s=float3(cos(a)*sin(b),cos(b),sin(a)*sin(b));
    float irregular=0.76+0.31*Hash21(floor(s.xz*19+s.y*11)+id);
    float3 scale=float3(1.0,0.65+seed*0.43,0.71+seed*0.41)*size;
    g.p=center+s*scale*irregular;g.n=normalize(s/scale);g.uv=uv;g.local=g.p-center;return g;
}
Geometry GliderGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;g.material=30;g.moving=1;g.seed=id*0.21;
    float3 center,rr,uu,forward;
    ProceduralGliderPose(id,G.z,center,rr,uu,forward);
    uint part=v/36,q=v%36;
    if(part==0)Box(q,float3(0,0,0),float3(0.24,0.24,3.1),g);
    else if(part==1||part==2)
    {
        float side=part==1?-1.0:1.0;Box(q,float3(side*4.3,0.05,-0.5),float3(4.3,0.055,0.53),g);
        g.p.z+=abs(g.p.x)*0.055;g.p.y+=abs(g.p.x)*0.025;
    }
    else if(part==3)Box(q,float3(0,0.36,-2.6),float3(1.7,0.04,0.31),g);
    else if(part==4)Box(q,float3(0,0.55,-2.55),float3(0.045,0.55,0.42),g);
    else{Box(q,float3(0,0.22,1.2),float3(0.20,0.20,0.70),g);g.material=31;}
    g.local=g.p;g.p=center+rr*g.p.x+uu*g.p.y+forward*g.p.z;g.n=normalize(rr*g.n.x+uu*g.n.y+forward*g.n.z);return g;
}
Geometry ForestGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;float seed=Hash21(float2(id,317));g.seed=seed;g.moving=1;g.material=20;
    float2 xz;
    if(id<4608)
    {
        float a=id*2.39996323,r=0.975+Hash21(float2(id,323))*0.14;
        xz=LAKE_C+float2(cos(a)*930.0,sin(a)*650.0)*r;
    }
    else
    {
        uint k=id-4608;float z=1530.0+Hash21(float2(k,322))*980.0;
        float x=ValleyCenter(z)+(k%2==0?-1.0:1.0)*(130.0+seed*290.0);
        xz=float2(x,z);
    }
    float ground=Terrain(xz),height=13.0+seed*12.0;
    float3 center=float3(xz.x,ground-0.05,xz.y);
    if(v<36)Cylinder(v,6,0,float3(0,height*0.95,0),0.24,g);
    else
    {
        uint branch=(v-36)/6;float2 uv=Corner(v-36);
        float y=height*(0.12+branch*(0.84/41.0)),angle=branch*2.39996323+seed*TAU;
        float branchSeed=Hash21(float2(branch,id));
        float length=pow(saturate(1.0-y/height),0.73)*(4.2+seed*1.8)*(0.72+branchSeed*0.35);
        float3 axis=normalize(float3(cos(angle),-0.12-branchSeed*0.16,sin(angle)));
        float3 side=normalize(cross(axis,float3(0,1,0))),up=cross(axis,side);
        float cardAngle=branchSeed*PI;
        float3 radial=side*cos(cardAngle)+up*sin(cardAngle);
        g.p=float3(0,y,0)+axis*(0.10+uv.x*length)+radial*((uv.y-0.5)*(0.70+length*0.34));
        g.n=normalize(cross(axis,radial));g.uv=uv;g.material=24;
    }
    g.p.x+=pow(saturate(g.p.y/height),2.0)*0.30*sin(LoopAngle()*15.0+center.z*0.021);
    g.local=g.p;g.p+=center;
    float slope=length(float2(Terrain(xz+float2(3,0))-Terrain(xz-float2(3,0)),Terrain(xz+float2(0,3))-Terrain(xz-float2(0,3))))/6.0;
    bool water=ground<LAKE_Y+1.0&&length((xz-LAKE_C)/float2(970,690))<1.08;
    if(ground<150.0||ground>1050.0||slope>1.35||water)g.p=center;
    return g;
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
    if(instance>=50000)g=PersonShadowGeometry(vertex,instance-50000);
    else if(instance>=40000)g=ForestGeometry(vertex,instance-40000);
    else if(instance>=30000)g=GliderGeometry(vertex,instance-30000);
    else if(instance>=20000)g=RockGeometry(vertex,instance-20000);
    else if(instance>=2000)g=GrassGeometry(vertex,instance-2000);
    else if(instance>=1000)g=TreeGeometry(vertex,instance-1000);
    else g=HouseGeometry(vertex,instance);
    return g;
}
MeshOut PackGeometry(Geometry g)
{
    MeshOut o;o.world=g.p;o.normal=g.n;o.uv=g.uv;o.local=g.local;o.tag=float3(g.material,g.seed,g.moving);o.position=0;o.clipDistance=1;return o;
}
MeshOut MeshVS(uint vertex:SV_VertexID,uint instance:SV_InstanceID)
{
    instance+=Batch.x;
    Geometry g=BuildGeometry(vertex,instance);MeshOut o=PackGeometry(g);
    CameraFrame camera;camera.origin=CinematicFrame[0].xyz;camera.lens=CinematicFrame[0].w;
    camera.forward=CinematicFrame[1].xyz;camera.right=CinematicFrame[2].xyz;camera.up=CinematicFrame[3].xyz;
    camera=PassCameraFrame(camera);
    float3 d=g.p-camera.origin;float z=dot(d,camera.forward),lens=camera.lens;
    float2 xy=float2(dot(d,camera.right)/CinematicFrame[2].w,dot(d,camera.up))*lens;
    float2 jitter=TemporalJitter(((int)G.w)&7)*float2(-2.0/G.x,2.0/G.y);
    o.position=float4(xy+jitter*z,z*(MAX_DIST/(MAX_DIST-0.1))-0.1*MAX_DIST/(MAX_DIST-0.1),z);
    if(instance>=50000)o.position=float4(0,0,-1,1);
    o.clipDistance=PassMode.x>0.5?g.p.y-LAKE_Y:1.0;
    return o;
}
MeshOut ShadowVS(uint vertex:SV_VertexID,uint instance:SV_InstanceID)
{
    instance+=Batch.x;
    Geometry g=BuildGeometry(vertex,instance);MeshOut o=PackGeometry(g);
    o.position=float4(CinematicShadowPosition(g.p),1);return o;
}
void FoliageCoverage(MeshOut i)
{
    if(i.tag.x==21)
    {
        float2 uv=i.uv;float seed=i.tag.y;
        float span=0.38+seed*0.25,halfWidth=0.17+seed*0.045;
        float u=uv.x*span,v=abs((uv.y-0.5)*2.0*halfWidth);
        float envelope=halfWidth*(0.18+0.82*pow(saturate(sin(uv.x*PI)),0.62));
        // Secondary twig: offshoots every7.5cm, each with2.6cm needle reach.
        // Fine needles are1.2cm apart along the offshoot, about2mm thick.
        float dx=(frac((u-v*0.65)/0.075+seed*0.4+0.5)-0.5)*0.075;
        float needlePhase=v*1.2/0.012-abs(dx)*44.0;
        float needleDistance=abs(frac(needlePhase)-0.5)*0.012;
        float needleRadius=0.0011+min(0.0034,fwidth(needlePhase)*0.003);
        float needles=min(0.026-abs(dx),needleRadius-needleDistance);
        float offshoot=max(0.002-abs(dx),needles);
        clip(min(envelope-v,max(0.0025-v,offshoot)));
    }
    else if(i.tag.x==24)
    {
        float2 uv=i.uv;float y=abs(uv.y*2.0-1.0);
        float envelope=pow(saturate(1.0-abs(uv.x*2.0-1.0)),0.45);
        float lobes=0.73+0.16*sin(uv.x*47.0+i.tag.y*39.0)+0.10*sin(uv.x*113.0+i.tag.y*17.0);
        clip(envelope*lobes-y);
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
float4 MeshPS(MeshOut i,bool front:SV_IsFrontFace):SV_Target
{
    FoliageCoverage(i);float mat=i.tag.x,seed=i.tag.y;
    float3 n=normalize(i.normal),view=normalize(CinematicViewOrigin()-i.world);
    if(mat==21||mat==22||mat==24)n=dot(n,view)>=0.0?n:-n;
    float3 color=float3(0.65,0.61,0.51);float rough=0.78,metal=0,ao=1;
    float mottling=Noise2(i.world.xz*0.57+i.world.y*0.37);
    if(mat==1)
    {
        color=lerp(float3(0.63,0.61,0.53),float3(0.77,0.69,0.55),seed);
        color*=0.975+0.03*mottling;ao=lerp(0.78,1.0,smoothstep(0.6,2.0,i.local.y));
        color*=1.0-0.11*(1.0-smoothstep(0.65,1.5,i.local.y))*Noise2(i.local.xz*2.1);
    }
    else if(mat==2||mat==23)
    {
        color=lerp(float3(0.22,0.25,0.24),float3(0.39,0.37,0.31),mottling);
        if(mat==2)
        {
            float horizontal=abs(n.x)>abs(n.z)?i.local.z:i.local.x;
            float mortar=max(FilteredLines(i.local.y*3.0,0.045),FilteredLines(horizontal*1.8+floor(i.local.y*3.0)*0.5,0.045));
            color=lerp(color,float3(0.16,0.17,0.16),mortar*0.60);
        }
        else
        {
            n=normalize(cross(ddy(i.world),ddx(i.world)));
            n=dot(n,view)>=0.0?n:-n;
        }
        rough=0.91;
    }
    else if(mat==3||mat==6||mat==7)
    {
        color=lerp(float3(0.14,0.068,0.032),float3(0.29,0.16,0.075),seed);
        float board=FilteredLines(i.local.y*(mat==6?8.0:4.0),0.045);
        color*=0.79+0.25*mottling;color*=1.0-0.35*board;
        if(mat==6)color=lerp(color,float3(0.08,0.16,0.14),step(0.55,seed));
        ao=0.82;
    }
    else if(mat==4)
    {
        float row=floor(i.local.z*3.2),tile=Hash21(float2(floor(i.local.x*2.8+row*0.5),row)+seed*71);
        color=lerp(float3(0.14,0.17,0.18),float3(0.28,0.29,0.27),tile);
        float mortar=max(FilteredLines(i.local.z*3.2,0.055),FilteredLines(i.local.x*2.8+row*0.5,0.045));
        color*=1.0-mortar*0.40;rough=0.70;
    }
    else if(mat==5||mat==31){color=float3(0.022,0.032,0.040);rough=0.11;ao=0.20;}
    else if(mat==20){color=float3(0.14,0.095,0.052)*(0.8+0.4*mottling);rough=0.95;}
    else if(mat==21||mat==24)
    {
        color=lerp(float3(0.027,0.075,0.028),float3(0.075,0.14,0.049),seed);
        color*=0.78+0.35*i.uv.x;rough=0.88;ao=0.69;
    }
    else if(mat==22){color=lerp(float3(0.075,0.14,0.025),float3(0.19,0.23,0.047),seed);color*=0.6+0.4*i.uv.y;rough=0.91;ao=0.72+0.28*i.uv.y;}
    else if(mat==30){color=float3(0.76,0.80,0.79);rough=0.27;}
    float sunVisibility=CinematicShadow(i.world,n);
    float3 lit=CinematicLightingVisible(n,view,color,rough,metal,ao,sunVisibility);
    if(mat==21||mat==22||mat==24)
    {
        float transmission=pow(saturate(dot(-view,CinematicFrame[8].xyz)),3.0);
        lit+=color*CinematicSunColor()*transmission*0.48*sunVisibility;
    }
    if(mat==5||mat==31)
    {
        float fresnel=0.04+0.96*pow(1.0-saturate(dot(n,view)),5.0);
        lit+=float3(0.22,0.31,0.39)*fresnel*0.65;
    }
    float depth=EncodeDepth(length(i.world-CinematicViewOrigin()));
    return float4(CinematicFog(lit,i.world),i.tag.z>0.5?-depth:depth);
}
