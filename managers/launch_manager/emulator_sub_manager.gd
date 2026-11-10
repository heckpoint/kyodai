extends Manager
class_name EmulatorSubManager

## Emulator install/update/download management

const DEBUG_LOG: bool = false
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const EmulatorExtraction = preload("res://utils/filesystem/emulator_extraction.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
const EXTRACTION_STAGING_PREFIX := ".kyodai-extract-"

# Track installation progress for UI display only
var _emulator_install_progress: Dictionary = {}  # emulator_id -> progress text for UI

## Unified download tracking for emulator downloads
# item_id -> {emulator_id, context, extract_to, strip_top_directory, callback}
var _pending_emulator_downloads: Dictionary = {}

## Pending emulator versions resolved during install but not yet persisted.
## Key: emulator_id, Value: version string. Saved only when install completes.
var _pending_emulator_version: Dictionary = {}

## When true, install-step handlers will execute even if their outputs already exist.
## Set for updates/reinstalls; cleared on completion or failure.
var _force_install_step: Dictionary = {}

## Per-emulator count of how many times each install step has executed in the
## current chain. A healthy chain visits each step once or twice (retries); a
## step that keeps re-executing indicates a retry ping-pong between steps
## (e.g. skip-forward vs retry-backward on a missing input), which would
## otherwise recurse synchronously until the stack overflows.
var _install_step_executions: Dictionary = {}
var _install_grant_prompt_pending: Dictionary = {}  # emulator_id -> true while the SAF picker is up
const MAX_STEP_EXECUTIONS := 5

## Config guard state: emulator_id -> Array of {original, backup}. Populated
## by _begin_config_guard() when an update/reinstall starts, consumed by
## _restore_config_guard() at every terminal point.
var _config_guard: Dictionary = {}

## Validation cache to avoid redundant file system operations
# emulator_id -> {result: Dictionary, timestamp: int, step_results: Dictionary}
var _validation_cache: Dictionary = {}
## Long enough that back-to-back launches and card refreshes don't re-scan
## every install step (each is a filesystem/package probe, possibly via SAF).
## Stale entries self-heal after the TTL; state-changing events (install
## steps, extractions, resume-time pending-launch reconciliation) erase
## targeted entries instead of clearing the whole cache.
const VALIDATION_CACHE_TTL_MS: int = 60000
var _validation_cache_mutex: Mutex = Mutex.new()  # get_install_progress is called from main + DB threads

## Emitted when an install step begins executing (step_index is 0-based).
signal install_step_started(emulator_id: String, step_index: int, total_steps: int)
## Emitted when the final install step completes successfully.
signal install_steps_finished(emulator_id: String)
## Emitted when the install chain aborts synchronously (async download/extract
## failures surface via LaunchManager.emulator_extraction_completed instead).
signal install_steps_failed(emulator_id: String, reason: String)

## When true (an update-all session is active), per-step download/extraction
## notifications are suppressed in favor of the session's aggregate snackbar.
var suppress_step_notifications: bool = false

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

## Clears the validation cache. Call after external install state changes (e.g., APK install).
func clear_validation_cache() -> void:
	_validation_cache_mutex.lock()
	_validation_cache.clear()
	_validation_cache_mutex.unlock()

func _erase_validation_cache(emulator_id: String) -> void:
	_validation_cache_mutex.lock()
	_validation_cache.erase(emulator_id)
	_validation_cache_mutex.unlock()

## Public targeted invalidation for callers that know one emulator's install
## state may have changed (e.g. post-APK-install checks). Prefer this over
## clear_validation_cache() so unrelated emulators keep their cached scans.
func erase_validation_cache(emulator_id: String) -> void:
	_erase_validation_cache(emulator_id)

## Reconciles pending launches after potential APK installations.
## Call on app resume. Never drops a pending launch without either resuming it
## or releasing its in-flight guard via LaunchManager._abort_pending_launches.
func clear_stale_pending_launches() -> void:
	for emulator_id in launch_manager._pending_launches.keys():
		var emulator = launch_manager.registry.get_emulator(emulator_id)
		if emulator.is_empty():
			launch_manager._abort_pending_launches(emulator_id, "Emulator unavailable")
			continue
		# If the post-install permissions reminder is still open, its "Got it"
		# dismissal (LaunchManager.on_install_reminder_dismissed) owns the
		# continuation - leave the pending launch queued.
		if launch_manager._open_install_reminders.has(emulator_id):
			continue
		# The pending emulator may have been APK-installed while backgrounded;
		# drop its cached scan so the resumed launch re-validates fresh.
		_erase_validation_cache(emulator_id)
		var install_steps = emulator.get("install", [])
		var all_valid = true
		for i in range(install_steps.size()):
			if not _validate_install_step(emulator_id, i, install_steps):
				all_valid = false
				break
		if all_valid:
			# Installed while backgrounded and no reminder is waiting on the
			# user (e.g. they already dismissed it) - resume the launch now.
			print("[EmulatorManager] Resuming pending launch for emulator installed while backgrounded: " + emulator_id)
			launch_manager._continue_pending_launches(emulator_id)
		# Not fully installed: leave queued - the user is still mid-install.

## Gets the current installation progress text for UI display
func get_emulator_install_progress(emulator_id: String) -> String:
	return _emulator_install_progress.get(emulator_id, "")

## Checks whether the stored progress text indicates an extraction is in progress.
func is_install_progress_extracting(emulator_id: String) -> bool:
	if _emulator_install_progress.has(emulator_id):
		var progress_str = _emulator_install_progress[emulator_id]
		return progress_str.find("Extracting") >= 0 or progress_str.find("extracting") >= 0
	return false

## Checks if emulator is currently being extracted
func is_emulator_extracting(emulator_id: String) -> bool:
	# Check SystemManager.download for any active extraction for this emulator
	for item in SystemManager.download.get_active():
		if item.name == emulator_id and item.status == "extracting":
			return true
	return false

## Called when SystemManager.download completes an extraction
## Registry-based validation handles actual installation checking
func _on_download_manager_extraction_completed(item_id: String, success: bool, extract_dir: String):
	# Check if this extraction has a pending callback (registry step tracking)
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		_pending_emulator_downloads.erase(item_id)
		
		# Clear validation cache for this emulator
		if task_info.has("emulator_id"):
			_erase_validation_cache(task_info.emulator_id)
		
		if task_info.has("callback"):
			task_info.callback.call(success, "")
			return
	
	# Find which emulator this extraction belongs to (fallback for non-registry extractions)
	for emulator_id in _emulator_install_progress.keys():
		if extract_dir.begins_with(launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")):
			# Clear validation cache
			_erase_validation_cache(emulator_id)
			
			if success:
				_emulator_install_progress[emulator_id] = ""
				launch_manager.emulator_extraction_completed.emit(emulator_id, true)
			else:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			
			# Fallback: dismiss any lingering extraction notification for this emulator.
			# This handles cases where the notification dismissal failed while backgrounded.
			# Extraction notifications are progress snackbars whose text starts with
			# the emulator name (see _get_step_display_name); dismiss only that one.
			if SystemManager.notifications:
				var emulator_name: String = RegistrySubManager.get_emulator_display_name(launch_manager.registry.get_emulator(emulator_id), emulator_id)
				SystemManager.notifications.dismiss_progress_notification_by_prefix(emulator_name + " - ")
			
			return

## Normalizes one archive's isolated output using its registry layout policy.
func _normalize_extracted_directory(staging_dir: String, extract_config: Dictionary) -> Dictionary:
	return FSM.normalize_extraction_layout(staging_dir, EmulatorExtraction.layout_options(extract_config))

## Validate every anchor representable inside staging before any live files are
## changed. Other install checks (packages, manifests, etc.) run after commit.
func _validate_staged_extraction(staging_dir: String, extract_config: Dictionary) -> bool:
	for anchor in EmulatorExtraction.expected_anchors(extract_config):
		if not _staged_anchor_exists(staging_dir, str(anchor)):
			return false
	return true

func _staged_anchor_exists(staging_dir: String, anchor: String) -> bool:
	if not anchor.contains("*") and not anchor.contains("?"):
		return FSM.file_exists(FSM.join_paths(staging_dir, anchor))
	var parent := anchor.get_base_dir()
	var directory := staging_dir if parent == "." else FSM.join_paths(staging_dir, parent)
	var pattern := anchor.get_file()
	for entry in FSM.list_dir(directory):
		if entry.match(pattern) and FSM.file_exists(FSM.join_paths(directory, entry)):
			return true
	return false

func _new_extraction_staging_dir(extract_dir: String) -> String:
	return FSM.join_paths(
		extract_dir.get_base_dir(),
		EXTRACTION_STAGING_PREFIX + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))

func _cleanup_extraction_staging(staging_dir: String) -> void:
	if staging_dir == "" or not staging_dir.get_file().begins_with(EXTRACTION_STAGING_PREFIX):
		return
	if not FSM.dir_exists(staging_dir):
		return
	if FSM.extraction_tree_has_symlinks(staging_dir):
		push_warning("[EmulatorManager] Leaving unsafe extraction staging in place: " + staging_dir)
		return
	FSM.delete_dir_recursive(staging_dir)

func _fail_extraction(emulator_id: String, progress_message: String, staging_dir: String = "") -> void:
	_cleanup_extraction_staging(staging_dir)
	_emulator_install_progress[emulator_id] = progress_message
	_end_force_install(emulator_id)
	launch_manager.emulator_extraction_completed.emit(emulator_id, false)

func download_emulator(emulator_id: String) -> bool:
	# Check if already downloading/extracting. Clean up stale entries that no
	# longer correspond to an active or queued download item (can happen if a
	# previous attempt crashed or the completion signal was missed).
	var stale_ids: Array[String] = []
	for item_id in _pending_emulator_downloads:
		var task = _pending_emulator_downloads[item_id]
		if task.emulator_id == emulator_id:
			var still_live = false
			for item in SystemManager.download.get_active():
				if item.id == item_id:
					still_live = true
					break
			if not still_live:
				for item in SystemManager.download.get_queued():
					if item.id == item_id:
						still_live = true
						break
			if not still_live:
				stale_ids.append(item_id)
	
	for stale_id in stale_ids:
		push_warning("[EmulatorManager] Cleaning stale pending download entry: " + stale_id)
		_pending_emulator_downloads.erase(stale_id)
		_erase_validation_cache(emulator_id)
	
	for item_id in _pending_emulator_downloads:
		if _pending_emulator_downloads[item_id].emulator_id == emulator_id:
			return false
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	# Get install steps from new step-based format
	var install_steps = emulator.get("install", [])
	if install_steps.is_empty():
		push_error("[EmulatorManager] No install steps defined for: " + emulator_id)
		return false
	
	# Ensure emulator directory exists before starting install
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
	if not FSM.dir_exists(emulator_dir):
		print("[EmulatorManager] Creating emulator directory: " + emulator_dir)
		if not FSM.make_dir_recursive(emulator_dir):
			push_error("[EmulatorManager] Failed to create emulator directory: " + emulator_dir)
			return false
		print("[EmulatorManager] Successfully created emulator directory")
	
	return _execute_install_steps(emulator_id, emulator, install_steps)

## Re-runs all non-download install steps to repair/refresh config files.
## Skips step 0 (download) since the emulator binary is already present.
## Forces re-creation of portable.txt, INIs, superblocks, etc.
## User-invoked repair intentionally overwrites configs; the config guard
## does not apply here.
func repair_emulator_config(emulator_id: String) -> bool:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	var install_steps = emulator.get("install", [])
	if install_steps.size() <= 1:
		push_error("[EmulatorManager] No config steps to repair for: " + emulator_id)
		return false
	
	# Force all steps to re-apply (overwrite existing config files)
	_force_install_step[emulator_id] = true
	RSM.invalidate_enforce_memo(emulator_id)
	
	# Start from step 1 (skip download)
	print("[EmulatorManager] Repairing config for " + emulator_id + " from step 1")
	return _execute_install_step(emulator_id, 1)

## Returns the on-disk backup directory for an in-progress update guard.
func _config_guard_dir(emulator_id: String) -> String:
	return "user://backups/" + emulator_id

## Snapshots user config files before an update/reinstall overwrites them.
## The preserve-list is built from the emulator's resolution config candidates
## and its create_files install seeds; every existing file is copied to
## user://backups/<emulator_id>/. The update then overwrites everything
## and _restore_config_guard() puts the configs back afterwards.
## No-op on Android: APK updates go through the package manager and preserve
## app-private data, so there is nothing to guard.
func _begin_config_guard(emulator_id: String) -> void:
	if SystemManager.platform.is_android():
		return
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return
	var platform_name: String = SystemManager.platform.get_platform_name().to_lower()

	var candidates: Array = []
	for candidate in emulator.get("resolution", {}).get("config_candidates", {}).get(platform_name, []):
		candidates.append(str(candidate))
	for step in emulator.get("install", []):
		var platform_config = launch_manager.registry._get_step_platform_config(step)
		if platform_config.get("action_type", "") != "create_files":
			continue
		for file_entry in platform_config.get("files", []):
			if typeof(file_entry) == TYPE_STRING:
				candidates.append(file_entry)
			elif typeof(file_entry) == TYPE_DICTIONARY:
				candidates.append(str(file_entry.get("name", "")))

	var backup_root := _config_guard_dir(emulator_id)
	if FSM.dir_exists(backup_root):
		FSM.delete_dir_recursive(backup_root)

	var preserved: Array = []
	var seen := {}
	var index := 0
	for candidate in candidates:
		if candidate == "":
			continue
		var original := FSM.resolve_emulator_path(candidate, emulator_id)
		if original == "" or seen.has(original) or not FSM.file_exists(original):
			continue
		seen[original] = true
		var backup := backup_root + "/" + str(index) + "_" + original.get_file()
		index += 1
		if FSM.copy_file(original, backup):
			preserved.append({"original": original, "backup": backup})
		else:
			push_warning("[EmulatorManager] Config guard: failed to back up " + original)

	if preserved.is_empty():
		return
	_config_guard[emulator_id] = preserved
	print("[EmulatorManager] Config guard: preserved %d config file(s) for %s" % [preserved.size(), emulator_id])

## Restores the configs preserved by _begin_config_guard() over whatever the
## update/reinstall wrote, then drops the backup dir. No-op without a guard
## (and never runs on Android, where _begin_config_guard is a no-op).
func _restore_config_guard(emulator_id: String) -> void:
	if not _config_guard.has(emulator_id):
		return
	var preserved: Array = _config_guard[emulator_id]
	_config_guard.erase(emulator_id)
	var restored := 0
	for entry in preserved:
		if FSM.copy_file(entry.backup, entry.original):
			restored += 1
		else:
			push_warning("[EmulatorManager] Config guard: failed to restore " + entry.original)
	FSM.delete_dir_recursive(_config_guard_dir(emulator_id))
	print("[EmulatorManager] Config guard: restored %d/%d config file(s) for %s" % [restored, preserved.size(), emulator_id])

## Clears the force-install flag at a terminal point, restoring any configs
## preserved by _begin_config_guard() first (update/reinstall flows only).
func _end_force_install(emulator_id: String) -> void:
	_restore_config_guard(emulator_id)
	_force_install_step.erase(emulator_id)
	_install_step_executions.erase(emulator_id)

## Executes a single install step by index
func _execute_install_step(emulator_id: String, step_index: int) -> bool:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if DEBUG_LOG: print("[EmulatorManager] _execute_install_step: emulator=%s step_index=%d" % [emulator_id, step_index])
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)
	var install_steps = emulator.get("install", [])
	
	if step_index >= install_steps.size():
		# All steps completed successfully
		_install_step_executions.erase(emulator_id)
		_create_emulator_save_directory(emulator_id)
		_emulator_install_progress[emulator_id] = ""
		# Persist the version resolved during the first download step now that the
		# install is fully complete. This avoids marking an emulator updated when a
		# download or extraction actually failed partway through.
		if _pending_emulator_version.has(emulator_id):
			_save_emulator_version(emulator_id, _pending_emulator_version[emulator_id])
			_pending_emulator_version.erase(emulator_id)
		_end_force_install(emulator_id)
		install_steps_finished.emit(emulator_id)
		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		return true
	
	var step = install_steps[step_index]
	var step_name = step.get("step", "")
	var platform_config = launch_manager.registry._get_step_platform_config(step)

	# Retry-loop guard: bail out before a step ping-pong can overflow the stack.
	var exec_counts: Dictionary = _install_step_executions.get_or_add(emulator_id, {})
	exec_counts[step_index] = int(exec_counts.get(step_index, 0)) + 1
	if exec_counts[step_index] > MAX_STEP_EXECUTIONS:
		push_error("[EmulatorManager] Install step '" + step_name + "' executed " + str(exec_counts[step_index]) + " times for " + emulator_id + " - aborting (retry loop detected)")
		_install_step_executions.erase(emulator_id)
		_end_force_install(emulator_id)
		install_steps_failed.emit(emulator_id, "Install retry loop detected")
		return false

	if platform_config.is_empty():
		# Step is scoped to another OS (e.g. the linux-only chmod step): skip it
		# instead of failing the install on a platform where it never applies.
		if not launch_manager.registry.step_applies_to_platform(step):
			print("[EmulatorManager] Skipping step '" + step_name + "' - not applicable on " + platform_name)
			return _execute_install_step(emulator_id, step_index + 1)
		push_error("[EmulatorManager] No platform config for step '" + step_name + "' on platform: " + platform_name)
		_end_force_install(emulator_id)
		install_steps_failed.emit(emulator_id, "No platform config")
		return false

	install_step_started.emit(emulator_id, step_index, install_steps.size())

	var action_type = platform_config.get("action_type", "")
	var step_success: bool = false
	
	# Route to appropriate handler based on action type
	match action_type:
		"download_url":
			step_success = _handle_download_url_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_repo":
			step_success = _handle_download_repo_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_scrape":
			step_success = _handle_download_scrape_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"extract":
			step_success = _execute_extract_step(emulator_id, step_index, platform_config)
		"apk_install":
			step_success = _execute_apk_install_step(emulator_id, step_index, platform_config)
		"batch_url_download":
			step_success = _execute_batch_url_download_step(emulator_id, step_index, platform_config)
		"create_folders":
			step_success = _handle_create_folders_step(emulator_id, step_name, step_index, platform_config)
		"create_files":
			step_success = _handle_create_files_step(emulator_id, step_name, step_index, platform_config)
		"create_pcsx2_superblock":
			step_success = _handle_create_pcsx2_superblock_step(emulator_id, step_name, step_index, platform_config)
		"edit_file":
			step_success = _handle_edit_file_step(emulator_id, step_name, step_index, platform_config)
		"chmod":
			step_success = _execute_chmod_step(emulator_id, step_index, platform_config)
		"move":
			step_success = _execute_move_step(emulator_id, step_index, platform_config)
		"appimage_extract":
			step_success = _execute_appimage_extract_step(emulator_id, step_index, platform_config)
		"validate_only":
			step_success = _handle_validate_only_step(emulator_id, step_name, step_index, platform_config)
		"none":
			step_success = _handle_none_step(emulator_id, step_name, step_index)
		_:
			push_error("[EmulatorManager] Unknown action_type '" + action_type + "' for step: " + step_name)
			step_success = false
	
	if not step_success:
		_end_force_install(emulator_id)
		install_steps_failed.emit(emulator_id, "Install step failed")

	return step_success

