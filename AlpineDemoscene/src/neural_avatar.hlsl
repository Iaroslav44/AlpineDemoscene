// gDNA THuman pretrained decoder, evaluated at application startup.
// Neural weights are exported by tools/neural_avatar_export.py. No photographs,
// precomputed feature volumes or meshes are supplied to this shader.
Buffer<float> Model : register(t0);
Buffer<float> Input : register(t1);
Buffer<float> Auxiliary : register(t2);
Buffer<float> Latents : register(t3);
RWBuffer<float> Output : register(u0);

cbuffer NeuralConstants : register(b0)
{
    uint4 Control;       // operation, element count, first element, activation flag
    uint4 SourceShape;   // W,H,D,C
    uint4 TargetShape;
    uint4 Offsets;       // convolution weight, bias, style offset, unused (floats)
    float4 GridMin;
    float4 GridStep;
    uint4 GeometryLayers[5]; // weight, bias, inputs, outputs
    uint4 NormalLayers[9];
    uint4 SkinLayers[5];
    uint4 TextureLayers[9];
    uint4 ModelInfo; // kind (0 gDNA, 1 GANHead), shape dimensions, detail offset, color offset
    uint4 MorphLayer;
};

groupshared float HiddenA[1024];
groupshared float HiddenB[512];
groupshared float GeometricFeatures[256];
groupshared float NormalFeatures[256];
groupshared float FourierPosition[40];
groupshared float ReductionA[256];
groupshared float ReductionB[256];
groupshared float NeuralNormal[3];
groupshared float NeuralColor[3];
groupshared float ExpressionDirections[12];

float ReadFeature(int3 p, uint c, uint3 shape)
{
    if (any(p < 0) || any(p >= int3(shape))) return 0.0;
    return Input[((c * shape.z + p.z) * shape.y + p.y) * shape.x + p.x];
}

float Trilinear(float3 position, uint channel, uint3 shape)
{
    int3 lo = int3(floor(position));
    float3 f = position - lo;
    float result = 0.0;
    [unroll] for (uint z = 0; z < 2; ++z)
    [unroll] for (uint y = 0; y < 2; ++y)
    [unroll] for (uint x = 0; x < 2; ++x)
        result += ReadFeature(lo + int3(x,y,z), channel, shape)
            * (x ? f.x : 1-f.x) * (y ? f.y : 1-f.y) * (z ? f.z : 1-f.z);
    return result;
}

float Softplus(float value)
{
    // PyTorch Softplus(beta=100, threshold=20), without exp overflow.
    return value > 0.2 ? value : log(1.0 + exp(clamp(value * 100.0,-80.0,20.0))) * 0.01;
}

float EmbedPosition(float3 p, uint lane)
{
    float component = (lane % 3) == 0 ? p.x : ((lane % 3) == 1 ? p.y : p.z);
    if (lane < 3) return component;
    uint i = lane - 3;
    float v = component * exp2(float(i / 6));
    return (i % 6) < 3 ? sin(v) : cos(v);
}

void DenseLayer(uint lane, uint4 layer, bool activate)
{
    float value = 0;
    if (lane < layer.w)
    {
        value = Model[layer.y + lane];
        // Runtime uploads dense weights input-major, so neighbouring neuron
        // lanes fetch neighbouring addresses. NAV1 remains source row-major.
        [loop] for (uint i = 0; i < layer.z; ++i) value += Model[layer.x + i * layer.w + lane] * HiddenA[i];
        if (activate) value = Softplus(value);
    }
    if (lane < 256) HiddenB[lane] = value;
    GroupMemoryBarrierWithGroupSync();
    if (lane < 256) HiddenA[lane] = HiddenB[lane];
    GroupMemoryBarrierWithGroupSync();
}

void Geometry(uint lane, float3 position)
{
    float3 p = position;
    if(ModelInfo.x==0){p.y+=0.28;p.z*=4.0;}
    if (lane < 27) FourierPosition[lane] = EmbedPosition(p,lane);
    if (lane < 91)
        HiddenA[lane] = lane < 27 ? EmbedPosition(p,lane)
            : Trilinear((p * 0.5 + 0.5) * float3(63,63,15),lane-27,uint3(64,64,16));
    GroupMemoryBarrierWithGroupSync();
    [unroll] for (uint layer = 0; layer < 4; ++layer)
        DenseLayer(lane,GeometryLayers[layer],true);
    if (lane < 229) GeometricFeatures[lane] = HiddenA[lane];
    // The skip layer concatenates its 229 inputs and the original 27 features.
    if (lane < 256)
        HiddenA[lane] = (lane < 229 ? HiddenA[lane] : FourierPosition[lane-229]) * 0.7071067811865475;
    GroupMemoryBarrierWithGroupSync();
    DenseLayer(lane,GeometryLayers[4],false);
}

