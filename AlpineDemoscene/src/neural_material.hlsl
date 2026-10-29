// PhotoMat 256 inference: real-photo-trained StyleGAN2 features + MatUnet.
// HWC fields and [kernelY,kernelX,input,output] weights; tiled GEMM convolution.
Buffer<float> Model : register(t0);
Buffer<float> Input : register(t1);
Buffer<float> Auxiliary : register(t2);
Buffer<float> Styles : register(t3);
RWBuffer<float> Output : register(u0);
cbuffer MaterialConstants : register(b0) {
    uint4 Control; // operation, total elements/groups, first element/group, flags
    uint4 Source;  // width, height, primary channels, concatenated channels
    uint4 Target;  // width, height, output channels, kernel width
    uint4 Layer;   // weight offset, bias offset, stride, input padding
    uint4 Noise;   // seed, reserved
    float4 Params; // noise strength, negative slope, activation gain, clamp
};
groupshared float TileInput[16][16];
groupshared float TileWeights[16][16];

uint Hash(uint x) { x^=x>>16; x*=0x7feb352d; x^=x>>15; x*=0x846ca68b; return x^(x>>16); }
float Gaussian(uint index) {
    uint x=Hash(index^Noise.x); float value=0;
    [unroll] for(uint i=0;i<12;++i){x=Hash(x+0x9e3779b9);value+=float(x>>8)*(1.0/16777216.0)-0.5;}
    return value;
}
float ReadInput(int2 p,uint c) {
    if(Control.w&1) p=(p+int2(Source.xy))%int2(Source.xy);
    if(any(p<0)||any(p>=int2(Source.xy))) return 0;
    uint pixel=p.y*Source.x+p.x;
    return c<Source.z?Input[pixel*Source.z+c]:Auxiliary[pixel*Source.w+c-Source.z];
}

[numthreads(16,16,1)]
void NeuralMaterialCS(uint3 group:SV_GroupID,uint3 tid:SV_GroupThreadID) {
    uint local=tid.y*16+tid.x;
    if(Control.x==0) {
        uint g=Control.z+group.x;
        uint pixelBlocks=(Target.x*Target.y+15)/16;
        uint pixel=(g%pixelBlocks)*16+tid.y;
        uint channel=(g/pixelBlocks)*16+tid.x;
        uint inputs=Source.z+Source.w, kernel=Target.w;
        uint count=inputs*kernel*kernel;
        float sum=0;
        [loop] for(uint first=0;first<count;first+=16) {
            uint k=first+tid.x;
            float value=0;
            if(pixel<Target.x*Target.y&&k<count) {
                uint c=k%inputs, tap=k/inputs;
                uint ky=tap/kernel,kx=tap%kernel;
                int2 p=int2(pixel%Target.x,pixel/Target.x)*int(Layer.z)+int2(kx,ky)-int(Layer.w);
                value=ReadInput(p,c);
                if(Control.w&4) value*=Styles[c];
            }
            TileInput[tid.y][tid.x]=value;
            k=first+tid.y;
            uint weightK=k;
            if((Control.w&2)&&k<count) weightK=(kernel*kernel-1-k/inputs)*inputs+k%inputs;
            TileWeights[tid.y][tid.x]=(k<count&&channel<Target.z)?Model[Layer.x+weightK*Target.z+channel]:0;
            GroupMemoryBarrierWithGroupSync();
            [unroll] for(uint j=0;j<16;++j) sum+=TileInput[tid.y][j]*TileWeights[j][tid.x];
            GroupMemoryBarrierWithGroupSync();
        }
        if(pixel<Target.x*Target.y&&channel<Target.z) {
            if(Control.w&4) sum*=Styles[512+channel];
            if(Params.x!=0) sum+=Gaussian(pixel)*Params.x;
            sum+=Model[Layer.y+channel];
            if(Control.w&16) sum=tanh(sum);
            else sum=(sum<0?sum*Params.y:sum)*Params.z;
            if(Params.w>0) sum=clamp(sum,-Params.w,Params.w);
            if(Control.w&8) sum+=Auxiliary[pixel*Target.z+channel];
            Output[pixel*Target.z+channel]=sum;
        }
    } else {
        uint index=Control.z+group.x*256+local;
        if(index>=Control.y)return;
        uint channel=index%Target.z,pixel=index/Target.z;
        uint2 p=uint2(pixel%Target.x,pixel/Target.x);
        if(Control.x==1) { // StyleGAN upfirdn, zero insertion + [1,3,3,1] FIR, gain4.
            float sum=0;
            [unroll] for(uint y=0;y<4;++y) [unroll] for(uint x=0;x<4;++x) {
                int2 q=int2(p)+int2(x,y)-int(Layer.w);
                if(all((q&1)==0)&&all(q>=0)&&all(q<int2(Source.xy)*2)) {
                    float wx=(x==1||x==2)?3:1,wy=(y==1||y==2)?3:1;
                    sum+=Input[((q.y/2)*Source.x+q.x/2)*Source.z+channel]*wx*wy*(1.0/16.0);
                }
            }
            Output[index]=sum;
        } else if(Control.x==2) { // U-Net align_corners=True bilinear upsample.
            float2 q=float2(p)*float2(Source.xy-1)/float2(Target.xy-1);
            uint2 lo=uint2(q),hi=min(lo+1,Source.xy-1);float2 f=q-lo;
            float a=Input[(lo.y*Source.x+lo.x)*Source.z+channel];
            float b=Input[(lo.y*Source.x+hi.x)*Source.z+channel];
            float c=Input[(hi.y*Source.x+lo.x)*Source.z+channel];
            float d=Input[(hi.y*Source.x+hi.x)*Source.z+channel];
            Output[index]=lerp(lerp(a,b,f.x),lerp(c,d,f.x),f.y);
        }
    }
}
