class_name CardDesignerView
extends Control

var _media_container: MediaContainer = MediaContainer.new()

func _init():
	_media_container.bounds = Rect2(Vector2.ZERO, Vector2(202.0, 270.0))
var _current_config: Dictionary = {}

var _preview_card: GameCard
var _preview_game: GameResource = null
var _card_rounding_slider: M3Slider
var _preview_background: LibraryBackground = null


# Shared effect designer UI instances
var _base_effect_designer: EffectDesignerUI
var _focus_effect_designer: EffectDesignerUI

# Guards against emitting save signals before the view has loaded real config.
var _config_loaded: bool = false

func _ready():
	_setup_ui()
	_load_current_config()
	call_deferred("_setup_preview_card")
	
	# Connect to settings changes so we refresh when a preset is applied
	if DataManager:
		DataManager.settings_saved.connect(_on_settings_saved)
		DataManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)

func _on_settings_saved():
	_load_current_config()
	# Don't call _setup_preview_card() here — it calls _save_to_settings() which
	# emits setting_changed(card_effect_config) and triggers UIManager._rebuild_views().
	# Just refresh the preview card directly since settings are already saved.
	if _preview_card and is_instance_valid(_preview_card):
		_preview_card.refresh_settings()

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "library_background_config":
		if _preview_background and value is Dictionary:
			_preview_background.set_background_config(value)

func _exit_tree():
	# Disconnect signal to prevent callbacks on freed object
	if DataManager and DataManager.settings_saved.is_connected(_on_settings_saved):
		DataManager.settings_saved.disconnect(_on_settings_saved)
	if DataManager and DataManager.setting_changed.is_connected(_on_setting_changed):
		DataManager.setting_changed.disconnect(_on_setting_changed)

func on_view_hide():
	# Only save if we've actually loaded config. During initialization the
	# preview card setup can trigger saves before config is populated.
	if _config_loaded:
		_save_to_settings()

func on_view_show():
	# Pick up any custom shaders the user dropped in while the view was away.
	EffectRegistry.rescan()
	if _base_effect_designer:
		_base_effect_designer.rediscover()
	if _focus_effect_designer:
		_focus_effect_designer.rediscover()
	# Reload config from DataManager to ensure we have latest (including preset changes)
	_load_current_config()
	_setup_preview_card()
	# Sync preview background in case it changed while the view was hidden
	if _preview_background and DataManager:
		var bg_setting = DataManager.get_setting("library_background_config")
		if bg_setting and bg_setting.value is Dictionary:
			_preview_background.set_background_config(bg_setting.value)

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Preserve the user's dragged split ratio across resizes instead of
	# slamming the divider back to a constant on every size change.
	var split_ratio := [0.65]
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

	var global_section := SettingsSection.new("Global Settings", "tune")
	left_vbox.add_child(global_section)

	var rounding_block := VBoxContainer.new()
	rounding_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rounding_block.add_theme_constant_override("separation", int(M3Units.dp(4)))
	global_section.add_content(rounding_block, false)

	var card_rounding_label = M3Label.new()
	card_rounding_label.text = "Card Rounding (0-1)"
	card_rounding_label.label_style = M3Label.Style.BODY_MEDIUM
	rounding_block.add_child(card_rounding_label)

	_card_rounding_slider = M3Slider.new()
	_card_rounding_slider.min_value = 0.0
	_card_rounding_slider.max_value = 1.0
	_card_rounding_slider.step = 0.01
	_card_rounding_slider.value = 0.12
	_card_rounding_slider.value_changed.connect(_on_card_rounding_changed)
	rounding_block.add_child(_card_rounding_slider)

	# Base effects designer
	_base_effect_designer = EffectDesignerUI.new()
	_base_effect_designer.use_internal_scroll = false
	_base_effect_designer.custom_kind = "card"
	_base_effect_designer.allow_multiple = true
	_base_effect_designer.allow_reorder = true
	_base_effect_designer.setup("Effects", "base_card", "effects", false)
	_base_effect_designer.config_changed.connect(_on_base_config_changed)
	_base_effect_designer.focus_override_requested.connect(_on_focus_override_requested)
	left_vbox.add_child(_base_effect_designer)

	# Focus effects designer
	_focus_effect_designer = EffectDesignerUI.new()
	_focus_effect_designer.use_internal_scroll = false
	_focus_effect_designer.custom_kind = "card"
	_focus_effect_designer.allow_multiple = true
	_focus_effect_designer.allow_reorder = true
	_focus_effect_designer.setup("Focus Effects", "focus_card", "focus_effects", true)
	_focus_effect_designer.config_changed.connect(_on_focus_config_changed)
	left_vbox.add_child(_focus_effect_designer)
	
	# Right side uses a plain Control so the LibraryBackground provides the only surface.
	var right_container = Control.new()
	right_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.add_child(right_container)
	
	# Add library background to show cards in context
	var library_bg = preload("res://components/library_background.tscn").instantiate()
	library_bg.preview_mode = true
	library_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_container.add_child(library_bg)
	_preview_background = library_bg
	
	var preview_container = CenterContainer.new()
	# Keep the interactive card above every background effect layer without
	# changing the live library or the background preview's own local Z-band.
	preview_container.z_index = 100
	preview_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_container.add_child(preview_container)
	
	_preview_card = preload("res://components/cards/game_card.tscn").instantiate()
	_preview_card.preview_mode = true
	_preview_card.focus_mode = Control.FOCUS_NONE
	_preview_card.preview_show_focus = false
	_preview_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	preview_container.add_child(_preview_card)
	
	# GameCard sets mouse_filter = IGNORE in _ready(), so we must override after
	_preview_card.call_deferred("set", "mouse_filter", Control.MOUSE_FILTER_STOP)
	_preview_card.mouse_entered.connect(func():
		if _preview_card:
			_preview_card.set_preview_focus(true)
	)
	_preview_card.mouse_exited.connect(func():
		if _preview_card:
			_preview_card.set_preview_focus(false)
	)

