extends Manager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")
const OperationLifecycle = preload("res://utils/filesystem/operation_lifecycle.gd")

# DataManager - Public facade for data persistence and caching.
# Delegates all work to child managers in the data_manager.tscn scene.

signal database_ready()
@warning_ignore("unused_signal")
signal database_failed(error_message: String)
signal sync_completed(success: bool, message: String)
@warning_ignore("unused_signal")
signal sync_progress(percent: float, current: int, total: int)
@warning_ignore("unused_signal")
signal game_updated(game: GameResource)
@warning_ignore("unused_signal")
signal cover_palette_updated(cover_url: String)
## Emitted when a game's Home-grid membership changes (local hide/unhide).
## Home rebuilds on this; other views ignore it (nothing displays the flag).
@warning_ignore("unused_signal")
signal game_home_visibility_changed(game: GameResource)
@warning_ignore("unused_signal")
signal games_removed(platform_slug: String)
@warning_ignore("unused_signal")
signal image_loaded(url: String, texture: Texture2D)
@warning_ignore("unused_signal")
signal cache_cleared()

# NEW: Emitted when the downloaded-games scan finishes.
@warning_ignore("unused_signal")
signal scan_for_downloaded_games_completed(found_count: int)

# Emitted (main thread) when a full sync finds more server-side deletions for
# a platform than the auto-delete threshold. The batch is held until
# confirm_server_deletions() or decline_server_deletions() is called.
# Emitted from SyncSubManager via this instance; connected in main.gd.
@warning_ignore("unused_signal")
signal server_deletions_detected(platform_slug: String, count: int)

# Settings facade signals
signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved()
signal apply_preset_begin()
signal apply_preset_end()

# Game save facade signal
signal save_sync_completed(game: GameResource, success: bool, message: String)

# Collection membership facade signal
@warning_ignore("unused_signal")
signal collection_membership_changed(collection_id: int, romm_id: int)

@onready var database: DatabaseSubManager = $DatabaseSubManager
@onready var sync: SyncSubManager = $SyncSubManager
@onready var cover: CoverSubManager = $CoverSubManager
@onready var save: SaveSyncSubManager = $SaveSyncSubManager
@onready var collections: CollectionSubManager = $CollectionSubManager
@onready var user_props: UserPropsSubManager = $UserPropsSubManager
var settings: SettingsSubManager
var game_save: GameSaveSubManager

## Bumped on every successful sync_completed. sync_completed is one-shot, so
## views that were disconnected when it fired (DS-mode reparenting, tab
## teardown) compare against their last-seen generation on show to catch up.
var library_generation: int = 0

func _enter_tree() -> void:
	settings = $SettingsSubManager
	game_save = $GameSaveSubManager

func _ready():
	_ensure_memory_manager()

	# Open the database on the DB worker thread so the autoload chain isn't
	# blocked by disk I/O. Views gate on database_ready / is_database_ready().
	MemorySubManager.queue_db_task(
		func():
			return database.initialize_database(),
		func(success):
			# null when the queue dropped the task (overflow): without this,
			# neither database_ready nor database_failed would ever emit and
			# every view would hang waiting.
			if success == null:
				success = false
			if success:
				print("[DatabaseManager] Database ready - emitting signal")
				database_ready.emit()
				# Warm the hot startup caches on the DB thread so view _ready
				# paths hit cache instead of scanning on the main thread.
				# Queued AFTER the signal: inside the init task it starved the
				# worker queue through the startup settle window.
				MemorySubManager.queue_db_task(func():
					var warm_start_us := Time.get_ticks_usec()
					database.get_downloaded_games_count()
					database.get_platforms_with_games()
					print("[DatabaseManager] startup cache warm elapsed_us=", Time.get_ticks_usec() - warm_start_us)
				)
			else:
				var err_msg = "Failed to initialize database at " + database.DB_PATH
				database_failed.emit(err_msg)
				SystemManager.notifications.show_notification("Fatal error: " + err_msg + "\nApp cannot function without database access.", SystemManager.notifications.Type.ERROR)
	)
	database_ready.connect(_on_database_ready_for_collections)

	# Wire settings sub-manager signals through the DataManager facade
	settings.setting_changed.connect(func(value: Variant, setting: SettingsVar): setting_changed.emit(value, setting))
	settings.settings_saved.connect(settings_saved.emit)
	settings.apply_preset_begin.connect(apply_preset_begin.emit)
	settings.apply_preset_end.connect(apply_preset_end.emit)

	# Wire game save sub-manager signal through the DataManager facade
	game_save.save_sync_completed.connect(func(game: GameResource, success: bool, message: String): save_sync_completed.emit(game, success, message))

	# Wire collection membership signal through the DataManager facade
	collections.collection_membership_changed.connect(func(collection_id: int, romm_id: int): collection_membership_changed.emit(collection_id, romm_id))

	# Connect to setting changes for dynamic cover folding
	settings.setting_changed.connect(_on_setting_changed)

	# Single chokepoint for the generation bump: connected before any view, so
	# it runs before view handlers regardless of who emitted sync_completed.
	sync_completed.connect(func(success: bool, _message: String):
		if success:
			library_generation += 1
	)


