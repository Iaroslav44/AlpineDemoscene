// Conservative maximum elevation of every cell, then a max-reduction pyramid.
// Startup only; every input is the generated height field, never a disk asset.
Texture2D<float> HeightSource : register(t4);
Texture2D<float> PreviousBounds : register(t14);
RWTexture2D<float> BoundsOutput : register(u0);
cbuffer BoundsParameters : register(b3) { float4 Bounds; };
[numthreads(8,8,1)]
void TerrainBoundsCS(uint3 id:SV_DispatchThreadID)
{
    uint level=(uint)Bounds.z,size=max(1u,4096u>>level);
    if(any(id.xy>=size))return;
    float h;
    if(level==0)
    {
        int2 p=int2(id.xy),q=min(p+1,4095);
        h=max(max(HeightSource.Load(int3(p,0)),HeightSource.Load(int3(q.x,p.y,0))),
              max(HeightSource.Load(int3(p.x,q.y,0)),HeightSource.Load(int3(q,0))));
    }
    else
    {
        int2 p=int2(id.xy)*2;
        h=max(max(PreviousBounds.Load(int3(p,0)),PreviousBounds.Load(int3(p+int2(1,0),0))),
              max(PreviousBounds.Load(int3(p+int2(0,1),0)),PreviousBounds.Load(int3(p+1,0))));
    }
    BoundsOutput[id.xy]=h+.001;
}
