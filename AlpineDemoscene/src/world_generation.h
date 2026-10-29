#pragma once
#include <stdint.h>
struct ID3D11Device;struct ID3D11DeviceContext;struct ID3D11ShaderResourceView;
struct ID3D11UnorderedAccessView;struct ID3D11Texture2D;
struct WorldGenerationResult {
    ID3D11Texture2D* ecologyTexture;
    ID3D11ShaderResourceView* ecologySRV;
    uint32_t status,iterations;
    float seconds;uint32_t resolution;
};
static_assert(sizeof(WorldGenerationResult)==32,"MASM world generation ABI");
// Changes the existing height field before grounding/bounds/physics begin.
// The pump uses1=continue,0=cancel. The caller owns the two result references.
extern "C" int WorldGenerate(ID3D11Device*,ID3D11DeviceContext*,
    ID3D11ShaderResourceView* originalHeight,ID3D11UnorderedAccessView* heightOutput,
    const void* shader,uint32_t shaderBytes,WorldGenerationResult*,int(*pump)());
