class_name FocusSubManager
extends Manager

## Owns the single global focus ring drawn above all UI.
##
## Pure RenderingServer (canvas + one canvas item): no nodes are added to the
## tree and nothing polls per frame. The manager listens to
## Viewport.gui_focus_changed, then tracks the focused control through signals
## only (item_rect_changed / visibility_changed / tree_exiting).
##
## Controls decide their own ring geometry by implementing:
##   func m3_get_focus_geometry() -> Dictionary
##       "rect":   Rect2  (canvas/global coords)
##       "radius": float  (px, uniform)           [default: default_radius_dp]
##       "shape":  int    (Shape)                 [default: ring_shape]
##       "color":  Color  (MIRROR color source)   [default: theme primary]
## The ring is opt-in: controls without the method keep their existing focus
## visuals and get no global ring (incremental migration).
##
## Controls that move without a local rect change (e.g. RenderingServer-stamped
## grid slots) push updates via FocusSubManager.notify_geometry_changed(self).
## Controls should also forward NOTIFICATION_TRANSFORM_CHANGED the same way —
## the manager enables transform notifications on whatever it tracks, so
## ancestor motion (sheet slides, dialog scale-ins) reaches the ring.

## CanvasLayer-equivalent stacking layer for the ring canvas (max is 128).
const CANVAS_LAYER: int = 128

## Fallback draw index when a grid card does not expose its own stacking
## geometry. M3Card supplies the focused position dynamically instead.
const DEFAULT_GRID_DRAW_INDEX: int = 2_000_000

enum Shape { BOX, PILL, CIRCLE, CORNERS }
enum ColorMode { PRIMARY, MIRROR, CUSTOM, GRADIENT }
enum PaletteRole {
	PRIMARY,
	SECONDARY,
	TERTIARY,
	PRIMARY_SECONDARY,
	PRIMARY_TERTIARY,
	SECONDARY_TERTIARY,
	ALL_THREE,
}
enum GradientSource { ACCENT, RAINBOW, GAME }
enum GradientAnim { STATIC, EVOLVE, CHASE }
enum MovementAnim { NONE, POP, FOLLOW }
enum IdleAnim { NONE, BREATHE, CHASE }

signal config_changed

## Hub re-emission of the UI viewport's gui_focus_changed. Subscribers that
## only care about app-UI focus connect here once instead of tracking
## Viewport.gui_focus_changed across dual-screen reparents. Overlays and the
## on-screen keyboard still connect to their own viewport directly.
signal ui_focus_changed(control: Control)

static var _instance: FocusSubManager = null

static func get_instance() -> FocusSubManager:
	return _instance

var ui_manager: Node = null

# ============================================================================
# Configuration — every setter repaints the live ring immediately
# ============================================================================

var enabled: bool = true:
	set(value):
		enabled = value
		if not is_inside_tree():
			return
		if not enabled:
			_hide_ring()
		else:
			var vp := get_viewport()
			if vp:
				_on_gui_focus_changed(vp.gui_get_focus_owner())

var ring_shape: Shape = Shape.BOX:
	set(value):
		ring_shape = value
		_on_config_changed()

var stroke_width_dp: float = 3.0:
	set(value):
		stroke_width_dp = maxf(0.0, value)
		_on_config_changed()

## Outset between the control's reported rect and the ring.
var offset_dp: float = 5.0:
	set(value):
		offset_dp = value
		_on_config_changed()

var default_radius_dp: float = 12.0:
	set(value):
		default_radius_dp = maxf(0.0, value)
		_on_config_changed()

var color_mode: ColorMode = ColorMode.PRIMARY:
	set(value):
		color_mode = value
		_on_config_changed()

## Independent spatial/hue animation for GRADIENT color mode. Alpha animation
## remains controlled by idle_anim, so the two can be stacked.
var gradient_anim: GradientAnim = GradientAnim.STATIC:
	set(value):
		gradient_anim = value
		_on_config_changed()

var palette_role: PaletteRole = PaletteRole.PRIMARY:
	set(value):
		palette_role = value
		_on_config_changed()

## Rainbow remains the default to preserve the original gradient appearance.
var gradient_source: GradientSource = GradientSource.RAINBOW:
	set(value):
		gradient_source = value
		_on_config_changed()

var custom_color: Color = Color.WHITE:
	set(value):
		custom_color = value
		_on_config_changed()

var neon_glow: bool = true:
	set(value):
		neon_glow = value
		_on_config_changed()

var glow_intensity: float = 0.6:
	set(value):
		glow_intensity = clampf(value, 0.0, 1.0)
		_on_config_changed()

var glow_size_dp: float = 8.0:
	set(value):
		glow_size_dp = maxf(0.0, value)
		_on_config_changed()

## Derived by _apply_color; changing it must not re-enter config handling.
var glow_color: Color = Color(0.0, 0.0, 0.0, 0.35)

## NONE snaps the ring to each newly focused control, POP snaps and settles
## with a quick scale-down, FOLLOW tweens between controls.
## Indices mirror the library_focus_movement_anim setting options.
var movement_anim: MovementAnim = MovementAnim.FOLLOW
var idle_anim: IdleAnim = IdleAnim.NONE:
	set(value):
		idle_anim = value
		_on_config_changed()

## Chase tween duration (seconds).
var chase_duration: float = M3Motion.STATE

## Tick length for Shape.CORNERS.
var corner_tick_dp: float = 10.0:
	set(value):
		corner_tick_dp = maxf(1.0, value)
		_on_config_changed()

const NEON_SHADER = preload("res://shaders/focus_ring_neon.gdshader")
const NEON_GLOW_STROKE_EXTRA_DP: float = 5.0
const BREATHE_PERIOD: float = 1.6
const BREATHE_MIN_ALPHA: float = 0.3
const ORBIT_PERIOD: float = 4.0
## Fraction of the perimeter covered by the CHASE comet (head + fading tail).
const ORBIT_WINDOW: float = 0.15
const ORBIT_POINTS: int = 16
## Base ring alpha multiplier while the CHASE comet orbits over it.
const ORBIT_BASE_ALPHA: float = 0.35

