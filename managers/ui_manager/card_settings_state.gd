class_name CardSettingsState
extends RefCounted

## Centralized, typed state for all grid/card-related settings.
##
## Owned by UIManager. Updated only from DataManager preset/apply paths.
## Broadcasts bitmask-based change events so consumers can react with the
## minimum work required (layout recalc, effect rebuild, display refresh, etc.).

enum ChangeMask {
	NONE = 0,
	LAYOUT = 1,       ## layout_mode, grid_vertical, card_zoom_ratio, grid_padding, focus_scale_ratio
	EFFECTS = 2,      ## card_effect_config (base + focus effects, corner rounding)
	DISPLAY = 4,      ## display_mode, show_title_mode, content_alignment
	MEDIA_SHAPE = 8,  ## media_aspect_ratio
	THEME = 16,       ## dark_mode, primary_color
	NAVIGATION = 32,  ## focus_centering_mode (scroll behavior only, no layout recalc)
	TEXT = 64,        ## platform visibility, text alignment, focused-only text, marquee
}

# ---------------------------------------------------------------------------
# State fields (mirrors Settings, but is the canonical runtime copy for UI)
# ---------------------------------------------------------------------------
var layout_mode: int = 0
var grid_vertical: bool = true
## Split the grid into viewport-sized pages instead of continuous scrolling.
var pagination_enabled: bool = false
## Offset every other grid row by half a card width (brick pattern); offset
## rows show one fewer card. Vertical grid only.
var grid_staggered: bool = false
var card_zoom_ratio: float = 0.25
var card_zoom_level: int = -1
## Card size ratio for LIST/CAROUSEL modes (per-mode zoom memory).
var card_zoom_list_ratio: float = 0.25
var grid_padding: int = 22
var focus_scale_ratio: float = 0.09
var display_mode: int = 0
var content_alignment: int = 0
var media_aspect_ratio: int = 0
var show_title_mode: int = 0
var show_platform: bool = true
## 0 = follow content_alignment, 1 = left, 2 = center, 3 = right.
var text_alignment: int = 0
var scroll_truncation: bool = false
var text_focused_only: bool = false
var card_effect_config: Dictionary = {}
var dark_mode: bool = true
var primary_color: Color = Color.WHITE
## 0 = Margin (edge-triggered: slide the card just back on screen)
## 1 = Center (edge-triggered: bring the card to the screen center)
var focus_centering_mode: int = 0

# ---------------------------------------------------------------------------
# Batch / change coalescing
# ---------------------------------------------------------------------------
var pending_mask: int = 0
var _batch_depth: int = 0

signal changed(mask: int)

func begin_batch() -> void:
	_batch_depth += 1

func end_batch() -> int:
	_batch_depth = max(0, _batch_depth - 1)
	if _batch_depth == 0 and pending_mask != 0:
		var mask := pending_mask
		pending_mask = 0
		changed.emit(mask)
		return mask
	return ChangeMask.NONE

func _mark(mask: int) -> void:
	if _batch_depth > 0:
		pending_mask |= mask
	else:
		changed.emit(mask)

# ---------------------------------------------------------------------------
# Setters (return true when value changed)
# ---------------------------------------------------------------------------
func set_layout_mode(value: int) -> bool:
	if layout_mode == value:
		return false
	layout_mode = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_grid_vertical(value: bool) -> bool:
	if grid_vertical == value:
		return false
	grid_vertical = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_pagination_enabled(value: bool) -> bool:
	if pagination_enabled == value:
		return false
	pagination_enabled = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_grid_staggered(value: bool) -> bool:
	if grid_staggered == value:
		return false
	grid_staggered = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_card_zoom_ratio(value: float) -> bool:
	if is_equal_approx(card_zoom_ratio, value):
		return false
	card_zoom_ratio = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_card_zoom_level(value: int) -> bool:
	if card_zoom_level == value:
		return false
	card_zoom_level = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_card_zoom_list_ratio(value: float) -> bool:
	if is_equal_approx(card_zoom_list_ratio, value):
		return false
	card_zoom_list_ratio = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_grid_padding(value: int) -> bool:
	if grid_padding == value:
		return false
	grid_padding = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_focus_scale_ratio(value: float) -> bool:
	if is_equal_approx(focus_scale_ratio, value):
		return false
	focus_scale_ratio = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_display_mode(value: int) -> bool:
	if display_mode == value:
		return false
	display_mode = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_content_alignment(value: int) -> bool:
	if content_alignment == value:
		return false
	content_alignment = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_show_title_mode(value: int) -> bool:
	if show_title_mode == value:
		return false
	show_title_mode = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_show_platform(value: bool) -> bool:
	if show_platform == value:
		return false
	show_platform = value
	_mark(ChangeMask.TEXT)
	return true

