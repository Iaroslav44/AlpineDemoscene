// Development-only offscreen QA. The shipped runtime remains the MASM host.
// Executes exactly the same P -> H -> Temporal -> Display topology, without a
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
    std::vector<uint8_t> pixels(ID3D11DeviceContext* c) {
        c->CopyResource(staging.Get(), texture.Get());
        D3D11_MAPPED_SUBRESOURCE m{}; check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&m),"Readback map");
        size_t stride=width*(format==DXGI_FORMAT_R32G32B32A32_FLOAT?16:format==DXGI_FORMAT_R16G16B16A16_FLOAT?8:4);
        std::vector<uint8_t> out(stride*height);
        for (UINT y=0;y<height;y++) memcpy(out.data()+y*stride,static_cast<uint8_t*>(m.pData)+y*m.RowPitch,stride);
        c->Unmap(staging.Get(),0); return out;
    }
};
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
    UINT w=960,h=540,frames=3,startFrame=0;float time=8,dt=1.f/60,seed=.375f;double scale=.5;bool warp=false,debug=true,diagnostic=false,loopTime=false;
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
        else throw std::runtime_error("Unknown option: "+a);
    }
    if(w<16||h<16||w>7680||h>4320||!frames||frames>4096||!std::isfinite(time)||!std::isfinite(dt)||!std::isfinite(seed))
        throw std::runtime_error("Invalid dimensions, frame count, or time/seed.");
    if(!std::isfinite(scale)||scale<.125||scale>2)throw std::runtime_error("Render scale must be between 0.125 and 2.");
    const UINT lowWidth=UINT(std::lround(w*scale)),lowHeight=UINT(std::lround(h*scale));
    if(lowWidth<2||lowHeight<2||lowWidth>8192||lowHeight>8192)throw std::runtime_error("Scaled dimensions exceed probe limits.");
    fs::create_directories(outDir);
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL level;
    auto create=[&](UINT flags){return D3D11CreateDevice(nullptr,warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_HARDWARE,nullptr,flags,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context);};
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
    Surface low(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT), humans(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface histories[]={Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT),Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT)};
    Surface output(device.Get(),w,h,DXGI_FORMAT_R8G8B8A8_UNORM);
    const float zero[4]={};for(auto& s:histories)context->ClearRenderTargetView(s.rtv.Get(),zero);
    D3D11_BUFFER_DESC bd{};bd.ByteWidth=32;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> cb;check(device->CreateBuffer(&bd,nullptr,&cb),"CreateCB");
    D3D11_SAMPLER_DESC sd{};sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc=D3D11_COMPARISON_NEVER;sd.MaxAnisotropy=1;sd.MaxLOD=D3D11_FLOAT32_MAX;
    ComPtr<ID3D11SamplerState> sampler;check(device->CreateSamplerState(&sd,&sampler),"CreateSampler");
    context->VSSetShader(vs.Get(),nullptr,0);context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetConstantBuffers(0,1,cb.GetAddressOf());
    context->PSSetConstantBuffers(0,1,cb.GetAddressOf());context->PSSetSamplers(0,1,sampler.GetAddressOf());
    if(diagnostic) {
        auto code=read(shaderDir/"camera_probe.cso");ComPtr<ID3D11PixelShader> shader;
        check(device->CreatePixelShader(code.data(),code.size(),nullptr,&shader),"Create camera probe");
        Surface samples(device.Get(),w,h,DXGI_FORMAT_R32G32B32A32_FLOAT);
        float constants[]={float(w),float(h),time,0,float(w),float(h),seed,time};
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);
        context->OMSetRenderTargets(1,samples.rtv.GetAddressOf(),nullptr);
        D3D11_VIEWPORT viewport{0,0,float(w),float(h),0,1};context->RSSetViewports(1,&viewport);
        context->PSSetShader(shader.Get(),nullptr,0);context->Draw(3,0);
        auto bytes=samples.pixels(context.Get());const auto* values=reinterpret_cast<const float*>(bytes.data());
        double minClearance=1e30,maxError=0;size_t invalid=0;
        std::ofstream csv(outDir/"camera.csv");csv<<"time,ray_index,ground_clearance,projection_error,town_y,lake_y\n";
        for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++) {
            const auto* v=values+(size_t(y)*w+x)*4;
            for(int j=0;j<4;j++)invalid+=!std::isfinite(v[j]);
            minClearance=std::min(minClearance,double(v[0]));maxError=std::max(maxError,double(v[1]));
            csv<<double(x)*128/w<<","<<y<<","<<v[0]<<","<<v[1]<<","<<v[2]<<","<<v[3]<<"\n";
        }
        std::ofstream summary(outDir/"camera_metrics.json");summary<<"{\"samples\":"<<w*h<<",\"min_ground_clearance\":"<<minClearance
            <<",\"max_projection_error\":"<<maxError<<",\"nonfinite_values\":"<<invalid<<",\"town_y\":"<<values[2]<<",\"lake_y\":"<<values[3]<<"}\n";
        std::cout<<"Camera samples="<<w*h<<" min clearance="<<minClearance<<" max roundtrip="<<maxError<<" invalid="<<invalid<<std::endl;
        return invalid||minClearance<.79||maxError>.001?2:0;
    }
    ComPtr<ID3D11Query> disjoint;D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT,0};check(device->CreateQuery(&qd,&disjoint),"CreateDisjoint");
    std::array<ComPtr<ID3D11Query>,5> timestamps;qd.Query=D3D11_QUERY_TIMESTAMP;
    for(auto& q:timestamps)check(device->CreateQuery(&qd,&q),"CreateTimestamp");
    std::ofstream metrics(outDir/"metrics.json");metrics<<"{\"adapter\":\""<<gpu<<"\",\"debug_layer\":"<<(debug?"true":"false")
        <<",\"width\":"<<w<<",\"height\":"<<h<<",\"low_width\":"<<lowWidth<<",\"low_height\":"<<lowHeight<<",\"scale\":"<<scale
        <<",\"seed\":"<<seed<<",\"dt\":"<<dt<<",\"loop_time\":"<<(loopTime?"true":"false")<<",\"frames\":[\n";
    std::vector<uint8_t> previous; bool failed=false; float previousSeconds=time;
    for(UINT f=0;f<frames;f++) {
        float t=time+f*dt;if(loopTime)t=std::fmod(t,128.f);
        const float constants[]={float(lowWidth),float(lowHeight),t,float(startFrame+f),float(w),float(h),seed,f?previousSeconds:t};
        previousSeconds=t;
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);
        UINT prev=f&1,next=prev^1;context->Begin(disjoint.Get());context->End(timestamps[0].Get());
        auto pass=[&](int i,Surface& target,ID3D11ShaderResourceView* s0,ID3D11ShaderResourceView* s1){
            ID3D11ShaderResourceView* nulls[2]={};context->PSSetShaderResources(0,2,nulls);
            context->OMSetRenderTargets(1,target.rtv.GetAddressOf(),nullptr);
            D3D11_VIEWPORT viewport{0,0,float(target.width),float(target.height),0,1};context->RSSetViewports(1,&viewport);
            ID3D11ShaderResourceView* srvs[]={s0,s1};context->PSSetShaderResources(0,2,srvs);
            context->PSSetShader(ps[i].Get(),nullptr,0);context->Draw(3,0);context->End(timestamps[i+1].Get());
        };
        pass(0,low,nullptr,nullptr);pass(1,humans,low.srv.Get(),nullptr);
        pass(2,histories[next],humans.srv.Get(),histories[prev].srv.Get());pass(3,output,histories[next].srv.Get(),nullptr);
        context->End(disjoint.Get());context->Flush();
        auto dis=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),disjoint.Get());std::array<UINT64,5> ticks{};
        for(int i=0;i<5;i++)ticks[i]=query<UINT64>(context.Get(),timestamps[i].Get());
        auto lo=measure(low.pixels(context.Get()));auto hu=measure(humans.pixels(context.Get()));auto hi=measure(histories[next].pixels(context.Get()));
        auto rgba=output.pixels(context.Get());double difference=0;uint64_t hash=14695981039346656037ULL;
        for(size_t i=0;i<rgba.size();i++){hash=(hash^rgba[i])*1099511628211ULL;if(!previous.empty()&&i%4!=3)difference+=std::abs(int(rgba[i])-int(previous[i]));}
        if(!previous.empty())difference/=double(w)*h*3;
        std::ostringstream name;name<<"frame_"<<std::setfill('0')<<std::setw(4)<<f<<".bmp";bmp(outDir/name.str(),rgba,w,h);previous=std::move(rgba);
        double total=0;metrics<<(f?",\n":"")<<"{\"frame\":"<<startFrame+f<<",\"time\":"<<t<<",\"gpu_disjoint\":"<<(dis.Disjoint?"true":"false")<<",\"gpu_ms\":[";
        for(int i=0;i<4;i++){double ms=dis.Disjoint||!dis.Frequency?0:1000.*double(ticks[i+1]-ticks[i])/dis.Frequency;total+=ms;metrics<<(i?",":"")<<ms;}
        metrics<<"],\"world\":"<<json(lo)<<",\"human_composite\":"<<json(hu)<<",\"resolved\":"<<json(hi)
            <<",\"mean_absolute_display_delta\":"<<difference<<",\"rgba_fnv1a64\":\""<<std::hex<<hash<<std::dec<<"\"}";
        // A full image at the minimum encoded depth means the camera/trace is
        // inside geometry. Numeric/API validity alone cannot detect that.
        bool collapsedDepth=lo.nearDepth>size_t(lowWidth)*lowHeight*99/100;
        failed|=lo.invalid||hu.invalid||hi.invalid||lo.outOfDepthRange||hu.outOfDepthRange||hi.outOfDepthRange||dis.Disjoint||collapsedDepth;
        std::cout<<"Frame "<<f<<" t="<<t<<" GPU="<<total<<" ms; invalid="<<(lo.invalid+hu.invalid+hi.invalid)<<"; delta="<<difference<<std::endl;
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
