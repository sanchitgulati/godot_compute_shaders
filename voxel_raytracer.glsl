#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std140) uniform CameraData {
    vec4 cam_pos;       // xyz = position, w = fov_radians
    vec4 cam_dir;       // xyz = forward direction, w = render_flags (bit 0: shadow, bit 1: refl, bit 2: floor, bit 3: studio)
    vec4 cam_up;        // xyz = up vector, w = edge_threshold (e.g. 0.06)
    vec4 cam_right;     // xyz = right vector, w = ambient_light (e.g. 0.28)
    vec4 grid_size;     // xyz = dimensions in voxels, w = max_steps
    vec4 light_dir;     // xyz = normalized light direction, w = edge_darken_strength (e.g. 0.45)
    vec4 screen_size;   // xy = resolution (w, h), z = floor_y (-0.02), w = exposure (1.1)
    vec4 post_process;  // x = gamma (2.2), y = saturation (1.35), z = contrast (1.15), w = sun_intensity (2.0)
    vec4 accum_params;  // x = current_spp, y = max_spp, z = light_spread (e.g. 0.20), w = enable_gi (1.0 or 0.0)
    vec4 extra_params;  // x = gi_bounces (1.0), y = gi_intensity (1.0), z = enable_accum (1.0 or 0.0), w = reserved
    vec4 bg_color;      // xyz = custom background color, w = use_custom_bg (1.0 or 0.0)
    vec4 floor_color;   // xyz = custom floor color, w = use_custom_floor (1.0 or 0.0)
} camera;

layout(set = 0, binding = 1, std430) readonly buffer VoxelGrid {
    uint voxels[];
};

layout(set = 0, binding = 2, rgba8) uniform writeonly image2D out_image;

layout(set = 0, binding = 3, std430) buffer AccumBuffer {
    vec4 accum_buffer[];
};


// =========================================================================
// Color Space Conversions
// =========================================================================
vec3 srgb_to_linear(vec3 c) {
    return pow(c, vec3(2.2));
}

vec3 linear_to_srgb(vec3 c, float gamma_val) {
    return pow(max(c, vec3(0.0)), vec3(1.0 / max(gamma_val, 0.1)));
}


// =========================================================================
// Random Number Generator (PCG Hash & Monte Carlo Sampling)
// =========================================================================
uint pcg_hash(inout uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand_float(inout uint rng) {
    return float(pcg_hash(rng)) * (1.0 / 4294967296.0);
}

vec2 rand_vec2(inout uint rng) {
    return vec2(rand_float(rng), rand_float(rng));
}

vec3 sample_cosine_hemisphere(vec3 n, inout uint rng) {
    vec2 r = rand_vec2(rng);
    float phi = 6.28318530718 * r.x;
    float cos_theta = sqrt(clamp(1.0 - r.y, 0.0, 1.0));
    float sin_theta = sqrt(clamp(r.y, 0.0, 1.0));

    vec3 local_dir = vec3(cos(phi) * sin_theta, cos_theta, sin(phi) * sin_theta);

    vec3 up = (abs(n.y) < 0.999) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, n));
    vec3 bitangent = cross(n, tangent);

    return normalize(tangent * local_dir.x + n * local_dir.y + bitangent * local_dir.z);
}

vec3 sample_sun_direction(vec3 l_dir, float spread, uint sample_idx, inout uint rng) {
    if (spread <= 0.001) {
        return l_dir;
    }
    // Vogel Golden Angle spiral for uniform low-discrepancy disc sampling
    // Golden angle = 2.39996323 rad (~137.508 deg)
    float golden_angle = 2.39996323;
    float dither = rand_float(rng);
    float r_dither = rand_float(rng);
    float n = float(sample_idx) + dither;
    float angle = n * golden_angle;
    // Fractional radius ensures progressive uniform coverage without clumping
    float radius = sqrt(fract(float(sample_idx) * 0.61803398875 + r_dither)) * spread;
    vec2 disk = vec2(radius * cos(angle), radius * sin(angle));

    vec3 up = (abs(l_dir.y) < 0.999) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 u_light = normalize(cross(l_dir, up));
    vec3 v_light = cross(l_dir, u_light);

    return normalize(l_dir + u_light * disk.x + v_light * disk.y);
}