[numthreads(256,1,1)]
void NeuralAvatarCS(uint3 threadID : SV_DispatchThreadID, uint3 groupID : SV_GroupID, uint lane : SV_GroupIndex)
{
    uint index = Control.z + threadID.x;
    if (Control.x == 0) // align_corners=True 3D interpolation
    {
        if (index >= Control.y) return;
        uint voxels = TargetShape.x * TargetShape.y * TargetShape.z;
        uint c = index / voxels, voxel = index % voxels;
        uint3 p = uint3(voxel % TargetShape.x,(voxel / TargetShape.x) % TargetShape.y,voxel / (TargetShape.x*TargetShape.y));
        float3 src = float3(p) * float3(SourceShape.xyz-1) / float3(TargetShape.xyz-1);
        Output[index] = Trilinear(src,c,SourceShape.xyz);
    }
    else if (Control.x == 1) // Conv3D, stride=1, zero padding=1
    {
        if (index >= Control.y) return;
        uint voxels = TargetShape.x * TargetShape.y * TargetShape.z;
        uint c = index / voxels, voxel = index % voxels;
        int3 p = int3(voxel % TargetShape.x,(voxel / TargetShape.x) % TargetShape.y,voxel / (TargetShape.x*TargetShape.y));
        float value = Model[Offsets.y + c];
        [loop] for (uint ci = 0; ci < SourceShape.w; ++ci)
        {
            uint w = Offsets.x + (c * SourceShape.w + ci) * 27;
            [unroll] for (int z = 0; z < 3; ++z)
            [unroll] for (int y = 0; y < 3; ++y)
            [unroll] for (int x = 0; x < 3; ++x)
                value += Model[w + z*9+y*3+x] * ReadFeature(p+int3(x-1,y-1,z-1),ci,SourceShape.xyz);
        }
        Output[index] = value;
    }
    else if (Control.x == 2) // unbiased per-channel variance (PyTorch .var)
    {
        uint c = groupID.x + Control.z;
        uint count = SourceShape.x * SourceShape.y * SourceShape.z;
        float sum = 0;
        [loop] for (uint i = lane; i < count; i += 256) sum += Input[c*count+i];
        ReductionA[lane] = sum;
        GroupMemoryBarrierWithGroupSync();
        [unroll] for (uint stride=128;stride>0;stride>>=1)
        {
            if(lane<stride) ReductionA[lane]+=ReductionA[lane+stride];
            GroupMemoryBarrierWithGroupSync();
        }
        float mean = ReductionA[0] / count;
        float squares=0;
        [loop] for(uint j=lane;j<count;j+=256){float delta=Input[c*count+j]-mean;squares+=delta*delta;}
        ReductionB[lane]=squares;
        GroupMemoryBarrierWithGroupSync();
        [unroll] for(uint stride2=128;stride2>0;stride2>>=1)
        {
            if(lane<stride2) ReductionB[lane]+=ReductionB[lane+stride2];
            GroupMemoryBarrierWithGroupSync();
        }
        if(lane==0){Output[c*2]=mean;Output[c*2+1]=rsqrt(ReductionB[0]/(count-1)+1e-5);}
    }
    else if (Control.x == 3) // AdaIN followed by LeakyReLU(0.01)
    {
        if(index>=Control.y)return;
        uint c=index/(SourceShape.x*SourceShape.y*SourceShape.z);
        float value=Input[index];
        if(Control.w==0)
            value=(value-Auxiliary[c*2])*Auxiliary[c*2+1]*Latents[Offsets.z+SourceShape.w+c]+Latents[Offsets.z+c];
        Output[index]=value>=0?value:value*0.01;
    }
    else if (Control.x == 4) // implicit occupancy field, 256 lanes per query
    {
        uint query=Control.z+groupID.x;
        if(query>=Control.y)return;
        uint3 p=uint3(query%TargetShape.x,(query/TargetShape.x)%TargetShape.y,query/(TargetShape.x*TargetShape.y));
        Geometry(lane,GridMin.xyz+float3(p)*GridStep.xyz);
        if(lane==0)Output[query]=HiddenA[0];
    }
    else if (Control.x == 5) // learned fine normals and 24-joint skinning field
    {
        uint query=Control.z+groupID.x;
        if(query>=Control.y)return;
        float3 position=float3(Auxiliary[query*3],Auxiliary[query*3+1],Auxiliary[query*3+2]);
        Geometry(lane,position);
        if(lane<39)FourierPosition[lane]=EmbedPosition(position,lane);
        uint detailSize=ModelInfo.x==0?64:128;
        [loop] for(uint a=lane;a<39+detailSize+229;a+=256)
            HiddenA[a]=a<39?EmbedPosition(position,a):(a<39+detailSize?Latents[ModelInfo.z+a-39]:GeometricFeatures[a-39-detailSize]);
        GroupMemoryBarrierWithGroupSync();
        [unroll]for(uint n=0;n<9;++n)
        {
            if(n==4)
            {
                if(lane<256)HiddenA[lane]=(lane<217?HiddenA[lane]:FourierPosition[lane-217])*0.7071067811865475;
                GroupMemoryBarrierWithGroupSync();
            }
            DenseLayer(lane,NormalLayers[n],n<8);
            if(n==7&&lane<256)NormalFeatures[lane]=HiddenA[lane];
        }
        if(lane<3)NeuralNormal[lane]=HiddenA[lane];
        GroupMemoryBarrierWithGroupSync();
        if(ModelInfo.x==1)
        {
            [loop]for(uint tex=lane;tex<845;tex+=256)
                HiddenA[tex]=tex<39?EmbedPosition(position,tex):
                    (tex<295?Latents[384+tex-39]:(tex<360?0:
                    (tex<589?GeometricFeatures[tex-360]:NormalFeatures[tex-589])));
            GroupMemoryBarrierWithGroupSync();
            [unroll]for(uint t=0;t<9;++t)
            {
                if(t==4)
                {
                    if(lane<256)HiddenA[lane]=(lane<217?HiddenA[lane]:FourierPosition[lane-217])*0.7071067811865475;
                    GroupMemoryBarrierWithGroupSync();
                }
                DenseLayer(lane,TextureLayers[t],t<8);
            }
            if(lane<3)NeuralColor[lane]=saturate(HiddenA[lane]*0.5+0.5);
            GroupMemoryBarrierWithGroupSync();
        }
        if(lane<(ModelInfo.x==0?67:3))HiddenA[lane]=lane<3?position[lane%3]:Latents[lane-3];
        GroupMemoryBarrierWithGroupSync();
        [unroll]for(uint s=0;s<5;++s)
        {
            DenseLayer(lane,SkinLayers[s],s<4);
            if(ModelInfo.x==1&&s==2)
            {
                if(lane<12)
                {
                    float morph=Model[MorphLayer.y+lane];
                    [loop]for(uint mi=0;mi<128;++mi)morph+=Model[MorphLayer.x+mi*12+lane]*HiddenA[mi];
                    ExpressionDirections[lane]=morph;
                }
                GroupMemoryBarrierWithGroupSync();
            }
        }
        if(lane==0)
        {
            float3 normal=float3(NeuralNormal[0],NeuralNormal[1],NeuralNormal[2]);
            normal*=rsqrt(max(dot(normal,normal),1e-20));
            uint stride=ModelInfo.x==0?12:32;
            Output[query*stride]=normal.x;Output[query*stride+1]=normal.y;Output[query*stride+2]=normal.z;Output[query*stride+3]=0;
            uint4 ids=0;float4 values=0;
            float largest=-1e30;
            uint jointCount=ModelInfo.x==0?24:5;
            [loop]for(uint k=0;k<jointCount;++k)largest=max(largest,HiddenA[k]);
            [unroll]for(uint pick=0;pick<4;++pick)
            {
                float best=-1e30;uint bestId=0;
                [loop]for(uint k2=0;k2<jointCount;++k2)if(HiddenA[k2]>best){best=HiddenA[k2];bestId=k2;}
                ids[pick]=bestId;values[pick]=exp((best-largest)*20.0);HiddenA[bestId]=-1e30;
            }
            values/=max(dot(values,1.0),1e-30);
            // Numeric floats survive typed R32_FLOAT stores. Bit-casting small
            // integers here would produce denormals that GPUs may flush to zero.
            // The CPU converts these indices to uint bits in the final mesh.
            [unroll]for(uint q=0;q<4;++q){Output[query*stride+4+q]=float(ids[q]);Output[query*stride+8+q]=values[q];}
            if(ModelInfo.x==1)
            {
                Output[query*stride+12]=NeuralColor[0];Output[query*stride+13]=NeuralColor[1];Output[query*stride+14]=NeuralColor[2];Output[query*stride+15]=1;
                [unroll]for(uint mode=0;mode<4;++mode)
                {
                    [unroll]for(uint coord=0;coord<3;++coord)Output[query*stride+16+mode*4+coord]=ExpressionDirections[mode*3+coord];
                    Output[query*stride+19+mode*4]=0;
                }
            }
        }
    }
}
