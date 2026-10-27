#ifndef ALPINE_MATERIAL_COMMON
#define ALPINE_MATERIAL_COMMON
// Generated on the GPU at startup, never loaded from an image file.
// Linear colour + height, tangent normal + perceptual roughness, full mip chain.
Texture2DArray<float4> ProceduralMaterialColor : register(t8);
Texture2DArray<float4> ProceduralMaterialNormal : register(t9);
#include "sampler_common.hlsli"
struct RuntimeMaterial { float3 albedo; float3 normal; float roughness; float height; };
RuntimeMaterial DecodeRuntimeMaterial(float4 a,float4 b)
{
    RuntimeMaterial m;m.albedo=a.rgb;m.height=a.a;
    float3 raw=b.xyz*2.0-1.0;float normalLength=length(raw);
    // Averaged normals lose length in coarse mips. Carry that unresolved
    // slope variance into roughness instead of producing distant glitter.
    m.roughness=sqrt(saturate(b.a*b.a+max(0.0,1.0-normalLength)));
    m.normal=raw/max(normalLength,.001);return m;
}
RuntimeMaterial SampleRuntimeMaterial(uint layer,float2 uv)
{
    return DecodeRuntimeMaterial(ProceduralMaterialColor.Sample(MaterialSampler,float3(uv,layer)),
        ProceduralMaterialNormal.Sample(MaterialSampler,float3(uv,layer)));
}
float2 MaterialCellOffset(int2 p)
{
    uint h=(uint)p.x*1597334677u^(uint)p.y*3812015801u;
    h^=h>>16;h*=2246822519u;h^=h>>13;
    uint g=h*3266489917u+374761393u;g^=g>>16;
    return float2(h&0x00ffffffu,g&0x00ffffffu)/16777216.0;
}
RuntimeMaterial SampleNaturalMaterial(uint layer,float2 uv)
{
    // Three overlapping randomized lattice samples. Their weights vanish at
    // cell edges, so an unstructured rock/soil surface has no repeated square
    // tiles or hard hash seams. Explicit gradients keep correct distant mips.
    float2 grid=float2(uv.x-uv.y*.577350269,uv.y*1.154700538);
    int2 base=int2(floor(grid));float2 f=frac(grid);
    int2 a,b,c;float3 w;
    if(f.x+f.y<1){a=base;b=base+int2(1,0);c=base+int2(0,1);w=float3(1-f.x-f.y,f.x,f.y);}
    else{a=base+1;b=base+int2(0,1);c=base+int2(1,0);w=float3(f.x+f.y-1,1-f.x,1-f.y);}
    w=w*w*w;w/=max(dot(w,1.0),.0001);
    float2 dx=ddx(uv),dy=ddy(uv);
    float3 u0=float3(uv+MaterialCellOffset(a),layer),u1=float3(uv+MaterialCellOffset(b),layer),u2=float3(uv+MaterialCellOffset(c),layer);
    float4 colour=ProceduralMaterialColor.SampleGrad(MaterialSampler,u0,dx,dy)*w.x
        +ProceduralMaterialColor.SampleGrad(MaterialSampler,u1,dx,dy)*w.y
        +ProceduralMaterialColor.SampleGrad(MaterialSampler,u2,dx,dy)*w.z;
    float4 normal=ProceduralMaterialNormal.SampleGrad(MaterialSampler,u0,dx,dy)*w.x
        +ProceduralMaterialNormal.SampleGrad(MaterialSampler,u1,dx,dy)*w.y
        +ProceduralMaterialNormal.SampleGrad(MaterialSampler,u2,dx,dy)*w.z;
    return DecodeRuntimeMaterial(colour,normal);
}
RuntimeMaterial TriplanarRuntimeMaterial(uint layer,float3 p,float3 baseNormal,float frequency,float strength)
{
    float3 weights=pow(abs(baseNormal),4.0);weights/=max(dot(weights,1.0),1e-5);
    RuntimeMaterial x,y,z;
    if(layer==0)
    {
        x=SampleNaturalMaterial(layer,p.zy*frequency);
        y=SampleNaturalMaterial(layer,p.xz*frequency);
        z=SampleNaturalMaterial(layer,p.xy*frequency);
    }
    else
    {
        x=SampleRuntimeMaterial(layer,p.zy*frequency);
        y=SampleRuntimeMaterial(layer,p.xz*frequency);
        z=SampleRuntimeMaterial(layer,p.xy*frequency);
    }
    RuntimeMaterial m;
    m.albedo=x.albedo*weights.x+y.albedo*weights.y+z.albedo*weights.z;
    m.height=x.height*weights.x+y.height*weights.y+z.height*weights.z;
    m.roughness=x.roughness*weights.x+y.roughness*weights.y+z.roughness*weights.z;
    float3 bump=float3(0,x.normal.y,x.normal.x)*weights.x+float3(y.normal.x,0,y.normal.y)*weights.y
        +float3(z.normal.x,z.normal.y,0)*weights.z;
    bump-=baseNormal*dot(bump,baseNormal);
    m.normal=normalize(baseNormal+bump*strength);return m;
}
#endif
