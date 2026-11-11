class_name View
extends Control

signal view_ready()
signal view_shown()
signal view_hidden()
signal hero_game_changed(game: GameResource)

var view_name: String = ""

# Whether focusing a game card in this view should update the hero image.
var supports_hero: bool = true

# Shared grid reference — subclasses set this via @onready
var games_grid: VirtualScrollGridContainer = null

# Lazy rebuild pattern - views marked for rebuild when hidden, rebuilt when shown
var needs_rebuild: bool = false
var needs_rebuild_reason: String = ""

# Deferred rebuild guard
var _deferred_rebuild_attempts: int = 0
const MAX_DEFERRED_REBUILD_ATTEMPTS: int = 10

# Track a focused GameCard that hasn't loaded its game data yet, so we can
# re-emit hero_game_changed once the data arrives.
var _pending_hero_card: GameCard = null

# Last DataManager.library_generation this view has refreshed against. -1 =
# uninitialized (fresh instance; first show just adopts the current value).
var _seen_library_generation: int = -1

## sync_completed is one-shot: if it fired while this view was disconnected
## (DS-mode reparenting, tab teardown), re-run the view's sync handler on
## show. Handlers must set _seen_library_generation so signal-driven
## refreshes aren't repeated here.
func _catch_up_missed_sync() -> void:
	if not DataManager or not DataManager.sync:
		return
	if DataManager.sync.is_sync_in_progress():
		# Reconnected by now; the completion signal will reach this view.
		return
	var generation: int = DataManager.library_generation
	if _seen_library_generation == -1 or generation == _seen_library_generation:
		_seen_library_generation = generation
		return
	_seen_library_generation = generation
	if has_method("_on_sync_completed"):
		call("_on_sync_completed", true, "")

func _ready():
	view_ready.emit()

func on_view_show():
	view_shown.emit()
	# Hidden views can have a stale or zero grid size when shown. Run a single
	# deterministic layout recalc now so the grid is settled against the real
	# available rect, unless a full rebuild is already pending.
	if not needs_rebuild and games_grid and UIManager:
		var available_size = UIManager.compute_grid_available_size(games_grid, self)
		games_grid.recalculate_layout_with_size(available_size)
	# Check if view needs to be rebuilt before showing (e.g. data/effect refresh).
	check_and_rebuild_if_needed()

func on_view_hide():
	view_hidden.emit()

# Whether the pending rebuild should also do a full card-effect refresh.
var _pending_refresh_effects: bool = false

func mark_for_rebuild(reason: String = "", refresh_effects: bool = false) -> void:
	"""Mark this view as needing a rebuild. Will be rebuilt when next shown."""
	needs_rebuild = true
	needs_rebuild_reason = reason
	_pending_refresh_effects = refresh_effects

func check_and_rebuild_if_needed() -> void:
	"""Override: Capture reason before it's cleared, then defer rebuild."""
	if needs_rebuild:
		var reason = needs_rebuild_reason
		var refresh_effects = _pending_refresh_effects
		# Clear flags now since we're handling the rebuild
		needs_rebuild = false
		needs_rebuild_reason = ""
		_pending_refresh_effects = false
		# Pass the captured reason to the deferred rebuild
		call_deferred("_do_rebuild", reason, refresh_effects)

func _do_rebuild(reason: String = "", refresh_effects: bool = false) -> void:
	# Ensure we have valid dimensions before rebuilding
	if size.x <= 0 or size.y <= 0:
		_deferred_rebuild_attempts += 1
		if _deferred_rebuild_attempts > MAX_DEFERRED_REBUILD_ATTEMPTS:
			push_warning("[%s] Max deferred rebuild attempts reached with invalid size, aborting" % view_name)
			_deferred_rebuild_attempts = 0
			return
		call_deferred("_do_rebuild", reason, refresh_effects)
		return
	
	# Reset counter on successful rebuild
	_deferred_rebuild_attempts = 0
	
	if games_grid:
		# Force a layout recalculation with the new valid size
		games_grid.queue_redraw()
	
	# Preset-applied rebuilds and card-effect changes need a full effect refresh.
	var do_refresh_effects = refresh_effects or reason == "Card effects changed"
	rebuild_grid(do_refresh_effects)

# Subclasses override this; base version is a no-op for safety.
func rebuild_grid(_refresh_effects: bool = false) -> void:
	pass