## Re-runs a previous install step when current step needs it
## Use this when a step's input (downloaded file, etc.) is missing
func _retry_previous_step(emulator_id: String, current_step_index: int) -> bool:
	var target_step = current_step_index - 1
	if target_step < 0:
		push_error("[EmulatorManager] Cannot retry - would go before first step")
		return false

	return _execute_install_step(emulator_id, target_step)

## Walks back to the FIRST download step in the chain and re-runs it, so a
## missing input (archive, AppImage) is actually re-fetched.
## Retrying only the immediate previous step cannot help when that step has no
## input either — worse, it ping-pongs: extract skip-forwards on a missing
## archive while chmod retries backwards on a missing binary, recursing
## synchronously until the stack overflows. And retrying the NEAREST download
## step is wrong for multi-download chains (shadPS4 core + Qt launcher): the
## input may come from an earlier download, so the whole chain restarts.
## AppImages are deleted after extraction, so "no AppImage" always means
## "re-download".
func _retry_from_download_step(emulator_id: String, current_step_index: int) -> bool:
	var install_steps: Array = launch_manager.registry.get_emulator(emulator_id).get("install", [])
	for i in range(0, current_step_index):
		var prev_config: Dictionary = launch_manager.registry._get_step_platform_config(install_steps[i])
		var prev_action: String = prev_config.get("action_type", "")
		if prev_action in ["download_repo", "download_scrape", "download_url", "batch_url_download"]:
			print("[EmulatorManager] Input missing - restarting download chain at step " + str(i) + " for " + emulator_id)
			return _execute_install_step(emulator_id, i)
	push_error("[EmulatorManager] No download step found before step " + str(current_step_index) + " for " + emulator_id)
	return false

## Executes APK install action for a step (Android only)
## Uses simple file:// URI approach with OS.shell_open()
## APKs are downloaded to the emulator directory for consistency
func _execute_apk_install_step(emulator_id: String, step_index: int, apk_config: Dictionary) -> bool:
	var package_name = apk_config.get("package_name", "")
	
	if package_name == "":
		push_error("[EmulatorManager] No package_name specified for apk_install")
		return false
	
	# Check if this is the first step (can't go back)
	if step_index == 0:
		push_error("[EmulatorManager] Cannot install APK - no previous download step")
		return false
	
	# Get expected filename pattern from config
	var expected_file = apk_config.get("expected_file", "")
	if expected_file == "":
		push_error("[EmulatorManager] No expected_file specified for apk_install - cannot find APK to install")
		return false
	
	print("[EmulatorManager] Executing APK install step...")
	if DEBUG_LOG: print("[EmulatorManager]   - package_name: '" + package_name + "'")
	if DEBUG_LOG: print("[EmulatorManager]   - expected_file: '" + expected_file + "'")
	
	# APKs are downloaded to the emulator directory (same as other platforms)
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
	var apk_path = ""
	
	# Find the APK file in emulator directory
	var entries = FSM.list_dir(emulator_dir)
	for file_name in entries:
		if file_name.match(expected_file):
			apk_path = FSM.join_paths(emulator_dir, file_name)
			if DEBUG_LOG: print("[EmulatorManager] Found APK: " + apk_path)
			break
	
	# If no APK found, retry download
	if apk_path == "":
		if DEBUG_LOG: print("[EmulatorManager] No APK found in emulator directory, retrying download")
		return _retry_previous_step(emulator_id, step_index)
	
	# Validate APK file exists and has content
	var file_size = FSM.get_file_size(apk_path)
	if DEBUG_LOG: print("[EmulatorManager] APK file size: " + str(file_size) + " bytes")
	if file_size < 0:
		if DEBUG_LOG: print("[EmulatorManager] ERROR: Cannot access APK file!")
		return _retry_previous_step(emulator_id, step_index)
	elif file_size < 1000:
		if DEBUG_LOG: print("[EmulatorManager] ERROR: APK file is too small or empty!")
		SystemManager.notifications.show_notification(
			"APK download incomplete!\nFile size: " + str(file_size) + " bytes",
			SystemManager.notifications.Type.ERROR,
			null,
			10.0
		)
		_emulator_install_progress[emulator_id] = "APK download incomplete"
		return false
	
	if DEBUG_LOG: print("[EmulatorManager] Installing APK: " + apk_path)
	
	# On Android, use plugin to install APK with content:// URI (required for Android N+)
	var plugin = null
	if Engine.has_singleton("KyodaiBridge"):
		plugin = Engine.get_singleton("KyodaiBridge")
	
	var result = Error.FAILED
	if plugin != null:
		# Android 8+ silently blocks APK installs until the user grants the
		# "Install unknown apps" toggle for Kyodai. Gate here so we don't fire
		# an intent the system will refuse and then advance the install flow
		# past a step that never actually ran. The platform helper owns the
		# explainer dialog and the just-in-time grant lifecycle.
		if not SystemManager.platform.ensure_install_permission("emulators"):
			print("[EmulatorManager] Install-unknown-apps permission not granted, requesting")
			_emulator_install_progress[emulator_id] = "Install permission required"
			return false
		# Convert Godot virtual path (user://) to an absolute filesystem path
		# so the Java plugin can create a File object from it.
		var absolute_apk_path = FSM.resolve_path(apk_path, {"format": FSM.PathFormat.ABSOLUTE})
		if DEBUG_LOG: print("[EmulatorManager] Resolved APK path for plugin: " + absolute_apk_path)
		var success = plugin.call("installApk", absolute_apk_path)
		if success:
			SystemManager.platform.notify_install_started()
			result = Error.OK
	else:
		push_error("[EmulatorManager] KyodaiBridge plugin not available for APK install")
	
	if result != Error.OK:
		print("[EmulatorManager] APK install failed with error: " + str(result))
		SystemManager.notifications.show_notification(
			"APK install failed!\nPlease install manually from:\n" + apk_path,
			SystemManager.notifications.Type.ERROR,
			null,
			10.0
		)
		
		# Try to open the folder
		var folder_result = OS.shell_open(FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE}))
		if folder_result == Error.OK:
			if DEBUG_LOG: print("[EmulatorManager] Opened folder containing APK")
		
		_emulator_install_progress[emulator_id] = "APK install failed"
		return false
	
	print("[EmulatorManager] APK installer opened successfully")
	print("[EmulatorManager] User must complete installation in Android UI")
	
	# Show reminder on Android to open the app and grant permissions
	launch_manager.process._show_android_permissions_reminder(emulator_id)
	
	# DEBUG: Don't delete APK so we can check it
	# Validate installation
	var validate_config = apk_config.get("validate", {})
	if not _validate_step(emulator_id, validate_config):
		# Don't fail here - user might still be installing
		pass
	
	# Progress to next step
	_execute_install_step(emulator_id, step_index + 1)
	return true

