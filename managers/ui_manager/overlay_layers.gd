class_name OverlayLayers
extends RefCounted

## Central registry of the canvas-layer stack. Higher layers render above
## lower ones. M3 addon components (M3Sheet, M3Dialog, M3Menu, M3Tooltip,
## M3Snackbar) carry their own defaults; these constants document the intended
## stack and are used wherever app code assigns or overrides a layer.
##
## Structural layers are reparented by DualScreenSubManager on DS mode shifts:
## UILayer (with its transition overlays) follows the main viewport, the
## on-screen keyboard moves to the second viewport. M3 overlays attach to
## whichever node is in the "m3_overlay_parent" group (see M3Overlay).
## ChromeLayer is NOT reparented: the window chrome only exists on the root
## window (desktop windowed mode), never on the Android dual-screen handheld.

# CanvasLayer.layer stack
const SHEET := 85
const SEARCH := 85
const DIALOG := 90
const MENU := 95
const TOOLTIP := 110
const UI_LAYER := 1000
const SNACKBAR := 1100
## Above UILayer so critical dialogs stay visible and clickable over the
## launch transition overlay.
const LAUNCH_CRITICAL := 1101
## Window chrome (custom title bar + resize grips). Above every app overlay —
## dialogs, sheets, menus, snackbars, and the launch/view transitions — so the
## window controls always render on top and stay reachable. Deliberately below
## DisplaySubManager's RESIZE_FREEZE_LAYER (1200): the black freeze overlay
## covers the whole window mid-resize-gesture, chrome included.
const CHROME := 1150

# z_index within UILayer (layer 1000)
const VIEW_TRANSITION_Z := 900
const LAUNCH_TITLE_Z := 1001
const KEYBOARD_Z := 4096

# z_index within the root layout
const LIBRARY_BACKGROUND_Z := -100
const GRID_MEDIA_Z := -1
const TOOLBAR_Z := 10

## True while a mouse event lands on the window-chrome strip (the custom title
## bar at the top of the window). The chrome renders above every overlay and
## must stay clickable, so overlay _input handlers that blanket-consume events
## (transition overlays mid-animation) use this to let chrome clicks through.
static func is_mouse_over_chrome(event: InputEvent) -> bool:
	if not (event is InputEventMouse):
		return false
	var inset := M3Overlay.get_chrome_top_inset()
	return inset > 0.0 and (event as InputEventMouse).position.y < inset