func set_text_alignment(value: int) -> bool:
	if text_alignment == value:
		return false
	text_alignment = value
	_mark(ChangeMask.TEXT)
	return true

func set_scroll_truncation(value: bool) -> bool:
	if scroll_truncation == value:
		return false
	scroll_truncation = value
	_mark(ChangeMask.TEXT)
	return true

func set_text_focused_only(value: bool) -> bool:
	if text_focused_only == value:
		return false
	text_focused_only = value
	# Focused Only is a Media Only presentation mode plus a floating title
	# pill, so card geometry must be refreshed alongside the text state.
	_mark(ChangeMask.DISPLAY | ChangeMask.TEXT)
	return true

func set_media_aspect_ratio(value: int) -> bool:
	if media_aspect_ratio == value:
		return false
	media_aspect_ratio = value
	_mark(ChangeMask.MEDIA_SHAPE)
	return true

func set_card_effect_config(value: Dictionary) -> bool:
	# Compare by hash to avoid redundant emissions when dictionaries are identical
	if card_effect_config.hash() == value.hash():
		return false
	card_effect_config = value.duplicate(true)
	_mark(ChangeMask.EFFECTS)
	return true

func set_dark_mode(value: bool) -> bool:
	if dark_mode == value:
		return false
	dark_mode = value
	_mark(ChangeMask.THEME)
	return true

func set_primary_color(value: Color) -> bool:
	if primary_color.is_equal_approx(value):
		return false
	primary_color = value
	_mark(ChangeMask.THEME)
	return true

func set_focus_centering_mode(value: int) -> bool:
	if focus_centering_mode == value:
		return false
	focus_centering_mode = value
	_mark(ChangeMask.NAVIGATION)
	return true

# ---------------------------------------------------------------------------
# Derived helpers
# ---------------------------------------------------------------------------
func get_effective_display_mode() -> int:
	return 2 if text_focused_only else display_mode

func get_corner_rounding() -> float:
	if card_effect_config.is_empty():
		return 0.12
	var rounding = card_effect_config.get("card_rounding", 0.12)
	if rounding == null:
		return 0.12
	return float(rounding)

func get_base_effects() -> Array:
	if card_effect_config.is_empty():
		return []
	var effects = card_effect_config.get("effects", [])
	if effects is Array:
		return effects.duplicate(true)
	return []

func get_focus_effects() -> Array:
	if card_effect_config.is_empty():
		return []
	var effects = card_effect_config.get("focus_effects", [])
	if effects is Array:
		return effects.duplicate(true)
	return []

# ---------------------------------------------------------------------------
# Sync from DataManager
# ---------------------------------------------------------------------------
func sync_from_settings_manager() -> int:
	if not DataManager.is_settings_loaded():
		return ChangeMask.NONE

	begin_batch()
	set_layout_mode(_get_int_setting("library_layout_mode", 0))
	set_grid_vertical(_get_bool_setting("library_grid_vertical", true))
	set_pagination_enabled(_get_bool_setting("library_pagination_view", false))
	set_grid_staggered(_get_bool_setting("library_grid_staggered", false))
	set_card_zoom_ratio(_get_float_setting("library_card_zoom", 0.25))
	set_card_zoom_level(_get_int_setting("library_card_zoom_level", -1))
	set_card_zoom_list_ratio(_get_float_setting("library_card_zoom_list", 0.25))
	set_grid_padding(_get_int_setting("library_grid_padding", 22))
	set_focus_scale_ratio(_get_float_setting("library_focus_scale", 0.09))
	set_display_mode(_get_int_setting("library_card_display_mode", 0))
	set_content_alignment(_get_int_setting("library_card_content_alignment", 0))
	set_media_aspect_ratio(_get_int_setting("card_media_aspect_ratio", 0))
	set_show_title_mode(_get_int_setting("library_show_title_mode", 0))
	set_show_platform(_get_bool_setting("library_card_show_platform", true))
	set_text_alignment(_get_int_setting("library_card_text_alignment", 0))
	set_scroll_truncation(_get_bool_setting("library_card_scroll_truncation", false))
	set_text_focused_only(_get_bool_setting("library_card_text_focused_only", false))
	set_card_effect_config(_get_dict_setting("card_effect_config", {}))
	set_dark_mode(_get_bool_setting("dark_mode", true))
	set_primary_color(_get_color_setting("library_primary_color", Color.WHITE))
	set_focus_centering_mode(_get_int_setting("library_focus_centering", 0))
	var emitted_mask := pending_mask
	end_batch()

	return emitted_mask

