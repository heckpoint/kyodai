class_name DropShadowEffect
extends EffectBase

static func is_material_shareable() -> bool:
	return true

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

## A shadow is meant to stay dark in both modes; converting its color across
## dark/light swaps (brightening it in light mode) reads as the effect
## breaking, so its settings never convert — see EffectThemeAdapter.
static func is_theme_adaptive() -> bool:
	return false

const SHADOW_MARGIN_RATIO = 0.05

func _init():
	super._init()
	effect_id = "drop_shadow"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/drop_shadow.gdshader")

func set_z_index(value: int) -> void:
	# The automatic base image uses z=0. Shadows are always behind it, regardless
	# of their configuration position; interior alpha is handled by compositing.
	super.set_z_index(-maxi(1, value))

func get_draw_rect() -> Rect2:
	if not media_container:
		return Rect2()

	var shadow_offset_x_ratio = _settings.get("shadow_offset_x", 0.0)
	var shadow_offset_y_ratio = _settings.get("shadow_offset_y", 0.05)
	var shadow_softness_ratio = _settings.get("shadow_softness", 0.04)
	var margin_ratio = SHADOW_MARGIN_RATIO + max(abs(shadow_offset_x_ratio), abs(shadow_offset_y_ratio)) + shadow_softness_ratio

	var card_size = media_container.size
	var margin_x = margin_ratio * card_size.x
	var margin_y = margin_ratio * card_size.y
	return Rect2(Vector2(-margin_x, -margin_y), card_size + Vector2(margin_x * 2.0, margin_y * 2.0))

func _update_shader_params() -> void:
	if not media_container:
		return

	_ensure_shared_material()

	var shadow_color = _settings.get("shadow_color", Color(0, 0, 0, 0.5))
	var shadow_offset_x = _settings.get("shadow_offset_x", 0.0)
	var shadow_offset_y = _settings.get("shadow_offset_y", 0.05)
	var shadow_softness = _settings.get("shadow_softness", 0.04)
	var shadow_spread = _settings.get("shadow_spread", 0.0)
	var shadow_expand = _settings.get("shadow_expand", 0.02)

	var card_size = media_container.size

	var shadow_offset = Vector2(shadow_offset_x * card_size.x, shadow_offset_y * card_size.y)
	var card_min = min(card_size.x, card_size.y)
	var softness_pixels = shadow_softness * card_min

	# Match get_draw_rect exactly: all three values are still ratios at
	# this point. Converting them before computing margin double-scales the rect.
	var margin_ratio = SHADOW_MARGIN_RATIO + max(abs(shadow_offset_x), abs(shadow_offset_y)) + shadow_softness
	var margin_x = card_size.x * margin_ratio
	var margin_y = card_size.y * margin_ratio
	var shadow_margin = Vector2(margin_x, margin_y)

	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("shadow_color", shadow_color)
	_set_shader_param("shadow_offset", shadow_offset)
	_set_shader_param("shadow_softness", softness_pixels)
	_set_shader_param("shadow_spread", shadow_spread)
	_set_shader_param("shadow_expand", shadow_expand)
	_set_shader_param("shadow_margin", shadow_margin)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var color_var = SettingsVar.new(Type.COLOR, Color(0, 0, 0, 0.5), State.ENABLED, "Shadow Color")
	color_var.property_name = "shadow_color"
	schema.append(color_var)

	var offset_x_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Offset X", "Ratio of card width", -0.1, 0.1, 0.001)
	offset_x_var.property_name = "shadow_offset_x"
	schema.append(offset_x_var)

	var offset_y_var = SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Shadow Offset Y", "Ratio of card height", -0.1, 0.1, 0.001)
	offset_y_var.property_name = "shadow_offset_y"
	schema.append(offset_y_var)

	var softness_var = SettingsVar.new(Type.FLOAT, 0.04, State.ENABLED, "Shadow Softness", "Ratio of min(card width, height)", 0.0, 0.15, 0.001)
	softness_var.property_name = "shadow_softness"
	schema.append(softness_var)

	var spread_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Spread", "", 0.0, 1.0, 0.01)
	spread_var.property_name = "shadow_spread"
	schema.append(spread_var)

	var expand_var = SettingsVar.new(Type.FLOAT, 0.02, State.ENABLED, "Shadow Expand", "Ratio of card size", 0.0, 0.2, 0.001)
	expand_var.property_name = "shadow_expand"
	schema.append(expand_var)

	return schema
