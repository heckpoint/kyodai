@tool
class_name GameCard
extends M3Card

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

signal download_requested(game: GameResource)
signal game_changed(game: GameResource)

@export var game: GameResource:
	set(value):
		if game == value:
			return
		game = value
		# Per-game placeholder tint, applied the moment the game is assigned
		# (grid's visual-setup path) so the swap to cover art never flashes
		# the neutral gray placeholder.
		_loading_texture = _tinted_placeholder_texture(game.id if game else "")
		game_changed.emit(game)
		_update_texture_pin_state()
		_update_display()

func set_game_with_priority(value: GameResource, high_priority: bool):
	if game == value:
		return
	game = value
	_loading_texture = _tinted_placeholder_texture(game.id if game else "")
	game_changed.emit(game)
	_image_priority_high = high_priority
	_update_texture_pin_state()
	_update_display_with_priority(high_priority)

@export var preview_mode: bool = false

static var _placeholder_theme_key: String = ""
static var _placeholder_texture: Texture2D = _create_placeholder_texture()

## Per-game placeholder color: derived from the game id hash (stable per
## game), quantized to a small hue palette so the tinted 2×2 textures are
## shared. Assigned when the game is set — before any cover arrives — so the
## media panel never flashes neutral gray between placeholder and art, and
## failed art (negative-cache TTL) shows the game's color immediately.
const PLACEHOLDER_HUE_STEPS: int = 24
static var _placeholder_tint_cache: Dictionary = {}  # hue_step -> Texture2D

static func _placeholder_base_color() -> Color:
	return M3Theme.get_elevation_surface(5)

static func _sync_placeholder_theme() -> void:
	# ImageTextures are shared and cannot follow M3Theme automatically. Rebuild
	# the neutral texture and invalidate every tint when the surface palette changes.
	var key := _placeholder_base_color().to_html()
	if key == _placeholder_theme_key:
		return
	_placeholder_theme_key = key
	_placeholder_texture = _create_placeholder_texture()
	_placeholder_tint_cache.clear()

static func placeholder_color_for_id(id: String) -> Color:
	var base := _placeholder_base_color()
	var dark := base.get_luminance() < 0.5
	var step := absi(hash(id)) % PLACEHOLDER_HUE_STEPS
	var value := maxf(base.v, 0.16) if dark else base.v
	var variant := Color.from_hsv(float(step) / PLACEHOLDER_HUE_STEPS, 0.30 if dark else 0.12, value)
	return base.lerp(variant, 0.65)

static func _tinted_placeholder_texture(id: String) -> Texture2D:
	_sync_placeholder_theme()
	if id == "":
		return _placeholder_texture
	var step := absi(hash(id)) % PLACEHOLDER_HUE_STEPS
	var tex: Texture2D = _placeholder_tint_cache.get(step, null)
	if tex == null:
		var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(placeholder_color_for_id(id))
		tex = ImageTexture.create_from_image(img)
		_placeholder_tint_cache[step] = tex
	return tex

static func _create_placeholder_texture() -> Texture2D:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(_placeholder_base_color())
	return ImageTexture.create_from_image(img)

var _loading_texture: Texture2D = _placeholder_texture
var _current_texture: Texture2D = null
var _current_texture_game_id: String = ""
static var _session_texture_cache: Dictionary = {}  # snapshot path -> Texture2D
const SESSION_TEXTURE_CACHE_LIMIT := 4
var _image_priority_high: bool = false
var _pinned_texture_key: String = ""
# Set by CardMediaLoader: true while a cover fetch/decode is genuinely in
# flight (media panel shimmers), false for static blanks (no art, failures).
var _media_loading: bool = false

# Track the last media bounds we refreshed effects against so we can skip
# redundant force_refresh calls during fast scroll/recycling.
var _last_refreshed_media_bounds: Rect2 = Rect2()
# Layout-input signature for _update_media_panel_size's early-out gate.
var _media_layout_sig := PackedFloat32Array()

# Media effect stack rendered inside M3Card's media panel
var _media_stack: EffectStack = null
var _focus_stack: EffectStack = null
var _focus_override_configs: Array = []
var _focus_effect_tweens: Array[Tween] = []

# Focus stack needs its own bounds (full card vs media panel) independent of
# the media stack, which lives in media-panel-local space.
var _focus_media_container: MediaContainer = null

# Present wrap overlay: internal layer above the media stack for
# downloaded-but-never-played games. Unwraps on first focus.
var _present_wrap: PresentWrapEffect = null
var _present_tween: Tween = null
const PRESENT_UNWRAP_DURATION: float = 0.6
const PRESENT_WRAP_DRAW_INDEX: int = 40
const STEAM_NEVER_PLAYED: String = "1970-01-01T00:00:00"

func _remove_focus_tween(tween: Tween) -> void:
	_focus_effect_tweens.erase(tween)

func _kill_focus_tweens() -> void:
	for tween in _focus_effect_tweens:
		if tween and is_instance_valid(tween):
			tween.kill()
	_focus_effect_tweens.clear()

	if _media_stack:
		for effect in _media_stack.get_effects():
			if effect is EffectBase:
				effect._is_tweening = false

# Cover/media loading is delegated to CardMediaLoader so GameCard stays focused
# on card behavior (focus, input, badges) rather than download/cache logic.
var _media_loader: CardMediaLoader = null

var _badge_update_pending: bool = false

# Platform badge icon assets
const PLATFORM_ICON_DIR := "res://assets/icons/platforms"
const PLATFORM_ICON_MAP := {
	"psx": "ps",
	"ps4": "ps4--1",
	"genesis": "genesis-slash-megadrive",
	"tg16": "turbografx16--1",
	"turbografx-cd": "turbografx16--1",
}
static var _platform_icon_cache: Dictionary = {}
static var _platform_icon_missing_warnings: Dictionary = {}
const _MAX_PLATFORM_ICON_WARNINGS: int = 64

static func clear_platform_icon_cache() -> void:
	_platform_icon_cache.clear()
	_platform_icon_missing_warnings.clear()

# Focus
const FOCUS_TWEEN_DURATION: float = 0.12
const FOCUS_EFFECT_FADE_DURATION: float = 0.15
var _focus_tween: Tween = null
var _is_focused: bool = false
var focus_scale: float = 1.08
var focus_scale_enabled: bool = true
# focus_scale_inverted is declared on M3Card: if true, card starts at
# 1.0/focus_scale and grows to 1.0 when focused (LIST/CAROUSEL); if false,
# card starts at 1.0 and grows to focus_scale when focused (GRID).

func _has_real_focus() -> bool:
	# A card is focused if it or any of its descendants currently owns viewport focus.
	var viewport = get_viewport()
	if not viewport:
		return false
	var focus_owner = viewport.gui_get_focus_owner()
	if not focus_owner:
		return false
	return focus_owner == self or is_ancestor_of(focus_owner)

func _sync_focus_state_from_viewport() -> void:
	var real_focus = _has_real_focus()
	if _is_focused == real_focus:
		return
	_is_focused = real_focus
	_sync_focus_visuals()
	_apply_text_settings()
	# If this card is focused but has no focus stack yet, build it now so the
	# subsequent media-stack rebuild can see the correct focus state.
	if _is_focused and not _focus_stack:
		_build_focus_stack()
		_update_platform_badge()
	if _is_focused:
		_try_unwrap_present()

# Android touch-and-hold
const LONG_PRESS_DURATION: float = 0.45
const LONG_PRESS_TOLERANCE_DP: float = 28.0
var _touch_start_time: float = 0.0
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_is_holding: bool = false
var _suppress_next_press: bool = false
# Fires the long-press while the finger is still down (standard UX) instead
# of waiting for release.
var _hold_timer: Timer = null

