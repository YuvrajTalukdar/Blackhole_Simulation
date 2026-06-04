#ifndef COMMON_TYPES_H
#define COMMON_TYPES_H

#include <metal_stdlib>
using namespace metal;

// ======== Uniform Params (shared by all shaders) ===
struct Params {
    float   rs;
    float   disk_r_in;
    float   disk_r_out;
    float3  cam_pos;
    float3  cam_right;
    float3  cam_up;
    float3  cam_fwd;
    float   time;
    float   exposure;
    int     nsteps;
    uint    disk_visible;
    uint    bloom_on;
    float   _pad0;
    float   _pad1;
    int     image_width;
    int     image_height;
};

// ========= Full tone mapping + gamma ===========
// Take HDR color, apply Reinhard tone map, then gamma 2.2
inline float3 tone_map(float3 hdr) {
    hdr = hdr / (hdr + float3(1.0f));
    return pow(clamp(hdr, float3(0.0f), float3(1.0f)), float3(1.0f/2.2f));
}

//========= Realistic blackbody temperature -> RGB ====
// Based on Planckian locus data, gives proper orange->yellow->white->blue colors
// T in Kelvin, returns RGB in [0,1] range (chromaticity only, caller multiplies brightness)
inline float3 temperature_color(float T) {
    T = clamp(T, 800.0f, 40000.0f);
    float t = T / 100.0f;
    float r, g, b;

    if (t <= 66.0f) {
        // Warm colors (red/orange dominant)
        r = 1.0f;
        g = max(0.0f, min(1.0f, 0.390081578769f * log(t - 10.0f) - 0.6318986329f));
        b = (t > 19.0f) ? max(0.0f, min(1.0f, 0.543103703435f * log(t - 46.0f) - 1.1962227492f)) : 0.0f;
    } else {
        // Cool colors (blue dominant)
        r = max(0.0f, min(1.0f, 1.3687484562f * pow(t - 60.0f, -0.0605067457f)));
        g = max(0.0f, min(1.0f, 1.1894476438f * pow(t - 60.0f, -0.0730704663f)));
        b = 1.0f;
    }
    return float3(r, g, b);
}

// ========= Star color (alias) =====
inline float3 star_col(float T) { return temperature_color(T); }
inline float3 blackbody_color(float T) { return temperature_color(T); }
inline float3 disk_color(float T) { return temperature_color(T); }

// ========= Value noise on torus parameterization (phi, radius_fraction) =====
// Periodic in phi (0..2pi), smooth interpolation
inline float disk_noise(float phi, float rt) {
    float p = phi / (2.0f * 3.14159265f);
    float2 uv = float2(p, rt);
    float2 id = floor(uv);
    float2 f = fract(uv);
    float2 w = f*f*(3.0f - 2.0f*f);
    float h00 = fract(sin(dot(id, float2(127.1f,311.7f))) * 43758.5453f);
    float h10 = fract(sin(dot(id+float2(1.0f,0.0f), float2(269.5f,183.3f))) * 43758.5453f);
    float h01 = fract(sin(dot(id+float2(0.0f,1.0f), float2(419.2f,593.1f))) * 43758.5453f);
    float h11 = fract(sin(dot(id+float2(1.0f,1.0f), float2(637.3f,877.4f))) * 43758.5453f);
    return mix(mix(h00,h10,w.x), mix(h01,h11,w.x), w.y);
}

// Multi-octave turbulence
inline float turbulence(float phi, float rt) {
    float v = 0.0f;
    float amp = 0.5f;
    for (int i = 0; i < 4; i++) {
        int fi = 1 << i;
        v += amp * disk_noise(phi * float(fi), rt * float(fi));
        amp *= 0.5f;
    }
    return v;
}

#endif // COMMON_TYPES_H
