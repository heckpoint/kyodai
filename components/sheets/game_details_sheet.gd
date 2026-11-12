class_name GameDetailsSheet
extends M3BottomSheet

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CoverPaletteDots = preload("res://components/cover_palette_dots.gd")

## Game details bottom sheet.
## Extends M3BottomSheet so the details UI is a native Material 3 overlay
## instead of a full-screen tab.

const CONTENT_MARGIN_PATH := ^"MarginContainer"
const HEIGHT_FRACTION := 0.85
## Height fraction on short viewports (landscape handhelds): the fixed
## chrome + header leave too little for tab content otherwise, so the sheet
## takes nearly the full screen height.
const FULL_HEIGHT_FRACTION := 0.95
const SHORT_VIEWPORT_HEIGHT_DP := 600.0
const WIDTH_FRACTION := 0.75
const MAX_WIDTH_DP := 1200.0
const H_MARGIN_DP := 32.0
const MAX_DETAILS_TEXTURE_SIZE: int = 1024

## Below this viewport width the header stacks (title row + left-aligned
## button row) and the two chip rows merge into one truncated line. Sits
## ABOVE the shared compact breakpoint: the sheet's fixed width fraction and
## cover column leave the header row too cramped to share well before the
## global compact tier kicks in (e.g. an 832dp-wide handheld panel).
const STACKED_HEADER_VIEWPORT_DP := 900.0


const TAB_MARGIN_TOP_DP := 12.0
const TAB_BADGE_SIZE_DP := 22.0
const TAB_BADGE_GAP_DP := 6.0
const CARD_PADDING_DP := 16.0
const CARD_GAP_DP := 8.0
const STAR_SIZE_DP := 14.0
const STAR_GAP_DP := 2.0


# NOTE: The scene root is a CanvasLayer (M3BottomSheet base). The MarginContainer
# and its children are direct children of the root in the .tscn file, then
# _reparent_content() moves MarginContainer into the sheet's _content_slot.
@onready var _content_root: Control = $MarginContainer
@onready var cover_container: VBoxContainer = $MarginContainer/HBoxContainer/CoverContainer
@onready var content_vbox: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox
@onready var cover_texture: TextureRect = $MarginContainer/HBoxContainer/CoverContainer/CoverClip/CoverTexture
@onready var title_label: Label = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/TitleLabel
@onready var studio_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/StudioRow
@onready var metadata_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/MetadataRow
@onready var content_tabs: TabContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs
@onready var overview_vbox: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox
@onready var desc_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescScroll
@onready var description_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescScroll/DescriptionLabel
@onready var desc_fold_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescFoldButton
@onready var screenshots_section: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/ScreenshotsSection
@onready var screenshots_header: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/ScreenshotsSection/ScreenshotsHeader
@onready var screenshots_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/ScreenshotsSection/ScreenshotsScroll
@onready var screenshots_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/ScreenshotsSection/ScreenshotsScroll/RowMargin/ScreenshotsRow
@onready var screenshots_tab_content: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Screenshots/ScreenshotsTabScroll/ScreenshotsTabContent
@onready var related_section: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Related/RelatedTabScroll/RelatedTabContent/RelatedSection
@onready var related_header: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Related/RelatedTabScroll/RelatedTabContent/RelatedSection/RelatedHeader
@onready var related_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Related/RelatedTabScroll/RelatedTabContent/RelatedSection/RelatedScroll
@onready var related_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Related/RelatedTabScroll/RelatedTabContent/RelatedSection/RelatedScroll/RowMargin/RelatedRow
@onready var files_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll
@onready var files_card: PanelContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard
@onready var file_info_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard/CardMargin/CardVBox/FileInfoLabel
@onready var file_size_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard/CardMargin/CardVBox/FileSizeLabel
@onready var title_id_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard/CardMargin/CardVBox/TitleIdLabel
@onready var status_chip: M3Chip = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard/CardMargin/CardVBox/StatusChipRow/StatusChip
@onready var sync_status_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/FilesCard/CardMargin/CardVBox/SyncStatusLabel
@onready var sibling_dropdown: M3OptionButton = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/SiblingDropdown
@onready var status_dropdown: M3OptionButton = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesScroll/FilesVBox/StatusDropdown
@onready var header_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow
@onready var button_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow
@onready var action_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/ActionButton
@onready var sync_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/SyncButton
@onready var favorite_button: M3IconButton = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/FavoriteButton
@onready var hide_button: M3IconButton = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/HideButton

## RomM play-status options. The first five map to the mutually exclusive
## rom_user.status enum; the last three are independent boolean flags.
const STATUS_OPTIONS := [
	{"key": "incomplete", "label": "Incomplete", "icon": "timer-sand"},
	{"key": "finished", "label": "Finished", "icon": "check-bold"},
	{"key": "completed_100", "label": "Completed 100%", "icon": "trophy"},
	{"key": "retired", "label": "Retired", "icon": "flag"},
	{"key": "never_playing", "label": "Never Playing", "icon": "cancel"},
	{"key": "now_playing", "label": "Now Playing", "icon": "play"},
	{"key": "backlogged", "label": "Backlogged", "icon": "bookmark"},
	{"key": "hidden", "label": "Hidden", "icon": "eye-off"},
]
const STATUS_FLAG_KEYS := ["now_playing", "backlogged", "hidden"]

var _current_game: GameResource = null
var _sibling_options: Array[Dictionary] = []  # [{id, name, file_name, file_size}, ...]
var _desc_expanded: bool = false
var _related_games_count: int = 0
var _screenshots_count: int = 0
## Whether the strip has anything to show (scraped/user shots or the upload
## card for RomM games). Drives visibility; _screenshots_count is thumbs only.
var _screenshots_strip_active: bool = false
var _add_screenshot_card: M3Card = null
var _uploaded_thumb_count: int = 0
var _screenshot_upload_in_flight: bool = false
var _metadata_chips: Array[M3Chip] = []
var _studio_chips: Array[M3Chip] = []
var _interactive_meta_chips: Array[M3Chip] = []
var _overflow_chip: M3Chip = null
var _stars_trailer: Control = null
var _palette_dots: CoverPaletteDots = null
var _tab_badge_prev: M3Badge = null
var _tab_badge_next: M3Badge = null

func _init():
	super._init()
	persistent = true

# Preloaded data while a context menu is open.
var _prepared_romm_id: int = 0
var _prepared_cover: Texture2D = null

func _ready():
	super._ready()
	# Never let content render past the sheet edge; the sheet must never grow
	# with its contents.
	if _sheet_container:
		_sheet_container.clip_contents = true
	_reparent_content()
	_setup_tabs()
	_setup_related_section_card()
	_setup_focus_neighbors()
	_connect_signals()
	if sibling_dropdown:
		sibling_dropdown.fit_to_longest_item = false
	if status_dropdown:
		status_dropdown.fit_to_longest_item = false
	_set_sheet_height()
	_reduce_top_padding()
	_apply_content_scaling()

func _input(event: InputEvent):
	# Cycle tabs with bumpers while the sheet is the topmost overlay.
	# Handled before super so the press never reaches the library view's
	# platform cycler, which binds the same actions.
	if visible and participates_in_dismiss_stack and overlay_layer >= _max_layer:
		if event.is_action_pressed("cycle_platform_next"):
			_cycle_tab(1)
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("cycle_platform_prev"):
			_cycle_tab(-1)
			get_viewport().set_input_as_handled()
			return
	super._input(event)

func _cycle_tab(direction: int) -> void:
	if not content_tabs:
		return
	var count := content_tabs.get_tab_count()
	if count <= 1:
		return
	var idx := content_tabs.current_tab
	for step in count:
		idx = (idx + direction + count) % count
		if not content_tabs.is_tab_hidden(idx):
			break
	if idx != content_tabs.current_tab:
		if SystemManager.audio:
			SystemManager.audio.play_sfx("click_03")
		content_tabs.current_tab = idx

## Settled-geometry hook (broadcast by OverlaySubManager on debounced viewport
## changes — resizes and DS swaps alike). Re-stamps geometry against the
## settled viewport so no stale stamp can survive a configuration change.
## Geometry-dependent content (desc fold, chip overflow) refits itself via
## resized signals; only the stamped shell and tier breakpoints live here.
func on_viewport_settled() -> void:
	if not is_node_ready() or not is_inside_tree():
		return
	# Shrink the content minimum BEFORE re-stamping: the tier switch and chip
	# refit are what allow the clamped-up shell to come back down, and
	# Control.set_size can never shrink below the content minimum on its own.
	_apply_responsive_layout()
	_refit_metadata_row()
	_set_sheet_height()
	if visible:
		_reposition_open()
	else:
		_position_sheet()

## Recomputes chip overflow against the current sheet width so a re-stamp
## (screen swap, settle) can't leave a stale fit whose minimum size forces
## the sheet wider than its stamp.
func _refit_metadata_row() -> void:
	if _metadata_chips.size() > 0:
		_layout_metadata_row_overflow()
	if _studio_chips.size() > 0:
		_layout_studio_row_overflow()

## Row width changes (sheet re-stamp, tier switch, DS swap) invalidate the
## overflow fit; recompute against the real width. Idempotent.
func _on_content_row_resized() -> void:
	_refit_metadata_row()

func _on_tab_changed(_tab: int) -> void:
	if visible and is_node_ready():
		_reposition_open()

func refresh_theme():
	super.refresh_theme()
	if is_node_ready():
		_apply_content_scaling()
		_apply_m3_control_styling()
		if _current_game:
			_populate_metadata_chips(_current_game)

func refresh_scale() -> void:
	if not is_node_ready():
		return
	_setup_tabs()
	_reduce_top_padding()
	_set_sheet_height()
	if is_instance_valid(_palette_dots):
		_palette_dots.refresh_scale()
	_layout_metadata_row_overflow()
	super.refresh_scale()

func _setup_tabs() -> void:
	if not content_tabs:
		return
	# Let the sheet background show through instead of the themed opaque panel.
	content_tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var tab_margin := M3Units.dpi(TAB_MARGIN_TOP_DP)
	for tab_name in [&"Overview", &"Files", &"Related", &"Screenshots"]:
		var tab := content_tabs.get_node_or_null(NodePath(tab_name)) as MarginContainer
		if tab:
			tab.add_theme_constant_override("margin_top", tab_margin)
	# The Related tab starts hidden; it's revealed when the game has related
	# games (see _update_related_tab_visibility). The Screenshots tab likewise
	# starts hidden; it's revealed when the strip folds out of the Overview
	# column (see _decide_screenshots_placement).
	content_tabs.set_tab_hidden(RELATED_TAB_INDEX, true)
	content_tabs.set_tab_hidden(SCREENSHOTS_TAB_INDEX, true)
	_apply_m3_control_styling()
	_setup_tab_badges()
	# _setup_tabs also runs on scale refresh, which would otherwise strand
	# both tabs hidden for the current game; restore live visibility.
	_update_related_tab_visibility()
	_decide_screenshots_placement()

