#include "CommonTypes.metal"

// ======== Post-Processing: Bloom, Tone Mapping ========

// Gaussian blur weights (13-tap, sigma=2.0)
constant int blur_kernel_size = 13;
constant float blur_weights[blur_kernel_size] = {
    0.0010, 0.0027, 0.0065, 0.0130, 0.0230, 0.0352,
    0.0459, 0.0459, 0.0352, 0.0230, 0.0130, 0.0065, 0.0027
};
constant int blur_offsets[blur_kernel_size] = {
    -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6
};

// ==== 1. Gaussian Blur ====
[[kernel]]
void gaussian_blur(
    uint2 gid [[ thread_position_in_grid ]],
    texture2d<float, access::read>  src  [[ texture(1) ]],
    texture2d<float, access::write> dst  [[ texture(2) ]]
) {
    uint x = gid.x, y = gid.y;
    if (x >= src.get_width() || y >= src.get_height()) return;

    float3 result = {0, 0, 0};
    for (int i = 0; i < blur_kernel_size; i++) {
        int offset = blur_offsets[i];
        int sx = (int)x + offset;
        if (sx < 0) sx = 0;
        if (sx >= (int)src.get_width()) sx = (int)src.get_width() - 1;
        float3 px = src.read(uint2((uint)sx, y)).rgb;
        result += px * blur_weights[i];
    }

    float3 result2 = {0, 0, 0};
    for (int i = 0; i < blur_kernel_size; i++) {
        int offset = blur_offsets[i];
        int sy = (int)y + offset;
        if (sy < 0) sy = 0;
        if (sy >= (int)src.get_height()) sy = (int)src.get_height() - 1;
        float3 px = src.read(uint2(x, (uint)sy)).rgb;
        result2 += px * blur_weights[i];
    }

    result = (result + result2) * 0.5f;
    dst.write(float4(result, 1.0), uint2(x, y));
}

// ==== 2. Bloom Combine ====
[[kernel]]
void bloom_combine(
    uint2 gid [[ thread_position_in_grid ]],
    constant Params& params [[ buffer(0) ]],
    texture2d<float, access::read>  scene     [[ texture(1) ]],
    texture2d<float, access::read>  bloom_src [[ texture(2) ]],
    texture2d<float, access::write> composite [[ texture(3) ]]
) {
    uint x = gid.x, y = gid.y;
    uint W = (uint)params.image_width, H = (uint)params.image_height;
    if (x >= W || y >= H) return;

    float3 scene_color = scene.read(uint2(x, y)).rgb;
    float3 bloom = bloom_src.read(uint2(x, y)).rgb;

    float bloom_intensity = 0.5f * params.exposure;
    float3 color = scene_color + bloom * bloom_intensity;

    // ACES filmic tone mapping
    const float a = 2.51f, b_val = 0.03f, c_val = 2.43f, d_val = 0.59f, e_val = 0.14f;
    color = (color * (a * color + b_val)) / (color * (c_val * color + d_val) + e_val);
    color = clamp(color, 0.0f, 1.0f);

    // Gamma
    color = pow(color, float3(1.0f/2.2f));

    composite.write(float4(color, 1.0), uint2(x, y));
}

// ==== 3. Bloom extraction (threshold) ====
[[kernel]]
void bloom_extract(
    uint2 gid [[ thread_position_in_grid ]],
    texture2d<float, access::read>  scene  [[ texture(1) ]],
    texture2d<float, access::write> dst    [[ texture(2) ]]
) {
    uint x = gid.x, y = gid.y;
    if (x >= scene.get_width() || y >= scene.get_height()) return;

    float3 col = scene.read(uint2(x, y)).rgb;

    float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
    if (lum < 0.8f) {
        dst.write(float4(0.0, 0.0, 0.0, 1.0), uint2(x, y));
        return;
    }

    float3 bright = max(col - 0.8f, 0.0f) * 2.0f;
    dst.write(float4(bright, 1.0), uint2(x, y));
}