func apply_setting(property_name: String, value: Variant) -> int:
	match property_name:
		"library_layout_mode":
			return ChangeMask.LAYOUT if set_layout_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_grid_vertical":
			return ChangeMask.LAYOUT if set_grid_vertical(_coerce_bool(value, true)) else ChangeMask.NONE
		"library_pagination_view":
			return ChangeMask.LAYOUT if set_pagination_enabled(_coerce_bool(value, false)) else ChangeMask.NONE
		"library_grid_staggered":
			return ChangeMask.LAYOUT if set_grid_staggered(_coerce_bool(value, false)) else ChangeMask.NONE
		"library_card_zoom":
			return ChangeMask.LAYOUT if set_card_zoom_ratio(_coerce_float(value, 0.25)) else ChangeMask.NONE
		"library_card_zoom_level":
			return ChangeMask.LAYOUT if set_card_zoom_level(_coerce_int(value, -1)) else ChangeMask.NONE
		"library_card_zoom_list":
			return ChangeMask.LAYOUT if set_card_zoom_list_ratio(_coerce_float(value, 0.25)) else ChangeMask.NONE
		"library_grid_padding":
			return ChangeMask.LAYOUT if set_grid_padding(_coerce_int(value, 22)) else ChangeMask.NONE
		"library_focus_scale":
			return ChangeMask.LAYOUT if set_focus_scale_ratio(_coerce_float(value, 0.09)) else ChangeMask.NONE
		"library_card_display_mode":
			return ChangeMask.DISPLAY if set_display_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_card_content_alignment":
			return ChangeMask.DISPLAY if set_content_alignment(_coerce_int(value, 0)) else ChangeMask.NONE
		"card_media_aspect_ratio":
			return ChangeMask.MEDIA_SHAPE if set_media_aspect_ratio(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_show_title_mode":
			return ChangeMask.DISPLAY if set_show_title_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_card_show_platform":
			return ChangeMask.TEXT if set_show_platform(_coerce_bool(value, true)) else ChangeMask.NONE
		"library_card_text_alignment":
			return ChangeMask.TEXT if set_text_alignment(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_card_scroll_truncation":
			return ChangeMask.TEXT if set_scroll_truncation(_coerce_bool(value, false)) else ChangeMask.NONE
		"library_card_text_focused_only":
			return (ChangeMask.DISPLAY | ChangeMask.TEXT) if set_text_focused_only(_coerce_bool(value, false)) else ChangeMask.NONE
		"card_effect_config":
			return ChangeMask.EFFECTS if set_card_effect_config(_coerce_dict(value, {})) else ChangeMask.NONE
		"dark_mode":
			return ChangeMask.THEME if set_dark_mode(_coerce_bool(value, true)) else ChangeMask.NONE
		"library_primary_color":
			return ChangeMask.THEME if set_primary_color(_coerce_color(value, Color.WHITE)) else ChangeMask.NONE
		"library_focus_centering":
			return ChangeMask.NAVIGATION if set_focus_centering_mode(_coerce_int(value, 0)) else ChangeMask.NONE
	return ChangeMask.NONE

# ---------------------------------------------------------------------------
# Private coercion helpers
# ---------------------------------------------------------------------------
func _get_int_setting(name: String, default: int) -> int:
	var setting = DataManager.get_setting(name)
	# Tolerate floats: prefs saved before the set_setting type coercion may
	# hold float values for INT settings.
	if setting and (setting.value is int or setting.value is float):
		return int(setting.value)
	return default

func _get_float_setting(name: String, default: float) -> float:
	var setting = DataManager.get_setting(name)
	if setting and (setting.value is float or setting.value is int):
		return float(setting.value)
	return default

func _get_bool_setting(name: String, default: bool) -> bool:
	var setting = DataManager.get_setting(name)
	if setting and setting.value is bool:
		return setting.value
	return default

func _get_dict_setting(name: String, default: Dictionary) -> Dictionary:
	var setting = DataManager.get_setting(name)
	if setting and setting.value is Dictionary:
		return setting.value.duplicate(true)
	return default.duplicate()

func _get_color_setting(name: String, default: Color) -> Color:
	var setting = DataManager.get_setting(name)
	if setting and setting.value is Color:
		return setting.value
	return default

func _coerce_int(value: Variant, default: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	return default

func _coerce_float(value: Variant, default: float) -> float:
	if value is float or value is int:
		return float(value)
	return default

func _coerce_bool(value: Variant, default: bool) -> bool:
	if value is bool:
		return value
	return default

func _coerce_dict(value: Variant, default: Dictionary) -> Dictionary:
	if value is Dictionary:
		return value.duplicate(true)
	return default.duplicate()

func _coerce_color(value: Variant, default: Color) -> Color:
	if value is Color:
		return value
	return default
