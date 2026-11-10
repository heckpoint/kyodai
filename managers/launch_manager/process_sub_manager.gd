extends Manager
class_name ProcessSubManager

## Process launch and background-state management

const DEBUG_LOG: bool = false
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
# AndroidBinaryExtractor is a global class; no preload const needed.

# Background state tracking (desktop only)
var _background_active_pid: int = -1
var _background_active_game: GameResource = null
var _background_active_signature: String = ""
var _background_active_exe_signature: String = ""
var _is_in_background_state: bool = false
var _background_poll_timer: Timer = null
var _poll_in_flight: bool = false
const BACKGROUND_POLL_INTERVAL: float = 1.0
# Android session ownership lives in the Java session service (its own
# :session process), which watches emulator presence via UsageStats and
# survives an LMK kill of this process. GDScript only supplies the emulator
# package at launch and consumes the record the service leaves behind.
var _android_emulator_package: String = ""
var _android_presence_perm_warned: bool = false
# Linux launches lead their own process group (Godot's create_process calls
# setsid() in the forked child): every wrapper/payload descendant (AppImage
# AppRun, sh, env) shares its PGID. Group liveness is the source of truth
# for "is the game
# still running" — it survives the reparenting/forking that gamescope and
# AppImage runtimes inflict on single-PID tracking.
var _background_active_pgid: int = -1
# Two consecutive dead reads are required before exiting background state;
# a single /proc race right after a fork/exec must not tear down input gating.
var _background_dead_streak: int = 0
const DEAD_STREAK_EXIT_THRESHOLD: int = 2
# Game Mode (gamescope) additionally tracks the game window by XID — as a
# CACHE, not an identity. Emulators recreate their window (Vita3K, Cemu game
# boot, fullscreen transitions), so a vanished XID triggers a re-find against
# the whole process group rather than an exit. Only a window that stays gone
# while the process group lingers ends the session (and reaps the group).
var _background_window_xid: String = ""
var _background_window_hint: String = ""
var _background_window_misses: int = 0
const WINDOW_MISS_EXIT_THRESHOLD: int = 5
# Safety net: if background state is exited while the emulator's process
# group is somehow still alive (forced exits, detection misses), launcher
# input stays blocked until the group actually dies. Degrades a detection
# miss into "input briefly stuck" instead of "double-inputting two apps".
var _lingering_pgid: int = -1
var _lingering_timer: Timer = null
const LINGERING_POLL_INTERVAL: float = 2.0
# Cached own-process PGID: group signals must never target Kyodai's own group.
var _own_pgid: int = -1

# Game session tracking (playtime + Android LMK protection). The pending
# session record is written to disk BEFORE the handoff so that a process
# kill mid-session (LMK, crash) can be recovered on the next launch.
var _active_session: GameSession = null
var _background_backend: GameSession.Backend = GameSession.Backend.UNKNOWN
var _recovery_in_progress: bool = false
var _recovery_rerun_requested: bool = false
var _recovery_retry_scheduled: bool = false
var _initial_recovery_completed: bool = false
signal recovery_completed
signal android_retention_configured
var _android_retention_configuring := false
var _android_retention_uncertain := false

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

	# Initialize background state polling (desktop PGID liveness; the Android
	# presence watch lives in the Java session service, not here).
	_background_poll_timer = Timer.new()
	_background_poll_timer.wait_time = BACKGROUND_POLL_INTERVAL
	_background_poll_timer.one_shot = false
	_background_poll_timer.timeout.connect(_on_background_poll_timeout)
	add_child(_background_poll_timer)
	if DEBUG_LOG: print("[ProcessManager] Poll timer created, in_tree=", _background_poll_timer.is_inside_tree(), " wait=", _background_poll_timer.wait_time)

	# Recover after the facade has connected registry signals. Every pending
	# record first gets a chance to prove its runtime survived; launcher death
	# alone does not prove that the game ended.
	if DataManager.database.is_database_ready():
		call_deferred("_recover_pending_sessions")
	else:
		DataManager.database_ready.connect(func(): call_deferred("_recover_pending_sessions"), CONNECT_ONE_SHOT)

	# Any native watch from the old process is stopped before recovery. The
	# registry re-arms it only when a pending runtime is actually reattached; terminal
	# recovery stops permanently, and no watch is left for an empty record.
	SystemManager.platform.stop_game_session_foreground_service()


# ============================================================================
# SHELL ESCAPING HELPERS (prevent command injection from user-controlled paths)
# ============================================================================

## Escapes a string for safe use inside Windows cmd.exe double quotes.
## Inside a quoted cmd string only % and " need special handling:
##   - % is doubled to prevent environment-variable expansion.
##   - " is doubled because a pair of double quotes inside a quoted string
##     represents one literal double quote.
## Other cmd metacharacters (& | < > ^ ( )) are literal inside quotes,
## so escaping them with ^ would actually introduce literal carets into paths.
func _escape_cmd_meta(s: String) -> String:
	var result = s.replace("%", "%%")
	# Double quotes are escaped by doubling them inside a quoted string
	result = result.replace('"', '""')
	return result

## Escapes a string for safe use inside Unix sh single quotes.
## Wraps in single quotes and handles embedded single quotes.
func _escape_sh_arg(s: String) -> String:
	# Single quotes prevent ALL interpretation in sh
	# To embed a single quote, close the quote, add an escaped quote, reopen
	return "'" + s.replace("'", "'\"'\"'") + "'"

## Escapes an array of arguments for the current platform's shell.
func _escape_args_for_shell(args: Array) -> Array:
	var result = []
	if SystemManager.platform.is_windows():
		for arg in args:
			result.append('"' + _escape_cmd_meta(arg) + '"')
	else:
		for arg in args:
			result.append(_escape_sh_arg(arg))
	return result

# ============================================================================
# APPIMAGE ENVIRONMENT SANITIZATION
# ============================================================================

## Returns true if candidate path is inside (or equal to) app_dir.
func _is_within_app_dir(candidate: String, app_dir: String) -> bool:
	var norm_candidate = candidate.replace("\\", "/").rstrip("/")
	var norm_app_dir = app_dir.replace("\\", "/").rstrip("/")
	return norm_candidate == norm_app_dir or norm_candidate.begins_with(norm_app_dir + "/")

## Removes entries inside app_dir from a colon/space separated path variable.
func _clean_path_var(value: String, app_dir: String) -> String:
	if value == "":
		return ""
	# LD_PRELOAD may be space-separated; everything else uses colons.
	# Normalize whitespace to colons so a single split covers both cases.
	var normalized = value.replace(" ", ":").replace("\t", ":")
	var parts = normalized.split(":", false)
	var cleaned: Array[String] = []
	for part in parts:
		if _is_within_app_dir(part, app_dir):
			continue
		cleaned.append(part)
	return ":".join(cleaned)

## Builds env(1) arguments that strip Kyodai's AppImage identity and apply
## per-emulator overrides. Returns an empty array on non-Linux platforms.
func _build_linux_env_args(intent: LaunchIntent) -> Array[String]:
	if not SystemManager.platform.is_linux():
		return []

	var env_args: Array[String] = []

	# Strip AppImage identity variables so child emulators don't mistake
	# Kyodai's AppImage for their own.
	for var_name in ["APPIMAGE", "APPDIR", "ARGV0", "OWD"]:
		env_args.append("-u")
		env_args.append(var_name)

	# Clean PATH-like variables of entries bundled inside Kyodai's AppImage.
	var app_dir = OS.get_environment("APPDIR")
	if app_dir != "":
		var path_vars = [
			"PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PERLLIB",
			"XDG_DATA_DIRS", "GTK_PATH", "GIO_EXTRA_MODULES", "GI_TYPELIB_PATH",
			"GSETTINGS_SCHEMA_DIR", "GDK_PIXBUF_MODULE_FILE",
			"QT_PLUGIN_PATH", "QT_QPA_PLATFORM_PLUGIN_PATH",
			"QML_IMPORT_PATH", "QML2_IMPORT_PATH"
		]
		for var_name in path_vars:
			var value = OS.get_environment(var_name)
			if value == "":
				continue
			var cleaned = _clean_path_var(value, app_dir)
			if cleaned == value:
				continue
			if cleaned == "":
				env_args.append("-u")
				env_args.append(var_name)
			else:
				env_args.append(var_name + "=" + cleaned)

	# Apply per-emulator environment overrides from the launch config.
	for var_name in intent.environment:
		env_args.append(var_name + "=" + str(intent.environment[var_name]))

	return env_args

## Escapes env(1) arguments for safe use inside a sh single-quoted string.
func _escape_env_args_for_shell(args: Array[String]) -> String:
	var escaped: Array[String] = []
	for arg in args:
		escaped.append(_escape_sh_arg(arg))
	return " ".join(escaped)

## Escapes a string for safe use as a single-quoted PowerShell argument.
## In PS single quotes only the single quote itself needs escaping (doubled).
func _escape_ps_arg(s: String) -> String:
	return "'" + s.replace("'", "''") + "'"

## Escapes a string for use inside Start-Process -ArgumentList.
## PowerShell joins -ArgumentList entries with spaces WITHOUT re-quoting them,
## so each entry is additionally wrapped in literal double quotes to keep
## paths containing spaces intact on the target process command line.
func _escape_ps_arg_quoted(s: String) -> String:
	return "'\"" + s.replace("'", "''") + "\"'"

## Spawns a short-lived helper (x11_windowctl, kill, ...) via the shared
## queue. Under Steam/gamescope the session-wide LD_PRELOAD (32-bit
## gameoverlayrenderer.so) only produces ld.so noise in our 64-bit helpers,
## so it is stripped for the spawn.
func queue_helper_execute(path: String, args: Array, callback: Callable = Callable()) -> void:
	if SystemManager.platform.is_linux() and OS.get_environment("LD_PRELOAD") != "":
		var env_args: Array = ["-u", "LD_PRELOAD", path]
		env_args.append_array(args)
		MemorySubManager.queue_os_execute("env", env_args, callback)
		return
	MemorySubManager.queue_os_execute(path, args, callback)

## Resolves the path to the x11_windowctl helper, extracting it from the
## package if running a shipped build so the binary is executable.
func _resolve_x11_windowctl_path() -> String:
	if SystemManager.platform.is_packaged():
		return AndroidBinaryExtractor.extract_binary("res://bin/linux/x11_windowctl", "x11_windowctl")
	return ProjectSettings.globalize_path("res://bin/linux/x11_windowctl")

# ==================== BACKGROUND STATE (DESKTOP ONLY) ====================

## Returns true if currently in background state (emulator running)
func is_in_background_state() -> bool:
	return _is_in_background_state

## Returns the active process PID, or -1 if none
func get_background_pid() -> int:
	return _background_active_pid

## Returns the active game during background state, or null
func get_background_game() -> GameResource:
	return _background_active_game

## Enter background state with active PID
func enter_background_state(pid: int, game: GameResource, intent: LaunchIntent = null) -> void:
	if _is_in_background_state:
		if DEBUG_LOG: print("[ProcessManager] Warning: Already in background state, ignoring new PID ", pid)
		return

	if pid <= 0:
		push_error("[ProcessManager] Invalid PID for background state: " + str(pid))
		return

	print("[ProcessManager] Entering background state with PID: ", pid)
	_background_backend = GameSession.Backend.DESKTOP_PROCESS
	_background_active_pid = pid
	_background_active_pgid = get_pgid(pid)
	if _background_active_pgid <= 0 and SystemManager.platform.is_linux():
		# Godot setsid()s the spawned leader, making it its own group; assume
		# that layout when the stat read raced the process.
		_background_active_pgid = pid
	_background_dead_streak = 0
	_background_window_misses = 0
	_background_active_game = game
	_is_in_background_state = true
	_background_window_xid = ""
	_background_window_hint = ""
	if intent != null:
		_background_window_hint = intent.emulator_id
	dump_process_state("enter_background_state")

	# Build command-line signatures for /proc fallback scanning. The ROM path is
	# the most reliable signature because it appears in the actual emulator's
	# cmdline even when wrapper processes fork/reparent it away from us.
	if game != null and game.file_path != "":
		_background_active_signature = game.file_path
	elif intent != null and not intent.launch_args.is_empty():
		# Fallback: use the last launch argument, which is commonly the ROM path.
		_background_active_signature = intent.launch_args[-1]
	if intent != null and not intent.launch_args.is_empty():
		var exe_name := str(intent.launch_args[0]).get_file().get_basename().to_lower()
		if exe_name != "":
			_background_active_exe_signature = exe_name
	if DEBUG_LOG: print("[ProcessManager] Background signatures: rom=\"", _background_active_signature, "\" exe=\"", _background_active_exe_signature, "\"")

	if _background_poll_timer:
		if DEBUG_LOG: print("[ProcessManager] Starting poll timer, in_tree=", _background_poll_timer.is_inside_tree(), " active=", _background_poll_timer.is_stopped())
		_background_poll_timer.start()
		if DEBUG_LOG: print("[ProcessManager] Poll timer started")
	else:
		if DEBUG_LOG: print("[ProcessManager] Poll timer not available")

	_begin_game_session(game)

