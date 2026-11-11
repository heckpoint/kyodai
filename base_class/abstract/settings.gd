# settings.gd
extends Resource
class_name Settings
const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType

## Marks a SettingsVar as part of theme presets (ThemePreset.values). This is
## the single source of truth for what themes capture — flag it here and save/
## apply/match all follow automatically.
static func _preset(s: SettingsVar) -> SettingsVar:
	s.include_in_preset = true
	return s
# DEFAULTS....................................................................

@export_group("Settings")
@export_subgroup("Audio")
@export var dblevel_music := SettingsVar.new(Type.FLOAT, 100.0, State.ENABLED, "Music Level", "", 0.0, 100.0, 1.0, [], false, {"show_stops": false, "slider_size": "SMALL", "display_unit": "%"})
@export var dblevel_sfx := SettingsVar.new(Type.FLOAT, 100.0, State.ENABLED, "SFX Level", "", 0.0, 100.0, 1.0, [], false, {"show_stops": false, "slider_size": "SMALL", "display_unit": "%"})
@export var music_file := SettingsVar.new(Type.PATH, "", State.ENABLED, "Background Music", "Audio file to loop in the background", 0.0, 1.0, 0.1, [], false, {"dialog": "file", "filters": ["*.ogg ; OGG Vorbis", "*.mp3 ; MP3", "*.wav ; WAV"]})

@export_subgroup("Display")
@export var windowed := SettingsVar.new(Type.BOOL,true,State.ENABLED,"Windowed")
@export var ui_scale := SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "UI Scale", "Scale all interface elements (multiplier on top of automatic display scaling)", 0.75, 3.0, 0.05, [], false, {"show_stops": false})
@export var hdr_enabled := SettingsVar.new(Type.BOOL, false, State.ENABLED, "HDR Output", "Request HDR output on supported displays")
@export var vrr_enabled := SettingsVar.new(Type.BOOL, false, State.ENABLED, "VRR / High Refresh", "Disable frame pacing limits and vsync for variable-refresh-rate displays")
@export var resolutions: Array = [
	Vector2i(2560,1080),
	Vector2i(1920,1080),
	Vector2i(1366,768),
	Vector2i(1536,864),
	Vector2i(1280,720),
	Vector2i(1440,900),
	Vector2i(1600,900),
	Vector2i(1024,600),
	Vector2i(800,600)
]
@export var resolution := SettingsVar.new(Type.ARRAY,resolutions[0],State.ENABLED, "Windowed Resolution:", "", 0.0, 1.0, 0.1, resolutions)
@export var dual_screen_mode := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Dual Screen Mode", "Automatically use second display for hero image when available")
@export var ui_font := SettingsVar.new(Type.PATH, "", State.ENABLED, "Interface Font", "Custom variable-weight font for the interface; leave empty to use the built-in M PLUS 1", 0.0, 1.0, 0.1, [], false, {"dialog": "file", "filters": ["*.ttf ; TrueType Font", "*.otf ; OpenType Font", "*.woff2 ; WOFF2 Font"]})

# Internal DS screen swap state (managed by AynThorManager)
@export var dual_screen_swapped := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Dual Screen Swapped")

# Internal debug toggle: enables [Geom] overlay/layout geometry logging
# (M3Debug.geom). Set via console or config; not shown in the settings UI.
@export var debug_geometry_logging := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Debug Geometry Logging")

# Internal last windowed size (managed by SystemManager.display). 200x150 min, 16K max.
@export var last_window_size := SettingsVar.new(Type.VECTOR2I, Vector2i.ZERO, State.INTERNAL, "Last Window Size", "", 200.0, 16384.0, 1.0, [], false, {})

