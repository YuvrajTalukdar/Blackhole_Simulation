#include "CommonTypes.metal"

// ============================================================
// Accretion Disk Rendering
// ============================================================
// The accretion disk is a thin, luminous ring in the equatorial plane (y ≈ 0).
// Physical effects:
//   1. Temperature gradient: T(r) = T_inner · (r_inner / r)^(3/4)
//      Inner edge ~1500K (dust sublimation temperature), outer edge ~500K
//   2. Keplerian rotation: v(r) = c √(rs / 2r)
//   3. Doppler shift: material approaching the observer is blueshifted and brightened
//      Material receding is redshifted and dimmed (Doppler beaming: intensity ∝ D^4)
//   4. Gravitational redshift: photons escaping the well lose energy
//      ν_obs = ν_emit · √(1 - rs/r)
//   5. Blackbody radiation: B(λ,T) = (2hc²/λ⁵) / (exp(hc/λkT) - 1)
// ============================================================

// === Animated particle hotspots for disk ===
// These create clearly visible bright "blobs" that orbit, making rotation obvious
float hotspot_density(float phi, float log_r, float time) {
    // Multiple orbiting hotspots at different speeds
    float s1 = sin(3.0f * (phi - time * 0.8f));
    float s2 = sin(5.0f * (phi + time * 0.5f + log_r));
    float s3 = sin(2.0f * (phi - time * 1.2f) + 3.0f * log_r);
    float s4 = cos(7.0f * phi + time * 0.3f);

    // Combine with different amplitudes to create asymmetric bright spots
    float val = 0.2f * s1 * s1 +      // 3 major hotspots
                0.15f * s2 +          // faster spiraling pattern
                0.1f * s3 * s3 +      // counter-rotating feature
                0.1f * s4;            // high-frequency texture

    return val;
}

// === Disk emission color with animation ===
float3 disk_color_at(float3 hit, float3 ray_to_cam, constant Params* params) {
    float disk_r = length(hit.xz);
    float rs = params->rs;

    // Normalized radius
    float nr = (disk_r - rs*params->disk_r_in) / (rs*(params->disk_r_out - params->disk_r_in));

    // Temperature profile: T(r) = 1500K x (r_inner/r)^(3/4)
    float r_in = rs * params->disk_r_in;
    float T = 1500.0f * pow(r_in / disk_r, 0.75f);
    T = clamp(T, 500.0f, 30000.0f);

    // Keplerian velocity: v = cSqrt(rs/2r)
    float beta = sqrt(max(1e-8f, rs / (2.0f * disk_r)));
    beta = min(beta, 0.99f);
    float3 vel = normalize(float3(-hit.z, 0, hit.x)) * beta * 299792458.0f;

    // Doppler factor: D = Sqrt(1-B^2)/(1+B cos theta)
    float beta_val = length(vel) / 299792458.0f;
    float cos_t = dot(normalize(vel), normalize(ray_to_cam));
    float D = sqrt(max(1e-8f, 1.0f - beta_val*beta_val)) / (1.0f + beta_val * cos_t);

    // Gravitational redshift: nu_obs = nu_emit Sqrt(1-rs/r)
    float grav = max(0.0f, sqrt(1.0f - rs / disk_r));

    // Doppler beaming intensity: I_obs = I_emit D^4
    float beaming = pow(max(D, 0.0f), 4.0f);

    // Surface brightness: ~1/r^2 for a steady-state viscous disk
    float surf = 1.0f / (nr + 0.1f);

    // === ANIMATED HOTSPOTS that orbit ===
    float phi = atan2(hit.z, hit.x);
    float log_r = log(max(1.0f, disk_r));
    float time = params->time;  // ANIMATION: use time parameter
    float spots = 1.0f + 1.5f * hotspot_density(phi, log_r, time);

    // Blackbody at grav-shifted temperature
    float3 col = blackbody_color(T * grav) * beaming * surf * 2.0f;
    col *= spots;  // Apply orbiting hotspot modulation
    return col;
}

// === Supplemental detailed disk pass ===
// If the main ray marcher misses thin disk features due to step size,
// this kernel does a ray-disk intersection at full resolution.
[[kernel]]
void disk_detail(
    uint2 gid [[ thread_position_in_grid ]],
    constant Params* params [[ buffer(0) ]],
    texture2d<float, access::read>  scene_in  [[ texture(1) ]],
    texture2d<float, access::write> scene_out [[ texture(2) ]]
) {
    int x = gid.x, y = gid.y;
    float4 px = scene_in.read(uint2(x, y));
    float3 base = px.rgb;

    // Cast a ray from the camera and check for disk intersection
    float2 uv = float2(float(x), float(y));
    float aspect = float(params->image_width) / float(params->image_height);
    float2 ndc = (uv - 0.5f * float2(float(params->image_width), float(params->image_height))) / float(params->image_height);
    const float fov = 0.70021f;
    float3 rd = normalize(params->cam_fwd + ndc.x/aspect*fov*params->cam_right + ndc.y*fov*params->cam_up);
    float3 ro = params->cam_pos;

    // Ray-plane intersection with y=0
    // Only paint where the ray marcher didn't already fill in color
    // (absorbed rays = event horizon shadow should stay black)
    if (abs(rd.y) > 1e-7f) {
        float t = -ro.y / rd.y;
        if (t > 0) {
            float3 hit = ro + t * rd;
            float disk_r = length(hit.xz);
            float rIn = params->rs * params->disk_r_in;
            float rOut = params->rs * params->disk_r_out;
            if (disk_r >= rIn && disk_r <= rOut) {
                float3 col = disk_color_at(hit, -rd, params);
                float grav = max(0.0f, sqrt(1.0f - params->rs / disk_r));
                col *= grav;
                // Only add where there was no existing color (escaped rays)
                // and NOT where the ray marcher wrote black (shadow)
                float lum = dot(base, float3(0.299f, 0.587f, 0.114f));
                // base==0 means either absorbed (shadow) or escaped (pure black)
                // We only want to fill escaped rays, so check: 
                // add disk only if base is dark AND the disk hit point is outside the shadow
                if (disk_r > params->rs * 2.5f && lum < 0.5f) {
                    base += col * 0.5f;
                }
            }
        }
    }

    scene_out.write(float4(base, 1.0f), uint2(x, y));
}