## Enter background state for Android. The session service (its own process)
## owns session end from here: it watches emulator presence via UsageStats,
## annotates the pending record with end_unix, and cold-starts us into save
## upload when the game exits. This process only finalizes on resume.
func enter_background_state_android(game: GameResource, emulator_package: String = "") -> void:
	if _is_in_background_state:
		if DEBUG_LOG: print("[ProcessManager] Warning: Already in background state, ignoring Android entry")
		return

	print("[ProcessManager] Entering background state for Android launch")
	_background_backend = GameSession.Backend.ANDROID_TASK
	_background_active_pid = -1  # No PID on Android
	_background_active_game = game
	_is_in_background_state = true
	_android_emulator_package = emulator_package

	# Without usage access the service's presence watch can't run; the session
	# then ends on our resume only, and a kill loses the end timestamp.
	if emulator_package != "" and not SystemManager.platform.has_usage_stats_permission() and not _android_presence_perm_warned:
		_android_presence_perm_warned = true
		push_warning("[ProcessManager] Usage Access not granted; session presence watch disabled (session ends on resume only). Grant via Settings > Usage access.")

	_begin_game_session(game)
	_configure_android_retention()

func _configure_android_retention() -> void:
	var session := _active_session
	if session == null or session.backend != GameSession.Backend.ANDROID_TASK:
		return
	_android_retention_configuring = true
	_android_retention_uncertain = false
	if _android_emulator_package.is_empty() or not await launch_manager.android_tasks.retention_available():
		_android_retention_uncertain = launch_manager.android_tasks.retention_probe_inconclusive()
		_finish_android_retention_configuration()
		return
	for attempt in 10:
		if _active_session != session:
			_finish_android_retention_configuration()
			return
		var result: Dictionary = await launch_manager.android_tasks.list_tasks()
		if _active_session != session or session.state == GameSession.State.ENDED or session.state == GameSession.State.CLOSING:
			_finish_android_retention_configuration()
			return
		if result.get("ok", false):
			var candidates: Array = []
			for task in result.get("tasks", []):
				if str(task.get("packageName", "")) == _android_emulator_package:
					candidates.append(task)
			if candidates.size() == 1:
				var task: Dictionary = candidates[0]
				session.runtime.merge({
					"taskId": int(task.taskId),
					"package": str(task.packageName),
					"topActivity": str(task.topActivity),
					"baseActivity": str(task.get("baseActivity", "")),
					"displayId": int(task.get("displayId", 0)),
					"userId": int(task.get("userId", 0)),
				}, true)
				session.policy["retain"] = true
				launch_manager.sessions.update_runtime(session, session.runtime)
				launch_manager.sessions._start_native_watch(session)
				launch_manager.android_tasks.set_retained_identity(session.runtime, true)
				print("[ProcessManager] Android retained task registered: ", session.runtime)
				_finish_android_retention_configuration()
				return
		# Each native list operation already has latency and a deadline. SceneTree
		# timers do not run while Kyodai is backgrounded, so retry directly.
	# Supported hardware with an unverified task identity is uncertain, never
	# proof that the emulator exited or that standard finalization is safe.
	_android_retention_uncertain = launch_manager.android_tasks.retention_available_cached()
	_finish_android_retention_configuration()

func _finish_android_retention_configuration() -> void:
	if not _android_retention_configuring:
		return
	_android_retention_configuring = false
	android_retention_configured.emit()

func has_retained_android_session() -> bool:
	return _active_session != null and _active_session.backend == GameSession.Backend.ANDROID_TASK \
		and bool(_active_session.policy.get("retain", false)) \
		and (_active_session.state == GameSession.State.ACTIVE or _active_session.state == GameSession.State.RETAINED)

func has_other_retained_game(romm_id: int) -> bool:
	return has_retained_android_session() and _active_session.romm_id != romm_id

func get_active_android_session() -> GameSession:
	return _active_session

func retain_active_android_session() -> bool:
	if not has_retained_android_session() or _android_transition_inflight:
		return false
	# Home delivery can be duplicated by the intent and lifecycle callbacks.
	# The first retain owns the transition; all duplicates are harmless no-ops.
	_android_transition_inflight = true
	_is_in_background_state = false
	var session := _active_session
	launch_manager.android_tasks.set_retained_identity(session.runtime, false)
	launch_manager.sessions.retain_session(session, false)
	# Returning to Kyodai is also a reconciliation point. Emulator bootstrap
	# activities can hand off to a new task (RetroArch CoreSideloadActivity ->
	# RetroActivityFuture), so rebind a unique package/profile successor before
	# deciding that the emulator exited. Only a confirmed-missing package may
	# finalize the session and upload saves.
	var identity_status := await _reconcile_android_task_identity(session)
	if identity_status != "ok":
		_android_transition_inflight = false
		launch_manager.android_tasks.release_observer()
		if identity_status == "missing":
			await _finalize_android_sessions_for_package(str(session.runtime.get("package", "")))
		elif identity_status != "cancelled":
			mark_android_session_lost(session)
		return false
	var captured_any := false
	if await launch_manager.android_tasks.snapshots_available():
		for attempt in 4:
			var captured: Dictionary = await launch_manager.android_tasks.capture_snapshot(session.runtime)
			if captured.get("ok", false):
				GameCard.evict_session_snapshot(str(session.runtime.get("snapshotPath", "")))
				session.runtime["snapshotPath"] = str(captured.get("snapshot", {}).get("path", ""))
				launch_manager.sessions.update_runtime(session, session.runtime)
				captured_any = true
				break
	if not captured_any:
		GameCard.evict_session_snapshot(str(session.runtime.get("snapshotPath", "")))
		session.runtime.erase("snapshotPath")
		launch_manager.sessions.update_runtime(session, session.runtime)
	if _android_task_removal_pending:
		_android_task_removal_pending = false
		identity_status = await _reconcile_android_task_identity(session)
		if identity_status != "ok":
			_android_transition_inflight = false
			launch_manager.android_tasks.release_observer()
			if identity_status == "missing":
				await _finalize_android_sessions_for_package(str(session.runtime.get("package", "")))
			elif identity_status != "cancelled":
				mark_android_session_lost(session)
			return false
	_android_transition_inflight = false
	# Publish the snapshot to cards before starting the visible return
	# transition, so the grid cannot settle on stale cover art.
	session_changed_for_android()
	launch_manager.sessions.session_retained.emit(session)
	return true

func resume_retained_game(romm_id: int = -1) -> Dictionary:
	if _active_session == null or _android_transition_inflight:
		return {"ok": false, "code": "busy"}
	var session := _active_session
	if romm_id >= 0 and session.romm_id != romm_id:
		return {"ok": false, "code": "not_found"}
	if session.state == GameSession.State.LOST:
		return {"ok": false, "code": "lost"}
	_android_transition_inflight = true
	var identity_status := await _reconcile_android_task_identity(session)
	if identity_status != "ok":
		_android_transition_inflight = false
		if identity_status == "missing":
			mark_android_session_lost(session)
		return {"ok": false, "code": "task_unverified" if identity_status != "missing" else "stale_task"}
	var focused: Dictionary = await launch_manager.android_tasks.focus(session.runtime)
	_android_transition_inflight = false
	if focused.get("ok", false):
		var task: Dictionary = focused.get("task", {})
		if not task.is_empty():
			session.runtime.merge({
				"taskId": int(task.get("taskId", session.runtime.taskId)),
				"package": str(task.get("packageName", session.runtime.package)),
				"topActivity": str(task.get("topActivity", session.runtime.topActivity)),
				"baseActivity": str(task.get("baseActivity", session.runtime.get("baseActivity", ""))),
				"displayId": int(task.get("displayId", session.runtime.get("displayId", 0))),
				"userId": int(task.get("userId", session.runtime.get("userId", 0))),
			}, true)
			launch_manager.sessions.update_runtime(session, session.runtime)
		launch_manager.android_tasks.set_retained_identity(session.runtime, true)
		_background_backend = GameSession.Backend.ANDROID_TASK
		_background_active_game = session.game
		_android_emulator_package = str(session.runtime.get("package", ""))
		_is_in_background_state = true
		launch_manager.sessions.resume_session(session)
		launch_manager.sessions._start_native_watch(session)
		return {"ok": true}
	if focused.get("code", "") == "stale_task":
		mark_android_session_lost(session)
	return {"ok": false, "code": focused.get("code", "focus_failed"), "error": focused.get("error", "")}

func reconcile_android_task_removed(session: GameSession) -> void:
	if session == null or session != _active_session:
		return
	if session.state != GameSession.State.ACTIVE and session.state != GameSession.State.RETAINED:
		return
	if _android_transition_inflight:
		_android_task_removal_pending = true
		return
	# Native task events are hints to revalidate, not standalone finalization
	# permission. A task-removal event commonly describes a bootstrap activity
	# being replaced by the emulator's real gameplay task.
	var identity_status := await _reconcile_android_task_identity(session)
	if identity_status != "missing":
		return
	if session != _active_session or (session.state != GameSession.State.ACTIVE and session.state != GameSession.State.RETAINED):
		return
	await _finalize_android_sessions_for_package(str(session.runtime.get("package", "")))

func mark_android_session_lost(session: GameSession) -> void:
	if session == null:
		return
	_android_task_removal_pending = false
	session.state = GameSession.State.LOST
	launch_manager.android_tasks.clear_retained_identity()
	session.pause_playtime()
	_is_in_background_state = false
	launch_manager.sessions.update_runtime(session, session.runtime)
	launch_manager.sessions.session_changed.emit(session)

func close_retained_game(romm_id: int = -1) -> Dictionary:
	if _active_session == null or _android_transition_inflight:
		return {"ok": false, "code": "busy"}
	var session := _active_session
	if romm_id >= 0 and session.romm_id != romm_id:
		return {"ok": false, "code": "not_found"}
	_android_transition_inflight = true
	session.state = GameSession.State.CLOSING
	# Restore cover art immediately while native task-death confirmation runs.
	# Keep the snapshot on disk so a failed close can restore retained visuals.
	session_changed_for_android()
	var identity_status := await _reconcile_android_task_identity(session, true)
	if identity_status == "error" or identity_status == "ambiguous" or identity_status == "cancelled":
		session.state = GameSession.State.RETAINED
		_android_transition_inflight = false
		session_changed_for_android()
		return {"ok": false, "code": "task_unverified"}
	if identity_status == "ok":
		var stopped: Dictionary = await launch_manager.android_tasks.force_stop(session.runtime)
		if not stopped.get("ok", false) and stopped.get("code", "") != "stale_task":
			session.state = GameSession.State.RETAINED
			_android_transition_inflight = false
			session_changed_for_android()
			return stopped
	var removed: Dictionary = await launch_manager.android_tasks.remove_task(session.runtime)
	if not removed.get("ok", false) and removed.get("code", "") != "stale_task":
		session.state = GameSession.State.RETAINED
		_android_transition_inflight = false
		session_changed_for_android()
		return removed
	for attempt in 8:
		identity_status = await _reconcile_android_task_identity(session, true)
		if identity_status == "missing":
			break
		if identity_status == "error" or identity_status == "ambiguous" or identity_status == "cancelled":
			session.state = GameSession.State.RETAINED
			_android_transition_inflight = false
			session_changed_for_android()
			return {"ok": false, "code": "close_unconfirmed"}
	if identity_status != "missing":
		session.state = GameSession.State.RETAINED
		_android_transition_inflight = false
		session_changed_for_android()
		return {"ok": false, "code": "close_unconfirmed"}
	await _finalize_android_sessions_for_package(str(session.runtime.get("package", "")))
	_android_transition_inflight = false
	return {"ok": true}

func discard_lost_android_session() -> void:
	if _active_session == null:
		return
	await _finalize_android_sessions_for_package(str(_active_session.runtime.get("package", "")))

## Resolves the current task identity without treating an activity/task handoff
## as process death. A successor is accepted only when it is the sole task for
## the same package and user/profile. Errors and ambiguity are never proof that
## the emulator exited.
func _resolve_android_task(runtime: Dictionary) -> Dictionary:
	var result: Dictionary = await launch_manager.android_tasks.list_tasks()
	if not result.get("ok", false):
		return {"status": "error", "result": result}
	var package_name := str(runtime.get("package", ""))
	var task_id := int(runtime.get("taskId", -1))
	var user_id := int(runtime.get("userId", 0))
	if package_name.is_empty() or task_id <= 0:
		return {"status": "error", "result": {"code": "invalid_request"}}
	var candidates: Array = []
	for task in result.get("tasks", []):
		if str(task.get("packageName", "")) != package_name:
			continue
		if int(task.get("userId", 0)) != user_id:
			continue
		if int(task.get("taskId", -1)) == task_id:
			return {"status": "ok", "task": task}
		candidates.append(task)
	if candidates.size() == 1:
		return {"status": "ok", "task": candidates[0]}
	if candidates.size() > 1:
		return {"status": "ambiguous"}
	return {"status": "missing"}

