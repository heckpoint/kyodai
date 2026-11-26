shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float fit_margin = 1.0;

void fragment() {
	vec2 group_size = card_size + vec2(fit_margin * 2.0);
	vec2 pixel_pos = UV * group_size - vec2(fit_margin);
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float aa_width = max(fwidth(pixel_pos.x) + fwidth(pixel_pos.y), 0.5);
	float coverage = 1.0 - smoothstep(-aa_width, 0.0, dist);

	vec4 contents = textureLod(screen_texture, SCREEN_UV, 0.0);
	vec4 modulate = COLOR;
	// The group texture is already premultiplied. Preserve that representation
	// through the final coverage/modulation pass, including emissive RGB whose
	// alpha is zero (for example glass specular highlights).
	float output_weight = coverage * modulate.a;
	COLOR = vec4(contents.rgb * modulate.rgb * output_weight, contents.a * output_weight);
}
