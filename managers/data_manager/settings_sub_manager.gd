@icon("res://Icons/BoxMesh.svg")
#settings_sub_manager.gd
extends Manager
class_name SettingsSubManager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved
signal apply_preset_begin
signal apply_preset_end

const SAVE_PATH := "user://user_prefs.tres"
const PRESETS_FOLDER := "user://themes/"
const BUILTIN_PRESETS_FOLDER := "res://themes/"
var settings: Settings
var _is_dirty: bool = false

func _init() -> void:
	load_settings()

## === Accessors ===
func get_settings() -> Dictionary:
	var dictionary: Dictionary[String, SettingsVar] = {}
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return dictionary
	for property in settings.get_property_list():
		if settings.get(property.name) is SettingsVar: #Check each property for SettingsVars
			dictionary[property.name] = settings.get(property.name) #Property name is key, SettingsVAR is value. 
	return dictionary

func get_settings_by_subgroup() -> Dictionary:
	var dictionary: Dictionary[String, Array] = {}
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return dictionary
	var subgroup :String = ""
	var settingsvars :Array[SettingsVar] = []
	for property in settings.get_property_list():	#					For every property in the list, 
		if property.usage == 256:  # 								If it's a @export subgroup..
			if not subgroup == "": # 								And we already have a previous subgroup
				# Only add subgroup if it has non-INTERNAL settings
				if settingsvars.size() > 0:
					dictionary[subgroup] = settingsvars.duplicate()
			subgroup = property.name
			settingsvars.clear()										# And then clear the array for re-use.
		if settings.get(property.name) is SettingsVar and not subgroup == "": 			#	If we've caught a SettingsVar and we already have a previous subgroup
			var settingsvar : SettingsVar = settings.get(property.name)
			# Skip INTERNAL settings - they shouldn't appear in the auto-generated menu
			if settingsvar.state != SettingsVar.SettingState.INTERNAL:
				settingsvars.append(settingsvar)
	# Only add last subgroup if it has non-INTERNAL settings
	if settingsvars.size() > 0:
		dictionary[subgroup] = settingsvars.duplicate()
	return dictionary

func enable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.ENABLED

func disable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.DISABLED

func set_setting(value: Variant, setting: SettingsVar, force: bool = false):
	if not settings:
		push_error("No settings loaded, cannot change setting '%s'" % setting.property_name)
		return
	# Coerce to the declared type: SettingsVar.value is an untyped Variant and
	# UI controls (e.g. sliders) emit floats even for INT settings.
	match setting.type:
		SettingsVar.SettingType.INT:
			if value is float or value is int:
				value = int(round(value))
		SettingsVar.SettingType.FLOAT:
			if value is float or value is int:
				value = float(value)
	# SettingsVar.value is an untyped Variant and UI controls may emit a
	# different representation than what's stored (the resolution OptionButton
	# emits an int index while its default is a Vector2i); mismatched Variant
	# types raise on !=, so differing types are always a change.
	var changed = force
	if not changed:
		changed = typeof(setting.value) != typeof(value) or setting.value != value
	setting.value = value
	if changed:
		_is_dirty = true
		emit_signal("setting_changed", value, setting)

## Builds a ThemePreset from the live settings using the public get_setting() API.
func create_preset_from_current() -> ThemePreset:
	return create_preset_from_settings(settings)

## Builds a ThemePreset from the given Settings object.
## Captures every SettingsVar flagged include_in_preset in settings.gd.
func create_preset_from_settings(source_settings: Settings) -> ThemePreset:
	return ThemePreset.build_from_settings(source_settings)

## Every setting flagged for theme presets — the single iteration used by
## save, apply, and preset-match so the three can never drift apart.
func get_presettable_settings() -> Array[SettingsVar]:
	var out: Array[SettingsVar] = []
	if not settings:
		return out
	for prop in settings.get_property_list():
		var s = settings.get(prop.name)
		if s is SettingsVar and s.include_in_preset:
			out.append(s)
	return out

var _defaults_cache: Settings = null

func get_setting_default(_name: String) -> Variant:
	if _defaults_cache == null:
		_defaults_cache = Settings.new()
	var s = _defaults_cache.get(_name)
	if s is SettingsVar:
		return s.value
	return null

func get_setting(_name:String) -> SettingsVar:
	var settingsvar: SettingsVar = null
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return settingsvar
	settingsvar = settings.get(_name)
	return settingsvar