func _ensure_memory_manager():
	if SystemManager.memory._instance == null:
		var mm = MemorySubManager.new()
		add_child(mm)


func _on_setting_changed(value, setting):
	# fold_duplicate_covers is owned by CoverSubManager._on_setting_changed.
	if setting.property_name == "hide_games_without_covers":
		print("[DataManager] Hide no-cover setting changed to %s" % value)
		# Filter clause changed; count may be different even without data changes.
		database.invalidate_downloaded_games_count_cache()
		# Trigger grid refresh so library view updates filtering
		sync_completed.emit(true, "Hide no-cover games %s" % ("enabled" if value else "disabled"))
	elif setting.property_name == "fold_romm_siblings":
		print("[DataManager] Fold RomM siblings setting changed to %s" % value)
		# Filter clause changed; count may be different even without data changes.
		database.invalidate_downloaded_games_count_cache()
		var folded_count = database.count_folded_sibling_entries()
		# Trigger grid refresh so library view updates filtering
		if value:
			sync_completed.emit(true, "RomM sibling folding enabled - %d entries folded" % folded_count)
		else:
			sync_completed.emit(true, "RomM sibling folding disabled - %d entries restored" % folded_count)
	elif setting.property_name == "enabled_platforms":
		# Platform filter changed; count may be different. Do NOT emit sync_completed
		# here because PlatformsSettingsView updates this setting for each platform
		# during initialization and emitting sync_completed would spam scans.
		database.invalidate_downloaded_games_count_cache()


# ==================== DATABASE READY ====================

func is_database_ready() -> bool:
	return database.is_database_ready()


# ==================== GAME QUERIES ====================

func get_game_by_id(romm_id: int) -> GameResource:
	return database.get_game_by_id(romm_id)


## Map IGDB ids to library romm_ids: {igdb_id: romm_id} for owned matches.
func get_games_by_igdb_ids(igdb_ids: Array) -> Dictionary:
	return database.get_games_by_igdb_ids(igdb_ids)


## Title fallback for related games: {lower_title: romm_id}.
func get_games_by_titles(titles: Array) -> Dictionary:
	return database.get_games_by_titles(titles)


func get_all_games() -> Array[GameResource]:
	return database.get_all_games()


func get_most_recently_played_game() -> GameResource:
	return database.get_most_recently_played_game()


