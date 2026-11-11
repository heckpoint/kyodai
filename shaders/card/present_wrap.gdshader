shader_type canvas_item;

// Internal "present wrap" overlay for downloaded-but-never-played games.
// All ribbon/bow geometry derives from s = min(card_size) so the wrap never
// stretches across the different media aspect ratios.

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform float inner_corner_radius_pixels = 0.0;

uniform vec4 paper_top_color : source_color = vec4(0.984, 0.984, 0.780, 1.0);    // #fbfbc7
uniform vec4 paper_bottom_color : source_color = vec4(0.976, 0.796, 0.290, 1.0); // #f9cb4a
uniform vec4 ribbon_color : source_color = vec4(0.937, 0.443, 0.282, 1.0);       // #ef7148
uniform vec4 knot_bottom_color : source_color = vec4(0.910, 0.298, 0.173, 1.0);  // #e84c2c
uniform vec4 tail_tip_color : source_color = vec4(0.953, 0.255, 0.376, 1.0);     // #f34160
uniform vec4 loop_inner_color : source_color = vec4(0.741, 0.220, 0.224, 1.0);   // #bd3839
uniform float ribbon_width_ratio = 0.155; // fraction of min(card_size)

uniform float unwrap_progress : hint_range(0.0, 1.0) = 0.0;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

