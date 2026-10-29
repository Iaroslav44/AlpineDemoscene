#ifndef ALPINE_MATERIAL_COMMON
#define ALPINE_MATERIAL_COMMON
// Generated on the GPU at startup, never loaded from an image file.
// Linear colour + height, tangent normal + perceptual roughness, full mip chain.
Texture2DArray<float4> ProceduralMaterialColor : register(t8);
Texture2DArray<float4> ProceduralMaterialNormal : register(t9);
#include "sampler_common.hlsli"
Texture2D<float4> NeuralMaterialDiffuse : register(t20);
Texture2D<float4> NeuralMaterialRelief : register(t21);
Texture2D<float4> NeuralMaterialSpecular : register(t22);
Texture2D<float4> NeuralWoodDiffuse : register(t23);
Texture2D<float4> NeuralWoodRelief : register(t24);
Texture2D<float4> NeuralWoodSpecular : register(t25);
struct RuntimeMaterial { float3 albedo; float3 normal; float roughness; float height; float3 specular; };
RuntimeMaterial DecodeRuntimeMaterial(float4 a,float4 b)
{
    RuntimeMaterial m;m.albedo=a.rgb;m.height=a.a;m.specular=.04;
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
void NeuralPatch(uint layer,float2 uv,float2 dx,float2 dy,out float4 color,out float4 normal,out float3 specular)
{
    // PhotoMat's original generator has non-periodic boundaries. Mirrored
    // coordinates preserve colour/height continuity; tangent slopes follow
    // each reflection. Random overlapping patches hide bilateral repetition.
    float2 parity=fmod(floor(uv),2.0);parity+=step(parity,-.5)*2;
    float2 flip=1-2*parity;
    float2 position=lerp(frac(uv),1-frac(uv),parity);
    position=(position*255+.5)/256;
    dx*=flip*(255.0/256);dy*=flip*(255.0/256);
    if(layer==2)
    {
        color=NeuralWoodDiffuse.SampleGrad(MaterialSampler,position,dx,dy);
        normal=NeuralWoodRelief.SampleGrad(MaterialSampler,position,dx,dy);
        specular=NeuralWoodSpecular.SampleGrad(MaterialSampler,position,dx,dy).rgb;
    }
    else
    {
        color=NeuralMaterialDiffuse.SampleGrad(MaterialSampler,position,dx,dy);
        normal=NeuralMaterialRelief.SampleGrad(MaterialSampler,position,dx,dy);
        specular=NeuralMaterialSpecular.SampleGrad(MaterialSampler,position,dx,dy).rgb;
    }
    normal.xy*=flip;
}
RuntimeMaterial SampleNeuralMaterial(uint layer,float2 uv)
{
    float2 grid=float2(uv.x-uv.y*.577350269,uv.y*1.154700538);
    int2 base=int2(floor(grid));float2 f=frac(grid);int2 a,b,c;float3 w;
    if(f.x+f.y<1){a=base;b=base+int2(1,0);c=base+int2(0,1);w=float3(1-f.x-f.y,f.x,f.y);}
    else{a=base+1;b=base+int2(0,1);c=base+int2(1,0);w=float3(f.x+f.y-1,1-f.x,1-f.y);}
    w=w*w*w;w/=max(dot(w,1),1e-6);
    float2 dx=ddx(uv),dy=ddy(uv);float4 albedo[3],relief[3];float3 spec[3];
    NeuralPatch(layer,uv+MaterialCellOffset(a)*17,dx,dy,albedo[0],relief[0],spec[0]);
    NeuralPatch(layer,uv+MaterialCellOffset(b)*17,dx,dy,albedo[1],relief[1],spec[1]);
    NeuralPatch(layer,uv+MaterialCellOffset(c)*17,dx,dy,albedo[2],relief[2],spec[2]);
    float4 color=albedo[0]*w.x+albedo[1]*w.y+albedo[2]*w.z;
    float4 nh=relief[0]*w.x+relief[1]*w.y+relief[2]*w.z;
    float normalLength=length(nh.xyz);RuntimeMaterial m;
    m.albedo=max(0,color.rgb);m.height=nh.w;m.normal=nh.xyz/max(normalLength,1e-5);
    m.roughness=sqrt(saturate(color.a*color.a+1-min(1,normalLength)));
    m.specular=saturate(spec[0]*w.x+spec[1]*w.y+spec[2]*w.z);return m;
}
RuntimeMaterial SampleNaturalMaterial(uint layer,float2 uv)
{
    if(layer==0||layer==2)return SampleNeuralMaterial(layer,uv);
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
    if(layer==0||layer==2)
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
    m.specular=x.specular*weights.x+y.specular*weights.y+z.specular*weights.z;
    float3 bump=float3(0,x.normal.y,x.normal.x)*weights.x+float3(y.normal.x,0,y.normal.y)*weights.y
        +float3(z.normal.x,z.normal.y,0)*weights.z;
    bump-=baseNormal*dot(bump,baseNormal);
    m.normal=normalize(baseNormal+bump*strength);return m;
}
#endif
