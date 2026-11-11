class_name ToolbarSubManager
extends Manager

## Owns the controls-bar toolbar: zoom slider, view-mode buttons, more-options
## menu, controlbar mask, and user avatar. Extracted from main.gd so the boot
## script only handles lifecycle.

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

# Nodes (set during initialize)
var _zoom_slider: M3Slider = null
var _view_mode_group: M3ButtonGroup = null
var _more_button: M3IconButton = null
var _mask: Panel = null
var _toolbar: PanelContainer = null
var _user_avatar: UserAvatar = null
var _platform_indicator: PlatformIndicator = null
var _controlbar_left: HBoxContainer = null
var _controlbar_right: HBoxContainer = null
var _main_content_vbox: VBoxContainer = null
var _content_wrapper: Control = null

# Zoom state
var _current_snap_ratios: Array[float] = []
var _startup_zoom_sync_active: bool = true
var _zoom_save_timer: Timer = null
const ZOOM_SAVE_DELAY_MS: int = 1500

# Cached SettingsVar refs for the hot zoom/layout keys. Settings load once at
# DataManager init and presets mutate these objects in place, so the refs stay
# valid for the session and skip repeated DataManager.get_setting() lookups.
var _sv_zoom_level: SettingsVar = null
var _sv_zoom_ratio: SettingsVar = null
var _sv_zoom_list: SettingsVar = null
var _sv_layout_mode: SettingsVar = null
var _sv_grid_vertical: SettingsVar = null

func initialize(
	main_content_vbox: VBoxContainer,
	content_wrapper: Control
) -> void:
	_main_content_vbox = main_content_vbox
	_content_wrapper = content_wrapper

	# Cache the hot SettingsVar refs (DataManager has loaded settings by now).
	if DataManager:
		_sv_zoom_level = DataManager.get_setting("library_card_zoom_level")
		_sv_zoom_ratio = DataManager.get_setting("library_card_zoom")
		_sv_zoom_list = DataManager.get_setting("library_card_zoom_list")
		_sv_layout_mode = DataManager.get_setting("library_layout_mode")
		_sv_grid_vertical = DataManager.get_setting("library_grid_vertical")

	# Resolve toolbar nodes
	_toolbar = _main_content_vbox.get_node_or_null("controlbar_background")
	if _toolbar:
		_toolbar.z_index = OverlayLayers.TOOLBAR_Z
	_zoom_slider = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarLeft/M3Slider_Zoom")
	_view_mode_group = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarRight/M3ButtonGroup")
	_more_button = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarRight/M3IconButton_More")
	_user_avatar = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarLeft/UserAvatar")
	_platform_indicator = _main_content_vbox.get_node_or_null("controlbar_background/PlatformIndicator")
	_controlbar_left = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarLeft")
	_controlbar_right = _main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/ControlBarRight")

	# Create debounced zoom save timer (replaces _process polling)
	_zoom_save_timer = Timer.new()
	_zoom_save_timer.one_shot = true
	_zoom_save_timer.wait_time = ZOOM_SAVE_DELAY_MS / 1000.0
	_zoom_save_timer.timeout.connect(_on_zoom_save_timer_timeout)
	add_child(_zoom_save_timer)

	# Sync the top background mask height to match the control bar.
	_mask = _content_wrapper.get_node_or_null("controlbar_mask")
	if _mask and _toolbar:
		var _update_mask_height := func():
			var toolbar_bottom: float = _toolbar.global_position.y - _content_wrapper.global_position.y + _toolbar.size.y
			_mask.custom_minimum_size.y = toolbar_bottom
			_mask.offset_top = 0
			_mask.offset_bottom = toolbar_bottom
		_toolbar.resized.connect(_update_mask_height)
		_update_mask_height.call_deferred()
		update_controlbar_mask_color()

	# Keep the overlay platform indicator inset by the wider side cluster so
	# its content row sits on the control bar's true center, and its 5/3/1
	# chip tiering tracks the real remaining slot.
	if _toolbar:
		if not _toolbar.resized.is_connected(_update_indicator_inset):
			_toolbar.resized.connect(_update_indicator_inset)
		_update_indicator_inset.call_deferred()

func connect_signals() -> void:
	# Connect zoom slider signals. value_changed is deferred until after startup
	# so the slider cannot override the saved zoom during initial layout.
	if _zoom_slider:
		_zoom_slider.drag_ended.connect(_on_zoom_changed_finished)

	# Connect view mode buttons
	if _view_mode_group:
		_view_mode_group.selection_changed.connect(_on_view_mode_changed)

	# Connect more-options button
	if _more_button:
		# M3IconButton._ready() stomps size_flags_vertical to 0, so the scene
		# value never takes effect; re-apply shrink-center here so the button
		# stays vertically centered in the taller controls bar.
		_more_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_more_button.pressed.connect(_on_more_button_pressed)

	# Set up the controls-bar user avatar: swap the fallback icon for the RomM
	# user's avatar image. Signal hookup is cheap, but the actual fetch/decode
	# is deferred until the home grid has settled (fetch_avatar_when_idle) so a
	# network response can't land mid-startup.
	if _user_avatar and SystemManager.network:
		SystemManager.network.network_status_changed.connect(_on_network_status_changed_for_avatar)
		SystemManager.network.current_user_changed.connect(_on_current_user_changed)

