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
static func staging_path(final_path: String) -> String:
	return final_path.get_base_dir().path_join(
		STAGING_PREFIX + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))

static func is_staging_path(path: String) -> bool:
	return path.get_file().begins_with(STAGING_PREFIX)

## Returns the shallowest CUSAxxxxx segment in an archive/filesystem path.
static func ps4_title_id_candidate(path: String) -> Dictionary:
	var parts := path.replace("\\", "/").split("/", false)
	for i in range(parts.size()):
		var candidate := parts[i]
		if candidate.length() != 9 or not candidate.begins_with("CUSA"):
			continue
		var valid := true
		for char_index in range(4, 9):
			var code := candidate.unicode_at(char_index)
			if code < 48 or code > 57:
				valid = false
				break
		if valid:
			return {"title_id": candidate, "depth": i}
	return {}

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
