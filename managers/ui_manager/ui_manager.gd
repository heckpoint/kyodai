extends Manager

const DEBUG_LOG: bool = false
const CONTENT_MARGIN_DP: float = 16.0

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const TITLE_BAR_SCRIPT := preload("res://components/title_bar.gd")
const RESIZE_GRIPS_SCRIPT := preload("res://components/overlays/window_resize_grips.gd")

# UIManager - Facade for UI orchestration.
# Child managers own views, navigation, hero/background, overlays, theme, and dual-screen logic.

@onready var view = $ViewSubManager
@onready var navigation = $NavigationSubManager
@onready var overlay = $OverlaySubManager
@onready var theme = $ThemeSubManager
@onready var dual_screen = $DualScreenSubManager
@onready var focus: FocusSubManager = $FocusSubManager
@onready var toolbar: ToolbarSubManager = $ToolbarSubManager

func _enter_tree() -> void:
	FrameWorkScheduler.register(self, _run_frame_work)

func _ready() -> void:
	PlatformCardPool.process(0.0)

func _run_frame_work(delta: float) -> void:
	if not PlatformCardPool.is_warm():
		PlatformCardPool.process(delta)

# Cached references passed during initialization
var _library_background: LibraryBackground = null

# Centralized card/grid settings state. Owned by UIManager; consumers read this
# instead of querying DataManager directly for card/grid settings.
var card_settings_state: CardSettingsState = null

# Layout management
var _root_control: Control = null  # Plain control, never replaced
var _inner_layout: BoxContainer = null  # VBox or HBox, replaced only on orientation change
var _main_content_vbox: VBoxContainer = null  # Never replaced, never cleared
var _content_wrapper: Control = null
var _content_margin: MarginContainer = null
var _status_bar: StatusBar = null
# Desktop windowed chrome: the custom title bar and the invisible edge resize
# grips live on _chrome_layer (CanvasLayer, OverlayLayers.CHROME) so they render
# above every overlay and stay reachable. The layout below them is offset via
# NavigationSubManager._apply_chrome_offset() (InnerLayout.offset_top). Null
# on Android.
var _chrome_layer: CanvasLayer = null
var _title_bar: PanelContainer = null
var _window_resize_grips: Control = null

# Cached on-screen keyboard reference (survives reparenting in dual-screen mode)
var _onscreen_keyboard: PanelContainer = null

# Focus lock state: when a locked grid owns focus, all other focusable controls
# in the scene are temporarily set to FOCUS_NONE so directional input cannot leak.
var _focus_lock_active: bool = false
var _focus_locked_grid: VirtualScrollGridContainer = null
# instance_id -> [WeakRef, int]. Keyed by instance (not NodePath) so dual-screen
# reparents and nav rebuilds can't strand the original focus modes.
var _saved_focus_modes: Dictionary = {}
var _focus_lock_refresh_queued: bool = false
var _focusables_cache: Array[Control] = []
var _focusables_cache_valid: bool = false

# Proxy for legacy external access to dual-screen keyboard state.
@warning_ignore("unused_private_class_variable")
var _keyboard_is_in_second_viewport: bool:
	get:
		if dual_screen:
			return dual_screen._keyboard_is_in_second_viewport
		return false

# Signals
@warning_ignore("unused_signal")
signal modal_shown(modal_id: String)
@warning_ignore("unused_signal")
signal modal_dismissed(modal_id: String)
@warning_ignore("unused_signal")
signal modal_item_selected(item_id: String, context: Dictionary)
@warning_ignore("unused_signal")
signal tab_changed(view_name: String)
@warning_ignore("unused_signal")
signal layout_changed(position: String)
@warning_ignore("unused_signal")
signal settings_dialog_dismissed()

## Consumes a UI-scale change that fired before initialize() connected the
## signal, and reconciles the nodes built so far. Main calls this right after
## the window settles, before initialize(): the tree is only main.tscn +
## autoloads then, so the refresh walk is at its smallest, and everything
## built afterwards reads the already-updated M3Units values.
func reconcile_early_scale_change() -> void:
	if SystemManager.display and SystemManager.display.consume_pending_scale_refresh():
		var walk_start_us := Time.get_ticks_usec()
		theme._do_refresh_scale()
		# During startup the walk is chunked across frames; this logs the first
		# chunk only, and [ThemeManager] startup scale walk logs the total.
		print("[UIManager] early scale reconcile first-chunk_us=", Time.get_ticks_usec() - walk_start_us)

func set_main_ui_visible(value: bool) -> void:
	"""Show/hide the entire main UI tree (RootLayout: library background, nav,
	grid, control bar). Used by the display manager's resize-gesture freeze:
	while the window is dragged, the app draws only the black freeze overlay
	(layer 1200, which also covers the ChromeLayer title bar and grips), so
	per-frame cost collapses and the compositor gets new buffers immediately.
	Hidden nodes still receive _input, so grip release detection keeps
	working."""
	if _root_control:
		_root_control.visible = value