func _on_rs_items_recreated() -> void:
	# Rebuild the node-less effect stacks as soon as the RenderingServer items
	# are recreated (called from M3Card._enter_tree before _update_media_panel_size).
	# Without this, _has_media_content() returns false during bounds calculation
	# and the card renders with zero-sized media.
	_last_refreshed_media_bounds = Rect2()
	if not _media_stack:
		_build_media_stack()
	if _focus_stack:
		_build_focus_stack()

func _enter_tree():
	super._enter_tree()
	# Cards are pooled: _ready runs once, but snapshot ownership changes on
	# every removal/reinsertion. Reconnect and reapply on every tree entry.
	if LaunchManager and not LaunchManager.session_changed.is_connected(_on_session_changed):
		LaunchManager.session_changed.connect(_on_session_changed)
	call_deferred("_apply_session_snapshot_if_present")
	if not _ready_called:
		return
	# The media stack is rebuilt in _on_rs_items_recreated() before bounds are
	# computed. The code below just reparents/resyncs in case anything changed.
	if _media_stack and _media_canvas_item.is_valid():
		_media_stack.set_parent_rid(_media_canvas_item)
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
	if _focus_stack:
		var focus_parent_rid := _focus_ring_canvas_item if _focus_ring_canvas_item.is_valid() else get_canvas_item()
		_focus_stack.set_parent_rid(focus_parent_rid)
		_update_effect_transforms()
	_update_media()

func _ready():
	# Grid cell geometry is authoritative for GameCards, including media-only
	# and compact-ratio layouts. M3Card's generic 80/240dp minimum would
	# otherwise override the computed cell and collapse the grid to one line.
	enforce_min_height = false
	super._ready()

	# Focus effects need a separate container so their bounds (full card or
	# media panel in card space) don't overwrite the media stack's bounds.
	_focus_media_container = MediaContainer.new()
	_sync_focus_container_properties()

	_sync_focus_visuals()

	_media_loader = CardMediaLoader.new(self)
	_media_loader.texture_loaded.connect(_on_media_texture_loaded)

	if preview_mode:
		_setup_preview_mode()
		return

	_update_card_state_from_settings()
	_update_display()

	# Connect M3Card signals
	pressed.connect(_on_card_pressed)
	gui_input.connect(_on_card_gui_input)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	mouse_entered.connect(_on_card_mouse_entered)

func _has_media_content() -> bool:
	return _media_stack != null

func _exit_tree():
	# Cancel any in-flight image operations to prevent callbacks from keeping this card alive
	if _media_loader:
		_media_loader.cancel()

	# Release the visible-window cache pin so this texture can be evicted.
	if _pinned_texture_key != "" and SystemManager.memory:
		SystemManager.memory.unpin_texture(_pinned_texture_key)
		_pinned_texture_key = ""

	if LaunchManager and LaunchManager.session_changed.is_connected(_on_session_changed):
		LaunchManager.session_changed.disconnect(_on_session_changed)

	# Kill any focus effect tweens
	_kill_focus_tweens()
	_kill_present_tween()

	# Keep the node-less effect stacks allocated while the card is pooled. They
	# are only freed in NOTIFICATION_PREDELETE when the card is truly destroyed.
	super._exit_tree()

func get_card_state() -> MediaContainer:
	return _media_container

func get_current_texture() -> Texture2D:
	return _current_texture

func set_image_priority(high_priority: bool) -> void:
	_image_priority_high = high_priority
	_update_texture_pin_state()
	if _media_loader:
		_media_loader.set_priority(high_priority, game)

## Assign the grid-computed decode bucket (grid card_size × dpr, bucketed).
## Called by the grid's layout pass so live card.size is never a decode basis
## and zoom/resize can't mint duplicate (path, bucket) cache entries.
func set_assigned_decode_bucket(bucket: int) -> void:
	if _media_loader:
		_media_loader.set_assigned_decode_bucket(bucket)

func _update_texture_pin_state() -> void:
	var desired_key := ""
	if _image_priority_high and game and _media_loader:
		desired_key = _media_loader.get_cover_cache_key(game)
	if desired_key == _pinned_texture_key:
		return
	if _pinned_texture_key != "" and SystemManager.memory:
		SystemManager.memory.unpin_texture(_pinned_texture_key)
	_pinned_texture_key = desired_key
	if _pinned_texture_key != "" and SystemManager.memory:
		SystemManager.memory.pin_texture(_pinned_texture_key)

func _setup_preview_mode():
	_update_card_state_from_settings()
	_build_media_stack()

	if DataManager:
		var random_game = DataManager.get_random_game()
		if random_game:
			self.game = random_game
		else:
			_set_texture(_loading_texture)
	else:
		_set_texture(_loading_texture)

	disabled = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Ensure focus effects match preview_show_focus after all setup
	_show_focus_effects(preview_show_focus)

func _build_media_stack():
	if not _media_container:
		return
	var effect_settings := []
	if UIManager and UIManager.card_settings_state:
		effect_settings = UIManager.card_settings_state.get_base_effects()
	elif DataManager:
		# Fallback if UIManager state is not yet available
		var config_setting = DataManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			effect_settings = config_setting.value.get("effects", [])

	if _media_stack:
		# Hot-reload: update configs in-place instead of rebuilding
		_media_stack.update_effect_configs(effect_settings)
		# The media canvas item may have been recreated by a layout change, so
		# always re-parent the existing stack canvas item to the current item.
		if _media_canvas_item.is_valid():
			_media_stack.set_parent_rid(_media_canvas_item)
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		_media_stack.update_draw_rects()
	else:
		_media_stack = EffectStack.new()
		_media_stack.initialize(_media_container, effect_settings, "base_card")
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		if _media_canvas_item.is_valid():
			_media_stack.set_parent_rid(_media_canvas_item)
		# The base card shader handles rounded corners; don't clip on the
		# node-less stack (it has no geometry of its own to clip against).
		_media_stack.set_clip_children(false)
		_media_stack.update_draw_rects()

	_sync_compositor_enabled()

	# Cached cover textures already include mipmaps. Sample them explicitly so
	# shrinking cards and zoom changes filter through the chain instead of
	# minifying only the base image. The silhouette shaders are unaffected.
	var base_effect := _media_stack.get_effect("base")
	if base_effect:
		base_effect.set_texture_filter(RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)

	_update_media()
	_ensure_present_wrap()
	_sync_present_wrap_geometry()

	# Focus stack is built lazily when this card becomes focused (or in preview mode).
	# Only one card is focused at a time, so building the stack for every card is
	# wasted work. The focused card builds its stack immediately in _on_focus_entered
	# or _sync_focus_state_from_viewport.
	# Cards that already have a focus stack (previously focused) still need their
	# configs hot-reloaded so stale settings don't resurface on the next focus.
	if preview_mode or _is_focused or _focus_stack:
		_build_focus_stack()


static func _partition_focus_configs(focus_settings: Array) -> Dictionary:
	var result := {"overrides": [], "overlays": []}
	for entry in focus_settings:
		if entry is Dictionary and not entry.get("target_layer_id", "").is_empty():
			result.overrides.append(entry)
		else:
			result.overlays.append(entry)
	return result

