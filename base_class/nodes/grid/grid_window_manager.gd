class_name GridWindowManager
extends RefCounted

## Owns the grid's active window: which cards exist (cards / by_index), which
## still need visual setup (pending_setup), the window bounds
## (virtual_start/virtual_end), and every operation that changes membership —
## the scroll pass, recycle/add, batch ops, teleport reassign, async buffer
## expansion, and the pending visual-setup drain. This is the ONE writer of
## window membership; layout/lifecycle code rebuilds the window only through
## these methods. The grid exposes read-only views (_active_cards etc.) for
## the other modules, the debug overlay, and tests.
## Reads grid state (geometry, ranges, config) via the backref.

const DEBUG_LOG: bool = false

const ASYNC_BUFFER_CARDS_PER_FRAME: int = 10
const ASYNC_SETUP_CARDS_PER_FRAME: int = 8

var _grid: VirtualScrollGridContainer = null

# --- Window membership (the module's truth; grid exposes read views) --------
var cards: Array[Control] = []
var by_index: Dictionary[int, Control] = {}
var pending_setup: Dictionary = {}  # virtual_index -> card awaiting visual setup

# Window bounds (kept consistent with the active card list so scroll/recycle
# math and preload checks never use stale bounds).
var virtual_start: int = 0
var virtual_end: int = 0

# Scroll-pass reentrancy guard (stuck-state watchdog lives in the grid's
# _process) and last-pass buffer cache for the light path + is_index_near_buffer.
var processing_scroll: bool = false
var trace_stuck_count: int = 0
var last_pass_buffer_start: int = -1
var last_pass_buffer_end: int = -1

# Async buffer expansion: after startup, the off-screen buffer is filled over
# subsequent frames (budget-gated) instead of one hitchy pass.
var pending_buffer_expansion: bool = false

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func reset_bounds() -> void:
	virtual_start = 0
	virtual_end = 0

func get_card_at_index(index: int) -> Control:
	return by_index.get(index, null)

func is_index_visible(idx: int) -> bool:
	return idx >= _grid._visible_start_idx and idx < _grid._visible_end_idx

# --- Scroll pass --------------------------------------------------------------

