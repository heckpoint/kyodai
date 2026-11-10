## Unified title ID / serial parser for all platforms
## Extracts game identifiers from ROM files for save sync purposes
class_name TitleIDParser

const DEBUG_LOG: bool = false
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")

# Sigil CLI runner for platforms routed through argosy-sigil
const _SigilRunner = preload("res://utils/identity/sigil_runner.gd")

# ZArchive reader for Xbox 360 .zar ROMs (compressed ISO contents)
const _ZarReader = preload("res://utils/identity/zar_reader.gd")

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

## Opens a file for reading and calls the callback. Handles error checking and cleanup.
## Returns the callback's result, or empty string on failure.
static func _with_open_file(path: String, callback: Callable) -> String:
	if not FSM.file_exists(path):
		push_error("[TitleIDParser] File not found: " + path)
		return ""
	
	var file = FSM.open_file_read(path)
	if not file:
		push_error("[TitleIDParser] Failed to open file: " + path)
		return ""
	
	var result = callback.call(file)
	file.close()
	return result

## Reads little-endian uint32 from byte array
static func _read_le32(bytes: PackedByteArray, offset: int) -> int:
	return bytes.decode_u32(offset)

## Reads big-endian uint32 from byte array
static func _read_be32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]

## Resolves a ZIP file path for opening with ZIPReader
## Handles Godot virtual paths, globalizes them, and tries Windows backslashes
## Returns the resolved path or empty string if file cannot be found
static func _resolve_zip_path(zip_path: String) -> String:
	# On Windows, prefer backslash paths for ZIPReader compatibility
	if OS.get_name() == "Windows":
		var backslash_path = zip_path.replace("/", "\\")
		if FSM.file_exists(backslash_path):
			# Resolve to absolute if it's a virtual path (external tools need real paths)
			if backslash_path.begins_with("user://") or backslash_path.begins_with("res://"):
				return FSM.resolve_path(backslash_path, {"format": FSM.PathFormat.ABSOLUTE})
			return backslash_path
	
	# Try original path
	if FSM.file_exists(zip_path):
		# Resolve to absolute if it's a virtual path (external tools need real paths)
		if zip_path.begins_with("user://") or zip_path.begins_with("res://"):
			return FSM.resolve_path(zip_path, {"format": FSM.PathFormat.ABSOLUTE})
		return zip_path
	
	# Try absolute path (resolves user://, res://, etc.)
	var abs_path = FSM.resolve_path(zip_path, {"format": FSM.PathFormat.ABSOLUTE})
	if abs_path != zip_path and FSM.file_exists(abs_path):
		return abs_path
	
	return ""

# ============================================================================
# PLATFORM-SPECIFIC EXTRACTORS
# ============================================================================

# ==================== Switch (Eden) ====================

static func _get_prod_keys_path(emulator_dir: String) -> String:
	var keys_path := ""

	if SystemManager.platform.is_android():
		keys_path = "/storage/emulated/0/Android/data/dev.eden.eden_emulator/files/keys/prod.keys"
	else:
		keys_path = emulator_dir.rstrip("/") + "/user/keys/prod.keys"

	return keys_path if FSM.file_exists(keys_path) else ""

# ==================== GameCube/Wii (Dolphin) ====================

static func _is_valid_upper_alnum(value: String, expected_length: int) -> bool:
	if value.length() != expected_length:
		return false
	for c in value:
		if not ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')):
			return false
	return true

static func extract_gamecube_game_id_from_existing_saves(emulator_dir: String) -> String:
	var regions: Array[String] = ["USA", "EUR", "JAP", "KOR"]
	for region in regions:
		var card_dirs: Array[String] = ["Card A", "Card B"]
		for card in card_dirs:
			var card_path = emulator_dir.rstrip("/") + "/User/GC/" + region + "/" + card + "/"
			if not FSM.dir_exists(card_path):
				continue
			var items = FSM.list_dir(card_path)
			for item in items:
				if item == "." or item == "..":
					continue
				if item.to_lower().ends_with(".gci"):
					var gci_path = card_path + item
					var result = _with_open_file(gci_path, func(file: FileAccess) -> String:
						var header = file.get_buffer(6)
						if header.size() < 6:
							return ""
						var game_id = header.slice(0, 4).get_string_from_ascii()
						var maker = header.slice(4, 6).get_string_from_ascii()
						if _is_valid_upper_alnum(game_id, 4) and _is_valid_upper_alnum(maker, 2):
							return game_id
						return ""
					)
					if result != "":
						return result
	return ""

# ==================== Wii WAD (WiiWare/VC, Dolphin) ====================

const _WAD_TYPES = [0x4973, 0x6962, 0x426B]  # "Is", "ib", "Bk"
const _WAD_TICKET_TITLE_ID_OFFSET = 0x1DC
const _WAD_TMD_TITLE_ID_OFFSETS = [0x18C, 0x190]

static func _wad_align64(value: int) -> int:
	return (value + 63) & ~63

## Returns true if the 4 bytes are all [A-Z0-9] (the low half of a title id
## is the ASCII game code, same rule sigil uses for disc IDs).
static func _wad_ascii4_valid(bytes: PackedByteArray, offset: int) -> bool:
	if bytes.size() < offset + 4:
		return false
	for i in range(offset, offset + 4):
		var b = bytes[i]
		if not ((b >= 0x41 and b <= 0x5A) or (b >= 0x30 and b <= 0x39)):
			return false
	return true

## Reads the 8-byte big-endian title id at offset + id_offset; returns
## 16 lowercase hex chars, or "" if out of bounds or invalid.
static func _wad_title_id_at(file: FileAccess, offset: int, id_offset: int) -> String:
	if offset < 0 or offset + id_offset + 8 > file.get_length():
		return ""
	file.seek(offset + id_offset)
	var id_bytes = file.get_buffer(8)
	if id_bytes.size() < 8 or not _wad_ascii4_valid(id_bytes, 4):
		return ""
	var title_id = ""
	for b in id_bytes:
		title_id += "%02x" % b
	return title_id

