class_name AZLetterCarousel
extends Control

## Vertical A-Z letter strip overlaid on the right edge of the library grid.
## Tapping a letter jumps the grid to that section; dragging scrubs through
## letters continuously. Pure overlay: it neither lives in nor affects the
## grid's layout (added as a child of the grid Control, which does not
## arrange its own children).
##
## Usage:
##   set_letter_map(first_index, ordered_letters, ordered_indices)
##   set_active_from_index(start_index)  # from grid visible_range_changed
##   signal letter_selected(letter, from_drag)

signal letter_selected(letter: String, from_drag: bool)
# Emitted when a scrub gesture begins/ends, so the grid can suppress network
# cover loads while the user is dragging across letters (cache-only) and
# re-fetch for the settled position when the finger lifts.
signal scrub_started
signal scrub_ended

const LETTERS: Array[String] = [
	"#", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
	"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
]

const WIDTH_DP: float = 26.0
const EDGE_MARGIN_DP: float = 4.0
const SLOT_MIN_HEIGHT_DP: float = 15.0
const BACKGROUND_ALPHA: float = 0.25
const DISABLED_ALPHA: float = 0.3
const INACTIVE_ALPHA: float = 0.8

# Scrub magnification: the letter under the finger grows while nearby letters
# scale/shift away with distance falloff (visual-only offset transforms, so
# neither the VBox layout nor the Y->letter input math is affected).
const MAGNIFY_MAX_EXTRA_SCALE: float = 0.8
const MAGNIFY_RADIUS_SLOTS: float = 2.0
const MAGNIFY_SHIFT_DP: float = 7.0
const MAGNIFY_DAMP: float = 14.0
const MAGNIFY_HOLD_TIME: float = 0.3

# letter -> first grid index (only letters that have games)
var _letter_first_index: Dictionary = {}
# Letters that have games, in grid order, with parallel first indices.
var _ordered_letters: Array[String] = []
var _ordered_indices: Array[int] = []

var _active_letter: String = ""

# Window mode: when the strip is too short for all letters at the minimum
# slot height, show a sliding window of letters with up/down arrows.
var _window_mode: bool = false
var _window_start: int = 0
var _window_letter_slots: int = 0

var _scrubbing: bool = false
var _last_emitted_letter: String = ""

# Magnification state: center is in visible-slot units (float, tracks the
# finger), strength eases toward _magnet_target (1 while scrubbing, 0 after).
var _magnet_center: float = 0.0
var _magnet_strength: float = 0.0
var _magnet_target: float = 0.0
var _magnet_hold: float = 0.0

var _vbox: VBoxContainer
var _background: Panel
var _labels: Dictionary = {}  # letter -> M3Label
var _up_arrow: M3IconButton
var _down_arrow: M3IconButton
var _resize_debounce_timer: Timer

const RESIZE_DEBOUNCE_TIME: float = 0.1


func _ready() -> void:
	# Render above focused cards (z_index 1) and their effects.
	z_index = 10
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_setup_anchors()
	_setup_ui()
	set_process(false)
	call_deferred("_apply_responsive_layout")


func _setup_anchors() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -M3Units.dp(WIDTH_DP)
	offset_right = 0.0
	offset_top = M3Units.dp(EDGE_MARGIN_DP)
	offset_bottom = -M3Units.dp(EDGE_MARGIN_DP)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN


func _setup_ui() -> void:
	_background = Panel.new()
	_background.name = "Background"
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	_update_background_style()

	_vbox = VBoxContainer.new()
	_vbox.name = "Slots"
	_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.add_theme_constant_override("separation", 0)
	add_child(_vbox)

	_up_arrow = _make_arrow("chevron-up")
	_vbox.add_child(_up_arrow)
	for letter in LETTERS:
		var label := M3Label.new()
		label.name = "Letter" + letter
		label.text = letter
		label.label_style = M3Label.Style.LABEL_SMALL
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		# Magnification pivots around the label center and never affects
		# layout or input picking.
		label.offset_transform_pivot_ratio = Vector2(0.5, 0.5)
		label.offset_transform_visual_only = true
		_labels[letter] = label
		_vbox.add_child(label)
	_down_arrow = _make_arrow("chevron-down")
	_vbox.add_child(_down_arrow)