## Shoulder-button badges at the ends of the tab strip, hinting that LB/RB
## cycle the tabs. The tab bar's side_margin (set in _apply_m3_control_styling)
## reserves a pocket at each end. Badges are parented to the internal TabBar
## because TabContainer would treat them as tab pages.
func _setup_tab_badges() -> void:
	var bar := content_tabs.get_tab_bar()
	if not bar:
		return
	var badge_px := M3Units.dpi(TAB_BADGE_SIZE_DP)
	if is_instance_valid(_tab_badge_prev) and is_instance_valid(_tab_badge_next):
		# Re-entry via refresh_scale: rescale and reposition, don't duplicate.
		_tab_badge_prev.size = Vector2(badge_px, badge_px)
		_tab_badge_next.size = Vector2(badge_px, badge_px)
		_tab_badge_prev.refresh()
		_tab_badge_next.refresh()
		_position_tab_badges.call_deferred()
		return
	_tab_badge_prev = M3Badge.new()
	_tab_badge_prev.icon_font = "ControllerIcons"
	_tab_badge_prev.icon_name = "nintendo-left-shoulder"
	_tab_badge_prev.size = Vector2(badge_px, badge_px)
	_tab_badge_prev.z_index = 1
	_tab_badge_next = M3Badge.new()
	_tab_badge_next.icon_font = "ControllerIcons"
	_tab_badge_next.icon_name = "nintendo-right-shoulder"
	_tab_badge_next.size = Vector2(badge_px, badge_px)
	_tab_badge_next.z_index = 1
	bar.add_child(_tab_badge_prev)
	bar.add_child(_tab_badge_next)
	bar.resized.connect(_position_tab_badges)
	bar.item_rect_changed.connect(_position_tab_badges)
	_position_tab_badges.call_deferred()

## True while a next-idle badge refit is scheduled; keeps the double-pass in
## _position_tab_badges from queueing unbounded deferred calls.
var _badge_refit_pending := false

func _position_tab_badges() -> void:
	_apply_tab_badge_positions()
	# Tab rects only settle once the bar re-sorts during the idle flush after
	# a tab visibility flip, so a same-frame read can be stale (e.g. tabs
	# unhidden during hidden prep). Re-run once on the next idle so the
	# badges can't be stranded on pre-unhide rects.
	if not _badge_refit_pending:
		_badge_refit_pending = true
		_refit_tab_badges.call_deferred()

func _refit_tab_badges() -> void:
	_badge_refit_pending = false
	_apply_tab_badge_positions()

func _apply_tab_badge_positions() -> void:
	if not is_instance_valid(_tab_badge_prev) or not is_instance_valid(_tab_badge_next):
		return
	var bar := content_tabs.get_tab_bar()
	if not bar:
		return
	# Anchor to the visible tab rects, not the bar's edges: side_margin shifts
	# the bar's origin, and the bar spans the full container width, so edge
	# anchoring overlaps the first tab and strands the badge in dead space.
	var first := -1
	var last := -1
	for i in bar.tab_count:
		if not content_tabs.is_tab_hidden(i):
			if first == -1:
				first = i
			last = i
	if first == -1:
		return
	var badge_px := _tab_badge_prev.size.x
	var gap := M3Units.dpi(TAB_BADGE_GAP_DP)
	var y := (bar.size.y - badge_px) / 2.0
	_tab_badge_prev.position = Vector2(bar.get_tab_rect(first).position.x - gap - badge_px, y)
	_tab_badge_next.position = Vector2(bar.get_tab_rect(last).end.x + gap, y)

func _apply_m3_control_styling() -> void:
	"""M3-style the native TabContainer and the sheet's scrollbars."""
	if content_tabs:
		M3Theme.style_tab_container(content_tabs)
		# Reserve pockets at the tab strip's ends for the shoulder badges.
		content_tabs.add_theme_constant_override(
			"side_margin", M3Units.dpi(TAB_BADGE_SIZE_DP + TAB_BADGE_GAP_DP * 2.0))
	if is_instance_valid(related_scroll):
		M3Theme.style_scrollbar(related_scroll.get_h_scroll_bar())
	if is_instance_valid(screenshots_scroll):
		M3Theme.style_scrollbar(screenshots_scroll.get_h_scroll_bar())
	if is_instance_valid(desc_scroll):
		M3Theme.style_scrollbar(desc_scroll.get_v_scroll_bar())
	if is_instance_valid(files_scroll):
		M3Theme.style_scrollbar(files_scroll.get_v_scroll_bar())

## Group the related-games row in a rounded section card (SettingsSection's
## surface language) sitting under the left-aligned header.
func _setup_related_section_card() -> void:
	if not is_instance_valid(related_section) or not is_instance_valid(related_scroll):
		return
	var section := SettingsSection.new()
	# One elevation step darker than the sheet (surface_container_low) so the
	# card reads as an inset group against it.
	section.bg_color_override = M3Theme.get_surface()
	related_section.add_child(section)
	related_section.move_child(section, 1)  # below RelatedHeader
	related_section.remove_child(related_scroll)
	section.add_content(related_scroll, false)

func _setup_focus_neighbors() -> void:
	if not content_tabs or not action_button:
		return
	action_button.focus_neighbor_bottom = action_button.get_path_to(content_tabs)
	if sync_button:
		sync_button.focus_neighbor_bottom = sync_button.get_path_to(content_tabs)
	if favorite_button:
		favorite_button.focus_neighbor_bottom = favorite_button.get_path_to(content_tabs)
	if hide_button:
		hide_button.focus_neighbor_bottom = hide_button.get_path_to(content_tabs)
	content_tabs.focus_neighbor_top = content_tabs.get_path_to(action_button)
	if desc_fold_button:
		desc_fold_button.focus_neighbor_top = desc_fold_button.get_path_to(content_tabs)

func _apply_content_scaling() -> void:
	if not is_instance_valid(_content_root):
		return
	var edge := M3Units.dpi(10.0 if _small_layout else (16.0 if (_compact_layout or _stacked_header) else 24.0))
	var margin := _content_root as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_left", edge)
		margin.add_theme_constant_override("margin_top", edge)
		margin.add_theme_constant_override("margin_right", edge)
		margin.add_theme_constant_override("margin_bottom", edge)
	var hbox := _content_root.get_node_or_null(^"HBoxContainer") as HBoxContainer
	if hbox:
		hbox.add_theme_constant_override("separation", 0 if _small_layout else edge)
	var vbox := _content_root.get_node_or_null(^"HBoxContainer/ContentVBox") as VBoxContainer
	if vbox:
		vbox.add_theme_constant_override("separation", M3Units.dpi(12.0))
	if is_instance_valid(metadata_row):
		metadata_row.add_theme_constant_override("separation", M3Units.dpi(8.0))
	if is_instance_valid(files_card):
		files_card.add_theme_stylebox_override("panel", _build_files_card_style())
		var card_margin := files_card.get_node_or_null(^"CardMargin") as MarginContainer
		if card_margin:
			var pad := M3Units.dpi(CARD_PADDING_DP)
			card_margin.add_theme_constant_override("margin_left", pad)
			card_margin.add_theme_constant_override("margin_top", pad)
			card_margin.add_theme_constant_override("margin_right", pad)
			card_margin.add_theme_constant_override("margin_bottom", pad)
		var card_vbox := files_card.get_node_or_null(^"CardMargin/CardVBox") as VBoxContainer
		if card_vbox:
			card_vbox.add_theme_constant_override("separation", M3Units.dpi(CARD_GAP_DP))
	_apply_chrome_tier()

func _build_files_card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = M3Theme.get_outline_variant()
	style.set_border_width_all(maxi(1, M3Units.dpi(1.0)))
	style.set_corner_radius_all(M3Units.dpi(M3Theme.RADIUS_LARGE))
	style.anti_aliasing = true
	return style

func _reparent_content() -> void:
	var content_root := get_node_or_null(CONTENT_MARGIN_PATH) as Control
	if not content_root or not _content_slot:
		return
	if content_root.get_parent():
		content_root.get_parent().remove_child(content_root)
	_content_slot.add_child(content_root)
	content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Visibility is controlled by set_game/clear_content.

func _connect_signals() -> void:
	if sibling_dropdown:
		sibling_dropdown.item_selected.connect(_on_sibling_selected)
	if action_button:
		action_button.pressed.connect(_on_action_button_pressed)
	if sync_button:
		sync_button.pressed.connect(_on_sync_button_pressed)
	if status_dropdown:
		status_dropdown.item_selected.connect(_on_status_item_selected)
	if favorite_button:
		favorite_button.pressed.connect(_on_favorite_button_pressed)
	if hide_button:
		hide_button.pressed.connect(_on_hide_button_pressed)
	if desc_fold_button:
		desc_fold_button.pressed.connect(_on_desc_fold_pressed)
	if desc_scroll:
		desc_scroll.resized.connect(_on_desc_scroll_resized)
	if content_tabs:
		# Safety net: the TabContainer's combined minimum tracks the SELECTED
		# tab, so a tab whose content minimum ever exceeds the stamp would
		# clamp the shell taller (Control.set_size clamps up) and strand it
		# overflowing the bottom screen edge. Re-anchor on every tab change;
		# the per-tab ScrollContainers keep the minimum under budget so this
		# only ever runs as a no-op re-stamp.
		var bar := content_tabs.get_tab_bar()
		if bar and not bar.tab_changed.is_connected(_on_tab_changed):
			bar.tab_changed.connect(_on_tab_changed)
	if metadata_row:
		metadata_row.resized.connect(_on_content_row_resized)
	if studio_row:
		studio_row.resized.connect(_on_content_row_resized)
	SystemManager.download.download_completed.connect(_on_download_completed)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.cover_palette_updated.connect(_on_cover_palette_updated)

const RELATED_TAB_INDEX := 2
const SCREENSHOTS_TAB_INDEX := 3
var _compact_layout := false
var _small_layout := false
var _stacked_header := false

## Viewport-dp breakpoint check, measured against the same authoritative
## viewport the sheet stamps its geometry against (DS-aware: the active
## SubViewport in dual-screen mode). DisplaySubManager's cached size is the
## ROOT window's and can go stale relative to that frame (root resizes
## overwrite it even while the UI lives in a smaller SubViewport).
func _is_viewport_narrow(breakpoint_dp: float) -> bool:
	var viewport = M3Overlay.get_sizing_viewport(get_viewport())
	if viewport == null:
		return true
	return viewport.get_visible_rect().size.x < M3Units.dp(breakpoint_dp)