## Revalidates and, when necessary, rebinds a live session to its current task.
func _reconcile_android_task_identity(session: GameSession, allow_closing: bool = false) -> String:
	if session == null:
		return "cancelled"
	var resolved: Dictionary = await _resolve_android_task(session.runtime)
	if session != _active_session or session.state == GameSession.State.ENDED:
		return "cancelled"
	if session.state == GameSession.State.CLOSING and not allow_closing:
		return "cancelled"
	if str(resolved.get("status", "")) != "ok":
		return str(resolved.get("status", "error"))
	var task: Dictionary = resolved.get("task", {})
	if task.is_empty():
		return "error"
	var old_task_id := int(session.runtime.get("taskId", -1))
	var old_top_activity := str(session.runtime.get("topActivity", ""))
	var updated := {
		"taskId": int(task.get("taskId", old_task_id)),
		"package": str(task.get("packageName", session.runtime.get("package", ""))),
		"topActivity": str(task.get("topActivity", old_top_activity)),
		"baseActivity": str(task.get("baseActivity", session.runtime.get("baseActivity", ""))),
		"displayId": int(task.get("displayId", session.runtime.get("displayId", 0))),
		"userId": int(task.get("userId", session.runtime.get("userId", 0))),
	}
	var changed := false
	for key in updated:
		if session.runtime.get(key) != updated[key]:
			changed = true
			break
	if not changed:
		return "ok"
	launch_manager.sessions.update_runtime(session, updated)
	launch_manager.android_tasks.set_retained_identity(session.runtime, session.state == GameSession.State.ACTIVE)
	print("[ProcessManager] Android task identity rebound: task ", old_task_id, " -> ", updated.taskId,
		" (", old_top_activity, " -> ", updated.topActivity, ")")
	return "ok"

func _finalize_android_sessions_for_package(package_name: String) -> void:
	if package_name.is_empty():
		return
	_android_task_removal_pending = false
	var affected: Array[GameSession] = []
	for session in launch_manager.sessions.get_live_for_package(package_name):
		if session.backend == GameSession.Backend.ANDROID_TASK:
			affected.append(session)
	for session in affected:
		_delete_snapshot(session)
		launch_manager.sessions.finalize_once(session, 0, "android_closed")
		if _active_session == session:
			launch_manager.android_tasks.clear_retained_identity()
			_active_session = null
			_clear_android_background()

func _delete_snapshot(session: GameSession) -> void:
	var path := str(session.runtime.get("snapshotPath", ""))
	GameCard.evict_session_snapshot(path)
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	session.runtime.erase("snapshotPath")

func _clear_android_background() -> void:
	_background_active_pid = -1
	_background_active_game = null
	_background_backend = GameSession.Backend.UNKNOWN
	_android_emulator_package = ""
	_is_in_background_state = false

func session_changed_for_android() -> void:
	if _active_session:
		launch_manager.sessions.session_changed.emit(_active_session)

var _android_transition_inflight := false
var _android_task_removal_pending := false

## Exit background state
func exit_background_state(exit_code: int = 0) -> void:
	if not _is_in_background_state:
		return

	print("[ProcessManager] Exiting background state. PID was: ", _background_active_pid, " PGID was: ", _background_active_pgid)

	var game = _background_active_game

	if _background_poll_timer:
		_background_poll_timer.stop()

	# If the process group somehow outlives the session (forced exits,
	# detection misses), keep launcher input blocked until it actually dies.
	if SystemManager.platform.is_linux() and _background_active_pgid > 1 and is_group_alive(_background_active_pgid):
		_start_lingering_watch(_background_active_pgid)

	_background_active_pid = -1
	_background_active_pgid = -1
	_background_active_game = null
	_background_active_signature = ""
	_background_active_exe_signature = ""
	_background_window_xid = ""
	_background_window_hint = ""
	_background_window_misses = 0
	_background_dead_streak = 0
	_is_in_background_state = false
	_android_emulator_package = ""
	_background_backend = GameSession.Backend.UNKNOWN

	_end_game_session(game, exit_code)


# ============================================================================
# GAME SESSION TRACKING (playtime + Android LMK protection)
# ============================================================================

## Starts a play session for a backgrounded game. On Android this also starts
## the game-session foreground service, promoting the process out of LMK's
## cached tier while a memory-hungry emulator holds the foreground. The
## pending record hits disk before the handoff so a mid-session process kill
## can be recovered on next launch.
func _begin_game_session(game: GameResource) -> void:
	if _active_session and _active_session.state != GameSession.State.ENDED:
		return
	var runtime := {
		"pid": _background_active_pid,
		"pgid": _background_active_pgid,
		"package": _android_emulator_package,
		"window_xid": _background_window_xid,
		"window_hint": _background_window_hint,
		"process_start_ticks": _process_start_ticks(_background_active_pid),
		"boot_id": _current_boot_id(),
		"signature": _background_active_signature,
		"exe_signature": _background_active_exe_signature,
	}
	_active_session = launch_manager.sessions.begin_session(game, _background_backend, {
		"title": "" if game else _background_window_hint,
		"emulator_id": launch_manager.resolve_emulator_for_game(game) if game else _background_window_hint,
		"runtime": runtime,
	})
	launch_manager.sessions.activate_session(_active_session, _background_active_pid)

func _sync_active_session_runtime() -> void:
	if _active_session == null:
		return
	launch_manager.sessions.update_runtime(_active_session, {
		"pid": _background_active_pid,
		"pgid": _background_active_pgid,
		"process_start_ticks": _process_start_ticks(_background_active_pid),
		"boot_id": _current_boot_id(),
		"package": _android_emulator_package,
		"window_xid": _background_window_xid,
		"window_hint": _background_window_hint,
		"signature": _background_active_signature,
		"exe_signature": _background_active_exe_signature,
	})

func _end_game_session(game: GameResource, exit_code: int = 0) -> void:
	if _active_session == null and game != null:
		_active_session = launch_manager.sessions.get_live_for_game(game.romm_id)
	if _active_session != null:
		if _active_session.backend == GameSession.Backend.ANDROID_TASK:
			launch_manager.android_tasks.clear_retained_identity()
		launch_manager.sessions.finalize_once(_active_session, exit_code, "runtime_exited")
		_active_session = null
	else:
		SystemManager.platform.stop_game_session_foreground_service()
	request_pending_recovery()

func _record_owner_alive(record: Dictionary) -> bool:
	var owner: Dictionary = record.get("owner", {})
	if owner.is_empty():
		return false
	var pid := int(owner.get("pid", -1))
	if pid <= 0:
		return false
	if pid == OS.get_process_id():
		return true
	var recorded_boot := str(owner.get("boot_id", ""))
	if not recorded_boot.is_empty() and recorded_boot != _current_boot_id():
		return false
	var start_ticks := int(owner.get("start_ticks", -1))
	if start_ticks > 0 and SystemManager.platform.is_linux():
		return _process_start_ticks(pid) == start_ticks
	return await is_running_async(pid)

func _recovery_role_allows(record: Dictionary) -> bool:
	var origin := str(record.get("policy", {}).get("origin", ""))
	if origin == "headless":
		return HeadlessLaunchRunner.is_active() and HeadlessLaunchRunner.parse_launch_romm_id() == int(record.get("romm_id", 0))
	return not HeadlessLaunchRunner.is_active()

func _claim_path(record: Dictionary) -> String:
	return str(record.get("_pending_path", "")) + ".claim"

func _write_recovery_claim(path: String, token: String) -> void:
	var f := FileAccess.open(path.path_join("owner.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"token": token,
			"owner": {
				"pid": OS.get_process_id(),
				"start_ticks": _process_start_ticks(OS.get_process_id()),
				"boot_id": _current_boot_id(),
			},
		}))
		f.close()

func _claim_pending_record(record: Dictionary) -> bool:
	var path := _claim_path(record)
	if path.is_empty():
		return false
	if DirAccess.dir_exists_absolute(path):
		var claim := SessionSubManager._read_pending_record(path.path_join("owner.json"))
		# Incomplete publications are contested, never assumed dead.
		if str(claim.get("token", "")).is_empty():
			return false
		if await _record_owner_alive(claim):
			return false
		var current := SessionSubManager._read_pending_record(path.path_join("owner.json"))
		if str(current.get("token", "")) != str(claim.get("token", "")):
			return false
		# Rename the stale generation out of the way atomically. Another
		# process cannot publish a new claim under this name until we finish.
		var stale := path + ".stale-" + str(claim.get("token", ""))
		if DirAccess.rename_absolute(path, stale) != OK:
			return false
		DirAccess.remove_absolute(stale.path_join("owner.json"))
		DirAccess.remove_absolute(stale)
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var staging := path + ".tmp-" + token
	if DirAccess.make_dir_absolute(staging) != OK:
		return false
	_write_recovery_claim(staging, token)
	# Publish a complete owner file atomically. No reader can observe a new
	# claim directory before its token/owner metadata exists.
	if DirAccess.rename_absolute(staging, path) != OK:
		DirAccess.remove_absolute(staging.path_join("owner.json"))
		DirAccess.remove_absolute(staging)
		return false
	record["_claim_token"] = token
	return true

func _release_recovery_claim(record: Dictionary) -> void:
	var path := _claim_path(record)
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	var current := SessionSubManager._read_pending_record(path.path_join("owner.json"))
	# Never remove a newer claimant's directory after an await or stale retry.
	if str(current.get("token", "")) == str(record.get("_claim_token", "")):
		DirAccess.remove_absolute(path.path_join("owner.json"))
		DirAccess.remove_absolute(path)
	record.erase("_claim_token")

## Recovery: every pending record gets a chance to prove that its runtime
## survived. Ownership/role checks and an atomic per-record claim prevent two
## launchers from adopting or finalizing the same game concurrently.
func request_pending_recovery() -> void:
	if _recovery_in_progress or _is_in_background_state:
		_recovery_rerun_requested = true
		return
	call_deferred("_recover_pending_sessions")

func wait_for_initial_recovery() -> void:
	if not _initial_recovery_completed:
		await recovery_completed

func _schedule_recovery_retry() -> void:
	if _recovery_retry_scheduled:
		return
	_recovery_retry_scheduled = true
	await get_tree().create_timer(1.0).timeout
	_recovery_retry_scheduled = false
	request_pending_recovery()

func _recover_pending_sessions() -> void:
	if launch_manager == null or _recovery_in_progress:
		return
	if _is_in_background_state:
		_recovery_rerun_requested = true
		return
	_recovery_in_progress = true
	var records: Array[Dictionary] = launch_manager.sessions.pending_records()
	var android_recovery_handled := false
	for record in records:
		if not _recovery_role_allows(record) or await _record_owner_alive(record):
			continue
		if not await _claim_pending_record(record):
			continue
		var origin := str(record.get("policy", {}).get("origin", ""))
		if origin == "shuffler":
			await _retire_shuffler_record(record)
		elif not _is_in_background_state and not android_recovery_handled:
			var outcome = await _try_reattach_pending_session(record)
			if (outcome is String and outcome == "invalid") or (outcome is bool and not outcome):
				launch_manager.sessions.finalize_pending_record(record, "runtime_unavailable")
			elif outcome == "error":
				_schedule_recovery_retry()
			elif outcome == "lost" or outcome == "reattached":
				android_recovery_handled = true
		# Once one ordinary session is reattached, leave additional records
		# pending rather than finalizing them without a liveness attempt.
		_release_recovery_claim(record)
	_recovery_in_progress = false
	if not _initial_recovery_completed:
		_initial_recovery_completed = true
		recovery_completed.emit()
	if _recovery_rerun_requested:
		_recovery_rerun_requested = false
		call_deferred("_recover_pending_sessions")

