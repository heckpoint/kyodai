extends RefCounted

const STAGING_PREFIX := ".kyodai-extract-"
const APP_ANCHORS := ["sce_sys/param.sfo", "eboot.bin"]

## Structural anchors shared by Vita3K and shadPS4 app-style game roots.
static func app_layout_options() -> Dictionary:
	return {
		"expected_all": APP_ANCHORS,
		"max_depth": 4,
		"ignored_dirs": ["__MACOSX"],
	}

## Staging is a sibling of the final owned title root. This keeps commit on the
## same filesystem and lets replace_extraction_payload rename instead of copy.
## An optional owner makes later cleanup attributable without widening the
## legacy anonymous-staging format used by other consumers.
static func staging_path(final_path: String, owner: String = "") -> String:
	var owner_prefix := owner + "-" if owner != "" else ""
	return final_path.get_base_dir().path_join(
		STAGING_PREFIX + owner_prefix + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))

static func is_staging_path(path: String) -> bool:
	return path.get_file().begins_with(STAGING_PREFIX)

## Returns the shallowest CUSAxxxxx segment in an archive/filesystem path.
static func ps4_title_id_candidate(path: String) -> Dictionary:
	var parts := path.replace("\\", "/").split("/", false)
	for i in range(parts.size()):
		var candidate := parts[i]
		if ps4_title_id_is_valid(candidate):
			return {"title_id": candidate, "depth": i}
	return {}

static func ps4_title_id_is_valid(title_id: String) -> bool:
	if title_id.length() != 9 or not title_id.begins_with("CUSA"):
		return false
	for index in range(4, 9):
		var code := title_id.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true

static func ps4_owned_root(games_root: String, title_id: String) -> String:
	if games_root.is_empty() or not ps4_title_id_is_valid(title_id):
		return ""
	var normalized_root := games_root.replace("\\", "/").simplify_path().rstrip("/")
	var candidate := normalized_root.path_join(title_id).simplify_path()
	if candidate == normalized_root or not candidate.begins_with(normalized_root + "/"):
		return ""
	return candidate

static func ps4_artifact_owned(name: String, title_id: String) -> bool:
	if not ps4_title_id_is_valid(title_id):
		return false
	return name.begins_with(STAGING_PREFIX + title_id + "-") \
		or name.begins_with(".kyodai-hoist-" + STAGING_PREFIX + title_id + "-") \
		or name.begins_with(".kyodai-backup-" + title_id + "-")

## Deletes only a PS4 title's canonical owned root and title-tagged operation
## artifacts. Anonymous legacy staging is deliberately left for the aged
## startup janitor because it cannot be attributed safely to one game.
static func cleanup_ps4_extracted_game(games_root: String, title_id: String, fsm: GDScript) -> Dictionary:
	var result := {"success": true, "deleted": [], "errors": []}
	var root := ps4_owned_root(games_root, title_id)
	if root.is_empty():
		result.success = false
		result.errors.append("Invalid PS4 TitleID or games root")
		return result
	var parent := root.get_base_dir()
	var candidates: Array = [root]
	for name in fsm.list_dir(parent):
		if ps4_artifact_owned(str(name), title_id):
			candidates.append(parent.path_join(str(name)))
	for path in candidates:
		if fsm.is_symlink(path):
			result.success = false
			result.errors.append("Refusing linked PS4 cleanup path: " + path)
			continue
		if not fsm.dir_exists(path):
			continue
		if fsm.extraction_tree_has_symlinks(path):
			result.success = false
			result.errors.append("Refusing PS4 cleanup tree containing links: " + path)
			continue
		if fsm.delete_dir_recursive(path):
			result.deleted.append(path)
		else:
			result.success = false
			result.errors.append("Could not delete PS4 cleanup path: " + path)
	return result

static func is_ps3_disc_sfo_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	return normalized.get_file().to_upper() == "PARAM.SFO" and normalized.get_base_dir().get_file().to_upper() == "PS3_GAME"

## Maps an authoritative PS3 PARAM.SFO to its owned game root and layout.
static func ps3_layout_from_sfo(sfo_path: String) -> Dictionary:
	var sfo_dir := sfo_path.get_base_dir()
	var is_disc := sfo_dir.get_file().to_upper() == "PS3_GAME"
	return {
		"game_root": sfo_dir.get_base_dir() if is_disc else sfo_dir,
		"is_disc": is_disc,
	}