## Tiered layout (shared breakpoints live on DisplaySubManager):
## - expanded: full margins; title and actions share the header row (the
##   title truncates with an ellipsis), studio and metadata chips are
##   separate rows
## - stacked header (<900dp viewport, sheet-specific): the title gets its own
##   row with the actions on a left-aligned row beneath + studio and metadata
##   chips merged into a single truncated row
## - compact (<700dp viewport): tighter margins
## - small (<600dp viewport): compact + cover hidden + dense chips
func _apply_responsive_layout() -> void:
	if not is_node_ready():
		return
	var small := _is_viewport_narrow(DisplaySubManager.SMALL_VIEWPORT_DP)
	var compact := small or _is_viewport_narrow(DisplaySubManager.COMPACT_VIEWPORT_DP)
	var stacked := _is_viewport_narrow(STACKED_HEADER_VIEWPORT_DP)
	var changed := false
	if compact != _compact_layout:
		_compact_layout = compact
		changed = true
	if small != _small_layout:
		_small_layout = small
		changed = true
		cover_container.visible = not small
	var stacked_changed := stacked != _stacked_header
	if stacked_changed:
		_stacked_header = stacked
		changed = true
	if changed:
		_apply_header_layout_tier()
		# Rebuild the header chips for the tier: the stacked-header tier merges
		# the studio and metadata rows into one truncated line; wider tiers
		# keep them as separate rows. Small additionally switches to dense chips.
		if _current_game:
			_populate_studio(_current_game)
			_populate_metadata_chips(_current_game)
			if stacked_changed:
				# Card sizes are tier-dependent; rebuild the strips so a full
				# row fits the shorter tab content area instead of clipping.
				_populate_screenshots(_current_game)
				_populate_related_games(_current_game)
		_apply_content_scaling()
	# Tier flips change both the margins and the small-mode rule, so the
	# strip's inline-vs-tab placement is only valid for the tier it was
	# computed in. Idempotent.
	_decide_screenshots_placement()

## Stacked-header tier: the title gets its own full-width row and the action
## buttons drop to a left-aligned row directly beneath it (reparented out of
## the header HBox into the content column, right after the header). Reversed
## on exit. Idempotent. Focus neighbors are stored as NodePaths, so the chains
## must be rebuilt after any reparent.
func _apply_header_layout_tier() -> void:
	if not is_instance_valid(button_row) or not is_instance_valid(header_row) or not is_instance_valid(content_vbox):
		return
	if _stacked_header:
		if button_row.get_parent() == header_row:
			header_row.remove_child(button_row)
			content_vbox.add_child(button_row)
			content_vbox.move_child(button_row, header_row.get_index() + 1)
	elif button_row.get_parent() == content_vbox:
		content_vbox.remove_child(button_row)
		header_row.add_child(button_row)
	_setup_focus_neighbors()
	_update_chips_focus_chain()

## Related always lives in its own tab; only the tab's visibility is managed
## here (hidden when the game has no related games).
func _update_related_tab_visibility() -> void:
	if not content_tabs:
		return
	content_tabs.set_tab_hidden(RELATED_TAB_INDEX, _related_games_count == 0)
	# Never leave the current tab pointing at a hidden page.
	if content_tabs.is_tab_hidden(RELATED_TAB_INDEX) and content_tabs.current_tab == RELATED_TAB_INDEX:
		content_tabs.current_tab = 0
	_position_tab_badges.call_deferred()

## Vertical space the Overview tab's VBox can occupy inside the STAMPED sheet
## height. Pure arithmetic over synchronous minimum sizes (theme/font metrics,
## not layout passes): stamped height minus sheet chrome, content margins, the
## rows above the tabs, separations, the tab bar, and the tab's top margin.
## The stamp is derived from the live viewport (== dp(peek_height)), so the
## result is ordering-independent — valid before or after a re-stamp.
func _compute_overview_budget() -> float:
	if not _sheet_container or not is_instance_valid(content_vbox) or not content_tabs:
		return 0.0
	var screen := _get_screen_size()
	if screen.y <= 0.0:
		return 0.0
	var used := 0.0
	var margin := _sheet_container.get_child(0) as MarginContainer
	if margin:
		used += float(margin.get_theme_constant("margin_top")) + float(margin.get_theme_constant("margin_bottom"))
		var root := margin.get_child(0) if margin.get_child_count() > 0 else null
		if root:
			for child in root.get_children():
				if child == _content_slot:
					continue
				if child is Control and child.visible:
					used += child.get_combined_minimum_size().y
	var content_margin := _content_root as MarginContainer
	if content_margin:
		used += float(content_margin.get_theme_constant("margin_top")) + float(content_margin.get_theme_constant("margin_bottom"))
	var sep := float(content_vbox.get_theme_constant("separation"))
	var visible_children := 0
	for child in content_vbox.get_children():
		if child is Control and child.visible:
			visible_children += 1
			if child != content_tabs:
				used += child.get_combined_minimum_size().y
	used += sep * maxf(0.0, float(visible_children - 1))
	var bar := content_tabs.get_tab_bar()
	if bar:
		used += bar.get_combined_minimum_size().y
	used += M3Units.dp(TAB_MARGIN_TOP_DP)
	return maxf(0.0, screen.y * _get_sheet_height_fraction() - used)

## Moves the screenshots strip between the Overview column (inline, under the
## description) and its own tab. Inline only when the strip's fixed minimum
## plus a usable description (DESC_COLLAPSED_LINES lines) plus the fold button
## fit the Overview budget; the small tier always folds to the tab. Pure
## synchronous arithmetic — no layout waits. Control.set_size clamps UP to the
## content minimum, so an inline strip that doesn't fit would grow the sheet
## past its stamp; this decision is the only thing standing in the way.
func _decide_screenshots_placement() -> void:
	if not is_instance_valid(screenshots_section) or not is_instance_valid(screenshots_tab_content) or not content_tabs:
		return
	var inline := false
	if _screenshots_strip_active and not _small_layout and is_instance_valid(overview_vbox):
		var sep := float(overview_vbox.get_theme_constant("separation"))
		var need := screenshots_section.get_combined_minimum_size().y + sep \
			+ float(description_label.get_line_height()) * DESC_COLLAPSED_LINES + sep \
			+ desc_fold_button.get_combined_minimum_size().y + sep
		inline = need <= _compute_overview_budget()
	var target: Control = overview_vbox if inline else screenshots_tab_content
	if screenshots_section.get_parent() != target:
		screenshots_section.get_parent().remove_child(screenshots_section)
		target.add_child(screenshots_section)
	# An expanded description borrows the inline strip's space; in the tab the
	# strip is unaffected by the fold.
	screenshots_section.visible = _screenshots_strip_active and (not inline or not _desc_expanded)
	content_tabs.set_tab_hidden(SCREENSHOTS_TAB_INDEX, inline or not _screenshots_strip_active)
	# Never leave the current tab pointing at a hidden page.
	if content_tabs.is_tab_hidden(SCREENSHOTS_TAB_INDEX) and content_tabs.current_tab == SCREENSHOTS_TAB_INDEX:
		content_tabs.current_tab = 0
	_position_tab_badges.call_deferred()

## Budget-violation diagnostics: when the content's combined minimum exceeds
## the stamped shell, name the exact subtree responsible — every visible
## child's min at each level, descending into the largest contributor along
## the violated axis. Gated on M3Debug (debug_geometry_logging); grep logcat
## for "min-chain".
func _report_content_budget(tag: String) -> void:
	super._report_content_budget(tag)
	if not _sheet_container:
		return
	var min_size := _sheet_container.get_combined_minimum_size()
	var stamped := _sheet_container.size
	var over_x := min_size.x > stamped.x + 1.0
	var over_y := min_size.y > stamped.y + 1.0
	if not over_x and not over_y:
		return
	_dump_min_chain(tag, _sheet_container, "y" if over_y else "x", 0)

func _dump_min_chain(tag: String, node: Control, axis: String, depth: int) -> void:
	if depth > 10:
		return
	var listing := ""
	var worst: Control = null
	var worst_v := -1.0
	for child in node.get_children():
		if not (child is Control and child.visible):
			continue
		var m: Vector2 = child.get_combined_minimum_size()
		listing += " | %s=%s" % [child.name, m]
		var v := m.y if axis == "y" else m.x
		if v > worst_v:
			worst_v = v
			worst = child
	M3Debug.geom("bottom_sheet", "min-chain[%s] d%d %s min=%s children:%s" % [
		tag, depth, node.name, node.get_combined_minimum_size(), listing])
	if worst:
		_dump_min_chain(tag, worst, axis, depth + 1)

## Sheet height as a fraction of the sizing viewport: nearly full-height on
## short landscape screens (handhelds), the standard 85% elsewhere.
func _get_sheet_height_fraction() -> float:
	var viewport = M3Overlay.get_sizing_viewport(get_viewport())
	if viewport == null:
		return HEIGHT_FRACTION
	var screen_dp_y := viewport.get_visible_rect().size.y / M3Units.get_scale()
	return FULL_HEIGHT_FRACTION if screen_dp_y < SHORT_VIEWPORT_HEIGHT_DP else HEIGHT_FRACTION

func _set_sheet_height() -> void:
	var viewport = M3Overlay.get_sizing_viewport(get_viewport())
	if not viewport:
		return
	var screen_dp := viewport.get_visible_rect().size.y / M3Units.get_scale()
	var new_peek := screen_dp * _get_sheet_height_fraction()
	peek_height = new_peek

func _reduce_top_padding() -> void:
	# Tighten the default M3BottomSheet top padding.
	if not _sheet_container:
		return
	show_drag_handle = false
	var margin := _sheet_container.get_child(0) as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_top", int(M3Units.dp(4.0)))

## Reclaim vertical chrome in the stacked-header tier: kill the (hidden)
## drag handle's spacer and shrink the header pad so content gets the room.
func _apply_chrome_tier() -> void:
	if not _sheet_container:
		return
	var margin := _sheet_container.get_child(0) as MarginContainer
	if not margin:
		return
	var root := margin.get_child(0) if margin.get_child_count() > 0 else null
	if not root:
		return
	var drag_margin := root.get_node_or_null("DragMargin")
	if drag_margin:
		drag_margin.custom_minimum_size = Vector2(0, M3Units.dp(0.0 if _stacked_header else 16.0))
	var header_pad := root.get_node_or_null("HeaderPad")
	if header_pad:
		header_pad.custom_minimum_size = Vector2(0, M3Units.dp(4.0 if _stacked_header else 8.0))

func _get_sheet_width(screen_width: float) -> float:
	var ui_scale := M3Units.get_scale()
	var screen_dp := screen_width / ui_scale
	var legacy_dp := minf(MAX_WIDTH_DP, screen_dp - H_MARGIN_DP)
	var width_dp := maxf(legacy_dp, screen_dp * WIDTH_FRACTION)
	return minf(width_dp, screen_dp - H_MARGIN_DP) * ui_scale

