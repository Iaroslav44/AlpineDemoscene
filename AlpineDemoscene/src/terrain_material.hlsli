// Runtime-generated mipmapped material layers replace per-pixel synthetic grain.
// This file is included after TerrainNormal/TerrainShadow and the sky helpers.
#include "geomorph_common.hlsli"
float TerrainCavity(float3 p,float3 n,out float3 bentNormal,out float deposition)
{
    // Eight horizon directions at four radii are computed once after erosion.
    // This replaces twelve redundant terrain reads for every shaded pixel.
    float4 ecology=WorldEcology(p.xz);
    bentNormal=n;deposition=ecology.y;return ecology.w;
}
float3 ShadeTerrain(float3 p,float3 rd,float3 sun,float loopA,float footprint)
{
    float3 baseNormal=TerrainNormal(p.xz);float slope=1.0-baseNormal.y;
    float3 bentNormal;float deposition;
    float cavity=TerrainCavity(p,baseNormal,bentNormal,deposition);
    float4 ecology=WorldEcology(p.xz);
    float macro=GeologicalNoise(p.xz*.0017+17.0);
    float field=GeologicalNoise(p.xz*.0083+float2(13.5,7.1));
    float rockWeight=smoothstep(.11,.33,slope+(field-.5)*.055+(0.45-deposition)*.10);
    RuntimeMaterial rock=TriplanarRuntimeMaterial(0,p,baseNormal,.20,.72);
    RuntimeMaterial meadow=SampleNaturalMaterial(1,p.xz*.34);
    float3 grassNormal=normalize(baseNormal+float3(meadow.normal.x,0,meadow.normal.y)*.28);
    float3 n=normalize(lerp(grassNormal,rock.normal,rockWeight));
    // Biome and deposition are correlated with slope/aspect/elevation rather
    // than painting every empty surface the same saturated green. Sheltered
    // lower slopes keep lush turf; exposed high slopes carry dry grass/scree.
    float north=saturate(dot(baseNormal,float3(.24,0,.97))*.5+.5);
    float dry=saturate(.52*macro+.30*(1-north)+smoothstep(680,1420,p.y)*.52-.24);
    float3 grass=meadow.albedo*lerp(float3(.86,.96,.80),float3(1.04,.93,.74),field);
    grass=lerp(grass,float3(.088,.076,.044)*(.84+.28*field),dry*.66);
    // Gentle pastoral grading without high-contrast amoeba spots.
    float2 pastureUV=p.xz*.0048+float2(
        Noise2(p.xz*.0017+float2(8.4,31.2)),
        Noise2(p.xz*.0021+float2(47.8,4.1)))*1.15;
    float pasture=.68*Noise2(pastureUV+13.7)+.32*Noise2(pastureUV*2.31+41.2);
    float lowland=(1-smoothstep(.10,.26,slope))*(1-smoothstep(740,1180,p.y));
    float hayBench=smoothstep(.46,.76,pasture)*lowland*(1-deposition*.45);
    float moistSwale=saturate(deposition*.55+ecology.x*.35-.32)*lowland;
    grass=lerp(grass,float3(.086,.078,.042)*(.88+.22*macro),hayBench*.36);
    grass=lerp(grass,float3(.028,.050,.020)*(.90+.20*field),moistSwale*.38);
    grass*=lerp(.91,1.07,smoothstep(.25,.75,pasture));
    // Woodland needle-duff and under-canopy moss darken forested slopes and
    // hills north/south of the village so slopes read as dark Alpine woodland.
    float acrossValley=abs(p.x-ValleyCenter(p.z));
    float townClear=1.0-smoothstep(145.0,275.0,length((p.xz-TOWN_C)/float2(.80,1.0)));
    float lakeRad=length((p.xz-LAKE_C)/float2(900.0,610.0));
    float northValleyWood=smoothstep(2060.0,2260.0,p.z)*(1.0-smoothstep(3850.0,4250.0,p.z));
    float flankBelt=max(smoothstep(125.0,245.0,acrossValley)*smoothstep(760.0,1120.0,p.z),northValleyWood*.88);
    float lakeBelt=smoothstep(.99,1.08,lakeRad)*(1.0-smoothstep(1.52,1.90,lakeRad));
    float grovePatch=smoothstep(.24,.60,GeologicalNoise(p.xz*.0038+float2(31.4,9.7))*.72+.28*ecology.x);
    float treelineMask=(1.0-smoothstep(1340.0,1740.0,p.y+(macro-.5)*160.0))*smoothstep(147.0,185.0,p.y);
    float woodland=saturate(max(flankBelt,lakeBelt)*grovePatch*treelineMask*(1.0-townClear)*(1.0-smoothstep(.28,.52,slope)));
    float3 forestFloor=lerp(float3(.018,.026,.013),float3(.032,.025,.015),field);
    grass=lerp(grass,forestFloor*(.82+.32*macro),woodland*.82);

    float mineralField=RockNoise(p*.0073+float3(9.2,17.1,3.8)).x;
    float weathering=RockNoise(p*.0026+float3(3.1,11.7,23.9)).x;
    float strata=.5+.5*sin(p.y*.135+p.x*.022+p.z*.017+weathering*4.8);
    // Dark Alpine graphitic gneiss and slate crags for high drama against snow
    // and white waterfall foam (matching scene0, scene2, scene3, scene4).
    float3 mineral=lerp(float3(.36,.39,.43),float3(.54,.52,.48),mineralField);
    float3 rockAlbedo=rock.albedo*mineral*(.56+.26*weathering)*(.78+.28*strata);
    float iron=smoothstep(.59,.77,weathering)*smoothstep(.20,.43,slope);
    rockAlbedo=lerp(rockAlbedo,rockAlbedo*float3(1.16,.86,.64),iron*.26);
    float3 albedo=lerp(grass,rockAlbedo,rockWeight);
    // Sub-metre fractures alter shading, while resolved silhouettes remain
    // the generated height field. Fade this band by the ray footprint.
    float4 grain=RockNoise(p*.19+float3(1.3,8.1,4.7));
    float3 micro=grain.yzw-baseNormal*dot(grain.yzw,baseNormal);
    n=normalize(n-micro*(.14*rockWeight*DetailBand(footprint,.19)));
    float rough=lerp(meadow.roughness,rock.roughness,rockWeight);
    float scree=smoothstep(680,1260,p.y+(macro-.5)*240)
        *(1-smoothstep(.28,.54,slope))*(.45+.55*field);
    if(scree>.025)
    {
        RuntimeMaterial gravel=SampleNaturalMaterial(7,p.xz*.65);
        float3 deposits=lerp(rockAlbedo*.88,gravel.albedo*float3(.56,.58,.60),.42);
        albedo=lerp(albedo,deposits,scree);rough=lerp(rough,.90,scree);
        float3 gravelNormal=normalize(baseNormal+float3(gravel.normal.x,0,gravel.normal.y)*.32);
        n=normalize(lerp(n,gravelNormal,scree*.65));
    }
    // Glacial shingle and boulder littoral zone around the Alpine lake.
    float littoral=(1.0-smoothstep(.15,3.8,abs(p.y-LAKE_Y)+max(0.0,p.y-LAKE_Y)*.35))
        *(1.0-smoothstep(.92,1.14,lakeRad))*(1.0-smoothstep(.26,.50,slope));
    if(littoral>.015)
    {
        RuntimeMaterial shoreStones=SampleNaturalMaterial(7,p.xz*.82);
        float3 shingle=shoreStones.albedo*lerp(float3(.62,.63,.62),float3(.86,.84,.80),field);
        albedo=lerp(albedo,shingle,littoral*.88);
        rough=lerp(rough,.80,littoral*.85);
        float3 shoreN=normalize(baseNormal+float3(shoreStones.normal.x,0,shoreStones.normal.y)*.48);
        n=normalize(lerp(n,shoreN,littoral*.80));
    }
    // Deep Alpine snowpack across upper massifs, gullies, couloirs and cirques;
    // only sheer vertical arêtes (slope > .52..76) shed snow to bare dark gneiss.
    float couloir=saturate((ecology.z-.32)*1.65+(deposition-.32)*.95)*smoothstep(.04,.42,slope);
    float snowOffset=(GeologicalNoise(p.xz*.0058)-.5)*185.0-couloir*290.0-(north-.5)*155.0;
    float sheltered=1.0-smoothstep(.40+.14*couloir,.76,slope);
    float snowPatch=smoothstep(.14,.42,GeologicalNoise(p.xz*.022)+baseNormal.y*.32+couloir*.30);
    float snow=smoothstep(1180.0,1540.0,p.y+snowOffset)*sheltered*snowPatch;
    float3 sastrugi=GeologicalField(p.xz*.085+float2(19.3,4.7));
    float3 snowNormal=normalize(baseNormal+float3(sastrugi.y,0,sastrugi.z)*(.055*DetailBand(footprint,.09)));
    albedo=lerp(albedo,float3(.87,.90,.935),snow);
    rough=lerp(rough,.50,snow);n=normalize(lerp(n,snowNormal,snow*.86));
    float moss=(1.0-rockWeight)*(1-snow)*smoothstep(.53,.77,macro)*north;
    albedo*=1-.12*moss;
    // Wet glistening dark rock across the waterfall amphitheatre and splash cliff.
    float damp=exp(-pow((p.x-350.0)/115.0,2))*smoothstep(4650,4775,p.z)*(1-smoothstep(4935,5010,p.z));
    float shoreline=(1-smoothstep(.15,2.2,abs(p.y-LAKE_Y)))*smoothstep(0.0,.26,slope)
        *(1-smoothstep(1.0,1.25,lakeRad));
    damp=max(damp,shoreline*.82);
    albedo*=1-.58*damp*(1.0-snow*.7);rough=lerp(rough,.16,damp*(1.0-snow));
    float2 town=p.xz-TOWN_C;
    float edgeWobble=(Noise2(p.xz*.22)-.5)*.42+(Noise2(p.xz*.79+13.1)-.5)*.18;
    float laneDist=abs(town.x)+edgeWobble;
    float laneLen=1-smoothstep(172,242,abs(town.y));
    float plazaDist=length((p.xz-float2(0,1755))/float2(.78,1))+edgeWobble*.6;
    float road=max((1-smoothstep(2.65,3.45,laneDist))*laneLen,1-smoothstep(5.8,9.8,plazaDist));
    float verge=saturate(max((1-smoothstep(3.1,4.5,laneDist))*laneLen,1-smoothstep(8.8,11.6,plazaDist))-road)*(1-snow);
    if(verge>.01)
    {
        RuntimeMaterial shoulder=SampleNaturalMaterial(7,p.xz*1.15);
        albedo=lerp(albedo,shoulder.albedo*float3(.58,.52,.42),verge*.68);
        rough=lerp(rough,.90,verge*.68);
    }
    if(road>.001)
    {
        float2 uv=p.xz*1.35;
        // Stepped relief mapping only in the near field. The height profile is
        // the same startup-generated material used to derive its normal.
        if(footprint<.12&&road>.8)
        {
            float2 delta=rd.xz/max(abs(rd.y),.20)*(.012/8.0);
            float h=1;
            [unroll]for(int j=0;j<8;++j)
            {
                float sample=ProceduralMaterialColor.SampleLevel(MaterialSampler,float3(uv,5),0).a;
                if(h>sample){uv+=delta;h-=1.0/8.0;}
            }
        }
        RuntimeMaterial paving=SampleRuntimeMaterial(5,uv);
        float wheelTrack=exp(-pow((abs(town.x)-1.05)/.48,2.0))*laneLen;
        float dampPatch=smoothstep(.54,.78,Noise2(p.xz*.16+7.4))*.38+.22*wheelTrack;
        float3 roadAlbedo=paving.albedo*(1.0-.16*wheelTrack)*(1.0-.22*dampPatch);
        float roadRough=lerp(paving.roughness,.36,dampPatch);
        albedo=lerp(albedo,roadAlbedo,road);rough=lerp(rough,roadRough,road);
        float3 pavingNormal=normalize(baseNormal+float3(paving.normal.x,0,paving.normal.y)*.68);
        n=normalize(lerp(n,pavingNormal,road));
    }
    cavity*=1.0-.24*woodland*(1.0-rockWeight)*(1.0-snow);
    float shadow=TerrainShadow(p+baseNormal*1.2,sun);
    float cloudShadow=lerp(.78,1.0,smoothstep(.42,.68,Noise2(p.xz*.0012+WindField(p.xz,loopA)*.42)));
    // Preserve the material normal's local detail but steer diffuse sky toward
    // the unoccluded hemisphere. This is local horizon visibility, not GI.
    bentNormal=normalize(bentNormal+n-baseNormal);
    // The real-photo generator's seed 42 describes a glossy aggregate, not
    // bare Alpine limestone. Cover it with an explicitly authored opaque
    // weathering layer. Mix evaluated BRDF radiance, not F0/roughness: a thin
    // clear coat would leave the highly reflective substrate visible.
    // Soil, scree, snow and road cover all suppress the exposed substrate.
    float rockExposure=rockWeight*(1-scree)*(1-snow)*(1-road)*(1-littoral);
    float weatherCoverage=clamp(.91+.07*saturate(deposition*.65+ecology.x*.25+weathering*.30),.91,.985);
    float bareFraction=rockExposure*(1-weatherCoverage);
    float weatherRough=lerp(rough,lerp(.80,.22,damp),rockExposure);
    float visibility=CinematicShadow(p,baseNormal)*shadow*cloudShadow;
    float3 weathered=CinematicLightingAt(p,n,bentNormal,-rd,albedo,weatherRough,0,cavity,visibility,.04);
    float3 substrate=CinematicLightingAt(p,n,bentNormal,-rd,albedo,rock.roughness,0,cavity,visibility,rock.specular);
    float3 lit=lerp(weathered,substrate,bareFraction);
    // Subtle multi-scattered blue-white sky fill inside shaded snowfields.
    if(snow>.01)lit+=snow*AtmosphereDiffuse(float3(0,1,0))*float3(.08,.12,.19)*cavity*(1.0-visibility*.65);
    return lit;
}
