shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// CafeOS - TRUE 3D Alpha Extrusion with Flat Shading

uniform sampler2D icon_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform float time_scale : hint_range(0.0, 2.0) = 0.5;
uniform float orbit_radius : hint_range(1.0, 5.0) = 2.358;
uniform float icon_scale : hint_range(0.1, 1.5) = 0.7;
uniform float orbit_speed : hint_range(0.05, 1.0) = 0.15;
uniform int num_icons : hint_range(5, 30) = 21;
uniform float icon_opacity : hint_range(0.0, 1.0) = 0.6;
uniform vec4 icon_color : source_color = vec4(1.0);
uniform vec3 light_direction = vec3(-0.65, 0.8, -0.75);

uniform float rotation_speed : hint_range(0.0, 2.0) = 0.3;

// 3D Extrusion & Raymarching Settings
uniform float extrusion_depth : hint_range(0.001, 0.1) = 0.03;
uniform int max_ray_steps : hint_range(16, 256) = 16;
uniform float ray_step_size : hint_range(0.0001, 0.01) = 0.002;
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.3;
uniform float edge_softness : hint_range(0.0, 1.0) = 1.0;

uniform float blur_amount : hint_range(0.0, 0.02) = 0.012;
uniform int blur_kernel_size : hint_range(1, 7) = 6;  // Used by the re-raymarched blur loop below.

// Weighted silhouette test: pixels below alpha_threshold stay fully culled
// (matching the original hard cutoff), fading in only above it.
float hit_weight(float alpha) {
    return smoothstep(alpha_threshold,
                      alpha_threshold + max(edge_softness * 0.1, 0.01), alpha);
}

uniform float highlight_lift : hint_range(0.0, 1.0) = 0.06;

// Lighting Settings
uniform float light_ambient : hint_range(0.0, 5.0) = 0.62;
uniform float light_diffuse : hint_range(0.0, 5.0) = 0.36;
uniform float front_face_brightness : hint_range(0.0, 2.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
uniform float specular_shininess : hint_range(4.0, 128.0) = 40.0;
uniform float overexposure_strength : hint_range(0.0, 1.0) = 0.95;
uniform float overexposure_threshold : hint_range(0.0, 1.0) = 0.06;
uniform float split_light_strength : hint_range(0.0, 1.0) = 0.22;
uniform float bevel_strength : hint_range(0.0, 2.0) = 0.75;

// Anti-aliasing / Supersampling
uniform int supersample_level : hint_range(1, 4) = 2;

// Constants (don't change)
const float ICON_SIZE = 256.0;
const float ATLAS_WIDTH = 2304.0;
const float ATLAS_HEIGHT = 2048.0;
const float ICONS_PER_ROW = 9.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 hash3(vec2 p) {
    return vec3(hash(p), hash(p + vec2(1.0, 0.0)), hash(p + vec2(0.0, 1.0)));
}

vec3 spherical_to_cartesian(float theta, float phi, float radius) {
    return vec3(
        radius * sin(phi) * cos(theta),
        radius * cos(phi),
        radius * sin(phi) * sin(theta)
    );
}

vec4 sample_icon(int icon_index, vec2 uv, float lod_bias) {
    float row = floor(float(icon_index) / ICONS_PER_ROW);
    float icon_col = mod(float(icon_index), ICONS_PER_ROW);
    vec2 pixel_pos = vec2(
        icon_col * ICON_SIZE + uv.x * ICON_SIZE,
        row * (ICON_SIZE + 1.0) + uv.y * ICON_SIZE
    );
    vec4 col = textureLod(icon_atlas, pixel_pos / vec2(ATLAS_WIDTH, ATLAS_HEIGHT), lod_bias);
    // Keep straight RGB here. Alpha coverage is applied exactly once when
    // samples are accumulated in fragment().
    return col;
}

mat3 rotate_x(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, -s), vec3(0.0, s, c));
}

mat3 rotate_y(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(c, 0.0, s), vec3(0.0, 1.0, 0.0), vec3(-s, 0.0, c));
}