func _load_current_config():
	_config_loaded = false
	if DataManager:
		var config_setting = DataManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_current_config = config_setting.value.duplicate(true)
		else:
			_current_config = _get_default_config()
	else:
		_current_config = _get_default_config()
	
	# Migrate old keys to unified card_rounding
	if not _current_config.has("card_rounding"):
		if _current_config.has("art_rounding"):
			_current_config["card_rounding"] = _current_config["art_rounding"]
		elif _current_config.has("corner_radius"):
			_current_config["card_rounding"] = _current_config["corner_radius"]
	
	# Remove stale keys
	_current_config.erase("corner_radius")
	_current_config.erase("art_rounding")
	EffectDesignerUI.ensure_card_layer_ids(_current_config)
	
	var rounding_value = _current_config.get("card_rounding", 0.12)
	_card_rounding_slider.value = rounding_value
	_media_container.corner_radius_ratio = rounding_value
	if _preview_card and is_instance_valid(_preview_card):
		_preview_card.card_rounding_ratio = rounding_value
	_media_container.effect_settings = _current_config.get("effects", [])
	_media_container.focus_effect_settings = _current_config.get("focus_effects", [])
	
	# Sync shared effect designers
	if _base_effect_designer:
		_base_effect_designer.set_config(_current_config)
	if _focus_effect_designer:
		_focus_effect_designer.set_config(_current_config)
		_focus_effect_designer.set_base_effects(_current_config.get("effects", []))
	_sync_focus_override_targets()

	_config_loaded = true


func _get_default_config() -> Dictionary:
	return {
		"effects": [],
		"focus_effects": [],
		"card_rounding": 0.12,
	}

func set_preview_game(game: GameResource) -> void:
	"""Set the game whose cover should appear in the Card Designer preview."""
	_preview_game = game
	if _preview_card and is_instance_valid(_preview_card):
		_preview_card.set_game_with_priority(game, true)

func _setup_preview_card():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	_preview_card.custom_minimum_size = _media_container.size
	
	# Save current config to DataManager so refresh_settings() picks it up
	_save_to_settings()
	_preview_card.refresh_settings()
	
	# Apply the requested preview game, if any, after the card has been set up.
	if _preview_game and is_instance_valid(_preview_game):
		_preview_card.set_game_with_priority(_preview_game, true)

func _on_base_config_changed(config: Dictionary):
	_current_config["effects"] = config.get("effects", []).duplicate(true)
	EffectDesignerUI.ensure_card_layer_ids(_current_config)
	# Refresh focus designer's base reference so overlap labels stay current
	if _focus_effect_designer:
		_focus_effect_designer.set_base_effects(_current_config.get("effects", []))
	_sync_focus_override_targets()
	_update_preview()
	_save_to_settings()