// =========================================================================
// Sky & Atmosphere (Linear Color Space)
// =========================================================================
vec3 get_sky_color(vec3 ray_dir) {
    if (camera.bg_color.w > 0.5) {
        return srgb_to_linear(camera.bg_color.rgb);
    }

    bool is_studio = (int(camera.cam_dir.w + 0.5) & 8) != 0;
    if (is_studio) {
        // Project ray_dir onto camera right and up vectors to get view-relative screen coordinates
        float cx = dot(ray_dir, camera.cam_right.xyz);
        float cy = dot(ray_dir, camera.cam_up.xyz);
        float tan_half_fov = tan(camera.cam_pos.w * 0.5);
        vec2 screen_coord = vec2(cx, cy) / max(tan_half_fov * 1.6, 0.01);
        // Subtle warm vignette gradient matching studio paper backdrop
        float t = clamp(length(screen_coord - vec2(0.18, 0.05)), 0.0, 1.0);
        vec3 bg_center = srgb_to_linear(vec3(0.89, 0.79, 0.68));
        vec3 bg_edge   = srgb_to_linear(vec3(0.72, 0.64, 0.56));
        return mix(bg_center, bg_edge, pow(t, 1.35));
    }

    vec3 l_dir = normalize(camera.light_dir.xyz);

    float t = clamp(ray_dir.y * 0.5 + 0.5, 0.0, 1.0);
    // Linear sky colors
    vec3 horizon = srgb_to_linear(vec3(0.68, 0.78, 0.92));
    vec3 zenith = srgb_to_linear(vec3(0.15, 0.38, 0.82));
    vec3 sky = mix(horizon, zenith, pow(t, 0.75));

    // Sun disc and warm corona glow
    float sun_dot = max(dot(ray_dir, l_dir), 0.0);
    vec3 sun_col = srgb_to_linear(vec3(1.0, 0.95, 0.82)) * 6.0;
    sky += sun_col * pow(sun_dot, 512.0) * 12.0;
    sky += sun_col * pow(sun_dot, 32.0) * 0.5;

    // Darken below horizon
    if (ray_dir.y < 0.0) {
        sky = mix(sky, srgb_to_linear(vec3(0.04, 0.045, 0.05)), clamp(-ray_dir.y * 3.0, 0.0, 1.0));
    }
    return sky;
}


// =========================================================================
// Ray - AABB Intersection
// =========================================================================
bool ray_aabb_intersection(vec3 box_min, vec3 box_max, vec3 ro, vec3 rd, out float t_near, out float t_far) {
    vec3 inv_dir = 1.0 / max(abs(rd), vec3(1e-7)) * sign(rd);
    vec3 t0 = (box_min - ro) * inv_dir;
    vec3 t1 = (box_max - ro) * inv_dir;
    vec3 tmin = min(t0, t1);
    vec3 tmax = max(t0, t1);
    t_near = max(max(tmin.x, tmin.y), tmin.z);
    t_far = min(min(tmax.x, tmax.y), tmax.z);
    return t_far >= max(t_near, 0.0);
}


