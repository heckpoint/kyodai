# SystemManager.filesystem - Unified file system operations
# Uses MANAGE_EXTERNAL_STORAGE on Android for direct filesystem access
# DocumentsContract used for /Android/data/ and /Android/obb/ paths

extends Manager
class_name FileSystemSubManager

const ExtractionLayout = preload("res://utils/filesystem/extraction_layout.gd")
const DEBUG_LOG: bool = false

## Path format options for resolve_path()
enum PathFormat {
	DEFAULT,      ## Resolve placeholders, normalize slashes
	ABSOLUTE,     ## Full absolute path (globalize user://)
	NORMALIZED,   ## Just clean slashes and ./ ../
	PLATFORM      ## Platform-appropriate separators (\ on Windows, / elsewhere)
}

## Image format identifiers for detect_image_format()
enum ImageFormat {
	UNKNOWN,
	JPEG,
	PNG,
	WEBP,
}

## Detects the image format of a byte buffer using magic bytes.
## Returns one of the ImageFormat constants.
static func detect_image_format(buffer: PackedByteArray) -> int:
	if buffer.size() < 2:
		return ImageFormat.UNKNOWN

	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		return ImageFormat.JPEG

	if buffer.size() >= 8 and buffer[0] == 0x89 and buffer[1] == 0x50 and buffer[2] == 0x4E and buffer[3] == 0x47:
		return ImageFormat.PNG

	if buffer.size() >= 12 and buffer[0] == 0x52 and buffer[1] == 0x49 and buffer[2] == 0x46 and buffer[3] == 0x46 and buffer[8] == 0x57 and buffer[9] == 0x45 and buffer[10] == 0x42 and buffer[11] == 0x50:
		return ImageFormat.WEBP

	return ImageFormat.UNKNOWN

## Returns true if the buffer starts with a supported image format's magic bytes.
static func is_image_buffer(buffer: PackedByteArray) -> bool:
	return detect_image_format(buffer) != ImageFormat.UNKNOWN

## Normalizes a path by removing redundant components like "." and ".."
## and ensuring consistent separators.
## Also converts content:// URIs to real paths.
static func normalize_path(path: String) -> String:
	if path.is_empty():
		return path
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Shared variables for path normalization
	var has_leading_slash: bool
	var segments: PackedStringArray
	var resolved: Array[String] = []
	var result: String
	
	# Preserve Godot virtual paths - don't normalize slashes in user:// or res://
	if path.begins_with("user://") or path.begins_with("res://"):
		# Only resolve . and .. after the protocol prefix
		var prefix = ""
		var rest = path
		if path.begins_with("user://"):
			prefix = "user://"
			rest = path.substr(7)
		elif path.begins_with("res://"):
			prefix = "res://"
			rest = path.substr(6)
		
		# Normalize the rest of the path
		has_leading_slash = rest.begins_with("/")
		segments = rest.split("/", false)
		resolved.clear()
		for segment in segments:
			if segment == ".":
				continue
			elif segment == "..":
				if resolved.size() > 0:
					resolved.pop_back()
			else:
				resolved.append(segment)
		
		result = "/".join(resolved)
		if has_leading_slash:
			result = "/" + result
		
		return prefix + result
	
	# Detect leading slash (absolute path)
	has_leading_slash = path.begins_with("/")
	
	# Split into segments and resolve . and ..
	segments = path.split("/", false)
	resolved.clear()
	for segment in segments:
		if segment == ".":
			continue
		elif segment == "..":
			if resolved.size() > 0:
				resolved.pop_back()
		else:
			resolved.append(segment)
	
	# Rejoin segments
	result = "/".join(resolved)
	
	# Restore leading slash for absolute paths
	if has_leading_slash:
		result = "/" + result
	
	return result

## Joins path components safely, handling trailing/leading slashes
## Supports up to 6 path segments. For more, chain calls.
static func join_paths(path1: String, path2: String, path3: String = "", path4: String = "", path5: String = "", path6: String = "") -> String:
	var result = _join_paths_2(path1, path2)
	if path3 != "":
		result = _join_paths_2(result, path3)
	if path4 != "":
		result = _join_paths_2(result, path4)
	if path5 != "":
		result = _join_paths_2(result, path5)
	if path6 != "":
		result = _join_paths_2(result, path6)
	return result

## Internal: Joins two path components
static func _join_paths_2(a: String, b: String) -> String:
	if a.is_empty():
		return b
	if b.is_empty():
		return a

	var result = a
	if not result.ends_with("/") and not result.ends_with("\\"):
		result += "/"
	if b.begins_with("/") or b.begins_with("\\"):
		b = b.substr(1)

	return result + b

## Validates a filename supplied by an external party (RomM server responses,
## archive listings). Returns "" when the name could escape its destination
## directory; callers must treat "" as fatal for the item and surface an
## error - never silently rewrite, so hostile server data stays visible.
##
## Deliberately does NOT use String.validate_filename(): that also strips
## '%', '?', '*', quotes etc., which are legal on Linux/NTFS and common in
## ROM scene naming (e.g. "[T+Eng30%_patch].gbc") and pose no traversal
## risk. The only requirement here is that the name stays a single path
## segment that cannot escape its destination; names the host OS genuinely
## can't store fail at write time with a visible error instead.
static func sanitize_server_filename(file_name: String) -> String:
	if file_name.is_empty():
		return ""
	# Path separators: the name must be a single segment on every OS.
	if file_name.contains("/") or file_name.contains("\\"):
		return ""
	# Drive letters / NTFS alternate data streams ("file.zip:payload").
	if file_name.contains(":"):
		return ""
	# Traversal segments and current/parent dir aliases.
	if file_name == "." or file_name == "..":
		return ""
	# Embedded NUL can truncate paths at the C layer.
	if file_name.contains("\u0000"):
		return ""
	return file_name

## True when path (after separator normalization and resolution of "." / ".."
## segments) stays inside root. Use before writing or deleting any path that
## incorporates externally supplied names.
static func is_path_contained(path: String, root: String) -> bool:
	if path.is_empty() or root.is_empty():
		return false
	var norm_path := path.replace("\\", "/").simplify_path()
	var norm_root := root.replace("\\", "/").simplify_path().rstrip("/")
	return norm_path == norm_root or norm_path.begins_with(norm_root + "/")

## Computes the SHA-256 hex digest of a file, streaming in 1 MiB chunks.
## Returns "" on error. Used to verify downloads against API-attested digests.
static func sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[SystemManager.filesystem] Cannot open for hashing: " + path)
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		f.close()
		return ""
	var length := f.get_length()
	while f.get_position() < length:
		var remaining: int = length - f.get_position()
		ctx.update(f.get_buffer(mini(1024 * 1024, remaining)))
	f.close()
	return ctx.finish().hex_encode()

## Computes an MD5 digest. Restricted paths stream through the Java plugin so
## file bytes never cross JNI; direct paths use Godot's streaming hash context.
static func md5_file(path: String) -> String:
	if path.is_empty():
		return ""
	if _is_restricted_android_path(path):
		var plugin = _get_plugin()
		if plugin == null:
			return ""
		return str(plugin.call("androidComputeFileHash", path))
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		file.close()
		return ""
	var length := file.get_length()
	while file.get_position() < length:
		var remaining: int = length - file.get_position()
		if ctx.update(file.get_buffer(mini(1024 * 1024, remaining))) != OK:
			file.close()
			return ""
	file.close()
	return ctx.finish().hex_encode()

## Computes the RomM-parity hash of a ZIP on a restricted path, streaming the
## archive in Java. Direct ZIP hashing remains in ContentHash.
static func zip_hash(path: String) -> String:
	if not _is_restricted_android_path(path):
		return ""
	var plugin = _get_plugin()
	if plugin == null:
		return ""
	return str(plugin.call("androidComputeZipHash", path))

## Universal path resolver - handles all path formats and transformations
##
## Options:
##   "base_dir": String        - REQUIRED for relative paths (errors if missing)
##   "placeholders": Dictionary - {"{key}": "value", ...} for custom placeholders
##   "format": PathFormat      - Output format (default: DEFAULT)
##   "platform": String        - Override platform for PLATFORM format
##
## Returns empty string on error (with push_error)
static func resolve_path(path: String, options: Dictionary = {}) -> String:
	if path.is_empty():
		return ""
	
	# Convert content:// URIs to real paths first
	var result = resolve_content_uri(path)
	var format = options.get("format", PathFormat.DEFAULT)
	
	# Step 1: Resolve placeholders
	var placeholders = options.get("placeholders", {})
	for key in placeholders:
		result = result.replace(key, str(placeholders[key]))
	
	# Step 1b: Expand leading ~/ to $HOME on Linux so config paths like
	# ~/.local/share/... resolve correctly.
	if SystemManager.platform.is_linux() and result.begins_with("~/"):
		var home = OS.get_environment("HOME")
		if home != "":
			result = home + result.substr(1)
	
	# Step 2: Handle relative paths
	if not _is_absolute_path(result):
		var base_dir = options.get("base_dir", "")
		if base_dir.is_empty():
			push_error("[SystemManager.filesystem] Relative path requires base_dir: " + path)
			return ""
		result = join_paths(base_dir, result)
	
	# Step 3: Apply format
	match format:
		PathFormat.DEFAULT:
			result = normalize_path(result)
		PathFormat.NORMALIZED:
			result = normalize_path(result)
		PathFormat.ABSOLUTE:
			result = ProjectSettings.globalize_path(normalize_path(result))
		PathFormat.PLATFORM:
			result = normalize_path(result)
			var platform = options.get("platform", "")
			if platform == "":
				if is_instance_valid(SystemManager.platform):
					platform = SystemManager.platform.get_platform_name()
				else:
					platform = OS.get_name().to_lower()
			if platform == "windows":
				result = result.replace("/", "\\")
			else:
				result = result.replace("\\", "/")
		_:
			result = normalize_path(result)
	
	return result

## Resolves a path to an absolute native path for external tools/processes
## Combines ABSOLUTE resolution with platform-specific slash conversion
## Windows: backslashes, Others: forward slashes
static func resolve_native_path(path: String) -> String:
	var resolved = resolve_path(path, {"format": PathFormat.ABSOLUTE})
	if is_instance_valid(SystemManager.platform):
		if SystemManager.platform.is_windows():
			resolved = resolved.replace("/", "\\")
	elif OS.get_name() == "Windows":
		resolved = resolved.replace("/", "\\")
	return resolved

