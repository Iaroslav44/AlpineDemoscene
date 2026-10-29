#ifndef ALPINE_ECOLOGY_GENERATION
#define ALPINE_ECOLOGY_GENERATION
// Runtime plant architecture. No stored mesh, photograph or per-tree asset.
// Include after PlantDeflection, FrameOutput and the scene constants are defined.
// A bounded attraction-growth solver assigns each branch a crown sector; this
// is not the unbounded all-attractors/all-nodes space-colonization algorithm.
// Its fixed topology permits deterministic SIMD generation and conservative LOD.
static const uint ECOLOGY_BRANCH_BASE = 62720;
static const uint ECOLOGY_BRANCH_COUNT = 96;
static const uint ECOLOGY_BRANCH_STRIDE = 3;
static const uint ECOLOGY_BRANCH_END = 118016;
static const uint ECOLOGY_NEAR_VERTICES = 15624;
static const uint ECOLOGY_FAR_VERTICES = 96;
static const uint ECOLOGY_COARSE_NEAR_VERTICES = 288;

uint EcologyHash(uint x)
{
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15;
    x *= 0x846ca68bu; x ^= x >> 16; return x;
}
float EcologyRandom(uint x) { return (EcologyHash(x) >> 8) * (1.0 / 16777216.0); }
uint EcologyKey(float seed) { return (uint)(saturate(seed) * 16777215.0); }
float3 EcologyUnit(float3 v) { return v * rsqrt(max(dot(v,v),1e-12)); }

struct EcologyTraits
{
    float crownBase;
    float crownRadius;
    float droop;
    float upturn;
    float vitality;
    float age;
    uint species;
    uint key;
};
EcologyTraits EcologyDescribe(float height, float seed)
{
    EcologyTraits t=(EcologyTraits)0;
    t.species = min((uint)(seed * 4.0),3u);
    t.key = EcologyKey(seed);
    t.age = .12 + .88 * EcologyRandom(t.key + 17u);
    // Norway spruce, European larch, mountain pine and silver fir. Parameters
    // express architecture families, not a claim of botanical reconstruction.
    t.crownBase = t.species == 0 ? .14 : (t.species == 1 ? .29 : (t.species == 2 ? .11 : .22));
    t.crownBase += .10 * t.age * EcologyRandom(t.key + 23u);
    float slender = t.species == 0 ? .19 : (t.species == 1 ? .25 : (t.species == 2 ? .34 : .23));
    t.crownRadius = height * slender * (.78 + .28 * EcologyRandom(t.key + 29u));
    t.droop = t.species == 0 ? .24 : (t.species == 1 ? .12 : (t.species == 2 ? -.04 : .07));
    t.upturn = t.species == 0 ? .16 : (t.species == 1 ? .24 : (t.species == 2 ? .37 : .10));
    t.vitality = .78 + .20 * EcologyRandom(t.key + 31u);
    return t;
}

// eco=(watershed moisture, deposited soil, cumulative drainage, sky visibility).
// Keep the packed species/random seed in [0,1), so existing colour seeds remain
// usable. Call once in each raw placement function, including its CS invocation.
void EcologyAdjustPlacement(uint id, float3 center, float2 terrainGradient,
    float4 eco, inout float height, inout float seed, out float survival)
{
    uint key=EcologyHash(id + 19073u);
    float slope=length(terrainGradient), moisture=saturate(eco.x), soil=saturate(eco.y);
    float drainage=saturate(eco.z), visibility=saturate(eco.w);
    float cold=smoothstep(1150.0,1850.0,center.y);
    float dry=saturate((1.0-moisture)*.72 + slope*.16);
    float choice=EcologyRandom(key+1u);
    uint species=0u;
    if(cold>.58 || (dry>.58 && slope>.48)) species=2u;
    else if(choice < .16 + cold*.38 + visibility*.08) species=1u;
    else if(moisture>.46 && visibility<.76 && choice>.74) species=3u;
    else species=0u;
    seed=(species + .03 + .94*EcologyRandom(key+7u))*.25;
    float maturity=EcologyRandom(key+17u);
    // Mixed regeneration cohorts: saplings grow in canopy gaps; trees become
    // shorter on exposed slopes instead of remaining identical full-size cones.
    float cohort=lerp(.32,1.08,sqrt(maturity));
    float habitatScale=lerp(.66,1.0,moisture)*lerp(.80,1.03,soil);
    float speciesScale=species==2u?.57:(species==1u?.91:1.0);
    height=max(2.7,height*cohort*habitatScale*speciesScale);
    float treeline=1.0-smoothstep(1450.0,1910.0,center.y+(1.0-moisture)*90.0);
    float substrate=lerp(.38,1.0,saturate(soil*2.5+.2));
    float steep=1.0-smoothstep(.65,1.25,slope);
    // Drainage channels stay open. Moist slopes beside them remain favourable.
    float channel=1.0-smoothstep(.70,.96,drainage);
    float probability=saturate(treeline*substrate*steep*channel);
    survival=EcologyRandom(key+47u)<probability?1.0:0.0;
}