func finish_startup_zoom_sync() -> void:
	"""Mark startup zoom sync complete and connect the continuous value_changed
	signal so user drags update grids."""
	set_startup_zoom_sync_active(false)

func set_startup_zoom_sync_active(value: bool) -> void:
	_startup_zoom_sync_active = value
	# CRITICAL: clearing the startup gate must ALSO connect the continuous
	# value_changed handler — otherwise the zoom slider silently dead-ends
	# (the guard is off but no signal reaches _on_zoom_changed). Idempotent so
	# both the setter and finish_startup_zoom_sync can call it.
	if not value and _zoom_slider and not _zoom_slider.value_changed.is_connected(_on_zoom_changed):
		_zoom_slider.value_changed.connect(_on_zoom_changed)

func is_startup_zoom_sync_active() -> bool:
	return _startup_zoom_sync_active

# ============================================================================
# Zoom slider
# ============================================================================

func _update_zoom_slider_stops(games_grid: VirtualScrollGridContainer) -> void:
	"""Update slider stops to match the grid's calculated snap levels."""
	if not _zoom_slider:
		return
	# Never reconfigure the slider mid-drag: reassigning range/stops can clamp
	# the live value and fire value_changed, fighting the user's drag.
	if _zoom_slider.has_method("is_dragging") and _zoom_slider.is_dragging():
		return
	var snap_ratios = games_grid.get_snap_ratios_ascending()

	# Guard: ensure at least 2 snap ratios to prevent division-by-zero in slider
	# and to provide meaningful zoom range. If only 1 ratio, add a second.
	if snap_ratios.size() == 1:
		var second_ratio = maxf(0.05, snap_ratios[0] * 0.7)
		if not is_equal_approx(second_ratio, snap_ratios[0]):
			snap_ratios.insert(0, second_ratio)

	_current_snap_ratios = snap_ratios
	if snap_ratios.size() >= 2:
		# Grid mode: use integer indices so stops are evenly spaced visually.
		# The actual snap ratios are looked up by index when applying zoom.
		_zoom_slider.step = 1.0
		var stops: Array[float] = []
		for i in range(snap_ratios.size()):
			stops.append(float(i))
		_zoom_slider.custom_stop_values = stops
		_zoom_slider.min_value = 0
		_zoom_slider.max_value = snap_ratios.size() - 1
		_zoom_slider.label_behavior = M3Slider.LabelBehavior.NEVER
	else:
		# List/Carousel mode: fall back to uniform float steps
		_zoom_slider.custom_stop_values = []
		var max_zoom := 0.5
		_zoom_slider.min_value = 0.15
		_zoom_slider.max_value = max_zoom
		_zoom_slider.step = 0.05
		_zoom_slider.label_behavior = M3Slider.LabelBehavior.WHILE_DRAGGING

## Show/hide the toolbar-hosted platform indicator (Library view only).
## Re-push the side inset afterwards since the toggle changes what the side
## clusters contain (zoom slider / view buttons appear with the grid views).
func _set_platform_indicator_visible(value: bool) -> void:
	if _platform_indicator:
		_platform_indicator.visible = value
	_update_indicator_inset()

## The toolbar-hosted platform indicator (Library view wires its signals).
func get_platform_indicator() -> PlatformIndicator:
	return _platform_indicator

## Push the control bar's side-cluster inset to the platform indicator. The
## indicator overlays the bar full-rect; insetting both of its sides by the
## wider cluster's content width keeps its content row on the bar's true
## center by construction — no min-width equalization, no stretch-ratio
## assumptions, and nothing depends on when children's sizes settle. Content
## widths are summed from visible children so the result can't feed back.
func _update_indicator_inset() -> void:
	if not _toolbar or not is_instance_valid(_toolbar):
		return
	if not _controlbar_left or not _controlbar_right:
		return
	var side_w := maxf(_hbox_content_min_width(_controlbar_left), _hbox_content_min_width(_controlbar_right))
	side_w += M3Units.dp(8)
	if _platform_indicator:
		_platform_indicator.set_side_inset(side_w)

## Sum of visible children's combined minimum widths plus separations.
func _hbox_content_min_width(box: BoxContainer) -> float:
	var w := 0.0
	var visible_count := 0
	for child in box.get_children():
		if child is Control and child.visible:
			w += child.get_combined_minimum_size().x
			visible_count += 1
	if visible_count > 1:
		w += box.get_theme_constant("separation") * (visible_count - 1)
	return w

func _find_nearest_snap_index(ratio: float) -> int:
	"""Find the index of the snap ratio closest to the given ratio."""
	if _current_snap_ratios.is_empty():
		return 0
	var nearest_idx = 0
	var nearest_dist = INF
	for i in range(_current_snap_ratios.size()):
		var dist = abs(ratio - _current_snap_ratios[i])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_idx = i
	return nearest_idx