## Executes batch URL download action for downloading multiple files
## Downloads all items in parallel and extracts them automatically
func _execute_batch_url_download_step(emulator_id: String, step_index: int, batch_config: Dictionary) -> bool:
	# Get configuration
	var base_url = batch_config.get("base_url", "")
	var url_pattern = batch_config.get("url_pattern", "{name}")
	var cores = batch_config.get("cores", [])
	var dynamic_cores = batch_config.get("dynamic_cores", false)
	
	# Generate the default-core list from the registry so it
	# stays in sync with the supported platform/core mappings.
	if dynamic_cores and emulator_id == "retroarch":
		cores = launch_manager.core.get_default_core_download_list(emulator_id) as Array
		if cores.is_empty():
			push_error("[EmulatorManager] No default cores found in registry for RetroArch")
			return false
	
	if base_url == "":
		push_error("[EmulatorManager] No base_url specified for batch_url_download")
		return false
	
	if cores.is_empty():
		push_error("[EmulatorManager] No cores specified for batch_url_download")
		return false
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Get step name for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)

	# Track batch progress using Dictionary for proper reference semantics in closures
	var total_cores = cores.size()
	var progress = {"completed": 0, "failed": 0}
	var failed_cores: Array[String] = []
	var download_ids = []
	
	# Set progress text
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(total_cores) + ")"
	
	# Create a single batch progress notification (skipped during update-all
	# sessions, which show their own aggregate snackbar instead)
	var batch_notification_id = -1
	if not suppress_step_notifications:
		batch_notification_id = SystemManager.notifications.show_notification(
			step_display_name + " (0/" + str(total_cores) + ")",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			func() -> float:
				return float(progress.completed) / float(total_cores),
			func(_p: float) -> String:
				return step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")",
			false,  # pulsing
			true  # pinned
		)
	
	# Queue all downloads
	for core_name in cores:
		# Construct URL from pattern
		var filename = url_pattern.replace("{name}", core_name)
		var full_url = base_url + filename
		
		# Download to emulator directory (for extraction, then delete)
		var destination_path = FSM.join_paths(launch_manager.registry._get_emulator_directory(emulator_id), filename)
		
		# Queue download without auto-extract (extraction happens in separate step)
		# suppress_notification=true to avoid dozens of individual notifications
		var item_id = SystemManager.download.queue_download(
			full_url,
			destination_path,
			"emulator_core",
			core_name,
			false,   # auto_extract - extraction handled by install_cores step
			"",      # extract_dir - not used here
			null,    # game
			{},      # callbacks
			0,       # romm_id
			false,   # delete_after_extract - keep zips for extraction step
			true     # suppress_notification - use batch notification instead
		)
		
		if item_id == "":
			# Count as completed so the all-done gate below can still fire and
			# surface the failure; otherwise the batch hangs at (N-1)/N forever.
			progress.completed += 1
			progress.failed += 1
			failed_cores.append(core_name)
			push_error("[EmulatorManager] Failed to queue core download: " + core_name)
		else:
			download_ids.append(item_id)
			
		# Create a callback that captures by reference (Dictionary is a reference type)
		var callback = func(success: bool, _message: String):
			progress.completed += 1
			if not success:
				progress.failed += 1
				failed_cores.append(core_name)
				push_warning("[EmulatorManager] Core download failed: " + core_name)
			# Update progress
			_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")"
			# Check if all downloads are complete
			if progress.completed >= total_cores:
				# Dismiss the batch notification
				SystemManager.notifications.dismiss_notification(batch_notification_id)
				if progress.failed > 0:
					push_error("[EmulatorManager] Batch download failed: " + str(progress.failed) + "/" + str(total_cores) + " cores failed: " + ", ".join(failed_cores))
					_emulator_install_progress[emulator_id] = "Batch download failed"
					_end_force_install(emulator_id)
					install_steps_failed.emit(emulator_id, "Batch download failed")
				else:
					_execute_install_step(emulator_id, step_index + 1)
			
		# Track completion
		_pending_emulator_downloads[item_id] = {
			"emulator_id": emulator_id,
			"context": "batch_download",
			"step_index": step_index,
			"core_name": core_name,
			"callback": callback
		}
	
	if download_ids.is_empty():
		push_error("[EmulatorManager] No downloads could be queued for batch_url_download")
		SystemManager.notifications.dismiss_notification(batch_notification_id)
		return false
	
	return true

## Executes extract action for a step
func _execute_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary) -> bool:
	var extract_to = extract_config.get("extract_to", ".")
	var strip_top = extract_config.get("strip_top_directory", false)
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Resolve path using universal resolver
	var extract_dir = FSM.resolve_emulator_path(extract_to, emulator_id)
	
	# Normalize the path to remove "." and ".." components
	extract_dir = FSM.normalize_path(extract_dir)
	
	# Look for the archive file to extract before deciding whether to skip.
	# This lets steps with no validation (e.g. Linux RetroArch cores) still extract
	# when an archive is present, while completed steps whose archive has been
	# cleaned up are correctly skipped.
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var archive_path = ""
	var is_batch_mode = extract_config.get("batch", false)
	
	if is_batch_mode:
		# Batch mode: extract all matching archives
		return _execute_batch_extract_step(emulator_id, step_index, extract_config, extract_dir, strip_top)
	
	# Single archive mode (default behavior)
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: expected_file pattern='" + expected_file + "'")
	if expected_file != "":
		var files = FSM.list_dir(emulator_dir)
		if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: files in emulator_dir=" + str(files))
		for file_name in files:
			if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: checking if '" + file_name + "' matches pattern '" + expected_file + "'")
			if file_name.match(expected_file):
				var full_path = FSM.join_paths(emulator_dir, file_name)
				if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: MATCH! full_path=" + full_path)
				if FSM.file_exists(full_path):
					archive_path = full_path
					if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: archive_path set to " + archive_path)
					break
				else:
					if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: file exists check failed for " + full_path)
		if DEBUG_LOG: print("[EmulatorManager] _execute_extract_step: after expected_file loop, archive_path=" + archive_path)
	
	# If no expected_file match, scan for common archive extensions (first match
	# only). When expected_file IS set there is no fallback: grabbing a random
	# unrelated archive (e.g. the Qt launcher zip when the core zip is missing)
	# extracts the wrong payload and corrupts the whole chain — treat it as
	# missing and walk back to the download step instead.
	if archive_path == "" and expected_file == "":
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = FSM.join_paths(emulator_dir, file_name)
					if FSM.file_exists(full_path):
						archive_path = full_path
						break
			if archive_path != "":
				break
	
	var archive_exists = archive_path != "" and FSM.file_exists(archive_path)
	
	# Skip extraction only when the step is already validated AND no archive remains.
	# During an update or reinstall the flag is set, so we re-extract the new archive.
	if not _force_install_step.get(emulator_id, false):
		if _validate_install_step(emulator_id, step_index, install_steps) and not archive_exists:
			_execute_install_step(emulator_id, step_index + 1)
			return true
	
	# Check if archive was found
	if not archive_exists:
		# Go back to the download step to re-fetch the archive
		return _retry_from_download_step(emulator_id, step_index)
	
	# Get step name from install_steps for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)

	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Notify UI that extraction has started
	launch_manager.emulator_extraction_started.emit(emulator_id)
	
	# Strip-enabled installs extract into isolated staging so old live anchors
	# cannot mask a wrapped update. Other extraction types retain their path.
	var staging_dir := ""
	var operation_extract_dir: String = extract_dir
	if strip_top:
		staging_dir = _new_extraction_staging_dir(extract_dir)
		if not FSM.make_dir_recursive(staging_dir):
			_fail_extraction(emulator_id, "Extraction staging failed", staging_dir)
			return false
		operation_extract_dir = staging_dir

	var item_id = SystemManager.download.queue_extraction(
		archive_path, operation_extract_dir, "emulator", step_display_name, not strip_top, suppress_step_notifications)
	if item_id == "":
		push_error("[EmulatorManager] Failed to queue extraction for: " + emulator_id)
		_fail_extraction(emulator_id, "Extraction failed", staging_dir)
		return false
	
	var extraction_callback = func(success: bool, _message: String):
		if not success:
			_fail_extraction(emulator_id, "Extraction failed", staging_dir)
			return

		if strip_top:
			var normalization := _normalize_extracted_directory(staging_dir, extract_config)
			var status := str(normalization.get("status", ""))
			if not ["normalized", "already_canonical"].has(status):
				push_error("[EmulatorManager] Layout normalization failed for " + emulator_id + ": " + str(normalization.get("error", status)))
				_fail_extraction(emulator_id, "Layout normalization failed", staging_dir)
				return
			if not _validate_staged_extraction(staging_dir, extract_config):
				push_error("[EmulatorManager] Staged validation failed for " + emulator_id)
				_fail_extraction(emulator_id, "Staged validation failed", staging_dir)
				return
			var commit := FSM.merge_extraction_payload(staging_dir, extract_dir)
			if str(commit.get("status", "")) != "committed":
				push_error("[EmulatorManager] Extraction commit failed for " + emulator_id + ": " + str(commit.get("error", "unknown error")))
				_fail_extraction(emulator_id, "Extraction commit failed", staging_dir)
				return

		# Full registry validation runs against the committed live install.
		var validate_config = extract_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Validation failed after extraction: " + emulator_id)
			_fail_extraction(emulator_id, "Validation failed")
			return

		# Strip-enabled archives are retained until every validation succeeds.
		if strip_top and FSM.file_exists(archive_path):
			FSM.delete_file(archive_path)
		_erase_validation_cache(emulator_id)
		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		_execute_install_step(emulator_id, step_index + 1)
	
	# Track extraction completion
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "extraction",
		"step_index": step_index,
		"step_config": extract_config,
		"callback": extraction_callback
	}
	
	return true

