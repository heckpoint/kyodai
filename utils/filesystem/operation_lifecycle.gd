extends RefCounted

## Cross-process destination locks and conservative operation-artifact cleanup.
## Lock creation uses atomic mkdir, not file_exists + WRITE (which is racy).
## Cleanup is intentionally manifest-driven after commit_started: backups and
## recovery trees may contain the only pre-commit copy and are never disposable
## merely because they are old.

const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")
const LOCK_ROOT := "user://temp/operations/locks"
const QUARANTINE_ROOT := "user://temp/operations/stale"
const DEFAULT_STALE_AGE_SECONDS := 7 * 24 * 60 * 60

static var _held: Dictionary = {}
static var _mutex: Mutex = Mutex.new()

static func destination_key(path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path().rstrip("/")
	if OS.get_name() == "Windows" or OS.get_name() == "macOS":
		normalized = normalized.to_lower()
	return normalized

static func _lock_dir(destination: String) -> String:
	return LOCK_ROOT + "/" + destination_key(destination).sha256_text() + ".lock"

static func acquire(destination: String, phase: String = "operation", wait_ms: int = 0, artifacts: Array = [], parent_token: Dictionary = {}) -> Dictionary:
	if destination_key(destination).is_empty():
		return {}
	var key := destination_key(destination)
	var started := Time.get_ticks_msec()
	while true:
		_mutex.lock()
		if _held.has(key):
			var existing: Dictionary = _held[key]
			var parent_id := str(parent_token.get("operation_id", ""))
			if parent_id != "" and parent_id == str(existing["token"].get("operation_id", "")):
				existing["depth"] = int(existing.get("depth", 1)) + 1
				var nested: Dictionary = existing["token"].duplicate(true)
				nested["nested"] = true
				_mutex.unlock()
				return nested
			_mutex.unlock()
			if Time.get_ticks_msec() - started >= wait_ms:
				return {}
			OS.delay_msec(25)
			continue
		_mutex.unlock()

		DirAccess.make_dir_recursive_absolute(LOCK_ROOT)
		var lock_dir := _lock_dir(destination)
		if DirAccess.make_dir_absolute(lock_dir) == OK:
			var token := {
				"operation_id": _new_operation_id(),
				"pid": OS.get_process_id(),
				"destination": destination,
				"phase": phase,
				"started_at": Time.get_unix_time_from_system(),
				"heartbeat": Time.get_unix_time_from_system(),
				"artifacts": artifacts.duplicate(),
				"lock_dir": lock_dir,
			}
			if not _write_owner(lock_dir, token):
				DirAccess.remove_absolute(lock_dir)
				return {}
			_mutex.lock()
			_held[key] = {"token": token.duplicate(true), "depth": 1}
			_mutex.unlock()
			return token

		var owner := read_owner(lock_dir)
		var empty_stale := owner.is_empty() and _is_stale_path(lock_dir, DEFAULT_STALE_AGE_SECONDS)
		if (not owner.is_empty() and not _owner_alive(owner)) or empty_stale:
			# Reclamation is atomic. Another cleaner cannot reclaim the same lock.
			DirAccess.make_dir_recursive_absolute(QUARANTINE_ROOT)
			var quarantine := QUARANTINE_ROOT + "/" + lock_dir.get_file() + "-" + _new_operation_id()
			if DirAccess.rename_absolute(lock_dir, quarantine) == OK:
				_process_quarantine(quarantine, owner, {"deleted": [], "preserved": []})
				continue
		if Time.get_ticks_msec() - started >= wait_ms:
			return {}
		OS.delay_msec(25)
	return {}

static func is_locked(destination: String) -> bool:
	if destination_key(destination).is_empty():
		return false
	return DirAccess.dir_exists_absolute(_lock_dir(destination))

static func release(token: Dictionary) -> void:
	var destination := str(token.get("destination", ""))
	var key := destination_key(destination)
	if key.is_empty():
		return
	_mutex.lock()
	if not _held.has(key):
		_mutex.unlock()
		return
	var existing: Dictionary = _held[key]
	var depth := int(existing.get("depth", 1)) - 1
	if depth > 0:
		existing["depth"] = depth
		_mutex.unlock()
		return
	var owner_token: Dictionary = existing["token"]
	_held.erase(key)
	_mutex.unlock()
	if str(owner_token.get("operation_id", "")) != str(token.get("operation_id", "")):
		return
	if str(owner_token.get("phase", "")) == "rollback_failed":
		_quarantine_owner(owner_token)
		return
	var lock_dir := str(owner_token.get("lock_dir", ""))
	var current := read_owner(lock_dir)
	if str(current.get("operation_id", "")) == str(owner_token.get("operation_id", "")):
		DirAccess.remove_absolute(lock_dir + "/owner.json")
		DirAccess.remove_absolute(lock_dir)

static func update_phase(token: Dictionary, phase: String, artifacts: Array = []) -> void:
	var key := destination_key(str(token.get("destination", "")))
	_mutex.lock()
	if not _held.has(key):
		_mutex.unlock()
		return
	var current: Dictionary = _held[key]["token"]
	if str(current.get("operation_id", "")) != str(token.get("operation_id", "")):
		_mutex.unlock()
		return
	current["phase"] = phase
	current["heartbeat"] = Time.get_unix_time_from_system()
	if not artifacts.is_empty():
		current["artifacts"] = artifacts.duplicate()
	var updated := current.duplicate(true)
	_held[key]["token"] = updated
	_mutex.unlock()
	_write_owner(str(updated.get("lock_dir", "")), updated)

static func track_artifact(token: Dictionary, artifact: String) -> void:
	if artifact.is_empty():
		return
	var key := destination_key(str(token.get("destination", "")))
	_mutex.lock()
	if not _held.has(key):
		_mutex.unlock()
		return
	var current: Dictionary = _held[key]["token"]
	if str(current.get("operation_id", "")) != str(token.get("operation_id", "")):
		_mutex.unlock()
		return
	var artifacts: Array = current.get("artifacts", [])
	if not artifacts.has(artifact):
		artifacts.append(artifact)
	current["artifacts"] = artifacts
	current["heartbeat"] = Time.get_unix_time_from_system()
	var updated := current.duplicate(true)
	_held[key]["token"] = updated
	_mutex.unlock()
	_write_owner(str(updated.get("lock_dir", "")), updated)

static func preserve_recovery(token: Dictionary, recovery_path: String, additional_artifacts: Array = []) -> void:
	var artifacts: Array = token.get("artifacts", []).duplicate()
	if recovery_path != "" and not artifacts.has(recovery_path):
		artifacts.append(recovery_path)
	for artifact in additional_artifacts:
		var path := str(artifact)
		if path != "" and not artifacts.has(path):
			artifacts.append(path)
	update_phase(token, "rollback_failed", artifacts)

static func _quarantine_owner(token: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(QUARANTINE_ROOT)
	var lock_dir := str(token.get("lock_dir", ""))
	var quarantine := QUARANTINE_ROOT + "/" + lock_dir.get_file() + "-" + _new_operation_id()
	if not _write_owner(lock_dir, token):
		return false
	return DirAccess.rename_absolute(lock_dir, quarantine) == OK

static func read_owner(lock_dir: String) -> Dictionary:
	var file := FileAccess.open(lock_dir + "/owner.json", FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static func _write_owner(lock_dir: String, token: Dictionary) -> bool:
	var temporary := lock_dir + "/owner.tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(token))
	file.close()
	return DirAccess.rename_absolute(temporary, lock_dir + "/owner.json") == OK

static func _owner_alive(owner: Dictionary) -> bool:
	var pid := int(owner.get("pid", 0))
	# Unknown owners are treated as live. Deleting on uncertain liveness could
	# destroy an active operation's only rollback data.
	return pid == OS.get_process_id() or pid <= 0 or OS.is_process_running(pid)

static func _new_operation_id() -> String:
	return "%d-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec(), randi()]

static func cleanup_stale_operations(max_age_seconds: int = DEFAULT_STALE_AGE_SECONDS) -> Dictionary:
	var result := {"locks": 0, "reclaimed": 0, "deleted": [], "preserved": []}
	var now := Time.get_unix_time_from_system()
	for lock_dir in _child_dirs(LOCK_ROOT):
		var owner := read_owner(lock_dir)
		if owner.is_empty() and not _is_stale_path(lock_dir, max_age_seconds):
			result.preserved.append(lock_dir)
			continue
		if not owner.is_empty() and _owner_alive(owner):
			result.preserved.append(lock_dir)
			continue
		var age := 0.0
		if not owner.is_empty():
			age = now - float(owner.get("heartbeat", owner.get("started_at", 0)))
		else:
			age = now - _modified_time(lock_dir)
		if age < max_age_seconds:
			result.preserved.append(lock_dir)
			continue
		DirAccess.make_dir_recursive_absolute(QUARANTINE_ROOT)
		var quarantine := QUARANTINE_ROOT + "/" + lock_dir.get_file() + "-" + _new_operation_id()
		if DirAccess.rename_absolute(lock_dir, quarantine) != OK:
			result.preserved.append(lock_dir)
			continue
		result.reclaimed += 1
		_process_quarantine(quarantine, owner, result)
	return result

static func _process_quarantine(quarantine: String, owner: Dictionary, result: Dictionary) -> bool:
	if owner.is_empty():
		DirAccess.remove_absolute(quarantine)
		return true
	if str(owner.get("phase", "")) == "commit_started" or str(owner.get("phase", "")) == "rollback_failed":
		result.preserved.append(quarantine)
		return false
	var preserved_before: int = result.preserved.size()
	for artifact in owner.get("artifacts", []):
		if _artifact_cleanup_allowed(str(artifact)):
			_delete_artifact(str(artifact), result)
		else:
			result.preserved.append(str(artifact))
	# Only discard the manifest when every pre-commit artifact is gone.
	if result.preserved.size() != preserved_before:
		return false
	DirAccess.remove_absolute(quarantine + "/owner.json")
	DirAccess.remove_absolute(quarantine)
	return true

static func cleanup_stale_untracked(roots: Array, max_age_seconds: int = DEFAULT_STALE_AGE_SECONDS) -> Dictionary:
	var result := {"deleted": [], "preserved": []}
	var referenced := _all_manifest_artifacts()
	var now := Time.get_unix_time_from_system()
	for root in roots:
		for path in _child_dirs(str(root)) + _child_files(str(root)):
			if not _is_operation_artifact_name(path.get_file()):
				continue
			if referenced.has(path):
				result.preserved.append(path)
				continue
			var modified := _modified_time(path)
			if modified <= 0 or now - modified < max_age_seconds:
				result.preserved.append(path)
				continue
			_delete_artifact(path, result)
	return result

static func _all_manifest_artifacts() -> Dictionary:
	var referenced := {}
	for lock_dir in _child_dirs(LOCK_ROOT) + _child_dirs(QUARANTINE_ROOT):
		var owner := read_owner(lock_dir)
		for artifact in owner.get("artifacts", []):
			referenced[str(artifact)] = true
	return referenced

static func _artifact_cleanup_allowed(path: String) -> bool:
	var name := path.get_file()
	if path.begins_with("user://temp/saves/"):
		return true
	if GameExtraction.is_staging_path(path):
		return true
	return name.begins_with(".kyodai-extract-download-") or name.begins_with(".kyodai-backup-")

static func _is_operation_artifact_name(name: String) -> bool:
	return name.begins_with(".kyodai-extract-") or name.begins_with(".kyodai-backup-") \
		or name.begins_with(".kyodai-hoist-") or name.begins_with(".kyodai-merge-backup-") \
		or name.begins_with("download_") or name.begins_with("staged_")

static func _delete_artifact(path: String, result: Dictionary) -> void:
	var fs := load("res://managers/system_manager/filesystem_sub_manager.gd")
	if fs.is_symlink(path):
		result.preserved.append(path)
		return
	if fs.dir_exists(path):
		if fs.extraction_tree_has_symlinks(path):
			result.preserved.append(path)
			return
		if fs.delete_dir_recursive(path):
			result.deleted.append(path)
		else:
			result.preserved.append(path)
	elif fs.file_exists(path):
		if fs.delete_file(path):
			result.deleted.append(path)
		else:
			result.preserved.append(path)

static func _child_dirs(root: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return result
	dir.set_include_hidden(true)
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != ".." and dir.current_is_dir():
			result.append(root.rstrip("/") + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	return result

static func _child_files(root: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return result
	dir.set_include_hidden(true)
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != ".." and not dir.current_is_dir():
			result.append(root.rstrip("/") + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	return result

static func _is_stale_path(path: String, max_age_seconds: int) -> bool:
	var modified := _modified_time(path)
	return modified > 0 and Time.get_unix_time_from_system() - modified >= max_age_seconds

static func _modified_time(path: String) -> int:
	var fs := load("res://managers/system_manager/filesystem_sub_manager.gd")
	if not fs.dir_exists(path) and not fs.file_exists(path):
		return 0
	return int(FileAccess.get_modified_time(path))