func sync_zoom_slider_to_view(view_name: String) -> void:
	"""Sync zoom slider stops/value to the current view's grid without applying
	zoom back to the grid (used on tab changes and after startup settle)."""
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if not UIManager._is_grid_view_name(view_name):
		if _view_mode_group:
			_view_mode_group.visible = false
		if _zoom_slider:
			_zoom_slider.visible = false
		_set_platform_indicator_visible(false)
		return

	if _view_mode_group:
		_view_mode_group.visible = true
	if _zoom_slider:
		_zoom_slider.visible = true
	_set_platform_indicator_visible(view_name == "Library")

	var view = UIManager.get_view(view_name)
	if not view:
		return
	var games_grid = UIManager.get_view_grid(view)
	if not games_grid:
		return

	# Defer if grid hasn't been laid out yet — get_snap_ratios() needs valid size
	if games_grid.size.x <= 0 or games_grid.size.y <= 0:
		if not games_grid.has_meta("_ui_view_retry_count"):
			games_grid.set_meta("_ui_view_retry_count", 0)
		var retry_count = games_grid.get_meta("_ui_view_retry_count")
		if retry_count < 5:
			games_grid.set_meta("_ui_view_retry_count", retry_count + 1)
			await get_tree().process_frame
			sync_zoom_slider_to_view(view_name)
		else:
			games_grid.set_meta("_ui_view_retry_count", 0)
		return
	games_grid.set_meta("_ui_view_retry_count", 0)

	if _zoom_slider.has_method("is_dragging") and _zoom_slider.is_dragging():
		return
	_update_zoom_slider_stops(games_grid)
	_zoom_slider.set_block_signals(true)
	if _current_snap_ratios.size() > 0:
		var level := -1
		if UIManager and UIManager.card_settings_state:
			if games_grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID:
				level = UIManager.card_settings_state.card_zoom_level
				if level < 0:
					level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
			else:
				# LIST/CAROUSEL store a scroll-fill fraction; resolve it to the
				# nearest stop index so the slider lands on the actual zoom.
				level = _find_nearest_snap_index(UIManager.card_settings_state.card_zoom_list_ratio)
		if level < 0:
			level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
		level = clampi(level, 0, _current_snap_ratios.size() - 1)
		_zoom_slider.set_value_no_signal(level)
	else:
		_zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
	_zoom_slider.set_block_signals(false)

func _on_zoom_changed(value: float):
	"""Called continuously while dragging - updates both views for parity."""
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if _startup_zoom_sync_active:
		return

	# DETERMINISTIC: zoom stops are pure functions of the grid's geometry
	# (base card dims, available area, separation, orientation, view mode) —
	# there is no guessed ratio path. If the cached stop list is empty (sync
	# has not run yet), compute it from the current view's grid right now.
	if _current_snap_ratios.is_empty():
		_sync_stops_from_current_view()
	if _current_snap_ratios.is_empty():
		# Genuinely zero-size grid (never laid out): nothing valid to apply.
		return

	# All modes: value is an integer stop index. Each grid resolves it to its
	# own bounds-aware stop (items-per-line for GRID, scroll-axis lines for
	# LIST/CAROUSEL) so the zoom stays consistent across views.
	var level := clampi(int(round(value)), 0, _current_snap_ratios.size() - 1)
	var is_grid := _current_view_is_grid_mode()
	if UIManager and UIManager.card_settings_state:
		if is_grid:
			UIManager.card_settings_state.card_zoom_level = level
			UIManager.card_settings_state.card_zoom_ratio = _current_snap_ratios[level]
		else:
			UIManager.card_settings_state.card_zoom_list_ratio = _current_snap_ratios[level]

	# Hidden views only get the level stamped; running their full layout
	# (card adds, effect rebuilds, data requests) while invisible multiplies
	# the zoom cost by every instantiated view. They settle on next show
	# via View.on_view_show -> recalculate_layout_with_size.
	UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
		var grid_view = UIManager.get_view_for_grid(grid)
		var visible: bool = grid_view != null and grid_view.is_visible_in_tree()
		if visible:
			grid.set_zoom_level(level)
		else:
			grid.stamp_zoom_level(level)
	)

func _sync_stops_from_current_view() -> void:
	"""Compute the slider stops fresh from the current view's grid. Stops are
	deterministic given the grid geometry, so this is always valid once the
	grid has any size — it never guesses."""
	var view = UIManager.get_current_view()
	var grid = UIManager.get_view_grid(view) if view else null
	if grid:
		_update_zoom_slider_stops(grid)

func _current_view_is_grid_mode() -> bool:
	var view = UIManager.get_current_view()
	var grid = UIManager.get_view_grid(view) if view else null
	return grid != null and grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID

func _on_zoom_changed_finished(value_changed: bool):
	"""Called when drag ends - saves the current slider value to settings."""
	if not value_changed or VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if not _zoom_slider:
		return

	if _current_snap_ratios.is_empty():
		_sync_stops_from_current_view()
	if _current_snap_ratios.is_empty():
		return
	# All modes: the slider carries integer stop indices; persist via the
	# shared mode-aware helper (grid -> level+ratio, list/carousel -> fraction).
	var level := clampi(int(round(_zoom_slider.value)), 0, _current_snap_ratios.size() - 1)
	_persist_zoom_stop(level)

