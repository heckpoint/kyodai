extends Manager
class_name FirmwareSubManager

## Firmware readiness and download management

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FIRMWARE_STAGING_PREFIX := ".kyodai-extract-"

## TEMPORARY (pending a proper identity manager): azahar [System] keys forced
## after a force_pull identity install — online LLE modules on, region USA.
const AZAHAR_IDENTITY_CONFIG_EDITS: Array = [
	{"old": "(?m)^enable_required_online_lle_modules\\s*=.*$", "new": "enable_required_online_lle_modules = true", "regex": true},
	{"old": "(?m)^enable_required_online_lle_modules\\\\default\\s*=.*$", "new": "enable_required_online_lle_modules\\default = false", "regex": true},
	{"old": "(?m)^region_value\\s*=.*$", "new": "region_value = 1", "regex": true},
	{"old": "(?m)^region_value\\\\default\\s*=.*$", "new": "region_value\\default = false", "regex": true},
]
const AZAHAR_IDENTITY_CONFIG_APPENDS: Dictionary = {
	"enable_required_online_lle_modules\\default": "false",
	"enable_required_online_lle_modules": "true",
	"region_value\\default": "false",
	"region_value": "1",
}

## Firmware readiness cache to avoid repeated recursive directory scans
# key: "platform_slug:emulator_id", value: bool
var _firmware_ready_cache: Dictionary = {}

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

## Clears the firmware readiness cache for a specific platform/emulator.
func clear_firmware_cache(platform_slug: String, emulator_id: String, core_id: String = "") -> void:
	var key = platform_slug + ":" + emulator_id
	if core_id != "":
		key += ":" + core_id
	_firmware_ready_cache.erase(key)

## Clears the entire firmware readiness cache.
func clear_all_firmware_cache() -> void:
	_firmware_ready_cache.clear()
	_firmware_tree_cache.clear()

## Clears all cached firmware readiness entries for a given platform.
func clear_firmware_cache_for_platform(platform_slug: String) -> void:
	var prefix = platform_slug + ":"
	for key in _firmware_ready_cache.keys():
		if key.begins_with(prefix):
			_firmware_ready_cache.erase(key)
	# Firmware content may have changed under the dir: a stale file list would
	# report newly-downloaded BIOS as missing (or vice versa).
	_firmware_tree_cache.clear()

## Gets the firmware directory for an emulator
## Resolves paths with wildcards ({emulator_dir}, {app_data}, etc.)
## Optional core_id for core-specific firmware paths (e.g. RetroArch PCSX2).
func get_firmware_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var paths = emulator.get("paths", {})
	var firmware = paths.get("default_firmware", {})
	var config: Dictionary = firmware.get("_default", {})
	
	# For RetroArch, check core-specific firmware config first
	if emulator_id == "retroarch" and core_id != "" and platform_slug != "":
		var core_config = launch_manager.registry.get_core_config(emulator_id, platform_slug, core_id)
		var core_paths = core_config.get("paths", {})
		var core_firmware = core_paths.get("default_firmware", {})
		if not core_firmware.is_empty():
			config = core_firmware
	
	var directories = config.get("directories", {})
	
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return ""
	
	if dir.contains("{save_root}") or dir.contains("{system_root}"):
		# Root-anchored template: the resolver composes root + subtree.
		return RSM.compose_template(dir, emulator_id, platform_slug, core_id).get("path", "")
	
	# Config-first: a stated system_directory beats the JSON default.
	var resolution: Dictionary = RSM.resolve_firmware_dir(emulator_id, platform_slug, core_id)
	if resolution.get("source", "") == "config" and resolution.get("path", "") != "":
		return resolution.path
	
	# Resolve wildcards
	dir = FSM.resolve_emulator_path(dir, emulator_id, platform_slug)
	return dir.rstrip("/") + "/"

## Cache-only variant of is_platform_firmware_ready: returns 1/0 for a cached
## result, or -1 when the lookup has never run. Callers on the main thread use
## this to avoid triggering the recursive filesystem walk; caches are warmed
## asynchronously on the DB thread.
func is_platform_firmware_ready_cached(platform_slug: String, emulator_id: String, core_id: String = "") -> int:
	var cache_key = platform_slug + ":" + emulator_id
	if core_id != "":
		cache_key += ":" + core_id
	if not _firmware_ready_cache.has(cache_key):
		return -1
	return 1 if _firmware_ready_cache[cache_key] else 0

