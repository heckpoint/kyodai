class_name EffectBase
extends RefCounted

var effect_id: String = ""
var layer_id: String = ""
var target_layer_id: String = ""

# Geometry assigned by EffectStack's ordered geometry pass. Most effects use
# the shared MediaContainer directly; geometric primitives and inset-aware
# effects consume these per-layer values.
var layer_inset_pixels: float = 0.0
var stroke_offset_pixels: float = 0.0
var stroke_width_pixels: float = 0.0

var _settings: Dictionary = {}
var media_container: MediaContainer = null

var effect_stack: EffectStack = null


var _canvas_item_rid: RID = RID()
var _last_parent_rid: RID = RID()
var _material: ShaderMaterial = null
var _visible: bool = true
var _z_index: int = 0
var _content_transform: Transform2D = Transform2D.IDENTITY

var _last_offset_rect: Rect2 = Rect2()

var _shader_params_dirty: bool = false

static var _fallback_texture: Texture2D = null

# Shared ShaderMaterials for effects whose uniforms are identical across cards
# (pure-SDF effects: border, drop_shadow, gradient_overlay). Keyed by
# effect_id + settings + geometry; only used in the static "base_card" context.
static var _shared_materials: Dictionary = {}
const MAX_SHARED_MATERIALS: int = 64

# Shared 256x1 gradient ramp textures, keyed by gradient content (insertion-ordered LRU)
static var _gradient_texture_cache: Dictionary = {}
const MAX_GRADIENT_TEXTURES: int = 32

static func gradient_content_hash(gradient: Gradient) -> String:
	var h := ""
	for i in range(gradient.get_point_count()):
		h += str(gradient.get_offset(i)) + ":" + gradient.get_color(i).to_html() + ";"
	return h

# Resolves a gradient angle in degrees (0 = up, clockwise). Falls back to the
# legacy "gradient_direction" enum (0 = Horizontal, 1 = Vertical, 2 = Diagonal)
# when the new angle key is absent, so old saved settings keep working.
static func get_gradient_angle(settings: Dictionary, angle_key: String, legacy_direction: Variant = null) -> float:
	if settings.has(angle_key):
		return float(settings[angle_key])
	if legacy_direction == null:
		legacy_direction = settings.get("gradient_direction")
	if legacy_direction is int or legacy_direction is float:
		match int(legacy_direction):
			1: return 180.0
			2: return 135.0
	return 90.0

static func get_shared_gradient_texture(gradient: Gradient) -> ImageTexture:
	if gradient == null:
		return null
	var key := gradient_content_hash(gradient)
	if _gradient_texture_cache.has(key):
		var cached_tex = _gradient_texture_cache[key]
		_gradient_texture_cache.erase(key)
		_gradient_texture_cache[key] = cached_tex
		return cached_tex
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in range(256):
		image.set_pixel(i, 0, gradient.sample(i / 255.0))
	var tex = ImageTexture.create_from_image(image)
	_gradient_texture_cache[key] = tex
	while _gradient_texture_cache.size() > MAX_GRADIENT_TEXTURES:
		_gradient_texture_cache.erase(_gradient_texture_cache.keys()[0])
	return tex

static func clear_shared_caches() -> void:
	_shared_materials.clear()
	_gradient_texture_cache.clear()

static func is_material_shareable() -> bool:
	return false

## Geometry-only layers (Inset) modify later geometry without drawing a canvas
## item of their own.
static func is_geometry_only() -> bool:
	return false

## Whether EffectThemeAdapter converts this effect's settings when dark mode
## toggles. Theme-independent effects — shine's highlight band, which must
## stay bright on any background — override this to return false; their
## settings then stay identical in both modes and never gain mode caches.
static func is_theme_adaptive() -> bool:
	return true

