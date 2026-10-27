#ifndef ALPINE_SETTLEMENT_GEOMETRY
#define ALPINE_SETTLEMENT_GEOMETRY
// Runtime architectural grammar:64 parcels, five vernacular building types,
// one chapel. No model file, raster facade or precomputed mesh is consumed.
// Each instance emits320 parts of36 vertices (11520 vertices); unused parts collapse.
void HousePlacementRaw(uint id,out float3 center,out float3 size,out float angle,out float seed)
{
    seed=Hash21(float2(id,71));float2 p;
    uint style=id%5;
    if(id<16)
    {
        uint row=id/2;float side=(id&1)?1.0:-1.0;
        float z=1634.0+row*43.0+Hash21(float2(id,39))*13.0;
        p=float2(side*(15.5+Hash21(float2(id,19))*6.5),z);
        angle=(side>0?0:PI)+(Hash21(float2(id,53))-.5)*.11;
    }
    else
    {
        uint k=id-16,side=k%2,row=k/8,lane=(k/2)%4;
        float z=1603.0+row*70.0+(lane%2)*23.0+Hash21(float2(id,39))*17.0;
        float x=(side?1.0:-1.0)*(43.0+lane*24.0+Hash21(float2(id,19))*8.0);
        p=float2(x,z);
        angle=(side?0:PI)+(Hash21(float2(id,53))-.5)*.42;
    }
    size=float3(4.2+seed*2.0,5.2+Hash21(float2(id,43))*2.8,5.0+Hash21(float2(id,47))*2.7);
    if(style==2){size.y*=.74;size.z*=1.25;}
    if(style==3){size.x*=1.16;size.z*=1.12;}
    if(id==31){p=float2(-38,1837);size=float3(5.0,7.2,10.5);angle=.08;}
    else if(length(p-float2(-38,1837))<28.0)p.x-=100.0;
    center=float3(p.x,Terrain(p)-.12,p.y);
}
void HousePlacement(uint id,out float3 center,out float3 size,out float angle,out float seed)
{
    float4 a=SceneInstanceData[id*2],b=SceneInstanceData[id*2+1];
    center=a.xyz;angle=a.w;size=b.xyz;seed=b.w;
}
void ArchitecturalBox(uint v,float3 center,float3 halfSize,float zAngle,inout Geometry g)
{
    Box(v,0,halfSize,g);g.p=RotateZ(g.p,zAngle)+center;g.n=RotateZ(g.n,zAngle);
}
void Spire(uint v,float3 center,float radius,float height,inout Geometry g)
{
    uint tri=(v/3)%4,k=v%3;float a=tri*PI*.5+PI*.25,b=a+PI*.5;
    float3 p=float3(cos(a)*radius,0,sin(a)*radius),q=float3(cos(b)*radius,0,sin(b)*radius),t=float3(0,height,0);
    g.p=center+(k==0?p:(k==1?q:t));g.n=normalize(cross(t-p,q-p));g.uv=g.p.xz;
    if(v>=12)g.p=center;
}
Geometry HouseGeometry(uint v,uint id)
{
    Geometry g=(Geometry)0;float3 center,hs;float angle,seed;
    HousePlacement(id,center,hs,angle,seed);g.seed=seed;g.material=1;
    uint part=v/36,q=v%36,style=id%5;bool chapel=id==31;
    float pitch=chapel?1.05:(.62+.26*Hash21(float2(id,57)));
    float roofRise=hs.x*pitch,roofAngle=atan(pitch),roofHalf=hs.x+.78;
    float balconyY=min(3.45,hs.y*.57),windowHigh=hs.y*.70;
    float3 c=0,b=0;bool explicitGeometry=false;
    // A stone plinth carries the actual building; upper bodies vary between
    // lime plaster, exposed masonry and horizontal/vertical timber boarding.
    if(part==0){c=float3(0,.43,0);b=float3(hs.x+.15,.57,hs.z+.15);g.material=2;}
    else if(part==1){c=float3(0,hs.y*.5,0);b=float3(hs.x,hs.y*.5,hs.z);g.material=(style==0||style==2)?35:(style==4?2:1);}
    else if(part==2){c=float3(0,hs.y-.37,0);b=float3(hs.x+.09,.37,hs.z+.09);g.material=35;}
    else if(part==3||part==4)
    {
        float side=part==3?-1.0:1.0;
        ArchitecturalBox(q,float3(side*roofHalf*.5,hs.y+roofRise-roofHalf*pitch*.5,0),
            float3(roofHalf*.5*sqrt(1.0+pitch*pitch),.12,hs.z+.84),-side*roofAngle,g);
        g.material=4;explicitGeometry=true;
    }
    else if(part==5||part==6)
    {
        Gable(q,hs.x,roofRise,.07,hs.y,g);g.p.z+=(part==5?1.0:-1.0)*(hs.z-.07);
        g.material=chapel?1:35;explicitGeometry=true;
    }
    else if(part==7){c=float3(hs.x*.37,hs.y+roofRise-.15,hs.z*.35);b=float3(.39,1.2,.44);g.material=2;}
    else if(part==8){c=float3(-hs.x-.75,.15,0);b=float3(.8,.16,1.45);g.material=2;}
    else if(part==9){c=float3(-hs.x-.025,1.18,0);b=float3(.08,1.18,.68);g.material=3;}
    else if(part==10){c=float3(-hs.x-.12,1.14,0);b=float3(.025,1.03,.53);g.material=7;}
    else if(part<83)
    {
        uint wi=(part-11)/6,wp=(part-11)%6,face=wi/4,w=wi%4;
        float side=face==0?-1.0:1.0;
        float height=w/2==0?1.95:windowHigh;
        float along=(w%2==0?-1.0:1.0)*(face<2?hs.z*.54:hs.x*.54);
        float3 wc=face<2?float3(side*(hs.x+.085),height,along):float3(along,height,hs.z+.085);
        float3 wb=float3(.11,.88,.66),offset=0;g.material=3;
        if(wp==1){wb=float3(.027,.76,.55);offset.x=.12;g.material=5;}
        else if(wp==2){wb=float3(.036,.78,.022);offset.x=.16;}
        else if(wp==3){wb=float3(.038,.027,.57);offset.x=.16;}
        else if(wp==4||wp==5){wb=float3(.065,.84,.21);offset=float3(.015,0,(wp==4?-1.0:1.0)*.89);g.material=6;}
        if(face<2){offset.x*=side;c=wc+offset;b=wb;}else{c=wc+float3(offset.z,offset.y,offset.x);b=wb.zyx;}
    }
    else if(part==83){c=float3(-hs.x-.85,balconyY,0);b=float3(1.10,.13,hs.z*.87);g.material=35;}
    else if(part==84){c=float3(-hs.x-1.90,balconyY+1.04,0);b=float3(.072,.06,hs.z*.87);g.material=3;}
    else if(part==85){c=float3(-hs.x-1.90,balconyY+.49,0);b=float3(.07,.05,hs.z*.87);g.material=3;}
    else if(part<90)
    {
        uint rail=part-86;c=float3((rail<2?-1.0:1.0)*(hs.x+2.05),.55+(rail%2)*.40,hs.z+2.1);
        b=float3(.055,.055,3.5);g.material=3;
    }
    else if(part<98)
    {
        uint post=part-90;c=float3((post<4?-1.0:1.0)*(hs.x+2.05),.59,hs.z-1.4+(post%4)*2.33);
        b=float3(.065,.62,.065);g.material=3;
    }
    else if(part<102){float stair=part-98;c=float3(-hs.x-1.1-stair*.36,.13-stair*.025,0);b=float3(.25,.15-stair*.025,.91);g.material=2;}
    else if(part<108)
    {
        uint beam=part-102;float side=(beam%2)?1.0:-1.0;
        c=float3(side*(hs.x+.055),hs.y*.48,((int)(beam/2)-1)*hs.z*.86);b=float3(.09,hs.y*.48,.11);g.material=3;
    }
    else if(part<112)
    {
        uint beam=part-108;float side=(beam%2)?1.0:-1.0;
        c=float3(side*(hs.x+.07),beam<2?balconyY:hs.y-.2,0);b=float3(.085,.12,hs.z);g.material=3;
    }
    else if(part<128)
    {
        uint spindle=part-112;c=float3(-hs.x-1.88,balconyY+.54,lerp(-hs.z*.83,hs.z*.83,spindle/15.0));
        b=float3(.075,.50,.055);g.material=3;
    }
    else if(part<132)
    {
        uint pipe=part-128;float side=(pipe%2)?1.0:-1.0;
        if(pipe<2){c=float3(side*(roofHalf+.04),hs.y-.14,0);b=float3(.095,.065,hs.z+.82);}
        else{c=float3(side*(hs.x+.16),hs.y*.5,hs.z-.35);b=float3(.045,hs.y*.5,.045);}
        g.material=36;
    }
    else if(part<140)
    {
        uint rafter=part-132;float side=(rafter%2)?1.0:-1.0,z=lerp(-hs.z,hs.z,(rafter/2)/3.0);
        ArchitecturalBox(q,float3(side*roofHalf*.51,hs.y+roofRise-roofHalf*pitch*.51-.22,z),
            float3(roofHalf*.54*sqrt(1.0+pitch*pitch),.105,.09),-side*roofAngle,g);
        g.material=3;explicitGeometry=true;
    }
    else if(part<156)
    {
        // Two genuinely projecting dormers break the uninterrupted roof slab.
        uint dormer=(part-140)/8,piece=(part-140)%8;float z=(dormer?1:-1)*hs.z*.46;
        float x=-hs.x*.55,y=hs.y+roofRise*.47;
        if(piece==0){c=float3(x,y,z);b=float3(1.20,.80,.93);g.material=35;}
        else if(piece==1||piece==2)
        {
            float s=piece==1?-1:1;
            ArchitecturalBox(q,float3(x,y+1.15,z+s*.50),float3(1.38,.09,.64),0,g);
            // Rotate around localX, so each half slopes down toward itsZ eave.
            float3 p=g.p-float3(x,y+1.15,z+s*.50);
            g.p=RotateZ(p.zyx,-s*.55).zyx+float3(x,y+1.15,z+s*.50);
            g.n=RotateZ(g.n.zyx,-s*.55).zyx;g.material=4;explicitGeometry=true;
        }
        else if(piece==3){c=float3(x-1.22,y,z);b=float3(.04,.57,.62);g.material=5;}
        else if(piece==4){c=float3(x-1.27,y,z);b=float3(.05,.60,.027);g.material=3;}
        else if(piece==5){c=float3(x-1.27,y,z);b=float3(.05,.027,.65);g.material=3;}
        else if(piece==6){c=float3(x-1.25,y+.63,z);b=float3(.06,.07,.72);g.material=3;}
        else{c=float3(x-1.25,y-.63,z);b=float3(.06,.07,.72);g.material=3;}
        if(style==2||chapel){c=0;b=0;explicitGeometry=false;}
    }
    else if(part<180)
    {
        // Rough stone garden walls and individual cap stones, with a gate gap.
        uint stone=part-156,row=stone/12,col=stone%12;float side=col<6?-1:1;
        float z=hs.z+2.8+(col%6)*.72;
        c=float3(side*(hs.x+2.7),.24+row*.43,z);
        b=float3(.28,.225,.37)*(.93+.09*Hash21(float2(stone,id)));g.material=2;
    }
    else if(part<196)
    {
        uint flower=part-180,box=flower/4,piece=flower%4;
        float z=(box%2?1:-1)*hs.z*.54,y=box<2?1.12:windowHigh-.84;
        if(piece==0){c=float3(-hs.x-.31,y,z);b=float3(.31,.19,.77);g.material=35;}
        else if(piece==1){c=float3(-hs.x-.33,y+.20,z);b=float3(.30,.07,.71);g.material=37;}
        else
        {
            float offset=piece==2?-.34:.34;c=float3(-hs.x-.40,y+.30+.07*sin(G.z+id),z+offset);
            b=float3(.20,.12,.25);g.material=38;g.moving=1;
        }
    }
    else if(part<212)
    {
        uint slab=part-196;float x=-hs.x-1.1-(slab/4)*.64,z=((int)(slab%4)-1.5)*.49;
        c=float3(x,.15,z);b=float3(.30,.08,.23);g.material=39;
    }
    else if(part<224)
    {
        uint trim=part-212;float side=(trim%2)?1:-1,z=lerp(-hs.z,hs.z,(trim/2)/5.0);
        c=float3(side*(roofHalf-.1),hs.y-.25,z);b=float3(.18,.22,.105);g.material=3;
    }
    else if(part<304)
    {
        // Raised overlapping roof courses: silhouette and specular breakup.
        uint shingle=part-224,side=shingle/40,row=(shingle%40)/10,col=shingle%10;
        float sx=side?1:-1,u=(row+.5)/4.0,z=lerp(-hs.z-.65,hs.z+.65,(col+.5)/10.0);
        float x=sx*roofHalf*u,y=hs.y+roofRise-roofHalf*pitch*u+.16;
        ArchitecturalBox(q,float3(x,y,z),float3(roofHalf*.126*sqrt(1+pitch*pitch),.04,(hs.z+.8)*.103),-sx*roofAngle,g);
        g.material=4;explicitGeometry=true;
    }
    else if(chapel)
    {
        uint piece=part-304;float z=hs.z-2.0;
        if(piece==0){c=float3(0,8.6,z);b=float3(2.45,8.6,2.45);g.material=1;}
        else if(piece==1){c=float3(0,16.8,z);b=float3(2.65,.22,2.65);g.material=2;}
        else if(piece==2){Spire(q,float3(0,17.0,z),4.05,11.0,g);g.material=4;explicitGeometry=true;}
        else if(piece==3){c=float3(0,28.35,z);b=float3(.065,.83,.065);g.material=36;}
        else if(piece==4){c=float3(0,28.55,z);b=float3(.46,.055,.055);g.material=36;}
        else if(piece<9)
        {
            uint face=piece-5;float side=(face%2)?1:-1;
            c=face<2?float3(side*2.47,14.7,z):float3(0,14.7,z+side*2.47);
            b=face<2?float3(.025,1.1,.63):float3(.63,1.1,.025);g.material=40;
        }
        else if(piece<13)
        {
            uint face=piece-9;float side=(face%2)?1:-1;
            c=face<2?float3(side*2.49,11.9,z):float3(0,11.9,z+side*2.49);
            b=face<2?float3(.035,.72,.72):float3(.72,.72,.035);g.material=41;
        }
        else{c=0;b=0;}
    }
    else
    {
        uint piece=part-304;
        if(piece<8){c=float3(-hs.x-1.80,balconyY*.48,lerp(-hs.z*.77,hs.z*.77,piece/7.0));b=float3(.08,balconyY*.48,.08);g.material=3;}
        else if(piece<12){c=float3(hs.x+1.1,.36,((int)(piece-8)-1.5)*1.1);b=float3(.70,.35,.45);g.material=35;}
        else{c=float3(hs.x+1.1,.77,((int)(piece-12)-1.5)*1.1);b=float3(.55,.12,.37);g.material=37;}
    }
    if(!explicitGeometry)Box(q,c,b,g);
    // Projected outbuildings/gardens on parcels never encroach on the walk lane.
    g.local=g.p;g.p=RotateY(g.p,angle)+center;g.n=RotateY(g.n,angle);
    return g;
}
#endif
