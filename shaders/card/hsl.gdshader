shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : source_color, repeat_disable;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

// HSL-style parameters (internally not HSL anymore)
uniform float hue_shift : hint_range(-1.0, 1.0) = 0.0;
uniform float saturation_scale : hint_range(0.0, 2.0) = 1.0;
uniform float lightness_scale : hint_range(0.0, 2.0) = 1.0;


void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float effective_inset = total_inset_pixels;
	
	vec2 inner_size = card_size - vec2(effective_inset * 2.0);
	vec2 inner_offset = vec2(effective_inset);
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha;
	if (display_mode == 0) {
		if (dist > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		// Fade inward so anti-aliasing stays within card bounds (parent clips children)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		if (edge_alpha <= 0.0) { discard; }
	}
	
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	vec2 inner_uv = inner_pixel_pos / inner_size;
	
	if (inner_uv.x < 0.0 || inner_uv.x > 1.0 || inner_uv.y < 0.0 || inner_uv.y > 1.0) {
		discard;
	}
	
	vec2 tex_uv = inner_uv * uv_transform_scale + uv_transform_offset;
	
	vec4 tex_color = texture(game_texture, tex_uv);
	
	
	// =========================
	// COLOR PROCESSING
	// =========================
	
	vec3 color = tex_color.rgb;
	
	// --- Linearize (important for correctness + fewer artifacts) ---
	color = pow(color, vec3(2.2));
	
	
	// --- HUE (YIQ rotation) ---
	vec3 yiq;
	yiq.x = dot(color, vec3(0.299, 0.587, 0.114));
	yiq.y = dot(color, vec3(0.596, -0.274, -0.322));
	yiq.z = dot(color, vec3(0.211, -0.523, 0.312));
	
	float angle = hue_shift * 3.14159265;
	float cosA = cos(angle);
	float sinA = sin(angle);
	
	float y = yiq.y;
	float z = yiq.z;

	yiq.y = y * cosA - z * sinA;
	yiq.z = y * sinA + z * cosA;
	
	color = vec3(
		dot(yiq, vec3(1.0, 0.956, 0.621)),
		dot(yiq, vec3(1.0, -0.272, -0.647)),
		dot(yiq, vec3(1.0, -1.106, 1.703))
	);
	
	
	// --- SATURATION (luma-based, with chroma protection) ---
	float luma = dot(color, vec3(0.299, 0.587, 0.114));
	float chroma = length(color - vec3(luma));
	float mask = smoothstep(0.02, 0.15, chroma);
	
	vec3 saturated = mix(vec3(luma), color, saturation_scale);
	color = mix(color, saturated, mask);
	
	
	// --- LIGHTNESS (exposure-style) ---
	color *= lightness_scale;
	
	
	// --- Back to sRGB ---
	color = pow(color, vec3(1.0 / 2.2));
	
	
	// --- Subtle dithering (reduces block artifacts) ---
	float noise = fract(sin(dot(UV, vec2(12.9898, 78.233))) * 43758.5453);
	color += (noise - 0.5) / 255.0;
	
	
	vec3 adjusted_color = color;
	
	
	// =========================
	// OUTPUT
	// =========================
	
	COLOR = vec4(adjusted_color, tex_color.a * edge_alpha * effect_alpha) * COLOR;
}