func _build_focus_stack() -> void:
	if not _focus_media_container:
		return
	_kill_focus_tweens()
	_sync_focus_container_properties()

	var focus_effect_settings := []
	if UIManager and UIManager.card_settings_state:
		focus_effect_settings = UIManager.card_settings_state.get_focus_effects()
	elif DataManager:
		# Fallback if UIManager state is not yet available
		var config_setting = DataManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			focus_effect_settings = config_setting.value.get("focus_effects", [])

	# Linked overrides are settings documents, not render layers. Only
	# independent focus additions instantiate a stack or affect its geometry.
	var partition := _partition_focus_configs(focus_effect_settings)
	_focus_override_configs = partition.overrides
	var overlay_settings: Array = partition.overlays

	if focus_effect_settings.is_empty():
		if _focus_stack:
			_focus_stack.update_effect_configs([])
			_focus_stack.set_visible(false)
		return

	if overlay_settings.is_empty():
		if _focus_stack:
			_focus_stack.update_effect_configs([])
			_focus_stack.set_visible(false)
		return

	if _focus_stack:
		# Hot-reload: update configs in-place
		_focus_stack.set_visible(false)
		_focus_stack.update_effect_configs(overlay_settings)

		# Re-apply focus state setup after config update
		var focus_base_node = _focus_stack.get_effect("base")
		if focus_base_node:
			focus_base_node.set_visible(false)
			focus_base_node.set_alpha(0.0)

		# In preview mode, respect preview_show_focus for initial alpha.
		# Otherwise start from zero so _show_focus_effects can tween from the correct state.
		var target_focus_alpha = 1.0 if (preview_mode and preview_show_focus) else 0.0
		for effect in _focus_stack.get_effects():
			if effect is EffectBase:
				effect.set_effect_alpha(target_focus_alpha)

		if preview_mode:
			_focus_stack.set_visible(preview_show_focus)

		if _current_texture:
			_focus_stack.set_game_texture(_current_texture)
		return

	_focus_stack = EffectStack.new()
	# Parent the focus stack to the focus ring canvas item so it moves and scales
	# with the card's unclipped visual transform.
	var focus_parent_rid := _focus_ring_canvas_item if _focus_ring_canvas_item.is_valid() else get_canvas_item()
	_focus_stack.set_parent_rid(focus_parent_rid)
	_focus_stack.set_clip_children(false)
	_focus_stack.set_visible(false)

	_sync_focus_container_properties()
	_focus_stack.initialize(_focus_media_container, overlay_settings, "focus_card")
	_update_effect_transforms()
	_update_focus_stack_bounds()
	if _current_texture:
		_focus_stack.set_game_texture(_current_texture)

	# Hide base effect in focus stack — focus effects are overlays only
	var focus_base = _focus_stack.get_effect("base")
	if focus_base:
		focus_base.set_visible(false)
		focus_base.set_alpha(0.0)

	# Initialize focus effects with effect_alpha based on preview_show_focus
	var focus_alpha = 1.0 if (preview_mode and preview_show_focus) else 0.0
	for effect in _focus_stack.get_effects():
		if effect is EffectBase:
			effect.set_effect_alpha(focus_alpha)

	if preview_mode:
		_focus_stack.set_visible(preview_show_focus)

var preview_show_focus: bool = false

func set_preview_focus(p_show: bool) -> void:
	preview_show_focus = p_show
	_apply_text_settings()
	_show_focus_effects(p_show)