## Extracts the full 16-char title ID from a Wii WAD package (WiiWare/VC).
## Primary: ticket title_id; fallback: TMD title_id (ticketless/fakesigned
## WADs). The category half is kept so save restore picks the correct NAND
## root (00010001/00010004 for WiiWare). Returns "" on any parse failure.
static func extract_wii_wad_title_id(wad_path: String) -> String:
	return _with_open_file(wad_path, func(file: FileAccess) -> String:
		if file.get_length() < 0x18:
			return ""
		var header = file.get_buffer(0x18)
		if header.size() < 0x18:
			return ""
		var header_len = _read_be32(header, 0x00)
		var wad_type = (header[0x04] << 8) | header[0x05]
		if not (wad_type in _WAD_TYPES):
			return ""
		var cert_size = _read_be32(header, 0x08)
		var ticket_size = _read_be32(header, 0x10)
		var tmd_size = _read_be32(header, 0x14)
		var ticket_off = _wad_align64(header_len) + _wad_align64(cert_size)
		if ticket_size > 0:
			var title_id = _wad_title_id_at(file, ticket_off, _WAD_TICKET_TITLE_ID_OFFSET)
			if title_id != "":
				if DEBUG_LOG: print("[TitleIDParser] Wii WAD title id from ticket: " + title_id)
				return title_id
		if tmd_size > 0:
			var tmd_off = _wad_align64(ticket_off + ticket_size)
			for id_offset in _WAD_TMD_TITLE_ID_OFFSETS:
				var title_id = _wad_title_id_at(file, tmd_off, id_offset)
				if title_id != "":
					if DEBUG_LOG: print("[TitleIDParser] Wii WAD title id from TMD: " + title_id)
					return title_id
		push_error("[TitleIDParser] Failed to extract title id from Wii WAD: " + wad_path)
		return ""
	)

# ==================== Vita (Vita3K) ====================

