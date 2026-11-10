extends RefCounted

const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")

const BARE_CONTENTS := "bare_contents"
const NAMED_ROOT := "named_root"
const MULTI_ROOT := "multi_root"
const ROUTED_COMPONENTS := "routed_components"
const PLAIN_FILE := "plain_file"

const COMMIT_REPLACE := "replace"
const COMMIT_MERGE := "merge"
const COMMIT_REPLACE_COMPONENTS := "replace_components"
const COMMIT_ROUTED := "routed"
const COMMIT_NONE := "none"

const ZIP_ROOT_NONE := "none"
const ZIP_ROOT_SAVE_ID := "save_id"
const ZIP_ROOT_SOURCE_BASENAME := "source_basename"
const ZIP_ROOT_COMPONENTS := "components"

## Static policy for one emulator architecture/platform. Dynamic paths are
## resolved by GameSaveSubManager into extract_dest, commit_root, and boundary.
static func policy(architecture: String, platform_slug: String) -> Dictionary:
	match architecture:
		"cemu":
			return _layout(NAMED_ROOT, COMMIT_REPLACE, ZIP_ROOT_SAVE_ID)
		"dolphin":
			if platform_slug == "ngc":
				return _layout(BARE_CONTENTS, COMMIT_MERGE, ZIP_ROOT_NONE)
			return _layout(BARE_CONTENTS, COMMIT_REPLACE, ZIP_ROOT_NONE)
		"eden", "pcsx2":
			return _layout(BARE_CONTENTS, COMMIT_REPLACE, ZIP_ROOT_NONE)
		"ppsspp":
			return _layout(MULTI_ROOT, COMMIT_REPLACE_COMPONENTS, ZIP_ROOT_COMPONENTS)
		"vita3k", "rpcs3", "shadps4", "xenia":
			return _layout(NAMED_ROOT, COMMIT_REPLACE, ZIP_ROOT_SOURCE_BASENAME)
		"azahar":
			return _layout(ROUTED_COMPONENTS, COMMIT_ROUTED, ZIP_ROOT_COMPONENTS)
		"retroarch":
			match platform_slug:
				"psp":
					return _layout(MULTI_ROOT, COMMIT_REPLACE_COMPONENTS, ZIP_ROOT_COMPONENTS)
				"3ds":
					return _layout(ROUTED_COMPONENTS, COMMIT_ROUTED, ZIP_ROOT_COMPONENTS)
				"ps2", "ngc", "wii":
					return _layout(BARE_CONTENTS, COMMIT_MERGE, ZIP_ROOT_NONE)
				_:
					return _layout(NAMED_ROOT, COMMIT_REPLACE, ZIP_ROOT_SOURCE_BASENAME)
		_:
			# Preserve the old generic folder-save fallback for unknown families.
			return _layout(BARE_CONTENTS, COMMIT_MERGE, ZIP_ROOT_NONE)

static func _layout(kind: String, commit: String, zip_root_mode: String) -> Dictionary:
	return {
		"kind": kind,
		"commit": commit,
		"zip_root_mode": zip_root_mode,
	}