func _show_focus_effects(p_show: bool) -> void:
	_kill_focus_tweens()

	if preview_mode:
		p_show = preview_show_focus
	if not _media_stack:
		return

	# Data-only overrides tween their explicit target. No focus render instance
	# is allocated for these entries, and their type must match the target.
	for config in _focus_override_configs:
		var base_effect := _media_stack.get_layer(config.get("target_layer_id", ""))
		if not base_effect or base_effect.effect_id != config.get("effect_id", ""):
			continue
		var base_copy = base_effect._base_settings.duplicate(true)
		var focus_copy: Dictionary = config.get("settings", {}).duplicate(true)
		var base_effect_ref = weakref(base_effect)
		var settings_tween = create_tween()
		_focus_effect_tweens.append(settings_tween)
		settings_tween.finished.connect(_remove_focus_tween.bind(settings_tween))
		settings_tween.set_trans(Tween.TRANS_QUAD)
		settings_tween.set_ease(Tween.EASE_OUT)
		if p_show:
			settings_tween.tween_method(func(t: float):
				var eff = base_effect_ref.get_ref()
				if eff:
					eff.tween_settings(base_copy, focus_copy, t),
			0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
		else:
			settings_tween.tween_method(func(t: float):
				var eff = base_effect_ref.get_ref()
				if eff:
					eff.tween_settings(eff._settings, base_copy, t),
			0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)

	# Independent focus additions fade as overlays. The auto base and
	# geometry-only layers never participate in these alpha tweens.
	var overlay_effects: Array[EffectBase] = []
	if _focus_stack:
		for effect in _focus_stack.get_effects():
			if effect is EffectBase and effect.layer_id != "base" and not effect.is_geometry_only():
				overlay_effects.append(effect)

	if overlay_effects.is_empty():
		return
	if p_show:
		_focus_stack.set_visible(true)

	for focus_effect in overlay_effects:
		if not focus_effect._material is ShaderMaterial:
			continue
		var start_alpha := float(focus_effect._material.get_shader_parameter("effect_alpha"))
		var target_alpha := 1.0 if p_show else 0.0
		var fade_tween = create_tween()
		_focus_effect_tweens.append(fade_tween)
		fade_tween.finished.connect(_remove_focus_tween.bind(fade_tween))
		fade_tween.set_trans(Tween.TRANS_QUAD)
		fade_tween.set_ease(Tween.EASE_OUT)
		fade_tween.tween_method(
			func(t: float, eff: EffectBase = focus_effect):
				if eff:
					eff.set_effect_alpha(t),
			start_alpha, target_alpha, FOCUS_EFFECT_FADE_DURATION
		)

	if not p_show:
		var hide_tween = create_tween()
		_focus_effect_tweens.append(hide_tween)
		hide_tween.finished.connect(_remove_focus_tween.bind(hide_tween))
		hide_tween.set_trans(Tween.TRANS_QUAD)
		hide_tween.set_ease(Tween.EASE_OUT)
		hide_tween.tween_interval(FOCUS_EFFECT_FADE_DURATION)
		hide_tween.finished.connect(func():
			if _focus_stack:
				_focus_stack.set_visible(false)
		)

var _display_mode: int = 0

func _is_focused_only_enabled() -> bool:
	var state = UIManager.card_settings_state if UIManager else null
	if state:
		return state.text_focused_only
	if DataManager:
		var setting = DataManager.get_setting("library_card_text_focused_only")
		return setting != null and setting.value is bool and setting.value
	return false

## Apply render-only text state. Source strings remain intact so these options
## never change text measurement, media bounds, or recycled-card layout.
func _apply_text_settings() -> void:
	var show_platform := true
	var alignment := 0
	var scroll_truncation := false
	var focused_only := _is_focused_only_enabled()
	var state = UIManager.card_settings_state if UIManager else null
	if state:
		show_platform = state.show_platform
		alignment = state.text_alignment
		scroll_truncation = state.scroll_truncation
	elif DataManager:
		var platform_setting = DataManager.get_setting("library_card_show_platform")
		if platform_setting and platform_setting.value is bool:
			show_platform = platform_setting.value
		var alignment_setting = DataManager.get_setting("library_card_text_alignment")
		if alignment_setting and alignment_setting.value is int:
			alignment = alignment_setting.value
		var scroll_setting = DataManager.get_setting("library_card_scroll_truncation")
		if scroll_setting and scroll_setting.value is bool:
			scroll_truncation = scroll_setting.value

	var focused := preview_show_focus if preview_mode else _is_focused
	text_alignment = clampi(alignment, 0, 3) as M3Card.TextAlignment
	supporting_text_visible = show_platform
	# In Focused Only the title lives in the grid-owned pill, never inline.
	scroll_truncated_text = scroll_truncation and not focused_only
	text_content_visible = not focused_only
	text_focused = focused and not focused_only

## Lightweight entry point for CardSettingsState.ChangeMask.TEXT.
func refresh_text_settings() -> void:
	_apply_text_settings()
	_update_card_text()

func _update_card_state_from_settings():
	if not _media_container:
		return

	var state = UIManager.card_settings_state if UIManager else null
	if state:
		var config = state.card_effect_config
		_media_container.effect_settings = state.get_base_effects()
		_media_container.focus_effect_settings = state.get_focus_effects()

		# Migrate old keys to unified card_rounding
		var config_dict = config.duplicate(true)
		if not config_dict.has("card_rounding"):
			if config_dict.has("art_rounding"):
				config_dict["card_rounding"] = config_dict["art_rounding"]
			elif config_dict.has("corner_radius"):
				config_dict["card_rounding"] = config_dict["corner_radius"]

		var corner_value = config_dict.get("card_rounding", 0.12)
		if corner_value is float and corner_value > 1.0:
			# Backward compat: old configs stored absolute pixels against the 3:4 vertical base width
			const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
			_media_container.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
		else:
			_media_container.corner_radius_ratio = float(corner_value)

		# Apply the same rounding to the M3Card background clip
		card_rounding_ratio = _media_container.corner_radius_ratio

		_display_mode = state.get_effective_display_mode()
	elif DataManager:
		# Fallback if UIManager state is not yet available
		var config_setting = DataManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_media_container.effect_settings = config_setting.value.get("effects", [])
			_media_container.focus_effect_settings = config_setting.value.get("focus_effects", [])
			var config_dict = config_setting.value.duplicate(true)
			if not config_dict.has("card_rounding"):
				if config_dict.has("art_rounding"):
					config_dict["card_rounding"] = config_dict["art_rounding"]
				elif config_dict.has("corner_radius"):
					config_dict["card_rounding"] = config_dict["corner_radius"]
			var corner_value = config_dict.get("card_rounding", 0.12)
			if corner_value > 1.0:
				const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
				_media_container.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
			else:
				_media_container.corner_radius_ratio = corner_value
			card_rounding_ratio = _media_container.corner_radius_ratio
		var display_setting = DataManager.get_setting("library_card_display_mode")
		if display_setting and display_setting.value is int:
			_display_mode = display_setting.value
		if _is_focused_only_enabled():
			_display_mode = 2

	_apply_display_mode()
	_apply_text_settings()
	_sync_focus_container_properties()

func _apply_display_mode() -> void:
	begin_bulk_layout()
	# Every stack layer already shares this outer-edge coverage calculation.
	# Keep it enabled in all display modes so Standard cards don't reintroduce
	# hard SDF cutouts. Inset and border-inner compositing is independent and
	# intentionally unchanged; display mode only controls background and text.
	_media_container.edge_aa_enabled = true
	match _display_mode:
		0: # Standard
			show_background = true
			show_text_margin = true
			text_centered_overlay = false
		1: # Transparent
			show_background = false
			show_text_margin = true
			text_centered_overlay = false
		2: # Media Only
			show_background = false
			# Cover-less games would render as blank unidentifiable panels, so
			# they keep their title, centered over the whole card instead.
			# Wrapped (unopened) games stay textless so the title doesn't draw
			# over the present wrap.
			# Focused Only suppresses the coverless inline fallback as well; the
			# grid's floating pill is the sole title presentation in that mode.
			var no_cover := not _is_focused_only_enabled() and game != null and not game.has_cover_art and not _is_present_wrapped()
			show_text_margin = no_cover
			text_centered_overlay = no_cover

	end_bulk_layout()

	# Update text immediately so shadow state reflects the new display mode
	_update_text()

# Re-evaluates the cover-less title fallback when the game changes on a
# recycled card, without paying for a full _apply_display_mode() when the
# state is unchanged.
func _sync_media_only_text_fallback() -> void:
	if _display_mode != 2 or _is_focused_only_enabled():
		return
	var no_cover := game != null and not game.has_cover_art and not _is_present_wrapped()
	if show_text_margin == no_cover and text_centered_overlay == no_cover:
		return
	_apply_display_mode()

func set_focus_scale(value: float) -> void:
	focus_scale = maxf(value, 1.0)
	_sync_focus_visuals()

func refresh_theme() -> void:
	super.refresh_theme()
	# Keep real cover art untouched; only rebind cards currently displaying the
	# shared loading/no-cover texture. _tinted_placeholder_texture also rebuilds
	# the static cache once when the palette changes.
	var rebind_loading := game != null and not _is_placeholder \
		and (_current_texture == null or _current_texture == _loading_texture)
	_loading_texture = _tinted_placeholder_texture(game.id if game else "")
	if rebind_loading and is_node_ready():
		_set_texture(_loading_texture)

func refresh_settings() -> void:
	_refresh_card_visuals()

func refresh_effects() -> void:
	_refresh_card_visuals()

func _refresh_card_visuals() -> void:
	"""Single card-refresh path: state -> focus sync -> media bounds -> effects ->
	badge/text -> focus tween -> cover safety net."""
	if not _ready_called:
		return
	_update_card_state_from_settings()
	# Sync focus state first so _build_media_stack sees the correct _is_focused
	# and builds the focus stack for focused cards.
	_sync_focus_state_from_viewport()
	_ensure_media_stack_parent()
	# Recompute media bounds before rebuilding the effect stack so effects are
	# created against final geometry instead of stale/zero bounds.
	_update_media_panel_size(true)
	# Hot-reload configs when possible; full rebuild only when the caller forces
	# it or the effect ID set actually changed.
	_build_media_stack()
	_update_platform_badge()
	_update_card_text()
	# Now that both media and focus stacks exist, run the focus tween.
	if _focus_stack:
		_show_focus_effects(_is_focused)
	# If the card has no valid cached texture for the current game, trigger a
	# cover load as a safety net so cards don't stay blank after a rebuild.
	if game and (not _current_texture or _current_texture_game_id != game.id):
		_load_cover(false)

func _sync_compositor_enabled() -> void:
	if not _media_stack:
		return
	if _media_stack.has_multiple_interior_layers():
		_media_stack.set_compositor_enabled(true, self)
	else:
		_media_stack.set_compositor_enabled(false, self)
	_sync_compositor_transform()

func _sync_compositor_transform() -> void:
	if not _media_stack or not _media_stack.is_compositor_enabled():
		return
	var parent := _visual_layer_rid if _uses_visual_layer() else _media_canvas_item
	_media_stack.sync_compositor(_last_media_transform, parent, m3_get_compositor_draw_index())
	_apply_compositor_opacity()

func _apply_visual_layer_opacity() -> void:
	super._apply_visual_layer_opacity()
	_apply_compositor_opacity()

func _apply_compositor_opacity() -> void:
	if not _media_stack or not _media_stack.is_compositor_enabled():
		return
	# The compositor is a sibling of the media canvas item, so it does not
	# inherit the opacity applied to the ordinary media/effect hierarchy.
	var compositor_rid := _media_stack.get_composition_parent_rid(_media_canvas_item)
	if compositor_rid.is_valid():
		# Self modulation fades the composited output without also passing the
		# opacity down to child effects, which would apply the fade twice.
		RenderingServer.canvas_item_set_modulate(compositor_rid, Color.WHITE)
		RenderingServer.canvas_item_set_self_modulate(compositor_rid, Color(1.0, 1.0, 1.0, _visual_layer_opacity))

func sync_visual_transform_with_offset(base_offset: Vector2) -> void:
	super.sync_visual_transform_with_offset(base_offset)
	_sync_compositor_transform()

func _apply_visual_draw_index() -> void:
	super._apply_visual_draw_index()
	_sync_compositor_transform()

func _ensure_media_stack_parent() -> void:
	if _media_stack and _media_canvas_item.is_valid():
		_media_stack.set_parent_rid(_media_canvas_item)

func _update_card_text() -> void:
	if game:
		headline = game.title
		supporting_text = game.platform if game.platform else ""
	else:
		headline = ""
		supporting_text = ""

func reset(for_pooling: bool = false) -> void:
	"""Reset the card for reuse.
	
	when for_pooling is true, we keep the effect stacks and current texture
	allocated so recycled cards don't have to rebuild them from scratch. This
	avoids the empty-card flash when the grid recycles during zoom/resize."""
	game = null
	_is_focused = false
	_reset_text_scroll()
	_apply_text_settings()
	_media_loading = false
	set_placeholder(false)
	# Clear hold state so a recycled card can't fire a stale long-press or
	# carry the press-suppression into its next assignment.
	if _hold_timer:
		_hold_timer.stop()
	_touch_is_holding = false
	_suppress_next_press = false
	# Reset the refresh gate so the next texture load always re-pushes crop UVs.
	_last_refreshed_media_bounds = Rect2()
	set_meta("_cached_show_delete", null)
	if _focus_tween:
		_focus_tween.kill()
		_focus_tween = null
	_kill_focus_tweens()
	_sync_focus_visuals()
	if _media_loader:
		_media_loader.cancel()
	headline = ""
	supporting_text = ""

	if for_pooling:
		# Hide and clear textures but keep stacks allocated for fast reuse.
		# Clear the cached texture so a pooled card never briefly renders the
		# previous game's cover when it's recycled for a different index.
		_current_texture = null
		_current_texture_game_id = ""
		if _media_stack:
			_media_stack.set_loading(false)
			_media_stack.set_game_texture(null)
		if _focus_stack:
			_focus_stack.set_loading(false)
			_focus_stack.set_game_texture(null)
			_focus_stack.set_visible(false)
			# Reset any shader alphas left mid-tween so the next focus-in fades cleanly
			# and a pooled card never enters the grid with focus effects visible.
			for effect in _focus_stack.get_effects():
				if effect is EffectBase and effect._material is ShaderMaterial:
					effect._material.set_shader_parameter("effect_alpha", 0.0)
	else:
		_current_texture = null
		_current_texture_game_id = ""
		if _media_stack:
			_media_stack.set_game_texture(null)
			_media_stack.free_rids()
			_media_stack = null
		if _focus_stack:
			_focus_stack.set_game_texture(null)
			_focus_stack.free_rids()
			_focus_stack = null

## Show the shimmer skeleton while the card has no data yet. The grid calls
## this when a card enters the flow before its game is cached; the media
## loader takes over the loading state once data arrives.
func show_loading_skeleton() -> void:
	if game or _is_placeholder:
		return
	_media_loading = true
	_set_texture(_loading_texture)

func _ensure_present_wrap() -> void:
	if _present_wrap or not _media_container or preview_mode:
		return
	_present_wrap = PresentWrapEffect.new()
	_present_wrap.initialize(_media_container, {})
	_present_wrap.set_visible(false)
	_sync_present_wrap_geometry()

func _sync_present_wrap_geometry() -> void:
	if not _present_wrap:
		return
	if _media_canvas_item.is_valid():
		var parent := _media_stack.get_composition_parent_rid(_media_canvas_item) if _media_stack else _media_canvas_item
		_present_wrap.set_parent_rid(parent)
	_present_wrap.set_z_index(PRESENT_WRAP_DRAW_INDEX)
	_present_wrap.set_offset_rect(Rect2(Vector2.ZERO, _media_container.size))

func _is_present_wrapped() -> bool:
	if preview_mode or not game:
		return false
	if game.unwrapped or not game.is_active_variant_downloaded():
		return false
	var lp: String = game.last_played
	return lp.is_empty() or lp == STEAM_NEVER_PLAYED

func _update_present_wrap() -> void:
	_ensure_present_wrap()
	if not _present_wrap:
		return
	_kill_present_tween()
	var wrapped := _is_present_wrapped()
	if wrapped:
		_present_wrap.set_unwrap_progress(0.0)
		_sync_present_wrap_geometry()
	_present_wrap.set_visible(wrapped)

func _kill_present_tween() -> void:
	if _present_tween and _present_tween.is_valid():
		_present_tween.kill()
	_present_tween = null

func _try_unwrap_present() -> void:
	if not _present_wrap or not _present_wrap.is_visible():
		return
	if not game or game.unwrapped:
		return
	game.unwrapped = true
	_persist_unwrapped()
	# Reveal the Media Only no-cover title now that the wrap is going away.
	_sync_media_only_text_fallback()
	_kill_present_tween()
	var effect := _present_wrap
	_present_tween = create_tween()
	_present_tween.set_trans(Tween.TRANS_QUAD)
	_present_tween.set_ease(Tween.EASE_OUT)
	_present_tween.tween_method(
		func(t: float):
			if is_instance_valid(effect):
				effect.set_unwrap_progress(t),
		0.0, 1.0, PRESENT_UNWRAP_DURATION
	)
	_present_tween.finished.connect(func():
		if is_instance_valid(effect):
			effect.set_visible(false)
	)

func _persist_unwrapped() -> void:
	if game.source == "steam":
		if LaunchManager and LaunchManager.steam:
			LaunchManager.steam.update_unwrapped(game.steam_app_id, true)
	elif DataManager:
		DataManager.update_game_unwrapped(game.romm_id, true)

func set_placeholder(enabled: bool) -> void:
	super.set_placeholder(enabled)
	# Placeholders render only the blank media panel: no effect stacks.
	if _media_stack:
		_media_stack.set_visible(not enabled)
	# The focus stack is only ever re-shown by focus logic; never restore it here.
	if enabled and _focus_stack:
		_focus_stack.set_visible(false)
	if _present_wrap:
		_present_wrap.set_visible(not enabled and _is_present_wrapped())

func _update_display():
	if not game or not is_node_ready():
		return
	_update_platform_badge()
	_update_present_wrap()
	_load_cover(false)
	_update_card_text()
	_sync_media_only_text_fallback()

func _update_display_with_priority(high_priority: bool):
	if not game or not is_node_ready():
		return
	_update_platform_badge()
	_update_present_wrap()
	# If the texture is already cached and the game hasn't changed, reuse it
	# synchronously to avoid the empty-card flash during recycling.
	if _current_texture and _current_texture != _loading_texture and _current_texture_game_id == game.id:
		_set_texture(_current_texture)
	else:
		_load_cover(high_priority)
	_update_card_text()
	_sync_media_only_text_fallback()

func _deferred_update_platform_badge():
	_badge_update_pending = false
	_update_platform_badge()

static func _resolve_platform_icon_name(slug: String) -> String:
	return PLATFORM_ICON_MAP.get(slug, slug)


static func _get_platform_icon_texture(slug: String, is_wordmark: bool) -> Texture2D:
	if slug.is_empty():
		return null

	var filename := _resolve_platform_icon_name(slug)
	var prefix := "wordmark_" if is_wordmark else "icon_"
	var path := PLATFORM_ICON_DIR + "/" + prefix + filename + ".png"

	if _platform_icon_cache.has(path):
		return _platform_icon_cache[path]

	if not ResourceLoader.exists(path):
		return null

	var tex := load(path) as Texture2D
	if tex:
		_platform_icon_cache[path] = tex
	return tex


static func _apply_badge_settings(badge: BadgeEffect, badge_type: int, icon_texture: Texture2D, badge_size_setting: float, inner_radius_setting: float, media_container: MediaContainer) -> void:
	if not badge:
		return

	var card_width = media_container.size.x
	var corner_radius_pixels = media_container.get_corner_radius_pixels()
	var total_inset = media_container.get_total_inset_pixels()
	var effective_corner_radius = max(0, corner_radius_pixels - total_inset)

	var texture_aspect = 1.0
	if icon_texture:
		var tex_size = icon_texture.get_size()
		texture_aspect = tex_size.x / tex_size.y if tex_size.y > 0 else 1.0
		if badge_type != 1:
			texture_aspect = 1.0

	const BADGE_SIZE_RATIO: float = 0.16

	if badge_type == 1:
		var base_badge_size = BADGE_SIZE_RATIO * card_width
		var top_bar_max_size = card_width * 0.25
		var bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		var top_bar_safe_x = total_inset + effective_corner_radius
		var top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		var top_bar_safe_y = total_inset
		var top_bar_safe_height = bar_height

		badge.set_badge_dimensions(Vector2(card_width, bar_height))
		badge.set_border_inset_pixels(total_inset)
		badge.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
	else:
		var raw_badge_size = BADGE_SIZE_RATIO * card_width * badge_size_setting
		var min_badge_size = card_width * 0.15
		var max_badge_size = card_width * 0.45
		var target_badge_size = clamp(raw_badge_size, min_badge_size, max_badge_size)

		var badge_width: float
		var badge_height: float
		if texture_aspect >= 1.0:
			badge_width = target_badge_size * texture_aspect
			badge_height = target_badge_size
		else:
			badge_width = target_badge_size
			badge_height = target_badge_size / texture_aspect

		var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
		var corner_margin = effective_corner_radius * corner_midpoint_factor
		var base_min_dim = min(badge_width, badge_height)
		var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
		var inner_corner_margin = base_inner_corner * corner_midpoint_factor
		var max_corner_margin = badge_width * 0.8
		var clamped_corner_margin = min(corner_margin, max_corner_margin)

		var safe_x = total_inset + clamped_corner_margin
		var safe_y = total_inset + clamped_corner_margin
		var safe_width = max(badge_width - clamped_corner_margin - inner_corner_margin, 0.0)
		var safe_height = max(badge_height - clamped_corner_margin - inner_corner_margin, 0.0)

		badge.set_badge_dimensions(Vector2(badge_width, badge_height))
		badge.set_border_inset_pixels(total_inset)
		badge.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)

	badge.set_icon_texture(icon_texture)


