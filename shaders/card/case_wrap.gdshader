shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

// Wrap style template. 0 = PS3 banner (top gradient band with red divider),
// 1 = 3DO spine (left vertical gradient strip),
// 2 = Wii U swoop (curved top bar with tapered strokes).
// Additional case styles get new IDs and their own branch in fragment().
uniform int template_id = 0;

uniform sampler2D banner_gradient : source_color, filter_linear, repeat_disable;
uniform float banner_height_ratio : hint_range(0.02, 0.4) = 0.10;
uniform vec4 line_color : source_color = vec4(0.75, 0.05, 0.10, 1.0);
uniform float line_thickness_pixels : hint_range(0.0, 16.0) = 2.0;

uniform sampler2D spine_gradient : source_color, filter_linear, repeat_disable;
uniform float spine_width_ratio : hint_range(0.03, 0.4) = 0.12;

uniform vec4 swoop_color : source_color = vec4(0.07, 0.64, 0.78, 1.0);
uniform float swoop_edge_ratio : hint_range(0.0, 0.3) = 0.03;
uniform float swoop_center_ratio : hint_range(0.02, 0.4) = 0.10;
uniform float swoop_exponent : hint_range(0.5, 3.0) = 1.5;
uniform vec4 swoop_stroke_color : source_color = vec4(0.98, 0.94, 0.13, 1.0);
uniform float swoop_stroke_thickness : hint_range(0.0, 12.0) = 2.5;
uniform bool swoop_under_enabled = true;
uniform vec4 swoop_under_color : source_color = vec4(0.64, 0.62, 0.62, 1.0);

uniform vec4 wii_header_color : source_color = vec4(0.97, 0.97, 0.97, 1.0);
uniform float wii_header_ratio : hint_range(0.0, 0.3) = 0.08;
uniform float wii_cutout_start_ratio : hint_range(0.2, 0.9) = 0.55;
uniform float wii_cutout_depth_ratio : hint_range(0.0, 0.4) = 0.10;
uniform bool wii_stroke_enabled = true;
uniform vec4 wii_stroke_color : source_color = vec4(0.54, 0.56, 0.58, 1.0);
uniform float wii_stroke_thickness : hint_range(0.0, 12.0) = 1.5;

uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;

	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);

	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha;
	if (display_mode == 0) {
		if (dist > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		if (edge_alpha <= 0.0) { discard; }
	}

	vec4 out_color = vec4(0.0);

	if (template_id == 0) {
		float banner_height = card_size.y * banner_height_ratio;
		if (pixel_pos.y < banner_height) {
			out_color = texture(banner_gradient, vec2(UV.x, 0.0));

			// Red divider along the bottom edge of the band
			float line_top = banner_height - line_thickness_pixels;
			float line_alpha = smoothstep(line_top - aa_width, line_top + aa_width, pixel_pos.y);
			out_color = mix(out_color, line_color, line_alpha * line_color.a);
		} else {
			discard;
		}
	} else if (template_id == 1) {
		float spine_width = card_size.x * spine_width_ratio;
		if (pixel_pos.x < spine_width) {
			// Ramp reads bottom -> top (t=0 at the bottom edge)
			out_color = texture(spine_gradient, vec2(1.0 - UV.y, 0.0));
		} else {
			discard;
		}
	} else if (template_id == 2) {
		// Swoop curve: deepest at center, rising to the edges
		float nx = (UV.x - 0.5) * 2.0;
		float curve_term = pow(clamp(1.0 - nx * nx, 0.0, 1.0), swoop_exponent);
		float edge_h = card_size.y * swoop_edge_ratio;
		float center_h = card_size.y * swoop_center_ratio;
		float curve_y = edge_h + (center_h - edge_h) * curve_term;

		// Strokes taper to a point at the edges
		float taper = 1.0 - nx * nx;
		float yellow_bottom = curve_y + swoop_stroke_thickness * taper;
		float gray_bottom = yellow_bottom + swoop_stroke_thickness * 0.6 * taper;

		// Painter's order: understroke, yellow stroke, bar on top
		if (swoop_under_enabled) {
			float gray_alpha = 1.0 - smoothstep(gray_bottom - aa_width, gray_bottom + aa_width, pixel_pos.y);
			out_color = vec4(swoop_under_color.rgb, swoop_under_color.a * gray_alpha);
		}
		float yellow_alpha = 1.0 - smoothstep(yellow_bottom - aa_width, yellow_bottom + aa_width, pixel_pos.y);
		out_color = mix(out_color, swoop_stroke_color, yellow_alpha * swoop_stroke_color.a);
		float bar_alpha = 1.0 - smoothstep(curve_y - aa_width, curve_y + aa_width, pixel_pos.y);
		out_color = mix(out_color, swoop_color, bar_alpha * swoop_color.a);

		if (out_color.a <= 0.0) {
			discard;
		}
	} else if (template_id == 3) {
		// Full-width header band; right-side cutout dips below the band with an
		// S-curve (cubic smoothstep: flat tangents at both ends).
		float band_h = card_size.y * wii_header_ratio;
		float x0 = card_size.x * wii_cutout_start_ratio;
		float depth = card_size.y * wii_cutout_depth_ratio;

		float boundary_y = band_h;
		float t = 0.0;
		if (pixel_pos.x > x0) {
			t = clamp((pixel_pos.x - x0) / max(card_size.x - x0, 1.0), 0.0, 1.0);
			boundary_y = band_h + depth * (t * t * (3.0 - 2.0 * t));
		}

		// Painter's order: stroke below the boundary, header fill on top.
		// Stroke hugs the curve only; fades in at the cutout's start.
		if (wii_stroke_enabled) {
			float stroke_bottom = boundary_y + wii_stroke_thickness;
			float stroke_alpha = 1.0 - smoothstep(stroke_bottom - aa_width, stroke_bottom + aa_width, pixel_pos.y);
			stroke_alpha *= smoothstep(0.0, 0.08, t);
			out_color = vec4(wii_stroke_color.rgb, wii_stroke_color.a * stroke_alpha);
		}
		float header_alpha = 1.0 - smoothstep(boundary_y - aa_width, boundary_y + aa_width, pixel_pos.y);
		out_color = mix(out_color, wii_header_color, header_alpha * wii_header_color.a);

		if (out_color.a <= 0.0) {
			discard;
		}
	}

	out_color.a *= edge_alpha * effect_alpha;

	COLOR = out_color * COLOR;

	if (COLOR.a <= 0.0) {
		discard;
	}
}
