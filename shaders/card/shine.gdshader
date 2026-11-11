shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

// Animated diagonal shine sweep, adapted from oLe Studios' Highlight Shader
// (CC0) for the card effect stack: textureless overlay clipped to the card's
// rounded rect, angle-configurable, and effect_alpha aware for focus fades.

uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float speed : hint_range(0.0, 5.0) = 1.0;
uniform float line_width : hint_range(0.0, 0.5) = 0.15;
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 0.6);
uniform float pause_duration : hint_range(0.0, 5.0) = 0.5;
uniform float angle_degrees : hint_range(0.0, 180.0) = 45.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;

	// Clip to the card's rounded rect (same edge handling as gradient_overlay)
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	float dist_edge = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha;
	if (display_mode == 0) {
		if (dist_edge > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist_edge);
		if (edge_alpha <= 0.0) { discard; }
	}

	// Project the pixel onto the sweep direction, normalized so the band
	// travels the full diagonal regardless of card aspect or angle.
	vec2 dir = vec2(cos(radians(angle_degrees)), sin(radians(angle_degrees)));
	float p10 = card_size.x * dir.x;
	float p01 = card_size.y * dir.y;
	float p11 = p10 + p01;
	float proj_min = min(min(0.0, p10), min(p01, p11));
	float proj_max = max(max(0.0, p10), max(p01, p11));
	float band_t = (dot(pixel_pos, dir) - proj_min) / max(proj_max - proj_min, 0.001);

	// Sweep fully off-canvas on both ends, then dwell during the pause.
	float travel = 1.0 + 2.0 * line_width;
	float cycle_duration = travel + pause_duration;
	float adjusted_time = mod(TIME * speed, cycle_duration);
	float line_position = -line_width + min(adjusted_time, travel);

	float dist = abs(band_t - line_position);
	float line_intensity = smoothstep(line_width, 0.0, dist);

	vec4 shine = line_color;
	shine.a *= line_intensity * edge_alpha * effect_alpha;

	COLOR = shine * COLOR;
	if (COLOR.a <= 0.0) {
		discard;
	}
}
