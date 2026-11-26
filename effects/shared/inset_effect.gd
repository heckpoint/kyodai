class_name InsetEffect
extends EffectBase

## Geometry-only layer. It advances the content edge for subsequent strokes and
## for the final base-media aperture, but creates no canvas item or draw call.

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

static func is_geometry_only() -> bool:
	return true

func _init() -> void:
	super._init()
	effect_id = "inset"

func get_inset_pixels(card_size: Vector2) -> float:
	return maxf(0.0, float(_settings.get("inset_ratio", 0.0)) * card_size.x)

# Internal asymmetric aperture support for launch transitions. The designer
# exposes only the uniform inset above.
func get_top_inset_pixels(card_size: Vector2) -> float:
	return maxf(0.0, float(_settings.get("top_inset_ratio", 0.0)) * card_size.y)

func get_left_inset_pixels(card_size: Vector2) -> float:
	return maxf(0.0, float(_settings.get("left_inset_ratio", 0.0)) * card_size.x)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	var inset_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Inset", "Ratio of card width", 0.0, 0.5, 0.001)
	inset_var.property_name = "inset_ratio"
	schema.append(inset_var)
	return schema
