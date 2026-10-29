#pragma once
#include <stdint.h>
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Buffer;
struct ID3D11ShaderResourceView;

struct NeuralAvatarResult {
    ID3D11Buffer* vertexBuffer;
    ID3D11ShaderResourceView* vertexSRV;
    uint32_t vertexCount;
    uint32_t status;
    float boundsMin[3];
    float boundsMax[3];
    float seconds;
    uint32_t seed;
    uint32_t reserved[2]; // measured feature generation / occupancy milliseconds
    ID3D11Buffer* motionBuffer;
    ID3D11ShaderResourceView* motionSRV;
    uint32_t motionFrames;
    uint32_t vertexStrideBytes;
    float motionDuration;
    uint32_t padding;
    ID3D11Buffer* rigBuffer;
    ID3D11ShaderResourceView* rigSRV;
};
static_assert(sizeof(NeuralAvatarResult)==112,"MASM result ABI");

// Body-only generated rig metadata: 32 float4 records (512 bytes), CS t23.
// Records0..23 are learned skin-interface bind landmarks in normalized metres.
// Records24/25 hold left/right ankle-to-sole distances after canonical unspread;
// records26..31 are reserved. Heads currently leave this buffer null.

// pump returns nonzero to continue, zero to cancel. All transient buffers are
// released before returning. Success transfers vertexBuffer/vertexSRV to caller.
extern "C" int NeuralAvatarCreate(ID3D11Device*, ID3D11DeviceContext*,
    const void* navData, uint32_t navBytes, const void* csData, uint32_t csBytes,
    uint32_t seed, NeuralAvatarResult*, int(*pump)());

// Optional offline validation hook. The executable leaves this unset, so no
// intermediate feature fields or meshes are written or read during playback.
extern "C" void NeuralAvatarSetDiagnosticSink(void(*sink)(const char*,const float*,uint32_t));
