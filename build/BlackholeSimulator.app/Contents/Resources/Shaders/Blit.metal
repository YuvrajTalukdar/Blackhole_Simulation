#include <metal_stdlib>
using namespace metal;

// Fullscreen quad vertex shader
vertex float4 blit_vert(uint vid [[vertex_id]]) {
    float2 pos[4];
    pos[0] = float2(-1, -1);
    pos[1] = float2(1, -1);
    pos[2] = float2(-1, 1);
    pos[3] = float2(1, 1);
    return float4(pos[vid], 0.0, 1.0);
}

// Pass-through fragment shader - reads from RGBA16Float texture
fragment float4 blit_frag(float4 pos [[position]],
                          texture2d<float, access::read> tex [[texture(0)]]) {
    // Convert normalized position to texture coordinates
    float2 uv = pos.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y; // Flip Y for Metal texture coords
    return tex.read(uint2(uv * float2(float(tex.get_width()), float(tex.get_height()))));
}