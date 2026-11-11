shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D gradient_texture : source_color, filter_linear, repeat_disable;
uniform float gradient_angle = 180.0;  // degrees, 0 = up, clockwise
uniform bool gradient_radial = false;  // vignette: center -> edge
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate anti-aliasing width
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Check if we're inside the card shape using SDF
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
	
	// Calculate gradient coordinate from angle (or radial vignette)
	float gradient_t = gradient_coord(UV, gradient_angle, gradient_radial);
	
	// Sample gradient
	vec4 gradient_color = texture(gradient_texture, vec2(gradient_t, 0.0));
	
	// Apply edge alpha and effect alpha
	gradient_color.a *= edge_alpha * effect_alpha;
	
	// Output the gradient color
	COLOR = gradient_color * COLOR;
	
	// Discard fully transparent pixels
	if (COLOR.a <= 0.0) {
		discard;
	}
}
