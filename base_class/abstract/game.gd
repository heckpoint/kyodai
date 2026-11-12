class_name GameResource
extends Resource

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

@export var id: String
@export var romm_id: int
@export var title: String
@export var platform: String
@export var platform_slug: String
@export var cover_url: String
@export var cover_path: String
## Derived from the cached cover during library sync. Kept independently of
## the image cache so palette metadata survives cover eviction.
@export var cover_primary_color: Color = Color.TRANSPARENT
@export var cover_secondary_color: Color = Color.TRANSPARENT
@export var cover_tertiary_color: Color = Color.TRANSPARENT
@export var cover_colors_version: int = 0
## RomM screenshot media URLs (from merged_screenshots), streamed on demand
## by the details sheet; never prefetched or disk-cached beyond the shared
## image cache.
@export var screenshot_urls: PackedStringArray = []
@export var file_name: String
@export var file_path: String
@export var file_size: int
@export var has_local_copy: bool = false
@export var last_updated: String
@export var description: String
@export var genres: Array[String] = []
@export var rating: float = 0.0

## Release date as unix epoch milliseconds (from RomM first_release_date /
## IGDB first_release_date). 0 means unknown.
@export var release_date: int = 0

## Raw IGDB metadata blob from RomM (includes multiplayer_modes, related games, etc.)
@export var igdb_metadata: Dictionary = {}

## IGDB game id from RomM (matches the `id` field of related-game entries).
## 0 means unknown / not IGDB-matched.
@export var igdb_id: int = 0

## Metadata provider IDs from RomM used for conflict-aware sibling folding:
## {"igdb": int, "ss": int, "moby": int, "ra": int, "hasheous": int,
## "launchbox": int, "tgdb": int} — only non-null entries. RomM's sibling_roms
## relation bridges roms that share ANY of these IDs (even transitively), so a
## shared weak ID can chain genuinely different games (e.g. sequels) into one
## sibling group. Conflicting values at the same provider are the signal to
## split a fold group.
@export var provider_ids: Dictionary = {}

## Per-game emulator override (optional)
@export var preferred_emulator_id: String = ""

## Per-game RetroArch core override (optional)
@export var preferred_core_id: String = ""

## Sibling ROMs - variants of the same game (different regions, versions, etc.)
@export var siblings: Array[Dictionary] = []  # [{id, name, file_name, file_size, title_id, is_main_sibling, sort_comparator}, ...]
@export var selected_sibling_id: int = 0  # 0 means use this game itself

## Whether this is the "master" entry shown in the library view
@export var is_master_entry: bool = true

## Whether this game has cover art (used to hide games without covers from library view)
@export var has_cover_art: bool = true

## Timestamp of when this game was last played (ISO format)
@export var last_played: String = ""

## Total seconds spent playing this game (accumulated locally per session;
## the server payload never provides it, so sync preserves the local value)
@export var play_seconds: int = 0

## Whether the "present wrap" overlay has been unwrapped (first focus).
## Persists so a wrapped game stays unwrapped across restarts even if never launched.
@export var unwrapped: bool = false

## RomM per-user play state (rom_user): status is one of "", "incomplete",
## "finished", "completed_100", "retired", "never_playing"
@export var status: String = ""
@export var now_playing: bool = false
@export var backlogged: bool = false
@export var hidden: bool = false

## Whether this game is hidden from the Home view only (local-only flag, never
## synced to RomM). Still appears in Library, search, collections, shuffle.
@export var hidden_from_home: bool = false

## Whether this game is in the user's RomM "favourites" virtual collection
@export var is_favorite: bool = false

## Platform-specific Title ID (for Vita, PS3, etc.)
@export var title_id: String = ""

## On-disk save folder/file name (from sigil; equals title_id on most platforms,
## diverges for PS2 region prefixes and 3DS nested paths)
@export var save_id: String = ""

## How save_id is laid out on disk: folder-exact, folder-prefix, file-exact,
## file-prefix, folder-split (sigil usage classification)
@export var save_usage: String = ""

## Tracks which sibling IDs have been downloaded locally
## Array of sibling IDs that have local copies
@export var downloaded_sibling_ids: Array[int] = []

## Cover grouping fields for "Fold Duplicate Covers" feature
## Games with identical covers are grouped together with a cover_group_id
@export var cover_group_id: String = ""  # Empty if no duplicate covers, otherwise hash of cover_url
@export var cover_group_master: bool = true  # Is this the master of its cover group?