## Extracts a Vita TitleID (e.g. "PCSE00965") from a game ZIP.
## Waterfall: sce_sys/param.sfo TITLE_ID (ground truth, works for flat PSN
## dumps and folder layouts), then any path segment shaped like a Vita
## TitleID (shallowest wins). Archive entries may use backslash separators;
## matching normalizes them while read_file keeps the stored name. Returns
## "" when nothing valid is found rather than an unvalidated string.
static func extract_vita_title_id(zip_path: String) -> String:
	# Resolve ZIP path with fallbacks for Godot virtual paths and Windows backslashes
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] Cannot extract TitleID - file not found: " + zip_path)
		return ""
	zip_path = resolved_path

	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		push_error("[TitleIDParser] Failed to open ZIP for TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""

	var files = reader.get_files()
	if files.is_empty():
		reader.close()
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		return ""

	# Tier 1: param.sfo ground truth (prefer the shallowest occurrence).
	var sfo_entry := ""
	var sfo_depth := 999
	for entry in files:
		var norm: String = entry.replace("\\", "/")
		if norm.to_lower().ends_with("sce_sys/param.sfo"):
			var depth := norm.get_slice_count("/")
			if depth < sfo_depth:
				sfo_depth = depth
				sfo_entry = entry
	if sfo_entry != "":
		var sfo_bytes := reader.read_file(sfo_entry)
		if not sfo_bytes.is_empty():
			var title_id := get_title_id_from_sfo_bytes(sfo_bytes)
			if _is_vita_title_id(title_id):
				reader.close()
				if DEBUG_LOG: print("[TitleIDParser] Vita TitleID from param.sfo: " + title_id.to_upper())
				return title_id.to_upper()
		push_warning("[TitleIDParser] param.sfo present but no valid TITLE_ID in: " + zip_path)

	# Tier 2: folder layout — any path segment shaped like a Vita TitleID,
	# shallowest across all entries wins.
	var best := ""
	var best_depth := 999
	for entry in files:
		var parts := entry.replace("\\", "/").split("/", false)
		for i in range(parts.size()):
			if _is_vita_title_id(parts[i]):
				if i < best_depth:
					best_depth = i
					best = parts[i].to_upper()
				break
	reader.close()
	if best != "":
		if DEBUG_LOG: print("[TitleIDParser] Vita TitleID from folder layout: " + best)
		return best

	push_error("[TitleIDParser] No Vita TitleID (param.sfo or folder layout) found in: " + zip_path)
	return ""

## Vita TitleIDs are 4 letters + 5 digits (PCSE/PCSA/PCSB/PCSF/...).
static func _is_vita_title_id(value: String) -> bool:
	if value.length() != 9:
		return false
	for i in range(4):
		var c := value.unicode_at(i)
		if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
			return false
	for i in range(4, 9):
		var c := value.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true

# ==================== Xbox 360 (Xenia) ====================

const _XEX_SECTOR_SIZE = 2048
const _GDFX_MAGIC = "MICROSOFT*XBOX*MEDIA"
const _XEX_HEADER_EXECUTION_INFO = 0x00040006

## Extracts Xbox 360 Title ID from an ISO, ZAR, XBLA archive, or extracted folder
## ISO: Parses the GDFX filesystem to find default.xex, then extracts Title ID from XEX header
## ZAR: Looks up default.xex directly in the archive file tree
## ZIP/RAR (XBLA): Matches the <TitleID>/<ContentType>/ folder layout in the archive listing
## Folder: Same layout match on disk, falling back to STFS header parsing
## Returns 8-character hex string (e.g., "545407DF")
static func extract_xbox360_title_id(iso_path: String) -> String:
	# XBLA games are loose folders of extensionless STFS containers
	if FSM.is_dir(iso_path):
		return _extract_xbox360_title_id_folder(iso_path)
	var ext = iso_path.get_extension().to_lower()
	if ext == "zip":
		return _extract_xbox360_title_id_archive(iso_path)
	if ext == "zar":
		return _extract_xbox360_title_id_zar(iso_path)
	return _with_open_file(iso_path, func(file: FileAccess) -> String:
		if DEBUG_LOG: print("[TitleIDParser] Parsing Xbox 360 ISO: " + iso_path)
		
		# Step 1: Find GDFX partition
		var game_offset = _find_gdfx_partition(file)
		if game_offset < 0:
			push_error("[TitleIDParser] Failed to find GDFX partition in Xbox 360 ISO: " + iso_path)
			return ""
		
		if DEBUG_LOG: print("[TitleIDParser] GDFX partition found at offset: 0x" + "%x" % game_offset)
		
		# Step 2: Read root directory info from sector 32
		file.seek(game_offset + (32 * _XEX_SECTOR_SIZE) + 20)
		var root_sector_bytes = file.get_buffer(4)
		var root_size_bytes = file.get_buffer(4)
		
		if root_sector_bytes.size() < 4 or root_size_bytes.size() < 4:
			push_error("[TitleIDParser] Failed to read GDFX root directory info")
			return ""
		
		var root_sector = _read_le32(root_sector_bytes, 0)
		var root_size = _read_le32(root_size_bytes, 0)
		var root_offset = game_offset + (root_sector * _XEX_SECTOR_SIZE)
		
		if DEBUG_LOG: print("[TitleIDParser] GDFX root directory: sector=" + str(root_sector) + ", size=" + str(root_size) + ", offset=0x" + "%x" % root_offset)
		
		# Validate root directory is within file bounds
		if root_offset > file.get_length():
			push_error("[TitleIDParser] GDFX root directory offset exceeds file size")
			return ""
		
		# Step 3: Parse directory tree to find default.xex
		if DEBUG_LOG: print("[TitleIDParser] Searching for default.xex in GDFX directory tree...")
		var xex_entry = _find_file_in_gdfx(file, game_offset, root_offset, "default.xex")
		
		# Step 4: If default.xex not found, try GameInfo.bin (XNA/Indie games)
		if xex_entry.is_empty():
			if DEBUG_LOG: print("[TitleIDParser] default.xex not found, trying GameInfo.bin...")
			var gameinfo_entry = _find_file_in_gdfx(file, game_offset, root_offset, "GameInfo.bin")
			if not gameinfo_entry.is_empty():
				var parsed_title_id = _parse_gameinfo_title_id(file, gameinfo_entry)
				if parsed_title_id != "":
					if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found from GameInfo.bin: " + parsed_title_id.to_upper())
					return parsed_title_id.to_upper()
			
			push_error("[TitleIDParser] Failed to find default.xex or GameInfo.bin in Xbox 360 ISO")
			return ""
		
		if DEBUG_LOG: print("[TitleIDParser] Found default.xex at offset 0x" + "%x" % xex_entry["offset"] + ", length=" + str(xex_entry["length"]))
		
		# Step 5: Read XEX header and extract Title ID
		var title_id = _read_xex_title_id(file, xex_entry["offset"], xex_entry["length"])
		
		if title_id != "":
			if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found: " + title_id.to_upper())
			return title_id.to_upper()
		
		push_error("[TitleIDParser] Failed to extract Title ID from XEX in Xbox 360 ISO")
		return ""
	)

## Extracts Xbox 360 Title ID from a .zar archive (ZArchive-compressed ISO contents)
## The archive contains the extracted filesystem, so default.xex is looked up
## directly in the archive's file tree instead of parsing GDFX
static func _extract_xbox360_title_id_zar(zar_path: String) -> String:
	if DEBUG_LOG: print("[TitleIDParser] Parsing Xbox 360 ZAR: " + zar_path)

	var reader = _ZarReader.open(zar_path)
	if reader == null:
		push_error("[TitleIDParser] Failed to open Xbox 360 ZAR: " + zar_path)
		return ""

	# ZAR archives store the extracted ISO contents, so default.xex sits at
	# the root of the archive rather than inside a GDFX partition
	var xex_entry = reader.find_file("default.xex")

	# If default.xex not found, try GameInfo.bin (XNA/Indie games)
	if xex_entry.is_empty():
		if DEBUG_LOG: print("[TitleIDParser] default.xex not found in ZAR, trying GameInfo.bin...")
		var gameinfo_entry = reader.find_file("GameInfo.bin")
		if not gameinfo_entry.is_empty():
			# Node-relative entry: offset 0 = start of GameInfo.bin
			var node_entry = {"offset": 0, "length": gameinfo_entry["size"]}
			var parsed_title_id = _parse_gameinfo_title_id(reader.create_node_io(gameinfo_entry), node_entry)
			reader.close()
			if parsed_title_id != "":
				if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found from GameInfo.bin: " + parsed_title_id.to_upper())
				return parsed_title_id.to_upper()

		push_error("[TitleIDParser] Failed to find default.xex or GameInfo.bin in Xbox 360 ZAR")
		reader.close()
		return ""

	if DEBUG_LOG: print("[TitleIDParser] Found default.xex in ZAR, length=" + str(xex_entry["size"]))

	# Reuse the XEX header parser against a node-relative IO view (offset 0 = file start)
	var xex_io = reader.create_node_io(xex_entry)
	var title_id = _read_xex_title_id(xex_io, 0, xex_entry["size"])
	reader.close()

	if title_id != "":
		if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found: " + title_id.to_upper())
		return title_id.to_upper()

	push_error("[TitleIDParser] Failed to extract Title ID from XEX in Xbox 360 ZAR")
	return ""

# ==================== Xbox 360 XBLA (STFS loose files) ====================

const _STFS_TITLE_ID_OFFSET = 0x360
const _STFS_MAGICS = ["CON ", "PIRS", "LIVE"]

## Returns true if the string is exactly 8 hexadecimal characters
static func _is_hex8(value: String) -> bool:
	if value.length() != 8:
		return false
	for i in range(8):
		var c = value[i]
		if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')):
			return false
	return true

## Matches the Xbox 360 content layout in a path's components:
## <TitleID>/<ContentType>/<file> where TitleID and ContentType are 8-hex dirs
## Returns the Title ID (uppercase) or empty string
static func _xbox360_title_id_from_path(path: String) -> String:
	var parts = path.replace("\\", "/").split("/", false)
	# The TitleID dir always sits outside the ContentType dir, so the first
	# (outermost) hex8/hex8 pair wins
	for i in range(parts.size() - 1):
		if _is_hex8(parts[i]) and _is_hex8(parts[i + 1]):
			return parts[i].to_upper()
	return ""

## Reads the Title ID from an STFS package (CON/PIRS/LIVE container)
## Title ID is a big-endian uint32 at offset 0x360
static func _xbox360_title_id_from_stfs_file(file_path: String) -> String:
	return _with_open_file(file_path, func(file: FileAccess) -> String:
		if file.get_length() < _STFS_TITLE_ID_OFFSET + 4:
			return ""
		var magic = file.get_buffer(4).get_string_from_ascii()
		if not magic in _STFS_MAGICS:
			return ""
		file.seek(_STFS_TITLE_ID_OFFSET)
		var title_id_bytes = file.get_buffer(4)
		if title_id_bytes.size() < 4:
			return ""
		var title_id = ""
		for b in title_id_bytes:
			title_id += "%02x" % b
		if title_id.length() == 8:
			return title_id.to_upper()
		return ""
	)

## Recursively collects all files under a directory
static func _collect_files_recursive(dir_path: String, results: Array[String], max_depth: int = 8) -> void:
	if max_depth <= 0:
		return
	var dir = DirAccess.open(dir_path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full_path = dir_path.path_join(entry)
			if dir.current_is_dir():
				_collect_files_recursive(full_path, results, max_depth - 1)
			else:
				results.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()

## Extracts Xbox 360 Title ID from an already-extracted XBLA game folder
## Primary: <TitleID>/<ContentType>/ folder layout; Fallback: STFS header parse
static func _extract_xbox360_title_id_folder(folder_path: String) -> String:
	if DEBUG_LOG: print("[TitleIDParser] Parsing Xbox 360 folder: " + folder_path)

	var files: Array[String] = []
	_collect_files_recursive(folder_path, files)
	if files.is_empty():
		push_error("[TitleIDParser] Xbox 360 folder is empty: " + folder_path)
		return ""

	for file_path in files:
		var title_id = _xbox360_title_id_from_path(file_path)
		if title_id != "":
			if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found from folder layout: " + title_id)
			return title_id

	if DEBUG_LOG: print("[TitleIDParser] No TitleID/ContentType layout found, sniffing STFS headers...")
	for file_path in files:
		var title_id = _xbox360_title_id_from_stfs_file(file_path)
		if title_id != "":
			if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found from STFS header: " + title_id)
			return title_id

	push_error("[TitleIDParser] Failed to find Title ID in Xbox 360 folder: " + folder_path)
	return ""

## Extracts Xbox 360 Title ID from an XBLA archive (.zip of loose files)
## Matches the <TitleID>/<ContentType>/ layout in the archive's file listing;
## archive contents are never read, so this is fast even for large packages
static func _extract_xbox360_title_id_archive(archive_path: String) -> String:
	if DEBUG_LOG: print("[TitleIDParser] Parsing Xbox 360 XBLA archive: " + archive_path)

	for entry_name in _list_zip_entries(archive_path):
		var title_id = _xbox360_title_id_from_path(entry_name)
		if title_id != "":
			if DEBUG_LOG: print("[TitleIDParser] Xbox 360 Title ID found from archive listing: " + title_id)
			return title_id

	push_error("[TitleIDParser] Failed to find Title ID in Xbox 360 archive: " + archive_path)
	return ""

## Lists all entry names in a ZIP archive via ZIPReader
static func _list_zip_entries(zip_path: String) -> Array[String]:
	var result: Array[String] = []
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		return result
	var reader = ZIPReader.new()
	if reader.open(resolved_path) != OK:
		return result
	for f in reader.get_files():
		result.append(f)
	reader.close()
	return result

## Finds the file xenia should launch inside an extracted Xbox 360 game folder
## Prefers default.xex (extracted disc/GOD games), otherwise the STFS package
## (XBLA) - preferring files under a 000D0000 content-type dir, then largest
## Returns empty string if no launchable file is found
static func find_xbox360_launch_file(folder_path: String) -> String:
	if not FSM.is_dir(folder_path):
		return ""

	var files: Array[String] = []
	_collect_files_recursive(folder_path, files)

	# default.xex always wins
	for file_path in files:
		if file_path.get_file().to_lower() == "default.xex":
			return file_path

	# Otherwise pick the best STFS package
	var best_path = ""
	var best_size = -1
	var best_preferred = false
	for file_path in files:
		var file = FSM.open_file_read(file_path)
		if not file:
			continue
		var is_stfs = false
		var size = file.get_length()
		if size >= _STFS_TITLE_ID_OFFSET + 4:
			is_stfs = file.get_buffer(4).get_string_from_ascii() in _STFS_MAGICS
		file.close()
		if not is_stfs:
			continue
		var preferred = file_path.get_base_dir().get_file().to_lower() == "000d0000"
		if (preferred and not best_preferred) or (preferred == best_preferred and size > best_size):
			best_path = file_path
			best_size = size
			best_preferred = preferred

	return best_path

## Searches for GDFX partition by looking for "MICROSOFT*XBOX*MEDIA" magic at known offsets
## Returns the game partition base offset, or -1 if not found
static func _find_gdfx_partition(file: FileAccess) -> int:
	var likely_offsets = [0x00000000, 0x0000FB20, 0x00020600, 0x02080000, 0x0FD90000]
	var file_size = file.get_length()
	
	for base_offset in likely_offsets:
		var magic_offset = base_offset + (32 * _XEX_SECTOR_SIZE)
		if magic_offset >= file_size:
			continue
		
		file.seek(magic_offset)
		var magic = file.get_buffer(20)
		if magic.size() < 20:
			continue
		
		var magic_str = magic.get_string_from_ascii()
		if magic_str == _GDFX_MAGIC:
			return base_offset
	
	return -1

## Recursively searches GDFX directory tree for a file by name
## Returns dictionary with "offset", "length", "attributes" or empty dictionary if not found
static func _find_file_in_gdfx(file: FileAccess, game_offset: int, dir_offset: int, filename: String) -> Dictionary:
	var result = {}
	var max_depth = 100  # Prevent infinite loops
	
	# Use a stack for iterative tree traversal
	# Each entry is [buffer_offset, parent_dir_offset]
	var stack = [[0, dir_offset]]
	var depth = 0
	
	while not stack.is_empty() and depth < max_depth:
		var current = stack.pop_back()
		var entry_ordinal = current[0]
		var buffer_offset = current[1]
		
		file.seek(buffer_offset + (entry_ordinal * 4))
		var entry_data = file.get_buffer(14)
		if entry_data.size() < 14:
			continue
		
		# GDFX directory entries are little-endian
		var node_l = entry_data.decode_u16(0)
		var node_r = entry_data.decode_u16(2)
		var sector = entry_data.decode_u32(4)
		var length = entry_data.decode_u32(8)
		var attributes = entry_data[12]
		var name_length = entry_data[13]
		
		# Read filename
		var name_bytes = file.get_buffer(name_length)
		if name_bytes.size() < name_length:
			continue
		var name = name_bytes.get_string_from_ascii()
		
		# Check if this is our target file
		if name.to_lower() == filename.to_lower():
			if not (attributes & 0x10):  # Not a directory
				result = {
					"offset": game_offset + (sector * _XEX_SECTOR_SIZE),
					"length": length,
					"attributes": attributes
				}
				return result
		
		# If directory and has children, add to stack
		if (attributes & 0x10) and length > 0 and name != "" and name != "." and name != "..":
			var child_offset = game_offset + (sector * _XEX_SECTOR_SIZE)
			stack.append([0, child_offset])
		
		# Add siblings to stack (right child)
		if node_r != 0:
			stack.append([node_r, buffer_offset])
		
		# Add left child to stack
		if node_l != 0:
			stack.append([node_l, buffer_offset])
		
		depth += 1
	
	return result

## Reads Title ID from XEX file
## XEX structure: magic "XEX2" at 0x0, header_count at 0x14, headers[] at 0x18
## Looks for XEX_HEADER_EXECUTION_INFO (0x00040006) and reads title_id at offset + 0x0C
## file is a FileAccess (ISO) or ZarReader.NodeIO (ZAR) with seek/get_buffer
static func _read_xex_title_id(file, xex_offset: int, xex_length: int) -> String:
	if xex_length < 0x20:
		push_error("[TitleIDParser] XEX file too small")
		return ""
	
	file.seek(xex_offset)
	var xex_header = file.get_buffer(0x18)
	if xex_header.size() < 0x18:
		push_error("[TitleIDParser] Failed to read XEX header")
		return ""
	
	var magic = xex_header.slice(0, 4).get_string_from_ascii()
	if magic != "XEX2" and magic != "XEX1":
		push_error("[TitleIDParser] Invalid XEX magic: " + magic)
		return ""
	
	var header_count = _read_be32(xex_header, 0x14)
	if header_count == 0 or header_count > 100:
		push_error("[TitleIDParser] Invalid XEX header count: " + str(header_count))
		return ""
	
	# Read optional headers
	file.seek(xex_offset + 0x18)
	for i in range(header_count):
		var opt_header = file.get_buffer(8)
		if opt_header.size() < 8:
			break
		
		var key = _read_be32(opt_header, 0)
		var value = _read_be32(opt_header, 4)
		
		# Check if this is XEX_HEADER_EXECUTION_INFO
		if key == _XEX_HEADER_EXECUTION_INFO:
			# For key 0x00040006, value is an offset from XEX header start
			var exec_info_offset = xex_offset + value
			file.seek(exec_info_offset + 0x0C)  # Title ID is at +0x0C in execution info
			var title_id_bytes = file.get_buffer(4)
			if title_id_bytes.size() < 4:
				return ""
			
			var title_id = ""
			for b in title_id_bytes:
				title_id += "%02x" % b
			
			if title_id.length() == 8:
				return title_id
	
	return ""

## Parses GameInfo.bin to extract Title ID (for XNA/Indie games)
## GameInfo.bin structure: Starts with "XGI1" magic, Title ID at offset 0x14
## file is a FileAccess (ISO) or ZarReader.NodeIO (ZAR) with seek/get_buffer
static func _parse_gameinfo_title_id(file, entry: Dictionary) -> String:
	if entry.is_empty() or entry["length"] < 0x18:
		return ""
	
	file.seek(entry["offset"])
	var header = file.get_buffer(4)
	if header.size() < 4:
		return ""
	
	var magic = header.get_string_from_ascii()
	if magic != "XGI1":
		return ""
	
	# Title ID is at offset 0x14 in GameInfo.bin
	file.seek(entry["offset"] + 0x14)
	var title_id_bytes = file.get_buffer(4)
	if title_id_bytes.size() < 4:
		return ""
	
	var title_id = ""
	for b in title_id_bytes:
		title_id += "%02x" % b
	
	if title_id.length() == 8:
		return title_id
	
	return ""

# ==================== PS4 (shadPS4) ====================

## Extracts PS4 Title ID from a ZIP or ZAR file by reading the root directory names
## PS4 game archives contain a CUSAxxxxx directory at the root level
## Returns Title ID string (e.g., "CUSA01130") or empty string on failure
static func extract_ps4_title_id(zip_path: String) -> String:
	if zip_path.get_extension().to_lower() == "zar":
		return _extract_ps4_title_id_zar(zip_path)

	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] File not found: " + zip_path)
		return ""
	zip_path = resolved_path
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	
	# If ZIPReader fails (e.g., ZIP64 large files), try 7-Zip fallback
	if err != OK:
		if DEBUG_LOG: print("[TitleIDParser] ZIPReader failed, attempting 7-Zip fallback for: " + zip_path)
		var title_id_from_7z = _extract_ps4_title_id_with_7z(zip_path)
		if title_id_from_7z != "":
			return title_id_from_7z
		push_error("[TitleIDParser] Failed to open ZIP for PS4 TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""
	
	var files = reader.get_files()
	if files.is_empty():
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		reader.close()
		return ""
	
	# Find the shallowest CUSA directory, tolerating outer archive wrappers.
	var title_id := ""
	var best_depth := 999
	for file_path in files:
		var candidate := GameExtraction.ps4_title_id_candidate(file_path)
		if not candidate.is_empty() and int(candidate.get("depth", 999)) < best_depth:
			best_depth = int(candidate["depth"])
			title_id = str(candidate["title_id"])
			if DEBUG_LOG: print("[TitleIDParser] Found PS4 TitleID in ZIP: " + title_id + " (from path: " + file_path + ")")
	
	reader.close()
	
	if title_id == "":
		push_error("[TitleIDParser] No CUSA TitleID found in PS4 ZIP: " + zip_path)
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] PS4 TitleID extracted from ZIP: " + title_id)
	return title_id


## Extracts PS4 Title ID from a .zar archive (ZArchive-compressed game contents)
## Looks for a CUSAxxxxx directory at the archive root; if absent (loose game
## contents), falls back to parsing the Title ID out of sce_sys/param.sfo
static func _extract_ps4_title_id_zar(zar_path: String) -> String:
	if DEBUG_LOG: print("[TitleIDParser] Parsing PS4 ZAR: " + zar_path)

	var reader = _ZarReader.open(zar_path)
	if reader == null:
		push_error("[TitleIDParser] Failed to open PS4 ZAR: " + zar_path)
		return ""

	# Primary: find the root-level CUSAxxxxx directory (same layout as the ZIPs)
	for entry in reader.list_dir_entries():
		var potential_id: String = entry["name"]
		if entry["is_dir"] and potential_id.begins_with("CUSA") and potential_id.length() == 9:
			reader.close()
			if DEBUG_LOG: print("[TitleIDParser] PS4 TitleID extracted from ZAR root dir: " + potential_id)
			return potential_id

	# Fallback: loose game contents — read Title ID from param.sfo
	if DEBUG_LOG: print("[TitleIDParser] No CUSA root dir in PS4 ZAR, trying param.sfo...")
	var sfo_entry = reader.find_file("param.sfo")
	if not sfo_entry.is_empty():
		var sfo_io = reader.create_node_io(sfo_entry)
		sfo_io.seek(0)
		var sfo_bytes = sfo_io.get_buffer(sfo_entry["size"])
		reader.close()
		if not sfo_bytes.is_empty():
			var title_id = get_title_id_from_sfo_bytes(sfo_bytes)
			if title_id != "":
				if DEBUG_LOG: print("[TitleIDParser] PS4 TitleID extracted from ZAR param.sfo: " + title_id)
				return title_id
		push_error("[TitleIDParser] Failed to extract TitleID from param.sfo in PS4 ZAR: " + zar_path)
		return ""

	reader.close()
	push_error("[TitleIDParser] No CUSA dir or param.sfo found in PS4 ZAR: " + zar_path)
	return ""


## 7-Zip fallback for extracting PS4 TitleID from large/ZIP64 archives
static func _extract_ps4_title_id_with_7z(zip_path: String) -> String:
	var binary_path = FSM._get_7z_binary_path()
	if binary_path == "":
		if DEBUG_LOG: print("[TitleIDParser] 7-Zip binary not available")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] Using 7-Zip fallback for PS4 TitleID: " + binary_path)
	
	# List archive contents
	var list_args = ["l", "-slt", zip_path]
	var output = []
	var exit_code = OS.execute(binary_path, list_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip list failed with exit code: " + str(exit_code))
		return ""
	
	var output_str = ""
	if output.size() > 0:
		output_str = output[0]
	
	# Parse output to find the shallowest CUSA directory, including wrappers.
	var title_id = ""
	var best_depth := 999
	var lines = output_str.split("\n")
	for line in lines:
		if line.begins_with("Path = "):
			var path = line.substr(7).strip_edges()
			var candidate := GameExtraction.ps4_title_id_candidate(path)
			if not candidate.is_empty() and int(candidate.get("depth", 999)) < best_depth:
				best_depth = int(candidate["depth"])
				title_id = str(candidate["title_id"])
				if DEBUG_LOG: print("[TitleIDParser] Found PS4 TitleID in 7-Zip output: " + title_id + " (from path: " + path + ")")
	
	if title_id == "":
		push_error("[TitleIDParser] No CUSA TitleID found via 7-Zip listing")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] PS4 TitleID extracted via 7-Zip fallback: " + title_id)
	return title_id


