## Run with isolated user:// storage (the project autoloads open the database):
## XDG_DATA_HOME=/tmp/kyodai-palette-tests godot --headless --path . -s utils/run_cover_palette_tests.gd
extends SceneTree

const CoverPalette = preload("res://utils/cover_palette.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	_test_three_family_palette()
	_test_solid_and_tiny_images()
	_test_dark_and_transparent_images()
	_test_determinism_and_hex_contract()
	_test_large_image_downsampling()

	if _failures.is_empty():
		print("[CoverPaletteTests] All tests passed")
		quit(0)
	else:
		for failure in _failures:
			push_error("[CoverPaletteTests] " + failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _test_three_family_palette() -> void:
	# Strongest region first: red, then blue, then green. Boundary samples may
	# form extra families, but they cannot outnumber the three solid regions.
	var image := Image.create(120, 180, false, Image.FORMAT_RGBA8)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := Color(0.9, 0.05, 0.05, 1.0)
			if x >= 72 and x < 102:
				color = Color(0.05, 0.05, 0.9, 1.0)
			elif x >= 102:
				color = Color(0.05, 0.9, 0.05, 1.0)
			image.set_pixel(x, y, color)

	var palette := CoverPalette.extract(image)
	_expect(not palette.is_empty(), "multicolor image returns a palette")
	if palette.is_empty():
		return
	_expect(_hue_distance(palette["primary"], Color.RED) < 20.0, "primary selects the dominant red family")
	_expect(_hue_distance(palette["secondary"], Color.BLUE) < 20.0, "secondary selects the second blue family")
	_expect(_hue_distance(palette["tertiary"], Color.GREEN) < 20.0, "tertiary selects the third green family")
	_expect(_hue_distance(palette["primary"], palette["secondary"]) >= 40.0, "secondary respects hue spacing")
	_expect(_hue_distance(palette["primary"], palette["tertiary"]) >= 40.0, "tertiary respects primary hue spacing")
	_expect(_hue_distance(palette["secondary"], palette["tertiary"]) >= 40.0, "tertiary respects secondary hue spacing")


func _test_solid_and_tiny_images() -> void:
	var solid := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	solid.fill(Color(0.8, 0.1, 0.1, 1.0))
	var first := CoverPalette.extract(solid)
	var second := CoverPalette.extract(solid)
	_expect(not first.is_empty(), "1x1 image returns a palette")
	_expect(first == second, "1x1 extraction is deterministic")
	if not first.is_empty():
		for key in ["primary", "secondary", "tertiary"]:
			_expect((first[key] as Color).a == 1.0, key + " fallback is opaque")
		_expect(_hue_distance(first["primary"], first["secondary"]) >= 40.0, "solid-color secondary fallback is distinct")
		_expect(_hue_distance(first["primary"], first["tertiary"]) >= 40.0, "solid-color tertiary fallback is distinct")


func _test_dark_and_transparent_images() -> void:
	var dark := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	dark.fill(Color(0.01, 0.01, 0.01, 1.0))
	var dark_palette := CoverPalette.extract(dark)
	_expect(not dark_palette.is_empty(), "dark image uses a safe neutral palette")

	var transparent := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	transparent.fill(Color.TRANSPARENT)
	var transparent_palette := CoverPalette.extract(transparent)
	_expect(not transparent_palette.is_empty(), "transparent image uses a safe neutral palette")

	var empty := Image.new()
	_expect(CoverPalette.extract(empty).is_empty(), "empty image returns no palette")


func _test_determinism_and_hex_contract() -> void:
	var image := Image.create(32, 48, false, Image.FORMAT_RGBA8)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			image.set_pixel(x, y, Color.from_hsv(fposmod(x * 17.0 + y * 11.0, 360.0) / 360.0, 0.8, 0.8, 1.0))
	var first := CoverPalette.extract_hex(image)
	var second := CoverPalette.extract_hex(image)
	_expect(first == second, "hex extraction is deterministic")
	_expect(int(first.get("version", 0)) == CoverPalette.ALGORITHM_VERSION, "palette carries its algorithm version")
	for key in ["primary", "secondary", "tertiary"]:
		var encoded := str(first.get(key, ""))
		_expect(encoded.length() == 7 and encoded.begins_with("#") and Color.html_is_valid(encoded), key + " is #RRGGBB")


func _test_large_image_downsampling() -> void:
	var image := Image.create(1024, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.5, 0.9, 1.0))
	var palette := CoverPalette.extract(image)
	_expect(not palette.is_empty(), "wide oversized image is sampled without errors")


func _hue_distance(a: Color, b: Color) -> float:
	var difference := absf(fposmod(a.h * 360.0 - b.h * 360.0 + 540.0, 360.0) - 180.0)
	return difference
