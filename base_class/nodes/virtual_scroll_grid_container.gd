class_name VirtualScrollGridContainer
extends Control

const DEBUG_LOG: bool = false
const CoverTrace = preload("res://utils/cover_trace.gd")

# Global startup guard: suppresses all layout work until Main is ready for the
# single final settle. This prevents visible "jank" from layout passes before
# the saved window size and saved zoom are stable.
static var startup_layout_suppressed: bool = true

## Card capability probes live in GridCardPool.probe_capabilities (static,
## cached per scene path, shared across all grids).

# Libraries below this size load all cards at once to avoid partial-row recycling
# edge cases. Above this threshold only visible cards plus a buffer are created.
const SMALL_LIBRARY_THRESHOLD: int = 50

# Single-request batch cap lives in GridDataCache.MAX_REQUEST_ITEMS.

signal items_requested(offset, limit)
# Emitted from GridWindowManager (via this instance) and connected by views;
# not referenced inside this class itself.
@warning_ignore("unused_signal")
signal visible_range_changed(start, end, total)
@warning_ignore("unused_signal")
signal item_created(item, index)
## Emitted at the end of set_total_count. The startup settle in main.gd waits
## on this (same-frame wakeup) instead of polling per frame while the
## cold-cache count load is in flight.
signal total_count_applied(count)

@export var card_scene: PackedScene
@export var data_buffer_multiplier: int = 5
@export var data_preload_multiplier: int = 3
@export var visual_buffer_lines: int = 4
@export var debug_mode: bool = false:
	set(value):
		if debug_mode != value:
			debug_mode = value
			_update_debug_mode()
## Gates the high-frequency per-pass trace prints ([GridTrace] pass/pass-end)
## so diagnostics stop inflating frame time. Violation logs
## ([GridInv], [VisHole], [CardApply], [RsAudit], [LayerAudit]) always print.
var trace_verbose: bool = false
enum ViewMode { GRID, LIST, CAROUSEL }
enum FocusCentering { MARGIN, CENTER }

@export var view_mode: ViewMode = ViewMode.GRID:
	set(value):
		if _batching_layout:
			view_mode = value
			return
		if view_mode != value:
			view_mode = value
			_update_view_mode()

# Grid orientation toggle. Only affects GRID mode; LIST is always vertical, CAROUSEL always horizontal.
var grid_vertical: bool = true:
	set(value):
		if _batching_layout:
			grid_vertical = value
			return
		if value == grid_vertical:
			return
		grid_vertical = value
		if _ready_called and view_mode == ViewMode.GRID:
			_update_view_mode()
			refresh_dimensions()
			queue_redraw()

## Batch-apply grid orientation settings to avoid redundant rebuilds.
## Call this instead of setting view_mode/grid_vertical/focus_scale individually.
func set_grid_orientation(p_view_mode: ViewMode, p_grid_vertical: bool, p_focus_scale: float) -> void:
	var needs_refresh: bool = _apply_view_mode_and_vertical(p_view_mode, p_grid_vertical)
	needs_refresh = _apply_focus_scale(p_focus_scale) or needs_refresh

	if needs_refresh:
		_refresh_buffer(true)
		refresh_dimensions()
		queue_redraw()

# Layout-application helpers: mutate state without emitting side effects, returning true if changed.
# Used by set_grid_orientation and _batch_apply_layout_state to coalesce layout recalculations.
func _apply_view_mode_and_vertical(p_view_mode: ViewMode, p_grid_vertical: bool) -> bool:
	var changed: bool = false
	if view_mode != p_view_mode:
		_batching_layout = true
		view_mode = p_view_mode
		_batching_layout = false
		_configure_view_mode()
		changed = true
	if grid_vertical != p_grid_vertical:
		_batching_layout = true
		grid_vertical = p_grid_vertical
		_batching_layout = false
		if view_mode == ViewMode.GRID:
			_configure_view_mode()
		changed = true
	return changed

func _apply_focus_scale(p_focus_scale: float) -> bool:
	var clamped_scale: float = maxf(p_focus_scale, 1.0)
	if is_equal_approx(focus_scale, clamped_scale):
		return false
	_batching_layout = true
	focus_scale = clamped_scale
	_batching_layout = false
	return true

func _apply_zoom_ratio(p_ratio: float) -> bool:
	_sync_zoom_model_inputs()
	# During startup suppression the model does NOT snap the saved zoom to the
	# current container size, because non-active grids can have a temporary
	# small size and would snap to the wrong stop. The final snap happens once
	# when the grid is explicitly settled after the window size is stable.
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _apply_zoom_ratio: p_ratio=", p_ratio, " current_target=", target_card_width_ratio, " suppressed=", startup_layout_suppressed)
	# GRID: snapshot the scroll anchor BEFORE N changes (see _scroll_anchor).
	if view_mode == ViewMode.GRID and not startup_layout_suppressed and _has_valid_available_size():
		_scroll_anchor = _capture_scroll_anchor(_focus.focused_virtual_index())
	return _zoom_model.set_ratio(p_ratio)

func _apply_grid_padding(p_padding: int) -> bool:
	var new_separation: int = int(M3Units.dp(float(p_padding)))
	if grid_separation != new_separation:
		grid_separation = new_separation
		if _flow_container:
			_flow_container.add_theme_constant_override("h_separation", grid_separation)
			_flow_container.add_theme_constant_override("v_separation", grid_separation)
		return true
	return false