## Checks if firmware is ready for a platform/emulator
## Returns true if firmware directory exists and has any of the expected files
## Searches recursively through subdirectories
func is_platform_firmware_ready(platform_slug: String, emulator_id: String, core_id: String = "") -> bool:
	var cache_key = platform_slug + ":" + emulator_id
	if core_id != "":
		cache_key += ":" + core_id
	if _firmware_ready_cache.has(cache_key):
		if not _is_force_pull_firmware(platform_slug):
			return _firmware_ready_cache[cache_key]
		# force_pull: the install marker is the cheap authoritative gate. A
		# cached hit must not survive its removal (e.g. azahar reinstall/OOBE
		# wiping the pulled identity), so re-verify before trusting the cache.
		var cached_dir := get_firmware_directory(emulator_id, platform_slug, core_id)
		if cached_dir != "" and FSM.file_exists(_marker_path(cached_dir)):
			return true
		_firmware_ready_cache.erase(cache_key)
	
	var firmware_dir = get_firmware_directory(emulator_id, platform_slug, core_id)
	print("[FirmwareManager] is_platform_firmware_ready: firmware_dir=" + firmware_dir)
	if firmware_dir == "":
		# No firmware directory configured, assume not needed
		_firmware_ready_cache[cache_key] = true
		return true
	
	if not FSM.dir_exists(firmware_dir):
		print("[FirmwareManager] is_platform_firmware_ready: firmware_dir does not exist")
		_firmware_ready_cache[cache_key] = false
		return false
	
	# Get expected files from platform configuration
	var platform_config = launch_manager.registry._platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	var expected_files = firmware_config.get("expected_files", [])
	
	print("[FirmwareManager] is_platform_firmware_ready: expected_files=" + str(expected_files))
	
	# No expected files means no BIOS needed for this platform
	if expected_files.is_empty():
		_firmware_ready_cache[cache_key] = true
		return true
	
	# Check if any expected file exists. Direct relative-path hits first (one
	# stat each - the common case); only genuinely-missing files then share a
	# SINGLE bounded tree walk, matched in memory. The old one-full-walk-per-
	# file search cost ~2s per missing file on a 3.4k-entry RetroArch/system
	# tree, and PSX alone has 7 expected files (~14s per cold check).
	var found_file := ""
	for expected_file in expected_files:
		if FSM.file_exists(FSM.join_paths(firmware_dir, expected_file)):
			found_file = expected_file
			break
	if found_file == "":
		var tree := _firmware_tree_paths(firmware_dir)
		for expected_file in expected_files:
			var suffix = "/" + expected_file.replace("\\", "/")
			for tree_path in tree:
				if tree_path.ends_with(suffix):
					found_file = expected_file
					break
			if found_file != "":
				break

	if found_file != "":
		if not _is_force_pull_firmware(platform_slug) \
				or FSM.file_exists(_marker_path(firmware_dir)):
			print("[FirmwareManager] is_platform_firmware_ready: found " + found_file)
			_firmware_ready_cache[cache_key] = true
			return true

	print("[FirmwareManager] is_platform_firmware_ready: no expected files found")
	_firmware_ready_cache[cache_key] = false
	return false

# Session cache of full file-path lists per firmware dir: every RetroArch-core
# platform shares /RetroArch/system, so without this each platform re-walks
# the same tree on a cold pass. Cleared alongside _firmware_ready_cache.
var _firmware_tree_cache: Dictionary = {}

## File paths under a firmware dir, from cache or one fresh bounded walk.
func _firmware_tree_paths(firmware_dir: String) -> Array:
	if _firmware_tree_cache.has(firmware_dir):
		return _firmware_tree_cache[firmware_dir]
	var tree := _collect_file_paths(firmware_dir)
	_firmware_tree_cache[firmware_dir] = tree
	return tree

## One bounded recursive walk collecting every file path under dir.
func _collect_file_paths(dir: String, depth: int = 0) -> Array:
	var out: Array = []
	if depth > 5:
		return out
	for entry in FSM.list_dir(dir):
		if entry == "." or entry == ".." or entry.begins_with(FIRMWARE_STAGING_PREFIX):
			continue
		var full_path = FSM.join_paths(dir, entry)
		if FSM.dir_exists(full_path):
			out.append_array(_collect_file_paths(full_path, depth + 1))
		else:
			out.append(full_path)
	return out

