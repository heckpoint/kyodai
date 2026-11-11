extends Manager

## Manages emulator registry, launch intents, and game execution (facade)

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
const RegistryManager := preload("res://managers/launch_manager/registry_sub_manager.gd")
const EmulatorManager := preload("res://managers/launch_manager/emulator_sub_manager.gd")
const GameManager := preload("res://managers/launch_manager/game_sub_manager.gd")
const FirmwareManager := preload("res://managers/launch_manager/firmware_sub_manager.gd")
const LaunchIntentManager := preload("res://managers/launch_manager/launch_intent_sub_manager.gd")
const ProcessManager := preload("res://managers/launch_manager/process_sub_manager.gd")
const SessionManager := preload("res://managers/launch_manager/session_sub_manager.gd")
const CoreManager := preload("res://managers/launch_manager/core_sub_manager.gd")
const ShufflerManager := preload("res://managers/launch_manager/shuffler_sub_manager.gd")
const SteamManager := preload("res://managers/launch_manager/steam_sub_manager.gd")
const M3UManager := preload("res://managers/launch_manager/m3u_sub_manager.gd")
const UpdateManager := preload("res://managers/launch_manager/update_sub_manager.gd")
const AndroidTaskManager := preload("res://managers/launch_manager/android_task_sub_manager.gd")

# Pending-launch orchestration state
var _pending_launches: Dictionary = {}  # emulator_id -> Array of {game, callback}
var _in_flight_launches: Dictionary = {}  # romm_id -> true

# emulator_id -> true while its Android post-install permissions reminder is open
var _open_install_reminders: Dictionary = {}

# platform_slug -> bool
var _pending_firmware_downloads: Dictionary = {}

# Array[Dictionary] supporting multiple pending launches for the same platform
# Each entry: {game: GameResource, emulator_id: String, callback: Callable}
var _pending_firmware_launches: Array[Dictionary] = []

# Tracks on-demand core downloads and the launches waiting on them.
# key: "platform_slug:core_id", value: true
var _pending_core_downloads: Dictionary = {}

# Each entry: {game: GameResource, platform_slug: String, core_id: String, callback: Callable}
var _pending_core_launches: Array[Dictionary] = []

# Signals
signal game_launched(game: GameResource)
signal game_launch_initiated(game: GameResource, focus_index: int)

## Optional async hook awaited immediately before the game process is created
## (desktop) or the launch intent is fired (Android). main.gd installs this to
## hibernate UI/memory so the trim is fully complete before we launch/suspend.
var pre_launch_hook: Callable

## Called when a launch fails after pre_launch_hook ran, so the app can undo
## the hibernation (no session_finalized fires in that case).
var launch_failed_hook: Callable
@warning_ignore("unused_signal")
signal launch_completed(success: bool, message: String)
@warning_ignore("unused_signal")
signal session_activated(session: GameSession, legacy_pid: int)
@warning_ignore("unused_signal")
signal session_finalized(session: GameSession, exit_code: int)
@warning_ignore("unused_signal")
signal session_retained(session: GameSession)
@warning_ignore("unused_signal")
signal session_resumed(session: GameSession)
@warning_ignore("unused_signal")
signal session_changed(session: GameSession)
@warning_ignore("unused_signal")
signal emulator_registry_loaded(success: bool)
@warning_ignore("unused_signal")
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_completed(emulator_id: String, success: bool)
@warning_ignore("unused_signal")
signal firmware_download_completed(platform_slug: String, success: bool)
signal core_download_completed(platform_slug: String, core_id: String, success: bool)
signal steam_games_updated()

@onready var registry: RegistryManager = $RegistrySubManager
@onready var emulator: EmulatorManager = $EmulatorSubManager
@onready var game_manager: GameManager = $GameSubManager
@onready var firmware: FirmwareManager = $FirmwareSubManager
@onready var intent_manager: LaunchIntentManager = $LaunchIntentSubManager
@onready var process: ProcessManager = $ProcessSubManager
@onready var sessions: SessionManager = $SessionSubManager
@onready var core: CoreManager = $CoreSubManager
@onready var m3u: M3UManager = $M3USubManager
@onready var update: UpdateManager = $UpdateSubManager
@onready var android_tasks: AndroidTaskManager = $AndroidTaskSubManager
var shuffler: ShufflerManager
var steam: SteamManager

# Shuffler uses different default emulators than the standard launcher for these platforms.
const SHUFFLER_DEFAULT_EMULATORS: Dictionary = {
	"ngc": {"emulator_id": "retroarch", "core_id": "dolphin_ngc"},
	"wii": {"emulator_id": "retroarch", "core_id": "dolphin_wii"},
	"psp": {"emulator_id": "retroarch", "core_id": "ppsspp"},
	"ps2": {"emulator_id": "retroarch", "core_id": "pcsx2"},
	"nds": {"emulator_id": "retroarch", "core_id": "melondsds"},
}

func _enter_tree() -> void:
	shuffler = $ShufflerSubManager
	steam = $SteamSubManager

func _ready():
	# The registry owns terminal finalization and canonical lifecycle signals.
	sessions.session_activated.connect(func(session, legacy_pid): session_activated.emit(session, legacy_pid))
	sessions.session_retained.connect(func(session): session_retained.emit(session))
	sessions.session_resumed.connect(func(session): session_resumed.emit(session))
	sessions.session_changed.connect(func(session): session_changed.emit(session))
	sessions.session_finalized.connect(func(session, exit_code): session_finalized.emit(session, exit_code))

	registry._load_registry()
	registry._ensure_emulators_directory()
	
	# Connect to SystemManager.download signals
	SystemManager.download.extraction_completed.connect(emulator._on_download_manager_extraction_completed)
	SystemManager.download.download_completed.connect(emulator._on_unified_download_completed)
	
	# Forward CoreManager signal so UI only needs to listen to LaunchManager.
	core.core_download_completed.connect(_on_core_download_completed)
	
	# Forward SteamManager games list signal.
	steam.games_updated.connect(steam_games_updated.emit)
	
	# Scan existing installations to detect partial installs
	# Wait a frame to ensure everything is initialized
	await get_tree().process_frame

# ============================================================================
# Registry wrappers
# ============================================================================

func get_emulators_directory() -> String:
	return registry.get_emulators_directory()

func get_emulator(emulator_id: String) -> Dictionary:
	return registry.get_emulator(emulator_id)

func get_all_emulators() -> Array[Dictionary]:
	return registry.get_all_emulators()

func get_emulators_for_platform(platform_slug: String) -> Array[Dictionary]:
	return registry.get_emulators_for_platform(platform_slug)

func get_default_emulator_for_platform(platform_slug: String) -> String:
	return registry.get_default_emulator_for_platform(platform_slug)

func get_emulator_install_path(emulator_id: String) -> String:
	return registry.get_emulator_install_path(emulator_id)

