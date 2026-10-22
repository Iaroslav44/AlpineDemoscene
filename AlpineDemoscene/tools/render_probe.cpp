// Development-only offscreen QA. The shipped runtime remains the MASM host.
// Executes the runtime compute -> shadow -> world -> mesh -> human -> temporal
// -> display topology, without a
// window, swapchain, audio device, or pre-generated imagery.
#define NOMINMAX
#include <windows.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <d3d11sdklayers.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
// Match the ABI sizes used by the hand-written x64 host, against the SDK.
static_assert(sizeof(MMTIME)==12, "MMTIME ABI differs from MASM host");
static_assert(sizeof(WAVEHDR)==48, "WAVEHDR ABI differs from MASM host");
static_assert(sizeof(D3D11_TEXTURE2D_DESC)==44, "Texture descriptor ABI differs");
static_assert(sizeof(D3D11_BUFFER_DESC)==24, "Buffer descriptor ABI differs");
static_assert(sizeof(D3D11_SHADER_RESOURCE_VIEW_DESC)==24, "SRV descriptor ABI differs");
static_assert(sizeof(D3D11_UNORDERED_ACCESS_VIEW_DESC)==20, "UAV descriptor ABI differs");
static_assert(sizeof(D3D11_RASTERIZER_DESC)==40, "Rasterizer descriptor ABI differs");
static_assert(sizeof(D3D11_DEPTH_STENCIL_DESC)==52, "Depth state descriptor ABI differs");
namespace fs = std::filesystem;
void check(HRESULT h, const char* context) {
    if (FAILED(h)) { std::ostringstream s; s << context << " HRESULT=0x" << std::hex << unsigned(h); throw std::runtime_error(s.str()); }
}
std::vector<char> read(const fs::path& p) {
    std::ifstream f(p, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("Cannot read shader: " + p.string());
    const auto size = f.tellg(); std::vector<char> data(static_cast<size_t>(size));
    f.seekg(0); f.read(data.data(), size);
    if (!f || data.size()<32 || std::string(data.data(),4)!="DXBC") throw std::runtime_error("Invalid shader: " + p.string());
    return data;
}
struct Surface {
    ComPtr<ID3D11Texture2D> texture, staging;
    ComPtr<ID3D11RenderTargetView> rtv;
    ComPtr<ID3D11ShaderResourceView> srv;
    UINT width, height; DXGI_FORMAT format;
    Surface(ID3D11Device* d, UINT w, UINT h, DXGI_FORMAT fmt):width(w),height(h),format(fmt) {
        D3D11_TEXTURE2D_DESC desc{}; desc.Width=w; desc.Height=h; desc.MipLevels=desc.ArraySize=1;
        desc.Format=fmt; desc.SampleDesc.Count=1; desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        check(d->CreateTexture2D(&desc,nullptr,&texture),"CreateTexture2D");
        check(d->CreateRenderTargetView(texture.Get(),nullptr,&rtv),"CreateRTV");
        check(d->CreateShaderResourceView(texture.Get(),nullptr,&srv),"CreateSRV");
        desc.BindFlags=0; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        check(d->CreateTexture2D(&desc,nullptr,&staging),"CreateStaging");
    }
    std::vector<uint8_t> pixels(ID3D11DeviceContext* c,bool copy=true) {
        if(copy)c->CopyResource(staging.Get(), texture.Get());
        D3D11_MAPPED_SUBRESOURCE m{}; check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&m),"Readback map");
        size_t stride=width*(format==DXGI_FORMAT_R32G32B32A32_FLOAT?16:format==DXGI_FORMAT_R16G16B16A16_FLOAT?8:4);
        std::vector<uint8_t> out(stride*height);
        for (UINT y=0;y<height;y++) memcpy(out.data()+y*stride,static_cast<uint8_t*>(m.pData)+y*m.RowPitch,stride);
        c->Unmap(staging.Get(),0); return out;
    }
};
struct DepthSurface {
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11DepthStencilView> dsv;
    DepthSurface(ID3D11Device* d,UINT w,UINT h) {
        D3D11_TEXTURE2D_DESC desc{};desc.Width=w;desc.Height=h;desc.MipLevels=desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_D32_FLOAT;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_DEPTH_STENCIL;
        check(d->CreateTexture2D(&desc,nullptr,&texture),"Create depth texture");
        check(d->CreateDepthStencilView(texture.Get(),nullptr,&dsv),"Create DSV");
    }
};
struct ScalarMetrics { size_t invalid=0,outOfRange=0,covered=0;double minimum=1e30,maximum=-1e30; };
ScalarMetrics scalarMetrics(const std::vector<uint8_t>& bytes,bool normalized) {
    ScalarMetrics m;const float* values=reinterpret_cast<const float*>(bytes.data());
    for(size_t i=0;i<bytes.size()/4;i++) {
        float v=values[i];if(!std::isfinite(v)){m.invalid++;continue;}
        m.minimum=std::min(m.minimum,double(v));m.maximum=std::max(m.maximum,double(v));
        m.outOfRange+=normalized&&(v<0||v>1);m.covered+=v<1;
    }return m;
}
std::string json(const ScalarMetrics& m) {
    std::ostringstream o;o<<"{\"nonfinite_values\":"<<m.invalid<<",\"out_of_range_values\":"<<m.outOfRange
        <<",\"covered_pixels\":"<<m.covered<<",\"minimum\":"<<m.minimum<<",\"maximum\":"<<m.maximum<<"}";return o.str();
}
float half(uint16_t h) {
    const int e=(h>>10)&31, m=h&1023; float f;
    if (!e) f=std::ldexp(float(m),-24);
    else if(e==31) f=m?NAN:INFINITY;
    else f=std::ldexp(float(m+1024),e-25);
    return (h&32768)?-f:f;
}
struct Metrics {
    size_t invalid=0, zeroDepth=0, nearDepth=0, outOfDepthRange=0, reactive=0, geometry=0;
    double minRGB=1e30,maxRGB=-1e30,luma=0,minDepth=1,maxDepth=0;
};
Metrics measure(const std::vector<uint8_t>& p) {
    Metrics m; const auto* h=reinterpret_cast<const uint16_t*>(p.data()); size_t n=p.size()/8;
    for(size_t i=0;i<n;i++) {
        float c[4]; bool valid=true; for(int j=0;j<4;j++) { c[j]=half(h[i*4+j]); valid &= std::isfinite(c[j]); }
        if(!valid) { m.invalid++; continue; }
        for(int j=0;j<3;j++){m.minRGB=std::min(m.minRGB,double(c[j]));m.maxRGB=std::max(m.maxRGB,double(c[j]));}
        m.luma+=.2126*c[0]+.7152*c[1]+.0722*c[2];
        const double depth=std::abs(c[3]); m.minDepth=std::min(m.minDepth,depth);m.maxDepth=std::max(m.maxDepth,depth);
        m.zeroDepth+=depth<1e-5; m.nearDepth+=depth<=.00011; m.outOfDepthRange+=depth>1.001; m.reactive+=c[3]<0; m.geometry+=depth<.999;
    }
    m.luma/=double(n); return m;
}
std::string json(const Metrics& m) {
    std::ostringstream o; o<<"{\"nonfinite_pixels\":"<<m.invalid<<",\"zero_depth_pixels\":"<<m.zeroDepth<<",\"near_floor_pixels\":"<<m.nearDepth
        <<",\"invalid_depth_pixels\":"<<m.outOfDepthRange<<",\"reactive_pixels\":"<<m.reactive<<",\"geometry_pixels\":"<<m.geometry
        <<",\"min_rgb\":"<<m.minRGB<<",\"max_rgb\":"<<m.maxRGB<<",\"mean_luma\":"<<m.luma
        <<",\"min_encoded_depth\":"<<m.minDepth<<",\"max_encoded_depth\":"<<m.maxDepth<<"}"; return o.str();
}
void bmp(const fs::path& path, const std::vector<uint8_t>& rgba, UINT w, UINT h) {
    BITMAPFILEHEADER fh{}; BITMAPINFOHEADER ih{}; fh.bfType=0x4D42; fh.bfOffBits=sizeof(fh)+sizeof(ih);
    fh.bfSize=fh.bfOffBits+w*h*4; ih.biSize=sizeof(ih); ih.biWidth=LONG(w); ih.biHeight=-LONG(h);
    ih.biPlanes=1; ih.biBitCount=32; ih.biCompression=BI_RGB;
    std::vector<uint8_t> bgra=rgba;for(size_t i=0;i<bgra.size();i+=4)std::swap(bgra[i],bgra[i+2]);
    std::ofstream f(path,std::ios::binary); f.write(reinterpret_cast<char*>(&fh),sizeof(fh));f.write(reinterpret_cast<char*>(&ih),sizeof(ih));
    f.write(reinterpret_cast<char*>(bgra.data()),bgra.size()); if(!f) throw std::runtime_error("Failed to write BMP.");
}
template<class T> T query(ID3D11DeviceContext* c, ID3D11Query* q) {
    T data{}; const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(60);
    while(true) {
        HRESULT hr=c->GetData(q,&data,sizeof(data),0);
        if(hr==S_OK)return data;check(hr,"GPU query");
        if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("GPU query timed out after 60 seconds.");
        Sleep(1);
    }
}
int main(int argc,char** argv) try {
    fs::path shaderDir="build", outDir="build/probe", executable;
    UINT w=1280,h=720,frames=3,startFrame=0;float time=8,dt=1.f/60,seed=.375f;double scale=1;bool warp=false,debug=true,diagnostic=false,loopTime=false,validateInstances=false;
    float diagnosticStart=0,diagnosticSpan=128;
    for(int i=1;i<argc;i++) {
        std::string a=argv[i];
        auto value=[&](){if(++i>=argc)throw std::runtime_error("Missing argument after "+a);return std::string(argv[i]);};
        if(a=="--shaders")shaderDir=value();else if(a=="--out")outDir=value();else if(a=="--exe")executable=value();
        else if(a=="--width")w=std::stoul(value());else if(a=="--height")h=std::stoul(value());
        else if(a=="--scale") {
            const std::string s=value(); const auto slash=s.find('/');
            scale=slash==std::string::npos?std::stod(s):std::stod(s.substr(0,slash))/std::stod(s.substr(slash+1));
        }
        else if(a=="--frames")frames=std::stoul(value());else if(a=="--start-frame")startFrame=std::stoul(value());
        else if(a=="--time")time=std::stof(value());else if(a=="--dt")dt=std::stof(value());else if(a=="--seed")seed=std::stof(value());
        else if(a=="--warp")warp=true;else if(a=="--no-debug")debug=false;else if(a=="--diagnostic")diagnostic=true;else if(a=="--loop-time")loopTime=true;
        else if(a=="--validate-instances")validateInstances=true;
        else if(a=="--diagnostic-start")diagnosticStart=std::stof(value());else if(a=="--diagnostic-span")diagnosticSpan=std::stof(value());
        else throw std::runtime_error("Unknown option: "+a);
    }
    if(w<16||h<16||w>7680||h>4320||!frames||frames>4096||!std::isfinite(time)||!std::isfinite(dt)||!std::isfinite(seed))
        throw std::runtime_error("Invalid dimensions, frame count, or time/seed.");
    if(!std::isfinite(scale)||scale<.125||scale>2)throw std::runtime_error("Render scale must be between 0.125 and 2.");
    if(!std::isfinite(diagnosticStart)||!std::isfinite(diagnosticSpan)||diagnosticSpan<=0)throw std::runtime_error("Invalid diagnostic time range.");
    const UINT lowWidth=UINT(std::lround(w*scale)),lowHeight=UINT(std::lround(h*scale));
    if(lowWidth<2||lowHeight<2||lowWidth>8192||lowHeight>8192)throw std::runtime_error("Scaled dimensions exceed probe limits.");
    fs::create_directories(outDir);
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL level;
    const D3D_FEATURE_LEVEL required=D3D_FEATURE_LEVEL_11_0;
    auto create=[&](UINT flags){return D3D11CreateDevice(nullptr,warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_HARDWARE,nullptr,flags,&required,1,D3D11_SDK_VERSION,&device,&level,&context);};
    HRESULT hr=create(debug?D3D11_CREATE_DEVICE_DEBUG:0);
    if(FAILED(hr)&&debug){device.Reset();context.Reset();debug=false;hr=create(0);}
    check(hr,"D3D11CreateDevice");
    ComPtr<IDXGIDevice> dxgi;check(device.As(&dxgi),"IDXGIDevice");ComPtr<IDXGIAdapter> adapter;check(dxgi->GetAdapter(&adapter),"GetAdapter");
    DXGI_ADAPTER_DESC ad{};check(adapter->GetDesc(&ad),"GetDesc");
    char gpuName[512]{};WideCharToMultiByte(CP_UTF8,0,ad.Description,-1,gpuName,sizeof(gpuName),nullptr,nullptr);std::string gpu(gpuName);
    std::cout<<"Adapter: "<<gpu<<"; debug="<<debug<<"; output="<<w<<"x"<<h<<"; scene="<<lowWidth<<"x"<<lowHeight<<std::endl;
    ComPtr<ID3D11InfoQueue> info;device.As(&info);
    // LOAD_LIBRARY_AS_DATAFILE never executes the candidate's entry point.
    // Reading its resources lets QA test exactly the shipped bytes, even after
    // build.ps1 removes intermediates.
    struct Module { HMODULE value=nullptr; ~Module(){if(value)FreeLibrary(value);} } module;
    if(!executable.empty()) {
        module.value=LoadLibraryExW(fs::absolute(executable).c_str(),nullptr,LOAD_LIBRARY_AS_DATAFILE|LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if(!module.value)throw std::runtime_error("Cannot load candidate EXE resources.");
    }
    auto shaderBytes=[&](int id,const char* file){
        if(!module.value)return read(shaderDir/file);
        HRSRC resource=FindResourceW(module.value,MAKEINTRESOURCEW(id),MAKEINTRESOURCEW(10));
        if(!resource)throw std::runtime_error("Missing candidate shader resource.");
        DWORD size=SizeofResource(module.value,resource);
        const char* data=static_cast<const char*>(LockResource(LoadResource(module.value,resource)));
        if(!data||size<32||std::string(data,4)!="DXBC")throw std::runtime_error("Invalid candidate shader resource.");
        return std::vector<char>(data,data+size);
    };
    auto vb=shaderBytes(101,"scene_vs.cso");ComPtr<ID3D11VertexShader> vs;check(device->CreateVertexShader(vb.data(),vb.size(),nullptr,&vs),"CreateVS");
    std::array<ComPtr<ID3D11PixelShader>,4> ps;
    const char* files[]={"scene_ps.cso","human_ps.cso","temporal_ps.cso","display_ps.cso"};
    for(int i=0;i<4;i++){auto data=shaderBytes(102+i,files[i]);check(device->CreatePixelShader(data.data(),data.size(),nullptr,&ps[i]),files[i]);}
    ComPtr<ID3D11VertexShader> meshVS,shadowVS;
    ComPtr<ID3D11PixelShader> meshPS,shadowPS;
    ComPtr<ID3D11ComputeShader> cameraCS,terrainCS;
    auto meshVB=shaderBytes(106,"mesh_vs.cso");check(device->CreateVertexShader(meshVB.data(),meshVB.size(),nullptr,&meshVS),"Create mesh VS");
    auto meshPB=shaderBytes(107,"mesh_ps.cso");check(device->CreatePixelShader(meshPB.data(),meshPB.size(),nullptr,&meshPS),"Create mesh PS");
    auto shadowVB=shaderBytes(108,"shadow_vs.cso");check(device->CreateVertexShader(shadowVB.data(),shadowVB.size(),nullptr,&shadowVS),"Create shadow VS");
    auto shadowPB=shaderBytes(109,"shadow_ps.cso");check(device->CreatePixelShader(shadowPB.data(),shadowPB.size(),nullptr,&shadowPS),"Create shadow PS");
    auto cameraCB=shaderBytes(110,"camera_cs.cso");check(device->CreateComputeShader(cameraCB.data(),cameraCB.size(),nullptr,&cameraCS),"Create camera CS");
    auto terrainCB=shaderBytes(111,"terrain_cs.cso");check(device->CreateComputeShader(terrainCB.data(),terrainCB.size(),nullptr,&terrainCS),"Create terrain CS");
    Surface low(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT), humans(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface worldSnapshot(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface shadow(device.Get(),2048,2048,DXGI_FORMAT_R32_FLOAT);
    DepthSurface mainDepth(device.Get(),lowWidth,lowHeight),shadowDepth(device.Get(),2048,2048);
    const UINT reflectionWidth=std::max(1u,lowWidth/2),reflectionHeight=std::max(1u,lowHeight/2);
    Surface reflection(device.Get(),reflectionWidth,reflectionHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    DepthSurface reflectionDepth(device.Get(),reflectionWidth,reflectionHeight);
    Surface histories[]={Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT),Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT)};
    Surface output(device.Get(),w,h,DXGI_FORMAT_R8G8B8A8_UNORM);
    const float zero[4]={};for(auto& s:histories)context->ClearRenderTargetView(s.rtv.Get(),zero);
    D3D11_BUFFER_DESC bd{};bd.ByteWidth=32;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> cb;check(device->CreateBuffer(&bd,nullptr,&cb),"CreateCB");
    bd.ByteWidth=16;ComPtr<ID3D11Buffer> batchCB;check(device->CreateBuffer(&bd,nullptr,&batchCB),"Create batch CB");
    ComPtr<ID3D11Buffer> passCB;check(device->CreateBuffer(&bd,nullptr,&passCB),"Create pass CB");
    bd.ByteWidth=192;bd.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    bd.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;bd.StructureByteStride=16;
    ComPtr<ID3D11Buffer> cameraBuffer,cameraStaging;check(device->CreateBuffer(&bd,nullptr,&cameraBuffer),"Create camera cache");
    D3D11_SHADER_RESOURCE_VIEW_DESC csrv{};csrv.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;csrv.Buffer.NumElements=12;
    ComPtr<ID3D11ShaderResourceView> cameraSRV;check(device->CreateShaderResourceView(cameraBuffer.Get(),&csrv,&cameraSRV),"Create camera SRV");
    D3D11_UNORDERED_ACCESS_VIEW_DESC cuav{};cuav.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;cuav.Buffer.NumElements=12;
    ComPtr<ID3D11UnorderedAccessView> cameraUAV;check(device->CreateUnorderedAccessView(cameraBuffer.Get(),&cuav,&cameraUAV),"Create camera UAV");
    bd.BindFlags=0;bd.MiscFlags=0;bd.StructureByteStride=0;bd.Usage=D3D11_USAGE_STAGING;bd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateBuffer(&bd,nullptr,&cameraStaging),"Create camera staging");
    D3D11_TEXTURE2D_DESC td{};td.Width=td.Height=2048;td.MipLevels=td.ArraySize=1;td.Format=DXGI_FORMAT_R32_FLOAT;
    td.SampleDesc.Count=1;td.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    ComPtr<ID3D11Texture2D> terrainTexture,terrainStaging;check(device->CreateTexture2D(&td,nullptr,&terrainTexture),"Create terrain cache");
    ComPtr<ID3D11ShaderResourceView> terrainSRV;check(device->CreateShaderResourceView(terrainTexture.Get(),nullptr,&terrainSRV),"Create terrain SRV");
    ComPtr<ID3D11UnorderedAccessView> terrainUAV;check(device->CreateUnorderedAccessView(terrainTexture.Get(),nullptr,&terrainUAV),"Create terrain UAV");
    td.BindFlags=0;td.Usage=D3D11_USAGE_STAGING;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateTexture2D(&td,nullptr,&terrainStaging),"Create terrain staging");
    D3D11_RASTERIZER_DESC rd{};rd.FillMode=D3D11_FILL_SOLID;rd.CullMode=D3D11_CULL_NONE;rd.DepthClipEnable=TRUE;
    ComPtr<ID3D11RasterizerState> rasterizer;check(device->CreateRasterizerState(&rd,&rasterizer),"Create rasterizer");
    D3D11_DEPTH_STENCIL_DESC dd{};dd.DepthEnable=TRUE;dd.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ALL;dd.DepthFunc=D3D11_COMPARISON_LESS_EQUAL;
    dd.StencilReadMask=dd.StencilWriteMask=255;dd.FrontFace={D3D11_STENCIL_OP_KEEP,D3D11_STENCIL_OP_KEEP,D3D11_STENCIL_OP_KEEP,D3D11_COMPARISON_ALWAYS};dd.BackFace=dd.FrontFace;
    ComPtr<ID3D11DepthStencilState> worldDepth;check(device->CreateDepthStencilState(&dd,&worldDepth),"Create world depth state");
    D3D11_SAMPLER_DESC sd{};sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc=D3D11_COMPARISON_NEVER;sd.MaxAnisotropy=1;sd.MaxLOD=D3D11_FLOAT32_MAX;
    ComPtr<ID3D11SamplerState> sampler;check(device->CreateSamplerState(&sd,&sampler),"CreateSampler");
    context->VSSetShader(vs.Get(),nullptr,0);context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetConstantBuffers(0,1,cb.GetAddressOf());
    context->VSSetConstantBuffers(1,1,batchCB.GetAddressOf());
    context->VSSetConstantBuffers(2,1,passCB.GetAddressOf());context->PSSetConstantBuffers(2,1,passCB.GetAddressOf());
    const float defaultPass[4]={};context->UpdateSubresource(passCB.Get(),0,nullptr,defaultPass,0,0);
    context->PSSetConstantBuffers(0,1,cb.GetAddressOf());context->PSSetSamplers(0,1,sampler.GetAddressOf());
    context->CSSetConstantBuffers(0,1,cb.GetAddressOf());context->RSSetState(rasterizer.Get());
    context->VSSetSamplers(1,1,sampler.GetAddressOf());context->PSSetSamplers(1,1,sampler.GetAddressOf());context->CSSetSamplers(1,1,sampler.GetAddressOf());
    const float initialConstants[]={float(lowWidth),float(lowHeight),time,0,float(w),float(h),seed,time};
    context->UpdateSubresource(cb.Get(),0,nullptr,initialConstants,0,0);
    D3D11_QUERY_DESC terrainQD{D3D11_QUERY_TIMESTAMP_DISJOINT,0};ComPtr<ID3D11Query> terrainDisjoint;
    check(device->CreateQuery(&terrainQD,&terrainDisjoint),"Create terrain disjoint");terrainQD.Query=D3D11_QUERY_TIMESTAMP;
    ComPtr<ID3D11Query> terrainStart,terrainEnd;check(device->CreateQuery(&terrainQD,&terrainStart),"Create terrain start");check(device->CreateQuery(&terrainQD,&terrainEnd),"Create terrain end");
    ID3D11UnorderedAccessView* nullUAV=nullptr;
    context->CSSetShader(terrainCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,terrainUAV.GetAddressOf(),nullptr);
    context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Dispatch(256,256,1);context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
    context->VSSetShaderResources(4,1,terrainSRV.GetAddressOf());context->PSSetShaderResources(4,1,terrainSRV.GetAddressOf());context->CSSetShaderResources(4,1,terrainSRV.GetAddressOf());
    context->CopyResource(terrainStaging.Get(),terrainTexture.Get());D3D11_MAPPED_SUBRESOURCE terrainMap{};
    check(context->Map(terrainStaging.Get(),0,D3D11_MAP_READ,0,&terrainMap),"Map terrain cache");
    std::vector<uint8_t> terrainValues(size_t(2048)*2048*4);
    for(UINT row=0;row<2048;row++)memcpy(terrainValues.data()+size_t(row)*2048*4,static_cast<uint8_t*>(terrainMap.pData)+size_t(row)*terrainMap.RowPitch,2048*4);
    context->Unmap(terrainStaging.Get(),0);const auto terrainMetrics=scalarMetrics(terrainValues,false);
    if(terrainMetrics.invalid)throw std::runtime_error("Terrain cache contains nonfinite values.");
    const auto terrainTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 terrainTicks0=query<UINT64>(context.Get(),terrainStart.Get()),terrainTicks1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(terrainTiming.Disjoint||!terrainTiming.Frequency)throw std::runtime_error("Terrain startup GPU timing is disjoint.");
    const double terrainMS=1000.0*double(terrainTicks1-terrainTicks0)/terrainTiming.Frequency;
    std::ofstream(outDir/"terrain_metrics.json")<<"{\"heightfield\":"<<json(terrainMetrics)<<",\"startup_gpu_ms\":"<<terrainMS<<"}\n";
    auto updateCamera=[&](){
        ID3D11ShaderResourceView* nulls[4]={};context->PSSetShaderResources(0,4,nulls);context->VSSetShaderResources(3,1,nulls);
        context->PSSetShaderResources(5,1,terrainSRV.GetAddressOf()); // safe non-RT fallback in reflection mode
        context->CSSetShader(cameraCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,cameraUAV.GetAddressOf(),nullptr);
        context->Dispatch(1,1,1);context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
        context->VSSetShaderResources(3,1,cameraSRV.GetAddressOf());context->PSSetShaderResources(3,1,cameraSRV.GetAddressOf());
    };
    auto drawMeshes=[&](bool shadowPass){
        constexpr UINT batches[][3]={{3600,32,0},{8712,192,1000},{18,12288,2000},{240,384,20000},{216,4,30000},{288,6144,40000},{432,6,50000}};
        for(size_t i=0;i<(shadowPass?7u:6u);i++) {
            const UINT batchConstants[]={batches[i][2],0,0,0};
            context->UpdateSubresource(batchCB.Get(),0,nullptr,batchConstants,0,0);
            context->DrawInstanced(batches[i][0],batches[i][1],0,0);
        }
    };
    if(validateInstances) {
        auto vertexCode=read(shaderDir/"instance_probe_vs.cso"),pixelCode=read(shaderDir/"instance_probe_ps.cso");
        ComPtr<ID3D11VertexShader> instanceVS;ComPtr<ID3D11PixelShader> instancePS;
        check(device->CreateVertexShader(vertexCode.data(),vertexCode.size(),nullptr,&instanceVS),"Create instance test VS");
        check(device->CreatePixelShader(pixelCode.data(),pixelCode.size(),nullptr,&instancePS),"Create instance test PS");
        context->VSSetShader(instanceVS.Get(),nullptr,0);context->PSSetShader(instancePS.Get(),nullptr,0);
        context->PSSetConstantBuffers(1,1,batchCB.GetAddressOf());
        constexpr UINT contracts[][2]={{0,32},{1000,192},{2000,12288},{20000,384},{30000,4},{40000,6144},{50000,6}};
        std::ofstream result(outDir/"instances.csv");result<<"base,count,api_start,raw_min,raw_max,effective_min,effective_max,mismatches\n";
        size_t errors=0;
        for(const auto& contract:contracts)for(UINT mode=0;mode<2;mode++) {
            const UINT base=contract[0],count=contract[1],apiStart=mode?base:0;
            Surface ids(device.Get(),count,1,DXGI_FORMAT_R32G32B32A32_FLOAT);
            const UINT constants[]={base,count,0,0};context->UpdateSubresource(batchCB.Get(),0,nullptr,constants,0,0);
            const float clear[4]={-1,-1,-1,-1};context->ClearRenderTargetView(ids.rtv.Get(),clear);
            context->OMSetRenderTargets(1,ids.rtv.GetAddressOf(),nullptr);
            D3D11_VIEWPORT viewport{0,0,float(count),1,0,1};context->RSSetViewports(1,&viewport);
            context->DrawInstanced(6,count,0,apiStart);
            auto bytes=ids.pixels(context.Get());const float* values=reinterpret_cast<const float*>(bytes.data());size_t mismatches=0;
            for(UINT id=0;id<count;id++)mismatches+=values[id*4]!=float(id)||values[id*4+1]!=float(base+id)||values[id*4+2]!=float(base)||values[id*4+3]!=1;
            result<<base<<","<<count<<","<<apiStart<<","<<values[0]<<","<<values[(count-1)*4]<<","<<values[1]<<","<<values[(count-1)*4+1]<<","<<mismatches<<"\n";
            errors+=mismatches;
        }
        size_t warnings=0;
        if(info)for(UINT64 i=0;i<info->GetNumStoredMessagesAllowedByRetrievalFilter();i++) {
            SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> storage(size);auto* msg=reinterpret_cast<D3D11_MESSAGE*>(storage.data());
            check(info->GetMessage(i,msg,&size),"Get instance diagnostic message");if(msg->Severity<=D3D11_MESSAGE_SEVERITY_WARNING){warnings++;std::cerr<<msg->pDescription<<"\n";}
        }
        std::cout<<"Instance contract: 14 GPU readbacks, mismatches="<<errors<<", D3D warnings/errors="<<warnings<<std::endl;
        context->ClearState();return errors||warnings?2:0;
    }
    if(diagnostic) {
        auto code=read(shaderDir/"camera_probe.cso");ComPtr<ID3D11PixelShader> shader;
        check(device->CreatePixelShader(code.data(),code.size(),nullptr,&shader),"Create camera probe");
        Surface samples(device.Get(),w,h,DXGI_FORMAT_R32G32B32A32_FLOAT);
        float constants[]={float(w),float(h),diagnosticStart,diagnosticSpan,float(w),float(h),seed,diagnosticStart};
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);
        updateCamera();
        context->OMSetRenderTargets(1,samples.rtv.GetAddressOf(),nullptr);
        D3D11_VIEWPORT viewport{0,0,float(w),float(h),0,1};context->RSSetViewports(1,&viewport);
        context->PSSetShader(shader.Get(),nullptr,0);context->Draw(3,0);
        auto bytes=samples.pixels(context.Get());const auto* values=reinterpret_cast<const float*>(bytes.data());
        double minClearance=1e30,minWaterClearance=1e30,maxError=0;size_t invalid=0;
        std::ofstream csv(outDir/"camera.csv");csv<<"time,ray_index,ground_clearance,projection_error,water_clearance,town_y\n";
        for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++) {
            const auto* v=values+(size_t(y)*w+x)*4;
            for(int j=0;j<4;j++)invalid+=!std::isfinite(v[j]);
            minClearance=std::min(minClearance,double(v[0]));maxError=std::max(maxError,double(v[1]));
            minWaterClearance=std::min(minWaterClearance,double(v[2]));
            csv<<diagnosticStart+double(x)*diagnosticSpan/w<<","<<y<<","<<v[0]<<","<<v[1]<<","<<v[2]<<","<<v[3]<<"\n";
        }
        std::ofstream summary(outDir/"camera_metrics.json");summary<<"{\"samples\":"<<w*h<<",\"min_ground_clearance\":"<<minClearance
            <<",\"min_water_clearance\":"<<minWaterClearance<<",\"range_start\":"<<diagnosticStart<<",\"range_span\":"<<diagnosticSpan
            <<",\"max_projection_error\":"<<maxError<<",\"nonfinite_values\":"<<invalid<<",\"town_y\":"<<values[3]<<"}\n";
        std::cout<<"Camera samples="<<w*h<<" min ground="<<minClearance<<" min water="<<minWaterClearance<<" max roundtrip="<<maxError<<" invalid="<<invalid<<std::endl;
        return invalid||minClearance<.79||minWaterClearance<4.49||maxError>.001?2:0;
    }
    ComPtr<ID3D11Query> disjoint;D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT,0};check(device->CreateQuery(&qd,&disjoint),"CreateDisjoint");
    // One extra timestamp brackets the QA-only world snapshot copy. It is
    // excluded from stage timings, since the shipped runtime makes no copy.
    std::array<ComPtr<ID3D11Query>,11> timestamps;qd.Query=D3D11_QUERY_TIMESTAMP;
    for(auto& q:timestamps)check(device->CreateQuery(&qd,&q),"CreateTimestamp");
    std::ofstream metrics(outDir/"metrics.json");metrics<<"{\"adapter\":\""<<gpu<<"\",\"debug_layer\":"<<(debug?"true":"false")
        <<",\"width\":"<<w<<",\"height\":"<<h<<",\"low_width\":"<<lowWidth<<",\"low_height\":"<<lowHeight<<",\"scale\":"<<scale
        <<",\"terrain_startup_gpu_ms\":"<<terrainMS
        <<",\"seed\":"<<seed<<",\"dt\":"<<dt<<",\"loop_time\":"<<(loopTime?"true":"false")
        <<",\"reflection_width\":"<<reflectionWidth<<",\"reflection_height\":"<<reflectionHeight
        <<",\"stage_names\":[\"camera\",\"shadow\",\"reflection_world\",\"reflection_mesh\",\"world\",\"mesh\",\"human\",\"temporal\",\"display\"],\"frames\":[\n";
    std::vector<uint8_t> previous; bool failed=false; float previousSeconds=time;
    for(UINT f=0;f<frames;f++) {
        float t=time+f*dt;if(loopTime)t=std::fmod(t,128.f);
        const float constants[]={float(lowWidth),float(lowHeight),t,float(startFrame+f),float(w),float(h),seed,f?previousSeconds:t};
        const float phase=std::fmod(t,128.f);const bool reflectionEnabled=phase>=40&&phase<=108;
        const float mainPass[]={0,reflectionEnabled?1.f:0.f,0,0},reflectionPass[]={1,1,0,0};
        context->UpdateSubresource(passCB.Get(),0,nullptr,mainPass,0,0);
        previousSeconds=t;
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);
        UINT prev=f&1,next=prev^1;context->Begin(disjoint.Get());context->End(timestamps[0].Get());
        updateCamera();context->End(timestamps[1].Get());
        context->OMSetDepthStencilState(nullptr,0);
        context->OMSetRenderTargets(1,shadow.rtv.GetAddressOf(),shadowDepth.dsv.Get());
        const float clearShadow[4]={1,1,1,1};context->ClearRenderTargetView(shadow.rtv.Get(),clearShadow);
        context->ClearDepthStencilView(shadowDepth.dsv.Get(),D3D11_CLEAR_DEPTH,1,0);
        D3D11_VIEWPORT shadowViewport{0,0,2048,2048,0,1};context->RSSetViewports(1,&shadowViewport);
        context->VSSetShader(shadowVS.Get(),nullptr,0);context->PSSetShader(shadowPS.Get(),nullptr,0);drawMeshes(true);context->End(timestamps[2].Get());
        if(reflectionEnabled) {
            float reflectedConstants[8];memcpy(reflectedConstants,constants,sizeof(constants));reflectedConstants[0]=float(reflectionWidth);reflectedConstants[1]=float(reflectionHeight);
            context->UpdateSubresource(cb.Get(),0,nullptr,reflectedConstants,0,0);context->UpdateSubresource(passCB.Get(),0,nullptr,reflectionPass,0,0);
            context->OMSetRenderTargets(1,reflection.rtv.GetAddressOf(),reflectionDepth.dsv.Get());
            context->ClearDepthStencilView(reflectionDepth.dsv.Get(),D3D11_CLEAR_DEPTH,1,0);context->OMSetDepthStencilState(worldDepth.Get(),0);
            context->PSSetShaderResources(2,1,shadow.srv.GetAddressOf());
            D3D11_VIEWPORT reflectionViewport{0,0,float(reflectionWidth),float(reflectionHeight),0,1};context->RSSetViewports(1,&reflectionViewport);
            context->VSSetShader(vs.Get(),nullptr,0);context->PSSetShader(ps[0].Get(),nullptr,0);context->Draw(3,0);context->End(timestamps[3].Get());
            context->OMSetDepthStencilState(nullptr,0);context->VSSetShader(meshVS.Get(),nullptr,0);context->PSSetShader(meshPS.Get(),nullptr,0);
            drawMeshes(false);context->End(timestamps[4].Get());
            context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);context->UpdateSubresource(passCB.Get(),0,nullptr,mainPass,0,0);
        } else { context->End(timestamps[3].Get());context->End(timestamps[4].Get()); }
        context->OMSetRenderTargets(1,low.rtv.GetAddressOf(),mainDepth.dsv.Get());
        if(reflectionEnabled)context->PSSetShaderResources(5,1,reflection.srv.GetAddressOf());
        context->ClearDepthStencilView(mainDepth.dsv.Get(),D3D11_CLEAR_DEPTH,1,0);context->OMSetDepthStencilState(worldDepth.Get(),0);
        context->PSSetShaderResources(2,1,shadow.srv.GetAddressOf());
        D3D11_VIEWPORT mainViewport{0,0,float(lowWidth),float(lowHeight),0,1};context->RSSetViewports(1,&mainViewport);
        context->VSSetShader(vs.Get(),nullptr,0);context->PSSetShader(ps[0].Get(),nullptr,0);context->Draw(3,0);context->End(timestamps[5].Get());
        context->CopyResource(worldSnapshot.staging.Get(),low.texture.Get());context->End(timestamps[6].Get());
        context->OMSetDepthStencilState(nullptr,0);context->VSSetShader(meshVS.Get(),nullptr,0);context->PSSetShader(meshPS.Get(),nullptr,0);
        drawMeshes(false);context->End(timestamps[7].Get());context->VSSetShader(vs.Get(),nullptr,0);
        auto pass=[&](int i,Surface& target,ID3D11ShaderResourceView* s0,ID3D11ShaderResourceView* s1){
            ID3D11ShaderResourceView* nulls[2]={};context->PSSetShaderResources(0,2,nulls);
            context->OMSetRenderTargets(1,target.rtv.GetAddressOf(),nullptr);
            D3D11_VIEWPORT viewport{0,0,float(target.width),float(target.height),0,1};context->RSSetViewports(1,&viewport);
            ID3D11ShaderResourceView* srvs[]={s0,s1};context->PSSetShaderResources(0,2,srvs);
            context->PSSetShader(ps[i].Get(),nullptr,0);context->Draw(3,0);context->End(timestamps[i+7].Get());
        };
        pass(1,humans,low.srv.Get(),nullptr);
        pass(2,histories[next],humans.srv.Get(),histories[prev].srv.Get());pass(3,output,histories[next].srv.Get(),nullptr);
        context->End(disjoint.Get());context->Flush();
        auto dis=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),disjoint.Get());std::array<UINT64,11> ticks{};
        for(int i=0;i<11;i++)ticks[i]=query<UINT64>(context.Get(),timestamps[i].Get());
        auto wo=measure(worldSnapshot.pixels(context.Get(),false));auto lo=measure(low.pixels(context.Get()));
        auto hu=measure(humans.pixels(context.Get()));auto hi=measure(histories[next].pixels(context.Get()));
        Metrics re;
        if(reflectionEnabled) {
            auto reflectionPixels=reflection.pixels(context.Get());re=measure(reflectionPixels);
            if(f==0) {
                // Diagnostic only: simple ACES-style view of the linear HDR
                // reflection target. This is never an input to the runtime.
                const uint16_t* values=reinterpret_cast<const uint16_t*>(reflectionPixels.data());
                std::vector<uint8_t> preview(size_t(reflectionWidth)*reflectionHeight*4);
                for(size_t p=0;p<preview.size()/4;p++) {
                    for(size_t c=0;c<3;c++){float x=std::max(0.f,half(values[p*4+c]));float mapped=x*(2.51f*x+.03f)/(x*(2.43f*x+.59f)+.14f);preview[p*4+c]=uint8_t(std::pow(std::clamp(mapped,0.f,1.f),1.f/2.2f)*255);}
                    preview[p*4+3]=255;
                }bmp(outDir/"reflection_preview.bmp",preview,reflectionWidth,reflectionHeight);
            }
        }
        const auto shadowValues=shadow.pixels(context.Get());const auto sh=scalarMetrics(shadowValues,true);
        context->CopyResource(cameraStaging.Get(),cameraBuffer.Get());D3D11_MAPPED_SUBRESOURCE cameraMap{};
        check(context->Map(cameraStaging.Get(),0,D3D11_MAP_READ,0,&cameraMap),"Map camera cache");
        std::vector<uint8_t> cameraValues(192);memcpy(cameraValues.data(),cameraMap.pData,192);context->Unmap(cameraStaging.Get(),0);
        const auto ca=scalarMetrics(cameraValues,false);
        if(f==0) {
            std::vector<uint8_t> shadowImage(size_t(2048)*2048*4);const float* depths=reinterpret_cast<const float*>(shadowValues.data());
            for(size_t p=0;p<shadowImage.size()/4;p++) {
                uint8_t v=uint8_t(std::clamp(std::isfinite(depths[p])?depths[p]:0.f,0.f,1.f)*255);
                shadowImage[4*p]=shadowImage[4*p+1]=shadowImage[4*p+2]=v;shadowImage[4*p+3]=255;
            }bmp(outDir/"shadow.bmp",shadowImage,2048,2048);
        }
        auto rgba=output.pixels(context.Get());double difference=0;uint64_t hash=14695981039346656037ULL;
        for(size_t i=0;i<rgba.size();i++){hash=(hash^rgba[i])*1099511628211ULL;if(!previous.empty()&&i%4!=3)difference+=std::abs(int(rgba[i])-int(previous[i]));}
        if(!previous.empty())difference/=double(w)*h*3;
        std::ostringstream name;name<<"frame_"<<std::setfill('0')<<std::setw(4)<<f<<".bmp";bmp(outDir/name.str(),rgba,w,h);previous=std::move(rgba);
        double total=0;metrics<<(f?",\n":"")<<"{\"frame\":"<<startFrame+f<<",\"time\":"<<t<<",\"gpu_disjoint\":"<<(dis.Disjoint?"true":"false")<<",\"gpu_ms\":[";
        constexpr int stageStarts[]={0,1,2,3,4,6,7,8,9};
        for(int i=0;i<9;i++){int j=stageStarts[i];double ms=dis.Disjoint||!dis.Frequency?0:1000.*double(ticks[j+1]-ticks[j])/dis.Frequency;total+=ms;metrics<<(i?",":"")<<ms;}
        metrics<<"],\"world\":"<<json(wo)<<",\"mesh_composite\":"<<json(lo)<<",\"shadow\":"<<json(sh)<<",\"camera\":"<<json(ca)
            <<",\"human_composite\":"<<json(hu)<<",\"resolved\":"<<json(hi)
            <<",\"reflection_enabled\":"<<(reflectionEnabled?"true":"false")<<",\"reflection\":"<<(reflectionEnabled?json(re):"null")
            <<",\"mean_absolute_display_delta\":"<<difference<<",\"rgba_fnv1a64\":\""<<std::hex<<hash<<std::dec<<"\"}";
        // A full image at the minimum encoded depth means the camera/trace is
        // inside geometry. Numeric/API validity alone cannot detect that.
        bool collapsedDepth=lo.nearDepth>size_t(lowWidth)*lowHeight*99/100;
        failed|=wo.invalid||lo.invalid||hu.invalid||hi.invalid||sh.invalid||ca.invalid||sh.outOfRange||wo.outOfDepthRange||lo.outOfDepthRange||hu.outOfDepthRange||hi.outOfDepthRange||dis.Disjoint||collapsedDepth||(reflectionEnabled&&(re.invalid||re.outOfDepthRange));
        std::cout<<"Frame "<<f<<" t="<<t<<" GPU="<<total<<" ms; invalid="<<(wo.invalid+lo.invalid+hu.invalid+hi.invalid+sh.invalid+ca.invalid)<<"; delta="<<difference<<std::endl;
    }
    size_t debugErrors=0,debugWarnings=0;std::ofstream diagnostics(outDir/"d3d11_messages.txt");
    if(info){for(UINT64 i=0;i<info->GetNumStoredMessagesAllowedByRetrievalFilter();i++){
        SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> storage(size);auto* m=reinterpret_cast<D3D11_MESSAGE*>(storage.data());
        check(info->GetMessage(i,m,&size),"GetMessage");diagnostics<<m->Severity<<": "<<m->pDescription<<"\n";
        debugErrors+=m->Severity<=D3D11_MESSAGE_SEVERITY_ERROR;debugWarnings+=m->Severity==D3D11_MESSAGE_SEVERITY_WARNING;
    }}
    metrics<<"\n],\"debug_errors\":"<<debugErrors<<",\"debug_warnings\":"<<debugWarnings<<"}\n";
    context->ClearState();context->Flush();
    if(debugErrors||debugWarnings)failed=true;return failed?2:0;
} catch(const std::exception& e){std::cerr<<"Probe failed: "<<e.what()<<std::endl;return 1;}