# ==================== PS3 (RPCS3) ====================

## Extracts PS3 Title ID from a ZIP file by reading PARAM.SFO directly from the archive
## Supports both disc format (PS3_GAME/PARAM.SFO) and digital format (TITLEID/PARAM.SFO)
## Returns Title ID string (e.g., "BLUS12345") or empty string on failure
static func extract_ps3_title_id(zip_path: String) -> String:
	# Resolve ZIP path with fallbacks for Godot virtual paths and Windows backslashes
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] File not found: " + zip_path)
		return ""
	zip_path = resolved_path
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	
	# If ZIPReader fails (e.g., ZIP64 large files), try 7-Zip fallback
	if err != OK:
		if DEBUG_LOG: print("[TitleIDParser] ZIPReader failed, attempting 7-Zip fallback for: " + zip_path)
		var title_id_from_7z = _extract_ps3_title_id_with_7z(zip_path)
		if title_id_from_7z != "":
			return title_id_from_7z
		push_error("[TitleIDParser] Failed to open ZIP for PS3 TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""
	
	var files = reader.get_files()
	if files.is_empty():
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		reader.close()
		return ""
	
	# Prefer the authoritative disc marker before considering digital/loose SFOs.
	var sfo_path := ""
	for file_path in files:
		if GameExtraction.is_ps3_disc_sfo_path(file_path):
			sfo_path = file_path
			break
	if sfo_path == "":
		for file_path in files:
			if file_path.ends_with("PARAM.SFO") or file_path.ends_with("PARAM.sfo"):
				sfo_path = file_path
				break
	
	if sfo_path == "":
		push_error("[TitleIDParser] PARAM.SFO not found in PS3 ZIP: " + zip_path)
		reader.close()
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] Found PARAM.SFO in ZIP at: " + sfo_path)
	
	# Read PARAM.SFO bytes from ZIP
	var sfo_bytes = reader.read_file(sfo_path)
	reader.close()
	
	if sfo_bytes.is_empty():
		push_error("[TitleIDParser] Failed to read PARAM.SFO from ZIP: " + zip_path)
		return ""
	
	# Parse TitleID from SFO bytes
	var title_id = get_title_id_from_sfo_bytes(sfo_bytes)
	
	if title_id == "":
		push_error("[TitleIDParser] Failed to extract TitleID from PARAM.SFO in: " + zip_path)
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] PS3 TitleID extracted from ZIP: " + title_id)
	return title_id