float3 EcologyStem(float y, float height, EcologyTraits t)
{
    float u=saturate(y/height), a=EcologyRandom(t.key+41u)*TAU;
    float lean=height*(.008+.026*t.age)*(u*u);
    return float3(cos(a)*lean,y,sin(a)*lean);
}

struct EcologyBranch
{
    float3 start;
    float3 control;
    float3 end;
    float radius;
    float tipRadius;
    float seed; // Negative seed identifies a retained dead branch without foliage.
};
float3 EcologyBranchPoint(EcologyBranch b,float u)
{
    float q=1.0-u;return b.start*q*q+2.0*b.control*q*u+b.end*u*u;
}
float3 EcologyBranchTangent(EcologyBranch b,float u)
{
    return EcologyUnit(lerp(b.control-b.start,b.end-b.control,u));
}

// Three growth steps towards four deterministic attractors in the branch's
// assigned crown sector. Targets within the kill radius stop contributing.
// Sector ownership bounds competition without a quadratic global search.
void EcologyAttractionGrowth(float3 start,float3 direction,float3 side,float length,
    uint key,float droop,float upturn,out float3 control,out float3 end)
{
    float3 target[4];
    [unroll] for(uint j=0;j<4;++j)
    {
        float along=.73+.37*EcologyRandom(key+j*13u);
        float across=(EcologyRandom(key+j*13u+3u)-.5)*.46;
        float lift=(EcologyRandom(key+j*13u+5u)-.5)*.20;
        target[j]=start+length*(direction*along+side*across+float3(0,lift,0));
    }
    float3 p=start,previous=direction,p1=start,p2=start;
    [unroll] for(uint step=0;step<3;++step)
    {
        float3 attraction=0;
        [unroll] for(uint k=0;k<4;++k)
        {
            float3 d=target[k]-p;float distanceSquared=dot(d,d);
            float alive=distanceSquared>length*length*.008?1.0:0.0;
            attraction+=d*rsqrt(max(distanceSquared,1e-9))*alive;
        }
        float tipLift=upturn*smoothstep(.2,1.0,step*.5);
        float3 next=EcologyUnit(attraction+previous*1.5+float3(0,tipLift-droop,0));
        p+=next*(length/3.0);previous=next;
        if(step==0)p1=p;if(step==1)p2=p;
    }
    end=p;control=p1+p2-.5*(start+end);
}

EcologyBranch EcologyPrimary(uint branch,float3 root,float height,float seed)
{
    EcologyTraits t=EcologyDescribe(height,seed);uint key=t.key+branch*277u;
    uint whorl=branch/4u,spoke=branch%4u;
    // Annual whorls overlap and lose branches unevenly. Stratify individual
    // attachment heights instead of producing six mechanically aligned shelves.
    float tier=(branch+.22+.65*EcologyRandom(key+1u))/24.0;
    float y=height*lerp(t.crownBase,.96,tier);
    float angle=(spoke+.14*(EcologyRandom(key+2u)-.5))*TAU*.25
        +whorl*2.39996323+EcologyRandom(t.key+43u)*TAU;
    float3 radial=float3(cos(angle),0,sin(angle));
    float3 side=float3(-radial.z,0,radial.x);
    float crownFraction=saturate((y/height-t.crownBase)/(1.0-t.crownBase));
    float span=t.crownRadius*pow(max(.02,1.0-crownFraction),.72)
        *(.78+.30*EcologyRandom(key+5u));
    EcologyBranch b=(EcologyBranch)0;b.start=EcologyStem(y,height,t);
    EcologyAttractionGrowth(b.start,radial,side,span,key+101u,t.droop,t.upturn,b.control,b.end);
    // Pipe model: each parent carries three child pipes plus a terminal shoot.
    // r_parent^2 = sum(r_child^2) + r_terminal^2, before distal taper.
    float childRadius=max(.004,height*.0011)*sqrt(max(.10,1.0-crownFraction));
    float terminalRadius=childRadius*.65;
    b.radius=sqrt(3.0*childRadius*childRadius+terminalRadius*terminalRadius);
    b.tipRadius=max(.002,b.radius*.16);
    b.seed=EcologyRandom(key+11u);
    if(EcologyRandom(key+19u)>t.vitality && whorl<3u)b.seed=-1.0-b.seed;
    float2 response=PlantDeflection(root+b.start,max(.04,.55*span*span),
        4.0*sqrt(3.0/max(span,.15)),.28,.20*span);
    float3 axis=EcologyUnit(b.end-b.start),wind=float3(response.x,0,response.y);
    wind-=axis*dot(wind,axis);
    // A physical response is bounded for conservative culling under rare gusts.
    wind*=min(1.0,.30*span/max(length(wind),1e-5));
    b.control+=wind*.28;b.end+=wind;
    return b;
}

