extends RefCounted

## Registry-to-layout policy for emulator archive extraction. Keeping this
## separate lets tests cover every strip_top_directory install configuration
## without starting LaunchManager or an actual emulator install.
static func layout_options(extract_config: Dictionary) -> Dictionary:
	var expected := expected_anchors(extract_config)
	var target_folder := str(extract_config.get("flatten_target", ""))
	return {
		"expected_any": expected,
		"target_folder": target_folder,
		# Historical installer behavior treated a missing flatten target as a
		# no-op. In staging that becomes an already-canonical flat layout.
		"allow_missing_target": bool(extract_config.get("allow_missing_target", true)),
		"strip_single_root": expected.is_empty() and target_folder == "",
		"max_depth": 3,
		"ignored_dirs": ["__MACOSX"],
	}

## Simple file validation doubles as the expected payload root. Validations
## outside the extraction root remain live-install checks only.
static func expected_anchors(extract_config: Dictionary) -> Array:
	if str(extract_config.get("extract_to", ".")) != ".":
		return []
	var explicit_anchor := str(extract_config.get("payload_anchor", "")).replace("\\", "/").trim_prefix("./")
	if explicit_anchor != "":
		if not explicit_anchor.begins_with("/") and not explicit_anchor.contains("{") and not explicit_anchor.contains(":"):
			return [explicit_anchor]
		return []
	var validate: Dictionary = extract_config.get("validate", {})
	if validate.get("action_type", "") != "file_exists":
		return []
	var file_path := str(validate.get("file", "")).replace("\\", "/").trim_prefix("./")
	if file_path == "" or file_path.begins_with("/") or file_path.contains("{") or file_path.contains(":"):
		return []
	return [file_path]