func _retire_shuffler_record(record: Dictionary) -> void:
	var runtime: Dictionary = record.get("runtime", {})
	var pid := int(runtime.get("pid", -1))
	var pgid := int(runtime.get("pgid", -1))
	var recorded_boot := str(runtime.get("boot_id", ""))
	var current_boot := _current_boot_id()
	if recorded_boot != current_boot and not recorded_boot.is_empty() and not current_boot.is_empty():
		# A previous boot's runtime cannot still be alive.
		launch_manager.sessions.finalize_pending_record(record, "previous_boot")
		return
	var signature := str(runtime.get("signature", ""))
	var exe_signature := str(runtime.get("exe_signature", ""))

	if not SystemManager.platform.is_linux():
		if recorded_boot != current_boot:
			# Windows records have no boot ID. A reused PID is not sufficient
			# proof for a recovery kill, so finalize without signaling anything.
			launch_manager.sessions.finalize_pending_record(record, "previous_boot")
			return
		if pid > 0 and await is_running_async(pid):
			# We cannot prove this is the original process on Windows. Preserve
			# the record rather than killing an unrelated process tree.
			push_warning("[ProcessManager] Windows shuffler runtime identity is unverified; pending record retained without signaling")
		else:
			launch_manager.sessions.finalize_pending_record(record, "shuffler_runtime_dead")
		return
	if recorded_boot != current_boot:
		return

	var recorded_start := int(runtime.get("process_start_ticks", -1))
	var leader_valid := pid > 0 and recorded_start > 0 and _process_start_ticks(pid) == recorded_start
	var anchor_valid := leader_valid
	if not anchor_valid and pgid > 1 and is_group_alive(pgid) and (not signature.is_empty() or not exe_signature.is_empty()):
		for match_pid in find_pids_by_signatures([signature] as Array[String], exe_signature):
			if get_pgid(match_pid) == pgid:
				anchor_valid = true
				break
	if not anchor_valid and (not signature.is_empty() or not exe_signature.is_empty()):
		# A setsid'd payload can outlive both its leader and original group.
		# Strong launch signatures are then the only safe adoption evidence.
		if not find_pids_by_signatures([signature] as Array[String], exe_signature).is_empty():
			anchor_valid = true
	var pids: Dictionary = {}
	var pgids: Dictionary = {}
	if anchor_valid:
		if pid > 0:
			pids[pid] = true
		if pgid > 1:
			pgids[pgid] = true
		# Once the launch is identified, include escaped payload groups too.
		if not signature.is_empty() or not exe_signature.is_empty():
			for match_pid in find_pids_by_signatures([signature] as Array[String], exe_signature):
				pids[match_pid] = true
				var match_pgid := get_pgid(match_pid)
				if match_pgid > 1:
					pgids[match_pgid] = true
	if pids.is_empty() and pgids.is_empty():
		if pgid <= 1 or not is_group_alive(pgid):
			launch_manager.sessions.finalize_pending_record(record, "shuffler_runtime_dead")
		return

	var signal_pid := pid if pid > 0 else int(pids.keys()[0])
	for group_id in pgids:
		kill_process_async(signal_pid, group_id)
	var all_dead := false
	var elapsed := 0.0
	while elapsed < 3.0:
		all_dead = true
		for target_pid in pids:
			if await is_running_async(target_pid):
				all_dead = false
		for group_id in pgids:
			if is_group_alive(group_id):
				all_dead = false
		if all_dead:
			break
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	if all_dead:
		launch_manager.sessions.finalize_pending_record(record, "shuffler_recovery_killed")
	else:
		push_warning("[ProcessManager] Shuffler payload survived recovery kill; pending record retained for retry")
		_schedule_recovery_retry()

func _try_reattach_android_session(record: Dictionary) -> String:
	if not bool(record.get("policy", {}).get("retain", false)):
		return "invalid"
	if float(record.get("end_unix", 0.0)) > float(record.get("start_unix", 0.0)):
		launch_manager.sessions.finalize_pending_record(record, "native_end_observed")
		return "ended"
	var runtime: Dictionary = record.get("runtime", {})
	var task_id := int(runtime.get("taskId", -1))
	if task_id <= 0:
		return "invalid"
	var resolved: Dictionary = await _resolve_android_task(runtime)
	var status := str(resolved.get("status", "error"))
	if status != "ok" and status != "missing":
		return "error"
	if status == "ok":
		var task: Dictionary = resolved.get("task", {})
		if task.is_empty():
			return "error"
		var romm_id := int(record.get("romm_id", 0))
		var game := _game_for_pending_session(romm_id)
		if game == null:
			return "invalid"
		var restored_runtime := runtime.duplicate(true)
		restored_runtime["taskId"] = int(task.get("taskId", task_id))
		restored_runtime["package"] = str(task.packageName)
		restored_runtime["topActivity"] = str(task.topActivity)
		restored_runtime["baseActivity"] = str(task.get("baseActivity", ""))
		restored_runtime["displayId"] = int(task.get("displayId", 0))
		restored_runtime["userId"] = int(task.get("userId", 0))
		_background_backend = GameSession.Backend.ANDROID_TASK
		_background_active_game = game
		_android_emulator_package = restored_runtime.package
		_is_in_background_state = false
		_active_session = launch_manager.sessions.reattach_session(record, game, restored_runtime)
		if _active_session:
			launch_manager.sessions.retain_session(_active_session)
			launch_manager.android_tasks.set_retained_identity(_active_session.runtime, false)
			return "reattached"
		return "invalid"
	var lost_game := _game_for_pending_session(int(record.get("romm_id", 0)))
	if lost_game:
		_active_session = launch_manager.sessions.mark_lost(record, lost_game)
		_background_backend = GameSession.Backend.ANDROID_TASK
		_background_active_game = lost_game
		_android_emulator_package = str(runtime.get("package", ""))
		_is_in_background_state = false
		return "lost"
	return "invalid"

func _game_for_pending_session(romm_id: int) -> GameResource:
	return launch_manager.sessions.game_for_record(romm_id)

func _try_reattach_pending_session(record: Dictionary) -> Variant:
	if GameSession.backend_from_string(str(record.get("backend", ""))) == GameSession.Backend.ANDROID_TASK:
		return await _try_reattach_android_session(record)
	if GameSession.backend_from_string(str(record.get("backend", ""))) != GameSession.Backend.DESKTOP_PROCESS:
		# Android task reconciliation is introduced with the privileged task
		# backend. Until then, retain the legacy conservative recovery behavior.
		return false
	var romm_id := int(record.get("romm_id", 0))
	var game := _game_for_pending_session(romm_id)
	if game == null and romm_id == 0:
		# Standalone emulator launches have no library GameResource. Preserve a
		# synthetic session identity so they can still be reattached safely.
		game = GameResource.new()
		game.id = "standalone-session"
		game.romm_id = 0
		game.title = str(record.get("title", "Emulator"))
		game.platform_slug = str(record.get("platform_slug", ""))
	if game == null:
		return false
	var runtime: Dictionary = record.get("runtime", {})
	var pid := int(runtime.get("pid", -1))
	if pid <= 0 or not SystemManager.platform.is_linux():
		return false
	# A live PID is not proof of identity. Reject records from another boot or
	# a PID that has since been reused before any group can be adopted/signaled.
	var recorded_boot := str(runtime.get("boot_id", ""))
	var current_boot := _current_boot_id()
	if recorded_boot.is_empty() or current_boot.is_empty() or recorded_boot != current_boot:
		return false
	var recorded_start := int(runtime.get("process_start_ticks", -1))
	var leader_valid := recorded_start > 0 and _process_start_ticks(pid) == recorded_start
	if not leader_valid:
		# Wrapper/AppImage leaders may exit while the real payload keeps their
		# process group alive. Allow that case only when the recorded launch
		# signature identifies a live process in the SAME group; otherwise fail
		# closed instead of adopting a reused PID/PGID.
		var signature := str(runtime.get("signature", ""))
		var exe_signature := str(runtime.get("exe_signature", ""))
		if signature.is_empty() and exe_signature.is_empty():
			return false
		var matching_pid := -1
		var recorded_pgid := int(runtime.get("pgid", -1))
		# Process discovery can race a fork/exec during startup. Retry briefly,
		# but never relax the same-group identity requirement.
		for attempt in 3:
			matching_pid = find_process_by_signature(signature, exe_signature)
			if matching_pid > 0 and recorded_pgid > 1 and get_pgid(matching_pid) == recorded_pgid:
				break
			if attempt < 2:
				await get_tree().create_timer(0.05).timeout
		if matching_pid <= 0 or recorded_pgid <= 1 or get_pgid(matching_pid) != recorded_pgid:
			return false
		pid = matching_pid

	_background_backend = GameSession.Backend.DESKTOP_PROCESS
	_background_active_game = game
	_background_active_pid = pid
	_background_active_pgid = int(runtime.get("pgid", -1))
	_background_active_signature = str(runtime.get("signature", ""))
	_background_active_exe_signature = str(runtime.get("exe_signature", ""))
	_background_window_xid = str(runtime.get("window_xid", ""))
	_background_window_hint = str(runtime.get("window_hint", ""))
	_background_window_misses = 0
	_background_dead_streak = 0
	_android_emulator_package = ""

	var alive := _linux_target_alive()
	if not alive:
		_background_active_game = null
		_background_active_pid = -1
		_background_active_pgid = -1
		_background_backend = GameSession.Backend.UNKNOWN
		return false

	_is_in_background_state = true
	var restored_runtime := runtime.duplicate(true)
	restored_runtime["pid"] = _background_active_pid
	restored_runtime["pgid"] = _background_active_pgid
	restored_runtime["process_start_ticks"] = _process_start_ticks(_background_active_pid)
	restored_runtime["signature"] = _background_active_signature
	restored_runtime["exe_signature"] = _background_active_exe_signature
	restored_runtime["window_xid"] = _background_window_xid
	restored_runtime["window_hint"] = _background_window_hint
	_active_session = launch_manager.sessions.reattach_session(record, game, restored_runtime)
	if _background_poll_timer:
		_background_poll_timer.start()
	dump_process_state("reattach_pending_session")
	return _active_session != null

## Poll callback (desktop only): check if process is still running (async:
## never blocks the main thread).
func _on_background_poll_timeout() -> void:
	if DEBUG_LOG: print("[ProcessManager] Poll timer fired")
	if not _is_in_background_state or _background_active_pid <= 0:
		if DEBUG_LOG: print("[ProcessManager] Poll skipped: in_background=", _is_in_background_state, " pid=", _background_active_pid)
		return
	if _poll_in_flight:
		if DEBUG_LOG: print("[ProcessManager] Poll skipped: previous check still in flight")
		return

	if SystemManager.platform.is_linux():
		_poll_in_flight = true
		_poll_linux_background(func(should_exit: bool):
			_poll_in_flight = false
			if not _is_in_background_state:
				return
			if should_exit:
				exit_background_state(0)
		)
		return

	_poll_in_flight = true
	var pid = _background_active_pid
	if DEBUG_LOG: print("[ProcessManager] Polling PID ", pid)
	_is_process_running_async(pid, func(running: bool):
		# Background state may have changed while the check was in flight
		if not _is_in_background_state or _background_active_pid != pid:
			_poll_in_flight = false
			if DEBUG_LOG: print("[ProcessManager] Poll result ignored: state changed")
			return
		if DEBUG_LOG: print("[ProcessManager] Poll result for PID ", pid, ": running=", running)
		_poll_in_flight = false
		if not running:
			if DEBUG_LOG: print("[ProcessManager] Process ", pid, " no longer running")
			exit_background_state(0)
	)

## Linux poll: the process group is the source of truth for liveness.
## The launched pid leads its own group (Godot setsid()s the child), so
## wrappers (AppImage AppRun, sh, env) and the
## real emulator payload all share one PGID — the group survives exactly the
## reparenting/forking that used to defeat single-PID /proc polling under
## gamescope. Only if the group is dead do we fall back to a cmdline
## signature scan for emulators that escaped the group entirely.
func _poll_linux_background(callback: Callable) -> void:
	if _linux_target_alive():
		_background_dead_streak = 0
	else:
		_background_dead_streak += 1
		print("[ProcessManager] Linux poll: no live process found (streak ", _background_dead_streak, "/", DEAD_STREAK_EXIT_THRESHOLD, ")")
		if _background_dead_streak >= DEAD_STREAK_EXIT_THRESHOLD:
			callback.call(true)
			return
		callback.call(false)
		return

	# Process is alive. In Game Mode we additionally watch the game window:
	# if the window is gone for good while the process lingers (e.g. the user
	# closed an emulator menu window), end the session rather than trapping
	# input behind a windowless process.
	if not SystemManager.platform.is_gamemode():
		callback.call(false)
		return
	_poll_gamemode_window(callback)

