#include "CommonTypes.metal"

// === Disk emission color (now time-varying) ===
// Physical effects:
//   1. Temperature gradient: T(r) = T_inner * (r_inner/r)^(3/4)
//   2. Time-varying spiral density waves
//   3. Keplerian rotation: inner orbits faster than outer
//   4. In-falling gas: material drifts radially inward
//   5. Doppler beaming + gravitational redshift
float3 disk_color_at(float3 hit, float3 ray_to_cam, constant Params* params) {
    float disk_r = length(hit.xz);
    float rs = params->rs;
    float time = params->time;
    float phi = atan2(hit.z, hit.x);  // azimuthal angle

    // Normalized radius 0..1
    float nr = (disk_r - rs*params->disk_r_in) / (rs*(params->disk_r_out - params->disk_r_in));
    float r_in = rs * params->disk_r_in;
    float r_out = rs * params->disk_r_out;

    // === Temperature profile ===
    float T_base = 15000.0f * pow(r_in / disk_r, 0.75f);

    // === Time-varying features ===

    // 1. Spiral density waves (Keplerian differential rotation)
    // Inner material orbits faster -> spiral pattern
    float orbital_omega = 2.0f / pow(disk_r, 1.5f);
    float spiral_angle = phi - orbital_omega * time;
    float spiral = sin(3.0f * spiral_angle + 2.0f * log(disk_r / r_in)) * 0.5f + 0.5f;
    spiral = pow(spiral, 1.5f);  // sharpen arms

    // 2. Hotspot blobs that orbit with the material
    float hotspot1 = cos(phi - 0.8f * orbital_omega * time + 0.5f);
    float hotspot2 = sin(phi - 0.6f * orbital_omega * time + 1.2f);
    float hotspots = max(hotspot1, 0.0f) * 0.4f + max(hotspot2, 0.0f) * 0.2f;

    // 3. Radial drift: gas falling inward -> inner edge brightens over time
    float radial_wave = sin(disk_r * 5.0f / rs - time * 2.5f);
    float radial_brightness = 0.7f + 0.3f * max(radial_wave, 0.0f);

    // 4. Inner edge glow: material just above ISCO (last stable orbit)
    // Very bright narrow ring at ~3*rs
    float inner_ring = exp(-20.0f * pow((disk_r - r_in) / (r_out - r_in), 2.0f));

    // Apply modulations to temperature
    float T = T_base * (1.0f + 0.4f * spiral + hotspots) * radial_brightness;
    T = clamp(T, 800.0f, 35000.0f);

    // Keplerian velocity
    float beta = sqrt(max(1e-8f, rs / (2.0f * disk_r)));
    beta = min(beta, 0.8f);
    float3 vel = normalize(float3(-hit.z, 0, hit.x)) * beta;

    // Doppler factor
    float cos_t = dot(vel, normalize(ray_to_cam));
    float D = sqrt(max(1e-8f, 1.0f - beta*beta)) / (1.0f + beta * cos_t);

    // Gravitational redshift
    float grav = max(0.0f, sqrt(1.0f - rs / disk_r));

    // Doppler beaming intensity: D^4
    float beaming = pow(max(D, 0.0f), 4.0f);

    // === Color ===
    float3 col = star_col(T) * beaming * grav;

    // Brightness: spiral arms + hotspots + inner ring
    col *= (0.5f + 1.0f * spiral + 1.5f * hotspots + 3.0f * inner_ring);

    // Surface brightness falloff (1/r^2 for steady disk, reduced to 1/r for better visibility)
    float surf = 1.0f / (nr + 0.2f);
    col *= surf;

    // Overall HDR intensity scaling
    col *= 15.0f;

    return col;
}

// === Supplemental detailed disk pass (time-varying) ===
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

    // Cast ray from camera to disk
    float2 uv = float2(float(x), float(y));
    float aspect = float(params->image_width) / float(params->image_height);
    float2 ndc = (uv - 0.5f * float2(float(params->image_width), float(params->image_height))) / float(params->image_height);
    const float fov = 0.70021f;
    float3 rd = normalize(params->cam_fwd + ndc.x/aspect*fov*params->cam_right + ndc.y*fov*params->cam_up);
    float3 ro = params->cam_pos;

    // Ray-plane intersection with y=0
    if (abs(rd.y) > 1e-7f) {
        float t = -ro.y / rd.y;
        if (t > 0) {
            float3 hit = ro + t * rd;
            float disk_r = length(hit.xz);
            float rIn = params->rs * params->disk_r_in;
            float rOut = params->rs * params->disk_r_out;
            if (disk_r >= rIn && disk_r <= rOut) {
                float3 col = disk_color_at(hit, -rd, params);
                // Add to HDR scene (don't replace)
                base += col;
            }
        }
    }

    scene_out.write(float4(base, 1.0f), uint2(x, y));
}