## Resolves emulator paths with full wildcard support
## Handles {emulator_dir}, {app_data}, {games_dir}, {core_name}, {home},
## and {env.VAR} environment placeholders.
## This is the preferred method for resolving emulator-related paths
static func resolve_emulator_path(path: String, emulator_id: String, platform_slug: String = "", format: PathFormat = PathFormat.DEFAULT) -> String:
	if path.is_empty():
		return ""
	
	var placeholders = {}
	
	# Resolve {emulator_dir}
	if is_instance_valid(LaunchManager):
		var emulator_dir = LaunchManager._get_emulator_directory(emulator_id)
		placeholders["{emulator_dir}"] = emulator_dir.rstrip("/")
		
		# Resolve {app_data}
		var app_data = LaunchManager.get_app_data_path(emulator_id)
		if app_data != "":
			placeholders["{app_data}"] = app_data.rstrip("/")
		
		# Resolve {core_name}
		if platform_slug != "":
			var core_name = LaunchManager.get_retroarch_core_name(platform_slug)
			if core_name != "":
				placeholders["{core_name}"] = core_name
	
	# Resolve {games_dir}
	if is_instance_valid(DataManager):
		var games_folder_setting = DataManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value if games_folder_setting else "user://roms"
		placeholders["{games_dir}"] = games_dir.rstrip("/")
	
	# Resolve {home}
	var home_dir = OS.get_environment("HOME")
	if home_dir == "" or (is_instance_valid(SystemManager.platform) and SystemManager.platform.is_windows()):
		home_dir = OS.get_environment("USERPROFILE")
	if home_dir != "":
		placeholders["{home}"] = home_dir.rstrip("/")
	
	# Resolve {env.VAR} environment placeholders
	var result := path
	var env_regex := RegEx.new()
	env_regex.compile(r"\{env\.([^}]+)\}")
	var env_match := env_regex.search(result)
	while env_match != null:
		var var_name := env_match.get_string(1)
		var var_value := OS.get_environment(var_name)
		result = result.substr(0, env_match.get_start()) + var_value + result.substr(env_match.get_end())
		env_match = env_regex.search(result)
	
	return resolve_path(result, {
		"base_dir": placeholders.get("{emulator_dir}", ""),
		"placeholders": placeholders,
		"format": format
	})

## Checks if a path is absolute (not relative)
static func _is_absolute_path(path: String) -> bool:
	if path.is_empty():
		return false
	return path.begins_with("/") \
		or path.begins_with("user://") \
		or path.begins_with("res://") \
		or (path.length() > 1 and path[1] == ":")

## Gets the size of a file in bytes
## Returns -1 if file doesn't exist or size cannot be determined
static func get_file_size(path: String) -> int:
	if path.is_empty():
		return -1

	if _is_restricted_android_path(path):
		var plugin = _get_plugin()
		if plugin == null:
			return -1
		return int(plugin.call("androidGetFileSize", resolve_native_path(path)))

	if not file_exists(path):
		return -1
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var size = file.get_length()
		file.close()
		return size
	
	return -1

## Returns free disk space in bytes for the filesystem containing path.
## Returns -1 if it cannot be determined (e.g. content:// URIs).
static func get_space_left(path: String) -> int:
	if path.is_empty():
		return -1

	var resolved := path
	if resolved.begins_with("content://"):
		return -1
	if resolved.begins_with("user://") or resolved.begins_with("res://"):
		resolved = ProjectSettings.globalize_path(resolved)

	# Walk up to the nearest existing ancestor so non-existent destinations work
	var dir_path := resolved
	if file_exists(dir_path):
		dir_path = dir_path.get_base_dir()
	while dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		var parent := dir_path.get_base_dir()
		if parent == dir_path:
			break
		dir_path = parent
	if dir_path == "":
		return -1

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return -1
	return dir.get_space_left()

## Converts a content:// URI (from Android file picker) to a real filesystem path.
## Uses the plugin to resolve the URI. Returns the original path if not a content URI.
static func resolve_content_uri(path: String) -> String:
	if not path.begins_with("content://"):
		return path
	
	if not is_android():
		return path
	
	var plugin = _get_plugin()
	if plugin == null:
		push_warning("[SystemManager.filesystem] Plugin not available to resolve content URI: " + path)
		return path
	
	var real_path = plugin.call("resolveContentUriToRealPath", path)
	if real_path != "" and real_path != path:
		return real_path
	
	return path

## Gets the KyodaiBridge plugin singleton
static func _get_plugin():
	if Engine.has_singleton("KyodaiBridge"):
		return Engine.get_singleton("KyodaiBridge")
	return null

## Resolves a content:// URI to a real path if possible; otherwise imports it
## into dest_dir via the plugin (bytes survive permission loss and reboots).
## Returns the usable real path, or the original path on failure.
static func import_content_file(path: String, dest_dir: String) -> String:
	var resolved = resolve_content_uri(path)
	if not resolved.begins_with("content://"):
		return resolved

	if not is_android():
		return path

	var plugin = _get_plugin()
	if plugin == null:
		push_warning("[SystemManager.filesystem] Plugin not available to import content URI: " + path)
		return path

	var dest = dest_dir
	if dest.begins_with("user://") or dest.begins_with("res://"):
		dest = ProjectSettings.globalize_path(dest)
	var imported = plugin.call("importContentUri", path, dest)
	if imported != "" and not str(imported).begins_with("content://"):
		return str(imported)

	push_warning("[SystemManager.filesystem] Failed to import content URI: " + path)
	return path

## Checks if running on Android platform
static func is_android() -> bool:
	return SystemManager.platform.is_android() if is_instance_valid(SystemManager.platform) else OS.get_name() == "Android"

## Checks if a path requires DocumentsContract on Android 11+
static func _is_restricted_android_path(path: String) -> bool:
	if not is_android():
		return false
	if path.is_empty():
		return false
	# Normalize to resolve any ".." segments before checking
	var normalized = normalize_path(path)
	return normalized.contains("/Android/data/") or normalized.contains("/Android/obb/")