// =========================================================================
// Amanatides-Woo DDA Voxel Traversal
// =========================================================================
bool dda_voxel_grid(
    vec3 ro, vec3 rd, float max_dist,
    out float hit_dist, out vec3 hit_norm, out uint hit_vox, out ivec3 hit_cell
) {
    vec3 box_min = vec3(0.0);
    vec3 box_max = camera.grid_size.xyz;
    float t_near, t_far;
    if (!ray_aabb_intersection(box_min, box_max, ro, rd, t_near, t_far)) {
        return false;
    }
    if (t_near > max_dist) {
        return false;
    }

    vec3 ray_start = ro;
    if (t_near > 0.0) {
        ray_start = ro + rd * (t_near + 0.0001);
    }

    ivec3 g_size = ivec3(camera.grid_size.xyz);
    ivec3 map_pos = clamp(ivec3(floor(ray_start)), ivec3(0), g_size - 1);
    vec3 delta_dist = abs(1.0 / max(abs(rd), vec3(1e-7)));
    ivec3 step_dir = ivec3(sign(rd));

    vec3 side_dist;
    if (rd.x > 0.0) side_dist.x = (float(map_pos.x + 1) - ray_start.x) * delta_dist.x;
    else            side_dist.x = (ray_start.x - float(map_pos.x)) * delta_dist.x;
    if (rd.y > 0.0) side_dist.y = (float(map_pos.y + 1) - ray_start.y) * delta_dist.y;
    else            side_dist.y = (ray_start.y - float(map_pos.y)) * delta_dist.y;
    if (rd.z > 0.0) side_dist.z = (float(map_pos.z + 1) - ray_start.z) * delta_dist.z;
    else            side_dist.z = (ray_start.z - float(map_pos.z)) * delta_dist.z;

    int max_steps = int(camera.grid_size.w > 0.0 ? camera.grid_size.w : 384.0);
    int hit_axis = 0;
    bool found_hit = false;

    for (int i = 0; i < max_steps; i++) {
        int v_idx = map_pos.x + map_pos.y * g_size.x + map_pos.z * g_size.x * g_size.y;
        uint v = voxels[v_idx];
        if (v != 0u) {
            found_hit = true;
            hit_vox = v;
            hit_cell = map_pos;
            break;
        }

        if (side_dist.x < side_dist.y) {
            if (side_dist.x < side_dist.z) {
                side_dist.x += delta_dist.x;
                map_pos.x += step_dir.x;
                hit_axis = 0;
            } else {
                side_dist.z += delta_dist.z;
                map_pos.z += step_dir.z;
                hit_axis = 2;
            }
        } else {
            if (side_dist.y < side_dist.z) {
                side_dist.y += delta_dist.y;
                map_pos.y += step_dir.y;
                hit_axis = 1;
            } else {
                side_dist.z += delta_dist.z;
                map_pos.z += step_dir.z;
                hit_axis = 2;
            }
        }

        if (map_pos.x < 0 || map_pos.x >= g_size.x ||
            map_pos.y < 0 || map_pos.y >= g_size.y ||
            map_pos.z < 0 || map_pos.z >= g_size.z) {
            break;
        }
    }

    if (!found_hit) {
        return false;
    }

    vec3 norm = vec3(0.0);
    if (hit_axis == 0) norm.x = -float(step_dir.x);
    else if (hit_axis == 1) norm.y = -float(step_dir.y);
    else norm.z = -float(step_dir.z);
    hit_norm = norm;

    float d;
    if (hit_axis == 0) d = (float(hit_cell.x) - ro.x + (1.0 - float(step_dir.x)) * 0.5) / rd.x;
    else if (hit_axis == 1) d = (float(hit_cell.y) - ro.y + (1.0 - float(step_dir.y)) * 0.5) / rd.y;
    else d = (float(hit_cell.z) - ro.z + (1.0 - float(step_dir.z)) * 0.5) / rd.z;
    hit_dist = d;

    return (hit_dist < max_dist && hit_dist > 0.0);
}


