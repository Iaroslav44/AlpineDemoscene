#ifndef ALPINE_ECOLOGY_GEOMETRY
#define ALPINE_ECOLOGY_GEOMETRY
// Include after Geometry, Corner and ecology_generation.hlsli.
// Materials:20 bark,25 statistical shoot surface,26 needle,27 crown envelope.
EcologyBranch EcologyLoadBranch(uint tree,uint segment)
{
    uint at=ECOLOGY_BRANCH_BASE+(tree*96u+segment)*3u;
    float4 a=SceneInstanceData[at],b=SceneInstanceData[at+1],c=SceneInstanceData[at+2];
    EcologyBranch branch;branch.start=a.xyz;branch.radius=a.w;
    branch.control=b.xyz;branch.seed=b.w;branch.end=c.xyz;branch.tipRadius=c.w;
    return branch;
}

void EcologyBranchTube(uint v,EcologyBranch b,inout Geometry g)
{
    float2 q=Corner(v);uint segment=v/18u,side=(v%18u)/6u;
    float u=(segment+q.y)/3.0,angle=(side+q.x)*TAU/3.0;
    float3 axis=EcologyBranchTangent(b,u);
    float3 right=EcologyUnit(cross(axis,abs(axis.y)<.9?float3(0,1,0):float3(1,0,0)));
    float3 up=cross(axis,right),normal=right*cos(angle)+up*sin(angle);
    float radius=lerp(b.radius,b.tipRadius,u);
    g.p=EcologyBranchPoint(b,u)+normal*radius;
    float taper=(b.radius-b.tipRadius)/max(length(b.end-b.start),.01);
    g.n=EcologyUnit(normal+axis*taper);g.uv=float2(angle/TAU,u);
}

float3 EcologyOctahedron(uint vertex)
{
    uint face=vertex/3u,k=vertex%3u;
    float vertical=face<4u?1.0:-1.0;uint quadrant=face%4u;
    if(k==0u)return float3(0,vertical,0);
    uint side=quadrant+(vertical>0?(2u-k):(k-1u));
    float angle=(side%4u)*TAU*.25;
    return float3(cos(angle),0,sin(angle));
}

void EcologyShoot(uint v,uint shoot,EcologyBranch b,EcologyTraits traits,inout Geometry g)
{
    uint key=traits.key+shoot*337u+(uint)(abs(b.seed)*8191.0);
    float u=.22+.31*(shoot%3u);
    float3 axis=EcologyBranchTangent(b,u),right=EcologyUnit(cross(axis,float3(0,1,0)));
    float3 up=cross(axis,right);
    float twist=EcologyRandom(key+3u)*TAU;
    float droop=traits.species==0u?-.58:(traits.species==1u?-.24:(traits.species==2u?.22:-.16));
    float3 shootAxis=EcologyUnit(axis*.62+right*cos(twist)*.34+float3(0,droop+sin(twist)*.14,0));
    float3 shootRight=EcologyUnit(cross(shootAxis,up)),shootUp=cross(shootAxis,shootRight);
    float branchLength=length(b.end-b.start);
    float halfLength=clamp(branchLength*.54+traits.crownRadius*.065,.22,.84);
    float radius=halfLength*(traits.species==2u?.26:(traits.species==1u?.19:.22));
    radius*=.88+.28*EcologyRandom(key+5u);
    float3 center=EcologyBranchPoint(b,u)+shootAxis*halfLength*.28;
    float packedSeed=(traits.species+EcologyRandom(key+29u))*.25;
    if(v<24u)
    {
        // A slim 3D inner twig-tuft core plus crossed procedural fir-needle frond
        // sprays below: dense volume from afar with feathery needles up close.
        float3 q=EcologyOctahedron(v);
        float lobe=1.0+.18*sin(q.x*3.0+q.z*2.0+EcologyRandom(key+7u)*TAU);
        float3 local=float3(q.x*radius*lobe,q.y*halfLength,q.z*radius*lobe);
        g.p=center+shootRight*local.x+shootAxis*local.y+shootUp*local.z;
        float3 n=EcologyUnit(float3(q.x/radius,q.y/halfLength,q.z/radius));
        g.n=EcologyUnit(shootRight*n.x+shootAxis*n.y+shootUp*n.z);
        g.local=local;g.uv=float2(radius,halfLength);g.material=25;
    }
    else
    {
        uint card=(v-24u)/6u,cv=(v-24u)%6u;
        float2 uv=Corner(cv);
        float tilt=(card==0u?-.68:.68)+(.22*EcologyRandom(key+11u+card*7u)-.11);
        float3 cardRight=shootRight*cos(tilt)+shootUp*sin(tilt);
        float3 cardNormal=EcologyUnit(cross(shootAxis,cardRight));
        float span=halfLength*1.76,halfW=radius*2.25;
        float along=(uv.x-.46)*span,across=(uv.y-.5)*2.0*halfW;
        float arch=-.11*along*along/max(span,.1);
        g.p=center+shootAxis*along+cardRight*across+cardNormal*arch;
        g.n=EcologyUnit(cardNormal+cardRight*(across/max(halfW,.05))*.28);
        g.local=float3(across,along,0);
        g.uv=uv;g.material=21;
    }
    g.seed=packedSeed;
    if(b.seed<0)g.p=b.start;
}

