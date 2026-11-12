class_name CoverPaletteDots
extends Control

## Decorative primary/secondary/tertiary cover palette indicator. The control
## hides itself until a complete triad is supplied and never joins focus/input.

const DOT_DIAMETER_DP := 10.0
const DOT_GAP_DP := 4.0
const DOT_OUTLINE_DP := 1.0

var _colors: Array[Color] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	visible = not _colors.is_empty()
	_refresh_minimum_size()


func set_colors(primary: Color, secondary: Color, tertiary: Color) -> void:
	if primary.a <= 0.0 or secondary.a <= 0.0 or tertiary.a <= 0.0:
		clear_colors()
		return
	_colors = [primary, secondary, tertiary]
	visible = true
	_refresh_minimum_size()
	queue_redraw()


func clear_colors() -> void:
	_colors.clear()
	visible = false
	_refresh_minimum_size()
	queue_redraw()


func refresh_scale() -> void:
	_refresh_minimum_size()
	queue_redraw()


func _refresh_minimum_size() -> void:
	var dot := M3Units.dpi(DOT_DIAMETER_DP)
	var gap := M3Units.dpi(DOT_GAP_DP)
	var outline := M3Units.dpi(DOT_OUTLINE_DP)
	custom_minimum_size = Vector2(dot * 3.0 + gap * 2.0 + outline * 2.0, dot + outline * 2.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	if _colors.size() != 3:
		return
	var dot := M3Units.dpi(DOT_DIAMETER_DP)
	var gap := M3Units.dpi(DOT_GAP_DP)
	var outline := M3Units.dpi(DOT_OUTLINE_DP)
	var radius := dot * 0.5
	var outline_color := M3Theme.get_on_surface_variant()
	outline_color.a = 0.35
	for i in range(3):
		var center := Vector2(outline + radius + float(i) * (dot + gap), size.y * 0.5)
		draw_circle(center, radius + outline, outline_color)
		draw_circle(center, radius, _colors[i])
