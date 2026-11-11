class_name CafeOSBackgroundEffect
extends BackgroundEffect

# The raymarched 3D effect is GPU-heavy; render at half resolution and let
# the host upscale. Initialized here so the host sees it before _ready().
func _init():
	render_scale = 0.5

func _ready():
	super._ready()
	effect_name = "CafeOS"
	effect_id = "cafeos"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_cafeos.gdshader")
	
	# Load the icon atlas texture (x4 resolution)
	var icon_atlas = load("res://assets/icons/wiiu_atlas_x4.png")
	if icon_atlas:
		_set_shader_param("icon_atlas", icon_atlas)

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 0.5))
	_set_shader_param("orbit_radius", _settings.get("orbit_radius", 2.358))
	_set_shader_param("icon_scale", _settings.get("icon_scale", 0.7))
	_set_shader_param("orbit_speed", _settings.get("orbit_speed", 0.15))
	_set_shader_param("num_icons", _settings.get("num_icons", 21))
	
	# Light direction as normalized vec3
	var light_dir = _settings.get("light_direction", Vector3(1.0, 1.0, 0.0))
	_set_shader_param("light_direction", light_dir.normalized())
	
	# 3D Extrusion & Raymarching Settings
	_set_shader_param("extrusion_depth", _settings.get("extrusion_depth", 0.03))
	_set_shader_param("max_ray_steps", _settings.get("max_ray_steps", 16))
	_set_shader_param("ray_step_size", _settings.get("ray_step_size", 0.002))
	_set_shader_param("alpha_threshold", _settings.get("alpha_threshold", 0.9))
	_set_shader_param("edge_softness", _settings.get("edge_softness", 1.0))
	
	# Blur Settings
	_set_shader_param("blur_amount", _settings.get("blur_amount", 0.004))
	_set_shader_param("blur_kernel_size", _settings.get("blur_kernel_size", 6))
	
	# Lighting Settings
	_set_shader_param("light_ambient", _settings.get("light_ambient", 0.85))
	_set_shader_param("light_diffuse", _settings.get("light_diffuse", 0.275))
	_set_shader_param("front_face_brightness", _settings.get("front_face_brightness", 1.0))
	
	# Anti-aliasing
	_set_shader_param("supersample_level", _settings.get("supersample_level", 2))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var time_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Time Scale", "Animation speed", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)
	
	var orbit_radius_var = SettingsVar.new(Type.FLOAT, 2.5, State.ENABLED, "Orbit Radius", "Size of the orbit sphere", 1.0, 5.0, 0.1)
	orbit_radius_var.property_name = "orbit_radius"
	schema.append(orbit_radius_var)
	
	var icon_scale_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Icon Scale", "Size of controller icons", 0.1, 1.0, 0.05)
	icon_scale_var.property_name = "icon_scale"
	schema.append(icon_scale_var)
	
	var orbit_speed_var = SettingsVar.new(Type.FLOAT, 0.15, State.ENABLED, "Orbit Speed", "How fast icons orbit", 0.05, 1.0, 0.05)
	orbit_speed_var.property_name = "orbit_speed"
	schema.append(orbit_speed_var)
	
	var num_icons_var = SettingsVar.new(Type.INT, 15, State.ENABLED, "Icon Count", "Number of icons to display", 5, 30, 1)
	num_icons_var.property_name = "num_icons"
	schema.append(num_icons_var)
	
	return schema
