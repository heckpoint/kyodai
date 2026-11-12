extends Manager
class_name SyncSubManager

const DEBUG_LOG: bool = false

## Metadata providers RomM's sibling_roms view matches on, in RomM's own
## priority order (the gallery's group_by_meta_id coalesce order). The first
## provider with a non-null ID is a rom's canonical identity source; two roms
## in one sibling component with conflicting values there are different games.
const FOLD_ID_PRIORITY: Array[String] = ["igdb", "ss", "moby", "ra", "hasheous", "launchbox", "tgdb"]

var data_manager: Node

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CoverPalette = preload("res://utils/cover_palette.gd")

# Sync state machine
enum SyncState {
	IDLE,
	PRECHECK_DISABLED,      # Remove games from disabled platforms
	PLATFORM_ITERATING,     # Iterate through platforms
	PLATFORM_FETCHING,      # Fetch batch from current platform
	PLATFORM_PROCESSING,    # Process fetched batch
	PLATFORM_BATCHING,      # Fetch more batches if needed
	COMPLETING              # Final cleanup
}

var _sync_state: SyncState = SyncState.IDLE

## Total plays of the sync loading SFX before it cuts itself off.
const SYNC_LOOP_MAX_PLAYS: int = 4
var _sync_current_offset: int = 0           # Current batch offset
var _sync_current_total: int = 0            # Total games in current platform
var _sync_precalc_platform_total: int = 0   # Pre-calculated total for current platform
var _sync_current_synced: int = 0           # Games synced in current platform
var _sync_total_synced: int = 0             # Total synced across all platforms
var _sync_final_callback: Callable = Callable()

# Incremental sync state
var _sync_current_updated_after: String = ""  # updated_after timestamp for current platform

# Server-deletion reconciliation state (full syncs only)
var _sync_seen_ids: Array = []               # romm_ids seen in current platform's full sync
var _sync_platform_fully_enumerated: bool = false  # Current platform enumerated without errors
var _sync_current_window_completed: bool = false   # Incremental window completed (last_sync advanced)
var _sync_total_removed: int = 0             # Games removed by reconciliation this sync
# Above-threshold deletion batches held for user confirmation.
# platform_slug -> Array of doomed rows (romm_id, cover_url, is_master_entry, siblings)
var _pending_server_deletions: Dictionary = {}

# Progress tracking state
var _sync_current: int = 0
var _sync_total: int = 0
# Progress split: covers are work units too, but they're counted into
# _sync_total only when DISPATCHED (never when merely queued), and tracked
# separately so the notification can show games and covers distinctly.
# games_done = _sync_current - _sync_covers_done; games_total = _sync_total - _sync_covers_total.
var _sync_covers_total: int = 0
var _sync_covers_done: int = 0
var _sync_platform: String = ""
var _sync_platform_index: int = 0  # Current platform number (1-based)
var _sync_platform_count: int = 0  # Total platforms

# Tracks whether a sync is running (used to suppress per-card cover downloads)
var _sync_batch_mode: bool = false

# Cover URLs collected during sync for batch downloading on main thread
var _sync_covers_pending: Array[String] = []
var _sync_covers_pending_set: Dictionary = {}  # Set of URLs already in _sync_covers_pending
var _sync_covers_mutex: Mutex = Mutex.new()

# Tracks how many cover-dispatch batches are in flight so the sync thread can wait
# until every deferred main-thread download call has finished scheduling.
var _sync_covers_dispatched_count: int = 0
var _sync_covers_processed_count: int = 0

# Cover download outcome counters for end-of-phase diagnostics
var _sync_covers_cached_count: int = 0
var _sync_covers_downloaded_count: int = 0
var _sync_covers_failed_count: int = 0
# Covers skipped because the disk cache reached its headroom limit mid-sync
var _sync_covers_skipped_count: int = 0

# Interleaved cover dispatch: throttle and once-per-URL progress counting
const COVER_DISPATCH_INTERVAL_MS: int = 2000
# Max sync covers allowed in the download queue at once. Kept well below
# DownloadSubManager's pending cap so onscreen card loads (high priority)
# always have headroom and sync covers are never dropped by the queue limit.
const COVER_DISPATCH_MAX_IN_FLIGHT: int = 128
var _sync_last_cover_dispatch_ms: int = 0
var _sync_covers_counted_set: Dictionary = {}

# Every cover URL collected during this sync (pending, dispatched, or done)
var _sync_covers_seen_set: Dictionary = {}

# Max new covers to download this sync, derived from the cache size cap so we
# don't fetch covers that evict-on-insert would immediately swap out.
# Written on the main thread before the sync task starts; budget is only
# touched on the sync thread, so no locking is needed for either.
var _sync_cover_cap_bytes: int = 0
var _sync_covers_budget: int = 0

# Tracks cover downloads that are still in flight so the sync can wait for
# them before completing.
var _sync_pending_downloads: int = 0
var _sync_pending_downloads_mutex: Mutex = Mutex.new()

# Platform pre-calculation totals
var _precalc_platform_totals: Dictionary = {}  # platform_id -> total count

var _sync_notification_id: int = -1
var _removal_notification_id: int = -1

# Android sync foreground service tracking
var _sync_fg_service_active: bool = false


func _ready():
	data_manager = get_parent()


# ==================== SYNC THREAD SIGNAL WRAPPERS ====================
# These are queued from the sync thread to safely emit signals on the main thread

## Queue a main-thread hop from the sync thread. call_deferred from threads is
## unreliable on Android (silently dropped, which previously wedged sync
## completion), so route via the memory manager's mutex-protected callback
## queue, drained every frame on the main thread.
func _defer_on_main(method: StringName, args: Array = []) -> void:
	MemorySubManager.queue_main_thread_callback(Callable(self, method), args)

func _emit_sync_progress(percent: float, current: int, total: int):
	data_manager.sync_progress.emit(percent, current, total)


func _emit_sync_completed(success: bool, message: String):
	data_manager.sync_completed.emit(success, message)


# Wrapper for calling _sync_final_callback via _defer_on_main
func _invoke_sync_callback(success: bool, message: String, count: int, error_code: int):
	if _sync_final_callback.is_valid():
		_sync_final_callback.call(success, message, count, error_code)


## Generic helper to wait for an async callback.
## Polls at 10ms intervals with a fast-path exit to minimize latency.
func _wait_for_async(task_func: Callable, timeout_ms: int = 60000):
	var state = {"completed": false, "result": null}

	var wrapped_callback = func(result = null):
		state.result = result
		state.completed = true

	task_func.call(wrapped_callback)

	# Fast-path: if callback fired synchronously, return immediately
	if state.completed:
		return state.result

	# Poll at 10ms intervals (matching pre-refactor latency)
	var elapsed = 0
	var check_interval = 10  # 10ms
	while not state.completed and elapsed < timeout_ms:
		if MemorySubManager.is_shutting_down():
			return null
		OS.delay_msec(check_interval)
		elapsed += check_interval

	return state.result if state.completed else null


## Delay before the single retry of a transient fetch failure during sync.
const SYNC_FETCH_RETRY_DELAY_MS := 1500

## Fetch errors that are usually transient (server wedged/restarting, network
## blip) and therefore worth one retry before abandoning the platform until
## the next sync. Anything else (auth, 404, parse errors) fails immediately.
const TRANSIENT_FETCH_ERROR_PREFIXES := [
	"HTTP error: 0",
	"Connection timeout",
	"Not connected",
	"Response timeout",
	"Response stalled",
	"Failed to connect",
	"Failed to make request",
]

func _is_transient_fetch_error(error: String) -> bool:
	for prefix in TRANSIENT_FETCH_ERROR_PREFIXES:
		if error.begins_with(prefix):
			return true
	return false


# ==================== ANDROID SYNC FOREGROUND SERVICE ====================

func _start_sync_fg_service(platform_name: String = "Game Library", current: int = 0, total: int = 0) -> void:
	print("[SyncManager] Starting sync foreground service: %s (%d/%d)" % [platform_name, current, total])
	if SystemManager.platform.start_sync_foreground_service(platform_name, current, total):
		_sync_fg_service_active = true


var _fg_service_last_update_ms := 0
var _fg_service_last_percent := -1
var _fg_service_last_platform := ""

func _update_sync_fg_service(platform_name: String = "", current: int = 0, total: int = 0) -> void:
	if not _sync_fg_service_active:
		return
	# Throttle: batch progress can fire several times per second, and every
	# update costs a service intent + notification rebuild on Android.
	var service_name = platform_name if platform_name != "" else _sync_platform
	var percent := int(current * 100.0 / max(total, 1))
	var now_ms := Time.get_ticks_msec()
	if percent == _fg_service_last_percent and service_name == _fg_service_last_platform and now_ms - _fg_service_last_update_ms < 500:
		return
	_fg_service_last_percent = percent
	_fg_service_last_platform = service_name
	_fg_service_last_update_ms = now_ms
	SystemManager.platform.update_sync_foreground_service(service_name, current, total)


func _stop_sync_fg_service() -> void:
	if not _sync_fg_service_active:
		return
	print("[SyncManager] Stopping sync foreground service")
	if SystemManager.platform.stop_sync_foreground_service():
		_sync_fg_service_active = false


# ==================== REMOVAL PROGRESS NOTIFICATION ====================

func _show_removal_notification(total: int) -> void:
	_removal_notification_id = SystemManager.notifications.show_notification(
		"Removing %d platforms..." % total,
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true,  # pulsing
		true  # pinned
	)


func _update_removal_notification(current: int, total: int, slug: String) -> void:
	if _removal_notification_id != -1:
		SystemManager.notifications.update_notification_text(
			_removal_notification_id,
			"Removing platform %d/%d: %s" % [current, total, slug]
		)


func _dismiss_removal_notification() -> void:
	if _removal_notification_id != -1:
		SystemManager.notifications.dismiss_notification(_removal_notification_id)
		_removal_notification_id = -1


# ==================== SYNC (ITERATIVE STATE MACHINE) ====================

## Loop predicate for the sync loading SFX: keeps playing until the sync
## state machine returns to IDLE (completion, failure, or teardown).
func _is_sync_active() -> bool:
	return _sync_state != SyncState.IDLE

func sync_enabled_platforms(callback: Callable = Callable(), force_full_sync: bool = false) -> void:
	if DEBUG_LOG: print("[Sync] ==========================================")
	print("[Sync] sync_enabled_platforms called")
	if DEBUG_LOG: print("[Sync] Current state: %s" % get_sync_state_name())
	if DEBUG_LOG: print("[Sync] Force full sync: %s" % force_full_sync)
	if DEBUG_LOG: print("[Sync] Callback valid: %s" % callback.is_valid())
	if DEBUG_LOG: print("[Sync] ==========================================")

	# Dismiss any existing sync notification from previous syncs
	if _sync_notification_id != -1:
		if DEBUG_LOG: print("[Sync] Dismissing existing notification ID: %d" % _sync_notification_id)
		SystemManager.notifications.dismiss_notification(_sync_notification_id)
		_sync_notification_id = -1

	if not data_manager.database.is_database_ready():
		var err_msg = "Database initialization failed. App cannot function without database access." if data_manager.database.is_database_init_failed() else "Database not ready"
		print("[Sync] ERROR: " + err_msg)
		if callback.is_valid():
			callback.call(false, err_msg, 0, 0)
		return

	# Repair any schema drift before syncing. A stale DB schema makes every
	# batched insert fail and roll back silently (missing-column writes).
	data_manager.database.ensure_schema_alignment()

	# Re-entrancy guard: a duplicated confirm/input event (or a second caller)
	# must not queue another full sync on top of a running one. _sync_state is
	# set synchronously below, so back-to-back calls in adjacent frames are safe.
	if _sync_state != SyncState.IDLE:
		print("[Sync] Sync already in progress (state=%s) - ignoring duplicate call" % get_sync_state_name())
		SystemManager.notifications.show_notification("Sync already in progress", SystemManager.notifications.Type.INFO)
		if callback.is_valid():
			callback.call(false, "Sync already in progress", 0, 0)
		return

	# Loop the loading SFX while the sync runs (stops the moment the sync
	# leaves IDLE-adjacent states; capped so long syncs don't loop forever).
	# Placed after the guards above so no-op syncs stay silent.
	if SystemManager.audio:
		SystemManager.audio.play_loop_while("loading", _is_sync_active, 0.0, SYNC_LOOP_MAX_PLAYS)

	# Reset sync state
	_sync_current = 0
	_sync_total = 0
	_sync_covers_total = 0
	_sync_covers_done = 0
	_sync_platform = ""
	_sync_state = SyncState.PRECHECK_DISABLED
	_sync_current_offset = 0
	_sync_current_total = 0
	_sync_current_synced = 0
	_sync_total_synced = 0
	_sync_final_callback = callback
	_sync_current_updated_after = ""
	_sync_seen_ids = []
	_sync_platform_fully_enumerated = false
	_sync_total_removed = 0
	# A background cover flush from a previous sync must not interfere with
	# this sync's queue (which is reset below).
	if _cover_flush_timer != null:
		_cover_flush_timer.stop()
	# A fresh enumeration supersedes any deletion batches held from a
	# previous sync - the server state they were validated against is stale.
	_pending_server_deletions.clear()

	# Reset cover download tracking
	_sync_covers_mutex.lock()
	_sync_covers_pending.clear()
	_sync_covers_pending_set.clear()
	_sync_covers_dispatched_count = 0
	_sync_covers_processed_count = 0
	_sync_covers_cached_count = 0
	_sync_covers_downloaded_count = 0
	_sync_covers_failed_count = 0
	_sync_covers_skipped_count = 0
	_sync_last_cover_dispatch_ms = 0
	_sync_covers_counted_set.clear()
	_sync_covers_seen_set.clear()
	_sync_covers_mutex.unlock()
	_sync_pending_downloads_mutex.lock()
	_sync_pending_downloads = 0
	_sync_pending_downloads_mutex.unlock()

	# Read the cap on the main thread; the sync thread must not touch autoloads.
	# The budget itself is computed on the sync thread once it starts.
	_sync_cover_cap_bytes = data_manager.cover.get_max_cache_bytes()
	_sync_covers_budget = 0

	var enabled = data_manager.database.get_enabled_platforms()
	print("[Sync] Enabled platforms: %d" % enabled.size())

	# Get all platforms that currently have games in the database
	var db_platforms = data_manager.database.get_db_platform_slugs()
	print("[Sync] Platforms with games in DB: %d" % db_platforms.size())

	var enabled_slugs = enabled.map(func(p): return p.slug)

	# Find platforms that have games but are now disabled
	var disabled_platforms: Array[String] = []
	for slug in db_platforms:
		if not slug in enabled_slugs:
			disabled_platforms.append(slug)

	print("[Sync] Platforms to disable: %d" % disabled_platforms.size())

	# Queue the entire sync to the background sync thread
	# This allows sync to continue even when the app is backgrounded on Android
	print("[Sync] Queuing sync to background thread...")
	MemorySubManager.queue_sync_task(
		func():
			_run_sync_threaded(enabled, disabled_platforms, force_full_sync)
			return true,
		func(_result):
			if DEBUG_LOG: print("[Sync] Sync thread task completed")
	)