## Synchronous /proc liveness check for the tracked launch. Also re-adopts
## tracking (pid + pgid) when the emulator was reparented or escaped its
## original group. Returns true while anything belonging to the launch lives.
func _linux_target_alive() -> bool:
	if _background_active_pgid > 1 and is_group_alive(_background_active_pgid):
		return true
	if _background_active_pid > 0:
		var stat := _parse_proc_stat(_background_active_pid)
		if stat.ok and stat.state != "Z":
			# Alive but outside the tracked group (PGID was stale): re-adopt.
			var pgrp := int(stat.get("pgrp", -1))
			if pgrp > 1 and pgrp != _background_active_pgid:
				if DEBUG_LOG: print("[ProcessManager] Adopting PGID ", pgrp, " from live PID ", _background_active_pid)
				_background_active_pgid = pgrp
				_sync_active_session_runtime()
			return true
	# Group and PID are gone: scan /proc by the launch signature in case the
	# emulator escaped the group entirely (own setsid, double-fork daemon).
	if _background_active_signature != "" or _background_active_exe_signature != "":
		var found_pid := _find_process_by_signature()
		if found_pid > 0:
			print("[ProcessManager] Emulator found by signature at PID ", found_pid, "; re-adopting")
			_background_active_pid = found_pid
			var pgrp := get_pgid(found_pid)
			if pgrp > 0:
				_background_active_pgid = pgrp
			_sync_active_session_runtime()
			return true
	return false

## Game Mode window watch. The XID is a cache layered on top of group
## liveness: a vanished window first triggers a re-find against every process
## in the group (window recreation is normal for Vita3K/Cemu), and only a
## window that stays gone for WINDOW_MISS_EXIT_THRESHOLD polls while the
## process group keeps running ends the session (reaping the lingerer).
## Calls back with true only when background state should exit.
func _poll_gamemode_window(callback: Callable) -> void:
	var tool := _resolve_x11_windowctl_path()
	if tool == "" or not FileAccess.file_exists(tool):
		# Window layer unavailable; group liveness alone decides.
		callback.call(false)
		return

	if _background_window_xid == "":
		# Best-effort capture; never blocks exit decisions.
		_find_game_window(tool, func(xid: String):
			if xid != "" and _is_in_background_state:
				_background_window_xid = xid
				_background_window_misses = 0
				print("[ProcessManager] Gamemode captured game window xid: ", xid)
			callback.call(false)
		)
		return

	queue_helper_execute(tool, ["exists", "xid:" + _background_window_xid], func(result: Dictionary):
		if not _is_in_background_state:
			callback.call(false)
			return
		var exit_code: int = result.get("exit_code", -1)
		if exit_code == 0:
			if _background_window_misses > 0:
				_background_window_misses = 0
			callback.call(false)
			return
		if exit_code != 1:
			# The helper itself failed to run (spawn error, display hiccup):
			# not evidence that the window closed. Ignore this poll.
			if DEBUG_LOG: print("[ProcessManager] Gamemode exists check failed to run (exit=", exit_code, "); ignoring")
			callback.call(false)
			return
		# Window confirmed gone. Try to bind a replacement window first —
		# emulators recreate windows on game boot / fullscreen transitions.
		_background_window_misses += 1
		if DEBUG_LOG: print("[ProcessManager] Gamemode window gone (miss ", _background_window_misses, "); attempting re-find")
		_find_game_window(tool, func(new_xid: String):
			if not _is_in_background_state:
				callback.call(false)
				return
			if new_xid != "":
				if new_xid != _background_window_xid:
					print("[ProcessManager] Gamemode window recreated; re-captured xid: ", new_xid, " (was ", _background_window_xid, ")")
					_background_window_xid = new_xid
				_background_window_misses = 0
				callback.call(false)
				return
			if _background_window_misses >= WINDOW_MISS_EXIT_THRESHOLD:
				print("[ProcessManager] Gamemode window gone for ", _background_window_misses, " polls with a live process; exiting and reaping lingering group")
				dump_process_state("window_miss_exit")
				_kill_background_group()
				callback.call(true)
				return
			callback.call(false)
		)
	)

## Runs x11_windowctl find against every process in the tracked group (the
## payload's _NET_WM_PID rarely matches the leader we spawned) plus the name
## hint. Calls back with the hex XID, or "" when no window matched.
func _find_game_window(tool: String, callback: Callable) -> void:
	var args: Array = ["find", _background_window_pid_list()]
	if _background_window_hint != "":
		args.append(_background_window_hint)
	queue_helper_execute(tool, args, func(result: Dictionary):
		if result.get("exit_code", -1) != 0:
			callback.call("")
			return
		var output: Array = result.get("output", [])
		var text := ("".join(output)).strip_edges()
		var xid := ""
		var owner_pid := -1
		for line: String in text.split("\n", false):
			var l := line.strip_edges().to_lower()
			if l.begins_with("pid="):
				owner_pid = l.trim_prefix("pid=").to_int()
			elif l.length() > 0 and l.is_valid_hex_number(false):
				xid = l
		# The window owner is the real payload even when it escaped the
		# tracked group (AppImage runtimes fork/setsid it away); adopt its
		# pid/group so liveness and group signals follow the emulator.
		if owner_pid > 0 and _is_in_background_state:
			var owner_pgid := get_pgid(owner_pid)
			if owner_pid != _background_active_pid or (owner_pgid > 1 and owner_pgid != _background_active_pgid):
				print("[ProcessManager] Adopting window owner pid=", owner_pid, " pgid=", owner_pgid, " (was pid=", _background_active_pid, " pgid=", _background_active_pgid, ")")
				_background_active_pid = owner_pid
				if owner_pgid > 1 and owner_pgid != _get_own_pgid():
					_background_active_pgid = owner_pgid
				_sync_active_session_runtime()
		callback.call(xid)
	)

## Comma-separated PIDs the game window could belong to: the tracked PID
## plus every live member of its process group.
func _background_window_pid_list() -> String:
	var pids := {}
	if _background_active_pid > 0:
		pids[_background_active_pid] = true
	if _background_active_pgid > 1:
		for member in get_group_members(_background_active_pgid):
			pids[member] = true
	var list: Array = []
	for p in pids.keys():
		list.append(str(p))
	return ",".join(list)

## Kills the tracked process group (SIGCONT first so SIGSTOPped members can
## die). Used when the session ends but the emulator process lingers.
func _kill_background_group() -> void:
	if _background_active_pgid > 1 and _background_active_pgid != _get_own_pgid():
		var pgid := _background_active_pgid
		var script := "kill -CONT -- -%d 2>/dev/null; kill -9 -- -%d 2>/dev/null" % [pgid, pgid]
		MemorySubManager.queue_os_execute("sh", ["-c", script])
	elif _background_active_pid > 0:
		kill_process_async(_background_active_pid)

# ==================== LINGERING PROCESS WATCH ====================

## Keeps launcher input blocked after background state exits while the
## emulator's process group is still alive. See _lingering_pgid declaration.
func _start_lingering_watch(pgid: int) -> void:
	push_warning("[ProcessManager] Background state exited but process group %d is still alive; keeping input blocked until it exits" % pgid)
	_lingering_pgid = pgid
	if _lingering_timer == null:
		_lingering_timer = Timer.new()
		_lingering_timer.wait_time = LINGERING_POLL_INTERVAL
		_lingering_timer.one_shot = false
		_lingering_timer.timeout.connect(_on_lingering_poll)
		add_child(_lingering_timer)
	_lingering_timer.start()

func _on_lingering_poll() -> void:
	if _lingering_pgid <= 0:
		if _lingering_timer:
			_lingering_timer.stop()
		return
	if not is_group_alive(_lingering_pgid):
		print("[ProcessManager] Lingering process group ", _lingering_pgid, " has exited; unblocking input")
		_lingering_pgid = -1
		if _lingering_timer:
			_lingering_timer.stop()

## True while a previously-tracked emulator process group is still alive after
## its background state ended. main.gd ORs this into its input gate.
func has_lingering_process() -> bool:
	return _lingering_pgid > 0

## Logs the current tracking state: pid, pgid, group members, window XID.
func dump_process_state(context: String) -> void:
	if not SystemManager.platform.is_linux():
		return
	var members := ""
	if _background_active_pgid > 1:
		var states := _get_group_states(_background_active_pgid)
		var parts: Array = []
		for member_pid in states.keys():
			parts.append(str(member_pid) + "(" + str(states[member_pid]) + ")")
		members = ",".join(parts)
	print("[ProcessManager] state[%s]: pid=%d pgid=%d members=[%s] xid=%s window_misses=%d dead_streak=%d lingering=%d" % [
		context, _background_active_pid, _background_active_pgid, members,
		_background_window_xid, _background_window_misses, _background_dead_streak, _lingering_pgid
	])

## Scans /proc for a live (non-zombie) emulator process whose cmdline contains
## the stored launch signature (usually the ROM path). This catches emulators
## that were reparented away from the wrapper PID Kyodai was tracking.
func _find_process_by_signature() -> int:
	return find_process_by_signature(_background_active_signature, _background_active_exe_signature)

## Signature scan with explicit signatures, so callers other than the launcher
## background tracker (e.g. the shuffler) can re-adopt an escaped payload.
func find_process_by_signature(signature: String, exe_signature: String = "") -> int:
	var matches := find_pids_by_signature(signature, exe_signature)
	return matches[0] if not matches.is_empty() else -1

## Returns every live (non-zombie, non-wrapper) process whose cmdline/exe
## matches ANY of the given launch signatures. The plural/multi variant
## matters for emulators whose payload escaped the launch process group
## (sharun/bwrap setsid): suspend/resume/kill must reach ALL matching
## processes, not the first.
func find_pids_by_signatures(signatures: Array[String], exe_signature: String = "") -> Array[int]:
	var matches: Array[int] = []
	var sigs: Array[String] = []
	for s in signatures:
		if s != "" and not sigs.has(s):
			sigs.append(s)
	if sigs.is_empty() and exe_signature == "":
		return matches

	if not SystemManager.platform.is_linux():
		return matches

	var proc_dir := DirAccess.open("/proc")
	if proc_dir == null:
		return matches

	var filename_sigs: Array[String] = []
	for signature in sigs:
		var filename_signature = signature.get_file()
		if filename_signature != signature and filename_signature != "":
			filename_sigs.append(filename_signature)

	proc_dir.list_dir_begin()
	var entry := proc_dir.get_next()
	while entry != "":
		if entry.is_valid_int():
			var scan_pid := entry.to_int()
			if scan_pid > 0:
				var stat := _parse_proc_stat(scan_pid)
				if stat.ok and stat.state != "Z" and not _is_appimage_wrapper_pid(scan_pid):
					var cmdline := _get_process_cmdline(scan_pid)
					var matched := false
					for signature in sigs:
						if cmdline.find(signature) != -1:
							if DEBUG_LOG: print("[ProcessManager] Signature match in cmdline for PID ", scan_pid, ": ", cmdline)
							matched = true
							break
					if not matched:
						for filename_signature in filename_sigs:
							if cmdline.find(filename_signature) != -1:
								if DEBUG_LOG: print("[ProcessManager] Filename signature match in cmdline for PID ", scan_pid, ": ", cmdline)
								matched = true
								break
					if not matched and exe_signature != "":
						if cmdline.to_lower().find(exe_signature) != -1:
							if DEBUG_LOG: print("[ProcessManager] Exe-signature match in cmdline for PID ", scan_pid, ": ", cmdline)
							matched = true
						else:
							var exe_link := "/proc/" + str(scan_pid) + "/exe"
							if FileAccess.file_exists(exe_link):
								var exe_path := proc_dir.read_link(exe_link)
								if exe_path != "":
									var exe_base := exe_path.get_file().get_basename().to_lower()
									if exe_base == exe_signature or exe_base.contains(exe_signature):
										if DEBUG_LOG: print("[ProcessManager] Exe-signature match for PID ", scan_pid, ": ", exe_path)
										matched = true
					if matched:
						matches.append(scan_pid)
		entry = proc_dir.get_next()
	proc_dir.list_dir_end()

	return matches

func find_pids_by_signature(signature: String, exe_signature: String = "") -> Array[int]:
	return find_pids_by_signatures([signature] as Array[String], exe_signature)

## Dumps state/pgrp/ppid/cmdline for the given pids — diagnostic for launches
## whose payload escapes tracking (sharun/bwrap chains).
func dump_pid_diagnostics(tag: String, pids: Array) -> void:
	if not SystemManager.platform.is_linux():
		return
	for pid in pids:
		var p := int(pid)
		if p <= 0:
			continue
		var stat := _parse_proc_stat(p)
		if stat.ok:
			print("[ProcessManager] diag[", tag, "] pid=", p, " state=", stat.state, " pgrp=", stat.pgrp, " ppid=", stat.ppid, " cmdline=\"", _get_process_cmdline(p), "\"")
		else:
			print("[ProcessManager] diag[", tag, "] pid=", p, " unreadable/dead")

## Public process-state accessor ("" when unreadable/dead).
func get_process_state(pid: int) -> String:
	var stat := _parse_proc_stat(pid)
	return str(stat.get("state", "")) if stat.ok else ""

## Public cmdline accessor for ownership checks.
func get_process_cmdline_pub(pid: int) -> String:
	return _get_process_cmdline(pid)

## Kyodai's own process group (public; group signals must never target it).
func get_own_pgid() -> int:
	return _get_own_pgid()

