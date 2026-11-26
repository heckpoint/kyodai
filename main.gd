extends Control

const DEBUG_LOG: bool = false
# ShaderPrewarmer and StartupBenchmark are global classes; no preload consts.

var tab_container: TabContainer
var library_background: LibraryBackground
var content_wrapper: Control
var main_content_vbox: VBoxContainer
var root_layout: Control

var _keyboard: PanelContainer = null
var _ui_layer: CanvasLayer = null
var _input_gate: Node = null

## Swallows all input while an emulator is running (background state or a
## lingering process group). Exists as Main's rightmost child because _input
## propagates deepest/rightmost-first: views would otherwise consume the
## event before Main._input ever gets to block it.
class BackgroundInputGate:
	extends Node
	func _input(_event: InputEvent) -> void:
		if LaunchManager and (LaunchManager.is_in_background_state() \
				or (LaunchManager.process and LaunchManager.process.has_lingering_process())):
			get_viewport().set_input_as_handled()

func _on_main_child_entered_tree(node: Node) -> void:
	if node != _input_gate and is_instance_valid(_input_gate) and _input_gate.get_parent() == self:
		move_child(_input_gate, get_child_count() - 1)

var _zoom_in_pressed: bool = false
var _zoom_out_pressed: bool = false

var _last_focused_index: int = -1
var _trimmed_for_launch: bool = false
var _rendering_suspended: bool = false
var _android_resume_reconciling: bool = false
var _prev_viewport_update_mode: int = -1

## Min interval between heavy NOTIFICATION_APPLICATION_RESUMED runs. Godot
## delivers RESUMED in pairs on Android (activity + render view), and activity
## churn (e.g. an intent bouncing back) can produce storms; the refresh work
## gated by this is idempotent, so it only needs to run once per burst.
const RESUME_HEAVY_DEBOUNCE_MS: int = 1000
var _last_resume_heavy_ms: int = -1


func _enter_tree():
	# Set the global startup suppression flag as early as possible so that every
	# VirtualScrollGridContainer (including HomeView created during scene load)
	# defers its expensive pool creation and layout until Main settles it once.
	VirtualScrollGridContainer.startup_layout_suppressed = true

	# Boot at full frame throughput: startup is a long chain of
	# await-process_frame stages, and low-processor mode's idle sleep taxes
	# every one of them. SystemManager.display.reapply_power_mode() restores
	# the configured pacing once the home grid has settled.
	OS.low_processor_usage_mode = false

	# Kick the settings dialog script load immediately: its deep preload chain
	# takes ~500ms on the loader thread, so starting here (instead of in
	# overlay.setup) lets it finish before the pre-create consumes it.
	ResourceLoader.load_threaded_request(OverlaySubManager.SETTINGS_DIALOG_SCRIPT_PATH, "", true)