func set_game(game: GameResource) -> void:
	_current_game = game

	if not is_node_ready():
		await ready

	if not is_instance_valid(self) or _current_game == null:
		return

	# Populate is fully synchronous: nothing here reads layout geometry, so
	# the hidden-prep phase is pure data. Geometry-driven refits (desc fold,
	# chip overflow) fire off resized signals once the sheet is laid out.
	_populate_basic_info(game)
	if is_instance_valid(_content_root):
		_content_root.visible = true
	_update_sync_ui()
	_load_cover(game)
	# Populate finished after the prepare-phase stamp; surface any content
	# minimum that busts the budget now instead of at the next re-stamp.
	_report_content_budget("post_populate")

func clear_content() -> void:
	_current_game = null
	if is_instance_valid(studio_row):
		studio_row.visible = false
		for child in studio_row.get_children():
			# Detach before queue_free so get_children() in the same frame
			# (focus chain rebuild) never sees dying chips.
			studio_row.remove_child(child)
			child.queue_free()
	_studio_chips.clear()
	if is_instance_valid(sibling_dropdown):
		sibling_dropdown.custom_minimum_size.x = 0.0
	if is_instance_valid(status_dropdown):
		status_dropdown.custom_minimum_size.x = 0.0
	if is_instance_valid(_content_root):
		_content_root.visible = false
	_set_cover_texture(null)
	if is_instance_valid(content_tabs):
		content_tabs.current_tab = 0
		content_tabs.set_tab_hidden(RELATED_TAB_INDEX, true)
		content_tabs.set_tab_hidden(SCREENSHOTS_TAB_INDEX, true)
		_position_tab_badges.call_deferred()
	if is_instance_valid(related_section):
		related_section.visible = false
	if is_instance_valid(related_row):
		for child in related_row.get_children():
			related_row.remove_child(child)
			child.queue_free()
	_screenshots_count = 0
	_screenshots_strip_active = false
	_add_screenshot_card = null
	_uploaded_thumb_count = 0
	_screenshot_upload_in_flight = false
	if is_instance_valid(screenshots_section):
		screenshots_section.visible = false
	if is_instance_valid(screenshots_row):
		for child in screenshots_row.get_children():
			screenshots_row.remove_child(child)
			child.queue_free()

func _populate_basic_info(game: GameResource) -> void:
	title_label.text = game.title if game.title else "Unknown Game"
	_populate_studio(game)
	_populate_metadata_chips(game)

	_setup_sibling_dropdown(game)
	_setup_status_dropdown(game)
	_update_favorite_button()
	_update_hide_button()
	_update_file_info_display(game)
	_update_action_button()
	description_label.text = game.description if game.description else "No description available."
	_setup_description_fold()
	_populate_screenshots(game)
	_populate_related_games(game)

func _populate_studio(game: GameResource) -> void:
	if not is_instance_valid(studio_row):
		return
	for child in studio_row.get_children():
		# Detach before queue_free; see clear_content().
		studio_row.remove_child(child)
		child.queue_free()
	_studio_chips.clear()
	var companies := game.get_igdb_companies()
	studio_row.visible = not companies.is_empty() and not _stacked_header
	if _stacked_header:
		# The stacked-header tier merges the company chips into the metadata
		# row's single truncated line; they're created by
		# _populate_metadata_chips so the row's overflow pass and focus chain
		# own them. This row stays hidden.
		return
	for company in companies:
		var chip := _make_studio_chip(company)
		studio_row.add_child(chip)
		_studio_chips.append(chip)
	_layout_studio_row_overflow()
	# Overflow visibility is final here; wire the focus chain last.
	_update_chips_focus_chain()

func _make_studio_chip(company: String) -> M3Chip:
	var chip := M3Chip.new()
	chip.chip_variant = M3Chip.ChipVariant.SUGGESTION
	chip.text = company
	chip.dense = true
	chip.focus_mode = Control.FOCUS_ALL
	chip.tooltip_text = "Show all games by %s" % company
	chip.pressed.connect(_on_company_chip_pressed.bind(company))
	return chip

## Same single-line overflow discipline as the metadata row: hide the chips
## that don't fit so the row's combined minimum width can never inflate the
## sheet past its stamped width (clip_contents alone still propagates min size).
func _layout_studio_row_overflow() -> void:
	if not is_instance_valid(studio_row) or _studio_chips.is_empty():
		return
	if _stacked_header:
		# Merged into the metadata row in this tier; that row's overflow
		# pass owns chip visibility.
		return
	var sep := float(studio_row.get_theme_constant("separation"))
	var avail := studio_row.size.x
	var estimate := _estimate_metadata_row_width()
	if avail <= 0.0 or (estimate > 0.0 and avail > estimate + 1.0):
		# A live width wider than the sheet's content area is stale; the row
		# can never legitimately be wider than the sheet.
		avail = estimate
	if avail <= 0.0:
		return
	var used := 0.0
	var fit := 0
	for i in range(_studio_chips.size()):
		if not is_instance_valid(_studio_chips[i]):
			break
		var w := _studio_chips[i].get_combined_minimum_size().x + (sep if i > 0 else 0.0)
		if fit == 0 or used + w <= avail:
			# Always show at least the first chip.
			used += w
			fit += 1
		else:
			break
	for i in range(_studio_chips.size()):
		if is_instance_valid(_studio_chips[i]):
			_studio_chips[i].visible = i < fit

## Wire the studio and interactive metadata chips into the vertical focus
## chain between the header buttons and the tabs; only visible chips count.
func _update_chips_focus_chain() -> void:
	if not content_tabs or not action_button:
		return
	var chain: Array[Control] = []
	if is_instance_valid(studio_row) and studio_row.visible:
		for child in studio_row.get_children():
			if child is Control and child.visible and not child.is_queued_for_deletion():
				chain.append(child)
	for chip in _interactive_meta_chips:
		if is_instance_valid(chip) and chip.visible and not chip.is_queued_for_deletion():
			chain.append(chip)
	if chain.is_empty():
		_setup_focus_neighbors()
		return
	var first := chain[0]
	var last := chain[chain.size() - 1]
	action_button.focus_neighbor_bottom = action_button.get_path_to(first)
	if sync_button:
		sync_button.focus_neighbor_bottom = sync_button.get_path_to(first)
	if favorite_button:
		favorite_button.focus_neighbor_bottom = favorite_button.get_path_to(first)
	if hide_button:
		hide_button.focus_neighbor_bottom = hide_button.get_path_to(first)
	first.focus_neighbor_top = first.get_path_to(action_button)
	last.focus_neighbor_bottom = last.get_path_to(content_tabs)
	content_tabs.focus_neighbor_top = content_tabs.get_path_to(last)

func _on_company_chip_pressed(company: String) -> void:
	_on_metadata_chip_pressed("company", company, "STUDIO", company)

func _populate_metadata_chips(game: GameResource) -> void:
	if not is_instance_valid(metadata_row):
		return
	for child in metadata_row.get_children():
		# Detach before queue_free: a queued child still counts toward the
		# row's combined minimum until frame end, and any re-stamp in the same
		# frame (settle + tier flip) would clamp the sheet to the dying chips'
		# width — the accumulation bug.
		metadata_row.remove_child(child)
		child.queue_free()
	_metadata_chips.clear()
	_interactive_meta_chips.clear()
	_overflow_chip = null
	_stars_trailer = null
	_palette_dots = null
	var platform_name: String = game.platform if game.platform else "Unknown Platform"
	_add_metadata_chip(platform_name, "gamepad-variant", true, true, "platform", game.platform_slug, "", platform_name)
	if _stacked_header:
		# Merged single line, platform first: company chips slot in ahead of
		# date/genre, and the overflow pass truncates them all into one "+N"
		# line. _populate_studio keeps its own row hidden in this tier.
		_studio_chips.clear()
		for company in game.get_igdb_companies():
			var studio_chip := _make_studio_chip(company)
			_interactive_meta_chips.append(studio_chip)
			metadata_row.add_child(studio_chip)
			metadata_row.move_child(studio_chip, 1 + _studio_chips.size())
			_studio_chips.append(studio_chip)
	if game.release_date > 0:
		var year := int(Time.get_datetime_dict_from_unix_time(int(game.release_date / 1000.0)).year)
		if year > 1971:
			var date_text := _format_release_date(game.release_date)
			_add_metadata_chip(date_text, "calendar", false, false, "release_week", str(game.release_date), "WEEK", date_text)
	# Genres from the IGDB blob (clean canonical list); fall back to the
	# merged genres column only when IGDB has none.
	var genre_list: Array = []
	var igdb_genres = game.igdb_metadata.get("genres", []) if game.igdb_metadata is Dictionary else []
	var genres_from_igdb: bool = igdb_genres is Array and not igdb_genres.is_empty()
	if genres_from_igdb:
		genre_list = igdb_genres
	else:
		genre_list = game.genres
	for genre in genre_list:
		# Only IGDB-sourced genres have matching filter rows; the merged
		# fallback taxonomy would filter to zero results, so it stays static.
		if genres_from_igdb:
			_add_metadata_chip(str(genre), "", false, false, "genre", str(genre), "GENRE", str(genre))
		else:
			_add_metadata_chip(str(genre), "", false)
	# Non-interactive "+N" overflow indicator; revealed by the overflow pass.
	_overflow_chip = M3Chip.new()
	_overflow_chip.chip_variant = M3Chip.ChipVariant.SUGGESTION
	_overflow_chip.elevated = true
	_overflow_chip.dense = _small_layout
	_overflow_chip.focus_mode = Control.FOCUS_NONE
	_overflow_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overflow_chip.visible = false
	metadata_row.add_child(_overflow_chip)
	_populate_palette_dots(game)
	_populate_rating_stars(game)
	_layout_metadata_row_overflow()
	# Overflow visibility is final here; wire the focus chain last.
	_update_chips_focus_chain()

## The chips row is a clipped single-line HBox: show as many chips as fit and
## collapse the rest into a "+N" chip so the row never wraps. Runs
## SYNCHRONOUSLY at populate: chip minimum sizes are valid at creation, and
## the row width is derived deterministically from the sheet width, so
## overflow chips are hidden before any minimum-size propagation can inflate
## the sheet (Control.set_size clamps up to the content minimum).
func _layout_metadata_row_overflow() -> void:
	if not is_instance_valid(metadata_row):
		return
	# The stacked-header tier merges the studio chips into this row; overflow
	# then runs over the combined list (companies first, then platform/date/
	# genre).
	var chips := _get_metadata_row_chips()
	var n := chips.size()
	if n == 0:
		return
	var sep := float(metadata_row.get_theme_constant("separation"))
	var avail := metadata_row.size.x
	var estimate := _estimate_metadata_row_width()
	if avail <= 0.0 or (estimate > 0.0 and avail > estimate + 1.0):
		# A live width wider than the sheet's content area is stale (carried
		# across a screen swap or a re-stamp): the row can never legitimately
		# be wider than the sheet.
		avail = estimate
	if avail <= 0.0:
		return
	var trailer_w := (_stars_trailer.get_combined_minimum_size().x if is_instance_valid(_stars_trailer) else 0.0) + sep * 2.0
	if is_instance_valid(_palette_dots) and _palette_dots.visible:
		trailer_w += _palette_dots.get_combined_minimum_size().x + sep
	var overflow_w := (_overflow_chip.get_combined_minimum_size().x + sep) if is_instance_valid(_overflow_chip) else 0.0
	var used := 0.0
	var fit := 0
	for i in range(n):
		if not is_instance_valid(chips[i]):
			break
		var w := chips[i].get_combined_minimum_size().x + sep
		var rest := n - i - 1
		var reserve := trailer_w + (overflow_w if rest > 0 else 0.0)
		if fit == 0 or used + w + reserve <= avail:
			# Always show at least the first chip.
			used += w
			fit += 1
		else:
			break
	for i in range(n):
		if is_instance_valid(chips[i]):
			chips[i].visible = i < fit
	var hidden := n - fit
	if is_instance_valid(_overflow_chip):
		_overflow_chip.visible = hidden > 0
		if hidden > 0:
			_overflow_chip.text = "+%d" % hidden

