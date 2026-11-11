extends Manager
class_name GameSaveSubManager

## Manages save file discovery and syncing with RomM server

const DEBUG_LOG: bool = false

signal save_sync_completed(game: GameResource, success: bool, message: String)

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
const _ContentHash = preload("res://utils/sync/content_hash.gd")
const SaveLayout = preload("res://utils/filesystem/save_layout.gd")
const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")
const OperationLifecycle = preload("res://utils/filesystem/operation_lifecycle.gd")
# Gavel is a global class (utils/sync/gavel.gd); no preload const needed.
const SLOT_DEFAULT := ""
const MAX_FILE_SIZE := 100 * 1024 * 1024

# Strategy pattern lookup table for emulator-specific save operations
var _emulator_strategies: Dictionary = {}

# Re-entrancy guards: one save-sync flow per game+emulator, one conflict dialog at a time
var _save_sync_in_flight: Dictionary = {}  # "romm_id:emulator_id" -> true
var _conflict_dialog_open: bool = false
signal _conflict_dialog_closed

# Session-scoped conflict choices from the pre-launch dialog, honored by the
# post-launch auto-upload: "local" = force upload without re-asking,
# "cancel" = skip post-launch sync entirely.
var _sync_choice_overrides: Dictionary = {}  # "romm_id:emulator_id" -> "local"|"cancel"

# Startup dirty-save sweep runs once per session, after the DB is ready
var _dirty_sweep_ran: bool = false

func _save_sync_key(game: GameResource, emulator_id: String) -> String:
	return str(game.romm_id) + ":" + emulator_id

func is_save_sync_in_flight(game: GameResource, emulator_id: String) -> bool:
	return _save_sync_in_flight.has(_save_sync_key(game, emulator_id))

func _begin_save_sync(key: String) -> void:
	_save_sync_in_flight[key] = true

func _end_save_sync(key: String) -> void:
	_save_sync_in_flight.erase(key)

## True for Android paths that route through the KyodaiBridge plugin
## (/Android/data, /Android/obb - DocumentsContract/SAF or vendor root).
func _is_restricted_android_path(path: String) -> bool:
	if not SystemManager.platform.is_android():
		return false
	var normalized = path.replace("\\", "/")
	return normalized.contains("/Android/data/") or normalized.contains("/Android/obb/")

## Kill switch for threaded restricted-path I/O: touch this file to restore
## the old inline behavior without a rebuild.
const FORCE_INLINE_RESTRICTED_IO_FILE := "user://debug/force_inline_restricted_io"
## -1 unknown, 0 thread, 1 force inline. Cached; the kill switch is read once.
var _force_inline_restricted_io: int = -1

## Runs save-discovery/zip work off the main thread when safe. Restricted
## Android paths go through the KyodaiBridge plugin, whose SAF methods were
## audited thread-safe (stateless ContentResolver/DocumentsContract calls;
## SafCache/StorageTier/RootShell guard their shared state), so they thread
## too - on SAF-tier devices the inline path serialized a binder round-trip
## per file on the main thread, freezing launch. Safeguard: an EMPTY threaded
## scan on a restricted path is re-verified inline before any
## remote-over-local download decision (see auto_download_saves_for_game).
func _should_thread_io(path: String) -> bool:
	if _is_restricted_android_path(path):
		if _force_inline_restricted_io == -1:
			_force_inline_restricted_io = 1 if FileAccess.file_exists(FORCE_INLINE_RESTRICTED_IO_FILE) else 0
			if _force_inline_restricted_io == 1:
				print("[GameSaveSubManager] threaded restricted-path I/O disabled via " + FORCE_INLINE_RESTRICTED_IO_FILE)
		return _force_inline_restricted_io == 0
	return true

func _run_io_task(path: String, work: Callable, callback: Callable) -> void:
	if not _should_thread_io(path):
		var result = work.call()
		if callback.is_valid():
			callback.call(result)
		return
	if _is_restricted_android_path(path):
		# Restricted scans go to the multi-threaded os-execute pool, not the
		# single extraction thread: a big archive extraction (game download)
		# must not stall a pre-launch save sync queued behind it.
		MemorySubManager.queue_os_execute_task(work, callback)
	else:
		MemorySubManager.queue_extraction_task(work, callback)

func _ready() -> void:
	_init_strategies()
	# Temp-dir cleanup does recursive disk deletes; keep it off the startup
	# critical path and off the main thread.
	call_deferred("_schedule_temp_dir_cleanup")
	# DB init is queued from DataManager._ready (runs after this), so
	# database_ready always fires after this connect
	DataManager.database_ready.connect(_schedule_startup_dirty_sweep, CONNECT_ONE_SHOT)

## Runs temp-dir cleanup on the IO worker once startup has settled.
func _schedule_temp_dir_cleanup() -> void:
	await get_tree().create_timer(5.0).timeout
	if not is_inside_tree():
		return
	_run_io_task("user://temp/saves", _cleanup_all_temp_dirs, Callable())

## Reclaims only definitely stale operation artifacts. Live owners and every
## post-commit backup/recovery tree are preserved, unlike the old recursive wipe.
func _cleanup_all_temp_dirs() -> void:
	var manifest_cleanup := OperationLifecycle.cleanup_stale_operations()
	var untracked_cleanup := OperationLifecycle.cleanup_stale_untracked(["user://temp/saves"])
	print("[GameSaveSubManager] Operation cleanup: locks=" + str(manifest_cleanup.get("reclaimed", 0)) + ", manifest deleted=" + str(manifest_cleanup.get("deleted", []).size()) + ", untracked deleted=" + str(untracked_cleanup.get("deleted", []).size()))

## Initializes the emulator strategy lookup table
func _init_strategies() -> void:
	_emulator_strategies = {
		"cemu": {
			"validate": func(tid: String) -> String:
				return "" if tid.length() == 16 or tid.length() == 8 else "Invalid Title ID for Cemu game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_cemu_save(dir, _get_save_identity(game).id),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, _get_save_identity(game).id),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path.get_base_dir(),
			"save_name": func(game: GameResource, _path: String) -> String:
				return _get_save_identity(game).id,
		},
		"dolphin": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No game ID available for this Dolphin game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				if game.platform_slug == "wii":
					return discover_local_dolphin_wii_save(dir, _get_save_identity(game).id)
				return discover_local_dolphin_gc_save(dir, _get_save_identity(game).id),
		"resolve_path": func(dir: String, game: GameResource) -> String:
			if game.platform_slug == "wii":
				return FSM.join_paths(_wii_title_root(dir, game), _get_save_identity(game).id)
			return FSM.join_paths(dir, _gc_region_dir(_get_save_identity(game).id), "Card A"),
		"extract_dest": func(save_dir: String, _record_path: String, game: GameResource, _zip: String) -> String:
			if game.platform_slug == "wii":
				return FSM.join_paths(_wii_title_root(save_dir, game), _get_save_identity(game).id)
			return FSM.join_paths(save_dir, _gc_region_dir(_get_save_identity(game).id), "Card A"),
			"save_name": func(game: GameResource, _path: String) -> String:
				if game.platform_slug == "wii":
					return _get_save_identity(game).id
				return _gc_ascii_id(_get_save_identity(game).id),
		},
		"eden": {
			"validate": func(tid: String) -> String:
				return "" if tid.length() == 16 else "Invalid Title ID for Eden game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_eden_save(dir, _get_save_identity(game).id),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return _eden_save_target(dir, _get_save_identity(game).id),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path,
			"save_name": func(game: GameResource, _path: String) -> String:
				return _get_save_identity(game).id,
		},
		"pcsx2": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No serial available for this PS2 game. Launch it once to extract the serial.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_pcsx2_save(dir, _get_save_identity(game).id),
			"resolve_path": func(dir: String, _game: GameResource) -> String:
				return dir,
			"extract_dest": func(save_dir: String, _record_path: String, game: GameResource, zip_file_name: String) -> String:
				var folder_name: String
				if zip_file_name != "":
					folder_name = zip_file_name.get_basename()
				else:
					folder_name = _get_save_identity(game).id
				return FSM.join_paths(save_dir, folder_name),
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return local_file_path.get_file() if local_file_path != "" else _get_save_identity(game).id,
		},
		"ppsspp": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No game ID available for this PSP game. Launch it once to extract the ID.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_psp_save(dir, _get_save_identity(game).id),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, _get_save_identity(game).id),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return local_file_path.get_file() if local_file_path != "" else _get_save_identity(game).id,
			"zip": func(src: String, dst: String, game: GameResource) -> bool:
				return _zip_psp_save(src, _get_save_identity(game).id, dst, MAX_FILE_SIZE),
		},
		"vita3k": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No Title ID available for this Vita game. Launch it once to extract the Title ID.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_vita3k_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
		},
		"rpcs3": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this PS3 game. Launch it once to extract the Title ID."
				if tid.length() != 9:
					return "Invalid Title ID for PS3 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_rpcs3_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
		},
		"shadps4": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this PS4 game. Launch it once to extract the Title ID."
				if tid.length() != 9:
					return "Invalid Title ID for PS4 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_shadps4_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
		},
		"xenia": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this Xbox 360 game. Launch it once to extract the Title ID."
				if tid.length() != 8:
					return "Invalid Title ID for Xbox 360 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_xenia_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, _xenia_active_profile(dir, game.get_active_title_id()).profile_id, game.get_active_title_id()),
			"extract_dest": func(save_dir: String, _record_path: String, game: GameResource, _zip: String) -> String:
				return FSM.join_paths(save_dir, _xenia_active_profile(save_dir, game.get_active_title_id()).profile_id),
			"prepare": func(save_dir: String, game: GameResource) -> void:
				_xenia_rehome_to_active_profile(save_dir, game.get_active_title_id()),
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
		},
		"azahar": {
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return _discover_3ds_unit(dir, game),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				var save_id = _get_save_identity(game).id
				var category = save_id.get_slice("/", 0) if "/" in save_id else "00040000"
				var short_title_id = save_id.get_slice("/", save_id.get_slice_count("/") - 1) if "/" in save_id else save_id
				return FSM.join_paths(dir, "title", category, short_title_id),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path,
			"zip": func(src: String, dst: String, game: GameResource) -> bool:
				return _zip_3ds_save(src, dst, game),
			"unpack": func(zip_path: String, record_path: String, _game: GameResource, operation_token: Dictionary = {}):
				return _unpack_3ds_save(zip_path, record_path, operation_token),
		},
		"retroarch": {
			"validate": func(tid: String) -> String:
				# RetroArch platforms use several ID shapes (PSP 9-char, GC/Wii
				# 6-char, 3DS 16-char); the discover branches handle specifics.
				return "" if tid != "" else "No title ID available for this game. Launch it once to extract the ID.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return _discover_retroarch_save(dir, game),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return _resolve_retroarch_save_path(dir, game),
			"extract_dest": func(save_dir: String, record_path: String, game: GameResource, _zip: String) -> String:
				return _get_retroarch_extract_dest(save_dir, record_path, game),
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return _get_retroarch_save_name(game, local_file_path),
			"zip": func(src: String, dst: String, game: GameResource) -> bool:
				return _zip_retroarch_save(src, dst, game),
			# Only 3DS units need routed unpacking; other platforms return null
			# so the caller falls through to generic archive extraction.
			"unpack": func(zip_path: String, record_path: String, game: GameResource, operation_token: Dictionary = {}):
				if game.platform_slug == "3ds" and _is_3ds_tree_path(record_path):
					return _unpack_3ds_save(zip_path, record_path, operation_token)
				return null,
		},
	}

func _get_strategy(emulator_id: String, strategy_name: String) -> Callable:
	# Strategies are keyed by architecture family so forks (nethersx2,
	# x360-mobile, ...) share their parent emulator's save handling.
	var key = emulator_id
	if not _emulator_strategies.has(key):
		key = LaunchManager.registry.get_emulator_architecture(emulator_id)
	if not _emulator_strategies.has(key):
		return Callable()
	var strategies = _emulator_strategies[key] as Dictionary
	if not strategies.has(strategy_name):
		return Callable()
	return strategies[strategy_name] as Callable

## Cleans up empty parent directories after removing a temp file
func _cleanup_temp_dir(file_path: String) -> void:
	var parent = file_path.get_base_dir()
	while parent != "" and parent != "user://" and parent != "res://":
		if FSM.dir_exists(parent):
			var items = FSM.list_dir(parent + "/")
			var has_files = false
			for item in items:
				if item != "." and item != "..":
					has_files = true
					break
			if not has_files:
				if DEBUG_LOG: print("[GameSaveSubManager] Removing empty temp directory: " + parent)
				FSM.delete_dir_recursive(parent)
				parent = parent.get_base_dir()
			else:
				break
		else:
			break

## Resolves the default save directory for an emulator from the registry config.
## This is the "fallback" path based purely on the emulator JSON configuration.
## Optional platform_slug for resolving platform-specific paths (e.g., RetroArch {core_name}, Dolphin ngc/wii)
func resolve_default_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	# Check core-specific config first (for RetroArch multi-core saves)
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	
	var directories = config.get("directories", {})
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return ""
	
	if dir.contains("{save_root}") or dir.contains("{system_root}"):
		return RSM.compose_template(dir, emulator_id, platform_slug, core_id).get("path", "")
	
	# Use the full emulator path resolver with all wildcards
	dir = FSM.resolve_emulator_path(dir, emulator_id, platform_slug)
	
	return dir.rstrip("/") + "/"

## Returns the saves config dict for an emulator/core/platform combination.
## Priority: core-specific > platform-specific > _default.
func _get_save_config(emulator_id: String, platform_slug: String, core_id: String) -> Dictionary:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return {}
	
	var paths = emulator.get("paths", {})
	var saves = paths.get("default_saves", {})
	
	# For RetroArch, check core-specific config first
	if emulator_id == "retroarch" and core_id != "":
		var core_config = LaunchManager.registry.get_core_config(emulator_id, platform_slug, core_id)
		var core_paths = core_config.get("paths", {})
		var core_saves = core_paths.get("default_saves", {})
		if not core_saves.is_empty():
			return core_saves
	
	if platform_slug != "" and saves.has(platform_slug):
		return saves[platform_slug]
	
	return saves.get("_default", {})

