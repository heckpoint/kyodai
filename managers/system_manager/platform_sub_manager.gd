extends Manager
class_name PlatformSubManager

## Forwarded from the Android plugin's ComponentCallbacks2.onTrimMemory.
## Level values match Android: 20=UI_HIDDEN 40=BACKGROUND 60=MODERATE
## 80=COMPLETE (next in line for the LMK kill).
signal trim_memory(level: int)

enum Platform {
	WINDOWS,
	LINUX,
	ANDROID,
	UNKNOWN
}

var current_platform: Platform = Platform.UNKNOWN

func _ready():
	_detect_platform()
	_setup_platform_specific_behavior()

func _setup_platform_specific_behavior():
	if is_android():
		# Disable native Android virtual keyboard - we use our own onscreen keyboard
		get_tree().node_added.connect(_on_node_added_android)
		# Forward the plugin's onTrimMemory escalation signal
		_connect_trim_memory_signal()
		# Check and request permissions on Android (skip during first-run OOBE)
		var first_run_completed = DataManager.get_setting("first_run_completed")
		if first_run_completed and first_run_completed.value:
			_request_android_permissions()
		# Startup leg of the install-grant session check (see below).
		call_deferred("_startup_install_grant_check")

## Connects the KyodaiBridge plugin's trim_memory signal for re-emission.
## Deferred retry covers the case where the plugin singleton is not yet
## registered at autoload _ready time.
var _trim_signal_retries: int = 0
const TRIM_SIGNAL_MAX_RETRIES := 10
func _connect_trim_memory_signal() -> void:
	var plugin = _get_android_plugin()
	if plugin == null:
		_trim_signal_retries += 1
		if _trim_signal_retries <= TRIM_SIGNAL_MAX_RETRIES:
			call_deferred("_connect_trim_memory_signal")
		else:
			push_warning("[SystemManager.platform] KyodaiBridge plugin unavailable; trim_memory signal not connected")
		return
	if plugin.has_signal("trim_memory") and not plugin.trim_memory.is_connected(_on_plugin_trim_memory):
		plugin.trim_memory.connect(_on_plugin_trim_memory)

func _on_plugin_trim_memory(level: int) -> void:
	trim_memory.emit(level)

func _notification(what: int) -> void:
	if not is_android():
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_on_android_window_focus_in()
		# Returning from the system installer or the grant toggle: run the
		# install-session state machine (deferred - UI layer may be settling).
		call_deferred("evaluate_install_grant_state")

func _on_android_window_focus_in() -> void:
	# The native IME must never be visible - it steals gamepad key events via
	# its input connection. Hide it natively and through the plugin.
	DisplayServer.virtual_keyboard_hide()
	var plugin = _get_android_plugin()
	if plugin and plugin.has_method("forceHideKeyboard"):
		plugin.forceHideKeyboard()
	# A text field holding focus at window-focus time can re-attach the IME.
	# Release it unless our own on-screen keyboard is intentionally open.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		focus_owner.release_focus()

func _on_node_added_android(node: Node):
	# When a LineEdit/TextEdit is added on Android, disable the native virtual keyboard
	# We use our own onscreen keyboard instead
	if node is LineEdit:
		node.virtual_keyboard_enabled = false
	elif node is TextEdit:
		# TextEdit doesn't have virtual_keyboard_enabled, use focus callback
		node.focus_entered.connect(_hide_android_keyboard.bind(node))

func _hide_android_keyboard(_node: Control):
	# Hide the native Android virtual keyboard when TextEdit gets focus
	DisplayServer.virtual_keyboard_hide()

func _detect_platform():
	match OS.get_name():
		"Windows":
			current_platform = Platform.WINDOWS
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			current_platform = Platform.LINUX
		"Android":
			current_platform = Platform.ANDROID
		_:
			current_platform = Platform.UNKNOWN

func is_windows() -> bool:
	return current_platform == Platform.WINDOWS

func is_linux() -> bool:
	return current_platform == Platform.LINUX