## Async process liveness check; callback receives `running: bool` on the main thread.
func _is_process_running_async(pid: int, callback: Callable) -> void:
	if pid <= 0:
		callback.call(false)
		return

	# Linux fast path: /proc check is effectively free, no process spawn needed.
	# Also parse /proc/{pid}/stat so we don't treat zombie (defunct) processes
	# as still running — OS.create_process can leave children unreaped.
	# Zombies fall through to a group check: the payload may still be alive in
	# the same process group even when the tracked leader is defunct.
	if SystemManager.platform.is_linux():
		var stat := _parse_proc_stat(pid)
		if stat.ok:
			if DEBUG_LOG: print("[ProcessManager] /proc/" + str(pid) + "/stat state=" + stat.state)
			if stat.state == "Z":
				var pgrp := int(stat.get("pgrp", -1))
				if pgrp > 1 and pgrp != _get_own_pgid() and is_group_alive(pgrp):
					if DEBUG_LOG: print("[ProcessManager] PID " + str(pid) + " is a zombie but its group lives; treating as running")
					callback.call(true)
					return
				if DEBUG_LOG: print("[ProcessManager] PID " + str(pid) + " is a zombie, treating as not running")
				callback.call(false)
				return
			callback.call(true)
			return
		else:
			if DEBUG_LOG: print("[ProcessManager] /proc/" + str(pid) + "/stat does not exist or is unreadable")
			callback.call(false)
			return

	if SystemManager.platform.is_windows():
		MemorySubManager.queue_os_execute("tasklist", ["/FI", "PID eq " + str(pid), "/NH"], func(result: Dictionary):
			var output: Array = result.get("output", [])
			var running = false
			if result.get("exit_code", -1) == 0 and output.size() > 0:
				var text = str(output[0]).strip_edges()
				running = text != "" and not text.begins_with("INFO:")
			callback.call(running)
		)
	else:
		MemorySubManager.queue_os_execute("ps", ["-p", str(pid)], func(result: Dictionary):
			callback.call(result.get("exit_code", -1) == 0)
		)


## Awaitable variant of _is_process_running_async. Returns true if running.
func is_running_async(pid: int) -> bool:
	var state := {"completed": false, "running": false}
	_is_process_running_async(pid, func(running: bool):
		state["completed"] = true
		state["running"] = running
	)
	while not state["completed"]:
		await get_tree().process_frame
	return state["running"]

## Kills a process by PID without blocking the main thread. On Linux the
## whole process group is killed (SIGCONT first so SIGSTOPped members can
## die): wrappers like AppImage AppRun would otherwise orphan the payload.
## pgid_override lets callers pass a freshly re-resolved group (the tracked
## PID's group goes stale when the payload re-execs into its own group).
func kill_process_async(pid: int, pgid_override: int = -1) -> void:
	if pid <= 0:
		return
	if SystemManager.platform.is_windows():
		MemorySubManager.queue_os_execute("taskkill", ["/F", "/PID", str(pid)])
	else:
		var pgid := pgid_override if pgid_override > 1 else get_pgid(pid)
		if pgid > 1 and pgid != _get_own_pgid():
			var script := "kill -CONT -- -%d 2>/dev/null; kill -9 -- -%d 2>/dev/null" % [pgid, pgid]
			MemorySubManager.queue_os_execute("sh", ["-c", script])
		else:
			MemorySubManager.queue_os_execute("kill", ["-9", str(pid)])

## Waits until the process exits (or timeout). Returns true if confirmed dead.
func confirm_process_dead_async(pid: int, timeout_sec: float = 5.0) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_sec:
		var running = await is_running_async(pid)
		if not running:
			return true
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	return false

## Suspends a process via pssuspend (Windows only; path supplied by caller).
## On Linux the whole process group gets SIGSTOP: single-PID suspension only
## ever froze the wrapper on AppImage/forking emulators (e.g. Cemu's AppRun),
## leaving the payload running alongside the next game.
## on_done(result: Dictionary {exit_code, output}) fires on the main thread
## when pssuspend exits - callers that must not race the suspended process
## (e.g. launching a new emulator instance) should await it.
func suspend_process_async(pid: int, pssuspend_path: String, on_done: Callable = Callable(), pgid_override: int = -1) -> void:
	if pid <= 0:
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if SystemManager.platform.is_windows():
		if pssuspend_path == "":
			if on_done.is_valid():
				on_done.call({"exit_code": -1, "output": []})
			return
		MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", str(pid)], on_done)
	elif OS.get_name() == "Linux" or OS.get_name().ends_with("BSD"):
		var pgid := pgid_override if pgid_override > 1 else get_pgid(pid)
		if pgid > 1 and pgid != _get_own_pgid():
			print("[ProcessManager] SIGSTOP group: pid=%d pgid=%d members=[%s]" % [pid, pgid, format_group_states(pgid)])
			MemorySubManager.queue_os_execute("kill", ["-STOP", "--", "-" + str(pgid)], on_done)
		else:
			print("[ProcessManager] SIGSTOP single pid=%d (pgid resolution failed or own group)" % pid)
			MemorySubManager.queue_os_execute("kill", ["-STOP", str(pid)], on_done)
	else:
		push_warning("[ProcessManager] suspend_process_async is only supported on Windows and Linux/BSD")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})

## Resumes a suspended process via pssuspend (Windows) or kill -CONT (Linux/BSD).
## Group-aware on Linux, mirroring suspend_process_async.
func resume_process_async(pid: int, pssuspend_path: String, on_done: Callable = Callable(), pgid_override: int = -1) -> void:
	if pid <= 0:
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if SystemManager.platform.is_windows():
		if pssuspend_path == "":
			if on_done.is_valid():
				on_done.call({"exit_code": -1, "output": []})
			return
		MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", "-r", str(pid)], on_done)
	elif OS.get_name() == "Linux" or OS.get_name().ends_with("BSD"):
		var pgid := pgid_override if pgid_override > 1 else get_pgid(pid)
		if pgid > 1 and pgid != _get_own_pgid():
			print("[ProcessManager] SIGCONT group: pid=%d pgid=%d members=[%s]" % [pid, pgid, format_group_states(pgid)])
			MemorySubManager.queue_os_execute("kill", ["-CONT", "--", "-" + str(pgid)], on_done)
		else:
			print("[ProcessManager] SIGCONT single pid=%d (pgid resolution failed or own group)" % pid)
			MemorySubManager.queue_os_execute("kill", ["-CONT", str(pid)], on_done)
	else:
		push_warning("[ProcessManager] resume_process_async is only supported on Windows and Linux/BSD")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})

## Force exit background state (for crashes/emergencies)
func force_exit_background_state() -> void:
	print("[ProcessManager] Force exiting background state")
	exit_background_state(-1)

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	print("[ProcessManager] execute_launch called for emulator: ", intent.emulator_id if intent else "<null>")
	if not intent or not intent.is_valid():
		push_error("[ProcessManager] Invalid launch intent")
		return false

	# Check if emulator is fully installed (cached scan, see _is_emulator_fully_installed)
	var is_actually_installed: bool = launch_manager.emulator.get_install_progress(intent.emulator_id).get("is_installed", false)

	if not is_actually_installed:
		push_error("[ProcessManager] Emulator not fully installed: " + intent.emulator_id)
		SystemManager.notifications.show_notification("Emulator not ready: " + intent.emulator_name, SystemManager.notifications.Type.ERROR)
		return false

	if SystemManager.platform.is_android():
		return await _execute_android(intent)
	else:
		return await _execute_desktop(intent)

func _execute_desktop(intent: LaunchIntent) -> bool:
	if DEBUG_LOG: print("[ProcessManager] _execute_desktop called")
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return false

	var pid = await _create_desktop_process(intent)
	if pid == -1:
		launch_manager.launch_completed.emit(false, "Failed to start emulator")
		return false

	# Store PID and enter background state for desktop
	enter_background_state(pid, intent.game, intent)

	launch_manager.launch_completed.emit(true, "Game launched successfully")
	return true

## Removes a stale portable config that points to the wrong home directory
## (e.g. /home/user/... on /home/carter). The file is backed up first so the
## user can restore it if needed. Returns true if a stale config was reset.
func _sanitize_portable_config(portable_root: String) -> bool:
	var config_dir := FSM.join_paths(portable_root, "user", "config")
	var candidates := ["qt-config.ini", "config.ini"]
	var current_home := OS.get_environment("HOME")
	if current_home == "":
		return false
	current_home = current_home.rstrip("/")
	
	for file_name in candidates:
		var config_path := FSM.join_paths(config_dir, file_name)
		if not FSM.file_exists(config_path):
			continue
		var text := FSM.read_file(config_path)
		var stale := false
		for line in text.split("\n"):
			# Look for absolute Unix home paths that aren't the current home.
			var idx := line.find("/home/")
			if idx < 0:
				continue
			var path_end := line.find(" ", idx)
			if path_end < 0:
				path_end = line.length()
			var candidate := line.substr(idx, path_end - idx).strip_edges()
			# Drop trailing slash/quote chars
			while not candidate.is_empty() and candidate[-1] in ['"', "'", "/"]:
				candidate = candidate.substr(0, candidate.length() - 1)
			if candidate == current_home or candidate.begins_with(current_home + "/"):
				continue
			stale = true
			break
		
		if stale:
			var backup_path := config_path + ".kyodai-stale-backup"
			FSM.write_file(backup_path, text)
			FSM.delete_file(config_path)
			print("[ProcessManager] Reset stale portable config: %s (backup: %s)" % [config_path, backup_path])
			return true
	return false

