// Native, framework-free PhotoMat inference. Public pretrained real-photo weights.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <xmmintrin.h>
#include "neural_material_runtime.h"

namespace {
void(*sink)(const char*,const float*,uint32_t)=0;
template<class T>void Release(T*& p){if(p){p->Release();p=0;}}
template<class T>T* Alloc(size_t n){return(T*)VirtualAlloc(0,n*sizeof(T),MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);}
void Free(void* p){if(p)VirtualFree(p,0,MEM_RELEASE);}
void Copy(void* dst,const void* src,size_t n){auto d=(volatile unsigned char*)dst;auto s=(const unsigned char*)src;for(size_t i=0;i<n;++i)d[i]=s[i];}
void Zero(void* dst,size_t n){auto d=(volatile unsigned char*)dst;for(size_t i=0;i<n;++i)d[i]=0;}
float Root(float x){return _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(x)));}
float Clamp(float x,float a,float b){return x<a?a:(x>b?b:x);}
bool Finite(float x){union{float f;uint32_t u;}v;v.f=x;return(v.u&0x7f800000)!=0x7f800000;}
bool Equal(const char* a,const char* b){for(uint32_t i=0;i<80;++i){if(a[i]!=b[i])return false;if(!a[i])return true;}return false;}
void Name(char* out,const char* prefix,uint32_t number,const char* suffix){
    uint32_t n=0;while(*prefix&&n<60)out[n++]=*prefix++;
    if(number>=100)out[n++]=(char)('0'+number/100);
    if(number>=10)out[n++]=(char)('0'+number/10%10);
    out[n++]=(char)('0'+number%10);while(*suffix&&n<79)out[n++]=*suffix++;out[n]=0;
}
void Append(char* out,const char* prefix,const char* suffix){uint32_t n=0;while(*prefix&&n<70)out[n++]=*prefix++;while(*suffix&&n<79)out[n++]=*suffix++;out[n]=0;}
uint32_t Hash(uint32_t x){x^=x>>16;x*=0x7feb352d;x^=x>>15;x*=0x846ca68b;return x^(x>>16);}
float Gaussian(uint32_t& x){float s=0;for(uint32_t i=0;i<12;++i){x=Hash(x+0x9e3779b9);s+=(float)(x>>8)*(1.0f/16777216)-0.5f;}return s;}
struct Tensor{char name[80];uint32_t rank,shape[5],offset,bytes,layout,reserved[3];};
static_assert(sizeof(Tensor)==128,"NAM1 tensor record");
struct U4{uint32_t x,y,z,w;};
struct Constants{U4 control,source,target,layer,noise;float params[4];};
static_assert(sizeof(Constants)==96,"Shader constant ABI");
struct Buffer {
    ID3D11Buffer* buffer=0;ID3D11ShaderResourceView* srv=0;ID3D11UnorderedAccessView* uav=0;
    uint32_t w=0,h=0,c=0,count=0;
    ~Buffer(){Clear();}
    void Clear(){Release(uav);Release(srv);Release(buffer);count=0;w=h=c=0;}
    void Take(Buffer& b){Clear();buffer=b.buffer;srv=b.srv;uav=b.uav;w=b.w;h=b.h;c=b.c;count=b.count;b.buffer=0;b.srv=0;b.uav=0;b.count=0;}
    bool Create(ID3D11Device* device,uint32_t width,uint32_t height,uint32_t channels,const void* initial=0,bool writable=true){
        Clear();uint64_t size=(uint64_t)width*height*channels;if(!size||size>40000000)return false;
        w=width;h=height;c=channels;count=(uint32_t)size;
        D3D11_BUFFER_DESC d={};d.ByteWidth=count*4;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_SHADER_RESOURCE|(writable?D3D11_BIND_UNORDERED_ACCESS:0);
        D3D11_SUBRESOURCE_DATA data={};data.pSysMem=initial;
        if(FAILED(device->CreateBuffer(&d,initial?&data:0,&buffer)))return false;
        D3D11_SHADER_RESOURCE_VIEW_DESC s={};s.Format=DXGI_FORMAT_R32_FLOAT;s.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;s.Buffer.NumElements=count;
        if(FAILED(device->CreateShaderResourceView(buffer,&s,&srv)))return false;
        if(writable){D3D11_UNORDERED_ACCESS_VIEW_DESC u={};u.Format=DXGI_FORMAT_R32_FLOAT;u.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;u.Buffer.NumElements=count;if(FAILED(device->CreateUnorderedAccessView(buffer,&u,&uav)))return false;}
        return true;
    }
};