## Ordered chips living in the metadata row. Wider tiers keep the rows
## separate; the stacked-header tier merges the studio chips in right behind
## the platform chip, which always leads the row.
func _get_metadata_row_chips() -> Array[M3Chip]:
	if _stacked_header and not _studio_chips.is_empty() and not _metadata_chips.is_empty():
		var all: Array[M3Chip] = [_metadata_chips[0]]  # platform leads
		all.append_array(_studio_chips)
		for i in range(1, _metadata_chips.size()):
			all.append(_metadata_chips[i])
		return all
	return _metadata_chips

## Deterministic width of the metadata row for the synchronous overflow pass,
## used before the row has been laid out (e.g. first summon).
## Derived from the STAMP (the same math _reposition_open applies), never the
## live container size: set_size clamps up to the content minimum, so a live
## read from an inflated sheet would budget against the inflation and the
## sheet could never shrink back.
func _estimate_metadata_row_width() -> float:
	if not _sheet_container:
		return 0.0
	var screen := _get_screen_size()
	if screen.x <= 0.0:
		return 0.0
	var stamped := minf(_get_sheet_width(screen.x), screen.x)
	# The sheet chrome (ContentMargin inside _sheet_container) eats horizontal
	# space before the content margins do; skip it and the chip rows budget
	# ~40dp too much and their combined minimum clamps the sheet wider than
	# its stamp. Read live so chrome changes can't desync the estimate.
	var chrome := 0.0
	var sheet_margin := _sheet_container.get_child(0) as MarginContainer
	if sheet_margin:
		chrome = float(sheet_margin.get_theme_constant("margin_left")) \
			+ float(sheet_margin.get_theme_constant("margin_right"))
	var edge := M3Units.dp(10.0 if _small_layout else (16.0 if (_compact_layout or _stacked_header) else 24.0))
	var content_w := stamped - chrome - edge * 2.0
	if not _small_layout and is_instance_valid(cover_container) and cover_container.visible:
		# Cover column takes ~0.3 of the HBox (stretch ratio 0.3/0.7) plus the gap.
		content_w = (content_w - edge) * 0.7
	# Slight under-reservation is safer than spilling.
	var estimate := content_w - M3Units.dp(8.0)
	return estimate

func _populate_palette_dots(game: GameResource) -> void:
	_palette_dots = CoverPaletteDots.new()
	metadata_row.add_child(_palette_dots)
	_update_palette_dots(game)


func _update_palette_dots(game: GameResource) -> void:
	if not is_instance_valid(_palette_dots):
		return
	_palette_dots.set_colors(
		game.cover_primary_color,
		game.cover_secondary_color,
		game.cover_tertiary_color
	)


func _on_cover_palette_updated(cover_url: String) -> void:
	if not _current_game or _current_game.cover_url != cover_url:
		return
	var updated_game: GameResource = DataManager.get_game_by_id(_current_game.romm_id)
	if not updated_game:
		return
	_current_game.cover_primary_color = updated_game.cover_primary_color
	_current_game.cover_secondary_color = updated_game.cover_secondary_color
	_current_game.cover_tertiary_color = updated_game.cover_tertiary_color
	_current_game.cover_colors_version = updated_game.cover_colors_version
	_update_palette_dots(_current_game)
	_layout_metadata_row_overflow()


func _populate_rating_stars(game: GameResource) -> void:
	if game.rating <= 0:
		var label := M3Label.new()
		label.label_style = M3Label.Style.BODY_MEDIUM
		label.use_on_surface_variant = true
		label.text = "No rating"
		metadata_row.add_child(label)
		_stars_trailer = label
		return

	# Stars live in their own tight cluster, pushed to the row's right edge
	# by an expanding spacer.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	metadata_row.add_child(spacer)

	var stars_box := HBoxContainer.new()
	stars_box.add_theme_constant_override("separation", int(M3Units.dp(STAR_GAP_DP)))
	stars_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	metadata_row.add_child(stars_box)
	_stars_trailer = stars_box

	var stars := clampi(int(round(game.rating * 5.0)), 1, 5)
	for i in range(5):
		var star := FontIcon.new()
		var settings := FontIconSettings.new()
		settings.icon_name = "star" if i < stars else "star-outline"
		settings.icon_size = clampi(M3Units.dpi(STAR_SIZE_DP), 12, 128)
		settings.icon_color = M3Theme.get_primary() if i < stars else M3Theme.get_on_surface_variant()
		star.icon_settings = settings
		star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stars_box.add_child(star)

func _add_metadata_chip(text: String, icon: String, elevated: bool, accent: bool = false, filter_kind: String = "", filter_value: String = "", center_text: String = "", filter_label: String = "") -> void:
	var chip := M3Chip.new()
	chip.chip_variant = M3Chip.ChipVariant.SUGGESTION
	chip.text = text
	chip.elevated = elevated
	chip.accent_colored = accent
	chip.dense = _small_layout
	var clickable := filter_kind != "" and filter_value != ""
	chip.focus_mode = Control.FOCUS_ALL if clickable else Control.FOCUS_NONE
	chip.mouse_filter = Control.MOUSE_FILTER_STOP if clickable else Control.MOUSE_FILTER_IGNORE
	if clickable:
		chip.tooltip_text = _chip_filter_tooltip(filter_kind, filter_label)
		chip.pressed.connect(_on_metadata_chip_pressed.bind(filter_kind, filter_value, center_text, filter_label))
		_interactive_meta_chips.append(chip)
	if icon != "":
		chip.leading_icon = icon
	metadata_row.add_child(chip)
	_metadata_chips.append(chip)

func _chip_filter_tooltip(kind: String, label: String) -> String:
	match kind:
		"platform":
			return "Show all %s games" % label
		"genre":
			return "Show all %s games" % label
		"release_week":
			return "Show all games from this week"
	return ""

