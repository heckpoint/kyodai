class_name DistortEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _init():
	super._init()
	effect_id = "distort"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/distort.gdshader")

func set_z_index(value: int) -> void:
	# Match Glass's behind-media swoop: the automatic base art uses z=0, so a
	# behind-art distortion renders at z=-1 and only shows through transparency.
	var behind_art: bool = _settings.get("distort_behind_media", false)
	super.set_z_index(-1 if behind_art else value)

func _update_shader_params() -> void:
	if not media_container:
		return

	var distortion = _settings.get("distortion", 0.5)
	var opacity = _settings.get("opacity", 1.0)

	var uv = media_container.get_uv_transforms()

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", layer_inset_pixels)
	_set_shader_param("distortion", distortion)
	_set_shader_param("opacity", opacity)
	_set_shader_param("uv_transform_scale", uv["uv_transform_scale"])
	_set_shader_param("uv_transform_offset", uv["uv_transform_offset"])
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var distortion_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Distortion", "", 0.0, 1.0, 0.01)
	distortion_var.property_name = "distortion"
	schema.append(distortion_var)

	var opacity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Opacity", "", 0.0, 1.0, 0.01)
	opacity_var.property_name = "opacity"
	schema.append(opacity_var)

	var behind_art_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Behind Art", "Render behind the cover art so distortion only shows through transparent media and inset areas")
	behind_art_var.property_name = "distort_behind_media"
	schema.append(behind_art_var)

	return schema