## Executes batch extraction for multiple archives
func _execute_batch_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary, extract_dir: String, strip_top: bool) -> bool:
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
	var archive_paths = []
	
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	if expected_file != "":
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			if file_name.match(expected_file):
				var full_path = FSM.join_paths(emulator_dir, file_name)
				if FSM.file_exists(full_path):
					archive_paths.append(full_path)
	
	# If no expected_file match, scan for common archive extensions — but only
	# when no expected_file was configured (see _execute_extract_step).
	if archive_paths.is_empty() and expected_file == "":
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = FSM.join_paths(emulator_dir, file_name)
					if FSM.file_exists(full_path):
						archive_paths.append(full_path)
						break
	
	# Check if any archives were found
	if archive_paths.is_empty():
		# Go back to download step to re-download
		return _retry_previous_step(emulator_id, step_index)
	
	# Get step name from install_steps for display
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)

	# Show batch progress
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(archive_paths.size()) + ")"
	
	# Notify UI that extraction has started
	launch_manager.emulator_extraction_started.emit(emulator_id)
	
	# Track progress for multiple extractions using Dictionary (reference type for closures)
	var total_archives = archive_paths.size()
	var progress = {"completed": 0, "failed": 0}
	var extraction_ids = []
	
	# Create a single batch progress notification (skipped during update-all
	# sessions, which show their own aggregate snackbar instead)
	var batch_notification_id = -1
	if not suppress_step_notifications:
		batch_notification_id = SystemManager.notifications.show_notification(
			step_display_name + " (0/" + str(total_archives) + ")",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			func() -> float:
				return float(progress.completed) / float(total_archives),
			func(_p: float) -> String:
				return step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")",
			false,  # pulsing
			true  # pinned
		)
	
	var staging_by_item := {}
	var archive_by_item := {}
	var batch_callback = func(success: bool, _message: String, completed_item_id: String):
		progress.completed += 1
		var staging_dir := str(staging_by_item.get(completed_item_id, ""))
		if not success:
			progress.failed += 1
			_cleanup_extraction_staging(staging_dir)
		elif strip_top:
			var normalization := _normalize_extracted_directory(staging_dir, extract_config)
			var status := str(normalization.get("status", ""))
			if not ["normalized", "already_canonical"].has(status):
				progress.failed += 1
				push_error("[EmulatorManager] Batch layout normalization failed for " + emulator_id + ": " + str(normalization.get("error", status)))
				_cleanup_extraction_staging(staging_dir)
			elif not _validate_staged_extraction(staging_dir, extract_config):
				progress.failed += 1
				push_error("[EmulatorManager] Batch staged validation failed for " + emulator_id)
				_cleanup_extraction_staging(staging_dir)
			else:
				var commit := FSM.merge_extraction_payload(staging_dir, extract_dir)
				if str(commit.get("status", "")) != "committed":
					progress.failed += 1
					push_error("[EmulatorManager] Batch extraction commit failed for " + emulator_id + ": " + str(commit.get("error", "unknown error")))
					_cleanup_extraction_staging(staging_dir)

		_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")"
		if progress.completed < total_archives:
			return

		SystemManager.notifications.dismiss_notification(batch_notification_id)
		if progress.failed > 0:
			for remaining_staging in staging_by_item.values():
				_cleanup_extraction_staging(str(remaining_staging))
			_fail_extraction(emulator_id, "Extraction failed")
			return

		if emulator_id == "retroarch":
			var manifest: Dictionary = launch_manager.core.build_default_core_manifest(emulator_id) as Dictionary
			launch_manager.core.write_manifest(emulator_id, manifest)

		var validate_config = extract_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Validation failed after batch extraction: " + emulator_id)
			_fail_extraction(emulator_id, "Validation failed")
			return

		if strip_top:
			for archive_path in archive_by_item.values():
				if FSM.file_exists(str(archive_path)):
					FSM.delete_file(str(archive_path))
		_erase_validation_cache(emulator_id)
		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		_execute_install_step(emulator_id, step_index + 1)

	# Stage and queue every archive independently. Queue/staging failures count
	# as completed failures so the shared callback cannot stall below the total.
	for archive_path in archive_paths:
		var staging_dir := ""
		var operation_extract_dir: String = extract_dir
		if strip_top:
			staging_dir = _new_extraction_staging_dir(extract_dir)
			if not FSM.make_dir_recursive(staging_dir):
				progress.completed += 1
				progress.failed += 1
				continue
			operation_extract_dir = staging_dir
		var item_id = SystemManager.download.queue_extraction(
			archive_path, operation_extract_dir, "emulator", step_display_name, not strip_top, true)
		if item_id == "":
			_cleanup_extraction_staging(staging_dir)
			progress.completed += 1
			progress.failed += 1
			push_error("[EmulatorManager] Failed to queue extraction for: " + archive_path)
			continue
		extraction_ids.append(item_id)
		staging_by_item[item_id] = staging_dir
		archive_by_item[item_id] = archive_path
		_pending_emulator_downloads[item_id] = {
			"emulator_id": emulator_id,
			"context": "extraction",
			"step_index": step_index,
			"step_config": extract_config,
			"callback": batch_callback.bind(item_id)
		}

	if extraction_ids.is_empty():
		push_error("[EmulatorManager] No extractions could be queued for batch: " + emulator_id)
		SystemManager.notifications.dismiss_notification(batch_notification_id)
		_fail_extraction(emulator_id, "Extraction failed")
		return false
	return true

func _validate_step(emulator_id: String, validate_config: Dictionary) -> bool:
	if validate_config.is_empty():
		return true
	
	var action_type = validate_config.get("action_type", "")
	
	match action_type:
		"file_exists":
			var file_path = validate_config.get("file", "")
			if file_path == "":
				return true
			var full_path = FSM.resolve_emulator_path(file_path, emulator_id)
			return FSM.file_exists(full_path)
		
		"folder_exists":
			var folder_path = validate_config.get("path", "")
			if folder_path == "":
				return true
			var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
			return FSM.dir_exists(full_path)
		
		"files_exist":
			var folder_path = validate_config.get("path", "")
			var pattern = validate_config.get("pattern", "")
			var files_array = validate_config.get("files", [])
			
			# Support both "files" array format and "path" + "pattern" format
			if files_array.size() > 0:
				# Check if all files in the array exist
				for file_name in files_array:
					var full_file_path = FSM.resolve_emulator_path(file_name, emulator_id)
					if not FSM.file_exists(full_file_path):
						return false
				return true
			
			if folder_path == "":
				return true
			
			var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
			
			var entries = FSM.list_dir(full_path)
			for file_name in entries:
				if file_name != "." and file_name != "..":
					if pattern == "" or file_name.match(pattern):
						return true
			return false
		
		"package_installed":
			# Check if an Android package is installed using PackageManager
			var package = validate_config.get("package", "")
			if package == "":
				return true
			
			if SystemManager.platform.is_android():
				return _is_android_package_installed(package)
			else:
				# On desktop, always return true (package concept doesn't apply)
				return true
		
		"core_manifest":
			# Android RetroArch only: validate that the core manifest is present
			# and every expected default core file exists on disk.
			if not launch_manager or not launch_manager.core:
				return false
			return launch_manager.core.validate_core_manifest(emulator_id) as bool
		
		"always_pass":
			return true
		
		_:
			return false

## Helper function for download_url action
func _handle_download_url_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var url = platform_config.get("url", "")
	if url == "":
		push_error("[EmulatorManager] No download URL for step '" + step_name + "'")
		return false
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
	return true

## Helper function for download_repo action
## Supports GitHub, Gitea, Forgejo, and other GitHub-compatible APIs via api_base_url
func _handle_download_repo_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var github_repo = platform_config.get("github_repo", "")
	var asset_pattern = platform_config.get("asset_pattern", "")
	var release_tag = platform_config.get("release_tag", "")
	var api_base_url = platform_config.get("api_base_url", "")  # For non-GitHub hosts (e.g., Gitea/Forgejo)
	# Opt into prereleases (e.g. ARMSX2 nightlies, the only channel carrying
	# some fixes). Default off: most repos should track stable releases.
	var include_prereleases = platform_config.get("include_prereleases", false)

	if github_repo == "" or asset_pattern == "":
		push_error("[EmulatorManager] Invalid download_repo config for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = emulator_name + " - Fetching release info..."
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	SystemManager.network.fetch_repo_release(
		github_repo,
		asset_pattern,
		func(url: String, tag: String, error: String, file_size: int, published_at: String, asset_updated_at: String, asset_sha256: String):
			if error != "":
				push_error("[EmulatorManager] Failed to fetch release: " + error)
				_emulator_install_progress[emulator_id] = emulator_name + " - Failed to fetch release"
				_end_force_install(emulator_id)
				install_steps_failed.emit(emulator_id, "Failed to fetch release info")
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
				return
			# Use the later of the release date and the matched asset's update date.
			# Asset updated_at is more reliable for rolling/pinned releases where the
			# release date stays fixed but CI re-uploads new builds.
			var version_to_save = launch_manager.registry._latest_iso_date(published_at, asset_updated_at)
			if version_to_save == "":
				version_to_save = tag
			if version_to_save != "" and not _pending_emulator_version.has(emulator_id):
				# First download step wins; defer persistence so failed installs don't appear up to date.
				_pending_emulator_version[emulator_id] = version_to_save
				print("[EmulatorManager] Resolved emulator version for " + emulator_id + ": " + version_to_save)
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config, file_size, asset_sha256),
		release_tag,
		api_base_url,
		include_prereleases
	)
	return true

## Helper function for download_scrape action
func _handle_download_scrape_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var scrape_url = platform_config.get("scrape_url", "")
	var version_pattern = platform_config.get("version_pattern", "")
	var url_template = platform_config.get("url_template", "")
	var match_strategy = platform_config.get("match_strategy", "first")
	var json_path = platform_config.get("json_path", "")
	
	if scrape_url == "" or url_template == "":
		push_error("[EmulatorManager] Invalid download_scrape config for step: " + step_name)
		return false
	
	# version_pattern is required for HTML scraping, optional for JSON API mode
	if json_path == "" and version_pattern == "":
		push_error("[EmulatorManager] download_scrape requires either version_pattern or json_path for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = emulator_name + " - Scraping for latest version..."
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	SystemManager.network.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(url: String, version: String, error: String):
			if error != "":
				push_error("[EmulatorManager] Failed to scrape release: " + error)
				_emulator_install_progress[emulator_id] = emulator_name + " - Failed to scrape release"
				_end_force_install(emulator_id)
				install_steps_failed.emit(emulator_id, "Failed to fetch release info")
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
				return
			if version != "" and not _pending_emulator_version.has(emulator_id):
				# First download step wins; defer persistence so failed installs don't appear up to date.
				_pending_emulator_version[emulator_id] = version
				print("[EmulatorManager] Resolved emulator version for " + emulator_id + ": " + version)
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config),
		match_strategy,
		json_path
	)
	return true

## Saves the installed emulator version to settings for update checking.
## Only stores the FIRST download step's version to prevent secondary assets
## (e.g. shadPS4 Qt launcher) from clobbering the core version.
## Pass force=true to overwrite an existing version when explicitly needed.
func _save_emulator_version(emulator_id: String, version: String, force: bool = false):
	if DataManager:
		var setting = DataManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions == null:
				versions = {}
			# Only save if not already present (first download step wins), unless force is true
			if not versions.has(emulator_id) or force:
				versions[emulator_id] = version
				# force=true: versions IS setting.value (mutated in place above), so the
				# changed-check inside set_setting would compare the Dictionary to itself
				# and never mark settings dirty - the save would be silently dropped.
				DataManager.set_setting(versions, setting, true)
				DataManager.save_settings()
				print("[EmulatorManager] Saved version for " + emulator_id + ": " + version)
			else:
				print("[EmulatorManager] Skipped saving version for " + emulator_id + " (already exists: " + versions.get(emulator_id, "") + ")")

## Clears stored version so a fresh install/update can save a new version.
func _clear_emulator_version(emulator_id: String):
	if DataManager:
		var setting = DataManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions != null and versions.has(emulator_id):
				versions.erase(emulator_id)
				# force=true: same in-place mutation trap as _save_emulator_version.
				DataManager.set_setting(versions, setting, true)
				DataManager.save_settings()

## Helper function for create_folders action
func _handle_create_folders_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var folders = platform_config.get("folders", [])
	if folders.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	for folder_path in folders:
		# Resolve path using universal resolver
		var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
		
		if not FSM.make_dir_recursive(full_path):
			push_error("[EmulatorManager] Failed to create folder: " + full_path)
			return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for chmod action (Linux/Android binary permissions)