func is_android() -> bool:
	return current_platform == Platform.ANDROID

## Returns true when running an exported build (not the editor).
## Packaged builds cannot execute or stat files stored inside the PCK.
func is_packaged() -> bool:
	return not OS.has_feature("editor")

## Returns true when running inside a gamescope Game Mode session (SteamOS
## game mode and friends). Game Mode only presents fullscreen windows, so
## overlay windows must be fullscreen and window switching must bypass EWMH
## hints the gamescope WM ignores.
func is_gamemode() -> bool:
	if not is_linux():
		return false
	var haystack := (
		OS.get_environment("XDG_CURRENT_DESKTOP") + ";"
		+ OS.get_environment("XDG_SESSION_DESKTOP") + ";"
		+ OS.get_environment("DESKTOP_SESSION") + ";"
		+ OS.get_environment("WAYLAND_DISPLAY")
	).to_lower()
	return haystack.contains("gamescope")

func get_platform_name() -> String:
	match current_platform:
		Platform.WINDOWS:
			return "Windows"
		Platform.LINUX:
			return "Linux"
		Platform.ANDROID:
			return "Android"
		_:
			return "Unknown"

func get_settings_key_for_emulator() -> String:
	match current_platform:
		Platform.WINDOWS:
			return "emulator_path_windows"
		Platform.LINUX:
			return "emulator_path_linux"
		Platform.ANDROID:
			return "emulator_path_android"
		_:
			return ""

## Requests necessary permissions on Android
func _request_android_permissions():
	# Get currently granted permissions
	var granted_permissions = OS.get_granted_permissions()
	
	# Check and request standard runtime permissions
	var permissions_to_request = []
	
	# Check storage permissions
	if not "android.permission.READ_EXTERNAL_STORAGE" in granted_permissions:
		permissions_to_request.append("android.permission.READ_EXTERNAL_STORAGE")
	
	if not "android.permission.WRITE_EXTERNAL_STORAGE" in granted_permissions:
		permissions_to_request.append("android.permission.WRITE_EXTERNAL_STORAGE")
	
	# Check internet permission (usually granted automatically)
	if not "android.permission.INTERNET" in granted_permissions:
		permissions_to_request.append("android.permission.INTERNET")
	
	# Check network state permission
	if not "android.permission.ACCESS_NETWORK_STATE" in granted_permissions:
		permissions_to_request.append("android.permission.ACCESS_NETWORK_STATE")
	
	# Check notification permission (Android 13+ / API 33+)
	# Required for foreground service notifications during downloads
	if not "android.permission.POST_NOTIFICATIONS" in granted_permissions:
		permissions_to_request.append("android.permission.POST_NOTIFICATIONS")
	
	if permissions_to_request.size() > 0:
		# Request each permission individually. OS.request_permissions() sweeps
		# EVERY manifest permission - including REQUEST_INSTALL_PACKAGES, which
		# Godot handles by opening the "Install unknown apps" settings page.
		# Since WRITE_EXTERNAL_STORAGE can never be granted on Android 13+,
		# permissions_to_request is never empty there, so the blanket call made
		# that settings page appear at EVERY app start.
		for permission in permissions_to_request:
			OS.request_permission(permission)
	
	# Note: "Install unknown apps" permission is checked when user tries to install an emulator
	# We don't prompt on startup to avoid annoying the user

## Opens Android Settings to enable "Install unknown apps" permission
func open_install_unknown_apps_settings():
	if not is_android():
		return
	
	# Use the KyodaiBridge plugin to launch with the correct intent action
	# (ACTION_APPLICATION_DETAILS_SETTINGS + package: URI). OS.shell_open uses
	# ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin:
		plugin.requestInstallUnknownAppsPermission()

## Checks if a specific permission is granted on Android
func has_permission(permission_name: String) -> bool:
	if not is_android():
		return true  # Non-Android platforms don't need Android permissions
	
	var granted_permissions = OS.get_granted_permissions()
	return permission_name in granted_permissions

