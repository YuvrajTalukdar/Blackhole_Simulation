#include "CommonTypes.metal"

// ======== Ray Marcher: gravitational lensing + accretion disk + starfield ==

// ==== camera ray (pinhole, 70 deg FOV)
float3 camera_ray(int x, int y, constant Params* params) {
    float2 uv = float2(float(x), float(y));
    float aspect = float(params->image_width) / float(params->image_height);
    float2 ndc = (uv - 0.5f * float2(params->image_width, params->image_height)) / float(params->image_height);
    return normalize(params->cam_fwd + ndc.x/aspect * 0.70021f * params->cam_right + ndc.y * 0.70021f * params->cam_up);
}

// ==== very sparse near-black starfield ====
inline float3 sample_stars(float3 dir) {
    float3 c = {0.002f, 0.001f, 0.005f};  // practically black
    float theta = acos(clamp(dir.y, -1.0f, 1.0f));
    float phi   = atan2(dir.z, dir.x);

    for (int layer = 0; layer < 3; layer++) {
        float2 st  = float2(phi, theta) * float(300 + 400 * layer) / 3.14159265f;
        float2 id = floor(st);
        float2 frac = fract(st);
        float h1 = fract(sin(dot(id, float2(127.1f, 311.7f))) * 43758.5453f);
        float h2 = fract(sin(dot(id + float2(0.5f, 0.0f), float2(269.5f, 183.3f))) * 43758.5453f);
        float dist = length(frac - float2(h1, h2));
        float star = max(0.0f, 1.0f - dist * 5.0f);
        star = star * star * star * star * star;
        float mag = pow(h1, 12.0f);  // extremely sparse
        float temp = 3000.0f + 28000.0f * fract(sin(dot(id + float2(13.0f, 0.0f), float2(311.7f, 93.5f))) * 43758.5453f);
        c += star_col(temp) * star * mag * float(0.10 - 0.02 * layer);
    }
    return c;
}