## Fixed five-color palette. Evolve cycles selected roles through fixed stops;
## Chase rotates the whole gradient through space.
const GRADIENT_COLORS = [
	Color(0.10, 0.90, 1.00),
	Color(0.20, 0.38, 1.00),
	Color(0.58, 0.22, 1.00),
	Color(1.00, 0.16, 0.65),
	Color(1.00, 0.62, 0.18),
]
const GRADIENT_HUE_OFFSETS = [-0.035, -0.015, 0.0, 0.018, 0.040]
const GRADIENT_VALUE_SCALE = [0.84, 0.96, 1.0, 0.94, 0.86]
const GRADIENT_EVOLVE_PERIOD: float = 6.0

## POP movement: the ring snaps to the new target slightly enlarged, then
## eases back down to its exact pose.
const POP_START_SCALE: float = 1.12
const POP_DURATION: float = 0.15

# ============================================================================
# RenderingServer state
# ============================================================================

var _canvas: RID
var _ring_item: RID
var _neon_item: RID
var _neon_material: ShaderMaterial = null
var _neon_texture: ImageTexture = null
var _ring_style: StyleBoxFlat = null
var _attached_viewport: Viewport = null
## Grid visual layer RID when the focused control is inside a grid; invalid
## RID means the ring is on the always-on-top viewport canvas.
var _ring_parent_grid: RID

# ============================================================================
# Target state. _dest_* is the resolved destination pose; _ring_* is the
# currently drawn pose (equal unless a chase tween is running).
# ============================================================================

var _target_ref: WeakRef = null
var _ring_rect := Rect2()
var _ring_radius: float = 0.0
var _ring_shape: int = Shape.BOX
var _ring_color: Color = Color.WHITE
var _base_gradient_colors: Array[Color] = []
var _ring_visible: bool = false
var _dest_rect := Rect2()
var _dest_radius: float = 0.0
var _dest_shape: int = Shape.BOX

var _chase_tween: Tween = null
var _idle_tween: Tween = null
var _gradient_tween: Tween = null
var _orbit_t: float = 0.0
var _gradient_t: float = 0.0
var _pop_tween: Tween = null
var _pop_scale: float = 1.0
var _target_prev_notify: bool = false

# ============================================================================
# Lifecycle
# ============================================================================

func _ready() -> void:
	ui_manager = get_parent()
	_instance = self
	if not DataManager.cover_palette_updated.is_connected(_on_cover_palette_updated):
		DataManager.cover_palette_updated.connect(_on_cover_palette_updated)

	_ring_style = StyleBoxFlat.new()
	_ring_style.bg_color = Color.TRANSPARENT
	M3Theme.configure_smooth_corners(_ring_style, M3Units.dp(default_radius_dp))
	_ring_style.shadow_offset = Vector2.ZERO
	_apply_style()

	_canvas = RenderingServer.canvas_create()
	_ring_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_ring_item, _canvas)
	RenderingServer.canvas_item_set_visible(_ring_item, false)

	_neon_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_neon_item, _canvas)
	RenderingServer.canvas_item_set_visible(_neon_item, false)
	_neon_material = ShaderMaterial.new()
	_neon_material.shader = NEON_SHADER
	RenderingServer.canvas_item_set_material(_neon_item, _neon_material.get_rid())
	var white_image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white_image.fill(Color.WHITE)
	_neon_texture = ImageTexture.create_from_image(white_image)

	var vp := get_viewport()
	if vp:
		vp.gui_focus_changed.connect(_on_gui_focus_changed)
		_attach_to_viewport(vp)
		call_deferred("_initial_sync")

func _initial_sync() -> void:
	var vp := get_viewport()
	if vp:
		_on_gui_focus_changed(vp.gui_get_focus_owner())

func _exit_tree() -> void:
	if _instance == self:
		_instance = null
	if DataManager.cover_palette_updated.is_connected(_on_cover_palette_updated):
		DataManager.cover_palette_updated.disconnect(_on_cover_palette_updated)
	_kill_chase_tween()
	_kill_pop_tween()
	_stop_idle()
	_ring_parent_grid = RID()
	if _attached_viewport and is_instance_valid(_attached_viewport):
		RenderingServer.viewport_remove_canvas(_attached_viewport.get_viewport_rid(), _canvas)
		_attached_viewport = null
	if _ring_item.is_valid():
		RenderingServer.free_rid(_ring_item)
		_ring_item = RID()
	if _neon_item.is_valid():
		RenderingServer.free_rid(_neon_item)
		_neon_item = RID()
	_neon_material = null
	_neon_texture = null
	if _canvas.is_valid():
		RenderingServer.free_rid(_canvas)
		_canvas = RID()

## Push API for controls/containers that move a focused control without
## changing its local rect (virtual grids stamping RS transforms, etc.).
static func notify_geometry_changed(control: Control) -> void:
	if _instance == null:
		return
	if _instance._get_target() == control:
		_instance._on_target_moved()

## Re-resolve style and geometry for the current target (theme/color changes).
func refresh() -> void:
	if _ring_style == null:
		return
	_apply_style()
	var t := _get_target()
	if t and _ring_visible:
		_show_target(false)

## Re-point the manager at a different viewport (dual screen mode reparents the
## whole UI into a SubViewport, which owns its own gui_focus_changed signal).
## Pass null to fall back to this node's own viewport.
func reconnect_viewport(vp: Viewport = null) -> void:
	if vp == null:
		vp = get_viewport()
	if vp == null:
		return
	if _attached_viewport and is_instance_valid(_attached_viewport) \
			and _attached_viewport != vp \
			and _attached_viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		_attached_viewport.gui_focus_changed.disconnect(_on_gui_focus_changed)
	if not vp.gui_focus_changed.is_connected(_on_gui_focus_changed):
		vp.gui_focus_changed.connect(_on_gui_focus_changed)
	_attach_to_viewport(vp)
	_untrack_target()
	_hide_ring()
	_on_gui_focus_changed(vp.gui_get_focus_owner())

# ============================================================================
# Focus tracking (signal driven)
# ============================================================================

func _on_gui_focus_changed(control: Control) -> void:
	ui_focus_changed.emit(control)
	_untrack_target()
	if not enabled or control == null or not is_instance_valid(control) \
			or not control.is_visible_in_tree() or not control.has_method("m3_get_focus_geometry"):
		_hide_ring()
		return
	# While the on-screen keyboard is open, key focus is shown by the keys'
	# own focus border — the global ring renders below the keyboard's canvas
	# layer, so hide it rather than chase keys around behind the panel.
	if ui_manager and ui_manager.has_method("is_focus_in_onscreen_keyboard") \
			and ui_manager.is_focus_in_onscreen_keyboard(control):
		_hide_ring()
		return
	var vp := control.get_viewport()
	if vp and vp != _attached_viewport:
		_attach_to_viewport(vp)
	_track_target(control)
	_update_ring_parent(control)
	_show_target(true)