## 7-Zip fallback for extracting PS3 TitleID from large/ZIP64 archives
## Uses bundled 7z binary to extract PARAM.SFO, then parses it
static func _extract_ps3_title_id_with_7z(zip_path: String) -> String:
	var binary_path = FSM._get_7z_binary_path()
	if binary_path == "":
		if DEBUG_LOG: print("[TitleIDParser] 7-Zip binary not available")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] Using 7-Zip fallback: " + binary_path)
	
	# Step 1: List archive contents to find PARAM.SFO path
	var list_args = ["l", "-slt", zip_path]
	var output = []
	var exit_code = OS.execute(binary_path, list_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip list failed with exit code: " + str(exit_code))
		return ""
	
	var output_str = ""
	if output.size() > 0:
		output_str = output[0]
	
	# Parse output, preferring the same authoritative disc marker used on disk.
	var sfo_path = ""
	var lines = output_str.split("\n")
	for line in lines:
		if line.begins_with("Path = "):
			var candidate: String = line.substr(7).strip_edges()
			if GameExtraction.is_ps3_disc_sfo_path(candidate):
				sfo_path = candidate
				break
	if sfo_path == "":
		for line in lines:
			if line.find("PARAM.SFO") != -1 and not line.ends_with("/") and not line.ends_with("\\"):
				if line.begins_with("Path = "):
					sfo_path = line.substr(7).strip_edges()
					break
	
	if sfo_path == "":
		push_error("[TitleIDParser] PARAM.SFO not found via 7-Zip listing")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] Found PARAM.SFO via 7-Zip at: " + sfo_path)
	
	# Step 2: Extract PARAM.SFO to temp directory
	var temp_dir = "user://temp/ps3_sfo/"
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	var extract_args = ["e", zip_path, sfo_path, 		"-o" + FSM.resolve_path(temp_dir, {"format": FSM.PathFormat.ABSOLUTE}), "-y"]
	exit_code = OS.execute(binary_path, extract_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip extract failed with exit code: " + str(exit_code))
		return ""
	
	# Step 3: Read extracted PARAM.SFO
	var extracted_sfo = temp_dir + "PARAM.SFO"
	if not FileAccess.file_exists(extracted_sfo):
		push_error("[TitleIDParser] Extracted PARAM.SFO not found at: " + extracted_sfo)
		return ""
	
	var sfo_file = FileAccess.open(extracted_sfo, FileAccess.READ)
	if not sfo_file:
		push_error("[TitleIDParser] Failed to open extracted PARAM.SFO")
		return ""
	
	var sfo_bytes = sfo_file.get_buffer(sfo_file.get_length())
	sfo_file.close()
	
	# Clean up temp file
	DirAccess.remove_absolute(extracted_sfo)
	
	if sfo_bytes.is_empty():
		push_error("[TitleIDParser] Failed to read extracted PARAM.SFO")
		return ""
	
	# Step 4: Parse TitleID
	var title_id = get_title_id_from_sfo_bytes(sfo_bytes)
	
	if title_id == "":
		push_error("[TitleIDParser] Failed to extract TitleID from 7-Zip extracted PARAM.SFO")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] PS3 TitleID extracted via 7-Zip fallback: " + title_id)
	return title_id


