class_name GridCardPool
extends RefCounted

## Card instance pool for VirtualScrollGridContainer: creation, acquire,
## recycle-to-pool, frame-spread growth, and the card-scene capability probe
## (cached per scene path across ALL grids). Pool cards are NOT in the scene
## tree — they must be freed explicitly on teardown. Reads card capability
## flags and the card scene via the grid backref; never writes grid state.
## The active-set (window) membership stays in the grid — this module owns
## only the inactive pool and card lifecycle primitives.

## Cards built synchronously when no layout has computed a visible count yet
## (hidden views, pre-settle). The pool tops up via process_growth().
const STARTUP_SEED: int = 8
const GROWTH_PER_FRAME: int = 4

## Probed once per card scene across ALL grids (previously every grid paid a
## full card instantiate + queue_free just for these flags).
static var _capability_probe_cache: Dictionary = {}  # scene_path -> flags Dictionary

var _grid: VirtualScrollGridContainer = null

var cards: Array[Control] = []      # pooled (inactive) cards; front = oldest
var max_pool_size: int = 120        # resized per layout by the grid
var pending_growth: int = 0

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

## Probe the card scene's capability flags (cached per scene path). The grid
## assigns the result onto its _card_has_* read-cache vars.
static func probe_capabilities(card_scene: PackedScene) -> Dictionary:
	var scene_key := card_scene.resource_path
	if _capability_probe_cache.has(scene_key):
		return _capability_probe_cache[scene_key]
	var probe = card_scene.instantiate()
	probe.queue_free()
	var flags := {
		"focus_scale_enabled": "focus_scale_enabled" in probe,
		"set_focus_scale": probe.has_method("set_focus_scale"),
		"set_game_with_priority": probe.has_method("set_game_with_priority"),
		"refresh_settings": probe.has_method("refresh_settings"),
		"reset": probe.has_method("reset"),
		"game_prop": "game" in probe,
		"update_media_panel_size": probe.has_method("_update_media_panel_size"),
		"update_display": probe.has_method("update_display"),
		"set_image_priority": probe.has_method("set_image_priority"),
		"set_content_alignment": probe.has_method("set_content_alignment"),
		"set_media_aspect_ratio": probe.has_method("set_media_aspect_ratio"),
		"refresh_effects": probe.has_method("refresh_effects"),
		"update_card_state_from_settings": probe.has_method("_update_card_state_from_settings"),
		"sync_visual_transform": probe.has_method("sync_visual_transform"),
		"sync_visual_offset": probe.has_method("sync_visual_transform_with_offset"),
		"visual_layer_opacity": probe.has_method("set_visual_layer_opacity"),
		"mark_visuals_position_synced": probe.has_method("_mark_visuals_position_synced"),
		"unmark_visuals_position_synced": probe.has_method("_unmark_visuals_position_synced"),
		"show_loading_skeleton": probe.has_method("show_loading_skeleton"),
		"begin_bulk_layout": probe.has_method("begin_bulk_layout"),
		"end_bulk_layout": probe.has_method("end_bulk_layout"),
	}
	_capability_probe_cache[scene_key] = flags
	return flags

## Free all pooled cards and reseed synchronously with `sync_count` cards;
## the remainder up to max_pool_size is queued for frame-spread growth.
func instantiate_seed(sync_count: int, has_valid_size: bool) -> void:
	free_all(false)
	sync_count = mini(sync_count, max_pool_size)
	for i in range(sync_count):
		cards.append(_new_pooled_card())
	pending_growth = maxi(0, max_pool_size - sync_count) if has_valid_size else 0

func _new_pooled_card() -> Control:
	var card: Control = _grid._card_scene.instantiate()
	card.visible = false
	card.set_meta("pooled", true)
	card.set_meta("virtual_index", -1)
	return card

## Frame-spread pool top-up (budget-gated by WarmupBudget).
func process_growth() -> void:
	if pending_growth <= 0 or not _grid._card_scene:
		return
	var count = mini(GROWTH_PER_FRAME, pending_growth)
	for i in range(count):
		if not WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US, "card_pool"):
			return
		cards.append(_new_pooled_card())
		pending_growth -= 1

func acquire() -> Control:
	while cards.size() > 0:
		var card = cards.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			# Ensure a recycled card can always receive focus; some paths
			# (preview, manual disabling) may leave these non-focusable.
			card.disabled = false
			card.focus_mode = Control.FOCUS_ALL
			if _grid._card_has_unmark_visuals_position_synced:
				card._unmark_visuals_position_synced()
			card.visible = true
			return card

	if _grid._card_scene:
		var card: Control = _grid._card_scene.instantiate()
		card.set_meta("pooled", false)
		card.focus_mode = Control.FOCUS_ALL
		return card

	return null

## Return a card to the pool: detach from the flow, reset its content, and
## either pool it or free it when the pool is at capacity.
func return_card(card: Control) -> void:
	if not is_instance_valid(card):
		return
	disconnect_signals(card)
	card.visible = false
	card.set_meta("pooled", true)
	card.set_meta("virtual_index", -1)
	card.remove_meta("needs_visual_setup")

	if _grid._card_has_reset:
		card.reset(true)
	elif _grid._card_has_game_prop:
		card.game = null

	if card.get_parent() == _grid._flow_container:
		_grid._flow_container.remove_child(card)

	if cards.size() >= max_pool_size:
		card.queue_free()
	else:
		cards.append(card)

## Only disconnect signals connected by external code (e.g., LibraryView).
## Internal signals like 'pressed' stay: they are connected in the card's
## _ready(), which only runs once.
func disconnect_signals(card: Control) -> void:
	if card.has_signal("download_requested"):
		for conn in card.get_signal_connection_list("download_requested"):
			card.disconnect("download_requested", conn["callable"])

## Release all pooled cards. immediate: free() (teardown/exit paths where
## queue_free may not flush), else queue_free().
func free_all(immediate: bool) -> void:
	for card in cards:
		if is_instance_valid(card):
			if immediate:
				card.free()
			else:
				card.queue_free()
	cards.clear()
	pending_growth = 0