EcologyBranch EcologyBuildBranch(uint segment,float3 root,float height,float seed)
{
    uint secondary=segment>=24u?segment-24u:0u;
    uint parent=segment<24u?segment:secondary/3u,child=secondary%3u;
    EcologyBranch p=EcologyPrimary(parent,root,height,seed),b=p;
    if(segment>=24u)
    {
    EcologyTraits t=EcologyDescribe(height,seed);uint key=t.key+segment*277u;
    float u=.32+child*.22+.025*(EcologyRandom(key+3u)-.5);
    b.start=EcologyBranchPoint(p,u);
    float3 axis=EcologyBranchTangent(p,u),side=EcologyUnit(cross(axis,float3(0,1,0)));
    float sign=child==1u?-1.0:1.0;
    float3 direction=EcologyUnit(axis*.38+side*sign*.89+float3(0,t.upturn*.55,0));
    float span=length(p.end-p.start)*(.34+.16*EcologyRandom(key+7u))*(1.0-.20*u);
    // Secondary shoot attraction already inherits the deformed parent joint.
    b.control=b.start+direction*span*.54+float3(0,-t.droop*span*.18,0);
    b.end=b.start+direction*span+float3(0,t.upturn*span*.15,0);
    b.radius=p.radius/sqrt(3.0+.65*.65);b.tipRadius=max(.0012,b.radius*.12);
    b.seed=EcologyRandom(key+13u);if(p.seed<0)b.seed=-1.0-b.seed;
    float2 response=PlantDeflection(root+b.start,max(.008,.18*span*span),
        7.0*sqrt(1.5/max(span,.10)),.32,.085*span);
    float3 wind=float3(response.x,0,response.y);wind-=axis*dot(wind,axis);
    wind*=min(1.0,.23*span/max(length(wind),1e-5));
    b.control+=wind*.35;b.end+=wind;
    }
    return b;
}

void EcologyStoreBranch(uint tree,uint segment,float3 root,float height,float seed)
{
    if(tree>=192u || segment>=ECOLOGY_BRANCH_COUNT)return;
    EcologyBranch b=EcologyBuildBranch(segment,root,height,seed);
    uint at=ECOLOGY_BRANCH_BASE+(tree*ECOLOGY_BRANCH_COUNT+segment)*ECOLOGY_BRANCH_STRIDE;
    FrameOutput[at]=float4(b.start,b.radius);
    FrameOutput[at+1]=float4(b.control,b.seed);
    FrameOutput[at+2]=float4(b.end,b.tipRadius);
}

float EcologyBoundsRadius(float height,float seed,float2 trunkWind)
{
    EcologyTraits t=EcologyDescribe(height,seed);
    // Secondary tips can extend beyond their parent's crown sector; needle
    // shoots and both levels of branch flex are included in this sphere.
    float horizontal=t.crownRadius*1.75+height*.04+length(trunkWind)+.8;
    return sqrt(horizontal*horizontal+height*height*.29)+.3;
}

void EcologyAdjustRock(float4 eco,float2 terrainGradient,inout float size,out float burial)
{
    float slope=length(terrainGradient);
    // Depositional soil buries small stones; erosive slopes expose fractured ones.
    burial=lerp(.18,.58,saturate(eco.y*(1.0-smoothstep(.25,.8,slope))));
    size*=lerp(.74,1.30,saturate(slope*.65+eco.z*.35));
}
#endif