// =========================================================================
// Raytraced Shadow Ray DDA
// =========================================================================
float trace_shadow(vec3 ro, vec3 rd, float max_dist) {
    vec3 box_min = vec3(0.0);
    vec3 box_max = camera.grid_size.xyz;
    float t_near, t_far;
    if (!ray_aabb_intersection(box_min, box_max, ro, rd, t_near, t_far)) {
        return 1.0;
    }

    vec3 ray_start = ro;
    if (t_near > 0.0) {
        ray_start += rd * (t_near + 0.0001);
    }

    ivec3 g_size = ivec3(camera.grid_size.xyz);
    ivec3 map_pos = clamp(ivec3(floor(ray_start)), ivec3(0), g_size - 1);
    vec3 delta_dist = abs(1.0 / max(abs(rd), vec3(1e-7)));
    ivec3 step_dir = ivec3(sign(rd));

    vec3 side_dist;
    if (rd.x > 0.0) side_dist.x = (float(map_pos.x + 1) - ray_start.x) * delta_dist.x;
    else            side_dist.x = (ray_start.x - float(map_pos.x)) * delta_dist.x;
    if (rd.y > 0.0) side_dist.y = (float(map_pos.y + 1) - ray_start.y) * delta_dist.y;
    else            side_dist.y = (ray_start.y - float(map_pos.y)) * delta_dist.y;
    if (rd.z > 0.0) side_dist.z = (float(map_pos.z + 1) - ray_start.z) * delta_dist.z;
    else            side_dist.z = (ray_start.z - float(map_pos.z)) * delta_dist.z;

    int max_steps = int(camera.grid_size.w > 0.0 ? camera.grid_size.w : 384.0);

    for (int i = 0; i < max_steps; i++) {
        int v_idx = map_pos.x + map_pos.y * g_size.x + map_pos.z * g_size.x * g_size.y;
        uint v = voxels[v_idx];
        if (v != 0u) {
            uint mat = (v >> 24u) & 0xFFu;
            if (mat == 4u) {
                return 0.55;
            }
            return 0.0;
        }

        if (side_dist.x < side_dist.y) {
            if (side_dist.x < side_dist.z) {
                side_dist.x += delta_dist.x;
                map_pos.x += step_dir.x;
            } else {
                side_dist.z += delta_dist.z;
                map_pos.z += step_dir.z;
            }
        } else {
            if (side_dist.y < side_dist.z) {
                side_dist.y += delta_dist.y;
                map_pos.y += step_dir.y;
            } else {
                side_dist.z += delta_dist.z;
                map_pos.z += step_dir.z;
            }
        }

        if (map_pos.x < 0 || map_pos.x >= g_size.x ||
            map_pos.y < 0 || map_pos.y >= g_size.y ||
            map_pos.z < 0 || map_pos.z >= g_size.z) {
            break;
        }
    }
    return 1.0;
}


// =========================================================================
// Scene Hit Structure
// =========================================================================
struct Hit {
    bool hit;
    bool is_floor;
    float dist;
    vec3 point;
    vec3 normal;
    vec3 albedo;
    uint mat;
    float roughness;
    float metallic;
    vec3 emission;
};


