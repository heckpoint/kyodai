shader_type canvas_item;
render_mode unshaded;

// This pass reads the already-composited background. Blurring here avoids
// accumulating low-alpha RGB fringe pixels around transparent source icons.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float blur_radius : hint_range(0.0, 8.0) = 2.0;
uniform float bloom_radius : hint_range(0.0, 16.0) = 10.0;
uniform float bloom_strength : hint_range(0.0, 0.5) = 0.4;
uniform float bloom_threshold : hint_range(0.5, 1.0) = 0.95;

vec3 sample_bokeh(vec2 uv, float radius) {
    vec2 pixel_size = 1.0 / vec2(textureSize(screen_texture, 0));
    vec2 step_uv = pixel_size * (radius * 0.5);
    vec3 color = vec3(0.0);
    float total_weight = 0.0;

    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            vec2 kernel_pos = vec2(float(x), float(y));
            float weight = exp(-0.5 * dot(kernel_pos, kernel_pos) / (1.15 * 1.15));
            vec2 sample_uv = uv + kernel_pos * step_uv;
            color += texture(screen_texture, sample_uv).rgb * weight;
            total_weight += weight;
        }
    }

    return color / max(total_weight, 0.0001);
}

vec3 sample_bloom(vec2 uv) {
    vec2 pixel_size = 1.0 / vec2(textureSize(screen_texture, 0));
    vec2 step_uv = pixel_size * (bloom_radius * 0.5);
    vec3 color = vec3(0.0);
    float total_weight = 0.0;

    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            vec2 kernel_pos = vec2(float(x), float(y));
            float weight = exp(-0.5 * dot(kernel_pos, kernel_pos) / (1.15 * 1.15));
            vec3 sample_color = texture(screen_texture, uv + kernel_pos * step_uv).rgb;
            // Require every channel to be near white. This rejects the green-
            // tinted background and admits only direct-light overexposure.
            float white_floor = min(min(sample_color.r, sample_color.g), sample_color.b);
            float energy = smoothstep(bloom_threshold, 1.0, white_floor);
            color += sample_color * energy * weight;
            total_weight += weight;
        }
    }

    return color / max(total_weight, 0.0001);
}

void fragment() {
    vec3 blurred = sample_bokeh(SCREEN_UV, blur_radius);
    vec3 bloom = sample_bloom(SCREEN_UV);
    COLOR = vec4(clamp(blurred + bloom * bloom_strength, vec3(0.0), vec3(1.0)), 1.0);
}