## Renames known firmware filename variants to their canonical names, per the
## platform's firmware "rename" map (variant basename -> canonical basename).
## Each entry no-ops when the variant is absent or the canonical file already
## exists, so mixed or already-canonical payloads pass through untouched.
func _apply_firmware_renames(firmware_dir: String, platform_slug: String) -> void:
	var platform_config: Dictionary = launch_manager.registry._platforms_data.get(platform_slug, {})
	var rename_map: Dictionary = platform_config.get("firmware", {}).get("rename", {})
	if rename_map.is_empty():
		return
	for source_name in rename_map:
		var target_name := str(rename_map[source_name])
		var target_path := FSM.join_paths(firmware_dir, target_name)
		if FSM.file_exists(target_path):
			continue
		var source_path := _find_file_path_recursive(firmware_dir, str(source_name))
		if source_path == "":
			continue
		if FSM.move(source_path, target_path):
			print("[FirmwareManager] Canonicalized firmware name: " + source_path + " -> " + target_path)
		else:
			push_warning("[FirmwareManager] Failed to rename " + source_path + " to " + target_path)

## Recursive search returning the full path of the first match, or "".
## Basename comparison is case-insensitive; servers and filesystems vary.
func _find_file_path_recursive(dir: String, filename: String) -> String:
	if not FSM.dir_exists(dir):
		return ""
	var entries = FSM.list_dir(dir)
	for entry in entries:
		if entry == "." or entry == ".." or entry.begins_with(FIRMWARE_STAGING_PREFIX):
			continue
		var full_path = FSM.join_paths(dir, entry)
		if entry.to_lower() == filename.to_lower() and FSM.file_exists(full_path):
			return full_path
		if FSM.dir_exists(full_path):
			var found := _find_file_path_recursive(full_path, filename)
			if found != "":
				return found
	return ""

func _on_firmware_download_complete(success: bool, download_error: String, _notification_id: int, temp_path: String, firmware_dir: String, platform_slug: String, emulator_id: String, callback: Callable, _last_progress_mb: Array):
	SystemManager.notifications.dismiss_notification(_notification_id)
	
	if not success:
		push_error("[FirmwareManager] Failed to download firmware: " + download_error)
		if FSM.file_exists(temp_path):
			FSM.delete_file(temp_path)
		if callback.is_valid():
			callback.call(false, download_error)
		return
	
	var staging_dir := FSM.join_paths(firmware_dir, FIRMWARE_STAGING_PREFIX + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))
	clear_firmware_cache_for_platform(platform_slug)
	print("[FirmwareManager] Firmware downloaded, extracting to isolated staging: " + staging_dir)

	# Normalize only this archive's output. Existing firmware (especially an
	# emulator-generated force_pull identity) must not satisfy the new anchors.
	FSM.extract_archive_async(
		temp_path,
		staging_dir,
		"Firmware for " + platform_slug,
		false,
		func(_info: Dictionary): pass,
		func(extract_success: bool, error_msg: String):
			if not extract_success:
				_retry_or_fail_firmware_extract(temp_path, staging_dir, firmware_dir, platform_slug, emulator_id, callback, error_msg)
			else:
				_finish_firmware_extract(true, error_msg, firmware_dir, platform_slug, emulator_id, callback, temp_path.get_file(), temp_path, staging_dir)
	, true, false)

