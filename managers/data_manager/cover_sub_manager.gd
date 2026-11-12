extends Manager
class_name CoverSubManager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CoverTrace = preload("res://utils/cover_trace.gd")
const CoverPalette = preload("res://utils/cover_palette.gd")

var data_manager: Node

const CACHE_FOLDER = "user://cache/covers/"
const VALIDATION_MARKER = "user://cache/covers_validated.txt"
# Bump this whenever the validation rules change so the full cache scan runs
# once more after an upgrade instead of on every launch.
const CACHE_VALIDATION_VERSION := 1
# Skip files modified within this window so covers being downloaded right now
# are never mistaken for corrupt cache entries by the background scan.
const RECENT_FILE_GRACE_SECONDS := 10
# Sidecar storing last-access times ({filename: unix_time}) for true LRU
# eviction: Godot has no utime API and rewriting files per cache hit is too
# much I/O. Advisory only - missing or corrupt data falls back to mtime order.
const LRU_SIDECAR_PATH = "user://cache/covers_lru.json"
const LRU_FLUSH_INTERVAL_SECONDS := 5.0
# Used to size the cover download budget when the cache has no files yet.
const ESTIMATED_COVER_BYTES := 150 * 1024
# Eviction trims to this fraction of the cap (not the cap itself) so steady-state
# browsing triggers an eviction pass per ~15% of cache growth instead of per
# cover write (hysteresis).
const EVICTION_LOW_WATER := 0.85
# Sync prefetch stops once the live cache total reaches this fraction of the
# cap, reserving the remainder for covers the user browses to.
const CACHE_HEADROOM_FRACTION := 0.95
# Returned by get_max_cache_bytes when the setting is Unlimited (stored as 0).
const UNLIMITED_CACHE_BYTES: int = 1 << 62

# Set while an eviction pass is in flight so concurrent triggers can't stack them.
var _eviction_running: bool = false

# Live cache byte accounting for evict-on-insert: each successful cover write
# adds its size and kicks an eviction pass when the cap is exceeded, so the
# cache never grows past the limit and no end-of-sync sweep is needed. Both
# are built by the startup maintenance pass (-1/empty until then) and kept
# authoritative by every eviction pass report. Main thread only.
var _cache_bytes_total: int = -1
var _cache_file_sizes: Dictionary = {}  # filename -> size in bytes

# filename -> unix time of last access. Main thread only; the eviction worker
# receives a duplicate snapshot instead of touching this map or the sidecar.
var _lru_map: Dictionary = {}
var _lru_dirty: bool = false
var _lru_flush_timer: Timer = null

# Palette extraction is background, low-priority work. Only two batches occupy
# the six image workers so cover decoding and visible cards keep most of the
# pool. These queues are main-thread only; workers receive immutable snapshots.
const PALETTE_BATCH_SIZE: int = 8
const PALETTE_MAX_IN_FLIGHT_BATCHES: int = 2
var _palette_pending: Array[String] = []
var _palette_pending_set: Dictionary = {}
var _palette_candidate_set: Dictionary = {}
var _palette_generation: Dictionary = {}
var _palette_inflight_set: Dictionary = {}
var _palette_inflight_batches: int = 0
var _palette_succeeded_set: Dictionary = {}


func _ready():
	data_manager = get_parent()
	# Own the fold_duplicate_covers reaction so DataManager._on_setting_changed
	# doesn't reach into cover internals.
	DataManager.setting_changed.connect(_on_setting_changed)
	# Cache maintenance is startup work, not a folding-setting side effect.
	# Keeping it in _on_setting_changed left byte accounting at -1 and disabled
	# validation/eviction unless the user happened to toggle cover folding.
	_ensure_cache_folder()
	_load_lru_sidecar()
	_lru_flush_timer = Timer.new()
	_lru_flush_timer.wait_time = LRU_FLUSH_INTERVAL_SECONDS
	_lru_flush_timer.autostart = true
	_lru_flush_timer.timeout.connect(_flush_lru_sidecar)
	add_child(_lru_flush_timer)
	# Read the cap on the main thread; the worker must not touch autoloads.
	var cap := get_max_cache_bytes()
	_eviction_running = true
	WorkerThreadPool.add_task(_cache_maintenance.bind(_cache_validation_needed(), cap, _lru_map.duplicate()))

