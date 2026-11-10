# app_update_checker.gd
extends RefCounted
class_name AppUpdateChecker

## Self-update check against Kyodai's own GitHub releases.
##
## Compares the newest release on the user's configured channel (Stable =
## non-prerelease only, Experimental = include prereleases) against the
## running build's version and, when a newer one exists, shows a dialog.
##
## Install behavior is platform-specific:
## - Android: "Download & Install" downloads the APK in-app. Rooted builds
##   replace it through the privileged backend and relaunch automatically;
##   other devices use the system package installer. App data survives because
##   all releases share one signature.
## - Desktop: "Download" opens the release page in the browser (file-swap
##   self-install is future work).
## Dev builds (custom feature "dev", e.g. the Android Dev preset) skip the
## check entirely - they're pushed directly from dev environments.

const REPO := "carter-lilley/kyodai"
const RELEASE_PAGE_BASE := "https://github.com/" + REPO + "/releases/tag/"
const UPDATES_DIR := "user://updates/"

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Fire-and-forget: safe to call during startup. Automatic checks fail
## silently (logged only) so a flaky network can never interrupt boot;
## manual checks (settings "Check Now" button) report every outcome via
## snackbar, since the user is actively waiting on a result.
static func check_for_updates(from_manual_trigger: bool = false) -> void:
	if not DataManager or not SystemManager or not SystemManager.network:
		return

	# Editor/dev runs have no meaningful version relationship to releases.
	if OS.has_feature("editor"):
		if from_manual_trigger:
			_notify("Update checks are disabled in editor builds", SystemManager.notifications.Type.INFO)
		return

	# Dev builds are deployed directly; self-updating them makes no sense.
	if OS.has_feature("dev"):
		if from_manual_trigger:
			_notify("Update checks are disabled in dev builds", SystemManager.notifications.Type.INFO)
		return

	if not from_manual_trigger:
		var toggle: SettingsVar = DataManager.get_setting("update_check_on_startup")
		if toggle and not toggle.value:
			return

		# First run: the OOBE wizard owns the screen, and a fresh install is
		# almost certainly current.
		var first_run: SettingsVar = DataManager.get_setting("first_run_completed")
		if first_run and not first_run.value:
			return

	var current := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	if current == "":
		return

	var asset_pattern := _platform_asset_pattern()
	if asset_pattern == "":
		return  # No release artifacts exist for this platform.

	var channel: SettingsVar = DataManager.get_setting("release_channel")
	# Channel index 1 (Experimental) opts into prereleases; anything else
	# (including a missing setting) stays on Stable.
	var include_prereleases := channel != null and channel.value is int and int(channel.value) == 1

	var on_release := func(download_url: String, tag: String, error: String, size: int, _published: String, _asset_updated: String, _sha256: String):
		if error != "":
			print("[AppUpdateChecker] Update check failed: " + error)
			if from_manual_trigger:
				_notify("Update check failed: " + error, SystemManager.notifications.Type.ERROR)
			return
		if tag == "":
			return
		# When every release is a prerelease, /releases/latest 404s and the
		# network fallback returns a prerelease even for Stable users. Tags
		# carry the prerelease marker (v0.7.0-beta.1), so filter it here.
		if not include_prereleases and tag.contains("-"):
			print("[AppUpdateChecker] Up to date on Stable (%s; newest is prerelease %s)" % [current, tag])
			if from_manual_trigger:
				_notify("You're up to date on Stable (%s; %s is an Experimental prerelease)" % [current, tag], SystemManager.notifications.Type.SUCCESS)
			return
		if VersionCompare.is_newer(tag, current):
			print("[AppUpdateChecker] Update available: %s -> %s" % [current, tag])
			# Deferred: the HTTP callback can land during early startup,
			# before the dialog layer is ready to host an M3Dialog.
			_show_update_dialog.call_deferred(tag, current, download_url, size)
		else:
			print("[AppUpdateChecker] Up to date (%s, latest %s)" % [current, tag])
			if from_manual_trigger:
				_notify("You're up to date (v%s)" % current, SystemManager.notifications.Type.SUCCESS)

	SystemManager.network.fetch_repo_release(REPO, asset_pattern, on_release, "", "", include_prereleases)

static func _platform_asset_pattern() -> String:
	if not SystemManager or not SystemManager.platform:
		return ""
	if SystemManager.platform.is_windows():
		return "Kyodai-windows-x64\\.zip"
	if SystemManager.platform.is_linux():
		return "Kyodai-.*\\.AppImage"
	if SystemManager.platform.is_android():
		# Distribution channels are locked: legacy users never migrate to the
		# standard artifact, and standard users never migrate to legacy. The
		# installed target SDK determines which asset is eligible, not recency.
		if Engine.has_singleton("KyodaiBridge"):
			var target = Engine.get_singleton("KyodaiBridge").call("getAppTargetSdkVersion")
			if target >= 0 and target <= 22:
				return "Kyodai-legacy\\.apk"
		return "Kyodai\\.apk"
	return ""