## Finishes firmware extraction in isolated staging, then commits a validated
## payload into the live emulator firmware directory (also used by SAF retry).
func _finish_firmware_extract(extract_success: bool, error_msg: String, firmware_dir: String, platform_slug: String, emulator_id: String, callback: Callable, artifact_name: String = "", source_archive: String = "", staging_dir: String = "") -> void:
	if not extract_success:
		_cleanup_firmware_staging(staging_dir)
		clear_firmware_cache_for_platform(platform_slug)
		push_error("[FirmwareManager] Failed to extract firmware to: " + firmware_dir + ": " + error_msg)
		launch_manager.firmware_download_completed.emit(platform_slug, false)
		if callback.is_valid():
			callback.call(false, error_msg)
		return

	# Server zips sometimes wrap the payload in folder(s) (e.g. bios/). Locate
	# and hoist the expected payload before reporting the install as successful.
	var expected := get_platform_firmware_expected_files(platform_slug)
	var scan_complete := false
	var snapshot: Array = []
	if not expected.is_empty():
		var norm: Dictionary = FSM.normalize_extraction_root(staging_dir, expected)
		scan_complete = bool(norm.get("scan_complete", false))
		snapshot = norm.get("entries", [])
		var status := str(norm.get("status", ""))
		if not ["normalized", "already_canonical"].has(status):
			var message := "Downloaded firmware does not contain a usable expected layout: " + str(norm.get("error", status))
			_cleanup_firmware_staging(staging_dir)
			clear_firmware_cache_for_platform(platform_slug)
			push_error("[FirmwareManager] " + message + " (staging: " + staging_dir + ")")
			launch_manager.firmware_download_completed.emit(platform_slug, false)
			if callback.is_valid():
				callback.call(false, message)
			return
		if status == "normalized":
			print("[FirmwareManager] Hoisted firmware payload " + str(norm.get("depth", 0)) + " level(s) inside isolated staging")

	# Only the isolated, validated payload enters the live firmware tree.
	var commit := FSM.merge_extraction_payload(staging_dir, firmware_dir, scan_complete, snapshot)
	if str(commit.get("status", "")) != "committed":
		var message := "Could not commit extracted firmware: " + str(commit.get("error", "unknown error"))
		if bool(commit.get("preserve_source", false)):
			push_warning("[FirmwareManager] Preserving extraction recovery data at " + str(commit.get("recovery_path", staging_dir)))
		else:
			_cleanup_firmware_staging(staging_dir)
		clear_firmware_cache_for_platform(platform_slug)
		push_error("[FirmwareManager] " + message)
		launch_manager.firmware_download_completed.emit(platform_slug, false)
		if callback.is_valid():
			callback.call(false, message)
		return

	# Canonicalize known filename variants after the staged payload is committed.
	_apply_firmware_renames(firmware_dir, platform_slug)

	if _is_force_pull_firmware(platform_slug):
		var marker := {
			"artifact": artifact_name,
			"applied_at": int(Time.get_unix_time_from_system()),
		}
		if not FSM.write_file(_marker_path(firmware_dir), JSON.stringify(marker)):
			push_warning("[FirmwareManager] Could not write install marker to " + _marker_path(firmware_dir))
		if emulator_id == "azahar":
			_apply_identity_config(firmware_dir)

	if source_archive != "" and FSM.file_exists(source_archive):
		FSM.delete_file(source_archive)
	clear_firmware_cache_for_platform(platform_slug)
	print("[FirmwareManager] Firmware successfully installed for " + platform_slug)
	launch_manager.firmware_download_completed.emit(platform_slug, true)
	if callback.is_valid():
		callback.call(true, "Firmware installed")

func _cleanup_firmware_staging(staging_dir: String) -> void:
	# Never turn an error path into deletion of the live firmware root.
	if staging_dir.get_file().begins_with(FIRMWARE_STAGING_PREFIX) and FSM.dir_exists(staging_dir):
		if FSM.extraction_tree_has_symlinks(staging_dir):
			push_warning("[FirmwareManager] Leaving unsafe staging in place rather than recursively deleting links: " + staging_dir)
			return
		FSM.delete_dir_recursive(staging_dir)