func _get_target() -> Control:
	if _target_ref == null:
		return null
	var t: Control = _target_ref.get_ref()
	if t == null or not is_instance_valid(t):
		return null
	return t

func _track_target(control: Control) -> void:
	_target_ref = weakref(control)
	# Enable global-transform notifications while tracked so ancestor motion
	# (sheet slides, dialog scale-ins, overlay moves) reaches the control and
	# is forwarded to us via the protocol. Restored on untrack.
	_target_prev_notify = control.is_transform_notification_enabled()
	control.set_notify_transform(true)
	control.item_rect_changed.connect(_on_target_moved)
	control.resized.connect(_on_target_moved)
	control.visibility_changed.connect(_on_target_visibility_changed)
	control.tree_exiting.connect(_on_target_tree_exiting)
	if control.has_signal("game_changed"):
		control.connect("game_changed", _on_target_game_changed)

func _untrack_target() -> void:
	var t := _get_target()
	if t:
		t.set_notify_transform(_target_prev_notify)
		if t.item_rect_changed.is_connected(_on_target_moved):
			t.item_rect_changed.disconnect(_on_target_moved)
		if t.resized.is_connected(_on_target_moved):
			t.resized.disconnect(_on_target_moved)
		if t.visibility_changed.is_connected(_on_target_visibility_changed):
			t.visibility_changed.disconnect(_on_target_visibility_changed)
		if t.tree_exiting.is_connected(_on_target_tree_exiting):
			t.tree_exiting.disconnect(_on_target_tree_exiting)
		if t.has_signal("game_changed") and t.is_connected("game_changed", _on_target_game_changed):
			t.disconnect("game_changed", _on_target_game_changed)
	_target_ref = null

func _on_target_moved() -> void:
	var t := _get_target()
	if t == null or not _ring_visible:
		return
	# Grid visual layers can be recreated on view rebuilds; re-resolve if the
	# one we're parented to was freed.
	if _ring_parent_grid != RID() and not _ring_parent_grid.is_valid():
		_ring_parent_grid = RID()
		_update_ring_parent(t)
	var geo := _resolve_geometry(t)
	# Dedupe: pre-draw stampers push every frame; only react to real change.
	_update_ring_draw_index(t)
	if geo.rect.is_equal_approx(_dest_rect) and is_equal_approx(geo.radius, _dest_radius) and geo.shape == _dest_shape:
		return
	_dest_rect = geo.rect
	_dest_radius = geo.radius
	_dest_shape = geo.shape
	_ring_shape = geo.shape
	_apply_color(geo)
	# A running chase reads _dest_* live; restarting it every push (grid
	# stamps, focus-pop scale) would freeze it at frame one.
	if _chase_tween and _chase_tween.is_valid():
		return
	_ring_rect = _dest_rect
	_ring_radius = _dest_radius
	_redraw_ring()

func _on_target_game_changed(_game: Variant) -> void:
	_refresh_focus_palette()

func _on_cover_palette_updated(cover_url: String) -> void:
	if color_mode != ColorMode.GRADIENT or gradient_source != GradientSource.GAME:
		return
	var target := _get_target()
	if target == null or not _ring_visible or not target.has_method("m3_get_focus_palette"):
		return
	var palette: Dictionary = target.m3_get_focus_palette()
	if palette.get("source_id", "") != cover_url:
		return
	if target.has_method("m3_refresh_focus_palette"):
		target.m3_refresh_focus_palette(cover_url)
	_refresh_focus_palette()

func _refresh_focus_palette() -> void:
	if color_mode != ColorMode.GRADIENT or gradient_source != GradientSource.GAME or not _ring_visible:
		return
	var target := _get_target()
	if target == null:
		return
	var geo := _resolve_geometry(target)
	_apply_color(geo)
	_redraw_ring()

func _on_target_visibility_changed() -> void:
	var t := _get_target()
	if t == null:
		return
	if t.is_visible_in_tree() and t.has_focus():
		_show_target(false)
	else:
		_hide_ring()

func _on_target_tree_exiting() -> void:
	# Targets can leave the tree without being freed (grid cards recycled into
	# the pool via remove_child). Disconnect through the guarded teardown so a
	# reused card doesn't accumulate duplicate connections on re-track.
	_untrack_target()
	_hide_ring()

# ============================================================================
# Geometry
# ============================================================================

func _resolve_geometry(control: Control) -> Dictionary:
	var geo: Dictionary = control.m3_get_focus_geometry()
	var rect: Rect2 = geo.get("rect", control.get_global_rect())
	var radius: float = geo.get("radius", -1.0)
	var shape: int = geo.get("shape", ring_shape)
	var color: Color = geo.get("color", Color(0.0, 0.0, 0.0, 0.0))
	var focus_palette: Dictionary = {}
	if control.has_method("m3_get_focus_palette"):
		focus_palette = control.m3_get_focus_palette()
	if radius < 0.0:
		radius = M3Units.dp(default_radius_dp)
	radius = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	return {"rect": rect, "radius": radius, "shape": shape, "color": color, "palette": focus_palette}

# ============================================================================
# Ring presentation
# ============================================================================

func _show_target(animate: bool) -> void:
	var t := _get_target()
	if t == null:
		_hide_ring()
		return
	var geo := _resolve_geometry(t)
	_dest_rect = geo.rect
	_dest_radius = geo.radius
	_dest_shape = geo.shape
	_ring_shape = geo.shape
	_apply_color(geo)
	if animate and _ring_visible and movement_anim == MovementAnim.FOLLOW:
		_start_chase()
	else:
		_kill_chase_tween()
		_ring_rect = _dest_rect
		_ring_radius = _dest_radius
		_set_ring_visible(true)
		_redraw_ring()
		if animate and movement_anim == MovementAnim.POP:
			_start_pop()
	_restart_idle()

func _hide_ring() -> void:
	_kill_chase_tween()
	_kill_pop_tween()
	_pop_scale = 1.0
	_stop_idle()
	_set_ring_visible(false)

func _set_ring_visible(value: bool) -> void:
	if _ring_visible == value:
		return
	_ring_visible = value
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_visible(_ring_item, value)
	if _neon_item.is_valid():
		RenderingServer.canvas_item_set_visible(_neon_item, value)

