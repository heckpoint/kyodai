## Writes fixture games and covers to user://. Always isolate storage first:
## XDG_DATA_HOME=/tmp/kyodai-palette-integration godot --headless --path . -s utils/run_cover_palette_integration_tests.gd
extends SceneTree

const CoverPalette = preload("res://utils/cover_palette.gd")

var _failures: Array[String] = []
var data_manager: Node
var game_script: GDScript
var memory_script: GDScript


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	data_manager = root.get_node("DataManager")
	var ready := await _wait_for_database()
	_expect(ready, "database becomes ready")
	if not ready:
		_finish()
		return
	game_script = load("res://base_class/abstract/game.gd")
	memory_script = load("res://managers/system_manager/memory_sub_manager.gd")

	var url_a := "https://example.test/shared.png"
	var url_b := "https://example.test/changed.png"
	var url_c := "https://example.test/worker.png"
	data_manager.database.query_bool("DELETE FROM games WHERE romm_id IN (?, ?)", [91001, 91002])
	for url in [url_a, url_b, url_c]:
		DirAccess.remove_absolute(data_manager.cover.get_cached_image_path(url))

	var game = _game(91001, url_a)
	_expect(_insert(game), "new game insert succeeds")

	var palette_a := {
		"url": url_a,
		"primary": "#ff0000",
		"secondary": "#00ff00",
		"tertiary": "#0000ff",
		"version": CoverPalette.ALGORITHM_VERSION,
	}
	_expect(await _update_palettes([palette_a]), "palette transaction succeeds")
	_expect_palette(91001, palette_a, "initial palette hydration")

	var same = _game(91001, url_a)
	_expect(_insert(same), "same-cover resync insert succeeds")
	_expect_palette(91001, palette_a, "same-cover resync preserves palette")

	var second = _game(91002, url_a)
	_expect(_insert(second), "shared-cover game insert succeeds")
	_expect_cleared(91002, "new shared-cover row starts without derived metadata")
	_expect(await _update_palettes([palette_a]), "shared URL palette transaction succeeds")
	_expect_palette(91001, palette_a, "shared URL updates first row")
	_expect_palette(91002, palette_a, "shared URL updates second row")

	var changed = _game(91001, url_b)
	_expect(_insert(changed), "changed-cover resync insert succeeds")
	_expect_cleared(91001, "changed-cover resync clears old palette")

	var palette_b := {
		"url": url_b,
		"primary": "#112233",
		"secondary": "#445566",
		"tertiary": "#778899",
		"version": CoverPalette.ALGORITHM_VERSION,
	}
	_expect(await _update_palettes([palette_b]), "changed URL palette transaction succeeds")
	_expect_palette(91001, palette_b, "changed URL stores new palette")

	var unrelated_edit = data_manager.database.get_game_by_id(91001)
	unrelated_edit.title = "Edited title"
	unrelated_edit.cover_primary_color = Color.TRANSPARENT
	unrelated_edit.cover_secondary_color = Color.TRANSPARENT
	unrelated_edit.cover_tertiary_color = Color.TRANSPARENT
	unrelated_edit.cover_colors_version = 0
	_expect(await _update_game(unrelated_edit), "unrelated game update succeeds")
	_expect_palette(91001, palette_b, "stale resource cannot wipe newest palette")
	_expect(data_manager.database.get_game_by_id(91001).title == "Edited title", "unrelated edit itself is retained")

	unrelated_edit = data_manager.database.get_game_by_id(91001)
	unrelated_edit.cover_url = url_c
	_expect(await _update_game(unrelated_edit), "cover-changing game update succeeds")
	_expect_cleared(91001, "cover-changing game update clears palette")

	var image := Image.create(64, 96, false, Image.FORMAT_RGBA8)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := Color(0.85, 0.1, 0.1, 1.0)
			if x >= 32 and x < 52:
				color = Color(0.1, 0.1, 0.85, 1.0)
			elif x >= 52:
				color = Color(0.1, 0.85, 0.1, 1.0)
			image.set_pixel(x, y, color)
	var cache_path: String = data_manager.cover.get_cached_image_path(url_c)
	_expect(image.save_png(cache_path) == OK, "fixture cover saves to isolated cache")
	_expect(await _run_palette_backfill(), "sync-thread palette backfill completes")
	# Simulate a stale sync-row invalidation while the first generation is in
	# flight. Its completion must retry rather than mark stale data successful.
	data_manager.cover.register_palette_candidates([url_c], true)
	var extracted := await _wait_for_palette(91001, url_c, 1500)
	_expect(extracted, "worker extraction persists before timeout")
	if extracted:
		var hydrated = data_manager.database.get_game_by_id(91001)
		_expect(hydrated.cover_colors_version == CoverPalette.ALGORITHM_VERSION, "worker stores current algorithm version")
		_expect(hydrated.cover_primary_color.a == 1.0 and hydrated.cover_secondary_color.a == 1.0 and hydrated.cover_tertiary_color.a == 1.0, "worker stores an opaque triad")

		var details_scene: PackedScene = load("res://components/sheets/game_details_sheet.tscn")
		var details = details_scene.instantiate()
		root.add_child(details)
		details._current_game = hydrated
		details._populate_metadata_chips(hydrated)
		_expect(is_instance_valid(details._palette_dots) and details._palette_dots.visible, "details subheader shows palette dots")
		_expect(details._palette_dots._colors.size() == 3, "details subheader renders all three palette colors")
		details._palette_dots.clear_colors()
		_expect(not details._palette_dots.visible, "details palette dots hide without a triad")
		details.queue_free()
		await process_frame

	_finish()