## Checks if storage access is granted (handles both old and new Android permission models)
func has_storage_permission() -> bool:
	if not is_android():
		return true
	
	var granted = OS.get_granted_permissions()
	var has_old = "android.permission.READ_EXTERNAL_STORAGE" in granted and "android.permission.WRITE_EXTERNAL_STORAGE" in granted
	var has_manage = "android.permission.MANAGE_EXTERNAL_STORAGE" in granted
	return has_old or has_manage

## Opens Android Settings to enable MANAGE_EXTERNAL_STORAGE permission
func open_manage_storage_settings():
	if not is_android():
		return

	# Use the KyodaiBridge plugin to launch with the correct intent action
	# (ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION + package: URI).
	# OS.shell_open uses ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin:
		plugin.requestManageExternalStoragePermission()

# ============================================================================
# ANDROID APP-DATA (SAF) ACCESS — just-in-time grant
# Direct File I/O (with MANAGE_EXTERNAL_STORAGE) is our primary path for all
# storage. Other apps' /Android/data/ and /Android/obb/ are the one exception:
# they're gated on the ext_data_rw group. When Kyodai holds it (firmware-
# dependent), direct I/O just works; failing that, a live vendor root daemon
# covers every package; failing that, we need a one-time document-tree grant
# per package folder. This guard prompts only when no route exists
# (argosy-style), calls back with true once usable access exists.
# ============================================================================

var _saf_grant_pending_callback: Callable = Callable()

## The access route for a filesystem path - the single source of truth for
## flow decisions (prompt for a grant, stage a download, proceed). Mirrors
## StorageTier in the KyodaiBridge plugin, whose probes (ext_data_rw gid,
## persisted grant coverage, vendor root daemon) back every file op.
enum AccessRoute { DIRECT, SAF, ROOT, NONE }

## Resolves the route for an absolute path. DIRECT: plain File I/O works
## (unrestricted path, desktop, or we hold ext_data_rw). SAF: a persisted
## document-tree grant covers the path - only plugin operations reach it.
## ROOT: a live vendor daemon writes via the plugin; our own process still
## cannot direct-write. NONE: no route exists - prompt for a grant.
func access_route(path: String) -> int:
	if not is_android():
		return AccessRoute.DIRECT
	var plugin = _get_android_plugin()
	if plugin == null or path == "":
		return AccessRoute.NONE
	return int(plugin.call("accessRouteForPath", path))

## True when any access route exists for the path (direct, SAF grant, or root
## daemon). When false, the flow should prompt for a document-tree grant.
func has_android_data_access(path: String = "") -> bool:
	if not is_android():
		return true
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	if path == "":
		# Legacy no-path semantics: any viable route mechanism.
		if plugin.has_method("hasExtDataRwAccess") and bool(plugin.hasExtDataRwAccess()):
			return true
		var root_available = plugin.call("rootAvailable")
		if root_available != null and root_available:
			return true
		return bool(plugin.hasSafGrant())
	return access_route(path) != AccessRoute.NONE

## True when plain File I/O (FileAccess, HTTPRequest downloads) can write the
## path directly. Root-daemon devices answer false for restricted paths: only
## the daemon writes there, via plugin calls - our own process cannot.
func has_direct_android_data_access(path: String = "") -> bool:
	return access_route(path) == AccessRoute.DIRECT