func _attach_to_viewport(vp: Viewport) -> void:
	if _attached_viewport == vp:
		return
	if _attached_viewport and is_instance_valid(_attached_viewport):
		RenderingServer.viewport_remove_canvas(_attached_viewport.get_viewport_rid(), _canvas)
	_attached_viewport = vp
	RenderingServer.viewport_attach_canvas(vp.get_viewport_rid(), _canvas)
	RenderingServer.viewport_set_canvas_stacking(vp.get_viewport_rid(), _canvas, CANVAS_LAYER, 0)

## Inside a grid the ring re-parents into the grid's visual layer (above all
## cards/effects via GRID_DRAW_INDEX, below chrome via tree order). Outside a
## grid it lives on the always-on-top viewport canvas.
func _update_ring_parent(control: Control) -> void:
	var grid_rid := _find_grid_ring_parent(control)
	if grid_rid == _ring_parent_grid:
		return
	_ring_parent_grid = grid_rid
	if not _ring_item.is_valid():
		return
	if _ring_parent_grid.is_valid():
		RenderingServer.canvas_item_set_parent(_ring_item, _ring_parent_grid)
		RenderingServer.canvas_item_set_parent(_neon_item, _ring_parent_grid)
		_update_ring_draw_index(control)
	else:
		RenderingServer.canvas_item_set_parent(_ring_item, _canvas)
		RenderingServer.canvas_item_set_parent(_neon_item, _canvas)
		RenderingServer.canvas_item_set_draw_index(_ring_item, 1)
		RenderingServer.canvas_item_set_draw_index(_neon_item, 0)

func _update_ring_draw_index(control: Control) -> void:
	if not _ring_parent_grid.is_valid() or not _ring_item.is_valid():
		return
	var draw_index := DEFAULT_GRID_DRAW_INDEX
	if control.has_method("m3_get_focus_draw_index"):
		draw_index = control.m3_get_focus_draw_index()
	# The normally blended core belongs after the additive halo.
	RenderingServer.canvas_item_set_draw_index(_ring_item, draw_index + 1)
	if _neon_item.is_valid():
		RenderingServer.canvas_item_set_draw_index(_neon_item, draw_index)

## Walks ancestors for a VirtualScrollGridContainer (duck-typed via its public
## visual layer accessor). Returns an invalid RID when not inside a grid.
func _find_grid_ring_parent(control: Control) -> RID:
	var node := control.get_parent()
	while node:
		if node.has_method("get_visual_layer_rid"):
			var rid: RID = node.get_visual_layer_rid()
			if rid.is_valid():
				return rid
		node = node.get_parent()
	return RID()

func _apply_style() -> void:
	_ring_style.set_border_width_all(M3Units.dpi(stroke_width_dp))
	# Full-ring glow is shader-based. A StyleBox shadow fills the entire rounded
	# silhouette, which would tint the card; never enable that path.
	_ring_style.shadow_size = 0
	_ring_style.shadow_color = glow_color if neon_glow else Color.TRANSPARENT

func _selected_palette_roles() -> Array:
	match palette_role:
		PaletteRole.SECONDARY:
			return [PaletteRole.SECONDARY]
		PaletteRole.TERTIARY:
			return [PaletteRole.TERTIARY]
		PaletteRole.PRIMARY_SECONDARY:
			return [PaletteRole.PRIMARY, PaletteRole.SECONDARY]
		PaletteRole.PRIMARY_TERTIARY:
			return [PaletteRole.PRIMARY, PaletteRole.TERTIARY]
		PaletteRole.SECONDARY_TERTIARY:
			return [PaletteRole.SECONDARY, PaletteRole.TERTIARY]
		PaletteRole.ALL_THREE:
			return [PaletteRole.PRIMARY, PaletteRole.SECONDARY, PaletteRole.TERTIARY]
		_:
			return [PaletteRole.PRIMARY]

func _accent_palette_color(role: PaletteRole) -> Color:
	match role:
		PaletteRole.SECONDARY:
			return M3Theme.get_secondary()
		PaletteRole.TERTIARY:
			return M3Theme.get_tertiary()
		_:
			return M3Theme.get_primary()

func _game_palette_color(palette: Dictionary, role: PaletteRole, fallback: Color) -> Color:
	var key := "primary"
	match role:
		PaletteRole.SECONDARY:
			key = "secondary"
		PaletteRole.TERTIARY:
			key = "tertiary"
	var game_color: Color = palette.get(key, Color.TRANSPARENT)
	return game_color if game_color.a > 0.0 else fallback

func _resolve_gradient_colors(geo: Dictionary) -> Array[Color]:
	var colors: Array[Color] = []
	if gradient_source == GradientSource.RAINBOW:
		for color in GRADIENT_COLORS:
			colors.append(color)
		return colors
	var base_colors: Array[Color] = []
	var game_palette: Dictionary = geo.get("palette", {})
	for role in _selected_palette_roles():
		var base_color := _accent_palette_color(role)
		if gradient_source == GradientSource.GAME:
			base_color = _game_palette_color(game_palette, role, base_color)
		base_colors.append(base_color)
	if base_colors.size() == 1:
		return _expand_gradient_color(base_colors[0])
	if base_colors.size() == 2:
		return _expand_dual_gradient(base_colors[0], base_colors[1])
	return _expand_triad_gradient(base_colors[0], base_colors[1], base_colors[2])

func _expand_gradient_color(base_color: Color) -> Array[Color]:
	var colors: Array[Color] = []
	var saturation := 0.0 if is_zero_approx(base_color.s) else clampf(maxf(base_color.s, 0.60), 0.0, 0.96)
	var value := clampf(maxf(base_color.v, 0.92), 0.0, 1.0)
	for i in range(5):
		var hue := fposmod(base_color.h + float(GRADIENT_HUE_OFFSETS[i]), 1.0)
		var stop_value := clampf(value * float(GRADIENT_VALUE_SCALE[i]), 0.70, 1.0)
		colors.append(Color.from_hsv(hue, saturation, stop_value, 1.0))
	return colors

func _expand_dual_gradient(a: Color, b: Color) -> Array[Color]:
	var a_variants := _expand_gradient_color(a)
	var b_variants := _expand_gradient_color(b)
	var colors: Array[Color] = []
	for index in [0, 2, 4]:
		colors.append(a_variants[index])
	for index in [0, 2, 4]:
		colors.append(b_variants[index])
	return colors