# ============================================================================
# PARAM.SFO PARSER (merged from param_sfo_parser.gd)
# ============================================================================

## Parses PARAM.SFO data from a byte array
## Returns empty dictionary if data cannot be parsed
static func _read_sfo_from_bytes(data: PackedByteArray) -> Dictionary:
	# Check minimum file size (header is 20 bytes)
	if data.size() < 20:
		push_error("[TitleIDParser] SFO data too small: " + str(data.size()) + " bytes")
		return {}
	
	# Parse header
	var pos := 0
	var magic := data.decode_u32(pos)
	pos += 4
	
	# Magic should be "PSF\0" = 0x46535000 (little-endian)
	if magic != 0x46535000:
		push_error("[TitleIDParser] Invalid SFO magic: 0x" + String.num_uint64(magic, 16) + " (expected 0x46535000 for PSF)")
		return {}
	
	var version := data.decode_u32(pos)
	pos += 4
	
	var key_table_offset := data.decode_u32(pos)
	pos += 4
	
	var data_table_offset := data.decode_u32(pos)
	pos += 4
	
	var num_entries := data.decode_u32(pos)
	pos += 4
	
	if DEBUG_LOG: print("[TitleIDParser] SFO Header: version=" + str(version) + ", entries=" + str(num_entries))
	if DEBUG_LOG: print("[TitleIDParser] SFO Key table at offset " + str(key_table_offset) + ", data table at offset " + str(data_table_offset))
	
	# Read index table entries
	var entries := []
	for i in range(num_entries):
		if pos + 16 > data.size():
			push_error("[TitleIDParser] Unexpected end of file reading SFO entry " + str(i))
			break
		
		var entry := {}
		entry["key_offset"] = data.decode_u16(pos)
		pos += 2
		entry["data_fmt"] = data.decode_u16(pos)
		pos += 2
		entry["data_len"] = data.decode_u32(pos)
		pos += 4
		entry["data_max_len"] = data.decode_u32(pos)
		pos += 4
		entry["data_offset"] = data.decode_u32(pos)
		pos += 4
		
		entries.append(entry)
	
	# Read key table (null-terminated strings)
	var keys := {}
	var key_pos := key_table_offset
	var key_index := 0
	
	while key_pos < data_table_offset and key_index < entries.size():
		var key_name := ""
		while key_pos < data.size() and data[key_pos] != 0:
			key_name += char(data[key_pos])
			key_pos += 1
		key_pos += 1  # Skip null terminator
		
		if key_name != "":
			keys[key_index] = key_name
			key_index += 1
	
	# Read data table values
	var result: Dictionary = {}
	for i in range(entries.size()):
		if i >= keys.size():
			break
		
		var entry: Dictionary = entries[i]
		var key_name: String = keys.get(i, "unknown_" + str(i))
		var data_pos: int = data_table_offset + int(entry["data_offset"])
		
		# Read data as raw bytes regardless of format - this handles all PARAM.SFO formats
		var value: String = ""
		var max_read: int = mini(entry["data_len"], data.size() - data_pos)
		for j in range(max_read):
			var byte_val: int = data[data_pos + j]
			if byte_val == 0:
				break
			# Only include printable ASCII characters
			if byte_val >= 32 and byte_val < 127:
				value += char(byte_val)
			else:
				break
		
		result[key_name] = value
	
	return result