func on_scroll_value_changed(value: float, allow_recycle: bool = true, force_recycle: bool = false):
	if processing_scroll:
		trace_stuck_count += 1
		if _grid.trace_verbose and (trace_stuck_count <= 3 or trace_stuck_count % 100 == 0):
			if DEBUG_LOG: print("[GridTrace] HANDLER BLOCKED (_is_processing_scroll stuck): value=", value, " count=", trace_stuck_count, " t=", Time.get_ticks_msec())
		return
	trace_stuck_count = 0
	processing_scroll = true
	if _grid.trace_verbose:
		if DEBUG_LOG: print("[GridTrace] pass: value=", value, " recycle=", allow_recycle, " force=", force_recycle, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

	if _grid._total_items == 0 or not _grid._scroll_container:
		processing_scroll = false
		return

	var scroll_pos = int(value)
	var items_per_line = _grid._get_items_per_line()
	var stride = _grid._get_normal_stride()

	_grid._update_cover_dl_suppression()

	var available := _grid._get_available_size()
	var viewport_size = available.y if _grid.vertical else available.x
	_grid._compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	if not force_recycle and cards.size() > 0 and _grid._buffer_target_start == last_pass_buffer_start and _grid._buffer_target_end == last_pass_buffer_end:
		# Light path: the buffer window didn't move, so no recycle/add, margin,
		# or data-request work is needed — just keep visuals and focus current.
		_grid._prefetch_scroll_lead(stride, items_per_line)
		_grid._effect_queue.flush_for_visible_zone()
		flush_pending_visual_setup_for_visible_zone()
		_grid._visual_sync.update_pagination_opacity()
		# No stamp here: pass-end runs mid-cascade (margin/center sorts queued
		# by this very pass may still be pending), and any stamp is superseded
		# by _on_frame_pre_draw before render anyway. Mid-cascade stamps were a
		# mixed-generation flash source.
		_grid.visible_range_changed.emit(_grid._visible_start_idx, _grid._visible_end_idx, _grid._total_items)
		_grid._focus.try_apply_pending_focus()
		if _grid.trace_verbose:
			if DEBUG_LOG: print("[GridTrace] pass-end (light): scroll=", scroll_pos, " active=", cards.size(), " buffer=", _grid._buffer_target_start, "-", _grid._buffer_target_end, " t=", Time.get_ticks_msec())
		processing_scroll = false
		return

	var structure_changed := stage_recycle_and_fill(allow_recycle)
	last_pass_buffer_start = _grid._buffer_target_start
	last_pass_buffer_end = _grid._buffer_target_end

	if cards.size() > 0:
		virtual_start = cards[0].get_meta("virtual_index", 0)
		virtual_end = cards[cards.size() - 1].get_meta("virtual_index", 0)

	_grid._request_missing_data()
	_grid._prefetch_scroll_lead(stride, items_per_line)

	var should_update_margin = true
	if cards.size() > 0:
		var current_first = cards[0].get_meta("virtual_index", 0)
		var current_last = cards[cards.size() - 1].get_meta("virtual_index", 0)
		should_update_margin = (current_first != _grid._last_margin_virtual_start) or (current_last != _grid._last_margin_virtual_end)
	if should_update_margin:
		_grid._update_margin()
	_grid._check_preload_needed()
	_grid._update_card_priorities(_grid._visible_start_idx, _grid._visible_end_idx)

	# Scrolling may bring queued effect-rebuild or visual-setup cards into the
	# visible zone; finish them immediately so the user doesn't see blanks.
	_grid._effect_queue.flush_for_visible_zone()
	flush_pending_visual_setup_for_visible_zone()
	_grid._visual_sync.update_pagination_opacity()
	# No pass-end stamp: pre-draw re-stamps post-cascade every changed frame.
	# Cards added/recycled this pass stay hidden until the FlowContainer sort
	# commits their positions; _on_flow_sorted reveals them exactly once,
	# post-sort, at the deterministic offset above.
	if structure_changed:
		_grid._visual_sync.request_reveal()
		_grid.call_deferred("_audit_visual_holes")
	_grid.call_deferred("_audit_render_state", "post-pass")
	_grid._visual_sync.update_draw_order()
	_grid._audit_structure("pass-end")

	_grid.visible_range_changed.emit(_grid._visible_start_idx, _grid._visible_end_idx, _grid._total_items)

	# If a programmatic focus is waiting for this scroll rebuild, try to land it now.
	_grid._focus.try_apply_pending_focus()

	if _grid.debug_mode:
		_grid._update_debug_visuals(_grid._visible_start_idx, _grid._visible_end_idx)

	if _grid.trace_verbose:
		var gt_first: int = cards[0].get_meta("virtual_index", -1) if cards.size() > 0 else -1
		var gt_last: int = cards[cards.size() - 1].get_meta("virtual_index", -1) if cards.size() > 0 else -1
		var gt_expected_pos := -float(_grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal)
		var gt_actual_pos: float = _grid._margin_container.position.y if _grid.vertical else _grid._margin_container.position.x
		if DEBUG_LOG: print("[GridTrace] pass-end: scroll=", scroll_pos, " active=", cards.size(), " window=", gt_first, "-", gt_last, " buffer=", _grid._buffer_target_start, "-", _grid._buffer_target_end, " pending_setup=", pending_setup.size(), " margin_pos=", gt_actual_pos, " expected_pos=", gt_expected_pos, " margin_delta=", gt_actual_pos - gt_expected_pos, " t=", Time.get_ticks_msec())

	processing_scroll = false

func stage_recycle_and_fill(allow_recycle: bool) -> bool:
	"""Recycle cards outside the buffer window and add missing ones. Returns
	true when the active set changed. Isolated so a failure here can't skip
	margins, data requests, or visual sync downstream of the scroll pass."""
	var structure_changed := false
	# Teleport: the new buffer window doesn't overlap the active window at all
	# (far jump / focus restore). Instead of recycle-all + re-add — which hides
	# every card and pops them back after the sort (a full-grid flicker) —
	# re-assign the existing cards to their new indices in place. Survivors
	# never leave the flow and never get hidden; the sort repositions them.
	if cards.size() > 0:
		var active_first: int = cards[0].get_meta("virtual_index", -1)
		var active_last: int = cards[cards.size() - 1].get_meta("virtual_index", -1)
		if active_last < _grid._buffer_target_start or active_first >= _grid._buffer_target_end:
			return reassign_to_window()

	if allow_recycle:
		var recycle_top_count = 0
		for card in cards:
			if not is_instance_valid(card):
				continue
			var idx = card.get_meta("virtual_index", -1)
			if idx < _grid._buffer_target_start:
				recycle_top_count += 1
			else:
				break
		if recycle_top_count > 0:
			batch_recycle_from_start(recycle_top_count)
			structure_changed = true

		while cards.size() > 0:
			var last_card = cards[cards.size() - 1]
			if not is_instance_valid(last_card):
				cards.remove_at(cards.size() - 1)
				continue
			var last_idx = last_card.get_meta("virtual_index", -1)

			if last_idx >= _grid._buffer_target_end:
				recycle_card_at_index(cards.size() - 1)
				structure_changed = true
			else:
				break

	# If buffer was fully recycled (e.g. scrolled to a completely different range),
	# populate the target range from scratch
	if cards.size() == 0:
		# Full jump (e.g. random-game teleport): in-flight requests for the old
		# window are useless now. Prune them so stale DB results are ignored and
		# queued DB tasks can skip themselves via is_load_pending().
		_grid._data.prune_pending_outside(_grid._buffer_target_start, _grid._buffer_target_end)
		# Likewise, every queued low-priority image task is directional prefetch
		# for the old window; draining them lets the workers decode the new
		# window's covers at full throughput. High-priority loads (hero art,
		# details sheets) are untouched.
		MemorySubManager.clear_pending_low_priority_image_tasks()
		# Same story for the download queue: queued low-priority requests are
		# covers for the window we just left. Drop them (DROPPED, no TTL) so
		# they can't crowd out the new window and trigger queue-full drops.
		# Bulk work (sync prefetch) and high-priority requests are spared.
		if SystemManager.download:
			SystemManager.download.clear_pending_low_priority_image_downloads()
		pending_buffer_expansion = false
		structure_changed = true
		for i in range(_grid._buffer_target_start, _grid._buffer_target_end):
			add_card_at_end(i)
	elif cards.size() > 0:
		var back_card = cards[cards.size() - 1]
		if not is_instance_valid(back_card):
			cards.remove_at(cards.size() - 1)
		else:
			var current_last = back_card.get_meta("virtual_index", 0)
			while current_last < _grid._buffer_target_end - 1 and current_last < _grid._total_items - 1:
				var size_before := cards.size()
				add_card_at_end(current_last + 1)
				structure_changed = true
				# Freeze guard: if the add failed to grow the active set (pool
				# exhaustion or an acquire failure), a platform-switch shrink
				# would spin here forever. Break loudly instead of hanging.
				if cards.size() <= size_before:
					push_error("[Grid] _stage_recycle_and_fill: add failed to grow active set (size=%d, target_end=%d) — breaking to avoid freeze" % [size_before, _grid._buffer_target_end])
					break
				back_card = cards[cards.size() - 1]
				if not is_instance_valid(back_card):
					break
				current_last = back_card.get_meta("virtual_index", 0)

		if cards.size() > 0 and is_instance_valid(cards[0]):
			var current_first = cards[0].get_meta("virtual_index", 0)
			if current_first > _grid._buffer_target_start and current_first > 0:
				var add_start_count = mini(current_first - _grid._buffer_target_start, current_first)
				batch_add_at_start(_grid._buffer_target_start, add_start_count)
				structure_changed = true

	return structure_changed

## Teleport rebuild: re-index the active cards in place to cover the new
## buffer window. Unlike the recycle-all path, survivors keep their flow slot
## and stay visible (marked); only the tail trim pools cards, and the head
## grows from the pool. The sort then repositions everyone in one pass, so a
## far jump never produces a hide-all/reveal-all pop.
func reassign_to_window() -> bool:
	var structure_changed := false
	var target_count: int = _grid._buffer_target_end - _grid._buffer_target_start
	# Keep in-flight requests: stale results are harmless under the LRU cap,
	# and the idle missing-data sweep re-finds anything still needed.
	MemorySubManager.clear_pending_low_priority_image_tasks()
	if SystemManager.download:
		SystemManager.download.clear_pending_low_priority_image_downloads()
	pending_buffer_expansion = false

	# Trim excess from the end: keeps flow child order identical to index
	# order (both old and new runs are contiguous and ascending).
	while cards.size() > target_count:
		recycle_card_at_index(cards.size() - 1)
		structure_changed = true

	# Re-index survivors through the same identity-reset contract as pool
	# reuse, while retaining their nodes/effect resources and flow positions.
	# Data for the new index is applied by the pending visual-setup flush.
	for i in range(cards.size()):
		var card = cards[i]
		if not is_instance_valid(card):
			continue
		var new_idx: int = _grid._buffer_target_start + i
		var old_idx: int = card.get_meta("virtual_index", -1)
		if old_idx == new_idx:
			continue
		_grid._focus.release_focus_if_inside(card)
		if old_idx >= 0:
			by_index.erase(old_idx)
			pending_setup.erase(old_idx)
			_grid._effect_queue.remove_card(card)
		if _grid._card_has_reset:
			card.reset(true)
		elif _grid._card_has_game_prop:
			card.game = null
		card.set_meta("virtual_index", new_idx)
		by_index[new_idx] = card
		card.set_meta("needs_visual_setup", true)
		pending_setup[new_idx] = card
		_grid._show_skeleton_if_unloaded(card, new_idx)
		structure_changed = true

	# Grow the tail from the pool if the new window is larger.
	while cards.size() < target_count:
		var grow_before := cards.size()
		add_card_at_end(_grid._buffer_target_start + cards.size())
		structure_changed = true
		# Freeze guard: a failed add must never spin this loop forever.
		if cards.size() <= grow_before:
			push_error("[Grid] _reassign_active_cards_to_window: add failed to grow active set (size=%d, target=%d) — breaking to avoid freeze" % [grow_before, target_count])
			break

	# Page/stagger spacers were laid out for the OLD index run; rebuild them
	# for the new one before the sort places everything.
	if _grid._is_pagination_active() or _grid._is_staggered_active():
		_grid._spacers.reconcile()
	return structure_changed

# --- Card add / recycle primitives --------------------------------------------

func recycle_card_at_index(index: int):
	if index < 0 or index >= cards.size():
		return

	var card = cards[index]
	_grid._focus.release_focus_if_inside(card)
	cards.remove_at(index)
	var vidx = card.get_meta("virtual_index", -1)
	if vidx >= 0:
		by_index.erase(vidx)
		pending_setup.erase(vidx)

	if is_instance_valid(card):
		# Remove from pending effect rebuild queue so recycled cards don't
		# rebuild after they're returned to the pool.
		_grid._effect_queue.remove_card(card)
		_grid._pool.return_card(card)
		_grid._spacers.prune_edges()

func add_card_at_end(virtual_index: int):
	var card = _grid._pool.acquire()
	if not card:
		return

	card.set_meta("virtual_index", virtual_index)
	if _grid._card_has_focus_scale_enabled:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = _grid._get_focus_scale_inverted()
	_grid._visual_sync.configure_card(card)
	_grid._configure_card_size_flags(card)
	if _grid._card_has_set_focus_scale:
		card.set_focus_scale(_grid.focus_scale)
	if _grid._is_pagination_active() and cards.size() > 0:
		# Page boundary between the last buffered card and this one: the spacer
		# owns a whole flow line, creating the visual gap between pages.
		var last_idx: int = cards[cards.size() - 1].get_meta("virtual_index", -1)
		if last_idx >= 0 and _grid._get_page_for_index(virtual_index) != _grid._get_page_for_index(last_idx):
			_grid._spacers.add_page_spacer()
	if _grid._spacers.is_stagger_row_opener(virtual_index):
		# Odd-row opener: half-cell spacer indents the row and wraps it at N-1.
		_grid._spacers.add_stagger_spacer()
	cards.append(card)
	by_index[virtual_index] = card
	_grid._flow_container.add_child(card)

	card.set_meta("needs_visual_setup", true)
	pending_setup[virtual_index] = card
	_grid._show_skeleton_if_unloaded(card, virtual_index)

	_grid.item_created.emit(card, virtual_index)

func add_card_at_start(virtual_index: int):
	var card = _grid._pool.acquire()
	if not card:
		return

	card.set_meta("virtual_index", virtual_index)
	if _grid._card_has_focus_scale_enabled:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = _grid._get_focus_scale_inverted()
	_grid._visual_sync.configure_card(card)
	cards.insert(0, card)
	by_index[virtual_index] = card
	_grid._flow_container.add_child(card)
	_grid._flow_container.move_child(card, 0)
	if _grid._is_pagination_active() and cards.size() > 1:
		# Page boundary between the new first card and the previous first card.
		var next_idx: int = cards[1].get_meta("virtual_index", -1)
		if next_idx >= 0 and _grid._get_page_for_index(virtual_index) != _grid._get_page_for_index(next_idx):
			_grid._spacers.add_page_spacer(1)
	if _grid._spacers.is_stagger_row_opener(virtual_index):
		# Odd-row opener prepended: its half-cell spacer goes before it. If the
		# row's partial run kept its spacer (edge-prune keeps live spacers),
		# move that one up instead of inserting a duplicate.
		if _grid._flow_container.get_child_count() > 1 and _grid._flow_container.get_child(1).has_meta("stagger_spacer"):
			_grid._flow_container.move_child(_grid._flow_container.get_child(1), 0)
		else:
			_grid._spacers.add_stagger_spacer(0)
	_grid._configure_card_size_flags(card)
	if _grid._card_has_set_focus_scale:
		card.set_focus_scale(_grid.focus_scale)

	card.set_meta("needs_visual_setup", true)
	pending_setup[virtual_index] = card
	_grid._show_skeleton_if_unloaded(card, virtual_index)

	_grid.item_created.emit(card, virtual_index)

func batch_recycle_from_start(count: int) -> void:
	if count <= 0 or count > cards.size():
		return

	# Release focus once if any card being recycled (or a descendant) owns it.
	var viewport := _grid.get_viewport()
	var focused = viewport.gui_get_focus_owner() if is_instance_valid(viewport) else null
	if focused:
		for i in range(count):
			var card = cards[i]
			if is_instance_valid(card) and card.is_ancestor_of(focused):
				viewport.gui_release_focus()
				break

	# Recycle in-place to avoid array allocation from slice().
	for i in range(count - 1, -1, -1):
		var card = cards[i]
		var vidx = card.get_meta("virtual_index", -1)
		if vidx >= 0:
			by_index.erase(vidx)
			pending_setup.erase(vidx)
		if is_instance_valid(card):
			_grid._effect_queue.remove_card(card)
			_grid._pool.return_card(card)
	cards = cards.slice(count)
	_grid._spacers.prune_edges()

func batch_add_at_start(target_start: int, count: int) -> void:
	if count <= 0:
		return
	var new_cards: Array[Control] = []
	var flow_pos := 0
	for i in range(count):
		var virtual_index = target_start + i
		var card = _grid._pool.acquire()
		if not card:
			break
		card.set_meta("virtual_index", virtual_index)
		if _grid._card_has_focus_scale_enabled:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = _grid._get_focus_scale_inverted()
		_grid._visual_sync.configure_card(card)
		if _grid._is_pagination_active() and i > 0:
			# Page boundary within the prepended range.
			if _grid._get_page_for_index(virtual_index) != _grid._get_page_for_index(virtual_index - 1):
				_grid._spacers.add_page_spacer(flow_pos)
				flow_pos += 1
		if _grid._spacers.is_stagger_row_opener(virtual_index):
			_grid._spacers.add_stagger_spacer(flow_pos)
			flow_pos += 1
		_grid._flow_container.add_child(card)
		_grid._flow_container.move_child(card, flow_pos)
		flow_pos += 1
		_grid._configure_card_size_flags(card)
		if _grid._card_has_set_focus_scale:
			card.set_focus_scale(_grid.focus_scale)
		card.set_meta("needs_visual_setup", true)
		pending_setup[virtual_index] = card
		_grid._show_skeleton_if_unloaded(card, virtual_index)
		_grid.item_created.emit(card, virtual_index)
		by_index[virtual_index] = card
		new_cards.append(card)
	if _grid._is_pagination_active() and new_cards.size() > 0 and cards.size() > 0:
		# Page boundary between the last prepended card and the previous first card.
		var last_new_idx: int = new_cards[new_cards.size() - 1].get_meta("virtual_index", -1)
		var old_first_idx: int = cards[0].get_meta("virtual_index", -1)
		if last_new_idx >= 0 and old_first_idx >= 0 and _grid._get_page_for_index(last_new_idx) != _grid._get_page_for_index(old_first_idx):
			_grid._spacers.add_page_spacer(flow_pos)
	cards = new_cards + cards

# --- Initial load + async buffer expansion ------------------------------------

func initial_load():
	var start_us := Time.get_ticks_usec()
	if _grid.startup_layout_suppressed:
		return
	if cards.size() > 0:
		return
	if _grid._total_items <= 0:
		return
	var available := _grid._get_available_size()
	if available.x <= 0 or available.y <= 0:
		return

	var items_per_line = _grid._get_items_per_line()
	var stride = _grid._get_normal_stride()
	var viewport_size = available.y if _grid.vertical else available.x
	var scroll_pos := 0
	if _grid._scroll_container:
		scroll_pos = _grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal

	_grid._compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	for i in range(_grid._buffer_target_start, _grid._buffer_target_end):
		add_card_at_end(i)

	virtual_start = _grid._buffer_target_start
	virtual_end = _grid._buffer_target_end - 1

	_grid._update_margin()
	_grid._visual_sync.update_draw_order()
	_grid._request_missing_data()
	_grid._update_card_priorities(_grid._visible_start_idx, _grid._visible_end_idx)
	flush_pending_visual_setup_for_visible_zone()
	# Reveal once the first sort commits positions.
	_grid._visual_sync.request_reveal()
	if DEBUG_LOG: print("[Grid] _initial_load: card_count=", _grid._buffer_target_end - _grid._buffer_target_start, " elapsed_us=", Time.get_ticks_usec() - start_us)

func process_buffer_expansion() -> void:
	if not pending_buffer_expansion:
		return
	if cards.size() == 0 or _grid._total_items == 0:
		pending_buffer_expansion = false
		return
	if not _grid._scroll_container:
		pending_buffer_expansion = false
		return

	var scroll_pos = _grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal
	var items_per_line = _grid._get_items_per_line()
	var stride = _grid._get_normal_stride()
	var available = _grid._get_available_size()
	var viewport_size = available.y if _grid.vertical else available.x
	_grid._compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	var current_last = cards[cards.size() - 1].get_meta("virtual_index", 0)
	var current_first = cards[0].get_meta("virtual_index", 0)

	if _grid.debug_mode:
		if DEBUG_LOG: print("[Grid] _process_buffer_expansion: target_start=", _grid._buffer_target_start, " target_end=", _grid._buffer_target_end, " current_first=", current_first, " current_last=", current_last)

	var added: int = 0
	while current_last < _grid._buffer_target_end - 1 and current_last < _grid._total_items - 1 and added < ASYNC_BUFFER_CARDS_PER_FRAME and WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US, "grid_buffer"):
		add_card_at_end(current_last + 1)
		current_last = cards[cards.size() - 1].get_meta("virtual_index", 0)
		added += 1

	current_first = cards[0].get_meta("virtual_index", 0)
	while current_first > _grid._buffer_target_start and current_first > 0 and added < ASYNC_BUFFER_CARDS_PER_FRAME and WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US, "grid_buffer"):
		add_card_at_start(current_first - 1)
		current_first = cards[0].get_meta("virtual_index", 0)
		added += 1

	if _grid.debug_mode:
		if DEBUG_LOG: print("[Grid] _process_buffer_expansion: added=", added, " current_first=", current_first, " current_last=", current_last)

	# Keep the internal virtual range consistent with the active card list so
	# later scroll/recycle math and preload checks don't use stale bounds.
	if cards.size() > 0:
		virtual_start = cards[0].get_meta("virtual_index", 0)
		virtual_end = cards[cards.size() - 1].get_meta("virtual_index", 0)

	if added > 0:
		_grid._request_missing_data()
		_grid._update_margin()
		_grid._check_preload_needed()
		_grid._update_card_priorities(_grid._visible_start_idx, _grid._visible_end_idx)
		_grid._visual_sync.update_draw_order()
		flush_pending_visual_setup_for_visible_zone()
		# Newly added off-screen cards are revealed once the sort commits their
		# positions (see _on_flow_sorted).
		_grid._visual_sync.request_reveal()

	if current_first <= _grid._buffer_target_start and current_last >= _grid._buffer_target_end - 1:
		pending_buffer_expansion = false
		if _grid.debug_mode:
			if DEBUG_LOG: print("[Grid] async buffer expansion complete")