func _expand_triad_gradient(a: Color, b: Color, c: Color) -> Array[Color]:
	var a_variants := _expand_gradient_color(a)
	var b_variants := _expand_gradient_color(b)
	var c_variants := _expand_gradient_color(c)
	var colors: Array[Color] = []
	for variants in [a_variants, b_variants, c_variants]:
		for index in [0, 2, 4]:
			colors.append(variants[index])
	return colors

func _apply_color(geo: Dictionary) -> void:
	_base_gradient_colors = _resolve_gradient_colors(geo)
	var source_color := Color.WHITE
	match color_mode:
		ColorMode.CUSTOM:
			source_color = custom_color
		ColorMode.MIRROR:
			var c: Color = geo.color
			source_color = c if c.a > 0.0 else M3Theme.get_primary()
		ColorMode.GRADIENT:
			# Palette RGB is sampled per fragment/vertex; white supplies alpha.
			source_color = Color.WHITE
		_:
			source_color = M3Theme.get_primary()

	if neon_glow:
		# Keep the hue, but give the core a brighter, slightly white-hot center.
		var core := source_color.lerp(Color.WHITE, 0.08)
		if not is_zero_approx(source_color.s):
			core.s = clampf(core.s, 0.65, 1.0)
		core.v = clampf(core.v, 0.9, 1.0)
		core.a = source_color.a
		_ring_color = core
		glow_color = Color(core.r, core.g, core.b, source_color.a * glow_intensity * 0.65)
	else:
		_ring_color = source_color
		glow_color = Color.TRANSPARENT
	_ring_style.border_color = _ring_color
	_ring_style.shadow_color = glow_color

func _redraw_ring() -> void:
	if not _ring_item.is_valid():
		return
	RenderingServer.canvas_item_clear(_ring_item)
	if _neon_item.is_valid():
		RenderingServer.canvas_item_clear(_neon_item)
	if not _ring_visible:
		return
	var orbiting := idle_anim == IdleAnim.CHASE
	var use_shader := neon_glow or color_mode == ColorMode.GRADIENT
	var base_color := _ring_color
	if orbiting:
		base_color.a *= ORBIT_BASE_ALPHA
	_ring_style.border_color = base_color
	_ring_style.shadow_color = Color(base_color.r, base_color.g, base_color.b, base_color.a * glow_intensity * 0.65) if neon_glow else Color.TRANSPARENT
	var offset := M3Units.dp(offset_dp)
	var stroke_width := M3Units.dpi(stroke_width_dp)
	# Stroke rasterization is centered on this rect. Move its centerline out by
	# half the stroke so the inner edge stays exactly at the configured outset.
	var geometry_offset := offset + stroke_width * 0.5
	var rect := _ring_rect.grow(geometry_offset)
	var radius := minf(_ring_radius + geometry_offset, minf(rect.size.x, rect.size.y) * 0.5)
	if _pop_scale != 1.0:
		var center := rect.get_center()
		rect = Rect2(center - rect.size * _pop_scale * 0.5, rect.size * _pop_scale)
		radius *= _pop_scale
	# Scale tessellation with the actual drawn size, not the control's DP
	# radius. Large card rings otherwise retain Godot's coarse default arcs.
	M3Theme.configure_smooth_corners(_ring_style, minf(rect.size.x, rect.size.y) * 0.5)
	match _ring_shape:
		Shape.PILL:
			radius = minf(rect.size.x, rect.size.y) * 0.5
			if use_shader:
				_draw_neon_full(rect, radius, base_color)
			else:
				_ring_style.set_corner_radius_all(int(radius))
				_ring_style.draw(_ring_item, rect)
		Shape.CIRCLE:
			var side := minf(rect.size.x, rect.size.y)
			var square := Rect2(rect.get_center() - Vector2(side, side) * 0.5, Vector2(side, side))
			radius = side * 0.5
			if use_shader:
				_draw_neon_full(square, radius, base_color)
			else:
				_ring_style.set_corner_radius_all(int(radius))
				_ring_style.draw(_ring_item, square)
		Shape.CORNERS:
			if use_shader:
				_draw_neon_corners(rect, radius, base_color)
				# Keep the core's hue intact on light backgrounds; only the
				# underlying halo uses additive blending.
				_draw_corners(rect, radius)
			else:
				_draw_corners(rect, radius)
		_:
			if use_shader:
				_draw_neon_full(rect, radius, base_color)
			else:
				_ring_style.set_corner_radius_all(int(radius))
				_ring_style.draw(_ring_item, rect)
	if orbiting:
		_draw_orbit_comet(rect, radius)

func _draw_neon_full(rect: Rect2, radius: float, color: Color) -> void:
	# Solid cores use normal alpha blending so light themes do not wash their
	# accent to white. Gradient cores retain the single-pass shader treatment.
	var separate_core := neon_glow and color_mode != ColorMode.GRADIENT
	_draw_neon_ring(rect, radius, color, false, 0.0, PI * 0.5, separate_core)
	if separate_core:
		_ring_style.set_corner_radius_all(int(radius))
		_ring_style.draw(_ring_item, rect)

func _draw_neon_corners(rect: Rect2, radius: float, color: Color) -> void:
	# Match the polyline fallback's centerline geometry. The shader derives a
	# true distance field around each arc and tick, including rounded end caps.
	var width := M3Units.dp(stroke_width_dp)
	if width <= 0.0:
		return
	# The incoming rect already includes the half-stroke outward offset.
	var r := rect
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	radius = minf(radius, minf(r.size.x, r.size.y) * 0.5)
	var straight_w := maxf(0.0, r.size.x - 2.0 * radius)
	var straight_h := maxf(0.0, r.size.y - 2.0 * radius)
	var tick := minf(M3Units.dp(corner_tick_dp), minf(straight_w, straight_h) * 0.5)
	var sweep := PI * 0.5
	if tick < 1.0:
		sweep *= 0.7
	_draw_neon_ring(r, radius, color, true, tick, sweep, true)

