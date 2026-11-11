shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : source_color, filter_linear, repeat_disable;

// Distortion parameters
uniform float distortion : hint_range(0.0, 1.0) = 0.5;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

vec2 distort(vec2 p, float dist_param, float aspect) {
	float d = length(p);
	float z = sqrt(dist_param + d * d * -dist_param);
	float r = atan(d, z) / 3.1415926535;
	float phi = atan(p.y, p.x);
	return vec2(r * cos(phi) * (1.0 / aspect) + 0.5, r * sin(phi) + 0.5);
}

vec2 spherical_distort(vec2 uv, float raw_distortion, vec2 size) {
	vec2 pixel_pos = uv * size;
	vec2 half_size = size * 0.5;
	float aspect = size.x / size.y;
	vec2 centered = (pixel_pos - half_size) / half_size;
	float max_dist = sqrt(aspect * aspect + 1.0);
	centered = centered / max_dist;
	centered.x *= aspect;
	
	float dist_param;
	if (raw_distortion < 0.5) {
		dist_param = mix(0.2, 1.0, raw_distortion * 2.0);
	} else {
		dist_param = mix(1.0, 1.5, (raw_distortion - 0.5) * 2.0);
	}
	
	return distort(centered, dist_param, aspect);
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Use the aperture assigned by the ordered geometry pass.
	float effective_border_inset = total_inset_pixels;
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
	// Calculate effective inner corner radius
	float inner_radius_pixels = max(0.0, corner_radius_pixels - effective_border_inset);
	float inner_radius_ratio = inner_radius_pixels / (min(inner_size.x, inner_size.y) / 2.0);
	
	// Offset pixel position for inset calculations
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	
	// Check if we're inside the area
	float sdf_dist = rounded_rect_sdf_ratio(inner_pixel_pos, inner_size, inner_radius_ratio);
	
	// Calculate edge anti-aliasing
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	float edge_alpha;
	if (display_mode == 0) {
		if (sdf_dist > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		// Fade inward so anti-aliasing stays within card bounds (parent clips children)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
		if (edge_alpha <= 0.0) { discard; }
	}
	
	// Zoom out input UVs so distortion pulls from a wider area of the texture
	// Apply zoom at BOTH extremes (distortion 0 and 1), not just distortion=1
	float zoom_out = 1.0 + abs(distortion - 0.5) * 0.4;
	vec2 zoomed_uv = (UV - 0.5) * zoom_out + 0.5;
	
	// Get distorted/warped UVs
	vec2 warped_uv = spherical_distort(zoomed_uv, distortion, card_size);
	
	// Apply precomputed UV transforms from MediaContainer so the distorted texture
	// aligns with the base image's visible crop.
	warped_uv = warped_uv * uv_transform_scale + uv_transform_offset;
	
	// Sample the distorted texture
	vec4 tex_color = texture(game_texture, warped_uv);
	
	// Apply opacity and effect alpha
	tex_color.a *= opacity * edge_alpha * effect_alpha;
	
	COLOR = tex_color * COLOR;
}