## Resolves all candidate save directories for an emulator.
## On desktop this returns a single path. On Android it returns both the
## {app_data} path and the {emulator_dir} path so we can check which one
## is actively being used.
func resolve_save_directories(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	var candidates: Array[String] = []
	
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return candidates
	
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	
	var directories = config.get("directories", {})
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")

	if dir == "":
		# The registry declares no save dir for this platform; the emulator's
		# own config may still state one (config-first). Without this probe a
		# missing JSON entry silently disables sync even when the config
		# resolver could produce the path.
		var resolution: Dictionary = RSM.resolve_save_dir(emulator_id, platform_slug, core_id)
		if resolution.get("path", "") != "":
			candidates.append(resolution.path)
		return candidates

	if dir.contains("{save_root}") or dir.contains("{system_root}"):
		# Root-anchored template: the resolver composes the complete directory
		# config-first.
		var composed: Dictionary = RSM.compose_template(dir, emulator_id, platform_slug, core_id)
		if composed.get("path", "") != "":
			candidates.append(composed.path)
	else:
		# Config-first: what the machine's own config states is authoritative;
		# the JSON default only applies when the config said nothing.
		var resolution: Dictionary = RSM.resolve_save_dir(emulator_id, platform_slug, core_id)
		if resolution.get("source", "") == "config" and resolution.get("path", "") != "":
			candidates.append(resolution.path)
		
		if candidates.is_empty():
			var default_path = FSM.resolve_emulator_path(dir, emulator_id, platform_slug)
			candidates.append(default_path.rstrip("/") + "/")
	
	# On Android, always generate both {app_data} and {emulator_dir} variants
	# so the active-directory picker can choose whichever one has saves.
	if SystemManager.platform.is_android():
		var emu_base := FSM.resolve_emulator_path("{emulator_dir}", emulator_id, platform_slug).rstrip("/")
		var app_base := FSM.resolve_emulator_path("{app_data}", emulator_id, platform_slug).rstrip("/")
		if emu_base != "" and app_base != "" and emu_base != app_base:
			for existing in candidates.duplicate():
				var variant := ""
				if existing.begins_with(emu_base):
					variant = app_base + existing.substr(emu_base.length())
				elif existing.begins_with(app_base):
					variant = emu_base + existing.substr(app_base.length())
				if variant != "" and not variant in candidates:
					candidates.append(variant)

	# 3DS console-identity completion: save templates carry all-zeros id0/id1
	# dirs; substitute the real pair the SD card tree shows (never invented).
	if platform_slug == "3ds":
		for i in range(candidates.size()):
			candidates[i] = _complete_3ds_identity(candidates[i])

	return candidates

## Resolves the actively-used save directory for an emulator.
## Checks all candidate directories and picks the one with the most recent
## modification time. Falls back to the default (app_data on Android) if
## none exist or have recent activity.
func resolve_active_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	var candidates = resolve_save_directories(emulator_id, platform_slug, core_id)
	if candidates.is_empty():
		return ""
	
	var best_dir = ""
	var best_mtime = 0
	
	for candidate in candidates:
		if FSM.dir_exists(candidate):
			var mtime = FSM.get_modified_time(candidate)
			if mtime > best_mtime:
				best_dir = candidate
				best_mtime = mtime
	
	# If no candidate exists yet, fall back to the default (first candidate)
	if best_dir == "":
		best_dir = candidates[0]

	return best_dir

## Opens the folder containing the game's save data in the OS file manager.
## Prefers the exact folder holding the game's save file(s); falls back to the
## emulator's save root when nothing has been written yet. Desktop only.
func open_save_location(game: GameResource) -> void:
	if game == null:
		return
	var emulator_id: String = LaunchManager.resolve_emulator_for_game(game)
	if emulator_id == "":
		SystemManager.notifications.show_notification("No emulator configured for " + game.get_display_name(), SystemManager.notifications.Type.WARNING)
		return
	var core_id: String = _get_core_id_for_save_resolution(emulator_id, game)
	var save_dir := resolve_active_save_directory(emulator_id, game.platform_slug, core_id)
	if save_dir == "":
		SystemManager.notifications.show_notification("No save location known for " + game.get_display_name(), SystemManager.notifications.Type.WARNING)
		return

	var is_folder_save := uses_folder_saves(emulator_id, game.platform_slug, core_id)
	var extensions := get_save_extensions(emulator_id, game.platform_slug, core_id)
	var scan_work := func() -> Array[Dictionary]:
		if is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc"):
			return _discover_emulator_saves(emulator_id, save_dir, game)
		return _discover_game_saves(save_dir, game, extensions)
	_run_io_task(save_dir, scan_work, func(found: Array[Dictionary]):
		# Most precise target: the folder actually holding a save file. The
		# emulator root is the fallback when the game has not saved yet.
		var target_dir := save_dir
		if not found.is_empty():
			target_dir = found[0].file_path.get_base_dir()
		if not FSM.dir_exists(target_dir):
			SystemManager.notifications.show_notification("No save folder yet for " + game.get_display_name() + " - it appears after the first save", SystemManager.notifications.Type.INFO)
			return
		var result := OS.shell_open(FSM.resolve_path(target_dir, {"format": FSM.PathFormat.ABSOLUTE}))
		if result != OK:
			SystemManager.notifications.show_notification("Could not open save folder for " + game.get_display_name(), SystemManager.notifications.Type.ERROR)
	)

## Backward-compatible alias that returns the default save directory.
## Install-time and directory-creation code should use this.
func resolve_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return resolve_default_save_directory(emulator_id, platform_slug, core_id)

## Ensures the save directory for an emulator exists, creating it if necessary
## Returns true if directory exists or was created successfully
func _ensure_save_directory_exists(emulator_id: String, save_dir: String = "") -> bool:
	if save_dir == "":
		save_dir = resolve_active_save_directory(emulator_id)
	if save_dir == "":
		print("[GameSaveSubManager] No save directory configured for: " + emulator_id)
		return false
	
	if FSM.dir_exists(save_dir):
		return true
	
	print("[GameSaveSubManager] Creating save directory for " + emulator_id + ": " + save_dir)
	var success = FSM.make_dir_recursive(save_dir)
	if not success:
		push_error("[GameSaveSubManager] Failed to create save directory for " + emulator_id + ": " + save_dir)
		return false
	
	print("[GameSaveSubManager] Successfully created save directory for " + emulator_id)
	return true

## Gets the save file extensions for an emulator
func get_save_extensions(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	var extensions = config.get("extensions", [])
	var result: Array[String] = []
	for ext in extensions:
		if ext is String:
			result.append(ext)
	return result

## Discovers local save files for a game in the given directory
## Searches recursively for files matching: {rom_name_no_ext}{extension}
## Returns array of dictionaries: [{file_name, file_path, modified_time, extension}, ...]
func discover_local_saves(directory: String, rom_name_no_ext: String, extensions: Array[String]) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or extensions.is_empty():
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	_search_directory_for_saves(directory, rom_name_no_ext, extensions, results)
	return results

func _search_directory_for_saves(dir_path: String, rom_name_no_ext: String, extensions: Array[String], results: Array[Dictionary]) -> void:
	var items = FSM.list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var full_path = dir_path + item
		if FSM.dir_exists(full_path):
			_search_directory_for_saves(full_path + "/", rom_name_no_ext, extensions, results)
		elif FSM.file_exists(full_path):
			var item_no_ext = item.get_basename()
			var item_ext = item.get_extension()
			if item_no_ext == rom_name_no_ext:
				var dot_ext = "." + item_ext
				if dot_ext in extensions:
					var modified_time = FSM.get_modified_time(full_path)
					results.append({
						"file_name": item,
						"file_path": full_path,
						"modified_time": modified_time,
						"extension": dot_ext
					})

## Returns the base name emulators use for this game's save files. Multi-disc
## games launched via an m3u playlist produce saves named after the playlist
## (RetroArch names saves after the loaded content, not individual discs).
func _get_save_base_name(game: GameResource) -> String:
	if game.m3u_path != "":
		return game.m3u_path.get_file().get_basename()
	return game.get_active_file_name().get_basename()

## Returns the normalized slot string used by RomM save records.
func _remote_save_slot(remote: Dictionary) -> String:
	var slot = remote.get("slot", "")
	return SLOT_DEFAULT if slot == null else str(slot)


## Normalizes local save paths before using them as grouping keys. Directory
## save roots sometimes differ only by a trailing slash.
func _normalized_save_path(path: String) -> String:
	var normalized := FSM.normalize_path(path)
	if normalized.length() > 1:
		normalized = normalized.rstrip("/")
	return normalized


## Collapses duplicate save_sync rows that point at the same physical file or
## folder. Filename aliases (notably pre-m3u disc saves) must not keep separate
## baselines for one local path, or one alias can overwrite the other and the
## later hash change is misread as gameplay.
func _dedupe_save_sync_records(game: GameResource, emulator_id: String, db_records: Array[Dictionary], remote_saves: Array) -> Array[Dictionary]:
	var live_remote_ids := {}
	for remote in remote_saves:
		if remote is Dictionary and _remote_save_slot(remote) == SLOT_DEFAULT:
			live_remote_ids[int(remote.get("id", 0))] = true

	var records_by_path := {}
	var records_without_path: Array[Dictionary] = []
	for rec in db_records:
		var slot = rec.get("slot", SLOT_DEFAULT)
		if slot == null:
			slot = SLOT_DEFAULT
		# Slots are independent save namespaces; never collapse across them.
		if str(slot) != SLOT_DEFAULT:
			records_without_path.append(rec)
			continue
		var path := _normalized_save_path(str(rec.get("file_path", "")))
		if path == "":
			records_without_path.append(rec)
			continue
		if not records_by_path.has(path):
			records_by_path[path] = []
		records_by_path[path].append(rec)

	var survivors: Array[Dictionary] = records_without_path.duplicate()
	for path_key in records_by_path.keys():
		var path := str(path_key)
		var group: Array = records_by_path[path_key]
		if group.size() == 1:
			survivors.append(group[0])
			continue

		var path_name := path.get_file()
		var best: Dictionary = {}
		var best_score := -1
		var best_time := -1
		for rec in group:
			var file_name := str(rec.get("file_name", ""))
			var score := 0
			# The natural record names the file/folder it points at. For folder
			# saves uploaded as Name.zip, compare the basename too.
			if file_name == path_name or file_name.get_basename() == path_name:
				score += 100
			# Prefer a record whose remote save still exists.
			if live_remote_ids.has(int(rec.get("remote_save_id", 0))):
				score += 50
			if str(rec.get("local_hash", "")) != "" and rec.get("local_hash", "") == rec.get("server_hash", ""):
				score += 10
			var rec_time := parse_iso_timestamp(str(rec.get("last_synced_at", "")))
			if score > best_score or (score == best_score and rec_time > best_time):
				best = rec
				best_score = score
				best_time = rec_time

		if best.is_empty():
			best = group[0]
		survivors.append(best)

		for rec in group:
			if int(rec.get("id", 0)) == int(best.get("id", 0)):
				continue
			var removed: bool = DataManager.delete_save_sync_record(game.romm_id, emulator_id, str(rec.get("file_name", "")), SLOT_DEFAULT)
			var status := "removed" if removed else "failed to remove"
			push_warning("[GameSaveSubManager] " + status + " duplicate save_sync record '" + str(rec.get("file_name", "")) + "' (remote id " + str(rec.get("remote_save_id", 0)) + ") sharing local path '" + path + "' with '" + str(best.get("file_name", "")) + "'")

	return survivors


## Resolves where a remote save would land locally. This must mirror
## _execute_save_download(); RetroArch and folder-save emulators derive the
## destination from the game, so differently named remote saves can alias to
## the same local path.
func _resolve_remote_save_destination(game: GameResource, emulator_id: String, save_dir: String, remote: Dictionary, local_by_name: Dictionary, is_folder_save: bool) -> String:
	var file_name := str(remote.get("file_name", "save"))
	var local = local_by_name.get(file_name)
	if local != null:
		return str(local.get("file_path", ""))

	if emulator_id == "retroarch" or is_folder_save:
		var record_path := _resolve_emulator_save_path(emulator_id, save_dir, game)
		if record_path == "" and is_folder_save:
			var result := _resolve_default_save_path(save_dir, game.get_active_title_id())
			if result.error == "":
				record_path = result.path
		return record_path

	return FSM.join_paths(save_dir, file_name)


## Chooses the one remote record allowed to write to a destination. Exact
## filename matches win; folder-save zips can match their folder basename;
## otherwise the newest server head is the least surprising choice.
func _preferred_remote_for_path(candidates: Array, path: String) -> Dictionary:
	var path_name := path.get_file()
	for remote in candidates:
		if str(remote.get("file_name", "")) == path_name:
			return remote
	for remote in candidates:
		if str(remote.get("file_name", "")).get_basename() == path_name:
			return remote

	var newest: Dictionary = {}
	var newest_time := -1
	for remote in candidates:
		var updated := parse_iso_timestamp(str(remote.get("updated_at", "")))
		if newest.is_empty() or updated > newest_time:
			newest = remote
			newest_time = updated
	return newest


## Filters remote saves so no sync pass can write two remote filenames to one
## local path. If a path is already occupied, only the remote carrying the
## occupant's exact filename may sync; aliases are skipped instead of
## overwriting the local save before the emulator starts.
func _filter_remote_saves_by_destination(game: GameResource, emulator_id: String, local_saves: Array, remote_saves: Array, save_dir: String, is_folder_save: bool) -> Array:
	var local_by_name := {}
	var local_by_path := {}
	for local in local_saves:
		local_by_name[str(local.get("file_name", ""))] = local
		var local_path := _normalized_save_path(str(local.get("file_path", "")))
		if local_path != "":
			local_by_path[local_path] = local

	var remote_by_path := {}
	var filtered: Array = []
	for remote in remote_saves:
		if not (remote is Dictionary):
			continue
		if _remote_save_slot(remote) != SLOT_DEFAULT:
			filtered.append(remote)
			continue
		var destination := _resolve_remote_save_destination(game, emulator_id, save_dir, remote, local_by_name, is_folder_save)
		if destination == "":
			# Preserve the existing error path for unresolvable destinations.
			filtered.append(remote)
			continue
		var key := _normalized_save_path(destination)
		if not remote_by_path.has(key):
			remote_by_path[key] = []
		remote_by_path[key].append(remote)

	for path in remote_by_path.keys():
		var candidates: Array = remote_by_path[path]
		var local = local_by_path.get(path)
		if local != null:
			var exact: Dictionary = {}
			for remote in candidates:
				if str(remote.get("file_name", "")) == str(local.get("file_name", "")):
					exact = remote
					break
			if not exact.is_empty():
				filtered.append(exact)
				for remote in candidates:
					if int(remote.get("id", 0)) == int(exact.get("id", 0)):
						continue
					push_warning("[GameSaveSubManager] Skipping remote save alias '" + str(remote.get("file_name", "")) + "' (id " + str(remote.get("id", 0)) + "); it resolves to '" + path + "', which belongs to local save '" + str(local.get("file_name", "")) + "'")
			else:
				for remote in candidates:
					push_warning("[GameSaveSubManager] Refusing to download remote save '" + str(remote.get("file_name", "")) + "' (id " + str(remote.get("id", 0)) + ") over existing local save '" + str(local.get("file_name", "")) + "' at '" + path + "'")
			continue

		var winner := _preferred_remote_for_path(candidates, path)
		if winner.is_empty():
			continue
		filtered.append(winner)
		for remote in candidates:
			if int(remote.get("id", 0)) == int(winner.get("id", 0)):
				continue
			push_warning("[GameSaveSubManager] Skipping remote save '" + str(remote.get("file_name", "")) + "' (id " + str(remote.get("id", 0)) + "); '" + str(winner.get("file_name", "")) + "' (id " + str(winner.get("id", 0)) + ") owns destination '" + path + "'")

	return filtered


## Discovers local saves for a game, migrating pre-m3u disc-named saves to the
## m3u base name so the emulator keeps reading them and sync matching works.
func _discover_game_saves(save_dir: String, game: GameResource, extensions: Array[String]) -> Array[Dictionary]:
	var results := discover_local_saves(save_dir, _get_save_base_name(game), extensions)
	if results.is_empty():
		results = _migrate_legacy_disc_saves(save_dir, game, extensions)
	return results

## Renames saves named after any folded ROM/disc variant (written before the
## m3u existed) to the m3u base name. Returns the migrated save entries.
func _migrate_legacy_disc_saves(save_dir: String, game: GameResource, extensions: Array[String]) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if game.m3u_path == "":
		return results

	var new_base := _get_save_base_name(game)
	var legacy_bases: Array[String] = []
	var add_legacy_base := func(file_name: String) -> void:
		var base := file_name.get_basename()
		if base != "" and base != new_base and not legacy_bases.has(base):
			legacy_bases.append(base)

	# Prefer the variant that would have been launched before considering the
	# rest of the folded sibling set.
	add_legacy_base.call(game.get_active_file_name())
	add_legacy_base.call(game.file_name)
	for sibling in game.siblings:
		if sibling is Dictionary:
			add_legacy_base.call(str(sibling.get("file_name", "")))

	for extension in extensions:
		var candidates: Array[Dictionary] = []
		for legacy_base in legacy_bases:
			candidates.append_array(discover_local_saves(save_dir, legacy_base, [extension]))
		# If more than one pre-m3u save exists, the most recently written card
		# is the safest migration candidate. The first successful move claims
		# the canonical m3u path; the others remain untouched.
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("modified_time", 0)) > int(b.get("modified_time", 0))
		)
		for save in candidates:
			var new_path: String = save["file_path"].get_base_dir() + "/" + new_base + "." + save["file_path"].get_extension()
			if FSM.file_exists(new_path):
				continue
			if FSM.move(save["file_path"], new_path):
				print("[GameSaveSubManager] Migrated legacy disc save: " + save["file_path"] + " -> " + new_path)
				results.append({
					"file_name": new_path.get_file(),
					"file_path": new_path,
					"modified_time": save["modified_time"],
					"extension": save["extension"]
				})
	return results

func uses_folder_saves(emulator_id: String, platform_slug: String = "", core_id: String = "") -> bool:
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	return config.get("uses_folder_saves", false)

func discover_local_folder_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	var category = title_id.substr(0, 8)
	var short_title_id = title_id.substr(8, 8)
	
	var id0_dirs = FSM.list_dir(directory)
	for id0 in id0_dirs:
		if id0 == "." or id0 == ".." or not FSM.dir_exists(FSM.join_paths(directory, id0)):
			continue
		var id0_path = FSM.join_paths(directory, id0)
		var id1_dirs = FSM.list_dir(id0_path)
		for id1 in id1_dirs:
			if id1 == "." or id1 == ".." or not FSM.dir_exists(FSM.join_paths(id0_path, id1)):
				continue
			var title_path = FSM.join_paths(id0_path, id1, "title", category, short_title_id)
			if FSM.dir_exists(title_path):
				var mtime = _get_folder_mtime(title_path)
				results.append({
					"file_name": short_title_id + ".zip",
					"file_path": title_path,
					"modified_time": mtime,
					"extension": ".zip"
				})
				return results
	
	return results

func discover_local_cemu_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or (title_id.length() != 16 and title_id.length() != 8):
		return results

	if not FSM.dir_exists(directory):
		return results

	var short_title_id = _short_title_id(title_id)
	var save_path = FSM.join_paths(directory, short_title_id)
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": short_title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	return results

func discover_local_dolphin_gc_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results

	game_id = _gc_ascii_id(game_id)

	# directory is the GC base; saves live under <region>/Card <slot>
	var gci_files := _find_gc_gci_files(directory, game_id)
	
	if gci_files.is_empty():
		return results
	
	# Create a temp zip bundle with all matching GCI files
	var zip_path = "user://temp/saves/" + game_id + ".zip"
	FSM.make_dir_recursive(zip_path.get_base_dir())
	
	var zip_success = _zip_gci_files(gci_files, zip_path)
	if not zip_success:
		push_error("[GameSaveSubManager] Failed to create GCI bundle for " + game_id)
		return results
	
	var mtime = _get_folder_mtime(directory)
	results.append({
		"file_name": game_id + ".zip",
		"file_path": zip_path,
		"modified_time": mtime,
		"extension": ".zip"
	})
	
	return results

