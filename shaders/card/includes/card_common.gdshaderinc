// Shared card effect utilities — included by all card shaders

// Core shape uniforms used by nearly every effect
uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 0.0;
uniform float corner_radius_ratio = 0.06;
uniform float total_inset_pixels = 0.0;

// Case wrap insets: asymmetric strips claimed by the wrap (top banner, left spine)
uniform float wrap_inset_top_pixels = 0.0;
uniform float wrap_inset_left_pixels = 0.0;

// UV transform chain precomputed by BaseCardEffect (avoids re-deriving aspect math)
uniform vec2 uv_transform_scale = vec2(1.0, 1.0);
uniform vec2 uv_transform_offset = vec2(0.0, 0.0);

// Optional source-image transform. These affect texture sampling only; card
// shape, overlays, and compositor geometry remain in their original space.
uniform vec2 source_transform_x = vec2(1.0, 0.0);
uniform vec2 source_transform_y = vec2(0.0, 1.0);
uniform vec2 source_transform_origin = vec2(0.0);
uniform int source_transform_active = 0;

vec2 source_transform_pixel(vec2 pixel_pos) {
	vec2 local = pixel_pos - source_transform_origin;
	float determinant = source_transform_x.x * source_transform_y.y - source_transform_y.x * source_transform_x.y;
	if (abs(determinant) < 0.000001) {
		return pixel_pos;
	}
	return vec2(
		(source_transform_y.y * local.x - source_transform_y.x * local.y) / determinant,
		(-source_transform_x.y * local.x + source_transform_x.x * local.y) / determinant
	);
}

vec2 source_transform_uv(vec2 uv) {
	return source_transform_pixel(uv * card_size) / max(card_size, vec2(0.0001));
}

// Edge AA mode: 0 = hard discard (Standard), 1 = smoothstep AA (Transparent/Media Only)
uniform int display_mode = 0;

// Pixel-accurate rounded rect SDF (used by base, blur, border, badge, gradient)
float rounded_rect_sdf_pixels(vec2 pos, vec2 size, float radius_pixels) {
	vec2 half_size = size * 0.5;
	float radius = clamp(radius_pixels, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Ratio-based rounded rect SDF (used when caller already has a ratio)
float rounded_rect_sdf_ratio(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius_pixels = radius_ratio * min(size.x, size.y) / 2.0;
	// Clamp for safety — ratio > 1.0 would otherwise exceed the shape bounds
	radius_pixels = clamp(radius_pixels, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius_pixels));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius_pixels;
}

// Per-corner rounded rect SDF. radii: x = top-left, y = top-right,
// z = bottom-right, w = bottom-left (pixel units, y-down canvas space).
float rounded_rect_sdf_corners(vec2 pos, vec2 size, vec4 radii) {
	vec2 half_size = size * 0.5;
	vec2 q = pos - half_size;
	float radius = q.x < 0.0 ? (q.y < 0.0 ? radii.x : radii.w) : (q.y < 0.0 ? radii.y : radii.z);
	radius = clamp(radius, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(q) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Aspect-ratio preserving UV transform: fits `tex` inside `card` using cover semantics
vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	vec2 scale;
	if (card_aspect > tex_aspect) {
		scale = vec2(1.0, tex_aspect / card_aspect);
	} else {
		scale = vec2(card_aspect / tex_aspect, 1.0);
	}
	return (uv - 0.5) * scale + 0.5;
}

// Gradient sampling coordinate.
// Linear: 0 degrees = up, clockwise. Projection is normalized corner-to-corner
// so the ramp spans the full 0..1 range at any angle (exactly reproduces the
// old H/V/diagonal behavior at 90/180/135 degrees).
// Radial: vignette — t=0 at center, t=1 at corners (center -> edge).
float gradient_coord(vec2 uv, float angle_deg, bool radial) {
	if (radial) {
		return clamp(length(uv - 0.5) * 1.41421356, 0.0, 1.0);
	}
	float r = radians(angle_deg);
	vec2 dir = vec2(sin(r), -cos(r));
	return clamp(dot(uv - 0.5, dir) / (abs(dir.x) + abs(dir.y)) + 0.5, 0.0, 1.0);
}
