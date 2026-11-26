shader_type canvas_item;
// Premultiplied emission keeps the colored core normally blended while the
// zero-alpha halo remains additive without creating a gray fringe.
render_mode unshaded, blend_premul_alpha;

// Neon stroke around a rounded rectangle. Glow is a distance falloff from the
// border, NOT a filled shadow silhouette, so card centers receive no tint.

uniform vec4 neon_color : source_color = vec4(1.0);
uniform vec2 quad_size = vec2(100.0);
uniform vec2 border_size = vec2(80.0);
uniform float corner_radius = 12.0;
uniform float stroke_width = 3.0;
uniform float glow_width = 8.0;
uniform float glow_strength = 0.6;
uniform float core_strength = 1.0;
uniform bool corner_mode = false;
uniform float corner_tick = 0.0;
uniform float corner_sweep = 1.5707963;
uniform bool gradient_enabled = false;
uniform float gradient_phase = 0.0;
uniform int gradient_color_count = 5;
uniform vec4 gradient_color_0 : source_color = vec4(0.10, 0.90, 1.00, 1.0);
uniform vec4 gradient_color_1 : source_color = vec4(0.20, 0.38, 1.00, 1.0);
uniform vec4 gradient_color_2 : source_color = vec4(0.58, 0.22, 1.00, 1.0);
uniform vec4 gradient_color_3 : source_color = vec4(1.00, 0.16, 0.65, 1.0);
uniform vec4 gradient_color_4 : source_color = vec4(1.00, 0.62, 0.18, 1.0);
uniform vec4 gradient_color_5 : source_color = vec4(0.10, 0.90, 1.00, 1.0);
uniform vec4 gradient_color_6 : source_color = vec4(0.10, 0.90, 1.00, 1.0);
uniform vec4 gradient_color_7 : source_color = vec4(0.10, 0.90, 1.00, 1.0);
uniform vec4 gradient_color_8 : source_color = vec4(0.10, 0.90, 1.00, 1.0);