func _on_zoom_save_timer_timeout() -> void:
	if DataManager:
		DataManager.save_settings()

## Apply the saved zoom level/ratio to all grids and sync the slider.
## Used at runtime (e.g. after a preset is applied) when the grid may already
## be visible with a different zoom.
func load_and_apply_saved_zoom() -> void:
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if not DataManager:
		return

	var is_grid: bool = _sv_layout_mode.value == 0 if _sv_layout_mode else true

	if is_grid and _sv_zoom_level and _sv_zoom_level.value is int and _sv_zoom_level.value >= 0:
		var level: int = _sv_zoom_level.value
		if UIManager and UIManager.card_settings_state:
			UIManager.card_settings_state.card_zoom_level = level

		# Apply the same level to all grid views.
		UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
			grid.set_zoom_level(level)
		)

	elif not is_grid:
		# List/Carousel: apply the per-mode ratio.
		if _sv_zoom_list:
			var saved_zoom = _sv_zoom_list.value
			if UIManager and UIManager.card_settings_state:
				UIManager.card_settings_state.card_zoom_list_ratio = saved_zoom

			# Apply saved list/carousel zoom to all grid views
			UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
				grid.target_card_width_ratio = saved_zoom
			)

	elif _sv_zoom_ratio:
		# GRID without a saved level: legacy ratio fallback (grid derives N).
		var saved_zoom = _sv_zoom_ratio.value

		# Apply saved zoom to all grid views
		UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
			grid.target_card_width_ratio = saved_zoom
		)

	# Set zoom slider to the current level (grid) or actual grid ratio (list/carousel)
	if _zoom_slider:
		var current_view = UIManager.get_current_view()
		var games_grid = UIManager.get_view_grid(current_view) if current_view else null
		if games_grid:
			_update_zoom_slider_stops(games_grid)
		# Use the current level in grid mode so the slider reflects the saved level.
		var actual_zoom: float
		if games_grid:
			actual_zoom = games_grid.target_card_width_ratio
		elif is_grid:
			actual_zoom = _sv_zoom_ratio.value if _sv_zoom_ratio else 0.25
		else:
			actual_zoom = _sv_zoom_list.value if _sv_zoom_list else 0.25
		_zoom_slider.set_block_signals(true)
		if _current_snap_ratios.size() > 0:
			var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
			if level < 0:
				level = _find_nearest_snap_index(actual_zoom)
			level = clampi(level, 0, _current_snap_ratios.size() - 1)
			_zoom_slider.set_value_no_signal(level)
		else:
			_zoom_slider.set_value_no_signal(actual_zoom)
		_zoom_slider.set_block_signals(false)

## Sync the zoom slider to the current grid's zoom level without applying zoom
## back to the grid. Used at startup after the grid has settled.
func sync_zoom_slider_to_current_view() -> void:
	if not _zoom_slider:
		return

	var current_view = UIManager.get_current_view()
	var games_grid = UIManager.get_view_grid(current_view) if current_view else null
	if not games_grid:
		return

	_update_zoom_slider_stops(games_grid)
	if _current_snap_ratios.size() > 0:
		var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
		if level < 0:
			level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
		level = clampi(level, 0, _current_snap_ratios.size() - 1)
		_zoom_slider.set_value_no_signal(level)
	else:
		_zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)

func save_zoom_ratio(ratio: float) -> void:
	"""Persist the list/carousel zoom fraction to library_card_zoom_list.

	(Only called from the list/carousel settle path — grid settle persists via
	the level/ratio settings in persist_settled_zoom.)"""
	if not DataManager:
		return
	# Don't save a zoom derived from a headless / zero-size window; it would
	# clamp to the maximum and corrupt the user's saved zoom.
	var win_size = DisplayServer.window_get_size()
	if win_size == Vector2i.ZERO or OS.get_cmdline_args().has("--benchmark-startup"):
		return
	if not _sv_zoom_list:
		return
	# Max fraction is 1.0 (the k=1 stop fills the scroll axis exactly).
	var clamped_ratio = clampf(ratio, 0.05, 1.0)
	if is_equal_approx(_sv_zoom_list.value, clamped_ratio):
		return
	DataManager.set_setting(clamped_ratio, _sv_zoom_list)
	if _zoom_save_timer:
		_zoom_save_timer.start()

# ============================================================================
# View mode buttons
# ============================================================================

func sync_view_mode_button_to_setting() -> void:
	if not _view_mode_group or not DataManager:
		return

	var layout_mode_val = _sv_layout_mode.value if _sv_layout_mode else 0

	var button_index: int
	match layout_mode_val:
		0: button_index = 0  # Grid
		1: button_index = 1  # List
		2: button_index = 2  # Carousel
		_: button_index = 0

	# Block signals during programmatic sync so it isn't treated as a user change.
	_view_mode_group.set_block_signals(true)
	_view_mode_group.select_button(button_index)
	_view_mode_group.set_block_signals(false)

