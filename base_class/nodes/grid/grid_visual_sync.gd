class_name GridVisualSync
extends Node

const FocusedTitlePill = preload("res://base_class/nodes/grid/grid_focused_title_pill.gd")

## Owns the grid's top-level visual layer and the per-frame visual stamping
## pipeline: layer-space offset computation, pre-draw stamping, the
## reveal-on-sort gate, the scroll-completed rest stamp, and the visual draw
## order. Reads grid state (scroll container, margins, window membership,
## layout generation) via the backref; the layout generation itself stays
## grid-owned (bumped in the grid's sort handlers before delegating here).
## Connects/disconnects its own RenderingServer.frame_pre_draw connection
## (children _exit_tree before the parent, so teardown is safe).

var _grid: VirtualScrollGridContainer = null

## Top-level layer the cards' RS items render into (draws outside the grid's
## bounds without being clipped by margins or scroll).
var layer: Control = null
var _focused_title_layer: Control = null
var _focused_title_pill: GridFocusedTitlePill = null
var _pill_draw_index: int = -1

## Position of the flow's content origin within the margin container, captured
## post-sort from Godot's own container results (center position + flow
## position). Scroll-independent, so capturing it on sort is race-free: during
## scroll only the scroll offset moves, which we track separately as a float.
var _content_chain_offset := Vector2.ZERO

# Skip-stamp cache: the pre-draw loop is skipped when nothing feeding the
# offset math changed since the last stamp (idle frames far outnumber scroll
# frames).
var _last_stamp_scroll: float = -1.0
var _last_stamp_margin: int = -1
var _last_stamp_first: int = -1
var _last_stamp_count: int = -1
var _last_stamp_generation: int = -1
var _last_stamp_scroll_origin := Vector2.INF
var _last_stamp_layer_origin := Vector2.INF
var _last_stamp_chain := Vector2.INF

# Reveal-on-sort gate: cards stay hidden until the FlowContainer sort commits
# their positions, then are stamped + marked exactly once (at pre-draw, after
# the whole sort cascade).
var _reveal_pending: bool = false
var _reveal_requested_frame: int = -1

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func _ready() -> void:
	# One-time setup: the layer persists across tree re-entries (DS reparents,
	# nav rebuilds).
	if not layer:
		layer = Control.new()
		layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
		layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		layer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.clip_contents = false
		layer.z_index = -1
		layer.top_level = true
		# The layer MUST be a child of the grid (a CanvasItem), not of this
		# module (a plain Node): engine visibility propagation only recurses
		# into CanvasItem children, and because the layer is top_level its
		# canvas item is re-rooted to the viewport — scene-tree propagation is
		# the ONLY thing that ever hides it. Under a Node parent the layer
		# stayed visible forever when the owning view's tab hid, leaving the
		# last stamped card art frozen behind the newly shown view.
		# (Container layout skips top_level children, so the grid does not
		# fight the layer's rect.)
		_grid.add_child(layer)
		layer.position = Vector2.ZERO
		layer.size = get_viewport().get_visible_rect().size
		# The pill needs a separate, higher canvas subtree: the card layer is
		# deliberately behind grid chrome, while the title must float above it.
		_focused_title_layer = Control.new()
		_focused_title_layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_focused_title_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_focused_title_layer.clip_contents = false
		_focused_title_layer.top_level = true
		_focused_title_layer.z_as_relative = false
		_focused_title_layer.z_index = OverlayLayers.TOOLBAR_Z + 20
		_grid.add_child(_focused_title_layer)
		_focused_title_layer.position = Vector2.ZERO
		_focused_title_layer.size = layer.size
		_focused_title_pill = FocusedTitlePill.new()
		_focused_title_layer.add_child(_focused_title_pill)
		_focused_title_pill.set_visual_layer(_focused_title_layer)

func _enter_tree() -> void:
	# _ready fires only once per node lifetime, so the reconnect must live
	# here: _exit_tree disconnects, and tree re-entries (DS reparents, nav
	# rebuilds) would otherwise leave the stamping loop dead for this grid
	# instance.
	if not RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)

func _exit_tree() -> void:
	_hide_focused_title_pill()
	if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)

## Keep the top-level layer pinned to the viewport (called on resize and
## display-size changes so the layer never holds a stale viewport rect).
func resize_to_viewport() -> void:
	# Query the viewport through the grid, not self: during the grid's
	# _enter_tree (nav-rebuild reparent) _enter_tree fires parent-first, so
	# this module hasn't re-entered yet and self.get_viewport() is null.
	if layer and layer.top_level and _grid.is_inside_tree():
		layer.position = Vector2.ZERO
		layer.size = _grid.get_viewport().get_visible_rect().size
	if _focused_title_layer and _focused_title_layer.top_level and _grid.is_inside_tree():
		_focused_title_layer.position = Vector2.ZERO
		_focused_title_layer.size = _grid.get_viewport().get_visible_rect().size