func _on_metadata_chip_pressed(kind: String, value: String, center_text: String, label: String) -> void:
	# The dismiss slide-out would otherwise restore focus to the summoner card
	# (~0.3s later, after the grid has rebuilt — i.e. the wrong game) and the
	# focus pull-back would yank the grid's first-card focus mid-animation.
	M3Overlay.push_focus_pullback_suppression()
	_restore_focus_on_dismiss = false
	dismiss()
	dismissed.connect(func():
		M3Overlay.pop_focus_pullback_suppression()
		_restore_focus_on_dismiss = true, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	var library := UIManager.get_view("Library") as LibraryView
	if library:
		if kind == "platform":
			library.apply_platform_selection(value, label)
		else:
			library.apply_external_filter(kind, value, center_text, label)
	# Immediate switch (no transition): the count callback's deferred
	# _focus_first_card is guarded on is_current_view, which an animated
	# transition would still be suppressing when it lands.
	UIManager.switch_to_tab_immediate("Library")

const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# ==================== DESCRIPTION FOLD ====================

const DESC_COLLAPSED_LINES := 3

func _setup_description_fold() -> void:
	if not is_instance_valid(description_label) or not is_instance_valid(desc_fold_button) or not is_instance_valid(desc_scroll):
		return
	_desc_expanded = false
	desc_fold_button.text = "More"
	desc_fold_button.visible = false
	desc_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	desc_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_scroll.scroll_vertical = 0
	# Min-size hygiene: the scroll is a zero-minimum slack absorber — its
	# height is negotiated by the container, never by the text inside it, so
	# the description can never grow the sheet.
	desc_scroll.custom_minimum_size.y = 0.0
	description_label.max_lines_visible = -1
	description_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	# Correct any truncation state left over from the previous game; on first
	# show geometry is zero and this no-ops until resized fires.
	_refit_description()

## Fit-based fold, event-driven: the desc scroll absorbs the column's
## leftover space (EXPAND_FILL), and the text truncates to however many lines
## FIT that space. Recomputes everything against CURRENT geometry — full line
## count at the current width, fit lines at the current height — so no cached
## measurement can go stale. Idempotent; called from desc_scroll.resized, so
## it only ever sees real laid-out rects, never pre-layout or mid-animation
## guesses.
func _refit_description() -> void:
	if not is_instance_valid(desc_scroll) or not is_instance_valid(description_label) or not is_instance_valid(desc_fold_button):
		return
	if _desc_expanded or _current_game == null:
		return
	var line_height := float(description_label.get_line_height())
	if line_height <= 0.0 or desc_scroll.size.y <= 0.0 or description_label.size.x <= 0.0:
		return
	var full_lines := description_label.get_line_count()
	var fit_lines := maxi(DESC_COLLAPSED_LINES, int(desc_scroll.size.y / line_height))
	if full_lines > fit_lines:
		description_label.max_lines_visible = fit_lines
		description_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		desc_fold_button.visible = true
	else:
		description_label.max_lines_visible = -1
		description_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		desc_fold_button.visible = false

func _on_desc_scroll_resized() -> void:
	_refit_description()

func _on_desc_fold_pressed() -> void:
	_desc_expanded = not _desc_expanded
	if _desc_expanded:
		# Trade space with the inline screenshot strip: expanding hides it
		# (collapse restores it); the full text fills the freed column and
		# scrolls. A strip folded into its own tab is unaffected.
		if is_instance_valid(screenshots_section) and screenshots_section.get_parent() == overview_vbox:
			screenshots_section.visible = false
		description_label.max_lines_visible = -1
		description_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		desc_scroll.scroll_vertical = 0
		desc_fold_button.text = "Less"
	else:
		desc_scroll.scroll_vertical = 0
		desc_fold_button.text = "More"
		desc_fold_button.visible = false
		if is_instance_valid(screenshots_section) and _screenshots_strip_active and screenshots_section.get_parent() == overview_vbox:
			screenshots_section.visible = true
		_refit_description()

# ==================== SCREENSHOTS ====================

const SCREENSHOT_HEIGHT_DP := 140.0
## Shorter strip in the stacked-header tier so a full row fits the shorter
## tab content area instead of clipping mid-card.
const SCREENSHOT_HEIGHT_STACKED_DP := 112.0

func _screenshot_strip_height_dp() -> float:
	return SCREENSHOT_HEIGHT_STACKED_DP if _stacked_header else SCREENSHOT_HEIGHT_DP

func _populate_screenshots(game: GameResource) -> void:
	if not is_instance_valid(screenshots_section) or not is_instance_valid(screenshots_row):
		return
	for child in screenshots_row.get_children():
		screenshots_row.remove_child(child)
		child.queue_free()
	screenshots_section.visible = false
	_screenshots_count = 0
	_screenshots_strip_active = false
	_add_screenshot_card = null
	_uploaded_thumb_count = 0
	_screenshot_upload_in_flight = false

	# The strip lives whenever there's anything to show or the game can take
	# uploads (RomM games always can, even with zero screenshots).
	var can_upload := game.source == "romm" and game.romm_id > 0
	if not can_upload and game.screenshot_urls.is_empty():
		_decide_screenshots_placement()
		return
	_screenshots_strip_active = true

	var for_romm_id := game.romm_id
	if can_upload:
		_add_screenshot_upload_card()
	for url in game.screenshot_urls:
		_add_screenshot_thumb(url, for_romm_id)
	_screenshots_count = game.screenshot_urls.size()
	_update_screenshots_header()

	if can_upload:
		_fetch_user_screenshots(for_romm_id)

	# Inline under the description when the Overview budget fits it, folded to
	# its own tab otherwise; decided by pure arithmetic, no layout waits.
	_decide_screenshots_placement()

func _update_screenshots_header() -> void:
	if not is_instance_valid(screenshots_header):
		return
	screenshots_header.text = "Screenshots" if _screenshots_count == 0 else "Screenshots (%d)" % _screenshots_count

func _add_screenshot_thumb(url: String, for_romm_id: int, at_position: int = -1) -> void:
	var height := M3Units.dp(_screenshot_strip_height_dp())
	# Media-only M3Card: no text, so the media fills the card with the card's
	# rounded-corner rendering. Clickable: opens the fullscreen lightbox.
	var card := M3Card.new()
	card.card_variant = M3Card.Variant.FILLED
	card.enforce_min_height = false
	card.custom_minimum_size = Vector2(height * 16.0 / 9.0, height)
	card.media_aspect_ratio = 16.0 / 9.0
	# No text band: the screenshot covers the whole card, aspect-covered by
	# the card's media shader (no stretch), corners rounded the same way.
	card.show_text_margin = false
	card.clickable = true
	card.focus_mode = Control.FOCUS_ALL
	card.tooltip_text = "View screenshot"
	card.set_meta("screenshot_url", url)
	card.set_placeholder(true)
	card.pressed.connect(_on_screenshot_thumb_pressed.bind(card))
	screenshots_row.add_child(card)
	if at_position >= 0:
		screenshots_row.move_child(card, at_position)
	DataManager.load_image(url, func(texture, _r: int):
		if not is_instance_valid(card):
			return
		if texture and _current_game and _current_game.romm_id == for_romm_id:
			card.media_texture = texture
			card.set_placeholder(false)
	)

## Open the pressed thumb in the fullscreen lightbox. Passes the loaded
## texture when available (instant); the URL covers the still-loading case.
func _on_screenshot_thumb_pressed(card: M3Card) -> void:
	if not is_instance_valid(card):
		return
	var texture := card.media_texture as Texture2D
	var url := str(card.get_meta("screenshot_url", ""))
	if texture == null and url == "":
		return
	ScreenshotLightbox.show_image(texture, url, card)

func _add_screenshot_upload_card() -> void:
	var height := M3Units.dp(_screenshot_strip_height_dp())
	var card := M3Card.new()
	card.card_variant = M3Card.Variant.FILLED
	card.enforce_min_height = false
	# Narrow strip: just an affordance, not a media tile.
	card.custom_minimum_size = Vector2(M3Units.dp(72), height)
	card.content_alignment = M3Card.ContentAlignment.CENTER
	card.headline = "+"
	card.supporting_text = "Add"
	card.clickable = true
	card.focus_mode = Control.FOCUS_ALL
	card.tooltip_text = "Upload a screenshot"
	card.pressed.connect(_on_add_screenshot_pressed)
	screenshots_row.add_child(card)
	screenshots_row.move_child(card, 0)
	_add_screenshot_card = card

## User-uploaded screenshots aren't in the library-sync payload (SimpleRomSchema
## only carries scraped merged_screenshots); they come from the detailed rom
## endpoint, merged across own (user_screenshots) and everyone's public shots
## (all_user_screenshots), deduped by id.
func _fetch_user_screenshots(for_romm_id: int) -> void:
	SystemManager.network.fetch_game_details(for_romm_id, func(data: Dictionary, error: String):
		if not is_instance_valid(self) or _current_game == null or _current_game.romm_id != for_romm_id:
			return
		if error != "" or not data is Dictionary:
			return
		var by_id: Dictionary = {}
		for entry in data.get("all_user_screenshots", []):
			if entry is Dictionary and not bool(entry.get("missing_from_fs", false)):
				by_id[int(entry.get("id", 0))] = entry
		for entry in data.get("user_screenshots", []):
			if entry is Dictionary and not bool(entry.get("missing_from_fs", false)):
				by_id[int(entry.get("id", 0))] = entry
		var ids := by_id.keys()
		ids.sort()
		for id in ids:
			var url := _screenshot_download_url(by_id[id])
			if url == "":
				continue
			# Uploads lead the strip: after the + card and any earlier
			# uploads, before the scraped thumbs.
			_add_screenshot_thumb(url, for_romm_id, 1 + _uploaded_thumb_count)
			_uploaded_thumb_count += 1
			_screenshots_count += 1
		_update_screenshots_header()
	)

func _screenshot_download_url(entry: Dictionary) -> String:
	var path := str(entry.get("download_path", ""))
	if path == "" or path == "null":
		var id := int(entry.get("id", 0))
		if id > 0:
			path = "/api/screenshots/%d/content" % id
	if path == "":
		return ""
	return SystemManager.network.build_media_url(path)

func _on_add_screenshot_pressed() -> void:
	if _screenshot_upload_in_flight or _current_game == null:
		return
	UIManager.show_file_dialog(
		"Select Screenshot",
		PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]),
		"",
		_upload_screenshot
	)

func _upload_screenshot(path: String) -> void:
	if _current_game == null:
		return
	var for_romm_id := _current_game.romm_id
	_screenshot_upload_in_flight = true
	if is_instance_valid(_add_screenshot_card):
		_add_screenshot_card.disabled = true
	SystemManager.network.upload_screenshot(for_romm_id, path, func(data: Dictionary, error: String):
		_screenshot_upload_in_flight = false
		if is_instance_valid(_add_screenshot_card):
			_add_screenshot_card.disabled = false
		if not is_instance_valid(self):
			return
		if error != "":
			SystemManager.notifications.show_notification("Screenshot upload failed: " + error, SystemManager.notifications.Type.ERROR)
			return
		SystemManager.notifications.show_notification("Screenshot uploaded", SystemManager.notifications.Type.INFO)
		if _current_game and _current_game.romm_id == for_romm_id:
			var url := _screenshot_download_url(data)
			if url != "":
				_add_screenshot_thumb(url, for_romm_id, 1 + _uploaded_thumb_count)
				_uploaded_thumb_count += 1
				_screenshots_count += 1
				_update_screenshots_header()
	)

# ==================== RELATED GAMES ====================

const RELATED_CARD_WIDTH_DP := 120.0
# Media is 3:4 (160dp tall at 120dp wide) plus the ~36dp caption-only text area.
const RELATED_CARD_HEIGHT_DP := 120.0 / 0.75 + 36.0
## Smaller cards in the stacked-header tier so a full card fits the shorter
## tab content area instead of clipping mid-card.
const RELATED_CARD_WIDTH_STACKED_DP := 96.0
const RELATED_CARD_HEIGHT_STACKED_DP := 96.0 / 0.75 + 36.0
const RELATED_TYPE_LABELS := {
	"dlc": "DLC",
	"expansion": "Expansion",
	"remake": "Remake",
	"remaster": "Remaster",
	"port": "Port",
	"expanded": "Expanded",
	"similar": "Similar",
}

func _populate_related_games(game: GameResource) -> void:
	if not is_instance_valid(related_section) or not is_instance_valid(related_row):
		return
	for child in related_row.get_children():
		related_row.remove_child(child)
		child.queue_free()
	related_section.visible = false

	var related := game.get_igdb_related_games()
	_related_games_count = related.size()
	var for_romm_id := game.romm_id
	if related.is_empty():
		_update_related_tab_visibility()
		return
	if is_instance_valid(related_header):
		related_header.text = "Related Games (%d)" % related.size()

	var igdb_ids: Array = []
	var titles: Array = []
	for entry in related:
		_add_related_card(entry)
		var raw_id = entry.get("id", 0)
		var igdb_id := int(raw_id) if raw_id != null else 0
		if igdb_id > 0:
			igdb_ids.append(igdb_id)
		titles.append(str(entry.get("name", "")))

	# Related always lives in its own tab; reveal it now that cards exist.
	related_section.visible = true
	_update_related_tab_visibility()

	# Resolve which related games are owned on the DB thread, then badge and
	# link their cards. Exact igdb_id match first, title fallback after.
	MemorySubManager.queue_db_task(
		func():
			var by_igdb: Dictionary = DataManager.get_games_by_igdb_ids(igdb_ids)
			var unmatched: Array = []
			for i in range(related.size()):
				var raw_id = related[i].get("id", 0)
				var igdb_id := int(raw_id) if raw_id != null else 0
				if igdb_id <= 0 or not by_igdb.has(igdb_id):
					unmatched.append(titles[i])
			var by_title: Dictionary = DataManager.get_games_by_titles(unmatched) if not unmatched.is_empty() else {}
			return {"by_igdb": by_igdb, "by_title": by_title},
		func(matches):
			# null when the queue dropped the task (overflow).
			if matches == null:
				return
			if not is_instance_valid(self) or _current_game == null or _current_game.romm_id != for_romm_id:
				return
			if not is_instance_valid(related_row):
				return
			var by_igdb: Dictionary = matches.get("by_igdb", {})
			var by_title: Dictionary = matches.get("by_title", {})
			var cards := related_row.get_children()
			var owned_pos := 0
			for i in range(mini(cards.size(), related.size())):
				var romm_id := 0
				var raw_id = related[i].get("id", 0)
				var igdb_id := int(raw_id) if raw_id != null else 0
				if igdb_id > 0 and by_igdb.has(igdb_id):
					romm_id = by_igdb[igdb_id]
				elif by_title.has(titles[i].to_lower()):
					romm_id = by_title[titles[i].to_lower()]
				if romm_id > 0:
					_mark_related_card_owned(cards[i], romm_id)
					# Owned games surface to the front in stable relative order.
					related_row.move_child(cards[i], owned_pos)
					owned_pos += 1
	)