func _draw_neon_ring(rect: Rect2, radius: float, color: Color, corners: bool = false, tick: float = 0.0, sweep: float = PI * 0.5, halo_only: bool = false) -> void:
	if not _neon_item.is_valid() or _neon_material == null or _neon_texture == null:
		return
	# Match the shader's 3x feathered glow range. Keep enough room for the core
	# when glow size is zero, plus safety padding for antialiased coverage.
	# border_size remains the actual ring rect; the SDF never fills its center.
	var glow_width := M3Units.dp(glow_size_dp)
	var stroke_width := M3Units.dpi(stroke_width_dp)
	var spread := maxf(glow_width * 3.0, stroke_width) + 2.0
	var draw_rect := rect.grow(spread)
	_neon_material.set_shader_parameter("neon_color", color)
	_neon_material.set_shader_parameter("quad_size", draw_rect.size)
	_neon_material.set_shader_parameter("border_size", rect.size)
	_neon_material.set_shader_parameter("corner_radius", radius)
	_neon_material.set_shader_parameter("stroke_width", stroke_width)
	_neon_material.set_shader_parameter("glow_width", glow_width)
	_neon_material.set_shader_parameter("glow_strength", glow_intensity if neon_glow else 0.0)
	_neon_material.set_shader_parameter("core_strength", 0.0 if halo_only else 1.0)
	_neon_material.set_shader_parameter("corner_mode", corners)
	_neon_material.set_shader_parameter("corner_tick", tick)
	_neon_material.set_shader_parameter("corner_sweep", sweep)
	_update_gradient_material()
	RenderingServer.canvas_item_add_texture_rect(
		_neon_item,
		draw_rect,
		_neon_texture.get_rid(),
		false,
		Color.WHITE,
		false
	)

func _current_gradient_palette() -> Array[Color]:
	var palette: Array[Color] = []
	var source_colors: Array[Color] = _base_gradient_colors
	if source_colors.is_empty():
		for color in GRADIENT_COLORS:
			source_colors.append(color)
	var count := source_colors.size()
	for i in range(count):
		if gradient_anim != GradientAnim.EVOLVE:
			palette.append(source_colors[i])
			continue
		# Every stop cycles through the complete approved palette. In mixed
		# palettes, adjacent role clusters run in opposite directions so Primary
		# becomes Secondary while Secondary becomes Primary, rather than the
		# whole gradient merely translating as it does in Chase.
		var direction := 1.0
		if count == 6 or count == 9:
			direction = 1.0 if floori(float(i) / 3.0) % 2 == 0 else -1.0
		var phase := fposmod(float(i) / float(count) + _gradient_t * direction, 1.0)
		var scaled := phase * float(count)
		var index := int(floor(scaled)) % count
		var next_index := (index + 1) % count
		var fraction: float = scaled - floor(scaled)
		fraction = fraction * fraction * (3.0 - 2.0 * fraction)
		palette.append(source_colors[index].lerp(source_colors[next_index], fraction))
	return palette

func _sample_gradient(palette: Array[Color], t: float) -> Color:
	if palette.is_empty():
		return Color.WHITE
	var scaled := fposmod(t, 1.0) * float(palette.size())
	var index := int(floor(scaled)) % palette.size()
	var next_index := (index + 1) % palette.size()
	var fraction: float = scaled - floor(scaled)
	fraction = fraction * fraction * (3.0 - 2.0 * fraction)
	return palette[index].lerp(palette[next_index], fraction)

func _gradient_spatial_t(t: float) -> float:
	var phase := _orbit_t if gradient_anim == GradientAnim.CHASE else 0.0
	return fposmod(t - phase, 1.0)

func _update_gradient_material() -> void:
	if _neon_material == null:
		return
	var enabled := color_mode == ColorMode.GRADIENT
	_neon_material.set_shader_parameter("gradient_enabled", enabled)
	_neon_material.set_shader_parameter("gradient_phase", _orbit_t if gradient_anim == GradientAnim.CHASE else 0.0)
	if not enabled:
		return
	var palette := _current_gradient_palette()
	_neon_material.set_shader_parameter("gradient_color_count", palette.size())
	for i in range(palette.size()):
		_neon_material.set_shader_parameter("gradient_color_%d" % i, palette[i])

## Walk the rounded-rect perimeter; t in [0,1) wraps. Starts at the top edge
## (after the top-left arc) and proceeds clockwise.
func _perimeter_point(rect: Rect2, radius: float, t: float) -> Vector2:
	var r := clampf(radius, 0.001, minf(rect.size.x, rect.size.y) * 0.5)
	var straight_w := rect.size.x - 2.0 * r
	var straight_h := rect.size.y - 2.0 * r
	var arc := r * PI * 0.5
	var total := 2.0 * (straight_w + straight_h) + 4.0 * arc
	if total <= 0.0:
		return rect.position
	var d := fposmod(t, 1.0) * total
	var segs := [straight_w, arc, straight_h, arc, straight_w, arc, straight_h, arc]
	var idx := 0
	while idx < 8 and d > segs[idx]:
		d -= segs[idx]
		idx += 1
	var tl := rect.position
	var top_right := Vector2(rect.end.x, rect.position.y)
	var br := rect.end
	var bl := Vector2(rect.position.x, rect.end.y)
	match idx:
		0:
			return Vector2(tl.x + r + d, tl.y)
		1:
			var c := top_right + Vector2(-r, r)
			var a := -PI * 0.5 + d / r
			return c + Vector2(cos(a), sin(a)) * r
		2:
			return Vector2(top_right.x, top_right.y + r + d)
		3:
			var c := br + Vector2(-r, -r)
			var a := d / r
			return c + Vector2(cos(a), sin(a)) * r
		4:
			return Vector2(br.x - r - d, br.y)
		5:
			var c := bl + Vector2(r, -r)
			var a := PI * 0.5 + d / r
			return c + Vector2(cos(a), sin(a)) * r
		6:
			return Vector2(bl.x, bl.y - r - d)
		7:
			var c := tl + Vector2(r, r)
			var a := PI + d / r
			return c + Vector2(cos(a), sin(a)) * r
	return tl