## Launches an emulator app directly with no game, for testing emulator configs.
## Android: launches the app by package name (opens the emulator's own UI).
## Desktop: starts the executable with no ROM arguments (emulators open to their menus).
## Returns true if a launch was attempted successfully.
func launch_emulator_standalone(emulator_id: String) -> bool:
	if emulator_id == "":
		return false

	var progress = get_install_progress(emulator_id)
	if progress.get("status", "") != "complete":
		SystemManager.notifications.show_notification(
			"Emulator is not fully installed yet",
			SystemManager.notifications.Type.ERROR,
			null,
			5.0
		)
		return false

	if SystemManager.platform.is_android():
		var emu_cfg = get_emulator(emulator_id)
		var android_cfg: Dictionary = emu_cfg.get("launch", {}).get("platforms", {}).get("android", {})
		var package_name: String = android_cfg.get("package", "")
		if package_name == "":
			push_error("[LaunchManager] No Android package configured for emulator: " + emulator_id)
			return false
		if not Engine.has_singleton("KyodaiBridge"):
			push_error("[LaunchManager] KyodaiBridge plugin not available")
			return false
		var plugin = Engine.get_singleton("KyodaiBridge")
		# Standalone emulator launch (no game): nothing to sync or track, so no
		# background state - same rationale as pinned app shortcuts.
		var success: bool = plugin.call("launchAppByPackageName", package_name)
		return success

	# Desktop: launch the executable directly with no ROM arguments.
	var install_path = get_emulator_install_path(emulator_id)
	if install_path == "":
		push_error("[LaunchManager] Could not resolve install path for emulator: " + emulator_id)
		return false
	var exe_path = FSM.resolve_native_path(install_path)
	var emulator_info = get_emulator(emulator_id)
	var intent = LaunchIntent.new()
	intent.emulator_id = emulator_id
	intent.emulator_name = RegistrySubManager.get_emulator_display_name(emulator_info, emulator_id)
	var args: Array[String] = [exe_path]
	intent.launch_args = args
	# Apply working directory from JSON template if present; otherwise keep
	# the legacy requires_working_dir behavior.
	var launch_cfg = emulator_info.get("launch", {}).get("platforms", {})
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	var platform_launch_cfg = launch_cfg.get(platform_name, {})

	# Apply per-platform environment variables and optional standalone args so
	# the "launch emulator" button shares the game-launch configuration (e.g.
	# RetroArch's managed retroarch.cfg via -c). Without this, a bare launch
	# falls back to the emulator's default config and diverges from in-game.
	var global_emulator_dir = FSM.resolve_path(
		_get_emulator_directory(emulator_id),
		{"format": FSM.PathFormat.ABSOLUTE}
	).rstrip("/")
	var env_config = platform_launch_cfg.get("environment", {})
	for var_name in env_config:
		var formatted_value = str(env_config[var_name])
		formatted_value = formatted_value.replace("{exe}", exe_path)
		formatted_value = formatted_value.replace("{emulator_dir}", global_emulator_dir)
		intent.environment[var_name] = formatted_value
	for arg in platform_launch_cfg.get("standalone_args", []):
		var formatted_arg = str(arg).replace("{exe}", exe_path)
		formatted_arg = formatted_arg.replace("{emulator_dir}", global_emulator_dir)
		intent.launch_args.append(formatted_arg)

	var working_dir_template = platform_launch_cfg.get("working_directory", "")
	if working_dir_template != "":
		var resolved = working_dir_template.replace("{exe}", exe_path)
		# resolve_emulator_path handles {emulator_dir}, {home}, {env.*}, etc.
		resolved = FSM.resolve_emulator_path(resolved, emulator_id, "")
		intent.working_directory = FSM.resolve_native_path(resolved).rstrip("/")
	elif emulator_info.get("requires_working_dir", false) or emulator_id.begins_with("vita3k"):
		intent.working_directory = exe_path.get_base_dir().replace("//", "/")
	var pid = await process._create_desktop_process(intent)
	if pid > 0:
		process.enter_background_state(pid, null, intent)
	return pid > 0

func _get_emulator_directory(emulator_id: String) -> String:
	return registry._get_emulator_directory(emulator_id)

func get_core_for_platform(emulator_id: String, platform_slug: String, core_id: String = "") -> String:
	return registry.get_core_for_platform(emulator_id, platform_slug, core_id)

func resolve_core_for_game(game: GameResource) -> String:
	return intent_manager.resolve_core_for_game(game)

func get_cores_for_platform(emulator_id: String, platform_slug: String) -> Array[Dictionary]:
	return registry.get_cores_for_platform(emulator_id, platform_slug)

func get_default_core_id_for_platform(emulator_id: String, platform_slug: String) -> String:
	return registry.get_default_core_id_for_platform(emulator_id, platform_slug)

## Returns the shuffler-specific default emulator for a platform, falling back to the registry default.
func get_shuffler_default_emulator_for_platform(platform_slug: String) -> String:
	if SHUFFLER_DEFAULT_EMULATORS.has(platform_slug):
		return SHUFFLER_DEFAULT_EMULATORS[platform_slug].emulator_id
	return registry.get_default_emulator_for_platform(platform_slug)

## Returns the shuffler-specific default RetroArch core for a platform, falling back to the registry default.
func get_shuffler_default_core_for_platform(platform_slug: String) -> String:
	if SHUFFLER_DEFAULT_EMULATORS.has(platform_slug):
		return SHUFFLER_DEFAULT_EMULATORS[platform_slug].core_id
	return registry.get_default_core_id_for_platform("retroarch", platform_slug)

func get_core_config(emulator_id: String, platform_slug: String, core_id: String) -> Dictionary:
	return registry.get_core_config(emulator_id, platform_slug, core_id)

func get_app_data_path(emulator_id: String) -> String:
	return registry.get_app_data_path(emulator_id)

func get_retroarch_core_name(platform_slug: String) -> String:
	return registry.get_retroarch_core_name(platform_slug)

func check_for_updates(callback: Callable, progress_callback: Callable = Callable()):
	registry.check_for_updates(callback, progress_callback)

## callback(update_available: bool, error: String)
func check_emulator_for_update(emulator_id: String, callback: Callable):
	registry.check_emulator_for_update(emulator_id, callback)

# ============================================================================
# Emulator install/update wrappers
# ============================================================================

func clear_validation_cache() -> void:
	emulator.clear_validation_cache()

func repair_emulator_config(emulator_id: String) -> bool:
	return emulator.repair_emulator_config(emulator_id)

func clear_stale_pending_launches() -> void:
	emulator.clear_stale_pending_launches()

func get_emulator_install_progress(emulator_id: String) -> String:
	return emulator.get_emulator_install_progress(emulator_id)

func get_install_progress(emulator_id: String) -> Dictionary:
	return emulator.get_install_progress(emulator_id)

func is_emulator_install_progress_extracting(emulator_id: String) -> bool:
	return emulator.is_install_progress_extracting(emulator_id)

func is_emulator_extracting(emulator_id: String) -> bool:
	return emulator.is_emulator_extracting(emulator_id)