## Applies one fully extracted archive to its descriptor's owned restore root.
## Shared directories are never replaced wholesale; multi-root saves replace
## only components matching the title prefix.
static func restore_staged_save(staging_dir: String, layout: Dictionary, fsm: GDScript) -> Dictionary:
	if not _folder_has_payload(staging_dir, fsm):
		return {"success": false, "error": "archive contains no save files"}
	var kind := str(layout.get("kind", ""))
	if kind == NAMED_ROOT or kind == MULTI_ROOT:
		var anchor := str(layout.get("archive_root", ""))
		if kind == MULTI_ROOT or bool(layout.get("root_prefix", false)):
			anchor += "*"
		var normalized: Dictionary = fsm.normalize_extraction_layout(staging_dir, {
			"expected_any": [anchor],
			"max_depth": 3,
			"ignored_dirs": ["__MACOSX"],
		})
		var status := str(normalized.get("status", ""))
		if not ["normalized", "already_canonical"].has(status):
			return {"success": false, "error": str(normalized.get("error", status))}

	var named_source_root := ""
	if kind == NAMED_ROOT:
		if bool(layout.get("root_prefix", false)):
			var prefix := str(layout.get("archive_root", "")).to_upper()
			var matches: Array = []
			for entry in fsm.list_dir(staging_dir):
				if entry.to_upper().begins_with(prefix) and fsm.dir_exists(fsm.join_paths(staging_dir, entry)):
					matches.append(entry)
			if matches.size() != 1:
				return {"success": false, "error": "expected exactly one TitleID-prefixed save root"}
			named_source_root = fsm.join_paths(staging_dir, matches[0])
			layout["commit_root"] = fsm.join_paths(str(layout["extract_dest"]), matches[0])
			layout["boundary_path"] = layout["commit_root"]
		else:
			named_source_root = fsm.join_paths(staging_dir, str(layout["archive_root"]))
		if not _folder_has_payload(named_source_root, fsm):
			return {"success": false, "error": "selected save root is empty"}

	var components: Array = []
	if kind == MULTI_ROOT:
		var prefix := str(layout.get("archive_root", "")).to_upper()
		for entry in fsm.list_dir(staging_dir):
			if not entry.to_upper().begins_with(prefix):
				continue
			var source: String = fsm.join_paths(staging_dir, entry)
			if not fsm.dir_exists(source):
				continue
			if not _folder_has_payload(source, fsm):
				return {"success": false, "error": "save component is empty: " + entry}
			components.append({"source": source, "name": entry})
		if components.is_empty():
			return {"success": false, "error": "no save folders match the expected title prefix"}

	match str(layout.get("commit", "")):
		COMMIT_REPLACE:
			var source_root := named_source_root if kind == NAMED_ROOT else staging_dir
			var replaced: Dictionary = fsm.replace_extraction_payload(source_root, str(layout["commit_root"]))
			if str(replaced.get("status", "")) != "replaced":
				return {"success": false, "error": str(replaced.get("error", "replacement failed"))}
		COMMIT_MERGE:
			var commit_root := str(layout["commit_root"])
			var backup: Dictionary = fsm.create_extraction_backup(commit_root)
			if not backup.get("success", false):
				return {"success": false, "error": str(backup.get("error", "backup failed"))}
			var backup_path := str(backup.get("backup_path", ""))
			var merged: Dictionary = fsm.merge_extraction_payload(staging_dir, commit_root)
			if str(merged.get("status", "")) != "committed":
				var rollback_ok := true
				if backup_path == "" and fsm.dir_exists(commit_root):
					rollback_ok = fsm.delete_dir_recursive(commit_root)
				elif not fsm.restore_extraction_backup(backup_path, commit_root):
					rollback_ok = false
				return {"success": false, "error": str(merged.get("error", "merge failed")), "rollback_ok": rollback_ok, "backup_path": backup_path}
			fsm.delete_extraction_backup(backup_path)
		COMMIT_REPLACE_COMPONENTS:
			var committed: Array = []
			for component in components:
				var destination: String = fsm.join_paths(str(layout["commit_root"]), str(component["name"]))
				var replaced: Dictionary = fsm.replace_extraction_payload(str(component["source"]), destination, true)
				var backup_path := str(replaced.get("backup_path", ""))
				if str(replaced.get("status", "")) != "replaced":
					# replace_extraction_payload already attempted this component's
					# own rollback. Do not delete its restored live payload; only
					# previously successful components participate in outer rollback.
					var rollback := _rollback_components(committed, fsm)
					var failed_backups: Array = rollback.get("failed_backups", [])
					var rollback_ok := bool(rollback.get("rollback_ok", false))
					if backup_path != "":
						rollback_ok = false
						failed_backups.append(backup_path)
					return {
						"success": false,
						"error": str(replaced.get("error", "component replacement failed")),
						"rollback_ok": rollback_ok,
						"failed_backups": failed_backups,
					}
				committed.append({"backup_path": backup_path, "destination": destination})
			for prior in committed:
				fsm.delete_extraction_backup(str(prior["backup_path"]))
		_:
			return {"success": false, "error": "unsupported save commit policy"}

	if kind != MULTI_ROOT and not _folder_has_payload(str(layout["commit_root"]), fsm):
		return {"success": false, "error": "restored save is missing or empty"}
	return {"success": true, "error": ""}

static func _folder_has_payload(path: String, fsm: GDScript) -> bool:
	return fsm.dir_exists(path) and fsm.count_files_recursive(path) > 0

## Rolls back both pre-existing components and components created during this
## operation. New components have no backup and are removed outright.
static func _rollback_components(committed: Array, fsm: GDScript) -> Dictionary:
	var rollback_ok := true
	var failed_backups: Array = []
	for index in range(committed.size() - 1, -1, -1):
		var prior: Dictionary = committed[index]
		var backup_path := str(prior.get("backup_path", ""))
		var destination := str(prior["destination"])
		if backup_path == "":
			if fsm.dir_exists(destination) and not fsm.delete_dir_recursive(destination):
				rollback_ok = false
				failed_backups.append(destination)
		elif fsm.restore_extraction_backup(backup_path, destination):
			fsm.delete_extraction_backup(backup_path)
		else:
			rollback_ok = false
			failed_backups.append(backup_path)
	return {"rollback_ok": rollback_ok, "failed_backups": failed_backups}
