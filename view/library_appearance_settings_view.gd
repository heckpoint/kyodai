class_name LibraryAppearanceSettingsView
extends Control

## Library Appearance controls and theme-preset UI.

const FOCUS_RING_SETTING_NAMES: Array[String] = [
	"library_focus_scale",
	"library_focus_movement_anim",
	"library_focus_idle_anim",
	"library_focus_ring_thickness",
	"library_focus_ring_shape",
	"library_focus_ring_outset",
]

var _library_general_menu: SettingsMenu = null
var _focus_ring_menu: SettingsMenu = null

var _margin: MarginContainer = null
var _vbox: VBoxContainer = null
var _bottom_buffer: Control = null
var _preset_container: HBoxContainer = null

# Theme preset UI
var _preset_dropdown: M3OptionButton = null
var _current_presets: Array[ThemePreset] = []
var _is_applying_preset: bool = false
var _loaded_preset: ThemePreset = null

# Init guard: block feedback signals while building the initial UI.
var _is_initializing: bool = true

func _ready():
	_setup_ui()
	_refresh_all_settings_ui()
	_is_initializing = false

func on_view_show():
	# The dialog calls this every time the category is shown (category switch or
	# dialog reopen). Reload in case presets changed while hidden.
	if _is_initializing:
		return
	_refresh_preset_dropdown()

func _setup_ui() -> void:
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	_margin = margin

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	margin.add_child(vbox)
	_vbox = vbox

	# Theme Presets section
	_create_preset_section(vbox)

	# General layout settings (excluding internal ones)
	_library_general_menu = SettingsMenu.new()
	vbox.add_child(_library_general_menu)

	# Focus-specific controls get a visual break from the general settings.
	_focus_ring_menu = SettingsMenu.new()
	vbox.add_child(_focus_ring_menu)

	# Bottom buffer
	var bottom_buffer = Control.new()
	vbox.add_child(bottom_buffer)
	_bottom_buffer = bottom_buffer

	_apply_scale()

func _apply_scale() -> void:
	if is_instance_valid(_margin):
		_margin.add_theme_constant_override("margin_left", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_top", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_right", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(20)))
	if is_instance_valid(_vbox):
		_vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	if is_instance_valid(_bottom_buffer):
		_bottom_buffer.custom_minimum_size = Vector2(0, M3Units.dp(60))
	if is_instance_valid(_preset_container):
		_preset_container.custom_minimum_size = Vector2(0, M3Units.dp(30))

func refresh_scale() -> void:
	_apply_scale()

func _create_preset_section(vbox: VBoxContainer) -> void:
	var preset_section := SettingsSection.new("Theme Presets", "palette")
	vbox.add_child(preset_section)

	var preset_container = HBoxContainer.new()
	preset_section.add_content(preset_container, false)
	_preset_container = preset_container
	
	_preset_dropdown = M3OptionButton.new()
	_preset_dropdown.label_text = "Theme Preset"
	_preset_dropdown.fit_to_longest_item = false
	_preset_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown.item_selected.connect(_on_preset_selected)
	preset_container.add_child(_preset_dropdown)
	
	var load_button = M3Button.new()
	load_button.text = "Load"
	load_button.button_size = M3Button.Size.SMALL
	load_button.tooltip_text = "Import preset from file"
	load_button.pressed.connect(_on_load_preset_pressed)
	preset_container.add_child(load_button)
	
	var export_button = M3Button.new()
	export_button.text = "Export"
	export_button.button_size = M3Button.Size.SMALL
	export_button.tooltip_text = "Export current settings as preset"
	export_button.pressed.connect(_on_export_preset_pressed)
	preset_container.add_child(export_button)

func _refresh_all_settings_ui() -> void:
	# Refresh general settings menu
	if _library_general_menu:
		_library_general_menu.clear_controls()
		var general_settings: Array[SettingsVar] = []
		var subgroups = DataManager.get_settings_by_subgroup()
		if subgroups.has("Library Appearance"):
			for sv in subgroups["Library Appearance"]:
				if sv.state != SettingsVar.SettingState.INTERNAL and not FOCUS_RING_SETTING_NAMES.has(sv.property_name):
					general_settings.append(sv)
		if general_settings.size() > 0:
			_library_general_menu.build_controls_from_settingsvars(general_settings, "General", "tune")
			if not _library_general_menu.setting_changed.is_connected(_on_setting_changed):
				_library_general_menu.setting_changed.connect(_on_setting_changed)

	# Build the focus section explicitly so its order stays stable and future
	# focus-adjacent settings (such as focus centering) don't move accidentally.
	if _focus_ring_menu:
		_focus_ring_menu.clear_controls()
		var focus_settings: Array[SettingsVar] = []
		for property_name in FOCUS_RING_SETTING_NAMES:
			var setting = DataManager.get_setting(property_name)
			if setting and setting.state != SettingsVar.SettingState.INTERNAL:
				focus_settings.append(setting)
		if focus_settings.size() > 0:
			_focus_ring_menu.build_controls_from_settingsvars(focus_settings, "Focus Ring", "crosshairs")
			if not _focus_ring_menu.setting_changed.is_connected(_on_setting_changed):
				_focus_ring_menu.setting_changed.connect(_on_setting_changed)

	# Refresh preset dropdown
	_refresh_preset_dropdown()

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if _is_initializing:
		return
	DataManager.set_setting(value, setting)

