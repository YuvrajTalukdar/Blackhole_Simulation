#include "CommonTypes.metal"

// ======== Starfield lensing pass + FINAL TONE MAP ======
// Pipeline: ray_march(HDR) -> bloom_extract -> blur -> bloom_combine(tone map) -> disk_detail(HDR, overwrites) -> THIS STEP
// This is the LAST shader to write before blit to display. MUST apply tone mapping here.

// Very sparse background star field — almost pure black with tiny bright points
inline float3 sparsely_sample_stars(float3 dir) {
    float3 c = {0.0f, 0.0f, 0.0f};  // pure black — no ambient glow
    float theta = acos(clamp(dir.y, -1.0f, 1.0f));
    float phi   = atan2(dir.z, dir.x);

    for (int layer = 0; layer < 3; layer++) {
        float2 st  = float2(phi, theta) * float(300 + 400 * layer) / 3.14159265f;
        float2 id = floor(st);
        float2 frac = fract(st);
        float h1 = fract(sin(dot(id, float2(127.1f, 311.7f))) * 43758.5453f);
        float h2 = fract(sin(dot(id + float2(0.5f, 0.0f), float2(269.5f, 183.3f))) * 43758.5453f);
        float dist = length(frac - float2(h1, h2));
        float star = max(0.0f, 1.0f - dist * 5.0f);  // very sharp cutoff
        star = star * star * star * star * star * star;
        float mag = pow(h1, 14.0f);  // extremely rare bright stars only
        float temp = 3000.0f + 28000.0f * fract(sin(dot(id + float2(13.0f, 0.0f), float2(311.7f, 93.5f))) * 43758.5453f);
        c += star_col(temp) * star * mag * float(0.08 - 0.02 * layer);
    }
    return c;
}

