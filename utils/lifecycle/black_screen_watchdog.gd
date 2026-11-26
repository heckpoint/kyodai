extends Node
class_name BlackScreenWatchdog

## Last-resort recovery for the Android "black screen with a live engine"
## failure (observed on Odin 3, 0.8.7): after an activity recreate, the Godot
## surface can be lost without the engine ever presenting another frame. The
## SceneTree keeps running (input, vibration, sync all work) but the user
## sees permanent black, and soft relaunches (HOME/recents) just re-attach a
## new activity to the same broken process.
##
## Godot 4.7.2 fixes the cold-start half of this upstream (godot#121670 and
## follow-up godot#121917: swapchain creation racing surface destruction).
## This watchdog covers any remaining in-process variant by detecting
## "resumed + display on + rendering enabled, yet zero frames presented":
##   1. Force the root viewport back to UPDATE_ALWAYS (cheap, in-process).
##   2. If frames still don't advance, hard-restart the process through
##      KyodaiBridge.restartApp() so Android relaunches a clean instance.
## A persisted cooldown prevents restart loops: after one watchdog-initiated
## restart, further restarts are refused for COOLDOWN_MS and the watchdog
## disarms itself for the rest of the session.
##
## Android-only; on other platforms it frees itself immediately.

const CHECK_INTERVAL_MS: int = 1000
## Cold start runs long (shader prewarm, DB warm, theme walks) before frames
## flow steadily; never fire inside this window.
const STARTUP_GRACE_MS: int = 45000
## How long "visible but no new frames" must hold before stage 1.
const STALL_THRESHOLD_MS: int = 12000
## Extra time stage 1 gets to recover before the hard restart.
const RECOVERY_GRACE_MS: int = 6000
## Minimum time between watchdog-initiated process restarts.
const COOLDOWN_MS: int = 10 * 60 * 1000
const STATE_PATH: String = "user://black_screen_watchdog_state.json"

var _accum_ms: int = 0
var _created_ms: int = 0
var _last_frame_ms: int = 0
var _last_frames_drawn: int = 0
var _recovery_started_ms: int = -1
var _app_paused: bool = false
var _disarmed: bool = false


func _ready() -> void:
	if not OS.has_feature("android"):
		# Desktop minimize/hide legitimately stops frames; the failure mode
		# this guards against is Android-specific surface handling.
		queue_free()
		return
	_created_ms = Time.get_ticks_msec()
	_last_frame_ms = _created_ms
	_last_frames_drawn = Engine.get_frames_drawn()
	var last_restart := _read_last_restart_ms()
	if last_restart > 0:
		print("[BlackScreenWatchdog] armed; last watchdog restart was %d ms ago" % [Time.get_ticks_msec() - last_restart])
	else:
		print("[BlackScreenWatchdog] armed (no prior watchdog restarts)")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_app_paused = true
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_app_paused = false
		# Reset the stall clock on resume: surface re-creation may take a
		# moment, and this is exactly where the failure starts.
		_last_frame_ms = Time.get_ticks_msec()
		_last_frames_drawn = Engine.get_frames_drawn()
		_recovery_started_ms = -1


func _process(delta: float) -> void:
	if _disarmed:
		return
	_accum_ms += int(delta * 1000.0)
	if _accum_ms < CHECK_INTERVAL_MS:
		return
	_accum_ms = 0
	_check()


func _check() -> void:
	var now := Time.get_ticks_msec()
	var frames := Engine.get_frames_drawn()
	if frames != _last_frames_drawn:
		_last_frames_drawn = frames
		_last_frame_ms = now
		if _recovery_started_ms >= 0:
			print("[BlackScreenWatchdog] frames flowing again after viewport force-enable; restart avoided")
			_recovery_started_ms = -1
		return

	if not _eligible(now):
		# While ineligible (startup, paused, display off, intentional render
		# suspension) the absence of new frames is expected, so keep the
		# stall clock reset instead of accumulating false stall time.
		_last_frame_ms = now
		return

	var stalled_ms := now - _last_frame_ms
	if stalled_ms < STALL_THRESHOLD_MS:
		return

	if _recovery_started_ms < 0:
		_recovery_started_ms = now
		push_warning("[BlackScreenWatchdog] no frames presented for %d ms while visible; forcing root viewport UPDATE_ALWAYS" % [stalled_ms])
		var root_rid := get_tree().root.get_viewport_rid()
		RenderingServer.viewport_set_update_mode(root_rid, RenderingServer.VIEWPORT_UPDATE_ALWAYS)
		return

	if now - _recovery_started_ms >= RECOVERY_GRACE_MS:
		_restart_process(now, stalled_ms)


## True when the app should be presenting frames right now. All intentional
## no-render states (startup, app paused, display off, display-off render
## suspension) return false so they can never trip the watchdog.
func _eligible(now: int) -> bool:
	if now - _created_ms < STARTUP_GRACE_MS:
		return false
	if _app_paused:
		return false
	var root_rid := get_tree().root.get_viewport_rid()
	if RenderingServer.viewport_get_update_mode(root_rid) == RenderingServer.VIEWPORT_UPDATE_DISABLED:
		# main.gd only sets this for intentional display-off suspension.
		return false
	if Engine.has_singleton("KyodaiBridge"):
		# NB: call directly - has_method() is unreliable on the Java plugin bridge.
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin and not bool(plugin.isDisplayInteractive()):
			return false
	return true


func _restart_process(now: int, stalled_ms: int) -> void:
	var last_restart := _read_last_restart_ms()
	if last_restart > 0 and now - last_restart < COOLDOWN_MS:
		push_error("[BlackScreenWatchdog] still stalled after %d ms but restart cooldown has %d ms left; disarming to avoid a restart loop" % [stalled_ms, COOLDOWN_MS - (now - last_restart)])
		_disarmed = true
		return

	push_error("[BlackScreenWatchdog] no frames for %d ms despite viewport force-enable; restarting process" % [stalled_ms])
	# Persist before restarting so the next process sees the cooldown.
	_write_last_restart_ms(now)
	if Engine.has_singleton("KyodaiBridge"):
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin:
			# Schedules an alarm relaunch and kills this process; does not return.
			plugin.restartApp()
	# Fallback if the bridge is unavailable: quitting still lets the system
	# relaunch the HOME app on the next home press.
	get_tree().quit()


## Ticks (monotonic uptime) of the last watchdog-initiated restart, or 0.
func _read_last_restart_ms() -> int:
	if not FileAccess.file_exists(STATE_PATH):
		return 0
	var file := FileAccess.open(STATE_PATH, FileAccess.READ)
	if file == null:
		return 0
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return 0
	var last := int(parsed.get("last_restart_ticks_ms", 0))
	# Ticks reset on device reboot; a stored value ahead of the current
	# clock is from a previous boot and must not engage the cooldown.
	if last <= 0 or last > Time.get_ticks_msec():
		return 0
	return last


func _write_last_restart_ms(now: int) -> void:
	var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[BlackScreenWatchdog] could not persist restart timestamp: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({"last_restart_ticks_ms": now}))
