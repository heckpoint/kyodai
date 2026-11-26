class_name EffectStack
extends RefCounted

## Ordered composition stack. Configured overlays are instances, not entries in
## a type-keyed map: their array order is their composition order and layer_id
## is their stable identity for focus overrides.

var media_container: MediaContainer
var _effect_configs: Array = []
var _context: String = "base_card"

var _parent_rid: RID = RID()
var _stack_canvas_item: RID = RID()
var _visible: bool = true
var _refresh_pending: bool = false
var _compositor: EffectCompositor = null
var _compositor_enabled: bool = false
var _compositor_host: CanvasItem = null

var _base_layer: Dictionary = {}
var _layers: Array[Dictionary] = []

const EFFECT_REGISTRY: Dictionary = {
	"base": "res://effects/shared/base_card_effect.gd",
	"stroke": "res://effects/shared/stroke_effect.gd",
	"inset": "res://effects/shared/inset_effect.gd",
	"badge": "res://effects/shared/badge_effect.gd",
	"drop_shadow": "res://effects/shared/drop_shadow_effect.gd",
	"glow": "res://effects/shared/glow_effect.gd",
	"glass": "res://effects/shared/glass_effect.gd",
	"distort": "res://effects/shared/distort_effect.gd",
	"transform": "res://effects/shared/transform_effect.gd",
	"gradient_overlay": "res://effects/shared/gradient_overlay_effect.gd",
	"case_wrap": "res://effects/shared/case_wrap_effect.gd",
	"hsl": "res://effects/shared/hsl_effect.gd",
	"blur": "res://effects/shared/blur_effect.gd",
	"shine": "res://effects/shared/shine_effect.gd",
}

func free_rids() -> void:
	if not _base_layer.is_empty():
		var base_effect: EffectBase = _base_layer.get("effect")
		if is_instance_valid(base_effect):
			base_effect.free_rid()
	_base_layer.clear()
	for layer in _layers:
		var effect: EffectBase = layer.get("effect")
		if is_instance_valid(effect):
			effect.free_rid()
	_layers.clear()
	if _compositor:
		_compositor.free_rids()
		_compositor = null
		_compositor_host = null
		_compositor_enabled = false
	if _stack_canvas_item.is_valid():
		RenderingServer.free_rid(_stack_canvas_item)
		_stack_canvas_item = RID()

func set_parent_rid(parent_rid: RID) -> void:
	_parent_rid = parent_rid
	_ensure_stack_canvas_item()

func _ensure_stack_canvas_item() -> void:
	if not _stack_canvas_item.is_valid():
		_stack_canvas_item = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_visible(_stack_canvas_item, true)
	if _parent_rid.is_valid():
		RenderingServer.canvas_item_set_parent(_stack_canvas_item, _parent_rid)

func set_clip_children(value: bool) -> void:
	if _stack_canvas_item.is_valid():
		RenderingServer.canvas_item_set_clip(_stack_canvas_item, value)

func set_compositor_enabled(value: bool, host: CanvasItem) -> void:
	if value and not host:
		push_warning("EffectStack: compositor requires a CanvasItem host")
		return
	if value:
		_compositor_host = host
		if not _compositor:
			_compositor = EffectCompositor.new()
		_compositor.attach(host)
	_compositor_enabled = value
	if _compositor:
		_compositor.set_visible(value)
	_update_effect_draw_rects()

func is_compositor_enabled() -> bool:
	return _compositor_enabled

func sync_compositor(transform: Transform2D, parent_rid: RID, draw_index: int) -> void:
	if _compositor_enabled and _compositor:
		_compositor.sync(transform, parent_rid, media_container.size, media_container.get_corner_radius_pixels(), draw_index)

func get_composition_parent_rid(fallback: RID) -> RID:
	if _compositor_enabled and _compositor:
		return _compositor.get_canvas_item()
	return fallback

func has_multiple_interior_layers() -> bool:
	var count := 0
	for effect in get_effects():
		if effect and effect.is_visible() and not effect.is_geometry_only() and not _is_exterior(effect):
			count += 1
	return count > 1

func _is_exterior(effect: EffectBase) -> bool:
	return effect.effect_id in ["glow", "drop_shadow"]

func _is_media_transformable(effect: EffectBase) -> bool:
	# Only source-image processors participate. Glass, strokes, badges, glows,
	# and other overlays remain fixed at the card's original geometry.
	return effect.effect_id in ["distort", "hsl", "blur"]

func set_draw_index(idx: int) -> void:
	_ensure_stack_canvas_item()
	RenderingServer.canvas_item_set_draw_index(_stack_canvas_item, idx)

func set_visible(value: bool) -> void:
	_visible = value
	if _stack_canvas_item.is_valid():
		RenderingServer.canvas_item_set_visible(_stack_canvas_item, value)
	if _compositor:
		_compositor.set_visible(value)

func is_visible() -> bool:
	return _visible