func configure_card(card: Control) -> void:
	if card.has_method("set_visual_layer"):
		card.set_visual_layer(layer)

func _hide_focused_title_pill() -> void:
	if is_instance_valid(_focused_title_pill):
		_focused_title_pill.hide_pill()

## Keep the single title pill bound to the actual focused GameCard. This runs
## even when card stamping is idle so focus-scale tweens still move the bubble.
func _sync_focused_title_pill() -> void:
	if not is_instance_valid(_focused_title_pill) or not _focused_title_layer:
		return
	var state = UIManager.card_settings_state if UIManager else null
	if not state or not state.text_focused_only or not _grid.is_visible_in_tree() or _grid._active_cards.is_empty():
		_hide_focused_title_pill()
		return

	var focused_index := _grid._focus.focused_virtual_index()
	var card = _grid._active_cards_by_index.get(focused_index, null)
	if not is_instance_valid(card) or not card is GameCard or not card.game:
		_hide_focused_title_pill()
		return
	var title: String = card.game.title
	if title.is_empty():
		_hide_focused_title_pill()
		return

	var geometry: Dictionary = card.m3_get_media_render_geometry()
	var media_rect: Rect2 = geometry.get("rect", Rect2())
	if media_rect.size.x <= 0.0 or media_rect.size.y <= 0.0:
		_hide_focused_title_pill()
		return

	var margin := M3Units.dp(8.0)
	var gap := M3Units.dp(10.0)
	var viewport_max := maxf(M3Units.dp(32.0), _focused_title_layer.size.x - margin * 2.0)
	# Width is based on the unscaled media so it does not breathe with the
	# focus tween; the anchor rect below does include the current focus scale.
	var max_width := minf(maxf(M3Units.dp(32.0), card._media_bounds.size.x), viewport_max)
	_focused_title_pill.configure(title, max_width, state.text_alignment, state.scroll_truncation)

	var pill_size := _focused_title_pill.custom_minimum_size
	var x := media_rect.get_center().x - pill_size.x * 0.5
	x = clampf(x, margin, maxf(margin, _focused_title_layer.size.x - pill_size.x - margin))
	var tail_height := _focused_title_pill.get_tail_height()
	var tail_points_down := true
	var tail_visible := true
	var y := media_rect.position.y - pill_size.y - tail_height - gap
	if y < margin:
		tail_points_down = false
		y = media_rect.end.y + gap + tail_height
		if y + pill_size.y > _focused_title_layer.size.y - margin:
			# Very tall cards can lack external space on both sides. Keep the
			# title readable as an overlay just inside the media's top edge.
			tail_visible = false
			y = maxf(margin, media_rect.position.y + gap)
	_focused_title_pill.set_tail_state(tail_points_down, tail_visible)

	var draw_index: int = card.m3_get_focus_draw_index() + 1
	if draw_index != _pill_draw_index:
		_pill_draw_index = draw_index
		_focused_title_pill.set_visual_draw_index(draw_index)
	var pill_position := Vector2(x, y)
	_focused_title_pill.position = pill_position
	_focused_title_pill.sync_visual_transform_with_offset(pill_position)
	_focused_title_pill._mark_visuals_position_synced()
	_focused_title_pill.show_pill()

func update_pagination_opacity() -> void:
	if _grid._active_cards.is_empty() or not _grid._card_has_visual_layer_opacity:
		return
	var current_page := -1
	if _grid._is_pagination_active() and _grid._scroll_container:
		_grid._sync_geometry()
		var period: float = _grid._geometry.page_period()
		if period > 0.0:
			var scroll_pos := _grid._scroll_container.get_scroll_float()
			current_page = clampi(int(round(scroll_pos / period)), 0, _grid._geometry.page_count() - 1)
	for card in _grid._active_cards:
		if not is_instance_valid(card):
			continue
		var opacity := 1.0
		if current_page >= 0:
			var idx: int = card.get_meta("virtual_index", -1)
			if idx >= 0 and _grid._geometry.page_for_index(idx) != current_page:
				opacity = _grid.PAGINATION_NEIGHBOR_OPACITY
		card.set_visual_layer_opacity(opacity)