func download_emulator(emulator_id: String) -> bool:
	return emulator.download_emulator(emulator_id)

func edit_emulator_file(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	return emulator.edit_emulator_file(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

func edit_emulator_file_with_backup(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	return emulator.edit_emulator_file_with_backup(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

func restore_emulator_file(emulator_id: String, file_path: String) -> bool:
	return emulator.restore_emulator_file(emulator_id, file_path)

func has_emulator_file_backup(emulator_id: String, file_path: String) -> bool:
	return emulator.has_emulator_file_backup(emulator_id, file_path)

func scan_emulator_install_state(emulator_id: String):
	emulator.scan_emulator_install_state(emulator_id)

func is_emulator_downloading(emulator_id: String) -> bool:
	return emulator.is_emulator_downloading(emulator_id)

func is_emulator_queued(emulator_id: String) -> bool:
	return emulator.is_emulator_queued(emulator_id)

func get_emulator_active_download(emulator_id: String):
	return emulator.get_emulator_active_download(emulator_id)

# ============================================================================
# Game preparation wrappers
# ============================================================================

func cleanup_extracted_game_files(game: GameResource, operation_token: Dictionary = {}) -> void:
	$GameSubManager.cleanup_extracted_game_files(game, operation_token)

# ============================================================================
# Firmware wrappers
# ============================================================================

func clear_firmware_cache(platform_slug: String, emulator_id: String, core_id: String = "") -> void:
	firmware.clear_firmware_cache(platform_slug, emulator_id, core_id)

func clear_all_firmware_cache() -> void:
	firmware.clear_all_firmware_cache()

func clear_firmware_cache_for_platform(platform_slug: String) -> void:
	firmware.clear_firmware_cache_for_platform(platform_slug)

func get_firmware_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return firmware.get_firmware_directory(emulator_id, platform_slug, core_id)

func is_platform_firmware_ready(platform_slug: String, emulator_id: String, core_id: String = "") -> bool:
	return firmware.is_platform_firmware_ready(platform_slug, emulator_id, core_id)

func is_platform_firmware_ready_cached(platform_slug: String, emulator_id: String, core_id: String = "") -> int:
	return firmware.is_platform_firmware_ready_cached(platform_slug, emulator_id, core_id)

func get_platform_firmware_expected_files(platform_slug: String) -> Array:
	return firmware.get_platform_firmware_expected_files(platform_slug)

func setup_platform_firmware(platform_slug: String, emulator_id: String, callback: Callable = Callable(), core_id: String = "") -> void:
	firmware.setup_platform_firmware(platform_slug, emulator_id, callback, core_id)

# ============================================================================
# Launch intent wrappers
# ============================================================================

func resolve_emulator_for_game(game: GameResource) -> String:
	return intent_manager.resolve_emulator_for_game(game)

func create_launch_intent(game: GameResource, rom_path_override: String = "") -> LaunchIntent:
	return intent_manager.create_launch_intent(game, rom_path_override)

# ============================================================================
# Background state wrappers
# ============================================================================

func is_in_background_state() -> bool:
	return process.is_in_background_state()

func get_background_pid() -> int:
	return process.get_background_pid()

func get_background_game() -> GameResource:
	return process.get_background_game()

func force_exit_background_state() -> void:
	process.force_exit_background_state()

func resume_retained_game(romm_id: int) -> Dictionary:
	return await process.resume_retained_game(romm_id)

func close_retained_game(romm_id: int) -> Dictionary:
	return await process.close_retained_game(romm_id)

func discard_lost_android_session() -> void:
	await process.discard_lost_android_session()

# ============================================================================
# Process execution wrappers
# ============================================================================

func execute_launch(intent: LaunchIntent) -> bool:
	return await process.execute_launch(intent)

func _create_process_from_intent(intent: LaunchIntent) -> int:
	return await process._create_desktop_process(intent)

# ============================================================================
# Launch orchestration
# ============================================================================

# Tracks the most recent prepared ROM path for a shuffler game so callers can
# update their bag entry after pre-launch preparation.
var _last_prepared_rom_paths: Dictionary = {}  # game romm_id -> prepared path

## Launch a game for the shuffler (no save sync, no background state).
## Calls on_pid_ready(pid) when the process is created. PID may be -1 on failure.
## If a download is pending, the function returns immediately and on_pid_ready will be called later.
func launch_shuffler_game(game: GameResource, rom_path_override: String, on_pid_ready: Callable = Callable()) -> void:
	print("[LaunchManager] launch_shuffler_game() called for: ", game.get_display_name())

	if not _try_begin_launch(game):
		if on_pid_ready.is_valid():
			on_pid_ready.call(-1)
		return

	var emulator_id = intent_manager.resolve_emulator_for_game(game)
	if emulator_id == "":
		push_error("[LaunchManager] No emulator configured for platform: " + game.platform_slug)
		if on_pid_ready.is_valid():
			on_pid_ready.call(-1)
		_end_launch(game.romm_id)
		return
	
	var on_ready = func():
		var prepared_rom_path = _last_prepared_rom_paths.get(game.romm_id, rom_path_override) as String
		var launch_intent = intent_manager.create_launch_intent(game, prepared_rom_path)
		if not launch_intent:
			push_error("[LaunchManager] Failed to create launch intent")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			_end_launch(game.romm_id)
			return

		if SystemManager.platform.is_android():
			push_error("[LaunchManager] Shuffler not supported on Android")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			_end_launch(game.romm_id)
			return

		var pid = await process._create_desktop_process(launch_intent)
		if pid != -1:
			print("[LaunchManager] Shuffler launch successful, PID: ", pid)
		if on_pid_ready.is_valid():
			on_pid_ready.call(pid)
		_end_launch(game.romm_id)
	
	# Vita3K and RPCS3-family emulators need TitleID extraction and ZIP extraction
	# even in shuffler mode. Keyed on architecture so forks (armsx3, aps3e, ...)
	# prep like their parent. Other emulators skip the normal preparation step.
	var prep_arch = registry.get_emulator_architecture(emulator_id)
	var should_prepare = prep_arch == "vita3k" or prep_arch == "rpcs3"
	# Prep/firmware failures inside _ensure_prerequisites never reach on_ready,
	# so report them as a failed pid or the shuffler idles out the round on a
	# dead launch.
	var on_failed = func():
		if on_pid_ready.is_valid():
			on_pid_ready.call(-1)
	var is_ready = await _ensure_prerequisites(game, emulator_id, on_ready, should_prepare, true, rom_path_override, on_failed)
	if not is_ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called


## Prepares a game for a shuffler session ahead of time. Returns true if the game
## is ready to launch. If preparation updates the ROM path (e.g. extracting a PS3
## ZIP to a folder), the new path can be retrieved with get_last_prepared_rom_path().
func prepare_game_for_shuffler(game: GameResource, emulator_id: String, rom_path_override: String) -> bool:
	var prep_success = await $GameSubManager._prepare_game_for_launch(game, emulator_id, true, rom_path_override)
	if prep_success:
		_last_prepared_rom_paths[game.romm_id] = $GameSubManager._last_prepared_rom_path
	return prep_success


func get_last_prepared_rom_path(game: GameResource) -> String:
	return _last_prepared_rom_paths.get(game.romm_id, "") as String


## Guards against concurrent launches of the same game (double-tap, signal storms).
func _try_begin_launch(game: GameResource) -> bool:
	if _in_flight_launches.has(game.romm_id):
		SystemManager.notifications.show_notification("Launch already in progress for " + game.get_display_name(), SystemManager.notifications.Type.WARNING)
		return false
	_in_flight_launches[game.romm_id] = true
	return true

func _end_launch(romm_id: int) -> void:
	_in_flight_launches.erase(romm_id)


## Called when the user dismisses the Android post-install permissions reminder.
## Outside a game-launch context this is a plain dismiss; mid-launch it resumes
## the pending launch if the emulator is now installed, or aborts it cleanly.
func on_install_reminder_dismissed(emulator_id: String) -> void:
	_open_install_reminders.erase(emulator_id)

	if not _pending_launches.has(emulator_id):
		return  # Plain dismiss: no game launch is waiting on this emulator

	# The user was just sent to the system APK installer for this emulator, so
	# its cached validation is likely stale-negative; re-scan fresh.
	emulator.erase_validation_cache(emulator_id)
	if _is_emulator_fully_installed(emulator_id):
		print("[LaunchManager] Install reminder dismissed, emulator installed - resuming pending launch for: " + emulator_id)
		_continue_pending_launches(emulator_id)
	else:
		print("[LaunchManager] Install reminder dismissed but emulator not installed - aborting pending launch for: " + emulator_id)
		_abort_pending_launches(emulator_id, "Emulator not installed")


## Validates every registry install step for an emulator. Uses the cached
## get_install_progress scan so a launch sequence validates once instead of
## re-probing the filesystem at every stage (60 s TTL, targeted invalidation
## on install/state-changing events).
func _is_emulator_fully_installed(emulator_id: String) -> bool:
	var emu = registry.get_emulator(emulator_id)
	if emu.is_empty():
		return false
	return emulator.get_install_progress(emulator_id).get("is_installed", false)


## Resumes queued launches for an emulator that finished installing.
func _continue_pending_launches(emulator_id: String) -> void:
	if not _pending_launches.has(emulator_id):
		return
	var pending_list: Array = _pending_launches[emulator_id]
	_pending_launches.erase(emulator_id)

	# Yield a frame so deferred focus restoration (app resume) can re-focus the
	# launching card before the overlay tries to grab its texture.
	await get_tree().process_frame

	for pending in pending_list:
		var pending_game: GameResource = pending.game
		var pending_callback: Callable = pending.callback
		SystemManager.notifications.show_notification("Launching " + pending_game.get_display_name() + "...", SystemManager.notifications.Type.INFO)

		# Replay the launch transition: it was force-hidden when the app resumed
		# from the Android installer.
		_restart_launch_overlay(pending_game)

		if pending_callback.is_valid():
			# Re-enter _ensure_prerequisites so game preparation (e.g. PS3 ZIP
			# extraction) runs before on_ready performs the actual launch.
			await _ensure_prerequisites(pending_game, emulator_id, pending_callback)
		else:
			_end_launch(pending_game.romm_id)


## Drops queued launches for an emulator, releasing the in-flight guard so the
## affected games can be launched again.
func _abort_pending_launches(emulator_id: String, reason: String) -> void:
	if not _pending_launches.has(emulator_id):
		return
	var pending_list: Array = _pending_launches[emulator_id]
	_pending_launches.erase(emulator_id)
	for pending in pending_list:
		var pending_game: GameResource = pending.game
		SystemManager.notifications.show_notification(reason + " - launch cancelled for " + pending_game.get_display_name(), SystemManager.notifications.Type.WARNING)
		_end_launch(pending_game.romm_id)
	_abort_launch_overlay()


## Replays the launch transition overlay for a game whose launch was interrupted
## before the process started (e.g. by an Android emulator install).
func _restart_launch_overlay(game: GameResource) -> void:
	var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
	if overlay_nodes.size() > 0:
		var overlay = overlay_nodes[0] as LaunchTransitionOverlay
		if overlay:
			overlay.restart(game)


## Hides the launch transition overlay after a failed launch. Any failure after
## game_launch_initiated leaves the fullscreen black overlay stuck: no
## background state is entered and no Android RESUMED arrives to dismiss it, so
## the app would sit black and unresponsive until the next real pause/resume.
func _abort_launch_overlay() -> void:
	var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
	if overlay_nodes.size() > 0:
		var overlay = overlay_nodes[0] as LaunchTransitionOverlay
		if overlay:
			overlay.abort()

## Prerequisites are complete: turn the cold landing page into a plain black
## launch curtain before any external process/intent is started.
func _finish_cold_launch_overlay() -> bool:
	var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
	if overlay_nodes.size() > 0:
		var overlay = overlay_nodes[0] as LaunchTransitionOverlay
		if overlay:
			return await overlay.finish_cold_launch()
	return true


## Main entry point for launching a game
func launch_game(game: GameResource, focus_index: int = -1) -> void:
	print("[LaunchManager] launch_game() called for: ", game.get_display_name() if game else "null", " with focus_index: ", focus_index)

	if process.is_in_background_state():
		var bg_game = process.get_background_game()
		if bg_game and bg_game.romm_id != game.romm_id:
			SystemManager.notifications.show_notification("Close the current game before launching another", SystemManager.notifications.Type.INFO)
			return

	if SystemManager.platform.is_android():
		if process._android_transition_inflight:
			SystemManager.notifications.show_notification("Finishing the current game transition first", SystemManager.notifications.Type.INFO)
			return
		var retained: GameSession = process.get_active_android_session()
		if retained and retained.state == GameSession.State.LOST:
			if retained.romm_id != game.romm_id:
				SystemManager.notifications.show_notification("Close or discard the lost session before launching another game", SystemManager.notifications.Type.INFO)
				return
			await process.discard_lost_android_session()
		elif process.has_other_retained_game(game.romm_id):
			SystemManager.notifications.show_notification("Close the current game before launching another", SystemManager.notifications.Type.INFO)
			return
		elif process.has_retained_android_session():
			await _resume_android_with_transition(retained)
			return

	if not _try_begin_launch(game):
		return

	# Never launch while any part of this game is still downloading: multi-disc
	# games would launch with a partial/incomplete disc set, and single-disc
	# games would just re-attach to the in-flight download and appear broken.
	# Tell the user instead. Placed before game_launch_initiated so a blocked
	# launch produces no overlay, sound, or focus changes.
	if game.source != "steam" and SystemManager.download.is_game_download_in_progress(game):
		var summary: Dictionary = SystemManager.download.get_game_download_summary(game)
		var msg := game.get_display_name() + " is still downloading"
		if int(summary.get("discs_total", 0)) > 1:
			msg += " (disc %d/%d, %d%%)" % [
				mini(int(summary.discs_done) + 1, int(summary.discs_total)),
				int(summary.discs_total),
				int(float(summary.progress) * 100),
			]
		else:
			msg += " (%d%%)" % int(float(summary.progress) * 100)
		print("[LaunchManager] " + msg + " - launch blocked")
		SystemManager.notifications.show_notification(msg + " - launch when it finishes", SystemManager.notifications.Type.INFO)
		_end_launch(game.romm_id)
		return

	# Check if this is a Steam game. Branched BEFORE the transition signal:
	# the backend picker (shown when both launchers are installed) must appear
	# before the overlay, which otherwise covers it with a black screen.
	if game.source == "steam":
		_launch_steam_game(game, focus_index)
		return

	# Emit signal immediately so focus can be saved before any suspension happens
	print("[LaunchManager] Emitting game_launch_initiated signal")
	game_launch_initiated.emit(game, focus_index)

	# Play launch sound
	if SystemManager.audio:
		SystemManager.audio.play_sfx("affirm_00")
	
	# If game is not downloaded, queue the download first then proceed
	if not game.is_active_variant_downloaded():
		_queue_game_download_then_launch(game)
		return

	# Multi-disc games on m3u-capable platforms need every disc on disk so an
	# m3u playlist can be generated; force-download the missing discs, then
	# launch. A specific disc (2+) selected by the user still launches directly.
	if M3USubManager.supports_m3u(game.platform_slug) and game.is_multi_disc() and game.get_active_disc_number() <= 1 and not game.are_all_discs_downloaded():
		_queue_game_download_then_launch(game)
		return

	# Single ordered flow: emulator -> firmware -> prep -> saves -> launch
	_launch_with_emulator_check(game)

## Launch a Steam game via intent through an installed frontend (GameNative/DroidDeck)
func _launch_steam_game(game: GameResource, focus_index: int = -1) -> void:
	if not SystemManager.platform.is_android():
		push_error("[LaunchManager] Cannot launch Steam game on non-Android platform")
		SystemManager.notifications.show_notification("Steam games only available on Android", SystemManager.notifications.Type.ERROR)
		_end_launch(game.romm_id)
		return

	# Resolve the backend first: the picker dialog must be fully answered
	# before the transition overlay and trim start. Nothing is torn down yet,
	# so cancel/failure here needs no restore.
	steam.resolve_backend_interactive(game.steam_app_id, func(backend: String, message: String):
		if backend == "":
			if message != "":
				push_error("[LaunchManager] Failed to launch Steam game: " + message)
				SystemManager.notifications.show_notification(message, SystemManager.notifications.Type.ERROR)
			_end_launch(game.romm_id)
			return
		_launch_steam_with_backend(game, backend, focus_index)
	)

## Backend resolved: transition overlay -> trim -> intent -> background state,
## mirroring the emulator launch sequence.
func _launch_steam_with_backend(game: GameResource, backend: String, focus_index: int) -> void:
	# Emit signal immediately so focus can be saved before any suspension happens
	game_launch_initiated.emit(game, focus_index)

	if SystemManager.audio:
		SystemManager.audio.play_sfx("affirm_00")

	# Wait for launch transition overlay phase 1 before trimming, mirroring
	# _launch_game_internal: the trim frees the cover textures the overlay is
	# still sampling mid-animation, so trimming early renders it black.
	if LaunchTransitionOverlay.is_transition_active:
		var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
		if overlay_nodes.size() > 0:
			var overlay = overlay_nodes[0] as LaunchTransitionOverlay
			if overlay:
				if not overlay.is_phase1_complete():
					await overlay.phase1_completed
		else:
			# Fallback: wait for the expected duration
			await get_tree().create_timer(0.5).timeout

	if not await _finish_cold_launch_overlay():
		_abort_launch_overlay()
		if launch_failed_hook.is_valid():
			launch_failed_hook.call()
		_end_launch(game.romm_id)
		return

	if pre_launch_hook.is_valid():
		await pre_launch_hook.call(game)

	var success := steam.launch_with_backend(backend, game.steam_app_id)
	if success:
		_update_last_played(game)
		# Enter background state like every other external launch: on resume the
		# normal exit path hides the launch overlay AND restores the trimmed UI.
		# Without this, RESUMED leaves the app in its trimmed (black,
		# unresponsive) state. The backend package arms the presence watch.
		process.enter_background_state_android(game, steam.get_installed_package(backend))
	else:
		var message := "Failed to launch %s. Is the app installed?" % steam.get_backend_label(backend)
		push_error("[LaunchManager] " + message)
		SystemManager.notifications.show_notification(message, SystemManager.notifications.Type.ERROR)
		_abort_launch_overlay()
		# launch_failed_hook is _restore_after_launch: undo the trim.
		if launch_failed_hook.is_valid():
			launch_failed_hook.call()
	_end_launch(game.romm_id)

## If game is not downloaded, queue the download first then proceed.
## Multi-disc games on m3u-capable platforms queue every missing disc.
func _queue_game_download_then_launch(game: GameResource) -> void:
	SystemManager.notifications.show_notification("Downloading " + game.get_display_name() + "...", SystemManager.notifications.Type.INFO)

	SystemManager.download.queue_game_download(game, func(success: bool):
		if success:
			# The in-memory game is mutated by download completion (disc flags,
			# m3u path) ahead of the async DB write, so it is the freshest copy.
			_launch_with_emulator_check(game)
		else:
			SystemManager.notifications.show_notification("Download failed for " + game.get_display_name(), SystemManager.notifications.Type.ERROR)
			_abort_launch_overlay()
			_end_launch(game.romm_id)
	)

## Ensures emulator is installed, firmware is ready, and game is prepared.
## Returns true if everything is ready and on_ready was called.
## Returns false if a download was started (caller should return and wait for callback).
func _ensure_prerequisites(game: GameResource, emulator_id: String, on_ready: Callable, prepare_game: bool = true, is_shuffler: bool = false, rom_path_override: String = "", on_failed: Callable = Callable()) -> bool:
	var emu = registry.get_emulator(emulator_id)
	var emulator_name = RegistrySubManager.get_emulator_display_name(emu, emulator_id)
	
	# Check if emulator is fully installed (cached scan, see _is_emulator_fully_installed)
	var _perf_t0 = Time.get_ticks_msec()
	var is_actually_installed = emulator.get_install_progress(emulator_id).get("is_installed", false)
	print("[PERF] launch.install_progress(%s): %dms" % [emulator_id, Time.get_ticks_msec() - _perf_t0])
	
	# If emulator is now installed but there's a stale pending launch, abort it
	# cleanly so its in-flight guard can't wedge the game as "already launching"
	if is_actually_installed and _pending_launches.has(emulator_id):
		print("[LaunchManager] Emulator " + emulator_id + " is installed, aborting stale pending launch")
		_abort_pending_launches(emulator_id, "Launch superseded")

	# Check if this game is already pending launch
	if _pending_launches.has(emulator_id):
		for pending_data in _pending_launches[emulator_id]:
			var pending_game: GameResource = pending_data.game
			if pending_game.romm_id == game.romm_id:
				SystemManager.notifications.show_notification("Game already pending launch! Waiting for emulator installation...", SystemManager.notifications.Type.WARNING)
				_abort_launch_overlay()
				return false

	if not is_actually_installed:
		# Auto-install ends in an APK install: gate on the install grant
		# before queuing anything. The continuation re-runs the whole
		# prerequisite pass once the user grants, so the launch resumes on
		# its own; the visible overlay is still reset in the meantime.
		if not SystemManager.platform.ensure_install_permission(emulator_name, func():
			_ensure_prerequisites(game, emulator_id, on_ready, prepare_game, is_shuffler, rom_path_override, on_failed)
		):
			_abort_launch_overlay()
			_end_launch(game.romm_id)
			return false
		SystemManager.notifications.show_notification("Setting up " + emulator_name + "...", SystemManager.notifications.Type.INFO)

		if not emulator_extraction_completed.is_connected(_on_emulator_installed_for_launch):
			emulator_extraction_completed.connect(_on_emulator_installed_for_launch)

		if _pending_launches.has(emulator_id):
			# Install already in progress: queue this launch alongside the pending one(s)
			_pending_launches[emulator_id].append({game = game, callback = on_ready})
			return false

		_pending_launches[emulator_id] = [{game = game, callback = on_ready}]

		var download_success = emulator.download_emulator(emulator_id)

		if download_success:
			SystemManager.notifications.show_notification(emulator_name + " downloading... Will auto-launch when ready.", SystemManager.notifications.Type.INFO)
		else:
			SystemManager.notifications.show_notification("Failed to queue " + emulator_name + " download", SystemManager.notifications.Type.ERROR)
			_pending_launches.erase(emulator_id)
			_abort_launch_overlay()
			_end_launch(game.romm_id)
		return false
	
	# Emulator is installed - check if the selected RetroArch core is ready (Android only)
	if SystemManager.platform.is_android() and emulator_id == "retroarch":
		var core_id_for_launch: String = intent_manager.resolve_core_for_game(game)
		if not core.is_core_ready(emulator_id, game.platform_slug, core_id_for_launch):
			var core_key: String = game.platform_slug + ":" + core_id_for_launch
			if _pending_core_downloads.has(core_key):
				print("[LaunchManager] Core download already in progress for " + core_key + ", will launch when ready")
				SystemManager.notifications.show_notification("Core download in progress for " + game.platform_slug + "...", SystemManager.notifications.Type.INFO)
				_pending_core_launches.append({"game": game, "platform_slug": game.platform_slug, "core_id": core_id_for_launch, "callback": on_ready})
				return false
			
			print("[LaunchManager] Core not ready for " + game.platform_slug + ", downloading...")
			SystemManager.notifications.show_notification("Downloading core for " + game.platform_slug + "...", SystemManager.notifications.Type.INFO)
			
			_pending_core_downloads[core_key] = true
			_pending_core_launches.append({"game": game, "platform_slug": game.platform_slug, "core_id": core_id_for_launch, "callback": on_ready})
			
			core.setup_platform_core(emulator_id, game.platform_slug, core_id_for_launch, Callable())
			return false
	
	# Emulator is installed - check firmware
	var core_id_for_firmware = ""
	if emulator_id == "retroarch":
		core_id_for_firmware = intent_manager.resolve_core_for_game(game)

	# Adopt externally-discovered data dirs (azahar's SAF-picked user folder,
	# read from its private prefs via vendor root) BEFORE any path resolution
	# below, so firmware/save checks target the emulator's real location.
	if SystemManager.platform.is_android():
		emulator.discover_external_dir_via_root(emulator_id)

	# Enforce kyodai-managed config paths BEFORE any firmware/save resolution:
	# on a fresh install the config has no stated keys yet, so resolution would
	# fall back to the emulator's built-in defaults and the download would land
	# in a directory the emulator stops reading once launch-time enforcement
	# runs (process_sub_manager does the same write, but too late for this).
	RSM.enforce_paths(emulator_id, game.platform_slug, core_id_for_firmware)
	print("[PERF] launch.enforce_paths(%s): %dms" % [emulator_id, Time.get_ticks_msec() - _perf_t0])
	_perf_t0 = Time.get_ticks_msec()

	if firmware.is_platform_firmware_ready(game.platform_slug, emulator_id, core_id_for_firmware):
		firmware.apply_force_pull_config(game.platform_slug, emulator_id)
		print("[PERF] launch.firmware_ready(%s): %dms" % [emulator_id, Time.get_ticks_msec() - _perf_t0])
	else:
		if _pending_firmware_downloads.has(game.platform_slug):
			print("[LaunchManager] Firmware download already in progress for " + game.platform_slug + ", will launch when ready")
			SystemManager.notifications.show_notification("Firmware download in progress for " + game.platform_slug + "...", SystemManager.notifications.Type.INFO)
			_pending_firmware_launches.append({"game": game, "emulator_id": emulator_id, "core_id": core_id_for_firmware, "callback": on_ready, "on_failed": on_failed, "prepare_game": prepare_game, "is_shuffler": is_shuffler, "rom_path_override": rom_path_override})
			return false
		
		print("[LaunchManager] Firmware not ready for " + game.platform_slug + ", downloading...")
		SystemManager.notifications.show_notification("Downloading firmware for " + game.platform_slug + "...", SystemManager.notifications.Type.INFO)
		
		_pending_firmware_downloads[game.platform_slug] = true
		_pending_firmware_launches.append({"game": game, "emulator_id": emulator_id, "core_id": core_id_for_firmware, "callback": on_ready, "on_failed": on_failed, "prepare_game": prepare_game, "is_shuffler": is_shuffler, "rom_path_override": rom_path_override})
		
		firmware.setup_platform_firmware(game.platform_slug, emulator_id, func(success: bool, message: String):
			_pending_firmware_downloads.erase(game.platform_slug)
			
			var matching_indices: Array[int] = []
			for i in range(_pending_firmware_launches.size()):
				var pending = _pending_firmware_launches[i]
				if pending.get("emulator_id", "") == emulator_id and pending.get("core_id", "") == core_id_for_firmware:
					matching_indices.append(i)
			
			if matching_indices.is_empty():
				return
			
			if not success:
				push_error("[LaunchManager] Firmware download failed for " + game.platform_slug + ": " + message)
				SystemManager.notifications.show_notification("Failed to download firmware for " + game.platform_slug, SystemManager.notifications.Type.ERROR)
				# Abort the pending launches: on_ready callbacks take no arguments
				# and would perform the launch, so they must not be invoked here.
				for i in matching_indices:
					_end_launch((_pending_firmware_launches[i].game as GameResource).romm_id)
					var failed_cb: Callable = _pending_firmware_launches[i].get("on_failed", Callable())
					if failed_cb.is_valid():
						failed_cb.call()
				for i in range(matching_indices.size() - 1, -1, -1):
					_pending_firmware_launches.remove_at(matching_indices[i])
				_abort_launch_overlay()
				return
			
			print("[LaunchManager] Firmware ready for " + game.platform_slug + ", continuing launch...")
			for i in matching_indices:
				var pending = _pending_firmware_launches[i]
				var pending_game: GameResource = pending.game
				var pending_callback = pending.callback
				# Re-enter _ensure_prerequisites so game preparation (e.g. PS3 ZIP
				# extraction) runs before on_ready performs the actual launch.
				# The original call's context travels with the pending entry:
				# shuffler launches would otherwise re-enter with default args
				# (prepare_game=true, is_shuffler=false, no rom override) and prep
				# against the relative game.file_path instead of the temp copy.
				await _ensure_prerequisites(pending_game, pending.emulator_id, pending_callback, pending.get("prepare_game", true), pending.get("is_shuffler", false), pending.get("rom_path_override", ""), pending.get("on_failed", Callable()))
			for i in range(matching_indices.size() - 1, -1, -1):
				_pending_firmware_launches.remove_at(matching_indices[i])
		, core_id_for_firmware)
		
		return false
	
	if prepare_game:
		# Emulator and firmware are ready - prepare game
		print("[LaunchManager] _ensure_prerequisites: Preparing game for emulator: " + emulator_id)
		var _perf_prep_t0 = Time.get_ticks_msec()
		var prep_success = await $GameSubManager._prepare_game_for_launch(game, emulator_id, is_shuffler, rom_path_override)
		print("[PERF] launch.prepare_game(%s): %dms" % [emulator_id, Time.get_ticks_msec() - _perf_prep_t0])
		_perf_dump_saf_stats("launch:" + emulator_id)
		if not prep_success:
			push_error("[LaunchManager] Failed to prepare game for launch: " + game.get_display_name())
			SystemManager.notifications.show_notification("Failed to prepare game for launch", SystemManager.notifications.Type.ERROR)
			_abort_launch_overlay()
			_end_launch(game.romm_id)
			if on_failed.is_valid():
				on_failed.call()
			return false
		# Cache the prepared ROM path for every launch: it carries the relative
		# path fix, m3u playlist substitution, and extraction rewrites that
		# _launch_game_internal must use verbatim instead of re-resolving.
		# Shuffler callers also read this to update bag entries.
		_last_prepared_rom_paths[game.romm_id] = $GameSubManager._last_prepared_rom_path
		print("[LaunchManager] _ensure_prerequisites: Game preparation complete")
	else:
		print("[LaunchManager] _ensure_prerequisites: Skipping game preparation (shuffler session)")
	
	on_ready.call()
	return true

## Dumps the plugin's SAF op counters (and resets them) - diagnostic for the
## restricted-path I/O cost on SAF-tier devices.
func _perf_dump_saf_stats(label: String) -> void:
	if not SystemManager.platform.is_android():
		return
	if Engine.has_singleton("KyodaiBridge"):
		var bridge = Engine.get_singleton("KyodaiBridge")
		var snap = bridge.call("safPerfSnapshot")
		print("[PERF] SAF ops (" + label + "): " + str(snap))

## Check emulator status and launch game (game must be downloaded)
func _launch_with_emulator_check(game: GameResource) -> void:
	print("[LaunchManager] _launch_with_emulator_check: ENTER for " + game.get_display_name())
	
	var emulator_id = intent_manager.resolve_emulator_for_game(game)
	
	if emulator_id == "":
		SystemManager.notifications.show_notification("No emulator configured for platform: " + game.platform_slug, SystemManager.notifications.Type.ERROR)
		_abort_launch_overlay()
		_end_launch(game.romm_id)
		return
	
	var on_ready = func():
		# Sync saves then launch
		print("[LaunchManager] Starting pre-launch save sync...")
		DataManager.auto_download_saves_for_game(game, emulator_id, func():
			print("[LaunchManager] Pre-launch save sync complete, launching game...")
			_launch_game_internal(game, emulator_id)
		)
		print("[LaunchManager] _launch_with_emulator_check: EXIT")
	
	var is_ready = await _ensure_prerequisites(game, emulator_id, on_ready)
	if not is_ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called

## Handler for when emulator extraction completes - retries pending launches
func _on_emulator_installed_for_launch(emulator_id: String, success: bool):
	if not success:
		return

	# Check if emulator is actually fully installed by validating all registry steps
	if not _is_emulator_fully_installed(emulator_id):
		# Post-install is still running (or, on Android, the user hasn't finished
		# the APK install yet). The resume path (clear_stale_pending_launches) or
		# the install-reminder dismissal retries the pending launch.
		return

	# Check if we have pending launches for this emulator
	if _pending_launches.has(emulator_id):
		# Give a small delay for file system to settle
		await get_tree().create_timer(0.5).timeout
		print("[LaunchManager] _on_emulator_installed_for_launch: Resuming pending launches for emulator: " + emulator_id)
		_continue_pending_launches(emulator_id)

## Handler for on-demand core downloads - resumes pending launches
func _on_core_download_completed(platform_slug: String, core_id: String, success: bool):
	var core_key: String = platform_slug + ":" + core_id
	_pending_core_downloads.erase(core_key)
	
	var matching_indices: Array[int] = []
	for i in range(_pending_core_launches.size()):
		var pending = _pending_core_launches[i]
		if pending.get("platform_slug", "") == platform_slug and pending.get("core_id", "") == core_id:
			matching_indices.append(i)
	
	if matching_indices.is_empty():
		return
	
	if not success:
		push_error("[LaunchManager] Core download failed for " + core_key)
		SystemManager.notifications.show_notification("Failed to download core for " + platform_slug, SystemManager.notifications.Type.ERROR)
		# Abort the pending launches: on_ready callbacks perform the launch
		# and must not run when the required core failed to download.
		for i in matching_indices:
			_end_launch((_pending_core_launches[i].game as GameResource).romm_id)
		for i in range(matching_indices.size() - 1, -1, -1):
			_pending_core_launches.remove_at(matching_indices[i])
		_abort_launch_overlay()
		core_download_completed.emit(platform_slug, core_id, false)
		return
	
	print("[LaunchManager] Core ready for " + core_key + ", continuing launch...")
	core_download_completed.emit(platform_slug, core_id, true)
	for i in matching_indices:
		var pending = _pending_core_launches[i]
		var game: GameResource = pending.game as GameResource
		var pending_callback = pending.callback
		var pending_emulator_id: String = intent_manager.resolve_emulator_for_game(game)
		await _ensure_prerequisites(game, pending_emulator_id, pending_callback)
	for i in range(matching_indices.size() - 1, -1, -1):
		_pending_core_launches.remove_at(matching_indices[i])

func _resume_android_with_transition(session: GameSession) -> void:
	var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
	if overlay_nodes.size() > 0:
		var overlay = overlay_nodes[0] as LaunchTransitionOverlay
		var texture := _session_snapshot_texture(session)
		if overlay and texture:
			var info: Dictionary = overlay._get_focused_card_and_texture()
			if info.get("card", null) != null and info.get("rect", Rect2()).size.x > 0.0 and info.get("rect", Rect2()).size.y > 0.0:
				LaunchTransitionOverlay.set_source(texture, info.rect, info.get("corner_radius", 0.06))
				overlay.play_resume(session.game)
				# Do not let Android begin its task transition until the exact
				# unmodified snapshot is already fullscreen.
				await overlay.resume_ready
	var result: Dictionary = await process.resume_retained_game(session.romm_id)
	if not result.get("ok", false):
		for node in overlay_nodes:
			if node is LaunchTransitionOverlay:
				node.abort()

func _session_snapshot_texture(session: GameSession) -> Texture2D:
	# GameCard owns one shared decode/cache path for overlay and card media.
	return GameCard.session_texture_for_path(str(session.runtime.get("snapshotPath", "")))

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	print("[LaunchManager] _launch_game_internal: ENTER for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	if process.is_in_background_state():
		var bg_game = process.get_background_game()
		if bg_game and bg_game.romm_id != game.romm_id:
			push_warning("[LaunchManager] Refusing to launch a different game while another session is active")
			SystemManager.notifications.show_notification("Close the current game before launching another", SystemManager.notifications.Type.INFO)
			_abort_launch_overlay()
			_end_launch(game.romm_id)
			return
		if bg_game and bg_game.romm_id == game.romm_id:
			push_warning("[LaunchManager] _launch_game_internal: " + game.get_display_name() + " is already running, ignoring duplicate launch")
			_abort_launch_overlay()
			_end_launch(game.romm_id)
			return
	
	# Use the ROM path resolved during game prep (m3u playlists, relative-path
	# fixes) instead of re-deriving it. Erased on use so a stale entry from a
	# previous launch can never leak into this one. Empty falls back to the
	# intent builder's own resolution (e.g. headless runs that skip prep).
	var prepared_path := _last_prepared_rom_paths.get(game.romm_id, "") as String
	_last_prepared_rom_paths.erase(game.romm_id)
	var launch_intent = intent_manager.create_launch_intent(game, prepared_path)

	if not launch_intent:
		push_error("[LaunchManager] _launch_game_internal: create_launch_intent returned null")
		SystemManager.notifications.show_notification("Failed to create launch intent", SystemManager.notifications.Type.ERROR)
		_abort_launch_overlay()
		_end_launch(game.romm_id)
		print("[LaunchManager] _launch_game_internal: EXIT (null intent)")
		return
	
	# Wait for launch transition overlay phase 1 to complete before opening game window
	# This ensures the user sees the card scale up before the game covers it
	if LaunchTransitionOverlay.is_transition_active:
		print("[LaunchManager] Waiting for launch transition overlay phase 1...")
		# Find the overlay instance to await its signal
		var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
		if overlay_nodes.size() > 0:
			var overlay = overlay_nodes[0] as LaunchTransitionOverlay
			if overlay:
				if overlay.is_phase1_complete():
					print("[LaunchManager] Overlay phase 1 already complete, proceeding")
				else:
					await overlay.phase1_completed
					print("[LaunchManager] Overlay phase 1 complete, proceeding with launch")
		else:
			# Fallback: wait for the expected duration
			await get_tree().create_timer(0.5).timeout
	
	if not await _finish_cold_launch_overlay():
		_abort_launch_overlay()
		if launch_failed_hook.is_valid():
			launch_failed_hook.call()
		_end_launch(game.romm_id)
		return
	print("[LaunchManager] _launch_game_internal: Launch intent created, executing launch...")

	# Let the app hibernate (release UI/memory) before the process starts and,
	# on Android, before the OS suspends us. Awaiting guarantees the trim —
	# including frame-deferred frees — is complete before launch.
	if pre_launch_hook.is_valid():
		await pre_launch_hook.call(game)

	var success = await process.execute_launch(launch_intent)
	
	if not success:
		push_error("[LaunchManager] _launch_game_internal: execute_launch returned false")
		SystemManager.notifications.show_notification("Failed to launch " + game.get_display_name(), SystemManager.notifications.Type.ERROR)
		_abort_launch_overlay()
		if launch_failed_hook.is_valid():
			launch_failed_hook.call()
		_end_launch(game.romm_id)
		print("[LaunchManager] _launch_game_internal: EXIT (launch failed)")
		return

	print("[LaunchManager] _launch_game_internal: Launch successful")

	# Update last_played timestamp on successful launch
	_update_last_played(game)
	_end_launch(game.romm_id)
	print("[LaunchManager] _launch_game_internal: EXIT (success)")

## Update the last_played timestamp for a game
func _update_last_played(game: GameResource) -> void:
	var timestamp = Time.get_datetime_string_from_system(false, true)  # UTC format
	game.last_played = timestamp
	
	# Steam games are not stored in the database, so persist in settings instead.
	if game.source == "steam":
		steam.update_last_played(game.steam_app_id, timestamp)
		game_launched.emit(game)
		return
	
	# Update in database
	DataManager.update_game_last_played(game.romm_id, timestamp)

	# Sync "now playing" + server-side last-played back to RomM (silent, queued if offline)
	DataManager.set_game_user_props(game, {"now_playing": true}, true, false)

	game_launched.emit(game)


# ============================================================================
# Shuffler facade
# ============================================================================

func is_session_active() -> bool:
	return shuffler.is_session_active()

func is_shuffle_session_active() -> bool:
	return shuffler.is_shuffle_session_active()

func get_shuffle_override(platform_slug: String) -> Dictionary:
	return shuffler.get_shuffle_override(platform_slug)

func set_shuffle_override(platform_slug: String, emulator_id: String, core_id: String) -> void:
	shuffler.set_shuffle_override(platform_slug, emulator_id, core_id)

func clear_shuffle_overrides() -> void:
	shuffler.clear_shuffle_overrides()

func start_shuffler_session(config: Dictionary) -> void:
	shuffler.start_session(config)

func stop_shuffler_session() -> void:
	shuffler.stop_session()


# ============================================================================
# Steam facade
# ============================================================================

func steam_has_games() -> bool:
	return steam.has_games()

func steam_create_game_resources() -> Array[GameResource]:
	return steam.create_game_resources()

func steam_get_game_count() -> int:
	return steam.get_game_count()

func steam_get_game_data(app_id: int) -> Dictionary:
	return steam.get_game_data(app_id)

func steam_rescan() -> void:
	steam.rescan()

func steam_remove_game(app_id: int) -> void:
	steam.remove_game(app_id)