## Creates a zip archive containing specific GCI files
## Used for bundling multiple GameCube saves for the same game
func _zip_gci_files(gci_files: Array[String], zip_path: String) -> bool:
	# The bundle path is stable per game; delete first so a partial zip from
	# a failed pass can't leak duplicate entries into the retry.
	if FSM.file_exists(zip_path):
		FSM.delete_file(zip_path)
	var writer = ZIPPacker.new()
	var err = writer.open(zip_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		push_error("[GameSaveSubManager] Failed to create GCI zip: " + zip_path)
		return false
	
	for gci_path in gci_files:
		var file_name = gci_path.get_file()
		var data = FSM.read_file_bytes(gci_path)
		if data.size() > 0:
			writer.start_file(file_name)
			writer.write_file(data)
			writer.close_file()
	
	writer.close()
	return true

func _game_id_to_hex(game_id: String) -> String:
	var hex = ""
	for c in game_id:
		hex += "%02x" % c.unicode_at(0)
	return hex

## Returns the last-8 short form of a 16-char title ID; passes through IDs
## that are already short (sigil emits wiiu IDs in short form).
func _short_title_id(title_id: String) -> String:
	return title_id.substr(8, 8) if title_id.length() == 16 else title_id

## Returns the Dolphin NAND hex form of a Wii/GC game ID. Legacy stored IDs
## are 4-char ASCII (converted); sigil-stored IDs are already 8-char hex;
## full 16-char title IDs (wii, incl. WAD) reduce to their 8-char code half.
func _wii_hex_id(game_id: String) -> String:
	if game_id.length() == 16 and game_id.is_valid_hex_number(false):
		return game_id.substr(8, 8)
	if game_id.length() == 8 and game_id.is_valid_hex_number(false):
		return game_id
	return _game_id_to_hex(game_id)

## Returns the 4-char ASCII form of a GC/Wii game ID (GCI naming form).
func _gc_ascii_id(game_id: String) -> String:
	if game_id.length() == 16 and game_id.is_valid_hex_number(false):
		game_id = game_id.substr(8, 8)
	if game_id.length() == 8 and game_id.is_valid_hex_number(false):
		var bytes := PackedByteArray()
		for i in range(0, 8, 2):
			bytes.append(game_id.substr(i, 2).hex_to_int())
		return bytes.get_string_from_ascii()
	return game_id

## Maps a GC game id's region character to Dolphin's modern GC region dir
## (argosy convention: last char of the 4-char ASCII game code; Korean
## GameCube maps to JPN per Dolphin's ToGameCubeRegion).
func _gc_region_dir(game_id: String) -> String:
	var ascii_id := _gc_ascii_id(game_id)
	if ascii_id == "":
		return "USA"
	match ascii_id[ascii_id.length() - 1]:
		"P":
			return "EUR"
		"J", "K":
			return "JPN"
		_:
			return "USA"

## Region dirs scanned when collecting GCI saves: modern Dolphin dirs plus
## the legacy JAP/KOR spellings older builds and argosy wrote.
const GC_SCAN_REGIONS := ["USA", "EUR", "JPN", "JAP", "KOR"]

## Collects .gci files matching a game id under a Dolphin GC base dir:
## every known region dir and any "Card *" slot inside it (plus loose files
## in the region dir), then the base dir itself as a flat fallback.
func _find_gc_gci_files(base_dir: String, game_id: String) -> Array[String]:
	var results: Array[String] = []
	if base_dir == "" or game_id == "" or not FSM.dir_exists(base_dir):
		return results
	var needle := game_id.to_lower()
	for region in GC_SCAN_REGIONS:
		var region_path := FSM.join_paths(base_dir, region)
		if not FSM.dir_exists(region_path):
			continue
		_collect_gci_matches(region_path, needle, results)
		for item in FSM.list_dir(region_path):
			if item == "." or item == "..":
				continue
			var item_path := FSM.join_paths(region_path, item)
			if FSM.dir_exists(item_path) and item.to_lower().begins_with("card"):
				_collect_gci_matches(item_path, needle, results)
	if results.is_empty():
		_collect_gci_matches(base_dir, needle, results)
	return results

func _collect_gci_matches(dir_path: String, needle: String, results: Array[String]) -> void:
	for item in FSM.list_dir(dir_path):
		if item == "." or item == "..":
			continue
		var full := FSM.join_paths(dir_path, item)
		if not FSM.dir_exists(full) and item.to_lower().ends_with(".gci") and needle in item.to_lower():
			results.append(full)

## Returns the Dolphin NAND title root for a Wii game: save_dir is the
## 00010000 root; WiiWare/VC titles live in the 00010001/00010004 siblings.
## An existing on-disk folder wins, then the 16-char title id's category,
## else 00010000.
func _wii_title_root(save_dir: String, game: GameResource) -> String:
	var base := save_dir.rstrip("/")
	var parent := base.get_base_dir()
	var hex_id := _wii_hex_id(_get_save_identity(game).id)
	if hex_id != "":
		if FSM.dir_exists(FSM.join_paths(base, hex_id)):
			return base
		for category in WII_WARE_CATEGORIES:
			var ware: String = parent + "/" + category
			if FSM.dir_exists(FSM.join_paths(ware, hex_id)):
				return ware
	var tid := game.get_active_title_id()
	if tid.length() == 16:
		return parent + "/" + tid.substr(0, 8)
	return base

## Returns the on-disk save identity for a game: {"id": ..., "usage": ...}.
## Prefers the sigil-persisted save_id/save_usage; falls back to deriving
## from title_id for records extracted before save_id persistence existed.
## For folder-split platforms (3DS) the id is a "/"-separated nested path.
func _get_save_identity(game: GameResource) -> Dictionary:
	var save_id = game.get_active_save_id()
	if save_id != "":
		return {"id": save_id, "usage": game.get_active_save_usage()}
	var title_id = game.get_active_title_id()
	match game.platform_slug:
		"wii":
			return {"id": _wii_hex_id(title_id), "usage": "folder-exact"}
		"ngc":
			return {"id": _gc_ascii_id(title_id), "usage": "file-prefix"}
		"wiiu":
			return {"id": _short_title_id(title_id), "usage": "folder-exact"}
		"3ds":
			if title_id.length() == 16:
				return {"id": title_id.substr(0, 8) + "/" + title_id.substr(8, 8), "usage": "folder-split"}
			return {"id": title_id, "usage": "folder-split"}
		_:
			return {"id": title_id, "usage": ""}

## Computes the RomM-parity content hash + logical size for a local save
## record. Folder saves hash as the zip _zip_emulator_save would produce
## (per-emulator root naming); file saves hash the file directly.
## Returns {"hash": String, "size": int}; hash is "" when uncomputable.
func _compute_local_save_hash(emulator_id: String, game: GameResource, local_save: Dictionary) -> Dictionary:
	var path: String = local_save.get("file_path", "")
	if path == "":
		return {"hash": "", "size": 0}
	if _is_3ds_tree_path(path):
		return _compute_3ds_unit_hash(path)
	var architecture: String = LaunchManager.registry.get_emulator_architecture(emulator_id)
	if architecture == "dolphin" and game.platform_slug == "ngc" and FSM.dir_exists(path):
		return _compute_dolphin_gc_hash(game, path)
	var layout := SaveLayout.policy(architecture, game.platform_slug)
	if str(layout.get("zip_root_mode", "")) == SaveLayout.ZIP_ROOT_COMPONENTS:
		var components := _get_save_components(emulator_id, game, path)
		if not components.is_empty():
			var total := 0
			for component in components:
				total += _folder_content_size(str(component["src"]))
			return {"hash": _ContentHash.compute_components_zip_hash(components), "size": total}
	if FSM.dir_exists(path):
		var root_name = _get_upload_zip_root_name(emulator_id, game, path)
		return {"hash": _ContentHash.compute_folder_zip_hash(path, root_name), "size": _folder_content_size(path)}
	if FSM.file_exists(path):
		return {"hash": _ContentHash.compute_content_hash(path), "size": int(FSM.get_file_size(path))}
	return {"hash": "", "size": 0}

## Root folder name used by the emulator's upload zip. The layout policy is
## authoritative for both archive construction and RomM hash simulation.
func _get_upload_zip_root_name(emulator_id: String, game: GameResource, src_path: String) -> String:
	var layout := SaveLayout.policy(LaunchManager.registry.get_emulator_architecture(emulator_id), game.platform_slug)
	match str(layout.get("zip_root_mode", "")):
		SaveLayout.ZIP_ROOT_SAVE_ID:
			return _get_save_identity(game).id
		SaveLayout.ZIP_ROOT_SOURCE_BASENAME:
			return src_path.rstrip("/").get_file()
		_:
			return ""

## Components for multi-root upload/hash layouts. 3DS has its own unit helper;
## PSP bundles every local save folder matching the title prefix.
func _get_save_components(emulator_id: String, game: GameResource, local_path: String) -> Array:
	var architecture: String = LaunchManager.registry.get_emulator_architecture(emulator_id)
	var is_psp: bool = architecture == "ppsspp" or (architecture == "retroarch" and game.platform_slug == "psp")
	if not is_psp:
		return []
	var title_id := str(_get_save_identity(game).id)
	var savedata_dir := local_path.rstrip("/").rstrip("\\")
	if savedata_dir.get_file().to_upper().contains(title_id.to_upper()):
		savedata_dir = savedata_dir.get_base_dir()
	var components: Array = []
	for save in discover_local_psp_save(savedata_dir, title_id):
		components.append({"src": save.file_path, "root": save.file_path.get_file()})
	return components

## Native Dolphin GC discovery/upload bundles only this game's GCI files, not
## every save on the shared card. Reproduce that exact bundle for boundaries.
func _compute_dolphin_gc_hash(game: GameResource, card_path: String) -> Dictionary:
	var gc_base := card_path.get_base_dir().get_base_dir()
	var game_id := _gc_ascii_id(str(_get_save_identity(game).id))
	var gci_files := _find_gc_gci_files(gc_base, game_id)
	if gci_files.is_empty():
		return {"hash": "", "size": 0}
	var bundle := "user://temp/saves/hash_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000) + ".zip"
	if not _zip_gci_files(gci_files, bundle):
		return {"hash": "", "size": 0}
	var result := {
		"hash": _ContentHash.compute_content_hash(bundle),
		"size": int(FSM.get_file_size(bundle)),
	}
	FSM.delete_file(bundle)
	_cleanup_temp_dir(bundle)
	return result

func _folder_content_size(dir_path: String) -> int:
	var total = 0
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var filename = dir.get_next()
	while filename != "":
		if filename != "." and filename != "..":
			var full_path = dir_path + "/" + filename
			if dir.current_is_dir():
				total += _folder_content_size(full_path)
			else:
				total += int(FSM.get_file_size(full_path))
		filename = dir.get_next()
	dir.list_dir_end()
	return total

## Builds the gavel bookkeeping record from a save_sync DB row.
func _gavel_files_state(db_rec) -> Dictionary:
	var files_state := {}
	if db_rec == null:
		return files_state
	if db_rec.get("local_hash", "") != "":
		files_state["last_sync_hash"] = db_rec.local_hash
	if db_rec.get("server_hash", "") != "":
		files_state["last_sync_server_hash"] = db_rec.server_hash
	if int(db_rec.get("local_size", 0)) > 0:
		files_state["last_sync_local_size"] = int(db_rec.local_size)
	return files_state

## Runs the gavel decision for one (game, file_name) pair.
## local_save: discovery record or null. remote: server save dict or null.
func _gavel_decide(emulator_id: String, game: GameResource, local_save, remote, db_rec, device_id: String) -> Dictionary:
	var hash_info := {"hash": "", "size": 0}
	var local_file = null
	if local_save != null:
		# Reuse the hash the discovery task computed (pre-launch scan hashes
		# inside the I/O task now); only hash here when the record lacks one.
		hash_info = local_save.get("_hash_info", {})
		if hash_info.get("hash", "") == "":
			hash_info = _compute_local_save_hash(emulator_id, game, local_save)
		local_file = {"filename": local_save.file_name, "size": hash_info.size, "mtime": local_save.get("modified_time", 0)}
	var server_saves: Array = [remote] if remote != null else []
	var decision = Gavel.compute_sync_action(local_file, server_saves, _gavel_files_state(db_rec), device_id, hash_info.hash if hash_info.hash != "" else null)
	return {"decision": decision, "hash_info": hash_info}

## Slot-wide parity check: finds a remote save whose server-stamped
## content_hash equals the local hash, regardless of file_name. Catches
## saves uploaded under artifact-suffixed names by other/older clients
## (e.g. BASLUS-20152AC04.zip vs BASLUS-20152.zip) so identical content is
## never re-uploaded as a duplicate record.
func _find_slot_parity_remote(remotes: Array, local_hash: String) -> Dictionary:
	if local_hash == "":
		return {}
	for remote in remotes:
		var ch = remote.get("content_hash", "")
		if ch != null and ch != "" and ch == local_hash:
			return remote
	return {}

func discover_local_dolphin_wii_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results

	if not FSM.dir_exists(directory):
		return results

	var hex_id = _wii_hex_id(game_id)
	for root in _wii_title_root_candidates(directory):
		var game_path = FSM.join_paths(root, hex_id)
		if FSM.dir_exists(game_path):
			var mtime = _get_folder_mtime(game_path)
			results.append({
				"file_name": hex_id + ".zip",
				"file_path": game_path,
				"modified_time": mtime,
				"extension": ".zip"
			})
			return results

	return results

## WiiWare/VC title categories: 00010004 is the common one, early titles
## (and VC arcade) use 00010001.
const WII_WARE_CATEGORIES := ["00010001", "00010004"]

## The title roots a Wii save may live under: the given 00010000 root plus
## the WiiWare/VC category siblings when the layout is a Dolphin NAND tree.
func _wii_title_root_candidates(directory: String) -> Array[String]:
	var roots: Array[String] = [directory]
	var parent := directory.rstrip("/").get_base_dir()
	if parent.get_file() == "title":
		for category in WII_WARE_CATEGORIES:
			roots.append(parent + "/" + category)
	return roots

const SWITCH_ZERO_USER := "0000000000000000"
const SWITCH_ZERO_PROFILE := "00000000000000000000000000000000"

## Switch titles that save to the console rather than a profile (ported from
## argosy's SwitchSaveHandler.DEVICE_SAVE_TITLE_IDS): they live under the
## zero user/profile regardless of the active profile, in both directions.
const EDEN_DEVICE_SAVE_TITLE_IDS := [
	"01006F8002326000", # Animal Crossing: New Horizons
	"0100D2F00D5C0000", # Nintendo Switch Sports
	"01000320000CC000", # 1-2-Switch
	"01002FF008C24000", # Ring Fit Adventure
	"0100C4B0034B2000", # Nintendo Labo Toy-Con 01: Variety Kit
	"01009AB0034E0000", # Nintendo Labo Toy-Con 02: Robot Kit
	"01001E9003502000", # Nintendo Labo Toy-Con 03: Vehicle Kit
	"0100165003504000", # Nintendo Labo Toy-Con 04: VR Kit
	"0100C1800A9B6000", # Go Vacation
]

func _eden_is_device_save(title_id: String) -> bool:
	return title_id.to_upper() in EDEN_DEVICE_SAVE_TITLE_IDS

func _is_hex_folder_name(folder_name: String) -> bool:
	for i in range(folder_name.length()):
		var c := folder_name.unicode_at(i)
		var is_hex := (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
		if not is_hex:
			return false
	return true

func _is_valid_switch_user_folder(folder_name: String) -> bool:
	if folder_name.length() != 16:
		return false
	return _is_hex_folder_name(folder_name)

func _is_valid_switch_profile_folder(folder_name: String) -> bool:
	if folder_name.length() != 16 and folder_name.length() != 32:
		return false
	return _is_hex_folder_name(folder_name)

## NAND root above a resolved save root ("<...>/user/save" -> "<...>").
## "" when the root is not a NAND save dir (unexpected layout).
func _eden_nand_root(save_root: String) -> String:
	var root := save_root.rstrip("/")
	if root.ends_with("/user/save"):
		return root.substr(0, root.length() - "/user/save".length())
	return ""

func _eden_profiles_dat_path(save_root: String) -> String:
	var nand := _eden_nand_root(save_root)
	if nand == "":
		return ""
	return nand + "/system/save/8000000000000010/su/avators/profiles.dat"

## UUID at offset 0x10, 16 bytes; full byte reversal == argosy's
## little-endian uint64 pair formatting.
func _eden_parse_profile_uuid(data: PackedByteArray) -> String:
	var uuid_bytes := data.slice(0x10, 0x20)
	var profile_id := ""
	for i in range(16):
		profile_id += "%02X" % uuid_bytes[15 - i]
	return profile_id

## The active profile folder for a save root: the profiles.dat selection,
## then the newest-mtime non-zero profile folder on disk, then the first
## non-zero one, then the zero profile (the default for profile-less users
## and pre-first-run restores). Read fresh on every call: profiles.dat
## changes when the user switches profiles.
## Returns {profile_path, profile_id, source}.
func _eden_active_profile(save_root: String) -> Dictionary:
	var root := save_root.rstrip("/")

	var result := {}
	var profiles_path := _eden_profiles_dat_path(root)
	if profiles_path != "" and FSM.file_exists(profiles_path):
		var data: PackedByteArray = FSM.read_file_bytes(profiles_path)
		if data.size() >= 0x20:
			var profile_id := _eden_parse_profile_uuid(data)
			var profile_path := FSM.join_paths(root, SWITCH_ZERO_USER, profile_id)
			if profile_id != "" and FSM.dir_exists(profile_path):
				result = {"profile_path": profile_path, "profile_id": profile_id, "source": "profiles.dat"}
			else:
				if DEBUG_LOG: print("[GameSaveSubManager] _eden_active_profile: parsed profile missing on disk: " + profile_path)
		else:
			if DEBUG_LOG: print("[GameSaveSubManager] _eden_active_profile: profiles.dat too small (" + str(data.size()) + " bytes)")

	if result.is_empty():
		result = _eden_scan_active_profile(root)

	if DEBUG_LOG: print("[GameSaveSubManager] _eden_active_profile: " + result.profile_path + " (source=" + result.source + ")")
	return result

## Fallback when profiles.dat is absent/stale: newest-mtime non-zero profile
## folder across all user folders, then first non-zero, then zero profile.
func _eden_scan_active_profile(save_root: String) -> Dictionary:
	var best_path := ""
	var best_time := 0
	var first_non_zero := ""
	for user_name in FSM.list_dir(save_root):
		if user_name == "." or user_name == ".." or not _is_valid_switch_user_folder(user_name):
			continue
		var user_path := FSM.join_paths(save_root, user_name)
		if not FSM.dir_exists(user_path):
			continue
		for profile_name in FSM.list_dir(user_path):
			if profile_name == "." or profile_name == ".." or not _is_valid_switch_profile_folder(profile_name):
				continue
			if profile_name.count("0") == profile_name.length():
				continue
			var profile_path := FSM.join_paths(user_path, profile_name)
			if not FSM.dir_exists(profile_path):
				continue
			if first_non_zero == "":
				first_non_zero = profile_path
			var mtime := _get_folder_mtime(profile_path)
			if mtime > best_time:
				best_time = mtime
				best_path = profile_path

	if best_path != "":
		return {"profile_path": best_path, "profile_id": best_path.get_file(), "source": "scan"}
	if first_non_zero != "":
		return {"profile_path": first_non_zero, "profile_id": first_non_zero.get_file(), "source": "scan"}
	return {
		"profile_path": FSM.join_paths(save_root, SWITCH_ZERO_USER, SWITCH_ZERO_PROFILE),
		"profile_id": SWITCH_ZERO_PROFILE,
		"source": "fallback",
	}

## Best-mtime title folder across all user/profile folders, or "" — catches
## saves stranded in a non-active profile (profile switch, legacy placement).
func _eden_find_title_in_profiles(save_root: String, title_id: String) -> String:
	var best_path := ""
	var best_time := 0
	for user_name in FSM.list_dir(save_root):
		if user_name == "." or user_name == ".." or not _is_valid_switch_user_folder(user_name):
			continue
		var user_path := FSM.join_paths(save_root, user_name)
		if not FSM.dir_exists(user_path):
			continue
		for profile_name in FSM.list_dir(user_path):
			if profile_name == "." or profile_name == ".." or not _is_valid_switch_profile_folder(profile_name):
				continue
			var profile_path := FSM.join_paths(user_path, profile_name)
			if not FSM.dir_exists(profile_path):
				continue
			for child in FSM.list_dir(profile_path):
				if child.to_upper() != title_id.to_upper():
					continue
				var title_path := FSM.join_paths(profile_path, child)
				if not FSM.dir_exists(title_path) or not _dir_contains_files(title_path):
					continue
				var mtime := _get_folder_mtime(title_path)
				if mtime > best_time:
					best_time = mtime
					best_path = title_path
	return best_path

## True if the directory contains at least one file (recursive, any size).
## Exists-but-empty dirs are not saves: eden creates the title dir under the
## active profile on launch while real saves may still sit under the zero
## profile (the launch-twice profile setup). Treating the empty dir as
## "found" strands those saves and hashes/uploads nothing.
func _dir_contains_files(dir_path: String) -> bool:
	if not FSM.dir_exists(dir_path):
		return false
	for item in FSM.list_dir(dir_path):
		if item == "." or item == "..":
			continue
		var full_path := FSM.join_paths(dir_path, item)
		if FSM.dir_exists(full_path):
			if _dir_contains_files(full_path):
				return true
		else:
			return true
	return false

## Restore/upload target for a title under a resolved save root. Device saves
## always land at zero/zero; everything else under the active profile.
func _eden_save_target(save_root: String, title_id: String) -> String:
	var root := save_root.rstrip("/")
	if _eden_is_device_save(title_id):
		return FSM.join_paths(root, SWITCH_ZERO_USER, SWITCH_ZERO_PROFILE, title_id.to_upper())
	var profile: Dictionary = _eden_active_profile(root)
	return FSM.join_paths(profile.profile_path, title_id.to_upper())

## Eden save structure: {save_root}/{user}/{profile}/{title_id}/
func discover_local_eden_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results

	if not FSM.dir_exists(directory):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: dir does not exist: " + directory)
		return results

	var candidates: Array[String] = []
	if _eden_is_device_save(title_id):
		candidates.append(FSM.join_paths(directory, SWITCH_ZERO_USER, SWITCH_ZERO_PROFILE, title_id.to_upper()))
	else:
		var profile: Dictionary = _eden_active_profile(directory)
		candidates.append(FSM.join_paths(profile.profile_path, title_id.to_upper()))

	for candidate in candidates:
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: checking " + candidate)
		if FSM.dir_exists(candidate):
			if _dir_contains_files(candidate):
				results.append({
					"file_name": title_id + ".zip",
					"file_path": candidate,
					"modified_time": _get_folder_mtime(candidate),
					"extension": ".zip"
				})
				return results
			# Exists-but-empty is not a save: eden creates the title dir under
			# the active profile on launch while real saves may still sit under
			# the zero profile. Fall through to the cross-profile scan.
			if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: candidate exists but is empty, scanning profiles: " + candidate)

	var scanned := _eden_find_title_in_profiles(directory, title_id)
	if scanned != "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: found via profile scan: " + scanned)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": scanned,
			"modified_time": _get_folder_mtime(scanned),
			"extension": ".zip"
		})
		return results

	if not _eden_is_device_save(title_id):
		var zero_path := FSM.join_paths(directory, SWITCH_ZERO_USER, SWITCH_ZERO_PROFILE, title_id.to_upper())
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: checking fallback " + zero_path)
		if FSM.dir_exists(zero_path) and _dir_contains_files(zero_path):
			results.append({
				"file_name": title_id + ".zip",
				"file_path": zero_path,
				"modified_time": _get_folder_mtime(zero_path),
				"extension": ".zip"
			})
			return results

	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_eden_save: no save found")
	return results

## Generalized fuzzy folder save discovery
## Searches for folders whose names contain the given search_id
## Options: recursive_search (bool), return_all_matches (bool)
## Returns array of save dictionaries
func discover_local_fuzzy_folder_save(directory: String, search_id: String, recursive_search: bool = false, return_all_matches: bool = true) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or search_id == "":
		return results
	
	# Handle both hyphenated and non-hyphenated versions
	var id_with_hyphen = search_id.to_upper()
	var id_no_hyphen = search_id.replace("-", "").to_upper()
	
	var best_path = ""
	var best_mtime = 0
	
	var dirs_to_check: Array[String] = [directory]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		if not FSM.dir_exists(current):
			continue
		
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = FSM.join_paths(current, item)
			
			if FSM.dir_exists(full_path):
				var folder_name = item.to_upper()
				var folder_name_no_hyphen = folder_name.replace("-", "")
				
				# Match if folder contains the search_id anywhere in the name
				var is_match = folder_name.find(id_with_hyphen) != -1 or folder_name_no_hyphen.find(id_no_hyphen) != -1
				
				if is_match:
					var mtime = _get_folder_mtime(full_path)
					if return_all_matches:
						results.append({
							"file_name": item + ".zip",
							"file_path": full_path,
							"modified_time": mtime,
							"extension": ".zip"
						})
					else:
						# Only keep the most recent
						if mtime > best_mtime:
							best_mtime = mtime
							best_path = full_path
				elif recursive_search:
					# Continue searching deeper
					dirs_to_check.append(full_path)
	
	if not return_all_matches and best_path != "":
		var folder_name = best_path.get_file()
		results.append({
			"file_name": folder_name + ".zip",
			"file_path": best_path,
			"modified_time": best_mtime,
			"extension": ".zip"
		})
	
	return results

func discover_local_pcsx2_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_pcsx2_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_pcsx2_save: searching for serial " + title_id + " in " + directory)
	var results = discover_local_fuzzy_folder_save(directory, title_id, true, false)
	
	if results.is_empty():
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_pcsx2_save: no saves found for serial " + title_id)
	else:
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_pcsx2_save: returning save at " + results[0].file_path)
	
	return results

## Discovers local PPSSPP saves for a PSP game
## Returns an array of save dictionaries, one per matching folder
## PSP games can have multiple save folders (e.g., ULUS10509DAT, ULUS10509DLC)
func discover_local_psp_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_psp_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	# PPSSPP save path already includes SAVEDATA in the path
	# e.g., {emulator_dir}/memstick/PSP/SAVEDATA
	var savedata_dir = directory.rstrip("/") + "/"
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_psp_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_psp_save: SAVEDATA dir doesn't exist yet")
		return []
	
	var results = discover_local_fuzzy_folder_save(savedata_dir, title_id, false, true)
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_psp_save: found " + str(results.size()) + " matching save folders")
	
	return results