func on_scroll_completed() -> void:
	"""Stamp all cards against the final rest position. The terminal write of
	a tween/chase can land without any further drawn frame (idle tree, nothing
	dirty), which would leave the pre-draw stamps frozen at the last motion
	frame's float position. A pure scroll landing queues no sort cascade
	(card positions are scroll-independent; scroll enters the offset formula
	directly), so stamping here is immediately correct. Reveal marking stays
	pre-draw gated."""
	if not _grid._card_has_sync_visual_offset or not _grid._scroll_container or not layer:
		return
	if _grid._active_cards.size() == 0:
		return
	_last_stamp_scroll = _grid._scroll_container.get_scroll_float()
	_last_stamp_margin = _grid._last_margin_top if _grid.vertical else _grid._last_margin_left
	_last_stamp_first = _grid._active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_grid._active_cards[0]) else -1
	_last_stamp_count = _grid._active_cards.size()
	_last_stamp_generation = _grid._layout_generation
	var context := _capture_offset_context()
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		card.sync_visual_transform_with_offset(compute_offset(card, context))
	update_pagination_opacity()
	_sync_focused_title_pill()

func _on_frame_pre_draw() -> void:
	# Stamp visual offsets at the last moment before render, from pure
	# container arithmetic. At pre-draw time the scroll value, margin cache and
	# window membership are all final for the frame, so the stamps are
	# render-fresh by construction — independent of sort/flush/deferred order.
	if not _grid or not _grid._card_has_sync_visual_offset or not _grid._scroll_container or not layer:
		_hide_focused_title_pill()
		return
	# Hidden grids (inactive view tabs) don't draw — stamping is wasted work
	# and, worse, consumes a pending reveal while invisible. The skip-cache is
	# untouched while hidden, so the first pre-draw after re-show detects the
	# interruption and stamps/marks before that frame renders (no flash).
	if not _grid.is_visible_in_tree():
		_hide_focused_title_pill()
		return
	if _grid._active_cards.size() == 0:
		_hide_focused_title_pill()
		return
	# Skip the stamp loop entirely when nothing that feeds the offset math
	# changed since the last stamp (idle frames far outnumber scroll frames).
	# Track the FLOAT motion model, not the int scrollbar: during tween/chase
	# tails the int can sit still for frames while the float keeps gliding —
	# skipping on the int would freeze the visual layer mid-glide.
	var scroll_now: float = _grid._scroll_container.get_scroll_float()
	var margin_now: int = _grid._last_margin_top if _grid.vertical else _grid._last_margin_left
	var first_now: int = _grid._active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_grid._active_cards[0]) else -1
	var context := _capture_offset_context()
	var origins_unchanged: bool = context.scroll_origin.is_equal_approx(_last_stamp_scroll_origin) \
		and context.layer_origin.is_equal_approx(_last_stamp_layer_origin) \
		and context.chain.is_equal_approx(_last_stamp_chain)
	if not _reveal_pending and origins_unchanged and scroll_now == _last_stamp_scroll and margin_now == _last_stamp_margin and first_now == _last_stamp_first and _grid._active_cards.size() == _last_stamp_count and _grid._layout_generation == _last_stamp_generation:
		_sync_focused_title_pill()
		return
	# A pending reveal means a sort cascade is (or was) in flight. Pre-draw runs
	# after the ENTIRE cascade (margin -> center -> flow), so positions and the
	# chain are final here — this is the only stamp that may also MARK cards
	# visible: marking from mid-cascade states (e.g. on_flow_sorted) flashed a
	# whole-strip offset by the margin delta for a frame.
	var do_reveal: bool = _reveal_pending
	_reveal_pending = false
	_reveal_requested_frame = -1
	_last_stamp_scroll = scroll_now
	_last_stamp_margin = margin_now
	_last_stamp_first = first_now
	_last_stamp_count = _grid._active_cards.size()
	_last_stamp_generation = _grid._layout_generation
	_last_stamp_scroll_origin = context.scroll_origin
	_last_stamp_layer_origin = context.layer_origin
	_last_stamp_chain = context.chain
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var expected_offset := compute_offset(card, context)
		card.sync_visual_transform_with_offset(expected_offset)
		if do_reveal and _grid._card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()
	update_pagination_opacity()
	_sync_focused_title_pill()