func _run_sync_threaded(enabled_platforms: Array, disabled_platforms: Array[String], force_full_sync: bool):
	"""Main sync worker that runs on the sync thread."""
	print("[SyncThread] Sync started on background thread")

	# 1. Remove disabled platforms
	if disabled_platforms.size() > 0:
		if DEBUG_LOG: print("[SyncThread] Removing %d disabled platforms..." % disabled_platforms.size())
		_defer_on_main("_show_removal_notification", [disabled_platforms.size()])
		for i in range(disabled_platforms.size()):
			var slug = disabled_platforms[i]
			if DEBUG_LOG: print("[SyncThread] Removing platform %d/%d: %s" % [i + 1, disabled_platforms.size(), slug])
			_defer_on_main("_update_removal_notification", [i + 1, disabled_platforms.size(), slug])
			_remove_platform_sync_threaded(slug)
			# Small yield to prevent blocking other sync thread tasks
			OS.delay_usec(1000)
		_defer_on_main("_dismiss_removal_notification")

	# 2. Check if there are platforms to sync
	if enabled_platforms.size() == 0:
		if DEBUG_LOG: print("[SyncThread] No platforms enabled, completing immediately")
		_sync_state = SyncState.IDLE  # Entry guard keys on this; must reset on every exit
		_defer_on_main("_emit_sync_completed", [true, "No platforms enabled"])
		_defer_on_main("_invoke_sync_callback", [true, "", 0, 0])
		return

	# 3. Start batch mode and foreground service on main thread
	_defer_on_main("_start_sync_batch_mode")
	_defer_on_main("_start_sync_fg_service", ["Game Library", 0, 0])

	# 4. Start sync immediately - skip pre-calculation to save 20+ seconds
	# We'll discover per-platform totals as we fetch the first batch of each
	print("[SyncThread] Starting sync of %d platforms..." % enabled_platforms.size())
	_sync_state = SyncState.PLATFORM_ITERATING
	_sync_platform_count = enabled_platforms.size()
	_sync_current = 0
	_sync_total = 0  # Will accumulate as we discover totals
	_sync_covers_total = 0
	_sync_covers_done = 0
	_sync_total_synced = 0

	# Start sync notification on main thread
	_defer_on_main("_show_sync_notification")

	# Pre-calculate totals in background without blocking
	# Fire off all pre-calc requests but don't wait for them
	var platform_totals_discovered = 0
	for platform in enabled_platforms:
		var platform_id = str(platform.id)
		var result = SystemManager.network.fetch_games_sync(platform_id, 0, 1)
		if result.success and result.data is Dictionary:
			var platform_total = int(result.data.get("total", 0))
			_precalc_platform_totals[platform_id] = platform_total
			_sync_total += platform_total
			platform_totals_discovered += 1
		# Don't block - just keep going
		OS.delay_usec(500)

	if DEBUG_LOG: print("[SyncThread] Discovered %d/%d platform totals, ~%d total games" % [platform_totals_discovered, enabled_platforms.size(), _sync_total])

	# Size the cover download budget from the cache cap before any covers are
	# collected: downloading past the cap only feeds evict-on-insert churn.
	_sync_covers_budget = _compute_cover_download_budget(_sync_cover_cap_bytes)
	if _sync_cover_cap_bytes >= CoverSubManager.UNLIMITED_CACHE_BYTES:
		print("[SyncThread] Cover download budget: unlimited (cache cap is Unlimited)")
	else:
		print("[SyncThread] Cover download budget: %d new covers" % _sync_covers_budget)

	# Queue backfill covers (library games whose image files were never
	# cached) up front so they download through the same interleaved dispatch
	# as per-batch covers instead of in a separate end-of-sync phase.
	_queue_backfill_covers()
	# Start palette backfill alongside network sync. Extraction is asynchronous
	# and deliberately not drained at completion, so a large legacy backlog
	# cannot add a long tail to an otherwise finished library sync.
	_queue_backfill_cover_palettes()

	for platform_idx in range(enabled_platforms.size()):
		var platform = enabled_platforms[platform_idx]
		_sync_platform = platform.name
		_sync_platform_index = platform_idx + 1

		# Look up platform ID
		var platform_id = platform.id
		if platform_id == 0 and data_manager.database.is_database_ready():
			platform_id = _lookup_platform_id_sync(platform.slug)

		if platform_id == 0:
			print("[SyncThread] Skipping platform '%s' - no ID found" % platform.name)
			continue

		# Update foreground service
		_defer_on_main("_update_sync_fg_service", [platform.name, _sync_current, _sync_total])

		# Determine sync mode
		_sync_current_updated_after = ""
		if not force_full_sync:
			var last_sync = _get_last_sync_time_sync(platform.slug)
			if last_sync != "":
				var last_sync_time = DataManager.parse_iso_timestamp(last_sync)
				var one_week_ago = Time.get_unix_time_from_system() - (7 * 24 * 60 * 60)
				if last_sync_time > one_week_ago:
					_sync_current_updated_after = last_sync
					if DEBUG_LOG: print("[SyncThread] Platform '%s' - incremental sync (after: %s)" % [platform.name, last_sync])
				else:
					if DEBUG_LOG: print("[SyncThread] Platform '%s' - full sync (last sync over a week ago)" % platform.name)
			else:
				if DEBUG_LOG: print("[SyncThread] Platform '%s' - full sync (no previous sync)" % platform.name)
		else:
			if DEBUG_LOG: print("[SyncThread] Platform '%s' - force full sync" % platform.name)

		# Fetch and process this platform
		_sync_state = SyncState.PLATFORM_FETCHING
		_sync_current_offset = 0
		_sync_current_synced = 0
		_sync_seen_ids = []
		_sync_platform_fully_enumerated = false
		_sync_current_window_completed = false
		_sync_precalc_platform_total = _precalc_platform_totals.get(str(platform_id), 0)

		var platform_complete = false
		var platform_batch_count = 0
		var batch_size = 250 if not SystemManager.platform.is_android() else 150

		# Parallel fetch state
		var parallel_fetch = {
			"thread": null,
			"mutex": Mutex.new(),
			"result": null,
			"completed": false,
			"offset": 0
		}

		while not platform_complete:

			# Fetch batch (or wait for parallel fetch)
			var fetch_retried := false
			var fetch_start = Time.get_ticks_msec()
			var result = null
			var fetch_time = 0

			if parallel_fetch.completed and parallel_fetch.offset == _sync_current_offset:
				# Use pre-fetched result
				parallel_fetch.mutex.lock()
				result = parallel_fetch.result
				parallel_fetch.completed = false
				parallel_fetch.result = null
				parallel_fetch.mutex.unlock()
				fetch_time = Time.get_ticks_msec() - fetch_start
				if DEBUG_LOG: print("[SyncThread] Using pre-fetched batch at offset %d" % _sync_current_offset)
			else:
				# Fetch synchronously
				result = SystemManager.network.fetch_games_sync(str(platform_id), _sync_current_offset, batch_size, _sync_current_updated_after)
				fetch_time = Time.get_ticks_msec() - fetch_start

			if not result.success and not fetch_retried and _is_transient_fetch_error(result.error):
				# Transient failure (server wedged/restarting, network blip):
				# retry once before abandoning the platform until the next sync.
				fetch_retried = true
				print("[SyncThread] Transient fetch error on platform '%s': %s - retrying once in %.1fs" % [platform.name, result.error, SYNC_FETCH_RETRY_DELAY_MS / 1000.0])
				OS.delay_msec(SYNC_FETCH_RETRY_DELAY_MS)
				result = SystemManager.network.fetch_games_sync(str(platform_id), _sync_current_offset, batch_size, _sync_current_updated_after)
				fetch_time = Time.get_ticks_msec() - fetch_start

			if not result.success:
				# Do NOT update last_sync here: the failed window must be retried
				# by the next sync instead of being permanently skipped.
				print("[SyncThread] Error fetching platform '%s': %s (fetch took %dms) - last_sync NOT updated" % [platform.name, result.error, fetch_time])
				platform_complete = true
				continue

			var total = int(result.data.get("total", 0))
			var items = result.data.get("items", [])

			if total == 0 or items.size() == 0:
				if _sync_current_offset == 0:
					# Nothing changed (incremental) or platform is genuinely empty:
					# safe to advance the sync window.
					if _sync_current_updated_after != "":
						_sync_current += _sync_precalc_platform_total
						_defer_on_main("_update_sync_fg_service", [platform.name, _sync_current, _sync_total])
					else:
						# Full sync with zero server games is a complete
						# enumeration: every local row for this platform is stale.
						_sync_platform_fully_enumerated = true

					var current_time = Time.get_datetime_string_from_system(true)
					_set_last_sync_time_sync(platform.slug, current_time)
					_sync_current_window_completed = true
				else:
					# Paged past the end with games still unprocessed (a batch
					# failed or the server total drifted): leave last_sync alone
					# so the next sync retries the full window.
					if DEBUG_LOG: print("[SyncThread] Platform '%s' ended early at offset %d (%d/%d synced) - last_sync NOT updated" % [platform.name, _sync_current_offset, _sync_current_synced, _sync_current_total])
				platform_complete = true
				continue

			_sync_current_total = total

			# Full syncs enumerate every server-side romm_id for this platform;
			# track them so reconciliation can delete locally-stale rows after
			# the platform completes. Incremental syncs can't see deletions.
			if _sync_current_updated_after == "":
				for item in items:
					if item is Dictionary:
						_sync_seen_ids.append(int(item.get("id", 0)))

			# Start fetching next batch in parallel while we process this one
			var next_offset = _sync_current_offset + batch_size
			if next_offset < total and not platform_complete:
				parallel_fetch.offset = next_offset
				parallel_fetch.completed = false
				parallel_fetch.result = null

				parallel_fetch.thread = Thread.new()
				parallel_fetch.thread.start(func():
					var next_result = SystemManager.network.fetch_games_sync(str(platform_id), next_offset, batch_size, _sync_current_updated_after)
					parallel_fetch.mutex.lock()
					parallel_fetch.result = next_result
					parallel_fetch.completed = true
					parallel_fetch.mutex.unlock()
				)

			# Process batch with incremental progress
			_sync_state = SyncState.PLATFORM_PROCESSING
			var batch_start = Time.get_ticks_msec()
			var succeeded = _process_batch_sync(items, platform.slug, true)
			var batch_time = Time.get_ticks_msec() - batch_start
			_sync_current_synced += succeeded
			_sync_total_synced += succeeded
			_sync_current += succeeded
			platform_batch_count += 1

			# Update progress
			_defer_on_main("_update_sync_fg_service", [platform.name, _sync_current, _sync_total])
			var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
			_defer_on_main("_emit_sync_progress", [progress_pct * 0.01, _sync_current, _sync_total])

			print("[SyncThread] Progress: %d/%d games (%d%%) | Platform %d/%d: %s | Batch %d: fetch=%dms process=%dms" % [
				_sync_current, _sync_total, int(progress_pct),
				_sync_platform_index, _sync_platform_count, platform.name,
				platform_batch_count, fetch_time, batch_time
			])

			# Wait for parallel fetch to finish before next iteration
			if parallel_fetch.thread != null and parallel_fetch.thread.is_alive():
				parallel_fetch.thread.wait_to_finish()

			if _sync_current_synced >= _sync_current_total:
				var current_time = Time.get_datetime_string_from_system(true)
				_set_last_sync_time_sync(platform.slug, current_time)
				_sync_platform_fully_enumerated = true
				_sync_current_window_completed = true
				platform_complete = true
			else:
				_sync_current_offset += batch_size
				_sync_state = SyncState.PLATFORM_BATCHING
				OS.delay_usec(10000)  # 10ms yield to prevent blocking and reduce CPU

		if DEBUG_LOG: print("[SyncThread] Platform '%s' complete (%d batches, %d/%d games)" % [platform.name, platform_batch_count, _sync_current_synced, _sync_current_total])

		# Server-deletion reconciliation. Full syncs reconcile directly from
		# their complete enumeration. Incremental syncs can't see deletions in
		# their updated_after window, so they reconcile via a cheap server-total
		# tripwire (only enumerating all ids when counts disagree).
		if _sync_current_updated_after == "" and _sync_platform_fully_enumerated:
			_sync_total_removed += _reconcile_platform_deletions(platform.slug)
		elif _sync_current_updated_after != "" and _sync_current_window_completed:
			_sync_total_removed += _reconcile_platform_deletions_count_checked(platform.slug, platform_id)

	# 7. Drain any covers still queued or in flight from the interleaved
	#    dispatch. Silent (no visible phase) and timeout-guarded so a stalled
	#    download can never block sync completion.
	_wait_for_all_cover_downloads()
	# Catch covers downloaded by this sync plus any cache files that arrived
	# since the startup pass. Remaining palette work continues in background.
	_queue_backfill_cover_palettes()

	# 8. Complete sync - defer ALL UI work to main thread
	print("[SyncThread] All platforms complete, finishing...")
	_sync_state = SyncState.COMPLETING

	# Get cache stats before clearing
	var cache_stats = SystemManager.network.get_and_reset_cache_stats()
	var games_from_cache = cache_stats.get("games_from_cache", 0)

	print("[SyncThread] Sync complete: %d games synced, %d from cache, %d removed" % [_sync_total_synced, games_from_cache, _sync_total_removed])

	# Defer the entire completion sequence to main thread
	# This avoids calling scene-tree methods from the sync thread
	_defer_on_main("_complete_sync_on_main_thread", [_sync_total_synced, games_from_cache, _sync_total_removed])


