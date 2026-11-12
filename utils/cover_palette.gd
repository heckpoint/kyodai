class_name CoverPalette
extends RefCounted

## Extracts a deterministic, three-color palette from cover artwork. Based on
## Argosy's region sampling and hue-family selection, extended with a tertiary
## color. All functions are safe to call from image worker threads.

const ALGORITHM_VERSION: int = 1
const SAMPLES_X: int = 12
const SAMPLES_Y: int = 18
const SAMPLE_RADIUS: int = 3
const MAX_SAMPLE_DIMENSION: int = 256
const COLOR_FAMILIES: int = 36
const MIN_SATURATION: float = 0.35
const MIN_VALUE: float = 0.15
const MIN_HUE_DISTANCE: float = 40.0
const SATURATION_BUMP: float = 0.45
const OUTPUT_MIN_VALUE: float = 0.8
const MIN_ALPHA: float = 0.05


static func extract(source: Image) -> Dictionary:
	if source == null or source.is_empty():
		return {}

	# Kyodai caches original artwork. Bound the sampling copy so huge covers do
	# not dominate worker time or memory; the cached file is never modified.
	var image: Image = source
	if maxi(source.get_width(), source.get_height()) > MAX_SAMPLE_DIMENSION:
		image = source.duplicate()
		var scale := float(MAX_SAMPLE_DIMENSION) / float(maxi(source.get_width(), source.get_height()))
		image.resize(
			maxi(1, int(round(source.get_width() * scale))),
			maxi(1, int(round(source.get_height() * scale))),
			Image.INTERPOLATE_BILINEAR
		)

	var samples: Array[Dictionary] = []
	for iy in range(1, SAMPLES_Y + 1):
		for ix in range(1, SAMPLES_X + 1):
			var center_x := image.get_width() * ix / (SAMPLES_X + 1)
			var center_y := image.get_height() * iy / (SAMPLES_Y + 1)
			var color := _average_pixel_region(image, int(center_x), int(center_y))
			if color.a < MIN_ALPHA or color.v < MIN_VALUE:
				continue
			samples.append({
				"color": Color(color.r, color.g, color.b, 1.0),
				"family": _hue_to_family(color.h * 360.0),
				"saturation": color.s,
			})

	if samples.is_empty():
		var neutral := Color(OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, 1.0)
		return {
			"primary": neutral,
			"secondary": neutral,
			"tertiary": neutral,
			"version": ALGORITHM_VERSION,
		}

	var threshold := _effective_saturation_threshold(samples)
	var all_families: Array = []
	var chosen_families: Array = []
	for i in range(COLOR_FAMILIES):
		all_families.append([] as Array[Color])
		chosen_families.append([] as Array[Color])

	var chosen_total := 0
	for sample in samples:
		var family: int = sample["family"]
		var color: Color = sample["color"]
		all_families[family].append(color)
		if float(sample["saturation"]) >= threshold:
			chosen_families[family].append(color)
			chosen_total += 1

	var has_saturated := chosen_total > 0
	var sorted_families: Array[int] = []
	for i in range(COLOR_FAMILIES):
		sorted_families.append(i)
	sorted_families.sort_custom(func(a: int, b: int) -> bool:
		var a_count: int = chosen_families[a].size() if has_saturated else all_families[a].size()
		var b_count: int = chosen_families[b].size() if has_saturated else all_families[b].size()
		if a_count == b_count:
			return a < b
		return a_count > b_count
	)

	var primary_family := _first_nonempty_family(sorted_families, all_families)
	var primary := _adjusted_family_average(primary_family, all_families, chosen_families, has_saturated)
	var secondary_family := _find_distinct_family(
		sorted_families, all_families, [primary_family], 1
	)
	var secondary: Color
	if secondary_family >= 0:
		secondary = _adjusted_family_average(secondary_family, all_families, chosen_families, has_saturated)
	else:
		secondary = _rotate_hue(primary, 180.0)

	var excluded: Array[int] = [primary_family]
	if secondary_family >= 0:
		excluded.append(secondary_family)
	var tertiary_family := _find_distinct_family(sorted_families, all_families, excluded, 1)
	var tertiary: Color
	if tertiary_family >= 0:
		tertiary = _adjusted_family_average(tertiary_family, all_families, chosen_families, has_saturated)
	else:
		tertiary = _best_triadic_fallback(primary, secondary)

	return {
		"primary": primary,
		"secondary": secondary,
		"tertiary": tertiary,
		"version": ALGORITHM_VERSION,
	}