## Android blocks other apps' /Android/data even with all-files access; a
## one-time document-tree grant unlocks it. Prompt just-in-time and retry once.
func _retry_or_fail_firmware_extract(temp_path: String, staging_dir: String, firmware_dir: String, platform_slug: String, emulator_id: String, callback: Callable, error_msg: String) -> void:
	if SystemManager.platform.access_route(firmware_dir) != PlatformSubManager.AccessRoute.NONE:
		_finish_firmware_extract(false, error_msg, firmware_dir, platform_slug, emulator_id, callback, temp_path.get_file(), temp_path, staging_dir)
		return

	print("[FirmwareManager] Extraction into restricted path needs folder access grant, prompting...")
	SystemManager.platform.ensure_android_data_access(func(granted: bool):
		if granted:
			if FSM.extraction_tree_has_symlinks(staging_dir):
				# Quarantine the unsafe tree and retry into a fresh empty directory.
				staging_dir = FSM.join_paths(firmware_dir, FIRMWARE_STAGING_PREFIX + str(Time.get_ticks_msec()) + "_retry_" + str(randi() % 1000))
			else:
				_cleanup_firmware_staging(staging_dir)
			FSM.extract_archive_async(
				temp_path,
				staging_dir,
				"Firmware for " + platform_slug,
				false,
				func(_info: Dictionary): pass,
				func(retry_success: bool, retry_error: String):
					_finish_firmware_extract(retry_success, retry_error, firmware_dir, platform_slug, emulator_id, callback, temp_path.get_file(), temp_path, staging_dir)
			, true, false)
		else:
			_finish_firmware_extract(false, error_msg, firmware_dir, platform_slug, emulator_id, callback, temp_path.get_file(), temp_path, staging_dir)
	, firmware_dir)

## Returns the list of expected firmware files for a platform (empty if none).
func get_platform_firmware_expected_files(platform_slug: String) -> Array:
	var platform_config = launch_manager.registry._platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	return firmware_config.get("expected_files", [])

## Returns true when the platform's firmware entry is flagged force_pull:
## readiness then also requires kyodai's own install marker, so content the
## emulator generated itself (e.g. azahar OOBE identity) cannot satisfy it.
func _is_force_pull_firmware(platform_slug: String) -> bool:
	var platform_config = launch_manager.registry._platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	return bool(firmware_config.get("force_pull", false))

## Re-forces post-install config for force_pull platforms whose firmware is
## already installed. Idempotent: the emulator can regenerate its config at
## any time (e.g. azahar OOBE after a reinstall), so applying only after
## extraction is not enough.
func apply_force_pull_config(platform_slug: String, emulator_id: String) -> void:
	if emulator_id != "azahar" or not _is_force_pull_firmware(platform_slug):
		return
	var firmware_dir := get_firmware_directory(emulator_id, platform_slug)
	if firmware_dir == "":
		return
	_apply_identity_config(firmware_dir)

## Marker kyodai stamps after installing force_pull firmware. Lives at the
## firmware dir root so it dies with the directory it describes.
func _marker_path(firmware_dir: String) -> String:
	return firmware_dir.rstrip("/") + "/.kyodai-identity"

## TEMPORARY (pending a proper identity manager): forces the azahar settings
## Pretendo needs into the azahar config under the firmware dir. Prefers an
## existing config.ini (newer azahar / Android), otherwise qt-config.ini,
## creating it if azahar has never run.
func _apply_identity_config(firmware_dir: String) -> void:
	var config_dir := firmware_dir.rstrip("/") + "/config/"
	var config_path := config_dir + "qt-config.ini"
	var alt_path := config_dir + "config.ini"
	if not FSM.file_exists(config_path) and FSM.file_exists(alt_path):
		config_path = alt_path
	if CSM.edit_text(config_path, AZAHAR_IDENTITY_CONFIG_EDITS, true, AZAHAR_IDENTITY_CONFIG_APPENDS, "System"):
		print("[FirmwareManager] Applied azahar identity config to " + config_path)
	else:
		push_warning("[FirmwareManager] Failed to apply azahar identity config to " + config_path)