## Calls on_ready(granted: bool). If a document-tree grant already exists, calls
## back immediately with true. Otherwise shows a prompt and launches the system
## folder picker; the callback fires when the flow resolves.
## path: the restricted path that needs access (grant targets its package folder).
func ensure_android_data_access(on_ready: Callable, path: String = "") -> void:
	if not is_android():
		on_ready.call(true)
		return
	var plugin = _get_android_plugin()
	if plugin == null:
		on_ready.call(false)
		return
	if has_android_data_access(path):
		on_ready.call(true)
		return
	# A grant flow is already in flight; queue behind it
	if _saf_grant_pending_callback.is_valid():
		on_ready.call(false)
		return

	_saf_grant_pending_callback = on_ready
	if not plugin.is_connected("saf_grant_result", _on_saf_grant_result):
		plugin.connect("saf_grant_result", _on_saf_grant_result)

	UIManager.show_confirm(
		"Folder Access Required",
		"This needs access to an emulator's app-data folder (Android/data), which Android protects separately.\n\nThe picker will open at the right folder — just tap \"Use this folder\".",
		func():
			plugin.requestAndroidDataAccess(path),
		func():
			_resolve_saf_grant(false),
		Callable(),
		{"overlay_layer": OverlayLayers.LAUNCH_CRITICAL}  # above UILayer so it stays visible over the launch transition overlay
	)

func _on_saf_grant_result(granted: bool) -> void:
	_resolve_saf_grant(granted)

func _resolve_saf_grant(granted: bool) -> void:
	var callback = _saf_grant_pending_callback
	_saf_grant_pending_callback = Callable()
	if callback.is_valid():
		callback.call(granted)

# ============================================================================
# INSTALL PERMISSION SESSION — just-in-time "Install unknown apps"
# On AYN Odin-family firmware the runtime install grant is coupled to
# storage: while Kyodai holds it, the system strips the ext_data_rw /
# sdcard_rw supplementary gids and every Android/data write drops off the
# direct tier (revoking restores the gids, but only for a fresh process -
# see StorageTier). So the grant is treated as a temporary session pass:
# requested only when an install actually needs it, handed back when
# installs are done, followed by a restart to pick the gids back up. On
# unaffected firmware the grant strips nothing, the degraded checks below
# never match, and all of this stays invisible.
# ============================================================================

var _install_grant_awaiting_retry := false  # sent the user to grant; install resumes on return
var _installs_since_grant := 0              # install intents fired while the grant is held
var _restore_prompt_snoozed := false        # user chose "not now"; re-arms on the next install
var _restart_prompt_snoozed := false        # user declined the restart; re-arms on a new session
var _install_prompt_open := false           # a session dialog is on screen; never stack another
var _startup_grant_check_done := false
var _pending_install_action: Callable = Callable()  # blocked action to fire once the grant lands

## True when the user currently allows Kyodai to install APKs.
func can_install_unknown_apps() -> bool:
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	var granted = plugin.call("canInstallUnknownApps")
	return granted != null and granted

## True when this process still holds direct storage (ext_data_rw). While the
## install grant is held on coupled firmware this reads false.
func has_direct_storage_tier() -> bool:
	var plugin = _get_android_plugin()
	if plugin == null:
		return true  # desktop / no plugin: nothing to couple against
	var direct = plugin.call("hasExtDataRwAccess")
	return direct == null or direct  # stale AAR fails open

## True when APK installation can proceed without changing Android's install
## grant. Rooted builds use pm install; other devices keep the system flow.
func can_install_packages() -> bool:
	if not is_android():
		return true
	var plugin = _get_android_plugin()
	if plugin != null:
		var allowed = plugin.call("canInstallPackages")
		if allowed != null and allowed:
			return true
	return can_install_unknown_apps()

func apk_install_uses_root() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	var available = plugin.call("rootAvailable")
	return available != null and bool(available)

## Gate for any APK install. Returns true when the install may proceed.
## When the grant is missing, explains the temporary-permission deal and
## opens the system toggle; on_granted is stashed and fired automatically
## when the user returns with the grant enabled (enabling takes effect
## immediately - unlike revoking, no restart is needed), so the blocked
## install RESUMES instead of dying. Callers that pass no continuation fall
## back to manual retry.
func ensure_install_permission(reason: String, on_granted: Callable = Callable()) -> bool:
	if not is_android():
		return true
	if can_install_packages():
		return true
	_install_grant_awaiting_retry = true
	_pending_install_action = on_granted
	_restore_prompt_snoozed = false
	_restart_prompt_snoozed = false
	UIManager.show_confirm(
		"Install Permission Needed",
		"Installing %s requires Android's 'Install unknown apps' switch for Kyodai.\n\nOn this device that switch temporarily pauses fast storage - turn it back off when you're done installing (Kyodai will remind you).\n\nEnable it in the screen that opens and the install continues on its own." % reason,
		func(): open_install_unknown_apps_settings(),
		Callable()
	)
	return false