func _game(romm_id: int, cover_url: String):
	var game = game_script.new()
	game.id = str(romm_id)
	game.romm_id = romm_id
	game.title = "Palette Test %d" % romm_id
	game.platform = "Test"
	game.platform_slug = "test"
	game.cover_url = cover_url
	game.cover_path = "fixture.png"
	game.file_name = "fixture.rom"
	game.file_path = ""
	game.last_updated = "2026-01-01T00:00:00"
	game.has_cover_art = true
	return game


func _insert(game) -> bool:
	var statement: Dictionary = data_manager.sync._build_insert_query(game, {})
	return data_manager.database.query_bool(statement["query"], statement["bindings"])


func _update_palettes(palettes: Array) -> bool:
	var state := {"done": false, "success": false}
	data_manager.database.update_cover_palettes(palettes, func(success: bool):
		state["success"] = success
		state["done"] = true
	)
	while not state["done"]:
		await process_frame
	return state["success"]


func _update_game(game) -> bool:
	var state := {"done": false, "success": false}
	data_manager.database.update_game(game, func(success: bool):
		state["success"] = success
		state["done"] = true
	)
	while not state["done"]:
		await process_frame
	return state["success"]


func _run_palette_backfill() -> bool:
	var state := {"done": false, "success": false}
	memory_script.queue_sync_task(
		func():
			data_manager.sync._queue_backfill_cover_palettes()
			return true,
		func(result):
			state["success"] = result == true
			state["done"] = true
	)
	for i in range(600):
		if state["done"]:
			return state["success"]
		await process_frame
	return false


func _wait_for_database() -> bool:
	for i in range(600):
		if data_manager.database.is_database_ready():
			return true
		await process_frame
	return false


func _wait_for_palette(romm_id: int, cover_url: String, max_frames: int) -> bool:
	for i in range(max_frames):
		var game = data_manager.database.get_game_by_id(romm_id)
		if game and game.cover_colors_version >= CoverPalette.ALGORITHM_VERSION \
			and data_manager.cover._palette_succeeded_set.has(cover_url):
			return true
		await process_frame
	return false


func _expect_palette(romm_id: int, expected: Dictionary, message: String) -> void:
	var game = data_manager.database.get_game_by_id(romm_id)
	_expect(game != null, message + " (row exists)")
	if game == null:
		return
	_expect(game.cover_primary_color.to_html(false) == str(expected["primary"]).trim_prefix("#"), message + " (primary)")
	_expect(game.cover_secondary_color.to_html(false) == str(expected["secondary"]).trim_prefix("#"), message + " (secondary)")
	_expect(game.cover_tertiary_color.to_html(false) == str(expected["tertiary"]).trim_prefix("#"), message + " (tertiary)")
	_expect(game.cover_colors_version == int(expected["version"]), message + " (version)")


func _expect_cleared(romm_id: int, message: String) -> void:
	var game = data_manager.database.get_game_by_id(romm_id)
	_expect(game != null, message + " (row exists)")
	if game == null:
		return
	_expect(game.cover_colors_version == 0, message + " (version resets)")
	_expect(game.cover_primary_color.a == 0.0 and game.cover_secondary_color.a == 0.0 and game.cover_tertiary_color.a == 0.0, message + " (colors reset)")


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[PaletteIntegration] PASS: " + message)
	else:
		_failures.append(message)
		push_error("[PaletteIntegration] FAIL: " + message)


func _finish() -> void:
	if _failures.is_empty():
		print("[PaletteIntegration] All integration tests passed")
		quit(0)
	else:
		quit(1)
