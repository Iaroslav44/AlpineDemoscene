#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include "world_generation.h"
namespace {
template<class T>void Drop(T*& p){if(p){p->Release();p=0;}}
struct Texture {
    ID3D11Texture2D* texture=0;ID3D11ShaderResourceView* srv=0;ID3D11UnorderedAccessView* uav=0;
    ~Texture(){Drop(uav);Drop(srv);Drop(texture);}
    bool Create(ID3D11Device* d,DXGI_FORMAT format,UINT size){
        D3D11_TEXTURE2D_DESC q={};q.Width=q.Height=size;q.MipLevels=q.ArraySize=q.SampleDesc.Count=1;
        q.Format=format;q.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
        return SUCCEEDED(d->CreateTexture2D(&q,0,&texture))&&SUCCEEDED(d->CreateShaderResourceView(texture,0,&srv))&&SUCCEEDED(d->CreateUnorderedAccessView(texture,0,&uav));
    }
};
struct Runner {
    ID3D11Device* device;ID3D11DeviceContext* context;int(*pump)();
    ID3D11ComputeShader* shader=0;ID3D11Buffer* constants=0;ID3D11SamplerState* sampler=0;ID3D11Query* event=0;
    ~Runner(){Unbind();Drop(event);Drop(sampler);Drop(constants);Drop(shader);}
    void Unbind(){ID3D11ShaderResourceView* s[4]={};ID3D11UnorderedAccessView* u[2]={};context->CSSetShaderResources(0,4,s);context->CSSetUnorderedAccessViews(0,2,u,0);context->CSSetShader(0,0,0);}
    bool Run(UINT phase,UINT iteration,ID3D11ShaderResourceView* state,ID3D11ShaderResourceView* flow,
        ID3D11ShaderResourceView* original,ID3D11ShaderResourceView* low,ID3D11UnorderedAccessView* out,ID3D11UnorderedAccessView* height){
        if(pump&&!pump())return false;Unbind();UINT data[4]={phase,iteration,1024,4096};
        context->UpdateSubresource(constants,0,0,data,0,0);context->CSSetConstantBuffers(0,1,&constants);
        ID3D11ShaderResourceView* s[4]={state,flow,original,low};ID3D11UnorderedAccessView* u[2]={out,height};
        context->CSSetShaderResources(0,4,s);context->CSSetUnorderedAccessViews(0,2,u,0);context->CSSetSamplers(0,1,&sampler);
        context->CSSetShader(shader,0,0);UINT groups=phase==6?512:128;context->Dispatch(groups,groups,1);
        context->End(event);context->Flush();HRESULT hr;
        while((hr=context->GetData(event,0,0,0))==S_FALSE){if(pump&&!pump())return false;Sleep(1);}
        return SUCCEEDED(hr)&&SUCCEEDED(device->GetDeviceRemovedReason());
    }
};
}
extern "C" int WorldGenerate(ID3D11Device* device,ID3D11DeviceContext* context,
    ID3D11ShaderResourceView* original,ID3D11UnorderedAccessView* height,
    const void* code,uint32_t bytes,WorldGenerationResult* result,int(*pump)()){
    if(!device||!context||!original||!height||!code||!bytes||!result)return 0;
    *result={};result->status=3;LARGE_INTEGER start,finish,frequency;QueryPerformanceCounter(&start);QueryPerformanceFrequency(&frequency);
    Runner r{device,context,pump};Texture state[2],flow,low,ecology;
    if(FAILED(device->CreateComputeShader(code,bytes,0,&r.shader)))return 0;
    D3D11_BUFFER_DESC b={};b.ByteWidth=16;b.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    if(FAILED(device->CreateBuffer(&b,0,&r.constants)))return 0;
    D3D11_SAMPLER_DESC sd={};sd.Filter=D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;sd.MaxLOD=D3D11_FLOAT32_MAX;
    if(FAILED(device->CreateSamplerState(&sd,&r.sampler)))return 0;
    D3D11_QUERY_DESC q={D3D11_QUERY_EVENT,0};if(FAILED(device->CreateQuery(&q,&r.event)))return 0;
    if(!state[0].Create(device,DXGI_FORMAT_R32G32B32A32_FLOAT,1024)||!state[1].Create(device,DXGI_FORMAT_R32G32B32A32_FLOAT,1024)||
       !flow.Create(device,DXGI_FORMAT_R32G32B32A32_FLOAT,1024)||!low.Create(device,DXGI_FORMAT_R32_FLOAT,1024)||
       !ecology.Create(device,DXGI_FORMAT_R16G16B16A16_FLOAT,1024))return 0;
    if(!r.Run(0,0,0,0,original,0,state[0].uav,low.uav))return 0;
    const UINT iterations=96;
    for(UINT i=0;i<iterations;++i){
        if(!r.Run(1,i,state[0].srv,0,0,low.srv,flow.uav,0)||
           !r.Run(2,i,state[0].srv,flow.srv,0,low.srv,state[1].uav,0)||
           !r.Run(3,i,state[1].srv,0,0,low.srv,flow.uav,0)||
           !r.Run(4,i,state[1].srv,flow.srv,0,low.srv,state[0].uav,0))return 0;
    }
    if(!r.Run(7,iterations,state[0].srv,0,0,low.srv,state[1].uav,0)||
       !r.Run(5,iterations,state[1].srv,0,0,low.srv,ecology.uav,0)||
       !r.Run(6,iterations,state[1].srv,0,0,low.srv,0,height))return 0;
    r.Unbind();result->ecologyTexture=ecology.texture;result->ecologySRV=ecology.srv;
    ecology.texture=0;ecology.srv=0;result->status=1;result->iterations=iterations;result->resolution=1024;
    QueryPerformanceCounter(&finish);result->seconds=float(double(finish.QuadPart-start.QuadPart)/frequency.QuadPart);
    return 1;
}
