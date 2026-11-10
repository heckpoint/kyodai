extends RefCounted

## Pure extraction-layout discovery. Consumers provide a snapshot of relative
## file/directory paths; this script selects a payload root without touching the
## filesystem. FileSystemSubManager owns collection and any subsequent moves.

const STATUS_ALREADY_CANONICAL := "already_canonical"
const STATUS_HOIST := "hoist"
const STATUS_PAYLOAD_MISSING := "payload_missing"
const STATUS_AMBIGUOUS := "ambiguous"
const STATUS_UNSAFE_ENTRY := "unsafe_entry"

## Selects a payload root from entries shaped as {path: String, is_dir: bool}.
## Plain strings are also accepted and represent files. Supported options:
##   expected_any: Array - at least one relative file/dir/glob anchor must match
##   expected_all: Array - every relative file/dir/glob anchor must match
##   target_folder: String - exact/glob immediate child directory to hoist
##   allow_missing_target: bool - accept a nonempty flat root when target is absent
##   strip_single_root: bool - anchorless fallback for legacy one-wrapper zips
##   max_depth: int - deepest wrapper directory to consider (default 3)
##   ignored_dirs: Array - directory basenames to exclude (default __MACOSX)
##   case_sensitive: bool - anchor/target matching policy (default true)
static func plan(entries: Array, options: Dictionary = {}) -> Dictionary:
	var index := _build_index(entries, options)
	if not index.get("ok", false):
		return _failure(STATUS_UNSAFE_ENTRY, str(index.get("error", "Invalid extraction entries")))

	var expected_check := _clean_anchors(options)
	if not expected_check.get("ok", false):
		return _failure(STATUS_UNSAFE_ENTRY, str(expected_check.get("error", "Invalid expected anchor")))
	var expected_any: Array = expected_check["any"]
	var expected_all: Array = expected_check["all"]
	var case_sensitive := bool(options.get("case_sensitive", true))
	var paths: Dictionary = index["paths"]
	var directories: Dictionary = index["directories"]

	var target_folder := str(options.get("target_folder", "")).strip_edges()
	if target_folder != "":
		return _plan_target_folder(
			target_folder, directories, case_sensitive, paths, bool(options.get("allow_missing_target", false)), expected_any, expected_all)

	if not expected_any.is_empty() or not expected_all.is_empty():
		var max_depth := maxi(0, int(options.get("max_depth", 3)))
		for depth in range(max_depth + 1):
			var candidates: Array = []
			var matches_by_candidate := {}
			for dir_path in directories:
				if _depth(dir_path) != depth:
					continue
				var matched := _matched_anchors(dir_path, expected_any, expected_all, paths, case_sensitive)
				if matched.is_empty():
					continue
				candidates.append(dir_path)
				matches_by_candidate[dir_path] = matched
			candidates.sort()
			if candidates.size() == 1:
				var payload_root: String = candidates[0]
				var status := STATUS_ALREADY_CANONICAL if payload_root == "" else STATUS_HOIST
				return _success(status, payload_root, matches_by_candidate[payload_root])
			if candidates.size() > 1:
				var result := _failure(STATUS_AMBIGUOUS, "Multiple extraction payloads match the expected layout")
				result["candidates"] = candidates
				return result

	# With no anchors there is no safe way to choose between sibling payloads.
	# Preserve the legacy installer behavior: exactly one top-level directory and
	# no top-level files can be stripped by one level.
	if expected_any.is_empty() and expected_all.is_empty() and bool(options.get("strip_single_root", false)):
		var root_entries: Array = []
		for path in paths:
			if path != "" and not str(path).contains("/"):
				root_entries.append(path)
		root_entries.sort()
		if root_entries.size() == 1 and bool(paths[root_entries[0]]):
			return _success(STATUS_HOIST, root_entries[0], [])
		if root_entries.size() > 1:
			var result := _failure(STATUS_AMBIGUOUS, "Cannot choose between multiple top-level extraction entries")
			result["candidates"] = root_entries
			return result

	return _failure(STATUS_PAYLOAD_MISSING, "Expected extraction payload was not found")

static func _plan_target_folder(target_folder: String, directories: Dictionary, case_sensitive: bool, paths: Dictionary, allow_missing_target: bool, expected_any: Array, expected_all: Array) -> Dictionary:
	var candidates: Array = []
	var matches_by_candidate := {}
	for dir_path in directories:
		if _depth(dir_path) != 1:
			continue
		var matches: bool = dir_path.match(target_folder) if case_sensitive else dir_path.matchn(target_folder)
		if not matches:
			continue
		var matched := _matched_anchors(dir_path, expected_any, expected_all, paths, case_sensitive)
		if (not expected_any.is_empty() or not expected_all.is_empty()) and matched.is_empty():
			continue
		candidates.append(dir_path)
		matches_by_candidate[dir_path] = matched
	candidates.sort()
	if candidates.size() == 1:
		return _success(STATUS_HOIST, candidates[0], matches_by_candidate[candidates[0]])
	if candidates.size() > 1:
		var result := _failure(STATUS_AMBIGUOUS, "Multiple directories match flatten_target: " + target_folder)
		result["candidates"] = candidates
		return result
	if allow_missing_target:
		if expected_any.is_empty() and expected_all.is_empty() and not paths.is_empty():
			return _success(STATUS_ALREADY_CANONICAL, "", [])
		var root_matches := _matched_anchors("", expected_any, expected_all, paths, case_sensitive)
		if not root_matches.is_empty():
			return _success(STATUS_ALREADY_CANONICAL, "", root_matches)
	return _failure(STATUS_PAYLOAD_MISSING, "No directory matches flatten_target: " + target_folder)