func _update_background_style() -> void:
	if not _background:
		return
	var bg_color := M3Theme.get_surface_container()
	bg_color.a = BACKGROUND_ALPHA
	# A radius of half the shortest side makes a true capsule with
	# semicircular ends rather than a merely rounded rectangle.
	var fallback_size := M3Units.dp(WIDTH_DP)
	var width := size.x if size.x > 0.0 else fallback_size
	var height := size.y if size.y > 0.0 else fallback_size * 2.0
	var radius := int(round(minf(width, height) * 0.5))
	_background.add_theme_stylebox_override("panel", M3Theme.make_flat(bg_color, radius))


func refresh_theme() -> void:
	_update_background_style()


func refresh_scale() -> void:
	_update_background_style()


func _make_arrow(icon_name: String) -> M3IconButton:
	var arrow := M3IconButton.new()
	arrow.icon_name = icon_name
	arrow.icon_button_size = M3IconButton.IconSize.EXTRA_SMALL
	arrow.icon_button_variant = M3IconButton.IconVariant.STANDARD
	arrow.focus_mode = Control.FOCUS_NONE
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	arrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arrow.visible = false
	return arrow


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_background_style()
		_request_layout_recompute()


func _request_layout_recompute() -> void:
	# Lazily create the timer so resize notifications arriving before _setup_ui
	# are not silently dropped (mirrors PlatformIndicator).
	if _resize_debounce_timer == null:
		_resize_debounce_timer = Timer.new()
		_resize_debounce_timer.name = "ResizeDebounceTimer"
		_resize_debounce_timer.one_shot = true
		_resize_debounce_timer.wait_time = RESIZE_DEBOUNCE_TIME
		_resize_debounce_timer.timeout.connect(_apply_responsive_layout)
		add_child(_resize_debounce_timer)
	_resize_debounce_timer.start()


# ==================== PUBLIC API ====================

## Provide the letter -> first-grid-index mapping. ordered_letters /
## ordered_indices describe which letters have games, in grid order, so the
## strip can dim empty letters and resolve the active letter while scrolling.
func set_letter_map(first_index: Dictionary, ordered_letters: Array[String], ordered_indices: Array[int]) -> void:
	_letter_first_index = first_index
	_ordered_letters = ordered_letters
	_ordered_indices = ordered_indices
	_last_emitted_letter = ""
	_refresh_label_styles()
	# Re-resolve the active letter against the new map (grid is usually
	# scrolled back to top when the map reloads).
	set_active_from_index(0)


## Highlight the letter containing the grid item at start_index.
func set_active_from_index(index: int) -> void:
	if _ordered_letters.is_empty():
		_set_active_letter("")
		return
	var letter := _ordered_letters[0]
	for i in range(_ordered_letters.size()):
		if _ordered_indices[i] <= index:
			letter = _ordered_letters[i]
		else:
			break
	_set_active_letter(letter)


## The letter currently highlighted ("" when no map is loaded).
func get_active_letter() -> String:
	return _active_letter


## Set the highlighted letter directly (jump-intent pinning).
func set_active_letter(letter: String) -> void:
	_set_active_letter(letter)


## Letters that have games, in grid order (used for controller stepping).
func get_ordered_letters() -> Array[String]:
	return _ordered_letters


## Briefly magnify the given letter without user input — feedback for
## controller-driven letter stepping. Holds MAGNIFY_HOLD_TIME, then eases
## back to rest in _process.
func pulse_letter(letter: String) -> void:
	var i := LETTERS.find(letter)
	if i == -1:
		return
	_ensure_letter_visible(letter)
	if not _window_mode:
		_magnet_center = float(i)
	else:
		var slot_count := _window_letter_slots + 2
		_magnet_center = clampf(float(i - _window_start + 1), 1.0, slot_count - 2.0)
	_magnet_target = 1.0
	_magnet_hold = MAGNIFY_HOLD_TIME
	set_process(true)


## Keep a letter inside the window (window mode) so a pulse is visible.
func _ensure_letter_visible(letter: String) -> void:
	if not _window_mode:
		return
	var pos := LETTERS.find(letter)
	var new_start := _window_start
	if pos < _window_start:
		new_start = pos
	elif pos >= _window_start + _window_letter_slots:
		new_start = pos - _window_letter_slots + 1
	if new_start != _window_start:
		_window_start = new_start
		_clamp_window()
		_layout_slots()


# ==================== LAYOUT ====================