## Discovers local Vita3K saves for a PSVita game
## Vita3K saves are folders directly in savedata/ named by TitleID (e.g., PCSA00152)
func discover_local_vita3k_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_vita3k_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_vita3k_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_vita3k_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_vita3k_save: found save at " + save_path)
	else:
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_vita3k_save: no save found for " + title_id)
	
	return results

## Discovers local RPCS3 saves for a PS3 game
## RPCS3 saves are folders in dev_hdd0/home/00000001/savedata/ whose names are the
## TitleID plus a game-chosen suffix (e.g., BLUS30721-BCSAVEDATA) - sigil classifies
## this as folder-prefix, so fuzzy-match on the TitleID like PSP.
func discover_local_rpcs3_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_rpcs3_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	var savedata_dir = directory.rstrip("/") + "/"
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_rpcs3_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_rpcs3_save: savedata dir doesn't exist yet")
		return []
	
	var results = discover_local_fuzzy_folder_save(savedata_dir, title_id, false, true)
	
	if results.is_empty():
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_rpcs3_save: no save found for " + title_id)
	else:
		for save in results:
			if DEBUG_LOG: print("[GameSaveSubManager] discover_local_rpcs3_save: found save at " + save.file_path)
	
	return results

## Discovers local shadPS4 saves for a PS4 game
## shadPS4 saves are folders in user/savedata/ named by TitleID (e.g., CUSA01130)
func discover_local_shadps4_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_shadps4_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_shadps4_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_shadps4_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_shadps4_save: found save at " + save_path)
	else:
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_shadps4_save: no save found for " + title_id)
	
	return results

## Xenia saves live in content/PROFILE_ID/TITLE_ID. The adjacent config TOML's
## [Profiles] logged_profile_slot_0_xuid selects the active profile; custom
## content_root installs fall back to _xenia_active_profile's folder heuristics.
const XENIA_CONFIG_FILENAMES := ["xenia-edge.config.toml", "xenia.config.toml", "xenia-canary.config.toml"]

func _xenia_logged_profile_xuid(content_dir: String) -> String:
	var storage := content_dir.rstrip("/").get_base_dir()
	# Read fresh on every call: the emulator rewrites the config on exit and
	# fresh installs regenerate the profile XUID.
	var xuid := ""
	for filename in XENIA_CONFIG_FILENAMES:
		var config_path := FSM.join_paths(storage, filename)
		if not FSM.file_exists(config_path):
			continue
		var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.TOML)
		if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
			continue
		xuid = str(parsed.sections.get("Profiles", {}).get("logged_profile_slot_0_xuid", "")).strip_edges()
		if xuid != "":
			if DEBUG_LOG: print("[GameSaveSubManager] _xenia_logged_profile_xuid: " + xuid + " from " + config_path)
			break
	return xuid

## The profile folder xenia writes this title's saves under. Returns
## {profile_id, source}. Ordering: the config-declared slot-0 XUID when its
## folder exists (or no profile folders exist yet — pre-first-run), then the
## profile holding FFFE07D1 account data (the live signed-in profile), then
## the profile already containing the title, then the only/newest profile,
## then the zero profile. Slot 0 only; multi-slot and manual selection are
## user-resolution-layer work.
func _xenia_active_profile(content_dir: String, title_id: String = "") -> Dictionary:
	var root := content_dir.rstrip("/")

	var profiles: Array[String] = []
	for item in FSM.list_dir(root):
		if item == "." or item == ".." or item.length() != 16 or not _is_hex_folder_name(item):
			continue
		if FSM.dir_exists(FSM.join_paths(root, item)):
			profiles.append(item)

	var xuid := _xenia_logged_profile_xuid(root)
	if xuid.length() == 16 and _is_hex_folder_name(xuid):
		xuid = xuid.to_upper()
		if profiles.has(xuid) or profiles.is_empty():
			return {"profile_id": xuid, "source": "config"}

	for profile in profiles:
		if FSM.dir_exists(FSM.join_paths(root, profile, "FFFE07D1")):
			return {"profile_id": profile, "source": "account-data"}
	if title_id != "":
		for profile in profiles:
			if FSM.dir_exists(FSM.join_paths(root, profile, title_id.to_upper())):
				return {"profile_id": profile, "source": "title-folder"}
	if profiles.size() == 1:
		return {"profile_id": profiles[0], "source": "single-profile"}
	var best := ""
	var best_time := 0
	for profile in profiles:
		var mtime := _get_folder_mtime(FSM.join_paths(root, profile))
		if mtime > best_time:
			best_time = mtime
			best = profile
	if best != "":
		return {"profile_id": best, "source": "newest-mtime"}
	return {"profile_id": "0000000000000000", "source": "fallback"}

## Moves this title's save out of a stale profile folder into the active
## profile (fresh installs regenerate the profile XUID, stranding old
## saves). Only fires when the active profile lacks the title; when both
## have it the active profile wins and the stale copy is left untouched.
func _xenia_rehome_to_active_profile(save_dir: String, title_id: String) -> void:
	if title_id == "":
		return
	var root := save_dir.rstrip("/")
	if not FSM.dir_exists(root):
		return
	var active: String = _xenia_active_profile(root, title_id).profile_id
	var active_title := FSM.join_paths(root, active, title_id.to_upper())
	if FSM.dir_exists(active_title):
		return
	for item in FSM.list_dir(root):
		if item == "." or item == ".." or item == active:
			continue
		if item.length() != 16 or not _is_hex_folder_name(item):
			continue
		var stale_title := FSM.join_paths(root, item, title_id.to_upper())
		if not FSM.dir_exists(stale_title):
			continue
		if FSM.move(stale_title, active_title):
			if DEBUG_LOG: print("[GameSaveSubManager] xenia rehome: moved " + stale_title + " -> " + active_title)
		else:
			push_warning("[GameSaveSubManager] xenia rehome: failed to move " + stale_title)
		return

func discover_local_xenia_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var content_dir = directory.rstrip("/") + "/"
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: searching in " + content_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(content_dir):
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: content dir doesn't exist yet")
		return results

	# The active profile's copy wins when duplicates exist across profiles.
	var active_profile: String = _xenia_active_profile(content_dir, title_id).profile_id
	var active_path := FSM.join_paths(content_dir, active_profile, title_id.to_upper())
	if FSM.dir_exists(active_path):
		results.append({
			"file_name": title_id.to_upper() + ".zip",
			"file_path": active_path,
			"modified_time": _get_folder_mtime(active_path),
			"extension": ".zip"
		})
		if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: found save at " + active_path + " (active profile)")
		return results

	# Search recursively through all profile subdirectories
	var dirs_to_check: Array[String] = [content_dir]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = current.rstrip("/") + "/" + item
			if FSM.dir_exists(full_path):
				# Check if this directory matches our Title ID
				if item.to_upper() == title_id.to_upper():
					var mtime = _get_folder_mtime(full_path)
					results.append({
						"file_name": title_id.to_upper() + ".zip",
						"file_path": full_path,
						"modified_time": mtime,
						"extension": ".zip"
					})
					if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: found save at " + full_path)
					return results
				else:
					# Continue searching deeper (profile subdirectories)
					dirs_to_check.append(full_path)
	
	if DEBUG_LOG: print("[GameSaveSubManager] discover_local_xenia_save: no save found for " + title_id)
	return results

## Recursion depth cap for _get_folder_mtime. Real save trees are shallow
## (title/profile/savefile); the cap bounds pathological emulator content
## trees. Directory mtimes are included at every level, so file creation or
## deletion at the cap depth still moves the result.
const FOLDER_MTIME_MAX_DEPTH := 6

func _get_folder_mtime(dir_path: String) -> int:
	var latest = 0
	# (path, depth) pairs; depth 0 is the root dir.
	var dirs_to_check: Array = [[dir_path, 0]]
	while not dirs_to_check.is_empty():
		var entry = dirs_to_check.pop_back()
		var current: String = entry[0]
		var depth: int = entry[1]
		# A directory's own mtime moves when its direct children are added,
		# removed, or renamed — this keeps structural changes visible even at
		# the depth cap.
		var dir_mtime = FSM.get_modified_time(current)
		if dir_mtime > latest:
			latest = dir_mtime
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			var full = FSM.join_paths(current, item)
			if FSM.dir_exists(full):
				if depth < FOLDER_MTIME_MAX_DEPTH:
					dirs_to_check.append([full, depth + 1])
			elif FSM.file_exists(full):
				var mtime = FSM.get_modified_time(full)
				if mtime > latest:
					latest = mtime
	return latest

## Validates that a game's title ID is valid for the given emulator
## Returns empty string on success, error message on failure
func _validate_emulator_title_id(emulator_id: String, title_id: String) -> String:
	var strategy = _get_strategy(emulator_id, "validate")
	if strategy.is_valid():
		return strategy.call(title_id)
	# Default validation
	if title_id.length() != 16:
		return "Invalid Title ID for this game."
	return ""

## Discovers local saves for a specific emulator and game
## Returns an array of save dictionaries

## Helper to determine the relevant core_id when resolving save paths for a game.
func _get_core_id_for_save_resolution(emulator_id: String, game: GameResource) -> String:
	if emulator_id != "retroarch":
		return ""
	return LaunchManager.resolve_core_for_game(game)
func _discover_emulator_saves(emulator_id: String, save_dir: String, game: GameResource) -> Array[Dictionary]:
	var strategy = _get_strategy(emulator_id, "discover")
	if strategy.is_valid():
		return strategy.call(save_dir, game)
	# Default: folder saves
	return discover_local_folder_save(save_dir, game.get_active_title_id())

## Resolves the save path for the default emulator folder structure
## Returns a dictionary with "path" and "error" keys
func _resolve_default_save_path(save_dir: String, title_id: String) -> Dictionary:
	var short_title_id = _short_title_id(title_id)
	var id0 = _find_first_subdir(save_dir)
	if id0 == "":
		return {"path": "", "error": "no_id0"}
	var id1 = _find_first_subdir(FSM.join_paths(save_dir, id0))
	if id1 == "":
		return {"path": "", "error": "no_id1"}
	var category = title_id.substr(0, 8)
	return {
		"path": FSM.join_paths(save_dir, id0, id1, "title", category, short_title_id),
		"error": ""
	}

## Resolves the save path for a specific emulator and game
## Returns the resolved path string (empty string on failure)
func _resolve_emulator_save_path(emulator_id: String, save_dir: String, game: GameResource) -> String:
	var strategy = _get_strategy(emulator_id, "resolve_path")
	if strategy.is_valid():
		return strategy.call(save_dir, game)
	# Default: use standard folder save path resolution
	var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
	return result.path

## Resolves the save path for RetroArch with core-specific subdirectories
## Returns the full file path (for .srm-style saves) or folder path (for folder saves)
func _resolve_retroarch_save_path(save_dir: String, game: GameResource) -> String:
	var platform_slug = game.platform_slug
	var title_id = game.get_active_title_id()
	
	match platform_slug:
		"psp":
			if title_id == "":
				return ""
			return FSM.join_paths(save_dir, title_id)
		"ps2":
			if FSM.file_exists(save_dir):
				return save_dir
			if title_id == "":
				return ""
			return FSM.join_paths(save_dir, title_id)
		"ngc":
			var ascii_id := _gc_ascii_id(title_id)
			if ascii_id == "":
				return ""
			return FSM.join_paths(save_dir, _gc_region_dir(ascii_id), "Card A")
		"wii":
			if title_id == "":
				return ""
			return FSM.join_paths(_wii_title_root(save_dir, game), _wii_hex_id(title_id))
		"3ds":
			if title_id.length() != 16:
				return ""
			# save_dir is the console-identity root (<id1>); the per-title
			# unit hangs under title/<category>/<low>.
			return FSM.join_paths(save_dir, "title", title_id.substr(0, 8), title_id.substr(8, 8))
		_:
			# save_dir is already the complete per-core directory (the resolver
			# composes root + sorted subdir); only the file name is appended.
			var rom_name_no_ext = _get_save_base_name(game)
			return FSM.join_paths(save_dir, rom_name_no_ext + ".srm")

## Discovers local saves for a RetroArch core, dispatching by platform.
func _discover_retroarch_save(dir: String, game: GameResource) -> Array[Dictionary]:
	var platform_slug = game.platform_slug
	var title_id = game.get_active_title_id()
	
	match platform_slug:
		"psp":
			return discover_local_psp_save(dir, title_id)
		"ps2":
			if FSM.file_exists(dir):
				return _discover_single_file_save(dir)
			return discover_local_pcsx2_save(dir, title_id)
		"ngc":
			return _discover_retroarch_ngc_save(dir, title_id)
		"wii":
			return _discover_retroarch_wii_save(dir, title_id)
		"3ds":
			# dir is the console-identity root (<id1>); citra cores share the
			# azahar two-tree unit layout.
			return _discover_3ds_unit(dir, game)
		_:
			var core_id = LaunchManager.resolve_core_for_game(game)
			var extensions = get_save_extensions("retroarch", platform_slug, core_id)
			return _discover_game_saves(dir, game, extensions)

## Discovers GameCube saves for the RetroArch Dolphin core.
## directory is the GC base; the matched region/Card folder is returned as a
## single folder save (its GCI files are bundled on upload).
func _discover_retroarch_ngc_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results

	if not FSM.dir_exists(directory):
		return results

	var ascii_id := _gc_ascii_id(game_id)
	var gci_files := _find_gc_gci_files(directory, ascii_id)
	if gci_files.is_empty():
		return results

	# Prefer the game's own region/Card A folder when matches span slots.
	var folder := gci_files[0].get_base_dir()
	var preferred := FSM.join_paths(directory, _gc_region_dir(ascii_id), "Card A").to_lower()
	for gci in gci_files:
		if gci.get_base_dir().to_lower() == preferred:
			folder = gci.get_base_dir()
			break

	results.append({
		"file_name": game_id + ".zip",
		"file_path": folder,
		"modified_time": _get_folder_mtime(folder),
		"extension": ".zip"
	})
	return results

## Discovers Wii saves for the RetroArch Dolphin core.
func _discover_retroarch_wii_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results

	if not FSM.dir_exists(directory):
		return results

	var hex_id = _wii_hex_id(game_id)
	for root in _wii_title_root_candidates(directory):
		var game_path = FSM.join_paths(root, hex_id)
		if FSM.dir_exists(game_path):
			var mtime = _get_folder_mtime(game_path)
			results.append({
				"file_name": hex_id + ".zip",
				"file_path": game_path,
				"modified_time": mtime,
				"extension": ".zip"
			})
			return results

	return results

