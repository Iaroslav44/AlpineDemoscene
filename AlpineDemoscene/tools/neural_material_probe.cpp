#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <vector>
#include <string>
#include "neural_material_runtime.h"
static std::filesystem::path destination;
static unsigned pumps=0,cancelAt=0;
static int Pump(){++pumps;return !cancelAt||pumps<cancelAt;}
static void Sink(const char* name,const float* values,uint32_t count){
    auto path=destination/(std::string(name)+".f32");FILE* file=0;_wfopen_s(&file,path.c_str(),L"wb");if(file){fwrite(values,4,count,file);fclose(file);}
    printf("tensor %s: %u floats\n",name,count);fflush(stdout);
}
static std::vector<unsigned char> Load(const wchar_t* path){
    FILE* file=0;_wfopen_s(&file,path,L"rb");if(!file)return{};_fseeki64(file,0,SEEK_END);auto size=_ftelli64(file);_fseeki64(file,0,SEEK_SET);std::vector<unsigned char> result((size_t)size);fread(result.data(),1,result.size(),file);fclose(file);return result;
}
static bool SaveTexture(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* texture,const char* name){
    D3D11_TEXTURE2D_DESC d;texture->GetDesc(&d);d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.BindFlags=0;d.MiscFlags=0;ID3D11Texture2D* stage=0;
    if(FAILED(device->CreateTexture2D(&d,0,&stage)))return false;context->CopyResource(stage,texture);D3D11_MAPPED_SUBRESOURCE m={};if(FAILED(context->Map(stage,0,D3D11_MAP_READ,0,&m))){stage->Release();return false;}
    std::vector<float> data(d.Width*d.Height*4);for(unsigned y=0;y<d.Height;++y)memcpy(data.data()+y*d.Width*4,(unsigned char*)m.pData+y*m.RowPitch,d.Width*16);context->Unmap(stage,0);stage->Release();Sink(name,data.data(),(unsigned)data.size());return true;
}
int wmain(int argc,wchar_t** argv){
    if(argc<4)return 2;destination=argv[3];std::filesystem::create_directories(destination);unsigned seed=argc>4?(unsigned)_wtoi(argv[4]):42;cancelAt=argc>5?(unsigned)_wtoi(argv[5]):0;
    auto model=Load(argv[1]),code=Load(argv[2]);if(model.empty()||code.empty())return 3;
    ID3D11Device* device=0;ID3D11DeviceContext* context=0;D3D_FEATURE_LEVEL feature;D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_0};
    HRESULT hr=D3D11CreateDevice(0,D3D_DRIVER_TYPE_HARDWARE,0,0,levels,1,D3D11_SDK_VERSION,&device,&feature,&context);if(FAILED(hr))return 4;
    NeuralMaterialResult invalid={};
    bool truncatedRejected=!NeuralMaterialCreate(device,context,model.data(),(uint32_t)model.size()-4,code.data(),(uint32_t)code.size(),seed,&invalid,0)&&invalid.status==3;
    uint32_t* header=(uint32_t*)model.data();uint32_t magic=header[0];header[0]=0;
    bool magicRejected=!NeuralMaterialCreate(device,context,model.data(),(uint32_t)model.size(),code.data(),(uint32_t)code.size(),seed,&invalid,0)&&invalid.status==3;header[0]=magic;
    uint32_t* firstOffset=(uint32_t*)(model.data()+64+80+6*4);uint32_t originalOffset=*firstOffset;*firstOffset=0;
    bool offsetRejected=!NeuralMaterialCreate(device,context,model.data(),(uint32_t)model.size(),code.data(),(uint32_t)code.size(),seed,&invalid,0)&&invalid.status==3;*firstOffset=originalOffset;
    if(!truncatedRejected||!magicRejected||!offsetRejected)return 6;
    NeuralMaterialSetDiagnosticSink(Sink);NeuralMaterialResult result={};
    bool ok=NeuralMaterialCreate(device,context,model.data(),(uint32_t)model.size(),code.data(),(uint32_t)code.size(),seed,&result,Pump)!=0;
    if(ok)ok=SaveTexture(device,context,result.diffuseRoughnessTexture,"diffuse_roughness")&&SaveTexture(device,context,result.normalHeightTexture,"normal_height")&&SaveTexture(device,context,result.specularTexture,"specular");
    FILE* file=0;_wfopen_s(&file,(destination/"timing.json").c_str(),L"wb");
    if(file){fprintf(file,"{\"success\":%s,\"status\":%u,\"seconds\":%.6f,\"seed\":%u,\"width\":%u,\"pump_calls\":%u,\"cancel_at\":%u,\"reject_truncated\":%s,\"reject_bad_magic\":%s,\"reject_bad_offset\":%s}\n",ok?"true":"false",result.status,result.seconds,seed,result.width,pumps,cancelAt,truncatedRejected?"true":"false",magicRejected?"true":"false",offsetRejected?"true":"false");fclose(file);}
    printf("success=%d status=%u time=%.3f seconds pumps=%u\n",ok,result.status,result.seconds,pumps);
    if(result.diffuseRoughnessSRV)result.diffuseRoughnessSRV->Release();if(result.diffuseRoughnessTexture)result.diffuseRoughnessTexture->Release();
    if(result.normalHeightSRV)result.normalHeightSRV->Release();if(result.normalHeightTexture)result.normalHeightTexture->Release();if(result.specularSRV)result.specularSRV->Release();if(result.specularTexture)result.specularTexture->Release();context->ClearState();context->Release();device->Release();
    return (ok||(cancelAt&&result.status==2))?0:5;
}