func _apply_responsive_layout() -> void:
	if not is_inside_tree():
		return
	var slot_px := M3Units.dp(SLOT_MIN_HEIGHT_DP)
	var fit := int(floor(size.y / slot_px)) if slot_px > 0.0 else LETTERS.size()
	var new_window_mode := fit < LETTERS.size()
	var new_letter_slots := maxi(1, fit - 2) if new_window_mode else LETTERS.size()  # reserve 2 arrow slots
	if new_window_mode == _window_mode and new_letter_slots == _window_letter_slots and _vbox != null:
		return
	_window_mode = new_window_mode
	_window_letter_slots = new_letter_slots
	_clamp_window()
	_layout_slots()


func _clamp_window() -> void:
	var max_start := maxi(0, LETTERS.size() - _window_letter_slots)
	_window_start = clampi(_window_start, 0, max_start)


func _layout_slots() -> void:
	if _vbox == null:
		return
	_up_arrow.visible = _window_mode
	_down_arrow.visible = _window_mode
	for i in range(LETTERS.size()):
		var label: M3Label = _labels[LETTERS[i]]
		if not _window_mode:
			label.visible = true
		else:
			var in_window := i >= _window_start and i < _window_start + _window_letter_slots
			if not in_window and label.visible:
				label.offset_transform_enabled = false  # drop stale magnification
			label.visible = in_window
	_refresh_arrows()
	_refresh_label_styles()


func _refresh_arrows() -> void:
	if not _window_mode:
		return
	var max_start := maxi(0, LETTERS.size() - _window_letter_slots)
	_up_arrow.modulate.a = DISABLED_ALPHA if _window_start == 0 else 1.0
	_down_arrow.modulate.a = DISABLED_ALPHA if _window_start == max_start else 1.0


func _refresh_label_styles() -> void:
	for letter in LETTERS:
		var label: M3Label = _labels[letter]
		if not _letter_first_index.has(letter):
			label.label_style = M3Label.Style.LABEL_SMALL
			label.modulate.a = DISABLED_ALPHA
		elif letter == _active_letter:
			label.label_style = M3Label.Style.LABEL_MEDIUM
			label.modulate.a = 1.0
		else:
			label.label_style = M3Label.Style.LABEL_SMALL
			label.modulate.a = INACTIVE_ALPHA


func _set_active_letter(letter: String) -> void:
	if letter == _active_letter:
		return
	_active_letter = letter
	_refresh_label_styles()
	if _window_mode and letter != "":
		# Keep the active letter visible inside the window.
		var pos := LETTERS.find(letter)
		var new_start := _window_start
		if pos < _window_start:
			new_start = pos
		elif pos >= _window_start + _window_letter_slots:
			new_start = pos - _window_letter_slots + 1
		if new_start != _window_start:
			_window_start = new_start
			_clamp_window()
			_layout_slots()


# ==================== INPUT ====================

func _gui_input(event: InputEvent) -> void:
	if _letter_first_index.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_scrub(event.position)
		else:
			_end_scrub()
		accept_event()
	elif event is InputEventMouseMotion and _scrubbing:
		_scrub_to(event.position, false)
		accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_scrub(event.position)
		else:
			_end_scrub()
		accept_event()
	elif event is InputEventScreenDrag and _scrubbing:
		_scrub_to(event.position, false)
		accept_event()


func _begin_scrub(pos: Vector2) -> void:
	_scrubbing = true
	_last_emitted_letter = ""
	_magnet_hold = 0.0  # a pulse's hold must not outlive the scrub
	_magnet_target = 1.0
	set_process(true)
	scrub_started.emit()
	_scrub_to(pos, true)


func _end_scrub() -> void:
	_scrubbing = false
	_last_emitted_letter = ""
	# Let the magnification ease back to rest in _process.
	_magnet_target = 0.0
	scrub_ended.emit()