[[kernel]]
void starfield_lens(
    uint2 gid [[ thread_position_in_grid ]],
    constant Params* params [[ buffer(0) ]],
    texture2d<float, access::read>  scene_in  [[ texture(1) ]],
    texture2d<float, access::write> scene_out [[ texture(2) ]]
) {
    int x = gid.x, y = gid.y;
    int W = params->image_width, H = params->image_height;
    if (x >= W || y >= H) return;

    // Read HDR accumulated scene (ray march + disk detail)
    float3 hdr = scene_in.read(uint2(x, y)).rgb;

    // Scale exposure
    hdr *= params->exposure;

    // === Generate camera ray ===
    float2 uv = float2(float(x), float(y));
    float aspect = float(params->image_width) / float(params->image_height);
    float2 ndc = (uv - 0.5f * float2(float(params->image_width), float(params->image_height))) / float(params->image_height);
    const float fov = 0.70021f;
    float3 rd = normalize(params->cam_fwd + ndc.x/aspect*fov*params->cam_right + ndc.y*fov*params->cam_up);

    // === Gravitational lensing of star directions ===
    // For each pixel, deflect the camera ray by the Schwarzschild deflection
    // so stars near the BH shadow are displaced outward, forming Einstein rings.
    // Deflection formula (first + second order post-Newtonian):
    //   alpha = 4GM/(c^2 b) + 15*pi*G^2M^2/(4c^4 b^2)
    //         = 2*rs/b + 15*pi*rs^2/(16*b^2)
    // The lensed source direction is displaced OUTWARD from BH center.
    float3 ro = params->cam_pos;
    float ro_len = length(ro);
    float3 toBH = -ro;  // BH at origin
    float impact = length(cross(ro, rd)) / ro_len;

    // Shadow angular radius
    float shadow_cutoff = 5.0f * params->rs / ro_len;

    // --- Primary lensed direction (first + second order deflection) ---
    // Component of BH vector perpendicular to ray direction
    float3 perp = toBH - dot(toBH, rd) * rd;
    float perp_len = length(perp);
    float3 deflectDir = perp_len > 1e-8f ? perp / perp_len : float3(0);

    // Deflection angle — use impact parameter, clamp to avoid singularity
    float b = max(impact, params->rs * 0.35f);
    float rs = params->rs;
    float alpha1 = 2.0f * rs / b;                             // first order
    float alpha2 = 15.0f * 3.14159265f * rs * rs / (16.0f * b * b);  // second order
    float alpha  = alpha1 + alpha2;

    // For very small impact (close to shadow), cap deflection
    alpha = min(alpha, 0.15f);

    // Lensed direction: sample stars displaced OUTWARD from BH center
    // (light bent toward BH so the source we see is from beyond the apparent position)
    float3 lensedDir = normalize(rd - deflectDir * sin(alpha));

    // --- Secondary image: higher-order Einstein ring ---
    // Light looping near the photon sphere produces secondary images
    // at roughly double the deflection. Sample this too for the ring effect.
    float alpha3 = min(alpha * 1.8f, 0.25f);  // stronger deflection for secondary image
    float3 lensedDir2 = normalize(rd - deflectDir * sin(alpha3));

    // --- Tertiary image: even higher order (very close to shadow edge) ---
    float alpha4 = min(alpha * 2.5f, 0.35f);
    float3 lensedDir3 = normalize(rd - deflectDir * sin(alpha4));

    // === Sample stars at all three lensed directions ===
    // Primary image (dominant)
    float3 stars = sparsely_sample_stars(lensedDir);

    // Secondary image (fainter, creates Einstein ring double-image effect)
    float3 stars2 = sparsely_sample_stars(lensedDir2);

    // Tertiary image (even fainter, close to shadow edge)
    float3 stars3 = sparsely_sample_stars(lensedDir3);

    // --- Lensing brightness modulation ---
    // Near the shadow, amplification increases (magnification ~ 1/beta near critical curve)
    // Also, the secondary/tertiary images add an "Einstein ring" glow
    float angularDist = impact * ro_len;  // angular distance from BH center
    float shadowEdge = shadow_cutoff * ro_len;
    float nearShadow = max(0.0f, 1.0f - abs(angularDist - shadowEdge) / (shadowEdge * 0.5f));
    nearShadow = smoothstep(0.0f, 1.0f, nearShadow);

    // Secondary image weight: strongest very close to the shadow edge
    float secondaryWeight = nearShadow * nearShadow * 0.4f;
    float tertiaryWeight  = nearShadow * 0.15f;

    // Also boost primary star brightness in the lensed zone
    float lensingBoost = 1.0f + nearShadow * 1.5f;

    // Combine all images
    stars *= lensingBoost;
    stars += stars2 * secondaryWeight;
    stars += stars3 * tertiaryWeight;

    // --- Straight-direction sample (for pixels far from BH) ---
    // Blend in the straight-sky sample for pixels far from the shadow
    // to avoid warping stars that are far away
    float straightBlend = smoothstep(shadow_cutoff * 3.5f, shadow_cutoff * 5.0f, impact);
    float3 starsStraight = sparsely_sample_stars(rd);
    stars = mix(stars, starsStraight, straightBlend * 0.5f);

    // --- Shadow mask ---
    // Stars: killed inside shadow, smooth fade at edge
    float star_mask = smoothstep(shadow_cutoff * 0.95f, shadow_cutoff, impact);
    // Only blend stars where scene is dark
    float hdr_lum = dot(hdr, float3(0.299f, 0.587f, 0.114f));
    float star_strength = smoothstep(0.02f, 0.05f, 1.0f - min(hdr_lum, 1.0f));
    star_strength *= star_mask;
    hdr += stars * star_strength;

    // === FINAL TONE MAPPING + GAMMA ===
    float3 result = tone_map(hdr);

    // === GUARANTEE: force BH shadow interior to ABSOLUTE BLACK ===
    float hard_radius = shadow_cutoff * 0.8f;
    float soft_radius = shadow_cutoff * 1.3f;
    float fade = smoothstep(hard_radius, soft_radius, impact);
    result *= fade;

    scene_out.write(float4(result, 1.0f), uint2(x, y));
}