func load_settings() -> void:
	if FSM.file_exists(SAVE_PATH):
		# Renamed keys must be pulled from the raw file before loading: the
		# .tres loader silently drops serialized properties that no longer
		# exist on the Settings class.
		var legacy_steam_games: Variant = _read_legacy_setting("gamenative_games")
		settings = ResourceLoader.load(SAVE_PATH) as Settings
		if settings == null:
			# Corrupt or wrong-type file: preserve a copy for inspection, start fresh
			push_error("[SettingsManager] Failed to load settings from %s - resetting to defaults (backup saved)" % SAVE_PATH)
			if FSM.copy_file(SAVE_PATH, SAVE_PATH + ".corrupt.bak"):
				FSM.delete_file(SAVE_PATH)
		elif legacy_steam_games != null:
			_migrate_legacy_setting("steam_games", legacy_steam_games)
	if settings:
		_refresh_setting_metadata(settings)
		store_property_names(settings)
		_decrypt_settings()
		return
	# fallback if load failed
	settings = Settings.new()
	store_property_names(settings)

## Reads a top-level property from the raw settings .tres text (single-line
## Variant). Used for one-time key migrations; returns null when absent.
func _read_legacy_setting(key: String) -> Variant:
	var raw := FSM.read_file(SAVE_PATH)
	if raw.is_empty():
		return null
	for line in raw.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with(key + " = "):
			return str_to_var(stripped.substr((key + " = ").length()))
	return null

## One-time migration for a renamed settings key: carry the legacy value over
## only when the new key still holds its (empty) default.
func _migrate_legacy_setting(new_key: String, legacy_value: Variant) -> void:
	if not (legacy_value is Array) or legacy_value.is_empty():
		return
	var new_setting := get_setting(new_key)
	if new_setting and new_setting.value is Array and new_setting.value.is_empty():
		new_setting.value = legacy_value
		_is_dirty = true

## Syncs metadata (options, ranges, names, etc.) from fresh defaults onto loaded settings.
## Preserves the user's saved values.
func _refresh_setting_metadata(_settings: Settings) -> void:
	var defaults = Settings.new()
	for prop in defaults.get_property_list():
		var default_var = defaults.get(prop.name)
		if not (default_var is SettingsVar):
			continue
		var saved_var = _settings.get(prop.name)
		if not (saved_var is SettingsVar):
			continue
		
		# Preserve user's value and property_name, refresh everything else from code
		var old_value = saved_var.value
		var old_property_name = saved_var.property_name
		
		saved_var.type = default_var.type
		saved_var.state = default_var.state
		saved_var.display_name = default_var.display_name
		saved_var.description = default_var.description
		saved_var.min_value = default_var.min_value
		saved_var.max_value = default_var.max_value
		saved_var.step = default_var.step
		saved_var.options = default_var.options.duplicate()
		saved_var.encrypted = default_var.encrypted
		saved_var.include_in_preset = default_var.include_in_preset
		# Visibility rules are code-owned, unlike user-facing values. Remove stale
		# rules and refresh current ones; otherwise a removed controlling setting
		# can leave its dependent row permanently hidden after an upgrade.
		if default_var.metadata.has("visible_if"):
			saved_var.metadata["visible_if"] = default_var.metadata["visible_if"].duplicate(true)
		else:
			saved_var.metadata.erase("visible_if")
		# Pick up metadata keys added since the settings were saved (saved
		# keys win, so stale serialized metadata can't clobber user state).
		for key in default_var.metadata:
			if not saved_var.metadata.has(key):
				saved_var.metadata[key] = default_var.metadata[key]

		# Clamp value to new valid range/options if needed
		if default_var.type == SettingsVar.SettingType.ARRAY:
			if old_value is Array:
				# ARRAY type can store actual arrays (e.g., steam_games)
				# not just int indices for dropdown options
				saved_var.value = old_value
			elif old_value is int and old_value >= 0 and old_value < default_var.options.size():
				saved_var.value = old_value
			else:
				saved_var.value = default_var.value
		elif default_var.type == SettingsVar.SettingType.INT or default_var.type == SettingsVar.SettingType.FLOAT:
			# 0 is the stored sentinel for a slider's "Unlimited" tick; keep it.
			if default_var.metadata.get("unlimited_tick", false) and (old_value is int or old_value is float) and old_value == 0:
				if default_var.type == SettingsVar.SettingType.INT:
					saved_var.value = 0
				else:
					saved_var.value = 0.0
			else:
				saved_var.value = clamp(old_value, default_var.min_value, default_var.max_value)
		elif default_var.type == SettingsVar.SettingType.VECTOR2I:
			# Clamp each axis independently using the per-axis min/max from metadata.
			var min_limit := int(default_var.min_value)
			var max_limit := int(default_var.max_value)
			if max_limit <= 0:
				max_limit = 16384
			saved_var.value = Vector2i(
				clampi(int(old_value.x), min_limit, max_limit),
				clampi(int(old_value.y), min_limit, max_limit)
			)
		else:
			saved_var.value = old_value
		
		saved_var.property_name = old_property_name