## Helper for RetroArch PS2 when the configured save path is a single memcard file.
func _discover_single_file_save(file_path: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if not FSM.file_exists(file_path):
		return results
	var mtime = FSM.get_modified_time(file_path)
	results.append({
		"file_name": file_path.get_file(),
		"file_path": file_path,
		"modified_time": mtime,
		"extension": "." + file_path.get_extension()
	})
	return results

## Determines the extraction destination for downloaded RetroArch saves.
func _get_retroarch_extract_dest(save_dir: String, record_path: String, game: GameResource) -> String:
	match game.platform_slug:
		"psp":
			return save_dir
		"ps2":
			if FSM.file_exists(save_dir):
				return save_dir.get_base_dir()
			return save_dir
		"ngc", "wii", "3ds":
			# record_path IS the per-game/card dir; the zips kyodai produces
			# hold bare contents (no wrapping folder), so extract into it.
			return record_path
		_:
			return record_path.get_base_dir()

## Determines the save name for RetroArch upload based on the local file/folder.
func _get_retroarch_save_name(game: GameResource, local_file_path: String) -> String:
	if local_file_path != "":
		return local_file_path.get_file()
	return _get_save_base_name(game) + ".srm"

## Creates a ZIP archive for a RetroArch save, dispatching by platform.
func _zip_retroarch_save(src: String, dst: String, game: GameResource) -> bool:
	if game.platform_slug == "psp":
		return _zip_psp_save(src, _get_save_identity(game).id, dst, MAX_FILE_SIZE)
	if game.platform_slug == "3ds":
		return _zip_3ds_save(src, dst, game)
	return FSM.zip_directory(src, dst, -1, _get_upload_zip_root_name("retroarch", game, src))

## Determines the extraction destination for downloaded saves based on emulator
## Returns the destination directory path
func _get_extract_dest(emulator_id: String, save_dir: String, record_path: String, game: GameResource, zip_file_name: String = "") -> String:
	var strategy = _get_strategy(emulator_id, "extract_dest")
	if strategy.is_valid():
		return strategy.call(save_dir, record_path, game, zip_file_name)
	# Default: extract to the parent directory of the record path
	return record_path.get_base_dir()

## Resolves the static save-layout policy into concrete paths for one download.
## This is the single source for archive shape, owned commit root, upload root,
## post-restore destination, and sync-boundary selection.
func _get_save_layout(emulator_id: String, save_dir: String, record_path: String, game: GameResource, zip_file_name: String = "") -> Dictionary:
	var architecture: String = LaunchManager.registry.get_emulator_architecture(emulator_id)
	var layout := SaveLayout.policy(architecture, game.platform_slug)
	var extract_dest := _get_extract_dest(emulator_id, save_dir, record_path, game, zip_file_name)
	var archive_root := zip_file_name.get_basename() if zip_file_name != "" else record_path.get_file()
	if architecture == "rpcs3":
		# RPCS3 save folders are TitleID-prefixed, often with game-specific
		# suffixes. The remote ZIP basename is not the internal directory name.
		archive_root = game.get_active_title_id()
		layout["root_prefix"] = true
	layout["extract_dest"] = extract_dest
	layout["archive_root"] = archive_root
	match str(layout["kind"]):
		SaveLayout.BARE_CONTENTS:
			layout["commit_root"] = extract_dest
			layout["boundary_path"] = extract_dest
		SaveLayout.NAMED_ROOT:
			layout["commit_root"] = FSM.join_paths(extract_dest, archive_root)
			layout["boundary_path"] = layout["commit_root"]
		SaveLayout.MULTI_ROOT:
			layout["commit_root"] = extract_dest
			layout["boundary_path"] = record_path
			layout["archive_root"] = _get_save_identity(game).id
		_:
			layout["commit_root"] = record_path
			layout["boundary_path"] = record_path
	return layout

## Determines the save name for upload based on emulator and game
## Returns the save name string
func _get_save_name_for_upload(emulator_id: String, game: GameResource, local_file_path: String = "") -> String:
	var strategy = _get_strategy(emulator_id, "save_name")
	if strategy.is_valid():
		return strategy.call(game, local_file_path)
	# Default: use the short Title ID (last 8 characters of the 16-character Title ID)
	return _short_title_id(game.get_active_title_id())

## Creates a ZIP archive for a specific emulator's save
## Returns true on success. Universal guard: an archive with zero entries is
## never a valid upload - it would clobber a good remote save with nothing
## (seen with an exists-but-empty eden profile dir). Applies to every
## strategy and the default path.
func _zip_emulator_save(emulator_id: String, source_path: String, zip_path: String, game: GameResource) -> bool:
	var architecture: String = LaunchManager.registry.get_emulator_architecture(emulator_id)
	var needs_custom_packing: bool = architecture in ["azahar", "ppsspp"] or (architecture == "retroarch" and game.platform_slug in ["psp", "3ds"])
	var zip_ok := false
	if needs_custom_packing:
		var strategy = _get_strategy(emulator_id, "zip")
		if strategy.is_valid():
			zip_ok = strategy.call(source_path, zip_path, game)
	else:
		var root_name := _get_upload_zip_root_name(emulator_id, game, source_path)
		zip_ok = FSM.zip_directory(source_path, zip_path, -1, root_name)
	if zip_ok and not _zip_has_entries(zip_path):
		push_error("[GameSaveSubManager] Refusing empty save zip (no entries): %s (source: %s)" % [zip_path, source_path])
		FSM.delete_file(zip_path)
		return false
	return zip_ok

## True if the zip contains at least one non-directory entry.
func _zip_has_entries(zip_path: String) -> bool:
	var zr = ZIPReader.new()
	if zr.open(zip_path) != OK:
		return false
	for entry_name in zr.get_files():
		if not entry_name.ends_with("/"):
			zr.close()
			return true
	zr.close()
	return false

## Zips all PSP save folders matching the title_id into a single archive
## max_file_size: maximum file size in bytes to include (-1 for no limit)
## Returns true on success
func _zip_psp_save(source_path: String, title_id: String, zip_path: String, max_file_size: int = -1) -> bool:
	# Normalize source path - remove trailing slashes to ensure get_file() works correctly
	var normalized_path = source_path.rstrip("/").rstrip("\\")
	
	# Use timestamp + random to avoid stage dir collisions when called rapidly
	var stage_dir = "user://temp/saves/stage_" + str(Time.get_ticks_msec()) + "_" + str(randi()) + "/"
	
	# Determine if source_path is an individual save folder or the SAVEDATA directory
	# Individual save folders contain the title_id in their name (e.g., NPJH50333DAT)
	var folder_name = normalized_path.get_file().to_upper()
	var savedata_dir = normalized_path
	
	if folder_name != "" and folder_name.contains(title_id.to_upper()):
		# It's an individual save folder, use parent directory
		savedata_dir = normalized_path.get_base_dir()
	
	if DEBUG_LOG: print("[GameSaveSubManager] _zip_psp_save: normalized_path=" + normalized_path + ", folder_name=" + folder_name + ", savedata_dir=" + savedata_dir)
	
	var saves = discover_local_psp_save(savedata_dir, title_id)
	
	if saves.is_empty():
		if DEBUG_LOG: print("[GameSaveSubManager] _zip_psp_save: no saves found in " + savedata_dir)
		return false
	
	if DEBUG_LOG: print("[GameSaveSubManager] _zip_psp_save: found " + str(saves.size()) + " save(s) to zip")
	
	# Copy all matching save folders to staging directory
	for save in saves:
		var save_folder_name = save.file_path.get_file()
		var dest = FSM.join_paths(stage_dir, save_folder_name)
		if DEBUG_LOG: print("[GameSaveSubManager] _zip_psp_save: copying " + save.file_path + " to " + dest)
		var success = FSM.copy_dir(save.file_path, dest)
		if not success:
			push_error("[GameSaveSubManager] _zip_psp_save: failed to copy " + save.file_path)
			FSM.delete_dir_recursive(stage_dir)
			return false
	
	# Zip the staging directory
	if DEBUG_LOG: print("[GameSaveSubManager] _zip_psp_save: creating zip at " + zip_path)
	var zip_success = FSM.zip_directory(stage_dir, zip_path, max_file_size)
	if not zip_success:
		push_error("[GameSaveSubManager] _zip_psp_save: failed to create zip " + zip_path)
	
	FSM.delete_dir_recursive(stage_dir)
	return zip_success

func _find_first_subdir(dir_path: String) -> String:
	var items = FSM.list_dir(dir_path)
	for item in items:
		if item != "." and item != ".." and FSM.dir_exists(FSM.join_paths(dir_path, item)):
			return item
	return ""

## Substitutes the real 3DS console-identity dirs (<id0>/<id1>) for the
## all-zeros placeholders baked into save templates. The pair is discovered
## on disk, never constructed: a single candidate wins; when several exist
## the all-zeros placeholder yields to a real pair; anything still
## ambiguous keeps the template with a warning.
func _complete_3ds_identity(path: String) -> String:
	const MARKER := "Nintendo 3DS/"
	const ZEROS := "00000000000000000000000000000000"
	var idx := path.find(MARKER)
	if idx < 0:
		return path
	var base := path.substr(0, idx + MARKER.length())
	var rest := path.substr(idx + MARKER.length())
	var segs := rest.split("/", false)
	if segs.size() < 2 or not (_is_hex32(segs[0]) and _is_hex32(segs[1])):
		return path

	var id0 := _pick_identity_dir(base, ZEROS, path)
	if id0 == "":
		return path
	var id1 := _pick_identity_dir(base + id0 + "/", ZEROS, path)
	if id1 == "":
		return path

	var tail := rest.substr(segs[0].length() + 1 + segs[1].length())
	var completed := base + id0 + "/" + id1 + tail
	if completed != path:
		if DEBUG_LOG: print("[GameSaveSubManager] 3DS identity: " + id0 + "/" + id1 + " for " + base)
	return completed

## Picks the single identity dir under parent. "" when none exist or the
## choice stays ambiguous after preferring a real pair over the all-zeros
## placeholder.
func _pick_identity_dir(parent: String, zeros: String, context_path: String) -> String:
	var found: Array[String] = []
	for item in FSM.list_dir(parent):
		if item != "." and item != ".." and _is_hex32(item) and FSM.dir_exists(FSM.join_paths(parent, item)):
			found.append(item)
	if found.is_empty():
		return ""
	if found.size() > 1:
		var real: Array[String] = []
		for d in found:
			if d.to_lower() != zeros:
				real.append(d)
		if not real.is_empty():
			found = real
	if found.size() != 1:
		push_warning("[GameSaveSubManager] 3DS identity ambiguous under " + parent + "; keeping template path " + context_path)
		return ""
	return found[0]

func _is_hex32(value: String) -> bool:
	if value.length() != 32:
		return false
	for i in range(value.length()):
		var c := value.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
		if not ok:
			return false
	return true

## A 3DS save unit spans two SD-card trees: title data at
## <id1>/title/<category>/<low>/data and extdata at
## <id1>/extdata/00000000/<extid>. Both azahar and the RetroArch citra
## cores share this layout, so the unit helpers below are emulator-neutral.
## Archives are two-root zips (data/ + extdata/ at the root), matching
## argosy; legacy rootless kyodai archives (data/... at root) route through
## the same unpack as data-only units.

## True when a resolved path points at a per-title dir inside a 3DS title
## tree (<id1>/title/00040000/<low>). Retail saves always use 00040000.
func _is_3ds_tree_path(path: String) -> bool:
	return path.replace("\\", "/").to_lower().contains("/title/00040000/")

## Walks <id1>/title/<category>/<low> back up to the console-identity root.
func _3ds_id1_root(title_dir: String) -> String:
	return title_dir.rstrip("/").get_base_dir().get_base_dir().get_base_dir()

## extdata id = (title_low >> 8) as 8 lowercase hex (retail rule).
func _3ds_extdata_id(short_title_id: String) -> String:
	return "%08x" % (short_title_id.hex_to_int() >> 8)

func _3ds_extdata_dir(title_dir: String) -> String:
	return FSM.join_paths(_3ds_id1_root(title_dir), "extdata", "00000000", _3ds_extdata_id(title_dir.rstrip("/").get_file()))

## Builds the unit's component list from a title dir: data + extdata roots,
## skipping components that do not exist on disk.
func _3ds_unit_components(title_dir: String) -> Array:
	title_dir = title_dir.rstrip("/")
	var components: Array = []
	if FSM.dir_exists(title_dir + "/data"):
		components.append({"src": title_dir + "/data", "root": "data"})
	var extdata_dir := _3ds_extdata_dir(title_dir)
	if FSM.dir_exists(extdata_dir):
		components.append({"src": extdata_dir, "root": "extdata"})
	return components

## Discovers a 3DS save unit under a console-identity root (<id1>). The
## save exists when EITHER component exists (extdata-only titles are real).
func _discover_3ds_unit(dir: String, game: GameResource) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var title_id = game.get_active_title_id()
	if dir == "" or title_id.length() != 16:
		return results
	var category := title_id.substr(0, 8)
	var short_title_id := title_id.substr(8, 8)
	var title_dir := FSM.join_paths(dir, "title", category, short_title_id)
	var extdata_dir := _3ds_extdata_dir(title_dir)
	var has_data := FSM.dir_exists(title_dir + "/data")
	var has_extdata := FSM.dir_exists(extdata_dir)
	if not has_data and not has_extdata:
		return results
	var mtime := 0
	if has_data:
		mtime = maxi(mtime, _get_folder_mtime(title_dir + "/data"))
	if has_extdata:
		mtime = maxi(mtime, _get_folder_mtime(extdata_dir))
	results.append({
		"file_name": short_title_id + ".zip",
		"file_path": title_dir,
		"modified_time": mtime,
		"extension": ".zip"
	})
	return results

## RomM-parity hash for a 3DS save unit: the zip the upload lambda would
## produce, simulated over both components. Identical to the legacy
## single-root hash when no extdata exists (old archives stay in sync).
func _compute_3ds_unit_hash(title_dir: String) -> Dictionary:
	var components := _3ds_unit_components(title_dir)
	if components.is_empty():
		return {"hash": "", "size": 0}
	var total := 0
	for comp in components:
		total += _folder_content_size(comp.src)
	return {"hash": _ContentHash.compute_components_zip_hash(components), "size": total}

## Zips a 3DS save unit as a two-root archive (data/ + extdata/).
func _zip_3ds_save(src: String, dst: String, _game: GameResource = null) -> bool:
	var components := _3ds_unit_components(src)
	if components.is_empty():
		push_error("[GameSaveSubManager] 3DS save unit has no data/extdata components: " + src)
		return false
	return FSM.zip_components(components, dst)

## Unpacks a 3DS save archive into the live tree. Entries route by first
## path segment: data/ -> <title>/data, extdata/ -> <id1>/extdata/00000000/
## <extid>. Only archive-present components are replaced; the other side of
## the unit is never touched. Unknown roots fail loudly (no silent merges).
## Directory entries are recreated too: games probe for empty dirs (e.g.
## MK7's replay_), and dropping them makes the save read as corrupt.
func _unpack_3ds_save(zip_path: String, record_path: String, operation_token: Dictionary = {}) -> bool:
	var title_dir := record_path.rstrip("/")
	return SaveLayout.unpack_3ds_archive(zip_path, title_dir + "/data", _3ds_extdata_dir(title_dir), FSM, operation_token)

func _ensure_device_registered(callback: Callable) -> void:
	var device_id = DataManager.get_romm_device_id()
	if device_id != "":
		callback.call(true, "")
		return
	
	var platform_name = OS.get_name().to_lower()
	var device_name = "Kyodai (" + platform_name.capitalize() + ")"
	SystemManager.network.register_device(device_name, platform_name, "kyodai", "1.0", func(data: Dictionary, error: String):
		if error != "":
			callback.call(false, "Device registration failed: " + error)
			return
		
		var new_device_id = data.get("device_id", "")
		if new_device_id == "":
			callback.call(false, "Device registration returned empty device_id")
			return
		
		DataManager.set_romm_device_id(new_device_id)
		print("[GameSaveSubManager] Registered device with RomM: " + new_device_id)
		callback.call(true, "")
	)

## Fetches remote saves with one recovery attempt for a stale device id.
## RomM 404s when the stored device_id no longer exists server-side (device
## deleted in RomM, server reset/upgrade); re-register and retry once.
## on_result(remote_saves: Array, error: String, device_id: String)
func _fetch_saves_with_device_retry(game: GameResource, on_result: Callable) -> void:
	var device_id = DataManager.get_romm_device_id()
	SystemManager.network.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, fetch_error: String):
		if fetch_error == "" or not "404" in fetch_error:
			on_result.call(remote_saves, fetch_error, device_id)
			return
		print("[GameSaveSubManager] fetch_saves 404 - device id stale, re-registering and retrying")
		DataManager.clear_romm_device_id()
		_ensure_device_registered(func(reg_ok: bool, _reg_error: String):
			if not reg_ok:
				on_result.call([], fetch_error, "")
				return
			var new_device_id = DataManager.get_romm_device_id()
			SystemManager.network.fetch_saves(game.romm_id, new_device_id, func(retry_saves: Array, retry_error: String):
				on_result.call(retry_saves, retry_error, new_device_id)
			)
		)
	)

## Shows the save conflict dialog and waits for user choice
## Returns: "local", "server", "cancel", or "" (on error)
func _show_conflict_dialog(game: GameResource, local_time: int, server_time: int) -> String:
	# Headless launches have no UI to ask with: resolve newest-wins (tie -> server)
	if HeadlessLaunchRunner.is_active():
		var headless_choice := "local" if local_time > server_time else "server"
		push_warning("[GameSaveSubManager] headless: save conflict for " + game.get_display_name() + " - auto-resolving newest-wins (" + headless_choice + ")")
		return headless_choice

	# Serialize conflict dialogs: a second flow waits for the first dialog to close
	while _conflict_dialog_open:
		await _conflict_dialog_closed
	_conflict_dialog_open = true

	var result := {
		"choice": "",
		"server_btn": null,
		"local_btn": null,
		"cancel_btn": null,
	}

	var on_server := func(): result["choice"] = "server"
	var on_local := func(): result["choice"] = "local"
	var on_cancel := func(): result["choice"] = "cancel"

	var dialog = UIManager.show_custom_dialog(func(conflict_dialog: M3Dialog):
		conflict_dialog.title_text = "Save Conflict"
		conflict_dialog.body_text = "Your local save data for %s conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten." % game.get_display_name()
		conflict_dialog.dismissible = false
		conflict_dialog.disable_default_action = true

		var content = VBoxContainer.new()
		content.alignment = BoxContainer.ALIGNMENT_BEGIN

		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, M3Units.dp(16))
		content.add_child(spacer)

		result["server_btn"] = M3Button.new()
		var dlg_server_btn: M3Button = result["server_btn"]
		dlg_server_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
		dlg_server_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		dlg_server_btn.button_size = M3Button.Size.LARGE
		dlg_server_btn.text = "Server Save\nModified: " + _format_conflict_timestamp(server_time)
		dlg_server_btn.pressed.connect(func():
			on_server.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_server_btn)

		result["local_btn"] = M3Button.new()
		var dlg_local_btn: M3Button = result["local_btn"]
		dlg_local_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
		dlg_local_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		dlg_local_btn.button_size = M3Button.Size.LARGE
		dlg_local_btn.text = "Local Save\nModified: " + _format_conflict_timestamp(local_time)
		dlg_local_btn.pressed.connect(func():
			on_local.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_local_btn)

		result["cancel_btn"] = M3Button.new()
		var dlg_cancel_btn: M3Button = result["cancel_btn"]
		dlg_cancel_btn.custom_minimum_size = Vector2(0, M3Units.dp(56))
		dlg_cancel_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		dlg_cancel_btn.button_size = M3Button.Size.MEDIUM
		dlg_cancel_btn.button_variant = M3Button.Variant.TEXT
		dlg_cancel_btn.text = "Cancel"
		dlg_cancel_btn.pressed.connect(func():
			on_cancel.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_cancel_btn)

		conflict_dialog.content_slot.add_child(content)
	, Callable(), {"overlay_layer": OverlayLayers.LAUNCH_CRITICAL})  # above UILayer so it stays visible and clickable over the launch transition overlay

	# Wait for the dialog to be laid out and then focus the first choice.
	await get_tree().process_frame
	var server_btn = result["server_btn"]
	var local_btn = result["local_btn"]
	var cancel_btn = result["cancel_btn"]
	if is_instance_valid(server_btn) and is_instance_valid(local_btn) and is_instance_valid(cancel_btn):
		server_btn.focus_neighbor_bottom = local_btn.get_path()
		local_btn.focus_neighbor_top = server_btn.get_path()
		local_btn.focus_neighbor_bottom = cancel_btn.get_path()
		cancel_btn.focus_neighbor_top = local_btn.get_path()
		server_btn.grab_focus()

	# Wait until the user picks one of the three choices.
	await dialog.dismissed

	_conflict_dialog_open = false
	_conflict_dialog_closed.emit()

	print("[GameSaveSubManager] Conflict dialog resolved with choice: " + result["choice"])
	return result["choice"]

func _short_hash(h) -> String:
	if h == null or str(h) == "":
		return "none"
	return str(h).substr(0, 8)

func _hash_detail(local_hash, remote_hash, last_sync_hash) -> String:
	return " [local=" + _short_hash(local_hash) + " remote=" + _short_hash(remote_hash) + " last_sync=" + _short_hash(last_sync_hash) + "]"

func _format_conflict_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "Unknown"

	var tz_info = Time.get_time_zone_from_system()
	var tz_offset_minutes = tz_info.get("bias", 0)
	var adjusted_unix = unix_time + (tz_offset_minutes * 60)
	var dict = Time.get_datetime_dict_from_unix_time(adjusted_unix)
	var month_names = ["January", "February", "March", "April", "May", "June",
					"July", "August", "September", "October", "November", "December"]

	var month = month_names[dict.month - 1]
	var day = dict.day
	var year = dict.year
	var hour = dict.hour
	var minute = dict.minute
	var ampm = "AM" if hour < 12 else "PM"

	if hour > 12:
		hour -= 12
	elif hour == 0:
		hour = 12

	return "%s %d, %d at %d:%02d %s" % [month, day, year, hour, minute, ampm]


## Returns "" when save sync may proceed, or the probe path that needs a
## document-tree grant first (no access route to the emulator's save dir on
## this device). Falls back to the emulator's app-data root when save_dir is
## empty: an unreadable config makes the resolver return "", but the tree is
## still restricted.
func _save_sync_grant_probe(emulator_id: String, save_dir: String) -> String:
	var probe_dir = save_dir
	if probe_dir == "":
		probe_dir = LaunchManager.get_app_data_path(emulator_id)
	if probe_dir == "":
		return ""
	if SystemManager.platform.access_route(probe_dir) != PlatformSubManager.AccessRoute.NONE:
		return ""
	return probe_dir


## Godot's HTTPRequest writes download_file via direct File I/O, which only
## works on DIRECT-route paths. SAF and ROOT routes must stage in user://temp
## and place the file via the plugin (a root daemon writes for us, but our
## own process cannot). Devices with direct file access keep the fast path.
func _must_stage_download(path: String) -> bool:
	return SystemManager.platform.access_route(path) != PlatformSubManager.AccessRoute.DIRECT


## Main sync entry point for manual and auto sync
func sync_saves_for_game(game: GameResource, emulator_id: String, callback: Callable = Callable()) -> void:
	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		SystemManager.notifications.show_notification("Save sync already in progress for " + game.get_display_name(), SystemManager.notifications.Type.WARNING)
		if callback.is_valid():
			callback.call(false, "Save sync already in progress")
		return

	# Android: emulator save dirs under /Android/data/ need a one-time folder
	# grant. Prompt just-in-time (before marking the sync in flight) and retry.
	var grant_probe = _save_sync_grant_probe(emulator_id, resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)))
	if grant_probe != "":
		SystemManager.platform.ensure_android_data_access(func(granted: bool):
			if granted:
				sync_saves_for_game(game, emulator_id, callback)
			elif callback.is_valid():
				callback.call(false, "Folder access required to sync saves from this emulator")
		, grant_probe)
		return

	_begin_save_sync(sync_key)
	var user_callback = callback
	callback = func(success: bool, message: String):
		_end_save_sync(sync_key)
		if user_callback.is_valid():
			user_callback.call(success, message)

	if not SystemManager.network.is_romm_connected():
		if callback.is_valid():
			callback.call(false, "Not connected to RomM")
		return
	
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	
	if save_dir == "" or extensions.is_empty():
		if callback.is_valid():
			callback.call(false, "No save configuration for emulator: " + emulator_id)
		return
	
	var is_folder_save_flow = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)) or (emulator_id == "dolphin" and game.platform_slug == "ngc")
	if is_folder_save_flow:
		if game.get_active_title_id() == "":
			if callback.is_valid():
				callback.call(false, "No Title ID available for this game. Launch it once to extract the Title ID.")
			return
		var validation_error = _validate_emulator_title_id(emulator_id, game.get_active_title_id())
		if validation_error != "":
			if callback.is_valid():
				callback.call(false, validation_error)
			return

	# Discovery walks the save directory tree and hashing reads every local
	# save; both run inside the I/O task (see auto_download_saves_for_game).
	var scan_work := func() -> Array[Dictionary]:
		var found: Array[Dictionary]
		if is_folder_save_flow:
			found = _discover_emulator_saves(emulator_id, save_dir, game)
		else:
			found = _discover_game_saves(save_dir, game, extensions)
		for save in found:
			save["_hash_info"] = _compute_local_save_hash(emulator_id, game, save)
		return found
	var scan_threaded := _should_thread_io(save_dir)
	_run_io_task(save_dir, scan_work, func(threaded_saves: Array[Dictionary]):
		# Manual sync can download remote-over-local; apply the same
		# empty-scan safeguard as the pre-launch flow.
		var local_saves: Array[Dictionary] = threaded_saves
		if local_saves.is_empty() and scan_threaded and _is_restricted_android_path(save_dir):
			var inline_saves: Array[Dictionary] = scan_work.call()
			if not inline_saves.is_empty():
				push_warning("[GameSaveSubManager] sync: threaded scan found 0 saves but inline re-scan found " + str(inline_saves.size()) + " in " + save_dir + " - using inline result")
				local_saves = inline_saves
		_ensure_device_registered(func(success: bool, error: String):
			if not success:
				if callback.is_valid():
					callback.call(false, error)
				return

			_fetch_saves_with_device_retry(game, func(remote_saves: Array, fetch_error: String, resolved_device_id: String):
				if fetch_error != "":
					if callback.is_valid():
						callback.call(false, "Failed to fetch remote saves: " + fetch_error)
					return

				_run_sync(game, emulator_id, local_saves, remote_saves, resolved_device_id, callback)
			)
		)
	)

