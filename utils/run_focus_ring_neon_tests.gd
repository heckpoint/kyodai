## Run with isolated user:// storage:
## XDG_DATA_HOME=/tmp/kyodai-neon-tests godot --headless --path . -s utils/run_focus_ring_neon_tests.gd
extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var focus = root.get_node("UIManager").focus
	var focus_script: GDScript = load("res://managers/ui_manager/focus_sub_manager.gd")
	var theme_script: GDScript = load("res://addons/m3/m3_theme.gd")
	var data_manager = root.get_node("DataManager")
	# Let the post-ready startup cache warm finish before teardown; quitting in
	# the middle of its DB worker task can race settings/autoload destruction.
	for i in range(600):
		if data_manager.database.is_database_ready():
			break
		await process_frame
	await create_timer(0.1).timeout
	_expect(data_manager.get_setting("library_focus_ring_neon_glow") != null, "neon setting is registered")
	_expect(data_manager.get_setting("library_focus_ring_glow_intensity") != null, "intensity setting is registered")
	var color_setting = data_manager.get_setting("library_focus_ring_color_mode")
	var gradient_setting = data_manager.get_setting("library_focus_gradient_anim")
	var palette_setting = data_manager.get_setting("library_focus_palette")
	var source_setting = data_manager.get_setting("library_focus_source")
	_expect(color_setting != null and color_setting.options == ["Theme", "Gradient"], "gradient color mode is registered")
	_expect(palette_setting != null and palette_setting.options == ["Primary", "Secondary", "Tertiary", "Primary + Secondary", "Primary + Tertiary", "Secondary + Tertiary", "All Three"], "all seven focus palette combinations are registered")
	_expect(source_setting != null and source_setting.options == ["Accent", "Rainbow", "Game"], "focus sources are registered")
	_expect(source_setting.value == 1, "rainbow preserves the default gradient source")
	_expect(gradient_setting != null and gradient_setting.options == ["Static", "Evolve", "Chase"], "gradient animation is registered separately")
	_expect(data_manager.get_setting("library_focus_idle_anim").display_name == "Focus Alpha Animation", "existing idle setting is exposed as alpha animation")

	focus.neon_glow = true
	focus.glow_intensity = 0.6
	focus.color_mode = focus_script.ColorMode.CUSTOM
	var source := Color(0.4, 0.4, 0.2, 0.8)
	focus.custom_color = source
	focus._apply_color({})
	_expect(focus._ring_color.v >= 0.89, "neon core is brightened")
	_expect(focus._ring_color.s >= 0.64, "neon core retains a saturated hue")
	_expect(is_equal_approx(focus._ring_color.a, source.a), "core preserves source alpha")
	_expect(focus._neon_item.is_valid() and focus._neon_material != null and focus._neon_material.shader != null, "neon uses the SDF stroke shader")
	_expect(focus._ring_style.shadow_size == 0.0, "full-ring shadow fill is disabled")
	_expect(is_equal_approx(focus.glow_color.a, source.a * 0.6 * 0.65), "halo follows the configured intensity")

	focus.glow_intensity = 0.0
	_expect(focus._ring_style.shadow_size == 0.0, "zero intensity disables the halo")

	focus.glow_intensity = 0.6
	focus.neon_glow = false
	focus._apply_color({})
	_expect(focus._ring_color.is_equal_approx(source), "disabling neon restores the unmodified core color")
	_expect(focus._ring_style.shadow_size == 0.0 and focus._ring_style.shadow_color.a == 0.0, "disabling neon fully removes the halo")

	focus.neon_glow = true
	focus.color_mode = focus_script.ColorMode.MIRROR
	focus._apply_color({"color": Color.RED})
	_expect(absf(focus._ring_color.h) < 0.01 and absf(focus.glow_color.h) < 0.01, "mirror mode shares the source hue with the halo")

	focus.color_mode = focus_script.ColorMode.PRIMARY
	focus._apply_color({})
	_expect(absf(focus._ring_color.h - theme_script.get_primary().h) < 0.01, "primary mode retains the theme hue")

	focus.color_mode = focus_script.ColorMode.GRADIENT
	focus.gradient_anim = focus_script.GradientAnim.STATIC
	focus.gradient_source = focus_script.GradientSource.ACCENT
	focus.palette_role = focus_script.PaletteRole.SECONDARY
	focus._apply_color({})
	var accent_secondary: Array[Color] = focus._base_gradient_colors.duplicate()
	var secondary_error := absf(fposmod(accent_secondary[2].h - theme_script.get_secondary().h + 0.5, 1.0) - 0.5)
	_expect(accent_secondary.size() == 5 and secondary_error < 0.001, "accent secondary expands into five stops")
	focus.palette_role = focus_script.PaletteRole.TERTIARY
	focus._apply_color({})
	var tertiary_error := absf(fposmod(focus._base_gradient_colors[2].h - theme_script.get_tertiary().h + 0.5, 1.0) - 0.5)
	_expect(tertiary_error < 0.001, "accent tertiary selects the theme tertiary role")
	focus.palette_role = focus_script.PaletteRole.PRIMARY_SECONDARY
	focus._apply_color({})
	var pair_primary_error := absf(fposmod(focus._base_gradient_colors[1].h - theme_script.get_primary().h + 0.5, 1.0) - 0.5)
	var pair_secondary_error := absf(fposmod(focus._base_gradient_colors[4].h - theme_script.get_secondary().h + 0.5, 1.0) - 0.5)
	_expect(focus._base_gradient_colors.size() == 6 and pair_primary_error < 0.001 and pair_secondary_error < 0.001, "primary and secondary combine into a six-stop gradient")
	focus._update_gradient_material()
	_expect(focus._neon_material.get_shader_parameter("gradient_color_count") == 6, "mixed palette count reaches the shader")

	focus.gradient_source = focus_script.GradientSource.GAME
	focus.palette_role = focus_script.PaletteRole.SECONDARY
	var game_secondary := Color.from_hsv(0.42, 0.72, 0.80)
	focus._apply_color({"palette": {"secondary": game_secondary}})
	var game_error := absf(fposmod(focus._base_gradient_colors[2].h - game_secondary.h + 0.5, 1.0) - 0.5)
	_expect(game_error < 0.001, "game secondary source uses the focused game's secondary swatch")
	focus._apply_color({"palette": {}})
	var fallback_matches := true
	for i in range(5):
		if not focus._base_gradient_colors[i].is_equal_approx(accent_secondary[i]):
			fallback_matches = false
	_expect(fallback_matches, "missing game colors fall back to the matching accent role")
	focus.palette_role = focus_script.PaletteRole.ALL_THREE
	var game_primary := Color.from_hsv(0.08, 0.75, 0.90)
	var game_tertiary := Color.from_hsv(0.72, 0.65, 0.85)
	focus._apply_color({"palette": {"primary": game_primary, "secondary": game_secondary, "tertiary": game_tertiary}})
	var role_hues := [game_primary.h, game_secondary.h, game_tertiary.h]
	var local_stops_only := true
	for i in range(focus._base_gradient_colors.size()):
		var role_hue: float = role_hues[floori(float(i) / 3.0)]
		var hue_error := absf(fposmod(focus._base_gradient_colors[i].h - role_hue + 0.5, 1.0) - 0.5)
		if hue_error > 0.041:
			local_stops_only = false
	_expect(focus._base_gradient_colors.size() == 9 and local_stops_only, "all three uses only local variants in primary-secondary-tertiary order")
	focus._update_gradient_material()
	_expect(focus._neon_material.get_shader_parameter("gradient_color_count") == 9, "nine-stop triad reaches the shader")
	focus.palette_role = focus_script.PaletteRole.PRIMARY_SECONDARY
	focus._apply_color({"palette": {"primary": game_primary, "secondary": Color.TRANSPARENT}})
	var partial_primary_error := absf(fposmod(focus._base_gradient_colors[1].h - game_primary.h + 0.5, 1.0) - 0.5)
	var partial_secondary_error := absf(fposmod(focus._base_gradient_colors[4].h - theme_script.get_secondary().h + 0.5, 1.0) - 0.5)
	_expect(partial_primary_error < 0.001 and partial_secondary_error < 0.001, "mixed game palettes substitute only missing roles")
	focus.gradient_anim = focus_script.GradientAnim.EVOLVE
	focus._gradient_t = 0.5
	var evolved: Array[Color] = focus._current_gradient_palette()
	var primary_to_secondary := absf(fposmod(evolved[0].h - focus._base_gradient_colors[3].h + 0.5, 1.0) - 0.5)
	var secondary_to_primary := absf(fposmod(evolved[3].h - focus._base_gradient_colors[0].h + 0.5, 1.0) - 0.5)
	_expect(primary_to_secondary < 0.001 and secondary_to_primary < 0.001, "evolve exchanges primary and secondary roles through approved variants")
	focus.gradient_anim = focus_script.GradientAnim.STATIC
	focus._gradient_t = 0.0
	focus.gradient_source = focus_script.GradientSource.RAINBOW
	focus._apply_color({})
	_expect(focus._base_gradient_colors[0].is_equal_approx(focus_script.GRADIENT_COLORS[0]), "rainbow retains the built-in palette")

	focus.color_mode = focus_script.ColorMode.GRADIENT
	focus.gradient_anim = focus_script.GradientAnim.STATIC
	var palette: Array[Color] = focus._current_gradient_palette()
	_expect(palette.size() == 5, "gradient uses five colors")
	_expect(focus._sample_gradient(palette, 0.0).is_equal_approx(focus._sample_gradient(palette, 1.0)), "gradient wraps seamlessly")
	var test_rect := Rect2(10.0, 20.0, 220.0, 140.0)
	for t in [0.0, 0.1, 0.33, 0.7, 0.95]:
		var point: Vector2 = focus._perimeter_point(test_rect, 18.0, t)
		var actual: float = focus._perimeter_progress_at_point(test_rect, 18.0, point)
		var error := absf(fposmod(actual - t + 0.5, 1.0) - 0.5)
		_expect(error < 0.001, "perimeter mapping round-trips at %.2f" % t)

	focus.gradient_anim = focus_script.GradientAnim.EVOLVE
	focus._gradient_t = 0.0
	var before: Color = focus._current_gradient_palette()[0]
	focus._gradient_t = 0.25
	var after: Color = focus._current_gradient_palette()[0]
	_expect(not before.is_equal_approx(after), "evolve changes palette hues")

	focus.gradient_anim = focus_script.GradientAnim.CHASE
	focus._orbit_t = 0.25
	focus._update_gradient_material()
	_expect(focus._neon_material.get_shader_parameter("gradient_enabled") == true, "gradient mode reaches the shader")
	_expect(is_equal_approx(focus._neon_material.get_shader_parameter("gradient_phase"), 0.25), "gradient chase uses the orbit phase")
	focus.neon_glow = false
	focus._draw_neon_ring(Rect2(0.0, 0.0, 100.0, 100.0), 12.0, Color.WHITE)
	_expect(is_zero_approx(focus._neon_material.get_shader_parameter("glow_strength")), "gradient core works with halo disabled")

	focus._ring_visible = true
	focus.idle_anim = focus_script.IdleAnim.CHASE
	focus.gradient_anim = focus_script.GradientAnim.EVOLVE
	focus._restart_idle()
	_expect(focus._idle_tween != null and focus._gradient_tween != null, "evolve and alpha chase run independently")
	focus._stop_idle()
	focus.idle_anim = focus_script.IdleAnim.BREATHE
	focus.gradient_anim = focus_script.GradientAnim.CHASE
	focus._restart_idle()
	_expect(focus._idle_tween != null and focus._gradient_tween != null, "gradient chase and breathe run independently")
	focus._stop_idle()
	focus.idle_anim = focus_script.IdleAnim.CHASE
	focus.gradient_anim = focus_script.GradientAnim.CHASE
	focus._restart_idle()
	_expect(focus._idle_tween != null and focus._gradient_tween == null, "both chase modes share one orbit phase")
	focus._stop_idle()
	focus._ring_visible = false

	await process_frame
	if _failures.is_empty():
		print("[FocusRingNeonTests] All tests passed")
		quit(0)
	else:
		for failure in _failures:
			push_error("[FocusRingNeonTests] " + failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[FocusRingNeonTests] PASS: " + message)
	else:
		_failures.append(message)