func _add_related_card(entry: Dictionary) -> void:
	var card := M3Card.new()
	card.card_variant = M3Card.Variant.FILLED
	card.enforce_min_height = false
	var card_w := RELATED_CARD_WIDTH_STACKED_DP if _stacked_header else RELATED_CARD_WIDTH_DP
	var card_h := RELATED_CARD_HEIGHT_STACKED_DP if _stacked_header else RELATED_CARD_HEIGHT_DP
	card.custom_minimum_size = Vector2(M3Units.dp(card_w), M3Units.dp(card_h))
	card.media_aspect_ratio = 0.75  # IGDB covers are 3:4
	# Caption-only cards: the type label stands in for the title.
	var type_label: String = RELATED_TYPE_LABELS.get(str(entry.get("type", "")), str(entry.get("type", "")).capitalize())
	card.supporting_text = type_label
	card.set_meta("type_label", type_label)
	card.clickable = false
	card.focus_mode = Control.FOCUS_NONE
	related_row.add_child(card)

	var cover_url := str(entry.get("cover_url", ""))
	if cover_url != "":
		# Public IGDB CDN; t_cover_small keeps thumbs light.
		var thumb_url := cover_url.replace("t_1080p", "t_cover_small")
		DataManager.load_image(thumb_url, func(texture, _r: int):
			if is_instance_valid(card) and texture:
				card.media_texture = texture
		)

func _mark_related_card_owned(card: Control, romm_id: int) -> void:
	if not card is M3Card:
		return
	var type_label := str(card.get_meta("type_label", ""))
	card.supporting_text = (type_label + " · ") if type_label != "" else ""
	card.supporting_text += "In Library"
	card.bg_color_override = M3Theme.get_primary_container()
	card.clickable = true
	card.focus_mode = Control.FOCUS_ALL
	card.pressed.connect(_on_related_card_pressed.bind(romm_id))

func _on_related_card_pressed(romm_id: int) -> void:
	UIManager.show_game_details(romm_id)

func _format_release_date(epoch_ms: int) -> String:
	var dict := Time.get_datetime_dict_from_unix_time(int(epoch_ms / 1000.0))
	var month: String = MONTH_NAMES[clampi(int(dict.month) - 1, 0, 11)]
	return "%s %d, %d" % [month, dict.day, dict.year]

func show_for_game(game: GameResource) -> GameDetailsSheet:
	await show_prepared(_prepare_for_show.bind(game))
	return self

## Grab initial in-sheet focus only once visible: grabbing during the hidden
## prep phase focuses an invisible control and pollutes the summoner's focus
## capture in show_overlay().
func show_overlay() -> void:
	super.show_overlay()
	if action_button:
		if UIManager:
			UIManager.suppress_next_focus_sound()
		action_button.grab_focus.call_deferred()

## Hidden prep phase of the two-phase show: parent, size, tier, and populate
## fully before the first visible frame.
func _prepare_for_show(game: GameResource) -> void:
	clear_content()
	# Parent first (also fixes stale parents across DS mode toggles): the
	# sizing below needs a viewport, which only exists once inside the tree.
	ensure_overlay_parent()
	# Recompute height against the current viewport/scale: the sheet is
	# persistent, so the one-shot _ready sizing goes stale after screen or
	# scale changes (dual-screen swap, orientation, display-init ordering).
	_set_sheet_height()
	_position_sheet()
	_apply_responsive_layout()
	await set_game(game)

func prepare_for_game(romm_id: int) -> void:
	"""Preload heavy details while the context menu is open."""
	var game: GameResource = DataManager.get_game_by_id(romm_id)
	if not game:
		return

	_prepared_romm_id = romm_id
	_prepared_cover = null

	# Decode the local cover on a background thread so it's ready if Details is selected.
	if game.cover_path and FSM.file_exists(game.cover_path):
		DataManager.cover.note_cover_access(game.cover_path)
		var cache_key := MemorySubManager.cover_cache_key(game.cover_path, MAX_DETAILS_TEXTURE_SIZE)
		var cached := MemorySubManager.get_cached_texture(cache_key)
		if cached:
			_prepared_cover = cached
			return
		MemorySubManager.queue_image_task(
			func() -> Image:
				return MemorySubManager.prepare_image_for_texture(_decode_cover_downscaled(game.cover_path)),
			func(img: Image):
				if is_instance_valid(self) and img and not img.is_empty():
					_prepared_cover = MemorySubManager.create_texture_from_image(img)
					if _prepared_cover:
						MemorySubManager.cache_texture(cache_key, _prepared_cover)
		)

func _setup_sibling_dropdown(game: GameResource) -> void:
	if not sibling_dropdown:
		return

	sibling_dropdown.clear_items()
	_sibling_options = []

	# Add the main game as the first option
	var main_label := game.file_name if game.file_name else game.title
	var main_disc := GameResource.parse_disc_number(game.file_name)
	if main_disc > 0 and not main_label.to_lower().contains("(disc"):
		main_label = "Disc %d: %s" % [main_disc, main_label]
	_sibling_options.append({
		"id": game.romm_id,
		"name": game.file_name if game.file_name else game.title,
		"file_name": game.file_name,
		"file_size": game.file_size
	})
	sibling_dropdown.add_item(main_label)

	# Add siblings, ordered by RomM's sort_comparator when available
	var sorted_siblings = game.siblings.duplicate()
	var has_comparator := false
	for sibling in sorted_siblings:
		if str(sibling.get("sort_comparator", "")) != "":
			has_comparator = true
			break
	if has_comparator:
		sorted_siblings.sort_custom(func(a, b):
			var ca := str(a.get("sort_comparator", ""))
			var cb := str(b.get("sort_comparator", ""))
			if ca == cb:
				return str(a.get("name", "")) < str(b.get("name", ""))
			return ca < cb
		)
	for sibling in sorted_siblings:
		if sibling is Dictionary:
			_sibling_options.append(sibling)
			var sibling_label := str(sibling.get("name", "Unknown"))
			var disc_number: int = sibling.get("disc_number", 0)
			if disc_number > 0 and not sibling_label.to_lower().contains("(disc"):
				sibling_label = "Disc %d: %s" % [disc_number, sibling_label]
			sibling_dropdown.add_item(sibling_label)

	# Select the currently active sibling
	var active_id = game.selected_sibling_id if game.selected_sibling_id != 0 else game.romm_id
	for i in range(_sibling_options.size()):
		if _sibling_options[i].get("id", 0) == active_id:
			sibling_dropdown.selected = i
			break

	# Show/hide dropdown based on whether there are siblings
	sibling_dropdown.visible = _sibling_options.size() > 1

func _on_sibling_selected(index: int) -> void:
	if index < 0 or index >= _sibling_options.size():
		return

	var selected = _sibling_options[index]
	var selected_id = selected.get("id", 0)

	if _current_game and selected_id != 0:
		_current_game.selected_sibling_id = selected_id

		# Check if we need to fetch full sibling details (name/size unresolved from sync)
		if selected_id != _current_game.romm_id and not selected.get("name_resolved", false):
			_fetch_sibling_details(selected_id, index)
			return

		# Update display to show selected variant's info
		_update_file_info_display(_current_game)
		# Update action button based on new selection
		_update_action_button()
		# Update sync UI based on new selection
		_update_sync_ui()
		# Persist the selection
		DataManager.update_game(_current_game)

func _fetch_sibling_details(sibling_id: int, dropdown_index: int) -> void:
	"""Fetch full game details for a sibling to get proper file name with extension."""
	SystemManager.network.fetch_game_details(sibling_id, func(data: Dictionary, error: String):
		if not is_instance_valid(self):
			return
		if error == "" and data.has("fs_name"):
			var full_file_name = FSM.sanitize_server_filename(str(data.get("fs_name", "")))
			if full_file_name == "":
				push_error("[GameDetailsSheet] Rejected unsafe sibling file name from server: '" + str(data.get("fs_name", "")) + "'")
				return

			# Update the sibling data in _current_game
			for i in range(_current_game.siblings.size()):
				if _current_game.siblings[i].get("id", 0) == sibling_id:
					_current_game.siblings[i]["file_name"] = full_file_name
					_current_game.siblings[i]["file_size"] = data.get("fs_size_bytes", 0)
					_current_game.siblings[i]["name_resolved"] = true
					break

			# Also update _sibling_options
			if dropdown_index < _sibling_options.size():
				_sibling_options[dropdown_index]["file_name"] = full_file_name
				_sibling_options[dropdown_index]["file_size"] = data.get("fs_size_bytes", 0)
				_sibling_options[dropdown_index]["name_resolved"] = true

			# Save updated game data
			DataManager.update_game(_current_game)

			# Update the display
			_update_file_info_display(_current_game)
			_update_action_button()
			_update_sync_ui()
		else:
			# Still update display with what we have
			_update_file_info_display(_current_game)
			_update_action_button()
			_update_sync_ui()
			DataManager.update_game(_current_game)
	)

func _setup_status_dropdown(game: GameResource) -> void:
	if not status_dropdown:
		return

	# Status/favorites are RomM features; hide for other sources (e.g. steam)
	var is_romm_game := game.source == "romm"
	status_dropdown.visible = is_romm_game
	if favorite_button:
		favorite_button.visible = is_romm_game
	if not is_romm_game:
		return

	status_dropdown.clear_items()
	for opt in STATUS_OPTIONS:
		status_dropdown.add_icon_item(opt["icon"], opt["label"])
	_update_status_selection()

func _update_status_selection() -> void:
	if not status_dropdown or not _current_game:
		return
	var indices: Array[int] = []
	for i in range(STATUS_OPTIONS.size()):
		var key: String = STATUS_OPTIONS[i]["key"]
		match key:
			"now_playing":
				if _current_game.now_playing:
					indices.append(i)
			"backlogged":
				if _current_game.backlogged:
					indices.append(i)
			"hidden":
				if _current_game.hidden:
					indices.append(i)
			_:
				if _current_game.status == key:
					indices.append(i)
	status_dropdown.set_selected_indices(indices)

func _on_status_item_selected(index: int) -> void:
	if not _current_game or index < 0 or index >= STATUS_OPTIONS.size():
		return

	var key: String = STATUS_OPTIONS[index]["key"]
	var selected := status_dropdown.is_selected(index)
	var props: Dictionary = {}

	if key in STATUS_FLAG_KEYS:
		props[key] = selected
	else:
		# The status enum is mutually exclusive: clear the other enum items
		for i in range(STATUS_OPTIONS.size()):
			var other_key: String = STATUS_OPTIONS[i]["key"]
			if other_key in STATUS_FLAG_KEYS or i == index:
				continue
			if status_dropdown.is_selected(i):
				status_dropdown.deselect_option(i)
		if selected:
			props["status"] = key
		else:
			props["status"] = null

	DataManager.set_game_user_props(_current_game, props)