# ============================================
# SHARED GRID / CARD LOGIC
# ============================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_open_background_context_menu(event.global_position)
		accept_event()

func _open_background_context_menu(screen_point: Vector2) -> void:
	if not UIManager:
		return
	# A zero-sized, non-interactive control anchors the context menu to the
	# pointer rather than to the whole view. Its lifetime follows the modal.
	var anchor := Control.new()
	anchor.name = "BackgroundMenuAnchor"
	anchor.top_level = true
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.focus_mode = Control.FOCUS_NONE
	anchor.size = Vector2.ZERO
	add_child(anchor)
	anchor.global_position = screen_point
	var modal_id: String = UIManager.show_background_context_menu(anchor)
	UIManager.modal_dismissed.connect(func(dismissed_id: String):
		if dismissed_id == modal_id and is_instance_valid(anchor):
			anchor.queue_free()
	, CONNECT_ONE_SHOT)

func _update_grid_orientation() -> void:
	var state = UIManager.card_settings_state if UIManager else null
	if not state:
		print("[View._update_grid_orientation] no card_settings_state for ", view_name)
		return
	if not games_grid:
		print("[View._update_grid_orientation] no games_grid for ", view_name)
		return

	# The grid exclusively owns structure -> padding -> zoom -> focus-scale.
	# Views only request the transaction; they never write zoom independently.
	games_grid._batch_apply_layout_state()

func _refresh_grid_dimensions() -> void:
	"""Recalculate grid layout using the deterministic available size."""
	if not games_grid:
		return
	if UIManager:
		var available_size = UIManager.compute_grid_available_size(games_grid, self)
		games_grid.recalculate_layout_with_size(available_size)
	else:
		games_grid.refresh_dimensions()

func _on_focus_changed(control: Control):
	# Traverse up the tree to find if focused control is inside a GameCard
	var card = control
	while card != null:
		if card is GameCard:
			if card.game:
				hero_game_changed.emit(card.game)
				_clear_pending_hero_card()
			else:
				# Data hasn't loaded yet; wait for the card's game_changed signal.
				_clear_pending_hero_card()
				_pending_hero_card = card
				if not card.game_changed.is_connected(_on_pending_card_game_changed):
					card.game_changed.connect(_on_pending_card_game_changed)
			return
		card = card.get_parent()
	
	# Focus is not on a card; stop waiting for a pending card.
	_clear_pending_hero_card()
	# Don't clear hero - keep the last focused game image

func _on_pending_card_game_changed(game: GameResource) -> void:
	if _pending_hero_card and is_instance_valid(_pending_hero_card):
		hero_game_changed.emit(game)
	_clear_pending_hero_card()

func _clear_pending_hero_card() -> void:
	if _pending_hero_card and is_instance_valid(_pending_hero_card):
		if _pending_hero_card.game_changed.is_connected(_on_pending_card_game_changed):
			_pending_hero_card.game_changed.disconnect(_on_pending_card_game_changed)
	_pending_hero_card = null

func reconnect_viewport() -> void:
	"""Ensure focus-event connections after reparenting. Focus events come from
	the FocusSubManager hub, which tracks the UI viewport across dual-screen
	reparents itself, so this only needs an idempotent ensure-connect."""
	var hub := FocusSubManager.get_instance()
	if hub and not hub.ui_focus_changed.is_connected(_on_focus_changed):
		hub.ui_focus_changed.connect(_on_focus_changed)

	# Reconnect grid's scroll container follow_focus
	if games_grid and games_grid._scroll_container:
		games_grid._scroll_container.reconnect_viewport()

	# Reconnect focus-lock viewport signal on the grid
	if games_grid and games_grid.has_method("refresh_focus_lock"):
		games_grid.refresh_focus_lock()

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			var card_visible = i >= range_info.start and i < range_info.end
			card.set_game_with_priority(game, card_visible)
			break

func _on_card_created(card: Control, _index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)

func _on_download_requested(game: GameResource):
	SystemManager.download.queue_game_download(game)

func _on_setting_changed(_value: Variant, _setting: SettingsVar) -> void:
	"""Handle settings changes.
	
	Card config / layout / effect updates are now driven by the grid's own
	DataManager handler and by ViewManager, so the base view no longer
	needs to trigger its own rebuilds here."""
	pass