func _complete_sync_on_main_thread(total_synced: int, games_from_cache: int, total_removed: int = 0):
	"""Complete sync on main thread - safe for UI operations."""
	print("[Sync] Completing on main thread...")

	# Ensure the progress notification reaches 100% so it auto-dismisses.
	if _sync_total == 0:
		_sync_total = 1
	_sync_current = _sync_total

	# Clean up
	_stop_sync_batch_mode()
	_stop_sync_fg_service()

	# Covers still queued when the drain hit its timeout keep downloading in
	# the background instead of being dropped; they no longer count toward
	# sync progress.
	_start_pending_cover_flush()

	# Apply cover folding and emit completion
	data_manager.cover.apply_cover_folding_to_database(func(folded_count: int):
		var completion_msg = "Synced " + str(total_synced) + " games"
		if total_removed > 0:
			completion_msg += ", removed " + str(total_removed) + " deleted"
		if games_from_cache > 0:
			completion_msg += " (" + str(games_from_cache) + " checked from cache"
			if folded_count > 0:
				completion_msg += ", " + str(folded_count) + " folded by cover"
			completion_msg += ")"
		elif folded_count > 0:
			completion_msg += " (" + str(folded_count) + " folded by cover)"

		_sync_state = SyncState.IDLE
		data_manager.sync_completed.emit(true, completion_msg)
		_invoke_sync_callback(true, completion_msg, total_synced, 0)

		# Reconcile downloaded state with the files actually on disk after every
		# library sync (clears rows whose files vanished). Owned by the data
		# layer so it runs no matter which view initiated the sync.
		data_manager.scan_for_downloaded_games()

		# Collections/favorites otherwise only sync at startup; mirror that
		# here so favorites and collection membership stay current after a
		# library sync. Views refresh via collections_synced when it lands.
		if SystemManager.network and SystemManager.network.is_online():
			data_manager.sync_collections(func(_ok: bool, _msg: String):
				data_manager.user_props.sync_favourites()
			)
	)


func _compute_cover_download_budget(cap_bytes: int) -> int:
	"""Sync thread: estimate how many new covers fit under the cache size cap,
	using the average size of already-cached covers (or a flat estimate when
	the cache is empty). Raw DirAccess/FileAccess because FSM reaches
	autoloads unsafely from worker threads."""
	var total_bytes := 0
	var file_count := 0
	var dir := DirAccess.open(CoverSubManager.CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				var file := FileAccess.open(CoverSubManager.CACHE_FOLDER + file_name, FileAccess.READ)
				if file:
					total_bytes += file.get_length()
					file.close()
					file_count += 1
			file_name = dir.get_next()
		dir.list_dir_end()
	var avg_size: int = int(total_bytes / float(file_count)) if file_count > 0 else CoverSubManager.ESTIMATED_COVER_BYTES
	if avg_size <= 0:
		avg_size = CoverSubManager.ESTIMATED_COVER_BYTES
	# Prefetch gets half the free space; the rest stays as headroom for covers
	# the user browses to during/after the sync, so prefetch can't fill the
	# cache and immediately start evicting what the user is looking at.
	return maxi(0, int((cap_bytes - total_bytes) / 2.0 / avg_size))


func _queue_backfill_covers() -> void:
	"""Sync thread: queue covers for games already in the library whose image
	files are not cached on disk (games this sync's batches may not touch).
	Ranked by favorites, then recently played, then recently updated (ISO text
	timestamps sort chronologically; empty strings sink under DESC) so a tight
	budget goes to the covers the user is most likely to see. Flows through
	the same interleaved dispatch as per-batch covers; gated on the budget."""
	if not data_manager.database.is_database_ready():
		return

	var rows = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.query_array(
					"""SELECT cover_url, MAX(is_favorite) AS fav,
						MAX(COALESCE(last_played, '')) AS lp,
						MAX(COALESCE(last_updated, '')) AS lu
					FROM games WHERE cover_url != '' AND cover_url IS NOT NULL
					GROUP BY cover_url
					ORDER BY fav DESC, lp DESC, lu DESC, cover_url ASC"""
				),
			func(result):
				# null when the queue dropped the task (overflow); pass through
				# so the outer null check can bail cleanly.
				callback.call(result if result is Array else null)
		)
	, 120000)

	if rows == null:
		return

	_sync_covers_mutex.lock()
	var queued := 0
	for row in rows:
		if _sync_covers_budget <= 0:
			break
		var url = row.get("cover_url", "")
		if url == "" or not url.begins_with("http"):
			continue
		if _sync_covers_seen_set.has(url):
			continue
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			continue
		_sync_covers_seen_set[url] = true
		_sync_covers_budget -= 1
		# Not counted into _sync_total here: covers join the progress total
		# when DISPATCHED, so never-dispatched queue leftovers can't inflate it.
		_sync_covers_pending.append(url)
		_sync_covers_pending_set[url] = true
		queued += 1
	_sync_covers_mutex.unlock()

	if queued > 0:
		if DEBUG_LOG: print("[SyncThread] Queued %d backfill covers for interleaved download" % queued)
		_dispatch_covers_to_main_thread()


func _queue_backfill_cover_palettes() -> void:
	"""Sync thread: register missing/outdated palette candidates and schedule
	the already-cached subset. File checks stay off the main thread. Extraction
	continues asynchronously after sync rather than adding a backlog drain."""
	if not data_manager.database.is_database_ready():
		return

	var rows = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.query_array(
					"""SELECT cover_url, MAX(is_favorite) AS fav,
						MAX(COALESCE(last_played, '')) AS lp,
						MAX(COALESCE(last_updated, '')) AS lu
					FROM games
					WHERE cover_url != '' AND cover_url IS NOT NULL
						AND (COALESCE(cover_colors_version, 0) < ?
							OR COALESCE(cover_primary_color, '') = ''
							OR COALESCE(cover_secondary_color, '') = ''
							OR COALESCE(cover_tertiary_color, '') = '')
					GROUP BY cover_url
					ORDER BY fav DESC, lp DESC, lu DESC, cover_url ASC""",
					[CoverPalette.ALGORITHM_VERSION]
				),
			func(result):
				callback.call(result if result is Array else null)
		)
	, 120000)
	if rows == null:
		return

	var candidates: Array[String] = []
	var cached: Array[String] = []
	for row in rows:
		var url := str(row.get("cover_url", ""))
		if url.is_empty() or not url.begins_with("http"):
			continue
		candidates.append(url)
		if FSM.file_exists(data_manager.cover.get_cached_image_path(url)):
			cached.append(url)
	if not candidates.is_empty():
		_defer_on_main("_queue_cover_palettes_on_main_thread", [candidates, cached])


func _queue_cover_palettes_on_main_thread(candidates: Array, cached: Array, invalidate_inflight: bool = false) -> void:
	data_manager.cover.register_palette_candidates(candidates, invalidate_inflight)
	data_manager.cover.queue_palette_extractions(cached, true)


const COVER_PROGRESS_EVERY: int = 5

func _on_cover_processed() -> void:
	"""Called on the main thread when a cover has been processed by the worker."""
	_sync_current += 1
	_sync_covers_done += 1
	if _sync_current % COVER_PROGRESS_EVERY == 0 or _sync_current == _sync_total:
		var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
		_emit_sync_progress(progress_pct * 0.01, _sync_current, _sync_total)
		_update_sync_fg_service(_sync_platform, _sync_current, _sync_total)


# Upper bound on the end-of-sync cover drain: a download stalled by an OS
# suspend must never wedge sync completion. Stragglers finish in the
# background after sync_completed fires.
const COVER_DRAIN_TIMEOUT_MS: int = 60000

## Repeating main-thread timer that keeps dispatching leftover queued covers
## after sync completion (drain timeout is a safety bound, not a drop).
var _cover_flush_timer: Timer = null


func _start_pending_cover_flush() -> void:
	"""Main thread: if covers are still queued after the drain, keep
	dispatching them in the background until the queue empties."""
	_sync_covers_mutex.lock()
	var pending := _sync_covers_pending.size()
	_sync_covers_mutex.unlock()
	if pending == 0:
		return
	print("[Sync] %d cover(s) still queued after sync - downloading in the background" % pending)
	if _cover_flush_timer == null:
		_cover_flush_timer = Timer.new()
		_cover_flush_timer.wait_time = 2.0
		_cover_flush_timer.timeout.connect(_on_cover_flush_tick)
		add_child(_cover_flush_timer)
	_cover_flush_timer.start()


func _on_cover_flush_tick() -> void:
	if MemorySubManager.is_shutting_down():
		_cover_flush_timer.stop()
		return
	_sync_covers_mutex.lock()
	var pending := _sync_covers_pending.size()
	_sync_covers_mutex.unlock()
	if pending == 0:
		_cover_flush_timer.stop()
		return
	# count_progress=false: the sync's progress notification has completed;
	# these covers must not touch its counters.
	_dispatch_covers_to_main_thread(false)

func _wait_for_all_cover_downloads() -> void:
	"""Block the sync thread until every queued cover download has settled.

	Silent safety net only: interleaved dispatch downloads covers during the
	sync, so this just drains the in-flight tail. Polls with a timeout
	(Semaphore has no timed wait) so a stalled download can't block forever.
	"""
	if DEBUG_LOG: print("[SyncThread] Draining remaining cover downloads...")
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < COVER_DRAIN_TIMEOUT_MS:
		if MemorySubManager.is_shutting_down():
			return
		_sync_covers_mutex.lock()
		var still_pending := _sync_covers_pending.size() > 0
		var dispatched := _sync_covers_dispatched_count
		var processed := _sync_covers_processed_count
		_sync_covers_mutex.unlock()
		if still_pending:
			# Self-throttled: no-op while the in-flight cap is reached.
			_dispatch_covers_to_main_thread()
			OS.delay_msec(50)
			continue
		if processed < dispatched:
			# A deferred main-thread dispatch call hasn't finished scheduling.
			OS.delay_msec(50)
			continue
		_sync_pending_downloads_mutex.lock()
		var download_count := _sync_pending_downloads
		_sync_pending_downloads_mutex.unlock()
		if download_count == 0:
			break
		OS.delay_msec(50)

	_sync_pending_downloads_mutex.lock()
	var remaining := _sync_pending_downloads
	_sync_pending_downloads_mutex.unlock()
	if remaining > 0:
		push_warning("[SyncThread] Cover drain timed out with %d downloads still in flight; they finish after sync completes" % remaining)
	print("[SyncThread] Cover downloads: %d cached, %d downloaded, %d skipped (cache full), %d FAILED" % [_sync_covers_cached_count, _sync_covers_downloaded_count, _sync_covers_skipped_count, _sync_covers_failed_count])


func _dispatch_covers_to_main_thread(count_progress: bool = true):
	"""Dispatch collected cover URLs to main thread for async download.

	Self-throttles to COVER_DISPATCH_MAX_IN_FLIGHT outstanding downloads so a
	large backfill can't flood the download queue past its pending cap and get
	covers silently dropped. Leftover URLs stay pending for the next dispatch
	once in-flight downloads settle.

	Dispatched covers join the progress total here (not at queue time) so
	never-dispatched leftovers can't inflate it. count_progress is false only
	for the post-sync background flush, which runs after the progress
	notification has completed."""
	_sync_pending_downloads_mutex.lock()
	var headroom: int = COVER_DISPATCH_MAX_IN_FLIGHT - _sync_pending_downloads
	_sync_pending_downloads_mutex.unlock()
	if headroom <= 0:
		return

	_sync_covers_mutex.lock()
	if _sync_covers_pending.is_empty():
		_sync_covers_mutex.unlock()
		return

	var take: int = mini(headroom, _sync_covers_pending.size())
	var urls: Array[String] = []
	for i in range(take):
		var url := _sync_covers_pending[i]
		urls.append(url)
		_sync_covers_pending_set.erase(url)
	_sync_covers_pending = _sync_covers_pending.slice(take)
	_sync_covers_dispatched_count += 1
	if count_progress:
		_sync_total += take
		_sync_covers_total += take
	_sync_last_cover_dispatch_ms = Time.get_ticks_msec()
	_sync_covers_mutex.unlock()

	# The post-sync flush must not touch progress counters.
	var on_processed: Callable = _on_cover_processed if count_progress else Callable()
	_defer_on_main("_download_covers_on_main_thread", [urls, on_processed])
	if DEBUG_LOG: print("[SyncThread] Cover dispatch: %d urls (cached=%d downloaded=%d failed=%d pending_dl=%d)" % [urls.size(), _sync_covers_cached_count, _sync_covers_downloaded_count, _sync_covers_failed_count, _sync_pending_downloads])