func _update_favorite_button() -> void:
	if not favorite_button or not _current_game:
		return
	favorite_button.icon_name = "heart" if _current_game.is_favorite else "heart-outline"
	favorite_button.tooltip_text = "Remove from favorites" if _current_game.is_favorite else "Add to favorites"

func _on_favorite_button_pressed() -> void:
	if not _current_game:
		return
	DataManager.set_game_favorite(_current_game, not _current_game.is_favorite)
	_update_favorite_button()

## Local-only Home hide toggle (eye button). Unlike the status-dropdown
## Hidden checkbox (a RomM server flag), this never leaves the device.
func _update_hide_button() -> void:
	if not hide_button or not _current_game:
		return
	var is_romm_game := _current_game.source == "romm"
	hide_button.disabled = not is_romm_game
	if not is_romm_game:
		hide_button.icon_name = "eye-off"
		hide_button.tooltip_text = "Hiding is only available for library games"
		return
	if _current_game.hidden_from_home:
		hide_button.icon_name = "eye"
		hide_button.tooltip_text = "Show in Home"
	else:
		hide_button.icon_name = "eye-off"
		hide_button.tooltip_text = "Hide from Home"

func _on_hide_button_pressed() -> void:
	if not _current_game or _current_game.source != "romm":
		return
	_current_game.hidden_from_home = not _current_game.hidden_from_home
	DataManager.update_game_hidden_from_home(_current_game.romm_id, _current_game.hidden_from_home)
	_update_hide_button()
	if _current_game.hidden_from_home:
		SystemManager.notifications.show_notification("Hidden from Home", SystemManager.notifications.Type.INFO)
	else:
		SystemManager.notifications.show_notification("Shown in Home", SystemManager.notifications.Type.INFO)
	# Home rebuilds its grid on this; other views have no use for the flag.
	DataManager.game_home_visibility_changed.emit(_current_game)

func _update_file_info_display(game: GameResource) -> void:
	# Get the active file info (either main game or selected sibling)
	var active_file_name = game.get_active_file_name()
	var active_file_size = game.get_active_file_size()

	file_info_label.text = "File: " + (active_file_name if active_file_name else "N/A")
	file_size_label.text = "Size: " + _format_file_size(active_file_size)

	# Check if the selected variant has a local copy
	if game.is_active_variant_downloaded():
		status_chip.text = "Downloaded"
		status_chip.leading_icon = "check-circle"
	else:
		status_chip.text = "Not downloaded"
		status_chip.leading_icon = "download"

	# Show Title ID for platforms that use it
	if title_id_label:
		var active_title_id = game.get_active_title_id()
		if active_title_id != "":
			title_id_label.text = "Title ID: " + active_title_id
			title_id_label.visible = true
		else:
			title_id_label.visible = false

func _load_cover(game: GameResource) -> void:
	_set_cover_texture(null)

	# Use a cover that was decoded while the context menu was open.
	if _prepared_romm_id == game.romm_id and _prepared_cover:
		_set_cover_texture(_prepared_cover)
		_prepared_cover = null
		_prepared_romm_id = 0
		return

	var cache_path := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url and game.cover_url.begins_with("http"):
		var url_path: String = DataManager.get_cached_image_path(game.cover_url)
		if FSM.file_exists(url_path):
			cache_path = url_path

	if cache_path != "":
		DataManager.cover.note_cover_access(cache_path)
		var cache_key := MemorySubManager.cover_cache_key(cache_path, MAX_DETAILS_TEXTURE_SIZE)
		var cached := MemorySubManager.get_cached_texture(cache_key)
		if cached:
			_set_cover_texture(cached)
			return
		if is_instance_valid(cover_texture):
			M3Shimmer.attach(cover_texture, 0.0)
		MemorySubManager.queue_image_task(
			func() -> Image:
				return MemorySubManager.prepare_image_for_texture(_decode_cover_downscaled(cache_path)),
			func(img: Image):
				if is_instance_valid(cover_texture):
					M3Shimmer.detach(cover_texture)
					if img and not img.is_empty():
						var tex := MemorySubManager.create_texture_from_image(img)
						if tex:
							MemorySubManager.cache_texture(cache_key, tex)
							_set_cover_texture(tex)
							return
				# Decode failed (corrupt or extension-mismatched cache file):
				# fall back to the remote path rather than showing nothing.
				_load_cover_remote(game)
		)
		return

	# Remote URL not yet on disk: keep the existing async path.
	_load_cover_remote(game)

func _load_cover_remote(game: GameResource) -> void:
	if game.cover_url and game.cover_url.begins_with("http"):
		if is_instance_valid(cover_texture):
			M3Shimmer.attach(cover_texture, 0.0)
		DataManager.load_image(game.cover_url, func(texture, _r: int):
			if not is_instance_valid(cover_texture):
				return
			M3Shimmer.detach(cover_texture)
			if texture and _current_game and _current_game.romm_id == game.romm_id:
				_set_cover_texture(texture)
		)

func _set_cover_texture(texture: Texture2D) -> void:
	if not is_instance_valid(cover_texture):
		return
	cover_texture.texture = texture

static func _decode_cover_downscaled(path: String) -> Image:
	return CardMediaLoader._load_image_from_buffer(FSM.read_file_bytes(path), MAX_DETAILS_TEXTURE_SIZE)

func _format_file_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(int(bytes / 1024.0)) + " KB"
	elif bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	else:
		return "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

func _update_action_button() -> void:
	if not action_button or not _current_game:
		return

	var session: GameSession = LaunchManager.sessions.get_live_for_game(_current_game.romm_id)
	if session and session.state == GameSession.State.RETAINED:
		action_button.text = "Resume"
		action_button.icon_name = "play"
		return
	if session and session.state == GameSession.State.LOST:
		action_button.text = "Launch Fresh"
		action_button.icon_name = "play"
		return

	if _current_game.is_active_variant_downloaded():
		action_button.text = "Launch"
		action_button.icon_name = "play"
	else:
		action_button.text = "Download"
		action_button.icon_name = "download"

func _update_sync_ui() -> void:
	if not sync_button or not sync_status_label or not _current_game:
		return

	var emulator_id = LaunchManager.resolve_emulator_for_game(_current_game)
	if emulator_id == "":
		sync_button.visible = false
		sync_status_label.visible = false
		return

	var extensions = DataManager.get_save_extensions(emulator_id, _current_game.platform_slug)
	if extensions.is_empty():
		sync_button.visible = false
		sync_status_label.visible = false
		return

	sync_button.visible = true
	sync_status_label.visible = true
	sync_button.text = "Sync Saves"
	sync_button.modulate = Color.WHITE
	sync_button.disabled = false
	sync_status_label.text = DataManager.get_save_sync_status_text(_current_game, emulator_id)

func _on_sync_button_pressed() -> void:
	if not _current_game:
		return

	var emulator_id = LaunchManager.resolve_emulator_for_game(_current_game)
	if emulator_id == "":
		return

	sync_button.disabled = true
	sync_button.text = "Syncing..."

	DataManager.sync_saves_for_game(_current_game, emulator_id, func(success: bool, message: String):
		if not is_instance_valid(sync_button):
			return
		sync_button.disabled = false
		sync_button.text = "Sync Saves"
		_update_sync_ui()

		if success:
			SystemManager.notifications.show_notification("Save sync complete", SystemManager.notifications.Type.INFO)
		else:
			SystemManager.notifications.show_notification("Save sync: " + message, SystemManager.notifications.Type.ERROR)
	)

func _on_action_button_pressed() -> void:
	if not _current_game:
		return
	var session: GameSession = LaunchManager.sessions.get_live_for_game(_current_game.romm_id)
	if session and session.state == GameSession.State.RETAINED:
		await LaunchManager.resume_retained_game(_current_game.romm_id)
		return

	# Skip file check for Steam games - they don't have physical files
	if _current_game.source == "steam":
		_setup_launch_transition_source()
		LaunchManager.launch_game(_current_game)
		return

	if _current_game.is_active_variant_downloaded():
		# Accept the stored path whether it points at the archive or at an
		# extracted folder (ps3/vita/xbox360 games live in directories after
		# launch-time extraction); only fall back to reconstructing the archive
		# path when the stored path is gone.
		var present := false
		var active_id = _current_game.get_active_game_id()
		var root_folder = DataManager.get_setting("games_root_folder")
		var root_path: String = root_folder.value if root_folder else ""
		if active_id != _current_game.romm_id:
			# Sibling selected: check its own file, not the main entry's path
			if root_path != "":
				present = FSM.file_exists(_current_game.get_sibling_file_path(active_id, root_path))
		elif _current_game.file_path != "" and (FSM.dir_exists(_current_game.file_path) or FSM.file_exists(_current_game.file_path)):
			present = true
		else:
			if root_path != "":
				var active_file_name = _current_game.get_active_file_name()
				present = FSM.file_exists(FSM.join_paths(root_path, _current_game.platform_slug, active_file_name))

		if not present:
			# File is marked as downloaded but doesn't exist - redownload
			SystemManager.notifications.show_notification("File not found - redownloading", SystemManager.notifications.Type.WARNING)
			_queue_download()
			return

		# Launch the game
		_setup_launch_transition_source()
		LaunchManager.launch_game(_current_game)
	else:
		# Download the game - same logic as library view
		_queue_download()

func _setup_launch_transition_source() -> void:
	# Animate the launch transition from the cover art shown in this sheet.
	if is_instance_valid(cover_texture) and cover_texture.texture:
		LaunchTransitionOverlay.set_source(cover_texture.texture, Rect2(cover_texture.global_position, cover_texture.size))

func _queue_download() -> void:
	if not _current_game:
		return
	SystemManager.download.queue_game_download(_current_game)

func _on_game_updated(game: GameResource) -> void:
	if not _current_game or not visible:
		return
	if game.romm_id != _current_game.romm_id:
		return
	_current_game = game
	_update_action_button()
	_update_hide_button()
	_update_file_info_display(_current_game)
	_update_sync_ui()
	_update_palette_dots(_current_game)
	_layout_metadata_row_overflow()

func _on_download_completed(item_id: String, success: bool, message: String) -> void:
	# Check if this download is for our current game
	if not _current_game:
		return

	var item = SystemManager.download.get_item(item_id)
	if item and item.game_resource and item.game_resource.romm_id == _current_game.romm_id:
		if success:
			SystemManager.notifications.show_notification("Download completed", SystemManager.notifications.Type.INFO)
		else:
			SystemManager.notifications.show_notification("Download failed: " + message, SystemManager.notifications.Type.ERROR)

		# Reload game data from DataManager to get updated downloaded_sibling_ids
		var updated_game = DataManager.get_game_by_id(_current_game.romm_id)
		if updated_game:
			_current_game = updated_game

		# Refresh the action button state
		_update_action_button()
		# Also refresh the file info display
		_update_file_info_display(_current_game)
		# Also refresh the sync UI
		_update_sync_ui()
		_update_palette_dots(_current_game)
		_layout_metadata_row_overflow()