vec2 rotate2d(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Approximate signed distance to a superellipse (n=2 ellipse, higher = boxier).
float superellipse_sdf(vec2 p, vec2 center, vec2 radii, float exponent, float angle) {
	vec2 q = rotate2d(p - center, angle);
	vec2 t = abs(q) / radii;
	float d = pow(pow(t.x, exponent) + pow(t.y, exponent), 1.0 / exponent) - 1.0;
	return d * min(radii.x, radii.y);
}

float box_sdf(vec2 p, vec2 center, vec2 half_size, float angle) {
	vec2 q = rotate2d(p - center, angle);
	vec2 d = abs(q) - half_size;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

// Ribbon tail: tapered strip (slightly narrower at the knot, wider at the
// tip). The swallowtail notch is cut separately in world space.
float tail_sdf(vec2 p, vec2 center, float half_len, float width_top, float width_tip, float angle) {
	vec2 q = rotate2d(p - center, angle);
	float t = clamp((q.y + half_len) / (2.0 * half_len), 0.0, 1.0);
	float w = mix(width_top, width_tip, t);
	vec2 d = vec2(abs(q.x) - w, abs(q.y) - half_len);
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

vec4 over(vec4 dst, vec4 src) {
	return vec4(mix(dst.rgb, src.rgb, src.a), max(dst.a, src.a));
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	float aa = max(fwidth(pixel_pos.x) + fwidth(pixel_pos.y), 0.5);

	// Clip to the inner media shape, matching the base card's edge handling:
	// hard edge in Standard mode, inward AA fade in Transparent/Media Only.
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0);
	vec2 inner_pos = pixel_pos - vec2(total_inset_pixels);
	float clip_sdf = rounded_rect_sdf_pixels(inner_pos, inner_size, inner_corner_radius_pixels);
	float clip_alpha;
	if (display_mode == 0) {
		if (clip_sdf > 0.0) {
			discard;
		}
		clip_alpha = 1.0;
	} else {
		clip_alpha = 1.0 - smoothstep(-aa, 0.0, clip_sdf);
		if (clip_alpha <= 0.0) {
			discard;
		}
	}

	float s = min(card_size.x, card_size.y);
	vec2 center = card_size * 0.5;
	float p = unwrap_progress;

	// --- Wrapping paper: vertical gradient ---
	float paper_alpha = 1.0 - smoothstep(0.30, 0.90, p);
	float grad = clamp(inner_pos.y / max(inner_size.y, 1.0), 0.0, 1.0);
	vec4 paper = mix(paper_top_color, paper_bottom_color, grad);
	vec4 col = vec4(paper.rgb, paper.a * paper_alpha);

	// --- Cross wrap: flat horizontal band under, vertical band over with the
	// same top-to-bottom gradient as the knot ---
	float ribbon_alpha = 1.0 - smoothstep(0.15, 0.65, p);
	float band_half = ribbon_width_ratio * s * 0.5;

	float h_dy = abs(pixel_pos.y - center.y);
	float h_edge = 1.0 - smoothstep(band_half - aa, band_half, h_dy);
	col = over(col, vec4(ribbon_color.rgb, ribbon_color.a * h_edge * ribbon_alpha));

	float v_dx = abs(pixel_pos.x - center.x);
	float v_edge = 1.0 - smoothstep(band_half - aa, band_half, v_dx);
	vec3 v_rgb = mix(ribbon_color.rgb, knot_bottom_color.rgb, grad);
	col = over(col, vec4(v_rgb, ribbon_color.a * v_edge * ribbon_alpha));

	// --- Bow: unties (loops spread/rotate, slight drop) and fades first ---
	float bow_alpha = 1.0 - smoothstep(0.0, 0.5, p);
	float spread = 1.0 + p * 1.4;
	vec2 bow_origin = center + vec2(0.0, p * 0.15 * s);
	vec2 bp = pixel_pos - bow_origin;

	// Shared bow geometry (loops tucked under the knot sides, tails steeper and
	// ending wider than the loops, knot matches the band width)
	float loop_offset = 0.24 * s * spread;
	vec2 loop_radii = vec2(0.20 * s, 0.14 * s);
	vec2 loop_center = vec2(0.0, -0.10 * s);
	float loop_angle = 0.22 + p * 0.9;
	float loop_exponent = 2.2;
	vec2 knot_half = vec2(band_half, 0.085 * s);
	float knot_radius = 0.03 * s;

	// Soft shadow conforming to the bottom silhouette of the loops + knot
	vec2 sp = bp - vec2(0.0, 0.045 * s);
	float sh_loop_l = superellipse_sdf(sp, vec2(-loop_offset, loop_center.y), loop_radii, loop_exponent, -loop_angle);
	float sh_loop_r = superellipse_sdf(sp, vec2(loop_offset, loop_center.y), loop_radii, loop_exponent, loop_angle);
	float sh_knot = rounded_rect_sdf_pixels(sp + knot_half, knot_half * 2.0, knot_radius);
	float shadow_d = min(min(sh_loop_l, sh_loop_r), sh_knot);
	float shadow_a = (1.0 - smoothstep(-0.02 * s, 0.05 * s, shadow_d)) * 0.28 * bow_alpha;
	col = over(col, vec4(0.35, 0.10, 0.05, shadow_a));

	// Tails: short, thick swallowtail ribbons with a pronounced taper,
	// emerging from either side of the knot, tips wider than the loops.
	// Gradient runs along each tail from the main red to the tip color.
	// The tip notch is one 90° step: horizontal leg starting at the outer
	// bottom corner, to a center point midway between the corners, then a
	// vertical riser straight down to the slanted bottom edge. The two tips
	// form upside-down Ls facing out: ‾| and |‾
	float tail_spread = 0.26 * s * spread;
	float tail_angle = 0.87 + p * 0.5;
	float tail_half_len = 0.26 * s;
	float tail_center_y = 0.15 * s;
	float tail_tip_w = 0.095 * s;
	vec2 tail_center_l = vec2(-tail_spread, tail_center_y);
	vec2 tail_center_r = vec2(tail_spread, tail_center_y);

	float tail_l = tail_sdf(bp, tail_center_l, tail_half_len, 0.06 * s, tail_tip_w, -tail_angle);
	// Bottom corners of the slanted tip: outer (local -x) and inner (local +x)
	vec2 outer_l = tail_center_l + rotate2d(vec2(-tail_tip_w, tail_half_len), tail_angle);
	vec2 inner_l = tail_center_l + rotate2d(vec2(tail_tip_w, tail_half_len), tail_angle);
	float riser_l = inner_l.x;
	float notch_l = box_sdf(bp, vec2(riser_l - s * 0.5, outer_l.y + s * 0.5), vec2(s * 0.5, s * 0.5), 0.0);
	tail_l = max(tail_l, -notch_l);
	vec2 ql = rotate2d(bp - tail_center_l, -tail_angle);
	float t_l = clamp((ql.y + tail_half_len) / (2.0 * tail_half_len), 0.0, 1.0);
	float tail_l_a = (1.0 - smoothstep(-aa, aa, tail_l)) * bow_alpha;
	col = over(col, vec4(mix(ribbon_color.rgb, tail_tip_color.rgb, t_l), ribbon_color.a * tail_l_a));

	float tail_r = tail_sdf(bp, tail_center_r, tail_half_len, 0.06 * s, tail_tip_w, tail_angle);
	vec2 outer_r = tail_center_r + rotate2d(vec2(tail_tip_w, tail_half_len), -tail_angle);
	vec2 inner_r = tail_center_r + rotate2d(vec2(-tail_tip_w, tail_half_len), -tail_angle);
	float riser_r = inner_r.x;
	float notch_r = box_sdf(bp, vec2(riser_r + s * 0.5, outer_r.y + s * 0.5), vec2(s * 0.5, s * 0.5), 0.0);
	tail_r = max(tail_r, -notch_r);
	vec2 qr = rotate2d(bp - tail_center_r, tail_angle);
	float t_r = clamp((qr.y + tail_half_len) / (2.0 * tail_half_len), 0.0, 1.0);
	float tail_r_a = (1.0 - smoothstep(-aa, aa, tail_r)) * bow_alpha;
	col = over(col, vec4(mix(ribbon_color.rgb, tail_tip_color.rgb, t_r), ribbon_color.a * tail_r_a));

	// Loops: soft flowing rounded petals leaning outward
	float loop_l = superellipse_sdf(bp, vec2(-loop_offset, loop_center.y), loop_radii, loop_exponent, -loop_angle);
	float loop_r = superellipse_sdf(bp, vec2(loop_offset, loop_center.y), loop_radii, loop_exponent, loop_angle);
	float loops_d = min(loop_l, loop_r);
	float loops_a = (1.0 - smoothstep(-aa, aa, loops_d)) * bow_alpha;
	// Light at the top of the loops, darker toward the knot
	float loop_shade = 1.06 - 0.28 * clamp((bp.y + 0.24 * s) / (0.4 * s), 0.0, 1.0);
	col = over(col, vec4(ribbon_color.rgb * loop_shade, ribbon_color.a * loops_a));

	// Inner loop openings (elongated dark slits low in the loop, nearly
	// horizontal, giving the loops a downward-facing look)
	vec2 hole_radii = vec2(0.15 * s, 0.042 * s);
	float hole_angle = 0.20 + p * 0.9;
	float hole_l = superellipse_sdf(bp, vec2(-0.215 * s * spread, -0.055 * s), hole_radii, 2.5, -hole_angle);
	float hole_r = superellipse_sdf(bp, vec2(0.215 * s * spread, -0.055 * s), hole_radii, 2.5, hole_angle);
	float holes_d = min(hole_l, hole_r);
	float holes_a = (1.0 - smoothstep(-aa, aa, holes_d)) * bow_alpha;
	col = over(col, vec4(loop_inner_color.rgb, loop_inner_color.a * holes_a));

	// Knot: rounded square centerpiece, vertical gradient main red -> darker red
	float knot_d = rounded_rect_sdf_pixels(bp + knot_half, knot_half * 2.0, knot_radius);
	float knot_a = (1.0 - smoothstep(-aa, aa, knot_d)) * bow_alpha;
	float knot_t = clamp((bp.y + knot_half.y) / (knot_half.y * 2.0), 0.0, 1.0);
	col = over(col, vec4(mix(ribbon_color.rgb, knot_bottom_color.rgb, knot_t), ribbon_color.a * knot_a));

	col.a *= clip_alpha * effect_alpha;
	if (col.a <= 0.0) {
		discard;
	}
	COLOR = col * COLOR;
}