Hit trace_scene(vec3 ro, vec3 rd, float max_dist) {
    Hit h;
    h.hit = false;
    h.is_floor = false;
    h.dist = max_dist;
    h.point = vec3(0.0);
    h.normal = vec3(0.0, 1.0, 0.0);
    h.albedo = vec3(0.0);
    h.mat = 0u;
    h.roughness = 0.9;
    h.metallic = 0.0;
    h.emission = vec3(0.0);

    // 1. Trace voxel structure
    float v_dist;
    vec3 v_norm;
    uint v_data;
    ivec3 v_cell;
    bool hit_voxel = dda_voxel_grid(ro, rd, max_dist, v_dist, v_norm, v_data, v_cell);

    // 2. Trace ground plane at floor_y
    bool enable_floor = (int(camera.cam_dir.w + 0.5) & 4) != 0;
    float floor_y = camera.screen_size.z; // default ~ -0.02
    float f_dist = 1e9;
    if (enable_floor && rd.y < -1e-6) {
        float tf = (floor_y - ro.y) / rd.y;
        if (tf > 0.0) {
            f_dist = tf;
        }
    }

    if (hit_voxel && (v_dist < f_dist || f_dist >= 1e8)) {
        h.hit = true;
        h.is_floor = false;
        h.dist = v_dist;
        h.point = ro + rd * v_dist;
        h.normal = v_norm;

        uvec4 raw = uvec4(
            v_data & 0xFFu,
            (v_data >> 8u) & 0xFFu,
            (v_data >> 16u) & 0xFFu,
            (v_data >> 24u) & 0xFFu
        );
        vec3 srgb_col = vec3(raw.xyz) / 255.0;
        h.albedo = srgb_to_linear(srgb_col);
        h.mat = raw.w;

        if (h.mat == 2u) {
            // Emissive light source (lanterns, torches, campfires, sea lanterns)
            h.emission = h.albedo * 6.5;
            h.roughness = 0.35;
            h.metallic = 0.1;
        } else if (h.mat == 3u) {
            // Water
            h.roughness = 0.03;
            h.metallic = 0.08;
            h.albedo = srgb_to_linear(vec3(0.20, 0.45, 0.85));
        } else if (h.mat == 4u) {
            // Glass
            h.roughness = 0.05;
            h.metallic = 0.12;
        } else if (h.mat == 5u) {
            // Metal
            h.roughness = 0.20;
            h.metallic = 0.85;
        }
    } else if (enable_floor && f_dist < 10000.0 && f_dist > 0.0) {
        h.hit = true;
        h.is_floor = true;
        h.dist = f_dist;
        h.point = ro + rd * f_dist;
        h.normal = vec3(0.0, 1.0, 0.0);

        if (camera.floor_color.w > 0.5) {
            h.albedo = srgb_to_linear(camera.floor_color.rgb);
            h.mat = 0u;
            h.roughness = 0.95;
            h.metallic = 0.0;
            h.emission = vec3(0.0);
        } else {
            bool is_studio = (int(camera.cam_dir.w + 0.5) & 8) != 0;
        if (is_studio) {
            // Pure matte warm studio paper floor (Taichi: (1.0, 1.0, 1.0))
            h.albedo = srgb_to_linear(vec3(0.95, 0.89, 0.80));
            h.mat = 0u;
            h.roughness = 0.99;
            h.metallic = 0.0;
            h.emission = vec3(0.0);
        } else {
            // Dark, glossy studio floor with subtle tile grid (linear space)
            vec2 p = h.point.xz * 0.5;
            vec2 g = abs(fract(p) - 0.5);
            float is_line = step(0.485, max(g.x, g.y));

            vec3 floor_base = srgb_to_linear(vec3(0.07, 0.075, 0.085));
            vec3 floor_line = srgb_to_linear(vec3(0.12, 0.125, 0.14));
            h.albedo = mix(floor_base, floor_line, is_line);
            h.mat = 0u;
            h.roughness = 0.15; // Glossy reflective floor
            h.metallic = 0.15;
            h.emission = vec3(0.0);
        }
    }
}

    return h;
}


// =========================================================================
// Voxel Corner Ambient Occlusion
// =========================================================================
float compute_voxel_ao(ivec3 cell, vec3 norm, vec3 pt) {
    ivec3 g_size = ivec3(camera.grid_size.xyz);
    vec3 abs_n = abs(norm);
    vec3 tangent = (abs_n.x > 0.5) ? vec3(0, 1, 0) : vec3(1, 0, 0);
    vec3 bitangent = cross(norm, tangent);

    vec3 frac_p = fract(pt) - 0.5;
    float u = dot(frac_p, tangent);
    float v = dot(frac_p, bitangent);

    ivec3 adj1 = cell + ivec3(tangent * sign(u));
    ivec3 adj2 = cell + ivec3(bitangent * sign(v));
    ivec3 corner = cell + ivec3(tangent * sign(u) + bitangent * sign(v));

    bool occ1 = false;
    bool occ2 = false;
    bool occ_c = false;

    if (adj1.x >= 0 && adj1.x < g_size.x && adj1.y >= 0 && adj1.y < g_size.y && adj1.z >= 0 && adj1.z < g_size.z) {
        occ1 = (voxels[adj1.x + adj1.y * g_size.x + adj1.z * g_size.x * g_size.y] != 0u);
    }
    if (adj2.x >= 0 && adj2.x < g_size.x && adj2.y >= 0 && adj2.y < g_size.y && adj2.z >= 0 && adj2.z < g_size.z) {
        occ2 = (voxels[adj2.x + adj2.y * g_size.x + adj2.z * g_size.x * g_size.y] != 0u);
    }
    if (corner.x >= 0 && corner.x < g_size.x && corner.y >= 0 && corner.y < g_size.y && corner.z >= 0 && corner.z < g_size.z) {
        occ_c = (voxels[corner.x + corner.y * g_size.x + corner.z * g_size.x * g_size.y] != 0u);
    }

    float weight = clamp((abs(u) + abs(v)), 0.0, 1.0);
    float occl = 0.0;
    if (occ1 && occ2) {
        occl = 0.65;
    } else {
        occl = (float(occ1) + float(occ2) + float(occ_c)) * 0.22;
    }

    return clamp(1.0 - occl * weight, 0.25, 1.0);
}