## Game source type: "romm" (default), "steam", etc.
@export var source: String = "romm"

## Path to the generated .m3u playlist for multi-disc games (empty if none)
@export var m3u_path: String = ""

## Steam App ID for Steam games (source == "steam")
@export var steam_app_id: int = 0

## Transient: RomM's own "main sibling" flag for this rom (rom_user.is_main_sibling),
## captured during sync to pick the canonical master entry for a sibling group.
var romm_is_main_sibling: bool = false

## Returns the ID of the game/sibling that should be used (for downloads, etc.)
func get_active_game_id() -> int:
	if selected_sibling_id != 0:
		return selected_sibling_id
	return romm_id

## Returns the title_id of the active game/sibling
func get_active_title_id() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("title_id", "")
	return title_id

## Sets the title_id for a specific sibling
func set_sibling_title_id(sibling_id: int, new_title_id: String) -> void:
	if sibling_id == romm_id:
		title_id = new_title_id
		return
	for sibling in siblings:
		if sibling.get("id", 0) == sibling_id:
			sibling["title_id"] = new_title_id
			return

## Returns the save_id of the active game/sibling
func get_active_save_id() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("save_id", "")
	return save_id

## Returns the save usage classification of the active game/sibling
func get_active_save_usage() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("save_usage", "")
	return save_usage

## Sets the save_id/save_usage for a specific sibling
func set_sibling_save_info(sibling_id: int, new_save_id: String, new_save_usage: String) -> void:
	if sibling_id == romm_id:
		save_id = new_save_id
		save_usage = new_save_usage
		return
	for sibling in siblings:
		if sibling.get("id", 0) == sibling_id:
			sibling["save_id"] = new_save_id
			sibling["save_usage"] = new_save_usage
			return

## Returns the file name of the active game/sibling
func get_active_file_name() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("file_name", file_name)
	return file_name

## Returns the file size of the active game/sibling
func get_active_file_size() -> int:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("file_size", file_size)
	return file_size

## Returns true if the currently selected sibling (or main game) has been downloaded
func is_active_variant_downloaded() -> bool:
	var active_id = get_active_game_id()
	if active_id == romm_id:
		return has_local_copy
	return active_id in downloaded_sibling_ids

## Marks a specific sibling as downloaded
func mark_sibling_downloaded(sibling_id: int):
	if sibling_id == romm_id:
		has_local_copy = true
	elif not sibling_id in downloaded_sibling_ids:
		downloaded_sibling_ids.append(sibling_id)

## Returns the file path for a specific sibling (constructs it based on current file_path pattern)
func get_sibling_file_path(sibling_id: int, root_folder: String) -> String:
	if sibling_id == romm_id:
		return file_path
	
	for sibling in siblings:
		if sibling.get("id", 0) == sibling_id:
			var sibling_file_name = sibling.get("file_name", "")
			if sibling_file_name != "":
				return FSM.join_paths(root_folder, platform_slug, sibling_file_name)
	
	return file_path

func get_display_name() -> String:
	return title if title else file_name

## Parses a disc number from a "(Disc N)" tag in a file name. Returns 0 if none.
static func parse_disc_number(p_name: String) -> int:
	var regex := RegEx.new()
	regex.compile("(?i)\\(disc\\s*(\\d+)\\)")
	var m := regex.search(p_name)
	if m:
		return m.get_string(1).to_int()
	return 0

## Strips all parenthesized/bracketed tags from a file/game name (RomM's
## fs_name_no_tags semantics) and normalizes case/whitespace, so base titles
## can be compared across regional/disc variants. A trailing file extension
## is dropped first (main rom names carry one, sibling names don't), but only
## a strict ".ext" suffix so titles containing dots ("Game Vol. 2") survive.
static func strip_name_tags(p_name: String) -> String:
	var ext_regex := RegEx.new()
	ext_regex.compile("\\.[A-Za-z0-9]{1,5}$")
	var stripped: String = ext_regex.sub(p_name.strip_edges(), "")
	var tag_regex := RegEx.new()
	tag_regex.compile("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]")
	# RegEx.sub replaces only the first match; loop to strip every tag.
	while true:
		var next := tag_regex.sub(stripped, "")
		if next == stripped:
			break
		stripped = next
	return stripped.strip_edges().to_lower()

## Returns true if this game has 2+ disc-tagged entries (main rom + siblings)
func is_multi_disc() -> bool:
	return get_disc_entries().size() >= 2