func _on_view_mode_changed(selected_indices: Array[int]) -> void:
	if selected_indices.is_empty():
		return

	var new_mode: VirtualScrollGridContainer.ViewMode
	var setting_value: int

	match selected_indices[0]:
		0:  # Grid
			new_mode = VirtualScrollGridContainer.ViewMode.GRID
			setting_value = 0
		1:  # List
			new_mode = VirtualScrollGridContainer.ViewMode.LIST
			setting_value = 1
		2:  # Carousel
			new_mode = VirtualScrollGridContainer.ViewMode.CAROUSEL
			setting_value = 2
		_:
			return

	# Snapshot the grid zoom level before leaving GRID so returning restores it
	# exactly, even if the user never dragged the zoom slider while in grid mode
	# (in which case no level was ever persisted).
	if new_mode != VirtualScrollGridContainer.ViewMode.GRID and UIManager and UIManager.card_settings_state:
		if UIManager.card_settings_state.card_zoom_level < 0:
			var snapshot_view = UIManager.get_current_view()
			var current_grid = UIManager.get_view_grid(snapshot_view) if snapshot_view else null
			if current_grid:
				var snapshot: int = current_grid.get_zoom_level()
				if snapshot >= 0:
					UIManager.card_settings_state.card_zoom_level = snapshot

	# Apply to all grid views
	UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
		grid.view_mode = new_mode
	)

	# Save to settings
	if DataManager:
		if _sv_layout_mode:
			DataManager.set_setting(setting_value, _sv_layout_mode)
			DataManager.save_settings()

	# Update zoom slider stops/range since max zoom and snap levels differ per mode
	var current_view = UIManager.get_current_view()
	if current_view:
		var games_grid = UIManager.get_view_grid(current_view)
		if games_grid:
			_update_zoom_slider_stops(games_grid)
			# Sync slider value to the grid's actual current ratio
			_zoom_slider.set_block_signals(true)
			if _current_snap_ratios.size() > 0:
				_zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
			else:
				_zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
			_zoom_slider.set_block_signals(false)

# ============================================================================
# More-options menu
# ============================================================================