func initialize(
	tab_container: TabContainer,
	library_background: LibraryBackground,
	content_wrapper: Control,
	main_content_vbox: VBoxContainer,
	root_layout: Control
) -> void:
	"""Initialize UIManager with all the pre-built nodes from main.tscn."""

	var init_start_us := Time.get_ticks_usec()
	_root_control = root_layout
	_content_wrapper = content_wrapper
	_main_content_vbox = main_content_vbox
	_library_background = library_background

	# Get navigation type setting
	var nav_type: int = 0
	if DataManager:
		var type_setting = DataManager.get_setting("library_navigation_type")
		if type_setting:
			nav_type = type_setting.value

	# Create InnerLayout and add it to the root control
	var phase_start_us := Time.get_ticks_usec()
	_inner_layout = _create_inner_layout(nav_type == 0)
	_root_control.add_child(_inner_layout)
	print("[UIManager] inner layout create elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Wrap MainContentVBox in a MarginContainer to keep content away from screen edges
	phase_start_us = Time.get_ticks_usec()
	var content_margin = MarginContainer.new()
	content_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_content_margin(content_margin)
	_content_margin = content_margin

	var mcv_index = _main_content_vbox.get_index()
	_content_wrapper.remove_child(_main_content_vbox)
	content_margin.add_child(_main_content_vbox)

	# Dock the status strip (clock + battery) at the top edge, above the margin
	# container so it is full-bleed and unaffected by the content margins.
	# Stored as a member: compute_grid_available_size subtracts its height.
	#
	# Desktop windowed chrome (Windows/Linux): the custom title bar lives on
	# its own CanvasLayer (OverlayLayers.CHROME) above every app overlay, so
	# dialogs, menus, and the launch/view transitions can never cover or block
	# the window controls. It is parented to Main (sibling of UILayer), NOT
	# RootLayout: DS-mode reparenting moves RootLayout into a SubViewport, and
	# window chrome belongs to the root window. The layout below it is offset
	# by the strip height via NavigationSubManager._apply_chrome_offset()
	# (InnerLayout.offset_top), which covers the nav rail/bar and the content
	# alike; the bar hides itself when the chrome is inactive (fullscreen).
	if SystemManager and SystemManager.display and SystemManager.display.supports_window_chrome():
		_chrome_layer = CanvasLayer.new()
		_chrome_layer.name = "ChromeLayer"
		_chrome_layer.layer = OverlayLayers.CHROME
		var chrome_parent: Node = _root_control.get_parent()
		if chrome_parent == null:
			chrome_parent = get_tree().root
		chrome_parent.add_child(_chrome_layer)
		_title_bar = TITLE_BAR_SCRIPT.new()
		_title_bar.name = "TitleBar"
		_chrome_layer.add_child(_title_bar)  # _ready() anchors the strip and syncs visibility
		if not _title_bar.visibility_changed.is_connected(_on_title_bar_visibility_changed):
			_title_bar.visibility_changed.connect(_on_title_bar_visibility_changed)
	_status_bar = StatusBar.new()
	var status_layout := VBoxContainer.new()
	status_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	status_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	status_layout.add_theme_constant_override("separation", 0)
	status_layout.add_child(_status_bar)
	status_layout.add_child(content_margin)

	_content_wrapper.add_child(status_layout)
	_content_wrapper.move_child(status_layout, mcv_index)
	print("[UIManager] content margin reparent elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Invisible edge resize grips: stripping the native frame also strips its
	# resize borders. They join the title bar on the ChromeLayer so the window
	# edges stay grabbable above every overlay. Deferred: nothing needs the
	# grips before first paint.
	if _chrome_layer:
		call_deferred("_create_window_resize_grips")

	# Ensure MainContentVBox fills the MarginContainer
	_main_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Initialize the toolbar sub-manager with the controls-bar nodes before views
	# are built so it can sync zoom/view-mode state during startup.
	phase_start_us = Time.get_ticks_usec()
	toolbar.initialize(_main_content_vbox, _content_wrapper)
	print("[UIManager] toolbar init elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Create and sync the centralized card/grid settings state BEFORE views are
	# instantiated so that HomeView/LibraryView and their grids can read the
	# saved layout/orientation during _ready()/_enter_tree().
	phase_start_us = Time.get_ticks_usec()
	card_settings_state = CardSettingsState.new()
	card_settings_state.sync_from_settings_manager()
	print("[UIManager] card settings state sync elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Configure child managers
	phase_start_us = Time.get_ticks_usec()
	navigation.setup(_root_control, _content_wrapper, _inner_layout, nav_type)
	print("[UIManager] navigation.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	view.setup(tab_container)
	print("[UIManager] view.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	overlay.setup(_root_control)
	print("[UIManager] overlay.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	theme.setup(tab_container)
	print("[UIManager] theme.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	dual_screen.setup(_root_control)
	print("[UIManager] dual_screen.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Apply the window-chrome top offset to the inner layout. The first nav
	# rebuild (inside navigation.setup above) ran before overlay.setup()
	# registered the inset resolver, so it read 0; re-assert now that every
	# piece is in place.
	navigation._apply_chrome_offset()

	# Reconnect dual-screen detection signal and re-evaluate current state.
	if SystemManager.display:
		SystemManager.display.dual_screen_mode_changed.connect(dual_screen._on_dual_screen_mode_changed)
		SystemManager.display.ui_scale_changed.connect(_on_ui_scale_changed)
		# Startup race: display can emit ui_scale_changed before this connects
		# (e.g. the persisted user scale factor applying in _load_user_scale_factor),
		# leaving nodes built before initialize() at the stale scale. Nav/views are
		# built after the pending change, so a refresh walk is enough to reconcile.
		if SystemManager.display.consume_pending_scale_refresh():
			theme._do_refresh_scale()
		if SystemManager.display.is_dual_screen_enabled():
			dual_screen._on_dual_screen_mode_changed(true, SystemManager.display.get_second_screen_index())
	print("[UIManager] initialize total elapsed_us=", Time.get_ticks_usec() - init_start_us)

	# Apply library background configuration now and when settings change
	if _library_background and DataManager:
		var bg_setting = DataManager.get_setting("library_background_config")
		if bg_setting and bg_setting.value is Dictionary:
			_library_background.set_background_config(bg_setting.value)

	# Connect settings signals
	DataManager.setting_changed.connect(_on_setting_changed)
	DataManager.settings_saved.connect(_on_settings_saved)
	DataManager.apply_preset_begin.connect(_on_apply_preset_begin)
	DataManager.apply_preset_end.connect(_on_apply_preset_end)
	modal_item_selected.connect(_on_modal_item_selected)

	# Apply dark mode setting on startup (walks the tree only on actual change)
	var dark_mode_setting = DataManager.get_setting("dark_mode")
	if dark_mode_setting:
		theme._apply_dark_mode(dark_mode_setting.value)

	# Track whether any style-affecting value actually changed: the refresh walk
	# below is what propagates these to nodes built earlier in initialize(), and
	# it's a whole-tree cost that boot shouldn't pay when settings match the
	# compiled defaults.
	var style_dirty := false

	# Apply frosted look setting on startup
	var frosted_setting = DataManager.get_setting("frosted_look")
	if frosted_setting and frosted_setting.value is bool:
		if M3Theme.frosted_look != frosted_setting.value:
			M3Theme.frosted_look = frosted_setting.value
			style_dirty = true

	# Apply primary color setting on startup
	var primary_color_setting = DataManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		var primary_before := M3Theme.PRIMARY_LIGHT
		M3Theme.set_primary_seed(primary_color_setting.value)
		if M3Theme.PRIMARY_LIGHT != primary_before:
			style_dirty = true

	# Apply custom interface font on startup
	var ui_font_setting = DataManager.get_setting("ui_font")
	if ui_font_setting and ui_font_setting.value is String and not ui_font_setting.value.is_empty():
		_apply_ui_font(ui_font_setting.value)
		style_dirty = true

	# Apply focus ring animation settings on startup
	var focus_movement_setting = DataManager.get_setting("library_focus_movement_anim")
	if focus_movement_setting and focus_movement_setting.value is int:
		focus.movement_anim = focus_movement_setting.value
	var focus_idle_setting = DataManager.get_setting("library_focus_idle_anim")
	if focus_idle_setting and focus_idle_setting.value is int:
		focus.idle_anim = focus_idle_setting.value
	var focus_thickness_setting = DataManager.get_setting("library_focus_ring_thickness")
	if focus_thickness_setting and (focus_thickness_setting.value is float or focus_thickness_setting.value is int):
		focus.stroke_width_dp = focus_thickness_setting.value
	var focus_shape_setting = DataManager.get_setting("library_focus_ring_shape")
	if focus_shape_setting and focus_shape_setting.value is int:
		_apply_focus_ring_shape(focus_shape_setting.value)
	var focus_outset_setting = DataManager.get_setting("library_focus_ring_outset")
	if focus_outset_setting and (focus_outset_setting.value is float or focus_outset_setting.value is int):
		focus.offset_dp = float(focus_outset_setting.value)

	# Only walk the tree when a style-affecting setting actually changed the
	# M3Theme state from the compiled defaults (see style_dirty above); nodes
	# built during initialize() read current M3Theme values at build time.
	if style_dirty:
		theme._request_theme_refresh()

# ============================================================================
# Layout helpers
# ============================================================================

func _apply_content_margin(margin_container: MarginContainer) -> void:
	var margin := int(M3Units.dp(CONTENT_MARGIN_DP))
	margin_container.add_theme_constant_override("margin_left", margin)
	margin_container.add_theme_constant_override("margin_right", margin)
	margin_container.add_theme_constant_override("margin_top", margin)
	margin_container.add_theme_constant_override("margin_bottom", margin)

func _on_ui_scale_changed(_new_scale: float) -> void:
	"""Live-apply a UI scale change: rescale baked sizes, rebuild nav + views."""
	if _content_margin:
		_apply_content_margin(_content_margin)
	# The chrome strip's pixel height scales with the UI; the nav rebuild below
	# re-asserts the inner layout's top offset after the refresh walk has
	# re-baked the title bar's height (see _rebuild_nav_and_layout).
	theme._do_refresh_scale()
	navigation._rebuild_nav_and_layout()
	view._rebuild_views("ui_scale")

func _create_inner_layout(is_horizontal: bool) -> BoxContainer:
	var layout: BoxContainer
	if is_horizontal:
		layout = VBoxContainer.new()
	else:
		layout = HBoxContainer.new()

	layout.name = "InnerLayout"
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)

	return layout

func _create_window_resize_grips() -> void:
	"""Deferred from initialize(): nothing needs the grips before first paint."""
	if _window_resize_grips or not _chrome_layer:
		return
	_window_resize_grips = RESIZE_GRIPS_SCRIPT.new()
	_window_resize_grips.name = "WindowResizeGrips"
	# Added after the title bar so the top grip strips win hit-testing over the
	# bar's top edge (matching native resize borders). Nothing else is ever
	# added to the ChromeLayer, so this order is stable — no re-raising needed.
	_chrome_layer.add_child(_window_resize_grips)


func _on_title_bar_visibility_changed() -> void:
	"""Re-offset the layout and re-stamp open overlays when the chrome strip
	appears/disappears (windowed <-> fullscreen). The bar toggles on chrome
	changes, window resizes, and focus-in (shuffler sessions restore window
	modes directly), so this catches every path."""
	if navigation:
		navigation._apply_chrome_offset()
	M3Overlay.notify_chrome_inset_changed()


func compute_grid_available_size(grid: VirtualScrollGridContainer, target_view: Control = null) -> Vector2:
	"""Compute the expected available rect for a grid from the active viewport.

	This mirrors the container layout that Godot will apply once sizes propagate
	through MarginContainer/VBoxContainer/TabContainer, so the grid can be settled
	synchronously without waiting for grid.size to update.
	"""
	var start_us := Time.get_ticks_usec()

	# Resolve the active viewport: SubViewport in dual-screen mode, root viewport otherwise.
	# The active check matters: the sub-manager always exists, and after DS mode
	# is disabled its cached viewport is a stale, hidden SubViewport.
	var active_viewport: Viewport = get_viewport()
	if dual_screen and dual_screen._dual_screen_active:
		var sub: Viewport = dual_screen.get_main_viewport()
		if sub:
			active_viewport = sub

	# In SubViewport dual-screen mode, controls see the 2D override size, not the physical size.
	var viewport_size: Vector2i
	if active_viewport is SubViewport:
		var sub: SubViewport = active_viewport as SubViewport
		viewport_size = sub.size_2d_override if sub.size_2d_override != Vector2i.ZERO else sub.size
	else:
		viewport_size = active_viewport.size

	# Subtract the outer margins that wrap MainContentVBox.
	var margin: int = int(M3Units.dp(CONTENT_MARGIN_DP))
	var available_width := maxf(1.0, viewport_size.x - margin * 2)
	var available_height := maxf(1.0, viewport_size.y - margin * 2)

	# Subtract the docked status bar strip (added above the content margin).
	if _status_bar and is_instance_valid(_status_bar) and _status_bar.visible:
		var status_h := maxf(_status_bar.get_combined_minimum_size().y, _status_bar.size.y)
		available_height -= status_h

	# Subtract the custom title bar strip (desktop windowed chrome; sits above
	# the status strip and hides itself in fullscreen).
	if _title_bar and is_instance_valid(_title_bar) and _title_bar.visible:
		var title_h := maxf(_title_bar.get_combined_minimum_size().y, _title_bar.size.y)
		available_height -= title_h

	# Subtract navigation bar/rail dimensions.
	# Use the node's intended minimum size rather than its actual size, because
	# during nav rebuilds the actual size can be transiently inflated (e.g.
	# when a pinned collection is removed and the bar is recreated).
	if navigation:
		var nav_node = navigation._nav_node
		if is_instance_valid(nav_node):
			if nav_node is M3NavigationBar:
				var nav_bar_h = nav_node.custom_minimum_size.y
				if nav_bar_h <= 0:
					nav_bar_h = M3Units.dp(M3NavigationBar.HEIGHT_COMPACT)
				available_height -= nav_bar_h
			elif nav_node is M3NavigationRail:
				var nav_bar_w = nav_node.custom_minimum_size.x
				if nav_bar_w <= 0:
					nav_bar_w = M3Units.dp(M3NavigationRail.WIDTH_COLLAPSED)
				available_width -= nav_bar_w

	# Subtract the toolbar/controlbar height.
	var toolbar_effective_h: float = 0.0
	if _main_content_vbox:
		var controlbar_bg = _main_content_vbox.get_node_or_null("controlbar_background")
		if controlbar_bg:
			var toolbar_min_h = controlbar_bg.get_combined_minimum_size().y
			var toolbar_size_h = controlbar_bg.size.y
			toolbar_effective_h = maxf(toolbar_min_h, toolbar_size_h)
			available_height -= toolbar_effective_h

	# Subtract VBox separation between toolbar and TabContainer.
	if _main_content_vbox:
		var vbox_separation = _main_content_vbox.get_theme_constant("separation")
		available_height -= vbox_separation

	# View-specific chrome above the grid. (The Library platform indicator lives
	# in the control bar now, so its height is covered by the toolbar subtraction.)
	if target_view == null and grid != null:
		var current: Node = grid
		for i in range(3):
			if current == null:
				break
			current = current.get_parent()
		target_view = current as Control

	if target_view is CollectionView:
		var title_label: Control = target_view.get_node_or_null("MarginContainer/VBoxContainer/CollectionTitle")
		if title_label:
			title_label.size.x = available_width
			available_height -= title_label.get_combined_minimum_size().y

	var result := Vector2(maxf(1.0, available_width), maxf(1.0, available_height))
	if DEBUG_LOG: print("[UIManager] compute_grid_available_size: view=", target_view.view_name if target_view is View else (String(target_view.name) if target_view else "unknown"), " result=", result, " elapsed_us=", Time.get_ticks_usec() - start_us)
	return result

# ============================================================================
# Public shell API (thin wrappers around child managers)
# ============================================================================

func switch_to_tab(tab_name: String):
	var current: View = view.get_current_view()
	if current == null or current.view_name == tab_name:
		view.switch_to_tab(tab_name)
		return
	var icon_name: String = navigation.get_transition_icon_for_view(tab_name)
	var transition := _get_view_transition_overlay()
	if icon_name.is_empty() or transition == null or transition.is_animating():
		view.switch_to_tab(tab_name)
		return
	transition.play_extended(icon_name, func(): view.switch_to_tab(tab_name), func(): return view.is_view_ready_for_reveal(tab_name), 400)

## Switch tabs without the transition animation. Used when a follow-up async
## step (grid reload, deferred focus) must find the target view already
## current — a 400ms transition would suppress is_current_view guards.
func switch_to_tab_immediate(tab_name: String):
	view.switch_to_tab(tab_name)

var _view_transition_overlay: ViewTransitionOverlay = null

func _get_view_transition_overlay() -> ViewTransitionOverlay:
	if _view_transition_overlay == null or not is_instance_valid(_view_transition_overlay):
		_view_transition_overlay = get_tree().get_first_node_in_group("view_transition_overlay") as ViewTransitionOverlay
	return _view_transition_overlay

func get_current_view() -> View:
	return view.get_current_view()

func is_current_view(view_name: String) -> bool:
	return view.is_current_view(view_name)

func get_view(view_name: String) -> View:
	return view.get_view(view_name)

## True for views that host a VirtualScrollGridContainer (Home, Library, Favorites,
## Collection_*, Platform_*).
func _is_grid_view_name(view_name: String) -> bool:
	return view_name == "Home" or view_name == "Library" or view_name == "Favorites" \
		or view_name.begins_with("Collection_") or view_name.begins_with("Platform_")

## Resolve the VirtualScrollGridContainer inside a view, if present.
func get_view_grid(target_view: View) -> VirtualScrollGridContainer:
	if not target_view:
		return null
	if target_view.has_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer"):
		return target_view.get_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer") as VirtualScrollGridContainer
	return null

## Apply a callable to every instantiated grid view.
func apply_to_all_grids(callable: Callable) -> void:
	if not view:
		return
	for grid in view.get_all_grids():
		callable.call(grid)

## Find the View that owns a given grid, if any.
func get_view_for_grid(grid: VirtualScrollGridContainer) -> View:
	if not view or not grid:
		return null
	for view_name in view._views.keys():
		if not _is_grid_view_name(view_name):
			continue
		var v = view.get_view(view_name)
		if v and get_view_grid(v) == grid:
			return v
	return null

func rebuild_game_grid() -> void:
	view.rebuild_game_grid()

func _on_modal_item_selected(item_id: String, _context: Dictionary) -> void:
	if item_id == "background_designer":
		show_settings_dialog_with_category("background_designer")

func show_settings_dialog() -> void:
	overlay.show_settings_dialog()

func get_onscreen_keyboard() -> PanelContainer:
	if _onscreen_keyboard and is_instance_valid(_onscreen_keyboard):
		return _onscreen_keyboard
	_onscreen_keyboard = get_tree().root.find_child("OnscreenKeyboard", true, false)
	return _onscreen_keyboard

func is_onscreen_keyboard_visible() -> bool:
	var kb = get_onscreen_keyboard()
	return kb != null and kb.visible

func is_focus_in_onscreen_keyboard(control: Control) -> bool:
	var kb = get_onscreen_keyboard()
	return kb != null and kb.is_focus_within_keyboard(control)

func pre_create_settings_dialog(force: bool = false) -> void:
	await overlay.pre_create_settings_dialog(force)

func is_settings_dialog_open() -> bool:
	return overlay.is_settings_dialog_open()

func set_status_bar_polling(enabled: bool) -> void:
	if _status_bar and is_instance_valid(_status_bar):
		_status_bar.set_polling_enabled(enabled)

func show_settings_dialog_with_category(category_id: String) -> void:
	overlay.show_settings_dialog_with_category(category_id)

func show_shuffler_dialog() -> void:
	overlay.show_shuffler_dialog()

func set_card_designer_preview_game(romm_id: int) -> void:
	overlay.set_card_designer_preview_game(romm_id)

func get_settings_dialog_platforms_view() -> PlatformsSettingsView:
	return overlay.get_settings_dialog_platforms_view()

func show_background_context_menu(anchor: Control) -> String:
	return overlay.show_background_context_menu(anchor)

func show_game_context_menu(romm_id: int, anchor: Control, show_delete: bool = true, show_hide: bool = false) -> String:
	return overlay.show_game_context_menu(romm_id, anchor, show_delete, show_hide)

func show_add_to_collection_picker(romm_id: int) -> void:
	overlay.show_add_to_collection_picker(romm_id)

func show_context_menu(items: Array[Dictionary], anchor: Control, context: Dictionary = {}) -> String:
	return overlay.show_context_menu(items, anchor, context)

func show_game_details(romm_id: int) -> void:
	overlay.show_game_details(romm_id)

func dismiss_modal() -> void:
	overlay.dismiss_modal()

func is_modal_open() -> bool:
	return overlay.is_modal_open()

func show_folder_dialog(title: String, initial_dir: String, on_dir_selected: Callable, use_native: bool = true) -> FileDialog:
	return overlay.show_folder_dialog(title, initial_dir, on_dir_selected, use_native)

func show_file_dialog(title: String, filters: PackedStringArray, initial_dir: String, on_file_selected: Callable, use_native: bool = true) -> FileDialog:
	return overlay.show_file_dialog(title, filters, initial_dir, on_file_selected, use_native)

func show_confirm(title: String, body: String, on_accept: Callable = Callable(), on_cancel: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_confirm(title, body, on_accept, on_cancel, on_dismissed, options)

func show_alert(title: String, body: String, on_ok: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_alert(title, body, on_ok, on_dismissed, options)

func show_custom_dialog(build_fn: Callable, on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_custom_dialog(build_fn, on_dismissed, options)

func has_active_dialog() -> bool:
	return overlay.has_active_dialog()

func find_home_button() -> Control:
	return navigation.find_home_button()

func find_nav_settings_button() -> Control:
	return navigation.find_nav_settings_button()

func get_last_nav_destination() -> Control:
	return navigation.get_last_nav_destination()

func get_active_nav_destination() -> Control:
	return navigation.get_active_nav_destination()

func get_nav_type() -> int:
	return navigation.get_nav_type()

func is_focus_lock_active() -> bool:
	return _focus_lock_active

func should_card_grab_focus_on_hover() -> bool:
	return navigation.should_card_grab_focus_on_hover()

func suppress_next_focus_sound() -> void:
	navigation.suppress_next_focus_sound()

func controller_has_priority() -> bool:
	return navigation.controller_has_priority()

func handle_directional_input(event: InputEvent) -> bool:
	return navigation.handle_directional_input(event)

# ============================================================================
# Focus save/restore helpers
# ============================================================================

## Capture the current focus owner as a WeakRef.
## If focus is inside the on-screen keyboard, resolves to the active LineEdit.
func capture_focus() -> WeakRef:
	var focus_owner := get_current_focus_owner()
	if focus_owner != null and is_instance_valid(focus_owner):
		return weakref(focus_owner)
	return null

## Restore focus from a captured WeakRef. If the captured control is no longer
## valid or visible, the optional fallback callable is invoked.
func restore_focus(saved_focus: WeakRef, fallback: Callable = Callable()) -> void:
	if saved_focus == null:
		_run_focus_fallback(fallback)
		return
	var focus_owner: Control = saved_focus.get_ref()
	if not is_instance_valid(focus_owner) or not focus_owner.is_visible_in_tree():
		_run_focus_fallback(fallback)
		return
	grab_focus_silent(focus_owner)

## Deferred, sound-suppressed grab_focus.
func grab_focus_silent(control: Control) -> void:
	if not is_instance_valid(control) or not control.is_visible_in_tree():
		return
	suppress_next_focus_sound()
	control.grab_focus.call_deferred()

## Returns the viewport that actually owns GUI focus for the app UI. In
## dual-screen mode the UI is reparented into a SubViewport, so this manager's
## own root viewport has no focus owner.
func get_active_viewport() -> Viewport:
	if _root_control and is_instance_valid(_root_control) and _root_control.is_inside_tree():
		return _root_control.get_viewport()
	return get_viewport()

## Returns the current focus owner, resolving through the on-screen keyboard.
func get_current_focus_owner() -> Control:
	var viewport := get_active_viewport()
	if not viewport:
		return null
	var focus_owner := viewport.gui_get_focus_owner()
	if not is_instance_valid(focus_owner):
		return null
	# If focus is inside the on-screen keyboard, resolve to the active LineEdit
	# (or the previous focus object if the keyboard is mid-dismissal).
	if is_focus_in_onscreen_keyboard(focus_owner):
		var keyboard := get_onscreen_keyboard()
		if keyboard != null and is_instance_valid(keyboard):
			var active_edit: LineEdit = keyboard.get_active_line_edit()
			if active_edit != null and is_instance_valid(active_edit):
				return active_edit
			var previous: Control = keyboard.get_previous_focus_object()
			if previous != null and is_instance_valid(previous):
				return previous
	return focus_owner

## Returns a callable that restores focus to the Home button.
func get_focus_restore_fallback_to_home() -> Callable:
	return func():
		var home := find_home_button()
		if home != null and is_instance_valid(home):
			grab_focus_silent(home)

func _run_focus_fallback(fallback: Callable) -> void:
	if fallback.is_valid():
		fallback.call()

# ============================================================================
# Focus lock: disable focus on all non-grid controls while a locked grid owns focus
# ============================================================================

func enter_focus_lock(grid: VirtualScrollGridContainer) -> void:
	"""Activate scene-wide focus lock around the given grid."""
	if _focus_lock_active and _focus_locked_grid == grid:
		return
	# If we were already locked to a different grid, restore first.
	if _focus_lock_active:
		_exit_focus_lock()
	_focus_locked_grid = grid
	_focus_lock_active = true
	_focusables_cache_valid = false
	if not get_tree().node_added.is_connected(_on_lock_tree_node_added):
		get_tree().node_added.connect(_on_lock_tree_node_added)
	_apply_focus_lock()

func exit_focus_lock(grid: VirtualScrollGridContainer) -> void:
	"""Exit focus lock if it is currently held by the given grid."""
	if not _focus_lock_active:
		return
	if _focus_locked_grid != grid:
		return
	_exit_focus_lock()

func release_focus_lock() -> void:
	"""Force-exit the focus lock regardless of which grid holds it.

	Used by pointer-initiated escapes (e.g. tapping a nav destination while
	grid-locked) where the caller doesn't know the owning grid."""
	_exit_focus_lock()

func _exit_focus_lock() -> void:
	if not _focus_lock_active:
		return
	_focus_lock_active = false
	_focus_locked_grid = null
	if get_tree().node_added.is_connected(_on_lock_tree_node_added):
		get_tree().node_added.disconnect(_on_lock_tree_node_added)
	_focusables_cache.clear()
	_focusables_cache_valid = false
	_restore_focus_modes()

func _on_lock_tree_node_added(node: Node) -> void:
	"""Invalidate the focusables cache when a Control appears outside the locked grid."""
	if _focusables_cache_valid and node is Control and _is_in_lock_scope(node):
		_focusables_cache_valid = false

func _is_in_lock_scope(node: Node) -> bool:
	if not _root_control or not _root_control.is_ancestor_of(node):
		return false
	if _focus_locked_grid and (_focus_locked_grid == node or _focus_locked_grid.is_ancestor_of(node)):
		return false
	return true

func queue_refresh_focus_lock_state() -> void:
	"""Coalesce refresh requests: at most one lock re-apply per frame."""
	if _focus_lock_refresh_queued:
		return
	_focus_lock_refresh_queued = true
	call_deferred("_refresh_focus_lock_state_deferred")

func _refresh_focus_lock_state_deferred() -> void:
	_focus_lock_refresh_queued = false
	refresh_focus_lock_state()

func _ensure_focus_after_preset() -> void:
	# Let the deferred theme refresh (and its nested focus restore) land first;
	# we only act if focus is genuinely absent afterwards.
	await get_tree().process_frame
	# An open overlay owns focus via its own machinery.
	if M3Overlay._get_topmost_overlay() != null:
		return
	var viewport: Viewport = null
	if navigation:
		viewport = navigation._get_active_viewport()
	if not viewport:
		return
	var focused := viewport.gui_get_focus_owner()
	if focused and is_instance_valid(focused) and focused.is_visible_in_tree():
		return
	get_focus_restore_fallback_to_home().call()

func refresh_focus_lock_state() -> void:
	"""Re-apply the current focus lock after layout/theme changes."""
	if not _focus_lock_active or not _focus_locked_grid:
		return
	if not is_instance_valid(_focus_locked_grid) or not _focus_locked_grid.is_inside_tree():
		_exit_focus_lock()
		return
	# Only remain locked if the grid still has focus.
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		_exit_focus_lock()
		return
	var focused := viewport.gui_get_focus_owner()
	if not focused or not _focus_locked_grid.is_ancestor_of(focused):
		_exit_focus_lock()
		return
	# Re-apply in case new focusable controls were created.
	_apply_focus_lock()

func _apply_focus_lock() -> void:
	"""Save and disable focus modes for all controls outside the locked grid."""
	if not _focus_locked_grid or not _root_control:
		return
	var focusables := _get_focusables()
	for ctrl in focusables:
		if not is_instance_valid(ctrl):
			continue
		if ctrl.focus_mode == Control.FOCUS_NONE:
			continue
		var id := ctrl.get_instance_id()
		if not _saved_focus_modes.has(id):
			_saved_focus_modes[id] = [weakref(ctrl), ctrl.focus_mode]
		ctrl.focus_mode = Control.FOCUS_NONE

func _get_focusables() -> Array[Control]:
	if _focusables_cache_valid:
		return _focusables_cache
	_focusables_cache = _gather_focusable_controls(_root_control)
	_focusables_cache_valid = true
	return _focusables_cache

func _restore_focus_modes() -> void:
	"""Restore original focus modes saved by _apply_focus_lock."""
	for id in _saved_focus_modes.keys():
		var entry: Array = _saved_focus_modes[id]
		var ctrl: Control = (entry[0] as WeakRef).get_ref()
		if ctrl and is_instance_valid(ctrl):
			ctrl.focus_mode = entry[1]
	_saved_focus_modes.clear()

func _gather_focusable_controls(node: Node) -> Array[Control]:
	"""Recursively collect Controls with non-NONE focus modes."""
	var result: Array[Control] = []
	if node is Control and node.focus_mode != Control.FOCUS_NONE:
		result.append(node)
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		# Don't descend into the locked grid or its children.
		if _focus_locked_grid and (_focus_locked_grid == child or _focus_locked_grid.is_ancestor_of(child)):
			continue
		# Don't descend into overlays/dialogs (CanvasLayer children).
		if child is CanvasLayer:
			continue
		result.append_array(_gather_focusable_controls(child))
	return result

## Maps the library_focus_ring_shape option index onto the manager's Shape
## enum (the dropdown is a subset: 0 = Full, 1 = Corners).
func _apply_focus_ring_shape(index: int) -> void:
	focus.ring_shape = FocusSubManager.Shape.CORNERS if index == 1 else FocusSubManager.Shape.BOX

# ============================================================================
# High-level setting-change dispatcher
# ============================================================================

func _on_settings_saved() -> void:
	"""Re-sync CardSettingsState after a save in case anything bypassed set_setting."""
	if card_settings_state:
		card_settings_state.sync_from_settings_manager()

func apply_settings_now() -> void:
	"""Public hook for settings dialog dismissal; ensures CardSettingsState re-syncs."""
	_on_settings_saved()

func _on_apply_preset_begin() -> void:
	"""Batch card settings updates during preset application."""
	if card_settings_state:
		card_settings_state.begin_batch()
	theme._on_apply_preset_begin()

func _on_apply_preset_end() -> void:
	"""Flush batched card settings and let each subsystem react."""
	var mask := CardSettingsState.ChangeMask.NONE
	if card_settings_state:
		mask = card_settings_state.end_batch() as CardSettingsState.ChangeMask
	# Effect changes need a full view rebuild; layout/display/media shape/theme
	# changes are applied live by the grid and other setting_changed handlers.
	if mask & CardSettingsState.ChangeMask.EFFECTS:
		view._rebuild_views("Preset applied", true)
	theme._on_apply_preset_end()
	# Theme/layout may have created new focusable controls; re-apply lock if needed.
	queue_refresh_focus_lock_state()
	# Last-resort focus guarantee once all deferred restores have settled.
	call_deferred("_ensure_focus_after_preset")

var _persisting_ui_font_path: bool = false

func _apply_ui_font(path: String) -> void:
	"""Point M3Theme's font endpoint at the user's font, empty restores default."""
	if path.is_empty():
		M3Theme.set_custom_font("")
		return
	# Resolve/import content:// URIs (Android file picker) to a durable real path
	var effective_path: String = FSM.import_content_file(path, "user://fonts/")
	if effective_path != path and not _persisting_ui_font_path:
		# Persist the usable path back to the setting (re-emits setting_changed)
		_persisting_ui_font_path = true
		var ui_font_setting = DataManager.get_setting("ui_font")
		if ui_font_setting:
			DataManager.set_setting(effective_path, ui_font_setting)
		_persisting_ui_font_path = false
	M3Theme.set_custom_font(effective_path)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes.

	Each subsystem reacts to its own setting directly. Card/grid setting changes
	are batched during preset application so the grid reacts once at the end.
	"""
	if card_settings_state:
		card_settings_state.apply_setting(setting.property_name, _value)

	if DEBUG_LOG: print("[UIManager] _on_setting_changed: %s" % setting.property_name)
	match setting.property_name:
		"library_background_config":
			if _library_background and _value is Dictionary:
				_library_background.set_background_config(_value)
		"library_navigation_type":
			navigation.set_nav_type(setting.value)
			navigation._rebuild_nav_and_layout()
			# Nav rebuild may add/reparent focusable controls; re-apply lock.
			queue_refresh_focus_lock_state()
		"hero_effect_config":
			var hero_image = get_hero_image()
			if hero_image and hero_image.has_method("refresh_from_settings"):
				hero_image.refresh_from_settings()
			view.mark_view_for_rebuild("Home", "Hero effect config changed")
			view.mark_view_for_rebuild("Library", "Hero effect config changed")
		"dark_mode":
			if _value is bool:
				# During preset apply the incoming configs already carry colors
				# for their saved (main) mode; swapping variants here would
				# mislabel/double-convert them.
				if not theme._preset_in_progress:
					EffectThemeAdapter.on_dark_mode_changed(_value)
			theme._apply_dark_mode(_value)
		"frosted_look":
			if _value is bool:
				M3Theme.frosted_look = _value
				theme._request_theme_refresh()
		"ui_font":
			if _value is String:
				_apply_ui_font(_value)
				theme._request_theme_refresh()
		"library_primary_color":
			M3Theme.set_primary_seed(_value)
			theme._request_theme_refresh()
			if focus:
				focus.refresh()
		"library_focus_movement_anim":
			if focus and _value is int:
				focus.movement_anim = _value
		"library_focus_idle_anim":
			if focus and _value is int:
				focus.idle_anim = _value
		"library_focus_ring_thickness":
			if focus and (_value is float or _value is int):
				focus.stroke_width_dp = _value
		"library_focus_ring_shape":
			if focus and _value is int:
				_apply_focus_ring_shape(_value)
		"library_focus_ring_outset":
			if focus and (_value is float or _value is int):
				focus.offset_dp = float(_value)
		# Card/grid specific settings (layout_mode, grid_vertical, card_zoom,
		# grid_padding, focus_scale, display_mode, content_alignment, media_ratio,
		# show_title_mode, card_effect_config, focus_lock) are owned by
		# CardSettingsState. VirtualScrollGridContainer and GameCard react to its
		# typed change events directly.
		_:
			pass

# ============================================================================
# Hero / library background helpers
# ============================================================================

func get_hero_image() -> HeroImage:
	if dual_screen:
		return dual_screen.get_hero_image()
	return null

func _on_hero_game_changed(game: GameResource) -> void:
	"""Update the resolved hero from the focused view's game."""
	var hero_image = get_hero_image()
	if not hero_image:
		return

	var current_view = view.get_current_view()
	if not current_view or not current_view.supports_hero:
		return

	# Check if hero height is set to 0% (hidden)
	var hero_config_setting = DataManager.get_setting("hero_effect_config") if DataManager else null
	var hero_config = hero_config_setting.value if hero_config_setting and hero_config_setting.value is Dictionary else {}
	var height_index = hero_config.get("hero_height", 0)
	var height_ratio = 0.0
	if height_index is int or height_index is float:
		var idx = int(height_index)
		var ratios = [1.0, 0.66, 0.5, 0.33, 0.0]
		if idx >= 0 and idx < ratios.size():
			height_ratio = ratios[idx]
	if height_ratio == 0.0:
		return

	if game:
		hero_image.set_game(game)
	else:
		hero_image.clear()

# ============================================================================
# Cleanup
# ============================================================================

func pre_shutdown_cleanup() -> void:
	"""Release static UI caches before the tree is freed.

	Can be called safely while the UI tree is still alive.
	"""
	MemorySubManager.clear_texture_cache()
	M3Theme.clear_theme_cache()
	EffectStack.clear_script_cache()
	GameCard.clear_platform_icon_cache()
	LaunchTransitionOverlay._clear_source_override()
	M3NavigationDestination.clear_shared_stylebox()
	M3MenuRenderer.clear_shared_stylebox()
	LibraryFilterSheet.cleanup_instance()
	PlatformCardPool.clear()

func _exit_tree() -> void:
	"""Release the UIManager's cached references so the engine can free the UI tree.
	Nodes still in the tree are left for the tree to free; orphaned overlays are
	freed immediately because queue_free() may not flush during process exit."""

	FrameWorkScheduler.unregister(self)
	_exit_focus_lock()

	# Drop all cached node references so the tree can free them.
	_root_control = null
	_inner_layout = null
	_main_content_vbox = null
	_content_wrapper = null
	_chrome_layer = null
	_title_bar = null
	_window_resize_grips = null

	# Release static caches that hold resources.
	pre_shutdown_cleanup()