func _download_covers_on_main_thread(urls: Array[String], on_complete: Callable = Callable()):
	"""Download covers on main thread using existing async infrastructure.

	Called via _defer_on_main from sync thread. Queues each cover to
	SystemManager.download for parallel async download.
	"""

	for url in urls:
		var counted_cb := _make_cover_counted_callback(url, on_complete)
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			# Already cached: no network wait.
			_sync_covers_cached_count += 1
			data_manager.cover.queue_downloaded_cover_palette(url)
			counted_cb.call()
			continue

		# Don't sink covers the cache can't hold: once the disk cache is
		# effectively full, remaining prefetch would only feed evict-on-insert
		# churn. Checked live per batch so a stale budget estimate can't
		# overshoot; skipped URLs still count toward progress.
		if not data_manager.cover.has_cache_headroom():
			_sync_covers_skipped_count += 1
			counted_cb.call()
			continue

		# Track pending download
		_sync_pending_downloads_mutex.lock()
		_sync_pending_downloads += 1
		_sync_pending_downloads_mutex.unlock()

		# Use existing async download path. Sync covers queue at normal priority:
		# high priority is reserved for on/near-screen card loads, and dispatch
		# throttling (COVER_DISPATCH_MAX_IN_FLIGHT) keeps the queue from
		# dropping these.
		# Bulk (true): sync prefetch is background batch work and must survive
		# grid-teleport pruning of user-facing queue entries. DROPPED
		# (backpressure) isn't logged as an error - the next sync's backfill
		# refetches anything that didn't land.
		data_manager.cover.download_cover(url, func(result):
			if result == DownloadSubManager.ImageResult.OK:
				_sync_covers_downloaded_count += 1
				data_manager.cover.queue_downloaded_cover_palette(url)
			else:
				_sync_covers_failed_count += 1
				if result == DownloadSubManager.ImageResult.FAILED:
					push_error("[SyncThread] Cover download FAILED: %s" % DownloadSubManager._redact_url(url))
			counted_cb.call()

			_sync_pending_downloads_mutex.lock()
			# Clamp: a straggler outliving a timed-out drain (or the whole
			# sync) must not drive the next sync's counter negative.
			_sync_pending_downloads = maxi(0, _sync_pending_downloads - 1)
			_sync_pending_downloads_mutex.unlock()
		, false, true)

	# Mark this dispatch batch as processed.
	_sync_covers_mutex.lock()
	_sync_covers_processed_count += 1
	_sync_covers_mutex.unlock()


func _remove_platform_sync_threaded(platform_slug: String) -> bool:
	"""Synchronous platform removal for sync thread (uses Semaphore, no busy-wait)."""
	var result = _wait_for_async(func(callback: Callable):
		data_manager.database.remove_platform_games(platform_slug, func(success: bool):
			callback.call(success)
		)
	, 60000)
	if result == null:
		print("[SyncThread] ERROR: Timeout removing platform %s" % platform_slug)
		return false
	return result if result is bool else false


# ==================== SERVER-DELETION RECONCILIATION ====================

## Guardrail: if the server's enumeration returns fewer than this fraction of
## the local platform rows, it is assumed partial/corrupt and reconciliation
## is aborted. A platform legitimately emptied server-side must go through
## the confirmation path instead of auto-deleting.
const RECONCILE_MIN_SEEN_FRACTION := 0.5

## Deletion batches at or below this size commit automatically. Larger ones
## are held in _pending_server_deletions until confirm_server_deletions().
const RECONCILE_AUTO_DELETE_THRESHOLD := 5


func _reconcile_platform_deletions_count_checked(platform_slug: String, platform_id: int) -> int:
	"""Sync thread: deletion reconcile for INCREMENTAL syncs. The
	updated_after window never contains deletions, so use the server's rom
	total as a cheap tripwire: when it disagrees with the local row count,
	enumerate all server ids for this platform and run the standard
	(guardrailed) reconcile. Returns the number removed.

	Count equality can mask a same-window add+delete pair; the weekly full
	sync remains the backstop for that case."""
	var probe = SystemManager.network.fetch_games_sync(str(platform_id), 0, 1, "")
	if not probe.success:
		if DEBUG_LOG: print("[SyncThread] Incremental reconcile probe failed for %s - skipping" % platform_slug)
		return 0
	var server_total := int(probe.data.get("total", -1))
	if server_total < 0:
		return 0

	var local_count = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.count_platform_rows(platform_slug),
			func(count):
				# null when the queue dropped the task (overflow).
				callback.call(count if count is int else null)
		)
	, 60000)
	if local_count == null or not (local_count is int):
		return 0
	if server_total == local_count:
		return 0
	if server_total == 0:
		# An emptied platform would trip the mass-deletion guardrails anyway;
		# leave it to an explicit full sync.
		print("[SyncThread] Incremental reconcile for %s: server reports 0 roms vs %d local rows - skipping (force a full sync to reconcile)" % [platform_slug, local_count])
		return 0

	print("[SyncThread] Incremental reconcile for %s: server total %d != %d local rows - enumerating server ids" % [platform_slug, server_total, local_count])
	var seen: Array = []
	var offset := 0
	var batch_size := 250
	while offset < server_total:
		var page = SystemManager.network.fetch_games_sync(str(platform_id), offset, batch_size, "")
		if not page.success:
			# Never delete on a partial enumeration.
			print("[SyncThread] Incremental reconcile enumeration failed for %s at offset %d - nothing deleted" % [platform_slug, offset])
			return 0
		var items = page.data.get("items", [])
		if items.is_empty():
			break
		for item in items:
			if item is Dictionary:
				seen.append(int(item.get("id", 0)))
		offset += batch_size
	_sync_seen_ids = seen
	_sync_platform_fully_enumerated = true
	return _reconcile_platform_deletions(platform_slug)


func _reconcile_platform_deletions(platform_slug: String) -> int:
	"""Sync thread: delete local rows whose romm_id the server no longer lists
	for this platform. Only call after a COMPLETE full enumeration - partial or
	incremental syncs must never trigger deletes. Returns the number removed.

	Guardrails: the enumeration must cover at least RECONCILE_MIN_SEEN_FRACTION
	of the local rows, and batches above RECONCILE_AUTO_DELETE_THRESHOLD wait
	for explicit user confirmation (server_deletions_detected signal)."""
	if not data_manager.database.is_database_ready():
		return 0

	var seen_ids = _sync_seen_ids.duplicate()

	# Guard 1: the enumeration must plausibly cover the local platform. A
	# truncated/failed enumeration looks exactly like a mass server deletion.
	var local_count = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.count_platform_rows(platform_slug),
			func(count):
				# null when the queue dropped the task (overflow).
				callback.call(count if count is int else null)
		)
	, 60000)
	if local_count == null or not (local_count is int):
		print("[SyncThread] ERROR: could not count local rows for %s - skipping reconciliation" % platform_slug)
		return 0
	if local_count == 0:
		return 0
	if seen_ids.size() < int(ceil(local_count * RECONCILE_MIN_SEEN_FRACTION)):
		if DEBUG_LOG: print("[SyncThread] Reconciliation aborted for %s: server enumeration (%d) is suspiciously small vs %d local rows - nothing deleted" % [platform_slug, seen_ids.size(), local_count])
		return 0

	# Dry run: compute the doomed set without deleting anything.
	var doomed = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				data_manager.database.lock()
				var rows = _find_server_removed_games(platform_slug, seen_ids)
				data_manager.database.unlock()
				return rows,
			func(rows):
				# null when the queue dropped the task (overflow).
				callback.call(rows if rows is Array else null)
		)
	, 120000)
	if doomed == null or not (doomed is Array):
		print("[SyncThread] ERROR: Timeout/overflow computing doomed set for %s - nothing deleted" % platform_slug)
		return 0
	if doomed.is_empty():
		# A fresh enumeration supersedes any older pending batch.
		_pending_server_deletions.erase(platform_slug)
		return 0

	# Guard 2: large batches need explicit user confirmation. The sync thread
	# must not block on UI, so the batch is held and the signal asks a view to
	# confirm (confirm_server_deletions) or decline (decline_server_deletions).
	if doomed.size() > RECONCILE_AUTO_DELETE_THRESHOLD:
		_pending_server_deletions[platform_slug] = doomed
		print("[SyncThread] %d server deletions detected for %s - held for user confirmation" % [doomed.size(), platform_slug])
		_defer_on_main("_emit_server_deletions_detected", [platform_slug, doomed.size()])
		return 0

	var committed = _wait_for_async(func(callback: Callable):
		_queue_reconciliation_commit(platform_slug, doomed, callback)
	, 120000)
	if committed == null or not (committed is int):
		print("[SyncThread] ERROR: Timeout/overflow committing reconciliation for %s" % platform_slug)
		return 0
	return committed


func _find_server_removed_games(platform_slug: String, seen_ids: Array) -> Array:
	"""DB thread (lock held): local rows absent from the server's complete
	enumeration of this platform. Read-only - deleting is a separate step."""
	var db = data_manager.database

	# Temp tables are per-connection and the DB queue is single-threaded, so
	# this only ever lives within this task.
	db.query_bool_unlocked("CREATE TEMP TABLE IF NOT EXISTS sync_seen_ids (romm_id INTEGER PRIMARY KEY)")
	db.query_bool_unlocked("DELETE FROM sync_seen_ids")

	var chunk_size = 500
	for i in range(0, seen_ids.size(), chunk_size):
		var chunk = seen_ids.slice(i, i + chunk_size)
		var placeholders = ", ".join(chunk.map(func(_id): return "(?)"))
		db.query_bool_unlocked("INSERT OR IGNORE INTO sync_seen_ids (romm_id) VALUES %s" % placeholders, chunk)

	return db.query_array_unlocked(
		"SELECT romm_id, cover_url, is_master_entry, siblings FROM games WHERE platform_slug = ? AND romm_id NOT IN (SELECT romm_id FROM sync_seen_ids)",
		[platform_slug])


func _queue_reconciliation_commit(platform_slug: String, doomed: Array, on_done: Callable = Callable()) -> void:
	"""Any thread: queue the transactional delete on the DB worker.
	on_done(count: int) runs on the main thread after cover cleanup."""
	MemorySubManager.queue_db_task(
		func():
			data_manager.database.lock()
			var info = _delete_server_removed_games(platform_slug, doomed)
			data_manager.database.unlock()
			return info,
		func(info):
			# null when the queue dropped the task (overflow).
			if info == null or not (info is Dictionary):
				push_warning("[Sync] Reconciliation commit dropped for %s (DB queue overflow)" % platform_slug)
				if on_done.is_valid():
					on_done.call(0)
				return
			var count: int = info.get("count", 0)
			if count > 0:
				_cleanup_reconciled_games(platform_slug, count, info.get("cover_urls", []))
			if on_done.is_valid():
				on_done.call(count)
	)


func confirm_server_deletions(platform_slug: String) -> bool:
	"""Main thread: commit a held above-threshold deletion batch. Returns false
	when no batch is pending for the platform."""
	if not _pending_server_deletions.has(platform_slug):
		return false
	var doomed: Array = _pending_server_deletions[platform_slug]
	_pending_server_deletions.erase(platform_slug)
	if DEBUG_LOG: print("[Sync] User confirmed %d server deletions for %s" % [doomed.size(), platform_slug])
	_queue_reconciliation_commit(platform_slug, doomed)
	return true


func decline_server_deletions(platform_slug: String) -> void:
	"""Main thread: discard a held deletion batch; local rows stay as-is."""
	if _pending_server_deletions.erase(platform_slug):
		print("[Sync] User declined pending server deletions for %s" % platform_slug)


func has_pending_server_deletions(platform_slug: String) -> bool:
	return _pending_server_deletions.has(platform_slug)


func _emit_server_deletions_detected(platform_slug: String, count: int) -> void:
	data_manager.server_deletions_detected.emit(platform_slug, count)