func _run_sync(game: GameResource, emulator_id: String, local_saves: Array, remote_saves: Array, device_id: String, callback: Callable) -> void:
	var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
	db_records = _dedupe_save_sync_records(game, emulator_id, db_records, remote_saves)

	var core_id := _get_core_id_for_save_resolution(emulator_id, game)
	var save_dir := resolve_active_save_directory(emulator_id, game.platform_slug, core_id)
	var is_folder_save := uses_folder_saves(emulator_id, game.platform_slug, core_id)
	remote_saves = _filter_remote_saves_by_destination(game, emulator_id, local_saves, remote_saves, save_dir, is_folder_save)

	var local_by_name: Dictionary = {}
	for save in local_saves:
		local_by_name[save.file_name] = save

	var remote_by_name: Dictionary = {}
	for save in remote_saves:
		var slot = save.get("slot", "")
		if slot == null:
			slot = ""
		if slot == SLOT_DEFAULT:
			remote_by_name[save.file_name] = save

	var db_by_name: Dictionary = {}
	for rec in db_records:
		db_by_name[rec.file_name] = rec

	var pending_uploads: Array[Dictionary] = []
	var pending_downloads: Array[Dictionary] = []
	var sync_aborted = false

	# Detection via the gavel decision table (hash identity + bookkeeping),
	# falling back to its timestamp branch only when hashes prove nothing.
	for local in local_saves:
		var file_name = local.file_name
		var remote = remote_by_name.get(file_name)
		var db_rec = db_by_name.get(file_name)
		var local_mtime = local.modified_time

		var verdict = _gavel_decide(emulator_id, game, local, remote, db_rec, device_id)
		local["_hash_info"] = verdict.hash_info
		var action: String = verdict.decision.action
		if DEBUG_LOG: print("[GameSaveSubManager] sync: gavel verdict for '" + file_name + "': " + action + " (" + verdict.decision.get("reason", "") + ")" + _hash_detail(verdict.hash_info.hash, remote.get("content_hash", "") if remote else "", db_rec.get("local_hash", "") if db_rec else ""))

		# Slot-wide parity: identical content exists under a different server
		# file_name - adopt the baseline instead of POSTing a duplicate.
		if action == "upload" and remote == null:
			var parity = _find_slot_parity_remote(remote_by_name.values(), verdict.hash_info.hash)
			if not parity.is_empty():
				var ts = Time.get_datetime_string_from_system(true, true)
				DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, local.file_path, ts, parity.get("id", 0), SLOT_DEFAULT, verdict.hash_info.hash, parity.get("content_hash", ""), verdict.hash_info.size)
				continue

		match action:
			"upload":
				pending_uploads.append({"local": local, "remote": remote})
			"download":
				if remote:
					pending_downloads.append({"local": local, "remote": remote})
			"conflict":
				var remote_updated_unix = parse_iso_timestamp(remote.get("updated_at", "")) if remote else 0
				var choice = await _show_conflict_dialog(game, local_mtime, remote_updated_unix)
				match choice:
					"local":
						pending_uploads.append({"local": local, "remote": remote, "force": true})
					"server":
						if remote:
							pending_downloads.append({"local": local, "remote": remote})
					"cancel", "":
						sync_aborted = true
						break
			"skip":
				if verdict.decision.get("adopt_baseline", false) and remote:
					var ts = Time.get_datetime_string_from_system(true, true)
					DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, local.file_path, ts, remote.get("id", 0), SLOT_DEFAULT, verdict.hash_info.hash, remote.get("content_hash", ""), verdict.hash_info.size)

	if sync_aborted:
		save_sync_completed.emit(game, false, "Save sync cancelled by user")
		if callback.is_valid():
			callback.call(false, "Save sync cancelled by user")
		return

	for remote in remote_by_name.values():
		var file_name = remote.file_name
		if not local_by_name.has(file_name):
			var verdict = _gavel_decide(emulator_id, game, null, remote, db_by_name.get(file_name), device_id)
			if verdict.decision.action == "download":
				pending_downloads.append({"local": null, "remote": remote})
	
	var total_ops = pending_uploads.size() + pending_downloads.size()
	if total_ops == 0:
		if callback.is_valid():
			callback.call(true, "Saves are already in sync")
		return
	
	var state = {"completed": 0, "failed": 0}
	var current_timestamp = Time.get_datetime_string_from_system(true, true)

	var check_complete = func():
		state.completed += 1
		if state.completed >= total_ops:
			if state.failed > 0:
				save_sync_completed.emit(game, false, "%d/%d operations failed" % [state.failed, total_ops])
				if callback.is_valid():
					callback.call(false, "%d/%d operations failed" % [state.failed, total_ops])
			else:
				save_sync_completed.emit(game, true, "Save sync completed")
				if callback.is_valid():
					callback.call(true, "Save sync completed")

	for upload in pending_uploads:
		_execute_save_upload(game, emulator_id, upload, device_id, current_timestamp, upload.get("force", false), func(success: bool):
			if not success:
				state.failed += 1
			check_complete.call()
		)

	for download in pending_downloads:
		_execute_save_download(game, emulator_id, download.remote, download.local, device_id, current_timestamp, func(success: bool):
			if not success:
				state.failed += 1
			check_complete.call()
		)

## Records the gavel bookkeeping after a successful boundary only.
## remote_hash is stored verbatim (the server-stamped content_hash).
func _record_sync_boundary(game: GameResource, emulator_id: String, file_name: String, record_path: String, timestamp: String, remote_id: int, remote_hash: String) -> void:
	var hash_info := _compute_local_save_hash(emulator_id, game, {"file_path": record_path})
	DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, timestamp, remote_id, SLOT_DEFAULT, hash_info.hash, remote_hash, hash_info.size)

## Executes one upload operation. Automatic uploads always POST with
## overwrite=false; force=true only when the user chose keep-local on a
## surfaced conflict. A 409 re-decides via the gavel ladder.
func _execute_save_upload(game: GameResource, emulator_id: String, upload: Dictionary, device_id: String, current_timestamp: String, force: bool, on_done: Callable) -> void:
	var upload_file_name = upload.local.file_name
	var original_path = upload.local.file_path
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	print("[GameSaveSubManager] Uploading local save '" + original_path + "' as '" + upload_file_name + "'")

	if is_folder_save:
		var save_name = _get_save_name_for_upload(emulator_id, game, original_path)
		var zip_path = "user://temp/saves/" + str(game.romm_id) + "/" + save_name + ".zip"
		FSM.make_dir_recursive(zip_path.get_base_dir())
		var zip_state := {"done": false, "success": false}
		_run_io_task(original_path,
			func():
				return _zip_emulator_save(emulator_id, original_path, zip_path, game),
			func(zip_success: bool):
				zip_state["success"] = zip_success
				zip_state["done"] = true
		)
		while not zip_state["done"]:
			await get_tree().process_frame
		if not zip_state["success"]:
			push_error("[GameSaveSubManager] Failed to zip folder for upload: " + original_path)
			on_done.call(false)
			return

		SystemManager.network.upload_save(
			game.romm_id, zip_path, emulator_id, SLOT_DEFAULT, device_id, force,
			func(data: Dictionary, error: String):
				if FSM.file_exists(zip_path):
					FSM.delete_file(zip_path)
				_cleanup_temp_dir(zip_path)
				_on_upload_response(game, emulator_id, upload, data, error, device_id, current_timestamp, on_done)
		)
	else:
		SystemManager.network.upload_save(
			game.romm_id, original_path, emulator_id, SLOT_DEFAULT, device_id, force,
			func(data: Dictionary, error: String):
				if original_path.contains("user://temp/saves/") and FSM.file_exists(original_path):
					FSM.delete_file(original_path)
				_on_upload_response(game, emulator_id, upload, data, error, device_id, current_timestamp, on_done)
		)

## Handles the upload response: records the boundary on success, runs the
## 409 resolution ladder on a stale-snapshot rejection.
func _on_upload_response(game: GameResource, emulator_id: String, upload: Dictionary, data: Dictionary, error: String, device_id: String, current_timestamp: String, on_done: Callable) -> void:
	var original_path = upload.local.file_path
	if error == "":
		_record_sync_boundary(game, emulator_id, upload.local.file_name, original_path, current_timestamp, data.get("id", 0), data.get("content_hash", ""))
		on_done.call(true)
		return

	if "409" in error:
		print("[GameSaveSubManager] Upload 409 for " + upload.local.file_name + " - running gavel ladder")
		_handle_upload_409(game, emulator_id, upload, device_id, current_timestamp, on_done)
		return

	push_error("[GameSaveSubManager] Upload failed for " + original_path + ": " + error)
	on_done.call(false)

## 409 fallback: the slot head moved past this device's snapshot. Refetch the
## head, re-decide from hashes alone (gavel L1/L2/L3), then download or
## surface the conflict. Never retries the POST unchanged, never escalates
## to overwrite=true on its own.
func _handle_upload_409(game: GameResource, emulator_id: String, upload: Dictionary, _device_id: String, current_timestamp: String, on_done: Callable) -> void:
	var local_save = upload.local
	_fetch_saves_with_device_retry(game, func(remote_saves: Array, fetch_error: String, resolved_device_id: String):
		if fetch_error != "":
			push_warning("[GameSaveSubManager] 409 refetch failed: " + fetch_error)
			on_done.call(false)
			return

		var file_name = local_save.file_name
		var head = null
		var head_epoch = -1
		for save in remote_saves:
			var slot = save.get("slot", "")
			if slot == null:
				slot = ""
			if slot != SLOT_DEFAULT or save.get("file_name", "") != file_name:
				continue
			var epoch = parse_iso_timestamp(save.get("updated_at", ""))
			if epoch > head_epoch:
				head = save
				head_epoch = epoch
		if head == null:
			push_warning("[GameSaveSubManager] 409 but no server head found for " + file_name)
			on_done.call(false)
			return

		var db_rec = null
		for rec in DataManager.get_save_sync_records(game.romm_id, emulator_id):
			if rec.file_name == file_name:
				db_rec = rec
				break

		var hash_info = local_save.get("_hash_info", {"hash": "", "size": 0})
		if hash_info.get("hash", "") == "":
			hash_info = _compute_local_save_hash(emulator_id, game, local_save)

		var outcome = Gavel.resolve_upload_conflict(
			hash_info.hash if hash_info.hash != "" else null,
			db_rec.get("local_hash") if db_rec else null,
			head.get("content_hash"),
			db_rec.get("server_hash") if db_rec else null)

		if outcome == "download":
			_execute_save_download(game, emulator_id, head, local_save, resolved_device_id, current_timestamp, on_done)
			return

		# L3: genuine two-sided divergence - the user decides
		var choice = await _show_conflict_dialog(game, local_save.get("modified_time", 0), parse_iso_timestamp(head.get("updated_at", "")))
		match choice:
			"local":
				_execute_save_upload(game, emulator_id, upload, resolved_device_id, current_timestamp, true, on_done)
			"server":
				_execute_save_download(game, emulator_id, head, local_save, resolved_device_id, current_timestamp, on_done)
			_:
				on_done.call(false)
	)

## Extracts and restores one downloaded archive according to its layout
## descriptor. Source ZIPs are deleted only after commit + validation succeeds.
func _restore_downloaded_save(zip_path: String, layout: Dictionary, on_complete: Callable) -> void:
	var commit_root := str(layout.get("commit_root", ""))
	var staging_dir := GameExtraction.staging_path(commit_root)
	if not FSM.make_dir_recursive(staging_dir):
		on_complete.call(false)
		return
	var operation_token: Dictionary = layout.get("_operation_token", {})
	if not operation_token.is_empty():
		OperationLifecycle.track_artifact(operation_token, staging_dir)
	FSM.extract_archive_async(zip_path, staging_dir, "Save data", false,
		func(_info: Dictionary): pass,
		func(extract_success: bool, error_msg: String):
			if not extract_success:
				push_error("[GameSaveSubManager] Save extraction failed: " + error_msg)
				_cleanup_save_staging(staging_dir)
				on_complete.call(false)
				return
			var restored := _restore_staged_save(staging_dir, layout)
			if not restored.get("success", false):
				push_error("[GameSaveSubManager] Save restore failed: " + str(restored.get("error", "unknown error")))
				if bool(restored.get("preserve_source", false)):
					var recovery_path := str(restored.get("recovery_path", ""))
					if recovery_path == "":
						recovery_path = staging_dir
					OperationLifecycle.preserve_recovery(layout.get("_operation_token", {}), recovery_path, [staging_dir, str(restored.get("backup_path", ""))])
					push_warning("[GameSaveSubManager] Save recovery data preserved at " + recovery_path)
				else:
					_cleanup_save_staging(staging_dir)
				on_complete.call(false)
				return
			# Keep the source archive until post-commit validation and the
			# confirmation boundary finish; the download operation owns cleanup.
			_cleanup_save_staging(staging_dir)
			on_complete.call(true)
	)

func _restore_staged_save(staging_dir: String, layout: Dictionary) -> Dictionary:
	return SaveLayout.restore_staged_save(staging_dir, layout, FSM)

func _cleanup_save_staging(staging_dir: String) -> void:
	if staging_dir == "" or not GameExtraction.is_staging_path(staging_dir) or not FSM.dir_exists(staging_dir):
		return
	if FSM.extraction_tree_has_symlinks(staging_dir):
		push_warning("[GameSaveSubManager] Leaving unsafe save staging in place: " + staging_dir)
		return
	FSM.delete_dir_recursive(staging_dir)

func _save_mutation_root(record_path: String, layout: Dictionary, folder_save: bool) -> String:
	if record_path.contains("/title/00040000/"):
		# Lock the shared 3DS identity root so data and extdata cannot be
		# restored concurrently by aliases or different emulator frontends.
		return record_path.get_base_dir().get_base_dir().get_base_dir()
	if folder_save and str(layout.get("commit_root", "")) != "":
		return str(layout["commit_root"])
	return record_path

## Executes one download operation: fetch, confirm, extract (folder saves and
## zip-packaged file saves), and record the gavel bookkeeping boundary.
func _execute_save_download(game: GameResource, emulator_id: String, remote: Dictionary, local, device_id: String, current_timestamp: String, on_done: Callable) -> void:
	var save_id = remote.get("id", 0)
	var file_name = FSM.sanitize_server_filename(str(remote.get("file_name", "save")))
	if file_name == "":
		push_error("[GameSaveSubManager] Rejected unsafe save file name from server (save id " + str(save_id) + "): '" + str(remote.get("file_name", "")) + "'")
		on_done.call(false)
		return
	var local_path = ""
	var record_path = ""
	# Dictionary holder so the download/extract lambdas share the boundary by
	# reference (plain String captures by value; the pcsx2 extract-dest
	# correction below must be visible to post_extraction).
	var boundary_path := {"path": ""}
	var zip_path = ""
	var download_dest = ""
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))

	if local:
		record_path = local.file_path
	else:
		if emulator_id == "retroarch":
			record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
		else:
			record_path = FSM.join_paths(save_dir, file_name)

	if is_folder_save:
		zip_path = "user://temp/saves/download_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000) + ".zip"
		FSM.make_dir_recursive(zip_path.get_base_dir())
		local_path = zip_path

		if not local:
			record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
			if record_path == "":
				var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
				if result.error != "":
					push_error("[GameSaveSubManager] Cannot download folder save: no " + result.error + " folder found")
					on_done.call(false)
					return
				record_path = result.path
	else:
		local_path = record_path
		if emulator_id == "retroarch":
			FSM.make_dir_recursive(record_path.get_base_dir())
		if local_path.to_lower().ends_with(".zip"):
			# A zip-packaged file save is restored into its owned root; never
			# overwrite an existing live ZIP just to use it as the source archive.
			local_path = "user://temp/saves/download_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000) + ".zip"
			download_dest = local_path
			FSM.make_dir_recursive(local_path.get_base_dir())
		elif _must_stage_download(local_path):
			# HTTPRequest cannot write restricted trees directly. Keep the
			# existing plugin placement path after content verification.
			download_dest = "user://temp/saves/staged_" + str(Time.get_ticks_msec()) + "_" + file_name
			FSM.make_dir_recursive(download_dest.get_base_dir())
			print("[GameSaveSubManager] Destination is SAF-gated; staging download in " + download_dest)
		else:
			# Stage plain files beside their final path. Verification failure leaves
			# the old file untouched, and a verified move commits on one filesystem.
			download_dest = record_path.get_base_dir() + "/.kyodai-extract-download-" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)

	# Last-line defense for filename aliases. A remote-only record should only
	# materialize a missing save; it must never overwrite a file/folder that
	# discovery already associates with a different filename.
	if local == null and record_path != "":
		var check_path: String = record_path
		if is_folder_save:
			# Some strategies resolve record_path to a container dir (pcsx2's
			# resolve_path returns the memcard root); the save actually lands in
			# the extract-dest child, so that child is the path to guard.
			var dest := _get_extract_dest(emulator_id, save_dir, record_path, game, file_name)
			if dest != "" and dest.get_base_dir().rstrip("/") == record_path.rstrip("/"):
				check_path = dest
		var destination_exists := FSM.dir_exists(check_path) if is_folder_save else FSM.file_exists(check_path)
		if destination_exists:
			push_warning("[GameSaveSubManager] Refusing to download remote save '" + file_name + "' (id " + str(save_id) + ") over existing unresolved local path: " + check_path)
			on_done.call(false)
			return

	# Without the top-level save dir nothing downstream (extraction, boundary
	# hashing) can succeed - fail fast instead of downloading a zip to nowhere.
	if not _ensure_save_directory_exists(emulator_id, save_dir):
		push_error("[GameSaveSubManager] Save directory unavailable for " + emulator_id + " - aborting download of '" + file_name + "'")
		SystemManager.notifications.show_notification("Save download failed for " + game.get_display_name() + ": no access to the emulator's save folder", SystemManager.notifications.Type.ERROR)
		on_done.call(false)
		return

	if download_dest == "":
		download_dest = local_path

	var restore_layout := _get_save_layout(emulator_id, save_dir, record_path, game, file_name)
	boundary_path.path = str(restore_layout.get("boundary_path", record_path))
	var mutation_root := _save_mutation_root(record_path, restore_layout, is_folder_save)
	var operation_lock := OperationLifecycle.acquire(mutation_root, "downloading", 0, [download_dest])
	if operation_lock.is_empty():
		push_warning("[GameSaveSubManager] Another save operation already owns this destination: " + mutation_root)
		on_done.call(false)
		return
	restore_layout["_operation_token"] = operation_lock
	print("[GameSaveSubManager] Downloading remote save '" + file_name + "' (id " + str(save_id) + ") -> '" + local_path + "' (record path: '" + record_path + "')")

	SystemManager.network.download_save(save_id, device_id, download_dest, func(_success: bool, _status_code: int, error_msg: String):
		var finished := {"done": false}
		var finish_operation = func(success: bool) -> void:
			if bool(finished.get("done", false)):
				return
			finished["done"] = true
			if FSM.file_exists(download_dest):
				FSM.delete_file(download_dest)
			_cleanup_temp_dir(download_dest)
			OperationLifecycle.release(operation_lock)
			on_done.call(success)
		if not _success:
			push_error("[GameSaveSubManager] Download failed for save " + str(save_id) + ": " + error_msg)
			finish_operation.call(false)
			return

		var proceed = func() -> void:
			OperationLifecycle.update_phase(operation_lock, "commit_started")
			# Place only verified staged content into the live destination tree.
			if download_dest != local_path:
				if not FSM.move(download_dest, local_path):
					push_error("[GameSaveSubManager] Failed to place staged download at '" + local_path + "'")
					finish_operation.call(false)
					return

			var post_extraction = func(extract_success: bool) -> void:
				if not extract_success:
					finish_operation.call(false)
					return
				boundary_path.path = str(restore_layout.get("boundary_path", boundary_path.path))
				if LaunchManager.registry.get_emulator_architecture(emulator_id) == "pcsx2" and not ensure_pcsx2_superblock(save_dir):
					push_error("[GameSaveSubManager] PCSX2 superblock validation failed; download is not confirmed")
					finish_operation.call(false)
					return
				OperationLifecycle.update_phase(operation_lock, "validating")
				_run_io_task(boundary_path.path,
					func(): return _compute_local_save_hash(emulator_id, game, {"file_path": boundary_path.path}),
					func(hash_info):
						if not hash_info is Dictionary or str(hash_info.get("hash", "")).is_empty():
							push_error("[GameSaveSubManager] Could not hash restored save; download is not confirmed")
							finish_operation.call(false)
							return
						OperationLifecycle.update_phase(operation_lock, "confirming")
						SystemManager.network.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
							if confirm_error != "":
								# Do not create a synced baseline until RomM confirms. The
								# next sync must retry confirmation rather than skip locally.
								push_warning("[GameSaveSubManager] Local restore validated but RomM confirmation failed: " + confirm_error)
								finish_operation.call(false)
								return
							var recorded: bool = DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, boundary_path.path, current_timestamp, save_id, SLOT_DEFAULT, str(hash_info.get("hash", "")), str(remote.get("content_hash", "")), int(hash_info.get("size", 0)))
							if not recorded:
								push_error("[GameSaveSubManager] Could not persist restored-save boundary after confirmation")
								finish_operation.call(false)
								return
							# Small delay to let the filesystem settle before emulator launch.
							await get_tree().create_timer(0.1).timeout
							finish_operation.call(true)
						)
				)

			if is_folder_save:
				# Routed-unpack hook: strategies that need per-entry routing
				# (3DS data+extdata units) handle the zip themselves and
				# return a bool; null falls through to generic extraction.
				var unpack = _get_strategy(emulator_id, "unpack")
				var unpacked = null
				if unpack.is_valid():
					unpacked = unpack.call(zip_path, record_path, game, operation_lock)
				if unpacked != null:
					if not unpacked:
						push_error("[GameSaveSubManager] Failed to unpack downloaded zip: " + zip_path)
					post_extraction.call(unpacked)
					return
				_restore_downloaded_save(zip_path, restore_layout, post_extraction)
			elif local_path.to_lower().ends_with(".zip"):
				# Non-folder save downloaded as zip (e.g. GameCube .gci bundle).
				_restore_downloaded_save(local_path, restore_layout, post_extraction)
			else:
				post_extraction.call(true)

		var expected_hash := str(remote.get("content_hash", "") if remote.get("content_hash", "") != null else "").strip_edges().to_lower()
		OperationLifecycle.update_phase(operation_lock, "verifying")
		_run_io_task(download_dest,
			func(): return _ContentHash.compute_content_hash(download_dest),
			func(actual_hash):
				if not actual_hash is String:
					push_error("[GameSaveSubManager] Content-hash worker was unavailable; download is not confirmed")
					finish_operation.call(false)
					return
				if expected_hash != "" and (actual_hash.is_empty() or actual_hash.to_lower() != expected_hash):
					push_error("[GameSaveSubManager] Downloaded content hash mismatch for save " + str(save_id) + "; live save is unchanged")
					finish_operation.call(false)
					return
				if expected_hash == "":
					push_warning("[GameSaveSubManager] Remote save has no content_hash; using legacy unverified-download compatibility")
				proceed.call()
		)
	)