// =========================================================================
// ACES Filmic Tone Mapping
// =========================================================================
vec3 tonemap_aces(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}


// =========================================================================
// Path Tracing Radiance Evaluation (Direct Light, Soft Shadows, GI Bounces)
// =========================================================================
vec3 compute_radiance(vec3 ray_pos, vec3 ray_dir, inout uint rng) {
    vec3 l_dir = normalize(camera.light_dir.xyz);
    float sun_int = camera.post_process.w;
    float amb_strength = camera.cam_right.w;
    bool is_studio = (int(camera.cam_dir.w + 0.5) & 8) != 0;

    vec3 sun_col;
    vec3 ambient;
    if (is_studio) {
        sun_col = srgb_to_linear(vec3(1.0, 0.82, 0.60)) * sun_int;
        ambient = srgb_to_linear(vec3(0.55, 0.50, 0.42)) * amb_strength;
    } else {
        sun_col = srgb_to_linear(vec3(1.0, 0.96, 0.88)) * sun_int;
        vec3 sky_amb = srgb_to_linear(vec3(0.24, 0.36, 0.52)) * amb_strength;
        vec3 gnd_amb = srgb_to_linear(vec3(0.09, 0.08, 0.08)) * amb_strength;
        ambient = mix(gnd_amb, sky_amb, 0.5);
    }

    Hit hit = trace_scene(ray_pos, ray_dir, 500.0);
    if (!hit.hit) {
        return get_sky_color(ray_dir);
    }

    // Stylized Voxel Edge Darkening
    float edge_mult = 1.0;
    if (!hit.is_floor && camera.light_dir.w > 0.0) {
        vec3 frac_p = fract(hit.point);
        float edge_thresh = camera.cam_up.w; // 0.06
        int edge_count = 0;
        if (frac_p.x < edge_thresh || frac_p.x > (1.0 - edge_thresh)) edge_count++;
        if (frac_p.y < edge_thresh || frac_p.y > (1.0 - edge_thresh)) edge_count++;
        if (frac_p.z < edge_thresh || frac_p.z > (1.0 - edge_thresh)) edge_count++;
        edge_mult = (edge_count >= 2) ? (1.0 - camera.light_dir.w) : 1.0;
    }

    // 1. Direct Sunlight with Quasi-Monte Carlo Multi-Sample Area Light
    float spread = camera.accum_params.z; // e.g. 0.18
    vec3 direct_sun = vec3(0.0);
    bool enable_shadows = (int(camera.cam_dir.w + 0.5) & 1) != 0;

    int shadow_samples = (spread > 0.01 && enable_shadows) ? (hit.is_floor ? 4 : 2) : 1;
    float shadow_sum = 0.0;
    float ndotl_sum = 0.0;
    uint cur_spp_val = uint(camera.accum_params.x);
    uint base_sample = cur_spp_val * uint(shadow_samples);

    for (int s = 0; s < shadow_samples; s++) {
        vec3 sun_sample_dir = sample_sun_direction(l_dir, spread, base_sample + uint(s), rng);
        float NdotL = max(dot(hit.normal, sun_sample_dir), 0.0);
        if (NdotL > 0.0) {
            float shadow = 1.0;
            if (enable_shadows) {
                shadow = trace_shadow(hit.point + hit.normal * 0.005, sun_sample_dir, 350.0);
            }
            shadow_sum += shadow * NdotL;
            ndotl_sum += NdotL;
        }
    }
    if (ndotl_sum > 0.0) {
        direct_sun = sun_col * (shadow_sum / float(shadow_samples));
    }

    // 2. Ambient Occlusion Fallback
    float ao = 1.0;
    if (!hit.is_floor) {
        ao = compute_voxel_ao(ivec3(floor(hit.point - hit.normal * 0.1)), hit.normal, hit.point);
    } else if (!is_studio) {
        vec2 b_min = vec2(0.0);
        vec2 b_max = camera.grid_size.xz;
        vec2 d = max(b_min - hit.point.xz, hit.point.xz - b_max);
        float dist_to_box = length(max(d, vec2(0.0)));
        ao = clamp(dist_to_box * 0.18 + 0.30, 0.30, 1.0);
    }

    bool enable_gi = (camera.accum_params.w > 0.5);
    float amb_factor = enable_gi ? (hit.is_floor ? 0.40 : 0.65) : 1.0;
    vec3 radiance = hit.albedo * (ambient * (ao * amb_factor) + direct_sun) * edge_mult + hit.emission;

    // 3. Specular Reflection (Secondary Ray Bounce for glass/water/glossy floor)
    bool enable_refl = (int(camera.cam_dir.w + 0.5) & 2) != 0;
    if (enable_refl) {
        float VoN = max(dot(-ray_dir, hit.normal), 0.0);
        float F0 = hit.metallic * 0.8 + 0.04;
        float fresnel = F0 + (1.0 - F0) * pow(1.0 - VoN, 5.0);
        float refl_factor = clamp(mix(fresnel, 1.0, hit.metallic) * (1.0 - hit.roughness * 0.65), 0.0, 0.85);

        if (refl_factor > 0.02) {
            vec3 refl_dir = reflect(ray_dir, hit.normal);
            Hit refl_hit = trace_scene(hit.point + hit.normal * 0.004, refl_dir, 250.0);
            vec3 refl_color;
            if (refl_hit.hit) {
                float r_NdotL = max(dot(refl_hit.normal, l_dir), 0.0);
                float r_shadow = ((int(camera.cam_dir.w + 0.5) & 1) != 0) ? trace_shadow(refl_hit.point + refl_hit.normal * 0.005, l_dir, 350.0) : 1.0;
                refl_color = refl_hit.albedo * (ambient + sun_col * r_NdotL * r_shadow) + refl_hit.emission;
            } else {
                refl_color = get_sky_color(refl_dir);
            }
            radiance = mix(radiance, refl_color, refl_factor);
        }
    }

    // 4. Global Illumination (Diffuse Indirect Bounces)
    int gi_bounces = int(camera.extra_params.x);
    float gi_intensity = camera.extra_params.y;
    if (enable_gi && gi_bounces >= 1 && hit.roughness > 0.1) {
        vec3 gi_throughput = hit.albedo * edge_mult * gi_intensity;
        vec3 cur_pos = hit.point;
        vec3 cur_norm = hit.normal;

        for (int b = 0; b < gi_bounces; b++) {
            vec3 bounce_dir = sample_cosine_hemisphere(cur_norm, rng);
            Hit bounce_hit = trace_scene(cur_pos + cur_norm * 0.006, bounce_dir, 200.0);

            if (!bounce_hit.hit) {
                // In outdoor mode, secondary rays hitting sky pick up sky lighting.
                // In studio mode, the paper backdrop is an unlit backdrop, not an emitter.
                if (!is_studio) {
                    radiance += gi_throughput * get_sky_color(bounce_dir);
                }
                break;
            }

            vec3 b_sun_dir = sample_sun_direction(l_dir, spread, cur_spp_val + uint(b), rng);
            float b_NdotL = max(dot(bounce_hit.normal, b_sun_dir), 0.0);
            vec3 b_direct = vec3(0.0);
            if (b_NdotL > 0.0) {
                float b_shadow = 1.0;
                if ((int(camera.cam_dir.w + 0.5) & 1) != 0) {
                    b_shadow = trace_shadow(bounce_hit.point + bounce_hit.normal * 0.005, b_sun_dir, 350.0);
                }
                b_direct = sun_col * b_NdotL * b_shadow;
            }

            vec3 b_amb = is_studio ? (ambient * 0.20) : (ambient * 0.25);
            radiance += gi_throughput * (bounce_hit.albedo * (b_direct + b_amb) + bounce_hit.emission);

            if (b + 1 < gi_bounces) {
                gi_throughput *= bounce_hit.albedo;
                cur_pos = bounce_hit.point;
                cur_norm = bounce_hit.normal;
            }
        }
    }

    // 5. Seamless Studio Cyclorama Sweep or Atmospheric Distance Fog
    if (is_studio) {
        if (hit.is_floor) {
            float sweep = smoothstep(230.0, 390.0, hit.dist);
            radiance = mix(radiance, get_sky_color(ray_dir), sweep);
        }
    } else {
        float fog = 0.0;
        if (hit.is_floor) {
            fog = smoothstep(80.0, 450.0, hit.dist);
        } else {
            fog = smoothstep(250.0, 600.0, hit.dist) * 0.35;
        }
        radiance = mix(radiance, get_sky_color(ray_dir), fog);
    }

    return clamp(radiance, vec3(0.0), vec3(60.0));
}


