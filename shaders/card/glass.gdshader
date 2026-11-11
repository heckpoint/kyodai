shader_type canvas_item;
render_mode blend_add;

#include "res://shaders/card/includes/card_common.gdshaderinc"

// Glass parameters  
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);

// Specular parameters
uniform float specular_power : hint_range(1.0, 128.0) = 32.0;
uniform float specular_intensity : hint_range(0.0, 2.0) = 0.8;
uniform float light_angle : hint_range(0.0, 360.0) = 45.0;
uniform float light_height : hint_range(-0.5, 1.0) = 0.5;

// Bounce light parameters
uniform float bounce_intensity : hint_range(0.0, 1.0) = 0.4;
uniform float bounce_softness : hint_range(1.0, 8.0) = 3.0;

// Rim light parameters
uniform float rim_intensity : hint_range(0.0, 2.0) = 1.0;
uniform float rim_sharpness : hint_range(2.0, 10.0) = 5.0;

uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

// Simple and correct: spherical dome using SDF distance
vec3 calculate_dome_normal(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	
	// Get signed distance from edge (negative inside)
	float sdf_dist = rounded_rect_sdf_ratio(pos, size, radius_ratio);
	
	// Distance from edge (0 at edge, positive inside)
	float dist_from_edge = -sdf_dist;
	
	// Maximum distance
	float max_dist = min(size.x, size.y) * 0.5;
	
	// Normalize: 0 at edge, 1 at center
	float t = dist_from_edge / max_dist;
	t = clamp(t, 0.0, 0.99);
	
	// Calculate height on hemisphere: z = sqrt(1 - (1-t)^2)
	// This creates true spherical curvature rising from the edge
	float z = sqrt(1.0 - (1.0 - t) * (1.0 - t));
	
	// Calculate surface position for normal
	// Project from center toward edge based on t
	vec2 from_center = pos - half_size;
	float center_dist = length(from_center);
	
	vec2 surface_xy;
	if (center_dist < 0.001) {
		surface_xy = vec2(0.0);
	} else {
		// Scale to match the spherical surface at this height
		surface_xy = from_center / max_dist * (1.0 - t);
	}
	
	// Normal is the position on unit hemisphere
	return normalize(vec3(surface_xy.x, surface_xy.y, z));
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Glass covers the full card edge (no border inset for glass shape)
	// The border effect overlays on top at the outer edge
	vec2 glass_size = card_size;
	vec2 glass_pixel_pos = pixel_pos;
	
	// Use precomputed corner radius for consistent edge alignment with base/border
	float sdf_dist = rounded_rect_sdf_pixels(glass_pixel_pos, glass_size, corner_radius_pixels);
	
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
	
	// The ordered geometry pass assigns the inset visible at this layer.
	float total_image_inset = total_inset_pixels;
	vec2 image_area_size = card_size - vec2(total_image_inset * 2.0);
	vec2 image_area_offset = vec2(total_image_inset);
	
	// Calculate image area corner radius
	float image_area_radius_pixels = max(0.0, corner_radius_pixels - total_image_inset);
	float image_area_radius_ratio = 0.0;
	if (min(image_area_size.x, image_area_size.y) > 0.0) {
		image_area_radius_ratio = image_area_radius_pixels / (min(image_area_size.x, image_area_size.y) / 2.0);
	}
	
	// Check if inside image area (for alpha calculation only)
	vec2 image_pixel_pos = pixel_pos - image_area_offset;
	float image_sdf_dist = rounded_rect_sdf_ratio(image_pixel_pos, image_area_size, image_area_radius_ratio);
	float image_aa = 1.0 - smoothstep(-aa_width, 0.0, image_sdf_dist);
	
	// Calculate 3D dome normal from full card area
	// Compute ratio from precomputed pixels for consistency
	float glass_radius_ratio = corner_radius_pixels / (min(card_size.x, card_size.y) / 2.0);
	vec3 normal = calculate_dome_normal(glass_pixel_pos, glass_size, glass_radius_ratio);
	
	// Specular
	float angle_rad = radians(light_angle);
	float height_rad = light_height * 3.14159265359 * 0.5;
	
	vec3 light_dir = normalize(vec3(
		cos(angle_rad) * cos(height_rad),
		sin(angle_rad) * cos(height_rad),
		sin(height_rad)
	));
	
	vec3 view_dir = vec3(0.0, 0.0, 1.0);
	vec3 half_dir = normalize(light_dir + view_dir);
	float spec_angle = max(0.0, dot(normal, half_dir));
	float specular = pow(spec_angle, specular_power) * specular_intensity;
	
	// Bounce
	float bounce_angle_rad = radians(light_angle + 180.0);
	float bounce_height_rad = 0.25 * 3.14159265359 * 0.5;
	
	vec3 bounce_dir = normalize(vec3(
		cos(bounce_angle_rad) * cos(bounce_height_rad),
		sin(bounce_angle_rad) * cos(bounce_height_rad),
		sin(bounce_height_rad)
	));
	
	float bounce = max(0.0, dot(normal, bounce_dir));
	bounce = pow(bounce, bounce_softness) * bounce_intensity;
	
	// Colors
	vec3 specular_color = glass_color.rgb * 2.0;
	specular_color = clamp(specular_color, vec3(0.0), vec3(1.0));
	
	vec3 bounce_color = glass_color.rgb * 1.3;
	bounce_color = mix(bounce_color, vec3(1.0, 0.9, 0.7), 0.2);
	bounce_color = clamp(bounce_color, vec3(0.0), vec3(1.0));
	
	// Rim
	float fresnel = 1.0 - abs(dot(view_dir, normal));
	float opposite_light = 1.0 - max(0.0, dot(normal, light_dir));
	float rim = fresnel * opposite_light;
	rim = pow(rim, rim_sharpness) * rim_intensity;
	
	vec3 rim_color = glass_color.rgb * 3.0;
	rim_color = clamp(rim_color, vec3(0.0), vec3(1.0));
	
	// Calculate lights contribution (additive)
	vec3 lights = (specular_color * specular) + (bounce_color * bounce) + (rim_color * rim);
	
	// Add glass color tint (alpha-blended into the additive lights)
	vec3 glass_tint = glass_color.rgb * glass_color.a;
	
	// Final color: lights + glass tint
	vec3 final_rgb = lights + glass_tint;
	
	// Calculate lights intensity for alpha
	float lights_intensity = length(lights) + glass_color.a;
	
	// Final alpha:
	// - edge_alpha controls the outer glass shape
	// - image_aa controls where the base image shows through (0 in corners)
	// - lights always show through, even in corners
	float content_alpha = max(image_aa, lights_intensity);
	float final_alpha = edge_alpha * content_alpha * effect_alpha;
	
	COLOR = vec4(final_rgb, final_alpha) * COLOR;
}