@export_subgroup("RomM Connection")
@export var romm_url := SettingsVar.new(Type.STRING, "", State.ENABLED, "RomM URL")
@export var romm_username := SettingsVar.new(Type.STRING, "", State.ENABLED, "Username")
@export var romm_password := SettingsVar.new(Type.STRING, "", State.ENABLED, "Password", "", 0.0, 1.0, 0.1, [], true)
# Internal: Client API Token (rmm_...) obtained via device pairing or code
# exchange. When set, all requests authenticate as Bearer instead of Basic
# and the username/password fields are unused (kept only for pre-5.0 servers).
@export var romm_token := SettingsVar.new(Type.STRING, "", State.INTERNAL, "RomM Client API Token", "", 0.0, 1.0, 0.1, [], true)
# Internal: device bound 1:1 to the paired token by /api/auth/device. Save
# sync deliberately keeps using the legacy romm_device_id (see
# game_save_sub_manager) so existing devices keep their sync history.
@export var romm_bound_device_id := SettingsVar.new(Type.STRING, "", State.INTERNAL, "RomM Paired Device ID")
# Internal: stable random UUID sent as client_device_identifier on pairing.
# RomM dedupes devices on (user, identifier), so re-pairing after token loss
# reuses the same server device instead of creating duplicates.
@export var romm_client_device_identifier := SettingsVar.new(Type.STRING, "", State.INTERNAL, "RomM Client Device Identifier")
# Internal: the http:// origin the user acknowledged as insecure-but-accepted
# (KYD-07). Pre-ticks the connection panel's acknowledgment checkbox when the
# current URL matches; a different http origin must be re-acknowledged.
@export var romm_insecure_http_ack := SettingsVar.new(Type.STRING, "", State.INTERNAL, "Insecure HTTP Acknowledged Origin")
@export var fold_duplicate_covers := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Fold duplicate covers into siblings", "During sync, games with identical cover art will be grouped together like RomM siblings")
@export var hide_games_without_covers := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Hide games without cover art", "Games without cover art will be hidden from the library view")
@export var fold_romm_siblings := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Fold RomM siblings", "RomM-designated regional variants (siblings) will be grouped under a single library entry")
@export_subgroup("Storage")
@export var games_root_folder := SettingsVar.new(Type.PATH, "user://roms/", State.ENABLED, "Games Folder", "Directory where game ROMs are stored")
@export var emulators_folder := SettingsVar.new(Type.PATH, "user://emulators/", State.ENABLED, "Emulators Folder", "Directory where emulators are installed")
@export var steam_folder := SettingsVar.new(Type.PATH, "", State.ENABLED, "Steam Installation Folder", "Path to your Steam installation (e.g., C:\\Program Files (x86)\\Steam)")
@export var save_sync_auto := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Auto-sync saves", "Automatically upload saves after playing and download before launch")
@export var download_speed_profile := SettingsVar.new(Type.ARRAY, 1, State.ENABLED, "Download Speed", "Higher settings use more network connections per file and more simultaneous downloads", 0.0, 3.0, 1.0, ["Conservative", "Balanced", "Fast", "Unrestricted"])
@export var cover_cache_max_mb := SettingsVar.new(Type.INT, 2048, State.ENABLED, "Cover Cache Limit", "Maximum disk space used for cached cover art; the least recently used covers are evicted when the limit is exceeded. Set to Unlimited to never evict", 64.0, 4096.0, 64.0, [], false, {"display_unit": " MB", "unlimited_tick": true})

# Internal Steam games list imported from exported .steam shortcut files
# (not displayed in settings menu)
@export var steam_games := SettingsVar.new(Type.ARRAY, [], State.INTERNAL, "Steam Games")

# Internal Steam launch backend preference: "auto" (detect/ask), "gamenative"
# or "droiddeck". Set from the launch-time backend picker dialog.
@export var steam_backend := SettingsVar.new(Type.STRING, "auto", State.INTERNAL, "Steam Launch Backend")

# Internal platform sync settings (not displayed in auto-generated menu)
@export var enabled_platforms := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Enabled Platforms")

# Internal per-emulator external data dirs discovered out-of-band on Android
# (e.g. azahar's SAF-picked user folder, read from its private prefs via vendor
# root). Redirects {emulator_dir} so firmware/save/config resolution follows
# the emulator's real location. {emulator_id: absolute_path}
@export var external_emulator_dirs := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "External Emulator Dirs")

# Internal shuffler preferences (set from the shuffler config dialog)
@export var shuffler_platform_balance := SettingsVar.new(Type.INT, 50, State.INTERNAL, "Shuffler: Platform Balance", "How evenly platforms are represented in the shuffle bag: 0% is proportional to library size, 100% is equal shares", 0.0, 100.0, 5.0)
# Set by the "Don't show this again" checkbox on the shuffler's
# experimental-feature warning (persisted only when confirmed).
@export var shuffler_warning_dismissed := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Shuffler: Experimental Warning Dismissed")