## Shared desktop process creation. Coroutine: returns the REAL emulator PID
## (never a shell-wrapper PID) or -1 on failure.
func _create_desktop_process(intent: LaunchIntent) -> int:
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return -1

	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	var pid: int = -1

	# Enforce Kyodai-managed data paths in the emulator config before launching.
	# This is the writing side of the config resolver: the same strategy that
	# reads save/firmware locations now writes them so managed and unmanaged
	# installs use the same directories.
	if not RSM.enforce_paths(intent.emulator_id, intent.platform_slug, intent.core_name):
		push_warning("[ProcessManager] Could not enforce config paths for %s" % intent.emulator_id)

	var linux_env_args = _build_linux_env_args(intent)
	var use_env_wrapper = SystemManager.platform.is_linux() and not linux_env_args.is_empty()
	
	# Portable-mode handshake: emulators like Eden/Azahar trigger portable mode
	# when their working directory contains a user/ folder. If the requested
	# working directory does not contain user/, fall back to the executable's
	# directory so unmanaged installs use their native config paths.
	var effective_working_dir := intent.working_directory
	if effective_working_dir != "":
		if FSM.dir_exists(FSM.join_paths(effective_working_dir, "user")):
			# We are forcing portable mode; reset any stale config that points
			# to a different home directory so the emulator regenerates it.
			_sanitize_portable_config(effective_working_dir)
		else:
			if DEBUG_LOG: print("[ProcessManager] No user/ in requested working dir '%s'; falling back to exe dir" % effective_working_dir)
			effective_working_dir = exe_path.get_base_dir().replace("//", "/")

	# Existence guard: a missing working dir makes the shell wrappers' `cd` (or
	# PowerShell's -WorkingDirectory) fail before the emulator ever starts.
	# Fall back to the exe dir, then to the process default working dir.
	if effective_working_dir != "" and not FSM.dir_exists(effective_working_dir):
		push_warning("[ProcessManager] Working dir does not exist, falling back: " + effective_working_dir)
		effective_working_dir = exe_path.get_base_dir().replace("//", "/")
	if effective_working_dir != "" and not FSM.dir_exists(effective_working_dir):
		push_warning("[ProcessManager] Exe dir missing too, using default working dir: " + effective_working_dir)
		effective_working_dir = ""
	
	print("[ProcessManager] Creating desktop process for: ", exe_path)
	if DEBUG_LOG: print("[ProcessManager] launch args: ", arguments)
	if DEBUG_LOG: print("[ProcessManager] working directory: ", effective_working_dir)
	if DEBUG_LOG: print("[ProcessManager] linux env args: ", linux_env_args, " use_env_wrapper=", use_env_wrapper)

	if effective_working_dir == "" and not use_env_wrapper:
		# No working directory needed and no env sanitization: call executable directly
		# (no shell, no injection risk). Godot's create_process already calls
		# setsid() in the forked child, so the returned pid leads its own
		# process group; wrapping in setsid(1) would double-fork and orphan it.
		if DEBUG_LOG: print("[ProcessManager] Direct launch: exe=", exe_path, " args=", arguments)
		pid = OS.create_process(exe_path, arguments, false)
		print("[ProcessManager] Direct launch returned pid: ", pid)
	elif effective_working_dir == "" and use_env_wrapper:
		# Linux with env sanitization: wrap env(1) in sh -c with exec so the
		# shell replaces itself with env, which then replaces itself with the
		# emulator. Calling env directly as the OS.create_process executable
		# can cause some AppRun scripts (e.g. Eden) to exit immediately when
		# backgrounded, because the intermediate non-exec parent changes the
		# process/session relationship the child sees.
		var safe_args = _escape_args_for_shell(arguments)
		var safe_exe = _escape_sh_arg(exe_path)
		var env_prefix = _escape_env_args_for_shell(linux_env_args) + " "
		# Capture stdout/stderr to a log file. This both gives us a diagnostic
		# trace if the emulator crashes, and provides the child with real open
		# file descriptors instead of whatever closed/socket fds the parent
		# Godot process happens to have inherited.
		var launch_log := FSM.resolve_path(
			FSM.resolve_emulator_path("launch.log", intent.emulator_id),
			{"format": FSM.PathFormat.ABSOLUTE}
		)
		var safe_log := _escape_sh_arg(launch_log)
		var inner_cmd = 'exec env %s%s %s > %s 2>&1' % [env_prefix, safe_exe, " ".join(safe_args), safe_log]
		if DEBUG_LOG: print("[ProcessManager] env launch via sh: sh -c ", inner_cmd)
		pid = OS.create_process("sh", ["-c", inner_cmd], false)
		print("[ProcessManager] env launch via sh returned pid: ", pid)
	elif not SystemManager.platform.is_windows():
		# Linux: sh -c with exec, so the shell REPLACES itself with the
		# emulator and the returned PID is the emulator's own PID.
		var safe_args = _escape_args_for_shell(arguments)
		var safe_working_dir = _escape_sh_arg(effective_working_dir)
		var safe_exe = _escape_sh_arg(exe_path)
		var env_prefix = _escape_env_args_for_shell(linux_env_args) + " " if use_env_wrapper else ""
		var launch_log := FSM.resolve_path(
			FSM.resolve_emulator_path("launch.log", intent.emulator_id),
			{"format": FSM.PathFormat.ABSOLUTE}
		)
		var safe_log := _escape_sh_arg(launch_log)
		var inner_cmd = 'cd %s && exec env %s%s %s > %s 2>&1' % [safe_working_dir, env_prefix, safe_exe, " ".join(safe_args), safe_log]
		if DEBUG_LOG: print("[ProcessManager] shell launch: sh -c ", inner_cmd)
		pid = OS.create_process("sh", ["-c", inner_cmd], false)
		print("[ProcessManager] shell launch returned pid: ", pid)
	else:
		# Windows: Start-Process sets the working directory AND reports the real
		# child PID via -PassThru (a cmd /c wrapper would return cmd.exe's PID)
		var ps_arg_list: Array[String] = []
		for arg in arguments:
			ps_arg_list.append(_escape_ps_arg_quoted(arg))
		var ps_command = "Start-Process -FilePath %s -WorkingDirectory %s" % [_escape_ps_arg(exe_path), _escape_ps_arg(effective_working_dir)]
		if not ps_arg_list.is_empty():
			ps_command += " -ArgumentList " + ",".join(ps_arg_list)
		ps_command += " -PassThru | Select-Object -ExpandProperty Id"
		if DEBUG_LOG: print("[ProcessManager] PowerShell launch: ", ps_command)

		var spawn_state := {"completed": false, "pid": -1}
		MemorySubManager.queue_os_execute("powershell", ["-NoProfile", "-Command", ps_command], func(result: Dictionary):
			spawn_state["completed"] = true
			if result.get("exit_code", -1) == 0:
				var output: Array = result.get("output", [])
				# Take the last non-empty output line as the PID
				for i in range(output.size() - 1, -1, -1):
					var line = str(output[i]).strip_edges()
					if line != "":
						spawn_state["pid"] = line.to_int()
						break
		)
		while not spawn_state["completed"]:
			await get_tree().process_frame
		pid = spawn_state["pid"]
		print("[ProcessManager] PowerShell launch returned pid: ", pid)

		if pid <= 0:
			# Fallback: cmd /c wrapper (tracks the wrapper PID, not the emulator)
			push_warning("[ProcessManager] PowerShell launch failed, falling back to cmd wrapper (PID tracking will follow cmd.exe)")
			var safe_args = _escape_args_for_shell(arguments)
			var safe_working_dir = _escape_cmd_meta(effective_working_dir)
			var safe_exe = _escape_cmd_meta(exe_path)
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			if DEBUG_LOG: print("[ProcessManager] Executing command: cmd /c ", inner_cmd)
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
			print("[ProcessManager] cmd fallback returned pid: ", pid)

	if pid == -1:
		push_error("[ProcessManager] Failed to launch process: " + exe_path)
		return -1

	# AppImage runtimes and env(1) wrappers often leave a parent process alive
	# even after the emulator window closes. Wait briefly for the real emulator
	# process to appear and discover it by walking the process tree.
	await get_tree().create_timer(0.3).timeout
	pid = _discover_emulator_pid(pid, arguments)

	return pid

## Reads a /proc virtual file whose reported size is 0. Godot's
## FileAccess.get_file_as_string() returns empty for such files, so we read
## chunks until EOF.
func _read_proc_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = []
	while not f.eof_reached():
		var chunk = f.get_buffer(1024)
		if chunk.size() == 0:
			break
		bytes.append_array(chunk)
	f.close()
	return bytes.get_string_from_utf8()

func _current_boot_id() -> String:
	if not SystemManager.platform.is_linux():
		return ""
	return _read_proc_file("/proc/sys/kernel/random/boot_id").strip_edges()

func _process_start_ticks(pid: int) -> int:
	if pid <= 0 or not SystemManager.platform.is_linux():
		return -1
	return int(_parse_proc_stat(pid).get("start_ticks", -1))

## Parses /proc/<pid>/stat and returns a dictionary with commonly-needed
## fields. The command name is wrapped in parentheses and may contain spaces
## or closing parens, so we locate the last ')' and split the remaining
## whitespace-delimited fields.
func _parse_proc_stat(pid: int) -> Dictionary:
	var result := {
		"ok": false,
		"state": "",
		"ppid": -1,
		"pgrp": -1,
		"start_ticks": -1,
	}
	if pid <= 0:
		return result
	var content := _read_proc_file("/proc/" + str(pid) + "/stat")
	if content == "":
		return result
	var close_paren := content.rfind(")")
	if close_paren == -1:
		return result
	var tail := content.substr(close_paren + 1).strip_edges()
	var fields := tail.split(" ", false)
	# Fields after ')': 0 = state, 1 = ppid, 2 = pgrp.
	if fields.size() >= 1:
		result["ok"] = true
		result["state"] = fields[0]
	if fields.size() >= 3:
		result["ppid"] = fields[1].to_int()
		result["pgrp"] = fields[2].to_int()
	if fields.size() >= 20:
		result["start_ticks"] = fields[19].to_int()
	return result

# ==================== PROCESS GROUP TRACKING (LINUX) ====================

## Returns the process group ID of a live process, or -1 when unknown.
func get_pgid(pid: int) -> int:
	if pid <= 0 or not SystemManager.platform.is_linux():
		return -1
	var stat := _parse_proc_stat(pid)
	if stat.ok:
		return int(stat.get("pgrp", -1))
	return -1

## Kyodai's own process group; group signals must never target it (an
## emulator whose PGID resolution failed must degrade to single-PID signals).
func _get_own_pgid() -> int:
	if _own_pgid <= 0:
		_own_pgid = get_pgid(OS.get_process_id())
	return _own_pgid

## Maps every live (non-zombie) member of a process group: pid -> state char.
func _get_group_states(pgid: int) -> Dictionary:
	var states := {}
	if pgid <= 1 or not SystemManager.platform.is_linux():
		return states
	var proc_dir := DirAccess.open("/proc")
	if proc_dir == null:
		return states
	proc_dir.list_dir_begin()
	var entry := proc_dir.get_next()
	while entry != "":
		if entry.is_valid_int():
			var scan_pid := entry.to_int()
			if scan_pid > 0:
				var stat := _parse_proc_stat(scan_pid)
				if stat.ok and int(stat.get("pgrp", -1)) == pgid and stat.state != "Z":
					states[scan_pid] = stat.state
		entry = proc_dir.get_next()
	proc_dir.list_dir_end()
	return states

## Returns all live (non-zombie) member PIDs of the given process group.
func get_group_members(pgid: int) -> Array[int]:
	var members: Array[int] = []
	for member_pid in _get_group_states(pgid).keys():
		members.append(member_pid)
	return members

## True while any non-zombie process belongs to the group.
func is_group_alive(pgid: int) -> bool:
	return not _get_group_states(pgid).is_empty()

## True when every live member of the group is stopped (SIGSTOP/SIGTSTP).
## False when the group is empty (nothing left to be stopped).
func are_group_members_stopped(pgid: int) -> bool:
	var states := _get_group_states(pgid)
	if states.is_empty():
		return false
	for state in states.values():
		if state != "T" and state != "t":
			return false
	return true

## Group-aware stopped check for callers that only know a PID (shuffler).
## Lenient mode: a dead PID/group counts as stopped (nothing left to freeze).
## Strict mode (suspend verification): "can't find anything" is NOT proof of
## "stopped" — an escaped payload reads identically to a dead one, and only
## strict mode forces the caller's kill-and-relaunch fallback instead of
## silently leaving a live emulator playing in the background.
func are_group_stopped_for_pid(pid: int, strict: bool = false) -> bool:
	if pid <= 0:
		return not strict
	var pgid := get_pgid(pid)
	if pgid <= 1:
		# No resolvable group; fall back to the PID's own state. A missing or
		# zombie PID proves nothing in strict mode.
		var stat := _parse_proc_stat(pid)
		if not stat.ok or stat.state == "Z":
			return not strict
		return stat.state == "T" or stat.state == "t"
	var states := _get_group_states(pgid)
	if states.is_empty():
		# Whole group dead, or the payload escaped the group and the leader
		# is a zombie: indistinguishable from here, so strict mode fails safe.
		return not strict
	for state in states.values():
		if state != "T" and state != "t":
			return false
	return true

## Resolves the process that actually represents a launch right now: the
## tracked PID when it (or its group) still lives, else a payload found by
## launch signature (emulators re-exec/fork away from the spawned leader —
## AppImage AppRun, Vita3K's second window process). Returns
## {"pid": -1, "pgid": -1} when nothing belonging to the launch is alive.
## pgid stays -1 when the only viable group is Kyodai's own (unsafe to
## group-signal); callers then degrade to single-PID signals.
func resolve_live_target(pid: int, signature: String = "", exe_signature: String = "") -> Dictionary:
	var result := {"pid": -1, "pgid": -1}
	if not SystemManager.platform.is_linux():
		if pid > 0:
			result["pid"] = pid
		return result
	if pid > 0:
		var stat := _parse_proc_stat(pid)
		if stat.ok:
			var pgrp := int(stat.get("pgrp", -1))
			if stat.state != "Z":
				result["pid"] = pid
				if pgrp > 1 and pgrp != _get_own_pgid():
					result["pgid"] = pgrp
				return result
			# Zombie leader: the payload may still live in its group.
			if pgrp > 1 and pgrp != _get_own_pgid() and is_group_alive(pgrp):
				result["pid"] = pid
				result["pgid"] = pgrp
				return result
	if signature != "" or exe_signature != "":
		var found := find_process_by_signature(signature, exe_signature)
		if found > 0:
			result["pid"] = found
			var pgrp := get_pgid(found)
			if pgrp > 1 and pgrp != _get_own_pgid():
				result["pgid"] = pgrp
	return result

## Formats a process group as "pid(state),pid(state)" for diagnostics.
func format_group_states(pgid: int) -> String:
	var states := _get_group_states(pgid)
	var parts: Array = []
	for member_pid in states.keys():
		parts.append(str(member_pid) + "(" + str(states[member_pid]) + ")")
	return ",".join(parts)

## Reads immediate child PIDs of a process from /proc.
func _get_process_children(pid: int) -> Array[int]:
	var children: Array[int] = []
	if pid <= 0:
		return children
	var path = "/proc/" + str(pid) + "/task/" + str(pid) + "/children"
	var content = _read_proc_file(path).strip_edges()
	if content == "":
		return children
	for part in content.split(" ", false):
		var child_pid = part.to_int()
		if child_pid > 0:
			children.append(child_pid)
	return children

## Reads the command line of a process.
func _get_process_cmdline(pid: int) -> String:
	if pid <= 0:
		return ""
	var path = "/proc/" + str(pid) + "/cmdline"
	var content = _read_proc_file(path)
	# Replace null bytes with spaces
	var bytes = content.to_utf8_buffer()
	for i in range(bytes.size()):
		if bytes[i] == 0:
			bytes[i] = 32  # space
	return bytes.get_string_from_utf8().strip_edges()