# Here we're storing an internal reference to the properties the settingsvars are assigned to. 
func store_property_names(_settings : Settings):
	for prop in _settings.get_property_list():
		var setting = _settings.get(prop.name)
		if setting is SettingsVar:
			setting.property_name = prop.name

func save_settings() -> void:
	if not settings or not _is_dirty:
		return
	# Encrypt a disposable copy so runtime values are never mutated.
	var settings_to_save = settings.duplicate(true)
	_encrypt_settings(settings_to_save)
	var err = ResourceSaver.save(settings_to_save, SAVE_PATH)

	if err != OK:
		push_error("Failed to save preferences: %s" % err)
	else:
		_is_dirty = false
		emit_signal("settings_saved")

const PASSWORD_KEY = "kyodai_v1"

func _encrypt_settings(target: Settings) -> void:
	for prop in target.get_property_list():
		var setting = target.get(prop.name)
		if setting is SettingsVar and setting.encrypted and setting.value:
			if setting.value is String and not setting.value.is_empty():
				setting.value = _xor_encrypt(setting.value, PASSWORD_KEY)

func _decrypt_settings() -> void:
	for prop in settings.get_property_list():
		var setting = settings.get(prop.name)
		if setting is SettingsVar and setting.encrypted and setting.value:
			if setting.value is String and not setting.value.is_empty():
				# Check if value looks encrypted (base64)
				if _is_base64(setting.value):
					setting.value = _xor_decrypt(setting.value, PASSWORD_KEY)

func _is_base64(text: String) -> bool:
	# Simple check: base64 strings are typically divisible by 4 and contain specific chars
	if text.length() % 4 != 0:
		return false
	var base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
	for c in text:
		if not c in base64_chars:
			return false
	return text.length() > 0

func reset_settings() -> void:
	settings = Settings.new()
	_is_dirty = true
	save_settings()

## XORs the UTF-8 BYTES, never String characters. The old char-wise version
## emitted embedded NUL codepoints whenever a plaintext char matched the key
## char at its aligned position, and the String<->UTF-8 roundtrip then mangled
## everything after the first NUL. That corrupted paired rmm_ tokens: 68
## random hex chars almost always contain an aligned match (~98% chance).
## Byte-wise XOR never roundtrips through String mid-cycle, so NULs and
## non-ASCII survive; legacy char-wise values decrypt identically for ASCII.
func _xor_encrypt(text: String, key: String) -> String:
	var plain := text.to_utf8_buffer()
	var key_bytes := key.to_utf8_buffer()
	var result := PackedByteArray()
	result.resize(plain.size())
	for i in range(plain.size()):
		result[i] = plain[i] ^ key_bytes[i % key_bytes.size()]
	return Marshalls.raw_to_base64(result)

func _xor_decrypt(encrypted: String, key: String) -> String:
	var bytes = Marshalls.base64_to_raw(encrypted)
	var key_bytes := key.to_utf8_buffer()
	for i in range(bytes.size()):
		bytes[i] = bytes[i] ^ key_bytes[i % key_bytes.size()]
	return bytes.get_string_from_utf8()

## === Theme Preset Management ===

func _ensure_presets_folder() -> void:
	FSM.make_dir_recursive(PRESETS_FOLDER)

# Fallback built-in preset filenames. On desktop the themes/ folder is scanned
# automatically; this list is used as a fallback on platforms (e.g. Android)
# where res:// directory listing may be unreliable.
const BUILTIN_PRESET_FILES: Array[String] = [
	"CafeOS.tres",
	"Default.tres",
	"Horizon3D.tres",
	"Horizon.tres",
	"LiveArea.tres",
	"NSO.tres",
	"SteamOS.tres",
	"XMB.tres",
]

func _discover_builtin_preset_files() -> Array[String]:
	"""Discover built-in preset filenames. Scan the themes/ folder first; if the
	scan yields nothing (common on Android where res:// listing is unreliable),
	fall back to the hardcoded BUILTIN_PRESET_FILES list."""
	var scanned: Array[String] = []
	for file_name in FSM.list_dir(BUILTIN_PRESETS_FOLDER):
		if FSM.is_dir(FSM.join_paths(BUILTIN_PRESETS_FOLDER, file_name)):
			continue
		if file_name.ends_with(".tres") or file_name.ends_with(".tres.remap"):
			scanned.append(file_name)

	if not scanned.is_empty():
		return scanned

	print("[SettingsManager] res://themes/ scan returned empty; using built-in preset fallback list")
	return BUILTIN_PRESET_FILES.duplicate()