## Config keys:
##   - file: specific file path relative to emulator_dir
##   - files: array of file paths relative to emulator_dir
##   - pattern: glob pattern matched against files in emulator_dir
##   - recursive: if true, pattern is matched recursively (default false)
##   - mode: chmod mode string (default "+x")
func _execute_chmod_step(emulator_id: String, step_index: int, platform_config: Dictionary) -> bool:
	# Windows does not use POSIX permissions; treat as no-op.
	if SystemManager.platform.is_windows():
		return _execute_install_step(emulator_id, step_index + 1)
	
	var mode: String = platform_config.get("mode", "+x")
	var emulator_dir: String = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var targets: Array[String] = []
	
	# Specific file
	var file: String = platform_config.get("file", "")
	if file != "":
		targets.append(FSM.resolve_emulator_path(file, emulator_id))
	
	# Array of files
	var files = platform_config.get("files", [])
	if files is Array:
		for f in files:
			if f is String and f != "":
				targets.append(FSM.resolve_emulator_path(f, emulator_id))
	
	# Pattern matching
	var pattern: String = platform_config.get("pattern", "")
	var recursive: bool = platform_config.get("recursive", false)
	if pattern != "":
		if recursive:
			var recursive_targets = _chmod_find_files_matching(emulator_dir, pattern)
			for found_path in recursive_targets:
				if FSM.file_exists(found_path):
					targets.append(found_path)
		else:
			for entry in FSM.list_dir(emulator_dir):
				if entry == "." or entry == "..":
					continue
				if entry.match(pattern):
					var full_path = FSM.join_paths(emulator_dir, entry)
					if FSM.file_exists(full_path):
						targets.append(full_path)
	
	if targets.is_empty():
		# If the step specified files/patterns to chmod but none were found, the
		# input was never downloaded or was already consumed (AppImages are
		# deleted after extraction). Step back to the download step instead of
		# retrying the immediate previous step: that one has no input either,
		# and its skip-forward would ping-pong with this retry until the stack
		# overflows.
		var expected_something: bool = file != "" or (files is Array and files.size() > 0) or pattern != ""
		if expected_something:
			push_warning("[EmulatorManager] chmod targets missing for " + emulator_id + "; retrying from download step")
			return _retry_from_download_step(emulator_id, step_index)
		push_warning("[EmulatorManager] chmod step has no targets for " + emulator_id)
		return _execute_install_step(emulator_id, step_index + 1)

	# Async: chmod runs on the OS-execute worker pool so installing an emulator
	# with many chmod targets doesn't stall the main thread. The step returns
	# "accepted" and the next step chains from _on_chmod_target_done once every
	# target has completed.
	var abs_targets: Array = []
	var all_success: bool = true
	for target in targets:
		if not FSM.file_exists(target):
			push_warning("[EmulatorManager] chmod target missing: " + target)
			all_success = false
			continue
		abs_targets.append(FSM.resolve_path(target, {"format": FSM.PathFormat.ABSOLUTE}))

	if abs_targets.is_empty():
		# Every target was missing - same failure as the synchronous path.
		return false

	# Callbacks run on the main thread, so mutating this shared state is safe.
	var state := {"pending": abs_targets.size(), "all_success": all_success}
	for abs_target in abs_targets:
		MemorySubManager.queue_os_execute("chmod", [mode, abs_target],
			_on_chmod_target_done.bind(emulator_id, step_index, mode, abs_target, state))
	return true

## Main thread: one chmod target finished. Chains the next install step after
## the last target; any failure fails the install like the synchronous path.
func _on_chmod_target_done(result: Dictionary, emulator_id: String, step_index: int, mode: String, abs_target: String, state: Dictionary) -> void:
	if int(result.get("exit_code", -1)) != 0:
		push_error("[EmulatorManager] chmod failed for " + abs_target + " with mode " + mode)
		state.all_success = false
	else:
		if DEBUG_LOG: print("[EmulatorManager] chmod " + mode + " " + abs_target)
	state.pending -= 1
	if state.pending > 0:
		return
	if not state.all_success:
		_end_force_install(emulator_id)
		install_steps_failed.emit(emulator_id, "Install step failed")
	else:
		_execute_install_step(emulator_id, step_index + 1)

## Recursively finds files under dir_path whose names match the Godot glob pattern.
## Used by the chmod install step when "recursive": true.
func _chmod_find_files_matching(dir_path: String, pattern: String) -> Array[String]:
	var results: Array[String] = []
	if dir_path.is_empty() or pattern.is_empty() or not FSM.dir_exists(dir_path):
		return results
	
	for entry in FSM.list_dir(dir_path):
		if entry == "." or entry == "..":
			continue
		var full_path = FSM.join_paths(dir_path, entry)
		if FSM.is_dir(full_path):
			results.append_array(_chmod_find_files_matching(full_path, pattern))
		elif entry.match(pattern):
			results.append(full_path)
	
	return results

## Helper function for move action
## Config keys:
##   - source: source file or directory path relative to emulator_dir
##   - destination: destination path relative to emulator_dir
##   - source_pattern: optional Godot glob pattern; if set, all matching files are moved
##   - recursive: if true, source_pattern is matched recursively (default false)
func _execute_move_step(emulator_id: String, step_index: int, platform_config: Dictionary) -> bool:
	var source: String = platform_config.get("source", "")
	var destination: String = platform_config.get("destination", "")
	var source_pattern: String = platform_config.get("source_pattern", "")
	var recursive: bool = platform_config.get("recursive", false)
	var replace: bool = platform_config.get("replace", false)
	
	if source == "" and source_pattern == "":
		push_error("[EmulatorManager] move step has no source for " + emulator_id)
		return false
	
	var emulator_dir: String = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var all_success: bool = true
	
	if source_pattern != "":
		# Move multiple files matching a glob pattern
		var sources: Array[String] = []
		if recursive:
			sources = _chmod_find_files_matching(emulator_dir, source_pattern)
		else:
			for entry in FSM.list_dir(emulator_dir):
				if entry == "." or entry == "..":
					continue
				if entry.match(source_pattern):
					sources.append(FSM.join_paths(emulator_dir, entry))
		
		if sources.is_empty():
			push_warning("[EmulatorManager] move step found no sources matching pattern '" + source_pattern + "' for " + emulator_id)
			# If the destination already passes validation, the move is already done.
			# Otherwise go back to the previous step (usually the download) so the
			# source file can be fetched again, matching how extract steps recover.
			var validate_config = platform_config.get("validate", {})
			if _validate_step(emulator_id, validate_config):
				return _execute_install_step(emulator_id, step_index + 1)
			return _retry_previous_step(emulator_id, step_index)
		
		for src_path in sources:
			var dest_path: String
			if destination != "":
				# Move into destination directory/preserve basename
				if FSM.dir_exists(FSM.resolve_emulator_path(destination, emulator_id)):
					dest_path = FSM.join_paths(destination, src_path.get_file())
				else:
					dest_path = destination
			else:
				push_error("[EmulatorManager] move step with source_pattern requires destination for " + emulator_id)
				return false
			
			var full_src: String = src_path
			var full_dest: String = FSM.resolve_emulator_path(dest_path, emulator_id)
			if not FSM.move(full_src, full_dest):
				push_error("[EmulatorManager] move failed: " + full_src + " -> " + full_dest)
				all_success = false
			else:
				if DEBUG_LOG: print("[EmulatorManager] moved " + full_src + " -> " + full_dest)
	else:
		# Move a single file or directory
		var full_src: String = FSM.resolve_emulator_path(source, emulator_id)
		var full_dest: String = FSM.resolve_emulator_path(destination, emulator_id)
		
		if not FSM.file_exists(full_src) and not FSM.dir_exists(full_src):
			# Source is gone; if destination already passes validation, treat the
			# move as already completed (idempotent resume after interruption).
			var validate_config = platform_config.get("validate", {})
			if _validate_step(emulator_id, validate_config):
				if DEBUG_LOG: print("[EmulatorManager] move source missing but destination valid, skipping: " + full_src)
				return _execute_install_step(emulator_id, step_index + 1)
			push_error("[EmulatorManager] move source missing: " + full_src)
			return false
		
		# If replace is requested and destination exists as a directory, remove it
		# first so the move can succeed (used for re-installing core directories).
		if replace and FSM.dir_exists(full_dest):
			if DEBUG_LOG: print("[EmulatorManager] move replace: removing existing destination " + full_dest)
			FSM.delete_dir_recursive(full_dest)
		
		if not FSM.move(full_src, full_dest):
			push_error("[EmulatorManager] move failed: " + full_src + " -> " + full_dest)
			all_success = false
		else:
			if DEBUG_LOG: print("[EmulatorManager] moved " + full_src + " -> " + full_dest)
	
	if not all_success:
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Escapes a string for safe use inside Unix sh single quotes.
func _escape_sh_arg(s: String) -> String:
	return "'" + s.replace("'", "'\"'\"'") + "'"