func _on_more_button_pressed() -> void:
	var menu = M3Menu.new()
	var current_view = UIManager.get_current_view()
	var is_grid = false
	var is_horizontal = false
	var pagination_enabled = false
	var staggered_enabled = false

	if current_view:
		var grid = UIManager.get_view_grid(current_view)
		if grid:
			is_grid = grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID
			is_horizontal = not grid.grid_vertical

	# Read the check state from the persisted setting (the shared source of
	# truth across all views), not from a single grid's applied state.
	if DataManager:
		var pagination_setting = DataManager.get_setting("library_pagination_view")
		if pagination_setting and pagination_setting.value is bool:
			pagination_enabled = pagination_setting.value
		var staggered_setting = DataManager.get_setting("library_grid_staggered")
		if staggered_setting and staggered_setting.value is bool:
			staggered_enabled = staggered_setting.value

	# Grid Settings submenu (independent toggles — no radio group)
	var grid_settings = M3Menu.new()
	grid_settings.auto_free = false
	grid_settings.add_check_item("Horizontal Grid", is_horizontal, _toggle_horizontal_grid)
	if not is_grid:
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	grid_settings.add_check_item("Pagination View", pagination_enabled, _toggle_pagination_view)
	if not is_grid:
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	grid_settings.add_check_item("Staggered Grid", staggered_enabled, _toggle_staggered_grid)
	if not is_grid or is_horizontal:
		# Staggered applies to the vertical grid only.
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	menu.add_submenu_item("Grid Settings", grid_settings, "view-grid")

	# Focus Centering submenu
	var focus_centering = 0
	if DataManager:
		var centering_setting = DataManager.get_setting("library_focus_centering")
		if centering_setting and centering_setting.value is int:
			focus_centering = centering_setting.value

	var centering_submenu = M3Menu.new()
	centering_submenu.auto_free = false
	centering_submenu.radio_group = true
	centering_submenu.add_check_item("Margin", focus_centering == 0, func(): _set_focus_centering(0))
	centering_submenu.add_check_item("Center", focus_centering == 1, func(): _set_focus_centering(1))
	menu.add_submenu_item("Focus Centering", centering_submenu, "crosshairs")

	menu.add_separator()

	# Card Display Mode submenu
	var display_mode = 0
	if DataManager:
		var display_setting = DataManager.get_setting("library_card_display_mode")
		if display_setting and display_setting.value is int:
			display_mode = display_setting.value

	var display_submenu = M3Menu.new()
	display_submenu.auto_free = false
	display_submenu.radio_group = true
	display_submenu.add_check_item("Standard", display_mode == 0, func(): _set_card_display_mode(0))
	display_submenu.add_check_item("Transparent", display_mode == 1, func(): _set_card_display_mode(1))
	display_submenu.add_check_item("Media Only", display_mode == 2, func(): _set_card_display_mode(2))
	menu.add_submenu_item("Card Display Mode", display_submenu, "cards-outline")

	# Card Media Ratio submenu
	var media_ratio = 0
	if DataManager:
		var ratio_setting = DataManager.get_setting("card_media_aspect_ratio")
		if ratio_setting and ratio_setting.value is int:
			media_ratio = ratio_setting.value

	var ratio_submenu = M3Menu.new()
	ratio_submenu.auto_free = false
	ratio_submenu.radio_group = true
	ratio_submenu.add_check_item("Fill", media_ratio == 0, func(): _set_card_media_ratio(0))
	ratio_submenu.add_check_item("2:3", media_ratio == 1, func(): _set_card_media_ratio(1))
	ratio_submenu.add_check_item("3:4", media_ratio == 2, func(): _set_card_media_ratio(2))
	ratio_submenu.add_check_item("1:1", media_ratio == 3, func(): _set_card_media_ratio(3))
	ratio_submenu.add_check_item("16:11", media_ratio == 4, func(): _set_card_media_ratio(4))
	menu.add_submenu_item("Card Media Ratio", ratio_submenu, "aspect-ratio")

	# Content Alignment submenu
	var content_alignment = 0
	if DataManager:
		var align_setting = DataManager.get_setting("library_card_content_alignment")
		if align_setting and align_setting.value is int:
			content_alignment = align_setting.value

	var align_submenu = M3Menu.new()
	align_submenu.auto_free = false
	align_submenu.radio_group = true
	align_submenu.add_check_item("Left / Top", content_alignment == 0, func(): _set_content_alignment(0))
	align_submenu.add_check_item("Center / Middle", content_alignment == 1, func(): _set_content_alignment(1))
	align_submenu.add_check_item("Right / Bottom", content_alignment == 2, func(): _set_content_alignment(2))
	menu.add_submenu_item("Content Alignment", align_submenu, "format-align-center")

	# Text Settings submenu. Visibility and marquee options are independent;
	# alignment choices share one persisted, mutually exclusive value.
	var show_platform := true
	var text_alignment := 0
	var scroll_truncation := false
	var text_focused_only := false
	if DataManager:
		var platform_setting = DataManager.get_setting("library_card_show_platform")
		if platform_setting and platform_setting.value is bool:
			show_platform = platform_setting.value
		var text_align_setting = DataManager.get_setting("library_card_text_alignment")
		if text_align_setting and text_align_setting.value is int:
			text_alignment = text_align_setting.value
		var scroll_setting = DataManager.get_setting("library_card_scroll_truncation")
		if scroll_setting and scroll_setting.value is bool:
			scroll_truncation = scroll_setting.value
		var focused_setting = DataManager.get_setting("library_card_text_focused_only")
		if focused_setting and focused_setting.value is bool:
			text_focused_only = focused_setting.value

	# Follow Content is the compatibility default. Reflect the effective
	# alignment in the checkmarks until the user chooses an explicit override.
	var effective_text_alignment := text_alignment
	if effective_text_alignment == 0:
		effective_text_alignment = content_alignment + 1

	var text_settings = M3Menu.new()
	text_settings.auto_free = false
	text_settings.add_check_item("Show Platform", show_platform, _toggle_card_show_platform)
	text_settings.add_section_label("Text Alignment")
	# Alignment is mutually exclusive through the persisted value. Keeping these
	# choices inline also avoids unreliable second-level submenu pointer input.
	text_settings.add_check_item("Left", effective_text_alignment == 1, func(): _set_card_text_alignment(1))
	text_settings.add_check_item("Center", effective_text_alignment == 2, func(): _set_card_text_alignment(2))
	text_settings.add_check_item("Right", effective_text_alignment == 3, func(): _set_card_text_alignment(3))
	text_settings.add_separator()
	text_settings.add_check_item("Scroll Truncation", scroll_truncation, _toggle_card_scroll_truncation)
	text_settings.add_check_item("Focused Only", text_focused_only, _toggle_card_text_focused_only)
	menu.add_submenu_item("Text Settings", text_settings, "format-text")

	if _more_button:
		menu.popup(_more_button)

