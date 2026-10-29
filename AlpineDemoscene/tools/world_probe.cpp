#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3d11sdklayers.h>
#include <wrl/client.h>
#include <vector>
#include <fstream>
#include <iostream>
#include <cmath>
#include <algorithm>
#include <stdexcept>
#include "world_generation.h"
using Microsoft::WRL::ComPtr;
static void check(HRESULT h,const char* what){if(FAILED(h))throw std::runtime_error(what);}
static int pump(){return 1;}
static unsigned cancelCalls=0;
static int cancelPump(){return ++cancelCalls<2;}
static float half(unsigned short h){unsigned sign=(h&0x8000)<<16,exp=(h>>10)&31,m=h&1023,bits;if(!exp){if(!m)bits=sign;else{int e=-14;while(!(m&1024)){m<<=1;--e;}bits=sign|((e+127)<<23)|((m&1023)<<13);}}else if(exp==31)bits=sign|0x7f800000|(m<<13);else bits=sign|((exp+112)<<23)|(m<<13);float f;memcpy(&f,&bits,4);return f;}
struct ThroughflowResult{double still,east,west;bool passed;};
static ThroughflowResult throughflow(ID3D11Device* device,ID3D11DeviceContext* context,const std::vector<char>& code){
    // Physical regression: the same planar bed, identical water level and
    // sediment, with no flux versus sustained east/west throughflow. Balanced
    // incoming/outgoing water leaves depth unchanged but must transport more
    // sediment than standing water. No velocity implementation is duplicated.
    constexpr UINT N=128;std::vector<float> state(N*N*4),flux(N*N*4),original(N*N);
    for(UINT y=0;y<N;++y)for(UINT x=0;x<N;++x){UINT p=y*N+x;state[p*4]=original[p]=1000.f-2*x;state[p*4+1]=1;}
    D3D11_TEXTURE2D_DESC d={};d.Width=d.Height=N;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    D3D11_SUBRESOURCE_DATA data={state.data(),N*16,0};ComPtr<ID3D11Texture2D> input,flow,output,low,staging;
    check(device->CreateTexture2D(&d,&data,&input),"throughflow input");check(device->CreateTexture2D(&d,nullptr,&flow),"throughflow flux");check(device->CreateTexture2D(&d,nullptr,&output),"throughflow output");
    d.BindFlags=0;d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;check(device->CreateTexture2D(&d,nullptr,&staging),"throughflow staging");
    d.Format=DXGI_FORMAT_R32_FLOAT;d.Usage=D3D11_USAGE_DEFAULT;d.CPUAccessFlags=0;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;data={original.data(),N*4,0};check(device->CreateTexture2D(&d,&data,&low),"throughflow original");
    ComPtr<ID3D11ShaderResourceView> inputView,flowView,lowView;ComPtr<ID3D11UnorderedAccessView> outView;
    check(device->CreateShaderResourceView(input.Get(),nullptr,&inputView),"throughflow input view");check(device->CreateShaderResourceView(flow.Get(),nullptr,&flowView),"throughflow flux view");check(device->CreateShaderResourceView(low.Get(),nullptr,&lowView),"throughflow low view");check(device->CreateUnorderedAccessView(output.Get(),nullptr,&outView),"throughflow output view");
    ComPtr<ID3D11ComputeShader> shader;check(device->CreateComputeShader(code.data(),code.size(),nullptr,&shader),"throughflow shader");UINT parameters[4]={2,0,N,4096};D3D11_BUFFER_DESC bd={};bd.ByteWidth=16;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;D3D11_SUBRESOURCE_DATA bdata={parameters,0,0};ComPtr<ID3D11Buffer> constants;check(device->CreateBuffer(&bd,&bdata,&constants),"throughflow constants");
    D3D11_SAMPLER_DESC samplerDesc={};samplerDesc.Filter=D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;samplerDesc.AddressU=samplerDesc.AddressV=samplerDesc.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;samplerDesc.MaxLOD=D3D11_FLOAT32_MAX;
    ComPtr<ID3D11SamplerState> sampler;check(device->CreateSamplerState(&samplerDesc,&sampler),"throughflow declared sampler");context->CSSetSamplers(0,1,sampler.GetAddressOf());
    double erosion[3]={};bool finite=true;
    for(UINT mode=0;mode<3;++mode){
        std::fill(flux.begin(),flux.end(),0.f);if(mode)for(UINT p=0;p<N*N;++p)flux[p*4+(mode==1?1:0)]=.25f;
        ID3D11ShaderResourceView* empty[4]={};ID3D11UnorderedAccessView* noUAV[2]={};context->CSSetShaderResources(0,4,empty);context->CSSetUnorderedAccessViews(0,2,noUAV,nullptr);
        context->UpdateSubresource(flow.Get(),0,nullptr,flux.data(),N*16,0);ID3D11ShaderResourceView* views[4]={inputView.Get(),flowView.Get(),nullptr,lowView.Get()};
        context->CSSetShaderResources(0,4,views);context->CSSetUnorderedAccessViews(0,1,outView.GetAddressOf(),nullptr);context->CSSetShader(shader.Get(),nullptr,0);context->CSSetConstantBuffers(0,1,constants.GetAddressOf());context->Dispatch(N/8,N/8,1);
        context->CSSetUnorderedAccessViews(0,2,noUAV,nullptr);context->CopyResource(staging.Get(),output.Get());D3D11_MAPPED_SUBRESOURCE mapped={};check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped),"throughflow readback");
        for(UINT y=16;y<=32;y+=8)for(UINT x=16;x<=32;x+=8){const float* row=(const float*)((const char*)mapped.pData+y*mapped.RowPitch);float delta=original[y*N+x]-row[x*4];finite=finite&&std::isfinite(delta);erosion[mode]+=delta/9;}
        context->Unmap(staging.Get(),0);context->CSSetShaderResources(0,4,empty);
    }
    context->CSSetShader(nullptr,nullptr,0);ID3D11Buffer* noBuffer=nullptr;context->CSSetConstantBuffers(0,1,&noBuffer);ID3D11SamplerState* noSampler=nullptr;context->CSSetSamplers(0,1,&noSampler);
    return{erosion[0],erosion[1],erosion[2],finite&&erosion[0]>0&&erosion[1]>5*erosion[0]&&erosion[2]>5*erosion[0]&&std::abs(erosion[1]-erosion[2])<.0001};
}
int main(int argc,char** argv)try{
    const char* shader=argc>1?argv[1]:"build/world_cs.cso";
    std::ifstream input(shader,std::ios::binary);std::vector<char> code((std::istreambuf_iterator<char>(input)),{});
    if(code.empty())throw std::runtime_error("Missing WorldCS");
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL feature;
    check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_DEBUG,nullptr,0,D3D11_SDK_VERSION,&device,&feature,&context),"D3D11 device");
    const ThroughflowResult flowCheck=throughflow(device.Get(),context.Get(),code);
    constexpr unsigned N=4096;std::vector<float> initial(N*N),x(N),z(N);
    for(unsigned i=0;i<N;++i){float p=-6000+i*(12000.f/(N-1));x[i]=85*std::sin(p*.0013f)+170*std::exp(-p*p/2000000);z[i]=65*std::sin(i*.013f);}
    for(unsigned j=0;j<N;++j)for(unsigned i=0;i<N;++i)initial[j*N+i]=430+x[i]+z[j];
    D3D11_TEXTURE2D_DESC d={};d.Width=d.Height=N;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R32_FLOAT;d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    D3D11_SUBRESOURCE_DATA data={initial.data(),N*4,0};ComPtr<ID3D11Texture2D> height;
    check(device->CreateTexture2D(&d,&data,&height),"height");ComPtr<ID3D11ShaderResourceView> srv;ComPtr<ID3D11UnorderedAccessView> uav;
    check(device->CreateShaderResourceView(height.Get(),nullptr,&srv),"SRV");check(device->CreateUnorderedAccessView(height.Get(),nullptr,&uav),"UAV");
    WorldGenerationResult cancelled{};bool cancellationPassed=!WorldGenerate(device.Get(),context.Get(),srv.Get(),uav.Get(),code.data(),unsigned(code.size()),&cancelled,cancelPump)&&cancelCalls==2&&!cancelled.ecologyTexture&&!cancelled.ecologySRV;
    WorldGenerationResult result{};if(!WorldGenerate(device.Get(),context.Get(),srv.Get(),uav.Get(),code.data(),unsigned(code.size()),&result,pump))throw std::runtime_error("WorldGenerate");
    ComPtr<ID3D11Texture2D> ecology;ecology.Attach(result.ecologyTexture);ComPtr<ID3D11ShaderResourceView> ecologySRV;ecologySRV.Attach(result.ecologySRV);
    d.BindFlags=0;d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ComPtr<ID3D11Texture2D> staging;
    check(device->CreateTexture2D(&d,nullptr,&staging),"staging");context->CopyResource(staging.Get(),height.Get());D3D11_MAPPED_SUBRESOURCE map{};check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"map");
    double sumDelta=0,square=0,maxDelta=0,protectedMax=0;unsigned invalid=0,changed=0;
    for(unsigned j=0;j<N;++j){const float* row=(const float*)((const char*)map.pData+j*map.RowPitch);for(unsigned i=0;i<N;++i){float v=row[i],delta=v-initial[j*N+i];invalid+=!std::isfinite(v);sumDelta+=delta;square+=double(delta)*delta;maxDelta=std::max(maxDelta,std::abs(double(delta)));changed+=std::abs(delta)>.001f;
        float wx=-6000+i*(12000.f/(N-1)),wz=-1500+j*(12000.f/(N-1));if(wx*wx+(wz-1800)*(wz-1800)<200*200)protectedMax=std::max(protectedMax,std::abs(double(delta)));}}
    context->Unmap(staging.Get(),0);
    D3D11_TEXTURE2D_DESC ed;ecology->GetDesc(&ed);ed.BindFlags=0;ed.Usage=D3D11_USAGE_STAGING;ed.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ComPtr<ID3D11Texture2D> ecoStage;
    check(device->CreateTexture2D(&ed,nullptr,&ecoStage),"ecology staging");context->CopyResource(ecoStage.Get(),ecology.Get());check(context->Map(ecoStage.Get(),0,D3D11_MAP_READ,0,&map),"ecology map");
    float minimum[4]={1,1,1,1},maximum[4]={};unsigned ecoInvalid=0;
    for(unsigned j=0;j<ed.Height;++j){const unsigned short* row=(const unsigned short*)((const char*)map.pData+j*map.RowPitch);for(unsigned i=0;i<ed.Width*4;++i){float v=half(row[i]);ecoInvalid+=!std::isfinite(v)||v<0||v>1;minimum[i%4]=std::min(minimum[i%4],v);maximum[i%4]=std::max(maximum[i%4],v);}}
    context->Unmap(ecoStage.Get(),0);
    ComPtr<ID3D11InfoQueue> queue;device.As(&queue);unsigned warnings=0,errors=0;
    for(UINT64 i=0;queue&&i<queue->GetNumStoredMessages();++i){SIZE_T bytes=0;queue->GetMessage(i,nullptr,&bytes);std::vector<char> b(bytes);auto m=(D3D11_MESSAGE*)b.data();queue->GetMessage(i,m,&bytes);if(m->Severity<=D3D11_MESSAGE_SEVERITY_ERROR)++errors;else if(m->Severity==D3D11_MESSAGE_SEVERITY_WARNING)++warnings;}
    double mean=sumDelta/(double(N)*N),rms=std::sqrt(square/(double(N)*N));
    bool passed=!invalid&&!ecoInvalid&&!warnings&&!errors&&protectedMax<.001&&rms>.01&&std::abs(mean)<.0001&&flowCheck.passed&&cancellationPassed;
    std::cout<<"{\"passed\":"<<(passed?"true":"false")<<",\"seconds\":"<<result.seconds<<",\"iterations\":"<<result.iterations<<",\"height_nonfinite\":"<<invalid<<",\"ecology_invalid\":"<<ecoInvalid<<",\"mean_height_delta\":"<<mean<<",\"rms_height_delta\":"<<rms<<",\"max_height_delta\":"<<maxDelta<<",\"protected_max_delta\":"<<protectedMax<<",\"changed_texels\":"<<changed<<",\"debug_warnings\":"<<warnings<<",\"debug_errors\":"<<errors<<",\"ecology_min\":["<<minimum[0]<<","<<minimum[1]<<","<<minimum[2]<<","<<minimum[3]<<"],\"ecology_max\":["<<maximum[0]<<","<<maximum[1]<<","<<maximum[2]<<","<<maximum[3]<<"],\"throughflow\":{\"passed\":"<<(flowCheck.passed?"true":"false")<<",\"standing_erosion\":"<<flowCheck.still<<",\"east_erosion\":"<<flowCheck.east<<",\"west_erosion\":"<<flowCheck.west<<"},\"cancellation_passed\":"<<(cancellationPassed?"true":"false")<<",\"cancel_callbacks\":"<<cancelCalls<<"}\n";
    return passed?0:2;
}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