func _delete_server_removed_games(platform_slug: String, doomed: Array) -> Dictionary:
	"""DB thread (lock held): delete the given doomed rows in a single
	transaction. Related tables keyed by romm_id are cleaned alongside games,
	and every deleted romm_id is written to reconciliation_log (inside the
	transaction, so a rollback leaves no log rows).

	Sibling handling: when a deleted row was its group's master, the lowest
	surviving romm_id immediately becomes the new master (the same fallback
	_assign_group_master uses). Doomed ids are scrubbed from survivors'
	siblings arrays, and every affected group's download cache is rebuilt
	from member-row truth."""
	var db = data_manager.database
	if doomed.is_empty():
		return {"count": 0, "cover_urls": []}

	if not db.query_bool_unlocked("BEGIN TRANSACTION"):
		print("[SyncThread] ERROR: Failed to begin reconciliation transaction for %s" % platform_slug)
		return {"count": 0, "cover_urls": []}

	var chunk_size = 500

	var doomed_id_set := {}
	for row in doomed:
		doomed_id_set[int(row.get("romm_id", 0))] = true

	# Re-fold sibling groups whose master is being deleted.
	for row in doomed:
		if int(row.get("is_master_entry", 0)) != 1:
			continue
		var doomed_id := int(row.get("romm_id", 0))
		var parsed = JSON.parse_string(str(row.get("siblings", "[]")))
		if not (parsed is Array):
			continue
		var candidate_ids: Array = []
		for sib in parsed:
			if sib is Dictionary:
				var sid := int(sib.get("id", 0))
				if sid != 0 and sid != doomed_id and not doomed_id_set.has(sid):
					candidate_ids.append(sid)
		if candidate_ids.is_empty():
			continue
		var ph = ", ".join(candidate_ids.map(func(_id): return "?"))
		var survivors = db.query_array_unlocked(
			"SELECT romm_id FROM games WHERE romm_id IN (%s) ORDER BY romm_id ASC" % ph,
			candidate_ids)
		if survivors.is_empty():
			continue
		var new_master := int(survivors[0].get("romm_id", 0))
		var other_ids: Array = []
		for s in survivors:
			var sid := int(s.get("romm_id", 0))
			if sid != new_master:
				other_ids.append(sid)
		db.query_bool_unlocked("UPDATE games SET is_master_entry = 1 WHERE romm_id = ?", [new_master])
		if not other_ids.is_empty():
			var oph = ", ".join(other_ids.map(func(_id): return "?"))
			db.query_bool_unlocked("UPDATE games SET is_master_entry = 0 WHERE romm_id IN (%s)" % oph, other_ids)

	var doomed_ids = doomed.map(func(r): return int(r.get("romm_id", 0)))

	# Audit log first: if the delete rolls back, the log rows roll back too.
	var now := Time.get_datetime_string_from_system(true)
	for i in range(0, doomed_ids.size(), chunk_size):
		var chunk = doomed_ids.slice(i, i + chunk_size)
		var ph = ", ".join(chunk.map(func(_id): return "(?, ?, 'server_deleted', ?)"))
		var bindings: Array = []
		for id in chunk:
			bindings.append_array([platform_slug, id, now])
		db.query_bool_unlocked("INSERT INTO reconciliation_log (platform_slug, romm_id, action, created_at) VALUES %s" % ph, bindings)

	for i in range(0, doomed_ids.size(), chunk_size):
		var chunk = doomed_ids.slice(i, i + chunk_size)
		var ph = ", ".join(chunk.map(func(_id): return "?"))
		db.query_bool_unlocked("DELETE FROM game_filter_values WHERE game_id IN (%s)" % ph, chunk)
		db.query_bool_unlocked("DELETE FROM save_sync WHERE romm_id IN (%s)" % ph, chunk)
		db.query_bool_unlocked("DELETE FROM collection_roms WHERE romm_id IN (%s)" % ph, chunk)
		db.query_bool_unlocked("DELETE FROM pending_props_sync WHERE romm_id IN (%s)" % ph, chunk)

	var success := true
	for i in range(0, doomed_ids.size(), chunk_size):
		var chunk = doomed_ids.slice(i, i + chunk_size)
		var ph = ", ".join(chunk.map(func(_id): return "?"))
		if not db.query_bool_unlocked("DELETE FROM games WHERE platform_slug = ? AND romm_id IN (%s)" % ph, [platform_slug] + chunk):
			success = false
			break

	if not success:
		print("[SyncThread] ERROR: Reconciliation delete failed for %s, rolling back" % platform_slug)
		db.query_bool_unlocked("ROLLBACK")
		return {"count": 0, "cover_urls": []}

	# Scrub doomed ids from surviving rows' sibling arrays - otherwise a
	# deleted sibling lingers in the details-sheet dropdown and the group
	# master's download cache until the member happens to re-sync.
	var survivor_ref_ids := {}
	for row in doomed:
		var parsed = JSON.parse_string(str(row.get("siblings", "[]")))
		if parsed is Array:
			for sib in parsed:
				if sib is Dictionary:
					var sid := int(sib.get("id", 0))
					if sid != 0 and not doomed_id_set.has(sid):
						survivor_ref_ids[sid] = true
	if not survivor_ref_ids.is_empty():
		var sph = ", ".join(survivor_ref_ids.keys().map(func(_id): return "?"))
		var survivor_rows = db.query_array_unlocked(
			"SELECT romm_id, siblings FROM games WHERE romm_id IN (%s)" % sph,
			survivor_ref_ids.keys())
		var rebuilt_groups := {}
		for srow in survivor_rows:
			var srid := int(srow.get("romm_id", 0))
			var entries = JSON.parse_string(str(srow.get("siblings", "[]")))
			if not (entries is Array):
				continue
			var changed := false
			for i in range(entries.size() - 1, -1, -1):
				if entries[i] is Dictionary and doomed_id_set.has(int(entries[i].get("id", 0))):
					entries.remove_at(i)
					changed = true
			if changed:
				db.query_bool_unlocked("UPDATE games SET siblings = ? WHERE romm_id = ?", [JSON.stringify(entries), srid])
			# Rebuild this group's download cache (a member row was deleted).
			var member_ids: Array = [srid]
			for e in entries:
				if e is Dictionary:
					var eid := int(e.get("id", 0))
					if eid != 0 and not member_ids.has(eid):
						member_ids.append(eid)
			var sorted_ids := member_ids.duplicate()
			sorted_ids.sort()
			var group_key := str(sorted_ids)
			if member_ids.size() > 1 and not rebuilt_groups.has(group_key):
				rebuilt_groups[group_key] = true
				db.refresh_group_download_cache_unlocked(member_ids)

	# Cover files are only safe to delete when no surviving game references them
	var cover_urls: Array = []
	for row in doomed:
		var url := str(row.get("cover_url", ""))
		if url == "":
			continue
		var still_used = db.query_array_unlocked("SELECT 1 FROM games WHERE cover_url = ? LIMIT 1", [url])
		if still_used.is_empty():
			cover_urls.append(url)

	db.query_bool_unlocked("COMMIT")
	return {"count": doomed.size(), "cover_urls": cover_urls}


func _cleanup_reconciled_games(platform_slug: String, count: int, cover_urls: Array) -> void:
	"""Main thread: delete cover cache files orphaned by reconciliation and
	refresh cached counts. Local ROM files are intentionally left on disk."""
	data_manager.database.invalidate_downloaded_games_count_cache()
	var covers_deleted = 0
	for url in cover_urls:
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			if FSM.delete_file(cache_path):
				covers_deleted += 1
	if DEBUG_LOG: print("[Sync] Reconciled %s: removed %d server-deleted games (%d covers deleted)" % [platform_slug, count, covers_deleted])


func _lookup_platform_id_sync(platform_slug: String) -> int:
	"""Lookup platform ID from DB - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return 0

	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				var query_result = data_manager.database.query_array("SELECT romm_id FROM platforms WHERE slug = ?", [platform_slug])
				if query_result.size() > 0:
					return query_result[0].get("romm_id", 0)
				return 0,
			func(romm_id):
				# null when the queue dropped the task (overflow).
				callback.call(romm_id if romm_id is int else null)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout looking up platform ID for %s" % platform_slug)
		return 0
	return result if result is int else 0


func _get_last_sync_time_sync(platform_slug: String) -> String:
	"""Get last sync time - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return ""

	var key = "last_sync_" + platform_slug
	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				var query_result = data_manager.database.query_array("SELECT value FROM cache_metadata WHERE key = ?", [key])
				if query_result.size() > 0:
					return query_result[0].get("value", "")
				return "",
			func(value):
				# null when the queue dropped the task (overflow).
				callback.call(value if value is String else null)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout getting last sync time for %s" % platform_slug)
		return ""
	return result if result is String else ""