float rounded_box_sdf(vec2 point, vec2 half_size, float radius) {
	vec2 q = abs(point) - half_size + vec2(radius);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

float segment_distance(vec2 point, vec2 a, vec2 b) {
	vec2 pa = point - a;
	vec2 ba = b - a;
	float t = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
	return length(pa - ba * t);
}

// Distance to one corner's arc and its two straight ticks. Clamping the
// angular coordinate includes the arc endpoint caps in the same distance
// field, so the glow feathers around caps instead of being clipped by a mask.
float corner_piece_distance(
	vec2 point,
	vec2 center,
	float radius,
	float base_angle,
	float sweep,
	float tick,
	vec2 tick_dir_0,
	vec2 tick_dir_1
) {
	float center_angle = base_angle + PI * 0.25;
	float half_sweep = sweep * 0.5;
	float a0 = center_angle - half_sweep;
	float a1 = center_angle + half_sweep;
	vec2 p0 = center + vec2(cos(a0), sin(a0)) * radius;
	vec2 p1 = center + vec2(cos(a1), sin(a1)) * radius;

	vec2 relative = point - center;
	float angle = atan(relative.y, relative.x);
	float delta = atan(sin(angle - center_angle), cos(angle - center_angle));
	float arc_angle = center_angle + clamp(delta, -half_sweep, half_sweep);
	vec2 closest_arc = center + vec2(cos(arc_angle), sin(arc_angle)) * radius;
	float distance = length(point - closest_arc);
	distance = min(distance, segment_distance(point, p0, p0 + tick_dir_0 * tick));
	distance = min(distance, segment_distance(point, p1, p1 + tick_dir_1 * tick));
	return distance;
}

float corner_path_distance(vec2 point, vec2 half_size, float radius) {
	vec2 corner = half_size - vec2(radius);
	float distance = corner_piece_distance(
		point, vec2(-corner.x, -corner.y), radius, PI,
		corner_sweep, corner_tick, vec2(0.0, 1.0), vec2(1.0, 0.0)
	);
	distance = min(distance, corner_piece_distance(
		point, vec2(corner.x, -corner.y), radius, PI * 1.5,
		corner_sweep, corner_tick, vec2(-1.0, 0.0), vec2(0.0, 1.0)
	));
	distance = min(distance, corner_piece_distance(
		point, corner, radius, 0.0,
		corner_sweep, corner_tick, vec2(0.0, -1.0), vec2(-1.0, 0.0)
	));
	distance = min(distance, corner_piece_distance(
		point, vec2(-corner.x, corner.y), radius, PI * 0.5,
		corner_sweep, corner_tick, vec2(1.0, 0.0), vec2(0.0, -1.0)
	));
	return distance;
}

// Inverse perimeter mapping matching FocusSubManager._perimeter_point(): start
// on the top straight after the top-left arc, then proceed clockwise.
float rounded_box_perimeter_t(vec2 point, vec2 half_size, float radius) {
	vec2 corner = half_size - vec2(radius);
	vec2 q = abs(point);
	float straight_w = max(half_size.x * 2.0 - radius * 2.0, 0.0);
	float straight_h = max(half_size.y * 2.0 - radius * 2.0, 0.0);
	float arc = radius * PI * 0.5;
	float total = 2.0 * (straight_w + straight_h) + 4.0 * arc;
	if (total <= 0.0) {
		return 0.0;
	}
	float distance = 0.0;
	if (q.x <= corner.x) {
		if (point.y < 0.0) {
			distance = point.x + half_size.x - radius;
		} else {
			distance = straight_w + 2.0 * arc + straight_h + half_size.x - radius - point.x;
		}
	} else if (q.y <= corner.y) {
		if (point.x > 0.0) {
			distance = straight_w + arc + point.y + half_size.y - radius;
		} else {
			distance = 2.0 * straight_w + 3.0 * arc + straight_h + half_size.y - radius - point.y;
		}
	} else {
		vec2 center = vec2(sign(point.x) * corner.x, sign(point.y) * corner.y);
		float angle = atan(point.y - center.y, point.x - center.x);
		if (point.x > 0.0 && point.y < 0.0) {
			distance = straight_w + (angle + PI * 0.5) * radius;
		} else if (point.x > 0.0) {
			distance = straight_w + arc + straight_h + angle * radius;
		} else if (point.y > 0.0) {
			distance = 2.0 * straight_w + 2.0 * arc + straight_h + (angle - PI * 0.5) * radius;
		} else {
			distance = 2.0 * straight_w + 3.0 * arc + 2.0 * straight_h + (angle + PI) * radius;
		}
	}
	return fract(distance / total);
}

vec3 gradient_color_at(int index) {
	if (index == 0) {
		return gradient_color_0.rgb;
	} else if (index == 1) {
		return gradient_color_1.rgb;
	} else if (index == 2) {
		return gradient_color_2.rgb;
	} else if (index == 3) {
		return gradient_color_3.rgb;
	} else if (index == 4) {
		return gradient_color_4.rgb;
	} else if (index == 5) {
		return gradient_color_5.rgb;
	} else if (index == 6) {
		return gradient_color_6.rgb;
	} else if (index == 7) {
		return gradient_color_7.rgb;
	}
	return gradient_color_8.rgb;
}

vec3 sample_gradient(float t) {
	int count = max(gradient_color_count, 1);
	float scaled = fract(t) * float(count);
	float f = smoothstep(0.0, 1.0, fract(scaled));
	int index = int(floor(scaled));
	int next_index = index + 1;
	if (next_index >= count) {
		next_index = 0;
	}
	// Linear crossfades stay between adjacent approved stops. Only the short
	// cluster boundaries mix roles; there is no hue-wheel traversal.
	return mix(gradient_color_at(index), gradient_color_at(next_index), f);
}

void fragment() {
	vec2 point = (UV - vec2(0.5)) * quad_size;
	vec2 half_size = border_size * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	float distance_to_border = corner_mode
		? corner_path_distance(point, half_size, radius)
		: abs(rounded_box_sdf(point, half_size, radius));
	// Cover the complete pixel footprint around the core. Narrower coverage
	// leaves visible stair-stepping on small rounded corners.
	float aa = max(fwidth(distance_to_border), 1.0);
	float core = (1.0 - smoothstep(
		max(stroke_width * 0.5 - aa, 0.0),
		stroke_width * 0.5 + aa,
		distance_to_border
	)) * core_strength;
	float glow_distance = distance_to_border;
	float falloff_width = max(glow_width, 0.001);
	float halo = exp(-glow_distance / falloff_width);
	// Preserve the large, soft tail. Feather it fully to zero before the draw
	// quad boundary at 3x glow_width so the outer radius remains smooth.
	float edge_fade = 1.0 - smoothstep(falloff_width * 1.5, falloff_width * 3.0, glow_distance);
	halo *= edge_fade * glow_strength;
	// Core alpha preserves destination coverage; halo RGB is emitted at zero
	// alpha so it adds light without washing the colored core out.
	float core_alpha = core * neon_color.a;
	float halo_alpha = (1.0 - core) * halo * neon_color.a;
	if (core_alpha <= 0.0 && halo_alpha <= 0.0) {
		discard;
	}
	vec3 local_color = neon_color.rgb;
	if (gradient_enabled) {
		float perimeter_t = rounded_box_perimeter_t(point, half_size, radius);
		local_color = sample_gradient(perimeter_t - gradient_phase);
	}
	COLOR = vec4(local_color * (core_alpha + halo_alpha), core_alpha);
}
