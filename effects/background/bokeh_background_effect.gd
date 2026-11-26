class_name BokehBackgroundEffect
extends BackgroundEffect

## Full-background post-process. This must run after the layers it softens so
## transparent source edges are composited before blur, rather than blurred as
## independent alpha coverage.
static func is_theme_adaptive() -> bool:
	return false

func _ready():
	super._ready()
	effect_name = "Bokeh"
	effect_id = "bokeh"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_bokeh.gdshader")

func _apply_settings() -> void:
	_set_shader_param("blur_radius", _settings.get("blur_radius", 2.0))
	_set_shader_param("bloom_radius", _settings.get("bloom_radius", 10.0))
	_set_shader_param("bloom_strength", _settings.get("bloom_strength", 0.4))
	_set_shader_param("bloom_threshold", _settings.get("bloom_threshold", 0.95))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var blur_var = SettingsVar.new(Type.FLOAT, 2.0, State.ENABLED, "Blur Radius", "Post-composite bokeh softness in pixels", 0.0, 8.0, 0.25)
	blur_var.property_name = "blur_radius"
	schema.append(blur_var)

	var bloom_radius_var = SettingsVar.new(Type.FLOAT, 10.0, State.ENABLED, "Bloom Radius", "Spread of rare near-white highlights", 0.0, 16.0, 0.5)
	bloom_radius_var.property_name = "bloom_radius"
	schema.append(bloom_radius_var)

	var bloom_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Bloom Strength", "Subtle highlight lift after compositing", 0.0, 0.5, 0.01)
	bloom_var.property_name = "bloom_strength"
	schema.append(bloom_var)

	var threshold_var = SettingsVar.new(Type.FLOAT, 0.95, State.ENABLED, "Bloom Threshold", "Minimum value of every RGB channel treated as a highlight", 0.5, 1.0, 0.005)
	threshold_var.property_name = "bloom_threshold"
	schema.append(threshold_var)

	return schema