func _on_focus_config_changed(config: Dictionary):
	_current_config["focus_effects"] = config.get("focus_effects", []).duplicate(true)
	EffectDesignerUI.ensure_card_layer_ids(_current_config)
	_sync_focus_override_targets()
	_update_preview()
	_save_to_settings()

func _on_focus_override_requested(effect_data: Dictionary) -> void:
	var base_layer_id = effect_data.get("layer_id", "")
	if not base_layer_id is String or base_layer_id.is_empty():
		return

	var focus_effects: Array = _current_config.get("focus_effects", []).duplicate(true)
	var has_override := false
	for focus_effect in focus_effects:
		if focus_effect is Dictionary and focus_effect.get("target_layer_id", "") == base_layer_id:
			has_override = true
			break

	if not has_override:
		var focus_entry := effect_data.duplicate(true)
		focus_entry["layer_id"] = EffectDesignerUI.generate_layer_id()
		focus_entry["target_layer_id"] = base_layer_id
		focus_effects.append(focus_entry)

	_current_config["focus_effects"] = focus_effects
	EffectDesignerUI.ensure_card_layer_ids(_current_config)
	if _base_effect_designer:
		_base_effect_designer.set_config(_current_config)
	if _focus_effect_designer:
		_focus_effect_designer.set_config(_current_config)
		_focus_effect_designer.set_base_effects(_current_config.get("effects", []))
	_sync_focus_override_targets()
	_update_preview()
	_save_to_settings()

func _sync_focus_override_targets() -> void:
	if not _base_effect_designer:
		return
	var target_layer_ids: Array = []
	for focus_effect in _current_config.get("focus_effects", []):
		if not focus_effect is Dictionary:
			continue
		var target_layer_id = focus_effect.get("target_layer_id", "")
		if target_layer_id is String and not target_layer_id.is_empty() and not target_layer_id in target_layer_ids:
			target_layer_ids.append(target_layer_id)
	_base_effect_designer.set_focus_override_targets(target_layer_ids)

func _on_card_rounding_changed(value: float):
	_current_config["card_rounding"] = value
	if _preview_card:
		_preview_card.card_rounding_ratio = value
	_media_container.corner_radius_ratio = value
	_update_preview()
	_save_to_settings()

func _update_preview():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	# Save current config to DataManager so refresh_settings() picks it up
	_save_to_settings()
	_preview_card.refresh_settings()

func _save_to_settings() -> void:
	"""Save the current config to DataManager immediately."""
	if not DataManager:
		return
	if not _config_loaded:
		return
	
	EffectDesignerUI.ensure_card_layer_ids(_current_config)
	var config_setting = DataManager.get_setting("card_effect_config")
	if config_setting:
		var effects_count := 0
		var focus_effects_count := 0
		if _current_config.get("effects") is Array:
			effects_count = _current_config.effects.size()
		if _current_config.get("focus_effects") is Array:
			focus_effects_count = _current_config.focus_effects.size()
		print("[CardDesignerView] _save_to_settings: effects=", effects_count, " focus_effects=", focus_effects_count, " config=", _current_config)
		DataManager.set_setting(_current_config.duplicate(true), config_setting)

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	viewport.gui_focus_changed.connect(_on_focus_changed)
	
	# Reconnect nested EffectDesignerUI viewports
	if _base_effect_designer and _base_effect_designer.has_method("reconnect_viewport"):
		_base_effect_designer.reconnect_viewport()
	if _focus_effect_designer and _focus_effect_designer.has_method("reconnect_viewport"):
		_focus_effect_designer.reconnect_viewport()

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in nested scroll containers."""
	if not control:
		return
	
	# Forward to the appropriate designer's scroll container
	if _base_effect_designer and _base_effect_designer.is_ancestor_of(control):
		if _base_effect_designer._scroll_container:
			_base_effect_designer._scroll_container.ensure_control_visible(control)
		return
	
	if _focus_effect_designer and _focus_effect_designer.is_ancestor_of(control):
		if _focus_effect_designer._scroll_container:
			_focus_effect_designer._scroll_container.ensure_control_visible(control)
		return