func _update_platform_badge():
	if not _media_stack:
		return

	var normal_badges := _media_stack.get_effects_of_type("badge")
	var focus_badges: Array[EffectBase] = []
	if _focus_stack:
		focus_badges = _focus_stack.get_effects_of_type("badge")
	if normal_badges.is_empty() and focus_badges.is_empty():
		return

	if not game:
		for badge in normal_badges + focus_badges:
			badge.set_icon_texture(null)
		return

	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null

	var badge_config := {}
	for effect_data in _media_container.effect_settings:
		if effect_data is Dictionary and effect_data.get("effect_id") == "badge":
			badge_config = effect_data
			break

	var settings = badge_config.get("settings", {})
	var badge_type = settings.get("badge_type", 0)
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)

	if platform_slug:
		icon_texture = _get_platform_icon_texture(platform_slug, badge_type == 1)

		if not icon_texture and not _platform_icon_missing_warnings.has(platform_slug):
			# Bound the warning cache so repeated unknown slugs can't grow it forever.
			if _platform_icon_missing_warnings.size() >= _MAX_PLATFORM_ICON_WARNINGS:
				_platform_icon_missing_warnings.erase(_platform_icon_missing_warnings.keys()[0])
			_platform_icon_missing_warnings[platform_slug] = true
			push_warning("GameCard: No platform icon found for slug '%s' (looked in %s)" % [platform_slug, PLATFORM_ICON_DIR])

	for badge in normal_badges:
		_apply_badge_settings(badge, badge_type, icon_texture, badge_size_setting, inner_radius_setting, _media_container)
	for badge in focus_badges:
		_apply_badge_settings(badge, badge_type, icon_texture, badge_size_setting, inner_radius_setting, _media_container)