func _set_last_sync_time_sync(platform_slug: String, timestamp: String):
	"""Set last sync time - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return

	var key = "last_sync_" + platform_slug
	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES (?, ?)", [key, timestamp]),
			func(success):
				# null when the queue dropped the task (overflow).
				callback.call(success if success is bool else null)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout setting last sync time for %s" % platform_slug)
	elif not (result is bool and result):
		print("[SyncThread] ERROR: Failed to set last sync time for %s" % platform_slug)


func _process_batch_sync(items: Array, platform_slug: String, emit_incremental_progress: bool = false) -> int:
	"""Create GameResources, insert/fold them in one DB task, then dispatch
	covers and optional incremental progress from the sync thread."""
	if items.is_empty():
		return 0

	var base_count = _sync_current  # Starting count before this batch

	# Phase 1: Create GameResources with incremental progress
	var games: Array[GameResource] = []
	var progress_chunk_size = 25  # Emit progress every 25 games

	for i in range(items.size()):
		var game = _create_game_from_data(items[i], platform_slug)
		if game != null:
			games.append(game)

		# Emit incremental progress every 25 games
		if emit_incremental_progress and i > 0 and i % progress_chunk_size == 0:
			var partial_current = base_count + i
			var partial_pct = float(partial_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
			_defer_on_main("_emit_sync_progress", [partial_pct * 0.01, partial_current, _sync_total])

	if games.is_empty():
		return 0

	# Phase 2: Sibling checks + DB inserts in ONE combined DB task
	var inserted = _check_and_insert_games_sync(games)

	# Register new/outdated covers before their downloads can complete. Cached
	# files start extraction immediately; the rest are handled by the download
	# callback or the end-of-sync backfill. All file checks stay on this worker.
	var palette_candidates: Array[String] = []
	var palette_cached: Array[String] = []
	var palette_seen := {}
	for game in games:
		if game.cover_colors_version >= CoverPalette.ALGORITHM_VERSION \
			and game.cover_primary_color.a > 0.0 and game.cover_secondary_color.a > 0.0 and game.cover_tertiary_color.a > 0.0:
			continue
		if not game.has_cover_art or game.cover_url.is_empty() or not game.cover_url.begins_with("http"):
			continue
		if palette_seen.has(game.cover_url):
			continue
		palette_seen[game.cover_url] = true
		palette_candidates.append(game.cover_url)
		if FSM.file_exists(data_manager.cover.get_cached_image_path(game.cover_url)):
			palette_cached.append(game.cover_url)
	if not palette_candidates.is_empty():
		_defer_on_main("_queue_cover_palettes_on_main_thread", [palette_candidates, palette_cached, true])

	# Phase 3: Collect unique cover URLs and queue them for interleaved
	# dispatch during the sync. Gated on the download budget so we don't fetch
	# covers that evict-on-insert would immediately swap out.
	var new_urls: Array[String] = []
	_sync_covers_mutex.lock()
	for game in games:
		if game.has_cover_art and game.cover_url != "" and game.cover_url.begins_with("http"):
			if _sync_covers_seen_set.has(game.cover_url):
				continue
			# Don't burn download budget (or inflate the progress total) on
			# covers already on disk; mark seen so later batches don't re-stat.
			var cache_path = data_manager.cover.get_cached_image_path(game.cover_url)
			if FSM.file_exists(cache_path):
				_sync_covers_seen_set[game.cover_url] = true
				continue
			if _sync_covers_budget <= 0:
				continue
			_sync_covers_seen_set[game.cover_url] = true
			_sync_covers_budget -= 1
			# Counted into _sync_total at dispatch time, not here.
			new_urls.append(game.cover_url)
	for url in new_urls:
		if not _sync_covers_pending_set.has(url):
			_sync_covers_pending.append(url)
			_sync_covers_pending_set[url] = true
	_sync_covers_mutex.unlock()

	# Interleave cover downloads with the sync instead of doing it all at the
	# end: dispatch pending covers every few seconds so network work overlaps
	# the sync's network waits.
	if Time.get_ticks_msec() - _sync_last_cover_dispatch_ms > COVER_DISPATCH_INTERVAL_MS:
		_dispatch_covers_to_main_thread()

	return inserted


## Wraps the per-cover completion callback so sync progress is counted at most
## once per unique cover URL, even if a cover is processed more than once
## (e.g. dispatched in an early batch, then re-queued for late-added games).
func _make_cover_counted_callback(url: String, on_complete: Callable) -> Callable:
	return func():
		_sync_covers_mutex.lock()
		var already := _sync_covers_counted_set.has(url)
		if not already:
			_sync_covers_counted_set[url] = true
		_sync_covers_mutex.unlock()
		if not already and on_complete.is_valid():
			on_complete.call()


func _check_and_insert_games_sync(games: Array[GameResource]) -> int:
	"""Check siblings and insert games in a single DB task.

	This combines what used to be two separate DB tasks (sibling check + insert)
	into one, halving the DB queue pressure.
	"""
	if games.is_empty() or not data_manager.database.is_database_ready():
		return 0

	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				# Step 1: Assign master entries per fold group. Siblings in the
				# same batch must see each other - checking everything before
				# inserting made every same-batch sibling a master, so folding
				# only worked for groups split across batches.
				var fold_data := _assign_sibling_masters(games)

				# Step 2: Prefetch existing rows once (preservation + propagation)
				var existing_rows := _prefetch_existing_rows(games)

				# Step 3: Insert all games in one transaction
				var insert_success = _insert_games_transaction(games, existing_rows)

				# Step 4: Post-insert group maintenance: reciprocal sibling
				# lists on DB-resident members + group download caches.
				if insert_success:
					_post_insert_group_maintenance(games, fold_data, existing_rows)
				return insert_success,
			func(db_success):
				# null when the queue dropped the task (overflow).
				callback.call(db_success if db_success is bool else null)
		)
	, 120000)

	if result == null:
		print("[SyncThread] ERROR: Timeout waiting for DB check+insert (%d games)" % games.size())
		return 0

	var success = result if result is bool else false
	if success:
		# Skip all UI emissions during sync for performance
		# LibraryView will refresh when sync_completed is emitted
		return games.size()
	else:
		print("[SyncThread] ERROR: DB check+insert failed for %d games" % games.size())
		return 0


func _prefetch_existing_rows(games: Array[GameResource]) -> Dictionary:
	"""DB thread: one-query prefetch of preservation/propagation columns for
	the whole batch, keyed by romm_id. Avoids a per-game SELECT (N+1)."""
	var romm_ids: Array = []
	for game in games:
		if game != null and game.romm_id > 0:
			romm_ids.append(game.romm_id)
	var existing_rows: Dictionary = {}
	if romm_ids.is_empty() or not data_manager.database.is_database_ready():
		return existing_rows
	data_manager.database.lock()
	var placeholders = ", ".join(romm_ids.map(func(_id): return "?"))
	var existing_result = data_manager.database.query_array_unlocked(
		"SELECT romm_id, cover_url, cover_primary_color, cover_secondary_color, cover_tertiary_color, cover_colors_version, has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master, last_played, play_seconds, title_id, m3u_path, is_favorite, unwrapped, hidden_from_home, selected_sibling_id, save_id, save_usage, siblings FROM games WHERE romm_id IN (%s)" % placeholders,
		romm_ids
	)
	for row in existing_result:
		existing_rows[row.get("romm_id", 0)] = row
	data_manager.database.unlock()
	return existing_rows


func _insert_games_transaction(games: Array[GameResource], existing_rows: Dictionary = {}) -> bool:
	"""Insert multiple games within a single database transaction.

	This provides 10-50x speedup over individual inserts by reducing
	disk sync operations. All games in the batch succeed or fail together.
	existing_rows should come from _prefetch_existing_rows; when omitted it
	is fetched here (single-batch callers)."""
	if not data_manager.database.is_database_ready() or games.is_empty():
		return false
	if existing_rows.is_empty():
		existing_rows = _prefetch_existing_rows(games)
	data_manager.database.lock()

	# Start transaction
	var begin_result = data_manager.database.query_bool_unlocked("BEGIN TRANSACTION")
	if not begin_result:
		print("[DatabaseManager] ERROR: Failed to begin transaction")
		data_manager.database.unlock()
		return false

	var success = true
	var error_count = 0

	# Insert all games in this batch
	for game in games:
		if game == null:
			continue

		var insert_data = _build_insert_query(game, existing_rows.get(game.romm_id, {}))
		var insert_result = data_manager.database.query_bool_unlocked(insert_data.query, insert_data.bindings)
		if insert_result:
			data_manager.database.replace_game_filter_values_unlocked(game)
		else:
			success = false
			error_count += 1
			print("[DatabaseManager] ERROR: Failed to insert game '%s' (ID: %d)" % [game.title, game.romm_id])
			# Continue trying to insert others - we'll rollback at the end

	# Commit or rollback based on success
	if success:
		var commit_result = data_manager.database.query_bool_unlocked("COMMIT")
		if commit_result:
			data_manager.database.unlock()
			return true
		else:
			print("[DatabaseManager] ERROR: Failed to commit transaction")
			data_manager.database.query_bool_unlocked("ROLLBACK")
			data_manager.database.unlock()
			return false
	else:
		print("[DatabaseManager] ERROR: Transaction failed with %d errors, rolling back %d games" % [error_count, games.size()])
		data_manager.database.query_bool_unlocked("ROLLBACK")
		data_manager.database.unlock()
		return false


func _post_insert_group_maintenance(games: Array[GameResource], fold_data: Dictionary, existing_rows: Dictionary) -> void:
	"""DB thread: after a batch is inserted, bring DB-resident group members
	up to date with the server's sibling relationships, prune sibling entries
	that cross conflict-split fold lines, and rebuild every touched group's
	download cache from member-row truth."""
	var db = data_manager.database
	var groups: Dictionary = fold_data.get("groups", {})
	if not groups.is_empty():
		db.lock()
		for key in groups:
			db.refresh_group_download_cache_unlocked(groups[key])
		db.unlock()
	_prune_cross_group_siblings(fold_data.get("member_group", {}))
	_propagate_sibling_lists(games, existing_rows)


func _sibling_entry_for(game: GameResource) -> Dictionary:
	"""Sibling-JSON entry for a batch game, matching the shape sync stores
	(fs_name_no_ext convention: no extension until resolved on-demand)."""
	var base_name := game.file_name.get_basename()
	return {
		"id": game.romm_id,
		"name": game.title,
		"file_name": base_name,
		"file_size": game.file_size,
		"name_resolved": false,
		"title_id": "",
		"is_main_sibling": game.romm_is_main_sibling,
		"sort_comparator": "",
		"disc_number": GameResource.parse_disc_number(base_name),
	}


func _propagate_sibling_lists(games: Array[GameResource], existing_rows: Dictionary) -> void:
	"""DB thread: keep siblings JSON reciprocal across group members.

	A sync batch only rewrites rows for roms the server returned. When a rom
	joins a group whose other members synced earlier, those members' stored
	sibling arrays never learned about it - the group folds, but the details
	sheet (built from the master's siblings array) can't see the new entry,
	and unfolded it looks like an unrelated duplicate. The batch rom's server
	sibling list is authoritative for ITS relationships, so mirror them onto
	DB-resident members here (adds AND removals)."""
	var db = data_manager.database
	if not db.is_database_ready():
		return

	# Collect every member referenced by (or formerly referenced by) a batch
	# game's sibling list.
	var ref_ids := {}
	var new_lists := {}  # romm_id -> Array[int] (fresh server sibling ids)
	var old_lists := {}  # romm_id -> Array[int] (previously stored ids)
	for game in games:
		if game == null or game.romm_id <= 0:
			continue
		var new_ids: Array[int] = []
		for sibling in game.siblings:
			var sid := int(sibling.get("id", 0))
			if sid != 0 and sid != game.romm_id:
				new_ids.append(sid)
				ref_ids[sid] = true
		new_lists[game.romm_id] = new_ids
		var old_ids: Array[int] = []
		var existing: Dictionary = existing_rows.get(game.romm_id, {})
		var parsed_old = JSON.parse_string(str(existing.get("siblings", "[]")))
		if parsed_old is Array:
			for sib in parsed_old:
				if sib is Dictionary:
					var sid := int(sib.get("id", 0))
					if sid != 0 and sid != game.romm_id:
						old_ids.append(sid)
						ref_ids[sid] = true
		old_lists[game.romm_id] = old_ids
	if ref_ids.is_empty():
		return

	db.lock()
	var placeholders = ", ".join(ref_ids.keys().map(func(_id): return "?"))
	var member_rows = db.query_array_unlocked(
		"SELECT romm_id, siblings FROM games WHERE romm_id IN (%s)" % placeholders,
		ref_ids.keys())
	var member_siblings := {}  # romm_id -> Array (parsed, mutated in place)
	for row in member_rows:
		var rid := int(row.get("romm_id", 0))
		var parsed = JSON.parse_string(str(row.get("siblings", "[]")))
		member_siblings[rid] = parsed if parsed is Array else []

	var tx_ok = db.query_bool_unlocked("BEGIN TRANSACTION")
	var dirty := {}
	if tx_ok:
		for game in games:
			if game == null or game.romm_id <= 0:
				continue
			var new_ids: Array[int] = new_lists.get(game.romm_id, [])
			var related := {}
			for sid in new_ids:
				related[sid] = true
			for sid in old_lists.get(game.romm_id, []):
				related[sid] = true
			for sid in related.keys():
				if not member_siblings.has(sid):
					continue  # member row not in the DB (not synced yet)
				var entries: Array = member_siblings[sid]
				var idx := -1
				for i in range(entries.size()):
					if entries[i] is Dictionary and int(entries[i].get("id", 0)) == game.romm_id:
						idx = i
						break
				if new_ids.has(sid) and idx == -1:
					# New relationship: add this game to the member's array.
					# Existing entries are never overwritten, preserving any
					# resolved full file names.
					entries.append(_sibling_entry_for(game))
					dirty[sid] = true
				elif not new_ids.has(sid) and idx != -1:
					# The server no longer lists this relationship.
					entries.remove_at(idx)
					dirty[sid] = true
		for sid in dirty.keys():
			if not db.query_bool_unlocked("UPDATE games SET siblings = ? WHERE romm_id = ?", [JSON.stringify(member_siblings[sid]), sid]):
				tx_ok = false
				break
	if tx_ok:
		db.query_bool_unlocked("COMMIT")
	else:
		db.query_bool_unlocked("ROLLBACK")
	db.unlock()
	if not dirty.is_empty() and tx_ok:
		if DEBUG_LOG: print("[SyncThread] Propagated sibling lists to %d DB-resident group member(s)" % dirty.size())


func _prune_cross_group_siblings(member_group: Dictionary) -> void:
	"""DB thread: drop stored sibling entries that cross fold sub-group lines.

	RomM's sibling relation can bridge genuinely different games (a shared weak
	or mis-scraped metadata ID). When conflict splitting separates them, every
	touched component member's stored list is filtered to its own sub-group so
	the details dropdown and m3u disc pools never span games. Entries pointing
	at roms outside the touched components (unknown grouping) are kept."""
	if member_group.is_empty() or not data_manager.database.is_database_ready():
		return
	var db = data_manager.database
	db.lock()
	var ids: Array = member_group.keys()
	var placeholders = ", ".join(ids.map(func(_id): return "?"))
	var rows = db.query_array_unlocked(
		"SELECT romm_id, siblings FROM games WHERE romm_id IN (%s)" % placeholders,
		ids)
	var tx_ok = db.query_bool_unlocked("BEGIN TRANSACTION")
	var dirty := {}
	if tx_ok:
		for row in rows:
			var rid := int(row.get("romm_id", 0))
			var my_group: int = member_group.get(rid, 0)
			if my_group == 0:
				continue
			var parsed = JSON.parse_string(str(row.get("siblings", "[]")))
			if not (parsed is Array) or parsed.is_empty():
				continue
			var filtered: Array = []
			var changed := false
			for entry in parsed:
				if entry is Dictionary:
					var sid := int(entry.get("id", 0))
					# Unknown counterpart (not part of a touched component): keep.
					if sid == 0 or member_group.get(sid, my_group) == my_group:
						filtered.append(entry)
					else:
						changed = true
				else:
					filtered.append(entry)
			if changed:
				dirty[rid] = filtered
		for rid in dirty:
			if not db.query_bool_unlocked("UPDATE games SET siblings = ? WHERE romm_id = ?", [JSON.stringify(dirty[rid]), rid]):
				tx_ok = false
				break
	if tx_ok:
		db.query_bool_unlocked("COMMIT")
	else:
		db.query_bool_unlocked("ROLLBACK")
	db.unlock()
	if not dirty.is_empty() and tx_ok:
		if DEBUG_LOG: print("[SyncThread] Pruned cross-game sibling entries from %d row(s)" % dirty.size())


func _show_sync_notification():
	"""Show sync notification on main thread."""
	_sync_notification_id = SystemManager.notifications.show_notification(
		"Syncing...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			if _sync_total == 0:
				return 0.0
			var frac = float(_sync_current) / float(_sync_total)
			# Cap below 1.0 until the sync is actually completing so the pinned
			# notification isn't auto-dismissed by transient catch-up mid-sync.
			if _sync_state != SyncState.COMPLETING and _sync_state != SyncState.IDLE:
				return minf(frac, 0.99)
			return frac,
		func(progress: float) -> String:
			var pct = int(progress * 100)
			# Games and covers are separate work-unit pools summed into
			# _sync_total; show them distinctly so the headline number is
			# always the game count.
			var games_done := _sync_current - _sync_covers_done
			var games_total := _sync_total - _sync_covers_total
			var covers_suffix := ""
			if _sync_covers_total > 0:
				covers_suffix = " + %d/%d covers" % [_sync_covers_done, _sync_covers_total]
			if _sync_platform != "":
				return "Platform %d/%d: %s - %d/%d games%s (%d%%)" % [_sync_platform_index, _sync_platform_count, _sync_platform, games_done, games_total, covers_suffix, pct]
			return "Syncing %d/%d games%s (%d%%)" % [games_done, games_total, covers_suffix, pct],
		false,  # pulsing
		true  # pinned
	)


func _assign_sibling_masters(games: Array[GameResource]) -> Dictionary:
	"""Pick exactly one master entry per fold group in this batch.

	RomM's sibling relation bridges roms sharing ANY metadata ID (transitively),
	so one weak or mis-scraped ID can chain genuinely different games (sequels,
	series entries) into a single sibling component. Each component is therefore
	split on canonical-source conflicts (see _split_component_by_conflicts)
	before masters are assigned per resulting sub-group.

	Master preference: RomM's own is_main_sibling flag, then an existing DB
	master from the same sub-group, then the lowest romm_id. All other members
	are folded (is_master_entry = false). Batch games' sibling lists are scoped
	to their own sub-group in place. To be run on the DB thread.
	Returns {"groups": {key: [member romm_ids]}, "member_group": {romm_id: key}}
	for post-insert maintenance."""
	var parent := {}
	var games_by_id := {}
	var adjacency := {}  # romm_id -> {sibling romm_id: true} (direct server edges, both directions)

	for game in games:
		if game == null or game.siblings.is_empty():
			continue
		games_by_id[game.romm_id] = game
		_uf_add(parent, game.romm_id)
		if not adjacency.has(game.romm_id):
			adjacency[game.romm_id] = {}
		for sibling in game.siblings:
			var sid: int = sibling.get("id", 0)
			if sid != 0 and sid != game.romm_id:
				_uf_add(parent, sid)
				_uf_union(parent, game.romm_id, sid)
				adjacency[game.romm_id][sid] = true
				if not adjacency.has(sid):
					adjacency[sid] = {}
				adjacency[sid][game.romm_id] = true

	# Bucket batch games by component root
	var components := {}
	for game in games_by_id.values():
		var root := _uf_find(parent, game.romm_id)
		if not components.has(root):
			components[root] = []
		components[root].append(game)

	# Provider IDs for every component member: fresh payload IDs for batch
	# games, DB-stored IDs for the rest. Also folds DB-stored sibling edges
	# into the adjacency map for conflict-split attachment votes.
	var provider_map := _prefetch_member_provider_ids(parent, games_by_id, adjacency)

	var groups := {}
	var member_group := {}
	var group_seq := 0
	for root in components:
		var member_ids: Array = []
		for id in parent.keys():
			if _uf_find(parent, id) == root:
				member_ids.append(id)
		for sub_group in _split_component_by_conflicts(member_ids, provider_map, adjacency):
			group_seq += 1
			_assign_group_master(components[root], sub_group)
			groups[group_seq] = sub_group
			for id in sub_group:
				member_group[id] = group_seq

	# Scope batch games' sibling lists to their own sub-group, so the details
	# dropdown and m3u disc pools never span genuinely different games that
	# RomM bridged into the component. Sibling ids missing from member_group
	# (shouldn't happen - every sibling id is unioned in) are kept.
	for game in games_by_id.values():
		var my_key: int = member_group.get(game.romm_id, 0)
		if my_key == 0:
			continue
		var scoped: Array[Dictionary] = []
		for sibling in game.siblings:
			var sid: int = sibling.get("id", 0)
			if sid == 0 or member_group.get(sid, my_key) == my_key:
				scoped.append(sibling)
		game.siblings = scoped

	return {"groups": groups, "member_group": member_group}


func _prefetch_member_provider_ids(parent: Dictionary, games_by_id: Dictionary, adjacency: Dictionary) -> Dictionary:
	"""DB thread: romm_id -> provider_ids Dictionary for every component member.

	Batch games contribute their fresh payload IDs; DB-resident members are
	fetched in one query, which also folds their stored sibling edges into
	adjacency so conflict-split attachment votes see DB-only relationships."""
	var provider_map := {}
	var db_ids: Array = []
	for id in parent.keys():
		if games_by_id.has(id):
			provider_map[id] = games_by_id[id].provider_ids
		else:
			db_ids.append(id)
	if db_ids.is_empty() or not data_manager.database.is_database_ready():
		return provider_map
	data_manager.database.lock()
	var placeholders = ", ".join(db_ids.map(func(_id): return "?"))
	var rows = data_manager.database.query_array_unlocked(
		"SELECT romm_id, provider_ids, igdb_id, siblings FROM games WHERE romm_id IN (%s)" % placeholders,
		db_ids)
	data_manager.database.unlock()
	for row in rows:
		var rid := int(row.get("romm_id", 0))
		var parsed_ids = JSON.parse_string(str(row.get("provider_ids", "{}")))
		var ids_dict: Dictionary = parsed_ids if parsed_ids is Dictionary else {}
		# Rows synced before provider_ids existed still carry the igdb_id column;
		# fall back to it so conflict splitting works before a full re-sync.
		if not ids_dict.has("igdb"):
			var legacy_igdb := int(row.get("igdb_id", 0))
			if legacy_igdb > 0:
				ids_dict["igdb"] = legacy_igdb
		provider_map[rid] = ids_dict
		var parsed_siblings = JSON.parse_string(str(row.get("siblings", "[]")))
		if parsed_siblings is Array:
			if not adjacency.has(rid):
				adjacency[rid] = {}
			for sib in parsed_siblings:
				if sib is Dictionary:
					var sid := int(sib.get("id", 0))
					if sid != 0 and sid != rid:
						adjacency[rid][sid] = true
						if not adjacency.has(sid):
							adjacency[sid] = {}
						adjacency[sid][rid] = true
	return provider_map


func _split_component_by_conflicts(member_ids: Array, provider_map: Dictionary, adjacency: Dictionary) -> Array:
	"""Split a RomM sibling component into fold sub-groups.

	The canonical source is the highest-priority provider (FOLD_ID_PRIORITY)
	any member carries. Members agreeing on a single value there (or carrying
	nothing) fold together; conflicting values mean genuinely different games
	and split the component. Members not carrying the canonical source attach
	to the one sub-group all their direct siblings vote for - conflicting or
	absent votes leave them standalone rather than guessing."""
	var canonical := ""
	for provider in FOLD_ID_PRIORITY:
		for id in member_ids:
			if int(provider_map.get(id, {}).get(provider, 0)) > 0:
				canonical = provider
				break
		if canonical != "":
			break
	if canonical == "":
		return [member_ids]  # no metadata at all: nothing to judge conflicts by
	var values := {}
	for id in member_ids:
		var v := int(provider_map.get(id, {}).get(canonical, 0))
		if v > 0:
			values[v] = true
	if values.size() <= 1:
		return [member_ids]  # agreement or uneven coverage: fold together
	var sub_groups: Array = []
	var by_value := {}
	var unattached: Array = []
	for id in member_ids:
		var v := int(provider_map.get(id, {}).get(canonical, 0))
		if v > 0:
			if not by_value.has(v):
				by_value[v] = []
			by_value[v].append(id)
		else:
			unattached.append(id)
	for v in by_value:
		sub_groups.append(by_value[v])
	for id in unattached:
		var votes := {}
		for sid in adjacency.get(id, {}).keys():
			var sv := int(provider_map.get(sid, {}).get(canonical, 0))
			if sv > 0:
				votes[sv] = true
		if votes.size() == 1:
			by_value[votes.keys()[0]].append(id)
		else:
			sub_groups.append([id])
	if DEBUG_LOG:
		print("[SyncThread] Sibling component of %d split into %d fold groups (conflicting %s ids)" % [member_ids.size(), sub_groups.size(), canonical])
	return sub_groups


func _assign_group_master(component_batch: Array, member_ids: Array) -> void:
	"""Assign is_master_entry for one fold sub-group. component_batch holds the
	batch games of the whole sibling component; only those in member_ids are
	considered. member_ids includes siblings not in this batch."""
	var member_set := {}
	for id in member_ids:
		member_set[id] = true
	var members: Array = []
	for game in component_batch:
		if member_set.has(game.romm_id):
			members.append(game)

	if members.is_empty():
		# No batch members in this sub-group: its rows are already in the DB.
		# Ensure it still has a master (e.g. it was folded under a different
		# game before conflict splitting) by promoting the lowest romm_id.
		if _get_db_master_id(member_ids) == 0:
			_promote_lowest_db_member(member_ids)
		return

	# 1) RomM-flagged main sibling among batch members wins
	var master: GameResource = null
	for game in members:
		if game.romm_is_main_sibling:
			master = game
			break

	# 2) Otherwise keep an existing DB master from this group, if any
	if master == null:
		var db_master_id := _get_db_master_id(member_ids)
		if db_master_id != 0:
			for game in members:
				if game.romm_id == db_master_id:
					master = game
					break
			if master == null:
				# Master lives in the DB but isn't in this batch - fold all members under it
				for game in members:
					game.is_master_entry = false
				return

	# 3) Fallback: deterministic pick (lowest romm_id)
	if master == null:
		master = members[0]
		for game in members:
			if game.romm_id < master.romm_id:
				master = game

	for game in members:
		game.is_master_entry = (game == master)

	# Demote any stale DB master in this group that disagrees with our pick
	# (repairs groups folded incorrectly by older sync logic on re-sync)
	_demote_stale_db_masters(member_ids, master.romm_id)


func _get_db_master_id(member_ids: Array) -> int:
	"""Return the romm_id of an existing DB master in this group, or 0."""
	if member_ids.is_empty() or not data_manager.database.is_database_ready():
		return 0
	var placeholders = ", ".join(member_ids.map(func(_id): return "?"))
	var query = "SELECT romm_id FROM games WHERE romm_id IN (%s) AND is_master_entry = 1 LIMIT 1" % placeholders
	var result = data_manager.database.query_array(query, member_ids)
	if result.size() > 0:
		return result[0].get("romm_id", 0)
	return 0


func _promote_lowest_db_member(member_ids: Array) -> void:
	"""Promote the lowest romm_id of a DB-resident group to master entry.
	Used when a fold sub-group has no batch members and no existing master
	(e.g. it was folded under a different game before conflict splitting)."""
	if member_ids.is_empty() or not data_manager.database.is_database_ready():
		return
	var lowest: int = member_ids[0]
	for id in member_ids:
		if int(id) < lowest:
			lowest = int(id)
	# Only promote if the row actually exists in the DB (it may be a
	# payload-referenced sibling that has never synced).
	data_manager.database.query_bool(
		"UPDATE games SET is_master_entry = 1 WHERE romm_id = ?", [lowest])


func _demote_stale_db_masters(member_ids: Array, keep_master_id: int) -> void:
	"""Clear is_master_entry on any DB row in this group that isn't the chosen master."""
	if member_ids.is_empty() or not data_manager.database.is_database_ready():
		return
	var placeholders = ", ".join(member_ids.map(func(_id): return "?"))
	var query = "UPDATE games SET is_master_entry = 0 WHERE romm_id IN (%s) AND is_master_entry = 1 AND romm_id != ?" % placeholders
	var bindings = member_ids.duplicate()
	bindings.append(keep_master_id)
	data_manager.database.query_bool(query, bindings)


