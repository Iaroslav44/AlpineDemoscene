// Residents are now real runtime-generated neural meshes in the geometry pass.
// Retain this HDR copy to preserve the existing post-processing surface graph.
// No analytic SDF face/body fallback is drawn over the learned geometry.
Texture2D<float4> SceneLow : register(t0);
float4 H(float4 position : SV_POSITION) : SV_Target
{
    return SceneLow.Load(int3(int2(position.xy),0));
}