func _load_cover(high_priority: bool = false) -> void:
	if _media_loader:
		_media_loader.load_cover(game, high_priority)
	else:
		_set_texture(_loading_texture)

## Deep memory trim: drop the decoded cover so its texture memory is
## reclaimable. The card swaps to the shared placeholder and stays renderable;
## retry_cover_if_placeholder() re-binds the cover during post-trim restore.
func release_cover() -> void:
	if _current_texture == null or _current_texture == _loading_texture:
		return
	_set_texture(null)

## Nudge for visible cards whose cover fetch was suppressed (fast scroll /
## A-Z scrub) or dropped by queue backpressure: nothing else re-triggers the
## download they skipped, so re-run the load path when suppression lifts.
func retry_cover_if_placeholder() -> void:
	if not game or not _media_loader:
		return
	if _current_texture == null or _current_texture == _loading_texture:
		_media_loader.load_cover(game, true)

func _on_media_texture_loaded(texture: Texture2D) -> void:
	_set_texture(texture)

static func evict_session_snapshot(path: String) -> void:
	if not path.is_empty():
		_session_texture_cache.erase(path)

static func clear_session_texture_cache() -> void:
	_session_texture_cache.clear()

func _apply_session_snapshot_if_present() -> void:
	var snapshot := _session_snapshot_texture()
	if snapshot:
		_set_texture(snapshot)

static func session_texture_for_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _session_texture_cache.has(path):
		return _session_texture_cache[path]
	var bytes := FSM.read_file_bytes(path)
	if bytes.size() < 16:
		return null
	var img := Image.new()
	if img.load_jpg_from_buffer(bytes) != OK or img.is_empty():
		return null
	var texture := ImageTexture.create_from_image(img)
	if _session_texture_cache.size() >= SESSION_TEXTURE_CACHE_LIMIT:
		_session_texture_cache.erase(_session_texture_cache.keys()[0])
	_session_texture_cache[path] = texture
	return texture

func _session_snapshot_texture() -> Texture2D:
	if not game or not LaunchManager:
		return null
	var session: GameSession = LaunchManager.sessions.get_live_for_game(game.romm_id)
	if session == null or session.state != GameSession.State.RETAINED:
		return null
	return session_texture_for_path(str(session.runtime.get("snapshotPath", "")))

func _on_session_changed(session: GameSession) -> void:
	if not game or session.romm_id != game.romm_id:
		return
	var snapshot := _session_snapshot_texture()
	if snapshot:
		_set_texture(snapshot)
	elif session.state != GameSession.State.RETAINED:
		_load_cover(true)
	# While RETAINED with capture still in flight, keep the existing texture;
	# starting another cover download here only adds a stale completion race.

func _set_texture(tex: Texture2D) -> void:
	# Use the placeholder for any null texture so cards never render the default
	# white fallback texture in the shader.
	var resolved_tex: Texture2D = _session_snapshot_texture()
	if resolved_tex == null:
		resolved_tex = tex if tex else _loading_texture
	var is_loading := resolved_tex == _loading_texture and _media_loading
	# Apply the shimmer state even when the texture itself is unchanged (the
	# loader may re-emit the placeholder with a different loading state).
	if _media_stack:
		_media_stack.set_loading(is_loading)
	if _focus_stack:
		_focus_stack.set_loading(is_loading)
	if _current_texture == resolved_tex and _media_stack:
		return
	_current_texture = resolved_tex
	if game:
		_current_texture_game_id = game.id

	# Safety net: if the stack was freed (e.g. pooled card re-entered the tree),
	# rebuild it now so the texture actually has somewhere to render.
	if not _media_stack:
		_build_media_stack()
	if _media_stack:
		_media_stack.set_loading(is_loading)
		_media_stack.set_game_texture(resolved_tex)
		# Only pay for a full force_refresh when the media geometry changed.
		# set_game_texture() already marks shader params dirty, so if bounds are
		# unchanged the deferred flush will push the new texture to the shader.
		if not _media_bounds.is_equal_approx(_last_refreshed_media_bounds):
			_media_stack.force_refresh()
	if _focus_stack:
		_focus_stack.set_game_texture(resolved_tex)
		if not _media_bounds.is_equal_approx(_last_refreshed_media_bounds):
			_focus_stack.force_refresh()
	_update_media()
	# Ensure the card redraws so the RS canvas items are submitted to the render tree.
	queue_redraw()

