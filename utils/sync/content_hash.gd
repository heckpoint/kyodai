## RomM-parity content hashing for save sync (gavel/negotiate support).
## Mirrors RomM's compute_content_hash: plain files hash as raw MD5;
## zip files hash as MD5 over the sorted "entry:md5(entry)" lines.
class_name ContentHash

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

static func _md5_bytes(data: PackedByteArray) -> String:
	var ctx = HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		return ""
	# HashingContext.update() rejects zero-length buffers; skipping it yields
	# the correct MD5 of empty input (d41d8cd9...) for RomM parity.
	if not data.is_empty():
		if ctx.update(data) != OK:
			return ""
	return ctx.finish().hex_encode()

## Restricted Android paths (other apps' Android/data|obb) are invisible to
## Godot's raw FileAccess/DirAccess; they must go through the FSM helpers.
static func _is_restricted(path: String) -> bool:
	var normalized = path.replace("\\", "/")
	return normalized.contains("/Android/data/") or normalized.contains("/Android/obb/")

## MD5 of raw file bytes, streamed.
static func compute_file_hash(path: String) -> String:
	if _is_restricted(path):
		return FSM.md5_file(path)
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx = HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		f.close()
		return ""
	while f.get_position() < f.get_length():
		var chunk = f.get_buffer(mini(1048576, f.get_length() - f.get_position()))
		if ctx.update(chunk) != OK:
			f.close()
			return ""
	f.close()
	return ctx.finish().hex_encode()

static func _is_zip_file(path: String) -> bool:
	var magic: PackedByteArray
	if _is_restricted(path):
		magic = FSM.read_file_chunk(path, 4)
	else:
		var f = FileAccess.open(path, FileAccess.READ)
		if f == null:
			return false
		magic = f.get_buffer(4)
		f.close()
	if magic.size() < 4:
		return false
	return magic[0] == 0x50 and magic[1] == 0x4B and (magic[2] == 0x03 or magic[2] == 0x05 or magic[2] == 0x07)

## RomM's zip hash: MD5 of the sorted "name:md5(content)" lines of all
## non-directory entries.
static func compute_zip_hash(zip_path: String) -> String:
	if _is_restricted(zip_path):
		return FSM.zip_hash(zip_path)
	var zr = ZIPReader.new()
	if zr.open(zip_path) != OK:
		return ""
	var lines: Array[String] = []
	for entry_name in zr.get_files():
		if entry_name.ends_with("/"):
			continue
		lines.append(entry_name + ":" + _md5_bytes(zr.read_file(entry_name)))
	zr.close()
	lines.sort()
	return _md5_bytes("\n".join(lines).to_utf8_buffer())

## RomM-parity hash for any file: zip-aware.
static func compute_content_hash(path: String) -> String:
	if _is_zip_file(path):
		return compute_zip_hash(path)
	return compute_file_hash(path)

## Simulates the zip hash of a folder as FSM.zip_directory() would pack it
## (relative entry names, optional root_name wrapper) without writing a zip.
## Used to hash local folder saves before negotiate decides anything.
static func compute_folder_zip_hash(dir_path: String, root_name: String = "") -> String:
	if not FSM.dir_exists(dir_path):
		return ""
	var prefix = (root_name + "/") if root_name != "" else ""
	var lines: Array[String] = []
	_collect_folder_hash_lines(dir_path, prefix, lines)
	lines.sort()
	if lines.is_empty() and _is_restricted(dir_path):
		# On a restricted path an empty collection may mean "no read access"
		# (direct/SAF tier failure) rather than a genuinely empty save - make it
		# visible instead of silently hashing nothing.
		push_warning("[ContentHash] Restricted path collected zero files (possible read-access failure): " + dir_path)
	return _md5_bytes("\n".join(lines).to_utf8_buffer())

## Simulates the zip hash of a multi-root archive: each component is
## {"src": dir, "root": zip_root} packed as zip_components would pack it
## (3DS data+extdata save units). Components with missing dirs are skipped.
static func compute_components_zip_hash(components: Array) -> String:
	var lines: Array[String] = []
	for comp in components:
		var src: String = comp.get("src", "")
		if src == "" or not FSM.dir_exists(src):
			continue
		var root: String = comp.get("root", "")
		var prefix = (root + "/") if root != "" else ""
		_collect_folder_hash_lines(src, prefix, lines)
	lines.sort()
	if lines.is_empty():
		for comp in components:
			var comp_src: String = comp.get("src", "")
			if comp_src != "" and _is_restricted(comp_src) and FSM.dir_exists(comp_src):
				push_warning("[ContentHash] Restricted path collected zero files (possible read-access failure): " + comp_src)
	return _md5_bytes("\n".join(lines).to_utf8_buffer())

static func _collect_folder_hash_lines(dir_path: String, zip_prefix: String, lines: Array[String]) -> void:
	if not FSM.dir_exists(dir_path):
		return
	for filename in FSM.list_dir(dir_path):
		if filename == "." or filename == "..":
			continue
		var full_path = dir_path + "/" + filename
		var zip_path = zip_prefix + filename
		if FSM.dir_exists(full_path):
			_collect_folder_hash_lines(full_path, zip_path + "/", lines)
		else:
			# Zero-length files are real ZIP entries and must affect the hash just
			# as they do in compute_zip_hash() and FSM.zip_directory().
			var hash := FSM.md5_file(full_path)
			if not hash.is_empty():
				lines.append(zip_path + ":" + hash)