## Fires (and clears) the stashed continuation of a grant-blocked install.
func _fire_pending_install_action() -> void:
	var action = _pending_install_action
	_pending_install_action = Callable()
	if action.is_valid():
		print("[SystemManager.platform] Install grant enabled - resuming blocked install")
		action.call()

## Called after an install intent was successfully fired. Re-arms the
## restore/restart prompts for the next focus return.
func notify_install_started() -> void:
	if not is_android() or apk_install_uses_root():
		return
	_installs_since_grant += 1
	_restore_prompt_snoozed = false
	_restart_prompt_snoozed = false

## Evaluates grant/storage coupling and runs the JIT prompts. Called
## (deferred) on window focus-in and once after startup. The coupling check -
## grant held while this process lacks direct storage - doubles as the
## device gate: on stock Android the grant strips nothing and none of this
## ever fires.
func evaluate_install_grant_state(on_startup: bool = false) -> void:
	if not is_android() or not UIManager:
		return
	var first_run = DataManager.get_setting("first_run_completed")
	if first_run and not first_run.value:
		return  # OOBE owns the screen; the grant is requested per-install now
	var granted := can_install_unknown_apps()
	var direct := has_direct_storage_tier()
	if direct:
		# Healthy: this process has full direct storage - the grant was never
		# held, the firmware doesn't couple grant and gids (stock Android),
		# or this is a fresh process after a revoke. Nothing to manage; drop
		# any blocked-install continuation (the user bailed on the explainer).
		_install_grant_awaiting_retry = false
		_pending_install_action = Callable()
		return
	if granted:
		# Degraded: grant held, gids stripped.
		if _install_grant_awaiting_retry:
			# User just granted on our request - the grant takes effect
			# immediately, so the blocked install resumes right now.
			_install_grant_awaiting_retry = false
			_fire_pending_install_action()
			return
		if on_startup or _installs_since_grant > 0:
			# Abandoned session (startup) or installs just ran (focus return).
			_installs_since_grant = 0
			_prompt_restore_fast_storage()
	else:
		# Stale: grant revoked, but this process was forked while it was held
		# and still carries the stripped gids - only a restart picks them
		# back up. Can't occur at boot: a fresh process after revoke is
		# healthy (direct) and returns above.
		_install_grant_awaiting_retry = false
		_installs_since_grant = 0
		if not on_startup:
			_prompt_restart_for_fast_storage()

func _prompt_restore_fast_storage() -> void:
	if _restore_prompt_snoozed or _install_prompt_open:
		return
	_restore_prompt_snoozed = true
	_install_prompt_open = true
	UIManager.show_confirm(
		"Restore Fast Storage",
		"The 'Install unknown apps' switch is still on, and this device runs Kyodai's storage in slow compatibility mode while it is.\n\nDone installing for now? Turn the switch off to restore full speed.",
		func(): open_install_unknown_apps_settings(),
		Callable(),  # "Not now": snoozed until the next install
		func(): _install_prompt_open = false
	)

func _prompt_restart_for_fast_storage() -> void:
	# Snoozed or not, this must never nag: a failed/declined restart leaves
	# the state matching on every focus-in, which would loop the dialog.
	if _restart_prompt_snoozed or _install_prompt_open:
		return
	_restart_prompt_snoozed = true
	_install_prompt_open = true
	UIManager.show_confirm(
		"Restart to Restore Fast Storage",
		"The install switch is off - full storage speed comes back when Kyodai restarts.\n\nRestart now?",
		func(): _restart_app(),
		Callable(),
		func(): _install_prompt_open = false
	)

