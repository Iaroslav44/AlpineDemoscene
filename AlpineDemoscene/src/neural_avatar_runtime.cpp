// Minimal D3D11 inference and mesh extraction for the pretrained gDNA decoder.
// Uses Win32 allocation and D3D11 only; no CUDA, Python, ONNX or CRT at runtime.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <xmmintrin.h>
#include "neural_avatar_runtime.h"

namespace {
void(*diagnosticSink)(const char*,const float*,uint32_t)=0;
void Zero(void* p, size_t n){unsigned char* d=(unsigned char*)p;for(size_t i=0;i<n;++i)d[i]=0;}
void Copy(void* p,const void* q,size_t n){unsigned char* d=(unsigned char*)p;const unsigned char* s=(const unsigned char*)q;for(size_t i=0;i<n;++i)d[i]=s[i];}
bool Equal(const char* a,const char* b){for(unsigned i=0;i<80;++i){if(a[i]!=b[i])return false;if(!a[i])return true;}return false;}
float Root(float x){return _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(x)));}
float Minimum(float a,float b){return a<b?a:b;}
float Maximum(float a,float b){return a>b?a:b;}
bool Finite(float x){union{float f;uint32_t u;}v;v.f=x;return(v.u&0x7f800000)!=0x7f800000;}
template<class T>void Release(T*& p){if(p){p->Release();p=0;}}
template<class T>T* Allocate(size_t n){return(T*)VirtualAlloc(0,sizeof(T)*n,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);}
void Free(void* p){if(p)VirtualFree(p,0,MEM_RELEASE);}
struct F3{float x,y,z;};
F3 Add(F3 a,F3 b){return{a.x+b.x,a.y+b.y,a.z+b.z};}
F3 Sub(F3 a,F3 b){return{a.x-b.x,a.y-b.y,a.z-b.z};}
F3 Mul(F3 a,float v){return{a.x*v,a.y*v,a.z*v};}
float Dot(F3 a,F3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
F3 Cross(F3 a,F3 b){return{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
F3 Normal(F3 a){return Mul(a,1.0f/Root(Maximum(Dot(a,a),1e-20f)));}

struct Tensor{char name[80];uint32_t rank,shape[5],offset,bytes,type,reserved[3];};
static_assert(sizeof(Tensor)==128,"NAV1 directory");
struct U4{uint32_t x,y,z,w;};
struct Constants{U4 control,source,target,offsets;float gridMin[4],gridStep[4];U4 geometry[5],normal[9],skin[5],texture[9],modelInfo,morph;};
static_assert(sizeof(Constants)%16==0,"D3D constant alignment");

struct Buffer {
    ID3D11Buffer* buffer=0;ID3D11ShaderResourceView* srv=0;ID3D11UnorderedAccessView* uav=0;uint32_t count=0;
    void Clear(){Release(uav);Release(srv);Release(buffer);count=0;}
    ~Buffer(){Clear();}
    bool Create(ID3D11Device* device,uint32_t elements,const void* initial=0,bool writable=true){
        Clear();D3D11_BUFFER_DESC d={};d.ByteWidth=elements*4;d.Usage=D3D11_USAGE_DEFAULT;
        d.BindFlags=D3D11_BIND_SHADER_RESOURCE|(writable?D3D11_BIND_UNORDERED_ACCESS:0);
        D3D11_SUBRESOURCE_DATA source={};source.pSysMem=initial;
        if(FAILED(device->CreateBuffer(&d,initial?&source:0,&buffer)))return false;
        D3D11_SHADER_RESOURCE_VIEW_DESC s={};s.Format=DXGI_FORMAT_R32_FLOAT;s.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;s.Buffer.NumElements=elements;
        if(FAILED(device->CreateShaderResourceView(buffer,&s,&srv)))return false;
        if(writable){D3D11_UNORDERED_ACCESS_VIEW_DESC u={};u.Format=DXGI_FORMAT_R32_FLOAT;u.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;u.Buffer.NumElements=elements;
            if(FAILED(device->CreateUnorderedAccessView(buffer,&u,&uav)))return false;}
        count=elements;return true;
    }
    void Take(Buffer& other){Clear();buffer=other.buffer;srv=other.srv;uav=other.uav;count=other.count;other.buffer=0;other.srv=0;other.uav=0;other.count=0;}
};

struct Runner {
    ID3D11Device* device;ID3D11DeviceContext* context;int(*pump)();const unsigned char* nav;uint32_t navBytes;
    ID3D11ComputeShader* shader=0;ID3D11Buffer* constantsBuffer=0;ID3D11Query* event=0;
    Constants constants={};Buffer model,latents,feature;uint32_t error=4;float* codes=0;float timing[3]={};bool head=false;uint32_t shapeDimensions=64,styleOffset=128;
    const Tensor* directory=0;uint32_t tensorCount=0;
    Runner(ID3D11Device* d,ID3D11DeviceContext* c,int(*p)(),const void* n,uint32_t nb):device(d),context(c),pump(p),nav((const unsigned char*)n),navBytes(nb){}
    ~Runner(){Unbind();Release(shader);Release(constantsBuffer);Release(event);Free(codes);}
    void Unbind(){ID3D11ShaderResourceView* srvs[4]={};ID3D11UnorderedAccessView* uav=0;context->CSSetShaderResources(0,4,srvs);context->CSSetUnorderedAccessViews(0,1,&uav,0);context->CSSetShader(0,0,0);}
    bool Alive(){if(pump&&!pump()){error=2;return false;}return true;}
    const Tensor* Find(const char* name){for(uint32_t i=0;i<tensorCount;++i)if(Equal(directory[i].name,name))return directory+i;return 0;}
    const float* Data(const char* name){const Tensor* t=Find(name);return t?(const float*)(nav+t->offset):0;}
    uint32_t Offset(const char* name){const Tensor* t=Find(name);return t?t->offset/4:0;}
    bool Layers(U4* output,const char* prefix,uint32_t count){
        char key[80]={};uint32_t len=0;while(prefix[len]&&len<60){key[len]=prefix[len];++len;}
        for(uint32_t i=0;i<count;++i){key[len]=(char)('0'+i);const char* suffix=".weight";for(uint32_t k=0;k<8;++k)key[len+1+k]=suffix[k];
            const Tensor* w=Find(key);suffix=".bias";for(uint32_t k=0;k<6;++k)key[len+1+k]=suffix[k];const Tensor* b=Find(key);
            if(!w||!b||w->rank!=2||b->rank!=1||w->shape[0]!=b->shape[0]||w->shape[0]>256||w->shape[1]>1024)return false;
            output[i]={w->offset/4,b->offset/4,w->shape[1],w->shape[0]};}
        return true;
    }
    bool Init(const void* cs,uint32_t csBytes,uint32_t seed){
        error=3;if(navBytes<16||((const uint32_t*)nav)[1]!=1)return false;
        uint32_t magic=((const uint32_t*)nav)[0];if(magic!=0x3156414e&&magic!=0x3148414e)return false;
        head=magic==0x3148414e;shapeDimensions=head?256:64;styleOffset=head?705:128;
        constants.modelInfo={head?1u:0u,shapeDimensions,head?256u:64u,head?384u:0u};
        codes=Allocate<float>(1248);if(!codes){error=6;return false;}
        tensorCount=((const uint32_t*)nav)[2];uint32_t dataOffset=((const uint32_t*)nav)[3];
        if(!tensorCount||tensorCount>128||dataOffset<16+tensorCount*128||dataOffset>navBytes)return false;
        directory=(const Tensor*)(nav+16);
        for(uint32_t i=0;i<tensorCount;++i){const Tensor& t=directory[i];if(t.rank<1||t.rank>5||t.type!=1||t.name[79]||t.offset<dataOffset||t.offset>navBytes||t.bytes>navBytes-t.offset||t.offset%4||t.bytes%4)return false;}
        if(!Layers(constants.geometry,"network.lin",5)||!Layers(constants.normal,"norm_network.lin",9)||!Layers(constants.skin,"deformer.lbs_network.lin",5))return false;
        if(head&&!Layers(constants.texture,"tex_network.lin",9))return false;
        if(head){const Tensor* w=Find("morph.expression.weight");const Tensor* b=Find("morph.expression.bias");
            if(!w||!b||w->rank!=2||w->shape[0]!=12||w->shape[1]!=128||b->bytes!=48)return false;
            constants.morph={w->offset/4,b->offset/4,128,12};}
        const float* mean=Data("latent.shape.mean");const float* sd=Data("latent.shape.std");
        const float* dm=Data("latent.detail.mean");const float* ds=Data("latent.detail.std");if(!mean||!sd||!dm||!ds)return false;
        const float* cm=head?Data("latent.color.mean"):0;const float* csd=head?Data("latent.color.std"):0;if(head&&(!cm||!csd))return false;
        uint32_t rng=seed?seed:1;
        uint32_t codeCount=head?640:128,detailEnd=head?384:128;
        for(uint32_t i=0;i<codeCount;++i){float v=0;for(uint32_t j=0;j<12;++j){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;v+=(float)(rng>>8)*(1.0f/16777216.0f)-0.5f;}
            float m=i<shapeDimensions?mean[i]:(i<detailEnd?dm[i-shapeDimensions]:cm[i-detailEnd]);float s=i<shapeDimensions?sd[i]:(i<detailEnd?ds[i-shapeDimensions]:csd[i-detailEnd]);codes[i]=m+v*s;}
        if(diagnosticSink)diagnosticSink("latent",codes,codeCount);
        error=4;if(FAILED(device->CreateComputeShader(cs,csBytes,0,&shader)))return false;
        D3D11_BUFFER_DESC cb={};cb.ByteWidth=sizeof(Constants);cb.Usage=D3D11_USAGE_DEFAULT;cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        if(FAILED(device->CreateBuffer(&cb,0,&constantsBuffer)))return false;
        D3D11_QUERY_DESC q={D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&q,&event)))return false;
        // Coalesce dense-layer GPU reads across output neurons. This is an
        // upload-layout transform only: the portable NAV1 remains row-major.
        float* upload=Allocate<float>(navBytes/4);if(!upload){error=6;return false;}
        Copy(upload,nav,navBytes);
        const U4* groups[4]={constants.geometry,constants.normal,constants.skin,constants.texture};const uint32_t lengths[4]={5,9,5,9};
        for(uint32_t g=0;g<(head?4u:3u);++g)for(uint32_t l=0;l<lengths[g];++l){U4 layer=groups[g][l];const float* source=(const float*)nav+layer.x;
            for(uint32_t out=0;out<layer.w;++out)for(uint32_t in=0;in<layer.z;++in)upload[layer.x+in*layer.w+out]=source[out*layer.z+in];}
        if(head){U4 layer=constants.morph;const float* source=(const float*)nav+layer.x;for(uint32_t out=0;out<12;++out)for(uint32_t in=0;in<128;++in)upload[layer.x+in*12+out]=source[out*128+in];}
        bool uploaded=model.Create(device,navBytes/4,upload,false);Free(upload);
        if(!uploaded||!latents.Create(device,1248,codes,false))return false;
        return true;
    }
    bool Run(Buffer* input,Buffer* auxiliary,Buffer& output,uint32_t elements,bool groupPerElement=false){
        if(!Alive())return false;
        constants.control.y=elements;
        uint32_t chunk=groupPerElement?2048:131072; // bounded batches avoid thousands of Flush/GetData roundtrips
        for(uint32_t start=0;start<elements;start+=chunk){
            if(!Alive())return false;
            uint32_t n=elements-start;if(n>chunk)n=chunk;constants.control.z=start;
            Unbind();context->UpdateSubresource(constantsBuffer,0,0,&constants,0,0);
            ID3D11ShaderResourceView* srvs[4]={model.srv,input?input->srv:0,auxiliary?auxiliary->srv:0,latents.srv};
            context->CSSetShader(shader,0,0);context->CSSetConstantBuffers(0,1,&constantsBuffer);context->CSSetShaderResources(0,4,srvs);
            context->CSSetUnorderedAccessViews(0,1,&output.uav,0);context->Dispatch(groupPerElement?n:(n+255)/256,1,1);
            context->End(event);context->Flush();
            while(context->GetData(event,0,0,0)==S_FALSE){if(!Alive())return false;Sleep(1);}
            if(FAILED(device->GetDeviceRemovedReason()))return false;
        }
        Unbind();return true;
    }
    bool Style(const char* weight,const char* bias,uint32_t outputs){
        const float* w=Data(weight);const float* b=Data(bias);if(!w||!b)return false;
        for(uint32_t i=0;i<outputs;++i){float v=b[i];for(uint32_t j=0;j<shapeDimensions;++j)v+=w[i*shapeDimensions+j]*codes[j];codes[styleOffset+i]=v;}
        Unbind();context->UpdateSubresource(latents.buffer,0,0,codes,0,0);return true;
    }
    bool GenerateFeature(){
        const float* initial=Data("generator.shape_code");if(!initial||!Style("generator.lin_code.weight","generator.lin_code.bias",512))return false;
        float* volume=Allocate<float>(256*128);if(!volume){error=6;return false;}
        for(uint32_t c=0;c<256;++c){float mean=0;for(uint32_t v=0;v<128;++v)mean+=initial[c*128+v];mean/=128;
            float variance=0;for(uint32_t v=0;v<128;++v){float delta=initial[c*128+v]-mean;variance+=delta*delta;}
            float inv=1.0f/Root(variance/127+1e-5f);
            for(uint32_t v=0;v<128;++v){float x=(initial[c*128+v]-mean)*inv*codes[styleOffset+256+c]+codes[styleOffset+c];volume[c*128+v]=x>=0?x:x*0.01f;}}
        bool ok=feature.Create(device,256*128,volume);Free(volume);if(!ok)return false;
        uint32_t w=8,h=8,d=2,c=256;
        for(uint32_t stage=0;stage<3;++stage){
            Buffer up,conv,stats,next;uint32_t nw=w*2,nh=h*2,nd=d*2,nc=c/2;if(nc<64)nc=64;
            if(!up.Create(device,nw*nh*nd*c)||!conv.Create(device,nw*nh*nd*nc)||!next.Create(device,nw*nh*nd*nc))return false;
            constants.source={w,h,d,c};constants.target={nw,nh,nd,c};constants.control={0,0,0,0};
            if(!Run(&feature,0,up,up.count))return false;
            const char* weights[3]={"generator.enc0.weight","generator.enc1.weight","generator.enc2.weight"};
            const char* biases[3]={"generator.enc0.bias","generator.enc1.bias","generator.enc2.bias"};
            constants.source={nw,nh,nd,c};constants.target={nw,nh,nd,nc};constants.offsets={Offset(weights[stage]),Offset(biases[stage]),styleOffset,0};constants.control={1,0,0,0};
            if(!constants.offsets.x||!constants.offsets.y||!Run(&up,0,conv,conv.count))return false;
            up.Clear();feature.Clear();constants.source={nw,nh,nd,nc};
            if(stage<2){
                if(!stats.Create(device,nc*2))return false;
                constants.control={2,0,0,0};if(!Run(&conv,0,stats,nc,true))return false;
                if(stage==0){if(!Style("generator.lin0.weight","generator.lin0.bias",256))return false;}
                else if(!Style("generator.lin1.weight","generator.lin1.bias",128))return false;
            }
            constants.control={3,0,0,stage==2?1u:0u};if(!Run(&conv,stage<2?&stats:0,next,next.count))return false;
            feature.Take(next);w=nw;h=nh;d=nd;c=nc;
        }
        if(diagnosticSink){float* values=Read(feature);if(!values)return false;diagnosticSink("feature",values,feature.count);Free(values);}
        return true;
    }
    float* Read(Buffer& source){
        ID3D11Buffer* staging=0;D3D11_BUFFER_DESC b={};b.ByteWidth=source.count*4;b.Usage=D3D11_USAGE_STAGING;b.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        if(FAILED(device->CreateBuffer(&b,0,&staging)))return 0;
        context->CopyResource(staging,source.buffer);D3D11_MAPPED_SUBRESOURCE mapped={};
        if(FAILED(context->Map(staging,0,D3D11_MAP_READ,0,&mapped))){Release(staging);return 0;}
        float* result=Allocate<float>(source.count);if(result)Copy(result,mapped.pData,source.count*4);
        context->Unmap(staging,0);Release(staging);return result;
    }
};

struct Edge{uint64_t key;uint32_t vertex,pad;};
struct Mesh {
    static const uint32_t MaxVertices=400000,MaxIndices=2400000,HashCount=1048576;
    F3* positions=0;F3* normals=0;uint32_t* indices=0;Edge* edges=0;uint32_t vertexCount=0,indexCount=0;
    const float* field;uint32_t nx,ny,nz;F3 minimum,step;bool valid=true;
    Mesh(const float* f,uint32_t x,uint32_t y,uint32_t z,F3 mn,F3 st):field(f),nx(x),ny(y),nz(z),minimum(mn),step(st){
        positions=Allocate<F3>(MaxVertices);normals=Allocate<F3>(MaxVertices);indices=Allocate<uint32_t>(MaxIndices);edges=Allocate<Edge>(HashCount);valid=positions&&normals&&indices&&edges;}
    ~Mesh(){Free(positions);Free(normals);Free(indices);Free(edges);}
    F3 Position(uint32_t id){return{minimum.x+(id%nx)*step.x,minimum.y+((id/nx)%ny)*step.y,minimum.z+(id/(nx*ny))*step.z};}
    F3 Gradient(uint32_t id){uint32_t x=id%nx,y=(id/nx)%ny,z=id/(nx*ny);
        float dx=field[id+(x+1<nx?1:0)]-field[id-(x?1:0)];float dy=field[id+(y+1<ny?nx:0)]-field[id-(y?nx:0)];float dz=field[id+(z+1<nz?nx*ny:0)]-field[id-(z?nx*ny:0)];
        return Normal({-dx/step.x,-dy/step.y,-dz/step.z});}
    uint32_t Vertex(uint32_t a,uint32_t b){
        if(a>b){uint32_t t=a;a=b;b=t;}uint64_t key=((uint64_t)a<<32)|b;
        uint64_t hash=key*0x9e3779b97f4a7c15ULL;uint32_t slot=(uint32_t)(hash^(hash>>32))&(HashCount-1);
        for(uint32_t tries=0;tries<HashCount;++tries){Edge& edge=edges[slot];if(edge.key==key)return edge.vertex;
            if(!edge.key){if(vertexCount>=MaxVertices){valid=false;return 0;}float t=field[a]/(field[a]-field[b]);
                F3 p=Add(Position(a),Mul(Sub(Position(b),Position(a)),t));F3 n=Normal(Add(Mul(Gradient(a),1-t),Mul(Gradient(b),t)));
                edge.key=key;edge.vertex=vertexCount;positions[vertexCount]=p;normals[vertexCount]=n;return vertexCount++;}
            slot=(slot+1)&(HashCount-1);}
        valid=false;return 0;
    }
    void Triangle(uint32_t a,uint32_t b,uint32_t c){if(indexCount+3>MaxIndices){valid=false;return;}
        if(Dot(Cross(Sub(positions[b],positions[a]),Sub(positions[c],positions[a])),Add(normals[a],Add(normals[b],normals[c])))<0){uint32_t t=b;b=c;c=t;}
        indices[indexCount++]=a;indices[indexCount++]=b;indices[indexCount++]=c;
    }
    void Tetra(const uint32_t* v){uint32_t in[4],out[4],ni=0,no=0;for(uint32_t i=0;i<4;++i){if(field[v[i]]>0)in[ni++]=v[i];else out[no++]=v[i];}
        if(ni==0||ni==4)return;
        if(ni==1){Triangle(Vertex(in[0],out[0]),Vertex(in[0],out[1]),Vertex(in[0],out[2]));}
        else if(ni==3){Triangle(Vertex(out[0],in[0]),Vertex(out[0],in[1]),Vertex(out[0],in[2]));}
        else{uint32_t a=Vertex(in[0],out[0]),b=Vertex(in[0],out[1]),c=Vertex(in[1],out[0]),d=Vertex(in[1],out[1]);Triangle(a,b,c);Triangle(b,d,c);}}
    bool Build(int(*pump)()){
        const uint32_t tet[6][4]={{0,1,3,7},{0,3,2,7},{0,2,6,7},{0,6,4,7},{0,4,5,7},{0,5,1,7}};
        for(uint32_t z=0;z+1<nz;++z){if(pump&&!pump())return false;
            for(uint32_t y=0;y+1<ny;++y)for(uint32_t x=0;x+1<nx;++x){uint32_t a=(z*ny+y)*nx+x;
                uint32_t v[8]={a,a+1,a+nx,a+nx+1,a+nx*ny,a+nx*ny+1,a+nx*ny+nx,a+nx*ny+nx+1};
                uint32_t mask=0;for(uint32_t i=0;i<8;++i){if(!Finite(field[v[i]]))return false;if(field[v[i]]>0)mask|=1<<i;}if(mask==0||mask==255)continue;
                for(uint32_t t=0;t<6;++t){uint32_t corners[4]={v[tet[t][0]],v[tet[t][1]],v[tet[t][2]],v[tet[t][3]]};Tetra(corners);if(!valid)return false;}}}
        return vertexCount>0&&indexCount>0;
    }
};

#include "neural_mesh_cleanup.h"

bool FinishMesh(Runner& r,Mesh& mesh,NeuralAvatarResult* result){
    ULONGLONG begin=GetTickCount64();
    Buffer positions,attributes;
    uint32_t attributeStride=r.head?32:12,vertexStride=r.head?36:16;
    if(!positions.Create(r.device,mesh.vertexCount*3,mesh.positions,false)||!attributes.Create(r.device,mesh.vertexCount*attributeStride))return false;
    r.constants.control={5,0,0,0};if(!r.Run(&r.feature,&positions,attributes,mesh.vertexCount,true))return false;
    float* attr=r.Read(attributes);if(!attr)return false;
    r.timing[2]=(float)(GetTickCount64()-begin)*0.001f;
    if(diagnosticSink){diagnosticSink("positions",(const float*)mesh.positions,mesh.vertexCount*3);diagnosticSink("attributes",attr,mesh.vertexCount*attributeStride);}
    if(!RefineNeuralAttributes(mesh,attr,r.head,r.pump)||!FilterNeuralClothingNormals(mesh,attr,r.head,r.pump)){Free(attr);return false;}
    if(diagnosticSink)diagnosticSink("refined_attributes",attr,mesh.vertexCount*attributeStride);
    F3 lo={1e20f,1e20f,1e20f},hi={-1e20f,-1e20f,-1e20f};
    for(uint32_t i=0;i<mesh.vertexCount;++i){F3 p=mesh.positions[i];lo={Minimum(lo.x,p.x),Minimum(lo.y,p.y),Minimum(lo.z,p.z)};hi={Maximum(hi.x,p.x),Maximum(hi.y,p.y),Maximum(hi.z,p.z)};}
    float height=r.head?0.33f:1.75f;float scale=height/Maximum(hi.y-lo.y,0.1f);float* verts=Allocate<float>(mesh.indexCount*vertexStride);if(!verts){Free(attr);r.error=6;return false;}
    bool valid=true;
    for(uint32_t i=0;i<mesh.indexCount;++i){if((i&4095)==0&&!r.Alive()){valid=false;break;}
        uint32_t id=mesh.indices[i];float* target=verts+i*vertexStride;float* sourceAttribute=attr+id*attributeStride;F3 p=mesh.positions[id];F3 n={sourceAttribute[0],sourceAttribute[1],sourceAttribute[2]};
        if(!Finite(n.x)||!Finite(n.y)||!Finite(n.z)){valid=false;break;}
        if(Dot(n,mesh.normals[id])<0)n=Mul(n,-1);n=Normal(n);
        target[0]=p.x*scale;target[1]=(p.y-lo.y)*scale;target[2]=p.z*scale;target[3]=1;
        target[4]=n.x;target[5]=n.y;target[6]=n.z;target[7]=0;
        for(uint32_t j=0;j<4;++j){float value=sourceAttribute[4+j];
            if(!Finite(value)||value<0||value>(r.head?4:23)){valid=false;break;}
            uint32_t joint=(uint32_t)value;Copy(target+8+j,&joint,4);target[12+j]=sourceAttribute[8+j];}
        for(uint32_t j=12;j<16;++j)if(!Finite(target[j])||target[j]<0||target[j]>1)valid=false;
        if(r.head){for(uint32_t j=0;j<3;++j){target[16+j]=sourceAttribute[12+j];if(!Finite(target[16+j])||target[16+j]<0||target[16+j]>1)valid=false;}target[19]=1;
            for(uint32_t j=0;j<16;++j){target[20+j]=sourceAttribute[16+j]*scale;if(!Finite(target[20+j]))valid=false;}}
    }
    if(valid){
        D3D11_BUFFER_DESC b={};b.ByteWidth=mesh.indexCount*vertexStride*4;b.Usage=D3D11_USAGE_IMMUTABLE;b.BindFlags=D3D11_BIND_SHADER_RESOURCE;b.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;b.StructureByteStride=16;
        D3D11_SUBRESOURCE_DATA source={};source.pSysMem=verts;
        valid=SUCCEEDED(r.device->CreateBuffer(&b,&source,&result->vertexBuffer));
        if(valid){D3D11_SHADER_RESOURCE_VIEW_DESC s={};s.Format=DXGI_FORMAT_UNKNOWN;s.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;s.Buffer.NumElements=mesh.indexCount*(vertexStride/4);
            valid=SUCCEEDED(r.device->CreateShaderResourceView(result->vertexBuffer,&s,&result->vertexSRV));}
        if(valid){result->vertexCount=mesh.indexCount;result->vertexStrideBytes=vertexStride*4;result->boundsMin[0]=lo.x*scale;result->boundsMin[1]=0;result->boundsMin[2]=lo.z*scale;
            result->boundsMax[0]=hi.x*scale;result->boundsMax[1]=height;result->boundsMax[2]=hi.z*scale;}}
    if(valid&&r.head){
        const Tensor* motion=r.Find("motion.frames");const float* duration=r.Data("motion.duration");
        if(!motion||motion->rank!=2||motion->shape[1]!=8||motion->shape[0]<2||!duration||!Finite(*duration)||*duration<=0)valid=false;
        if(valid){
            D3D11_BUFFER_DESC b={};b.ByteWidth=motion->bytes;b.Usage=D3D11_USAGE_IMMUTABLE;b.BindFlags=D3D11_BIND_SHADER_RESOURCE;b.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;b.StructureByteStride=16;
            D3D11_SUBRESOURCE_DATA source={};source.pSysMem=r.nav+motion->offset;
            valid=SUCCEEDED(r.device->CreateBuffer(&b,&source,&result->motionBuffer));
            if(valid){D3D11_SHADER_RESOURCE_VIEW_DESC s={};s.Format=DXGI_FORMAT_UNKNOWN;s.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;s.Buffer.NumElements=motion->shape[0]*2;
                valid=SUCCEEDED(r.device->CreateShaderResourceView(result->motionBuffer,&s,&result->motionSRV));}
            if(valid){result->motionFrames=motion->shape[0];result->motionDuration=*duration;if(diagnosticSink)diagnosticSink("motion",(const float*)source.pSysMem,motion->bytes/4);}
        }
    }
    if(valid&&!r.head){
        float rig[128]={};valid=NeuralBindLandmarks(mesh,attr,scale,lo.y,rig,r.pump);
        if(valid){
            D3D11_BUFFER_DESC b={};b.ByteWidth=sizeof(rig);b.Usage=D3D11_USAGE_IMMUTABLE;b.BindFlags=D3D11_BIND_SHADER_RESOURCE;b.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;b.StructureByteStride=16;
            D3D11_SUBRESOURCE_DATA source={};source.pSysMem=rig;valid=SUCCEEDED(r.device->CreateBuffer(&b,&source,&result->rigBuffer));
            if(valid){D3D11_SHADER_RESOURCE_VIEW_DESC s={};s.Format=DXGI_FORMAT_UNKNOWN;s.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;s.Buffer.NumElements=32;
                valid=SUCCEEDED(r.device->CreateShaderResourceView(result->rigBuffer,&s,&result->rigSRV));}
            if(valid&&diagnosticSink)diagnosticSink("rig",rig,128);
        }
    }
    Free(verts);Free(attr);return valid;
}
} // namespace