func _uf_add(parent: Dictionary, id: int) -> void:
	if not parent.has(id):
		parent[id] = id


func _uf_find(parent: Dictionary, id: int) -> int:
	var root := id
	while parent.get(root, root) != root:
		root = parent[root]
	# Path compression
	var cur := id
	while parent.get(cur, cur) != cur:
		var next: int = parent[cur]
		parent[cur] = root
		cur = next
	return root


func _uf_union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra


func _create_game_from_data(data: Dictionary, platform_slug: String) -> GameResource:
	var game = GameResource.new()
	game.id = str(data.get("id", ""))
	game.romm_id = data.get("id", 0)
	game.title = str(data.get("name", ""))
	game.platform = str(data.get("platform_display_name", ""))
	var raw_slug := platform_slug if platform_slug != "" else str(data.get("platform_slug", ""))
	game.platform_slug = FSM.sanitize_server_filename(raw_slug)
	if game.platform_slug != raw_slug:
		push_error("[SyncManager] Rejected unsafe platform slug from server: '" + raw_slug + "' for game " + game.title)
	# Always use RomM-proxied cover media (path_cover_large), never the external
	# scraper URL (url_cover) - the proxy works with the app's RomM credentials
	# and avoids scraper rate limits/logins. Mirrors argosy-launcher.
	var path_cover_large := str(data.get("path_cover_large", ""))
	if path_cover_large != "" and path_cover_large != "null" and path_cover_large != "<null>" and path_cover_large != "None":
		game.cover_url = SystemManager.network.build_media_url(path_cover_large)
	else:
		game.cover_url = ""
	game.cover_path = path_cover_large
	var screenshots: PackedStringArray = []
	var merged_screenshots = data.get("merged_screenshots", [])
	if merged_screenshots is Array:
		for shot in merged_screenshots:
			var shot_path := str(shot)
			if shot_path == "" or shot_path == "null" or shot_path == "<null>" or shot_path == "None":
				continue
			screenshots.append(SystemManager.network.build_media_url(shot_path))
	game.screenshot_urls = screenshots
	game.file_name = FSM.sanitize_server_filename(str(data.get("fs_name", "")))
	if game.file_name == "" and str(data.get("fs_name", "")) != "":
		push_error("[SyncManager] Rejected unsafe file name from server for game " + game.title + ": '" + str(data.get("fs_name", "")) + "'")
	game.file_path = str(data.get("full_path", ""))
	game.file_size = data.get("fs_size_bytes", 0)
	game.has_local_copy = false
	game.last_updated = str(data.get("updated_at", ""))
	game.description = str(data.get("summary", ""))

	var genres: Array[String] = []
	if data.has("metadatum") and data["metadatum"] is Dictionary:
		if data["metadatum"].has("genres") and data["metadatum"]["genres"] is Array:
			for g in data["metadatum"]["genres"]:
				if g is String:
					genres.append(g)
	game.genres = genres

	if data.has("metadatum") and data["metadatum"] is Dictionary:
		var rating_val = data["metadatum"].get("average_rating", 0.0)
		game.rating = rating_val if rating_val != null else 0.0

	# Extract raw IGDB metadata blob from RomM if present
	if data.has("igdb_metadata") and data["igdb_metadata"] is Dictionary:
		game.igdb_metadata = data["igdb_metadata"].duplicate()
	else:
		game.igdb_metadata = {}
	var raw_igdb_id = data.get("igdb_id", 0)
	game.igdb_id = int(raw_igdb_id) if raw_igdb_id != null else 0

	# Metadata provider IDs for conflict-aware sibling folding. RomM's
	# sibling_roms relation bridges roms sharing ANY of these IDs (even
	# transitively), so conflicting values at the same provider are the signal
	# that a sibling group actually contains different games (e.g. sequels).
	game.provider_ids = {}
	for provider in FOLD_ID_PRIORITY:
		var raw_id = data.get(provider + "_id", 0)
		if raw_id != null and int(raw_id) > 0:
			game.provider_ids[provider] = int(raw_id)

	# Release date: RomM exposes first_release_date as unix seconds; fall back
	# to the IGDB blob (also unix seconds) when the top-level field is missing.
	game.release_date = 0
	var raw_release = data.get("first_release_date", 0)
	if raw_release != null:
		game.release_date = int(raw_release) * 1000
	if game.release_date <= 0 and game.igdb_metadata.has("first_release_date"):
		var igdb_release = game.igdb_metadata.get("first_release_date", 0)
		if igdb_release != null:
			game.release_date = int(igdb_release) * 1000

	# Extract siblings from API response
	# Current RomM versions expose this as "sibling_roms" (SiblingRomSchema);
	# older versions used "siblings". Support both.
	var siblings: Array[Dictionary] = []
	var siblings_raw: Array = []
	if data.has("sibling_roms") and data["sibling_roms"] is Array:
		siblings_raw = data["sibling_roms"]
	elif data.has("siblings") and data["siblings"] is Array:
		siblings_raw = data["siblings"]
	for sibling_data in siblings_raw:
		if sibling_data is Dictionary:
			# Note: Sibling data from API only has basic info (id, name, fs_name_no_ext, etc.)
			# Full details (including proper file name with extension) will be fetched on-demand
			# when the user selects the sibling in the game details view

			var sibling = {
				"id": sibling_data.get("id", 0),
				"name": str(sibling_data.get("name", "")),
			"file_name": str(sibling_data.get("fs_name_no_ext", "")),  # Will be updated on-demand
			"file_size": sibling_data.get("fs_size_bytes", 0),
			"name_resolved": false,
			"title_id": "",  # Will be extracted on launch
			"is_main_sibling": sibling_data.get("is_main_sibling", false) == true,
			"sort_comparator": str(sibling_data.get("sort_comparator", "")),
			"disc_number": GameResource.parse_disc_number(str(sibling_data.get("fs_name_no_ext", "")))
		}
			siblings.append(sibling)
	game.siblings = siblings

	# RomM marks the representative rom of a sibling group via rom_user.is_main_sibling
	var rom_user = data.get("rom_user", {})
	game.romm_is_main_sibling = rom_user is Dictionary and rom_user.get("is_main_sibling", false) == true

	# RomM per-user play state (rom_user); status may be null when unset
	if rom_user is Dictionary:
		var raw_status = rom_user.get("status", null)
		game.status = str(raw_status) if raw_status != null else ""
		game.now_playing = rom_user.get("now_playing", false) == true
		game.backlogged = rom_user.get("backlogged", false) == true
		game.hidden = rom_user.get("hidden", false) == true

	# Batch master selection is finalized by _assign_sibling_masters.
	game.is_master_entry = true

	# Mark games without cover art so filtering can be applied dynamically
	if game.cover_url == "" or game.cover_url == "null" or game.cover_url == "<null>" or game.cover_url == "None":
		game.has_cover_art = false

	return game