static func _matched_anchors(root: String, expected_any: Array, expected_all: Array, paths: Dictionary, case_sensitive: bool) -> Array:
	var matched: Array = []
	for anchor in expected_any:
		if _anchor_exists(root, anchor, paths, case_sensitive):
			matched.append(anchor)
	if not expected_any.is_empty() and matched.is_empty():
		return []
	for anchor in expected_all:
		if not _anchor_exists(root, anchor, paths, case_sensitive):
			return []
		matched.append(anchor)
	return matched

static func _anchor_exists(root: String, anchor: String, paths: Dictionary, case_sensitive: bool) -> bool:
	var full_path := anchor if root == "" else root + "/" + anchor
	if not anchor.contains("*") and not anchor.contains("?"):
		if case_sensitive:
			return paths.has(full_path)
		var folded := full_path.to_lower()
		for path in paths:
			if str(path).to_lower() == folded:
				return true
		return false
	for path in paths:
		if _path_matches(full_path, str(path), case_sensitive):
			return true
	return false

static func _path_matches(pattern: String, path: String, case_sensitive: bool) -> bool:
	var pattern_parts := pattern.split("/", false)
	var path_parts := path.split("/", false)
	if pattern_parts.size() != path_parts.size():
		return false
	for i in range(pattern_parts.size()):
		var matches: bool = path_parts[i].match(pattern_parts[i]) if case_sensitive else path_parts[i].matchn(pattern_parts[i])
		if not matches:
			return false
	return true

static func _build_index(entries: Array, options: Dictionary) -> Dictionary:
	var paths := {}
	var directories := {"": true}
	var ignored_dirs: Array = options.get("ignored_dirs", ["__MACOSX"])
	var case_sensitive := bool(options.get("case_sensitive", true))
	for entry in entries:
		var raw_path := ""
		var is_dir := false
		if entry is Dictionary:
			raw_path = str(entry.get("path", ""))
			is_dir = bool(entry.get("is_dir", false))
		else:
			raw_path = str(entry)
		if raw_path.ends_with("/") or raw_path.ends_with("\\"):
			is_dir = true
		var normalized := _normalize_relative(raw_path)
		if not normalized.get("ok", false):
			return normalized
		var path := str(normalized["path"])
		if path == "" or _is_ignored(path, ignored_dirs, case_sensitive):
			continue

		var parts := path.split("/", false)
		var parent := ""
		for i in range(parts.size() - 1):
			var child := parts[i] if parent == "" else parent + "/" + parts[i]
			if paths.has(child) and not bool(paths[child]):
				return {"ok": false, "error": "File/directory collision at: " + child}
			paths[child] = true
			directories[child] = true
			parent = child

		if paths.has(path) and bool(paths[path]) != is_dir:
			return {"ok": false, "error": "File/directory collision at: " + path}
		paths[path] = is_dir
		if is_dir:
			directories[path] = true
	return {"ok": true, "paths": paths, "directories": directories}

static func _clean_anchors(options: Dictionary) -> Dictionary:
	var result := {"ok": true, "any": [], "all": []}
	for key in ["any", "all"]:
		for value in options.get("expected_" + key, []):
			var normalized := _normalize_relative(str(value).strip_edges())
			if not normalized.get("ok", false) or str(normalized.get("path", "")) == "":
				return {"ok": false, "error": "Unsafe or empty expected anchor: " + str(value)}
			var anchor := str(normalized["path"])
			if not anchor in result[key]:
				result[key].append(anchor)
	return result

static func _normalize_relative(raw_path: String) -> Dictionary:
	if raw_path.contains("\u0000"):
		return {"ok": false, "error": "NUL in extraction path"}
	var path := raw_path.replace("\\", "/")
	if path.begins_with("/"):
		return {"ok": false, "error": "Absolute extraction path: " + raw_path}
	var clean: Array[String] = []
	for segment in path.split("/", false):
		if segment == ".":
			continue
		if segment == "..":
			return {"ok": false, "error": "Traversal in extraction path: " + raw_path}
		clean.append(segment)
	if not clean.is_empty() and clean[0].contains(":"):
		return {"ok": false, "error": "Drive-qualified extraction path: " + raw_path}
	return {"ok": true, "path": "/".join(clean)}

static func _is_ignored(path: String, ignored_dirs: Array, case_sensitive: bool) -> bool:
	for segment in path.split("/", false):
		for ignored in ignored_dirs:
			var ignored_name := str(ignored)
			if segment == ignored_name or (not case_sensitive and segment.to_lower() == ignored_name.to_lower()):
				return true
	return false

static func _depth(path: String) -> int:
	return 0 if path == "" else path.get_slice_count("/")

static func _success(status: String, payload_root: String, matched: Array) -> Dictionary:
	return {
		"status": status,
		"payload_root": payload_root,
		"depth": _depth(payload_root),
		"matched_anchors": matched,
		"candidates": [],
		"error": "",
	}

static func _failure(status: String, error: String) -> Dictionary:
	return {
		"status": status,
		"payload_root": "",
		"depth": 0,
		"matched_anchors": [],
		"candidates": [],
		"error": error,
	}