static func extract_hex(source: Image) -> Dictionary:
	var palette := extract(source)
	if palette.is_empty():
		return {}
	return {
		"primary": "#" + (palette["primary"] as Color).to_html(false),
		"secondary": "#" + (palette["secondary"] as Color).to_html(false),
		"tertiary": "#" + (palette["tertiary"] as Color).to_html(false),
		"version": ALGORITHM_VERSION,
	}


static func _average_pixel_region(image: Image, center_x: int, center_y: int) -> Color:
	var red := 0.0
	var green := 0.0
	var blue := 0.0
	var alpha := 0.0
	var count := 0
	for dy in range(-SAMPLE_RADIUS, SAMPLE_RADIUS + 1):
		for dx in range(-SAMPLE_RADIUS, SAMPLE_RADIUS + 1):
			var x := clampi(center_x + dx, 0, image.get_width() - 1)
			var y := clampi(center_y + dy, 0, image.get_height() - 1)
			var pixel := image.get_pixel(x, y)
			if pixel.a < MIN_ALPHA:
				continue
			red += pixel.r
			green += pixel.g
			blue += pixel.b
			alpha += pixel.a
			count += 1
	if count == 0:
		return Color.TRANSPARENT
	return Color(red / count, green / count, blue / count, alpha / count)


static func _effective_saturation_threshold(samples: Array[Dictionary]) -> float:
	var threshold := MIN_SATURATION
	while threshold > 0.15:
		var qualifying := 0
		for sample in samples:
			if float(sample["saturation"]) >= threshold:
				qualifying += 1
		if float(qualifying) / float(samples.size()) >= 0.15:
			break
		threshold -= 0.05
	return maxf(0.15, threshold)


static func _hue_to_family(hue_degrees: float) -> int:
	var resolution := 360.0 / float(COLOR_FAMILIES)
	return clampi(int(fposmod(hue_degrees, 360.0) / resolution), 0, COLOR_FAMILIES - 1)


static func _family_distance(a: int, b: int) -> float:
	var difference := absi(a - b)
	return float(mini(difference, COLOR_FAMILIES - difference)) * (360.0 / float(COLOR_FAMILIES))


static func _first_nonempty_family(sorted_families: Array[int], all_families: Array) -> int:
	for family in sorted_families:
		if not all_families[family].is_empty():
			return family
	return 0


static func _find_distinct_family(
	sorted_families: Array[int],
	all_families: Array,
	excluded: Array[int],
	start_index: int
) -> int:
	for i in range(start_index, sorted_families.size()):
		var candidate := sorted_families[i]
		if all_families[candidate].is_empty() or candidate in excluded:
			continue
		var distinct := true
		for other in excluded:
			if other >= 0 and _family_distance(candidate, other) < MIN_HUE_DISTANCE:
				distinct = false
				break
		if distinct:
			return candidate
	return -1


static func _adjusted_family_average(
	family: int,
	all_families: Array,
	chosen_families: Array,
	has_saturated: bool
) -> Color:
	if family < 0:
		return Color(OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, 1.0)
	var colors: Array = chosen_families[family] if has_saturated else all_families[family]
	if colors.is_empty():
		colors = all_families[family]
	var color := _average_color_group(colors)
	return Color.from_hsv(
		color.h,
		clampf(color.s + SATURATION_BUMP, 0.0, 1.0),
		clampf(maxf(color.v, OUTPUT_MIN_VALUE), 0.0, 1.0),
		1.0
	)


static func _average_color_group(colors: Array) -> Color:
	if colors.is_empty():
		return Color(OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, OUTPUT_MIN_VALUE, 1.0)
	var red := 0.0
	var green := 0.0
	var blue := 0.0
	for color in colors:
		red += color.r
		green += color.g
		blue += color.b
	var count := float(colors.size())
	return Color(red / count, green / count, blue / count, 1.0)


static func _rotate_hue(color: Color, degrees: float) -> Color:
	return Color.from_hsv(fposmod(color.h * 360.0 + degrees, 360.0) / 360.0, color.s, color.v, 1.0)


static func _best_triadic_fallback(primary: Color, secondary: Color) -> Color:
	var best := _rotate_hue(primary, 120.0)
	var best_distance := _minimum_hue_distance(best, primary, secondary)
	var alternate := _rotate_hue(primary, 240.0)
	var alternate_distance := _minimum_hue_distance(alternate, primary, secondary)
	return alternate if alternate_distance > best_distance else best


static func _minimum_hue_distance(color: Color, a: Color, b: Color) -> float:
	var hue := color.h * 360.0
	var distance_a := absf(fposmod(hue - a.h * 360.0 + 540.0, 360.0) - 180.0)
	var distance_b := absf(fposmod(hue - b.h * 360.0 + 540.0, 360.0) - 180.0)
	return minf(distance_a, distance_b)