func _refresh_preset_dropdown() -> void:
	if not _preset_dropdown:
		return
	
	_preset_dropdown.clear_items()
	_preset_dropdown.add_item("New Theme...", 0)
	
	_current_presets = DataManager.list_presets()
	for i in range(_current_presets.size()):
		var preset = _current_presets[i]
		_preset_dropdown.add_item(preset.get_display_name(), i + 1)
	
	_check_preset_match()

func _on_preset_selected(index: int) -> void:
	if _is_applying_preset or index <= 0 or index > _current_presets.size():
		return
	
	var preset = _current_presets[index - 1] as ThemePreset
	if not preset:
		return
	
	UIManager.show_confirm("Load Theme Preset", "Load preset '%s'?\n\nThis will overwrite your current library and card settings." % preset.name,
		func(): _apply_preset(preset),
		Callable(),
		func(): _preset_dropdown.selected = 0,
		{"cancel_text": "Cancel", "accept_text": "Load"}
	)

func _apply_preset(preset: ThemePreset) -> void:
	_is_applying_preset = true
	
	var success = DataManager.apply_preset(preset)
	if success:
		_loaded_preset = preset
		SystemManager.notifications.show_notification("Applied preset: %s" % preset.name, SystemManager.notifications.Type.SUCCESS)
		_refresh_all_settings_ui()
		_update_preset_dropdown_for_loaded_preset()
	else:
		SystemManager.notifications.show_notification("Failed to apply preset", SystemManager.notifications.Type.ERROR)
		_preset_dropdown.selected = 0
	
	_is_applying_preset = false

func _update_preset_dropdown_for_loaded_preset() -> void:
	if not _preset_dropdown or not _loaded_preset:
		return
	
	for i in range(_current_presets.size()):
		var preset = _current_presets[i] as ThemePreset
		if preset and preset.name == _loaded_preset.name:
			_preset_dropdown.selected = i + 1
			return
	
	_preset_dropdown.selected = 0

func _check_preset_match() -> void:
	if not _preset_dropdown:
		return
	
	if not _loaded_preset:
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.selected = 0
		return
	
	var current_preset = DataManager.create_preset_from_current()
	var is_match = _presets_equal(current_preset, _loaded_preset)
	
	if is_match:
		_update_preset_dropdown_for_loaded_preset()
	else:
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.selected = 0

func _presets_equal(a: ThemePreset, b: ThemePreset) -> bool:
	# Compare over the same flagged setting list that save/apply use; keys
	# missing from a preset mean its declared default (snapshot semantics).
	for s in DataManager.get_presettable_settings():
		var default: Variant = DataManager.get_setting_default(s.property_name)
		var va: Variant = a.values.get(s.property_name, default)
		var vb: Variant = b.values.get(s.property_name, default)
		if not EffectThemeAdapter.values_equal_approx(va, vb):
			return false
	return true

func _on_load_preset_pressed() -> void:
	UIManager.show_file_dialog("Import Theme Preset", PackedStringArray(["*.tres ; Theme Preset Files"]), "", func(path: String):
		var imported = DataManager.import_preset(path)
		if imported:
			SystemManager.notifications.show_notification("Imported preset: %s" % imported.name, SystemManager.notifications.Type.SUCCESS)
			_refresh_preset_dropdown()
			UIManager.show_confirm("Apply Imported Preset", "Apply the imported preset '%s' now?" % imported.name,
				func(): _apply_preset(imported),
				Callable(),
				func(): _preset_dropdown.selected = 0,
				{"cancel_text": "Cancel", "accept_text": "Apply"}
			)
		else:
			SystemManager.notifications.show_notification("Failed to import preset", SystemManager.notifications.Type.ERROR)
	, false)

func _on_export_preset_pressed() -> void:
	if not DataManager.is_settings_loaded():
		return
	
	var preset = DataManager.create_preset_from_current()
	
	UIManager.show_custom_dialog(func(dialog: M3Dialog):
		dialog.title_text = "Export Theme Preset"
		dialog.body_text = "Enter a name for this preset:"
		
		var line_edit = M3TextField.new()
		line_edit.label_text = "Preset Name"
		line_edit.text = preset.name
		line_edit.placeholder_text = "Preset Name"
		line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dialog.content_slot.add_child(line_edit)
		
		dialog.add_action("Cancel", Callable(), false)
		dialog.add_action("Save", func():
			if line_edit.text.is_empty():
				SystemManager.notifications.show_notification("Preset name cannot be empty", SystemManager.notifications.Type.WARNING)
				return
			
			preset.name = line_edit.text
			preset.created_at = Time.get_datetime_string_from_system()
			
			var success = DataManager.save_preset(preset)
			if success:
				SystemManager.notifications.show_notification("Saved preset: %s" % preset.name, SystemManager.notifications.Type.SUCCESS)
				_refresh_preset_dropdown()
			else:
				SystemManager.notifications.show_notification("Failed to save preset", SystemManager.notifications.Type.ERROR)
		, true)
	, func(): _preset_dropdown.selected = 0)

func refresh_values() -> void:
	_refresh_all_settings_ui()
