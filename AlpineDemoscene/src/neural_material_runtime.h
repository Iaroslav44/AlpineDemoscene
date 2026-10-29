#pragma once
#include <stdint.h>
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct ID3D11ShaderResourceView;

// Owned COM references are transferred only on success; release each once.
// Maps are generated from PhotoMat's real-flash-photo-trained neural networks.
struct NeuralMaterialResult {
    ID3D11Texture2D* diffuseRoughnessTexture; // +0, linear diffuse.rgb / roughness.a
    ID3D11ShaderResourceView* diffuseRoughnessSRV; // +8
    ID3D11Texture2D* normalHeightTexture; // +16, signed tangent normal.xyz / height.a
    ID3D11ShaderResourceView* normalHeightSRV; // +24
    ID3D11Texture2D* specularTexture; // +32, linear specular.rgb / 1
    ID3D11ShaderResourceView* specularSRV; // +40
    uint32_t width; // +48
    uint32_t status; // +52: 0 success, 2 cancelled, 3 model, 4 D3D, 6 allocation
    float seconds; // +56
    uint32_t seed; // +60
};
static_assert(sizeof(NeuralMaterialResult)==64,"MASM material ABI");

extern "C" int NeuralMaterialCreate(ID3D11Device*, ID3D11DeviceContext*,
    const void* modelData, uint32_t modelBytes, const void* csData, uint32_t csBytes,
    uint32_t seed, NeuralMaterialResult*, int(*pump)());

// QA only: callback receives temporary HWC tensors, never written by production.
extern "C" void NeuralMaterialSetDiagnosticSink(void(*sink)(const char*,const float*,uint32_t));