## Delegates file_exists to plugin for restricted paths
static func _plugin_file_exists(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidFileExists", path)

## Delegates dir_exists to plugin for restricted paths (verifies it's actually a directory)
static func _plugin_dir_exists(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidDirExists", path)

## Delegates dir listing to plugin for restricted paths
static func _plugin_list_dir(path: String) -> Array[String]:
	var result: Array[String] = []
	var plugin = _get_plugin()
	if plugin == null:
		return result
	
	var json_str = plugin.call("androidListDir", path)
	if json_str.is_empty() or json_str == "[]":
		return result
	
	var json = JSON.new()
	var error = json.parse(json_str)
	if error == OK and json.data is Array:
		for item in json.data:
			result.append(str(item))
	
	return result

## Delegates file read to plugin for restricted paths
static func _plugin_read_file(path: String) -> PackedByteArray:
	var plugin = _get_plugin()
	if plugin == null:
		return PackedByteArray()
	var handle = plugin.call("androidOpenRead", path)
	if handle <= 0:
		return PackedByteArray()
	var data := PackedByteArray()
	while true:
		var base64_chunk = plugin.call("androidReadChunk", handle, 1024 * 1024)
		if base64_chunk == null:
			plugin.call("androidCloseRead", handle)
			return PackedByteArray()
		if base64_chunk.is_empty():
			break
		data.append_array(Marshalls.base64_to_raw(base64_chunk))
	plugin.call("androidCloseRead", handle)
	return data

## Delegates a bounded file read to plugin for restricted paths
static func _plugin_read_file_chunk(path: String, max_bytes: int) -> PackedByteArray:
	var plugin = _get_plugin()
	if plugin == null or max_bytes <= 0:
		return PackedByteArray()
	var handle = plugin.call("androidOpenRead", path)
	if handle <= 0:
		return PackedByteArray()
	var base64_chunk = plugin.call("androidReadChunk", handle, max_bytes)
	plugin.call("androidCloseRead", handle)
	if base64_chunk == null or base64_chunk.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(base64_chunk)

## Delegates file write to plugin for restricted paths
static func _plugin_write_file(path: String, data: PackedByteArray) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	var handle = plugin.call("androidOpenWrite", path)
	if handle <= 0:
		return false
	var offset := 0
	while offset < data.size():
		var end := mini(offset + 1024 * 1024, data.size())
		var base64_chunk = Marshalls.raw_to_base64(data.slice(offset, end))
		if not plugin.call("androidWriteChunk", handle, base64_chunk):
			plugin.call("androidCloseWrite", handle)
			return false
		offset = end
	return bool(plugin.call("androidCloseWrite", handle))

## Delegates file delete to plugin for restricted paths
static func _plugin_delete_file(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidDeleteFile", path)

## Delegates dir creation to plugin for restricted paths
static func _plugin_create_dir(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidCreateDir", path)

## Delegates rename/move to plugin for restricted paths (streaming, SAF-aware)
static func _plugin_rename(source_path: String, dest_path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidRename", resolve_native_path(source_path), resolve_native_path(dest_path))

## Delegates file copy to plugin for restricted paths (streaming, SAF-aware)
static func _plugin_copy_file(source_path: String, dest_path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidCopyFile", resolve_native_path(source_path), resolve_native_path(dest_path))

## Delegates get modified time to plugin for restricted paths
## Note: Android plugin returns milliseconds, Godot expects seconds
static func _plugin_get_modified_time(path: String) -> int:
	var plugin = _get_plugin()
	if plugin == null:
		return 0
	var ms = plugin.call("androidGetModifiedTime", path)
	return int(ms / 1000)

## Checks if a file exists
static func file_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return FileAccess.file_exists(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_file_exists(path)
	
	# For real paths
	return FileAccess.file_exists(path)

## Checks if a directory exists
static func dir_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return DirAccess.dir_exists_absolute(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_dir_exists(path)
	
	# For real paths
	return DirAccess.dir_exists_absolute(path)

## Creates a directory and all parent directories if they don't exist
static func make_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false

	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)

	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		if DirAccess.dir_exists_absolute(path):
			return true
		return DirAccess.make_dir_recursive_absolute(path) == OK

	# Check if restricted Android path (Godot's DirAccess is storage-scope gated
	# and refuses other apps' /Android/data/ paths even when the OS allows us)
	if _is_restricted_android_path(path):
		return _plugin_create_dir(path)

	# For real paths
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK

## Deletes a directory and all its contents recursively
static func delete_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false

	# Restricted paths go through the plugin (SAF deleteDocument removes subtrees)
	if _is_restricted_android_path(path):
		var plugin = _get_plugin()
		if plugin == null:
			return false
		return plugin.call("androidDeleteRecursive", resolve_native_path(path))

	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return _delete_dir_recursive_internal(path)

	# For real paths
	return _delete_dir_recursive_internal(path)

static func _delete_dir_recursive_internal(path: String) -> bool:
	print("[SystemManager.filesystem] Deleting directory: " + path)
	var dir = DirAccess.open(path)
	if dir == null:
		if DEBUG_LOG: print("[SystemManager.filesystem] FAILED to open directory: " + path)
		return false
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	var deleted_count = 0
	var failed_count = 0
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_path = join_paths(path, file_name)
			if dir.current_is_dir():
				if DEBUG_LOG: print("[SystemManager.filesystem] Recursing into subdirectory: " + item_path)
				if not _delete_dir_recursive_internal(item_path):
					failed_count += 1
			else:
				var remove_result = DirAccess.remove_absolute(item_path)
				if remove_result == OK:
					deleted_count += 1
				else:
					if OS.get_name() == "Windows":
						OS.execute("cmd", ["/c", "attrib", "-r", item_path], [], true)
						remove_result = DirAccess.remove_absolute(item_path)
						if remove_result == OK:
							deleted_count += 1
						else:
							if DEBUG_LOG: print("[SystemManager.filesystem] FAILED to delete file after clearing read-only: " + item_path + " (error: " + str(remove_result) + ")")
							failed_count += 1
					else:
						if DEBUG_LOG: print("[SystemManager.filesystem] FAILED to delete file: " + item_path + " (error: " + str(remove_result) + ")")
						failed_count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	
	var result = DirAccess.remove_absolute(path)
	if result != OK and OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "attrib", "-r", path], [], true)
		result = DirAccess.remove_absolute(path)
	
	if result == OK:
		print("[SystemManager.filesystem] Successfully deleted directory: " + path + " (files deleted: " + str(deleted_count) + ", failed: " + str(failed_count) + ")")
	else:
		print("[SystemManager.filesystem] FAILED to delete directory: " + path + " (error: " + str(result) + ", files deleted: " + str(deleted_count) + ", failed: " + str(failed_count) + ")")
	
	return result == OK

## Lists files in a directory
static func list_dir(path: String) -> Array[String]:
	var result: Array[String] = []
	
	if path.is_empty():
		return result
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_list_dir(path)
	
	var dir = DirAccess.open(path)
	if dir == null:
		return result
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			result.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	return result

## Renames a file or directory
static func rename(source_path: String, dest_name: String) -> bool:
	if source_path.is_empty() or dest_name.is_empty():
		return false

	var dest_path = join_paths(source_path.get_base_dir(), dest_name)
	if _is_restricted_android_path(source_path) or _is_restricted_android_path(dest_path):
		return _plugin_rename(source_path, dest_path)
	return DirAccess.rename_absolute(source_path, dest_path) == OK

## Moves a file or directory to a new location
static func move(source_path: String, dest_path: String) -> bool:
	if source_path.is_empty() or dest_path.is_empty():
		return false

	# Restricted paths go through the plugin (handles cross-dir move as copy+delete)
	if _is_restricted_android_path(source_path) or _is_restricted_android_path(dest_path):
		return _plugin_rename(source_path, dest_path)

	# Ensure destination directory exists
	var dest_dir = dest_path.get_base_dir()
	if not dest_dir.is_empty() and not dir_exists(dest_dir):
		if not make_dir_recursive(dest_dir):
			return false

	return DirAccess.rename_absolute(source_path, dest_path) == OK

## Copies a file from source to destination
static func copy_file(source_path: String, dest_path: String) -> bool:
	if source_path.is_empty() or dest_path.is_empty():
		return false

	# Restricted paths go through the plugin's streaming copy (SAF-aware)
	if _is_restricted_android_path(source_path) or _is_restricted_android_path(dest_path):
		return _plugin_copy_file(source_path, dest_path)

	# Ensure destination directory exists
	var dest_dir = dest_path.get_base_dir()
	if not dest_dir.is_empty() and not dir_exists(dest_dir):
		if not make_dir_recursive(dest_dir):
			return false
	
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if not source_file:
		return false
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		source_file.close()
		return false
	
	var buffer_size = 65536  # 64KB chunks
	while not source_file.eof_reached():
		var chunk = source_file.get_buffer(buffer_size)
		dest_file.store_buffer(chunk)
	
	source_file.close()
	dest_file.close()
	
	return true

## Recursively copies a directory to another location
## Uses routed helpers throughout so restricted /Android/data/ paths work
## Returns true on success
static func copy_dir(source: String, dest: String) -> bool:
	print("[SystemManager.filesystem] copy_dir: START " + source + " -> " + dest)
	if not dir_exists(dest):
		if DEBUG_LOG: print("[SystemManager.filesystem] copy_dir: Creating destination directory: " + dest)
		if not make_dir_recursive(dest):
			push_error("[SystemManager.filesystem] Failed to create destination directory: " + dest)
			return false

	if not dir_exists(source):
		push_error("[SystemManager.filesystem] Failed to open source directory: " + source)
		return false

	var success = true
	var copied_count = 0
	var failed_count = 0

	for item in list_dir(source):
		if item == "." or item == "..":
			continue
		var src_path = source.rstrip("/") + "/" + item
		var dst_path = dest.rstrip("/") + "/" + item
		if dir_exists(src_path):
			if not copy_dir(src_path, dst_path):
				success = false
				failed_count += 1
		else:
			if not copy_file(src_path, dst_path):
				success = false
				failed_count += 1
			else:
				copied_count += 1

	print("[SystemManager.filesystem] copy_dir: END " + source + " -> " + dest + " (success=" + str(success) + ", copied=" + str(copied_count) + ", failed=" + str(failed_count) + ")")
	return success

## Creates a ZIP archive from a directory
## When root_name is provided, creates a root folder inside the zip with that name
## max_file_size: maximum file size in bytes to include (-1 for no limit)
## Returns true on success
static func zip_directory(source_dir: String, dest_zip: String, max_file_size: int = -1, root_name: String = "") -> bool:
	if not dir_exists(source_dir):
		push_error("[SystemManager.filesystem] Source directory does not exist: " + source_dir)
		return false
	
	# If root_name is provided, stage to temp directory first
	var actual_source = source_dir
	var stage_dir = ""
	
	if not root_name.is_empty():
		stage_dir = "user://temp/saves/stage_" + str(Time.get_ticks_msec()) + "/"
		var stage_root = stage_dir + root_name
		DirAccess.make_dir_recursive_absolute(stage_root)
		var copy_success = copy_dir(source_dir, stage_root)
		if not copy_success:
			delete_dir_recursive(stage_dir)
			return false
		actual_source = stage_dir
	
	# Ensure parent directory exists
	var parent_dir = dest_zip.get_base_dir()
	if not parent_dir.is_empty() and not dir_exists(parent_dir):
		if not make_dir_recursive(parent_dir):
			if not stage_dir.is_empty():
				delete_dir_recursive(stage_dir)
			return false
	
	# Staging paths are reused across attempts; a partial zip from a failed
	# pass must not leak duplicate entries into the retry (open() appends).
	if file_exists(dest_zip):
		delete_file(dest_zip)
	var packer = ZIPPacker.new()
	var err = packer.open(dest_zip)
	if err != OK:
		push_error("[SystemManager.filesystem] Failed to open ZIPPacker for: " + dest_zip)
		if not stage_dir.is_empty():
			delete_dir_recursive(stage_dir)
		return false
	
	var success = _zip_directory_recursive(packer, actual_source, "", max_file_size)
	packer.close()
	
	# Clean up staging directory if used
	if not stage_dir.is_empty():
		delete_dir_recursive(stage_dir)
	
	return success

## Creates a ZIP archive from several source directories, each packed under
## its own root folder (e.g. a 3DS save unit: data + extdata roots).
## components: Array of {"src": dir_path, "root": zip_root_name}; sources
## that do not exist are skipped. Returns true on success.
static func zip_components(components: Array, dest_zip: String) -> bool:
	# Ensure parent directory exists
	var parent_dir = dest_zip.get_base_dir()
	if not parent_dir.is_empty() and not dir_exists(parent_dir):
		if not make_dir_recursive(parent_dir):
			return false

	# Staging paths are reused across attempts; a partial zip from a failed
	# pass must not leak duplicate entries into the retry (open() appends).
	if file_exists(dest_zip):
		delete_file(dest_zip)
	var packer = ZIPPacker.new()
	var err = packer.open(dest_zip)
	if err != OK:
		push_error("[SystemManager.filesystem] Failed to open ZIPPacker for: " + dest_zip)
		return false

	var success = true
	for comp in components:
		var src: String = comp.get("src", "")
		if src == "" or not dir_exists(src):
			continue
		var root: String = comp.get("root", "")
		var prefix = (root + "/") if root != "" else ""
		if not _zip_directory_recursive(packer, src, prefix, -1):
			success = false
	packer.close()
	return success

## Internal: Recursively adds directory contents to a ZIPPacker
## Uses routed helpers so restricted /Android/data/ source trees work
static func _zip_directory_recursive(packer: ZIPPacker, dir_path: String, zip_prefix: String, max_file_size: int = -1) -> bool:
	if not dir_exists(dir_path):
		push_error("[SystemManager.filesystem] Failed to open directory for zipping: " + dir_path)
		return false

	var success = true

	for filename in list_dir(dir_path):
		if filename == "." or filename == "..":
			continue
		var full_path = dir_path + "/" + filename
		var zip_path = zip_prefix + filename

		if dir_exists(full_path):
			packer.start_file(zip_path + "/")
			packer.close_file()
			if not _zip_directory_recursive(packer, full_path, zip_path + "/", max_file_size):
				success = false
		else:
			var file_size = get_file_size(full_path)
			if file_size < 0:
				push_error("[SystemManager.filesystem] Failed to read file for zipping: " + full_path)
				success = false
			elif max_file_size > 0 and file_size > max_file_size:
				if DEBUG_LOG: print("[SystemManager.filesystem] Skipping oversized file (" + str(file_size) + " bytes): " + full_path)
			else:
				var data = read_file_bytes(full_path)
				if data.is_empty() and file_size > 0:
					push_error("[SystemManager.filesystem] Failed to read file for zipping: " + full_path)
					success = false
				else:
					packer.start_file(zip_path)
					packer.write_file(data)
					packer.close_file()

		if not success:
			break

	return success

## Deletes a file
static func delete_file(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_delete_file(path)
	
	var result = DirAccess.remove_absolute(path)
	if result != OK and OS.get_name() == "Windows":
		# Clear read-only attribute and retry on Windows
		OS.execute("cmd", ["/c", "attrib", "-r", path], [], true)
		result = DirAccess.remove_absolute(path)
	
	return result == OK

## Gets file modification time
static func get_modified_time(path: String) -> int:
	if path.is_empty():
		return 0
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_get_modified_time(path)
	
	if not FileAccess.file_exists(path):
		return 0
	
	return FileAccess.get_modified_time(path)

## Opens a file for reading
## Returns FileAccess object or null on failure
static func open_file_read(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	path = resolve_content_uri(path)
	return FileAccess.open(path, FileAccess.READ)

## Opens a file for writing
## Returns FileAccess object or null on failure
static func open_file_write(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	path = resolve_content_uri(path)
	return FileAccess.open(path, FileAccess.WRITE)

## Writes string content to a file
static func write_file(path: String, content: String) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_write_file(path, content.to_utf8_buffer())
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	
	file.store_string(content)
	file.close()
	return true

## Writes binary data to a file
static func write_file_bytes(path: String, data: PackedByteArray) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_write_file(path, data)
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	
	file.store_buffer(data)
	file.close()
	return true

## Reads the entire content of a file as a string
static func read_file(path: String) -> String:
	if path.is_empty() or not file_exists(path):
		return ""
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		var bytes = _plugin_read_file(path)
		return bytes.get_string_from_utf8()
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	
	var content = file.get_as_text()
	file.close()
	return content

## Reads the entire content of a file as bytes
static func read_file_bytes(path: String) -> PackedByteArray:
	if path.is_empty() or not file_exists(path):
		return PackedByteArray()
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_read_file(path)
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return PackedByteArray()
	
	var data = file.get_buffer(file.get_length())
	file.close()
	return data

## Reads at most max_bytes from the beginning of a file, without pulling the
## whole file through JNI. Returns an empty array on error or EOF.
static func read_file_chunk(path: String, max_bytes: int) -> PackedByteArray:
	if path.is_empty() or max_bytes <= 0:
		return PackedByteArray()
	path = resolve_content_uri(path)
	if _is_restricted_android_path(path):
		return _plugin_read_file_chunk(path, max_bytes)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var data := file.get_buffer(max_bytes)
	file.close()
	return data

## Extracts an archive to a destination directory.
## Auto-detects format (.zip, .7z) and platform (Android/desktop).
## On desktop: always uses 7-Zip binary for consistent behavior.
## On Android: uses native ExtractorService for ZIP files.
## progress_callback(info: Dictionary) is called periodically with keys:
## extracted_files, total_files, extracted_bytes, total_bytes, total_estimated, current_file
static func extract_archive(archive_path: String, extract_dir: String, progress_callback: Callable = Callable(), normalize_backslashes: bool = true) -> bool:
	if not file_exists(archive_path):
		push_error("[SystemManager.filesystem] Archive file not found: " + archive_path)
		return false
	
	if not dir_exists(extract_dir):
		if not make_dir_recursive(extract_dir):
			push_error("[SystemManager.filesystem] Failed to create extraction directory: " + extract_dir)
			return false
	
	var ext = archive_path.to_lower().get_extension()
	
	# On Android, only ZIP is supported via native ExtractorService
	if SystemManager.platform.is_android():
		if ext == "zip":
			var android_success := _extract_zip_native_streaming(archive_path, extract_dir, "", progress_callback)
			if android_success and normalize_backslashes:
				_normalize_backslash_paths(extract_dir)
			return android_success
		else:
			push_error("[SystemManager.filesystem] Only ZIP files supported on Android")
			return false
	
	# On desktop, use 7-Zip for all archive types
	var success := _extract_with_7z(archive_path, extract_dir, progress_callback)
	if success and normalize_backslashes:
		_normalize_backslash_paths(extract_dir)
	return success

## Async extraction with notification management.
## Queues to SystemManager.memory and handles progress notifications automatically.
## on_progress(info: Dictionary) — keys: extracted_files, total_files,
## extracted_bytes, total_bytes, total_estimated, current_file
## on_complete(success: bool, error_msg: String)
## normalize_backslashes=false defers path repair to a staged layout normalizer.
static func extract_archive_async(
	archive_path: String,
	extract_dir: String,
	archive_name: String = "",
	delete_after: bool = false,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable(),
	show_notification: bool = true,
	normalize_backslashes: bool = true
) -> void:
	var display_name = archive_name if archive_name != "" else archive_path.get_file().get_basename()
	
	# Use Dictionary so closures capture by reference (not by value)
	var counts := {
		"extracted_files": 0,
		"total_files": 0,
		"extracted_bytes": 0,
		"total_bytes": 0,
		"total_estimated": false,
		"current_file": "",
	}
	
	var progress_callable = func() -> float:
		if counts.total_bytes > 0:
			return clampf(float(counts.extracted_bytes) / float(counts.total_bytes), 0.0, 1.0)
		if counts.total_files > 0:
			return clampf(float(counts.extracted_files) / float(counts.total_files), 0.0, 1.0)
		return 0.0
	
	var text_formatter = func(_progress: float) -> String:
		var file_part := ""
		if counts.current_file != "":
			file_part = " — " + String(counts.current_file).get_file()
		
		if counts.total_bytes > 0:
			var estimate_prefix := "~" if counts.total_estimated else ""
			return "%s... (%s / %s%s)%s" % [
				display_name,
				format_bytes(counts.extracted_bytes),
				estimate_prefix,
				format_bytes(counts.total_bytes),
				file_part,
			]
		if counts.extracted_bytes > 0:
			return "%s... (%s extracted)%s" % [display_name, format_bytes(counts.extracted_bytes), file_part]
		if counts.total_files > 0:
			return "%s... (%d/%d files)%s" % [display_name, counts.extracted_files, counts.total_files, file_part]
		if counts.extracted_files > 0:
			return "%s... (%d files)%s" % [display_name, counts.extracted_files, file_part]
		return display_name + "..."
	
	# Suppressed for shuffler preps etc. where the caller runs its own
	# notification and an extra extraction snackbar would just be noise.
	var notification_id: int = -1
	if show_notification:
		notification_id = SystemManager.notifications.show_notification_safe(
			display_name + "...",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			progress_callable,
			text_formatter,
			true,  # pulsing (indeterminate until byte totals are known)
			true  # pinned
		)
	
	var progress_callback = func(info: Dictionary):
		counts.extracted_files = int(info.get("extracted_files", counts.extracted_files))
		counts.total_files = int(info.get("total_files", counts.total_files))
		counts.extracted_bytes = int(info.get("extracted_bytes", counts.extracted_bytes))
		counts.total_bytes = int(info.get("total_bytes", counts.total_bytes))
		counts.total_estimated = bool(info.get("total_estimated", counts.total_estimated))
		counts.current_file = str(info.get("current_file", counts.current_file))
		
		# Once real totals are known, switch from indeterminate pulsing to a
		# determinate progress bar. This callback runs on the extraction worker
		# thread, so route UI changes through the main-thread queue.
		if counts.total_bytes > 0 or counts.total_files > 0:
			if notification_id != -1:
				SystemManager.memory.queue_main_thread_callback(func():
					SystemManager.notifications.set_notification_pulsing(notification_id, false)
				)
		
		# Forward to caller
		if on_progress.is_valid():
			on_progress.call_deferred(info.duplicate())
	
	var extraction_callable = func() -> bool:
		var success = extract_archive(archive_path, extract_dir, progress_callback, normalize_backslashes)
		
		if success and delete_after:
			delete_file(archive_path)
		
		return success
	
	SystemManager.memory.queue_extraction_task(extraction_callable, func(success: bool):
		if success and notification_id != -1:
			# Snap the notification to the actual final totals (the fallback total
			# may have been an estimate) and show it briefly before dismissing.
			counts.total_estimated = false
			if counts.total_bytes > 0:
				counts.extracted_bytes = counts.total_bytes
			if counts.total_files > 0:
				counts.extracted_files = counts.total_files
			SystemManager.notifications.refresh_progress_notification(notification_id)

		if notification_id != -1:
			SystemManager.notifications.dismiss_notification_safe(notification_id)
		
		var error_msg = ""
		if not success:
			error_msg = "Extraction failed for " + display_name
		
		if on_complete.is_valid():
			on_complete.call_deferred(success, error_msg)
	)

## Uses the ExtractorService (separate process) for all Android ZIP extractions.
## This prevents OOM kills by running extraction outside Godot's memory budget.
## Works for any ZIP extraction: games, firmware, emulator assets, saves, etc.
## progress_callback(info: Dictionary) is called when the progress file updates.
static func _extract_zip_native_streaming(zip_path: String, extract_dir: String, game_name: String = "", progress_callback: Callable = Callable()) -> bool:
	print("[SystemManager.filesystem] Using ExtractorService for: " + zip_path)
	
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[SystemManager.filesystem] Android plugin not available")
		return false
	
	var abs_zip = resolve_native_path(zip_path)
	var abs_extract_dir = resolve_native_path(extract_dir)
	
	# Derive a display name from the ZIP filename if not provided
	var display_name = game_name
	if display_name == "":
		display_name = zip_path.get_file().get_basename()
	
	# Derive a unique marker base from the ZIP filename so concurrent extractions
	# into the same directory (e.g. RetroArch cores) don't overwrite each other's
	# completion markers.
	var marker_base = zip_path.get_file().get_basename()
	if marker_base == "":
		marker_base = "archive"
	
	# Use unique completion marker files for 100% reliable completion detection
	# The service writes this file when done, so we don't depend on signals/broadcasts
	var completion_marker = abs_extract_dir + "/.extraction_complete_" + marker_base
	var success_marker = abs_extract_dir + "/.extraction_success_" + marker_base
	var progress_marker = abs_extract_dir + "/.extraction_progress_" + marker_base
	
	# Clean up any old markers (both legacy shared markers and this archive's markers)
	# Marker files may live under restricted /Android/data/ paths, so go through
	# the routed FSM helpers instead of raw FileAccess/DirAccess.
	var legacy_completion_marker = abs_extract_dir + "/.extraction_complete"
	var legacy_success_marker = abs_extract_dir + "/.extraction_success"
	var legacy_progress_marker = abs_extract_dir + "/.extraction_progress"
	for marker in [completion_marker, success_marker, progress_marker, legacy_completion_marker, legacy_success_marker, legacy_progress_marker]:
		if file_exists(marker):
			delete_file(marker)
	
	# Start the extraction service
	var started = plugin.startExtractorService(abs_zip, abs_extract_dir, display_name)
	if not started:
		push_error("[SystemManager.filesystem] Failed to start ExtractorService")
		return false
	
	print("[SystemManager.filesystem] ExtractorService started, waiting for completion marker: " + completion_marker)
	
	# Wait for completion marker with timeout (30 minutes max for very large games)
	var timeout = 1800.0
	var elapsed = 0.0
	var completed = false
	var success = false
	var last_progress_read = 0.0
	
	while elapsed < timeout:
		if MemorySubManager.is_shutting_down():
			print("[SystemManager.filesystem] Extraction wait aborted: shutting down")
			return false
		# Check for completion marker (most reliable method)
		if file_exists(completion_marker):
			completed = true
			# Read success marker content ("true" or "false"). Retry briefly on an
			# empty/missing read: marker writes may go through SAF where visibility
			# lags, and older ExtractorService builds wrote completion before success.
			var success_text = ""
			for attempt in 10:
				success_text = read_file(success_marker).strip_edges()
				if success_text != "":
					break
				OS.delay_msec(200)
			success = success_text == "true"
			print("[SystemManager.filesystem] Extraction complete marker found, success=" + str(success))
			break

		# Poll progress file every ~2 seconds
		if progress_callback.is_valid() and elapsed - last_progress_read >= 2.0:
			var info := _read_extraction_progress(progress_marker)
			if not info.is_empty():
				progress_callback.call(info)
			last_progress_read = elapsed

		# Runs on the extraction worker thread; safe to sleep. Keeps the marker
		# polls from hammering the SAF provider and lets the timeout fire.
		OS.delay_msec(500)
		elapsed += 0.5
	
	# Read the final progress marker (written just before completion markers) so
	# the callback receives the real totals rather than the estimated fallback.
	if progress_callback.is_valid():
		var final_info := _read_extraction_progress(progress_marker)
		if not final_info.is_empty():
			progress_callback.call(final_info)
	
	# Clean up markers
	for marker in [completion_marker, success_marker, progress_marker]:
		if file_exists(marker):
			delete_file(marker)
	
	if not completed:
		push_error("[SystemManager.filesystem] Extraction service timed out")
		return false
	
	print("[SystemManager.filesystem] ExtractorService result for " + marker_base + ": " + str(success))
	return success

## Reads the ExtractorService progress marker and normalizes it to a Dictionary:
## {extracted_files, total_files, extracted_bytes, total_bytes, total_estimated, current_file}
static func _read_extraction_progress(progress_marker: String) -> Dictionary:
	if not file_exists(progress_marker):
		return {}
	var json_text = read_file(progress_marker)
	if json_text.is_empty():
		return {}
	var json = JSON.new()
	if json.parse(json_text) != OK or not (json.data is Dictionary):
		return {}
	var data: Dictionary = json.data
	return {
		"extracted_files": int(data.get("extracted", 0)),
		"total_files": int(data.get("total", 0)),
		"extracted_bytes": int(data.get("extracted_bytes", 0)),
		"total_bytes": int(data.get("total_bytes", 0)),
		"total_estimated": bool(data.get("total_estimated", false)),
		"current_file": str(data.get("current_file", "")),
	}

## Builds a normalized extraction progress Dictionary for paths that only know
## file counts (e.g. the 7-Zip desktop fallback).
static func _make_extraction_progress_info(extracted_files: int, total_files: int) -> Dictionary:
	return {
		"extracted_files": extracted_files,
		"total_files": total_files,
		"extracted_bytes": 0,
		"total_bytes": 0,
		"total_estimated": false,
		"current_file": "",
	}

## Formats a byte count as a human-readable string (e.g. "4.2 GB").
static func format_bytes(byte_count: int) -> String:
	if byte_count < 1024:
		return str(byte_count) + " B"
	var units := ["KB", "MB", "GB", "TB"]
	var value := float(byte_count)
	var unit_index := -1
	while value >= 1024.0 and unit_index < units.size() - 1:
		value /= 1024.0
		unit_index += 1
	return "%.1f %s" % [value, units[unit_index]]

## Extracts an archive using the bundled 7-Zip binary.
## Handles both ZIP and 7z archives on desktop platforms.
## progress_callback(info: Dictionary) is called every ~250ms while extracting.
## total_files will be 0 (unknown) if counting the archive listing failed.
## Returns true on success
static func _extract_with_7z(archive_path: String, extract_dir: String, progress_callback: Callable = Callable()) -> bool:
	var binary_path = _get_7z_binary_path()
	if binary_path == "":
		push_error("[SystemManager.filesystem] 7-Zip binary not available for fallback extraction")
		return false

	print("[SystemManager.filesystem] Using 7-Zip fallback for ZIP extraction: " + binary_path)

	var abs_archive = resolve_native_path(archive_path)
	var abs_extract_dir = resolve_native_path(extract_dir)

	print("[SystemManager.filesystem] 7-Zip extracting: " + abs_archive + " -> " + abs_extract_dir)

	# Ensure extraction directory exists before extracting
	if not dir_exists(abs_extract_dir):
		make_dir_recursive(abs_extract_dir)

	# Count total files first for accurate progress
	var total_files = _count_files_in_7z_archive(binary_path, abs_archive)
	if DEBUG_LOG: print("[SystemManager.filesystem] 7-Zip total files in archive: " + str(total_files))

	# Stream 7z's own progress output (-bsp1) instead of polling the extraction
	# directory with recursive file counts (the old approach re-walked tens of
	# thousands of files every 500ms, thrashing disk I/O against 7z itself).
	var args: PackedStringArray = ["x", abs_archive, "-o" + abs_extract_dir, "-y", "-bsp1"]
	var pipe: Dictionary = OS.execute_with_pipe(binary_path, args)
	if pipe.is_empty():
		return _extract_with_7z_blocking(binary_path, abs_archive, abs_extract_dir, total_files, progress_callback)

	if DEBUG_LOG: print("[SystemManager.filesystem] 7-Zip command: " + binary_path + " " + " ".join(args))

	var stdio: FileAccess = pipe["stdio"]
	var pid: int = pipe["pid"]
	var percent_regex := RegEx.new()
	percent_regex.compile("(\\d+)%")

	var last_percent := -1
	var last_callback_ms := 0
	# Keep a small tail between chunks so a percentage split across a chunk
	# boundary is still matched.
	var tail := ""

	while true:
		var chunk := stdio.get_buffer(4096)
		if chunk.is_empty():
			# No data right now; stop once the process has exited.
			if not OS.is_process_running(pid):
				break
			OS.delay_msec(50)
			continue
		var text := tail + chunk.get_string_from_utf8()
		tail = text.right(16)
		var search_from := 0
		while true:
			var m := percent_regex.search(text, search_from)
			if m == null:
				break
			last_percent = maxi(last_percent, int(m.get_string(1)))
			search_from = m.get_end()
		var now := Time.get_ticks_msec()
		if last_percent >= 0 and progress_callback.is_valid() and now - last_callback_ms >= 250:
			last_callback_ms = now
			var extracted := int(round(maxi(total_files, 0) * last_percent / 100.0))
			progress_callback.call(_make_extraction_progress_info(extracted, maxi(total_files, 0)))

	stdio.close()
	if pipe.get("stderr") is FileAccess:
		pipe["stderr"].close()

	var exit_code := OS.get_process_exit_code(pid)
	if DEBUG_LOG: print("[SystemManager.filesystem] 7-Zip exit code: " + str(exit_code))

	var success := exit_code == 0
	if success:
		if progress_callback.is_valid():
			progress_callback.call(_make_extraction_progress_info(maxi(total_files, 0), maxi(total_files, 0)))
		print("[SystemManager.filesystem] 7-Zip extraction completed successfully, " + str(maxi(total_files, 0)) + " files extracted")
	else:
		push_error("[SystemManager.filesystem] 7-Zip extraction failed with exit code: " + str(exit_code))

	return success

## Fallback extraction when a progress pipe cannot be created: runs 7z blocking
## on an inner thread and waits for completion with no incremental progress.
static func _extract_with_7z_blocking(binary_path: String, abs_archive: String, abs_extract_dir: String, total_files: int, progress_callback: Callable = Callable()) -> bool:
	var args: Array = ["x", abs_archive, "-o" + abs_extract_dir, "-y"]
	if DEBUG_LOG: print("[SystemManager.filesystem] 7-Zip command: " + binary_path + " " + " ".join(args))

	var result = {"done": false, "exit_code": -1}
	var thread = Thread.new()
	var run_7z = func():
		var output = []
		result.exit_code = OS.execute(binary_path, args, output, true)
		result.done = true
	thread.start(run_7z)

	while not result.done:
		OS.delay_msec(250)
	thread.wait_to_finish()

	if DEBUG_LOG: print("[SystemManager.filesystem] 7-Zip exit code: " + str(result.exit_code))
	var success: bool = result.exit_code == 0
	if success:
		if progress_callback.is_valid():
			progress_callback.call(_make_extraction_progress_info(maxi(total_files, 0), maxi(total_files, 0)))
		print("[SystemManager.filesystem] 7-Zip extraction completed successfully, " + str(maxi(total_files, 0)) + " files extracted")
	else:
		push_error("[SystemManager.filesystem] 7-Zip extraction failed with exit code: " + str(result.exit_code))

	return success

## Counts total files in a 7z archive using "7z l" command.
## Returns -1 if counting fails.
static func _count_files_in_7z_archive(binary_path: String, archive_path: String) -> int:
	print("[SystemManager.filesystem] Listing archive: " + archive_path)
	var output = []
	var args = ["l", archive_path]
	var exit_code = OS.execute(binary_path, args, output, true)
	
	if exit_code != 0:
		push_warning("[SystemManager.filesystem] Failed to list archive contents, progress will be indeterminate")
		return -1
	
	# OS.execute returns output as array of strings - often one big string per element on Windows
	# Join everything and split by newlines to get individual lines
	var full_text = "\n".join(output)
	var lines = full_text.split("\n", false)
	if DEBUG_LOG: print("[SystemManager.filesystem] 7z list: " + str(lines.size()) + " lines total")
	
	# The summary line is typically the last non-empty line
	# Format: "20643          311  2 files, 0 folders"
	# We want the number before " files" (field $3 in awk)
	for i in range(lines.size() - 1, -1, -1):
		var line = lines[i].strip_edges()
		if line.is_empty():
			continue
		
		# Look for "files," pattern
		if line.contains("files,") or line.contains("files "):
			# Use regex to extract: (number) files
			var regex = RegEx.new()
			regex.compile("(\\d+)\\s+files")
			var match = regex.search(line)
			if match:
				var num_str = match.get_string(1)
				if DEBUG_LOG: print("[SystemManager.filesystem] Found total files from summary: " + num_str)
				return int(num_str)
			
		# Only check last 5 non-empty lines for summary
		var checked = 0
		for j in range(i, -1, -1):
			if not lines[j].strip_edges().is_empty():
				checked += 1
				if checked >= 5:
					break
		if checked >= 5:
				break
	
	# Fallback: count individual file entries
	# Format: "YYYY-MM-DD HH:MM:SS .R..A   Size   Compressed  Name"
	var file_count = 0
	for line in lines:
		line = line.strip_edges()
		if line.length() > 25:
			# Check for attribute at position 20 (after timestamp "YYYY-MM-DD HH:MM:SS ")
			var attr = line.substr(20, 5)
			# Files start with '.', directories start with 'D'
			if attr.length() == 5 and attr[0] == ".":
				file_count += 1
	
	if DEBUG_LOG: print("[SystemManager.filesystem] Counted files from entries: " + str(file_count))
	return file_count if file_count > 0 else -1

## Gets the bundled 7z binary path for the current platform.
## Packaged builds return the extracted copy under user://bin/ since
## binaries inside the PCK cannot be executed.
static func _get_7z_binary_path() -> String:
	var res_path = ""
	match OS.get_name():
		"Windows":
			res_path = "res://bin/7z/windows/7za.exe"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			res_path = "res://bin/7z/linux/7z"
		_:
			return ""

	# Runtime load avoids a cyclic preload with utils/launch/android_binary_extractor.gd
	var extractor = load("res://utils/launch/android_binary_extractor.gd")
	return extractor.extract_binary(res_path, res_path.get_file())

## Gets the directory portion of a path
static func get_dir(path: String) -> String:
	return path.get_base_dir()

## Gets the filename portion of a path
static func get_filename(path: String) -> String:
	return path.get_file()

## Gets the file extension
static func get_extension(path: String) -> String:
	return path.get_extension()

## Checks if a path is a directory
static func is_dir(path: String) -> bool:
	return dir_exists(path)

## Detects symbolic links/junctions without following them. SAF document trees
## do not expose host symlink semantics, so restricted Android paths return false.
static func is_symlink(path: String) -> bool:
	if path.is_empty() or _is_restricted_android_path(path):
		return false
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())

## Gets a list of all files (not directories) in a directory
static func get_files(path: String) -> Array[String]:
	var result: Array[String] = []
	var items = list_dir(path)
	
	for item in items:
		var item_path = join_paths(path, item)
		if not is_dir(item_path):
			result.append(item)
	
	return result

## Gets a list of all subdirectories in a directory
static func get_dirs(path: String) -> Array[String]:
	var result: Array[String] = []
	var items = list_dir(path)
	
	for item in items:
		var item_path = join_paths(path, item)
		if is_dir(item_path):
			result.append(item)
	
	return result

## Recursively searches for a file by name starting from dir_path
## Returns the full path to the file, or empty string if not found
static func find_file_recursive(dir_path: String, filename: String) -> String:
	if dir_path.is_empty() or filename.is_empty():
		return ""
	
	if not dir_exists(dir_path):
		return ""
	
	var items = list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var item_path = join_paths(dir_path, item)
		
		if item == filename:
			return item_path
		
		if is_dir(item_path):
			var found = find_file_recursive(item_path, filename)
			if not found.is_empty():
				return found
	
	return ""

## Recursively finds ALL files matching filename under dir_path.
static func find_files_recursive(dir_path: String, filename: String) -> Array[String]:
	var results: Array[String] = []
	if dir_path.is_empty() or filename.is_empty():
		return results
	
	if not dir_exists(dir_path):
		return results
	
	var items = list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var item_path = join_paths(dir_path, item)
		
		if item == filename:
			results.append(item_path)
		
		if is_dir(item_path):
			results.append_array(find_files_recursive(item_path, filename))
	
	return results

## Recursively removes empty directories under dir_path (bottom-up).
## dir_path itself is never removed. Used to clean up leftover wrapper folder
## shells (e.g. "Game Name/TitleID/") after unwrapping extracted games.
static func prune_empty_dirs(dir_path: String) -> void:
	if dir_path.is_empty() or not dir_exists(dir_path):
		return
	
	var items = list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		var item_path = join_paths(dir_path, item)
		if is_dir(item_path):
			prune_empty_dirs(item_path)
			if list_dir(item_path).is_empty():
				delete_dir_recursive(item_path)

## Recursively counts files (not directories) in a directory
## Returns the total file count
static func count_files_recursive(dir_path: String) -> int:
	if dir_path.is_empty() or not dir_exists(dir_path):
		return 0
	
	var count = 0
	var items = list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var item_path = join_paths(dir_path, item)
		if is_dir(item_path):
			count += count_files_recursive(item_path)
		else:
			count += 1
	
	return count

## Moves all contents from source_dir to dest_dir
## Tries rename first (fast), falls back to copy+delete for cross-boundary moves
## Returns true on success
static func move_dir_contents(source_dir: String, dest_dir: String) -> bool:
	if source_dir.is_empty() or dest_dir.is_empty():
		return false
	
	if not dir_exists(source_dir):
		push_error("[SystemManager.filesystem] Source directory does not exist: " + source_dir)
		return false
	
	if not dir_exists(dest_dir):
		if not make_dir_recursive(dest_dir):
			push_error("[SystemManager.filesystem] Failed to create destination directory: " + dest_dir)
			return false
	
	var items = list_dir(source_dir)
	var moved_count = 0
	
	for item in items:
		if item == "." or item == "..":
			continue
		
		var source = join_paths(source_dir, item)
		var dest = join_paths(dest_dir, item)
		if is_dir(source) and dir_exists(dest):
			# Android ROOT `mv source existing-dir` nests source inside the
			# destination. Recurse and rename individual entries instead of
			# copying the whole directory; copy remains each entry's fallback.
			if not move_dir_contents(source, dest):
				return false
			if not delete_dir_recursive(source):
				if DEBUG_LOG: print("[SystemManager.filesystem] WARNING: Failed to delete merged source directory: " + source)
			moved_count += 1
			continue
		
		# Try rename first (fast, same filesystem)
		if move(source, dest):
			moved_count += 1
			continue
		
		# Rename failed - try copy+delete
		if DEBUG_LOG: print("[SystemManager.filesystem] Rename failed for " + source + ", falling back to copy+delete...")
		if file_exists(source):
			if DEBUG_LOG: print("[SystemManager.filesystem] Copying file: " + source + " -> " + dest)
			if not copy_file(source, dest):
				push_error("[SystemManager.filesystem] Failed to copy file: " + source + " -> " + dest)
				return false
			if DEBUG_LOG: print("[SystemManager.filesystem] Deleting source file: " + source)
			var del_success = delete_file(source)
			if not del_success:
				if DEBUG_LOG: print("[SystemManager.filesystem] WARNING: Failed to delete source file: " + source)
			moved_count += 1
		elif is_dir(source):
			if DEBUG_LOG: print("[SystemManager.filesystem] Copying directory: " + source + " -> " + dest)
			if not copy_dir(source, dest):
				push_error("[SystemManager.filesystem] Failed to copy directory: " + source + " -> " + dest)
				return false
			if DEBUG_LOG: print("[SystemManager.filesystem] Deleting source directory: " + source)
			var del_success = delete_dir_recursive(source)
			if not del_success:
				if DEBUG_LOG: print("[SystemManager.filesystem] WARNING: Failed to delete source directory: " + source)
			moved_count += 1
	
	print("[SystemManager.filesystem] Moved " + str(moved_count) + " items from " + source_dir + " to " + dest_dir)
	return true

## Builds a read-only extraction-layout plan from a bounded filesystem snapshot.
## See utils/filesystem/extraction_layout.gd for the supported policy options.
static func plan_extraction_layout(target_dir: String, options: Dictionary = {}) -> Dictionary:
	if target_dir.is_empty() or not dir_exists(target_dir):
		return {
			"status": "io_error",
			"payload_root": "",
			"depth": 0,
			"matched_anchors": [],
			"candidates": [],
			"error": "Extraction target does not exist or is not accessible: " + target_dir,
		}
	var entries: Array[Dictionary] = []
	var unsafe_entries: Array = []
	_collect_extraction_layout_entries(target_dir, "", 0, _extraction_scan_depth(options), entries, unsafe_entries)
	if not unsafe_entries.is_empty():
		return {
			"status": "unsafe_entry",
			"payload_root": "",
			"depth": 0,
			"matched_anchors": [],
			"candidates": unsafe_entries,
			"error": "Symbolic links are not supported inside extracted payloads",
		}
	return ExtractionLayout.plan(entries, options)

## Normalizes an extracted payload according to a declarative layout policy.
## target_dir must contain only this operation's output (normally isolated
## staging); a live root's old anchors cannot identify the newest archive.
## Successful hoists preflight actual file collisions and return the final path.
static func normalize_extraction_layout(target_dir: String, options: Dictionary = {}) -> Dictionary:
	var result := {
		"status": "io_error",
		"payload_root": "",
		"depth": 0,
		"matched_anchors": [],
		"candidates": [],
		"error": "",
		"moved": false,
		"path": target_dir,
		"source_path": "",
		"collisions": [],
	}
	if target_dir.is_empty() or not dir_exists(target_dir):
		result.error = "Extraction target does not exist or is not accessible: " + target_dir
		return result

	# Collect links and backslash-named entries in one bounded walk. No rename
	# is attempted when any link is present in the scanned payload.
	var linked_entries := _normalize_backslash_paths(target_dir, true, _extraction_scan_depth(options))
	if not linked_entries.is_empty():
		result.status = "unsafe_entry"
		result.error = "Symbolic links are not supported inside extracted payloads"
		result.candidates = linked_entries
		return result
	var layout := plan_extraction_layout(target_dir, options)
	for key in layout:
		result[key] = layout[key]
	if result.status != ExtractionLayout.STATUS_HOIST:
		return result

	var relative_root := str(result.payload_root)
	var source_dir := join_paths(target_dir, relative_root)
	result.source_path = source_dir
	if source_dir == target_dir or not is_path_contained(source_dir, target_dir):
		result.status = "unsafe_entry"
		result.error = "Normalized payload root escapes extraction target: " + relative_root
		return result

	# Preflight the complete payload. Directories may merge when their contents
	# are disjoint; actual file conflicts and every symlink are rejected before
	# the first move. This also covers content below the planner's scan depth.
	var collisions: Array = []
	var unsafe_entries: Array = []
	var type_collisions: Array = []
	_collect_extraction_commit_conflicts(source_dir, target_dir, collisions, unsafe_entries, type_collisions)
	collisions.append_array(type_collisions)
	if not unsafe_entries.is_empty():
		result.status = "unsafe_entry"
		result.error = "Symbolic links are not supported in extraction payloads or their destinations"
		result.collisions = unsafe_entries
		return result
	if not collisions.is_empty():
		result.status = "collision"
		result.error = "Extracted payload would overwrite existing destination entries"
		result.collisions = collisions
		return result

	if not move_dir_contents(source_dir, target_dir):
		result.status = "io_error"
		result.error = "Failed to hoist extracted payload from " + source_dir + " to " + target_dir
		return result

	# Remove only empty wrapper directories. A wrapper containing unrelated or
	# ignored archive content, and every ancestor above it, is left in place.
	var current := source_dir
	while normalize_path(current) != normalize_path(target_dir) and is_path_contained(current, target_dir):
		if not list_dir(current).is_empty():
			break
		if not delete_dir_recursive(current):
			break
		current = current.get_base_dir()

	result.status = "normalized"
	result.moved = true
	result.path = target_dir
	print("[SystemManager.filesystem] Hoisted extraction payload from " + source_dir + " to " + target_dir)
	return result

## Commits an already-normalized staging tree into a live destination. Existing
## real files are replaced (matching 7-Zip's update behavior), disjoint folders
## are merged, and symlink source/destination entries fail the whole preflight.
static func merge_extraction_payload(source_dir: String, dest_dir: String) -> Dictionary:
	var result := {
		"status": "io_error",
		"path": dest_dir,
		"source_path": source_dir,
		"error": "",
		"overwritten": [],
	}
	if source_dir.is_empty() or dest_dir.is_empty() or source_dir == dest_dir or not dir_exists(source_dir) or is_symlink(source_dir):
		result.error = "Invalid extraction commit source or destination"
		return result
	var destination_existed := dir_exists(dest_dir)
	if not destination_existed and not make_dir_recursive(dest_dir.get_base_dir()):
		result.error = "Could not create extraction commit destination parent: " + dest_dir.get_base_dir()
		return result

	var overwritten: Array = []
	var unsafe_entries: Array = []
	var type_collisions: Array = []
	_collect_extraction_commit_conflicts(source_dir, dest_dir, overwritten, unsafe_entries, type_collisions)
	if not type_collisions.is_empty():
		result.status = "collision"
		result.error = "Cannot merge files and directories with conflicting types"
		result.overwritten = type_collisions
		return result
	if not unsafe_entries.is_empty():
		result.status = "unsafe_entry"
		result.error = "Symbolic links are not supported in extraction payloads or their destinations"
		result.overwritten = unsafe_entries
		return result
	result.overwritten = overwritten
	if not destination_existed and move(source_dir, dest_dir):
		result.status = "committed"
		return result
	if not destination_existed and not make_dir_recursive(dest_dir):
		result.error = "Could not create extraction commit destination: " + dest_dir
		return result
	if not move_dir_contents(source_dir, dest_dir):
		result.error = "Failed to merge extracted payload into " + dest_dir
		return result
	if dir_exists(source_dir) and list_dir(source_dir).is_empty():
		delete_dir_recursive(source_dir)
	result.status = "committed"
	return result

## Replaces one owned payload root (for example a per-title game directory)
## instead of merging into it. The source and destination should be siblings on
## the same filesystem so commit uses rename instead of a partial-copy fallback.
static func replace_extraction_payload(source_dir: String, dest_dir: String, keep_backup: bool = false) -> Dictionary:
	var result := {
		"status": "io_error",
		"path": dest_dir,
		"source_path": source_dir,
		"backup_path": "",
		"error": "",
	}
	if source_dir.is_empty() or dest_dir.is_empty() or source_dir == dest_dir or not dir_exists(source_dir) or is_symlink(source_dir) or is_symlink(dest_dir):
		result.error = "Invalid extraction replacement source or destination"
		return result
	if extraction_tree_has_symlinks(source_dir):
		result.status = "unsafe_entry"
		result.error = "Symbolic links are not supported inside extracted payloads"
		return result
	if not make_dir_recursive(dest_dir.get_base_dir()):
		result.error = "Could not create replacement destination parent: " + dest_dir.get_base_dir()
		return result
	if _is_restricted_android_path(source_dir) or _is_restricted_android_path(dest_dir):
		return _replace_extraction_payload_saf(source_dir, dest_dir, keep_backup, result)

	var backup_dir := ""
	if dir_exists(dest_dir) or file_exists(dest_dir):
		backup_dir = join_paths(dest_dir.get_base_dir(), ".kyodai-backup-" + dest_dir.get_file() + "-" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))
		if not move(dest_dir, backup_dir):
			result.error = "Could not move existing payload aside for replacement"
			return result
		result.backup_path = backup_dir

	var committed := move(source_dir, dest_dir)
	if not committed:
		# Do not start a partially consumable copy: the old payload must remain
		# recoverable. Remove only the incomplete new destination, then restore.
		if dir_exists(dest_dir):
			delete_dir_recursive(dest_dir)
		elif file_exists(dest_dir):
			delete_file(dest_dir)
		if backup_dir != "":
			if move(backup_dir, dest_dir):
				result.backup_path = ""
			else:
				result.error = "Replacement failed and the previous payload is preserved at " + backup_dir
				return result
		result.error = "Failed to replace extracted payload at " + dest_dir
		return result

	if dir_exists(source_dir) and list_dir(source_dir).is_empty():
		delete_dir_recursive(source_dir)
	if backup_dir != "" and not keep_backup:
		if dir_exists(backup_dir):
			delete_dir_recursive(backup_dir)
		elif file_exists(backup_dir):
			delete_file(backup_dir)
		result.backup_path = ""
	result.status = "replaced"
	return result

## Android's recursive directory rename can consume some children before
## failing. Use an unconsumed backup for restricted paths so the previous
## install is always recoverable; never restore by moving that backup away.
static func _replace_extraction_payload_saf(source_dir: String, dest_dir: String, keep_backup: bool, result: Dictionary) -> Dictionary:
	var backup_dir := ""
	if dir_exists(dest_dir) or file_exists(dest_dir):
		backup_dir = join_paths(dest_dir.get_base_dir(), ".kyodai-backup-" + dest_dir.get_file() + "-" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))
		if not _copy_payload_root(dest_dir, backup_dir):
			_delete_payload_root(backup_dir)
			result.error = "Could not preserve the existing Android payload before replacement"
			return result
		result.backup_path = backup_dir
		if not _delete_payload_root(dest_dir):
			if _restore_replacement_backup(backup_dir, dest_dir) and not keep_backup:
				_delete_payload_root(backup_dir)
				result.backup_path = ""
			result.error = "Could not clear the previous Android payload for replacement"
			return result

	if not move(source_dir, dest_dir):
		_delete_payload_root(dest_dir)
		if backup_dir != "" and not _restore_replacement_backup(backup_dir, dest_dir):
			result.error = "Replacement failed and the previous payload is preserved at " + backup_dir
			return result
		if backup_dir != "" and not keep_backup:
			_delete_payload_root(backup_dir)
			result.backup_path = ""
		result.error = "Failed to replace extracted Android payload at " + dest_dir
		return result

	if dir_exists(source_dir) and list_dir(source_dir).is_empty():
		delete_dir_recursive(source_dir)
	if backup_dir != "" and not keep_backup:
		_delete_payload_root(backup_dir)
		result.backup_path = ""
	result.status = "replaced"
	return result

static func _restore_replacement_backup(backup_dir: String, dest_dir: String) -> bool:
	# Restoration is copy-based and therefore leaves the backup intact on error.
	return _delete_payload_root(dest_dir) and _copy_payload_root(backup_dir, dest_dir)

static func _copy_payload_root(source_dir: String, dest_dir: String) -> bool:
	if dir_exists(source_dir):
		return copy_dir(source_dir, dest_dir)
	if file_exists(source_dir):
		return copy_file(source_dir, dest_dir)
	return false

static func _delete_payload_root(path: String) -> bool:
	if dir_exists(path):
		return delete_dir_recursive(path)
	if file_exists(path):
		return delete_file(path)
	return true

## Creates a restorable backup for a shared save root. Always copy: the old
## contents must remain present during the merge and available for rollback.
static func create_extraction_backup(path: String) -> Dictionary:
	if not dir_exists(path) and not file_exists(path):
		return {"success": true, "backup_path": "", "error": ""}
	var backup_path := join_paths(path.get_base_dir(), ".kyodai-backup-" + path.get_file() + "-" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000))
	if not _copy_payload_root(path, backup_path):
		_delete_payload_root(backup_path)
		return {"success": false, "backup_path": "", "error": "could not copy save backup"}
	return {"success": true, "backup_path": backup_path, "error": ""}

## Restores a backup created by create_extraction_backup. The backup remains
## recoverable if the restore itself fails.
static func restore_extraction_backup(backup_path: String, dest_dir: String) -> bool:
	if backup_path == "":
		return true
	if not dir_exists(backup_path) and not file_exists(backup_path):
		return false
	if _is_restricted_android_path(backup_path) or _is_restricted_android_path(dest_dir):
		return _restore_replacement_backup(backup_path, dest_dir)
	if not _delete_payload_root(dest_dir):
		return false
	return move(backup_path, dest_dir)

static func delete_extraction_backup(backup_path: String) -> bool:
	return _delete_payload_root(backup_path)

## Compatibility wrapper for firmware's any-of expected-file policy.
static func normalize_extraction_root(target_dir: String, expected_names: Array, max_depth: int = 3) -> Dictionary:
	return normalize_extraction_layout(target_dir, {
		"expected_any": expected_names,
		"max_depth": max_depth,
	})

static func _extraction_scan_depth(options: Dictionary) -> int:
	var scan_depth := maxi(1, int(options.get("max_depth", 3)))
	for group in ["expected_any", "expected_all"]:
		for anchor in options.get(group, []):
			var anchor_path := str(anchor).replace("\\", "/").strip_edges().trim_prefix("./")
			scan_depth = maxi(scan_depth, int(options.get("max_depth", 3)) + maxi(1, anchor_path.get_slice_count("/")))
	return scan_depth

static func _collect_extraction_layout_entries(root_dir: String, relative_dir: String, depth: int, max_depth: int, out: Array[Dictionary], unsafe_entries: Array) -> void:
	var current_dir := root_dir if relative_dir == "" else join_paths(root_dir, relative_dir)
	for entry in list_dir(current_dir):
		if entry == "." or entry == "..":
			continue
		var relative_path := entry if relative_dir == "" else relative_dir + "/" + entry
		var full_path := join_paths(root_dir, relative_path)
		if is_symlink(full_path):
			unsafe_entries.append(relative_path)
			continue
		var directory := is_dir(full_path)
		out.append({"path": relative_path, "is_dir": directory})
		if directory and depth < max_depth:
			_collect_extraction_layout_entries(root_dir, relative_path, depth + 1, max_depth, out, unsafe_entries)

static func extraction_tree_has_symlinks(root_dir: String) -> bool:
	if root_dir.is_empty() or not dir_exists(root_dir):
		return false
	var linked_entries: Array = []
	_collect_extraction_symlinks(root_dir, "", linked_entries)
	return not linked_entries.is_empty()

static func _collect_extraction_symlinks(root_dir: String, relative_dir: String, out: Array) -> void:
	var current_dir := root_dir if relative_dir == "" else join_paths(root_dir, relative_dir)
	for entry in list_dir(current_dir):
		if entry == "." or entry == "..":
			continue
		var relative_path := entry if relative_dir == "" else relative_dir + "/" + entry
		var full_path := join_paths(root_dir, relative_path)
		if is_symlink(full_path):
			out.append(relative_path)
		elif is_dir(full_path):
			_collect_extraction_symlinks(root_dir, relative_path, out)

static func _collect_extraction_commit_conflicts(source_dir: String, dest_dir: String, collisions: Array, unsafe_entries: Array, type_collisions: Array) -> void:
	for item in list_dir(source_dir):
		if item == "." or item == "..":
			continue
		var source := join_paths(source_dir, item)
		var destination := join_paths(dest_dir, item)
		if is_symlink(source) or is_symlink(destination):
			unsafe_entries.append(source if is_symlink(source) else destination)
			continue
		if is_dir(source):
			if dir_exists(destination):
				_collect_extraction_commit_conflicts(source, destination, collisions, unsafe_entries, type_collisions)
			elif file_exists(destination):
				type_collisions.append(destination)
			else:
				# Still scan the new subtree for links and file-type conflicts.
				_collect_extraction_commit_conflicts(source, destination, collisions, unsafe_entries, type_collisions)
		elif dir_exists(destination):
			type_collisions.append(destination)
		elif file_exists(destination):
			collisions.append(destination)

## Renames files and directories extracted with Windows-style backslash path
## separators into real nested directories. Some archives (often firmware dumps
## packed on Windows) store paths like os0\kd\foo.skprx; on Linux 7-Zip extracts
## that as a single file named "os0\kd\foo.skprx" instead of a nested path.
## This fixes those entries so the rest of Kyodai's path logic works.
static func _normalize_backslash_paths(root_dir: String, deep_scan: bool = false, max_depth: int = -1) -> Array:
	if root_dir.is_empty() or not dir_exists(root_dir):
		return []

	# Preserve the cheap common-case exit for raw extraction. Layout normalization
	# requests a deep scan because backslash-named entries can occur below
	# otherwise-normal directories; otherwise the planner could select a source
	# path that does not exist on disk yet.
	if not deep_scan:
		var needs_normalization := false
		for entry in list_dir(root_dir):
			if entry.contains("\\"):
				needs_normalization = true
				break
		if not needs_normalization:
			return []

	var entries: Array[Dictionary] = []
	var linked_entries: Array = []
	_normalize_backslash_collect(root_dir, "", 0, entries, linked_entries, max_depth)
	if not linked_entries.is_empty():
		return linked_entries
	if entries.is_empty():
		return []
	
	# Process deepest filesystem entries first so files/subdirectories are moved
	# out of fake parent directories before those directories are handled.
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["depth"] > b["depth"]
	)
	
	var moved_count := 0
	for entry in entries:
		var old_full: String = entry["full"]
		var new_rel: String = entry["rel"].replace("\\", "/")
		var entry_is_dir := entry["is_dir"] as bool

		# Directory entries from Windows-style ZIPs often have trailing
		# backslashes in their names. Strip that from the target path so we
		# rename to the real directory instead of moving into it.
		if entry_is_dir and new_rel.ends_with("/"):
			new_rel = new_rel.substr(0, new_rel.length() - 1)
		
		var new_full: String = join_paths(root_dir, new_rel)
		if new_full == old_full:
			continue

		# Archive members can hide traversal behind backslashes (e.g. a file
		# literally named "..\..\evil" extracts inside root_dir, but renaming
		# it would move it outside). Never normalize past the extraction root.
		if not is_path_contained(new_full, root_dir):
			push_warning("[SystemManager.filesystem] Skipping backslash normalization that escapes extraction root: " + entry["rel"])
			continue
		
		if entry_is_dir:
			if dir_exists(new_full):
				# Target directory already exists (created while moving a file
				# or subdirectory into it). Remove the old empty fake directory.
				if _delete_dir_literal(old_full):
					moved_count += 1
				else:
					print("[SystemManager.filesystem] Failed to remove old fake dir: " + old_full)
			elif _rename_literal(old_full, new_full):
				moved_count += 1
			else:
				print("[SystemManager.filesystem] Failed to normalize dir: " + old_full + " -> " + new_full)
		else:
			if _rename_literal(old_full, new_full):
				moved_count += 1
			else:
				print("[SystemManager.filesystem] Failed to normalize file: " + old_full + " -> " + new_full)
	
	if moved_count > 0:
		if DEBUG_LOG: print("[SystemManager.filesystem] Normalized " + str(moved_count) + " backslash path(s) in " + root_dir)
	return []

static func _normalize_backslash_collect(full_path: String, rel_path: String, depth: int, out: Array[Dictionary], linked_entries: Array, max_depth: int) -> void:
	if rel_path != "" and rel_path.contains("\\"):
		# Windows-style directory entries in ZIPs end with a backslash, and
		# Godot's is_dir() normalizes backslashes so it can't tell. Use the
		# stored path itself to decide.
		out.append({
			"full": full_path,
			"rel": rel_path,
			"is_dir": rel_path.ends_with("\\"),
			"depth": depth,
		})
	if max_depth >= 0 and depth >= max_depth:
		return

	# Recurse even for backslash-named directories; children must be moved out
	# before the parent can be removed/renamed. Links are reported, never followed.
	for entry in list_dir(full_path):
		if entry == "." or entry == "..":
			continue
		var child_path := join_paths(full_path, entry)
		if is_symlink(child_path):
			linked_entries.append(child_path)
			continue
		var child_rel := entry if rel_path == "" else rel_path + "\\" + entry
		_normalize_backslash_collect(child_path, child_rel, depth + 1, out, linked_entries, max_depth)

## OS-level rename that preserves literal backslashes in filenames. Godot's
## DirAccess.rename_absolute normalizes backslashes into path separators, which
## breaks renaming entries extracted from Windows-style ZIPs on Linux.
static func _rename_literal(old_full: String, new_full: String) -> bool:
	if old_full.is_empty() or new_full.is_empty():
		return false
	
	var parent := new_full.get_base_dir()
	if not parent.is_empty() and not dir_exists(parent):
		if not make_dir_recursive(parent):
			return false
	
	# No literal backslash in the name: use the normal path.
	if not old_full.contains("\\"):
		return move(old_full, new_full)
	
	# On Unix-likes, filenames can contain '\' and Godot's built-in rename
	# normalizes it away. Use mv through /bin/sh with single-quoted paths so
	# the backslash stays literal. Convert Godot virtual paths (user://,
	# res://) to absolute OS paths first because the shell doesn't understand
	# them.
	if OS.get_name() != "Windows":
		var output: Array[String] = []
		var abs_old := ProjectSettings.globalize_path(old_full)
		var abs_new := ProjectSettings.globalize_path(new_full)
		var cmd := "mv " + _shell_quote(abs_old) + " " + _shell_quote(abs_new)
		return OS.execute("/bin/sh", ["-c", cmd], output, true) == 0
	
	# Windows filenames cannot contain backslashes, so this branch should not
	# be reachable. Fall back to the built-in move just in case.
	return move(old_full, new_full)

static func _delete_dir_literal(path: String) -> bool:
	if path.is_empty():
		return false
	
	# No literal backslash: use the normal path.
	if not path.contains("\\"):
		return delete_dir_recursive(path)
	
	# On Unix-likes, use rmdir through /bin/sh so the backslash stays literal.
	# rmdir only succeeds when the directory is empty, which is what we want
	# after moving out all children first. Convert virtual paths to absolute
	# OS paths because the shell doesn't understand user:// / res://.
	if OS.get_name() != "Windows":
		var output: Array[String] = []
		var abs_path := ProjectSettings.globalize_path(path)
		var cmd := "rmdir " + _shell_quote(abs_path)
		return OS.execute("/bin/sh", ["-c", cmd], output, true) == 0
	
	return delete_dir_recursive(path)

static func _shell_quote(s: String) -> String:
	# POSIX single-quote quoting: everything inside is literal except ' itself,
	# which is escaped by ending the quote, inserting an escaped quote, and
	# resuming.
	return "'" + s.replace("'", "'\\''") + "'"
