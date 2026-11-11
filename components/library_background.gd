class_name LibraryBackground
extends Control

## Ordered background composition: the M3 surface color at the bottom, then a
## single stack of strict BackgroundEffect layers and compatible shared effects.
## Config order is draw order, including interleaved effect types.

const EFFECT_REGISTRY: Dictionary = {
	"gradient": "res://effects/background/gradient_background_effect.gd",
	"gradient_flow": "res://effects/background/gradient_flow_background_effect.gd",
	"xmb": "res://effects/background/xmb_background_effect.gd",
	"xmb_classic": "res://effects/background/xmb_classic_background_effect.gd",
	"motes": "res://effects/background/motes_background_effect.gd",
	"osdsys": "res://effects/background/osdsys_background_effect.gd",
	"cafeos": "res://effects/background/cafeos_background_effect.gd",
	"isolines": "res://effects/background/isolines_background_effect.gd",
	"dotgrid": "res://effects/background/dotgrid_background_effect.gd",
	"horizon3d": "res://effects/background/horizon3d_background_effect.gd",
	"hero_art": "res://effects/background/hero_art_background_effect.gd",
}

const EFFECT_DISPLAY_NAMES: Dictionary = {
	"gradient": "Gradient",
	"gradient_flow": "Gradient Flow",
	"xmb": "XMB",
	"xmb_classic": "XMB (Classic)",
	"motes": "Motes",
	"osdsys": "OSDSYS",
	"cafeos": "CafeOS",
	"isolines": "Isolines",
	"dotgrid": "Dot Grid",
	"horizon3d": "Horizon3D",
	"hero_art": "Hero Artwork",
}

## Shared effects currently known to work in the background's full-surface
## media context. Card-only effects are not exposed here.
const OVERLAY_REGISTRY: Dictionary = {
	"gradient_overlay": "res://effects/shared/gradient_overlay_effect.gd",
}

const LAYER_BACKGROUND := "background"
const LAYER_SHARED := "shared"

var _config: Dictionary = {}
var _base_rect: ColorRect = null

# One ordered stack: [{entry, kind, node, viewport, effect, media, draw_index}].
var _layers: Array = []

func _ready():
	_initialize_background()
	resized.connect(_on_resized)

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_update_layer_viewport_activity()
	elif what == NOTIFICATION_PREDELETE:
		_clear_layers()

func _update_layer_viewport_activity() -> void:
	"""Pause scaled background SubViewports when the background itself is hidden
	(e.g. dual-screen reparent, resize-gesture freeze, tab teardown)."""
	var active := is_visible_in_tree()
	for layer in _layers:
		if layer.viewport:
			layer.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED

func _on_resized() -> void:
	for layer in _layers:
		if layer.kind == LAYER_BACKGROUND:
			if layer.viewport:
				layer.viewport.size = _get_scaled_effect_size(layer.node)
				layer.node.size = Vector2(layer.viewport.size)
			else:
				layer.node.size = size
		else:
			layer.media.bounds = Rect2(Vector2.ZERO, size)
			layer.effect.set_offset_rect(Rect2(Vector2.ZERO, size))
			layer.effect.update_settings(layer.entry.get("settings", {}))

func _get_scaled_effect_size(effect: BackgroundEffect) -> Vector2i:
	var scale_factor = effect.render_scale if effect else 1.0
	return Vector2i(maxi(1, int(size.x * scale_factor)), maxi(1, int(size.y * scale_factor)))

func _initialize_background() -> void:
	if DataManager:
		var config_setting = DataManager.get_setting("library_background_config")
		if config_setting and config_setting.value is Dictionary:
			_config = normalize_config(config_setting.value)
	if _config.is_empty():
		_config = _empty_config()
	_apply_background_state(true)

static func _empty_config() -> Dictionary:
	return {"effects": []}

static func normalize_config(config: Dictionary) -> Dictionary:
	## Single ordered stack. Legacy overlays are appended after legacy background
	## layers, matching the old renderer's guaranteed draw order. The legacy key
	## is omitted from the result so normalization cannot migrate it twice.
	var out := _empty_config()
	if config.get("effects") is Array:
		out["effects"] = config["effects"].duplicate(true)
	if config.get("overlays") is Array:
		out["effects"].append_array(config["overlays"].duplicate(true))
	return out

func _apply_background_state(full_rebuild: bool) -> void:
	if full_rebuild:
		_clear_layers()
		_build_base()
		_build_layers()
	else:
		# Re-zip entries from the fresh config: normalize_config deep-duplicates
		# on every call, so stored entries would otherwise go stale. Identical
		# signatures guarantee the same IDs and order, so index matching is safe.
		var effects: Array = _config.get("effects", [])
		for i in range(_layers.size()):
			if i < effects.size():
				_layers[i].entry = effects[i]
			if _layers[i].kind == LAYER_BACKGROUND:
				_layers[i].node.update_settings(_layers[i].entry.get("settings", {}))
			else:
				_layers[i].effect.update_settings(_layers[i].entry.get("settings", {}))

func _clear_layers() -> void:
	for layer in _layers:
		if is_instance_valid(layer.node):
			layer.node.queue_free()
		if is_instance_valid(layer.viewport):
			layer.viewport.queue_free()
		if is_instance_valid(layer.effect):
			layer.effect.free_rid()
	_layers.clear()
	if _base_rect:
		_base_rect.queue_free()
		_base_rect = null