mat3 rotate_z(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(c, -s, 0.0), vec3(s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

// Optimized render_ray: analytic front-face intersection per icon (one sample)
// plus a short depth-slab march for extrusion side walls (<= max_ray_steps).
vec4 render_ray(vec2 uv, float aspect, float lod_bias) {
    vec3 camera_pos = vec3(0.0, 0.0, -4.0);
    vec3 ray_dir = normalize(vec3(uv.x * aspect, uv.y, 1.5));

    float time = TIME * orbit_speed * time_scale;
    vec3 light = normalize(light_direction);

    float closest_t = 9999.0;
    vec3 closest_normal = vec3(0.0, 0.0, 1.0);
    vec3 closest_world_pos = vec3(0.0);
    vec3 closest_color = vec3(0.0);
    float closest_alpha = 0.0;
    bool hit = false;

    for (int i = 0; i < num_icons && i < 12; i++) {
        float fi = float(i);
        vec3 seed_vec = hash3(vec2(fi, 0.0));

        float angular_jitter = (seed_vec.z - 0.5) * 0.65;
        float orbit_angle = time * (0.5 + seed_vec.x * 0.5) + fi * 6.28318 / float(num_icons) + angular_jitter;
        float phi = 1.57 + sin(time * 0.3 + fi) * 0.5 + (seed_vec.y - 0.5) * 0.35;
        float varied_radius = orbit_radius * (0.82 + hash(seed_vec.xy + vec2(7.0)) * 0.36);
        vec3 icon_center = spherical_to_cartesian(orbit_angle, phi, varied_radius);

        float rot_time = time * rotation_speed;
        float tilt_x = (seed_vec.x - 0.5) * 0.85 + sin(rot_time * 0.35 + fi) * 0.12;
        float tilt_y = (seed_vec.y - 0.5) * 0.85 + cos(rot_time * 0.25 + fi) * 0.12;
        mat3 rot_mat = rotate_z(seed_vec.z * 6.28318 + rot_time * 0.15) *
                      rotate_y(tilt_y) *
                      rotate_x(tilt_x);

        vec3 icon_right = rot_mat * vec3(1.0, 0.0, 0.0);
        vec3 icon_up = rot_mat * vec3(0.0, 1.0, 0.0);
        vec3 icon_normal = rot_mat * vec3(0.0, 0.0, 1.0);

        float size_variation = 0.65 + hash(seed_vec.xy) * 0.5;
        float scale = icon_scale * size_variation;
        int icon_index = int(floor(seed_vec.x * 72.0)) % 72;

        vec3 local_origin = vec3(
            dot(camera_pos - icon_center, icon_right),
            dot(camera_pos - icon_center, icon_up),
            dot(camera_pos - icon_center, icon_normal)
        );
        vec3 local_dir = vec3(
            dot(ray_dir, icon_right),
            dot(ray_dir, icon_up),
            dot(ray_dir, icon_normal)
        );

        vec3 box_min = vec3(-scale * 0.5, -scale * 0.5, -extrusion_depth);
        vec3 box_max = vec3(scale * 0.5, scale * 0.5, 0.0);

        vec3 inv_rd = 1.0 / local_dir;
        vec3 t1 = (box_min - local_origin) * inv_rd;
        vec3 t2 = (box_max - local_origin) * inv_rd;
        vec3 t_near = min(t1, t2);
        vec3 t_far = max(t1, t2);
        float t_start = max(max(t_near.x, t_near.y), t_near.z);
        float t_end = min(min(t_far.x, t_far.y), t_far.z);

        if (t_end <= max(t_start, 0.0)) continue;

        float t0 = max(t_start, 0.0);
        bool icon_hit = false;

        // --- Analytic front face (z = 0 plane): one sample, one alpha test ---
        if (abs(local_dir.z) > 1e-5) {
            float t_plane = -local_origin.z / local_dir.z;
            if (t_plane >= t0 && t_plane <= t_end) {
                vec3 pos = local_origin + local_dir * t_plane;
                vec2 uv_local = pos.xy / scale + 0.5;
                if (uv_local.x >= 0.0 && uv_local.x <= 1.0 &&
                    uv_local.y >= 0.0 && uv_local.y <= 1.0) {
                    vec4 col = sample_icon(icon_index, uv_local, lod_bias);
                    float w = hit_weight(col.a);
                    if (w > 0.0) {
                        vec3 world_pos = icon_center + icon_right * pos.x + icon_up * pos.y;
                        float world_t = length(world_pos - camera_pos);
                        if (world_t < closest_t) {
                            closest_t = world_t;
                            vec2 texel = vec2(1.0 / ICON_SIZE);
                            float alpha_left = sample_icon(icon_index, clamp(uv_local - vec2(texel.x, 0.0), vec2(0.0), vec2(1.0)), lod_bias).a;
                            float alpha_right = sample_icon(icon_index, clamp(uv_local + vec2(texel.x, 0.0), vec2(0.0), vec2(1.0)), lod_bias).a;
                            float alpha_down = sample_icon(icon_index, clamp(uv_local - vec2(0.0, texel.y), vec2(0.0), vec2(1.0)), lod_bias).a;
                            float alpha_up = sample_icon(icon_index, clamp(uv_local + vec2(0.0, texel.y), vec2(0.0), vec2(1.0)), lod_bias).a;
                            vec2 alpha_gradient = vec2(alpha_right - alpha_left, alpha_up - alpha_down);
                            closest_normal = normalize(icon_normal - (icon_right * alpha_gradient.x + icon_up * alpha_gradient.y) * bevel_strength);
                            closest_world_pos = world_pos;
                            closest_color = col.rgb;
                            closest_alpha = col.a * w;
                            hit = true;
                        }
                        icon_hit = true;
                    }
                }
            }
        }

        // --- Extrusion side walls: short march through the depth slab only ---
        if (icon_hit) continue;

        float slab_start = t0;
        float slab_end = t_end;
        if (abs(local_dir.z) > 1e-5) {
            float tz0 = -local_origin.z / local_dir.z;
            float tzd = -(local_origin.z + extrusion_depth) / local_dir.z;
            slab_start = max(t0, min(tz0, tzd));
            slab_end = min(t_end, max(tz0, tzd));
        }
        if (slab_end <= slab_start) continue;

        float slab_len = slab_end - slab_start;
        int steps = clamp(int(ceil(slab_len / ray_step_size)), 1, max_ray_steps);
        float step_size = slab_len / float(steps);
        float t = slab_start;

        for (int s = 0; s < steps; s++) {
            vec3 pos = local_origin + local_dir * t;
            vec2 uv_local = pos.xy / scale + 0.5;

            if (uv_local.x >= 0.0 && uv_local.x <= 1.0 &&
                uv_local.y >= 0.0 && uv_local.y <= 1.0) {
                vec4 col = sample_icon(icon_index, uv_local, lod_bias);
                float height = col.a * extrusion_depth;
                if (pos.z >= -height && pos.z <= 0.0) {
                    float w = hit_weight(col.a);
                    if (w > 0.0) {
                        vec3 world_pos = icon_center + icon_right * pos.x + icon_up * pos.y + icon_normal * pos.z;
                        float world_t = length(world_pos - camera_pos);
                        if (world_t < closest_t) {
                            closest_t = world_t;
                            // Flat-shaded wall normal from the dominant axis
                            closest_normal = abs(pos.x) > abs(pos.y) ? icon_right * sign(pos.x) : icon_up * sign(pos.y);
                            closest_world_pos = world_pos;
                            closest_color = col.rgb;
                            closest_alpha = col.a * w;
                            hit = true;
                        }
                        break;
                    }
                }
            }
            t += step_size;
        }
    }

    if (hit && closest_alpha > 0.0) {
        vec3 normal = normalize(closest_normal);
        vec3 view_dir = normalize(camera_pos - closest_world_pos);
        // The atlas' front plane points away from the camera in local space.
        // Use the view-facing side for both front faces and extruded walls.
        if (dot(normal, view_dir) < 0.0) {
            normal = -normal;
        }

        vec3 key_dir = normalize(light);
        vec3 fill_dir = normalize(vec3(-key_dir.x, -key_dir.y * 0.35, key_dir.z));
        float key_diffuse = max(dot(normal, key_dir), 0.0);
        float fill_diffuse = max(dot(normal, fill_dir), 0.0);

        const vec3 warm_light = vec3(1.0, 0.62, 0.40);
        const vec3 cool_light = vec3(0.38, 0.82, 0.88);
        float diffuse = light_ambient + light_diffuse * (key_diffuse + fill_diffuse * 0.35);
        vec3 split_tint = (warm_light - vec3(1.0)) * key_diffuse
                        + (cool_light - vec3(1.0)) * fill_diffuse * 0.65;
        vec3 lighting = vec3(diffuse) + split_tint * split_light_strength;

        float key_specular = pow(max(dot(normal, normalize(key_dir + view_dir)), 0.0), specular_shininess);
        float fill_specular = pow(max(dot(normal, normalize(fill_dir + view_dir)), 0.0), specular_shininess);
        vec3 specular = (warm_light * key_specular + cool_light * fill_specular * 0.45) * specular_strength;

        vec3 albedo = closest_color * icon_color.rgb;
        vec3 material_color = mix(albedo * lighting * front_face_brightness, vec3(1.0), highlight_lift);
        return vec4(material_color + specular, closest_alpha);
    }

    return vec4(0.0);
}

void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).x / (1.0 / SCREEN_PIXEL_SIZE).y;

    // Calculate pixel size for supersampling
    vec2 pixel_size = SCREEN_PIXEL_SIZE * 2.0; // UV range is -1 to 1

    // Premultiplied accumulation of icon rays; composited over layers beneath
    vec4 final_color = vec4(0.0);

    if (blur_amount > 0.0) {
        // Depth-of-field: 6x6 kernel of (now cheap, analytic) rays with proper
        // premultiplied blending to avoid dark fringes. Same offsets/width as
        // the original blur; affordable now that each ray costs ~2 fetches.
        float kernel_half = float(blur_kernel_size - 1) / 2.0;
        float weight_sum = 0.0;
        for (float x = -kernel_half; x <= kernel_half; x += 1.0) {
            for (float y = -kernel_half; y <= kernel_half; y += 1.0) {
                vec2 offset = vec2(x, y) * blur_amount * 0.5;
                // Gaussian-weighted coverage for the optional in-shader blur.
                float weight = exp(-0.25 * (x * x + y * y));
                vec4 sample = render_ray(uv + offset, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a) * weight;
                weight_sum += weight;
            }
        }
        final_color /= weight_sum;
    } else if (supersample_level <= 1) {
        // No blur, no supersampling - single sharp sample
        vec4 sample0 = render_ray(uv, aspect, 0.0);
        final_color = vec4(sample0.rgb * sample0.a, sample0.a);
    } else if (supersample_level == 2) {
        // 2x2 supersampling (4 samples)
        vec2 offsets[4] = vec2[](
            vec2(-0.25, -0.25),
            vec2( 0.25, -0.25),
            vec2(-0.25,  0.25),
            vec2( 0.25,  0.25)
        );
        for (int i = 0; i < 4; i++) {
            vec2 sample_uv = uv + offsets[i] * pixel_size;
            vec4 sample = render_ray(sample_uv, aspect, 0.0);
            final_color += vec4(sample.rgb * sample.a, sample.a);
        }
        final_color /= 4.0;
    } else if (supersample_level == 3) {
        // 3x3 supersampling (9 samples)
        for (float x = -1.0; x <= 1.0; x += 1.0) {
            for (float y = -1.0; y <= 1.0; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 3.0;
                vec4 sample = render_ray(sample_uv, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 9.0;
    } else {
        // 4x4 supersampling (16 samples)
        for (float x = -1.5; x <= 1.5; x += 1.0) {
            for (float y = -1.5; y <= 1.5; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 4.0;
                vec4 sample = render_ray(sample_uv, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 16.0;
    }

    // Specular energy beyond ordinary surface coverage marks a rare direct
    // light alignment. Preserve that peak as a near-white, high-opacity core;
    // the post-composite bright pass will supply the restrained outer bloom.
    float rgb_peak = max(max(final_color.r, final_color.g), final_color.b);
    float highlight_excess = max(rgb_peak - final_color.a, 0.0);
    float overexposed = smoothstep(overexposure_threshold, overexposure_threshold + 0.14, highlight_excess);

    // The accumulated color is premultiplied. Keep it that way through the
    // transparent SubViewport so its outer container can filter and composite
    // coverage without mixing icon RGB with transparent black.
    final_color *= icon_opacity;
    float peak_alpha = overexposed * overexposure_strength;
    final_color.a = max(final_color.a, peak_alpha);
    final_color.rgb = max(final_color.rgb, vec3(peak_alpha));
    COLOR = vec4(clamp(final_color.rgb, vec3(0.0), vec3(1.0)), clamp(final_color.a, 0.0, 1.0));
}
