shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

// Swoop parameters
uniform vec4 swoop_color : source_color = vec4(0.06, 0.12, 0.3, 1.0);
uniform float swoop_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float swoop_height : hint_range(0.0, 0.8) = 0.5;  // Y position of the line (0 = bottom, 1 = top)
uniform float swoop_curve : hint_range(0.0, 1.0) = 0.3;  // Curve amount: 0 = flat, 1 = maximum dip
uniform float swoop_tilt : hint_range(-1.0, 1.0) = 0.0;   // Tilt: raises one side, lowers the other
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Swoop covers the full card edge (no border inset)
	// The border effect overlays on top at the outer edge
	vec2 swoop_size = card_size;
	vec2 swoop_offset = vec2(0.0);
	
	// Calculate SDF for the full card shape using precomputed radius
	vec2 swoop_pixel_pos = pixel_pos - swoop_offset;
	float sdf_dist = rounded_rect_sdf_pixels(swoop_pixel_pos, swoop_size, corner_radius_pixels);
	
	// Unified edge anti-aliasing — same formula as all other effects
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	float edge_alpha;
	if (display_mode == 0) {
		// Standard mode: hard edge — parent panel provides anti-aliasing
		if (sdf_dist > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		// Transparent / Media Only: smoothstep anti-aliasing (fade inward so parent clip doesn't cut it)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
		if (edge_alpha <= 0.0) { discard; }
	}
	
	// Base Y position of the swoop line (from bottom)
	// swoop_height: 0 = bottom of card, 1 = top of card
	float base_y = 1.0 - swoop_height;
	
	// Bezier-like curve that bends down
	// Uses a quadratic function: x * (2 - x) creates a curve that starts at 0, peaks at 1 (at x=1), then back to 0
	// But we want it to dip down, so we invert and shift
	float x = UV.x;
	
	// Create a curve that bends down from left to right
	// At x=0 (left): curve = 0
	// At x=0.5 (center): curve = maximum dip
	// At x=1 (right): curve = back to 0
	float curve_shape = 4.0 * x * (1.0 - x);  // Parabola: 0 at edges, 1 at center
	
	// Apply curve amount (positive = dips down, negative = rises up)
	float curve_offset = curve_shape * swoop_curve * 0.5;
	
	// Apply tilt - raises one side, lowers the other
	// (x - 0.5) goes from -0.5 on left to +0.5 on right
	float tilt_offset = (x - 0.5) * swoop_tilt * 0.5;
	
	// Calculate boundary Y position
	// Add curve_offset so positive values dip DOWN (increase Y)
	float boundary_y = base_y + curve_offset + tilt_offset;
	
	// Check if pixel is below the boundary (in the filled swoop area)
	// Hard edge with anti-aliasing - use fwidth for sharp but smooth edge
	float dist_to_boundary = UV.y - boundary_y;
	float boundary_aa = fwidth(dist_to_boundary) * 0.5;
	float is_in_swoop = smoothstep(-boundary_aa, boundary_aa, dist_to_boundary);
	
	// Fade alpha vertically from full intensity at the swoop boundary
	// down to zero at the bottom of the card (UV.y == 1.0).
	float swoop_range = 1.0 - boundary_y;
	float vertical_fade = 0.0;
	if (swoop_range > 0.0) {
		vertical_fade = clamp((1.0 - UV.y) / swoop_range, 0.0, 1.0);
	}
	
	// Apply intensity
	float alpha = is_in_swoop * vertical_fade * swoop_intensity;
	
	// Output the configured swoop color
	vec3 final_color = swoop_color.rgb;
	float final_alpha = alpha * edge_alpha * swoop_color.a * effect_alpha;

	COLOR = vec4(final_color, final_alpha) * COLOR;
}