# --- Pending visual setup ------------------------------------------------------

func process_pending_visual_setup() -> void:
	if pending_setup.is_empty():
		return

	if _grid.debug_mode:
		if DEBUG_LOG: print("[Grid] _process_pending_visual_setup: pending_size=", pending_setup.size())
	var processed: int = 0
	var keys := pending_setup.keys()
	# Not budget-gated: this drain services ACTIVE cards (a pending card has
	# no game assigned and renders invisible). Starving it hides rows.
	while processed < ASYNC_SETUP_CARDS_PER_FRAME and not keys.is_empty():
		var idx = keys[0]
		keys.remove_at(0)
		var card = pending_setup[idx]
		if not is_instance_valid(card) or not cards.has(card):
			pending_setup.erase(idx)
			continue
		# Count ATTEMPTS toward the per-frame budget, not just successes:
		# cards whose data hasn't arrived yet stay pending, and without an
		# attempt cap the loop iterates the entire pending dict every frame
		# (livelock when many cards are waiting on the DB).
		processed += 1
		var setup_ok = apply_card_visual_setup(card, idx)
		if _grid.debug_mode: print("[Grid] _process_pending_visual_setup: idx=", idx, " setup_ok=", setup_ok)
		if setup_ok:
			pending_setup.erase(idx)
		else:
			# Re-queue at the end (dicts iterate in insertion order) so a run
			# of data-starved cards at the front can't block the rest.
			pending_setup.erase(idx)
			pending_setup[idx] = card
	if _grid.debug_mode:
		if DEBUG_LOG: print("[Grid] _process_pending_visual_setup: processed=", processed, " remaining=", pending_setup.size())