void EcologyBend(float height,float2 wind,inout Geometry g)
{
    float u=saturate(g.p.y/height);g.p.xz+=u*u*wind;
    g.n.y-=dot(g.n.xz,wind)*(2.0*u/height);g.n=EcologyUnit(g.n);
}

Geometry EcologyNearTreeGeometry(uint vertex,uint tree)
{
    Geometry g=(Geometry)0;g.material=20;g.moving=1;
    float4 a=SceneInstanceData[(64u+tree)*2u],b=SceneInstanceData[(64u+tree)*2u+1u];
    float height=a.w,seed=b.x;g.seed=seed;EcologyTraits traits=EcologyDescribe(height,seed);
    if(vertex<72u)
    {
        float2 q=Corner(vertex);uint segment=vertex/24u,side=(vertex%24u)/6u;
        float u=(segment+q.y)/3.0,angle=(side+q.x)*TAU/4.0;
        float3 radial=float3(cos(angle),0,sin(angle));
        float radius=height*.0105*(.80+.30*traits.age)*pow(max(.001,1.0-u*.97),1.18);
        g.p=EcologyStem(u*height,height,traits)+radial*radius;
        g.n=EcologyUnit(radial+float3(0,.012,0));g.uv=float2(angle/TAU,u);
    }
    else if(vertex<5256u)
    {
        uint q=vertex-72u;EcologyBranch branch=EcologyLoadBranch(tree,q/54u);
        EcologyBranchTube(q%54u,branch,g);
    }
    else
    {
        uint q=vertex-5256u,branchIdx=min(q/108u,95u),sub=(q%108u)/36u;
        EcologyBranch branch=EcologyLoadBranch(tree,branchIdx);
        EcologyShoot(q%36u,branchIdx*3u+sub,branch,traits,g);
    }
    if(g.material==20)g.local=g.p;
    EcologyBend(height,b.yz,g);g.p+=a.xyz;
    if(b.w<.5)g.p=a.xyz;return g;
}

