shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform float stroke_offset_pixels = 0.0;
uniform float stroke_width_pixels = 4.0;
uniform vec4 stroke_color : source_color = vec4(1.0);
uniform bool use_gradient = false;
uniform sampler2D gradient_texture : source_color, filter_linear, repeat_disable;
uniform float gradient_angle = 180.0;
uniform bool gradient_radial = false;
uniform bool fade_in = false;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	if (stroke_width_pixels <= 0.0) {
		discard;
	}
	vec2 pixel_pos = UV * card_size;
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float aa_width = max(fwidth(pixel_pos.x) + fwidth(pixel_pos.y), 0.5);

	// Distances are relative to the original outer silhouette. Adding the
	// ordered geometry depth produces concentric strokes without baking any
	// previous stroke or inset knowledge into this layer.
	float outer_dist = dist + stroke_offset_pixels;
	float inner_dist = outer_dist + stroke_width_pixels;
	float outer_alpha;
	if (display_mode == 0) {
		if (outer_dist > 0.0) {
			discard;
		}
		outer_alpha = 1.0;
	} else {
		outer_alpha = 1.0 - smoothstep(-aa_width, 0.0, outer_dist);
	}
	float inner_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_dist);
	float ring_alpha = max(outer_alpha - inner_alpha, 0.0);
	if (ring_alpha <= 0.0) {
		discard;
	}

	vec4 color = stroke_color;
	if (use_gradient) {
		float gradient_t = gradient_coord(UV, gradient_angle, gradient_radial);
		color = texture(gradient_texture, vec2(gradient_t, 0.0));
	}
	float fade_alpha = 1.0;
	if (fade_in) {
		fade_alpha = 1.0 - clamp(-outer_dist / stroke_width_pixels, 0.0, 1.0);
	}
	COLOR = vec4(color.rgb, color.a * ring_alpha * fade_alpha * effect_alpha) * COLOR;
}
