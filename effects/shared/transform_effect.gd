class_name TransformEffect
extends EffectBase

## Geometry-only controller for the whole EffectStack. The stack applies this
## transform to its canvas item instead of drawing another copy of the source.
static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

static func is_geometry_only() -> bool:
	return true

static func is_theme_adaptive() -> bool:
	return false

func _init() -> void:
	super._init()
	effect_id = "transform"

static func make_transform(settings: Dictionary, target_size: Vector2) -> Transform2D:
	var pan := Vector2(
		float(settings.get("pan_x", 0.0)) * target_size.x,
		float(settings.get("pan_y", 0.0)) * target_size.y
	)
	var pivot := target_size * 0.5
	var angle := deg_to_rad(float(settings.get("rotation", 0.0)))
	var uniform_scale := maxf(0.01, float(settings.get("scale", 1.0)))

	var rotation_basis := Transform2D(angle, Vector2.ZERO)
	var x_axis := rotation_basis.x * uniform_scale
	var y_axis := rotation_basis.y * uniform_scale
	# Keep the media center fixed before applying pan. Chaining Translated/
	# Rotated/Scaled would also transform the pivot offset and move the center.
	var origin := pivot + pan - (rotation_basis * pivot) * uniform_scale
	return Transform2D(x_axis, y_axis, origin)

func get_transform(target_size: Vector2) -> Transform2D:
	return make_transform(_settings, target_size)

static func build_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var pan_x_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Pan X", "Horizontal pan as a percentage of the target width", -1.0, 1.0, 0.01, [], false, {"display_scale": 100.0, "display_unit": "%"})
	pan_x_var.property_name = "pan_x"
	schema.append(pan_x_var)

	var pan_y_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Pan Y", "Vertical pan as a percentage of the target height", -1.0, 1.0, 0.01, [], false, {"display_scale": 100.0, "display_unit": "%"})
	pan_y_var.property_name = "pan_y"
	schema.append(pan_y_var)

	var scale_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Scale", "Uniform scale around the center", 0.1, 4.0, 0.01, [], false, {"display_scale": 100.0, "display_unit": "%"})
	scale_var.property_name = "scale"
	schema.append(scale_var)

	var rotation_var = SettingsVar.new(Type.ANGLE, 0.0, State.ENABLED, "Rotation", "Clockwise rotation around the center", -180.0, 180.0, 1.0)
	rotation_var.property_name = "rotation"
	schema.append(rotation_var)

	return schema

func get_settings_schema() -> Array[SettingsVar]:
	return build_settings_schema()
