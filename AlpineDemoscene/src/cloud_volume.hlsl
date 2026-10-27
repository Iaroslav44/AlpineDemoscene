// Startup-generated periodic3D cloud fields, no image or volume asset.
// Resource117:128^3 RGBA8_UNORM UAV, Dispatch(16,16,16).
// R: Perlin-like FBM / Worley billow shape;G/B: medium/fine erosion;
// A: low-frequency weather. All channels tile in all three directions.
RWTexture3D<float4> CloudNoiseOutput : register(u0);
uint CloudHash(uint3 p)
{
    uint h=p.x*1597334677u^p.y*3812015801u^p.z*2798796415u;
    h^=h>>16;h*=2246822519u;h^=h>>13;h*=3266489917u;return h^(h>>16);
}
float CloudHashValue(int3 p,int period)
{
    // All FBM/weather periods are powers of two, including negative lattice cells.
    p=int3(uint3(p)&uint(period-1));
    return (CloudHash(uint3(p))&0x00ffffffu)/16777216.0;
}
float CloudValueNoise(float3 p,int period)
{
    int3 c=(int3)floor(p);float3 f=frac(p);f=f*f*f*(f*(f*6.0-15.0)+10.0);
    float a=lerp(CloudHashValue(c,period),CloudHashValue(c+int3(1,0,0),period),f.x);
    float b=lerp(CloudHashValue(c+int3(0,1,0),period),CloudHashValue(c+int3(1,1,0),period),f.x);
    float d=lerp(CloudHashValue(c+int3(0,0,1),period),CloudHashValue(c+int3(1,0,1),period),f.x);
    float e=lerp(CloudHashValue(c+int3(0,1,1),period),CloudHashValue(c+int3(1,1,1),period),f.x);
    return lerp(lerp(a,b,f.y),lerp(d,e,f.y),f.z);
}
float CloudFBM(float3 uv)
{
    float sum=0.0,weight=.533333;
    [unroll]for(int i=0;i<4;++i)
    {
        int frequency=8<<i;sum+=CloudValueNoise(uv*frequency,frequency)*weight;weight*=.5;
    }
    return sum;
}
float CloudWorley(float3 uv,int cells)
{
    float3 p=uv*cells,local=frac(p);int3 cell=(int3)floor(p);float distanceSquared=4.0;
    [loop]for(int z=-1;z<=1;++z)[loop]for(int y=-1;y<=1;++y)[loop]for(int x=-1;x<=1;++x)
    {
        int3 offset=int3(x,y,z);uint3 q=uint3(cell+offset+cells)%uint(cells);
        uint h=CloudHash(uint3(q));
        float3 feature=float3(h&1023u,(h>>10)&1023u,(h>>20)&1023u)/1023.0;
        feature=.10+.80*feature;
        float3 delta=offset+feature-local;distanceSquared=min(distanceSquared,dot(delta,delta));
    }
    return 1.0-saturate(sqrt(distanceSquared)*1.04);
}
[numthreads(8,8,8)]
void CloudNoiseCS(uint3 id:SV_DispatchThreadID)
{
    if(any(id>=128))return;
    float3 uv=(id+.5)/128.0;
    float fbm=CloudFBM(uv),large=CloudWorley(uv,8);
    float medium=CloudWorley(uv,16),fine=CloudWorley(uv,32);
    float shape=pow(saturate(.62*fbm+.38*large),.72);
    // Weather describes horizontal cloud banks, not a fog sheet that changes
    // coverage whenever the camera changes altitude. Y remains constant.
    float weather=CloudValueNoise(float3(uv.x*2.0+.37,1.17,uv.z*2.0+.83),2);
    CloudNoiseOutput[id]=float4(shape,medium,fine,weather);
}
