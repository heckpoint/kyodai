shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : source_color, repeat_disable;
uniform float alpha = 1.0;  // Global alpha multiplier for fade animations

// Skeleton shimmer: replaces the texture sample while media is loading.
// Colors are pushed from M3Theme by BaseCardEffect so they track dark/light.
uniform float loading_active : hint_range(0.0, 1.0) = 0.0;
uniform vec4 loading_base_color : source_color = vec4(0.13, 0.125, 0.14, 1.0);
uniform vec4 loading_shimmer_color : source_color = vec4(0.32, 0.31, 0.34, 1.0);
uniform float loading_speed : hint_range(0.1, 5.0) = 2.2;
uniform float loading_angle_degrees : hint_range(-180.0, 180.0) = 25.0;
uniform float loading_shimmer_width : hint_range(0.02, 0.4) = 0.3;
uniform float loading_intensity : hint_range(0.0, 2.0) = 0.8;
uniform float loading_base_pulse : hint_range(0.0, 0.4) = 0.25;

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// The media area is inset by the total of border + glass insets (uniform)
	// plus case wrap insets (top/left only, asymmetric).
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0 + wrap_inset_left_pixels, total_inset_pixels * 2.0 + wrap_inset_top_pixels);
	vec2 inner_offset = vec2(total_inset_pixels + wrap_inset_left_pixels, total_inset_pixels + wrap_inset_top_pixels);
	bool has_insets = total_inset_pixels > 0.0 || wrap_inset_top_pixels > 0.0 || wrap_inset_left_pixels > 0.0;
	
	// Safety: extreme insets could collapse the inner area.
	if (inner_size.x <= 0.0 || inner_size.y <= 0.0) {
		discard;
	}
	
	// Calculate the outer edge (base card shape)
	// Use shared corner_radius_pixels from MediaContainer for consistent rounding
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	
	float edge_alpha;
	if (display_mode == 0) {
		// Standard mode: hard edge — parent panel provides anti-aliasing
		if (dist > 0.0) {
			discard;
		}
		edge_alpha = 1.0;
	} else {
		// Fade inward so anti-aliasing stays within card bounds (parent clips children)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		if (edge_alpha <= 0.0) {
			discard;
		}
	}
	
	// Calculate the inner edge (media area after border + glass insets)
	float inner_radius_pixels = max(0.0, corner_radius_pixels - total_inset_pixels);

	// Corners made interior by a case wrap inset go square: the banner's bottom
	// edge and spine's right edge are hard straight lines. Untouched corners
	// keep the concentric inner radius.
	bool wrap_top = wrap_inset_top_pixels > 0.0;
	bool wrap_left = wrap_inset_left_pixels > 0.0;
	vec4 inner_radii = vec4(
		(wrap_top || wrap_left) ? 0.0 : inner_radius_pixels,  // top-left
		wrap_top ? 0.0 : inner_radius_pixels,  // top-right
		inner_radius_pixels,  // bottom-right
		wrap_left ? 0.0 : inner_radius_pixels  // bottom-left
	);

	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	float inner_sdf_dist = rounded_rect_sdf_corners(inner_pixel_pos, inner_size, inner_radii);
	float inner_edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_sdf_dist);
	
	// Clip the base card to the inset media shape
	if (has_insets && inner_edge_alpha <= 0.0) {
		discard;
	}
	
	vec2 inner_uv = inner_pixel_pos / inner_size;

	vec4 tex_color;
	if (loading_active > 0.5) {
		// Skeleton shimmer: gentle base pulse plus a Gaussian glint sweep,
		// evaluated in media-local UV space so the sweep spans the panel.
		float pulse = (sin(TIME * loading_speed * 1.5) * 0.5 + 0.5) * loading_base_pulse;
		vec3 dynamic_base = mix(loading_base_color.rgb, loading_shimmer_color.rgb, pulse);

		vec2 sweep_dir = vec2(cos(radians(loading_angle_degrees)), sin(radians(loading_angle_degrees)));
		float proj = dot(inner_uv - vec2(0.5), sweep_dir);
		float period = 2.2;
		float sweep_pos = mod(TIME * loading_speed, period) - 1.1;
		float norm_dist = (proj - sweep_pos) / loading_shimmer_width;
		float wave = exp(-0.5 * norm_dist * norm_dist) * loading_intensity;

		tex_color = vec4(mix(dynamic_base, loading_shimmer_color.rgb, wave), 1.0);
	} else {
		// Use the precomputed UV transform from MediaContainer. The transform maps
		// inner media UV -> texture UV.
		vec2 tex_uv = inner_uv * uv_transform_scale + uv_transform_offset;
		tex_color = texture(game_texture, tex_uv);
	}
	
	// Combine outer edge alpha with inner inset alpha
	float final_alpha = edge_alpha;
	if (has_insets) {
		final_alpha = min(edge_alpha, inner_edge_alpha);
	}
	
	tex_color.a *= final_alpha * alpha;
	COLOR = tex_color * COLOR;
}