## Extracts an AppImage in-place using --appimage-extract.
## Config keys:
##   - pattern: Godot glob pattern to find the AppImage file (default "*.AppImage")
##   - validate: standard validation block after extraction
func _execute_appimage_extract_step(emulator_id: String, step_index: int, platform_config: Dictionary) -> bool:
	var emulator_dir: String = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var pattern: String = platform_config.get("pattern", "*.AppImage")

	# Find AppImage matching pattern first; the path is needed for the skip
	# decision and for locating the bundled <AppImage>.home config tree.
	var appimage_path: String = ""
	for entry in FSM.list_dir(emulator_dir):
		if entry == "." or entry == "..":
			continue
		if entry.match(pattern):
			var full_path = FSM.join_paths(emulator_dir, entry)
			if FSM.file_exists(full_path):
				appimage_path = full_path
				break

	if appimage_path == "":
		push_warning("[EmulatorManager] appimage_extract step found no AppImage matching '" + pattern + "' for " + emulator_id + "; retrying from download step")
		return _retry_from_download_step(emulator_id, step_index)

	# Detect whether RetroArch's bundled config data (assets, autoconfig, shaders)
	# is missing so we can repair existing installs without a full re-extraction.
	var appimage_home_config: String = ""
	var assets_dst: String = ""
	var needs_config_copy: bool = false
	if emulator_id == "retroarch":
		appimage_home_config = FSM.join_paths(emulator_dir, appimage_path.get_file() + ".home/.config/retroarch")
		assets_dst = FSM.join_paths(emulator_dir, ".config/retroarch/assets")
		needs_config_copy = FSM.dir_exists(appimage_home_config) and (not FSM.dir_exists(assets_dst) or _dir_is_empty(assets_dst))

	# Skip re-extraction if the output is already valid and this isn't a forced
	# reinstall/update. This mirrors the Windows extract skip-if-valid guard.
	# For RetroArch we also re-run if bundled config data is missing, so existing
	# installs that extracted before the asset-copy fix get repaired automatically.
	if not _force_install_step.get(emulator_id, false):
		var validate_config = platform_config.get("validate", {})
		var already_valid = _validate_step(emulator_id, validate_config)
		if already_valid and needs_config_copy:
			print("[EmulatorManager] RetroArch assets missing, copying bundled config from AppImage home")
			_copy_retroarch_bundled_config(emulator_dir, appimage_path)
			_delete_extracted_appimage(appimage_path)
			return _execute_install_step(emulator_id, step_index + 1)
		if already_valid:
			if DEBUG_LOG: print("[EmulatorManager] AppImage extraction already valid for " + emulator_id + ", skipping")
			_delete_extracted_appimage(appimage_path)
			return _execute_install_step(emulator_id, step_index + 1)

	var abs_appimage = FSM.resolve_path(appimage_path, {"format": FSM.PathFormat.ABSOLUTE})
	var abs_emulator_dir = FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE})

	# Remove any existing squashfs-root to ensure clean extraction
	var squashfs_dir = FSM.join_paths(emulator_dir, "squashfs-root")
	if FSM.dir_exists(squashfs_dir):
		if DEBUG_LOG: print("[EmulatorManager] Removing existing squashfs-root before extraction: " + squashfs_dir)
		FSM.delete_dir_recursive(squashfs_dir)

	var step_name = ""
	var install_steps = launch_manager.registry.get_emulator(emulator_id).get("install", [])
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	var emulator_name = RegistrySubManager.get_emulator_display_name(launch_manager.registry.get_emulator(emulator_id), emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	launch_manager.emulator_extraction_started.emit(emulator_id)

	var inner_cmd = 'cd %s && %s --appimage-extract' % [_escape_sh_arg(abs_emulator_dir), _escape_sh_arg(abs_appimage)]
	if DEBUG_LOG: print("[EmulatorManager] Extracting AppImage: sh -c ", inner_cmd)

	var extract_callback = func(result: Dictionary):
		if result.get("exit_code", -1) != 0:
			push_error("[EmulatorManager] AppImage extraction failed for " + emulator_id + ": " + str(result.get("output", [])))
			_emulator_install_progress[emulator_id] = "Extraction failed"
			_end_force_install(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			return

		print("[EmulatorManager] AppImage extraction completed for " + emulator_id)

		# Persist a manifest of expected default cores so validation knows exactly
		# which files should be present (same as the batch-extract path).
		if emulator_id == "retroarch":
			var manifest: Dictionary = launch_manager.core.build_default_core_manifest(emulator_id) as Dictionary
			launch_manager.core.write_manifest(emulator_id, manifest)

		# Copy RetroArch's bundled config data into the enforced XDG config tree.
		if emulator_id == "retroarch":
			_copy_retroarch_bundled_config(emulator_dir, appimage_path)

		# Clear validation cache so UI doesn't show a stale Resume state
		_erase_validation_cache(emulator_id)

		# Validate extraction
		var validate_config = platform_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Validation failed after AppImage extraction: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Validation failed"
			_end_force_install(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			return

		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		# The extracted squashfs-root tree is the install now; the AppImage is
		# dead weight. Kyodai has no repair-from-AppImage flow — a broken install
		# is fixed by reinstalling, which fetches a fresh AppImage.
		_delete_extracted_appimage(appimage_path)
		_execute_install_step(emulator_id, step_index + 1)

	MemorySubManager.queue_os_execute("sh", ["-c", inner_cmd], extract_callback)
	return true

## Deletes a source AppImage after its extraction has been validated. Only the
## file this step actually extracted is removed — e.g. shadPS4's Qt launcher
## AppImage is never extracted and must be left alone.
func _delete_extracted_appimage(appimage_path: String) -> void:
	if appimage_path == "" or not FSM.file_exists(appimage_path):
		return
	print("[EmulatorManager] Deleting extracted AppImage: " + appimage_path)
	var err := DirAccess.remove_absolute(appimage_path)
	if err != OK:
		push_warning("[EmulatorManager] Failed to delete extracted AppImage " + appimage_path + " (error " + str(err) + ")")

func _copy_retroarch_bundled_config(emulator_dir: String, appimage_path: String) -> void:
	"""Copy RetroArch's bundled assets, autoconfigs, shaders, overlays, core info,
	and filters from <AppImage>.home/.config/retroarch into the enforced
	{emulator_dir}/.config/retroarch tree."""
	var config_root: String = FSM.join_paths(emulator_dir, ".config/retroarch")
	var appimage_home_config: String = FSM.join_paths(emulator_dir, appimage_path.get_file() + ".home/.config/retroarch")
	if not FSM.dir_exists(appimage_home_config):
		push_warning("[EmulatorManager] RetroArch AppImage home config not found at: " + appimage_home_config)
		return
	var dirs_to_copy: Array[String] = ["assets", "autoconfig", "shaders", "overlays", "cores", "filters"]
	for dir_name in dirs_to_copy:
		var src_dir: String = FSM.join_paths(appimage_home_config, dir_name)
		var dst_dir: String = FSM.join_paths(config_root, dir_name)
		if FSM.dir_exists(src_dir):
			FSM.copy_dir(src_dir, dst_dir)
		else:
			push_warning("[EmulatorManager] RetroArch bundled '%s' not found in AppImage home config" % dir_name)

func _dir_is_empty(path: String) -> bool:
	if not FSM.dir_exists(path):
		return true
	for entry in FSM.list_dir(path):
		if entry != "." and entry != "..":
			return false
	return true

func _handle_create_files_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var files = platform_config.get("files", [])
	if files.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	# Get the emulator directory path for placeholder resolution
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var global_emulator_dir = FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE})
	
	for file_entry in files:
		var file_name = ""
		var file_content = ""
		
		if typeof(file_entry) == TYPE_STRING:
			file_name = file_entry
		elif typeof(file_entry) == TYPE_DICTIONARY:
			file_name = file_entry.get("name", "")
			file_content = file_entry.get("content", "")
		
		if file_name == "":
			continue
		
		var full_path = FSM.resolve_emulator_path(file_name, emulator_id)
		
		# Resolve placeholders in content
		file_content = file_content.replace("{emulator_dir}", global_emulator_dir)
		
		# Resolve {games_dir} placeholder
		var games_folder_setting = DataManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value.rstrip("/") if games_folder_setting else "user://roms"
		file_content = file_content.replace("{games_dir}", games_dir)
		
		# During an update/reinstall we re-create config files so the new defaults
		# are applied. Otherwise we only create missing files to preserve user edits.
		var should_write = _force_install_step.get(emulator_id, false) or not FSM.file_exists(full_path)
		if should_write:
			if not CSM.write_config(full_path, file_content):
				push_error("[EmulatorManager] Failed to create file: " + full_path)
				return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for creating PCSX2 folder memory card superblock
func _handle_create_pcsx2_superblock_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var path = platform_config.get("path", "")
	if path == "":
		push_error("[EmulatorManager] No path specified for create_pcsx2_superblock step: " + step_name)
		return false

	# Use the configured save directory as the base path, which properly resolves
	# to app_data on Android and emulator_dir on desktop
	var save_dir = DataManager.resolve_default_save_directory(emulator_id, "ps2")
	if save_dir == "":
		push_error("[EmulatorManager] No save directory configured for " + emulator_id)
		return false
	
	# The save directory already includes the memcards path from the emulator config,
	# so we use it directly without appending the step path again
	var memcard_path = save_dir.rstrip("/")
	
	var success = DataManager.create_pcsx2_superblock(memcard_path)
	if not success:
		push_error("[EmulatorManager] Failed to create PCSX2 superblock at: " + memcard_path)
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Apply a set of text replacements to an emulator-relative config file.
## Each edit is a Dictionary with "old" and "new". Set "regex": true to treat
## "old" as a RegEx pattern. If create_if_missing is true, the file is created
## when it doesn't exist.
## If append_if_missing is provided, any key not already present is appended under
## the named section (or at the end of the file if section_name is empty).
func edit_emulator_file(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	if emulator_id == "" or file_path == "" or (edits.is_empty() and append_if_missing.is_empty()):
		push_error("[EmulatorManager] Invalid arguments for edit_emulator_file")
		return false
	
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path: " + file_path)
		return false

	var ok: bool = CSM.edit_text(full_path, edits, create_if_missing, append_if_missing, section_name)
	if ok:
		# Config changed outside the launch path; the next launch's
		# enforce_paths must re-read the file, not reuse a memoized result.
		RSM.invalidate_enforce_memo(emulator_id)
	return ok


## Same as edit_emulator_file, but stores the original file content first so it can be restored later.
func edit_emulator_file_with_backup(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path for backup: " + file_path)
		return false

	CSM.begin_backup(full_path)

	return edit_emulator_file(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

## Restores a file to the content captured by edit_emulator_file_with_backup().
func restore_emulator_file(emulator_id: String, file_path: String) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path for restore: " + file_path)
		return false

	var ok: bool = CSM.restore_backup(full_path)
	if ok:
		RSM.invalidate_enforce_memo(emulator_id)
	return ok

## Returns true if a backup exists for the given emulator file.
func has_emulator_file_backup(emulator_id: String, file_path: String) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		return false
	return CSM.has_backup(full_path)

## Helper function for edit_file action
func _handle_edit_file_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var file_path = platform_config.get("file", "")
	var edits = platform_config.get("edits", [])
	
	if file_path == "" or edits.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	if not edit_emulator_file(emulator_id, file_path, edits, true):
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for none action (skip)
func _handle_none_step(emulator_id: String, _step_name: String, step_index: int) -> bool:
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for validate_only action.
## Runs the platform config's validate block and advances only if it passes.
## Useful when no managed install action exists (e.g. user-provided Linux binary).
func _handle_validate_only_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var validate_config = platform_config.get("validate", {})
	if validate_config.is_empty():
		push_error("[EmulatorManager] validate_only step has no validate config: " + step_name)
		return false
	
	if DEBUG_LOG: print("[EmulatorManager] Validating step '%s' (index %d)" % [step_name, step_index])
	if not _validate_step(emulator_id, validate_config):
		print("[EmulatorManager] Validation failed for step '%s' (index %d)" % [step_name, step_index])
		return false
	print("[EmulatorManager] Validation passed for step '%s' (index %d)" % [step_name, step_index])
	
	return _execute_install_step(emulator_id, step_index + 1)

## Creates the save directory for an emulator if it doesn't exist
## Called automatically at the end of successful install flow
## For multi-platform emulators (e.g., RetroArch), creates directories for all supported platforms
func _create_emulator_save_directory(emulator_id: String) -> void:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return
	
	var platforms = emulator.get("meta", {}).get("platforms", [])
	
	# For single-platform emulators, just create the base directory
	if platforms.size() == 1:
		var save_dir = DataManager.resolve_default_save_directory(emulator_id)
		if save_dir == "":
			print("[EmulatorManager] No save directory configured for: " + emulator_id)
			return
		
		if FSM.dir_exists(save_dir):
			if DEBUG_LOG: print("[EmulatorManager] Save directory already exists for " + emulator_id + ": " + save_dir)
			return
		
		print("[EmulatorManager] Creating save directory for " + emulator_id + ": " + save_dir)
		var success = FSM.make_dir_recursive(save_dir)
		if not success:
			push_error("[EmulatorManager] Failed to create save directory for " + emulator_id + ": " + save_dir)
		else:
			print("[EmulatorManager] Successfully created save directory for " + emulator_id)
	else:
		# Multi-platform emulator: create save directories for each platform
		print("[EmulatorManager] Creating save directories for multi-platform emulator: " + emulator_id)
		for platform in platforms:
			var save_dir = DataManager.resolve_default_save_directory(emulator_id, platform)
			if save_dir == "":
				continue
			
			if FSM.dir_exists(save_dir):
				continue
			
			print("[EmulatorManager] Creating save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			var success = FSM.make_dir_recursive(save_dir)
			if not success:
				push_error("[EmulatorManager] Failed to create save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			else:
				print("[EmulatorManager] Successfully created save directory for " + emulator_id + " / " + platform)

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, _emulator: Dictionary, _install_steps: Array) -> bool:
	# Fresh install attempt: reset the retry-loop guard.
	_install_step_executions.erase(emulator_id)

	# Android: steps that touch the emulator's private app-data folder need a
	# one-time document-tree grant on devices without direct access or a root
	# daemon. Prompt up front rather than failing mid-flow with a cryptic
	# "failed to queue/create" error; the grant callback restarts the flow.
	if _install_flow_needs_app_data(emulator_id, _install_steps) and _prompt_for_app_data_access(emulator_id):
		return true  # picker is up; flow resumes (or fails) from its callback

	# Find the first incomplete step to start from
	var progress = get_install_progress(emulator_id)
	var start_step = 0
	
	if progress["status"] == "partial" and progress["next_step_index"] >= 0:
		start_step = progress["next_step_index"]
	
	# Starting from step 0 means this is a fresh install or a reinstall.
	# Clear any persisted or pending version so the first download step can save
	# the new one and we don't leak a stale resolved version from a prior attempt.
	if start_step == 0:
		_clear_emulator_version(emulator_id)
		_pending_emulator_version.erase(emulator_id)
		# If the emulator was already fully installed, this is a reinstall/update:
		# force all steps to re-run instead of short-circuiting on existing files.
		# Preserve user config files across the overwrite.
		if progress["status"] == "complete":
			_force_install_step[emulator_id] = true
			_begin_config_guard(emulator_id)
		else:
			_force_install_step.erase(emulator_id)
	
	return _execute_install_step(emulator_id, start_step)

## True when the flow needs restricted-path access to the emulator's private
## /Android/data folder: either an install step references {app_data}, or a
## declared save/firmware directory resolves under Android/data|obb. The
## latter matters because those dirs are auto-created when the steps finish
## (_create_emulator_save_directory) - without a grant that creation fails
## and every later save sync is denied.
func _install_flow_needs_app_data(emulator_id: String, install_steps: Array) -> bool:
	if JSON.stringify(install_steps).contains("{app_data}"):
		return true
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return false
	var platforms: Array = emulator.get("meta", {}).get("platforms", [])
	if platforms.is_empty():
		platforms = [""]
	for platform in platforms:
		if _declared_path_needs_grant(DataManager.resolve_default_save_directory(emulator_id, platform)):
			return true
		if _declared_path_needs_grant(launch_manager.firmware.get_firmware_directory(emulator_id, platform)):
			return true
	return false

## True when no access route to the path exists on this device - the install
## flow should prompt for a document-tree grant before touching it.
func _declared_path_needs_grant(path: String) -> bool:
	if path == "":
		return false
	return SystemManager.platform.access_route(path) == PlatformSubManager.AccessRoute.NONE

## Gates an install flow on Android app-data access. Returns true when the
## grant picker was just shown (caller must pause; the callback restarts the
## flow on grant, or fails it cleanly on denial). Returns false when access
## already exists, the path isn't restricted, or we're not on Android.
func _prompt_for_app_data_access(emulator_id: String) -> bool:
	if not SystemManager.platform.is_android():
		return false
	var app_data = LaunchManager.get_app_data_path(emulator_id)
	if app_data == "":
		return false
	if SystemManager.platform.has_android_data_access(app_data):
		return false
	# Re-entrancy guard: one picker per emulator at a time.
	if _install_grant_prompt_pending.has(emulator_id):
		return true
	_install_grant_prompt_pending[emulator_id] = true
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)
	print("[EmulatorManager] Install for " + emulator_id + " needs storage access to " + app_data + " - prompting")
	_emulator_install_progress[emulator_id] = "Waiting for storage access..."
	SystemManager.platform.ensure_android_data_access(func(granted: bool):
		_install_grant_prompt_pending.erase(emulator_id)
		if granted:
			print("[EmulatorManager] Storage access granted for " + emulator_id + " - restarting install flow")
			_execute_install_steps(emulator_id, {}, [])
		else:
			push_warning("[EmulatorManager] Storage access denied for " + emulator_id)
			_emulator_install_progress[emulator_id] = "Storage access denied"
			_end_force_install(emulator_id)
			install_steps_failed.emit(emulator_id, "Storage access denied for " + emulator_name)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
	, app_data)
	return true

## Gets display name for a step based on step_name
## Optionally prepends the emulator name for context in notifications
func _get_step_display_name(step_name: String, emulator_name: String = "") -> String:
	# Map step names to user-friendly display names
	var step_label = ""
	match step_name:
		"download_emulator":
			step_label = "Downloading"
		"install_emulator":
			step_label = "Installing"
		"download_cores":
			step_label = "Downloading Cores"
		"install_cores":
			step_label = "Installing Cores"
		"download_system_files":
			step_label = "Downloading System Files"
		"install_system_files":
			step_label = "Installing System Files"
		_:
			# Convert snake_case to Title Case with spaces
			var words = step_name.split("_")
			for i in range(words.size()):
				if i > 0:
					step_label += " "
				step_label += words[i].capitalize()
	
	if emulator_name != "":
		return emulator_name + " - " + step_label
	return step_label

## Checks if an Android package is installed using the KyodaiBridge plugin
func _is_android_package_installed(package_name: String) -> bool:
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		return false
	
	# Check the main package name first
	var result = plugin.isPackageInstalled(package_name)
	
	if result:
		return true
	
	# For RetroArch, check common variants
	if package_name == "com.retroarch":
		var variants = ["com.retroarch.aarch64", "com.retroarch.ra32"]

		for i in range(variants.size()):
			var variant = variants[i]
			result = plugin.isPackageInstalled(variant)

			if result:
				return true

	return false

## Seeds an Android emulator's private SharedPreferences through the vendor root
## daemon (AYN/Retroid PServerBinder, Ayaneo xsu) when the emulator JSON declares
## a "provision" block with method "root_shared_prefs". Used to pre-complete
## emulator OOBE setup on handhelds (e.g. x1box's setup_complete + file paths).
## Returns true when there is nothing to do (no provision block, no root route,
## or prefs already hold the requested values). Failures are logged, never fatal.
func provision_via_root(emulator_id: String) -> bool:
	var emulator: Dictionary = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return true
	var provision: Dictionary = emulator.get("provision", {}).get("android", {})
	if provision.get("method", "") != "root_shared_prefs":
		return true

	if not Engine.has_singleton("KyodaiBridge"):
		return true
	var plugin = Engine.get_singleton("KyodaiBridge")
	# has_method() reports false for GodotPlugin-exposed Java methods (they
	# dispatch dynamically via JNI, not ClassDB), so call directly; a stale AAR
	# without the method yields null, treated as unavailable.
	var root_available = plugin.call("rootAvailable")
	if root_available == null:
		root_available = false
	if not root_available:
		if DEBUG_LOG: print("[EmulatorManager] No vendor root route; skipping provisioning for " + emulator_id)
		return true

	var package: String = provision.get("package", "")
	if package == "":
		package = emulator.get("launch", {}).get("platforms", {}).get("android", {}).get("package", "")
	var prefs_file: String = provision.get("file", "")
	var entries: Dictionary = provision.get("entries", {})
	if package == "" or prefs_file == "" or entries.is_empty():
		push_warning("[EmulatorManager] Incomplete provision block for " + emulator_id)
		return true

	# These values are interpolated into a script executed as root; refuse
	# anything that isn't a plain package / prefs file name.
	if not _is_valid_android_package(package) or not _is_valid_prefs_file_name(prefs_file):
		push_warning("[EmulatorManager] Unsafe provision package/file for " + emulator_id + " ('" + package + "', '" + prefs_file + "'); refusing root provisioning")
		return true

	# Resolve placeholders to the absolute storage paths the target app itself
	# will validate (File(path).isFile from that app's process).
	var resolved := {}
	for key in entries:
		var entry: Dictionary = entries[key]
		var value := str(entry.get("value", ""))
		if value.contains("{") and value.contains("}"):
			value = FSM.resolve_emulator_path(value, emulator_id, "")
		resolved[key] = {"type": str(entry.get("type", "string")), "value": value}

	var prefs_path := "/data/data/" + package + "/shared_prefs/" + prefs_file + ".xml"

	# Satisfied-check first: when every requested value is already present there
	# is nothing to write and no force-stop is needed.
	var current := _root_read_prefs(plugin, prefs_path)
	if current != "" and _prefs_satisfied(current, resolved):
		if DEBUG_LOG: print("[EmulatorManager] Prefs already provisioned for " + package)
		return true

	var xml := _merge_prefs_xml(current, resolved)
	var result: Dictionary = _root_run(plugin, _build_prefs_write_script(package, prefs_path, xml))
	var exit_code = result.get("exit")
	if exit_code == null or int(exit_code) != 0:
		push_warning("[EmulatorManager] Root provisioning failed for " + package + ": exit=" + str(exit_code) + " output=" + str(result.get("output", "")))
		return false

	print("[EmulatorManager] Provisioned private prefs for " + package + " via vendor root")
	return true

## Reads an Android emulator's SAF-picked user directory from its private
## SharedPreferences via vendor root when the emulator JSON declares a
## "discover" block with method "root_read_pref" (azahar's CITRA_DIRECTORY).
## The decoded path is adopted as the emulator's {emulator_dir} override so
## firmware/save/config resolution follows the app's real location. Runs on
## every launch prep so a folder change inside the app self-heals.
## Returns the discovered POSIX path, or "" when unavailable.
func discover_external_dir_via_root(emulator_id: String) -> String:
	var emulator: Dictionary = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	var discover: Dictionary = emulator.get("discover", {}).get("android", {})
	if discover.get("method", "") != "root_read_pref":
		return ""
	if discover.get("format", "saf_tree_uri") != "saf_tree_uri":
		push_warning("[EmulatorManager] Unsupported discover format for " + emulator_id)
		return ""

	if not Engine.has_singleton("KyodaiBridge"):
		return ""
	var plugin = Engine.get_singleton("KyodaiBridge")
	# Same JNI dispatch caveat as provision_via_root: has_method() lies for
	# GodotPlugin Java methods, so call directly; null means unavailable and
	# Java booleans arrive as int, hence truthiness.
	var root_available = plugin.call("rootAvailable")
	if root_available == null or not root_available:
		return ""

	var package: String = discover.get("package", "")
	if package == "":
		package = emulator.get("launch", {}).get("platforms", {}).get("android", {}).get("package", "")
	var prefs_file: String = discover.get("file", "")
	var keys: Array = discover.get("keys", [])
	if package == "" or prefs_file == "" or keys.is_empty():
		push_warning("[EmulatorManager] Incomplete discover block for " + emulator_id)
		return ""
	# Same KYD-08 rule as provisioning: these values land in a root shell
	# script, so refuse anything that isn't a plain package / prefs file name.
	if not _is_valid_android_package(package) or not _is_valid_prefs_file_name(prefs_file):
		push_warning("[EmulatorManager] Unsafe discover package/file for " + emulator_id + " ('" + package + "', '" + prefs_file + "'); refusing root read")
		return ""

	var prefs_path := "/data/data/" + package + "/shared_prefs/" + prefs_file + ".xml"
	var xml := _root_read_prefs(plugin, prefs_path)
	if xml == "":
		return ""

	for key in keys:
		var posix := _saf_tree_uri_to_posix(_extract_pref_string(xml, str(key)))
		if posix == "":
			continue
		_adopt_discovered_emulator_dir(emulator_id, posix)
		return posix
	return ""

## Extracts a <string name="key">value</string> entry from a SharedPreferences
## XML dump; "" when absent.
func _extract_pref_string(xml: String, key: String) -> String:
	# The key is interpolated into a regex; restrict it to plain identifiers.
	var key_re := RegEx.new()
	if key_re.compile("^[A-Za-z0-9_]+$") != OK or key_re.search(key) == null:
		return ""
	var re := RegEx.new()
	if re.compile("<string name=\"" + key + "\">(.*?)</string>") != OK:
		return ""
	var m := re.search(xml)
	if m == null:
		return ""
	return _xml_unescape(m.get_string(1))

## Decodes an ExternalStorageProvider tree URI
## (content://com.android.externalstorage.documents/tree/primary%3A...) to its
## POSIX path. "primary" maps to /storage/emulated/0; other volume IDs map to
## /storage/<id>. Returns "" for anything unrecognized or unsafe.
func _saf_tree_uri_to_posix(uri: String) -> String:
	if not uri.begins_with("content://"):
		return ""
	var decoded := uri.uri_decode()
	var marker := "/tree/"
	var idx := decoded.find(marker)
	if idx < 0:
		return ""
	var doc_id := decoded.substr(idx + marker.length())
	var sep := doc_id.find(":")
	if sep <= 0:
		return ""
	var volume := doc_id.substr(0, sep)
	var rel := doc_id.substr(sep + 1).trim_prefix("/")
	# The volume ID lands in a filesystem path; refuse traversal and anything
	# that isn't a plain storage volume name.
	var vol_re := RegEx.new()
	if vol_re.compile("^[A-Za-z0-9_\\-]+$") != OK or vol_re.search(volume) == null:
		return ""
	if rel == "" or rel.contains("..") or rel.contains(":"):
		return ""
	var base := "/storage/emulated/0" if volume == "primary" else "/storage/" + volume
	return base + "/" + rel

## Persists a discovered external dir, which redirects {emulator_dir} for the
## emulator (registry consults the setting first). No-op when unchanged.
func _adopt_discovered_emulator_dir(emulator_id: String, path: String) -> void:
	if not DataManager:
		return
	var setting = DataManager.get_setting("external_emulator_dirs")
	if setting == null or not setting.value is Dictionary:
		return
	var dirs: Dictionary = setting.value
	if str(dirs.get(emulator_id, "")) == path:
		return
	dirs[emulator_id] = path
	# In-place dictionary mutation never trips set_setting's change detection,
	# so force it and persist immediately: this anchors firmware/save paths.
	DataManager.set_setting(dirs, setting, true)
	DataManager.save_settings()
	print("[EmulatorManager] Adopted discovered " + emulator_id + " user dir: " + path)

## Runs a script through the plugin's vendor-root bridge; {} when unavailable.
func _root_run(plugin: Object, script: String) -> Dictionary:
	var raw: String = plugin.call("rootRunScript", script)
	if raw == "":
		return {}
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}

## Reads a private prefs file as root; "" when absent or unreadable.
func _root_read_prefs(plugin: Object, prefs_path: String) -> String:
	var result := _root_run(plugin, "cat " + FSM._shell_quote(prefs_path) + " 2>/dev/null")
	var exit_code = result.get("exit")
	if exit_code == null or int(exit_code) != 0:
		return ""
	return str(result.get("output", ""))

## True when the prefs XML already holds every requested entry verbatim.
func _prefs_satisfied(xml: String, entries: Dictionary) -> bool:
	for key in entries:
		if not xml.contains(_pref_entry_fragment(key, entries[key])):
			return false
	return true

## Merges requested entries into existing prefs XML line-wise (preserving keys
## the app wrote itself), or builds a fresh document when none exists.
func _merge_prefs_xml(existing: String, entries: Dictionary) -> String:
	if not existing.contains("</map>"):
		var body := ""
		for key in entries:
			body += _pref_entry_xml_line(key, entries[key]) + "\n"
		return "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n" + body + "</map>\n"

	var merged := ""
	var handled := {}
	for line in existing.split("\n"):
		var claimed := false
		for key in entries:
			if line.contains("name=\"" + key + "\""):
				claimed = true
				if not handled.has(key):
					merged += _pref_entry_xml_line(key, entries[key]) + "\n"
					handled[key] = true
				break
		if claimed:
			continue
		if line.contains("</map>"):
			for key in entries:
				if not handled.has(key):
					merged += _pref_entry_xml_line(key, entries[key]) + "\n"
		merged += line + "\n"
	return merged

func _pref_entry_xml_line(key: String, entry: Dictionary) -> String:
	match str(entry.get("type", "string")):
		"boolean", "int":
			return "    <" + str(entry.type) + " name=\"" + key + "\" value=\"" + str(entry.value) + "\" />"
		_:
			return "    <string name=\"" + key + "\">" + _xml_escape(str(entry.value)) + "</string>"

## The fragment _prefs_satisfied looks for: exact attribute/value pair or
## element body, matching how the app itself serializes these keys.
func _pref_entry_fragment(key: String, entry: Dictionary) -> String:
	match str(entry.get("type", "string")):
		"boolean", "int":
			return "name=\"" + key + "\" value=\"" + str(entry.value) + "\""
		_:
			return "<string name=\"" + key + "\">" + _xml_escape(str(entry.value)) + "</string>"

## Root-side write: stop the app (it caches prefs in memory and would clobber
## the file on exit), write via base64 to dodge quoting, then fix ownership,
## mode, and SELinux label so the app can read its own prefs.
## package/prefs_path come from registry JSON (including user overrides), so
## every interpolation into this root-executed script must be shell-quoted.
func _build_prefs_write_script(package: String, prefs_path: String, xml: String) -> String:
	var b64 := Marshalls.utf8_to_base64(xml)
	var dir := prefs_path.get_base_dir()
	var q_package := FSM._shell_quote(package)
	var q_path := FSM._shell_quote(prefs_path)
	var q_dir := FSM._shell_quote(dir)
	var lines: Array = []
	lines.append("am force-stop " + q_package)
	lines.append("mkdir -p " + q_dir)
	lines.append("echo '" + b64 + "' | base64 -d > " + q_path)
	lines.append("OWN=$(stat -c '%u:%g' /data/data/" + q_package + ")")
	lines.append("chown $OWN " + q_dir + " " + q_path)
	lines.append("chmod 771 " + q_dir)
	lines.append("chmod 660 " + q_path)
	lines.append("restorecon -R " + q_dir + " 2>/dev/null || true")
	return "\n".join(lines) + "\n"

## Registry-supplied values end up inside scripts executed as root via vendor
## daemons. Validate strictly so a malicious or malformed registry entry
## cannot smuggle shell syntax into a root context (KYD-08).
static func _is_valid_android_package(package: String) -> bool:
	var re := RegEx.new()
	if re.compile("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$") != OK:
		return false
	return re.search(package) != null

static func _is_valid_prefs_file_name(prefs_file: String) -> bool:
	var re := RegEx.new()
	if re.compile("^[A-Za-z0-9_\\-]+(\\.[A-Za-z0-9_\\-]+)*$") != OK:
		return false
	return re.search(prefs_file) != null

func _xml_escape(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

func _xml_unescape(value: String) -> String:
	# &amp; must be replaced last so "&amp;lt;" decodes to "&lt;", not "<".
	return value.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")

## Validates a specific install step to check if it's complete
## Returns true if the step validation passes (step is complete)
func _validate_install_step(emulator_id: String, step_index: int, install_steps: Array) -> bool:
	if step_index >= install_steps.size():
		return true
	
	var step = install_steps[step_index]
	var platform_config = launch_manager.registry._get_step_platform_config(step)
	
	if platform_config.is_empty():
		# A step scoped to another OS can never complete here: treat it as not
		# applicable so the install doesn't stay "partial" forever (which would
		# re-trigger an install on every launch).
		if not launch_manager.registry.step_applies_to_platform(step):
			return true
		return false
	
	var action_type = platform_config.get("action_type", "")
	var validate_config = platform_config.get("validate", {})
	
	# If no validation config, consider step complete (just move on).
	# This handles download steps where the file gets deleted after extraction.
	# For extract steps, only consider it complete if no archive remains in the
	# emulator directory, otherwise a resume would skip extraction entirely.
	if validate_config.is_empty():
		if action_type == "extract":
			var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
			var expected_file = platform_config.get("expected_file", "")
			var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
			var files = FSM.list_dir(emulator_dir)
			for file_name in files:
				if file_name == "." or file_name == "..":
					continue
				if expected_file != "" and file_name.match(expected_file):
					return false
				var lower_name = file_name.to_lower()
				for ext in archive_extensions:
					if lower_name.ends_with(ext):
						return false
		return true
	
	# Run validation
	return _validate_step(emulator_id, validate_config)

## Scans install steps and finds the first incomplete step
## Returns a dictionary with progress info
## Uses caching to avoid redundant file system operations
func get_install_progress(emulator_id: String) -> Dictionary:
	# Check cache first (thread-safe: DB-thread precompute also reads this).
	_validation_cache_mutex.lock()
	if _validation_cache.has(emulator_id):
		var cached = _validation_cache[emulator_id]
		var elapsed = Time.get_ticks_msec() - cached.timestamp
		if elapsed < VALIDATION_CACHE_TTL_MS:
			_validation_cache_mutex.unlock()
			return cached.result
	_validation_cache_mutex.unlock()
	
	# Perform validation
	var result = _compute_install_progress(emulator_id)
	
	# Cache the result
	_validation_cache_mutex.lock()
	_validation_cache[emulator_id] = {
		"result": result,
		"timestamp": Time.get_ticks_msec()
	}
	_validation_cache_mutex.unlock()
	
	return result

## Internal function to compute install progress without caching
func _compute_install_progress(emulator_id: String) -> Dictionary:
	var result = {
		"total_steps": 0,
		"completed_steps": 0,
		"next_step_index": -1,
		"next_step_name": "",
		"next_step_display": "",
		"status": "not_started",  # "not_started", "partial", "complete"
		"is_installed": false
	}
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)

	if emulator.is_empty():
		return result
	
	var install_steps = emulator.get("install", [])
	result["total_steps"] = install_steps.size()
	
	# Scan each step
	for i in range(install_steps.size()):
		var step = install_steps[i]
		var step_name = step.get("step", "")
		if _validate_install_step(emulator_id, i, install_steps):
			result["completed_steps"] += 1
		else:
			# First incomplete step found
			if result["next_step_index"] == -1:
				result["next_step_index"] = i
				result["next_step_name"] = step_name
				result["next_step_display"] = _get_step_display_name(step_name, emulator_name)
	
	# Determine status
	if result["completed_steps"] == 0:
		result["status"] = "not_started"
	elif result["completed_steps"] == result["total_steps"]:
		result["status"] = "complete"
		result["is_installed"] = true
	else:
		result["status"] = "partial"
	
	return result

## Scans emulator installation and updates state based on step completion
## Call this when opening platform page to refresh state
func scan_emulator_install_state(emulator_id: String):
	var progress = get_install_progress(emulator_id)
	
	if progress["status"] == "complete":
		_emulator_install_progress[emulator_id] = ""
	elif progress["status"] == "partial":
		# Mark as partial - UI will show "Resume: [Step Name]"
		_emulator_install_progress[emulator_id] = "Resume: " + progress["next_step_display"]
	else:
		_emulator_install_progress[emulator_id] = ""

## Queues a direct emulator download for install steps that provide an
## explicit URL. Used by download_url, download_repo, and download_scrape
## handlers once they have resolved the final URL and display name.
func _queue_emulator_download(emulator_id: String, _emulator_name: String, step_display_name: String, download_url: String, step_index: int, step_config: Dictionary = {}, file_size: int = 0, expected_sha256: String = ""):
	# Use explicit filename from config if provided, otherwise extract from URL
	var filename = step_config.get("filename", "")
	if filename == "":
		filename = download_url.get_file()
	
	# Check for custom destination path (for firmware/shared files)
	var custom_destination = step_config.get("destination", "")
	var destination_path: String
	if custom_destination != "":
		FSM.make_dir_recursive(custom_destination)
		destination_path = FSM.join_paths(custom_destination, filename)
	else:
		destination_path = FSM.join_paths(launch_manager.registry._get_emulator_directory(emulator_id), filename)
	
	print("[EmulatorManager] Queueing download for " + emulator_id + ": " + filename + " -> " + destination_path)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue download WITHOUT auto-extract (extract is now a separate step)
	var item_id = SystemManager.download.queue_download(
		download_url,
		destination_path,
		"emulator",
		step_display_name,  # Use step-specific display name for notifications
		false,  # auto_extract = false
		"",  # extract_to = empty, we'll handle extraction separately
		null,  # game
		{},  # callbacks
		0,  # romm_id
		true,  # delete_after_extract
		suppress_step_notifications,  # suppress_notification (aggregate snackbar during update-all)
		file_size  # expected_file_size from GitHub API
	)
	
	if item_id == "":
		push_error("[EmulatorManager] Failed to queue download for: " + emulator_id)
		_emulator_install_progress[emulator_id] = "Failed to queue download"
		_end_force_install(emulator_id)
		install_steps_failed.emit(emulator_id, "Failed to queue download")
		launch_manager.emulator_extraction_completed.emit(emulator_id, false)
		return
	
	# Track download with step info for sequential execution
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "emulator",
		"step_index": step_index,
		"step_config": step_config,
		"filename": filename,
		"destination_path": destination_path,
		# API-attested SHA-256 from the release listing ("" = host publishes
		# none, verification skipped). Verified before any extract/install.
		"expected_sha256": expected_sha256,
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_progress[emulator_id] = message if message != "" else "Download failed"
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
	}

## Checks if an emulator is currently downloading or extracting
## Uses SystemManager.download to check active downloads for this emulator
func is_emulator_downloading(emulator_id: String) -> bool:
	# Check if any active item in SystemManager.download is for this emulator
	for item in SystemManager.download.get_active():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return item.status == "downloading" or item.status == "extracting"
	return false

## Checks if an emulator is queued for download
func is_emulator_queued(emulator_id: String) -> bool:
	# Check if any queued item in SystemManager.download is for this emulator
	for item in SystemManager.download.get_queued():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return true
	return false

## Gets the active download item for an emulator (if any)
## Returns the SystemManager.download.QueueItem or null
func get_emulator_active_download(emulator_id: String):
	for item_id in _pending_emulator_downloads:
		var task = _pending_emulator_downloads[item_id]
		if task.emulator_id == emulator_id:
			for item in SystemManager.download.get_active():
				if item.id == item_id:
					return item
	return null

## Handles download completion
func _on_unified_download_completed(item_id: String, success: bool, message: String):
	print("[EmulatorManager] _on_unified_download_completed: item_id=%s success=%s" % [item_id, success])
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		var emulator_id = task_info.emulator_id
		var step_index = task_info.get("step_index", 0)
		var step_config = task_info.get("step_config", {})
		_pending_emulator_downloads.erase(item_id)
		
		if not success:
			_emulator_install_progress[emulator_id] = "Download failed: " + message
			_pending_emulator_version.erase(emulator_id)
			_end_force_install(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, message)
			return

		# Verify the download against the SHA-256 digest attested by the
		# release API at listing time (KYD-09). Skipped when the host
		# publishes no digest. A mismatch means the bytes on disk are NOT
		# what the release API advertised - delete and abort, never install.
		var expected_sha256: String = task_info.get("expected_sha256", "")
		if expected_sha256 != "":
			var dest_path: String = task_info.get("destination_path", "")
			_emulator_install_progress[emulator_id] = "Verifying download..."
			var actual_sha256 := FSM.sha256_file(dest_path)
			if actual_sha256 == "" or actual_sha256.to_lower() != expected_sha256.to_lower():
				push_error("[EmulatorManager] SHA-256 mismatch for %s: expected %s, got %s - deleting download" % [emulator_id, expected_sha256, actual_sha256])
				FSM.delete_file(dest_path)
				_emulator_install_progress[emulator_id] = "Download verification failed"
				_pending_emulator_version.erase(emulator_id)
				_end_force_install(emulator_id)
				SystemManager.notifications.show_notification(
					"Verification failed for " + emulator_id + " - the download does not match the publisher's checksum and was deleted",
					SystemManager.notifications.Type.ERROR
				)
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
				task_info.callback.call(false, "Checksum verification failed")
				return
			print("[EmulatorManager] SHA-256 verified for " + emulator_id + " download")

		# Validate download if validation config exists
		var validate_config = step_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Download validation failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Download validation failed"
			_pending_emulator_version.erase(emulator_id)
			_end_force_install(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Validation failed")
			return
		
		# For batch downloads, let the callback handle progress tracking and step advancement
		# The callback only advances when ALL items in the batch are complete
		if task_info.get("context", "") == "batch_download":
			task_info.callback.call(true, "")
			return
		
		# Clear validation cache so the UI reflects the completed download
		_erase_validation_cache(emulator_id)
		
		# For non-batch downloads, proceed to next step
		print("[EmulatorManager] Download completed for %s, advancing to step %d" % [emulator_id, step_index + 1])
		var step_success = _execute_install_step(emulator_id, step_index + 1)
		if not step_success:
			push_error("[EmulatorManager] Install step " + str(step_index + 1) + " failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Install step failed"
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Install step failed")
		return