func flush_pending_visual_setup_for_visible_zone() -> void:
	if pending_setup.is_empty():
		return

	_grid._get_visible_range()
	var items_per_line: int = _grid._get_items_per_line()
	var sync_start: int = maxi(0, _grid._visible_start_idx - items_per_line)
	var sync_end: int = mini(_grid._visible_end_idx + items_per_line, _grid._total_items)

	var completed: Array = []
	for idx in pending_setup:
		if idx >= sync_start and idx < sync_end:
			var card = pending_setup[idx]
			if is_instance_valid(card) and cards.has(card):
				if apply_card_visual_setup(card, idx):
					completed.append(idx)
			else:
				completed.append(idx)
	for idx in completed:
		pending_setup.erase(idx)

func apply_card_visual_setup(card: Control, virtual_index: int) -> bool:
	if not card.has_meta("needs_visual_setup"):
		if _grid.debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " no meta, skipping")
		return true
	if not card.is_node_ready():
		if _grid.debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " not ready, keeping pending")
		return false
	var actual_idx: int = card.get_meta("virtual_index", -1)
	if actual_idx != virtual_index:
		# Stale pending entry: the card was recycled and now shows a different
		# index. Never apply the wrong game's data; re-queue under the card's
		# current index so it still gets set up.
		if DEBUG_LOG: print("[CardApply] MISMATCH: card_meta=", actual_idx, " arg=", virtual_index, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())
		if actual_idx >= 0 and by_index.get(actual_idx) == card:
			pending_setup[actual_idx] = card
		else:
			card.remove_meta("needs_visual_setup")
		return true
	# Placeholder slots (index beyond the source count): no data to apply;
	# render as a blank, non-interactive card shape.
	if virtual_index >= _grid._source_total_items:
		card.remove_meta("needs_visual_setup")
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
		return true
	if not _grid._data.has_index(virtual_index):
		# Data not loaded yet; keep the card pending so it gets finished once
		# the items_requested callback populates the cache.
		if _grid.debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " data missing, keeping pending")
		_grid._show_skeleton_if_unloaded(card, virtual_index)
		return false
	card.remove_meta("needs_visual_setup")
	# Real data always clears placeholder state, including survivors of an
	# in-place window reassignment that previously padded the grid.
	if card.has_method("set_placeholder"):
		card.set_placeholder(false)

	if _grid._card_has_refresh_settings:
		card.refresh_settings()

	var card_visible = is_index_visible(virtual_index)
	if _grid._card_has_set_game_with_priority:
		card.set_game_with_priority(_grid._data.get_game(virtual_index), card_visible)
	else:
		card.game = _grid._data.get_game(virtual_index)
	_grid._data.touch(virtual_index)
	if _grid.debug_mode:
		if DEBUG_LOG: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " data applied, size=", card.size, " min=", card.custom_minimum_size)
	# The card may have been marked as position-synced before its data was
	# applied, in which case its visual items were hidden because headline was
	# empty. Re-evaluate visibility now that the game/title is set.
	if card.has_method("_update_visual_items_visibility"):
		card._update_visual_items_visibility()
	# Ensure the card's visual layer is positioned and marked visible now that
	# data is applied. In some paths (async startup, scroll recycling) the
	# global sync runs before the card is ready or before data is available,
	# leaving the card invisible until it is recycled.
	if _grid._card_has_sync_visual_offset and _grid._scroll_container and _grid._visual_sync.layer:
		card.sync_visual_transform_with_offset(_grid._visual_sync.compute_offset(card))
	elif _grid._card_has_sync_visual_transform:
		card.sync_visual_transform()
	# When called from inside a scroll pass — or while a reveal is pending (a
	# sort cascade is in flight; positions/chains are mid-update) — marking here
	# would reveal the card at a stale or mixed-generation position. The pre-draw
	# reveal handles those after the cascade. Outside both, layout is settled
	# and marking immediately is both safe and required (async data arrivals).
	if not processing_scroll and not _grid._visual_sync.has_reveal_pending() and _grid._card_has_mark_visuals_position_synced:
		card._mark_visuals_position_synced()
	if _grid.debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " applied")
	return true