# Internal card effect configuration (managed by Card Designer)
@export var card_effect_config := _preset(SettingsVar.new(Type.DICTIONARY, {
	"card_orientation": 2,
	"card_rounding": 0.24,
	"effects": [{
		"layer_id": "default_shadow",
		"effect_id": "drop_shadow",
		"settings": {
			"shadow_color": Color(0, 0, 0, 0.5),
			"shadow_expand": 0.066,
			"shadow_offset_x": 0.0,
			"shadow_offset_y": 0.043,
			"shadow_softness": 0.15,
			"shadow_spread": 0.0
		}
	}],
	"focus_effects": [{
		"layer_id": "default_focus_glow",
		"effect_id": "glow",
		"settings": {
			"blur_amount": 6.5,
			"glow_intensity": 0.3,
			"glow_radius": 0.14,
			"glow_spread": 0.06,
			"threshold": 0.41
		}
	}],
	"hero_height": 4
}, State.INTERNAL, "Card Effect Configuration"))

# Internal hero effect configuration (managed by Hero Designer)
@export var hero_effect_config := _preset(SettingsVar.new(Type.DICTIONARY, {
	"effects": [],
	"corner_radius": 0.06,
	"hero_height": 0
}, State.INTERNAL, "Hero Effect Configuration"))