## Parses an ISO 8601 timestamp string to Unix seconds.
## Handles trailing timezone offsets (Z, +HH:MM, -HH:MM) and converts to UTC.
## Returns 0 if parsing fails or the input is empty.
func parse_iso_timestamp(iso_string: String) -> int:
	if iso_string == "":
		return 0
	
	# Validate format and capture optional timezone offset.
	# Matches: 2024-01-15T10:30:00Z, 2024-01-15T10:30:00+02:00, etc.
	var regex = RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?")
	var match_result = regex.search(iso_string)
	if not match_result:
		return 0
	
	var year = int(match_result.get_string(1))
	var month = int(match_result.get_string(2))
	var day = int(match_result.get_string(3))
	var hour = int(match_result.get_string(4))
	var minute = int(match_result.get_string(5))
	var second = int(match_result.get_string(6))
	var tz_str = match_result.get_string(7)
	
	var dict = {"year": year, "month": month, "day": day,
				"hour": hour, "minute": minute, "second": second}
	var unix = int(Time.get_unix_time_from_datetime_dict(dict))
	
	# Apply timezone offset to get true UTC timestamp.
	if tz_str != "" and tz_str != "Z":
		var tz_regex = RegEx.new()
		tz_regex.compile("([+-])(\\d{2}):?(\\d{2})")
		var tz_match = tz_regex.search(tz_str)
		if tz_match:
			var tz_sign = 1 if tz_match.get_string(1) == "+" else -1
			var tz_hours = int(tz_match.get_string(2))
			var tz_minutes = int(tz_match.get_string(3))
			var offset_seconds = tz_sign * (tz_hours * 3600 + tz_minutes * 60)
			unix -= offset_seconds
	
	return unix

## Auto-upload saves after playing (post-exit hook)
## Checks for conflicts and shows dialog if both local and server saves have changed
func auto_upload_saves_for_game(game: GameResource, emulator_id: String) -> void:
	print("[GameSaveSubManager] auto_upload_saves_for_game called for " + game.get_display_name() + " (" + emulator_id + ")")
	if not DataManager.get_setting("save_sync_auto").value:
		print("[GameSaveSubManager] Auto-upload aborted: save_sync_auto is off")
		return
	if not SystemManager.network.is_romm_connected():
		print("[GameSaveSubManager] Auto-upload aborted: not connected to RomM")
		return

	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		print("[GameSaveSubManager] Auto-upload aborted: save sync already in progress for this game")
		return

	# Honor a pre-launch conflict choice without re-asking
	var choice_override = _sync_choice_overrides.get(sync_key, "")
	if choice_override != "":
		_sync_choice_overrides.erase(sync_key)
	if choice_override == "cancel":
		print("[GameSaveSubManager] Auto-upload skipped: user cancelled save sync pre-launch")
		return
	var force_all = choice_override == "local"
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	if save_dir == "" or extensions.is_empty():
		print("[GameSaveSubManager] Auto-upload aborted: no save dir or extensions (dir=" + save_dir + ", ext count=" + str(extensions.size()) + ")")
		return

	# Android: without a document-tree grant for a restricted save dir, every
	# SAF call fails mid-sync. Prompt just-in-time and retry once granted;
	# on denial, skip the upload silently (the game already ran).
	var grant_probe = _save_sync_grant_probe(emulator_id, save_dir)
	if grant_probe != "":
		SystemManager.platform.ensure_android_data_access(func(granted: bool):
			if granted:
				auto_upload_saves_for_game(game, emulator_id)
		, grant_probe)
		return

	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	if is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc"):
		if game.get_active_title_id() == "":
			return

	var prepare = _get_strategy(emulator_id, "prepare")
	if prepare.is_valid():
		prepare.call(save_dir, game)

	# Discovery walks the save directory tree and hashing reads every local
	# save; both run inside the I/O task (see auto_download_saves_for_game).
	var scan_work := func() -> Array[Dictionary]:
		var found: Array[Dictionary]
		if is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc"):
			found = _discover_emulator_saves(emulator_id, save_dir, game)
		else:
			found = _discover_game_saves(save_dir, game, extensions)
		for save in found:
			save["_hash_info"] = _compute_local_save_hash(emulator_id, game, save)
		return found
	_run_io_task(save_dir, scan_work, func(local_saves: Array[Dictionary]):
		if local_saves.is_empty():
			if DEBUG_LOG: print("[GameSaveSubManager] No local saves found for auto-upload (emulator: " + emulator_id + ", title_id: " + game.get_active_title_id() + ", dir: " + save_dir + "), skipping.")
			SystemManager.notifications.show_notification("No local saves found for " + game.get_display_name() + " - nothing to upload", SystemManager.notifications.Type.INFO)
			return

		_begin_save_sync(sync_key)
		_auto_upload_after_scan(game, emulator_id, local_saves, sync_key, force_all)
	)

func _auto_upload_after_scan(game: GameResource, emulator_id: String, local_saves: Array[Dictionary], sync_key: String, force_all: bool = false) -> void:
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[GameSaveSubManager] Auto-upload aborted: " + error)
			_end_save_sync(sync_key)
			return

		if force_all:
			# User chose keep-local on the pre-launch conflict dialog: force the
			# upload without re-asking (explicit choice = legitimate overwrite)
			var force_ops: Array = []
			for local in local_saves:
				force_ops.append({"local": local, "force": true})
			_perform_auto_upload(game, emulator_id, force_ops, DataManager.get_romm_device_id())
			return

		# Check for conflicts with remote saves before uploading
		_fetch_saves_with_device_retry(game, func(remote_saves: Array, fetch_error: String, resolved_device_id: String):
			if fetch_error != "":
				push_warning("[GameSaveSubManager] Auto-upload conflict check failed: " + fetch_error)
				# Continue with upload anyway if we can't check
				var fallback_ops: Array = []
				for local in local_saves:
					fallback_ops.append({"local": local})
				_perform_auto_upload(game, emulator_id, fallback_ops, resolved_device_id)
				return

			# Check if any local save conflicts with remote (gavel decision per record)
			var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)

			# A successful fetch that comes back empty while the DB knows save
			# records is a transient server/network lie - uploading here would
			# POST duplicates of records the server already has.
			if remote_saves.is_empty() and not db_records.is_empty():
				push_warning("[GameSaveSubManager] auto_upload: fetch returned no remote saves but DB has " + str(db_records.size()) + " sync record(s); treating as transient failure, skipping upload")
				SystemManager.notifications.show_notification("Save sync skipped: could not verify server state", SystemManager.notifications.Type.ERROR)
				_end_save_sync(sync_key)
				return

			db_records = _dedupe_save_sync_records(game, emulator_id, db_records, remote_saves)
			var save_dir := resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
			var is_folder_save := uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
			remote_saves = _filter_remote_saves_by_destination(game, emulator_id, local_saves, remote_saves, save_dir, is_folder_save)

			var db_by_name: Dictionary = {}
			for rec in db_records:
				db_by_name[rec.file_name] = rec

			var remote_by_name: Dictionary = {}
			for save in remote_saves:
				var slot = save.get("slot", "")
				if slot == null:
					slot = ""
				if slot == SLOT_DEFAULT:
					remote_by_name[save.file_name] = save

			var conflict_pairs: Array = []
			var upload_ops: Array = []

			for local in local_saves:
				var remote = remote_by_name.get(local.file_name)
				var verdict = _gavel_decide(emulator_id, game, local, remote, db_by_name.get(local.file_name), resolved_device_id)
				local["_hash_info"] = verdict.hash_info
				if DEBUG_LOG: print("[GameSaveSubManager] auto_upload: gavel verdict for '" + local.file_name + "': " + verdict.decision.action + " (" + verdict.decision.get("reason", "") + ")" + _hash_detail(verdict.hash_info.hash, remote.get("content_hash", "") if remote else "", db_by_name.get(local.file_name, {}).get("local_hash", "")))
				if verdict.decision.action == "upload":
					# Slot-wide parity: don't POST a duplicate of identical
					# content living under a different server file_name
					if remote == null and not _find_slot_parity_remote(remote_by_name.values(), verdict.hash_info.hash).is_empty():
						continue
					upload_ops.append({"local": local})
				elif verdict.decision.action == "conflict":
					conflict_pairs.append({"local": local, "remote": remote})

			if not conflict_pairs.is_empty():
				if HeadlessLaunchRunner.is_active():
					# Headless newest-wins: local-newer force-uploads, remote-newer downloads
					var headless_timestamp = Time.get_datetime_string_from_system(true, true)
					var headless_downloads: Array = []
					for pair in conflict_pairs:
						var headless_local_mtime: int = pair.local.modified_time
						var headless_remote_mtime: int = parse_iso_timestamp(pair.remote.get("updated_at", ""))
						if headless_local_mtime > headless_remote_mtime:
							push_warning("[GameSaveSubManager] headless: conflict on '" + pair.local.file_name + "' - local is newer, force uploading")
							upload_ops.append({"local": pair.local, "force": true})
						else:
							push_warning("[GameSaveSubManager] headless: conflict on '" + pair.local.file_name + "' - server is newer, downloading")
							headless_downloads.append(pair)
					if headless_downloads.is_empty():
						_perform_auto_upload(game, emulator_id, upload_ops, resolved_device_id)
					else:
						var headless_dl_state = {"pending": headless_downloads.size()}
						for pair in headless_downloads:
							_execute_save_download(game, emulator_id, pair.remote, pair.local, resolved_device_id, headless_timestamp, func(_dl_success: bool):
								headless_dl_state.pending -= 1
								if headless_dl_state.pending <= 0:
									_perform_auto_upload(game, emulator_id, upload_ops, resolved_device_id)
							)
				else:
					# Show conflict dialog
					print("[GameSaveSubManager] Auto-upload detected conflict, showing dialog")
					var first = conflict_pairs[0]
					var choice = await _show_conflict_dialog(game, first.local.modified_time, parse_iso_timestamp(first.remote.get("updated_at", "")))

					match choice:
						"local":
							# User chose to keep local, proceed with upload (force is
							# legitimate only here: explicit user keep-local)
							print("[GameSaveSubManager] User chose to keep local save, proceeding with upload")
							for pair in conflict_pairs:
								upload_ops.append({"local": pair.local, "force": true})
							_perform_auto_upload(game, emulator_id, upload_ops, resolved_device_id)
						"server":
							# User chose the server copy: download it now so the
							# choice takes effect immediately and the baseline is
							# recorded for future syncs
							print("[GameSaveSubManager] User chose server save, downloading now")
							var current_timestamp = Time.get_datetime_string_from_system(true, true)
							var dl_state = {"pending": conflict_pairs.size(), "failed": 0}
							for pair in conflict_pairs:
								_execute_save_download(game, emulator_id, pair.remote, pair.local, resolved_device_id, current_timestamp, func(success: bool):
									if not success:
										dl_state.failed += 1
									dl_state.pending -= 1
									if dl_state.pending <= 0:
										if dl_state.failed > 0:
											SystemManager.notifications.show_notification("Save sync: server download failed", SystemManager.notifications.Type.ERROR)
										else:
											SystemManager.notifications.show_notification("Save sync: server version applied", SystemManager.notifications.Type.INFO)
										_end_save_sync(sync_key)
								)
						"cancel", "":
							# User cancelled
							print("[GameSaveSubManager] User cancelled auto-upload")
							SystemManager.notifications.show_notification("Save sync cancelled", SystemManager.notifications.Type.INFO)
							_end_save_sync(sync_key)
			else:
				# No conflict, upload only records gavel marked as changed
				_perform_auto_upload(game, emulator_id, upload_ops, resolved_device_id)
		)
	)


## Internal function to perform the actual auto-upload after conflict checks
## upload_ops: [{"local": save record, "force": bool (default false)}]
func _perform_auto_upload(game: GameResource, emulator_id: String, upload_ops: Array, device_id: String) -> void:
	if upload_ops.is_empty():
		SystemManager.notifications.show_notification("Saves already in sync", SystemManager.notifications.Type.INFO)
		_end_save_sync(_save_sync_key(game, emulator_id))
		return

	var current_timestamp = Time.get_datetime_string_from_system(true, true)
	var state = {"pending": upload_ops.size(), "failed": 0}

	var on_one_done = func(success: bool):
		if not success:
			state.failed += 1
		state.pending -= 1
		if state.pending <= 0:
			if state.failed > 0:
				SystemManager.notifications.show_notification("Save sync failed for some files", SystemManager.notifications.Type.ERROR)
			else:
				SystemManager.notifications.show_notification("Saves synced to RomM", SystemManager.notifications.Type.INFO)
			_end_save_sync(_save_sync_key(game, emulator_id))

	for op in upload_ops:
		_execute_save_upload(game, emulator_id, {"local": op.local, "remote": null}, device_id, current_timestamp, op.get("force", false), on_one_done)

## Startup recovery sweep: checks the most recently launched game for a local
## save that no longer matches its last sync boundary (e.g. the OS killed
## Kyodai before the post-play upload ran). Only the most recent game is
## checked: the OOM-kill scenario strands the killed session's game, and older
## drift is caught by that game's next pre-launch auto-download. Path resolution,
## the sync-record fetch, discovery, and hashing run as one worker unit when the
## path is safe to thread; prompts before any upload.
func _schedule_startup_dirty_sweep() -> void:
	if _dirty_sweep_ran:
		return
	_dirty_sweep_ran = true
	# Headless launch companions never prompt; drift is reconciled by the
	# newest-wins conflict policy during the launch's own sync.
	if HeadlessLaunchRunner.is_active():
		return
	# Let startup settle before touching disk: wait out the warmup window so
	# the sweep can't collide with shader prewarm or the settings pre-creation
	# (capped in case the home grid never settles), then a short buffer.
	var waited_ms := Time.get_ticks_msec()
	while WarmupBudget.is_startup_mode() and Time.get_ticks_msec() - waited_ms < 20000:
		await get_tree().process_frame
	await get_tree().create_timer(3.0).timeout
	if not DataManager.get_setting("save_sync_auto").value:
		return
	if not SystemManager.network.is_romm_connected():
		return
	var dirty: Dictionary = await _check_most_recent_save_dirty()
	if dirty.is_empty():
		if DEBUG_LOG: print("[GameSaveSubManager] Startup sweep: most recent save matches its last sync boundary")
		return
	print("[GameSaveSubManager] Startup sweep: unsynced local save for " + dirty.game.get_display_name())
	var choice = await _show_dirty_sweep_dialog([dirty])
	if choice != "upload":
		return
	auto_upload_saves_for_game(dirty.game, dirty.emulator_id)

## Returns {game, emulator_id} when the most recently launched game has a
## local save whose hash differs from the recorded sync boundary, else {}.
func _check_most_recent_save_dirty() -> Dictionary:
	# Android restricted-path scans can't thread (KyodaiBridge), so resolve
	# the context inline there: the save dir decides whether the unit threads.
	# On desktop even the context resolves inside the worker.
	var prologue_start_us := Time.get_ticks_usec()
	var ctx := {}
	if SystemManager.platform.is_android():
		ctx = _resolve_sweep_context()
		if ctx.is_empty():
			return {}
	if DEBUG_LOG: print("[GameSaveSubManager] Startup sweep prologue (main thread) elapsed_us=", Time.get_ticks_usec() - prologue_start_us)
	var worker_start_us := Time.get_ticks_usec()

	# One work unit: context (game query, emulator/path resolution), sync-record
	# fetch, discovery, hashing, and the boundary comparison all stay together
	# so threaded paths keep the whole check off the main thread. Read-only:
	# the DB is mutex-guarded and registry/settings reads from workers are
	# already an established pattern here.
	var work := func() -> Dictionary:
		var c: Dictionary = ctx
		if c.is_empty():
			c = _resolve_sweep_context()
			if c.is_empty():
				return {}
		var db_records = DataManager.get_save_sync_records(c.game.romm_id, c.emulator_id)
		if db_records.is_empty():
			return {}  # never synced: no boundary to recover against
		var db_by_name: Dictionary = {}
		for rec in db_records:
			db_by_name[rec.file_name] = rec
		var found: Array[Dictionary]
		if c.is_folder_save or (c.emulator_id == "dolphin" and c.game.platform_slug == "ngc"):
			found = _discover_emulator_saves(c.emulator_id, c.save_dir, c.game)
		else:
			found = _discover_game_saves(c.save_dir, c.game, c.extensions)
		for save in found:
			var rec = db_by_name.get(save.file_name)
			if rec == null or rec.get("local_hash", "") == "":
				continue  # no baseline hash to compare against
			var hash_info := _compute_local_save_hash(c.emulator_id, c.game, save)
			if hash_info.hash != "" and hash_info.hash != rec.local_hash:
				if DEBUG_LOG: print("[GameSaveSubManager] Startup sweep: dirty save '" + save.file_name + "' for " + c.game.get_display_name() + _hash_detail(hash_info.hash, rec.get("server_hash", ""), rec.local_hash))
				return {"game": c.game, "emulator_id": c.emulator_id}
		return {}
	var state := {"done": false, "result": {}}
	_run_io_task(ctx.get("save_dir", "user://"), work, func(r: Dictionary):
		state["result"] = r
		state["done"] = true
	)
	while not state["done"]:
		await get_tree().process_frame
	if DEBUG_LOG: print("[GameSaveSubManager] Startup sweep worker (resolve+db+discover+hash) elapsed_us=", Time.get_ticks_usec() - worker_start_us)
	return state["result"]