func initialize(container: MediaContainer, effect_configs: Array, context: String = "base_card") -> void:
	if media_container != container:
		for effect in get_effects():
			if effect:
				effect.rebind_media_container(container)
	media_container = container
	_effect_configs = _clone_effect_configs(effect_configs)
	_context = context
	_reconcile_layers()

func update_effect_configs(effect_configs: Array) -> void:
	_effect_configs = _clone_effect_configs(effect_configs)
	_reconcile_layers()

func set_game_texture(texture: Texture2D) -> void:
	if media_container and media_container.texture == texture:
		return
	if media_container:
		media_container.texture = texture
	for effect in get_effects():
		if effect:
			effect._mark_shader_params_dirty()

func set_loading(value: bool) -> void:
	if media_container:
		media_container.loading_active = value

func _ensure_base_layer() -> void:
	if not _base_layer.is_empty():
		return
	var effect := _create_effect("base")
	if not effect:
		return
	effect.effect_stack = self
	effect.layer_id = "base"
	effect.initialize(media_container, {})
	effect.set_z_index(0)
	_base_layer = {"layer_id": "base", "effect": effect}

func _reconcile_layers() -> void:
	_ensure_base_layer()
	var previous: Dictionary = {}
	for layer in _layers:
		var old_id: String = layer.get("layer_id", "")
		if previous.has(old_id):
			# Duplicate identities are never reusable targets. Free the later
			# duplicate instead of leaking it through the keyed lookup.
			var duplicate: EffectBase = layer.get("effect")
			if is_instance_valid(duplicate):
				duplicate.free_rid()
		else:
			previous[old_id] = layer

	var next_layers: Array[Dictionary] = []
	var used_layer_ids: Dictionary = {}
	for i in range(_effect_configs.size()):
		var config: Dictionary = _effect_configs[i]
		var effect_id: String = config.get("effect_id", "")
		if effect_id == "base" or not EffectRegistry.card_effect_exists(effect_id):
			continue
		var layer_id: String = config.get("layer_id", "")
		var needs_new_identity := layer_id.is_empty() or used_layer_ids.has(layer_id)
		if needs_new_identity:
			var base_id := "%s_%d" % [effect_id, i]
			layer_id = base_id
			var suffix := 1
			while used_layer_ids.has(layer_id):
				layer_id = "%s_%d" % [base_id, suffix]
				suffix += 1
			config["layer_id"] = layer_id

		var layer: Dictionary = {} if needs_new_identity else previous.get(layer_id, {})
		var effect: EffectBase = layer.get("effect") if not layer.is_empty() else null
		if effect and effect.effect_id != effect_id:
			effect.free_rid()
			effect = null
			layer = {}
		if not effect:
			effect = _create_effect(effect_id)
			if not effect:
				continue
			var allowed_contexts = effect.get_allowed_contexts()
			if not allowed_contexts.has(_context):
				effect.free_rid()
				continue
			effect.effect_stack = self
			effect.layer_id = layer_id
			effect.target_layer_id = config.get("target_layer_id", "")
			effect.initialize(media_container, config.get("settings", {}))
			layer = {"layer_id": layer_id, "effect": effect}
		else:
			previous.erase(layer_id)
			effect.effect_stack = self
			effect.media_container = media_container
			effect.target_layer_id = config.get("target_layer_id", "")
			effect.update_settings(config.get("settings", {}))
		effect.set_visible(true)
		effect.set_z_index(next_layers.size() + 1)
		layer["layer_id"] = layer_id
		used_layer_ids[layer_id] = true
		next_layers.append(layer)

	for layer in previous.values():
		var effect: EffectBase = layer.get("effect")
		if is_instance_valid(effect):
			effect.free_rid()
	_layers = next_layers
	force_refresh()

func update_draw_rects() -> void:
	_update_effect_draw_rects()

func _update_effect_draw_rects() -> void:
	if not media_container:
		return
	_ensure_stack_canvas_item()
	var base_rect = Rect2(Vector2.ZERO, media_container.size)
	var interior_parent := _stack_canvas_item
	if _compositor_enabled and _compositor:
		interior_parent = _compositor.get_canvas_item()
	if not _base_layer.is_empty():
		var base_effect: EffectBase = _base_layer.get("effect")
		base_effect.set_parent_rid(interior_parent)
		base_effect.set_offset_rect(base_rect)
	for layer in _layers:
		var effect: EffectBase = layer.get("effect")
		if not effect or not effect.is_visible() or effect.is_geometry_only():
			continue
		var draw_rect: Rect2 = base_rect
		if effect.has_method("get_draw_rect"):
			draw_rect = effect.get_draw_rect()
		var parent := _stack_canvas_item if _is_exterior(effect) else interior_parent
		effect.set_parent_rid(parent)
		effect.set_offset_rect(draw_rect)