func _build_base() -> void:
	_base_rect = ColorRect.new()
	_base_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_base_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_rect.z_index = 0
	add_child(_base_rect)
	move_child(_base_rect, 0)
	refresh_theme()

## Re-applies the M3 base color. ThemeSubManager's tree walk calls this on
## dark-mode toggles, seed-color changes, and preset switches.
func refresh_theme() -> void:
	if _base_rect:
		_base_rect.color = M3Theme.get_surface_container_low()

func _build_layers() -> void:
	var effects: Array = _config.get("effects", [])
	for i in range(effects.size()):
		var entry = effects[i]
		if not entry is Dictionary:
			continue
		var draw_index := i + 1  # The base surface stays at index zero.
		var background_effect := EffectRegistry.create_background_effect(entry.get("effect_id", ""))
		if background_effect:
			_build_background_layer(entry, background_effect, draw_index)
		else:
			_build_shared_layer(entry, draw_index)

func _build_background_layer(entry: Dictionary, effect: BackgroundEffect, draw_index: int) -> void:
	if effect.render_scale < 1.0:
		# GPU-heavy effect: render into a scaled-down SubViewport (transparent
		# so layers beneath show through) and stretch it back to full size.
		var viewport := SubViewport.new()
		viewport.size = _get_scaled_effect_size(effect)
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.add_child(effect)
		effect.position = Vector2.ZERO
		effect.size = Vector2(viewport.size)
		effect.visible = true
		effect.initialize(entry.get("settings", {}))
		var container := SubViewportContainer.new()
		container.stretch = true
		container.set_anchors_preset(Control.PRESET_FULL_RECT)
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.z_index = draw_index
		add_child(container)
		container.add_child(viewport)
		_layers.append({
			"entry": entry, "kind": LAYER_BACKGROUND, "node": effect,
			"viewport": viewport, "effect": null, "media": null, "draw_index": draw_index,
		})
	else:
		effect.z_index = draw_index
		add_child(effect)
		effect.position = Vector2.ZERO
		effect.size = size
		effect.visible = true
		effect.initialize(entry.get("settings", {}))
		_layers.append({
			"entry": entry, "kind": LAYER_BACKGROUND, "node": effect,
			"viewport": null, "effect": null, "media": null, "draw_index": draw_index,
		})

func _build_shared_layer(entry: Dictionary, draw_index: int) -> void:
	var script_path: String = OVERLAY_REGISTRY.get(entry.get("effect_id", ""), "")
	if script_path.is_empty():
		return
	var script = load(script_path)
	if not script:
		return
	var effect: EffectBase = script.new()
	if not effect:
		return
	var media := MediaContainer.new()
	media.bounds = Rect2(Vector2.ZERO, size)
	media.corner_radius_ratio = 0.0
	effect.initialize(media, entry.get("settings", {}))
	effect.ensure_canvas_item(get_canvas_item())
	effect.set_z_index(draw_index)
	effect.set_offset_rect(Rect2(Vector2.ZERO, size))
	_layers.append({
		"entry": entry, "kind": LAYER_SHARED, "node": null,
		"viewport": null, "effect": effect, "media": media, "draw_index": draw_index,
	})

# Public API for updating background configuration
func set_background_config(config: Dictionary) -> void:
	var normalized := normalize_config(config)
	var rebuild := _config_signature(_config) != _config_signature(normalized)
	_config = normalized
	_apply_background_state(rebuild)

func get_background_config() -> Dictionary:
	return _config.duplicate(true)

func _config_signature(config: Dictionary) -> String:
	# Rebuild only when the ordered set of IDs changes; settings-only changes
	# take the cheaper update path, including reordered duplicates.
	var parts: Array[String] = []
	for entry in config.get("effects", []):
		if entry is Dictionary:
			parts.append(entry.get("effect_id", ""))
	return ",".join(parts)

static func get_designer_registry() -> Dictionary:
	var registry := EFFECT_REGISTRY.duplicate()
	registry.merge(OVERLAY_REGISTRY, true)
	return registry

# Get available effect IDs for dropdowns/designers
static func get_available_effects() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(get_designer_registry().keys())
	for descriptor in EffectRegistry.get_custom_descriptors("background"):
		var custom_id: String = descriptor.get("id", "")
		if custom_id != "" and not ids.has(custom_id):
			ids.append(custom_id)
	return ids

static func get_effect_display_name(effect_id: String) -> String:
	if EffectRegistry.is_custom(effect_id):
		return EffectRegistry.get_display_name(effect_id)
	return EFFECT_DISPLAY_NAMES.get(effect_id, effect_id.replace("_", " ").capitalize())

# Get settings schema for an effect
static func get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	if EffectRegistry.is_custom(effect_id):
		return EffectRegistry.get_schema(effect_id)
	var script_path: String = EFFECT_REGISTRY.get(effect_id, OVERLAY_REGISTRY.get(effect_id, ""))
	if script_path.is_empty():
		return []
	var script = load(script_path)
	if not script:
		return []
	var effect = script.new()
	var schema: Array[SettingsVar] = effect.get_settings_schema()
	if effect is Node:
		effect.free()
	else:
		effect.free_rid()
	return schema