func _restart_app() -> void:
	var plugin = _get_android_plugin()
	if plugin != null:
		plugin.call("restartApp")


## One-shot startup check, delayed past boot so any dialog lands on a ready
## UI layer.
func _startup_install_grant_check() -> void:
	if _startup_grant_check_done:
		return
	_startup_grant_check_done = true
	await get_tree().create_timer(2.0).timeout
	evaluate_install_grant_state(true)

# ============================================================================
# ANDROID FOREGROUND SERVICE HELPERS (unified for SystemManager.download + DataManager)
# ============================================================================

func _get_android_plugin() -> Variant:
	if Engine.has_singleton("KyodaiBridge"):
		return Engine.get_singleton("KyodaiBridge")
	return null

## Starts the Android download foreground service
func start_download_foreground_service(game_name: String = "Game") -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] KyodaiBridge plugin not available for download foreground service")
		return false
	plugin.startDownloadForegroundService(game_name)
	return true

## Updates the Android download foreground service progress
func update_download_foreground_service(game_name: String, progress: int) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.updateDownloadForegroundService(game_name, progress)
	return true

## Stops the Android download foreground service
func stop_download_foreground_service() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.stopDownloadForegroundService()
	return true

## Starts the Android sync foreground service
func start_sync_foreground_service(platform_name: String = "Game Library", current: int = 0, total: int = 0) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] KyodaiBridge plugin not available for sync foreground service")
		return false
	plugin.startSyncForegroundService(platform_name, current, total)
	return true

## Updates the Android sync foreground service progress
func update_sync_foreground_service(platform_name: String, current: int = 0, total: int = 0) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.updateSyncForegroundService(platform_name, current, total)
	return true

## Stops the Android sync foreground service
func stop_sync_foreground_service() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.stopSyncForegroundService()
	return true

func supports_per_session_pending_records() -> bool:
	# has_method() is unreliable for GodotPlugin-exposed Java methods. The
	# bundled AAR always provides the per-session API.
	return is_android() and _get_android_plugin() != null

## Starts the Android game-session foreground service, which runs in its own
## process and owns the session end (presence watch, end_unix annotation,
## launcher cold-start) even when LMK kills the Godot process.
func start_game_session_foreground_service(game_name: String, start_time_ms: int, emulator_package: String = "", romm_id: int = 0, session_id: String = "", retained_mode: bool = false) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] KyodaiBridge plugin not available for game session foreground service")
		return false
	plugin.startGameSessionWithIdentity(game_name, start_time_ms, emulator_package, romm_id, session_id, retained_mode)
	return true

## Stops the Android game-session foreground service
func stop_game_session_foreground_service() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.stopGameSessionForegroundService()
	return true

## True when the user granted Usage Access (Settings > Usage access).
## The Android presence watch degrades to resume-only tracking without it.
func has_usage_stats_permission() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	return bool(plugin.hasUsageStatsPermission())

## Opens the system Usage Access settings page.
func open_usage_access_settings() -> void:
	if not is_android():
		return
	var plugin = _get_android_plugin()
	if plugin != null:
		plugin.openUsageAccessSettings()

## Package that most recently moved to the foreground within lookback_ms,
## or "" when unknown/ungranted. "" must never count as a presence miss.
func get_foreground_package_name(lookback_ms: int) -> String:
	if not is_android():
		return ""
	var plugin = _get_android_plugin()
	if plugin == null:
		return ""
	var result = plugin.getForegroundPackageName(lookback_ms)
	return result if result is String else ""

## True when the keyguard is locked (screen off mid-game is not a miss).
func is_keyguard_locked() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	return bool(plugin.isKeyguardLocked())

func _exit_tree() -> void:
	"""Disconnect platform-specific scene-tree signals to avoid leaked callables."""
	if is_android() and get_tree().node_added.is_connected(_on_node_added_android):
		get_tree().node_added.disconnect(_on_node_added_android)
