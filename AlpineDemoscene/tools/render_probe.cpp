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
#include <bcrypt.h>
#pragma comment(lib,"bcrypt.lib")
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <climits>
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
#include "../src/neural_avatar_runtime.h"
using Microsoft::WRL::ComPtr;
// Match the ABI sizes used by the hand-written x64 host, against the SDK.
static_assert(sizeof(MMTIME)==12, "MMTIME ABI differs from MASM host");
static_assert(sizeof(WAVEHDR)==48, "WAVEHDR ABI differs from MASM host");
static_assert(sizeof(D3D11_TEXTURE2D_DESC)==44, "Texture descriptor ABI differs");
static_assert(sizeof(D3D11_TEXTURE3D_DESC)==36, "Volume descriptor ABI differs");
static_assert(sizeof(D3D11_BUFFER_DESC)==24, "Buffer descriptor ABI differs");
static_assert(sizeof(D3D11_SHADER_RESOURCE_VIEW_DESC)==24, "SRV descriptor ABI differs");
static_assert(sizeof(D3D11_UNORDERED_ACCESS_VIEW_DESC)==20, "UAV descriptor ABI differs");
static_assert(sizeof(D3D11_RASTERIZER_DESC)==40, "Rasterizer descriptor ABI differs");
static_assert(sizeof(D3D11_DEPTH_STENCIL_DESC)==52, "Depth state descriptor ABI differs");
namespace fs = std::filesystem;
static fs::path neuralDumpDirectory;
static bool neuralDumpFailed=false;
static void dumpNeuralStage(const char* name,const float* values,uint32_t count) {
    std::ofstream out(neuralDumpDirectory/(std::string(name)+".f32"),std::ios::binary);
    out.write(reinterpret_cast<const char*>(values),size_t(count)*sizeof(float));
    if(!out)neuralDumpFailed=true;
}
constexpr UINT TerrainSize=4096,WaterSize=256,FlightSamples=3841,FlightElements=4*FlightSamples*4;
constexpr UINT MaterialSize=1024,MaterialLayers=8,MaterialMips=11,CameraFloats=15*4;
constexpr UINT InstanceElements=81152,InstanceGroups=778;
constexpr UINT CloudSize=128,BoundsMips=13;
void check(HRESULT h, const char* context) {
    if (FAILED(h)) { std::ostringstream s; s << context << " HRESULT=0x" << std::hex << unsigned(h); throw std::runtime_error(s.str()); }
}
struct Sha256 {
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
    Sha256(){
        if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)
            throw std::runtime_error("Cannot open SHA256 provider.");
        if(BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)<0){BCryptCloseAlgorithmProvider(algorithm,0);algorithm=nullptr;throw std::runtime_error("Cannot create SHA256 hash.");}
    }
    ~Sha256(){if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);}
    void update(const void* bytes,size_t count){if(count>ULONG_MAX||BCryptHashData(hash,(PUCHAR)bytes,ULONG(count),0)<0)throw std::runtime_error("SHA256 input failed.");}
    std::string finish(){unsigned char digest[32];if(BCryptFinishHash(hash,digest,32,0)<0)throw std::runtime_error("SHA256 finish failed.");
        std::ostringstream text;text<<std::hex<<std::setfill('0');for(unsigned char c:digest)text<<std::setw(2)<<unsigned(c);return text.str();}
};
static std::string sha256File(const fs::path& path){
    std::ifstream file(path,std::ios::binary);if(!file)throw std::runtime_error("Cannot hash candidate EXE.");
    Sha256 hash;std::array<char,65536> block;
    while(file){file.read(block.data(),block.size());const auto n=file.gcount();if(n)hash.update(block.data(),size_t(n));}
    if(!file.eof())throw std::runtime_error("Candidate EXE hash read failed.");return hash.finish();
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
struct ComputeSurface {
    ComPtr<ID3D11Texture2D> texture,staging;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
    ComputeSurface(ID3D11Device* d) {
        D3D11_TEXTURE2D_DESC desc{};desc.Width=desc.Height=WaterSize;desc.MipLevels=desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;desc.SampleDesc.Count=1;
        desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
        check(d->CreateTexture2D(&desc,nullptr,&texture),"Create water state");
        check(d->CreateShaderResourceView(texture.Get(),nullptr,&srv),"Create water SRV");
        check(d->CreateUnorderedAccessView(texture.Get(),nullptr,&uav),"Create water UAV");
        desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        check(d->CreateTexture2D(&desc,nullptr,&staging),"Create water readback");
    }
    std::vector<float> values(ID3D11DeviceContext* c) {
        c->CopyResource(staging.Get(),texture.Get());D3D11_MAPPED_SUBRESOURCE map{};
        check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"Map water state");
        std::vector<float> result(size_t(WaterSize)*WaterSize*4);
        for(UINT y=0;y<WaterSize;y++)memcpy(result.data()+size_t(y)*WaterSize*4,static_cast<const uint8_t*>(map.pData)+size_t(y)*map.RowPitch,WaterSize*16);
        c->Unmap(staging.Get(),0);return result;
    }
};
struct MaterialSurface {
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
    MaterialSurface(ID3D11Device* d) {
        D3D11_TEXTURE2D_DESC desc{};desc.Width=desc.Height=MaterialSize;desc.MipLevels=MaterialMips;desc.ArraySize=MaterialLayers;
        desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;
        desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET|D3D11_BIND_UNORDERED_ACCESS;
        desc.MiscFlags=D3D11_RESOURCE_MISC_GENERATE_MIPS;
        check(d->CreateTexture2D(&desc,nullptr,&texture),"Create procedural material array");
        check(d->CreateShaderResourceView(texture.Get(),nullptr,&srv),"Create material SRV");
        D3D11_UNORDERED_ACCESS_VIEW_DESC ud{};ud.Format=desc.Format;ud.ViewDimension=D3D11_UAV_DIMENSION_TEXTURE2DARRAY;
        ud.Texture2DArray.ArraySize=MaterialLayers;
        check(d->CreateUnorderedAccessView(texture.Get(),&ud,&uav),"Create material mip0 UAV");
    }
    std::vector<uint8_t> pixels(ID3D11Device* d,ID3D11DeviceContext* c,UINT layer,UINT mip) {
        const UINT size=std::max(1u,MaterialSize>>mip);
        D3D11_TEXTURE2D_DESC desc{};desc.Width=desc.Height=size;desc.ArraySize=desc.MipLevels=1;
        desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> staging;check(d->CreateTexture2D(&desc,nullptr,&staging),"Create material staging");
        c->CopySubresourceRegion(staging.Get(),0,0,0,0,texture.Get(),D3D11CalcSubresource(mip,layer,MaterialMips),nullptr);
        D3D11_MAPPED_SUBRESOURCE map{};check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"Map material mip");
        std::vector<uint8_t> out(size_t(size)*size*4);
        for(UINT y=0;y<size;y++)memcpy(out.data()+size_t(y)*size*4,static_cast<uint8_t*>(map.pData)+size_t(y)*map.RowPitch,size*4);
        c->Unmap(staging.Get(),0);return out;
    }
};
struct CloudVolume {
    ComPtr<ID3D11Texture3D> texture,staging;
    ComPtr<ID3D11ShaderResourceView> srv;ComPtr<ID3D11UnorderedAccessView> uav;
    CloudVolume(ID3D11Device* d) {
        D3D11_TEXTURE3D_DESC desc{};desc.Width=desc.Height=desc.Depth=CloudSize;desc.MipLevels=1;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
        check(d->CreateTexture3D(&desc,nullptr,&texture),"Create cloud volume");
        check(d->CreateShaderResourceView(texture.Get(),nullptr,&srv),"Create cloud SRV");check(d->CreateUnorderedAccessView(texture.Get(),nullptr,&uav),"Create cloud UAV");
        desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        check(d->CreateTexture3D(&desc,nullptr,&staging),"Create cloud staging");
    }
    std::vector<uint8_t> pixels(ID3D11DeviceContext* c) {
        c->CopyResource(staging.Get(),texture.Get());D3D11_MAPPED_SUBRESOURCE map{};check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"Map cloud volume");
        std::vector<uint8_t> data(size_t(CloudSize)*CloudSize*CloudSize*4);
        for(UINT z=0;z<CloudSize;z++)for(UINT y=0;y<CloudSize;y++)memcpy(data.data()+(size_t(z)*CloudSize+y)*CloudSize*4,static_cast<uint8_t*>(map.pData)+size_t(z)*map.DepthPitch+size_t(y)*map.RowPitch,CloudSize*4);
        c->Unmap(staging.Get(),0);return data;
    }
};
struct TerrainBoundsSurface {
    ComPtr<ID3D11Texture2D> texture;ComPtr<ID3D11ShaderResourceView> srv;
    std::array<ComPtr<ID3D11ShaderResourceView>,BoundsMips> levels;
    std::array<ComPtr<ID3D11UnorderedAccessView>,BoundsMips> uavs;
    TerrainBoundsSurface(ID3D11Device* d) {
        D3D11_TEXTURE2D_DESC desc{};desc.Width=desc.Height=TerrainSize;desc.MipLevels=BoundsMips;desc.ArraySize=1;desc.Format=DXGI_FORMAT_R32_FLOAT;
        desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
        check(d->CreateTexture2D(&desc,nullptr,&texture),"Create terrain bounds");check(d->CreateShaderResourceView(texture.Get(),nullptr,&srv),"Create full bounds SRV");
        for(UINT level=0;level<BoundsMips;level++) {
            D3D11_SHADER_RESOURCE_VIEW_DESC sd{};sd.Format=desc.Format;sd.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D;sd.Texture2D.MostDetailedMip=level;sd.Texture2D.MipLevels=1;
            D3D11_UNORDERED_ACCESS_VIEW_DESC ud{};ud.Format=desc.Format;ud.ViewDimension=D3D11_UAV_DIMENSION_TEXTURE2D;ud.Texture2D.MipSlice=level;
            check(d->CreateShaderResourceView(texture.Get(),&sd,&levels[level]),"Create single-level bounds SRV");check(d->CreateUnorderedAccessView(texture.Get(),&ud,&uavs[level]),"Create bounds mip UAV");
        }
    }
    std::vector<float> values(ID3D11Device* d,ID3D11DeviceContext* c,UINT level) {
        const UINT size=TerrainSize>>level;D3D11_TEXTURE2D_DESC desc{};desc.Width=desc.Height=size;desc.ArraySize=desc.MipLevels=1;
        desc.Format=DXGI_FORMAT_R32_FLOAT;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> staging;check(d->CreateTexture2D(&desc,nullptr,&staging),"Create bounds staging");
        c->CopySubresourceRegion(staging.Get(),0,0,0,0,texture.Get(),level,nullptr);D3D11_MAPPED_SUBRESOURCE map{};
        check(c->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"Map terrain bounds");std::vector<float> data(size_t(size)*size);
        for(UINT y=0;y<size;y++)memcpy(data.data()+size_t(y)*size,static_cast<uint8_t*>(map.pData)+size_t(y)*map.RowPitch,size*4);
        c->Unmap(staging.Get(),0);return data;
    }
};
struct WaterMetrics { size_t invalid=0,foamOutOfRange=0;double volume=0,maxHeight=0,maxVelocity=0,maxFoam=0; };
WaterMetrics waterMetrics(const std::vector<float>& v) {
    WaterMetrics m;const double area=(2200.0/256)*(1600.0/256);
    for(size_t i=0;i<v.size();i+=4) {
        for(size_t j=0;j<4;j++)m.invalid+=!std::isfinite(v[i+j]);
        m.volume+=double(v[i])*area;m.maxHeight=std::max(m.maxHeight,std::abs(double(v[i])));
        m.maxVelocity=std::max(m.maxVelocity,std::hypot(double(v[i+1]),double(v[i+2])));
        m.maxFoam=std::max(m.maxFoam,double(v[i+3]));m.foamOutOfRange+=v[i+3]<0||v[i+3]>1;
    }return m;
}
std::string json(const WaterMetrics& m) {
    std::ostringstream o;o<<"{\"nonfinite_values\":"<<m.invalid<<",\"foam_out_of_range\":"<<m.foamOutOfRange
        <<",\"height_volume_m3\":"<<m.volume<<",\"max_abs_height_m\":"<<m.maxHeight
        <<",\"max_speed_m_s\":"<<m.maxVelocity<<",\"max_foam\":"<<m.maxFoam
        // The solver's wet-cell depth is strictly >0.5m. This conservative
        // bound proves positive total depth without a CPU copy of bathymetry.
        <<",\"wet_total_depth_lower_bound_m\":"<<.5-m.maxHeight<<"}";return o.str();
}
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
size_t changedDepth(const std::vector<uint8_t>& a,const std::vector<uint8_t>& b) {
    if(a.size()!=b.size())throw std::runtime_error("Depth comparison dimensions differ.");
    const auto* av=reinterpret_cast<const uint16_t*>(a.data());const auto* bv=reinterpret_cast<const uint16_t*>(b.data());size_t changed=0;
    for(size_t p=0;p<a.size()/8;p++)changed+=(av[p*4+3]&0x7fff)!=(bv[p*4+3]&0x7fff);
    return changed;
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
    fs::path shaderDir="build", outDir="build/probe", executable,rawProbe,writeNeuralCache,replayNeuralCache,timesFile;
    UINT w=1280,h=720,frames=3,startFrame=0;float time=8,dt=1.f/60,seed=.375f;double scale=1;bool warp=false,debug=true,diagnostic=false,loopTime=false,validateInstances=false,physicsOnly=false,dumpWorld=false,waterDiagnostic=false;
    UINT avatarSeed=42;bool neuralOnly=false,dumpNeural=false,headOnly=false;
    float diagnosticStart=0,diagnosticSpan=128;
    for(int i=1;i<argc;i++) {
        std::string a=argv[i];
        auto value=[&](){if(++i>=argc)throw std::runtime_error("Missing argument after "+a);return std::string(argv[i]);};
        if(a=="--shaders")shaderDir=value();else if(a=="--out")outDir=value();else if(a=="--exe")executable=value();
        else if(a=="--raw-probe")rawProbe=value();
        else if(a=="--width")w=std::stoul(value());else if(a=="--height")h=std::stoul(value());
        else if(a=="--scale") {
            const std::string s=value(); const auto slash=s.find('/');
            scale=slash==std::string::npos?std::stod(s):std::stod(s.substr(0,slash))/std::stod(s.substr(slash+1));
        }
        else if(a=="--frames")frames=std::stoul(value());else if(a=="--start-frame")startFrame=std::stoul(value());
        else if(a=="--avatar-seed")avatarSeed=std::stoul(value());else if(a=="--neural-only")neuralOnly=true;
        else if(a=="--dump-neural")dumpNeural=true;
        else if(a=="--neural-head")headOnly=true;
        else if(a=="--write-neural-cache")writeNeuralCache=value();
        else if(a=="--replay-neural-cache")replayNeuralCache=value();
        else if(a=="--times-file")timesFile=value();
        else if(a=="--time")time=std::stof(value());else if(a=="--dt")dt=std::stof(value());else if(a=="--seed")seed=std::stof(value());
        else if(a=="--warp")warp=true;else if(a=="--no-debug")debug=false;else if(a=="--diagnostic")diagnostic=true;else if(a=="--loop-time")loopTime=true;
        else if(a=="--validate-instances")validateInstances=true;
        else if(a=="--physics-only")physicsOnly=true;
        else if(a=="--dump-world-hdr")dumpWorld=true;
        else if(a=="--diagnostic-water")waterDiagnostic=true;
        else if(a=="--diagnostic-start")diagnosticStart=std::stof(value());else if(a=="--diagnostic-span")diagnosticSpan=std::stof(value());
        else throw std::runtime_error("Unknown option: "+a);
    }
    if(headOnly&&!neuralOnly)throw std::runtime_error("--neural-head is an isolated test; use --neural-only with it.");
    if(!replayNeuralCache.empty()&&(dumpNeural||!writeNeuralCache.empty()))throw std::runtime_error("QA cache replay cannot produce neural inference dumps or overwrite its cache.");
    std::vector<float> frameTimes;
    if(!timesFile.empty()) {
        std::ifstream input(timesFile);if(!input)throw std::runtime_error("Cannot read QA frame times.");
        float value;while(input>>value){if(!std::isfinite(value)||value<0||value>128||frameTimes.size()>=4096)throw std::runtime_error("Invalid QA frame time.");frameTimes.push_back(value);}
        if(!input.eof()||frameTimes.empty())throw std::runtime_error("Invalid or empty QA frame-time file.");
        frames=UINT(frameTimes.size());time=frameTimes.front();
    }
    if(w<16||h<16||w>7680||h>4320||!frames||frames>4096||!std::isfinite(time)||!std::isfinite(dt)||!std::isfinite(seed))
        throw std::runtime_error("Invalid dimensions, frame count, or time/seed.");
    if(!std::isfinite(scale)||scale<.125||scale>2)throw std::runtime_error("Render scale must be between 0.125 and 2.");
    if(!std::isfinite(diagnosticStart)||!std::isfinite(diagnosticSpan)||diagnosticSpan<=0)throw std::runtime_error("Invalid diagnostic time range.");
    const UINT lowWidth=UINT(std::lround(w*scale)),lowHeight=UINT(std::lround(h*scale));
    if(lowWidth<2||lowHeight<2||lowWidth>8192||lowHeight>8192)throw std::runtime_error("Scaled dimensions exceed probe limits.");
    fs::create_directories(outDir);
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL featureLevel;
    const D3D_FEATURE_LEVEL requiredFeatureLevel=D3D_FEATURE_LEVEL_11_0;
    auto create=[&](UINT flags){return D3D11CreateDevice(nullptr,warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_HARDWARE,nullptr,flags,&requiredFeatureLevel,1,D3D11_SDK_VERSION,&device,&featureLevel,&context);};
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
    const std::string candidateSha256=executable.empty()?"":sha256File(executable);
    auto shaderBytes=[&](int id,const char* file){
        if(!module.value)return read(shaderDir/file);
        HRSRC resource=FindResourceW(module.value,MAKEINTRESOURCEW(id),MAKEINTRESOURCEW(10));
        if(!resource)throw std::runtime_error("Missing candidate shader resource.");
        DWORD size=SizeofResource(module.value,resource);
        const char* data=static_cast<const char*>(LockResource(LoadResource(module.value,resource)));
        if(!data||size<32||std::string(data,4)!="DXBC")throw std::runtime_error("Invalid candidate shader resource.");
        return std::vector<char>(data,data+size);
    };
    auto neuralModelBytes=[&](UINT id,const char* relativePath,const char* magic){
        if(module.value) {
            HRSRC resource=FindResourceW(module.value,MAKEINTRESOURCEW(id),MAKEINTRESOURCEW(10));
            if(!resource)throw std::runtime_error("Candidate lacks required neural resource"+std::to_string(id));
            DWORD size=SizeofResource(module.value,resource);
            const char* data=static_cast<const char*>(LockResource(LoadResource(module.value,resource)));
            if(!data||size<32||std::string(data,4)!=magic)throw std::runtime_error("Invalid candidate neural model.");
            return std::vector<char>(data,data+size);
        }
        const fs::path modelPath=shaderDir.parent_path()/relativePath;
        std::ifstream file(modelPath,std::ios::binary|std::ios::ate);
        if(!file)throw std::runtime_error("Cannot read pretrained model: "+modelPath.string());
        const auto length=file.tellg();
        if(length<32||length>=400000000)throw std::runtime_error("Invalid neural model length.");
        std::vector<char> data(static_cast<size_t>(length));file.seekg(0);file.read(data.data(),length);
        if(!file||std::string(data.data(),4)!=magic)throw std::runtime_error("Invalid neural model header.");
        return data;
    };
    const auto avatarShader=shaderBytes(120,"neural_avatar_cs.cso");
    struct NeuralProduct {
        NeuralAvatarResult result{};
        ComPtr<ID3D11Buffer> vertices,motion;
        ComPtr<ID3D11ShaderResourceView> srv,motionSRV;
        std::string json;
    };
    auto generateNeural=[&](bool isHead){
        NeuralProduct product;
        const UINT id=isHead?202:200,jointCount=isHead?5:24,expectedStride=isHead?144:64;
        auto model=neuralModelBytes(id,isHead?"models/head/ganhead-faceverse.nah":"models/avatar/gdna-thuman.nav",isHead?"NAH1":"NAV1");
        Sha256 modelHasher;modelHasher.update(model.data(),model.size());const std::string modelSha=modelHasher.finish();
        const fs::path dumpDirectory=isHead&&!neuralOnly?outDir/"head":outDir;
        fs::create_directories(dumpDirectory);
        if(dumpNeural){neuralDumpDirectory=dumpDirectory;NeuralAvatarSetDiagnosticSink(dumpNeuralStage);}
        const bool cached=!replayNeuralCache.empty();
        std::cout<<(cached?"Replaying QA-only generated geometry: ":"Generating pretrained ")<<(isHead?"GANHead":"gDNA")<<", seed="<<avatarSeed<<"..."<<std::endl;
        const auto started=std::chrono::steady_clock::now();
        auto& result=product.result;
        int success=0;
        if(cached) {
            const fs::path base=replayNeuralCache/std::to_string(id);
            std::ifstream metadata(base.string()+".meta");std::string format,cachedSha;UINT cachedId=0,cachedSeed=0;
            metadata>>format>>cachedId>>cachedSeed>>cachedSha>>result.vertexStrideBytes>>result.vertexCount>>result.motionFrames>>result.motionDuration;
            for(float& value:result.boundsMin)metadata>>value;for(float& value:result.boundsMax)metadata>>value;
            if(!metadata||format!="ALPINE_NEURAL_QA_CACHE_1"||cachedId!=id||cachedSeed!=avatarSeed||cachedSha!=modelSha||result.vertexStrideBytes!=expectedStride
                ||!result.vertexCount||uint64_t(result.vertexCount)*expectedStride>=400000000||result.motionFrames>100000)
                throw std::runtime_error("Missing, stale or invalid QA-only generated geometry cache.");
            auto uploadCached=[&](const std::string& suffix,size_t count,ComPtr<ID3D11Buffer>& buffer,ComPtr<ID3D11ShaderResourceView>& srv){
                const fs::path cachePath=base.string()+suffix;
                if(fs::file_size(cachePath)!=count)throw std::runtime_error("QA cache length mismatch.");
                std::ifstream file(cachePath,std::ios::binary);std::vector<uint8_t> data(count);file.read(reinterpret_cast<char*>(data.data()),count);
                if(!file)throw std::runtime_error("QA cache read failed.");
                D3D11_BUFFER_DESC desc{};desc.ByteWidth=UINT(count);desc.Usage=D3D11_USAGE_IMMUTABLE;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
                desc.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;desc.StructureByteStride=16;
                D3D11_SUBRESOURCE_DATA initial{};initial.pSysMem=data.data();check(device->CreateBuffer(&desc,&initial,&buffer),"Upload QA-only cached geometry");
                D3D11_SHADER_RESOURCE_VIEW_DESC view{};view.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;view.Buffer.NumElements=UINT(count/16);
                check(device->CreateShaderResourceView(buffer.Get(),&view,&srv),"Create QA-only cache view");
            };
            uploadCached(".vertices",size_t(result.vertexCount)*expectedStride,product.vertices,product.srv);
            if(isHead)uploadCached(".motion",size_t(result.motionFrames)*32,product.motion,product.motionSRV);
            result.vertexBuffer=product.vertices.Get();result.vertexSRV=product.srv.Get();result.motionBuffer=product.motion.Get();result.motionSRV=product.motionSRV.Get();
            result.status=1;result.seed=avatarSeed;success=1;
        } else {
            success=NeuralAvatarCreate(device.Get(),context.Get(),model.data(),UINT(model.size()),
                avatarShader.data(),UINT(avatarShader.size()),avatarSeed,&result,nullptr);
            product.vertices.Attach(result.vertexBuffer);product.srv.Attach(result.vertexSRV);
            product.motion.Attach(result.motionBuffer);product.motionSRV.Attach(result.motionSRV);
        }
        NeuralAvatarSetDiagnosticSink(nullptr);
        const double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
        if(!success||!product.vertices||!product.srv||!result.vertexCount||result.vertexCount%3||result.vertexStrideBytes!=expectedStride)
            throw std::runtime_error("Neural generation failed, resource="+std::to_string(id)+",status="+std::to_string(result.status));
        if(neuralDumpFailed)throw std::runtime_error("Cannot write neural diagnostic dump.");
        context->ClearState();
        auto readBuffer=[&](ID3D11Buffer* buffer,size_t expected){
            D3D11_BUFFER_DESC desc{};buffer->GetDesc(&desc);
            if(expected>desc.ByteWidth)throw std::runtime_error("Neural result exceeds its buffer.");
            desc.BindFlags=desc.MiscFlags=desc.StructureByteStride=0;
            desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            ComPtr<ID3D11Buffer> staging;check(device->CreateBuffer(&desc,nullptr,&staging),"Create neural readback");
            context->CopyResource(staging.Get(),buffer);D3D11_MAPPED_SUBRESOURCE map{};
            check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&map),"Read neural data");
            std::vector<uint8_t> bytes(expected);memcpy(bytes.data(),map.pData,expected);
            context->Unmap(staging.Get(),0);return bytes;
        };
        const auto vertices=readBuffer(product.vertices.Get(),size_t(result.vertexCount)*expectedStride);
        size_t invalidValues=0,invalidJoints=0,invalidColor=0,invalidMorph=0;
        std::array<uint64_t,24> jointUse{};
        double weightSumError=0,minNormalLength=1e30,maxNormalLength=0,maxMorph=0;
        std::array<float,3> lo={1e30f,1e30f,1e30f},hi={-1e30f,-1e30f,-1e30f};
        uint64_t geometryHash=14695981039346656037ULL;
        for(auto byte:vertices)geometryHash=(geometryHash^byte)*1099511628211ULL;
        for(UINT i=0;i<result.vertexCount;++i) {
            const auto* v=reinterpret_cast<const float*>(vertices.data()+size_t(i)*expectedStride);
            const auto* joints=reinterpret_cast<const uint32_t*>(v+8);
            for(unsigned j=0;j<8;++j)invalidValues+=!std::isfinite(v[j]);
            double totalWeight=0;
            for(unsigned j=0;j<4;++j){invalidJoints+=joints[j]>=jointCount;invalidValues+=!std::isfinite(v[12+j])||v[12+j]<0;totalWeight+=v[12+j];
                if(joints[j]<jointCount&&v[12+j]>1e-4f)jointUse[joints[j]]++;}
            weightSumError=std::max(weightSumError,std::abs(totalWeight-1));
            const double length=std::sqrt(double(v[4])*v[4]+double(v[5])*v[5]+double(v[6])*v[6]);
            minNormalLength=std::min(minNormalLength,length);maxNormalLength=std::max(maxNormalLength,length);
            for(unsigned j=0;j<3;++j){lo[j]=std::min(lo[j],v[j]);hi[j]=std::max(hi[j],v[j]);}
            if(isHead) {
                for(unsigned j=16;j<20;++j)invalidColor+=!std::isfinite(v[j])||v[j]<0||v[j]>1;
                for(unsigned j=20;j<36;++j){invalidMorph+=!std::isfinite(v[j]);maxMorph=std::max(maxMorph,std::abs(double(v[j])));}
            }
        }
        const size_t activeJoints=std::count_if(jointUse.begin(),jointUse.end(),[](uint64_t count){return count!=0;});
        std::vector<uint8_t> motionBytes;
        size_t invalidMotion=0;double motionDifference=0;
        if(isHead) {
            if(!product.motion||!product.motionSRV||result.motionFrames<2||!std::isfinite(result.motionDuration)||result.motionDuration<=0)
                throw std::runtime_error("GANHead has no valid expression motion.");
            motionBytes=readBuffer(product.motion.Get(),size_t(result.motionFrames)*32);
            const float* values=reinterpret_cast<const float*>(motionBytes.data());
            for(size_t i=0;i<motionBytes.size()/4;++i){invalidMotion+=!std::isfinite(values[i]);if(i>=8)motionDifference=std::max(motionDifference,std::abs(double(values[i])-values[i%8]));}
        }
        std::ostringstream description;
        description<<"{\"model\":\""<<(isHead?"GANHead FaceVerse":"gDNA THuman2.0")<<"\",\"model_resource_id\":"<<id<<",\"model_bytes\":"<<model.size()
            <<",\"model_sha256\":\""<<modelSha<<"\",\"candidate_sha256\":\""<<candidateSha256<<"\""
            <<",\"source_kind\":\""<<(cached?"qa_generated_cache":module.value?"candidate_resources":"development_files")<<"\",\"inference_executed\":"<<(cached?"false":"true")
            <<",\"seed\":"<<avatarSeed<<",\"vertex_count\":"<<result.vertexCount<<",\"vertex_stride_bytes\":"<<expectedStride<<",\"status\":"<<result.status
            <<",\"startup_wall_seconds\":"<<seconds<<",\"helper_seconds\":"<<result.seconds
            <<",\"feature_ms\":"<<result.reserved[0]<<",\"field_ms\":"<<result.reserved[1]
            <<",\"geometry_fnv1a64\":\""<<std::hex<<geometryHash<<std::dec<<"\",\"invalid_values\":"<<invalidValues
            <<",\"invalid_joint_ids\":"<<invalidJoints<<",\"max_weight_sum_error\":"<<weightSumError
            <<",\"normal_length_min\":"<<minNormalLength<<",\"normal_length_max\":"<<maxNormalLength
            <<",\"active_joint_count\":"<<activeJoints<<",\"joint_influence_counts\":[";
        for(UINT joint=0;joint<jointCount;++joint)description<<(joint?",":"")<<jointUse[joint];
        description<<"],\"bounds_min\":["<<lo[0]<<","<<lo[1]<<","<<lo[2]<<"],\"bounds_max\":["<<hi[0]<<","<<hi[1]<<","<<hi[2]<<"]"
            <<",\"invalid_color_values\":"<<invalidColor<<",\"invalid_morph_values\":"<<invalidMorph<<",\"max_abs_morph_delta\":"<<maxMorph
            <<",\"motion_frames\":"<<result.motionFrames<<",\"motion_duration_seconds\":"<<result.motionDuration
            <<",\"invalid_motion_values\":"<<invalidMotion<<",\"motion_max_difference_from_first\":"<<motionDifference<<"}";
        product.json=description.str();
        std::ofstream(outDir/(isHead?"neural_head_metrics.json":"neural_avatar_metrics.json"))<<product.json<<"\n";
        if(isHead&&dumpNeural)std::ofstream(dumpDirectory/"neural_avatar_metrics.json")<<product.json<<"\n";
        if(invalidValues||invalidJoints||activeJoints<(isHead?1u:8u)||weightSumError>.005||minNormalLength<.5||maxNormalLength>1.5
            ||invalidColor||invalidMorph||invalidMotion||(isHead&&(maxMorph<=1e-7||motionDifference<=1e-7)))
            throw std::runtime_error("Neural vertex/material/motion validation failed; resource="+std::to_string(id));
        if(!writeNeuralCache.empty()) {
            fs::create_directories(writeNeuralCache);
            const fs::path base=writeNeuralCache/std::to_string(id);
            std::ofstream mesh(base.string()+".vertices",std::ios::binary);mesh.write(reinterpret_cast<const char*>(vertices.data()),vertices.size());
            std::ofstream motion(base.string()+".motion",std::ios::binary);if(!motionBytes.empty())motion.write(reinterpret_cast<const char*>(motionBytes.data()),motionBytes.size());
            std::ofstream metadata(base.string()+".meta");metadata<<std::setprecision(9)<<"ALPINE_NEURAL_QA_CACHE_1\n"<<id<<" "<<avatarSeed<<" "<<modelSha<<"\n"
                <<expectedStride<<" "<<result.vertexCount<<" "<<result.motionFrames<<" "<<result.motionDuration<<"\n";
            for(float value:result.boundsMin)metadata<<value<<" ";for(float value:result.boundsMax)metadata<<value<<" ";metadata<<"\n";
            if(!mesh||!motion||!metadata)throw std::runtime_error("Cannot write QA-only generated geometry cache.");
        }
        std::cout<<"Neural "<<(isHead?"head":"body")<<": "<<result.vertexCount<<" vertices in "<<seconds<<" s"<<std::endl;
        return product;
    };
    NeuralProduct body,head;
    if(!headOnly)body=generateNeural(false);
    if(!neuralOnly||headOnly)head=generateNeural(true);
    auto& avatar=body.result;
    const std::string neuralJson=body.json,headJson=head.json;
    if(neuralOnly) {
        UINT64 messages=info?info->GetNumStoredMessages():0;size_t warnings=0;
        for(UINT64 i=0;i<messages;++i){SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> data(size);
            auto* message=reinterpret_cast<D3D11_MESSAGE*>(data.data());check(info->GetMessage(i,message,&size),"Read neural diagnostics");
            if(message->Severity<=D3D11_MESSAGE_SEVERITY_WARNING){warnings++;std::cerr<<message->pDescription<<"\n";}}
        std::ofstream(outDir/"neural_debug.json")<<"{\"debug_layer\":"<<(debug?"true":"false")<<",\"warnings_errors\":"<<warnings<<"}\n";
        return warnings?2:0;
    }
    ID3D11ShaderResourceView* neuralViews[]={body.srv.Get(),head.srv.Get(),head.motionSRV.Get()};
    context->VSSetShaderResources(16,3,neuralViews);
    auto vb=shaderBytes(101,"scene_vs.cso");ComPtr<ID3D11VertexShader> vs;check(device->CreateVertexShader(vb.data(),vb.size(),nullptr,&vs),"CreateVS");
    std::array<ComPtr<ID3D11PixelShader>,4> ps;
    const char* files[]={"scene_ps.cso","human_ps.cso","temporal_ps.cso","display_ps.cso"};
    for(int i=0;i<4;i++){auto data=shaderBytes(102+i,files[i]);check(device->CreatePixelShader(data.data(),data.size(),nullptr,&ps[i]),files[i]);}
    ComPtr<ID3D11VertexShader> meshVS,shadowVS;
    ComPtr<ID3D11PixelShader> meshPS,shadowPS;
    ComPtr<ID3D11ComputeShader> cameraCS,terrainCS,flightCS,waterCS,materialCS,atmosphereCS,instancesCS,cloudCS,boundsCS;
    auto meshVB=shaderBytes(106,"mesh_vs.cso");check(device->CreateVertexShader(meshVB.data(),meshVB.size(),nullptr,&meshVS),"Create mesh VS");
    auto meshPB=shaderBytes(107,"mesh_ps.cso");check(device->CreatePixelShader(meshPB.data(),meshPB.size(),nullptr,&meshPS),"Create mesh PS");
    auto shadowVB=shaderBytes(108,"shadow_vs.cso");check(device->CreateVertexShader(shadowVB.data(),shadowVB.size(),nullptr,&shadowVS),"Create shadow VS");
    auto shadowPB=shaderBytes(109,"shadow_ps.cso");check(device->CreatePixelShader(shadowPB.data(),shadowPB.size(),nullptr,&shadowPS),"Create shadow PS");
    auto cameraCB=shaderBytes(110,"camera_cs.cso");check(device->CreateComputeShader(cameraCB.data(),cameraCB.size(),nullptr,&cameraCS),"Create camera CS");
    auto terrainCB=shaderBytes(111,"terrain_cs.cso");check(device->CreateComputeShader(terrainCB.data(),terrainCB.size(),nullptr,&terrainCS),"Create terrain CS");
    auto flightCode=shaderBytes(112,"flight_cs.cso");check(device->CreateComputeShader(flightCode.data(),flightCode.size(),nullptr,&flightCS),"Create flight physics CS");
    auto waterCode=shaderBytes(113,"water_cs.cso");check(device->CreateComputeShader(waterCode.data(),waterCode.size(),nullptr,&waterCS),"Create water physics CS");
    auto materialCode=shaderBytes(114,"material_cs.cso");check(device->CreateComputeShader(materialCode.data(),materialCode.size(),nullptr,&materialCS),"Create material CS");
    auto atmosphereCode=shaderBytes(115,"atmosphere_cs.cso");check(device->CreateComputeShader(atmosphereCode.data(),atmosphereCode.size(),nullptr,&atmosphereCS),"Create atmosphere CS");
    auto instanceCode=shaderBytes(116,"instances_cs.cso");check(device->CreateComputeShader(instanceCode.data(),instanceCode.size(),nullptr,&instancesCS),"Create instance CS");
    auto cloudCode=shaderBytes(117,"cloud_cs.cso");check(device->CreateComputeShader(cloudCode.data(),cloudCode.size(),nullptr,&cloudCS),"Create cloud CS");
    auto boundsCode=shaderBytes(118,"terrain_bounds_cs.cso");check(device->CreateComputeShader(boundsCode.data(),boundsCode.size(),nullptr,&boundsCS),"Create bounds CS");
    auto cloudPostCode=shaderBytes(119,"cloud_composite_ps.cso");ComPtr<ID3D11PixelShader> cloudCompositePS;check(device->CreatePixelShader(cloudPostCode.data(),cloudPostCode.size(),nullptr,&cloudCompositePS),"Create cloud composite PS");
    Surface low(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT), humans(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface clouded(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface worldSnapshot(device.Get(),lowWidth,lowHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface shadow(device.Get(),2048,2048,DXGI_FORMAT_R32_FLOAT);
    Surface farShadow(device.Get(),1024,1024,DXGI_FORMAT_R32_FLOAT);
    DepthSurface mainDepth(device.Get(),lowWidth,lowHeight),shadowDepth(device.Get(),2048,2048);
    DepthSurface farShadowDepth(device.Get(),1024,1024);
    MaterialSurface materialColor(device.Get()),materialNormal(device.Get());
    CloudVolume cloud(device.Get());TerrainBoundsSurface terrainBounds(device.Get());
    D3D11_TEXTURE2D_DESC atmosphereDesc{};atmosphereDesc.Width=256;atmosphereDesc.Height=128;atmosphereDesc.MipLevels=atmosphereDesc.ArraySize=1;
    atmosphereDesc.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;atmosphereDesc.SampleDesc.Count=1;
    atmosphereDesc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    ComPtr<ID3D11Texture2D> atmosphereTexture,atmosphereStaging;
    ComPtr<ID3D11ShaderResourceView> atmosphereSRV;ComPtr<ID3D11UnorderedAccessView> atmosphereUAV;
    check(device->CreateTexture2D(&atmosphereDesc,nullptr,&atmosphereTexture),"Create atmosphere LUT");
    check(device->CreateShaderResourceView(atmosphereTexture.Get(),nullptr,&atmosphereSRV),"Create atmosphere SRV");
    check(device->CreateUnorderedAccessView(atmosphereTexture.Get(),nullptr,&atmosphereUAV),"Create atmosphere UAV");
    atmosphereDesc.BindFlags=0;atmosphereDesc.Usage=D3D11_USAGE_STAGING;atmosphereDesc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateTexture2D(&atmosphereDesc,nullptr,&atmosphereStaging),"Create atmosphere staging");
    const UINT reflectionWidth=std::max(1u,lowWidth/2),reflectionHeight=std::max(1u,lowHeight/2);
    Surface reflection(device.Get(),reflectionWidth,reflectionHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    Surface reflectionClouded(device.Get(),reflectionWidth,reflectionHeight,DXGI_FORMAT_R16G16B16A16_FLOAT);
    DepthSurface reflectionDepth(device.Get(),reflectionWidth,reflectionHeight);
    Surface histories[]={Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT),Surface(device.Get(),w,h,DXGI_FORMAT_R16G16B16A16_FLOAT)};
    Surface output(device.Get(),w,h,DXGI_FORMAT_R8G8B8A8_UNORM);
    const float zero[4]={};for(auto& s:histories)context->ClearRenderTargetView(s.rtv.Get(),zero);
    D3D11_BUFFER_DESC bd{};bd.ByteWidth=32;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> cb;check(device->CreateBuffer(&bd,nullptr,&cb),"CreateCB");
    bd.ByteWidth=16;ComPtr<ID3D11Buffer> batchCB;check(device->CreateBuffer(&bd,nullptr,&batchCB),"Create batch CB");
    ComPtr<ID3D11Buffer> passCB;check(device->CreateBuffer(&bd,nullptr,&passCB),"Create pass CB");
    ComPtr<ID3D11Buffer> physicsCB;check(device->CreateBuffer(&bd,nullptr,&physicsCB),"Create physics CB");
    bd.ByteWidth=CameraFloats*4;bd.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;
    bd.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;bd.StructureByteStride=16;
    ComPtr<ID3D11Buffer> cameraBuffer,cameraStaging;check(device->CreateBuffer(&bd,nullptr,&cameraBuffer),"Create camera cache");
    D3D11_SHADER_RESOURCE_VIEW_DESC csrv{};csrv.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;csrv.Buffer.NumElements=CameraFloats/4;
    ComPtr<ID3D11ShaderResourceView> cameraSRV;check(device->CreateShaderResourceView(cameraBuffer.Get(),&csrv,&cameraSRV),"Create camera SRV");
    D3D11_UNORDERED_ACCESS_VIEW_DESC cuav{};cuav.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;cuav.Buffer.NumElements=CameraFloats/4;
    ComPtr<ID3D11UnorderedAccessView> cameraUAV;check(device->CreateUnorderedAccessView(cameraBuffer.Get(),&cuav,&cameraUAV),"Create camera UAV");
    bd.BindFlags=0;bd.MiscFlags=0;bd.StructureByteStride=0;bd.Usage=D3D11_USAGE_STAGING;bd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateBuffer(&bd,nullptr,&cameraStaging),"Create camera staging");
    bd.ByteWidth=InstanceElements*16;bd.Usage=D3D11_USAGE_DEFAULT;bd.CPUAccessFlags=0;
    bd.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;bd.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;bd.StructureByteStride=16;
    // A poison fill makes incomplete compute writes observable on the first
    // frame; the native runtime does not upload an instance buffer.
    std::vector<float> instancePoison(size_t(InstanceElements)*4,NAN);D3D11_SUBRESOURCE_DATA instanceInitial{instancePoison.data(),0,0};
    ComPtr<ID3D11Buffer> instanceBuffer,instanceStaging;check(device->CreateBuffer(&bd,&instanceInitial,&instanceBuffer),"Create instance cache");
    csrv.Buffer.NumElements=InstanceElements;cuav.Buffer.NumElements=InstanceElements;
    ComPtr<ID3D11ShaderResourceView> instanceSRV;ComPtr<ID3D11UnorderedAccessView> instanceUAV;
    check(device->CreateShaderResourceView(instanceBuffer.Get(),&csrv,&instanceSRV),"Create instance SRV");
    check(device->CreateUnorderedAccessView(instanceBuffer.Get(),&cuav,&instanceUAV),"Create instance UAV");
    bd.BindFlags=0;bd.MiscFlags=0;bd.StructureByteStride=0;bd.Usage=D3D11_USAGE_STAGING;bd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateBuffer(&bd,nullptr,&instanceStaging),"Create instance staging");
    bd.ByteWidth=FlightElements*16;bd.Usage=D3D11_USAGE_DEFAULT;bd.CPUAccessFlags=0;
    bd.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS;bd.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;bd.StructureByteStride=16;
    ComPtr<ID3D11Buffer> flightBuffer,flightStaging;check(device->CreateBuffer(&bd,nullptr,&flightBuffer),"Create flight trajectory");
    csrv.Buffer.NumElements=FlightElements;cuav.Buffer.NumElements=FlightElements;
    ComPtr<ID3D11ShaderResourceView> flightSRV;ComPtr<ID3D11UnorderedAccessView> flightUAV;
    check(device->CreateShaderResourceView(flightBuffer.Get(),&csrv,&flightSRV),"Create flight SRV");
    check(device->CreateUnorderedAccessView(flightBuffer.Get(),&cuav,&flightUAV),"Create flight UAV");
    bd.BindFlags=0;bd.MiscFlags=0;bd.StructureByteStride=0;bd.Usage=D3D11_USAGE_STAGING;bd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    check(device->CreateBuffer(&bd,nullptr,&flightStaging),"Create flight readback");
    ComputeSurface waters[]={ComputeSurface(device.Get()),ComputeSurface(device.Get())};
    D3D11_TEXTURE2D_DESC td{};td.Width=td.Height=TerrainSize;td.MipLevels=td.ArraySize=1;td.Format=DXGI_FORMAT_R32_FLOAT;
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
    dd.DepthEnable=FALSE;dd.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ZERO;dd.DepthFunc=D3D11_COMPARISON_ALWAYS;
    ComPtr<ID3D11DepthStencilState> postDepth;check(device->CreateDepthStencilState(&dd,&postDepth),"Create post depth state");
    D3D11_SAMPLER_DESC sd{};sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc=D3D11_COMPARISON_NEVER;sd.MaxAnisotropy=1;sd.MaxLOD=D3D11_FLOAT32_MAX;
    ComPtr<ID3D11SamplerState> sampler;check(device->CreateSamplerState(&sd,&sampler),"CreateSampler");
    sd.Filter=D3D11_FILTER_ANISOTROPIC;sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_WRAP;sd.MaxAnisotropy=8;
    ComPtr<ID3D11SamplerState> materialSampler;check(device->CreateSamplerState(&sd,&materialSampler),"Create material sampler");
    context->VSSetShader(vs.Get(),nullptr,0);context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetConstantBuffers(0,1,cb.GetAddressOf());
    context->VSSetConstantBuffers(1,1,batchCB.GetAddressOf());
    context->VSSetConstantBuffers(2,1,passCB.GetAddressOf());context->PSSetConstantBuffers(2,1,passCB.GetAddressOf());
    const float defaultPass[4]={};context->UpdateSubresource(passCB.Get(),0,nullptr,defaultPass,0,0);
    context->PSSetConstantBuffers(0,1,cb.GetAddressOf());context->PSSetSamplers(0,1,sampler.GetAddressOf());
    context->CSSetConstantBuffers(0,1,cb.GetAddressOf());context->RSSetState(rasterizer.Get());
    context->CSSetConstantBuffers(3,1,physicsCB.GetAddressOf());context->VSSetConstantBuffers(3,1,physicsCB.GetAddressOf());context->PSSetConstantBuffers(3,1,physicsCB.GetAddressOf());
    const float initialPhysics[4]={1.f/60,0,0,0};context->UpdateSubresource(physicsCB.Get(),0,nullptr,initialPhysics,0,0);
    context->VSSetSamplers(1,1,sampler.GetAddressOf());context->PSSetSamplers(1,1,sampler.GetAddressOf());context->CSSetSamplers(1,1,sampler.GetAddressOf());
    context->VSSetSamplers(2,1,materialSampler.GetAddressOf());context->PSSetSamplers(2,1,materialSampler.GetAddressOf());
    const float initialConstants[]={float(lowWidth),float(lowHeight),time,0,float(w),float(h),seed,time};
    context->UpdateSubresource(cb.Get(),0,nullptr,initialConstants,0,0);
    D3D11_QUERY_DESC terrainQD{D3D11_QUERY_TIMESTAMP_DISJOINT,0};ComPtr<ID3D11Query> terrainDisjoint;
    check(device->CreateQuery(&terrainQD,&terrainDisjoint),"Create terrain disjoint");terrainQD.Query=D3D11_QUERY_TIMESTAMP;
    ComPtr<ID3D11Query> terrainStart,terrainEnd;check(device->CreateQuery(&terrainQD,&terrainStart),"Create terrain start");check(device->CreateQuery(&terrainQD,&terrainEnd),"Create terrain end");
    ID3D11UnorderedAccessView* nullUAV=nullptr;
    ID3D11UnorderedAccessView* materialUAVs[]={materialColor.uav.Get(),materialNormal.uav.Get()},*nullUAVs[2]={};
    context->CSSetShader(materialCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,2,materialUAVs,nullptr);
    context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Dispatch(MaterialSize/8,MaterialSize/8,MaterialLayers);
    context->CSSetUnorderedAccessViews(0,2,nullUAVs,nullptr);context->GenerateMips(materialColor.srv.Get());context->GenerateMips(materialNormal.srv.Get());
    context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    const auto materialTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 materialT0=query<UINT64>(context.Get(),terrainStart.Get()),materialT1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(materialTiming.Disjoint||!materialTiming.Frequency)throw std::runtime_error("Material startup timing is disjoint.");
    const double materialMS=1000.0*double(materialT1-materialT0)/materialTiming.Frequency;
    ID3D11ShaderResourceView* materialSRVs[]={materialColor.srv.Get(),materialNormal.srv.Get()};
    context->VSSetShaderResources(8,2,materialSRVs);context->PSSetShaderResources(8,2,materialSRVs);
    std::ofstream materialReport(outDir/"material_metrics.json");materialReport<<"{\"startup_gpu_ms\":"<<materialMS<<",\"width\":1024,\"mips\":11,\"layers\":[";
    for(UINT layer=0;layer<MaterialLayers;layer++) {
        auto color=materialColor.pixels(device.Get(),context.Get(),layer,0),normal=materialNormal.pixels(device.Get(),context.Get(),layer,0);
        auto coarse=materialColor.pixels(device.Get(),context.Get(),layer,MaterialMips-1);
        uint8_t lowByte=255,highByte=0;double sum=0,square=0;size_t invalidNormals=0;
        for(size_t i=0;i<color.size();i+=4) {
            for(size_t channel=0;channel<3;channel++){uint8_t value=color[i+channel];lowByte=std::min(lowByte,value);highByte=std::max(highByte,value);sum+=value;square+=double(value)*value;}
            float x=normal[i]/127.5f-1.f,y=normal[i+1]/127.5f-1.f,z=normal[i+2]/127.5f-1.f;
            float length=std::sqrt(x*x+y*y+z*z);invalidNormals+=length<.90f||length>1.1f;
        }
        double samples=double(color.size()/4)*3,variance=square/samples-std::pow(sum/samples,2);
        if(invalidNormals||highByte==0)throw std::runtime_error("Invalid procedural material output.");
        std::ostringstream name;name<<"material_color_"<<layer<<".bmp";bmp(outDir/name.str(),color,MaterialSize,MaterialSize);
        materialReport<<(layer?",":"")<<"{\"layer\":"<<layer<<",\"min_byte\":"<<unsigned(lowByte)<<",\"max_byte\":"<<unsigned(highByte)<<",\"variance\":"<<variance<<",\"invalid_normals\":"<<invalidNormals
            <<",\"last_mip_rgba\":["<<unsigned(coarse[0])<<","<<unsigned(coarse[1])<<","<<unsigned(coarse[2])<<","<<unsigned(coarse[3])<<"]}";
    }
    materialReport<<"]}\n";
    context->CSSetShader(terrainCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,terrainUAV.GetAddressOf(),nullptr);
    context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Dispatch(TerrainSize/8,TerrainSize/8,1);context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
    context->VSSetShaderResources(4,1,terrainSRV.GetAddressOf());context->PSSetShaderResources(4,1,terrainSRV.GetAddressOf());context->CSSetShaderResources(4,1,terrainSRV.GetAddressOf());
    context->CopyResource(terrainStaging.Get(),terrainTexture.Get());D3D11_MAPPED_SUBRESOURCE terrainMap{};
    check(context->Map(terrainStaging.Get(),0,D3D11_MAP_READ,0,&terrainMap),"Map terrain cache");
    std::vector<uint8_t> terrainValues(size_t(TerrainSize)*TerrainSize*4);
    for(UINT row=0;row<TerrainSize;row++)memcpy(terrainValues.data()+size_t(row)*TerrainSize*4,static_cast<uint8_t*>(terrainMap.pData)+size_t(row)*terrainMap.RowPitch,TerrainSize*4);
    context->Unmap(terrainStaging.Get(),0);const auto terrainMetrics=scalarMetrics(terrainValues,false);
    if(terrainMetrics.invalid)throw std::runtime_error("Terrain cache contains nonfinite values.");
    const auto terrainTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 terrainTicks0=query<UINT64>(context.Get(),terrainStart.Get()),terrainTicks1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(terrainTiming.Disjoint||!terrainTiming.Frequency)throw std::runtime_error("Terrain startup GPU timing is disjoint.");
    const double terrainMS=1000.0*double(terrainTicks1-terrainTicks0)/terrainTiming.Frequency;
    std::ofstream(outDir/"terrain_metrics.json")<<"{\"heightfield\":"<<json(terrainMetrics)<<",\"startup_gpu_ms\":"<<terrainMS<<"}\n";
    context->CSSetShader(boundsCS.Get(),nullptr,0);context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());
    for(UINT level=0;level<BoundsMips;level++) {
        const float boundsParameters[4]={0,0,float(level),0};context->UpdateSubresource(physicsCB.Get(),0,nullptr,boundsParameters,0,0);
        ID3D11ShaderResourceView* previousLevel=level?terrainBounds.levels[level-1].Get():nullptr;
        context->CSSetShaderResources(14,1,&previousLevel);context->CSSetUnorderedAccessViews(0,1,terrainBounds.uavs[level].GetAddressOf(),nullptr);
        const UINT groups=((TerrainSize>>level)+7)/8;context->Dispatch(groups,groups,1);context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
    }
    ID3D11ShaderResourceView* nullBounds=nullptr;context->CSSetShaderResources(14,1,&nullBounds);
    context->VSSetShaderResources(14,1,terrainBounds.srv.GetAddressOf());context->PSSetShaderResources(14,1,terrainBounds.srv.GetAddressOf());
    context->UpdateSubresource(physicsCB.Get(),0,nullptr,initialPhysics,0,0);context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    const auto boundsTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 boundsT0=query<UINT64>(context.Get(),terrainStart.Get()),boundsT1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(boundsTiming.Disjoint||!boundsTiming.Frequency)throw std::runtime_error("Terrain bounds timing is disjoint.");
    const double boundsMS=1000.0*double(boundsT1-boundsT0)/boundsTiming.Frequency;
    std::ofstream boundsReport(outDir/"terrain_bounds_metrics.json");boundsReport<<"{\"startup_gpu_ms\":"<<boundsMS<<",\"levels\":[";
    std::vector<float> previousBounds;size_t boundsFailures=0;
    for(UINT level=0;level<BoundsMips;level++) {
        auto values=terrainBounds.values(device.Get(),context.Get(),level);const UINT size=TerrainSize>>level,sourceSize=level?size*2:TerrainSize;
        const float* source=level?previousBounds.data():reinterpret_cast<const float*>(terrainValues.data());
        size_t invalid=0,nonconservative=0;float minimum=INFINITY,maximum=-INFINITY;
        for(UINT y=0;y<size;y++)for(UINT x=0;x<size;x++) {
            const UINT px=level?x*2:x,py=level?y*2:y,qx=std::min(px+1,sourceSize-1),qy=std::min(py+1,sourceSize-1);
            const float required=std::max(std::max(source[size_t(py)*sourceSize+px],source[size_t(py)*sourceSize+qx]),std::max(source[size_t(qy)*sourceSize+px],source[size_t(qy)*sourceSize+qx]));
            float value=values[size_t(y)*size+x];invalid+=!std::isfinite(value);nonconservative+=value<required;
            minimum=std::min(minimum,value);maximum=std::max(maximum,value);
        }
        boundsFailures+=invalid+nonconservative;
        boundsReport<<(level?",":"")<<"{\"level\":"<<level<<",\"size\":"<<size<<",\"nonfinite\":"<<invalid<<",\"nonconservative\":"<<nonconservative<<",\"minimum\":"<<minimum<<",\"maximum\":"<<maximum<<"}";
        previousBounds=std::move(values);
    }
    boundsReport<<"]}\n";if(boundsFailures||previousBounds[0]<terrainMetrics.maximum||previousBounds[0]>terrainMetrics.maximum+.1)throw std::runtime_error("Terrain hierarchy is not a conservative finite bound.");
    context->CSSetShader(cloudCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,cloud.uav.GetAddressOf(),nullptr);
    context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Dispatch(16,16,16);
    context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);context->PSSetShaderResources(13,1,cloud.srv.GetAddressOf());
    context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    const auto cloudTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 cloudT0=query<UINT64>(context.Get(),terrainStart.Get()),cloudT1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(cloudTiming.Disjoint||!cloudTiming.Frequency)throw std::runtime_error("Cloud startup timing is disjoint.");
    const double cloudMS=1000.0*double(cloudT1-cloudT0)/cloudTiming.Frequency;
    auto cloudPixels=cloud.pixels(context.Get());std::ofstream cloudReport(outDir/"cloud_metrics.json");cloudReport<<"{\"startup_gpu_ms\":"<<cloudMS<<",\"size\":128,\"channels\":[";
    for(UINT channel=0;channel<4;channel++) {
        uint8_t minimum=255,maximum=0;double sum=0;
        for(size_t p=channel;p<cloudPixels.size();p+=4){minimum=std::min(minimum,cloudPixels[p]);maximum=std::max(maximum,cloudPixels[p]);sum+=cloudPixels[p];}
        if(minimum==maximum)throw std::runtime_error("Cloud volume channel is constant/uninitialized.");
        cloudReport<<(channel?",":"")<<"{\"min_byte\":"<<unsigned(minimum)<<",\"max_byte\":"<<unsigned(maximum)<<",\"mean_byte\":"<<sum/(CloudSize*CloudSize*CloudSize)<<"}";
    }
    cloudReport<<"]}\n";const size_t cloudSliceBytes=CloudSize*CloudSize*4;
    std::vector<uint8_t> cloudSlice(cloudPixels.begin()+cloudSliceBytes*(CloudSize/2),cloudPixels.begin()+cloudSliceBytes*(CloudSize/2+1));bmp(outDir/"cloud_volume_slice.bmp",cloudSlice,CloudSize,CloudSize);
    context->CSSetShader(flightCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,flightUAV.GetAddressOf(),nullptr);
    context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Dispatch(1,1,1);context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
    context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
    context->VSSetShaderResources(6,1,flightSRV.GetAddressOf());context->PSSetShaderResources(6,1,flightSRV.GetAddressOf());context->CSSetShaderResources(6,1,flightSRV.GetAddressOf());
    context->CopyResource(flightStaging.Get(),flightBuffer.Get());D3D11_MAPPED_SUBRESOURCE flightMap{};
    check(context->Map(flightStaging.Get(),0,D3D11_MAP_READ,0,&flightMap),"Map flight trajectory");
    std::vector<float> flightValues(size_t(FlightElements)*4);memcpy(flightValues.data(),flightMap.pData,flightValues.size()*4);context->Unmap(flightStaging.Get(),0);
    const auto flightTiming=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());
    const UINT64 flightTicks0=query<UINT64>(context.Get(),terrainStart.Get()),flightTicks1=query<UINT64>(context.Get(),terrainEnd.Get());
    if(flightTiming.Disjoint||!flightTiming.Frequency)throw std::runtime_error("Flight startup timing invalid.");
    const double flightMS=1000.0*double(flightTicks1-flightTicks0)/flightTiming.Frequency;
    size_t flightInvalid=0;double flightMinClearance=1e30,flightMinSpeed=1e30,flightMaxSpeed=0,flightMaxBank=0,flightMinCl=1e30,flightMaxCl=-1e30;
    std::ofstream flightCSV(outDir/"flight.csv");flightCSV<<"id,time,x,y,z,bank,vx,vy,vz,airspeed,fx,fy,fz,Cl,ux,uy,uz,clearance\n";
    for(UINT id=0;id<4;id++)for(UINT sample=0;sample<FlightSamples;sample++) {
        const float* v=flightValues.data()+(id*FlightSamples+sample)*16;
        for(UINT k=0;k<16;k++)flightInvalid+=!std::isfinite(v[k]);
        flightMinClearance=std::min(flightMinClearance,double(v[15]));flightMinSpeed=std::min(flightMinSpeed,double(v[7]));
        flightMaxSpeed=std::max(flightMaxSpeed,double(v[7]));flightMaxBank=std::max(flightMaxBank,std::abs(double(v[3])));
        flightMinCl=std::min(flightMinCl,double(v[11]));flightMaxCl=std::max(flightMaxCl,double(v[11]));
        flightCSV<<id<<","<<sample/30.0;for(UINT k=0;k<16;k++)flightCSV<<","<<v[k];flightCSV<<"\n";
    }
    flightCSV.close();std::ofstream flightSummary(outDir/"flight_metrics.json");
    flightSummary<<"{\"samples\":"<<4*FlightSamples<<",\"fixed_step_seconds\":"<<1.0/120<<",\"storage_hz\":30,\"startup_gpu_ms\":"<<flightMS
        <<",\"nonfinite_values\":"<<flightInvalid<<",\"min_clearance_m\":"<<flightMinClearance<<",\"min_airspeed_m_s\":"<<flightMinSpeed
        <<",\"max_airspeed_m_s\":"<<flightMaxSpeed<<",\"max_abs_bank_rad\":"<<flightMaxBank<<",\"min_lift_coefficient\":"<<flightMinCl<<",\"max_lift_coefficient\":"<<flightMaxCl<<"}\n";
    flightSummary.close();
    if(flightInvalid||flightMinClearance<0||flightMinSpeed<1||flightMaxSpeed>100||flightMaxBank>.551||flightMinCl<.149||flightMaxCl>1.351)
        throw std::runtime_error("Flight trajectory violates finite/clearance/control envelope.");
    std::cout<<"Flight physics: "<<4*FlightSamples<<" samples, clearance="<<flightMinClearance<<"m, airspeed="<<flightMinSpeed<<".."<<flightMaxSpeed<<"m/s, GPU="<<flightMS<<"ms"<<std::endl;
    UINT waterIndex=0,waterStep=0;
    auto detachWater=[&](){ID3D11ShaderResourceView* nullView=nullptr;context->VSSetShaderResources(7,1,&nullView);context->PSSetShaderResources(7,1,&nullView);};
    auto waterDispatch=[&](float mode,UINT source,UINT destination,UINT step){
        const float constants[]={1.f/60,step/60.f,mode,float(step)};context->UpdateSubresource(physicsCB.Get(),0,nullptr,constants,0,0);
        context->CSSetShader(waterCS.Get(),nullptr,0);context->CSSetShaderResources(7,1,waters[source].srv.GetAddressOf());
        context->CSSetUnorderedAccessViews(0,1,waters[destination].uav.GetAddressOf(),nullptr);context->Dispatch(32,32,1);
        context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
    };
    auto resetWater=[&](float mode=0.f){detachWater();waterDispatch(mode,1,0,0);waterIndex=waterStep=0;};
    auto bindWater=[&](){context->VSSetShaderResources(7,1,waters[waterIndex].srv.GetAddressOf());context->PSSetShaderResources(7,1,waters[waterIndex].srv.GetAddressOf());context->CSSetShaderResources(7,1,waters[waterIndex].srv.GetAddressOf());};
    auto advanceWater=[&](float seconds){
        float phase=std::fmod(seconds,128.f);if(phase<0)phase+=128;
        const UINT target=UINT(std::floor(phase*60.f));if(target<waterStep)resetWater();
        detachWater();UINT advances=0;
        while(waterStep<target){waterDispatch(1,waterIndex,waterIndex^1,waterStep);waterIndex^=1;waterStep++;advances++;}
        bindWater();return advances;
    };
    resetWater();bindWater();
    if(physicsOnly) {
        bool physicsFailed=false;std::ofstream result(outDir/"physics_tests.json");result<<"{\"flight_finite\":true,\"tests\":[";
        for(UINT test=0;test<3;test++) {
            resetWater(test==1?3.f:0.f);const auto initial=waterMetrics(waters[waterIndex].values(context.Get()));
            const UINT steps=test==2?7680:600;const float mode=test==2?1.f:2.f;
            for(UINT step=0;step<steps;step++){waterDispatch(mode,waterIndex,waterIndex^1,step);waterIndex^=1;}
            const auto final=waterMetrics(waters[waterIndex].values(context.Get()));
            const double massError=std::abs(final.volume-initial.volume),relativeMassError=massError/std::max(1.0,std::abs(initial.volume));
            const bool good=!final.invalid&&!final.foamOutOfRange&&final.maxHeight<.5&&relativeMassError<.001&&(test!=0||final.maxHeight<1e-7);
            physicsFailed|=!good;result<<(test?",":"")<<"{\"name\":\""<<(test==0?"rest_state":test==1?"gaussian_conservation":"forced_128_seconds")<<"\",\"steps\":"<<steps
                <<",\"initial\":"<<json(initial)<<",\"final\":"<<json(final)<<",\"relative_volume_error\":"<<relativeMassError<<",\"passed\":"<<(good?"true":"false")<<"}";
            std::cout<<"Water physics test "<<test<<" max eta="<<final.maxHeight<<" volume error="<<massError<<" pass="<<good<<std::endl;
        }
        // Integrating the same physical time in irregular display-frame
        // partitions and after a backwards seek must produce identical bits.
        resetWater();advanceWater(64.f);const auto direct=waters[waterIndex].values(context.Get());
        resetWater();for(UINT partition=1;partition<=13;partition++)advanceWater(64.f*partition/13.f);
        const auto partitioned=waters[waterIndex].values(context.Get());
        advanceWater(32.f);advanceWater(64.f);const auto replayed=waters[waterIndex].values(context.Get());
        const bool partitionMatch=memcmp(direct.data(),partitioned.data(),direct.size()*sizeof(float))==0;
        const bool replayMatch=memcmp(direct.data(),replayed.data(),direct.size()*sizeof(float))==0;
        physicsFailed|=!partitionMatch||!replayMatch;
        const double cfl=std::sqrt(9.81*50.0)/60.0*std::hypot(256.0/2200.0,256.0/1600.0);
        physicsFailed|=cfl>=1;
        std::cout<<"Water fixed-clock determinism: partitions="<<partitionMatch<<", backwards replay="<<replayMatch<<", CFL="<<cfl<<std::endl;
        size_t warningCount=0;if(info)for(UINT64 i=0;i<info->GetNumStoredMessagesAllowedByRetrievalFilter();i++) {
            SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> storage(size);auto* message=reinterpret_cast<D3D11_MESSAGE*>(storage.data());
            check(info->GetMessage(i,message,&size),"Read physics diagnostics");if(message->Severity<=D3D11_MESSAGE_SEVERITY_WARNING){warningCount++;std::cerr<<message->pDescription<<"\n";}
        }
        result<<"],\"display_partition_bit_exact\":"<<(partitionMatch?"true":"false")
            <<",\"backwards_replay_bit_exact\":"<<(replayMatch?"true":"false")<<",\"conservative_CFL\":"<<cfl
            <<",\"debug_warnings_errors\":"<<warningCount<<"}\n";context->ClearState();return physicsFailed||warningCount?2:0;
    }
    auto updateCamera=[&](){
        ID3D11ShaderResourceView* nulls[4]={};context->PSSetShaderResources(0,4,nulls);context->VSSetShaderResources(3,1,nulls);
        context->PSSetShaderResources(5,1,terrainSRV.GetAddressOf()); // safe non-RT fallback in reflection mode
        context->CSSetShader(cameraCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,cameraUAV.GetAddressOf(),nullptr);
        context->Dispatch(1,1,1);context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
        context->VSSetShaderResources(3,1,cameraSRV.GetAddressOf());context->PSSetShaderResources(3,1,cameraSRV.GetAddressOf());
    };
    auto updateAtmosphere=[&](){
        ID3D11ShaderResourceView* nullView=nullptr;
        context->PSSetShaderResources(10,1,&nullView);context->CSSetShaderResources(3,1,cameraSRV.GetAddressOf());
        context->CSSetShader(atmosphereCS.Get(),nullptr,0);context->CSSetUnorderedAccessViews(0,1,atmosphereUAV.GetAddressOf(),nullptr);
        context->Dispatch(32,16,1);context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);
        context->CSSetShaderResources(3,1,&nullView);context->PSSetShaderResources(10,1,atmosphereSRV.GetAddressOf());
    };
    auto updateInstances=[&](){
        ID3D11ShaderResourceView* nullView=nullptr;
        context->VSSetShaderResources(12,1,&nullView);context->PSSetShaderResources(12,1,&nullView);context->CSSetShaderResources(12,1,&nullView);
        context->CSSetShaderResources(3,1,cameraSRV.GetAddressOf());context->CSSetShader(instancesCS.Get(),nullptr,0);
        context->CSSetUnorderedAccessViews(0,1,instanceUAV.GetAddressOf(),nullptr);context->Dispatch(InstanceGroups,1,1);
        context->CSSetUnorderedAccessViews(0,1,&nullUAV,nullptr);context->CSSetShaderResources(3,1,&nullView);
        context->VSSetShaderResources(12,1,instanceSRV.GetAddressOf());context->PSSetShaderResources(12,1,instanceSRV.GetAddressOf());
    };
    auto drawMeshes=[&](bool shadowPass,bool farPass=false){
        const UINT batches[][3]={{11520,64,0},{15624,192,1000},{48,12288,2000},{240,384,20000},{12288,4,30000},{288,6144,40000},{avatar.vertexCount,6,60000},{head.result.vertexCount,6,70000}};
        (void)shadowPass;
        for(size_t i=0;i<8;i++) {
            if(farPass&&(i==2||i>=6))continue;
            UINT durationBits=0;memcpy(&durationBits,&head.result.motionDuration,4);
            const UINT batchConstants[]={batches[i][2],0,i==7?head.result.motionFrames:0,i==7?durationBits:0};
            context->UpdateSubresource(batchCB.Get(),0,nullptr,batchConstants,0,0);
            context->DrawInstanced(farPass&&i==1?288:batches[i][0],batches[i][1],0,0);
        }
    };
    if(validateInstances) {
        auto vertexCode=read(shaderDir/"instance_probe_vs.cso"),pixelCode=read(shaderDir/"instance_probe_ps.cso");
        ComPtr<ID3D11VertexShader> instanceVS;ComPtr<ID3D11PixelShader> instancePS;
        check(device->CreateVertexShader(vertexCode.data(),vertexCode.size(),nullptr,&instanceVS),"Create instance test VS");
        check(device->CreatePixelShader(pixelCode.data(),pixelCode.size(),nullptr,&instancePS),"Create instance test PS");
        context->VSSetShader(instanceVS.Get(),nullptr,0);context->PSSetShader(instancePS.Get(),nullptr,0);
        context->PSSetConstantBuffers(1,1,batchCB.GetAddressOf());
        constexpr UINT contracts[][2]={{0,64},{1000,192},{2000,12288},{20000,384},{30000,4},{40000,6144},{50000,6}};
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
    if(waterDiagnostic) {
        auto code=read(shaderDir/"water_probe.cso");ComPtr<ID3D11PixelShader> shader;
        check(device->CreatePixelShader(code.data(),code.size(),nullptr,&shader),"Create water normal diagnostic");
        Surface samples(device.Get(),w,h,DXGI_FORMAT_R32G32B32A32_FLOAT);
        float constants[]={float(w),float(h),time,0,float(w),float(h),seed,time};
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);advanceWater(time);updateCamera();
        context->OMSetRenderTargets(1,samples.rtv.GetAddressOf(),nullptr);
        D3D11_VIEWPORT viewport{0,0,float(w),float(h),0,1};context->RSSetViewports(1,&viewport);
        context->PSSetShader(shader.Get(),nullptr,0);context->Draw(3,0);
        auto bytes=samples.pixels(context.Get());const float* values=reinterpret_cast<const float*>(bytes.data());
        size_t invalid=0,waterCount=0;double maxUnitError=0,slopeSquared=0;
        for(size_t i=0;i<size_t(w)*h;i++) {
            const float* v=values+i*4;bool finite=true;for(UINT k=0;k<4;k++)finite&=std::isfinite(v[k]);
            if(!finite){invalid++;continue;}invalid+=v[0]>0;waterCount+=v[3]>0;
            maxUnitError=std::max(maxUnitError,double(v[1]));slopeSquared+=v[2];
        }
        size_t warnings=0;if(info)for(UINT64 i=0;i<info->GetNumStoredMessagesAllowedByRetrievalFilter();i++) {
            SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> storage(size);auto* msg=reinterpret_cast<D3D11_MESSAGE*>(storage.data());
            check(info->GetMessage(i,msg,&size),"Get water diagnostic message");if(msg->Severity<=D3D11_MESSAGE_SEVERITY_WARNING){warnings++;std::cerr<<msg->pDescription<<"\n";}
        }
        const double rmsSlope=std::sqrt(slopeSquared/std::max(size_t(1),waterCount));
        const bool passed=!invalid&&!warnings&&waterCount>100&&maxUnitError<.001&&rmsSlope>1e-5;
        std::ofstream summary(outDir/"water_normal_metrics.json");summary<<"{\"samples\":"<<size_t(w)*h<<",\"time\":"<<time
            <<",\"deep_limit_checks\":"<<size_t(w)*h<<",\"water_samples\":"<<waterCount<<",\"nonfinite_normal_or_uv_pixels\":"<<invalid
            <<",\"max_normal_length_error\":"<<maxUnitError<<",\"water_rms_slope\":"<<rmsSlope<<",\"debug_warnings_errors\":"<<warnings
            <<",\"passed\":"<<(passed?"true":"false")<<"}\n";
        std::cout<<"Water normal/UV: samples="<<waterCount<<", nonfinite="<<invalid<<", unit error="<<maxUnitError<<", RMS slope="<<rmsSlope<<std::endl;
        context->ClearState();return passed?0:2;
    }
    if(!rawProbe.empty()) {
        auto code=read(rawProbe);ComPtr<ID3D11PixelShader> shader;check(device->CreatePixelShader(code.data(),code.size(),nullptr,&shader),"Create raw diagnostic PS");
        Surface samples(device.Get(),w,h,DXGI_FORMAT_R32G32B32A32_FLOAT);
        const float constants[8]={float(w),float(h),time,float(startFrame),float(w),float(h),seed,time};
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);updateCamera();
        context->OMSetRenderTargets(1,samples.rtv.GetAddressOf(),nullptr);D3D11_VIEWPORT viewport{0,0,float(w),float(h),0,1};context->RSSetViewports(1,&viewport);
        context->PSSetShader(shader.Get(),nullptr,0);context->Begin(terrainDisjoint.Get());context->End(terrainStart.Get());context->Draw(3,0);context->End(terrainEnd.Get());context->End(terrainDisjoint.Get());
        auto bytes=samples.pixels(context.Get());const float* values=reinterpret_cast<const float*>(bytes.data());
        std::ofstream binary(outDir/"raw_probe.bin",std::ios::binary);binary.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());
        std::ofstream csv(outDir/"raw_probe.csv");csv<<"x,y,r,g,b,a\n";size_t invalid=0;
        for(UINT y=0;y<h;y++)for(UINT x=0;x<w;x++){csv<<x<<","<<y;for(UINT c=0;c<4;c++){const float value=values[(size_t(y)*w+x)*4+c];invalid+=!std::isfinite(value);csv<<","<<std::setprecision(9)<<value;}csv<<"\n";}
        const auto timing=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),terrainDisjoint.Get());const UINT64 t0=query<UINT64>(context.Get(),terrainStart.Get()),t1=query<UINT64>(context.Get(),terrainEnd.Get());
        size_t messages=0;std::ofstream diagnostics(outDir/"d3d11_messages.txt");
        if(info)for(UINT64 i=0;i<info->GetNumStoredMessagesAllowedByRetrievalFilter();i++){SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<uint8_t> storage(size);auto* message=reinterpret_cast<D3D11_MESSAGE*>(storage.data());check(info->GetMessage(i,message,&size),"Read raw probe diagnostics");if(message->Severity<=D3D11_MESSAGE_SEVERITY_WARNING){messages++;diagnostics<<message->pDescription<<"\n";}}
        const double gpuMS=timing.Disjoint||!timing.Frequency?0:1000.0*double(t1-t0)/timing.Frequency;
        std::ofstream(outDir/"raw_probe_metrics.json")<<"{\"samples\":"<<size_t(w)*h<<",\"nonfinite\":"<<invalid<<",\"debug_warnings_errors\":"<<messages<<",\"gpu_ms\":"<<gpuMS<<"}\n";
        std::cout<<"Raw GPU probe: samples="<<size_t(w)*h<<", nonfinite="<<invalid<<", diagnostics="<<messages<<", GPU="<<gpuMS<<"ms"<<std::endl;
        context->ClearState();return invalid||messages||timing.Disjoint?2:0;
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
        return invalid||minClearance<.79||minWaterClearance<1.64||maxError>.001?2:0;
    }
    ComPtr<ID3D11Query> disjoint;D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT,0};check(device->CreateQuery(&qd,&disjoint),"CreateDisjoint");
    // One extra timestamp brackets the QA-only world snapshot copy. It is
    // excluded from stage timings, since the shipped runtime makes no copy.
    std::array<ComPtr<ID3D11Query>,18> timestamps;qd.Query=D3D11_QUERY_TIMESTAMP;
    for(auto& q:timestamps)check(device->CreateQuery(&qd,&q),"CreateTimestamp");
    std::ofstream metrics(outDir/"metrics.json");metrics<<"{\"adapter\":\""<<gpu<<"\",\"debug_layer\":"<<(debug?"true":"false")
        <<",\"candidate_sha256\":\""<<candidateSha256<<"\""
        <<",\"neural_avatar\":"<<neuralJson<<",\"neural_head\":"<<headJson
        <<",\"width\":"<<w<<",\"height\":"<<h<<",\"low_width\":"<<lowWidth<<",\"low_height\":"<<lowHeight<<",\"scale\":"<<scale
        <<",\"terrain_startup_gpu_ms\":"<<terrainMS<<",\"flight_startup_gpu_ms\":"<<flightMS<<",\"material_startup_gpu_ms\":"<<materialMS<<",\"terrain_bounds_startup_gpu_ms\":"<<boundsMS<<",\"cloud_startup_gpu_ms\":"<<cloudMS
        <<",\"seed\":"<<seed<<",\"dt\":"<<(frameTimes.empty()?std::to_string(dt):"null")<<",\"custom_frame_times\":"<<(frameTimes.empty()?"false":"true")<<",\"loop_time\":"<<(loopTime?"true":"false")
        <<",\"reflection_width\":"<<reflectionWidth<<",\"reflection_height\":"<<reflectionHeight
        <<",\"stage_names\":[\"physics\",\"camera\",\"instances\",\"atmosphere\",\"far_shadow\",\"shadow\",\"reflection_world\",\"reflection_mesh\",\"reflection_clouds\",\"world\",\"mesh\",\"human\",\"cloud_composite\",\"temporal\",\"display\"],\"frames\":[\n";
    auto compositeClouds=[&](Surface& target,ID3D11ShaderResourceView* source){
        ID3D11ShaderResourceView* nulls[2]={};context->PSSetShaderResources(0,2,nulls);context->OMSetRenderTargets(1,target.rtv.GetAddressOf(),nullptr);context->OMSetDepthStencilState(postDepth.Get(),0);
        D3D11_VIEWPORT viewport{0,0,float(target.width),float(target.height),0,1};context->RSSetViewports(1,&viewport);
        context->PSSetShaderResources(0,1,&source);context->VSSetShader(vs.Get(),nullptr,0);context->PSSetShader(cloudCompositePS.Get(),nullptr,0);context->Draw(3,0);
    };
    std::vector<uint8_t> previous; bool failed=false; float previousSeconds=time;
    for(UINT f=0;f<frames;f++) {
        float t=frameTimes.empty()?time+f*dt:frameTimes[f];if(loopTime)t=std::fmod(t,128.f);
        const float constants[]={float(lowWidth),float(lowHeight),t,float(startFrame+f),float(w),float(h),seed,f?previousSeconds:t};
        const float phase=std::fmod(t,128.f);const bool reflectionEnabled=phase>=40&&phase<=108;
        const float mainPass[]={0,reflectionEnabled?1.f:0.f,0,0},reflectionPass[]={1,1,0,0};
        context->UpdateSubresource(passCB.Get(),0,nullptr,mainPass,0,0);
        previousSeconds=t;
        context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);
        UINT prev=f&1,next=prev^1;context->Begin(disjoint.Get());context->End(timestamps[11].Get());
        const UINT physicsSteps=advanceWater(t);context->End(timestamps[12].Get());context->End(timestamps[0].Get());
        updateCamera();context->End(timestamps[1].Get());
        updateInstances();context->End(timestamps[15].Get());
        updateAtmosphere();context->End(timestamps[13].Get());
        const float clearShadow[4]={1,1,1,1},farPass[4]={0,0,1,0};
        ID3D11ShaderResourceView* nullFar=nullptr;context->PSSetShaderResources(11,1,&nullFar);
        context->UpdateSubresource(passCB.Get(),0,nullptr,farPass,0,0);
        context->OMSetDepthStencilState(nullptr,0);
        context->OMSetRenderTargets(1,farShadow.rtv.GetAddressOf(),farShadowDepth.dsv.Get());
        context->ClearRenderTargetView(farShadow.rtv.Get(),clearShadow);context->ClearDepthStencilView(farShadowDepth.dsv.Get(),D3D11_CLEAR_DEPTH,1,0);
        D3D11_VIEWPORT farViewport{0,0,1024,1024,0,1};context->RSSetViewports(1,&farViewport);
        context->VSSetShader(shadowVS.Get(),nullptr,0);context->PSSetShader(shadowPS.Get(),nullptr,0);drawMeshes(true,true);
        context->OMSetRenderTargets(0,nullptr,nullptr);context->PSSetShaderResources(11,1,farShadow.srv.GetAddressOf());
        context->UpdateSubresource(passCB.Get(),0,nullptr,mainPass,0,0);context->End(timestamps[14].Get());
        context->OMSetDepthStencilState(nullptr,0);
        context->OMSetRenderTargets(1,shadow.rtv.GetAddressOf(),shadowDepth.dsv.Get());
        context->ClearRenderTargetView(shadow.rtv.Get(),clearShadow);
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
            compositeClouds(reflectionClouded,reflection.srv.Get());context->End(timestamps[16].Get());
            context->UpdateSubresource(cb.Get(),0,nullptr,constants,0,0);context->UpdateSubresource(passCB.Get(),0,nullptr,mainPass,0,0);
        } else { context->End(timestamps[3].Get());context->End(timestamps[4].Get());context->End(timestamps[16].Get()); }
        context->OMSetRenderTargets(1,low.rtv.GetAddressOf(),mainDepth.dsv.Get());
        if(reflectionEnabled)context->PSSetShaderResources(5,1,reflectionClouded.srv.GetAddressOf());
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
        compositeClouds(clouded,humans.srv.Get());context->End(timestamps[17].Get());
        pass(2,histories[next],clouded.srv.Get(),histories[prev].srv.Get());pass(3,output,histories[next].srv.Get(),nullptr);
        context->End(disjoint.Get());context->Flush();
        auto dis=query<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>(context.Get(),disjoint.Get());std::array<UINT64,18> ticks{};
        for(size_t i=0;i<ticks.size();i++)ticks[i]=query<UINT64>(context.Get(),timestamps[i].Get());
        const auto waterState=waterMetrics(waters[waterIndex].values(context.Get()));
        auto worldPixels=worldSnapshot.pixels(context.Get(),false);auto wo=measure(worldPixels);auto lo=measure(low.pixels(context.Get()));
        if(dumpWorld&&f==0){std::ofstream raw(outDir/"world_rgba16f.bin",std::ios::binary);raw.write(reinterpret_cast<const char*>(worldPixels.data()),worldPixels.size());}
        auto humanPixels=humans.pixels(context.Get()),cloudPixelsFrame=clouded.pixels(context.Get());
        auto hu=measure(humanPixels);auto cl=measure(cloudPixelsFrame);auto hi=measure(histories[next].pixels(context.Get()));
        const size_t cloudDepthChanged=changedDepth(humanPixels,cloudPixelsFrame);size_t reflectionDepthChanged=0;Metrics re;
        if(reflectionEnabled) {
            auto reflectionPixels=reflectionClouded.pixels(context.Get());re=measure(reflectionPixels);
            reflectionDepthChanged=changedDepth(reflection.pixels(context.Get()),reflectionPixels);
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
        const auto farValues=farShadow.pixels(context.Get());const auto farSh=scalarMetrics(farValues,true);
        context->CopyResource(atmosphereStaging.Get(),atmosphereTexture.Get());D3D11_MAPPED_SUBRESOURCE atmosphereMap{};
        check(context->Map(atmosphereStaging.Get(),0,D3D11_MAP_READ,0,&atmosphereMap),"Map atmosphere LUT");
        size_t atmosphereInvalid=0;float atmosphereMax=0;double atmosphereSum=0;
        std::vector<uint8_t> atmospherePreview(256*128*4);
        for(UINT row=0;row<128;row++)for(UINT col=0;col<256;col++) {
            auto* values=reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(atmosphereMap.pData)+size_t(row)*atmosphereMap.RowPitch)+col*4;
            for(UINT channel=0;channel<4;channel++) {
                float value=half(values[channel]);atmosphereInvalid+=!std::isfinite(value);
                if(channel<3){atmosphereMax=std::max(atmosphereMax,value);atmosphereSum+=value;float display=value/(1.f+std::max(0.f,value));atmospherePreview[(row*256+col)*4+channel]=uint8_t(255*std::pow(std::clamp(display,0.f,1.f),1.f/2.2f));}
            }
            atmospherePreview[(row*256+col)*4+3]=255;
        }
        context->Unmap(atmosphereStaging.Get(),0);if(f==0)bmp(outDir/"atmosphere_preview.bmp",atmospherePreview,256,128);
        context->CopyResource(cameraStaging.Get(),cameraBuffer.Get());D3D11_MAPPED_SUBRESOURCE cameraMap{};
        check(context->Map(cameraStaging.Get(),0,D3D11_MAP_READ,0,&cameraMap),"Map camera cache");
        std::vector<uint8_t> cameraValues(CameraFloats*4);memcpy(cameraValues.data(),cameraMap.pData,CameraFloats*4);context->Unmap(cameraStaging.Get(),0);
        if(dumpWorld&&f==0){std::ofstream raw(outDir/"camera_float4.bin",std::ios::binary);raw.write(reinterpret_cast<const char*>(cameraValues.data()),cameraValues.size());}
        const auto ca=scalarMetrics(cameraValues,false);
        context->CopyResource(instanceStaging.Get(),instanceBuffer.Get());D3D11_MAPPED_SUBRESOURCE instanceMap{};
        check(context->Map(instanceStaging.Get(),0,D3D11_MAP_READ,0,&instanceMap),"Map instance cache");
        std::vector<uint8_t> instanceValues(size_t(InstanceElements)*16);memcpy(instanceValues.data(),instanceMap.pData,instanceValues.size());context->Unmap(instanceStaging.Get(),0);
        const auto instances=scalarMetrics(instanceValues,false);
        const float* instanceData=reinterpret_cast<const float*>(instanceValues.data());
        size_t activeNearTrees=0,activeFarTrees=0,activeGrass=0,invalidInstanceFlags=0;
        for(UINT id=64;id<30976;id++) {
            const float valid=instanceData[size_t(id)*8+(id<18688?7:6)];
            invalidInstanceFlags+=valid!=0.f&&valid!=1.f;
            if(valid==1.f){if(id<256)activeNearTrees++;else if(id<18688)activeFarTrees++;else activeGrass++;}
        }
        if(dumpWorld&&f==0){std::ofstream raw(outDir/"instances_float4.bin",std::ios::binary);raw.write(reinterpret_cast<const char*>(instanceValues.data()),instanceValues.size());}
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
        constexpr int stageStarts[]={11,0,1,15,13,14,2,3,4,16,6,7,8,17,9};
        constexpr int stageEnds[]={12,1,15,13,14,2,3,4,16,5,7,8,17,9,10};
        for(int i=0;i<15;i++){double ms=dis.Disjoint||!dis.Frequency?0:1000.*double(ticks[stageEnds[i]]-ticks[stageStarts[i]])/dis.Frequency;total+=ms;metrics<<(i?",":"")<<ms;}
        metrics<<"],\"world\":"<<json(wo)<<",\"mesh_composite\":"<<json(lo)<<",\"shadow\":"<<json(sh)<<",\"camera\":"<<json(ca)
            <<",\"instance_cache\":"<<json(instances)
            <<",\"instance_counts\":{\"records\":"<<InstanceElements<<",\"houses\":64,\"active_near_trees\":"<<activeNearTrees<<",\"active_far_trees\":"<<activeFarTrees<<",\"active_grass\":"<<activeGrass<<",\"rocks\":384,\"branch_responses\":18432,\"invalid_flags\":"<<invalidInstanceFlags<<"}"
            <<",\"far_shadow\":"<<json(farSh)<<",\"atmosphere\":{\"nonfinite_values\":"<<atmosphereInvalid<<",\"max_rgb\":"<<atmosphereMax<<",\"mean_rgb\":"<<atmosphereSum/(256*128*3)<<"}"
            <<",\"human_composite\":"<<json(hu)<<",\"cloud_composite\":"<<json(cl)<<",\"resolved\":"<<json(hi)<<",\"physics_steps\":"<<physicsSteps<<",\"water_state\":"<<json(waterState)
            <<",\"cloud_changed_depth_pixels\":"<<cloudDepthChanged<<",\"reflection_cloud_changed_depth_pixels\":"<<reflectionDepthChanged
            <<",\"reflection_enabled\":"<<(reflectionEnabled?"true":"false")<<",\"reflection\":"<<(reflectionEnabled?json(re):"null")
            <<",\"mean_absolute_display_delta\":"<<difference<<",\"rgba_fnv1a64\":\""<<std::hex<<hash<<std::dec<<"\"}";
        // A full image at the minimum encoded depth means the camera/trace is
        // inside geometry. Numeric/API validity alone cannot detect that.
        bool collapsedDepth=lo.nearDepth>size_t(lowWidth)*lowHeight*99/100;
        failed|=wo.invalid||lo.invalid||hu.invalid||cl.invalid||hi.invalid||sh.invalid||ca.invalid||instances.invalid||invalidInstanceFlags||cloudDepthChanged||reflectionDepthChanged||sh.outOfRange||farSh.invalid||farSh.outOfRange||atmosphereInvalid||atmosphereMax<=0||wo.outOfDepthRange||lo.outOfDepthRange||hu.outOfDepthRange||cl.outOfDepthRange||hi.outOfDepthRange||dis.Disjoint||collapsedDepth||waterState.invalid||waterState.foamOutOfRange||waterState.maxHeight>1.0||(reflectionEnabled&&(re.invalid||re.outOfDepthRange));
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