## Extracts the TitleID from PARAM.SFO byte data
## Returns empty string if TitleID cannot be found
static func get_title_id_from_sfo_bytes(data: PackedByteArray) -> String:
	if DEBUG_LOG: print("[TitleIDParser] get_title_id_from_sfo_bytes called")
	
	var sfo_data := _read_sfo_from_bytes(data)
	return _extract_title_id_from_sfo_data(sfo_data)


static func _extract_title_id_from_sfo_data(sfo_data: Dictionary) -> String:
	if sfo_data.is_empty():
		if DEBUG_LOG: print("[TitleIDParser] SFO data is empty")
		return ""
	
	if DEBUG_LOG: print("[TitleIDParser] SFO data keys: " + str(sfo_data.keys()))
	
	# TitleID is stored in the "TITLE_ID" field
	var title_id: String = sfo_data.get("TITLE_ID", "")
	if DEBUG_LOG: print("[TitleIDParser] TITLE_ID value: '" + title_id + "'")
	
	if title_id == "" or title_id == "<binary>":
		# Try alternative field names
		title_id = sfo_data.get("title_id", "")
		if title_id != "":
			if DEBUG_LOG: print("[TitleIDParser] Found title_id (lowercase): '" + title_id + "'")
	
	return title_id


## Extracts the full sigil result for a game based on its platform.
## Returns {title_id, save_id, raw_serial, usage, source, experimental} for
## sigil-routed platforms; legacy platforms return only title_id.
## Returns an empty Dictionary if extraction fails or not needed.
static func extract_for_game_result(game: GameResource, rom_path_override: String = "") -> Dictionary:
	var rom_path = rom_path_override if rom_path_override != "" else game.file_path
	if rom_path == "":
		return {}

	var slug = game.platform_slug

	# Sigil routing: psp, ps2, switch, 3ds, wii, ngc, wiiu, psx go through the
	# sigil CLI. ps3, ps4, vita, xbox360 keep their custom extractors below.
	if _SigilRunner.is_supported(slug):
		var prod_keys := ""
		if slug == "switch":
			var emulator_dir = LaunchManager._get_emulator_directory("eden")
			prod_keys = _get_prod_keys_path(emulator_dir)
		return _SigilRunner.extract(rom_path, slug, prod_keys)

	var legacy_id := ""
	match slug:
		"ps3":
			legacy_id = extract_ps3_title_id(rom_path)
		"ps4":
			legacy_id = extract_ps4_title_id(rom_path)
		"vita":
			legacy_id = extract_vita_title_id(rom_path)
		"xbox360":
			legacy_id = extract_xbox360_title_id(rom_path)

	if legacy_id == "":
		return {}
	return {"title_id": legacy_id, "save_id": "", "raw_serial": "", "usage": "", "source": "", "experimental": false}
