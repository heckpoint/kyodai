shader_type canvas_item;
render_mode blend_add;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform vec2 glow_margin = vec2(20.0, 20.0);
uniform float glow_radius = 20.0;
uniform float glow_intensity = 1.5;
uniform float blur_amount = 12.0;
uniform float threshold = 0.1;
uniform float glow_spread : hint_range(0.0, 0.5) = 0.05; // Expands glow outward like drop shadow
// Mip filtering must be opted into explicitly: the default canvas sampler
// clamps maxLod to 0, which would silently sample the base level.
uniform sampler2D game_texture : source_color, repeat_disable, filter_linear_mipmap;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float quality_scale = 1.0;

// Mip-pyramid blur (Steam-style): the mip chain is a proper box-filter
// downsample, so a 3x3 tent tap at a footprint-matched LOD yields a huge,
// smooth blur for 9 reads. The [1,2,1] tent weights composed with the
// mip's bilinear filtering form a quadratic B-spline (a partition of
// unity), so the result is provably ripple-free; fractional LOD blends
// between mips, keeping the footprint seamless. All taps contribute —
// thresholding happens AFTER the blur (see fragment): a per-tap binary
// gate carves a heavily blurred image into blobs with gaps.
vec3 sample_glow_blur_mip(vec2 uv, float lod, vec2 mip_texel) {
	vec3 sum = vec3(0.0);
	float weight_sum = 0.0;
	for (int x = -1; x <= 1; x++) {
		float weight_x = 1.0 - abs(float(x)) * 0.5;
		for (int y = -1; y <= 1; y++) {
			// Clamp to the cover edge rather than skipping out-of-bounds taps:
			// skipped taps exit one by one as the glow extends outward, and
			// each exit removes a discrete chunk of kernel weight — visible
			// as step-contour lines at wide (high-LOD) footprints.
			vec2 tap_uv = clamp(uv + vec2(float(x), float(y)) * mip_texel, 0.0, 1.0);
			float w = weight_x * (1.0 - abs(float(y)) * 0.5);
			sum += textureLod(game_texture, tap_uv, lod).rgb * w;
			weight_sum += w;
		}
	}
	return sum / max(weight_sum, 1e-4);
}

// Dense tent-weighted blur: grid coverage like the classic box kernel (so
// high-frequency cover detail averages out instead of aliasing into
// splotches), but with a bilinear-tent weighting (a box convolved with
// itself) for a smooth, band-free falloff. Taps clamp to the cover edge.
// Fallback for textures without a mip chain (placeholder art).
vec3 sample_glow_blur_dense(vec2 uv, vec2 tex_size) {
	vec3 sum = vec3(0.0);
	float weight_sum = 0.0;

	vec2 step_uv = blur_amount / tex_size;
	int blur_radius = int(12.0 * quality_scale);
	float radius_f = float(blur_radius) + 1.0;

	for (int x = -blur_radius; x <= blur_radius; x++) {
		float weight_x = 1.0 - abs(float(x)) / radius_f;
		for (int y = -blur_radius; y <= blur_radius; y++) {
			vec2 tap_uv = clamp(uv + vec2(float(x) * step_uv.x, float(y) * step_uv.y), 0.0, 1.0);
			float w = weight_x * (1.0 - abs(float(y)) / radius_f);
			sum += texture(game_texture, tap_uv).rgb * w;
			weight_sum += w;
		}
	}

	return sum / max(weight_sum, 1e-4);
}

vec3 sample_glow_blur(vec2 uv, vec2 tex_size) {
	// Mipmapped textures (all cached card art — the memory manager generates
	// the chain at load) take the cheap pyramid path.
	if (textureSize(game_texture, 1).x > 0) {
		// Footprint in base-lod texels is blur_amount * 12; pick the mip where
		// it spans ~4 texels, then 3x3-tap it at a 1-texel stride (the tent
		// kernel smooths the mip texel grid; the mip supplies the wide blur).
		float footprint = max(blur_amount * 12.0, 4.0);
		float lod = clamp(log2(footprint) - 2.0, 0.0, 7.0);
		vec2 mip_texel = pow(2.0, lod) / tex_size;
		return sample_glow_blur_mip(uv, lod, mip_texel);
	}
	return sample_glow_blur_dense(uv, tex_size);
}

void fragment() {
	// Identical coordinate system to drop_shadow.gdshader
	vec2 total_size = card_size + glow_margin * 2.0;
	vec2 pixel_pos = UV * total_size;
	
	// Center the card in the larger area (same as drop shadow)
	vec2 card_center = total_size * 0.5;
	vec2 local_pos = pixel_pos - card_center;
	
	// Convert to card-local coordinates for SDF and texture sampling
	vec2 card_half = card_size * 0.5;
	vec2 card_local_pos = local_pos + card_half;
	
	// Convert to normalized UV (0-1 within card bounds)
	vec2 card_uv = card_local_pos / card_size;
	
	// Calculate distance from card edge before doing any texture work. Most of
	// the quad is interior and can never contribute glow.
	float dist = rounded_rect_sdf_pixels(card_local_pos, card_size, corner_radius_pixels);
	float effective_radius = glow_radius * (1.0 - glow_spread);
	if (dist <= 0.0 || effective_radius <= 0.0) {
		discard;
	}

	vec2 tex_size = vec2(textureSize(game_texture, 0));
	
	// The base card image lives in the inner media area (after insets). Match it
	// so the glow comes from the same visible texture crop.
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0);
	vec2 inner_uv = (card_uv * card_size - vec2(total_inset_pixels)) / max(inner_size, vec2(1.0));
	vec2 tex_uv = inner_uv * uv_transform_scale + uv_transform_offset;
	
	// Get blurred texture only for exterior fragments.
	vec3 blurred = sample_glow_blur(tex_uv, tex_size);

	// Only show glow outside the card
	float glow_alpha = 0.0;
	if (dist > 0.0 && effective_radius > 0.0) {
		glow_alpha = 1.0 - smoothstep(0.0, effective_radius, dist);
		glow_alpha = clamp(glow_alpha, 0.0, 1.0);
	}

	// Soft-knee threshold on the BLURRED result (classic bloom threshold):
	// a smooth ramp keeps the halo continuous where a binary cutoff would
	// carve it into blobs with gaps.
	float lum = dot(blurred, vec3(0.2126, 0.7152, 0.0722));
	float knee = threshold <= 0.0 ? 1.0 : smoothstep(threshold - 0.1, threshold + 0.1, lum);

	// Apply intensity
	vec3 glow_color = blurred * (glow_intensity * knee);

	// Calculate brightness of glow for alpha
	glow_alpha *= lum * knee * glow_intensity * effect_alpha;

	COLOR = vec4(glow_color, glow_alpha) * COLOR;
}