func _on_card_pressed():
	if _suppress_next_press:
		_suppress_next_press = false
		return
	if not game:
		return

	var focus_index = self.get_meta("virtual_index", -1)

	if game.source == "steam":
		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
		return

	if game.is_active_variant_downloaded():
		# Accept the stored path whether it points at the archive or at an
		# extracted folder (ps3/vita/xbox360 games live in directories after
		# launch-time extraction); only fall back to reconstructing the archive
		# path when the stored path is gone.
		var present := false
		var active_id = game.get_active_game_id()
		var root_folder = DataManager.get_setting("games_root_folder") if DataManager else null
		var root_path: String = root_folder.value if root_folder else ""
		if active_id != game.romm_id:
			# Sibling selected: check its own file, not the main entry's path
			if root_path != "":
				present = FSM.file_exists(game.get_sibling_file_path(active_id, root_path))
		elif game.file_path != "" and (FSM.dir_exists(game.file_path) or FSM.file_exists(game.file_path)):
			present = true
		else:
			if root_path != "":
				var active_file_name = game.get_active_file_name()
				present = FSM.file_exists(FSM.join_paths(root_path, game.platform_slug, active_file_name))
		if not present:
			if SystemManager.notifications:
				SystemManager.notifications.show_notification("File not found - redownloading", SystemManager.notifications.Type.WARNING)
			download_requested.emit(game)
			return

		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
	else:
		download_requested.emit(game)

func _get_show_delete() -> bool:
	# Cache the result to avoid parent traversal on every context menu open
	if has_meta("_cached_show_delete"):
		return get_meta("_cached_show_delete")

	var parent = get_parent()
	while parent:
		if parent is HomeView or parent is LibraryView:
			set_meta("_cached_show_delete", true)
			return true
		parent = parent.get_parent()
	set_meta("_cached_show_delete", false)
	return false

func _is_in_home_view() -> bool:
	# The Hide menu item is Home-only; cache like _get_show_delete.
	# NOTE: deliberately no CollectionView check here — naming that class
	# from game_card completes a game_card -> collection_view -> view
	# dependency cycle that breaks global class compilation. A card's
	# ancestor chain can only pass through its own view, so stopping at
	# LibraryView (and falling through anything else to false) is exact.
	if has_meta("_cached_in_home_view"):
		return get_meta("_cached_in_home_view")

	var parent = get_parent()
	while parent:
		if parent is HomeView:
			set_meta("_cached_in_home_view", true)
			return true
		if parent is LibraryView:
			break
		parent = parent.get_parent()
	set_meta("_cached_in_home_view", false)
	return false

func _on_card_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if game and UIManager:
				UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete(), _is_in_home_view())

func _on_card_mouse_entered() -> void:
	if not _can_accept_focus():
		return
	if UIManager and UIManager.should_card_grab_focus_on_hover():
		if not has_focus():
			set_meta("mouse_hover_focus", true)
			grab_focus()

func _has_point(point: Vector2) -> bool:
	# In Transparent and Media Only modes the visible card is only the media
	# panel, so restrict the input hitbox to that region. This avoids launching
	# when clicking in the empty text/background area surrounding the media.
	if _display_mode != 1 and _display_mode != 2:
		return Rect2(Vector2.ZERO, size).has_point(point)
	if _media_bounds.size.x <= 0.0 or _media_bounds.size.y <= 0.0:
		return Rect2(Vector2.ZERO, size).has_point(point)
	return _media_bounds.has_point(point)

func _gui_input(event: InputEvent) -> void:
	if _can_accept_focus():
		# Dual-screen bottom touches arrive as emulated mouse events — treat them
		# like touch so hold-for-context-menu works on the second screen too.
		# These MUST run before super._gui_input(): M3Card emits `pressed`
		# synchronously on release in SubViewports, and _end_hold() must trigger
		# the long-press (suppressing the press) before that or the game launches.
		if SystemManager.platform.is_android() and event is InputEventMouseButton \
				and event.device == InputEvent.DEVICE_ID_EMULATION \
				and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_try_begin_hold(event.position)
			else:
				_end_hold()

		if SystemManager.platform.is_android() and event is InputEventMouseMotion \
				and event.device == InputEvent.DEVICE_ID_EMULATION \
				and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_update_hold_drag(event.position)

	super._gui_input(event)

	if not _can_accept_focus():
		return

	if event.is_action_pressed("ui_select"):
		var focused = get_viewport().gui_get_focus_owner()
		if focused == self and game and UIManager:
			if SystemManager.audio:
				SystemManager.audio.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
			UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete(), _is_in_home_view())
			accept_event()

	if SystemManager.platform.is_android() and event is InputEventScreenTouch:
		if event.pressed:
			_try_begin_hold(event.position)
		else:
			_end_hold()

	if SystemManager.platform.is_android() and event is InputEventScreenDrag:
		_update_hold_drag(event.position)

func _input(event: InputEvent) -> void:
	# Releases outside the card never reach _gui_input, but a hold that began
	# here must still end or the long-press state sticks. _touch_is_holding is
	# only ever set on Android touch paths, so on desktop this is a single
	# bool check per event per card.
	if not _touch_is_holding:
		return
	if event is InputEventScreenTouch and not event.pressed:
		_end_hold()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_end_hold()

func _try_begin_hold(pos: Vector2) -> void:
	# gui_input event positions are control-local in Godot 4, and _media_bounds
	# is local too (matching _has_point); the previous global-rect comparison
	# only ever passed for cards near the screen's top-left origin.
	var inside := false
	if _display_mode == 1 or _display_mode == 2:
		inside = _media_bounds.size.x > 0.0 and _media_bounds.size.y > 0.0 and _media_bounds.has_point(pos)
	else:
		inside = Rect2(Vector2.ZERO, size).has_point(pos)
	if inside:
		_touch_start_time = Time.get_ticks_msec() / 1000.0
		_touch_start_pos = pos
		_touch_is_holding = true
		if not _hold_timer:
			_hold_timer = Timer.new()
			_hold_timer.one_shot = true
			_hold_timer.timeout.connect(_on_hold_timer_timeout)
			add_child(_hold_timer)
		_hold_timer.start(LONG_PRESS_DURATION)

func _on_hold_timer_timeout() -> void:
	if _touch_is_holding:
		_trigger_long_press()

func _end_hold() -> void:
	if _hold_timer:
		_hold_timer.stop()
	if _touch_is_holding:
		# Fallback for a release after the duration without the timer firing.
		if _is_long_press_elapsed():
			_trigger_long_press()
		_touch_is_holding = false

func _update_hold_drag(pos: Vector2) -> void:
	if not _touch_is_holding:
		return
	if _touch_start_pos.distance_to(pos) > M3Units.dp(LONG_PRESS_TOLERANCE_DP):
		_touch_is_holding = false
		if _hold_timer:
			_hold_timer.stop()
	else:
		# Check if we've held long enough during drag
		if _is_long_press_elapsed():
			_trigger_long_press()

func _is_long_press_elapsed() -> bool:
	if not _touch_is_holding:
		return false
	var elapsed = (Time.get_ticks_msec() / 1000.0) - _touch_start_time
	return elapsed >= LONG_PRESS_DURATION

func _trigger_long_press() -> void:
	if not _touch_is_holding or not game or not UIManager:
		return
	_touch_is_holding = false
	# Haptic tick on activation (same pattern as keyboard/focus feedback).
	if SystemManager.platform.is_android():
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin:
			plugin.call("vibrateDevice", 50)
	elif Input.get_connected_joypads().size() > 0:
		Input.start_joy_vibration(0, 0.1, 0.05, 0.08)
	# M3Card emits `pressed` on the release that ends a hold; swallow it so the
	# game doesn't launch while the context menu opens.
	_suppress_next_press = true
	if SystemManager.audio:
		SystemManager.audio.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
	UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete(), _is_in_home_view())

