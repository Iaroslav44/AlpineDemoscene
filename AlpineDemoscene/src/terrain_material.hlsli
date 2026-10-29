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
    float rockWeight=smoothstep(.12,.35,slope+(field-.5)*.055+(0.45-deposition)*.10);
    RuntimeMaterial rock=TriplanarRuntimeMaterial(0,p,baseNormal,.20,.68);
    RuntimeMaterial meadow=SampleNaturalMaterial(1,p.xz*.32);
    float3 grassNormal=normalize(baseNormal+float3(meadow.normal.x,0,meadow.normal.y)*.24);
    float3 n=normalize(lerp(grassNormal,rock.normal,rockWeight));
    // Biome and deposition are correlated with slope/aspect/elevation rather
    // than painting every empty surface the same saturated green. Sheltered
    // lower slopes keep lush turf; exposed high slopes carry dry grass/scree.
    float north=saturate(dot(baseNormal,float3(.24,0,.97))*.5+.5);
    float dry=saturate(.58*macro+.32*(1-north)+smoothstep(700,1600,p.y)*.46-.28);
    float3 grass=meadow.albedo*lerp(float3(.91,1.03,.85),float3(1.09,.96,.77),field);
    grass=lerp(grass,float3(.112,.102,.057)*(.80+.32*field),dry*.65);
    // Continuous pasture mosaics at 30--180 m scales. Warped boundaries have
    // no grid or discrete tile identity; coarse concavity retains moisture.
    // These bands remain visible from the establishing camera after all fine
    // surface detail has correctly collapsed into its material mip average.
    float2 pastureUV=p.xz*.0061+float2(
        Noise2(p.xz*.0019+float2(8.4,31.2)),
        Noise2(p.xz*.0023+float2(47.8,4.1)))*1.35;
    float pasture=.69*Noise2(pastureUV+13.7)
                 +.31*Noise2(float2(pastureUV.x*2.91-pastureUV.y*1.70,
                                          pastureUV.x*1.70+pastureUV.y*2.91)+41.2);
    float lowland=(1-smoothstep(.11,.27,slope))*(1-smoothstep(720,1150,p.y));
    float fallow=smoothstep(.38,.62,pasture)*lowland*(1-deposition*.65);
    float dampMeadow=saturate(deposition*.75+smoothstep(.59,.76,field)*.40)*lowland;
    grass=lerp(grass,float3(.126,.109,.061)*(.82+.28*macro),fallow*.72);
    grass=lerp(grass,float3(.032,.058,.025)*(.85+.25*field),dampMeadow*.75);
    grass*=lerp(.82,1.12,smoothstep(.27,.73,pasture));
    grass=lerp(grass,grass*float3(.62,.90,.60),saturate(ecology.x-.35)*.8);
    float mineralField=RockNoise(p*.0073+float3(9.2,17.1,3.8)).x;
    float weathering=RockNoise(p*.0026+float3(3.1,11.7,23.9)).x;
    float3 mineral=lerp(float3(.83,.88,.91),float3(1.06,1.01,.90),mineralField);
    float3 rockAlbedo=rock.albedo*mineral*(.83+.25*weathering);
    // Iron staining follows discontinuous deposits, not equally spaced
    // contour stripes. The centimetre material retains its own grain scale.
    float iron=smoothstep(.59,.77,weathering)*smoothstep(.20,.43,slope);
    rockAlbedo=lerp(rockAlbedo,rockAlbedo*float3(1.15,.88,.65),iron*.32);
    float3 albedo=lerp(grass,rockAlbedo,rockWeight);
    // Sub-metre fractures alter shading, while resolved silhouettes remain
    // the generated height field. Fade this band by the ray footprint.
    float4 grain=RockNoise(p*.19+float3(1.3,8.1,4.7));
    float3 micro=grain.yzw-baseNormal*dot(grain.yzw,baseNormal);
    n=normalize(n-micro*(.10*rockWeight*DetailBand(footprint,.19)));
    float rough=lerp(meadow.roughness,rock.roughness,rockWeight);
    float scree=smoothstep(680,1370,p.y+(macro-.5)*280)
        *(1-smoothstep(.30,.57,slope))*(.45+.55*field);
    if(scree>.025)
    {
        RuntimeMaterial gravel=SampleNaturalMaterial(7,p.xz*.65);
        float3 deposits=lerp(rockAlbedo*.82,gravel.albedo*float3(.87,.88,.86),.38);
        albedo=lerp(albedo,deposits,scree);rough=lerp(rough,.91,scree);
        float3 gravelNormal=normalize(baseNormal+float3(gravel.normal.x,0,gravel.normal.y)*.28);
        n=normalize(lerp(n,gravelNormal,scree*.63));
    }
    float snowOffset=(GeologicalNoise(p.xz*.006)-.5)*180.0;
    float sheltered=1-smoothstep(.25,.65,slope);
    float snow=smoothstep(1610.0,1940.0,p.y+snowOffset)*sheltered;
    snow*=smoothstep(.22,.48,GeologicalNoise(p.xz*.021)+baseNormal.y*.25);
    albedo=lerp(albedo,float3(.72,.78,.83),snow);
    rough=lerp(rough,.64,snow);n=normalize(lerp(n,baseNormal,snow*.85));
    float moss=(1.0-rockWeight)*(1-snow)*smoothstep(.53,.77,macro)*north;
    albedo*=1-.14*moss;
    float damp=exp(-pow((p.x-350.0)/52.0,2))*smoothstep(4710,4800,p.z)*(1-smoothstep(4920,4970,p.z));
    float shoreline=(1-smoothstep(.25,2.8,abs(p.y-LAKE_Y)))*smoothstep(0.0,.25,slope)
        *(1-smoothstep(1.0,1.3,length((p.xz-LAKE_C)/float2(900,610))));
    damp=max(damp,shoreline*.85);
    albedo*=1-.46*damp;rough=lerp(rough,.30,damp);
    float2 town=p.xz-TOWN_C;
    float road=(1-smoothstep(2.8,3.5,abs(town.x)))*(1-smoothstep(170,240,abs(town.y)));
    road=max(road,1-smoothstep(6,10,length((p.xz-float2(0,1755))/float2(.78,1))));
    if(road>.001)
    {
        float2 uv=p.xz*1.5;
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
        albedo=lerp(albedo,paving.albedo,road);rough=lerp(rough,paving.roughness,road);
        float3 pavingNormal=normalize(baseNormal+float3(paving.normal.x,0,paving.normal.y)*.65);
        n=normalize(lerp(n,pavingNormal,road));
    }
    float shadow=TerrainShadow(p+baseNormal*1.2,sun);
    float cloudShadow=lerp(.82,1.0,smoothstep(.44,.70,Noise2(p.xz*.0012+WindField(p.xz,loopA)*.42)));
    // Preserve the material normal's local detail but steer diffuse sky toward
    // the unoccluded hemisphere. This is local horizon visibility, not GI.
    bentNormal=normalize(bentNormal+n-baseNormal);
    // The real-photo generator's seed 42 describes a glossy aggregate, not
    // bare Alpine limestone. Cover it with an explicitly authored opaque
    // weathering layer. Mix evaluated BRDF radiance, not F0/roughness: a thin
    // clear coat would leave the highly reflective substrate visible.
    // Soil, scree, snow and road cover all suppress the exposed substrate.
    float rockExposure=rockWeight*(1-scree)*(1-snow)*(1-road);
    float weatherCoverage=clamp(.90+.08*saturate(deposition*.65+ecology.x*.25+weathering*.30),.90,.98);
    float bareFraction=rockExposure*(1-weatherCoverage);
    float weatherRough=lerp(rough,lerp(.82,.30,damp),rockExposure);
    float visibility=CinematicShadow(p,baseNormal)*shadow*cloudShadow;
    float3 weathered=CinematicLightingVisibleBentF0(n,bentNormal,-rd,albedo,weatherRough,0,cavity,visibility,.04);
    float3 substrate=CinematicLightingVisibleBentF0(n,bentNormal,-rd,albedo,rock.roughness,0,cavity,visibility,rock.specular);
    return lerp(weathered,substrate,bareFraction);
}