func get_games_by_platform(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	return database.get_games_by_platform(platform_slug, filters)


func get_games_for_shuffle(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	return database.get_games_for_shuffle(platform_slug, filters)


func get_games_for_shuffle_async(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	return await database.get_games_for_shuffle_async(platform_slug, filters)


func get_random_games_for_shuffle_async(platforms: Array[String], filters: Dictionary, limit: int) -> Array[GameResource]:
	return await database.get_random_games_for_shuffle_async(platforms, filters, limit)


func get_random_games_for_shuffle_balanced_async(platforms: Array[String], filters: Dictionary, limit: int, balance: float = 1.0) -> Array[GameResource]:
	return await database.get_random_games_for_shuffle_balanced_async(platforms, filters, limit, balance)


func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true, platform_slug: String = "", filters: Dictionary = {}) -> Array[GameResource]:
	return database.get_games_paginated(offset, limit, sort_field, ascending, platform_slug, filters)


func get_platforms_with_games() -> Array[Dictionary]:
	return database.get_platforms_with_games()


## First-character run lengths for A-Z letter navigation (see database).
func get_title_letter_runs(platform_slug: String = "", filters: Dictionary = {}, search_query: String = "") -> Array[Dictionary]:
	return database.get_title_letter_runs(platform_slug, filters, search_query)


func get_total_games_count(platform_slug: String = "", filters: Dictionary = {}) -> int:
	return database.get_total_games_count(platform_slug, filters)


func search_games_paginated(query: String, offset: int, limit: int, filters: Dictionary = {}) -> Array[GameResource]:
	return database.search_games_paginated(query, offset, limit, filters)


func get_search_results_count(query: String, filters: Dictionary = {}) -> int:
	return database.get_search_results_count(query, filters)


## Distinct library filter values keyed by kind (genre, game_mode, esrb, pegi).
func get_filter_options() -> Dictionary:
	return database.get_filter_options()


func get_downloaded_games_count() -> int:
	return database.get_downloaded_games_count()


## True when the count is cached, i.e. get_downloaded_games_count() won't scan.
func has_cached_downloaded_count() -> bool:
	return database.has_cached_downloaded_count()


func get_downloaded_games_paginated(offset: int, limit: int) -> Array[GameResource]:
	return database.get_downloaded_games_paginated(offset, limit)


func get_random_game() -> GameResource:
	return database.get_random_game()


# ==================== COLLECTIONS ====================

func _on_database_ready_for_collections() -> void:
	"""Sync collections from RomM once the database is ready and RomM is configured."""
	if SystemManager.network and SystemManager.network.is_configured():
		print("[DataManager] Syncing collections at startup...")
		# Favorites are derived from the favorite collection, so sync them after it
		sync_collections(func(_success, _msg):
			# sync_favourites is pure (mutex-guarded) DB work but measures
			# ~175ms; run it on the DB worker so the sync completion frame
			# doesn't hitch.
			if MemorySubManager.is_shutting_down():
				user_props.sync_favourites()
			else:
				MemorySubManager.queue_db_task(func(): user_props.sync_favourites())
		)
		user_props.flush_pending()

func sync_collections(callback: Callable = Callable()) -> void:
	collections.sync_collections(callback)


func get_collections() -> Array[Dictionary]:
	return collections.get_collections()


func get_collection(romm_id: int) -> Dictionary:
	return collections.get_collection(romm_id)


func get_romm_ids_for_collection(romm_id: int) -> Array[int]:
	return collections.get_romm_ids_for_collection(romm_id)


func get_collection_ids_for_rom(romm_id: int) -> Array[int]:
	return collections.get_collection_ids_for_rom(romm_id)


func add_rom_to_collection(romm_id: int, collection_id: int, callback: Callable = Callable()) -> void:
	collections.add_rom_to_collection(romm_id, collection_id, callback)


func get_favorite_collection_id() -> int:
	return collections.get_favorite_collection_id()


func get_games_for_collection_count(romm_id: int) -> int:
	return collections.get_games_for_collection_count(romm_id)


func get_games_for_collection_paginated(romm_id: int, offset: int, limit: int, sort_field: String = "title", ascending: bool = true) -> Array[GameResource]:
	return collections.get_games_for_collection_paginated(romm_id, offset, limit, sort_field, ascending)


# ==================== GAME WRITES ====================

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	return database.update_game(game, callback)


func update_game_title_id(romm_id: int, title_id: String, callback: Callable = Callable()) -> bool:
	return database.update_game_title_id(romm_id, title_id, callback)


func update_game_save_info(romm_id: int, save_id: String, save_usage: String, callback: Callable = Callable()) -> bool:
	return database.update_game_save_info(romm_id, save_id, save_usage, callback)


func update_game_siblings(romm_id: int, siblings: Array[Dictionary], callback: Callable = Callable()) -> bool:
	return database.update_game_siblings(romm_id, siblings, callback)


func update_game_m3u_path(romm_id: int, m3u_path: String, callback: Callable = Callable()) -> bool:
	return database.update_game_m3u_path(romm_id, m3u_path, callback)


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	return database.update_game_last_played(romm_id, timestamp)


## Accumulate session playtime (seconds) onto a game's local total.
func add_game_play_seconds(romm_id: int, seconds: int) -> bool:
	return database.add_game_play_seconds(romm_id, seconds)


func update_game_unwrapped(romm_id: int, unwrapped: bool) -> bool:
	return database.update_game_unwrapped(romm_id, unwrapped)


## Set the local-only Home-hide flag. Never syncs to RomM (unlike
## set_game_user_props/hidden).
func update_game_hidden_from_home(romm_id: int, hidden_from_home: bool) -> bool:
	return database.update_game_hidden_from_home(romm_id, hidden_from_home)


# ==================== ROMM USER PROPS / FAVORITES ====================

## Apply RomM per-user props (status/now_playing/backlogged/hidden) locally and
## push to the server. Set notify=false for silent background updates (launches).
func set_game_user_props(game: GameResource, props: Dictionary, update_last_played: bool = false, notify: bool = true, callback: Callable = Callable()) -> void:
	user_props.set_game_props(game, props, update_last_played, notify, callback)


## Record a completed download for a specific variant (main rom or sibling).
## Per-row truth model: the variant's OWN row is stamped, and the group
## master's downloaded_sibling_ids cache is rebuilt from member rows.
func record_variant_download(game: GameResource, downloaded_id: int, file_path: String, callback: Callable = Callable()) -> void:
	if not database.is_database_ready() or not game:
		if callback.is_valid():
			callback.call(false)
		return
	# In-memory update for immediate UI feedback
	if downloaded_id == game.romm_id:
		game.has_local_copy = true
		game.file_path = file_path
	else:
		game.mark_sibling_downloaded(downloaded_id)
	var group_ids: Array = [game.romm_id]
	for sibling in game.siblings:
		var sid := int(sibling.get("id", 0))
		if sid != 0 and sid != game.romm_id and not group_ids.has(sid):
			group_ids.append(sid)
	database.record_variant_download(group_ids, downloaded_id, file_path, func(result: Dictionary):
		var success: bool = result.get("success", false)
		if success:
			# Mirror the authoritative cache (master rows only)
			if int(result.get("master_id", 0)) == game.romm_id:
				game.downloaded_sibling_ids = result.get("cache", [])
			game_updated.emit(game)
		if callback.is_valid():
			callback.call(success)
	)


## Toggle a game's membership in the RomM "favourites" virtual collection.
func set_game_favorite(game: GameResource, favorite: bool, notify: bool = true, callback: Callable = Callable()) -> void:
	user_props.set_favorite(game, favorite, notify, callback)


func delete_game_download(game: GameResource, callback: Callable = Callable(), force_db_update: bool = false) -> bool:
	"""Delete a downloaded game file and update the database.
	Multi-disc games delete as a unit — every downloaded disc plus the
	generated m3u — mirroring the download side, which fetches every disc.
	Other sibling groups (regional variants etc.) delete only the active
	variant. If force_db_update is true and files don't exist, the DB
	entries are cleared anyway."""
	if not database.is_database_ready() or not game:
		push_error("[DataManager] Cannot delete: DB not ready or game is null")
		if callback.is_valid():
			callback.call(false)
		return false
	if LaunchManager and LaunchManager.sessions.get_live_for_game(game.romm_id):
		push_warning("[DataManager] Refusing to delete a game with a live session: " + game.title)
		SystemManager.notifications.show_notification("Close the current game session before deleting it", SystemManager.notifications.Type.ERROR)
		if callback.is_valid():
			callback.call(false)
		return false

	# Deleting a download changes the downloaded-games count.
	database.invalidate_downloaded_games_count_cache()

	var root_folder = get_setting("games_root_folder")
	var root_path: String = root_folder.value if root_folder else "user://roms/"
	var ps4_delete_lock: Dictionary = {}
	if game.platform_slug == "ps4":
		var owned_root := GameExtraction.ps4_owned_root(root_path + "/ps4", game.get_active_title_id())
		if owned_root != "":
			ps4_delete_lock = OperationLifecycle.acquire(owned_root, "cleanup")
			if ps4_delete_lock.is_empty():
				push_warning("[DataManager] Refusing to delete PS4 download while another operation owns " + owned_root)
				SystemManager.notifications.show_notification("Wait for PS4 extraction to finish before deleting this game", SystemManager.notifications.Type.ERROR)
				if callback.is_valid():
					callback.call(false)
				return false

	# Sibling group (master + all sibling rows) for the group cache rebuild.
	var group_ids: Array = [game.romm_id]
	for sibling in game.siblings:
		var sid := int(sibling.get("id", 0))
		if sid != 0 and sid != game.romm_id and not group_ids.has(sid):
			group_ids.append(sid)

	# Which rows/files to delete. Multi-disc: all downloaded discs (deleting
	# one disc of a set leaves a broken half-install). Otherwise: the active
	# variant only, so regional siblings keep their downloaded state.
	var delete_ids: Array[int] = []
	var delete_file_names: Array[String] = []
	if game.is_multi_disc():
		for entry in game.get_disc_entries():
			if not entry.get("downloaded", false):
				continue
			var entry_id := int(entry.get("id", 0))
			var entry_file := str(entry.get("file_name", ""))
			if entry_id == 0 or entry_file == "":
				continue
			delete_ids.append(entry_id)
			delete_file_names.append(entry_file)
	else:
		var active_id = game.get_active_game_id()
		var active_file_name = ""
		if active_id == game.romm_id:
			active_file_name = game.file_name
		else:
			# Get sibling file name
			for sibling in game.siblings:
				if sibling.get("id", 0) == active_id:
					active_file_name = sibling.get("file_name", "")
					break
		if active_file_name != "":
			delete_ids.append(active_id)
			delete_file_names.append(active_file_name)

	if delete_ids.is_empty():
		if not ps4_delete_lock.is_empty():
			OperationLifecycle.release(ps4_delete_lock)
		push_error("[DataManager] Cannot delete: empty file name")
		if callback.is_valid():
			callback.call(false)
		return false

	# Best-effort file deletion: a missing file never bails the operation
	# (it may be a leftover from a previous partial delete), and inside a
	# multi-disc set one stubborn file shouldn't strand the rest.
	var any_existed := false
	var any_failed := false
	for del_file_name in delete_file_names:
		var abs_path = root_path + "/" + game.platform_slug + "/" + del_file_name
		# File names and platform slugs originate from the RomM server; never
		# delete anything outside the configured games folder.
		if not FSM.is_path_contained(abs_path, root_path):
			push_error("[DataManager] Refusing to delete path outside games folder: " + abs_path)
			any_failed = true
			continue
		if not FSM.file_exists(abs_path):
			continue
		any_existed = true
		if not FSM.delete_file(abs_path):
			any_failed = true
			push_error("[DataManager] Failed to delete file: " + abs_path)
		elif FSM.file_exists(abs_path):
			any_failed = true
			push_error("[DataManager] File still exists after deletion attempt: " + abs_path)

	if not any_existed and not force_db_update:
		if not ps4_delete_lock.is_empty():
			OperationLifecycle.release(ps4_delete_lock)
		push_error("[DataManager] No files found on disk for: " + game.title)
		if callback.is_valid():
			callback.call(false)
		return false

	if any_failed and not force_db_update:
		if not ps4_delete_lock.is_empty():
			OperationLifecycle.release(ps4_delete_lock)
		# Leave the DB untouched so the rows still match what's on disk; the
		# force dialog lets the user clear the entries anyway.
		if callback.is_valid():
			callback.call(false)
		return false

	# The generated playlist goes with the discs (regenerable cruft, so a
	# failed delete here only logs).
	if game.is_multi_disc() and game.m3u_path != "":
		if FSM.file_exists(game.m3u_path) and not FSM.delete_file(game.m3u_path):
			push_error("[DataManager] Failed to delete m3u: " + game.m3u_path)
		game.m3u_path = ""
		update_game_m3u_path(game.romm_id, "")

	print("[DataManager] delete_game_download: clearing variants " + str(delete_ids) + " of game " + game.title + " (romm_id=" + str(game.romm_id) + ")")

	# Clean up extracted game files for platforms that extract during launch
	LaunchManager.cleanup_extracted_game_files(game, ps4_delete_lock)
	if not ps4_delete_lock.is_empty():
		OperationLifecycle.release(ps4_delete_lock)

	# Persist to database and mirror the authoritative result in memory.
	# reconcile_root lets the DB clear group siblings whose files are also
	# gone - otherwise a stale sibling stamp re-fills the group cache and the
	# entry survives the delete on Home.
	database.record_variants_deleted(group_ids, delete_ids, func(result: Dictionary):
		var success: bool = result.get("success", false)
		print("[DataManager] delete_game_download: DB update result for " + game.title + " = " + str(success))
		if success:
			if delete_ids.has(game.romm_id):
				game.has_local_copy = false
				game.file_path = ""
			if int(result.get("master_id", 0)) == game.romm_id:
				game.downloaded_sibling_ids = result.get("cache", [])
			else:
				for deleted_id in delete_ids:
					if deleted_id != game.romm_id:
						game.downloaded_sibling_ids.erase(deleted_id)
			game_updated.emit(game)
		if callback.is_valid():
			callback.call(success)
	, root_path)
	return true


# ==================== SYNC TIMESTAMPS / DEVICE ID ====================

func get_last_sync_time(platform_slug: String = "") -> String:
	return database.get_last_sync_time(platform_slug)


func set_last_sync_time(platform_slug: String, timestamp: String):
	database.set_last_sync_time(platform_slug, timestamp)


func get_romm_device_id() -> String:
	return database.get_romm_device_id()


func set_romm_device_id(device_id: String) -> void:
	database.set_romm_device_id(device_id)


func clear_romm_device_id() -> void:
	database.clear_romm_device_id()


# ==================== SYNC ====================

func sync_enabled_platforms(callback: Callable = Callable(), force_full_sync: bool = false) -> void:
	sync.sync_enabled_platforms(callback, force_full_sync)


func sync_platforms_from_romm(callback: Callable = Callable()):
	sync.sync_platforms_from_romm(callback)


func is_sync_in_progress() -> bool:
	return sync.is_sync_in_progress()


func get_sync_state() -> int:
	return sync.get_sync_state()


func get_sync_state_name() -> String:
	return sync.get_sync_state_name()


func get_current_platform_progress() -> Dictionary:
	return sync.get_current_platform_progress()


# ==================== COVERS / CACHE ====================

func load_image(url: String, callback: Callable = Callable(), high_priority: bool = false):
	cover.load_image(url, callback, high_priority)


func get_cached_image_path(url: String) -> String:
	return cover.get_cached_image_path(url)


func clear_cache():
	cover.clear_cache()


func get_cache_size() -> int:
	return cover.get_cache_size()


func get_random_cached_cover_path() -> String:
	return cover.get_random_cached_cover_path()


func apply_cover_folding_to_database(callback: Callable = Callable()):
	cover.apply_cover_folding_to_database(callback)


# ==================== PLATFORMS / SCAN ====================

func scan_for_downloaded_games(callback: Callable = Callable()) -> void:
	database.scan_for_downloaded_games(callback)


func remove_platform_games(platform_slug: String, callback: Callable = Callable()):
	database.remove_platform_games(platform_slug, callback)


# ==================== SERVER-DELETION RECONCILIATION ====================

## Commits a held above-threshold deletion batch. Returns false when no batch
## is pending for the platform.
func confirm_server_deletions(platform_slug: String) -> bool:
	return sync.confirm_server_deletions(platform_slug)


## Discards a held deletion batch; local rows stay as-is.
func decline_server_deletions(platform_slug: String) -> void:
	sync.decline_server_deletions(platform_slug)


func has_pending_server_deletions(platform_slug: String) -> bool:
	return sync.has_pending_server_deletions(platform_slug)


func get_reconciliation_log(platform_slug: String = "", limit: int = 100) -> Array:
	return database.get_reconciliation_log(platform_slug, limit)


func get_all_platforms() -> Array[PlatformResource]:
	return database.get_all_platforms()


# ==================== SAVE SYNC ====================

func get_save_sync_records(romm_id: int, emulator_id: String = "") -> Array[Dictionary]:
	return save.get_save_sync_records(romm_id, emulator_id)



func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "", local_hash: String = "", server_hash: String = "", local_size: int = 0) -> bool:
	return save.update_save_sync_record(romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot, local_hash, server_hash, local_size)


func delete_save_sync_record(romm_id: int, emulator_id: String, file_name: String, slot: String = "") -> bool:
	return save.delete_save_sync_record(romm_id, emulator_id, file_name, slot)


# ==================== SETTINGS FACADE ====================

func is_settings_loaded() -> bool:
	return settings.settings != null

func get_setting(_name: String) -> SettingsVar:
	return settings.get_setting(_name)

func set_setting(value: Variant, setting: SettingsVar, force: bool = false):
	settings.set_setting(value, setting, force)

func save_settings():
	settings.save_settings()

func get_settings() -> Dictionary:
	return settings.get_settings()

func get_settings_by_subgroup() -> Dictionary:
	return settings.get_settings_by_subgroup()

func enable_setting(_name: String):
	settings.enable_setting(_name)

func disable_setting(_name: String):
	settings.disable_setting(_name)

func load_settings():
	settings.load_settings()

func reset_settings():
	settings.reset_settings()

func list_presets() -> Array[ThemePreset]:
	return settings.list_presets()

func save_preset(preset: ThemePreset) -> bool:
	return settings.save_preset(preset)

func load_preset(preset_path: String) -> ThemePreset:
	return settings.load_preset(preset_path)

func apply_preset(preset: ThemePreset) -> bool:
	return settings.apply_preset(preset)

func export_preset(preset: ThemePreset, export_path: String) -> bool:
	return settings.export_preset(preset, export_path)

func import_preset(import_path: String) -> ThemePreset:
	return settings.import_preset(import_path)

func create_preset_from_current() -> ThemePreset:
	return settings.create_preset_from_current()

func create_preset_from_settings(source_settings: Settings) -> ThemePreset:
	return settings.create_preset_from_settings(source_settings)

func get_presettable_settings() -> Array[SettingsVar]:
	return settings.get_presettable_settings()

func get_setting_default(_name: String) -> Variant:
	return settings.get_setting_default(_name)


# ==================== GAME SAVE FACADE ====================

func auto_upload_saves_for_game(game: GameResource, emulator_id: String):
	game_save.auto_upload_saves_for_game(game, emulator_id)

func auto_download_saves_for_game(game: GameResource, emulator_id: String, on_complete: Callable = Callable()):
	game_save.auto_download_saves_for_game(game, emulator_id, on_complete)

func sync_saves_for_game(game: GameResource, emulator_id: String, callback: Callable = Callable()):
	game_save.sync_saves_for_game(game, emulator_id, callback)

func resolve_default_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return game_save.resolve_default_save_directory(emulator_id, platform_slug, core_id)

func get_save_extensions(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	return game_save.get_save_extensions(emulator_id, platform_slug, core_id)

func get_save_sync_status_text(game: GameResource, emulator_id: String) -> String:
	return game_save.get_save_sync_status_text(game, emulator_id)

func create_pcsx2_superblock(memcard_path: String) -> bool:
	return game_save.create_pcsx2_superblock(memcard_path)

func parse_iso_timestamp(iso_string: String) -> int:
	return game_save.parse_iso_timestamp(iso_string)