func _existing_palette_color(value: Variant) -> Color:
	var encoded := str(value).strip_edges()
	if encoded.is_empty() or not Color.html_is_valid(encoded):
		return Color.TRANSPARENT
	return Color.html(encoded)


func _preserve_cover_palette(game: GameResource, existing: Dictionary) -> void:
	var preserve := not game.cover_url.is_empty() and str(existing.get("cover_url", "")) == game.cover_url
	game.cover_primary_color = _existing_palette_color(existing.get("cover_primary_color", "")) if preserve else Color.TRANSPARENT
	game.cover_secondary_color = _existing_palette_color(existing.get("cover_secondary_color", "")) if preserve else Color.TRANSPARENT
	game.cover_tertiary_color = _existing_palette_color(existing.get("cover_tertiary_color", "")) if preserve else Color.TRANSPARENT
	game.cover_colors_version = int(existing.get("cover_colors_version", 0)) if preserve else 0


func _build_insert_query(game: GameResource, existing_row: Dictionary = {}) -> Dictionary:
	"""Build SQL INSERT query and bindings for a game - used for batch processing.

	PRESERVES existing has_local_copy, downloaded_sibling_ids, file_path,
	last_played, and title_id if the game already exists in the
	database. This prevents downloaded games and local progress from
	disappearing after a re-sync. Pass existing_row (batch-prefetched) to
	avoid a per-game SELECT; direct callers fall back to fetching on demand."""

	# Check if game already exists and preserve download status
	var has_local_copy = 1 if game.has_local_copy else 0
	var downloaded_sibling_ids = JSON.stringify(game.downloaded_sibling_ids)
	var file_path = game.file_path
	var last_played = game.last_played
	var play_seconds = game.play_seconds
	var title_id = game.title_id
	var is_favorite = 1 if game.is_favorite else 0
	var unwrapped = 1 if game.unwrapped else 0
	var hidden_from_home = 1 if game.hidden_from_home else 0
	var selected_sibling_id = game.selected_sibling_id
	var save_id = game.save_id
	var save_usage = game.save_usage

	var existing = existing_row
	if existing.is_empty() and data_manager.database.is_database_ready() and game.romm_id > 0:
		var check_query = "SELECT cover_url, cover_primary_color, cover_secondary_color, cover_tertiary_color, cover_colors_version, has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master, last_played, play_seconds, title_id, m3u_path, is_favorite, unwrapped, hidden_from_home, selected_sibling_id, save_id, save_usage, siblings FROM games WHERE romm_id = ?"
		var query_result = data_manager.database.query_array_unlocked(check_query, [game.romm_id])
		if query_result.size() > 0:
			existing = query_result[0]

	if not existing.is_empty():
		# Palette metadata is derived locally, not supplied by RomM. Preserve it
		# only while the artwork identity (its URL) remains unchanged.
		_preserve_cover_palette(game, existing)
		# Preserve download status from existing record
		if existing.get("has_local_copy", 0) == 1:
			has_local_copy = 1
		# Preserve downloaded siblings
		var existing_siblings = existing.get("downloaded_sibling_ids", "[]")
		if existing_siblings != "[]" and existing_siblings != "":
			downloaded_sibling_ids = existing_siblings
		# Preserve file path
		var existing_path = existing.get("file_path", "")
		if existing_path != "":
			file_path = existing_path
		# Preserve cover group fields (they're managed separately from sync)
		var existing_cover_group_id = existing.get("cover_group_id", "")
		if existing_cover_group_id != "":
			game.cover_group_id = existing_cover_group_id
			game.cover_group_master = existing.get("cover_group_master", 1) == 1
		# Preserve locally-managed fields the server payload never provides
		var existing_last_played = existing.get("last_played", "")
		if existing_last_played != "":
			last_played = existing_last_played
		# Preserve accumulated playtime (recorded locally, never synced)
		var existing_play_seconds = int(existing.get("play_seconds", 0))
		if existing_play_seconds > 0:
			play_seconds = existing_play_seconds
		var existing_title_id = existing.get("title_id", "")
		if existing_title_id != "":
			title_id = existing_title_id
		# Preserve locally generated m3u playlist (the server payload never provides it)
		var existing_m3u_path = existing.get("m3u_path", "")
		if existing_m3u_path != "":
			game.m3u_path = existing_m3u_path
		# Preserve favorite flag (synced separately via the favourites virtual collection)
		is_favorite = 1 if existing.get("is_favorite", 0) == 1 else 0
		# Preserve present-wrap state (the server payload never provides it)
		unwrapped = 1 if existing.get("unwrapped", 0) == 1 else 0
		# Preserve local-only Home hide (never synced to or from the server)
		hidden_from_home = 1 if existing.get("hidden_from_home", 0) == 1 else 0
		# Preserve the user's chosen variant (the server payload never provides it)
		var existing_selected_sibling = existing.get("selected_sibling_id", 0)
		if existing_selected_sibling != null and int(existing_selected_sibling) != 0:
			selected_sibling_id = int(existing_selected_sibling)
		# Preserve sigil-derived save identity (extracted locally, never synced)
		var existing_save_id = existing.get("save_id", "")
		if existing_save_id != "":
			save_id = existing_save_id
		var existing_save_usage = existing.get("save_usage", "")
		if existing_save_usage != "":
			save_usage = existing_save_usage
		# Preserve resolved sibling metadata: full file names/sizes are fetched
		# on-demand locally; the server payload only carries fs_name_no_ext, so
		# a resync would otherwise reset them (breaking downloads-on-disk paths).
		var prev_siblings = JSON.parse_string(str(existing.get("siblings", "")))
		if prev_siblings is Array:
			var prev_by_id := {}
			for prev in prev_siblings:
				if prev is Dictionary:
					prev_by_id[int(prev.get("id", 0))] = prev
			for i in range(game.siblings.size()):
				var prev: Dictionary = prev_by_id.get(int(game.siblings[i].get("id", 0)), {})
				if prev.is_empty():
					continue
				if prev.get("name_resolved", false):
					game.siblings[i]["file_name"] = str(prev.get("file_name", game.siblings[i]["file_name"]))
					game.siblings[i]["file_size"] = int(prev.get("file_size", 0))
					game.siblings[i]["name_resolved"] = true
				for field in ["title_id", "save_id", "save_usage"]:
					var prev_val := str(prev.get(field, ""))
					if prev_val != "":
						game.siblings[i][field] = prev_val

	var query = """
		INSERT OR REPLACE INTO games
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path,
		 cover_primary_color, cover_secondary_color, cover_tertiary_color, cover_colors_version,
		 file_name, file_path, file_size, has_local_copy, last_updated,
		 description, genres, rating, release_date, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, play_seconds, title_id, save_id, save_usage, cover_group_id, cover_group_master, igdb_metadata, igdb_id, provider_ids, m3u_path, status, now_playing, backlogged, hidden, is_favorite, unwrapped, hidden_from_home, screenshots)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	"""

	var bindings = [
		game.id,
		game.romm_id,
		game.title,
		game.platform,
		game.platform_slug,
		game.cover_url,
		game.cover_path,
		"#" + game.cover_primary_color.to_html(false) if game.cover_primary_color.a > 0.0 else "",
		"#" + game.cover_secondary_color.to_html(false) if game.cover_secondary_color.a > 0.0 else "",
		"#" + game.cover_tertiary_color.to_html(false) if game.cover_tertiary_color.a > 0.0 else "",
		game.cover_colors_version,
		game.file_name,
		file_path,
		game.file_size,
		has_local_copy,
		game.last_updated,
		game.description,
		",".join(game.genres),
		game.rating,
		game.release_date,
		JSON.stringify(game.siblings),
		selected_sibling_id,
		1 if game.is_master_entry else 0,
		downloaded_sibling_ids,
		1 if game.has_cover_art else 0,
		last_played,
		play_seconds,
		title_id,
		save_id,
		save_usage,
		game.cover_group_id,
		1 if game.cover_group_master else 0,
		JSON.stringify(game.igdb_metadata),
		game.igdb_id,
		JSON.stringify(game.provider_ids),
		game.m3u_path,
		game.status,
		1 if game.now_playing else 0,
		1 if game.backlogged else 0,
		1 if game.hidden else 0,
		is_favorite,
		unwrapped,
		hidden_from_home,
		JSON.stringify(Array(game.screenshot_urls))
	]

	return {"query": query, "bindings": bindings}


# ==================== PLATFORMS ====================

func sync_platforms_from_romm(callback: Callable = Callable()):
	if not data_manager.database.is_database_ready():
		var err_msg = "Database initialization failed. App cannot function without database access." if data_manager.database.is_database_init_failed() else "Database not ready"
		if callback.is_valid():
			callback.call(false, err_msg)
		return

	SystemManager.network.fetch_platforms(func(data, error):
		if error != "" or not data is Array:
			if callback.is_valid():
				callback.call(false, error if error else "Invalid data")
			return

		var count = 0
		for platform_data in data:
			var platform = PlatformResource.new()
			platform.id = str(platform_data.get("id", ""))
			platform.romm_id = platform_data.get("id", 0)
			platform.name = platform_data.get("name", "")
			platform.slug = platform_data.get("slug", "")
			platform.icon_url = platform_data.get("url_logo", "")
			data_manager.database.add_platform(platform)
			count += 1

		data_manager.sync_completed.emit(true, "Synced " + str(count) + " platforms")
		if callback.is_valid():
			callback.call(true, "")
	)


func _start_sync_batch_mode():
	"""Mark sync as in progress (suppresses per-card cover downloads)."""
	_sync_batch_mode = true


func _stop_sync_batch_mode():
	"""Mark sync as finished."""
	_sync_batch_mode = false


func is_sync_in_progress() -> bool:
	"""Check if a sync is currently in progress."""
	return _sync_batch_mode


func get_sync_state() -> int:
	"""Get the current sync state for debugging/monitoring."""
	return _sync_state


func get_sync_state_name() -> String:
	"""Get the current sync state as a readable string."""
	match _sync_state:
		SyncState.IDLE:
			return "IDLE"
		SyncState.PRECHECK_DISABLED:
			return "PRECHECK_DISABLED"
		SyncState.PLATFORM_ITERATING:
			return "PLATFORM_ITERATING"
		SyncState.PLATFORM_FETCHING:
			return "PLATFORM_FETCHING"
		SyncState.PLATFORM_PROCESSING:
			return "PLATFORM_PROCESSING"
		SyncState.PLATFORM_BATCHING:
			return "PLATFORM_BATCHING"
		SyncState.COMPLETING:
			return "COMPLETING"
		_:
			return "UNKNOWN"


func get_current_platform_progress() -> Dictionary:
	"""Get progress information for the current platform being synced."""
	return {
		"platform_index": _sync_platform_index,
		"total_platforms": _sync_platform_count,
		"platform_name": _sync_platform,
		"games_synced": _sync_current_synced,
		"games_total": _sync_current_total,
		"batch_offset": _sync_current_offset
	}