## Gathers everything the sweep needs to check the most recently played game:
## {game, emulator_id, extensions, is_folder_save, save_dir}, or {} when there
## is nothing to check. Uses a targeted LIMIT 1 query — get_all_games()
## hydrates the whole library (per-row JSON blobs) just to find one game.
func _resolve_sweep_context() -> Dictionary:
	var game: GameResource = DataManager.get_most_recently_played_game()
	if game == null:
		return {}
	var emulator_id: String = LaunchManager.resolve_emulator_for_game(game)
	if emulator_id == "":
		return {}
	var core_id = _get_core_id_for_save_resolution(emulator_id, game)
	var extensions = get_save_extensions(emulator_id, game.platform_slug, core_id)
	if extensions.is_empty():
		return {}
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, core_id)
	if (is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc")) and game.get_active_title_id() == "":
		return {}
	var save_dir := resolve_active_save_directory(emulator_id, game.platform_slug, core_id)
	if save_dir == "":
		return {}
	return {
		"game": game,
		"emulator_id": emulator_id,
		"extensions": extensions,
		"is_folder_save": is_folder_save,
		"save_dir": save_dir,
	}

## Prompts about saves that drifted from their last sync boundary (sweep).
## Returns "upload" or "skip" (also "skip" on dismissal).
func _show_dirty_sweep_dialog(dirty: Array) -> String:
	# Share the conflict-dialog serialization so prompts never stack
	while _conflict_dialog_open:
		await _conflict_dialog_closed
	_conflict_dialog_open = true

	var result := {"choice": "skip", "upload_btn": null, "skip_btn": null}
	var names := []
	for entry in dirty:
		names.append(entry.game.get_display_name())

	var dialog = UIManager.show_custom_dialog(func(sweep_dialog: M3Dialog):
		sweep_dialog.title_text = "Unsynced Save Data"
		sweep_dialog.body_text = "Local save data changed but was never synced to the server (Kyodai may have been closed before sync finished):\n\n" + "\n".join(names) + "\n\nUpload now?"
		sweep_dialog.dismissible = true
		sweep_dialog.disable_default_action = true

		var content = VBoxContainer.new()
		content.alignment = BoxContainer.ALIGNMENT_BEGIN

		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, M3Units.dp(16))
		content.add_child(spacer)

		result["upload_btn"] = M3Button.new()
		var dlg_upload_btn: M3Button = result["upload_btn"]
		dlg_upload_btn.custom_minimum_size = Vector2(0, M3Units.dp(64))
		dlg_upload_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		dlg_upload_btn.button_size = M3Button.Size.LARGE
		dlg_upload_btn.text = "Upload to Server"
		dlg_upload_btn.pressed.connect(func():
			result["choice"] = "upload"
			sweep_dialog.dismiss()
		)
		content.add_child(dlg_upload_btn)

		result["skip_btn"] = M3Button.new()
		var dlg_skip_btn: M3Button = result["skip_btn"]
		dlg_skip_btn.custom_minimum_size = Vector2(0, M3Units.dp(56))
		dlg_skip_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		dlg_skip_btn.button_size = M3Button.Size.MEDIUM
		dlg_skip_btn.button_variant = M3Button.Variant.TEXT
		dlg_skip_btn.text = "Skip"
		dlg_skip_btn.pressed.connect(func():
			result["choice"] = "skip"
			sweep_dialog.dismiss()
		)
		content.add_child(dlg_skip_btn)

		sweep_dialog.content_slot.add_child(content)
	, Callable())

	await get_tree().process_frame
	var upload_btn = result["upload_btn"]
	var skip_btn = result["skip_btn"]
	if is_instance_valid(upload_btn) and is_instance_valid(skip_btn):
		upload_btn.focus_neighbor_bottom = skip_btn.get_path()
		skip_btn.focus_neighbor_top = upload_btn.get_path()
		upload_btn.grab_focus()

	await dialog.dismissed

	_conflict_dialog_open = false
	_conflict_dialog_closed.emit()

	print("[GameSaveSubManager] Startup sweep dialog resolved with choice: " + result["choice"])
	return result["choice"]

## Auto-download saves before launch (pre-launch hook)
## If on_complete callback is provided, it will be called when sync finishes
func auto_download_saves_for_game(game: GameResource, emulator_id: String, on_complete: Callable = Callable()) -> void:
	print("[GameSaveSubManager] auto_download: START for game=" + game.get_display_name() + " emulator=" + emulator_id)
	
	if not DataManager.get_setting("save_sync_auto").value:
		print("[GameSaveSubManager] auto_download: ABORT - save_sync_auto is false")
		if on_complete.is_valid():
			on_complete.call()
		return
	if not SystemManager.network.is_romm_connected():
		print("[GameSaveSubManager] auto_download: ABORT - not connected to RomM")
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	if DEBUG_LOG: print("[GameSaveSubManager] auto_download: save_dir=" + save_dir + " extensions=" + str(extensions.size()))
	if save_dir == "" or extensions.is_empty():
		print("[GameSaveSubManager] auto_download: ABORT - no save_dir or extensions")
		if on_complete.is_valid():
			on_complete.call()
		return

	# Android: without a document-tree grant for a restricted save dir, every
	# SAF call fails mid-sync. Prompt just-in-time and retry once granted;
	# on denial, launch proceeds without syncing.
	var grant_probe = _save_sync_grant_probe(emulator_id, save_dir)
	if grant_probe != "":
		SystemManager.platform.ensure_android_data_access(func(granted: bool):
			if granted:
				auto_download_saves_for_game(game, emulator_id, on_complete)
			elif on_complete.is_valid():
				on_complete.call()
		, grant_probe)
		return

	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))

	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		# Pre-launch must not skip a needed download: wait for the in-flight
		# sync (e.g. a manual sync started moments ago) to finish, bounded.
		if DEBUG_LOG: print("[GameSaveSubManager] auto_download: save sync already in progress, waiting for it to finish")
		var wait_ms = 0
		while _save_sync_in_flight.has(sync_key) and wait_ms < 15000:
			await get_tree().create_timer(0.1).timeout
			wait_ms += 100
		if _save_sync_in_flight.has(sync_key):
			push_warning("[GameSaveSubManager] auto_download: timed out waiting for in-flight save sync")
		if on_complete.is_valid():
			on_complete.call()
		return
	_begin_save_sync(sync_key)
	var user_on_complete = on_complete
	on_complete = func():
		_end_save_sync(sync_key)
		if user_on_complete.is_valid():
			user_on_complete.call()

	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[GameSaveSubManager] Auto-download aborted: " + error)
			if on_complete.is_valid():
				on_complete.call()
			return
		
		_fetch_saves_with_device_retry(game, func(remote_saves: Array, fetch_error: String, resolved_device_id: String):
			if fetch_error != "":
				push_warning("[GameSaveSubManager] Pre-launch fetch failed: " + fetch_error)
				if on_complete.is_valid():
					on_complete.call()
				return
			
			print("[GameSaveSubManager] auto_download: fetched " + str(remote_saves.size()) + " remote saves for romm_id=" + str(game.romm_id))
			
			var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)

			# A successful fetch that comes back empty while the DB knows save
			# records is a transient server/network lie - skip this sync rather
			# than decide against phantom state.
			if remote_saves.is_empty() and not db_records.is_empty():
				push_warning("[GameSaveSubManager] auto_download: fetch returned no remote saves but DB has " + str(db_records.size()) + " sync record(s); treating as transient failure, skipping sync")
				if on_complete.is_valid():
					on_complete.call()
				return

			db_records = _dedupe_save_sync_records(game, emulator_id, db_records, remote_saves)
			var db_by_name: Dictionary = {}
			for rec in db_records:
				db_by_name[rec.file_name] = rec
			
			var local_saves: Array[Dictionary]
			if is_folder_save:
				if game.get_active_title_id() == "":
					print("[GameSaveSubManager] auto_download: ABORT - folder save but no active title ID for " + game.get_display_name())
					if on_complete.is_valid():
						on_complete.call()
					return
				var validation_error = _validate_emulator_title_id(emulator_id, game.get_active_title_id())
				if validation_error != "":
					print("[GameSaveSubManager] auto_download: ABORT - title ID '" + game.get_active_title_id() + "' rejected: " + validation_error)
					if on_complete.is_valid():
						on_complete.call()
					return

			var prepare = _get_strategy(emulator_id, "prepare")
			if prepare.is_valid():
				prepare.call(save_dir, game)

			# Discovery walks the save directory tree and hashing reads every
			# local save; both run inside the I/O task so SAF-tier devices don't
			# serialize per-file ContentResolver round-trips on the main thread.
			var scan_work := func() -> Array[Dictionary]:
				var found: Array[Dictionary]
				if is_folder_save:
					found = _discover_emulator_saves(emulator_id, save_dir, game)
				else:
					found = _discover_game_saves(save_dir, game, extensions)
				for save in found:
					save["_hash_info"] = _compute_local_save_hash(emulator_id, game, save)
				return found
			var scan_threaded := _should_thread_io(save_dir)
			var scan_state := {"done": false, "result": []}
			_run_io_task(save_dir, scan_work, func(scan_result: Array[Dictionary]):
				scan_state["result"] = scan_result
				scan_state["done"] = true
			)
			while not scan_state["done"]:
				await get_tree().process_frame
			local_saves = scan_state["result"]

			# Safeguard for threaded restricted-path scans: an empty result
			# could theoretically be a plugin/threading lie, and acting on it
			# would mean remote-over-local downloads clobbering real saves.
			# When an empty scan could change a decision (remote saves or DB
			# records exist), re-scan inline once and trust the inline result.
			if local_saves.is_empty() and scan_threaded and _is_restricted_android_path(save_dir) \
					and (not remote_saves.is_empty() or not db_records.is_empty()):
				var inline_saves: Array[Dictionary] = scan_work.call()
				if not inline_saves.is_empty():
					push_warning("[GameSaveSubManager] threaded scan found 0 saves but inline re-scan found " + str(inline_saves.size()) + " in " + save_dir + " - using inline result")
					local_saves = inline_saves
				elif DEBUG_LOG:
					print("[GameSaveSubManager] empty-scan re-verify agreed for " + save_dir)

			if DEBUG_LOG: print("[GameSaveSubManager] auto_download: found " + str(local_saves.size()) + " local saves in " + save_dir)

			var local_by_name: Dictionary = {}
			for save in local_saves:
				local_by_name[save.file_name] = save
			
			remote_saves = _filter_remote_saves_by_destination(game, emulator_id, local_saves, remote_saves, save_dir, is_folder_save)

			var current_timestamp = Time.get_datetime_string_from_system(true, true)
			var state = {"pending": 0, "failed": 0, "fired": false}
			
			var check_complete = func():
				if state.fired or state.pending > 0:
					return
				state.fired = true
				if on_complete.is_valid():
					on_complete.call()
			
			var conflict_pairs: Array = []
			for remote in remote_saves:
				var slot = remote.get("slot", "")
				if slot == null:
					slot = ""
				if slot != SLOT_DEFAULT:
					continue

				var file_name = remote.get("file_name", "save")
				var save_id = remote.get("id", 0)
				var local = local_by_name.get(file_name)
				var db_rec = db_by_name.get(file_name)

				var verdict = _gavel_decide(emulator_id, game, local, remote, db_rec, resolved_device_id)
				var action: String = verdict.decision.action
				if DEBUG_LOG: print("[GameSaveSubManager] auto_download: gavel verdict for '" + file_name + "': " + action + " (" + verdict.decision.get("reason", "") + ")" + _hash_detail(verdict.hash_info.hash, remote.get("content_hash", ""), db_rec.get("local_hash", "") if db_rec else ""))

				match action:
					"download":
						# Slot-wide parity: identical content already exists
						# locally under a different file_name - adopt the
						# baseline instead of downloading a duplicate.
						var ch = remote.get("content_hash", "")
						var parity_local = null
						if local == null and ch != null and ch != "":
							for l in local_saves:
								if l.get("_hash_info", {}).get("hash", "") == ch:
									parity_local = l
									break
						if parity_local != null:
							if DEBUG_LOG: print("[GameSaveSubManager] auto_download: parity match for '" + file_name + "' - identical content already local as '" + parity_local.file_name + "', adopting baseline (download skipped)")
							DataManager.update_save_sync_record(game.romm_id, emulator_id, parity_local.file_name, parity_local.file_path, current_timestamp, save_id, SLOT_DEFAULT, ch, ch, parity_local._hash_info.size)
						else:
							state.pending += 1
							_execute_save_download(game, emulator_id, remote, local, resolved_device_id, current_timestamp, func(success: bool):
								if not success:
									state.failed += 1
								state.pending -= 1
								if state.pending <= 0 and state.failed == 0:
									SystemManager.notifications.show_notification("Saves downloaded from RomM", SystemManager.notifications.Type.INFO)
								check_complete.call()
							)
					"conflict":
						conflict_pairs.append({"local": local, "remote": remote})
					"skip":
						if verdict.decision.get("adopt_baseline", false):
							var hash_info = verdict.hash_info
							var record_path = local.file_path if local else FSM.join_paths(save_dir, file_name)
							DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT, hash_info.hash, remote.get("content_hash", ""), hash_info.size)
					# "upload": pre-launch never uploads; local work is picked up post-launch

			# Surface conflicts BEFORE launching: the choice is respected this
			# session (keep-local force-uploads post-launch without re-asking,
			# cancel suppresses the post-launch sync entirely)
			if not conflict_pairs.is_empty():
				state.pending += 1  # conflict resolution counts as a pending op
				if HeadlessLaunchRunner.is_active():
					# Per-file newest-wins: server-newer downloads now; local-newer
					# keeps local and force-uploads post-launch without re-asking
					for pair in conflict_pairs:
						var headless_local_mtime: int = pair.local.modified_time if pair.local else 0
						var headless_remote_mtime: int = parse_iso_timestamp(pair.remote.get("updated_at", ""))
						if headless_local_mtime > headless_remote_mtime:
							push_warning("[GameSaveSubManager] headless: pre-launch conflict on '" + pair.remote.get("file_name", "save") + "' - local is newer, keeping local (uploads after play)")
							_sync_choice_overrides[sync_key] = "local"
						else:
							push_warning("[GameSaveSubManager] headless: pre-launch conflict on '" + pair.remote.get("file_name", "save") + "' - server is newer, downloading")
							state.pending += 1
							_execute_save_download(game, emulator_id, pair.remote, pair.local, resolved_device_id, current_timestamp, func(success: bool):
								if not success:
									state.failed += 1
								state.pending -= 1
								check_complete.call()
							)
				else:
					var first = conflict_pairs[0]
					var local_mtime = first.local.modified_time if first.local else 0
					var choice = await _show_conflict_dialog(game, local_mtime, parse_iso_timestamp(first.remote.get("updated_at", "")))
					match choice:
						"server":
							for pair in conflict_pairs:
								state.pending += 1
								_execute_save_download(game, emulator_id, pair.remote, pair.local, resolved_device_id, current_timestamp, func(success: bool):
									if not success:
										state.failed += 1
									state.pending -= 1
									check_complete.call()
								)
						"local":
							_sync_choice_overrides[sync_key] = "local"
						_:
							_sync_choice_overrides[sync_key] = "cancel"
				state.pending -= 1

			# Fire completion once the conflict (if any) is resolved and no
			# downloads remain in flight
			check_complete.call()
		)
	)

## Validates that a PCSX2 superblock exists and has a valid header.
## Returns true if valid, false if missing or invalid.
func validate_pcsx2_superblock(memcard_path: String) -> bool:
	var superblock_path = memcard_path.rstrip("/") + "/_pcsx2_superblock"
	if not FSM.file_exists(superblock_path):
		return false
	var existing = FSM.open_file_read(superblock_path)
	if not existing:
		return false
	var header = existing.get_buffer(28)
	existing.close()
	var magic = "Sony PS2 Memory Card Format "
	for i in range(min(header.size(), magic.length())):
		if header[i] != magic.unicode_at(i):
			return false
	return true

## Creates a valid PS2 memory card superblock header for PCSX2 folder memory cards.
## Always writes a fresh superblock regardless of existing state.
## PCSX2 handles directory scanning itself; we only need to provide the card metadata header.
func create_pcsx2_superblock(memcard_path: String) -> bool:
	var superblock_path = memcard_path.rstrip("/") + "/_pcsx2_superblock"
	print("[GameSaveSubManager] Creating PCSX2 superblock at: " + superblock_path)
	
	var sb = PackedByteArray()
	sb.resize(8192)
	sb.fill(0)
	
	# Magic string: "Sony PS2 Memory Card Format " (28 bytes)
	var magic = "Sony PS2 Memory Card Format "
	for i in range(magic.length()):
		sb[i] = magic.unicode_at(i)
	
	# Version: "1.2.0.0" (12 bytes)
	var version = "1.2.0.0"
	for i in range(version.length()):
		sb[0x1C + i] = version.unicode_at(i)
	
	# Page size: 512
	sb.encode_u16(0x28, 512)
	# Pages per cluster: 2
	sb.encode_u16(0x2A, 2)
	# Pages per erase block: 16
	sb.encode_u16(0x2C, 16)
	# Unused: 0xFF00
	sb.encode_u16(0x2E, 0xFF00)
	# Clusters per card: 8192 (8MB)
	sb.encode_u32(0x30, 8192)
	# Allocatable cluster offset: 41
	sb.encode_u32(0x34, 41)
	# Allocatable cluster end: 8135
	sb.encode_u32(0x38, 8135)
	# Rootdir cluster: 0
	sb.encode_u32(0x3C, 0)
	# Good block 1: 1023
	sb.encode_u32(0x40, 1023)
	# Good block 2: 1022
	sb.encode_u32(0x44, 1022)
	# Indirect FAT cluster list: cluster 8 at offset 0x50
	sb.encode_u32(0x50, 8)
	for i in range(1, 32):
		sb.encode_u32(0x50 + (i * 4), 0xFFFFFFFF)
	# Bad erase block list: all 0xFFFFFFFF
	for i in range(32):
		sb.encode_u32(0xD0 + (i * 4), 0xFFFFFFFF)
	# Card type: 2
	sb[0x150] = 2
	# Card flags: 0x2B
	sb[0x151] = 0x2B
	
	# Fill remaining bytes with 0xFF
	for i in range(512, 8192):
		sb[i] = 0xFF
	
	if not FSM.write_file_bytes(superblock_path, sb):
		push_error("[GameSaveSubManager] Failed to write PCSX2 superblock: " + superblock_path)
		return false
	
	print("[GameSaveSubManager] PCSX2 superblock created successfully")
	return true

## Validates the PCSX2 superblock and creates it only if invalid or missing.
## Returns true if valid (or successfully created), false on error.
func ensure_pcsx2_superblock(memcard_path: String) -> bool:
	if validate_pcsx2_superblock(memcard_path):
		return true
	return create_pcsx2_superblock(memcard_path)

## Returns a human-readable sync status for the UI
func get_save_sync_status_text(game: GameResource, emulator_id: String) -> String:
	var records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
	if records.is_empty():
		return "Not synced"
	
	var latest = ""
	for rec in records:
		if rec.last_synced_at > latest:
			latest = rec.last_synced_at
	
	if latest == "":
		return "Not synced"
	
	var unix = parse_iso_timestamp(latest)
	if unix > 0:
		var now = Time.get_unix_time_from_system()
		var diff = int(now - unix)
		if diff < 60:
			return "Synced just now"
		elif diff < 3600:
			return "Synced %d min ago" % (diff / 60.0)
		elif diff < 86400:
			return "Synced %d hours ago" % (diff / 3600.0)
		else:
			return "Synced %d days ago" % (diff / 86400.0)
	
	return "Synced"