## Inverse of _perimeter_point for direct-drawn Corners colors. The shader uses
## the same segment ordering so both paths share an identical gradient position.
func _perimeter_progress_at_point(rect: Rect2, radius: float, point: Vector2) -> float:
	var half_size := rect.size * 0.5
	var r := clampf(radius, 0.001, minf(half_size.x, half_size.y))
	var local := point - rect.get_center()
	var corner := half_size - Vector2.ONE * r
	var q := local.abs()
	var straight_w := maxf(rect.size.x - 2.0 * r, 0.0)
	var straight_h := maxf(rect.size.y - 2.0 * r, 0.0)
	var arc := r * PI * 0.5
	var total := 2.0 * (straight_w + straight_h) + 4.0 * arc
	if total <= 0.0:
		return 0.0
	var distance := 0.0
	if q.x <= corner.x:
		if local.y < 0.0:
			distance = local.x + half_size.x - r
		else:
			distance = straight_w + 2.0 * arc + straight_h + half_size.x - r - local.x
	elif q.y <= corner.y:
		if local.x > 0.0:
			distance = straight_w + arc + local.y + half_size.y - r
		else:
			distance = 2.0 * straight_w + 3.0 * arc + straight_h + half_size.y - r - local.y
	else:
		var center := Vector2(signf(local.x) * corner.x, signf(local.y) * corner.y)
		var offset := local - center
		var angle := atan2(offset.y, offset.x)
		if local.x > 0.0 and local.y < 0.0:
			distance = straight_w + (angle + PI * 0.5) * r
		elif local.x > 0.0:
			distance = straight_w + arc + straight_h + angle * r
		elif local.y > 0.0:
			distance = 2.0 * straight_w + 2.0 * arc + straight_h + (angle - PI * 0.5) * r
		else:
			distance = 2.0 * straight_w + 3.0 * arc + 2.0 * straight_h + (angle + PI) * r
	return fposmod(distance / total, 1.0)

func _draw_orbit_comet(rect: Rect2, radius: float) -> void:
	var width := M3Units.dp(stroke_width_dp)
	if width <= 0.0:
		return
	var gradient_enabled := color_mode == ColorMode.GRADIENT
	var palette: Array[Color] = []
	if gradient_enabled:
		palette = _current_gradient_palette()
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	points.resize(ORBIT_POINTS)
	colors.resize(ORBIT_POINTS)
	for i in range(ORBIT_POINTS):
		var f := float(i) / float(ORBIT_POINTS - 1)  # 0 = tail, 1 = head
		var point_t := fposmod(_orbit_t - ORBIT_WINDOW * (1.0 - f), 1.0)
		points[i] = _perimeter_point(rect, radius, point_t)
		var c := _sample_gradient(palette, _gradient_spatial_t(point_t)) if gradient_enabled else _ring_color
		c.a *= f * f
		colors[i] = c
	if neon_glow and glow_intensity > 0.0:
		var halo_colors := PackedColorArray(colors)
		for i in range(halo_colors.size()):
			halo_colors[i].a *= glow_intensity * 0.65
		var halo_width := width + M3Units.dp(NEON_GLOW_STROKE_EXTRA_DP)
		RenderingServer.canvas_item_add_polyline(_ring_item, points, halo_colors, halo_width, true)
		var head_halo := _ring_style.shadow_color
		if gradient_enabled:
			head_halo = colors[ORBIT_POINTS - 1]
			head_halo.a *= glow_intensity * 0.65
		RenderingServer.canvas_item_add_circle(_ring_item, points[ORBIT_POINTS - 1], halo_width * 0.5, head_halo)
	RenderingServer.canvas_item_add_polyline(_ring_item, points, colors, width, true)
	# Round nose on the comet head (polylines end in butt caps).
	RenderingServer.canvas_item_add_circle(_ring_item, points[ORBIT_POINTS - 1], width * 0.5, colors[ORBIT_POINTS - 1])

func _draw_corners(rect: Rect2, radius: float) -> void:
	var width := M3Units.dp(stroke_width_dp)
	if width <= 0.0:
		return
	# Match the shader/full-ring centerline. The caller already grew the rect
	# by half the stroke, so no further inset is needed.
	var r := rect
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	radius = minf(radius, minf(r.size.x, r.size.y) * 0.5)
	# Each straight edge is shared by the ticks of two corners; budget half to
	# each so neighboring corners can never overlap on small/circular controls.
	var straight_w := maxf(0.0, r.size.x - 2.0 * radius)
	var straight_h := maxf(0.0, r.size.y - 2.0 * radius)
	var tick := minf(M3Units.dp(corner_tick_dp), minf(straight_w, straight_h) * 0.5)
	# Near-circular controls have no straight edge for ticks; shrink the arc
	# sweep instead so the four corners stay visually separated.
	var sweep := PI * 0.5
	if tick < 1.0:
		sweep *= 0.7
	# Border color was already set by _redraw_ring (dimmed during CHASE idle).
	var colors := PackedColorArray([_ring_style.border_color])
	# Per corner: arc center, start angle, tick direction at start, tick dir at end.
	var corners := [
		[r.position + Vector2(radius, radius), PI, Vector2(0, 1), Vector2(1, 0)],
		[Vector2(r.end.x, r.position.y) + Vector2(-radius, radius), PI * 1.5, Vector2(-1, 0), Vector2(0, 1)],
		[r.end - Vector2(radius, radius), 0.0, Vector2(0, -1), Vector2(-1, 0)],
		[Vector2(r.position.x, r.end.y) + Vector2(radius, -radius), PI * 0.5, Vector2(1, 0), Vector2(0, -1)],
	]
	# Tessellate arcs by arc length (physical px) so large corners stay smooth
	# while small ones stay cheap.
	const SEGMENT_TARGET_PX := 4.0
	const SEGMENTS_MIN := 4
	const SEGMENTS_MAX := 48
	var segments := clampi(int(ceil(radius * sweep / SEGMENT_TARGET_PX)), SEGMENTS_MIN, SEGMENTS_MAX)
	var gradient_enabled := color_mode == ColorMode.GRADIENT
	var palette: Array[Color] = []
	if gradient_enabled:
		palette = _current_gradient_palette()
	for c in corners:
		var center: Vector2 = c[0]
		# Center the (possibly shrunk) sweep on the corner bisector.
		var a0: float = c[1] + (PI * 0.5 - sweep) * 0.5
		var a1: float = a0 + sweep
		var p0 := center + Vector2(cos(a0), sin(a0)) * radius
		var p1 := center + Vector2(cos(a1), sin(a1)) * radius
		var points := PackedVector2Array()
		points.append(p0 + c[2] * tick)
		for i in range(segments + 1):
			var a := lerpf(a0, a1, float(i) / float(segments))
			points.append(center + Vector2(cos(a), sin(a)) * radius)
		points.append(p1 + c[3] * tick)
		var point_colors := PackedColorArray()
		for point in points:
			var color := colors[0]
			if gradient_enabled:
				var perimeter_t := _perimeter_progress_at_point(r, radius, point)
				color = _sample_gradient(palette, _gradient_spatial_t(perimeter_t))
				color.a = colors[0].a
			point_colors.append(color)
		RenderingServer.canvas_item_add_polyline(_ring_item, points, point_colors, width, true)
		# Polylines have butt caps; stamp circles on the tips for pill ends.
		RenderingServer.canvas_item_add_circle(_ring_item, points[0], width * 0.5, point_colors[0])
		RenderingServer.canvas_item_add_circle(_ring_item, points[points.size() - 1], width * 0.5, point_colors[point_colors.size() - 1])