static func get_fallback_texture() -> Texture2D:
	if _fallback_texture == null:
		var img = Image.create(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(M3Theme.get_elevation_surface(5))
		_fallback_texture = ImageTexture.create_from_image(img)
	return _fallback_texture

func _init():
	_material = ShaderMaterial.new()
	_setup_shader()

func free_rid() -> void:
	if media_container and media_container.changed.is_connected(_on_media_changed):
		media_container.changed.disconnect(_on_media_changed)
	media_container = null
	effect_stack = null

	if _canvas_item_rid.is_valid():
		RenderingServer.free_rid(_canvas_item_rid)
		_canvas_item_rid = RID()
	_material = null
	_last_offset_rect = Rect2()
	_last_parent_rid = RID()
	_content_transform = Transform2D.IDENTITY

func ensure_canvas_item(parent_rid: RID) -> RID:
	if not _canvas_item_rid.is_valid():
		_canvas_item_rid = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_material(_canvas_item_rid, _material.get_rid())
		RenderingServer.canvas_item_set_draw_index(_canvas_item_rid, _z_index)
	if parent_rid.is_valid() and not _last_parent_rid == parent_rid:
		_last_parent_rid = parent_rid
		RenderingServer.canvas_item_set_parent(_canvas_item_rid, parent_rid)
	return _canvas_item_rid

func set_parent_rid(parent_rid: RID) -> void:
	ensure_canvas_item(parent_rid)

## Media-local source transform supplied by EffectStack. Shaders that sample
## the cover apply this to texture coordinates; draw geometry never moves.
func set_content_transform(value: Transform2D) -> void:
	if _content_transform == value:
		return
	_content_transform = value
	_set_shader_param("source_transform_x", value.x)
	_set_shader_param("source_transform_y", value.y)
	_set_shader_param("source_transform_origin", value.origin)
	_set_shader_param("source_transform_active", 0 if value == Transform2D.IDENTITY else 1)

func set_z_index(value: int) -> void:
	_z_index = value
	if _canvas_item_rid.is_valid():
		RenderingServer.canvas_item_set_draw_index(_canvas_item_rid, value)

## Overrides the texture sampling filter for this effect's canvas item. Only
## affects shaders whose samplers use filter_default (e.g. base_card).
func set_texture_filter(filter: RenderingServer.CanvasItemTextureFilter) -> void:
	ensure_canvas_item(RID())
	RenderingServer.canvas_item_set_default_texture_filter(_canvas_item_rid, filter)

func set_visible(value: bool) -> void:
	_visible = value
	if _canvas_item_rid.is_valid():
		RenderingServer.canvas_item_set_visible(_canvas_item_rid, value)

func is_visible() -> bool:
	return _visible

func set_offset_rect(rect: Rect2) -> void:
	if _last_offset_rect == rect:
		return
	_last_offset_rect = rect
	ensure_canvas_item(RID())
	RenderingServer.canvas_item_clear(_canvas_item_rid)
	# Add the visible rect used by the shader. We also draw a tiny placeholder
	# rect when collapsed to keep the canvas item valid for transforms.
	var draw_rect := rect
	if draw_rect.size.x <= 0.0 or draw_rect.size.y <= 0.0:
		draw_rect = Rect2(Vector2.ZERO, Vector2(1, 1))
	RenderingServer.canvas_item_add_rect(_canvas_item_rid, draw_rect, Color.WHITE)
	RenderingServer.canvas_item_set_visible(_canvas_item_rid, _visible)

var _base_settings: Dictionary = {}

func rebind_media_container(container: MediaContainer) -> void:
	if media_container == container:
		return
	if media_container and media_container.changed.is_connected(_on_media_changed):
		media_container.changed.disconnect(_on_media_changed)
	media_container = container
	_apply_settings()
	if media_container:
		media_container.changed.connect(_on_media_changed)
	_mark_shader_params_dirty()

func initialize(container: MediaContainer, settings: Dictionary) -> void:
	if media_container and media_container.changed.is_connected(_on_media_changed):
		media_container.changed.disconnect(_on_media_changed)

	media_container = container
	_settings = settings.duplicate()
	_base_settings = settings.duplicate()
	_tweenable_cache_valid = false
	_setup_shader()
	_apply_settings()
	if media_container:
		media_container.changed.connect(_on_media_changed)
	_update_shader_params()

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_base_settings = settings.duplicate()
	_tweenable_cache_valid = false
	_apply_settings()
	_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []

var _tweenable_cache: Array[String] = []
var _tweenable_cache_valid: bool = false

func get_tweenable_settings() -> Array[String]:
	if _tweenable_cache_valid:
		return _tweenable_cache
	var tweenable: Array[String] = []
	var schema = get_settings_schema()

	for setting in schema:
		if setting.type == SettingsVar.SettingType.FLOAT or \
		   setting.type == SettingsVar.SettingType.INT or \
		   setting.type == SettingsVar.SettingType.VECTOR2 or \
		   setting.type == SettingsVar.SettingType.COLOR:
			tweenable.append(setting.property_name)

	_tweenable_cache = tweenable
	_tweenable_cache_valid = true
	return _tweenable_cache

var _is_tweening: bool = false

func tween_settings(from_settings: Dictionary, to_settings: Dictionary, progress: float) -> void:
	var tweenables = get_tweenable_settings()

	_is_tweening = true

	var temp_settings = _settings.duplicate()

	for setting_name in tweenables:
		if from_settings.has(setting_name) and to_settings.has(setting_name):
			var from_val = from_settings[setting_name]
			var to_val = to_settings[setting_name]
			temp_settings[setting_name] = _interpolate_value(from_val, to_val, progress)

	_apply_tweened_settings(temp_settings)

	if progress >= 1.0:
		# Snap to the exact target settings so non-tweenable parameters don't
		# linger with stale values from the starting configuration.
		_settings = to_settings.duplicate(true)
		_apply_settings()
		_update_shader_params()
		_is_tweening = false
		_complete_tween_if_pending()

func _interpolate_value(from_val: Variant, to_val: Variant, progress: float) -> Variant:
	var from_type = typeof(from_val)
	var to_type = typeof(to_val)

	if (from_type == TYPE_FLOAT or from_type == TYPE_INT) and (to_type == TYPE_FLOAT or to_type == TYPE_INT):
		return lerpf(float(from_val), float(to_val), progress)
	elif from_val is Color and to_val is Color:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector2 and to_val is Vector2:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector3 and to_val is Vector3:
		return from_val.lerp(to_val, progress)
	else:
		return to_val if progress >= 0.5 else from_val

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _apply_tweened_settings(temp_settings: Dictionary) -> void:
	# Tweened values become the active visual state. We intentionally do NOT
	# restore the original _settings afterwards; otherwise shader params and
	# geometry can snap back to base values while the card is still focused,
	# causing effects like glow to misalign.
	_settings = temp_settings
	_apply_settings()

	# Push interpolated values to the shader while _settings holds the tweened
	# values. Without this, effects like glow keep their base uniforms during
	# the focus tween and scale from the wrong size/center.
	_update_shader_params()

	if media_container:
		var needs_refresh = false
		match effect_id:
			"stroke", "inset", "transform":
				# Geometry is derived from the ordered stack, so focus tweens must
				# recompute layer depths and the final media aperture.
				needs_refresh = true
			"glow", "drop_shadow":
				# These effects change their canvas draw rect with their settings,
				# so refresh geometry during the tween to keep alignment.
				needs_refresh = true

		if needs_refresh and effect_stack:
			effect_stack.request_refresh()

func _update_shader_params() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	if not _material:
		return
	if param == "game_texture" and (value == null or not value is Texture2D):
		_material.set_shader_parameter(param, get_fallback_texture())
		return
	_material.set_shader_parameter(param, value)

var _material_share_key: String = ""

## Re-points _material at the shared material for this effect's current
## settings+geometry. Called at the top of _update_shader_params by shareable
## effects. Only shares in the "base_card" stack context; focus/hero contexts
## tween per-card uniforms and always get a unique material.
func _ensure_shared_material() -> void:
	if not is_material_shareable():
		return
	var shareable_here = effect_stack != null and effect_stack._context == "base_card" and not _is_tweening
	var key := ""
	if shareable_here:
		key = _compute_material_share_key()
	if key == _material_share_key:
		return
	_material_share_key = key
	if key == "":
		_material = ShaderMaterial.new()
	else:
		var mat: ShaderMaterial = _shared_materials.get(key, null)
		if mat:
			# Insertion-ordered dict: erase+re-set refreshes recency.
			_shared_materials.erase(key)
			_shared_materials[key] = mat
		else:
			# Evict only the oldest entries; clearing the whole dict here
			# forced every visible card to rebuild (and recompile) at once.
			while _shared_materials.size() >= MAX_SHARED_MATERIALS:
				_shared_materials.erase(_shared_materials.keys()[0])
			mat = ShaderMaterial.new()
			_shared_materials[key] = mat
		_material = mat
	_setup_shader()
	if _canvas_item_rid.is_valid():
		RenderingServer.canvas_item_set_material(_canvas_item_rid, _material.get_rid())

func _compute_material_share_key() -> String:
	var parts: Array[String] = [effect_id]
	var keys = _settings.keys()
	keys.sort()
	for k in keys:
		var v = _settings[k]
		if v is Gradient:
			parts.append(str(k) + "=" + gradient_content_hash(v))
		else:
			parts.append(str(k) + "=" + str(v))
	if media_container:
		# The key must match the actual uniforms exactly. Rounded keys with
		# unrounded uniforms can make different cards overwrite shared geometry.
		parts.append(str(media_container.size))
		parts.append(str(media_container.get_corner_radius_pixels()))
		parts.append(str(media_container.get_total_inset_pixels()))
		parts.append(str(layer_inset_pixels))
		parts.append(str(stroke_offset_pixels))
		parts.append(str(stroke_width_pixels))
		parts.append(str(media_container.edge_aa_enabled))
	return "|".join(parts)

func _on_media_changed() -> void:
	if _is_tweening:
		# Defer rather than drop: re-mark when the tween finishes so media
		# changes that land mid-tween are not lost.
		if not _media_changed_pending:
			_media_changed_pending = true
		return
	_mark_shader_params_dirty()

var _media_changed_pending: bool = false

func _complete_tween_if_pending() -> void:
	if _media_changed_pending:
		_media_changed_pending = false
		_mark_shader_params_dirty()

func _mark_shader_params_dirty() -> void:
	if _shader_params_dirty:
		return
	_shader_params_dirty = true
	call_deferred("_flush_shader_params")

func _flush_shader_params() -> void:
	if not is_instance_valid(self):
		return
	if not _shader_params_dirty:
		# A direct update (e.g. EffectStack._run_pipeline during a resize
		# rebuild) already pushed the params after this flush was queued.
		return
	_shader_params_dirty = false
	_update_shader_params()

func set_alpha(value: float) -> void:
	_set_shader_param("alpha", value)

func set_effect_alpha(value: float) -> void:
	_set_shader_param("effect_alpha", value)