func _recompute_geometry() -> void:
	if not media_container:
		return
	var depth := 0.0
	var wrap_top := 0.0
	var wrap_left := 0.0
	for layer in _layers:
		var effect: EffectBase = layer.get("effect")
		if not effect:
			continue
		effect.layer_inset_pixels = depth
		if effect is StrokeEffect:
			effect.stroke_offset_pixels = maxf(0.0, depth + effect.get_depth_offset_pixels(media_container.size))
			effect.stroke_width_pixels = effect.get_stroke_width_pixels(media_container.size)
			if effect.advances_content_edge():
				depth = maxf(depth, effect.stroke_offset_pixels + effect.stroke_width_pixels)
		elif effect is InsetEffect:
			depth += effect.get_inset_pixels(media_container.size)
			wrap_top += effect.get_top_inset_pixels(media_container.size)
			wrap_left += effect.get_left_inset_pixels(media_container.size)

	_update_media_transforms()
	# Keep a minimal valid aperture. Unlimited duplicate insets must not produce
	# negative media sizes or NaNs in downstream crop/shader calculations.
	var max_depth := maxf(0.0, minf(media_container.size.x, media_container.size.y) * 0.5 - 0.5)
	depth = clampf(depth, 0.0, max_depth)
	wrap_top = clampf(wrap_top, 0.0, maxf(0.0, media_container.size.y - depth * 2.0 - 0.5))
	wrap_left = clampf(wrap_left, 0.0, maxf(0.0, media_container.size.x - depth * 2.0 - 0.5))
	media_container.content_inset_pixels = depth
	media_container.wrap_inset_top_ratio = wrap_top / maxf(media_container.size.y, 1.0)
	media_container.wrap_inset_left_ratio = wrap_left / maxf(media_container.size.x, 1.0)

func _update_media_transforms() -> void:
	# A Transform applies to media below it, not to the stack/card container.
	# Walk backward so layers above the current boundary keep their own space.
	var transform_below := Transform2D.IDENTITY
	for i in range(_layers.size() - 1, -1, -1):
		var effect: EffectBase = _layers[i].get("effect")
		if not effect:
			continue
		if effect is TransformEffect:
			transform_below = transform_below * effect.get_transform(media_container.size)
		elif _is_media_transformable(effect):
			effect.set_content_transform(transform_below)
		else:
			effect.set_content_transform(Transform2D.IDENTITY)

	if not _base_layer.is_empty():
		var base_effect: EffectBase = _base_layer.get("effect")
		base_effect.set_content_transform(transform_below)

func _run_pipeline() -> void:
	if not media_container:
		return
	_recompute_geometry()
	for effect in get_effects():
		if effect and effect.is_visible():
			effect._shader_params_dirty = false
			effect._update_shader_params()
			if _compositor_enabled and not _is_exterior(effect):
				# Interior cutouts stay hard; the final compositor supplies the
				# only outer coverage after all layers have blended.
				effect._set_shader_param("display_mode", 0)

func get_effects() -> Array:
	var result: Array = []
	if not _base_layer.is_empty():
		result.append(_base_layer.get("effect"))
	for layer in _layers:
		result.append(layer.get("effect"))
	return result

func get_layer(layer_id: String) -> EffectBase:
	if layer_id == "base" and not _base_layer.is_empty():
		return _base_layer.get("effect")
	for layer in _layers:
		if layer.get("layer_id", "") == layer_id:
			return layer.get("effect")
	return null

func get_effect(effect_id: String) -> EffectBase:
	for effect in get_effects():
		if effect and effect.effect_id == effect_id:
			return effect
	return null

func get_effects_of_type(effect_id: String) -> Array[EffectBase]:
	var result: Array[EffectBase] = []
	for effect in get_effects():
		if effect and effect.effect_id == effect_id:
			result.append(effect)
	return result

func _create_effect(effect_id: String) -> EffectBase:
	var effect := EffectRegistry.create_card_effect(effect_id)
	if not effect:
		push_error("EffectStack: Unknown or invalid effect: " + effect_id)
	return effect

static func clear_script_cache() -> void:
	EffectRegistry.clear_script_cache()
	EffectBase.clear_shared_caches()

func request_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	call_deferred("_flush_requested_refresh")

func _flush_requested_refresh() -> void:
	_refresh_pending = false
	force_refresh()

func force_refresh() -> void:
	_update_effect_draw_rects()
	_run_pipeline()

func _clone_effect_configs(configs: Array) -> Array:
	var result: Array = []
	for config in configs:
		if not config is Dictionary:
			continue
		var clone := {"effect_id": config.get("effect_id", "")}
		if config.has("layer_id"):
			clone["layer_id"] = str(config.get("layer_id"))
		if config.has("target_layer_id"):
			clone["target_layer_id"] = str(config.get("target_layer_id"))
		var settings = config.get("settings", {})
		if settings is Dictionary:
			clone["settings"] = settings.duplicate()
		result.append(clone)
	return result
