shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : source_color, repeat_disable;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

uniform float blur_strength : hint_range(0.0, 32.0) = 4.0;
uniform float blur_samples : hint_range(1.0, 24.0) = 8.0;
uniform float quality_scale = 1.0;

vec4 sample_blur(vec2 uv, vec2 tex_size) {
	vec4 color = vec4(0.0);
	float total = 0.0;
	
	float step_x = blur_strength / tex_size.x;
	float step_y = blur_strength / tex_size.y;
	int samples = int(blur_samples * quality_scale);
	
	for (int x = -samples; x <= samples; x++) {
		for (int y = -samples; y <= samples; y++) {
			vec2 offset = vec2(float(x) * step_x, float(y) * step_y);
			color += texture(game_texture, uv + offset);
			total += 1.0;
		}
	}
	
	return color / total;
}

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
	
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec4 tex_color = sample_blur(tex_uv, tex_size);
	
	COLOR = vec4(tex_color.rgb, tex_color.a * edge_alpha * effect_alpha) * COLOR;
}