func _set_card_display_mode(mode: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_card_display_mode")
		if setting:
			DataManager.set_setting(mode, setting)
			DataManager.save_settings()

func _set_card_media_ratio(ratio: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("card_media_aspect_ratio")
		if setting:
			DataManager.set_setting(ratio, setting)
			DataManager.save_settings()

func _set_content_alignment(alignment: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_card_content_alignment")
		if setting:
			DataManager.set_setting(alignment, setting)
			DataManager.save_settings()

func _set_card_text_alignment(alignment: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_card_text_alignment")
		if setting:
			DataManager.set_setting(alignment, setting)
			DataManager.save_settings()

func _toggle_card_show_platform() -> void:
	_toggle_card_text_bool("library_card_show_platform", true)

func _toggle_card_scroll_truncation() -> void:
	_toggle_card_text_bool("library_card_scroll_truncation", false)

func _toggle_card_text_focused_only() -> void:
	_toggle_card_text_bool("library_card_text_focused_only", false)

func _toggle_card_text_bool(property_name: String, default_value: bool) -> void:
	if not DataManager:
		return
	var setting = DataManager.get_setting(property_name)
	if not setting:
		return
	var current_value: bool = setting.value if setting.value is bool else default_value
	DataManager.set_setting(not current_value, setting)
	DataManager.save_settings()

func _set_focus_centering(mode: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_focus_centering")
		if setting:
			DataManager.set_setting(mode, setting)
			DataManager.save_settings()

func _toggle_pagination_view() -> void:
	var target_enabled = true
	if DataManager:
		var setting = DataManager.get_setting("library_pagination_view")
		if setting and setting.value is bool:
			target_enabled = not setting.value

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = get_focused_card_index()

	# Persist; CardSettingsState propagates the change to all grid views.
	if DataManager:
		var setting = DataManager.get_setting("library_pagination_view")
		if setting:
			DataManager.set_setting(target_enabled, setting)
			DataManager.save_settings()

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

func _toggle_staggered_grid() -> void:
	var target_enabled = true
	if DataManager:
		var setting = DataManager.get_setting("library_grid_staggered")
		if setting and setting.value is bool:
			target_enabled = not setting.value

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = get_focused_card_index()

	# Persist; CardSettingsState propagates the change to all grid views.
	if DataManager:
		var setting = DataManager.get_setting("library_grid_staggered")
		if setting:
			DataManager.set_setting(target_enabled, setting)
			DataManager.save_settings()

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

func _toggle_horizontal_grid() -> void:
	var target_vertical = true
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = UIManager.get_view_grid(current_view)
		if grid:
			target_vertical = not grid.grid_vertical

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = get_focused_card_index()

	# Apply to all grid views
	UIManager.apply_to_all_grids(func(grid: VirtualScrollGridContainer):
		grid.grid_vertical = target_vertical
	)

	# Persist. The zoom level index is orientation-relative (columns vs rows),
	# so sync it to the post-flip layout BEFORE the LAYOUT change propagates —
	# otherwise the batch would re-apply the stale index against the new
	# orientation's stop list and clobber the size-preserving derivation above.
	var new_level := -1
	if current_view:
		var current_grid = UIManager.get_view_grid(current_view)
		if current_grid:
			new_level = current_grid.get_zoom_level()
	if new_level >= 0 and UIManager and UIManager.card_settings_state:
		UIManager.card_settings_state.card_zoom_level = new_level
	if DataManager:
		if _sv_grid_vertical:
			DataManager.set_setting(target_vertical, _sv_grid_vertical)
		if new_level >= 0 and _sv_zoom_level:
			DataManager.set_setting(new_level, _sv_zoom_level)
		DataManager.save_settings()

	# Refresh zoom slider so it uses snap ratios for the new orientation
	if current_view:
		sync_zoom_slider_to_view(current_view.view_name)

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

# ============================================================================
# Controlbar mask
# ============================================================================

func update_controlbar_mask_color() -> void:
	# refresh_theme can arrive from an early scale/theme walk before the node
	# refs are fetched; the mask gets its color again on the next refresh.
	if not _content_wrapper:
		return
	if not _mask and _content_wrapper:
		_mask = _content_wrapper.get_node_or_null("controlbar_mask")
	if _mask and _mask.material:
		var surface := M3Theme.get_surface()
		var accent := M3Theme.get_primary()
		# Use accent hue, but keep the surface's value and only borrow a small
		# amount of accent saturation so the fade stays subtle in light modes.
		var h := accent.h
		var s: float = lerp(surface.s, accent.s, 0.08)
		var v := surface.v * 0.85
		var fade_color := Color.from_hsv(h, s, v)
		_mask.material.set_shader_parameter("fade_color", fade_color)

# ============================================================================
# User avatar
# ============================================================================

# Avatar fetch/decode is deferred until the home grid has settled so network
# latency and image decode can't sit on the startup critical path.
var _avatar_fetch_allowed: bool = false

## Kick the initial avatar fetch once startup has settled. Also arms the
## network-status handler so a reconnect later in the session refetches.
func fetch_avatar_when_idle() -> void:
	_avatar_fetch_allowed = true
	if not _user_avatar or not SystemManager.network:
		return
	if SystemManager.network.is_online():
		if SystemManager.network.current_user.is_empty():
			SystemManager.network.fetch_current_user()
		else:
			# User data already arrived (e.g. an early fetch elsewhere); apply now.
			_on_current_user_changed(SystemManager.network.current_user)

func _on_network_status_changed_for_avatar(online: bool) -> void:
	if not _avatar_fetch_allowed:
		return
	if online and SystemManager.network.current_user.is_empty():
		SystemManager.network.fetch_current_user()

func _on_current_user_changed(user: Dictionary) -> void:
	if not _avatar_fetch_allowed:
		return
	if not is_instance_valid(_user_avatar):
		return
	var avatar_path: String = user.get("avatar_path", "")
	var user_id := int(user.get("id", 0))
	if avatar_path.is_empty() or user_id <= 0:
		_user_avatar.clear_avatar()
		return
	SystemManager.network.download_avatar(user_id, func(success: bool, body: PackedByteArray, _status: int, _err: String):
		if not success or not is_instance_valid(_user_avatar) or body.size() < 16:
			return
		# Decode on the image thread: a large avatar JPEG costs tens of ms of
		# main-thread time and this callback can land mid-startup inside a
		# net_handler frame. The completion hop runs back on the main thread.
		MemorySubManager.queue_image_task(
			func():
				var image := Image.new()
				var err := FAILED
				match FSM.detect_image_format(body):
					FSM.ImageFormat.JPEG:
						err = image.load_jpg_from_buffer(body)
					FSM.ImageFormat.PNG:
						err = image.load_png_from_buffer(body)
					FSM.ImageFormat.WEBP:
						err = image.load_webp_from_buffer(body)
					_:
						return null
				if err != OK or image.is_empty():
					return null
				return image,
			func(image):
				# image is null when the task was evicted or decode failed.
				if image != null and is_instance_valid(_user_avatar):
					_user_avatar.set_avatar_image(image)
		)
	)

# ============================================================================
# Focus helpers
# ============================================================================

func get_focused_card_index() -> int:
	"""Return the virtual index of the currently focused card, or -1."""
	var current_view = UIManager.get_current_view()
	if not current_view:
		return -1
	var grid = UIManager.get_view_grid(current_view)
	if not grid:
		return -1
	return grid.get_focused_virtual_index()

func _restore_focus_to_card(index: int, preserve_index: bool = false) -> void:
	"""Restore focus to the card at the given virtual index."""
	var current_view = UIManager.get_current_view()
	if not current_view:
		return

	# For HomeView, normally restore to index 0 since it reorders by last played.
	# When preserve_index is true (e.g. orientation toggle), keep the original index.
	var target_index = index
	if current_view is HomeView and not preserve_index:
		target_index = 0

	var games_grid = UIManager.get_view_grid(current_view)
	if not games_grid:
		return

	# The grid handles follow-focus suppression internally; a direct grab here
	# would override in-flight wheel scrolling and spam value_changed.
	games_grid.restore_focus_to_index(target_index)

## Step the zoom by one stop in the given direction (gamepad triggers).
## Unified stop model: the slider value IS the stop index for every view mode,
## so stepping moves one stop and clamps to the mode's stop count.
func adjust_zoom(delta: float) -> void:
	if _startup_zoom_sync_active:
		return
	if not _zoom_slider:
		return
	if _current_snap_ratios.is_empty():
		_sync_stops_from_current_view()
	if _current_snap_ratios.is_empty():
		return

	var current_index := int(round(_zoom_slider.value))
	var new_index := clampi(current_index + sign(delta), 0, _current_snap_ratios.size() - 1)
	if new_index == current_index:
		return
	var focused_index = get_focused_card_index()
	_zoom_slider.set_value_no_signal(new_index)
	_on_zoom_changed(new_index)
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index)
	_persist_zoom_stop(new_index)

## Write the current stop to the mode-correct settings (in-memory; the
## debounced timer persists to disk). Writing the wrong field here reverts the
## zoom on the next settings re-sync: sync_from_settings_manager re-reads BOTH
## zoom fields, and whichever one was left stale wins the re-apply.
func _persist_zoom_stop(level: int) -> void:
	if not DataManager:
		return
	if _current_view_is_grid_mode():
		if _sv_zoom_level:
			DataManager.set_setting(level, _sv_zoom_level)
		if _sv_zoom_ratio:
			DataManager.set_setting(_current_snap_ratios[level], _sv_zoom_ratio)
	else:
		if _sv_zoom_list:
			DataManager.set_setting(_current_snap_ratios[level], _sv_zoom_list)
	if _zoom_save_timer:
		_zoom_save_timer.start()

## Stop any pending debounced zoom save (used when suspending/quitting).
func cancel_pending_zoom_save() -> void:
	if _zoom_save_timer:
		_zoom_save_timer.stop()

## Persist the settled startup zoom level and snapped ratio so settings stay in
## sync with the slider and don't hold stale values from a previous viewport.
func persist_settled_zoom(grid: VirtualScrollGridContainer) -> void:
	if not grid or not UIManager or not UIManager.card_settings_state:
		return
	# Mode-aware: persist to the grid OR list/carousel settings. Writing the
	# wrong field leaves the other stale, and the next settings re-sync
	# (sync_from_settings_manager) re-applies the stale value = snap-back.
	if grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID:
		var level = UIManager.card_settings_state.card_zoom_level
		if level < 0 and _current_snap_ratios.size() > 0:
			level = _find_nearest_snap_index(grid.target_card_width_ratio)
			UIManager.card_settings_state.card_zoom_level = level
		if level >= 0 and DataManager:
			if _sv_zoom_level:
				DataManager.set_setting(level, _sv_zoom_level)
			if _sv_zoom_ratio:
				DataManager.set_setting(grid.target_card_width_ratio, _sv_zoom_ratio)
			UIManager.card_settings_state.card_zoom_ratio = grid.target_card_width_ratio
			if _zoom_save_timer:
				_zoom_save_timer.start()
	else:
		save_zoom_ratio(grid.target_card_width_ratio)