// ==== main raymarch kernel ====
[[kernel]]
void ray_march(
    constant Params*           params   [[ buffer(0) ]],
    texture2d<float, access::write> scene [[ texture(1) ]],
    texture2d<float, access::write> composite [[ texture(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    int x = gid.x, y = gid.y;
    int W = params->image_width, H = params->image_height;
    if (x >= W || y >= H) return;

    float3 ro = params->cam_pos;
    float3 dir = camera_ray(x, y, params);
    float3 pos = ro;
    float3 col = float3(0.0);
    bool hit_disk = false;
    float3 prevPos = pos;
    bool absorbed = false;
    bool escaped = false;
    float min_r = length(pos);

    float rs = params->rs;
    float disk_min_r = rs * params->disk_r_in;
    float disk_max_r = rs * params->disk_r_out;
    float fine_threshold = rs * 12.0f;  // wider to catch more rays

    for (int i = 0; i < 3000 && !absorbed && !escaped; i++) {
        // Adaptive step size - smaller near black hole
        float r = length(pos);
        min_r = min(min_r, r);

        float stepSize;
        if (r > fine_threshold) {
            stepSize = max(0.01f, 0.04f * r);
        } else {
            stepSize = max(0.0005f, 0.0015f * r);  // much finer near the hole
        }
        stepSize = min(stepSize, 1.0f);

        pos = prevPos + dir * stepSize;

        // Update r after step
        r = length(pos);
        min_r = min(min_r, r);

        // === EVENT HORIZON: pure black ===
        // Any ray reaching inside rs -> write black and return
        if (r < params->rs * 0.95f) {
            scene.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            composite.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }

        // Singularity guard
        if (r < 0.0001f) { absorbed = true; break; }

        // === Gravitational bending ===
        float3 n = -normalize(pos);
        float accel = 1.5f * rs / (r * r);
        dir += n * accel * stepSize;
        dir = normalize(dir);

        // === Photon sphere shadow ===
        if (min_r < rs * 1.45f) { absorbed = true; break; }

        // === Far boundary ===
        if (r > 200.0f) { escaped = true; break; }

        // === Disk crossing detection ===
        // Check if ray crossed y=0 plane
        if (prevPos.y * pos.y < 0.0f) {
            float t_cross = prevPos.y / (prevPos.y - pos.y);
            t_cross = clamp(t_cross, 0.0f, 1.0f);
            float3 hit = prevPos + t_cross * (pos - prevPos);
            float disk_r = length(float2(hit.x, hit.z));

            // Check if within disk ring
            if (disk_r >= disk_min_r && disk_r <= disk_max_r) {
                float phi = atan2(hit.z, hit.x);
                float nr = (disk_r - disk_min_r) / (disk_max_r - disk_min_r);

                // === Keplerian orbital velocity ===
                float beta = sqrt(max(0.001f, rs / (2.0f * disk_r)));
                beta = min(beta, 0.4f);  // cap to avoid extreme beaming

                // Doppler factor
                float cos_phi = cos(phi);
                float D = sqrt(max(0.001f, 1.0f - beta * beta)) / (1.0f + beta * cos_phi);

                // === ANIMATION: gas rotation — VISIBLE ===
                // Speed up time dramatically so rotation is obvious
                float time = params->time * 30.0f;
                // Inner gas orbits MUCH faster than outer gas: omega = 1/r^(3/2)
                float omega = sqrt(1.0f / (disk_r * disk_r * disk_r));
                float orbitPhi = phi - time * omega * 3.0f;

                // === VISIBLE ORBITING PARTICLES / HOTSPOTS ===
                // These are the clearly visible bright spots orbiting the disk
                float hotspot = 0.0f;
                // 5 major hotspots at inner radii
                hotspot += 1.5f * pow(max(0.0f, cos(5.0f * orbitPhi)), 8.0f);
                // 3 hotspots at mid radii, orbiting opposite direction
                hotspot += 1.0f * pow(max(0.0f, cos(3.0f * (orbitPhi + time * 0.5f))), 6.0f);
                // 7 bright sparks at outer radii
                hotspot += 0.8f * pow(max(0.0f, sin(7.0f * orbitPhi)), 10.0f);
                // Spiral arms
                float spiral = pow(0.5f * sin(3.0f * orbitPhi - 2.0f * nr * 6.28f) + 0.5f, 3.0f);

                // Turbulence with animated rotation
                float turb1 = turbulence(orbitPhi, nr);
                float turb2 = turbulence(orbitPhi * 2.0f + 1.0f, nr * 1.5f + 0.1f);

                // === TEMPERATURE BASED RADIUS ===
                // Hot inner, cool outer
                float T_inner = 15000.0f;
                float T_outer = 2500.0f;
                float T_base = T_outer + (T_inner - T_outer) * pow(1.0f - nr, 2.0f);
                float T = T_base * pow(D, 0.3f);

                // === COLOR from temperature - vivid gradient ===
                float3 diskCol;
                if (T > 10000.0f) {
                    // Hot inner: bright cyan-blue
                    diskCol = float3(0.3f, 0.5f, 1.0f);
                } else if (T > 7000.0f) {
                    float t_m = (T - 7000.0f) / 3000.0f;
                    diskCol = mix(float3(1.0f, 0.95f, 0.6f), float3(0.3f, 0.5f, 1.0f), t_m);
                } else if (T > 4000.0f) {
                    float t_m = (T - 4000.0f) / 3000.0f;
                    diskCol = mix(float3(1.0f, 0.5f, 0.15f), float3(1.0f, 0.95f, 0.6f), t_m);
                } else {
                    // Cool outer: deep orange-red
                    float t_m = max(0.0f, (T - 2000.0f) / 2000.0f);
                    diskCol = mix(float3(0.6f, 0.1f, 0.03f), float3(1.0f, 0.5f, 0.15f), t_m);
                }

                // === BRILLIANCE (HDR) ===
                // Use moderate intensity to preserve color
                float brightness = 3.0f;
                // Inner edge much brighter
                brightness *= pow(1.0f - nr, 1.5f) * 2.0f + 0.5f;
                // Doppler beaming: approaching side brighter
                brightness *= pow(D, 3.0f);
                // Turbulence + spiral variation
                brightness *= (0.6f + 0.4f * turb1 + 0.2f * spiral);
                // === PARTICLE HOTSPOTS: clearly visible bright spots ===
                // Adding (not multiplying) so they create obvious bright "blobs"
                brightness += 4.0f * hotspot;
                // Gravitational redshift dims near horizon
                brightness *= sqrt(max(0.02f, 1.0f - rs / disk_r));

                // Bright inner ring
                float innerBoost = exp(-12.0f * nr);
                brightness += 5.0f * innerBoost;

                diskCol *= brightness;

                // === VERTICAL THICKNESS ===
                // Disk is not a mathematical plane - has gaussian thickness profile
                float y_from_plane = abs(hit.y);
                // Scale height increases with radius
                float H_disk = 0.05f * disk_r + 0.2f;
                float thickness = exp(-y_from_plane * y_from_plane / (2.0f * H_disk * H_disk));
                diskCol *= thickness;

                col += diskCol;
                hit_disk = true;
                break;
            }
        }
        prevPos = pos;
    }

    // If hit disk, write disk color
    if (hit_disk) {
        scene.write(float4(col, 1.0f), gid);
        composite.write(float4(col, 1.0f), gid);
        return;
    }

    // Escaped - sample starfield with final bent direction (gravitational lensing)
    // NOTE: DO NOT write stars here - let starfield_lens pass handle stars at LDR
    // so they don't get double tone-mapped and brighten the background
    // If escaped and didn't hit disk, col stays at 0.0 = pure black

    // Absorbed rays stay black (event horizon shadow)
    scene.write(float4(col, 1.0f), gid);
    composite.write(float4(col, 1.0f), gid);
}
