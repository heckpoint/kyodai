shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform float inner_corner_radius_pixels = 0.0;  // Radius after total inset

uniform bool hide_background = false;
uniform float badge_size_ratio = 0.16;
uniform vec2 badge_aspect_ratio = vec2(1.0, 1.0);
uniform float badge_inner_radius = 0.0;
uniform vec4 badge_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float border_inset_pixels = 0.0;
uniform int badge_type = 0; // 0 = corner badge, 1 = top bar

// Icon uniforms
uniform sampler2D icon_texture : source_color;
uniform bool has_icon_texture = false;
uniform vec4 icon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float icon_padding = 0.5;

// Safe zone uniforms (set by GameCard for debugging)
uniform bool show_safe_zone = false;
uniform vec4 safe_zone = vec4(0.0, 0.0, 0.0, 0.0); // x, y, width, height in pixels (corner badge mode)
uniform vec4 safe_zone_top_bar = vec4(0.0, 0.0, 0.0, 0.0); // x, y, width, height in pixels (top bar mode)
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	if (hide_background && !has_icon_texture) {
		discard;
	}
	
	vec2 pixel_pos = UV * card_size;
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
	
	float badge_size_pixels = badge_size_ratio * card_size.x;
	
	float badge_width = badge_size_pixels * badge_aspect_ratio.x;
	float badge_height = badge_size_pixels * badge_aspect_ratio.y;
	
	// Draw badge based on type
	if (badge_type == 0) {
		// Corner badge (original implementation)
		// Offset by border_inset_pixels for inset positioning
		vec2 badge_origin = vec2(border_inset_pixels, border_inset_pixels);
		vec2 local_pos = pixel_pos - badge_origin;
		
		if (local_pos.x >= 0.0 && local_pos.x < badge_width && local_pos.y >= 0.0 && local_pos.y < badge_height) {
			float dist_left = local_pos.x;
			float dist_top = local_pos.y;
			bool outside_badge = local_pos.x >= badge_width || local_pos.y >= badge_height;
			float alpha_left = smoothstep(-aa_width, 0.0, dist_left);
			float alpha_top = smoothstep(-aa_width, 0.0, dist_top);
			float bounds_alpha = outside_badge ? 0.0 : 1.0;
			float badge_alpha = min(min(alpha_left, alpha_top), bounds_alpha);
			
		if (badge_inner_radius > 0.0) {
			float min_dimension = min(badge_width, badge_height);
			float max_radius = min_dimension * 0.5;
			float inner_radius = max_radius * clamp(badge_inner_radius, 0.0, 1.0);
			vec2 corner_center = vec2(badge_width - inner_radius, badge_height - inner_radius);
			bool in_corner_region = local_pos.x > badge_width - inner_radius && local_pos.y > badge_height - inner_radius;
				
				if (in_corner_region && inner_radius > 0.0) {
					float dist_from_center = length(local_pos - corner_center);
					if (dist_from_center > inner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(inner_radius - aa_width, inner_radius, dist_from_center);
						badge_alpha *= edge_alpha;
					}
				}
			}
			
			final_color = vec4(badge_color.rgb, badge_color.a * badge_alpha);
		}
	} else {
		// Top bar badge - full width at top
		float bar_height = badge_size_pixels;
		float card_width_pixels = card_size.x - border_inset_pixels * 2.0;
		// Offset by border_inset_pixels
		float local_y = pixel_pos.y - border_inset_pixels;
		
		if (local_y >= 0.0 && local_y < bar_height && pixel_pos.x >= border_inset_pixels && pixel_pos.x < card_width_pixels + border_inset_pixels) {
			// Top edge fade
			float alpha_top = smoothstep(-aa_width, 0.0, local_y);
			// Bottom edge fade
			float alpha_bottom = 1.0 - smoothstep(bar_height - aa_width, bar_height, local_y);
			float badge_alpha = min(alpha_top, alpha_bottom);
			
			// Apply rounded corners to bottom of bar
			if (badge_inner_radius > 0.0) {
				float max_radius = max(0.0, bar_height * 0.5);
				float corner_radius = max_radius * clamp(badge_inner_radius, 0.0, 1.0);
				
				float local_x = pixel_pos.x - border_inset_pixels;
				
				// Bottom left corner
				vec2 bl_corner_center = vec2(corner_radius, bar_height - corner_radius);
				// Bottom right corner
				vec2 br_corner_center = vec2(card_width_pixels - corner_radius, bar_height - corner_radius);
				
				// Check if in bottom left corner region
				if (local_x < corner_radius && local_y > bar_height - corner_radius) {
					float dist_bl = length(vec2(local_x, local_y) - bl_corner_center);
					if (dist_bl > corner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(corner_radius - aa_width, corner_radius, dist_bl);
						badge_alpha *= edge_alpha;
					}
				}
				
				// Check if in bottom right corner region
				if (local_x > card_width_pixels - corner_radius && local_y > bar_height - corner_radius) {
					float dist_br = length(vec2(local_x, local_y) - br_corner_center);
					if (dist_br > corner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(corner_radius - aa_width, corner_radius, dist_br);
						badge_alpha *= edge_alpha;
					}
				}
			}
			
			final_color = vec4(badge_color.rgb, badge_color.a * badge_alpha);
		}
	}
	
	// Clip to the inner media shape using shared shape parameters from MediaContainer.
	// total_inset_pixels combines border + glass insets, matching the base card clip.
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0);
	vec2 inner_offset = vec2(total_inset_pixels);
	
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	float inner_sdf = rounded_rect_sdf_pixels(inner_pixel_pos, inner_size, inner_corner_radius_pixels);
	
	float card_edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_sdf);
	final_color.a *= card_edge_alpha;
	
	// Draw icon within the safe zone
	if (has_icon_texture) {
		vec4 active_safe = badge_type == 0 ? safe_zone : safe_zone_top_bar;
		float safe_x = active_safe.x;
		float safe_y = active_safe.y;
		float safe_w = active_safe.z;
		float safe_h = active_safe.w;
		
		if (safe_w > 1.0 && safe_h > 1.0) {
			// Apply padding inside safe zone
			float padding = min(safe_w, safe_h) * icon_padding * 0.25;
			float icon_x = safe_x + padding;
			float icon_y = safe_y + padding;
			float icon_w = max(safe_w - padding * 2.0, 1.0);
			float icon_h = max(safe_h - padding * 2.0, 1.0);
			
			// Get texture dimensions for aspect ratio
			vec2 tex_size = vec2(textureSize(icon_texture, 0));
			float tex_aspect = tex_size.x / tex_size.y;
			float safe_aspect = icon_w / icon_h;
			
			// Fit icon maintaining aspect ratio (contain)
			float draw_w, draw_h;
			if (tex_aspect > safe_aspect) {
				draw_w = icon_w;
				draw_h = icon_w / tex_aspect;
			} else {
				draw_h = icon_h;
				draw_w = icon_h * tex_aspect;
			}
			
			// Center within padded safe zone
			float draw_x = icon_x + (icon_w - draw_w) * 0.5;
			float draw_y = icon_y + (icon_h - draw_h) * 0.5;
			
			// Check if current pixel is within icon draw rect
			if (pixel_pos.x >= draw_x && pixel_pos.x <= draw_x + draw_w &&
				pixel_pos.y >= draw_y && pixel_pos.y <= draw_y + draw_h) {
				// Convert to UV coordinates for icon texture
				vec2 icon_uv = vec2(
					(pixel_pos.x - draw_x) / draw_w,
					(pixel_pos.y - draw_y) / draw_h
				);
				
				vec4 tex_sample = texture(icon_texture, icon_uv);
				
				// Apply icon color (replace RGB, keep texture alpha - matches original icon_color_shader)
				vec4 icon_col = vec4(icon_color.rgb, tex_sample.a);
				
				// Composite icon on top of badge background
				final_color = vec4(
					mix(final_color.rgb, icon_col.rgb, icon_col.a),
					max(final_color.a, icon_col.a)
				);
			}
		}
	}
	
	// Debug: overlay safe zone in magenta for corner badge, cyan for top bar
	if (show_safe_zone) {
		if (badge_type == 0 && safe_zone.z > 0.0 && safe_zone.w > 0.0) {
			// Corner badge safe zone (magenta)
			if (pixel_pos.x >= safe_zone.x && pixel_pos.x <= safe_zone.x + safe_zone.z &&
				pixel_pos.y >= safe_zone.y && pixel_pos.y <= safe_zone.y + safe_zone.w) {
				final_color = mix(final_color, vec4(1.0, 0.0, 1.0, 0.6), 0.6);
			}
		} else if (badge_type == 1 && safe_zone_top_bar.z > 0.0 && safe_zone_top_bar.w > 0.0) {
			// Top bar safe zone (cyan)
			if (pixel_pos.x >= safe_zone_top_bar.x && pixel_pos.x <= safe_zone_top_bar.x + safe_zone_top_bar.z &&
				pixel_pos.y >= safe_zone_top_bar.y && pixel_pos.y <= safe_zone_top_bar.y + safe_zone_top_bar.w) {
				final_color = mix(final_color, vec4(0.0, 1.0, 1.0, 0.6), 0.6);
			}
		}
	}
	
	// Apply effect alpha
	final_color.a *= effect_alpha;
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color * COLOR;
}
