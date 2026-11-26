class_name BackgroundEffect
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

## Fraction of the host size to render at (1.0 = full res). Values below 1.0
## make library_background host the effect inside a scaled-down SubViewport
## and stretch it back up — for GPU-heavy effects that are soft by design.
var render_scale: float = 1.0

## Scaled transparent viewports must be composited with premultiplied alpha
## when their shader outputs premultiplied RGB. This prevents bilinear upscaling
## from creating dark fringes where coverage approaches zero.
var output_premultiplied_alpha: bool = false

var _settings: Dictionary = {}

## Mirror of EffectBase.is_theme_adaptive(): whether EffectThemeAdapter
## converts this background effect's settings across dark/light swaps.
## Backgrounds stay adaptive by default; override to lock one.
static func is_theme_adaptive() -> bool:
	return true

func _ready():
	material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_setup_shader()

func initialize(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	# Defer to ensure shader material is fully ready
	call_deferred("_apply_settings")

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_apply_settings()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	var mat = material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(param, value)