func _on_setting_changed(value, setting: SettingsVar) -> void:
	if setting.property_name != "fold_duplicate_covers":
		return
	if value:
		print("[CoverFolding] Setting enabled - applying cover folding...")
		apply_cover_folding_to_database(func(folded_count: int):
			print("[CoverFolding] Applied cover folding to %d games" % folded_count)
			# Trigger grid refresh
			data_manager.sync_completed.emit(true, "Cover folding enabled - folded %d games" % folded_count)
		)
	else:
		print("[CoverFolding] Setting disabled - removing cover-based siblings...")
		_remove_cover_based_siblings()


func _exit_tree() -> void:
	_flush_lru_sidecar()


## Record a cover use for LRU eviction. Main thread only.
func note_cover_access(cache_path: String) -> void:
	if cache_path.is_empty():
		return
	_lru_map[cache_path.get_file()] = int(Time.get_unix_time_from_system())
	_lru_dirty = true


func _load_lru_sidecar() -> void:
	_lru_map.clear()
	var file := FileAccess.open(LRU_SIDECAR_PATH, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return
	for key in json.data:
		var value = json.data[key]
		if value is float or value is int:
			_lru_map[key] = int(value)


func _flush_lru_sidecar() -> void:
	if not _lru_dirty:
		return
	_lru_dirty = false
	# Atomic-ish write: temp file, then remove+rename (rename can't overwrite
	# an existing file on Windows). A crash between the two loses at most the
	# previous sidecar, which only degrades eviction to mtime order.
	var tmp_path := LRU_SIDECAR_PATH + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not file:
		return
	file.store_string(JSON.stringify(_lru_map))
	file.close()
	DirAccess.remove_absolute(LRU_SIDECAR_PATH)
	DirAccess.rename_absolute(tmp_path, LRU_SIDECAR_PATH)


func _cache_maintenance(run_validation: bool, max_bytes: int, lru_snapshot: Dictionary) -> void:
	if run_validation:
		_scan_cover_cache()
	_enforce_cache_size_limit(max_bytes, lru_snapshot)


func get_max_cache_bytes() -> int:
	var setting = DataManager.get_setting("cover_cache_max_mb")
	var mb: int = int(setting.value) if setting and setting.value != null else 2048
	if mb <= 0:
		return UNLIMITED_CACHE_BYTES
	return mb * 1024 * 1024


## True while the disk cache has room for prefetched covers. Used by sync to
## skip downloads that evict-on-insert would immediately swap out. Main thread.
func has_cache_headroom() -> bool:
	if _cache_bytes_total < 0:
		# Accounting not built yet (startup pass in flight): allow downloads;
		# the maintenance pass reconciles afterwards.
		return true
	return _cache_bytes_total < int(get_max_cache_bytes() * CACHE_HEADROOM_FRACTION)


func get_cover_trace_snapshot() -> Dictionary:
	return {
		"cache_bytes": _cache_bytes_total,
		"cache_files": _cache_file_sizes.size(),
		"cache_eviction": _eviction_running,
		"cache_headroom": has_cache_headroom(),
	}


func enforce_cache_limit_async() -> void:
	if _eviction_running:
		CoverTrace.event("cache", "eviction_already_running", {"bytes": _cache_bytes_total, "files": _cache_file_sizes.size()})
		return
	_eviction_running = true
	CoverTrace.event("cache", "eviction_start", {"bytes": _cache_bytes_total, "files": _cache_file_sizes.size()})
	# Steady-state passes run from the live size accounting instead of
	# rescanning the directory (O(sort + delete) rather than O(open every
	# file)). -1/empty means the startup pass hasn't built the accounting
	# yet; the worker then falls back to a directory scan.
	WorkerThreadPool.add_task(_enforce_cache_size_limit.bind(
		get_max_cache_bytes(), _lru_map.duplicate(),
		_cache_file_sizes.duplicate(), _cache_bytes_total))


func _enforce_cache_size_limit(max_bytes: int, lru_snapshot: Dictionary, size_snapshot: Dictionary = {}, snapshot_total: int = -1) -> void:
	"""Worker thread: evict least-recently-used covers until the cache folder
	is under EVICTION_LOW_WATER * the configured byte cap (hysteresis, so
	steady-state writes don't trigger a pass per cover). Recency comes from
	the LRU sidecar snapshot, falling back to file mtime for files with no
	recorded access. Files younger than RECENT_FILE_GRACE_SECONDS count toward
	the total but are never victims, so in-flight downloads are protected.

	When the main thread passes its live size accounting (snapshot_total >= 0)
	the pass runs from that map instead of rescanning the directory; mtimes
	are then stated lazily only for files missing from the LRU snapshot. The
	startup maintenance pass passes no accounting and scans the directory,
	which rebuilds the live map. Uses raw DirAccess/FileAccess for the same
	reason as _scan_cover_cache: FSM reaches autoloads unsafely from
	workers."""
	var entries: Array = []
	var total := 0
	var now := int(Time.get_unix_time_from_system())
	if snapshot_total >= 0:
		total = snapshot_total
		for file_name in size_snapshot:
			# LRU time doubles as the grace check: any file in the size map
			# went through _note_cover_write, which stamps the LRU map, so a
			# missing entry means an old file whose mtime predates the sidecar.
			var time: int = lru_snapshot.get(file_name, -1)
			if time < 0:
				time = int(FileAccess.get_modified_time(CACHE_FOLDER + file_name))
			entries.append({"path": CACHE_FOLDER + file_name, "name": file_name, "size": size_snapshot[file_name], "time": time})
	else:
		var dir := DirAccess.open(CACHE_FOLDER)
		if dir:
			dir.list_dir_begin()
			var file_name := dir.get_next()
			while file_name != "":
				if not dir.current_is_dir():
					var path := CACHE_FOLDER + file_name
					var mtime := int(FileAccess.get_modified_time(path))
					var file := FileAccess.open(path, FileAccess.READ)
					if file:
						var size := file.get_length()
						file.close()
						entries.append({"path": path, "name": file_name, "size": size, "time": lru_snapshot.get(file_name, mtime)})
						total += size
				file_name = dir.get_next()
			dir.list_dir_end()

	var deleted_count := 0
	var freed := 0
	var deleted_names: Array = []
	if total > max_bytes:
		var target := int(max_bytes * EVICTION_LOW_WATER)
		entries.sort_custom(func(a, b):
			return a.time < b.time
		)
		for e in entries:
			if total <= target:
				break
			# Never evict a file an in-flight download may still be writing.
			if now - e.time < RECENT_FILE_GRACE_SECONDS:
				continue
			if DirAccess.remove_absolute(e.path) == OK:
				total -= e.size
				freed += e.size
				deleted_count += 1
				deleted_names.append(e.name)

	# Report the surviving name->size map so the main thread can keep live
	# byte accounting for evict-on-insert without rescanning the directory.
	var deleted_set := {}
	for n in deleted_names:
		deleted_set[n] = true
	var remaining_sizes := {}
	for e in entries:
		if not deleted_set.has(e.name):
			remaining_sizes[e.name] = e.size
	# The manager may already be freed if the app quit mid-scan (benchmark).
	if is_instance_valid(self):
		call_deferred("_report_cache_eviction", deleted_count, freed, deleted_names, total, remaining_sizes)


func _report_cache_eviction(deleted_count: int, freed_bytes: int, deleted_names: Array, remaining_bytes: int, remaining_sizes: Dictionary) -> void:
	_eviction_running = false
	# The worker's snapshot is authoritative for files it saw; re-add covers
	# written while the pass was running (absent from the snapshot but not
	# evicted) so the live accounting doesn't lose them.
	for file_name in _cache_file_sizes.keys():
		if not remaining_sizes.has(file_name) and not file_name in deleted_names:
			remaining_sizes[file_name] = _cache_file_sizes[file_name]
			remaining_bytes += _cache_file_sizes[file_name]
	_cache_file_sizes = remaining_sizes
	_cache_bytes_total = remaining_bytes
	for file_name in deleted_names:
		_lru_dirty = _lru_map.erase(file_name) or _lru_dirty
	CoverTrace.event("cache", "eviction_complete", {
		"deleted": deleted_count,
		"freed_bytes": freed_bytes,
		"remaining_bytes": remaining_bytes,
		"remaining_files": remaining_sizes.size(),
		"over_cap": remaining_bytes > get_max_cache_bytes() if CoverTrace.enabled else false,
	})
	if deleted_count > 0:
		print("[CoverCache] Evicted %d covers (%d MB) to enforce the cache size limit" % [deleted_count, int(freed_bytes / (1024.0 * 1024.0))])
		# More covers were written while the pass ran and we're still over:
		# go again. Passes that deleted nothing don't retrigger - the overage
		# is all grace-window files, which become evictable on the next write.
		if remaining_bytes > get_max_cache_bytes():
			enforce_cache_limit_async()


func _ensure_cache_folder():
	FSM.make_dir_recursive(CACHE_FOLDER)


func _cache_validation_needed() -> bool:
	var file = FSM.open_file_read(VALIDATION_MARKER)
	if not file:
		return true
	var version := file.get_as_text().strip_edges().to_int()
	file.close()
	return version < CACHE_VALIDATION_VERSION


func _scan_cover_cache():
	"""Worker thread: flag cached covers that are not valid images.

	Only the first 16 bytes of each file are read (enough for magic-byte
	detection), so this is a metadata pass rather than a full read of every
	cover image. Uses raw DirAccess/FileAccess because the FSM helpers reach
	the SystemManager autoload, which is not safe to touch from a worker
	thread (and may already be freed if the app quits mid-scan).
	user://cache is app-private storage, so the Android restricted-path
	plugin is never needed here.
	"""
	var total := 0
	var deleted: Array[String] = []
	var dir := DirAccess.open(CACHE_FOLDER)
	if dir:
		var now := int(Time.get_unix_time_from_system())
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				var path := CACHE_FOLDER + file_name
				if now - int(FileAccess.get_modified_time(path)) >= RECENT_FILE_GRACE_SECONDS:
					var file := FileAccess.open(path, FileAccess.READ)
					if file:
						total += 1
						var size := file.get_length()
						var buffer := file.get_buffer(mini(size, 16))
						file.close()
						if size < 64 or buffer.size() < 16 or FSM.detect_image_format(buffer) == FSM.ImageFormat.UNKNOWN:
							if DirAccess.remove_absolute(path) == OK:
								deleted.append(path)
			file_name = dir.get_next()
		dir.list_dir_end()

	# Mark the cache as validated from the worker so short sessions (e.g. the
	# startup benchmark, which quits immediately) don't rescan on every launch.
	var marker := FileAccess.open(VALIDATION_MARKER, FileAccess.WRITE)
	if marker:
		marker.store_string(str(CACHE_VALIDATION_VERSION))
		marker.close()
	if is_instance_valid(self):
		call_deferred("_report_cover_cache_scan", total, deleted)


func _report_cover_cache_scan(total: int, deleted: Array[String]) -> void:
	for path in deleted:
		print("[CoverCache] Deleted invalid cached cover: ", path)
	CoverTrace.event("cache", "startup_validation", {"scanned": total, "deleted_invalid": deleted.size()})
	print("[CoverCache] Startup cache check: %d files, %d deleted as invalid" % [total, deleted.size()])


func get_cached_image_path(url: String) -> String:
	# Extract extension from URL, default to jpg if not found
	var extension = "jpg"
	var query_start = url.find("?")
	var url_without_query = url
	if query_start != -1:
		url_without_query = url.substr(0, query_start)

	var last_dot = url_without_query.rfind(".")
	if last_dot != -1 and last_dot < url_without_query.length() - 1:
		var ext = url_without_query.substr(last_dot + 1).to_lower()
		if ext in ["jpg", "jpeg", "png", "webp"]:
			extension = ext
			if extension == "jpeg":
				extension = "jpg"

	return CACHE_FOLDER + url.md5_text() + "." + extension


## Queue a cover for palette extraction. Main thread only. Missing cache files
## are ignored here; the cover download callback queues them once available.
func queue_palette_extraction(url: String, cache_verified: bool = false) -> void:
	if url.is_empty() or not url.begins_with("http"):
		return
	if _palette_succeeded_set.has(url) or _palette_pending_set.has(url) or _palette_inflight_set.has(url):
		return
	_palette_candidate_set[url] = true
	if not cache_verified and not FSM.file_exists(get_cached_image_path(url)):
		return
	_palette_pending.append(url)
	_palette_pending_set[url] = true
	_dispatch_palette_batches()


func register_palette_candidates(urls: Array, invalidate_inflight: bool = false) -> void:
	for value in urls:
		var url := str(value)
		if not url.is_empty() and url.begins_with("http"):
			# The DB said this palette is missing/outdated, so a previous success
			# may have been overwritten. Only actual sync-row replacements bump
			# the generation; read-only backfill scans avoid duplicate decoding.
			if invalidate_inflight:
				_palette_generation[url] = int(_palette_generation.get(url, 0)) + 1
			_palette_succeeded_set.erase(url)
			_palette_candidate_set[url] = true


func queue_palette_extractions(urls: Array, cache_verified: bool = false) -> void:
	for url in urls:
		queue_palette_extraction(str(url), cache_verified)


## Download completion hook. Up-to-date covers are not candidates, so routine
## downloads do not cause unnecessary palette recomputation.
func queue_downloaded_cover_palette(url: String) -> void:
	if _palette_candidate_set.has(url):
		queue_palette_extraction(url)


func _dispatch_palette_batches() -> void:
	while _palette_inflight_batches < PALETTE_MAX_IN_FLIGHT_BATCHES and not _palette_pending.is_empty():
		var take := mini(PALETTE_BATCH_SIZE, _palette_pending.size())
		var batch: Array[String] = []
		var generations := {}
		for i in range(take):
			var url := _palette_pending[i]
			batch.append(url)
			generations[url] = int(_palette_generation.get(url, 0))
			_palette_pending_set.erase(url)
			_palette_inflight_set[url] = true
		_palette_pending = _palette_pending.slice(take)
		_palette_inflight_batches += 1
		MemorySubManager.queue_image_task(
			_extract_palette_batch.bind(batch),
			_on_palette_batch_extracted.bind(batch, generations),
			false
		)


## Image worker: decode and sample a small batch sequentially. Raw FileAccess is
## intentional: FSM reaches autoloads and is not safe to use from every worker.
func _extract_palette_batch(urls: Array[String]) -> Array:
	var palettes: Array = []
	for url in urls:
		var cache_path := get_cached_image_path(url)
		var file := FileAccess.open(cache_path, FileAccess.READ)
		if file == null:
			continue
		var buffer := file.get_buffer(file.get_length())
		file.close()
		var image := _load_image_from_memory(buffer, cache_path)
		if image == null:
			continue
		var palette := CoverPalette.extract_hex(image)
		if palette.is_empty():
			continue
		palette["url"] = url
		palettes.append(palette)
	return palettes


func _on_palette_batch_extracted(result: Variant, urls: Array[String], generations: Dictionary) -> void:
	if result == null or not result is Array or result.is_empty():
		_finish_palette_batch(urls, [], false, generations)
		return
	data_manager.database.update_cover_palettes(result, func(success: bool):
		_finish_palette_batch(urls, result, success, generations)
	)


func _finish_palette_batch(urls: Array[String], palettes: Array, persist_success: bool, generations: Dictionary) -> void:
	_palette_inflight_batches = maxi(0, _palette_inflight_batches - 1)
	for url in urls:
		_palette_inflight_set.erase(url)
	var retry: Array[String] = []
	if persist_success:
		for palette in palettes:
			var url := str(palette.get("url", ""))
			data_manager.cover_palette_updated.emit(url)
			if int(_palette_generation.get(url, 0)) == int(generations.get(url, -1)):
				_palette_candidate_set.erase(url)
				_palette_succeeded_set[url] = true
			else:
				retry.append(url)
	# A sync-row replacement invalidated this batch while it was in flight.
	# Retry only those extracted URLs; failed decodes still wait for next sync.
	for url in retry:
		queue_palette_extraction(url)
	_dispatch_palette_batches()


func download_cover(url: String, callback: Callable, high_priority: bool = false, bulk: bool = false) -> void:
	var cache_path = get_cached_image_path(url)

	# Check if already cached
	if FSM.file_exists(cache_path):
		callback.call(DownloadSubManager.ImageResult.OK)
		return

	# Direct download - SystemManager.download handles deduplication.
	# The callback (and therefore _note_cover_write) runs on the main thread.
	SystemManager.download.download_image(url, cache_path, func(result):
		if result == DownloadSubManager.ImageResult.OK:
			_note_cover_write(cache_path)
		callback.call(result)
	, high_priority, bulk)


## Account for a freshly written cover and evict oldest-first if the cache now
## exceeds the cap (evict-on-insert). Main thread only. Deduplicated per file:
## DownloadSubManager may invoke multiple callbacks for one downloaded file.
func _note_cover_write(cache_path: String) -> void:
	note_cover_access(cache_path)
	var file_name := cache_path.get_file()
	if not _cache_file_sizes.has(file_name):
		var size := FSM.get_file_size(cache_path)
		if size > 0:
			_cache_file_sizes[file_name] = size
			if _cache_bytes_total >= 0:
				_cache_bytes_total += size
	if CoverTrace.enabled:
		CoverTrace.event("cache", "cover_write", {
			"cover": CoverTrace.trace_id(cache_path),
			"bytes": _cache_file_sizes.get(file_name, 0),
			"total_bytes": _cache_bytes_total,
			"files": _cache_file_sizes.size(),
			"cap_bytes": get_max_cache_bytes(),
			"eviction_running": _eviction_running,
		})
	if _cache_bytes_total >= 0 and _cache_bytes_total > get_max_cache_bytes():
		enforce_cache_limit_async()


func _load_image_from_memory(buffer: PackedByteArray, _cache_path: String = "") -> Image:
	if buffer.size() < 16:
		push_error("[CoverCache] Decode failed for %s: buffer too small (%d bytes)" % [_cache_path, buffer.size()])
		return null

	var image = Image.new()
	var err = FAILED
	var format = FSM.detect_image_format(buffer)

	match format:
		FSM.ImageFormat.JPEG:
			err = image.load_jpg_from_buffer(buffer)
		FSM.ImageFormat.PNG:
			err = image.load_png_from_buffer(buffer)
		FSM.ImageFormat.WEBP:
			err = image.load_webp_from_buffer(buffer)
		_:
			# Unknown magic bytes: not a supported image.
			push_error("[CoverCache] Decode failed for %s: unknown magic bytes (%d bytes, first16=%s)" % [_cache_path, buffer.size(), buffer.slice(0, 16).hex_encode()])
			return null

	if err == OK and not image.is_empty():
		return image
	push_error("[CoverCache] Decode failed for %s: format=%d loader error=%d (%d bytes)" % [_cache_path, format, err, buffer.size()])
	return null


func load_image(url: String, callback: Callable = Callable(), high_priority: bool = false):
	if url == "" or not url.begins_with("http"):
		if callback.is_valid():
			callback.call(null, DownloadSubManager.ImageResult.FAILED)
		return

	var cache_path = get_cached_image_path(url)

	# Try cache first - using background thread
	if FSM.file_exists(cache_path):
		note_cover_access(cache_path)
		CoverTrace.event("cache", "cached_full_decode_request", {"cover": CoverTrace.trace_id(url), "priority": high_priority})
		MemorySubManager.queue_image_task(
			func():
				return MemorySubManager.prepare_image_for_texture(_load_image_from_memory(FSM.read_file_bytes(cache_path), cache_path)),
		func(image):
			CoverTrace.event("cache", "cached_full_decode_result", {"cover": CoverTrace.trace_id(url), "ok": image != null and not image.is_empty()})
			if image and not image.is_empty():
				var texture = MemorySubManager.create_texture_from_image(image)
				if texture:
					if callback.is_valid():
						callback.call(texture, DownloadSubManager.ImageResult.OK)
					data_manager.image_loaded.emit(url, texture)
				else:
					# Cache file exists but failed to load, try downloading fresh
					_load_image_from_network(url, cache_path, callback, high_priority)
			else:
				# Cache file exists but failed to load, try downloading fresh
				_load_image_from_network(url, cache_path, callback, high_priority)
		, high_priority)
		return

	# Download if not cached
	_load_image_from_network(url, cache_path, callback, high_priority)


func _load_image_from_network(url: String, cache_path: String, callback: Callable, high_priority: bool = false):
	"""Download and load image from network using background thread."""
	download_cover(url, func(result):
		# Check if file was downloaded successfully
		if not FSM.file_exists(cache_path):
			if callback.is_valid():
				# OK-but-missing means the file was evicted between write and
				# read: transient, so report DROPPED (retryable) not FAILED.
				var out_result: int = result if result != DownloadSubManager.ImageResult.OK else DownloadSubManager.ImageResult.DROPPED
				CoverTrace.event("cache", "missing_after_download", {"cover": CoverTrace.trace_id(url), "download_result": result, "out_result": out_result, "eviction_running": _eviction_running})
				callback.call(null, out_result)
			return

		CoverTrace.event("cache", "downloaded_full_decode_request", {"cover": CoverTrace.trace_id(url), "download_result": result, "priority": high_priority})
		MemorySubManager.queue_image_task(
			func():
				return MemorySubManager.prepare_image_for_texture(_load_image_from_memory(FSM.read_file_bytes(cache_path), cache_path)),
		func(image):
			CoverTrace.event("cache", "downloaded_full_decode_result", {"cover": CoverTrace.trace_id(url), "ok": image != null and not image.is_empty()})
			if image and not image.is_empty():
				var texture = MemorySubManager.create_texture_from_image(image)
				if texture:
					if callback.is_valid():
						callback.call(texture, DownloadSubManager.ImageResult.OK)
					data_manager.image_loaded.emit(url, texture)
				else:
					# Decode worked but texture creation failed (transient,
					# e.g. memory pressure). Still must answer the callback:
					# callers that never get a result stay in loading state
					# forever.
					if callback.is_valid():
						callback.call(null, DownloadSubManager.ImageResult.FAILED)
			else:
				# Corrupt/partial cache file. Delete it so the next attempt
				# re-downloads instead of decoding the same bad bytes forever
				# (the download path reports "already cached" and would loop
				# straight back here), and answer with FAILED so callers
				# apply their normal retry/backoff policy.
				CoverTrace.event("cache", "delete_undecodable", {"cover": CoverTrace.trace_id(url)})
				FSM.delete_file(cache_path)
				if callback.is_valid():
					callback.call(null, DownloadSubManager.ImageResult.FAILED)
		, high_priority)
	, high_priority)


func clear_cache():
	for file_name in FSM.list_dir(CACHE_FOLDER):
		FSM.delete_file(FSM.join_paths(CACHE_FOLDER, file_name))
	_lru_map.clear()
	_lru_dirty = false
	_cache_bytes_total = 0
	_cache_file_sizes.clear()
	DirAccess.remove_absolute(LRU_SIDECAR_PATH)
	# Wipe the in-memory texture cache too, or stale textures survive the disk wipe
	MemorySubManager.clear_texture_cache()
	data_manager.cache_cleared.emit()


func get_cache_size() -> int:
	var total_size = 0
	for file_name in FSM.list_dir(CACHE_FOLDER):
		total_size += FSM.get_file_size(FSM.join_paths(CACHE_FOLDER, file_name))
	return total_size


func get_random_cached_cover_path() -> String:
	"""Get a random cover image from the cache folder."""
	var image_files: Array[String] = []
	for file_name in FSM.list_dir(CACHE_FOLDER):
		if file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg") or file_name.ends_with(".webp"):
			image_files.append(FSM.join_paths(CACHE_FOLDER, file_name))

	if image_files.size() > 0:
		return image_files[randi() % image_files.size()]
	return ""


# ==================== COMPREHENSIVE COVER FOLDING ====================

func apply_cover_folding_to_database(callback: Callable = Callable()):
	"""Globally group identical cover URLs by a hashed cover_group_id. The
	lowest romm_id in each group becomes cover_group_master; games already in
	RomM sibling groups keep their separate is_master_entry handling."""
	if not data_manager.database.is_database_ready():
		if callback.is_valid():
			callback.call(0)
		return

	# Check if cover folding is enabled
	var fold_covers_setting = DataManager.get_setting("fold_duplicate_covers")
	if not fold_covers_setting or not fold_covers_setting.value:
		if callback.is_valid():
			callback.call(0)
		return

	# Cover folding changes cover_group_master, which affects the count query.
	data_manager.database.invalidate_downloaded_games_count_cache()

	print("[CoverFolding] Starting global cover folding...")

	# Show pulsing notification
	var notification_id = SystemManager.notifications.show_notification(
		"Folding duplicate covers...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true,  # pulsing
		true  # pinned
	)

	MemorySubManager.queue_db_task(
		func():
			data_manager.database.lock()

			# Query all games with cover URLs that don't have RomM siblings
			# We exclude games that already have siblings in the RomM system
			var query = """
				SELECT id, romm_id, title, file_name, file_size, cover_url, siblings
				FROM games
				WHERE cover_url != '' AND cover_url IS NOT NULL
			"""

			var rows = data_manager.database.query_array_unlocked(query)
			if rows.is_empty():
				data_manager.database.unlock()
				return 0

			# Prefetch all master-entry romm_ids once (avoids a per-sibling COUNT query)
			var master_ids: Dictionary = {}
			var master_rows = data_manager.database.query_array_unlocked("SELECT romm_id FROM games WHERE is_master_entry = 1")
			for r in master_rows:
				master_ids[r.get("romm_id", 0)] = true

			# Build cover groups from games WITHOUT RomM siblings
			var cover_groups: Dictionary = {}
			var games_with_romm_siblings: Dictionary = {}

			for row in rows:
				var romm_id = row.get("romm_id", 0)
				var cover_url = row.get("cover_url", "")
				var siblings_json = row.get("siblings", "[]")

				if cover_url == "" or romm_id == 0:
					continue

				# Check if this game has RomM siblings (not just cover siblings)
				var has_romm_siblings = false
				var json = JSON.new()
				var err = json.parse(siblings_json)
				if err == OK and json.data is Array:
					for sibling in json.data:
						if sibling is Dictionary:
							var sibling_id = sibling.get("id", 0)
							# Check if this sibling exists in DB as master (RomM sibling)
							if sibling_id != 0 and sibling_id != romm_id and master_ids.has(sibling_id):
								has_romm_siblings = true
								break

				if has_romm_siblings:
					# Don't process games with RomM siblings
					games_with_romm_siblings[romm_id] = true
					continue

				# Add to cover group
				if not cover_groups.has(cover_url):
					cover_groups[cover_url] = []

				cover_groups[cover_url].append({
					"romm_id": romm_id
				})

			var groups_processed = 0
			var games_folded = 0

			# Apply all group updates in a single transaction
			if not data_manager.database.query_bool_unlocked("BEGIN IMMEDIATE TRANSACTION"):
				data_manager.database.unlock()
				return 0

			var tx_ok = true

			# Process each cover group with 2+ games. Two bulk statements per
			# group regardless of group size: one tags every member, one
			# promotes the master. (Members are addressed by romm_id, not
			# cover_url, so games excluded for having RomM siblings stay clean.)
			for cover_url in cover_groups.keys():
				var games = cover_groups[cover_url]
				if games.size() < 2:
					continue

				groups_processed += 1

				# Generate group ID from cover URL hash
				var group_id = cover_url.md5_text()

				# Find the lowest romm_id in this group (will be the master)
				var lowest_id = games[0].romm_id
				for game in games:
					if game.romm_id < lowest_id:
						lowest_id = game.romm_id

				var member_ids: Array = []
				var placeholders: Array[String] = []
				for game in games:
					member_ids.append(game.romm_id)
					placeholders.append("?")

				var tag_query := "UPDATE games SET cover_group_id = ?, cover_group_master = 0 WHERE romm_id IN (%s)" % ",".join(placeholders)
				var tag_bindings: Array = [group_id]
				tag_bindings.append_array(member_ids)
				if not data_manager.database.query_bool_unlocked(tag_query, tag_bindings):
					tx_ok = false

				if not data_manager.database.query_bool_unlocked(
					"UPDATE games SET cover_group_master = 1 WHERE romm_id = ?", [lowest_id]):
					tx_ok = false

				# All non-master members count as folded
				games_folded += games.size() - 1

			if tx_ok:
				data_manager.database.query_bool_unlocked("COMMIT")
			else:
				data_manager.database.query_bool_unlocked("ROLLBACK")
				games_folded = 0
			data_manager.database.unlock()

			print("[CoverFolding] Processed %d cover groups, folded %d games" % [groups_processed, games_folded])
			return games_folded,
		func(folded_count):
			# Always dismiss the pinned notification — null means the queue
			# dropped the task (overflow), not that folding finished.
			SystemManager.notifications.dismiss_notification(notification_id)

			if folded_count == null:
				push_warning("[CoverFolding] folding task dropped (DB queue overflow)")
				if callback.is_valid():
					callback.call(0)
				return

			if folded_count > 0:
				SystemManager.notifications.show_notification(
					"Folded %d duplicate covers" % folded_count,
					SystemManager.notifications.Type.SUCCESS
				)

			print("[CoverFolding] Complete - folded %d games" % folded_count)
			if callback.is_valid():
				callback.call(folded_count)
	)


func _remove_cover_based_siblings():
	"""Unfold all games by setting cover_group_master = 1 for all games in cover groups.

	This is the simple inverse of apply_cover_folding_to_database. Since cover_group_id
	is preserved during sync, we just need to set cover_group_master = 1 for all games
	that are in a cover group (cover_group_id != '').
	"""
	if not data_manager.database.is_database_ready():
		return

	# Unfolding changes cover_group_master, which affects the count query.
	data_manager.database.invalidate_downloaded_games_count_cache()

	MemorySubManager.queue_db_task(
		func():
			# Lock across UPDATE + changes() so another thread's query can't
			# interleave and corrupt the count.
			data_manager.database.lock()
			var query = "UPDATE games SET cover_group_master = 1 WHERE cover_group_id != ''"
			var success = data_manager.database.query_bool_unlocked(query)

			var unfolded_count = 0
			var query_result = data_manager.database.query_array_unlocked("SELECT changes() as count")
			data_manager.database.unlock()
			if success and query_result.size() > 0:
				unfolded_count = query_result[0].get("count", 0)

			return unfolded_count,
		func(unfolded_count):
			# null when the queue dropped the task (overflow).
			if unfolded_count == null:
				push_warning("[CoverFolding] unfold task dropped (DB queue overflow)")
				return
			print("[CoverFolding] Unfolded %d games" % unfolded_count)
			# Notify listeners that library needs refresh
			data_manager.sync_completed.emit(true, "Cover folding disabled - unfolded %d games" % unfolded_count)
	)
