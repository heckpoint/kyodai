class_name GridFocusedTitlePill
extends M3Card

## Display-only title bubble shared by a grid. It deliberately reuses M3Card's
## visual-layer text rendering so static ellipsis and seamless marquee behavior
## stay identical to inline card text.

const HEIGHT_DP := 44.0
const MIN_WIDTH_DP := 76.0
const TEXT_HORIZONTAL_PADDING_DP := 40.0
const TITLE_FONT_SIZE_DP := 15.0
const TAIL_WIDTH_DP := 18.0
const TAIL_HEIGHT_DP := 9.0

var _configured_title: String = ""
var _configured_max_width: float = -1.0
var _configured_alignment: int = -1
var _configured_scroll: bool = false
var _pill_active: bool = false
var _tail_points_down: bool = true
var _tail_visible: bool = true

func _init() -> void:
	enforce_min_height = false
	clickable = false
	focus_mode = Control.FOCUS_NONE
	show_background = true
	show_text_margin = true
	text_centered_overlay = false
	supporting_text_visible = false
	card_rounding_ratio = 1.0
	headline_font_weight = "bold"
	_update_contrast_colors()
	visible = false

func _ready() -> void:
	super._ready()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE

func configure(title: String, max_width: float, alignment: int, scroll_enabled: bool, force: bool = false) -> void:
	if not force and title == _configured_title and is_equal_approx(max_width, _configured_max_width) \
			and alignment == _configured_alignment and scroll_enabled == _configured_scroll:
		return
	_configured_title = title
	_configured_max_width = max_width
	_configured_alignment = alignment
	_configured_scroll = scroll_enabled

	var fonts := M3Theme.load_fonts()
	var font: Font = fonts.get("bold", fonts.get("medium", fonts.get("regular")))
	var font_size := int(M3Units.dp(TITLE_FONT_SIZE_DP))
	var text_width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x if font else 0.0
	var maximum := maxf(M3Units.dp(32.0), max_width)
	var minimum := minf(M3Units.dp(MIN_WIDTH_DP), maximum)
	var width := clampf(text_width + M3Units.dp(TEXT_HORIZONTAL_PADDING_DP), minimum, maximum)
	var height := M3Units.dp(HEIGHT_DP)

	headline = title
	supporting_text = ""
	text_alignment = (M3Card.TextAlignment.CENTER if alignment == 0 else clampi(alignment, 1, 3)) as M3Card.TextAlignment
	scroll_truncated_text = scroll_enabled
	text_content_visible = true
	text_focused = _pill_active
	custom_minimum_size = Vector2(width, height)
	size = custom_minimum_size
	if _ready_called:
		_update_media_panel_size(true)

func get_tail_height() -> float:
	return M3Units.dp(TAIL_HEIGHT_DP)

func set_tail_state(points_down: bool, tail_visible: bool) -> void:
	if _tail_points_down == points_down and _tail_visible == tail_visible:
		return
	_tail_points_down = points_down
	_tail_visible = tail_visible
	queue_redraw()

func show_pill() -> void:
	_pill_active = true
	visible = true
	text_focused = true

func hide_pill() -> void:
	_pill_active = false
	text_focused = false
	_reset_text_scroll()
	visible = false

func _redraw_visual_background(rect: Rect2) -> void:
	super._redraw_visual_background(rect)
	if not _tail_visible or not _visual_bg_canvas_item.is_valid():
		return
	var tail_width := M3Units.dp(TAIL_WIDTH_DP)
	var tail_height := M3Units.dp(TAIL_HEIGHT_DP)
	var center_x := rect.get_center().x
	# Overlap the body by one pixel to avoid an antialiased seam.
	var base_y := rect.size.y - 1.0 if _tail_points_down else 1.0
	var tip_y := base_y + tail_height if _tail_points_down else base_y - tail_height
	var points := PackedVector2Array([
		Vector2(center_x - tail_width * 0.5, base_y),
		Vector2(center_x + tail_width * 0.5, base_y),
		Vector2(center_x, tip_y),
	])
	var color := _cached_stylebox.bg_color
	RenderingServer.canvas_item_add_polygon(
		_visual_bg_canvas_item,
		points,
		PackedColorArray([color, color, color]),
		PackedVector2Array()
	)

func _update_contrast_colors() -> void:
	# Fully opaque contrast: white on light, black on dark.
	bg_color_override = Color.BLACK if M3Theme.is_dark_mode else Color.WHITE
	headline_color_override = Color.WHITE if M3Theme.is_dark_mode else Color.BLACK

func _configure_stylebox_for_state() -> void:
	super._configure_stylebox_for_state()
	# This small overlay must stay truly black/white even when Frosted Look is
	# enabled. Do not let the generic card frosted cap/material alter it.
	_cached_stylebox.bg_color.a = 1.0
	if _visual_bg_canvas_item.is_valid():
		RenderingServer.canvas_item_set_material(_visual_bg_canvas_item, RID())
	_frosted_applied = false

func refresh_theme() -> void:
	_update_contrast_colors()
	super.refresh_theme()
	# Font or UI-scale changes can alter the hug width even when the title and
	# focused card are unchanged.
	configure(_configured_title, _configured_max_width, _configured_alignment, _configured_scroll, true)

func _exit_tree() -> void:
	hide_pill()
	super._exit_tree()