## Reads the short command name (comm) of a process from /proc/<pid>/comm.
func _get_process_comm(pid: int) -> String:
	if pid <= 0:
		return ""
	return _read_proc_file("/proc/" + str(pid) + "/comm").strip_edges()

## Returns true if the given PID is a Linux AppImage runtime wrapper.
## Raw-AppImage wrappers fork the real emulator payload and stay alive to
## manage the FUSE mount, so they must not be mistaken for the emulator
## process itself. They are identified by LOCATION (exe under /tmp/.mount_*),
## never by name: for extracted installs AppRun IS the emulator (RetroArch's
## AppRun is the retroarch binary itself, and it even daemonizes into its own
## session), so a comm=="AppRun" name check would skip the exact process the
## signature scan is meant to adopt.
func _is_appimage_wrapper_pid(pid: int) -> bool:
	if pid <= 0 or not SystemManager.platform.is_linux():
		return false
	var exe_link := "/proc/" + str(pid) + "/exe"
	if FileAccess.file_exists(exe_link):
		var proc_dir := DirAccess.open("/proc")
		var exe_path := proc_dir.read_link(exe_link) if proc_dir != null else ""
		if exe_path != "" and exe_path.begins_with("/tmp/.mount_"):
			return true
		if exe_path != "":
			# Resolved exe is not on a FUSE mount: this is a real process,
			# regardless of comm (extracted AppRun included).
			return false
	# exe unreadable (kernel task, permission, race): fall back to the legacy
	# comm heuristic so raw-AppImage wrappers are still excluded.
	return _get_process_comm(pid) == "AppRun"

## Reads the parent PID from /proc/<pid>/status.
func _get_parent_pid(pid: int) -> int:
	if pid <= 0:
		return 0
	var path = "/proc/" + str(pid) + "/status"
	var content = _read_proc_file(path)
	for line in content.split("\n", false):
		if line.begins_with("PPid:"):
			var parts = line.split(":", false)
			if parts.size() >= 2:
				return parts[1].strip_edges().to_int()
	return 0

## Computes how many parent-child hops target_pid is below initial_pid.
func _pid_depth(initial_pid: int, target_pid: int) -> int:
	var depth := 0
	var current := target_pid
	while current > 0 and current != initial_pid:
		current = _get_parent_pid(current)
		depth += 1
		if depth > 20:  # Safety break
			break
	if current == initial_pid:
		return depth
	return 0

## Recursively collects all descendant PIDs of a process.
func _collect_descendants(pid: int, collected: Dictionary = {}) -> void:
	if collected.has(pid):
		return
	collected[pid] = true
	for child in _get_process_children(pid):
		_collect_descendants(child, collected)

## Tries to find the actual emulator PID under the initial wrapper PID.
## Returns the best candidate (deepest descendant whose cmdline matches the
## launch arguments) or the initial PID if no better candidate is found.
func _discover_emulator_pid(initial_pid: int, launch_args: Array) -> int:
	if initial_pid <= 0:
		return initial_pid

	var initial_cmdline := _get_process_cmdline(initial_pid)
	if DEBUG_LOG: print("[ProcessManager] Initial PID ", initial_pid, " cmdline=\"", initial_cmdline, "\"")

	var descendants := {}
	_collect_descendants(initial_pid, descendants)
	descendants.erase(initial_pid)  # Don't include the wrapper itself

	if descendants.is_empty():
		if DEBUG_LOG: print("[ProcessManager] No child processes found under PID ", initial_pid, ", using initial PID")
		return initial_pid

	# Signature from launch arguments (excluding the executable path) so we can
	# match the real emulator even when the executable name changes (AppRun -> retroarch).
	var arg_signature := ""
	if launch_args.size() > 1:
		arg_signature = " ".join(launch_args.slice(1))

	var best_pid := initial_pid
	var best_depth := 0
	for pid in descendants.keys():
		var depth := _pid_depth(initial_pid, pid)
		var cmdline := _get_process_cmdline(pid)
		if DEBUG_LOG: print("[ProcessManager] Descendant PID ", pid, " depth=", depth, " cmdline=\"", cmdline, "\"")
		if arg_signature != "" and cmdline.contains(arg_signature):
			if best_pid == initial_pid or depth > best_depth:
				best_pid = pid
				best_depth = depth
		elif best_pid == initial_pid:
			# Fallback: deepest leaf if no argument match yet
			if depth > best_depth:
				best_pid = pid
				best_depth = depth

	if best_pid != initial_pid:
		print("[ProcessManager] Discovered emulator PID ", best_pid, " (initial was ", initial_pid, ")")
		return best_pid

	# Final fallback: the emulator may have already been reparented away from the
	# wrapper (e.g. AppImage runtime). Scan all of /proc for a live process whose
	# cmdline contains the launch argument signature.
	if arg_signature != "":
		var proc_dir := DirAccess.open("/proc")
		if proc_dir != null:
			proc_dir.list_dir_begin()
			var entry := proc_dir.get_next()
			while entry != "":
				if entry.is_valid_int():
					var scan_pid := entry.to_int()
					if scan_pid > 0 and scan_pid != initial_pid:
						var stat := _parse_proc_stat(scan_pid)
						if stat.ok and stat.state != "Z":
							var cmdline := _get_process_cmdline(scan_pid)
							if cmdline.contains(arg_signature):
								print("[ProcessManager] Discovered reparented emulator PID ", scan_pid, " via /proc scan")
								proc_dir.list_dir_end()
								return scan_pid
				entry = proc_dir.get_next()
			proc_dir.list_dir_end()

	print("[ProcessManager] Could not match child cmdline, keeping initial PID ", initial_pid)
	return initial_pid

func _execute_android(intent: LaunchIntent) -> bool:
	# Enforce Kyodai-managed data paths in the emulator's writable config, when
	# the emulator exposes one (e.g. ARMSX2's armsx2-settings.json). Failures are
	# logged but do not block the launch because many Android apps keep their
	# settings inside private app data Kyodai cannot reach.
	if not RSM.enforce_paths(intent.emulator_id, intent.platform_slug, intent.core_name):
		push_warning("[ProcessManager] Could not enforce config paths for Android emulator %s" % intent.emulator_id)

	# On handhelds with a vendor root daemon, seed emulator-private prefs
	# (OOBE skip, e.g. x1box) before the intent goes out. No-op elsewhere.
	launch_manager.emulator.provision_via_root(intent.emulator_id)

	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		push_error("[ProcessManager] KyodaiBridge plugin not available for Android launch")
		return false

	# Check if we need MANAGE_EXTERNAL_STORAGE permission for FileProvider to work with SD cards
	if not plugin.hasManageExternalStoragePermission():
		push_warning("[ProcessManager] MANAGE_EXTERNAL_STORAGE permission not granted - FileProvider may fail for SD card files")
		# Show dialog to user explaining they need to grant the permission manually
		if UIManager:
			UIManager.show_alert("Permission Required", "To launch games from SD card storage, Kyodai needs 'All Files Access' permission.\n\nPlease grant this permission in Settings → Apps → Kyodai → Permissions → Files",
				func(): plugin.requestManageExternalStoragePermission(),
				Callable(),
				{"ok_text": "Open Settings"}
			)
		return false

	# Format the core path for RetroArch
	var core_path = ""

	# Check if using CoreSideloadActivity (for testing sideloaded cores)
	if intent.android_class == "com.retroarch.browser.debug.CoreSideloadActivity":
		# Use downloaded core from emulator directory
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Cores are downloaded to {emulator_dir}/cores
			# Use real filesystem path - with MANAGE_EXTERNAL_STORAGE, RetroArch can read directly
			core_path = FSM.resolve_emulator_path("cores/" + core_filename, intent.emulator_id, "", FSM.PathFormat.ABSOLUTE)
			if DEBUG_LOG: print("[ProcessManager] Core path for sideload: " + core_path)
	else:
		# Regular RetroArch launch - use internal core path
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Build core path using the actual package name from intent
			var retroarch_package = intent.android_package
			if retroarch_package != "":
				core_path = "/data/data/" + retroarch_package + "/cores/" + core_filename
			else:
				# Fallback if package name is somehow empty
				core_path = "/data/data/com.retroarch/cores/" + core_filename

	# Resolve ROM path to absolute filesystem path for the Java plugin.
	# The plugin creates File objects directly, so user:// virtual paths won't work.
	var absolute_rom_path = FSM.resolve_path(intent.rom_path, {"format": FSM.PathFormat.ABSOLUTE})
	print("[ProcessManager] Resolved ROM path for Android intent: " + absolute_rom_path)

	# Retained mode must preserve the existing Android task. Standard mode keeps
	# the emulator's configured clear_task behavior unchanged.
	var clear_task = intent.android_config.get("clear_task", true)
	# Never hold the emulator intent behind privileged initialization. The
	# post-handoff retention configuration performs the authoritative probe.
	if launch_manager.android_tasks.retention_available_cached():
		clear_task = false
	var rom_delivery = intent.android_config.get("rom_delivery", "intent_data")
	var mime_type = intent.android_config.get("mime_type", "application/octet-stream")
	var grant_uri_permission = intent.android_config.get("grant_uri_permission", true)
	var use_document_uri = intent.android_config.get("use_document_uri", false)
	var use_file_uri = intent.android_config.get("use_file_uri", false)

	# Convert extras array to JSON string
	var extras_array = intent.android_extras
	if extras_array.is_empty() and intent.android_config.has("extras"):
		extras_array = intent.android_config.get("extras", [])

	# Convert extras to JSON using proper JSON.stringify to handle escaping correctly
	# Replace {core_path} placeholder with actual core path
	var extras_json = "[]"
	if extras_array.size() > 0:
		var extras_to_serialize = []
		for extra in extras_array:
			var value = extra.get("value", "")
			if value.contains("{core_path}"):
				value = value.replace("{core_path}", core_path)
				if DEBUG_LOG: print("[ProcessManager] Replaced {core_path} with: " + core_path)

			extras_to_serialize.append({
				"key": extra.get("key", ""),
				"value": value,
				"type": extra.get("type", "string")
			})
		var json_result = JSON.stringify(extras_to_serialize)
		if json_result == "":
			push_error("[ProcessManager] Failed to serialize extras to JSON")
		else:
			extras_json = json_result

	# The pending record exists before the external handoff. If intent delivery
	# fails, abort it without playtime/upload instead of leaving a live phantom.
	_background_backend = GameSession.Backend.ANDROID_TASK
	_background_active_game = intent.game
	_android_emulator_package = intent.android_package
	_begin_game_session(intent.game)
	var success = plugin.call("launchAndroidIntent",
		intent.android_action,
		intent.android_package,
		intent.android_class,
		absolute_rom_path,
		core_path,
		rom_delivery,
		extras_json,
		mime_type,
		clear_task,
		grant_uri_permission,
		use_document_uri,
		use_file_uri
	)

	if not success:
		push_error("[ProcessManager] Failed to launch Android intent")
		if _active_session:
			launch_manager.sessions.abort_session(_active_session)
			_active_session = null
		_clear_android_background()
		return false

	# Enter background state for Android - we track the game and exit on resume
	# (or when the presence watch sees the emulator leave the foreground).
	enter_background_state_android(intent.game, intent.android_package)

	return true

## Shows a reminder dialog on Android after APK installation
## Prompts the user to open the newly installed emulator and grant permissions
func _show_android_permissions_reminder(emulator_id: String) -> void:
	# Only show on Android
	if SystemManager.platform.get_platform_name().to_lower() != "android":
		return

	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)

	# Don't stack a second reminder if one is already open for this emulator
	if launch_manager._open_install_reminders.has(emulator_id):
		print("[ProcessManager] Install reminder already open for: " + emulator_name)
		return

	launch_manager._open_install_reminders[emulator_id] = true

	# Emulators with a discover block carry their own setup instructions (e.g.
	# azahar: finish the wizard, kyodai adopts whatever folder is picked).
	var message: String = "Please open " + emulator_name + " from your app drawer and grant any requested permissions (especially storage access) before launching games."
	var setup_prompt: String = emulator.get("discover", {}).get("android", {}).get("setup_prompt", "")
	if setup_prompt != "":
		message = setup_prompt

	# Create M3Dialog reminder as a distinct overlay type so it stacks above the settings dialog.
	# "Got it" routes through LaunchManager so a mid-game-launch pending launch can
	# resume (or abort) once the user acknowledges the reminder.
	UIManager.show_alert("Installation Reminder", message,
		launch_manager.on_install_reminder_dismissed.bind(emulator_id),
		Callable(),
		{"ok_text": "Got it", "overlay_type": "alert", "overlay_layer": OverlayLayers.MENU, "dismissible": false}
	)

	print("[ProcessManager] Shown Android permissions reminder for: " + emulator_name)