// =========================================================================
// Compute Main
// =========================================================================
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(camera.screen_size.x) || pixel.y >= int(camera.screen_size.y)) {
        return;
    }

    int p_idx = pixel.y * int(camera.screen_size.x) + pixel.x;
    float cur_spp = camera.accum_params.x;
    bool accum_active = (camera.extra_params.z > 0.5);

    // High quality per-pixel Monte Carlo RNG
    uint rng = uint(pixel.x) * 1973u + uint(pixel.y) * 9277u + uint(cur_spp) * 26699u + 1337u;
    pcg_hash(rng);

    // Subpixel jitter for smooth anti-aliased geometry when accumulating
    vec2 subpixel = (accum_active && cur_spp > 1.5) ? (rand_vec2(rng) - 0.5) : vec2(0.0);
    vec2 uv = (vec2(pixel) + 0.5 + subpixel) / camera.screen_size.xy;
    vec2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;

    float aspect = camera.screen_size.x / camera.screen_size.y;
    float tan_fov = tan(camera.cam_pos.w * 0.5);

    vec3 ray_dir = normalize(
        camera.cam_dir.xyz +
        camera.cam_right.xyz * (ndc.x * aspect * tan_fov) +
        camera.cam_up.xyz * (ndc.y * tan_fov)
    );
    vec3 ray_pos = camera.cam_pos.xyz;

    // Compute sample radiance
    vec3 sample_radiance = compute_radiance(ray_pos, ray_dir, rng);

    // Progressive Monte Carlo Accumulation
    vec4 prev_accum = (accum_active && cur_spp > 1.5) ? accum_buffer[p_idx] : vec4(0.0);
    vec4 cur_accum = prev_accum;
    if (cur_spp <= 1.5 || prev_accum.a < camera.accum_params.y) {
        cur_accum = prev_accum + vec4(sample_radiance, 1.0);
        if (accum_active) {
            accum_buffer[p_idx] = cur_accum;
        }
    }

    vec3 color = accum_active ? (cur_accum.rgb / max(cur_accum.a, 1.0)) : sample_radiance;

    // Color Grading & Tone Mapping Pipeline
    // 1. Exposure
    color *= camera.screen_size.w;

    // 2. ACES Filmic Tone Mapping
    color = tonemap_aces(color);

    // 3. Saturation Adjustment
    float sat = camera.post_process.y;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, sat);

    // 4. Contrast Adjustment around mid-gray 0.18
    float contrast = camera.post_process.z;
    color = max((color - 0.18) * contrast + 0.18, vec3(0.0));

    // 5. Gamma Correction (Linear to display space)
    float gamma_val = camera.post_process.x;
    color = linear_to_srgb(color, gamma_val);

    // 6. Subtle Cinematic Vignette
    vec2 screen_uv = (vec2(pixel) + 0.5) / camera.screen_size.xy;
    float v_dist = length(screen_uv - 0.5);
    float vignette = 1.0 - smoothstep(0.45, 0.90, v_dist) * 0.22;
    color *= vignette;

    imageStore(out_image, pixel, vec4(color, 1.0));
}
