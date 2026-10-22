// Development-only readback of the D3D11 instance-ID contract.
cbuffer MeshBatch : register(b1) { uint4 Batch; };
struct InstanceOut { float4 position:SV_Position; nointerpolation uint raw:TEXCOORD0; };
InstanceOut InstanceVS(uint vertex:SV_VertexID,uint instance:SV_InstanceID)
{
    float2 uv;
    if(vertex==0||vertex==3)uv=float2(0,0);
    else if(vertex==1)uv=float2(1,0);
    else if(vertex==2||vertex==4)uv=float2(1,1);
    else uv=float2(0,1);
    InstanceOut o;o.position=float4((float(instance)+uv.x)*2.0/Batch.y-1.0,1.0-uv.y*2.0,0,1);
    o.raw=instance;return o;
}
float4 InstancePS(InstanceOut i):SV_Target
{
    return float4(i.raw,i.raw+Batch.x,Batch.x,1);
}
