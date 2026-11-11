shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform vec2 shadow_margin = vec2(100.0, 100.0);

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
uniform vec2 shadow_offset = vec2(0.0, 10.0); // pixels
uniform float shadow_softness = 8.0; // pixels
uniform float shadow_spread : hint_range(0.0, 1.0) = 0.0;
uniform float shadow_expand : hint_range(0.0, 0.5) = 0.02; // ratio of card width
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

// Anti-aliasing width in pixels (1.0 is usually enough)
const float aa_width = 1.5;

void fragment() {
	// The texture is larger than the card (includes margin for shadow)
	vec2 total_size = card_size + shadow_margin * 2.0;
	vec2 pixel_pos = UV * total_size;
	
	// Center the card in the larger area
	vec2 card_center = total_size * 0.5;
	vec2 local_pos = pixel_pos - card_center;
	
	// Calculate distance from the shadow-casting shape (offset card)
	// This gives us negative values inside the shape, positive outside
	// 1.0 ratio = corners touch (half of smallest dimension)
	float corner_radius = corner_radius_pixels;
	vec2 card_half = card_size * 0.5;
	float dist = rounded_rect_sdf_pixels(local_pos - shadow_offset + card_half, card_size, corner_radius);
	
	// Expand the shadow shape outward by the expand amount (as ratio of card width)
	// Convert ratio to pixels: shadow_expand * card_width
	float expand_pixels = shadow_expand * card_size.x;
	// Subtracting from distance makes the shape appear larger
	dist -= expand_pixels;
	
	// Apply softness by smoothing over the softness range
	// When softness is 0, this is a hard edge. When softness is high, it's a gradual fade.
	float shadow_alpha = 1.0 - smoothstep(-shadow_softness, 0.0, dist);
	
	// Apply spread (inset the shadow)
	if (shadow_spread > 0.0) {
		shadow_alpha = clamp((shadow_alpha - shadow_spread) / max(1e-4, 1.0 - shadow_spread), 0.0, 1.0);
	}
	
	// Mask out the card area itself (only show shadow outside)
	float card_edge_dist = rounded_rect_sdf_pixels(local_pos + card_half, card_size, corner_radius);
	float card_alpha = 1.0 - smoothstep(-aa_width, 0.0, card_edge_dist);
	
	// Shadow only appears outside the card
	shadow_alpha *= (1.0 - card_alpha);
	
	COLOR = vec4(shadow_color.rgb, shadow_color.a * shadow_alpha * effect_alpha) * COLOR;
}