func list_presets() -> Array[ThemePreset]:
	_ensure_presets_folder()
	var presets: Array[ThemePreset] = []
	var loaded_names: Array[String] = []

	# Load built-in presets first (from res://). Prefer a live directory scan so
	# adding a .tres to themes/ is automatic on desktop; fall back to the hardcoded
	# list on platforms where res:// scanning is unreliable (e.g. Android).
	var builtin_files := _discover_builtin_preset_files()
	for file_name in builtin_files:
		var preset_path := FSM.join_paths(BUILTIN_PRESETS_FOLDER, file_name)
		if preset_path.ends_with(".remap"):
			preset_path = preset_path.substr(0, preset_path.length() - 6)
		if not ResourceLoader.exists(preset_path):
			push_warning("[SettingsManager] Built-in preset file missing, skipping: " + preset_path)
			continue
		var loaded_resource = ResourceLoader.load(preset_path)
		var preset = loaded_resource as ThemePreset
		if not preset:
			push_warning("[SettingsManager] Built-in file is not a ThemePreset, skipping: " + preset_path)
			continue
		if preset.name not in loaded_names:
			presets.append(preset)
			loaded_names.append(preset.name)
	
	# Load user presets (from user://) - these override built-ins of the same name
	for file_name in FSM.list_dir(PRESETS_FOLDER):
		if FSM.is_dir(FSM.join_paths(PRESETS_FOLDER, file_name)):
			continue
		if file_name.ends_with(".tres") or file_name.ends_with(".tres.remap"):
			var user_preset_path = FSM.join_paths(PRESETS_FOLDER, file_name)
			# REPLACE mode: bypass (and refresh) any stale cached copy so
			# freshly overwritten exports show their new content.
			var user_preset = ResourceLoader.load(user_preset_path, "", ResourceLoader.CACHE_MODE_REPLACE) as ThemePreset
			if not user_preset:
				continue
			var existing := loaded_names.find(user_preset.name)
			if existing >= 0:
				presets[existing] = user_preset
			else:
				presets.append(user_preset)
				loaded_names.append(user_preset.name)
	
	# Sort by name
	presets.sort_custom(func(a, b): return a.name < b.name)
	return presets

func save_preset(preset: ThemePreset) -> bool:
	_ensure_presets_folder()
	if preset.name.is_empty():
		push_error("Cannot save preset without a name")
		return false
	
	# Sanitize filename
	var safe_name = preset.name.replace(" ", "_").replace("/", "_").replace("\\", "_")
	var preset_path = PRESETS_FOLDER + safe_name + ".tres"
	
	var err = ResourceSaver.save(preset, preset_path)
	if err != OK:
		push_error("Failed to save preset: %s" % err)
		return false

	# ResourceLoader caches by path; without this, reloading after an overwrite
	# returns the stale instance from a previous load of the same path.
	ResourceLoader.load(preset_path, "", ResourceLoader.CACHE_MODE_REPLACE)

	return true

func load_preset(preset_path: String) -> ThemePreset:
	if not FSM.file_exists(preset_path):
		push_error("Preset file not found: %s" % preset_path)
		return null
	
	var preset = ResourceLoader.load(preset_path) as ThemePreset
	if not preset:
		push_error("Failed to load preset from: %s" % preset_path)
		return null
	return preset

func apply_preset(preset: ThemePreset) -> bool:
	if not preset:
		push_error("[SettingsSubManager] Cannot apply null preset")
		return false

	if not settings:
		push_error("[SettingsSubManager] No settings loaded, cannot apply preset")
		return false

	emit_signal("apply_preset_begin")

	# Snapshot semantics: every presettable setting is applied; keys missing
	# from the preset fall back to declared defaults. dark_mode is applied
	# LAST — the preset's effect configs already carry colors for their saved
	# (main) mode, so the dark/light adapter swap must not run mid-apply.
	var dark_mode_var: SettingsVar = null
	for s in get_presettable_settings():
		if s.property_name == "dark_mode":
			dark_mode_var = s
			continue
		var value: Variant = preset.values.get(s.property_name, get_setting_default(s.property_name))
		set_setting(ThemePreset.deep_dup_value(value), s, true)
	if dark_mode_var:
		var dark_value: Variant = preset.values.get("dark_mode", get_setting_default("dark_mode"))
		set_setting(dark_value, dark_mode_var, true)

	emit_signal("apply_preset_end")

	save_settings()

	return true

func export_preset(preset: ThemePreset, export_path: String) -> bool:
	if not preset:
		return false
	
	var err = ResourceSaver.save(preset, export_path)
	if err != OK:
		push_error("Failed to export preset: %s" % err)
		return false
	
	return true

func import_preset(import_path: String) -> ThemePreset:
	if not FSM.file_exists(import_path):
		push_error("Import file not found: %s" % import_path)
		return null
	
	var preset = ResourceLoader.load(import_path) as ThemePreset
	if not preset:
		push_error("Failed to import preset from: %s" % import_path)
		return null
	# Save to presets folder
	if save_preset(preset):
		return preset
	
	return null

func _exit_tree() -> void:
	"""Release the loaded settings resource so its SettingsVars don't leak."""
	settings = null