struct Runner {
    ID3D11Device* device;ID3D11DeviceContext* context;int(*pump)();const unsigned char* bytes;uint32_t byteCount;
    const Tensor* directory=0;uint32_t tensorCount=0,error=3,seed=0,layerIndex=0;
    ID3D11ComputeShader* shader=0;ID3D11Buffer* cb=0;ID3D11Query* event=0;
    Buffer model,styles;Constants constants={};float* latent=0;float* style=0;
    Runner(ID3D11Device* d,ID3D11DeviceContext* c,const void* b,uint32_t n,int(*p)()):device(d),context(c),pump(p),bytes((const unsigned char*)b),byteCount(n){}
    ~Runner(){Unbind();Release(shader);Release(cb);Release(event);Free(latent);}
    void Unbind(){ID3D11ShaderResourceView* s[4]={};ID3D11UnorderedAccessView* u=0;context->CSSetShaderResources(0,4,s);context->CSSetUnorderedAccessViews(0,1,&u,0);context->CSSetShader(0,0,0);}
    bool Alive(){if(pump&&!pump()){error=2;return false;}return true;}
    const Tensor* Find(const char* name){for(uint32_t i=0;i<tensorCount;++i)if(Equal(directory[i].name,name))return directory+i;return 0;}
    const float* Data(const Tensor* t){return(const float*)(bytes+t->offset);}
    bool Init(const void* code,uint32_t codeBytes,uint32_t inputSeed){
        seed=inputSeed;error=3;
        if(!bytes||byteCount<64||byteCount%4||!code||!codeBytes)return false;
        const uint32_t* header=(const uint32_t*)bytes;
        if(header[0]!=0x314d414e||header[1]!=1||header[4]!=256||header[5]!=512||header[6]!=32||header[7]!=8||header[8]!=2)return false;
        for(uint32_t i=9;i<16;++i)if(header[i])return false;
        tensorCount=header[2];uint32_t first=header[3];
        if(tensorCount!=137||first<64+tensorCount*128||first>byteCount||first%4)return false;
        directory=(const Tensor*)(bytes+64);
        uint32_t expected=first;
        for(uint32_t i=0;i<tensorCount;++i){const Tensor& t=directory[i];
            if(t.name[79]||t.rank<1||t.rank>5||t.offset!=expected||t.offset>byteCount||t.bytes>byteCount-t.offset||t.bytes%4||t.layout<1||t.layout>3)return false;
            uint64_t n=1;for(uint32_t j=0;j<t.rank;++j){if(!t.shape[j]||t.shape[j]>4096)return false;n*=t.shape[j];if(n>40000000)return false;}
            if(n*4!=t.bytes)return false;expected+=t.bytes;
        }
        if(expected!=byteCount)return false;
        latent=Alloc<float>(1536);if(!latent){error=6;return false;}style=latent+512;
        error=4;if(FAILED(device->CreateComputeShader(code,codeBytes,0,&shader)))return false;
        D3D11_BUFFER_DESC d={};d.ByteWidth=sizeof(Constants);d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        if(FAILED(device->CreateBuffer(&d,0,&cb)))return false;
        D3D11_QUERY_DESC q={D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&q,&event)))return false;
        if(!model.Create(device,byteCount/4,1,1,bytes,false)||!styles.Create(device,1024,1,1,style,false))return false;
        return Alive();
    }
    bool Wait(){
        context->End(event);context->Flush();ULONGLONG begun=GetTickCount64();
        for(;;){HRESULT hr=context->GetData(event,0,0,0);if(hr==S_OK)return true;if(FAILED(hr)||GetTickCount64()-begun>60000){error=4;return false;}if(!Alive())return false;Sleep(1);}
    }
    bool Run(Buffer& input,Buffer* auxiliary,Buffer& output,bool conv){
        uint32_t total=conv?((output.w*output.h+15)/16)*((output.c+15)/16):output.count;
        const uint32_t chunk=conv?256:131072;
        constants.control.y=total;
        for(uint32_t first=0;first<total;first+=chunk){
            if(!Alive())return false;
            uint32_t n=total-first;if(n>chunk)n=chunk;constants.control.z=first;
            Unbind();context->UpdateSubresource(cb,0,0,&constants,0,0);
            ID3D11ShaderResourceView* srvs[4]={model.srv,input.srv,auxiliary?auxiliary->srv:0,styles.srv};
            context->CSSetShader(shader,0,0);context->CSSetConstantBuffers(0,1,&cb);context->CSSetShaderResources(0,4,srvs);context->CSSetUnorderedAccessViews(0,1,&output.uav,0);
            context->Dispatch(conv?n:(n+255)/256,1,1);if(!Wait())return false;
        }
        Unbind();return true;
    }
    bool Mapping(){
        uint32_t rng=Hash(seed);float norm=0;for(uint32_t i=0;i<512;++i){latent[i]=Gaussian(rng);norm+=latent[i]*latent[i];}
        norm=1/Root(norm/512+1e-8f);for(uint32_t i=0;i<512;++i)latent[i]*=norm;
        if(sink)sink("latent_z",latent,512);
        float next[512];
        for(uint32_t layer=0;layer<2;++layer){char name[80];Name(name,"mapping.fc",layer,".weight");const Tensor* w=Find(name);Name(name,"mapping.fc",layer,".bias");const Tensor* b=Find(name);
            if(!w||!b||w->bytes!=512*512*4||b->bytes!=512*4||w->layout!=1)return false;
            const float* weights=Data(w);const float* bias=Data(b);float gain=0.01f/Root(512.0f);
            for(uint32_t o=0;o<512;++o){float v=0;for(uint32_t i=0;i<512;++i)v+=latent[i]*(weights[o*512+i]*gain);v+=bias[o]*0.01f;next[o]=(v>=0?v:v*0.2f)*1.4142135623730951f;}
            Copy(latent,next,sizeof(next));
        }
        // Standard truncation towards the learned W average reduces outliers.
        const Tensor* avg=Find("mapping.w_avg");if(!avg||avg->bytes!=2048)return false;
        for(uint32_t i=0;i<512;++i)latent[i]=Data(avg)[i]+(latent[i]-Data(avg)[i])*0.7f;
        if(sink)sink("latent_w",latent,512);return true;
    }
    bool Affine(const char* prefix,const Tensor* conv,bool demodulate){
        char key[80];Append(key,prefix,".affine.weight");const Tensor* wt=Find(key);Append(key,prefix,".affine.bias");const Tensor* bt=Find(key);
        uint32_t in=conv->shape[1],out=conv->shape[0],kernel=conv->shape[2];
        if(!wt||!bt||wt->bytes!=in*512*4||bt->bytes!=in*4||in>512||out>512)return false;
        const float* w=Data(wt);const float* b=Data(bt);float gain=1/Root(512.0f);
        for(uint32_t o=0;o<in;++o){float value=b[o];for(uint32_t i=0;i<512;++i)value+=latent[i]*(w[o*512+i]*gain);style[o]=value*(demodulate?1:1/Root((float)in));}
        const float* weights=Data(conv);
        for(uint32_t o=0;o<out;++o){float square=0;if(demodulate){for(uint32_t k=0;k<kernel*kernel*in;++k){float v=weights[k*out+o]*style[k%in];square+=v*v;}}style[512+o]=demodulate?1/Root(square+1e-8f):1;}
        Unbind();context->UpdateSubresource(styles.buffer,0,0,style,0,0);return Alive();
    }
    bool Upsample(Buffer& input,Buffer& output,bool fir,uint32_t padding=2){
        uint32_t extra=fir&&padding==3?2:0;
        if(!output.Create(device,input.w*2+extra,input.h*2+extra,input.c))return false;
        constants={};constants.control.x=fir?1:2;constants.source={input.w,input.h,input.c,0};constants.target={output.w,output.h,output.c,0};constants.layer.w=padding;
        return Run(input,0,output,false);
    }
    bool Convolution(const char* prefix,Buffer& input,Buffer* auxiliary,Buffer& output,uint32_t flags,uint32_t stride,uint32_t padding,uint32_t width,uint32_t height,bool styled=false,bool demod=true){
        char key[80];Append(key,prefix,".weight");const Tensor* w=Find(key);Append(key,prefix,".bias");const Tensor* b=Find(key);
        if(!w||!b||w->rank!=4||w->layout!=2||b->rank!=1||b->shape[0]!=w->shape[0]||w->shape[2]!=w->shape[3]||w->shape[2]>4||w->shape[0]>512)return false;
        uint32_t extra=(auxiliary&&!(flags&8))?auxiliary->c:0;
        if(w->shape[1]!=input.c+extra||(auxiliary&&(auxiliary->w!=width||auxiliary->h!=height)))return false;
        if(!output.Create(device,width,height,w->shape[0]))return false;
        if(styled&&!Affine(prefix,w,demod))return false;
        constants={};constants.control.w=flags|(styled?4:0);
        constants.source={input.w,input.h,input.c,extra};constants.target={width,height,w->shape[0],w->shape[2]};constants.layer={w->offset/4,b->offset/4,stride,padding};
        constants.params[1]=styled?(demod?0.2f:1):0.01f;constants.params[2]=styled&&demod?1.4142135623730951f:1;constants.params[3]=styled?256:0;
        if(styled&&demod){Append(key,prefix,".noise_strength");const Tensor* n=Find(key);if(!n||n->bytes!=4)return false;constants.params[0]=Data(n)[0];constants.noise.x=Hash(seed^(++layerIndex*0x9e3779b9));}
        return Run(input,auxiliary,output,true);
    }
    float* Read(Buffer& input){
        ID3D11Buffer* stage=0;D3D11_BUFFER_DESC d={};d.ByteWidth=input.count*4;d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        if(FAILED(device->CreateBuffer(&d,0,&stage)))return 0;
        context->CopyResource(stage,input.buffer);if(!Wait()){Release(stage);return 0;}
        D3D11_MAPPED_SUBRESOURCE m={};if(FAILED(context->Map(stage,0,D3D11_MAP_READ,0,&m))){Release(stage);return 0;}
        float* values=Alloc<float>(input.count);if(values)Copy(values,m.pData,input.count*4);else error=6;
        context->Unmap(stage,0);Release(stage);
        if(values)for(uint32_t i=0;i<input.count;++i)if(!Finite(values[i])){Free(values);error=3;return 0;}
        return values;
    }
    bool Diagnose(const char* name,Buffer& input){if(!sink)return true;float* p=Read(input);if(!p)return false;sink(name,p,input.count);Free(p);return true;}
    bool Generate(Buffer& maps){
        if(!Mapping())return false;
        const Tensor* initial=Find("synthesis.b4.const");if(!initial||initial->layout!=3||initial->bytes!=4*4*512*4)return false;
        Buffer field,image;if(!field.Create(device,4,4,512,Data(initial)))return false;
        for(uint32_t res=4;res<=256;res*=2){
            char prefix[80];Buffer next,up;
            if(res>4){if(!Upsample(field,up,true,3))return false;field.Clear();Name(prefix,"synthesis.b",res,".conv0");if(!Convolution(prefix,up,0,next,2,1,0,res,res,true))return false;field.Take(next);up.Clear();}
            Name(prefix,"synthesis.b",res,".conv1");if(!Convolution(prefix,field,0,next,0,1,1,res,res,true))return false;field.Take(next);
            if(res>4){if(!Upsample(image,up,true,2))return false;image.Clear();}
            Name(prefix,"synthesis.b",res,".torgb");if(!Convolution(prefix,field,res>4?&up:0,next,res>4?8:0,1,0,res,res,true,false))return false;image.Take(next);
            Name(prefix,"feature_",res,"");if(!Diagnose(prefix,image))return false;
        }
        field.Clear();Buffer levels[5];
        for(uint32_t layer=0;layer<5;++layer){Buffer a,b;char prefix[80];Buffer& input=layer?levels[layer-1]:image;
            Name(prefix,"unet.block",layer,".model.0");if(!Convolution(prefix,input,0,a,1,2,1,input.w/2,input.h/2))return false;
            Name(prefix,"unet.block",layer,".model.2");if(!Convolution(prefix,a,0,b,1,1,1,a.w,a.h))return false;levels[layer].Take(b);
        }
        image.Clear();field.Take(levels[4]);
        for(uint32_t layer=5;layer<9;++layer){Buffer up,a,b;char prefix[80];
            if(!Upsample(field,up,false))return false;field.Clear();Buffer& skip=levels[8-layer];
            Name(prefix,"unet.block",layer,".model.0");if(!Convolution(prefix,up,&skip,a,1,1,1,up.w,up.h))return false;up.Clear();skip.Clear();
            Name(prefix,"unet.block",layer,".model.2");if(!Convolution(prefix,a,0,b,1,1,1,a.w,a.h))return false;field.Take(b);
        }
        Buffer up;if(!Upsample(field,up,false))return false;field.Clear();
        if(!Convolution("unet.out",up,0,maps,17,1,1,256,256))return false;
        return Diagnose("svbrdf_raw",maps);
    }
    bool Texture(float* base,ID3D11Texture2D** texture,ID3D11ShaderResourceView** srv){
        const uint32_t total=87381*4;float* pixels=Alloc<float>(total);if(!pixels){error=6;return false;}
        Copy(pixels,base,256*256*4*sizeof(float));D3D11_SUBRESOURCE_DATA data[9]={};uint32_t offset=0,previous=0,size=256;
        for(uint32_t level=0;level<9;++level){data[level].pSysMem=pixels+offset;data[level].SysMemPitch=size*16;
            if(level){uint32_t prevSize=size*2;for(uint32_t y=0;y<size;++y)for(uint32_t x=0;x<size;++x)for(uint32_t c=0;c<4;++c){uint32_t p=previous+((y*2)*prevSize+x*2)*4+c;pixels[offset+(y*size+x)*4+c]=(pixels[p]+pixels[p+4]+pixels[p+prevSize*4]+pixels[p+prevSize*4+4])*0.25f;}}
            previous=offset;offset+=size*size*4;size/=2;
        }
        D3D11_TEXTURE2D_DESC d={};d.Width=d.Height=256;d.MipLevels=9;d.ArraySize=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;d.Usage=D3D11_USAGE_IMMUTABLE;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        HRESULT hr=device->CreateTexture2D(&d,data,texture);Free(pixels);if(FAILED(hr))return false;
        return SUCCEEDED(device->CreateShaderResourceView(*texture,0,srv));
    }
    bool Finish(Buffer& maps,NeuralMaterialResult& result){
        float* raw=Read(maps);if(!raw)return false;
        float* packed=Alloc<float>(256*256*12);if(!packed){error=6;Free(raw);return false;}
        for(uint32_t i=0;i<256*256*8;++i)raw[i]=Clamp(raw[i]*0.5f+0.5f,0,1);
        for(uint32_t y=0;y<256;++y)for(uint32_t x=0;x<256;++x){uint32_t p=y*256+x;float* a=packed+p*4;float* n=packed+256*256*4+p*4;float* s=packed+256*256*8+p*4;
            a[0]=raw[p*8+1];a[1]=raw[p*8+2];a[2]=raw[p*8+3];a[3]=Clamp(raw[p*8+4],0.2f,0.9f);
            float dx=(raw[(y*256+((x-1)&255))*8]-raw[(y*256+((x+1)&255))*8])*6.4f;
            float dy=(raw[((((y-1)&255)*256)+x)*8]-raw[((((y+1)&255)*256)+x)*8])*6.4f;
            float inv=1/Root(dx*dx+dy*dy+1);n[0]=dx*inv;n[1]=-dy*inv;n[2]=inv;n[3]=raw[p*8];
            s[0]=raw[p*8+5];s[1]=raw[p*8+6];s[2]=raw[p*8+7];s[3]=1;
        }
        Free(raw);bool ok=Texture(packed,&result.diffuseRoughnessTexture,&result.diffuseRoughnessSRV)&&Texture(packed+256*256*4,&result.normalHeightTexture,&result.normalHeightSRV)&&Texture(packed+256*256*8,&result.specularTexture,&result.specularSRV);
        Free(packed);return ok;
    }
};
}
extern "C" void NeuralMaterialSetDiagnosticSink(void(*callback)(const char*,const float*,uint32_t)){sink=callback;}
extern "C" int NeuralMaterialCreate(ID3D11Device* device,ID3D11DeviceContext* context,const void* model,uint32_t bytes,const void* code,uint32_t codeBytes,uint32_t seed,NeuralMaterialResult* result,int(*pump)()){
    if(!result)return 0;Zero(result,sizeof(*result));result->status=3;result->seed=seed;
    if(!device||!context)return 0;
    LARGE_INTEGER begin={},end={},freq={};QueryPerformanceFrequency(&freq);QueryPerformanceCounter(&begin);
    Runner run(device,context,model,bytes,pump);Buffer maps;
    bool ok=run.Init(code,codeBytes,seed)&&run.Generate(maps)&&run.Finish(maps,*result);
    QueryPerformanceCounter(&end);result->seconds=freq.QuadPart?(float)((double)(end.QuadPart-begin.QuadPart)/freq.QuadPart):0;
    if(!ok){Release(result->diffuseRoughnessSRV);Release(result->diffuseRoughnessTexture);Release(result->normalHeightSRV);Release(result->normalHeightTexture);Release(result->specularSRV);Release(result->specularTexture);result->status=run.error;return 0;}
    result->width=256;result->status=0;return 1;
}