## Sets up firmware for a platform by downloading from RomM
## This should be called during platform sync
## callback(success: bool, message: String)
func setup_platform_firmware(platform_slug: String, emulator_id: String, callback: Callable = Callable(), core_id: String = "") -> void:
	print("[FirmwareManager] Checking firmware for " + platform_slug + " / " + emulator_id)

	# Enforce kyodai-managed config paths before resolving the download target:
	# on a fresh install the config has no stated keys yet, so resolution would
	# fall back to the emulator's built-in default dir and the download would
	# be orphaned once launch-time enforcement repoints the emulator.
	RSM.enforce_paths(emulator_id, platform_slug, core_id)

	# Check if firmware is already ready
	if is_platform_firmware_ready(platform_slug, emulator_id, core_id):
		print("[FirmwareManager] Firmware already ready for " + platform_slug)
		apply_force_pull_config(platform_slug, emulator_id)
		if callback.is_valid():
			callback.call(true, "Firmware already installed")
		return
	
	# Get firmware directory
	var firmware_dir = get_firmware_directory(emulator_id, platform_slug, core_id)
	if firmware_dir == "":
		print("[FirmwareManager] No firmware directory configured for " + emulator_id)
		if callback.is_valid():
			callback.call(true, "No firmware needed")
		return
	
	print("[FirmwareManager] Firmware needed for " + platform_slug + ", querying RomM...")
	
	# Query RomM for platform firmware
	SystemManager.network.fetch_platform_firmware(platform_slug, func(platform_data: Dictionary, error: String):
		if error != "":
			push_error("[FirmwareManager] Failed to fetch firmware info: " + error)
			if callback.is_valid():
				callback.call(false, error)
			return
		
		var firmware_list = platform_data.get("firmware", [])
		if firmware_list.is_empty():
			print("[FirmwareManager] No firmware available for " + platform_slug + " on RomM")
			# Cache the platform as ready so callers don't re-enter the firmware
			# download loop every time the launch path is re-evaluated.
			var cache_key = platform_slug + ":" + emulator_id
			if core_id != "":
				cache_key += ":" + core_id
			_firmware_ready_cache[cache_key] = true
			if callback.is_valid():
				callback.call(true, "No firmware on server")
			return
		
		print("[FirmwareManager] Found " + str(firmware_list.size()) + " firmware file(s) for " + platform_slug)
		
		# For now, download the first firmware file (should be the zip)
		var firmware = firmware_list[0]
		var firmware_id = firmware.get("id", 0)
		var file_name = firmware.get("file_name", "")
		
		if firmware_id == 0 or file_name == "":
			push_error("[FirmwareManager] Invalid firmware data for " + platform_slug)
			if callback.is_valid():
				callback.call(false, "Invalid firmware data")
			return

		if FSM.sanitize_server_filename(file_name) == "":
			push_error("[FirmwareManager] Rejected unsafe firmware file name from server: '" + file_name + "'")
			if callback.is_valid():
				callback.call(false, "Unsafe firmware file name")
			return

		# Download to temp location first
		var temp_path = "user://temp/firmware/" + file_name
		FSM.make_dir_recursive("user://temp/firmware")
		if FSM.file_exists(temp_path):
			FSM.delete_file(temp_path)

		# Pre-flight disk space check (10% margin) when RomM reports the file size
		var firmware_size: int = firmware.get("file_size_bytes", 0)
		if firmware_size > 0:
			var required_bytes := int(firmware_size * 1.1)
			var space_left := FSM.get_space_left("user://temp/firmware")
			if space_left >= 0 and space_left < required_bytes:
				var needed_mb := int(required_bytes / (1024.0 * 1024.0))
				var free_mb := int(space_left / (1024.0 * 1024.0))
				push_error("[FirmwareManager] Insufficient disk space for firmware: need ~" + str(needed_mb) + " MB, have " + str(free_mb) + " MB")
				SystemManager.notifications.show_notification(
					"Not enough disk space to download firmware for " + platform_slug + " (need ~" + str(needed_mb) + " MB, " + str(free_mb) + " MB free)",
					SystemManager.notifications.Type.ERROR,
					null,
					10.0
				)
				if callback.is_valid():
					callback.call(false, "Insufficient disk space")
				return

		print("[FirmwareManager] Downloading firmware: " + file_name)
		
		# Show progress notification
		var _firmware_notification_id = SystemManager.notifications.show_notification(
			"Downloading firmware for " + platform_slug + "...",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			Callable(),
			Callable(),
			true,  # pulsing
			true  # pinned
		)
		
		var _last_progress_mb = [-1]
		
		SystemManager.network.download_firmware_zip(
			firmware_id,
			file_name,
			temp_path,
			_on_firmware_download_complete.bind(_firmware_notification_id, temp_path, firmware_dir, platform_slug, emulator_id, callback, _last_progress_mb),
			func(size_mb: int):
				if size_mb != _last_progress_mb[0]:
					_last_progress_mb[0] = size_mb
					SystemManager.notifications.update_notification_text(
						_firmware_notification_id,
						"Downloading firmware for " + platform_slug + "... " + str(size_mb) + " MB"
					)
		)
	)