Geometry EcologyCrownGeometry(uint vertex,float4 placement,float4 motion,uint rings,uint trunkVertices)
{
    Geometry g=(Geometry)0;g.material=20;g.moving=1;g.seed=motion.x;
    float height=placement.w;EcologyTraits traits=EcologyDescribe(height,motion.x);
    if(vertex<trunkVertices)
    {
        float2 q=Corner(vertex);float angle=(vertex/6u+q.x)*TAU/(trunkVertices/6u);
        float3 radial=float3(cos(angle),0,sin(angle));
        g.p=EcologyStem(q.y*height,height,traits)+radial*height*.011*(1.0-q.y*.97);
        g.n=radial;g.uv=q;g.local=g.p;
    }
    else
    {
        // One connected crown with a pointed leader. Separate stacked volumes
        // made distant firs resemble beads; the shell preserves continuous mass.
        uint v=vertex-trunkVertices,wallVertices=(rings-1u)*36u;
        float u=0,azimuth=0,radialScale=1;bool bottom=false;
        if(v<18u)
        {
            uint side=v/3u,k=v%3u;bottom=true;
            azimuth=(side+(k==1u?1u:0u))*TAU/6.0;
            radialScale=k==0u?0.0:1.0;
        }
        else if(v<18u+wallVertices)
        {
            uint q=v-18u,ring=q/36u,side=(q%36u)/6u;float2 corner=Corner(q);
            u=(ring+corner.y)/rings;azimuth=(side+corner.x)*TAU/6.0;
        }
        else
        {
            uint q=v-18u-wallVertices,side=q/3u,k=q%3u;
            u=k==0u?1.0:(rings-1.0)/rings;azimuth=(side+(k==2u?1u:0u))*TAU/6.0;
            radialScale=k==0u?0.0:1.0;
        }
        azimuth+=EcologyRandom(traits.key+71u)*TAU;
        float3 radial=float3(cos(azimuth),0,sin(azimuth));
        float irregular=.88+.10*sin(azimuth*3.0+traits.age*9.0)+.05*cos(azimuth*5.0+u*7.0);
        float width=traits.crownRadius*pow(max(.001,1.0-u),.72)*irregular*radialScale;
        float y=height*lerp(traits.crownBase,1.0,u);
        if(bottom&&radialScale==0)y-=height*.04;
        g.p=EcologyStem(y,height,traits)+radial*width;
        float slope=.72*traits.crownRadius/max(height*(1.0-traits.crownBase),.01)*pow(max(.03,1.0-u),-.28);
        g.n=bottom?EcologyUnit(radial*.25+float3(0,-1,0)):EcologyUnit(radial+float3(0,slope,0));
        g.local=float3(radial.x*width,y-height*(.5+.5*traits.crownBase),radial.z*width);
        g.uv=float2(traits.crownRadius,height*(1.0-traits.crownBase)*.5);g.material=27;
    }
    EcologyBend(height,motion.yz,g);g.p+=placement.xyz;
    if(motion.w<.5)g.p=placement.xyz;return g;
}
Geometry EcologyForestGeometry(uint vertex,uint group)
{
    uint tree=group*3u+vertex/96u;
    return EcologyCrownGeometry(vertex%96u,SceneInstanceData[(256u+tree)*2u],
        SceneInstanceData[(256u+tree)*2u+1u],2u,24u);
}
Geometry EcologyCoarseNearTreeGeometry(uint vertex,uint tree)
{
    return EcologyCrownGeometry(vertex,SceneInstanceData[(64u+tree)*2u],
        SceneInstanceData[(64u+tree)*2u+1u],6u,72u);
}

float EcologyCrownOccupancy(float3 local,float2 crownSize,float seed)
{
    float u=saturate(local.y/max(crownSize.y*2.0,.01)+.5);
    float azimuth=atan2(local.z,local.x+1e-6);
    EcologyTraits traits=EcologyDescribe(1.0,seed);
    float irregular=.88+.10*sin(azimuth*3.0+traits.age*9.0)+.05*cos(azimuth*5.0+u*7.0);
    float outer=max(.001,crownSize.x*pow(max(.001,1.0-u),.72)*irregular);
    // Coherent branch whorls are perturbed independently in height and azimuth.
    // This is a 3D object-space canopy occupancy field evaluated on a closed
    // conservative shell; no billboard plane or sampled alpha texture is used.
    float phase=u*(11.0+traits.age*3.0)+.23*sin(azimuth*3.0+seed*19.0)
        +.20*sin(u*23.0+seed*11.0);
    float tooth=pow(saturate(1.0-abs(frac(phase)-.53)*2.0),.65);
    float resolvedRadius=.80+.23*tooth;
    // When the branch pitch falls below the pixel footprint, converge to its
    // mean envelope. Final silhouette edge AA is provided by temporal resolve.
    float detail=1.0-smoothstep(.35,1.0,fwidth(phase));
    float envelope=outer*lerp(.93,resolvedRadius,detail);
    return envelope-length(local.xz);
}

// Band-limited needle density. Resolved needles modulate surface colour/normal;
// below a pixel their coverage converges to its area average instead of a binary
// repeating alpha-card comb.
float EcologyShootOccupancy(float3 local,float2 shootSize,float seed)
{
    float r=length(local.xz)/max(shootSize.x,.005);
    float axial=local.y/max(shootSize.y,.01);
    float angle=atan2(local.z,local.x+1e-6);
    float phase=local.y/.022+angle*(5.0/TAU)+seed*23.0;
    float tuft=pow(saturate(1.0-abs(frac(phase)-.5)*2.0),.55);
    float fine=.72+.28*sin(angle*11.0+local.y*88.0+seed*41.0);
    float detail=1.0-smoothstep(.28,.92,fwidth(phase));
    float taper=sqrt(saturate(1.0-axial*axial*.86));
    float outer=taper*lerp(.86,.52+.47*tuft*fine,detail);
    return outer-r;
}

