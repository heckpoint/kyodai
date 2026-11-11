class_name BackgroundDesignerView
extends Control

## Background Designer: one ordered composition of strict background layers
## and compatible shared effects over the M3 surface base color.

var _config: Dictionary = {}
var _config_loaded: bool = false
var _suppress_config_signal: bool = false

var _effects_designer: EffectDesignerUI
var _preview_background: LibraryBackground

func _ready():
	_setup_ui()
	_load_current_config()

	if DataManager:
		DataManager.settings_saved.connect(_on_settings_saved)
		DataManager.setting_changed.connect(_on_setting_changed)

	get_viewport().gui_focus_changed.connect(_on_focus_changed)

func _exit_tree():
	if DataManager and DataManager.settings_saved.is_connected(_on_settings_saved):
		DataManager.settings_saved.disconnect(_on_settings_saved)
	if DataManager and DataManager.setting_changed.is_connected(_on_setting_changed):
		DataManager.setting_changed.disconnect(_on_setting_changed)

func on_view_show():
	# Pick up any custom shaders the user dropped in while the view was away.
	EffectRegistry.rescan()
	if _effects_designer:
		_effects_designer.rediscover()
	_load_current_config()

func on_view_hide():
	if _config_loaded:
		_save_to_settings()

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Preserve the user's dragged split ratio across resizes instead of
	# slamming the divider back to a constant on every size change.
	var split_ratio := [0.55]
	hsplit.dragged.connect(func(offset: int):
		if hsplit.size.x > 0.0:
			split_ratio[0] = clampf(offset / hsplit.size.x, 0.1, 0.9)
	)
	hsplit.resized.connect(func():
		hsplit.split_offset = int(hsplit.size.x * split_ratio[0])
	)
	add_child(hsplit)

	var scroll = ScrollContainer.new()
	scroll.clip_contents = true
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	hsplit.add_child(scroll)

	var left_vbox = VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	scroll.add_child(left_vbox)

	# One ordered composition of strict background layers and shared effects.
	_effects_designer = EffectDesignerUI.new()
	_effects_designer.use_internal_scroll = false
	_effects_designer.effect_registry = LibraryBackground.get_designer_registry()
	_effects_designer.display_names = LibraryBackground.EFFECT_DISPLAY_NAMES
	_effects_designer.custom_kind = "background"
	_effects_designer.allow_multiple = true
	_effects_designer.allow_reorder = true
	_effects_designer.setup("Background Layers", "", "effects", false)
	_effects_designer.config_changed.connect(_on_effects_config_changed)
	left_vbox.add_child(_effects_designer)

	# Live preview
	var right_container = Control.new()
	right_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.add_child(right_container)

	var library_bg = preload("res://components/library_background.tscn").instantiate()
	library_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_container.add_child(library_bg)
	_preview_background = library_bg

func _load_current_config():
	_config_loaded = false
	if DataManager:
		var config_setting = DataManager.get_setting("library_background_config")
		if config_setting and config_setting.value is Dictionary:
			_config = LibraryBackground.normalize_config(config_setting.value)
	if _config.is_empty():
		_config = {"effects": []}

	if _effects_designer:
		_effects_designer.set_config(_config)
	_update_preview()

	_config_loaded = true

func _on_effects_config_changed(config: Dictionary):
	if not _config_loaded:
		return
	_config["effects"] = config.get("effects", []).duplicate(true)
	_apply()

func _apply():
	_update_preview()
	_save_to_settings()

func _update_preview():
	if _preview_background and is_instance_valid(_preview_background):
		_preview_background.set_background_config(_config)

func _save_to_settings() -> void:
	if not DataManager or not _config_loaded:
		return
	var config_setting = DataManager.get_setting("library_background_config")
	if config_setting:
		_suppress_config_signal = true
		DataManager.set_setting(_config.duplicate(true), config_setting)
		_suppress_config_signal = false

func _on_settings_saved():
	_load_current_config()

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if _suppress_config_signal:
		return
	if setting.property_name == "library_background_config" and value is Dictionary:
		_load_current_config()

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return

	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)

	viewport.gui_focus_changed.connect(_on_focus_changed)

	if _effects_designer and _effects_designer.has_method("reconnect_viewport"):
		_effects_designer.reconnect_viewport()

func _on_focus_changed(control: Control) -> void:
	if not control:
		return
	if _effects_designer and _effects_designer.is_ancestor_of(control):
		if _effects_designer._scroll_container:
			_effects_designer._scroll_container.ensure_control_visible(control)
		return