static func _notify(text: String, type: int) -> void:
	# Deferred for the same reason as the dialog: the HTTP callback can land
	# before the snackbar layer is ready during early startup.
	if SystemManager and SystemManager.notifications:
		SystemManager.notifications.show_notification.call_deferred(text, type)

static func _show_update_dialog(tag: String, current: String, download_url: String, size: int) -> void:
	var dialog := M3Dialog.new()
	dialog.title_text = "Update Available"
	var on_android := SystemManager.platform.is_android() and download_url != ""
	if on_android:
		var size_mb := "%.0f MB" % (size / (1024.0 * 1024.0)) if size > 0 else "unknown size"
		dialog.body_text = "Kyodai %s is available (you have %s).\n\nDownload (%s) and install now? Your library and settings carry over." % [tag, current, size_mb]
	else:
		dialog.body_text = "Kyodai %s is available (you have %s).\n\nDownload it from the GitHub release page?" % [tag, current]
	dialog.add_action("Later", func(): dialog.dismiss(), false)
	if on_android:
		dialog.add_action("Download & Install", func():
			# Gate before downloading: the install at the end needs the
			# grant. When blocked, the continuation resumes the download
			# automatically once the user grants - no manual retry.
			var start_download := func(): _download_update(tag, download_url, size)
			if SystemManager.platform.ensure_install_permission("this update", start_download):
				start_download.call()
			dialog.dismiss()
		, true)
	else:
		dialog.add_action("Download", func():
			OS.shell_open(RELEASE_PAGE_BASE + tag)
			dialog.dismiss()
		, true)
	M3Dialog.show_dialog(dialog)

# ============================================================================
# Android: download + install
# ============================================================================

static func _download_update(tag: String, download_url: String, size: int) -> void:
	FSM.make_dir_recursive(UPDATES_DIR)
	# Drop stale APKs from previous (cancelled or superseded) update attempts.
	for file_name in FSM.list_dir(UPDATES_DIR):
		if file_name.ends_with(".apk"):
			FSM.delete_file(FSM.join_paths(UPDATES_DIR, file_name))

	var destination := FSM.join_paths(UPDATES_DIR, "Kyodai-" + tag + ".apk")
	var item_id: String = SystemManager.download.queue_download(
		download_url,
		destination,
		"file",
		"Kyodai " + tag,
		false,  # auto_extract
		"",     # extract_dir
		null,   # game
		{},     # callbacks - the download_completed signal carries both outcomes
		0,      # romm_id
		true,   # delete_after_extract (unused - no extraction)
		false,  # suppress_notification: keep the progress snackbar visible
		size    # expected_file_size: known from the release, enables progress %
	)
	if item_id == "":
		_notify("Couldn't start the update download", SystemManager.notifications.Type.ERROR)
		return

	var on_completed: Callable
	on_completed = func(completed_id: String, success: bool, message: String):
		if completed_id != item_id:
			return
		SystemManager.download.download_completed.disconnect(on_completed)
		if success:
			print("[AppUpdateChecker] Update downloaded: " + destination)
			_install_apk(destination)
		else:
			push_warning("[AppUpdateChecker] Update download failed: " + message)
			_notify("Update download failed: " + message, SystemManager.notifications.Type.ERROR)
	SystemManager.download.download_completed.connect(on_completed)

## Hands the downloaded APK to the self-update installer. Rooted builds detach
## the replace and relaunch automatically; other devices use the system
## package-installer intent. The permission gate is skipped when root is usable.
static func _install_apk(apk_path: String) -> void:
	if not Engine.has_singleton("KyodaiBridge"):
		push_error("[AppUpdateChecker] KyodaiBridge plugin unavailable; falling back to browser")
		_notify("Couldn't start the installer - opening the release page instead", SystemManager.notifications.Type.WARNING)
		return
	var plugin = Engine.get_singleton("KyodaiBridge")

	# Android 8+ silently blocks installs until the user grants "Install
	# unknown apps" for Kyodai. The platform helper owns the explainer
	# dialog and the just-in-time grant lifecycle.
	if not SystemManager.platform.ensure_install_permission("this update"):
		return

	var absolute_path: String = FSM.resolve_path(apk_path, {"format": FSM.PathFormat.ABSOLUTE})
	var success = plugin.call("installApkSelfUpdate", absolute_path)
	if success == null:
		success = plugin.call("installApk", absolute_path)
	if success:
		SystemManager.platform.notify_install_started()
	else:
		push_error("[AppUpdateChecker] installApk failed for: " + absolute_path)
		_notify("Couldn't start the installer - the APK is saved at:\n" + apk_path, SystemManager.notifications.Type.ERROR)