func _can_accept_focus() -> bool:
	if LaunchTransitionOverlay.is_transition_active:
		return false
	return true

func _apply_content_scale() -> void:
	super._apply_content_scale()
	_update_effect_transforms()

func _update_effect_transforms() -> void:
	# The focus stack is parented to the card's canvas item, so it inherits
	# the card's offset-transform scale. We only need to translate it to the
	# media region when in transparent/media-only mode.
	if not _focus_stack:
		return
	var ci = _focus_stack._stack_canvas_item
	if not ci.is_valid():
		return

	var t := Transform2D()
	if not show_background:
		t = Transform2D().translated(_media_bounds.position)
	RenderingServer.canvas_item_set_transform(ci, t)

func _sync_focus_container_properties() -> void:
	if not _focus_media_container or not _media_container:
		return
	_focus_media_container.corner_radius_ratio = _media_container.corner_radius_ratio
	_focus_media_container.edge_aa_enabled = _media_container.edge_aa_enabled
	_focus_media_container.vertical_offset = _media_container.vertical_offset
	_focus_media_container.effect_settings = _media_container.effect_settings
	_focus_media_container.focus_effect_settings = _media_container.focus_effect_settings

func _sync_focus_visuals() -> void:
	if not focus_scale_enabled:
		content_scale = Vector2.ONE
		return
	var target_scale: Vector2
	if focus_scale_inverted:
		target_scale = Vector2.ONE if _is_focused else Vector2.ONE / focus_scale
	else:
		target_scale = Vector2.ONE * focus_scale if _is_focused else Vector2.ONE
	if not is_equal_approx(content_scale.x, target_scale.x) or not is_equal_approx(content_scale.y, target_scale.y):
		content_scale = target_scale

func _on_focus_entered():
	_is_focused = true
	_apply_text_settings()

	# Build the focus stack lazily the first time this card is focused.
	if not _focus_stack:
		_build_focus_stack()
		_update_platform_badge()

	if SystemManager.audio:
		SystemManager.audio.play_sfx_modulate("click_02", 0.98, 1.02)

	if SystemManager.platform.is_android():
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin:
			plugin.call("vibrateDevice", 50)
	else:
		Input.start_joy_vibration(0, 0.08, 0.03, 0.08)

	z_index = 2
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_BACK)
	_focus_tween.set_ease(Tween.EASE_OUT)
	if focus_scale_enabled:
		var start_scale = content_scale
		var target_scale = Vector2.ONE if focus_scale_inverted else Vector2.ONE * focus_scale
		_focus_tween.tween_method(
			func(t: float):
				if not is_instance_valid(self):
					return
				content_scale = start_scale.lerp(target_scale, t),
			0.0, 1.0, FOCUS_TWEEN_DURATION
		)
	_show_focus_effects(true)
	_try_unwrap_present()

func _on_focus_exited():
	_is_focused = false
	_apply_text_settings()
	z_index = 1
	_kill_focus_tweens()
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	if focus_scale_enabled:
		var start_scale = content_scale
		var target_scale = Vector2.ONE / focus_scale if focus_scale_inverted else Vector2.ONE
		_focus_tween.tween_method(
			func(t: float):
				if not is_instance_valid(self):
					return
				content_scale = start_scale.lerp(target_scale, t),
			0.0, 1.0, FOCUS_TWEEN_DURATION
		)
	_show_focus_effects(false)

func _update_focus_stack_bounds() -> void:
	if not _focus_media_container or not _focus_stack:
		return
	# Effect geometry is always local to its surface. Media offset belongs only
	# to the shared render transform, not to the bounds themselves.
	var new_bounds := Rect2(Vector2.ZERO, _media_bounds.size) if not show_background else Rect2(Vector2.ZERO, _get_content_size())

	var bounds_changed := not _focus_media_container.bounds.is_equal_approx(new_bounds)
	_focus_media_container.bounds = new_bounds

	_focus_stack.update_draw_rects()
	if bounds_changed:
		_focus_stack.force_refresh()
	_update_effect_transforms()

func _update_media_panel_size(force: bool = false) -> void:
	# Layout-input signature: when every input the panel layout derives from is
	# unchanged, every output (media/text bounds, control positions, draw rects,
	# shader geometry) is unchanged too — skip the whole pass. This kills the
	# duplicate full refresh that NOTIFICATION_RESIZED used to run right after
	# the layout pass had already applied the same inputs. force=true (structural
	# paths: canvas-item recreation, new media content, content rebind) bypasses.
	var _sig_w := custom_minimum_size.x
	if _sig_w <= 0.0:
		_sig_w = size.x
	var _sig_h := custom_minimum_size.y
	if _sig_h <= 0.0:
		_sig_h = size.y
	var _sig := PackedFloat32Array([
		maxf(_sig_w, M3Units.dp(40.0)),
		maxf(_sig_h, M3Units.dp(40.0)),
		float(card_layout_mode),
		float(content_alignment),
		media_aspect_ratio,
		card_rounding_ratio,
		1.0 if show_text_margin else 0.0,
		1.0 if text_centered_overlay else 0.0,
		1.0 if headline.is_empty() else 0.0,
		1.0 if _uses_visual_layer() else 0.0,
	])
	if not force and _sig == _media_layout_sig:
		return
	_media_layout_sig = _sig

	super._update_media_panel_size(force)
	if _media_container and _media_bounds.size.x > 0.0 and _media_bounds.size.y > 0.0:
		# The media stack is parented to _media_canvas_item, so its bounds are
		# expressed in media-local coordinates rather than card coords.
		_media_container.bounds = Rect2(Vector2.ZERO, _media_bounds.size)

	# _media_canvas_item is recreated by M3Card._rebuild_layout() when layout mode,
	# content alignment, or media aspect ratio changed. The node-less effect stack
	# must be reparented to the new item or its CanvasItem stays parented to a
	# freed RID and disappears.
	if _media_stack and _media_canvas_item.is_valid():
		_media_stack.set_parent_rid(_media_canvas_item)
		_media_stack.set_clip_children(false)
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		# Always update draw rects on entry/resize so the stack has valid geometry.
		# Only pay for a full shader pipeline refresh when bounds actually changed.
		var bounds_changed := not _media_bounds.is_equal_approx(_last_refreshed_media_bounds)
		_media_stack.update_draw_rects()
		if bounds_changed or force:
			_media_stack.force_refresh()
			_last_refreshed_media_bounds = _media_bounds

	if _present_wrap:
		_sync_present_wrap_geometry()

	if _focus_stack:
		_update_focus_stack_bounds()

func _update_focus_ring_bounds() -> void:
	super._update_focus_ring_bounds()
	_update_focus_stack_bounds()

func _notification(what: int):
	super._notification(what)
	if what == NOTIFICATION_RESIZED:
		pivot_offset = size / 2.0
		if not _badge_update_pending:
			_badge_update_pending = true
			call_deferred("_deferred_update_platform_badge")
		# _update_media_panel_size(true) is called by the layout system on resize,
		# which already refreshes the media stack. Avoid a second deferred refresh
		# that duplicates the work and can stall the render thread.
	if what == NOTIFICATION_PARENTED:
		# Invalidate cached parent-chain lookup so _get_show_delete() recomputes
		remove_meta("_cached_show_delete")
	if what == NOTIFICATION_PREDELETE:
		if _media_stack:
			_media_stack.free_rids()
			_media_stack = null
		if _focus_stack:
			_focus_stack.free_rids()
			_focus_stack = null
		if _present_wrap:
			_present_wrap.free_rid()
			_present_wrap = null