# ============================================================================
# Animation
# ============================================================================

func _start_chase() -> void:
	_kill_chase_tween()
	var from_rect := _ring_rect
	var from_radius := _ring_radius
	_chase_tween = create_tween()
	_chase_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_chase_tween.set_ease(M3Motion.EASE_ENTER)
	_chase_tween.tween_method(_apply_chase_pose.bind(from_rect, from_radius), 0.0, 1.0, chase_duration)
	_chase_tween.finished.connect(_on_chase_finished)

func _apply_chase_pose(t: float, from_rect: Rect2, from_radius: float) -> void:
	# Destination is read live: cards re-stamp their target pose mid-flight
	# (focus-pop scale, grid scroll) and the chase must track, not restart.
	_ring_rect = Rect2(from_rect.position.lerp(_dest_rect.position, t), from_rect.size.lerp(_dest_rect.size, t))
	_ring_radius = lerpf(from_radius, _dest_radius, t)
	_redraw_ring()

func _on_chase_finished() -> void:
	_ring_rect = _dest_rect
	_ring_radius = _dest_radius
	_redraw_ring()

func _kill_chase_tween() -> void:
	if _chase_tween and _chase_tween.is_valid():
		_chase_tween.kill()
	_chase_tween = null

func _start_pop() -> void:
	_kill_pop_tween()
	_pop_scale = POP_START_SCALE
	_pop_tween = create_tween()
	_pop_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_pop_tween.set_ease(M3Motion.EASE_ENTER)
	_pop_tween.tween_method(_apply_pop_scale, POP_START_SCALE, 1.0, POP_DURATION)

func _apply_pop_scale(scale_factor: float) -> void:
	_pop_scale = scale_factor
	_redraw_ring()

func _kill_pop_tween() -> void:
	if _pop_tween and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = null

func _restart_idle() -> void:
	_stop_idle()
	if not _ring_visible:
		return
	_orbit_last_redraw_ms = 0
	_gradient_last_update_ms = 0
	match idle_anim:
		IdleAnim.BREATHE:
			_idle_tween = create_tween().set_loops()
			_idle_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_idle_tween.tween_method(_set_ring_alpha, 1.0, BREATHE_MIN_ALPHA, BREATHE_PERIOD * 0.5)
			_idle_tween.tween_method(_set_ring_alpha, BREATHE_MIN_ALPHA, 1.0, BREATHE_PERIOD * 0.5)
		IdleAnim.CHASE:
			_idle_tween = create_tween().set_loops()
			_idle_tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
			_idle_tween.tween_method(_set_orbit_t, 0.0, 1.0, ORBIT_PERIOD)
	if color_mode != ColorMode.GRADIENT:
		return
	match gradient_anim:
		GradientAnim.EVOLVE:
			_gradient_tween = create_tween().set_loops()
			_gradient_tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
			_gradient_tween.tween_method(_set_gradient_t, 0.0, 1.0, GRADIENT_EVOLVE_PERIOD)
		GradientAnim.CHASE:
			# An active alpha comet already owns the shared orbit phase.
			if idle_anim != IdleAnim.CHASE:
				_gradient_tween = create_tween().set_loops()
				_gradient_tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
				_gradient_tween.tween_method(_set_orbit_t, 0.0, 1.0, ORBIT_PERIOD)

func _stop_idle() -> void:
	if _idle_tween and _idle_tween.is_valid():
		_idle_tween.kill()
		_idle_tween = null
	if _gradient_tween and _gradient_tween.is_valid():
		_gradient_tween.kill()
		_gradient_tween = null
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_ring_item, Color.WHITE)
	if _neon_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_neon_item, Color.WHITE)
	if _ring_style:
		_apply_style()

## Public wrappers so main.gd can suspend the idle ring animation when the
## window loses focus (rendering is suspended, so the loop would run invisibly)
## and resume it on refocus. _restart_idle() already no-ops when the ring is
## hidden.
func suspend_idle_animation() -> void:
	_stop_idle()

func resume_idle_animation() -> void:
	_restart_idle()

func _set_ring_alpha(alpha: float) -> void:
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_ring_item, Color(1.0, 1.0, 1.0, alpha))
	if _neon_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_neon_item, Color(1.0, 1.0, 1.0, alpha))

var _orbit_last_redraw_ms: int = 0
var _gradient_last_update_ms: int = 0
## Direct-drawn paths still re-tessellate on tween ticks; ~30Hz is visually
## indistinguishable and bounds PackedArray churn. Shader-only gradient motion
## updates uniforms in place and leaves the existing draw geometry untouched.
const ANIMATION_UPDATE_INTERVAL_MS: int = 33

func _set_orbit_t(t: float) -> void:
	_orbit_t = t
	var now := Time.get_ticks_msec()
	if now - _orbit_last_redraw_ms < ANIMATION_UPDATE_INTERVAL_MS:
		return
	_orbit_last_redraw_ms = now
	if idle_anim == IdleAnim.CHASE or _ring_shape == Shape.CORNERS:
		_redraw_ring()
	elif color_mode == ColorMode.GRADIENT and gradient_anim == GradientAnim.CHASE:
		_update_gradient_material()

func _set_gradient_t(t: float) -> void:
	_gradient_t = t
	var now := Time.get_ticks_msec()
	if now - _gradient_last_update_ms < ANIMATION_UPDATE_INTERVAL_MS:
		return
	_gradient_last_update_ms = now
	if _ring_shape == Shape.CORNERS:
		_redraw_ring()
	else:
		_update_gradient_material()

# ============================================================================
# Config
# ============================================================================

func _on_config_changed() -> void:
	config_changed.emit()
	if _ring_style == null:
		return
	_apply_style()
	var t := _get_target()
	if t and _ring_visible:
		var geo := _resolve_geometry(t)
		_dest_rect = geo.rect
		_dest_radius = geo.radius
		_dest_shape = geo.shape
		_ring_rect = _dest_rect
		_ring_radius = _dest_radius
		_ring_shape = _dest_shape
		_apply_color(geo)
		_redraw_ring()
		_restart_idle()