float EcologyNeedleDensity(float3 local,float2 shootSize,float seed)
{
    float radius=max(shootSize.x,.005);
    float angle=atan2(local.z,local.x);
    float phase=local.y/.014+angle*(6.0/TAU)+seed*19.0;
    float footprint=max(fwidth(phase),1e-4);
    float distance=abs(frac(phase+.5)-.5);
    float resolved=1.0-smoothstep(.10-footprint,.10+footprint,distance);
    float density=lerp(resolved,.20,saturate(footprint*.75));
    float tip=saturate(abs(local.y)/max(shootSize.y,.01));
    return lerp(.58+.42*density,.72,smoothstep(radius*12.0,radius*36.0,shootSize.y))*(1.0-.08*tip);
}
float3 EcologyNeedleAlbedo(float seed,float density)
{
    uint species=min((uint)(seed*4.0),3u);float variation=frac(seed*4.0);
    // ~90% deep evergreen spruce, Swiss stone pine and silver fir; ~10% golden-
    // russet autumn European larch (species==3 && variation>=.58) on high slopes.
    bool isLarch=(species==3u)&&(variation>=.58);
    float larchT=saturate((variation-.58)/.42);
    float3 larch=lerp(float3(.082,.052,.014),float3(.148,.094,.020),larchT);
    float3 base=species==0u?float3(.013,.037,.015):
        (species==1u?float3(.018,.041,.017):(species==2u?float3(.012,.038,.023):
        (isLarch?larch:float3(.020,.043,.017))));
    float tone=isLarch?lerp(.88,1.12,larchT):lerp(.74,1.16,variation);
    return base*tone*lerp(.68,1.12,density);
}

// Intersection of a radial direction with seeded convex fracture half-spaces.
// Unlike independently displaced sphere vertices, each plane remains coherent
// over the whole stone and gives physically legible fracture faces.
void EcologyFracture(float3 direction,uint key,out float radius,out float3 normal)
{
    radius=2.0;normal=direction;
    float angle=EcologyRandom(key+3u)*TAU,c=cos(angle),s=sin(angle);
    [unroll] for(uint plane=0;plane<8u;++plane)
    {
        float3 n;
        if(plane<6u)
        {
            uint axis=plane/2u;float sign=plane%2u==0u?1.0:-1.0;
            n=axis==0u?float3(c*sign,0,s*sign):(axis==1u?float3(0,sign,0):float3(-s*sign,0,c*sign));
        }
        else
        {
            float z=EcologyRandom(key+plane*31u)*1.5-.75;
            float a=EcologyRandom(key+plane*31u+7u)*TAU;
            n=float3(cos(a)*sqrt(1.0-z*z),z,sin(a)*sqrt(1.0-z*z));
        }
        float distance=.60+.33*EcologyRandom(key+plane*47u+11u);
        float denominator=dot(direction,n);
        if(denominator>1e-4)
        {
            float hit=distance/denominator;if(hit<radius){radius=hit;normal=n;}
        }
    }
}
Geometry EcologyRockGeometry(uint vertex,uint rock)
{
    float4 placement=SceneInstanceData[(30976u+rock)*2u],shape=SceneInstanceData[(30976u+rock)*2u+1u];
    Geometry g=(Geometry)0;g.material=23;g.seed=shape.w;
    uint quad=vertex/6u;float2 uv=Corner(vertex);
    float azimuth=(quad%10u+uv.x)*TAU/10.0,polar=(quad/10u+uv.y)*PI/4.0;
    float3 direction=float3(cos(azimuth)*sin(polar),cos(polar),sin(azimuth)*sin(polar));
    float radius;float3 normal;EcologyFracture(direction,EcologyKey(shape.w)+rock*71u,radius,normal);
    g.local=direction*radius*shape.xyz;g.p=placement.xyz+g.local;
    g.uv=uv;g.n=EcologyUnit(normal/max(shape.xyz,.01));return g;
}
#endif