## Returns all disc entries (main rom + disc-tagged siblings), sorted by disc number.
## Only disc-tagged entries are included - untagged siblings (regional variants
## etc.) are never treated as discs. If the main rom lacks a disc tag but at
## least one sibling has one, the main rom counts as disc 1.
## Siblings whose tag-stripped base title differs from the main rom's (e.g. a
## sequel RomM bridged into the sibling group via a shared metadata ID) are
## never treated as discs of this game.
## Each entry: {id, file_name, file_size, disc_number, downloaded}
func get_disc_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var main_disc := parse_disc_number(file_name)
	var main_base := strip_name_tags(file_name)
	for sibling in siblings:
		var disc_number: int = sibling.get("disc_number", 0)
		if disc_number <= 0:
			disc_number = parse_disc_number(str(sibling.get("file_name", "")))
		if disc_number <= 0:
			disc_number = parse_disc_number(str(sibling.get("name", "")))
		if disc_number <= 0:
			continue
		# Base-title guard: only same-title siblings can be discs of this game.
		var sibling_base := strip_name_tags(str(sibling.get("file_name", "")))
		if sibling_base == "":
			sibling_base = strip_name_tags(str(sibling.get("name", "")))
		if main_base != "" and sibling_base != "" and sibling_base != main_base:
			continue
		var sibling_id: int = sibling.get("id", 0)
		entries.append({
			"id": sibling_id,
			"file_name": str(sibling.get("file_name", "")),
			"file_size": int(sibling.get("file_size", 0)),
			"name_resolved": sibling.get("name_resolved", false),
			"disc_number": disc_number,
			"downloaded": sibling_id in downloaded_sibling_ids
		})
	if main_disc > 0:
		entries.append({
			"id": romm_id,
			"file_name": file_name,
			"file_size": file_size,
			"name_resolved": true,
			"disc_number": main_disc,
			"downloaded": has_local_copy
		})
	elif not entries.is_empty():
		# Untagged main rom alongside disc-tagged siblings: implicitly disc 1
		entries.append({
			"id": romm_id,
			"file_name": file_name,
			"file_size": file_size,
			"name_resolved": true,
			"disc_number": 1,
			"downloaded": has_local_copy
		})
	entries.sort_custom(func(a, b): return a["disc_number"] < b["disc_number"])
	return entries

## Returns the disc number of the currently selected variant (1 if main/none)
func get_active_disc_number() -> int:
	if selected_sibling_id == 0:
		return 1
	for entry in get_disc_entries():
		if entry["id"] == selected_sibling_id:
			return entry["disc_number"]
	return 1

## Returns true if every disc of a multi-disc game has been downloaded
func are_all_discs_downloaded() -> bool:
	var entries := get_disc_entries()
	if entries.size() < 2:
		return false
	for entry in entries:
		if not entry["downloaded"]:
			return false
	return true

func get_cover_image() -> Texture2D:
	if cover_path and FSM.file_exists(cover_path):
		var img = Image.new()
		var error = img.load(cover_path)
		if error == OK and not img.is_empty():
			return SystemManager.memory.create_texture_from_image(img)
	return null

## Returns the IGDB multiplayer_modes list if present
func get_igdb_multiplayer_modes() -> Array[Dictionary]:
	if igdb_metadata.has("multiplayer_modes") and igdb_metadata["multiplayer_modes"] is Array:
		var result: Array[Dictionary] = []
		for item in igdb_metadata["multiplayer_modes"]:
			if item is Dictionary:
				result.append(item)
		return result
	return []

## Returns the IGDB companies list (developer/publisher names) if present
func get_igdb_companies() -> Array[String]:
	var result: Array[String] = []
	if igdb_metadata is Dictionary and igdb_metadata.has("companies") and igdb_metadata["companies"] is Array:
		for item in igdb_metadata["companies"]:
			result.append(str(item))
	return result

## Returns combined IGDB related games from all relation categories
func get_igdb_related_games() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not igdb_metadata is Dictionary:
		return result
	
	var categories = [
		"expansions",
		"dlcs",
		"remasters",
		"remakes",
		"expanded_games",
		"ports",
		"similar_games",
	]
	
	for category in categories:
		if igdb_metadata.has(category) and igdb_metadata[category] is Array:
			for item in igdb_metadata[category]:
				if item is Dictionary:
					result.append(item)
	return result