func _ready():
	var main_ready_start_us := Time.get_ticks_usec()

	# Headless companion mode: launched by Steam shortcuts written by
	# SteamVDFWriter (kyodai --headless -- --kyodai-launch <romm_id>). Skips all
	# UI init and runs save sync around the emulator process, then exits.
	var headless_romm_id := HeadlessLaunchRunner.parse_launch_romm_id()
	if headless_romm_id > 0:
		var headless_runner := HeadlessLaunchRunner.new()
		add_child(headless_runner)
		headless_runner.run(headless_romm_id)
		return

	# Disable automatic quit so we can free the scene tree before the rendering
	# server shuts down. Without this, get_tree().quit() exits without destroying
	# nodes, which causes CanvasItem/Texture RID leaks.
	get_tree().auto_accept_quit = false

	# Set window title (Window.title also feeds the custom title bar strip,
	# which mirrors it via the title_changed signal).
	get_window().title = "Kyodai - Game Launcher"

	# Preload the Home view scene on a worker thread while the window settles
	ResourceLoader.load_threaded_request("res://view/home_view.tscn")

	if SystemManager.display:
		await SystemManager.display.initial_window_size_settled

	if DEBUG_LOG: print("[Main] initial_window_size_settled elapsed_us=", Time.get_ticks_usec() - main_ready_start_us)
	WarmupBudget.tag("main_ready")

	# Get all nodes using get_node to ensure they're ready
	tab_container = get_node("RootLayout/ContentWrapper/MainContentVBox/TabContainer")
	library_background = get_node("RootLayout/ContentWrapper/LibraryBackground")
	content_wrapper = get_node("RootLayout/ContentWrapper")
	main_content_vbox = get_node("RootLayout/ContentWrapper/MainContentVBox")
	root_layout = get_node("RootLayout")

	# Cache the on-screen keyboard and UILayer references (survive reparenting in dual-screen mode)
	_ui_layer = get_node_or_null("UILayer")
	_keyboard = get_node_or_null("UILayer/OnscreenKeyboard")

	# Reconcile a pending UI-scale change before building nav/views: the tree
	# is only main.tscn + autoloads at this point, so the refresh walk is at
	# its smallest, and everything built afterwards reads the already-updated
	# M3Units values.
	UIManager.reconcile_early_scale_change()

	# Initialize UIManager with all the pre-built nodes
	var phase_start_us := Time.get_ticks_usec()
	UIManager.initialize(
		tab_container,
		library_background,
		content_wrapper,
		main_content_vbox,
		root_layout
	)
	if DEBUG_LOG: print("[Main] UIManager.initialize elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	WarmupBudget.tag("ui_init")

	# Boot-frame split: initialize (nav/views build) and the rest of _ready
	# (connects, theme, settle) no longer share one frame. Grid layout is
	# still suppressed here, so nothing new paints during this frame.
	await get_tree().process_frame

	# Connect toolbar sub-manager signals (zoom slider, view-mode buttons,
	# more-options menu, user avatar).
	UIManager.toolbar.connect_signals()

	# Connect to UIManager for tab changes and settings dialog
	UIManager.tab_changed.connect(_on_tab_changed)

	# Re-sync zoom slider when viewport size changes (e.g. window resize).
	# The grid re-snaps its zoom in _on_resize_debounced(), but the slider
	# stops and position need to be updated from main.gd since it owns the UI.
	if SystemManager.display:
		SystemManager.display.viewport_size_changed.connect(_on_viewport_resized)

	# Connect to DataManager to sync UI when presets are applied
	if DataManager:
		DataManager.apply_preset_end.connect(_on_preset_applied)
		# Confirm dialog for above-threshold server-deletion batches.
		DataManager.server_deletions_detected.connect(_on_server_deletions_detected)

	# Connect to LaunchManager to save focus before game launch
	if LaunchManager:
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)
		# Connect to background state signals for desktop
		LaunchManager.session_activated.connect(_on_session_activated)
		LaunchManager.session_retained.connect(_on_session_retained)
		LaunchManager.session_resumed.connect(_on_session_resumed)
		LaunchManager.session_finalized.connect(_on_session_finalized)
		# Hibernate (release reclaimable memory) before the process/intent starts
		LaunchManager.pre_launch_hook = _pre_launch_trim
		LaunchManager.launch_failed_hook = _restore_after_launch

	if Engine.has_singleton("KyodaiBridge"):
		var bridge = Engine.get_singleton("KyodaiBridge")
		if bridge and not bridge.is_connected("android_home_requested", _on_android_home_requested):
			bridge.connect("android_home_requested", _on_android_home_requested)
		if bridge and not bridge.is_connected("android_task_event", _on_android_task_event):
			bridge.connect("android_task_event", _on_android_task_event)

	# Android memory-pressure escalation (plugin forwards onTrimMemory levels)
	if SystemManager and SystemManager.platform:
		SystemManager.platform.trim_memory.connect(_on_android_trim_memory)

	# Keep the input gate rightmost so it swallows emulator input before views.
	_input_gate = BackgroundInputGate.new()
	_input_gate.name = "BackgroundInputGate"
	child_entered_tree.connect(_on_main_child_entered_tree)
	add_child(_input_gate)
	move_child(_input_gate, get_child_count() - 1)

	# Set initial view controls
	phase_start_us = Time.get_ticks_usec()
	UIManager.toolbar.sync_view_mode_button_to_setting()
	UIManager.toolbar.sync_zoom_slider_to_view("Home")
	if DEBUG_LOG: print("[Main] view mode setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Apply M3 theme to root for fallback native control styling before grid is shown.
	phase_start_us = Time.get_ticks_usec()
	_apply_m3_theme()
	if DEBUG_LOG: print("[Main] _apply_m3_theme elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Connect to screen swap signal and restore the saved swap state.
	# The dual_screen_swapped setting lifecycle is owned by DualScreenSubManager.
	phase_start_us = Time.get_ticks_usec()
	UIManager.dual_screen.setup_swap_persistence()
	if DEBUG_LOG: print("[Main] screen swap setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Second boot-frame split: the settle + zoom sync run in their own frame
	# instead of stacking onto the connects/theme work above.
	await get_tree().process_frame
	WarmupBudget.tag("main_settle")

	# Single final layout: settle the visible grid(s) now that the window size and
	# screen swap state are final. This is the one layout pass that should happen
	# during startup; any resize events triggered before this point are suppressed.
	# Grids in hidden tabs have no valid size yet and will settle naturally when shown.
	var settle_start_us := Time.get_ticks_usec()
	print("[Main] Unsuppressing grid layout and settling once...")
	VirtualScrollGridContainer.startup_layout_suppressed = false
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = UIManager.get_view_grid(current_view)
		if grid:
			# Use a deterministic computed size rather than relying on grid.size, which
			# may not have caught up to the post-swap viewport yet. Keep it set so
			# later layout passes keep using the expected viewport rect.
			var grid_settle_start_us := Time.get_ticks_usec()
			var available_size := UIManager.compute_grid_available_size(grid, current_view)
			grid.set_deterministic_available_size(available_size)
			if DEBUG_LOG: print("[Main] settle: set_deterministic_available_size elapsed_us=", Time.get_ticks_usec() - grid_settle_start_us)
			# The total count arrives asynchronously when the DB cache is cold.
			# Settling with 0 items sizes the card pool to 0 and forces a full
			# post-settle relayout when data lands (collapsed layout + a burst of
			# synchronous card instantiations). Wait for the count first.
			_settle_grid_when_data_ready(grid, current_view, available_size, grid_settle_start_us)
	else:
		print("[Main] No current view to settle")

	# Sync zoom slider to the final grid ratio without reapplying zoom to the grids.
	# Keep the deterministic startup size active so get_snap_ratios() works even
	# though Godot hasn't propagated grid.size yet.
	phase_start_us = Time.get_ticks_usec()
	UIManager.toolbar.sync_zoom_slider_to_current_view()
	if DEBUG_LOG: print("[Main] _sync_zoom_slider_to_current_view elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	# Save the current level and snapped ratio so the settings stay in sync with
	# the slider and don't hold stale values from a previous viewport size.
	if current_view:
		var grid = UIManager.get_view_grid(current_view)
		if grid:
			UIManager.toolbar.persist_settled_zoom(grid)
	if DEBUG_LOG: print("[Main] Settle block total elapsed_us=", Time.get_ticks_usec() - settle_start_us)

	# Self-healing for the Android "live engine, black screen" surface-loss
	# failure: arms only after startup settles, no-ops on desktop and in the
	# headless companion (which returned early above). See BlackScreenWatchdog.
	add_child(BlackScreenWatchdog.new())

	# Compile all shader pipelines in the background so the first scroll/focus
	# doesn't pay lazy-compile hitches. Deferred + internally delayed so first
	# paint and grid settle win the main thread.
	call_deferred("_prewarm_shader_pipelines")

	# Focus the first Home card on startup once data is loaded.
	var first_run_setting = DataManager.get_setting("first_run_completed")
	if first_run_setting and first_run_setting.value:
		call_deferred("_focus_first_home_card_on_startup")

	# Startup zoom sync is complete; clear the guard after the current frame so
	# any deferred slider emissions that fire during this frame are ignored.
	# finish_startup_zoom_sync also connects the slider's continuous
	# value_changed -> _on_zoom_changed (without it the zoom bar dead-ends).
	UIManager.toolbar.call_deferred("finish_startup_zoom_sync")
	if DEBUG_LOG: print("[Main] _ready() completed, elapsed_us=", Time.get_ticks_usec() - main_ready_start_us)

	# Non-critical boot work (OOBE wizard, avatar fetch, tool extraction,
	# settings-dialog pre-create) runs after the settle frame so none of it
	# sits between _ready() and first paint.
	call_deferred("_post_ready_startup")

	# Headless benchmark modes (--benchmark-startup / --benchmark-shutdown and
	# related flags) live in utils/perf/startup_benchmark.gd.
	if await StartupBenchmark.run_from_args(self):
		return

func _post_ready_startup() -> void:
	"""Second boot phase: runs deferred after the Home grid settle so first
	paint isn't blocked by wizard/avatar/extraction work."""
	var post_start_us := Time.get_ticks_usec()
	var phase_start_us := Time.get_ticks_usec()

	# Check if first-run wizard needs to be shown
	_show_oobe_wizard_if_needed()
	if DEBUG_LOG: print("[Main] _show_oobe_wizard_if_needed elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Kick the avatar fetch/decode now that the grid is up.
	phase_start_us = Time.get_ticks_usec()
	if UIManager and UIManager.toolbar:
		UIManager.toolbar.fetch_avatar_when_idle()
	if DEBUG_LOG: print("[Main] avatar kickoff elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Extract bundled tools on packaged builds (binaries inside the PCK cannot
	# be executed). File IO + chmod; every consumer also extracts lazily on
	# demand (extract_binary is idempotent), so this warm-up runs on the
	# extraction worker instead of the startup path.
	if SystemManager.platform.is_packaged():
		phase_start_us = Time.get_ticks_usec()
		MemorySubManager.queue_extraction_task(func():
			AndroidBinaryExtractor.extract_all_binaries()
		)
		if DEBUG_LOG: print("[Main] binary extraction kickoff elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Self-update check: fire-and-forget GitHub release lookup on the user's
	# configured channel; shows a dialog only when a newer release exists.
	AppUpdateChecker.check_for_updates()

	# Pre-create the settings dialog in the background so opening it later
	# (especially the RomM platform cards screen) is instant.
	var first_run_setting = DataManager.get_setting("first_run_completed")
	if first_run_setting and first_run_setting.value:
		call_deferred("_pre_create_settings_dialog")

	if DEBUG_LOG: print("[Main] _post_ready_startup elapsed_us=", Time.get_ticks_usec() - post_start_us)

func _apply_m3_theme() -> void:
	theme = M3Theme.generate_theme()

func refresh_theme() -> void:
	# Called by UIManager when theme colors change (dark mode, primary color, etc.)
	_apply_m3_theme()
	if UIManager and UIManager.toolbar:
		UIManager.toolbar.update_controlbar_mask_color()

func refresh_scale() -> void:
	# main.gd bakes no dp-derived sizes itself (the dp(16) margins around
	# MainContentVBox are owned by UIManager); children re-bake their own.
	refresh_theme()

func _show_oobe_wizard_if_needed():
	var first_run_setting = DataManager.get_setting("first_run_completed")
	var is_first_run = true
	if first_run_setting:
		is_first_run = not first_run_setting.value

	if is_first_run:
		print("[Main] First run detected, showing OOBE wizard")
		var wizard = OobeWizard.new()
		wizard.wizard_completed.connect(_on_oobe_wizard_completed)
		wizard.start_wizard()

func _on_oobe_wizard_completed():
	print("[Main] OOBE wizard completed")
	# Rebuild settings dialog with updated path/RomM values so it's fresh
	UIManager.pre_create_settings_dialog(true)
	# Refresh any views that might need updated settings
	UIManager.rebuild_game_grid()
	# Restore focus to the home button
	call_deferred("reset_focus_to_home_button")

func _pre_create_settings_dialog() -> void:
	"""Build the settings dialog eagerly while the home screen is visible so the
	platform cards screen can appear instantly when opened. Waits for a gap in
	user input (5s cap) so the build can't land mid-interaction; the category
	builds themselves spread over frames inside the dialog."""
	if DEBUG_LOG: print("[Main] _pre_create_settings_dialog entered at ms=", Time.get_ticks_msec())
	for i in range(3):
		await get_tree().process_frame
	# Hold off until the home grid has settled (capped) so the dialog's
	# category build can't share a frame with boot-critical settle/paint work.
	var settle_wait_ms := Time.get_ticks_msec()
	while not WarmupBudget.home_grid_settled and Time.get_ticks_msec() - settle_wait_ms < 8000:
		await get_tree().process_frame
	var waited_ms := Time.get_ticks_msec()
	while WarmupBudget.input_idle_ms() < 500 and Time.get_ticks_msec() - waited_ms < 5000:
		await get_tree().process_frame
	if DEBUG_LOG: print("[Main] _pre_create_settings_dialog building at ms=", Time.get_ticks_msec(), " idle_ms=", WarmupBudget.input_idle_ms())
	if UIManager:
		var start_us := Time.get_ticks_usec()
		await UIManager.pre_create_settings_dialog()
		if DEBUG_LOG: print("[Main] pre_create_settings_dialog (initial burst) elapsed_us=", Time.get_ticks_usec() - start_us)

func _on_tab_changed(view_name: String):
	# Sync slider to the current view's grid; do not re-apply saved zoom here,
	# because that overrides the live zoom whenever tabs are switched (e.g. when
	# adding/removing a collection pin).
	UIManager.toolbar.sync_zoom_slider_to_view(view_name)

func _on_viewport_resized(_new_size: Vector2) -> void:
	"""Re-sync zoom slider after viewport resize. The grid re-snaps its zoom
	in _on_resize_debounced(), but the slider stops and position are owned
	by the toolbar sub-manager and must be updated to match."""
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	var current_view = UIManager.get_current_view()
	if not current_view:
		return
	var view_name = current_view.view_name
	if not UIManager._is_grid_view_name(view_name):
		return

	var games_grid = UIManager.get_view_grid(current_view)
	if not games_grid:
		return

	# Wait one frame for the grid to finish its resize recalculation
	await get_tree().process_frame

	UIManager.toolbar.sync_zoom_slider_to_view(view_name)

func _on_preset_applied() -> void:
	"""Sync UI controls after a theme preset is applied."""
	UIManager.toolbar.sync_view_mode_button_to_setting()
	# Re-apply zoom to all views (deferred so grids have valid dimensions)
	UIManager.toolbar.call_deferred("load_and_apply_saved_zoom")


# Server-deletion confirmation: a full sync can hold one above-threshold
# batch per platform; dialogs are shown one at a time, queued per signal.
var _server_deletion_queue: Array = []
var _server_deletion_dialog_open: bool = false

func _on_server_deletions_detected(platform_slug: String, count: int) -> void:
	_server_deletion_queue.append({"slug": platform_slug, "count": count})
	_show_next_server_deletion_dialog()

func _show_next_server_deletion_dialog() -> void:
	if _server_deletion_dialog_open or _server_deletion_queue.is_empty():
		return
	_server_deletion_dialog_open = true
	var entry: Dictionary = _server_deletion_queue.pop_front()
	var slug: String = entry.slug
	var count: int = entry.count

	var dialog := M3Dialog.new()
	dialog.title_text = "Games removed from server"
	dialog.body_text = "The server no longer lists %d games for %s. Remove them from this device?\n\nROM and save files on disk are not affected." % [count, slug]
	dialog.add_action("Keep", func():
		DataManager.decline_server_deletions(slug)
		dialog.dismiss()
	, false)
	dialog.add_action("Remove", func():
		DataManager.confirm_server_deletions(slug)
		dialog.dismiss()
	, true)
	# Any dismissal path (buttons above, scrim, X, back) frees the queue;
	# scrim/X/back counts as Keep (safe default, and a no-op after Remove).
	dialog.dismissed.connect(func():
		DataManager.decline_server_deletions(slug)
		_server_deletion_dialog_open = false
		_show_next_server_deletion_dialog())
	M3Dialog.show_dialog(dialog)

func _focus_first_home_card_on_startup(attempts: int = 0) -> void:
	"""Focus the first game card in the Home grid once it has data."""
	if attempts == 0:
		if DEBUG_LOG: print("[Main] Startup focus: entered at ms=", Time.get_ticks_msec())
	if attempts > 60:
		if DEBUG_LOG: print("[Main] Startup focus: grid did not populate, falling back to Home button")
		reset_focus_to_home_button()
		return

	if not UIManager or not UIManager.is_current_view("Home"):
		if DEBUG_LOG: print("[Main] Startup focus: Home is not current view, aborting")
		return

	var home_view = UIManager.get_view("Home") as HomeView
	if not home_view or not home_view.games_grid:
		if DEBUG_LOG: print("[Main] Startup focus: Home grid not ready, retrying...")
		await get_tree().process_frame
		_focus_first_home_card_on_startup(attempts + 1)
		return

	var grid = home_view.games_grid
	var range_info = grid.get_visible_range()
	if range_info.total <= 0:
		if DEBUG_LOG: print("[Main] Startup focus: waiting for Home grid data (total=", range_info.total, ")")
		await get_tree().process_frame
		_focus_first_home_card_on_startup(attempts + 1)
		return

	if DEBUG_LOG: print("[Main] Startup focus: focusing first Home card")
	WarmupBudget.tag("startup_focus")
	grid.scroll_to_index_and_focus(0, false)

func _prewarm_shader_pipelines() -> void:
	# Fallback kick: SystemManager starts the prewarm during the autoload
	# window so pipelines are warm before the first visible frame. If that
	# somehow didn't run, start it once the home grid settles. Prewarm is
	# idempotent, so this is a no-op in the normal case.
	if DEBUG_LOG: print("[Main] _prewarm_shader_pipelines entered at ms=", Time.get_ticks_msec())
	await get_tree().create_timer(1.0).timeout
	if not is_inside_tree():
		return
	var waited_ms := Time.get_ticks_msec()
	while not WarmupBudget.home_grid_settled and Time.get_ticks_msec() - waited_ms < 10000:
		await get_tree().process_frame
	if not is_inside_tree():
		return
	ShaderPrewarmer.prewarm(get_tree())

func _settle_grid_when_data_ready(grid: VirtualScrollGridContainer, view: View, available_size: Vector2, settle_start_us: int) -> void:
	"""Defer the pool build + startup settle until the grid's total count is
	known (it arrives asynchronously when the DB cache is cold at startup)."""
	if not is_instance_valid(grid):
		return
	var source_total: int = grid.get_visible_range().get("source_total", 0)
	if source_total <= 0 and not _view_count_resolved_empty(view):
		# Cold cache: wait on the count application itself (same-frame wakeup)
		# instead of polling the view's load flags once per frame. The timeout
		# covers the queue-overflow drop path, where no count ever lands.
		var wait := {"fired": false}
		grid.total_count_applied.connect(func(_c: int) -> void: wait.fired = true, CONNECT_ONE_SHOT)
		get_tree().create_timer(SETTLE_COUNT_WAIT_TIMEOUT_SEC).timeout.connect(func() -> void: wait.fired = true, CONNECT_ONE_SHOT)
		var wait_start_ms := Time.get_ticks_msec()
		while not wait.fired:
			await get_tree().process_frame
			if not is_instance_valid(grid):
				return
		if DEBUG_LOG: print("[Main] settle waited ", Time.get_ticks_msec() - wait_start_ms, "ms for grid count (source_total=", grid.get_visible_range().get("source_total", 0), ")")
	WarmupBudget.tag("grid_settle")
	var sub_start_us := Time.get_ticks_usec()
	grid._instantiate_card_pool()
	if DEBUG_LOG: print("[Main] settle: _instantiate_card_pool elapsed_us=", Time.get_ticks_usec() - sub_start_us)
	sub_start_us = Time.get_ticks_usec()
	grid.settle_startup_with_buffer(0)
	if DEBUG_LOG: print("[Main] settle: settle_startup_with_buffer elapsed_us=", Time.get_ticks_usec() - sub_start_us)
	if DEBUG_LOG: print("[Main] Settled grid for ", view.view_name, " target_ratio=", grid.target_card_width_ratio, " available=", available_size, " elapsed_us=", Time.get_ticks_usec() - settle_start_us)
	# Open the warmup gates (platform card pool waits on this) and start the
	# countdown out of startup budgeting back to steady-state.
	WarmupBudget.notify_home_grid_settled()
	# The startup perf window ends here: restore the configured frame pacing
	# (low-processor mode was disabled in _enter_tree for boot throughput).
	if SystemManager.display:
		SystemManager.display.reapply_power_mode()
	await get_tree().create_timer(2.0).timeout
	WarmupBudget.set_startup_mode(false)

## Cap on the startup wait for the grid's first total-count application; the
## queue-overflow drop path resolves without any set_total_count call.
const SETTLE_COUNT_WAIT_TIMEOUT_SEC := 2.0

func _view_count_resolved_empty(view: View) -> bool:
	"""True when the view's count load has already resolved with 0 items, so
	the startup settle can proceed with an empty grid instead of waiting for a
	count application that already happened."""
	var pending = view.get("_total_count_load_pending")
	var loading = view.get("_is_loading")
	return pending is bool and not pending and loading is bool and not loading

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home destination in the M3 nav."""
	var home_button = UIManager.find_home_button()
	if DEBUG_LOG: print("[Main] find_home_button returned: ", home_button)
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		if DEBUG_LOG: print("[Main] Grabbing focus on: ", home_button.name)
		home_button.grab_focus()
	else:
		if DEBUG_LOG: print("[Main] Could not grab focus — home_button invalid or focus disabled")

func _is_home_button_focused() -> bool:
	var home_button = UIManager.find_home_button()
	if not home_button or not home_button is Control:
		return false
	return home_button == UIManager.get_current_focus_owner()

func _handle_ui_cancel() -> void:
	"""Handle ui_cancel: return to Home unless blocked by overlay."""
	# Block during background state (emulator running)
	if LaunchManager and LaunchManager.is_in_background_state():
		return

	# Block if OOBE wizard is visible
	if _ui_layer:
		for child in _ui_layer.get_children():
			if child.has_method("start_wizard") and child.visible:
				return

	# Check if keyboard is visible - let keyboard handle it
	if DEBUG_LOG: print("[Main] _handle_ui_cancel: _keyboard=", _keyboard, " visible=", str(_keyboard.visible) if _keyboard else "N/A", " in_second_viewport=", str(UIManager._keyboard_is_in_second_viewport) if UIManager else "N/A")
	if _keyboard and _keyboard.visible:
		# If keyboard is in SecondViewport, it won't receive ui_cancel (controller input goes to MainViewport)
		# So we need to manually dismiss it here
		if UIManager and UIManager._keyboard_is_in_second_viewport:
			if DEBUG_LOG: print("[Main] Manually dismissing keyboard in SecondViewport")
			if _keyboard.has_method("_hide_keyboard"):
				_keyboard._hide_keyboard()
				# Return focus to the active LineEdit in MainViewport
				if _keyboard._active_line_edit != null:
					_keyboard._active_line_edit.grab_focus()
			get_viewport().set_input_as_handled()
			return
		else:
			return

	# Check if settings dialog is open - let it handle dismissal
	if UIManager and UIManager.is_settings_dialog_open():
		return

	# Second cancel while on Home tab and Home button is focused opens Settings.
	if UIManager and UIManager.is_current_view("Home") and _is_home_button_focused():
		UIManager.show_settings_dialog()
		get_viewport().set_input_as_handled()
		return

	# If a bottom sheet overlay is open, let M3Overlay handle dismissal
	if M3Overlay.is_showing("bottom_sheet"):
		return

	# If a side sheet (library filters, etc.) is open, let it dismiss itself
	if M3Overlay.is_showing("side_sheet"):
		return

	# If in Library view with an active search, clear the search first
	var current_view = UIManager.get_current_view()
	if current_view and current_view.view_name == "Library" and current_view.has_method("try_clear_search"):
		if current_view.try_clear_search():
			return

	# Then clear active library filters (e.g. a studio filter from the
	# details sheet) before falling through to grid escape / Home.
	if current_view and current_view.view_name == "Library" and current_view.has_method("try_clear_filters"):
		if current_view.try_clear_filters():
			return

	# If focus is locked in a grid, escape to the nav bar instead of switching to Home
	if current_view and current_view.games_grid:
		var grid = current_view.games_grid
		if grid.is_focus_locked_and_active():
			# Release scene-wide focus lock before moving focus to the nav bar.
			if UIManager:
				UIManager.exit_focus_lock(grid)
			var nav_dest = UIManager.get_active_nav_destination()
			if nav_dest and nav_dest is Control and nav_dest.focus_mode != Control.FOCUS_NONE:
				if SystemManager.audio:
					SystemManager.audio.play_sfx("return")
				nav_dest.grab_focus()
				if DEBUG_LOG: print("[Main] _handle_ui_cancel: escaped locked grid to nav destination: ", nav_dest.name)
			else:
				var home_button = UIManager.find_home_button()
				if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
					if SystemManager.audio:
						SystemManager.audio.play_sfx("return")
					home_button.grab_focus()
					if DEBUG_LOG: print("[Main] _handle_ui_cancel: escaped locked grid to home button")
			return

	# Play return sound
	if SystemManager.audio:
		SystemManager.audio.play_sfx("return")
	# Switch to Home view
	push_warning("[Main] ui_cancel: switching to Home")
	UIManager.switch_to_tab("Home")
	# Set focus to Home button (deferred so tab layout settles)
	call_deferred("reset_focus_to_home_button")

func _input(event: InputEvent):
	if event is InputEventKey or event is InputEventJoypadButton \
			or event is InputEventMouseButton or event is InputEventMouseMotion \
			or event is InputEventScreenTouch or event is InputEventScreenDrag:
		WarmupBudget.note_input()
	# Block all input during background state (emulator running), and also
	# while a previously-tracked emulator process group is still alive after
	# its session ended — a detection miss must degrade to "input briefly
	# stuck", never "double-inputting the game and the launcher".
	if LaunchManager and (LaunchManager.is_in_background_state() \
			or (LaunchManager.process and LaunchManager.process.has_lingering_process())):
		get_viewport().set_input_as_handled()
		return

	# Block input if OOBE wizard is visible
	if _ui_layer:
		for child in _ui_layer.get_children():
			if child.has_method("start_wizard") and child.visible:
				return

	# If the on-screen keyboard is on the second (dual) screen, controller input
	# does not reach that viewport automatically. Forward relevant actions so
	# the keyboard can be navigated and dismissed.
	if _keyboard and _keyboard.visible and UIManager and UIManager._keyboard_is_in_second_viewport:
		if _forward_input_to_second_viewport(event):
			return

	# Delegate directional input to NavigationManager for unified delay/repeat handling.
	# Skip when the on-screen keyboard is visible so keyboard keys can be navigated.
	if not (_keyboard and _keyboard.visible):
		if UIManager and UIManager.handle_directional_input(event):
			get_viewport().set_input_as_handled()
			return

	# Handle zoom in/out with right stick left/right - only on press, not hold
	if event.is_action_pressed("zoom_in"):
		if not _zoom_in_pressed:
			if SystemManager.audio:
				SystemManager.audio.play_sfx("click_04")
			_zoom_in_pressed = true
			UIManager.toolbar.adjust_zoom(1.0)
		return

	if event.is_action_pressed("zoom_out"):
		if not _zoom_out_pressed:
			if SystemManager.audio:
				SystemManager.audio.play_sfx("click_04")
			_zoom_out_pressed = true
			UIManager.toolbar.adjust_zoom(-1.0)
		return

	if event.is_action_released("zoom_in") and _zoom_in_pressed:
		_zoom_in_pressed = false
		return

	if event.is_action_released("zoom_out") and _zoom_out_pressed:
		_zoom_out_pressed = false
		return

	# Handle ui_cancel: return to Home unless blocked by overlay.
	if event.is_action_pressed("ui_cancel"):
		_handle_ui_cancel()

func _forward_input_to_second_viewport(event: InputEvent) -> bool:
	"""Forward controller actions to the second viewport while the keyboard is displayed there."""
	if not UIManager or not UIManager.dual_screen:
		return false
	var second_vp = UIManager.dual_screen.get_second_viewport()
	if not second_vp:
		return false
	var actions := ["ui_left", "ui_right", "ui_up", "ui_down", "ui_accept", "ui_cancel", "ui_start"]
	for action in actions:
		if event.is_action_pressed(action):
			second_vp.push_input(event)
			get_viewport().set_input_as_handled()
			return true
	return false

func _on_window_focus_out() -> void:
	# NB: OS.has_feature, not SystemManager.platform — focus-out can arrive
	# during shutdown, when the autoload is already freed (nil base access).
	if OS.has_feature("android"):
		_on_android_window_focus_out()
	else:
		_suspend_rendering_if_hidden()

func _on_android_window_focus_out() -> void:
	"""Android focus loss splits two ways: another app taking focus (game
	launch, notification shade) keeps rendering — dual-screen hero art must
	stay live — while the display turning off means nothing is visible, so
	rendering is suspended and the engine drops to low-power CPU pacing."""
	var display_off := false
	if Engine.has_singleton("KyodaiBridge"):
		# NB: call directly — has_method() is unreliable on the Java plugin bridge.
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin:
			display_off = not bool(plugin.isDisplayInteractive())
	if not display_off:
		return
	_suspend_rendering()
	OS.low_processor_usage_mode = true
	print("[Main] Display off: rendering suspended, low-processor mode on")

func _restore_power_mode_after_focus_in() -> void:
	if not OS.has_feature("android"):
		return
	# Focus-in can arrive during shutdown; the managers may already be gone.
	if not is_instance_valid(SystemManager):
		return
	# An active download owns low-processor mode (heat management); otherwise
	# restore the configured VRR/warmup pacing.
	if SystemManager.download and not SystemManager.download.get_active().is_empty():
		OS.low_processor_usage_mode = true
	elif SystemManager.display:
		SystemManager.display.reapply_power_mode()

func _suspend_rendering_if_hidden() -> void:
	"""Only suspend when the window is actually minimized/hidden — plain
	alt-tab keeps rendering so the app stays live when visible again."""
	var window := get_window()
	if window and (window.mode == Window.MODE_MINIMIZED or not window.visible):
		_suspend_rendering()

func _suspend_rendering() -> void:
	"""Stop issuing frames while the window is invisible (desktop: minimized/
	hidden; Android: display off). The SceneTree keeps processing (downloads,
	poll timers, sync all keep running); only the renderer and the perpetual
	focus-ring idle animation are halted."""
	if _rendering_suspended:
		return
	_rendering_suspended = true
	_prev_viewport_update_mode = RenderingServer.viewport_get_update_mode(get_tree().root.get_viewport_rid())
	RenderingServer.viewport_set_update_mode(get_tree().root.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_DISABLED)
	if UIManager and UIManager.focus:
		UIManager.focus.suspend_idle_animation()
	print("[Main] Rendering suspended (window unfocused)")

func _resume_rendering() -> void:
	if not _rendering_suspended:
		return
	_rendering_suspended = false
	if _prev_viewport_update_mode >= 0:
		RenderingServer.viewport_set_update_mode(get_tree().root.get_viewport_rid(), _prev_viewport_update_mode)
		_prev_viewport_update_mode = -1
	if UIManager and UIManager.focus:
		UIManager.focus.resume_idle_animation()
	print("[Main] Rendering resumed (window focused)")

func _notification(what: int) -> void:
	"""Handle application lifecycle notifications."""
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		# Defer one frame so the window manager state (minimize/hide) has settled
		call_deferred("_on_window_focus_out")
		return

	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_resume_rendering()
		_restore_power_mode_after_focus_in()
		return

	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		var close_start_us := Time.get_ticks_usec()
		print("[Main] NOTIFICATION_WM_CLOSE_REQUEST: shutdown started")

		# Hide/minimize the window immediately on desktop so the app feels closed,
		# even if cleanup continues for a few more frames. Skip on Android because mobile
		# has no minimize-to-taskbar concept, and skip in headless mode.
		if not OS.has_feature("headless") and SystemManager.platform and not SystemManager.platform.is_android():
			get_window().mode = Window.MODE_MINIMIZED
		print("[Main] Window hidden/minimized, running cleanup...")

		# Remember the current windowed size before shutdown.
		var window_save_start_us := Time.get_ticks_usec()
		if SystemManager.display:
			SystemManager.display.save_last_window_size()
		if DEBUG_LOG: print("[Main] save_last_window_size elapsed_us=", Time.get_ticks_usec() - window_save_start_us)

		# Flush any pending settings changes before shutdown
		var settings_save_start_us := Time.get_ticks_usec()
		if DataManager:
			DataManager.save_settings()
		if DEBUG_LOG: print("[Main] save_settings elapsed_us=", Time.get_ticks_usec() - settings_save_start_us)

		# Pre-clean heavy resources and background work before freeing the tree.
		# This reduces the number of synchronous RenderingServer.free_rid() calls
		# and thread-join waits during root teardown.
		_pre_shutdown_cleanup()

		# The OS asked us to close. Free the entire scene tree now so all node
		# RIDs are released before the rendering server finalizes, then quit.
		# auto_accept_quit is disabled in _ready(), so the default quit() is
		# suppressed and we take over the shutdown sequence.
		var tree = get_tree()
		if tree:
			tree.root.queue_free()
			call_deferred("_deferred_quit")

		if DEBUG_LOG: print("[Main] NOTIFICATION_WM_CLOSE_REQUEST total elapsed_us=", Time.get_ticks_usec() - close_start_us)
		return

	if what == NOTIFICATION_APPLICATION_RESUMED:
		print("[Main] NOTIFICATION_APPLICATION_RESUMED received, _last_focused_index = ", _last_focused_index)

		# Reconciliation is asynchronous. Android must never hold the resumed
		# activity on a privileged probe before presenting Kyodai.
		if LaunchManager and LaunchManager.is_in_background_state():
			_reconcile_android_resume()

		# RESUMED belongs to Kyodai's activity, so rendering is always safe to
		# restore even while session reconciliation continues in the background.
		_resume_rendering()
		var root_rid := get_tree().root.get_viewport_rid()
		if RenderingServer.viewport_get_update_mode(root_rid) == RenderingServer.VIEWPORT_UPDATE_DISABLED:
			push_warning("[Main] Viewport was left disabled on resume; force re-enabling")
			RenderingServer.viewport_set_update_mode(root_rid, RenderingServer.VIEWPORT_UPDATE_ALWAYS)

		# The heavy refresh work below is idempotent, so skip burst duplicates
		# (RESUMED arrives in pairs on Android, and activity churn can produce
		# storms). The safety restores above run on every notification.
		var resume_now_ms := Time.get_ticks_msec()
		if _last_resume_heavy_ms >= 0 and resume_now_ms - _last_resume_heavy_ms < RESUME_HEAVY_DEBOUNCE_MS:
			return
		_last_resume_heavy_ms = resume_now_ms

		# Restore focus when app returns to foreground (Android)
		if _last_focused_index >= 0:
			if DEBUG_LOG: print("[Main] Calling _restore_focus_to_card deferred")
			UIManager.toolbar.call_deferred("_restore_focus_to_card", _last_focused_index)
		else:
			if DEBUG_LOG: print("[Main] No saved focus index, skipping restoration")

		# Reconcile stale pending launches (handles APK installs that completed
		# while backgrounded). The validation cache is intentionally NOT cleared
		# here: pending emulators get targeted invalidation inside
		# clear_stale_pending_launches, and everything else self-heals via TTL,
		# so the next launch after resume no longer re-scans every install step.
		if LaunchManager:
			LaunchManager.clear_stale_pending_launches()
			# Re-scan the .steam export folder: games installed/uninstalled in
			# Steam frontends (GameNative/DroidDeck) while backgrounded
			# appear/disappear here.
			LaunchManager.steam_rescan()
			if LaunchManager.update:
				LaunchManager.update.on_app_resumed()
		var platforms_view = UIManager.get_settings_dialog_platforms_view()
		if platforms_view and platforms_view.has_method("refresh_cards"):
			# Refreshing hidden cards is wasted work on the resume frame -
			# on_view_show re-renders from data the next time the dialog opens.
			if platforms_view.is_visible_in_tree():
				platforms_view.refresh_cards()
				print("[Main] Refreshed platform cards after resume")
				# Restore focus to the platform card the user was last interacting with
				if platforms_view.has_method("restore_focus_to_last_active"):
					call_deferred("_restore_platform_focus")

		# Dismiss any stale notifications (e.g., extraction notifications that completed while backgrounded)
		if SystemManager.notifications:
			SystemManager.notifications.dismiss_all_notifications()
			print("[Main] Dismissed all notifications after resume")

func _pre_shutdown_cleanup() -> void:
	"""Release heavy resources and stop background work before the tree is freed.

	Doing this before tree.root.queue_free() reduces the synchronous work done
	during node teardown, which is the main source of slow app shutdown.
	"""
	var cleanup_start_us := Time.get_ticks_usec()
	print("[Main] Pre-shutdown cleanup starting")

	# Cancel the shader prewarm first: it's a static coroutine awaiting frames,
	# so without an explicit cancel it can resume mid-teardown and touch the
	# freed prewarm viewport / finalizing RenderingServer.
	ShaderPrewarmer.cancel()

	# Stop any pending debounced settings save.
	if UIManager and UIManager.toolbar:
		UIManager.toolbar.cancel_pending_zoom_save()

	# Cancel active downloads and clear the download queue.
	# This stops HTTPRequest nodes and chunked-download timers.
	var download_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.download:
		SystemManager.download.shutdown()
	if DEBUG_LOG: print("[Main] download shutdown elapsed_us=", Time.get_ticks_usec() - download_start_us)

	# Cancel active HTTP requests and free the request pool.
	var network_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.network:
		SystemManager.network.shutdown()
	if DEBUG_LOG: print("[Main] network shutdown elapsed_us=", Time.get_ticks_usec() - network_start_us)

	# Release card pools, overlays, pending image work, and static caches.
	# Shared with the launch-hibernation trim so pooled cards (and their
	# RenderingServer items) are freed before the root is queue_freed.
	_release_heavy_resources("shutdown")

	# Stop all background worker threads (DB, image, download, extraction, OS execute).
	# After this point SystemManager.memory static methods will safely no-op.
	var memory_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.memory:
		MemorySubManager.shutdown()
	if DEBUG_LOG: print("[Main] memory shutdown elapsed_us=", Time.get_ticks_usec() - memory_start_us)

	if DEBUG_LOG: print("[Main] Pre-shutdown cleanup elapsed_us=", Time.get_ticks_usec() - cleanup_start_us)

func _deferred_quit() -> void:
	var tree = get_tree()
	if tree:
		tree.quit()

# ==================== LAUNCH HIBERNATION ====================

func _pre_launch_trim(_game: GameResource) -> void:
	"""Release reclaimable memory before the game process starts (and before
	Android suspends us), then yield frames so deferred frees fully complete."""
	_log_rss("pre-launch trim start")
	_trim_memory("launch")
	# queue_free()'d nodes and RenderingServer RIDs release on frame boundaries;
	# yield so the trim is fully materialized before the process/intent starts.
	await get_tree().process_frame
	await get_tree().process_frame
	_log_rss("pre-launch trim done")

# Monotonic token bumped by every trim so an in-flight restore coroutine
# aborts at its next await when a new launch re-trims mid-restore.
var _restore_generation: int = 0

## Android ComponentCallbacks2.onTrimMemory escalation, forwarded by the
## plugin. Only acts during a game session: ordinary backgrounding is left
## untrimmed so returning to the launcher stays instant, and LMK kills stay
## visible during testing instead of being masked.
## Levels: 20=UI_HIDDEN 40=BACKGROUND 60=MODERATE 80=COMPLETE (next to die).
func _on_android_trim_memory(level: int) -> void:
	_log_rss("onTrimMemory level=%d" % level)
	if not (LaunchManager and LaunchManager.is_in_background_state()):
		return
	if level >= 80:
		_deep_trim_for_critical()
	elif level >= 40:
		# Standard trim; usually a no-op since the pre-launch trim already ran.
		_trim_memory("trim_memory_%d" % level)

## Last-resort trim when Android warns we are next in line for the kill:
## everything the standard trim does PLUS the visible window's decoded
## covers (normally kept for an instant resume frame). Cards swap to the
## shared placeholder and re-bind from the warmed disk cache on resume.
func _deep_trim_for_critical() -> void:
	_trim_memory("critical")
	if UIManager and UIManager.view:
		for grid in UIManager.view.get_all_grids():
			grid.release_active_media()
	_log_rss("deep trim done")

func _trim_memory(reason: String) -> void:
	"""Idempotent entry point for launch hibernation."""
	# Abort any in-flight restore from a previous launch, even when this trim
	# turns out to be a no-op (already trimmed).
	_restore_generation += 1
	if _trimmed_for_launch:
		return
	_trimmed_for_launch = true
	_release_heavy_resources(reason)
	# Game session starting: restore the configured frame pacing for the
	# background stretch (the post-launch restore disables low-processor
	# mode again during its brief rebuild window).
	if SystemManager and SystemManager.display:
		SystemManager.display.reapply_power_mode()

func _release_heavy_resources(reason: String) -> void:
	"""Free every reclaimable memory hold that existing lazy paths can rebuild.
	Downloads, worker threads, and in-flight network requests are untouched."""
	var trim_start_us := Time.get_ticks_usec()
	if DEBUG_LOG: print("[Main] Memory trim (", reason, ") starting")

	# Stop periodic work that wakes the main thread while backgrounded.
	if UIManager:
		UIManager.set_status_bar_polling(false)
	if SystemManager and SystemManager.notifications:
		SystemManager.notifications.dismiss_all_notifications()

	# Pools release their texture refs before the cache wipe below.
	var pool_start_us := Time.get_ticks_usec()
	if UIManager and UIManager.view:
		for grid in UIManager.view.get_all_grids():
			grid.clear_pool()
	PlatformCardPool.clear()
	if DEBUG_LOG: print("[Main] trim grid pools elapsed_us=", Time.get_ticks_usec() - pool_start_us)

	# Overlays rebuild lazily through their existing show paths.
	if UIManager and UIManager.overlay:
		UIManager.overlay.release_settings_dialog()
		UIManager.overlay.clear_game_details_sheet_content()
	LibraryFilterSheet.cleanup_instance()

	# Drop queued cover/prefetch work; in-flight tasks and downloads continue.
	# At shutdown the tree is dying, so drained waiters must not be called back.
	MemorySubManager.clear_pending_image_tasks(reason != "shutdown")

	# Static caches; covers re-decode from the disk cache on demand.
	var cache_start_us := Time.get_ticks_usec()
	MemorySubManager.clear_texture_cache()
	GameCard.clear_session_texture_cache()
	GameCard.clear_platform_icon_cache()
	EffectBase.clear_shared_caches()
	EffectStack.clear_script_cache()
	M3Theme.clear_theme_cache()
	LaunchTransitionOverlay._clear_source_override()
	M3NavigationDestination.clear_shared_stylebox()
	M3MenuRenderer.clear_shared_stylebox()
	if DEBUG_LOG: print("[Main] trim static caches elapsed_us=", Time.get_ticks_usec() - cache_start_us)

	if SystemManager and SystemManager.network:
		SystemManager.network.clear_response_cache()

	if DEBUG_LOG: print("[Main] Memory trim (", reason, ") total elapsed_us=", Time.get_ticks_usec() - trim_start_us)

func _restore_after_launch() -> void:
	"""Undo launch hibernation. The visible card window survives the trim with
	its textures, so the resume frame is already correct; what the trim removed
	is everything AROUND it. Restore that eagerly (below) instead of letting it
	rebuild lazily inside the scroll/dialog hot paths."""
	if not _trimmed_for_launch:
		return
	_trimmed_for_launch = false
	if UIManager:
		UIManager.set_status_bar_polling(true)
	_log_rss("post-resume")
	_eager_restore_after_trim()

func _eager_restore_after_trim() -> void:
	"""Rebuild what _release_heavy_resources() tore down, budget-gated like
	startup: current view's grid first (pool reseed + cover prefetch around
	the window), then the other instantiated grids, then the settings dialog
	once interaction settles."""
	_restore_generation += 1
	var generation := _restore_generation
	var restore_start_us := Time.get_ticks_usec()

	# Treat the restore like startup so pool growth, buffer expansion, and
	# texture-upload drains share the per-frame budget instead of stacking
	# into blown frames right as the user starts interacting again. Also run
	# at full frame throughput for the duration (see _enter_tree).
	WarmupBudget.set_startup_mode(true)
	OS.low_processor_usage_mode = false

	# Current view first: it is what the user is looking at and scrolls first.
	var current_view: View = UIManager.get_current_view() if UIManager else null
	var current_grid: VirtualScrollGridContainer = UIManager.get_view_grid(current_view) if current_view else null
	if current_grid and is_instance_valid(current_grid):
		current_grid.restore_after_trim()
	if DEBUG_LOG: print("[Main] restore: current grid elapsed_us=", Time.get_ticks_usec() - restore_start_us)

	# Then the other instantiated grids (hidden views seed their minimum).
	if UIManager and UIManager.view:
		for grid in UIManager.view.get_all_grids():
			if generation != _restore_generation:
				return
			if grid == current_grid or not is_instance_valid(grid):
				continue
			grid.restore_after_trim()
			await get_tree().process_frame

	# Rebuild the settings dialog once interaction settles (same idle-gated
	# path as startup; the trim released it).
	if generation != _restore_generation:
		return
	call_deferred("_pre_create_settings_dialog")

	# Count down out of startup budgeting back to steady state, mirroring the
	# post-settle countdown in _settle_grid_when_data_ready.
	await get_tree().create_timer(2.0).timeout
	if generation != _restore_generation:
		return
	WarmupBudget.set_startup_mode(false)
	if SystemManager and SystemManager.display:
		SystemManager.display.reapply_power_mode()
	if DEBUG_LOG: print("[Main] eager restore done, total elapsed_us=", Time.get_ticks_usec() - restore_start_us)

func _log_rss(label: String) -> void:
	# Always on: trim-effectiveness forensics in logcat (LMK investigations).
	# One /proc read per call, a handful of calls per session.
	var rss_kb := _get_process_rss_kb()
	if rss_kb >= 0:
		print("[Main] VmRSS (", label, "): ", snappedf(rss_kb / 1024.0, 0.1), " MB")
	else:
		print("[Main] Resource count (", label, "): ", Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))

func _get_process_rss_kb() -> int:
	"""VmRSS from /proc/self/status (Linux/Android); -1 where unavailable.
	procfs entries fail stat-style existence checks, so open directly - and
	bypass FSM, whose path validation rejects absolute /proc paths."""
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if not f:
		return -1
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			var parts := line.split(" ", false)
			f.close()
			if parts.size() >= 2:
				return parts[1].to_int()
			return -1
	f.close()
	return -1

func _on_game_launch_initiated(_game: GameResource, focus_index: int) -> void:
	"""Save the focused card index when a game launch is initiated."""
	print("[Main] _on_game_launch_initiated() called with focus_index: ", focus_index)

	# Store the focused card index (passed from card before focus is lost)
	_last_focused_index = focus_index
	print("[Main] Saved _last_focused_index: ", _last_focused_index)

	# Note: Pre-launch save sync is now handled inside LaunchManager.launch_game()

func _reconcile_android_resume() -> void:
	if _android_resume_reconciling or not LaunchManager or not LaunchManager.is_in_background_state():
		return
	_android_resume_reconciling = true
	if LaunchManager.process._android_retention_configuring:
		await LaunchManager.process.android_retention_configured
	if not LaunchManager.is_in_background_state():
		_android_resume_reconciling = false
		return
	if LaunchManager.process.has_retained_android_session():
		await LaunchManager.process.retain_active_android_session()
	elif LaunchManager.process._android_retention_uncertain and LaunchManager.process.get_active_android_session():
		# A backend timeout is not task-death evidence. Preserve an
		# unfinalized recovery record instead of silently ending/uploading.
		LaunchManager.process.mark_android_session_lost(LaunchManager.process.get_active_android_session())
		_restore_after_launch()
		SystemManager.notifications.show_notification("Could not verify the retained game. It has been left running for recovery.", SystemManager.notifications.Type.ERROR)
	else:
		print("[Main] In background state on resume, exiting to trigger save upload")
		LaunchManager.force_exit_background_state()
	_android_resume_reconciling = false

func _on_android_task_event(event: String, task_id: int, package_name: String) -> void:
	if event != "task_removed" or not LaunchManager:
		return
	var session := LaunchManager.process.get_active_android_session()
	if session == null or int(session.runtime.get("taskId", -1)) != task_id:
		return
	if not package_name.is_empty() and str(session.runtime.get("package", "")) != package_name:
		return
	LaunchManager.process.reconcile_android_task_removed(session)

func _on_android_home_requested() -> void:
	if not LaunchManager or not SystemManager.platform.is_android():
		return
	# Home is a one-way transition from the emulator to Kyodai. Once Kyodai is
	# foreground, Home only selects the Home view; it never resumes a game or
	# restarts an in-flight snapshot transition.
	if LaunchManager.is_in_background_state() and LaunchManager.process.has_retained_android_session():
		LaunchManager.process.retain_active_android_session()
	else:
		UIManager.switch_to_tab("Home")

func _on_session_activated(session: GameSession, _legacy_pid: int) -> void:
	"""Handle an ordinary game becoming active; shuffler owns its own UI."""
	if session.is_shuffler():
		return
	print("[Main] Session activated - input blocked")
	# Fallback trim for launch paths that bypass pre_launch_hook (e.g. standalone
	# emulator launches); no-op if the pre-launch trim already ran.
	_trim_memory("background")
	_log_rss("session activated")

func _restore_platform_focus() -> void:
	var platforms_view = UIManager.get_settings_dialog_platforms_view()
	if platforms_view and platforms_view.has_method("restore_focus_to_last_active"):
		platforms_view.restore_focus_to_last_active()

func _on_session_resumed(session: GameSession) -> void:
	if session.is_shuffler():
		return
	# Resume uses the same background hibernation policy as a cold activation;
	# the restored grid/status work must not keep running behind the game.
	_trim_memory("background")

func _on_session_retained(session: GameSession) -> void:
	if session.is_shuffler():
		return
	# Keep heavy grid/settings restoration off the snapshot handoff. The
	# visible media window survives the trim, so the return can animate first.
	var texture := LaunchManager._session_snapshot_texture(session)
	var overlays := get_tree().get_nodes_in_group("launch_transition_overlay")
	for overlay in overlays:
		if texture:
			var completion := _on_retained_return_finished.bind(session)
			if not overlay.return_completed.is_connected(completion):
				overlay.return_completed.connect(completion, CONNECT_ONE_SHOT)
			if not overlay.return_failed.is_connected(completion):
				overlay.return_failed.connect(completion, CONNECT_ONE_SHOT)
			overlay.play_return_to_card(texture)
		else:
			# Never strand the launch curtain if snapshot capture failed.
			overlay.abort()
			_on_retained_return_finished(session)
	if overlays.is_empty():
		_on_retained_return_finished(session)
	# Grid restoration can recreate/rebind cards after the first publication.
	# Reapply the retained snapshot once that work has reached the tree, then
	# release the native Home curtain onto the already-updated frame.
	await get_tree().process_frame
	LaunchManager.process.session_changed_for_android()
	LaunchManager.android_tasks.release_observer()
	_release_android_home_curtain(session)

func _on_retained_return_finished(session: GameSession) -> void:
	for overlay in get_tree().get_nodes_in_group("launch_transition_overlay"):
		var completion := _on_retained_return_finished.bind(session)
		if overlay.return_completed.is_connected(completion):
			overlay.return_completed.disconnect(completion)
		if overlay.return_failed.is_connected(completion):
			overlay.return_failed.disconnect(completion)
	if session.state == GameSession.State.RETAINED:
		_restore_after_launch()

func _release_android_home_curtain(session: GameSession) -> void:
	var snapshot_path := str(session.runtime.get("snapshotPath", ""))
	if snapshot_path.is_empty():
		return
	var release := FileAccess.open(snapshot_path.get_base_dir().path_join("release-curtain"), FileAccess.WRITE)
	if release:
		release.store_string("release\n")
		release.close()

func _on_session_finalized(session: GameSession, _exit_code: int) -> void:
	"""Restore ordinary-launch UI after terminal finalization."""
	if session.is_shuffler():
		return
	print("[Main] Session finalized - restoring focus")
	_restore_after_launch()
	# Save upload belongs to SessionSubManager.finalize_once(), not this UI path.

	# Restore focus to the last known position
	if _last_focused_index >= 0:
		UIManager.toolbar.call_deferred("_restore_focus_to_card", _last_focused_index)
	else:
		# Fallback to home button
		call_deferred("reset_focus_to_home_button")

func _exit_tree() -> void:
	"""Release root-level references so the Main node can be fully freed."""
	# Stop timers so they don't hold references after tree teardown.
	if UIManager and UIManager.toolbar:
		UIManager.toolbar.cancel_pending_zoom_save()

	# Drop cached node references; the actual nodes are freed with the tree.
	_keyboard = null
	_ui_layer = null

	# Disconnect signals we own.
	if UIManager.is_connected("tab_changed", _on_tab_changed):
		UIManager.tab_changed.disconnect(_on_tab_changed)
	if DataManager and DataManager.is_connected("apply_preset_end", _on_preset_applied):
		DataManager.apply_preset_end.disconnect(_on_preset_applied)
	if LaunchManager:
		if LaunchManager.is_connected("game_launch_initiated", _on_game_launch_initiated):
			LaunchManager.game_launch_initiated.disconnect(_on_game_launch_initiated)
		if LaunchManager.is_connected("session_activated", _on_session_activated):
			LaunchManager.session_activated.disconnect(_on_session_activated)
		if LaunchManager.is_connected("session_retained", _on_session_retained):
			LaunchManager.session_retained.disconnect(_on_session_retained)
		if LaunchManager.is_connected("session_resumed", _on_session_resumed):
			LaunchManager.session_resumed.disconnect(_on_session_resumed)
		if LaunchManager.is_connected("session_finalized", _on_session_finalized):
			LaunchManager.session_finalized.disconnect(_on_session_finalized)
	if Engine.has_singleton("KyodaiBridge"):
		var bridge = Engine.get_singleton("KyodaiBridge")
		if bridge:
			if bridge.is_connected("android_home_requested", _on_android_home_requested):
				bridge.disconnect("android_home_requested", _on_android_home_requested)
			if bridge.is_connected("android_task_event", _on_android_task_event):
				bridge.disconnect("android_task_event", _on_android_task_event)
	if UIManager and UIManager.dual_screen:
		UIManager.dual_screen.teardown_swap_persistence()