extern "C" int NeuralAvatarCreate(ID3D11Device* device,ID3D11DeviceContext* context,
    const void* navData,uint32_t navBytes,const void* csData,uint32_t csBytes,uint32_t seed,
    NeuralAvatarResult* result,int(*pump)()){
    if(!result||!device||!context||!navData||!csData)return 0;Zero(result,sizeof(*result));result->seed=seed;
    LARGE_INTEGER begin,freq,end;QueryPerformanceCounter(&begin);QueryPerformanceFrequency(&freq);
    Runner r(device,context,pump,navData,navBytes);
    ULONGLONG stage=GetTickCount64();
    if(!r.Init(csData,csBytes,seed)||!r.GenerateFeature()){result->status=r.error;return 0;}
    result->reserved[0]=(uint32_t)(GetTickCount64()-stage);r.timing[0]=result->reserved[0]*0.001f;
    const uint32_t nx=r.head?81:65,ny=r.head?97:129,nz=r.head?81:49;
    F3 minimum=r.head?F3{-1,-1,-1}:F3{-1.0f,-1.3f,-0.35f};
    F3 step=r.head?F3{2.0f/(nx-1),2.0f/(ny-1),2.0f/(nz-1)}:F3{2.0f/(nx-1),2.2f/(ny-1),0.7f/(nz-1)};
    Buffer field;
    if(!field.Create(device,nx*ny*nz)){result->status=6;return 0;}
    r.constants.control={4,0,0,0};r.constants.target={nx,ny,nz,1};
    r.constants.gridMin[0]=minimum.x;r.constants.gridMin[1]=minimum.y;r.constants.gridMin[2]=minimum.z;
    r.constants.gridStep[0]=step.x;r.constants.gridStep[1]=step.y;r.constants.gridStep[2]=step.z;
    stage=GetTickCount64();
    if(!r.Run(&r.feature,0,field,nx*ny*nz,true)){result->status=r.error;return 0;}
    result->reserved[1]=(uint32_t)(GetTickCount64()-stage);r.timing[1]=result->reserved[1]*0.001f;
    float* values=r.Read(field);field.Clear();if(!values){result->status=6;return 0;}
    if(diagnosticSink)diagnosticSink("field",values,nx*ny*nz);
    Mesh mesh(values,nx,ny,nz,minimum,step);
    bool ok=mesh.valid&&mesh.Build(pump)&&KeepLargestSurface(mesh,pump);
    if(ok&&diagnosticSink)diagnosticSink("extracted_positions",(const float*)mesh.positions,mesh.vertexCount*3);
    ok=ok&&RefineNeuralGeometry(mesh,r.head,pump)&&FinishMesh(r,mesh,result);Free(values);
    if(!ok){Release(result->vertexSRV);Release(result->vertexBuffer);Release(result->motionSRV);Release(result->motionBuffer);Release(result->rigSRV);Release(result->rigBuffer);result->vertexCount=0;result->status=r.error;return 0;}
    if(diagnosticSink)diagnosticSink("timings",r.timing,3);
    QueryPerformanceCounter(&end);result->seconds=(float)((double)(end.QuadPart-begin.QuadPart)/(double)freq.QuadPart);result->status=1;return 1;
}

extern "C" void NeuralAvatarSetDiagnosticSink(void(*sink)(const char*,const float*,uint32_t)){diagnosticSink=sink;}