func _scrub_to(pos: Vector2, is_press: bool) -> void:
	if size.y <= 0.0:
		return
	# Hit-test against the actually laid-out controls: the VBox's realized
	# slot heights can differ from size.y / slot_count (minimum sizes,
	# hidden arrows, separators), which made clicks land on the wrong letter.
	var global_pos: Vector2 = get_global_transform() * pos
	if _window_mode:
		if _up_arrow.visible and _up_arrow.get_global_rect().grow(1.0).has_point(global_pos):
			_magnet_center = 1.0
			_shift_window(-_window_letter_slots if is_press else -1)
			return
		if _down_arrow.visible and _down_arrow.get_global_rect().grow(1.0).has_point(global_pos):
			_magnet_center = maxf(float(_window_letter_slots), 1.0)
			_shift_window(_window_letter_slots if is_press else 1)
			return
	var hit := _hit_letter(global_pos)
	if hit != -1:
		if not _window_mode:
			_magnet_center = float(hit)
		else:
			var slot_count := _window_letter_slots + 2
			_magnet_center = clampf(float(hit - _window_start + 1), 1.0, slot_count - 2.0)
		_emit_letter(LETTERS[hit], not is_press)
		return
	# Fallback: arithmetic mapping (e.g. drag strayed outside every label).
	if not _window_mode:
		var slot_height := size.y / LETTERS.size()
		_magnet_center = clampf(pos.y / slot_height, 0.0, LETTERS.size() - 1.0)
		var slot := clampi(int(pos.y / slot_height), 0, LETTERS.size() - 1)
		_emit_letter(LETTERS[slot], not is_press)
	else:
		var slot_count := _window_letter_slots + 2
		var slot_height := size.y / slot_count
		# Clamp the magnification center to the letter slots so resting on an
		# arrow doesn't magnify empty space.
		_magnet_center = clampf(pos.y / slot_height, 1.0, slot_count - 2.0)
		var slot := clampi(int(pos.y / slot_height), 0, slot_count - 1)
		if slot == 0:
			# Tap pages by a full window; holding the drag on the arrow walks
			# one slot per motion event so scrubbing stays continuous.
			_shift_window(-_window_letter_slots if is_press else -1)
		elif slot == slot_count - 1:
			_shift_window(_window_letter_slots if is_press else 1)
		else:
			_emit_letter(LETTERS[_window_start + slot - 1], not is_press)


## Return the LETTERS index of the visible label under the global point,
## or -1 if none hit.
func _hit_letter(global_pos: Vector2) -> int:
	for i in range(LETTERS.size()):
		var label: M3Label = _labels[LETTERS[i]]
		if not label.visible:
			continue
		if label.get_global_rect().grow(1.0).has_point(global_pos):
			return i
	return -1


func _shift_window(delta: int) -> void:
	var max_start := maxi(0, LETTERS.size() - _window_letter_slots)
	var new_start := clampi(_window_start + delta, 0, max_start)
	if new_start == _window_start:
		return
	_window_start = new_start
	_layout_slots()
	# Continue the scrub from the newly revealed edge letter.
	var edge := _window_start if delta < 0 else _window_start + _window_letter_slots - 1
	_emit_letter(LETTERS[edge], true)


func _emit_letter(letter: String, from_drag: bool) -> void:
	if letter == _last_emitted_letter:
		return
	if not _letter_first_index.has(letter):
		return  # Dimmed letter: no games in this section.
	_last_emitted_letter = letter
	_set_active_letter(letter)
	letter_selected.emit(letter, from_drag)


# ==================== MAGNIFICATION ====================

func _process(delta: float) -> void:
	if not _scrubbing and _magnet_target > 0.0:
		# A pulse (controller stepping) holds, then releases.
		_magnet_hold -= delta
		if _magnet_hold <= 0.0:
			_magnet_target = 0.0
	_magnet_strength = lerpf(_magnet_strength, _magnet_target, 1.0 - exp(-MAGNIFY_DAMP * delta))
	if _magnet_strength < 0.01 and _magnet_target == 0.0:
		_magnet_strength = 0.0
		_clear_magnification()
		set_process(false)
		return
	_apply_magnification()


func _apply_magnification() -> void:
	var shift_px := M3Units.dp(MAGNIFY_SHIFT_DP)
	for i in range(LETTERS.size()):
		var label: M3Label = _labels[LETTERS[i]]
		if not label.visible:
			continue
		# Distance in visible-slot units (window mode reserves slot 0 and the
		# last slot for the arrows).
		var slot := float(i) if not _window_mode else float(i - _window_start + 1)
		var dist := absf(slot - _magnet_center)
		var falloff := clampf(1.0 - dist / (MAGNIFY_RADIUS_SLOTS + 1.0), 0.0, 1.0)
		falloff = falloff * falloff * (3.0 - 2.0 * falloff)  # smoothstep
		var amount := falloff * _magnet_strength
		if amount < 0.01:
			label.offset_transform_enabled = false
			continue
		label.offset_transform_enabled = true
		var s := 1.0 + MAGNIFY_MAX_EXTRA_SCALE * amount
		label.offset_transform_scale = Vector2(s, s)
		# Push neighbors away from the finger so the grown letter has room.
		var dir := signf(slot - _magnet_center)
		label.offset_transform_position = Vector2(0.0, dir * shift_px * amount)


func _clear_magnification() -> void:
	for letter in LETTERS:
		(_labels[letter] as M3Label).offset_transform_enabled = false