func _capture_offset_context() -> Dictionary:
	# Loop-invariant inputs are captured once per stamp, not queried again for
	# every card. They are also part of the dirty key so ancestor-only motion
	# invalidates the cache even when no scroll/layout event occurs.
	var chain := _content_chain_offset
	if _grid._center_container and _grid._flow_container:
		chain = _grid._center_container.position + _grid._flow_container.position
	return {
		"scroll_origin": _grid._scroll_container.get_global_rect().position if _grid._scroll_container else Vector2.ZERO,
		"scroll_float": _grid._scroll_container.get_scroll_float() if _grid._scroll_container else 0.0,
		"chain": chain,
		"layer_origin": layer.global_position,
	}

func compute_offset(card: Control, context: Dictionary = {}) -> Vector2:
	"""Layer-space offset for a card — ONE deterministic source of truth.

	Composed entirely from Godot's own layout results plus the precisely
	tracked float scroll:
		scroll_container.origin − scroll_float + content_chain + card.position
	where `content_chain` is the flow's offset within the margin container
	(captured post-sort) and `card.position` is the FlowContainer's own child
	position. Every card on a line goes through the identical formula, so no
	column can diverge, and reading it never depends on mid-frame transform
	flushes (only the scroll float moves during scrolling, and we track it).
	"""
	if context.is_empty():
		context = _capture_offset_context()
	var layer_origin: Vector2 = context.layer_origin
	var vidx: int = card.get_meta("virtual_index", -1)
	if vidx < 0 or not _grid._scroll_container or not _grid._flow_container:
		return card.global_position - layer_origin
	var scroll_f: float = context.scroll_float
	var scroll_vec := Vector2(scroll_f, 0.0) if not _grid.vertical else Vector2(0.0, scroll_f)
	return context.scroll_origin - scroll_vec + context.chain + card.position - layer_origin

func stamp_and_mark(_tag: String = "", mark: bool = true) -> void:
	var use_offsets: bool = _grid._card_has_sync_visual_offset and _grid._scroll_container and layer
	var context := _capture_offset_context() if use_offsets else {}
	for card in _grid._active_cards:
		if not is_instance_valid(card):
			continue
		# Don't mark cards before _ready() has run; _setup_rs_items() resets the
		# synced flag, so marking earlier would be silently undone.
		if not card.is_node_ready():
			continue
		if use_offsets:
			card.sync_visual_transform_with_offset(compute_offset(card, context))
		elif _grid._card_has_sync_visual_transform:
			card.sync_visual_transform()
		# When mark=false (pre-sort passes), newly added cards keep their RS
		# items hidden until the deferred post-sort mark, so a stale pooled
		# position can never reach the screen even if the heal slips a frame.
		if mark and _grid._card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()
	update_pagination_opacity()
	_sync_focused_title_pill()

## Capture the content chain post-sort (called from the grid's sort handlers
## after they bump the layout generation).
func on_content_sorted() -> void:
	if _grid._center_container and _grid._flow_container:
		_content_chain_offset = _grid._center_container.position + _grid._flow_container.position

## Request reveal-on-sort: cards stay hidden until the FlowContainer sort
## commits their positions, then are stamped + marked exactly once.
func request_reveal() -> void:
	_reveal_pending = true
	_reveal_requested_frame = Engine.get_process_frames()
	if _grid._flow_container:
		_grid._flow_container.queue_sort()

## The sort committed new FLOW child positions, but the container cascade may
## still be mid-flight: queued sorts flush in message-queue order, so the
## MARGIN/CENTER re-sorts (which move center.position via the new margins)
## can run AFTER this flow sort. Stamping now would mix the new child
## positions with the old chain — a whole-strip offset by the margin delta
## (one card pitch) flashing for a frame. The reveal therefore defers to
## _on_frame_pre_draw, which runs after the ENTIRE cascade, before render.
func on_flow_sorted_post() -> void:
	if _reveal_pending:
		_reveal_requested_frame = Engine.get_process_frames()

func has_reveal_pending() -> bool:
	return _reveal_pending

## Reveal fallback: if a sort never consumed the pending reveal (hidden view,
## container quirk), reveal after 3 frames rather than leaving cards hidden.
func check_reveal_fallback() -> void:
	if _reveal_pending and _reveal_requested_frame >= 0 \
		and Engine.get_process_frames() > _reveal_requested_frame + 3:
		_reveal_pending = false
		_reveal_requested_frame = -1
		stamp_and_mark("reveal-fallback", true)

func update_draw_order() -> void:
	# The grid owns only slot order. M3Card exclusively owns the focused-card
	# boost, and FocusSubManager derives the ring position from that same value.
	for card in _grid._active_cards:
		if not card.has_method("set_visual_draw_index"):
			continue
		var idx = card.get_meta("virtual_index", 0)
		card.set_visual_draw_index(idx * 10)