func _batch_apply_layout_state() -> void:
	"""Apply all LAYOUT-affecting CardSettingsState fields in one pass.
	For structure changes this results in exactly one _recalculate_layout() call."""
	if not UIManager or not UIManager.card_settings_state:
		return
	var state = UIManager.card_settings_state

	var new_mode: ViewMode
	match state.layout_mode:
		0: new_mode = ViewMode.GRID
		1: new_mode = ViewMode.LIST
		2: new_mode = ViewMode.CAROUSEL
		_: new_mode = ViewMode.GRID

	# Apply structure first so zoom/padding math uses the correct geometry.
	# Then apply padding before zoom because separation affects available space.

	var structure_changed: bool = _apply_view_mode_and_vertical(new_mode, state.grid_vertical)
	var padding_changed: bool = _apply_grid_padding(state.grid_padding)
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _batch_apply_layout_state before zoom: target_ratio=", target_card_width_ratio, " base_size=", base_card_size, " card_size=", card_size, " state.zoom=", state.card_zoom_ratio, " state.level=", state.card_zoom_level)
	var zoom_changed: bool
	if new_mode == ViewMode.GRID:
		if state.card_zoom_level >= 0:
			zoom_changed = _apply_zoom_level(state.card_zoom_level)
		else:
			zoom_changed = _apply_zoom_ratio(state.card_zoom_ratio)
	else:
		# LIST/CAROUSEL have their own per-mode zoom ratio.
		zoom_changed = _apply_zoom_ratio(state.card_zoom_list_ratio)
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _batch_apply_layout_state after zoom: target_ratio=", target_card_width_ratio, " zoom_changed=", zoom_changed, " card_size=", card_size)
	var focus_changed: bool = _apply_focus_scale(1.0 + state.focus_scale_ratio)
	# Apply the flag (also converged in _refresh_cached_settings), but detect
	# changes against the layout-applied cache: it reflects what is actually
	# built (spacers, snap state), not what flag is set.
	pagination_enabled = state.pagination_enabled
	staggered = state.grid_staggered
	var pagination_changed: bool = pagination_enabled != _last_layout_pagination
	var staggered_changed: bool = staggered != _last_layout_staggered

	if not structure_changed and not zoom_changed and not padding_changed and not focus_changed and not pagination_changed and not staggered_changed:
		if debug_mode: print("[Grid] _batch_apply_layout_state: no changes (structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed, " pagination=", pagination_changed, " staggered=", staggered_changed, ")")
		return

	if debug_mode:
		if DEBUG_LOG: print("[Grid] _batch_apply_layout_state: structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed, " pagination=", pagination_changed, " staggered=", staggered_changed)

	if structure_changed:
		# One rebuild path: configure flags then refresh buffer, which recalculates layout.
		_refresh_buffer(true)
		queue_redraw()
	else:
		# Non-structure changes share the same rebuild path to guarantee a single recalc.
		if focus_changed or padding_changed or pagination_changed or staggered_changed:
			_refresh_buffer(true)
		elif zoom_changed:
			_recalculate_layout()

# Computed scroll axis: GRID respects grid_vertical; LIST is vertical; CAROUSEL is horizontal.
var vertical: bool:
	get:
		match view_mode:
			ViewMode.GRID:
				return grid_vertical
			ViewMode.LIST:
				return true
			ViewMode.CAROUSEL:
				return false
		return true

const BASE_CARD_WIDTH_DP: float = 202.0
const BASE_CARD_HEIGHT_DP: float = 270.0
const BASE_LIST_HEIGHT_DP: float = 120.0
const BASE_CAROUSEL_WIDTH_DP: float = 280.0

const _MEDIA_BASE_WIDTH_DP: float = 200.0

const _RATIO_LOOKUP: Array[float] = [
	-1.0,        # 0 = Fill
	2.0 / 3.0,   # 1 = 2:3  (width/height)
	3.0 / 4.0,   # 2 = 3:4
	1.0,         # 3 = 1:1
	16.0 / 11.0, # 4 = 16:11
]

# Grid separation (padding) - loaded from settings, defaults to 10 DP
var grid_separation: int = int(M3Units.dp(10))

# Universal outer margin: insets the scroll container (and the effective
# viewport for all layout math) on all four sides. Internal for now.
const GRID_OUTER_MARGIN_DP := 22.0
var grid_outer_margin: int = 0

## When true (GRID mode only), the grid is split into viewport-sized pages
## separated by spacer lines in the flow; scrolling snaps between pages.
var pagination_enabled: bool = false
## Scroll-axis amount of the adjacent page visible at a snapped page position.
const PAGINATION_PREVIEW_DP := 24.0
## Opacity of adjacent-page cards; the page nearest the snap target stays opaque.
const PAGINATION_NEIGHBOR_OPACITY := 0.35

## When true (vertical GRID only), every other row is offset by half a card
## width (brick pattern); offset rows hold one fewer card via a leading
## half-cell spacer in the flow.
var staggered: bool = false

## Focus tracking, restore/release, and the focus-lock viewport connection
## (GridFocusController). The property facades below keep direct readers
## unchanged; the module owns the truth.
var _focus := GridFocusController.new(self)

func is_focus_locked_and_active() -> bool:
	"""Returns true if UIManager has locked focus to this grid."""
	return UIManager and UIManager.is_focus_lock_active()

# Scale factor applied when a card is focused. Cards scale UP from their normal size
# by this amount. Edge overflow is prevented by focus-safe container margins.
var focus_scale: float = 1.08:
	set(value):
		if _batching_layout:
			focus_scale = value
			return
		var clamped_scale = maxf(value, 1.0)
		if not is_equal_approx(focus_scale, clamped_scale):
			focus_scale = clamped_scale
			_recalculate_layout()
			_refresh_buffer(true)

## SINGLE owner of zoom structure: items-per-line N (GRID) or scroll-axis
## lines k (LIST/CAROUSEL). Every ratio/zoom/card-size figure is DERIVED from
## it; inputs (mode, orientation, separation, base dims, available size,
## startup suppression) are pushed via _sync_zoom_model_inputs() and its stop
## caches self-invalidate. Nothing else stores zoom state.
var _zoom_model := GridZoomModel.new()

## Read facades for tests/debug; writes go through the model's setters.
var _grid_items_per_line: int:
	get:
		return _zoom_model._n_grid
# Read by zoom drive tests; writes go through the zoom model.
@warning_ignore("unused_private_class_variable")
var _scroll_axis_lines: int:
	get:
		return _zoom_model._k_lines

## Push the zoom model's inputs. Cheap (key compare short-circuits); called
## at the top of every zoom facade so stale caches are impossible.
func _sync_zoom_model_inputs() -> void:
	_zoom_model.resolution_enabled = not startup_layout_suppressed
	_zoom_model.configure(int(view_mode), vertical, grid_separation, _get_base_dimensions_for_mode())
	_zoom_model.set_available_size(_get_available_size() if _has_valid_available_size() else Vector2.ZERO)

## SINGLE implementation of the line/slot/page offset formula (pinned by
## grid_offset_identity_test). Inputs are pushed per call (cheap field
## assignments); the math itself is pure and has no caches to invalidate.
var _geometry := GridGeometry.new()

func _sync_geometry() -> void:
	_geometry.mode = int(view_mode)
	_geometry.vertical = vertical
	_geometry.separation = grid_separation
	_geometry.staggered = _is_staggered_active()
	_geometry.paginated = _is_pagination_active()
	_geometry.page_preview = M3Units.dp(PAGINATION_PREVIEW_DP)
	_geometry.items_per_line = _get_items_per_line()
	_geometry.stride = _get_normal_stride()
	_geometry.card_scroll = card_size.y if vertical else card_size.x
	var overflow := _get_focus_overflow()
	_geometry.focus_overflow = overflow.y if vertical else overflow.x
	var available := _get_available_size()
	_geometry.viewport = available.y if vertical else available.x
	_geometry.total_items = _total_items

# Scroll anchor snapshot (null = unset). Captured by _set_grid_n_silent BEFORE
# items-per-line changes so _recalculate_layout can restore the view in index
# space; capturing after the N change would compute the anchor against the NEW
# items-per-line, which preserves the line number instead of the content
# (teleport on zoom). See GridScrollAnchor for the three slots.
var _scroll_anchor: GridScrollAnchor = null

# Scroll writes during layout recalcs go through
# SmoothScrollContainer.write_immediate_with_extent(): the extent is pre-raised
# to the grid-computed value so the stale mid-frame scrollbar range never
# clamps the write, and the single-writer ownership in SSC makes echo guards
# unnecessary.

## Scroll velocity (px/s) is owned by the SmoothScrollContainer (it owns the
## float motion model, so it owns the derivative too). This is the single
## read point; the EMA decays to exactly 0 at rest and discontinuous
## write_immediate jumps reset its baseline.
func _get_scroll_velocity() -> float:
	return _scroll_container.get_scroll_velocity() if _scroll_container else 0.0

# Cover-download suppression during fast scroll / A-Z scrubbing (Fix 4):
# while suppressed, cards render the placeholder for covers that aren't on
# disk instead of queueing network downloads; on release the visible
# placeholders retry. Prevents fast traversal from flooding the download
# queue (which manifests as queue-full drops and blank covers).
const FAST_SCROLL_SUPPRESS_STRIDES: float = 4.0  # px/s threshold = 4 row pitches
var _scrub_cover_suppressed: bool = false   # external: A-Z carousel drag
var _cover_dl_suppressed: bool = false      # effective state last applied
var _lp_gate_held: bool = false             # this grid holds the (refcounted) low-priority decode gate
var _cover_trace_last_mismatch_ms: int = 0
## Incremented on every completed full layout pass and every FlowContainer
## sort. Part of the visual sync's pre-draw stamp gate so stamps always
## follow layout changes even when scroll/margin/window didn't move.
var _layout_generation: int = 0
var _layout_settled_with_valid_size: bool = false
## Forces the next _recalculate_layout past its input-cache early-exit (set
## when a valid size first arrives after an invalid settle).
var _force_layout_once: bool = false

# The user-facing zoom ratio (e.g. 0.15 = card area ≈ 15%² of viewport for
# GRID; scroll-axis fill fraction for LIST/CAROUSEL). DERIVED from the zoom
# model's structure — there is no independently stored ratio. External writes
# resolve structure (GRID snaps N immediately; LIST/CAROUSEL re-resolve k on
# next layout) and run a layout pass.
var target_card_width_ratio: float:
	get:
		_sync_zoom_model_inputs()
		return _zoom_model.get_ratio()
	set(value):
		# Ensure cached display/ratio settings are fresh before snapping; direct
		# assignments from views can otherwise use stale base dimensions.
		_refresh_cached_settings()
		_sync_zoom_model_inputs()
		if debug_mode:
			if DEBUG_LOG: print("[Grid] setter target_card_width_ratio: input=", value, " max=", _zoom_model.get_max_ratio(), " suppressed=", startup_layout_suppressed)
		# GRID: snapshot the scroll anchor BEFORE N changes (see _scroll_anchor).
		if view_mode == ViewMode.GRID and not startup_layout_suppressed and _has_valid_available_size():
			_scroll_anchor = _capture_scroll_anchor(_focus.focused_virtual_index())
		_zoom_model.set_ratio(value)
		# _recalculate_layout() early-exits cheaply when nothing changed; callers
		# (e.g. refresh_dimensions) expect the setter to run a layout pass.
		_recalculate_layout()

# Computed zoom based on viewport size
var zoom: float = 1.0:
	get:
		return _calculate_zoom()
	set(value):
		push_warning("VirtualScrollGridContainer: Cannot set zoom directly. Set target_card_width_ratio instead.")

# Unified size vocabulary - single source of truth
var base_card_size: Vector2 = Vector2(BASE_CARD_WIDTH_DP, BASE_CARD_HEIGHT_DP)
var card_size: Vector2 = Vector2(212.0, 280.0)
var focused_card_size: Vector2 = Vector2(228.96, 302.4)

# Currently focused virtual index for dynamic stride math

# Cached focus-centering mode (synced from CardSettingsState)
var _focus_centering_mode: int = FocusCentering.MARGIN

# Focus target for an in-flight programmatic scroll-and-focus sequence.
# Cleared (and the scroll container's follow-focus suppression lifted) once the
# scroll settles; polled in _process().
var _programmatic_focus_index: int = -1

# When true, public setters suppress their side effects so _batch_apply_layout_state()
# can apply multiple inputs and recalculate exactly once.
var _batching_layout: bool = false

# Backward compatibility - still compute these from card_size
var item_height: float = 280.0:
	get:
		return card_size.y + grid_separation
var item_width: float = 212.0:
	get:
		return card_size.x + grid_separation

var _scroll_container: SmoothScrollContainer
var _margin_container: MarginContainer
# Plain Control, NOT a CenterContainer: CenterContainer positions children by
# their combined minimum size (ignoring size flags), so any transient card
# min-size mutation during recycling leaked into flow.position for exactly
# one rendered frame (the whole strip jumped ~half the extent delta at
# recycle thresholds). With a plain Control the flow is anchored full-rect —
# flow.position stays (0,0) no matter what min sizes do — and all centering
# is reproduced deterministically via margins in _update_margin().
var _center_container: Control
var _flow_container: FlowContainer
## Visual stamping pipeline: owns the top-level visual layer, pre-draw
## stamping, the reveal-on-sort gate, and the rest stamp (GridVisualSync).
var _visual_sync := GridVisualSync.new(self)
## Spacer lifecycle in the flow (page spacers between pages, stagger spacers
## indenting odd rows). Boundary math stays in GridGeometry via the facades.
var _spacers := GridSpacerManager.new(self)

## Debug/audit tooling (debug panels, debug camera, frame-post-draw audits,
## soak test). Reads grid state for introspection; owns its own RS signal
## connections. Created in _setup_ui.
var _debug_overlay: GridDebugOverlay = null

var _total_items: int = 0
# Real item count from the data source. _total_items is the geometry count:
# padded with placeholder slots (trailing) so pages/rows always fill evenly.
var _source_total_items: int = 0
var _card_scene: PackedScene
var _ready_called: bool = false

## Card instance pool: creation, acquire/recycle, frame-spread growth, and the
## card-scene capability probe (GridCardPool).
var _pool := GridCardPool.new(self)

## The active window: membership, recycle/add, the scroll pass, async buffer
## expansion, and the pending visual-setup drain (GridWindowManager). The
## window manager is the ONE writer of window membership; the properties
## below are read-only views for the other modules, the overlay, and tests.
var _window := GridWindowManager.new(self)

var _active_cards: Array[Control]:
	get:
		return _window.cards
var _active_cards_by_index: Dictionary[int, Control]:
	get:
		return _window.by_index
var _pending_visual_setup: Dictionary:
	get:
		return _window.pending_setup
var _virtual_start: int:
	get:
		return _window.virtual_start
var _virtual_end: int:
	get:
		return _window.virtual_end

# Async buffer expansion: load only a small synchronous buffer at startup, then
# fill the rest of the visual buffer over subsequent frames to avoid a startup
# hitch while keeping the full scroll buffer.
var _current_buffer_lines: int = visual_buffer_lines

# Cached card capability flags — set once in _instantiate_card_pool() to avoid
# repeated has_method() and string lookups in hot loops.
var _card_has_focus_scale_enabled: bool = false
var _card_has_set_focus_scale: bool = false
var _card_has_set_game_with_priority: bool = false
var _card_has_refresh_settings: bool = false
var _card_has_reset: bool = false
var _card_has_game_prop: bool = false
var _card_has_update_media_panel_size: bool = false
var _card_has_update_display: bool = false
var _card_has_set_image_priority: bool = false
var _card_has_set_content_alignment: bool = false
var _card_has_set_media_aspect_ratio: bool = false
var _card_has_refresh_effects: bool = false
var _card_has_update_card_state_from_settings: bool = false
var _card_has_sync_visual_transform: bool = false
var _card_has_sync_visual_offset: bool = false
var _card_has_visual_layer_opacity: bool = false
var _card_has_mark_visuals_position_synced: bool = false
var _card_has_unmark_visuals_position_synced: bool = false
var _card_has_show_loading_skeleton: bool = false
var _card_has_begin_bulk_layout: bool = false
var _card_has_end_bulk_layout: bool = false

# Layout input cache — used to skip redundant _recalculate_layout() work
var _last_layout_view_mode: ViewMode = ViewMode.GRID
var _last_layout_grid_vertical: bool = true
var _last_layout_focus_scale: float = 1.08
var _last_layout_card_size: Vector2 = Vector2.ZERO
var _last_layout_focused_card_size: Vector2 = Vector2.ZERO
var _last_layout_grid_separation: int = -1
var _last_layout_pagination: bool = false
var _last_layout_staggered: bool = false
var _last_layout_available_size: Vector2 = Vector2.ZERO

# Deterministic available size: when set, _get_available_size() returns this value
# instead of grid.size so layout can be computed before Godot propagates
# container sizes through the scene tree. Main, UIManager, and views set this
# explicitly at startup and at every layout-affecting transition.
var _deterministic_available_size: Vector2 = Vector2.ZERO

func _has_valid_available_size() -> bool:
	return (_deterministic_available_size.x > 0.0 and _deterministic_available_size.y > 0.0) or (size.x > 0 and size.y > 0)

var _last_layout_display_mode: int = -1
var _last_layout_media_aspect_ratio: int = -1
var _last_layout_total_items: int = -1

# Deferred layout recalc guard — coalesces multiple settings-driven recalc
# requests into a single call at the end of the frame.
var _layout_recalc_scheduled: bool = false

# Resize debounce timer — prevents rapid-fire recalculations during window resize
var _resize_debounce_timer: Timer = null
const RESIZE_DEBOUNCE_SECONDS: float = 0.05

# Scroll math cache — invalidated and recomputed inside _recalculate_layout()
var _cached_items_per_line: int = -1
var _cached_normal_stride: float = -1.0

# Margin caching - only update when margins actually change
var _last_margin_top: int = -1
var _last_margin_bottom: int = -1
var _last_margin_left: int = -1
var _last_margin_right: int = -1
var _last_flow_width: float = 0.0
var _last_flow_height: float = 0.0

# Cached settings — refreshed only when settings change (settings_saved signal)
var _cached_media_aspect_ratio: float = -1.0
var _cached_card_display_mode: int = 0
var _cached_content_alignment: M3Card.ContentAlignment = M3Card.ContentAlignment.START

# Cached visible/buffer range — updated in-place to avoid Dictionary allocations
var _visible_start_idx: int = 0
var _visible_end_idx: int = 0
var _buffer_target_start: int = 0
var _buffer_target_end: int = 0

## Incremental effect rebuild queue (visible zone immediately, the rest
## drained over frames) plus the "refresh after layout settles" deferral.
var _effect_queue := GridEffectRefreshQueue.new(self)

# Flow-container separation caching - only override when value changes
var _last_h_separation: int = -1
var _last_v_separation: int = -1

# Margin virtual-range cache — margins only change when the active card range changes
var _last_margin_virtual_start: int = -1
var _last_margin_virtual_end: int = -1



## Item-data cache: index → game, LRU + in-flight request ledger + duplicate
## tracking (GridDataCache). Views still connect to THIS grid's
## items_requested signal; the module's signal is relayed below.
var _data: GridDataCache = _create_data_cache()

func _create_data_cache() -> GridDataCache:
	var d := GridDataCache.new(self)
	d.items_requested.connect(func(offset: int, limit: int): items_requested.emit(offset, limit))
	return d

## Buffer-zone data loads (beyond the visible zone + one line) deferred while
## scrolling fast: flushed when velocity drops below the threshold OR the
## viewport has been idle 150ms, whichever first. Keeps fast traversal from
## flooding the DB worker with windows nobody is looking at.
const BUFFER_LOAD_VELOCITY_STRIDES: float = 2.0
const BUFFER_LOAD_IDLE_FLUSH_MS: int = 150
## Idle missing-data sweep cooldown. In-flight requests can be dropped without
## a retry (pruned by a window jump while the DB task was queued, or the task
## queue overflowing), and steady-state window passes take the light path
## which skips data requests — so without a sweep the hole never heals. The
## cooldown keeps a genuinely unfetchable index from hammering the DB.
const MISSING_DATA_SWEEP_MS: int = 500
var _deferred_data_indices: Dictionary = {}  # idx -> true
var _last_scroll_active_ms: int = 0          # last frame with nonzero velocity
var _last_missing_data_sweep_ms: int = 0

func _configure_view_mode() -> void:
	"""Update scroll/flow container flags for the current view_mode/grid_vertical without rebuilding cards."""
	if not _flow_container or not _scroll_container:
		return
	match view_mode:
		ViewMode.GRID:
			_scroll_container.vertical = grid_vertical
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER if grid_vertical else ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if grid_vertical else ScrollContainer.SCROLL_MODE_SHOW_NEVER
			_flow_container.vertical = not grid_vertical
		ViewMode.LIST:
			_scroll_container.vertical = true
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_flow_container.vertical = false
		ViewMode.CAROUSEL:
			_scroll_container.vertical = false
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			_flow_container.vertical = true
	_update_center_container_flags()
	_update_flow_container_flags()

func _update_view_mode() -> void:
	"""Apply view-mode configuration and rebuild the card buffer."""
	_configure_view_mode()
	_refresh_buffer(true)

func _update_flow_container_flags() -> void:
	if not _flow_container:
		return
	# The flow is anchored full-rect inside the center container (a plain
	# Control), so flow.position is pinned at (0,0) on every frame and
	# flow.size tracks the margin content rect — completely independent of
	# card min-size churn during recycling. Anchor layout is synchronous and
	# never depends on minimum sizes. (This replaces the old CenterContainer +
	# SHRINK_CENTER arrangement whose sort-derived flow.position committed
	# transient min-size states for one rendered frame — the recycle-flicker.)
	_flow_container.set_anchors_preset(Control.PRESET_FULL_RECT)

func _update_center_container_flags() -> void:
	if not _center_container:
		return
	if vertical:
		_center_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_center_container.size_flags_vertical = Control.SIZE_FILL
	else:
		_center_container.size_flags_horizontal = Control.SIZE_FILL
		_center_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _get_focus_overflow() -> Vector2:
	# How many pixels a focused card extends beyond its normal bounds on each side.
	match view_mode:
		ViewMode.GRID:
			return Vector2(
				maxf(0.0, (focused_card_size.x - card_size.x) / 2.0),
				maxf(0.0, (focused_card_size.y - card_size.y) / 2.0)
			)
		ViewMode.LIST:
			# Inverted focus: focused_card_size == card_size, so this is zero;
			# unfocused cards shrink inward and never overflow.
			return Vector2(0.0, maxf(0.0, (focused_card_size.y - card_size.y) / 2.0))
		ViewMode.CAROUSEL:
			return Vector2(maxf(0.0, (focused_card_size.x - card_size.x) / 2.0), 0.0)
	return Vector2.ZERO

func _get_focus_scale_inverted() -> bool:
	# LIST/CAROUSEL: card starts at 1.0/focus_scale and grows to 1.0 when focused.
	# GRID: card starts at 1.0 and grows to focus_scale when focused.
	return view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL

func _get_available_size() -> Vector2:
	# The outer margin insets the effective viewport on all sides; every layout
	# consumer (zoom stops, exact-fill, centering, visible ranges, page groups)
	# computes against this inset size.
	var inset := Vector2(grid_outer_margin * 2.0, grid_outer_margin * 2.0)
	# During deterministic sizing, use the size supplied by Main/UIManager rather
	# than the grid's own size, which may not reflect the final container size yet.
	if _deterministic_available_size.x > 0.0 and _deterministic_available_size.y > 0.0:
		if debug_mode:
			if DEBUG_LOG: print("[Grid] _get_available_size: using deterministic available size=", _deterministic_available_size)
		return Vector2(maxf(_deterministic_available_size.x - inset.x, 1.0), maxf(_deterministic_available_size.y - inset.y, 1.0))

	var result = Vector2(maxf(size.x - inset.x, 1.0), maxf(size.y - inset.y, 1.0))
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _get_available_size: vertical=", vertical, " size=", size, " result=", result)
	return result

func _get_normal_stride() -> float:
	if _cached_normal_stride > 0:
		return _cached_normal_stride
	# Stride is based on normal card size so cards can touch at grid_separation = 0.
	# Focused cards scale up and overlap; inner padding prevents clipping at content edges.
	match view_mode:
		ViewMode.GRID:
			return (card_size.y + grid_separation) if vertical else (card_size.x + grid_separation)
		ViewMode.LIST:
			return card_size.y + grid_separation
		ViewMode.CAROUSEL:
			return card_size.x + grid_separation
	return (card_size.y + grid_separation) if vertical else (card_size.x + grid_separation)

func _get_slot_position_for_index(idx: int, items_per_line: int = -1, stride: float = -1.0) -> float:
	"""Returns the scroll-axis pixel position where slot `idx` begins."""
	_sync_geometry()
	return _geometry.slot_position(idx, items_per_line, stride)

## Captures the current scroll position as a three-slot anchor (index,
## intra-line fraction, viewport edge — see GridScrollAnchor). The anchor is
## the focused card when there is one, else the first slot of the top visible
## line. MUST be called before any geometry change (items-per-line / card
## size) it is meant to survive. allow_end_pin: inline recalc captures
## (resize, library shrink) may pin the restore to the content end when
## captured at max scroll; zoom-path captures pass false because the focused
## card is the better zoom anchor.
func _capture_scroll_anchor(focus_index: int, allow_end_pin: bool = false) -> GridScrollAnchor:
	var anchor := GridScrollAnchor.new()
	if not _scroll_container or _source_total_items <= 0:
		return anchor
	var scroll_pos: float = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
	var stride: float = _get_normal_stride()
	var items_per_line: int = _get_items_per_line()
	if stride <= 0.0 or items_per_line <= 0:
		return anchor
	if focus_index >= 0:
		anchor.index = mini(focus_index, _source_total_items - 1)
		anchor.frac = (scroll_pos - _get_slot_position_for_index(anchor.index, items_per_line, stride)) / stride
	else:
		var top_line := int(floor(scroll_pos / stride))
		anchor.index = clampi(_get_first_index_for_line(top_line, items_per_line), 0, _source_total_items - 1)
		anchor.frac = (scroll_pos - top_line * stride) / stride
	if allow_end_pin:
		_sync_geometry()
		if scroll_pos >= _geometry.max_scroll() - 1.0:
			anchor.edge = GridScrollAnchor.Edge.FAR
	return anchor

func _ready():
	_setup_ui()

	# frame_pre_draw (visual stamping) is owned by _visual_sync (connects in
	# its own _ready/_exit_tree).
	# frame_post_draw (DrawAudit) connects in _update_debug_mode — debug-only.

	# Use SystemManager.display as the single source of resize truth when available.
	# It debounces viewport changes so we don't recalculate layout on every pixel.
	if SystemManager.display:
		SystemManager.display.viewport_size_changed.connect(_on_display_size_changed)
	else:
		resized.connect(_on_resized)
		_setup_internal_resize_debounce()

	# Load initial grid separation and focus scale from settings
	# Use call_deferred to ensure DataManager is fully initialized
	call_deferred("_update_grid_separation_from_settings")
	call_deferred("_update_focus_scale_from_settings")
	call_deferred("_refresh_cached_settings")
	_focus.connect_viewport.call_deferred()
	_ready_called = true

func _setup_internal_resize_debounce():
	_resize_debounce_timer = Timer.new()
	_resize_debounce_timer.one_shot = true
	_resize_debounce_timer.wait_time = RESIZE_DEBOUNCE_SECONDS
	_resize_debounce_timer.timeout.connect(_on_resize_debounced)
	add_child(_resize_debounce_timer)

func _on_resized():
	# Keep the top-level visual layer pinned to the viewport so it can draw
	# outside the grid's bounds without being clipped by margins or scroll.
	_visual_sync.resize_to_viewport()

	# Ignore resize events that don't actually change size (sub-pixel or duplicate)
	var new_size = Vector2(size.x, size.y)
	if is_equal_approx(new_size.x, _last_resized_size.x) and is_equal_approx(new_size.y, _last_resized_size.y):
		return

	# Ignore tiny size jitters that don't meaningfully affect layout.
	if abs(new_size.x - _last_resized_size.x) < RESIZE_IGNORE_DELTA and abs(new_size.y - _last_resized_size.y) < RESIZE_IGNORE_DELTA:
		return

	_last_resized_size = new_size

	# Debounce rapid resize events (e.g. during window resize or layout transitions)
	if _resize_debounce_timer:
		_resize_debounce_timer.start()

func _on_display_size_changed(_new_size: Vector2):
	"""Handler for SystemManager.display's debounced viewport_size_changed signal."""
	# Keep the top-level visual layer pinned to the viewport even while startup
	# layout is suppressed, so the layer never holds a stale viewport rect.
	_visual_sync.resize_to_viewport()

	if startup_layout_suppressed:
		return

	# Dedupe on the signal's viewport size, not this container's local rect:
	# display_sub_manager sometimes emits immediately (DS swap, fullscreen
	# toggle) before the container system has propagated the new rect, and a
	# local-size check would early-out against the stale rect with no retry.
	var viewport_changed: bool = not (is_equal_approx(_new_size.x, _last_viewport_arg_size.x) and is_equal_approx(_new_size.y, _last_viewport_arg_size.y))
	_last_viewport_arg_size = _new_size

	var new_size = Vector2(size.x, size.y)
	var local_changed: bool = not (abs(new_size.x - _last_resized_size.x) < RESIZE_IGNORE_DELTA and abs(new_size.y - _last_resized_size.y) < RESIZE_IGNORE_DELTA)

	# Skip only when neither the viewport nor our rect moved. When in doubt,
	# run: _on_resize_debounced re-derives the deterministic available size
	# from the viewport (not the possibly-stale local rect), and the recalc's
	# input-cache early-exit absorbs redundant passes.
	if not viewport_changed and not local_changed:
		return

	_last_resized_size = new_size

	# Run the same debounced logic the internal timer used to trigger.
	_on_resize_debounced()

func _enter_tree():
	FrameWorkScheduler.register(self, _run_frame_work)
	# frame_pre_draw (visual stamping) reconnects in _visual_sync's own
	# _enter_tree on every tree entry (DS reparents, nav rebuilds).
	# Connect to centralized card settings state (idempotent via is_connected guards)
	if UIManager and UIManager.card_settings_state:
		var state = UIManager.card_settings_state
		if not state.changed.is_connected(_on_card_settings_state_changed):
			state.changed.connect(_on_card_settings_state_changed)
	# If the grid was reparented, the pool was freed in _exit_tree().
	# Recreate it so cards can be reused again. On initial entry _card_scene is
	# still null, so this is a no-op.
	if _card_scene and _pool.cards.is_empty():
		_instantiate_card_pool()

	# Reset cached size so the next display resize check will recalculate layout
	# (the current parent may give us a different size than before reparenting).
	_last_resized_size = Vector2.ZERO
	if SystemManager.display:
		_on_display_size_changed(SystemManager.display.get_viewport_size())
	# Ensure focus-lock viewport signal is active after reparenting.
	_focus.reconnect_viewport()

func _exit_tree():
	FrameWorkScheduler.unregister(self)
	# frame_pre_draw (visual stamping) is disconnected by _visual_sync's own
	# _exit_tree; frame_post_draw audit/reality-check connections are owned
	# (and released) by _debug_overlay. Both exit the tree before this parent.
	if UIManager and UIManager.card_settings_state:
		var state = UIManager.card_settings_state
		if state.changed.is_connected(_on_card_settings_state_changed):
			state.changed.disconnect(_on_card_settings_state_changed)
	_focus.disconnect_viewport()
	# Release scene-wide focus lock if this grid held it.
	if UIManager:
		UIManager.exit_focus_lock(self)
	# Always free the pooled cards when leaving the tree. Pooled nodes are not in
	# the tree, so they would not be cleaned up automatically. Use free() because
	# queue_free() may not flush during process exit.
	_pool.free_all(true)

	# Only clear active-card tracking when the grid is being destroyed. When the
	# grid is reparented (e.g. nav type change), the active cards stay in the
	# FlowContainer and _active_cards keeps pointing to them so the next
	# _recalculate_layout can recycle/update them. Clearing this while leaving the
	# cards in the tree produces stale blank cards that are not tracked.
	if is_queued_for_deletion():
		_active_cards.clear()
		_active_cards_by_index.clear()
	if _lp_gate_held or _cover_dl_suppressed or _scrub_cover_suppressed or CardMediaLoader.downloads_suppressed:
		CoverTrace.event("grid", "exit_with_cover_state", {
			"grid": get_instance_id(),
			"queued_for_deletion": is_queued_for_deletion(),
			"gate_held": _lp_gate_held,
			"local_suppressed": _cover_dl_suppressed,
			"scrub_suppressed": _scrub_cover_suppressed,
			"global_suppressed": CardMediaLoader.downloads_suppressed,
		})
	# The low-priority decode gate is process-global (owner-refcounted): never
	# leave it held when this grid leaves the tree or other screens starve.
	if _lp_gate_held:
		_lp_gate_held = false
		MemorySubManager.release_low_priority_gate(get_instance_id())

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		if UIManager:
			UIManager.exit_focus_lock(self)
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		# A focus grab skipped while the window was backgrounded left its
		# target pending; restore it now that the user is back.
		if _focus.pending_index >= 0 and M3Overlay._get_topmost_overlay() == null:
			_focus.try_apply_pending_focus.call_deferred()

func clear_pool() -> void:
	"""Public hook to free pooled cards before the grid leaves the tree.

	Useful during app shutdown to release heavy card resources early.
	Pooled nodes are not in the tree, so they must be freed explicitly;
	free() is used because queue_free() may not flush before the rendering
	server shuts down at engine exit.
	"""
	_pool.free_all(true)

## Lead beyond the visible window, in lines, when re-warming covers post-trim.
const RESTORE_PREFETCH_LEAD_LINES := 2

## True after release_active_media(): the next restore must re-bind covers on
## the visible cards, not just re-warm the cache around them.
var _active_media_released: bool = false

## Deep trim (TRIM_MEMORY_COMPLETE): drop decoded covers on the VISIBLE cards
## too, which the standard launch trim deliberately keeps for an instant
## resume frame. Cards swap to the shared placeholder; restore_after_trim()
## re-binds them from the (re-warmed) disk cache.
func release_active_media() -> void:
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("release_cover"):
			card.release_cover()
	_active_media_released = true

## Rebuild what Main's launch-hibernation trim released for this grid: the
## inactive card pool (the active window survives the trim with its textures)
## and the cover texture cache around the current window. Called on
## resume/launch-failure so the first scroll afterwards doesn't pay card
## instantiations and disk decodes inside the recycle hot path.
func restore_after_trim() -> void:
	if not _card_scene or _total_items <= 0:
		return
	_instantiate_card_pool()
	prefetch_covers_around_window()
	# Deep-trimmed visible cards hold the placeholder; re-request their covers
	# now that the cache around the window is warming again.
	if _active_media_released:
		_active_media_released = false
		for card in _active_cards:
			if is_instance_valid(card) and card.has_method("retry_cover_if_placeholder"):
				card.retry_cover_if_placeholder()

## Warm the cover texture cache for the visible window plus a small lead in
## both directions. Disk-only (preload_cover never downloads) and a no-op for
## entries already cached; worker decodes and main-thread texture uploads
## self-pace through MemorySubManager's queue drains.
func prefetch_covers_around_window() -> void:
	if _total_items <= 0:
		return
	var items_per_line := _get_items_per_line()
	if items_per_line <= 0:
		return
	var range_info := get_visible_range()
	var start: int = maxi(0, int(range_info.get("start", 0)) - RESTORE_PREFETCH_LEAD_LINES * items_per_line)
	var end: int = mini(_source_total_items, int(range_info.get("end", 0)) + RESTORE_PREFETCH_LEAD_LINES * items_per_line)
	if end <= start:
		return
	var bucket := CardMediaLoader.decode_bucket_for_card_size(card_size, CardMediaLoader.current_dpr())
	for idx in range(start, end):
		if _data.has_index(idx):
			CardMediaLoader.preload_cover(_data.get_game(idx), bucket, self, idx)

func _on_card_settings_state_changed(mask: int) -> void:
	if not UIManager or not UIManager.card_settings_state:
		return

	var state = UIManager.card_settings_state

	if debug_mode:
		if DEBUG_LOG: print("[Grid] settings changed mask=", mask, " display_mode=", state.display_mode, " media_ratio=", state.media_aspect_ratio, " cached_display=", _cached_card_display_mode, " cached_ratio=", _cached_media_aspect_ratio)

	# Refresh cached media/display settings before any layout work so that
	# _batch_apply_layout_state() snaps target_card_width_ratio against the
	# correct base dimensions.
	_refresh_cached_settings()

	if debug_mode:
		if DEBUG_LOG: print("[Grid] after refresh cached display=", _cached_card_display_mode, " cached_ratio=", _cached_media_aspect_ratio)

	# Layout-affecting settings: orientation, zoom, padding, focus scale
	if mask & CardSettingsState.ChangeMask.LAYOUT:
		if debug_mode: print("[Grid] applying LAYOUT batch, target_ratio before=", target_card_width_ratio)
		_batch_apply_layout_state()
		if debug_mode:
			if DEBUG_LOG: print("[Grid] after LAYOUT batch, target_ratio=", target_card_width_ratio, " card_size=", card_size, " base_card_size=", base_card_size)

	# Text-only options do not alter geometry or effects.
	if mask & CardSettingsState.ChangeMask.TEXT:
		refresh_all_card_displays()

	# Display mode / content alignment / media aspect ratio
	if mask & (CardSettingsState.ChangeMask.DISPLAY | CardSettingsState.ChangeMask.MEDIA_SHAPE):
		refresh_all_card_configs()
		# Effects are rebuilt only after the final display/media layout exists.
		_effect_queue.request_after_layout()
		_schedule_layout_recalc()

	# Card effect configuration changed. Defer the effect refresh until after the
	# layout recalc so cards are rebuilt against final bounds and newly added cards
	# are included in the refresh snapshot.
	if mask & CardSettingsState.ChangeMask.EFFECTS:
		_effect_queue.request_after_layout()
		_schedule_layout_recalc()

func _schedule_layout_recalc() -> void:
	"""Queue a single deferred layout recalc. Multiple calls in one frame collapse."""
	if _layout_recalc_scheduled:
		return
	_layout_recalc_scheduled = true
	call_deferred("_do_scheduled_layout_recalc")

func _do_scheduled_layout_recalc() -> void:
	_layout_recalc_scheduled = false
	_recalculate_layout()
	
	# Now that layout has settled, apply any deferred effect refresh. This ensures
	# effect rebuilds use final card bounds and include cards added during recalc.
	_effect_queue.apply_after_layout()

func _refresh_cached_settings() -> void:
	if not UIManager or not UIManager.card_settings_state:
		return

	var state = UIManager.card_settings_state
	var idx = clampi(state.media_aspect_ratio, 0, _RATIO_LOOKUP.size() - 1)
	_cached_media_aspect_ratio = _RATIO_LOOKUP[idx]
	_cached_card_display_mode = clampi(state.get_effective_display_mode(), 0, 2)
	_cached_content_alignment = clampi(state.content_alignment, 0, 2) as M3Card.ContentAlignment
	_focus_centering_mode = clampi(state.focus_centering_mode, 0, 1)
	# Converge the pagination flag with the shared state. Grids otherwise only
	# learn it via the changed() signal, which fires before grids connect at
	# startup and never reaches lazily created views — leaving the member out
	# of sync with the persisted setting (double-click menu bug).
	pagination_enabled = state.pagination_enabled
	staggered = state.grid_staggered

	# Initialize last-layout tracking on the first cache so the first real
	# layout doesn't treat the initial state as a "change" and re-snap the
	# saved zoom to a different stop.
	if _last_layout_display_mode < 0:
		_last_layout_display_mode = _cached_card_display_mode
	if _last_layout_media_aspect_ratio < 0:
		_last_layout_media_aspect_ratio = state.media_aspect_ratio

var _last_resized_size: Vector2 = Vector2.ZERO
var _last_viewport_arg_size: Vector2 = Vector2.ZERO
var _is_recalculating_layout: bool = false
# Set when a resize arrives mid-recalc; consumed with one deferred follow-up
# pass when the current recalc finishes, so no resize is ever dropped.
var _resize_pending: bool = false

# Ignore tiny size jitters and duplicate recalculations caused by scrollbar visibility toggling.
const RESIZE_IGNORE_DELTA: float = 2.0

func _gui_input(event: InputEvent) -> void:
	# Right-clicks that were not consumed by a card arrive here through the
	# scroll container. Handle them at the grid boundary; View itself never
	# sees these events because this Control stops propagation.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var view = UIManager.get_view_for_grid(self) if UIManager else null
		if view:
			view._open_background_context_menu(event.global_position)
			accept_event()
		return

	# Wheel over the grid's outer margin (the inset area around the scroll
	# container) should still scroll; forward to the scroll container's wheel
	# handler. Events over the scroll container itself are accepted there and
	# never propagate here.
	if _scroll_container and event is InputEventMouseButton and event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_scroll_container._on_gui_input(event)

func _run_frame_work(_delta: float):
	if _window.processing_scroll:
		_window.processing_scroll = false
		push_warning("[Grid] _is_processing_scroll was left set between frames; force-cleared")

	# Reveal fallback: if a sort never consumed the pending reveal (hidden view,
	# container quirk), reveal after 3 frames rather than leaving cards hidden.
	_visual_sync.check_reveal_fallback()

	# A programmatic scroll-and-focus sequence has settled (completed or was
	# interrupted): lift follow-focus suppression and focus the target card if
	# nothing inside the grid ended up focused (e.g. the card only entered the
	# buffer near the end of a long scroll).
	if _programmatic_focus_index >= 0 and _scroll_container and not _scroll_container.is_scrolling():
		var idx := _programmatic_focus_index
		_programmatic_focus_index = -1
		_scroll_container.follow_focus_suppressed = false
		_focus.pending_index = -1
		var focused_owner: Control = null
		var viewport := get_viewport()
		if viewport:
			focused_owner = viewport.gui_get_focus_owner()
		if not focused_owner or not is_ancestor_of(focused_owner):
			var card := get_card_at_index(idx)
			if card and is_instance_valid(card) and card.is_inside_tree():
				_focus.apply_focus_to_card(card)

	# Add off-screen buffer cards a few at a time so startup isn't blocked by
	# creating the entire visual buffer in one frame.
	_window.process_buffer_expansion()

	# Settle detection for cover-download suppression: scroll passes stop once
	# scrolling ends, so _process is where the stale velocity decays and
	# suppressed cover loads resume (and visible placeholders retry).
	_update_cover_dl_suppression()

	# Buffer-zone data loads deferred during fast scroll flush here on settle.
	_flush_deferred_data_loads()

	# Safety net: re-find missing card data at idle (dropped requests leave
	# no pending entry, and steady-state passes never re-request).
	_sweep_missing_data_at_idle()

	# Top up the card pool a few per frame after zoom-out/resize grew the layout.
	_pool.process_growth()

	# Finish deferred visual setup for off-screen buffer cards.
	_window.process_pending_visual_setup()

	# Drain any queued off-screen effect rebuilds a few cards per frame.
	_effect_queue.drain_pending()

func _on_resize_debounced():
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _on_resize_debounced: size=", size, " target_ratio=", target_card_width_ratio, " suppressed=", startup_layout_suppressed)
	if size.y > 0:
		if debug_mode:
			_log_parent_chain_sizes()
	if startup_layout_suppressed:
		return
	# Prevent re-entrant layout recalculations. Don't drop the resize: flag it
	# and let the in-flight recalc run one deferred follow-up pass.
	if _is_recalculating_layout:
		_resize_pending = true
		return

	# Update the cached size so later viewport_size_changed events can de-duplicate.
	_last_resized_size = Vector2(size.x, size.y)

	# Re-snap zoom ratio to a valid stop for the new available size and recalculate once.
	# Use the deterministic available size when possible so the snap is based on
	# the viewport and chrome, not on the grid's possibly-stale local size.
	# Keep it set so later layout passes do not fall back to a transient size.
	var available := Vector2.ZERO
	if UIManager:
		available = UIManager.compute_grid_available_size(self, null)
	set_deterministic_available_size(available if available.x > 0 and available.y > 0 else _get_available_size())
	# If the grid was settled before its size was valid (e.g. size-0 startup
	# settle), force the next layout past its input-cache early-exit now that
	# real geometry exists — the early-exit would otherwise stand forever.
	if _has_valid_available_size() and not _layout_settled_with_valid_size:
		_force_layout_once = true
		_recalculate_layout()
	if view_mode == ViewMode.GRID:
		# N is the source of truth: it survives resizes and is clamped to the
		# new viewport's stop range inside _recalculate_layout(). If N was never
		# derived (fresh grid), seed it from the saved zoom level.
		if _grid_items_per_line <= 0 and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
			_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
		_recalculate_layout()
	else:
		target_card_width_ratio = _calculate_snapped_ratio(target_card_width_ratio)

	# If we have items but no active cards (e.g., view was hidden during setup), load them now
	if _active_cards.size() == 0 and _total_items > 0 and _has_valid_available_size():
		_window.initial_load()
		_recalculate_layout()

func _log_parent_chain_sizes() -> void:
	var labels = ["grid", "vbox", "margin", "view", "tab_page", "tab_container", "main_vbox", "outer_margin", "content_wrapper"]
	var current: Node = self
	var i := 0
	while current != null and i < labels.size():
		if DEBUG_LOG: print("[Grid] layout chain ", labels[i], " size=", current.size)
		current = current.get_parent()
		i += 1

func settle_startup() -> void:
	"""Run the single startup layout and snap the saved zoom to a valid stop.
	
	Main calls this once after the final window size is known so the grid
	settles at a valid internal snap stop for the current viewport, while the
	slider and saved zoom stay consistent."""
	if DEBUG_LOG: print("[Grid] settle_startup: size=", size, " target_ratio=", target_card_width_ratio)
	if _is_recalculating_layout:
		return

	# Update the cached size so later viewport_size_changed events can de-duplicate.
	_last_resized_size = Vector2(size.x, size.y)

	# Snap the saved zoom to a valid stop for the final available size. In grid
	# mode use the current level so all views settle at the same zoom level.
	if view_mode == ViewMode.GRID and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
		_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
		_recalculate_layout()
	elif view_mode == ViewMode.GRID:
		# No saved level: lock in N from the saved ratio now that the size is final.
		_set_grid_n_silent(_zoom_model.nearest_grid_stop(target_card_width_ratio))
		_recalculate_layout()
	else:
		target_card_width_ratio = _calculate_snapped_ratio(target_card_width_ratio)

	# If we have items but no active cards (e.g., view was hidden during setup), load them now.
	if _active_cards.size() == 0 and _total_items > 0 and _has_valid_available_size():
		_window.initial_load()
		_recalculate_layout()

func settle_startup_with_buffer(startup_buffer_lines: int) -> void:
	"""Run the startup layout with a smaller buffer, then expand asynchronously.

	This creates only the visible cards plus a small synchronous buffer at
	startup, then fills the rest of the visual buffer over subsequent frames
	so the initial frame is not blocked by dozens of off-screen cards."""
	if DEBUG_LOG: print("[Grid] settle_startup_with_buffer: startup_buffer_lines=", startup_buffer_lines, " final_buffer_lines=", visual_buffer_lines)
	var previous_buffer_lines: int = _current_buffer_lines
	_current_buffer_lines = startup_buffer_lines
	settle_startup()
	_current_buffer_lines = previous_buffer_lines
	_window.pending_buffer_expansion = true




func _update_grid_separation_from_settings() -> void:
	var padding: int = UIManager.card_settings_state.grid_padding if UIManager and UIManager.card_settings_state else 10
	_apply_grid_padding(padding)

func _update_focus_scale_from_settings() -> void:
	if UIManager and UIManager.card_settings_state:
		focus_scale = 1.0 + UIManager.card_settings_state.focus_scale_ratio
	else:
		focus_scale = 1.08



func _calculate_zoom() -> float:
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var ratio = clampf(target_card_width_ratio, 0.05, _calculate_max_ratio())

	match view_mode:
		ViewMode.GRID:
			var viewport_area = available.x * available.y
			var base_area = base_dims.x * base_dims.y
			var target_card_area = viewport_area * ratio * ratio
			return sqrt(target_card_area / base_area)
		ViewMode.LIST:
			return (available.y * ratio) / base_dims.y
		ViewMode.CAROUSEL:
			return (available.x * ratio) / base_dims.x
	return 1.0

func _calculate_max_ratio() -> float:
	_sync_zoom_model_inputs()
	return _zoom_model.get_max_ratio()

## Ascending items-per-line stops for the current viewport (index = zoom level).
## Every stop exactly fills the viewport cross-axis with whole cards.
## Do not mutate the returned array (it is the model's cache).
func get_snap_levels() -> Array[int]:
	_sync_zoom_model_inputs()
	if view_mode != ViewMode.GRID:
		return []
	return _zoom_model.get_stops()

## Ascending "cards along the scroll axis" stops for LIST/CAROUSEL. Stop k
## gives a card that exactly fills the cross axis and shares the scroll axis
## evenly with k−1 siblings: every stop is bounds-correct by construction.
func get_scroll_stop_lines() -> Array[int]:
	_sync_zoom_model_inputs()
	if view_mode == ViewMode.GRID:
		return []
	return _zoom_model.get_stops()

## Card size for scroll-axis stop k: cross axis fills exactly, scroll axis is
## (scroll_axis − (k−1)·sep) / k.
func _scroll_stop_size(k: int) -> Vector2:
	_sync_zoom_model_inputs()
	return _zoom_model.scroll_stop_size(k)

## The stop's zoom fraction (card scroll dim / viewport scroll dim). This is
## the value stored in card_zoom_list_ratio, so saved floats migrate onto the
## nearest stop.
## Maps a scroll-fill fraction to the nearest stop's k.
func _resolve_lines_for_ratio(ratio: float) -> int:
	_sync_zoom_model_inputs()
	if view_mode == ViewMode.GRID:
		return 2
	return _zoom_model.resolve_lines_for_ratio(ratio)

## The effective scroll-axis stop for LIST/CAROUSEL layout. Derives from the
## stored fraction once a trustworthy size is available; 0 = "not resolved".
func _get_scroll_lines_visible() -> int:
	_sync_zoom_model_inputs()
	return _zoom_model.get_lines_visible()

## Returns snap ratios ordered most-zoomed-out first (index 0 = smallest
## ratio), one per stop, for ALL view modes — the unified view the zoom slider
## consumes. GRID: legacy view over the items-per-line stops. LIST/CAROUSEL:
## the scroll-axis fill fraction of each stop.
func get_snap_ratios() -> Array[float]:
	_sync_zoom_model_inputs()
	var ratios := _zoom_model.get_snap_ratios_desc()
	if _has_valid_available_size() and ratios.size() < 2:
		push_warning("[VirtualScrollGridContainer] Only %d snap ratio(s) for view_mode=%s, size=%s, available=%s" % [ratios.size(), view_mode, size, _get_available_size()])
	return ratios

## Returns snap ratios sorted ascending (index 0 = most items per line).
## The slider index maps directly to a zoom level.
func get_snap_ratios_ascending() -> Array[float]:
	_sync_zoom_model_inputs()
	return _zoom_model.get_snap_ratios_ascending()

## Index of the current zoom within the mode's stop list (0 = largest cards).
## Pass from_ratio to resolve a level for an arbitrary ratio (e.g. a saved one)
## instead of the grid's current zoom. Does not mutate zoom state.
func get_zoom_level(from_ratio: float = -1.0) -> int:
	_sync_zoom_model_inputs()
	if from_ratio < 0.0:
		return _zoom_model.get_level()
	var stops := _zoom_model.get_stops()
	if stops.is_empty():
		return -1
	if view_mode != ViewMode.GRID:
		return stops.find(_zoom_model.resolve_lines_for_ratio(from_ratio))
	var n := _zoom_model.nearest_grid_stop(from_ratio)
	var best := 0
	for i in range(stops.size()):
		if absi(stops[i] - n) < absi(stops[best] - n):
			best = i
	return best

## Applies a zoom level (index into the mode's stop list) and recalculates
## layout. Returns true if the effective zoom changed.
func set_zoom_level(level: int) -> bool:
	if view_mode != ViewMode.GRID:
		return _apply_scroll_stop_level(level, true)
	_sync_zoom_model_inputs()
	var levels := _zoom_model.get_stops()
	if levels.is_empty():
		return false
	return _set_grid_items_per_line(levels[clampi(level, 0, levels.size() - 1)])

## Shared level→stop application for LIST/CAROUSEL. `recalc` false is the
## batch/stamp variant (recalculate once at the end by the caller).
func _apply_scroll_stop_level(level: int, recalc: bool) -> bool:
	_sync_zoom_model_inputs()
	if not _zoom_model.set_level(level):
		return false
	if recalc:
		_recalculate_layout()
	return true

## Stamps a zoom level without recalculating layout. Intended for hidden views:
## the layout settles when the view is next shown (View.on_view_show runs
## recalculate_layout_with_size). Returns true if N changed.
func stamp_zoom_level(level: int) -> bool:
	if view_mode != ViewMode.GRID:
		return _apply_scroll_stop_level(level, false)
	_sync_zoom_model_inputs()
	var levels := _zoom_model.get_stops()
	if levels.is_empty():
		return false
	return _set_grid_n_silent(levels[clampi(level, 0, levels.size() - 1)])

## Stamps a LIST/CAROUSEL zoom ratio without recalculating layout (hidden views
## settle on show).
func stamp_zoom_ratio(p_ratio: float) -> void:
	_sync_zoom_model_inputs()
	_zoom_model.stamp_ratio(p_ratio)

## Applies the given zoom level without triggering a layout recalculation
## (batch contexts recalculate once at the end). Returns true if N changed.
func _apply_zoom_level(p_level: int) -> bool:
	if view_mode != ViewMode.GRID:
		return _apply_scroll_stop_level(p_level, false)
	_sync_zoom_model_inputs()
	var levels := _zoom_model.get_stops()
	if levels.is_empty():
		return false
	return _set_grid_n_silent(levels[clampi(p_level, 0, levels.size() - 1)])

func _set_grid_items_per_line(n: int) -> bool:
	if not _set_grid_n_silent(maxi(2, n)):
		return false
	_recalculate_layout()
	return true

func _set_grid_n_silent(n: int) -> bool:
	_sync_zoom_model_inputs()
	if _zoom_model._n_grid == n:
		return false
	# Snapshot the scroll anchor BEFORE N changes (see _scroll_anchor).
	_scroll_anchor = _capture_scroll_anchor(_focus.focused_virtual_index())
	_zoom_model.set_grid_n(n)
	return true

## Whole lines (rows when vertical, columns when horizontal) that fit in the
## viewport on the scroll axis. Groundwork for paged scrolling.
func get_lines_per_page() -> int:
	_sync_geometry()
	return _geometry.lines_per_page()

# ---------------------------------------------------------------------------
# Pagination (GRID mode only)
# ---------------------------------------------------------------------------

func _is_pagination_active() -> bool:
	return pagination_enabled and view_mode == ViewMode.GRID

## Staggered brick layout only applies to the vertical grid.
func _is_staggered_active() -> bool:
	return staggered and view_mode == ViewMode.GRID and vertical

## Blank space between page groups in the scroll direction, sized to reveal
## PAGINATION_PREVIEW_DP of adjacent pages at snapped positions when space allows.
func _get_page_gap() -> float:
	_sync_geometry()
	return _geometry.page_gap()

## Scroll-axis distance from one page start to the next (page + gap).
func _get_page_period() -> float:
	_sync_geometry()
	return _geometry.page_period()

## Total line count (rows/columns) across all items.
func _get_page_count() -> int:
	_sync_geometry()
	return _geometry.page_count()

## Snapped scroll position for page `page` (centered, clamped to range).
## With the leading pad in the slot transform, targets are simply k * period.
func _get_page_scroll_target(page: int) -> float:
	_sync_geometry()
	return _geometry.page_scroll_target(page)

## Page index containing slot `idx`.
func _get_page_for_index(idx: int) -> int:
	_sync_geometry()
	return _geometry.page_for_index(idx)

# --- Staggered rows ---------------------------------------------------------
# The stagger math itself lives in GridGeometry; these facades keep the call
# sites (and tests) stable.

## Items in one full two-row stagger unit (N even-row + N-1 odd-row).
func _get_stagger_line_for_index(idx: int) -> int:
	_sync_geometry()
	return _geometry.stagger_line_for_index(idx)

## Cards on a staggered row (N on even rows, N-1 on offset/odd rows).
func _get_stagger_line_capacity(line: int) -> int:
	_sync_geometry()
	return _geometry.stagger_line_capacity(line)

func _get_stagger_first_index_for_line(line: int) -> int:
	_sync_geometry()
	return _geometry.stagger_first_index_for_line(line)

## Line an item sits on (uniform mapping unless staggered).
func _get_line_for_index(idx: int, items_per_line: int = -1) -> int:
	_sync_geometry()
	return _geometry.line_for_index(idx, items_per_line)

## First item index of a line (uniform mapping unless staggered).
func _get_first_index_for_line(line: int, items_per_line: int = -1) -> int:
	_sync_geometry()
	return _geometry.first_index_for_line(line, items_per_line)

## Inverse of the (page-gapped) slot position transform.
func _get_line_for_scroll_pos(pos: float) -> int:
	_sync_geometry()
	return _geometry.line_for_scroll(pos)

## Scroll-axis position of the end of the last line, including the trailing
## pad that lets partial last pages center (no trailing page gap).
func _get_content_end_position() -> float:
	_sync_geometry()
	return _geometry.content_end()

## Nearest snapped page target to `pos`.
func _snap_to_page_target(pos: float) -> float:
	_sync_geometry()
	return _geometry.snap_to_page_target(pos)

## Pushes the snap period/offset to the scroll container and re-aligns the
## current scroll to a page target. Called after layout recalcs so the view
## never rests mid-gap after zoom/resize/orientation changes.
func _update_page_snap_state() -> void:
	if not _scroll_container:
		return
	if not _is_pagination_active():
		if _scroll_container.page_snap_period != 0.0:
			_scroll_container.page_snap_period = 0.0
			_scroll_container.page_snap_offset = 0.0
			_scroll_container.page_snap_max_target = -1.0
		return
	_scroll_container.page_snap_period = _get_page_period()
	_scroll_container.page_snap_offset = 0.0
	_scroll_container.page_snap_max_target = (_get_page_count() - 1) * _get_page_period()
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _update_page_snap_state: period=", _get_page_period(), " max_target=", _scroll_container.page_snap_max_target, " pages=", _get_page_count(), " lpp=", get_lines_per_page(), " stride=", _get_normal_stride(), " axis=", (_get_available_size().y if vertical else _get_available_size().x))
	var current := _get_current_scroll_pos()
	var snap_target := _clamp_scroll_to_range(_snap_to_page_target(current))
	if not is_equal_approx(snap_target, current):
		# A page snap supersedes any pending guarded recalc write: without
		# clearing the guard, the snap's signal can be echo-skipped (buffer
		# never rebuilds at the snap) or the guard's deferred corrective can
		# yank the view back off the page target.
		_reset_transient_scroll_state("page_snap")
		_scroll_container.scroll_to(int(snap_target), false)
	# Re-apply the snap after the ScrollContainer's end-of-frame sort, whose
	# clamp can otherwise undo it and leave the view between pages. The
	# generation guard coalesces zoom drags so only the last recalc applies.
	_page_snap_generation += 1
	call_deferred("_deferred_page_snap", _page_snap_generation)

var _page_snap_generation: int = 0

func _deferred_page_snap(generation: int) -> void:
	if generation != _page_snap_generation:
		return
	if not _scroll_container or not _is_pagination_active():
		return
	var current := _get_current_scroll_pos()
	var snap_target := _clamp_scroll_to_range(_snap_to_page_target(current))
	if not is_equal_approx(snap_target, current):
		_reset_transient_scroll_state("page_snap_deferred")
		_scroll_container.scroll_to(int(snap_target), false)

## Wheel page-step target, resolved through the same target math as
## keyboard/controller navigation (single source of truth for page targets).
func _on_page_step_request(direction: int) -> float:
	if not _is_pagination_active() or not _scroll_container:
		return 0.0
	var period := _get_page_period()
	if period <= 0.0:
		return 0.0
	# Queue from the tween's destination so rapid ticks chain multiple pages.
	var base := _scroll_container.get_target_scroll()
	var page := int(round(base / period))
	var target := _get_page_scroll_target(page + direction)
	if debug_mode:
		if DEBUG_LOG: print("[Grid] page step: base=", base, " period=", period, " page=", page, " dir=", direction, " target=", target)
	return target

# --- Page spacers -----------------------------------------------------------
# Spacers are real (visible, but non-rendering) Controls inside the flow that
# each own one whole line, forcing the FlowContainer wrap that creates the
# visual gap between pages. They never carry a virtual_index and are not part
# of _active_cards; the invariant is:
#   "a spacer sits between two consecutive card children iff their lines are
#    on different pages; no leading or trailing spacers."
# Spacer lifecycle (page + stagger) lives in GridSpacerManager (_spacers);
# boundary math lives in GridGeometry.

## Compute the exact snap ratio for a given number of items per line.
func _calculate_snapped_ratio(desired_ratio: float) -> float:
	_sync_zoom_model_inputs()
	if not _has_valid_available_size():
		return desired_ratio
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return clampf(desired_ratio, 0.05, _zoom_model.get_max_ratio())
	# GRID: snap to the nearest items-per-line stop.
	return _zoom_model.ratio_for_grid_n(_zoom_model.nearest_grid_stop(desired_ratio))

func _finish_recalculate() -> void:
	"""Clear the recalc guard; if a resize arrived mid-pass, run one deferred
	follow-up so the new size is never dropped."""
	_is_recalculating_layout = false
	if _resize_pending:
		_resize_pending = false
		call_deferred("_on_resize_debounced")

func _recalculate_layout():
	var start_us := Time.get_ticks_usec()
	if startup_layout_suppressed:
		return
	if _is_recalculating_layout:
		# A resize (or other recalc request) arrived mid-recalc. Flag it so the
		# in-flight pass runs one deferred follow-up instead of dropping it.
		_resize_pending = true
		return
	if not _flow_container or not _scroll_container:
		return
	if not _has_valid_available_size():
		return

	# Ensure cached settings are fresh before any layout math
	_refresh_cached_settings()
	# Push fresh inputs into the zoom model. If display mode or media aspect
	# ratio changed the base dimensions, the model's stop caches rebuild and
	# LIST/CAROUSEL k re-resolves from its fraction automatically; GRID N is a
	# count and survives (clamped to the new stop range below).
	_sync_zoom_model_inputs()
	# Clamp resolved zoom structure into the current stop range (the window may
	# have shrunk, or base dimensions changed with display mode).
	_zoom_model.clamp_structure_to_stops()

	_is_recalculating_layout = true

	# Save focus state before layout recalculation so we can restore it after
	# cards are recycled and recreated.
	var saved_focus_index: int = _focus.focused_virtual_index()

	# Resolve the scroll anchor for this recalc. Prefer the snapshot taken by
	# _set_grid_n_silent BEFORE items-per-line changed (zoom path); otherwise
	# capture inline, which is correct because N is unchanged in that case.
	# Inline captures (resize, library shrink) may pin to the content end.
	var anchor: GridScrollAnchor = _scroll_anchor
	_scroll_anchor = null
	if anchor == null or not anchor.valid():
		anchor = _capture_scroll_anchor(saved_focus_index, true)

	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions_for_mode()

	if debug_mode:
		if DEBUG_LOG: print("[Grid] _recalculate_layout: zoom=", current_zoom, " target_ratio=", target_card_width_ratio, " base_dims=", base_dims, " view_mode=", view_mode, " vertical=", vertical, " available=", _get_available_size(), " elapsed_us=", Time.get_ticks_usec() - start_us)

	if current_zoom <= 0:
		push_warning("[VirtualScrollGridContainer] Invalid zoom value: %f, skipping layout" % current_zoom)
		_finish_recalculate()
		return

	base_card_size = base_dims

	match view_mode:
		ViewMode.GRID:
			var n := _zoom_model.get_grid_n()
			if n > 0:
				# Exact fill: N whole cards per line, sized directly from the
				# cross-axis space. No ratio/zoom round-trips; the persisted
				# ratio derives from N.
				card_size = _zoom_model.grid_card_size_for_n(n)
			else:
				card_size = base_dims * current_zoom
			focused_card_size = card_size * focus_scale
		ViewMode.LIST:
			# LIST (inverted focus): the cell is the FOCUSED size, so focused width
			# fills the viewport exactly; unfocused cards shrink by 1/focus_scale
			# centered in their cells. Nothing exceeds the cell, so no overflow.
			# Zoom resolves to discrete scroll-axis stops (k cards share the
			# viewport height); the persisted fraction derives from k.
			var k_list := _zoom_model.get_lines_visible()
			card_size = _zoom_model.scroll_stop_size(k_list)
			focused_card_size = card_size
		ViewMode.CAROUSEL:
			# CAROUSEL (inverted focus): the cell is the FOCUSED size, so focused
			# height fills the viewport exactly; unfocused cards shrink by
			# 1/focus_scale centered in their cells. No overflow is reserved.
			var k_car := _zoom_model.get_lines_visible()
			card_size = _zoom_model.scroll_stop_size(k_car)
			focused_card_size = card_size

	var available = _get_available_size()

	# Invalidate scroll-math caches BEFORE the re-pad: card_size changed above,
	# and _pad_total_items/get_lines_per_page must compute against the fresh
	# stride rather than the stale cached one from the previous composition.
	_cached_items_per_line = -1
	_cached_normal_stride = -1.0

	# Re-pad the geometry item count for the current N/page composition
	# (placeholder slots fill the last page/row evenly).
	var old_total_items = _total_items
	_total_items = _pad_total_items(_source_total_items)
	if debug_mode and old_total_items != _total_items:
		if DEBUG_LOG: print("[Grid] re-pad: source=", _source_total_items, " total ", old_total_items, " -> ", _total_items)

	# Determine which parts of the layout actually changed
	var structure_changed = view_mode != _last_layout_view_mode or grid_vertical != _last_layout_grid_vertical
	var focus_changed = not is_equal_approx(focus_scale, _last_layout_focus_scale)
	var card_geometry_changed = not card_size.is_equal_approx(_last_layout_card_size) or not focused_card_size.is_equal_approx(_last_layout_focused_card_size)
	var separation_changed = grid_separation != _last_layout_grid_separation
	var available_changed = not available.is_equal_approx(_last_layout_available_size)
	var total_items_changed = _total_items != _last_layout_total_items
	var pagination_changed = pagination_enabled != _last_layout_pagination
	var staggered_changed = staggered != _last_layout_staggered

	# Display mode and media aspect ratio affect base card dimensions, which
	# feed into card_geometry_changed. Cache them explicitly so a recalc that
	# runs after these settings change cannot be skipped incorrectly.
	var state = UIManager.card_settings_state if UIManager else null
	var current_display_mode = state.get_effective_display_mode() if state else _cached_card_display_mode
	var current_media_ratio = state.media_aspect_ratio if state else 0
	var display_or_ratio_changed = current_display_mode != _last_layout_display_mode or current_media_ratio != _last_layout_media_aspect_ratio

	if debug_mode:
		if DEBUG_LOG: print("[Grid] _recalculate_layout changes: structure=", structure_changed, " focus=", focus_changed, " card_geom=", card_geometry_changed, " separation=", separation_changed, " available=", available_changed, " display_or_ratio=", display_or_ratio_changed, " total_items=", total_items_changed, " pagination=", pagination_changed)

	if not _force_layout_once and not structure_changed and not focus_changed and not card_geometry_changed and not separation_changed and not available_changed and not display_or_ratio_changed and not total_items_changed and not pagination_changed and not staggered_changed:
		# Keep extent and margin writes fresh; both calls are idempotent and write-cached.
		_update_layout()
		_update_margin()
		_finish_recalculate()
		return

	# Update the input cache now that we know work is required
	_last_layout_view_mode = view_mode
	_last_layout_grid_vertical = grid_vertical
	_last_layout_focus_scale = focus_scale
	_last_layout_card_size = card_size
	_last_layout_focused_card_size = focused_card_size
	_last_layout_grid_separation = grid_separation
	_last_layout_available_size = available
	_last_layout_display_mode = current_display_mode
	_last_layout_media_aspect_ratio = current_media_ratio
	_last_layout_total_items = _total_items
	_last_layout_pagination = pagination_enabled
	_last_layout_staggered = staggered

	# Pre-compute scroll math before downstream consumers read it (caches were
	# invalidated earlier, before the re-pad)
	_cached_items_per_line = _get_items_per_line()
	_cached_normal_stride = _get_normal_stride()

	if debug_mode:
		if DEBUG_LOG: print("[Grid] _recalculate_layout: available=", available, " card_size=", card_size, " item_width=", item_width, " item_height=", item_height, " items_per_line=", _cached_items_per_line, " normal_stride=", _cached_normal_stride)

	# items_per_line is by design 1 for LIST/CAROUSEL; only GRID can collapse.
	if debug_mode and _cached_items_per_line == 1 and view_mode == ViewMode.GRID:
		push_warning("[Grid] COLLAPSE DETECTED: items_per_line=1, available=%s, card_size=%s, item_width=%s, item_height=%s" % [available, card_size, item_width, item_height])

	# Only override separation theme constants when the value actually changed
	if grid_separation != _last_h_separation:
		_flow_container.add_theme_constant_override("h_separation", grid_separation)
		_last_h_separation = grid_separation
	if grid_separation != _last_v_separation:
		_flow_container.add_theme_constant_override("v_separation", grid_separation)
		_last_v_separation = grid_separation

	_update_layout()
	_update_margin()
	_flow_container.queue_sort()
	_force_layout_once = false
	_layout_generation += 1
	_layout_settled_with_valid_size = true

	# Restore the scroll position from the pre-recalc anchor so a zoom change
	# keeps the same content in view instead of re-interpreting the old pixel
	# offset against the new stride (which teleports the buffer window and
	# forces a full card rebuild). The clamp uses computed content-end math,
	# never the live scrollbar range (which is stale until end-of-frame sort).
	var restored_scroll: float = -1.0
	if anchor.valid():
		var new_stride: float = _cached_normal_stride
		var new_ipl: int = _cached_items_per_line
		if new_stride > 0.0 and new_ipl > 0:
			var overflow_axis: float = _get_focus_overflow().y if vertical else _get_focus_overflow().x
			var viewport_axis: float = available.y if vertical else available.x
			var max_scroll: float = maxf(0.0, _get_content_end_position() + 2.0 * overflow_axis - viewport_axis)
			var new_scroll: float
			if _is_pagination_active():
				# Pages rest snapped: restore directly to the anchor's page
				# target so the window build, the guarded write, and the
				# page-snap state all aim at the same position. Restoring a
				# free slot+frac position and snapping afterwards raced: with a
				# large page gap (zoomed out) the snap could land >1 stride
				# from the guarded anchor write, get echo-skipped, or be yanked
				# back by the guard's deferred corrective — the page then
				# rested off-center.
				new_scroll = _get_page_scroll_target(_get_page_for_index(anchor.index))
			elif anchor.edge == GridScrollAnchor.Edge.FAR:
				# Pinned to the content end at capture (inline resize / library
				# shrink with the view at the bottom): keep the end in view.
				new_scroll = max_scroll
			else:
				new_scroll = _get_slot_position_for_index(anchor.index, new_ipl, new_stride) + anchor.frac * new_stride
			new_scroll = clampf(new_scroll, 0.0, max_scroll)
			# Keep the focused card inside the viewport in the NEW geometry. The
			# anchor preserves its scroll-relative position, which can strand it
			# fully offscreen when the stride grows past the viewport (zoom-in).
			# Computed math only — never the live scrollbar range. In paginated
			# mode the focus card shares the anchor page by construction, and an
			# end-pinned restore deliberately leaves an offscreen focus alone.
			if not _is_pagination_active() and anchor.edge != GridScrollAnchor.Edge.FAR and saved_focus_index >= 0 and saved_focus_index < _source_total_items:
				var focus_slot := _get_slot_position_for_index(saved_focus_index, new_ipl, new_stride)
				var edge_margin := float(grid_separation)
				if focus_slot - edge_margin < new_scroll:
					new_scroll = focus_slot - edge_margin
				elif focus_slot + new_stride + edge_margin > new_scroll + viewport_axis:
					new_scroll = focus_slot + new_stride + edge_margin - viewport_axis
				new_scroll = clampf(new_scroll, 0.0, max_scroll)
			restored_scroll = new_scroll
			var zb_cur: float = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
			if debug_mode:
				if DEBUG_LOG: print("[Grid] anchor restore: idx=", anchor.index, " frac=", anchor.frac, " edge=", anchor.edge, " ipl=", new_ipl, " stride=", new_stride, " scroll ", zb_cur, " -> ", new_scroll, " max=", max_scroll)

	var _active_before: int = _active_cards.size()
	var _first_before: int = -1
	var _last_before: int = -1
	if _active_cards.size() > 0:
		_first_before = _active_cards[0].get_meta("virtual_index", -1)
		_last_before = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
	# Always recycle cards that fall outside the new buffer target during a layout
	# recalculation. A preset can reset the scroll position while the active cards
	# still hold indices from the previous scroll offset; without recycling, the
	# grid prepends a large range of stale blank cards instead of rebuilding the
	# correct visible range. The recalc-time scroll write pre-raises the
	# scrollbar extent to the grid-computed value, so the end-of-frame sort
	# finds the range already correct and emits no clamp echo to guard against.
	#
	# IMPORTANT: the window is built against the COMPUTED anchor position, not
	# the scrollbar value. The scrollbar range is stale mid-frame and clamps
	# writes beyond the old max (zoom-in at deep positions), which previously
	# rebuilt the window at the clamped offset and recycled the focused card.
	var recycle_pos: float = restored_scroll
	if recycle_pos < 0.0:
		recycle_pos = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
	_on_scroll_value_changed(recycle_pos, true, true)
	var _active_after: int = _active_cards.size()
	var _first_after: int = -1
	var _last_after: int = -1
	if _active_cards.size() > 0:
		_first_after = _active_cards[0].get_meta("virtual_index", -1)
		_last_after = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
	if debug_mode:
		if DEBUG_LOG: print("[Grid] recalc recycle: active ", _active_before, " -> ", _active_after, " (", _first_before, "-", _last_before, " -> ", _first_after, "-", _last_after, ")")

	# Sync the scrollbar to the restored position. The window above was built
	# from the computed position; the extent pre-raise makes the write land
	# exactly even while the live scrollbar range is stale mid-frame.
	if restored_scroll >= 0.0:
		_write_scroll_during_recalc(restored_scroll)

	var update_card_geometry = card_geometry_changed or structure_changed
	var update_focus = focus_changed

	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		if _card_has_focus_scale_enabled:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = _get_focus_scale_inverted()
		if update_focus and _card_has_set_focus_scale:
			card.set_focus_scale(focus_scale)
		if update_card_geometry:
			_configure_card_size_flags(card)
			# Media-panel refresh (force=false): when card geometry changed the
			# derived media bounds change too, so the bounds check inside the
			# card still triggers the immediate stack refresh. force=true here
			# rebuilt the full shader pipeline even when bounds were unchanged.
			if _card_has_update_media_panel_size:
				card._update_media_panel_size(false)

	_finish_recalculate()
	_visual_sync.update_draw_order()
	_ensure_pool_capacity()
	# Rebuild spacer placement for the new page composition, then push the snap
	# period/offset to the scroll container and re-align the scroll to a page
	# target so the view never rests mid-gap after zoom/resize/orientation changes.
	_spacers.reconcile()
	_update_page_snap_state()
	# Commit the flow rect explicitly before sorting. Anchors alone allow the
	# FlowContainer to expand to its content width, which prevents wrapping and
	# leaves every card on the first line during cold startup.
	_flow_container.size = _center_container.size
	# Queue one final sort after every extent/margin/page-composition write.
	# The early sort can commit a pre-layout height and otherwise leave every
	# child on the first line until an unrelated resize forces another pass.
	_flow_container.queue_sort()
	# Geometry/spacers changed: reveal after the sort commits new positions
	# (the reveal runs in _on_flow_sorted, post-sort, at committed offsets).
	_visual_sync.request_reveal()

	# Restore focus to the card that was focused before layout recalculation.
	# The anchor restore above already placed it in view, so this must NOT
	# scroll (re-centering would fight the anchor and, worse, its clamp reads
	# the stale scrollbar range mid-frame, which could strand the target
	# offscreen and lose focus entirely on zoom-in).
	if saved_focus_index >= 0 and saved_focus_index < _source_total_items:
		_focus.restore_focus_only.call_deferred(saved_focus_index)

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 1
	# GRID zoom is N-driven: the items-per-line count is the source of truth.
	if _grid_items_per_line > 0:
		return _grid_items_per_line
	if _cached_items_per_line > 0:
		return _cached_items_per_line

	var available = _get_available_size()
	if vertical:
		var effective_width = maxf(1.0, available.x + grid_separation)
		var result = max(1, int(effective_width / item_width + 0.0001))
		if debug_mode:
			if DEBUG_LOG: print("[Grid] _get_items_per_line: vertical effective_width=", effective_width, " item_width=", item_width, " result=", result)
		return result
	else:
		var effective_height = maxf(1.0, available.y + grid_separation)
		var result = max(1, int(effective_height / item_height + 0.0001))
		if debug_mode:
			if DEBUG_LOG: print("[Grid] _get_items_per_line: horizontal effective_height=", effective_height, " item_height=", item_height, " result=", result)
		return result

func _get_media_aspect_ratio() -> float:
	return _cached_media_aspect_ratio

func _get_card_display_mode() -> int:
	return _cached_card_display_mode

func _get_base_card_height_for_ratio(media_h: float) -> float:
	"""Compute card height that guarantees M3Card's text area fits.

	Delegates to M3Card.get_min_text_height_dp() so the threshold logic
	lives in one place and never drifts out of sync."""
	var card_h = media_h + 500.0  # start well above any threshold
	for i in range(3):
		var text_h = M3Card.get_min_text_height_dp(card_h)
		card_h = media_h + text_h
	return card_h

func _get_content_alignment() -> M3Card.ContentAlignment:
	return _cached_content_alignment

func _get_base_dimensions_for_mode() -> Vector2:
	var ratio = _get_media_aspect_ratio()
	var display_mode = _get_card_display_mode()
	if ratio < 0.0:
		# Fill mode — legacy behavior
		match view_mode:
			ViewMode.GRID:
				return _get_base_dimensions()
			ViewMode.LIST:
				return Vector2(0.0, BASE_LIST_HEIGHT_DP)
			ViewMode.CAROUSEL:
				return Vector2(BASE_CAROUSEL_WIDTH_DP, 0.0)
		return _get_base_dimensions()

	# Ratio mode
	match view_mode:
		ViewMode.GRID:
			var media_h = _MEDIA_BASE_WIDTH_DP / ratio
			if display_mode == 2:
				# Media Only: no text area
				return Vector2(_MEDIA_BASE_WIDTH_DP, media_h)
			var card_h = _get_base_card_height_for_ratio(media_h)
			return Vector2(_MEDIA_BASE_WIDTH_DP, card_h)
		ViewMode.LIST:
			# Horizontal layout: base height = media height
			return Vector2(0.0, _MEDIA_BASE_WIDTH_DP / ratio)
		ViewMode.CAROUSEL:
			# Vertical layout: base width = media width
			return Vector2(_MEDIA_BASE_WIDTH_DP, 0.0)
	return _get_base_dimensions()

func _get_visible_count() -> int:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var available := _get_available_size()
	if vertical:
		var viewport_height = available.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		# Extra row for partial visibility at the viewport edge.
		return ((visible_rows + 1) * items_per_line) + 1
	else:
		var viewport_width = available.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		return ((visible_cols + 1) * items_per_line) + 1

## Returns the number of items that fit in the current viewport
func get_visible_count() -> int:
	return _get_visible_count()

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	z_index = -1

	_scroll_container = SmoothScrollContainer.new()
	_scroll_container.vertical = vertical
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.write_immediate(0.0)
	_scroll_container.clip_contents = true
	# Universal outer margin: inset the scroll container on all sides. The
	# effective viewport for layout math is inset in _get_available_size().
	grid_outer_margin = int(M3Units.dp(GRID_OUTER_MARGIN_DP))
	_scroll_container.offset_left = grid_outer_margin
	_scroll_container.offset_top = grid_outer_margin
	_scroll_container.offset_right = -grid_outer_margin
	_scroll_container.offset_bottom = -grid_outer_margin
	# Scrollbar is not needed; navigation uses mouse wheel, keyboard, or controller.
	# Hiding it removes the scrollbar-width feedback loop from the layout math.
	_scroll_container.vertical_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_SHOW_NEVER
	_scroll_container.horizontal_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_SHOW_NEVER

	# The visual sync module creates its top-level layer in its own _ready.
	add_child(_visual_sync)

	add_child(_scroll_container)

	# Make the scroll container panel transparent so the visual layer behind it is visible.
	_scroll_container.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	_scroll_container.scroll_value_changed.connect(_on_scroll_value_changed)
	_scroll_container.scroll_completed.connect(_visual_sync.on_scroll_completed)
	_scroll_container.scroll_target_provider = _on_follow_focus_target_request
	_scroll_container.page_step_provider = _on_page_step_request

	_margin_container = MarginContainer.new()
	_margin_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.add_child(_margin_container)

	_center_container = Control.new()
	# Plain Controls default to MOUSE_FILTER_STOP, which would swallow wheel
	# scrolls and hover over the whole grid area (Container defaulted to PASS).
	_center_container.mouse_filter = Control.MOUSE_FILTER_PASS
	if vertical:
		_center_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_center_container.size_flags_vertical = Control.SIZE_FILL
	else:
		_center_container.size_flags_horizontal = Control.SIZE_FILL
		_center_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_margin_container.add_child(_center_container)

	_flow_container = FlowContainer.new()
	_flow_container.vertical = not vertical
	_update_flow_container_flags()
	_flow_container.add_theme_constant_override("h_separation", grid_separation)
	_flow_container.add_theme_constant_override("v_separation", grid_separation)
	_flow_container.sort_children.connect(_on_flow_sorted)
	_center_container.add_child(_flow_container)
	# The center rect changes when the viewport/margins change even if the flow
	# itself did not re-sort. It only refreshes the captured chain offset;
	# revealing waits for the FLOW sort, which runs after children are placed.
	# (This used to hook CenterContainer.sort_children; a plain Control has no
	# sort, and anchor layout is synchronous, so `resized` covers the size half
	# and the margin-change half is already caught by the live chain reads in
	# _compute_visual_layer_offset.)
	if not _center_container.resized.is_connected(_on_center_sorted):
		_center_container.resized.connect(_on_center_sorted)

	# Debug/audit tooling lives in a child overlay so its RS signal connections
	# and debug nodes release with it.
	_debug_overlay = GridDebugOverlay.new()
	_debug_overlay.setup(self)
	add_child(_debug_overlay)
	if debug_mode:
		_update_debug_mode()

func get_visual_layer_rid() -> RID:
	if _visual_sync.layer and _visual_sync.layer.is_inside_tree():
		return _visual_sync.layer.get_canvas_item()
	return RID()

func _get_base_dimensions() -> Vector2:
	return Vector2(BASE_CARD_WIDTH_DP, BASE_CARD_HEIGHT_DP)

func refresh_dimensions() -> void:
	"""Recalculate dimensions and refresh layout (call after orientation change or margin change)."""
	# Ensure cached settings are fresh before any layout math
	_refresh_cached_settings()

	# Update grid separation from settings
	_update_grid_separation_from_settings()

	# NOTE: do not zero the flow/center custom_minimum_size here to "force" a
	# recalc — the center's custom min carries the content extent for the
	# scrollbar range, and if the recalc is skipped or the deferred sort runs
	# first, a zeroed min size collapses the layout. The cache invalidation
	# below is the correct trigger; _update_layout/_update_margin own the min
	# sizes.

	# Re-snap zoom to ensure it fits the new dimensions/margins
	var current_ratio = target_card_width_ratio
	var snapped_ratio = _calculate_snapped_ratio(current_ratio)
	# Force a full layout pass past the recalc input-cache early exit.
	_last_layout_available_size = Vector2.ZERO
	_force_layout_once = true
	target_card_width_ratio = snapped_ratio
	_recalculate_layout()

func setup(card_scene_resource: PackedScene, total_items: int, initial_target_ratio: float = -1.0):
	_card_scene = card_scene_resource
	_source_total_items = total_items
	_total_items = _pad_total_items(total_items)

	# If a caller supplies an initial zoom ratio, apply it directly without
	# snapping so the grid starts at the saved user zoom. The final snap to a
	# valid stop happens once when the window size is stable and the grid is
	# explicitly settled.
	if initial_target_ratio >= 0.0:
		if DEBUG_LOG: print("[Grid] setup initial_target_ratio=", initial_target_ratio)
		_sync_zoom_model_inputs()
		_zoom_model.stamp_ratio(initial_target_ratio)

	# When startup is orchestrated by Main, defer pool creation until the final
	# available size is known so the pool is sized for the real viewport instead
	# of the grid's pre-layout size. Main will call _instantiate_card_pool()
	# explicitly during the single settle pass.
	if not startup_layout_suppressed:
		_instantiate_card_pool()

	# Wait for container sizing before initial load only when startup is not being
	# orchestrated. Main suppresses layout and settles explicitly with a known
	# available size, so the awaits would just add blank frames.
	if not startup_layout_suppressed:
		await get_tree().process_frame
		await get_tree().process_frame

	# If startup is being orchestrated by Main, skip the automatic layout
	# so we can perform a single explicit settle after the window size is stable.
	if startup_layout_suppressed:
		return

	if _has_valid_available_size():
		_recalculate_layout()
	if _active_cards.size() == 0:
		_window.initial_load()

func _instantiate_card_pool():
	var start_us := Time.get_ticks_usec()
	if not _card_scene:
		return

	# Compute a conservative pool size for the current viewport and library size
	# instead of always allocating the hardcoded maximum. This avoids paying for
	# dozens of unused cards during startup, especially on smaller libraries.
	var available = _get_available_size()
	if _has_valid_available_size():
		_pool.max_pool_size = _compute_pool_size(available)
		if DEBUG_LOG: print("[Grid] _instantiate_card_pool dynamic max_pool_size=", _pool.max_pool_size, " available=", available, " total_items=", _total_items)

	# Instantiate only the first visible screen synchronously so startup paints
	# sooner; the rest of the pool is topped up a few per frame by
	# _pool.process_growth (off-screen buffer cards don't need to exist yet).
	# Hidden views have no valid size: skip both the seed and the pending
	# growth — they build their pool under the transition cover on first show
	# via _ensure_pool_capacity.
	var sync_count = GridCardPool.STARTUP_SEED if _has_valid_available_size() else 0
	if _last_computed_visible_count > 0:
		sync_count = mini(_pool.max_pool_size, _last_computed_visible_count)
	_pool.instantiate_seed(sync_count, _has_valid_available_size())

	# Cache card capability flags from the probe so we can skip has_method() /
	# string lookups in hot loops (probed once per card scene across all grids).
	_apply_capability_flags(GridCardPool.probe_capabilities(_card_scene))
	if debug_mode:
		if DEBUG_LOG: print("[Grid] _instantiate_card_pool: pool_size=", _pool.max_pool_size, " elapsed_us=", Time.get_ticks_usec() - start_us)

## Assigns the probed capability flags onto the read-cache vars consumed by
## the hot paths (visual setup, refresh, recycle).
func _apply_capability_flags(flags: Dictionary) -> void:
	_card_has_focus_scale_enabled = flags["focus_scale_enabled"]
	_card_has_set_focus_scale = flags["set_focus_scale"]
	_card_has_set_game_with_priority = flags["set_game_with_priority"]
	_card_has_refresh_settings = flags["refresh_settings"]
	_card_has_reset = flags["reset"]
	_card_has_game_prop = flags["game_prop"]
	_card_has_update_media_panel_size = flags["update_media_panel_size"]
	_card_has_update_display = flags["update_display"]
	_card_has_set_image_priority = flags["set_image_priority"]
	_card_has_set_content_alignment = flags["set_content_alignment"]
	_card_has_set_media_aspect_ratio = flags["set_media_aspect_ratio"]
	_card_has_refresh_effects = flags["refresh_effects"]
	_card_has_update_card_state_from_settings = flags["update_card_state_from_settings"]
	_card_has_sync_visual_transform = flags["sync_visual_transform"]
	_card_has_sync_visual_offset = flags["sync_visual_offset"]
	_card_has_visual_layer_opacity = flags["visual_layer_opacity"]
	_card_has_mark_visuals_position_synced = flags["mark_visuals_position_synced"]
	_card_has_unmark_visuals_position_synced = flags["unmark_visuals_position_synced"]
	_card_has_show_loading_skeleton = flags["show_loading_skeleton"]
	_card_has_begin_bulk_layout = flags["begin_bulk_layout"]
	_card_has_end_bulk_layout = flags["end_bulk_layout"]

var _last_computed_visible_count: int = 0

## Recomputes the required pool size for the current layout. Grows _max_pool_size
## immediately (so buffer math sees the new cap) and queues frame-spread card
## instantiation; shrinking is handled passively by pool-return overflow.
func _ensure_pool_capacity() -> void:
	if not _card_scene or _total_items <= 0 or not _scroll_container:
		return
	if not _has_valid_available_size():
		return
	var required = _compute_pool_size(_get_available_size())
	if required <= 0:
		return
	if required > _pool.max_pool_size:
		var live_cards = _pool.cards.size() + _active_cards.size()
		_pool.pending_growth = maxi(_pool.pending_growth, required - live_cards)
	_pool.max_pool_size = required

func _compute_pool_size(available: Vector2) -> int:
	if _total_items <= 0 or not _scroll_container:
		return 0

	# Use the expected card size for the current ratio/available size instead of
	# the default card_size, so the pool is sized for the real layout.
	var expected_card_size = _compute_expected_card_size(available)
	var expected_item_width = expected_card_size.x + grid_separation
	var expected_item_height = expected_card_size.y + grid_separation

	var items_per_line: int
	if vertical:
		items_per_line = max(1, int((available.x + grid_separation) / expected_item_width + 0.0001))
	else:
		items_per_line = max(1, int((available.y + grid_separation) / expected_item_height + 0.0001))

	var stride: float
	var viewport_size: float
	if vertical:
		stride = expected_item_height
		viewport_size = available.y
	else:
		stride = expected_item_width
		viewport_size = available.x

	var visible_lines = max(1, ceili(viewport_size / stride)) if stride > 0 else 1
	var visible_count = visible_lines * items_per_line
	_last_computed_visible_count = visible_count

	var buffer_count = visible_count + (visual_buffer_lines * 2 * items_per_line)

	if _source_total_items <= SMALL_LIBRARY_THRESHOLD:
		return max(_total_items, buffer_count)
	return buffer_count

func _compute_expected_card_size(available: Vector2) -> Vector2:
	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions_for_mode()
	if current_zoom <= 0:
		return base_dims

	match view_mode:
		ViewMode.GRID:
			return base_dims * current_zoom
		ViewMode.LIST:
			return Vector2(available.x, base_dims.y * current_zoom)
		ViewMode.CAROUSEL:
			return Vector2(base_dims.x * current_zoom, available.y)
	return base_dims

# Deterministic sizing: callers (Main, UIManager, views) compute the expected
# available rect from the viewport and container constants, then pass it here so
# layout can run in a single pass without waiting for Godot's deferred size
# propagation.
func set_deterministic_available_size(available: Vector2) -> void:
	# Degenerate sizes (e.g. headless 0x0 window) should not be kept; otherwise
	# every layout pass would collapse to one item per line. Fall back to the
	# grid's own size in those cases.
	if available.x < 2.0 or available.y < 2.0:
		clear_deterministic_available_size()
		return
	_deterministic_available_size = Vector2(maxf(available.x, 1.0), maxf(available.y, 1.0))
	if debug_mode: print("[Grid] set_deterministic_available_size: ", _deterministic_available_size)

func clear_deterministic_available_size() -> void:
	_deterministic_available_size = Vector2.ZERO

func recalculate_layout_with_size(available: Vector2) -> void:
	"""Run a single deterministic layout pass using the supplied available size.

	The deterministic size is kept set so later layout passes (e.g. from
	set_total_count or resize) continue to use the expected viewport rect instead
	of the grid's transient local size. A minimum-size guard prevents degenerate
	headless / tiny-window cases from locking the grid at a 1x1 rect."""
	set_deterministic_available_size(available)
	# Hidden/lazy views can arrive here with a stale target ratio (e.g. the
	# Home-settled ratio) while their own grid size is still zero. Resolve the
	# shared zoom level to this view's snap ratio for the computed available
	# size before snapping, so the final items-per-line matches Home.
	if view_mode == ViewMode.GRID and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
		_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
	refresh_dimensions()

func set_total_count_with_available_size(count: int, available: Vector2, preserve_cache: bool = false) -> void:
	"""Set the total item count using a deterministic available size.

	Use this instead of set_total_count() when the grid's own size may not yet
	reflect the final container rect (e.g. after a tab change or data reload). The
	deterministic size stays active so subsequent layout recalculations keep
	using the expected viewport rect."""
	set_deterministic_available_size(available)
	set_total_count(count, preserve_cache)

func set_total_count(count: int, preserve_cache: bool = false):
	var padded = _pad_total_items(count)
	# Compare the SOURCE count as well: padding can mask a real add/remove
	# (N-1 pads back up to the same total), which would skip the rebuild and
	# leave a stale, index-shifted data cache.
	var count_changed = _source_total_items != count or _total_items != padded
	var old_total := _total_items
	_source_total_items = count
	_total_items = padded
	_update_layout()

	# Extent-shrink clamp: on a total-count decrease the current scroll offset
	# can sit beyond the new content end. Clamp BEFORE the recycle pass below,
	# against the grid-COMPUTED extent (the live scrollbar max is stale for a
	# frame after a rebuild) and through SSC's instant writer, so no tween/chase
	# state survives into the rebuild and the engine's end-of-frame clamp never
	# fires mid-recycle. _refresh_buffer's restore path applies its own clamped
	# target on top of this; this clamp keeps every pass during the rebuild
	# computed against the final position.
	if count_changed and padded < old_total and _scroll_container:
		var cur := _scroll_container.get_scroll_float()
		var clamped := _clamp_scroll_to_range(cur)
		if clamped < cur:
			_scroll_container.write_immediate(clamped)

	# Clear cache if count changed (index-to-data mapping is now stale)
	# or if preserve_cache is explicitly false
	if count_changed or not preserve_cache:
		_refresh_buffer()

	total_count_applied.emit(count)

## Geometry item count: pads the source count with trailing placeholder slots
## so the last page (paginated) or last row/column (plain grid) fills evenly.
func _pad_total_items(count: int) -> int:
	if count <= 0 or view_mode != ViewMode.GRID:
		return count
	var items_per_line = _get_items_per_line()
	if items_per_line <= 1:
		return count
	var unit = items_per_line
	if _is_staggered_active():
		# Pad to whole two-row stagger units so the layout stays even.
		unit = 2 * items_per_line - 1
	if _is_pagination_active():
		unit = items_per_line * get_lines_per_page()
		if _is_staggered_active():
			# Pages start on even rows (lpp is even), so a page holds lpp/2 pairs.
			unit = (2 * items_per_line - 1) * maxi(1, int(get_lines_per_page() / 2.0))
	var padded = int(ceil(float(count) / unit) * unit)
	if debug_mode and padded != count:
		if DEBUG_LOG: print("[Grid] _pad_total_items: source=", count, " ipl=", items_per_line, " lpp=", get_lines_per_page(), " unit=", unit, " padded=", padded)
	return padded

func _update_layout():
	var items_per_line = _get_items_per_line()

	# The center container is a plain Control, so its combined minimum size is
	# exactly its custom_minimum_size — children no longer propagate. It must
	# carry the content extent for the margin container / scrollbar range:
	# this pass owns the CROSS component (row width / column height / card
	# extent), _update_margin() owns the scroll-axis component (flow span).
	# All writes are deterministic functions of layout inputs, never of the
	# transient children extent, so min-size churn during recycling can no
	# longer reach any container's size or position.
	match view_mode:
		ViewMode.GRID:
			if vertical:
				var row_width = items_per_line * card_size.x
				if items_per_line > 1:
					row_width += (items_per_line - 1) * grid_separation
				_flow_container.custom_minimum_size.x = max(row_width, 0.0)
				_flow_container.update_minimum_size()
				if _center_container:
					_center_container.custom_minimum_size.x = max(row_width, 0.0)
			else:
				var col_height = items_per_line * card_size.y
				if items_per_line > 1:
					col_height += (items_per_line - 1) * grid_separation
				_flow_container.custom_minimum_size.y = max(col_height, 0.0)
				_flow_container.update_minimum_size()
				if _center_container:
					_center_container.custom_minimum_size.y = max(col_height, 0.0)
		ViewMode.LIST:
			_flow_container.custom_minimum_size.x = 0
			_flow_container.update_minimum_size()
			if _center_container:
				_center_container.custom_minimum_size.x = card_size.x
		ViewMode.CAROUSEL:
			_flow_container.custom_minimum_size.y = 0
			_flow_container.update_minimum_size()
			if _center_container:
				_center_container.custom_minimum_size.y = card_size.y


func _calculate_visible_index_range(scroll_pos: float, items_per_line: int, stride: float, viewport_size: float) -> Vector2i:
	# One pagination-aware visible-range formula for windowing, data binding,
	# effect queues, status, and prefetch. Partial trailing lines are included.
	var line := _get_line_for_scroll_pos(scroll_pos) if _is_pagination_active() else (int(floor(scroll_pos / stride)) if stride > 0 else 0)
	var end_line: int
	if _is_pagination_active():
		end_line = _get_line_for_scroll_pos(scroll_pos + viewport_size) + 1
	else:
		end_line = int(ceil((scroll_pos + viewport_size) / stride)) if stride > 0 else 1
	return Vector2i(
		_get_first_index_for_line(line, items_per_line),
		mini(_get_first_index_for_line(end_line, items_per_line), _total_items)
	)

func _compute_visible_and_buffer_ranges(scroll_pos: float, items_per_line: int, stride: float, viewport_size: float) -> void:
	"""Compute visible range and buffer target range for the current scroll position.
	Writes directly to member variables to avoid Dictionary allocation."""
	var visible_range := _calculate_visible_index_range(scroll_pos, items_per_line, stride, viewport_size)
	_visible_start_idx = visible_range.x
	_visible_end_idx = visible_range.y

	var visible_count = _visible_end_idx - _visible_start_idx
	# When paginated, a page jump moves the visible window by a whole page;
	# keep the buffer at least one page deep in each direction.
	var buffer_lines = maxi(_current_buffer_lines, get_lines_per_page()) if _is_pagination_active() else _current_buffer_lines
	var total_card_count = visible_count + (buffer_lines * 2 * items_per_line)
	# For small libraries, just load everything to avoid edge-case recycling bugs
	# that can clip the last partial row in grid mode. (Compares the source
	# count so placeholder padding never flips a small library into recycling.)
	if _source_total_items <= SMALL_LIBRARY_THRESHOLD:
		total_card_count = _total_items
	var half_buffer = int((total_card_count - visible_count) / 2.0)
	_buffer_target_start = max(0, _visible_start_idx - half_buffer)
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	if _buffer_target_end == _total_items:
		_buffer_target_start = max(0, _total_items - total_card_count)

	# Align target_start to a row/column start so the first buffered card always
	# opens a row. Without this, FlowContainer misaligns cards when the buffer
	# starts mid-row after incremental recycling or zoom changes.
	_buffer_target_start = _get_first_index_for_line(_get_line_for_index(_buffer_target_start, items_per_line), items_per_line)

	# Recompute target_end after alignment so the buffer size stays consistent
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	# When we're near the end of the list, alignment can leave a partial row
	# outside the buffer (e.g. 98 items, buffer covers 56-97, missing index 97).
	# Extend target_end to always include the last partial row.
	if _buffer_target_end < _total_items and (_total_items - _buffer_target_end) < items_per_line:
		_buffer_target_end = _total_items



## The scroll pass (SSC scroll_value_changed handler + force-pass callers).
## Implementation in GridWindowManager — it owns the window the pass mutates.
func _on_scroll_value_changed(value: float, allow_recycle: bool = true, force_recycle: bool = false):
	_window.on_scroll_value_changed(value, allow_recycle, force_recycle)

func _reset_transient_scroll_state(reason: String) -> void:
	"""Single reset point for transient scroll/jump state. Called from every
	entry point that moves the view programmatically so a stale velocity or
	pending expansion from a previous operation can never fight the new one."""
	# (Velocity needs no reset here: write_immediate resets the SSC baseline.)
	_window.pending_buffer_expansion = false
	_deferred_data_indices.clear()
	SmoothScrollContainer._strace("reset-transient reason=" + reason)
	if trace_verbose:
		if DEBUG_LOG: print("[GridTrace] reset-transient: reason=", reason, " t=", Time.get_ticks_msec())


## External suppression (A-Z carousel scrub): turns network cover loads off
## (cards render placeholders for uncached covers) and, when lifted, retries
## the visible placeholders.
func set_scrub_cover_suppressed(active: bool) -> void:
	if _scrub_cover_suppressed == active:
		return
	_scrub_cover_suppressed = active
	_update_cover_dl_suppression()


## Recompute the effective cover-download suppression. Called from the scroll
## pass (fresh velocity) and from _process (settle detection). On release,
## visible cards stuck on the placeholder are nudged to retry - nothing else
## re-triggers the download they skipped.
func _update_cover_dl_suppression() -> void:
	# Velocity comes from the scroll container: it owns the float motion model
	# and its derivative, and the reading decays to exactly 0 at rest.
	var velocity := _get_scroll_velocity()
	var stride := _get_normal_stride()
	var fast := stride > 0.0 and absf(velocity) > stride * FAST_SCROLL_SUPPRESS_STRIDES
	var want := _scrub_cover_suppressed or fast
	var global_before := CardMediaLoader.downloads_suppressed
	# Scroll-idle gate: while scrolling fast, buffer-card decodes wait so the
	# thread pool's full throughput serves visible covers (they un-gate here on
	# settle and resume behind the visible cards already in the high queue).
	# Owner-refcounted: two live grids can't fight over the process-global gate.
	if fast != _lp_gate_held:
		_lp_gate_held = fast
		if fast:
			MemorySubManager.acquire_low_priority_gate(get_instance_id())
		else:
			MemorySubManager.release_low_priority_gate(get_instance_id())
	if want == _cover_dl_suppressed:
		# Another live grid can overwrite the process-global flag while this
		# grid's local state remains unchanged. Report that mismatch at rest
		# instead of silently repairing it and hiding the diagnostic evidence.
		if CoverTrace.enabled and global_before != want:
			var now := Time.get_ticks_msec()
			if now - _cover_trace_last_mismatch_ms >= 5000:
				_cover_trace_last_mismatch_ms = now
				CoverTrace.event("grid", "suppression_mismatch", {
					"grid": get_instance_id(),
					"want": want,
					"global": global_before,
					"fast": fast,
					"scrub": _scrub_cover_suppressed,
					"velocity": velocity,
					"gate_held": _lp_gate_held,
				})
		return
	var previous := _cover_dl_suppressed
	_cover_dl_suppressed = want
	CardMediaLoader.downloads_suppressed = want
	CoverTrace.event("grid", "suppression_transition", {
		"grid": get_instance_id(),
		"previous": previous,
		"current": want,
		"global_before": global_before,
		"fast": fast,
		"scrub": _scrub_cover_suppressed,
		"velocity": velocity,
		"threshold": stride * FAST_SCROLL_SUPPRESS_STRIDES,
		"gate_held": _lp_gate_held,
	})
	if not want:
		_retry_visible_placeholder_covers()


func _retry_visible_placeholder_covers() -> void:
	var retried := 0
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		var idx: int = card.get_meta("virtual_index", -1)
		if idx < _visible_start_idx or idx >= _visible_end_idx:
			continue
		if card.has_method("retry_cover_if_placeholder"):
			retried += 1
			card.retry_cover_if_placeholder()
	CoverTrace.event("grid", "visible_cover_retry", {
		"grid": get_instance_id(),
		"cards": retried,
		"visible_start": _visible_start_idx,
		"visible_end": _visible_end_idx,
	})



func _configure_card_size_flags(card: Control) -> void:
	if not card is M3Card:
		return

	# Assign the grid-computed decode bucket BEFORE any cover load: live
	# card.size is never a decode basis, so layout transitions can't mint
	# duplicate (path, bucket) cache entries.
	if card is GameCard:
		card.set_assigned_decode_bucket(CardMediaLoader.decode_bucket_for_card_size(card_size, CardMediaLoader.current_dpr()))

	if _card_has_begin_bulk_layout:
		card.begin_bulk_layout()

	match view_mode:
		ViewMode.GRID:
			card.card_layout_mode = M3Card.LayoutMode.VERTICAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.LIST:
			card.card_layout_mode = M3Card.LayoutMode.HORIZONTAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.CAROUSEL:
			card.card_layout_mode = M3Card.LayoutMode.VERTICAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# Render cards one z-level above the grid's visual layer so the visual layer
	# (drawn at the grid's z-index) sits behind the cards while still covering the
	# scroll container background.
	card.z_index = 1

	# Apply content alignment for all modes (GRID also supports START/CENTER/END)
	if _card_has_set_content_alignment:
		var alignment = _get_content_alignment()
		card.set_content_alignment(alignment)

	if _card_has_set_media_aspect_ratio:
		card.set_media_aspect_ratio(_get_media_aspect_ratio())

	# Re-sync focus visuals so a recycled card does not carry a stale focused
	# content_scale into the grid after a layout/theme change.
	if _card_has_set_focus_scale:
		card.set_focus_scale(focus_scale)

	if _card_has_end_bulk_layout:
		card.end_bulk_layout()

func _on_center_sorted() -> void:
	_layout_generation += 1
	_visual_sync.on_content_sorted()

func _on_flow_sorted() -> void:
	_layout_generation += 1
	_visual_sync.on_content_sorted()
	# The sort committed new FLOW child positions, but the container cascade may
	# still be mid-flight: queued sorts flush in message-queue order, so the
	# MARGIN/CENTER re-sorts (which move center.position via the new margins)
	# can run AFTER this flow sort. Stamping now would mix the new child
	# positions with the old chain — a whole-strip offset by the margin delta
	# (one card pitch) flashing for a frame. The reveal therefore defers to
	# the visual sync's pre-draw stamp, which runs after the ENTIRE cascade,
	# before render.
	_visual_sync.on_flow_sorted_post()

func _audit_structure(tag: String) -> void:
	if _debug_overlay:
		_debug_overlay.audit_structure(tag)

func _audit_visual_holes() -> void:
	if _debug_overlay:
		_debug_overlay.audit_visual_holes()

func soak_test(iterations: int = 20) -> void:
	"""Debug stress test: random teleports + scroll bursts with all violation
	audits active. Any [GridInv]/[VisHole]/[RsAudit]/[DrawAudit] output during
	the run indicates a broken invariant. Call from the debugger or a hotkey."""
	if _debug_overlay:
		await _debug_overlay.soak_test(iterations)

func _audit_render_state(tag: String) -> void:
	"""Compare what is actually rendered (RS canvas item transforms, visual
	layer state, scroll content offset) against the layout truth."""
	if _debug_overlay:
		_debug_overlay.audit_render_state(tag)

func _show_skeleton_if_unloaded(card: Control, virtual_index: int) -> void:
	# Cards entering the flow before their data is cached would render blank
	# until setup lands; show the shimmer skeleton in the meantime.
	if not _card_has_show_loading_skeleton:
		return
	if virtual_index >= _source_total_items:
		return  # Placeholder slots render a blank panel, not shimmer.
	if _data.has_index(virtual_index):
		return  # Data ready; setup applies it this pass.
	card.show_loading_skeleton()






func _get_visible_range() -> void:
	var items_per_line := _get_items_per_line()
	var eff := _get_normal_stride()
	var available := _get_available_size()
	var scroll_pos: float = (_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal) if _scroll_container else 0.0
	var viewport_size := available.y if vertical else available.x
	var visible_range := _calculate_visible_index_range(scroll_pos, items_per_line, eff, viewport_size)
	_visible_start_idx = visible_range.x
	_visible_end_idx = visible_range.y


func _update_margin():
	# Wrapper: after margin/extent writes, force the ScrollContainer to
	# recompute its cached content min size. ScrollContainer's
	# _update_scrollbars() reads the CACHED largest_child_min_size member,
	# which only refreshes when the container's own combined minimum size is
	# recomputed — margin writes alone leave it stale, and the end-of-frame
	# sort then clamps the scroll value against the pre-write extent.
	var snapshot := [_last_margin_top, _last_margin_bottom, _last_margin_left, _last_margin_right, _last_flow_height, _last_flow_width]
	_update_margin_writes()
	if [_last_margin_top, _last_margin_bottom, _last_margin_left, _last_margin_right, _last_flow_height, _last_flow_width] != snapshot:
		if _scroll_container:
			_scroll_container.get_combined_minimum_size()

func _update_margin_writes():
	if _active_cards.size() == 0:
		_last_margin_virtual_start = -1
		_last_margin_virtual_end = -1
		if _last_margin_top != 0 or _last_margin_bottom != 0 or _last_margin_left != 0 or _last_margin_right != 0:
			_margin_container.add_theme_constant_override("margin_top", 0)
			_margin_container.add_theme_constant_override("margin_bottom", 0)
			_margin_container.add_theme_constant_override("margin_left", 0)
			_margin_container.add_theme_constant_override("margin_right", 0)
			_last_margin_top = 0
			_last_margin_bottom = 0
			_last_margin_left = 0
			_last_margin_right = 0
		# Never touch the cross-axis min size here: _update_layout owns it, and
		# zeroing it collapses the grid to one line when the flow sorts before
		# cards are re-added (every recycle-all refresh passes through this
		# branch with zero active cards). Only a genuinely empty grid gets its
		# stale scroll-axis extent cleared.
		if _total_items == 0:
			if vertical:
				if _last_flow_height != 0:
					_flow_container.custom_minimum_size.y = 0
					if _center_container:
						_center_container.custom_minimum_size.y = 0
					_last_flow_height = 0
			else:
				if _last_flow_width != 0:
					_flow_container.custom_minimum_size.x = 0
					if _center_container:
						_center_container.custom_minimum_size.x = 0
					_last_flow_width = 0
		return

	var first_idx = _active_cards[0].get_meta("virtual_index", 0)
	var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	_last_margin_virtual_start = first_idx
	_last_margin_virtual_end = last_idx
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	var focus_overflow = _get_focus_overflow()

	if vertical:
		# Add focus overflow padding to top/bottom so edge rows have room to scale.
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		# _get_slot_position_for_index uses floor division, returning the START of a row.
		# For the total content end, we need the END of the last (possibly partial) row,
		# otherwise the last row gets clipped in grid mode where items_per_line > 1.
		# When paginated this also excludes any trailing page gap.
		var total_end = _get_content_end_position()
		var margin_top = first_pos + focus_overflow.y
		var margin_bottom = total_end - after_last_pos + focus_overflow.y
		var flow_height = after_last_pos - first_pos

		# The flow is anchored full-rect in the (plain Control) center container
		# (see _update_flow_container_flags), so a library shorter than the
		# viewport can no longer be centered by the container. Split the slack
		# into the scroll-axis margins to reproduce that centering exactly,
		# while keeping flow.position pinned at 0 on every frame.
		var viewport_axis: float = _get_available_size().y
		var slack: float = viewport_axis - (margin_top + flow_height + margin_bottom)
		if slack > 0.0:
			margin_top += slack / 2.0
			margin_bottom += slack / 2.0

		if int(margin_top) != _last_margin_top or int(margin_bottom) != _last_margin_bottom:
			_margin_container.add_theme_constant_override("margin_top", int(margin_top))
			_margin_container.add_theme_constant_override("margin_bottom", int(margin_bottom))
			_last_margin_top = int(margin_top)
			_last_margin_bottom = int(margin_bottom)
			if trace_verbose:
				if DEBUG_LOG: print("[GridTrace] margin: top=", _last_margin_top, " bottom=", _last_margin_bottom, " flow_h=", flow_height, " first=", first_idx, " last=", last_idx, " t=", Time.get_ticks_msec())

		if not is_equal_approx(flow_height, _last_flow_height):
			_flow_container.custom_minimum_size.y = flow_height
			if _center_container:
				_center_container.custom_minimum_size.y = flow_height
			_last_flow_height = flow_height

		# Cross-axis centering: content narrower than the viewport is centered
		# via the cross-axis margins. This reproduces exactly what the old
		# CenterContainer did (offset = slack/2), but the inputs are the
		# deterministic cross extent owned by _update_layout() — never the
		# transient children min size — and margins are grid-owned writes, so
		# the result cannot flicker mid-cascade.
		var flow_cross: float = _center_container.custom_minimum_size.x if _center_container else 0.0
		var cross_slack: float = maxf(0.0, _get_available_size().x - flow_cross)
		var margin_left_c := int(cross_slack / 2.0)
		var margin_right_c := int(cross_slack / 2.0)
		if margin_left_c != _last_margin_left or margin_right_c != _last_margin_right:
			_margin_container.add_theme_constant_override("margin_left", margin_left_c)
			_margin_container.add_theme_constant_override("margin_right", margin_right_c)
			_last_margin_left = margin_left_c
			_last_margin_right = margin_right_c
		# NOTE: the flow's custom_minimum_size.x is owned by _update_layout()
		# (row width). This pass must NOT zero it — a zeroed cross min wraps
		# the grid to one column.
		_last_flow_width = 0
	else:
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		# END of the last (possibly partial) column; excludes any trailing page gap.
		var total_end = _get_content_end_position()
		var margin_left = first_pos + focus_overflow.x
		var margin_right = total_end - after_last_pos + focus_overflow.x
		var flow_width = after_last_pos - first_pos

		# Horizontal counterpart of the slack compensation above: the flow is
		# anchored full-rect in the center container, so center a library
		# narrower than the viewport via the margins instead of the container.
		var viewport_axis: float = _get_available_size().x
		var slack: float = viewport_axis - (margin_left + flow_width + margin_right)
		if slack > 0.0:
			margin_left += slack / 2.0
			margin_right += slack / 2.0

		if int(margin_left) != _last_margin_left or int(margin_right) != _last_margin_right:
			_margin_container.add_theme_constant_override("margin_left", int(margin_left))
			_margin_container.add_theme_constant_override("margin_right", int(margin_right))
			_last_margin_left = int(margin_left)
			_last_margin_right = int(margin_right)

		if not is_equal_approx(flow_width, _last_flow_width):
			_flow_container.custom_minimum_size.x = flow_width
			if _center_container:
				_center_container.custom_minimum_size.x = flow_width
			_last_flow_width = flow_width

		# Cross-axis centering (horizontal counterpart of the vertical branch):
		# content shorter than the viewport is centered via the cross-axis
		# margins, using the deterministic cross extent from _update_layout().
		var flow_cross: float = _center_container.custom_minimum_size.y if _center_container else 0.0
		var cross_slack: float = maxf(0.0, _get_available_size().y - flow_cross)
		var margin_top_c := int(cross_slack / 2.0)
		var margin_bottom_c := int(cross_slack / 2.0)
		if margin_top_c != _last_margin_top or margin_bottom_c != _last_margin_bottom:
			_margin_container.add_theme_constant_override("margin_top", margin_top_c)
			_margin_container.add_theme_constant_override("margin_bottom", margin_bottom_c)
			_last_margin_top = margin_top_c
			_last_margin_bottom = margin_bottom_c
		# NOTE: the flow's custom_minimum_size.y is owned by _update_layout()
		# for GRID horizontal (column height); see the vertical branch.
		_last_flow_height = 0

## Thread-safe check used by DB worker tasks to skip queries whose results
## would be discarded anyway (superseded by a jump or buffer refresh).
func is_load_pending(offset: int) -> bool:
	return _data.is_load_pending(offset)

func _request_missing_data():
	if _active_cards.size() == 0:
		return

	var missing_indices: Array[int] = []
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		# Placeholder slots (idx >= source count) need no data.
		if idx >= 0 and idx < _source_total_items and not _data.has_index(idx) and not _data.is_index_pending(idx):
			missing_indices.append(idx)

	if missing_indices.size() == 0:
		return
	if trace_verbose:
		if DEBUG_LOG: print("[GridTrace] missing-data: count=", missing_indices.size(), " first=", missing_indices[0], " t=", Time.get_ticks_msec())

	# Buffer-zone indices (beyond the visible zone + one line) defer during
	# fast scroll; the visible zone always requests immediately.
	var line_margin := _get_items_per_line()
	var defer_below := _visible_start_idx - line_margin
	var defer_above := _visible_end_idx + line_margin
	var immediate: Array[int] = []
	for idx in missing_indices:
		if idx >= defer_below and idx < defer_above:
			immediate.append(idx)
		else:
			_deferred_data_indices[idx] = true

	if immediate.size() == 0:
		return
	var batches: Array[Array] = []
	var current_batch: Array[int] = [immediate[0]]

	for i in range(1, immediate.size()):
		if immediate[i] == immediate[i - 1] + 1:
			current_batch.append(immediate[i])
		else:
			batches.append(current_batch)
			current_batch = [immediate[i]]
	batches.append(current_batch)

	for batch in batches:
		if batch.size() > 0:
			var offset = batch[0]
			var limit = batch.size()
			_data.request(offset, limit)

## True when the scroll is settled enough for deferred/best-effort data work:
## velocity below the threshold OR the viewport idle BUFFER_LOAD_IDLE_FLUSH_MS,
## whichever first. Updates _last_scroll_active_ms as a side effect.
func _scroll_is_settled() -> bool:
	var velocity := absf(_get_scroll_velocity())
	var now_ms := Time.get_ticks_msec()
	if velocity > 1.0:
		_last_scroll_active_ms = now_ms
	var stride := _get_normal_stride()
	var slow := velocity <= maxf(stride, 1.0) * BUFFER_LOAD_VELOCITY_STRIDES
	var idle := _last_scroll_active_ms == 0 or now_ms - _last_scroll_active_ms >= BUFFER_LOAD_IDLE_FLUSH_MS
	return slow or idle

## Flush buffer-zone data loads deferred during fast scroll. Runs from
## _process: drains when the scroll velocity drops below the threshold OR the
## viewport has been idle BUFFER_LOAD_IDLE_FLUSH_MS, whichever first.
func _flush_deferred_data_loads() -> void:
	if _deferred_data_indices.is_empty():
		return
	if not _scroll_is_settled():
		return
	var indices: Array = _deferred_data_indices.keys()
	_deferred_data_indices.clear()
	indices.sort()
	# Drop indices that became cached/pending meanwhile or scrolled away; the
	# current window's own _request_missing_data re-finds anything still needed.
	var live: Array[int] = []
	for idx in indices:
		if idx < 0 or idx >= _source_total_items:
			continue
		if _data.has_index(idx) or _data.is_index_pending(idx):
			continue
		if not is_index_near_buffer(idx):
			continue
		live.append(idx)
	var i := 0
	while i < live.size():
		var offset: int = live[i]
		var limit := 1
		while i + limit < live.size() and live[i + limit] == offset + limit:
			limit += 1
		_data.request(offset, limit)
		i += limit

## Safety net for stranded skeletons. In-flight data requests can be dropped
## without a retry — pruned by a window jump while the DB task was still
## queued (its result then lands empty via is_load_pending), or the task
## queue overflowing — and steady-state window passes take the light path
## which skips data requests, so the hole would never heal at idle. Re-run
## the missing-data sweep when the scroll is settled, on a cooldown so a
## genuinely unfetchable index can't re-query the DB every frame.
func _sweep_missing_data_at_idle() -> void:
	if _active_cards.is_empty():
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_missing_data_sweep_ms < MISSING_DATA_SWEEP_MS:
		return
	if not _scroll_is_settled():
		return
	_last_missing_data_sweep_ms = now_ms
	_request_missing_data()

## True when idx is within one buffer-window width of the current buffer
## window. Stale prefetch/decode completions use it to drop work for content
## that has scrolled away. Before the first scroll pass (no window yet)
## everything counts as near so nothing is dropped blindly.
func is_index_near_buffer(idx: int) -> bool:
	if _window.last_pass_buffer_start < 0 or _window.last_pass_buffer_end <= _window.last_pass_buffer_start:
		return true
	var width := _window.last_pass_buffer_end - _window.last_pass_buffer_start
	return idx >= _window.last_pass_buffer_start - width and idx < _window.last_pass_buffer_end + width

func _prefetch_scroll_lead(stride: float, items_per_line: int) -> void:
	"""Prefetch data beyond the buffer edge in the current scroll direction so
	incoming rows already have data when they enter the viewport (~150ms lead).
	Without this, every window shift leaves the entering rows blank for the
	~100ms DB round-trip, visible as flickering/disappearing rows."""
	# During a programmatic jump the destination window is already being built;
	# directional prefetch would only crowd the queues and delay visible cards.
	if _programmatic_focus_index >= 0:
		return
	var velocity := _get_scroll_velocity()
	if stride <= 0.0 or _total_items <= 0 or absf(velocity) < stride * 2.0:
		return
	var lead_px: float = clampf(absf(velocity) * 0.15, stride * 2.0, stride * 8.0)
	var lead_items: int = int(ceil(lead_px / stride)) * items_per_line
	var start: int
	var end: int
	if velocity > 0.0:
		start = _buffer_target_end
		end = mini(_total_items, start + lead_items)
	else:
		end = _buffer_target_start
		start = maxi(0, end - lead_items)
	if end <= start:
		return
	var missing: Array[int] = []
	for idx in range(start, end):
		if idx < _source_total_items and not _data.has_index(idx) and not _data.is_index_pending(idx):
			missing.append(idx)
	if missing.size() == 0:
		return
	if trace_verbose:
		if DEBUG_LOG: print("[GridTrace] prefetch-lead: count=", missing.size(), " first=", missing[0], " vel=", velocity, " t=", Time.get_ticks_msec())
	_data.request(missing[0], missing.size())

func _check_preload_needed():
	var visible_count = _get_visible_count()
	var preload_distance = visible_count * data_preload_multiplier
	var buffer_size = visible_count * data_buffer_multiplier

	if _virtual_end < _source_total_items - 1:
		var distance_to_end = _source_total_items - 1 - _virtual_end
		if distance_to_end > 0 and distance_to_end <= preload_distance:
			var next_batch_start = _virtual_end + 1
			if not is_load_pending(next_batch_start) and not _data.has_index(next_batch_start):
				_data.request(next_batch_start, min(buffer_size, _source_total_items - next_batch_start))

	if _virtual_start > 0:
		var distance_to_start = _virtual_start
		if distance_to_start > 0 and distance_to_start <= preload_distance:
			var prev_batch_start = max(0, _virtual_start - buffer_size)
			if not is_load_pending(prev_batch_start) and not _data.has_index(prev_batch_start):
				_data.request(prev_batch_start, min(buffer_size, _virtual_start - prev_batch_start))

func _update_card_priorities(visible_start_idx: int, visible_end_idx: int):
	# Mark visible cards and one extra row on each side as high priority so
	# covers decode before the row fully enters the viewport.
	var items_per_line = _get_items_per_line()
	var high_start: int = maxi(0, visible_start_idx - items_per_line)
	var high_end: int = mini(_total_items, visible_end_idx + items_per_line)
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue

		var card_high_priority = idx >= high_start and idx < high_end

		if _card_has_set_image_priority:
			card.set_image_priority(card_high_priority)

func refresh_focus_lock() -> void:
	"""Re-sync focus-lock state and ensure the viewport signal is connected.
	Call after reparenting or when the setting may have changed outside the
	normal change event flow."""
	_focus.reconnect_viewport()

func navigate_direction(dir: String, from_index: int = -1) -> bool:
	"""Move focus one step in the given direction. Returns true if the event was consumed."""
	return _focus.navigate_direction(dir, from_index)

## Public read of the focused card's virtual index (-1 when focus is outside
## the grid). External callers (main.gd) use this instead of walking ancestors
## for the virtual_index meta themselves.
func get_focused_virtual_index() -> int:
	return _focus.focused_virtual_index()

## Public focus-restore entry point: focus the card for `index` without
## scrolling, with follow-focus suppression handled internally. No-op when the
## card isn't in the buffer or isn't focusable.
func restore_focus_to_index(index: int) -> void:
	_focus.restore_focus_to_index(index)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	if trace_verbose:
		if DEBUG_LOG: print("[GridTrace] items-loaded: offset=", offset, " count=", items.size(), " t=", Time.get_ticks_msec())
	if debug_mode:
		if DEBUG_LOG: print("[Grid] on_items_loaded: offset=", offset, " count=", items.size(), " pending=", _pending_visual_setup.size(), " cache_size_before=", _data.size())

	# Ingest into the cache (stale results — superseded by a jump or buffer
	# refresh while the DB task was in flight — are dropped inside).
	var landed := _data.ingest(items, offset)
	if landed.is_empty():
		return

	# Warm the texture cache as data lands (covers both window and prefetch
	# loads) so cover art is decoded before its row scrolls into view. Same
	# grid-computed bucket the cards are assigned, so warmed entries match
	# card lookups exactly. Grid + index enable the stale-decode drop.
	var bucket := CardMediaLoader.decode_bucket_for_card_size(card_size, CardMediaLoader.current_dpr())
	for cache_key in landed:
		CardMediaLoader.preload_cover(_data.get_game(cache_key), bucket, self, cache_key)

	_get_visible_range()
	var visible_start_idx: int = _visible_start_idx
	var visible_end_idx: int = _visible_end_idx

	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= offset and idx < offset + items.size():
			# Off-screen buffer cards may have their visual setup deferred; leave
			# them for _process_pending_visual_setup() so we don't pay the cost now.
			if card.has_meta("needs_visual_setup"):
				continue
			var data_idx = idx - offset
			if data_idx < items.size():
				var card_visible = idx >= visible_start_idx and idx < visible_end_idx
				if _card_has_set_game_with_priority:
					card.set_game_with_priority(items[data_idx], card_visible)
				else:
					card.game = items[data_idx]
				_data.touch(idx)

	_update_card_priorities(visible_start_idx, visible_end_idx)
	_window.flush_pending_visual_setup_for_visible_zone()

func _refresh_buffer(preserve_scroll: bool = false):
	# Capture live focus state before recycling so we can restore it after rebuild.
	var saved_focus_index: int = _focus.focused_virtual_index()
	# Only a live in-grid focus may trigger a focus restore after the rebuild;
	# the _last_focused fallback below is memory only, and must not let a
	# background rebuild steal focus back from the nav rail or other views.
	var focus_was_in_grid: bool = saved_focus_index >= 0
	# Remember the last focused index for fallback restoration even if focus is
	# not currently owned by this grid.
	if saved_focus_index < 0 and _focus.last_index >= 0:
		saved_focus_index = _focus.last_index
	# Capture the raw scroll offset when requested so we can restore position for
	# non-focused cards (e.g. mouse users) across view-mode switches.
	var saved_scroll_offset: float = 0.0
	if preserve_scroll and _scroll_container:
		saved_scroll_offset = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal

	while _active_cards.size() > 0:
		_window.recycle_card_at_index(0)
	_spacers.clear_all()

	_data.clear()
	_active_cards_by_index.clear()
	_effect_queue.clear_all()
	_margin_container.add_theme_constant_override("margin_top", 0)
	_margin_container.add_theme_constant_override("margin_bottom", 0)
	_margin_container.add_theme_constant_override("margin_left", 0)
	_margin_container.add_theme_constant_override("margin_right", 0)
	# Do NOT zero _flow_container/_center_container.custom_minimum_size here:
	# the center's custom min carries the content extent for the scrollbar
	# range, and if the restoring recalc below is skipped (guards) or the flow
	# sorts first, a zeroed min size collapses the layout. _update_layout/
	# _update_margin own the min sizes; the cache invalidations below already
	# force the recalc that rewrites them.
	# Reset the write-caches to the sentinel so the next _update_margin() cannot
	# skip a write while the real overrides sit at zero (cache/actual desync).
	_last_margin_top = -1
	_last_margin_bottom = -1
	_last_margin_left = -1
	_last_margin_right = -1
	_last_flow_height = -1.0
	_last_flow_width = -1.0
	_last_margin_virtual_start = -1
	_last_margin_virtual_end = -1
	# Invalidate the layout input cache so the following _recalculate_layout()
	# cannot early-exit. This matters when a buffer refresh happens while total
	# count and geometry are unchanged (e.g. after sync completes).
	_last_layout_available_size = Vector2.ZERO
	_last_layout_total_items = -1
	_last_layout_card_size = Vector2.ZERO
	_last_layout_focused_card_size = Vector2.ZERO
	_window.reset_bounds()

	# Only zero the scroll when not preserving it. View-mode switches remember
	# the focused item (or raw offset) and restore it after the rebuild.
	if not preserve_scroll and _scroll_container:
		_reset_transient_scroll_state("refresh_buffer")
		_scroll_container.write_immediate(0.0)

	_recalculate_layout()
	if _active_cards.size() == 0:
		_window.initial_load()
		_recalculate_layout()
	_visual_sync.update_draw_order()

	# Restore focus to the card that owned it before recycle; fall back to the
	# saved raw scroll offset if no focus target exists. scroll_to_index_and_focus
	# waits for the target card to exist and suppresses the smooth-scroll
	# response, so the jump is instantaneous.
	# Never grab card focus while an overlay (e.g. the settings dialog) is
	# showing: the steal would fight the overlay's focus pull-back.
	if preserve_scroll:
		# The platform/filter path can shrink the library far below the saved
		# index (random jump deep, then RB/LB to a small platform): restoring an
		# out-of-range index drives slot math past the content end and the
		# container's instant path EXTENDS the scrollbar range to reach it,
		# corrupting every subsequent window computation. Clamp to the new
		# source range.
		if saved_focus_index >= 0 and saved_focus_index >= _source_total_items:
			saved_focus_index = _source_total_items - 1
		if saved_focus_index >= 0 and M3Overlay._get_topmost_overlay() == null:
			call_deferred("scroll_to_index_and_focus", saved_focus_index, false)
		elif _scroll_container:
			_reset_transient_scroll_state("refresh_buffer_restore")
			# Clamp against the GRID-COMPUTED range (fresh after the recalc
			# above); the live scrollbar range is stale mid-frame.
			_scroll_container.write_immediate(_clamp_scroll_to_range(saved_scroll_offset))
	elif focus_was_in_grid and M3Overlay._get_topmost_overlay() == null:
		# Non-preserve rebuilds (e.g. Steam import changes, post-sync reload)
		# recycle the focused card; restore focus to it so controller users
		# aren't stranded. Scroll position still resets as before.
		call_deferred("scroll_to_index_and_focus", saved_focus_index, false)

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var items_per_line := _get_items_per_line()
	var eff := _get_normal_stride()
	var available := _get_available_size()
	var scroll_pos: float = (_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal) if _scroll_container else 0.0
	var viewport_size := available.y if vertical else available.x
	var visible_range := _calculate_visible_index_range(scroll_pos, items_per_line, eff, viewport_size)
	return {
		"start": visible_range.x,
		"end": visible_range.y,
		"total": _total_items,
		"source_total": _source_total_items,
		"buffer_start": _virtual_start,
		"buffer_size": _active_cards.size(),
		"active_cards_count": _active_cards.size()
	}

func get_card_at_index(index: int) -> Control:
	return _window.get_card_at_index(index)

## Replace cached data for a game (matched by romm_id) without a buffer
## rebuild, so an offscreen card picks up the new state when scrolled into
## view. Live cards are NOT touched here — the view's _on_game_updated path
## updates those in place.
func update_cached_game(game: GameResource) -> void:
	_data.update_game(game)

func _clamp_scroll_to_range(offset: float) -> float:
	if not _scroll_container:
		return offset
	_sync_geometry()
	if _is_pagination_active():
		# Clamp against the page composition instead of the live scrollbar range:
		# the scrollbar's max is stale while a layout recalc's margin changes are
		# still propagating, which let zoom snaps clamp to (or get undone to)
		# positions between pages.
		return _geometry.clamp_to_range(offset)
	# Clamp against COMPUTED content end, never the live scrollbar: the
	# scrollbar's max is stale for a frame after a library shrink / rebuild
	# (it updates on the next sort), and a stale-large max lets out-of-range
	# targets through — the instant scroll path then extends the range to fit,
	# corrupting every subsequent window computation.
	if not _has_valid_available_size() or _total_items <= 0:
		var fallback_sb: ScrollBar = (_scroll_container.get_v_scroll_bar() as ScrollBar) if vertical else _scroll_container.get_h_scroll_bar()
		if not fallback_sb:
			return offset
		return clampf(offset, fallback_sb.min_value, maxf(fallback_sb.min_value, fallback_sb.max_value - fallback_sb.page))
	return _geometry.clamp_to_range(offset)

func _get_current_scroll_pos() -> float:
	if not _scroll_container:
		return 0.0
	return float(_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal)

## Writes a scroll position during a layout recalc. Mid-frame the scrollbar's
## max_value is stale (it updates at the end-of-frame sort), so the extent is
## pre-raised to the GRID-COMPUTED value — what the sort will compute anyway —
## and the write goes through SSC's single-writer API. No echo guards: the
## write lands exactly, so there is no clamp echo to suppress.
func _write_scroll_during_recalc(pos: float) -> void:
	if not _scroll_container:
		return
	var scrollbar: ScrollBar = (_scroll_container.get_v_scroll_bar() as ScrollBar) if vertical else _scroll_container.get_h_scroll_bar()
	var viewport_axis: float = _get_available_size().y if vertical else _get_available_size().x
	# scrollbar.page is 0 before the first sort; fall back to the viewport.
	var page: float = maxf(scrollbar.page if scrollbar else 0.0, viewport_axis)
	_scroll_container.write_immediate_with_extent(pos, pos + page)
	if trace_verbose:
		if DEBUG_LOG: print("[GridTrace] recalc-write: pos=", pos, " actual_after=", _get_current_scroll_pos(), " sb_max=", scrollbar.max_value if scrollbar else -1.0, " page=", scrollbar.page if scrollbar else -1.0, " t=", Time.get_ticks_msec())

func get_centered_scroll_for_index(idx: int) -> float:
	"""Scroll position that places the center of slot `idx` at the viewport
	center (clamped to the scrollable range). Cards grow around their center
	when focused, so the unfocused card_size is the correct centering basis."""
	_sync_geometry()
	return _clamp_scroll_to_range(_geometry.center_offset(idx))

func get_follow_focus_scroll_target(idx: int) -> float:
	"""Where to scroll when card `idx` gains focus, honoring the centering mode.
	Both modes are edge-triggered: no scroll happens until the focused card's
	visual bounds (including its focus scale-up) cross a thin margin at a
	viewport edge. Returns the current scroll position when no scroll is needed."""
	_sync_geometry()
	return _clamp_scroll_to_range(_geometry.reveal_offset(idx, _get_current_scroll_pos(), float(grid_separation), _focus_centering_mode == FocusCentering.CENTER))

func _on_follow_focus_target_request(control: Control) -> float:
	"""Provider callback for SmoothScrollContainer follow-focus scrolling.
	Maps the focused control to its virtual index and uses layout math rather
	than measuring global rects (which can be stale right after recycling)."""
	var node := control
	while node and node != self:
		if node.has_meta("virtual_index"):
			var vidx: int = node.get_meta("virtual_index", -1)
			var ftarget := get_follow_focus_scroll_target(vidx)
			SmoothScrollContainer._strace("follow-focus idx=" + str(vidx) + " target=" + str(ftarget) + " current=" + str(_get_current_scroll_pos()))
			return ftarget
		node = node.get_parent()
	return _get_current_scroll_pos()

func scroll_to_index(index: int, animate: bool = false, duration_multiplier: float = 1.0):
	# Out-of-range indices (stale restore targets after a library shrink) must
	# not reach the slot math: they push the scroll target past the content end
	# and the instant path extends the scrollbar range to fit, corrupting it.
	if index < 0 or index >= _source_total_items:
		return
	if _scroll_container:
		_reset_transient_scroll_state("scroll_to_index")
		_scroll_container.scroll_to(int(get_centered_scroll_for_index(index)), animate, duration_multiplier)

func scroll_to_index_and_focus(index: int, animate: bool = false, duration_multiplier: float = 1.0) -> void:
	"""Scroll to an item and focus it, honoring the focus-centering mode."""
	if not _scroll_container:
		return
	if index < 0 or index >= _source_total_items:
		return
	_focus.request_id += 1
	var request_id := _focus.request_id
	# Defocus the grid before scrolling so the currently focused card is not
	# recycled mid-jump, which would hand focus to a temporary card and trigger
	# a competing smooth-scroll back toward the top.
	_focus.release_focus_inside_grid()
	_focus.pending_index = index
	_programmatic_focus_index = -1
	_scroll_container.follow_focus_suppressed = false
	_reset_transient_scroll_state("jump")

	var target := get_follow_focus_scroll_target(index)
	var current := _get_current_scroll_pos()
	var needs_scroll := not is_equal_approx(target, current)
	SmoothScrollContainer._strace("grid-jump idx=" + str(index) + " target=" + str(target) + " current=" + str(current) + " animate=" + str(animate))

	if not needs_scroll or not animate:
		# Inside the trigger margin (or instant jump): no animation, focus immediately.
		if needs_scroll:
			_scroll_container.scroll_to(int(target), false)
		var card := get_card_at_index(index)
		if card and is_instance_valid(card) and card.is_inside_tree():
			_focus.apply_focus_to_card(card)
		else:
			_deferred_focus_index(index, request_id, 0)
		return

	# Animated: suppress follow-focus for the duration of the scroll so no
	# competing tween starts; the suppression is lifted in _process() once the
	# scroll settles (_programmatic_focus_index poll).
	_programmatic_focus_index = index
	_scroll_container.follow_focus_suppressed = true
	_scroll_container.scroll_to(int(target), true, duration_multiplier)
	_deferred_focus_index(index, request_id, 0)

func _deferred_focus_index(index: int, request_id: int, attempt: int) -> void:
	"""Wait until the card for `index` exists, then grab focus."""
	if request_id != _focus.request_id:
		return
	if _focus.pending_index != index:
		# Focused already, superseded by a newer request, or cancelled.
		return

	var card := get_card_at_index(index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		_focus.apply_focus_to_card(card)
		return

	# The card may not enter the buffer until the scroll passes its row, which
	# can take seconds on long animated jumps. Keep waiting while this request's
	# scroll is in flight; the _process settle backstop performs the final focus
	# and lifts follow-focus suppression once the scroll ends.
	var in_flight := _scroll_container != null and _scroll_container.is_scrolling()
	if in_flight or attempt < 5:
		await get_tree().process_frame
		_deferred_focus_index(index, request_id, attempt + 1)

func focus_last_or_first_card() -> void:
	"""Focus the last focused card, or the first card if none was focused."""
	_focus.focus_last_or_first_card()

# --- Debug/audit facades (implementation: GridDebugOverlay child) -------------

func _update_debug_visuals(visible_start_idx: int, visible_end_idx: int):
	if _debug_overlay:
		_debug_overlay.update_debug_visuals(visible_start_idx, visible_end_idx)

func _update_debug_mode():
	if _debug_overlay:
		_debug_overlay.set_enabled(debug_mode)

func refresh_all_card_effects() -> void:
	"""Refresh effects on active cards. Cards in the visible zone plus a small
	buffer are rebuilt immediately; the rest are queued and drained over frames
	to avoid stalling on large grids."""
	_effect_queue.refresh_all()

func refresh_all_card_configs() -> void:
	"""Re-apply size flags, alignment, aspect ratio, and display mode to all active cards.
	Call when cached settings (alignment, ratio, display mode) change so that
	cards already in the viewport pick up the new values immediately."""
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		# Display state determines text/background reservation, so it is applied
		# before size flags and media bounds are recomputed.
		if _card_has_update_card_state_from_settings:
			card._update_card_state_from_settings()
		_configure_card_size_flags(card)
		if _card_has_update_media_panel_size:
			card._update_media_panel_size(true)

func refresh_all_card_displays() -> void:
	"""Refresh render-only text state without rebuilding media, effects, or layout."""
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("refresh_text_settings"):
			card.refresh_text_settings()