@export_subgroup("Library Appearance")
# General layout settings (always visible)
@export var library_primary_color := _preset(SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Accent Color", "Primary color for the Material 3 interface theme"))
@export var dark_mode := _preset(SettingsVar.new(Type.BOOL, true, State.ENABLED, "Dark Mode", "Use dark colors for the Material 3 interface"))
@export var frosted_look := _preset(SettingsVar.new(Type.BOOL, false, State.ENABLED, "Frosted Look", "Blur the backdrop behind cards, dialogs and sheets, tinted with the current theme colors"))
@export var library_layout_mode := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Layout Mode", "How game cards are arranged in the library", 0.0, 2.0, 1.0, ["Grid", "List", "Carousel"]))
@export var library_grid_vertical := _preset(SettingsVar.new(Type.BOOL, true, State.INTERNAL, "Grid Vertical", "Scroll grid vertically (true) or horizontally (false)"))
@export var library_pagination_view := _preset(SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Pagination View", "Split the grid into viewport-sized pages with a gap in the scroll direction instead of a continuous scrolling list"))
@export var library_grid_staggered := _preset(SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Staggered Grid", "Offset every other row by half a card width in a brick pattern; offset rows show one fewer card"))
@export var library_focus_centering := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Focus Centering", "How the view scrolls when focus nears a screen edge: Margin slides the card just back on screen, Center brings it to the center of the screen", 0.0, 1.0, 1.0, ["Margin", "Center"]))
@export var library_navigation_type := _preset(SettingsVar.new(Type.ARRAY, 1, State.ENABLED, "Navigation Type", "Use a bottom bar or side rail for navigation", 0.0, 1.0, 1.0, ["Bar", "Rail"]))
@export var library_grid_padding := _preset(SettingsVar.new(Type.INT, 22, State.ENABLED, "Grid Padding", "Space between game cards in pixels", 0.0, 50.0, 1.0))
@export var library_card_zoom := _preset(SettingsVar.new(Type.FLOAT, 0.25, State.INTERNAL, "Card Zoom", "Card size as ratio of viewport", 0.05, 0.5, 0.01))
@export var library_card_zoom_level := _preset(SettingsVar.new(Type.INT, -1, State.INTERNAL, "Card Zoom Level", "Discrete zoom level for grid mode (index into snap ratios)", -1.0, 11.0, 1.0))
@export var library_card_zoom_list := _preset(SettingsVar.new(Type.FLOAT, 0.25, State.INTERNAL, "Card Zoom (List)", "Card size as ratio of viewport for list/carousel modes", 0.05, 0.5, 0.01))
@export var library_show_title_mode := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Gamecard Titles", "When to display game titles on cards", 0.0, 2.0, 1.0, ["None", "Focused", "All"]))
@export var library_focus_scale := _preset(SettingsVar.new(Type.FLOAT, 0.09, State.ENABLED, "Focus Scale", "How much larger the focused card appears (0% to 50%)", 0.0, 0.5, 0.01))
@export var library_focus_movement_anim := _preset(SettingsVar.new(Type.ARRAY, 2, State.ENABLED, "Focus Movement", "How the focus ring moves between controls: None snaps instantly, Pop snaps with a quick scale-down settle, Follow tweens to the new control", 0.0, 2.0, 1.0, ["None", "Pop", "Follow"]))
@export var library_focus_idle_anim := _preset(SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Focus Idle Animation", "Looping animation shown on the focus ring while focus is stationary", 0.0, 2.0, 1.0, ["None", "Breathe", "Chase"]))
@export var library_focus_ring_thickness := _preset(SettingsVar.new(Type.FLOAT, 3.0, State.ENABLED, "Focus Ring Thickness", "Stroke width of the focus ring in dp", 1.0, 8.0, 0.5))
@export var library_focus_ring_shape := _preset(SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Focus Ring Shape", "Full draws the complete rounded ring; Corners draws only crosshair-style corner ticks", 0.0, 1.0, 1.0, ["Full", "Corners"]))
@export var library_focus_ring_outset := _preset(SettingsVar.new(Type.INT, 2, State.ENABLED, "Focus Ring Outset", "Space between the focused control and the focus ring in dp", 0.0, 12.0, 1.0, [], false, {"show_stops": false, "display_unit": "dp"}))
@export var library_card_content_alignment := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Content Alignment", "How card content is positioned within the card cell", 0.0, 2.0, 1.0, ["Left/Top", "Center/Middle", "Right/Bottom"]))
@export var library_card_show_platform := _preset(SettingsVar.new(Type.BOOL, true, State.INTERNAL, "Show Platform", "Display the platform as supporting text on game cards"))
# Follow Content preserves the alignment supplied by Content Alignment until
# the user explicitly chooses a text-only alignment from the toolbar.
@export var library_card_text_alignment := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Text Alignment", "How title and platform text align within the card's text bounds", 0.0, 3.0, 1.0, ["Follow Content", "Left", "Center", "Right"]))
@export var library_card_scroll_truncation := _preset(SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Scroll Truncation", "Scroll overflowing title and platform text while its card is focused"))
@export var library_card_text_focused_only := _preset(SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Focused Only", "Hide title and platform text on every unfocused game card"))
@export var card_media_aspect_ratio := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Card Media Ratio", "Aspect ratio of the card's media panel", 0.0, 4.0, 1.0, ["Fill", "2:3", "3:4", "1:1", "16:11"]))
@export var library_card_display_mode := _preset(SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Card Display Mode", "How game cards appear in the library", 0.0, 2.0, 1.0, ["Standard", "Transparent", "Media Only"]))


# Internal first-run flag (tracks if OOBE wizard has been completed)
@export var first_run_completed := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "First Run Completed")

# Internal last search query (managed by Library search)
@export var library_last_search := SettingsVar.new(Type.STRING, "", State.INTERNAL, "Last Search Query")

# Internal installed emulator versions (tracked for update checking)
@export var installed_emulator_versions := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Installed Emulator Versions")

# Internal background effect configuration (managed by the Background Designer)
@export var library_background_config := _preset(SettingsVar.new(Type.DICTIONARY, {
	"effects": []
}, State.INTERNAL, "Background Effect Configuration"))

# Internal pinned navigation shortcuts (managed by NavigationSubManager)
@export var nav_pinned_shortcuts := SettingsVar.new(Type.ARRAY, [], State.INTERNAL, "Pinned Navigation Shortcuts")

@export_subgroup("Updates")
@export var update_check_on_startup := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Check for Updates on Startup", "Check GitHub for a newer Kyodai release when the app starts")
# Default Experimental while the app is in alpha: every release is currently a
# prerelease, so Stable would never notify. Flip the default to 0 at 1.0.
@export var release_channel := SettingsVar.new(Type.ARRAY, 1, State.ENABLED, "Release Channel", "Stable only notifies about full releases; Experimental also includes alpha/beta prereleases", 0.0, 1.0, 1.0, ["Stable", "Experimental"])
