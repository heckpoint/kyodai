class_name TransformBackgroundEffect
extends BackgroundEffect

const TransformSettings = preload("res://effects/shared/transform_effect.gd")

## Screen-space host for the shared Transform controls. Unlike the card stack's
## canvas transform, this post-process transforms the background composed so far.
static func is_theme_adaptive() -> bool:
	return false

func _ready():
	super._ready()
	effect_name = "Transform"
	effect_id = "transform"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_transform.gdshader")

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and material:
		_apply_settings()

func _apply_settings() -> void:
	var transform := TransformSettings.make_transform(_settings, size)
	_set_shader_param("target_size", size)
	_set_shader_param("transform_x", transform.x)
	_set_shader_param("transform_y", transform.y)
	_set_shader_param("transform_origin", transform.origin)
	_set_shader_param("background_color", M3Theme.get_surface_container_low())

func get_settings_schema() -> Array[SettingsVar]:
	return TransformSettings.build_settings_schema()
