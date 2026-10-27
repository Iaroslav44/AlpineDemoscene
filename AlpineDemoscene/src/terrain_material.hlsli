// Runtime-generated mipmapped material layers replace per-pixel synthetic grain.
// This file is included after TerrainNormal/TerrainShadow and the sky helpers.
float TerrainCavity(float3 p,float3 n)
{
    float occlusion=0;
    [unroll]for(int i=0;i<4;++i)
    {
        float angle=(i+.37)*TAU/4.0;float2 d=float2(cos(angle),sin(angle));float horizon=0;
        [unroll]for(int j=0;j<3;++j)
        {
            float distance=12.0*exp2(j*2.0);float2 q=p.xz+d*distance;
            float3 delta=float3(q.x,Terrain(q)+.15,q.y)-p;
            horizon=max(horizon,saturate(dot(n,normalize(delta))));
        }
        occlusion+=horizon*horizon;
    }
    return 1.0-min(.68,occlusion*.23);
}
float3 ShadeTerrain(float3 p,float3 rd,float3 sun,float loopA,float footprint)
{
    float3 baseNormal=TerrainNormal(p.xz);float slope=1.0-baseNormal.y;
    float rockWeight=smoothstep(.10,.27,slope);
    float macro=GeologicalNoise(p.xz*.0037+17.0);
    RuntimeMaterial rock=TriplanarRuntimeMaterial(0,p,baseNormal,.16,.8);
    RuntimeMaterial meadow=SampleNaturalMaterial(1,p.xz*.32);
    float3 grassNormal=normalize(baseNormal+float3(meadow.normal.x,0,meadow.normal.y)*.35);
    float3 n=normalize(lerp(grassNormal,rock.normal,rockWeight));
    float field=GeologicalNoise(p.xz*.011+float2(13.5,7.1));
    float3 grass=meadow.albedo*lerp(float3(.66,.70,.55),float3(.96,.92,.80),macro);
    grass*=lerp(float3(.87,.98,.78),float3(1.09,1.04,.87),smoothstep(.35,.65,field));
    float mineralField=RockNoise(p*.011+float3(9.2,17.1,3.8)).x;
    float weathering=RockNoise(p*.0037+float3(3.1,11.7,23.9)).x;
    float3 mineral=lerp(float3(.80,.82,.82),float3(1.0,.98,.93),mineralField);
    float3 rockAlbedo=rock.albedo*mineral*(.78+.30*weathering+.12*macro);
    float3 albedo=lerp(grass,rockAlbedo,rockWeight);
    // Sub-metre fractures alter shading, while resolved silhouettes remain
    // the generated height field. Fade this band by the ray footprint.
    float4 grain=RockNoise(p*.19+float3(1.3,8.1,4.7));
    float3 micro=grain.yzw-baseNormal*dot(grain.yzw,baseNormal);
    n=normalize(n-micro*(.10*rockWeight*DetailBand(footprint,.19)));
    float rough=lerp(meadow.roughness,rock.roughness,rockWeight);
    float snowOffset=(GeologicalNoise(p.xz*.006)-.5)*180.0;
    float sheltered=1-smoothstep(.25,.65,slope);
    float snow=smoothstep(1610.0,1940.0,p.y+snowOffset)*sheltered;
    snow*=smoothstep(.22,.48,GeologicalNoise(p.xz*.021)+baseNormal.y*.25);
    albedo=lerp(albedo,float3(.72,.78,.83),snow);
    rough=lerp(rough,.64,snow);n=normalize(lerp(n,baseNormal,snow*.85));
    float moss=(1.0-rockWeight)*(1-snow)*smoothstep(.52,.76,macro);
    albedo*=1-.24*moss;
    float damp=exp(-pow((p.x-350.0)/52.0,2))*smoothstep(4710,4800,p.z)*(1-smoothstep(4920,4970,p.z));
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
    float cavity=TerrainCavity(p,baseNormal);
    return CinematicLightingShadow(p,n,-rd,albedo,rough,0, cavity,shadow*cloudShadow);
}
